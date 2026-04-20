# PRCR-751: Handoff – Backend / DB → Frontend / Tester

Handoff from **Backend/DB agent**

`Goal:` Implemented **stream-based audited download** for template documents so **every request to the download URL is logged** (one log per click), per `[BACKEND_DB]` Phase 3 in `PRCR-751-PLAN.md`. Replaced “request download URL” with **GET `.../documents/:documentId/download`** that streams the file with `Content-Disposition: attachment` and logs one audit entry per HTTP request. Audit action format: `Template {id} ({name}): Downloaded template document "…"`.

`Changes:`

- `rohan_api/src/template-generator/template-documents.controller.ts`: **Removed** GET `:documentId/download-url`. **Added** GET `:documentId/download` — calls `getDocumentDownloadStream(templateId, documentId, performedBy)` and returns `StreamableFile` (response body is the file stream; no URL returned).
- `rohan_api/src/template-generator/template-documents.service.ts`: **Removed** `requestDownloadUrl` and short-lived SAS URL logic. **Added** `getDocumentDownloadStream(templateId, documentId, performedBy)` — loads document (with template), logs one audit entry (feature `Template-Generator`, same action string), streams file from blob with `disposition: attachment`. List/get still use long-lived `download_url` for display.
- `rohan_api/src/utils/constants.ts`: Unchanged — `AuditTrailAction.getTemplateDocumentDownloadAction(filename, templateId, templateName, fileSize?, durationMs?)` still used for the audit message.
- `rohan_api/src/template-generator/dto/template-document.dto.ts`: No change for this iteration; `TemplateDocumentDownloadUrlDto` remains but is unused (download-url endpoint removed).
- No new migrations.
- `rohan_api/src/template-generator/template-documents.controller.spec.ts`: Replaced `getDownloadUrl` tests with `streamDocumentDownload` tests (return `StreamableFile`, performedBy from userEmail / fallback to sub).
- `rohan_api/src/template-generator/template-documents.service.spec.ts`: Replaced `requestDownloadUrl` tests with `getDocumentDownloadStream` tests (audit call, attachment disposition, optional bytes/ms, template name fallback, NotFound).
- `PRCR-751-contracts.md`: §5.1 updated to describe **GET `.../documents/:documentId/download`** (stream, one log per request). Changelog entry added for stream-based download.

`Open questions:`

- Q1: Frontend currently calls GET `.../download-url` and opens the returned blob URL. It must switch to using the **stream URL** for Download: either open GET `.../download` in the same or new tab (if auth is cookie-based) or `fetch(streamUrl, { headers: { Authorization } })` then create blob and trigger download (if Bearer). Should the UI use a single method that builds the stream URL and opens it, or fetch + blob?
- Q2: Export-to-Word audit is owned by [FRONTEND] (preview-step). Any backend contract or naming change needed for that action string?

`Next owner:` [FRONTEND] — In document-library, wire Download to **GET `.../documents/:documentId/download`** (stream endpoint) so each click triggers one request and one audit log; add export-to-Word audit in preview-step. Then [TEST_REVIEW] for manual verification (download and export both appear under Template Generator in Settings > Audit Trail).

---

## Handoff from [FRONTEND] (Phase 3 – document download only)

**Goal:** Implemented Phase 3 [FRONTEND] item: template document Download in document library uses the new request-download endpoint and opens the returned URL. **Stashed for a separate PR:** export-to-Word audit in preview step (preview-step.component.ts + spec).

**Changes (this PR):**

- **TemplateGeneratorService** (`template-generator.service.ts`): Added `getTemplateDocumentDownloadUrl(templateId, documentId)` calling GET `/procurement-templates/:templateId/documents/:documentId/download-url`, returns `Observable<{ download_url: string }>`.
- **DocumentLibraryComponent** (`document-library.component.ts`, `.html`): Injected `ToastNotificationService`; added `onRequestDownload(doc)` which calls `getTemplateDocumentDownloadUrl`, then `window.open(res.download_url, '_blank', 'noopener,noreferrer')`. Bound `(requestDownload)="onRequestDownload($event)"` on `app-procurement-attachment-table`.
- **ProcurementAttachmentTableComponent** (`procurement-attachment-table.component.ts`, `.html`): Added `@Output() requestDownload = new EventEmitter<Document>()`. For template-generator, filename link now calls `onDownloadClick(element)`; `onDownloadClick` emits `requestDownload` with the matching document (non–template-generator still calls `downloadDocument` using list `download_url`).
- **Unit tests:** `template-generator.service.spec.ts` (getTemplateDocumentDownloadUrl), `document-library.component.spec.ts` (onRequestDownload), `procurement-attachment-table.component.spec.ts` (onDownloadClick, TeamService mock).

**Open questions:**

- None.

**Next owner:** [TEST_REVIEW] — Manual: Download a template document from the document library; confirm audit entry in Settings > Audit Trail for Template Generator. (Export-to-Word audit will be a follow-up PR.)

---

## Handoff from [FRONTEND] (Phase 3 – stream-based audited download)

