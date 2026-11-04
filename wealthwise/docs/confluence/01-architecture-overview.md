# Architecture overview

Attach `docs/diagrams/wealthwise-architecture.gif` to this page (Insert > Files and images). Regenerate it with `python3 scripts/make-architecture-gif.py` after changing the topology.

```
Browser (Angular; Compose http://localhost:4200, Kubernetes http://localhost:8080)
   |  nginx adds the API key server-side
   v
Kong gateway (:8000 inside the network; host port 8800 under Compose)  key-auth, rate limiting, CORS, correlation id
   v
ASP.NET Core API (:8080)
   |-- Domain        aggregates, valuation, rebalance strategies (no dependencies)
   |-- Application   use cases and ports (interfaces)
   |-- Infrastructure EF Core + PostgreSQL, price feed, SQS adapter
   |
   +--> PostgreSQL (:5432)
   +--> SQS-compatible queue (ElasticMQ :9324) --> consumer --> audit_entries
```

## Why these pieces
| Concern | Choice | Notes |
| --- | --- | --- |
| API management | Kong OSS, declarative config | Policy lives outside the service, as it would on an enterprise gateway |
| Persistence | PostgreSQL via EF Core | Money columns use `numeric` with explicit precision |
| Messaging | SQS API (ElasticMQ locally) | Same SDK and code on real AWS; only configuration changes |
| Front end | Angular standalone components and signals | Lazy-loaded routes, strict templates, responsive CSS, semantic HTML |
| Delivery | GitHub Actions to Octopus Deploy | CI proves it; Octopus promotes it through environments |

## Design patterns in use
- **Aggregate root** (`Portfolio`): the only way to change cash and holdings is `ApplyTrade`, which enforces the invariants.
- **Strategy and Factory** (`IRebalanceStrategy`, `RebalanceStrategyFactory`).
- **Decorator** (`CachingPriceProvider` wraps `SimulatedPriceProvider`).
- **Repository and ports/adapters** (`IPortfolioRepository`, `IPriceProvider`, `IEventPublisher`).
- **Idempotent consumer** (unique `EventId` in the audit table).
- **Optimistic concurrency** (`Portfolio.Version`).

## Path to AWS
| Local | AWS |
| --- | --- |
| Docker images | ECR then ECS Fargate services behind an ALB |
| Kong | Amazon API Gateway or Kong on ECS |
| PostgreSQL | Aurora PostgreSQL or RDS |
| ElasticMQ | SQS (set `Sqs__ServiceUrl` empty) |
| In-process consumer | Lambda with SQS event source mapping and a DLQ |
| `.env` and compose variables | Secrets Manager and SSM Parameter Store |
