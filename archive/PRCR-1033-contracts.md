# PRCR-1033: Compliance API contracts (projects CRUD, MinIO uploads, compliance-items)

Single source of truth for request/response shapes, validation rules, and error formats for the Compliance projects, document upload, and compliance-items endpoints. Base path: **`/compliance`** (e.g. full URL prefix may be `{baseUrl}/compliance`).

---

## Authentication and authorization

- All routes require **JWT** (`AuthGuard('jwt')`) and **permission** `compliance` (`PermissionsGuard` + `@Permissions('compliance')`).
- Unauthorized requests: **401 Unauthorized**.
- Forbidden (no permission): **403 Forbidden** (if applicable).

---

## Enums and constants

### ProjectStatus (response / internal)

| Value                      | Description                         |
| -------------------------- | ----------------------------------- |
| `active`                   | Default; project in use             |
| `creating_compliance_list` | Work in progress                    |
| `reviewing_responses`      | Work in progress                    |
| `archived`                 | Archived; can be soft-deleted       |
| `deleted`                  | Soft-deleted (not returned in list) |

### UserSettableProjectStatus (request body for PUT /projects/:id)

Only these values may be set by the client: **`active`** | **`archived`**.

---

## Projects CRUD

### GET /compliance/projects

**Description:** List compliance projects owned by the current user.

**Request**

- **Headers:** `Authorization: Bearer <token>`
- **Query:** None.
- **Body:** None.

**Response**

- **200 OK**
  - Body: **Array of project objects** (summary shape; no nested relations).
  - Each item includes at least: `id`, `projectName`, `contractNumber`, `startDate`, `dueDate`, `additionalDetails`, `status`, `createdAt`, `updatedAt`, and owner/creator references as returned by the backend (e.g. `projectOwner`, `creator`).

**Errors**

| Status | When                                                       |
| ------ | ---------------------------------------------------------- |
| 401    | Missing or invalid JWT                                     |
| 403    | User does not have `compliance` permission                 |
| 500    | Internal error (e.g. “Error fetching compliance projects”) |

---

### GET /compliance/projects/:id

**Description:** Get a single compliance project by ID with related documents and responses.

**Request**

- **Headers:** `Authorization: Bearer <token>`
- **Path:** `id` (UUID).
- **Body:** None.

**Response**

- **200 OK**
  - Body: **Single project object** with nested relations, e.g.:
    - `documents` (with `document` and `document.complianceItems`)
    - `responses` (with `documents`, `complianceChecks` with `complianceItem` and `evidence`).
  - Fields include: `id`, `projectName`, `contractNumber`, `startDate`, `dueDate`, `additionalDetails`, `status`, `createdAt`, `updatedAt`, `projectOwner`, `creator`, `updater`, and the relations above.

**Errors**

| Status | When                                                                           |
| ------ | ------------------------------------------------------------------------------ |
| 400    | Invalid UUID for `id`                                                          |
| 401    | Missing or invalid JWT                                                         |
| 403    | No permission                                                                  |
| 404    | Project not found or not owned by user (e.g. “Project with ID {id} not found”) |
| 500    | Internal error (e.g. “Error fetching compliance project by ID”)                |

---

### POST /compliance/projects

**Description:** Create a new compliance project. Owner defaults to the current user.

**Request**

- **Headers:** `Authorization: Bearer <token>`, `Content-Type: application/json`
- **Body:** JSON matching **CreateComplianceProjectDto**.

| Field               | Type                   | Required | Validation                        | Notes                                        |
| ------------------- | ---------------------- | -------- | --------------------------------- | -------------------------------------------- |
| `projectName`       | string                 | No\*     | -                                 | \*Optional in DTO; consider requiring for UX |
| `contractNumber`    | string                 | No       | -                                 |                                              |
| `startDate`         | string (ISO 8601 date) | No       | `@IsDate()` + `@Type(() => Date)` |                                              |
| `dueDate`           | string (ISO 8601 date) | No       | `@IsDate()` + `@Type(() => Date)` |                                              |
| `additionalDetails` | string                 | No       | -                                 |                                              |
| `projectOwnerId`    | number                 | No       | `@IsInt()`                        | Defaults to creator if omitted               |
| `status`            | ProjectStatus enum     | No       | `@IsEnum(ProjectStatus)`          | Defaults to `active`                         |

