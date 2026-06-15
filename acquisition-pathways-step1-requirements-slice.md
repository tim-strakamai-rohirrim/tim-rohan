# Acquisition Pathways — Step 1 vertical slice (Requirements Record via ONERING/Airflow)

> **Read this first.** This is the *thin end-to-end slice* that de-risks the whole
> Acquisition Pathways (AP) backend. It wires **one** wizard step — **Requirements
> Record** — from the uploaded mission documents all the way through an ONERING
> extraction run and back into the UI, proving the bridge, the ONERING step-graph
> integration, the artifact→`run_state` materialization, and the FE hydration with
> the *least* new domain content. Every later step (Pathway Selection, Package
> Assembly, Integrity Check, Finalize) repeats this exact shape. The broad map is in
> the companion **`acquisition-pathways-onering-integration-PLAN.md`**.

**Bridge decision (RESOLVED — team-agreed 2026-06-09):** all AP generation runs on the
**shipped Airflow `/onering/*` path** in rohan_api — *not* the auto-tag Service Bus path, and
*not* in-process answer-engine-v2 — for the **entire flow** (all five stages + agentic chat +
Auto-Run). This was decided jointly after comparing the in-process alternative in Alex's
*Acquisition Pathways Production Design Doc* (`ua-acquisition-pathways` PR #10); see the companion
plan's **Decision record (2026-06-09)** and three-topology comparison. The fast synchronous
`rohan-python-api` lane for low-latency ops is now a **possible far-future optimization only**,
not a planned refactor (companion Non-goals/Future work).

**Do Stage 0 first (engine-agnostic, no AI).** Per the companion plan's **phase F0** (adopted from
Alex's Stage 0), wire the wizard onto real `run_state` with *zero* generation — promote `run_state`
to the typed **`AcquisitionRunState`** interface (companion **Appendix E**), `createMission`
(mode passes through as `manual|auto` — the shipped contract; see S7.1), hydrate the five wizard signals, and persist on each `nextAction` — **before
or in parallel with** this slice. This slice's S7 then layers extraction-driven hydration on top of
an already-proven persistence path rather than introducing both at once.

Companion contracts are inline in this document (the slice is meant to be
self-contained). The broader epic gets its own `…-contracts.md`.

---

## Problem statement

The AP wizard's **Requirements Record** step is ~85% built on the frontend but runs
entirely on in-memory mock seed data (`INITIAL_REQUIREMENTS_RECORD_FIELDS`). The
rohan_api `acquisition-pathways` module already persists an opaque, client-owned
`run_state` JSON blob per mission, but nothing computes that state — there is no AI
backend. ONERING can produce exactly this artifact (document ingestion + per-field
extraction with line-level evidence), and ONERING's *shipped* integration path is the
Airflow-orchestrated `/onering/*` namespace in rohan_api (the same path that powers
proposal launch today).

This slice makes a real mission flow: **upload documents → trigger an ONERING
`arc_acquisition_requirements` DAG → extract a buyer-side requirements record with
evidence → materialize it into `acquisition_missions.run_state.canonicalRecord` →
hydrate the wizard's `requirementsRecord` signal from the server** instead of the mock.

## Key architectural observations

How the relevant areas work today (verified in code):

- **ONERING→product is Airflow, and it is shipped.** `rohan_api/src/onering/`
  contains `OneringPipelineService` (`launchProposal`/`stageOpportunity`/
  `triggerDiscovery`/`listRuns`/`getRun`/`refreshRunStatus`), `OneringAirflowClientService`
  (Airflow REST v2: `triggerDagRun`/`getDagRunStatus`/`listTaskInstances`/logs + token
  auth), `OneringArtifactService` (reads run artifacts from MinIO via the OneRing API),
  the `or_pipeline_runs` table/entity, the `OneringDagId`/`RunType`/`RunStatus` enums,
  and `OneringRunsController`/`OneringOpportunitiesController`. This slice **extends**
  that stack; it does not build a parallel one.
- **Custom step graphs already drive shipping DAGs.** `arc_strategy_pipeline_dag.py`
  invokes the ONERING CLI with `--steps-factory module:fn` through the
  `bash_for_steps_factory_step()` helper (`ONERING/airflow/dags/common/__init__.py:398`).
  The compliance epic (`archive/onering-compliance-integration-PLAN.md`) is the written
  precedent for adding a *new* ONERING-powered feature via a thin step factory + a new
  DAG. We mirror it.
- **The AP module already has its own home + persistence.** `rohan_api/src/acquisition-pathways/`
  has `acquisition_missions` (entity + `init_acquisition_pathways.sql`) with a `run_state`
  JSONB blob and `GET`/`PUT`/`PATCH /acquisition-pathways/missions/:id/state` endpoints
  (`ap-missions.controller.ts:210-291`, `ap-missions.service.ts:277-327`). `mergeState`
  is a shallow top-level merge (`{ ...current, ...patch }`, `ap-missions.service.ts:325`).
  The entity already documents the expected `run_state` keys, including
  **`canonicalRecord?: CrrField[]`** — the exact target for this slice
  (`acquisition-mission.entity.ts:54-70`). **Caveat:** that `CrrField[]` is only a doc-comment;
  the column type is the opaque `AcquisitionRunState = Record<string, unknown>`, and the
  `CrrField`/`SourcePill` types are defined only in **rohan_ui** (`requirements-record.types.ts`).
  So the S6 materializer must define the `CrrField`/`SourcePill` shape in rohan_api itself (the
  documented keys: `canonicalRecord, pathways, findings, ledger, artifacts, documents,
  selectedPathway, pathwayCommitted`).
- **The FE contract for the record is `CrrField[]`.** The wizard owns a
  `requirementsRecord = signal<CrrField[]>(…)` and passes it to the step as the
  `record` input. `RequirementsRecordStepComponent` reads `record` and renders
  per-field `tag` + `sources`. **Pre-S7** the signal was seeded with
  `INITIAL_REQUIREMENTS_RECORD_FIELDS` and the wizard never read/wrote the server
  `run_state`. **S7 changed this** to `signal<CrrField[]>([])` hydrated from
  `run_state.canonicalRecord`, with the mock seed moved behind `?demo=1`.
- **ONERING extraction already emits line-level evidence.** `pipelines/requirements/`
  and `pipelines/_common/models.py` define `EvidenceSpan(doc_id, start_line, end_line,
  page_number)` and the 4-phase pattern (per-chunk extract → per-doc aggregate → master
  → UI projection). We clone this pattern with buyer-side schemas/prompts; we do **not**
  reuse the RFP-response field set.
- **Polling, not webhooks.** `OneringPipelineService.refreshRunStatus()`
  (`onering-pipeline.service.ts:387`) is invoked on-demand from `getRun()`
  (`GET /onering/runs/:id`). The compliance precedent adds a `MATERIALIZING` intermediate
  status and runs its materializer inside the terminal-SUCCESS branch of
  `refreshRunStatus()`. We do the same.

## Data-flow (target state for this slice)

```
rohan_ui                         rohan_api (/onering + /acquisition-pathways)        Airflow / ONERING            MinIO
────────                         ───────────────────────────────────────────       ───────────────────          ─────
mission composer
  ├─ createMission ───────────▶  POST /acquisition-pathways/missions
  ├─ uploadFiles  ────────────▶  POST …/missions/:id/files ──── store ───────────────────────────────────────▶ acquisition/{org}/{mission}/uploads/*
  └─ triggerExtract ──────────▶  POST …/missions/:id/requirements:extract
                                   └─ OneringPipelineService.triggerAcquisitionRequirements()
                                        ├─ INSERT or_pipeline_runs(run_type=ACQUISITION_REQUIREMENTS, mission_id)
                                        └─ OneringAirflowClientService.triggerDagRun('arc_acquisition_requirements', …conf) ─▶ DAG runs CLI
                                                                                                                  --steps-factory acquisition_requirements:build_steps
                                                                                                                  (ingestion → acquisition_requirements → ui_projection)
                                                                                                                                              └─ writes ───▶ AGENT_RUNS/{run}/pipelines/acquisition_requirements_extraction/
                                                                                                                                                              ui/ui_projection_acquisition_requirements.json
poll GET /onering/runs/:id ───▶  refreshRunStatus()  (Airflow says SUCCESS)
                                   └─ set MATERIALIZING → AcquisitionRequirementsMaterializerService.materialize()
                                        ├─ read+validate artifact (OneringArtifactService) ◀───────────────────────────────────────────────── read
                                        ├─ map fields → CrrField[]
                                        └─ PATCH acquisition_missions.run_state.canonicalRecord  → set SUCCESS
on SUCCESS: GET …/missions/:id/state ─▶ hydrate requirementsRecord signal (CrrField[])  ✅ real data replaces the mock
```

## Assumptions

1. **`acquisition_missions` stays the source of truth for AP**; `or_pipeline_runs` is
   reused only for *run tracking* (status/progress/arc_run_id), linked by a new
   nullable `mission_id` column. We do **not** migrate AP onto `or_pipeline_runs`.
2. **Uploaded files land in MinIO** under a mission-keyed prefix that the DAG ingests
   via `dag_run.conf.document_uris`. **rohan_api has no MinIO write client today** — it only
   *reads* ONERING artifacts via the `onering_api` gateway, whose design rule is "bytes always
   stream — MinIO never leaves the OneRing network" — so the write path is new work (see Open
   question 1).
3. **`RunMode.MANUAL_UPLOAD` exists** (`orchestrator.py:83`), but conf-driven document intake
   does **not**: no `document_uris` key exists anywhere in ONERING today, and CLI ingestion
   stages files via `--files` / the local run workspace. The S1 factory therefore adds a small
   **document-staging step** (fetch the MinIO URIs into the run workspace) ahead of the
   ingestion subset (`docling_parse_base … chunk_plan`), followed by the new extraction + UI
   projection.
4. **`run_state` becomes co-owned**: the server materializer writes AI-produced
   top-level keys (`canonicalRecord`); the client writes user-edited keys. Of these,
   `selectedPathway` is already a documented `run_state` key; `requirementsRecordNotes` and
   dismissal flags are **new additive** keys (safe — `run_state` is an opaque blob). The shallow
   top-level `mergeState` keeps these non-conflicting. In this slice the user cannot
   edit the record until extraction completes (the UI shows a drafting state), so there
   is no first-write race; subsequent user edits PATCH `canonicalRecord` per existing
   behavior.
5. **Polling via `GET /onering/runs/:id`** is acceptable latency for extraction (mirrors
   proposal launch + the compliance plan). No new scheduler primitive.
6. **The `AcquisitionPathways` feature flag + `acquisition-pathways` permission** already
   gate the AP module (`featureFlags.ts`, `ap-missions.controller.ts:59-61`). New AP
   endpoints reuse the same guards.
