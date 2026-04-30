# ONERING as Engine: Integration Proposal for Acquisition Center, Answer Engine v2, and Compliance

## Executive Summary

All three modules independently reinvent capabilities ONERING already has — document ingestion, KM-style retrieval, requirement extraction, structured generation. **Compliance has the strongest structural overlap and has not yet launched**, making it the natural first integration target. Answer Engine v2 (already in production) and Acquisition Center are deferred several months while Compliance proves the engine pattern.

The pattern that makes sense: ONERING runs as the AI compute layer behind rohan-python-api, exposing capabilities both as fast inline endpoints and as async DAG runs. NestJS modules become thinner shells that own user-facing state (projects, threads, items) and delegate AI work to the engine.

**Recommended sequence:** ship a thin ONERING-driven Compliance launch in the next few weeks (Phase 1: unified ingestion endpoint + per-org tenancy + requirements extraction + items review). Expand Compliance scope post-launch (Phase 2: additional extraction tabs, response-analysis DAG, XLSX export). Migrate Answer Engine v2 (Phase 3) and Acquisition Center (Phase 4) as later phases once the wrapper layer is proven.

---

## Module Snapshots

### Acquisition Center (Procurement Writer)

Multi-step procurement drafting — Market Research Assistant (MRA), RFI Assistant, Requirements Discovery, Document Library, Template Generator, Toolkits. Backend at `rohan_api/src/procurement-writer/` is a 1,700-line service with streaming SSE controllers and a `wizard_state` JSONB blob for multi-step state. AI pattern is consistent across assistants: fetch prompt by feature flag → enrich with `addDocContent()` (manual document-summary append) and `addVectorDBResults()` (pgvector query for 10 paragraphs + 10 tables) → `handleCompletion()` for SSE streaming.

### Answer Engine v2

Threaded conversational Q&A with KM retrieval, deep research (o3), file-context uploads, streaming responses, aggregates, and summaries. Backend at `rohan_api/src/answer-engine-v2/` is a 2,300-line service with advisory locks, `Question`/`Answer`/`Thread`/`Aggregate`/`Summary` entities, and heavy use of `AgentWorkflowService.getKmWorkflow()` (LangChain-based LLM-as-retriever) plus `RfpPythonServer.extract-file-content` for file parsing. Determines a follow-up route (REUSE_EXISTING_KM_CONTEXT vs RERUN_KM vs RESEARCH_WITH_KM_CONTEXT vs RESEARCH_ONLY) before streaming.

### Compliance

Source-document compliance item extraction → manual review → response-document upload → automated cross-check → reviewer adjudication. Inline tag UI on the document viewer (recent PRCR-1517/1519/1544 work). Backend at `rohan_api/src/compliance/` has entities `ComplianceProject`, `ComplianceItem`, `ComplianceCheck`, `ComplianceItemEvidence`, `ComplianceDocument`, `ComplianceResponse`. Auto-extraction is async: Service Bus → rohan-python-api (GPT-5.2 extracts shall-statements with line offsets) → completion handler updates DB. **Not yet in production — launch target is approximately a few weeks out, no specific feature commitments, sales wants to start selling the module as soon as it ships.**

---

## ONERING Capability Map

| ONERING capability                                                                  | Compliance                                           | AE v2                                     | Acquisition Center                              |
| ----------------------------------------------------------------------------------- | ---------------------------------------------------- | ----------------------------------------- | ----------------------------------------------- |
| Document ingestion (Docling + OCR + canonical markdown + line numbering + chunking) | ✅ Replace inline rohan-python-api path              | ✅ Replace `extract-file-content`         | ✅ Replace doc-summary-only flow                |
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
│   Delegates: AI work to engine                              │
└─────────────────┬───────────────────────────────────────────┘
                  │ HTTP (existing rfp-python-server pattern)
