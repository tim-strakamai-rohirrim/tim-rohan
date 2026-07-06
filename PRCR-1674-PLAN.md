# PRCR-1674 — Pathway Selection API (Acquisition Pathways, Workstream P)

> **Companion docs.** Contracts: `PRCR-1674-contracts.md`. Epic map:
> `acquisition-pathways-onering-integration-PLAN.md` (this ticket = **Workstream P**). Template
> mirrored: `acquisition-pathways-step1-requirements-slice.md` — the **shipped** Requirements
> slice (S1–S11). That slice already built the shared harness; Pathway Selection reuses it and is
> therefore materially **lighter** (no DB phase, no upload endpoint, no ingestion).

Jira: [PRCR-1674](https://rohirrim.atlassian.net/browse/PRCR-1674) — *Acquisition Pathways —
Pathway Selection* (UnifiedAcquire / PRCR).

---

## Problem statement

The AP wizard's **Pathway Selection** step is ~85% built on the frontend but runs on a mock
(`PathwaySelectionService.generate()` returns `PATHWAY_SELECTION_MOCK_PATHWAYS` after a
`setTimeout`, `pathway-selection.service.ts:51`). Nothing computes the three contracting
pathways (low/medium/high tiers) from the mission's requirements record.

This ticket wires the step end-to-end on the shipped Airflow `/onering/*` path, exactly like the
Requirements slice: **trigger an ONERING `arc_acquisition_pathways` synthesis run over the
already-materialized `run_state.canonicalRecord` → emit a `pathways` UI projection → materialize it
into `acquisition_missions.run_state.pathways` (+ default `selectedPathway`) → hydrate the wizard
from the server** instead of the mock.

**What pathway generation consumes.** Unlike Requirements, Pathways does **not** ingest documents.
Its input is the requirements record produced by the prior step (`run_state.canonicalRecord`).
rohan_api **claim-checks** the record to MinIO (via the shipped gateway upload route) and passes a
**pointer** (`canonical_record_ref`) in the DAG conf — not the record inline, since a `canonicalRecord`
can be large and `dag_run.conf` is size-bounded. So there is **no document upload, no `document_uris`,
no ingestion subset** — the ONERING graph fetches the record by key and runs a single LLM synthesis
call. Generation is gated on a non-empty `canonicalRecord`.

## Key architectural observations (verified in code)

- **The materializer harness is shipped and per-`run_type` dispatched.**
  `OneringPipelineService.refreshRunStatus()` already branches on
  `run_type === ACQUISITION_REQUIREMENTS` after a terminal SUCCESS to set `MATERIALIZING` → run the
  materializer → commit SUCCESS (`onering-pipeline.service.ts:1062`). Pathways adds a sibling branch.
- **`RunStatus.MATERIALIZING` and `or_pipeline_runs.mission_id`/`materialized_at` columns already
  exist** (shipped S3/S4; index is on `organization_id`, not `mission_id`). **No DB phase is needed
  for this ticket.**
- **The trigger is a clean template.** `triggerAcquisitionRequirements()`
  (`onering-pipeline.service.ts:832`) is the exact shape to mirror — in-flight 409 guard,
  pre-trigger row insert, `reconcileTriggerFailure()` probe, and a `triggersCutoverEnabled()`
  gateway-owned branch. Swap DAG id / run_type / conf.
- **The dev Airflow mock + gateway acquisition router are shipped** and scoped to requirements;
  both extend to a second DAG by adding the pathways DAG to `shouldHandle()` / a second projection
  read route. The C20/S10 restart-recovery already keys off `shouldHandle`, so it covers pathways
  for free.
- **The claim-check path is shipped, with one small write-side extension.** The Requirements slice
  already ships the gateway upload write (`OneringApiClient.uploadAcquisitionDocument`) and the
  engine-side cross-prefix `get_object_bytes(key)` read (S11). The **read** side is reused verbatim;
  the **write** side reuses the client as-is but needs a one-line gateway validator extension (P6.0)
  to accept the top-level `pathways/` claim-check prefix (the shipped validator only allows
  `uploads/`). No new read plumbing.
- **The FE run service is generic.** `AcquisitionRunService.pollRun/getState/patchState`
  (`acquisition-run.service.ts`) are not requirements-specific — only `triggerRequirements` is. Add
  `triggerPathways` and swap the `PathwaySelectionService` mock body.
- **The prototype's scoring is pure-LLM** (`/Users/tim/Documents/code/UA-Acquisition-Pathways` —
  a sibling repo outside the `rohan` tree; no static vehicle dataset).
  The domain content to port is the `populate_pathways` prompt (the model names real vehicles and
  estimates mission-specific dimensions) + the `Pathway`/`dimensions` shape. No reference-data
  ingestion to build.

## Assumptions

1. `run_state.canonicalRecord` (the Requirements slice output) is the **input** to pathway
   generation, **claim-checked** to MinIO and referenced by `dag_run.conf.canonical_record_ref`
   (not inline). Pathways cannot run before Requirements has materialized.
2. Scoring lands in two stages, both in this ticket: **P1** stands the pipeline up pure-LLM (proves
   the plumbing + unblocks the dev mock / Stream B), then **P7** replaces the scoring internals with a
   deterministic two-layer scorer over a versioned contract-vehicle catalog — **before** the
   user-facing FE swap (P8), so no government-facing recommendation ships on LLM-guessed vehicle facts.
   The C3 schema reserves optional `score`/`evidence`/`recommendation_kind`, so P7 is **content behind
   the frozen schema — no `schema_version` bump**. The vehicle dataset is engineering-shipped (defensible
   v1) + SME-refined behind the schema.
3. `run_state` stays co-owned: the materializer writes `pathways` and a *default* `selectedPathway`
   (recommended tier, only when unset); the user owns `selectedPathway` re-picks and
   `pathwayCommitted` thereafter. The shallow top-level `mergeState` keeps these non-conflicting —
   **but only if both writers take the same lock.** Both the materializer write **and** the
   FE-driven `PATCH run_state` endpoint MUST perform an atomic read-modify-write of `run_state`
   under the same `pessimistic_write` lock on the mission row (a shallow top-level merge, never a
   full-blob overwrite). Otherwise a user tier-pick that lands mid-materialize can drop `pathways`,
   or the materializer can drop a concurrent `pathwayCommitted`. P5 adds a concurrent-write test
   covering both orderings. (If the shipped PATCH endpoint does not already lock+shallow-merge,
   that is a prerequisite, not an assumption.)
4. The `AcquisitionPathways` feature flag + `acquisition-pathways` permission already gate the
   module; new endpoints reuse them.
