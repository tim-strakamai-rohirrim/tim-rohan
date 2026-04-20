# PRCR-1260: Compliance Document Viewer — Real Document Content

## Problem Statement

The **Document Viewer Panel** in the Compliance List Creation workflow (`document-viewer-panel.component`) currently displays **mock/hardcoded text lines** instead of the actual content of uploaded documents. The `mapProjectDocumentsToViewerDocuments()` utility in `compliance-document.utils.ts` maps project documents onto `MOCK_COMPLIANCE_DOCUMENTS` line data (with a TODO to replace it).

Users need to:
1. View the **real content** of each uploaded source document in the right-hand panel, with layout that **matches the look of the original document**.
2. **Highlight text** within the rendered document and create compliance items (tagging) from the selection — even when auto-tagging has not been run.
3. **Edit both auto-tagged and manually created compliance items** (title, text, etc.) while viewing the highlighted source passage for context.
4. Switch between multiple documents via the existing dropdown.
5. **Add new documents** to an existing project from the overview page's Document Library (post-wizard), with auto-tagging running automatically on only the new documents after conversion completes.
6. **Delete documents** from the library, with all associated compliance items automatically removed from the database.

The viewer must support **PDF, DOCX, and XLSX** files. Docling already converts all three formats to HTML uniformly, so one rendering path handles all file types.

### Document lifecycle context

The compliance project wizard (Create → Preview → Finish) already triggers auto-tagging on all uploaded documents when the user clicks **Finish** (`onFinish()` calls `processDocuments(projectId, true)` fire-and-forget). This behavior is correct and does not change.

After finishing the wizard, the user lands on the **project overview page**, which includes a Document Library section where they can:
- **Upload additional documents** (drag-and-drop or file picker, same UI as the wizard).
- **Delete documents** (remove button on each document card).

Documents added from the overview page must be auto-tagged automatically after conversion completes — there is no "Finish" button on the overview page. Documents deleted from the overview page must cascade-delete all associated compliance items.

---

## Current State Summary

| Layer | What exists | Gap |
|-------|------------|-----|
| **Frontend — `document-viewer-panel`** | Line-based rendering (`@for line of document.lines`), text selection maps to line numbers, "Add Compliance Item" popover. | Uses mock data. Line-based rendering does not preserve original document layout. |
| **Frontend — `DocShellComponent`** (shared) | Renders Docling HTML via `innerHTML`, block-based selection capture (client-side block indices via `TAGGABLE_BLOCK_SELECTOR`), highlights via CSS. Tag-type context menu via `TaggingService`. Used by Template Generator's Tag Step. | Context menu is tied to template-generator tag config. Client-side block indices include `span` (unstable). Not used by compliance. |
| **Frontend — `HtmlRendererComponent`** (proposal-writer) | Renders HTML via `innerHTML`, uses server-generated `data-linenum` attributes for selection mapping via `LineElementsCache`. Tagging context menu. Used by Create Proposal Wizard. | Module-scoped to proposal-writer. Not shared. |
| **Backend (NestJS) — compliance controller** | Upload, auto-tag endpoints. `ComplianceDocument` entity has `minioObjectKey`, `mimeType`, `taggable_doc_id`. | No endpoint to serve converted HTML. |
| **Backend (NestJS) — compliance listener** | `handleAutoTagComplete` creates compliance items. Event carries `convertedHtmlUrl` but **compliance listener does not persist it** (template-documents listener does). Stores `start_offset`/`end_offset` (character offsets) in `documentStartLine`/`documentEndLine`. | Converted HTML URL from auto-tag pipeline is lost. Character offsets stored in line-number columns. |
| **Backend (Python) — auto-tag handler** | Docling converts PDF/DOCX/XLSX → HTML. Uploads converted HTML to MinIO. Returns `converted_html_url` in `DocumentResult`. Segments have `start_offset`/`end_offset` as **character positions in rendered text**. | Conversion is coupled with tagging pipeline (no standalone endpoint). HTML lacks `data-linenum` attributes. No char-offset → linenum mapping. |
| **Backend (Python) — shredding pipeline** | `post_process_docling_html_block_lines()` in `shred_0120.py` adds `data-linenum` attributes to block elements (`p, h1-h6, li, table, ol`). 1-based sequential integers. | Only used by shredding pipeline, not auto-tag. |

---

## Proposed Approach

### Render Docling HTML via `innerHTML` with server-generated `data-linenum` attributes

Rather than extracting text lines from the Docling HTML, we serve the **Docling HTML with `data-linenum` attributes** to the frontend and render it via `innerHTML`. This preserves the original document's visual layout (fonts, tables, lists, formatting) exactly as Docling rendered it.

The `data-linenum` approach aligns with:
- **The Python shredding pipeline** (`shred_0120.py`) — which already adds `data-linenum` to block elements.
- **`HtmlRendererComponent`** in Proposal Writer — which consumes `data-linenum` for selection mapping via `LineElementsCache`.

### Why `data-linenum` over client-side block indices

The original plan proposed borrowing `DocShellComponent`'s approach (collecting block elements client-side via `TAGGABLE_BLOCK_SELECTOR`). The `data-linenum` approach is superior because:

1. **Server-generated coordinates are stable.** `data-linenum` values are embedded in the HTML by Python and don't change with browser rendering. Client-side `querySelectorAll` indices shift if CSS or DOM rendering differs.
2. **No `span` instability.** `TAGGABLE_BLOCK_SELECTOR` includes `span` (an inline element), making client-side block counts unreliable. `data-linenum` targets true block elements (`p, h1-h6, li, table, tr`) without `span`.
3. **Consistent coordinate system.** Both auto-tagged and manual compliance items store `data-linenum` values in `documentStartLine`/`documentEndLine`. No mixed semantics.
4. **Proven pattern.** `HtmlRendererComponent` + `LineElementsCache` is already production-tested in the proposal writer.
5. **Alignment path.** Since users edit auto-tagged items alongside manual items (viewing source highlights for context), both types must highlight correctly. The `data-linenum` approach, combined with a char-offset → linenum mapping in the auto-tag pipeline, achieves this.

### Architecture

> **Revised per PR review.** Conversion now happens as part of the auto-tag queue pipeline, not a separate HTTP endpoint. See "PR Review Feedback" section below for details.

```
User uploads document
  → NestJS: Save to MinIO, create ComplianceDocument

User clicks Finish (wizard) or uploads from overview page
  → NestJS: Call TaggingService.requestAutoTag() for each document
  → Queue message → Python auto-tag handler
  → Python: Docling converts → strips metadata → adds data-linenum → tags → uploads HTML to MinIO
  → Python: Sends AutoTagComplete to topic with converted_html_url
  → NestJS: AutoTagCompleteHandler persists segments/tags, emits 'tagging.auto-tag-complete'
  → Compliance listener: Persists convertedHtmlKey, converts char offsets → linenum, creates items

User selects document in viewer
  → Frontend: GET /compliance/projects/:pid/documents/:did/html
  → NestJS: Check convertedHtmlKey
    → Non-null: Read HTML from MinIO, return 200 with html
    → Null + processing: Return 202 (no html yet)
    → Null + failed: Return 502 with error message
  → Frontend: DOMPurify.sanitize() + render via innerHTML
  → Frontend: Build LineElementsCache from [data-linenum] elements
  → User selects text → resolve to data-linenum range → "Add Compliance Item" popover
  → Compliance item created with startLine/endLine
```

### Reuse strategy: Align with `HtmlRendererComponent`, not `DocShellComponent`

**Why not `DocShellComponent`:**
- Its context menu is hard-wired to `TaggingService.templateGeneratorConfig()` (tag type selection with categories like Instructions, Structure, Evaluation, Requirements).
- Compliance needs a different flow: select text → "Add Compliance Item" button → create item. No tag-type menu.
- Its tag layer (positioned tag chips alongside content) is not the compliance UX — compliance shows items in a separate left panel.
- Its `TAGGABLE_BLOCK_SELECTOR` includes `span`, making block indices unstable for persistent storage.
- Coupling compliance to the template-generator's `TaggingService` would create an unwanted dependency.

**What to borrow from `HtmlRendererComponent`:**
- `LineElementsCache` — maps `data-linenum` values to DOM elements and positions. Small class (~38 lines). Copy to compliance module (future: extract to shared).
- `findNearestLineNumber()` — resolves a viewport Y coordinate to the nearest `[data-linenum]` element.
- Selection → linenum mapping — on `mouseup`, resolve selection start/end to `data-linenum` values via DOM traversal.
- `[innerHTML]="sanitizedHtml"` rendering pattern.

**What to borrow from `DocShellComponent`:**
- HTML sanitization: `DOMPurify.sanitize()` → strip unsafe tags → `bypassSecurityTrustHtml()`. (`HtmlRendererComponent` skips DOMPurify — a security gap we fix.)

