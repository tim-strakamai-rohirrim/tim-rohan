# Audit Components Inventory Report

> Purpose: Survey every audit trail / activity log / history component in the Angular frontend to inform a future reusable audit page component.
> Scope: `rohan_ui-parent/rohan_ui/` (frontend) with supporting backend DTO references from `rohan_api-parent/rohan_api/`.

## Executive Summary

Found **8 audit/activity/history components** across the Angular frontend:
- **2 Full-featured audit pages** with filtering, pagination, CSV export
- **4 Activity/preview components** for displaying activity streams
- **2 Placeholders** (one-ring run history, compliance project audit — post-MVP)

Full audit pages share a consistent backend DTO (`AuditTrailRecord`) and follow the pattern: timestamp + action + performed_by, with optional feature and template filtering.

---

## Component Summary Table

| Component | Path | Module | Data Shape | UI Pattern | Notable Features |
|-----------|------|--------|------------|-----------|------------------|
| **AuditTrailComponent** | `/settings/components/audit-trail/` | settings | `AuditTrailRecord[]` + filters | Table + Filters | Multi-feature, infinite scroll, CSV export, date range + email + feature filters |
| **TemplateAuditLogComponent** | `/acquisition-center/template-generator/` | acquisition-center | `AuditTrailRecord[]` | Table + Filters | Template-scoped, action text filter, 6-month default, CSV export |
| **RunHistoryTabComponent** | `/one-ring/components/` | one-ring | Placeholder | Placeholder | Not implemented yet |
| **ComplianceProjectAuditPageComponent** | `/compliance/components/` | compliance | Placeholder | Placeholder | Post-MVP, shows placeholder tab |
| **ActivityPanelComponent** | `/shared-components/activity-panel/` | shared | `ActivityItem[]` + sources | Tab group | Tabbed layout (Activity/Sources), signal-based reactivity |
| **ActivityPanelLiteComponent** | `/answer-engine-v2/components/` | answer-engine-v2 | `ActivityItem[]` | List + panel | Lightweight, filters reasoning messages, close button |
| **ActivityListComponent** | `/shared-components/activity-list/` | shared | `ActivityItem[]` | Vertical list | Simple list with type-based icons (search, reasoning, completion, error) |
| **ActivityItemComponent** | `/shared-components/activity-item/` | shared | `ActivityItem` | Single item | Base component, supports markdown, compact modes, timestamps |

---

## Detailed Component Specifications

### 1. AuditTrailComponent (Settings)
**Full Path:** `rohan_ui-parent/rohan_ui/src/app/pages/settings/components/audit-trail/`

**Selector:** `app-audit-trail`

**Module:** `SettingsModule`

**Route:** Not routed directly (used within Settings tab)

**Data Source:**
- Service: `AuditTrailService`
- Methods: `getAuditTrail()`, `getAuditTrailFiltersData()`, `getAuditTrailCSV()`
- DTO: `AuditTrailRecord[]` with `GetAuditTrailResponse`

**Inputs:**
```typescript
@Input() auditTrail: AuditTrailRecord[] = [];
@Input() resultsCount: number = 0;
@Input() auditTrailFiltersData: AuditTrailFiltersData | null = null;
```

**Outputs:**
```typescript
@Output() filters = new EventEmitter<AuditTrailFilters>();
@Output() downloadCSVEvent = new EventEmitter<AuditTrailFilters>();
@Output() infiniteScrollEvent = new EventEmitter<AuditTrailFilters>();
```

**Template Structure:**
- Toolbar with filters (date range, email multi-select with search, feature multi-select with search)
- Date range options: Today, Yesterday, Last 7 Days, Last 30 Days, Custom Range (via modal)
- Download CSV button
- Mat-table with sticky header
- Columns: timestamp, feature, action (expandable), performed_by
- Infinite scroll on container
- Results count display

**Special Features:**
- Multi-select with `ngx-mat-select-search` for filtering by email and feature
- Action column has inline expand/collapse for truncated text
- Feature name formatting (removes 'v2')
- Date range persistence via custom `DatePickerModalComponent`
- Debounced feature selection (300ms)
- Clear All button
- CSV download with timezone alignment

**Used Primitives:**
- Material (Table, Select, DatePicker, Form, Icon, Button, Chips)
- ngx-infinite-scroll
- ngx-mat-select-search
- `ReplaySubject` for filter management

---

### 2. TemplateAuditLogComponent (Acquisition Center)
**Full Path:** `rohan_ui-parent/rohan_ui/src/app/pages/acquisition-center/components/template-generator/template-audit-log/`

