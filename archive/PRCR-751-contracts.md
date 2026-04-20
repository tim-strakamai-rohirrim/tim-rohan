# PRCR-751: API contracts and data shapes (Audit/Metrics for new templates)

Single source of truth for request/response shapes, action strings, and validation related to PRCR-751 (audit and metrics for Template Generator).

---

## 1. Feature identifier

| Context                                    | Value                | Notes                                                                                                             |
| ------------------------------------------ | -------------------- | ----------------------------------------------------------------------------------------------------------------- |
| Audit trail feature for Template Generator | `Template-Generator` | Must match backend `AuditTrailFeature.TEMPLATE_GENERATOR` and frontend `AUDIT_TRAIL_FEATURES.TEMPLATE_GENERATOR`. |

---

## 2. Audit trail API (unchanged)

- **POST** `/settings/audit_trail`

  - **Request body:** `{ feature: string, action: string }`
  - **Response:** `{ message: string }`
  - `performed_by` is set by the backend from the authenticated user; frontend does not send it.

- **POST** `/settings/audit_trail/batch`

  - **Request body:** `{ audit_trails: Array<{ feature: string, action: string }> }`
  - **Response:** `{ message: string }`

- **GET** `/settings/audit_trail`
  - Query params: `startDate`, `endDate`, `feature`, `performedBy`, `page`, `pageSize`, `actionType` (e.g. `metrics`), `templateId`
  - **Response:** `{ data: AuditTrailRecord[], count: number, pageSize: string, page: number }`

No changes to these endpoints for PRCR-751; only the **action strings** and **feature** used by the frontend/backend for Template Generator are specified below.

---

## 3. Audit action strings (Template Generator)

Backend helpers in `rohan_api/src/utils/constants.ts` (`AuditTrailAction`) use the following formats. Frontend may post the same or equivalent strings when logging from the UI.

| Event                | Format                               | Example                             | System-wide?                |
| -------------------- | ------------------------------------ | ----------------------------------- | --------------------------- |
| New template created | `Template {id} ({name}) generated`   | `Template 123 (My RFP) generated`   | Yes                         |
| Template edited      | `Template {id} ({name}) edited`      | `Template 123 (My RFP) edited`      | Yes                         |
| Template published   | `Template {id} ({name}) published`   | `Template 123 (My RFP) published`   | Yes                         |
| Template unpublished | `Template {id} ({name}) unpublished` | `Template 123 (My RFP) unpublished` | Yes                         |
| Template archived    | `Template {id} ({name}) archived`    | `Template 123 (My RFP) archived`    | Yes                         |
| Template restored    | `Template {id} ({name}) restored`    | `Template 123 (My RFP) restored`    | Yes                         |
| Template deleted     | `Template {id} ({name}) deleted`     | `Template 123 (My RFP) deleted`     | No (template-specific only) |
| Template modified    | (same as edited)                     | —                                   | —                           |

**System-wide vs template-specific:** The system-wide audit trail (Settings > Audit Trail, no `templateId`) shows **only** these six lifecycle actions for Template-Generator: generated, edited, published, unpublished, archived, restored. All other Template-Generator actions (e.g. deleted, section added/modified/deleted, wizard step change, status changed from X to Y) are **excluded** from system-wide and appear **only** in the template-specific audit trail (`templateId` provided). Backend filter: when `templateId` is not provided, include Template-Generator rows only if the action ends with one of: ` generated`, ` edited`, ` published`, ` unpublished`, ` archived`, ` restored` (allow-list).

User is stored in the `performed_by` column; action strings do not include “by \<user\>”.

---

## 4. Metric action strings (Template Generator)

Same POST `/settings/audit_trail` body; `feature: 'Template-Generator'`. Actions:

| Metric               | Action string format                                                       | Example                                                          |
| -------------------- | -------------------------------------------------------------------------- | ---------------------------------------------------------------- |
| Time spent in module | `Metric: Spent {minutes} minutes {seconds} seconds in Template-Generator.` | `Metric: Spent 2 minutes 30 seconds in Template-Generator.`      |
| Words generated      | `Metric: Generated {wordCount} words for {purposeUsingFeature}.`           | `Metric: Generated 150 words for Template Wizard Analysis step.` |

**Purpose strings (words-generated):**

- Emit word-count only when the user generates text **using AI** (e.g. Template Wizard analysis step, or any AI-generated content in Template Generator). Do not emit for manual typing or on save of Create-step content.
- Example purpose strings: `Template Wizard Analysis step`, or `{templateName} Draft Document – Analysis`.