**Response**

- **201 Created**
  - Body: **Created project entity** (same shape as returned by repository save: `id`, `projectName`, `contractNumber`, `startDate`, `dueDate`, `additionalDetails`, `status`, `createdAt`, `updatedAt`, `projectOwner`, `creator`, etc.).

**Errors**

| Status | When                                                      |
| ------ | --------------------------------------------------------- |
| 400    | Validation failed (invalid types, e.g. date or enum)      |
| 401    | Missing or invalid JWT                                    |
| 403    | No permission                                             |
| 500    | Internal error (e.g. “Error creating compliance project”) |

---

### PATCH /compliance/projects/:id

**Description:** Update an existing compliance project.

**Request**

- **Headers:** `Authorization: Bearer <token>`, `Content-Type: application/json`
- **Path:** `id` (UUID).
- **Body:** JSON matching **UpdateComplianceProjectDto** (all fields optional).

| Field               | Type              | Required | Validation                       | Notes |
| ------------------- | ----------------- | -------- | -------------------------------- | ----- |
| `projectName`       | string            | No       | max 255                          |       |
| `contractNumber`    | string            | No       | max 100                          |       |
| `startDate`         | string (ISO 8601) | No       | `@IsDateString()`                |       |
| `dueDate`           | string (ISO 8601) | No       | `@IsDateString()`                |       |
| `additionalDetails` | string            | No       | -                                |       |
| `projectOwnerId`    | string            | No       | -                                |       |
| `documentsToDelete` | string[] (UUIDs)  | No       | `@IsUUID('all', { each: true })` |       |
| `responsesToDelete` | string[] (UUIDs)  | No       | `@IsUUID('all', { each: true })` |       |

**Response**

- **200 OK**
  - Body: **Updated project entity** (full entity shape with relations as returned by the service).

**Errors**

| Status | When                                                      |
| ------ | --------------------------------------------------------- |
| 400    | Invalid UUID or validation failure                        |
| 401    | Missing or invalid JWT                                    |
| 403    | No permission                                             |
| 404    | Project not found or not owned by user                    |
| 500    | Internal error (e.g. “Error updating compliance project”) |

---

### DELETE /compliance/projects/:id

**Description:** Soft-delete a project. The project **must** be in status **`archived`** first; otherwise the API returns 409.

**Request**

- **Headers:** `Authorization: Bearer <token>`
- **Path:** `id` (UUID).
- **Body:** None.

**Response**

- **200 OK** or **204 No Content**
  - Body: None (implementation returns void).

**Errors**

| Status | When                                                                                       |
| ------ | ------------------------------------------------------------------------------------------ |
| 401    | Missing or invalid JWT                                                                     |
| 403    | No permission                                                                              |
| 404    | Project not found or user not authorized (e.g. “Project not found or user not authorized”) |
| 409    | Project is not archived (e.g. “Cannot delete an active project. Please archive it first.”) |
| 500    | Internal error                                                                             |

---

### PUT /compliance/projects/:id

**Description:** Set project status to `active` or `archived` (user-settable statuses only).

**Request**

- **Headers:** `Authorization: Bearer <token>`, `Content-Type: application/json`
- **Path:** `id` (UUID).
- **Body:** **SetProjectStatusDto**

| Field    | Type   | Required | Validation                      | Notes                              |
| -------- | ------ | -------- | ------------------------------- | ---------------------------------- |
| `status` | string | Yes      | `@IsIn(['active', 'archived'])` | Literal `'active'` or `'archived'` |

**Response**

- **200 OK**
  - Body: **Updated project entity** (e.g. full ComplianceProject with new `status`).

**Errors**

| Status | When                                                                           |
| ------ | ------------------------------------------------------------------------------ |
| 400    | Invalid UUID or body (e.g. status not in `['active','archived']`)              |
| 401    | Missing or invalid JWT                                                         |
| 403    | No permission                                                                  |
| 404    | Project not found or user not authorized (e.g. “Compliance project not found”) |
| 500    | Internal error                                                                 |

---

## MinIO upload routes

