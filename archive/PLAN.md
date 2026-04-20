# Template Generator Audit Trail Implementation Plan

## Problem Statement

Users need comprehensive audit logging for template generator activities to track all changes and state transitions. Currently, template operations (create, edit, publish, delete, draft state changes, wizard step navigation, and content modifications) are not being logged in the audit trail system. Users should be able to:

1. Access audit logs directly from the template landing page for each template (in publish, draft, or delete state)
2. View detailed audit entries with filters (Date, Email address, Action)
3. Download audit logs as CSV
4. Track all template-related activities including:
   - Text/content changes with before/after states
   - Wizard step transitions during draft creation
   - Template state changes (publish, deletion, draft transitions)

## Assumptions

1. The existing audit trail infrastructure (`/settings/audit_trail` endpoints) can be reused without modification
2. The existing audit trail UI component can be reused or adapted for template-specific views
3. Template IDs will be included in action strings for traceability
4. Wizard step tracking will use the `current_step` field from the template entity
5. Content changes will be logged with descriptive before/after information in the action string
6. The feature identifier will be `'Template-Generator'` (separate from `'Acquisition-Center'`)

## Open Questions

1. **Feature Identifier**: Should we use `'Template-Generator'` as a separate feature, or group it under `'Acquisition-Center'`?
   - **Decision**: Use `'Template-Generator'` as separate feature for better filtering granularity
2. **Content Change Granularity**: How detailed should before/after logging be for text changes?
   - **Decision**: Log section-level changes with section name/ID, not character-by-character diffs
3. **Wizard Step Naming**: What are the exact step names to use in audit logs?
   - **Decision**: Use step indices (0, 1, 2) with descriptive names: "Select Template", "Create", "Preview"
   - **Detail**: See **Detailed Plan: Wizard Step Transitions During Draft** below for flows (template / scratch / AI), when step transitions are logged, and optional alignment of backend step names with the template-flow UI.
4. **Audit Log Button Placement**: Should the button appear in the actions column or as a separate column?
   - **Decision**: Add to existing actions column as "view audit log" option (already present in completedTemplatesColumnData)
5. **Navigation**: Should audit log view be a modal, separate page, or route parameter?
   - **Decision**: Navigate to Settings > Audit Trail tab with pre-filtered feature and optional template ID filter

## Verification Summary (2026-02-02)

Completed steps (Phases 1–6 and Phase 4 TEST_REVIEW) were verified in the codebase:

- **Phase 1**: `rohan_api/src/utils/constants.ts` — `TEMPLATE_GENERATOR` enum and all `AuditTrailAction` helper methods present.
- **Phase 2**: `template-generator.module.ts` — `SettingsModule` in imports.
- **Phase 3**: `template-generator.service.ts` — `SettingsService` injected; `logAuditTrail` used in `saveTemplate`, `deleteTemplate`, `completeTemplate`, `publishTemplate`, `unpublishTemplate`, `archiveTemplate`, `restoreTemplate`, and for content/section and wizard step changes.
- **Phase 3.5**: Settings controller and service — `templateId` query param on `getAuditTrail` and `generateAuditTrailCSV`; filtering in `getAuditLogs`/`generateAuditTrailCSV`; tests in `settings.service.spec.ts` and `settings.controller.spec.ts`.
- **Phase 4**: `template-generator.service.spec.ts` — `SettingsService` mock and audit-logging tests present.
- **Phase 5**: Template audit log component, route `template-generator/:templateId/audit-log`, data fetching, "view audit log" handler in `handleTableAction` navigating to audit log page, back nav, tests.
- **Phase 6**: `AUDIT_TRAIL_FEATURES.TEMPLATE_GENERATOR` in `audit-trail.constants.ts`; component uses constant.

**Phase 6.5** was found to be **already implemented** in code but previously unchecked: `TemplateAuditLogComponent` and `AuditTrailService` pass `templateId` to API; `AuditTrailFilters` includes `templateId` (in `settings.types.ts`); component spec verifies `templateId` in API calls. Phase 6.5 checklist items are marked complete below.

