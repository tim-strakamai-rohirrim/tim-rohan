# PRCR-1161 API Contracts

Single source of truth for request/response shapes, validation rules, and error formats for compliance check evidence retrieval.

---

## Contract Baseline

- This contract is authored against branch baseline `tim/PRCR-1159`.
- PRCR-1159 endpoint/contracts remain unchanged and are treated as prerequisite context.
- PRCR-1161 introduces a new read-only endpoint only; it does not alter PATCH review/determination behavior from PRCR-1159.

---

## Endpoint

`GET /compliance/projects/{projectId}/responses/{responseId}/checks/{checkId}/evidence`

### Auth and Access

- Requires valid JWT (`AuthGuard('jwt')`)
- Requires `compliance` permission (`PermissionsGuard` + `@Permissions('compliance')`)
- Access/ownership enforcement mirrors existing compliance endpoints (project ownership service check)

---

## Path Parameters

| Param | Type | Validation |
|---|---|---|
| `projectId` | UUID string | `ParseUUIDPipe` -> `400` if invalid UUID |
| `responseId` | UUID string | `ParseUUIDPipe` -> `400` if invalid UUID |
| `checkId` | UUID string | `ParseUUIDPipe` -> `400` if invalid UUID |

---

## Request Body

None.

---

## Response

HTTP `200 OK`

Returns all evidence rows for the check as a plain array (not wrapped), ordered by `created_at ASC`.

```ts
type ComplianceCheckEvidenceResponse = ComplianceCheckEvidenceDto[];

type ComplianceCheckEvidenceDto = {
  id: string;                  // UUID
  complianceCheckId: string;   // UUID (from compliance_check_id)
  responseDocumentId: string;  // UUID (from response_document_id)
  documentStartLine: number | null;
  documentEndLine: number | null;
  createdAt: string;           // ISO-8601 timestamp
};
```

### Empty State

If the project/response/check path is valid and no evidence exists, return:

- HTTP `200 OK`
- Body: `[]`

---

## Source Schema Mapping

`compliance_item_evidence` table fields (from `Database/rohan_api/scripts/sql/init_compliance.sql`):

- `id`
- `compliance_check_id`
- `response_document_id`
- `document_start_line`
- `document_end_line`
- `created_at`

API field mapping:

- `id` <- `id`
- `complianceCheckId` <- `compliance_check_id`
- `responseDocumentId` <- `response_document_id`
- `documentStartLine` <- `document_start_line`
- `documentEndLine` <- `document_end_line`
- `createdAt` <- `created_at`

---

## Validation and Business Rules

- UUID validation is enforced at controller boundary for all path params.
- Hierarchy checks are required:
  - response must belong to project
  - check must belong to response
- Query uses deterministic ordering: `created_at ASC`.
- Endpoint is read-only; no mutation of compliance checks, responses, or evidence rows.

---

## Error Responses

| HTTP | Condition | Format |
|---|---|---|
| `400 Bad Request` | Invalid UUID in path params | NestJS validation error response |
| `401 Unauthorized` | Missing/invalid JWT | Standard auth error response |
| `403 Forbidden` | User lacks `compliance` permission | Standard permissions error response |
| `404 Not Found` | Project inaccessible, response not in project, or check not in response | Compliance service not-found error message (mirrors existing endpoint patterns) |
| `500 Internal Server Error` | Unexpected retrieval failure | `{ "message": "Error retrieving compliance check evidence" }` |

---

## Changelog

- **Phase 2**: Backend error surface aligned in `compliance.errors.ts`: added `ComplianceErrors.getCheckEvidenceError` for 500 responses. Reused `ResponseNotFoundError` (response not in project) and `ComplianceCheckNotFoundError` (check not in response).
- **Phase 3**: Service method `getCheckEvidence(projectId, responseId, checkId, user)` added; DTO `ComplianceCheckEvidenceDto` in `dto/compliance-check-evidence.dto.ts`. Response shape unchanged from contract.
- **Phase 4**: GET route `GET /compliance/projects/:projectId/responses/:responseId/checks/:checkId/evidence` added; ParseUUIDPipe on all path params; Swagger 200/400/401/403/404/500.

---

## Unchanged Contracts

- No request-body DTOs are introduced for this endpoint.
- Existing compliance check write/read contracts remain unchanged.
- Existing PRCR-1159 PATCH contract remains unchanged:
  - `PATCH /compliance/projects/{projectId}/responses/{responseId}/checks/{checkId}`