**What to keep from current compliance viewer:**
- Document selector dropdown.
- "Add Compliance Item" popover on text selection.
- Compliance item list in left panel (separate component).
- Integration with `ComplianceStateService`.

### Selection-to-compliance-item mapping

Both auto-tagged and manually created compliance items store `data-linenum` values (1-based block indices) in `documentStartLine` / `documentEndLine`:

- **Manual items:** Frontend maps the text selection to `data-linenum` values of the start/end block elements → stored directly.
- **Auto-tagged items:** The Python auto-tag handler adds `data-linenum` to the HTML and computes a char-offset → linenum mapping. The NestJS compliance listener converts segment `start_offset`/`end_offset` to `data-linenum` values using this mapping before storing.

This ensures a single, consistent coordinate system across all compliance items, so highlighting works identically for both auto-tagged and manual items — critical since users edit both types while viewing source highlights.

### Conversion via the auto-tag queue pipeline

> **Revised per PR review.** Conversion no longer uses a dedicated HTTP endpoint. Instead, it happens as part of the standard auto-tag queue pipeline (see "PR Review Feedback" section below).

Document conversion happens as a byproduct of the auto-tag pipeline. When `TaggingService.requestAutoTag()` is called (either from the wizard "Finish" button or from an overview-page upload), a queue message is sent to Python. The auto-tag handler converts the document to HTML (with `data-linenum` attributes), runs segmentation and classification, uploads the HTML to MinIO, and sends a completion event with `converted_html_url`.

The `GET .../html` endpoint **only serves cached HTML** — no on-demand conversion. If the auto-tag pipeline hasn't completed yet (no `convertedHtmlKey` on the entity), the endpoint returns `202 Accepted`. If auto-tag failed, it returns `502`.

This leverages the queue's natural benefits: retry semantics, backpressure, horizontal scaling, and dead-letter queue for persistent failures. The timing of when `requestAutoTag()` is called determines when documents become viewable — see Open Question #8.

---

## Assumptions

1. `MinioService` is available (or can be injected) in the compliance module. (Verified: already imported in `compliance.module.ts`.)
2. `EventEmitter2` is available in the compliance module for emitting internal events. (Standard NestJS pattern — `EventEmitterModule` is typically imported at the app level.)
3. ~~`RfpPythonServerService` (or equivalent HTTP client) is available for NestJS → Python calls. A new resource enum entry is needed for `/compliance/convert-document`.~~ **Removed per PR review** — no direct HTTP call to Python. Compliance uses `TaggingService.requestAutoTag()` which manages the queue internally.
4. Docling conversion completes within a reasonable time (< 60s) for typical documents. Since conversion happens in the auto-tag queue pipeline, timeouts are managed by the queue infrastructure (retry, dead-letter queue).
5. The Docling HTML output preserves the visual layout of the original document well enough for compliance review purposes. Embedded base64 images are kept to match the original look.
6. `data-linenum` targets (`p, h1-h6, li, table, tr`) cover the block elements Docling produces. Adapted from the shredding pipeline's block list, with `ol` removed (avoids double-counting `li` content) and `tr` added (enables row-level table granularity).
7. `documentStartLine` / `documentEndLine` on compliance items will store `data-linenum` values (1-based block indices). The column names are kept as-is — the semantic shift from character offsets to `data-linenum` values is internal. No production data exists, so no migration is needed.
8. `DOMPurify` is already a dependency (used by `DocShellComponent`).
9. The `build_char_to_linenum_map()` utility in Python uses the same text extraction algorithm (`extract_text_with_mapping`) as the segmenter, ensuring consistent offset mapping.
10. Compliance is still in development — no production data exists. Character offsets in existing `documentStartLine`/`documentEndLine` values can be discarded without migration.
11. Existing test/dev documents auto-tagged before `convertedHtmlKey` was added do not need a backfill. They can be re-uploaded to trigger conversion.
12. Multi-sheet XLSX files: Docling's export layer merges all sheets into a single flat HTML output (sequential `<table>` elements). `add_data_linenum()` numbers them sequentially with no special handling needed. Sheet boundary markers are deferred as future work.
13. Auto-tagging from the wizard "Finish" button already works correctly — `onFinish()` calls `processDocuments(projectId, true)` fire-and-forget. No change to this trigger is needed.
14. The overview page's Document Library uses the same `uploadSourceDocument` backend endpoint as the wizard. The difference is context: overview-page uploads should auto-tag after conversion; wizard uploads rely on the "Finish" button.
15. `compliance_items.source_document_id` has `ON DELETE CASCADE` referencing `compliance_documents(id)`. Deleting the `compliance_documents` row automatically deletes all associated compliance items. (Verified in `init_compliance.sql`.)
16. The current document removal code (`updateProject` with `documentsToDelete`) only deletes from the `compliance_project_documents` join table — it does not delete the `compliance_documents` row. This must change for cascade cleanup to work.

---

## Resolved Questions

1. **Conversion timing.** ~~On-demand sync on first view?~~ → **Async on upload.** Conversion is triggered as a fire-and-forget event when a document is uploaded. The GET endpoint only serves cached HTML. See "Async conversion on upload" section above.
2. **Embedded images / max document size.** ~~Strip or serve separately?~~ → **Keep embedded base64 images** for now. Documents must look exactly like their originals. Image optimization (stripping, lazy-loading, or serving separately) is a future enhancement.
3. **Fallback for already-processed documents.** ~~Backfill migration?~~ → **Not needed.** Existing documents are test/development data and can be scrapped. No backfill migration required.
4. **Existing auto-tagged items / semantic shift.** ~~Backfill from char offsets to data-linenum?~~ → **Not needed.** Compliance is still in development — no production data to preserve. The shift from character offsets to `data-linenum` values in `documentStartLine`/`documentEndLine` is safe.
5. **Race condition on concurrent conversion.** ~~Locking mechanism?~~ → **Accept idempotent overwrites.** Two users can upload the same document and each gets a separate `ComplianceDocument` entity. Concurrent conversions of the same entity (e.g., upload conversion + auto-tag conversion) produce the same output — last writer wins.
6. **Column rename.** ~~Rename `documentStartLine`/`documentEndLine` to `documentStartLineNum`/`documentEndLineNum`?~~ → **Keep existing names.** The semantic shift from character offsets to `data-linenum` values is internal. Renaming columns, DTOs, frontend types, and tests across both `ComplianceItem` and `ComplianceItemEvidence` adds complexity without proportional benefit.
7. **XLSX multi-sheet handling.** ~~How does Docling render multiple sheets?~~ → **No plan changes needed for MVP.** Docling's export layer merges all sheets into a single flat HTML output — each sheet becomes one or more sequential `<table>` elements. `add_data_linenum()` assigns sequential `data-linenum` values across all tables/rows naturally. Users see all sheets as one continuous scrollable document. Sheet boundary markers (injecting sheet name headers between tables) are deferred as future work (see Open Question #4).
8. **`convertedHtmlUrl` vs `convertedHtmlKey` semantics.** ~~Is it a full blob URL or a MinIO key?~~ → **It's an object key (path only).** Despite the `_url` suffix, the Python auto-tag handler always sets `converted_html_url` to `output_blob_path` — a constructed path like `org_abc/docs/output/file.html`. The upload functions' return values are never captured. The NestJS auto-tag-complete handler and template-documents listener pass it through with no URL parsing. The compliance listener can store it directly in `convertedHtmlKey`. **Bucket:** All writes go to the `uploads` bucket — compliance `putObject` defaults to `uploadsBucket` (hardcoded `'uploads'`), and the Python auto-tag handler uploads to `MINIO_TAGGING_BUCKET` (default `'uploads'`). However, `getObjectBuffer` defaults to `this.configs.bucket` (from `MINIO_BUCKET` env var), which may differ. The `getDocumentHtml` method should pass the bucket explicitly (e.g., `'uploads'`) rather than relying on the default.
9. **Legacy Office format support.** ~~Support `.doc`, `.xls`, `.ppt` via LibreOffice pre-conversion?~~ → **Restrict to modern formats only.** Docling does not support legacy Office formats — it only handles Office Open XML (`.docx`, `.xlsx`, `.pptx`) and PDF. LibreOffice is installed in the container but only for DOCX→PDF and PPTX→PNG, not legacy→modern conversion. A two-step pipeline (LibreOffice → Docling) would degrade visual fidelity. The Angular compliance UI already restricts to `.pdf`, `.docx`, `.xlsx`, and every other NestJS service (template-documents, procurement-writer) restricts to modern formats. The conversion endpoint validates extensions and returns `422` for unsupported formats. `SUPPORTED_EXTENSIONS` in `handle_auto_tag_message.py` is cleaned up to remove `.doc`, `.xls`, `.ppt` (latent bug — listed but conversion fails).