**Goal:** Switched template document Download in the document library to the **stream-based** audited endpoint (GET `.../documents/:documentId/download`) per `PRCR-751-HANDOFF.md` and `PRCR-751-contracts.md` §5.1. Each click triggers one request to the stream endpoint; the backend logs one audit entry and returns the file body. The UI fetches with auth, creates a blob URL, triggers download via the existing anchor, then revokes the blob URL.

**Changes:**

- **TemplateGeneratorService** (`template-generator.service.ts`): Replaced `getTemplateDocumentDownloadUrl` with `getTemplateDocumentDownloadStream(templateId, documentId)` which calls `RequestService.getFileAsBlobWithoutErrorModal('/procurement-templates/:templateId/documents/:documentId/download', this.rohAuth)` and returns `Observable<Blob>`. Injected `RohAuthService` for the blob request.
- **DocumentLibraryComponent** (`document-library.component.ts`, `.html`): `onRequestDownload(doc)` now calls `getTemplateDocumentDownloadStream`; on success creates an object URL from the blob, sets the persistent anchor’s `href`/`download`, triggers click, then `URL.revokeObjectURL(url)`. Error toasts updated to "Unable to download. Please try again." and "Download is unavailable. Please try again." Comment in HTML updated for blob-based download.
- **Unit tests:** `template-generator.service.spec.ts` — mock `getFileAsBlobWithoutErrorModal` and `RohAuthService`; tests for `getTemplateDocumentDownloadStream` (path, auth, Blob return). `document-library.component.spec.ts` — `getTemplateDocumentDownloadStream` spy returning `of(new Blob())`; success case asserts `URL.createObjectURL`/`revokeObjectURL`, blob URL on anchor, spinner; error and guard cases updated; "no blob" toast case added.

**Open questions:**

- None. Export-to-Word audit (preview step) remains a separate [FRONTEND] item.

**Next owner:** [TEST_REVIEW] — Manual: Download a template document from the document library; confirm file downloads and one audit entry in Settings > Audit Trail for Template Generator. No Playwright E2E changes in this PR (user flow unchanged).

---

## Review: Backend Phase 3 (TEST_REVIEW)

**Scope reviewed:** Phase 3 [BACKEND_DB] only — request-download endpoint, audit action format, and related backend files.

**Files reviewed:**

- `rohan_api-parent/rohan_api-PRCR-751/src/template-generator/template-documents.controller.ts` — GET `:documentId/download-url`, `performedBy` from `user.userEmail ?? user.sub`.
- `rohan_api-parent/rohan_api-PRCR-751/src/template-generator/template-documents.service.ts` — `requestDownloadUrl`, SettingsService, audit log with template name.
- `rohan_api-parent/rohan_api-PRCR-751/src/utils/constants.ts` — `AuditTrailAction.getTemplateDocumentDownloadAction(...)`.
- `rohan_api-parent/rohan_api-PRCR-751/src/template-generator/dto/template-document.dto.ts` — `TemplateDocumentDownloadUrlDto`.
- `rohan_api-parent/rohan_api-PRCR-751/src/template-generator/template-documents.controller.spec.ts`
- `rohan_api-parent/rohan_api-PRCR-751/src/template-generator/template-documents.service.spec.ts`

**Alignment with PRCR-751-PLAN.md and PRCR-751-contracts.md:**

- Endpoint: GET `/procurement-templates/:templateId/documents/:documentId/download-url` matches contracts §5.1.
- Response `{ download_url: string }` and side-effect (one audit entry per request) match.
- Audit action format matches §5.2: `Template {templateId} ({templateName}): Downloaded template document "{filename}"` with optional ` (fileSize bytes, durationMs ms)`; helper only adds suffix when both `fileSize` and `durationMs` are defined.
- Feature `Template-Generator` and `performed_by` from `userEmail` / `sub` match handoff and contracts.

**Review notes:**

- Route order is correct: `GET ':documentId/download-url'` is declared before `GET ':documentId'`, so the path is matched as intended.
- `appendAuditLog` is called with `(payload, undefined)`; signature `appendAuditLog(auditTrail, _orgId?)` is correct; template-specific filtering is done at read time via action string pattern, so no change needed.
- No issues found that require code fixes. Two extra unit tests were added for edge cases (see Test updates).

**Test updates:**

- `rohan_api-parent/rohan_api-PRCR-751/src/template-generator/template-documents.service.spec.ts`:
  - **requestDownloadUrl:** added test “should not include bytes/ms in audit action when file_size is missing” (optional suffix only when both fileSize and durationMs provided).
  - **requestDownloadUrl:** added test “should use template id as name when template title is missing” (fallback `Template ${templateId}`).
- No new test files. All existing template-documents controller and service specs pass (42 tests total after additions).

**Issues:**

- None. Backend Phase 3 is complete and aligned with plan/contracts.

**Next owner:** [FRONTEND] — No backend changes required. Proceed with frontend Phase 3 (document library download wiring and export-to-Word audit in preview step) as in the handoff. After that, [TEST_REVIEW] for manual verification (download and export audit entries under Template Generator).

