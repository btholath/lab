# WealthWise space home

WealthWise is a small wealth-management platform used to practise enterprise delivery end to end: domain modelling, API-led design, event-driven integration, CI/CD and agile practice.

| Page | Purpose |
| --- | --- |
| 01 Architecture overview | What runs where and why |
| 02 ADR-0001 Clean architecture and a hand-rolled mediator-free application layer | Decision record |
| 03 ADR-0002 Events after commit, idempotent consumer, outbox later | Decision record |
| 04 API guidelines | Contract conventions for every service |
| 05 Release runbook | How code becomes a running release |
| 06 Retrospective template | Used at the end of every sprint |
| 07 Running on Kubernetes | kind cluster, manifests, troubleshooting |
| Definition of Done | Below |

## Definition of Done
- Acceptance criteria demonstrated to the product owner.
- Unit tests for new domain rules; an integration test for new endpoints.
- CI green (build, tests, stack smoke test).
- OpenAPI contract updated if the API changed.
- No new secrets in the repository.
- Jira issue linked to the merged PR and moved to Done.

## Working agreements
- Trunk-based development with short-lived branches named `feature/WW-123-slug`.
- Pull requests are reviewed by one other person within one working day.
- Anyone can stop the line when CI is red.
