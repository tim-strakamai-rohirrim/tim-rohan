# PRCR-1260-v2 — Real Document Viewer, Manual Tagging, and Document Management

> **This plan replaces** `PRCR-1260-PLAN.md` and `PRCR-1260-VIEWER-PLAN.md`. Those earlier documents are superseded.

> **Prerequisite:** This plan targets the `feature/` worktrees (post-tagging-redesign). The tagging redesign branches must be merged before implementation begins. Key dependencies include the refactored `InlineTag` interface (flat-text offsets instead of block-based coordinates), `BlobStorageService` in the compliance module, and the `DocumentTag`-based compliance listener.

## Problem Statement

The **Document Viewer Panel** in the Compliance List Creation workflow (`document-viewer-panel.component`) currently displays **mock/hardcoded text lines** instead of actual document content. The `mapProjectDocumentsToViewerDocuments()` utility in `compliance-document.utils.ts` maps project documents onto `MOCK_COMPLIANCE_DOCUMENTS` line data (with a TODO to replace it).

Users need to:

1. View the **real content** of each uploaded source document in the right-hand panel, with layout that **matches the look of the original document**.
2. **Highlight text** within the rendered document and create compliance items (tagging) from the selection — even when auto-tagging has not been run.
3. **Edit both auto-tagged and manually created compliance items** (title, text, etc.) while viewing the highlighted source passage for context.
4. Switch between multiple documents via the existing dropdown.
5. **Add new documents** to an existing project from the overview page's Document Library (post-wizard), with auto-tagging running automatically on only the new documents after conversion completes.
6. **Delete documents** from the library, with all associated compliance items automatically removed from the database.

The viewer must support **PDF, DOCX, and XLSX** files. Docling already converts all three formats to HTML uniformly, so one rendering path handles all file types.

### Document lifecycle context

- The **wizard** (Create → Preview → Finish) already triggers auto-tagging on all uploaded documents when the user clicks Finish (`onFinish()` calls `processDocuments(projectId, true)` fire-and-forget). This behaviour is correct and does not change.
- After finishing the wizard, the **overview page** includes a Document Library section. Documents uploaded here must be auto-tagged automatically after upload — there is no "Finish" button.
- Deleting a document from the overview page must cascade-delete all associated compliance items (already handled by `ON DELETE CASCADE` in the DB).

---

## Key Architectural Observations

### How HTML is produced today

1. **Upload**: Frontend uploads file via `POST /compliance/projects/:project_id/documents` → stored in MinIO at `compliance_documents.minio_object_key`.
2. **Auto-tag trigger**: `POST /compliance/projects/:project_id/documents/process` → NestJS emits `compliance.auto.tag` event → `ComplianceListener.autoTagHandler` sends one Service Bus `AutoTagRequestMessage` per document.
3. **Python worker**: Downloads file from MinIO → Docling converts to HTML → `strip_html_metadata` removes `<style>`, `<script>`, `<head>` → segments HTML → classifies tags → **uploads stripped HTML** to MinIO at `{parent_path}/output/{stem}.html` → sends `AutoTagComplete` with `converted_html_url`.
4. **NestJS handler**: `AutoTagCompleteHandler` persists tags → emits `tagging.auto-tag-complete` event with `convertedHtmlUrl`.
5. **Compliance listener**: `handleAutoTagComplete` marks document ready/failed, loads `DocumentTag` rows, creates `ComplianceItem` rows — but **does not store `convertedHtmlUrl`**.

### Offset semantics

`compliance_items.document_start_line` / `document_end_line` are populated from `DocumentTag.start_offset` / `end_offset` via the compliance listener. Despite the "line" naming, these are **character offsets into the stripped HTML string**, not line numbers. The same offset space applies to the HTML served by the new content endpoint.

### Existing cascade constraints (DB)

- `compliance_items.source_document_id → compliance_documents(id) ON DELETE CASCADE`
- `compliance_project_documents(document_id) → compliance_documents(id) ON DELETE CASCADE`
- `compliance_checks.compliance_item_id → compliance_items(id) ON DELETE CASCADE`
- `compliance_item_evidence.response_document_id → compliance_documents(id) ON DELETE CASCADE`

Deleting a `compliance_documents` row automatically removes all associated items, checks, and evidence.

---

## Assumptions

1. Docling-generated stripped HTML is **safe to render**. The shared `app-doc-shell` component already handles sanitisation via DOMPurify + `bypassSecurityTrustHtml`, matching the Proposal Writer's approach.
2. The stripped HTML uploaded by the Python auto-tag worker is the **same** HTML we serve in the viewer — no secondary conversion needed.
3. The viewer only needs to display document content **after** auto-tagging has been triggered (wizard Finish or overview upload). A "Processing…" placeholder for in-progress documents is acceptable for v1.
4. The existing `pageNumber` / `totalPages` fields on `ComplianceSourceDocument` can be dropped — Docling HTML does not inherently have page breaks.
5. The shared `app-doc-shell` component's offset algorithm (`buildFlattenedOffsetsByTextNode`) is compatible with the Python auto-tag pipeline's `extract_text_with_mapping()` — both use the same block selectors and separator. This is explicitly documented in the Python code comments.
6. `app-doc-shell` is exported by `SharedComponentsModule`, which `ComplianceModule` already imports. No additional module import is needed.

---

## Resolved Questions

