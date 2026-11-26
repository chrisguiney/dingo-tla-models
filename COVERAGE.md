# Coverage

Which parts of Dingo are modelled. A part that only calls into gOuroboros is
covered by the gOuroboros models repository and listed here as "upstream".

| Dingo area | Status | Model |
| --- | --- | --- |
| Tx-submission client (`ouroboros/txsubmission.go`) local stop | modelled | `txsubmission-client` |
| Chain-sync jumping dynamo stall check (`ouroboros/chainsync_jumping.go` `csjCheckDynamoStall`) | modelled | `chainsync-jumping` |
| Metadata migration lock (`database/plugin/metadata/sqlstore/migrations/lock_file_unix.go`) | modelled | `metadata-migration-lock` |
| Transaction size measure (`internal/txsize/txsize.go` `FromCBOR`), Shelley-family framing | modelled | `txsize-framing` |
| Live UTxO store chunked batch apply, reward epoch wipe and failure-mark rewind (`database/ledgerdb/badgerutxo/chunk.go` `applyChunked`, `reward.go` `wipeRewardEpochLimited`, `recovery.go` `PointBefore`) | modelled | `badgerutxo-chunked-apply` |
| Chain-sync client and jumping, the rest (`ouroboros/chainsync.go`, `chainsync/`) | gap | |
| Block-fetch client | gap | |
| Mempool | gap | |
| Chain selection (`chainselection/`) | gap | |
| Node lifecycle and shutdown order (`node.go`) | gap | |
| DMQ node-to-node (`dmq/`) | gap | |
| Protocols, ledger, consensus as implemented by gOuroboros | upstream | gouroboros-tla-models |
| IndexerDB fact copy order (`internal/indexer/facts.go`, `writer.go`) for a segment that registers and credits an account | modelled | `indexer-fact-copy-order` |