### POST /compliance/projects/:project_id/documents

**Description:** Upload a **source document** for a compliance project. Stored in MinIO and linked to the project.

**Request**

- **Headers:** `Authorization: Bearer <token>`, `Content-Type: multipart/form-data`
- **Path:** `project_id` (UUID).
- **Body:** Multipart form with **one file** (field name not strictly defined; backend reads first part with `part.file`). Typically a single file field (e.g. `file` or `document`).

**Response**

- **200 OK** or **201 Created**
  - Body: **Upload result object**

| Field        | Type    | Description                      |
| ------------ | ------- | -------------------------------- |
| `success`    | boolean | `true`                           |
| `key`        | string  | MinIO object key                 |
| `filename`   | string  | Original filename                |
| `projectId`  | string  | Project UUID                     |
| `documentId` | string  | Created compliance document UUID |

**Errors**

| Status | When                                                                                        |
| ------ | ------------------------------------------------------------------------------------------- |
| 400    | No file in request (e.g. “No file provided”)                                                |
| 401    | Missing or invalid JWT                                                                      |
| 403    | No permission                                                                               |
| 404    | Project not found or user not authorized (e.g. “Project not found or user not authorized.”) |
| 500    | Upload or persistence error (e.g. “An unexpected error occurred”)                           |

---

### POST /compliance/projects/:project_id/responses/:response_id/documents

**Description:** Upload a **response document** for a specific response within a project. Stored in MinIO and linked to the response.

**Request**

- **Headers:** `Authorization: Bearer <token>`, `Content-Type: multipart/form-data`
- **Path:** `project_id` (UUID), `response_id` (UUID).
- **Body:** Multipart form with **one file** (same as source document upload).

**Response**

- **200 OK** or **201 Created**
  - Body: **Upload result object**

| Field        | Type    | Description                      |
| ------------ | ------- | -------------------------------- |
| `success`    | boolean | `true`                           |
| `key`        | string  | MinIO object key                 |
| `filename`   | string  | Original filename                |
| `projectId`  | string  | Project UUID                     |
| `responseId` | string  | Response UUID                    |
| `documentId` | string  | Created compliance document UUID |

**Errors**

| Status | When                                                                                                                                                        |
| ------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 400    | No file in request (e.g. “No file provided”)                                                                                                                |
| 401    | Missing or invalid JWT                                                                                                                                      |
| 403    | No permission                                                                                                                                               |
| 404    | Project not found, or response not found / not authorized (e.g. “Project not found or user not authorized.” / “Response not found or user not authorized.”) |
| 500    | Upload or persistence error (e.g. “An unexpected error occurred”)                                                                                           |

---

## Compliance-items routes

Compliance items belong to a project and (optionally) a source document. All routes require the project to exist and to be owned by the current user.

### Enums (compliance-items)

**ComplianceItemStatus** (response / PATCH body):

| Value           | Description     |
| --------------- | --------------- |
| `pending_review` | Default for new items |
| `approved`      | Approved        |
| `rejected`     | Rejected        |

**ExtractionMethod** (request body):

| Value            | Description   |
| ---------------- | ------------- |
| `auto_extracted` | Auto-extracted |
| `manual`         | Manual        |
| `edited`         | Edited        |

---

### GET /compliance/projects/:id/compliance-items

**Description:** List all compliance items for a project. User must own the project.

**Request**

- **Headers:** `Authorization: Bearer <token>`
- **Path:** `id` (UUID) — project ID.
- **Body:** None.

**Response**

- **200 OK**
  - Body: **Array of compliance item objects** (entity shape; no nested relations by default).
  - Each item includes at least: `id`, `complianceItemTitle`, `complianceItemText`, `lineItemNumber`, `outlineNumber`, `sectionName`, `documentStartLine`, `documentEndLine`, `extractionMethod`, `status`, `createdAt`, `updatedAt`, and references to `project`, `sourceDocument` as returned by the backend.

**Errors**

| Status | When                                                                 |
| ------ | -------------------------------------------------------------------- |
| 400    | Invalid UUID for `id`                                                |
| 401    | Missing or invalid JWT                                              |
| 403    | No permission                                                       |
| 404    | Project not found or not owned by user (e.g. “Project with ID … not found”) |
| 500    | Internal error (e.g. “Error fetching compliance items”)              |

