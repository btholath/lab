# API guidelines

- **Resources are nouns**, plural, lowercase: `/api/portfolios/{id}/trades`.
- **Verbs** map to HTTP semantics: GET reads, POST creates and returns `201` with a `Location`.
- **Errors** use RFC 7807 problem details. Business-rule failures are `422`, unknown ids `404`, stale writes `409`, gateway auth `401`, throttling `429`.
- **Money** is a JSON number in the portfolio currency, rounded to cents at the boundary; ratios are fractions (0.05 means 5%).
- **Enums** are strings, never integers.
- **Versioning:** breaking changes go to `/api/v2`; the old version is announced in the changelog and kept for one full quarter.
- **Contract:** OpenAPI at `/openapi/v1.json`. Changing the contract requires updating the consumer (Angular `models.ts`) in the same pull request.
- **Idempotency:** the next trade-related endpoint to be added (basket execution) takes an `Idempotency-Key` header.
- **Correlation:** the gateway issues `X-Correlation-ID`; services log it and copy it into events.
