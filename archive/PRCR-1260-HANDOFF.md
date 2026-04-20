# PRCR-1260 Handoff Summary — Compliance Document Viewer

> **Date:** 2026-03-24
> **Previous conversations:**
> - Agent 1: [Compliance viewer plan](f2b7dde9-4b37-448e-9869-b36f1185d539) — initial plan creation
> - Agent 2: Review, critique, and revised approach
> - Agent 3: Async conversion architecture and open question resolution
> - Agent 4: Codebase-verified review, critique, and final refinements
> - Agent 5: PR review feedback — revised architecture to use queue-based flow (this update)
> **Plan file:** `PRCR-1260-PLAN.md` (root) — **updated by Agent 5**
> **Contracts file:** `PRCR-1260-contracts.md` (root) — **updated by Agent 5**

---

## What is being built

The **Document Viewer Panel** in the Compliance List Creation workflow needs to display **real uploaded documents** (PDF, DOCX, XLSX) instead of the current hardcoded mock data. Users must be able to:

1. View documents that look exactly like the originals.
2. Select text in the document and create compliance items (manual tagging).
3. Switch between multiple uploaded documents via a dropdown.

---

## Key architectural decision: Docling HTML via `innerHTML`

After exploring several approaches (embedded PDF viewer, line-based text extraction), the final decision was to **render Docling-converted HTML via `innerHTML`**, the same pattern used by:

- **`DocShellComponent`** (`rohan_ui/src/app/shared-components/document-shredding/components/document-tagging/doc-shell/`) — used by Template Generator's Tag Step.
- **`HtmlRendererComponent`** (`rohan_ui/src/app/pages/proposal-writer/`) — used by Create Proposal Wizard.

This was chosen because:
- Docling converts PDF, DOCX, and XLSX uniformly to HTML, so one rendering path handles all file types.
- The HTML preserves the original document's visual layout (fonts, tables, lists, formatting).
- `DocShellComponent` already proves this pattern works for text selection and tagging.

**We borrow patterns from `DocShellComponent` but do NOT reuse it directly** because its context menu is hard-wired to Template Generator's `TaggingService` (tag-type selection with categories). Compliance has a different UX: select text → "Add Compliance Item" button → create item (no tag-type menu).

---

## What currently exists