**Selector:** `app-template-audit-log`

**Module:** Standalone

**Route:** `/template-generator/:templateId/audit-log`

**Data Source:**
- Service: `AuditTrailService`, `RequestService` (for template fetch)
- Methods: `getAuditTrail()`, `getAuditTrailFiltersData()`, `getAuditTrailCSV()`
- DTO: `AuditTrailRecord[]`
- Context: Template ID from route params, filters scoped to `TEMPLATE_GENERATOR` feature + templateId

**Key Properties:**
```typescript
templateId: number | null;
auditTrail: AuditTrailRecord[] = [];
auditTrailFiltersData: AuditTrailFiltersData | null = null;
columnsToDisplay = ['timestamp', 'action', 'performed_by'];
actionFilter: string = ''; // Client-side only
startDate, endDate, performedBy: string;
```

**Template Structure:**
- Header: Back link + "Template Name - Audit Logs"
- Toolbar: Date range, Email multi-select, Action text filter (ngx-mat-select-search), Clear All
- Mat-table (no sticky header, no infinite scroll)
- Columns: timestamp, action (expandable), performed_by
- No-results message
- All results loaded at once (pageSize: 10000)

**Special Features:**
- 6-month default date range (via `subMonths` from date-fns)
- Action text filter applied client-side only
- CSV download also filters by action client-side
- Back navigation to template-generator
- Spinner (ngx-spinner) during fetch

**Differences from AuditTrailComponent:**
- No feature filter (scoped to `TEMPLATE_GENERATOR` by default)
- Template ID scope parameter
- Action text search instead of feature multi-select
- Client-side action filtering on CSV download
- No infinite scroll (all results at once)
- Simpler table (3 columns vs 4)

---

### 3. RunHistoryTabComponent (OneRing)
**Full Path:** `rohan_ui-parent/rohan_ui/src/app/pages/one-ring/components/run-history-tab/`

**Selector:** `app-run-history-tab`

**Module:** `OneRingModule`

**Status:** **PLACEHOLDER ONLY**

**Template:** Just displays "Run History tab placeholder"

**Implementation:** Empty component, injected `OneRingStateService` but no implementation.

---

### 4. ComplianceProjectAuditPageComponent (Compliance)
**Full Path:** `rohan_ui-parent/rohan_ui/src/app/pages/compliance/components/compliance-project-audit-page/`

**Selector:** `app-compliance-project-audit-page`

**Module:** `ComplianceModule`

**Route:** `/compliance/:projectId/project-audit`

**Status:** **PLACEHOLDER (Post-MVP)**

**Template:** Shows `<app-compliance-tab-placeholder>` with message "Project audit timeline is planned for post-MVP."

**Implementation:** Empty component with OnPush change detection.

---

### 5. ActivityPanelComponent (Shared)
**Full Path:** `rohan_ui-parent/rohan_ui/src/app/shared-components/activity-panel/`

**Selector:** `app-activity-panel`

**Module:** `SharedComponentsModule`

**Purpose:** Display activity stream with Sources tab

**Data Source:**
- Signal-based: `activitySignal: Signal<ActivityItem[]>`, `sourcesSignal: Signal<Source[]>`, `titleSignal: Signal<string>`
- Fallback inputs: `activity`, `sources`, `title`

**Inputs:**
```typescript
@Input() activitySignal: Signal<ActivityItem[]>;
@Input() sourcesSignal: Signal<Source[]>;
@Input() titleSignal: Signal<string>;
@Input() activity: ActivityItem[] = [];
@Input() sources: Source[] = [];
@Input() title: string = '';
```

**Template Structure:**
- Optional title header
- Mat-tab-group with 2 tabs:
  - Activity tab (disabled if empty): contains `<app-activity-list>`
  - Sources tab (disabled if empty): contains `<app-sources-list>`
- Initial tab selection logic: defaults to Activity unless empty and Sources present

**Special Features:**
- Reactive signals for real-time updates
- Fallback to traditional `@Input` if signals not provided
- Dynamic tab selection (prioritizes Activity if available)
- Uses `ChangeDetectorRef.markForCheck()` in effects

---

### 6. ActivityPanelLiteComponent (Answer Engine v2)
**Full Path:** `rohan_ui-parent/rohan_ui/src/app/pages/answer-engine-v2/components/activity-panel-lite/`

**Selector:** `app-activity-panel-lite`

**Module:** `AnswerEngineModule`

**Purpose:** Lightweight activity preview panel for AEv2