5. Polling via `GET /onering/runs/:id` is acceptable latency (mirrors Requirements). No new
   scheduler primitive. (The integration plan's "fast-lane re-score" stays future work.)

## Open questions

| # | Question | Proposed default |
|---|----------|------------------|
| 1 | Is `triggersCutoverEnabled()` on in the target envs? If so, P6 must also ship the `POST /v1/acquisition/pathways` trigger route the cutover branch calls. | **Mirror both branches** in C9, but treat the legacy DAG-trigger path as primary (it works under the dev mock). Ship the gateway **read** route (C13) unconditionally; ship the gateway **trigger** route only if cutover is on. |
| 2 | Does the materializer auto-select the recommended tier into `selectedPathway`? | **Yes, only when `selectedPathway` is currently null** (matches the prototype's auto-select; preserves a user's prior pick on re-run). Never sets `pathwayCommitted`. |
| 3 | Snake_case vs camelCase for `dimensions` keys, and `scopeFlexibility` vs the prototype's `flexibilityToScopeChange`? | Artifact = snake_case; TS = camelCase; standardize on **`scopeFlexibility`** (integration-plan Appendix E name). The rohan_ui type has no `dimensions` field today, so there is no existing renderer to break. |
| 4 | Does the synthesis prompt need mission scalars beyond the record (NAICS, value band)? | **Pass `mission_context` { name, statement?, naics?, value_band? }** from the mission row. The record already carries NAICS/value as fields; the context is belt-and-suspenders for the prompt. |

## Non-goals (this ticket) — named fast-follows

> **Note:** the deterministic vehicle-catalog scorer was originally listed here as a fast-follow but is
> now **in-scope as P7** (promoted ahead of the FE swap so no government-facing recommendation ships on
> LLM-guessed vehicle facts). The two below remain out of scope; the v1 schema reserves the fields each
> needs, so both land as content behind the frozen schema — **no `schema_version` bump**. Each is its
> own ticket.

1. **Grounding (org pgvector history + web_search)**. Ground recommendations in the org's actual
   procurement history (`VectorDbPostgresService`) and current web instead of stale LLM/catalog
   knowledge, capability-flagged + fail-closed with an air-gapped floor (record-only still yields 3).
   Populates the reserved `evidence[]` provenance. Net-new rohan_api grounding service + ONERING web
   profile.
2. **Pathway re-rank + agentic chat tools** (Workstream X): `compare_pathways`,
   `simulate_pathway_change`, deterministic `rerank_pathways(emphasis)` (badge best-balanced→best-fit
   without re-running the DAG), `select_pathway`, `populate_pathways`, with per-tool RBAC. The
   `recommendationKind` field is already reserved for the badge move. Sequenced after the per-step
   DAGs per the integration plan.
3. Package Assembly, Integrity, Finalize (later workstreams).
4. A new DB migration (the run-tracking columns are already shipped).

---

## Implementation phases

Branching: `{user}/acquisition-pathways-onering/phase-P{N}` (epic = `acquisition-pathways-onering`;
the `P` prefix keeps these distinct from the shipped slice's `S` phases). Each phase is one repo /
one PR. `base_branch: base` = repo main; `base_branch: phase-PN` = prior phase in the **same** repo.
Cross-repo phases coordinate via the contracts, not git stacking.

### Phase P1 — Engine: `acquisition_pathways` synthesis pipeline + step factory [PYTHON]

```phase-meta
phase: P1
title: ONERING - acquisition_pathways pipeline + acquisition_pathways:build_steps factory
tags: [PYTHON]
repo: onering
base_branch: base
depends_on: []
files:
  - arc_agent_writer/pipelines/acquisition_pathways/__init__.py
  - arc_agent_writer/pipelines/acquisition_pathways/models.py
  - arc_agent_writer/pipelines/acquisition_pathways/prompts.py
  - arc_agent_writer/pipelines/acquisition_pathways/synthesis.py
  - arc_agent_writer/pipelines/acquisition_pathways/ui_projection.py
  - arc_agent_writer/factories/acquisition_pathways.py
  - arc_agent_writer/tests/factories/test_acquisition_pathways_factory.py
  - arc_agent_writer/tests/fixtures/ui_projection_acquisition_pathways.sample.json
  - arc_agent_writer/CLAUDE.md
  - docs/specs/minio_path_contract.md
contracts:
  - "C1 acquisition_pathways:build_steps step factory"
  - "C2 pipelines.acquisition_pathways output models"
  - "C3 ui_projection_acquisition_pathways.json v1"
verification:
  - uv run pytest arc_agent_writer/tests/factories/test_acquisition_pathways_factory.py
  - uv run python -m arc_agent_writer.cli run --steps-factory arc_agent_writer.factories.acquisition_pathways:build_steps --dry-run
```

**Goal**: a single-call LLM synthesis graph that reads the requirements record (claim-checked from
MinIO) and emits a 3-tier `AcquisitionPathway[]`-shaped UI projection with mission-specific
`dimensions` (+ optional `score`/`evidence` the schema reserves for the scorer fast-follow).

**Steps**:

- [ ] **P1.1** Create `pipelines/acquisition_pathways/` with the C2 Pydantic models
  (`AcquisitionPathwayItem`, `PathwayFeature`, `PathwayDimensions`, `PathwayScore`/
  `PathwayScoreComponent`, `PathwayEvidence`, `AcquisitionPathwaysUIProjection`). Inherit
  `RecordModel` (`pipelines/_common/record_model.py`). `score`, `evidence`, and `recommendation_kind`
  are **optional** (v1 pure-LLM may emit a thin `score` / empty `evidence`; the deterministic scorer
  fast-follow fills them with no schema bump). **Not** a 4-phase pipeline — one synthesis step.
- [ ] **P1.2** Write `prompts.py` porting the prototype `populate_pathways` guidance
  (`/Users/tim/Documents/code/UA-Acquisition-Pathways/proxy/src/system-prompt.js:137` — **sibling
  repo, not in-tree**; an agent rooted in `rohan` must read it via the absolute path): the persona is a government
  acquisition strategist; emit **exactly 3** options (low/medium/high), each with a concrete real
  vehicle name, FAR reference, contract type, ≤1-paragraph rationale (limited inline HTML), 3
  feature bullets, and **mission-specific** dimensions (forbid generic reused numbers like "310
  vendors" unless they fit this PSC band/value). Exactly one option carries `recommended`.
- [ ] **P1.3** `synthesis.py`: one `ctx.llm_controller.call_structured(output_model=AcquisitionPathwaysUIProjection, …)`
  over the record + mission_context from `run_meta`. `ui_projection.py` writes the artifact to
  `pipelines/acquisition_pathways_extraction/ui/ui_projection_acquisition_pathways.json` (mirror
  `REQUIREMENTS_UI_RELPATH`; derive prefix via `runs_prefix_for(store)`).
- [ ] **P1.4** `factories/acquisition_pathways.py:build_steps(*, cfg, artifact_store)` per **C1** —
  a `load_run_state_record` step + the synthesis step + UI projection step (no `stage_documents`, no
  ingestion subset). `load_run_state_record` reads `canonical_record_ref` from `run_meta` and fetches
  the record JSON from MinIO via the **shipped** S11 `get_object_bytes(key)` cross-prefix getter (bare
  key, scheme rejected — the same getter `stage_documents` uses). `mission_context` is read inline
  from `run_meta`. The DAG's `stage_run` seeds both (P2).
- [ ] **P1.5** Add the sample fixture (consumed by P5's dev mock + vendored for the P9 E2E; P7 later
  updates it with populated `score`/`evidence`; include a
  thin `score` + a sample `evidence[]` entry so the fixture exercises the optional fields) and the
  factory unit test (step count/order; asserts the load step + no ingestion/extraction steps). Update
  `docs/specs/minio_path_contract.md` (note the
  `acquisition/{org}/{mission}/pathways/{arc_run_id}/canonical_record.json` claim-check input key)
  + `arc_agent_writer/CLAUDE.md`.

### Phase P2 — Engine: `arc_acquisition_pathways` DAG + JSON schema [PYTHON]

```phase-meta
phase: P2
title: ONERING - arc_acquisition_pathways DAG + ui_projection schema
tags: [PYTHON]
repo: onering
base_branch: phase-P1
depends_on: [P1]
files:
  - airflow/dags/arc_acquisition_pathways_dag.py
  - arc_agent_writer/tests/test_airflow_dag_acquisition_pathways.py
  - specs/ui_projection_acquisition_pathways.schema.json
  - airflow/CLAUDE.md
contracts:
  - "C4 arc_acquisition_pathways DAG dag_run.conf envelope"
  - "C3 ui_projection_acquisition_pathways.json v1 JSON Schema"
verification:
  - uv run pytest arc_agent_writer/tests/test_airflow_dag_acquisition_pathways.py
  - "python -c 'import json,jsonschema; jsonschema.Draft7Validator.check_schema(json.load(open(\"specs/ui_projection_acquisition_pathways.schema.json\")))'"
```

**Goal**: ship the DAG that runs the P1 factory and freeze the v1 artifact schema.

**Steps**:

- [ ] **P2.1** `airflow/dags/arc_acquisition_pathways_dag.py` mirroring
  `arc_acquisition_requirements_dag.py`. `dag_id="arc_acquisition_pathways"`. Conf key is `run_id`.
  `stage_run` seeds `run_meta` with `canonical_record_ref` (MinIO key — the record is claim-checked,
  fetched in P1.4's load step) + inline `mission_context` (new templating, mirroring how the
  requirements DAG forwards `document_uris`/`mission_id` — export as env or pass to the CLI; never
  bash-interpolate untrusted conf). Tags
  `["arc","acquisition","pathways"]`, `max_active_runs=4`, retries 1/5 min. Reuse existing LLM pools.
- [ ] **P2.2** DAG unit test (loads, task order, conf parsing/seeding, env export).
- [ ] **P2.3** `specs/ui_projection_acquisition_pathways.schema.json` per **C3** with
  `schema_version` const `"1"`; validate the P1 sample fixture against it.
- [ ] **P2.4** Document the DAG + conf in `airflow/CLAUDE.md`.

### Phase P3 — rohan_api: enums, conf type, DTOs + pathway types [BACKEND_DB]

```phase-meta
phase: P3
title: rohan_api - OneringDagId/RunType + AcquisitionPathwaysConf + DTOs + AcquisitionPathway type
tags: [BACKEND_DB]
repo: rohan_api
base_branch: base
depends_on: []
files:
  - src/onering/types/airflow.types.ts
  - src/onering/enums/run-type.enum.ts
  - src/acquisition-pathways/types/acquisition-pathway.ts
  - src/acquisition-pathways/dto/runs/generate-pathways.dto.ts
  - src/acquisition-pathways/dto/runs/index.ts
contracts:
  - "C5 Enum extensions (OneringDagId, RunType)"
  - "C6 AcquisitionPathwaysConf"
  - "C7 TriggerPathwaysGenerateDto + PathwaysRunResponse + AcquisitionPathway/PathwayDimensions"
verification:
  - npm run lint
  - npm run build
```

**Goal**: land all rohan_api type/enum/DTO surface area with no behavior change (the contract-freeze
phase Streams A and C build against).

**Steps**:

- [ ] **P3.1** `OneringDagId.ACQUISITION_PATHWAYS = 'arc_acquisition_pathways'`
  (`airflow.types.ts`); `RunType.ACQUISITION_PATHWAYS = 'ACQUISITION_PATHWAYS'` (`run-type.enum.ts`).
  **Do not** touch `run-status.enum.ts` — `MATERIALIZING` already exists.
- [ ] **P3.2** `AcquisitionPathwaysConf` interface + extend the `DagRunConf` union per **C6**
  (imports the shipped `CrrField`).
- [ ] **P3.3** `acquisition-pathways/types/acquisition-pathway.ts` with `AcquisitionPathway`,
  `PathwayDimensions`, `PathwayFeature`, `PathwayTier` per **C7** (net-new — the materializer needs
  the shape; `run_state` is opaque today).
- [ ] **P3.4** `TriggerPathwaysGenerateDto` (empty) + `PathwaysRunResponse` (snake_case, matching
  `RequirementsRunResponse`) per **C7**.
- [ ] **P3.5** Grep the `onering` module for `RunType`/`OneringDagId` switch/if-chains — same as the
  slice's S3.5, `refreshRunStatus()` only switches over `AirflowDagRunState` (with a `default`), so
  the new members don't break exhaustiveness.

### Phase P4 — rohan_api: `pathways:generate` endpoint + `triggerAcquisitionPathways()` [BACKEND_DB]

```phase-meta
phase: P4
title: rohan_api - pathways:generate endpoint + OneringPipelineService.triggerAcquisitionPathways()
tags: [BACKEND_DB]
repo: rohan_api
base_branch: phase-P3
depends_on: [P3]
files:
  - src/acquisition-pathways/controllers/ap-missions.controller.ts
  - src/acquisition-pathways/services/ap-missions.service.ts
  - src/onering/services/onering-pipeline.service.ts
  - src/onering/services/onering-pipeline.service.spec.ts
  - src/onering/clients/onering-api.client.ts
contracts:
  - "C8 POST /acquisition-pathways/missions/:id/pathways:generate"
  - "C9 OneringPipelineService.triggerAcquisitionPathways()"
verification:
  - npm run lint
  - npm run test -- src/onering/services/onering-pipeline.service.spec.ts
```

**Goal**: trigger the pathways DAG over the mission's requirements record, tracked in
`or_pipeline_runs`.

**Steps**:

- [ ] **P4.1** `triggerAcquisitionPathways(user, missionId, canonicalRecord, missionContext, options?)`
  in `OneringPipelineService` per **C9** — copy `triggerAcquisitionRequirements`
  (`:832`) and swap DAG id (`ACQUISITION_PATHWAYS`), run_type, `arc_run_id` prefix
  (`'arc_acq_path_'`), `dagRunId` (`control__acq_path__…`), and conf (build `AcquisitionPathwaysConf`).
  **Claim-check the record:** before the row insert, write `canonicalRecord` JSON to MinIO at
  `acquisition/{org_id}/{mission_id}/pathways/{arcRunId}/canonical_record.json` via the
  `OneringApiClient.uploadAcquisitionDocument` client (the same client S5 uses for uploads) → set
  `canonical_record_ref` on the conf; on upload failure, fail the row and surface the error (don't
  fire a DAG that can't read its input). **Gateway dependency:** the shipped upload route currently
  validates the key as `acquisition/{org_id}/{mission_id}/uploads/…/{filename}` (4th segment must be
  `uploads`), so a top-level `pathways/` key is rejected **until P6.0 extends the validator** to
  whitelist the `pathways/` claim-check prefix. P4's happy path therefore depends on P6.0 being
  deployed (P4 can still be coded/tested against contracts with the client mocked). Keep the
  in-flight 409 guard, pre-trigger row insert, and
  `reconcileTriggerFailure()`. Mirror the `triggersCutoverEnabled()` branch →
  `oneringApi.triggerAcquisitionPathways(...)` (add the client method; the gateway trigger route is
  P6/Open-Q1).
- [ ] **P4.2** `POST /acquisition-pathways/missions/:id/pathways::generate` on
  `ApMissionsController` per **C8** (`::` Fastify escape; pin `200`). Same guards + ownership check.
  Resolve `canonicalRecord` + `missionContext` from the mission; **422** when `canonicalRecord` is
  absent/empty; call `triggerAcquisitionPathways`; PATCH `run_state.pathwaysRun = { arcRunId, status }`;
  return `PathwaysRunResponse`. **`missionContext` is best-effort:** `name` is required; `statement`/
  `naics`/`value_band` are included only if the mission row carries them (omit when absent — the
  authoritative source for NAICS/value is the record itself, per Open-Q4). Do not 4xx on missing
  optional scalars.
- [ ] **P4.3** Unit tests: happy path, record-upload (claim-check) failure → row failed + no DAG
  trigger, Airflow trigger failure, trigger-failure reconcile (DAG run exists → row not FAILED),
  ownership 404, empty-`canonicalRecord` 422, in-flight 409.

### Phase P5 — rohan_api: artifact validator + materializer + dev mock [BACKEND_DB]

```phase-meta
phase: P5
title: rohan_api - pathways artifact validator, materializer into run_state.pathways, dev mock
tags: [BACKEND_DB]
repo: rohan_api
base_branch: phase-P4
depends_on: [P4]
files:
  - src/acquisition-pathways/services/ap-pathways-projection-validator.service.ts
  - src/acquisition-pathways/services/ap-pathways-projection-validator.service.spec.ts
  - src/acquisition-pathways/services/ap-pathways-materializer.service.ts
  - src/acquisition-pathways/services/ap-pathways-materializer.service.spec.ts
  - src/onering/services/onering-pipeline.service.ts
  - src/onering/services/onering-pipeline.service.spec.ts
  - src/onering/services/onering-airflow-mock.service.ts
  - src/onering/clients/onering-api.client.ts
  - src/onering/__mocks__/ui_projection_acquisition_pathways.fixture.json
  - src/onering/onering.module.ts
contracts:
  - "C10 Pathways artifact validator (ajv, version-strict)"
  - "C11 Materializer behavior + field->AcquisitionPathway mapping"
  - "C12 Dev Airflow mock extension (pathways fixture)"
verification:
  - npm run lint
  - npm run test -- src/acquisition-pathways/services/ap-pathways-projection-validator.service.spec.ts
  - npm run test -- src/acquisition-pathways/services/ap-pathways-materializer.service.spec.ts
  - npm run test -- src/onering/services/onering-pipeline.service.spec.ts
```

**Goal**: on terminal SUCCESS, validate the artifact and materialize it into `run_state.pathways`
(+ default `selectedPathway`); let UI engineers iterate without real Airflow.

**Steps**:

- [ ] **P5.1** `ApPathwaysProjectionValidatorService` (ajv@^8, version-strict on `schema_version`)
  per **C10**, reading via the gateway client. `loadAndValidate(run)` takes the run row; expose a
  pure `validate(raw, contextId)` half. Provided by `OneringModule` (avoid circular import).
- [ ] **P5.2** `getAcquisitionPathwaysProjection(runId, ctx)` on `OneringApiClient` mirroring
  `getAcquisitionRequirementsProjection` (incl. the 25 MB per-request `maxContentLength` cap).
- [ ] **P5.3** `ApPathwaysMaterializerService.materialize(arcRunId)` per **C11**: Phase A
  (read+validate+cross-check `run_id`/`mission_id`), Phase B (map snake→camel → `AcquisitionPathway[]`,
  passing optional `score` + `recommendationKind` through and mapping `evidence[]` → `SourcePill[]`;
  PATCH `run_state` shallow-merging `pathways` + default `selectedPathway` *only when unset* +
  `pathwaysRun.status='SUCCEEDED'`; `pessimistic_write` lock; set `materialized_at`; flip SUCCESS;
  idempotent via `materialized_at`).
- [ ] **P5.4** Extend `refreshRunStatus()`'s post-SUCCESS branch with a
  `run_type === ACQUISITION_PATHWAYS` arm (sibling to the requirements arm at `:1062`) that runs the
  pathways materializer. Add `MATERIALIZING` wherever `RunStatus` is serialized for this run type (the
  serialization path is already `MATERIALIZING`-aware from the slice).
- [ ] **P5.4b** **Terminal-failure propagation.** On a terminal **non-SUCCESS** state for an
  `ACQUISITION_PATHWAYS` run (DAG `FAILED`, or materialize/validation error), `refreshRunStatus()`
  must stamp the terminal status back into `run_state.pathwaysRun.status` (locked shallow-merge,
  same path as P5.3) — **not** just the `or_pipeline_runs` row. Without this, the C14 hydrate-on-
  reload path (`pathwaysRun.status` non-terminal → keep polling) loops forever on a failed run.
  Mirror whatever the requirements slice does for its run-state failure stamp; if the slice has no
  such stamp, this is net-new for pathways.
- [ ] **P5.5** Extend `AirflowMockService.shouldHandle()` to accept `ACQUISITION_PATHWAYS` and
  `triggerDagRun` to serve the pathways fixture per **C12**. Copy the P1 sample into
  `src/onering/__mocks__/`.
- [ ] **P5.5b** **Stub the claim-check upload in mock mode.** When the same dev-mock gate is active
  (reuse `AirflowMockService`'s enablement predicate — `ONERING_AIRFLOW_BASE_URL` empty + `NODE_ENV
  !== 'production'` + no `KEY_VAULT_NAME` + `ONERING_AIRFLOW_MOCK !== 'disabled'`), `triggerAcquisitionPathways`
  (the P4 path) **skips** the real `OneringApiClient.uploadAcquisitionDocument` call and synthesizes
  `canonical_record_ref` = the would-be key directly. The mock serves a fixed fixture and never
  dereferences the record, so the write is pure waste locally — skipping it lets the slice run with
  **no gateway reachable** (P6.0 then only matters against a real gateway). Gate is identical to the
  trigger/artifact-read stubs so mock mode is all-or-nothing.
- [ ] **P5.6** Tests: validator (happy, unknown `schema_version`, missing/typed field, **optional
  `score`/`evidence` absent still validates**); materializer (map→`AcquisitionPathway[]`, `evidence`→
  pills, `score` passthrough, default `selectedPathway`=recommended when unset, **no clobber** when
  already set, no `pathwayCommitted` write, cross-check mismatch rejects, idempotent re-materialize,
  **terminal-failure stamps `pathwaysRun.status` (P5.4b)**, **concurrent FE-PATCH + materialize keeps
  both keys (Assumption #3)**); mock serves fixture + materializes end-to-end, **and the claim-check
  upload is skipped in mock mode (no `uploadAcquisitionDocument` call; synthetic
  `canonical_record_ref`) — P5.5b**.

### Phase P6 — Engine: `onering_api` pathways-projection gateway route [PYTHON]

```phase-meta
phase: P6
title: ONERING - onering_api pathways claim-check upload-key extension + pathways-projection read route (+ trigger parity if cutover)
tags: [PYTHON]
repo: onering
base_branch: phase-P2
depends_on: [P2]
files:
  - onering_api/routers/acquisition.py
  - onering_api/services/acquisition.py
  - onering_api/schemas.py
  - onering_api/tests/test_acquisition_routes.py
  - docs/specs/minio_path_contract.md
contracts:
  - "C9 claim-check write key (gateway upload-validator accepts pathways/ prefix)"
  - "C13 GET /v1/acquisition/runs/{run_id}/pathways-projection"
verification:
  - uv run pytest onering_api/tests/test_acquisition_routes.py
```

> **Stacking note.** P6 stacks on `phase-P2` (gateway routes + validator only — a small, independent
> diff), and **P7 stacks on P6** so the P7 branch carries the full ONERING stack (P1+P2+P6+P7) and is
> locally testable end-to-end — exercising the gateway routes against the real catalog scorer. P6 and
> P7 touch disjoint files (P6 = `onering_api/` gateway; P7 = `arc_agent_writer/` scorer), so the stack
> order is a convenience for one full-stack test branch, not a code dependency. P6.0's only hard
> consumer is P4, which is unblocked locally by the P5.5b mock stub and only needs P6.0 *deployed*
> before it runs against a real gateway.

**Goal**: extend the gateway upload validator to accept the `pathways/` claim-check prefix (so P4's
record write lands), and land the gateway read route the rohan_api P5 client calls, so the slice
works against real Airflow/MinIO (the dev mock covers it locally).

**Steps**:

- [ ] **P6.0** **Extend the upload-key validator** in `onering_api/services/acquisition.py`
  (`_parse_acquisition_upload_key`) to whitelist a top-level `pathways/` folder in addition to
  `uploads/` — i.e. accept `acquisition/{org_id}/{mission_id}/pathways/{arc_run_id}/canonical_record.json`
  (4th segment ∈ {`uploads`, `pathways`}). Keep every other guard: `{org_id}` segment must equal the
  caller's tenant org (403), reject traversal/absolute/unsafe segments (400). This is the write side
  of the C9 claim-check; **P4's happy path depends on it.** Tests: a `pathways/` key for the caller's
  org is accepted; cross-org `pathways/` key → 403; traversal → 400.
- [ ] **P6.1** Add `GET /v1/acquisition/runs/{run_id}/pathways-projection` to the existing
  `routers/acquisition.py` per **C13**: resolve prefix via `runs_prefix_for(store)`, read the C3
  artifact, return raw JSON (200) or 404. Reuse the requirements-projection service pattern in
  `services/acquisition.py`.
- [ ] **P6.2** *(Conditional — Open-Q1)* If `triggersCutoverEnabled()` is on in target envs, add
  `POST /v1/acquisition/pathways` mirroring the requirements trigger route (own the in-flight 409).
  Skip if cutover is off everywhere.
- [ ] **P6.3** Update `docs/specs/minio_path_contract.md`; route tests (projection happy path + 404).

### Phase P7 — Engine: contract-vehicle catalog + deterministic two-layer scorer [PYTHON]

```phase-meta
phase: P7
title: ONERING - acquisition/vehicles catalog + deterministic+LLM two-layer scorer (populate score{})
tags: [PYTHON]
repo: onering
base_branch: phase-P6
depends_on: [P1, P2, P6]
files:
  - arc_agent_writer/acquisition/vehicles/schema.py
  - arc_agent_writer/acquisition/vehicles/loader.py
  - arc_agent_writer/acquisition/vehicles/catalog_version.py
  - arc_agent_writer/acquisition/vehicles/data/*.yaml
  - arc_agent_writer/acquisition/vehicles/tests/test_catalog.py
  - arc_agent_writer/pipelines/acquisition_pathways/deterministic.py
  - arc_agent_writer/pipelines/acquisition_pathways/llm_assess.py
  - arc_agent_writer/pipelines/acquisition_pathways/blend.py
  - arc_agent_writer/pipelines/acquisition_pathways/synthesis.py
  - arc_agent_writer/pipelines/acquisition_pathways/models.py
  - arc_agent_writer/tests/pipelines/test_acquisition_pathways_scoring.py
  - arc_agent_writer/tests/fixtures/ui_projection_acquisition_pathways.sample.json
  - arc_agent_writer/CLAUDE.md
contracts:
  - "C15 contract-vehicle catalog + two-layer scorer"
verification:
  - uv run pytest arc_agent_writer/acquisition/vehicles/tests/test_catalog.py
  - uv run pytest arc_agent_writer/tests/pipelines/test_acquisition_pathways_scoring.py
```

**Goal**: replace P1's pure-LLM scoring internals with a defensible **two-layer** scorer over a
versioned contract-vehicle catalog — deterministic signals + hard disqualifiers blended with an LLM
assessment — populating the reserved `score{}`/`recommendationKind`/`evidence[]` fields. **Behind the
P2-frozen schema: no `schema_version` bump.** Lands **before** the FE swap (P8) so the first
user-facing ship recommends only real, in-scope vehicles (no LLM-guessed ceilings or cancelled
vehicles). P1's prompt/models/factory/UI-projection survive; this swaps `synthesis.py`'s
"ask the LLM for 3 cards" for "score the catalog → collapse to 3 → narrate".

**Steps**:

- [ ] **P7.1** Contract-vehicle dataset (**C15**): `acquisition/vehicles/` — Pydantic `Vehicle` schema
  (closed enums where the scorer keys off them: family, status, set-aside, time-to-award band, protest
  band, cost-risk owner; free text for LLM/UI), YAML data (one file per family), `load_vehicle_catalog()`
  (version-strict `SCHEMA_VERSION='1'`, `lru_cache`, **no network/DB** — air-gap baked), calendar
  `CATALOG_VERSION`, a **defensible v1 dataset** (~15–20 rows incl. lifecycle flags — e.g. CIO-SP4
  cancelled, NITAAC sunsetting, **and one always-eligible open-market / Full & Open row** as the
  guaranteed 3-tier floor per P7.3). Per-row `confidence ∈ {VERIFIED_WEB, SME_VERIFY, ESTIMATED}` marks
  what the SME must validate — **engineering ships defensible v1; SME refines behind the schema**. CI:
  load + invariant tests + a 90-day `ordering_period_end` freshness warning.
- [ ] **P7.2** `deterministic.py`: 10 weighted signals (sum 1.00) + hard disqualifiers →
  `DeterministicVehicleScores{composite, disqualified, disqualifier_reasons}`. Weights:
  requirement_fit .18, ceiling_fit .15, set_aside_eligibility .14, naics_psc_applicability .12,
  time_to_award .10, protest_exposure .09, vendor_pool_depth .07, scope_change_flexibility .06,
  cost_risk_alignment .05, agency_already_holds .04. **Disqualifiers:** value > `ceiling_usd`; est.
  per-order > `order_ceiling_usd`; required set-aside the vehicle can't satisfy; non-`ACTIVE` status.
- [ ] **P7.3** `llm_assess.py`: per-vehicle LLM assessment (`call_structured`, gated on
  `!disqualified`) — reuses P1's prompt persona; returns `overall_fit ∈ [0,1]` + strengths/risks/
  rationale. **Bound the fan-out:** assess only the **top-K** non-disqualified vehicles by
  deterministic composite (`K` default 8) — not the whole catalog — and run the assessments
  **concurrently** (`ThreadPoolExecutor`, mirror the extraction pipelines' worker pattern), so total
  added latency is ~one LLM round-trip, not K sequential calls. Log how many were assessed vs.
  skipped. `blend.py`: `composite = 0.40·det + 0.60·llm` (`det·0.40` when the LLM didn't run);
  `collapse_to_tiers` → exactly 3 by a speed-vs-control risk index (best composite per band).
  **Fewer-than-3-eligible backfill:** if hard disqualifiers leave <3 eligible vehicles, backfill from
  the highest-composite **disqualified** vehicles, each surfaced with its disqualifier reason (a
  `tone:'fail'` feature + the `disqualifiers[]` populated) so the card never hides why it's a poor
  fit. The catalog MUST also carry an always-eligible **open-market / Full & Open** entry (no ceiling
  or status to disqualify on) as the guaranteed floor, so a 3-tier result is always producible.
  `choose_recommended` → balanced default `recommendation_kind:'best-balanced'`, tiebreak
  `low > medium > high`; a backfilled (disqualified) tier is never `recommended`.
- [ ] **P7.4** Rewrite `synthesis.py` to score the catalog → collapse → narrate the 3 tiers, emitting
  `score{total,deterministic,llm,components[],disqualifiers[]}`, `recommendation_kind`, and
  `evidence[]` from the catalog `sources[]` (+ any grounding). `models.py` gains the scoring models
  (`DeterministicVehicleScores`, `LLMPathwayAssessment`). Stamp `catalog_version` into the artifact.
- [ ] **P7.5** Update the **ONERING** sample fixture
  (`arc_agent_writer/tests/fixtures/ui_projection_acquisition_pathways.sample.json`) so
  `score`/`evidence` are populated. **Re-vendoring into rohan_api is owned by P9** (cross-repo: a
  rohan_api PR can't import an ONERING branch's file, so P9 copies the P7-updated sample into the two
  rohan_api locations). Tests: catalog load + invariants; deterministic disqualifier kills (value >
  ceiling, cancelled vehicle); blend ratio; `collapse_to_tiers` always yields 3 (incl. the
  fewer-than-3-eligible backfill, P7.3); recommended tiebreak.

### Phase P8 — rohan_ui: swap PathwaySelectionService mock → trigger/poll/hydrate [FRONTEND]

```phase-meta
phase: P8
title: rohan_ui - real pathway generation (trigger + poll + run_state.pathways hydration)
tags: [FRONTEND]
repo: rohan_ui
base_branch: base
depends_on: [P4, P7]
files:
  - src/app/pages/acquisition-pathways/services/pathway-selection.service.ts
  - src/app/pages/acquisition-pathways/services/pathway-selection.service.spec.ts
  - src/app/pages/acquisition-pathways/services/acquisition-run.service.ts
  - src/app/pages/acquisition-pathways/types/acquisition-pathways.types.ts
  - src/app/pages/acquisition-pathways/wizard/acquisition-pathways-wizard.component.ts
contracts:
  - "C14 FE consumption + hydration"
verification:
  - npm run lint
  - npm run test:ci -- --include='**/pathway-selection.service.spec.ts'
  - npm run build
```

**Goal**: replace the Pathway Selection mock with server data, end to end.

> **Sequencing.** P8 builds against P3+P4 contracts (frozen) and can develop against the P5 dev mock,
> but it is **sequenced after P7** so the first user-facing ship renders real, scored, defensible
> pathways — not LLM-guessed vehicles. Code against the contracts + PR diffs, not a running backend.

**Steps**:

- [ ] **P8.1** Add the optional `dimensions?`, `score?`, `evidence?`, `recommendationKind?` fields to
  the rohan_ui `AcquisitionPathway` type per **C14** (+ the `PathwayDimensions`/`PathwayScore`
  interfaces; the other fields already match). Cards may render `dimensions` + the badge now; the
  `score` detail panel can stay behind a later UI ticket.
- [ ] **P8.2** Add `triggerPathways(missionId)` to `AcquisitionRunService` (mirror
  `triggerRequirements`, `:50`). Reuse generic `pollRun`/`getState`/`patchState`.
- [ ] **P8.3** Swap `PathwaySelectionService.generate()` (`:51`) from the `setTimeout`+mock body to
  `triggerPathways → pollRun → getState → _pathways$.next(run_state.pathways)` +
  `_selectedTier$.next(run_state.selectedPathway ?? recommended)`. Keep the signature
  side-effect-only; keep `reset()`/`selectTier()`. Keep the mock importable behind `?demo=1`.
- [ ] **P8.4** Wizard hydration on `:missionId` load: `run_state.pathways` present → hydrate; else
  `run_state.pathwaysRun` non-terminal → loading + poll; else `pathwaysRun.status` terminal-FAILED →
  error/retry state, **no poll** (relies on C11's terminal-failure stamp). `generate()`/`pollRun`
  must surface a terminal non-SUCCESS as an error, not hang on the loading banner. Persist selection
  via debounced `patchState({ selectedPathway, pathwayCommitted })` (locked shallow-merge PATCH).
- [ ] **P8.5** Specs: generate→poll→hydrate, default tier selection, persistence on select,
  **terminal-FAILED surfaces an error (no infinite poll)**. Keep the existing pathway-selection step
  spec green.

### Phase P9 — Slice E2E [TEST_REVIEW]

```phase-meta
phase: P9
title: rohan_api - acquisition_pathways slice E2E via in-process mock
tags: [TEST_REVIEW]
repo: rohan_api
base_branch: phase-P5
depends_on: [P5, P7]
files:
  - test/acquisition-pathways.e2e-spec.ts
  - test/fixtures/ui_projection_acquisition_pathways.fixture.json
  - src/onering/__mocks__/ui_projection_acquisition_pathways.fixture.json
  - test/run-sequential.integration-spec.ts
contracts:
  - "C11 materializer mapping (exercised via E2E)"
  - "C14 hydration (exercised via E2E)"
verification:
  - npm run lint
  - npm run test:e2e -- -t "Pathway"
```

**Goal**: prove the pathway slice end-to-end through the in-process mock, against the P7-scored fixture.

**Steps**:

- [ ] **P9.1** E2E (`ONERING_AIRFLOW_BASE_URL` empty): create mission → seed
  `run_state.canonicalRecord` (PATCH) → `pathways:generate` → poll → assert `run_state.pathways`
  materialized as `AcquisitionPathway[]` (3 tiers, `dimensions` + `score` present, exactly one
  recommended) and `selectedPathway` = recommended tier; assert idempotent re-materialize; assert the
  422 when `canonicalRecord` is absent. **Runs with no gateway reachable** (P5.5b stubs the
  claim-check upload in mock mode). Register in `test/run-sequential.integration-spec.ts`.
- [ ] **P9.2** Re-vendor the P7-updated ONERING sample into **both** rohan_api copies
  (`test/fixtures/…` and `src/onering/__mocks__/…`) — this is the manual cross-repo copy P7.5 defers
  here. Then an in-repo byte-equal check asserts the **two rohan_api copies match each other**
  (mirrors the slice's retained S8 assertion). **Scope note:** this check is intra-repo only — it
  cannot reach the ONERING source of truth, so ONERING↔rohan_api drift is caught only by re-running
  this copy step, not automatically. Flag drift in the P7/P9 PR descriptions.

---

## Phase order, dependencies, parallelism

### File-touch matrix

| Phase | ONERING files | rohan_api files | rohan_ui files |
|-------|---------------|-----------------|----------------|
| P1 | pipelines/acquisition_pathways/, factories/ | — | — |
| P2 | airflow/dags/, specs/ | — | — |
| P3 | — | onering/types, onering/enums, acquisition-pathways/{types,dto} | — |
| P4 | — | acquisition-pathways/{controllers,services}, onering/services/pipeline, onering/clients | — |
| P5 | — | acquisition-pathways/services (validator+materializer), onering/{services,clients,__mocks__,module} | — |
| P6 | onering_api/{routers,services,tests}, docs/specs | — | — |
| P7 | acquisition/vehicles/, pipelines/acquisition_pathways/ (deterministic/llm_assess/blend/synthesis/models) | — | — |
| P8 | — | — | pages/acquisition-pathways/{services,wizard,types} |
| P9 | — | test/ (E2E + fixture) | — |

No file is touched by two phases except P5 (amends the P4 `onering-pipeline.service.ts` +
`onering-api.client.ts`), P7 (amends P1's `synthesis.py`/`models.py`), and P9 (re-vendors the P5
`src/onering/__mocks__/…fixture.json` with the P7-scored content) — all same-repo stacks, safe.

### Stream model

- **Stream A (engine):** P1 → P2 → **P6** → **P7** in ONERING. P6 ships the gateway upload-validator
  extension P6.0 + projection read route (a small, independent diff on P2); **P7 stacks on P6** so the
  P7 branch carries the full ONERING stack (P1+P2+P6+P7) and is locally testable end-to-end. P7 is the
  defensibility upgrade — vehicle catalog + two-layer scorer. **P6.0 is on the critical path for P4** —
  P4's claim-check write 400s until the gateway accepts the `pathways/` prefix, so land P6 before
  exercising P4 against any reachable gateway (locally the P5.5b mock stub bypasses the gateway
  entirely, so P4 dev is unblocked regardless). P7's vehicle dataset is the critical-path content
  (engineering ships a defensible v1; the SME refines behind the frozen schema).
- **Stream B (rohan_api):** P3 → P4 → P5 → P9.
- **Stream C (UI):** P8 can develop against the P5 dev mock once P3+P4 contracts freeze, but **ships
  after P7** (sequencing gate — first user-facing render must be scored/defensible).

**Stacks:** P1→P2→P6→P7 (ONERING — P7 stacks on P6, making the P7 branch the single full-stack
local-test branch); P3→P4→P5→P9 (rohan_api); P8 branches off its repo's main.
Convergence: a working slice needs P2 (DAG) + P5 (materializer) green; the P5 dev mock lets Stream C
demo the full path with **no gateway reachable** (P5.5b stubs the claim-check upload in mock mode,
alongside the trigger/artifact-read stubs). **The first user-facing ship additionally needs P7**
(defensible scoring); a slice against **real** Airflow/MinIO additionally needs **P6** — both P6.0
(the gateway accepts P4's `pathways/` claim-check write) and P6.1 (the projection read route).

Solo sequence: **P3 → P1 → P2 → P6 → P7 → P4 → P5 → P8 → P9** (P7 stacks on P6, so P6 lands first;
P6 carries P6.0 so the claim-check write is accepted before P4 runs against a real gateway — locally
the P5.5b stub bypasses it).

## Phase context summaries

- **P1 — `acquisition_pathways` pipeline + factory (ONERING).** Produces the
  `pipelines.acquisition_pathways` package (a **single** LLM synthesis step — NOT 4-phase
  extraction; no ingestion) and the `acquisition_pathways:build_steps` factory, emitting a
  3-tier `AcquisitionPathway[]`-shaped `ui_projection_acquisition_pathways.json` with
  mission-specific `dimensions` (+ optional `score`/`evidence`/`recommendation_kind` reserved for the
  scorer/grounding/re-rank fast-follows). Input is the requirements record — **claim-checked**: a
  `load_run_state_record` step reads `canonical_record_ref` from `run_meta` and fetches the JSON from
  MinIO via the shipped `get_object_bytes` getter (no documents). Depends on nothing. Domain content =
  the ported prototype `populate_pathways` prompt; no static vehicle dataset in v1. Gotchas: factory
  signature is `build_steps(*, cfg, artifact_store)`; emit exactly 3 options, exactly one
  `recommended`; forbid generic reused dimension numbers. v1 scoring is pure-LLM; **P7 replaces the
  scoring internals** with the catalog scorer (behind this same schema). Ships a sample fixture
  consumed by P5/P9. Implements C1, C2, C3.

- **P2 — `arc_acquisition_pathways` DAG + schema (ONERING).** Ships the DAG (mirrors
  `arc_acquisition_requirements_dag.py`) and freezes the v1 artifact JSON Schema. `stage_run` seeds
  `run_meta` with `canonical_record_ref` (MinIO key; record claim-checked) + inline `mission_context`
  from conf — new templating (the helper
  templates only `run_id`); never bash-interpolate untrusted conf, export as env. `schema_version`
  const `"1"`; the P1 fixture must validate. Depends on P1. Stacks on phase-P1. Implements C4 + the
  schema half of C3.

- **P3 — Enums, conf, DTOs, pathway types (rohan_api).** Zero-behavior contract-freeze:
  `OneringDagId.ACQUISITION_PATHWAYS`, `RunType.ACQUISITION_PATHWAYS`, `AcquisitionPathwaysConf` in
  the `DagRunConf` union, net-new `AcquisitionPathway`/`PathwayDimensions` rohan_api types, and the
  trigger DTO + `PathwaysRunResponse`. **Does NOT touch `run-status.enum.ts`** (`MATERIALIZING`
  already shipped) and adds **no DB migration** (run-tracking columns already shipped). Branches off
  `base`. Implements C5, C6, C7.

- **P4 — `pathways:generate` + `triggerAcquisitionPathways()` (rohan_api).** A copy of the shipped
  `triggerAcquisitionRequirements` with DAG id/run_type/conf swapped — in-flight 409 guard,
  pre-trigger row insert, `reconcileTriggerFailure()` probe, and the `triggersCutoverEnabled()`
  gateway branch. The `…/pathways::generate` endpoint (Fastify `::` escape) reads `canonicalRecord`
  from `run_state` (**422** if absent), fires the run, stores the `pathwaysRun` pointer. Depends on
  P3. Stacks on phase-P3. Implements C8, C9.

- **P5 — Validator + materializer + dev mock (rohan_api).** On terminal SUCCESS for an
  `ACQUISITION_PATHWAYS` run, `refreshRunStatus()` sets `MATERIALIZING`, validates the artifact
  (ajv, version-strict), maps snake→camel to `AcquisitionPathway[]`, PATCHes `run_state.pathways` +
  a default `selectedPathway` (recommended tier, **only when unset** — co-ownership), then flips
  SUCCESS. Extends the dev mock to serve the pathways fixture. Depends on P4. Gotchas: Phase-A/Phase-B
  discipline; idempotency via `materialized_at`; validator/materializer provided by `OneringModule`
  (circular-import avoidance); never write `pathwayCommitted`. Stacks on phase-P4. Implements C10,
  C11, C12.

- **P6 — Gateway upload-key extension + pathways-projection route (ONERING).** **P6.0** extends the
  upload-key validator (`_parse_acquisition_upload_key`) to accept the top-level `pathways/`
  claim-check prefix — the write side of C9, on the **critical path for P4** (P4's record write 400s
  without it). **P6.1** adds `GET /v1/acquisition/runs/{run_id}/pathways-projection` to the existing
  `routers/acquisition.py` (mirrors the shipped requirements-projection route), so the materializer
  can read the artifact against real Airflow/MinIO. Optionally adds the cutover trigger route
  (Open-Q1). Depends on P2; **stacks on phase-P2** (a small, independent gateway-only diff). P7 then
  stacks on P6, so the full-stack local-test branch is P7. Implements C13 + the C9 write-key extension.

- **P7 — Contract-vehicle catalog + two-layer scorer (ONERING).** The defensibility upgrade,
  promoted ahead of the FE swap. Adds a versioned `acquisition/vehicles/` catalog (Pydantic schema +
  YAML + version-strict, air-gapped loader; defensible engineering v1, SME-refined) and replaces P1's
  pure-LLM scoring with a **two-layer** scorer: 10 weighted deterministic signals + hard disqualifiers
  (value > ceiling, cancelled vehicle) blended `0.40·det + 0.60·llm`, collapsed to 3 tiers, populating
  the reserved `score{}`/`recommendationKind`/`evidence[]`. **No `schema_version` bump** — content
  behind the P2-frozen schema. Re-vendors the updated fixture into rohan_api. Depends on P1+P2 (+P6 for
  git stacking only); **stacks on phase-P6** so the P7 branch carries the full ONERING stack
  (P1+P2+P6+P7) for end-to-end local testing. Gotchas: keep exactly-3 + one-recommended invariants;
  tiebreak low>medium>high; loader must not hit network/DB. Implements C15.

- **P8 — FE swap (rohan_ui).** Adds `dimensions`/`score`/`evidence`/`recommendationKind` to the
  `AcquisitionPathway` type, a `triggerPathways` method on the generic `AcquisitionRunService`, and
  swaps `PathwaySelectionService.generate()` from mock to trigger→poll→hydrate from
  `run_state.pathways`, persisting `selectedPathway`/`pathwayCommitted` via debounced PATCH. Builds on
  P3+P4 contracts + the P5 dev mock; **sequenced after P7** so the first user-facing render is scored.
  Branches off `main`. Gotchas: keep the mock behind `?demo=1`; keep the existing step spec green;
  signature stays side-effect-only. Implements C14.

- **P9 — Slice E2E (rohan_api).** Drives create → seed record → `pathways:generate` → poll →
  asserts `run_state.pathways` materialized (3 tiers + `dimensions` + `score`) and
  `selectedPathway`=recommended, idempotent re-materialize, and the empty-record 422, with an in-repo
  byte-equal fixture-sync check against the P7 sample. Depends on P5+P7. Stacks on phase-P5.

## Jira ticket

**Title:** Acquisition Pathways — Pathway Selection API (ONERING/Airflow synthesis →
`run_state.pathways` → wizard hydration)

**Description:** Wire the AP wizard's **Pathway Selection** step end-to-end through the shipped
Airflow `/onering/*` integration, reusing the Requirements slice's materializer harness. Add a
buyer-side `acquisition_pathways` pipeline + DAG in ONERING that scores three contracting pathways
(low/medium/high, with mission-specific dimensions) from the mission's requirements record — a
deterministic two-layer scorer over a versioned contract-vehicle catalog (so recommendations are
defensible, not LLM-guessed), landed before the user-facing FE swap; extend rohan_api to trigger the
DAG (tracked in `or_pipeline_runs`), validate the emitted artifact and materialize it into
`acquisition_missions.run_state.pathways` (+ default `selectedPathway`); add the gateway projection
read route; and replace the rohan_ui mock with real server-hydrated pathways + a polling state. The dev Airflow mock lets the FE iterate without
the real DAG, and a slice E2E exercises the whole path. Ships behind the existing
`AcquisitionPathways` feature flag. No DB migration (run-tracking columns shipped by the Requirements
slice). Companion: `acquisition-pathways-onering-integration-PLAN.md`.

**Acceptance criteria** (one per phase):

- [ ] **P1** ONERING `pipelines.acquisition_pathways` + `acquisition_pathways:build_steps` factory
  run a single synthesis step over the requirements record and emit a 3-tier
  `ui_projection_acquisition_pathways.json` with mission-specific dimensions; factory test + sample
  fixture land.
- [ ] **P2** `arc_acquisition_pathways` DAG runs the factory via `--steps-factory`, seeding the
  `canonical_record_ref` + inline mission context from conf; the v1 schema (with optional
  `score`/`evidence`/`recommendation_kind`) is frozen and the P1 fixture validates.
- [ ] **P3** `OneringDagId`/`RunType` values, `AcquisitionPathwaysConf` (in the `DagRunConf` union),
  the trigger DTO + `PathwaysRunResponse`, and the `AcquisitionPathway`/`PathwayDimensions` types
  compile and lint with no behavior change (and no `run-status.enum.ts` / DB change).
- [ ] **P4** `POST …/missions/:id/pathways:generate` reads `run_state.canonicalRecord` (422 if
  absent), claim-checks it to MinIO via the shipped upload client, triggers the DAG via
  `triggerAcquisitionPathways()` with `canonical_record_ref`, stores the `run_state.pathwaysRun`
  pointer; guards + claim-check-failure + reconcile idempotency + ownership + in-flight 409 covered by tests.
- [ ] **P5** On terminal SUCCESS the materializer validates the artifact (version-strict),
  cross-checks `run_id`+`mission_id`, maps to `AcquisitionPathway[]`, PATCHes `run_state.pathways`
  + default `selectedPathway` (only when unset), and the dev mock drives the full path; validator +
  materializer + mock tests pass.
- [ ] **P6** The gateway upload-key validator accepts the `pathways/` claim-check prefix (P6.0, with
  org-ownership 403 + traversal 400 tests) **and** `GET /v1/acquisition/runs/{run_id}/pathways-projection`
  exists matching C13 with route tests; the slice works against real Airflow/MinIO.
- [ ] **P7** A versioned `acquisition/vehicles/` catalog (Pydantic + YAML + air-gapped loader, v1
  dataset) and a two-layer scorer (deterministic 10-signal + disqualifiers blended `0.40/0.60` with
  the LLM, collapsed to 3 tiers) populate the reserved `score{}`/`recommendationKind`/`evidence[]`
  with **no `schema_version` bump**; catalog + scoring tests pass; the fixture is re-vendored to
  rohan_api. Lands before P8.
- [ ] **P8** The wizard hydrates pathways from `run_state.pathways` (real data, mock behind
  `?demo=1`), with generate → poll wired, `dimensions`/`score`/`evidence`/`recommendationKind` added
  to the FE type, and `selectedPathway`/`pathwayCommitted` persisted via debounced PATCH; service +
  hydration specs pass.
- [ ] **P9** An E2E drives the slice end-to-end via the in-process mock (create → seed record →
  generate → poll → `pathways` as `AcquisitionPathway[]` (3 tiers + `score`) + `selectedPathway` →
  idempotent re-materialize → empty-record 422), with an in-repo byte-equal fixture-sync check against
  the P7 sample.

## Tech stack reference

| Layer | Stack |
|-------|-------|
| Engine (ONERING) | Python 3.x, Airflow 3.x (KubernetesExecutor), Pydantic v2, Helm |
| Backend (rohan_api) | NestJS, TypeScript, TypeORM, Jest, ajv |
| Frontend (rohan_ui) | Angular 20+ (signals, zoneless, non-standalone module), Karma/Jasmine |
| Storage | MinIO (`AGENT_RUNS/{arc_run_id}/…` artifacts; `acquisition/{org}/{mission}/pathways/{run}/canonical_record.json` claim-checked input — gateway upload validator extended to accept the `pathways/` prefix, P6.0) — **no document uploads for pathways** |
| Run tracking | `or_pipeline_runs` (reused; `mission_id` shipped), `acquisition_missions.run_state` |
| Auth | JWT; Airflow token via `OneringAirflowClientService` |
