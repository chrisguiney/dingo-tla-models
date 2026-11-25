# Drift between Dingo and the reference

Each entry: the behaviour, what the reference does (pinned source), what Dingo
does, the verdict, and the model config that shows it.

| Id | Area | Reference | Dingo | Verdict | Model |
| --- | --- | --- | --- | --- | --- |
| D1 | Tx-submission client, local stop during a blocking `MsgRequestTxIds` | Waits for a transaction or `Terminate`, and answers `Terminate` with `MsgDone` (ouroboros-network `5f356486ab3e`, `Outbound.hs` 193-210, `ControlMessage.hs` 43-55) | Dingo main answered a released wait with an empty list or an error, which gOuroboros reports as a protocol violation and the connection closes blaming the peer | Fixed on the local integration branch (`b86b031fb`): every released wait, and a blocking request with no consumer, answers `ErrStopServerProcess` | `txsubmission-client`: `MainBug`, `JoinBug`, `EmptyBug` fail; `Fixed` and `FixedNoJoin` pass |
| D2 | Chain-sync jumping, replacing a silent dynamo | A peer that has sent no header is left to the timeouts; the Limit on Patience pauses only while the node is busy with a header the peer sent (ouroboros-consensus `ec239d57f618`, `Genesis/Governor.hs` 393-396, `ChainSync/Client.hs` 1925-1938) | The stall clock restarted whenever the selector held the dynamo's stream, so a dynamo held before any delivery was never recycled (Preview: stuck 1370 s) | Fixed on the local integration branch (`46e41a232`): a hold excuses silence only after a delivery since election | `chainsync-jumping`: `DingoBug` fails; `Fixed`, `FixedHonest`, `Reference` pass |
