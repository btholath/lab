# ADR-0001: Layered clean architecture with a plain application layer

**Status:** Accepted  **Date:** 2026-10

## Context
The domain (portfolios, trades, valuation, rebalancing) has real rules that must be testable without a database. The team also wants to avoid a mediator library: MediatR moved to a commercial licence, and for a handful of use cases an indirection layer adds more ceremony than value.

## Decision
- Four projects: `Domain` (no references), `Application` (references Domain), `Infrastructure` (references Application), `Api` (composition root).
- Use cases are ordinary scoped classes (`PortfolioService`, `TradeService`) taking ports in their constructors.
- Endpoints are thin: bind, call a service, return.
- Errors are translated in one exception handler: `NotFoundException` to 404, `DomainException` to 422, concurrency conflict to 409.

## Consequences
- Domain tests run in milliseconds with no mocks.
- Swapping PostgreSQL, the price feed or the queue touches only Infrastructure.
- If use cases multiply, introduce handlers per command behind the same ports; nothing here blocks that.
