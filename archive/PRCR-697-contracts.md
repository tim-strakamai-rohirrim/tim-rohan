# PRCR-697: API Contracts and Data Shapes

This document defines the contracts, DTOs, and data shapes shared between frontend and backend for the Template Publishing to Procurement Projects Tiles feature.

## API Endpoints

### Get Published Templates (Existing - Reused)

**Endpoint**: `GET /procurement-templates`

**Query Parameters**:
```typescript
{
  status?: 'published' | 'draft' | 'completed' | 'archived';  // Filter by status
  created_from?: TemplateCreationSource[];                    // Optional creation source filter
}
```

**Response**:
```typescript
ProcurementTemplateDto[]
```

**Example Request**:
```
GET /procurement-templates?status=published
```

**Example Response**:
```json
[
  {
    "procurement_template_id": 123,
    "title": "Market Research Record",
    "name": "Market Research Record",
    "description": "The MRR provides an overview of a market, including competitors, customers, and trends.",
    "owner_id": 42,
    "owner_name": "John Doe",
    "status": "published",
    "created_on": "2024-01-15T10:00:00Z",
    "updated_on": "2024-01-20T14:30:00Z",
    "published_on": "2024-01-20T14:30:00Z",
    "image_url": "https://example.com/images/mrr.png",
    "category": "Research",
    "show_relevant_clauses": false,
    "created_from": "scratch",
    "current_step": 2,
    "source_template_id": null
  }
]
```

### Publish Template (Existing - Reused)

**Endpoint**: `PATCH /procurement-templates/:id/publish`

**Path Parameters**:
```typescript
{
  id: number;  // Template ID
}
```

**Request Body**: Empty (or `{ id: number }` for consistency)

**Response**:
```typescript
ProcurementTemplateDto
```

**Status Codes**:
- `200 OK`: Template published successfully
- `400 Bad Request`: Invalid status transition (e.g., DRAFT cannot be published directly)
- `404 Not Found`: Template not found
- `500 Internal Server Error`: Failed to publish template

**Example Request**:
```
PATCH /procurement-templates/123/publish
```

**Example Response**:
```json
{
  "procurement_template_id": 123,
  "title": "Market Research Record",
  "name": "Market Research Record",
  "description": "The MRR provides an overview of a market...",
  "status": "published",
  "published_on": "2024-01-20T14:30:00Z",
  ...
}
```

**Idempotency**: If template is already published, returns existing template without error (status 200).

### Unpublish Template (Existing - Reused)

**Endpoint**: `PATCH /procurement-templates/:id/unpublish`

**Path Parameters**:
```typescript
{
  id: number;  // Template ID
}
```

**Request Body**: Empty (or `{ id: number }` for consistency)

**Response**:
```typescript
ProcurementTemplateDto
```

**Status Codes**:
- `200 OK`: Template unpublished successfully
- `400 Bad Request`: Invalid status transition (only PUBLISHED can be unpublished)
- `404 Not Found`: Template not found
- `500 Internal Server Error`: Failed to unpublish template

**Example Request**:
```
PATCH /procurement-templates/123/unpublish
```

**Example Response**:
```json
{
  "procurement_template_id": 123,
  "title": "Market Research Record",
  "name": "Market Research Record",
  "description": "The MRR provides an overview of a market...",
  "status": "completed",
  "published_on": "2024-01-20T14:30:00Z",  // Retained for history
  ...
}
```

**Note**: Unpublishing sets status to `COMPLETED` but retains `published_on` timestamp for audit purposes.

## Data Types

### ProcurementTemplateDto (Backend)

**Source**: `rohan_api/src/template-generator/dto/template.dto.ts`

```typescript
class ProcurementTemplateDto {
  procurement_template_id: number;
  title: string;
  name: string;  // Alias for title (frontend compatibility)
  description?: string;
  owner_id: number;
  owner_name?: string | null;
  status: TemplateStatus;  // 'draft' | 'completed' | 'published' | 'archived'
  created_on: Date;
  updated_on: Date;
  published_on?: Date | null;
  image_url?: string | null;
  category?: string | null;
  show_relevant_clauses: boolean;
  created_from?: TemplateCreationSource | null;
  current_step: number;
  source_template_id?: number | null;
}
```

### TemplatePreview (Frontend)

**Source**: `rohan_ui/src/app/pages/acquisition-center/types/procurement-writer.types.ts`

```typescript
interface TemplatePreview extends CardData {
  author?: string;
  is_coming_soon?: boolean;
  procurement_template_id?: string;  // Added for published templates
}
```

### CardData (Frontend)

**Source**: `rohan_ui/src/app/shared-types/card.types.ts`

```typescript
interface CardData {
  id: string;
  name: string;
  description: string;
  image: string;
  analyticsId?: string;
}
```

### Transformation Mapping

**From**: `ProcurementTemplateDto` → **To**: `TemplatePreview`

| ProcurementTemplateDto Field | TemplatePreview Field | Transformation Logic |
|------------------------------|----------------------|---------------------|
| `procurement_template_id` | `id` | `procurement_template_id.toString()` |
| `procurement_template_id` | `procurement_template_id` | `procurement_template_id.toString()` (optional, for template reference) |
| `title` | `name` | Direct mapping |
| `description` | `description` | `description || ''` (fallback to empty string) |
| `image_url` | `image` | `image_url || './assets/images/templates/custom-template.png'` (fallback to default) |
| `owner_name` | `author` | `owner_name || undefined` (optional) |
| N/A | `is_coming_soon` | Always `false` for published templates |

