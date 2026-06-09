# Acquisition Pathways — ONERING integration architecture (epic, reference)

> **Scope of this document.** This is the *reference architecture* for powering the
> Acquisition Pathways (AP) backend with ONERING, across all five wizard steps. It is
> deliberately broad — a map and a work-split, not a line-by-line build plan. The
> **first vertical slice is fully specified in `acquisition-pathways-step1-requirements-slice.md`**
> and should be built first; every later step repeats that slice's shape. Read the slice
> doc for concrete contracts and code; read this for the whole-feature picture, the
> reuse-vs-build breakdown, and how to parallelize the work across people.

**Bridge decision (RESOLVED — team-agreed 2026-06-09):** all AP generation runs on the
**shipped Airflow `/onering/*` integration path** in rohan_api — for the **entire flow**:
all five wizard stages *plus* agentic chat and Auto-Run. This supersedes the alternative in
Alex's *Acquisition Pathways Production Design Doc* (`ua-acquisition-pathways` PR #10), which
locked **in-process answer-engine-v2 (sync/SSE)** generation with ONERING deferred to a late
"heavy path" stage. After comparing both (see *Decision record*), we chose **ONERING for
everything**: the high-value stages — Package Assembly's DOCX/PPTX/XLSX rendering and
Integrity's FAR/DFARS compliance engine — genuinely require ONERING machinery answer-engine-v2
lacks, so we prove the **single** bridge once on the cheapest stage (CRR) rather than standing
it up late on the heaviest. The helpful artifacts from Alex's doc are folded into this plan:
the typed **`AcquisitionRunState`** interface (Appendix E), the **name-mapping** table
(Appendix F), the **operating modes** + mode vocabulary (§"Operating modes"), the **agentic
chat / MCP control plane + Watcher + Auto-Run** (Workstream X), the **38-tool production-home**
map (Appendix G), **per-tool RBAC** scopes, and the engine-agnostic **no-AI "Stage 0"
persistence foundation** (phase F0).

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
| **Chat** (cross-cutting) | RAG baseline **already shipped** via Answer Engine V2 (`ap-chat.controller.ts`); ONERING `mcp_server` + `OneringMcpService` + ReAct agent for the agentic layer | **agentic control plane** (run_state read/mutate + generation-trigger MCP tools), Watcher endpoint, AP-tuned prompt branch — see **Workstream X** | **Med** (baseline done; agentic layer net-new) |

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

