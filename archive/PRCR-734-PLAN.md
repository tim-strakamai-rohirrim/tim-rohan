# PRCR-734: Published Template Builds New Wizard for Use

## Problem Statement

When a user publishes a template via Template Generator, it should generate a new card in the Procurement Projects section. When users click this card, they should be able to use a wizard to create a procurement project from that template. The wizard should mirror the current RFI wizard structure and reuse shared components.

Currently:

- Published templates appear as cards in Procurement Projects (from PRCR-697)
- Clicking a card creates a procurement but doesn't navigate to a wizard
- Templates have a preview step that shows how the draft document should look
  q/- RFI wizard exists with Needs Statement → Analysis flow (2 steps, then navigates to editor)
- No generic template wizard exists for published templates

## Assumptions

1. **Wizard structure**: The template wizard should mirror RFI wizard with 2 steps:
   - Step 1: Needs Statement (context input + document uploads)
   - Step 2: Analysis (uses root prompts with RBAC-based deep research/pgvector)
   - After Step 2, navigate to editor (same as RFI wizard)
   - **Template sections flow**: When a user clicks a template card:
     - Template is fetched from database via `GET /procurement-templates/:id` endpoint (`template-generator.controller.ts:85`) which calls `templateGeneratorService.findOne(id)` - this includes unique sections from `procurement_template_sections` table
     - Procurement is created with template sections included in the request
     - Backend converts template sections to procurement sections format
     - Each template has unique sections stored in the database, making each wizard unique based on `template_id`
     - Template sections are displayed in the editor after wizard completion

2. **Shared components**: The wizard should reuse existing shared wizard components:
   - `SingleRteStepComponent` for Steps 1 and 2
   - `DocumentLibraryComponent` for document uploads (if highSideEnabled)
   - `ActivityPanelComponent` for Step 2 activity/sources

3. **Prompt selection**: Step 2 Analysis should use `analysis_assistant` prompt (same as RFI) with RBAC-based model switching (deep research vs pgvector).

4. **Template identification**: The wizard should identify which template it's for via `procurement.template_id` or `procurement.template_title`. Each template has unique sections stored in the database (`procurement_template_sections` table), which are fetched via `GET /procurement-templates/:id` endpoint (`template-generator.controller.ts:85`) when the template is loaded and used to create the procurement.

5. **Draft document display**: After completing the wizard, users navigate to the editor where template sections/questions are displayed in the same format as the template generator preview, with sections visible in secondary nav. These sections come from the database entry for that specific template, making each wizard unique.

6. **Navigation flow**: After clicking a template card:
   - Create procurement from template (existing flow)
   - Navigate to template wizard: `/acquisition-center/procurement/{procurement_id}/template-wizard`
   - Complete Step 1 (Needs Statement) and Step 2 (Analysis)
   - Navigate to editor after Step 2 completion (same as RFI wizard)

7. **Secondary nav**: The secondary nav should show template sections (like preview step) when in the editor, using hierarchical structure matching the template generator preview.

8. **Wizard state saving**: The wizard should support state saving (like RFI) if `highSideEnabled` is true. Use `WizardState.type = procurement.template_id` to identify template-specific wizard state.

9. **Template sections mapping**: Template sections (`TemplateSection`/`TemplateSubSection`) are stored in the database (`procurement_template_sections` table) for each template. When a procurement is created from a template:
   - Template sections are fetched from the database via `GET /procurement-templates/:id` endpoint (`template-generator.controller.ts:85`) which includes sections via `procurement_template_id`
   - Sections are included in the procurement creation request
   - Backend converts template sections to procurement sections (`Section` with `Question[]`) format
   - Each template has unique sections, making each wizard unique based on the template's database entry

## Open Questions

1. **Wizard routing**: Should the wizard route be generic (`/template-wizard`) or template-specific (`/template-{template_id}-wizard`)?
   - **Decision**: Generic route `/template-wizard` with template identified from procurement context.

2. **Step 2 prompt**: Should Step 2 use `analysis_assistant` (same as RFI) or should templates define custom prompts?
   - **Decision**: Use `analysis_assistant` for now, with option to extend to template-specific prompts later.