## Template Status Values

**Backend Enum** (`TemplateStatus`):
- `DRAFT = 'draft'`
- `COMPLETED = 'completed'`
- `PUBLISHED = 'published'`
- `ARCHIVED = 'archived'`

**Frontend Mapping** (`CustomTemplateStatus`):
- `DRAFT = 'draft'`
- `COMPLETED = 'completed'`
- `PUBLISHED = 'published'`
- `ARCHIVED = 'archived'`

**Status Transitions for Publishing**:
- `COMPLETED` → `PUBLISHED` ✅ (allowed)
- `ARCHIVED` → `PUBLISHED` ✅ (allowed)
- `PUBLISHED` → `PUBLISHED` ✅ (idempotent, no-op)
- `DRAFT` → `PUBLISHED` ❌ (not allowed, must complete first)

**Status Transitions for Unpublishing**:
- `PUBLISHED` → `COMPLETED` ✅ (allowed)
- `COMPLETED` → `COMPLETED` ✅ (idempotent, no-op)
- `DRAFT` → `COMPLETED` ❌ (not allowed)
- `ARCHIVED` → `COMPLETED` ❌ (not allowed)

## Error Formats

### Backend Errors

**400 Bad Request** (Invalid status transition):
```json
{
  "statusCode": 400,
  "message": "DRAFT templates cannot be published directly. Complete the template first.",
  "error": "Bad Request"
}
```

**400 Bad Request** (Unpublish invalid state):
```json
{
  "statusCode": 400,
  "message": "Only PUBLISHED templates can be unpublished to COMPLETED",
  "error": "Bad Request"
}
```

**404 Not Found** (Template not found):
```json
{
  "statusCode": 404,
  "message": "Template not found",
  "error": "Not Found"
}
```

**500 Internal Server Error** (Service error):
```json
{
  "statusCode": 500,
  "message": "Failed to publish template.",
  "error": "Internal Server Error"
}
```

### Frontend Error Handling

**Publish Failure**:
- Show toast notification: "Tile creation failed. Retry."
- Display retry button in toast or error banner
- Log error to console for debugging
- Do not block user workflow (allow retry)

**Unpublish Failure**:
- Show toast notification: "Template could not be unpublished. Please try again."
- Refresh template data to reflect actual state
- Log error to console

**Template Fetch Failure**:
- Show toast notification: "Failed to load published templates. Please refresh the page."
- Display empty state or fallback to cached data (if available)
- Provide retry button to re-fetch templates

## Unpublish Confirmation Modal

**Component**: `GenericModalComponent`

**Modal Configuration**:
```typescript
const modalData: GenericModalData = {
  mainText: "Unpublish template?",
  secondaryText: "This will remove the template from Procurement Projects. Existing drafts created from it are unaffected.",
  button1Text: "Cancel",
  button2Text: "Unpublish",
  isDelete: true,  // For destructive styling (red button)
};
```

**User Actions**:
- **Cancel** (BUTTON_1): Close modal, no changes made
- **Unpublish** (BUTTON_2): Proceed with unpublish API call
- **Dismiss** (X or outside click): Same as Cancel

## Tile Display Rules

### Visibility
- Only templates with `status='published'` are displayed as tiles
- Tiles are visible to all authenticated users (no additional permission checks)
- Tiles are ordered by `published_on` DESC (most recently published first)
- Fallback ordering: `updated_on` DESC if `published_on` is null

### Tile Fields
- **Title**: `template.title` (required)
- **Description**: `template.description || ''` (optional, can be empty)
- **Image**: `template.image_url || default_placeholder` (required, fallback to default)
- **Status**: Always "Published" (implicit, not displayed on tile)
- **Author**: `template.owner_name` (optional, may not be displayed)

### Tile Click Behavior
- Clicking a tile triggers `createNewProcurement(template: TemplatePreview)`
- Uses `template.procurement_template_id` to create new procurement from template
- Navigates to procurement workspace after creation

## Idempotency Rules

### Publishing
- Re-publishing the same template (already `PUBLISHED`) is idempotent
- Returns existing template without error
- Does not create duplicate tiles (filtered by status)
- Updates `published_on` timestamp if re-published (TBD - verify current behavior)

### Unpublishing
- Unpublishing an already `COMPLETED` template is idempotent
- Returns existing template without error
- Does not cause errors or side effects

## Audit Trail Integration

Publish and unpublish actions are logged to audit trail (from previous PR):

**Publish Action**:
```
"Template {templateId} ({templateName}) published"
```

**Unpublish Action**:
```
"Template {templateId} ({templateName}) unpublished"
```

**State Change Action**:
```
"Template {templateId} ({templateName}) status changed from {fromStatus} to {toStatus}"
```

See `contracts.md` (PRCR-697 audit trail contracts) for full audit trail contract details.

## Notes

- **No new database tables**: Uses existing `procurement_templates` table with `status` field
- **No new API endpoints**: Reuses existing template endpoints with status filtering
- **Backward compatibility**: Existing mock templates can be kept as fallback or removed based on product decision
- **Image requirements**: Default placeholder image should exist at `./assets/images/templates/custom-template.png` or equivalent
- **Performance**: Consider caching published templates if list is large or fetched frequently
- **Real-time updates**: Template list can be refreshed on navigation (simpler) or via observables (more complex, better UX)
