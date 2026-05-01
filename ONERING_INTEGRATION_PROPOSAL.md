# ONERING as Engine: Integration Proposal for Acquisition Center, Answer Engine v2, and Compliance

## Executive Summary

All three modules independently reinvent capabilities ONERING already has — document ingestion, KM-style retrieval, requirement extraction, structured generation. **Compliance has the strongest structural overlap and has not yet launched**, making it the natural first integration target. Answer Engine v2 (already in production) and Acquisition Center are deferred several months while Compliance proves the engine pattern.

**There is already a working ONERING integration in the codebase.** rohan_api has a `/onering/*` namespace (~8,300 lines across seven controllers and eleven services as of this revision) that triggers Apache Airflow DAGs in the ONERING repo. Proposal launch (`arc_launch_proposal`) and opportunity discovery DAGs are implemented end-to-end and running in dev/staging environments — **the ONERING Airflow stack has not yet been deployed to production.** Compliance Phase 1 is therefore not just a new DAG; it is also the first production cutover of the ONERING engine. The infrastructure includes a Helm chart for AKS deployment (with `values-prod.yaml` defined but not yet rolled out), hot-reload local Docker Compose, and reusable services (`OneringPipelineService`, `OneringArtifactService`, `OneringExceptionFilter`) plus a run-metadata table (`or_pipeline_runs`). **Phase 1 should reuse this stack rather than build a parallel rohan-python-api wrapper, but should treat first-prod-deployment as a real risk surface, not an extension of an existing prod path.**

**Recommended sequence:** ship a thin ONERING-driven Compliance launch by adding a new `arc_compliance_review` Airflow DAG and extending the existing rohan_api `/onering/*` namespace (Phase 1: **plan for 6–8 calendar weeks; 3–5 weeks is achievable only under favorable conditions, see "Phase 1 timeline reality" below**). Expand Compliance scope post-launch (Phase 2: additional extraction tabs, response-analysis DAG, XLSX export). Migrate Answer Engine v2 (Phase 3) and Acquisition Center (Phase 4) as later phases — Phase 3 is where the rohan-python-api wrapper layer makes sense for fast inline operations (KM retrieval, single-section writes) that don't fit Airflow's batch model.

---

## Module Snapshots

### Acquisition Center (Procurement Writer)

Multi-step procurement drafting — Market Research Assistant (MRA), RFI Assistant, Requirements Discovery, Document Library, Template Generator, Toolkits. Backend at `rohan_api/src/procurement-writer/` is a 1,700-line service with streaming SSE controllers and a `wizard_state` JSONB blob for multi-step state. AI pattern is consistent across assistants: fetch prompt by feature flag → enrich with `addDocContent()` (manual document-summary append) and `addVectorDBResults()` (pgvector query for 10 paragraphs + 10 tables) → `handleCompletion()` for SSE streaming.

### Answer Engine v2

Threaded conversational Q&A with KM retrieval, deep research (o3), file-context uploads, streaming responses, aggregates, and summaries. Backend at `rohan_api/src/answer-engine-v2/` is a ~3,500-line service with advisory locks, `Question`/`Answer`/`Thread`/`Aggregate`/`Summary` entities, and heavy use of `AgentWorkflowService.getKmWorkflow()` (LangChain-based LLM-as-retriever, currently at `answer-engine.service.ts:1575`). File parsing for upload context goes through rohan-python-api; specific symbol names should be re-verified at implementation time since the surface continues to evolve. The service routes follow-ups through one of several KM/research paths before streaming.

### Compliance

Source-document compliance item extraction → manual review → response-document upload → automated cross-check → reviewer adjudication. Backend at `rohan_api/src/compliance/` (~2,400-line `compliance.service.ts`) has entities `ComplianceProject`, `ComplianceItem`, `ComplianceCheck`, `ComplianceItemEvidence`, `ComplianceDocument`, `ComplianceResponse`. **Auto-extraction is already async, not inline:** the Compliance controller enqueues an `AutoTagRequest` to the `rohan-rfp-queue` Service Bus queue; rohan-python-api processes it (GPT-5.2 extracts shall-statements with line offsets); completion is published to the `rohan-rfp-topic` topic and consumed by `compliance.listener.ts` via `@OnEvent('tagging.auto-tag-complete')`, which creates `ComplianceItem` rows. The migration in Phase 1 is therefore **swapping one async transport (Service Bus + Python service) for another (Airflow + ONERING DAG)** — not converting an inline call to async. Risk profile (latency, partial failure, retry, document-deletion-mid-run) is similar in shape but different in operational characteristics.

**Recent active work (in flight or just merged):**

- **rohan_api side:** PRCR-1562 (`ComplianceReconciliationService` — retry/reconciliation pattern Phase 1 should follow), PRCR-1570 (sequential line-item numbering with pessimistic locking), PRCR-1552/1548/1558 (MinIO path alignment + org_id prefixing — directly relevant to Phase 1 tenancy choices).
- **rohan_ui side:** PRCR-1517/1519/1544 (inline tag UI: bidirectional tag↔item selection, dot-styled tags for single-tag-type contexts, delete tooltip).

**Not yet in production** — launch target is approximately a few weeks out, no specific feature commitments, sales wants to start selling the module as soon as it ships.

---

## ONERING Capability Map

| ONERING capability                                                                  | Compliance                                           | AE v2                                     | Acquisition Center                              |
| ----------------------------------------------------------------------------------- | ---------------------------------------------------- | ----------------------------------------- | ----------------------------------------------- |
| Document ingestion (Docling + OCR + canonical markdown + line numbering + chunking) | ✅ Replace Service-Bus → rohan-python-api auto-tag path | ✅ Replace `extract-file-content`         | ✅ Replace doc-summary-only flow                |
| `pipelines.requirements` (shall/must extraction with line evidence)                 | ✅ Direct replacement for compliance item extraction | —                                         | ✅ Replaces Requirements Discovery              |
| `pipelines.structure` / `evaluation` / `instructions` / `attachments` / `metadata`  | ✅ Net-new tabs/views                                | —                                         | ✅ Could power Template Generator               |
| `pipelines.compliance_matrix` (six-tab XLSX + JSON)                                 | ✅ Direct replacement; gives free export             | —                                         | —                                               |
| KM retrieval (LLM-as-retriever with query plans)                                    | Improves response analysis                           | ✅ Direct replacement for `getKmWorkflow` | ✅ Replace `addVectorDBResults`                 |
| Section writer (draft → critique → revise + consistency ledger)                     | Optional: auto-generate compliance commentary        | ✅ Aggregates / summaries quality boost   | ✅ Replace one-shot LLM calls                   |
| GOLD library                                                                        | —                                                    | Opt-in past-proposal answer source        | ✅ Vendor / template suggestions from past wins |
| Render layer (DOCX/PPTX/XLSX with anchor amendments)                                | ✅ Compliance matrix export                          | ✅ Aggregate / answer export              | ✅ Replace DocxExportService                    |
| DAG orchestrator (resumable, parallel)                                              | Wrap per-project runs                                | Resumable deep-research                   | ✅ Replaces `wizard_state` JSONB                |
| Deep research (o3 + web search, structured)                                         | —                                                    | ✅ Replace direct o3 calls                | ✅ Replace MRA deep research                    |
| SAM.gov discovery                                                                   | —                                                    | —                                         | ✅ Connect to existing `opp_id` field           |

---

## Architecture Target

