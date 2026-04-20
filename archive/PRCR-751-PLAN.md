# PRCR-751: [UI] Audit/Metrics – Add line items for new templates

## Problem Statement

Users need new templates published via Template Generator to be reflected in platform-level audit trail and metrics so they can track activity without data being lost.

**Requirements:**

1. **New Procurement Projects (templates) published** should generate:
   - **Metrics:**
     - Add to time spent in module (Template Generator).
     - Words generated per wizard step and draft document.
   - **Audit:**
     - Document downloads or exports are tracked.

2. **Audit trail** (system-wide, in Settings) should include **only** these Template Generator entries:
   - Template \<name\> generated
   - Template \<name\> edited
   - Template \<name\> published
   - Template \<name\> unpublished
   - Template \<name\> archived
   - Template \<name\> restored

   **Granular** Template Generator logs (section added/modified/deleted, wizard step changes, status/state changes) must **not** appear in the system-wide audit trail; they appear only in the **template-specific** audit trail (e.g. `template-generator/:templateId/audit-log`).

## Assumptions

1. The existing Template Generator audit trail work (see `PLAN.md`) already logs template lifecycle events on the backend (created/generated, edited, deleted, published, unpublished, etc.). PRCR-751 focuses on ensuring these appear in the system-wide audit trail and on adding **metrics** (time spent, words generated) and **document download/export** audit entries.
2. “Time spent in module” uses the same mechanism as today: frontend calls `AuditTrailService.startTrackingTimeSpentInFeature` / `endTrackingTimeSpentInFeature` with feature `Template-Generator`; the backend already accepts and stores these metric entries.
3. “Words generated” uses the existing pattern: `postToAuditTrailWithWordCount(feature, wordCount, purposeUsingFeature)` with feature `Template-Generator` where the activity is Template Generator (wizard steps or draft document).
4. Document “download” means either (a) user downloads an uploaded template document (e.g. from document library via signed URL), or (b) user exports the draft template to Word from the preview step. Both should produce an audit entry.
5. The audit trail stores `performed_by` (user) separately. **Decision:** `performed_by` in a separate column is sufficient; action strings do not need to literally include “by \<user\>”.
6. **Word-count metrics:** Emitted only when the user generates text using AI (e.g. template wizard analysis step, or any AI-generated content in Template Generator). Not on manual typing or save of Create-step content.

## Decisions

- **Template document download logging:** Option B — dedicated “request download” endpoint that returns the signed URL and logs one audit entry per request. Frontend calls it when the user clicks Download; list responses can continue to include `download_url` for display without logging.
- **System-wide vs template-specific audit trail:** System-wide (Settings > Audit Trail, no `templateId`) shows only the six Template Generator lifecycle actions: generated, edited, published, unpublished, archived, restored. Granular actions (section added/modified/deleted, wizard step change, status changed from X to Y) and other lifecycle actions (e.g. deleted) are filtered out for system-wide and appear only when viewing a template's audit trail (`templateId` provided).

## Implementation Checklist

Steps are ordered for minimal dependencies. Only plan and contracts are edited in this role; no application code changes.

---

## Phase order and parallelism

### File touch summary (no overlaps)

| Phase       | Files touched                                                                                                                                                                                                              |
| ----------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Phase 0** | `rohan_api/src/settings/settings.service.ts` only                                                                                                                                                                          |
| **Phase 1** | `rohan_ui/.../side-nav-bar/side-nav-bar.component.ts` only                                                                                                                                                                 |
| **Phase 2** | `rohan_ui/.../template-wizard/template-wizard.component.ts` (and any other TG flows with AI word count)                                                                                                                    |
| **Phase 3** | Backend: `rohan_api/.../template-documents.controller.ts`, `template-documents.service.ts`. Frontend: `rohan_ui/.../document-library/document-library.component.ts`, `rohan_ui/.../preview-step/preview-step.component.ts` |

No two phases touch the same file, so **all phases can be done in parallel** without merge conflicts.

