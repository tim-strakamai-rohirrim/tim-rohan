# PRCR-1260 (Viewer): Document Rendering, Serving & Lifecycle — Non-Tagging Work

> **Companion to:** `PRCR-1260-PLAN.md` (full feature plan)
> **Created:** 2026-03-25
> **Context:** The "tagging" portion of PRCR-1260 (text highlighting in UI, selection → compliance item creation, auto-tag result visualization) is being handled by the in-progress **tagging redesign** (`tagging-redesign` branches in `rohan_api` and `rohan_ui`, `fix/block-aware-text-extraction` in `rohan-python-api`). This plan covers **the rest of the feature** — document HTML serving, rendering, state management, and document lifecycle — and identifies what can be done in parallel while waiting for the tagging work.

---

## Problem Statement

The Document Viewer Panel currently displays **mock text lines** instead of real document content. Even without text selection / tagging / highlighting, the viewer needs to:
1. **Show the actual content** of uploaded documents (PDF, DOCX, XLSX) rendered from Docling HTML.
2. **Handle loading, pending, and error states** for document conversion.
3. **Support adding and deleting documents** from the overview page with proper lifecycle management.

These capabilities are independent of the tagging infrastructure and can be built now.

---

## What the Tagging Redesign Changes (and Why It Matters)

The coworkers' `tagging-redesign` branches introduce:

| Repo | Branch | Key Changes Affecting Compliance |
|------|--------|----------------------------------|
| `rohan_api` | `tagging-redesign` | `DocumentSegment` → `DocumentTag`; compliance listener uses `DocumentTag` rows; `BlobStorageService` replaces direct `MinioService` for uploads; claim-check payload support in `AutoTagCompleteHandler` |
| `rohan_ui` | `tagging-redesign` | Error handling improvements in `ComplianceApiService` + `ComplianceStateService`; minor `@HostListener` → `host` change in viewer panel; compliance response features |
| `rohan-python-api` | `fix/block-aware-text-extraction` | Block-aware text extraction fixes to match UI offset algorithm |

### File conflict analysis

| File | Tagging Redesign Changes | PRCR-1260 Viewer Changes | Conflict Risk |
|------|-------------------------|--------------------------|---------------|
| `document-viewer-panel.component.{ts,html,scss}` | Trivial: `@HostListener` → `host` binding (5 lines) | **Major rewrite**: HTML rendering | **Low** — rewrite replaces the whole file |
| `compliance-document.utils.ts` | Not touched | Remove mock fallback | **None** |
| `compliance-item.types.ts` | Not touched significantly | Add `DocumentHtmlResponse` type | **None** |
| `compliance-api.service.ts` | Error handling, toast, new response methods (~100 lines added) | Add `getDocumentHtml()`, `deleteSourceDocument()` | **Low** — additive methods in different sections |
| `compliance-state.service.ts` | 409 handling, expose `project` signal (~40 lines) | Add HTML loading/caching signals + methods | **Low** — additive in different sections |
| `compliance.listener.ts` (NestJS) | **Rewritten**: `DocumentTag` instead of `DocumentSegment` | Persist `convertedHtmlUrl` | **Medium** — must apply against redesigned listener |
| `compliance.service.ts` (NestJS) | `BlobStorageService` for uploads | Add `getDocumentHtml()`, `deleteSourceDocument()` | **Medium** — new methods are additive but imports change |
| `compliance.module.ts` (NestJS) | Adds `BlobStorageModule` | May need additional imports | **Low** |
| `compliance.controller.ts` (NestJS) | Not significantly changed | Add GET HTML + DELETE endpoints | **Low** |
| `compliance-document.entity.ts` (NestJS) | Not touched | Add `convertedHtmlKey` column | **None** |

### Recommendation

**Frontend work can start NOW** — the tagging-redesign changes to compliance frontend files are small and non-overlapping with the viewer rendering work. Merge conflicts will be trivial.

**Backend work should start after `tagging-redesign` merges to `main`** (or branch off `tagging-redesign`) — the compliance listener is substantially rewritten, and `compliance.service.ts` has import changes from `BlobStorageService`.

---

## What's Blocked on Tagging (NOT in this plan)

