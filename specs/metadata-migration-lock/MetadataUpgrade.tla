-------------------------- MODULE MetadataUpgrade --------------------------
(***************************************************************************)
(* Upgrading a v0.94.2 metadata store (schema 68) when Dingo cannot write  *)
(* it.                                                                     *)
(*                                                                         *)
(* Dingo opens the store twice before the node runs:                       *)
(*   1. a pre-open check (internal/settingsresolve), whose failure is      *)
(*      logged and ignored;                                                *)
(*   2. the v0.94.2 ledger-state migration (internal/nodestorage           *)
(*      released.go), through the SQLite plugin's Start                    *)
(*      (database/plugin/metadata/sqlite shared_sqlstore.go: prepare, then *)
(*      the schema migrations).                                            *)
(* Each runs the schema migrations 69..74 in order; each migration writes. *)
(*                                                                         *)
(* When the process may not write metadata.sqlite (its mode lacks the      *)
(* owner's write bit, another uid owns it in a protected sticky            *)
(* directory, and so on), SQLite opens it read-only [S1] and the first     *)
(* write fails with "attempt to write a readonly database" [S2].           *)
(*                                                                         *)
(* There is no Cardano reference for this; the rules are SQLite's:         *)
(*   [S1] sqlite.org/c3ref/open.html: SQLITE_OPEN_READWRITE "opens the     *)
(*        database for reading and writing if possible, or reading only if *)
(*        the file is write protected by the operating system".            *)
(*   [S2] sqlite.org/rescode.html SQLITE_READONLY (8): "an attempt is made *)
(*        to alter some data for which the current database connection     *)
(*        does not have write permission".                                 *)
(*                                                                         *)
(* Symbols are explained in specs/hello/Hello.tla's header.                *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS
    Check,      \* "none" (Dingo main) or "access" (the fix: check write access first)
    Writable,   \* TRUE: the process may write metadata.sqlite
    Pending     \* schema migrations still to run (6 for 68 -> 74)

VARIABLES
    step,       \* "precheck", "migrate", "running" or "failed"
    applied,    \* migrations applied so far
    reason      \* why the node stopped: "none", "readonly" (SQLite's), or "notWritable" (named up front)

\* Literally: "vars is defined as the tuple of the three variables."
vars == <<step, applied, reason>>

\* In English: "The node starts with no migration applied."
\* Literally: "Init is defined as: step equals "precheck", applied equals 0,
\*   and reason equals "none"."
Init == step = "precheck" /\ applied = 0 /\ reason = "none"
-----------------------------------------------------------------------------
\* In English: "The pre-open check runs the migrations if it can, and its
\* failure is ignored [settingsresolve]."
\* Literally: "PreCheck is defined as: step equals "precheck", and step in
\*   the next state equals "migrate", and applied in the next state equals
\*   (if Writable then Pending else applied), and reason is unchanged."
PreCheck ==
    /\ step = "precheck"
    /\ step' = "migrate"
    /\ applied' = IF Writable THEN Pending ELSE applied
    /\ UNCHANGED reason

\* In English: "The migration's own open. With the fix it first checks that
\* it may write the file, and stops naming it; without, it runs the next
\* migration, which fails as SQLite's read-only error [S1][S2]."
\* Literally: "Migrate is defined as: step equals "migrate", and: if applied
\*   equals Pending then step in the next state equals "running" and applied
\*   and reason are unchanged; else if Check equals "access" and Writable is
\*   FALSE then step becomes "failed", reason becomes "notWritable", applied
\*   unchanged; else if Writable then applied increases by 1 and step and
\*   reason are unchanged; else step becomes "failed", reason becomes
\*   "readonly", applied unchanged."
Migrate ==
    /\ step = "migrate"
    /\ IF applied = Pending
          THEN /\ step' = "running" /\ UNCHANGED <<applied, reason>>
       ELSE IF Check = "access" /\ ~Writable
          THEN /\ step' = "failed" /\ reason' = "notWritable"
               /\ UNCHANGED applied
       ELSE IF Writable
          THEN /\ applied' = applied + 1 /\ UNCHANGED <<step, reason>>
       ELSE /\ step' = "failed" /\ reason' = "readonly"           \* [S2]
            /\ UNCHANGED applied

\* In English: "Once the node runs or has stopped, nothing changes."
\* Literally: "Done is defined as: step is "running" or "failed", and vars is
\*   unchanged."
Done == step \in {"running", "failed"} /\ UNCHANGED vars

\* Literally: "Next is defined as: PreCheck, or Migrate, or Done."
Next == PreCheck \/ Migrate \/ Done

\* Literally: "Spec is defined as: Init, and always Next or vars unchanged."
Spec == Init /\ [][Next]_vars
-----------------------------------------------------------------------------
\* In English: "A store Dingo may not write never gets as far as a migration
\* failing on SQLite's read-only error: the node stops before migrating and
\* says which file it cannot write."
\* Literally: "NoMigrationWithoutWriteAccess is defined as: reason does not
\*   equal "readonly"."
NoMigrationWithoutWriteAccess == reason # "readonly"

\* In English: "A writable store is always upgraded and the node runs."
\* Literally: "WritableRuns is defined as: if Writable and step is "failed"
\*   then FALSE."
WritableRuns == Writable => step # "failed"
=============================================================================