**Phase 7**: "View audit log" handler and its presence in completed/published templates are implemented. Draft and archived templates do not currently include "view audit log" in their action lists; the plan leaves these as optional ("if required").

---

## Detailed Plan: Wizard Step Transitions During Draft

This section expands the Jira requirement **"During draft, which/when the template moves from various wizard steps"** into a concrete design and verification checklist.

### Goal

Users should see audit log entries that record **when** a draft template moved **from which wizard step to which step**, so they can trace the flow of draft creation (e.g. "Template 123 (My RFP) moved from step \"Create\" to step \"Preview\"").

### When Step Transitions Are Logged

- **Backend**: Step changes are logged inside `saveTemplate` when the incoming DTO has a different `current_step` than the previously persisted value (`originalStep`). No separate API call is used; logging happens as part of the same save that updates the template’s `current_step`.
- **Frontend**: The UI sends `current_step` when the user saves from the Create step (e.g. "Save & continue" or moving to Preview). So transitions are only recorded when a **save** occurs with a new step index. Navigating from "Select" to "Create" without saving does **not** create an audit entry until a subsequent save includes `current_step` (e.g. first save on Create sends `current_step: 1`).

### Wizard Flows and Step Names

| Flow         | Source / UI         | Step indices | Step names (for audit log)      | Backend `stepNames` (current)            |
| ------------ | ------------------- | ------------ | ------------------------------- | ---------------------------------------- |
| **Template** | Build from template | 0, 1, 2      | Select → Create → Preview       | `['Create', 'Preview']` (2 steps)        |
| **Scratch**  | Build from scratch  | 0, 1         | Create → Preview                | `['Create', 'Preview']`                  |
| **AI**       | Build with AI       | 0, 1, 2, 3   | Upload → Tag → Create → Preview | `['Upload', 'Tag', 'Create', 'Preview']` |

- **Template flow**: The UI has 3 steps (Select, Create, Preview). The backend currently uses only 2 names for non-AI flows, so step index `0` would display as "Step 0" in the audit message unless the backend is extended to use 3 names for `created_from === 'template'` (e.g. `['Select', 'Create', 'Preview']`).
- **Scratch flow**: 2 steps; backend names match.
- **AI flow**: 4 steps; backend names match.

### Data Flow (Current Behavior)

1. User is on a wizard step (e.g. Create). They click "Save & continue" or equivalent.
2. Frontend (e.g. `create-step` or build-from-scratch/template) calls the save API with `current_step` set to the **destination** step index (e.g. `1` for Create, `2` for Preview in template flow).
3. Backend `saveTemplate` loads the existing template, gets `originalStep = existingTemplate.current_step`, then runs the transaction and updates the template.
4. After a successful save, if `dto.current_step !== undefined && dto.current_step !== null && originalStep !== dto.current_step`, the backend calls `getWizardStepChangeAction(templateId, templateName, originalStep ?? 0, dto.current_step, stepNames)` and appends an audit log entry.
5. The audit action string format is: `Template {id} ({name}) moved from step "{fromStepName}" to step "{toStepName}"` (see `contracts.md` and `AuditTrailAction.getWizardStepChangeAction`).

### What Users See in the Audit Log

- **Example (scratch)**: `Template 456 (Draft RFP) moved from step "Create" to step "Preview"`.
- **Example (template, after backend alignment)**: `Template 789 (My SOW) moved from step "Select" to step "Create"` (only if we persist/log step 0→1) or `... from step "Create" to step "Preview"`.
- Each entry appears with timestamp, feature `Template-Generator`, and performed_by (user email). Users can filter by Date, Email, Action on the template audit log page and download CSV.

### Implementation Status (Reference)

- Backend logging for step changes is implemented in Phase 3 (see checklist): `saveTemplate` compares `originalStep` to `dto.current_step` and logs via `getWizardStepChangeAction` with step names derived from `created_from` (ai vs non-ai).
- Frontend sends `current_step` from the Create step when saving (template and scratch flows). No frontend-only audit calls are required for step transitions.

