# PRCR-1063: API Contracts and Data Shapes (Template Audit Log)

Single source of truth for request/response shapes, validation rules, and error formats shared between frontend and backend for template-scoped audit log (PRCR-1063).

---

## 1. GET /settings/audit_trail (list)

**Purpose**: Paginated audit log entries, optionally filtered by template.

**Method**: `GET`  
**Path**: `/settings/audit_trail`  
**Auth**: JWT + Admin permission required.

### Query parameters

| Parameter      | Type   | Required | Description                                                                                                                                                         |
| -------------- | ------ | -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| startDate      | string | No       | ISO date string; filter `timestamp >= startDate`.                                                                                                                   |
| endDate        | string | No       | ISO date string; filter `timestamp <= endDate`.                                                                                                                     |
| feature        | string | No       | Comma-separated feature names (e.g. `Template-Generator`).                                                                                                          |
| performedBy    | string | No       | Comma-separated email addresses.                                                                                                                                    |
| page           | number | No       | 1-based page index for pagination.                                                                                                                                  |
| pageSize       | number | No       | Page size (default from backend).                                                                                                                                   |
| actionType     | string | No       | `metrics` or `untyped` (filters by action prefix "Metric: ").                                                                                                       |
| **templateId** | number | No       | When set, only entries whose `action` starts with `Template {templateId}` (case-insensitive) are returned.                                                          |
| **action**     | string | No       | When set, only entries whose `action` contains this value (case-insensitive substring). E.g. `published`, `edited`, `section`, `moved from step`, `status changed`. |

### Response shape

```ts
{
  data: AuditTrailRecord[];
  page: number;
  count: number;
  pageSize: number;
}
```

**AuditTrailRecord** (each item in `data`):

| Field        | Type           | Description                                                                                                                                  |
| ------------ | -------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| id           | number         | Primary key.                                                                                                                                 |
| timestamp    | string         | ISO date string.                                                                                                                             |
| feature      | string         | e.g. `Template-Generator`.                                                                                                                   |
| action       | string         | Human-readable action text (see Template action formats below).                                                                              |
| performed_by | string         | Email of user who performed the action.                                                                                                      |
| archive_at   | string         | Used for retention; entries with `archive_at < now` may be excluded.                                                                         |
| **details**  | object \| null | Optional. For template section content changes, may contain `{ "before": string, "after": string }` (or structured fields). Omitted if null. |

### Backend filters

- **templateId**: `LOWER(audit.action) LIKE LOWER('Template {templateId}%')`. All template-related actions use the format `Template {id} ({name}) ...`.
- **action**: When provided, `LOWER(audit.action) LIKE LOWER('%' + escaped(value) + '%')`. Backend must escape `%` and `_` in the value to avoid SQL LIKE injection.

### Errors

- `500` – Generic audit trail error (message from `SettingsErrors.auditTrailError`).

---

## 2. GET /settings/audit_trail_csv (download CSV)

**Purpose**: Export audit log as CSV with same filters as list (including template).

**Method**: `GET`  
**Path**: `/settings/audit_trail_csv`  
**Auth**: JWT + Admin permission required.

### Query parameters

| Parameter      | Type   | Required | Description                                   |
| -------------- | ------ | -------- | --------------------------------------------- |
| startDate      | string | **Yes**  | Start of date range.                          |
| endDate        | string | **Yes**  | End of date range.                            |
| feature        | string | No       | Same as list.                                 |
| performedBy    | string | No       | Same as list.                                 |
| actionType     | string | No       | Same as list.                                 |
| **templateId** | number | No       | Same as list; only entries for this template. |
| **action**     | string | No       | Same as list; substring match on action.      |

### Response

- **Content-Type**: `text/csv`
- **Content-Disposition**: `attachment; filename="audit_logs_{startDate}_{endDate}.csv"`
- **Body**: CSV with headers `timestamp`, `feature`, `action`, `performed_by` (and optionally `details` if supported); one row per audit record (no pagination).

### Validation

- If `startDate` or `endDate` is missing → `400` with `SettingsErrors.auditTrailDateError`.

### Errors

- `400` – Missing/invalid date (auditTrailDateError); CSV/date formatting errors.
- `500` – CSV generation or general audit error.

---

## 3. Template audit action string formats (backend)

All template-related audit entries use `feature: 'Template-Generator'` and `action` strings starting with `Template {templateId} (` so that filtering by `templateId` (e.g. `Template 123%`) returns only that template’s events.

