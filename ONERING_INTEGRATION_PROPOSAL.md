# ONERING as Engine: Integration Proposal for Acquisition Center, Answer Engine v2, and Compliance

## Executive Summary

All three modules independently reinvent capabilities ONERING already has — document ingestion, KM-style retrieval, requirement extraction, structured generation. Compliance has the strongest structural overlap; Answer Engine v2 has the cleanest direct swap; Acquisition Center is the most diverse and benefits from gradual sub-feature migration.

The pattern that makes sense: ONERING runs as the AI compute layer behind rohan-python-api, exposing capabilities both as fast inline endpoints and as async DAG runs. NestJS modules become thinner shells that own user-facing state (projects, threads, items) and delegate AI work to the engine.

---

## Module Snapshots

### Acquisition Center (Procurement Writer)
Multi-step procurement drafting — Market Research Assistant (MRA), RFI Assistant, Requirements Discovery, Document Library, Template Generator, Toolkits. Backend at `rohan_api/src/procurement-writer/` is a 1,700-line service with streaming SSE controllers and a `wizard_state` JSONB blob for multi-step state. AI pattern is consistent across assistants: fetch prompt by feature flag → enrich with `addDocContent()` (manual document-summary append) and `addVectorDBResults()` (pgvector query for 10 paragraphs + 10 tables) → `handleCompletion()` for SSE streaming.

### Answer Engine v2
Threaded conversational Q&A with KM retrieval, deep research (o3), file-context uploads, streaming responses, aggregates, and summaries. Backend at `rohan_api/src/answer-engine-v2/` is a 2,300-line service with advisory locks, `Question`/`Answer`/`Thread`/`Aggregate`/`Summary` entities, and heavy use of `AgentWorkflowService.getKmWorkflow()` (LangChain-based LLM-as-retriever) plus `RfpPythonServer.extract-file-content` for file parsing. Determines a follow-up route (REUSE_EXISTING_KM_CONTEXT vs RERUN_KM vs RESEARCH_WITH_KM_CONTEXT vs RESEARCH_ONLY) before streaming.

### Compliance
Source-document compliance item extraction → manual review → response-document upload → automated cross-check → reviewer adjudication. Inline tag UI on the document viewer (recent PRCR-1517/1519/1544 work). Backend at `rohan_api/src/compliance/` has entities `ComplianceProject`, `ComplianceItem`, `ComplianceCheck`, `ComplianceItemEvidence`, `ComplianceDocument`, `ComplianceResponse`. Auto-extraction is async: Service Bus → rohan-python-api (GPT-5.2 extracts shall-statements with line offsets) → completion handler updates DB.

---

## ONERING Capability Map

| ONERING capability | Compliance | AE v2 | Acquisition Center |
|---|---|---|---|
| Document ingestion (Docling + OCR + canonical markdown + line numbering + chunking) | ✅ Replace inline rohan-python-api path | ✅ Replace `extract-file-content` | ✅ Replace doc-summary-only flow |
| `pipelines.requirements` (shall/must extraction with line evidence) | ✅ Direct replacement for compliance item extraction | — | ✅ Replaces Requirements Discovery |
| `pipelines.structure` / `evaluation` / `instructions` / `attachments` / `metadata` | ✅ Net-new tabs/views | — | ✅ Could power Template Generator |
| `pipelines.compliance_matrix` (six-tab XLSX + JSON) | ✅ Direct replacement; gives free export | — | — |
| KM retrieval (LLM-as-retriever with query plans) | Improves response analysis | ✅ Direct replacement for `getKmWorkflow` | ✅ Replace `addVectorDBResults` |
| Section writer (draft → critique → revise + consistency ledger) | Optional: auto-generate compliance commentary | ✅ Aggregates / summaries quality boost | ✅ Replace one-shot LLM calls |
| GOLD library | — | Opt-in past-proposal answer source | ✅ Vendor / template suggestions from past wins |
| Render layer (DOCX/PPTX/XLSX with anchor amendments) | ✅ Compliance matrix export | ✅ Aggregate / answer export | ✅ Replace DocxExportService |
| DAG orchestrator (resumable, parallel) | Wrap per-project runs | Resumable deep-research | ✅ Replaces `wizard_state` JSONB |
| Deep research (o3 + web search, structured) | — | ✅ Replace direct o3 calls | ✅ Replace MRA deep research |
| SAM.gov discovery | — | — | ✅ Connect to existing `opp_id` field |

---

## Architecture Target

