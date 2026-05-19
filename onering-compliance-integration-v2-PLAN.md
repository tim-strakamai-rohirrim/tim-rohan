# onering-compliance-integration (v2) — Plan

Phased implementation plan for **Phase 1** of `ONERING_INTEGRATION_PROPOSAL.md`: Compliance launch on ONERING via Airflow, **with the engine emitting the canonical `compliance_matrix.json` (and `response_check.json`) artifacts** rather than the thin `ui_projection_requirements.json`. This document treats the integration as a single epic spanning three repos (ONERING, rohan_api, rohan_ui). Each phase below is independently implementable as a single PR with its own subticket.

Diff vs v1 (`onering-compliance-integration-PLAN.md`):

- **Engine emits `compliance_matrix.json`**, not `ui_projection_requirements.json`. Step factory expands from option 2 (thin) to option 1 (full pipeline): ingestion → chunk_plan → metadata → structure → evaluation → instructions → attachments → requirements → attachment_requirement_traceability → response_guidance → budget_allocation → compliance_matrix → ui projections.
- **Adds `arc_compliance_response_check` DAG** producing `response_check.json` per response-document analysis run. This is proposal Phase 2 work pulled into Phase 1 because the materializer needs the contract locked at the same time.
- **Materializer is split**: one for source-doc extraction (reads `compliance_matrix.json`, flattens hierarchy into `compliance_items`, persists JSON pointer for future hierarchical surfaces); one for response-doc analysis (reads `response_check.json`, writes `compliance_checks` + `compliance_item_evidence`).
- **Scope inflation**: ~3–5 additional engineer-weeks for the engine response-check pipeline; ~1.5–3× LLM cost per source-doc run because the full step graph runs metadata + structure + evaluation + instructions + attachments + response_guidance + page_budget + compliance_matrix in addition to requirements.
- **Two fallback gates still apply.** Week-1 / week-2 criteria expand to cover both DAGs.

Companion: `onering-compliance-integration-v2-contracts.md` (API, DTO, schema, frontend types) — needs to be authored alongside this plan; current `onering-compliance-integration-contracts.md` refers to the v1 thin artifact and is superseded.

---

## Problem statement

Compliance auto-extraction today runs through Service Bus → rohan-python-api → `tagging.auto-tag-complete` event → `compliance.listener.ts` materializer (extracts source-document requirements into `compliance_items`). Response analysis runs through a sibling `compliance.response.analyze` event that creates `compliance_checks` rows per (item × response document) pair with `compliance_item_evidence` snippets.

The v2 proposal replaces **both** transports with Airflow-orchestrated DAGs that emit the canonical engine JSON shapes:

- `arc_compliance_review` → `compliance_matrix.json` (the same artifact ONERING already produces today via `pipelines.compliance_matrix` for proposal launches). Contains `solicitation_metadata`, `compliance_checklist_items`, hierarchical `compliance_matrix` rows (structure → evaluation → requirement → sources → writing), `response_guidance_contract`, `page_budget_contract`, `attachment_requirement_traceability`, `package_wide_groups`, and multi-topic variants.
- `arc_compliance_response_check` → `response_check.json` (NEW pipeline; no current ONERING equivalent). Contains per-item automated pass/fail with evidence spans extracted from the response document(s).

The benefit over v1's thin `ui_projection_requirements.json` shape: one engine call produces every datum the compliance UI surfaces could ever want (solicitation overview, attachment inventory, page budgets, response guidance) instead of leaving each future surface to either re-extract or graft new fields onto the v1 schema. The cost: ~1.5–3× LLM cost and wall-clock per source-doc run (full pipeline vs. requirements-only), plus genuinely-new engine work for the response-check pipeline. Compliance is pre-production, which makes this the cheapest moment to commit. It is also the **first production cutover of the ONERING Airflow stack** — the namespace and Helm chart exist and run in dev/staging, but no DAG has shipped to prod yet. Phase 1 v2 therefore carries a "three firsts at once" cost: full-pipeline DAG plus new response-check DAG plus first prod cutover.

## Key architectural observations

- **`/onering/*` namespace in rohan_api is mature.** `OneringPipelineService`, `OneringAirflowClientService`, `OneringArtifactService`, `OneringExceptionFilter`, `or_pipeline_runs` table, `OneringDagId` / `RunType` enums. Phase 1 v2 *extends* this; it does not build a parallel stack. Reference pattern: `arc_launch_proposal_dag.py` + `OneringPipelineService.launchProposal()`.
- **Airflow stack (`ONERING/airflow/`) runs in dev and staging.** Helm chart `helm/onering-airflow/` with `values-{dev,staging,prod}.yaml`. KubernetesExecutor with per-task pod resource profiles. Pools `llm_extraction_pool` (2 slots) and `llm_aggregation_pool` (1 slot) are shared across all DAGs. v2's larger step graph + the second DAG bumps pool sizing more aggressively than v1 (`llm_extraction_pool=6`, `llm_aggregation_pool=3`; see Phase 4).
- **`compliance_items` already supports auto-extraction.** `extractionMethod`, `lineItemNumber` (PRCR-1570 sequential numbering with pessimistic lock), `documentStartLine`/`documentEndLine`, `status`, `userNotes`. v2 adds three columns to it (`arc_run_id`, `arc_requirement_id`, `stable_hash`) and three to `compliance_checks` (`arc_run_id`, `arc_response_check_id`, `stable_hash`) so the response-check materializer can match-and-update the same way.
- **`compliance_matrix.json` already exists in ONERING.** Produced by `_step_pipelines_compliance_matrix` (cli.py:15542) → `build_compliance_matrix()` → `build_compliance_json()` at `pipelines/compliance_matrix/json_builder.py:2143`. Output relpath `pipelines/compliance_matrix/ui/compliance_matrix.json`. Today this is an internal artifact consumed by the ONERING writer (section_runner, volume_assembler, cross_reference_matrix), the XLSX renderer, and the MCP server's extraction tools. **Not consumed by rohan_api or rohan_ui yet** — Phase 1 v2 is the first external consumer, which is exactly why locking the JSON Schema in Phase 2 matters.
- **`response_check.json` does NOT exist in ONERING today.** There is no current `pipelines.response_check` package. The proposal calls this out as "genuinely new ONERING capability" (line 367) and Phase 1 v2 is the engine work to ship it. Reference pattern at the design level: the existing rohan_api `compliance.response.analyze` flow (per-item KM retrieval + automated status PASS/FAIL + evidence-span extraction from response documents).
- **Existing listeners at `compliance.listener.ts:65` (`compliance.response.analyze`) and `:379` (`tagging.auto-tag-complete`)** are the dual-path counterparts to the two new DAGs. Phase 1 keeps both intact during the dual-path window; Phase 14 retires both after bake.
- **`cli.py` is ~17K lines and growing weekly.** Engine version contract is mandatory: pinned Airflow git-sync ref + **two JSON Schemas** (`compliance_matrix.schema.json` v1 and `response_check.schema.json` v1) + CI cross-check on both. v2 doubles the schema surface area, so the contract carries more risk than v1's single schema.
- **Schema changes ownership.** Per `rohan_api/CLAUDE.md`, schema changes live in the separate `Database/` repo and sync into rohan_api via a manual script. Plan respects that ownership.
- **Step factory chosen up front: option 1** (`compliance_review:build_steps`) — full pipeline graph emitting `compliance_matrix.json`. Decision committed by user; week-1 fallback to option 2 (ship the thin `ui_projection_requirements.json` shape and defer the full matrix to Phase 2) only fires if the cost/latency spike at W1.2 reveals a >3× regression vs the rohan-python-api baseline.
- **Second step factory: `response_check:build_steps`** — new step graph for response-document analysis: ingestion → chunk_plan → per-item KM-retrieve over the response doc → automated status + evidence span emission → `pipelines.ui_projection_response_check`. Engine-side responsibility, Phase 3 of this plan.

## Assumptions

1. The full pipeline (option 1) factory can run all of `pipelines.metadata`, `pipelines.structure`, `pipelines.evaluation`, `pipelines.instructions`, `pipelines.attachments`, `pipelines.requirements`, `pipelines.attachment_requirement_traceability`, `pipelines.response_guidance`, `pipelines.budget_allocation`, and `pipelines.compliance_matrix` end-to-end against the Compliance source-document corpus without RFP-launch-specific quirks. Phase 1 confirms this in the engine PR using the staging fixture set; if any pipeline assumes proposal-launch context (e.g., a `responding_company` requirement we cannot satisfy at extract time), the factory injects safe defaults or the pipeline gets a no-op short-circuit, documented in the PR. If the fixes are non-trivial, scope grows by ~3–5 engineer-days and lands in Phase 1's engine work, not as a new phase.
2. **`pipelines.response_check` does not exist yet** and Phase 3 is a genuine engine-build phase, not a wiring phase. Reference architecture: one LLM call per (item × response document) chunk plan, output schema matches the v1 `response_check.json` shape in Contracts §1.9. Slot accounting: budget for one response-check run to consume `llm_extraction_pool` for the duration of the analysis; conservatively 1–3× the wall-clock of a source-doc extraction.
3. The existing `OneringPipelineService.refreshRunStatus()` polling cadence (used for proposal launch) is acceptable for both Compliance latency profiles. No new scheduler primitive needed. Both DAGs share the same polling state machine; only `run_type` differs.
4. `or_pipeline_runs.run_type` column is `varchar` and accepts the two new enum values (`COMPLIANCE_REVIEW`, `COMPLIANCE_RESPONSE_CHECK`) without DDL change. Verified by reading the existing migration before Phase 6 lands.
5. PRCR-1570's pessimistic lock can be reused inside the source-doc materializer transaction. The materializer calls the same numbering helper used by the manual create path. Response-check materializer does not need numbering (checks are keyed by `(response_id, compliance_item_id)` which already has a unique constraint).
6. rohan-python-api stays untouched in Phase 1 v2. Both Service Bus paths (auto-tag + response-analyze) remain live behind the feature flag during dual-path; Phase 14 retires both.
7. Single Airflow trigger per project per request for source-doc extraction; single trigger per response per request for response-check. Multi-document source-doc runs use one `dag_run.conf.document_ids` array; multi-document response-check runs use one `dag_run.conf.response_document_ids` array (typically the response itself is one doc, but accommodate multi-file responses).
8. Polling completion is sufficient. No webhook callback (proposal §"DAG → rohan_api completion mechanism" line 209 explicitly rejects inbound webhooks: would require new auth + idempotency + ingress rules with no UX benefit over polling). Service Bus completion publish from the CLI is Phase 2 of the proposal — not in scope here.
9. `or_pipeline_runs.materialized_at` is the idempotency latch for **both** materializers. Same column, different `run_type`. Phase 6 ensures it exists.
10. Feature flag `ONERING_COMPLIANCE` is org-scoped via the existing `OrganizationFeaturesService` JSON-blob source. The `FeatureGuard` already understands org-level feature gating. Same flag gates both DAG paths to avoid a half-flipped state where source-doc extraction goes through ONERING but response analysis still goes through Service Bus (or vice versa) — that would surface inconsistent `arc_run_id` provenance across `compliance_items` and `compliance_checks`.
11. The hierarchical `compliance_matrix` array in `compliance_matrix.json` can be deterministically flattened to `compliance_items` rows via a stable hash over `(source_document_id, requirement_id, paragraph_indicator_normalized)`. Phase 8 materializer freezes this hash function; any future engine-side change to it bumps `schema_version`. The hierarchy itself is preserved by persisting the JSON pointer on the run row so future hierarchical UI surfaces can read it without re-extracting.

## Open questions

