# Acquisition Pathways — ONERING integration architecture (epic, reference)

> **Scope of this document.** This is the *reference architecture* for powering the
> Acquisition Pathways (AP) backend with ONERING, across all five wizard steps. It is
> deliberately broad — a map and a work-split, not a line-by-line build plan. The
> **first vertical slice is fully specified in `acquisition-pathways-step1-requirements-slice.md`**
> and should be built first; every later step repeats that slice's shape. Read the slice
> doc for concrete contracts and code; read this for the whole-feature picture, the
> reuse-vs-build breakdown, and how to parallelize the work across people.

**Bridge decision (locked):** all ONERING-heavy work runs on the **shipped Airflow
`/onering/*` integration path** in rohan_api. A future refactor will move *fast,
low-latency* ops (notably pathway scoring) onto a thin synchronous `rohan-python-api`
lane — tracked under **Future work**, not built in this epic.

---

## Problem statement

The AP feature is a **government-buyer** workflow: take a mission/need → build a
requirements record → choose a contracting **pathway/vehicle** → assemble an acquisition
**package** (Acquisition Plan, Market Research Report, SOW/PWS/SOO, RFI/RFP, etc.) → run
an **integrity check** (FAR/policy/consistency/protest) → **finalize** for release. The
frontend wizard is ~80–85% built but runs on mock seed data; rohan_api persists an opaque
per-mission `run_state` blob but computes nothing; rohan-python-api has no AP code.

ONERING is a **contractor** workflow engine (ingest an RFP → write a winning proposal).
The two are **mirror images of the same machinery**. The governing reuse rule, confirmed
by inspecting ONERING:

> **Infrastructure and patterns transfer. Domain content (prompts, schemas, document
> templates, reference data, rules) is net-new.**

ONERING generates **zero** government-side documents and has **no** contract-vehicle
reference data — those are genuinely new. But its orchestrator, ingestion, render engine,
LLM controller, evidence/provenance model, scoring pattern, and compliance-finding engine
are all directly reusable, and its product integration (Airflow `/onering/*`) is shipped.

## Key architectural observations

### The bridge: Airflow `/onering/*` is shipped; Service Bus is the wrong lane for ONERING

Verified in code (not just planned):

- `rohan_api/src/onering/` exists and is live: `OneringPipelineService`
  (`launchProposal`/`stageOpportunity`/`triggerDiscovery`/`listRuns`/`getRun`/
  `refreshRunStatus`), `OneringAirflowClientService` (Airflow REST v2 + token auth),
  `OneringArtifactService` (MinIO artifact reads), `or_pipeline_runs` table,
  `OneringDagId`/`RunType`/`RunStatus` enums, `OneringRunsController` +
  `OneringOpportunitiesController`.
- `ONERING/airflow/dags/` ships `arc_launch_proposal_dag.py`, `arc_stage_opportunity_dag.py`,
  `arc_strategy_pipeline_dag.py`; `helm/onering-airflow/` ships dev/staging/prod values.
- The **`--steps-factory module:fn`** pattern (custom step graph per feature) is already
  used by a shipping DAG via `bash_for_steps_factory_step()`.
- The **FastAPI backend (`rohan-python-api`) has zero `arc_agent_writer` imports.** A
  Service-Bus→FastAPI lane for ONERING would be greenfield and divergent.

Three topologies, compared:

| | **A. Airflow `/onering/*`** (chosen) | **B. Service Bus → FastAPI → ONERING** | **C. Hybrid** |
|---|---|---|---|
| Reuses shipped code | ✅ entire stack + DAG runner | ❌ none (FastAPI has no ONERING) | ✅ heavy on A, fast on B |
| Fit for ONERING's resumable DAG | ✅ native (K8s executor, pods, LLM pools, checkpointing) | ⚠️ heavy DAG inside a worker | ✅ |
| Precedent to copy | ✅ proposal launch (live) + compliance plan (written) | ⚠️ only lightweight auto-tag | ✅ both |
| Right for *fast* ops (scoring, chat) | ⚠️ DAG overhead for a 2-call score | ✅ low latency | ✅ |

**Decision:** anchor on **A** now; adopt the **C** hybrid's fast lane later (Future work).

### ONERING reuse-vs-build, per AP wizard step

