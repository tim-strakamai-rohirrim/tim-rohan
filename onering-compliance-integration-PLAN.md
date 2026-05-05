# onering-compliance-integration — Plan

Phased implementation plan for **Phase 1** of `ONERING_INTEGRATION_PROPOSAL.md`: Compliance launch on ONERING via Airflow. This document treats the integration as a single epic spanning three repos (ONERING, rohan_api, rohan_ui). Each phase below is independently implementable as a single PR with its own subticket.

Companion: `onering-compliance-integration-contracts.md` (API, DTO, schema, frontend types).

---

## Problem statement

Compliance auto-extraction today runs through Service Bus → rohan-python-api → `tagging.auto-tag-complete` event → `compliance.listener.ts` materializer. The proposal recommends swapping that transport for an Airflow-orchestrated `arc_compliance_review` DAG that reuses the engine work in ONERING. The benefit is engine consolidation: ONERING already produces line-numbered evidence, audit-trail-per-LLM-call, and is the future home for response analysis, matrix export, and the other extraction tabs.

Compliance is pre-production, which makes it the cheapest moment to commit. It is also the **first production cutover of the ONERING Airflow stack** — the namespace and Helm chart exist and run in dev/staging, but no DAG has shipped to prod yet. Phase 1 therefore carries a "two firsts at once" cost: new DAG plus first prod cutover.

## Key architectural observations

- **`/onering/*` namespace in rohan_api is mature.** `OneringPipelineService`, `OneringAirflowClientService`, `OneringArtifactService`, `OneringExceptionFilter`, `or_pipeline_runs` table, `OneringDagId` / `RunType` enums. Phase 1 *extends* this; it does not build a parallel stack. Reference pattern: `arc_launch_proposal_dag.py` + `OneringPipelineService.launchProposal()`.
- **Airflow stack (`ONERING/airflow/`) runs in dev and staging.** Helm chart `helm/onering-airflow/` with `values-{dev,staging,prod}.yaml`. KubernetesExecutor with per-task pod resource profiles. Pools `llm_extraction_pool` (2 slots) and `llm_aggregation_pool` (1 slot) are shared across all DAGs.
- **`compliance_items` already supports auto-extraction.** `extractionMethod`, `lineItemNumber` (PRCR-1570 sequential numbering with pessimistic lock), `documentStartLine`/`documentEndLine`, `status`, `userNotes`. Phase 1 adds two columns (`arc_run_id`, `arc_requirement_id`) to link items back to the run that produced them.
- **Existing listener at `compliance.listener.ts:379`** consumes `tagging.auto-tag-complete`. Phase 1 keeps it intact during the dual-path window; Phase 13 retires it after bake.
- **`cli.py` is ~17K lines and growing weekly.** Engine version contract is mandatory: pinned Airflow git-sync ref + JSON Schema for `ui_projection_requirements.json` + CI cross-check.
- **Schema changes ownership.** Per `rohan_api/CLAUDE.md`, schema changes live in the separate `Database/` repo and sync into rohan_api via a manual script. Plan respects that ownership.
- **Step factory chosen up front: option 2** (`compliance_review:build_steps`) — thin step graph (ingestion → chunk_plan → `pipelines.requirements` → `pipelines.ui_projection_requirements`). No metadata/structure/evaluation upstream cost. Decision committed by user; Phase 1 ships this, no week-1 fallback to option 1.

## Assumptions

1. The thin step factory (option 2) can run `pipelines.requirements` without `metadata` / `structure` / `evaluation` UI projections. Phase 1 confirms this in the engine PR; if `pipelines.requirements` consumes upstream projections in non-trivial ways, the factory injects empty defaults. If that turns out to require pipeline-internal changes, scope grows by ~3–5 engineer-days and lands in Phase 1's engine work, not as a new phase.
2. The existing `OneringPipelineService.refreshRunStatus()` polling cadence (used for proposal launch) is acceptable for Compliance latency. No new scheduler primitive needed.
3. `or_pipeline_runs.run_type` column is `varchar` and accepts an enum extension without DDL change. Verified by reading the existing migration before Phase 5 lands.
4. PRCR-1570's pessimistic lock can be reused inside the materializer transaction. The materializer calls the same numbering helper used by the manual create path.
5. rohan-python-api stays untouched in Phase 1. The Service Bus path remains live behind the feature flag during dual-path; Phase 13 retires it.
6. Single Airflow trigger per project per request. Multi-document runs use a single `dag_run.conf.document_ids` array; the DAG processes all docs as one chunk plan.
7. Polling completion is sufficient. No webhook callback (proposal §"DAG → rohan_api completion mechanism" line 209 explicitly rejects inbound webhooks: would require new auth + idempotency + ingress rules with no UX benefit over polling). Service Bus completion publish from the CLI is Phase 2.
8. `or_pipeline_runs.materialized_at` is the idempotency latch for the materializer. If the column doesn't exist, Phase 5 adds it alongside the other `compliance_items` changes.
9. Feature flag `ONERING_COMPLIANCE` is org-scoped via the existing `OrganizationFeaturesService` JSON-blob source. The `FeatureGuard` already understands org-level feature gating.

## Open questions

| # | Question | Default answer |
|---|----------|----------------|
| 1 | Does `pipelines.requirements` produce identical output without `metadata`/`structure`/`evaluation` projections? Validated where in the engine PR? | Engine-side behavioral parity test on the staging fixture set is the validation; Phase 1 PR is blocked on this passing. |
| 2 | Does `or_pipeline_runs` already have a `materialized_at` column or equivalent idempotency latch? | Assume no. Phase 5 adds it. |
| 3 | Does PRCR-1570's numbering helper expose a callable for batched insert? Or only a per-row API? | If per-row only, materializer loops within the transaction; acceptable for the typical 50–500-item project. Revisit if profiling shows lock contention. |
| 4 | Where does `OneringPipelineService` persist `project_id` for a given `arc_run_id`? Is there a side table or a JSON column on `or_pipeline_runs`? | Typed columns on `or_pipeline_runs`: `project_id UUID` and `document_ids UUID[]`. No JSONB junk-drawer. Phase 5 covers this; service consumers (Phase 6, Phase 7) read the typed columns directly. |
| 5 | Does the existing `OneringMinioService` know how to read fixture artifacts during the in-process mock, or does the mock write through it? | Mock writes through `OneringMinioService` so the read path is identical to prod. Phase 9 verifies this. |
| 6 | Is `OneringAirflowClientService.killDagRun(dag_run_id)` already exposed? | Not needed for Phase 1 — no consumer in scope. Defer to a future phase that introduces cancel-on-document-deletion or stuck-run reaper. Open Q removed from Phase 1 scope. |
| 7 | Do prod Helm values for `onering-airflow` exist and just need pool count bumps, or does the prod values file need full review? | `values-prod.yaml` exists per the proposal. Phase 3 reviews + bumps; SRE owns sign-off. |
| 8 | Is there an existing `compliance_run_documents` join/audit table for tracking which documents were included in a run? | No new join table. Phase 5 stores `document_ids` as a typed UUID[] column on `or_pipeline_runs`. Re-evaluate if multi-document audit queries become hot. |
| 9 | What is the SLO target for `arc_compliance_review` end-to-end? | Stakeholder input needed. Default placeholder: p95 wall-clock < 30 min for ≤10 documents; surfaces in Phase 11 prod-readiness ticket. |
| 10 | Azure Government (.us) — proposal calls this a follow-up. Confirm Gov orgs are flagged off for Phase 1 launch and the spike is a separate ticket. | Conditional. **If no Gov customer in scope for launch:** flagged off, spike post-launch (this is the current default). **If a Gov customer is in scope (decided at week-1 gate W1.5):** spike runs in week 1 alongside engine work, NOT post-launch. Decision logged in writing per W1.5 evidence row. |

## Non-goals (deferred to later phases of the proposal)

- Service Bus completion publish from CLI (proposal Phase 2 upgrade path).
- Other five extraction tabs (structure, evaluation, instructions, attachments, metadata) — proposal Phase 2.
- Compliance matrix XLSX export — proposal Phase 2.
- Response-analysis DAG (`arc_compliance_response_analysis_dag`) — proposal Phase 2.
- rohan-python-api wrapper layer for fast inline ops — proposal Phase 3.
- Anything for Answer Engine v2 or Acquisition Center.
- **Azure Government (`.us`) feasibility** — conditional follow-up. Default: Gov orgs flagged off at launch, spike scoped post-launch (Helm-chart-on-Gov-AKS, OpenAI-`.us`-endpoint-routing, image registry promotion to Gov registry). **Override:** if a Gov customer enters scope at the week-1 gate (W1.5), the spike pulls into Phase 1 week-1 work, not post-launch. Either path decided in writing at gate close-out.

---

## Fallback gates (week-1 + week-2)

Per `ONERING_INTEGRATION_PROPOSAL.md` non-negotiable line 524 ("Two fallback gates, not one"). Slipping a 6–8 week integration at week 4 is much more expensive than slipping at week 2. Each gate has a hard-fall-back path: ship Compliance on the existing Service-Bus + rohan-python-api architecture and treat the ONERING migration as Phase 2 work. Pre-production status keeps the fallback cheap.

### Week-1 gate (continue / fall back)

Required green by end of calendar week 1 from kickoff:

| # | Criterion | Owner | Evidence |
|---|-----------|-------|----------|
| W1.1 | DAG running locally end-to-end with sample data; writes `ui_projection_requirements.json` to MinIO via run-keyed path. | Stream A (engine) | Demo + MinIO artifact path |
| W1.2 | Cost & latency spike on representative RFP. Records: total wall-clock, per-step pod cold-start, total LLM cost, slot wait time. Compared to current Service-Bus extraction. | Stream A + Stream B | Numbers committed to `docs/onering-compliance/baseline-measurements.md` |
| W1.3 | Completion-mechanism end-to-end (local). rohan_api triggers DAG, polls to terminal state, materializes items via `OneringArtifactService`. Includes schema validator + deletion-during-run check. | Stream B | E2E test passing locally |
| W1.4 | Prod-readiness checklist drafted with named owners. Not done — drafted. | Stream D (SRE-led) | `docs/onering-compliance/prod-readiness.md` with owner names |
| W1.5 | Azure Gov in-scope decision. Confirmed in writing whether any current customer or near-term sales prospect is on `.us`. If yes: Gov spike scoped and assigned this week (not deferred). If no: flag-off-for-Gov decision logged. | Product + Stream B | PR comment or Jira ticket |

**Fallback trigger.** Any of W1.1–W1.4 red at end of week 1 → team commits to launching Compliance on the existing Service-Bus path and re-files the ONERING migration as Phase 2 work. W1.5 red → spike landed by week 2 OR Gov orgs flagged off explicitly.

### Week-2 gate (continue / fall back, second checkpoint)

Required green by end of calendar week 2:

| # | Criterion | Owner | Evidence |
|---|-----------|-------|----------|
| W2.1 | Step-graph decision committed (option 2 thin step factory shipping per current plan). Engine-side work scoped and assigned. Believable end-of-week-3 delivery date. | Stream A | Phase 1 PR open |
| W2.2 | ONERING-repo PR open and progressing. Reviewers identified, review cadence confirmed, no surprise blockers. | Stream A | PR link + reviewer comments |
| W2.3 | rohan_api integration code merged behind feature flag (DAG trigger, polling, item materialization, schema validator, dev mock). Reviewable, not yet production-clean. | Stream B | Merged PRs for Phases 4–7 |
| W2.4 | Prod-readiness checklist progressing. SLO + on-call ownership decided. Secrets + Key Vault paths agreed with security. Helm prod values reviewed by SRE. | Stream D | Checklist updated |
| W2.5 | No engine-side breaking change has landed in `cli.py` requirements internals or `ui_projection_requirements.json` shape since the pinned tag. | Stream A | Diff check vs pinned tag |

**Fallback trigger.** Any of W2.1–W2.5 red at end of week 2 → same fallback path as week 1. Calendar-cheaper than slipping at week 3 or 4.

### Tracking

Both gates carry their own subticket under the epic (`<epic>/gate-week-1`, `<epic>/gate-week-2`) with the criteria above as acceptance items. Engineering lead closes the gate ticket with a one-line green/red call and a link to the evidence row. No silent slip past either gate.

---

## Branching convention

Per skill convention: `{user}/{epic}/phase-{N}` per repo. The epic name is `onering-compliance-integration`. Each phase lives in exactly one repo and stacks on the prior phase in the **same repo**. Cross-repo phases do not stack on each other — they coordinate via the contracts document.

| Repo | Phases | Stack within repo |
|------|--------|-------------------|
| ONERING | 1, 2, 3 | 1 → 2 → 3 |
| rohan_api | 4, 5, 6, 7, 8, 9 | 4 → 5 → 6 → 7 → 8 → 9 |
| rohan_ui | 10 | 10 (off main) |
| Cross-cutting (mostly rohan_api repo, some Database/SRE) | 11, 12, 13 | sequenced after the integration phases land |

`base_branch: base` means main of the phase's repo. `base_branch: phase-N` means the prior phase's branch in the same repo.

---

## Implementation phases

### Phase 1 — Engine: thin Compliance step factory [PYTHON]

```phase-meta
phase: 1
title: Engine - thin Compliance step factory (compliance_review:build_steps)
tags: [PYTHON]
repo: onering
base_branch: base
depends_on: []
files:
  - arc_agent_writer/factories/__init__.py
  - arc_agent_writer/factories/compliance_review.py
  - arc_agent_writer/orchestrator/cost_summary.py
  - arc_agent_writer/tests/factories/test_compliance_review_factory.py
  - arc_agent_writer/tests/orchestrator/test_cost_summary.py
  - arc_agent_writer/tests/fixtures/ui_projection_requirements.sample.json
  - arc_agent_writer/tests/fixtures/cost_summary.sample.json
  - arc_agent_writer/CLAUDE.md
contracts:
  - "1.1 compliance_review:build_steps step factory"
  - "1.3 ui_projection_requirements.json v1 JSON Schema (sample fixture)"
  - "1.5 cost_summary.json run-level rollup"
verification:
  - uv run pytest arc_agent_writer/tests/factories/test_compliance_review_factory.py
  - uv run pytest arc_agent_writer/tests/orchestrator/test_cost_summary.py
  - uv run python -m arc_agent_writer.cli run --steps-factory arc_agent_writer.factories.compliance_review:build_steps --dry-run
```

**Goal**: Add a thin step graph that runs `ingestion → chunk_plan → pipelines.requirements → pipelines.ui_projection_requirements` only, bypassing metadata-derived deps.

**Steps**:

- [ ] **1.1** Create `arc_agent_writer/factories/` package (`__init__.py`).
- [ ] **1.2** Implement `build_steps(config)` in `factories/compliance_review.py` returning the seven-step Sequence per Contracts §1.1.
  - Inject empty/default UI-projection inputs where `pipelines.requirements` consumes upstream projections that are not produced by the thin graph.
  - Document any pipeline-internal changes required for the thin graph to run; if any are non-trivial, surface them in the PR description and the engine team approves before merge.
- [ ] **1.3** Add unit test `test_compliance_review_factory.py`: validates step ordering, count (7), no metadata/structure/evaluation steps present.
- [ ] **1.4** Add a sample fixture `ui_projection_requirements.sample.json` matching the v1 JSON Schema (this fixture is referenced by Phase 9's rohan_api dev mock and Phase 12's CI cross-check).
- [ ] **1.5** Implement `cost_summary.py` orchestrator hook. On terminal step (success path) and on failure handler (best-effort partial), aggregate per-call `cost.json` artifacts into `AGENT_RUNS/{run_id}/cost_summary.json` per Contracts §1.5. Single read path for rohan_api dashboards — replaces aggregating per-call files at query time. Add fixture `cost_summary.sample.json` and unit test that the rollup matches summed inputs.
- [ ] **1.6** Update `arc_agent_writer/CLAUDE.md` with a one-paragraph note on the `compliance_review` factory and how to invoke it. Document the `cost_summary.json` emission contract.

---

### Phase 2 — Engine: arc_compliance_review DAG + JSON Schema [PYTHON]

```phase-meta
phase: 2
title: Engine - arc_compliance_review DAG + ui_projection_requirements schema
tags: [PYTHON]
repo: onering
base_branch: phase-1
depends_on: [1]
files:
  - airflow/dags/arc_compliance_review_dag.py
  - arc_agent_writer/tests/test_airflow_dag_compliance_review.py
  - specs/ui_projection_requirements.schema.json
  - airflow/CLAUDE.md
contracts:
  - "1.2 arc_compliance_review DAG dag_run.conf envelope"
  - "1.3 ui_projection_requirements.json v1 JSON Schema"
verification:
  - uv run pytest arc_agent_writer/tests/test_airflow_dag_compliance_review.py
  - "python -c 'import json,jsonschema; jsonschema.Draft7Validator.check_schema(json.load(open(\"specs/ui_projection_requirements.schema.json\")))'"
```

**Goal**: Ship the Airflow DAG file and freeze the v1 JSON Schema for the requirements artifact.

**Steps**:

- [ ] **2.1** Create `airflow/dags/arc_compliance_review_dag.py`. Mirror `arc_launch_proposal_dag.py`. BashOperator wrapping `python -m arc_agent_writer.cli run --steps-factory arc_agent_writer.factories.compliance_review:build_steps`. `dag_run.conf` envelope per Contracts §1.2. Tags `["arc", "compliance", "extraction"]`. `max_active_runs=4`. Retries 1 / 5 min.
- [ ] **2.2** Add DAG unit test `test_airflow_dag_compliance_review.py` mirroring the existing `test_airflow_dag_llm_mode.py` — validates DAG loads, task ordering, conf-param parsing, env-var export to BashOperator.
- [ ] **2.3** Write `specs/ui_projection_requirements.schema.json` per Contracts §1.3. Include the `schema_version: "1"` constant so rohan_api can reject unknown versions.
- [ ] **2.4** Fixture stays at the Phase 1 location: `arc_agent_writer/tests/fixtures/ui_projection_requirements.sample.json`. **Do not move.** rohan_api Phase 9 mock and Phase 12 CI cross-check both pin to this exact path; relocating it silently breaks both. Confirm CI cross-check runs locally (`jsonschema -i arc_agent_writer/tests/fixtures/ui_projection_requirements.sample.json specs/ui_projection_requirements.schema.json`).
- [ ] **2.5** Update `airflow/CLAUDE.md` with a section on the new DAG, conf shape, and pool usage.

---

### Phase 3 — Engine: Helm pool capacity + prod values review [PYTHON]

```phase-meta
phase: 3
title: Engine - Helm pool capacity bumps + prod values review
tags: [PYTHON]
repo: onering
base_branch: phase-2
depends_on: [2]
files:
  - helm/onering-airflow/values.yaml
  - helm/onering-airflow/values-dev.yaml
  - helm/onering-airflow/values-staging.yaml
  - helm/onering-airflow/values-prod.yaml
  - helm/onering-airflow/templates/airflow-init-job.yaml
  - helm/onering-airflow/.rendered/dev.yaml
  - helm/onering-airflow/.rendered/staging.yaml
  - helm/onering-airflow/.rendered/prod.yaml
  - .github/workflows/onering-helm-parity.yml
  - docs/onering-airflow/sizing-model.md
contracts:
  - "1.4 Airflow pool sizing + sizing model"
  - "1.6 Git-sync ref pin policy"
  - "9.3 Helm parity job"
verification:
  - helm lint helm/onering-airflow
  - helm template helm/onering-airflow -f helm/onering-airflow/values-prod.yaml > helm/onering-airflow/.rendered/prod.yaml.new && diff helm/onering-airflow/.rendered/prod.yaml helm/onering-airflow/.rendered/prod.yaml.new
  - "! grep -E '^\\s*ref:\\s*(main|HEAD|master)\\s*$' helm/onering-airflow/values-prod.yaml"
```