**Inputs:**
```typescript
@Input() activities: ActivityItem[] = [];
@Input() isVisible: boolean = false;
@Input() title: string = 'Activity';
```

**Outputs:**
```typescript
@Output() closePreview = new EventEmitter<void>();
```

**Template Structure:**
- Conditional wrapper (only if `isVisible`)
- Header: title + close button
- Content: `<app-activity-list>` with filtered activities
- Filters out "Reasoning completed" messages

**Special Features:**
- Filtered activities (removes reasoning completion messages)
- Close button with emit
- Track by function for performance

---

### 7. ActivityListComponent (Shared)
**Full Path:** `rohan_ui-parent/rohan_ui/src/app/shared-components/activity-list/`

**Selector:** `app-activity-list`

**Module:** `SharedComponentsModule`

**Purpose:** Display a vertical list of activities with type-based icons

**Inputs:**
```typescript
@Input() activities: ActivityItem[] = [];
```

**Template Structure:**
- Container div (activity-list)
- `@for` loop with `trackByActivityId`
- Each activity item shows:
  - Icon based on type (completion → check_circle, error → error, other → language)
  - `<app-activity-item>` component
- Empty state: "No activity available for this question"

**Change Detection:** OnPush

---

### 8. ActivityItemComponent (Shared)
**Full Path:** `rohan_ui-parent/rohan_ui/src/app/shared-components/activity-item/`

**Selector:** `app-activity-item`

**Module:** `SharedComponentsModule`

**Purpose:** Base unit component for displaying a single activity entry

**Type Definition:**
```typescript
export type ActivityType = 'search' | 'reasoning' | 'completion' | 'open_page' | 'error' | 'markdown';

export interface ActivityItem {
    message: string;
    id: string;
    type?: ActivityType;
    timestamp?: Date;
    url?: string;
}
```

**Inputs:**
```typescript
@Input({ required: true }) activity!: ActivityItem;
@Input() compact: boolean = false;
@Input() superCompact: boolean = false;
```

**Template Structure:**
- If `type === 'markdown'`: render with markdown pipe and innerHTML
- Else:
  - If `superCompact`: message + url on single line
  - Else: message on first line, url on second line
- URL renders as external link (`target=_blank`, `rel=noopener noreferrer`)

---

## Services & Constants

### AuditTrailService
**Path:** `rohan_ui-parent/rohan_ui/src/app/shared-services/audit-trail/audit-trail.service.ts`

**Methods:**
```typescript
logAuditTrail(feature: AuditTrailFeature, action: string)
logBatchAuditTrail(entries: AuditTrailEntry[])
getAuditTrail(startDate?, endDate?, feature?, performedBy?, page?, pageSize?, metrics?, templateId?)
getAuditTrailFiltersData(metrics?)
getAuditTrailCSV(startDate?, endDate?, feature?, performedBy?, metrics?, templateId?)
logWordCount(feature, wordCount, purposeUsingFeature)
postToAuditTrail(feature, action)
```

**Features:**
- Word count tracking
- Metrics vs Audit Trail endpoints (dual-use service)
- CSV file download with timezone handling
- Batch logging support

### AuditTrailManager (Utility Class)
**Path:** `rohan_ui-parent/rohan_ui/src/app/pages/settings/utility/audit-trail-manager.ts`

**Purpose:** Centralized state + fetching logic for Settings audit trail (and metrics)

**Key Methods:**
- `fetchInitialAuditTrail(startDate?)` — 6-month default
- `getMoreAuditTrail(filterData)` — pagination
- `fetchAuditTrail(filterData)` — core fetch
- `downloadCSV(startDate, endDate, feature, performedBy)`
- `getAuditTrailFiltersData()`

**Feature Filtering:** Procurement-only allows specific features; general audit allows all.

### StreamingActivityService
**Path:** `rohan_ui-parent/rohan_ui/src/app/shared-services/streaming-activity/streaming-activity.service.ts`

**Purpose:** Notification service (not audit-specific)

**Methods:**
```typescript
notifyActivity(): void
activity$: Observable
```

---

## Constants & Types

### Audit Trail Constants
**Path:** `rohan_ui-parent/rohan_ui/src/app/shared-services/audit-trail/audit-trail.constants.ts`

**Feature Enum:**
```typescript
AUDIT_TRAIL_FEATURES = {
    PROPOSAL_WRITER: 'Proposal-Writer',
    SETTINGS: 'Settings',
    GRAPHICS_LOOKBOOK: 'Graphics-Lookbook',
    SOLUTIONS_ARCHITECT: 'Solutions-Architect',
    ANSWER_ENGINE: 'Answer-Engine',
    USER: 'User',
    ACQUISITION_CENTER: 'Acquisition-Center',
    TEMPLATE_GENERATOR: 'Template-Generator',
}
```

