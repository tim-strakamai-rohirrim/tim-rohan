#### Summary

- Template Generator document downloads and export-to-Word are now audited so platform-level audit trail and metrics can track Template Generator activity.
- Document library downloads for Template Generator use the audited **streaming** endpoint (**GET** `/procurement-templates/:templateId/documents/:documentId/download`); the backend logs one audit entry per request and the UI receives the file as a blob and triggers an in-tab download.
- Export to Word from the preview step logs a single audit entry with feature `Template-Generator` and action `Template {name} exported to Word` after a successful export.

#### Technical Details

- **Frontend:**
  - **TemplateGeneratorService** (`template-generator.service.ts`): New method `getTemplateDocumentDownloadStream(templateId, documentId)` calling `RequestService.getFileAsBlobWithoutErrorModal` with path `/procurement-templates/:templateId/documents/:documentId/download` and auth; returns `Observable<Blob>`.
  - **DocumentLibraryComponent** (`document-library.component.ts`, `.html`): New `onRequestDownload(doc)` handler that calls the service, creates an object URL from the blob, assigns it to a `@ViewChild('downloadAnchor')` anchor with `download` set to the filename, programmatically clicks it, and revokes the object URL. Shows spinner during the request; on error or missing blob shows a toast. Template binds `(requestDownload)="onRequestDownload($event)"` to the table and adds a hidden `<a #downloadAnchor>`. No-op when not a Template Generator project, when `templateId` is missing, or when `document_id` is null.
  - **ProcurementAttachmentTableComponent** (`procurement-attachment-table/`): For `project === 'template-generator'`, the filename cell is a `<button>` with class `download-filename-link` that emits `@Output() requestDownload` with the matching `Document`; for other projects the existing `downloadDocument` flow is unchanged. `onDownloadClick` finds the document by filename and either emits `requestDownload` or calls `downloadDocument`; no-op when no matching document.
  - **PreviewStepComponent** (`preview-step/preview-step.component.ts`): After a successful `exportToWord(...)` in `exportTemplate()`, calls `AuditTrailService.logAuditTrail(AUDIT_TRAIL_FEATURES.TEMPLATE_GENERATOR, action)` with action `Template {templateName} exported to Word` (fallback `'template'` when name is missing). Fire-and-forget subscribe.
- **Backend:** No changes in this repo (streaming download endpoint and audit logging live in the API repo).
- **Database:** No changes in this repo.
- **Contracts:**
  - Frontend uses **GET** `/procurement-templates/:templateId/documents/:documentId/download`; response body is the file stream (no signed URL). Backend logs one Template Generator audit entry per request. Export-to-Word action string: `Template "{templateName}" exported to Word` (or equivalent); frontend uses `Template {templateName} exported to Word`.

#### Testing

- **Manual:**
  - Template Generator document library: click download on a template document; confirm file downloads in the same tab and that Settings > Audit Trail (filter by Template Generator) shows a download audit entry.
  - Preview step: export template to Word; confirm Settings > Audit Trail shows an entry for the export (e.g. "Template … exported to Word").
  - Non–Template Generator document library: click download and confirm existing behavior (no new endpoint).
  - Error handling: with backend unavailable or document missing, confirm error toast and spinner hidden for download.
- **Automated:**
  - **Karma/Jasmine:** `template-generator.service.spec.ts` — `getTemplateDocumentDownloadStream` calls `getFileAsBlobWithoutErrorModal` with correct path and returns Blob; accepts `documentId` as string or number. `document-library.component.spec.ts` — `onRequestDownload` flow (service call, anchor click, revoke, spinner, toast on error); no-op when not tgProject, no templateId, or null document_id. `procurement-attachment-table.component.spec.ts` — `onDownloadClick` for template-generator emits `requestDownload` with document; for other project calls `downloadDocument`; no-op when no matching document. `preview-step.component.spec.ts` — `exportTemplate()` calls `logAuditTrail` with `TEMPLATE_GENERATOR` and correct action; fallback name when template has no name.
  - **Playwright:** No E2E changes in this PR.
  - **Jest:** N/A (backend in separate repo).
- **Known gaps / TODO:**
  - E2E coverage for “download from document library → audit entry visible” and “export to Word → audit entry visible” not added.

#### Risks & Impact

- **Breaking changes:** None. Only Template Generator document library download uses the new streaming endpoint; other projects keep existing download behavior.
- **Performance:** One GET per user-initiated download; response is the file stream. Export-to-Word adds one fire-and-forget audit POST per export.
- **Security:** Same auth as existing template document APIs; download uses `getFileAsBlobWithoutErrorModal` with auth.
- **Rollout:** Requires the API streaming download endpoint to be deployed before or with this UI; if the endpoint is missing or errors, users see an error toast for download.

#### Verification Steps for Reviewers

1. **Template Generator download and audit:** Open a template in Template Generator, go to the document library, and click the document name (download). Confirm the file downloads in the same tab. In Settings > Audit Trail, filter by feature “Template Generator” and confirm an entry for the download (e.g. “Downloaded template document \"…\"").
2. **Export to Word and audit:** From the Template Generator preview step, click export to Word and complete the export. In Settings > Audit Trail, filter by Template Generator and confirm an entry such as “Template … exported to Word”.
3. **Non–Template Generator unchanged:** In a non–template-generator document library, click download on an attachment and confirm it still uses the existing behavior (no new endpoint).
4. **Error handling:** With backend down or document missing, click download in Template Generator document library and confirm an error toast and that the spinner is hidden.
5. **Unit tests:** Run Karma for `template-generator.service.spec`, `document-library.component.spec`, `procurement-attachment-table.component.spec`, and `preview-step.component.spec` and confirm all pass.
