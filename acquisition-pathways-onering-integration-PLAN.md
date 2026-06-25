# Acquisition Pathways — ONERING integration architecture (epic, reference)

> **Scope of this document.** This is the *reference architecture* for powering the
> Acquisition Pathways (AP) backend with ONERING, across all five wizard steps. It is
> deliberately broad — a map and a work-split, not a line-by-line build plan. The
> **first vertical slice is fully specified in `acquisition-pathways-step1-requirements-slice.md`**
> and should be built first; every later step repeats that slice's shape. Read the slice
> doc for concrete contracts and code; read this for the whole-feature picture, the
> reuse-vs-build breakdown, and how to parallelize the work across people.
>
> **Work model (updated 2026-06-25).** The epic is organized as **full-stack vertical
> slices, one per wizard step** — *not* as horizontal per-repo streams. Each vertical is
> owned end-to-end by one full-stack engineer: ONERING pipeline + DAG, rohan_api
> trigger/materializer, and rohan_ui hydration are **one person's coherent unit of work**,
> reviewed as a cross-repo set. The only shared prerequisite is the **Foundation** (V0), and
> the only synchronization boundary between verticals is the **per-step I/O contract** —
> frozen in the companion doc **`acquisition-pathways-onering-integration-contracts.md`**,
> which specifies the inputs each wizard step consumes and the outputs it produces. After
> Foundation + the Requirements slice land, V2/V3/V4 run fully in parallel.

**Bridge decision (RESOLVED — team-agreed 2026-06-09):** all AP generation runs on the
**shipped Airflow `/onering/*` integration path** in rohan_api — for the **entire flow**:
all five wizard stages *plus* agentic chat and Auto-Run. This supersedes the alternative in
Alex's *Acquisition Pathways Production Design Doc* (`UA-Acquisition-Pathways` PR #10 —
actual PR title "Ap design initial", still open), which
locked **in-process answer-engine-v2 (sync/SSE)** generation with ONERING deferred to a late
"heavy path" stage. After comparing both (see *Decision record*), we chose **ONERING for
everything**: the high-value stages — Package Assembly's DOCX/PPTX/XLSX rendering and
Integrity's FAR/DFARS compliance engine — genuinely require ONERING machinery answer-engine-v2
lacks, so we prove the **single** bridge once on the cheapest stage (CRR) rather than standing
it up late on the heaviest. The helpful artifacts from Alex's doc are folded into this plan:
the typed **`AcquisitionRunState`** interface (Appendix E), the **name-mapping** table
(Appendix F), the **operating modes** + mode vocabulary (§"Operating modes"), the **agentic
chat / MCP control plane + Watcher + Auto-Run** (V6), the **38-tool production-home**
map (Appendix G), **per-tool RBAC** scopes, and the engine-agnostic **no-AI "Stage 0"
persistence foundation** (V0).

**Decision record (2026-06-09).** Considered: **(A)** ONERING/Airflow for all stages;
**(B)** in-process answer-engine-v2 for all stages (Alex's doc); **(C)** hybrid — light stages
(CRR, Pathways) in-process, heavy stages (Package Assembly, Integrity) on ONERING, behind one
`/generate {phase}` facade. **Chosen: A.** Rationale: ONERING is on the critical path for ~half
the stages and most of the deliverable value regardless; one generation path (not two) to
build, secure, and operate; the CRR slice de-risks that one path on the cheapest stage; uniform
Gov/air-gap story. The hybrid's fast-lane optimization (a thin synchronous `rohan-python-api`
lane for low-latency pathway re-scoring) is retained only as a **possible far-future
optimization** (Non-goals/Future work), not a planned divergence.

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
reference dataset — vehicle names appear only as extraction vocabulary (the
`contract_vehicle` metadata field), not as scoring reference data; those are genuinely new. But its orchestrator, ingestion, render engine,
LLM controller, evidence/provenance model, scoring pattern, and compliance-finding engine
are all directly reusable, and its product integration (Airflow `/onering/*`) is shipped.

## Key architectural observations

### The bridge: Airflow `/onering/*` is shipped; Service Bus is the wrong lane for ONERING

Verified in code (not just planned):

- `rohan_api/src/onering/` exists and is live: `OneringPipelineService`
  (`launchProposal`/`stageOpportunity`/`triggerDiscovery`/`listRuns`/`getRun`/
  `refreshRunStatus`), `OneringAirflowClientService` (Airflow REST v2 + token auth),
  `OneringArtifactService` (artifact list/stream proxied through `OneringApiClient`, not direct MinIO reads), `or_pipeline_runs` table,
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
| **Integrity Check** | `review/compliance_check.py` three-pass engine (deterministic checks → LLM judgment → LLM corrective actions), finding kinds/severities — distinct from the separate MAPPER review pipeline | FAR/DFARS/policy/protest rule set + cross-document consistency rules → `FindingGroup[]` | **Med–High** (engine reuses; rules new) |
| **Finalize Package** | `volume_assembler` + renderers + MinIO | bundling/download endpoints | **Low** |
| **Chat** (cross-cutting) | RAG baseline **already shipped** via Answer Engine V2 (`ap-chat.controller.ts`); ONERING `mcp_server` + `OneringMcpService` + ReAct agent for the agentic layer | **agentic control plane** (run_state read/mutate + generation-trigger MCP tools), Watcher endpoint, AP-tuned prompt branch — see **V6** | **Med** (baseline done; agentic layer net-new) |

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
shallow top-level `mergeState` (rohan_api `ap-missions.service.ts:319`) keeps them non-conflicting.

## Assumptions

1. `acquisition_missions` remains the AP source of truth; `or_pipeline_runs` is reused only
   for run tracking, linked by a new nullable `mission_id`.
