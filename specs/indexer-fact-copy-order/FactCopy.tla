---------------------------- MODULE FactCopy ----------------------------
(***************************************************************************)
(* One segment of Dingo's IndexerDB catch-up: the ledger's reward credits  *)
(* dated in the segment are replayed first, then the segment's blocks are  *)
(* indexed (certificates and withdrawals), then the patch step runs, all   *)
(* in one write transaction that is rolled back whole on any failure and  *)
(* run again.                                                              *)
(*                                                                         *)
(* One reward account is followed through a sequence of transactions, each *)
(* a registration, a Dijkstra direct deposit, or a withdrawal.             *)
(*                                                                         *)
(* Dingo sources (blinklabs-io/dingo, commit eae4caf93):                   *)
(*   [D1] internal/indexer/writer.go, the batch closure: per segment       *)
(*        copyFacts, indexBlocks, patchFacts, one transaction.             *)
(*   [D2] internal/indexer/facts.go CopyFacts and applyRewardCredits: the  *)
(*        credit journal rows dated in the segment are credited through    *)
(*        AddAccountRewardsByCredential, which fails with                  *)
(*        ErrAccountNotFound for an account the IndexerDB does not hold.   *)
(*   [D3] database/plugin/metadata/sqlstore/transaction_write.go           *)
(*        applyTransactionWithdrawals: a withdrawal that exceeds the       *)
(*        account's balance fails with ErrRewardWithdrawalExceedsBalance;  *)
(*        a transaction's withdrawals are applied before its               *)
(*        certificates.                                                    *)
(*   [D4] ledger/delta.go and ledger/dijkstra_direct_deposit.go: the       *)
(*        ledger credits a direct deposit after the transaction's          *)
(*        certificates and journals it at the transaction's slot.          *)
(*   [D5] database/plugin/metadata/sqlstore/account.go: a credit is        *)
(*        journaled under a unique key and applied once.                   *)
(*                                                                         *)
(* Reference: cardano-ledger 9e272f774431,                                 *)
(* eras/dijkstra/impl/src/Cardano/Ledger/Dijkstra/Rules/Entities.hs        *)
(* dijkstraEntitiesTransition, lines 276-314: withdrawals are applied      *)
(* first, then the certificates, then the direct deposits are checked      *)
(* against the accounts as the certificates left them                      *)
(* (validateMissingAccountsInDirectDeposits) and applied last. A deposit   *)
(* to an account the same transaction registers is valid, and the credit   *)
(* is visible to the next transaction's withdrawals.                       *)
(*                                                                         *)
(* Symbols are read as in specs/hello/Hello.tla.                           *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    Mode,        \* "Dingo", "Defer", "Fixed" or "FixedNoDedup"; see the configs
    MaxTxs,      \* longest transaction sequence of a segment
    MaxCrashes   \* rolled-back attempts per behaviour

\* In English: Dingo replays every credit first; Defer holds a credit whose
\* account is missing until the blocks are indexed; Fixed also credits a
\* direct deposit inside block indexing, in transaction order, and lets the
\* held replay pass find it already journaled.
ASSUME /\ Mode \in {"Dingo", "Defer", "Fixed", "FixedNoDedup"}
       /\ MaxTxs \in Nat /\ MaxCrashes \in Nat

Kinds == {"reg", "dep", "wd"}

\* Literally: "AllSeqs is the set of every sequence over Kinds whose length
\*   is between 1 and MaxTxs."
AllSeqs == UNION {[1..n -> Kinds] : n \in 1..MaxTxs}

\* In English: the ledger's account after the first k transactions of s,
\* from an account that starts registered with balance b0, or unregistered.
\* ok is FALSE once a transaction is invalid under the reference rules above:
\* a withdrawal needs a balance of at least 1 (it takes 1), a deposit needs
\* the account registered after the transaction's own certificates, and a
\* registration needs it unregistered.
RECURSIVE Led(_, _, _, _)
Led(s, k, r0, b0) ==
    IF k = 0 THEN [ok |-> TRUE, reg |-> r0, bal |-> b0]
    ELSE LET p == Led(s, k - 1, r0, b0)
         IN IF ~p.ok THEN p
            ELSE CASE s[k] = "reg" ->
                        IF p.reg THEN [p EXCEPT !.ok = FALSE]
                        ELSE [ok |-> TRUE, reg |-> TRUE, bal |-> 0]
                   [] s[k] = "dep" ->
                        IF ~p.reg THEN [p EXCEPT !.ok = FALSE]
                        ELSE [p EXCEPT !.bal = p.bal + 1]
                   [] s[k] = "wd" ->
                        IF ~p.reg \/ p.bal < 1 THEN [p EXCEPT !.ok = FALSE]
                        ELSE [p EXCEPT !.bal = p.bal - 1]

VARIABLES
    txs,        \* the segment's transactions, in block order
    reg0,       \* the account is in the IndexerDB when the segment starts
    bal0,       \* its balance then
    idxReg,     \* the account is in the IndexerDB now
    idxBal,     \* its balance now
    journal,    \* positions of the deposits already credited
    held,       \* positions of the deposits the replay held back
    phase,      \* "replay", "blocks", "patch" or "done"
    pos,        \* the next transaction block indexing takes
    failed,     \* the transaction failed, so the catch-up retries forever
    crashes     \* rolled-back attempts so far

vars == <<txs, reg0, bal0, idxReg, idxBal, journal, held, phase, pos,
          failed, crashes>>

\* In English: the positions of the segment's direct deposits, which is what
\* the ledger's credit journal holds for the segment [D4].
Deps == {k \in 1..Len(txs) : txs[k] = "dep"}

Valid(s, r0, b0) == Led(s, Len(s), r0, b0).ok

\* In English: every segment the ledger accepts, from an unregistered
\* account, or a registered one holding 0 or 1.
Init ==
    /\ txs \in AllSeqs
    /\ \E r \in BOOLEAN, b \in {0, 1} :
         /\ (r \/ b = 0)
         /\ Valid(txs, r, b)
         /\ reg0 = r /\ bal0 = b
         /\ idxReg = r /\ idxBal = b
    /\ journal = {} /\ held = {} /\ phase = "replay" /\ pos = 1
    /\ failed = FALSE /\ crashes = 0

\* In English: the replay credits each deposit through the journal [D2]. A
\* credit to an account the IndexerDB does not hold has no row to credit.
Replay ==
    /\ phase = "replay" /\ ~failed
    /\ IF idxReg
          THEN /\ journal' = Deps /\ held' = {}
               /\ idxBal' = idxBal + Cardinality(Deps)
               /\ failed' = FALSE
          ELSE IF Deps = {} THEN /\ UNCHANGED <<journal, held, idxBal, failed>>
               ELSE IF Mode = "Dingo"
                       THEN /\ failed' = TRUE
                            /\ UNCHANGED <<journal, held, idxBal>>
                       ELSE /\ held' = Deps
                            /\ UNCHANGED <<journal, idxBal, failed>>
    /\ phase' = IF failed' THEN phase ELSE "blocks"
    /\ UNCHANGED <<txs, reg0, bal0, idxReg, pos, crashes>>

\* In English: block indexing takes the next transaction [D3]. A
\* registration creates the account with nothing in it, a withdrawal debits
\* and fails past the balance, and under Fixed a deposit is credited here
\* unless the journal already holds it [D5].
Block ==
    /\ phase = "blocks" /\ ~failed
    /\ IF pos > Len(txs)
          THEN /\ phase' = "patch"
               /\ UNCHANGED <<idxReg, idxBal, journal, failed, pos>>
          ELSE /\ pos' = pos + 1
               /\ phase' = "blocks"
               /\ CASE txs[pos] = "reg" ->
                        /\ idxReg' = TRUE /\ idxBal' = 0
                        /\ UNCHANGED <<journal, failed>>
                   [] txs[pos] = "wd" ->
                        /\ IF idxBal < 1
                              THEN failed' = TRUE /\ UNCHANGED idxBal
                              ELSE failed' = FALSE /\ idxBal' = idxBal - 1
                        /\ UNCHANGED <<idxReg, journal>>
                   [] txs[pos] = "dep" ->
                        /\ IF Mode \in {"Fixed", "FixedNoDedup"}
                              THEN IF /\ pos \notin journal
                                      \/ Mode = "FixedNoDedup"
                                      THEN /\ idxBal' = idxBal + 1
                                           /\ journal' = journal \cup {pos}
                                      ELSE UNCHANGED <<idxBal, journal>>
                              ELSE UNCHANGED <<idxBal, journal>>
                        /\ UNCHANGED <<idxReg, failed>>
    /\ UNCHANGED <<txs, reg0, bal0, held, crashes>>

\* In English: the patch step credits what the replay held, once the account
\* exists, skipping a credit the journal already holds [D5]. FixedNoDedup
\* credits it again.
Patch ==
    /\ phase = "patch" /\ ~failed
    /\ LET todo == IF Mode = "FixedNoDedup" THEN held ELSE held \ journal
       IN IF todo # {} /\ ~idxReg
             THEN /\ failed' = TRUE /\ UNCHANGED <<idxBal, journal>>
             ELSE /\ failed' = FALSE
                  /\ idxBal' = idxBal + Cardinality(todo)
                  /\ journal' = journal \cup todo
    /\ held' = {} /\ phase' = IF failed' THEN phase ELSE "done"
    /\ UNCHANGED <<txs, reg0, bal0, idxReg, pos, crashes>>

\* In English: a crash, or a failure the retry meets again, rolls the whole
\* transaction back to the segment's start. Only a crash that is not a
\* deterministic failure comes back different, which the model allows by
\* letting any live attempt crash.
Crash ==
    /\ phase # "done" /\ ~failed /\ crashes < MaxCrashes
    /\ idxReg' = reg0 /\ idxBal' = bal0
    /\ journal' = {} /\ held' = {} /\ phase' = "replay" /\ pos' = 1
    /\ crashes' = crashes + 1
    /\ UNCHANGED <<txs, reg0, bal0, failed>>

Done == phase = "done" /\ UNCHANGED vars
Stuck == failed /\ UNCHANGED vars

Next == Replay \/ Block \/ Patch \/ Crash \/ Done \/ Stuck

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ phase \in {"replay", "blocks", "patch", "done"}
    /\ journal \subseteq Deps /\ held \subseteq Deps

\* In English: the catch-up never fails on a segment the ledger accepted.
\* Literally: "failed is never TRUE."
ReplaySucceeds == ~failed

\* In English: once the segment is indexed, the IndexerDB's account is the
\* ledger's: same registration, same balance.
\* Literally: "when phase is done, idxReg and idxBal equal the ledger's
\*   account after all transactions."
BalancesMatchLedger ==
    phase = "done" =>
        /\ idxReg = Led(txs, Len(txs), reg0, bal0).reg
        /\ idxBal = Led(txs, Len(txs), reg0, bal0).bal
=============================================================================