3. **Draft document generation**: Should the editor auto-generate content for all sections/questions, or show empty template structure?
   - **Decision**: Show template structure with empty fields initially (user can generate per section/question via magic wand).

4. **Template section conversion**: How should `TemplateSubSection` (with `instructions_text`, `field_prompt`, etc.) be converted to `Question` format?
   - **Decision**: Map `TemplateSubSection` → `Question`:
     - `section_title` → `Question.field` (or section grouping)
     - `instructions_text` → `Question.instructions_text`
     - `field_prompt` → `Question.field_prompt`
     - `helper_text` → `Question.helper_text`
     - `answer_text` → `null` (empty initially)

5. **Secondary nav sections**: Should secondary nav show all template sections or only top-level sections?
   - **Decision**: Use hierarchical structure matching preview (shows both `TemplateSection` and `TemplateSubSection` in hierarchical format).

6. **Wizard type identification**: How should the wizard service identify this is a "template" wizard vs "rfi" wizard for state saving?
   - **Decision**: Use `WizardState.type = procurement.template_id` (template-specific state identification).

7. **Confirmation dialog**: Should Step 2 → Editor have a confirmation dialog like RFI?
   - **Decision**: Only if `highSideEnabled` is false (mirror RFI behavior).

## Implementation Checklist

### Phase 1: Backend - Template Section Conversion (if needed)

- [x] **[BACKEND_DB]** Verify template sections can be converted to procurement sections
  - **File**: `rohan_api/src/template-generator/template-generator.service.ts` or new service method
  - **Action**: Add method to convert `TemplateSubSection[]` → `Section[]` with `Question[]`
  - **Mapping**:
    - Group `TemplateSubSection` by `template_section_id` or `section_title`
    - Each `TemplateSubSection` becomes a `Question`:
      - `question_id`: Generate UUID or sequential ID
      - `field`: `section_indicator` or `section_title`
      - `helper_text`: `helper_text || ''`
      - `instructions_text`: `instructions_text`
      - `field_prompt`: `field_prompt`
      - `answer_text`: `null`
  - **Note**: Backend has `convertTemplateSectionsToProcurementSections()` method. Conversion happens when creating procurement from template.

- [x] **[BACKEND_DB]** Verify template sections are fetched when creating procurement
  - **File**: `rohan_api/src/template-generator/template-generator.controller.ts` (lines 82-90) and `rohan_api/src/template-generator/template-generator.service.ts`
  - **Endpoint**: `GET /procurement-templates/:id` (controller line 85)
  - **Action**: Verify that when creating procurement from template, template is fetched via `GET /procurement-templates/:id` endpoint which calls `templateGeneratorService.findOne(id)`
  - **Service Method**: `findOne(id: number)` in `template-generator.service.ts` (line 101) fetches template with sections from database using relations `['sections', 'owner']` and orders sections by `sort_order`
  - **Purpose**: Ensure unique template sections from database are used for each template wizard
  - **Note**: Template sections are stored in `procurement_template_sections` table and fetched when template is loaded via this endpoint. When creating procurement, sections are included in the request payload.

### Phase 2: Frontend - Template Wizard Component Structure

- [x] **[FRONTEND]** Create template wizard component
  - **File**: `rohan_ui/src/app/pages/acquisition-center/components/workspace/template-wizard/template-wizard.component.ts`
  - **Structure**: Mirror `RfiAssistantComponent` structure
  - **Properties**:
    - `documentIds = signal<number[]>([])`
    - `stepIndex = 0`
    - `lastCompletedStepIndex = -1`
    - `context = signal<string>('')`
    - `analysis = signal<string>('')`
    - `analysisStream = signal<Observable<string> | null>(null)`
    - `activitySignal = signal<ActivityItem[] | null>(null)`
    - `sourcesSignal = signal<Source[] | null>(null)`
    - `showSaveButton = ProcurementWriterUtils.highSideEnabled`
  - **Methods**:
    - `getAnalysis()`: Call analysis service with context and documentIds
    - `generate()`: Navigate to editor with analysis context
    - `saveState()`: Save wizard state if highSideEnabled (use `type = procurement.template_id`)
  - **Template**: `template-wizard.component.html` (mirror `rfi-assistant.component.html`)