**Action Presets:**
```typescript
AUDIT_TRAIL_ACTIONS = {
    UPLOADED_FILE, DOWNLOADED_DOCUMENT, CREATED_PROPOSAL,
    ARCHIVED_PROPOSAL, DELETED_PROPOSAL, UPDATED_SETTINGS,
    DOWNLOADED_GRAPHIC,
}
```

**Record DTO:**
```typescript
interface AuditTrailRecord {
    id: number;
    timestamp: string;
    feature: AuditTrailFeature;
    action: string;
    performed_by: string;
    archive_at: string;
}

interface AuditTrailFiltersData {
    features: AuditTrailFeature[];
    performed_by: string[];
}
```

### Activity Item Types
```typescript
export type ActivityType = 'search' | 'reasoning' | 'completion' | 'open_page' | 'error' | 'markdown';

export interface ActivityItem {
    message: string;
    id: string;
    type?: ActivityType;
    timestamp?: Date;
    url?: string;
}
```

---

## Backend Endpoints (NestJS API)

**Base Controller:** `/settings` (SettingsController)

| Endpoint | Method | Purpose | Query Params | Response |
|----------|--------|---------|--------------|----------|
| `/audit_trail` | GET | Fetch audit trail records | startDate, endDate, feature, performedBy, page, pageSize, templateId, scopeType, scopeId, entityType, entityId, metadata, action | `{data: AuditTrail[], page, count, pageSize}` |
| `/audit_trail` | POST | Log single audit entry | (body: AuditTrailInput) | `{message: string}` |
| `/audit_trail/batch` | POST | Log batch entries | (body: AuditTrailInputBatch) | (returns success) |
| `/audit_trail_csv` | GET | Download CSV | startDate, endDate, feature, performedBy, templateId, timeZone | ArrayBuffer (CSV) |
| `/audit_trail_filters_data` | GET | Get filter options | (none) | `{features[], performed_by[]}` |

**Backend DTO (`audit_trail.dto.ts`):**
```typescript
export class AuditTrailDto {
  feature: AuditTrailFeature;
  action: string;
  performed_by: string;
  scope_type?: string;
  scope_id?: string;
  entity_type?: string;
  entity_id?: string;
}

export class AuditTrailInput {
  feature: AuditTrailFeature;
  action: string;
}
```

---

## Similarities Across Components

1. **Data Shape:** All full audit pages use `AuditTrailRecord` (timestamp, feature, action, performed_by) + optional metadata.
2. **Service Pattern:** Inject `AuditTrailService` and call `getAuditTrail()`.
3. **Filtering:** Date range (with presets), multi-select by email/feature.
4. **CSV Export:** All full-featured pages support download with current filters.
5. **Material Usage:** All use Material Table, Select, Form, Icon, Button.
6. **Change Detection:** OnPush strategy.
7. **Expandable Actions:** Action text truncates with expand/collapse toggle.
8. **Infinite Scroll or Pagination:** AuditTrail (Settings) uses infinite scroll; Template uses all-at-once load.

---

## Differences Across Components

| Feature | AuditTrail | TemplateAuditLog | ActivityPanel | ActivityList | ActivityItem |
|---------|-----------|------------------|---------------|--------------|--------------|
| **Scope** | Global | Template-specific | Feature-agnostic | Feature-agnostic | Feature-agnostic |
| **Data Source** | AuditTrailService | AuditTrailService + route | Signal/Input | Input array | Input single |
| **Filtering** | Date + Email + Feature | Date + Email + Action Text | None | None | None |
| **UI Pattern** | Table + Toolbar | Table + Toolbar | Tabbed panel | List | Single item |
| **Pagination** | Infinite scroll | All-at-once (10k limit) | N/A | N/A | N/A |
| **CSV Export** | Yes | Yes | No | No | No |
| **Expandable Rows** | Action column only | Action column only | N/A | N/A | N/A |
| **Multi-tab** | No | No | Yes (Activity/Sources) | No | No |
| **Markdown Support** | No | No | No | No | Yes |
| **Type-based Rendering** | No | No | No | Yes (icons) | Yes (type-specific) |

---

## Candidate Reusable Audit Component API

Based on analysis, a shared reusable audit page component should support:

### Inputs
```typescript
@Input() auditRecords: AuditTrailRecord[] = [];
@Input() resultsCount: number = 0;
@Input() filtersData: AuditTrailFiltersData | null = null;
@Input() columnsToDisplay: string[] = ['timestamp', 'feature', 'action', 'performed_by'];
@Input() allowInfiniteScroll: boolean = true;
@Input() allowFeatureFilter: boolean = true;
@Input() allowEmailFilter: boolean = true;
@Input() allowDateRangeFilter: boolean = true;
@Input() allowActionTextFilter: boolean = false; // template-specific
@Input() defaultStartDate?: string; // 6 months ago
@Input() pageSize: number = 50;
@Input() scopeContext?: {  // For template or project-specific audit
  templateId?: number;
  projectId?: string;
  entityType?: string;
}
```

### Outputs
```typescript
@Output() filtersChanged = new EventEmitter<AuditTrailFilters>();
@Output() csvDownloadRequested = new EventEmitter<AuditTrailFilters>();
@Output() scrolledToBottom = new EventEmitter<AuditTrailFilters>();
@Output() rowActionClicked = new EventEmitter<{
  action: 'expand' | 'view-diff' | 'revert';
  record: AuditTrailRecord;
}>();
```

### Features to Consolidate
1. **Filter Toolbar** (date range + multi-selects + action search)
2. **Expandable Action Column** (truncate + expand/collapse)
3. **Sticky Header Table** with customizable columns
4. **Infinite Scroll vs Pagination** toggle
5. **CSV Download** with current filter state
6. **Empty State** messaging
7. **Date Range Modal** (reusable `DatePickerModalComponent`)
8. **Multi-select with Search** (ngx-mat-select-search)

### Configuration Options
- **Display mode:** table-only vs table+toolbar
- **Sort capability:** by timestamp, feature, performer (optional)
- **Grouping:** by date, by feature, by performer (optional)
- **Row actions:** expand, view-diff (optional), revert (optional)
- **Styling variants:** compact, standard, detailed

### Service Integration Points
- Inject `AuditTrailService`
- Accept custom filter DTO interface (extends `AuditTrailFilters`)
- Support metrics vs audit-trail dual endpoint

---

## File Structure Summary

```
rohan_ui/src/app/
├── shared-components/
│   ├── activity-item/                    [base item unit]
│   ├── activity-list/                    [vertical list of items]
│   ├── activity-panel/                   [tabbed panel with sources]
│   └── shared-components.module.ts
├── shared-services/
│   ├── audit-trail/
│   │   ├── audit-trail.service.ts        [fetch + log]
│   │   ├── audit-trail.constants.ts      [DTOs + enums]
│   │   └── audit-trail.spec.ts
│   └── streaming-activity/               [notification service]
├── pages/
│   ├── settings/
│   │   ├── components/audit-trail/       [full-featured settings audit]
│   │   ├── utility/audit-trail-manager.ts [state management]
│   │   └── root/settings.component.ts    [orchestrator]
│   ├── acquisition-center/
│   │   └── template-generator/
│   │       └── template-audit-log/       [template-scoped audit]
│   ├── one-ring/
│   │   └── run-history-tab/              [placeholder]
│   ├── compliance/
│   │   └── compliance-project-audit-page/[placeholder]
│   └── answer-engine-v2/
│       └── activity-panel-lite/          [lightweight activity panel]
```

---

## Key Takeaways for Building Reusable Component

1. **Two Distinct Patterns:**
   - **Audit Pages:** Full-featured (filters + pagination + export) — AuditTrail, TemplateAuditLog
   - **Activity Streams:** Lightweight display only (no filtering) — ActivityPanel, ActivityList, ActivityItem

2. **Service Contract:** All audit components call `AuditTrailService.getAuditTrail()` with same signature; differentiate via `feature`, `templateId`, and `scopeId` params.

3. **Reusable Sub-components:** ActivityItem, ActivityList, ActivityPanel are already generic and decoupled; they're ready to be consumed by new audit pages.

4. **Template-specific Pattern:** TemplateAuditLog shows how to scope audit to a specific context (templateId) with client-side action filtering — model this pattern for other scoped audits.

5. **Styling & State:** Each component manages its own styling and local form state (date, filters); the `AuditTrailManager` class handles state if needed at page level.

6. **Missing Feature:** Neither current audit page implements a diff viewer, row-level actions, or revert functionality — these are candidates for new shared features.

7. **Placeholders Ready to Fill:** `RunHistoryTabComponent` (one-ring) and `ComplianceProjectAuditPageComponent` are placeholders — ideal first consumers of a new reusable audit page component.
