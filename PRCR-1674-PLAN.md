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
Its input is the requirements record produced by the prior step (`run_state.canonicalRecord`), passed
into the DAG via conf. So there is **no upload endpoint, no `document_uris`, no ingestion subset** —
the ONERING graph is a single LLM synthesis call. Generation is gated on a non-empty
`canonicalRecord`.

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
   generation, passed verbatim in `dag_run.conf.canonical_record`. Pathways cannot run before
   Requirements has materialized.
2. Scoring is **LLM-driven** (ported prototype prompt), not a deterministic vehicle dataset. Real
   vehicle reference data + calibration rules remain a future Stream-E enhancement behind the frozen
   C3 artifact schema — the pipeline runs end-to-end on the prompt alone.
3. `run_state` stays co-owned: the materializer writes `pathways` and a *default* `selectedPathway`
   (recommended tier, only when unset); the user owns `selectedPathway` re-picks and
   `pathwayCommitted` thereafter. The shallow top-level `mergeState` keeps these non-conflicting.
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

## Non-goals

- Real contract-vehicle reference data / scoring calibration rules (future Stream E; the prompt
  carries v1).
- `compare_pathways` / `simulate_pathway_change` / agentic chat tools (Workstream X).
- Package Assembly, Integrity, Finalize (later workstreams).
- A new DB migration (the run-tracking columns are already shipped).

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

**Goal**: a single-call LLM synthesis graph that reads the requirements record from `run_meta` and
emits a 3-tier `AcquisitionPathway[]`-shaped UI projection with mission-specific `dimensions`.

**Steps**:

- [ ] **P1.1** Create `pipelines/acquisition_pathways/` with the C2 Pydantic models
  (`AcquisitionPathwayItem`, `PathwayFeature`, `PathwayDimensions`,
  `AcquisitionPathwaysUIProjection`). Inherit `RecordModel` (`pipelines/_common/record_model.py`).
  No `EvidenceSpan` (pathways carry no source spans). **Not** a 4-phase pipeline — one synthesis
  step.
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
  the synthesis step + UI projection step only (no `stage_documents`, no ingestion subset). The DAG's
  `stage_run` seeds `run_meta['canonical_record']` + `run_meta['mission_context']` from conf (P2).
- [ ] **P1.5** Add the sample fixture (consumed by P5's dev mock + vendored for the P8 E2E) and the
  factory unit test (step count/order; asserts no ingestion/extraction steps). Update
  `docs/specs/minio_path_contract.md` + `arc_agent_writer/CLAUDE.md`.

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
  `stage_run` seeds `run_meta` from `dag_run.conf.canonical_record` + `mission_context` (new
  templating, mirroring how the requirements DAG forwards `document_uris`/`mission_id` — export as
  env or pass to the CLI; never bash-interpolate untrusted conf). Tags
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
  Keep the in-flight 409 guard, pre-trigger row insert, and `reconcileTriggerFailure()`. Mirror the
  `triggersCutoverEnabled()` branch → `oneringApi.triggerAcquisitionPathways(...)` (add the client
  method; the gateway trigger route is P6/Open-Q1).
- [ ] **P4.2** `POST /acquisition-pathways/missions/:id/pathways::generate` on
  `ApMissionsController` per **C8** (`::` Fastify escape; pin `200`). Same guards + ownership check.
  Resolve `canonicalRecord` + `missionContext` from the mission; **422** when `canonicalRecord` is
  absent/empty; call `triggerAcquisitionPathways`; PATCH `run_state.pathwaysRun = { arcRunId, status }`;
  return `PathwaysRunResponse`.
- [ ] **P4.3** Unit tests: happy path, Airflow trigger failure, trigger-failure reconcile (DAG run
  exists → row not FAILED), ownership 404, empty-`canonicalRecord` 422, in-flight 409.

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
  PATCH `run_state` shallow-merging `pathways` + default `selectedPathway` *only when unset* +
  `pathwaysRun.status='SUCCEEDED'`; `pessimistic_write` lock; set `materialized_at`; flip SUCCESS;
  idempotent via `materialized_at`).
- [ ] **P5.4** Extend `refreshRunStatus()`'s post-SUCCESS branch with a
  `run_type === ACQUISITION_PATHWAYS` arm (sibling to the requirements arm at `:1062`) that runs the
  pathways materializer. Add `MATERIALIZING` wherever `RunStatus` is serialized for this run type (the
  serialization path is already `MATERIALIZING`-aware from the slice).
