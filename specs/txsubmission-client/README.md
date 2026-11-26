# Tx-submission client in Dingo

Dingo drives gOuroboros's tx-submission client: its `RequestTxIdsFunc` waits on the mempool. This model checks what Dingo answers when that wait ends because its own node stops. The protocol itself is modelled in the gOuroboros models repository (`specs/txsubmission`); this one models only Dingo's side.

Dingo source: `ouroboros/txsubmission.go`. Reference: ouroboros-network `5f356486ab3e`, `Outbound.hs` and `ControlMessage.hs`.

`TxSubmissionLocalStop.tla` follows the one blocking `MsgRequestTxIds` that
the client is still answering, with an empty mempool, when its own node
stops. The reference waits for a transaction or for `Terminate`, and answers
`Terminate` with `MsgDone` (`Outbound.hs` 193-210, `ControlMessage.hs`
43-55). It never answers a blocking request with an empty list, and its stop
never reports a protocol error.

In gOuroboros the wait is the application's `RequestTxIdsFunc`. Its answer
decides what the client does: `ErrStopServerProcess` sends `MsgDone`; an
empty list is refused by `reconcileTxIds` as a protocol violation, which
the connection reports as it closes; a missing mempool consumer is an error
that is reported the same way. Dingo's wait ends when the mempool consumer
is released: the connection-closed cleanup cancels it after `Close`
returns, and node shutdown stops the mempool before draining connections.

| Config | Callback | Close joins callbacks | States | Result |
| --- | --- | --- | --- | --- |
| `TxSubmissionLocalStopReference.cfg` | reference | yes | 30 | passes |
| `TxSubmissionLocalStopMainBug.cfg` | Dingo main | no | | **fails** `LocalStopBlamesNoPeer` |
| `TxSubmissionLocalStopJoinBug.cfg` | Dingo main | yes | | **deadlock** |
| `TxSubmissionLocalStopEmptyBug.cfg` | ends on `StopChan`, empty list | yes | | **fails** `LocalStopBlamesNoPeer` |
| `TxSubmissionLocalStopFixed.cfg` | ends on any release with `ErrStopServerProcess` | yes | 30 | passes |
| `TxSubmissionLocalStopFixedNoJoin.cfg` | same | no | 34 | passes |
| `TxSubmissionLocalStopMetricBug.cfg` | same, metric exempts only chain-sync's stop | yes | | **fails** `LocalStopCountsNoError` |

`MainBug` is node shutdown on Dingo `main`: the mempool stops, the wait
returns nothing, and the empty reply closes the connection with
"blocking request for 1 transaction IDs received an empty reply". Once
`Close` waits for running callbacks, Dingo `main`'s wait, which only the
cleanup after `Close` releases, deadlocks `Close` (`JoinBug`; the Dingo
test `TestTxSubmissionServerInitExitsCleanlyOnPeerDisconnect` hung on it).
Ending the wait on `StopChan` removed the deadlock but kept the empty reply
(`EmptyBug`). The fix answers every released wait, and a blocking request
with no consumer, with `ErrStopServerProcess`, as the reference answers
`Terminate`. Dingo test:
`TestTxSubmissionClientEndsBlockingWaitWithDoneWhenMempoolStops`.


`MetricBug` is the fix as first written: `recordProtocolMessage`
(`ouroboros/metrics_protocol.go`) labels a callback's non-nil error
`outcome="error"` unless it is chain-sync's `ErrStopSyncProcess`, so every
answered stop counted as an error on shutdown. The fixed configs set
`MetricExemptsStop` and check `LocalStopCountsNoError`. Dingo test:
`TestInstrumentTxsubmissionRequestTxIds_StopIsNotAnError`.
