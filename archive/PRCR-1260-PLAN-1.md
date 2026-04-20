# PRCR-1260: Compliance Document Viewer — Real Document Content

## Problem Statement

The **Document Viewer Panel** in the Compliance List Creation workflow (`document-viewer-panel.component`) currently displays **mock/hardcoded text lines** instead of the actual content of uploaded documents. The `mapProjectDocumentsToViewerDocuments()` utility in `compliance-document.utils.ts` maps project documents onto `MOCK_COMPLIANCE_DOCUMENTS` line data (with a TODO to replace it).

Users need to:
1. View the **real content** of each uploaded source document in the right-hand panel, with layout that **matches the look of the original document**.
2. **Highlight text** within the rendered document and create compliance items (tagging) from the selection — even when auto-tagging has not been run.
3. Switch between multiple documents via the existing dropdown.

The viewer must support **PDF, DOCX, and XLSX** files. Docling already converts all three formats to HTML uniformly, so one rendering path handles all file types.

---

## Current State Summary

| Layer | What exists | Gap |
|-------|------------|-----|
| **Frontend — `document-viewer-panel`** | Line-based rendering (`@for line of document.lines`), text selection maps to line numbers, "Add Compliance Item" popover. | Uses mock data. Line-based rendering does not preserve original document layout. |
| **Frontend — `DocShellComponent`** (shared) | Renders Docling HTML via `innerHTML`, block-based selection capture (block indices + char offsets), highlights via CSS. Tag-type context menu via `TaggingService`. Used by Template Generator's Tag Step. | Context menu is tied to template-generator tag config. Not used by compliance. |
| **Frontend — `HtmlRendererComponent`** (proposal-writer) | Similar HTML rendering, uses `data-linenum` for selection mapping, tagging context menu. Used by Create Proposal Wizard. | Module-scoped to proposal-writer. Not shared. |
| **Backend (NestJS) — compliance controller** | Upload, auto-tag endpoints. `ComplianceDocument` entity has `minioObjectKey`, `mimeType`, `taggable_doc_id`. | No endpoint to serve converted HTML. |
| **Backend (NestJS) — compliance listener** | `handleAutoTagComplete` creates compliance items. Event carries `convertedHtmlUrl` but **compliance listener does not persist it** (template-documents listener does). | Converted HTML URL from auto-tag pipeline is lost. |
| **Backend (Python) — auto-tag handler** | Docling converts PDF/DOCX/XLSX → HTML. Uploads converted HTML to MinIO. Returns `converted_html_url` in `DocumentResult`. | Conversion is coupled with tagging pipeline (no standalone endpoint). |

---

## Proposed Approach

### Render Docling HTML via `innerHTML` (like DocShell / HtmlRenderer)

Rather than extracting text lines from the Docling HTML, we serve the **raw Docling HTML** to the frontend and render it via `innerHTML`. This preserves the original document's visual layout (fonts, tables, lists, formatting) exactly as Docling rendered it.

This is the same approach used by:
- **`DocShellComponent`** in Template Generator Tag Step
- **`HtmlRendererComponent`** in Proposal Writer Create Wizard

### Architecture

```
User selects document in viewer
  → Frontend: GET /compliance/projects/:pid/documents/:did/html
  → NestJS: Check if converted HTML exists for this document
    → YES: Read from MinIO, return HTML string
    → NO:  Call Python conversion endpoint → store in MinIO → return HTML
  → Frontend: Sanitize + render via innerHTML
  → User selects text → "Add Compliance Item" popover → compliance item created
```

### Reuse strategy: Borrow from `DocShellComponent`, don't couple to it

**Why not use `DocShellComponent` directly:**
- Its context menu is hard-wired to `TaggingService.templateGeneratorConfig()` (tag type selection with categories like Instructions, Structure, Evaluation, Requirements).
- Compliance needs a different flow: select text → "Add Compliance Item" button → create item. No tag-type menu.
- Its tag layer (positioned tag chips alongside content) is not the compliance UX — compliance shows items in a separate left panel.
- Coupling compliance to the template-generator's `TaggingService` would create an unwanted dependency.

