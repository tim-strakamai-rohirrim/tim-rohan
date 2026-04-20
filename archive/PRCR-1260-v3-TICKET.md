# PRCR-1260 — Real Document Viewer, Manual Tagging, and Document Management

**Type**: Story
**Priority**: High
**Components**: `rohan_api`, `rohan_ui`, `Database`
**Labels**: `compliance`, `document-viewer`, `tagging`

---

## Summary

Replace the hardcoded mock document viewer in the Compliance List Creator with a real document rendering pipeline. Users can view actual document content (PDF, DOCX, XLSX converted to HTML via Docling), manually highlight text to create compliance items, and manage documents (upload/delete) from the project overview page — all integrated with the existing auto-tagging system.

---

## Background

The `document-viewer-panel` component currently displays mock/hardcoded text lines via `MOCK_COMPLIANCE_DOCUMENTS`. The `mapProjectDocumentsToViewerDocuments()` utility maps project documents onto static mock data with a TODO to replace it. Meanwhile, the Docling auto-tag pipeline already converts uploaded documents to stripped HTML and stores it in MinIO, but the converted HTML key is never persisted on the compliance document entity — making it inaccessible to the frontend.

The shared `app-doc-shell` component (used by the Proposal Writer) already provides HTML rendering with DOMPurify sanitization, offset-based `<mark>` highlighting, and text-selection-to-offset computation. The flattened-text offset algorithm in `doc-shell` is identical to the Python auto-tag pipeline's `extract_text_with_mapping()`, so compliance item offsets are directly compatible.

**Prerequisite**: The `tagging-redesign` branch has been merged to `main` in both repos. Key dependencies include the refactored `InlineTag` interface (flat-text offsets), `BlobStorageService` in the compliance module, and the `DocumentTag`-based compliance listener. Post-merge, the upload endpoint already auto-triggers processing and the listener has a skip-already-tagged guard.

---

## Scope of Work

### Backend (rohan_api)

1. **Store converted HTML key** — Add a nullable `converted_html_key VARCHAR(500)` column to `compliance_documents` (DB + TypeORM entity). Update `ComplianceListener.handleAutoTagComplete` to persist the MinIO key from the `convertedHtmlUrl` field on the auto-tag completion event. Add a guard against late-arriving completion events for documents deleted during processing (prevents FK violations).

2. **Serve document HTML content** — New `GET /compliance/projects/:projectId/documents/:documentId/content` endpoint. Reads converted HTML from MinIO via `BlobStorageService.downloadBuffer()` and returns `{ html, documentId, processingStatus }`. Returns 409 if the document is still processing, 404 if not found/not converted.

3. **Delete source document** — New `DELETE /compliance/projects/:projectId/documents/:documentId` endpoint returning 204. Deletes MinIO objects (original file + converted HTML) and the `ComplianceDocument` row; DB cascade removes all associated compliance items, checks, and evidence. MinIO cleanup is best-effort.

4. **Per-document auto-tagging (retry)** — New `POST /compliance/projects/:projectId/documents/:documentId/process` endpoint returning 202. Clears `taggable_doc_id` and sets `processingStatus` to `extracting`, then calls `TaggingService.requestAutoTag()`. Since upload now auto-triggers processing on `main`, this endpoint serves as a **retry mechanism** for failed/stuck documents. Does not modify project-level `autotag_processing`.

5. **Unit + controller tests** for all new service methods and routes.

### Frontend (rohan_ui)

6. **API service + types** — Add `getDocumentContent()`, `deleteSourceDocument()`, and `processDocument()` methods to `ComplianceApiService`. Add `DocumentContentResponse` interface. (`processingStatus` is already on the `ComplianceDocument` type post-merge.)

7. **HTML document viewer** — Replace the mock line-by-line rendering in `document-viewer-panel` with the shared `app-doc-shell` component. Load HTML on demand via the new content endpoint. Map `ComplianceItemView[]` to `InlineTag[]` for offset-based highlighting. Handle text selection via `doc-shell`'s `tagSelection` output for manual compliance item creation. Show loading/processing/error states. Remove `app-pdf-highlight-overlay`. Configure `TaggingService` with a compliance-specific tag config for `ProductCode.COMPLIANCE`. Add per-document HTML content polling (~5s) for documents still processing.

8. **Viewer polish** — Compliance highlight colour scheme (cyan = selected, teal = approved, muted = other). Simplified context menu (single "Add Compliance Item" action). Bidirectional items panel ↔ viewer interaction: click item → scroll to highlight, hover → `.hl-active` state.

9. **Overview page document management** — Add `app-document-upload` to the Document Library section on the project overview page (reuse existing drag-and-drop component). Add a delete button per row in `compliance-document-table` (no confirmation dialog). Show `processingStatus` badges (Processing / Ready / Failed). Wire `editDocumentLibrary` output from `project-snapshot-content`. Backend auto-triggers processing on upload; `processDocument()` only needed for retry on failures.

