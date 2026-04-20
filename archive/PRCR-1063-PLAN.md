# PRCR-1063: Template Audit Log – Full Details and Per-Template Access

## Problem Statement

Users need to see **all** audit log details for each template (publish, draft, or deleted) and more audit entries (see PRCR-752) to track template activity. Today:

- The template generator landing page shows **Completed**, **Template Drafts**, and **Archived Templates**.
- **Completed** templates list a "view audit log" action, but it has **no handler**—clicking it does nothing.
- **Draft** and **Archived** tables do **not** expose a "view audit log" action.
- The platform audit trail (Settings) supports filtering by `templateId` on the backend, but the frontend does not pass `templateId` or offer a template-scoped audit view.

**Requested behavior:**

1. **Button on landing page**: For each template (in publish, draft, or archived state), provide a button that navigates to the audit logs for that template.
2. **Audit log page**: Look and function like the existing platform audit trail: table (same design), filters (Date, Email address, **Action**), and Download CSV.
3. **Actions tracked**:
   - Text/content changes — **before → after state** (optional `details` with before/after; see Phase 5).
   - During draft: which/when the template moves between wizard steps.
   - Template publish, deletion, draft — state changes.

---

## Assumptions

1. **Reuse existing audit trail UI**: The template-scoped audit view will reuse the same table design and filter behavior as the platform audit trail (`app-audit-trail` or equivalent), with data fetched using `templateId`.
2. **Backend already supports template-scoped audit**: `GET /settings/audit_trail` and `GET /settings/audit_trail_csv` already accept optional `templateId`; filtering uses `action LIKE 'Template {templateId}%'`. Additional backend work in this ticket: **Action filter** param and **details** (before/after) for content changes.
3. **Permissions**: Access to template audit logs follows the same admin guard as the rest of the template generator and Settings audit trail (admin-only).
4. **Template identification**: Templates are identified by `procurement_template_id` (numeric id). Draft/archived/completed rows all expose this id for navigation.
5. **PRCR-752**: No coordination required for now; this plan is self-contained.

---

## Decisions (from clarifying answers)

1. **Action filter**: Add a **separate Action filter** (e.g. "published", "edited", "section modified") with **backend support** (action substring or action-type). Backend will accept an optional query param and filter by action text (e.g. case-insensitive substring match).
2. **Before/after for content changes**: **Implement in this ticket**. Extend audit payload with optional `details` (e.g. JSON with `before`/`after`); add storage (e.g. `details` column on `audit_trail`); log before/after in template-generator when recording section content changes (especially "modified").
3. **Delete state**: Use the **existing Archived state**. "View audit log" is available for archived templates; no separate "permanently deleted" audit view required.
4. **PRCR-752**: No scope dependency for now.

---

## Ordered Checklist

### Phase 1: Frontend – Add "View audit log" to all template tables and wire navigation

- [ ] **[FRONTEND]** Add "view audit log" to **draft** templates action list.
  - **File**: `rohan_ui-parent/rohan_ui/src/app/pages/acquisition-center/components/template-generator/template-generator.component.ts`
  - **Change**: In `draftTemplatesColumnData`, set `actionList` to include `'view audit log'` (e.g. `['view audit log', 'edit', 'delete']`).

- [ ] **[FRONTEND]** Add "view audit log" to **archived** templates action list.
  - **File**: `rohan_ui-parent/rohan_ui/src/app/pages/acquisition-center/components/template-generator/template-generator.component.ts`
  - **Change**: In `archivedTemplatesColumnData`, set `actionList` to include `'view audit log'` (e.g. `['view audit log', 'restore', 'delete']`).

- [ ] **[FRONTEND]** Handle "view audit log" in `handleTableAction`: navigate to template-scoped audit route.
  - **File**: `rohan_ui-parent/rohan_ui/src/app/pages/acquisition-center/components/template-generator/template-generator.component.ts`
  - **Change**: In `handleTableAction`, add branch for `action === 'view audit log'`: e.g. `this.router.navigate(['/acquisition-center/template-generator/audit', id])` (where `id` is `template.procurement_template_id` or the row id used by the table).

- [ ] **[FRONTEND]** Ensure grid view for completed templates also handles "view audit log" (already in `actionList`; confirm `handleTableAction` receives correct `id` for grid).
  - **File**: Same as above; verify `template-grid-card` passes `procurement_template_id` when emitting action (already does per grep). No code change if already correct.