- [x] **[FRONTEND]** Create template wizard service
  - **File**: `rohan_ui/src/app/pages/acquisition-center/components/workspace/template-wizard/template-wizard-service/template-wizard.service.ts`
  - **Structure**: Mirror `RfiAssistantService`
  - **Method**: `getAnalysis(context: string, documentIds: number[]): Observable<ThinkingStreamResponse>`
  - **Implementation**: Use `analysis_assistant` prompt via `ProcurementWriterService` or similar

- [x] **[FRONTEND]** Create template wizard service provider
  - **File**: `rohan_ui/src/app/pages/acquisition-center/components/workspace/template-wizard/template-wizard-service/template-wizard-service-provider.ts`
  - **Structure**: Mirror `rfiAssistantServiceProvider`

- [x] **[FRONTEND]** Create template wizard constants
  - **File**: `rohan_ui/src/app/pages/acquisition-center/components/workspace/template-wizard/template-wizard.constants.ts`
  - **Content**: Step titles, instructions, button labels
  - **Example**:
    ```typescript
    export const TemplateWizardStrings = {
      request: {
        title: "Needs Statement",
        instructions: "Start with a requirement, goal, or capability gap...",
      },
      analysis: {
        title: "Analysis",
        instructions: "Your input is now structured content...",
      },
      generateButton: "Generate Document",
      highSideGenerateButton: "Generate Document",
      confirmation: "Once you continue, you will not be able to come back...",
    };
    ```

- [x] **[FRONTEND]** Create template wizard types
  - **File**: `rohan_ui/src/app/pages/acquisition-center/components/workspace/template-wizard/template-wizard.types.ts`
  - **Types**: `TemplateWizardContextStep`, `TemplateWizardAnalysisStep` (mirror RFI types)

### Phase 3: Frontend - Wizard Steps Configuration

- [x] **[FRONTEND]** Configure Step 1: Needs Statement
  - **File**: `rohan_ui/src/app/pages/acquisition-center/components/workspace/template-wizard/template-wizard.component.ts`
  - **StepConfig**:
    - `component: SingleRteStepComponent`
    - `inputs`: `{ content: this.context, feature: Features.TEMPLATE_WIZARD, documentIds: this.documentIds }`
    - `title`: `strings.request.title`
    - `instructions`: `strings.request.instructions`
    - `extraComponent`: `DocumentLibraryComponent` if `highSideEnabled`
    - `nextAction`: `this.getAnalysis.bind(this)`
    - `nextButtonTitleOverride`: `'Run Request'`

- [x] **[FRONTEND]** Configure Step 2: Analysis
  - **File**: `rohan_ui/src/app/pages/acquisition-center/components/workspace/template-wizard/template-wizard.component.ts`
  - **StepConfig**:
    - `component: SingleRteStepComponent`
    - `inputs`: `{ content: this.analysis, feature: Features.TEMPLATE_WIZARD, stream: this.analysisStream, onStreamComplete: () => {...} }`
    - `title`: `strings.analysis.title`
    - `instructions`: `strings.analysis.instructions`
    - `nextAction`: `this.generate.bind(this)`
    - `nextButtonTitleOverride`: Based on `highSideEnabled`
    - `confirmationDialogText`: Only if `!highSideEnabled`
    - `sidePanel`: `{ component: ActivityPanelComponent, inputs: { activitySignal, sourcesSignal } }`

- [x] **[FRONTEND]** Add Features enum value for template wizard (if needed)
  - **File**: `rohan_ui/src/app/shared-types/modify-text.types.ts`
  - **Add**: `TEMPLATE_WIZARD = 'template-wizard'` (or reuse existing feature)

### Phase 4: Frontend - Template Section Conversion (for Editor)