| Wizard step | ONERING reuse | Net-new build | Lift |
|---|---|---|---|
| **Requirements Record** | ingestion (Docling→markdown→chunk), 4-phase extraction pattern, `EvidenceSpan` provenance | buyer-side extraction models + prompts; `CrrField[]` UI projection | **Low–Med** (this is the slice) |
| **Pathway Selection** | two-layer scoring pattern (`opportunities/scoring.py` deterministic + `opp_matcher.py` LLM), `ScoreComponent`/`OpportunityScore`, `disqualifier_reasons` | **contract-vehicle reference data** (GSA MAS, CIO-SP4, GWAC, IDIQ, BPA, open-market — ceilings, scope, set-asides, protest history), scoring rules, prompts → `AcquisitionPathway[]` | **High** (most novel domain data; *also* the best fast-lane candidate later) |
| **Package Assembly** | section-writer orchestration (draft→critique→revise→summarize), `consistency_ledger`, `source_packet_builder`, render engine (DOCX/PPTX/XLSX), `volume_assembler`, `template_fill_arbiter` | **government document templates** (Acq Plan, MRR, SOW/PWS/SOO, RFI/RFP…), buyer-side writer prompts, acquisition context builder → `Artifact[]`/`AssemblyCard[]` | **High** (biggest content lift) |
| **Integrity Check** | `review/compliance_check.py` MAPPER engine: three-pass, finding kinds/severities, corrective actions | FAR/DFARS/policy/protest rule set + cross-document consistency rules → `FindingGroup[]` | **Med–High** (engine reuses; rules new) |
| **Finalize Package** | `volume_assembler` + renderers + MinIO | bundling/download endpoints | **Low** |
| **Chat** (cross-cutting) | **already shipped** via Answer Engine V2 (`ap-chat.controller.ts`) — separate RAG stack, not ONERING | — | **Done** |

### The materialization model (uniform across steps)

Every step follows the slice pattern: rohan_api triggers an ONERING DAG (tracked in
`or_pipeline_runs` with a new `mission_id` link) → ONERING writes a `ui_projection_*.json`
artifact to MinIO → on terminal SUCCESS, a per-step **materializer** validates the artifact
and PATCHes a top-level key into `acquisition_missions.run_state`:

| Step | DAG / step factory | `run_state` key materialized | FE type |
|---|---|---|---|
| Requirements Record | `arc_acquisition_requirements` / `acquisition_requirements:build_steps` | `canonicalRecord` | `CrrField[]` |
| Pathway Selection | `arc_acquisition_pathways` / `acquisition_pathways:build_steps` | `pathways`, `selectedPathway` | `AcquisitionPathway[]` |
| Package Assembly | `arc_acquisition_package` / `acquisition_package:build_steps` | `artifacts` | `Artifact[]`/`AssemblyCard[]` |
| Integrity Check | `arc_acquisition_integrity` / `acquisition_integrity:build_steps` | `findings` | `FindingGroup[]` |

`run_state` becomes **co-owned**: the server writes AI-produced keys; the client writes
user-edited keys (`requirementsRecordNotes`, `selectedPathway` selection, dismissals). The
shallow top-level `mergeState` (`ap-missions.service.ts:325`) keeps them non-conflicting.

## Assumptions

1. `acquisition_missions` remains the AP source of truth; `or_pipeline_runs` is reused only
   for run tracking, linked by a new nullable `mission_id`.
2. Uploaded mission documents land in MinIO under a mission-keyed prefix the DAGs ingest via
   `dag_run.conf.document_uris` (ONERING `MANUAL_UPLOAD` ingestion).
3. Each step is independently triggerable and resumable; a mission can re-run any step.
4. The `AcquisitionPathways` feature flag + `acquisition-pathways` permission already gate
   the module; new endpoints reuse them.
5. Pathway Selection and Integrity Check **rules/reference-data** are owned by a contracting
   SME, not invented by engineering. Engineering ships the schemas, scoring/eval scaffolds,
   and the data ingestion path; the SME supplies the content.
6. Prod-readiness for new AP DAGs (first AP prod workloads) is a parallel workstream from
   kickoff, mirroring the compliance epic's Stream D — not a late surprise.

## Open questions

