# PRCR-1679 — Contracts

## Contract → Phase mapping

| Contract Section | Phase(s) | Notes |
|------------------|----------|-------|
| — | 1 | No API/DTO/DB/type contracts — infra & scripts only |

## Summary

This ticket is a **LocalDev infrastructure/config cleanup**. It touches only
`docker-compose` files, `devcontainer.json`, shell scripts, and a README — no HTTP
endpoints, DTOs, database schema, frontend types, or cross-service event payloads change.

There are therefore **no contracts to define**. The complete change inventory lives in
[PRCR-1679-PLAN.md](PRCR-1679-PLAN.md) Phase 1.

### Effective "interface" change (for reference)

The only externally observable change is a removed container/port in the local dev
environment:

- Weaviate service (`semitechnologies/weaviate:1.24.1`) no longer started.
- Ports `8080` (HTTP) and `50051` (gRPC) no longer published/forwarded from local dev.
- `WEAVIATE_SCHEME` / `WEAVIATE_HOST` / `WEAVIATE_PORT` no longer injected into the
  `rohan_api` / `workspace` service environments.
