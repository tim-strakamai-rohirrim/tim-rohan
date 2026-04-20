# PRCR-734: API Contracts and Data Shapes

This document defines the contracts, DTOs, and data shapes shared between frontend and backend for the Published Template Wizard feature.

## API Endpoints

### Get Analysis for Template Wizard (Existing - Reused)

**Endpoint**: `POST /procurement-writer/analysis` (or similar)

**Request Body**:

```typescript
{
  context: string;           // Needs statement from Step 1
  document_ids?: number[];   // Optional uploaded document IDs
  template_id?: string;      // Optional template ID for context
  procurement_id?: number;   // Optional procurement ID
}
```

**Response**:

```typescript
ThinkingStreamResponse; // Streaming response with content, activity, sources
```

**Example Request**:

```json
{
  "context": "We need to procure cloud infrastructure services...",
  "document_ids": [123, 456],
  "template_id": "custom-template-1",
  "procurement_id": 789
}
```

**Example Response** (streaming):

```json
{
  "content": "Based on your requirements...",
  "activity": [...],
  "sources": [...]
}
```

**Note**: Uses existing `analysis_assistant` prompt with RBAC-based model switching (deep research vs pgvector).

### Get Template Sections (Existing - Reused)

**Endpoint**: `GET /procurement-templates/:id`

**Controller**: `rohan_api/src/template-generator/template-generator.controller.ts` (lines 82-90)

**Service Method**: `templateGeneratorService.findOne(id: number)` in `rohan_api/src/template-generator/template-generator.service.ts` (line 101)

**Path Parameters**:

```typescript
{
  id: number; // Template ID (procurement_template_id)
}
```

**Response**:

```typescript
ProcurementTemplateWithSectionsDto; // Includes sections: TemplateSection[] with relations ['sections', 'owner']
```

**Implementation Details**:

- Fetches template from `procurement_templates` table with relations `['sections', 'owner']`
- Orders sections by `sort_order` ASC
- Returns template with all sections from `procurement_template_sections` table
- Each template has unique sections stored in the database, making each wizard unique

**Example Request**:

```
GET /procurement-templates/123
```

**Example Response**:

```json
{
  "procurement_template_id": 123,
  "title": "Custom Template",
  "sections": [
    {
      "template_section_id": 1,
      "section_title": "Introduction",
      "section_indicator": "1.0",
      "parent_section_id": null,
      "sort_order": 0
    },
    {
      "template_section_id": 2,
      "section_title": "Introduction",
      "section_indicator": "1.1",
      "parent_section_id": 1,
      "instructions_text": "Provide an overview...",
      "field_prompt": "Generate an introduction...",
      "helper_text": "This section should...",
      "relevant_clauses": "FAR 12.1...",
      "sort_order": 1
    }
  ],
  ...
}
```

**Note**: This endpoint is used when creating a procurement from a template. The frontend calls this endpoint via `getTemplate(templateId)` in `procurement-writer.service.ts` (line 336), which fetches the template including all unique sections from the database.

### Create Procurement from Template (Existing - Reused)

**Endpoint**: `POST /procurement-writer`

**Request Body**:

```typescript
{
  template_id: string;        // Template ID from published template
  template_title: string;    // Template title
  title: string;             // Procurement title (usually same as template)
  sections: Section[];       // Template sections from GET /procurement-templates/:id (converted to procurement sections format by backend)
  // ... other procurement fields
}
```

**Response**:

```typescript
Procurement; // Created procurement with template_id set
```

**Note**:

- This endpoint already exists and handles template-based procurement creation.
- Template sections are fetched via `GET /procurement-templates/:id` (`template-generator.controller.ts:85`) before creating the procurement.
- Sections are included in the request payload and backend converts them to procurement sections format.
- Each template has unique sections from the database, making each wizard unique based on `template_id`.

### Save Wizard State (Existing - Reused)

**Endpoint**: `POST /procurement-writer/:id/wizard-state` (or similar)

