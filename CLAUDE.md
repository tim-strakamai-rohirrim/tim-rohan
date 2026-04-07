# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Structure

This is a multi-repo workspace containing four separate git repositories, each with their own branches and CI/CD:

| Directory                     | Language             | Purpose                                                                       |
| ----------------------------- | -------------------- | ----------------------------------------------------------------------------- |
| `rohan_api-parent/rohan_api/` | TypeScript (NestJS)  | Primary REST API — see its own `CLAUDE.md`                                    |
| `rohan_ui-parent/rohan_ui/`   | TypeScript (Angular) | Frontend SPA                                                                  |
| `rohan-python-api/`           | Python (FastAPI)     | Python backend with ARC Agent Writer integration                              |
| `ONERING/`                    | Python               | ARC Agent Writer CLI — automated proposal generation; see its own `CLAUDE.md` |
| `Database/`                   | SQL                  | PostgreSQL + Weaviate schema scripts                                          |
| `LocalDev/`                   | Shell/Docker         | Local dev environment (devcontainer + submodules)                             |

`ONERING` is embedded as a git submodule inside `rohan-python-api/backend/arc_agent_writer/`.

## Git Worktrees

Feature branches are managed with git worktrees — see `WORKTREES.md` for the convention. The pattern is:

```bash
# From rohan_api-parent/rohan_api:
git worktree add ../rohan_api-PRCR-XXX -b feature/PRCR-XXX

# From rohan_ui-parent/rohan_ui:
git worktree add ../rohan_ui-PRCR-XXX -b feature/PRCR-XXX
```

## Secrets / Environment Files

All `.env` files are encrypted with [SOPS](https://github.com/getsops/sops) using Azure Key Vault (`stg-staging-rohan`). After cloning any repo, decrypt manually once:

```bash
./scripts/env-decrypt.sh   # rohan-python-api or rohan_ui
```

After that, the post-merge hook auto-decrypts on `git pull`. Requires `brew install sops` and `az login` with "Key Vault Crypto User" role.

---

## rohan_api (NestJS)

Full details in `rohan_api-parent/rohan_api/CLAUDE.md`. Quick reference:

```bash
cd rohan_api-parent/rohan_api
npm install
npm run start:dev          # Hot reload dev server
npm run test               # Unit tests (Jest)
npm run test -- path/to/test.spec.ts  # Single test file
npm run test:e2e:ci        # Full E2E (spins up Docker DBs automatically)
npm run lint               # ESLint
npm run format             # Prettier
```

---

## rohan_ui (Angular)

```bash
cd rohan_ui-parent/rohan_ui
npm install
ng serve                   # Dev server at http://localhost:4200
ng test --code-coverage    # Unit tests via Karma
npm run test:ci            # Unit tests headless (CI mode)
npm run test:e2e:ci        # Full E2E (spins up Docker DBs + Playwright)
npm run lint               # ESLint
npm run format             # Prettier
```

Generate a component (use module-scoped, non-standalone):

```bash
ng generate component -m <module-name> --standalone false <path/from/app/component-name>
```

---

## rohan-python-api (FastAPI)

```bash
cd rohan-python-api
./scripts/install-hooks.sh   # One-time: installs post-merge + pre-commit hooks
./scripts/env-decrypt.sh     # One-time: decrypt backend/.env

cd backend
uv sync
fastapi run --reload app/main.py   # Dev server at http://localhost:8000 (docs at /docs)

uv run bash scripts/lint.sh        # mypy + ruff check + ruff format --check
uv run bash scripts/format.sh      # ruff fix + format
uv run bash scripts/test.sh        # pytest with coverage → htmlcov/
```

Or run the full stack with Docker Compose:

```bash
docker compose watch               # Starts backend + DB with live reload
docker compose exec backend bash   # Shell into container
```

**Alembic migrations** (run inside the container):

```bash
alembic revision --autogenerate -m "Description"
alembic upgrade head
```

---

## ONERING (ARC Agent Writer CLI)

Full details in `ONERING/CLAUDE.md`. Quick reference:

```bash
cd ONERING
uv sync
uv run python -m arc_agent_writer.cli --help
uv run pytest arc_agent_writer/tests/
```

---

## Architecture Overview

### System Flow

The platform is an AI-powered proposal-writing product for government/commercial RFPs:

```
User uploads RFP → rohan_ui (Angular)
                 → rohan_api (NestJS) — auth, RBAC, orchestration
                 → rohan-python-api (FastAPI) — heavy AI processing
                   └── ONERING (ARC Agent Writer submodule)
                         Document ingestion → LLM extraction → proposal writing → DOCX/PPTX render
```

### Cross-Service Communication

- **rohan_ui ↔ rohan_api**: REST over HTTPS; JWT from Auth0 or Okta.
- **rohan_api ↔ rohan-python-api**: JWT-authenticated HTTP (the "RFP Python Server" client in `rohan_api/src/utils/rfp-python-server/`).
- **rohan-python-api ARC runs**: Queued asynchronously via **Azure Service Bus**; results stored in **MinIO** and **PostgreSQL**.

### Databases

- **PostgreSQL + pgvector** — primary relational DB and vector embeddings (replacing Weaviate).
- **Weaviate** — legacy vector DB (being phased out; `rohan_api` still references it during migration).
- **MinIO** — object storage for documents and rendered outputs.

### Auth / RBAC (rohan_api)

Multi-tenant with Organization-scoped data. JWT → user lookup → hierarchical RBAC:
`User → Group (categories_v2 resource access) → Role → Permission`.
The `PermissionsGuard` handles all authorization including admin bypass and resource hierarchy matching.

### ARC Agent Writer Pipeline (ONERING)

22-step resumable DAG: ingestion (Docling parse → OCR → canonical markdown) → extraction pipelines (metadata, structure, requirements, evaluation) → human aggregator → compliance matrix → section writer (draft/critique/revise) → render (DOCX/PPTX/XLSX).
Artifacts are persisted per-run under `AGENT_RUNS/{run_id}/` with manifest checkpointing so any step can be resumed or force-rerun.

### Feature Flags

Managed via `pnpm enable-flag / disable-flag` in `rohan_api`. Types defined in `src/utils/feature-flags/types/featureFlags.ts`. Org-level feature gating via `FeatureGuard`.

## Ticket Prefix Convention

Commit messages and branch names use JIRA-style prefixes: `PRCR-NNNN` (older) or `ROH-NNNN` (newer).

## Other Notes

- Prefer using private helper class functions, if they exist, but within reason. If the helper does not exactly fit the use case, suggest an alternative.
