----------------------------- MODULE TxSizeFraming ---------------------------
(***************************************************************************)
(* The size Dingo measures for a transaction from its stored bytes, and    *)
(* whether, for Shelley, Allegra and Mary, it depends on how the outer     *)
(* CBOR array of the received transaction is framed.                       *)
(*                                                                         *)
(* Sources. IntersectMBO/cardano-ledger commit 1210d37fe6bd.               *)
(*   [S1] eras/shelley/impl/src/Cardano/Ledger/Shelley/Tx.hs 155-166:      *)
(*        toCBORForSizeComputation encodes encodeListLen 3, the body, the  *)
(*        witness set, then encodeNullStrictMaybe of the auxiliary data:   *)
(*        a one-byte array header plus the three components, a missing     *)
(*        auxiliary data as one null byte.                                 *)
(*   [S2] Shelley/Tx.hs 168-177: sizeShelleyTxF is the length of that      *)
(*        encoding, not of the received bytes.                             *)
(*   [S3] eras/allegra/impl/src/Cardano/Ledger/Allegra/Tx.hs 74 and        *)
(*        eras/mary/impl/src/Cardano/Ledger/Mary/Tx.hs 71: sizeTxF is      *)
(*        sizeShelleyTxF in both eras.                                     *)
(*                                                                         *)
(* The Dingo code is FromCBOR (internal/txsize/txsize.go). It feeds        *)
(* TxSizeForFee (ledger/eras/validation.go), mempool admission             *)
(* (mempool/mempool.go rawTxSize) and the peer decode limits               *)
(* (ouroboros/peer_decode_limits.go). On main, types 1-3 return the        *)
(* length of the received bytes; Alonzo onward are measured from their     *)
(* components already, so they are outside this model's change.            *)
(* When the bytes are not exactly a three-component array, every era       *)
(* keeps the received length.                                              *)
(* Symbols are read as in specs/hello/Hello.tla.                           *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS
    Rule    \* "main": Dingo before the fix; "fixed": the branch

\* Literally: "Rules is defined as the set containing "main" and "fixed"."
\* In English: the two Dingo behaviours a configuration can pick.
Rules == {"main", "fixed"}
ASSUME Rule \in Rules

\* Literally: "FamilyEras is defined as the set containing "Shelley",
\*   "Allegra" and "Mary"."
\* In English: the eras whose size is the Shelley measure [S3]; Dingo tx
\* types 1, 2 and 3.
FamilyEras == {"Shelley", "Allegra", "Mary"}

\* Literally: "OtherEras is defined as the set containing "Alonzo" and
\*   "Conway"."
\* In English: eras the change must leave alone; their size is already
\* measured from the components.
OtherEras == {"Alonzo", "Conway"}

\* Literally: "Framings is defined as the set of the four framings."
\* In English: how the outer array is written: header 83, header 98 03,
\* header 99 00 03, or header 9f with a closing break ff.
Framings == {"definite", "wide8", "wide16", "indefinite"}

\* Literally: "Auxes is defined as the set containing "null", "map" and
\*   "mapScripts"."
\* In English: the third component is a null byte, a map, or the
\* two-element array [map, scripts] that Allegra and Mary allow.
Auxes == {"null", "map", "mapScripts"}

\* Literally: "Shapes is defined as the set containing "three" and
\*   "other"."
\* In English: the stored bytes are exactly a three-component array, or
\* something else (two or five components, trailing bytes, not an array).
Shapes == {"three", "other"}

VARIABLES era, framing, aux, shape
vars == <<era, framing, aux, shape>>

\* In English: byte lengths of the components, small stand-ins; only that
\* they stay the same across framings matters.
BodyLen == 5
WitsLen == 2

\* Literally: "AuxLen is defined as: 1 if aux is "null", 4 if "map", else 7."
\* In English: the bytes the third component occupies as received.
AuxLen == IF aux = "null" THEN 1 ELSE IF aux = "map" THEN 4 ELSE 7

\* Literally: "HeaderLen(f) is defined as: 1 if f is "definite", 3 if
\*   "wide16", else 2."
\* In English: bytes the framing adds around the components: 83; 98 03;
\* 99 00 03; or 9f plus the closing ff.
HeaderLen(f) == IF f = "definite" THEN 1 ELSE IF f = "wide16" THEN 3 ELSE 2

\* Literally: "Received(f) is defined as HeaderLen(f) plus the three
\*   component lengths."
\* In English: the length of the received bytes in framing f.
Received(f) == HeaderLen(f) + BodyLen + WitsLen + AuxLen

\* Literally: "RefSize is defined as 1 plus BodyLen plus WitsLen plus
\*   AuxLen."
\* In English: the reference size: a one-byte array header plus the three
\* components, whatever framing was received [S1, S2].
RefSize == 1 + BodyLen + WitsLen + AuxLen

\* Literally: "DingoSize(f) is defined as: Received(f) if the shape is
\*   "other"; otherwise, for a family era under Rule "main", Received(f);
\*   for a family era under "fixed", RefSize; for any other era, RefSize."
\* In English: what FromCBOR returns. Alonzo onward drop the framing
\* already, so they return RefSize under both rules; a malformed or
\* non-three-component envelope falls back to the received length.
DingoSize(f) ==
    IF shape = "other" THEN Received(f)
    ELSE IF era \in FamilyEras /\ Rule = "main" THEN Received(f)
    ELSE RefSize

\* Literally: "Init is defined as: era is any era, framing, aux and shape
\*   are members of their sets."
\* In English: pick a cell of the table.
Init == /\ era \in FamilyEras \cup OtherEras
        /\ framing \in Framings
        /\ aux \in Auxes
        /\ shape \in Shapes

\* Literally: "Next is defined as: vars is unchanged."
Next == UNCHANGED vars

\* Literally: "Spec is defined as Init and always Next or vars unchanged."
Spec == Init /\ [][Next]_vars

\* Literally: "SizeAsReference is defined as: if the shape is "three",
\*   DingoSize(framing) equals RefSize."
\* In English: a three-component transaction measures the reference size.
SizeAsReference == shape = "three" => DingoSize(framing) = RefSize

\* Literally: "FramingIndependent is defined as: if the shape is "three",
\*   DingoSize(framing) equals DingoSize("definite")."
\* In English: the same transaction re-framed measures the same size.
FramingIndependent ==
    shape = "three" => DingoSize(framing) = DingoSize("definite")

\* Literally: "OtherErasUnchanged is defined as: for an era outside the
\*   family, DingoSize(framing) equals the main result."
\* In English: Alonzo and Conway measure the same under the fix as before
\* it. Their main result is RefSize for a three-component shape and the
\* received length otherwise.
OtherErasUnchanged ==
    era \in OtherEras =>
        DingoSize(framing) = IF shape = "three" THEN RefSize
                             ELSE Received(framing)

\* Literally: "FallbackIsReceived is defined as: if the shape is "other",
\*   DingoSize(framing) equals Received(framing)."
\* In English: input that is not exactly three components keeps its
\* received length in every era.
FallbackIsReceived ==
    shape = "other" => DingoSize(framing) = Received(framing)
=============================================================================