| Layer | Current state | Gap |
|-------|--------------|-----|
| **Frontend — `document-viewer-panel`** | Line-based rendering with `@for (line of document.lines)`, text selection maps to line numbers, "Add Compliance Item" popover. Located at `rohan_ui/src/app/pages/compliance/components/document-viewer-panel/`. | Uses mock data (`MOCK_COMPLIANCE_DOCUMENTS`). Line-based rendering doesn't preserve original layout. |
| **Frontend — `compliance-document.utils.ts`** | `mapProjectDocumentsToViewerDocuments()` maps project documents onto `MOCK_COMPLIANCE_DOCUMENTS`. | Mock data dependency, has a TODO to replace it. |
| **Frontend — `ComplianceStateService`** | Manages compliance state with Angular signals. Has `_selectedDocumentId`. | No HTML loading/caching. |
| **Backend (NestJS) — `ComplianceDocument` entity** | Has `minioObjectKey`, `mimeType`, `taggable_doc_id`. | No `convertedHtmlKey` column — no way to store/retrieve converted HTML. |
| **Backend (NestJS) — compliance listener** | `handleAutoTagComplete` creates compliance items from auto-tag results. Event carries `convertedHtmlUrl` but **the compliance listener discards it** (template-documents listener persists it, compliance doesn't). | Converted HTML URL from the auto-tag pipeline is lost for compliance documents. |
| **Backend (Python) — auto-tag handler** | Docling converts documents → HTML, uploads to MinIO, returns `converted_html_url` in `DocumentResult`. | Conversion is coupled to the tagging pipeline — no standalone conversion endpoint. |

---

## The plan (5 phases, 5 Jira tickets, 5 PRs)

The full plan is in `PRCR-1260-PLAN.md`. Summary:

| Phase | Owner | Repo | Summary |
|-------|-------|------|---------|
| **Phase 0** | `[BACKEND_DB]` | `rohan-python-api` | New `POST /compliance/convert-document` endpoint for on-demand Docling conversion |
| **Phase 1** | `[BACKEND_DB]` | `rohan_api` | Add `converted_html_key` column + migration, persist it in listener, add `GET .../documents/:id/html` endpoint |
| **Phase 2** | `[FRONTEND]` | `rohan_ui` | Wire `ComplianceApiService` + `ComplianceStateService` to fetch/cache document HTML |
| **Phase 3** | `[FRONTEND]` | `rohan_ui` | Rebuild viewer panel: `innerHTML` rendering, block-based selection, highlighting |
| **Phase 4** | `[FRONTEND]` | `rohan_ui` | Cleanup: remove `PdfHighlightOverlayComponent`, mock data, page number display |
| **Phase 5** | `[TEST_REVIEW]` | Both | Unit tests for all changes |

**Parallelism:** Phases 0, 1, and 2 can all start in parallel (separate repos, and frontend can mock the API). Phase 3 depends on Phase 2. Phase 4 depends on Phase 3. Phase 5 overlaps with each.

---

## API contracts

Full contracts are in `PRCR-1260-contracts.md`. Key endpoints:

1. **`GET /compliance/projects/:projectId/documents/:documentId/html`** (NestJS)
   - Returns `{ documentId, documentName, mimeType, conversionStatus, html? }`.
   - Only serves cached results — no on-demand conversion.
   - 200 (complete + HTML), 202 (pending, no HTML), 404 (not found), 502 (conversion failed).

2. **`POST /compliance/convert-document`** (Python FastAPI)
   - Input: `{ storage_type, object_key, output_key }`.
   - Downloads from MinIO, converts via Docling, uploads HTML back.
   - Returns `{ success, html_key, mime_type }`.

---

## Open questions

Full list in `PRCR-1260-PLAN.md` § Open Questions. Most original questions have been resolved across Agents 2–4. Remaining items:

1. **XLSX multi-sheet handling.** How does Docling render multiple sheets? Test with a sample file.
2. **`convertedHtmlUrl` vs `convertedHtmlKey` semantics.** Verify whether the auto-tag handler's `converted_html_url` is a full URL or a MinIO key — extraction logic may be needed. _(Revisit during Phase 1.)_
3. **HTML stripping consistency.** Python strips `head` but not `base`; DocShell strips `base` but not `head`. Both passes run, so safe in practice. _(Revisit if rendering issues arise.)_
4. **Legacy Office format support.** Verify `.doc`, `.xls`, `.ppt` work in Docling's container environment. _(Revisit during Phase 0.)_
5. **Pending conversion UX.** MVP shows static "processing" message. _(Check with design team on polling, auto-refresh, or manual refresh.)_
6. **Large HTML payloads.** Base64 images compress well with gzip but may still be large. _(Revisit if real documents cause performance issues.)_

---

## Key code locations

### Frontend (`rohan_ui-parent/rohan_ui/src/app/`)

| File | Relevance |
|------|-----------|
| `pages/compliance/components/document-viewer-panel/document-viewer-panel.component.{ts,html,scss}` | **Primary component to modify** — currently line-based rendering |
| `pages/compliance/components/compliance-list-creator/compliance-list-creator.component.{ts,html}` | Parent component — passes data to viewer panel |
| `pages/compliance/utils/compliance-document.utils.ts` | Maps project docs to viewer docs — currently uses mock data |
| `pages/compliance/types/compliance-item.types.ts` | Frontend types: `ComplianceSourceDocument`, `CreateComplianceItemSelection` |
| `pages/compliance/services/compliance-api.service.ts` | API service — needs `getDocumentHtml()` method |
| `pages/compliance/services/compliance-state.service.ts` | State management — needs HTML loading/caching |
| `shared-components/document-shredding/components/document-tagging/doc-shell/doc-shell.component.ts` | **Reference implementation** — HTML rendering, block selection, highlighting |
| `pages/proposal-writer/components/.../html-renderer/html-renderer.component.ts` | Another reference — uses `data-linenum` for selection mapping |

### Backend NestJS (`rohan_api-parent/rohan_api/src/compliance/`)

| File | Relevance |
|------|-----------|
| `entities/compliance-document.entity.ts` | Needs `convertedHtmlKey` column |
| `listeners/compliance.listener.ts` | Needs to persist `convertedHtmlUrl` from auto-tag events |
| `compliance.service.ts` | Needs `getDocumentHtml()` method |
| `compliance.controller.ts` | Needs `GET .../documents/:id/html` endpoint |

### Backend Python (`rohan-python-api/backend/app/`)

| File | Relevance |
|------|-----------|
| `api/routes/compliance.py` | **New file** — standalone conversion endpoint |
| `domains/shared/docling/docling_factory.py` | Existing Docling utilities to reuse |

---

## User preferences and constraints

- **Separate PRs** — one per Jira ticket (5 total across 2 repos).
- **Document must match original look exactly** — this drove the decision to use Docling HTML.
- **Auto-tagging is optional** — users can always manually tag even if auto-tagging hasn't run. The on-demand conversion endpoint exists to support this.
- **Page numbers can be omitted for now.**
- **PDF, DOCX, XLSX support** — all at once since Docling handles them uniformly.

---

## What the next agent should do (Agent 1's original guidance)

1. ~~**Address the open questions** — especially #1 (block index vs. offset semantics) and #2 (data-linenum).~~ **Resolved by Agent 2** — see below.
2. **Begin implementation** starting with Phase 0 (Python endpoint) and/or Phase 1 (NestJS endpoint) — these are the foundation everything else depends on.
3. **Reference the contracts file** (`PRCR-1260-contracts.md`) for exact API shapes, DTOs, and validation rules.
4. ~~**Follow the reuse strategy** — borrow from `DocShellComponent` but don't create a dependency on Template Generator's tagging service.~~ **Revised by Agent 2** — align with `HtmlRendererComponent` + `data-linenum` instead.

---

## Agent 2: Review Findings and Revised Approach

> The sections below were added by a second review agent. The plan and contracts files have been updated to reflect these findings. The original versions are preserved as `PRCR-1260-PLAN-1.md` and `PRCR-1260-contracts-1.md`.

### Critical finding: Character offset vs. block index mismatch

Agent 1's plan proposed storing **client-side block indices** (from `DocShellComponent`'s `TAGGABLE_BLOCK_SELECTOR`) in `documentStartLine`/`documentEndLine`. Investigation of the actual codebase revealed a **breaking incompatibility**:

- The Python auto-tag pipeline produces **character offsets in rendered plain text** (explicitly documented as "Character start position in HTML" in `orchestrator.py`).
- The compliance listener stores these character offsets directly in `documentStartLine`/`documentEndLine` (values like 0, 50, 100, 120).
- The original plan proposed storing **block indices** (values like 0, 1, 2, 3) in the same columns for manual items.
- This would create mixed semantics — the same columns holding character offsets (auto-tagged) and block indices (manual) with no way to distinguish them.
- Since **users edit both auto-tagged and manual items** while viewing highlighted source text, both types must highlight correctly. A "fix it later" approach is not viable.

### Resolution: Align on server-generated `data-linenum`

The revised approach uses the Python backend's existing `data-linenum` convention (from the shredding pipeline) instead of `DocShellComponent`'s client-side block indices:

1. **Python adds `data-linenum` attributes** to block elements (`p, h1-h6, li, table, tr`) with 1-based sequential integers — adapted from `shred_0120.py`'s `post_process_docling_html_block_lines()` (with `ol` removed and `tr` added).
2. **Auto-tag handler updated** to add `data-linenum` to its HTML output AND produce a char-offset → linenum mapping (`build_char_to_linenum_map()`).
3. **Compliance listener converts** segment character offsets to `data-linenum` values using the mapping before storing `documentStartLine`/`documentEndLine`.
4. **Frontend uses `data-linenum`** for selection mapping (modeled on `HtmlRendererComponent` + `LineElementsCache`, not `DocShellComponent`).
5. **Both auto-tagged and manual items** store `data-linenum` values → consistent coordinate system → highlighting works for both.

### Why `data-linenum` over `DocShellComponent` block indices

| Factor | `DocShellComponent` (client-side) | `data-linenum` (server-generated) |
|--------|-----------------------------------|-----------------------------------|
| Stability | `querySelectorAll` indices shift with browser rendering | Embedded in HTML, fixed |
| `span` handling | `TAGGABLE_BLOCK_SELECTOR` includes `span` (inline) — unstable counts | Targets only true block elements — stable |
| Coordinate system | Frontend-computed, not available to backend | Server-generated, available everywhere |
| Existing usage | Template Generator only | Shredding pipeline + `HtmlRendererComponent` |
| Backend alignment | None — Python doesn't know about client-side indices | Direct alignment with Python's shredding convention |