---

### Phase 2: Frontend – Template-scoped audit log page (route + component)

- [ ] **[FRONTEND]** Add route for template audit log page.
  - **File**: `rohan_ui-parent/rohan_ui/src/app/pages/acquisition-center/procurement-writer-routing.module.ts`
  - **Change**: Under `template-generator` children, add e.g. `{ path: 'audit/:templateId', component: TemplateAuditLogPageComponent }` (component to be created next).

- [ ] **[FRONTEND]** Create `TemplateAuditLogPageComponent` (or equivalent name): resolve `templateId` from route, optionally load template name for header, fetch audit data with `templateId`, render table and filters.
  - **Files**: New component under e.g. `rohan_ui-parent/rohan_ui/src/app/pages/acquisition-center/components/template-generator/template-audit-log-page/` (`.ts`, `.html`, `.scss`).
  - **Behavior**: Use same table/filter design as platform audit trail; pass `templateId` into every audit API call (see Phase 3). Optionally call `GET /procurement-templates/:id` to show template name in the page title.

- [ ] **[FRONTEND]** Use existing `app-audit-trail` (or same table/filter UX) inside the new page; parent component supplies data and handles filter/CSV events with `templateId` fixed.
  - **Files**: New component template and class; inject `AuditTrailService`, `ActivatedRoute`. Implement data fetch and filter/CSV handlers that include `templateId` (service to be extended in Phase 3).

---

### Phase 3: Frontend – Audit service and filters support `templateId`

- [ ] **[FRONTEND]** Extend `AuditTrailService.getAuditTrail` to accept optional `templateId` and pass it as query param.
  - **File**: `rohan_ui-parent/rohan_ui/src/app/shared-services/audit-trail/audit-trail.service.ts`
  - **Change**: Add optional parameter `templateId?: number`; if present, append `templateId` to URL params.

- [ ] **[FRONTEND]** Extend `AuditTrailService.getAuditTrailCSV` to accept optional `templateId` and pass it as query param.
  - **File**: Same as above.
  - **Change**: Add optional parameter `templateId?: number`; if present, append to CSV request params.

- [ ] **[FRONTEND]** Extend settings filter type to include optional `templateId` (for use by template audit page).
  - **File**: `rohan_ui-parent/rohan_ui/src/app/pages/settings/types/settings.types.ts`
  - **Change**: Add optional `templateId?: number` to `AuditTrailFilters` (if used by the template audit flow; otherwise the new page can pass templateId separately from the shared filter type).

- [ ] **[FRONTEND]** Template audit page: when fetching initial data and on filter/CSV/infinite-scroll, pass `templateId` from route into the service calls.
  - **File**: New template audit log page component (from Phase 2).
  - **Change**: All `getAuditTrail` and `getAuditTrailCSV` calls include the resolved `templateId`.

- [ ] **[FRONTEND]** Extend `AuditTrailService.getAuditTrail` and `getAuditTrailCSV` to accept optional `action` filter param and pass it as query param.
  - **File**: `rohan_ui-parent/rohan_ui/src/app/shared-services/audit-trail/audit-trail.service.ts`
  - **Change**: Add optional parameter `action?: string`; if present, append to URL params (backend Phase 4 will support it).

- [ ] **[FRONTEND]** Add optional `action` to `AuditTrailFilters` type.
  - **File**: `rohan_ui-parent/rohan_ui/src/app/pages/settings/types/settings.types.ts`
  - **Change**: Add optional `action?: string` to `AuditTrailFilters`.

- [ ] **[FRONTEND]** Template audit page: add Action filter dropdown (e.g. "All", "Published", "Edited", "Section modified", "Step change", "State change") and pass selected value into audit API calls; optionally extend platform audit trail component to support an Action filter when used in template context.
  - **Files**: New template audit log page component; optionally `app-audit-trail` if it needs to accept an action filter input.
  - **Change**: Dropdown options can map to backend substring values (e.g. "published", "edited", "section", "moved from step", "status changed"); pass through to `getAuditTrail` / `getAuditTrailCSV`.