### Verification / Optional Improvements Checklist

- [ ] **[BACKEND_DB]** (Optional) Align step names for **template** flow with UI: use 3 names when `created_from === 'template'` (e.g. `['Select', 'Create', 'Preview']`) so that step index 0 logs as "Select" instead of "Step 0".

  - **File**: `rohan_api/src/template-generator/template-generator.service.ts`
  - **Change**: In the block where `stepNames` is set (around the wizard step change log), add a branch for `result.created_from === 'template'` with `['Select', 'Create', 'Preview']`; keep `['Create', 'Preview']` for scratch and existing logic for `'ai'`.

- [ ] **[FRONTEND]** (Optional) If product wants a step transition logged when user leaves "Select" and enters "Create" (template flow) without saving content, consider calling save (or a dedicated step-update) with `current_step: 1` when transitioning Select → Create so that an audit entry is created.

  - **Files**: `rohan_ui/.../build-from-template/build-from-template.component.ts` (e.g. in `templateSelected` or after `getTemplateById`/stepper.next).
  - **Note**: Current behavior only logs steps when the user saves from Create or moves to Preview with save; Select → Create does not persist step change today.

- [ ] **[TEST_REVIEW]** Manual test: Create a draft (scratch or template), move from Create to Preview with save, open template audit log and confirm entry: `... moved from step "Create" to step "Preview"`.
- [ ] **[TEST_REVIEW]** Manual test: (If backend step names updated) In template flow, verify step names in audit log match UI labels (Select, Create, Preview).

---

## Implementation Checklist

### Phase 1: Backend - Constants and Enums

- [x] **[BACKEND_DB]** Add `TEMPLATE_GENERATOR` to `AuditTrailFeature` enum

  - **File**: `rohan_api/src/utils/constants.ts`
  - **Change**: Add `TEMPLATE_GENERATOR = 'Template-Generator'` to enum

- [x] **[BACKEND_DB]** Add helper methods to `AuditTrailAction` class for template operations
  - **File**: `rohan_api/src/utils/constants.ts`
  - **Methods to add**:
    - `getGenerateTemplateAction(templateId: number, templateName: string): string`
    - `getEditTemplateAction(templateId: number, templateName: string): string`
    - `getDeleteTemplateAction(templateId: number, templateName: string): string`
    - `getPublishTemplateAction(templateId: number, templateName: string): string`
    - `getUnpublishTemplateAction(templateId: number, templateName: string): string`
    - `getArchiveTemplateAction(templateId: number, templateName: string): string`
    - `getRestoreTemplateAction(templateId: number, templateName: string): string`
    - `getWizardStepChangeAction(templateId: number, templateName: string, fromStep: number, toStep: number, stepNames: string[]): string`
    - `getContentChangeAction(templateId: number, templateName: string, sectionName: string, changeType: 'added' | 'modified' | 'deleted'): string`
    - `getStateChangeAction(templateId: number, templateName: string, fromStatus: string, toStatus: string): string`

### Phase 2: Backend - Module Dependencies

- [x] **[BACKEND_DB]** Ensure `TemplateGeneratorModule` imports `SettingsModule`
  - **File**: `rohan_api/src/template-generator/template-generator.module.ts`
  - **Change**: Verify `SettingsModule` is in imports array, add if missing

### Phase 3: Backend - Service Logging

- [x] **[BACKEND_DB]** Inject `SettingsService` into `TemplateGeneratorService`

  - **File**: `rohan_api/src/template-generator/template-generator.service.ts`
  - **Change**: Add `SettingsService` to constructor dependencies

- [x] **[BACKEND_DB]** Add audit logging to `saveTemplate` method

  - **File**: `rohan_api/src/template-generator/template-generator.service.ts`
  - **Change**: Log template creation or update with appropriate action
  - **Condition**: Log "Generated template" for new templates, "Edited template" for updates
  - **Include**: Track wizard step changes if `current_step` is provided

