# PRCR-1679 — Stop spinning up the Weaviate container in LocalDev

Jira: https://rohirrim.atlassian.net/browse/PRCR-1679

## Problem statement

Weaviate was removed from `rohan_api` (replaced by PostgreSQL + pgvector), but the
`LocalDev` repo still starts a `semitechnologies/weaviate:1.24.1` container in both
compose stacks and still runs Weaviate backup/restore scripts on `run-local.sh`. This
wastes startup time, disk, and a network download of a multi-GB backup on every fresh
local/devcontainer bring-up. Remove the Weaviate service and its supporting scripts.

The repo's own `databases-runlocal/readme.md:89` already prescribes the fix:
> "When Weaviate is decommissioned, simply remove the Weaviate-related code from
> `run-local.sh` and the `import-data.sh` script."

## Key architectural observations

Weaviate appears in `LocalDev` in six places:

1. **`databases-runlocal/docker-compose.yml`** (host-run stack): a `weaviate` service
   (lines 63–91), three `WEAVIATE_*` env vars on the `rohan_api` service (lines 43–45),
   and an (unused) `weaviate-data` named volume (line 115).
2. **`.devcontainer/docker-compose.yaml`** (devcontainer stack): a `weaviate` service
   (lines 48–76), a `WEAVIATE_HOST: weaviate` env on the `workspace` service (line 30),
   and a `weaviate-data` named volume (line 100).
3. **`.devcontainer/devcontainer.json`**: port `8080` (Weaviate) in `forwardPorts`
   (line 78).
4. **`databases-runlocal/run-local.sh`**: a guard block (lines 1, 4–9) that runs
   `./import-data.sh &` when `./data/weaviate` is absent.
5. **`databases-runlocal/import-data.sh`**: Weaviate-only download + restore script.
6. **`scripts/reset-data.sh`** (line 7) → **`scripts/reset-weaviate.sh`**: Weaviate reset.
   `readme.md` also documents Weaviate backup/restore.

Notes:
- The `weaviate-data` named volume is declared but never mounted (the service uses a
  bind mount `./data/weaviate`), so it's already dead config.
- Port `50051` (Weaviate gRPC) is published by the compose service but is NOT in
  devcontainer `forwardPorts`, so only `8080` needs removing there.
- pgvector and MinIO import remain untouched — this ticket is Weaviate-only.

## Assumptions

- `rohan_api` no longer reads `WEAVIATE_*` env vars at boot (per the ticket); removing
  them will not break its startup. Verified at runtime in the verification step.
- The remote Weaviate backup blob URL is no longer needed locally and can be dropped
  along with `import-data.sh` (no other script sources it).
- `data/weaviate` and `backups/` local dirs are gitignored working data; no repo change
  needed for them. (The stale `.gitignore` entry `databases-runlocal/weaviate-data/` —
  a volume name that was never actually bind-mounted — is removed in step 1.9.)
- The `database/` submodule (the separate `Database` repo) still references Weaviate in
  its `.github/workflows/deploy*.yml`. That is out of scope here — a LocalDev-only
  ticket — so the verification grep excludes submodule dirs. Clean it up under its own
  ticket if desired.

## Open questions

- **Q: Does the encrypted `.devcontainer/docker-compose.override.yaml.enc` reference
  Weaviate?** It's SOPS-encrypted so not greppable here. Proposed default: decrypt it
  (`.devcontainer/yaml-decrypt.sh`) during the phase and, if it defines/overrides a
  `weaviate` service or `WEAVIATE_*` env, strip those and re-encrypt. If it doesn't
  mention Weaviate, leave it untouched.

## Implementation phases

### Phase 1 — Remove Weaviate from LocalDev [TEST_REVIEW]