| #    | Question                                                                                                          | Decision                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| ---- | ----------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| OQ-1 | Should `document_start_line` / `document_end_line` be renamed to `document_start_offset` / `document_end_offset`? | **Leave as-is.** Document the semantics (they are character offsets, not line numbers) but do not rename to minimise churn on the coworker's code.                                                                                                                                                                                                                                                                                                                                                                                                      |
| OQ-2 | Should the viewer show content before auto-tagging completes?                                                     | **Show a "Processing…" placeholder.** A separate fast-convert step can be a follow-up.                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| OQ-3 | Per-document auto-tagging approach?                                                                               | **New per-document endpoint `POST .../documents/:docId/process`.** The wizard's bulk `POST .../documents/process` stays unchanged. A separate endpoint avoids conflating project-level `autotag_processing` status with per-document processing, and keeps the two flows cleanly separated. See Phase 4.                                                                                                                                                                                                                                                |
| OQ-4 | HTML rendering isolation?                                                                                         | **Reuse the shared `app-doc-shell` component** from `shared-components/document-shredding/`. This is the same component the Proposal Writer uses. It renders via `[innerHTML]` with DOMPurify + `bypassSecurityTrustHtml`, uses `::ng-deep` for content styling, and — critically — already implements offset-based `<mark>` highlighting and text-selection-to-offset computation using the exact same flattened-text algorithm as the Python auto-tag pipeline.                                                                                       |
| OQ-5 | Overview page upload UX?                                                                                          | **Reuse `app-document-upload`** (drag-and-drop) for consistency with the wizard.                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| OQ-6 | Confirmation dialog on document delete?                                                                           | **No confirmation dialog.** Delete immediately on click.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| OQ-7 | What offset space do auto-tag offsets use?                                                                        | **Flattened visible text** (not raw HTML). Python's `extract_text_with_mapping` in `html_preprocessing.py` and Angular's `doc-shell.buildFlattenedOffsetsByTextNode` use the **exact same algorithm** by design: walk text nodes inside block-level elements (`h1-h6, p, li, tr, td, span`), concatenate visible text, insert a single space between different block elements. Comments in the Python code explicitly reference the UI constants. This means `app-doc-shell` natively handles compliance item highlighting with no custom offset logic. |

## Open Questions

No remaining open questions. All resolved above.

---

## Implementation Phases

### Phase 1 — Store converted HTML key [BACKEND_DB]

```phase-meta
phase: 1
title: Store converted HTML key
tags: [BACKEND_DB]
repo: rohan_api
base_branch: base
depends_on: []
files:
  - src/compliance/entities/compliance-document.entity.ts
  - src/compliance/listeners/compliance.listener.ts
  - src/compliance/listeners/compliance.listener.spec.ts
contracts:
  - "4.1 converted_html_key column"
  - "7.2 AutoTagCompleteEvent"
verification:
  - npm run lint
  - npm run test -- src/compliance/listeners/compliance.listener.spec.ts
```

**Goal**: Persist the MinIO key for the converted HTML on the compliance document entity so it can be retrieved later.

**Steps**:

- [ ] **1.1** Add `converted_html_key VARCHAR(500) NULL` column to `compliance_documents` table.
  - File: `Database/rohan_api/scripts/sql/init_compliance.sql` _(workspace-relative — outside repo)_
- [ ] **1.2** Add `convertedHtmlKey` column to `ComplianceDocument` TypeORM entity.
  - File: `src/compliance/entities/compliance-document.entity.ts`
- [ ] **1.3** In `ComplianceListener.handleAutoTagComplete`, save `event.convertedHtmlUrl` to the document's `convertedHtmlKey`.
  - If the value is an Azure Blob HTTPS URL, extract the object path. If it's already a MinIO path/key, store as-is.
  - File: `src/compliance/listeners/compliance.listener.ts`
- [ ] **1.4** Guard `handleAutoTagComplete` against deleted documents.
  - Before creating compliance items from tags, check if the `ComplianceDocument` still exists. If it was deleted while auto-tagging was in progress, log a warning and return early. This prevents FK constraint violations when a completion event arrives for a document the user deleted during processing.
  - File: `src/compliance/listeners/compliance.listener.ts`
- [ ] **1.5** Unit tests: verify `handleAutoTagComplete` persists the key, and verify deleted-document guard skips gracefully.
  - File: `src/compliance/listeners/compliance.listener.spec.ts`

---

### Phase 2 — Serve document HTML content [BACKEND_DB]

```phase-meta
phase: 2
title: Serve document HTML content
tags: [BACKEND_DB]
repo: rohan_api
base_branch: phase-1
depends_on: [1]
files:
  - src/compliance/compliance.service.ts
  - src/compliance/compliance.service.spec.ts
  - src/compliance/compliance.controller.ts
  - src/compliance/compliance.controller.spec.ts
  - src/compliance/dto/document-content-response.dto.ts
contracts:
  - "1.1 GET content endpoint"
  - "3.1 DocumentContentResponseDto"
  - "6 Error responses"
verification:
  - npm run lint
  - npm run test -- src/compliance/compliance.service.spec.ts
  - npm run test -- src/compliance/compliance.controller.spec.ts
```

**Goal**: New endpoint to retrieve the converted HTML for a compliance source document.

**Steps**:

- [ ] **2.1** Add `getDocumentContent(projectId, documentId)` method to `ComplianceService`.
  - Loads the `ComplianceDocument` (verify it belongs to the project via join table).
  - If `convertedHtmlKey` is null → throw 404 or 409 ("not yet converted").
  - If `processingStatus` is not `extraction_complete` → throw 409 ("still processing").
  - Reads HTML from MinIO via `BlobStorageService.downloadBuffer()` and returns the string.
  - File: `src/compliance/compliance.service.ts`
- [ ] **2.2** Add `GET /compliance/projects/:projectId/documents/:documentId/content` to controller.
  - Returns `{ html: string }` with `Content-Type: application/json`.
  - File: `src/compliance/compliance.controller.ts`
- [ ] **2.3** Create response DTO `DocumentContentResponseDto`.
  - File: `src/compliance/dto/document-content-response.dto.ts`
- [ ] **2.4** Unit test for service method (mock MinIO download).
  - File: `src/compliance/compliance.service.spec.ts`
- [ ] **2.5** Controller spec for the new route.
  - File: `src/compliance/compliance.controller.spec.ts`

---

### Phase 3 — Delete source document [BACKEND_DB]

```phase-meta
phase: 3
title: Delete source document
tags: [BACKEND_DB]
repo: rohan_api
base_branch: phase-1
depends_on: [1]
files:
  - src/compliance/compliance.service.ts
  - src/compliance/compliance.service.spec.ts
  - src/compliance/compliance.controller.ts
  - src/compliance/compliance.controller.spec.ts
contracts:
  - "1.2 DELETE document endpoint"
  - "6 Error responses"
verification:
  - npm run lint
  - npm run test -- src/compliance/compliance.service.spec.ts
  - npm run test -- src/compliance/compliance.controller.spec.ts
```

**Goal**: New endpoint to delete a source document and its associated compliance items.

