# PulseWatch SOA and ESB Architecture

PulseWatch keeps its current user-facing behavior and uses Apache Camel as
the required integration gateway between Next.js and the Python service.
Direct app-to-NLP communication is not a supported runtime topology.

## Service boundaries

| Service | Responsibility | Existing contract |
| --- | --- | --- |
| Next.js application / BFF | Browser UI, authentication, authorization, watchlists, attention orchestration, response validation | Browser-facing `/api/*` routes |
| PostgreSQL | Users, sessions, watchlists, instruments, observations, and attention baselines | Prisma schema and migrations |
| Python NLP service | NLP analysis, financial news, market data adapters, RAG, and LangGraph chat workflow | FastAPI routes such as `/nlp/*`, `/stocks/*`, `/market/*`, `/chat/*`, `/rag/*`, and `/agents/*` |
| Apache Camel ESB (required) | Service routing, correlation metadata, dependency readiness, and protocol-level forwarding to the NLP service | Preserves the Python service's paths, HTTP methods, query strings, bodies, response codes, and payloads |

The browser continues to call only the Next.js BFF. Authentication and
watchlist ownership remain in Next.js; the ESB does not bypass those checks
or expose database access. The ESB is a transport/integration boundary, not
a second implementation of business or NLP logic.

## Request flow

```text
Browser ── /api/* ──> Next.js BFF ──> Apache Camel ESB ──> Python NLP service
                          │
                          └── Prisma ──> PostgreSQL
```

`NLP_SERVICE_URL` points to Camel (`http://127.0.0.1:8081` by default);
Camel forwards the existing service paths to `NLP_SERVICE_TARGET_URL`
(`http://127.0.0.1:8000` by default). No application API contract or
frontend code changes are required.

## Integration behavior

- Camel routes the existing `/nlp`, `/stocks`, `/market`, `/chat`, `/rag`,
  `/agents`, `/docs`, and `/openapi.json` paths to the configured NLP service.
- GET and POST are accepted for proxied service routes. Existing query
  parameters, request bodies, response bodies, content types, and upstream
  HTTP status codes are preserved.
- An `X-Correlation-Id` is forwarded and echoed. Camel creates a UUID when a
  request does not provide one.
- `GET /health` reports ESB liveness. `GET /ready` checks the Python NLP
  service through the gateway and is required before the launcher starts
  Next.js.
- A connection failure to the upstream NLP service returns HTTP 502; it
  does not fabricate a successful NLP response. Existing app-level fallback
  and unavailable states continue to apply.
- Camel binds to the configured server port. Keep the ESB and Python service
  on a private network; the gateway does not replace authentication or
  provide a public security boundary.

## Running and compatibility

Run `./start.sh` to launch the complete stack. The Maven Wrapper downloads
its pinned Maven distribution on first use. The launcher starts Python,
waits for its health check, starts Camel and waits for `/ready`, then starts
Next.js with its `NLP_SERVICE_URL` pointed at Camel. On Windows PowerShell,
follow the three-terminal instructions in `NLP_SETUP.md`. Applications
started separately must also point `NLP_SERVICE_URL` at the ESB; configuring
it to point directly at Python bypasses the required integration boundary.

## Evolution toward independently deployable services

Current modules can be extracted without changing their public contracts:

1. Keep the Next.js app as the browser-facing BFF and authorization owner.
2. Deploy market, NLP/RAG, and chat capabilities independently behind their
   existing HTTP contracts.
3. Use Camel routes to apply service discovery, authentication between
   services, timeouts, retries, circuit breakers, or message transformation
   only when a concrete deployment requires them.
4. Version a contract before changing payload semantics; keep the existing
   paths and schemas available during client migration.

The ESB adds no application-level retry or circuit-breaker policy. Any
future reliability policy should account for non-idempotent and potentially
costly NLP/LLM operations before it is enabled.
