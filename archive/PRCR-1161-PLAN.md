# PRCR-1161 Plan - Compliance Phase 2: Retrieve Compliance Check Evidence

## Problem Statement

The compliance workflow needs a read endpoint so the client can show users exactly which response-document segments were used as evidence for an LLM compliance determination.

This ticket adds:

`GET /compliance/projects/{projectId}/responses/{responseId}/checks/{checkId}/evidence`

The endpoint returns all `compliance_item_evidence` rows for the specified check, ordered by `created_at ASC`, so the UI can render evidence context in a stable order.

---

## Assumptions

- Scope is backend-only. No Angular code changes are required in this ticket.
- `compliance_item_evidence` schema already exists; no migration is needed.
- Implementation branch for this ticket is based on `tim/PRCR-1159` (not `main`).
- PRCR-1161 should reuse compliance error/service/controller patterns introduced in PRCR-1159 rather than duplicating classes/messages.
- Endpoint auth/authorization mirrors existing compliance endpoints:
  - JWT auth
  - `@Permissions('compliance')`
  - project ownership enforcement via existing service pattern
- Hierarchy must be validated:
  - response belongs to project
  - check belongs to response
- If a valid check has no evidence rows, API returns `200` with `[]`.

---

## Open Questions

- None at this time.

---

## Cross-Ticket Dependency Note

- **Base branch**: `tim/PRCR-1159`
- **Dependency expectation**: PRCR-1159 changes are treated as available foundation for PRCR-1161 implementation.
- **Conflict-avoidance rule**:
  - Prefer extending existing `compliance.errors.ts` entries added in PRCR-1159.
  - Keep new service/controller additions in separate methods/routes without refactoring PRCR-1159 behavior.
  - Add tests for evidence retrieval without rewriting PRCR-1159 test cases.
- **Planned merge target flow**:
  1. Merge PRCR-1159
  2. Rebase/validate PRCR-1161 if needed
  3. Merge PRCR-1161

---

## Ordered Checklist

### Phase 1 - Contract Lock [BACKEND_DB]

- [ ] **1.1** Create and lock shared contract doc for request/response/error behavior.
  - File: `PRCR-1161-contracts.md`

### Phase 2 - Error Surface Alignment [BACKEND_DB]

- [ ] **2.1** Add or reuse compliance error classes/messages for:
  - response not found in project scope
  - check not found in response scope
  - generic evidence retrieval failure
  - File: `rohan_api-parent/rohan_api/src/compliance/compliance.errors.ts`

### Phase 3 - Service Method [BACKEND_DB]

- [ ] **3.1** Implement service method to retrieve evidence rows:
  - validate user and project ownership via existing helper flow
  - load response within project scope
  - load check within response scope
  - query `compliance_item_evidence` by `compliance_check_id`
  - apply `created_at ASC` order
  - map DB entity rows to response DTO shape
  - return array, including empty array when no rows
  - Files:
    - `rohan_api-parent/rohan_api/src/compliance/compliance.service.ts`
    - `rohan_api-parent/rohan_api/src/compliance/entities/compliance-item-evidence.entity.ts` (reuse, no schema edits)

### Phase 4 - Controller Route [BACKEND_DB]

- [ ] **4.1** Add GET route for evidence retrieval under compliance controller:
  - `GET /projects/:projectId/responses/:responseId/checks/:checkId/evidence`
  - path UUID validation with `ParseUUIDPipe`
  - swagger response annotations for 200/400/401/403/404/500
  - delegate to service method
  - File: `rohan_api-parent/rohan_api/src/compliance/compliance.controller.ts`

### Phase 5 - Tests [TEST_REVIEW]

- [ ] **5.1** Add service unit tests:
  - returns evidence rows in ascending `created_at` order
  - returns `[]` when no rows exist
  - throws not found on response/project mismatch
  - throws not found on check/response mismatch
  - honors ownership/auth flow as currently enforced in compliance service
  - File: `rohan_api-parent/rohan_api/src/compliance/compliance.service.spec.ts`

- [ ] **5.2** Add controller unit tests:
  - delegates with parsed UUID params
  - returns service array payload unchanged
  - propagates service exceptions
  - File: `rohan_api-parent/rohan_api/src/compliance/compliance.controller.spec.ts`

- [ ] **5.3** Add compliance e2e scenarios:
  - success with populated evidence array
  - success with empty array
  - invalid UUID -> 400
  - missing auth -> 401
  - no permission -> 403
  - response/check not found in scope -> 404
  - File: `rohan_api-parent/rohan_api/test/compliance.e2e-spec.ts`

### Phase 6 - Frontend Impact Acknowledgement [FRONTEND]

- [ ] **6.1** Confirm no code changes are needed in this ticket; frontend consumes endpoint in a separate implementation ticket/PR.
  - Files: none (documentation-only acknowledgment in planning artifacts)

---

## Phase Order and Parallelism

### Files touched by phase

- **Phase 1**: `PRCR-1161-contracts.md`
- **Phase 2**: `src/compliance/compliance.errors.ts`
- **Phase 3**: `src/compliance/compliance.service.ts` (+ evidence entity read usage)
- **Phase 4**: `src/compliance/compliance.controller.ts`
- **Phase 5**: compliance `*.spec.ts` and `test/compliance.e2e-spec.ts`
- **Phase 6**: no application files

### Parallel-safe phases (no file conflicts)

- Phase 1 should run first (contract baseline).
- After Phase 1:
  - Phase 2 can start immediately.
  - Test scaffolding in Phase 5 can begin in parallel for controller/service describe blocks.
- Phase 3 and Phase 4 should be sequenced to avoid interface churn (service first, then controller wiring).
- Remaining test assertions in Phase 5 should complete after Phases 3 and 4 stabilize.

### Recommended sequential order

`1 -> 2 -> 3 -> 4 -> 5 -> 6`

Rationale: lock contract first, align backend errors, implement service logic before controller exposure, then finalize tests against stable endpoint behavior.

Given the base branch strategy, PRCR-1161 implementation should assume PRCR-1159 code is already present and build incrementally on top of it.

---

## Files to Touch

- `PRCR-1161-PLAN.md`
- `PRCR-1161-contracts.md`
- `rohan_api-parent/rohan_api/src/compliance/compliance.errors.ts`
- `rohan_api-parent/rohan_api/src/compliance/compliance.service.ts`
- `rohan_api-parent/rohan_api/src/compliance/compliance.controller.ts`
- `rohan_api-parent/rohan_api/src/compliance/compliance.service.spec.ts`
- `rohan_api-parent/rohan_api/src/compliance/compliance.controller.spec.ts`
- `rohan_api-parent/rohan_api/test/compliance.e2e-spec.ts`

No DB migration required.
No frontend code changes in this ticket.
