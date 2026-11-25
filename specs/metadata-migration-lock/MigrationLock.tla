--------------------------- MODULE MigrationLock ---------------------------
(***************************************************************************)
(* Opening the metadata migration lock file in a shared data directory.   *)
(*                                                                         *)
(* Before it migrates the SQLite metadata store, Dingo takes a flock on    *)
(* <metadata.sqlite>.migrate.lock (database/plugin/metadata/sqlstore/      *)
(* migrations/lock_file_unix.go fileLocker.Acquire). Dingo main opens it   *)
(* with O_CREAT|O_RDWR, mode 0600, whether or not it exists.               *)
(*                                                                         *)
(* A Kubernetes pod mounts the data directory with fsGroup: the directory  *)
(* is world- or group-writable with the sticky and setgid bits (relay-a:   *)
(* drwxrwsrwt root:dingo), and every file is group-readable and -writable *)
(* to the pod's group. A file a different uid created stays owned by that  *)
(* uid.                                                                    *)
(*                                                                         *)
(* There is no Cardano reference implementation for this lock. The rules   *)
(* are the kernel's:                                                       *)
(*   [K1] Linux fs/namei.c may_create_in_sticky, and                       *)
(*        Documentation/admin-guide/sysctl/fs.rst "protected_regular":     *)
(*        with protected_regular set (1 for world-writable, 2 also for     *)
(*        group-writable sticky directories), an O_CREAT open of an        *)
(*        existing regular file is refused unless the caller or the        *)
(*        directory's owner owns the file, whatever its mode.              *)
(*   [K2] open(2): O_RDWR needs write permission and O_RDONLY read         *)
(*        permission, by owner, group or other bits.                       *)
(*   [K3] flock(2): a lock can be placed on a file opened only for         *)
(*        reading.                                                         *)
(*                                                                         *)
(* Symbols are explained in specs/hello/Hello.tla's header.                *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS
    Open,        \* "creat" (Dingo main: O_CREAT|O_RDWR) or "existing" (the fix)
    Protected    \* TRUE: the host sets protected_regular (Ubuntu's default is 2)

\* In English: "Who may own the lock file: the node itself, the
\* directory's owner, or another uid (a pod or tool that ran as one)."
\* Literally: "Owners is defined as the set of "self", "dirOwner" and
\*   "other"."
Owners == {"self", "dirOwner", "other"}

\* In English: "The permission bits that matter to the node: whether it
\* may read and whether it may write the file, through the owner bits when
\* it owns it and the group bits otherwise."
\* Literally: "Perms is defined as the set of records with fields r and w,
\*   each a boolean."
Perms == [r : BOOLEAN, w : BOOLEAN]

VARIABLES
    exists,   \* the lock file already exists
    owner,    \* its owner
    perm,     \* what the node may do with it [K2]
    result    \* "pending", "locked", or "refused"

\* Literally: "vars is defined as the tuple of the four variables."
vars == <<exists, owner, perm, result>>

\* In English: "Any starting state: the lock file absent, or present with
\* any owner and any permissions. The data files themselves are readable
\* and writable to the node through fsGroup."
\* Literally: "Init is defined as: exists is a boolean, owner is in Owners,
\*   perm is in Perms, and result equals "pending"."
Init ==
    /\ exists \in BOOLEAN
    /\ owner \in Owners
    /\ perm \in Perms
    /\ result = "pending"
-----------------------------------------------------------------------------
\* In English: "An O_CREAT open of the existing file is refused by [K1]."
\* Literally: "CreatBlocked is defined as: Protected is TRUE, and exists is
\*   TRUE, and owner is not "self" and not "dirOwner"."
CreatBlocked == Protected /\ exists /\ owner \notin {"self", "dirOwner"}

\* In English: "Can the node open the lock and flock it? Dingo main needs
\* the O_CREAT open to pass [K1] and write permission [K2]. The fix opens an
\* existing file without O_CREAT, for writing or else for reading, which is
\* enough for flock [K3], and creates the file only when it is absent."
\* Literally: "Opens is defined as: if Open equals "creat" then (it is not
\*   the case that CreatBlocked, and (exists is FALSE or perm's w is TRUE)),
\*   else (exists is FALSE, or perm's w is TRUE, or perm's r is TRUE)."
Opens ==
    IF Open = "creat"
       THEN ~CreatBlocked /\ (~exists \/ perm.w)          \* [K1][K2]
       ELSE ~exists \/ perm.w \/ perm.r                     \* [K2][K3]

\* In English: "The node tries to take the lock once."
\* Literally: "Acquire is defined as: result equals "pending", and result
\*   in the next state equals (if Opens then "locked" else "refused"), and
\*   exists, owner and perm are unchanged."
Acquire ==
    /\ result = "pending"
    /\ result' = IF Opens THEN "locked" ELSE "refused"
    /\ UNCHANGED <<exists, owner, perm>>

\* In English: "After the attempt nothing changes any more."
\* Literally: "Done is defined as: result does not equal "pending", and vars
\*   is unchanged."
Done == result # "pending" /\ UNCHANGED vars

\* Literally: "Next is defined as: Acquire, or Done."
Next == Acquire \/ Done

\* Literally: "Spec is defined as: Init, and always Next or vars unchanged."
Spec == Init /\ [][Next]_vars
-----------------------------------------------------------------------------
\* In English: "Whenever the node may read the lock file (fsGroup gives it
\* group read and write, as it does every data file), it takes the lock."
\* Literally: "LockWhenReadable is defined as: if result equals "refused",
\*   then exists is TRUE and perm's r is FALSE and perm's w is FALSE."
LockWhenReadable ==
    result = "refused" => (exists /\ ~perm.r /\ ~perm.w)
=============================================================================