---

### GET /compliance/projects/:id/compliance-items/:itemId

**Description:** Get a single compliance item by project ID and item ID. User must own the project.

**Request**

- **Headers:** `Authorization: Bearer <token>`
- **Path:** `id` (UUID) — project ID; `itemId` (UUID) — compliance item ID.
- **Body:** None.

**Response**

- **200 OK**
  - Body: **Single compliance item object** (entity shape as returned by the service; may include relations such as `sourceDocument` when loaded).

**Errors**

| Status | When                                                                                    |
| ------ | --------------------------------------------------------------------------------------- |
| 400    | Invalid UUID for `id` or `itemId`                                                       |
| 401    | Missing or invalid JWT                                                                 |
| 403    | No permission                                                                          |
| 404    | Project not found or not owned by user, or compliance item not found (e.g. “Compliance item with ID {itemId} not found”) |
| 500    | Internal error (e.g. “Error fetching compliance item”)                                 |

---

### POST /compliance/projects/:id/compliance-items

**Description:** Create a new compliance item for a project. Item is linked to a source document. Status defaults to `pending_review`.

**Request**

- **Headers:** `Authorization: Bearer <token>`, `Content-Type: application/json`
- **Path:** `id` (UUID) — project ID.
- **Body:** JSON matching **CreateComplianceItemDto**.

| Field                | Type              | Required | Validation                       | Notes                                  |
| -------------------- | ----------------- | -------- | -------------------------------- | -------------------------------------- |
| `sourceDocumentId`   | string (UUID)     | Yes      | `@IsUUID()`                      | Source document in this project        |
| `lineItemNumber`     | number            | No       | `@IsInt()`, `@Type(() => Number)` |                                        |
| `complianceItemTitle`| string            | Yes      | `@MaxLength(500)`                |                                        |
| `complianceItemText` | string            | Yes      | -                                |                                        |
| `outlineNumber`      | string            | No       | `@MaxLength(100)`                |                                        |
| `sectionName`        | string            | No       | `@MaxLength(255)`                |                                        |
| `documentStartLine`  | number            | No       | `@IsInt()`, `@Type(() => Number)` |                                        |
| `documentEndLine`    | number            | No       | `@IsInt()`, `@Type(() => Number)` |                                        |
| `extractionMethod`   | ExtractionMethod  | No       | `@IsEnum(ExtractionMethod)`      | `auto_extracted` \| `manual` \| `edited` |

**Response**

- **201 Created**
  - Body: **Created compliance item entity** (e.g. `id`, `complianceItemTitle`, `complianceItemText`, `status` default `pending_review`, `project`, `sourceDocument`, `createdAt`, `updatedAt`, etc.).

**Errors**

| Status | When                                                         |
| ------ | ------------------------------------------------------------ |
| 400    | Validation failed (invalid UUID, types, or max length)       |
| 401    | Missing or invalid JWT                                       |
| 403    | No permission                                                |
| 404    | Project not found or not owned by user                       |
| 500    | Internal error (e.g. “Error creating compliance item”)        |

---

### PATCH /compliance/projects/:id/compliance-items/:itemId

**Description:** Update an existing compliance item. All body fields are optional.

**Request**

- **Headers:** `Authorization: Bearer <token>`, `Content-Type: application/json`
- **Path:** `id` (UUID) — project ID; `itemId` (UUID) — compliance item ID.
- **Body:** JSON matching **UpdateComplianceItemDto** (all fields optional).

| Field                | Type                | Required | Validation                        | Notes                                   |
| -------------------- | ------------------- | -------- | --------------------------------- | --------------------------------------- |
| `complianceItemTitle`| string              | No       | `@MaxLength(500)`                  |                                         |
| `complianceItemText` | string              | No       | -                                  |                                         |
| `outlineNumber`      | string              | No       | `@MaxLength(100)`                  |                                         |
| `sectionName`        | string              | No       | `@MaxLength(255)`                  |                                         |
| `lineItemNumber`     | number              | No       | `@IsInt()`, `@Type(() => Number)`  |                                         |
| `documentStartLine`  | number              | No       | `@IsInt()`, `@Type(() => Number)`  |                                         |
| `documentEndLine`    | number              | No       | `@IsInt()`, `@Type(() => Number)`  |                                         |
| `extractionMethod`   | ExtractionMethod    | No       | `@IsEnum(ExtractionMethod)`         |                                         |
| `status`            | ComplianceItemStatus| No       | `@IsEnum(ComplianceItemStatus)`    | `pending_review` \| `approved` \| `rejected` |