- [x] **[FRONTEND]** Convert template sections to procurement sections
  - **File**: `rohan_ui/src/app/pages/acquisition-center/utilities/template-section-converter.utils.ts`
  - **Method**: `convertTemplateSectionsToProcurementSections(template: CustomTemplate): Section[]`
  - **Logic**:
    - Group `TemplateSubSection` by `template_section_id` or `section_title`
    - Create `Section` objects with `questions: Question[]`
    - Map `TemplateSubSection` fields to `Question` fields
  - **Note**: Conversion utility exists. Template sections are fetched from database via `GET /procurement-templates/:id` endpoint (`template-generator.controller.ts:85`) when template is loaded, then included in procurement creation request. Backend converts them to procurement sections format. Each template has unique sections stored in `procurement_template_sections` table, making each wizard unique based on `template_id`.

### Phase 5: Frontend - Navigation and Routing

- [x] **[FRONTEND]** Add template wizard route
  - **File**: `rohan_ui/src/app/pages/acquisition-center/procurement-writer-routing.module.ts`
  - **Route**: `{ path: 'procurement/:procurement_id/template-wizard', component: TemplateWizardComponent }`
  - **Guard**: Ensure procurement exists and has template_id

- [x] **[FRONTEND]** Update landing page navigation for template cards
  - **File**: `rohan_ui/src/app/pages/acquisition-center/components/procurement-writer-landing-page/procurement-writer-landing-page.component.ts`
  - **Method**: `navigateToProcurement(procurement: Procurement)`
  - **Change**: Added check for `template_id` at the end of navigation logic (after RFI/MRA title checks)
  - **Logic**: Navigation order:
    1. If `highSideEnabled` → navigate to `analysis-assistant`
    2. Else if `title === 'Market Research Analysis'` → navigate to `mra-assistant`
    3. Else if `title === 'Request for Information'` → navigate to `rfi-assistant`
    4. Else if `procurement.template_id` exists → navigate to `template-wizard`
  - **Note**: RFI and MRA templates are handled by their title checks before the `template_id` check, so they won't navigate to template-wizard. Custom templates with `template_id` will navigate to template-wizard as a fallback after title checks.
  - **Note**: When user clicks template card, `createNewProcurement()` is called which:
    1. Fetches template from database via `GET /procurement-templates/:id` endpoint (`template-generator.controller.ts:85`) which calls `templateGeneratorService.findOne(id)` - this includes unique sections from `procurement_template_sections` table
    2. Creates procurement with template sections included
    3. Each template has unique sections, making each wizard unique based on `template_id`

- [x] **[FRONTEND]** Update procurement creation to include template_id
  - **File**: `rohan_ui/src/app/pages/acquisition-center/services/procurement-writer.service.ts`
  - **Method**: `newProcurement(template: TemplatePreview)`
  - **Verify**: Ensure `template_id` is set correctly when creating from published template
  - **Check**: `createNewProcurementFromTemplate()` sets `template_id: template.id`
  - **Template sections**: When template is fetched via `getTemplate()` in `procurement-writer.service.ts` (line 336), it calls `GET /procurement-templates/:id` endpoint (`template-generator.controller.ts:85`) which returns template with sections from database (`procurement_template_sections` table). These sections are included in procurement creation request (line 166: `sections: JSON.parse(JSON.stringify(template.sections))`). Backend converts them to procurement sections format. **This is where unique template sections from database are used to create unique wizards for each template.**

### Phase 6: Frontend - Secondary Navigation for Template Sections

- [ ] **[FRONTEND]** Update procurement nav to show template sections
  - **File**: `rohan_ui/src/app/pages/acquisition-center/components/workspace/procurement-nav/procurement-nav.component.ts`
  - **Method**: `initializeProcurementNavItems()`
  - **Change**: If procurement has template sections, generate nav items from sections
  - **Logic**:
    - Load template sections from procurement or template
    - Generate nav items for each section (similar to preview step sidebar)
    - Show sections in secondary nav when in editor/draft document step

- [ ] **[FRONTEND]** Create utility to generate nav items from template sections
  - **File**: `rohan_ui/src/app/pages/acquisition-center/utilities/procurement-nav.utils.ts` (or similar)
  - **Method**: `generateTemplateNavItems(sections: TemplateSection[]): NavItems`
  - **Purpose**: Convert template sections to nav items for secondary nav
  - **Structure**: Use hierarchical structure matching template generator preview (both `TemplateSection` and `TemplateSubSection` in hierarchical format)