### What can run in parallel

- **Phase 0, Phase 1, Phase 2, and Phase 3** can all be done in parallel (different files; no shared code).
- Within Phase 3, backend (controller + service) and frontend (document-library + preview-step) are in different repos/files and can be split across people if desired.

### Recommended order (if doing sequentially)

1. **Phase 0** — Fixes incorrect system-wide audit display first; backend-only; small, reviewable change; no dependency on other phases.
2. **Phase 1** — Time-in-module under Template-Generator; single file; quick to implement and verify.
3. **Phase 2** — Words-generated under Template-Generator; single (or few) files; independent of 1 and 3.
4. **Phase 3** — Document download (Option B) + export-to-Word audit; largest phase (backend + frontend) but still self-contained.

Rationale: Phase 0 gives an immediate correctness fix for the audit trail. Phases 1 and 2 are small frontend changes. Phase 3 is the only phase that adds a new API and changes two frontend flows, so doing it last keeps the “new endpoint + frontend consumer” change in one PR or a clear backend-then-frontend sequence.

---

### Phase 0: System-wide audit trail – show only Template Generator lifecycle events

- [x] **[BACKEND_DB]** When returning audit trail for the **system-wide** view (no `templateId` query param), exclude granular Template Generator actions so only lifecycle events appear.
  - **Include (Template-Generator, system-wide):** Only these six lifecycle actions: `generated`, `edited`, `published`, `unpublished`, `archived`, `restored` (see contracts for exact formats). All other Template-Generator actions (e.g. deleted, section changes, wizard step change, state change) are excluded from system-wide.
  - **Implementation:** In `getAuditLogs`, when `templateId` is not provided, include Template-Generator rows only if the action ends with one of: ` generated`, ` edited`, ` published`, ` unpublished`, ` archived`, ` restored` (allow-list). Same logic for CSV export when no `templateId`.
  - **Behavior when `templateId` is provided:** No change — return all matching Template Generator entries for that template (including deleted, section, step, and state-change entries).
  - **Files:** `rohan_api/src/settings/settings.service.ts` (`getAuditLogs`, and `generateAuditTrailCSV` which uses it).

- [x] **[TEST_REVIEW]** Manual: In Settings > Audit Trail (system-wide), filter by Template Generator; confirm only these six lifecycle entries appear: generated, edited, published, unpublished, archived, restored (no deleted, no "section X added/modified/deleted", "moved from step", or "status changed from"). Open a template’s audit log (`template-generator/:templateId/audit-log`) and confirm granular and other entries (e.g. deleted) appear there.

---

### Phase 1: Time spent in Template Generator module

- [x] **[FRONTEND]** Ensure time spent in the Template Generator area is tracked under feature `Template-Generator` (not only `Acquisition-Center`).
  - **Current behavior:** `SideNavBarComponent.getFeatureFromUrl` returns `'Acquisition-Center'` for any URL containing `/acquisition-center`, so template-generator routes are currently counted as Acquisition-Center.
  - **Change:** In `getFeatureFromUrl`, add a case for URLs containing `template-generator` that returns `'Template-Generator'` (e.g. before the generic `acquisition-center` case).
  - **File:** `rohan_ui/src/app/shared-components/side-nav-bar/side-nav-bar.component.ts`

- [x] **[TEST_REVIEW]** Manual: Navigate to Template Generator, stay for 1+ minute, leave; in Settings > Audit Trail, filter by feature “Template Generator” and confirm a “Metric: Spent … in Template-Generator” entry.

---

### Phase 2: Words-generated metrics for Template Generator