```
┌─────────────────────────────────────────────────────────────┐
│ rohan_ui (Angular)                                          │
│   compliance/   answer-engine-v2/   acquisition-center/    │
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

### Phase 1 — Unified Ingestion Service (foundation)
Wrap ONERING's ingestion DAG (`ingestion.docling_parse_base` through `ingestion.chunk_plan`) as a fast endpoint on rohan-python-api: `POST /ingest/document` → `{canonical_md, line_map, chunk_plan, doc_id}` stored in a shared MinIO bucket keyed by `org_id/doc_id`. All three modules switch to this for new uploads; existing summary fields stay populated for backwards compatibility. Cheapest, highest-leverage starting point — no data migration, no module refactor, just a new optional path.

### Phase 2 — Unified KM Retrieval
Extract `run_km_retrieval()` and `generate_km_query_plan()` into a Python package and expose `POST /km/retrieve`. AE v2 swaps `getKmWorkflow()`; Acquisition Center swaps the `addVectorDBResults()` enrichment; Compliance gains a tool for response-document analysis ("does this response contain evidence for compliance item X?"). Unifies three different retrieval implementations into one.

### Phase 3 — Compliance Pivots to ONERING-Driven (the flagship)
The most visible "ONERING as engine" demonstration:

1. Source-document upload triggers a full ONERING run (custom step graph: ingestion → all six extraction pipelines → `pipelines.compliance_matrix`). Async, status tracked via existing Service Bus pattern.
2. `ui_projection_requirements.json` becomes the source of truth for compliance items. The `compliance_items` table becomes a review-state mirror (`status`, `reviewed_by`, `reviewedAt`, `userNotes`) pointing at ONERING artifacts.
3. Net-new tabs come for free: structure, evaluation, instructions, attachments, metadata. Today the module only exposes requirements.
4. Compliance matrix XLSX export hooks up to ONERING's already-styled six-tab workbook.
5. Response-document analysis becomes a separate ONERING DAG: ingest response → for each approved item, KM-retrieve evidence → produce `ComplianceCheck` payload with `automatedStatus` and evidence spans. Replaces the current rohan-python-api inline auto-tag flow.
6. Tag UI work (PRCR-1517/1519/1544) is preserved unchanged — tags are positional UI overlays, items now sourced from ONERING but the rendering doesn't care.

Migration: existing projects keep their data; new uploads use ONERING; offer a "Re-analyze with ONERING" action for backfill.

### Phase 4 — Answer Engine v2 Engine-Backed Q&A
Once Phases 1–2 land, AE v2's backend thins considerably. `getKmWorkflow()` → Phase 2 endpoint. `extract-file-content` → Phase 1 endpoint. Aggregates and summaries → ONERING section writer (draft/critique/revise + consistency ledger gives a measurable quality jump for cross-question summaries). GOLD library as an optional answer source for proposal-team Q&A like "what did we say about cyber past performance in the last DoD bid?" Threads, execution locks, file management, RBAC stay in NestJS — they're user-facing concerns, not engine concerns. Defer the deep-research consolidation; AE v2's o3 path and ONERING's are functionally similar.

### Phase 5 — Acquisition Center Sub-Feature Migration

| Sub-feature | Migration |
|---|---|
| Market Research Assistant | Custom DAG: discovery → deep research (o3) → vendor research → draft acquisition document. Replaces inline streaming with resumable manifest. |
| RFI Assistant | Section writer (draft/critique/revise) replaces one-shot LLM. |
| Requirements Discovery | Direct call to `pipelines.requirements`. |
| Document Library | Phase 1 ingestion replaces summary-only path. |
| Template Generator | `pipelines.structure` reverse-engineers templates from past proposals. |
| Toolkits | No engine work; storage feature stays as-is. |
| Vector DB calls | Phase 2 KM retrieval replaces them. |

`wizard_state` JSONB shrinks to a thin pointer to ONERING run IDs + step status; the orchestrator's manifest does the heavy lifting.

---

## Concerns to Resolve Before Committing

1. **Latency vs. interactivity.** ONERING pipelines take minutes; modules expect interactive responses. The split between fast inline endpoints (KM retrieval, single section, single ingest) and async DAG endpoints (full extraction, full write) needs a deliberate design pass, including the streaming contract.

2. **Per-org tenancy.** ONERING was designed single-operator. Production needs `org_id` partitioning on workspaces, MinIO buckets, GOLD libraries, and KM corpora. The wrapper layer is the natural place — it can scope `ARC_WORKSPACE_ROOT` per request — but GOLD and KM partitioning need explicit design (global library? per-org? hybrid?).

3. **Source-of-truth conflicts.** When `compliance_items.complianceItemTitle` exists in PostgreSQL *and* `ui_projection_requirements.json`, which wins? Recommended: ONERING artifacts immutable per-extraction; PostgreSQL stores review-only state plus a pointer (`run_id`, `requirement_id`); user edits create override rows rather than mutating artifacts. Matches ONERING's append-only philosophy.

4. **State models don't match.** Compliance uses Service Bus + completion handlers. AE v2 uses execution locks + observables. ONERING uses manifest-based state. The wrapper layer translates: rohan-python-api owns run lifecycle and emits Service Bus messages on key transitions; NestJS continues to consume them.

5. **Streaming through the engine.** Modules expect SSE; ONERING's `llm_calls/.../` artifacts are written *after* calls complete. Either (a) the engine emits in-progress events that rohan-python-api forwards, or (b) NestJS streams directly from OpenAI and the engine sees only finalized artifacts. (a) preserves the engine's audit trail at the cost of ONERING changes; (b) is simpler.

6. **Existing data.** Three options: (i) leave old data alone, only new uploads go through ONERING; (ii) one-time backfill that re-extracts existing source documents; (iii) lazy migration on first read. Default to (i) with opt-in (ii) per project.

7. **Custom step graph governance.** If every module ships a `build_steps` factory, expect step-name collisions and prompt drift. Suggest a registry pattern in ONERING — modules register namespaced prefixes (`compliance.*`, `mra.*`, `ae.*`) and the orchestrator validates uniqueness.

8. **Response analysis is genuinely new.** ONERING doesn't currently have "compare a response document against extracted requirements" — that's a Compliance-specific addition. The one place where ONERING gets *new* code rather than just being a destination for module logic.

---

## Tradeoffs: Should This Happen Now?

The plan above is what *could* be done. Whether it should be done *at this point in time* is a separate question. Below is a frank tradeoff analysis — not "pros of consolidation in general" but specifically "should this team make this change now."

### Pros

**1. The duplication tax is compounding.** Every new feature added to AE v2, Acquisition Center, or Compliance today picks one of three different retrieval approaches, three ingestion paths, three prompt-management strategies. Each new MRA sub-assistant is another bespoke LLM streaming endpoint to maintain. The longer you wait, the more code locks in to the current divergence — and divergent systems get harder to unify, not easier.

**2. ONERING knowledge is at peak right now.** The submodule was built recently and the team that wrote it is still close to it. The step-factory pattern, manifest schema, artifact directory layout, prompt versioning conventions all live in the heads of the people who made the decisions. Refactoring against living knowledge is dramatically cheaper than refactoring against archaeology.

**3. Phase 3 isn't *just* a refactor — it ships features.** Compliance today only shows requirements. ONERING already produces structure, evaluation, instructions, attachments, and metadata extractions for free. The Compliance pivot delivers five new tabs of capability as a side effect of the architecture work. Easier to justify to product leadership and easier for users to feel a positive change rather than just plumbing churn.

**4. Tenancy work has to happen anyway.** ONERING is single-operator today. For it to run in production behind FastAPI you need per-org workspace partitioning, scoped MinIO buckets, scoped GOLD/KM libraries. That work isn't optional if ONERING ever runs as a real service — and doing it once amortizes the cost across all three modules.

**5. Audit trail and debuggability are real wins.** ONERING's manifest plus per-call artifact persistence (`llm_calls/{step}/{prompt}/{call_id}/`) is dramatically more debuggable than what the existing modules have. When a user complains about a bad answer or a missed compliance item today, there's no easy way to reconstruct what the LLM saw. ONERING gives you that for free.

**6. Section writer quality lift is concrete, not speculative.** Acquisition Center's RFI Assistant and AE v2's aggregates use one-shot LLM calls. Switching them to draft → critique → revise with a consistency ledger is a known quality improvement. Users will feel the difference, especially on longer outputs.

**7. Strategic narrative.** "ONERING as engine" reframes the product. Instead of "three modules that happen to use AI," it becomes "an AI engine for proposal/acquisition/compliance workflows with surfaces tailored to each." That framing affects roadmap, hiring, and how the company pitches.

### Cons

**1. The scope is large and competes with feature work.** Even Phase 1 touches three modules across frontend, backend, Python service, and submodule. Every phase has a real ramp. If engineering capacity is constrained — and it always is — this displaces feature work. The plan looks tidy in a doc; in practice each phase is two-to-three quarters of work for a small team.

**2. There's active in-flight work in these modules.** Compliance has open PRCR tickets (1517, 1519, 1544) polishing the existing tag UI. AE v2 just shipped (the "v2" implies "v1" is recent). Acquisition Center has multiple wizards being iterated on. Refactoring against a moving target is much more expensive than refactoring frozen code.

**3. ONERING isn't production-tested at this scale.** It's a CLI-driven batch system. Running it as a real-time engine behind a UI exposes failure modes that don't exist in batch: timeout handling, partial results, concurrent runs from the same org, API rate-limit fairness across tenants, queue backpressure. The first time a long ONERING run blocks a user-visible operation will be educational and unpleasant.

**4. The streaming/engine impedance mismatch is structural, not cosmetic.** All three modules are built around SSE. ONERING is built around batch + manifest. Reconciling these requires either teaching ONERING to stream (engine changes that may not land cleanly) or keeping streaming responsibility in NestJS (engine loses audit trail for streamed calls). Neither option is free.

**5. State-model translation creates a class of bugs.** Service Bus completion handlers, advisory locks, manifest checkpointing — three mental models for "is the work done." The wrapper layer that translates between them is exactly where subtle bugs live: lost updates, double-processed runs, items stuck in `pending` because a manifest update raced a Service Bus message.

**6. Compliance source-of-truth migration is genuinely risky.** Today `ComplianceItem.complianceItemTitle` is user-editable. If it moves to mirror `ui_projection_requirements.json`, every existing user edit becomes an "override." If a project is re-analyzed, override resolution becomes a UX problem (new requirement says X, user edit said Y, who wins?). Get this wrong and you either lose user edits or surface confusing inconsistencies.

**7. AE v2 KM is not a free swap.** ONERING KM is structurally similar to `getKmWorkflow`, but wire protocols, latency characteristics, error handling, and streaming contracts differ. Behavioral parity is harder than feature parity, and AE v2 just shipped — disrupting it again creates user fatigue.

**8. KM costs and latency could spike.** ONERING KM is brute-force chunk-by-chunk LLM scanning. AE v2 today might make 1 LLM call to answer a question; on ONERING KM it might make 50+ (one per chunk plus generation). The product's per-question cost could 10× or worse. Worth a measurement spike before committing.

**9. GOLD library partitioning is an unsolved product question.** Today GOLD is one folder. For AE v2 to use it as an answer source you need per-org GOLD curation, possibly per-project filtering, possibly per-proposal access control (past performance can be sensitive). Product work, not plumbing.

**10. Modules lose iteration independence.** Each module currently has its own prompts, retrieval logic, LLM controller. They can ship a new AE v2 prompt without touching Compliance. Once they share an engine, prompt changes need cross-module regression. The blast radius of every engine change increases.

**11. ONERING is still evolving.** Three modules built on top of a young codebase means every ONERING refactor cascades. You either pin the submodule (and fall behind) or stay current (and absorb breaking changes). The mature pattern is a frozen, versioned engine API — which is itself a piece of work.

**12. There's no forcing function.** No scaling crisis, no committed architecture promise, no customer demand for ONERING-specific features. Big refactors without a forcing function tend to slip and accumulate resentment. They get half-done and leave the codebase worse than before — partly migrated, doubly complex.

**13. Compliance tag UI investment signals a different roadmap.** Recent PRCR-1517/1519/1544 work refines the existing implementation. Someone is making product investments in the current Compliance architecture. Worth understanding what the Compliance product owner thinks about timing before committing.

### Honest Summary

The plan is technically sound. The timing question is the harder one.

**Strong case for doing now:** Phase 1 (unified ingestion) is low-risk and pays back regardless of whether you ever do Phases 3–5. Tenancy hardening has to happen anyway. Knowledge of ONERING is at peak. The duplication is compounding.

**Strong case for waiting:** AE v2 just shipped. Compliance has in-flight work. ONERING is unproven at production scale. The streaming and state-model mismatches are real and expensive. Without a forcing function, big refactors slip and become half-done.

**A reasonable middle path:** commit to Phase 1 and the tenancy work now, treat them as foundational regardless of the rest of the plan. Run Phase 3 (Compliance pivot) as a deliberate strategic decision with leadership buy-in and a tight scope. Defer Phases 4–5 until Compliance proves the model. That gets you the highest-leverage wins without locking in the disruption.

**Biggest concrete risks to flag to leadership:**
- Compliance source-of-truth migration loses user edits if rushed.
- KM cost/latency could regress meaningfully — measure before committing.
- Streaming-through-engine needs an architectural decision *before* you start, not after.
- Cross-tenant data leakage is the worst-case failure mode of partial tenancy work.

**The single thing I'd push hardest on:** don't start Phase 3 until Phase 1 has been live in production long enough to surface the wrapper-layer problems. Two months minimum. The design assumptions baked into the wrapper become much harder to revisit once three modules depend on them.