Exact wording can be aligned with product; the important part is `feature: 'Template-Generator'` and the prefix `Metric: Generated X words for …`.

---

## 5. Document download / export (new for PRCR-751)

### 5.1 Audited download endpoint (stream)

- **GET** `/procurement-templates/:templateId/documents/:documentId/download`

- **Path params:** `templateId` (number), `documentId` (number).
- **Auth:** Required (same as other document endpoints).
- **Response:** File stream with `Content-Disposition: attachment; filename="…"`. The response body is the document bytes (no signed URL returned).
- **Side effect:** Backend logs one audit trail entry with feature `Template-Generator` and action string **per HTTP request**. Every request to this URL (every click, or refresh) is logged, so one log per download click when the UI uses this URL for the Download action. See action string format below.
- **Errors:** 404 if template or document not found; 403 if forbidden; 500 on server error.

The UI should use this endpoint for the Download action (e.g. open this URL in a new tab with auth, or `fetch` with `Authorization` and trigger a download from the response). List/single-document endpoints may still return `download_url` for display; only this endpoint both delivers the file and logs each request.

### 5.2 Audit action strings (download / export)

| Event                               | Source   | Action string format                                                                                                                                 | Example                                                                     |
| ----------------------------------- | -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| Template document downloaded        | Backend  | `Template {templateId} ({templateName}): Downloaded template document "{filename}"` (optional suffix: ` ({fileSize} bytes, {durationMs}ms)`)        | `Template 6 (My RFP): Downloaded template document "sow.docx" (12345 bytes, 12ms)` |
| Template exported to Word (preview) | Frontend | `Template "{templateName}" exported to Word` or `Exported template "{templateName}" to Word`                                                         | `Template My RFP exported to Word`                                          |

Backend uses `AuditTrailAction.getTemplateDocumentDownloadAction(filename, templateId, templateName, fileSize?, durationMs?)`. The `Template {templateId} ({templateName}): ` prefix ensures the entry appears in the template-specific audit trail when filtering by `templateId` and shows the template name. Frontend posts the export string when user exports to Word.

---

## 6. Validation and errors

- **Audit trail POST:** `feature` must be a valid `AuditTrailFeature` enum value; `Template-Generator` is allowed.
- **Validation:** Backend continues to use existing `AuditTrailInput` / `AuditTrailFeature` validation; no new validation rules for PRCR-751.
- **Errors:** Existing settings/audit_trail error responses unchanged (e.g. 401, 403, 500).

---

## 7. Summary of changes introduced by PRCR-751

| Item                             | Change                                                                                                                                                                                                                                                                                                  |
| -------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Feature for time spent           | Use `Template-Generator` when URL is under template-generator (frontend route mapping).                                                                                                                                                                                                                 |
| Feature for words-generated      | Use `Template-Generator` (and purpose string) when user generates text using AI in Template Generator (e.g. template wizard); not for manual typing or save.                                                                                                                                            |
| Document download/export         | GET `/procurement-templates/:templateId/documents/:documentId/download` streams the file (attachment) and logs one audit entry per request—every click creates one log. Template export to Word logged from frontend.                                                                                      |
| Lifecycle actions                | No contract change; existing backend strings (created/deleted/modified/published/unpublished/archived) already satisfy “audit trail should include” requirement; performed_by in separate column is sufficient.                                                                                         |
| System-wide vs template-specific | GET `/settings/audit_trail` without `templateId`: return only Template-Generator lifecycle actions (generated, edited, published, unpublished, archived, restored) — allow-list of six; exclude all others (e.g. deleted, section, step, state change). With `templateId`: return all matching entries. |

---

## Changelog

- **Phase 3 (Backend):** Document download audit action string includes `Template {templateId} ({templateName}): ` prefix (e.g. `Template 6 (My RFP): Downloaded template document "sow.docx" (12345 bytes, 12ms)`) so that request-download entries appear in the template-specific audit trail and show the template name. Backend helper signature: `getTemplateDocumentDownloadAction(filename, templateId, templateName, fileSize?, durationMs?)`.
- **Phase 3 (Backend) – stream-based download:** Replaced “request download URL” with **GET `.../documents/:documentId/download`** that streams the file and logs once per request. Every request to this URL is logged (one log per click when the UI uses it for Download). No signed URL is returned—the response body is the file stream.