```phase-meta
phase: 1
title: Remove Weaviate container and scripts from LocalDev
tags: [TEST_REVIEW]
repo: localdev
base_branch: main
depends_on: []
files:
  - databases-runlocal/docker-compose.yml
  - .devcontainer/docker-compose.yaml
  - .devcontainer/devcontainer.json
  - databases-runlocal/run-local.sh
  - databases-runlocal/import-data.sh
  - scripts/reset-data.sh
  - scripts/reset-weaviate.sh
  - databases-runlocal/readme.md
  - .gitignore
contracts:
  - "N/A — infra/config only"
verification:
  - docker compose -f databases-runlocal/docker-compose.yml config
  - docker compose -f .devcontainer/docker-compose.yaml config
  - python3 -c "import json,re,sys; json.load(open('.devcontainer/devcontainer.json'))" || echo "devcontainer.json has JSONC comments; validate manually"
  - grep -rniI weaviate . --exclude-dir=.git --exclude-dir=database --exclude-dir=api --exclude-dir=ui --exclude-dir=python-api
```

**Goal**: Stop `LocalDev` from ever starting or provisioning Weaviate; leave pgvector
and MinIO flows intact.

**Steps**:

- [ ] **1.1** In `databases-runlocal/docker-compose.yml`: delete the `weaviate:` service
      block (lines 63–91), the three `WEAVIATE_SCHEME`/`WEAVIATE_HOST`/`WEAVIATE_PORT`
      env vars under `rohan_api` (lines 43–45), and the `weaviate-data: {}` volume
      (line 115).
  - File: `databases-runlocal/docker-compose.yml`
- [ ] **1.2** In `.devcontainer/docker-compose.yaml`: delete the `weaviate:` service
      block (lines 48–76), the `WEAVIATE_HOST: weaviate` env under `workspace`
      (line 30), and the `weaviate-data: {}` volume (line 100).
  - File: `.devcontainer/docker-compose.yaml`
- [ ] **1.3** In `.devcontainer/devcontainer.json`: remove `8080` from `forwardPorts`
      (line 78). Leave 3000/4200/5432/9000/9001/9876.
  - File: `.devcontainer/devcontainer.json`
- [ ] **1.4** In `databases-runlocal/run-local.sh`: remove the `if [[ ! -d
      ./data/weaviate ]]` block that runs `./import-data.sh &` (lines 4–9) and the
      leading Weaviate-restore comment (line 1). Keep the pgvector, MinIO, and
      `docker compose up -d` logic.
  - File: `databases-runlocal/run-local.sh`
- [ ] **1.5** Delete `databases-runlocal/import-data.sh` (Weaviate-only, now unreferenced).
  - File: `databases-runlocal/import-data.sh`
- [ ] **1.6** Delete `scripts/reset-weaviate.sh` and remove its invocation from
      `scripts/reset-data.sh` (line 7). Keep `reset-postgres.sh` and `reset-minio.sh`.
  - Files: `scripts/reset-weaviate.sh`, `scripts/reset-data.sh`
- [ ] **1.7** In `databases-runlocal/readme.md`: remove the Weaviate backup/restore
      sections and the "Weaviate is decommissioned" note (lines 1–33, 47, 84, 89);
      keep pgvector and MinIO docs. Trim any now-dangling references.
  - File: `databases-runlocal/readme.md`
- [ ] **1.8** Decrypt `.devcontainer/docker-compose.override.yaml.enc` via
      `.devcontainer/yaml-decrypt.sh`; if it defines a `weaviate` service or `WEAVIATE_*`
      env, remove them and re-encrypt with `yaml-encrypt.sh`. If no Weaviate reference,
      leave it unchanged. (Resolves the Open Question.)
  - File: `.devcontainer/docker-compose.override.yaml.enc`
- [ ] **1.9** In `.gitignore`: remove the stale `databases-runlocal/weaviate-data/` line
      (the volume name it ignored was never bind-mounted). Leave the `data/` and
      `backups/` working-data ignores intact.
  - File: `.gitignore`
