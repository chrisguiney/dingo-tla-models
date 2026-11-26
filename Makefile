.DEFAULT_GOAL := help
SHELL := bash

# Every model is a .cfg file under specs/. A config whose name ends in Bug.cfg
# is expected to FAIL (a mutation, a known bug, or a reachability probe).
CONFIGS := $(filter-out %Bug.cfg,$(wildcard specs/*/*.cfg))

.PHONY: help install hello hello-bug txsubmission-client chainsync-jumping metadata-migration-lock badgerutxo-chunked-apply indexer-fact-copy-order models check clean

help: ## Show this list
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-20s %s\n", $$1, $$2}'

install: ## Download Java + TLA+ tools into .tools/ (no sudo)
	@scripts/install-tla.sh

hello: ## Check the hello-world model (proves the install works)
	cd specs/hello && ../../bin/tlc -config Hello.cfg Hello.tla

hello-bug: ## Watch TLC catch a bug and print the steps that cause it
	cd specs/hello && ../../bin/tlc -config HelloBug.cfg Hello.tla || true

txsubmission-client: ## Check Dingo's tx-submission client under a local stop
	@scripts/run-model.sh specs/txsubmission-client

chainsync-jumping: ## Check when Dingo replaces a silent chain-sync jumping dynamo
	@scripts/run-model.sh specs/chainsync-jumping

metadata-migration-lock: ## Check opening the metadata migration lock in a shared directory
	@scripts/run-model.sh specs/metadata-migration-lock

badgerutxo-chunked-apply: ## Check a chunked ledger batch in the live UTxO store under crash and replay
	@scripts/run-model.sh specs/badgerutxo-chunked-apply

indexer-fact-copy-order: ## Check the IndexerDB fact copy of a segment that registers and credits an account
	@scripts/run-model.sh specs/indexer-fact-copy-order

models: ## Check every config of every model, Bug ones expected to fail
	@set -e; for d in specs/*/; do scripts/run-model.sh "$${d%/}"; done

check: ## Check every model that is expected to pass
	@set -e; for cfg in $(CONFIGS); do \
	  dir=$$(dirname $$cfg); name=$$(basename $$cfg .cfg); \
	  tla=$$(sed -n 's/^\\\* *SPEC: *//p' $$cfg); tla=$${tla:-$$name.tla}; \
	  echo "==> $$cfg"; \
	  (cd $$dir && ../../bin/tlc -config $$name.cfg $$tla); \
	done

clean: ## Delete TLC scratch output (keeps the installed tools)
	find specs -type d -name states -prune -exec rm -rf {} +
	find specs -name '*_TTrace_*' -delete
