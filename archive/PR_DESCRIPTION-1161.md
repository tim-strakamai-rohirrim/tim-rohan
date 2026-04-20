# Pull Request Description

#### Summary

- Adds a read-only endpoint so the client can retrieve which response-document segments were used as evidence for a given compliance check (LLM determination).
- Implements `GET /compliance/projects/:projectId/responses/:responseId/checks/:checkId/evidence` returning all `compliance_item_evidence` rows for the check, ordered by `created_at ASC`, with proper project/response/check hierarchy validation and existing auth/RBAC.
- Reuses existing compliance error types and service patterns; no DB migration or frontend changes in this PR.

#### Technical Details

- **Frontend:**  
  - None. Backend-only change; UI will consume this endpoint in a separate implementation.

- **Backend:**
  - **New endpoint:** `GET /compliance/projects/:projectId/responses/:responseId/checks/:checkId/evidence`. Path params validated with `ParseUUIDPipe` (400 on invalid UUID). JWT + `@Permissions('compliance')` and project-ownership enforcement via existing compliance service flow.
  - **Service:** `getCheckEvidence(projectId, responseId, checkId, user)` — ensures user/project ownership, loads response in project scope, loads check in response scope, then queries `compliance_item_evidence` by `compliance_check_id` with `innerJoin` to `ComplianceResponseDocument` scoped to the same response; orders by `evidence.created_at ASC`; maps entities to DTO; returns array (empty when no rows). Evidence rows whose `responseDocument` is missing (e.g. orphaned) are filtered out before mapping.
  - **Errors:** Reuses `ResponseNotFoundError` (response not in project) and `ComplianceCheckNotFoundError` (check not in response); adds `ComplianceErrors.getCheckEvidenceError` for 500. `ProjectNotFoundError` from ownership check is rethrown as `ResponseNotFoundError` for consistent 404 surface.
  - **DTO:** New `ComplianceCheckEvidenceDto` in `dto/compliance-check-evidence.dto.ts` (id, complianceCheckId, responseDocumentId, documentStartLine, documentEndLine, createdAt). Swagger decorators on the GET route for 200/400/401/403/404/500.

- **Database:**  
  - No schema changes. Uses existing `compliance_item_evidence` table and `ComplianceItemEvidence` entity.

- **Contracts:**
  - Response: `200 OK` with a plain array of `ComplianceCheckEvidenceDto` (or `[]` when no evidence). No request body. 400 for invalid path UUIDs; 401/403 for auth/permission; 404 for project inaccessible, response not in project, or check not in response; 500 with message `"Error retrieving compliance check evidence"` on unexpected failure.

#### Testing

- **Manual:**
  - Call `GET .../evidence` with valid project/response/check (with and without evidence rows); invalid UUID; missing JWT; token without compliance permission; token without resource access; non-existent response in project; non-existent check in response. Confirm 200 + array, 200 + `[]`, 400, 401, 403, 404 as appropriate.
- **Automated:**
  - **Jest (service):** `getCheckEvidence` — returns evidence in ascending `created_at` order; returns `[]` when no rows; throws `ResponseNotFoundError` when response not in project; throws `ComplianceCheckNotFoundError` when check not in response; propagates `UserNotFoundError`; uses ownership flow (project lookup); filters out evidence rows with missing `responseDocument.id` and still returns remaining rows.
  - **Jest (controller):** `getCheckEvidence` — delegates with parsed UUID params and returns service array unchanged; returns empty array when service returns `[]`; propagates `ResponseNotFoundError` and `ComplianceCheckNotFoundError`.
  - **Playwright/E2E (compliance):** New `GET .../evidence` scenarios — 200 with array when evidence exists (and ordering); 200 with `[]` when no evidence; 400 for invalid `checkId` UUID; 401 without JWT; 403 for no compliance permission and for no resource access; 404 when response not in project and when check not in response.
- **Known gaps / TODO:**  
  - None. E2E does not explicitly assert 500 (unexpected server error); acceptable for this read-only endpoint.

#### Risks & Impact

- **Breaking changes:** None. New endpoint only.
- **Performance:** Single query with joins and `ORDER BY created_at`; evidence rows per check are expected to be small. No new N+1.
- **Security:** Same as existing compliance endpoints: JWT, compliance permission, and project ownership enforced before any DB read. Evidence is scoped to the check, which is already validated to belong to the response and project.
- **Migration/rollout:** None. No DB migration; frontend can adopt the endpoint when ready.

#### Verification Steps for Reviewers

1. Run unit tests: `npm run test -- src/compliance/compliance.service.spec.ts src/compliance/compliance.controller.spec.ts` and confirm all pass.
2. Run compliance E2E: `npm run test:e2e:ci -- test/compliance.e2e-spec.ts` (or equivalent) and confirm the new `GET .../evidence` describe block passes.
3. Start the API and, with a JWT that has compliance permission and project access, call `GET /compliance/projects/{projectId}/responses/{responseId}/checks/{checkId}/evidence` for a check that has evidence — expect 200 and an array of objects with `id`, `complianceCheckId`, `responseDocumentId`, `documentStartLine`, `documentEndLine`, `createdAt`. Repeat for a check with no evidence — expect 200 and `[]`.
4. Repeat the same URL with an invalid `checkId` (e.g. `not-a-uuid`) — expect 400; without `Authorization` header — expect 401; with a token without compliance permission — expect 403; with a non-existent `responseId` or `checkId` in scope — expect 404.
5. Optionally check Swagger at `/api` (or your docs path) and confirm the new GET route and response/error schemas are documented.