**Goal**: Bump pool sizes per documented sizing model, ensure `values-prod.yaml` is review-ready for the first prod cutover, pin git-sync refs, and lock Helm rendering behind a parity CI job so values-file changes produce reviewable diffs.

**Steps**:

- [ ] **3.1** In `airflow-init` job, raise `llm_extraction_pool` to 4 slots and `llm_aggregation_pool` to 2 slots. Apply across `values-{dev,staging,prod}.yaml` via base `values.yaml` overrides where appropriate. Document the sizing model in `docs/onering-airflow/sizing-model.md` per Contracts §1.4 (concurrent run targets, slot-hold per run, headroom assumption, re-evaluation trigger). Numbers are diff-able.
- [ ] **3.2** Pin `gitSync.ref` in all three env values files to a specific engine release tag per Contracts §1.6. NEVER `main` / `HEAD` / a branch name. Phase 13 final step bumps prod ref to the engine release matching `onering-compliance-v1`. Add the regex check to verification commands above so the CI catches a regression to a branch ref.
- [ ] **3.3** SRE review of `values-prod.yaml` — capacity headroom, image registry, ingress, network policy, secrets paths (Key Vault for Airflow basic-auth credentials). SRE sign-off captured in PR description.
- [ ] **3.4** No new resource profile required (requirements extraction fits the existing `llm_extraction` 8–16 GiB profile). Confirmed during the engine spike; if confirmed false, add a `compliance_extraction` profile here.
- [ ] **3.5** Add Helm parity CI workflow `onering-helm-parity.yml` per Contracts §9.3. Triggers on PRs touching `helm/onering-airflow/**`. Renders each env, diffs against checked-in baseline at `helm/onering-airflow/.rendered/<env>.yaml`, fails if author did not update the baseline. Asserts no env file pins `gitSync.ref` to a branch. Closes the gap that `make up-airflow` (Docker Compose, used by §9.1 / Phase 12) does not validate the Helm chart.
- [ ] **3.6** Commit the initial baseline renders to `helm/onering-airflow/.rendered/{dev,staging,prod}.yaml`. Subsequent Helm changes update both the values file AND the rendered baseline in the same PR.

---

### Phase 4 — rohan_api: enums, types, DTOs [BACKEND_DB]

```phase-meta
phase: 4
title: rohan_api - OneringDagId, RunType, ComplianceReviewConf, DTOs
tags: [BACKEND_DB]
repo: rohan_api
base_branch: base
depends_on: []
files:
  - src/onering/types/airflow.types.ts
  - src/onering/enums/run-type.enum.ts
  - src/onering/dto/runs/compliance-run.dto.ts
  - src/onering/dto/runs/index.ts
  - src/utils/feature-flags/types/featureFlags.ts
contracts:
  - "2.1 Enum extensions"
  - "2.2 ComplianceReviewConf interface"
  - "5.1 TriggerComplianceReviewDto + ComplianceRunResponse"
  - "6.1 ONERING_COMPLIANCE feature flag"
verification:
  - npm run lint
  - npm run build
```

**Goal**: Land all rohan_api type and enum surface area without behavior changes. Lays the foundation for subsequent service/controller phases.

**Steps**:

- [ ] **4.1** Extend `OneringDagId` with `COMPLIANCE_REVIEW = 'arc_compliance_review'` in `airflow.types.ts`.
- [ ] **4.2** Extend `RunType` with `COMPLIANCE_REVIEW = 'COMPLIANCE_REVIEW'` in `run-type.enum.ts`. Also extend `RunStatus` with `MATERIALIZING = 'MATERIALIZING'` (intermediate state between Airflow SUCCESS and rohan_api materializer commit; closes the UI race per Contracts §3.2 status transition contract).
- [ ] **4.3** Add `ComplianceReviewConf` interface and extend `DagRunConf` union in `airflow.types.ts`.
- [ ] **4.4** Create `src/onering/dto/runs/compliance-run.dto.ts` with `TriggerComplianceReviewDto`, `ComplianceRunResponse`, `ComplianceRunListItem`, `ComplianceRunListResponse`. Include `class-validator` and `@nestjs/swagger` decorators per Contracts §5.
- [ ] **4.5** Add `ONERING_COMPLIANCE` to `featureFlags.ts` enum. Run `pnpm enable-flag ONERING_COMPLIANCE` is a follow-up DB operation, not a code change.
- [ ] **4.6** Confirm no consumers of `RunType` / `OneringDagId` break (search and verify exhaustive-match handlers). Especially check `OneringPipelineService.refreshRunStatus()` for switch-case completeness.

---

### Phase 5 — DB schema: compliance_items + or_pipeline_runs columns [BACKEND_DB]

```phase-meta
phase: 5
title: DB - compliance_items.arc_run_id/arc_requirement_id/stable_hash, or_pipeline_runs typed columns
tags: [BACKEND_DB]
repo: rohan_api
base_branch: phase-4
depends_on: [4]
files:
  - src/compliance/entities/compliance-item.entity.ts
  - src/onering/entities/or-pipeline-run.entity.ts
  - scripts/sql/<synced-from-Database-repo>.sql
contracts:
  - "3.1 compliance_items additions"
  - "3.2 or_pipeline_runs (typed columns for project_id and document_ids)"
verification:
  - npm run lint
  - npm run build
  - npm run test -- src/compliance/entities
  - npm run db:test:up
```

**Goal**: Land the schema changes first so downstream service code (Phase 6) can write typed columns without conditional gates. Per `rohan_api/CLAUDE.md`, SQL is authored in the `Database/` repo and synced into rohan_api. This phase coordinates both.

**Steps**:

- [ ] **5.1** **In the `Database/` repo**, author a migration script: add `compliance_items.arc_run_id UUID NULL`, `compliance_items.arc_requirement_id VARCHAR(128) NULL`, `compliance_items.stable_hash VARCHAR(64) NULL`, plus the three indexes per Contracts §3.1. Verify on a current dev DB whether `or_pipeline_runs.materialized_at TIMESTAMPTZ NULL`, `or_pipeline_runs.project_id UUID NULL`, and `or_pipeline_runs.document_ids UUID[] NULL` exist; if not, add them in the same migration. Index `or_pipeline_runs (organization_id, project_id, started_at DESC)` for the listing endpoint. **Also** create `compliance_audit_log` (`id` UUID PK, `organization_id` UUID NOT NULL, `project_id` UUID NOT NULL, `arc_run_id` UUID NULL, `action` VARCHAR(64) NOT NULL, `payload` JSONB NOT NULL, `created_at` TIMESTAMPTZ NOT NULL DEFAULT now()) plus index `(organization_id, project_id, created_at DESC)` if it does not already exist (Phase 7 materializer is its first writer). Use `IF NOT EXISTS` everywhere.
- [ ] **5.2** Run the sync script in rohan_api to pull the new SQL into `scripts/sql/`. **Do not edit `scripts/sql/` directly.**
- [ ] **5.3** Add the TypeORM column definitions to `compliance-item.entity.ts` (`arcRunId`, `arcRequirementId`, `stableHash`) and `or-pipeline-run.entity.ts` (`projectId`, `documentIds`, `materializedAt`).
- [ ] **5.4** Verify `or_pipeline_runs.run_type` accepts the new `COMPLIANCE_REVIEW` enum value without DDL — read the existing column definition. If it's a CHECK constraint or DB enum, the constraint also needs updating in the `Database/` repo.
- [ ] **5.5** Run `npm run db:test:up` and confirm the test DB reflects new columns.

---

### Phase 6 — rohan_api: triggerComplianceReview() service method [BACKEND_DB]

```phase-meta
phase: 6
title: rohan_api - OneringPipelineService.triggerComplianceReview()
tags: [BACKEND_DB]
repo: rohan_api
base_branch: phase-5
depends_on: [5]
files:
  - src/onering/services/onering-pipeline.service.ts
  - src/onering/services/onering-pipeline.service.spec.ts
  - src/onering/services/onering-airflow-client.service.ts
  - src/onering/services/onering-org-lookup.service.ts
  - src/onering/services/onering-run-reaper.service.ts
  - src/onering/services/onering-run-reaper.service.spec.ts
  - src/onering/onering.module.ts
contracts:
  - "2.3 OneringPipelineService.triggerComplianceReview()"
  - "2.3 Polling cadence + stuck-run reaper"
  - "1.2 arc_compliance_review DAG dag_run.conf envelope (consumer side)"
verification:
  - npm run lint
  - npm run test -- src/onering/services/onering-pipeline.service.spec.ts
  - npm run test -- src/onering/services/onering-run-reaper.service.spec.ts
```

**Goal**: Add the trigger method that creates `or_pipeline_runs`, calls Airflow, and returns the run handle. Schema (Phase 5) is already in place — write `project_id` and `document_ids` to typed columns directly. Add the stuck-run reaper as a sibling service so a 409 on subsequent triggers cannot lock a project forever.

**Steps**:

- [ ] **6.1** Implement `triggerComplianceReview(orgId, userId, projectId, documentIds, options)` per Contracts §2.3. Resolves `organization_id` via `OneringOrgLookupService`. Generates `arc_run_id` upfront. Writes `project_id` and `document_ids` (resolved to explicit list — empty input MUST be expanded to all current source documents at trigger time, never stored as empty) to typed columns on `or_pipeline_runs`. No JSONB junk-drawer. No flag gating.
- [ ] **6.2** On Airflow trigger 409 (duplicate `dag_run_id`), treat as success — read back the existing run via `getDagRun()` and use that handle. Idempotent retry on transport-error retry storms.
- [ ] **6.3** Mirror error mapping from `launchProposal()`: `OneringAirflowError` on transport failure; row marked FAILED with captured error.
- [ ] **6.4** **Resolve org-mapping policy.** Audit `OneringOrgLookupService` — is it a pass-through (rohan org id == ONERING tenant id) or a real mapping table? If pass-through, drop the indirection in this PR and call sites use `orgId` directly. If real mapping, document bootstrap path: row created on org provisioning via `OneringOrgProvisioningService.ensureOrgMapping(orgId)` called from the org-create handler. Open Q4 closed by this step.
- [ ] **6.5** Add `killDagRun(dagRunId)` to `OneringAirflowClientService`. Used by reaper (6.6) and admin cancel endpoint (Phase 8.7). Tolerates Airflow 404 (run already gone).
- [ ] **6.6** Implement `OneringRunReaperService` per Contracts §2.3 stuck-run reaper. Cron every 5 min via `@Cron(CronExpression.EVERY_5_MINUTES)` on a dedicated reaper handler. Behavior: find `or_pipeline_runs` with `status IN ('PENDING','QUEUED','RUNNING')` AND `started_at < now() - interval '90 minutes'`. For each: re-fetch Airflow status; if Airflow says terminal, transition the row; if Airflow still running but `started_at < now() - interval '180 minutes'` (hard cap), call `killDagRun()` and mark `FAILED` with error code `STUCK_RUN_TIMEOUT`. INSERT `compliance_audit_log` row with `action = 'reaper_force_failed'`. Reaper is global (not per-org); single instance via `SELECT FOR UPDATE SKIP LOCKED` to support multi-pod deploys.
- [ ] **6.7** Pin `refreshRunStatus()` polling cadence per Contracts §2.3 table: 15 s for PENDING/QUEUED, 5 s for RUNNING, stop on terminal. If existing reconciler uses a different cadence, override per-run-type via the existing scheduler primitive — do not introduce a new scheduler.
- [ ] **6.8** Unit tests: happy path, Airflow trigger failure, Airflow 409 idempotent re-handle, empty `document_ids` expansion, idempotency at the row level. Reaper tests: terminal-Airflow-state pickup at >90min, hard-cap kill at >180min, multi-pod lock contention via SKIP LOCKED.
- [ ] **6.9** Wire `OneringRunReaperService` into `OneringModule` providers + the `@nestjs/schedule` registration.

---

### Phase 7 — rohan_api: completion polling, validator, materializer [BACKEND_DB]

```phase-meta
phase: 7
title: rohan_api - run-status polling, schema validator, item materializer
tags: [BACKEND_DB]
repo: rohan_api
base_branch: phase-6
depends_on: [6]
files:
  - src/onering/services/ui-projection-requirements-validator.service.ts
  - src/onering/services/ui-projection-requirements-validator.service.spec.ts
  - src/onering/services/onering-pipeline.service.ts
  - src/onering/services/onering-pipeline.service.spec.ts
  - src/compliance/services/compliance-onering-materializer.service.ts
  - src/compliance/services/compliance-onering-materializer.service.spec.ts
  - src/compliance/listeners/compliance.listener.ts
  - src/compliance/listeners/compliance.listener.spec.ts
  - src/onering/onering.errors.ts
  - src/onering/onering.module.ts
  - src/compliance/compliance.module.ts
contracts:
  - "4.1 Schema validator"
  - "4.2 Materializer behavior"
  - "6.1 ONERING_COMPLIANCE listener fence"
verification:
  - npm run lint
  - npm run test -- src/onering/services/ui-projection-requirements-validator.service.spec.ts
  - npm run test -- src/compliance/services/compliance-onering-materializer.service.spec.ts
  - npm run test -- src/onering/services/onering-pipeline.service.spec.ts
  - npm run test -- src/compliance/listeners/compliance.listener.spec.ts
```

**Goal**: Read the artifact on terminal SUCCESS, validate, drop deletion-during-run items, materialize compliance items via Phase A (read+validate, no DB tx) / Phase B (mutate, single short tx with no network IO) split. PRCR-1570 numbering preserved. Listener fence added in same phase to close the dual-path race window — without it, in-flight rohan-python-api jobs queued before flag flip would race the new materializer.

**Steps**:

- [ ] **7.1** Implement `UiProjectionRequirementsValidatorService` using `ajv` (pin `ajv@^8` explicitly in `package.json` to avoid transitive-version conflict with `class-validator`). Compile schema once at module init. Method `loadAndValidate(arcRunId)` reads from MinIO via `OneringArtifactService` and validates. Validator uses `additionalProperties: true` per Contracts §1.3 versioning rule — strictness lives at the `schema_version` field (rejects unknown versions), not at field-set closure. Throws `OneringSchemaError` on validation failure or unknown `schema_version`.
- [ ] **7.2** Add `OneringSchemaError` to `onering.errors.ts`. Map to 502 in `OneringExceptionFilter`.
- [ ] **7.3** Implement `ComplianceOneringMaterializerService.materialize(arcRunId, dagRunId)` per Contracts §4.2 — strict Phase A (read & validate, no DB tx) / Phase B (mutate, single short tx with no network IO) split.
  - Phase A: SELECT run row (reject if missing — out-of-band trigger defense), load + validate JSON from MinIO, **A4a cross-check** that `json.run_id == or_pipeline_runs.arc_run_id` AND `json.project_id == or_pipeline_runs.project_id` AND `compliance_projects.organization_id == or_pipeline_runs.organization_id`, SELECT current `compliance_documents`, compute drop-set. On any failure here, separate UPDATE marks run FAILED; Phase B never starts. A4a mismatch raises `OneringSchemaError` with code `JSON_RUN_ROW_MISMATCH` — alert wired in Contracts §8.2.
  - Phase B: BEGIN → re-check idempotency latch (`materialized_at` SELECT FOR UPDATE) → match by `(source_document_id, stable_hash)` only → UPDATE matched (preserve `status`, `reviewed_by`, `userNotes`, `lineItemNumber`) → INSERT unmatched with PRCR-1570 numbering → UPDATE supersede (scoped to `dag_run.conf.document_ids` regardless of length) → INSERT audit log rows for drops → UPDATE `materialized_at` → COMMIT.
  - No MinIO reads, no Airflow calls, no `compliance_documents` lookups inside Phase B.
  - Audit log target table `compliance_audit_log` (created in Phase 5). Materializer writes one row per drop with `action = 'materializer_dropped_orphan'`.
  - Document-replacement (new ID) handling per Contracts §4.2 lifecycle table: legacy items NOT auto-superseded — UI nudges user to re-extract (Phase 10 stale-state banner).
- [ ] **7.3a** Add `compliance.listener.ts` fence per Contracts §6.1: short-circuit `tagging.auto-tag-complete` handler when `ONERING_COMPLIANCE` is on for the event's organization. Lookup is per-event via `FeatureService.isEnabledForOrg(organizationId, 'ONERING_COMPLIANCE')`. Skip log line: `compliance.listener.skipped_due_to_onering` with `org_id`, `project_id`, `job_id`. This is the dual-path fence — without it, in-flight rohan-python-api jobs queued before flag flip race the materializer. **Locate the handler by decorator, not line number.** `git grep "@OnEvent('tagging.auto-tag-complete')" src/compliance/listeners/` is the source of truth — the planning doc cites `:379` and `:417` from a now-stale diff and those numbers will drift. PR description includes the resolved location at implementation time. Phase 13 retirement uses the same locate-by-decorator approach.
- [ ] **7.4** Extend `OneringPipelineService.refreshRunStatus()` to handle the new `MATERIALIZING` intermediate state for `run_type === COMPLIANCE_REVIEW`. When Airflow reports terminal SUCCESS: UPDATE the row to `MATERIALIZING` (not `SUCCESS`), then invoke the materializer; the materializer's Phase B9 commits the `SUCCESS` flip atomically with the item writes. Closes the UI race where SUCCESS is observed before items are queryable. Reuse the existing reconciliation service (PRCR-1562) for transient failures. Add `RunStatus.MATERIALIZING` to the run-status enum and update the `OneringRunStatus` switch-case completeness check across the module.
- [ ] **7.5** Add `ComplianceItemStatus.SUPERSEDED = 'superseded'` to `compliance.constants.ts`. **Audit ALL queries against `compliance_items.status` — not just the obvious endpoint.** Grep `from\(.*compliance_items.*\)` and `compliance_items.*status` across the repo; verify each result either: (a) explicitly excludes `SUPERSEDED`, (b) explicitly includes it for an audit/historical use case, or (c) is dead code. Targets to check at minimum: list endpoint, count/aggregation endpoints, export/download paths, dashboard tile services, dependent module queries (analytics, response analysis, matrix export stubs), TypeORM repository helpers, and any CASE WHEN status counts. PR description must enumerate the audited query sites with the chosen filter behavior — no silent ghost items.
- [ ] **7.6** Wire materializer into both `OneringModule` (provider) and `ComplianceModule` (consumer).
- [ ] **7.7** Unit tests: validator (happy path, unknown schema_version, missing field, type mismatch); materializer (insert-only, match-and-update, supersede, document-deletion drop, single-document scoped retry, idempotency latch). Plus a test for `compliance_items.compliance_document_id` population from `source_document_id` (proposal alignment per Contracts §4.2 B5).
- [ ] **7.8** Wire document-deletion-mid-run cancel hook per Proposal §"Document deletion during a run." When a `compliance_documents` row is hard-deleted via the existing delete handler, check if any non-terminal `or_pipeline_runs` reference that doc in `document_ids`. If yes AND deletion would leave the run with zero remaining docs in `compliance_documents`: call `OneringAirflowClientService.killDagRun(airflow_dag_run_id)`, mark the run `FAILED` with code `ALL_DOCUMENTS_DELETED`, write `compliance_audit_log` `action = 'run_cancelled_doc_deletion'`. If deletion still leaves ≥1 doc: do NOT cancel — Phase 7.3 A5 drop-set handles the partial case at materialize time. Wire as a `@OnEvent('compliance.document.deleted')` listener or a synchronous tap in the existing delete service — pick whichever the existing code uses for similar side-effects.