- [ ] **1.10** Run the verification commands. The scoped
      `grep -rniI weaviate . --exclude-dir=.git --exclude-dir=database --exclude-dir=api --exclude-dir=ui --exclude-dir=python-api`
      should return no results. (An unscoped grep still surfaces the `database/`
      submodule's deploy workflows — out of scope, see Assumptions.) `docker compose …
      config` must parse cleanly for both stacks.

## Phase order and parallelism

Single phase, single repo — no parallelism needed.

| File | Phase 1 |
|------|:------:|
| `databases-runlocal/docker-compose.yml` | ✎ |
| `.devcontainer/docker-compose.yaml` | ✎ |
| `.devcontainer/devcontainer.json` | ✎ |
| `databases-runlocal/run-local.sh` | ✎ |
| `databases-runlocal/import-data.sh` | ✗ delete |
| `scripts/reset-data.sh` | ✎ |
| `scripts/reset-weaviate.sh` | ✗ delete |
| `databases-runlocal/readme.md` | ✎ |
| `.gitignore` | ✎ |
| `.devcontainer/docker-compose.override.yaml.enc` | ✎ (conditional) |

## Phase context summaries

**Phase 1** — Removes every Weaviate touchpoint in `LocalDev`: the `weaviate` service +
volume + `WEAVIATE_*` env from both compose stacks (`databases-runlocal/docker-compose.yml`,
`.devcontainer/docker-compose.yaml`), port `8080` from devcontainer `forwardPorts`, the
`import-data.sh` restore call in `run-local.sh`, the `reset-weaviate.sh` call in
`reset-data.sh`, Weaviate docs in `readme.md`, and the stale `weaviate-data/` line in
`.gitignore`. Deletes `import-data.sh` and `reset-weaviate.sh`. Conditionally strips
Weaviate from the encrypted devcontainer override. No dependencies. Gotchas: the
verification grep must exclude the `database`/`api`/`ui`/`python-api` submodules (the
`database` repo's deploy workflows still reference Weaviate — out of scope);
`weaviate-data` volume is already dead (never mounted);
only port `8080` (not `50051`) is in devcontainer forwards; `devcontainer.json` uses JSONC
so a plain JSON parser may reject comments — validate manually if so. Leave pgvector +
MinIO flows untouched.

## Jira ticket

**Title**: PRCR-1679 — Stop spinning up the Weaviate container in LocalDev

**Description**: Weaviate has been removed from `rohan_api` in favor of PostgreSQL +
pgvector, but `LocalDev` still starts a Weaviate container and runs its backup/restore
scripts on every bring-up. Remove the Weaviate service, volume, env vars, forwarded port,
and backup/reset scripts from both the host (`databases-runlocal`) and devcontainer
stacks. Leave pgvector and MinIO provisioning intact.

**Acceptance criteria**:

- [ ] Neither compose stack defines a `weaviate` service; `docker compose … config`
      parses cleanly for both.
- [ ] No `WEAVIATE_*` env vars remain on the `rohan_api`/`workspace` services and the
      `weaviate-data` volume is gone.
- [ ] Port `8080` is removed from `.devcontainer/devcontainer.json` `forwardPorts`.
- [ ] `run-local.sh` no longer calls `import-data.sh`; `import-data.sh` and
      `reset-weaviate.sh` are deleted; `reset-data.sh` no longer references Weaviate.
- [ ] `readme.md` no longer documents Weaviate backup/restore.
- [ ] `grep -rniI weaviate` over LocalDev-owned files (excluding `.git` and the `database`/
      `api`/`ui`/`python-api` submodules) returns no hits, including inside the decrypted
      devcontainer override. The stale `.gitignore` `weaviate-data/` entry is gone.
      (The `database` submodule's deploy workflows still mention Weaviate — separate repo,
      out of scope.)
- [ ] A fresh `./run-local.sh` / devcontainer bring-up starts with no Weaviate container
      and `rohan_api` boots normally without the `WEAVIATE_*` vars.

## Branching convention

Phase produces a stacked branch off `main`:

```
{user}/PRCR-1679/phase-1
```

Phase 1 branches off `main`. (Single phase — no stack.)