```
┌─────────────────────────────────────────────────────────────┐
│ rohan_ui (Angular)                                          │
│   compliance/   answer-engine-v2/   acquisition-center/     │
└─────────────────┬───────────────────────────────────────────┘
                  │ REST + SSE
┌─────────────────▼───────────────────────────────────────────┐
│ rohan_api (NestJS) — thin orchestration shells              │
│   Owns: projects, threads, items, review state, RBAC        │
│   /onering/* namespace already exists                       │
│   or_pipeline_runs table tracks all ONERING runs            │
└────────┬─────────────────────────────────┬──────────────────┘
         │ HTTP (Airflow REST API)         │ HTTP (rfp-python-server)
         │ — used today for                │ — Phase 3+ for fast
         │   proposal launch, discovery,   │   inline ops only
         │   compliance review (Phase 1)   │   (KM retrieve, single
         │                                 │    section write)
┌────────▼────────────────┐    ┌───────────▼─────────────────┐
│ Airflow 3.x (AKS)       │    │ rohan-python-api (FastAPI)  │
│ DAGs in ONERING repo    │    │ Org-stateless wrapper       │
│ KubernetesExecutor      │    │ Reuses RfpPythonServer      │
│ Per-task pod resources  │    │   service contract          │
│ Helm: helm/onering-     │    │ Phase 3+ work               │
│   airflow/              │    │                             │
└────────┬────────────────┘    └───────────┬─────────────────┘
         │                                 │
         └────────────────┬────────────────┘
                          │ Python imports
┌─────────────────────────▼───────────────────────────────────┐
│ ONERING (submodule) — engine                                │
│   arc_agent_writer/ — CLI + library                         │
│   airflow/dags/ — 7 DAGs (BashOperator wrapping CLI)        │
│   helm/onering-airflow/ — AKS deployment                    │
│   Step factories: built-in DAG + module-specific DAGs       │
│     (compliance_review:build_steps for Phase 1,             │
│      mra_assistant:build_steps for Phase 4, etc.)           │
└─────────────────────────────────────────────────────────────┘
```

**Two transport paths, each optimized for its workload:**

- **Airflow** for long async batch work (full extractions, proposal generation, response analysis). Implemented and exercised in lower environments today; Compliance Phase 1 uses this path and will be its first prod cutover.
- **rohan-python-api** for fast inline operations (KM retrieval, single-section writes, single-file ingestion). Doesn't exist yet; Phase 3 work for AE v2.

ONERING already supports `--steps-factory mod:fn`. Each module's custom DAG ships as a Python file in `airflow/dags/` that wraps CLI commands via BashOperator.

---

## Existing Infrastructure to Build On

The Phase 1 plan reuses substantial infrastructure already in place. This section is the inventory.

### `/onering/*` namespace in rohan_api

`rohan_api/src/onering/` (currently ~8,300 lines and growing):

- **7 controllers** — `onering-auth`, `onering-chat`, `onering-opportunities`, `onering-onboarding`, `onering-portals`, `onering-runs`, `onering-mission-control`. All guarded by `@UseGuards(AuthGuard('jwt'), FeatureGuard, PermissionsGuard)` + `@Features('ONERING')` + `@Permissions('one-ring')`, with `@UseFilters(OneringExceptionFilter)`.
- **11 services** — including the ones Compliance Phase 1 will reuse:
  - `OneringPipelineService` (`onering-pipeline.service.ts`) — run lifecycle, Airflow trigger, status polling.
  - `OneringAirflowClientService` (`onering-airflow-client.service.ts`) — REST client for Airflow 3.x, auth via JWT from Key Vault.
  - `OneringArtifactService` — list/presign run artifacts from MinIO.
  - `OneringOrgLookupService` — JWT `org_id` → `Organization` entity → `organization_id` (FK).
  - `OneringExceptionFilter` — centralized error mapping (`OneringAirflowError` → 502, etc.).
  - Plus `OneringMissionControlService`, `OneringMinioService`, `OneringAuthService`, `OneringChatService`, `OneringOpportunityService`, `OneringOnboardingService`, `OneringPortalService`.
- **4 entities** — `OrOpportunity`, `OrPipelineRun`, `OrPortalConnection`, `OrUploadedFile`. **`or_pipeline_runs` is the run-metadata table Phase 1 should reuse** — don't invent a parallel one. Columns: `organization_id` (FK), `arc_run_id`, `airflow_dag_id`, `airflow_dag_run_id`, `status`, `progress_pct`, `current_step`, `total_steps`, `completed_steps`.
- **Enum types** — `OneringDagId` (currently `LAUNCH_PROPOSAL`, `DISCOVERY_DAILY` — Phase 1 adds `COMPLIANCE_REVIEW`), `RunStatus`, `RunType` (currently `PROPOSAL`, `DISCOVERY`, `RESUME` — Phase 1 adds `COMPLIANCE_REVIEW`).

### Airflow setup in ONERING repo

`ONERING/airflow/`:

- **7 DAG files** in `airflow/dags/`:
  - `arc_agent_writer_dag.py` — full pipeline. `airflow/CLAUDE.md` documents 26 steps; `STEP_GRAPH` in the file currently lists ~28 (deltas are the recently-added `pipelines.response_guidance` and `pipelines.compliance_matrix` tasks). Confirm exact count at implementation time. Selective execution is possible via `--steps-factory` or `--start-at`/`--stop-after`, **but the dependency chain matters** — see "Phase 1 thin-scope reality" below.
  - `arc_agent_writer_resume_dag.py` — resume/re-run DAG.
  - `arc_launch_proposal_dag.py` — two-phase: stage opportunity → trigger `arc_agent_writer`.
  - `arc_gold_pipeline_dag.py`, `arc_global_pool_sync_dag.py`, `arc_tenant_scoring_dag.py`, `arc_storage_smoke_dag.py`.
- **Local dev:** `airflow/docker-compose.yaml` + `Dockerfile`. Run `make up-airflow` (or equivalent `docker compose --profile airflow up`) and Airflow UI is at `localhost:8080` (admin/admin). DAG files and ARC source code are mounted into the container with hot-reload — no rebuild for code changes.
- **AKS deployment:** `helm/onering-airflow/` Helm chart with base `values.yaml` plus `values-dev.yaml`, `values-staging.yaml`, `values-prod.yaml` (and a parent-level `helm/values-aks.yaml`). KubernetesExecutor with per-task pod resource profiles (`default`, `ingestion`, `llm_extraction` 8–16Gi on Spot pool, `llm_aggregation`). DAG sync from GitHub via git-sync (no redeploy on DAG changes — see "Engine version contract" below for the cost of this).
- **Pools:** `default_pool` (implicit), `llm_extraction_pool` (**2 slots, system-wide**), `llm_aggregation_pool` (**1 slot, system-wide**). Created during `airflow-init`. **These slot counts are a launch-time concern: today they are shared across `arc_launch_proposal` + discovery DAGs; Compliance becomes a third concurrent consumer.** See "Pool capacity plan" below.
- **DAG conventions:** BashOperator wrapping `python -m arc_agent_writer.cli`. `airflow.sdk` DAG import (3.x style). Inputs via `dag_run.conf`. Run ID flows between tasks via XCom.

**Recent commits show the team is actively converging on the patterns this proposal recommends:** "retire duplicate DAGs + route launch_proposal through arc_launch_proposal", "feat: route tenant scoring + launch_proposal polling through Airflow", "Phase 1: opportunities → StorageBackend migration + local Airflow fixes". The proposal's recommendation isn't fighting the team's direction — it's lining up with it.

### CLI surface

`arc_agent_writer/cli.py` is currently ~17,250 lines and growing rapidly — the engine is evolving fast, and that pace is itself a Phase 1 risk surface (see "Engine version contract" below). The canonical step factory `build_builtin_steps()` is at line 13386. The step name `pipelines.ui_projection_requirements` exists in the builtin graph (cli.py:13561) and is a node in `arc_agent_writer_dag.py`. Pipeline subdirectories `response_guidance/` and `attachment_requirement_traceability/` exist alongside the core six (metadata, instructions, attachments_forms, structure, evaluation, requirements).

**Phase 1 thin-scope reality:** the dependency chain in `arc_agent_writer_dag.py:107-145` makes `pipelines.requirements` transitively depend on `ingestion.chunk_plan` → `pipelines.metadata` → `pipelines.ui_projection` → `pipelines.rfi_fast_path` → `pipelines.instructions` (+ `pipelines.attachments`) → `pipelines.ui_projection_instructions` → `pipelines.structure` → `pipelines.ui_projection_structure` → `pipelines.evaluation` → `pipelines.ui_projection_evaluation` → `pipelines.requirements`. **Stopping after `pipelines.ui_projection_requirements` therefore still executes ~all six extraction pipelines plus ~10 ingestion steps.** This is materially heavier than a naive "ingestion + requirements only" reading would suggest. Two options:

1. **Accept the cost.** Run the full extraction graph; bonus is that Phase 2's additional extraction tabs (structure, evaluation, instructions, attachments, metadata) are already produced — Phase 2 becomes pure UI work. Trade-off: 5–10× cost per Compliance run vs the current Service-Bus-based single-extraction path, plus 10–30 min wall-clock through KubernetesExecutor pod-spinup-per-task.
2. **Build a true thin step factory.** Add `compliance_review:build_steps` in `arc_agent_writer/cli.py` that produces ingestion → chunk_plan → `pipelines.requirements` → `pipelines.ui_projection_requirements` only, bypassing the metadata-derived deps. Cost: ~1 engineer-week of ONERING-side work plus validation that `requirements` actually runs without `metadata`/`structure`/`evaluation` outputs (it currently consumes their UI projections). May require small changes inside the requirements pipeline.

**Recommendation:** start the week-1 milestone with option (1) to derisk timeline, but make the cost/latency measurement spike (also week 1) the trigger for switching to option (2) before launch if the numbers don't fit. See "Phase 1 milestones."

### What this means for Phase 1

Adding Compliance to this stack is mostly an **extension exercise**, not a build-from-scratch:

- **Reuse:** `OneringPipelineService`, `OneringAirflowClientService`, `OneringArtifactService`, `OneringExceptionFilter`, `or_pipeline_runs` table, `OneringOrgLookupService`, the Helm chart, the local dev story.
- **Extend:** add `COMPLIANCE_REVIEW` to `OneringDagId` and `RunType` enums; add a config interface (`ComplianceReviewConf`); add a service method (`triggerComplianceReview`) that mirrors `launchProposal`.
- **Add:** new DAG file `airflow/dags/arc_compliance_review_dag.py` in the ONERING repo; new endpoints on the existing Compliance controller; column updates on `compliance_items` to point at ONERING run artifacts.

The Phase 1 work is concentrated in two places — both already well-trodden territory.

---

## Tenancy Model

Phase 1 tenancy work isn't greenfield. The codebase has established patterns that should be followed rather than replaced.

### Existing patterns

- **Identity.** JWT carries `org_id`. `JwtStrategy` (`rohan_api/src/auth/jwt.strategy.ts:112-185`) validates and attaches it to `request.user`. The `@GetUser()` decorator extracts it; services pass it explicitly through method signatures — no async-local storage anywhere.
- **Authorization.** `PermissionsGuard` (`rohan_api/src/auth/permissions/permissions.guard.ts`) does User → Group → Role → Permission traversal plus resource-hierarchy matching against `categories_v2` JSON trees stored on groups. The `categories_v2` model — `{ item, children[] }` trees where parent access implies child access (`utils/categories/type/category.type.ts:21-39`) — is the codebase's existing hierarchical access-control mechanism.
- **Service-layer.** No shared base class. Services manually scope TypeORM queries by `org_id` (e.g., AE v2 `threadRepository.findOne({ where: { thread_id, org_id, user_id } })`). Brittle but defended in depth by the guard layer rejecting unauthorized requests upstream.
- **MinIO uses two distinct path conventions in the existing ONERING integration:**
  - **Tenant-scoped data** (org pipeline indexes, opportunity records): `tenants/{org.organization_id}/pipeline/{suffix}` — explicit `org_id` segment because the data conceptually belongs to the org.
  - **Run-keyed artifacts** (per-run outputs from any DAG): `AGENT_RUNS/{run_id}/...` — no org segment; `or_pipeline_runs.organization_id` is the access-control source. Compliance follows this convention for Phase 1 outputs.
  - The other Compliance-style pattern (`Compliance/PROJECT_p1234/...`) is a third precedent for project-scoped data; isolation lives at the query layer because only the project owner can resolve `projectId`.
- **Service Bus.** Messages carry `org_id` explicitly in the envelope (`AutoTagRequestMessage.org_id`). Full configs (prompts, tag definitions) are baked into the message; the Python side never queries the customer database. Completion messages echo `org_id` back as both a body field and an Azure Service Bus application property so subscription SQL filters can route by org.
- **Airflow.** `dag_run.conf` carries `org_id`, `user_id`, and run-specific parameters. DAG tasks read it via `{{ dag_run.conf.get('org_id', '') }}` and export it as `ONERING_DEV_ORG_ID` for the CLI. `arc_launch_proposal_dag.py:58-72` is the reference pattern. `or_pipeline_runs.organization_id` (FK to Organization) is set when `OneringPipelineService` creates the run record — that's the access-control source for downstream artifact retrieval.
- **Vector DB.** `VectorDbPostgresService` accepts `org_id` as an explicit method parameter and passes it through. Implicit scoping via document/project ownership.
- **Feature flags.** Two layers — paid org features in an Azure JSON blob cached 5 min (`OrganizationFeaturesService`) and global DB flags (`FeatureFlagsService`). The JSON blob is the per-org entitlement source.

### Conventions for the Compliance integration

1. **Reuse `or_pipeline_runs` for run tracking.** Don't create a parallel `onering_runs` table. Add `RunType.COMPLIANCE_REVIEW` to the enum and that's it. The existing `organization_id` FK plus status/progress columns cover everything needed.
2. **Path conventions.** Compliance run artifacts go under `AGENT_RUNS/{arc_run_id}/...` (the run-keyed pattern, matching how proposals work). Compliance source documents that are uploaded *before* a run can stay under `Compliance/PROJECT_{id}/source-documents/...` (the existing project-scoped pattern), with the run reading them as inputs.
3. **`dag_run.conf` envelope.** When `OneringPipelineService` triggers `arc_compliance_review`, it passes `{ org_id, user_id, project_id, document_ids, expected_run_id }` in `dag_run.conf`. The DAG reads them via Jinja templating in BashOperator commands and exports them as env vars to the CLI. Mirrors `arc_launch_proposal_dag.py` exactly.
4. **Authentication stays in NestJS.** The Airflow DAG trusts that the trigger came from an authenticated rohan_api request. Airflow itself authenticates the rohan_api caller via Airflow 3.x's `POST /auth/token` endpoint, which exchanges basic credentials for a short-lived JWT bearer token (see `airflow/CLAUDE.md` for the exact request shape). The basic credentials (`ONERING_AIRFLOW_USERNAME` / `ONERING_AIRFLOW_PASSWORD`) live in Azure Key Vault and are rotated on the standard Key Vault rotation schedule. `OneringAirflowClientService` handles the token exchange + refresh.
5. **Categories integration where it makes sense.** When ONERING extracts content that the Compliance UI surfaces (requirements, structure, etc.), tag those records with the appropriate `categories_v2` value if Compliance uses categories for its resources.
6. **Explicit plumbing, not magic.** Pass `org_id` through method signatures rather than introducing async-local storage. Matches every other module.

### ONERING-specific tenancy questions (deferred to Phase 3)

These don't affect Phase 1 because Compliance doesn't use GOLD or KM. They become relevant in Phase 3 (AE v2):

- **GOLD library partitioning.** No existing pattern for "shared corpus filtered per-org." Three options: per-org folders (`ARC_GOLD_DIR=/data/gold/{org_id}/`), shared GOLD with `categories_v2` tags, or hybrid global + per-org private. Per-org folders is the simplest placeholder; revisit before Phase 3.
- **KM corpus partitioning.** Same shape, same options, same recommendation.
- **Workspace partitioning.** ONERING uses `ARC_WORKSPACE_ROOT` for run output. For Phase 1, a single shared root keyed only by `arc_run_id` is fine — `or_pipeline_runs.organization_id` is the access-control source.

---

## Phase 1 Operational Decisions

Several operational questions ("polling vs Service Bus completion," "what if pool slots saturate," "what if a doc is deleted mid-run") need explicit answers before implementation. They are pinned down here so the team can ship Phase 1 without re-litigating them.