---

### Phase 8 — rohan_api: Compliance controller endpoints + dual-path branching [BACKEND_DB]

```phase-meta
phase: 8
title: rohan_api - Compliance controller endpoints, ONERING_COMPLIANCE feature flag dual-path
tags: [BACKEND_DB]
repo: rohan_api
base_branch: phase-7
depends_on: [7]
files:
  - src/compliance/compliance.controller.ts
  - src/compliance/compliance.controller.spec.ts
  - src/compliance/compliance.service.ts
  - src/compliance/compliance.service.spec.ts
  - src/compliance/compliance.errors.ts
  - src/compliance/dto/compliance-run.dto.ts
  - src/compliance/compliance.module.ts
contracts:
  - "5.1 POST /compliance/projects/:id/onering/extract"
  - "5.2 GET /compliance/projects/:id/onering/runs"
  - "5.3 Modified POST /compliance/projects/:projectId/documents/process"
  - "5.4 POST /compliance/projects/:id/onering/runs/:arcRunId/cancel (admin force-cancel)"
  - "6.1 ONERING_COMPLIANCE feature flag (consumer side)"
verification:
  - npm run lint
  - npm run test -- src/compliance/compliance.controller.spec.ts
  - npm run test -- src/compliance/compliance.service.spec.ts
```

**Goal**: Surface the new endpoints, gate them on the feature flag, and branch the existing `documents/process` endpoint to either path.

**Steps**:

- [ ] **8.1** Add `POST /compliance/projects/:id/onering/extract` per Contracts §5.1. Guards: `AuthGuard('jwt')`, `PermissionsGuard('compliance')`, `FeatureGuard('ONERING_COMPLIANCE')`. Two-stage org check: load `compliance_projects` by `id`, return 404 unless `organization_id == caller.organization_id` (do not distinguish "wrong org" from "missing"). Delegates to `OneringPipelineService.triggerComplianceReview()`. 409 if project has a non-terminal run.
- [ ] **8.2** Add `GET /compliance/projects/:id/onering/runs` per Contracts §5.2. Same two-stage org check as 8.1. Query `or_pipeline_runs` filtered by `organization_id = caller.organization_id` AND `project_id = :id` (typed column from Phase 5). Order by `started_at DESC`, cap at 50. Reuse the existing `ComplianceProjectAccessService` (or equivalent) so org-scope check matches every other compliance endpoint's pattern.
- [ ] **8.3** Modify `POST /compliance/projects/:projectId/documents/process` (`compliance.controller.ts:617`) to feature-detect on `ONERING_COMPLIANCE`. Same two-stage org check. When on, call the new path; when off, existing Service-Bus `AutoTagRequest` flow unchanged. Response shape per Contracts §5.3 with `path: 'legacy' | 'onering'` discriminator.
- [ ] **8.4** Add error classes per Contracts §5.1 errors table (`ComplianceNoDocumentsError`, `ComplianceRunInProgressError`). Map in `compliance.errors.ts` + the existing exception filter.
- [ ] **8.5** Update controller spec + service spec for both paths. E2E test stays under Phase 12.
- [ ] **8.6** Listener fence is implemented in Phase 7.3a (not here). This phase ensures the controller does NOT delete or skip-register the legacy listener — dual-path period needs it for flag-off orgs. Phase 13 deletes the handler entirely after the bake window.
- [ ] **8.7** Add `POST /compliance/projects/:id/onering/runs/:arcRunId/cancel` per Contracts §5.4. Guards: `AuthGuard('jwt')`, `PermissionsGuard('compliance:admin')`, two-stage org check. Delegates to a new `OneringPipelineService.forceCancelRun(orgId, projectId, arcRunId, actorUserId)` that calls `killDagRun()`, marks the row FAILED with `ADMIN_FORCE_CANCEL`, and writes `compliance_audit_log` with `action='admin_force_cancel'`. 409 if run already terminal. Stuck-run reaper (Phase 6.6) handles the > 90 min auto-case; this endpoint covers the < 90 min admin override.
- [ ] **8.8** Update controller + service specs to cover the cancel endpoint: 200 happy path, 403 missing admin role, 404 wrong-org, 409 already-terminal, 502 Airflow non-404 error.

---

### Phase 9 — rohan_api: in-process Airflow mock + dev experience [BACKEND_DB]

```phase-meta
phase: 9
title: rohan_api - in-process Airflow mock for default dev mode
tags: [BACKEND_DB]
repo: rohan_api
base_branch: phase-8
depends_on: [8]
files:
  - src/onering/services/onering-airflow-client.service.ts
  - src/onering/services/onering-airflow-client.service.spec.ts
  - src/onering/__mocks__/airflow-mock.service.ts
  - src/onering/__mocks__/ui_projection_requirements.fixture.json
  - src/onering/onering.module.ts
  - .env.example
  - README.md
contracts:
  - "6.2 In-process Airflow mock"
verification:
  - npm run lint
  - npm run test -- src/onering/services/onering-airflow-client.service.spec.ts
  - "ONERING_AIRFLOW_BASE_URL= npm run start:dev"
```

**Goal**: When `ONERING_AIRFLOW_BASE_URL` is unset and `NODE_ENV !== 'production'`, the client returns a synthetic dag-run handle and writes the fixture artifact to MinIO, letting UI engineers iterate without `make up-airflow`.

**Steps**:

- [ ] **9.1** Implement `AirflowMockService` that, on `triggerDagRun`, writes the fixture (copied from ONERING `tests/fixtures/`) into MinIO via `OneringMinioService` at `AGENT_RUNS/{arc_run_id}/pipelines/ui_projection_requirements/ui_projection_requirements.json`, then returns a fake `dag_run_id`. Schedules a 100 ms timer to flip the corresponding `or_pipeline_runs` row to SUCCESS so the polling pathway materializes items naturally.
- [ ] **9.2** Toggle in `OneringAirflowClientService`: detect `ONERING_AIRFLOW_BASE_URL` empty + `NODE_ENV !== 'production'` + `ONERING_AIRFLOW_MOCK !== 'disabled'` → delegate to the mock.
- [ ] **9.3** Copy `ui_projection_requirements.fixture.json` from ONERING repo into `src/onering/__mocks__/`. Phase 12's CI cross-check keeps them in sync.
- [ ] **9.4** Document the mock in `README.md` + `.env.example` (`ONERING_AIRFLOW_BASE_URL=` left empty for default dev mode; set to `http://localhost:8080` to use real Airflow via `make up-airflow`).
- [ ] **9.5** Tests: unit test that the mock writes the fixture and returns a synthetic handle; integration test that the polling pathway downstream materializes items end-to-end against the mock.

---

### Phase 10 — rohan_ui: extracting state, polling, retry [FRONTEND]

```phase-meta
phase: 10
title: rohan_ui - extracting banner, run polling, retry, error states
tags: [FRONTEND]
repo: rohan_ui
base_branch: base
depends_on: [8]
files:
  - src/app/pages/compliance/types/compliance-run.types.ts
  - src/app/pages/compliance/services/compliance-run.service.ts
  - src/app/pages/compliance/services/compliance-run.service.spec.ts
  - src/app/pages/compliance/components/compliance-page-shell/compliance-page-shell.component.ts
  - src/app/pages/compliance/components/compliance-page-shell/compliance-page-shell.component.html
  - src/app/pages/compliance/components/compliance-extracting-banner/compliance-extracting-banner.component.ts
  - src/app/pages/compliance/components/compliance-extracting-banner/compliance-extracting-banner.component.html
  - src/app/pages/compliance/components/compliance-extracting-banner/compliance-extracting-banner.component.scss
  - src/app/pages/compliance/components/compliance-extracting-banner/compliance-extracting-banner.component.spec.ts
contracts:
  - "7.1 Compliance run types"
  - "7.2 UI states"
verification:
  - npm run lint
  - npm run test:ci -- --include='**/compliance-extracting-banner.component.spec.ts'
  - npm run test:ci -- --include='**/compliance-run.service.spec.ts'
```

**Goal**: When a run is active, show the extracting banner and poll. When a run fails, show retry. Preserve existing tag UI (PRCR-1517/1519/1544) unchanged for the item-review surface.

**Contract-stability gate.** This phase branches off `main` (no cross-repo branch stacking) but **logically depends on Phase 8 contracts being frozen**. Convention: Phase 8 PR includes the OpenAPI / DTO files as the source of truth. UI engineer codes against the contracts doc + Phase 8 PR diff, NOT against a running Phase 8 backend. If a Phase 8 reviewer requests a contract change after Phase 10 is in flight, the contract change must be reflected in this plan's Contracts §5/§7 in the same review cycle, and Phase 10 rebases. Avoid the trap of UI silently drifting from a half-merged backend.

**Steps**:

- [ ] **10.1** Add `compliance-run.types.ts` per Contracts §7.1.
- [ ] **10.2** Add `ComplianceRunService` with `triggerExtract(projectId, body)` calling `POST /compliance/projects/:id/onering/extract` and `listRuns(projectId)` calling `GET /compliance/projects/:id/onering/runs`. Polling helper that resolves on terminal state with 10 s cadence, backing off to 30 s after 5 min.
- [ ] **10.3** New presentational component `compliance-extracting-banner` rendering the five UI states from Contracts §7.2 (`extracting`, `extracting-late`, `failed`, `partial`, `stale`). Accepts a `ComplianceRun` input plus a `currentDocumentIds` input for staleness detection.
- [ ] **10.4** Wire the banner into `compliance-page-shell.component`. Conditional render based on the latest run from `ComplianceRunService.listRuns()` and the project's current `compliance_documents`. Staleness derived client-side: last successful run's `document_ids` set-difference current docs → non-empty = stale. Disable item-edit actions while `extracting`. Show admin force-cancel CTA in `extracting-late` when caller has the admin role.
- [ ] **10.5** Retry handler on the `failed` state calls `triggerExtract` with the same `document_ids` as the failed run. Re-run handler on `stale` state calls `triggerExtract` with the project's current source documents (resolved server-side via empty-input expansion).
- [ ] **10.5a** Admin force-cancel handler on `extracting-late` (admin role only) calls `POST /onering/runs/:arcRunId/cancel`. Confirms via dialog. Surfaces 409 (already terminal) by refreshing run state.
- [ ] **10.6** Existing tag UI components (`compliance-item-card`, `compliance-items-panel`, `compliance-checklist-table`, `compliance-content-section`) untouched. They render items source-agnostic.
- [ ] **10.6a** Audit-trail deep-link per Proposal §"Observability and correlation IDs" line 271. On any `compliance_items` row produced by ONERING (`arc_run_id IS NOT NULL`), the item-card detail surface shows a "View extraction trail" link that opens `/onering/runs/:arcRunId/audit?requirement=:arcRequirementId`. Backend endpoint resolves to MinIO browse URLs at `AGENT_RUNS/{arc_run_id}/llm_calls/{step}/{prompt}/{call_id}/`. Phase 1 ships the link only; the audit-browser route itself can stub to a JSON listing — full audit-browser UI is Phase 2 scope. Gates on caller having `compliance:admin` or `onering:audit` permission to avoid leaking prompt internals to end users.
- [ ] **10.7** Component tests for the banner (each state) and service tests for polling cadence + terminal-state resolution.

---

### Phase 11 — Prod-readiness: SLO, alerting, runbook, secrets, dashboard [TEST_REVIEW]

```phase-meta
phase: 11
title: Prod-readiness - SLO, on-call, alerts, runbook, Key Vault, Grafana
tags: [TEST_REVIEW]
repo: rohan_api
base_branch: base
depends_on: []
files:
  - docs/onering-compliance/slo.md
  - docs/onering-compliance/runbook.md
  - docs/onering-compliance/oncall.md
  - helm/values.yaml
  - helm/templates/rohan-api-configmap.yaml
  - grafana/dashboards/onering-compliance.json
  - grafana/alerts/onering-compliance.yaml
contracts:
  - "8.1 Grafana panels"
  - "8.2 Alerts"
  - "8.3 Correlation IDs"
verification:
  - "helm lint helm/"
  - "promtool check rules grafana/alerts/onering-compliance.yaml"
  - "jq empty grafana/dashboards/onering-compliance.json"
```

**Goal**: First-prod-cutover gate. Counted as a **separate ~3–5 engineer-week pool**, not folded into the integration estimate. Tracked as a parallel workstream from the start of integration work, not a week-3 surprise. Owners assigned at kickoff.

**Steps**:

- [ ] **11.1** Draft `slo.md`: target p95 wall-clock < 30 min for ≤10 documents, error budget, failure-rate target. **Seed with week-1 gate W1.2 measurements** (`docs/onering-compliance/baseline-measurements.md` — total wall-clock, per-step pod cold-start, total LLM cost, slot wait time vs current Service-Bus baseline). Placeholder thresholds get replaced by p50/p95 from real numbers, not vibes. **Stakeholder commit before staging pilot.** The placeholder values cannot ship — alerts in Contracts §8.2 (`ComplianceRunStuck` at 60 min, `ComplianceRunFailureRate` >20% in 30 min) are derived from these numbers. Get product owner sign-off in writing (PR comment or linked Jira ticket) and update the alert thresholds in the same PR if the committed numbers diverge from placeholders. Phase 13 staging-pilot start gated on this checkbox.
- [ ] **11.2** Draft `runbook.md`: stuck run, schema validation failure, pool saturation, materializer failure, document-deleted-mid-run. Each failure mode lists detection signal, immediate mitigation, root-cause investigation steps.
- [ ] **11.3** Draft `oncall.md`: rotation, paging policy by severity, escalation to engine team for `OneringSchemaError`.
- [ ] **11.4** Wire correlation IDs into NestJS request-context async storage per Contracts §8.3. Every log line for a Compliance run carries `correlation_id`, `org_id`, `project_id`, `arc_run_id`, `dag_run_id`, `airflow_dag_id`.
- [ ] **11.5** Key Vault paths for `ONERING_AIRFLOW_USERNAME` / `ONERING_AIRFLOW_PASSWORD` agreed with security; Helm wiring per `rohan_api/CLAUDE.md` Helm conventions. **Log scrubber audit.** Confirm rohan_api's existing log redactor masks the `Authorization` header on every level (info, warn, error) and on every log target (stdout, structured, error tracker). Add a regression test that an `OneringAirflowError` log entry containing the basic-auth-bearing axios config does NOT include the header value verbatim. Misconfigured redactors leak credentials on first prod 500.
- [ ] **11.6** Grafana dashboard JSON per Contracts §8.1. Alert rules YAML per §8.2. SRE review.
- [ ] **11.7** Image registry promotion path validated (rohan_api + ONERING images both in prod registry).
- [ ] **11.8** Network policy: Airflow ingress allows rohan_api egress; rohan_api reads MinIO via existing path.

---

### Phase 12 — CI: airflow opt-in workflow + schema cross-check [TEST_REVIEW]

```phase-meta
phase: 12
title: CI - test:e2e:airflow workflow + schema cross-check
tags: [TEST_REVIEW]
repo: rohan_api
base_branch: phase-9
depends_on: [9, 10, 11]
files:
  - .github/workflows/test-e2e-airflow.yml
  - .github/workflows/onering-schema-check.yml
  - .github/workflows/onering-cost-summary-check.yml
  - test/compliance-airflow.e2e-spec.ts
  - test/fixtures/ui_projection_requirements.fixture.json
  - test/fixtures/cost_summary.fixture.json
  - package.json
contracts:
  - "9.1 test:e2e:airflow opt-in CI workflow"
  - "9.2 Schema cross-check job"
  - "9.4 Cost summary smoke check"
verification:
  - npm run lint
  - "act -j test:e2e:airflow --container-architecture linux/amd64"
  - npm run test:e2e -- --grep compliance-airflow
```

**Goal**: Catch DAG drift, schema drift, pool/timeout regressions in CI on demand or nightly.

**Steps**:

- [ ] **12.1** Add `.github/workflows/test-e2e-airflow.yml` per Contracts §9.1. PR label `test:airflow` and nightly cron.
- [ ] **12.2** Add `.github/workflows/onering-schema-check.yml` per Contracts §9.2. Every PR. Fetches ONERING at the pinned tag, runs the rohan_api validator against the sample fixture, AND asserts byte-equal match between `rohan_api/src/onering/__mocks__/ui_projection_requirements.fixture.json` and the ONERING-side fixture. Closes the manual-sync drift gap.
- [ ] **12.3** Implement `compliance-airflow.e2e-spec.ts` using the existing `TestClientFactory`: triggers `POST /compliance/projects/:id/onering/extract`, polls `GET /onering/runs`, asserts items materialized, asserts retry idempotency, asserts admin force-cancel transitions a stuck synthetic run.
- [ ] **12.4** Add `npm run test:e2e:airflow` script that wraps `npm run test:e2e:ci` with the airflow grep filter.
- [ ] **12.5** Add `.github/workflows/onering-cost-summary-check.yml` per Contracts §9.4. Nightly. Runs the dev-mock pipeline end-to-end and asserts `AGENT_RUNS/{run_id}/cost_summary.json` is present and parses against the schema. Prevents silent regression on the Grafana cost panel data source.
- [ ] **12.6** **Helm parity job lives in the ONERING repo (Phase 3.5).** This step only documents the cross-repo dependency: rohan_api PRs that bump the pinned ONERING ref must be reviewed alongside an ONERING release that has passed `onering-helm-parity.yml`. Phase 13 cutover step references the same gate.

---

### Phase 13 — Cutover: pilot rollout + legacy listener retirement [TEST_REVIEW]

```phase-meta
phase: 13
title: Cutover - pilot rollout, batch enable, legacy listener retire
tags: [TEST_REVIEW]
repo: rohan_api
base_branch: phase-12
depends_on: [12]
files:
  - src/compliance/listeners/compliance.listener.ts
  - src/compliance/listeners/compliance.listener.spec.ts
  - docs/onering-compliance/cutover-log.md
contracts:
  - "10.1 Flag flip plan"
  - "10.2 Listener retirement"
verification:
  - npm run lint
  - npm run test -- src/compliance/listeners/compliance.listener.spec.ts
  - npm run test:e2e -- --grep compliance
```

**Goal**: Flip the flag for staging, then production pilot, then batch. After 2-week clean window, retire the legacy `tagging.auto-tag-complete` handler for the auto-tag path.

**Steps**:

- [ ] **13.1** Enable `ONERING_COMPLIANCE` for one staging org. Run end-to-end happy path + retry path manually. Capture results in `cutover-log.md`.
- [ ] **13.2** Enable for one prod pilot org. 1-week soak with daily Grafana check.
- [ ] **13.3** Batch-enable remaining prod orgs in groups of 5, 24-hour spacing.
- [ ] **13.4** After 2-week clean window post-100%-enable: delete the `@OnEvent('tagging.auto-tag-complete')` auto-tag handler at `compliance.listener.ts:379`. Other listeners (`compliance.auto.tag` enqueue at `:167`, `compliance.response.analyze` at `:65`) remain — they're different event types and not part of the swapped path.
  - **Pre-delete drain check.** Before deletion, confirm rohan-python-api has no in-flight `AutoTagRequest` for any flagged-on org for ≥24h: Service Bus main queue empty, dead-letter queue empty, no `auto_tag_jobs` rows in non-terminal state for those orgs. The Phase 7.3a listener fence has been short-circuiting these for the entire bake window, so this is a final sanity check.
  - **Coordinate** the matching rohan-python-api publish removal in the same release window. Out of scope as a code change in this repo but in scope as a coordination item — file the Python API ticket at start of Phase 13.
