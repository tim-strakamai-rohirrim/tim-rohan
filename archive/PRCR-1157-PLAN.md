# PRCR-1157 Plan: GET /compliance/projects/:projectId/responses/:responseId/checks

> **Status**: FINAL — ready for implementation.

---

## Problem Statement

The compliance module allows vendors' responses to be checked against a compliance list. Each `compliance_check` row records whether a response passed or failed a single compliance list item (`automated_status`) and the human reviewer's determination (`user_determination`).

Currently there is no dedicated endpoint to retrieve all compliance checks for a given response. The data is embedded inside `GET /compliance/projects/:projectId/responses/:responseId`, but a focused endpoint is needed for the compliance review UI.

---

## Assumptions

1. **Backend only** — no Angular UI changes in this ticket.
2. **No pagination** — responses have a bounded number of compliance items; a flat list is returned.
3. **No filtering** — return all checks for the response.
4. **Full `complianceItem` fields** are included per check (title, text, lineItemNumber, outlineNumber, sectionName, status).
5. **Evidence is excluded** — a separate dedicated endpoint will serve evidence (future ticket).
6. **Reviewer** is `ComplianceUserRefDto` `{ id, email }` (matching existing pattern), nullable.
7. `complianceCheckRepository` is already injected in `ComplianceService` (line 77). No new module imports needed.

---

## Ordered Implementation Checklist

### Phase 1 — DTO `[BACKEND_DB]`

**Files touched:**
- `rohan_api-parent/rohan_api/src/compliance/dto/compliance-check-response.dto.ts` *(new file)*

**Steps:**
- [ ] 1.1 `[BACKEND_DB]` Create `compliance-check-response.dto.ts` with three classes:
  - `ComplianceCheckItemRefDto` — id, complianceItemTitle, complianceItemText, lineItemNumber, outlineNumber, sectionName, status
  - `ComplianceCheckResponseDto` — id, automatedStatus, userDetermination, userNotes, reviewer (`ComplianceUserRefDto | null`), reviewedAt, createdAt, updatedAt, complianceItem (`ComplianceCheckItemRefDto`)
  - All fields decorated with `@ApiProperty` / `@ApiPropertyOptional`

> No changes to existing files — safe to do in isolation.

---

### Phase 2 — Service method `[BACKEND_DB]`

**Files touched:**
- `rohan_api-parent/rohan_api/src/compliance/compliance.service.ts`

**Steps:**
- [ ] 2.1 `[BACKEND_DB]` Add `getComplianceChecks(projectId: string, responseId: string, user: RequestUser): Promise<ComplianceCheck[]>` to `ComplianceService`:
  1. `getUserEntity(user)` → throw `UserNotFoundError` if not found
  2. `responseRepository.findOne({ where: { id: responseId, project: { id: projectId } }, relations: ['project'] })` → throw `ResponseNotFoundError` if null
  3. `ensureProjectOwnership(response.project, userEntity)` → throws if not authorized
  4. `complianceCheckRepository.find({ where: { response: { id: responseId } }, relations: ['complianceItem', 'reviewer'] })`
  5. Return the array
  6. Catch and rethrow `UserNotFoundError`, `ResponseNotFoundError`; wrap unknowns in `ComplianceError`

> Only additive — existing methods are untouched.

---

### Phase 3 — Controller endpoint `[BACKEND_DB]`

**Files touched:**
- `rohan_api-parent/rohan_api/src/compliance/compliance.controller.ts`

**Steps:**
- [ ] 3.1 `[BACKEND_DB]` Add handler after the existing `getResponseById` route:
  ```
  @Get('/projects/:projectId/responses/:responseId/checks')
  ```
  - `@ApiOperation`, `@ApiParam` for both `projectId` and `responseId`
  - `@ApiOkResponse({ type: ComplianceCheckResponseDto, isArray: true })`
  - Standard 401, 403, 404, 500 decorators
  - Both params through `new ParseUUIDPipe()`
  - Delegate to `complianceService.getComplianceChecks(projectId, responseId, user)`

> Only additive — existing routes are untouched.

---

### Phase 4 — Unit Tests `[TEST_REVIEW]`

**Files touched:**
- `rohan_api-parent/rohan_api/src/compliance/compliance.service.spec.ts` *(existing or new)*

**Steps:**
- [ ] 4.1 `[TEST_REVIEW]` Unit tests for `getComplianceChecks`:
  - Happy path: returns array of `ComplianceCheck` with relations
  - Response not found (wrong responseId or wrong projectId) → `ResponseNotFoundError`
  - User not found → `UserNotFoundError`
  - User does not own project → `ResponseNotFoundError`
  - DB error → `ComplianceError`

---

### Phase 5 — E2E Test `[TEST_REVIEW]`

**Files touched:**
- `rohan_api-parent/rohan_api/test/compliance.e2e-spec.ts` *(existing or new)*

**Steps:**
- [ ] 5.1 `[TEST_REVIEW]` E2E test:
  - Authenticated user with `compliance` permission fetches checks for a seeded response → 200, array of `ComplianceCheckResponseDto`
  - Unknown `responseId` → 404
  - Wrong `projectId` for a valid `responseId` → 404
  - Unauthenticated request → 401

---

## Phase Order and Parallelism

| Phase | Files touched | Depends on | Can parallelize with |
|-------|--------------|------------|----------------------|
| 1 — DTO | `dto/compliance-check-response.dto.ts` (new) | — | Nothing blocks it; start immediately |
| 2 — Service | `compliance.service.ts` | Phase 1 (imports DTO types) | — |
| 3 — Controller | `compliance.controller.ts` | Phase 1 + 2 | Phase 4 once Phase 2 is done |
| 4 — Unit tests | `*.spec.ts` | Phase 2 | Phase 3 |
| 5 — E2E tests | `*.e2e-spec.ts` | Phase 3 | — |

**Recommended order**: 1 → 2 → (3 ‖ 4) → 5

---

## No Database Changes Required

`compliance_checks` and `compliance_item_evidence` tables already exist with all required columns and relations. No SQL scripts needed.