**Request Body**:

```typescript
{
  step: number;
  type: string;              // 'template' or template_id
  lastCompletedStepIndex: number;
  stepData: {
    context?: string;
    analysis?: string;
    sources?: Source[];
  };
}
```

**Response**:

```typescript
{
  success: boolean;
}
```

**Note**: Uses existing wizard state saving mechanism (same as RFI wizard).

## Data Types

### Template Wizard State (Frontend)

**Source**: `rohan_ui/src/app/pages/acquisition-center/types/procurement-writer.types.ts`

```typescript
interface WizardState {
  step: number;
  lastCompletedStepIndex: number;
  type: string; // procurement.template_id (e.g., "custom-template-1") for template-specific state
  stepData: {
    context?: string;
    analysis?: string;
    sources?: Source[] | null;
    templateSections?: Section[]; // Optional: store converted sections
  };
}
```

### Template Section Conversion

**From**: `TemplateSubSection` → **To**: `Question`

| TemplateSubSection Field | Question Field      | Transformation Logic                         |
| ------------------------ | ------------------- | -------------------------------------------- | --- | ----------------------- |
| `section_indicator`      | `field`             | Direct mapping (e.g., "1.1")                 |
| `instructions_text`      | `instructions_text` | Direct mapping                               |
| `field_prompt`           | `field_prompt`      | Direct mapping                               |
| `helper_text`            | `helper_text`       | `helper_text                                 |     | ''` (fallback to empty) |
| `relevant_clauses`       | N/A                 | Stored in section metadata (not in Question) |
| N/A                      | `question_id`       | Generate UUID or sequential ID               |
| N/A                      | `answer_text`       | `null` (empty initially)                     |

**From**: `TemplateSection` / `TemplateSubSection[]` → **To**: `Section`

| Template Field         | Section Field           | Transformation Logic                            |
| ---------------------- | ----------------------- | ----------------------------------------------- |
| `section_title`        | `section_title`         | Direct mapping                                  |
| `TemplateSubSection[]` | `questions: Question[]` | Convert each `TemplateSubSection` to `Question` |

### Template Wizard Step Configuration

**Source**: `rohan_ui/src/app/pages/acquisition-center/components/workspace/template-wizard/template-wizard.component.ts`

```typescript
type StepConfig = {
  component: Type<StepComponent>;
  inputs: any;
  title: string;
  instructions?: string;
  nextAction: () => Observable<void | ActivityItem>;
  nextButtonTitleOverride?: string;
  confirmationDialogText?: string;
  extraComponent?: Type<any>;
  sidePanel?: {
    component: Type<any>;
    inputs: any;
  };
};

// Step 1: Needs Statement
const step1: StepConfig = {
  component: SingleRteStepComponent,
  inputs: {
    content: contextSignal,
    feature: Features.TEMPLATE_WIZARD,
    documentIds: documentIdsSignal,
  },
  title: "Needs Statement",
  instructions: "Start with a requirement, goal, or capability gap...",
  extraComponent: highSideEnabled ? DocumentLibraryComponent : undefined,
  nextAction: getAnalysis,
  nextButtonTitleOverride: "Run Request",
};

// Step 2: Analysis
const step2: StepConfig = {
  component: SingleRteStepComponent,
  inputs: {
    content: analysisSignal,
    feature: Features.TEMPLATE_WIZARD,
    stream: analysisStreamSignal,
    onStreamComplete: () => {
      /* audit trail */
    },
  },
  title: "Analysis",
  instructions: "Your input is now structured content...",
  nextAction: generate,
  nextButtonTitleOverride: highSideEnabled
    ? "Generate Document"
    : "Generate Document",
  confirmationDialogText: highSideEnabled ? undefined : "Once you continue...",
  sidePanel: {
    component: ActivityPanelComponent,
    inputs: {
      activitySignal: activitySignal,
      sourcesSignal: sourcesSignal,
    },
  },
};
```

