#### Summary

- Adds a new read-only endpoint `GET /compliance/projects/:projectId/responses/:responseId/checks` that returns all compliance checks for a given response, with their associated compliance item details (evidence excluded).
- Closes a gap where clients had no way to fetch check-level status and reviewer metadata for a compliance response without loading heavier, unrelated data.

#### Technical Details

- Backend:
  - **New endpoint**: `GET /compliance/projects/:projectId/responses/:responseId/checks` in `ComplianceController`. Both path params are validated as UUIDs via `ParseUUIDPipe`; the endpoint is fully decorated with Swagger (`@ApiOkResponse`, `@ApiNotFoundResponse`, etc.).
  - **New service method** `getComplianceChecks()` in `ComplianceService`:
    1. Resolves the requesting user via `getUserEntity`.
    2. Fetches the `ComplianceResponse` joined to its `project`, confirming the `responseId`/`projectId` combination is valid before proceeding.
    3. Calls `ensureProjectOwnership` to confirm the caller owns the project (surfaced as 404 to avoid leaking existence).
    4. Queries `ComplianceCheck` with `relations: ['complianceItem', 'reviewer']`.
    5. Maps raw entities to `ComplianceCheckResponseDto`, deliberately projecting only `user_id`, `name`, and `email` from the reviewer to avoid over-exposing user data.
  - **Error handling**: `UserNotFoundError` and `ResponseNotFoundError` are re-thrown as-is; `ProjectNotFoundError` is converted to `ResponseNotFoundError` (consistent 404 surface); all other errors become `ComplianceError` (500).
  - **New error constant**: `ComplianceErrors.getComplianceChecksError`.

- Contracts:
  - **New DTOs** in `src/compliance/dto/compliance-check-response.dto.ts`:
    - `ComplianceCheckItemRefDto` — subset of `ComplianceItem` fields (no evidence, no raw FK columns).
    - `ComplianceCheckResponseDto` — check fields (`automatedStatus`, `userDetermination`, `userNotes`, `reviewer`, `reviewedAt`, timestamps) plus the embedded `complianceItem`.
  - `reviewer` is typed as the existing `ComplianceUserRefDto` (`user_id`, `name`, `email`), reused from `compliance-project-response.dto.ts`.
  - No request body; no pagination or filtering in this iteration.

#### Testing

- Manual:
  - TODO: Verify the happy path via Swagger UI (`/api`) against a staging or local environment with real check data.
- Automated:
  - [Jest]: 8 new unit test cases added to `compliance.service.spec.ts` under `describe('getComplianceChecks')`:
    - Happy path with checks present.
    - Empty array when no checks exist.
    - `UserNotFoundError` when user lookup returns null.
    - `ResponseNotFoundError` for unknown `responseId`.
    - `ResponseNotFoundError` when `projectId`/`responseId` mismatch.
    - `ResponseNotFoundError` when user does not own the project.
    - `ComplianceError` on unexpected DB error.
    - Reviewer fields correctly mapped to `ComplianceUserRefDto` shape when reviewer is non-null.
  - [E2E / Integration]: 6 new cases added to `test/compliance.e2e-spec.ts`:
    - 200 + array for a valid response with no checks yet.
    - 404 for unknown `responseId`.
    - 404 when `projectId` does not match the response.
    - 401 for unauthenticated request.
    - 400 for non-UUID `responseId`.
    - 403 for token without `compliance` permission.
- Known gaps / TODO:
  - No test covering a response that actually has checks (E2E). Seeding check data would require uploading and processing a document; deferred.
  - No test for 404 when `projectId` is a valid UUID but belongs to a different user (non-admin path).

#### Risks & Impact

- Read-only endpoint; no writes, no migrations, no schema changes.
- `ensureProjectOwnership` converts `ProjectNotFoundError` → 404 rather than 403, consistent with other endpoints in this service — intentional to avoid leaking project existence.
- Reviewer data is deliberately minimised (3 fields only); if the `ComplianceUserRefDto` shape ever changes, this endpoint inherits that change automatically.

#### Verification Steps for Reviewers

1. Check out the branch and run `npm run start:dev` in `rohan_api-parent/rohan_api`.
2. Open the Swagger UI and authenticate with an admin JWT.
3. Create a compliance project and a response via the existing POST endpoints.
4. Call `GET /compliance/projects/{projectId}/responses/{responseId}/checks` — expect `200 []`.
5. Swap in a random UUID for `responseId` — expect `404`.
6. Swap in a valid `responseId` but a mismatched `projectId` — expect `404`.
7. Call the endpoint with no `Authorization` header — expect `401`.
8. Call with a token that lacks the `compliance` permission — expect `403`.
9. Run unit tests: `npm run test -- src/compliance/compliance.service.spec.ts`.
10. Run E2E tests: `npm run test:e2e:ci` and confirm the new `getComplianceChecks` describe block passes.
