# ADR-0002: Publish events after commit, consume idempotently, add an outbox later

**Status:** Accepted for now  **Date:** 2026-10

## Context
Executing a trade must update the database and tell other systems. Doing both atomically needs either a distributed transaction (not available across PostgreSQL and SQS) or an outbox.

## Decision
1. Commit the trade.
2. Publish `trade.executed` to SQS. A failure is logged and does not undo the trade.
3. The consumer writes an audit row keyed by a unique `EventId`; duplicates are ignored and the message is then deleted.

## Consequences
- Delivery is at-least-once, so the consumer must be idempotent (it is).
- There is a small window where a crash after commit loses the event. Acceptable for an audit trail in this demo; **not** acceptable for downstream settlement.
- Follow-up: transactional outbox table written in the same transaction as the trade, drained by a publisher (Jira WW-S20 moves the consumer to Lambda at the same time).
