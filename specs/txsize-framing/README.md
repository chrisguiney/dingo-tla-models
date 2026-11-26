# txsize-framing

Dingo's `txsize.FromCBOR` for Shelley, Allegra and Mary (types 1-3): the size
is the received length on main, so it depends on the outer array framing. The
reference measures one header byte plus the three components.

| Config | Expected |
| --- | --- |
| `TxSizeFramingDingoBug` | fails `SizeAsReference` |
| `TxSizeFramingDingoIndependenceBug` | fails `FramingIndependent` |
| `TxSizeFramingDecodedTagBug` | fails `SizeAsReference`: decoded component lengths drop a tag in front of a component |
| `TxSizeFramingFixed` | passes all four invariants |
| `TxSizeFramingMainOtherUnchanged` | passes: untagged Alonzo/Conway and the fallback are unchanged by the fix |

The fix measures each component as its span of the received bytes
(`decodeComponents` in `internal/txsize/txsize.go`), so a tag in front of a
component, such as the self-describe tag 55799, counts; decoding the array into
`RawMessage` values dropped it. That applied to Alonzo onward on main too. A tag
around the whole transaction is not an outer array and keeps the received
length (not modelled). Dingo tests: `TestFromCBORCountsComponentTags`,
`TestFromCBORTaggedOuterArrayKeepsReceivedLength`.