| Event type         | Format / example                                                                 |
| ------------------ | -------------------------------------------------------------------------------- |
| Generated          | `Template {id} ({name}) generated`                                               |
| Edited             | `Template {id} ({name}) edited`                                                  |
| Deleted            | `Template {id} ({name}) deleted`                                                 |
| Published          | `Template {id} ({name}) published`                                               |
| Unpublished        | `Template {id} ({name}) unpublished`                                             |
| Archived           | `Template {id} ({name}) archived`                                                |
| Restored           | `Template {id} ({name}) restored`                                                |
| State change       | `Template {id} ({name}) status changed from "{fromStatus}" to "{toStatus}"`      |
| Wizard step change | `Template {id} ({name}) moved from step "{fromStepName}" to step "{toStepName}"` |
| Section content    | `Template {id} ({name}) - section "{sectionName}" added \| modified \| deleted`  |

**Details (before/after)**: For section content changes (especially "modified"), the backend may store optional **details** (e.g. JSON) with `before` and `after` strings summarizing or containing the previous and new section content (e.g. section_title, instructions_text, helper_text, field_prompt). The list API returns `details` when present; CSV may include a `details` column or omit it (implementation choice).

---

## 3b. Audit log write payload (optional details)

When the backend writes an audit entry (e.g. `appendAuditLog`), the payload may include optional **details** for template section content changes.

**AuditTrailDto (server-side, for appendAuditLog)**:

| Field        | Type   | Required | Description                                                                                                  |
| ------------ | ------ | -------- | ------------------------------------------------------------------------------------------------------------ |
| feature      | string | Yes      | e.g. `Template-Generator`.                                                                                   |
| action       | string | Yes      | Human-readable action (see formats above).                                                                   |
| performed_by | string | Yes      | User email.                                                                                                  |
| **details**  | string | No       | JSON string, e.g. `JSON.stringify({ before: "...", after: "..." })`. Stored in `audit_trail.details` column. |

For section "modified" events, template-generator.service should pass `details` with a JSON object containing at least `before` and `after` (e.g. concatenated or structured representation of the section fields that changed). For "added" or "deleted", details may be omitted or contain only the relevant state.

---

## 4. Frontend data shapes and filter type

### AuditTrailFilters (extended for template audit page)

```ts
interface AuditTrailFilters {
  startDate: string;
  endDate?: string;
  feature?: string;
  performedBy?: string;
  page?: number;
  pageSize?: number;
  templateId?: number; // when set, only template-scoped audit
  action?: string; // optional substring filter on action (e.g. "published", "edited", "section")
}
```

### GetAuditTrailResponse (client)

```ts
interface GetAuditTrailResponse {
  data: AuditTrailRecord[];
  count: number;
  pageSize: number;
  page: number;
}
```

### AuditTrailRecord (client)

```ts
interface AuditTrailRecord {
  id: number;
  timestamp: string;
  feature: string;
  action: string;
  performed_by: string;
  archive_at: string;
  details?: { before?: string; after?: string } | null; // optional; for section content changes
}
```

### AuditTrailFiltersData (for filter dropdowns)

```ts
interface AuditTrailFiltersData {
  features: string[];
  performed_by: string[];
}
```

When the template audit page is shown, the list is already scoped to one template; the UI shows Date, Email, and **Action** filters. Action filter options can be a fixed list (e.g. "All", "Published", "Edited", "Section modified", "Step change", "State change") mapping to backend substring values. The backend `audit_trail_filters_data` endpoint is unchanged for features/performed_by; Action filter is a free-form or fixed client-side list passed as the `action` query param.

---

## 5. Validation rules

- **templateId**: If present, must be a positive integer (template primary key). Backend accepts as number; invalid values may yield no rows.
- **startDate / endDate**: For CSV, both required; for list, optional. Values are parsed as `Date`; invalid format may result in backend error or undefined behavior.
- **page**: 1-based; backend uses it as pagination index.
- **feature**: When template-scoped, frontend typically sends `Template-Generator` or omits to get all features for that template (only template actions are returned when templateId is set).
- **action**: Optional substring; backend matches case-insensitively. Safe values for dropdown: e.g. "published", "edited", "section", "moved from step", "status changed".

---

## 6. Error format (HTTP)

- Backend returns standard NestJS `HttpException` with status and message.
- Frontend should handle `400` (e.g. missing dates for CSV) and `500` (e.g. audit trail error) and surface a user-friendly message or toast.

---

## 7. Navigation (frontend)

- **Route**: `/acquisition-center/template-generator/audit/:templateId`
- **Resolve**: `templateId` from `ActivatedRoute.params` or `paramMap` (string); convert to number for API (e.g. `Number(route.snapshot.paramMap.get('templateId'))`).
- **Optional**: `GET /procurement-templates/:id` to display template name in the page header (response shape per existing template API; not redefined here).
