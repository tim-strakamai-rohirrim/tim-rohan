# PRCR-1159 Plan — Compliance Phase 2: Review/Approve a Compliance Check

## Problem Statement

The compliance check list endpoint (`GET .../checks`) already exposes `automatedStatus`, `userDetermination`, `userNotes`, `reviewer`, and `reviewedAt` fields on each `ComplianceCheck` record.
However there is no write path: users cannot record their own ruling on an LLM-generated determination, add notes, or have their sign-off timestamped.

This ticket adds:

```
PATCH /compliance/projects/{projectId}/responses/{responseId}/checks/{checkId}
```

which allows a user to:
1. Set or update `user_determination` (overriding or confirming the LLM's `automated_status`).
2. Set or update `user_notes`.
3. Have `reviewed_by` / `reviewed_at` stamped automatically when `user_determination` is provided.

---

## Assumptions

- No DB schema changes are required; all target columns already exist on `compliance_checks`.
- The response body of the PATCH mirrors `ComplianceCheckResponseDto` (the same shape returned by the GET list).
- `user_notes` may be set/updated independently of `user_determination` (the two fields are decoupled).
- Setting `user_determination` to a non-null value **always** stamps `reviewed_by` and `reviewed_at` to the current user/time — even if overwriting a previous determination.
- Setting `user_determination: null` **clears** `reviewed_by` and `reviewed_at` as well (full undo).
- Setting only `user_notes` (no `user_determination` key in the body) leaves `reviewed_by` / `reviewed_at` unchanged.
- **Only the project owner** may submit or update a ruling — enforced via the existing `ensureProjectOwnership(projectId, userEntity.user_id)` helper, consistent with all other compliance write endpoints.
- **Updates are blocked when the parent response is `approved`** (`ResponseStatus.APPROVED`) — the service throws a 409 Conflict in that case.
- Ownership/hierarchy check: the check must belong to the given `responseId`, and the response must belong to the given `projectId`; a mismatch returns 404.
- Auth/RBAC: same as all other compliance endpoints — `@Permissions('compliance')`.
- This ticket is **backend-only**; no Angular changes are in scope.

---

## Open Questions

None — all questions resolved.

---

## Ordered Checklist

### Phase 1 — DTO [BACKEND_DB]

- [ ] **1.1** Create `UpdateComplianceCheckDto` in
  `rohan_api-parent/rohan_api/src/compliance/dto/update-compliance-check.dto.ts`
  Fields (all optional):
  - `userDetermination?: UserDetermination | null`
  - `userNotes?: string | null`

### Phase 2 — Error constants [BACKEND_DB]

- [ ] **2.1** Add `ComplianceCheckNotFoundError` class to
  `rohan_api-parent/rohan_api/src/compliance/compliance.errors.ts`
  (HTTP 404, mirrors the pattern of `ComplianceItemNotFoundError`)

- [ ] **2.2** Add `ResponseApprovedError` class to the same file
  (HTTP 409 Conflict — blocks writes when the response is already approved)

- [ ] **2.3** Add static message strings to `ComplianceErrors`:
  - `checkNotFoundError`
  - `updateComplianceCheckError`
  - `responseApprovedError`

### Phase 3 — Service method [BACKEND_DB]

- [ ] **3.1** Add `updateComplianceCheck(projectId, responseId, checkId, dto, user)` to
  `rohan_api-parent/rohan_api/src/compliance/compliance.service.ts`

  Logic:
  1. Resolve `userEntity` from `user` (same `getUserEntity` call used across all service methods); throw `UserNotFoundError` if missing.
  2. Call `ensureProjectOwnership(projectId, userEntity.user_id)` — throws `ProjectNotFoundError` (→ 404) if project not found or user is not the owner.
  3. Load response with `responseRepository.findOne({ where: { id: responseId, project: { id: projectId } } })`; throw `ResponseNotFoundError` if missing.
  4. **Guard**: if `response.status === ResponseStatus.APPROVED` throw a new `ResponseApprovedError` (409 Conflict).
  5. Load `ComplianceCheck` by `id` where `response.id = responseId`; throw `ComplianceCheckNotFoundError` if missing.
  6. Apply field updates:
     - If `dto.userNotes !== undefined` → set `userNotes`.
     - If `dto.userDetermination !== undefined` → set `userDetermination`; if non-null also stamp `reviewer = userEntity` and `reviewedAt = new Date()`; if null also clear `reviewer = null` and `reviewedAt = null`.
  7. Save and return mapped `ComplianceCheckResponseDto` (same mapping as `getComplianceChecks`).

### Phase 4 — Controller route [BACKEND_DB]

- [ ] **4.1** Add `PATCH /projects/:projectId/responses/:responseId/checks/:checkId` handler to
  `rohan_api-parent/rohan_api/src/compliance/compliance.controller.ts`

  - `@ApiOkResponse({ type: ComplianceCheckResponseDto })`
  - `@ApiNotFoundResponse` for project / response / check not found
  - `@ApiBadRequestResponse` for UUID parse failures or invalid enum values
  - Delegates to `complianceService.updateComplianceCheck(...)`

### Phase 5 — Unit tests [TEST_REVIEW]

- [ ] **5.1** Add service unit tests in
  `rohan_api-parent/rohan_api/src/compliance/compliance.service.spec.ts`
  Scenarios:
  - Sets `userDetermination` + stamps reviewer/reviewedAt
  - Sets `userNotes` only — reviewer/reviewedAt unchanged
  - Clears `userDetermination` (null) — clears reviewer/reviewedAt
  - Throws 404 when check not found
  - Throws 404 when project/response mismatch
  - Throws 403 when caller is not the project owner
  - Throws 409 when response status is `approved`

- [ ] **5.2** Add controller unit tests in
  `rohan_api-parent/rohan_api/src/compliance/compliance.controller.spec.ts`
  Scenarios:
  - Delegates to service and returns result
  - Propagates 404 from service

### Phase 6 — E2E test [TEST_REVIEW]

- [ ] **6.1** Add E2E test in
  `rohan_api-parent/rohan_api/test/compliance.e2e-spec.ts`
  Scenarios:
  - `PATCH` with `userDetermination` → 200, reviewer/reviewedAt populated
  - `PATCH` with `userNotes` only → 200, determination/reviewer unchanged
  - `PATCH` with `userDetermination: null` → 200, reviewer/reviewedAt cleared
  - `PATCH` with unknown `checkId` → 404
  - `PATCH` with wrong `responseId` → 404
  - `PATCH` by a non-owner → 403 / 404 (depends on `ensureProjectOwnership` error surface)
  - `PATCH` when response is `approved` → 409
  - `PATCH` without JWT → 401

---

## Phase Order & Parallelism

| Phase | Files touched | Can run in parallel with |
|---|---|---|
| 1 — DTO | `dto/update-compliance-check.dto.ts` (new file) | Phases 2 (different file) |
| 2 — Errors | `compliance.errors.ts` | Phase 1 |
| 3 — Service | `compliance.service.ts` | Depends on Phases 1 & 2 |
| 4 — Controller | `compliance.controller.ts` | Can start alongside Phase 3; needs DTO from Phase 1 |
| 5 — Unit tests | `*.spec.ts` files | Can be written alongside Phases 3 & 4 |
| 6 — E2E tests | `test/compliance.e2e-spec.ts` | Depends on Phases 3 & 4 being complete |

**Recommended sequential order if done one phase at a time:**
1 → 2 → 3 → 4 → 5 → 6

Phases 1 and 2 touch different files and can be done in parallel.
Phases 3 and 4 both depend on Phase 1 (DTO) and Phase 2 (errors); they share no overlapping lines once the imports are established and can be reviewed independently.
Tests (Phases 5–6) should be the last PR step to allow sign-off on the implementation shape first.

---

## Files to Touch

| File | Change |
|---|---|
| `src/compliance/dto/update-compliance-check.dto.ts` | **Create** new DTO |
| `src/compliance/compliance.errors.ts` | Add `ComplianceCheckNotFoundError` + `ResponseApprovedError` classes + 3 static strings |
| `src/compliance/compliance.service.ts` | Add `updateComplianceCheck` method |
| `src/compliance/compliance.controller.ts` | Add `PATCH .../checks/:checkId` handler |
| `src/compliance/compliance.service.spec.ts` | Add unit test cases |
| `src/compliance/compliance.controller.spec.ts` | Add unit test cases |
| `test/compliance.e2e-spec.ts` | Add E2E scenarios |

No DB migration required.
No Angular changes in scope.