2. Uploaded mission documents land in MinIO under a mission-keyed prefix the DAGs ingest via
   a net-new `dag_run.conf.document_uris` key (defined by the slice doc, not an existing
   ONERING mechanism; it feeds ONERING's existing `MANUAL_UPLOAD` ingestion).
3. Each step is independently triggerable and resumable; a mission can re-run any step.
4. The `AcquisitionPathways` feature flag + `acquisition-pathways` permission already gate
   the module; new endpoints reuse them.
5. Pathway Selection and Integrity Check **rules/reference-data** are owned by a contracting
   SME, not invented by engineering. Engineering ships the schemas, scoring/eval scaffolds,
   and the data ingestion path; the SME supplies the content.
6. Prod-readiness for new AP DAGs (first AP prod workloads) is a parallel workstream from
   kickoff, as a parallel prod-readiness feeding lane — not a late surprise.

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

- **Hybrid fast lane (Topology C) — possible far-future optimization only.** We committed to
  **ONERING for the entire flow** (Decision record, 2026-06-09), so the in-process / fast-lane
  split is *not* a planned divergence and needs **no per-phase notes**. Revisit a thin synchronous
  `rohan-python-api` endpoint (JWT via the existing RFP-Python-Server client pattern) for
  low-latency ops (pathway re-scoring) **only if** post-launch profiling shows Airflow latency
  measurably hurts the re-score UX. Default: leave it on ONERING.
- **Azure Government (`.us`)** feasibility for AP DAGs (mirror the compliance epic's Gov
  spike) — separate ticket; flag AP off for Gov orgs at launch.
- Audit-trail UI, document viewer for source pills, advanced export/packaging.
- Retiring any existing path (there is none to retire — AP is greenfield on the backend).

---

## Implementation phases (full-stack verticals)

The epic decomposes into **one shared Foundation (V0)** plus **six full-stack vertical
slices (V1–V6)**, fed by two support lanes (Domain content, Prod-readiness). **A vertical is
the unit of parallel work and the unit of ownership**: one full-stack engineer carries the
whole step — ONERING engine, rohan_api, rohan_ui — against the frozen per-step I/O contract.
Within a vertical the engineer still stacks one branch per repo (each repo has its own CI/PR),
but the three PRs land together as one reviewable slice; the work is **not** handed across an
api/ui boundary.

Each vertical's internal steps follow the proven slice shape, now owned by one person rather
than split across streams: **engine pipeline → DAG + frozen artifact schema → api enums/conf/DTOs
→ api trigger → api materializer + dev mock → ui swap/hydrate → slice E2E.** PRCR-1674 (Pathway
Selection) is the canonical worked example of this internal shape — see its `P1…P9` phases.

### V0 — Foundation (build once; shared by every vertical) [LARGELY SHIPPED]

```phase-meta
phase: 0
title: Foundation - shared AP↔ONERING run plumbing + frozen run_state contract
tags: [PYTHON, BACKEND_DB, FRONTEND]
repo: multi
base_branch: main
depends_on: []
files:
  - rohan_api-parent/rohan_api/src/acquisition-pathways/entities/acquisition-mission.entity.ts
  - rohan_api-parent/rohan_api/src/acquisition-pathways/types/run-state.types.ts
  - rohan_ui-parent/rohan_ui/src/app/pages/acquisition-pathways/types/acquisition-pathways.types.ts
  - rohan_ui-parent/rohan_ui/src/app/pages/acquisition-pathways/services/acquisition-run.service.ts
  - rohan_ui-parent/rohan_ui/src/app/pages/acquisition-pathways/components/mission-workspace/ap-mission-workspace.component.ts
  - ONERING/arc_agent_writer/factories/
contracts:
  - "§2 AcquisitionRunState (shared blob)"
  - "§8 Trigger + DAG-conf envelope (shared)"
verification:
  - cd rohan_api-parent/rohan_api && npm run lint && npm run test -- src/acquisition-pathways
  - cd rohan_ui-parent/rohan_ui && npm run test:ci
```

**Goal**: Freeze the shared contract and run plumbing every vertical builds on; ship the
no-AI persistence rails so the wizard runs on real state before any generation exists.

**Steps** (most already shipped by the Requirements slice — verify, don't rebuild):

- [x] **0.1** Tighten `AcquisitionRunState` from `Record<string, unknown>` to the typed
  interface (Appendix E) in both repos. Files: `acquisition-mission.entity.ts:81`,
  `run-state.types.ts`, rohan_ui `acquisition-pathways.types.ts`.
- [x] **0.2** No-AI persistence: `createMission` (persisted `mode ∈ {manual,auto}`) →
  navigate by `mission_id` → `ApMissionWorkspaceComponent` hosts wizard+chat → hydrate five
  wizard signals from `GET …/missions/:id/state` → persist each `nextAction` via `PATCH …/state`.
- [x] **0.3** `or_pipeline_runs.mission_id` + `materialized_at` + index; entity columns.
- [x] **0.4** Per-step enum convention (`OneringDagId.ACQUISITION_*`, `RunType.ACQUISITION_*`,
  `RunStatus.MATERIALIZING`) + `DagRunConf` union extension.
- [x] **0.5** Upload→MinIO endpoint + claim-check gateway (`onering_api` `/v1/acquisition`).
- [x] **0.6** Generic materializer harness: ajv version-strict validator base,
  Phase-A/Phase-B transaction discipline, `refreshRunStatus()` `MATERIALIZING` hook, in-process
  Airflow dev mock (`onering-airflow-mock.service.ts`).
- [x] **0.7** `AcquisitionRunService` (trigger + poll `/onering/runs/:id` + getState/patchState)
  and the `run_state.<key>` → signal hydration pattern.
- [x] **0.8** ONERING `factories/` package + shared ingestion-subset helper.

> **Foundation status:** the Requirements slice already shipped 0.1–0.8 (entity types,
> run service, materializer harness, dev mock, `factories/`). New verticals **reuse** these;
> a vertical only re-touches Foundation files to *add* its enum value, conf variant, or
> materializer-dispatch case. If anything in 0.1–0.8 is missing in a fresh checkout, fix it
> here before starting V2+.

### V1 — Requirements Record [SHIPPED — the slice]

```phase-meta
phase: 1
title: Requirements Record vertical (canonicalRecord)
tags: [PYTHON, BACKEND_DB, FRONTEND]
repo: multi
base_branch: main
depends_on: [0]
files:
  - ONERING/arc_agent_writer/factories/acquisition_requirements.py
  - rohan_api-parent/rohan_api/src/acquisition-pathways/dto/runs/extract-requirements.dto.ts
  - rohan_ui-parent/rohan_ui/src/app/pages/acquisition-pathways/steps/
contracts:
  - "§3 Requirements Record I/O"
verification:
  - see acquisition-pathways-step1-requirements-slice.md
```

**Goal**: Prove the bridge, the materializer harness, and FE hydration on the cheapest stage.

Fully specified and built in **`acquisition-pathways-step1-requirements-slice.md`** (`S1–S8`).
Materializes `canonicalRecord` (+`requirementsRecordNotes` is user-owned). This vertical is the
template every later vertical copies. **Gate V2–V4 on this working in staging** (dev mock + one
real DAG run).

### V2 — Pathway Selection [IN PROGRESS — PRCR-1674]

```phase-meta
phase: 2
title: Pathway Selection vertical (pathways, selectedPathway)
tags: [PYTHON, BACKEND_DB, FRONTEND]
repo: multi
base_branch: main
depends_on: [0, 1]
files:
  - ONERING/arc_agent_writer/factories/acquisition_pathways.py
  - ONERING/arc_agent_writer/pipelines/acquisition_pathways.py
  - ONERING/arc_agent_writer/acquisition/vehicles/
  - rohan_api-parent/rohan_api/src/acquisition-pathways/dto/runs/generate-pathways.dto.ts
  - rohan_api-parent/rohan_api/src/acquisition-pathways/types/acquisition-pathway.ts
  - rohan_ui-parent/rohan_ui/src/app/pages/acquisition-pathways/services/pathway-selection.service.ts
contracts:
  - "§4 Pathway Selection I/O"
verification:
  - cd rohan_api-parent/rohan_api && npm run lint && npm run test -- src/acquisition-pathways
  - cd rohan_ui-parent/rohan_ui && npm run test:ci
```

**Goal**: Generate, score, and persist contracting pathways; FE swaps mock → trigger/poll/hydrate.

**Steps** (the per-repo build sequence is detailed in `PRCR-1674-PLAN.md` `P1…P9`):

- [ ] **2.1 [engine]** `acquisition_pathways` synthesis pipeline + `acquisition_pathways:build_steps`
  factory; clone the two-layer pattern (`opportunities/scoring.py` deterministic + `opp_matcher.py`
  LLM). `arc_acquisition_pathways` DAG + frozen `ui_projection_acquisition_pathways.json` schema.
- [ ] **2.2 [engine]** Contract-vehicle catalog (`acquisition/vehicles/`) + deterministic+LLM scorer
  populating `score`/`evidence` behind the frozen schema (domain content feeds this).
- [ ] **2.3 [api]** `OneringDagId.ACQUISITION_PATHWAYS`, `AcquisitionPathwaysConf`, trigger DTO +
  `AcquisitionPathway`/`PathwayDimensions` types.
- [ ] **2.4 [api]** `POST …/missions/:id/pathways:generate` + `triggerAcquisitionPathways()`
  (reads `canonicalRecord`, claim-checks it under `pathways/`).
- [ ] **2.5 [api]** Pathways artifact validator + materializer → `run_state.pathways` (+ default
  `selectedPathway`) + dev-mock pathways fixture.
- [ ] **2.6 [ui]** Swap `PathwaySelectionService.generate()` → trigger + poll + hydrate
  `run_state.pathways`; render `dimensions`/`score`.
- [ ] **2.7 [test]** Slice E2E via in-process mock.

### V3 — Package Assembly [NOT STARTED — heaviest vertical, start first of V3/V4]

```phase-meta
phase: 3
title: Package Assembly vertical (scheduledArtifacts, artifacts, documents)
tags: [PYTHON, BACKEND_DB, FRONTEND]
repo: multi
base_branch: main
depends_on: [0, 1]
files:
  - ONERING/arc_agent_writer/factories/acquisition_package.py
  - rohan_api-parent/rohan_api/src/acquisition-pathways/
  - rohan_ui-parent/rohan_ui/src/app/pages/acquisition-pathways/steps/package-assembly-step/package-assembly.service.ts
contracts:
  - "§5 Package Assembly I/O"
verification:
  - cd rohan_api-parent/rohan_api && npm run lint && npm run test -- src/acquisition-pathways
  - cd rohan_ui-parent/rohan_ui && npm run test:ci
```

**Goal**: Generate and render acquisition documents (Acq Plan, MRR, SOW/PWS/SOO, RFI/RFP…) and
persist durable artifacts the FE rebuilds card state from.

**Steps**:

- [ ] **3.1 [engine]** `acquisition_package:build_steps` factory cloning the section-writer loop
  (draft→critique→revise→summarize) + `consistency_ledger` + `source_packet_builder` + render
  engine (DOCX/PPTX/XLSX) + `volume_assembler`. `arc_acquisition_package` DAG + frozen
  `ui_projection_acquisition_package.json` schema.
- [ ] **3.2 [engine]** Government document templates + buyer-side writer prompts + acquisition
  context builder (domain content feeds this; ship scaffold with placeholders first).
- [ ] **3.3 [api]** `OneringDagId.ACQUISITION_PACKAGE`, conf variant, trigger DTO + artifact types.
- [ ] **3.4 [api]** `POST …/missions/:id/artifacts:generate` + trigger (reads `canonicalRecord` +
  `selectedPathway`).
- [ ] **3.5 [api]** Artifact validator + materializer → `run_state.scheduledArtifacts` (persist
  durable `Artifact`, NOT volatile `AssemblyCard`) + artifact download endpoint + dev-mock fixture.
- [ ] **3.6 [ui]** Swap `package-assembly.service.ts` mock → trigger/poll/hydrate; rebuild card
  animation from terminal `Artifact` states; wire review/download.
- [ ] **3.7 [test]** Slice E2E via in-process mock.

### V4 — Integrity Check [NOT STARTED — parallel with V3]

```phase-meta
phase: 4
title: Integrity Check vertical (findings)
tags: [PYTHON, BACKEND_DB, FRONTEND]
repo: multi
base_branch: main
depends_on: [0, 1]
files:
  - ONERING/arc_agent_writer/factories/acquisition_integrity.py
  - rohan_api-parent/rohan_api/src/acquisition-pathways/
  - rohan_ui-parent/rohan_ui/src/app/pages/acquisition-pathways/steps/integrity-check-step/integrity-check-step.component.ts
contracts:
  - "§6 Integrity Check I/O"
verification:
  - cd rohan_api-parent/rohan_api && npm run lint && npm run test -- src/acquisition-pathways
  - cd rohan_ui-parent/rohan_ui && npm run test:ci
```

**Goal**: Run FAR/policy/consistency/protest checks over the package; persist findings with
server-side merge that preserves user triage on re-run.

**Steps**:

- [ ] **4.1 [engine]** `acquisition_integrity:build_steps` cloning `review/compliance_check.py`
  three-pass engine (deterministic checks → LLM judgment → LLM corrective actions).
  `arc_acquisition_integrity` DAG + frozen `ui_projection_acquisition_integrity.json` schema.
- [ ] **4.2 [engine]** FAR/DFARS/policy/protest rule set + cross-document consistency rules
  (domain content feeds this; scaffold with placeholders first).
- [ ] **4.3 [api]** `OneringDagId.ACQUISITION_INTEGRITY`, conf variant, trigger DTO + finding types.
- [ ] **4.4 [api]** `POST …/missions/:id/findings:generate` + trigger (reads artifacts).
- [ ] **4.5 [api]** Finding validator + materializer → `run_state.findings` implementing
  **`mergeReplace`** server-side (preserve `edited`/`dismissed`/`dismissReason`, append only
  `isNew`, title-dedup per group) + dev-mock fixture.
- [ ] **4.6 [ui]** Swap `integrity-check.seed.ts` → state; apply/dismiss persists via PATCH.
- [ ] **4.7 [test]** Slice E2E covering re-run merge behavior.

### V5 — Finalize Package [NOT STARTED — depends on V3 render output]

```phase-meta
phase: 5
title: Finalize vertical (ledger, bundle/download)
tags: [PYTHON, BACKEND_DB, FRONTEND]
repo: multi
base_branch: main
depends_on: [0, 3]
files:
  - rohan_api-parent/rohan_api/src/acquisition-pathways/
  - rohan_ui-parent/rohan_ui/src/app/pages/acquisition-pathways/steps/finalize-package-step/finalize-package-step.component.ts
contracts:
  - "§7 Finalize I/O"
verification:
  - cd rohan_api-parent/rohan_api && npm run lint && npm run test -- src/acquisition-pathways
  - cd rohan_ui-parent/rohan_ui && npm run test:ci
```

**Goal**: Bundle V3's rendered artifacts for release and wire the download handlers.

**Steps**:

- [ ] **5.1 [engine/api]** Reuse V3's `volume_assembler` + renderers; bundle/download endpoints.
- [ ] **5.2 [api]** Materialize `run_state.ledger` (generated; display panel deferred).
- [ ] **5.3 [ui]** Wire the "not yet wired" placeholder toasts in `finalize-package-step.component.ts`
  to real download handlers.

### V6 — Agentic chat + Auto-Run + Watcher [NOT STARTED — depends on V2–V4 DAGs]

```phase-meta
phase: 6
title: Agentic control plane vertical (MCP tools, Auto-Run DAG, Watcher)
tags: [PYTHON, BACKEND_DB, FRONTEND]
repo: multi
base_branch: main
depends_on: [0, 2, 3, 4]
files:
  - ONERING/mcp_server/tools/procurement.py
  - rohan_api-parent/rohan_api/src/utils/onering-mcp/onering-mcp.service.ts
  - rohan_ui-parent/rohan_ui/src/app/pages/acquisition-pathways/
contracts:
  - "§9 Chat / MCP control-plane I/O"
verification:
  - cd rohan_api-parent/rohan_api && npm run lint && npm run test -- src/acquisition-pathways
  - cd rohan_ui-parent/rohan_ui && npm run test:ci
```

**Goal**: Make Rohan *act* — run_state read/mutate + generation-trigger MCP tools (firing the
**same** `arc_acquisition_*` DAGs the wizard buttons do), the chaining Auto-Run DAG, and the
read-only Watcher turn.

**Steps**:

- [ ] **6.1 [engine]** `mcp_server/tools/procurement.py` — run_state read/mutate tools +
  generation triggers (Appendix G homes); register in `server.py`.
- [ ] **6.2 [engine]** Chaining `arc_acquisition_autorun` DAG sequencing record→pathway→artifacts→findings→ledger.
- [ ] **6.3 [api]** Bind AP MCP tools via `OneringMcpService.getToolsForUser` + ReAct agent;
  allowlist in `onering-mcp.service.ts:28` (cap `ONERING_MCP_CHAT_TOOL_LIMIT = 120`); per-tool
  `@Permissions()` scopes; Auto-Run persist-then-trigger with deterministic run-ids + in-flight
  short-circuit; `POST …/missions/:id/watcher`.
- [ ] **6.4 [ui]** AP-tuned chat prompt branch; client-side Watcher gating; Auto-Run progress via
  run polling.

### Operating modes (Drive · Auto-Run · Watcher)

Three modes, ported from Alex's doc and mapped onto ONERING:

- **Drive (v1, all of V1–V5; persisted as `mode: 'manual'`).** Per-stage, human-in-the-loop: each wizard step triggers
  exactly one stage's DAG (`{phase}` → one `arc_acquisition_*` run), materializes, and stops for
  review/edit. The default through every vertical above.
- **Auto-Run (V6).** Chains all stages unattended. ONERING-native: a single
  **`arc_acquisition_autorun` DAG** (or a parent DAG sequencing the per-stage step factories)
  runs record→pathway→artifacts→findings→ledger with checkpointing; rohan_api persists-then-
  triggers with deterministic run-ids + in-flight short-circuit (precedent: the in-flight
  short-circuit in `OneringPipelineService.stageOpportunity()`),
  polls while RUNNING, and materializes each stage's `run_state` key as it completes; surfaced to
  the UI via the existing run-polling path. *(This is exactly what ONERING's Airflow already does
  for proposals — Auto-Run is markedly cheaper under "ONERING for everything" than it would have
  been in-process.)*
- **Watcher (V6).** A proactive read-only assistant turn: `POST …/missions/:id/watcher`
  (`{event, context}`) → ≤2 sentences, no mutations, ≤1 read-only tool, "empty reply is valid."
  The **gating policy** (enabled toggle, 60s cooldown buckets, 8/session cap,
  no-interrupt-during-phase, busy-drop with single-slot replay for high-severity dismissals,
  reset on new mission) stays **client-side** in rohan_ui and decides *whether* to POST.

**Mode vocabulary (corrected 2026-06-09):** the shipped persisted enum is
**`mode ∈ {manual, auto}`** (`AcquisitionMissionMode`, `acquisition-mission.entity.ts:10`), and
the UI composer matches — no mapping needed. A `manual→drive` rename was attempted on a feature
branch and deliberately **reverted** (rohan_ui commit `c076e85f3`; the rename was *not*
PRCR-1650, which was unrelated component work). Re-adopting `drive` would now require a data
migration, so this plan keeps `manual|auto` unless the team re-decides. "Drive" remains the UX
label for the manual mode only. Full stage-name drift table in Appendix F.

**Single front door (optional, recommended).** The per-step trigger endpoints can sit behind one
canonical **`POST …/missions/:id/generate {phase, mode}`** facade that routes `phase` to the
right `arc_acquisition_*` DAG and returns a run handle the FE polls. This gives Alex's
"written-once, never-forked" generation path: the **wizard buttons and the chat MCP tools call
the same endpoint** — neither re-implements generation. Adopt it as the public surface once ≥2
stages exist; V2 may ship per-step endpoints first and converge them. Contract in **§8**.

### V6 detail — agentic chat + MCP control plane

The baseline AP chat (Answer Engine V2, `ap-chat.controller.ts`) is shipped and stays the RAG
front door. V6 makes Rohan *act*, reusing ONERING's `mcp_server` — the natural home now
that everything runs on ONERING:

- **`ONERING/mcp_server/tools/procurement.py`** exposes the prototype's run_state read/mutate tools
  and **generation triggers that fire the same `arc_acquisition_*` DAGs the wizard buttons do** —
  one generation path, two front doors (button + chat), never forked. Register in ONERING's `server.py`; allowlist
  in **rohan_api** — `DEFAULT_ONERING_MCP_CHAT_TOOL_ALLOWLIST` lives in rohan_api's
  `src/utils/onering-mcp/onering-mcp.service.ts:28`, capped by `ONERING_MCP_CHAT_TOOL_LIMIT = 120`
  (headroom under OpenAI's 128-tool limit).
- **rohan_api** binds the AP MCP tools via `OneringMcpService.getToolsForUser` + the LangChain
  ReAct agent, adds the AP-tuned retrieval/prompt branch, and adds `POST …/missions/:id/watcher`.
- **Per-tool RBAC** (Appendix G): generation/mutation endpoints + MCP tools carry `@Permissions()`
  scopes (e.g. `populate_findings → compliance.write`, `generate_decision_memo →
  procurement.write`) behind the existing `permissions.guard.ts` — finer-grained than the single
  `acquisition-pathways` permission the v1 wizard endpoints reuse.

The 38 prototype tools' production homes are in **Appendix G**: 4 client-only (drop server-side),
~24 thin run_state reads/writes (rohan_api endpoints / MCP), 8 heavy generators (= the
`arc_acquisition_*` DAGs; MCP-exposed here), 2 retrieval (ONERING retrieval layer).

---

## Phase order and parallelism

### One full-stack owner per vertical (not per repo)

The previous draft split the work into horizontal per-repo streams (engine / api / ui) that
synchronized at the contract boundary. **This plan inverts that:** the unit of parallel work is
the **vertical slice**, owned end-to-end by one full-stack engineer. The api and ui for a step
are never handed across a boundary — they are the same person's work, landing together.

```
  V0  Foundation             shared, build once (largely shipped)
   |
  V1  Requirements           proves the spine; gates V2-V4 (shipped)
   |
   +--> V2  Pathway          (engine+api+ui)  owner: Eng1   --+
   +--> V3  Package          (engine+api+ui)  owner: Eng2     |  run fully in parallel
   +--> V4  Integrity        (engine+api+ui)  owner: Eng3   --+  after V0 + V1
   |
   +--> V5  Finalize         depends on V3 render output
   |
   +--> V6  Chat/Auto-Run/Watcher   depends on V2-V4 DAGs

  Feeding lanes (support roles, not verticals):
    - Domain content (SME + prompt eng): vehicle data -> V2, gov templates -> V3, FAR rules -> V4
    - Prod-readiness (SRE, ~0.5): Helm pools, SLOs, alerts, dashboards for AP DAGs -- from day one
```

### File-touch matrix

| | ONERING | rohan_api | rohan_ui | run_state key written |
|---|---|---|---|---|
| **V0 Foundation** | `factories/` | entity, run-state types, materializer harness, dev mock, enums | run service, workspace host, run_state types | — (rails only) |
| **V1 Requirements** | `factories/acquisition_requirements.py` | requirements trigger+materializer | requirements step hydrate | `canonicalRecord` |
| **V2 Pathway** | `factories/acquisition_pathways.py`, `acquisition/vehicles/` | pathways trigger+materializer, `acquisition-pathway.ts` | `pathway-selection.service.ts` | `pathways`, `selectedPathway` |
| **V3 Package** | `factories/acquisition_package.py` | package trigger+materializer, download | `package-assembly.service.ts` | `scheduledArtifacts`, `artifacts`, `documents` |
| **V4 Integrity** | `factories/acquisition_integrity.py` | integrity trigger+materializer (mergeReplace) | `integrity-check-step.component.ts` | `findings` |
| **V5 Finalize** | (reuses V3 render) | bundle/download endpoints | `finalize-package-step.component.ts` | `ledger` |
| **V6 Control plane** | `mcp_server/tools/procurement.py`, autorun DAG | MCP bind, watcher, per-tool RBAC | chat prompt branch, watcher gating | (mutates all) |

**V2/V3/V4 touch disjoint files** — different factories, different conf variants, different
materializer cases, different FE services. The only shared files are V0's (enum file, materializer
dispatch, run-state types), where each vertical *adds* one case; coordinate those small additions
via the frozen contract, not by serializing the verticals.

### What makes the parallelism safe

- **The frozen per-step I/O contract is the only synchronization boundary.** Each step's
  `ui_projection_*.json` schema + run_state key + FE type are frozen in
  `acquisition-pathways-onering-integration-contracts.md` *before* a vertical starts. The owner
  builds engine→api→ui against their own frozen contract — no cross-vertical coordination.
- **The dev mock removes the intra-vertical ordering pain.** V0's in-process Airflow mock writes a
  fixture artifact and flips the run to SUCCESS, so the owner can build api + ui against the frozen
  schema before their real DAG is green. The real DAG only needs to be green before *staging*.
- **Domain content iterates behind the frozen schema.** Each vertical ships its engine *scaffold*
  with placeholder prompts/rules/templates; the SME swaps real content later without re-touching
  api/ui. The artifact schema is the handoff.
- **Prod-readiness runs from day one.** New AP DAGs are new prod workloads; SLOs/alerts are
  designed alongside, not bolted on.

### Recommended sequencing

0. **V0 Foundation** — *largely shipped.* Verify the rails (typed `AcquisitionRunState`, run
   service, materializer harness, dev mock, `factories/`) hold in a fresh checkout; fill gaps here.
1. **V1 Requirements (the slice)** — *shipped.* Proves the bridge end-to-end. **Gate V2–V4 on V1
   working in staging** (dev mock + one real DAG run).
2. **Fan out V2, V3, V4 in parallel**, one full-stack owner each. Start **V3 (Package) earliest**
   of the three — it is the heaviest (section-writer loop + render + templates). V2 (Pathway) is in
   progress as PRCR-1674. V4 (Integrity) reuses the compliance-check engine.
3. **V5 Finalize** once V3's render output exists (the only intra-epic cross-vertical dependency),
   then per-org enablement behind the existing `AcquisitionPathways` flag.
4. **V6 control plane** after V2–V4 DAGs exist (so MCP tools have real DAGs to trigger and Auto-Run
   has stages to chain). Reuses the generation path; net-new is the MCP tools, the chaining DAG, the
   Watcher endpoint, and the prompt port.

**Smallest sensible team:** 1 full-stack engineer can run a single vertical solo
(engine→api→ui→E2E). **Recommended for the full epic:** 3 full-stack engineers (one per V2/V3/V4)
+ 0.5 SRE (prod-readiness) + SME + 0.5 prompt eng (domain content), with V1 landed first.

## Branching convention

A vertical is **one owner's cross-repo unit of work**. Because each repo has its own CI/PR, the
owner still cuts one branch per repo, but all three branches for a vertical land together as a
single reviewable slice:

```
{user}/acquisition-pathways-onering/v{N}-{repo}
  e.g.  tim/acquisition-pathways-onering/v2-onering
        tim/acquisition-pathways-onering/v2-rohan_api
        tim/acquisition-pathways-onering/v2-rohan_ui
```

Within a repo, a vertical's phases stack (engine pipeline → DAG, or api enums → trigger →
materializer) as before. Cross-repo, the verticals coordinate **only** via the frozen contract.
The active PRCR-1674 phase branches (`acquisition-pathways-onering-phase-P*`) are V2's per-repo
phases under this scheme.

## Jira shape

Epic **`acquisition-pathways-onering-integration`** with **one sub-epic per vertical** (each
sub-epic is a full-stack unit, not a per-repo stream):

- `…/foundation` — V0 (no-AI persistence + frozen `AcquisitionRunState` contract; **largely shipped**).
- `…/requirements` — V1, the slice. **First vertical; gates the rest.** (**shipped**)
- `…/pathway-selection` — V2 (engine+api+ui + vehicle-data content ticket). *(PRCR-1674, in progress)*
- `…/package-assembly` — V3 (engine+api+ui + gov-templates content ticket).
- `…/integrity-check` — V4 (engine+api+ui + FAR-rules content ticket).
- `…/finalize` — V5 (engine+api+ui packaging/download).
- `…/chat-control-plane` — V6 (MCP tools, Auto-Run DAG, Watcher, prompt port). After V2–V4 DAGs.
- `…/prod-readiness` — feeding lane (SRE), parallel from kickoff.
- `…/domain-content` — feeding lane (SME + prompt eng): vehicle data, gov templates, FAR rules.

Each vertical's tickets copy that vertical's `phase-meta` block + a link to this doc, the slice
doc, and the per-step section of the contracts doc.

## Tech stack reference

| Layer | Stack |
|-------|-------|
| Engine (ONERING) | Python 3.x, Airflow 3.x (KubernetesExecutor), Pydantic v2, Helm; reuses orchestrator, ingestion, `opportunities/scoring`, `review/compliance_check`, writer, render, LLM controller |
| Backend (rohan_api) | NestJS, TypeScript, TypeORM, Jest, ajv (net-new dependency); `/onering/*` (reused) + `/acquisition-pathways/*` (extended) |
| Frontend (rohan_ui) | Angular 20+ (signals, zoneless, non-standalone module), Karma/Jasmine |
| Storage | MinIO (`AGENT_RUNS/{arc_run_id}/…` artifacts; `acquisition/{org}/{mission}/uploads/` inputs) |
| Run tracking | `or_pipeline_runs` (reused; new `mission_id`); `acquisition_missions.run_state` (materialization target) |
| Auth | JWT; Airflow token auth (`POST /auth/token` → Bearer) via `OneringAirflowClientService` |
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

---

## Appendix E — full `AcquisitionRunState` interface (ported from Alex's design doc)

The single shared contract for the opaque `run_state` blob. Add this net-new to rohan_ui
`types/acquisition-pathways.types.ts` (the UI has no run_state type today) and tighten
rohan_api's existing `AcquisitionRunState = Record<string, unknown>` alias
(`acquisition-mission.entity.ts:72`) to match. **Every per-step materializer must write keys whose shapes deserialize 1:1 into
the five wizard signals** — this is the schema the `ui_projection_*.json` artifacts and the
materializers (V0 harness + each vertical) target.

```ts
// run_state JSONB blob in acquisition_missions.run_state, returned by
// GET /acquisition-pathways/missions/:id/state as { run_state: AcquisitionRunState }.
interface AcquisitionRunState {
  // --- record  → wizard.requirementsRecord (CrrField[]); materialized from canonicalRecord DAG ---
  canonicalRecord?: Array<{
    label: string;                                   // e.g. "Estimated Value" (edit key)
    icon?: string;                                   // material-symbol name
    tag: 'extracted' | 'inferred' | 'needs' | 'user'; // provenance chip; user edits flip to 'user'
    text: string;
    sources: Array<{                                 // SourcePill[]
      kind: 'web' | 'library' | 'upload' | 'user-typed';
      label: string;
      href?: string;                                 // web sources
      docId?: string;                                // library/upload sources
    }>;
  }>;
  requirementsRecordNotes?: string;                  // user-typed; not generated (matches the wizard signal)

  // --- pathway → wizard.selectedPathway + PathwaySelectionService ---
  pathways?: Array<{
    id: 'low' | 'medium' | 'high';                   // tier + track id
    name: string; vehicle: string;
    vehicleType: 'existing' | 'new';
    tierLabel: string; tierIcon: string;
    contractType: string;                            // free-form pill text, NO enum
    contractTypeClass?: string;                      // reserved SCSS modifier, unused today
    rationale: string;                               // limited inline HTML; UI sanitizes
    features: Array<{ icon: string; text: string; tone?: 'ok' | 'warn' | 'fail' }>;
    recommended?: string;                            // badge label; omit for non-recommended
    dimensions?: Record<string, unknown>;            // protestExposure, timeToAwardMonths,
                                                     // vendorPoolSize, vehicleStandUp,
                                                     // costRiskOwner, scopeFlexibility,
                                                     // bestFor, mainRisk — used by
                                                     // compare_pathways / simulate_pathway_change.
                                                     // MUST be added to the rohan_ui interface
                                                     // before the UI can render it.
  }>;
  selectedPathway?: 'low' | 'medium' | 'high' | null;
  pathwayCommitted?: boolean;                        // default false; true after any select;
                                                     // gates "Assemble package"

  // --- artifacts (stage slug 'interview'/'package-assembly') → wizard.packageAssemblyCards ---
  // PERSIST the durable Artifact, NOT the volatile AssemblyCard (UI rebuilds animation state).
  scheduledArtifacts?: Array<{
    key: string; title: string; subtitle?: string;
    type: string;                                    // 'SOW' | 'RFP' | ... free string
    filename: string; pages: number; icon: string; edited?: boolean;
  }>;
  // Optional resolved card states (terminal only) to skip re-animation on reload:
  artifacts?: Array<{
    artifact: { key: string; title: string; subtitle?: string; type: string; filename: string; pages: number; icon: string; edited?: boolean };
    state: 'queued' | 'drafting' | 'done' | 'removed';
    progress: number; label: string; removedReason?: string;
  }>;
  documents?: unknown[];                             // Rohan-created docs (distinct from artifacts)
  removedDocuments?: unknown[];

  // --- findings (UI 'integrity') → wizard.integrityCheckGroups (FindingGroup[]) ---
  // Re-runs use mergeReplace: preserve edited/dismissed/dismissReason, append only isNew,
  // title-dedup per group. Materializer MUST reproduce this server-side.
  findings?: Array<{
    key: string; label: string; name: string;
    findings: Array<{
      id: string;
      artifact: string;
      severity: 'high' | 'med' | 'low';              // note 'med' not 'medium'
      category: 'policy' | 'consistency' | 'protest' | 'clause';
      categoryLabel: string; title: string; meta: string;
      sections: Array<{
        label: string; quote: string; isOffending?: boolean;
        sources?: Array<{ kind: 'web' | 'library' | 'upload'; label: string; docId?: string; href?: string }>;
      }>;
      actions: Array<{ label: string; icon: string; primary?: boolean; kind: 'apply' | 'dismiss' }>;
      // USER TRIAGE STATE — generator sets initial; UI owns after first render; mergeReplace preserves:
      expanded?: boolean; dismissed?: boolean; dismissReason?: string;
      edited?: boolean;                              // == "applied"
      isNew?: boolean;                               // mergeReplace marks genuinely-new re-run findings
    }>;
  }>;

  // --- ledger (UI 'export') — generated + persisted; display panel deferred ---
  ledger?: Array<{ field?: string; value?: string; confidence?: number; [k: string]: unknown }>;

  // Run handle pointer (FE convenience; see Open question 2):
  // e.g. requirementsRun?: { arcRunId: string; status: RunStatus }, one per stage.

  [extraKey: string]: unknown;                       // blob tolerates extra keys
}
```

## Appendix F — name-mapping (single source of truth, from Alex's design doc)

The four vocabularies drift; this table governs. **`generate`'s `phase` enum uses the phase
names**; materializers write the `run_state` key; the persisted stage cursor + URL slug are
UI-side (cursor values = the UI's existing `sourceFeature` strings in the AP `constants.ts`).

| Phase (generate / DAG) | `run_state` key | Persisted stage cursor | Wizard URL slug | ONERING DAG |
|---|---|---|---|---|
| `record` | `canonicalRecord` (+`requirementsRecordNotes`) | `canonical-record` | `requirements-record` | `arc_acquisition_requirements` |
| `pathway` | `pathways`, `selectedPathway`, `pathwayCommitted` | `pathways` | `pathway-selection` | `arc_acquisition_pathways` |
| `artifacts` | `scheduledArtifacts` (+`artifacts`,`documents`) | `interview` | `package-assembly` | `arc_acquisition_package` |
| `findings` | `findings` | `integrity` | `integrity-check` | `arc_acquisition_integrity` |
| `ledger` | `ledger` | `export-package` | `finalize-package` | (Finalize; reuses K render output) |

Mode enum: `mode ∈ {manual, auto}` (shipped `AcquisitionMissionMode`; the `drive` rename was attempted and reverted — see §"Operating modes").

## Appendix G — 38 prototype tools → production homes (ported + re-homed for ONERING)

The prototype's 38 client-side tools (`ua-acquisition-pathways/proxy/src/tools/*.js`), mapped to
production. **Homes:** `client-only-drop` ×4 · `run_state-rw` ×24 (reads + simple writes +
lifecycle) · `arc-dag-generator` ×8 (heavy LLM generation = the `arc_acquisition_*` DAGs, exposed
as MCP tools in **V6**) · `rohan_api-retrieval` ×2.

> Under "ONERING for everything," the 8 generators are **not** in-process — each is (or maps onto)
> an `arc_acquisition_*` DAG. The MCP tools in V6 are thin triggers/readers that call the
> same DAG path the wizard buttons use; they do not re-implement generation.

| Tool | Home | Notes |
|---|---|---|
| `navigate`, `set_mode`, `append_to_draft`, `load_sample_mission` | client-only-drop | UI-only; forbidden server-side (`set_mode` tracks mode as a `run_state` field) |
| `get_mission_state`, `set_mission_name`, `set_mission_statement`, `add_attached_files` | run_state-rw | mission scalars + attachment refs |
| `update_crr_field`, `add_crr_field`, `remove_crr_field`, `clear_canonical_record` | run_state-rw | CRR edits (flip `tag→'user'`) |
| `select_pathway`, `compare_pathways`, `set_recommended_pathway`, `simulate_pathway_change` | run_state-rw | tier select + read/derive (no LLM); use `dimensions` |
| `start_document`, `remove_document`, `get_document`, `list_documents`, `get_document_sections`, `update_document_section` | run_state-rw | document CRUD/sections |
| `apply_finding`, `dismiss_finding` (reason mandatory), `explain_finding` | run_state-rw | finding triage (`apply`→`edited:true`) |
| `intake_complete`, `complete_auto_run`, `pause_auto_run` | run_state-rw | lifecycle signals → Auto-Run state machine (V6); the latter two were retired in the prototype |
| `populate_canonical_record`, `populate_pathways`, `populate_artifacts`, `populate_findings`, `populate_ledger` | arc-dag-generator | the five stage DAGs (`{phase}`); findings DAG reproduces `mergeReplace` |
| `complete_document`, `edit_document`, `generate_decision_memo` | arc-dag-generator | HTML prose generation (memo uses a two-call grounding pattern: rohan_api read + ONERING synth) |
| `search_library`, `open_source_doc` | rohan_api-retrieval | ONERING retrieval layer (`PgVectorStore` / library) |
