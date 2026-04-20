#### Summary

- The compliance check list endpoint was read-only; this PR adds the write path so users can record a human determination on each compliance check.
- Adds `PATCH /compliance/projects/:projectId/responses/:responseId/checks/:checkId` — updates `userDetermination` and/or `userNotes`, and automatically stamps `reviewedBy` / `reviewedAt` when a determination is set (or clears them when set to `null`).
- No schema changes required; all columns (`user_determination`, `user_notes`, `reviewed_by`, `reviewed_at`) already exist on the `compliance_checks` table.

---

#### Technical Details

- Frontend:
  - No frontend changes — backend-only feature.

- Backend:
  - **New DTO** `UpdateComplianceCheckDto` (`src/compliance/dto/update-compliance-check.dto.ts`): both `userDetermination` and `userNotes` are optional/nullable; enum validation via `@IsEnum(UserDetermination)`.
  - **New errors** (`src/compliance/compliance.errors.ts`): `ComplianceCheckNotFoundError` (404) and `ResponseApprovedError` (409) added alongside three static message strings.
  - **New service method** `updateComplianceCheck` (`src/compliance/compliance.service.ts`):
    1. Verifies caller owns the project (`ensureProjectOwnership`).
    2. Guards: 404 if response not found under project; 409 if response status is `APPROVED`.
    3. 404 if check not found under response.
    4. Field update logic — setting `userDetermination` to a non-null value stamps reviewer + timestamp; setting to `null` clears both; updating `userNotes` alone leaves reviewer/timestamp unchanged.
  - **New controller route** `@Patch('/projects/:projectId/responses/:responseId/checks/:checkId')` (`src/compliance/compliance.controller.ts`) — guarded by `@Permissions('compliance')` + JWT; full Swagger annotations for all response codes.

- Database:
  - No migrations. All columns already exist on `compliance_checks`.

- Contracts:
  - **Request body** (`UpdateComplianceCheckDto`): `userDetermination?: 'compliant' | 'non_compliant' | 'not_applicable' | null`, `userNotes?: string | null`. At least one field should be present (validated at runtime via service logic).
  - **Success response** (200): `ComplianceCheckResponseDto` — same shape as the GET list items; includes populated `reviewer` + `reviewedAt` when a determination is set.
  - **Error codes**: 400 (invalid UUID or enum value), 401 (missing/invalid JWT), 403 (no `compliance` permission or not project owner), 404 (project / response / check not found), 409 (parent response is `approved`).
  - Path params all use `ParseUUIDPipe`.

---

#### Testing

- Manual:
  - PATCH with `userDetermination: "compliant"` — verify 200, `reviewer` and `reviewedAt` populated in response.
  - PATCH with `userDetermination: null` — verify reviewer and reviewedAt cleared.
  - PATCH with only `userNotes` — verify determination/reviewer/reviewedAt unchanged.
  - PATCH on an approved response — verify 409.
  - PATCH with a non-owner JWT — verify 403.
  - PATCH with missing JWT — verify 401.

- Automated:
  - **Jest (unit)**:
    - `src/compliance/compliance.service.spec.ts` — 7 new cases: happy-path determination set, notes-only update, null-clear, check-not-found (404), response-not-found (404), non-owner (403), approved-response (409).
    - `src/compliance/compliance.controller.spec.ts` — 3 new cases: delegates to service, propagates `ComplianceCheckNotFoundError`, propagates `ResponseNotFoundError`.
  - **Playwright / E2E**:
    - `test/compliance.e2e-spec.ts` — 10 new scenarios covering all happy paths and all documented error codes (400 bad UUID, 400 bad enum, 401, 403 permission, 403 ownership, 404 check, 404 response, 409 approved). Test setup seeds data directly via repository since no public POST /checks endpoint exists.

- Known gaps / TODO:
  - No test for concurrent PATCH requests on the same check.
  - No load/performance test added.

---

#### Risks & Impact

- **No breaking changes** — new endpoint only; existing GET routes unchanged.
- **No DB migration** — zero risk of table-lock or rollback complexity.
- The 409 guard prevents writes to approved responses; any client calling this endpoint on an approved response will receive a clear error rather than silently succeeding — downstream UI must handle this code when it is built.
- `ensureProjectOwnership` is reused from the existing compliance module; behaviour is consistent with all other compliance endpoints.

---

#### Verification Steps for Reviewers

1. Check out the branch and run `npm run start:dev`; hit `GET /docs` to confirm the new `PATCH` endpoint appears in Swagger with correct request/response schemas.
2. Obtain a valid JWT for a user with `compliance` permission and project ownership; send:
   ```
   PATCH /compliance/projects/{projectId}/responses/{responseId}/checks/{checkId}
   { "userDetermination": "compliant" }
   ```
   Confirm 200 with `reviewer` and `reviewedAt` populated.
3. Repeat the PATCH with `{ "userDetermination": null }` — confirm both fields are cleared.
4. Swap to a JWT for a user without `compliance` permission — confirm 403.
5. Find or create a response with status `approved`; attempt the PATCH — confirm 409.
6. Run unit tests: `npm run test -- src/compliance/compliance.service.spec.ts src/compliance/compliance.controller.spec.ts`
7. Run E2E tests: `npm run test:e2e:ci -- --testPathPattern compliance`