- [ ] **[FRONTEND]** Display optional `details` (before/after) in audit table when present (e.g. expandable row or a "Details" column).
  - **File**: Template audit log page template and/or shared `app-audit-trail` component if it receives `details` in the record.
  - **Change**: When `AuditTrailRecord.details` is present, show before/after (e.g. in expanded row or tooltip); see contracts for `details` shape.

---

### Phase 4: Backend – Action filter and details (before/after)

- [ ] **[BACKEND_DB]** Add optional **action** query param to `GET /settings/audit_trail` and `GET /settings/audit_trail_csv`: when set, filter where `action` contains the value (case-insensitive substring).
  - **Files**: `rohan_api-parent/rohan_api/src/settings/settings.controller.ts`, `rohan_api-parent/rohan_api/src/settings/settings.service.ts`
  - **Change**: In `getAuditTrail` and `generateAuditTrailCSV`, accept `action?: string`; in `getAuditLogs`, if action provided, add e.g. `AND LOWER(audit.action) LIKE LOWER(:actionPattern)` with `actionPattern = '%' + value + '%'`. Escape `%` and `_` in value to avoid SQL LIKE injection.

- [ ] **[BACKEND_DB]** Add optional **details** column to `audit_trail` table (e.g. JSONB or TEXT for JSON); extend entity and DTO.
  - **Files**: `rohan_api-parent/rohan_api/src/settings/entities/audit_trail.entity.ts`, `rohan_api-parent/rohan_api/src/settings/dto/audit_trail.dto.ts`, new migration (if applicable).
  - **Change**: Entity: optional `details?: string` (or JSONB); DTO used by `appendAuditLog`: optional `details?: string`. GET responses include `details` when present.

- [ ] **[BACKEND_DB]** When returning audit records (list and CSV), include `details` in response; CSV may add a `details` column or omit for brevity (document in contracts).
  - **Files**: `rohan_api-parent/rohan_api/src/settings/settings.service.ts` (getAuditLogs, generateAuditTrailCSV).
  - **Change**: Ensure selected entity/dto includes `details`; for CSV, either add column or document that details are list-only.

- [ ] **[BACKEND_DB]** In template-generator.service, when logging section content change (especially "modified"), pass optional **details** with `{ "before": "...", "after": "..." }` (e.g. section title + field summaries or full text for the changed section); extend `logAuditTrail` / `appendAuditLog` call to accept optional details.
  - **Files**: `rohan_api-parent/rohan_api/src/template-generator/template-generator.service.ts`, `rohan_api-parent/rohan_api/src/settings/settings.service.ts` (appendAuditLog signature if DTO extended).
  - **Change**: When section is "modified", capture existing vs new values (e.g. section_title, instructions_text, helper_text, field_prompt) and store as JSON in `details`; for "added"/"deleted", details may be optional or contain single state. Ensure `appendAuditLog` (and AuditTrailDto) accept optional `details`.

---

### Phase 5: Backend – Verify and optional step names

- [ ] **[BACKEND_DB]** Verify CSV response includes same columns when filtered by `templateId` and when `details` is present (details column or omitted per contracts).
  - **Files**: `rohan_api-parent/rohan_api/src/settings/settings.controller.ts`, `rohan_api-parent/rohan_api/src/settings/settings.service.ts`
  - **Change**: Confirm behavior; document in contracts.

- [ ] **[BACKEND_DB]** (Optional) Use 3 step names for template flow in wizard step audit: e.g. `['Select', 'Create', 'Preview']` when `created_from === 'template'` so audit log shows "Select" instead of "Step 0".
  - **File**: `rohan_api-parent/rohan_api/src/template-generator/template-generator.service.ts`
  - **Note**: Documented in archive PLAN.md; can be done in this ticket or later.

---

### Phase 6: Test and review

- [ ] **[TEST_REVIEW]** Unit tests: `TemplateGeneratorComponent` – handleTableAction branches for "view audit log" (navigate with correct id).
  - **File**: `rohan_ui-parent/rohan_ui/src/app/pages/acquisition-center/components/template-generator/template-generator.component.spec.ts` (or equivalent).

- [ ] **[TEST_REVIEW]** Unit tests: `AuditTrailService` – getAuditTrail and getAuditTrailCSV include `templateId` in params when provided.
  - **File**: `rohan_ui-parent/rohan_ui/src/app/shared-services/audit-trail/audit-trail.service.spec.ts` (if present).

