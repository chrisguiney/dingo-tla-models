---------------------------- MODULE ChunkedApply ----------------------------
(***************************************************************************)
(* One ledger batch written to Dingo's live UTxO store (badgerutxo) when   *)
(* it is too big for one Badger transaction, a crash between any two of    *)
(* its transactions, the startup rewind of the failure mark, and the batch *)
(* applied again.                                                          *)
(*                                                                         *)
(* Dingo sources (blinklabs-io/dingo, database/ledgerdb/badgerutxo):       *)
(*   [D1] chunk.go applyChunked: the transactions a batch is split into,  *)
(*        the failure mark set in the first and cleared in the last, the  *)
(*        batch rollback (DeleteNoncesAfter) carried by the first leading *)
(*        transaction, snapshot and reward block ops extracted when they  *)
(*        do not fit beside the batch's other rows.                       *)
(*   [D2] store.go applyLedgerTxn: the order inside one transaction:      *)
(*        rollback, epochs, snapshot ops, rows, reward block ops, UTxO    *)
(*        changes and their journal record, tip.                          *)
(*   [D3] rewardblocks.go: an Open op creates the fee row when absent; a  *)
(*        Fee op adds to the fee row when it exists; a counted block is   *)
(*        guarded by the epoch's next slot, so applied again it is a      *)
(*        no-op. Each write journals the row at the op's slot.            *)
(*   [D4] recovery.go PointBefore and stoppedBeforeRecord; epoch.go       *)
(*        rollbackLedgerState: a rollback to a slot undoes journaled rows *)
(*        past it and deletes snapshot rows of epochs past the newest     *)
(*        epoch row. internal/utxoset/set.go rewindFailed: at startup a   *)
(*        failure mark rolls back to PointBefore(mark) when one is found. *)
(*   [D5] epoch.go putSnapshot: a snapshot put is not journaled; it      *)
(*        writes a capture index entry at the row's capture slot.         *)
(*                                                                         *)
(* Reference: UNSOURCED. The split of one ledger commit into several      *)
(* storage transactions is Dingo's own; cardano-node's LedgerDB has no    *)
(* counterpart. The property checked is the one a single atomic commit    *)
(* gives: a crash plus restart plus a second application leaves the      *)
(* store as one application would.                                        *)
(*                                                                         *)
(* Badger rejects a transaction past its size limit with ErrTxnTooBig     *)
(* (dgraph-io/badger v4 txn.go). The model's OverBudget stands for a     *)
(* batch whose ops do not fit beside its other rows.                      *)
(*                                                                         *)
(* Symbols are read as in specs/hello/Hello.tla.                          *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANTS
    ExtractOps,                 \* ops too big for the last transaction get transactions of their own
    RewindStoppedBeforeRecord,  \* PointBefore finds journal entries past the tip with no record
    KeepRollbackWithoutOps,     \* the batch rollback stays on the batch when no op is extracted
    RowsBeforeOps,              \* rows go ahead of extracted ops, as in one transaction
    RewindStrayCapture,         \* PointBefore finds snapshot capture index entries past the tip (not taken)
    MaxCrashes                  \* crashes per behaviour

\* Literally: "the first five constants are each TRUE or FALSE, and
\*   MaxCrashes is a natural number."
\* In English: the flags pick a Dingo version; see the configs.
ASSUME /\ ExtractOps \in BOOLEAN
       /\ RewindStoppedBeforeRecord \in BOOLEAN
       /\ KeepRollbackWithoutOps \in BOOLEAN
       /\ RowsBeforeOps \in BOOLEAN
       /\ RewindStrayCapture \in BOOLEAN
       /\ MaxCrashes \in Nat

\* In English: the fee a Fee op adds. Any positive amount shows a double.
F == 1

\* Literally: "Order is defined as the sequence of eleven step names."
\* In English: the order applyLedgerTxn writes a transaction's parts in
\* [D2], with "mark" and "clear" for the failure mark around them [D1].
Order == <<"mark", "rollback", "epoch", "snap", "row", "open", "fee",
           "count", "change", "tip", "clear">>

\* Literally: "OpSteps is defined as the set of "snap", "open", "fee" and
\*   "count"."
\* In English: the snapshot and reward block ops opsCost weighs [D1].
OpSteps == {"snap", "open", "fee", "count"}

\* Literally: "Shapes is defined as the set of records whose fields range
\*   over the sets given."
\* In English: every batch the model applies. hasRollback: the batch rolls
\* back first (DeleteNoncesAfter). ops: which ops it carries. overBudget:
\* the ops and the other rows exceed one transaction. hasChange: it carries
\* a UTxO change, whose journal record goes in a transaction of its own.
\* feeSource: what creates the fee row the Fee op adds to, a reward block
\* Open op or a row put. entries: whether the batch's journaled writes lie
\* past the tip, or at or below it, which only a batch that rolls back
\* first can do.
Shapes == [hasRollback : BOOLEAN,
           ops : {"none", "snapOnly", "rewardOnly", "both"},
           overBudget : BOOLEAN,
           hasChange : BOOLEAN,
           feeSource : {"open", "row"},
           entries : {"pastTip", "belowTip"}]

VARIABLES
    b,        \* the batch's shape, fixed for the behaviour
    st,       \* the store
    pc,       \* the next transaction of the plan
    phase,    \* "run", "crashed", "recovered", "done" or "toobig"
    crashes   \* crashes so far
vars == <<b, st, pc, phase, crashes>>

\* Literally: "SnapOps is defined as: b.ops is "snapOnly" or "both"."
\* In English: the batch carries a snapshot put.
SnapOps == b.ops \in {"snapOnly", "both"}

\* Literally: "RewardOps is defined as: b.ops is "rewardOnly" or "both"."
\* In English: the batch carries a Fee op and a counted block.
RewardOps == b.ops \in {"rewardOnly", "both"}

\* Literally: "HasOps is defined as SnapOps or RewardOps."
HasOps == SnapOps \/ RewardOps

\* Literally: "Opt(c, S) is defined as S if c, else the empty set."
\* In English: a part that is in the batch only when c holds.
Opt(c, S) == IF c THEN S ELSE {}

\* Literally: "AllSteps is defined as the union of "epoch" and "tip" with
\*   each optional part the shape selects."
\* In English: every write of the batch. The epoch row and the tip are
\* always there; the fee row comes from a row put or an Open op.
AllSteps ==
    {"epoch", "tip"}
    \cup Opt(b.hasRollback, {"rollback"})
    \cup Opt(SnapOps, {"snap"})
    \cup Opt(b.feeSource = "row", {"row"})
    \cup Opt(RewardOps, {"fee", "count"})
    \cup Opt(RewardOps /\ b.feeSource = "open", {"open"})
    \cup Opt(b.hasChange, {"change"})

\* Literally: "Dropped is defined as: ExtractOps and not
\*   KeepRollbackWithoutOps."
\* In English: the version moves the rollback off the batch whenever the
\* family estimate is over budget, even with no op to carry it [D1].
Dropped == ExtractOps /\ ~KeepRollbackWithoutOps

\* Literally: "RowLead is the one-element sequence of {"row"} if rows go
\*   first and the batch has one, else the empty sequence; SnapLead and
\*   BlockLead likewise for the extracted ops."
\* In English: the leading transactions of an extracted batch, in the
\* order the loop takes them: rows, snapshot ops, then reward block ops in
\* two transactions, the Fee op's and the count's.
RowLead == IF RowsBeforeOps /\ "row" \in AllSteps THEN <<{"row"}>> ELSE <<>>
SnapLead == IF SnapOps THEN <<{"snap"}>> ELSE <<>>
BlockLead ==
    IF RewardOps
    THEN <<{"fee"} \cup Opt(b.feeSource = "open", {"open"}), {"count"}>>
    ELSE <<>>

\* Literally: "Lead0 is RowLead, SnapLead and BlockLead concatenated."
\* In English: `\o` joins two sequences, like append(a, b...) in Go.
Lead0 == RowLead \o SnapLead \o BlockLead

\* Literally: "LeadSteps is the union of the sets in Lead0."
\* In English: every write the leading transactions take.
LeadSteps == UNION {Lead0[i] : i \in 1..Len(Lead0)}

\* Literally: "Lead is Lead0 with its first set joined by "mark" and, if
\*   the batch rolls back, "rollback"."
\* In English: the first transaction sets the failure mark and carries the
\* batch's rollback [D1].
Lead == [Lead0 EXCEPT ![1] = @ \cup {"mark"} \cup Opt(b.hasRollback, {"rollback"})]

\* Literally: "Units is the one-element sequence of {"change"} if the batch
\*   has a change, else empty."
\* In English: a UTxO change and its journal record in a transaction that
\* leaves the tip alone [D1].
Units == IF b.hasChange THEN <<{"change"}>> ELSE <<>>

\* Literally: "Chunked(S) is: if the batch has a change, a transaction with
\*   the mark and the change followed by one with S less the change plus
\*   the clear; else the single transaction S."
\* In English: the plan of a batch none of whose ops are extracted: the
\* change goes first under the mark, the rest and the tip last.
Chunked(S) ==
    IF b.hasChange
    THEN <<{"mark", "change"}, (S \ {"change"}) \cup {"clear"}>>
    ELSE <<S>>

\* Literally: "Plan is defined by cases on the shape and the flags."
\* In English: the transactions applyChunked writes [D1]. A batch within
\* budget is one transaction. One over budget with ops, in a version that
\* extracts them, leads with them; without ops, the rollback may be lost.
\* A version that does not extract them keeps them in the last transaction.
Plan ==
    CASE ~b.overBudget -> <<AllSteps>>
      [] HasOps /\ ExtractOps ->
            Lead \o Units
                 \o <<(AllSteps \ (LeadSteps \cup {"rollback", "change"}))
                      \cup {"clear"}>>
      [] OTHER ->
            Chunked(AllSteps \ Opt(Dropped /\ ~HasOps, {"rollback"}))

\* Literally: "TooBig(T) is: the batch is over budget, T holds an op and
\*   T holds the epoch row."
\* In English: a transaction with the ops beside the batch's other rows
\* fails with ErrTxnTooBig, on every attempt.
TooBig(T) == b.overBudget /\ T \cap OpSteps # {} /\ "epoch" \in T

\* Literally: "Base is the record of the journaled fields before the
\*   batch."
\* In English: no fee row, no count, no counted slot.
Base == [feeKnown |-> FALSE, fee |-> 0, count |-> 0, next |-> FALSE]

\* Literally: "Init0 is the record of the store before the batch."
\* In English: the old tip, no mark, a nonce the batch's rollback must
\* delete when it has one, and nothing the batch writes.
Init0 == [tip |-> "old", mark |-> FALSE, nonce |-> b.hasRollback,
          epochRow |-> FALSE, snap |-> FALSE, snapPast |-> FALSE,
          feeKnown |-> FALSE, fee |-> 0, count |-> 0, next |-> FALSE,
          utxo |-> FALSE, record |-> FALSE,
          hasSaved |-> FALSE, saved |-> Base]

\* Literally: "Journaled(s) is the record of s's four journaled fields."
Journaled(s) == [feeKnown |-> s.feeKnown, fee |-> s.fee,
                 count |-> s.count, next |-> s.next]

\* Literally: "Save(s) is s with saved set to its journaled fields and
\*   hasSaved TRUE, if the entries lie past the tip and none are saved yet;
\*   else s."
\* In English: the first journaled write past the tip records what a
\* rollback to the tip restores; later ones keep it.
Save(s) ==
    IF b.entries = "pastTip" /\ ~s.hasSaved
    THEN [s EXCEPT !.hasSaved = TRUE, !.saved = Journaled(s)]
    ELSE s

\* Literally: "Do(s, x) is the store after step x, by cases on x."
\* In English: one write [D2, D3, D5]. The rollback undoes every journaled
\* row above its slot, which is all the batch wrote, and deletes the
\* snapshot rows of the epoch with no epoch row yet [D4]. A Fee op adds only
\* to a fee row that exists; a count is a no-op once counted.
Do(s, x) ==
    CASE x = "mark" -> [s EXCEPT !.mark = TRUE]
      [] x = "clear" -> [s EXCEPT !.mark = FALSE]
      [] x = "rollback" ->
            [s EXCEPT !.nonce = FALSE, !.feeKnown = Base.feeKnown,
                      !.fee = Base.fee, !.count = Base.count,
                      !.next = Base.next, !.hasSaved = FALSE,
                      !.snap = IF s.epochRow THEN s.snap ELSE FALSE,
                      !.snapPast = FALSE]
      [] x = "epoch" -> [s EXCEPT !.epochRow = TRUE]
      [] x = "snap" ->
            [s EXCEPT !.snap = TRUE, !.snapPast = (b.entries = "pastTip")]
      [] x = "row" -> [Save(s) EXCEPT !.feeKnown = TRUE, !.fee = 0]
      [] x = "open" ->
            IF s.feeKnown THEN s
            ELSE [Save(s) EXCEPT !.feeKnown = TRUE, !.fee = 0]
      [] x = "fee" ->
            IF s.feeKnown THEN [Save(s) EXCEPT !.fee = s.fee + F] ELSE s
      [] x = "count" ->
            IF s.next THEN s
            ELSE [Save(s) EXCEPT !.count = s.count + 1, !.next = TRUE]
      [] x = "change" -> [s EXCEPT !.utxo = TRUE, !.record = TRUE]
      [] x = "tip" ->
            [s EXCEPT !.tip = "new", !.record = FALSE, !.hasSaved = FALSE,
                      !.snapPast = FALSE]

\* Literally: "Fold(s, T, i) is s if i is past the end of Order, else
\*   Fold of (Do(s, Order[i]) if Order[i] is in T, else s), T and i + 1."
\* In English: apply transaction T's writes in Order.
RECURSIVE Fold(_, _, _)
Fold(s, T, i) ==
    IF i > Len(Order) THEN s
    ELSE Fold(IF Order[i] \in T THEN Do(s, Order[i]) ELSE s, T, i + 1)

\* Literally: "Expected is Fold of Init0, AllSteps, 1."
\* In English: the store after the batch applied once, in one transaction.
Expected == Fold(Init0, AllSteps, 1)

\* Literally: "Proj(s) is the record of s's fields a reader sees."
\* In English: the store's contents, without the bookkeeping.
Proj(s) == [tip |-> s.tip, nonce |-> s.nonce, epochRow |-> s.epochRow,
            snap |-> s.snap, feeKnown |-> s.feeKnown, fee |-> s.fee,
            count |-> s.count, utxo |-> s.utxo]

\* Literally: "Found(s) is: s has a record past the tip, or the version
\*   finds journal entries past the tip and s has some, or it finds capture
\*   index entries past the tip and s has one."
\* In English: whether PointBefore(mark) returns a point [D4]. A record
\* past the tip is at or after the mark, which takes the change's slot.
\* RewindStrayCapture is an alternative Dingo does not take: a startup
\* rollback would then delete every stray snapshot row in one transaction,
\* while the replay rewrites the same rows anyway.
Found(s) ==
    \/ s.record
    \/ RewindStoppedBeforeRecord /\ s.hasSaved
    \/ RewindStrayCapture /\ s.snapPast

\* Literally: "RollbackToTip(s) is s with the saved journaled fields
\*   restored, the change and its record undone, and the snapshot rows
\*   deleted when no epoch row covers them."
\* In English: Rollback(tip) [D4]. Entries at or below the tip stay.
RollbackToTip(s) ==
    LET j == IF s.hasSaved THEN s.saved ELSE Journaled(s)
    IN [s EXCEPT !.feeKnown = j.feeKnown, !.fee = j.fee, !.count = j.count,
                 !.next = j.next, !.hasSaved = FALSE, !.utxo = FALSE,
                 !.record = FALSE,
                 !.snap = IF s.epochRow THEN s.snap ELSE FALSE,
                 !.snapPast = FALSE]

\* Literally: "Init: b is a shape whose entries are past the tip unless it
\*   rolls back, st is Init0, pc is 1, phase is "run", crashes is 0."
Init == /\ b \in {s \in Shapes : s.entries = "belowTip" => s.hasRollback}
        /\ st = Init0
        /\ pc = 1
        /\ phase = "run"
        /\ crashes = 0

\* Literally: "Commit: phase is "run"; if Plan[pc] is too big, phase
\*   becomes "toobig"; else st becomes Fold(st, Plan[pc], 1), pc grows by
\*   one, and phase becomes "done" after the last."
\* In English: one transaction of the plan commits, or fails for size.
Commit ==
    /\ phase = "run"
    /\ IF TooBig(Plan[pc])
       THEN /\ phase' = "toobig"
            /\ UNCHANGED <<b, st, pc, crashes>>
       ELSE /\ st' = Fold(st, Plan[pc], 1)
            /\ pc' = pc + 1
            /\ phase' = IF pc = Len(Plan) THEN "done" ELSE "run"
            /\ UNCHANGED <<b, crashes>>

\* Literally: "Crash: phase is "run", fewer than MaxCrashes crashes so
\*   far; phase becomes "crashed" and crashes grows by one."
\* In English: the process stops between two transactions.
Crash ==
    /\ phase = "run"
    /\ crashes < MaxCrashes
    /\ phase' = "crashed"
    /\ crashes' = crashes + 1
    /\ UNCHANGED <<b, st, pc>>

\* Literally: "Restart: phase is "crashed"; st becomes, when it has a mark,
\*   RollbackToTip(st) if Found(st) else st, with the mark cleared."
\* In English: startup's rewindFailed, then the mark cleared once the set
\* and ledger agree [D4].
Restart ==
    /\ phase = "crashed"
    /\ st' = IF st.mark
             THEN [(IF Found(st) THEN RollbackToTip(st) ELSE st)
                   EXCEPT !.mark = FALSE]
             ELSE st
    /\ phase' = "recovered"
    /\ UNCHANGED <<b, pc, crashes>>

\* Literally: "Replay: phase is "recovered"; pc becomes 1 and phase "run"."
\* In English: the ledger applies the same batch again from its start.
Replay ==
    /\ phase = "recovered"
    /\ pc' = 1
    /\ phase' = "run"
    /\ UNCHANGED <<b, st, crashes>>

\* Literally: "Finished: phase is "done" or "toobig" and nothing changes."
\* In English: the end of a behaviour; not a deadlock.
Finished == phase \in {"done", "toobig"} /\ UNCHANGED vars

\* Literally: "Next is one of the five actions."
Next == Commit \/ Crash \/ Restart \/ Replay \/ Finished

\* Literally: "Spec is Init and always Next or vars unchanged."
Spec == Init /\ [][Next]_vars

\* Literally: "NeverTooBig: phase is not "toobig"."
\* In English: every transaction of the plan fits.
NeverTooBig == phase # "toobig"

\* Literally: "ReplayEqualsOnce: when done, Proj(st) equals
\*   Proj(Expected)."
\* In English: any crashes, rewinds and second applications leave the
\* store as one atomic application would.
ReplayEqualsOnce == phase = "done" => Proj(st) = Proj(Expected)

\* Literally: "FeeOnce: when done, st.fee is at most Expected.fee."
\* In English: a Fee op is never added twice.
FeeOnce == phase = "done" => st.fee <= Expected.fee

\* Literally: "FeeCounted: when done, st.fee is at least Expected.fee."
\* In English: a Fee op is never lost to a fee row created after it.
FeeCounted == phase = "done" => st.fee >= Expected.fee

\* Literally: "RollbackKept: when done and the batch rolls back, the nonce
\*   above the rollback is gone."
\* In English: the batch's DeleteNoncesAfter is never dropped.
RollbackKept == phase = "done" /\ b.hasRollback => ~st.nonce

\* Literally: "SnapshotFollowsTip: once recovered, with entries past the
\*   tip, a snapshot row exists only beside its epoch row."
\* In English: after the startup rewind and before the batch is applied
\* again, the store holds no snapshot rows of an epoch its tip has not
\* reached.
SnapshotFollowsTip ==
    phase = "recovered" /\ b.entries = "pastTip" => (st.snap => st.epochRow)
=============================================================================