| # | Question | Default |
|---|----------|---------|
| 1 | Single `RunType.ACQUISITION` with a sub-step discriminator, or one per step (`ACQUISITION_REQUIREMENTS`, `…_PATHWAYS`, …)? | **One per step** — clearer status filtering + per-step `OneringDagId`. Matches compliance's one-DAG-per-concern shape. |
| 2 | Where does contract-vehicle reference data live — ONERING `taxonomy/`, a new ONERING module, or a Postgres table in rohan_api? | **New ONERING reference module** (`acquisition/vehicles/`) loaded by the scoring step, versioned with the engine. Revisit if the data needs frequent non-engineer edits → then a DB table + admin UI. |
| 3 | Is pathway scoring heavy enough to need a DAG, or should it be the first fast-lane (hybrid B) op now? | **DAG now** for architectural uniformity and to avoid a second integration before the slice proves out; **fast-lane refactor** is the named follow-up (Future work). |
| 4 | Do Package Assembly documents need per-tenant templates from day one? | **No** — ship a default template set; tenant overrides reuse ONERING's `template_registry`. |
| 5 | Should Integrity Check run automatically after Package Assembly, or only on demand? | **On demand** (explicit wizard step) for v1; auto-trigger is a later UX enhancement. |
| 6 | Does the existing AP chat (Answer Engine V2) need to read ONERING artifacts (e.g. cite the requirements record)? | Out of scope for this epic; revisit once `run_state` is server-populated. |

## Non-goals / Future work

- **Hybrid fast lane (Topology C).** After the slice proves the Airflow path, add a thin
  synchronous `rohan-python-api` endpoint (JWT via the existing RFP-Python-Server client
  pattern) for low-latency ops — pathway re-scoring, quick field re-extraction. Migrate
  Pathway Selection's scoring off Airflow onto it. **Filed as a follow-up refactor**, with a
  note in each affected phase. Not built here.
- **Azure Government (`.us`)** feasibility for AP DAGs (mirror the compliance epic's Gov
  spike) — separate ticket; flag AP off for Gov orgs at launch.
- Audit-trail UI, document viewer for source pills, advanced export/packaging.
- Retiring any existing path (there is none to retire — AP is greenfield on the backend).

---

## Workstreams (epic structure)

The epic decomposes into a **shared foundation** plus **four per-step workstreams** plus a
**domain-content workstream**. Phases are named `F*` (foundation) and `R*`/`P*`/`K*`/`Z*`
(Requirements / Pathways / pacKage / integrity-Z) so they don't collide with the slice's
`S*`. The slice (`S1–S8`) **is** the Requirements workstream's first delivery — i.e. `R*`
≡ the slice; it is reproduced here only as a row, not re-specified.

### Foundation (build once, reused by every step)

```phase-meta
phase: F
title: Foundation - shared AP↔ONERING run plumbing
tags: [PYTHON, BACKEND_DB, FRONTEND]
repo: multi
base_branch: base
depends_on: []
```

- **F1 [rohan_api/DB]** `or_pipeline_runs.mission_id` + `materialized_at` + index; entity
  columns. *(= slice S4.)*
- **F2 [rohan_api]** Per-step enum scaffolding convention (`OneringDagId.ACQUISITION_*`,
  `RunType.ACQUISITION_*`, `RunStatus.MATERIALIZING`) + `DagRunConf` union extension. *(slice S3 establishes the pattern.)*
- **F3 [rohan_api]** Upload→MinIO endpoint + `ApUploadsService`. *(= slice S5 upload half.)*
- **F4 [rohan_api]** Generic materializer harness: validator base (ajv, version-strict),
  Phase-A/Phase-B transaction discipline, `refreshRunStatus()` `MATERIALIZING` hook,
  in-process Airflow dev mock. *(slice S6 is the first concrete instance; refactor shared
  bits out as the second step lands.)*
- **F5 [rohan_ui]** `AcquisitionRunService` (trigger + poll `/onering/runs/:id` + getState)
  and the wizard hydration pattern (`run_state.<key>` → signal). *(= slice S7 run/hydration
  half; reused verbatim by every step.)*
- **F6 [ONERING]** `factories/` package + a shared ingestion-subset helper the per-step
  factories compose. *(slice S1 creates `factories/`; later factories reuse it.)*

### Per-step delivery (each = one slice-shaped mini-epic)