- [ ] **[TEST_REVIEW]** Unit tests: `TemplateAuditLogPageComponent` – resolves templateId from route, passes to service.
  - **File**: New spec for template audit log page component.

- [ ] **[TEST_REVIEW]** Manual/E2E: From landing page, for a completed/draft/archived template, click "view audit log", confirm navigation to template audit page, table loads with entries for that template only; filters (date, email, **action**) and CSV download work.
  - **Note**: E2E may live in separate repo per project setup.

- [ ] **[TEST_REVIEW]** Manual: Confirm audit entries include state changes, wizard step changes, section content changes; confirm **Action filter** narrows results; confirm **details** (before/after) appear for section content changes where implemented.

---

## Phase Order and Parallelism

### Files touched per phase

| Phase | Area        | Files touched |
|-------|-------------|----------------|
| 1     | Frontend    | `template-generator.component.ts` |
| 2     | Frontend    | `procurement-writer-routing.module.ts`, new `template-audit-log-page/*` |
| 3     | Frontend    | `audit-trail.service.ts`, `settings.types.ts`, `template-audit-log-page/*`, optionally `app-audit-trail` |
| 4     | Backend     | `settings.controller.ts`, `settings.service.ts`, `audit_trail.entity.ts`, `audit_trail.dto.ts`, `template-generator.service.ts`, migration |
| 5     | Backend     | Verification; optionally `template-generator.service.ts` (step names) |
| 6     | Test/Review | Specs for template-generator, audit-trail service, new page; manual/E2E |

### Parallelism

- **Phase 1 and Phase 3** can be done in parallel with **Phase 2** once Phase 3 service/type changes are agreed (templateId + action params). Phase 2 depends on Phase 3 for API params.
- **Phase 4** (backend Action filter + details) can start after or in parallel with frontend Phases 1–3; frontend Action filter and details display depend on Phase 4 being available.
- **Phase 5** is verification + optional step names; can run after Phase 4.
- **Phase 6** depends on Phases 1–4 (and optionally 5) being done.

### Recommended sequential order

1. **Phase 3** – Extend audit service and filter types with `templateId` and `action` so the new page can call the API.
2. **Phase 4** – Backend: add `action` query param, add `details` column and DTO, return details in list (and optionally CSV), log before/after in template-generator for section content changes.
3. **Phase 1** – Add "view audit log" to draft/archived and handle navigation.
4. **Phase 2** – Add route and template audit log page; wire Action filter and details display once Phase 4 is in place.
5. **Phase 5** – Verify backend list/CSV; optionally align step names for template flow.
6. **Phase 6** – Unit and manual/E2E tests (including Action filter and before/after).

---

## File Paths Summary

| Step | Owner | File(s) |
|------|--------|---------|
| Draft action list | FRONTEND | `rohan_ui/.../template-generator/template-generator.component.ts` |
| Archived action list | FRONTEND | Same |
| handleTableAction | FRONTEND | Same |
| Route | FRONTEND | `rohan_ui/.../procurement-writer-routing.module.ts` |
| New page component | FRONTEND | `rohan_ui/.../template-generator/template-audit-log-page/*` |
| getAuditTrail templateId / action | FRONTEND | `rohan_ui/.../audit-trail/audit-trail.service.ts` |
| getAuditTrailCSV templateId / action | FRONTEND | Same |
| AuditTrailFilters templateId / action | FRONTEND | `rohan_ui/.../settings/types/settings.types.ts` |
| Action filter dropdown + details display | FRONTEND | Template audit log page; optionally `app-audit-trail` |
| Backend action param | BACKEND_DB | `rohan_api/.../settings/settings.controller.ts`, `settings.service.ts` |
| Backend details column + DTO + response | BACKEND_DB | `rohan_api/.../settings/entities/audit_trail.entity.ts`, `dto/audit_trail.dto.ts`, `settings.service.ts`, migration |
| Template content-change details (before/after) | BACKEND_DB | `rohan_api/.../template-generator/template-generator.service.ts`, `settings.service.ts` (appendAuditLog) |
| Optional step names | BACKEND_DB | `rohan_api/.../template-generator/template-generator.service.ts` |
| Unit/E2E tests | TEST_REVIEW | Template-generator spec, audit-trail service spec, new page spec |