- [ ] **P5.5** Extend `AirflowMockService.shouldHandle()` to accept `ACQUISITION_PATHWAYS` and
  `triggerDagRun` to serve the pathways fixture per **C12**. Copy the P1 sample into
  `src/onering/__mocks__/`.
- [ ] **P5.6** Tests: validator (happy, unknown `schema_version`, missing/typed field); materializer
  (map→`AcquisitionPathway[]`, default `selectedPathway`=recommended when unset, **no clobber** when
  already set, no `pathwayCommitted` write, cross-check mismatch rejects, idempotent re-materialize);
  mock serves fixture + materializes end-to-end.

### Phase P6 — Engine: `onering_api` pathways-projection gateway route [PYTHON]

```phase-meta
phase: P6
title: ONERING - onering_api /v1/acquisition pathways-projection read route (+ trigger parity if cutover)
tags: [PYTHON]
repo: onering
base_branch: base
depends_on: [P2]
files:
  - onering_api/routers/acquisition.py
  - onering_api/services/acquisition.py
  - onering_api/schemas.py
  - onering_api/tests/test_acquisition_routes.py
  - docs/specs/minio_path_contract.md
contracts:
  - "C13 GET /v1/acquisition/runs/{run_id}/pathways-projection"
verification:
  - uv run pytest onering_api/tests/test_acquisition_routes.py
```

**Goal**: land the gateway read route the merged rohan_api P5 client calls, so the slice works
against real Airflow/MinIO (the dev mock covers it locally).

**Steps**:

- [ ] **P6.1** Add `GET /v1/acquisition/runs/{run_id}/pathways-projection` to the existing
  `routers/acquisition.py` per **C13**: resolve prefix via `runs_prefix_for(store)`, read the C3
  artifact, return raw JSON (200) or 404. Reuse the requirements-projection service pattern in
  `services/acquisition.py`.
- [ ] **P6.2** *(Conditional — Open-Q1)* If `triggersCutoverEnabled()` is on in target envs, add
  `POST /v1/acquisition/pathways` mirroring the requirements trigger route (own the in-flight 409).
  Skip if cutover is off everywhere.
- [ ] **P6.3** Update `docs/specs/minio_path_contract.md`; route tests (projection happy path + 404).

### Phase P7 — rohan_ui: swap PathwaySelectionService mock → trigger/poll/hydrate [FRONTEND]

```phase-meta
phase: P7
title: rohan_ui - real pathway generation (trigger + poll + run_state.pathways hydration)
tags: [FRONTEND]
repo: rohan_ui
base_branch: base
depends_on: [P4]
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

> **Contract-stability gate.** P7 branches off `main` but logically depends on P3+P4 contracts being
> frozen (the rohan_api PRs are the source of truth). Code against the contracts + PR diffs.

**Steps**:

- [ ] **P7.1** Add `dimensions?: PathwayDimensions` to the rohan_ui `AcquisitionPathway` type per
  **C14** (the other fields already match). Add the `PathwayDimensions` interface.
- [ ] **P7.2** Add `triggerPathways(missionId)` to `AcquisitionRunService` (mirror
  `triggerRequirements`, `:50`). Reuse generic `pollRun`/`getState`/`patchState`.
- [ ] **P7.3** Swap `PathwaySelectionService.generate()` (`:51`) from the `setTimeout`+mock body to
  `triggerPathways → pollRun → getState → _pathways$.next(run_state.pathways)` +
  `_selectedTier$.next(run_state.selectedPathway ?? recommended)`. Keep the signature
  side-effect-only; keep `reset()`/`selectTier()`. Keep the mock importable behind `?demo=1`.
- [ ] **P7.4** Wizard hydration on `:missionId` load: `run_state.pathways` present → hydrate; else
  `run_state.pathwaysRun` non-terminal → loading + poll. Persist selection via debounced
  `patchState({ selectedPathway, pathwayCommitted })`.
- [ ] **P7.5** Specs: generate→poll→hydrate, default tier selection, persistence on select. Keep the
  existing pathway-selection step spec green.

### Phase P8 — Slice E2E [TEST_REVIEW]

```phase-meta
phase: P8
title: rohan_api - acquisition_pathways slice E2E via in-process mock
tags: [TEST_REVIEW]
repo: rohan_api
base_branch: phase-P5
depends_on: [P5]
files:
  - test/acquisition-pathways.e2e-spec.ts
  - test/fixtures/ui_projection_acquisition_pathways.fixture.json
  - test/run-sequential.integration-spec.ts
