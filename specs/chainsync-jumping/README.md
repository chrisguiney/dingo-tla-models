# Chain-sync jumping in Dingo: replacing an idle dynamo

While Dingo syncs with chain-sync jumping, one peer, the dynamo, streams headers and the jumpers wait to be asked whether they agree with points on its chain. If the dynamo delivers nothing, nothing moves. This model checks when Dingo replaces a silent dynamo.

Dingo source: `ouroboros/chainsync_jumping.go` (`csjCheckDynamoStall`), with `Held` wired in `node.go` to `chainselection` `EagernessPaused`. Reference: ouroboros-consensus `ec239d57f618`.

Dingo recycles a dynamo once it has delivered no header, and the local chain has not advanced, for `DynamoStallTimeout` (30 s). Before the fix, the stall clock restarted whenever the selector held the dynamo's stream (the Limit on Eagerness or the catch-up band). A dynamo held before it had delivered anything was therefore never recycled. On Preview, Dingo main with gOuroboros v0.221.0 sat at its start block for 1370 s: one dynamo delivered no header for 16 minutes, 19 to 40 jumpers waited, and 0 jumps were sent.

The reference has no such exemption. A peer that has sent no header is left to the timeouts (`Genesis/Governor.hs` 393-396). The Limit on Patience bucket is paused only while the node itself is busy checking a header the peer already sent (`ChainSync/Client.hs` 1925-1938, `pauseBucket`), or while a jumper waits for an instruction (`Client.hs` 1296-1316, `Client/Jumping.hs` 90-95).

| Config | Rule | Dynamo | States | Result |
| --- | --- | --- | --- | --- |
| `CsjDynamoStallDingoBug.cfg` | a hold always excuses silence | silent | | **fails** `SilentDynamoReplaced` |
| `CsjDynamoStallDeliveredOnlyBug.cfg` | a hold excuses silence only after a verified delivery | parks its first header | | **fails** `BusyDynamoKept` |
| `CsjDynamoStallFixed.cfg` | a hold excuses silence only after the dynamo sent a header | silent | 10 | passes |
| `CsjDynamoStallFixedHonest.cfg` | same | delivers or parks | 558 | passes |
| `CsjDynamoStallReference.cfg` | reference | silent | 10 | passes |

The shortest `DingoBug` trace: the selector holds the stream of the newly elected dynamo, and every later stall check restarts the clock while the dynamo stays silent past the timeout.

Dingo test: `TestChainsyncJumpingDynamoStallCheck/a_held_dynamo_that_delivered_nothing_is_recycled` (fails on Dingo main and on the integration branch before the fix). Fix: local integration branch `46e41a232`.

Not modelled: why the selector holds a dynamo that has delivered nothing (the Limit on Eagerness computation, or a pause counter left on a replaced peer-tip record), and a dynamo held after a delivery that is never released, which the reference resolves with the density rule.

`DeliveredOnlyBug` is the fix as first written: only a verified delivery
(`csjObserveDelivery`) set the flag, but the roll-forward callback parks a
header before verifying it (header capacity, the catch-up band, the
future-header wait) while the stream is held, so a dynamo whose first header
was parked was recycled at `DynamoStallTimeout` (30 s) while the node's own
wait could run 60 s. The fix sets the flag on receipt
(`csjObserveHeaderSent`, called from `chainsyncClientRollForwardAt` before
any wait). `NodeWait` bounds a parked header; `BusyDynamoKept` says a dynamo
is not recycled while the node waits on its header. Dingo test:
`TestChainsyncJumpingDynamoStallCheck/a_held_dynamo_whose_first_header_is_parked_is_kept`.