10. **Mock data cleanup** — Delete `MOCK_COMPLIANCE_DOCUMENTS`, `PRIMARY_DOCUMENT_LINES`, `SECONDARY_DOCUMENT_LINES`, `TERTIARY_DOCUMENT_LINES`. Remove fallback/mock-rotation logic from `mapProjectDocumentsToViewerDocuments()`. Update tests.

### Testing

11. **Backend E2E** — Upload → process → GET content → verify HTML returned. Delete document → verify compliance items cascade-deleted.
12. **Frontend E2E (Playwright, optional)** — Navigate to compliance creator, verify real HTML loads, select text, create manual item, verify highlight appears.

---

## Acceptance Criteria

- [ ] After auto-tag completion, `compliance_documents.converted_html_key` is populated with the MinIO object key for the converted HTML.
- [ ] Late-arriving auto-tag completions for deleted documents are handled gracefully (no FK violations).
- [ ] `GET .../documents/:documentId/content` returns the stripped HTML for a fully-processed document; returns 409 for in-progress documents and 404 for missing/unconverted documents.
- [ ] `DELETE .../documents/:documentId` removes the document, its MinIO objects, and all associated compliance items/checks/evidence via cascade.
- [ ] `POST .../documents/:documentId/process` resets and retriggers auto-tagging for a single document (retry mechanism).
- [ ] The compliance document viewer renders real Docling-converted HTML (tables, headings, paragraphs) via the shared `app-doc-shell` component — no mock data.
- [ ] Auto-tagged and manually created compliance items are highlighted at their correct character offsets in the viewer.
- [ ] Text selection in the viewer creates a new compliance item with correct flattened-text offsets.
- [ ] Highlight colours: cyan (selected), teal (approved), muted (other).
- [ ] Clicking an item in the items panel scrolls the viewer to its highlight; hovering an item activates the highlight.
- [ ] Document dropdown still switches between documents correctly.
- [ ] Documents show loading spinner while HTML is fetching, "Processing..." placeholder while auto-tagging is in progress, and error state on failure.
- [ ] Users can upload new documents from the overview page's Document Library; auto-tagging triggers automatically.
- [ ] Users can delete documents from the overview page; deletion is immediate (no confirmation dialog).
- [ ] Processing status badges appear per document in the document table.
- [ ] All mock document line data (`MOCK_COMPLIANCE_DOCUMENTS`, etc.) is removed from production code.
- [ ] Unit tests for all new backend service methods and controller routes.
- [ ] Component tests for updated frontend components.
- [ ] Backend E2E tests for the full document lifecycle (upload → process → view → delete).

---

## Technical Notes

- **Offset semantics**: `document_start_line` / `document_end_line` on compliance items are character offsets into flattened visible text (not line numbers, despite the naming). The same offset space is used by Python's `extract_text_with_mapping()` and Angular's `doc-shell.buildFlattenedOffsetsByTextNode()`.
- **HTML safety**: Docling's stripped HTML (no `<style>`, `<script>`, `<head>`) is rendered via `app-doc-shell` using DOMPurify + `bypassSecurityTrustHtml`.
- **Large payloads**: Documents with embedded base64 images can produce multi-MB HTML payloads; NestJS gzip compression mitigates this.
- **DB cascades**: Deleting a `compliance_documents` row automatically removes `compliance_items`, `compliance_checks`, `compliance_item_evidence`, and `compliance_project_documents` join rows.
- **Post-merge context**: Upload already auto-triggers processing (`uploadSourceDocument` emits `compliance.auto.tag`). The listener has a skip guard. `InlineTag.isManualPosition` no longer exists. `AutotagProcessingStatusEnum` values are descriptive strings (`'Not Started'`, `'Processing'`, etc.) not chars.

---

## New Endpoints

| Method | Path | Status | Purpose |
|--------|------|--------|---------|
| `GET` | `/compliance/projects/:projectId/documents/:documentId/content` | 200 / 404 / 409 | Retrieve converted HTML |
| `DELETE` | `/compliance/projects/:projectId/documents/:documentId` | 204 / 404 | Delete source document |
| `POST` | `/compliance/projects/:projectId/documents/:documentId/process` | 202 / 404 / 409 | Retry auto-tagging |

---

## DB Schema Change

```sql
ALTER TABLE compliance_documents
  ADD COLUMN converted_html_key VARCHAR(500) NULL;
```

---

## Files Touched (Key)

**rohan_api**: `compliance-document.entity.ts`, `compliance.listener.ts`, `compliance.service.ts`, `compliance.controller.ts`, `document-content-response.dto.ts` (new), `compliance.listener.spec.ts`, `compliance.service.spec.ts`, `compliance.controller.spec.ts`, `compliance.e2e-spec.ts`

**rohan_ui**: `compliance-api.service.ts`, `compliance-project.types.ts`, `compliance-item.types.ts`, `document-viewer-panel.component.*`, `compliance-state.service.ts`, `compliance-document.utils.ts`, `tagging.service.ts`, `project-snapshot-content.component.*`, `compliance-document-table.component.*`, `compliance-project-overview-page.component.ts`, `compliance-item-mock-data.ts`, `pdf-highlight-overlay/` (removed)

**Database**: `init_compliance.sql`