**What to borrow from `DocShellComponent`:**
- HTML sanitization pattern: `DOMPurify.sanitize()` → strip unsafe tags → `bypassSecurityTrustHtml()`.
- Block element collection: `TAGGABLE_BLOCK_SELECTOR` (`h1,h2,h3,h4,h5,h6,p,li,tr,td,span`).
- Selection capture: `mouseup` → `window.getSelection()` → resolve block range + character offsets.
- Block-level highlighting: set data attributes and CSS on block elements.

**What to keep from current compliance viewer:**
- Document selector dropdown.
- "Add Compliance Item" popover on text selection.
- Compliance item list in left panel (separate component).
- Integration with `ComplianceStateService`.

### Selection-to-compliance-item mapping

The current compliance items store `documentStartLine` / `documentEndLine`. In the HTML-based approach, these will represent **block indices** (0-based sequential index of block elements in the Docling HTML, matching `DocShellComponent`'s `blockStart`/`blockEnd`). This is consistent with how the existing auto-tag completion handler sets these values from `DocumentSegment.start_offset`/`end_offset`.

### On-demand conversion

Auto-tagging is optional. When a document hasn't been processed yet, the backend triggers Docling conversion synchronously (NestJS → Python) on the first content request, stores the result in MinIO, and serves it. Subsequent requests serve the cached HTML.

---

## Assumptions

1. `MinioService` is available (or can be injected) in the compliance module.
2. Docling conversion runs synchronously within a reasonable time (< 30s) for typical documents.
3. The Docling HTML output preserves the visual layout of the original document well enough for compliance review purposes.
4. The `TAGGABLE_BLOCK_SELECTOR` constant covers the block elements that Docling produces.
5. `documentStartLine` / `documentEndLine` on compliance items will be repurposed to store block indices (0-based) in the HTML.

---

## Open Questions

1. **Block index vs. existing offset semantics.** The auto-tag completion handler sets `documentStartLine`/`documentEndLine` from `DocumentSegment.start_offset`/`end_offset`. Are these character offsets or block indices? This determines whether existing auto-tagged items will align with the block-based highlighting. Needs investigation during Phase 1.
2. **Docling HTML `data-linenum` attributes.** The shredding pipeline (`shred_0120.py`) post-processes Docling HTML to add `data-linenum` on blocks. The auto-tag handler does NOT do this. Should we add the same post-processing for compliance? If so, we can use `data-linenum` for selection mapping (like proposal-writer's `HtmlRendererComponent`).
3. **Conversion timeout.** What should the timeout be for the on-demand Python conversion call?
4. **Max document size.** Large documents may be slow to render via `innerHTML`. Should we consider virtual scrolling or pagination?
5. **For XLSX files, how does Docling render sheets?** Tables become HTML `<table>` elements — need to confirm multi-sheet handling.
6. **Fallback for already-processed documents.** Documents auto-tagged before the `convertedHtmlKey` column is added won't have a stored path. Derive from MinIO key convention (`{parent}/output/{stem}.html`) or backfill via migration?
7. **Should `DocShellComponent` be refactored to extract a reusable base?** Longer-term, both doc-shell and the compliance viewer share the same rendering + selection pattern. A shared base component or utility could reduce duplication. This is out of scope for PRCR-1260 but worth noting for future work.

---

## Implementation Plan

### Phase 0: Python — Document Conversion Endpoint `[BACKEND_DB]`

> **Goal:** Expose a standalone Docling conversion endpoint for on-demand document conversion when auto-tagging hasn't run.

#### Step 0.1: Add conversion endpoint to Python API

- **File:** `rohan-python-api/backend/app/api/routes/compliance.py` (new)
- **What:** `POST /compliance/convert-document`
  - Input: `{ "storage_type": "minio", "object_key": "...", "output_key": "..." }`
  - Downloads from MinIO, converts to HTML via `convert_document_to_html`, strips metadata via `strip_html_metadata`, uploads converted HTML to MinIO.
  - Returns `{ "success": true, "html_key": "..." }`.
  - Reuses existing Docling utilities from `app.domains.shared.docling.docling_factory`.
  - Auth: Service-to-service (same as other NestJS → Python calls).

#### Step 0.2: Unit tests

- **File:** `rohan-python-api/backend/app/tests/api/routes/test_compliance.py` (new)
- **What:** Test conversion with mocked MinIO and Docling.

---

### Phase 1: Backend — Document HTML Endpoint `[BACKEND_DB]`

> **Goal:** NestJS endpoint that returns the Docling-converted HTML for a compliance document.

#### Step 1.1: Add `convertedHtmlKey` column + migration

- **Files:**
  - `rohan_api-parent/rohan_api/src/compliance/entities/compliance-document.entity.ts`
  - New TypeORM migration
- **What:** Add nullable `converted_html_key` (`varchar(500)`) to `compliance_documents`.

#### Step 1.2: Update compliance listener to persist `convertedHtmlUrl`

- **File:** `rohan_api-parent/rohan_api/src/compliance/listeners/compliance.listener.ts`
- **What:** In `handleAutoTagComplete`, persist `event.convertedHtmlUrl` on the `ComplianceDocument`. Update `markDocumentReady` in `compliance.service.ts` to accept and store the key.

#### Step 1.3: Add `getDocumentHtml` method to `ComplianceService`

- **File:** `rohan_api-parent/rohan_api/src/compliance/compliance.service.ts`
- **What:** New method that:
  1. Looks up `ComplianceDocument` by ID + validates project ownership.
  2. If `convertedHtmlKey` exists: reads HTML from MinIO via `MinioService.getObjectBuffer()`.
  3. If null: calls the Python conversion endpoint (Phase 0), stores result key on entity.
  4. Returns `{ documentId, documentName, mimeType, html }`.

#### Step 1.4: Add controller endpoint

- **File:** `rohan_api-parent/rohan_api/src/compliance/compliance.controller.ts`
- **What:** `GET /compliance/projects/:projectId/documents/:documentId/html`
  - Auth: JWT + compliance permission guard.
  - Returns `DocumentHtmlResponseDto` (see contracts).
  - 404 for document not found / not linked to project.
  - 502 if conversion fails.

#### Step 1.5: Add DTO

- **File:** `rohan_api-parent/rohan_api/src/compliance/dto/document-html-response.dto.ts` (new)
- **What:** Response DTO matching the `DocumentHtmlResponse` contract.

#### Step 1.6: Backend unit tests

- **Files:**
  - `rohan_api-parent/rohan_api/src/compliance/compliance.service.spec.ts` (update)
  - `rohan_api-parent/rohan_api/src/compliance/listeners/compliance.listener.spec.ts` (update)
- **What:** Test service method (cached + on-demand paths), listener `convertedHtmlUrl` persistence.

---

### Phase 2: Frontend — API Integration & State `[FRONTEND]`

> **Goal:** Wire the frontend to fetch document HTML and manage content state.

#### Step 2.1: Add `getDocumentHtml` to `ComplianceApiService`

- **File:** `rohan_ui-parent/rohan_ui/src/app/pages/compliance/services/compliance-api.service.ts`
- **What:** New method calling `GET .../documents/:documentId/html`. Returns `Observable<DocumentHtmlResponse>`.

#### Step 2.2: Add `DocumentHtmlResponse` type

- **File:** `rohan_ui-parent/rohan_ui/src/app/pages/compliance/types/compliance-item.types.ts`
- **What:** Add `DocumentHtmlResponse` interface.

#### Step 2.3: Update `ComplianceStateService` for lazy HTML loading

- **File:** `rohan_ui-parent/rohan_ui/src/app/pages/compliance/services/compliance-state.service.ts`
- **What:**
  - Add a map/cache for loaded HTML content: `Map<documentId, string>`.
  - Add signals: `_isDocumentHtmlLoading`, `_documentHtmlError`.
  - Add `loadDocumentHtml(projectId, documentId)` method: fetches HTML, caches it, updates signals.
  - Add effect: when `_selectedDocumentId` changes, auto-fetch HTML if not cached.
  - Expose `selectedDocumentHtml`, `isDocumentHtmlLoading`, `documentHtmlError` as readonly signals.

#### Step 2.4: Update `compliance-document.utils.ts` to remove mock fallback

- **File:** `rohan_ui-parent/rohan_ui/src/app/pages/compliance/utils/compliance-document.utils.ts`
- **What:**
  - Remove import of `MOCK_COMPLIANCE_DOCUMENTS`.
  - Update `toViewerDocument()` to produce a `ComplianceSourceDocument` with **empty `lines` array** (lines are no longer the rendering model — HTML is).
  - Remove the `fallbackDocuments` parameter.

---

### Phase 3: Frontend — Rebuild Document Viewer Panel `[FRONTEND]`

> **Goal:** Replace line-based rendering with HTML rendering, borrowing patterns from `DocShellComponent`.

This is the largest phase. The `document-viewer-panel` component is modified in place.

#### Step 3.1: Switch rendering from line-based to HTML-based

- **Files:**
  - `rohan_ui-parent/rohan_ui/src/app/pages/compliance/components/document-viewer-panel/document-viewer-panel.component.ts`
  - `rohan_ui-parent/rohan_ui/src/app/pages/compliance/components/document-viewer-panel/document-viewer-panel.component.html`
  - `rohan_ui-parent/rohan_ui/src/app/pages/compliance/components/document-viewer-panel/document-viewer-panel.component.scss`
- **What:**
  - **New inputs:** `htmlSource` (string), `isContentLoading` (boolean), `contentError` (string | null).
  - **Remove** line-related inputs: `documents` stays (for dropdown), but the line-based rendering loop (`@for line of document.lines`) is replaced with:
    ```html
    <div class="document-content" #documentContent [innerHTML]="sanitizedHtml" (mouseup)="onContentMouseUp($event)"></div>
    ```
  - **Add** HTML sanitization: `DOMPurify.sanitize()` → `bypassSecurityTrustHtml()` (same pattern as `DocShellComponent`).
  - **Add** loading state: show spinner/skeleton when `isContentLoading`.
  - **Add** error state: show error message when `contentError` is set.
  - **Keep** document dropdown and document switching.
  - **Remove** `PdfHighlightOverlayComponent` usage (block-level CSS replaces it).

#### Step 3.2: Adapt selection capture to block-based model

- **File:** `document-viewer-panel.component.ts`
- **What:**
  - On `mouseup`: use `window.getSelection()` to capture selection text.
  - Resolve selection to **block range** using `TAGGABLE_BLOCK_SELECTOR` (borrow from `DocShellComponent.getSelectionBlockRange()`).
  - Position the "Add Compliance Item" popover relative to the selection (keep existing popover UX).
  - On "Add Compliance Item" click: emit `createComplianceItem` with `{ documentId, selectionText, startBlock, endBlock }`.
  - **Remove** `getLineNumberFromNode()` and line-based selection logic.
  - **Add** `collectBlockElements()`, `resolveClosestBlockElement()` (borrow from DocShell).

#### Step 3.3: Adapt highlighting for selected compliance item

- **File:** `document-viewer-panel.component.ts` + `.scss`
- **What:**
  - When a compliance item is selected (via left panel), highlight its corresponding block range in the HTML.
  - Apply a CSS class (e.g., `compliance-hl-active`) to blocks within the item's `documentStartLine`–`documentEndLine` range.
  - Use `data-compliance-item-id` attribute on blocks for tracking.
  - Scroll to the first highlighted block when an item is selected.
  - **Remove** `PdfHighlightOverlayComponent` and the old `filteredRegions`/`selectedRegion` computed signals.

#### Step 3.4: Update `CreateComplianceItemSelection` type

- **File:** `rohan_ui-parent/rohan_ui/src/app/pages/compliance/types/compliance-item.types.ts`
- **What:** Update `CreateComplianceItemSelection` to use block indices:
  ```typescript
  export interface CreateComplianceItemSelection {
      documentId: string;
      selectionText: string;
      startBlock: number;  // renamed from startLine
      endBlock: number;    // renamed from endLine
  }
  ```
  Update `ComplianceStateService.addManualItem()` to map `startBlock`/`endBlock` to `documentStartLine`/`documentEndLine` on the API request.

#### Step 3.5: Update `compliance-list-creator` to pass new inputs

- **Files:**
  - `rohan_ui-parent/rohan_ui/src/app/pages/compliance/components/compliance-list-creator/compliance-list-creator.component.ts`
  - `rohan_ui-parent/rohan_ui/src/app/pages/compliance/components/compliance-list-creator/compliance-list-creator.component.html`
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
- **What:**
  - Test HTML rendering mode (sanitization, innerHTML binding).
  - Test block-based selection capture.
  - Test lazy HTML loading in state service (loading, success, error, caching).
  - Test "Add Compliance Item" flow with block indices.
  - Update existing tests that depend on line-based rendering or mock documents.

#### Step 5.2: Backend unit tests

- Covered in Phase 0 (Step 0.2) and Phase 1 (Step 1.6).

#### Step 5.3: E2E smoke test (optional)

- **What:** Verify that the compliance creator shows real document content (visually faithful), text selection works, and compliance items can be created from selections.

---

## Phase Order and Parallelism

### Files touched per phase

| Phase | Repo | Files touched |
|-------|------|--------------|
| **Phase 0** | `rohan-python-api` | New `routes/compliance.py`, new test |
| **Phase 1** | `rohan_api` | `compliance-document.entity.ts`, `compliance.listener.ts`, `compliance.service.ts`, `compliance.controller.ts`, new DTO, migration, `*.spec.ts` |
| **Phase 2** | `rohan_ui` | `compliance-api.service.ts`, `compliance-item.types.ts`, `compliance-document.utils.ts`, `compliance-state.service.ts` |
| **Phase 3** | `rohan_ui` | `document-viewer-panel.component.{ts,html,scss}`, `compliance-item.types.ts`, `compliance-list-creator.component.{ts,html}` |
| **Phase 4** | `rohan_ui` | `pdf-highlight-overlay/`, `compliance.module.ts`, `compliance-document.utils.ts`, `document-viewer-panel.component.html` |
| **Phase 5** | Both | `*.spec.ts` files |

### Parallelism

- **Phase 0 and Phase 1 can run in parallel** — separate repos, no file conflicts.
- **Phase 2 can start in parallel with 0+1** — frontend API layer can use mocked response matching the contract.
- **Phase 3 depends on Phase 2** — needs state service changes.
- **Phase 4 depends on Phase 3** — cleanup after new rendering is working.
- **Phase 5 overlaps** — backend tests within their phases; frontend tests after Phase 3.

### Recommended sequential order

1. **Phase 0** (Python) — Unblocks on-demand conversion.
2. **Phase 1** (NestJS) — Unblocks frontend work. Can stub Python call initially.
3. **Phase 2** (Frontend API + state) — Wires up data flow.
4. **Phase 3** (Frontend viewer rebuild) — Largest phase, core change.
5. **Phase 4** (Cleanup) — After Phase 3 is verified working.
6. **Phase 5** (Tests) — Backend tests inline; frontend tests after Phase 3.

---

## Existing Code to Borrow From

| Pattern | Source | How to reuse |
|---------|--------|-------------|
| HTML sanitization | `DocShellComponent.sanitizeHtmlSource()` | Copy: `DOMPurify.sanitize()` + strip unsafe tags + `bypassSecurityTrustHtml()` |
| Block element collection | `DocShellComponent.collectBlockElements()` | Copy: `querySelectorAll(TAGGABLE_BLOCK_SELECTOR)` |
| Block range resolution | `DocShellComponent.getSelectionBlockRange()` | Copy: resolve selection start/end to nearest block element indices |
| Closest block element | `DocShellComponent.resolveClosestBlockElement()` | Copy: walk up DOM to find matching block |
| Selection containment check | `DocShellComponent.isSelectionInsideContent()` | Copy: verify selection is inside content div |
| Block-level CSS highlighting | `DocShellComponent` SCSS (`.hl-active`, `data-tag-id`) | Adapt: use `data-compliance-item-id` + compliance-specific CSS classes |
| Constants | `TAGGABLE_BLOCK_SELECTOR`, `DOC_SHELL_HTML_STRIPPED_SELECTORS` | Import from `@shared-services/tagging/constants/tagging-ui.constants` |

---

## Future Work (Out of Scope)

- **Extract shared `HtmlDocumentRenderer` component** from `DocShellComponent` for reuse by both template-generator and compliance (avoids code duplication long-term).
- **Virtual scrolling** for very large documents.
- **Page-level navigation** (page indicators, jump to page).
- **Presigned URL endpoint** for direct file download.
- **Character-offset-based highlighting** for precise inline highlighting (like DocShell's inline tags).

---

## Jira Ticket Information

### Ticket 1: Python — Document Conversion Endpoint

- **Title:** `[BACKEND] Add standalone Docling conversion endpoint for compliance documents`
- **Description:** Add `POST /compliance/convert-document` to the Python FastAPI backend. Downloads a document from MinIO, converts to HTML using Docling, uploads the result back to MinIO. Supports PDF, DOCX, XLSX. Enables on-demand conversion for the compliance viewer when auto-tagging has not been run. Includes unit tests with mocked MinIO/Docling.
- **Acceptance Criteria:**
  - Endpoint accepts MinIO object key and returns converted HTML key.
  - Supports PDF, DOCX, XLSX.
  - Converted HTML stored in MinIO for caching.
  - Unit tests pass.
- **Story Points:** 3
- **PR Scope:** `rohan-python-api` only.

### Ticket 2: NestJS — Document HTML Endpoint + Schema Update

- **Title:** `[BACKEND] Add GET .../documents/:id/html endpoint with convertedHtmlKey persistence`
- **Description:** (A) Add `converted_html_key` column to `compliance_documents` table (migration). (B) Update compliance listener to persist `convertedHtmlUrl` from auto-tag completion events — fixing the existing gap where this value is available but discarded. (C) Add `GET /compliance/projects/:projectId/documents/:documentId/html` endpoint that returns the Docling-converted HTML. If the converted HTML exists in MinIO, serve it; if not, call the Python conversion endpoint on demand, store the result, and serve it.
- **Acceptance Criteria:**
  - New column + migration for `converted_html_key`.
  - Compliance listener persists `convertedHtmlUrl`.
  - Endpoint returns HTML string with document metadata.
  - On-demand conversion works for unprocessed documents.
  - 404 for unknown/unlinked documents.
  - Unit tests pass.
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

- **Title:** `[FRONTEND] Rebuild document viewer panel with Docling HTML rendering and block-based tagging`
- **Description:** Replace the line-based rendering in `document-viewer-panel` with HTML rendering via `innerHTML`, borrowing patterns from the shared `DocShellComponent`. Key changes: (1) render Docling HTML via `innerHTML` with DOMPurify sanitization, (2) adapt text selection to use block-based mapping (block indices via `TAGGABLE_BLOCK_SELECTOR`), (3) keep "Add Compliance Item" popover UX, (4) adapt compliance item highlighting to use block-level CSS, (5) add loading/error states, (6) remove line-based rendering and `PdfHighlightOverlayComponent`. The document preserves the visual layout of the original uploaded file.
- **Acceptance Criteria:**
  - Document renders with original layout preserved (Docling HTML).
  - Text selection → "Add Compliance Item" popover works.
  - Selected compliance item highlights the corresponding blocks.
  - Loading spinner shown during HTML fetch.
  - Error state shown on fetch failure.
  - Document dropdown switching works.
  - PDF, DOCX, XLSX all render correctly.
- **Story Points:** 8
- **PR Scope:** `rohan_ui` only.

### Ticket 5: Tests & Cleanup

- **Title:** `[TEST] Unit tests and cleanup for HTML-based document viewer`
- **Description:** Write/update frontend unit tests for HTML rendering, block-based selection, state service caching, and API method. Remove `PdfHighlightOverlayComponent` from compliance templates. Remove mock data imports from production code. Remove page number display.
- **Acceptance Criteria:**
  - All new code has unit test coverage.
  - No production code imports mock document data.
  - `PdfHighlightOverlayComponent` removed from compliance viewer.
  - Existing tests updated and passing.
- **Story Points:** 3
- **PR Scope:** `rohan_ui` only.