## Navigation Routes

### Template Wizard Route

**Route**: `/acquisition-center/procurement/:procurement_id/template-wizard`

**Parameters**:

- `procurement_id`: Number - The procurement ID created from template

**Guard**: Ensure procurement exists and has `template_id` set (and is not 'rfi' or 'mra').

**Component**: `TemplateWizardComponent`

### Navigation Flow

1. **Landing Page** → Click template card
2. **Fetch Template** → `GET /procurement-templates/:id` (`template-generator.controller.ts:85`) to get template with unique sections from database
3. **Create Procurement** → `POST /procurement-writer` with template data (including sections)
4. **Navigate to Wizard** → `/acquisition-center/procurement/{procurement_id}/template-wizard`
5. **Complete Steps** → Step 1 (Needs Statement) → Step 2 (Analysis)
6. **Navigate to Editor** → `/acquisition-center/procurement/{procurement_id}/editor` (after Step 2 completion)

## Secondary Navigation Structure

### Template Sections in Nav

When in the editor for template-based procurement, secondary nav should show:

```typescript
type NavItem = {
  id: string; // Section ID or index
  link: string; // Anchor link or route
  title: string; // Section title
  type: "standard" | "editor";
  children?: NavItem[]; // Optional: for hierarchical structure
};

// Generated from template sections (hierarchical structure matching preview)
const templateNavItems: NavItems = [
  {
    id: "section-0",
    link: "#section-0",
    title: "Introduction",
    type: "standard",
    children: [
      {
        id: "section-0-0",
        link: "#section-0-0",
        title: "1.1 Overview",
        type: "standard",
      },
      {
        id: "section-0-1",
        link: "#section-0-1",
        title: "1.2 Background",
        type: "standard",
      },
    ],
  },
  {
    id: "section-1",
    link: "#section-1",
    title: "Requirements",
    type: "standard",
    children: [
      // ... subsections
    ],
  },
  // ... more sections
];
```

**Note**: Should match the hierarchical structure shown in template generator preview step sidebar (both `TemplateSection` and `TemplateSubSection` in hierarchical format).

## Error Formats

### Analysis Generation Failure

**Backend Error** (500):

```json
{
  "statusCode": 500,
  "message": "Failed to generate analysis",
  "error": "Internal Server Error"
}
```

**Frontend Handling**:

- Show toast notification: "Analysis generation failed. Please try again."
- Allow user to retry Step 2
- Log error to console

### Template Not Found

**Backend Error** (404):

```json
{
  "statusCode": 404,
  "message": "Template not found",
  "error": "Not Found"
}
```

**Frontend Handling**:

- Show error dialog: "Template not found. Please select a different template."
- Navigate back to landing page
- Log error to console

### Section Conversion Failure

**Frontend Error**:

- Show error dialog: "Failed to load template sections. Please try again."
- Navigate back to landing page or previous step
- Log error to console

### Wizard State Save Failure

**Backend Error** (500):

```json
{
  "statusCode": 500,
  "message": "Failed to save wizard state",
  "error": "Internal Server Error"
}
```

**Frontend Handling**:

- Show toast notification: "Failed to save progress. Please try again."
- Allow user to continue (state may be lost)
- Log error to console

## Prompt Configuration

### Analysis Assistant Prompt

**Prompt Name**: `analysis_assistant`

**Usage**: Step 2 Analysis generation

**RBAC-Based Model Switching**:

- If user has `AC_DEEP_RESEARCH` permission: Use deep research model
- Otherwise: Use default model (e.g., `o3`)

**Prompt Variables**:

- `<<INPUT>>`: Context from Step 1 (Needs Statement)
- `<<UPLOADED_DOCUMENT_CONTENT>>`: Content from uploaded documents (if any)
- `<<VECTOR_DB_RESULTS>>`: pgvector search results (if enabled)

**Note**: Same prompt as RFI wizard for consistency.

## Wizard State Persistence

### State Storage