| # | Question | Default answer |
|---|----------|----------------|
| 1 | Does the full pipeline (option 1) factory run end-to-end against the Compliance corpus without proposal-launch-specific quirks? Validated where in the engine PR? | Engine-side behavioral test on the staging fixture set: factory invoked with Compliance-style `dag_run.conf` (no `responding_company`, no `responding_entity` deep-research) emits all expected artifacts including a non-empty `compliance_matrix.json`. Phase 1 PR is blocked on this passing. |
| 2 | Does `or_pipeline_runs` already have a `materialized_at` column or equivalent idempotency latch? | Assume no. Phase 6 adds it. |
| 3 | Does PRCR-1570's numbering helper expose a callable for batched insert? Or only a per-row API? | If per-row only, source-doc materializer loops within the transaction; acceptable for the typical 50–500-item project. Revisit if profiling shows lock contention. |
| 4 | Where does `OneringPipelineService` persist `project_id` / `response_id` for a given `arc_run_id`? Is there a side table or a JSON column on `or_pipeline_runs`? | Typed columns on `or_pipeline_runs`: `project_id UUID NULL`, `response_id UUID NULL`, `document_ids UUID[] NULL`. `run_type` discriminates which is populated (`COMPLIANCE_REVIEW` → project_id+document_ids; `COMPLIANCE_RESPONSE_CHECK` → response_id+document_ids). No JSONB junk-drawer. Phase 6 covers this; service consumers (Phase 7, Phase 8) read the typed columns directly. |
| 5 | Does the existing `OneringMinioService` know how to read fixture artifacts during the in-process mock, or does the mock write through it? | Mock writes through `OneringMinioService` so the read path is identical to prod. Both fixture artifacts (`compliance_matrix.json` + `response_check.json`) are written this way. Phase 10 verifies this. |
| 6 | Is `OneringAirflowClientService.killDagRun(dag_run_id)` already exposed? | Not needed before Phase 7's stuck-run reaper. Added there alongside the admin force-cancel endpoint (Phase 9.8). |
| 7 | Do prod Helm values for `onering-airflow` exist and just need pool count bumps, or does the prod values file need full review? | `values-prod.yaml` exists per the proposal. Phase 4 reviews + bumps to `llm_extraction_pool=6` and `llm_aggregation_pool=3`; SRE owns sign-off. |
| 8 | Is there an existing `compliance_run_documents` join/audit table for tracking which documents were included in a run? | No new join table. Phase 6 stores `document_ids` as a typed UUID[] column on `or_pipeline_runs`. Re-evaluate if multi-document audit queries become hot. |
| 9 | What is the SLO target for `arc_compliance_review` and `arc_compliance_response_check` end-to-end? | Stakeholder input needed. Default placeholder for review: p95 wall-clock < 45 min for ≤10 documents (up from v1's 30 min — full pipeline is heavier). Default for response-check: p95 wall-clock < 10 min per response. Surfaces in Phase 12 prod-readiness ticket. |
| 10 | Azure Government (.us) — proposal calls this a follow-up. Confirm Gov orgs are flagged off for Phase 1 launch and the spike is a separate ticket. | Conditional. **If no Gov customer in scope for launch:** flagged off, spike post-launch (this is the current default). **If a Gov customer is in scope (decided at week-1 gate W1.5):** spike runs in week 1 alongside engine work, NOT post-launch. Decision logged in writing per W1.5 evidence row. |
| 11 | Should the rohan_api materializer persist the full `compliance_matrix.json` (e.g., on `compliance_projects.compliance_matrix_json_key`) or only the run-row pointer to `or_pipeline_runs.arc_run_id`? | Persist a pointer column on `compliance_projects`: `compliance_matrix_json_url VARCHAR(2048) NULL` (MinIO key, NOT presigned URL — presigns expire). Cleared on document-set change so the UI can never serve a stale matrix. Phase 6 adds the column; Phase 8 writes it; Phase 9.5 adds the read endpoint. Empty list of writers today means the cost of getting the storage shape wrong is low, but the cost of needing it later and not having it is high. |
| 12 | The hierarchical `compliance_matrix.json` includes `package_wide_groups`, `response_guidance_contract`, `page_budget_contract`, `attachment_requirement_traceability` — does v2's materializer surface these as `compliance_items` rows? | No. Only the flat `compliance_matrix[]` array (one row per leaf requirement) maps to `compliance_items`. The other top-level keys stay JSON-only and are exposed via the matrix-JSON read endpoint (Q11). Today's UI doesn't render them; future hierarchical UI surfaces (proposal-engine compliance step, response-guidance side panel) consume the JSON directly. |
| 13 | Should `response_check.json` rows match the existing `compliance_checks.automatedStatus` enum (`PASS`/`FAIL`) or introduce a third bucket (`INDETERMINATE`)? Today's listener emits only PASS/FAIL based on `metadata.status === 'fail'` per-tag. | Match the existing enum exactly: `PASS` / `FAIL`. The engine MAY emit per-item `confidence` and `rationale` strings that the materializer persists into `compliance_checks.user_notes` (or a new column, Phase 6 decides). Adding a third enum value is a separate, larger change. |

## Non-goals (deferred to later phases of the proposal)

- Service Bus completion publish from CLI (proposal Phase 2 upgrade path). Polling stays in Phase 1.
- Anything in `compliance_matrix.json` that the current rohan_api/rohan_ui consumers don't need: `package_wide_groups`, hierarchical multi-topic variants, the full `response_guidance_contract` and `page_budget_contract` payloads — emitted by the engine and persisted as JSON blob (Q11), but **not** wired into any new rohan_ui surface in Phase 1 v2. Future UI work (proposal-engine compliance step, response-guidance side panel) consumes them as a follow-up.
- **No XLSX consumer wiring in Phase 1 v2.** The full-pipeline DAG produces `compliance_matrix.xlsx` as a free byproduct (already implemented in ONERING). Surfacing the workbook download in rohan_ui is a one-line `OneringArtifactService` read at the controller layer; it is added as a stretch goal in Phase 11.5 but not on the critical path.
- rohan-python-api wrapper layer for fast inline ops — proposal Phase 3.
- Anything for Answer Engine v2 or Acquisition Center.
- **Azure Government (`.us`) feasibility** — conditional follow-up. Default: Gov orgs flagged off at launch, spike scoped post-launch (Helm-chart-on-Gov-AKS, OpenAI-`.us`-endpoint-routing, image registry promotion to Gov registry). **Override:** if a Gov customer enters scope at the week-1 gate (W1.5), the spike pulls into Phase 1 week-1 work, not post-launch. Either path decided in writing at gate close-out.

### Brought in from proposal Phase 2 (NEW vs v1 plan)

- **Response-analysis DAG** (`arc_compliance_response_check`) — proposal-Phase-2 work pulled forward because the engine artifact shape needs to be locked at the same time as the source-doc matrix shape. Phase 3 of this plan ships the engine pipeline; Phase 7/8 ship the rohan_api integration. Adds ~3–5 engineer-weeks vs v1.
- **Five additional extraction tabs** (structure, evaluation, instructions, attachments, metadata) — folded into the source-doc DAG as upstream pipelines so they all land in the same `compliance_matrix.json`. No separate phases; cost shows up as full-pipeline run time. The actual *UI surfacing* of these tabs is still deferred — Phase 1 v2 ships the data, not the UI.

---

## Fallback gates (week-1 + week-2)

Per `ONERING_INTEGRATION_PROPOSAL.md` non-negotiable line 524 ("Two fallback gates, not one"). Slipping a 6–8 week integration at week 4 is much more expensive than slipping at week 2. Each gate has a hard-fall-back path: ship Compliance on the existing Service-Bus + rohan-python-api architecture and treat the ONERING migration as Phase 2 work. Pre-production status keeps the fallback cheap.

### Week-1 gate (continue / fall back)

Required green by end of calendar week 1 from kickoff:

| # | Criterion | Owner | Evidence |
|---|-----------|-------|----------|
| W1.1 | Source-doc DAG running locally end-to-end with sample data; writes `compliance_matrix.json` to MinIO via run-keyed path. | Stream A (engine) | Demo + MinIO artifact path |
| W1.1b | Response-check DAG running locally against a sample response document; writes `response_check.json` with at least one PASS and one FAIL row. Pipeline does NOT need to be production-quality at week 1 — fixture-driven happy path is sufficient. | Stream A (engine) | Demo + MinIO artifact path |
| W1.2 | Cost & latency spike on representative RFP. Records: total wall-clock, per-step pod cold-start, total LLM cost, slot wait time. Compared to current Service-Bus extraction. **Both DAGs measured separately.** | Stream A + Stream B | Numbers committed to `docs/onering-compliance/baseline-measurements.md` |
| W1.2b | **Cost regression check.** If source-doc full-pipeline run shows >3× LLM cost regression vs. current Service-Bus baseline at p50, escalate to product/engineering lead within 48 hours to decide: (a) ship anyway, (b) fall back to v1's thin option-2 step graph and ship matrix-JSON as Phase 2, or (c) optimize. >3× is the threshold because it represents real per-customer impact. | Stream A + product | Cost numbers + decision logged in PR |
| W1.3 | Completion-mechanism end-to-end (local). rohan_api triggers BOTH DAGs, polls to terminal state, materializes items via `OneringArtifactService`. Includes schema validators (two: matrix + response_check) + deletion-during-run check. | Stream B | E2E test passing locally |
| W1.4 | Prod-readiness checklist drafted with named owners. Not done — drafted. | Stream D (SRE-led) | `docs/onering-compliance/prod-readiness.md` with owner names |
| W1.5 | Azure Gov in-scope decision. Confirmed in writing whether any current customer or near-term sales prospect is on `.us`. If yes: Gov spike scoped and assigned this week (not deferred). If no: flag-off-for-Gov decision logged. | Product + Stream B | PR comment or Jira ticket |

**Fallback trigger.** Any of W1.1, W1.2, W1.3, W1.4 red at end of week 1 → team commits to launching Compliance on the existing Service-Bus path and re-files the ONERING migration as Phase 2 work. W1.1b red (response-check DAG specifically struggling) → fall back to **v1's plan** (ship matrix-only, keep response analysis on the existing rohan-python-api path), do not abandon the whole integration. W1.2b at the >3× threshold without an optimization path → same v1 fallback. W1.5 red → spike landed by week 2 OR Gov orgs flagged off explicitly.

### Week-2 gate (continue / fall back, second checkpoint)

Required green by end of calendar week 2:

| # | Criterion | Owner | Evidence |
|---|-----------|-------|----------|
| W2.1 | Step-graph decisions committed (option 1 full-pipeline factory for source docs + new response_check factory). Engine-side work scoped and assigned. Believable end-of-week-4 delivery date for **both** factories. | Stream A | Phase 1 + Phase 3 PRs open |
| W2.2 | ONERING-repo PRs open and progressing. Reviewers identified, review cadence confirmed, no surprise blockers. Response-check pipeline reviewer assigned (it is new code, not wiring). | Stream A | PR links + reviewer comments |
| W2.3 | rohan_api integration code merged behind feature flag for source-doc path (DAG trigger, polling, item materialization, schema validator, dev mock). Response-check rohan_api path may still be in flight at end of W2 — soft target. | Stream B | Merged PRs for Phases 5–9 (source-doc); in-flight for response-check |
| W2.4 | Prod-readiness checklist progressing. SLO + on-call ownership decided **for both DAGs** (the response-check DAG carries different failure modes — e.g., a single FAIL row materially impacts reviewer workflow whereas an extraction error is detectable). Secrets + Key Vault paths agreed with security. Helm prod values reviewed by SRE. | Stream D | Checklist updated |
| W2.5 | No engine-side breaking change has landed in `cli.py` pipelines, `compliance_matrix.json` shape, or the in-flight `response_check.json` design since the pinned tag. | Stream A | Diff check vs pinned tag |

**Fallback trigger.** Any of W2.1, W2.2, W2.4, W2.5 red at end of week 2 → same fallback path as week 1. W2.3 red specifically for response-check while source-doc is green → narrow fallback to **v1's plan** (ship matrix-only via ONERING, keep response analysis on Service-Bus path); the response-check DAG re-attempts as proposal Phase 2 work. Calendar-cheaper than slipping at week 3 or 4.

### Tracking

Both gates carry their own subticket under the epic (`<epic>/gate-week-1`, `<epic>/gate-week-2`) with the criteria above as acceptance items. Engineering lead closes the gate ticket with a one-line green/red call and a link to the evidence row. No silent slip past either gate.

---

## Branching convention

Per skill convention: `{user}/{epic}/phase-{N}` per repo. The epic name is `onering-compliance-integration-v2`. Each phase lives in exactly one repo and stacks on the prior phase in the **same repo**. Cross-repo phases do not stack on each other — they coordinate via the contracts document.

| Repo | Phases | Stack within repo |
|------|--------|-------------------|
| ONERING | 1, 2, 3, 4 | 1 → 2 → 3 → 4 |
| rohan_api | 5, 6, 7, 8, 9, 10 | 5 → 6 → 7 → 8 → 9 → 10 |
| rohan_ui | 11 | 11 (off main) |
| Cross-cutting (mostly rohan_api repo, some Database/SRE) | 12, 13, 14 | sequenced after the integration phases land |

`base_branch: base` means main of the phase's repo. `base_branch: phase-N` means the prior phase's branch in the same repo.

---

## Implementation phases

### Phase 1 — Engine: full-pipeline Compliance step factory [PYTHON]

```phase-meta
phase: 1
title: Engine - full-pipeline Compliance step factory (compliance_review:build_steps emitting compliance_matrix.json)
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
  - arc_agent_writer/tests/fixtures/compliance_matrix.sample.json
  - arc_agent_writer/tests/fixtures/cost_summary.sample.json
  - arc_agent_writer/CLAUDE.md
contracts:
  - "1.1 compliance_review:build_steps step factory (full pipeline)"
  - "1.3 compliance_matrix.json v1 JSON Schema (sample fixture)"
  - "1.5 cost_summary.json run-level rollup"
verification:
  - uv run pytest arc_agent_writer/tests/factories/test_compliance_review_factory.py
  - uv run pytest arc_agent_writer/tests/orchestrator/test_cost_summary.py
  - uv run python -m arc_agent_writer.cli run --steps-factory arc_agent_writer.factories.compliance_review:build_steps --dry-run
```

**Goal**: Add a step graph that runs the full Compliance-relevant pipeline so the run terminates with `pipelines/compliance_matrix/ui/compliance_matrix.json` populated. Step list:

```
ingestion → chunk_plan
  → pipelines.metadata → pipelines.ui_projection_metadata
  → pipelines.structure → pipelines.ui_projection_structure
  → pipelines.evaluation → pipelines.ui_projection_evaluation
  → pipelines.instructions → pipelines.ui_projection_instructions
  → pipelines.attachments → pipelines.ui_projection_attachments
  → pipelines.requirements → pipelines.ui_projection_requirements
  → pipelines.attachment_requirement_traceability
  → pipelines.response_guidance
  → pipelines.budget_allocation
  → pipelines.compliance_matrix
```

This is **option 1** from `ONERING_INTEGRATION_PROPOSAL.md` (the full pipeline), explicitly chosen over v1's option 2 thin graph because the engine artifact (`compliance_matrix.json`) is the v2 contract.

**Steps**:

- [ ] **1.1** Create `arc_agent_writer/factories/` package (`__init__.py`).
- [ ] **1.2** Implement `build_steps(config)` in `factories/compliance_review.py` returning the step Sequence above per Contracts §1.1.
  - Skip proposal-launch-specific steps that the existing `arc_launch_proposal_dag` runs (writer, render, deep research on `responding_entity`). Compliance does not need them.
  - Pass `compliance_mode=True` to `pipelines.compliance_matrix` so the JSON builder uses Compliance defaults (no proposal-package writers, no required `responding_company`).
  - Document any pipeline-internal changes required for the Compliance use case; if any are non-trivial, surface them in the PR description and the engine team approves before merge.
- [ ] **1.3** Add unit test `test_compliance_review_factory.py`: validates step ordering, count matches the full graph (12 steps from chunk_plan onward), and `pipelines.compliance_matrix` is the terminal step. Assert `pipelines.attachment_requirement_traceability` precedes `pipelines.compliance_matrix`. Assert no writer/render steps are present.
- [ ] **1.4** Add a sample fixture `compliance_matrix.sample.json` matching the v1 JSON Schema per Contracts §1.3. Source: extract from a known-good staging run via the existing `scripts/dev/rerender_compliance_xlsx.py` flow. **This fixture is referenced by Phase 10's rohan_api dev mock and Phase 13's CI cross-check** — pin its location, don't move.
- [ ] **1.5** Implement `cost_summary.py` orchestrator hook. On terminal step (success path) and on failure handler (best-effort partial), aggregate per-call `cost.json` artifacts into `AGENT_RUNS/{run_id}/cost_summary.json` per Contracts §1.5. Single read path for rohan_api dashboards — replaces aggregating per-call files at query time. Add fixture `cost_summary.sample.json` and unit test that the rollup matches summed inputs. v2 note: with the full pipeline, the rollup spans more steps than v1 (10+ steps emit cost) — assert the test fixture exercises this.
- [ ] **1.6** Update `arc_agent_writer/CLAUDE.md` with a one-paragraph note on the `compliance_review` factory (option 1 full pipeline emitting `compliance_matrix.json`), how to invoke it, and the `cost_summary.json` emission contract.

---

### Phase 2 — Engine: arc_compliance_review DAG + compliance_matrix JSON Schema [PYTHON]

```phase-meta
phase: 2
title: Engine - arc_compliance_review DAG + compliance_matrix.schema.json
tags: [PYTHON]
repo: onering
base_branch: phase-1
depends_on: [1]
files:
  - airflow/dags/arc_compliance_review_dag.py
  - arc_agent_writer/tests/test_airflow_dag_compliance_review.py
  - specs/compliance_matrix.schema.json
  - airflow/CLAUDE.md
contracts:
  - "1.2 arc_compliance_review DAG dag_run.conf envelope"
  - "1.3 compliance_matrix.json v1 JSON Schema"
verification:
  - uv run pytest arc_agent_writer/tests/test_airflow_dag_compliance_review.py
  - "python -c 'import json,jsonschema; jsonschema.Draft7Validator.check_schema(json.load(open(\"specs/compliance_matrix.schema.json\")))'"
  - "python -c 'import json,jsonschema; jsonschema.validate(json.load(open(\"arc_agent_writer/tests/fixtures/compliance_matrix.sample.json\")), json.load(open(\"specs/compliance_matrix.schema.json\")))'"
```

**Goal**: Ship the Airflow DAG file and freeze the v1 JSON Schema for `compliance_matrix.json`. Because `compliance_matrix.json` is rich and shape-variant (multi-topic vs single-topic top-level keys differ), the schema work here is heavier than v1's `ui_projection_requirements.schema.json` — budget ~3 engineer-days for schema authoring + cross-checking against representative fixtures from staging.

**Steps**:

- [ ] **2.1** Create `airflow/dags/arc_compliance_review_dag.py`. Mirror `arc_launch_proposal_dag.py`. BashOperator wrapping `python -m arc_agent_writer.cli run --steps-factory arc_agent_writer.factories.compliance_review:build_steps`. `dag_run.conf` envelope per Contracts §1.2. Tags `["arc", "compliance", "extraction"]`. `max_active_runs=4`. Retries 1 / 5 min. **Bumps pod resource profile to `llm_extraction` for steps and `llm_aggregation` for the matrix-merge step** — the matrix step does an LLM-backed description merge.
- [ ] **2.2** Add DAG unit test `test_airflow_dag_compliance_review.py` mirroring the existing `test_airflow_dag_llm_mode.py` — validates DAG loads, task ordering, conf-param parsing, env-var export to BashOperator.
- [ ] **2.3** Write `specs/compliance_matrix.schema.json` per Contracts §1.3. Include `schema_version: "1"` constant. **Top-level shape**: `is_multi_topic`, `schema_version`, `run_id`, `generated_at_utc`, `response_format_tier`, `solicitation_metadata`, `compliance_checklist_items[]`, `response_guidance_contract`, `page_budget_contract`, `attachment_requirement_traceability`, `scope_banded_flat`, `compliance_matrix[]` (the canonical flat array of leaf compliance rows), `package_wide_groups[]`. Multi-topic variant: `topics[]`, `shared_requirements`, `classification`. `additionalProperties: true` per Contracts §1.3 versioning rule — strictness lives at `schema_version` rejection.
- [ ] **2.4** Fixture stays at the Phase 1 location: `arc_agent_writer/tests/fixtures/compliance_matrix.sample.json`. **Do not move.** rohan_api Phase 10 mock and Phase 13 CI cross-check both pin to this exact path; relocating it silently breaks both. Confirm CI cross-check runs locally (`jsonschema -i arc_agent_writer/tests/fixtures/compliance_matrix.sample.json specs/compliance_matrix.schema.json`).
- [ ] **2.5** Update `airflow/CLAUDE.md` with a section on the new DAG, conf shape, pool usage (uses 2 `llm_extraction_pool` slots for ~6 LLM-emitting steps + 1 `llm_aggregation_pool` slot for the merge), and the matrix shape contract.

---

### Phase 3 — Engine: response-check pipeline + arc_compliance_response_check DAG + schema [PYTHON]

```phase-meta
phase: 3
title: Engine - response_check pipeline (NEW) + arc_compliance_response_check DAG + response_check.schema.json
tags: [PYTHON]
repo: onering
base_branch: phase-2
depends_on: [2]
files:
  - arc_agent_writer/pipelines/response_check/__init__.py
  - arc_agent_writer/pipelines/response_check/pipeline.py
  - arc_agent_writer/pipelines/response_check/models.py
  - arc_agent_writer/pipelines/response_check/prompts.py
  - arc_agent_writer/pipelines/response_check/ui_projection.py
  - arc_agent_writer/factories/compliance_response_check.py
  - arc_agent_writer/tests/factories/test_compliance_response_check_factory.py
  - arc_agent_writer/tests/test_response_check_pipeline.py
  - arc_agent_writer/tests/fixtures/response_check.sample.json
  - airflow/dags/arc_compliance_response_check_dag.py
  - arc_agent_writer/tests/test_airflow_dag_compliance_response_check.py
  - specs/response_check.schema.json
  - arc_agent_writer/CLAUDE.md
  - airflow/CLAUDE.md
contracts:
  - "1.7 compliance_response_check:build_steps step factory"
  - "1.8 arc_compliance_response_check DAG dag_run.conf envelope"
  - "1.9 response_check.json v1 JSON Schema"
verification:
  - uv run pytest arc_agent_writer/tests/test_response_check_pipeline.py
  - uv run pytest arc_agent_writer/tests/factories/test_compliance_response_check_factory.py
  - uv run pytest arc_agent_writer/tests/test_airflow_dag_compliance_response_check.py
  - "python -c 'import json,jsonschema; jsonschema.Draft7Validator.check_schema(json.load(open(\"specs/response_check.schema.json\")))'"
  - "python -c 'import json,jsonschema; jsonschema.validate(json.load(open(\"arc_agent_writer/tests/fixtures/response_check.sample.json\")), json.load(open(\"specs/response_check.schema.json\")))'"
```

**Goal**: Ship a NEW ONERING pipeline for response-document analysis. There is no current `pipelines.response_check` in the engine; this phase is genuine engine-build work, not wiring. Budget ~3–5 engineer-weeks. Output artifact `pipelines/response_check/ui/response_check.json` is consumed by rohan_api's response-check materializer (Phase 8) to produce `compliance_checks` + `compliance_item_evidence` rows.

**Input contract**: `dag_run.conf` includes `compliance_items[]` (the approved items extracted by a prior `arc_compliance_review` run — denormalized into the conf so the response-check DAG does not need to read run-cross MinIO state) plus `response_document_ids[]` and `org_id` / `user_id`. See Contracts §1.8.

**Output contract**: `response_check.json` with `schema_version`, `run_id`, `compliance_project_id`, `response_id`, per-item `checks[]` array where each entry has `compliance_item_id`, `stable_hash`, `automated_status` ∈ `{PASS, FAIL}`, `confidence`, `rationale`, and `evidence[]` (per-snippet: `document_id`, `start_line`, `end_line`, `text`). See Contracts §1.9.

**Steps**:

- [ ] **3.1** Create `arc_agent_writer/pipelines/response_check/` package. `pipeline.py` implements `ResponseCheckPipeline` and a public `build_response_check(...)` entry point. Mirrors the structural choice of `pipelines.response_guidance` (per-item LLM call, KM-retrieve over response doc, structured output). `models.py` defines pydantic schemas matching the JSON output. `prompts.py` registers the response-check prompt; **explicit non-goal**: this is NOT the existing `response_guidance` prompt — different purpose (PASS/FAIL determination + evidence span vs writer-side guidance generation).
- [ ] **3.2** Implement `pipelines.response_check.pipeline`. For each `compliance_item`, KM-retrieve evidence from the response document(s), call the LLM with a structured-output schema, emit `(automated_status, confidence, rationale, evidence[])`. Reuse the existing per-call cost emission so Phase 1's `cost_summary.py` rollup picks it up automatically.
- [ ] **3.3** Implement `pipelines.response_check.ui_projection` — hydrates the raw per-item LLM outputs into the v1 `response_check.json` shape per Contracts §1.9. Persists `pipelines/response_check/ui/response_check.json`.
- [ ] **3.4** Create `arc_agent_writer/factories/compliance_response_check.py` with `build_steps(config)` per Contracts §1.7. Step graph: `ingestion(response_doc) → chunk_plan → pipelines.response_check → pipelines.ui_projection_response_check`. Note: `pipelines.metadata`/`structure`/etc. are NOT in this graph — response-check operates on the items already extracted by the source-doc DAG.
- [ ] **3.5** Create `airflow/dags/arc_compliance_response_check_dag.py`. Mirror `arc_compliance_review_dag.py` from Phase 2. BashOperator wrapping `python -m arc_agent_writer.cli run --steps-factory arc_agent_writer.factories.compliance_response_check:build_steps`. `dag_run.conf` envelope per Contracts §1.8. Tags `["arc", "compliance", "response_check"]`. `max_active_runs=8` (higher than the source-doc DAG because response-check runs are shorter and more frequent — one per response submission). Retries 1 / 5 min.
- [ ] **3.6** Write `specs/response_check.schema.json` per Contracts §1.9. Include `schema_version: "1"`. Schema is much smaller than `compliance_matrix.schema.json` — flat `checks[]` array, no multi-topic variants. `additionalProperties: true`, version-strict on `schema_version`.
- [ ] **3.7** Add a sample fixture `response_check.sample.json` covering: one PASS check with two evidence spans, one FAIL check with rationale, one item with empty evidence (defensible FAIL). Pin location: rohan_api Phase 10 mock and Phase 13 CI cross-check both consume it.
- [ ] **3.8** Unit tests: response-check pipeline happy path (fixture-driven, LLM mocked), factory step ordering, DAG load + conf parsing, schema validates the sample fixture.
- [ ] **3.9** Update `arc_agent_writer/CLAUDE.md` with a section on the new `response_check` pipeline. Update `airflow/CLAUDE.md` with the new DAG, conf shape, pool usage (uses 1 `llm_extraction_pool` slot per response — many items but small per-item LLM calls; the pool can run several response-checks concurrently).

**Risk callout**: This is the highest-risk phase in the plan. If the response-check pipeline does not converge in week 2, the team falls back to v1 (ship matrix-only, keep response analysis on Service-Bus path) per W2.3 fallback trigger. The risk surfaces in W1.1b and W2.3.

---

### Phase 4 — Engine: Helm pool capacity + prod values review [PYTHON]

```phase-meta
phase: 4
title: Engine - Helm pool capacity bumps + prod values review
tags: [PYTHON]
repo: onering
base_branch: phase-3
depends_on: [3]
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

**Goal**: Bump pool sizes per documented sizing model **for the two-DAG world** (v2 needs more capacity than v1), ensure `values-prod.yaml` is review-ready for the first prod cutover, pin git-sync refs, and lock Helm rendering behind a parity CI job so values-file changes produce reviewable diffs.

**Steps**:

- [ ] **4.1** In `airflow-init` job, raise `llm_extraction_pool` to **6 slots** (up from v1's 4) and `llm_aggregation_pool` to **3 slots** (up from v1's 2). Sizing rationale: full-pipeline source-doc runs hold ~2 extraction + 1 aggregation slots; response-check runs hold ~1 extraction slot each. Target 2 concurrent source-doc runs + 4 concurrent response-check runs without queueing. Apply across `values-{dev,staging,prod}.yaml` via base `values.yaml` overrides where appropriate. Document the sizing model in `docs/onering-airflow/sizing-model.md` per Contracts §1.4 (concurrent run targets, slot-hold per run, headroom assumption, re-evaluation trigger). Numbers are diff-able.
- [ ] **4.2** Pin `gitSync.ref` in all three env values files to a specific engine release tag per Contracts §1.6. NEVER `main` / `HEAD` / a branch name. Phase 14 final step bumps prod ref to the engine release matching `onering-compliance-v2`. Add the regex check to verification commands above so the CI catches a regression to a branch ref.
- [ ] **4.3** SRE review of `values-prod.yaml` — capacity headroom, image registry, ingress, network policy, secrets paths (Key Vault for Airflow basic-auth credentials). SRE sign-off captured in PR description.
- [ ] **4.4** No new resource profile required (response-check pipeline fits the existing `llm_extraction` 8–16 GiB profile — per-item calls are smaller than requirements extraction). Confirmed during the Phase 3 engine spike; if confirmed false, add a `compliance_response_check` profile here.
- [ ] **4.5** Add Helm parity CI workflow `onering-helm-parity.yml` per Contracts §9.3. Triggers on PRs touching `helm/onering-airflow/**`. Renders each env, diffs against checked-in baseline at `helm/onering-airflow/.rendered/<env>.yaml`, fails if author did not update the baseline. Asserts no env file pins `gitSync.ref` to a branch. Closes the gap that `make up-airflow` does not validate the Helm chart.
- [ ] **4.6** Commit the initial baseline renders to `helm/onering-airflow/.rendered/{dev,staging,prod}.yaml`. Subsequent Helm changes update both the values file AND the rendered baseline in the same PR.

---

### Phase 5 — rohan_api: enums, types, DTOs [BACKEND_DB]

```phase-meta
phase: 5
title: rohan_api - OneringDagId, RunType, ComplianceReviewConf, ResponseCheckConf, DTOs
tags: [BACKEND_DB]
repo: rohan_api
base_branch: base
depends_on: []
files:
  - src/onering/types/airflow.types.ts
  - src/onering/enums/run-type.enum.ts
  - src/onering/dto/runs/compliance-run.dto.ts
  - src/onering/dto/runs/response-check-run.dto.ts
  - src/onering/dto/runs/index.ts
  - src/utils/feature-flags/types/featureFlags.ts
contracts:
  - "2.1 Enum extensions (two new DAG IDs + two new RunTypes)"
  - "2.2 ComplianceReviewConf interface"
  - "2.4 ResponseCheckConf interface"
  - "5.1 TriggerComplianceReviewDto + ComplianceRunResponse"
  - "5.5 TriggerResponseCheckDto + ResponseCheckRunResponse"
  - "6.1 ONERING_COMPLIANCE feature flag"
verification:
  - npm run lint
  - npm run build
```

**Goal**: Land all rohan_api type and enum surface area for **both** new DAGs without behavior changes. Lays the foundation for subsequent service/controller phases.

**Steps**:

- [ ] **5.1** Extend `OneringDagId` with `COMPLIANCE_REVIEW = 'arc_compliance_review'` and `COMPLIANCE_RESPONSE_CHECK = 'arc_compliance_response_check'` in `airflow.types.ts`.
- [ ] **5.2** Extend `RunType` with `COMPLIANCE_REVIEW = 'COMPLIANCE_REVIEW'` and `COMPLIANCE_RESPONSE_CHECK = 'COMPLIANCE_RESPONSE_CHECK'` in `run-type.enum.ts`. Also extend `RunStatus` with `MATERIALIZING = 'MATERIALIZING'` (intermediate state between Airflow SUCCESS and rohan_api materializer commit; closes the UI race per Contracts §3.2 status transition contract).
- [ ] **5.3** Add `ComplianceReviewConf` and `ResponseCheckConf` interfaces and extend `DagRunConf` union in `airflow.types.ts`. `ResponseCheckConf` includes `org_id`, `user_id`, `compliance_project_id`, `response_id`, `response_document_ids`, `compliance_items[]` (denormalized — array of `{ compliance_item_id, stable_hash, title, text }` so the DAG does not need to read the parent run's MinIO state), `expected_run_id`, optional `llm_mode`/`verbose`.
- [ ] **5.4** Create `src/onering/dto/runs/compliance-run.dto.ts` with `TriggerComplianceReviewDto`, `ComplianceRunResponse`, `ComplianceRunListItem`, `ComplianceRunListResponse`. Create `src/onering/dto/runs/response-check-run.dto.ts` with `TriggerResponseCheckDto`, `ResponseCheckRunResponse`. Include `class-validator` and `@nestjs/swagger` decorators per Contracts §5.
- [ ] **5.5** Add `ONERING_COMPLIANCE` to `featureFlags.ts` enum. Single flag gates **both** paths (source-doc + response-check) per Assumption 10 to avoid the half-flipped state risk. Run `pnpm enable-flag ONERING_COMPLIANCE` is a follow-up DB operation, not a code change.
- [ ] **5.6** Confirm no consumers of `RunType` / `OneringDagId` break (search and verify exhaustive-match handlers). Especially check `OneringPipelineService.refreshRunStatus()` for switch-case completeness across the now-two new run types.

---

### Phase 6 — DB schema: compliance_items, compliance_checks, compliance_projects, or_pipeline_runs columns [BACKEND_DB]

```phase-meta
phase: 6
title: DB - compliance_items + compliance_checks + compliance_projects pointer + or_pipeline_runs typed columns + compliance_audit_log
tags: [BACKEND_DB]
repo: rohan_api
base_branch: phase-5
depends_on: [5]
files:
  - src/compliance/entities/compliance-item.entity.ts
  - src/compliance/entities/compliance-check.entity.ts
  - src/compliance/entities/compliance-project.entity.ts
  - src/onering/entities/or-pipeline-run.entity.ts
  - scripts/sql/<synced-from-Database-repo>.sql
contracts:
  - "3.1 compliance_items additions"
  - "3.2 or_pipeline_runs (typed columns for project_id, response_id, document_ids)"
  - "3.3 compliance_checks additions"
  - "3.4 compliance_projects.compliance_matrix_json_key pointer"
verification:
  - npm run lint
  - npm run build
  - npm run test -- src/compliance/entities
  - npm run db:test:up
```

**Goal**: Land the schema changes first so downstream service code (Phase 7) can write typed columns without conditional gates. v2 adds more columns than v1 because the response-check materializer also needs `arc_run_id` provenance, and the matrix-JSON pointer column lives on `compliance_projects`. Per `rohan_api/CLAUDE.md`, SQL is authored in the `Database/` repo and synced into rohan_api. This phase coordinates both.

**Steps**:

- [ ] **6.1** **In the `Database/` repo**, author a migration script with `IF NOT EXISTS` everywhere:
  - `compliance_items.arc_run_id UUID NULL`, `compliance_items.arc_requirement_id VARCHAR(128) NULL`, `compliance_items.stable_hash VARCHAR(64) NULL` + indexes per Contracts §3.1.
  - `compliance_checks.arc_run_id UUID NULL`, `compliance_checks.arc_response_check_id VARCHAR(128) NULL`, `compliance_checks.stable_hash VARCHAR(64) NULL`, `compliance_checks.confidence VARCHAR(16) NULL` (engine confidence string), `compliance_checks.automated_rationale TEXT NULL` (engine rationale; distinct from reviewer `user_notes`) per Contracts §3.3. Index `(response_id, compliance_item_id)` already unique today — confirm it stays.
  - `compliance_projects.compliance_matrix_json_key VARCHAR(2048) NULL` per Contracts §3.4 (Open Q11). MinIO object key, NOT presigned URL. Cleared on document-set change (Phase 7.x trigger).
  - `or_pipeline_runs.materialized_at TIMESTAMPTZ NULL`, `or_pipeline_runs.project_id UUID NULL`, `or_pipeline_runs.response_id UUID NULL`, `or_pipeline_runs.document_ids UUID[] NULL`. Indexes `(organization_id, project_id, started_at DESC)` for project-scoped listing and `(organization_id, response_id, started_at DESC)` for response-scoped listing.
  - `compliance_audit_log` (`id` UUID PK, `organization_id` UUID NOT NULL, `project_id` UUID NULL, `response_id` UUID NULL, `arc_run_id` UUID NULL, `run_type` VARCHAR(64) NOT NULL, `action` VARCHAR(64) NOT NULL, `payload` JSONB NOT NULL, `created_at` TIMESTAMPTZ NOT NULL DEFAULT now()) plus indexes `(organization_id, project_id, created_at DESC)` and `(organization_id, response_id, created_at DESC)`. Both materializers write into it (Phase 8).
- [ ] **6.2** Run the sync script in rohan_api to pull the new SQL into `scripts/sql/`. **Do not edit `scripts/sql/` directly.**
- [ ] **6.3** Add the TypeORM column definitions to:
  - `compliance-item.entity.ts` — `arcRunId`, `arcRequirementId`, `stableHash`.
  - `compliance-check.entity.ts` — `arcRunId`, `arcResponseCheckId`, `stableHash`, `confidence`, `automatedRationale`.
  - `compliance-project.entity.ts` — `complianceMatrixJsonKey`.
  - `or-pipeline-run.entity.ts` — `projectId`, `responseId`, `documentIds`, `materializedAt`.
- [ ] **6.4** Verify `or_pipeline_runs.run_type` accepts the new `COMPLIANCE_REVIEW` and `COMPLIANCE_RESPONSE_CHECK` enum values without DDL — read the existing column definition. If it's a CHECK constraint or DB enum, the constraint also needs updating in the `Database/` repo.
- [ ] **6.5** Run `npm run db:test:up` and confirm the test DB reflects new columns.

---

### Phase 7 — rohan_api: triggerComplianceReview() + triggerResponseCheck() service methods [BACKEND_DB]

```phase-meta
phase: 7
title: rohan_api - OneringPipelineService.triggerComplianceReview() + triggerResponseCheck()
tags: [BACKEND_DB]
repo: rohan_api
base_branch: phase-6
depends_on: [6]
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
  - "2.5 OneringPipelineService.triggerResponseCheck()"
  - "2.3 Polling cadence + stuck-run reaper"
  - "1.2 arc_compliance_review DAG dag_run.conf envelope (consumer side)"
  - "1.8 arc_compliance_response_check DAG dag_run.conf envelope (consumer side)"
verification:
  - npm run lint
  - npm run test -- src/onering/services/onering-pipeline.service.spec.ts
  - npm run test -- src/onering/services/onering-run-reaper.service.spec.ts
```

**Goal**: Add **both** trigger methods that create `or_pipeline_runs`, call Airflow, and return the run handle. Schema (Phase 6) is already in place — write `project_id` / `response_id` and `document_ids` to typed columns directly. Add the stuck-run reaper as a sibling service so a 409 on subsequent triggers cannot lock a project or response forever.

**Steps**:

- [ ] **7.1** Implement `triggerComplianceReview(orgId, userId, projectId, documentIds, options)` per Contracts §2.3. Resolves `organization_id` via `OneringOrgLookupService`. Generates `arc_run_id` upfront. Writes `project_id`, `document_ids` (resolved to explicit list — empty input MUST be expanded to all current source documents at trigger time), `run_type = 'COMPLIANCE_REVIEW'` to typed columns on `or_pipeline_runs`. No JSONB junk-drawer. No flag gating.
- [ ] **7.2** Implement `triggerResponseCheck(orgId, userId, responseId, options)` per Contracts §2.5. Resolves `organization_id`. Generates `arc_run_id` upfront. Reads the parent project's currently-approved `compliance_items` (filtered by `status = APPROVED`) and denormalizes them into `compliance_items[]` in the `dag_run.conf` envelope. Writes `project_id` (the parent project), `response_id`, `document_ids` (= the response's document IDs from `compliance_response_documents`), `run_type = 'COMPLIANCE_RESPONSE_CHECK'` to typed columns. 409 if non-terminal response-check run exists for the same `response_id`.
- [ ] **7.3** On Airflow trigger 409 (duplicate `dag_run_id`) in either trigger, treat as success — read back the existing run via `getDagRun()` and use that handle. Idempotent retry on transport-error retry storms.
- [ ] **7.4** Mirror error mapping from `launchProposal()`: `OneringAirflowError` on transport failure; row marked FAILED with captured error.
- [ ] **7.5** **Resolve org-mapping policy.** Audit `OneringOrgLookupService` — is it a pass-through (rohan org id == ONERING tenant id) or a real mapping table? If pass-through, drop the indirection in this PR and call sites use `orgId` directly. If real mapping, document bootstrap path. Open Q4 closed by this step.
- [ ] **7.6** Add `killDagRun(dagRunId)` to `OneringAirflowClientService`. Used by reaper (7.7) and admin cancel endpoint (Phase 9.8). Tolerates Airflow 404 (run already gone).
- [ ] **7.7** Implement `OneringRunReaperService` per Contracts §2.3 stuck-run reaper. Cron every 5 min via `@Cron(CronExpression.EVERY_5_MINUTES)` on a dedicated reaper handler. Behavior: find `or_pipeline_runs` with `status IN ('PENDING','QUEUED','RUNNING')` AND `started_at < now() - interval '90 minutes'`. For each: re-fetch Airflow status; if Airflow says terminal, transition the row; if Airflow still running but `started_at < now() - interval '180 minutes'` (hard cap), call `killDagRun()` and mark `FAILED` with error code `STUCK_RUN_TIMEOUT`. INSERT `compliance_audit_log` row with `action = 'reaper_force_failed'` and the correct `run_type`. Reaper is global (not per-org); single instance via `SELECT FOR UPDATE SKIP LOCKED` to support multi-pod deploys. **Same reaper for both run types** — picks up either run by status alone.
- [ ] **7.8** Pin `refreshRunStatus()` polling cadence per Contracts §2.3 table: 15 s for PENDING/QUEUED, 5 s for RUNNING, stop on terminal. Cadence applies to both run types. If existing reconciler uses a different cadence, override per-run-type via the existing scheduler primitive — do not introduce a new scheduler.
- [ ] **7.9** Unit tests for both triggers: happy path, Airflow trigger failure, Airflow 409 idempotent re-handle, empty `document_ids` expansion (source-doc only — response-check requires explicit response_id), idempotency at the row level. Reaper tests cover both run types: terminal-Airflow-state pickup at >90min, hard-cap kill at >180min, multi-pod lock contention via SKIP LOCKED.
- [ ] **7.10** Wire `OneringRunReaperService` into `OneringModule` providers + the `@nestjs/schedule` registration.
- [ ] **7.11** **Clear-pointer trigger**: add a hook on `compliance_documents` changes (insert/delete) for the parent project. When the document set changes, clear `compliance_projects.compliance_matrix_json_key` so a stale matrix isn't served. Implementation choice: synchronous in the existing doc-add / doc-delete handler in `ComplianceService`, since both handlers already touch project state. Document the rule: "any change to the project's source-doc set invalidates the cached matrix pointer."

---

### Phase 8 — rohan_api: validators + materializers for both DAGs [BACKEND_DB]

```phase-meta
phase: 8
title: rohan_api - compliance_matrix.json + response_check.json validators + materializers + listener fences
tags: [BACKEND_DB]
repo: rohan_api
base_branch: phase-7
depends_on: [7]
files:
  - src/onering/services/compliance-matrix-validator.service.ts
  - src/onering/services/compliance-matrix-validator.service.spec.ts
  - src/onering/services/response-check-validator.service.ts
  - src/onering/services/response-check-validator.service.spec.ts
  - src/onering/services/onering-pipeline.service.ts
  - src/onering/services/onering-pipeline.service.spec.ts
  - src/compliance/services/compliance-onering-materializer.service.ts
  - src/compliance/services/compliance-onering-materializer.service.spec.ts
  - src/compliance/services/compliance-response-check-materializer.service.ts
  - src/compliance/services/compliance-response-check-materializer.service.spec.ts
  - src/compliance/listeners/compliance.listener.ts
  - src/compliance/listeners/compliance.listener.spec.ts
  - src/onering/onering.errors.ts
  - src/onering/onering.module.ts
  - src/compliance/compliance.module.ts
contracts:
  - "4.1 Schema validators (compliance_matrix + response_check)"
  - "4.2 Source-doc materializer behavior (compliance_matrix.json → compliance_items)"
  - "4.3 Response-check materializer behavior (response_check.json → compliance_checks)"
  - "6.1 ONERING_COMPLIANCE listener fence (tagging.auto-tag-complete + compliance.response.analyze)"
verification:
  - npm run lint
  - npm run test -- src/onering/services/compliance-matrix-validator.service.spec.ts
  - npm run test -- src/onering/services/response-check-validator.service.spec.ts
  - npm run test -- src/compliance/services/compliance-onering-materializer.service.spec.ts
  - npm run test -- src/compliance/services/compliance-response-check-materializer.service.spec.ts
  - npm run test -- src/onering/services/onering-pipeline.service.spec.ts
  - npm run test -- src/compliance/listeners/compliance.listener.spec.ts
```

**Goal**: Read **both** terminal-SUCCESS artifacts, validate, drop deletion-during-run items, materialize. Phase A (read+validate, no DB tx) / Phase B (mutate, single short tx with no network IO) split applies to both materializers. PRCR-1570 numbering preserved for source-doc items. Two listener fences added in same phase to close the dual-path race window for both event types.

**Steps**:

- [ ] **8.1** Implement `ComplianceMatrixValidatorService` using `ajv` (pin `ajv@^8` explicitly in `package.json` to avoid transitive-version conflict with `class-validator`). Compile schema once at module init. Method `loadAndValidate(arcRunId)` reads `pipelines/compliance_matrix/ui/compliance_matrix.json` from MinIO via `OneringArtifactService` and validates against `specs/compliance_matrix.schema.json` (synced from ONERING at the pinned tag — see Phase 13 cross-check). `additionalProperties: true`. Throws `OneringSchemaError` on validation failure or unknown `schema_version`.
- [ ] **8.2** Implement `ResponseCheckValidatorService` (same pattern). Reads `pipelines/response_check/ui/response_check.json` and validates against `specs/response_check.schema.json`.
- [ ] **8.3** Add `OneringSchemaError` to `onering.errors.ts`. Map to 502 in `OneringExceptionFilter`.
- [ ] **8.4** Implement `ComplianceOneringMaterializerService.materialize(arcRunId, dagRunId)` per Contracts §4.2 — strict Phase A / Phase B split. Reads `compliance_matrix.json`.
  - Phase A: SELECT run row (reject if missing — out-of-band trigger defense), load + validate JSON, **A4a cross-check** that `json.run_id == or_pipeline_runs.arc_run_id` AND `json.compliance_project_id == or_pipeline_runs.project_id` AND `compliance_projects.organization_id == or_pipeline_runs.organization_id`, SELECT current `compliance_documents`, **flatten `json.compliance_matrix[]` array** into per-leaf-requirement records (one row per leaf requirement; the structure→eval→requirement hierarchy is preserved only in the JSON blob, not in `compliance_items`), compute drop-set for items whose `source_document_id` is no longer in the doc set. On any failure here, separate UPDATE marks run FAILED; Phase B never starts. A4a mismatch raises `OneringSchemaError` with code `JSON_RUN_ROW_MISMATCH`.
  - Phase B: BEGIN → re-check idempotency latch (`materialized_at` SELECT FOR UPDATE) → match by `(source_document_id, stable_hash)` only → UPDATE matched (preserve `status`, `reviewed_by`, `userNotes`, `lineItemNumber`) → INSERT unmatched with PRCR-1570 numbering → UPDATE supersede (scoped to `dag_run.conf.document_ids`) → INSERT audit log rows for drops → **UPDATE `compliance_projects.compliance_matrix_json_key` to the MinIO key of the validated JSON** (Open Q11) → UPDATE `or_pipeline_runs.materialized_at` → UPDATE run row to `SUCCESS` → COMMIT.
  - No MinIO reads, no Airflow calls, no `compliance_documents` lookups inside Phase B.
  - Audit log target table `compliance_audit_log`. Materializer writes one row per drop with `action = 'materializer_dropped_orphan'`.
  - Document-replacement (new ID) handling per Contracts §4.2 lifecycle table: legacy items NOT auto-superseded — UI nudges user to re-extract (Phase 11 stale-state banner).
- [ ] **8.5** Implement `ComplianceResponseCheckMaterializerService.materialize(arcRunId, dagRunId)` per Contracts §4.3.
  - Phase A: SELECT run row, load + validate `response_check.json`, A4a cross-check (`json.run_id == arc_run_id`, `json.response_id == or_pipeline_runs.response_id`), SELECT current `compliance_response_documents` for the response.
  - Phase B: BEGIN → idempotency latch → match `compliance_checks` rows by `(response_id, compliance_item_id, stable_hash)` → UPDATE matched (preserve `userDetermination`, `userNotes`, `reviewedBy`) — only `automatedStatus`, `confidence`, `automatedRationale`, `arc_run_id` get refreshed → INSERT unmatched → on the same transaction, replace `compliance_item_evidence` rows for matched/inserted checks (DELETE existing automated evidence with `extraction_method = AUTO_EXTRACTED` for these checks, INSERT fresh from `json.checks[].evidence[]`) → COMMIT.
  - Manual evidence rows (`extraction_method = MANUAL`) are NEVER deleted by this materializer — they belong to the human reviewer.
  - Audit log: `action = 'response_check_materialized'` with `payload = { checks_updated, checks_inserted, evidence_rows_replaced }`.
- [ ] **8.6** Add **two** `compliance.listener.ts` fences per Contracts §6.1:
  - Source-doc fence: short-circuit `tagging.auto-tag-complete` handler when `ONERING_COMPLIANCE` is on for the event's organization.
  - Response-doc fence: short-circuit `compliance.response.analyze` handler when `ONERING_COMPLIANCE` is on for the project's organization.
  - **Locate handlers by decorator, not line number.** `git grep "@OnEvent('tagging.auto-tag-complete')"` and `git grep "@OnEvent('compliance.response.analyze')"` are the source of truth. Skip-log lines: `compliance.listener.skipped_due_to_onering` with `org_id`, `project_id`/`response_id`, `event_name`. Phase 14 retirement uses the same locate-by-decorator approach.
- [ ] **8.7** Extend `OneringPipelineService.refreshRunStatus()` to handle the new `MATERIALIZING` intermediate state for **both** `run_type` values. Branch on `run_type` to invoke the correct materializer. The materializer's Phase B commits the `SUCCESS` flip atomically with the data writes. Reuse the existing reconciliation service (PRCR-1562) for transient failures. Add `RunStatus.MATERIALIZING` to the run-status enum and update the `OneringRunStatus` switch-case completeness check across the module.
- [ ] **8.8** Add `ComplianceItemStatus.SUPERSEDED = 'superseded'` to `compliance.constants.ts`. **Audit ALL queries against `compliance_items.status`** — same audit discipline as v1 step 7.5. PR description must enumerate the audited query sites with the chosen filter behavior.
- [ ] **8.9** Wire both materializers into `OneringModule` (providers) and `ComplianceModule` (consumers).
- [ ] **8.10** Unit tests for both validators (happy path, unknown schema_version, missing field, type mismatch); both materializers (insert-only, match-and-update, supersede / evidence-replace, document-deletion drop, single-document scoped retry, idempotency latch). Plus a test that the source-doc materializer correctly populates `compliance_projects.compliance_matrix_json_key`.
- [ ] **8.11** Wire document-deletion-mid-run cancel hook per Proposal §"Document deletion during a run" — same logic as v1 step 7.8, generalized to **both** run types. When a `compliance_documents` row is hard-deleted (or a `compliance_response_documents` link is removed), check non-terminal `or_pipeline_runs`. Cancel runs with zero remaining docs in scope; let the materializer's drop-set handle partial deletion.

---

### Phase 9 — rohan_api: Compliance controller endpoints + dual-path branching [BACKEND_DB]

```phase-meta
phase: 9
title: rohan_api - Compliance controller endpoints (source-doc + response-check + matrix-JSON read), ONERING_COMPLIANCE dual-path
tags: [BACKEND_DB]
repo: rohan_api
base_branch: phase-8
depends_on: [8]
files:
  - src/compliance/compliance.controller.ts
  - src/compliance/compliance.controller.spec.ts
  - src/compliance/compliance.service.ts
  - src/compliance/compliance.service.spec.ts
  - src/compliance/compliance.errors.ts
  - src/compliance/dto/compliance-run.dto.ts
  - src/compliance/dto/response-check-run.dto.ts
  - src/compliance/compliance.module.ts
contracts:
  - "5.1 POST /compliance/projects/:id/onering/extract"
  - "5.2 GET /compliance/projects/:id/onering/runs"
  - "5.3 Modified POST /compliance/projects/:projectId/documents/process"
  - "5.4 POST /compliance/projects/:id/onering/runs/:arcRunId/cancel (admin force-cancel)"
  - "5.5 POST /compliance/responses/:id/onering/check"
  - "5.6 GET /compliance/responses/:id/onering/runs"
  - "5.7 Modified POST /compliance/responses/:id/analyze (dual-path)"
  - "5.8 GET /compliance/projects/:id/onering/matrix"
  - "6.1 ONERING_COMPLIANCE feature flag (consumer side)"
verification:
  - npm run lint
  - npm run test -- src/compliance/compliance.controller.spec.ts
  - npm run test -- src/compliance/compliance.service.spec.ts
```

**Goal**: Surface the new endpoints for **both** flows, gate them on the feature flag, branch the existing `documents/process` and response-analyze endpoints to either path, and add a read endpoint for the full `compliance_matrix.json` so future UI surfaces can render hierarchy without a re-extract.

**Steps**:

- [ ] **9.1** Add `POST /compliance/projects/:id/onering/extract` per Contracts §5.1. Guards: `AuthGuard('jwt')`, `PermissionsGuard('compliance')`, `FeatureGuard('ONERING_COMPLIANCE')`. Two-stage org check: load `compliance_projects` by `id`, return 404 unless `organization_id == caller.organization_id` (do not distinguish "wrong org" from "missing"). Delegates to `OneringPipelineService.triggerComplianceReview()`. 409 if project has a non-terminal review run.
- [ ] **9.2** Add `GET /compliance/projects/:id/onering/runs` per Contracts §5.2. Returns both `COMPLIANCE_REVIEW` and (project-scoped) `COMPLIANCE_RESPONSE_CHECK` runs by default, with an optional `?run_type=` query param to filter. Order by `started_at DESC`, cap at 50.
- [ ] **9.3** Modify `POST /compliance/projects/:projectId/documents/process` to feature-detect on `ONERING_COMPLIANCE`. Same two-stage org check. When on, call the new path; when off, existing Service-Bus `AutoTagRequest` flow unchanged. Response shape per Contracts §5.3 with `path: 'legacy' | 'onering'` discriminator.
- [ ] **9.4** Add `POST /compliance/responses/:id/onering/check` per Contracts §5.5. Guards same as 9.1. Two-stage org check via the response → project → org chain. Delegates to `OneringPipelineService.triggerResponseCheck()`. 409 if response has a non-terminal response-check run.
- [ ] **9.5** Add `GET /compliance/responses/:id/onering/runs` per Contracts §5.6. Returns `COMPLIANCE_RESPONSE_CHECK` runs filtered by `response_id`.
- [ ] **9.6** Modify the existing response-analyze endpoint (today triggered via `complianceService.runResponseAnalysis()` → emits `compliance.response.analyze` event) per Contracts §5.7 to feature-detect on `ONERING_COMPLIANCE`. When on, call `triggerResponseCheck()`; when off, existing event-emission path unchanged. Response shape carries the same `path: 'legacy' | 'onering'` discriminator.
- [ ] **9.7** Add `GET /compliance/projects/:id/onering/matrix` per Contracts §5.8. Returns the parsed `compliance_matrix.json` for the project's most-recent successful `COMPLIANCE_REVIEW` run. Reads the MinIO key from `compliance_projects.compliance_matrix_json_key` (populated by Phase 8 materializer). 404 if no successful run yet OR if the pointer is null (cleared by Phase 7.11 doc-set-change trigger). Returns the raw JSON shape — no rohan_api-side normalization. Future UI surfaces (proposal-engine compliance step, response-guidance side panel) consume this. Cache-Control: `private, max-age=60` since the underlying MinIO object doesn't change for a given `arc_run_id`.
- [ ] **9.8** Add error classes per Contracts §5.1 errors table (`ComplianceNoDocumentsError`, `ComplianceRunInProgressError`, `ComplianceResponseCheckInProgressError`, `ComplianceMatrixNotAvailableError`). Map in `compliance.errors.ts` + the existing exception filter.
- [ ] **9.9** Add `POST /compliance/projects/:id/onering/runs/:arcRunId/cancel` per Contracts §5.4. Guards: `AuthGuard('jwt')`, `PermissionsGuard('compliance:admin')`, two-stage org check. Works for **both** run types (the run row's `run_type` discriminates internally). Delegates to `OneringPipelineService.forceCancelRun(orgId, arcRunId, actorUserId)`. 409 if run already terminal. Stuck-run reaper (Phase 7.7) handles the >90 min auto-case; this endpoint covers the <90 min admin override.
- [ ] **9.10** Update controller spec + service spec for all paths. Listener fences are implemented in Phase 8.6 (not here). This phase ensures the controller does NOT delete or skip-register the legacy listeners — dual-path period needs both for flag-off orgs. Phase 14 deletes both handlers after the bake window.

---

### Phase 10 — rohan_api: in-process Airflow mock + dev experience [BACKEND_DB]

```phase-meta
phase: 10
title: rohan_api - in-process Airflow mock for default dev mode (both DAGs)
tags: [BACKEND_DB]
repo: rohan_api
base_branch: phase-9
depends_on: [9]
files:
  - src/onering/services/onering-airflow-client.service.ts
  - src/onering/services/onering-airflow-client.service.spec.ts
  - src/onering/__mocks__/airflow-mock.service.ts
  - src/onering/__mocks__/compliance_matrix.fixture.json
  - src/onering/__mocks__/response_check.fixture.json
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

**Goal**: When `ONERING_AIRFLOW_BASE_URL` is unset and `NODE_ENV !== 'production'`, the client returns a synthetic dag-run handle and writes the **correct fixture** based on `dag_id`, letting UI engineers iterate without `make up-airflow`.

**Steps**:

- [ ] **10.1** Implement `AirflowMockService` that branches on `dag_id`:
  - `arc_compliance_review` → write `compliance_matrix.fixture.json` to `AGENT_RUNS/{arc_run_id}/pipelines/compliance_matrix/ui/compliance_matrix.json`.
  - `arc_compliance_response_check` → write `response_check.fixture.json` to `AGENT_RUNS/{arc_run_id}/pipelines/response_check/ui/response_check.json`.
  - Both via `OneringMinioService`. Schedules a 100 ms timer to flip the corresponding `or_pipeline_runs` row to SUCCESS so the polling pathway materializes naturally.
- [ ] **10.2** Toggle in `OneringAirflowClientService`: detect `ONERING_AIRFLOW_BASE_URL` empty + `NODE_ENV !== 'production'` + `ONERING_AIRFLOW_MOCK !== 'disabled'` → delegate to the mock.
- [ ] **10.3** Copy `compliance_matrix.fixture.json` and `response_check.fixture.json` from ONERING repo into `src/onering/__mocks__/`. Phase 13's CI cross-check keeps both in sync.
- [ ] **10.4** Document the mock in `README.md` + `.env.example` (`ONERING_AIRFLOW_BASE_URL=` left empty for default dev mode; set to `http://localhost:8080` to use real Airflow via `make up-airflow`). Note: the mock honors both DAG IDs so dev-mode response-check works end-to-end.
- [ ] **10.5** Tests: unit test that the mock writes the correct fixture per DAG and returns a synthetic handle; integration tests for both polling pathways downstream materializing against the respective mock.

---

### Phase 11 — rohan_ui: extracting + checking state, polling, retry [FRONTEND]

```phase-meta
phase: 11
title: rohan_ui - extracting + checking banners, run polling, retry, error states
tags: [FRONTEND]
repo: rohan_ui
base_branch: base
depends_on: [9]
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
  - src/app/pages/compliance/components/company-detail/company-detail.component.ts
  - src/app/pages/compliance/components/company-detail/company-detail.component.spec.ts
contracts:
  - "7.1 Compliance run types (source-doc + response-check)"
  - "7.2 UI states (extracting + checking)"
verification:
  - npm run lint
  - npm run test:ci -- --include='**/compliance-extracting-banner.component.spec.ts'
  - npm run test:ci -- --include='**/compliance-run.service.spec.ts'
  - npm run test:ci -- --include='**/company-detail.component.spec.ts'
```

**Goal**: When a source-doc extraction run is active, show the extracting banner. When a response-check run is active in the response detail view, show the checking banner. Both poll, both retry. Preserve existing tag UI (PRCR-1517/1519/1544) and the existing `analysisState` semantics (PRCR-1562/1596) unchanged for the item-review surface — only the *trigger* path changes (legacy event vs ONERING DAG), not the rendering.

**Contract-stability gate.** This phase branches off `main` (no cross-repo branch stacking) but **logically depends on Phase 9 contracts being frozen**. Convention: Phase 9 PR includes the OpenAPI / DTO files as the source of truth. UI engineer codes against the contracts doc + Phase 9 PR diff, NOT against a running Phase 9 backend. Avoid the trap of UI silently drifting from a half-merged backend.

**Steps**:

- [ ] **11.1** Add `compliance-run.types.ts` per Contracts §7.1. Includes both `ComplianceRun` (run_type discriminated) and `ComplianceMatrixDocument` (the shape of the parsed `compliance_matrix.json` — typed minimally as `Record<string, unknown>` plus the few top-level keys the v1 UI reads; future hierarchical UIs typify further).
- [ ] **11.2** Add `ComplianceRunService` with:
  - `triggerExtract(projectId, body)` calling `POST /compliance/projects/:id/onering/extract`.
  - `triggerCheck(responseId, body)` calling `POST /compliance/responses/:id/onering/check`.
  - `listProjectRuns(projectId)` and `listResponseRuns(responseId)` calling the respective `GET` endpoints.
  - `getMatrixJson(projectId)` calling `GET /compliance/projects/:id/onering/matrix` (returns `null` on 404 — interpreted as "no successful run yet" by callers).
  - Polling helper that resolves on terminal state with 10 s cadence, backing off to 30 s after 5 min. Same helper used for both run types.
- [ ] **11.3** New presentational component `compliance-extracting-banner` rendering the five UI states from Contracts §7.2 (`extracting`, `extracting-late`, `failed`, `partial`, `stale`). Accepts a `ComplianceRun` input plus a `currentDocumentIds` input for staleness detection. Component is run-type-aware: copy reads "Extracting compliance items…" for `COMPLIANCE_REVIEW` and "Checking response against compliance items…" for `COMPLIANCE_RESPONSE_CHECK`. Same five states.
- [ ] **11.4** Wire the banner into `compliance-page-shell.component` for source-doc runs (polls `listProjectRuns`). Conditional render based on the latest review run and the project's current `compliance_documents`. Staleness derived client-side: last successful run's `document_ids` set-difference current docs → non-empty = stale. Disable item-edit actions while `extracting`. Show admin force-cancel CTA in `extracting-late` when caller has the admin role.
- [ ] **11.5** Wire the banner into `company-detail.component` (the response detail view) for response-check runs. Polls `listResponseRuns(responseId)`. The existing `analysisState` computed (PRCR-1596) stays as the source of truth for tab content rendering; the banner is a thin status layer that lives above it and only renders during a non-terminal run.
- [ ] **11.6** Retry handler on the `failed` state calls the appropriate trigger (`triggerExtract` or `triggerCheck`) with the same scope as the failed run.
- [ ] **11.7** Admin force-cancel handler on `extracting-late` (admin role only) calls `POST /onering/runs/:arcRunId/cancel`. Confirms via dialog. Surfaces 409 (already terminal) by refreshing run state.
- [ ] **11.8** Existing tag UI components (`compliance-item-card`, `compliance-items-panel`, `compliance-checklist-table`, `compliance-content-section`, plus the response-side `evidence-detail-panel` and `compliance-score-card`) untouched. They render items + checks + evidence source-agnostic.
- [ ] **11.9** Audit-trail deep-link per Proposal §"Observability and correlation IDs" line 271. On any `compliance_items` or `compliance_checks` row produced by ONERING (`arc_run_id IS NOT NULL`), the detail surface shows a "View extraction trail" link that opens `/onering/runs/:arcRunId/audit?requirement=:arcRequirementId` (or `?check=:arcResponseCheckId` for response-side). Backend endpoint resolves to MinIO browse URLs at `AGENT_RUNS/{arc_run_id}/llm_calls/{step}/{prompt}/{call_id}/`. Phase 1 v2 ships the link only; full audit-browser UI is a follow-up. Gates on caller having `compliance:admin` or `onering:audit` permission.
- [ ] **11.10** Component tests for the banner (each state, each run type) and service tests for polling cadence + terminal-state resolution + matrix-JSON fetch (200 happy path + 404 = null contract).

**Out of scope for this phase (v2 deferral)**: rendering anything new from `compliance_matrix.json` — solicitation metadata side panel, response-guidance panel, attachment inventory tile. The data is exposed via `GET /onering/matrix` and the typed Angular model exists; building the actual UI components is a follow-up ticket so this phase stays scoped to "banner + polling + retry" exactly like v1.

---

### Phase 12 — Prod-readiness: SLO, alerting, runbook, secrets, dashboard [TEST_REVIEW]

```phase-meta
phase: 12
title: Prod-readiness - SLO, on-call, alerts, runbook, Key Vault, Grafana (both DAGs)
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
  - "8.1 Grafana panels (both DAGs)"
  - "8.2 Alerts (both DAGs)"
  - "8.3 Correlation IDs"
verification:
  - "helm lint helm/"
  - "promtool check rules grafana/alerts/onering-compliance.yaml"
  - "jq empty grafana/dashboards/onering-compliance.json"
```

**Goal**: First-prod-cutover gate. Counted as a **separate ~4–6 engineer-week pool** (up from v1's 3–5), not folded into the integration estimate. v2 carries more dashboards/alerts because both DAGs need their own panels. Tracked as a parallel workstream from the start of integration work, not a week-3 surprise. Owners assigned at kickoff.

**Steps**:

- [ ] **12.1** Draft `slo.md` covering **both** DAGs:
  - `arc_compliance_review`: target p95 wall-clock < 45 min for ≤10 documents (up from v1's 30 min — full pipeline is heavier).
  - `arc_compliance_response_check`: target p95 wall-clock < 10 min per response.
  - Error-rate target per DAG, error budget, success-rate target.
  - **Seed with week-1 gate W1.2 measurements** (`docs/onering-compliance/baseline-measurements.md` — both DAGs measured separately). Placeholder thresholds get replaced by p50/p95 from real numbers, not vibes. **Stakeholder commit before staging pilot.** Phase 14 staging-pilot start gated on this checkbox.
- [ ] **12.2** Draft `runbook.md` covering: stuck run (either DAG), schema validation failure (matrix schema vs response-check schema mismatch), pool saturation, materializer failure (split per materializer), document-deleted-mid-run, response-replaced-mid-check, matrix-pointer-cleared-during-response-check (response-check started while a source-doc re-extract is in flight — both paths must agree on what compliance_items look like). Each failure mode lists detection signal, immediate mitigation, root-cause investigation steps.
- [ ] **12.3** Draft `oncall.md`: rotation, paging policy by severity, escalation to engine team for `OneringSchemaError` AND for response-check-pipeline-specific issues (since that pipeline is genuinely new and the engine team is most familiar with its failure modes).
- [ ] **12.4** Wire correlation IDs into NestJS request-context async storage per Contracts §8.3. Every log line for **either** Compliance run carries `correlation_id`, `org_id`, `project_id`, `response_id` (if applicable), `arc_run_id`, `run_type`, `dag_run_id`, `airflow_dag_id`.
- [ ] **12.5** Key Vault paths for `ONERING_AIRFLOW_USERNAME` / `ONERING_AIRFLOW_PASSWORD` agreed with security; Helm wiring per `rohan_api/CLAUDE.md` Helm conventions. **Log scrubber audit.** Same as v1 step 11.5 — masks `Authorization` header at every log level and target.
- [ ] **12.6** Grafana dashboard JSON per Contracts §8.1 with **separate row groups for each DAG** (review + response-check). Alert rules YAML per §8.2 — alerts include `ComplianceReviewRunStuck` (60 min), `ComplianceResponseCheckRunStuck` (15 min — tighter because the SLO is tighter), `ComplianceReviewFailureRate` (>20% in 30 min), `ComplianceResponseCheckFailureRate` (>10% in 30 min — tighter because each response is user-facing), plus `OneringSchemaError` and `OneringMatrixPointerInconsistency` (engine emitted a successful matrix that the materializer rejected). SRE review.
- [ ] **12.7** Image registry promotion path validated (rohan_api + ONERING images both in prod registry).
- [ ] **12.8** Network policy: Airflow ingress allows rohan_api egress; rohan_api reads MinIO via existing path. No changes vs v1 — same network surface.

---

### Phase 13 — CI: airflow opt-in workflow + dual schema cross-check [TEST_REVIEW]

```phase-meta
phase: 13
title: CI - test:e2e:airflow workflow + dual schema cross-check (matrix + response_check)
tags: [TEST_REVIEW]
repo: rohan_api
base_branch: phase-10
depends_on: [10, 11, 12]
files:
  - .github/workflows/test-e2e-airflow.yml
  - .github/workflows/onering-schema-check.yml
  - .github/workflows/onering-cost-summary-check.yml
  - test/compliance-airflow.e2e-spec.ts
  - test/response-check-airflow.e2e-spec.ts
  - test/fixtures/compliance_matrix.fixture.json
  - test/fixtures/response_check.fixture.json
  - test/fixtures/cost_summary.fixture.json
  - package.json
contracts:
  - "9.1 test:e2e:airflow opt-in CI workflow"
  - "9.2 Schema cross-check job (two schemas)"
  - "9.4 Cost summary smoke check"
verification:
  - npm run lint
  - "act -j test:e2e:airflow --container-architecture linux/amd64"
  - npm run test:e2e -- --grep compliance-airflow
  - npm run test:e2e -- --grep response-check-airflow
```

**Goal**: Catch DAG drift, schema drift (two schemas now), pool/timeout regressions in CI on demand or nightly.

**Steps**:

- [ ] **13.1** Add `.github/workflows/test-e2e-airflow.yml` per Contracts §9.1. PR label `test:airflow` and nightly cron. Runs both new E2E specs (compliance-airflow + response-check-airflow).
- [ ] **13.2** Add `.github/workflows/onering-schema-check.yml` per Contracts §9.2. Every PR. Fetches ONERING at the pinned tag, runs the rohan_api validators against the sample fixtures, AND asserts byte-equal match between:
  - `rohan_api/src/onering/__mocks__/compliance_matrix.fixture.json` ↔ ONERING-side fixture.
  - `rohan_api/src/onering/__mocks__/response_check.fixture.json` ↔ ONERING-side fixture.
  Closes the manual-sync drift gap on both schemas.
- [ ] **13.3** Implement `compliance-airflow.e2e-spec.ts` using the existing `TestClientFactory`: triggers `POST /compliance/projects/:id/onering/extract`, polls `GET /onering/runs`, asserts items materialized from `compliance_matrix.json`, asserts `compliance_projects.compliance_matrix_json_key` populated, asserts `GET /compliance/projects/:id/onering/matrix` returns the parsed JSON, asserts retry idempotency, asserts admin force-cancel transitions a stuck synthetic run.
- [ ] **13.4** Implement `response-check-airflow.e2e-spec.ts`: triggers `POST /compliance/responses/:id/onering/check`, polls, asserts `compliance_checks` rows materialized with PASS/FAIL automated_status from `response_check.json`, asserts evidence rows replaced atomically (no orphans), asserts retry preserves human-set `user_determination`.
- [ ] **13.5** Add `npm run test:e2e:airflow` script that wraps `npm run test:e2e:ci` with the airflow grep filter (covers both specs).
- [ ] **13.6** Add `.github/workflows/onering-cost-summary-check.yml` per Contracts §9.4. Nightly. Runs the dev-mock pipeline end-to-end and asserts `AGENT_RUNS/{run_id}/cost_summary.json` is present and parses against the schema. Both DAGs share the cost summary rollup format.
- [ ] **13.7** **Helm parity job lives in the ONERING repo (Phase 4.5).** This step only documents the cross-repo dependency: rohan_api PRs that bump the pinned ONERING ref must be reviewed alongside an ONERING release that has passed `onering-helm-parity.yml`. Phase 14 cutover step references the same gate.

---

### Phase 14 — Cutover: pilot rollout + both legacy listeners retired [TEST_REVIEW]

```phase-meta
phase: 14
title: Cutover - pilot rollout, batch enable, retire both legacy listeners
tags: [TEST_REVIEW]
repo: rohan_api
base_branch: phase-13
depends_on: [13]
files:
  - src/compliance/listeners/compliance.listener.ts
  - src/compliance/listeners/compliance.listener.spec.ts
  - docs/onering-compliance/cutover-log.md
contracts:
  - "10.1 Flag flip plan"
  - "10.2 Listener retirement (both handlers)"
verification:
  - npm run lint
  - npm run test -- src/compliance/listeners/compliance.listener.spec.ts
  - npm run test:e2e -- --grep compliance
```

**Goal**: Flip the flag for staging, then production pilot, then batch. After 2-week clean window, retire **both** legacy listeners: the source-doc `tagging.auto-tag-complete` handler AND the response-doc `compliance.response.analyze` handler.

**Steps**:

- [ ] **14.1** Enable `ONERING_COMPLIANCE` for one staging org. Run end-to-end happy path + retry path manually **for both DAGs**: trigger source-doc extraction, then upload a response and trigger response-check. Capture results in `cutover-log.md`.
- [ ] **14.2** Enable for one prod pilot org. 1-week soak with daily Grafana check. Watch both DAG dashboards independently — a healthy source-doc DAG with a flapping response-check DAG (or vice versa) is a real risk profile.
- [ ] **14.3** Batch-enable remaining prod orgs in groups of 5, 24-hour spacing.
- [ ] **14.4** After 2-week clean window post-100%-enable: delete **both** legacy listeners — locate by decorator, not line number:
  - `@OnEvent('tagging.auto-tag-complete')` source-doc handler.
  - `@OnEvent('compliance.response.analyze')` response-doc handler.
  Other listeners (`compliance.auto.tag` enqueue handler) remain — that's the upstream queueing logic, not the swapped path.
  - **Pre-delete drain check (both queues).** Before deletion, confirm rohan-python-api has no in-flight `AutoTagRequest` for any flagged-on org for ≥24h, AND no in-flight response-analysis equivalent: Service Bus main queue empty, dead-letter queue empty, no `auto_tag_jobs` rows in non-terminal state for those orgs. The Phase 8.6 listener fences have been short-circuiting both for the entire bake window, so this is a final sanity check.
  - **Coordinate** the matching rohan-python-api publish removal for BOTH paths in the same release window. Out of scope as a code change in this repo but in scope as a coordination item — file the Python API ticket at start of Phase 14.
- [ ] **14.5** Tag the rohan_api repo `onering-compliance-v2` and update the pinned ONERING git-sync ref to the matching engine release tag.
- [ ] **14.6** Bump the ONERING submodule pin in `rohan-python-api/backend/arc_agent_writer/` to the same engine release tag used in `values-prod.yaml`. Hygiene step per Contracts §1.6.

---

## Phase order, dependencies, and parallelism

### File-touch matrix

| Phase | rohan_api files | ONERING files | rohan_ui files | Database/SRE files |
|-------|-----------------|---------------|----------------|---------------------|
| 1 | — | factories/compliance_review.py, orchestrator/cost_summary, tests/factories/, tests/orchestrator/, tests/fixtures/compliance_matrix.sample.json | — | — |
| 2 | — | airflow/dags/arc_compliance_review_dag.py, specs/compliance_matrix.schema.json, airflow/CLAUDE.md | — | — |
| 3 | — | factories/compliance_response_check.py, pipelines/response_check/, airflow/dags/arc_compliance_response_check_dag.py, specs/response_check.schema.json, tests/fixtures/response_check.sample.json | — | — |
| 4 | — | helm/onering-airflow/ + .rendered/ baselines, .github/workflows/onering-helm-parity.yml, docs/onering-airflow/sizing-model.md | — | — |
| 5 | onering/types, onering/enums, onering/dto (extract + check), feature-flags/types | — | — | — |
| 6 | compliance/entities, onering/entities, scripts/sql | — | — | Database/ migration (compliance_items + compliance_checks + compliance_projects.compliance_matrix_json_key + or_pipeline_runs typed cols + compliance_audit_log) |
| 7 | onering/services/{pipeline,airflow-client,org-lookup,run-reaper}, compliance/services/compliance.service.ts (clear-pointer hook), onering/onering.module | — | — | — |
| 8 | onering/services/{compliance-matrix-validator,response-check-validator}, onering/onering.errors, compliance/services/{compliance-onering-materializer,compliance-response-check-materializer}, compliance/listeners | — | — | — |
| 9 | compliance/{controller,service,errors,module}, compliance/dto (extract + check + getMatrix) | — | — | — |
| 10 | onering/services/airflow-client, onering/__mocks__/{compliance_matrix,response_check}.fixture.json | — | — | .env.example |
| 11 | — | — | pages/compliance/{types,services,components} (run-type-aware banner: 5 source-doc states + 5 response-check states) | — |
| 12 | docs/, helm/, grafana/ | — | — | Key Vault, network policy |
| 13 | .github/workflows/{test-e2e-airflow,schema-check,cost-summary-check}, test/{compliance-airflow,response-check-airflow}.e2e-spec.ts | — | — | — |
| 14 | compliance/listeners/, docs/ | — | — | — |

No file is touched by two integration phases simultaneously. Phases 5–10 stack on each other in rohan_api; 1–4 stack in ONERING (1=matrix factory → 2=matrix DAG+schema → 3=NEW response-check pipeline+DAG+schema → 4=Helm pool bumps that depend on the final shape of both pipelines); 11 starts independently in rohan_ui after the contracts are stable (after Phase 5); 12 is parallel from kickoff; 13–14 are sequential post-integration.

### Parallelism options

**Four concurrent streams from kickoff:**

- **Stream A (engine):** Phases 1 → 2 → 3 → 4 in ONERING. ~1–1.5 engineers. Phase 3 is a meaningful chunk on its own — new pipeline build, prompts, models — so budget accordingly. Phase 4 cannot start until 3 is at least scoped so the pool-sizing model is correct.
- **Stream B (rohan_api):** Phases 5 → 6 → 7 → 8 → 9 → 10 in rohan_api. ~1.5–2 engineers (up from ~1–2 in v1 because of the second DAG: extra DTOs, extra entity columns, extra trigger service method, extra validator, extra materializer, extra controller endpoint). Phase 6 has a dependency on the `Database/` repo PR landing first; budget 2–3 calendar days for that handoff. Schema-before-service ordering is intentional.
- **Stream C (UI):** Phase 11 starts as soon as Phase 5 lands (contract-stable). ~0.5–0.75 engineer (run-type-aware banner with two distinct flows + the matrix viewer hook adds real surface area).
- **Stream D (prod-readiness, parallel):** Phase 12 from day 1. SRE-led. Owners assigned at kickoff. Engineer-week pool bumped vs v1 because of dual SLO targets, dual dashboards, dual alerts.

**Convergence:** Phase 13 needs Phases 10, 11, 12 green. Phase 14 strictly serial after 13.

### Recommended sequential order with rationale

If forced to a single-thread sequence (one engineer):

1. **Phase 5** (types) — unblocks rohan_api spec writing and rohan_ui interface stubs for both run types.
2. **Phase 1** (engine compliance_matrix factory) — without this the source-doc rest is hypothetical.
3. **Phase 2** (matrix DAG + schema) — schema unblocks the rohan_api matrix validator.
4. **Phase 3** (response-check pipeline + DAG + schema) — schema unblocks the rohan_api response-check validator.
5. **Phase 6** (DB schema) — Database/ repo PR lands first.
6. **Phase 7** (trigger service for BOTH DAGs) — writes typed columns added in Phase 6.
7. **Phase 8** (materializers + validators + listener fences).
8. **Phase 9** (controller + flag dual-path for BOTH endpoints).
9. **Phase 10** (dev mock with two fixtures).
10. **Phase 4** (Helm pool bumps) — only needs to land before staging pilot.
11. **Phase 11** (UI with run-type-aware banner).
12. **Phase 12** (prod-readiness) — best done as parallel workstream from day 1, but if strictly sequential, before Phase 14.
13. **Phase 13** (CI with two E2E specs and two schema cross-checks).
14. **Phase 14** (cutover with BOTH listener retirements).

The actual recommendation is the four-stream parallel model above; the sequential list exists only as a fallback for solo execution.

---

## Phase context summaries (for coding agents)

Each summary is self-contained — under 150 words — and tells an implementer what the phase produces, what it depends on, and any gotchas.

**Phase 1 (engine: full-pipeline matrix factory).** Adds `compliance_review:build_steps` factory in ONERING producing a 12-step graph that runs all relevant upstream pipelines (metadata → structure → evaluation → instructions → attachments → requirements → response_guidance → budget_allocation) and culminates in `pipelines.compliance_matrix` (with `compliance_mode=True`). Output artifact is `AGENT_RUNS/{run_id}/pipelines/compliance_matrix/compliance_matrix.json` — the same shape ARC writers consume internally, now externally consumable. Also emits `AGENT_RUNS/{run_id}/cost_summary.json` (run-level rollup). **Cost gotcha**: this is roughly 5–10× the LLM cost of the v1 thin graph; the cost regression gate in Week 1 fallback gates exists precisely to catch this on real RFPs before pilot. Reference fixture committed under `tests/fixtures/compliance_matrix.sample.json`.

**Phase 2 (matrix DAG + schema).** Ships `arc_compliance_review_dag.py` mirroring `arc_launch_proposal_dag.py`, plus `specs/compliance_matrix.schema.json` v1. `dag_run.conf` envelope: `{ org_id, user_id, project_id, document_ids, expected_run_id, responding_company?, llm_mode?, verbose? }`. Tags `["arc","compliance","extraction","matrix"]`, `max_active_runs=4`. Depends on Phase 1's factory existing. Schema versioning: any rohan_api-breaking change bumps `schema_version` to `"2"`. Pod resource profile bumped from the thin-graph defaults to account for the longer-running upstream extraction steps.

**Phase 3 (NEW response-check pipeline + DAG + schema).** Brand-new work, not a port. Adds `arc_agent_writer/pipelines/response_check/` (with `pipeline.py`, `models.py`, `prompts.py`, `ui_projection.py`) — the analyzer that reads denormalized `compliance_items` out of `dag_run.conf` and emits `response_check.json` with `{ automated_status: pass|fail|review, evidence: [{document_id, snippet, page, locator}], confidence, rationale }` per item. Also adds `factories/compliance_response_check.py` (response-check step graph), `airflow/dags/arc_compliance_response_check_dag.py` (separate DAG, separate pool slot budget), `specs/response_check.schema.json`, and `tests/fixtures/response_check.sample.json`. **Gotcha**: the input contract is denormalized — rohan_api flattens approved compliance items into a single list inside `dag_run.conf` so the engine doesn't need a DB read path. Engine release tag for this phase MUST cover both DAGs together.

**Phase 4 (Helm pools + git-sync pin + Helm parity CI).** Bumps `llm_extraction_pool` to 6 slots (was 4) and `llm_aggregation_pool` to 3 slots (was 2) in `airflow-init` job. Sizing rationale documented in `docs/onering-airflow/sizing-model.md`: matrix DAG holds extraction slots ~3× longer than v1 thin graph because of the full upstream pipeline; response-check DAG holds aggregation slots for the analyzer. Concurrent target: 4 matrix DAGs + 4 response-check DAGs without queueing. Pins `gitSync.ref` in all three env values files to a specific engine release tag — never `main` — closing the engine-team-can-break-prod gap. Adds `onering-helm-parity.yml` CI job that renders each env, diffs against checked-in baselines under `helm/onering-airflow/.rendered/`. SRE reviews `values-prod.yaml`.

**Phase 5 (rohan_api types).** Pure type/enum/DTO surface area. Adds `OneringDagId.COMPLIANCE_REVIEW` AND `OneringDagId.COMPLIANCE_RESPONSE_CHECK`; `RunType.COMPLIANCE_REVIEW` AND `RunType.COMPLIANCE_RESPONSE_CHECK`; `ComplianceReviewConf` and `ResponseCheckConf` interfaces (the latter carries the denormalized compliance-items array); `ONERING_COMPLIANCE` feature flag enum; request/response DTOs for both endpoints. No behavior change. Must check `RunType` switch-case completeness in `OneringPipelineService.refreshRunStatus()` — easy place to miss the new enum value.

**Phase 6 (DB schema).** Three entity expansions in a single Database/-repo PR: (1) `compliance_items` adds `arc_run_id` UUID, `arc_requirement_id` VARCHAR(128), `stable_hash` VARCHAR(64) + indexes. (2) `compliance_checks` adds `arc_run_id` UUID, `arc_response_check_id` VARCHAR(128), `stable_hash` VARCHAR(64), `confidence` NUMERIC, `automated_rationale` TEXT + indexes. (3) `compliance_projects` adds `compliance_matrix_json_key` VARCHAR(512) — pointer to the materialized `compliance_matrix.json` in MinIO, so the UI can render the full hierarchical view without re-flattening DB rows. (4) `or_pipeline_runs` adds typed `project_id` UUID, `response_id` UUID, `document_ids` UUID[], `materialized_at` TIMESTAMPTZ. Index `(organization_id, project_id, started_at DESC)` and `(organization_id, response_id, started_at DESC)` for the two listing flows. Per `rohan_api/CLAUDE.md`, the SQL is authored in the `Database/` repo and synced. **Do not edit `rohan_api/scripts/sql/` directly.** Lands BEFORE Phase 7 service code.

**Phase 7 (trigger services + reaper + cadence pin + clear-pointer hook).** Three pieces: (1) `OneringPipelineService.triggerComplianceReview(...)` (source-doc DAG, behavior largely unchanged from v1). (2) `OneringPipelineService.triggerResponseCheck(orgId, userId, responseId, options)` — looks up the response's parent project, reads all approved `compliance_items` from DB, denormalizes them into `ResponseCheckConf.items[]`, writes typed `response_id` and `document_ids` (response doc(s)) on `or_pipeline_runs`, calls Airflow. Idempotent on 409. (3) Hook in `ComplianceService.replaceSourceDocuments(...)` that clears `compliance_projects.compliance_matrix_json_key` whenever the source document set changes (the materialized JSON is now stale until a new matrix run completes). Adds `OneringRunReaperService` (every 5 min) that detects stuck runs at >90 min and force-fails at >180 min via `killDagRun()` — works for BOTH run types. Polling cadence pinned: 15 s for PENDING/QUEUED, 5 s for RUNNING.

**Phase 8 (validators + materializers + listener fences).** Four pieces: (1) `ComplianceMatrixValidatorService` and (2) `ResponseCheckValidatorService` — both ajv@^8, `additionalProperties: true`, version-strict on `schema_version`, throws `OneringSchemaError`. (3) `ComplianceOneringMaterializerService.materialize(arcRunId, dagRunId)` flattens the hierarchical `compliance_matrix.json` into `compliance_items` rows AND persists the JSON object key on `compliance_projects.compliance_matrix_json_key` in the same transaction — UI gets both the flat list (for the table) and the pointer (for the hierarchical viewer). Phase A (read+validate, A4a JSON-vs-run-row cross-check) / Phase B (mutate, single tx) split. Match by `(source_document_id, stable_hash)` only, scoped supersede. (4) `ComplianceResponseCheckMaterializerService.materialize(arcRunId, dagRunId)` writes `compliance_checks` rows (with `automated_status`, `confidence`, `automated_rationale`) AND replaces `compliance_item_evidence` rows atomically per check (delete + insert in tx, no orphan windows). Preserves any human-set `user_determination` on retry. (5) Two listener fences in `compliance.listener.ts`: short-circuits `tagging.auto-tag-complete` AND `compliance.response.analyze` when `ONERING_COMPLIANCE` is on for the event's org. Idempotency latch `or_pipeline_runs.materialized_at`.

**Phase 9 (controller + dual-path + admin cancel).** Five endpoints added/modified: (1) `POST /compliance/projects/:id/onering/extract`, (2) `GET /compliance/projects/:id/onering/runs`, (3) `POST /compliance/projects/:id/onering/runs/:arcRunId/cancel`, (4) `POST /compliance/responses/:id/onering/check`, (5) `GET /compliance/responses/:id/onering/runs`, plus (6) `GET /compliance/projects/:id/onering/matrix` returning the parsed `compliance_matrix.json` (404 if `compliance_matrix_json_key` is null — surfaces "needs re-run" UI state). All endpoints use the two-stage org check (load by `id` → 404 unless org match → query runs with explicit org filter — no id-only lookups). Cancel endpoint works for either run type via `RunType` switch. Modifies `POST /compliance/projects/:projectId/documents/process` AND `POST /compliance/responses/:id/analyze` for dual-path discriminated union (`path: 'legacy' | 'onering'`). New error classes: `ComplianceNoDocumentsError`, `ComplianceNoApprovedItemsError`, `ComplianceMatrixNotMaterializedError`, `ComplianceRunInProgressError`. 409 if non-terminal run exists; 409 if already terminal for cancel.

**Phase 10 (dev mock).** When `ONERING_AIRFLOW_BASE_URL` empty + `NODE_ENV !== 'production'` + `ONERING_AIRFLOW_MOCK !== 'disabled'`, `OneringAirflowClientService.triggerDagRun()` delegates to `AirflowMockService` which dispatches on `dag_id` and writes the matching fixture (`compliance_matrix.fixture.json` or `response_check.fixture.json`) through `OneringMinioService`, then schedules a 100 ms status flip. Polling pathway downstream is the same as prod. Both fixture files kept in sync with ONERING via Phase 13 CI cross-check.

**Phase 11 (UI).** Adds `ComplianceRunService` with two trigger surfaces (`triggerExtract`, `triggerCheck`), two listing surfaces (`listExtractRuns`, `listCheckRuns`), a `getMatrixJson()` method that fetches `/onering/matrix`, and a unified cancel. `compliance-extracting-banner` becomes run-type-aware: source-doc states (`extracting`, `extracting-late`, `extract-failed`, `extract-partial`, `stale`) + response-check states (`checking`, `checking-late`, `check-failed`, `check-partial`, `check-stale`). Wired into `company-detail` and any matrix-viewer component that loads the JSON for the hierarchical display. Polling cadence 10 s active → 30 s after 5 min → stop on terminal. Admin force-cancel CTA in `-late` states. Audit trail deep-link updated to discriminate between run types.

**Phase 12 (prod-readiness).** SLO doc with SEPARATE targets for matrix DAG (e.g., p95 < 30 min, success rate > 95%) and response-check DAG (e.g., p95 < 15 min, success rate > 95%). Runbook with separate sections per DAG including reaper + force-cancel + JSON-mismatch flows. On-call doc, correlation-ID async-storage wiring, Key Vault paths for Airflow basic-auth, Helm config-map wiring. Grafana dashboard with two row groups (matrix + response-check) and a shared cost panel from `cost_summary.json`. Alert rules YAML with per-DAG variants. **Engineer-week pool bumped from v1 (~3–5) to ~5–7** because of dual surface area. Tracked as a parallel workstream from kickoff with named owners — not a week-3 surprise.

**Phase 13 (CI).** Adds `test:e2e:airflow` opt-in workflow (PR label `test:airflow` + nightly cron), `onering-schema-check` per-PR job that validates BOTH rohan_api ajv compilers against the ONERING-side fixtures AND asserts byte-equal sync between BOTH dev-mock fixtures and BOTH ONERING fixtures (closes manual-sync drift gap on both schemas), and `onering-cost-summary-check` nightly job. Plus `compliance-airflow.e2e-spec.ts` (matrix trigger → poll → materialize → matrix endpoint → retry → admin force-cancel) AND `response-check-airflow.e2e-spec.ts` (check trigger → poll → materialize → evidence atomic-replace → user-determination preservation on retry). Helm parity job lives in the ONERING repo (Phase 4.5).

**Phase 14 (cutover).** Flag flip per stage: staging org → prod pilot org (1-week soak watching BOTH DAG dashboards) → batches of 5 (24-hour spacing). After 2-week clean window, delete BOTH legacy listeners (`tagging.auto-tag-complete` AND `compliance.response.analyze`) by decorator lookup, not line number. Pre-delete drain check confirms both Service Bus queues empty for ≥24 h. Coordinate matching rohan-python-api publish removal for both paths in the same release window. Tag rohan_api `onering-compliance-v2`; pin ONERING git-sync ref to the engine release covering both DAGs.

---

## Jira (epic + per-phase tickets)

This work is an **epic** with one subticket per phase. Suggested epic + ticket shape:

### Epic — `onering-compliance-integration-v2`

**Title:** ONERING Integration — Compliance launch via Airflow (v2: full matrix + response check)

**Description:** Replace the Compliance auto-extraction Service-Bus path AND the response-document analysis path with two Airflow-orchestrated DAGs:
- **`arc_compliance_review` (source-doc DAG)** runs the full ONERING extraction graph (metadata → structure → evaluation → instructions → attachments → requirements → response_guidance → budget_allocation → compliance_matrix) producing `compliance_matrix.json`, the rich hierarchical artifact ARC writers already consume internally.
- **`arc_compliance_response_check` (response-doc DAG)** runs a new `pipelines.response_check` over approved compliance items + a response document, producing `response_check.json` with per-item automated PASS/FAIL/REVIEW status, evidence snippets, confidence, and rationale.

Reuses the existing `/onering/*` namespace, `or_pipeline_runs` run metadata, `OneringAirflowClientService`, `OneringArtifactService`, `OneringExceptionFilter`. Ships behind `ONERING_COMPLIANCE` feature flag with dual-path during rollout. Supersedes the v1 thin-graph plan (`onering-compliance-integration-PLAN.md`). First production cutover of the ONERING Airflow stack — prod-readiness tracked as a parallel workstream.

**Cost note:** This is ~5–10× the LLM cost of v1 per source-doc run (full pipeline vs. thin requirements-only) plus the new response-check cost per response. The Week-1 cost regression fallback gate exists to catch this on real RFPs before pilot.

**Acceptance criteria:**

- [ ] Phase 1: Engine `compliance_review:build_steps` factory produces 12-step full-pipeline graph terminating in `pipelines.compliance_matrix` (`compliance_mode=True`); emits `compliance_matrix.json` + `cost_summary.json`; reference fixture committed; passes engine PR review.
- [ ] Phase 2: `arc_compliance_review` DAG ships with v1 `specs/compliance_matrix.schema.json`; pod resource profile bumped for longer-running upstream steps; DAG unit test green.
- [ ] Phase 3: `arc_agent_writer/pipelines/response_check/` new pipeline implemented; `factories/compliance_response_check.py` + `arc_compliance_response_check_dag.py` shipped; v1 `specs/response_check.schema.json` + reference fixture committed; denormalized input contract documented; engine-release tag covers BOTH DAGs.
- [ ] Phase 4: Helm pools bumped (`llm_extraction_pool=6`, `llm_aggregation_pool=3`) with sizing model documented; `gitSync.ref` pinned to engine tag (no `main`) in all envs; `onering-helm-parity.yml` CI job + checked-in baseline renders; `values-prod.yaml` SRE-reviewed.
- [ ] Phase 5: rohan_api enums (BOTH `RunType.COMPLIANCE_REVIEW` AND `RunType.COMPLIANCE_RESPONSE_CHECK`), types (`ComplianceReviewConf`, `ResponseCheckConf`), DTOs (extract + check), and `ONERING_COMPLIANCE` feature flag landed.
- [ ] Phase 6: `compliance_items.arc_run_id`/`arc_requirement_id`/`stable_hash` columns + `compliance_checks.arc_run_id`/`arc_response_check_id`/`stable_hash`/`confidence`/`automated_rationale` columns + `compliance_projects.compliance_matrix_json_key` column + `or_pipeline_runs.project_id`/`response_id`/`document_ids`/`materialized_at` typed columns + `compliance_audit_log` table + indexes applied via Database/ repo sync. Lands BEFORE Phase 7.
- [ ] Phase 7: `OneringPipelineService.triggerComplianceReview()` AND `triggerResponseCheck()` implemented and unit-tested; both idempotent on Airflow 409; clear-pointer hook on source-doc replacement zeroes `compliance_matrix_json_key`; `OneringRunReaperService` cron handles both run types and force-fails stuck runs at >90/180 min; reconciler polling cadence pinned (15s/5s).
- [ ] Phase 8: BOTH schema validators (additive-tolerant, version-strict) + matrix materializer (flattens hierarchy → `compliance_items` rows AND persists JSON key on `compliance_projects`) + response-check materializer (writes `compliance_checks` + atomic evidence replace + preserves human `user_determination` on retry) + idempotency latches + audit log + TWO listener fences (`tagging.auto-tag-complete` AND `compliance.response.analyze`).
- [ ] Phase 9: `POST /compliance/projects/:id/onering/extract`, `GET /compliance/projects/:id/onering/runs`, `POST .../onering/runs/:arcRunId/cancel`, `POST /compliance/responses/:id/onering/check`, `GET /compliance/responses/:id/onering/runs`, AND `GET /compliance/projects/:id/onering/matrix` (returns parsed `compliance_matrix.json`). Both `documents/process` and `responses/:id/analyze` feature-flagged dual-path live.
- [ ] Phase 10: in-process Airflow mock dispatches on `dag_id` to write BOTH `compliance_matrix.fixture.json` and `response_check.fixture.json` via MinIO; UI engineers iterate without `make up-airflow`.
- [ ] Phase 11: run-type-aware extracting banner (5 source-doc states + 5 response-check states), polling, retry, audit deep-link discriminating by run type; admin force-cancel CTA in `-late` states; matrix-viewer hook calls `getMatrixJson()` for hierarchical display.
- [ ] Phase 12: prod-readiness — SLO doc with separate targets per DAG, runbook with per-DAG sections (incl. reaper + force-cancel + JSON-mismatch flows), on-call, correlation IDs, Key Vault, Grafana dashboard with two row-groups + shared cost panel, alerts (incl. `OrgConsistencyMismatch`, `ComplianceRunReaperFiring`) with per-DAG variants.
- [ ] Phase 13: `test:e2e:airflow` opt-in workflow + `onering-schema-check` per-PR job (validates BOTH schemas + mock-vs-engine fixture sync for BOTH fixtures) + `onering-cost-summary-check` nightly job; `compliance-airflow.e2e-spec.ts` AND `response-check-airflow.e2e-spec.ts` green.
- [ ] Phase 14: pilot rollout to one prod org with 1-week soak watching BOTH DAG dashboards, batch-enable remaining orgs, retire BOTH legacy listeners (`tagging.auto-tag-complete` AND `compliance.response.analyze`) after 2-week clean window with pre-delete drain check on both queues, bump prod `gitSync.ref` to engine release matching `onering-compliance-v2`.

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
| Messaging | Service Bus (legacy auto-tag + response-analyze paths, both retired Phase 14) |

---

## Out of plan but worth flagging

- **Azure Government (`.us`) feasibility.** Per user direction: not in scope for Phase 1, mentioned here as a follow-up. `ONERING_COMPLIANCE` flag stays off for Gov orgs at launch. Spike scope: does the ONERING Airflow Helm chart deploy cleanly to Gov AKS; does the OpenAI client respect the `.us` endpoint switch; image registry promotion to Gov registry. File a separate ticket post-launch.
- **Custom step-graph governance.** As more module-specific factories ship (`compliance_review`, eventually `mra_assistant`, `ae_v2`), step-name collisions and prompt drift become real. Suggest a registry pattern in ONERING — modules register namespaced prefixes and the orchestrator validates uniqueness. Not a Phase 1 blocker, but worth filing as a follow-up.
- **Engine version contract enforcement.** Pinned Airflow git-sync ref + JSON Schema validators (two of them now: matrix + response-check) + Phase 13 CI cross-check is the Phase 1+2 mitigation. A versioned engine API surface (proper SemVer) is deferred to proposal Phase 3.
- **Additional extraction tabs.** Because the source-doc DAG now runs the full pipeline (Phase 1), tabs for evaluation criteria, instructions, attachments, response-guidance, etc. are *generated* server-side as part of `compliance_matrix.json`. **UI surfacing of those extra tabs is explicitly out of scope** for this plan — only the requirements/items view and the response-check view ship in Phase 11. File a follow-up epic to surface the other tabs (the data is already there).
- **Response-check confidence calibration.** The `confidence` field on `compliance_checks` is captured from the engine but no UI threshold logic is built in this plan (e.g. auto-flagging low-confidence items for human review). Filed as a follow-up.
- **Matrix viewer component.** This plan persists `compliance_matrix_json_key` and exposes `GET /onering/matrix` (Phase 9) and `getMatrixJson()` (Phase 11) so the data is available to a hierarchical viewer, but the rich-tree viewer component itself is **not** scoped here — Phase 11 only wires the data hook into existing list/table views. Build the dedicated viewer as a follow-up UI epic.