- **F0 [rohan_ui + rohan_api] — Contract + thin persistence (no AI). _Do this first;
  engine-agnostic._** Promote `run_state` from `Record<string, unknown>` to the exported
  **`AcquisitionRunState`** interface (Appendix E), shared by rohan_ui and mirrored in rohan_api
  with optional shape validation. Wire the wizard onto real state with **zero generation**:
  landing → `createMission` (map UI `manual→drive`; persisted `mode ∈ {drive,auto}`) → navigate
  by `mission_id`; build out `ApMissionWorkspaceComponent` as the wizard+chat host; hydrate the
  five wizard signals from `GET …/missions/:id/state`; persist on each `nextAction` via
  `PATCH …/state` (replace every `of(undefined)`); handle `pathwayCommitted` vs auto-commit and
  `AssemblyCard` vs durable `Artifact` (hydrate terminal card states so animation is suppressed).
  Coordinate with in-flight UI PRs **#2110/#2112** to avoid type churn. **Acceptance:** create a
  mission, fill steps, reload — state persists; cross-user 404s hold; no mock is read for state.
  *(Adopted from Alex's Stage 0 — it de-risks the FE rails before any engine work and is the same
  regardless of how generation runs. It precedes and feeds F5's hydration-of-generated-output.)*
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
| **X — Agentic chat + Auto-Run + Watcher** *(from Alex's Stage 4 + Auto-Run)* | `mcp_server/tools/procurement.py` (run_state read/mutate + generation-trigger tools that fire the same `arc_acquisition_*` DAGs); a chaining **Auto-Run** DAG over all stages | bind AP MCP tools (`OneringMcpService.getToolsForUser` + ReAct agent); `POST …/missions/:id/watcher`; per-tool `@Permissions()` scopes | AP-tuned chat prompt branch; Watcher gating stays client-side; Auto-Run progress via run polling | AP system-prompt port + per-tool prompts |

Each per-step workstream stacks its own `phase-meta` blocks exactly like the slice's
`S1`(engine pipeline) → `S2`(DAG) → `S3/S4`(enums/DB, mostly F-covered after the first) →
`S5`(trigger) → `S6`(materializer) → `S7`(FE) → `S8`(CI). After R lands, F2/F4/F5 are
shared, so P/K/Z are lighter on the plumbing and heavier on domain content.

### Operating modes (Drive · Auto-Run · Watcher)

Three modes, ported from Alex's doc and mapped onto ONERING:

- **Drive (v1, all of F0–Finalize).** Per-stage, human-in-the-loop: each wizard step triggers
  exactly one stage's DAG (`{phase}` → one `arc_acquisition_*` run), materializes, and stops for
  review/edit. The default through every per-step workstream above.
- **Auto-Run (Workstream X).** Chains all stages unattended. ONERING-native: a single
  **`arc_acquisition_autorun` DAG** (or a parent DAG sequencing the per-stage step factories)
  runs record→pathway→artifacts→findings→ledger with checkpointing; rohan_api persists-then-
  triggers with deterministic run-ids + in-flight short-circuit (the Growth Engine pattern),
  polls while RUNNING, and materializes each stage's `run_state` key as it completes; surfaced to
  the UI via the existing run-polling path. *(This is exactly what ONERING's Airflow already does
  for proposals — Auto-Run is markedly cheaper under "ONERING for everything" than it would have
  been in-process.)*
- **Watcher (Workstream X).** A proactive read-only assistant turn: `POST …/missions/:id/watcher`
  (`{event, context}`) → ≤2 sentences, no mutations, ≤1 read-only tool, "empty reply is valid."
  The **gating policy** (enabled toggle, 60s cooldown buckets, 8/session cap,
  no-interrupt-during-phase, busy-drop with single-slot replay for high-severity dismissals,
  reset on new mission) stays **client-side** in rohan_ui and decides *whether* to POST.

**Mode vocabulary (locked):** the API/contract is **`mode ∈ {drive, auto}`** only; map UI
`manual→drive` at `createMission` (the UI composer says `manual|auto`; the persisted enum is
`drive|auto`, renamed in PRCR-1650 without migrating the enum). Full stage-name drift table in
Appendix F.

**Single front door (optional, recommended).** The per-step trigger endpoints can sit behind one
canonical **`POST …/missions/:id/generate {phase, mode}`** facade that routes `phase` to the
right `arc_acquisition_*` DAG and returns a run handle the FE polls. This gives Alex's
"written-once, never-forked" generation path: the **wizard buttons and the chat MCP tools call
the same endpoint** — neither re-implements generation. Adopt it as the public surface once ≥2
stages exist; the slice (S5/S10) may ship per-step endpoints first and converge them.

### Workstream X — agentic chat + MCP control plane

The baseline AP chat (Answer Engine V2, `ap-chat.controller.ts`) is shipped and stays the RAG
front door. Workstream X makes Rohan *act*, reusing ONERING's `mcp_server` — the natural home now
that everything runs on ONERING:

- **`ONERING/mcp_server/tools/procurement.py`** exposes the prototype's run_state read/mutate tools
  and **generation triggers that fire the same `arc_acquisition_*` DAGs the wizard buttons do** —
  one generation path, two front doors (button + chat), never forked. Register in `server.py`; add
  to `DEFAULT_ONERING_MCP_CHAT_TOOL_ALLOWLIST` (watch the ≤120/128-tool cap).
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

0. **F0 — no-AI persistence foundation.** Engine-agnostic; lands first (can run in parallel with
   the engine-side S1/S2). Proves the FE rails (createMission, hydrate, persist-on-reload) before
   any generation, and ships the typed `AcquisitionRunState` contract everything else targets.
1. **Foundation + Requirements slice (R = S1–S8).** Single-threaded enough to keep small;
   proves the bridge, the materializer harness, and the FE hydration. **Gate the rest of the
   epic on this slice working in staging with the dev mock and one real DAG run.**
2. **Fan out P, K, Z in parallel** once F2/F4/F5 are shared. P and Z reuse the scoring and
   review engines (lighter engine work, heavier Stream E content); K is the heaviest (writer +
   templates) and should start earliest of the three.
3. **Finalize + prod-readiness convergence**, then per-org enablement behind the existing flag.
4. **Workstream X — agentic chat + Auto-Run + Watcher.** After the per-step DAGs exist (so the MCP
   tools have real DAGs to trigger and Auto-Run has stages to chain). Reuses the gen path built in
   1–3; net-new is the `mcp_server` tools, the chaining DAG, the Watcher endpoint, and the prompt port.

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

- `…/foundation` — F0–F6 (**F0 = no-AI persistence + `AcquisitionRunState` contract; do first**).
- `…/requirements` — the slice (S1–S8). **First generation slice; gates the rest.**
- `…/pathway-selection` — P phases (+ Stream E vehicle data ticket).
- `…/package-assembly` — K phases (+ Stream E templates ticket).
- `…/integrity-check` — Z phases (+ Stream E FAR-rules ticket).
- `…/finalize` — packaging/download.
- `…/chat-control-plane` — Workstream X (MCP tools, Auto-Run DAG, Watcher, prompt port). After per-step DAGs.
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

---

## Appendix E — full `AcquisitionRunState` interface (ported from Alex's design doc)

The single shared contract for the opaque `run_state` blob. Promote this to rohan_ui
`types/acquisition-pathways.types.ts` (replacing the `Record<string, unknown>` alias) and mirror
it in rohan_api. **Every per-step materializer must write keys whose shapes deserialize 1:1 into
the five wizard signals** — this is the schema the `ui_projection_*.json` artifacts and the
materializers (F4 + each workstream's S6-equivalent) target.

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
  recordNotes?: string;                              // user-typed; not generated

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
UI-side.

| Phase (generate / DAG) | `run_state` key | Persisted stage cursor | Wizard URL slug | ONERING DAG |
|---|---|---|---|---|
| `record` | `canonicalRecord` (+`recordNotes`) | `record` | `requirements-record` | `arc_acquisition_requirements` |
| `pathway` | `pathways`, `selectedPathway`, `pathwayCommitted` | `pathways` | `pathway-selection` | `arc_acquisition_pathways` |
| `artifacts` | `scheduledArtifacts` (+`artifacts`,`documents`) | `interview` | `package-assembly` | `arc_acquisition_package` |
| `findings` | `findings` | `integrity` | `integrity-check` | `arc_acquisition_integrity` |
| `ledger` | `ledger` | `export` | `finalize-package` | (Finalize; reuses K render output) |

Mode enum: `mode ∈ {drive, auto}` (map UI `manual→drive`).

## Appendix G — 38 prototype tools → production homes (ported + re-homed for ONERING)

The prototype's 38 client-side tools (`ua-acquisition-pathways/proxy/src/tools/*.js`), mapped to
production. **Homes:** `client-only-drop` ×4 · `run_state-rw` ×24 (reads + simple writes +
lifecycle) · `arc-dag-generator` ×8 (heavy LLM generation = the `arc_acquisition_*` DAGs, exposed
as MCP tools in **Workstream X**) · `rohan_api-retrieval` ×2.

> Under "ONERING for everything," the 8 generators are **not** in-process — each is (or maps onto)
> an `arc_acquisition_*` DAG. The MCP tools in Workstream X are thin triggers/readers that call the
> same DAG path the wizard buttons use; they do not re-implement generation.

| Tool | Home | Notes |
|---|---|---|
| `navigate`, `set_mode`, `append_to_draft`, `load_sample_mission` | client-only-drop | UI-only; forbidden server-side (`set_mode` tracks mode as a `run_state` field) |
| `get_mission_state`, `set_mission_name`, `set_mission_statement`, `add_attached_files` | run_state-rw | mission scalars + attachment refs |
| `update_crr_field`, `add_crr_field`, `remove_crr_field`, `clear_canonical_record` | run_state-rw | CRR edits (flip `tag→'user'`) |
| `select_pathway`, `compare_pathways`, `set_recommended_pathway`, `simulate_pathway_change` | run_state-rw | tier select + read/derive (no LLM); use `dimensions` |
| `start_document`, `remove_document`, `get_document`, `list_documents`, `get_document_sections`, `update_document_section` | run_state-rw | document CRUD/sections |
| `apply_finding`, `dismiss_finding` (reason mandatory), `explain_finding` | run_state-rw | finding triage (`apply`→`edited:true`) |
| `intake_complete`, `complete_auto_run`, `pause_auto_run` | run_state-rw | lifecycle signals → Auto-Run state machine (Workstream X); the latter two were retired in the prototype |
| `populate_canonical_record`, `populate_pathways`, `populate_artifacts`, `populate_findings`, `populate_ledger` | arc-dag-generator | the five stage DAGs (`{phase}`); findings DAG reproduces `mergeReplace` |
| `complete_document`, `edit_document`, `generate_decision_memo` | arc-dag-generator | HTML prose generation (memo uses a two-call grounding pattern: rohan_api read + ONERING synth) |
| `search_library`, `open_source_doc` | rohan_api-retrieval | ONERING retrieval layer (`PgVectorStore` / library) |