**Location**: Backend (procurement `wizard_state` field) or localStorage (frontend)

**Format**: JSON string of `WizardState` object

**Restoration**:

- Load on component initialization
- Restore `stepIndex`, `context`, `analysis`, `sources`, `lastCompletedStepIndex`
- Navigate to saved step if applicable

### State Clearing

**When to Clear**:

- After successful navigation to editor
- When user explicitly starts new wizard
- When procurement is deleted/archived

## Notes

- **Template identification**: Wizard identifies template via `procurement.template_id` or `procurement.template_title`.
- **Template fetching**: Templates are fetched via `GET /procurement-templates/:id` endpoint (`template-generator.controller.ts:85`) which calls `templateGeneratorService.findOne(id)`. This includes unique sections from `procurement_template_sections` table, making each wizard unique.
- **Section conversion**: Template sections are converted to procurement sections format for editor compatibility. Conversion happens on backend when creating procurement.
- **Prompt reuse**: Uses existing `analysis_assistant` prompt (same as RFI) for consistency.
- **RBAC integration**: Analysis respects user permissions for deep research vs pgvector.
- **State management**: Wizard state uses `type = procurement.template_id` for template-specific state identification.
- **Secondary nav**: Uses hierarchical structure matching template generator preview (both `TemplateSection` and `TemplateSubSection`).
- **Navigation**: Wizard route is generic (`/template-wizard`) but template is identified from procurement context.

## Changelog

### Phase 1 (Backend/DB) - Template Section Conversion

**Added**:

- `TemplateGeneratorService.convertTemplateSectionsToProcurementSections()` method
  - Converts `CompleteTemplateSectionDto[]` to procurement sections with questions format
  - Handles hierarchical structure (headers with `parent_section_id === null` and children with `parent_section_id !== null`)
  - Groups child sections by their `parent_section_id` to create `Section` objects
  - Maps template section fields to procurement question fields:
    - `section_indicator` → `field`
    - `instructions_text` → `instructions_text`
    - `field_prompt` → `field_prompt`
    - `helper_text` → `helper_text`
    - `answer_text` → `null` (empty initially)
  - Generates UUIDs for `question_id` values using `crypto.randomUUID()`
  - Handles edge cases: empty input, headers without children, orphaned children
  - Available in `rohan_api/src/template-generator/template-generator.service.ts`
  - Unit tests added in `template-generator.service.spec.ts`

**Updated**:

- `ProcurementWriterService.create()` method now automatically converts template sections to procurement sections
  - Detects template sections by checking for `template_section_id` or `parent_section_id` fields via `isTemplateSectionFormat()` helper
  - If `template_id` is provided and sections are in template format, automatically converts them using `TemplateGeneratorService`
  - Conversion happens before saving to database, ensuring sections are in correct procurement format
  - Falls back gracefully if conversion fails (uses provided sections as-is) with warning log
  - Logs conversion activity for debugging
  - Available in `rohan_api/src/procurement-writer/procurement-writer.service.ts`

**Module Updates**:

- `ProcurementWriterModule` now imports `TemplateGeneratorModule` to access template conversion service
  - Enables `ProcurementWriterService` to inject and use `TemplateGeneratorService`
  - Available in `rohan_api/src/procurement-writer/procurement-writer.module.ts`

**API Contract Details**:

- `GET /procurement-templates/:id` endpoint (`template-generator.controller.ts:85`) returns template with sections
- Endpoint calls `templateGeneratorService.findOne(id)` which fetches template with relations `['sections', 'owner']` and orders sections by `sort_order`
- Template sections are stored in `procurement_template_sections` table and fetched when template is loaded
- Frontend fetches template via `GET /procurement-templates/:id` and includes sections in procurement creation request
- Conversion is performed automatically on backend when creating procurement from template via `POST /procurement-writer` if sections are detected as template format
- No new endpoints required for Phase 1
- No database migrations required for Phase 1 (uses existing schema)
