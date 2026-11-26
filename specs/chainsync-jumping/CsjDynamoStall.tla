--------------------------- MODULE CsjDynamoStall ---------------------------
(***************************************************************************)
(* The dynamo of chain-sync jumping, and when an idle one is replaced.     *)
(*                                                                         *)
(* While Dingo syncs with chain-sync jumping, one peer (the dynamo)        *)
(* streams headers and the others (jumpers) wait to be asked whether they  *)
(* agree with points on its chain. If the dynamo delivers nothing, nothing *)
(* moves, so a dynamo that stays silent must be replaced.                  *)
(*                                                                         *)
(* Dingo (ouroboros/chainsync_jumping.go csjCheckDynamoStall, wired in     *)
(* node.go): a timer recycles the dynamo once it has delivered no header,  *)
(* and the local chain has not advanced, for DynamoStallTimeout. The       *)
(* timer restarts whenever Held(dynamo) is true, that is whenever the      *)
(* chain selector holds the dynamo's header stream (the Limit on Eagerness *)
(* or the catch-up band, chainselection EagernessPaused).                  *)
(*                                                                         *)
(* The reference (ouroboros-consensus ec239d57f618):                       *)
(*   [R1] Genesis/Governor.hs 393-396 densityDisconnect: a peer that has   *)
(*        sent no header yet is skipped by the density rule; "They should  *)
(*        be disconnected by timeouts instead."                            *)
(*   [R2] MiniProtocol/ChainSync/Client.hs 1925-1938 pauseBucket: the      *)
(*        Limit on Patience bucket is paused only while the node itself    *)
(*        blocks checking a header the peer already sent (time            *)
(*        translation or the forecast horizon), "as our peer is not        *)
(*        responsible for this waiting time".                              *)
(*   [R3] Client.hs 1296-1316 and Client/Jumping.hs 90-95: the bucket is   *)
(*        also paused while a jumper waits for a jump instruction, and    *)
(*        resumed once the peer runs normally, as a dynamo does.           *)
(* So in the reference a dynamo's silence is excused only while the node   *)
(* is busy with a header the dynamo sent; a dynamo that has sent nothing   *)
(* is always subject to the timeout.                                       *)
(*                                                                         *)
(* A header can hold the stream before it is verified: Dingo's catch-up    *)
(* band wait (ouroboros/chainsync.go, awaitCatchUpBand in the roll-forward *)
(* handler) parks an overshooting header on the connection's callback and  *)
(* marks the stream held (node.go, Held), and only a verified header is    *)
(* reported to chain-sync jumping as delivered (csjObserveDelivery). That  *)
(* wait is bounded by the node's own limit (ouroboros/ouroboros.go, the    *)
(* catch-up band wait, twice DynamoStallTimeout), the constant NodeWait.   *)
(*                                                                         *)
(* One dynamo is followed from its election. Time is counted in ticks of   *)
(* the stall check; one tick is one check.                                 *)
(*                                                                         *)
(* Symbols are explained in specs/hello/Hello.tla's header.                *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS
    Rule,     \* "dingo" (main), "deliveredOnly" (first fix), "fixed" or "reference"
    Silent,   \* TRUE: the dynamo never delivers a header (a broken or slow peer)
    Timeout,  \* DynamoStallTimeout, in ticks
    NodeWait, \* the node's own bound on a parked header's wait, in ticks
    MaxTicks  \* bound on the ticks explored

VARIABLES
    delivered, \* the dynamo has delivered (and the node verified) a header since its election
    sent,      \* the dynamo has sent at least one header since its election, verified or not
    parked,    \* the node is waiting on a header the dynamo sent, before verifying it
    parkedFor, \* ticks the current parked header has waited
    held,      \* the chain selector holds the dynamo's header stream
    idle,      \* ticks since the stall clock last restarted
    silentFor, \* ticks since the dynamo last delivered a header (or was elected)
    recycled,  \* the stall check has recycled the dynamo
    ticks      \* ticks so far (model bound only)

\* Literally: "vars is defined as the tuple of the nine variables."
vars == <<delivered, sent, parked, parkedFor, held, idle, silentFor,
          recycled, ticks>>

\* In English: "Every variable holds a value of the right kind."
\* Literally: "TypeOK is defined as: delivered, sent, parked, held and
\*   recycled are booleans, and parkedFor, idle, silentFor and ticks are
\*   natural numbers."
TypeOK ==
    /\ delivered \in BOOLEAN /\ sent \in BOOLEAN /\ parked \in BOOLEAN
    /\ held \in BOOLEAN /\ recycled \in BOOLEAN
    /\ parkedFor \in Nat /\ idle \in Nat /\ silentFor \in Nat /\ ticks \in Nat

\* In English: "The dynamo has just been elected: it has sent nothing,
\* nothing holds it, and its clocks are at zero."
\* Literally: "Init is defined as: delivered, sent, parked and held are
\*   FALSE, and parkedFor, idle, silentFor and ticks equal 0, and recycled
\*   is FALSE."
Init ==
    /\ delivered = FALSE /\ sent = FALSE /\ parked = FALSE /\ held = FALSE
    /\ parkedFor = 0
    /\ idle = 0 /\ silentFor = 0 /\ ticks = 0
    /\ recycled = FALSE
-----------------------------------------------------------------------------
\* In English: "Does the rule excuse the dynamo's silence on this check?
\* Dingo main excuses it whenever the stream is held. The first fix excused
\* it only when the stream is held after a verified delivery, which misses
\* a header parked before verification. The reference, and the fix, excuse
\* it when the stream is held after the dynamo sent a header, the only time
\* the node can be busy with one [R2]."
\* Literally: "Excused is defined as: if Rule equals "dingo" then held,
\*   else if Rule equals "deliveredOnly" then held and delivered, else held
\*   and sent."
Excused ==
    CASE Rule = "dingo"         -> held               \* held restarts the clock
      [] Rule = "deliveredOnly" -> held /\ delivered   \* csjObserveDelivery only
      [] OTHER                  -> held /\ sent        \* [R1][R2]

\* In English: "The dynamo delivers a header that is verified at once,
\* unless it is silent or its stream is held. Both clocks restart."
\* Literally: "Deliver is defined as: Silent is FALSE, and held is FALSE,
\*   and recycled is FALSE, and delivered and sent in the next state are
\*   TRUE, and idle and silentFor in the next state are 0, and the other
\*   variables are unchanged."
Deliver ==
    /\ ~Silent /\ ~held /\ ~recycled
    /\ delivered' = TRUE /\ sent' = TRUE
    /\ idle' = 0 /\ silentFor' = 0
    /\ UNCHANGED <<parked, parkedFor, held, recycled, ticks>>

\* In English: "The dynamo sends a header past the catch-up band. The node
\* parks it on the connection's callback before verifying it, and the
\* stream is held while it waits. Chain-sync jumping has not seen a
\* delivery yet."
\* Literally: "SendParks is defined as: Silent is FALSE, and held is FALSE,
\*   and recycled is FALSE, and sent, parked and held in the next state are
\*   TRUE, and parkedFor in the next state is 0, and the other variables
\*   are unchanged."
SendParks ==
    /\ ~Silent /\ ~held /\ ~recycled
    /\ sent' = TRUE /\ parked' = TRUE /\ held' = TRUE
    /\ parkedFor' = 0
    /\ UNCHANGED <<delivered, idle, silentFor, recycled, ticks>>

\* In English: "The parked header's wait ends: the ledger caught up, or the
\* node's own bound ran out. The header is verified and delivered, the
\* hold ends and both clocks restart."
\* Literally: "Unpark is defined as: parked is TRUE, and recycled is
\*   FALSE, and parked and held in the next state are FALSE, and delivered
\*   in the next state is TRUE, and parkedFor, idle and silentFor in the
\*   next state are 0, and sent, recycled and ticks are unchanged."
Unpark ==
    /\ parked /\ ~recycled
    /\ parked' = FALSE /\ held' = FALSE /\ delivered' = TRUE
    /\ parkedFor' = 0 /\ idle' = 0 /\ silentFor' = 0
    /\ UNCHANGED <<sent, recycled, ticks>>

\* In English: "The selector starts or stops holding the stream. In Dingo
\* this can happen before the dynamo has delivered anything (the run it
\* stalled showed a dynamo held with no header for 16 minutes)."
\* A parked header keeps the stream held until its wait ends.
\* Literally: "Hold is defined as: recycled is FALSE, and parked is FALSE,
\*   and held in the next state is not held, and the other variables are
\*   unchanged."
Hold ==
    /\ ~recycled /\ ~parked
    /\ held' = ~held
    /\ UNCHANGED <<delivered, sent, parked, parkedFor, idle, silentFor,
                   recycled, ticks>>

\* In English: "One stall check. The clock restarts if the rule excuses
\* the silence, and otherwise advances; past the timeout the dynamo is
\* recycled."
\* Literally: "Tick is defined as: recycled is FALSE, and ticks is less
\*   than MaxTicks, and, letting next be (if Excused then 0 else idle plus
\*   1): idle in the next state equals next, and recycled in the next state
\*   equals (next is greater than Timeout), and silentFor in the next state
\*   equals silentFor plus 1, and ticks in the next state equals ticks plus
\*   1, and parkedFor in the next state equals (if parked then parkedFor
\*   plus 1, else 0), and parkedFor is below NodeWait if parked, and
\*   delivered, sent, parked and held are unchanged."
\* The parked header's wait ends (Unpark) before it exceeds NodeWait.
Tick ==
    /\ ~recycled /\ ticks < MaxTicks
    /\ parked => parkedFor < NodeWait
    /\ LET next == IF Excused THEN 0 ELSE idle + 1
       IN /\ idle' = next
          /\ recycled' = (next > Timeout)
    /\ silentFor' = silentFor + 1
    /\ ticks' = ticks + 1
    /\ parkedFor' = IF parked THEN parkedFor + 1 ELSE 0
    /\ UNCHANGED <<delivered, sent, parked, held>>

\* In English: "Once the dynamo is recycled, or the tick bound is reached,
\* nothing changes any more." This tells TLC that this is an expected
\* ending, not a deadlock.
\* Literally: "Finished is defined as: recycled is TRUE or ticks equals
\*   MaxTicks, and vars is unchanged."
Finished ==
    /\ recycled \/ ticks = MaxTicks
    /\ UNCHANGED vars

\* Literally: "Next is defined as: Deliver, or SendParks, or Unpark, or
\*   Hold, or Tick, or Finished."
Next == Deliver \/ SendParks \/ Unpark \/ Hold \/ Tick \/ Finished

\* Literally: "Spec is defined as: Init holds at the start, and always,
\*   every step is a Next step or leaves vars unchanged."
Spec == Init /\ [][Next]_vars
-----------------------------------------------------------------------------
\* In English: "A dynamo that has sent nothing since its election is
\* recycled within one check after the timeout [R1]."
\* Literally: "SilentDynamoReplaced is defined as: if sent is FALSE and
\*   recycled is FALSE, then silentFor is at most Timeout plus 1."
SilentDynamoReplaced ==
    (~sent /\ ~recycled) => silentFor <= Timeout + 1

\* In English: "A dynamo is never recycled while the node itself is still
\* waiting on a header it sent: the peer is not responsible for that
\* wait [R2]."
\* Literally: "BusyDynamoKept is defined as: not (recycled and parked)."
BusyDynamoKept == ~(recycled /\ parked)
=============================================================================
