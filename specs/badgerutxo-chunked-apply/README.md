# badgerutxo-chunked-apply

Dingo's live UTxO store (`database/ledgerdb/badgerutxo`) writes a ledger batch
too big for one Badger transaction in several. This model applies one batch,
crashes it between any two transactions, runs the startup rewind of the
failure mark, and applies the batch again. The property is the one a single
atomic commit gives: the store ends as one application would leave it.

| Config | Expected |
| --- | --- |
| `ChunkedApplyMainBug` | fails `NeverTooBig`: main keeps every snapshot and reward block op in the last transaction (`Txn is too big` on every attempt) |
| `ChunkedApplyNoRewindBug` | fails `FeeOnce`: ops extracted ahead of the first journal record, with no rewind when no record is at or after the mark, add a fee twice |
| `ChunkedApplyRollbackDropBug` | fails `RollbackKept`: over budget with no op to extract, the batch's `DeleteNoncesAfter` is dropped |
| `ChunkedApplyOrderBug` | fails `FeeCounted`: extracted reward block ops run before the rows the last transaction carries |
| `ChunkedApplyStrayCaptureProbeBug` | fails `SnapshotFollowsTip` (probe): a stopped snapshot put is not rewound, and the replay rewrites it |
| `ChunkedApplyWipeBug` | fails `NeverTooBig`: a reward epoch wipe row is weighed as one row and deletes every output row of the epoch inside the batch's transaction, on a batch with no tip, change or failure mark |
| `ChunkedApplyWipeOrderBug` | fails `ReplayEqualsOnce`: the wipe runs ahead of the batch's rollback, which restores the rows it removed |
| `ChunkedApplyWipeFixed` | passes the same five invariants with the wipe in transactions of its own after the rollback |
| `ChunkedApplyFixed` | passes `NeverTooBig`, `ReplayEqualsOnce`, `FeeOnce`, `FeeCounted`, `RollbackKept` |