- [x] **[BACKEND_DB]** Add audit logging to `deleteTemplate` method

  - **File**: `rohan_api/src/template-generator/template-generator.service.ts`
  - **Change**: Log template deletion before actual deletion

- [x] **[BACKEND_DB]** Add audit logging to `completeTemplate` method

  - **File**: `rohan_api/src/template-generator/template-generator.service.ts`
  - **Change**: Log state change from DRAFT to COMPLETED

- [x] **[BACKEND_DB]** Add audit logging to `publishTemplate` method

  - **File**: `rohan_api/src/template-generator/template-generator.service.ts`
  - **Change**: Log state change to PUBLISHED

- [x] **[BACKEND_DB]** Add audit logging to `unpublishTemplate` method

  - **File**: `rohan_api/src/template-generator/template-generator.service.ts`
  - **Change**: Log state change from PUBLISHED to COMPLETED

- [x] **[BACKEND_DB]** Add audit logging to `archiveTemplate` method

  - **File**: `rohan_api/src/template-generator/template-generator.service.ts`
  - **Change**: Log state change to ARCHIVED

- [x] **[BACKEND_DB]** Add audit logging to `restoreTemplate` method

  - **File**: `rohan_api/src/template-generator/template-generator.service.ts`
  - **Change**: Log state change from ARCHIVED to COMPLETED

- [x] **[BACKEND_DB]** Add audit logging for content/section changes

  - **File**: `rohan_api/src/template-generator/template-generator.service.ts`
  - **Change**: In `saveTemplate`, compare old vs new sections and log additions/modifications/deletions
  - **Note**: This may require comparing existing sections with incoming DTO sections

- [x] **[BACKEND_DB]** Add audit logging for wizard step transitions
  - **File**: `rohan_api/src/template-generator/template-generator.service.ts`
  - **Change**: In `saveTemplate`, if `current_step` changes, log the step transition
  - **Note**: Step names: 0="Select Template", 1="Create", 2="Preview" (for template flow) or 0="Create", 1="Preview" (for scratch flow)

### Phase 3.5: Backend - API Enhancement for Template ID Filtering

- [x] **[BACKEND_DB]** Add `templateId` query parameter to `getAuditTrail` controller method

  - **File**: `rohan_api/src/settings/settings.controller.ts`
  - **Change**: Add `@Query('templateId') templateId?: number` parameter to `getAuditTrail` method
  - **Change**: Pass `templateId` to `settingsService.getAuditLogs` call

- [x] **[BACKEND_DB]** Update `getAuditLogs` service method to accept and filter by `templateId`

  - **File**: `rohan_api/src/settings/settings.service.ts`
  - **Change**: Add `templateId?: number` parameter to `getAuditLogs` method signature (after `actionType` parameter)
  - **Change**: Add filtering logic to match template ID by parsing action strings
  - **Implementation**: When `templateId` is provided, add SQL WHERE clause: `audit.action LIKE :templatePattern`
  - **Pattern**: Use pattern `Template {templateId}` (case-insensitive) to match action strings like "Template 123 (Name) generated"
  - **Example**: `query.andWhere('LOWER(audit.action) LIKE LOWER(:templatePattern)', { templatePattern: `Template ${templateId}` })`

- [x] **[BACKEND_DB]** Add tests for template ID filtering in `settings.service.spec.ts`

  - **File**: `rohan_api/src/settings/settings.service.spec.ts`
  - **Tests**: Verify filtering by templateId returns only matching audit log entries
  - **Tests**: Verify templateId filter works in combination with other filters (feature, date, etc.)
  - **Tests**: Include non-matching template IDs in test data to verify filtering actually excludes them

- [x] **[BACKEND_DB]** Add tests for template ID filtering in `settings.controller.spec.ts`

  - **File**: `rohan_api/src/settings/settings.controller.spec.ts`
  - **Tests**: Verify controller passes templateId parameter to service correctly

