# Agent instructions

This repository holds TLA+ models of Dingo, the Go Cardano node from Blink
Labs. It mirrors `gouroboros-tla-models`. That repository models gOuroboros:
the protocols, the ledger rules, consensus and its concurrency. This one models
what Dingo builds on top of it: how Dingo drives gOuroboros's callbacks, its
mempool, chain selection, its storage and its node lifecycle. A rule that
belongs to gOuroboros is modelled there and only referred to here.

Its audience is engineers who are new to TLA+, so readability beats
cleverness.

- Install tools with `make install`; never install Java or TLA+ system-wide.
  `.tools` may be a symlink to the gOuroboros models repository's copy.
- Run `make check` before committing a model. `scripts/run-model.sh
  specs/<dir>` checks one directory; `*Bug.cfg` configs must fail by a
  violation or a deadlock.
- One directory per model under `specs/`, with no number prefix.
- Every definition carries two comments: an `In English:` reading of the
  whole definition, and a `Literally:` symbol-by-symbol reading ("for all x
  in S there exists a y such that ..."). Comment every new TLA+ construct the
  first time a model uses it, and add new terms to `docs/glossary.md`.
- Cite a source for every rule before writing it: the reference
  implementation (cardano-node, ouroboros-network, ouroboros-consensus,
  cardano-ledger) pinned to a commit, with file and line numbers. Name the
  Dingo file a model is based on in the module header. A rule with no source
  is marked UNSOURCED with the reason.
- When in doubt, do what the reference implementation does.
- Model-driven TDD: reproduce a defect here first, with a config of Dingo's
  current behaviour that fails, before writing the Dingo test or the fix.
  Then switch to the fixed config, which passes, and keep the failing one as
  `*Bug.cfg`.
- Record every difference from the reference in `DRIFT.md`, and every Dingo
  pull request a model is responsible for in `PRS.md`.
- This repository is unpublished. Nothing published (code comments, commits,
  issues, pull requests, reviews) may mention it, TLA+, TLC, `specs/` paths,
  config names or invariant names.
- Conventional Commits with DCO sign-off (`git commit -s`).
