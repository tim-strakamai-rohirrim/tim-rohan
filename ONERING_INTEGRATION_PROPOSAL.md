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

## Where I'd Start

Smallest commitment to validate the strategy: **Phase 1 (unified ingestion) first** — touches all three modules, zero migration risk, clean test of the wrapper pattern. If that lands, **Compliance pivot (Phase 3) next** — highest overlap, gives you a concrete "ONERING as engine" demonstration to evaluate further migrations against.
