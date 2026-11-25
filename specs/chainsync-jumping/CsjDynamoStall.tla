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
(* is busy with a header the dynamo delivered; a dynamo that has delivered *)
(* nothing is always subject to the timeout.                               *)
(*                                                                         *)
(* One dynamo is followed from its election. Time is counted in ticks of   *)
(* the stall check; one tick is one check.                                 *)
(*                                                                         *)
(* Symbols are explained in specs/hello/Hello.tla's header.                *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS
    Rule,     \* "dingo" (as it is now), "fixed", or "reference"
    Silent,   \* TRUE: the dynamo never delivers a header (a broken or slow peer)
    Timeout,  \* DynamoStallTimeout, in ticks
    MaxTicks  \* bound on the ticks explored

VARIABLES
    delivered, \* the dynamo has delivered at least one header since its election
    held,      \* the chain selector holds the dynamo's header stream
    idle,      \* ticks since the stall clock last restarted
    silentFor, \* ticks since the dynamo last delivered a header (or was elected)
    recycled,  \* the stall check has recycled the dynamo
    ticks      \* ticks so far (model bound only)

\* Literally: "vars is defined as the tuple of the six variables."
vars == <<delivered, held, idle, silentFor, recycled, ticks>>

\* In English: "Every variable holds a value of the right kind."
\* Literally: "TypeOK is defined as: delivered, held and recycled are
\*   booleans, and idle, silentFor and ticks are natural numbers."
TypeOK ==
    /\ delivered \in BOOLEAN /\ held \in BOOLEAN /\ recycled \in BOOLEAN
    /\ idle \in Nat /\ silentFor \in Nat /\ ticks \in Nat

\* In English: "The dynamo has just been elected: it has delivered nothing,
\* nothing holds it, and its clocks are at zero."
\* Literally: "Init is defined as: delivered is FALSE, and held is FALSE,
\*   and idle, silentFor and ticks equal 0, and recycled is FALSE."
Init ==
    /\ delivered = FALSE /\ held = FALSE
    /\ idle = 0 /\ silentFor = 0 /\ ticks = 0
    /\ recycled = FALSE
-----------------------------------------------------------------------------
\* In English: "Does the rule excuse the dynamo's silence on this check?
\* Dingo excuses it whenever the stream is held; the reference, and the fix,
\* only when the stream is held after the dynamo delivered a header, the
\* only time the node can be busy with one [R2]."
\* Literally: "Excused is defined as: if Rule equals "dingo" then held,
\*   else held and delivered."
Excused ==
    IF Rule = "dingo" THEN held          \* csjCheckDynamoStall: held restarts the clock
                      ELSE held /\ delivered   \* [R1][R2]

\* In English: "The dynamo delivers a header, unless it is silent or its
\* stream is held. Both clocks restart."
\* Literally: "Deliver is defined as: Silent is FALSE, and held is FALSE,
\*   and recycled is FALSE, and delivered in the next state is TRUE, and
\*   idle and silentFor in the next state are 0, and held, recycled and
\*   ticks are unchanged."
Deliver ==
    /\ ~Silent /\ ~held /\ ~recycled
    /\ delivered' = TRUE
    /\ idle' = 0 /\ silentFor' = 0
    /\ UNCHANGED <<held, recycled, ticks>>

\* In English: "The selector starts or stops holding the stream. In Dingo
\* this can happen before the dynamo has delivered anything (the run it
\* stalled showed a dynamo held with no header for 16 minutes)."
\* Literally: "Hold is defined as: recycled is FALSE, and held in the next
\*   state is not held, and the other variables are unchanged."
Hold ==
    /\ ~recycled
    /\ held' = ~held
    /\ UNCHANGED <<delivered, idle, silentFor, recycled, ticks>>

\* In English: "One stall check. The clock restarts if the rule excuses
\* the silence, and otherwise advances; past the timeout the dynamo is
\* recycled."
\* Literally: "Tick is defined as: recycled is FALSE, and ticks is less
\*   than MaxTicks, and, letting next be (if Excused then 0 else idle plus
\*   1): idle in the next state equals next, and recycled in the next state
\*   equals (next is greater than Timeout), and silentFor in the next state
\*   equals silentFor plus 1, and ticks in the next state equals ticks plus
\*   1, and delivered and held are unchanged."
Tick ==
    /\ ~recycled /\ ticks < MaxTicks
    /\ LET next == IF Excused THEN 0 ELSE idle + 1
       IN /\ idle' = next
          /\ recycled' = (next > Timeout)
    /\ silentFor' = silentFor + 1
    /\ ticks' = ticks + 1
    /\ UNCHANGED <<delivered, held>>

\* In English: "Once the dynamo is recycled, or the tick bound is reached,
\* nothing changes any more." This tells TLC that this is an expected
\* ending, not a deadlock.
\* Literally: "Finished is defined as: recycled is TRUE or ticks equals
\*   MaxTicks, and vars is unchanged."
Finished ==
    /\ recycled \/ ticks = MaxTicks
    /\ UNCHANGED vars

\* Literally: "Next is defined as: Deliver, or Hold, or Tick, or Finished."
Next == Deliver \/ Hold \/ Tick \/ Finished

\* Literally: "Spec is defined as: Init holds at the start, and always,
\*   every step is a Next step or leaves vars unchanged."
Spec == Init /\ [][Next]_vars
-----------------------------------------------------------------------------
\* In English: "A dynamo that has delivered nothing since its election is
\* recycled within one check after the timeout [R1]."
\* Literally: "SilentDynamoReplaced is defined as: if delivered is FALSE
\*   and recycled is FALSE, then silentFor is at most Timeout plus 1."
SilentDynamoReplaced ==
    (~delivered /\ ~recycled) => silentFor <= Timeout + 1
=============================================================================
