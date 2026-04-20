# API Contracts and Data Shapes

This document defines the contracts, DTOs, and data shapes shared between frontend and backend for the Template Generator Audit Trail feature.

## Audit Trail Feature Identifier

**Feature Name**: `'Template-Generator'`

**Enum Value** (Backend): `AuditTrailFeature.TEMPLATE_GENERATOR = 'Template-Generator'`

**Constant Value** (Frontend): `AUDIT_TRAIL_FEATURES.TEMPLATE_GENERATOR = 'Template-Generator'`

## API Endpoints

### Get Audit Trail (Existing - Reused)

**Endpoint**: `GET /settings/audit_trail`

**Query Parameters**:

```typescript
{
  startDate?: string;        // ISO 8601 date string
  endDate?: string;          // ISO 8601 date string
  feature?: string;          // 'Template-Generator' for filtering
  performedBy?: string;      // Email address
  page?: number;             // Page number (1-indexed)
  pageSize?: number;         // Items per page (default: 50)
  actionType?: string;       // Optional action filter
  templateId?: number;       // Template ID for filtering (extracts from action strings)
}
```

**Response**:

```typescript
{
  data: AuditTrailRecord[];
  page: number;
  count: number;
  pageSize: number;
}
```

### Post Audit Trail Entry (Existing - Reused)

**Endpoint**: `POST /settings/audit_trail`

**Request Body**:

```typescript
{
  feature: "Template-Generator";
  action: string; // Descriptive action string
}
```

**Response**:

```typescript
{
  message: "Audit trail action registered successfully";
}
```

**Note**: `performed_by` is automatically set from authenticated user's email.

### Download Audit Trail CSV (Existing - Reused)

**Endpoint**: `GET /settings/audit_trail_csv`

**Query Parameters**:

```typescript
{
  startDate?: string;        // ISO 8601 date string
  endDate?: string;          // ISO 8601 date string
  feature?: string;          // 'Template-Generator' for filtering
  performedBy?: string;      // Email address
  isMetrics?: boolean;       // false for audit trail
  templateId?: number;       // Template ID for filtering (extracts from action strings)
}
```

**Note**: CSV endpoint should also support `templateId` parameter for consistency with the main audit trail endpoint.

**Response**: CSV file (ArrayBuffer)

## Data Types

### AuditTrailRecord

**Backend Entity**: `AuditTrail` (from `rohan_api/src/settings/entities/audit_trail.entity.ts`)

**Frontend Interface**:

```typescript
interface AuditTrailRecord {
  id: number;
  timestamp: string; // ISO 8601 date string
  feature: string; // 'Template-Generator'
  action: string; // Descriptive action text
  performed_by: string; // User email address
  archive_at: string; // ISO 8601 date string
}
```

### AuditTrailEntry (Request)

**Frontend Interface**:

```typescript
interface AuditTrailEntry {
  feature: "Template-Generator";
  action: string;
}
```

**Backend DTO**: `AuditTrailInput` (from `rohan_api/src/settings/dto/audit_trail.dto.ts`)

### AuditTrailFilters

**Frontend Type**:

```typescript
type AuditTrailFilters = {
  startDate: string;
  endDate?: string;
  feature?: string; // 'Template-Generator'
  performedBy?: string; // Email address
  page?: number;
  pageSize?: number;
  templateId?: number; // Template ID for template-specific audit log filtering
};
```

## Action String Formats

All action strings for Template Generator should follow these patterns:

### Template Lifecycle Actions

**Template Creation**:

```
"Template {templateId} ({templateName}) generated"
```

**Template Update**:

```
"Template {templateId} ({templateName}) edited"
```

**Template Deletion**:

```
"Template {templateId} ({templateName}) deleted"
```

### State Change Actions

**Publish**:

```
"Template {templateId} ({templateName}) published"
```

**Unpublish**:

```
"Template {templateId} ({templateName}) unpublished"
```

**Archive**:

```
"Template {templateId} ({templateName}) archived"
```

**Restore**:

```
"Template {templateId} ({templateName}) restored"
```