### DAG → rohan_api completion mechanism

The choice is between polling and a Service Bus completion event from Airflow:

- **Phase 1 default: polling.** `OneringPipelineService` already has a `refreshRunStatus()` pattern used by Proposal Launch and Discovery. Compliance reuses it: a NestJS scheduled job polls Airflow's `GET /api/v2/dags/{dag_id}/dagRuns/{dag_run_id}` until terminal state, then reads `ui_projection_requirements.json` from MinIO via `OneringArtifactService` and creates `compliance_items` rows in a single DB transaction. **Reuses the existing reconciliation service (PRCR-1562)** for retry/repair on transient failure.
- **Phase 2 upgrade path: completion publish from CLI.** When Phase 2 lands the response-analysis DAG, replace polling with a Service Bus publish from the final ONERING CLI step (similar to how rohan-python-api currently publishes `tagging.auto-tag-complete`). The Compliance listener already understands a completion-event shape; the work is one new event type and one new handler. Airflow does not natively emit Service Bus, so this lives in the CLI step, not in Airflow itself.
- **Webhook callback rejected.** Inbound webhooks to rohan_api would require new auth + idempotency + ingress rules with no UX benefit over polling.

**Idempotency.** `dag_run_id` is unique per Airflow trigger; rohan_api stores it on `or_pipeline_runs` and uses it as the dedupe key when materializing `compliance_items`. A second poll that observes the same successful run is a no-op. A retry (new `dag_run_id`) replaces items associated with the previous `arc_run_id` for the same `(project_id, document_id)` tuple — see "Multi-document mapping" below.

### Pool capacity plan

`llm_extraction_pool` (2 slots) and `llm_aggregation_pool` (1 slot) are shared by every DAG. Phase 1 adds Compliance as a third concurrent consumer alongside `arc_launch_proposal` and the discovery DAGs (both running today in lower environments and headed to prod alongside Compliance).

- **Pre-launch:** raise `llm_extraction_pool` to 4 slots and `llm_aggregation_pool` to 2 slots in the Helm chart's `airflow-init` job. Validate Spot pool capacity supports the additional pods; the `llm_extraction` profile is 8–16Gi per pod.
- **Customer-latency carve-out (optional):** if Compliance latency is a launch-blocker, add a dedicated `compliance_pool` (2 slots) used only by `arc_compliance_review` step nodes. Trade-off: per-DAG pool partitioning prevents starvation but caps Compliance throughput independent of overall capacity. Defer unless the week-1 measurement spike shows contention.
- **Monitoring:** Airflow exposes pool slot utilization via the standard Airflow metrics endpoint. Add a Grafana panel for slot saturation before launch.

### Multi-document mapping

`ComplianceProject` has many `ComplianceDocument`s; `ComplianceItem`s are conceptually per-document evidence. ONERING produces one `ui_projection_requirements.json` per **run**, with each requirement carrying source-document anchors (file id + line range).

- **One DAG run per project, ingesting all source documents in a single chunk plan.** The artifact carries per-requirement `source_document_id` + line offsets. `OneringPipelineService` materializes items grouped by `source_document_id`, populating `compliance_items.compliance_document_id` from the ONERING-side anchor.
- **Re-run semantics.** A new run for the same project supersedes the previous run's items: items where `arc_run_id != current_run_id` are soft-deleted (or marked `superseded`) in the same transaction that inserts the new set, preserving any reviewer state (`status`, `reviewed_by`, `userNotes`) by stable-key match (`source_document_id` + `line_start` + canonical statement hash). If no stable match exists, the prior reviewer state is archived for audit but not propagated.
- **Single-document re-extraction (retry path).** Already used today for failed-document retries (compliance.controller.ts:620). Phase 1 retains this affordance: a single-document retry triggers a scoped DAG run with `dag_run.conf.document_ids = [<one>]` and writes only the items for that document, leaving items from other documents untouched.

### PRCR-1570 vs ONERING numbering

PRCR-1570 introduced sequential per-project line-item numbering with pessimistic locking in rohan_api. ONERING produces its own requirement IDs (per-run, with internal stable hashes). The conflict resolution:

- **rohan_api owns the user-visible sequential number.** ONERING's IDs are stored as `compliance_items.arc_requirement_id` (engine-side stable identifier, opaque to UI). The rohan_api-assigned sequential number remains the column the UI renders.
- **PRCR-1570's pessimistic lock continues to gate insertion** on item materialization from the DAG output. The numbering pass runs inside the same transaction as the insert.
- **On re-run with item carry-over:** retained items keep their original sequential numbers; new items get the next available numbers in the per-project sequence. This preserves user familiarity with item numbers across re-extractions.

### Document deletion during a run

Existing listener (`compliance.listener.ts:417`) skips item creation if a source document was deleted while the auto-tag job was running. The Airflow path needs equivalent semantics:

- `OneringPipelineService` re-checks `ComplianceDocument` rows for the project's `document_ids` after the DAG completes and before materializing items. Items whose source document has been deleted are dropped with an audit log entry.
- ONERING-side cancellation is best-effort: if a user deletes all source documents while a DAG is running, rohan_api fires `OneringAirflowClientService.killDagRun(dag_run_id)`. The DAG's BashOperator steps already handle SIGTERM gracefully (per `ONERING/CLAUDE.md`), so kills are clean.

### Engine version contract

`cli.py` is growing rapidly (currently ~17K LOC, with major additions on a weekly cadence). Compliance Phase 1 takes a hard dep on `_step_pipelines_ui_projection_requirements` internals plus the JSON schema of `ui_projection_requirements.json`. To prevent silent breakage:

- **Pin the ONERING submodule in `rohan-python-api/backend/arc_agent_writer/` to a specific commit** for Phase 1, even though Phase 1's primary consumption path is Airflow git-sync (not the submodule). This gives Phase 3 a stable target.
- **Pin the Airflow git-sync ref to a tagged release of ONERING** (e.g., `onering-airflow/v1.x`) rather than `main`. Update the tag deliberately, with a smoke run of `arc_compliance_review` against the new tag in staging before promoting to prod.
- **Schema contract for `ui_projection_requirements.json`.** ONERING owns it today; freeze a v1 shape in `ONERING/specs/` and add a JSON Schema file. rohan_api's parser validates against it on load and raises a clear error on schema drift rather than silently corrupting items.
- **CI cross-check.** Add a CI job in rohan_api that fetches the pinned ONERING tag, runs the schema validator against a sample artifact in `ONERING/arc_agent_writer/tests/fixtures/`, and fails the build if the contract drifts.

Pinning is a small calendar-time tax (deliberate updates instead of ambient drift) and a large derisk for a customer-facing surface depending on a fast-evolving engine.

### Azure Government / `.us` endpoint feasibility

rohan_api's CLAUDE.md requires support for commercial OpenAI, Azure OpenAI, and Azure Government (`.us`) endpoints. Compliance Phase 1 assumes ONERING + Airflow run in the same Azure tenant as rohan_api. **Open questions for Gov customers:**

- Does the ONERING Airflow Helm chart deploy cleanly into a Gov AKS cluster? Image registries, KubernetesExecutor pod-spec, ingress patterns differ.
- Does ONERING's OpenAI client respect the `.us` endpoint switch? `ARC_LLM_MODE` and the LLM Config v2 spec mention model selection but not endpoint routing.
- Pgvector / MinIO / Service Bus all have Gov equivalents already in use by rohan_api; the new dependency is the Airflow + ONERING stack.

**Action:** add a Gov-feasibility spike to Phase 1 week 1 if any current customer or near-term sales prospect is on `.us`. If no Gov customer is in scope for the Compliance launch, document the limitation explicitly and gate the Compliance feature flag off for Gov orgs until Phase 2 addresses it.

### Observability and correlation IDs

Trace stitching across the new transport boundaries should be explicit, not implicit:

- `OneringPipelineService.triggerComplianceReview()` generates `arc_run_id` (UUID) and writes it to `or_pipeline_runs` before issuing the Airflow trigger. The same UUID is passed in `dag_run.conf.run_id` and becomes the run-keyed prefix in MinIO (`AGENT_RUNS/{arc_run_id}/...`).
- The rohan_api request log line at trigger time includes: `correlation_id` (HTTP request id), `org_id`, `project_id`, `arc_run_id`, `dag_run_id` (returned by Airflow), `airflow_dag_id`. Same fields tagged on every subsequent log line for that run via NestJS request-context async storage.
- ONERING CLI per-step artifact paths (`llm_calls/{step}/{prompt}/{call_id}/`) live under the same `arc_run_id` prefix; rohan_api can deep-link from the Compliance UI to the audit-trail browser for any extracted item.
- Add a Grafana board: per-run timing, slot wait time, per-step LLM cost, error rate by step name. Treat as launch-blocking dashboard, not a nice-to-have.

### CI test story for Airflow-dependent flows

rohan_api's `test:e2e:ci` currently spins Docker DBs but not Airflow. Two layers:

- **Unit + integration in rohan_api:** mock `OneringAirflowClientService` and `OneringArtifactService` (existing pattern — `.spec.ts` files for both already exist). Validate `triggerComplianceReview` happy path, retry, and item materialization from a fixture `ui_projection_requirements.json` checked into the repo.
- **End-to-end with real Airflow:** opt-in CI workflow (`test:e2e:airflow`) that runs `make up-airflow` + `npm run test:e2e:ci -- --grep compliance-airflow` on a slow-lane CI runner (nightly or PR-on-demand label). Catches DAG drift, schema drift, and pool/timeout regressions.
- **ONERING-side DAG test** mirroring `test_airflow_dag_llm_mode.py` validates step ordering and conf parsing in fast unit-test time.

### Local developer experience

`make up-airflow` is correct for the engineers actively building Compliance Phase 1, but onboarding every UI/feature engineer to a full Airflow stack is wasteful. Three tiers:

- **Default dev mode:** rohan_api detects the absence of `ONERING_AIRFLOW_BASE_URL` and uses an in-process mock that synchronously generates a fixture `ui_projection_requirements.json` and materializes items. UI engineers iterate on the Compliance UI without running Airflow.
- **Engine-integration mode:** `make up-airflow` for engineers actively working on the DAG, schema, or completion handler.
- **CI mode:** the opt-in `test:e2e:airflow` workflow above.

The fixture-driven mock should be checked into the repo and kept in sync via the schema contract above. This is ~1 engineer-week of work and removes a real adoption tax.

---

## Phased Strategy

### Phase 1 — Compliance Launch on ONERING via Airflow (target: 6–8 weeks, with hard fallback gates at weeks 1 and 2)

Compliance ships as a new Airflow DAG that follows the same pattern as `arc_launch_proposal`. The work splits across the ONERING repo (DAG + tests) and rohan_api (`/onering/*` extension + Compliance controller endpoints + UI wiring).

**ONERING repo work (`airflow/dags/`):**

1. **New DAG file** `airflow/dags/arc_compliance_review_dag.py`. Pattern: BashOperator wrapping `python -m arc_agent_writer.cli`. Mirrors the structure of `arc_launch_proposal_dag.py`. Inputs via `dag_run.conf`: `org_id`, `user_id`, `project_id`, `document_ids`, `expected_run_id`. Run ID propagated via XCom if multi-phase, or generated up front.
2. **Step-graph choice (decided in week 1).** Default to `--builtin-steps --stop-after pipelines.ui_projection_requirements`, accepting that the dep chain pulls in metadata + instructions + attachments + structure + evaluation + requirements (see "Phase 1 thin-scope reality"). If the week-1 cost/latency spike rules this out, ship a thin `compliance_review:build_steps` factory in `arc_agent_writer/cli.py` that bypasses metadata-derived deps. Pick before week 2 begins.
3. **DAG test** in `arc_agent_writer/tests/` mirroring `test_airflow_dag_llm_mode.py`. Validates step ordering and `dag_run.conf` parsing.
4. **JSON Schema for `ui_projection_requirements.json`** in `ONERING/specs/` plus a sample fixture in `arc_agent_writer/tests/fixtures/`. Used by the rohan_api validator and by the rohan_api dev mock.
5. **Helm chart update** (`helm/onering-airflow/`): bump `llm_extraction_pool` to ≥4 slots and `llm_aggregation_pool` to ≥2 slots in the `airflow-init` job (see "Pool capacity plan"). New resource profile only if requirements extraction needs different memory than existing extraction profiles — probably not.

**rohan_api work (`src/onering/` + `src/compliance/`):**

6. **Extend `OneringDagId` and `RunType` enums** (`onering/types/airflow.types.ts`, `onering/enums/run-type.enum.ts`) to add `COMPLIANCE_REVIEW`. Add a `ComplianceReviewConf` interface.
7. **Add `triggerComplianceReview()` method** to `OneringPipelineService` (or a new `OneringComplianceService` if you want separation). Mirrors `launchProposal()` — creates an `or_pipeline_run` row, calls `OneringAirflowClientService.triggerDagRun()`, returns `{ run_id, status }`.
8. **Compliance controller endpoint** that takes a project ID + uploaded documents and triggers the DAG. Replaces the existing Service-Bus-based auto-tag controller path; the existing `compliance.listener.ts` handler is retired once cutover completes (or kept dual-path behind a feature flag during rollout).
9. **DB migration** on `compliance_items`: add `arc_run_id` (run that produced the item) and `arc_requirement_id` (engine-side opaque ID) columns. The user-visible sequential number column stays owned by rohan_api with PRCR-1570's pessimistic locking unchanged. Existing fields (`status`, `reviewed_by`, `userNotes`) remain the review-state mirror.
10. **Polling-based completion** via the existing `refreshRunStatus()` pattern. On terminal SUCCESS: read `ui_projection_requirements.json` from MinIO via `OneringArtifactService`, validate against the JSON Schema (step 4), drop items whose `source_document_id` was deleted during the run, materialize/supersede `compliance_items` rows in a single transaction (see "Multi-document mapping"). On terminal FAILURE: surface error to the project status; reconciliation service (PRCR-1562) handles transient retries.
11. **JSON Schema validator + dev-mode mock** for `ui_projection_requirements.json`. Validator runs on artifact load. Mock generates a fixture artifact when `ONERING_AIRFLOW_BASE_URL` is unset (see "Local developer experience").
12. **UI adaptation.** Tag UI work (PRCR-1517/1519/1544) is preserved unchanged — items now flow from ONERING-produced artifacts but the rendering layer doesn't care. Add a "extracting (this can take 10–30 min)" UX state that polls run status; success transitions to the existing item-review view.

**Local dev:**

13. **Engine-integration mode** for engineers actively building the DAG/handler: `cd ONERING && cp .env.example .env && make up-airflow`. UI at `localhost:8080`. DAGs hot-reload; ARC source code hot-reloads. Set `ONERING_AIRFLOW_BASE_URL=http://localhost:8080` in the local rohan_api env.
14. **Default dev mode** for everyone else: leave `ONERING_AIRFLOW_BASE_URL` unset; rohan_api detects the absence and uses the in-process fixture mock (step 11). UI engineers iterate on the Compliance UI without spinning Airflow.

**Out of scope for launch (deferred to Phase 2):**

- The other five extraction tabs (structure, evaluation, instructions, attachments, metadata) — net-new feature work, exciting to ship but not needed for launch.
- Compliance matrix XLSX export — deferrable.
- Response-analysis DAG — genuinely new ONERING code; concentrates production-scale unknowns. Sales can demo Compliance as "AI-extracted requirements with review"; automated response checking is "coming next."
- rohan-python-api wrapper for fast inline ops — Phase 3 work.

**Phase 1 timeline reality:**

The "3–5 week" figure occasionally cited is the optimistic end of plausible, not the middle of the distribution. Honest ranges:

- **3–5 weeks** is achievable only if **all** of the following hold: (a) at least one engineer already has deep `/onering/*` namespace and Airflow context, (b) ONERING repo PRs land same-day, (c) the week-1 cost/latency spike returns green for option 1 (full graph) and the thin step factory is not needed, (d) prod-readiness is staffed in parallel by SRE/DevOps without competing for the integration team's time, (e) no major engine refactor lands in window.
- **6–8 weeks** is the realistic range for the scope as defined (integration work + first-prod cutover), assuming 2–3 engineers at typical 60–70% sustained utilization and at least one of conditions (a)–(e) failing.
- **9+ weeks** is the pessimistic case if the thin step factory is required, the ONERING-side PR cadence is slow, or the prod-readiness checklist surfaces a blocker (e.g., network policy or Key Vault wiring requiring cross-team coordination).

**Plan against 6–8 weeks. Track 3–5 as a stretch.** If sales urgency is fixed at a tighter window, treat it as a forcing constraint that must be paired with explicit fallback gates (below) — not as evidence that the work is smaller.

**Phase 1 week-1 gate (continue / fall back to existing architecture):**

1. **DAG running locally end-to-end** with sample data, writing `ui_projection_requirements.json` to MinIO via the run-keyed path.
2. **Cost & latency spike.** Run the full extraction graph (or thin step factory if option 2 from "Phase 1 thin-scope reality" is chosen) on a representative RFP. Record: total wall-clock, per-step pod cold-start time, total LLM cost, slot wait time. Compare to the current Service-Bus-based extraction. **This number drives the decision between option 1 (full graph) and option 2 (thin step factory) before the launch window closes.**
3. **Completion-mechanism end-to-end (local).** rohan_api triggers the DAG, polls to terminal state, materializes items via `OneringArtifactService`. Includes the schema validator and the deletion-during-run check.
4. **Prod-readiness checklist drafted and owners assigned.** Not done — drafted. SLO target, on-call rotation, alerting, runbook, capacity plan, secrets/Key Vault wiring, image registry promotion, ingress, network policy. Each item has a name next to it.
5. **Fallback decision criteria documented.** If milestones (1)–(4) are not green by end of week 1, the team commits to launching Compliance on the existing Service Bus + rohan-python-api path and treats the ONERING migration as Phase 2 work. Pre-production status keeps the fallback cheap.

**Phase 1 week-2 gate (continue / fall back, second checkpoint):**

The week-1 gate catches "we don't know how to start." The week-2 gate catches "we started but the ground is shifting." Required green by end of week 2:

1. **Cost & latency decision made and committed.** Option 1 (full graph) or option 2 (thin step factory). If option 2: the engine-side work is scoped and assigned, with a believable end-of-week-3 delivery date.
2. **ONERING-repo PR open and progressing.** Reviewers identified, review cadence confirmed, no surprise blockers from the engine team.
3. **rohan_api integration code merged behind a feature flag** (DAG trigger, polling, item materialization, schema validator, dev mock). Does not need to be production-clean yet — needs to be reviewable.
4. **Prod-readiness checklist progressing.** SLO and on-call ownership decided. Secrets and Key Vault paths agreed with security. Helm chart prod values reviewed by SRE.
5. **No engine-side breaking change** has landed in `cli.py` requirements internals or `ui_projection_requirements.json` shape since the pinned tag.

If any of (1)–(5) is red, the same fallback applies as in week 1, and the team delivers Compliance on the existing path. **Week-2 fallback is calendar-cheaper than week-3 or week-4 fallback** — that's the point of the second gate.


### Phase 2 — Compliance Expansion (weeks/months after launch)

Once Phase 1 is live and stable:

- **Additional extraction tabs.** Surface `ui_projection_*.json` for structure, evaluation, instructions, attachments, and metadata as new tabs. Each tab is an independently shippable deliverable. Update the `arc_compliance_review` DAG to run all six pipelines, or extend it.
- **Compliance matrix XLSX export.** Hook up ONERING's already-styled six-tab workbook via `OneringArtifactService`.
- **Response-analysis DAG.** New DAG `arc_compliance_response_analysis_dag.py`: ingest response → for each approved item, KM-retrieve evidence from response → produce `ComplianceCheck` payload with `automatedStatus` and evidence spans. Net-new ONERING capability (no current equivalent exists in either rohan_api or rohan-python-api). This phase concentrates the production-scale unknowns; benefits from launch-period learnings.

### Phase 3 — Answer Engine v2 Migration (months out)

This is where the **rohan-python-api wrapper layer** becomes worth building. KM retrieval needs to be a fast inline operation, not an Airflow run; AE v2 streams responses; aggregates are interactive. Airflow doesn't fit this workload.

- Build the rohan-python-api wrapper for fast inline ops (`POST /km/retrieve`, `POST /ingest/document`, `POST /section/write`).
- Replace `AgentWorkflowService.getKmWorkflow()` with calls to `POST /km/retrieve` backed by ONERING's `run_km_retrieval()`.
- Replace `RfpPythonServer.extract-file-content` with `POST /ingest/document` for AE v2's file-context uploads.
- Aggregates and summaries → ONERING section writer (draft / critique / revise + consistency ledger) via the wrapper.
- Add GOLD library as an opt-in past-proposal answer source. Requires resolving GOLD partitioning model first.
- Threads, execution locks, file management, and RBAC stay in NestJS.
- Defer the deep-research consolidation; AE v2's o3 path and ONERING's are functionally similar.

### Phase 4 — Acquisition Center Sub-Feature Migration (further out)

| Sub-feature               | Migration                                                                                                                                                |
| ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Market Research Assistant | Custom Airflow DAG `arc_market_research_dag.py`: discovery → deep research (o3) → vendor research → draft acquisition document. Replaces inline streaming. |
| RFI Assistant             | Section writer (draft/critique/revise) via Phase 3 wrapper.                                                                                              |
| Requirements Discovery    | Direct call to `pipelines.requirements` via Airflow DAG.                                                                                                 |
| Document Library          | Phase 3 ingestion endpoint replaces summary-only path.                                                                                                   |
| Template Generator        | `pipelines.structure` reverse-engineers templates from past proposals.                                                                                   |
| Toolkits                  | No engine work; storage feature stays as-is.                                                                                                             |
| Vector DB calls           | Phase 3 KM retrieval endpoint replaces them.                                                                                                             |

`wizard_state` JSONB shrinks to a thin pointer to ONERING run IDs + step status; the orchestrator's manifest does the heavy lifting.

---

## Timeline & Effort Estimate

Estimates assume 2–3 engineers split across rohan_api (NestJS), ONERING (Python + Airflow DAG), and rohan_ui (Angular), with at least one engineer fluent in the existing `/onering/*` namespace and Airflow setup. Numbers are realistic ranges, not best-case.

### Per-phase ranges

**Phase 1 — Compliance Launch via Airflow (thin scope): 6–8 calendar weeks (realistic), 3–5 weeks (stretch, conditions in "Phase 1 timeline reality").** Roughly 8–12 engineer-weeks of integration work plus 3–5 engineer-weeks of prod-readiness work running in parallel — the prod-readiness pool is on top of the integration estimate, not inside it. Integration breakdown: ONERING side, new DAG file + tests (1–2); rohan_api side, enum extensions, service method, controller endpoints, DB migration, completion wiring (3–4); UI adaptation against new source (1); end-to-end testing and stabilization (2–3). Prod-readiness breakdown: SLO + on-call + alerting + runbook (1–2), Helm prod cutover and validation (1), security review (Key Vault, network policy, ingress) (1), observability dashboard (1). The Airflow integration surface is already mature in lower environments, so the integration side is mostly *extending* existing patterns; the prod-readiness side is genuinely new because Compliance is the first ONERING workload to ship to production.

**Phase 2 — Compliance Expansion: 2–3 calendar months.** Five additional extraction tabs are quick (~1 engineer-week each, mostly UI). XLSX export is short (1–2 weeks). Response-analysis DAG is the big chunk — 8–12 weeks for DAG design, prompt engineering, per-item evidence retrieval, `ComplianceCheck` integration, and production hardening. Total ~14–19 engineer-weeks.

