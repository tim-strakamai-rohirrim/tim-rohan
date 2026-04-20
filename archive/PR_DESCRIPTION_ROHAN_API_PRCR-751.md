# PR Description – rohan_api (PRCR-751)

#### Summary

- Adds an **audited document-download** flow for Template Generator so each user download of a template document is recorded in the system audit trail (feature `Template-Generator`).
- New **GET** endpoint streams the file with `Content-Disposition: attachment` and logs **one audit entry per request**; the response body is the file stream (no signed URL returned). The UI should use this URL for the Download action so every click is logged.
- Supporting change: **`acquisition-center`** is added to the approved resources list in the settings controller so the acquisition center (and thus template document download) can use approved resources as needed.

#### Technical Details

- **Backend**
  - **Template documents**
    - **Controller:** New route **GET** `procurement-templates/:templateId/documents/:documentId/download` (must be registered before `:documentId` so `download` is not parsed as a documentId). Uses `GetUser()` to get `userEmail` or `sub` as `performedBy` and delegates to the service.
    - **Service:** New method `getDocumentDownloadStream(templateId, documentId, performedBy)`. Loads document with `template` relation; streams file via `Helpers.createDownloadStreamFile`; builds audit action with `AuditTrailAction.getTemplateDocumentDownloadAction(filename, templateId, templateName, fileSize?, durationMs?)`; calls `SettingsService.appendAuditLog` with feature `TEMPLATE_GENERATOR` and the action; returns `StreamableFile` with correct MIME type and `attachment; filename="..."`. On non-`NotFoundException` errors, logs and throws `InternalServerErrorException` and does **not** write a success audit entry.
  - **Constants:** New `AuditTrailAction.getTemplateDocumentDownloadAction(filename, templateId, templateName, fileSize?, durationMs?)` producing strings like `Template {id} ({name}): Downloaded template document "{filename}"` with optional `(bytes, ms)` suffix so entries show up in the template-specific audit view.
  - **Settings controller:** `getApprovedResources` allowlist now includes `'acquisition-center'`.
- **Database**
  - No schema or migration changes.
- **Contracts**
  - **New endpoint:** **GET** `/procurement-templates/:templateId/documents/:documentId/download`  
    - Path params: `templateId`, `documentId`. Auth required (same as other document endpoints).  
    - Response: file stream with `Content-Disposition: attachment; filename="..."`. One audit trail entry per HTTP request (feature `Template-Generator`, action format as above).  
    - Errors: 404 if template or document not found; 403 if forbidden; 500 on stream failure.  
  - List/single-document endpoints are unchanged; they may still return `download_url` for display. Only this endpoint both delivers the file and logs each request.

#### Testing

- **Manual**
  - Download a template document from the document library (with UI calling this endpoint); in Settings > Audit Trail, filter by Template Generator and confirm an entry like `Template X (Name): Downloaded template document "filename" (...)`.
- **Automated**
  - **[Jest]**  
    - **template-documents.controller.spec.ts:** New `streamDocumentDownload` suite: returns stream and calls service with `performedBy` from `user.userEmail`; falls back to `user.sub` when `userEmail` is not set.  
    - **template-documents.service.spec.ts:** New `getDocumentDownloadStream` tests: returns `StreamableFile` with attachment disposition and logs one audit entry with correct feature, `performed_by`, and action (template prefix, filename, optional bytes/duration); includes file size and duration when available; only duration when `file_size` missing; uses `Template ${id}` as name when template title is missing; throws `NotFoundException` when document not found; on stream failure throws `InternalServerErrorException` and does **not** call `appendAuditLog`. Additional tests for `AuditTrailAction.getTemplateDocumentDownloadAction`: bytes+ms, bytes only, ms only, no suffix when both undefined.
- **Known gaps / TODO**
  - Integration test against real blob storage and audit table was not added; manual or E2E can cover that.

#### Risks & Impact

- **Route order:** The `:documentId/download` route is declared **before** the generic `:documentId` route so that `"download"` is not interpreted as a documentId. Keep this order in future edits.
- **Log volume:** Every HTTP request to the download URL is logged (one audit row per click or refresh). Acceptable for “download” semantics; no change to list or metadata endpoints.
- **Frontend dependency:** The UI must use this endpoint for the Download action (e.g. open this URL in a new tab with auth, or `fetch` with `Authorization` and trigger a download). List responses can still include `download_url` for display; only the actual download action should go through this audited endpoint.

#### Verification Steps for Reviewers

1. Run the template-generator Jest specs:  
   `npm test -- --testPathPattern="template-documents"`  
   Confirm controller and service tests for the new download route and `getDocumentDownloadStream` pass.
2. Optionally run the full Jest suite to ensure no regressions in settings or other modules.
3. (Manual) With the frontend configured to use this API: open a template, go to document library, click Download for a document. In Settings > Audit Trail, filter by feature “Template Generator” and confirm a “Downloaded template document …” entry with the correct template name and filename.