**Steps**:

- [ ] **3.1** Add `deleteSourceDocument(projectId, documentId, user)` to `ComplianceService`.
  - Verify the document belongs to the project (via `compliance_project_documents` join table).
  - Delete the MinIO objects (original file + converted HTML if present).
  - Delete the `ComplianceDocument` row (DB cascade removes items, checks, evidence, join table rows).
  - Audit-log the deletion.
  - File: `src/compliance/compliance.service.ts`
- [ ] **3.2** Add `DELETE /compliance/projects/:projectId/documents/:documentId` to controller.
  - Returns 204 No Content on success.
  - File: `src/compliance/compliance.controller.ts`
- [ ] **3.3** Unit test for service method (mock repo + MinIO).
  - File: `src/compliance/compliance.service.spec.ts`
- [ ] **3.4** Controller spec for the new route.
  - File: `src/compliance/compliance.controller.spec.ts`

---

### Phase 4 — Per-document auto-tagging [BACKEND_DB]

```phase-meta
phase: 4
title: Per-document auto-tagging
tags: [BACKEND_DB]
repo: rohan_api
base_branch: phase-1
depends_on: [1]
files:
  - src/compliance/compliance.service.ts
  - src/compliance/compliance.service.spec.ts
  - src/compliance/compliance.controller.ts
  - src/compliance/compliance.controller.spec.ts
contracts:
  - "1.3 POST process endpoint"
  - "6 Error responses"
verification:
  - npm run lint
  - npm run test -- src/compliance/compliance.service.spec.ts
  - npm run test -- src/compliance/compliance.controller.spec.ts
```

**Goal**: New endpoint to trigger auto-tagging for a single document (overview-page upload flow).

The existing bulk `POST .../documents/process` (wizard flow) remains unchanged. The new per-document endpoint avoids touching the project-level `autotag_processing` status and keeps the two flows cleanly separated.

