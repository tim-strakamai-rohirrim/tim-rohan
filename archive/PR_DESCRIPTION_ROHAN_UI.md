#### Summary

- Adds a **template wizard** so that clicking a published template card creates a procurement and opens a 2-step wizard (Needs Statement → Analysis), then navigates to the editor, matching the RFI wizard flow.
- Reuses shared wizard building blocks (`SingleRteStepComponent`, `DocumentLibraryComponent`, `ActivityPanelComponent`) and the existing analysis streaming endpoint (`/procurement-writer/rfi-draft?stream=true`) so behavior stays consistent with RFI/MRA.
- Ensures **template-based procurements** are created via `GET /procurement-templates/:id` and `POST /procurement-writer` with `template_id`; section conversion for the editor is done on the backend.

#### Technical Details

- **Frontend:**
  - **TemplateWizardComponent** (`components/workspace/template-wizard/template-wizard.component.ts`)
    - Two steps: Needs Statement (Step 1) and Analysis (Step 2), using `SingleRteStepComponent` for both.
    - Step 1: context RTE, optional `DocumentLibraryComponent` when `highSideEnabled`; "Run Request" triggers analysis.
    - Step 2: streaming analysis, `ActivityPanelComponent` for activity/sources; "Generate Document" navigates to editor.
    - Wizard state save/restore via `ProcurementWriterService` with `type` = `procurement.template_id`.
    - Implements `UnsavedChangesProtection`; uses `UnsavedChangesGuard` on the route.
  - **TemplateWizardService** (`template-wizard-service/template-wizard.service.ts`)
    - `getAnalysis(context, documentIds, templateId?, procurementId?)` calls `POST /procurement-writer/rfi-draft?stream=true` with `useAnalysisAssistantPrompt` (RBAC) and token-limit check.
  - **Routing:** New child route `procurement/:procurement_id/template-wizard` under acquisition-center, with `UnsavedChangesGuard`.
  - **Landing page:** `navigateToProcurement()` updated: after highSide → analysis-assistant and title-based RFI/MRA, any procurement with `template_id` goes to `template-wizard`.
  - **ProcurementWriterService:**
    - `getTemplate(templateId)`: mock path for `rfi`/`mra` (CSV); for other IDs calls `GET /procurement-templates/:id` and returns a `Template` with metadata and `sections: []` (sections are resolved by backend on create).
    - `newProcurement(templateStub)` → `getTemplate()` then `createNewProcurementFromTemplate()`; request body includes `template_id`, `template_title`, and `sections` (empty for API templates).
  - **Features:** `TEMPLATE_WIZARD` added in `shared-types/modify-text.types.ts`.
  - **Module:** Template wizard component and route registered in `procurement-writer-routing.module.ts` and `procurement-writer.module.ts`.

- **Backend:**  
  No changes in this PR (template section conversion and procurement create behavior live in the backend).

- **Database:**  
  No changes in this PR.

- **Contracts:**
  - Reuses `GET /procurement-templates/:id` (template metadata; frontend does not send section payload for create).
  - Reuses `POST /procurement-writer` with `template_id`, `template_title`, `title`, and `sections` (empty for published templates; backend fills sections from template).
  - Reuses `POST /procurement-writer/rfi-draft?stream=true` with optional `templateId`, `procurementId`; same streaming/analysis contract as RFI.
  - Wizard state stored in procurement `wizard_state`; shape unchanged, with `type` set to `template_id` for template wizard.

#### Testing

- **Manual:**
  - Landing page → click published template card → procurement created → redirect to template wizard.
  - Step 1: enter context, (if highSide) attach documents, "Run Request" → Step 2.
  - Step 2: analysis streams, activity/sources in side panel, "Generate Document" → editor.
  - With highSide: save wizard state, leave and re-enter wizard, state restored.
  - Navigation: RFI/MRA titles still go to rfi-assistant/mra-assistant; other `template_id` go to template-wizard.

- **Automated:**
  - **Karma/Jasmine:**
    - `template-wizard.component.spec.ts`: init, state restore, step config (both steps use `TEMPLATE_WIZARD`), `getAnalysis`/`generate`/`saveState`, token limit, guard behavior.
    - `template-wizard.service.spec.ts`: `getAnalysis` endpoint and params, optional `templateId`/`procurementId`, token limit, categories.
    - `procurement-writer.service.spec.ts`: `getTemplate` for mock (rfi/mra) vs API (non-mock ID returns `sections: []`), `getTemplateStubs`, `transformTemplateToPreview`, error handling.
    - `procurement-writer-landing-page.component.spec.ts`: `navigateToProcurement` — template-wizard for custom `template_id`, rfi-assistant for RFI, mra-assistant for MRA, analysis-assistant when highSide and no template_id.
  - **Playwright:** No E2E tests added in this PR.
  - **Jest:** N/A (backend in separate PR).

- **Known gaps / TODO:**
  - E2E coverage for full flow (landing → template card → wizard → editor) not added.
  - Secondary nav for template sections in editor (planned Phase 6) not implemented.
  - Optional: stronger UX for "template not found" (e.g. toast or redirect).

#### Risks & Impact

- **Breaking changes:** None; additive route and wizard; RFI/MRA and highSide behavior unchanged.
- **Performance:** One extra `GET /procurement-templates/:id` when creating from a published template; analysis reuses existing streaming endpoint.
- **Security:** Analysis uses same RBAC (`useAnalysisAssistantPrompt`); wizard state only when `highSideEnabled`.
- **Rollout:** Feature gated by existing template generator / landing behavior; no migration.

#### Verification Steps for Reviewers

1. **Template wizard entry**
   - Go to acquisition center landing, click a published template card (not RFI/MRA).
   - Confirm new procurement is created and URL is `/acquisition-center/procurement/{id}/template-wizard` and both steps (Needs Statement, Analysis) are visible.

2. **Step 1 → Step 2**
   - Enter text in Step 1; if highSide, confirm document library is shown.
   - Click "Run Request"; confirm Step 2 loads and analysis stream and activity panel behave as in RFI.

3. **Step 2 → Editor**
   - After analysis completes, click "Generate Document"; if not highSide, confirm confirmation dialog.
   - Confirm redirect to `/acquisition-center/procurement/{id}/editor`.

4. **State (highSide)**
   - Complete Step 1, go to Step 2, save.
   - Navigate away and back to the same procurement’s template-wizard; confirm step, context, and analysis (and sources) are restored.

5. **Routing**
   - Create from RFI template → rfi-assistant; from MRA → mra-assistant; from another published template → template-wizard.
   - With highSide, create from template → analysis-assistant (highSide branch takes precedence).

6. **Errors**
   - Invalid or missing template ID: confirm create/template fetch fails gracefully (no uncaught errors).
   - Very large context: confirm token-limit check and user-visible feedback.