- [ ] **[FRONTEND]** Update nav to show template sections in editor
  - **File**: `rohan_ui/src/app/pages/acquisition-center/components/workspace/procurement-nav/procurement-nav.component.ts`
  - **Change**: When in editor for template-based procurement, show template sections in nav
  - **Note**: May need to detect current route and procurement type to determine nav content

### Phase 7: Frontend - Wizard State Management

- [x] **[FRONTEND]** Implement wizard state saving for template wizard
  - **File**: `rohan_ui/src/app/pages/acquisition-center/components/workspace/template-wizard/template-wizard.component.ts`
  - **Method**: `saveState()`
  - **Implementation**: Mirror RFI wizard state saving
  - **WizardState**:
    ```typescript
    {
      step: this.stepIndex,
      type: procurement.template_id, // Use template_id for template-specific state
      lastCompletedStepIndex: this.lastCompletedStepIndex,
      stepData: {
        context: this.context(),
        analysis: this.analysis(),
        sources: this.sourcesSignal(),
      },
    }
    ```

- [x] **[FRONTEND]** Implement wizard state restoration
  - **File**: `rohan_ui/src/app/pages/acquisition-center/components/workspace/template-wizard/template-wizard.component.ts`
  - **Constructor**: Load saved state from `ProcurementWriterService.getWizardState()`
  - **Restore**: `stepIndex`, `context`, `analysis`, `sources`, `lastCompletedStepIndex`

### Phase 8: Backend - Analysis Service Integration

- [ ] **[BACKEND_DB]** Verify analysis_assistant prompt works for templates
  - **File**: `rohan_api/src/procurement-writer/procurement-writer.service.ts`
  - **Verification**: Ensure `analysis_assistant` prompt can handle template-based procurements
  - **Note**: May need to pass template context or sections to prompt

- [ ] **[BACKEND_DB]** Add template context to analysis request (if needed)
  - **File**: `rohan_api/src/procurement-writer/procurement-writer.controller.ts` or service
  - **Change**: Include template_id or template sections in analysis request
  - **Purpose**: Allow prompt to tailor analysis based on template type

### Phase 9: Frontend - Integration and Polish

- [x] **[FRONTEND]** Add error handling for template wizard
  - **File**: `rohan_ui/src/app/pages/acquisition-center/components/workspace/template-wizard/template-wizard.component.ts`
  - **Handling**: Template not found, analysis failure, navigation errors
  - **User feedback**: Toast notifications for errors
  - **Note**: Basic error handling implemented (token limit, navigation errors). Additional error handling for template not found may be needed.

- [x] **[FRONTEND]** Add loading states
  - **File**: `rohan_ui/src/app/pages/acquisition-center/components/workspace/template-wizard/template-wizard.component.ts`
  - **Spinner**: Show spinner during analysis generation, template loading
  - **Note**: Spinner implemented for state saving. Analysis generation uses streaming (no spinner needed).

- [ ] **[FRONTEND]** Test wizard navigation flow
  - **Flow**: Landing page → Click template card → Create procurement → Navigate to wizard → Complete steps → Navigate to editor

### Phase 10: Testing

- [ ] **[TEST_REVIEW]** Add unit tests for template wizard component
  - **File**: `rohan_ui/src/app/pages/acquisition-center/components/workspace/template-wizard/template-wizard.component.spec.ts`
  - **Tests**:
    - Component initializes correctly
    - Steps configured correctly
    - Analysis service called with correct parameters
    - State saving/restoration works
    - Navigation to editor works

- [ ] **[TEST_REVIEW]** Add unit tests for template section conversion
  - **File**: `rohan_ui/src/app/pages/acquisition-center/components/workspace/template-wizard/template-wizard.component.spec.ts` or utility spec
  - **Tests**:
    - TemplateSubSection → Question mapping
    - Section grouping by template_section_id
    - Empty/null field handling