---

## PR Review Feedback & Revised Architecture

> Added after PR review comments on `html_linenum.py` and `compliance.py:50-51`. Both comments challenge Phase 0's approach — the dedicated Python HTTP endpoint and the `LinenumRange` coupling. After review against the [auto-tagging integration guide](https://rohan.atlassian.net/) (Jira), the plan is revised as described below.

### Comment 1: `LinenumRange` couples compliance concerns into the shared tagging pipeline

> "The tagging rework explicitly moved away from line-number-based coordinates in favour of character offsets on document_segments. Reintroducing LinenumRange here feels like it's working around the new model rather than building on it."

**Assessment: Agree.** The `linenum_ranges` field on `DocumentResult` ships a compliance-specific mapping in every auto-tag completion message — even for template-generator and proposal-writer, which don't use it. This is the wrong layer for this concern.

**Resolution:**
- **Remove** `build_char_to_linenum_map()` from the Python auto-tag handler.
- **Remove** `linenum_ranges` from `DocumentResult` and `AutoTagCompleteMessage`.
- **Remove** `LinenumRange` from `tagging_message.py`.
- **Keep** `add_data_linenum()` in the auto-tag handler — enriching the HTML with `data-linenum` attributes is harmless and useful for any consumer (aligns with the shredding pipeline's convention). It stays as a universal HTML post-processing step, not a compliance-specific addition.
- **Move** the char-offset → linenum mapping to the **NestJS compliance module**. When the compliance listener creates items from auto-tag segments, it downloads the line-numbered HTML from MinIO, builds the mapping in TypeScript (parse `[data-linenum]` elements, extract text, find offsets), and converts segment `start_offset`/`end_offset` to linenum values before storing. This keeps the compliance-specific logic in the compliance module where it belongs.
- **Alternative (simpler, recommended):** Do the mapping at **read time** instead of write time. Store char offsets as-is in `documentStartLine`/`documentEndLine` for auto-tagged items. When NestJS serves the `GET .../html` response, include both the HTML and the compliance items' coordinates already translated to linenum. This avoids an extra MinIO read during auto-tag completion processing.

### Comment 2: Queue-based flow, not a dedicated HTTP endpoint

> "Per the tagging rework spec, compliance was intended to onboard through tag_configs and the existing AutoTagRequestMessage queue flow rather than a dedicated HTTP endpoint."

**Assessment: Agree.** The [auto-tagging integration guide](https://rohan.atlassian.net/) makes this explicit: your feature calls `TaggingService.requestAutoTag()`, the tagging layer handles bus/persistence/completion, and your listener reacts to `'tagging.auto-tag-complete'`. The `POST /compliance/convert-document` HTTP endpoint bypasses this entire infrastructure and has operational problems (no retry, no backpressure, ties up a worker for 30+ seconds).

**Resolution:**
- **Remove** the `POST /compliance/convert-document` Python endpoint entirely (`rohan-python-api/backend/app/api/routes/compliance.py`).
- **Remove** `ConvertDocumentRequest`/`ConvertDocumentResponse` models.
- **Remove** `RfpPythonServerResource.COMPLIANCE_CONVERT_DOCUMENT` and `RfpPythonServerService.convertDocument()`.
- **Remove** the `compliance.document.uploaded` internal event and its conversion listener (Phase 1 Steps 1.2 and 1.3).
- **Use** the existing `requestAutoTag()` → queue → completion flow for all document processing.
- The auto-tag handler already converts documents to HTML (with `data-linenum`), uploads to MinIO, and returns `converted_html_url` in the completion event. The compliance listener just needs to persist this value as `convertedHtmlKey`.

### Impact on phases

| Phase | Change |
|-------|--------|
| **Phase 0** | Significantly reduced. Steps 0.2 (build_char_to_linenum_map), 0.3 (conversion endpoint), and 0.6 (linenum_ranges on DocumentResult) are removed. Only `add_data_linenum()` utility, SUPPORTED_EXTENSIONS cleanup, and the auto-tag handler calling `add_data_linenum()` remain. |
| **Phase 1** | Steps 1.2 (async conversion trigger) and 1.3 (conversion listener) are removed. Step 1.4 simplified: compliance listener persists `convertedHtmlUrl` and implements char-offset → linenum mapping in TypeScript. The `conversionStatus` column may be simplified to track auto-tag processing status rather than a separate conversion lifecycle. |
| **Phase 6** | Step 6A.1 (`autoTag` query parameter) simplified: overview-page uploads call `requestAutoTag()` directly instead of using a flag + chained conversion. Step 6A.2 (chain auto-tagging after conversion) removed entirely — there's no separate conversion step to chain after. |
| **Contracts** | Python endpoint removed. `LinenumRange` removed from Python types. `linenum_ranges` removed from `DocumentResult` and `AutoTagCompleteEvent`. `RfpPythonServerService.convertDocument()` removed. `RfpPythonServerResource.COMPLIANCE_CONVERT_DOCUMENT` removed. |

### New open question: When does compliance call `requestAutoTag()`?

This is a **UX/product decision** that affects when documents become viewable. See Open Question #8 below.

---

## Open Questions

1. **HTML stripping consistency.** Python's `strip_html_metadata` strips `{"style", "script", "head", "meta", "link", "title"}` while the DocShell frontend strips `'base,link,meta,script,style,title'`. Python strips `head` (container) but not `base`; DocShell strips `base` but not `head`. Both passes run (Python server-side, DOMPurify client-side), so this is safe in practice. _(Revisit if stripping-related rendering issues arise.)_
2. **Pending conversion UX.** For MVP, the viewer shows a static "processing" message with a prompt to refresh. _(Check with the design team on whether polling, auto-refresh, or a manual refresh button would be better UX.)_
3. **Large HTML payloads.** Documents with many embedded base64 images could produce multi-megabyte JSON payloads. NestJS/Express gzip compression mitigates this significantly. _(Revisit if real documents cause performance issues — options include streaming the HTML directly, lazy-loading images, or serving images separately.)_
4. **XLSX sheet boundary markers.** Multi-sheet XLSX files render as sequential `<table>` elements with no visual separation between sheets. Users reviewing multi-sheet files won't see which sheet a table came from. _(Future enhancement: inject sheet name headers between tables during conversion by iterating `DoclingDocument.tables` instead of using the flat export. Not needed for MVP — compliance reviewers view the whole document.)_
5. **Auto-tag race with document deletion.** If a user deletes a document while auto-tagging is in progress (message on Azure Service Bus or Python handler running), the `handleAutoTagComplete` listener will try to create compliance items for a deleted document. The FK constraint will reject the insert. _(The listener should handle this gracefully — check if the document still exists, or wrap item creation in a try/catch. Acceptable for MVP since deletion during active processing is uncommon.)_
6. **MinIO cleanup on document deletion.** When a `compliance_documents` row is deleted, the DB cascade removes compliance items but does not clean up MinIO files (source document + converted HTML). _(Should the delete endpoint also remove files from MinIO? Or leave them as orphans for a future cleanup job? Recommend: delete from MinIO in the same operation for data hygiene, but wrap in try/catch so MinIO failures don't prevent the DB delete.)_
7. **Overview page Document Library upload component.** The overview page's Document Library uses the shared `app-document-upload` component. _(Verify during implementation that this component can accept a callback or config to trigger `requestAutoTag()` after upload completes.)_
8. **When does compliance call `requestAutoTag()`?** This is a UX/product decision that determines when documents become viewable in the Document Viewer Panel. The auto-tag pipeline produces the converted HTML as a byproduct, so document viewing is gated on auto-tag completion. Options:
   - **Option A — On upload (each document individually):** Documents are viewable ~30-60s after upload (as soon as the pipeline completes). Auto-tagging starts before the user "commits" via Finish. Wasted work if the wizard is abandoned. The wizard "Finish" button no longer needs to trigger auto-tagging (it already ran). For overview-page uploads this is clearly correct (no Finish button exists).
   - **Option B — On wizard Finish only (current behavior):** Documents are not viewable until the user clicks Finish and the pipeline completes. Matches the existing UX. Overview-page uploads would still need to call `requestAutoTag()` immediately (no Finish button on the overview page).
   - **Option C — On upload with `isAutoTag: false`, then on Finish with `isAutoTag: true`:** The first call runs segmentation only (no LLM classification) and produces converted HTML. The second call re-processes with full classification. This gives HTML faster but **double-processes** every document (wasteful). Not recommended.
   - _(Recommendation: Option A for overview-page uploads is unambiguous. For wizard uploads, discuss with product/design whether users need to view documents before clicking Finish. If yes → Option A. If no → Option B.)_
9. **Char-offset → linenum mapping layer.** Two approaches for converting auto-tagged items' character offsets to `data-linenum` values (needed for frontend highlighting):
   - **Write-time (in compliance listener):** When `handleAutoTagComplete` fires, download the HTML from MinIO, parse `[data-linenum]` elements, build the mapping, and convert segment offsets to linenum values before storing in `documentStartLine`/`documentEndLine`. Pro: DB always has linenum values, reads are simple. Con: Extra MinIO read during completion processing.
   - **Read-time (in getDocumentHtml):** Store char offsets as-is in `documentStartLine`/`documentEndLine`. When serving the `GET .../html` response, build the mapping from the HTML being served and include translated linenum coordinates in the response alongside the compliance items. Pro: No extra processing at write time, single source of truth (HTML). Con: Computation on every read (cacheable), slightly more complex response shape.
   - _(Recommendation: Write-time is simpler for the frontend — it always receives linenum values and doesn't need to know about char offsets. The extra MinIO read is acceptable since the listener is already async.)_

---

## Implementation Plan

### Phase 0: Python — `data-linenum` HTML Enrichment `[BACKEND_DB]`

> **Goal:** Add `data-linenum` post-processing to the auto-tag handler so all converted HTML has stable block-level anchors. Clean up legacy extension support. ~~Add standalone conversion endpoint and linenum mapping~~ (removed per PR review — see "PR Review Feedback" section above).

#### Step 0.1: Add `add_data_linenum()` utility

- **File:** `rohan-python-api/backend/app/domains/shared/html/html_linenum.py` *(already created)*
- **What:** Standalone utility that adds `data-linenum` attributes to block elements in Docling HTML:
  - Targets: `p, h1, h2, h3, h4, h5, h6, li, table, tr` (adapted from shredding pipeline's `post_process_docling_html_block_lines()`, with `ol` removed to avoid double-counting list content and `tr` added for table row granularity).
  - Skips empty blocks.
  - 1-based sequential numbering.
  - Returns modified HTML string.
  - ~15 lines. No file I/O, no blob clients — pure HTML transformation.

#### ~~Step 0.2: Add `build_char_to_linenum_map()` utility~~ — REMOVED

> **Removed per PR review.** The char-offset → linenum mapping is a compliance-specific concern. It should not live in the shared Python tagging pipeline. The mapping will be implemented in the NestJS compliance module instead (see Phase 1 Step 1.4 and Open Question #9).
>
> The `build_char_to_linenum_map()` function and `LinenumRange` model may be removed from `html_linenum.py` or kept as a utility for future use, but they are no longer called by the auto-tag handler or shipped in completion messages.

#### ~~Step 0.3: Add conversion endpoint to Python API~~ — REMOVED

> **Removed per PR review.** Per the [auto-tagging integration guide](https://rohan.atlassian.net/), compliance should use `TaggingService.requestAutoTag()` → queue → completion event flow. The `POST /compliance/convert-document` HTTP endpoint is removed. See "PR Review Feedback" section above.
>
> **File to remove:** `rohan-python-api/backend/app/api/routes/compliance.py`

#### Step 0.4: Clean up `SUPPORTED_EXTENSIONS` in auto-tag handler

- **File:** `rohan-python-api/backend/app/azure_event_bus/handlers/handle_auto_tag_message.py`
- **What:** Remove `.doc`, `.xls`, `.ppt` from `SUPPORTED_EXTENSIONS`. These are listed but Docling cannot convert them — legacy files selected for processing fail silently at conversion time. Restricting to `{".pdf", ".docx", ".pptx", ".xlsx"}` aligns with the rest of the system (Angular UI, template-documents, procurement-writer, ARC ingestion).
- **Status:** Already done in current branch.

#### Step 0.5: Update auto-tag handler to call `add_data_linenum()` on HTML

- **File:** `rohan-python-api/backend/app/azure_event_bus/handlers/handle_auto_tag_message.py`
- **What:** After `strip_html_metadata()`, call `add_data_linenum()` on the HTML before uploading to MinIO.
- **Impact:** The HTML uploaded by auto-tag now has `data-linenum` attributes. This is additive and harmless to other consumers (template-generator's `DocShellComponent` ignores unknown attributes).
- **Status:** Already done in current branch.
- ~~Include `linenum_ranges` in the `DocumentResult`.~~ **REMOVED** — `linenum_ranges` is no longer shipped in the completion message. The mapping is computed in NestJS if needed.

#### ~~Step 0.6: Add `linenum_ranges` to `DocumentResult` model~~ — REMOVED

> **Removed per PR review.** `linenum_ranges` is no longer part of `DocumentResult`. The char-offset → linenum mapping lives in the NestJS compliance module. The `linenum_ranges` field and its `LinenumRange` import should be removed from `DocumentResult` in `tagging_message.py`.

#### Step 0.7: Unit tests

- **File:** `rohan-python-api/backend/app/tests/domains/shared/html/test_html_linenum.py` *(already created)*
- **What:** Test `add_data_linenum()` (block targeting, numbering, empty block skipping). ~~Test `build_char_to_linenum_map()` (offset-to-linenum accuracy).~~ Linenum mapping tests are deferred to NestJS.
- ~~**File:** `rohan-python-api/backend/app/tests/api/routes/test_compliance.py`~~ — REMOVED (conversion endpoint removed).

---

### Phase 1: Backend — Persist Auto-Tag HTML + Document HTML Endpoint `[BACKEND_DB]`

> **Goal:** Persist `convertedHtmlUrl` from auto-tag completions. Serve cached HTML via a new endpoint. Implement char-offset → linenum mapping in the compliance module. ~~Trigger Docling conversion asynchronously on document upload~~ (removed per PR review — conversion happens via the auto-tag queue pipeline).

#### Step 1.1: Add `convertedHtmlKey` column + migration

- **Files:**
  - `rohan_api-parent/rohan_api/src/compliance/entities/compliance-document.entity.ts`
  - New TypeORM migration
- **What:**
  - Add nullable `converted_html_key` (`varchar(500)`) to `compliance_documents`.
  - ~~Add `conversion_status` column~~ — **Simplified.** Since conversion now happens as part of the auto-tag pipeline (not a separate step), a dedicated `conversion_status` column may be unnecessary. The existing `processingStatus` on `ComplianceDocument` (set by `markDocumentReady`/`markDocumentFailed`) already tracks whether the auto-tag pipeline succeeded or failed. `convertedHtmlKey` being non-null indicates HTML is available. _(Confirm during implementation: is the existing `processingStatus` sufficient, or do we still need a separate `conversionStatus`?)_

#### ~~Step 1.2: Add async conversion trigger on upload~~ — REMOVED

> **Removed per PR review.** There is no separate conversion step. Document conversion happens as part of the auto-tag queue pipeline when `requestAutoTag()` is called. The `compliance.document.uploaded` internal event and its handler are not needed.

#### ~~Step 1.3: Add conversion listener~~ — REMOVED

> **Removed per PR review.** No dedicated conversion listener. The existing `handleAutoTagComplete` listener receives the completion event (which includes `convertedHtmlUrl`) and updates the entity.

#### Step 1.4: Update compliance listener to persist `convertedHtmlUrl` + implement linenum mapping

- **File:** `rohan_api-parent/rohan_api/src/compliance/listeners/compliance.listener.ts`
- **What:**
  1. In `handleAutoTagComplete`, persist `event.convertedHtmlUrl` directly as `convertedHtmlKey` on the `ComplianceDocument` (it's already an object key despite the `_url` name — see Resolved Question #8).
  2. Implement char-offset → linenum mapping **in TypeScript** within the compliance module:
     - Download the line-numbered HTML from MinIO using `convertedHtmlKey`.
     - Parse `[data-linenum]` elements (using `cheerio` or `DOMParser`), extract their text content, and build a `{ charStart, charEnd, linenum }[]` mapping.
     - Convert segment `start_offset`/`end_offset` to `data-linenum` values when setting `documentStartLine`/`documentEndLine`.
     - Add `charOffsetToLinenum()` helper method.
  3. _(Alternative: defer the mapping to read-time in `getDocumentHtml`. See Open Question #9 for the trade-off.)_
- **File:** `rohan_api-parent/rohan_api/src/tagging/events/auto-tag-complete.event.ts`
- **What:** ~~Add `linenumRanges` field~~ — No change needed. The `convertedHtmlUrl` field is already on the event (just not persisted by the compliance listener currently). No new fields required.
- **File:** `rohan_api-parent/rohan_api/src/utils/roh-azure-utils/handlers/auto-tag-complete.handler.ts`
- **What:** ~~Extract `linenum_ranges` from the auto-tag message body~~ — No change needed. The handler already extracts `converted_html_url` from the message documents and includes it in the emitted event. No additional fields to extract.

#### Step 1.5: Add `getDocumentHtml` method to `ComplianceService`

- **File:** `rohan_api-parent/rohan_api/src/compliance/compliance.service.ts`
- **What:** New method that:
  1. Looks up `ComplianceDocument` by ID + validates project ownership.
  2. Checks whether HTML is available:
     - `convertedHtmlKey` set → reads HTML from MinIO via `MinioService.getObjectBuffer(key, 'uploads')` → returns `{ documentId, documentName, mimeType, conversionStatus: 'COMPLETE', html }`. Pass `'uploads'` explicitly — both compliance uploads and the Python auto-tag handler write to the `uploads` bucket, but `getObjectBuffer` defaults to `MINIO_BUCKET` env var which may differ.
     - `convertedHtmlKey` null + auto-tag processing in progress → returns `{ documentId, documentName, mimeType, conversionStatus: 'PENDING', html: null }`.
     - `convertedHtmlKey` null + auto-tag failed → throws `BadGatewayException` with failure message.
     - `convertedHtmlKey` null + no auto-tag requested yet → returns `{ ..., conversionStatus: 'PENDING' }`. _(Documents that haven't been through the auto-tag pipeline yet have no HTML. The frontend shows a "processing" or "not yet processed" state. See Open Question #8 on when `requestAutoTag()` is called.)_

#### Step 1.6: Add controller endpoint

- **File:** `rohan_api-parent/rohan_api/src/compliance/compliance.controller.ts`
- **What:** `GET /compliance/projects/:projectId/documents/:documentId/html`
  - Auth: JWT + compliance permission guard.
  - Returns `DocumentHtmlResponseDto` (see contracts).
  - `200` with HTML when auto-tag has completed and HTML is available.
  - `202` when auto-tag is pending or not yet triggered (body has `conversionStatus` but no `html`).
  - `404` for document not found / not linked to project.
  - `502` if auto-tag failed.

#### Step 1.7: Add DTO

- **File:** `rohan_api-parent/rohan_api/src/compliance/dto/document-html-response.dto.ts` (new)
- **What:** Response DTO matching the `DocumentHtmlResponse` contract with `conversionStatus` field. Include `@ApiProperty` decorators per project convention.

#### Step 1.8: Backend unit tests

- **Files:**
  - `rohan_api-parent/rohan_api/src/compliance/compliance.service.spec.ts` (update)
  - `rohan_api-parent/rohan_api/src/compliance/listeners/compliance.listener.spec.ts` (update)
- **What:** Test service method (complete, pending, failed paths), auto-tag listener `convertedHtmlUrl` persistence, `charOffsetToLinenum()` mapping (if implementing write-time mapping).

---

### Phase 2: Frontend — API Integration & State `[FRONTEND]`

> **Goal:** Wire the frontend to fetch document HTML and manage content state.

#### Step 2.1: Add `getDocumentHtml` to `ComplianceApiService`

- **File:** `rohan_ui-parent/rohan_ui/src/app/pages/compliance/services/compliance-api.service.ts`
- **What:** New method calling `GET .../documents/:documentId/html`. Returns `Observable<DocumentHtmlResponse>`.

#### Step 2.2: Add `DocumentHtmlResponse` type

- **File:** `rohan_ui-parent/rohan_ui/src/app/pages/compliance/types/compliance-item.types.ts`
- **What:** Add `DocumentHtmlResponse` interface.

#### Step 2.3: Update `ComplianceStateService` for lazy HTML loading with conversion status

- **File:** `rohan_ui-parent/rohan_ui/src/app/pages/compliance/services/compliance-state.service.ts`
- **What:**
  - Add a map/cache for loaded HTML content: `Map<documentId, string>`.
  - Add signals: `_isDocumentHtmlLoading`, `_documentHtmlError`, `_documentConversionStatus`.
  - Add `loadDocumentHtml(projectId, documentId)` method: fetches HTML, handles conversion status:
    - `200` response → cache HTML, set status to `COMPLETE`.
    - `202` response → set status to `PENDING`, optionally poll for completion.
    - Error response → set status to `FAILED`.
  - Add effect: when `_selectedDocumentId` changes, auto-fetch HTML if not cached.
  - Expose `selectedDocumentHtml`, `isDocumentHtmlLoading`, `documentHtmlError`, `documentConversionStatus` as readonly signals.

#### Step 2.4: Update `compliance-document.utils.ts` to remove mock fallback

- **File:** `rohan_ui-parent/rohan_ui/src/app/pages/compliance/utils/compliance-document.utils.ts`
- **What:**
  - Remove import of `MOCK_COMPLIANCE_DOCUMENTS`.
  - Update `toViewerDocument()` to produce a `ComplianceSourceDocument` with **empty `lines` array** (lines are no longer the rendering model — HTML is).
  - Remove the `fallbackDocuments` parameter.

---

### Phase 3: Frontend — Rebuild Document Viewer Panel `[FRONTEND]`

> **Goal:** Replace line-based rendering with `data-linenum`-based HTML rendering, modeled on `HtmlRendererComponent`.

This is the largest phase. The `document-viewer-panel` component is rebuilt in place.

#### Step 3.1: Add `LineElementsCache` to compliance module

- **File:** `rohan_ui-parent/rohan_ui/src/app/pages/compliance/utils/line-elements-cache.ts` (new)
- **What:** Copy `LineElementsCache` from `rohan_ui-parent/rohan_ui/src/app/pages/proposal-writer/components/html-renderer/line-elements-cache.ts`. ~38 lines. Maps `data-linenum` values to DOM elements and positions. Future: extract to shared module.

#### Step 3.2: Switch rendering from line-based to HTML-based

- **Files:**
  - `document-viewer-panel.component.ts`
  - `document-viewer-panel.component.html`
  - `document-viewer-panel.component.scss`
- **What:**
  - **New inputs:** `htmlSource` (string), `isContentLoading` (boolean), `contentError` (string | null).
  - **Remove** line-based rendering loop (`@for line of document.lines`) and replace with:
    ```html
    <div class="document-content" #documentContent [innerHTML]="sanitizedHtml" (mouseup)="onContentMouseUp($event)"></div>
    ```
  - **Add** HTML sanitization: `DOMPurify.sanitize()` → strip unsafe tags → `bypassSecurityTrustHtml()` (from `DocShellComponent` pattern).
  - **Add** `LineElementsCache` initialization: build cache from `[data-linenum]` elements after HTML renders (via `AfterViewChecked` or `MutationObserver`).
  - **Add** loading state: show spinner/skeleton when `isContentLoading`.
  - **Add** pending conversion state: show "Document is being processed — please refresh in a moment" message when `conversionStatus = 'PENDING'`. _(Check with design team on optimal UX — polling, auto-refresh, or manual refresh.)_
  - **Add** error state: show "Document conversion failed — please re-upload the file to try again" message when `contentError` is set or `conversionStatus = 'FAILED'`.
  - **Keep** document dropdown and document switching.
  - **Remove** `PdfHighlightOverlayComponent` usage (`data-linenum` CSS highlighting replaces it).

#### Step 3.3: Adapt selection capture to `data-linenum` model

- **File:** `document-viewer-panel.component.ts`
- **What:**
  - On `mouseup`: use `window.getSelection()` to capture selection text.
  - Resolve selection start/end to `data-linenum` values:
    - Walk from `anchorNode`/`focusNode` up the DOM to the nearest `[data-linenum]` ancestor.
    - Use `findNearestLineNumber()` as fallback (borrow from `HtmlRendererComponent`).
  - Position the "Add Compliance Item" popover relative to the selection (keep existing popover UX).
  - On "Add Compliance Item" click: emit `createComplianceItem` with `{ documentId, selectionText, startLine, endLine }`.
  - **Remove** `getLineNumberFromNode()` (old line-number lookup) and line-based selection logic.

#### Step 3.4: Adapt highlighting for selected compliance item

- **File:** `document-viewer-panel.component.ts` + `.scss`
- **What:**
  - When a compliance item is selected (via left panel), highlight its corresponding `data-linenum` range in the HTML.
  - Use `LineElementsCache.getLineElement(linenum)` to find DOM elements in the item's `documentStartLine`–`documentEndLine` range.
  - Apply a CSS attribute (e.g., `data-compliance-active`) to those elements.
  - Scroll to the first highlighted element when an item is selected.
  - **Remove** `PdfHighlightOverlayComponent` and the old `filteredRegions`/`selectedRegion` computed signals.

#### Step 3.5: Update `CreateComplianceItemSelection` type

- **File:** `rohan_ui-parent/rohan_ui/src/app/pages/compliance/types/compliance-item.types.ts`
- **What:** Update `CreateComplianceItemSelection` to use `data-linenum` values:
  ```typescript
  export interface CreateComplianceItemSelection {
      documentId: string;
      selectionText: string;
      startLine: number;  // data-linenum value of first selected block (1-based)
      endLine: number;    // data-linenum value of last selected block (1-based)
  }
  ```
  Update `ComplianceStateService.addManualItem()` to map `startLine`/`endLine` to `documentStartLine`/`documentEndLine` on the API request.

#### Step 3.6: Update `highlightRegions` in `ComplianceStateService`

- **File:** `rohan_ui-parent/rohan_ui/src/app/pages/compliance/services/compliance-state.service.ts`
- **What:** The `highlightRegions` computed signal maps `item.documentStartLine`/`documentEndLine` to `startLine`/`endLine`. Since these now store `data-linenum` values (for both auto-tagged and manual items), the signal works as-is. Verify `HighlightRegion` type still fits or simplify if the line-based overlay is no longer needed.

#### Step 3.7: Update `compliance-list-creator` to pass new inputs

- **Files:**
  - `compliance-list-creator.component.ts`
  - `compliance-list-creator.component.html`
- **What:** Pass `htmlSource`, `isContentLoading`, `contentError` from state service to viewer panel. Update template bindings.

---

### Phase 4: Cleanup `[FRONTEND]`

#### Step 4.1: Remove `PdfHighlightOverlayComponent` from compliance usage

- **Files:**
  - `rohan_ui-parent/rohan_ui/src/app/pages/compliance/components/pdf-highlight-overlay/` (may keep for other usage or remove if compliance-only)
  - `rohan_ui-parent/rohan_ui/src/app/pages/compliance/compliance.module.ts` (update declarations if removing)
- **What:** Remove from compliance viewer template. If no other consumers, remove the component entirely.

#### Step 4.2: Remove mock data from production code

- **File:** `rohan_ui-parent/rohan_ui/src/app/pages/compliance/utils/compliance-document.utils.ts`
- **What:** Ensure no production code imports `MOCK_COMPLIANCE_DOCUMENTS`.

#### Step 4.3: Remove page number display

- **File:** `document-viewer-panel.component.html`
- **What:** Remove "Page X of Y" display (omitted for now).

---

### Phase 5: Tests `[TEST_REVIEW]`

#### Step 5.1: Frontend unit tests

- **Files:**
  - `document-viewer-panel.component.spec.ts`
  - `compliance-state.service.spec.ts`
  - `compliance-api.service.spec.ts`
  - `compliance-document.utils.spec.ts`
  - `line-elements-cache.spec.ts` (new)
- **What:**
  - Test HTML rendering mode (sanitization, innerHTML binding).
  - Test `data-linenum` selection capture (selection → linenum resolution).
  - Test `LineElementsCache` (cache building, element lookup, nearest-linenum fallback).
  - Test lazy HTML loading in state service (loading, success, error, caching).
  - Test "Add Compliance Item" flow with `data-linenum` values.
  - Update existing tests that depend on line-based rendering or mock documents.

#### Step 5.2: Backend unit tests

- Covered in Phase 0 (Step 0.7) and Phase 1 (Step 1.8).

#### Step 5.3: E2E smoke test (optional)

- **What:** Verify that the compliance creator shows real document content (visually faithful), text selection works, compliance items can be created from selections, and selecting an item (auto-tagged or manual) highlights the correct passage.

---

### Phase 6: Document Lifecycle — Auto-tag Chaining & Deletion Cascade

> **Goal:** Support the post-wizard document lifecycle: auto-tag new documents added from the overview page (after conversion completes), skip already-tagged documents on re-run, and cascade-delete compliance items when documents are removed. This phase is **independent of the core viewer work** (Phases 0–5) and can be scheduled separately.

#### Phase 6A: Backend `[BACKEND_DB]`

##### Step 6A.1: Trigger `requestAutoTag()` for overview-page uploads

- **File:** `rohan_api-parent/rohan_api/src/compliance/compliance.service.ts`
- **What:**
  - Add a method (or extend `uploadSourceDocument()`) that calls `requestAutoTag()` immediately after saving the document entity for overview-page uploads. This follows the standard auto-tagging integration pattern from the [integration guide](https://rohan.atlassian.net/): your feature decides when to tag, calls `TaggingService.requestAutoTag()`, and handles the completion event.
  - The wizard upload flow does NOT call `requestAutoTag()` on upload — the wizard's "Finish" button handles batch auto-tagging via `requestAutoTagging()`.
  - The overview page upload flow calls `requestAutoTag()` immediately — auto-tagging starts right after upload, with no user action needed.
  - _(How to distinguish: the controller/service layer knows the call context. Either add an `autoTag?: boolean` parameter to the upload method, or create a separate `uploadAndTag()` method for the overview page.)_
- **File:** `rohan_api-parent/rohan_api/src/compliance/compliance.controller.ts`
- **What:** Accept `autoTag` as an optional query parameter or body field on the upload endpoint. When `true`, the service calls `requestAutoTag()` after saving. Default: `false`.

##### ~~Step 6A.2: Chain auto-tagging after conversion completion~~ — REMOVED

> **Removed per PR review.** There is no separate conversion step to chain after. Overview-page uploads call `requestAutoTag()` directly (Step 6A.1). The auto-tag pipeline handles conversion + tagging as one atomic flow.

##### Step 6A.3: Update `requestAutoTagging()` to skip already-tagged documents

- **File:** `rohan_api-parent/rohan_api/src/compliance/compliance.service.ts`
- **What:** In `requestAutoTagging()`, filter the source documents list to exclude documents that already have a `taggableDocId` set (i.e., they were already sent to the tagging service in a previous run).
- **Effect:** When a user goes back to the wizard (edit mode), adds new documents, and clicks Finish again, only the new documents are auto-tagged. Previously tagged documents are skipped.
- **Edge case:** If a document's auto-tagging failed previously, `taggableDocId` may still be set (it's set when the request is made, not when results return). Consider whether to also check auto-tag processing status, or accept that re-tagging requires manual intervention.

##### Step 6A.4: Add `DELETE /compliance/projects/:projectId/documents/:documentId` endpoint

- **File:** `rohan_api-parent/rohan_api/src/compliance/compliance.controller.ts`
- **What:** New `DELETE` endpoint for removing a single document from a project:
  - Auth: JWT + compliance permission guard (same as other compliance endpoints).
  - Validates project ownership and document linkage.
  - Returns `204 No Content` on success.
  - Returns `404` if document not found or not linked to project.

##### Step 6A.5: Add `deleteSourceDocument` method to `ComplianceService`

- **File:** `rohan_api-parent/rohan_api/src/compliance/compliance.service.ts`
- **What:** New method that:
  1. Validates the document belongs to the project.
  2. Deletes the `compliance_documents` row itself (not just the join table entry). The `ON DELETE CASCADE` on `compliance_items.source_document_id` automatically removes all associated compliance items.
  3. Cleans up MinIO: deletes the source file (`minioObjectKey`) and converted HTML (`convertedHtmlKey`, if set) from the `uploads` bucket. Wrap MinIO deletions in try/catch — MinIO failures should not prevent the DB delete.
  4. Returns void (caller uses 204 No Content).
- **Current behavior vs. new:** The existing `updateProject` flow with `documentsToDelete` only removes the join table entry (`compliance_project_documents`). This new method deletes the actual `compliance_documents` row, triggering the cascade. The existing wizard deletion flow may need to be updated to use this new method, or kept separate if the wizard's "remove" is a soft-remove (reversible in the wizard session) vs. the overview page's "delete" being permanent.

##### Step 6A.6: Handle auto-tag completion for deleted documents

- **File:** `rohan_api-parent/rohan_api/src/compliance/listeners/compliance.listener.ts`
- **What:** In `handleAutoTagComplete`, before creating compliance items from segments:
  1. Check if the `ComplianceDocument` still exists (it may have been deleted while auto-tagging was in progress).
  2. If the document no longer exists, log a warning and skip item creation.
  3. This prevents FK constraint violations when the auto-tag completion event arrives for a document that was deleted during processing.

##### Step 6A.7: Backend unit tests for document lifecycle

- **Files:**
  - `rohan_api-parent/rohan_api/src/compliance/compliance.service.spec.ts` (update)
  - `rohan_api-parent/rohan_api/src/compliance/listeners/compliance.listener.spec.ts` (update)
- **What:**
  - Test `deleteSourceDocument`: DB cascade deletes items, MinIO cleanup, MinIO failure handling.
  - Test auto-tag chaining: `autoTagAfterConversion` flag triggers auto-tag after conversion.
  - Test incremental tagging: `requestAutoTagging` skips documents with `taggableDocId`.
  - Test `handleAutoTagComplete` with deleted document (graceful skip).
  - Test upload endpoint with `autoTag` parameter.

#### Phase 6B: Frontend `[FRONTEND]`

##### Step 6B.1: Add `deleteSourceDocument` to `ComplianceApiService`

- **File:** `rohan_ui-parent/rohan_ui/src/app/pages/compliance/services/compliance-api.service.ts`
- **What:** New method calling `DELETE .../documents/:documentId`. Returns `Observable<void>`.

##### Step 6B.2: Update overview page Document Library to pass `autoTag: true` on upload

- **Files:**
  - Overview page component that hosts the Document Library (likely `compliance-overview.component.ts` or equivalent)
  - `compliance-api.service.ts` (upload method)
- **What:**
  - When uploading from the overview page's Document Library, pass `autoTag=true` as a query parameter on the upload request.
  - This signals the backend to chain auto-tagging after conversion completes.
  - The wizard upload continues to omit `autoTag` (defaults to `false`).
  - May require the `app-document-upload` shared component to accept a config option or callback that appends the query parameter.

##### Step 6B.3: Wire document deletion on overview page

- **Files:**
  - Overview page component (Document Library section)
  - `compliance-api.service.ts`
- **What:**
  - Wire the delete button (red X on each document card) to call `deleteSourceDocument(projectId, documentId)`.
  - Show a confirmation dialog before deletion: "This will permanently delete the document and all associated compliance items. Continue?"
  - On success: refresh the document list.
  - On error: show error message.

##### Step 6B.4: Frontend unit tests for document lifecycle

- **Files:**
  - `compliance-api.service.spec.ts` (update)
  - Overview page component spec (update)
- **What:**
  - Test `deleteSourceDocument` API method.
  - Test overview page upload passes `autoTag=true`.
  - Test confirmation dialog on delete.

---

## Phase Order and Parallelism

### Files touched per phase

| Phase | Repo | Files touched |
|-------|------|--------------|
| **Phase 0** | `rohan-python-api` | `domains/shared/html/html_linenum.py` (already created), `handle_auto_tag_message.py` (update: `add_data_linenum` call + remove legacy extensions from `SUPPORTED_EXTENSIONS`; remove `linenum_ranges` from `DocumentResult`), `tagging_message.py` (remove `linenum_ranges` and `LinenumRange` import from `DocumentResult`), ~~`routes/compliance.py`~~ (to be removed), tests |
| **Phase 1** | `rohan_api` | `compliance-document.entity.ts`, `compliance.service.ts` (getDocumentHtml), `compliance.listener.ts` (persist `convertedHtmlUrl` + charOffsetToLinenum mapping), `compliance.controller.ts`, new DTO, migration, `*.spec.ts` |
| **Phase 2** | `rohan_ui` | `compliance-api.service.ts`, `compliance-item.types.ts`, `compliance-document.utils.ts`, `compliance-state.service.ts` |
| **Phase 3** | `rohan_ui` | New `line-elements-cache.ts`, `document-viewer-panel.component.{ts,html,scss}`, `compliance-item.types.ts`, `compliance-list-creator.component.{ts,html}`, `compliance-state.service.ts` |
| **Phase 4** | `rohan_ui` | `pdf-highlight-overlay/`, `compliance.module.ts`, `compliance-document.utils.ts`, `document-viewer-panel.component.html` |
| **Phase 5** | Both | `*.spec.ts` files |
| **Phase 6A** | `rohan_api` | `compliance.service.ts` (requestAutoTag on overview-page upload + deleteSourceDocument + incremental requestAutoTagging), `compliance.controller.ts` (autoTag param + DELETE endpoint), `compliance.listener.ts` (deleted doc guard), `*.spec.ts` |
| **Phase 6B** | `rohan_ui` | `compliance-api.service.ts` (deleteSourceDocument), overview page component (autoTag upload + delete wiring), `*.spec.ts` |

### Parallelism

**Core viewer work (Phases 0–5):**

- **Phase 0 and Phase 1 can run in parallel** — separate repos, no file conflicts. Phase 0 is now much smaller (just `add_data_linenum` + cleanup). Phase 1 no longer depends on a Python conversion endpoint.
- **Phase 2 can start in parallel with 0+1** — frontend API layer can use mocked response matching the contract.
- **Phase 3 depends on Phase 2** — needs state service changes.
- **Phase 4 depends on Phase 3** — cleanup after new rendering is working.
- **Phase 5 overlaps** — backend tests within their phases; frontend tests after Phase 3.

**Document lifecycle add-on (Phase 6):**

- **Phase 6 is fully independent of Phases 2–5.** It only depends on Phase 1 (extends the compliance service and listener). It can be done any time after Phase 1 merges.
- **Phase 6A and 6B are sequential** — 6B (frontend) depends on 6A (backend) for the `autoTag` parameter and DELETE endpoint.
- **Phase 6 can be scheduled as a separate sprint/milestone** if the core viewer work is the priority.

### Recommended sequential order

**Core viewer (deliver first):**

1. **Phase 0** (Python) — Small: `add_data_linenum` already done; remove `linenum_ranges` from `DocumentResult`, remove conversion endpoint, clean up `SUPPORTED_EXTENSIONS`.
2. **Phase 1** (NestJS) — Persist `convertedHtmlUrl` from auto-tag completion, implement charOffsetToLinenum, add GET HTML endpoint. No Python HTTP dependency.
3. **Phase 2** (Frontend API + state) — Wires up data flow.
4. **Phase 3** (Frontend viewer rebuild) — Largest phase, core change.
5. **Phase 4** (Cleanup) — After Phase 3 is verified working.
6. **Phase 5** (Tests) — Backend tests inline; frontend tests after Phase 3.

**Document lifecycle (deliver after core viewer, or in a later sprint):**

7. **Phase 6A** (NestJS) — Overview-page `requestAutoTag()` on upload, incremental tagging, delete cascade. Requires Phase 1.
8. **Phase 6B** (Frontend) — Overview page upload with autoTag, delete wiring. Requires Phase 6A.

---

## Existing Code to Borrow From

| Pattern | Source | How to reuse |
|---------|--------|-------------|
| HTML sanitization | `DocShellComponent.sanitizeHtmlSource()` | Copy: `DOMPurify.sanitize()` + strip unsafe tags + `bypassSecurityTrustHtml()` |
| Stripped tag list | `DOC_SHELL_HTML_STRIPPED_SELECTORS` in `doc-shell.constants.ts` | Reference: `'base,link,meta,script,style,title'` |
| Line element cache | `LineElementsCache` in `html-renderer/line-elements-cache.ts` | Copy: `Map<number, HTMLElement>` from `data-linenum` to DOM elements (~38 lines) |
| Nearest linenum | `HtmlRendererComponent.findNearestLineNumber()` | Copy: resolve viewport Y to closest `[data-linenum]` element |
| Selection → linenum | `HtmlRendererComponent.processSelectionAndOpenOverlay()` | Adapt: resolve anchor/focus nodes to `[data-linenum]` ancestors |
| `data-linenum` attribution | `shred_0120.py → post_process_docling_html_block_lines()` | Extract block list and numbering logic into standalone `add_data_linenum()` utility |
| Char-offset text extraction | `html_preprocessing.py → extract_text_with_mapping()` | Reference: understand offset computation for NestJS `buildLinenumMapFromHtml()` (mapping now in TypeScript) |
| Block-level CSS highlighting | `HtmlRendererComponent` SCSS (`[data-category]` backgrounds) | Adapt: use `[data-compliance-active]` + compliance-specific CSS classes |

---

## Future Work (Out of Scope)

- **Extract shared `LineElementsCache` and HTML rendering utilities** to a shared module for reuse by both `HtmlRendererComponent` and the compliance viewer.
- **Extract shared `TaggableHtmlViewerComponent`** from `HtmlRendererComponent` — make the tagging context menu pluggable, support compliance and proposal-writer flows from a common base.
- **Virtual scrolling** for very large documents.
- **Page-level navigation** (page indicators, jump to page).
- **Presigned URL endpoint** for direct file download.
- **Image optimization** — strip or lazy-load embedded base64 images from Docling HTML to reduce payload size. Documents must look like their originals, so any optimization must preserve visual fidelity.
- **Retry auto-tag for failed documents** — re-trigger `requestAutoTag()` for documents that failed processing without re-uploading. Currently, re-upload is the retry mechanism.
- **Polling / WebSocket for auto-tag completion** — frontend polls or subscribes to auto-tag completion instead of manual refresh. Consider Server-Sent Events or WebSocket notification when the pipeline finishes and HTML becomes available.
- **XLSX sheet boundary markers** — inject sheet name headers (e.g., `<h2>Sheet: Revenue</h2>`) between tables during conversion for multi-sheet XLSX files. Requires iterating `DoclingDocument.tables` instead of using Docling's flat export. Not needed for MVP — all sheets render as sequential tables and `data-linenum` numbering spans them naturally.

---

## Jira Ticket Information

### Ticket 1: Python — `data-linenum` HTML Enrichment & Pipeline Cleanup

- **Title:** `[BACKEND] Add data-linenum to auto-tag HTML output and remove compliance-specific coupling`
- **Description:** (A) Ensure `add_data_linenum()` utility is integrated into the auto-tag handler — adds `data-linenum` attributes to block elements in the converted HTML before uploading to MinIO (matching shredding pipeline's convention). Already done in current branch. (B) Remove `linenum_ranges` from `DocumentResult` and `LinenumRange` import from `tagging_message.py` — the char-offset → linenum mapping is a compliance-specific concern that belongs in NestJS, not the shared tagging pipeline. (C) Remove the `POST /compliance/convert-document` HTTP endpoint (`routes/compliance.py`) — per the auto-tagging integration guide, compliance uses `TaggingService.requestAutoTag()` → queue → completion event flow, not a dedicated synchronous endpoint. (D) Remove legacy extensions (`.doc`, `.xls`, `.ppt`) from `SUPPORTED_EXTENSIONS` in auto-tag handler (already done). (E) Unit tests for `add_data_linenum()`.
- **Acceptance Criteria:**
  - `add_data_linenum()` adds 1-based `data-linenum` to `p, h1-h6, li, table, tr` elements.
  - Auto-tag handler uploads HTML with `data-linenum` attributes.
  - `linenum_ranges` field removed from `DocumentResult`.
  - `POST /compliance/convert-document` endpoint removed.
  - `SUPPORTED_EXTENSIONS` in auto-tag handler only contains `.pdf`, `.docx`, `.pptx`, `.xlsx`.
  - Existing auto-tag tests still pass.
  - `add_data_linenum()` unit tests pass.
- **Story Points:** 3
- **PR Scope:** `rohan-python-api` only.

### Ticket 2: NestJS — Persist Auto-Tag HTML + Document HTML Endpoint + Schema Update

- **Title:** `[BACKEND] Persist convertedHtmlUrl from auto-tag, add GET .../documents/:id/html endpoint, implement linenum mapping`
- **Description:** (A) Add `converted_html_key` column to `compliance_documents` table (migration). (B) Update compliance listener's `handleAutoTagComplete` to persist `event.convertedHtmlUrl` as `convertedHtmlKey` on the `ComplianceDocument` — fixing the existing gap where this value is available but discarded. (C) Implement char-offset → linenum mapping in TypeScript within the compliance module: download the line-numbered HTML from MinIO, parse `[data-linenum]` elements, build the mapping, and convert segment `start_offset`/`end_offset` to `data-linenum` values for `documentStartLine`/`documentEndLine`. (D) Add `GET /compliance/projects/:projectId/documents/:documentId/html` endpoint — returns HTML (200) when auto-tag has completed and HTML is available, 202 when pending, 502 when failed.
- **Acceptance Criteria:**
  - New column + migration for `converted_html_key`.
  - Compliance listener persists `convertedHtmlUrl` from auto-tag completion events.
  - Compliance items created from auto-tag use `data-linenum` values (not character offsets) for `documentStartLine`/`documentEndLine`, with the mapping computed in TypeScript.
  - GET endpoint returns appropriate status (200/202/502) based on `convertedHtmlKey` + document processing status.
  - 404 for unknown/unlinked documents.
  - Unit tests pass (including `charOffsetToLinenum()` mapping tests).
- **Story Points:** 8
- **PR Scope:** `rohan_api` only.

### Ticket 3: Frontend — API Integration & State Management

- **Title:** `[FRONTEND] Wire compliance document viewer to document HTML API`
- **Description:** Add `getDocumentHtml()` to `ComplianceApiService`. Update `ComplianceStateService` to lazy-load document HTML when the user selects a document. Cache loaded HTML per document. Expose loading/error signals. Remove mock data fallback from `compliance-document.utils.ts`.
- **Acceptance Criteria:**
  - Selecting a document triggers API call to fetch HTML.
  - HTML is cached per document in state service.
  - Loading and error signals exposed.
  - Mock data no longer used in production code.
- **Story Points:** 5
- **PR Scope:** `rohan_ui` only.

### Ticket 4: Frontend — Document Viewer HTML Rendering + Selection

- **Title:** `[FRONTEND] Rebuild document viewer panel with data-linenum rendering and selection`
- **Description:** Replace the line-based rendering in `document-viewer-panel` with HTML rendering via `innerHTML`, using server-generated `data-linenum` attributes for selection mapping (modeled on `HtmlRendererComponent`). Key changes: (1) render Docling HTML via `innerHTML` with DOMPurify sanitization, (2) build `LineElementsCache` from `[data-linenum]` elements for efficient lookups, (3) adapt text selection to resolve to `data-linenum` values via DOM traversal, (4) keep "Add Compliance Item" popover UX, (5) highlight compliance items (both auto-tagged and manual) by applying CSS to elements in the `data-linenum` range, (6) add loading/error states, (7) remove line-based rendering and `PdfHighlightOverlayComponent`.
- **Acceptance Criteria:**
  - Document renders with original layout preserved (Docling HTML).
  - Text selection → "Add Compliance Item" popover works using `data-linenum` mapping.
  - Selected compliance item (auto-tagged or manual) highlights the correct passage.
  - Clicking a compliance item scrolls to the highlighted passage.
  - Loading spinner shown during HTML fetch.
  - Error state shown on fetch failure.
  - Document dropdown switching works.
  - PDF, DOCX, XLSX all render correctly.
- **Story Points:** 8
- **PR Scope:** `rohan_ui` only.

### Ticket 5: Tests & Cleanup

- **Title:** `[TEST] Unit tests and cleanup for data-linenum-based document viewer`
- **Description:** Write/update frontend unit tests for HTML rendering, `data-linenum` selection mapping, `LineElementsCache`, state service caching, and API method. Remove `PdfHighlightOverlayComponent` from compliance templates. Remove mock data imports from production code. Remove page number display.
- **Acceptance Criteria:**
  - All new code has unit test coverage.
  - No production code imports mock document data.
  - `PdfHighlightOverlayComponent` removed from compliance viewer.
  - Existing tests updated and passing.
- **Story Points:** 3
- **PR Scope:** `rohan_ui` only.

---

### Document Lifecycle Tickets (Phase 6 — can be scheduled independently)

### Ticket 6: NestJS — Document Lifecycle (Auto-tag on Upload & Deletion Cascade)

- **Title:** `[BACKEND] requestAutoTag on overview-page upload, incremental tagging, and document deletion with cascade`
- **Description:** (A) Add `autoTag` parameter to the source document upload endpoint. When true, the service calls `TaggingService.requestAutoTag()` immediately after saving the document entity (for overview-page uploads, following the standard auto-tagging integration pattern). When false/omitted, the wizard's "Finish" button handles batch auto-tagging (existing behavior). (B) Update `requestAutoTagging()` to skip documents that already have a `taggableDocId` — only new documents are tagged on subsequent Finish clicks. (C) Add `DELETE /compliance/projects/:projectId/documents/:documentId` endpoint — deletes the `compliance_documents` row (DB cascade removes associated `compliance_items`), cleans up MinIO files (source + converted HTML). (D) Guard `handleAutoTagComplete` against deleted documents — check if the document still exists before creating items. Includes unit tests.
- **Acceptance Criteria:**
  - Upload with `autoTag=true` calls `requestAutoTag()` immediately after saving.
  - Upload with `autoTag=false` (or omitted) does NOT auto-tag — deferred to batch trigger.
  - `requestAutoTagging()` only processes documents without `taggableDocId`.
  - DELETE endpoint removes `compliance_documents` row and cascades to `compliance_items`.
  - DELETE endpoint cleans up MinIO files (source + converted HTML).
  - MinIO cleanup failure does not block DB delete.
  - `handleAutoTagComplete` gracefully handles deleted documents.
  - 204 No Content on successful delete, 404 for unknown/unlinked documents.
  - Unit tests pass.
- **Story Points:** 5
- **PR Scope:** `rohan_api` only. Depends on Ticket 2 (Phase 1).

### Ticket 7: Frontend — Overview Page Document Lifecycle

- **Title:** `[FRONTEND] Wire overview page document upload with auto-tag and deletion with cascade`
- **Description:** Add `deleteSourceDocument()` to `ComplianceApiService`. Wire overview page Document Library: uploads pass `autoTag=true` so auto-tagging chains after conversion, delete button calls the delete endpoint with a confirmation dialog warning that compliance items will be removed.
- **Acceptance Criteria:**
  - Overview page upload passes `autoTag=true`.
  - Overview page delete button shows confirmation dialog and calls delete endpoint.
  - Document list refreshes after delete.
  - Unit tests for new API method and overview page interactions.
- **Story Points:** 3
- **PR Scope:** `rohan_ui` only. Depends on Ticket 6 (Phase 6A).