- [x] **[FRONTEND]** Use feature `Template-Generator` for word-count metrics when the user generates text using AI in Template Generator (e.g. template wizard analysis step, or any AI-generated draft content).
  - **Current behavior:** Template wizard uses `AUDIT_TRAIL_FEATURES.ACQUISITION_CENTER` for `postToAuditTrailWithWords` in the analysis step.
  - **Change:** Where the flow is Template Generator and text is AI-generated, use `AUDIT_TRAIL_FEATURES.TEMPLATE_GENERATOR` and an appropriate purpose string (see contracts). Do **not** emit word-count for manual typing or on save of Create-step content; only when AI generates text.
  - **Files:** e.g. `rohan_ui/src/app/pages/acquisition-center/components/workspace/template-wizard/template-wizard.component.ts` (and any other Template Generator flows where AI generates text and word count is posted).

- [x] **[TEST_REVIEW]** Manual: Generate text using AI in template wizard (e.g. analysis step); confirm audit entry with feature “Template Generator” and “Metric: Generated X words for …”.

---

### Phase 3: Audit – document download and export

- [ ] **[BACKEND_DB]** Add a dedicated “request download” endpoint that returns the signed URL for a single template document and logs one audit entry per request (Option B).
  - **Endpoint:** e.g. `GET /procurement-templates/:templateId/documents/:documentId/download-url` (or `POST .../request-download`) — see `PRCR-751-contracts.md`.
  - **Behavior:** Resolve document, generate signed URL, log audit action (e.g. `Downloaded template document "{filename}"` or equivalent), return `{ download_url: string }`.
  - **Files:** `rohan_api/src/template-generator/template-documents.controller.ts` (new route), `rohan_api/src/template-generator/template-documents.service.ts` (method that generates URL + calls settings/audit to log). Inject `SettingsService` into template-documents if not already present.

- [ ] **[FRONTEND]** When the user clicks Download for a template document (e.g. in document library), call the new request-download endpoint, then use the returned URL to perform the download (replace or supplement use of `download_url` from list for the actual download action).
  - **File:** e.g. `rohan_ui/src/app/pages/acquisition-center/components/workspace/document-library/document-library.component.ts` (or wherever template document download is triggered).

- [ ] **[FRONTEND]** Log an audit entry when the user exports the draft template to Word (preview step).
  - **Current behavior:** `PreviewStepComponent.exportTemplate()` builds HTML and calls `exportToWord(...)`; no audit call.
  - **Change:** After a successful export (or at the start of export), call `AuditTrailService.logAuditTrail(AUDIT_TRAIL_FEATURES.TEMPLATE_GENERATOR, action)` with the action string defined in contracts (e.g. template name + “exported to Word”).
  - **File:** `rohan_ui/src/app/pages/acquisition-center/components/template-generator/preview-step/preview-step.component.ts`

- [ ] **[TEST_REVIEW]** Manual: (1) Download a template document from the document library; (2) Export template to Word from preview. Confirm corresponding audit entries in Settings > Audit Trail for Template Generator.

---

## Summary of file paths (by owner)

| Owner       | Files                                                                                                                                                                                                                                                                                                                      |
| ----------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| FRONTEND    | `rohan_ui/src/app/shared-components/side-nav-bar/side-nav-bar.component.ts`; `rohan_ui/.../template-wizard/template-wizard.component.ts`; `rohan_ui/.../template-generator/preview-step/preview-step.component.ts`; `rohan_ui/.../document-library/document-library.component.ts` (template document download)             |
| BACKEND_DB  | `rohan_api/src/settings/settings.service.ts` (getAuditLogs, generateAuditTrailCSV — filter Template-Generator for system-wide); `rohan_api/src/template-generator/template-documents.controller.ts` (new request-download endpoint); `rohan_api/src/template-generator/template-documents.service.ts` (method + audit log) |
| TEST_REVIEW | Manual verification steps above.                                                                                                                                                                                                                                                                                           |

---

## References

- Jira: [PRCR-751](https://rohirrim.atlassian.net/browse/PRCR-751)
- **Handoff (Backend → Frontend/Tester):** `PRCR-751-HANDOFF.md`
- Existing Template Generator audit plan: `PLAN.md` (this repo)
- Contracts for actions and metrics: `PRCR-751-contracts.md`