- [x] **[BACKEND_DB]** Add `templateId` query parameter to CSV endpoint

  - **File**: `rohan_api/src/settings/settings.controller.ts`
  - **Change**: Add `@Query('templateId') templateId?: number` parameter to `generateAuditTrailCSV` method
  - **Change**: Pass `templateId` to `settingsService.generateAuditTrailCSV` call

- [x] **[BACKEND_DB]** Update `generateAuditTrailCSV` service method to accept and pass `templateId` to `getAuditLogs`
  - **File**: `rohan_api/src/settings/settings.service.ts`
  - **Change**: Add `templateId?: number` parameter to `generateAuditTrailCSV` method signature
  - **Change**: Pass `templateId` to `getAuditLogs` call (which already handles the filtering)

### Phase 4: Backend - Testing

- [x] **[TEST_REVIEW]** Update `template-generator.service.spec.ts` to mock `SettingsService`

  - **File**: `rohan_api/src/template-generator/template-generator.service.spec.ts`
  - **Change**: Add `SettingsService` mock to test setup

- [x] **[TEST_REVIEW]** Add tests for audit logging in template operations
  - **File**: `rohan_api/src/template-generator/template-generator.service.spec.ts`
  - **Tests**: Verify `appendAuditLog` is called with correct parameters for:
    - Template creation
    - Template update
    - Template deletion
    - State changes (publish, unpublish, archive, restore, complete)
    - Wizard step changes
    - Content/section changes

### Phase 5: Frontend - Template-Specific Audit Log Page

- [x] **[FRONTEND]** Create new component for template-specific audit log page

  - **File**: `rohan_ui/src/app/pages/acquisition-center/components/template-generator/template-audit-log/template-audit-log.component.ts`
  - **File**: `rohan_ui/src/app/pages/acquisition-center/components/template-generator/template-audit-log/template-audit-log.component.html`
  - **File**: `rohan_ui/src/app/pages/acquisition-center/components/template-generator/template-audit-log/template-audit-log.component.scss`
  - **Change**: Create new component that displays audit logs filtered by template ID
  - **Features**:
    - Table design matching audit trail page (timestamp, feature, action, performed_by columns)
    - Filters: Date, Email address, Action
    - Download CSV button
    - Shows all results on one page (no pagination/infinite scroll)
    - Pre-filter by feature='Template-Generator' and template ID from route parameter

- [x] **[FRONTEND]** Add route for template audit log page

  - **File**: `rohan_ui/src/app/pages/acquisition-center/procurement-writer-routing.module.ts`
  - **Change**: Add route: `/acquisition-center/template-generator/:templateId/audit-log`
  - **Component**: Use `TemplateAuditLogComponent`

- [x] **[FRONTEND]** Implement audit log data fetching in `TemplateAuditLogComponent`

  - **File**: `rohan_ui/src/app/pages/acquisition-center/components/template-generator/template-audit-log/template-audit-log.component.ts`
  - **Change**:
    - Inject `ActivatedRoute` to get template ID from route params
    - Inject `AuditTrailService` to fetch audit logs
    - Pass templateId query parameter to API (backend filtering)
    - Filter by feature='Template-Generator' and templateId
    - Implement filter handlers (date, email, action)
    - Implement CSV download functionality
    - Fetch all results at once (pageSize: 10000) - no pagination/infinite scroll
  - **Note**: Initial implementation may use client-side filtering; Phase 6.5 will update to use backend templateId filtering

- [x] **[FRONTEND]** Reuse or adapt audit trail table component

  - **File**: `rohan_ui/src/app/pages/acquisition-center/components/template-generator/template-audit-log/template-audit-log.component.html`
  - **Change**:
    - Use similar table structure as `audit-trail.component.html`
    - Include filter UI (date range, email, action)
    - Include CSV download button
    - Display audit log records in table format

- [x] **[FRONTEND]** Update "view audit log" action handler to navigate to new page

  - **File**: `rohan_ui/src/app/pages/acquisition-center/components/template-generator/template-generator.component.ts`
  - **Change**: In `handleTableAction` method, when action is `'view audit log'`, navigate to `/acquisition-center/template-generator/${templateId}/audit-log`