**State Transition** (Generic):

```
"Template {templateId} ({templateName}) status changed from \"{fromStatus}\" to \"{toStatus}\""
```

(The backend quotes status values; see `AuditTrailAction.getStateChangeAction`.)

### Wizard Step Actions

**Step Transition**:

```
"Template {templateId} ({templateName}) moved from step "{fromStepName}" to step "{toStepName}""
```

**Step Names**:

- For "template" flow: `"Select Template"` (step 0), `"Create"` (step 1), `"Preview"` (step 2)
- For "scratch" flow: `"Create"` (step 0), `"Preview"` (step 1)
- For "ai" flow: (TBD based on implementation)

### Content Change Actions

**Section Added/Modified/Deleted**:

```
"Template {templateId} ({templateName}) - section \"{sectionName}\" {action}"
```

Where `{action}` is one of: `added`, `modified`, or `deleted`. The backend uses double quotes around the section name (see `AuditTrailAction.getContentChangeAction` in `rohan_api/src/utils/constants.ts`).

**Examples**:

- `"Template 123 (My Template) - section \"Introduction\" added"`
- `"Template 123 (My Template) - section \"Introduction\" modified"`
- `"Template 123 (My Template) - section \"Introduction\" deleted"`

**Note**: The action verb is lowercase and follows the pattern: `Template {id} ({name}) - section \"{section}\" {action}`.

## Validation Rules

### Backend Validation

1. **Feature Enum**: Must be valid `AuditTrailFeature` enum value

   - Validated via `@IsEnum(AuditTrailFeature)` decorator

2. **Action String**:

   - Must be non-empty (`@IsNotEmpty()`)
   - Should be descriptive and include template ID for traceability
   - Recommended length: 50-500 characters

3. **Performed By**:
   - Automatically set from authenticated user's email
   - Must be valid email format (enforced by user authentication)

### Frontend Validation

1. **Feature Filter**: Must match one of the allowed features in `AUDIT_TRAIL_FEATURES`

2. **Date Filters**:

   - `startDate` must be valid ISO 8601 date string
   - `endDate` must be after `startDate` (if both provided)
   - Maximum date range: 6 months (enforced by UI)

3. **Email Filter**:
   - Must be valid email format (if provided)
   - Case-insensitive matching

## Error Formats

### Backend Errors

**400 Bad Request** (Invalid input):

```json
{
  "statusCode": 400,
  "message": "Validation failed",
  "error": "Bad Request"
}
```

**401 Unauthorized** (Missing/invalid auth):

```json
{
  "statusCode": 401,
  "message": "Unauthorized"
}
```

**500 Internal Server Error** (Service error):

```json
{
  "statusCode": 500,
  "message": "Failed to append audit log"
}
```

### Frontend Error Handling

Frontend should handle errors gracefully:

- Log errors to console for debugging
- Show user-friendly toast notifications for critical failures
- Do not block user workflow for audit logging failures (fail silently if non-critical)

## Navigation Contract

### View Audit Log from Template Landing Page

**Route**: `/acquisition-center/template-generator/:templateId/audit-log`

**Route Parameters**:

```typescript
{
  templateId: number; // Template ID from route parameter
}
```

**Component**: `TemplateAuditLogComponent`

**Behavior**:

- Page displays audit logs filtered by feature='Template-Generator' and template ID
- Template ID is extracted from the action string (e.g., "Template 123 (Name) generated" contains ID 123)
- Users can apply additional filters (Date, Email, Action) on top of the template-specific filter
- Includes back navigation to template generator landing page

**Implementation Note**: The component will:

1. Fetch audit logs with feature='Template-Generator' and templateId query parameter
2. Backend filters by parsing template ID from action strings (e.g., "Template 123 (Name) generated" contains ID 123)
3. Display only entries matching the template ID from the route parameter
4. Additional client-side filtering can be applied for Date, Email, and Action filters

## CSV Export Format

**Filename Pattern**: `audit-trail_YYYY-MM-DD_HH-MM-SS.csv`

**Columns**:

1. Timestamp (ISO 8601 format)
2. Feature
3. Action
4. Performed By (Email)

**Encoding**: UTF-8

**Line Endings**: `\n` (Unix-style)

## Template Status Values

For reference in state change actions:

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

## Helper Methods (Backend)

The following helper methods are implemented in `AuditTrailAction` class in `rohan_api/src/utils/constants.ts`:

```typescript
static getGenerateTemplateAction(templateId: number, templateName: string): string {
  return `Template ${templateId} (${templateName}) generated`;
}

static getEditTemplateAction(templateId: number, templateName: string): string {
  return `Template ${templateId} (${templateName}) edited`;
}

static getDeleteTemplateAction(templateId: number, templateName: string): string {
  return `Template ${templateId} (${templateName}) deleted`;
}

static getPublishTemplateAction(templateId: number, templateName: string): string {
  return `Template ${templateId} (${templateName}) published`;
}

static getUnpublishTemplateAction(templateId: number, templateName: string): string {
  return `Template ${templateId} (${templateName}) unpublished`;
}

static getArchiveTemplateAction(templateId: number, templateName: string): string {
  return `Template ${templateId} (${templateName}) archived`;
}

static getRestoreTemplateAction(templateId: number, templateName: string): string {
  return `Template ${templateId} (${templateName}) restored`;
}

static getWizardStepChangeAction(
  templateId: number,
  templateName: string,
  fromStep: number,
  toStep: number,
  stepNames: string[]
): string {
  const fromStepName = stepNames[fromStep] || `Step ${fromStep}`;
  const toStepName = stepNames[toStep] || `Step ${toStep}`;
  return `Template ${templateId} (${templateName}) moved from step "${fromStepName}" to step "${toStepName}"`;
}

static getContentChangeAction(
  templateId: number,
  templateName: string,
  sectionName: string,
  changeType: 'added' | 'modified' | 'deleted'
): string {
  const action = changeType === 'added' ? 'added' : changeType === 'modified' ? 'modified' : 'deleted';
  return `Template ${templateId} (${templateName}) - section '${sectionName}' ${action}`;
}

static getStateChangeAction(
  templateId: number,
  templateName: string,
  fromStatus: string,
  toStatus: string
): string {
  return `Template ${templateId} (${templateName}) status changed from ${fromStatus} to ${toStatus}`;
}
```

## Notes

- All timestamps are in UTC and formatted as ISO 8601 strings
- Template IDs are numeric (number type)
- Template names should be escaped/sanitized if they contain special characters that might break action string formatting
- Action strings are free-form text but should follow the patterns above for consistency
- The `performed_by` field is always the authenticated user's email address
- Audit entries are automatically archived after 6 months (database trigger)

## Changelog

### Verification and contract alignment (2026-02-02)

- **Action string formats**: Aligned contracts with backend implementation:
  - Content change actions use double quotes around section name (backend: `getContentChangeAction` uses `"${sectionName}"`).
  - State transition actions use double quotes around fromStatus/toStatus (backend: `getStateChangeAction` uses `"${fromStatus}"` / `"${toStatus}"`).
- No API or DTO changes; documentation-only.

### Phase 3.5 - Backend API Enhancement for Template ID Filtering (2026-01-23)

**Implemented:**

- Added `templateId` query parameter to `GET /settings/audit_trail` endpoint
- Added `templateId` query parameter to `GET /settings/audit_trail_csv` endpoint
- Updated `getAuditLogs` service method to filter audit logs by template ID using pattern matching on action strings
- Updated `generateAuditTrailCSV` service method to support template ID filtering
- Added comprehensive unit tests for template ID filtering in both service and controller

**Technical Details:**

- Template ID filtering uses SQL `LIKE` pattern matching: `LOWER(audit.action) LIKE LOWER('Template {templateId}')`
- This pattern matches action strings like "Template 123 (Name) generated", "Template 123 (Name) edited", etc.
- Filtering works in combination with all other existing filters (feature, date, performedBy, actionType)
- Both endpoints now support the optional `templateId` parameter for consistent filtering behavior