- [ ] **[TEST_REVIEW]** Add unit tests for template wizard service
  - **File**: `rohan_ui/src/app/pages/acquisition-center/components/workspace/template-wizard/template-wizard-service/template-wizard.service.spec.ts`
  - **Tests**:
    - getAnalysis() calls correct endpoint
    - Handles errors correctly
    - Returns correct response format

- [ ] **[TEST_REVIEW]** Manual E2E testing: Template wizard flow
  - **Steps**:
    1. Publish a template
    2. Navigate to Procurement Projects
    3. Click template card
    4. Verify wizard opens with 2 steps
    5. Complete Step 1 (Needs Statement)
    6. Complete Step 2 (Analysis)
    7. Verify navigation to editor after Step 2
    8. Verify secondary nav shows template sections in editor
    9. Verify draft document displays template sections correctly

- [ ] **[TEST_REVIEW]** Manual E2E testing: Wizard state saving
  - **Steps**:
    1. Start template wizard
    2. Complete Step 1, navigate to Step 2
    3. Save state (if highSideEnabled)
    4. Navigate away and return
    5. Verify state restored correctly

- [ ] **[TEST_REVIEW]** Manual E2E testing: Multiple templates
  - **Steps**:
    1. Publish multiple templates
    2. Create procurements from each
    3. Verify each wizard shows correct template sections
    4. Verify navigation works for each

## Notes

- **Reusability**: The template wizard should be reusable for all published templates, not template-specific.
- **Shared components**: Leverage existing wizard, RTE, and editor components to minimize duplication.
- **Template conversion**: Template sections need to be converted to procurement sections format for editor compatibility.
- **Secondary nav**: The secondary nav should use hierarchical structure matching the template generator preview (both `TemplateSection` and `TemplateSubSection` in hierarchical format) for consistency.
- **RBAC integration**: Step 2 Analysis should respect RBAC settings for deep research vs pgvector (already handled by prompt service).
- **State management**: Wizard state should be saved/restored similar to RFI wizard for consistency.
- **Error handling**: Handle cases where template is missing, sections are invalid, or analysis fails.

## Implementation Conflicts & Dependencies

**Dependencies on PRCR-697**:

- Template cards must exist in Procurement Projects (from PRCR-697)
- Template publishing must work (from PRCR-697)
- Procurement creation from template must work (from PRCR-697)

**Potential Conflicts**:

- **Navigation logic**: `navigateToProcurement()` may conflict with other navigation updates
  - **Resolution**: Add template_id check before existing RFI/MRA logic

- **Wizard state type**: RFI uses `type: 'rfi'`, template wizard should use `type: template_id` for template-specific state
  - **Resolution**: Use `WizardState.type = procurement.template_id` to allow template-specific state management

- **Secondary nav**: May conflict with existing procurement nav logic
  - **Resolution**: Add conditional logic to check if procurement has template sections

## Reference Files

### Backend

- Template service: `rohan_api/src/template-generator/template-generator.service.ts`
- Procurement writer service: `rohan_api/src/procurement-writer/procurement-writer.service.ts`
- Analysis prompt: `Database/rohan_api/scripts/sql/init_prompts.sql` (analysis_assistant)

### Frontend

- RFI wizard: `rohan_ui/src/app/pages/acquisition-center/components/workspace/rfi-assistant/`
- Wizard component: `rohan_ui/src/app/shared-components/wizard/wizard.component.ts`
- Single RTE step: `rohan_ui/src/app/shared-components/single-rte-step/single-rte-step.component.ts`
- Preview step: `rohan_ui/src/app/pages/acquisition-center/components/template-generator/preview-step/`
- Procurement editor: `rohan_ui/src/app/pages/acquisition-center/components/workspace/procure-editor/`
- Procurement nav: `rohan_ui/src/app/pages/acquisition-center/components/workspace/procurement-nav/`
- Landing page: `rohan_ui/src/app/pages/acquisition-center/components/procurement-writer-landing-page/`
- Types: `rohan_ui/src/app/pages/acquisition-center/types/procurement-writer.types.ts`