**Phase 3 — Answer Engine v2 Migration: 3–5 calendar months.** Wider range driven by: (1) building the rohan-python-api wrapper layer (3–5 weeks); (2) GOLD library partitioning design (2 weeks if simple per-org, 1–2 months if per-proposal access control); (3) behavior-parity validation against AE v2's already-shipped behavior (2–4 weeks); (4) KM cost/latency measurement spike (1–2 weeks). Total ~18–30 engineer-weeks.

**Phase 4 — Acquisition Center Sub-Feature Migration: 3–4 calendar months.** Sub-features are independently sized: MRA (4–6 weeks), RFI (2–3), Requirements Discovery and Document Library (1–2 each), Template Generator (3–4), vector-DB replacement (2–3), wizard-state migration (2–3), testing and hardening (3–4). Total ~18–26 engineer-weeks.

### Totals

- **Sequential execution:** 7–13 calendar months for the full four-phase plan with 2–3 engineers.
- **With overlap** (Phase 2 starts while Phase 1 stabilizes; Phase 3 begins while Phase 2 winds down): 5–9 calendar months.

### Comparison to initial estimate

A 3-month / 2–3 engineer estimate (~18–27 engineer-weeks) is tight for **Phase 1 plus the bulk of Phase 2** once Phase 1 is sized at 6–8 weeks. It works only if Phase 1 lands in the stretch range (3–5 weeks); at 6–8 weeks it pushes into 4 months. It is not enough for the full four-phase plan that includes AE v2 and Acquisition Center under any sizing.

Given the proposal's recommendation to defer Phases 3–4 by months anyway, the relevant question is whether 3 months gets you Phases 1–2. Honest answer: only in the optimistic case. The harder constraint is hitting the launch window for Phase 1 alone — and the realistic path is to negotiate sales to the 6–8-week range, not to commit to 3–5 and slip.

### What drives variance

- **Engineer ramp on the existing `/onering/*` namespace and Airflow patterns.** Faster if someone on the team already knows them; slower otherwise.
- **GOLD/KM partitioning complexity.** Phase 3 only — if it requires per-proposal access control rather than per-org, expand 2–4 weeks.
- **First production deployment of the ONERING stack.** Compliance Phase 1 is both a new DAG and the first prod cutover of the integration — proposal launch and discovery are running in lower environments today but have not yet shipped to prod. Plan for 2–3 weeks of post-launch stabilization rather than 1–2.
- **DAG repo coordination.** Adding the Compliance DAG requires a PR to the ONERING repo. If review/deploy cadence in that repo is slow, that becomes a calendar-time tax independent of engineering capacity.
- **Cross-team coordination.** Sales demo scoping, launch-date negotiation — calendar time without engineer time.

### Single numbers to plan against

If forced to commit to point estimates:

- **Phase 1: 7 weeks** as the planning number, with hard fallback gates at week 1 and week 2. 4 weeks is the stretch target if all conditions in "Phase 1 timeline reality" hold.
- **Phase 1 + Phase 2: 4 months** for 2–3 engineers (revised up from 3.5 months to reflect the realistic Phase 1 range).
- **Full four-phase plan: 9–10 months** for 2–3 engineers, with overlap.

A 3-month / 2–3 engineer budget is tight for Phases 1–2 once Phase 1 is sized realistically; it works only if Phase 1 lands in the stretch range. Plan against 4 months for Phases 1–2 and against 9–10 months for the full scope.

---

## Concerns to Resolve Before Committing

The "Phase 1 Operational Decisions" section above pins down the engineering-level choices (completion mechanism, pool capacity, multi-doc mapping, numbering, doc-deletion handling, engine version pin, observability, CI, local dev). The concerns below are the residual unknowns that need explicit answers from stakeholders.

1. **Production Airflow readiness becomes a Compliance launch dependency.** The local dev story is solved (`make up-airflow`) and lower-env Airflow is already running, but **the ONERING Airflow stack has not yet been deployed to production**. Compliance Phase 1 forces that cutover. Required before launch: explicit prod-readiness checklist (SLO target, on-call rotation, alerting, runbook, capacity headroom, secrets and Key Vault wiring, image registry promotion, ingress, network policy). This is more work than "extend existing prod infra" implies and should be tracked as a parallel workstream from week 1.

2. **DAG repo coordination.** Adding `arc_compliance_review_dag.py` is a PR to the ONERING repo. If the team that owns that repo has different review cadence or release process than rohan_api, it creates calendar-time friction. Worth confirming the workflow up front.

3. **Cost & latency baseline.** Phase 1 week-1 milestone (2) measures it. Real numbers replace the 5–10× cost / 10–30 min wall-clock estimates above. Budget for switching to the thin step factory if numbers don't fit.

4. **Per-org tenancy.** Mostly resolved by following existing conventions (see **Tenancy Model**). Reuse `or_pipeline_runs.organization_id` for access control. The remaining open design decision is GOLD/KM partitioning, which is a Phase 3 concern.

5. **Custom step graph governance.** As more module-specific factories ship (`compliance_review`, eventually `mra_assistant`, `ae_v2`), expect step-name collisions and prompt drift. Suggest a registry pattern in ONERING — modules register namespaced prefixes and the orchestrator validates uniqueness. Not a Phase 1 blocker.

6. **Response analysis is genuinely new.** ONERING doesn't currently have "compare a response document against extracted requirements." That work lands in Phase 2 as `arc_compliance_response_analysis_dag`, not Phase 1, but the Phase 1 architecture should leave room for it (e.g., the `compliance_items.arc_run_id` schema generalizes to multiple run types per project).

7. **Azure Government (.us) feasibility.** Spike scheduled in Phase 1 week 1 if any Gov customer is in scope for the Compliance launch. Otherwise gate Compliance feature flag off for Gov orgs and address in Phase 2.

8. **KM cost and latency for AE v2 (Phase 3 concern).** ONERING KM is brute-force chunk-by-chunk LLM scanning. AE v2 today might make 1 LLM call per question; on ONERING KM it could be 50+. Worth a measurement spike before Phase 3 — not a Phase 1 blocker.

9. **GOLD library partitioning (Phase 3 concern).** Today GOLD is one folder. For AE v2 to use it as an answer source you need per-org curation, possibly per-project filtering, possibly per-proposal access control. Product work, not plumbing. Phase 3 prerequisite.

10. **Streaming for Phase 3.** Compliance doesn't need streaming (Airflow is async). But AE v2 expects SSE, and Airflow doesn't fit interactive workloads. Phase 3's rohan-python-api wrapper has to solve streaming-from-engine — either via in-progress events from ONERING or by keeping streaming responsibility in NestJS with the engine seeing only finalized artifacts. Decision needed before Phase 3 starts.

---

## Tradeoffs: Should This Happen Now?

The plan above is what _could_ be done. Whether it should be done _at this point in time_ is a separate question. Below is a frank tradeoff analysis given the current context (Compliance pre-production, ~few-weeks launch target, no specific feature commitments, ONERING is a high-priority initiative with resource availability, AE v2 / Acquisition Center can wait several months, mature `/onering/*` + Airflow infrastructure already implemented and running in dev/staging — but **not yet in production**).

### Pros

**1. Pre-production Compliance status is the cheapest possible moment to commit to ONERING.** No user data, no edits to migrate, no launch promises to break, no behavioral parity bar to clear. Launching on the current architecture and refactoring later is double-work; choosing ONERING up front avoids it.

**2. Sales urgency is the forcing function.** Big engine consolidations stall without a deadline; the Compliance launch supplies one — it gives the work a date and a why.

**3. The `/onering/*` namespace and Airflow stack are already mature.** Seven controllers, eleven services, a DAG library, a Helm chart, hot-reload local dev, KubernetesExecutor with per-task pod resource profiles. Phase 1 is mostly *extending* this rather than building from scratch — much lower risk than an unproven greenfield path.

**4. The integration is mature in lower environments.** Proposal launch and opportunity discovery DAGs run end-to-end in dev/staging today; the engineering surface has been exercised. Compliance is not the first DAG to be wired up — it is the first DAG to ship to production. That asymmetry matters: the integration shape is proven, the production cutover is not.

