# txsize-framing

Dingo's `txsize.FromCBOR` for Shelley, Allegra and Mary (types 1-3): the size
is the received length on main, so it depends on the outer array framing. The
reference measures one header byte plus the three components.

| Config | Expected |
| --- | --- |
| `TxSizeFramingDingoBug` | fails `SizeAsReference` |
| `TxSizeFramingDingoIndependenceBug` | fails `FramingIndependent` |
| `TxSizeFramingFixed` | passes all four invariants |
| `TxSizeFramingMainOtherUnchanged` | passes: Alonzo/Conway and the fallback are unchanged by the fix |