**Response**

- **200 OK**
  - Body: **Updated compliance item entity** (full entity shape as returned by the service).

**Errors**

| Status | When                                                         |
| ------ | ------------------------------------------------------------ |
| 400    | Invalid UUID or validation failure                           |
| 401    | Missing or invalid JWT                                      |
| 403    | No permission                                               |
| 404    | Project not found or not owned by user, or compliance item not found |
| 500    | Internal error (e.g. “Error updating compliance item”)       |

---

### DELETE /compliance/projects/:id/compliance-items/:itemId

**Description:** Delete a compliance item. User must own the project. Item is removed (hard delete).

**Request**

- **Headers:** `Authorization: Bearer <token>`
- **Path:** `id` (UUID) — project ID; `itemId` (UUID) — compliance item ID.
- **Body:** None.

**Response**

- **200 OK** or **204 No Content**
  - Body: None (implementation returns void).

**Errors**

| Status | When                                                                                    |
| ------ | --------------------------------------------------------------------------------------- |
| 400    | Invalid UUID for `id` or `itemId`                                                       |
| 401    | Missing or invalid JWT                                                                 |
| 403    | No permission                                                                          |
| 404    | Project not found or not owned by user, or compliance item not found (e.g. “Compliance item with ID {itemId} not found”) |
| 500    | Internal error (e.g. “Error deleting compliance item”)                                  |

---

## Error response body format

NestJS typically returns error responses in a structured form. Assume a shape similar to:

```json
{
  "statusCode": 404,
  "message": "Project with ID <id> not found",
  "error": "Not Found"
}
```

- **statusCode:** HTTP status code.
- **message:** Human-readable message (may be a string or array of validation messages).
- **error:** Short error name (e.g. “Bad Request”, “Not Found”, “Conflict”).

Validation (400) responses may have `message` as an array of constraint messages when using `ValidationPipe`.

---

## Summary table

| Method | Path                                                              | Purpose                              |
| ------ | ----------------------------------------------------------------- | ------------------------------------ |
| GET    | /compliance/projects                                              | List projects                        |
| GET    | /compliance/projects/:id                                          | Get project by ID (with relations)   |
| POST   | /compliance/projects                                              | Create project                       |
| PATCH  | /compliance/projects/:id                                          | Update project                       |
| DELETE | /compliance/projects/:id                                          | Soft-delete (must be archived first) |
| PUT    | /compliance/projects/:id                                          | Set status (active \| archived)     |
| POST   | /compliance/projects/:project_id/documents                        | Upload source document               |
| POST   | /compliance/projects/:project_id/responses/:response_id/documents | Upload response document             |
| GET    | /compliance/projects/:id/compliance-items                         | List compliance items                |
| GET    | /compliance/projects/:id/compliance-items/:itemId                 | Get compliance item by ID            |
| POST   | /compliance/projects/:id/compliance-items                         | Create compliance item              |
| PATCH  | /compliance/projects/:id/compliance-items/:itemId                  | Update compliance item               |
| DELETE | /compliance/projects/:id/compliance-items/:itemId                  | Delete compliance item               |

All routes require JWT and `compliance` permission.

---

## Changelog

- **Step 12:** Compliance-items routes added to contracts: GET list, GET by id, POST, PATCH, DELETE. Request/response shapes, validation rules (CreateComplianceItemDto, UpdateComplianceItemDto), enums (ComplianceItemStatus, ExtractionMethod), and error formats documented.
- **Step 3 (backend):** Response DTOs added in code: `ComplianceProjectSummaryDto`, `ComplianceProjectDetailDto` (and nested DTOs), `UploadSourceDocumentResultDto`, `UploadResponseDocumentResultDto`. No contract changes; DTOs align with this document.