┌─────────────────▼───────────────────────────────────────────┐
│ rohan-python-api (FastAPI) — engine wrapper                 │
│   Fast inline endpoints: KM retrieval, single-section write,│
│     ingest-one-file, query-gold-library                     │
│   Async DAG endpoints: full RFP analysis, full proposal     │
│     generation, response-document analysis                  │
│   Owns: per-org workspace partitioning, run lifecycle,      │
│     Service Bus integration, MinIO routing                  │
└─────────────────┬───────────────────────────────────────────┘
                  │ Python imports
┌─────────────────▼───────────────────────────────────────────┐
│ ONERING (submodule) — engine                                │
│   Step factories: built-in DAG + module-specific DAGs       │
│     (compliance_review:build_steps,                         │
│      mra_assistant:build_steps,                             │
│      ae_v2:build_steps)                                     │
└─────────────────────────────────────────────────────────────┘
```

The key insight: ONERING already supports `--steps-factory mod:fn`. Each module ships its own custom DAG that reuses ONERING steps — that's the engine idiom.

---

## Phased Strategy

### Phase 1 — Compliance Launch on ONERING (target: ~few weeks)

Compliance is pre-production with no user data, real sales urgency, and the strongest structural overlap with ONERING. Launching is the natural moment to commit to ONERING-as-engine without paying any migration cost. Phase 1 absorbs the foundational wrapper work (originally proposed as a separate phase) because Compliance needs it anyway and can't wait.

**In-scope for launch:**

1. **Unified ingestion endpoint on rohan-python-api.** `POST /ingest/document` wraps ONERING's ingestion DAG (`ingestion.docling_parse_base` through `ingestion.chunk_plan`) and returns `{canonical_md, line_map, chunk_plan, doc_id}`, with artifacts stored in MinIO keyed by `org_id/doc_id`. Designed for Compliance's needs first but with documented multi-consumer awareness so AE v2 and Acquisition Center can adopt it later without redesign.

2. **Per-org tenancy.** Workspace partitioning, scoped MinIO buckets, scoped GOLD/KM library paths. Non-negotiable — the moment Compliance is in production, the tenancy model is fixed and cross-tenant leakage becomes a credibility-destroying P0.

3. **Custom Compliance step graph.** Module-specific factory `compliance_review:build_steps` running ingestion + `pipelines.requirements` only. Other extraction pipelines deferred to Phase 2 to keep launch scope tight.

4. **Compliance items as review-state mirrors.** `ui_projection_requirements.json` is the source of truth; the `compliance_items` table stores `status`, `reviewed_by`, `reviewedAt`, `userNotes` plus pointers (`run_id`, `requirement_id`). No override-resolution UX needed because there are no pre-existing user edits to reconcile.

5. **Existing UI works against the new source.** Tag UI work (PRCR-1517/1519/1544) is preserved unchanged. Items now flow from ONERING but the rendering layer doesn't care.

6. **Service Bus + completion handler** wired the same way the current rohan-python-api integration works, just kicking off ONERING runs instead of inline LLM calls.

**Out-of-scope for launch (deferred to Phase 2):**

- The other five extraction tabs (structure, evaluation, instructions, attachments, metadata) — net-new feature work, exciting to ship but not needed for launch.
- Compliance matrix XLSX export — deferrable.
- Response-analysis DAG — genuinely new ONERING code; concentrates production-scale unknowns. Sales can demo Compliance as "AI-extracted requirements with review"; automated response checking is "coming next."
- Generalizing the wrapper layer for AE v2 and Acquisition Center.

**Checkpoint discipline:** define an explicit milestone at week one. If tenancy + ingestion endpoint + custom step graph aren't tracking, fall back to launching Compliance on the current architecture and refactor onto ONERING in the following weeks while user count is still small. Pre-production status keeps that fallback cheap. The version to avoid is "we shipped half-done because we tried to do too much in too little time."

### Phase 2 — Compliance Expansion (weeks/months after launch)

Once Phase 1 is live and stable:

- **Additional extraction tabs.** Surface `ui_projection_*.json` for structure, evaluation, instructions, attachments, and metadata as new tabs. Each tab is an independently shippable deliverable.
- **Compliance matrix XLSX export.** Hook up ONERING's already-styled six-tab workbook.
- **Response-analysis DAG.** Custom step graph: ingest response → for each approved item, KM-retrieve evidence from response → produce `ComplianceCheck` payload with `automatedStatus` and evidence spans. Replaces the current rohan-python-api inline auto-tag flow. This phase concentrates the production-scale unknowns; it benefits from launch-period learnings on rate limits, concurrency, and tenancy edge cases.

### Phase 3 — Answer Engine v2 Migration (months out)

Once Phase 1's wrapper layer is proven and Phase 2 has shaken out the harder unknowns:

- Generalize the unified ingestion endpoint for AE v2's file-context uploads (replacing `RfpPythonServer.extract-file-content`).
- Replace `AgentWorkflowService.getKmWorkflow()` with calls to a unified `POST /km/retrieve` endpoint backed by ONERING's `run_km_retrieval()`.
- Aggregates and summaries → ONERING section writer (draft / critique / revise + consistency ledger).
- Add GOLD library as an opt-in past-proposal answer source. Requires resolving GOLD partitioning model first.
- Threads, execution locks, file management, and RBAC stay in NestJS — user-facing concerns, not engine concerns.
- Defer the deep-research consolidation; AE v2's o3 path and ONERING's are functionally similar.

### Phase 4 — Acquisition Center Sub-Feature Migration (further out)

| Sub-feature               | Migration                                                                                                                                     |
| ------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| Market Research Assistant | Custom DAG: discovery → deep research (o3) → vendor research → draft acquisition document. Replaces inline streaming with resumable manifest. |
| RFI Assistant             | Section writer (draft/critique/revise) replaces one-shot LLM.                                                                                 |
| Requirements Discovery    | Direct call to `pipelines.requirements`.                                                                                                      |
| Document Library          | Phase 1 ingestion endpoint replaces summary-only path.                                                                                        |
| Template Generator        | `pipelines.structure` reverse-engineers templates from past proposals.                                                                        |
| Toolkits                  | No engine work; storage feature stays as-is.                                                                                                  |
| Vector DB calls           | Phase 3 KM retrieval endpoint replaces them.                                                                                                  |

`wizard_state` JSONB shrinks to a thin pointer to ONERING run IDs + step status; the orchestrator's manifest does the heavy lifting.

---

## Timeline & Effort Estimate

Estimates below assume 2–3 engineers split across rohan-python-api, ONERING-side work, and rohan_api / rohan_ui integration, with at least one engineer having strong existing ONERING context. Numbers are realistic ranges, not best-case.

### Per-phase ranges

**Phase 1 — Compliance Launch on ONERING (thin scope): 4–6 calendar weeks.** Roughly 10–15 engineer-weeks of work split across tenancy (2–3), unified ingestion endpoint (1–2), custom Compliance step graph (1–2), DB schema + completion handler integration (1–2), Service Bus translation (1–2), UI adaptation against the new source (1), and testing/hardening (2–3). The "few weeks" target in the proposal is achievable at the optimistic end of this range with strong execution and pre-existing ONERING fluency on the team. Tighter timelines start trading away tenancy or testing — both bad trades.

**Phase 2 — Compliance Expansion: 2–3 calendar months.** The five additional extraction tabs are quick (~1 engineer-week each, mostly UI work over already-extracted JSON). XLSX export is a short hookup (1–2 engineer-weeks). The response-analysis DAG is the big chunk — 8–12 engineer-weeks for step-graph design, prompt engineering, per-item evidence retrieval, `ComplianceCheck` integration, and production hardening. Total ~14–19 engineer-weeks.

**Phase 3 — Answer Engine v2 Migration: 3–5 calendar months.** Wide range driven by two unknowns: (1) GOLD library partitioning design — could be 2 weeks if the team picks a simple per-org model, 1–2 months if it requires per-proposal access control; (2) behavior-parity validation against AE v2's already-shipped behavior, which can't be skipped. Engineer-weeks: ingestion endpoint generalization (1–2), KM retrieval endpoint + AE v2 swap (3–4), KM cost/latency measurement spike (1–2), behavior-parity validation (2–4), aggregate/summary integration via section writer (2–3), GOLD partitioning design + integration (4–7), streaming/state-model translation work (2–4), production hardening (3–4). Total ~18–30 engineer-weeks.

**Phase 4 — Acquisition Center Sub-Feature Migration: 3–4 calendar months.** Sub-features are independently sized: MRA is the largest (4–6 engineer-weeks), RFI moderate (2–3), Requirements Discovery and Document Library small (1–2 each), Template Generator novel (3–4), vector-DB replacement spans all sub-features (2–3), wizard-state migration (2–3), testing and hardening (3–4). Total ~18–26 engineer-weeks.

### Totals

- **Sequential execution:** 8–14 calendar months for the full four-phase plan with 2–3 engineers.
- **With overlap** (Phase 2 starts while Phase 1 stabilizes; Phase 3 begins while Phase 2 winds down): 6–10 calendar months.

### Comparison to initial estimate

A 3-month / 2–3 engineer estimate (~18–27 engineer-weeks) is realistic for **Phase 1 plus the bulk of Phase 2** — shipping Compliance fully on ONERING with all extraction tabs, XLSX export, and response analysis. It is not enough for the full four-phase plan that includes AE v2 and Acquisition Center.

Given the proposal's recommendation to defer Phases 3–4 by months anyway, the relevant question is whether 3 months gets you Phases 1–2. Honest answer: yes at the optimistic end, with realistic risk of slipping to 4 months. The harder constraint is hitting the few-weeks launch window for Phase 1 alone, not the multi-month Phase 1+2 timeline.

### What drives variance

- **Tenancy complexity.** If GOLD/KM partitioning ends up needing per-proposal access control rather than per-org, Phase 3 estimates expand by 2–4 weeks.
- **Streaming-through-engine decision.** Choosing option (a) — engine emits in-progress events — adds 2–4 weeks of ONERING-side work, deferrable to Phase 3 but not avoidable.
- **First-production shakedown.** ONERING has never run as a real-time service behind a UI. Plan for 2–3 weeks of post-launch stabilization that's hard to compress.
- **Engineer ramp on ONERING internals.** If only one engineer knows the manifest schema, step factory pattern, and artifact layout, parallelism is limited until others ramp. Two ONERING-fluent engineers is the sweet spot.
- **Cross-team coordination.** GOLD partitioning, scope cuts, launch-date negotiation, sales demo scoping — these consume calendar time without consuming engineer time.

### Single numbers to plan against

If forced to commit to point estimates:
- **Phase 1: 6 weeks** with an explicit fallback to current architecture if tracking poorly at the week-2 checkpoint.
- **Phase 1 + Phase 2: 4 months** for 2–3 engineers (one ramp month, three execution months).
- **Full four-phase plan: 10 months** for 2–3 engineers, with overlap.

Your initial 3-month / 2–3 engineer estimate is reasonable if "the work" means Compliance-only on ONERING (Phases 1–2). For the full proposal scope as written, plan for closer to 10 months.

---

## Concerns to Resolve Before Committing

1. **Latency vs. interactivity.** ONERING pipelines take minutes; modules expect interactive responses. The split between fast inline endpoints (KM retrieval, single section, single ingest) and async DAG endpoints (full extraction, full write) needs a deliberate design pass, including the streaming contract.

2. **Per-org tenancy.** ONERING was designed single-operator. Production needs `org_id` partitioning on workspaces, MinIO buckets, GOLD libraries, and KM corpora. The wrapper layer is the natural place — it can scope `ARC_WORKSPACE_ROOT` per request — but GOLD and KM partitioning need explicit design (global library? per-org? hybrid?). This work has to land _with_ Phase 1, not after.

3. **State models don't match.** Compliance uses Service Bus + completion handlers. ONERING uses manifest-based state. The wrapper layer translates: rohan-python-api owns run lifecycle and emits Service Bus messages on key transitions; NestJS continues to consume them. AE v2's advisory locks add a third model in Phase 3.

4. **Streaming through the engine.** Modules expect SSE; ONERING's `llm_calls/.../` artifacts are written _after_ calls complete. Either (a) the engine emits in-progress events that rohan-python-api forwards, or (b) NestJS streams directly from OpenAI and the engine sees only finalized artifacts. (a) preserves the engine's audit trail at the cost of ONERING changes; (b) is simpler. Compliance's launch flow is async (Service Bus) so streaming pressure is lower in Phase 1; Phase 3 (AE v2) is where this decision really bites.

5. **Custom step graph governance.** If every module ships a `build_steps` factory, expect step-name collisions and prompt drift. Suggest a registry pattern in ONERING — modules register namespaced prefixes (`compliance.*`, `mra.*`, `ae.*`) and the orchestrator validates uniqueness.

6. **Response analysis is genuinely new.** ONERING doesn't currently have "compare a response document against extracted requirements." That work lands in Phase 2, not Phase 1, but it should be designed into the custom step graph from the start so the Phase 1 architecture leaves room for it.

7. **KM cost and latency for AE v2 (Phase 3 concern).** ONERING KM is brute-force chunk-by-chunk LLM scanning. AE v2 today might make 1 LLM call per question; on ONERING KM it could be 50+. Worth a measurement spike before committing in Phase 3 — not a Phase 1 blocker.

8. **GOLD library partitioning (Phase 3 concern).** Today GOLD is one folder. For AE v2 to use it as an answer source you need per-org curation, possibly per-project filtering, possibly per-proposal access control (past performance can be sensitive). Product work, not plumbing. Phase 3 prerequisite.

---

## Tradeoffs: Should This Happen Now?

The plan above is what _could_ be done. Whether it should be done _at this point in time_ is a separate question. Below is a frank tradeoff analysis given the current context (Compliance pre-production, ~few-weeks launch target, no specific feature commitments, ONERING is a high-priority initiative with resource availability, AE v2 / Acquisition Center can wait several months).

### Pros

**1. Pre-production Compliance status is the cheapest possible moment to commit to ONERING.** No user data, no edits to migrate, no launch promises to break, no behavioral parity bar to clear. Launching on the current architecture and refactoring later is double-work; choosing ONERING up front avoids it.

**2. Sales urgency is the forcing function.** Earlier framing flagged "no forcing function" as a risk for big refactors. The Compliance launch is the forcing function — it gives the work a deadline and a why.

**3. ONERING knowledge is at peak right now.** The submodule was built recently and the team that wrote it is still close to it. Refactoring against living knowledge is dramatically cheaper than refactoring against archaeology.

**4. Phase 1 ships features.** The launch _is_ the feature delivery. ONERING-driven from day one means sales can sell on engine-backed capabilities (canonical line-numbered evidence, audit trail per LLM call, future-ready for response analysis and matrix export) rather than retrofitting that story later.

**5. Tenancy work has to happen anyway.** For ONERING to run in production behind FastAPI you need per-org workspace partitioning, scoped MinIO buckets, scoped GOLD/KM libraries. Doing it once for Compliance amortizes the cost across all three modules.

**6. Audit trail and debuggability are real wins.** ONERING's manifest plus per-call artifact persistence (`llm_calls/{step}/{prompt}/{call_id}/`) is dramatically more debuggable than what the existing modules have. This matters more as Compliance ships to actual users.

**7. The compounding duplication tax stops growing.** Every new feature added to AE v2, Acquisition Center, or Compliance today picks one of three different retrieval approaches and three ingestion paths. Establishing the engine pattern with Compliance creates the pull for AE v2 and Acquisition Center to follow.

**8. Strategic narrative.** "ONERING as engine" reframes the product from "three modules that happen to use AI" to "an AI engine for proposal/acquisition/compliance workflows with surfaces tailored to each." Compliance launching on ONERING is the demonstration that makes the story credible.

**9. Pre-launch tag UI investment is easy to absorb.** Earlier framing flagged the PRCR-1517/1519/1544 work as a "different roadmap" signal. Inverted: pre-launch polishing means the team is still flexible, and the tag UI work is preserved unchanged because items become source-agnostic.

### Cons

**1. Few-weeks timeline is tight.** Even with thin scope (ingestion + tenancy + requirements extraction + items review), shipping a production-ready ONERING-driven Compliance in a few weeks is ambitious. The risk isn't the technical work itself — it's timeline slip, where you hit the launch date with something half-done.

**2. First production use of ONERING coincides with first customer demo.** ONERING has never run as a real-time service behind a UI. The launch _is_ the production-scale shakedown. Pre-production status means user impact is zero if something goes wrong, but it also means the polish you'd normally get from a quiet pilot phase isn't on the table.

**3. Streaming/state-model decisions still need deliberate design.** Reduced pressure in Phase 1 (Compliance flow is async via Service Bus) but the decisions still need to be made cleanly because Phase 3 (AE v2) inherits them. Easy to make pragmatic Phase 1 choices that hurt Phase 3.

**4. Engine-side engineering may be underfunded.** "ONERING is a high priority" should include the engine itself, not just integration work. Tenancy, custom step factory hardening, possibly streaming hooks, eventually response-analysis pipeline — these need ONERING-side engineering capacity, not just integration capacity.

**5. State-model translation creates a class of bugs.** Service Bus completion handlers + manifest checkpointing — two mental models for "is the work done." The wrapper layer that translates between them is exactly where subtle bugs live: lost updates, double-processed runs, items stuck in `pending` because a manifest update raced a Service Bus message. Hardening takes time.

**6. ONERING is still evolving.** Building Compliance on a young codebase means every ONERING refactor cascades. Either pin the submodule (and fall behind) or stay current (and absorb breaking changes). The mature pattern is a frozen, versioned engine API — itself another piece of work, deferrable until Phase 3 is in flight.

**7. Modules lose iteration independence over time.** Once multiple modules share an engine, prompt and pipeline changes need cross-module regression. Not a Phase 1 issue but a real ongoing tax once Phase 3+ land.

**8. AE v2 KM swap will not be free when its turn comes (Phase 3).** Behavioral parity is harder than feature parity, and AE v2 just shipped — disrupting it again in a few months creates user fatigue. Worth flagging now so Phase 3 timing is realistic.

### Honest Summary

The plan is technically sound and the timing is unusually favorable. Pre-production Compliance + sales urgency + AE v2/Acquisition Center deferral + ONERING priority resource availability is roughly the best window this team will get for an engine consolidation.

**Recommended path:** thin Compliance launch on ONERING in the few-weeks window (Phase 1), with Phase 2 expanding scope post-launch and Phases 3–4 following months later as separate efforts.

**Non-negotiables for Phase 1:**

- Per-org tenancy. Cross-tenant data leakage is the worst-case failure mode and it ships _with_ the launch.
- Designed wrapper API. Even though only Compliance uses it on day one, design with awareness that AE v2 / Acquisition Center will adopt later — avoid Compliance-specific shapes that won't generalize.
- Explicit week-one checkpoint with a fallback to "launch on current architecture, refactor right after" if the timeline isn't tracking. Pre-production status keeps the fallback cheap; not having a fallback is what turns aggressive plans into death marches.

**Aggressively defer for Phase 1:**

- Response-analysis DAG (genuinely new ONERING code; Phase 2).
- Other five extraction tabs (Phase 2).
- XLSX export (Phase 2).
- Anything for AE v2 or Acquisition Center.

**Open questions worth confirming before starting:**

- Is the few-weeks launch date hard or soft? "Sales wants to sell" is real urgency but may not be a fixed deadline — getting another month or two would meaningfully derisk Phase 1.
- What does sales actually need to demo? If "AI extracts requirements, your team reviews, response analysis is coming next quarter" is enough, the thin scope works. If sales is committed to demonstrating automated response checking, scope changes.
- Does "ONERING is a high priority" include ONERING-side engineering capacity (tenancy, step factory hardening)? Integration without engine work isn't enough.

**The single thing to push hardest on:** don't compress tenancy under timeline pressure. If a tradeoff has to be made, drop scope (defer the extraction tabs, defer XLSX export, even defer requirements polish), not tenancy. Everything else is recoverable; tenant leakage is not.