- [x] **[FRONTEND]** Add back navigation to template generator landing page

  - **File**: `rohan_ui/src/app/pages/acquisition-center/components/template-generator/template-audit-log/template-audit-log.component.html`
  - **Change**: Add back button/link to return to template generator landing page

- [x] **[FRONTEND]** Add tests for template audit log component
  - **File**: `rohan_ui/src/app/pages/acquisition-center/components/template-generator/template-audit-log/template-audit-log.component.spec.ts`
  - **Tests**:
    - Verify component loads with template ID from route
    - Verify audit logs are fetched with correct filters (feature and templateId)
    - Verify filters work correctly
    - Verify CSV download functionality
    - Verify navigation back to template generator
  - **Note**: Initial tests may verify client-side filtering; Phase 6.5 will update tests to verify backend templateId filtering

### Phase 6: Frontend - Constants

- [x] **[FRONTEND]** Add `TEMPLATE_GENERATOR` to `AUDIT_TRAIL_FEATURES` constant

  - **File**: `rohan_ui/src/app/shared-services/audit-trail/audit-trail.constants.ts`
  - **Change**: Add `TEMPLATE_GENERATOR: 'Template-Generator'` to constant object

- [x] **[FRONTEND]** Update `AuditTrailFeature` type to include new feature

  - **File**: `rohan_ui/src/app/shared-services/audit-trail/audit-trail.constants.ts`
  - **Change**: Type will automatically include new feature via `typeof AUDIT_TRAIL_FEATURES`

- [x] **[FRONTEND]** Refactor template audit log component to use constant
  - **File**: `rohan_ui/src/app/pages/acquisition-center/components/template-generator/template-audit-log/template-audit-log.component.ts`
  - **Change**: Replace all string literals `'Template-Generator'` with `AUDIT_TRAIL_FEATURES.TEMPLATE_GENERATOR`

### Phase 6.5: Frontend - Update to Use Backend Template ID Filtering

- [x] **[FRONTEND]** Update `TemplateAuditLogComponent` to use backend `templateId` query parameter

  - **File**: `rohan_ui/src/app/pages/acquisition-center/components/template-generator/template-audit-log/template-audit-log.component.ts`
  - **Change**: Update `AuditTrailService` calls to include `templateId` query parameter
  - **Change**: Remove any client-side template ID filtering/parsing logic
  - **Change**: Pass `templateId` from route parameter directly to API calls
  - **API Calls to Update**:
    - `getAuditTrail()` - add `templateId` to query parameters
    - `getAuditTrailCSV()` - add `templateId` to query parameters

- [x] **[FRONTEND]** Update `AuditTrailService` to support `templateId` parameter (if not already supported)

  - **File**: `rohan_ui/src/app/shared-services/audit-trail/audit-trail.service.ts`
  - **Change**: Add `templateId?: number` parameter to `getAuditTrail()` method
  - **Change**: Add `templateId?: number` parameter to `getAuditTrailCSV()` method
  - **Change**: Pass `templateId` as query parameter in HTTP requests

- [x] **[FRONTEND]** Update `AuditTrailFilters` type to include `templateId` (if needed)

  - **File**: `rohan_ui/src/app/pages/settings/types/settings.types.ts`
  - **Change**: Add `templateId?: number` to `AuditTrailFilters` type definition

- [x] **[FRONTEND]** Update tests for `TemplateAuditLogComponent` to verify backend filtering

  - **File**: `rohan_ui/src/app/pages/acquisition-center/components/template-generator/template-audit-log/template-audit-log.component.spec.ts`
  - **Change**: Update tests to verify `templateId` is passed as query parameter to API
  - **Change**: Remove tests for client-side template ID parsing/filtering
  - **Change**: Verify API is called with correct `templateId` parameter

- [x] **[FRONTEND]** Update CSV download to use backend `templateId` filtering

  - **File**: `rohan_ui/src/app/pages/acquisition-center/components/template-generator/template-audit-log/template-audit-log.component.ts`
  - **Change**: Ensure CSV download includes `templateId` in query parameters
  - **Change**: Verify CSV contains only entries for the specific template

