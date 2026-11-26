# indexer-fact-copy-order

One segment of Dingo's IndexerDB catch-up: the ledger's reward credits dated
in the segment are replayed, the segment's blocks are indexed, and the patch
step runs, in one transaction that rolls back whole on a failure. One reward
account is followed through registrations, Dijkstra direct deposits and
withdrawals, under the order the reference applies them in (withdrawals, then
certificates, then direct deposits, per transaction).

| Config | Expected |
| --- | --- |
| `FactCopyDingoBug` | fails `ReplaySucceeds`: a deposit to an account the segment registers is replayed before the account exists (`<<reg, dep>>`) |
| `FactCopyDeferOnlyBug` | fails `ReplaySucceeds`: holding the credit until the blocks are indexed leaves a later withdrawal short (`<<reg, dep, wd>>`) |
| `FactCopyNoDedupBug` | fails `BalancesMatchLedger`: crediting in block order without the journal skip on the held replay credits a deposit twice |
| `FactCopyFixed` | passes `TypeOK`, `ReplaySucceeds`, `BalancesMatchLedger`, with up to two rolled-back attempts |
