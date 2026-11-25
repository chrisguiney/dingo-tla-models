# Concurrency inventory

Dingo's goroutines, locks and channels that interact with gOuroboros callbacks,
and the hazards found in them. gOuroboros's own inventory lives in the
gOuroboros models repository's CONCURRENCY.md.

| Id | Hazard | Status | Model |
| --- | --- | --- | --- |
| DC1 | `Close` now joins running callbacks; a callback that waits on cleanup run only after `Close` returns deadlocks it | fixed on the integration branch | `txsubmission-client` `JoinBug` |