- [x] **[TEST_REVIEW]** Manual testing: Verify backend filtering works correctly
  - **Steps**:
    - Navigate to template audit log page
    - Verify only audit logs for that specific template are displayed
    - Verify filters (date, email, action) still work correctly with templateId
    - Verify CSV download only includes entries for that template
    - Test with multiple templates to ensure filtering is accurate

### Phase 7: Frontend - Template Landing Page Integration

- [x] **[FRONTEND]** Verify "view audit log" action handler navigates to template-specific audit log page

  - **File**: `rohan_ui/src/app/pages/acquisition-center/components/template-generator/template-generator.component.ts`
  - **Note**: Implemented in `handleTableAction` (Phase 5); navigates to `/acquisition-center/template-generator/${id}/audit-log`

- [x] **[FRONTEND]** Verify "view audit log" appears in actions for completed/published templates

  - **File**: `rohan_ui/src/app/pages/acquisition-center/components/template-generator/template-generator.component.ts`
  - **Note**: Present in `completedTemplatesColumnData.actionList` (VIEW_AUDIT_LOG first in list)

- [x] **[FRONTEND]** Add "view audit log" action to draft templates (if required) - not needed

  - **File**: `rohan_ui/src/app/pages/acquisition-center/components/template-generator/template-generator.component.ts`
  - **Change**: Add `'view audit log'` to `draftTemplatesColumnData.actionList` if needed
  - **Note**: Product decision; currently draft actions are EDIT, DELETE only

- [x] **[FRONTEND]** Add "view audit log" action to archived templates (if required) - not needes

  - **File**: `rohan_ui/src/app/pages/acquisition-center/components/template-generator/template-generator.component.ts`
  - **Change**: Add `'view audit log'` to `archivedTemplatesColumnData.actionList` if needed
  - **Note**: Product decision; currently archived actions are RESTORE, DELETE only

### Phase 8: Frontend - Component Logging (Optional - User Interactions)

- [ ] **[FRONTEND]** Inject `AuditTrailService` into template generator components

  - **Files**:
    - `rohan_ui/src/app/pages/acquisition-center/components/template-generator/template-generator.component.ts`
    - `rohan_ui/src/app/pages/acquisition-center/components/template-generator/build-from-scratch/build-from-scratch.component.ts`
    - `rohan_ui/src/app/pages/acquisition-center/components/template-generator/build-from-template/build-from-template.component.ts`
    - `rohan_ui/src/app/pages/acquisition-center/components/template-generator/create-step/create-step.component.ts`
    - `rohan_ui/src/app/pages/acquisition-center/components/template-generator/preview-step/preview-step.component.ts`
  - **Change**: Add `AuditTrailService` to constructor

- [ ] **[FRONTEND]** Add user interaction logging (optional - for client-side tracking)
  - **Files**: Template generator components
  - **Actions to log**:
    - View template details
    - Navigate between wizard steps
    - Save template (draft)
    - Export template
  - **Note**: Backend logging is primary; frontend logging is supplementary

### Phase 9: Frontend - Settings Integration

- [ ] **[FRONTEND]** Verify `AuditTrailManager` includes `'Template-Generator'` in allowed features

  - **File**: `rohan_ui/src/app/pages/settings/utility/audit-trail-manager.ts`
  - **Change**: Add `'Template-Generator'` to `procureAllowedAuditTrailFilterFeatures` array if filtering is restricted

- [ ] **[FRONTEND]** Test audit trail filters work with `'Template-Generator'` feature
  - **File**: `rohan_ui/src/app/pages/settings/components/audit-trail/audit-trail.component.ts`
  - **Verification**: Feature should appear in feature dropdown filter

### Phase 10: Frontend - Testing

- [ ] **[TEST_REVIEW]** Update template generator component tests to mock `AuditTrailService`

  - **Files**: `rohan_ui/src/app/pages/acquisition-center/components/template-generator/**/*.spec.ts`
  - **Change**: Add `AuditTrailService` mock where needed