- [ ] **13.5** Tag the rohan_api repo `onering-compliance-v1` and update the pinned ONERING git-sync ref to the matching engine release tag.
- [ ] **13.6** Bump the ONERING submodule pin in `rohan-python-api/backend/arc_agent_writer/` to the same engine release tag used in `values-prod.yaml`. Hygiene step per Contracts §1.6 — Phase 1 does not consume the submodule path, but Phase 3's wrapper-layer work depends on the pin. One-line bump PR; coordinated with the rohan-python-api team alongside the listener-removal coordination in step 13.4.

---

## Phase order, dependencies, and parallelism

### File-touch matrix

| Phase | rohan_api files | ONERING files | rohan_ui files | Database/SRE files |
|-------|-----------------|---------------|----------------|---------------------|
| 1 | — | factories/, orchestrator/cost_summary, tests/factories/, tests/orchestrator/ | — | — |
| 2 | — | airflow/dags/, specs/, airflow/CLAUDE.md | — | — |
| 3 | — | helm/onering-airflow/ + .rendered/ baselines, .github/workflows/onering-helm-parity.yml, docs/onering-airflow/sizing-model.md | — | — |
| 4 | onering/types, onering/enums, onering/dto, feature-flags/types | — | — | — |
| 5 | compliance/entities, onering/entities, scripts/sql | — | — | Database/ migration (compliance_items + or_pipeline_runs + compliance_audit_log) |
| 6 | onering/services/{pipeline,airflow-client,org-lookup,run-reaper}, onering/onering.module | — | — | — |
| 7 | onering/services/validator, onering/onering.errors, compliance/services/materializer, compliance/listeners | — | — | — |
| 8 | compliance/{controller,service,errors,module}, compliance/dto | — | — | — |
| 9 | onering/services/airflow-client, onering/__mocks__ | — | — | .env.example |
| 10 | — | — | pages/compliance/{types,services,components} (5 banner states) | — |
| 11 | docs/, helm/, grafana/ | — | — | Key Vault, network policy |
| 12 | .github/workflows/{test-e2e-airflow,schema-check,cost-summary-check}, test/ | — | — | — |
| 13 | compliance/listeners/, docs/ | — | — | — |

No file is touched by two integration phases simultaneously. Phases 4–9 stack on each other in rohan_api (4=types → 5=schema → 6=service → 7=materializer+listener-fence → 8=controller → 9=dev mock); 1–3 stack in ONERING; 10 starts independently in rohan_ui after the contracts are stable (after Phase 4); 11 is parallel from kickoff; 12–13 are sequential post-integration.

### Parallelism options

**Three concurrent streams from kickoff:**

- **Stream A (engine):** Phases 1 → 2 → 3 in ONERING. ~1 engineer.
- **Stream B (rohan_api):** Phases 4 → 5 → 6 → 7 → 8 → 9 in rohan_api. ~1–2 engineers. Phase 5 has a dependency on the `Database/` repo PR landing first; budget 2–3 calendar days for that handoff. Schema-before-service ordering is intentional: Phase 6 writes typed columns added in Phase 5 with no flag gating or commented-out code.
- **Stream C (UI):** Phase 10 starts as soon as Phase 4 lands (contract-stable). ~0.5 engineer.
- **Stream D (prod-readiness, parallel):** Phase 11 from day 1. SRE-led. Owners assigned at kickoff.

**Convergence:** Phase 12 needs Phases 9, 10, 11 green. Phase 13 strictly serial after 12.

### Recommended sequential order with rationale

If forced to a single-thread sequence (one engineer):

1. **Phase 4** (types) — unblocks rohan_api spec writing and rohan_ui interface stubs.
2. **Phase 1** (engine factory) — without this the rest is hypothetical.
3. **Phase 2** (DAG + schema) — schema unblocks the rohan_api validator.
4. **Phase 5** (DB schema) — Database/ repo PR lands first.
5. **Phase 6** (trigger service) — writes typed columns added in Phase 5.
6. **Phase 7** (materializer + validator + listener fence).
7. **Phase 8** (controller + flag dual-path).
8. **Phase 9** (dev mock).
9. **Phase 3** (Helm pool bumps) — only needs to land before staging pilot.
10. **Phase 10** (UI).
11. **Phase 11** (prod-readiness) — best done as parallel workstream from day 1, but if strictly sequential, before Phase 13.
12. **Phase 12** (CI).
13. **Phase 13** (cutover).

The actual recommendation is the four-stream parallel model above; the sequential list exists only as a fallback for solo execution.

---

## Phase context summaries (for coding agents)

Each summary is self-contained — under 150 words — and tells an implementer what the phase produces, what it depends on, and any gotchas.

**Phase 1 (engine factory).** Adds `compliance_review:build_steps` factory in ONERING producing a 7-step graph: ingestion → chunk_plan → `pipelines.requirements` → `pipelines.ui_projection_requirements`. No metadata/structure/evaluation upstream. Output artifact is `AGENT_RUNS/{run_id}/pipelines/ui_projection_requirements/ui_projection_requirements.json`. Also emits `AGENT_RUNS/{run_id}/cost_summary.json` (run-level rollup of LLM cost — single read path for Grafana, replaces aggregating per-call `cost.json` files at query time). Gotcha: `pipelines.requirements` may consume upstream UI projections; if so, factory injects empty defaults, and any required pipeline-internal change is documented in the PR.

**Phase 2 (DAG + schema).** Ships `arc_compliance_review_dag.py` mirroring `arc_launch_proposal_dag.py`, plus `specs/ui_projection_requirements.schema.json` v1. `dag_run.conf` envelope: `{ org_id, user_id, project_id, document_ids, expected_run_id, responding_company?, llm_mode?, verbose? }`. Tags `["arc","compliance","extraction"]`, `max_active_runs=4`. Depends on Phase 1's factory existing. Schema versioning: any rohan_api-breaking change bumps `schema_version` to `"2"`.

**Phase 3 (Helm pools + git-sync pin + Helm parity CI).** Bumps `llm_extraction_pool` to 4 slots, `llm_aggregation_pool` to 2 slots in `airflow-init` job, with the sizing model documented in `docs/onering-airflow/sizing-model.md` (concurrent-run targets, slot-hold, headroom, re-evaluation trigger). Pins `gitSync.ref` in all three env values files to a specific engine release tag — never `main` / a branch — closing the engine-team-can-break-prod gap. Adds `onering-helm-parity.yml` CI job that renders each env, diffs against checked-in baselines under `helm/onering-airflow/.rendered/`, and asserts no env file pins ref to a branch. Initial baselines committed in this phase. SRE reviews `values-prod.yaml` for first prod cutover (capacity, secrets, ingress, network policy).

**Phase 4 (rohan_api types).** Pure type/enum/DTO surface area. Adds `OneringDagId.COMPLIANCE_REVIEW`, `RunType.COMPLIANCE_REVIEW`, `ComplianceReviewConf` interface, `ONERING_COMPLIANCE` feature flag enum, request/response DTOs. No behavior change. Must check `RunType` switch-case completeness in `OneringPipelineService.refreshRunStatus()`.

**Phase 5 (DB schema).** Adds `compliance_items.arc_run_id` UUID, `compliance_items.arc_requirement_id` VARCHAR(128), `compliance_items.stable_hash` VARCHAR(64), and three indexes. Adds typed columns `or_pipeline_runs.project_id` UUID, `or_pipeline_runs.document_ids` UUID[], `or_pipeline_runs.materialized_at` TIMESTAMPTZ if not present (no JSONB junk-drawer). Index `or_pipeline_runs (organization_id, project_id, started_at DESC)` for the listing endpoint. Per `rohan_api/CLAUDE.md`, the SQL is authored in the `Database/` repo and synced via the sync script. **Do not edit `rohan_api/scripts/sql/` directly.** Verify `or_pipeline_runs.run_type` accepts the new enum value. Lands BEFORE Phase 6 service code so writes are unconditional.

**Phase 6 (trigger service + reaper + cadence pin).** Implements `OneringPipelineService.triggerComplianceReview(orgId, userId, projectId, documentIds, options)`. Resolves `organization_id` (resolves Open Q4 — pass-through or real mapping), generates `arc_run_id`, expands empty `documentIds` to all current source documents (audit fidelity — never store empty), inserts `or_pipeline_runs` with `project_id` and `document_ids` in typed columns, calls `OneringAirflowClientService.triggerDagRun()`. Idempotent on Airflow 409 (re-handle existing run via `getDagRun()`). Adds `OneringRunReaperService` cron (every 5 min) that detects stuck runs at >90 min and force-fails at >180 min via `killDagRun()` + `compliance_audit_log` `reaper_force_failed` row. Pins reconciler polling cadence: 15 s for PENDING/QUEUED, 5 s for RUNNING, stop on terminal. No JSONB metadata writes, no flag gating.

**Phase 7 (validator + materializer + listener fence).** Three pieces: (1) `UiProjectionRequirementsValidatorService` (ajv@^8 pinned, `additionalProperties: true`, version-strict on `schema_version`, throws `OneringSchemaError`); (2) `ComplianceOneringMaterializerService.materialize(arcRunId, dagRunId)` with strict Phase A (read+validate, no DB tx, includes A4a JSON-vs-run-row cross-check that defends against out-of-band DAG triggers) / Phase B (mutate, single short tx, no network IO) split — match by `(source_document_id, stable_hash)` only, supersede scoped to `dag_run.conf.document_ids` regardless of length, audit log via `compliance_audit_log` table; (3) `compliance.listener.ts` fence that short-circuits `tagging.auto-tag-complete` when `ONERING_COMPLIANCE` is on for the event's org — closes the dual-path race window. Idempotency latch `or_pipeline_runs.materialized_at`. New status `ComplianceItemStatus.SUPERSEDED`. Document-replace lifecycle: legacy items NOT auto-superseded; UI surfaces `stale` banner.