---

## Review: Frontend Phase 3 – Template document download (TEST_REVIEW)

**Scope reviewed:** Phase 3 `[FRONTEND]` plan item (PRCR-751-PLAN.md lines 116–117): when the user clicks Download for a template document in the document library, call the request-download endpoint and use the returned URL to perform the download.

**Files reviewed:**

- `rohan_ui-parent/rohan_ui-PRCR-751/src/app/pages/acquisition-center/components/template-generator/template-generator.service.ts` — `getTemplateDocumentDownloadUrl(templateId, documentId)` using GET `.../download-url` via `request.getWithoutErrorModal`.
- `rohan_ui-parent/rohan_ui-PRCR-751/src/app/pages/acquisition-center/components/template-generator/template-generator.service.spec.ts`
- `rohan_ui-parent/rohan_ui-PRCR-751/src/app/pages/acquisition-center/components/workspace/document-library/document-library.component.ts` — `onRequestDownload(doc)`, persistent `#downloadAnchor`, spinner and toast.
- `rohan_ui-parent/rohan_ui-PRCR-751/src/app/pages/acquisition-center/components/workspace/document-library/document-library.component.html` — `(requestDownload)="onRequestDownload($event)"`, hidden anchor.
- `rohan_ui-parent/rohan_ui-PRCR-751/src/app/pages/acquisition-center/components/workspace/document-library/document-library.component.spec.ts`
- `rohan_ui-parent/rohan_ui-PRCR-751/src/app/pages/acquisition-center/components/workspace/document-library/procurement-attachment-table/procurement-attachment-table.component.ts` — `requestDownload` output, `onDownloadClick` (emit vs `downloadDocument`).
- `rohan_ui-parent/rohan_ui-PRCR-751/src/app/pages/acquisition-center/components/workspace/document-library/procurement-attachment-table/procurement-attachment-table.component.html` — button with `aria-label` for template-generator.
- `rohan_ui-parent/rohan_ui-PRCR-751/src/app/pages/acquisition-center/components/workspace/document-library/procurement-attachment-table/procurement-attachment-table.component.spec.ts`
- `rohan_ui-parent/rohan_ui-PRCR-751/src/app/pages/acquisition-center/components/workspace/document-library/procurement-attachment-table/procurement-attachment-table.component.scss` — `.download-filename-link` styles.

**Alignment with PRCR-751-PLAN.md and PRCR-751-contracts.md:**

- Frontend calls GET `/procurement-templates/:templateId/documents/:documentId/download-url` (contracts §5.1); implementation uses `getWithoutErrorModal` so errors are handled in-component (toast) without a global error modal.
- Response `{ download_url: string }` is used to set a persistent anchor’s `href`/`download` and trigger click for in-tab download; no new tab.
- Guards: API is only called when `tgProject && templateId && doc.document_id != null`; otherwise no request.
- Accessibility: template-generator download trigger is a `<button type="button">` with `aria-label="Download {filename}"` and link-like styling.

**Review notes:**

- **Fix applied:** `template-generator.service.spec.ts` was mocking `RequestService.get` while the service calls `getWithoutErrorModal`. Spec was updated to mock `getWithoutErrorModal` and assert that method; tests now match implementation.
- **Spec improvements:** `document-library.component.spec.ts` now uses `fakeAsync`/`tick` for async assertions (per project preference), adds error path (toast + hide spinner), guards for missing `templateId` and `document_id` null, and a case when response has no `download_url` (no anchor click, spinner still hidden). Added required `documentIds` input and spinner show/hide assertions where relevant.
- Export-to-Word audit (preview step) is correctly out of scope for this handoff.

**Test updates:**

- **template-generator.service.spec.ts:** Mock `RequestService` with `getWithoutErrorModal` (and `get` for other methods); `getTemplateDocumentDownloadUrl` tests now assert `getWithoutErrorModal` and correct URL path.
- **document-library.component.spec.ts:** `onRequestDownload` tests refactored to `fakeAsync`/`tick`; added tests: error path (toast + hide spinner), guard when `templateId` is missing, guard when `document_id` is null, no anchor click when `download_url` is empty (spinner still hidden); added `documentIds = signal([])` for component init; assertions for spinner show/hide on success.
- **procurement-attachment-table.component.spec.ts:** No changes; existing tests for `onDownloadClick` (emit vs `downloadDocument`, no emit when no matching doc) are sufficient and clearly named.

**E2E:** No Playwright tests added. Manual verification remains as described in the handoff (Template Generator → document library → click filename → confirm in-tab download and audit entry under Settings → Audit Trail).

**Issues:**

- None. Frontend Phase 3 (template document download) is complete and aligned with plan/contracts. Remaining work: export-to-Word audit (preview step) in a follow-up PR.

**Next owner:** [PLANNER] for next phase, or [FRONTEND] if export-to-Word audit is taken in the same cycle. Manual testing as above is recommended before closing the PR.