7. **Buyer-side field set for v1** (kept deliberately small to limit new domain content):
   Mission / objective, Scope summary, NAICS/PSC, Estimated value, Period of performance,
   Place of performance, Socioeconomic considerations. Each carries `tag ∈ {extracted,
   inferred, needs}` and evidence spans. `tag = 'user'` is reserved for fields the user
   adds in the UI (never emitted by extraction).

## Open questions

| # | Question | Proposed default |
|---|----------|------------------|
| 1 | How do uploads get **written** to MinIO? rohan_api has no MinIO write client — `OneringArtifactService` only *reads*, via the `onering_api` gateway — and ONERING's design rule is "bytes always stream — MinIO never leaves the OneRing network". | **Add an upload route to the `onering_api` gateway** (ONERING-side, cross-repo — a small standalone PR or riding the S2 branch) and call it from `ApUploadsService` via the existing OneRing API client. Giving rohan_api direct MinIO credentials would violate the gateway design; only do that with ONERING owners' sign-off. Confirm bucket + prefix convention against `docs/specs/minio_path_contract.md` before S6. **Status (2026-06-12): the route never landed** — S2 (ONERING #414) merged without it, and S5/S6 shipped rohan_api clients against *assumed* routes. Now tracked as **Phase S9** (Contracts C18/C19). |
| 2 | Do we track the run in `or_pipeline_runs` (new `mission_id` column) or store the run handle inside `run_state.requirementsRun`? | **`or_pipeline_runs` + `mission_id`** — reuses `refreshRunStatus`, `getRun`, artifact listing, and matches the compliance precedent. `run_state` stores only a pointer (`run_state.requirementsRun = { arcRunId, status }`) for the FE convenience. |
| 3 | Does `RunStatus.MATERIALIZING` already exist, or is it added here? | Confirmed **absent** (current members: `QUEUED/RUNNING/SUCCESS/FAILED`, in `src/onering/enums/run-status.enum.ts` — its own file, not `run-type.enum.ts`); add it there (mirrors compliance Phase 4). `refreshRunStatus` switches only over `AirflowDagRunState`, not `RunStatus`, so no exhaustiveness break — just add the `MATERIALIZING` case where `RunStatus` is serialized to the FE. |
| 4 | Does `pipelines.requirements`'s aggregation reusably generalize, or do we fork a fresh `pipelines.acquisition_requirements`? | **Fork** a new pipeline package cloning the 4-phase structure + `EvidenceSpan`; new prompts + Pydantic models. Reuse `pipelines/_common/` helpers unchanged. Avoids coupling AP to RFP-response semantics. |
| 5 | Where does the FE poll from — a new AP status endpoint or `GET /onering/runs/:id`? | **`GET /onering/runs/:id`** (already does `refreshRunStatus`). The trigger response returns the run id; the FE polls it to terminal, then refetches mission state. |

## Post-S6 review findings (2026-06-12)

Verified-in-code findings from the S6 PR review (rohan_api #2035, merged 2026-06-12), after
syncing all repos to main. Ship status (updated 2026-06-15): **S1 ✅** (ONERING #409), **S2 ✅**
(ONERING #414), **S3–S6 ✅** (rohan_api #2031 = S4, #2034 = S5, #2035 = S6), **S7 in PR review**
(rohan_ui branch `tim/acquisition-pathways-onering/phase-S7` — substantially complete),
**S8 files present on `main`** (`.github/workflows/acquisition-requirements-schema-check.yml`
+ `test/acquisition-requirements.e2e-spec.ts`); confirm whether S8 merged under a separate PR —
`#2036` is not in the recent merge log. **S9/S10 not started.**

1. **The assumed gateway routes do not exist (BLOCKER outside the dev mock) → Phase S9.**
   The `onering_api` gateway on ONERING main has routers only for `/v1/runs`,
   `/v1/integrations`, `/v1/mission-control`, `/v1/onboarding`, `/v1/opportunities` — **no
   `/v1/acquisition/*` routes**, and no open ONERING PR adds them. Both shipped rohan_api
   clients point at assumed routes: S5's `uploadAcquisitionDocument` →
   `POST /v1/acquisition/uploads` (`onering-api.client.ts:353`) and S6's
   `getAcquisitionRequirementsProjection` →
   `GET /v1/acquisition/runs/{run_id}/requirements-projection`. In any environment with real
   Airflow the slice breaks at **upload time** (before the S6 read is ever reached); even a
   successful engine run would then fail materialization (gateway 404 → `AcquisitionSchemaError`
   → run FAILED). The dev mock masks all of this locally. Open-Q1 anticipated the upload route
   "riding the S2 branch", but S2 merged without it. **Action: Phase S9 (Contracts C18/C19).**

2. **`or_pipeline_runs.mission_id` nullability — verified correct, no action.**
   `@Column({ type: 'int', nullable: true }) mission_id: number | null`
   (`or-pipeline-run.entity.ts:32`). The materializer's null-guard is right and necessary
   (non-acquisition runs carry null `mission_id`).

3. **`CrrField` mirror — zero drift today, F0 still pending.** rohan_ui's
   `requirements-record.types.ts` and rohan_api's `acquisition-pathways/types/crr-field.ts`
   match character-for-character (`CrrTag`/`SourceKind`/`SourcePill`/`CrrField`). F0 has not
   landed — `AcquisitionRunState` is still `Record<string, unknown>`
   (`acquisition-mission.entity.ts:81`). Note: S8's CI cross-check covers the **artifact
   schema**, not these UI-facing TS types; the type mirror is reconciled by F0, not S8. No new
   phase; reconcile into `AcquisitionRunState` when F0 lands (as the S6.2 step already says).

4. **Dev mock bricks a mission's extraction after a process restart → Phase S10.** The mock's
   registries are per-process. After a restart, `getDagRunStatus` for an in-flight mocked run
   throws "mock DAG run not found" — which `refreshRunStatus()`'s outer `catch` **swallows with
   a log warning, leaving the run QUEUED/RUNNING forever**. The C10 in-flight guard then 409s
   every re-trigger for that mission (`QUEUED | RUNNING | MATERIALIZING` all block) until
   someone manually clears the row. Worse than the "artifact 404" failure assumed during
   review: the run never reaches the artifact read at all. Same orphaned-QUEUED class as the
   documented stage-run edge case, but stage soft-returns `already_staging` while this path
   hard-409s. Dev-only, but a real trap for UI engineers. **Action: Phase S10 (Contract C20).**

5. **Artifact JSON read is size-unbounded — folded into S10 as cheap hardening.** The shared
   gateway axios client is created with `maxContentLength: Infinity`
   (`onering-api.client.ts:106`), so the projection read parses `resp.data` with no size cap —
   same class as the existing gateway JSON reads. Low severity; S10 caps it per-request rather
   than touching the shared client default.

**As-built contract deviations (documented in rohan_api #2035, now reflected in C12/C13/C14
below):** C12's `loadAndValidate` takes the run **row** (not a bare `arcRunId`) for tenant
context; C13 maps the pill label as `doc_name || doc_id` (not `??` — C3 allows empty-string
`doc_name`); C14's mock serves the stamped fixture **in-memory at the artifact-read seam**
(rohan_api has no MinIO write client by design) and additionally gates off when `KEY_VAULT_NAME`
is set; the validator + materializer are **provided by `OneringModule`** (not the AP module) to
avoid a circular import.

## Non-goals (this slice)

- Pathway Selection scoring, Package Assembly writing, Integrity Check, Finalize — all
  in the companion epic.
- The **fast synchronous `rohan-python-api` lane** (hybrid Option 2). Given the team decision to
  run **ONERING for the entire flow**, this is a **possible far-future optimization only** (revisit
  only if profiling shows Airflow latency hurts pathway re-score UX) — **not** a planned refactor and
  **not** built here. Flagged in the epic's "Future work."
- Audit-trail UI, document viewer for source pills, download/export.
- Prod-readiness (SLO/alerts/runbook) — folded into the epic's Stream D; this slice
  ships behind the existing feature flag in dev/staging only.

---

## Implementation phases

Branching: `{user}/{epic}/phase-{N}`, epic = `acquisition-pathways-onering`. Each phase
is one repo / one PR. `base_branch: base` = main of that repo; `base_branch: phase-N` =
prior phase in the **same** repo. Cross-repo phases coordinate via the contracts in this
doc, not via git stacking.

### Phase S1 — Engine: `acquisition_requirements` extraction pipeline + step factory [PYTHON]

```phase-meta
phase: S1
title: ONERING - acquisition_requirements pipeline + acquisition_requirements:build_steps factory
tags: [PYTHON]
repo: onering
base_branch: base
depends_on: []
files:
  - arc_agent_writer/pipelines/acquisition_requirements/__init__.py
  - arc_agent_writer/pipelines/acquisition_requirements/models.py
  - arc_agent_writer/pipelines/acquisition_requirements/prompts.py
  - arc_agent_writer/pipelines/acquisition_requirements/extraction.py
  - arc_agent_writer/pipelines/acquisition_requirements/aggregation.py
  - arc_agent_writer/pipelines/acquisition_requirements/pipeline.py
  - arc_agent_writer/pipelines/acquisition_requirements/ui_projection.py
  - arc_agent_writer/factories/__init__.py
  - arc_agent_writer/factories/acquisition_requirements.py
  - arc_agent_writer/tests/factories/test_acquisition_requirements_factory.py
  - arc_agent_writer/tests/fixtures/ui_projection_acquisition_requirements.sample.json
  - arc_agent_writer/CLAUDE.md
  - docs/specs/minio_path_contract.md
contracts:
  - "C1 acquisition_requirements:build_steps step factory"
  - "C2 pipelines.acquisition_requirements output models"
  - "C3 ui_projection_acquisition_requirements.json v1"
verification:
  - uv run pytest arc_agent_writer/tests/factories/test_acquisition_requirements_factory.py
  - uv run python -m arc_agent_writer.cli run --steps-factory arc_agent_writer.factories.acquisition_requirements:build_steps --dry-run
```

**Goal**: a thin, buyer-side extraction graph that runs `ingestion (docling_parse_base …
chunk_plan) → pipelines.acquisition_requirements → ui_projection_acquisition_requirements`
and writes a `CrrField[]`-shaped UI projection. Reuse the ingestion + `EvidenceSpan` +
4-phase patterns; new domain content only in models/prompts.

**Steps**:

- [ ] **S1.1** Create `pipelines/acquisition_requirements/` cloning the structure of
  `pipelines/requirements/`. Define Pydantic models per **Contract C2**:
  `AcquisitionRequirementChunkOutput`, `AcquisitionRequirementItem` (with
  `evidence: list[EvidenceSpan]` from `pipelines/_common/models.py:14`), the per-doc/master
  aggregation models, and `AcquisitionRequirementsUIProjection`. Inherit from the shared
  `RecordModel` (`pipelines/_common/record_model.py:224` — a **dataclass-backed** model, *not*
  Pydantic; `EvidenceSpan` *is* a Pydantic `BaseModel`, and existing pipelines mix the two the
  same way). **Note:** the shared `EvidenceSpan` declares only
  `doc_id/start_line/end_line/page_number` (it is `extra="allow"`, so additional keys pass).
  C3's evidence carries `snippet` + `doc_name`, and C13 maps `e.doc_name ?? e.doc_id` → the
  source pill label — so the `ui_projection` step (S1.5) must explicitly populate `snippet` and
  `doc_name` on each emitted span (resolve `doc_name` from the doc manifest), since they are not
  guaranteed by the base model.
- [ ] **S1.2** Write `prompts.py` for the v1 buyer-side field set (Assumption 7). The
  persona is a **government acquisition analyst** extracting the *requirement record for a
  buy*, not an RFP-responder. Emit `tag ∈ {extracted, inferred, needs}` per field with a
  one-line rationale and evidence spans. **Never** emit `tag = 'user'`.
- [ ] **S1.3** Implement the 4 phase functions in `extraction.py`/`aggregation.py`/
  `pipeline.py`/`ui_projection.py` mirroring metadata/requirements entry functions; all LLM
  calls go through `ctx.llm_controller.call_structured(output_model=…, …)`.
- [ ] **S1.4** Implement `factories/acquisition_requirements.py:build_steps(*, cfg, artifact_store) -> list[StepDef]`
  per **Contract C1** (**keyword signature** — the CLI loader *always* invokes factories as
  `fn(cfg=cfg, artifact_store=store)`, `cli.py:19380`, with no signature adaptation; do **not**
  copy `cli.py:build_strategy_only_steps()`, which is zero-argument and would `TypeError`
  through this exact path) — a document-staging step (fetch `document_uris` into the run
  workspace; **new** — no conf-driven intake exists today) + ingestion subset + the new
  pipeline + UI projection. Inject empty defaults where the extraction expects upstream
  projections it no longer gets (mirror the compliance factory note); document any
  pipeline-internal change in the PR.
- [ ] **S1.5** UI projection writes `pipelines/acquisition_requirements_extraction/ui/ui_projection_acquisition_requirements.json`
  under the run root — mirroring the shipped convention
  (`REQUIREMENTS_UI_RELPATH = "pipelines/requirements_extraction/ui/ui_projection_requirements.json"`) —
  matching **Contract C3** (incl. `schema_version: "1"`, `run_id`, `mission_id`, `fields[]`).
  Update `docs/specs/minio_path_contract.md` in the same PR (repo rule for bucket-layout
  changes). Read-side consumers derive the runs prefix via
  `onering_shared.storage.paths.runs_prefix_for(store)` — never hard-code `AGENT_RUNS/`.
- [ ] **S1.6** Add the sample fixture (referenced by S8's dev mock and S-CI cross-check) and
  the factory unit test (step ordering/count, no metadata/structure/evaluation steps).
- [ ] **S1.7** Note the factory + invocation in `arc_agent_writer/CLAUDE.md`.

### Phase S2 — Engine: `arc_acquisition_requirements` DAG + JSON schema [PYTHON]

```phase-meta
phase: S2
title: ONERING - arc_acquisition_requirements DAG + ui_projection schema
tags: [PYTHON]
repo: onering
base_branch: phase-S1
depends_on: [S1]
files:
  - airflow/dags/arc_acquisition_requirements_dag.py
  - arc_agent_writer/tests/test_airflow_dag_acquisition_requirements.py
  - specs/ui_projection_acquisition_requirements.schema.json
  - airflow/CLAUDE.md
contracts:
  - "C4 arc_acquisition_requirements DAG dag_run.conf envelope"
  - "C3 ui_projection_acquisition_requirements.json v1 JSON Schema"
verification:
  - uv run pytest arc_agent_writer/tests/test_airflow_dag_acquisition_requirements.py
  - "python -c 'import json,jsonschema; jsonschema.Draft7Validator.check_schema(json.load(open(\"specs/ui_projection_acquisition_requirements.schema.json\")))'"
```

**Goal**: ship the DAG that runs the factory and freeze the v1 artifact schema.

**Steps**:

- [ ] **S2.1** Create `airflow/dags/arc_acquisition_requirements_dag.py` mirroring
  `arc_strategy_pipeline_dag.py` (which already uses `--steps-factory` via
  `bash_for_steps_factory_step()`). `dag_id="arc_acquisition_requirements"`. The Bash step
  runs (via `bash_for_steps_factory_step()`, which already templates
  `--run-id "{{ dag_run.conf['run_id'] }}"`) `python -m arc_agent_writer.cli run --steps-factory
  arc_agent_writer.factories.acquisition_requirements:build_steps`, with org/user exported as
  env (`ONERING_DEV_ORG_ID`/`ONERING_DEV_USER_ID`). **The conf key is `run_id`** (the helper
  reads `dag_run.conf['run_id']` and errors if absent — do not name it `expected_run_id`).
  **The shipped helper templates only `run_id`** — forwarding `document_uris` + `mission_id`
  from conf to the CLI/factory is *new templating this DAG adds* (extend the bash command or
  export them as env, mirroring how org/user are exported). Tags `["arc","acquisition","extraction"]`,
  `max_active_runs=4`, retries 1 / 5 min. `dag_run.conf` per **Contract C4**.
- [ ] **S2.2** DAG unit test mirroring `test_airflow_dag_*`: loads, task order, conf parsing,
  env export.
- [ ] **S2.3** `specs/ui_projection_acquisition_requirements.schema.json` per **Contract C3**,
  with `schema_version: "1"` constant (rohan_api rejects unknown versions). Validate the S1
  fixture against it. (`specs/` holds only markdown today — this is the first `*.schema.json`
  there; a new but deliberate convention.)
- [ ] **S2.4** Document DAG + conf in `airflow/CLAUDE.md`. Reuse existing LLM pools (no new
  pool needed for a single thin extraction graph; revisit only if profiling shows
  saturation).

### Phase S3 — rohan_api: enums, conf type, DTOs [BACKEND_DB]

```phase-meta
phase: S3
title: rohan_api - OneringDagId/RunType/RunStatus + AcquisitionRequirementsConf + DTOs
tags: [BACKEND_DB]
repo: rohan_api
base_branch: base
depends_on: []
files:
  - src/onering/types/airflow.types.ts
  - src/onering/enums/run-type.enum.ts
  - src/onering/enums/run-status.enum.ts
  - src/acquisition-pathways/dto/runs/extract-requirements.dto.ts
  - src/acquisition-pathways/dto/runs/index.ts
contracts:
  - "C5 Enum extensions (OneringDagId, RunType, RunStatus)"
  - "C6 AcquisitionRequirementsConf"
  - "C7 TriggerRequirementsExtractDto + RequirementsRunResponse"
verification:
  - npm run lint
  - npm run build
```

**Goal**: land all rohan_api type/enum/DTO surface area with no behavior change.

**Steps**:

- [ ] **S3.1** `OneringDagId.ACQUISITION_REQUIREMENTS = 'arc_acquisition_requirements'`
  (`airflow.types.ts`).
- [ ] **S3.2** `RunType.ACQUISITION_REQUIREMENTS = 'ACQUISITION_REQUIREMENTS'`
  (`run-type.enum.ts`). Add `RunStatus.MATERIALIZING = 'MATERIALIZING'` in
  **`run-status.enum.ts`** (its own file; confirmed absent today — Open Q3).
- [ ] **S3.3** `AcquisitionRequirementsConf` interface + extend the `DagRunConf` union
  (`airflow.types.ts`) per **Contract C6**.
- [ ] **S3.4** `TriggerRequirementsExtractDto` + `RequirementsRunResponse` with
  `class-validator` + `@nestjs/swagger` per **Contract C7**.
- [ ] **S3.5** Grep the `onering` module for `RunType`/`RunStatus`/`OneringDagId`
  `switch`/`if`-chains that assume the old member set. Note: `refreshRunStatus()`'s only switch
  is `mapAirflowState()` over `AirflowDagRunState` (with a `default` fallback,
  `onering-pipeline.service.ts:462-475`) — it does **not** switch over `RunType`/`RunStatus`, so
  adding the new members won't break it. There is no exhaustive-match break to fix here; the
  real work is the new SUCCESS-branch hook in S6.3.

### Phase S4 — DB: `or_pipeline_runs.mission_id` + `materialized_at` [BACKEND_DB]

```phase-meta
phase: S4
title: DB - or_pipeline_runs.mission_id typed column + materialized_at + index
tags: [BACKEND_DB]
repo: rohan_api
base_branch: phase-S3
depends_on: [S3]
files:
  - src/onering/entities/or-pipeline-run.entity.ts
  - scripts/sql/<synced-from-Database-repo>.sql
contracts:
  - "C8 or_pipeline_runs additions (mission_id, materialized_at)"
verification:
  - npm run lint
  - npm run build
  - npm run db:test:up
```

**Goal**: schema first, so the trigger service (S5) writes typed columns unconditionally.

**Steps**:

- [ ] **S4.1** **In the `Database/` repo**, author a migration: `or_pipeline_runs.mission_id
  INTEGER NULL`, `or_pipeline_runs.materialized_at TIMESTAMPTZ NULL` (if not present), and
  index `or_pipeline_runs (organization_id, mission_id, started_at DESC)`. `IF NOT EXISTS`
  everywhere. Verify `run_type` accepts the new enum value without a CHECK/enum DDL change;
  if constrained, update the constraint in the same migration.
- [ ] **S4.2** Run the rohan_api sync script to pull SQL into `scripts/sql/`. **Do not edit
  `scripts/sql/` directly** (per `rohan_api/CLAUDE.md`).
- [ ] **S4.3** Add TypeORM columns (`missionId`, `materializedAt`) to `or-pipeline-run.entity.ts`.
- [ ] **S4.4** `npm run db:test:up` and confirm.

### Phase S5 — rohan_api: file upload → MinIO + `triggerAcquisitionRequirements()` [BACKEND_DB]

```phase-meta
phase: S5
title: rohan_api - upload endpoint + OneringPipelineService.triggerAcquisitionRequirements()
tags: [BACKEND_DB]
repo: rohan_api
base_branch: phase-S4
depends_on: [S4]
files:
  - src/acquisition-pathways/controllers/ap-missions.controller.ts
  - src/acquisition-pathways/services/ap-missions.service.ts
  - src/acquisition-pathways/services/ap-uploads.service.ts
  - src/acquisition-pathways/services/ap-uploads.service.spec.ts
  - src/acquisition-pathways/entities/acquisition-mission.entity.ts
  - src/onering/services/onering-pipeline.service.ts
  - src/onering/services/onering-pipeline.service.spec.ts
  - src/acquisition-pathways/acquisition-pathways.module.ts
contracts:
  - "C9 POST /acquisition-pathways/missions/:id/files"
  - "C10 POST /acquisition-pathways/missions/:id/requirements:extract"
  - "C11 OneringPipelineService.triggerAcquisitionRequirements()"
verification:
  - npm run lint
  - npm run test -- src/acquisition-pathways/services/ap-uploads.service.spec.ts
  - npm run test -- src/onering/services/onering-pipeline.service.spec.ts
```

**Goal**: accept uploads into MinIO and trigger the DAG, tracked in `or_pipeline_runs`.

**Steps**:

- [ ] **S5.1** Implement `ApUploadsService` that stores multipart files at
  `acquisition/{org_id}/{mission_id}/uploads/{filename}` via the Open-Q1 write path (expected:
  a new `onering_api` gateway upload route — rohan_api has no MinIO write client) and updates
  `acquisition_missions.attached_files`. Extend `AcquisitionAttachedFile` with an optional
  `uri` (today it is `{ name, size?, mime? }`, entity `:48-52`). Returns
  `[{ name, size, mime, uri }]`.
- [ ] **S5.2** Add `POST /acquisition-pathways/missions/:id/files` per **Contract C9** to
  `ApMissionsController` (same `AuthGuard`/`FeatureGuard('AcquisitionPathways')`/
  `Permissions('acquisition-pathways')` guards as the existing routes), delegating to
  `ApUploadsService` + ownership check.
- [ ] **S5.3** Implement `OneringPipelineService.triggerAcquisitionRequirements(user,
  missionId, documentUris, options)` per **Contract C11**: resolve org, generate `arc_run_id`,
  `INSERT or_pipeline_runs(run_type=ACQUISITION_REQUIREMENTS, mission_id, status=QUEUED)`,
  call `OneringAirflowClientService.triggerDagRun('arc_acquisition_requirements', dagRunId,
  conf)`. Mirror `launchProposal`'s error mapping (`OneringAirflowError` on transport
  failure; row FAILED) and its `reconcileTriggerFailure()` idempotency: on any trigger
  failure, probe Airflow for the DAG run before failing the row. (Shipped code has **no
  explicit 409 catch** — reconcile by state, not by status code.)
- [ ] **S5.4** Add `POST /acquisition-pathways/missions/:id/requirements:extract` per
  **Contract C10** — resolves uploaded `documentUris` from the mission, calls the trigger,
  stores a pointer at `run_state.requirementsRun = { arcRunId, status: 'QUEUED' }` (PATCH),
  returns `RequirementsRunResponse`.
- [ ] **S5.5** Unit tests: happy path, Airflow trigger failure, trigger-failure reconcile
  (DAG run already exists in Airflow → row not marked FAILED), ownership 404,
  empty-uploads guard.

### Phase S6 — rohan_api: artifact validator + materializer + dev mock [BACKEND_DB]

```phase-meta
phase: S6
title: rohan_api - requirements artifact validator, materializer into run_state.canonicalRecord, dev Airflow mock
tags: [BACKEND_DB]
repo: rohan_api
base_branch: phase-S5
depends_on: [S5]
files:
  - src/acquisition-pathways/types/crr-field.ts
  - src/acquisition-pathways/services/ap-requirements-projection-validator.service.ts
  - src/acquisition-pathways/services/ap-requirements-projection-validator.service.spec.ts
  - src/acquisition-pathways/services/ap-requirements-materializer.service.ts
  - src/acquisition-pathways/services/ap-requirements-materializer.service.spec.ts
  - src/onering/services/onering-pipeline.service.ts
  - src/onering/services/onering-pipeline.service.spec.ts
  - src/onering/__mocks__/ui_projection_acquisition_requirements.fixture.json
  - src/acquisition-pathways/acquisition-pathways.module.ts
contracts:
  - "C12 Artifact validator (ajv, version-strict)"
  - "C13 Materializer behavior + field→CrrField mapping"
  - "C14 In-process Airflow mock"
verification:
  - npm run lint
  - npm run test -- src/acquisition-pathways/services/ap-requirements-projection-validator.service.spec.ts
  - npm run test -- src/acquisition-pathways/services/ap-requirements-materializer.service.spec.ts
  - npm run test -- src/onering/services/onering-pipeline.service.spec.ts
```

**Goal**: on terminal SUCCESS, validate the artifact and materialize it into
`run_state.canonicalRecord` as `CrrField[]`; let UI engineers iterate without real Airflow.

**Steps**:

- [ ] **S6.1** `ApRequirementsProjectionValidatorService` (ajv@^8, `additionalProperties:
  true`, **version-strict** on `schema_version` — reject unknown versions) per **Contract
  C12**. Reads the artifact via `OneringArtifactService` and validates against the C3 schema.
- [ ] **S6.2** Type the `CrrField`/`SourcePill` shape in rohan_api. **If F0 has landed**, reuse the
  mirrored **`AcquisitionRunState`** interface it promotes (companion **Appendix E**) —
  `canonicalRecord` is already `CrrField[]` there. **If the slice runs ahead of F0**, add a small
  `acquisition-pathways/types/crr-field.ts` mirroring the rohan_ui definition (today `run_state` is
  opaque `Record<string, unknown>` and the types live only in rohan_ui) and reconcile it into
  `AcquisitionRunState` when F0 lands. Then `ApRequirementsMaterializerService.materialize(arcRunId)` per **Contract C13**,
  strict **Phase A** (read + validate + cross-check `json.run_id == run.arc_run_id` and
  `json.mission_id == run.mission_id`; no DB tx) / **Phase B** (map `fields[]` → `CrrField[]`,
  PATCH `acquisition_missions.run_state` shallow-merging `canonicalRecord` + clearing the
  `requirementsRun.status` to `SUCCEEDED`, set `materialized_at`, flip run SUCCESS; single
  short tx, no network IO). Field mapping: `evidence[]` → `sources: [{ kind: 'upload', label:
  <doc filename>, docId: <doc_id> }]`; `tag` passes through (`extracted|inferred|needs`).
- [ ] **S6.3** Extend `OneringPipelineService.refreshRunStatus()` so that *after* `mapAirflowState()`
  resolves a terminal SUCCESS, a `run_type === ACQUISITION_REQUIREMENTS` branch sets
  `MATERIALIZING`, invokes the materializer, then commits SUCCESS (closes the race where SUCCESS
  is visible before `canonicalRecord` exists). This is a new `run_type` branch in the
  post-mapping path — `mapAirflowState()` itself stays a switch over `AirflowDagRunState` and is
  unchanged. Add the `MATERIALIZING` case wherever `RunStatus` is rendered/serialized to the FE.
- [ ] **S6.4** Add `AirflowMockService` toggle (reuse/mirror the compliance Phase 9 design):
  when `ONERING_AIRFLOW_BASE_URL` is empty + `NODE_ENV !== 'production'`, `triggerDagRun`
  writes the S1 fixture to MinIO at the artifact path and schedules a ~100 ms flip of the
  `or_pipeline_runs` row to SUCCESS, so the polling path materializes naturally. Copy the
  fixture from ONERING into `src/onering/__mocks__/`.
- [ ] **S6.5** Tests: validator (happy, unknown `schema_version`, missing field, type
  mismatch); materializer (map→CrrField, run/mission cross-check mismatch rejects, idempotent
  re-materialize via `materialized_at`); mock writes fixture + materializes end-to-end.

### Phase S7 — rohan_ui: wire mission create → upload → extract → poll → hydrate [FRONTEND]

```phase-meta
phase: S7
title: rohan_ui - real mission/upload/extract + run polling + requirementsRecord hydration
tags: [FRONTEND]
repo: rohan_ui
base_branch: base
depends_on: [S5]
files:
  - src/app/pages/acquisition-pathways/services/acquisition-pathways.service.ts
  - src/app/pages/acquisition-pathways/services/acquisition-pathways-api.service.ts
  - src/app/pages/acquisition-pathways/services/acquisition-run.service.ts
  - src/app/pages/acquisition-pathways/services/acquisition-run.service.spec.ts
  - src/app/pages/acquisition-pathways/components/landing/ap-landing.component.ts
  - src/app/pages/acquisition-pathways/wizard/acquisition-pathways-wizard.component.ts
  - src/app/pages/acquisition-pathways/acquisition-pathways-routing.module.ts
  - src/app/pages/acquisition-pathways/types/acquisition-pathways.types.ts
contracts:
  - "C9/C10/C15 FE consumption of upload/extract/state endpoints"
  - "C16 run_state hydration contract"
verification:
  - npm run lint
  - npm run test:ci -- --include='**/acquisition-run.service.spec.ts'
  - npm run build
```

**Goal**: replace the Requirements Record mock with server data, end to end.

> **Contract-stability gate.** S7 branches off `main` but logically depends on S3+S5
> contracts being frozen (the rohan_api PRs are the source of truth). Code against the
> contracts in this doc + the PR diffs, not a running backend.

**Steps**:

- [ ] **S7.1** Replace the `createMission()`/`uploadFiles()` `of(MOCK…)` stubs with real
  `RequestService` calls per **Contracts C9/C15** (`POST /acquisition-pathways/missions`,
  `POST …/missions/:id/files` multipart). **As built:** these HTTP calls live in a dedicated
  `AcquisitionPathwaysApiService` (created in S7), not on `AcquisitionPathwaysService` — the
  landing component and wizard call the api service directly. Pass the
  composer's `mode` through **unchanged** — the shipped contract is `mode ∈ {manual, auto}`
  (`acquisition-mission.entity.ts:10`, DTO `@IsIn(ACQUISITION_MISSION_MODES)`, DB CHECK
  constraint; `init_acquisition_pathways.sql` migrates legacy `drive→manual`). **No
  `manual→drive` mapping** — the companion plan's Appendix F had this backwards and has been
  corrected. Ideally this `createMission` wiring is already done in F0.
- [ ] **S7.2** New `AcquisitionRunService`: `triggerRequirements(missionId)` →
  `POST …/missions/:id/requirements:extract`; `pollRun(arcRunId)` → polls
  `GET /onering/runs/:id` to terminal (10 s cadence, back off to 30 s after 5 min);
  `getState(missionId)` → `GET …/missions/:id/state`.
- [ ] **S7.3** `ApLandingComponent.onMissionStarted()` (`ap-landing.component.ts:59`; TODO
  comment + navigate-only stub at :65): `createMission` → `uploadFiles` → `triggerRequirements` → navigate to
  `/acquisition-pathways/wizard/{missionId}/requirements-record`. **Add a
  `wizard/:missionId/:step` route** in `acquisition-pathways-routing.module.ts` — today the
  wizard route is `wizard/:step` only (no mission id; the only `:id` route is `mission/:id`
  on the workspace component). Keep the id-less `wizard/:step` route as the `?demo=1` seed
  mode.
- [ ] **S7.4** Wizard hydration per **Contract C16**: on load with `:missionId`, `getState(missionId)`.
  If `run_state.canonicalRecord` present → set `requirementsRecord.set(canonicalRecord)`.
  Else, if a `requirementsRun` is in flight → show a drafting/extracting state and `pollRun`;
  on SUCCESS, refetch state and hydrate. **The drafting state is new UI for this step** — the
  requirements-record step has no loading state today; the only existing drafting affordance
  is `package-assembly-step`'s `CardState`/`loading` pattern, so mirror that rather than
  inventing a new one. Fall back to the seed only in a dedicated `?demo=1` mode (keep the
  mock importable for design/dev).
- [ ] **S7.5** Persist user edits: when the user edits/adds/removes a field, PATCH
  `run_state.canonicalRecord` (debounced) so reload is stable. (`RequirementsRecordStepComponent`
  already mutates the `record` signal; add the persistence side-effect in the wizard.)
- [ ] **S7.6** Spec the run service (poll cadence + terminal resolution) + a wizard hydration
  test. Keep the existing requirements-record step spec green.

### Phase S8 — CI: schema + fixture cross-check [TEST_REVIEW]

```phase-meta
phase: S8
title: CI - acquisition_requirements schema + mock-vs-engine fixture cross-check
tags: [TEST_REVIEW]
repo: rohan_api
base_branch: phase-S6
depends_on: [S6]
files:
  - .github/workflows/acquisition-requirements-schema-check.yml
  - test/acquisition-requirements.e2e-spec.ts
  - test/fixtures/ui_projection_acquisition_requirements.fixture.json
contracts:
  - "C17 schema cross-check job"
verification:
  - npm run lint
  - npm run test:e2e -- --grep acquisition-requirements
```

**Goal**: catch artifact-schema drift between ONERING and rohan_api.

**Steps**:

- [ ] **S8.1** Per-PR job: validate the rohan_api ajv compiler against the ONERING-side sample
  fixture (at the pinned ref) **and** assert byte-equal sync between
  `src/onering/__mocks__/ui_projection_acquisition_requirements.fixture.json` and the ONERING
  fixture. Mirrors compliance Phase 12.2.
- [ ] **S8.2** E2E using the in-process mock (`ONERING_AIRFLOW_BASE_URL` empty): create
  mission → upload → extract → poll → assert `run_state.canonicalRecord` materialized as
  `CrrField[]`; assert idempotent re-materialize.

### Phase S9 — Engine: `onering_api` acquisition gateway routes (upload write + projection read) [PYTHON]

> Added 2026-06-12 from post-S6 review finding 1. **Blocker for any environment with real
> Airflow** — both routes are already called by merged rohan_api code (S5 + S6) against the
> shapes frozen in C18/C19 below. If the gateway must deviate, change the two rohan_api
> client methods in the same coordinated change.

```phase-meta
phase: S9
title: ONERING - onering_api /v1/acquisition routes (upload write + requirements-projection read)
tags: [PYTHON]
repo: onering
base_branch: base
depends_on: [S2]
files:
  - onering_api/routers/acquisition.py
  - onering_api/services/acquisition.py
  - onering_api/schemas.py
  - onering_api/server.py
  - onering_api/tests/test_acquisition_routes.py
  - docs/specs/minio_path_contract.md
contracts:
  - "C18 POST /v1/acquisition/uploads"
  - "C19 GET /v1/acquisition/runs/{run_id}/requirements-projection"
verification:
  - uv run pytest onering_api/tests/test_acquisition_routes.py
```

**Goal**: land the two gateway routes that the merged rohan_api S5/S6 clients already call, so
the slice works against real Airflow/MinIO (today it only works under the in-process dev mock).

**Steps**:

- [ ] **S9.1** New `onering_api/routers/acquisition.py` with
  `APIRouter(prefix="/v1/acquisition", dependencies=[Depends(get_principal)])`, registered in
  `server.py` (mirror the existing `include_router` block, `server.py:92-101`).
- [ ] **S9.2** `POST /v1/acquisition/uploads` per **Contract C18**: multipart body with an
  `object_key` form field + a `file` part; stream the bytes to MinIO at `object_key` (mirror
  `routers/user_uploads.py`'s streaming-upload pattern — never buffer the whole file).
  Validate `object_key` against `acquisition/{org_id}/{mission_id}/uploads/{filename}`
  (reject traversal/absolute keys → 400) and require the `{org_id}` segment to equal the
  `X-Onering-Org-Id` tenant header → 403 on mismatch (tenant isolation — the key is
  caller-computed in rohan_api's `ApUploadsService`).
- [ ] **S9.3** `GET /v1/acquisition/runs/{run_id}/requirements-projection` per **Contract
  C19**: resolve the run prefix via `onering_shared.storage.paths.runs_prefix_for(store)`
  (never hard-code `AGENT_RUNS/`), read
  `pipelines/acquisition_requirements_extraction/ui/ui_projection_acquisition_requirements.json`,
  return the raw JSON (200) or 404 when absent. rohan_api maps 404 → `null` → retains its
  "SUCCESS but no artifact = engine-contract violation" semantics.
- [ ] **S9.4** Update `docs/specs/minio_path_contract.md` with the `acquisition/…/uploads/`
  input prefix (repo rule for bucket-layout changes; the S1/S2 PRs documented only the run
  artifact path).
- [ ] **S9.5** Route tests: upload happy path (201 created / 200 overwrite + response shape),
  `object_key` validation rejects (400) + org mismatch (403), projection read happy path,
  projection 404 when the artifact is absent.

### Phase S10 — rohan_api: dev-mock restart recovery + artifact read size cap [BACKEND_DB]

> Added 2026-06-12 from post-S6 review findings 4 and 5. Dev-ergonomics fix (a restart
> mid-extraction permanently 409-blocks the mission under the mock) plus cheap read-path
> hardening. Branches off main — S6 is merged.

```phase-meta
phase: S10
title: rohan_api - Airflow mock unknown-run recovery + projection read maxContentLength
tags: [BACKEND_DB]
repo: rohan_api
base_branch: base
depends_on: [S6]
files:
  - src/onering/services/onering-airflow-mock.service.ts
  - src/onering/services/onering-airflow-mock.service.spec.ts
  - src/onering/services/onering-pipeline.service.ts
  - src/onering/services/onering-pipeline.service.spec.ts
  - src/onering/clients/onering-api.client.ts
contracts:
  - "C20 Mock unknown-run recovery"
verification:
  - npm run lint
  - npm run test -- src/onering/services/onering-airflow-mock.service.spec.ts
  - npm run test -- src/onering/services/onering-pipeline.service.spec.ts
```

**Goal**: a process restart while a mocked extraction is in flight must not leave the run
stuck QUEUED/RUNNING (and the mission 409-blocked) forever; cap the projection read size.

**Steps**:

- [ ] **S10.1** Per **Contract C20**: in `refreshRunStatus()`'s catch path, when the mock owns
  the DAG (`airflowMock.shouldHandle(run.airflow_dag_id)`) and the error is the mock's
  unknown-run 404, flip the run to FAILED with the literal
  `error_message = 'Dev Airflow mock lost run state (process restart) — re-trigger the extraction'`
  and save. This unblocks the C10 in-flight 409 guard. **Gotcha:** keep the mock's
  `getDagRunStatus` *throwing* on unknown runs — `reconcileTriggerFailure()`'s probe semantics
  ("status check throws ⇒ the DAG run never reached Airflow ⇒ fail the row") depend on it;
  recovery belongs in the refresh path, not in the mock's return value.
- [ ] **S10.2** Expose the unknown-run case distinguishably from the mock (e.g. a typed
  `OneringAirflowError` flag or a `isUnknownRun(dagRunId)` helper) rather than string-matching
  the message in the pipeline service.
- [ ] **S10.3** Cap the projection read: pass a per-request `maxContentLength` (25 MB) in
  `getAcquisitionRequirementsProjection`'s axios config (finding 5 — the shared client default
  is `Infinity`; do not change the shared default, other routes stream large artifacts).
- [ ] **S10.4** Tests: restart simulation (run row QUEUED + empty mock registry → refresh
  flips FAILED with the literal message; subsequent `requirements:extract` no longer 409s);
  `reconcileTriggerFailure` probe semantics unchanged; oversized projection response rejects.

## Phase order, dependencies, parallelism

### File-touch matrix

| Phase | ONERING files | rohan_api files | rohan_ui files | Database |
|-------|---------------|-----------------|----------------|----------|
| S1 | pipelines/acquisition_requirements/, factories/ | — | — | — |
| S2 | airflow/dags/, specs/ | — | — | — |
| S3 | — | onering/types, onering/enums, acquisition-pathways/dto | — | — |
| S4 | — | onering/entities, scripts/sql | — | migration |
| S5 | — | acquisition-pathways/{controllers,services}, onering/services/pipeline | — | — |
| S6 | — | acquisition-pathways/services (validator+materializer), onering/services, __mocks__ | — | — |
| S7 | — | — | pages/acquisition-pathways/{services,components,wizard,types} | — |
| S8 | — | .github/workflows, test/ | — | — |
| S9 | onering_api/{routers,services,tests}, docs/specs | — | — | — |
| S10 | — | onering/services (mock + pipeline), onering/clients | — | — |

No file is touched by two phases — except S10, which amends three S5/S6 files
(`onering-airflow-mock.service.ts`, `onering-pipeline.service.ts`, `onering-api.client.ts`);
safe because S6 is already merged to main. **Stacks:** S1→S2 (ONERING); S3→S4→S5→S6 then S8
(rohan_api); S7 starts after S3+S5 contracts freeze (rohan_ui, off main). **S9 and S10 branch
off main** in their repos (their dependencies are merged) and are independent of each other.

### Two-stream parallel model

- **Stream A (engine):** S1 → S2 in ONERING. ~1 engineer, ~3–5 days. **Follow-up: S9** (the
  gateway routes Open-Q1 expected to ride S2 — ~0.5–1 day; unblocks real-Airflow envs).
- **Stream B (rohan_api):** S3 → S4 → S5 → S6 → S8. ~1 engineer, ~5–8 days. S4 has a
  `Database/` repo handoff (budget 1–2 days). **Follow-up: S10** (mock restart recovery —
  ~0.5 day; independent of S9).
- **Stream C (UI):** S7 begins as soon as S3+S5 contracts are frozen. ~0.5 engineer.

Convergence: a working slice needs S2 (DAG) + S6 (materializer) green; the dev mock in S6
lets Stream C demo without Stream A's real DAG. **A working slice against *real*
Airflow/MinIO additionally needs S9** — without it, uploads 502 and materialization fails
(post-S6 review finding 1). Solo sequence: S3 → S1 → S2 → S4 → S5 → S6 → S7 → S8 → S9 → S10
(S9/S10 in either order or parallel).

## Phase context summaries

Compact, self-contained briefs for a coding agent picking up a single phase. Each says what
the phase produces, what it depends on, and the gotchas. Read the matching phase block +
contracts for detail.

- **S1 — `acquisition_requirements` pipeline + step factory (ONERING).** Produces the
  `pipelines.acquisition_requirements` package (4-phase extraction cloning
  `pipelines/requirements/`) and the `acquisition_requirements:build_steps` factory wiring
  ingestion-subset → extraction → UI projection, emitting a `CrrField[]`-shaped
  `ui_projection_acquisition_requirements.json` with `EvidenceSpan` provenance. Depends on
  nothing. Net-new domain content lives only in `models.py`/`prompts.py`; everything else
  reuses `pipelines/_common/` helpers and builtin ingestion StepDefs. Gotchas: the factory
  signature is `build_steps(*, cfg, artifact_store)` — the CLI loader always passes both
  kwargs (`cli.py:19380`; the zero-arg `build_strategy_only_steps()` is a shipped bug, not a
  precedent); document staging from `document_uris` is a new step (no conf-driven intake
  exists today); inject empty defaults where extraction expects upstream projections it no
  longer receives (mirror the compliance factory); never emit `tag='user'`. Ships a sample
  fixture consumed downstream by S6's dev mock and S8's cross-check. Implements C1, C2, C3.

- **S2 — `arc_acquisition_requirements` DAG + JSON schema (ONERING).** Ships the DAG
  (mirrors `arc_strategy_pipeline_dag.py`, invokes the S1 factory via
  `bash_for_steps_factory_step()`) and freezes the v1 artifact JSON Schema. Depends on S1 (the
  factory must exist). Passes `run_id` + `document_uris` + `mission_id` via `dag_run.conf`; the
  shipped helper templates **only** `run_id` (conf key `run_id`, **not** `expected_run_id`) —
  forwarding `document_uris`/`mission_id` to the CLI is new DAG-side templating. Gotcha:
  `schema_version` is the constant `"1"` (rohan_api rejects unknown
  versions) and the S1 fixture must validate against the schema. Reuses existing LLM pools.
  Stacks on phase-S1. Implements C4 and the JSON-Schema half of C3.

- **S3 — Enums, conf type, DTOs (rohan_api).** Lands all rohan_api type surface area with zero
  behavior change: `OneringDagId`/`RunType` values, `RunStatus.MATERIALIZING` (confirmed
  absent; lives in its own `run-status.enum.ts`),
  `AcquisitionRequirementsConf` added to the `DagRunConf` union, and the trigger DTO +
  response. Depends on nothing — this is the contract-freeze phase Streams A and C build
  against. Gotcha: grep the `onering` module for `RunType`/`RunStatus` `switch`/`if`-chains that
  assume the old member set — but note `refreshRunStatus()` only switches over `AirflowDagRunState`
  (with a `default`), so the new members won't break it. Branches off `base`. Implements C5, C6, C7.

- **S4 — `or_pipeline_runs.mission_id` + `materialized_at` (DB/rohan_api).** Schema-first
  change so S5 writes typed columns: nullable `mission_id` + `materialized_at` + a
  `(organization_id, mission_id, started_at DESC)` index, authored in the `Database/` repo and
  synced into `scripts/sql/` (never edited directly), plus TypeORM entity columns. Depends on
  S3 (needs the enum value for the `run_type` constraint). Gotcha: verify `run_type` accepts
  the new enum without a CHECK/enum DDL change; if constrained, update it in the same
  migration. Stacks on phase-S3. Implements C8.

- **S5 — Upload → MinIO + `triggerAcquisitionRequirements()` (rohan_api).** The trigger half:
  `ApUploadsService` stores multipart uploads to MinIO and updates `attached_files`; the
  `…/files` and `…/requirements:extract` endpoints reuse existing AP guards + ownership check;
  `triggerAcquisitionRequirements()` inserts the `or_pipeline_runs` row and fires the DAG.
  Depends on S4 (typed columns). Gotchas: resolve the Open-Q1 write path before coding
  (expected: new `onering_api` gateway upload route — rohan_api has no MinIO write client);
  extend `AcquisitionAttachedFile` with optional `uri`; mirror `launchProposal`'s error
  mapping + `reconcileTriggerFailure()` idempotency probe (no explicit 409 catch exists);
  guard empty uploads. Stacks on phase-S4. Implements C9, C10, C11.

- **S6 — Artifact validator + materializer + dev mock (rohan_api).** The materializer half: on
  terminal SUCCESS for an `ACQUISITION_REQUIREMENTS` run, `refreshRunStatus()` sets
  `MATERIALIZING`, validates the artifact (ajv, version-strict), maps `fields[] → CrrField[]`,
  PATCHes `run_state.canonicalRecord`, sets `materialized_at`, then flips SUCCESS. Also ships
  the in-process Airflow dev mock so UI engineers iterate without real Airflow. Depends on S5.
  Gotchas: Phase-A (read/validate/cross-check `run_id`+`mission_id`, no tx) vs Phase-B
  (map+PATCH, single short tx, no network IO); idempotency via `materialized_at`; copy the S1
  fixture into `__mocks__/`. Stacks on phase-S5. Implements C12, C13, C14.

- **S7 — Wire mission → upload → extract → poll → hydrate (rohan_ui).** Replaces the
  Requirements Record mock with server data end-to-end: real `createMission`/`uploadFiles`, a
  new `AcquisitionRunService` (trigger + poll `GET /onering/runs/:id` + getState), landing
  wiring, and wizard hydration of `requirementsRecord` from `run_state.canonicalRecord` with a
  drafting/polling state. Logically depends on S3+S5 contracts being frozen but branches off
  `main` — code against the contracts/PR diffs, not a running backend. Gotchas: the wizard
  route is `wizard/:step` today — add `wizard/:missionId/:step`; the drafting state is new UI
  for this step (mirror `package-assembly-step`'s pattern); `mode` passes through as
  `manual|auto` (**no** `manual→drive` mapping — that vocabulary was backwards); keep the seed
  importable behind `?demo=1`; debounce user-edit PATCHes; keep the existing step spec green.
  Implements C9/C10/C15 consumption and C16.

- **S8 — CI schema + fixture cross-check (rohan_api).** Guards against artifact-schema drift:
  a per-PR job validates the rohan_api ajv compiler against the ONERING sample fixture (pinned
  ref) and asserts byte-equal sync with the `__mocks__/` fixture, plus an E2E using the
  in-process mock driving create → upload → extract → poll → asserting `canonicalRecord`
  materialized as `CrrField[]` and idempotent re-materialize. Depends on S6. Mirrors compliance
  Phase 12.2. Stacks on phase-S6. Implements C17.

- **S9 — `onering_api` acquisition gateway routes (ONERING).** Lands the two `/v1/acquisition`
  routes that merged rohan_api code already calls: `POST /v1/acquisition/uploads` (multipart
  `object_key` + `file`, streamed to MinIO, returns `{ key, size, content_type, etag }`) and
  `GET /v1/acquisition/runs/{run_id}/requirements-projection` (raw artifact JSON or 404).
  Depends on S2 (merged) — branches off ONERING main. Gotchas: the request/response shapes are
  **already frozen** by the shipped rohan_api clients (C18/C19) — deviating means changing
  `uploadAcquisitionDocument` / `getAcquisitionRequirementsProjection` in the same coordinated
  change; validate `object_key` shape + org-prefix-vs-tenant-header match (the key is
  caller-computed); resolve the run prefix via `runs_prefix_for(store)`, never hard-code
  `AGENT_RUNS/`; stream uploads (mirror `routers/user_uploads.py`), don't buffer; update
  `docs/specs/minio_path_contract.md`. Implements C18, C19.

- **S10 — Dev-mock restart recovery + read size cap (rohan_api).** Fixes post-S6 finding 4: a
  restart while a mocked extraction is in flight empties the mock's per-process registry, the
  refresh catch swallows the resulting 404, and the run sits QUEUED/RUNNING forever while the
  C10 guard 409-blocks re-triggers. Fix in the **refresh path**: mock-owned DAG + unknown-run
  404 → flip the run FAILED with the literal C20 message. Gotcha: keep the mock's
  `getDagRunStatus` throwing on unknown runs — `reconcileTriggerFailure()`'s probe depends on
  throw semantics; detect the case via a typed flag/helper, not message string-matching. Also
  caps `getAcquisitionRequirementsProjection` at 25 MB per-request (finding 5) without touching
  the shared client's `maxContentLength: Infinity`. Branches off rohan_api main (S6 merged).
  Independent of S9. Implements C20.

## Jira ticket

**Title:** Acquisition Pathways — Requirements Record vertical slice (ONERING/Airflow
extraction → `run_state.canonicalRecord` → wizard hydration)

**Description:** Wire the AP wizard's **Requirements Record** step end-to-end through the
shipped Airflow `/onering/*` integration. Add a buyer-side `acquisition_requirements`
extraction pipeline + DAG in ONERING; extend rohan_api to upload mission documents to MinIO,
trigger the DAG (tracked in `or_pipeline_runs` via a new `mission_id` link), validate the
emitted artifact and materialize it into `acquisition_missions.run_state.canonicalRecord` as
`CrrField[]`; and replace the rohan_ui mock seed with real server-hydrated data plus a
polling/drafting state. An in-process Airflow dev mock lets the FE iterate without the real
DAG, and a CI cross-check guards the shared artifact schema. Ships behind the existing
`AcquisitionPathways` feature flag (dev/staging only). Companion epic:
`acquisition-pathways-onering-integration-PLAN.md`.

**Acceptance criteria** (one per phase):

- [ ] **S1** ONERING `pipelines.acquisition_requirements` + `acquisition_requirements:build_steps`
  factory run ingestion-subset → extraction → UI projection and emit a `CrrField[]`-shaped
  `ui_projection_acquisition_requirements.json` with evidence spans; factory unit test + sample
  fixture land.
- [ ] **S2** `arc_acquisition_requirements` DAG runs the factory via `--steps-factory`; the v1
  `ui_projection_acquisition_requirements.schema.json` is frozen and the S1 fixture validates
  against it.
- [ ] **S3** `OneringDagId`/`RunType` values, `RunStatus.MATERIALIZING`, `AcquisitionRequirementsConf`
  (in the `DagRunConf` union), and the trigger DTO + response compile and lint with no behavior
  change.
- [ ] **S4** `or_pipeline_runs.mission_id` + `materialized_at` + index exist (migration in
  `Database/`, synced to `scripts/sql/`), TypeORM entity columns added, `db:test:up` green.
- [ ] **S5** `POST …/missions/:id/files` stores uploads to MinIO and updates `attached_files`;
  `POST …/missions/:id/requirements:extract` inserts the run row, triggers the DAG, and stores
  the `run_state.requirementsRun` pointer; guards + trigger-failure reconcile idempotency +
  ownership covered by tests.
- [ ] **S6** On terminal SUCCESS the materializer validates the artifact (version-strict),
  cross-checks `run_id`+`mission_id`, maps to `CrrField[]`, PATCHes `run_state.canonicalRecord`,
  and the in-process Airflow mock drives the full path; validator + materializer + mock tests
  pass.
- [ ] **S7** The wizard hydrates `requirementsRecord` from `run_state.canonicalRecord` (real
  data, mock removed except `?demo=1`), with mission create → upload → extract → poll wired and
  user edits persisted via debounced PATCH; run-service + hydration specs pass.
- [ ] **S8** A per-PR CI job validates the rohan_api ajv compiler against the pinned ONERING
  fixture, asserts byte-equal mock sync, and an E2E drives the slice end-to-end via the mock.
- [ ] **S9** `POST /v1/acquisition/uploads` and `GET /v1/acquisition/runs/{run_id}/requirements-projection`
  exist on the `onering_api` gateway matching C18/C19 (the shapes the merged rohan_api clients
  call), with `object_key` validation + tenant-prefix check and route tests; the slice works
  against real Airflow/MinIO.
- [ ] **S10** A process restart during a mocked extraction no longer leaves the run stuck
  (refresh flips it FAILED with the C20 message, re-trigger unblocked); `reconcileTriggerFailure`
  probe semantics unchanged; the projection read is capped at 25 MB.

## Tech stack reference

| Layer | Stack |
|-------|-------|
| Engine (ONERING) | Python 3.x, Airflow 3.x (KubernetesExecutor), Pydantic v2, Helm |
| Backend (rohan_api) | NestJS, TypeScript, TypeORM, Jest, ajv |
| Frontend (rohan_ui) | Angular 20+ (signals, zoneless, non-standalone module), Karma/Jasmine |
| Storage | MinIO (`AGENT_RUNS/{arc_run_id}/…` for ONERING artifacts; `acquisition/{org}/{mission}/uploads/` for inputs) |
| Run tracking | `or_pipeline_runs` (reused; new `mission_id`), `acquisition_missions.run_state` (materialization target) |
| Auth | JWT; Airflow basic-auth token via `OneringAirflowClientService` |

---

## Contracts

Contracts are kept inline here (the slice is meant to be self-contained); the broader epic
gets its own `…-contracts.md`. Cross-repo phases coordinate via these contracts, not via git
stacking — Stream B freezes them first and Streams A/C build against the schema + PR diffs.

### Contract → Phase mapping

| Contract Section | Phase(s) | Notes |
|------------------|----------|-------|
| C1 `acquisition_requirements:build_steps` step factory | S1 | ONERING factory |
| C2 `pipelines.acquisition_requirements` output models | S1 | Pydantic models + `EvidenceSpan` |
| C3 `ui_projection_acquisition_requirements.json` v1 | S1, S2 | S1 writes the artifact; S2 freezes the JSON Schema |
| C4 `arc_acquisition_requirements` DAG `dag_run.conf` envelope | S2 | DAG conf contract |
| C5 Enum extensions (`OneringDagId`/`RunType`/`RunStatus`) | S3 | `MATERIALIZING` added in `run-status.enum.ts` (confirmed absent today) |
| C6 `AcquisitionRequirementsConf` | S3 | Extends `DagRunConf` union |
| C7 Trigger DTO + `RequirementsRunResponse` | S3 | `class-validator` + swagger |
| C8 `or_pipeline_runs` additions (`mission_id`, `materialized_at`) | S4 | DB + entity + index |
| C9 `POST …/missions/:id/files` | S5, S7 | S5 implements; S7 consumes |
| C10 `POST …/missions/:id/requirements:extract` | S5, S7 | S5 implements; S7 consumes |
| C11 `OneringPipelineService.triggerAcquisitionRequirements()` | S5 | Trigger + run row |
| C12 Artifact validator (ajv, version-strict) | S6 | Reads via `OneringArtifactService`; **as-built:** `loadAndValidate(run)` takes the run row |
| C13 Materializer behavior + field→`CrrField` mapping | S6 | Phase-A/Phase-B discipline; **as-built:** pill label is `doc_name \|\| doc_id` |
| C14 In-process Airflow mock | S6 | Dev/staging only; **as-built:** in-memory at the read seam, also gated off when Key Vault is set |
| C15 FE upload/extract consumption | S7 | rohan_ui services |
| C16 `run_state` hydration contract (FE) | S7 | signal hydration + poll |
| C17 Schema cross-check CI | S8 | mock-vs-engine fixture sync |
| C18 `POST /v1/acquisition/uploads` (gateway) | S9 | Shape frozen by the shipped S5 client |
| C19 `GET /v1/acquisition/runs/{run_id}/requirements-projection` (gateway) | S9 | Shape frozen by the shipped S6 client |
| C20 Mock unknown-run recovery | S10 | Refresh-path fix; mock keeps throw semantics |

### C1 — `acquisition_requirements:build_steps` step factory (ONERING)

```python
# arc_agent_writer/factories/acquisition_requirements.py
from arc_agent_writer.orchestrator import StepDef

def build_steps(*, cfg, artifact_store) -> list[StepDef]:
    """Thin buyer-side requirements-extraction graph.
    stage documents → ingestion subset → acquisition_requirements → ui_projection."""
    # step "stage_documents" (fetch dag_run document_uris into the run workspace — NEW)
    # ingestion.docling_parse_base, page_classifier, (ocr…), canonical_markdown,
    # line_numbering, line_map, chunk_plan  (reuse builtin ingestion StepDefs)
    # → step "pipelines.acquisition_requirements"
    # → step "pipelines.ui_projection_acquisition_requirements"
    ...
```
Returns `list[StepDef]`; the CLI loads it via `--steps-factory
arc_agent_writer.factories.acquisition_requirements:build_steps`. **Factory signature is
keyword** `build_steps(*, cfg, artifact_store) -> list[StepDef]` — the CLI loader *always*
invokes factories as `fn(cfg=cfg, artifact_store=store)` (`cli.py:19380`; `_resolve_callable`
does no signature adaptation). **Do not mirror `cli.py:build_strategy_only_steps()`** — it is
zero-argument and would raise `TypeError` through this exact path; that is a shipped bug
(flagged separately), not a contract. (An earlier revision of this doc "corrected" the
signature to zero-argument based on that factory; the correction was backwards.)

### C2 — `pipelines.acquisition_requirements` output models (ONERING)

```python
class AcquisitionRequirementItem(RecordModel):
    field_key: str                 # e.g. "mission_objective", "naics_psc"
    label: str                     # human label rendered in the UI
    text: str                      # extracted/inferred value
    tag: Literal["extracted", "inferred", "needs"]
    rationale: str | None = None
    evidence: list[EvidenceSpan]   # from pipelines/_common/models.py
```
`AcquisitionRequirementsUIProjection.fields: list[AcquisitionRequirementItem]`.

### C3 — `ui_projection_acquisition_requirements.json` v1 (ONERING → rohan_api)

```jsonc
{
  "schema_version": "1",
  "run_id": "arc_...",
  "mission_id": 123,
  "fields": [
    {
      "field_key": "mission_objective",
      "label": "Mission / objective",
      "text": "Modernize FAA terminal radar across 12 sites …",
      "tag": "extracted",                       // extracted | inferred | needs
      "icon": "flag",                            // optional material symbol hint
      "evidence": [
        { "doc_id": "doc_A", "start_line": 45, "end_line": 52,
          "page_number": 3, "snippet": "…", "doc_name": "AcquisitionPlan.pdf" }
      ]
    }
  ]
}
```
Path: `pipelines/acquisition_requirements_extraction/ui/ui_projection_acquisition_requirements.json`
under the run root — mirrors the shipped `REQUIREMENTS_UI_RELPATH` convention. The writer's
local prefix is `AGENT_RUNS/{run_id}/`, but read-side consumers must derive the runs prefix via
`onering_shared.storage.paths.runs_prefix_for(store)` — never hard-code it. Update
`docs/specs/minio_path_contract.md` in the same PR (repo rule for bucket-layout changes).
Versioning rule: any rohan_api-breaking change bumps `schema_version`.

### C4 — `arc_acquisition_requirements` DAG `dag_run.conf` envelope

```jsonc
{
  "org_id": "org_123",
  "user_id": "auth0|abc",
  "mission_id": 123,
  "run_id": "arc_...",                   // rohan_api generates; the shipped
                                         // bash_for_steps_factory_step() reads
                                         // dag_run.conf['run_id'] → passes --run-id
  "document_uris": ["acquisition/org_123/123/uploads/AcquisitionPlan.pdf", "…"],
  "llm_mode": "gpt5_5",                  // optional
  "verbose": false                        // optional
}
```

### C5 — Enum extensions (rohan_api)

```ts
// src/onering/types/airflow.types.ts
enum OneringDagId { /* …existing… */ ACQUISITION_REQUIREMENTS = 'arc_acquisition_requirements' }
// src/onering/enums/run-type.enum.ts
enum RunType { /* …existing… */ ACQUISITION_REQUIREMENTS = 'ACQUISITION_REQUIREMENTS' }
// src/onering/enums/run-status.enum.ts  (separate file; current members QUEUED/RUNNING/SUCCESS/FAILED)
enum RunStatus { /* …existing… */ MATERIALIZING = 'MATERIALIZING' }  // confirmed absent today
```

### C6 — `AcquisitionRequirementsConf` (rohan_api)

```ts
interface AcquisitionRequirementsConf {
  org_id: string; user_id: string; mission_id: number;
  run_id: string;                 // conf key MUST be `run_id` — that's what the shipped
                                  // bash_for_steps_factory_step() reads (not `expected_run_id`)
  document_uris: string[];
  llm_mode?: string; verbose?: boolean;
}
// extend DagRunConf union with AcquisitionRequirementsConf
```

### C7 — Trigger DTO + response (rohan_api)

```ts
class TriggerRequirementsExtractDto {}                       // body empty; uploads resolved server-side
interface RequirementsRunResponse { arc_run_id: string; dag_run_id: string; status: RunStatus; }  // snake_case per module wire convention (PR #2030 review)
```

### C8 — `or_pipeline_runs` additions

```sql
ALTER TABLE or_pipeline_runs ADD COLUMN IF NOT EXISTS mission_id INTEGER NULL;
ALTER TABLE or_pipeline_runs ADD COLUMN IF NOT EXISTS materialized_at TIMESTAMPTZ NULL;
CREATE INDEX IF NOT EXISTS idx_or_runs_org_mission_started
  ON or_pipeline_runs (organization_id, mission_id, started_at DESC);
```

### C9 — `POST /acquisition-pathways/missions/:id/files`

Multipart upload. Guards (same as existing AP routes, `ap-missions.controller.ts:59-61`):
`@UseGuards(AuthGuard('jwt'), FeatureGuard, PermissionsGuard)` + `@Features('AcquisitionPathways')`
+ `@Permissions('acquisition-pathways')`, plus mission-ownership check. Stores to
`acquisition/{org_id}/{mission_id}/uploads/{filename}` via the Open-Q1 write path; updates
`attached_files` (extend `AcquisitionAttachedFile` with optional `uri` — today it is
`{ name, size?, mime? }`). Returns `{ files: [{ name, size, mime, uri }] }`.

### C10 — `POST /acquisition-pathways/missions/:id/requirements:extract`

Same guards + ownership. 409 if a non-terminal requirements run already exists for the
mission. Resolves uploaded `document_uris` from the mission, calls C11, PATCHes
`run_state.requirementsRun = { arcRunId, status }`. Returns `RequirementsRunResponse`.

### C11 — `OneringPipelineService.triggerAcquisitionRequirements()`

```ts
triggerAcquisitionRequirements(
  user: RequestUser, missionId: number, documentUris: string[],
  options?: { llmMode?: string; verbose?: boolean },
): Promise<RequirementsRunResponse>
```
Resolves org, generates `arc_run_id`, `INSERT or_pipeline_runs(run_type=ACQUISITION_REQUIREMENTS,
mission_id, status=QUEUED, …)`, `OneringAirflowClientService.triggerDagRun('arc_acquisition_requirements',
dagRunId, conf)`. Idempotency mirrors `launchProposal`'s `reconcileTriggerFailure()`: on any
trigger failure, probe Airflow for the DAG run before failing the row (shipped code has no
explicit 409 catch — reconcile by state, not status code). Error mapping mirrors
`launchProposal`.

### C12 — Artifact validator

ajv@^8, compiled once at module init from the C3 schema. `loadAndValidate(arcRunId)` reads via
`OneringArtifactService`. `additionalProperties: true`; strict on `schema_version` (reject
unknown). Throws `AcquisitionSchemaError` (map to 502).

**As built (rohan_api #2035):** `loadAndValidate(run: OrPipelineRun)` takes the run **row**
rather than a bare `arcRunId` — callers already hold the row and the artifact read needs
`organization_id` for tenant headers. A pure `validate(raw, contextId)` half is exposed for
tests and the S8 cross-check. Provided by `OneringModule` (not the AP module) to avoid a
circular module import.

### C13 — Materializer behavior + field→CrrField mapping

Phase A (no tx): read + validate; cross-check `json.run_id === run.arc_run_id` **and**
`json.mission_id === run.mission_id` (reject `JSON_RUN_ROW_MISMATCH`). Phase B (single short
tx): map and PATCH. **Note:** `CrrField`/`SourcePill` are not defined in rohan_api today
(`run_state` is opaque `Record<string, unknown>`; the types live in rohan_ui). S6.2 adds the
shape under `acquisition-pathways/types/`. The mapping below is shape-valid against the rohan_ui
`SourcePill` (`{ kind: SourceKind; label: string; href?; docId? }`, where `'upload'` is a real
`SourceKind`).

```ts
// field → CrrField
{
  label: f.label,
  icon: f.icon,
  tag: f.tag,                                  // 'extracted' | 'inferred' | 'needs'
  text: f.text,
  sources: f.evidence.map(e => ({
    kind: 'upload', label: e.doc_name ?? e.doc_id, docId: e.doc_id,
  })),
}
```
PATCH `run_state` shallow-merges `{ canonicalRecord: CrrField[], requirementsRun: { arcRunId,
status: 'SUCCEEDED' } }`; set `materialized_at`; flip run `SUCCESS`. Idempotent via
`materialized_at`.

**As built (rohan_api #2035):** the pill label is `e.doc_name || e.doc_id` (not `??`) — C3
allows empty-string `doc_name`, and `||` keeps the label non-blank when a `doc_id` exists.
Phase B takes a `pessimistic_write` row lock on the mission (same discipline as
`ApMissionsService.runStateTransaction`) and resolves the Auth0 org string **before** the
transaction.

### C14 — In-process Airflow mock

When `ONERING_AIRFLOW_BASE_URL` empty + `NODE_ENV !== 'production'` + `ONERING_AIRFLOW_MOCK
!== 'disabled'`: `triggerDagRun` writes the fixture artifact via the MinIO path and schedules
a ~100 ms status flip to SUCCESS. Polling path downstream is identical to prod.

**As built (rohan_api #2035):** two deviations. (1) The mock does **not** physically write to
MinIO — rohan_api has no MinIO write client by gateway design — so the stamped fixture is
served **in-memory at the artifact-read seam**
(`OneringArtifactService.readAcquisitionRequirementsProjection` consults the mock registry
before the gateway); everything downstream of the read is unchanged. (2) The gate additionally
requires **no `KEY_VAULT_NAME`** (deployed envs resolve the Airflow URL from Key Vault, so a
set Key Vault means "real Airflow lives here"). The registries are per-process — the
restart-stuck-run consequence is fixed by **C20/S10**.

### C15 — FE upload/extract consumption

`AcquisitionPathwaysService.createMission(payload)` → `POST /acquisition-pathways/missions`.
`uploadFiles(missionId, files)` → multipart `POST …/missions/:id/files`.
`AcquisitionRunService.triggerRequirements(missionId)` → `POST …/missions/:id/requirements:extract`.

### C16 — `run_state` hydration contract (FE)

On wizard load with `:missionId` (via the **new** `wizard/:missionId/:step` route — today the
wizard route is `wizard/:step` only): `GET …/missions/:id/state`. If `run_state.canonicalRecord`
present → `requirementsRecord.set(canonicalRecord)`. Else if `run_state.requirementsRun.status`
is non-terminal → show the (new) drafting state + poll `GET /onering/runs/:arcRunId`; on SUCCESS
refetch state. User edits debounce-PATCH `run_state.canonicalRecord`.

### C17 — Schema cross-check CI

Per-PR: validate rohan_api ajv compiler against the ONERING sample fixture (pinned ref) and
assert byte-equal sync with `src/onering/__mocks__/ui_projection_acquisition_requirements.fixture.json`.

### C18 — `POST /v1/acquisition/uploads` (onering_api gateway, S9)

> **Shape frozen by the shipped rohan_api S5 client** (`uploadAcquisitionDocument`,
> `onering-api.client.ts:331-362`, merged in #2034/#2035). If the gateway must deviate, change
> that client method + `ApUploadsService`'s mapping in the same coordinated change.

Auth: `Depends(get_principal)` like every gateway router. Tenant context via the standard
headers `X-Onering-Org-Id` / `X-Onering-User-Id` (rohan_api sends both on this path).

Request: `multipart/form-data` with

| Part | Type | Description |
|------|------|-------------|
| `object_key` | form field (string) | Caller-computed `acquisition/{org_id}/{mission_id}/uploads/{filename}` MinIO key |
| `file` | file part | The document bytes (streamed; rohan_api raises its timeout to 120 s for large docs) |

Validation: `object_key` must match the prefix shape above (reject traversal / absolute keys →
**400**); the `{org_id}` segment must equal `X-Onering-Org-Id` → **403** on mismatch.

Response (**200** = overwrite, **201** = created — rohan_api accepts both; any other status is
raised as a typed error, including 204):

```jsonc
{ "key": "acquisition/org_123/123/uploads/AcquisitionPlan.pdf",
  "size": 1048576, "content_type": "application/pdf", "etag": "\"abc…\"" /* or null */ }
```

(rohan_api parses this as `UploadResponseDto { key, size, content_type, etag }`.)

### C19 — `GET /v1/acquisition/runs/{run_id}/requirements-projection` (onering_api gateway, S9)

> **Shape frozen by the shipped rohan_api S6 client** (`getAcquisitionRequirementsProjection`,
> merged in #2035). 404 is load-bearing: rohan_api maps it to `null`, and the materializer
> treats "SUCCESS but no artifact" as an engine-contract violation (502 semantics).

Auth: `Depends(get_principal)` + tenant headers as above (rohan_api sends `org_id` only on
this poll-driven path; `user_id` is null).

Behavior: resolve the run prefix via `onering_shared.storage.paths.runs_prefix_for(store)`
(never hard-code `AGENT_RUNS/`), read
`{runs_prefix}/{run_id}/pipelines/acquisition_requirements_extraction/ui/ui_projection_acquisition_requirements.json`,
return it verbatim as the JSON body.

| Status | Condition | Body |
|--------|-----------|------|
| 200 | Artifact exists | The raw C3 artifact JSON (gateway does not validate it — rohan_api's ajv validator owns that) |
| 404 | Artifact not written yet / run unknown | error body (rohan_api ignores it, returns `null`) |

### C20 — Mock unknown-run recovery (rohan_api, S10)

The dev mock's registries are per-process. Recovery for a restart-orphaned run lives in
`OneringPipelineService.refreshRunStatus()`'s catch path, **not** in the mock's return values:

- The mock's `getDagRunStatus` **keeps throwing** on unknown `dag_run_id`s
  (`reconcileTriggerFailure()`'s probe semantics — "status check throws ⇒ the DAG run never
  reached Airflow ⇒ fail the row" — depend on it), but exposes the case distinguishably (typed
  error flag or an `isUnknownRun(dagRunId)` helper; no message string-matching).
- `refreshRunStatus()` catch: when `airflowMock.shouldHandle(run.airflow_dag_id)` and the
  error is the mock's unknown-run case, set `status = FAILED` and the **literal**
  `error_message = 'Dev Airflow mock lost run state (process restart) — re-trigger the extraction'`,
  then save. This unblocks the C10 in-flight 409 guard so the user can re-trigger.
- All other refresh errors keep today's behavior (warn + leave status unchanged) — transient
  real-Airflow failures must not fail runs.