**Phase 8 (controller + dual-path + admin cancel).** Adds `POST /compliance/projects/:id/onering/extract`, `GET /compliance/projects/:id/onering/runs`, and `POST /compliance/projects/:id/onering/runs/:arcRunId/cancel` (admin force-cancel for the < 90 min window before reaper kicks in). All three endpoints use the two-stage org check: load `compliance_projects` by `id`, 404 unless `organization_id == caller.organization_id`, then query `or_pipeline_runs` with explicit org filter — no project-id-only lookups. Cancel endpoint requires `compliance:admin` permission and writes `compliance_audit_log` `admin_force_cancel`. Modifies `POST /compliance/projects/:projectId/documents/process` to feature-detect on `ONERING_COMPLIANCE` and return discriminated union response (`path: 'legacy' | 'onering'`). Legacy listener stays registered (fence already added in Phase 7) until Phase 13 deletes it. New error classes: `ComplianceNoDocumentsError`, `ComplianceRunInProgressError`. 409 if non-terminal run exists for trigger; 409 if already terminal for cancel.

**Phase 9 (dev mock).** When `ONERING_AIRFLOW_BASE_URL` empty + `NODE_ENV !== 'production'` + `ONERING_AIRFLOW_MOCK !== 'disabled'`, `OneringAirflowClientService.triggerDagRun()` delegates to `AirflowMockService` which writes the fixture artifact through `OneringMinioService` and schedules a 100 ms status flip. Polling pathway downstream is the same as prod. Fixture file kept in sync with ONERING via Phase 12 CI cross-check.

**Phase 10 (UI).** Adds `ComplianceRunService` (trigger + list + poll + cancel), `compliance-extracting-banner` component, **five** UI states (`extracting`, `extracting-late`, `failed`, `partial`, `stale`). `stale` triggered when last run's `document_ids` set-difference current `compliance_documents` is non-empty (replacement-by-new-id case). Wired into `compliance-page-shell`. Polling cadence 10 s active → 30 s after 5 min → stop on terminal. Admin force-cancel CTA in `extracting-late` (admin role only). Existing tag UI components untouched. Retry handler reuses last run's `document_ids`; re-run on `stale` reuses current source documents.

**Phase 11 (prod-readiness).** SLO doc, runbook, on-call doc, correlation-ID async-storage wiring, Key Vault paths for Airflow basic-auth credentials, Helm config-map wiring, Grafana dashboard JSON, alert rules YAML, image registry promotion verified, network policy verified. **Tracked as a parallel workstream from kickoff with named owners — not a week-3 surprise.** Counted as ~3–5 engineer-week pool separate from integration estimate.

**Phase 12 (CI).** Adds `test:e2e:airflow` opt-in workflow (PR label `test:airflow` + nightly cron), `onering-schema-check` per-PR job that validates the rohan_api ajv compiler against the ONERING-side fixture AND asserts byte-equal sync between the rohan_api dev mock fixture and the ONERING fixture (closes the manual-sync drift gap), and `onering-cost-summary-check` nightly job that runs the dev-mock pipeline and asserts `cost_summary.json` parses against §1.5 schema. Plus `compliance-airflow.e2e-spec.ts` exercising trigger → poll → materialize → retry → admin force-cancel. Helm parity job lives in the ONERING repo (Phase 3.5) — rohan_api PRs that bump the pinned ONERING ref must reference an ONERING release that passed parity.

**Phase 13 (cutover).** Flag flip per stage: staging org → prod pilot org (1-week soak) → batches of 5 (24-hour spacing). After 2-week clean window, delete the `tagging.auto-tag-complete` handler at `compliance.listener.ts:379` and coordinate the matching rohan-python-api publish removal. Tag rohan_api `onering-compliance-v1`; pin ONERING git-sync ref to the matching engine release.

---

## Jira (epic + per-phase tickets)

This work is an **epic** with one subticket per phase. Suggested epic + ticket shape:

### Epic — `onering-compliance-integration`

**Title:** ONERING Integration — Phase 1: Compliance launch via Airflow

**Description:** Replace the Compliance auto-extraction Service-Bus path with an Airflow-orchestrated `arc_compliance_review` DAG that reuses ONERING's `pipelines.requirements`. Reuses the existing `/onering/*` namespace, `or_pipeline_runs` run metadata, `OneringAirflowClientService`, `OneringArtifactService`, `OneringExceptionFilter`. Ships behind `ONERING_COMPLIANCE` feature flag with dual-path during rollout. Phase 1 of `ONERING_INTEGRATION_PROPOSAL.md`. First production cutover of the ONERING Airflow stack — prod-readiness tracked as a parallel workstream.

**Acceptance criteria:**

- [ ] Phase 1: Engine `compliance_review:build_steps` factory produces 7-step graph; emits `cost_summary.json` run-level rollup; passes engine PR review.
- [ ] Phase 2: `arc_compliance_review` DAG ships with v1 JSON Schema for `ui_projection_requirements.json`; DAG unit test green.
- [ ] Phase 3: Helm pools bumped (`llm_extraction_pool=4`, `llm_aggregation_pool=2`) with sizing model documented; `gitSync.ref` pinned to engine tag (no `main`) in all envs; `onering-helm-parity.yml` CI job + checked-in baseline renders; `values-prod.yaml` SRE-reviewed.
- [ ] Phase 4: rohan_api enums, types, DTOs, and `ONERING_COMPLIANCE` feature flag landed.
- [ ] Phase 5: `compliance_items.arc_run_id`/`arc_requirement_id`/`stable_hash` columns + `or_pipeline_runs.project_id`/`document_ids`/`materialized_at` typed columns + `compliance_audit_log` table + indexes applied via Database/ repo sync. Lands BEFORE Phase 6.
- [ ] Phase 6: `OneringPipelineService.triggerComplianceReview()` implemented and unit-tested. Writes typed columns added in Phase 5; idempotent on Airflow 409. `OneringRunReaperService` cron force-fails stuck runs at >90/180 min. Reconciler polling cadence pinned (15s/5s).
- [ ] Phase 7: schema validator (additive-tolerant, version-strict) + materializer with strict Phase A / Phase B split + JSON-vs-run-row A4a cross-check + `(source_document_id, stable_hash)`-only match + PRCR-1570 numbering + scoped supersede + document-deletion drop + audit log + idempotency latch + listener fence on `tagging.auto-tag-complete`.
- [ ] Phase 8: `POST /compliance/projects/:id/onering/extract`, `GET /compliance/projects/:id/onering/runs`, `POST .../onering/runs/:arcRunId/cancel` (admin force-cancel), and feature-flagged `documents/process` dual-path live.
- [ ] Phase 9: in-process Airflow mock when `ONERING_AIRFLOW_BASE_URL` unset; UI engineers iterate without `make up-airflow`.
- [ ] Phase 10: extracting banner, polling, retry, **five** error states (incl. `stale` for replaced docs); admin force-cancel CTA in `extracting-late`; existing tag UI untouched.
- [ ] Phase 11: prod-readiness — SLO, runbook (incl. reaper + force-cancel + JSON-mismatch flows), on-call, correlation IDs, Key Vault, Grafana dashboard (cost from `cost_summary.json`, reaper/cancel counters), alerts (incl. `OrgConsistencyMismatch`, `ComplianceRunReaperFiring`).
- [ ] Phase 12: `test:e2e:airflow` opt-in workflow + `onering-schema-check` per-PR job (incl. mock-vs-engine fixture sync) + `onering-cost-summary-check` nightly job.
- [ ] Phase 13: pilot rollout to one prod org with 1-week soak, batch-enable remaining orgs, retire legacy `tagging.auto-tag-complete` listener after 2-week clean window with pre-delete drain check, bump prod `gitSync.ref` to engine release matching `onering-compliance-v1`.

### Per-phase subtickets

One subticket per phase, named `<epic>/phase-N — <title>`. Subticket descriptions copy the phase block from this plan verbatim plus a link back to the epic and the contracts doc.

---

## Tech stack reference

| Layer | Stack |
|-------|-------|
| Frontend | Angular 19, SCSS, Karma/Jasmine |
| Backend (rohan_api) | NestJS 10, Fastify, TypeScript, TypeORM, Jest, ajv |
| Engine (ONERING) | Python 3.x, Airflow 3.x, Helm, KubernetesExecutor |
| Database | PostgreSQL + pgvector (schema authored in `Database/` repo, synced) |
| Storage | MinIO (run-keyed `AGENT_RUNS/{arc_run_id}/...`) |
| Auth | JWT via Auth0/Okta; Airflow basic-auth via Key Vault |
| Messaging | Service Bus (legacy auto-tag path, retired Phase 13) |

---

## Out of plan but worth flagging

- **Azure Government (`.us`) feasibility.** Per user direction: not in scope for Phase 1, mentioned here as a follow-up. `ONERING_COMPLIANCE` flag stays off for Gov orgs at launch. Spike scope: does the ONERING Airflow Helm chart deploy cleanly to Gov AKS; does the OpenAI client respect the `.us` endpoint switch; image registry promotion to Gov registry. File a separate ticket post-launch.
- **Custom step-graph governance.** As more module-specific factories ship (`compliance_review`, eventually `mra_assistant`, `ae_v2`), step-name collisions and prompt drift become real. Suggest a registry pattern in ONERING — modules register namespaced prefixes and the orchestrator validates uniqueness. Not a Phase 1 blocker, but worth filing as a follow-up.
- **Engine version contract enforcement.** Pinned Airflow git-sync ref + JSON Schema validator + Phase 12 CI cross-check is the Phase 1 mitigation. A versioned engine API surface (proper SemVer) is deferred to proposal Phase 3.