These items from the original `PRCR-1260-PLAN.md` are **excluded** from this plan because they depend on the tagging redesign landing:

| Original Phase/Step | Description | Why Blocked |
|---------------------|-------------|-------------|
| Phase 0 (all) | Python `add_data_linenum()`, auto-tag handler updates | Python branch `fix/block-aware-text-extraction` modifies the same auto-tag handler files. `add_data_linenum()` needs to be integrated after coworkers' text extraction fixes land. |
| Phase 1 Step 1.4 (char-offset → linenum mapping) | `buildLinenumMapFromHtml()` + `charOffsetToLinenum()` in compliance listener | The coordinate system and offset semantics may change with the tagging redesign. The listener is rewritten to use `DocumentTag`. Mapping logic should be implemented against the final data model. |
| Phase 3 Steps 3.3–3.6 | Selection capture → `data-linenum`, highlighting compliance items, `CreateComplianceItemSelection` updates, `highlightRegions` | These are the core "tagging" UX: selecting text and creating/viewing tagged items. Depends on the new coordinate system and `DocumentTag` model. |

These will be picked up **after** the tagging redesign merges. The original `PRCR-1260-PLAN.md` remains the source of truth for these items.

---

## Assumptions

1. All assumptions from `PRCR-1260-PLAN.md` still apply (see § Assumptions there).
2. The `tagging-redesign` branch will merge before Phase B of this plan begins (backend work).
3. The compliance listener on `tagging-redesign` still emits/receives `AutoTagCompleteEvent` with `convertedHtmlUrl` — confirmed: the event interface is unchanged.
4. `BlobStorageService` on the `tagging-redesign` branch is a wrapper around MinIO. The `getDocumentHtml` method can use either `BlobStorageService` or `MinioService` for reading HTML from the `uploads` bucket. Prefer `BlobStorageService` for consistency with the redesign's direction.
5. The frontend viewer panel rewrite (Phase A) can be developed and tested with hardcoded/mock HTML strings while the backend endpoint (Phase B) is being built. The mock can be replaced with a real API call once the backend is ready.
6. `DOMPurify` is already a project dependency (used by `DocShellComponent`).

---

## Open Questions