- [ ] **[TEST_REVIEW]** Add tests for "view audit log" navigation
  - **File**: `rohan_ui/src/app/pages/acquisition-center/components/template-generator/template-generator.component.spec.ts`
  - **Test**: Verify navigation to settings with correct filters

### Phase 11: Manual Testing & Verification

- [ ] **[TEST_REVIEW]** Manual E2E testing: Create a new template and verify audit log entry

  - **Steps**: Create template via wizard, check audit trail for "Generated template" entry

- [ ] **[TEST_REVIEW]** Manual E2E testing: Edit template content and verify audit log

  - **Steps**: Modify template sections, check for "Edited template" and content change entries

- [ ] **[TEST_REVIEW]** Manual E2E testing: Navigate wizard steps and verify step transition logging

  - **Steps**: Move between wizard steps, verify step change entries in audit log

- [ ] **[TEST_REVIEW]** Manual E2E testing: Publish/unpublish template and verify state change logging

  - **Steps**: Publish template, verify "Published template" entry; unpublish, verify entry

- [ ] **[TEST_REVIEW]** Manual E2E testing: Archive/restore template and verify logging

  - **Steps**: Archive template, verify entry; restore, verify entry

- [ ] **[TEST_REVIEW]** Manual E2E testing: Delete template and verify logging

  - **Steps**: Delete template, verify "Deleted template" entry appears

- [ ] **[TEST_REVIEW]** Manual E2E testing: Test "view audit log" button navigation

  - **Steps**: Click "view audit log" from template table, verify navigation to template-specific audit log page with correct template ID
  - **Verify**: Page displays only audit logs for that specific template

- [ ] **[TEST_REVIEW]** Manual E2E testing: Test audit trail filters (Date, Email, Action, Feature)

  - **Steps**: Apply filters, verify results are correctly filtered

- [ ] **[TEST_REVIEW]** Manual E2E testing: Test CSV download
  - **Steps**: Download CSV, verify it contains template generator audit entries

## Notes

- No database schema changes required - existing `audit_trail` table supports all needed fields
- No new API endpoints required - reuse existing `/settings/audit_trail` and `/settings/audit_trail_csv` endpoints
- Backend logging is the primary source of truth (more reliable, cannot be bypassed)
- Frontend logging is optional and supplementary (for user interaction tracking)
- Action strings are free-form text - use descriptive, human-readable messages
- Auto-cleanup: Audit entries are automatically archived after 6 months (handled by database trigger)
- Template ID should be included in action strings for traceability: `"Generated template 123 (Template Name)"`

## Reference Files

### Backend

- Audit trail entity: `rohan_api/src/settings/entities/audit_trail.entity.ts`
- Audit trail DTOs: `rohan_api/src/settings/dto/audit_trail.dto.ts`
- Settings service: `rohan_api/src/settings/settings.service.ts`
- Settings controller: `rohan_api/src/settings/settings.controller.ts`
- Constants: `rohan_api/src/utils/constants.ts`
- Template generator service: `rohan_api/src/template-generator/template-generator.service.ts`
- Template generator module: `rohan_api/src/template-generator/template-generator.module.ts`
- Template entity: `rohan_api/src/template-generator/entities/procurement-template.entity.ts`

### Frontend

- Audit trail service: `rohan_ui/src/app/shared-services/audit-trail/audit-trail.service.ts`
- Audit trail constants: `rohan_ui/src/app/shared-services/audit-trail/audit-trail.constants.ts`
- Audit trail component: `rohan_ui/src/app/pages/settings/components/audit-trail/audit-trail.component.ts`
- Settings component: `rohan_ui/src/app/pages/settings/root/settings.component.ts`
- Audit trail manager: `rohan_ui/src/app/pages/settings/utility/audit-trail-manager.ts`
- Template generator component: `rohan_ui/src/app/pages/acquisition-center/components/template-generator/template-generator.component.ts`
