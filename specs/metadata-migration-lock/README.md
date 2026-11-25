# Metadata migration lock in a shared data directory

Before Dingo migrates its SQLite metadata store, it takes a flock on `metadata.sqlite.migrate.lock` (`database/plugin/metadata/sqlstore/migrations/lock_file_unix.go`). Dingo main opened that file with `O_CREAT|O_RDWR`, mode 0600, whether or not it already existed.

A Kubernetes pod mounts its data directory with `fsGroup`. The directory is world-writable with the sticky and setgid bits (relay-a's is `drwxrwsrwt root:dingo`), and every file becomes readable and writable to the pod's group, but a file that another uid created stays owned by that uid. With `protected_regular` set (2 on Ubuntu and on this host), the kernel refuses an `O_CREAT` open of such a file, whatever its mode (Linux `fs/namei.c` `may_create_in_sticky`). The integration build therefore failed on the preview relay-b canary with "acquire lock: open metadata migration lock: open /data/metadata.sqlite.migrate.lock: permission denied". There is no Cardano reference for this lock; the rules modelled are the kernel's.

| Config | Open | protected_regular | States | Result |
| --- | --- | --- | --- | --- |
| `MigrationLockCreatBug.cfg` | `O_CREAT|O_RDWR` | yes | | **fails** `LockWhenReadable` |
| `MigrationLockCreatUnprotectedBug.cfg` | `O_CREAT|O_RDWR` | no | | **fails** `LockWhenReadable` |
| `MigrationLockFixed.cfg` | existing file without `O_CREAT`, read-only if need be | yes | 48 | passes |
| `MigrationLockFixedUnprotected.cfg` | same | no | 48 | passes |

TLC's first `CreatBug` trace is a lock file the node may read but not write. The canary's case (owner another uid, group read and write) violates the same invariant.

Reproduced in Docker with `--user 1000:1000 --read-only --cap-drop ALL --security-opt no-new-privileges`, a v0.94.2 database, a `root:1000` mode 3777 directory, and the lock file owned by uid 1001 with group read and write: the same error, byte for byte. With every file owned by 1000 (as on relay-a), the migration runs.

Dingo test: `TestFileLockerTakesAnExistingLockItCannotWrite`. Fix: local integration branch (the lock file is opened without `O_CREAT` when it exists, read-only if need be, and created 0660 with `O_EXCL` when absent).

Not modelled: SQLite's own opens. With the lock fixed, the same Docker setup fails next with "attempt to write a readonly database", because SQLite opens a `metadata.sqlite` owned by another uid with `O_CREAT` and falls back to read-only. A data directory shared this way needs its files owned by the pod's uid.

## Upgrading a store Dingo cannot write

`MetadataUpgrade.tla` follows the v0.94.2 store (schema 68) through Dingo's two opens: the pre-open check, whose failure is ignored, and the v0.94.2 ledger-state migration. When the process may not write `metadata.sqlite`, SQLite opens it read-only without saying so ([`sqlite3_open_v2`](https://sqlite.org/c3ref/open.html)), and the first migration (version 69) fails with `SQLITE_READONLY` (8), "attempt to write a readonly database". That is the preprod relay-b canary's error.

| Config | Check | Writable | Result |
| --- | --- | --- | --- |
| `MetadataUpgradeReadonlyBug.cfg` | none (Dingo main) | no | **fails** `NoMigrationWithoutWriteAccess` |
| `MetadataUpgradeFixed.cfg` | write access first | no | passes: stops naming the file |
| `MetadataUpgradeFixedWritable.cfg` | write access first | yes | passes |
| `MetadataUpgradeWritable.cfg` | none | yes | passes |

Reproduced in Docker with the pod settings, `--storage-mode api` and a v0.94.2 database whose files uid 1000 owns, with `metadata.sqlite` mode `-r--rw-r--` (group-writable through fsGroup, owner read-only). It gives the canary's exact sequence and error. With the fix the node stops at once with "/data/metadata.sqlite is not writable by uid 1000 gid 1000 (mode -r--rw-r--, owner 1000:1000)". Dingo test: `TestUnwritableReleasedStoreStopsBeforeMigrating`.

### The canary's actual cause: another uid in a sticky directory

On the relays the files are `-rw-r--r-- dingo:dingo` (1000:1000), but dingo-operator 0.5.0 runs the pod as its legacy user (uid 100, gid 101, fsGroup 101) for any image whose tag is not `major.minor.patch` (`usesLegacyDingoUser`), and the canary's tag `0474faf37-96088e569` is not. The kubelet's fsGroup change makes every file group-writable to 101, so `access(2)` allows writes. But in the sticky `/data` (set by the `data-volume-sticky-bit` init container), with `protected_regular=2`, the kernel refuses each `O_CREAT` open of a file uid 1000 owns. The lock opened with `O_CREAT` gave "permission denied" (the first canary). SQLite's main-file open with `O_CREAT` falls back to read-only, giving "attempt to write a readonly database" (the second canary). Both reproduce byte for byte in Docker with `--user 100:101 --group-add 101`, the pod's mounts and `DINGO_STORAGE_MODE=api`.

| Config | Check | Cause | Result |
| --- | --- | --- | --- |
| `MetadataUpgradeStickyBug.cfg` | `access(2)` only | sticky | **fails** `NoMigrationWithoutWriteAccess` |
| `MetadataUpgradeStickyFixed.cfg` | `access(2)` and the sticky rule | sticky | passes |
| `MetadataUpgradeStickyFixedMode.cfg` | same | mode | passes |

Dingo test: `TestStickyCreateRefused`. With the fix, the node stops at once: "/data/metadata.sqlite is not writable by uid 100 gid 101 (mode -rw-rw-r--, owner 1000:101): another uid owns it in the sticky directory /data, and fs.protected_regular=2 refuses SQLite's O_CREAT open". The node cannot repair this itself. The pod must run as the uid that owns the data.