1. **BlobStorageService vs MinioService for HTML reads.** The tagging redesign introduces `BlobStorageService` for uploads. Should the `getDocumentHtml` method use `BlobStorageService.download()` or `MinioService.getObjectBuffer()`? Depends on whether `BlobStorageService` supports read operations and is registered in `ComplianceModule`. _(Check after tagging-redesign merges.)_
2. **`convertedHtmlKey` bucket.** Both compliance uploads and Python auto-tag handler write to the `uploads` bucket. Confirm that `BlobStorageService.download()` defaults to the correct bucket, or pass it explicitly. _(Same concern as original plan Open Question #8 — just with the new abstraction.)_
3. **Auto-tag timing for document viewing.** Documents are only viewable after auto-tag completes (which produces the HTML). Open Question #8 from the original plan (when to call `requestAutoTag()`) still applies and affects UX. _(Carry forward — product decision needed.)_
4. **Mock HTML for frontend development.** To unblock frontend work, we need a sample Docling HTML string with `data-linenum` attributes. Can we grab one from an existing auto-tag run in staging, or generate one from a test document? _(Investigate during Phase A.)_

---

## Implementation Plan

### Phase A: Frontend — Document Viewer HTML Rendering `[FRONTEND]`

> **Goal:** Replace line-based mock rendering with HTML rendering via `innerHTML`. This is the largest single piece of work and can start **immediately** — it has minimal conflict with the tagging redesign.
>
> **Can start:** Now
> **Depends on:** Nothing (use mock/hardcoded HTML for development)

#### Step A.1: Add `LineElementsCache` to compliance module

- **File:** `rohan_ui-parent/rohan_ui/src/app/pages/compliance/utils/line-elements-cache.ts` *(new)*
- **What:** Copy `LineElementsCache` from `proposal-writer/components/html-renderer/line-elements-cache.ts`. ~38 lines. Maps `data-linenum` values to DOM elements and positions. Use `Number()` instead of `parseInt()` per project convention.
- **Why now:** Needed for both rendering (scroll-to-element) and later for tagging (highlight elements). Creating the file now has zero conflict risk.

#### Step A.2: Add `DocumentHtmlResponse` type + `ConversionStatus`

- **File:** `rohan_ui-parent/rohan_ui/src/app/pages/compliance/types/compliance-item.types.ts`
- **What:** Add:
  ```typescript
  export type ConversionStatus = 'PENDING' | 'COMPLETE' | 'FAILED';
  
  export interface DocumentHtmlResponse {
    documentId: string;
    documentName: string;
    mimeType: string;
    conversionStatus: ConversionStatus;
    html?: string;
  }
  ```
- **Why now:** Pure type addition, no conflict risk.

#### Step A.3: Rebuild `document-viewer-panel` for HTML rendering

- **Files:**
  - `document-viewer-panel.component.ts`
  - `document-viewer-panel.component.html`
  - `document-viewer-panel.component.scss`
- **What:**
  - **New inputs:** `htmlContent` (string | null), `isContentLoading` (boolean), `contentError` (string | null), `conversionStatus` (ConversionStatus).
  - **Keep existing inputs** for now: `documents`, `selectedDocumentId`, `selectedItemId`, `highlightRegions` — these will continue to be used once tagging work lands.
  - **Replace** the `@for (line of document.lines)` template block with:
    ```html
    @if (isContentLoading()) {
      <div class="document-loading"><!-- spinner/skeleton --></div>
    } @else if (conversionStatus() === 'PENDING') {
      <div class="document-pending">Document is being processed. Please refresh in a moment.</div>
    } @else if (contentError() || conversionStatus() === 'FAILED') {
      <div class="document-error">Document conversion failed. Please re-upload the file.</div>
    } @else if (sanitizedHtml()) {
      <div class="document-content" #documentContent [innerHTML]="sanitizedHtml()"></div>
    } @else {
      <div class="document-empty">Select a document to view its content.</div>
    }
    ```
  - **Add** HTML sanitization: `DOMPurify.sanitize()` → strip unsafe tags → `bypassSecurityTrustHtml()` (from `DocShellComponent` pattern).
  - **Add** `LineElementsCache` initialization: after HTML renders, build cache from `[data-linenum]` elements (via `afterNextRender` or `MutationObserver`).
  - **Keep** document dropdown and document switching.
  - **Keep** the `PdfHighlightOverlayComponent` references temporarily (remove in Phase D) — they become no-ops when lines are empty.
  - **Defer** selection capture (`onContentMouseUp`) and highlighting to the tagging work.
- **Conflict with tagging-redesign:** The only change in tagging-redesign is `@HostListener` → `host` binding (5 lines). Since we're rewriting the component, we apply the `host` pattern in the rewrite. No real conflict.

#### Step A.4: Update `compliance-document.utils.ts` to remove mock fallback

- **File:** `rohan_ui-parent/rohan_ui/src/app/pages/compliance/utils/compliance-document.utils.ts`
- **What:**
  - Remove import of `MOCK_COMPLIANCE_DOCUMENTS`.
  - Update `toViewerDocument()` to produce a `ComplianceSourceDocument` with **empty `lines` array** (lines are no longer the rendering model).
  - Remove the `fallbackDocuments` parameter.
- **Conflict with tagging-redesign:** File not touched by tagging-redesign. No conflict.

#### Step A.5: Update `compliance-list-creator` to pass new inputs

- **Files:**
  - `compliance-list-creator.component.ts`
  - `compliance-list-creator.component.html`
- **What:** Pass `htmlContent`, `isContentLoading`, `contentError`, `conversionStatus` from state service to viewer panel. For now, use hardcoded mock HTML or connect to the state service signals added in Step A.6.

#### Step A.6: Add HTML loading state to `ComplianceStateService` (minimal version)

- **File:** `rohan_ui-parent/rohan_ui/src/app/pages/compliance/services/compliance-state.service.ts`
- **What:** Add signals for HTML content state. Initially, these can be populated from a mock or left as pending:
  - `_documentHtmlCache`: `Map<string, string>` for loaded HTML per document ID.
  - `_isDocumentHtmlLoading`: signal<boolean>.
  - `_documentHtmlError`: signal<string | null>.
  - `_documentConversionStatus`: signal<ConversionStatus | null>.
  - `selectedDocumentHtml`: computed signal derived from cache + `_selectedDocumentId`.
  - `loadDocumentHtml(projectId, documentId)`: method that will call the API (Phase C) or use a mock for now.
- **Conflict with tagging-redesign:** Low — the redesign adds 409 handling and a `project` signal in different code areas. HTML loading signals and methods are fully additive.

#### Step A.7: Frontend unit tests for rendering

- **Files:**
  - `document-viewer-panel.component.spec.ts`
  - `line-elements-cache.spec.ts` *(new)*
- **What:**
  - Test HTML rendering (sanitization, innerHTML binding, loading/error/pending states).
  - Test `LineElementsCache` (cache building, element lookup).
  - Test document switching triggers HTML load.
  - Update existing tests that depend on line-based rendering.

---

### Phase B: Backend — Schema + HTML Serving Endpoint `[BACKEND_DB]`

> **Goal:** Persist `convertedHtmlKey` from auto-tag completion and serve cached HTML to the frontend.
>
> **Can start:** After `tagging-redesign` merges to `main` (or branch off `tagging-redesign`)
> **Depends on:** Tagging redesign merge (compliance listener is rewritten)

#### Step B.1: Add `convertedHtmlKey` column

- **Files:**
  - `rohan_api-parent/rohan_api/src/compliance/entities/compliance-document.entity.ts`
  - New migration or `init_compliance.sql` update
- **What:**
  - Add nullable `converted_html_key` (`varchar(500)`) to `compliance_documents`.
  - No `conversion_status` column — the existing `processingStatus` + `convertedHtmlKey` non-null check is sufficient (see original plan Resolved Questions).

#### Step B.2: Update compliance listener to persist `convertedHtmlUrl`

- **File:** `rohan_api-parent/rohan_api/src/compliance/listeners/compliance.listener.ts`
- **What:** In `handleAutoTagComplete`, after marking the document ready, persist `event.convertedHtmlUrl` as `convertedHtmlKey`:
  ```typescript
  if (event.convertedHtmlUrl) {
    await this.complianceDocumentRepository.update(documentId, {
      convertedHtmlKey: event.convertedHtmlUrl,
    });
  }
  ```
- **Note:** This is the **simple persistence** only. The char-offset → linenum mapping (converting segment/tag offsets to `data-linenum` values) is tagging-dependent work and is NOT included here. That mapping will be added when the tagging integration work begins.
- **Must be applied against the `tagging-redesign` version of the listener** (which uses `DocumentTag` instead of `DocumentSegment`).

#### Step B.3: Guard `handleAutoTagComplete` against deleted documents

- **File:** `rohan_api-parent/rohan_api/src/compliance/listeners/compliance.listener.ts`
- **What:** Before creating compliance items, check if the document still exists:
  ```typescript
  const document = await this.complianceDocumentRepository.findOneBy({ id: documentId });
  if (!document) {
    this.logger.warn(`Auto-tag complete for document ${documentId} but document no longer exists`);
    return;
  }
  ```
- **Why here:** Needed for document deletion (Phase D) to work safely. Independent of tagging.

#### Step B.4: Add `getDocumentHtml` method to `ComplianceService`

- **File:** `rohan_api-parent/rohan_api/src/compliance/compliance.service.ts`
- **What:** New method that:
  1. Looks up `ComplianceDocument` by ID + validates project ownership.
  2. Checks HTML availability:
     - `convertedHtmlKey` non-null → read HTML from MinIO/BlobStorage → return `{ documentId, documentName, mimeType, conversionStatus: 'COMPLETE', html }`.
     - `convertedHtmlKey` null + processing → return `{ ..., conversionStatus: 'PENDING', html: null }`.
     - `convertedHtmlKey` null + failed → throw `BadGatewayException`.
  3. Pass bucket explicitly when reading: `'uploads'`.

#### Step B.5: Add `DocumentHtmlResponseDto`

- **File:** `rohan_api-parent/rohan_api/src/compliance/dto/document-html-response.dto.ts` *(new)*
- **What:** Response DTO with `@ApiProperty` decorators. See contracts file.

#### Step B.6: Add controller endpoint

- **File:** `rohan_api-parent/rohan_api/src/compliance/compliance.controller.ts`
- **What:** `GET /compliance/projects/:projectId/documents/:documentId/html`
  - Auth: JWT + compliance permission guard.
  - Returns `DocumentHtmlResponseDto`.
  - `200` with HTML, `202` when pending, `404` for not found, `502` for failed.

#### Step B.7: Backend unit tests

- **Files:**
  - `compliance.service.spec.ts` (update)
  - `compliance.listener.spec.ts` (update)
- **What:**
  - Test `getDocumentHtml` (complete, pending, failed, not found).
  - Test listener persists `convertedHtmlKey`.
  - Test deleted-document guard.

---

### Phase C: Frontend — Wire API Integration `[FRONTEND]`

> **Goal:** Connect the frontend HTML loading to the real backend endpoint.
>
> **Can start:** After Phase B backend endpoint is deployed (or use mock server)
> **Depends on:** Phase A (rendering) + Phase B (endpoint)

#### Step C.1: Add `getDocumentHtml` to `ComplianceApiService`

- **File:** `rohan_ui-parent/rohan_ui/src/app/pages/compliance/services/compliance-api.service.ts`
- **What:** New method calling `GET .../documents/:documentId/html`. Returns `Observable<DocumentHtmlResponse>`. Use `getWithoutErrorModal` to handle 202 without triggering error UI.
- **Conflict with tagging-redesign:** Low — the redesign adds error handling and response methods, but the document section is untouched. This is an additive method.

#### Step C.2: Wire `ComplianceStateService` to real API

- **File:** `rohan_ui-parent/rohan_ui/src/app/pages/compliance/services/compliance-state.service.ts`
- **What:** Update `loadDocumentHtml()` (added in Step A.6) to call the real API:
  - `200` response → cache HTML, set status to `COMPLETE`.
  - `202` response → set status to `PENDING`.
  - Error → set status to `FAILED`.
  - Add effect: when `_selectedDocumentId` changes, auto-fetch HTML if not cached.

#### Step C.3: Frontend unit tests for API integration

- **Files:**
  - `compliance-api.service.spec.ts` (update)
  - `compliance-state.service.spec.ts` (update)
- **What:** Test API method, state service loading/caching/error handling.

---

### Phase D: Backend + Frontend — Document Lifecycle `[BACKEND_DB]` + `[FRONTEND]`

> **Goal:** Support adding documents from the overview page (with auto-tag) and deleting documents with cascade cleanup.
>
> **Can start:** After Phase B merges (extends the same backend files)
> **Depends on:** Phase B (schema + listener changes)

#### Step D.1: Add `DELETE /compliance/projects/:projectId/documents/:documentId` endpoint `[BACKEND_DB]`

- **File:** `rohan_api-parent/rohan_api/src/compliance/compliance.controller.ts`
- **What:** New `DELETE` endpoint. Auth: JWT + compliance permission. Returns `204 No Content`.

#### Step D.2: Add `deleteSourceDocument` method `[BACKEND_DB]`

- **File:** `rohan_api-parent/rohan_api/src/compliance/compliance.service.ts`
- **What:** Validates project ownership, deletes `compliance_documents` row (CASCADE removes items), cleans up MinIO/BlobStorage files (source + converted HTML). MinIO failures don't block DB delete.

#### Step D.3: Trigger `requestAutoTag()` for overview-page uploads `[BACKEND_DB]`

- **File:** `rohan_api-parent/rohan_api/src/compliance/compliance.service.ts`
- **What:** Add `autoTag` parameter to upload method. When `true`, call `requestAutoTag()` after saving. Default `false`. Overview-page uploads pass `true`; wizard uploads rely on "Finish" button.
- **File:** `rohan_api-parent/rohan_api/src/compliance/compliance.controller.ts`
- **What:** Accept `autoTag` as optional query parameter on upload endpoint.

#### Step D.4: Update `requestAutoTagging()` to skip already-tagged documents `[BACKEND_DB]`

- **File:** `rohan_api-parent/rohan_api/src/compliance/compliance.service.ts`
- **What:** Filter source documents to exclude those with `taggableDocId` set. Only new documents are auto-tagged on subsequent "Finish" clicks.

#### Step D.5: Add `deleteSourceDocument` to frontend `[FRONTEND]`

- **File:** `rohan_ui-parent/rohan_ui/src/app/pages/compliance/services/compliance-api.service.ts`
- **What:** New method calling `DELETE .../documents/:documentId`. Returns `Observable<void>`.

#### Step D.6: Wire overview page upload + delete `[FRONTEND]`

- **Files:** Overview page component (Document Library section)
- **What:**
  - Upload passes `autoTag=true`.
  - Delete button calls `deleteSourceDocument` with confirmation dialog.
  - Refresh document list after operations.

#### Step D.7: Backend + frontend unit tests for document lifecycle

- **Files:** `compliance.service.spec.ts`, `compliance.listener.spec.ts`, `compliance-api.service.spec.ts`, overview component spec
- **What:** Test delete cascade, MinIO cleanup, auto-tag chaining, incremental tagging, frontend API methods.

---

### Phase E: Cleanup `[FRONTEND]`

> **Goal:** Remove dead code after the new rendering is verified working.
>
> **Can start:** After Phase A is verified
> **Depends on:** Phase A

#### Step E.1: Remove `PdfHighlightOverlayComponent` from compliance

- **Files:**
  - `rohan_ui-parent/rohan_ui/src/app/pages/compliance/components/pdf-highlight-overlay/`
  - `compliance.module.ts` (update declarations)
- **What:** Remove from compliance viewer template. If no other consumers, remove entirely.

#### Step E.2: Remove mock data from production code

- **File:** `compliance-document.utils.ts`, mock data file
- **What:** Ensure no production code imports `MOCK_COMPLIANCE_DOCUMENTS`.

#### Step E.3: Remove page number display

- **File:** `document-viewer-panel.component.html`
- **What:** Remove "Page X of Y" display.

---

## Phase Order and Parallelism

### Files touched per phase

| Phase | Repo | Files |
|-------|------|-------|
| **A** | `rohan_ui` | New `line-elements-cache.ts`, `compliance-item.types.ts`, `document-viewer-panel.component.{ts,html,scss}`, `compliance-document.utils.ts`, `compliance-list-creator.component.{ts,html}`, `compliance-state.service.ts`, `*.spec.ts` |
| **B** | `rohan_api` | `compliance-document.entity.ts`, new migration, `compliance.listener.ts`, `compliance.service.ts`, `compliance.controller.ts`, new `document-html-response.dto.ts`, `*.spec.ts` |
| **C** | `rohan_ui` | `compliance-api.service.ts`, `compliance-state.service.ts`, `*.spec.ts` |
| **D** | Both | `compliance.service.ts`, `compliance.controller.ts`, `compliance.listener.ts` (NestJS); `compliance-api.service.ts`, overview component (Angular) |
| **E** | `rohan_ui` | `pdf-highlight-overlay/`, `compliance.module.ts`, `compliance-document.utils.ts`, `document-viewer-panel.component.html` |

### Parallelism and sequencing

```
                 ┌─────────────────────────┐
 START ──────────┤  Phase A (Frontend       │ ← CAN START NOW
 NOW             │  Viewer Rendering)       │
                 └──────────┬──────────────┘
                            │
     ┌──────────────────────┴───────────────────────┐
     │                                               │
     ▼                                               ▼
┌──────────────┐                            ┌───────────────┐
│ Phase E      │                            │ Phase B        │ ← AFTER tagging-redesign
│ (Cleanup)    │                            │ (Backend HTML  │   merges to main
│              │                            │  Serving)      │
└──────────────┘                            └───────┬───────┘
                                                    │
                                        ┌───────────┴──────────┐
                                        │                      │
                                        ▼                      ▼
                                  ┌──────────┐          ┌──────────┐
                                  │ Phase C  │          │ Phase D  │
                                  │ (Wire    │          │ (Doc     │
                                  │  API)    │          │ Lifecycle│
                                  └──────────┘          └──────────┘
```

**Phase A can start immediately.** It touches only frontend viewer files with minimal tagging-redesign overlap. Use mock/hardcoded HTML for development.

**Phase B must wait for `tagging-redesign` to merge** (or branch off it). The compliance listener and service files are substantially changed in the redesign.

**Phase C depends on Phase A + Phase B.** It connects the frontend rendering (Phase A) to the backend endpoint (Phase B).

**Phase D depends on Phase B.** It extends the same backend files.

**Phase E can start after Phase A is verified.** It only removes dead code.

### What to do while waiting for tagging-redesign merge

| What You Can Do | Estimated Effort | Phase |
|-----------------|-----------------|-------|
| Copy `LineElementsCache` to compliance module | Small (1h) | A.1 |
| Add `DocumentHtmlResponse` type | Trivial | A.2 |
| **Rebuild viewer panel with HTML rendering** | **Large (1-2 days)** | A.3 |
| Remove mock fallback from utils | Small (30min) | A.4 |
| Wire up parent component | Small (1h) | A.5 |
| Add HTML loading state signals (with mock) | Medium (2-3h) | A.6 |
| Write unit tests for rendering | Medium (3-4h) | A.7 |
| Remove `PdfHighlightOverlayComponent` | Small (30min) | E.1 |
| Remove mock data imports | Trivial | E.2 |
| Create `DocumentHtmlResponseDto` (new file, no conflicts) | Small (30min) | B.5 |

**Total parallelizable work: ~2-3 days of frontend work** plus creating the backend DTO file.

### What to do immediately after tagging-redesign merges

| What To Do | Estimated Effort | Phase |
|------------|-----------------|-------|
| Add `convertedHtmlKey` column + migration | Small (1h) | B.1 |
| Update listener to persist `convertedHtmlUrl` | Small (1h) | B.2 |
| Add deleted-document guard | Small (30min) | B.3 |
| Implement `getDocumentHtml` service method | Medium (2h) | B.4 |
| Add controller endpoint | Small (1h) | B.6 |
| Backend unit tests | Medium (3-4h) | B.7 |

**Total Phase B: ~1-1.5 days of backend work.**

---

## Jira Ticket Information

### Ticket V1: Frontend — Document Viewer HTML Rendering (Phase A)

- **Title:** `[FRONTEND] PRCR-1260: Replace mock line rendering with Docling HTML viewer`
- **Description:** Rebuild the `document-viewer-panel` component to render Docling-converted HTML via `innerHTML` instead of line-based mock text. Add `LineElementsCache` utility (copied from proposal-writer), HTML sanitization via DOMPurify, and loading/error/pending states. Add `DocumentHtmlResponse` type. Remove mock data fallback from `compliance-document.utils.ts`. Update `compliance-list-creator` to pass HTML content to the viewer. Initially uses mock HTML — backend API wiring follows in a separate ticket.
- **Acceptance Criteria:**
  - Document viewer renders HTML via `innerHTML` with DOMPurify sanitization.
  - `LineElementsCache` built from `[data-linenum]` elements after render.
  - Loading spinner shown during HTML fetch.
  - Pending conversion message shown when `conversionStatus = 'PENDING'`.
  - Error message shown on conversion failure.
  - Document dropdown switching works.
  - Mock data no longer used in production code.
  - Unit tests pass for rendering, cache, and state.
- **Story Points:** 8
- **PR Scope:** `rohan_ui` only.
- **Blocked by:** Nothing — can start immediately.

### Ticket V2: Backend — Persist HTML Key + Serve HTML Endpoint (Phase B)

- **Title:** `[BACKEND] PRCR-1260: Add convertedHtmlKey column and GET .../documents/:id/html endpoint`
- **Description:** (A) Add `converted_html_key` column to `compliance_documents` table. (B) Update compliance listener to persist `convertedHtmlUrl` from auto-tag completion events as `convertedHtmlKey`. (C) Add guard for deleted documents in auto-tag completion handler. (D) Add `GET /compliance/projects/:projectId/documents/:documentId/html` endpoint — reads HTML from MinIO/BlobStorage, returns 200 (complete), 202 (pending), 404 (not found), 502 (failed). Includes unit tests.
- **Acceptance Criteria:**
  - New column + migration for `converted_html_key`.
  - Compliance listener persists `convertedHtmlUrl` from auto-tag events.
  - Deleted-document guard prevents FK violations.
  - GET endpoint returns appropriate status codes.
  - Unit tests pass.
- **Story Points:** 5
- **PR Scope:** `rohan_api` only.
- **Blocked by:** Tagging redesign merge.

### Ticket V3: Frontend — Wire API Integration (Phase C)

- **Title:** `[FRONTEND] PRCR-1260: Connect document viewer to HTML serving API`
- **Description:** Add `getDocumentHtml()` to `ComplianceApiService`. Update `ComplianceStateService` to call the real backend API for document HTML, replacing the mock/placeholder from Ticket V1. Handle 200/202/error responses, cache loaded HTML per document.
- **Acceptance Criteria:**
  - Selecting a document triggers API call to fetch HTML.
  - HTML cached per document in state service.
  - 202 response shows pending state.
  - Error response shows error state.
  - Unit tests pass.
- **Story Points:** 3
- **PR Scope:** `rohan_ui` only.
- **Blocked by:** Ticket V1 + Ticket V2.

### Ticket V4: Document Lifecycle — Deletion + Auto-tag on Upload (Phase D)

- **Title:** `[BACKEND+FRONTEND] PRCR-1260: Document deletion cascade and auto-tag on overview upload`
- **Description:** (Backend) Add `DELETE /compliance/projects/:projectId/documents/:documentId` endpoint with cascade to compliance items and MinIO cleanup. Add `autoTag` query parameter to upload endpoint for overview-page uploads. Update `requestAutoTagging()` to skip already-tagged documents. (Frontend) Add `deleteSourceDocument()` to API service. Wire overview page upload with `autoTag=true` and delete with confirmation dialog.
- **Acceptance Criteria:**
  - DELETE endpoint removes document, cascades to items, cleans MinIO.
  - Upload with `autoTag=true` triggers immediate auto-tagging.
  - `requestAutoTagging()` skips documents with `taggableDocId`.
  - Deleted-document guard in listener prevents FK violations.
  - Frontend confirmation dialog on delete.
  - Document list refreshes after operations.
  - Unit tests pass.
- **Story Points:** 5
- **PR Scope:** Both `rohan_api` and `rohan_ui`.
- **Blocked by:** Ticket V2.

### Ticket V5: Frontend Cleanup (Phase E)

- **Title:** `[FRONTEND] PRCR-1260: Remove PdfHighlightOverlay, mock data, and page numbers`
- **Description:** Remove `PdfHighlightOverlayComponent` from compliance viewer template and module. Remove mock document data imports from production code. Remove page number display.
- **Acceptance Criteria:**
  - `PdfHighlightOverlayComponent` removed from compliance.
  - No production code imports mock document data.
  - Page number display removed.
  - Existing tests updated and passing.
- **Story Points:** 2
- **PR Scope:** `rohan_ui` only.
- **Blocked by:** Ticket V1.

---

## Relationship to Original Plan

This plan implements the **non-tagging subset** of the original `PRCR-1260-PLAN.md`:

| This Plan Phase | Original Plan Phase(s) | Notes |
|-----------------|----------------------|-------|
| **A** (Viewer Rendering) | Phase 3 Steps 3.1, 3.2, 3.7 + Phase 2 Steps 2.2, 2.3 (partial) + Phase 4 | Rendering without selection/highlighting |
| **B** (Backend HTML Serving) | Phase 1 Steps 1.1, 1.5, 1.6, 1.7, 1.8 | Without char-offset → linenum mapping |
| **C** (Wire API) | Phase 2 Steps 2.1, 2.3 (remainder) | API wiring |
| **D** (Document Lifecycle) | Phase 6A + 6B | Identical scope |
| **E** (Cleanup) | Phase 4 | Identical scope |
| _(Not in this plan)_ | Phase 0 (Python), Phase 1 Step 1.4, Phase 3 Steps 3.3–3.6 | Tagging-dependent — see original plan |

After the tagging redesign merges and this plan's phases complete, the remaining tagging-dependent items from the original plan can be implemented as a follow-up.