**5. Phase 1 ships features.** The launch _is_ the feature delivery. ONERING-driven from day one means sales can sell on engine-backed capabilities (canonical line-numbered evidence, audit trail per LLM call, future-ready for response analysis and matrix export) rather than retrofitting that story later.

**6. Audit trail and debuggability are real wins.** ONERING's manifest plus per-call artifact persistence (`llm_calls/{step}/{prompt}/{call_id}/`) plus Airflow's per-task UI is dramatically more debuggable than what the existing modules have. This matters more as Compliance ships to actual users.

**7. The compounding duplication tax stops growing.** Every new feature added to AE v2, Acquisition Center, or Compliance today picks one of three different retrieval approaches and three ingestion paths. Establishing the engine pattern with Compliance creates the pull for AE v2 and Acquisition Center to follow.

**8. Strategic narrative.** "ONERING as engine" reframes the product from "three modules that happen to use AI" to "an AI engine for proposal/acquisition/compliance workflows with surfaces tailored to each." Compliance launching on ONERING is the demonstration that makes the story credible.

**9. Pre-launch tag UI investment is easy to absorb.** The recently-merged tag UI work (PRCR-1517/1519/1544) is preserved unchanged under this plan because items become source-agnostic — the rendering layer doesn't care whether items came from the existing extraction path or from ONERING.

### Cons

**1. Timeline is tighter than 3–5 weeks reads.** The realistic range is 6–8 weeks once first-prod cutover is in scope; 3–5 weeks requires multiple favorable conditions to hold simultaneously (deep `/onering` context on team, same-day ONERING-repo reviews, green cost/latency spike, parallel SRE staffing, no engine refactor in window — see "Phase 1 timeline reality"). The risk isn't "we don't know how"; it's that the team commits to the optimistic number, hits any one of the friction points, and slips past the launch window without an early-enough fallback. The week-1 and week-2 gates exist precisely to make the slip cheap.

**2. First production deployment of the ONERING stack.** This is two firsts at once: a new DAG with new step ordering, and the initial prod cutover of the entire ONERING integration. Production surfaces issues that staging won't (capacity, networking, secrets rotation, image registry, on-call, ingress, observability gaps). Plan for 2–3 weeks of post-launch stabilization specifically for this path, and treat the prod-readiness checklist as a launch gate.

**3. Cross-repo coordination overhead.** Phase 1 work spans the ONERING repo (DAG file, tests) and rohan_api (services, controllers, DB migration). Two PRs need to merge in coordination; production cutover requires both deployed. Not a blocker, but a calendar-time tax.

**4. Streaming/state-model decisions still need deliberate design for Phase 3.** Compliance is async (Airflow), so Phase 1 doesn't force the issue. But AE v2 in Phase 3 requires SSE streaming through a wrapper layer — and how that wrapper interacts with ONERING is a real architectural decision. Easy to make pragmatic Phase 1 choices that hurt Phase 3.

**5. Engine-side engineering may be underfunded.** "ONERING is a high priority" should include the engine itself, not just integration work. Custom step factory hardening, eventually streaming hooks, eventually response-analysis pipeline — these need ONERING-side engineering capacity.

**6. ONERING is still evolving fast.** `cli.py` is growing on a weekly cadence. Building Compliance on a young codebase means every ONERING refactor cascades. Phase 1 partially mitigates via the engine version contract (pinned Airflow git-sync ref + pinned submodule + JSON Schema validator + CI cross-check — see "Engine version contract" above), but full insulation requires a versioned engine API surface that's deferred to Phase 3. Expect a steady tax of "ONERING tag bumps with smoke validation" between launch and that work.

**7. Modules lose iteration independence over time.** Once multiple modules share an engine, prompt and pipeline changes need cross-module regression. Not a Phase 1 issue but a real ongoing tax once Phase 3+ land.

**8. AE v2 KM swap will not be free when its turn comes (Phase 3).** Behavioral parity is harder than feature parity, and AE v2 just shipped — disrupting it again in a few months creates user fatigue. Worth flagging now so Phase 3 timing is realistic.

### Honest Summary

The plan is technically sound and the timing is unusually favorable. Pre-production Compliance + sales urgency + AE v2/Acquisition Center deferral + ONERING priority + mature `/onering/*` and Airflow stack already running in dev/staging is roughly the best window this team will get for an engine consolidation. The honest caveat: the ONERING stack has not yet been deployed to production, so Phase 1 carries a "two firsts at once" cost — first Compliance launch and first ONERING prod cutover. The week-one checkpoint discipline plus a parallel prod-readiness workstream are how that cost is managed.

**Recommended path:** thin Compliance launch as an Airflow DAG in the few-weeks window (Phase 1), with Phase 2 expanding scope post-launch and Phases 3–4 following months later as separate efforts. Phase 3 is where the rohan-python-api wrapper layer becomes worth building — not before.

**Non-negotiables for Phase 1:**

- Reuse `or_pipeline_runs`, `OneringPipelineService`, `OneringArtifactService`, `OneringExceptionFilter` rather than building parallel infrastructure.
- Per-org tenancy via the established `dag_run.conf` envelope + `or_pipeline_runs.organization_id` access control.
- Polling-based completion using `refreshRunStatus()` + reconciliation service (PRCR-1562). Defer Service Bus completion publish to Phase 2.
- Pin the Airflow git-sync ref to a tagged ONERING release; ship the JSON Schema validator for `ui_projection_requirements.json` before launch.
- rohan_api owns user-visible sequential item numbering (PRCR-1570 stays); `arc_requirement_id` stores the engine-side opaque ID.
- Bump `llm_extraction_pool` to ≥4 slots and `llm_aggregation_pool` to ≥2 slots before launch.
- **Two fallback gates, not one.** Week-1 gate (DAG running end-to-end locally + cost/latency spike + prod-readiness checklist drafted with owners) and week-2 gate (cost/latency decision committed + ONERING-repo PR progressing + integration code merged behind feature flag + prod-readiness progressing + no engine breakage). Either gate can trigger fallback to "launch on current architecture, do ONERING migration as Phase 2." Two gates because slipping a 6–8-week project at week 4 is much more expensive than slipping at week 2.
- **Plan against 6–8 weeks; treat 3–5 weeks as a stretch.** Negotiate sales to the realistic range up front rather than committing to the optimistic one and slipping. See "Phase 1 timeline reality."
- **Prod-readiness checklist as a launch gate.** Because Compliance Phase 1 is the first prod deployment of the ONERING stack: SLO target, on-call rotation, alerting, runbook, capacity headroom, secrets and Key Vault wiring, image registry promotion, ingress, network policy, observability dashboard. **Counted as a separate ~3–5 engineer-week pool**, not folded into the integration estimate. Tracked as a parallel workstream with named owners from week 1, not a week-3 surprise.

**Aggressively defer for Phase 1:**

- Response-analysis DAG (Phase 2).
- Other five extraction tabs (Phase 2).
- XLSX export (Phase 2).
- rohan-python-api wrapper layer (Phase 3).
- Anything for AE v2 or Acquisition Center.

**Open questions worth confirming before starting:**

- Is the few-weeks launch date hard or soft? "Sales wants to sell" is real urgency but may not be a fixed deadline. The honest planning number is 6–8 weeks; getting sales to that window up front is materially safer than committing to 3–5 and slipping.
- What does sales actually need to demo? If "AI extracts requirements, your team reviews, response analysis is coming next quarter" is enough, the thin scope works.
- Does the team that owns the ONERING repo have capacity to review and merge the new Compliance DAG within the launch window? This is the single biggest external dependency.

**The single thing to push hardest on:** preserve the week-one **and week-two** checkpoint discipline, and negotiate sales to a 6–8-week launch window instead of 3–5. The Airflow integration path is well-trodden in lower environments, but first-prod cutover plus a new DAG plus a fast-evolving engine adds up to a realistic 6–8 weeks. Catching trouble at week 1 or 2 is far cheaper than catching it at week 4 or 5; committing to the realistic range up front is cheaper still.