Per the [Auto-Tagging Flow and Integration Guide](https://rohan.atlassian.net), the compliance module owns _when_ to request tagging and _how_ to react when it finishes. `TaggingService.requestAutoTag()` handles the Service Bus message, `TaggableDocument` row creation, and tag config resolution. The completion is handled by the existing `ComplianceListener.handleAutoTagComplete` — no changes needed there since it already processes per-document events.

**Steps**:

- [ ] **4.1** Add `processDocument(projectId, documentId, user)` method to `ComplianceService`.
  - Verify document belongs to project via `compliance_project_documents`.
  - Set the document's `processingStatus` to `extracting`.
  - Call `TaggingService.requestAutoTag()` with the document's `minioObjectKey`, `ProductCode.COMPLIANCE`, `StorageType.MINIO`.
  - Save the returned `taggableDocId` on the `ComplianceDocument`.
  - Do **not** modify the project-level `autotag_processing` flag (that's only for the wizard's bulk flow).
  - Audit-log the per-document processing trigger.
  - File: `src/compliance/compliance.service.ts`
- [ ] **4.2** Add skip-already-tagged guard to the existing bulk `requestAutoTagging()` method.
  - When iterating source documents, skip any document that already has a `taggable_doc_id` set (meaning it was already sent to the tagging service in a previous run). Only new/unprocessed documents should be auto-tagged.
  - This ensures that when the wizard's Finish button is clicked again after adding new documents, previously processed documents are not re-processed.
  - File: `src/compliance/compliance.service.ts`
- [ ] **4.3** Add `POST /compliance/projects/:projectId/documents/:documentId/process` to controller.
  - Returns 202 Accepted.
  - File: `src/compliance/compliance.controller.ts`
- [ ] **4.4** Unit test for `processDocument` method and skip-already-tagged guard.
  - File: `src/compliance/compliance.service.spec.ts`
- [ ] **4.5** Controller spec for the new route.
  - File: `src/compliance/compliance.controller.spec.ts`

---

### Phase 5 — Frontend API service + types [FRONTEND]

```phase-meta
phase: 5
title: Frontend API service and types
tags: [FRONTEND]
repo: rohan_ui
base_branch: base
depends_on: [2, 3, 4]
files:
  - src/app/pages/compliance/services/compliance-api.service.ts
  - src/app/pages/compliance/services/compliance-api.service.spec.ts
  - src/app/pages/compliance/types/compliance-project.types.ts
contracts:
  - "5.1 ComplianceDocument (modified)"
  - "5.2 DocumentContentResponse"
verification:
  - npm run lint
  - ng test --include=**/compliance-api.service.spec.ts --watch=false
```

**Goal**: Add HTTP methods and update types so the viewer and overview page can consume the new endpoints.

**Steps**:

- [ ] **5.1** Add `getDocumentContent(projectId, documentId): Observable<DocumentContentResponse>` to `ComplianceApiService`.
  - File: `src/app/pages/compliance/services/compliance-api.service.ts`
- [ ] **5.2** Add `deleteSourceDocument(projectId, documentId): Observable<void>` to `ComplianceApiService`.
  - File: `src/app/pages/compliance/services/compliance-api.service.ts`
- [ ] **5.3** Add `processDocument(projectId, documentId): Observable<void>` to `ComplianceApiService`.
  - Calls `POST /compliance/projects/:projectId/documents/:documentId/process`.
  - File: `src/app/pages/compliance/services/compliance-api.service.ts`
- [ ] **5.4** Add `DocumentContentResponse` interface (or inline).
  - File: `src/app/pages/compliance/types/compliance-project.types.ts`
- [ ] **5.5** Add `processingStatus` to `ComplianceDocument` frontend type (needed to show loading/error state per document).
  - File: `src/app/pages/compliance/types/compliance-project.types.ts`
- [ ] **5.6** Unit tests for new service methods.
  - File: `src/app/pages/compliance/services/compliance-api.service.spec.ts`

---

### Phase 6 — HTML document viewer using shared `app-doc-shell` [FRONTEND]

```phase-meta
phase: 6
title: HTML document viewer via doc-shell
tags: [FRONTEND]
repo: rohan_ui
base_branch: phase-5
depends_on: [5]
files:
  - src/app/pages/compliance/components/document-viewer-panel/document-viewer-panel.component.html
  - src/app/pages/compliance/components/document-viewer-panel/document-viewer-panel.component.ts
  - src/app/pages/compliance/components/document-viewer-panel/document-viewer-panel.component.spec.ts
  - src/app/pages/compliance/services/compliance-state.service.ts
  - src/app/pages/compliance/utils/compliance-document.utils.ts
  - src/app/pages/compliance/utils/compliance-document.utils.spec.ts
  - src/app/pages/compliance/types/compliance-item.types.ts
  - src/app/shared-services/tagging/tagging.service.ts
  - src/app/pages/compliance/components/pdf-highlight-overlay/
  - src/app/pages/compliance/compliance.module.ts
contracts:
  - "5.3 ComplianceSourceDocument (modified)"
  - "5.x InlineTag (reference)"
  - "5.5 CreateComplianceItemSelection"
  - "5.7 HighlightRegion (removed)"
verification:
  - npm run lint
  - ng test --include=**/document-viewer-panel.component.spec.ts --watch=false
  - ng test --include=**/compliance-document.utils.spec.ts --watch=false
```

**Goal**: Replace the line-based mock viewer with the shared `app-doc-shell` component that the Proposal Writer already uses for document rendering and tagging.

`app-doc-shell` (in `shared-components/document-shredding/`) already provides:

- HTML rendering via `[innerHTML]` + DOMPurify + `bypassSecurityTrustHtml`
- Offset-based `<mark>` highlighting via `syncOffsetHighlights()` / `applyOffsetHighlight()`
- Text selection → flattened-text offset computation via `buildFlattenedOffsetsByTextNode()`
- Hover state syncing between highlights and the tag layer
- CSS for tables, figures, images, and highlight marks via `::ng-deep`

The flattened-text offset algorithm in `doc-shell` is **identical** to Python's `extract_text_with_mapping()` — same block selectors (`h1-h6, p, li, tr, td, span`), same single-space separator between blocks. Offsets stored on compliance items are directly compatible.

**Steps**:

- [ ] **6.1** Update `ComplianceStateService` to load HTML content per document.
  - When `selectedDocumentId` changes, call `complianceApi.getDocumentContent(projectId, documentId)`.
  - Store the loaded HTML in a signal (`_documentHtmlContent`).
  - Handle loading state and errors (409 = still processing, 404 = not converted).
  - **Cache invalidation**: When `processDocument()` is called for a document, clear its cached HTML so the next selection triggers a fresh fetch.
  - File: `src/app/pages/compliance/services/compliance-state.service.ts`
- [ ] **6.2** Replace `document.lines` rendering in the viewer template with `app-doc-shell`.
  - Replace the `@for (line of document.lines)` block and `app-pdf-highlight-overlay` with `<app-doc-shell [htmlSource]="..." [tags]="..." (tagSelection)="...">`.
  - Show loading spinner while HTML is being fetched.
  - Show "Processing…" placeholder for documents with `processingStatus !== extraction_complete`. Include a polling mechanism: when the viewer shows the processing state, poll `getDocumentContent()` on an interval (e.g., every 5 seconds) until the document is ready or fails. Stop polling when the user switches documents or navigates away.
  - Show error state for failed documents.
  - File: `src/app/pages/compliance/components/document-viewer-panel/document-viewer-panel.component.html`
  - File: `src/app/pages/compliance/components/document-viewer-panel/document-viewer-panel.component.ts`
- [ ] **6.3** Map compliance items to `InlineTag[]` for `doc-shell`.
  - Each `ComplianceItemView` with `documentStartLine` / `documentEndLine` (offsets) maps to an `InlineTag` with `startOffset` / `endOffset`, `id`, `color`, `label`.
  - Colour mapping: cyan (selected), teal (approved), muted (other) — translate to hex for `InlineTag.color`.
  - **Implementation note**: `InlineTag` has required `x` and `y` fields. Verify during implementation that `doc-shell`'s `syncOffsetHighlights()` does not use them for offset-based highlighting (they appear to be used only by `TagLayerComponent` for chip positioning, which compliance does not use). If confirmed, set both to `0`.
  - File: `src/app/pages/compliance/components/document-viewer-panel/document-viewer-panel.component.ts`
- [ ] **6.4** Handle `tagSelection` output from `doc-shell`.
  - `doc-shell` emits a `TemplateTagEvent` with `startOffset`, `endOffset`, `selectionText`.
  - Map this to `CreateComplianceItemSelection` and call `complianceState.addManualItem()`.
  - Replace the existing `onSelectionMouseUp()` / `pendingSelection` / selection-action-popover logic.
  - File: `src/app/pages/compliance/components/document-viewer-panel/document-viewer-panel.component.ts`
- [ ] **6.5** Configure `TaggingService` with a compliance-specific tag config for the `COMPLIANCE` product code.
  - `doc-shell` injects `TaggingService` directly and uses it to resolve the context menu config. Register a compliance-specific `TagConfigResponse` with `TaggingService` for `ProductCode.COMPLIANCE` containing a single tag entry (e.g., `tag_type: 'compliance_item'`, `display_name: 'Add Compliance Item'`).
  - Verify how `doc-shell` resolves its tag config (product-code-based lookup vs. static injection) and wire accordingly. If `TaggingService` doesn't support product-code-based config resolution, extend it or provide an alternative mechanism.
  - File: `src/app/shared-services/tagging/tagging.service.ts` (if extending)
  - File: `src/app/pages/compliance/components/document-viewer-panel/document-viewer-panel.component.ts`
- [ ] **6.6** Scroll-to-highlight: when an item is selected in the items panel, scroll the viewer to the corresponding `<mark data-tag-id="...">` element.
  - File: `src/app/pages/compliance/components/document-viewer-panel/document-viewer-panel.component.ts`
- [ ] **6.7** Update `ComplianceSourceDocument` type — remove `lines`, `pageNumber`, `totalPages`; add `processingStatus`.
  - Deprecate or remove `ComplianceSourceDocumentLine`.
  - File: `src/app/pages/compliance/types/compliance-item.types.ts`
- [ ] **6.8** Rewrite `mapProjectDocumentsToViewerDocuments()` to build `ComplianceSourceDocument` from project documents **without** mock data.
  - Remove import and usage of `MOCK_COMPLIANCE_DOCUMENTS`.
  - File: `src/app/pages/compliance/utils/compliance-document.utils.ts`
- [ ] **6.9** Update `compliance-document.utils.spec.ts` tests.
  - File: `src/app/pages/compliance/utils/compliance-document.utils.spec.ts`
- [ ] **6.10** Remove or retire `app-pdf-highlight-overlay` component (no longer needed — `doc-shell` handles highlighting).
  - File: `src/app/pages/compliance/components/pdf-highlight-overlay/` (all files)
- [ ] **6.11** Verify `SharedComponentsModule` is already imported in `ComplianceModule` (it is — `app-doc-shell` is already available, no changes needed).
  - File: `src/app/pages/compliance/compliance.module.ts`

---

### Phase 7 — Compliance-specific viewer polish [FRONTEND]

```phase-meta
phase: 7
title: Compliance-specific viewer polish
tags: [FRONTEND]
repo: rohan_ui
base_branch: phase-6
depends_on: [6]
files:
  - src/app/pages/compliance/components/document-viewer-panel/document-viewer-panel.component.ts
  - src/app/pages/compliance/components/document-viewer-panel/document-viewer-panel.component.spec.ts
  - src/app/pages/compliance/components/compliance-list-creator/compliance-list-creator.component.ts
contracts: []
verification:
  - npm run lint
  - ng test --include=**/document-viewer-panel.component.spec.ts --watch=false
```

**Goal**: Fine-tune the `doc-shell` integration for compliance-specific UX that differs from the Proposal Writer.

Since `doc-shell` provides rendering, highlighting, and offset computation out of the box, this phase focuses on the delta between Proposal Writer tagging UX and Compliance tagging UX.

**Steps**:

- [ ] **7.1** Compliance highlight colour scheme.
  - `doc-shell` uses `InlineTag.color` (hex with alpha) for highlights. Map compliance status colours:
    - Selected item → cyan highlight
    - Approved → teal highlight
    - Other → muted/grey highlight
  - File: `src/app/pages/compliance/components/document-viewer-panel/document-viewer-panel.component.ts`
- [ ] **7.2** Verify the single-item tag config renders cleanly in the context menu (no unnecessary indent, correct label).
  - File: `src/app/pages/compliance/components/document-viewer-panel/document-viewer-panel.component.ts`
- [ ] **7.3** Update the compliance items panel ↔ viewer interaction.
  - Clicking an item in the items panel should highlight + scroll to its mark in the viewer.
  - Hovering an item in the panel should activate the `.hl-active` state on its marks (already built into `doc-shell`'s hover system, but may need wiring from the compliance side).
  - File: `src/app/pages/compliance/components/compliance-list-creator/compliance-list-creator.component.ts`
- [ ] **7.4** Component tests for the updated viewer panel.
  - File: `src/app/pages/compliance/components/document-viewer-panel/document-viewer-panel.component.spec.ts`

---

### Phase 8 — Overview page Document Library: upload and delete [FRONTEND]

```phase-meta
phase: 8
title: Overview page upload and delete
tags: [FRONTEND]
repo: rohan_ui
base_branch: phase-7
depends_on: [3, 4, 5]
files:
  - src/app/pages/compliance/components/project-snapshot-content/project-snapshot-content.component.html
  - src/app/pages/compliance/components/project-snapshot-content/project-snapshot-content.component.ts
  - src/app/pages/compliance/components/project-snapshot-content/project-snapshot-content.component.spec.ts
  - src/app/pages/compliance/components/compliance-document-table/compliance-document-table.component.html
  - src/app/pages/compliance/components/compliance-document-table/compliance-document-table.component.ts
  - src/app/pages/compliance/components/compliance-document-table/compliance-document-table.component.spec.ts
  - src/app/pages/compliance/components/compliance-project-overview-page/compliance-project-overview-page.component.ts
  - src/app/pages/compliance/components/project-overview-tab/project-overview-tab.component.ts
contracts: []
verification:
  - npm run lint
  - ng test --include=**/project-snapshot-content.component.spec.ts --watch=false
  - ng test --include=**/compliance-document-table.component.spec.ts --watch=false
```

**Goal**: Allow users to upload new documents and delete existing ones from the project overview page.

**Steps**:

- [ ] **8.1** Add `app-document-upload` component to the Document Library section of the overview page.
  - Wire the upload output to `ComplianceApiService.uploadSourceDocument()`.
  - After upload completes, call `ComplianceApiService.processDocument(projectId, documentId)` for the new document (per-document endpoint from Phase 4).
  - Refresh the project to update the document list.
  - File: `src/app/pages/compliance/components/project-snapshot-content/project-snapshot-content.component.html`
  - File: `src/app/pages/compliance/components/project-snapshot-content/project-snapshot-content.component.ts`
- [ ] **8.2** Update `compliance-document-table` to include a delete button per row.
  - Emit a `deleteDocument` event with the document ID.
  - File: `src/app/pages/compliance/components/compliance-document-table/compliance-document-table.component.html`
  - File: `src/app/pages/compliance/components/compliance-document-table/compliance-document-table.component.ts`
- [ ] **8.3** Wire delete button through to `ComplianceApiService.deleteSourceDocument()`.
  - No confirmation dialog — delete immediately on click.
  - Refresh the project after successful deletion.
  - File: `src/app/pages/compliance/components/compliance-project-overview-page/compliance-project-overview-page.component.ts`
  - File: `src/app/pages/compliance/components/project-overview-tab/project-overview-tab.component.ts`
- [ ] **8.4** Show `processingStatus` badges on documents in the table (e.g., "Processing…", "Ready", "Failed").
  - File: `src/app/pages/compliance/components/compliance-document-table/compliance-document-table.component.html`
- [ ] **8.5** Component tests for upload and delete flows.
  - File: `src/app/pages/compliance/components/project-snapshot-content/project-snapshot-content.component.spec.ts`
  - File: `src/app/pages/compliance/components/compliance-document-table/compliance-document-table.component.spec.ts`

---

### Phase 9 — Cleanup and mock removal [FRONTEND]

```phase-meta
phase: 9
title: Cleanup and mock removal
tags: [FRONTEND]
repo: rohan_ui
base_branch: phase-8
depends_on: [6]
files:
  - src/app/pages/compliance/mocks/compliance-item-mock-data.ts
  - src/app/pages/compliance/utils/compliance-document.utils.ts
  - src/app/pages/compliance/utils/compliance-document.utils.spec.ts
contracts:
  - "5.4 ComplianceSourceDocumentLine (deprecated)"
verification:
  - npm run lint
  - ng test --include=**/compliance-document.utils.spec.ts --watch=false
```

**Goal**: Remove all mock/hardcoded document data now that real content is served.

**Steps**:

- [ ] **9.1** Delete `MOCK_COMPLIANCE_DOCUMENTS`, `PRIMARY_DOCUMENT_LINES`, `SECONDARY_DOCUMENT_LINES`, `TERTIARY_DOCUMENT_LINES` from mock data file. Keep `ITEM_SEEDS` if still needed by tests.
  - File: `src/app/pages/compliance/mocks/compliance-item-mock-data.ts`
- [ ] **9.2** Remove the `toViewerDocument` fallback parameter and mock-rotation logic from `compliance-document.utils.ts`.
  - File: `src/app/pages/compliance/utils/compliance-document.utils.ts`
- [ ] **9.3** Update any tests that depended on mock document lines.
  - File: `src/app/pages/compliance/utils/compliance-document.utils.spec.ts`

---

### Phase 10 — Integration / E2E tests [TEST_REVIEW]

```phase-meta
phase: 10
title: Integration and E2E tests
tags: [TEST_REVIEW]
repo: rohan_api
base_branch: base
depends_on: [1, 2, 3, 4, 5, 6, 7, 8, 9]
files:
  - test/compliance.e2e-spec.ts
contracts: []
verification:
  - npm run test:e2e:ci
```

**Goal**: End-to-end confidence that upload → convert → view → tag → delete works across the stack.

**Steps**:

- [ ] **10.1** Backend E2E: upload a document, trigger process, wait for auto-tag completion, GET content, verify HTML returned.
  - File: `test/compliance.e2e-spec.ts`
- [ ] **10.2** Backend E2E: delete a document, verify compliance items are cascade-deleted.
  - File: `test/compliance.e2e-spec.ts`
- [ ] **10.3** Frontend E2E (Playwright, if in scope): navigate to compliance creator, verify real document HTML loads, select text, create manual item, verify highlight appears.
  - File: TBD (Playwright test repo)

---

## Phase Order and Parallelism

### Files touched per phase

| Phase  | Repo        | Key files                                                                                                                                                                      |
| ------ | ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **1**  | `rohan_api` | `compliance-document.entity.ts`, `compliance.listener.ts`, `compliance.listener.spec.ts`                                                                                       |
| **2**  | `rohan_api` | `compliance.controller.ts`, `compliance.service.ts`, `document-content-response.dto.ts` (new)                                                                                  |
| **3**  | `rohan_api` | `compliance.controller.ts`, `compliance.service.ts`                                                                                                                            |
| **4**  | `rohan_api` | `compliance.controller.ts`, `compliance.service.ts`                                                                                                                            |
| **5**  | `rohan_ui`  | `compliance-api.service.ts`, `compliance-project.types.ts`                                                                                                                     |
| **6**  | `rohan_ui`  | `document-viewer-panel.component.*`, `compliance-state.service.ts`, `compliance-document.utils.ts`, `compliance-item.types.ts`, `tagging.service.ts`, `pdf-highlight-overlay/` |
| **7**  | `rohan_ui`  | `document-viewer-panel.component.*`, `compliance-list-creator.component.ts`                                                                                                    |
| **8**  | `rohan_ui`  | `project-snapshot-content.component.*`, `compliance-document-table.component.*`, `compliance-project-overview-page.component.ts`                                               |
| **9**  | `rohan_ui`  | `compliance-item-mock-data.ts`, `compliance-document.utils.ts`                                                                                                                 |
| **10** | `rohan_api` | `compliance.e2e-spec.ts`, Playwright tests                                                                                                                                     |

### Parallelism

- **Phases 2, 3, 4** can run in parallel — they all add methods to `compliance.controller.ts` and `compliance.service.ts`, but different methods. If done by the same developer, do them sequentially within a single PR. If split across developers, coordinate on merge order.
- **Phase 5** depends on Phases 2 + 3 + 4 (needs all three endpoint contracts finalized).
- **Phases 6 + 8** can run in parallel — they touch different components. Phase 6 touches the viewer; Phase 8 touches the overview page.
- **Phase 7** depends on Phase 6 (needs the HTML viewer in place).
- **Phase 9** depends on Phase 6 (mock data must not be removed until the HTML viewer replaces it).
- **Phase 10** depends on all other phases.

### Recommended sequential order (single developer)

1. **Phase 1** (DB + entity) — foundation, small PR
2. **Phase 4** (per-doc auto-tag) — needed before Phase 8 but independent of 2/3
3. **Phase 2** (serve HTML) — depends on Phase 1
4. **Phase 3** (delete doc) — can follow Phase 2 in the same PR or separate
5. **Phase 5** (FE API + types) — depends on 2 + 3
6. **Phase 6** (HTML viewer) — biggest FE change, depends on 5
7. **Phase 7** (highlighting) — depends on 6
8. **Phase 8** (overview upload/delete) — depends on 3, 4, 5; can be done in parallel with 7
9. **Phase 9** (cleanup) — after 6 is merged
10. **Phase 10** (E2E) — final

> **Stacking note**: When following the recommended order as a single developer, create branches linearly (each new phase stacks on the last created, regardless of phase number). The `base_branch` in phase-meta reflects the _logical_ dependency; the stacked-branches skill will resolve the actual branch base at creation time.

**Rationale**: DB and entity changes go first because everything else depends on the `convertedHtmlKey` column. The per-document filter (Phase 4) is small and unblocks the overview page upload flow. The HTML viewer (Phase 6) is the critical-path item with the most risk, so it should start as soon as the backend is ready. Highlighting (Phase 7) builds on the viewer but can be iterated on incrementally.

---

## Phase Context Summaries

**Phase 1 — Store converted HTML key**: Adds the `converted_html_key` nullable VARCHAR(500) column to `compliance_documents` and the corresponding `convertedHtmlKey` property on the TypeORM entity. Updates `handleAutoTagComplete` in the compliance listener to persist the MinIO key from the `convertedHtmlUrl` field on the auto-tag completion event. Adds a guard against late-arriving completion events for documents deleted during processing. No prior-phase dependencies. Gotcha: `convertedHtmlUrl` from the event may be a full Azure Blob HTTPS URL — extract the object path if so.

**Phase 2 — Serve document HTML content**: Adds `GET /compliance/projects/:projectId/documents/:documentId/content` that reads converted HTML from MinIO via `BlobStorageService.downloadBuffer()` and returns `{ html, documentId, processingStatus }`. Creates `DocumentContentResponseDto`. Depends on Phase 1 for the `convertedHtmlKey` column on the entity. Gotcha: large HTML payloads for documents with embedded base64 images; gzip compression mitigates this.

**Phase 3 — Delete source document**: Adds `DELETE /compliance/projects/:projectId/documents/:documentId` returning 204. Deletes MinIO objects (original file + converted HTML via `convertedHtmlKey`) and the DB row, relying on `ON DELETE CASCADE` for items/checks/evidence. Depends on Phase 1 for `convertedHtmlKey` (to know which MinIO HTML object to clean up). Gotcha: MinIO delete is best-effort; 204 returned even if MinIO cleanup fails.

**Phase 4 — Per-document auto-tagging**: Adds `POST /compliance/projects/:projectId/documents/:documentId/process` returning 202. Sets `processingStatus` to `extracting`, calls `TaggingService.requestAutoTag()`, saves the returned `taggableDocId`. Also adds a skip-already-tagged guard to the existing bulk `requestAutoTagging()` so re-running Finish only processes new documents. Depends on Phase 1 (entity). Gotcha: does NOT touch the project-level `autotag_processing` flag — that's exclusively for the wizard's bulk flow.

**Phase 5 — Frontend API service and types**: Adds `getDocumentContent()`, `deleteSourceDocument()`, and `processDocument()` methods to `ComplianceApiService`. Adds `DocumentContentResponse` interface and `processingStatus` field to the frontend `ComplianceDocument` type. Depends on Phases 2, 3, 4 for the endpoint contracts (cross-repo dependency — backend must be deployed or running locally). No major gotchas.

**Phase 6 — HTML document viewer via doc-shell**: The largest phase. Replaces the mock line-by-line viewer with `app-doc-shell` from `shared-components/document-shredding/`. Loads HTML on demand via `getDocumentContent()` in `ComplianceStateService`. Maps `ComplianceItemView[]` to `InlineTag[]` for offset-based highlighting. Handles text selection via `tagSelection` output for manual item creation. Removes `app-pdf-highlight-overlay`. Depends on Phase 5. Gotchas: `InlineTag.x`/`y` set to 0 (unused for offset mode); must configure `TaggingService` with a compliance-specific tag config for `ProductCode.COMPLIANCE`; polling needed for "Processing" state.

**Phase 7 — Compliance-specific viewer polish**: Fine-tunes the doc-shell integration for compliance UX: highlight colour scheme (cyan selected, teal approved, muted other), context menu verification (single "Add Compliance Item" action), and bidirectional items panel ↔ viewer interaction (click → scroll to mark, hover → `.hl-active` state). Depends on Phase 6. No major gotchas — mostly wiring and CSS.

**Phase 8 — Overview page upload and delete**: Adds `app-document-upload` to the Document Library section on the overview page. Wires upload to trigger per-document auto-tagging (Phase 4's endpoint). Adds a delete button per row in `compliance-document-table`, wired to `deleteSourceDocument()`. Shows processing status badges. Depends on Phases 3, 4, 5. Gotcha: no confirmation dialog on delete — immediate action.

**Phase 9 — Cleanup and mock removal**: Removes `MOCK_COMPLIANCE_DOCUMENTS` and related mock constants. Strips the fallback/mock-rotation logic from `mapProjectDocumentsToViewerDocuments()`. Updates tests. Depends on Phase 6 (mock data must not be removed until the HTML viewer replaces it). Straightforward cleanup — low risk.

**Phase 10 — Integration and E2E tests**: Backend E2E tests for the full document lifecycle: upload → process → GET content → verify HTML, and delete → verify cascade. Optional Playwright tests for the frontend viewer flow. Depends on all prior phases being complete and deployed. Should be implemented after all PRs are merged to the base branch.

---

## Jira Ticket Breakdown

### Ticket 1: Store converted HTML key on compliance documents

**Title**: [BACKEND_DB] Persist converted HTML MinIO key on compliance_documents

**Description**: Add a `converted_html_key` column to the `compliance_documents` table and TypeORM entity. Update the compliance auto-tag-complete listener to save the `convertedHtmlUrl` from the event payload onto the document. This is the foundation for serving real document content to the viewer.

**Acceptance criteria**:

- New nullable VARCHAR(500) column `converted_html_key` exists on `compliance_documents`.
- After a successful auto-tag completion, the compliance document row has a non-null `converted_html_key`.
- If the document was deleted while auto-tagging was in progress, the completion handler logs a warning and skips item creation (no FK violation).
- Unit tests verify the key is persisted and the deleted-document guard works.

**Phases**: 1

---

### Ticket 2: Serve document HTML content endpoint

**Title**: [BACKEND_DB] GET endpoint to retrieve converted document HTML

**Description**: Add `GET /compliance/projects/:projectId/documents/:documentId/content` that reads the converted HTML from MinIO and returns it. Returns 409 if the document is still processing, 404 if not found or not converted.

**Acceptance criteria**:

- Endpoint returns `{ html: string }` for a fully-processed document.
- Returns 409 with descriptive message for documents still processing.
- Returns 404 for unknown document or missing HTML.
- Verifies document belongs to the specified project.
- Unit + controller tests.

**Phases**: 2

---

### Ticket 3: Delete source document endpoint

**Title**: [BACKEND_DB] DELETE endpoint for compliance source documents

**Description**: Add `DELETE /compliance/projects/:projectId/documents/:documentId` that removes a source document, its MinIO objects, and lets DB cascade delete compliance items, checks, and evidence.

**Acceptance criteria**:

- Endpoint returns 204 on success.
- MinIO objects (original file + converted HTML) are deleted.
- DB cascade removes all associated compliance items.
- Returns 404 if document not found or doesn't belong to project.
- Unit + controller tests.

**Phases**: 3

---

### Ticket 4: Per-document auto-tagging endpoint

**Title**: [BACKEND_DB] New endpoint to trigger auto-tagging for a single document

**Description**: Add `POST /compliance/projects/:projectId/documents/:documentId/process` that triggers auto-tagging for one document. This supports the overview-page upload flow where only the newly added document should be tagged. Also add a skip-already-tagged guard to the existing bulk `requestAutoTagging()` so re-running Finish only processes new documents. Uses `TaggingService.requestAutoTag()` directly — does not modify the project-level `autotag_processing` flag.

**Acceptance criteria**:

- Endpoint returns 202 Accepted.
- Document's `processingStatus` is set to `extracting`.
- `TaggingService.requestAutoTag()` is called with the document's MinIO key.
- `taggable_doc_id` is saved on the document after the request.
- Returns 404 if document not found or doesn't belong to project.
- Existing bulk process endpoint is unaffected but now skips documents that already have a `taggable_doc_id`.
- Per-document processing is audit-logged.
- Unit + controller tests.

**Phases**: 4

---

### Ticket 5: Frontend API service and types for document content, delete, and per-doc process

**Title**: [FRONTEND] Add HTTP methods and types for document content, deletion, and per-doc processing

**Description**: Add `getDocumentContent()`, `deleteSourceDocument()`, and `processDocument()` methods to `ComplianceApiService`. Add `DocumentContentResponse` type and `processingStatus` to the `ComplianceDocument` frontend type.

**Acceptance criteria**:

- `getDocumentContent(projectId, documentId)` calls GET endpoint and returns `{ html: string }`.
- `deleteSourceDocument(projectId, documentId)` calls DELETE endpoint.
- `processDocument(projectId, documentId)` calls POST per-document process endpoint.
- `ComplianceDocument` type includes `processingStatus`.
- Unit tests for new methods.

**Phases**: 5

---

### Ticket 6: Replace line-based viewer with shared `app-doc-shell` component

**Title**: [FRONTEND] Render real document HTML using the shared doc-shell component

**Description**: Replace the mock line-by-line text rendering in `document-viewer-panel.component` with the shared `app-doc-shell` component (from `shared-components/document-shredding/`), the same component the Proposal Writer uses. Load HTML content via the new `getDocumentContent()` API. Map compliance items to `InlineTag[]` for the doc-shell's built-in offset-based highlighting. Handle text selection via doc-shell's `tagSelection` output to create manual compliance items. Show loading/processing/error states. Remove `app-pdf-highlight-overlay` (superseded by doc-shell's highlighting). Remove mock data dependency.

**Acceptance criteria**:

- Viewer displays the actual document HTML for each selected document via `app-doc-shell`.
- Auto-tagged and manual compliance items are highlighted at their character offsets.
- Text selection in the viewer creates a compliance item with correct offsets.
- Loading spinner while HTML is being fetched.
- "Processing…" placeholder for documents still being processed.
- Error state for failed documents.
- Document dropdown still works.
- Docling tables, headings, and paragraphs render correctly.
- `app-pdf-highlight-overlay` removed or deprecated.
- `SharedComponentsModule` already imported in `ComplianceModule` (verified — `app-doc-shell` is available).
- `TaggingService` configured with a compliance-specific tag config for `ProductCode.COMPLIANCE`.

**Phases**: 6

---

### Ticket 7: Compliance-specific viewer polish

**Title**: [FRONTEND] Fine-tune doc-shell integration for compliance UX

**Description**: Adapt the shared `app-doc-shell` component's behaviour to compliance-specific needs: colour scheme (cyan/teal/muted), simplified tag context menu (single "Add Compliance Item" action vs. Proposal Writer's multi-tag menu), panel ↔ viewer interaction (click item → scroll to highlight, hover sync).

**Acceptance criteria**:

- Compliance highlight colours: cyan (selected), teal (approved), muted (other).
- Tag selection produces a compliance item directly (single action, not tag-type picker).
- Clicking an item in the items panel scrolls the viewer to its highlight.
- Hovering an item in the panel highlights the corresponding mark in the viewer.
- Component tests for the updated viewer panel.

**Phases**: 7

---

### Ticket 8: Overview page — upload and delete documents

**Title**: [FRONTEND] Add document upload and delete to the project overview page

**Description**: Add the `app-document-upload` drag-and-drop component to the Document Library section on the overview page. Add a delete button per document row in `compliance-document-table`. After uploading, call the per-document process endpoint to auto-tag the new document. Show processing status badges. No confirmation dialog on delete.

**Acceptance criteria**:

- Users can drag-and-drop or pick files to upload from the overview page (same UX as wizard).
- Upload triggers auto-tagging for only the new document via `processDocument()`.
- Delete button appears on each document row; deletes immediately (no confirmation).
- Processing status badge per document (Processing / Ready / Failed).
- Document list refreshes after upload or delete.
- Viewer polls `getDocumentContent()` on an interval (e.g., every 5s) when showing the "Processing" state; stops when ready or failed.
- Component tests.

**Phases**: 8

---

### Ticket 9: Remove mock document data

**Title**: [FRONTEND] Clean up mock compliance document lines

**Description**: Delete `MOCK_COMPLIANCE_DOCUMENTS` and associated constants. Remove fallback logic from `toViewerDocument()`. Update tests.

**Acceptance criteria**:

- No mock document line data remains in production code.
- `mapProjectDocumentsToViewerDocuments()` works without fallback mock data.
- All tests pass.

**Phases**: 9

---

### Ticket 10: E2E tests for document viewer and management

**Title**: [TEST_REVIEW] End-to-end tests for document lifecycle

**Description**: Add backend E2E tests for document content retrieval and cascade deletion. Optionally add Playwright tests for the viewer flow.

**Acceptance criteria**:

- E2E test: upload → process → GET content → verify HTML.
- E2E test: delete document → verify items cascade-deleted.
- Tests pass in CI.

**Phases**: 10
