# Dingo TLA+ models

Formal models of [Dingo](https://github.com/blinklabs-io/dingo), the Go
Cardano node. They cover what Dingo adds on top of gOuroboros. The protocols,
ledger rules and consensus that gOuroboros implements are modelled in the
sibling repository, `gouroboros-tla-models`; a model here refers to those
rather than repeating them.

**You do not need to know TLA+ to start here.** Read the gOuroboros models
repository's README and its "Reading a formula literally" section first; this
repository uses the same conventions.

## Quick start

```sh
make install     # download Java + TLA+ tools into .tools/ (or symlink the gOuroboros copy)
make hello       # check a tiny model; ends with "No error has been found."
make check       # check every config expected to pass
make models      # check every config, Bug ones expected to fail
```

## Models

### Node-to-node protocols as Dingo drives them

- [Tx-submission client](specs/txsubmission-client/README.md): what Dingo's
  mempool wait answers when its own node stops.

## Tracking

- [DRIFT.md](DRIFT.md): differences between Dingo and the reference, each
  with the spec or reference citation.
- [PRS.md](PRS.md): the Dingo pull requests each model is responsible for.
- [COVERAGE.md](COVERAGE.md): which parts of Dingo are modelled.