### What changed in the plan

| Area | Agent 1 (original) | Agent 2 (revised) |
|------|-------------------|-------------------|
| **Reuse source** | `DocShellComponent` | `HtmlRendererComponent` + `data-linenum` |
| **Block selector** | `TAGGABLE_BLOCK_SELECTOR` (h1-h6, p, li, tr, td, span) | `[data-linenum]` attribute (p, h1-h6, li, table, tr) |
| **Selection mapping** | `collectBlockElements()` + `resolveClosestBlockElement()` | `LineElementsCache` + `findNearestLineNumber()` + DOM traversal to `[data-linenum]` ancestor |
| **Coordinate system** | 0-based client-side block indices | 1-based server-generated `data-linenum` values |
| **Auto-tag compat** | Open question (deferred) | Resolved — char offsets converted to linenum at persistence time |
| **Phase 0 scope** | Conversion endpoint only (SP 3) | Conversion endpoint + `add_data_linenum()` + `build_char_to_linenum_map()` + auto-tag handler update (SP 5) |
| **Phase 1 scope** | Persist `convertedHtmlUrl` | Persist `convertedHtmlUrl` + use `linenumRanges` to convert offsets |
| **Phase 3 scope** | Borrow from DocShell | Copy `LineElementsCache`, use `data-linenum` DOM traversal |

### New types introduced

```typescript
// NestJS — auto-tag-complete.event.ts
interface LinenumRange {
  charStart: number;
  charEnd: number;
  linenum: number;
}
```

```python
# Python — html_linenum.py
class LinenumRange(BaseModel):
    char_start: int
    char_end: int
    linenum: int
```

### Additional findings from the review

1. **`HtmlRendererComponent` skips DOMPurify** — uses bare `bypassSecurityTrustHtml()`. The compliance viewer should use `DOMPurify.sanitize()` from `DocShellComponent`'s pattern (already a project dependency).

2. **`LineElementsCache` is ~38 lines** — maps `data-linenum` → DOM element + position. Copy to compliance module for now; extract to shared later.

3. **HTML payload size** — Docling uses `ImageRefMode.EMBEDDED` (base64 images inline). Large documents with images could be multi-megabyte payloads. Not blocking for initial implementation but noted as future optimization.

4. **Race condition** — concurrent on-demand conversion requests for the same document will both trigger Python calls. Accept idempotent overwrites for now.

5. **`PdfHighlightOverlayComponent`** — confirmed compliance-only. Can be removed entirely in Phase 4.

6. **Existing auto-tagged items** — items created before this change store character offsets. If there is production compliance data, a backfill migration is needed. If compliance is still in development, this is a non-issue.

### Remaining open questions (from Agent 2)

All resolved by Agents 3 and 4:
1. ~~Conversion timeout~~ → **Resolved:** Async on upload + 5-minute HTTP timeout.
2. ~~Embedded images~~ → **Resolved:** Keep for now; deferred optimization.
3. ~~XLSX multi-sheet~~ → **Still open** (moved to main Open Questions).
4. ~~Fallback for pre-existing documents~~ → **Resolved:** Scrap existing test/dev data.
5. ~~Race condition strategy~~ → **Resolved:** Accept idempotent overwrites.

### Updated guidance for the next agent

1. **Read the updated plan** — `PRCR-1260-PLAN.md` has been fully rewritten with the `data-linenum` approach. It includes all phases, file lists, and Jira tickets.
2. **Read the updated contracts** — `PRCR-1260-contracts.md` has the revised types, linenum mapping contracts, Python utility signatures, and compliance listener code snippets.
3. **Start with Phase 0** — the `add_data_linenum()` and `build_char_to_linenum_map()` Python utilities are the foundation. They unblock the auto-tag handler update and the conversion endpoint.
4. **Key files to study first:**
   - `shred_0120.py` lines 1012–1040 — the existing `data-linenum` logic to model `add_data_linenum()` on.
   - `html_preprocessing.py` → `extract_text_with_mapping()` — the text extraction algorithm that `build_char_to_linenum_map()` must use for consistent offsets.
   - `handle_auto_tag_message.py` lines 250–284 — where `add_data_linenum()` and mapping should be inserted.
   - `line-elements-cache.ts` — the ~38-line class to copy to the compliance module.
   - `html-renderer.component.ts` → `findNearestLineNumber()` and `processSelectionAndOpenOverlay()` — the selection patterns to adapt.