contracts:
  - "C11 materializer mapping (exercised via E2E)"
  - "C14 hydration (exercised via E2E)"
verification:
  - npm run lint
  - npm run test:e2e -- -t "Pathway"
```

**Goal**: prove the pathway slice end-to-end through the in-process mock.

**Steps**:

- [ ] **P8.1** E2E (`ONERING_AIRFLOW_BASE_URL` empty): create mission → seed
  `run_state.canonicalRecord` (PATCH) → `pathways:generate` → poll → assert `run_state.pathways`
  materialized as `AcquisitionPathway[]` (3 tiers, dimensions present) and `selectedPathway` =
  recommended tier; assert idempotent re-materialize; assert the 422 when `canonicalRecord` is
  absent. Register in `test/run-sequential.integration-spec.ts`.
- [ ] **P8.2** In-repo byte-equal check that `test/fixtures/…` and
  `src/onering/__mocks__/ui_projection_acquisition_pathways.fixture.json` stay in sync (mirrors the
  slice's retained S8 assertion).

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
| P7 | — | — | pages/acquisition-pathways/{services,wizard,types} |
| P8 | — | test/ (E2E + fixture) | — |

No file is touched by two phases except P5, which amends the P4 `onering-pipeline.service.ts` +
`onering-api.client.ts` (same-stack stack, safe).

### Two-stream parallel model

- **Stream A (engine):** P1 → P2 in ONERING. Follow-up: **P6** (gateway read route; branches off
  ONERING main after P2 merges).
- **Stream B (rohan_api):** P3 → P4 → P5 → P8.
- **Stream C (UI):** P7 begins as soon as P3+P4 contracts are frozen (off `main`).

**Stacks:** P1→P2 (ONERING); P3→P4→P5→P8 (rohan_api); P6 and P7 branch off their repos' main once
their contract deps are frozen. Convergence: a working slice needs P2 (DAG) + P5 (materializer)
green; the P5 dev mock lets Stream C demo without the real DAG. A working slice against **real**
Airflow/MinIO additionally needs **P6** (the projection read route).

Solo sequence: **P3 → P1 → P2 → P4 → P5 → P7 → P8 → P6** (P6 any time after P2).

## Phase context summaries

- **P1 — `acquisition_pathways` pipeline + factory (ONERING).** Produces the
  `pipelines.acquisition_pathways` package (a **single** LLM synthesis step — NOT 4-phase
  extraction; no ingestion) and the `acquisition_pathways:build_steps` factory, emitting a
  3-tier `AcquisitionPathway[]`-shaped `ui_projection_acquisition_pathways.json` with
  mission-specific `dimensions`. Input is the requirements record from `run_meta` (seeded by the P2
  DAG from conf), not documents. Depends on nothing. Domain content = the ported prototype
  `populate_pathways` prompt; no static vehicle dataset. Gotchas: factory signature is
  `build_steps(*, cfg, artifact_store)`; emit exactly 3 options, exactly one `recommended`; forbid
  generic reused dimension numbers. Ships a sample fixture consumed by P5/P8. Implements C1, C2, C3.

- **P2 — `arc_acquisition_pathways` DAG + schema (ONERING).** Ships the DAG (mirrors
  `arc_acquisition_requirements_dag.py`) and freezes the v1 artifact JSON Schema. `stage_run` seeds
  `run_meta` with `canonical_record` + `mission_context` from conf — new templating (the helper
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

- **P6 — Gateway pathways-projection route (ONERING).** Adds
  `GET /v1/acquisition/runs/{run_id}/pathways-projection` to the existing `routers/acquisition.py`
  (mirrors the shipped requirements-projection route), so the materializer can read the artifact
  against real Airflow/MinIO. Optionally adds the cutover trigger route (Open-Q1). Depends on P2;
  branches off ONERING main. Implements C13.

- **P7 — FE swap (rohan_ui).** Adds `dimensions` to the `AcquisitionPathway` type, a
  `triggerPathways` method on the generic `AcquisitionRunService`, and swaps
  `PathwaySelectionService.generate()` from mock to trigger→poll→hydrate from `run_state.pathways`,
  persisting `selectedPathway`/`pathwayCommitted` via debounced PATCH. Logically depends on P3+P4
  contracts; branches off `main`. Gotchas: keep the mock behind `?demo=1`; keep the existing step
  spec green; signature stays side-effect-only. Implements C14.

- **P8 — Slice E2E (rohan_api).** Drives create → seed record → `pathways:generate` → poll →
  asserts `run_state.pathways` materialized (3 tiers + dimensions) and `selectedPathway`=recommended,
  idempotent re-materialize, and the empty-record 422, with an in-repo byte-equal fixture-sync
  check. Depends on P5. Stacks on phase-P5.

## Jira ticket

**Title:** Acquisition Pathways — Pathway Selection API (ONERING/Airflow synthesis →
`run_state.pathways` → wizard hydration)

**Description:** Wire the AP wizard's **Pathway Selection** step end-to-end through the shipped
Airflow `/onering/*` integration, reusing the Requirements slice's materializer harness. Add a
buyer-side `acquisition_pathways` LLM-synthesis pipeline + DAG in ONERING that scores three
contracting pathways (low/medium/high, with mission-specific dimensions) from the mission's
requirements record; extend rohan_api to trigger the DAG (tracked in `or_pipeline_runs`), validate
the emitted artifact and materialize it into `acquisition_missions.run_state.pathways` (+ default
`selectedPathway`); add the gateway projection read route; and replace the rohan_ui mock with
real server-hydrated pathways + a polling state. The dev Airflow mock lets the FE iterate without
the real DAG, and a slice E2E exercises the whole path. Ships behind the existing
`AcquisitionPathways` feature flag. No DB migration (run-tracking columns shipped by the Requirements
slice). Companion: `acquisition-pathways-onering-integration-PLAN.md`.

**Acceptance criteria** (one per phase):

- [ ] **P1** ONERING `pipelines.acquisition_pathways` + `acquisition_pathways:build_steps` factory
  run a single synthesis step over the requirements record and emit a 3-tier
  `ui_projection_acquisition_pathways.json` with mission-specific dimensions; factory test + sample
  fixture land.
- [ ] **P2** `arc_acquisition_pathways` DAG runs the factory via `--steps-factory`, seeding the
  record + mission context from conf; the v1 schema is frozen and the P1 fixture validates.
- [ ] **P3** `OneringDagId`/`RunType` values, `AcquisitionPathwaysConf` (in the `DagRunConf` union),
  the trigger DTO + `PathwaysRunResponse`, and the `AcquisitionPathway`/`PathwayDimensions` types
  compile and lint with no behavior change (and no `run-status.enum.ts` / DB change).
- [ ] **P4** `POST …/missions/:id/pathways:generate` reads `run_state.canonicalRecord` (422 if
  absent), triggers the DAG via `triggerAcquisitionPathways()`, stores the `run_state.pathwaysRun`
  pointer; guards + reconcile idempotency + ownership + in-flight 409 covered by tests.
- [ ] **P5** On terminal SUCCESS the materializer validates the artifact (version-strict),
  cross-checks `run_id`+`mission_id`, maps to `AcquisitionPathway[]`, PATCHes `run_state.pathways`
  + default `selectedPathway` (only when unset), and the dev mock drives the full path; validator +
  materializer + mock tests pass.
- [ ] **P6** `GET /v1/acquisition/runs/{run_id}/pathways-projection` exists on the gateway matching
  C13 with route tests; the slice works against real Airflow/MinIO.
- [ ] **P7** The wizard hydrates pathways from `run_state.pathways` (real data, mock behind
  `?demo=1`), with generate → poll wired, `dimensions` added to the FE type, and
  `selectedPathway`/`pathwayCommitted` persisted via debounced PATCH; service + hydration specs pass.
- [ ] **P8** An E2E drives the slice end-to-end via the in-process mock (create → seed record →
  generate → poll → `pathways` as `AcquisitionPathway[]` + `selectedPathway` → idempotent
  re-materialize → empty-record 422), with an in-repo byte-equal fixture-sync check.

## Tech stack reference

| Layer | Stack |
|-------|-------|
| Engine (ONERING) | Python 3.x, Airflow 3.x (KubernetesExecutor), Pydantic v2, Helm |
| Backend (rohan_api) | NestJS, TypeScript, TypeORM, Jest, ajv |
| Frontend (rohan_ui) | Angular 20+ (signals, zoneless, non-standalone module), Karma/Jasmine |
| Storage | MinIO (`AGENT_RUNS/{arc_run_id}/…` artifacts) — **no upload inputs for pathways** |
| Run tracking | `or_pipeline_runs` (reused; `mission_id` shipped), `acquisition_missions.run_state` |
| Auth | JWT; Airflow token via `OneringAirflowClientService` |
