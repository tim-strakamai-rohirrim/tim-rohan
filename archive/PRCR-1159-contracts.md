# PRCR-1159 API Contracts

Single source of truth for request/response shapes, validation rules, and error formats for the compliance-check review endpoint.

---

## Endpoint

```
PATCH /compliance/projects/{projectId}/responses/{responseId}/checks/{checkId}
```

### Auth

- Requires valid JWT (`AuthGuard('jwt')`)
- Requires `compliance` permission (`PermissionsGuard` + `@Permissions('compliance')`)
- Caller must be the **project owner** (`project.projectOwner.user_id === caller.user_id`) — enforced via `ensureProjectOwnership` in the service; non-owners receive 404 (same surface as all other compliance write endpoints)

---

## Path Parameters

| Param | Type | Validation |
|---|---|---|
| `projectId` | UUID string | `ParseUUIDPipe` — 400 if not valid UUID |
| `responseId` | UUID string | `ParseUUIDPipe` — 400 if not valid UUID |
| `checkId` | UUID string | `ParseUUIDPipe` — 400 if not valid UUID |

---

## Request Body — `UpdateComplianceCheckDto`

```ts
class UpdateComplianceCheckDto {
  userDetermination?: 'compliant' | 'non_compliant' | 'not_applicable' | null;
  userNotes?: string | null;
}
```

| Field | Type | Required | Validation |
|---|---|---|---|
| `userDetermination` | `UserDetermination` enum or `null` | No | Must be a valid enum value if provided; `null` allowed to clear |
| `userNotes` | `string` or `null` | No | Free text; `null` allowed to clear |

At least one field should be present (but this is not enforced at the transport layer — a no-op body is accepted and returns the current state unchanged).

### Validation Rules

- `userDetermination`, if provided and non-null, must be one of: `compliant`, `non_compliant`, `not_applicable`.
- `userNotes`, if provided, has no length restriction at the API layer (mirrors the `TEXT` column).

---

## Side-Effect Rules (business logic)

| Condition | Effect on `reviewed_by` / `reviewed_at` |
|---|---|
| `userDetermination` set to a non-null value | Set to current user / current timestamp |
| `userDetermination` set to `null` | Clear both to `null` |
| Only `userNotes` provided (no `userDetermination` key) | Unchanged |

### Write guard

If the parent response's `status` is `ResponseStatus.APPROVED`, the endpoint returns **409 Conflict** and no fields are modified.

---

## Response Body — `ComplianceCheckResponseDto`

HTTP `200 OK` on success.

```ts
class ComplianceCheckResponseDto {
  id: string;                              // UUID
  automatedStatus: 'pass' | 'fail' | null;
  userDetermination: 'compliant' | 'non_compliant' | 'not_applicable' | null;
  userNotes: string | null;
  reviewer: ComplianceUserRefDto | null;
  reviewedAt: Date | null;                 // ISO-8601
  createdAt: Date;
  updatedAt: Date;
  complianceItem: ComplianceCheckItemWithTextDto;
}

class ComplianceUserRefDto {
  user_id: string;
  name: string;
  email: string;
}

class ComplianceCheckItemWithTextDto {
  id: string;
  complianceItemTitle: string;
  complianceItemText: string;
  lineItemNumber: number | null;
  outlineNumber: string | null;
  sectionName: string | null;
  status: 'pending_review' | 'approved' | 'rejected';
}
```

---

## Error Responses

| HTTP | Condition | Body |
|---|---|---|
| `400 Bad Request` | `projectId`, `responseId`, or `checkId` is not a valid UUID | NestJS default validation error |
| `400 Bad Request` | `userDetermination` is not a valid enum value | NestJS class-validator error |
| `401 Unauthorized` | Missing or invalid JWT | Standard auth error |
| `403 Forbidden` | User lacks `compliance` permission | Standard permissions error |
| `404 Not Found` | Project not found **or caller is not the project owner** | `{ message: "Project not found or user not authorized." }` (same surface as `ensureProjectOwnership`) |
| `404 Not Found` | Response does not belong to project | `{ message: "Response not found or user not authorized." }` |
| `404 Not Found` | Check does not belong to the response | `{ message: "Compliance check with ID {checkId} not found" }` |
| `409 Conflict` | Parent response status is `approved` — writes are locked | `{ message: "Cannot update a compliance check for an approved response" }` |
| `500 Internal Server Error` | Unexpected DB/service error | `{ message: "Error updating compliance check" }` |

---

## Unchanged Contracts (existing, for reference)

### GET `.../checks` → `ComplianceCheckResponseDto[]`

No changes to this endpoint.

### `UserDetermination` enum

```ts
enum UserDetermination {
  COMPLIANT = 'compliant',
  NON_COMPLIANT = 'non_compliant',
  NOT_APPLICABLE = 'not_applicable',
}
```

### `AutomatedStatus` enum (read-only from API perspective)

```ts
enum AutomatedStatus {
  PASS = 'pass',
  FAIL = 'fail',
}
```