5. **Do NOT borrow from `DocShellComponent`** for selection or block collection. Use `data-linenum` + `LineElementsCache` exclusively.
6. **Use DOMPurify for sanitization** (from `DocShellComponent`'s pattern), not bare `bypassSecurityTrustHtml()` (which is what `HtmlRendererComponent` does).

---

## Agent 3: Open Question Resolution and Async Conversion

> Added by a third planning agent. The plan and contracts files have been updated to reflect the user's answers to open questions.

### User's answers to open questions

| # | Question | Answer | Impact |
|---|----------|--------|--------|
| 1 | Conversion timing (sync on-demand vs async) | **Async on upload** | Major architecture change — conversion triggered as fire-and-forget event after upload. GET endpoint only serves cached HTML. Added `conversion_status` column. |
| 2 | Embedded images / payload size | **Future enhancement** — documents must look exactly like originals | No change. Base64 images kept. Image optimization deferred. |
| 3 | XLSX multi-sheet handling | User unsure how to investigate | Kept as open question with guidance (test sample file through Docling). |
| 4 | Fallback for pre-existing documents | **Scrap existing test/dev data** — no backfill needed | Simplified plan. No migration for existing documents. |
| 5 | Existing auto-tagged items | **Compliance still in dev** — no production data | Char-offset → linenum semantic shift is safe. No backfill migration. |
| 6 | Race conditions / concurrency | **Accept duplicates** — separate storage per upload, no locking | No locking mechanism needed. Idempotent overwrites accepted. |

### Key architectural changes

1. **Async conversion on upload** replaces on-demand sync conversion:
   - `uploadSourceDocument` emits `compliance.document.uploaded` event after saving
   - New listener calls Python conversion endpoint via `RfpPythonServerService`
   - New `conversion_status` column tracks state (`PENDING` → `COMPLETE` / `FAILED`)
   - GET endpoint returns `200` (complete), `202` (pending), or `502` (failed)
   - Upload response is immediate — user doesn't wait for conversion

2. **Response DTO updated** with `conversionStatus` field and optional `html`

3. **Phase 1 expanded** from 6 to 8 steps (added conversion trigger + listener steps)

4. **5 of 6 original open questions resolved** — only XLSX multi-sheet remains open

### What changed in the files

| File | Changes |
|------|---------|
| `PRCR-1260-PLAN.md` | Architecture diagram updated for async flow. "On-demand conversion" → "Async conversion on upload." Open Questions resolved (5 of 6). Assumptions updated (11 items). Phase 1 expanded to 8 steps with conversion trigger/listener. Phase 2 Step 2.3 updated for conversion status handling. Phase 3 Step 3.2 updated for pending/error states. Future Work updated (removed "async on upload," added retry endpoint and polling). Jira Ticket 2 description updated. |
| `PRCR-1260-contracts.md` | GET endpoint response includes `conversionStatus`. New 202 Accepted response. DTO has `conversionStatus` field and optional `html`. Frontend type has `ConversionStatus` type. Schema adds `conversion_status` column. Upload service code snippet. Conversion listener code snippet. `RfpPythonServerService` addition with resource enum. Contracts open questions resolved (all 3). |

---

## Agent 4: Codebase-Verified Review and Final Refinements

> Added by a fourth review agent. Verified all plan/contract claims against the actual codebase and applied the user's final decisions. Plan and contracts files updated.

### What this agent did

Performed a thorough codebase-verified review of `PRCR-1260-PLAN.md` and `PRCR-1260-contracts.md`, checking every factual claim against the actual source code across all three repos. Surfaced 15 issues (mix of inaccuracies, unconsidered edge cases, and nits). The user resolved all 15, and the plan/contracts files were updated accordingly.

### Issues found and resolved

| # | Severity | Issue | Resolution |
|---|----------|-------|------------|
| 1 | High | `ComplianceItemEvidence` entity also has `documentStartLine`/`documentEndLine` — not addressed in column rename scope | **Don't rename any columns.** Keep existing names on both entities. Semantic shift from char offsets to linenum values is internal. |
| 5 | High | `ol` in block list causes double-counting (`<ol>` gets a linenum AND each child `<li>` does too) | **Remove `ol`** from `_LINENUM_BLOCK_TAGS`. `li` elements cover all list content. |
| 6 | Medium | `table` as a single linenum block is too coarse for compliance (entire table = one highlight) | **Add `tr`** to block list for row-level granularity. |
| 7 | Medium | Large HTML payloads with base64 images could be 10+ MB | **Revisit later.** Gzip compression helps. Not a blocker for MVP. |
| 10 | Medium | No polling/retry strategy for PENDING documents | **Show static message** ("processing — refresh in a moment") + note to check with design team. |
| 3 | Medium | `convertedHtmlUrl` (URL) vs `convertedHtmlKey` (MinIO key) semantic mismatch | **Note to revisit** during Phase 1 implementation. |
| 9 | Medium | No HTTP timeout on Python conversion call | **5-minute timeout** (300s). Generous because async — premature timeout forces re-upload. |
| 14 | Medium | `RfpPythonServerModule` not mentioned as needed import for `ComplianceModule` | **Added** to Step 1.3. |
| 11 | Low | `ComplianceItemEvidence.documentStartLine` references response docs, not source docs | **Don't rename.** Clarified by decision not to rename any columns. |
| 2 | Low | Resource enum called `RfpPythonServerResource`, not `Resource` | **Fixed** in contracts. |
| 4 | Low | `ul` guard in `add_data_linenum()` is dead code (ul not in block list) | **Removed** from contracts Python code. |
| 8 | Low | No user-facing message for failed conversions | **Added** "conversion failed — please re-upload" error message. |
| 12 | Low | `LineElementsCache` uses `parseInt()` | **Changed** to `Number()` per project convention. |
| 13 | Low | Python strips `head` but DocShell strips `base` — inconsistent | **Note to revisit** if rendering issues arise. |
| 15 | Low | Legacy formats (.doc, .xls, .ppt) listed but unverified in Docling | **Note to revisit** during Phase 0. |

### Summary of changes to plan and contracts files

| Change | Files affected |
|--------|---------------|
| Block tags: `ol` → removed, `tr` → added | Both (assumptions, Step 0.1, tickets, endpoint desc, Python code) |
| No column rename: keep `documentStartLine`/`documentEndLine` everywhere | Both (removed rename from migration, updated all field name references, resolved question updated) |
| Pending UX: static message + design team note | Plan (Step 3.2) |
| Failed UX: re-upload message | Plan (Step 3.2) |
| HTTP timeout: 5 min on Python call | Plan (Step 1.3) |
| `RfpPythonServerModule` import | Plan (Step 1.3) |
| `RfpPythonServerResource` enum name | Contracts (service addition, resource enum) |
| `Number()` over `parseInt()` | Contracts (LineElementsCache) |
| Dead `ul` guard removed | Contracts (Python add_data_linenum) |
| 6 new open questions added | Plan (Open Questions section) |

### Updated guidance for the next agent

1. **Read the updated plan** — `PRCR-1260-PLAN.md` has been refined with all decisions applied. Block tags are now `p, h1-h6, li, table, tr`. No column renames. 5-minute HTTP timeout on conversion calls. `RfpPythonServerModule` import required.
2. **Read the updated contracts** — `PRCR-1260-contracts.md` has corrected enum names, `Number()` usage, cleaned Python code, and updated field name references.
3. **Key decisions to remember:**
   - `documentStartLine`/`documentEndLine` columns are **NOT renamed** — the semantic shift from char offsets to linenum values is internal.
   - Block list is `p, h1-h6, li, table, tr` — **not** `ol` (avoids double-counting), **includes** `tr` (row-level table granularity).
   - PENDING conversion shows a static "processing" message — **no polling for MVP**. Check with design team later.
   - FAILED conversion tells user to re-upload the file.
   - `RfpPythonServerModule` must be imported in `ComplianceModule`.
   - Use `RfpPythonServerResource` (not `Resource`) for the enum.
   - Use `Number()` instead of `parseInt()` when copying `LineElementsCache`.
4. **Start with Phase 0** (Python utilities + conversion endpoint) — it's the foundation.

---

## Agent 5: PR Review Feedback — Queue-Based Architecture

> Added after PR review comments challenged the dedicated Python HTTP endpoint and `LinenumRange` coupling. Reviewed against the [auto-tagging integration guide](https://rohan.atlassian.net/) and revised the plan accordingly.

### What changed

Two PR comments prompted a significant architectural revision:

1. **`LinenumRange` removed from auto-tag pipeline.** The char-offset → linenum mapping is a compliance-specific concern that doesn't belong in the shared `DocumentResult` model. The mapping is now implemented in TypeScript in the NestJS compliance module (the listener downloads the HTML from MinIO, parses `[data-linenum]` elements, and builds the mapping locally).

2. **`POST /compliance/convert-document` endpoint removed.** Per the auto-tagging integration guide, compliance uses `TaggingService.requestAutoTag()` → queue → completion event flow. The auto-tag pipeline already converts documents to HTML (with `data-linenum`), uploads to MinIO, and returns `converted_html_url`. A separate synchronous HTTP endpoint bypasses queue infrastructure (retry, backpressure, scaling).

### Impact on phases

| Phase | Change |
|-------|--------|
| **Phase 0** | Significantly reduced — only `add_data_linenum` + SUPPORTED_EXTENSIONS cleanup + remove `linenum_ranges`/`LinenumRange` from pipeline. No conversion endpoint. |
| **Phase 1** | Simplified — no conversion listener or `compliance.document.uploaded` event. Just persist `convertedHtmlUrl` from auto-tag completion + implement linenum mapping in TypeScript + add GET HTML endpoint. |
| **Phase 6** | No conversion-chaining step. Overview-page uploads call `requestAutoTag()` directly. |

### New open questions

- **Open Question #8:** When does compliance call `requestAutoTag()`? On upload (faster viewing) or on wizard Finish (current behavior)? UX/product decision.
- **Open Question #9:** Char-offset → linenum mapping: at write time (in listener) or read time (in getDocumentHtml)?

### Updated guidance for the next agent

1. **Read the updated plan** — `PRCR-1260-PLAN.md` now reflects queue-based architecture. Phase 0 is much smaller. Phase 1 has no Python HTTP dependency.
2. **Read the updated contracts** — `PRCR-1260-contracts.md` removes the Python endpoint, `LinenumRange` from pipeline types, and adds the TypeScript `buildLinenumMapFromHtml` implementation.
3. **Key decisions:**
   - No `POST /compliance/convert-document` endpoint — use `requestAutoTag()` queue flow.
   - No `linenum_ranges` in `DocumentResult` — mapping done in NestJS.
   - `add_data_linenum()` stays in auto-tag handler (enriches HTML for all consumers).
   - ~~`RfpPythonServerModule` import~~ no longer needed — no direct Python HTTP calls.
   - `conversion_status` column likely unnecessary — existing `processingStatus` + `convertedHtmlKey` non-null is sufficient.
4. **Before implementing, resolve Open Questions #8 and #9** with the team.

---

## Screenshots

The user provided screenshots of the current Compliance Review UI showing:
- The document viewer panel with the document dropdown selector (top-right).
- Left panel with compliance items (volume sections with Yes/No buttons).
- Right panel showing the document content (currently real content from an existing flow, showing what the target UX looks like).
- Text selection with "Add compliance item" popover appearing below the selection.

Screenshot files:
- `/Users/tim/.cursor/projects/Users-tim-Documents-code-rohan/assets/Screenshot_2026-03-18_at_10.57.21_AM-903db76d-7c98-49b0-a43d-1688ba15d3c8.png`
- `/Users/tim/.cursor/projects/Users-tim-Documents-code-rohan/assets/Screenshot_2026-03-18_at_10.57.23_AM-494efd6d-726c-4c05-b3d5-cc6c62c767a4.png`
- `/Users/tim/.cursor/projects/Users-tim-Documents-code-rohan/assets/Screenshot_2026-03-18_at_10.57.36_AM-fa0da40e-b0eb-44d1-97b8-8beb03d83574.png`