| Workstream | ONERING (engine) | rohan_api | rohan_ui | Net-new domain content |
|---|---|---|---|---|
| **R — Requirements Record** *(the slice S1–S8)* | `acquisition_requirements` pipeline + DAG | trigger + materializer (`canonicalRecord`) | hydrate `requirementsRecord` | buyer-side extraction prompts/models |
| **P — Pathway Selection** | `acquisition_pathways` scoring steps (clone `opportunities/scoring.py` + `opp_matcher.py`) + DAG | trigger + materializer (`pathways`/`selectedPathway`) | swap `PathwaySelectionService.generate()` (`:51`) to trigger+poll | **vehicle reference data** + scoring rules + prompts |
| **K — Package Assembly** | `acquisition_package` writer steps (clone section-writer loop + render) + DAG | trigger + materializer (`artifacts`) + artifact download | swap `PackageAssemblyService.reload()` (`:12`); wire review/download | **gov document templates** + writer prompts + context builder |
| **Z — Integrity Check** | `acquisition_integrity` steps (clone `review/compliance_check.py`) + DAG | trigger + materializer (`findings`) | swap `IntegrityCheckStep` seed → state; apply/dismiss persists | **FAR/policy/protest rule set** |
| **Finalize** | (reuse K's render output) | bundle/download endpoints | wire download handlers (`finalize-package-step` TODOs) | — |

Each per-step workstream stacks its own `phase-meta` blocks exactly like the slice's
`S1`(engine pipeline) → `S2`(DAG) → `S3/S4`(enums/DB, mostly F-covered after the first) →
`S5`(trigger) → `S6`(materializer) → `S7`(FE) → `S8`(CI). After R lands, F2/F4/F5 are
shared, so P/K/Z are lighter on the plumbing and heavier on domain content.

---

## Splitting the work across people

The compliance epic's **four-stream parallel model** is the proven template here; AP adds a
fifth, content-owner stream because the buyer-side domain data is the genuinely novel part.

```
        ┌─────────────────────────────────────────────────────────────────────┐
Stream A│ ENGINE (ONERING/Python)                                              │
        │  F6 → R(pipeline+DAG) → P(scoring+DAG) → K(writer+DAG) → Z(rules+DAG)│   ~1–2 eng
        └─────────────────────────────────────────────────────────────────────┘
        ┌─────────────────────────────────────────────────────────────────────┐
Stream B│ rohan_api (NestJS)                                                   │
        │  F1,F2,F3,F4 → R(trigger+mat) → P(trigger+mat) → K(…) → Z(…)         │   ~1–2 eng
        └─────────────────────────────────────────────────────────────────────┘
        ┌─────────────────────────────────────────────────────────────────────┐
Stream C│ rohan_ui (Angular)                                                   │
        │  F5 → R(hydrate) → P(swap generate) → K(swap reload) → Z → Finalize  │   ~1 eng
        └─────────────────────────────────────────────────────────────────────┘
        ┌─────────────────────────────────────────────────────────────────────┐
Stream D│ Prod-readiness / SRE                                                 │
        │  Helm pools, SLO, alerts, Key Vault, dashboards for AP DAGs          │   ~0.5 eng (SRE-led)
        └─────────────────────────────────────────────────────────────────────┘
        ┌─────────────────────────────────────────────────────────────────────┐
Stream E│ Domain content (contracting SME + prompt engineer)                   │
        │  vehicle reference data, FAR/policy/protest rules, gov doc templates,│   SME + ~0.5 eng
        │  extraction/scoring/writer prompts                                   │
        └─────────────────────────────────────────────────────────────────────┘
```

**How the streams interlock**

- **Contracts are the synchronization boundary.** Each step's `ui_projection_*.json` schema
  + the rohan_api DTOs are frozen first (Stream B publishes them); Streams A and C then build
  against the schema/PR diffs, not against each other's running code. This is the
  contract-stability gate used throughout the compliance epic and the slice (S7).
- **The dev mock decouples C from A.** Foundation **F4** ships an in-process Airflow mock that
  writes a fixture artifact and flips the run to SUCCESS. Stream C can build and demo the
  entire FE flow for every step **without** Stream A's real DAG existing yet — A only needs to
  be green before staging.
- **Stream E feeds A.** Engineers in Stream A build the *scaffold* (scoring step, writer step,
  integrity step) with placeholder content; Stream E replaces placeholders with real
  prompts/rules/templates/reference data. The schema is the handoff — E can iterate on content
  behind a frozen artifact schema without re-touching A's code.
- **Stream D runs from day one.** New AP DAGs are new prod workloads; SLOs and alerts must be
  designed alongside, not bolted on. Mirrors compliance Phase 11.

**Smallest sensible team:** 1 engineer can run the **slice** solo (S3→S1→S2→S4→S5→S6→S7→S8).
**Recommended for the full epic:** A(1–2) + B(1–2) + C(1) + D(0.5 SRE) + E(SME + 0.5), with R
(the slice) landing first to prove the spine, then P/K/Z fanning out in parallel because the
foundation is shared.

### Recommended sequencing

1. **Foundation + Requirements slice (R = S1–S8).** Single-threaded enough to keep small;
   proves the bridge, the materializer harness, and the FE hydration. **Gate the rest of the
   epic on this slice working in staging with the dev mock and one real DAG run.**
2. **Fan out P, K, Z in parallel** once F2/F4/F5 are shared. P and Z reuse the scoring and
   review engines (lighter engine work, heavier Stream E content); K is the heaviest (writer +
   templates) and should start earliest of the three.
3. **Finalize + prod-readiness convergence**, then per-org enablement behind the existing flag.

### Dependency notes

- P/K/Z each **depend on Foundation (F1–F5)** but **not on each other** — they touch different
  `run_state` keys, different DAGs, different FE services. True parallelism after R.
- K's render output is the input to **Finalize**; Finalize is the only intra-epic cross-step
  dependency.
- Stream E content for P (vehicle data) and Z (FAR rules) is on the critical path for those
  steps' *quality*, not their *plumbing* — ship the plumbing with placeholders, swap content
  when ready.

## Branching convention

`{user}/{epic}/phase-{N}`, epic = `acquisition-pathways-onering`. Each phase is one repo / one
PR; phases stack within a repo and coordinate cross-repo via the frozen schemas/DTOs. The
slice's `S*` phases are the Requirements workstream; `F*`/`P*`/`K*`/`Z*` follow the same
metadata shape.

## Jira shape

Epic **`acquisition-pathways-onering-integration`** with sub-epics per workstream:

- `…/foundation` — F1–F6.
- `…/requirements` — the slice (S1–S8). **First; gates the rest.**
- `…/pathway-selection` — P phases (+ Stream E vehicle data ticket).
- `…/package-assembly` — K phases (+ Stream E templates ticket).
- `…/integrity-check` — Z phases (+ Stream E FAR-rules ticket).
- `…/finalize` — packaging/download.
- `…/prod-readiness` — Stream D, parallel from kickoff.

Each sub-epic's tickets copy the relevant `phase-meta` block + a link to this doc and the
slice doc.

## Tech stack reference

| Layer | Stack |
|-------|-------|
| Engine (ONERING) | Python 3.x, Airflow 3.x (KubernetesExecutor), Pydantic v2, Helm; reuses orchestrator, ingestion, `opportunities/scoring`, `review/compliance_check`, writer, render, LLM controller |
| Backend (rohan_api) | NestJS, TypeScript, TypeORM, Jest, ajv; `/onering/*` (reused) + `/acquisition-pathways/*` (extended) |
| Frontend (rohan_ui) | Angular 20+ (signals, zoneless, non-standalone module), Karma/Jasmine |
| Storage | MinIO (`AGENT_RUNS/{arc_run_id}/…` artifacts; `acquisition/{org}/{mission}/uploads/` inputs) |
| Run tracking | `or_pipeline_runs` (reused; new `mission_id`); `acquisition_missions.run_state` (materialization target) |
| Auth | JWT; Airflow basic-auth token via `OneringAirflowClientService` |
| Already shipped | AP missions CRUD + `run_state` endpoints; AP chat via Answer Engine V2; the entire `/onering/*` Airflow integration |

---

## Appendix — what is already built (so we don't rebuild it)

- **Frontend:** the 5-step wizard, landing/mission-composer/missions-table, pathway cards,
  donut/integrity UI, finalize summary, analytics, feature-flag gating, all domain TS types.
  ~80–85% UI-complete on mocks. *(See `acquisition-pathways-step1-requirements-slice.md` for
  the exact swap points.)*
- **rohan_api AP module:** `acquisition_missions` entity + table, missions CRUD, `run_state`
  GET/PUT/PATCH with safety guards, chat (Answer Engine V2), guards, e2e suite.
- **rohan_api `/onering/*`:** the entire Airflow client + pipeline service + artifact service +
  run table + controllers — reused, not rebuilt.
- **ONERING:** orchestrator/DAG runner, ingestion, LLM controller, render engine, storage,
  config, `EvidenceSpan`, two-layer scoring (`opportunities/`), compliance-finding engine
  (`review/compliance_check.py`), `--steps-factory` invocation pattern, Helm Airflow stack.

**Genuinely net-new (the real cost):** buyer-side extraction/scoring/writer **prompts +
schemas**, **contract-vehicle reference data**, **government document templates**,
**FAR/policy/protest rule set**, and the per-step trigger/materializer/hydration wiring (which
is mechanical and shared after the slice).
