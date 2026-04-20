# PRCR-1033: Testing/Review handoff (Steps 1–17)

**Date:** 2026-02-18  
**Agent:** Testing/Reviewer

---

## Scope reviewed

- **Plan items:** Steps 1–17 (contracts, Swagger decorators for projects CRUD, MinIO uploads, compliance-items CRUD).
- **Files reviewed:**
  - `PRCR-1033-PLAN.md`, `PRCR-1033-contracts.md`
  - `rohan_api-parent/rohan_api-PRCR-1033/src/compliance/compliance.controller.ts`
  - `rohan_api-parent/rohan_api-PRCR-1033/src/compliance/dto/create-compliance-project.dto.ts`
  - `rohan_api-parent/rohan_api-PRCR-1033/src/compliance/dto/update-compliance-project.dto.ts`
  - `rohan_api-parent/rohan_api-PRCR-1033/src/compliance/dto/set-project-status.dto.ts`
  - `rohan_api-parent/rohan_api-PRCR-1033/src/compliance/dto/create-compliance-item.dto.ts`
  - `rohan_api-parent/rohan_api-PRCR-1033/src/compliance/dto/update-compliance-item.dto.ts`
  - `rohan_api-parent/rohan_api-PRCR-1033/src/compliance/dto/compliance-project-response.dto.ts`
  - `rohan_api-parent/rohan_api-PRCR-1033/src/compliance/dto/upload-document-result.dto.ts`
  - Existing specs: `compliance.controller.spec.ts`, `compliance.service.spec.ts`, DTO specs.

---

## Review notes

- **Alignment with plan/contracts:** Controller routes, params, and response/error decorators match the contracts. DTOs align with documented request/response shapes (CreateComplianceProjectDto, UpdateComplianceProjectDto, SetProjectStatusDto, CreateComplianceItemDto, UpdateComplianceItemDto; ComplianceProjectSummaryDto, ComplianceProjectDetailDto; UploadSourceDocumentResultDto, UploadResponseDocumentResultDto).
- **Path consistency:** `PUT /projects/:id` was missing a leading slash; updated to `@Put('/projects/:id')` to match other routes and the plan.
- **Optional @ApiTags:** Step 2 is satisfied by NestJS auto-tagging (ComplianceController → tag "Compliance"); no code change required.
- **Upload responses:** Plan allows 200 or 201; controller uses `@ApiOkResponse` for both upload endpoints. Contracts allow "200 OK or 201 Created"; no change made.
- **UpdateComplianceProjectDto.projectOwnerId:** Contracts table lists type "string" for PATCH; DTO has `projectOwnerId?: string`. Service assigns it to `user_id` (typically number). If the API expects a numeric owner ID, consider aligning DTO/contract to number or parsing before use.

---

## Test updates

| File | Change |
|------|--------|
| `src/compliance/compliance.controller.ts` | Path fix: `@Put('projects/:id')` → `@Put('/projects/:id')`. |
| `src/compliance/compliance.controller.spec.ts` | Added tests for: **getProjects**, **getProjectById**, **createProject**, **updateProject**, **deleteProject**, **setProjectStatus**, **uploadSourceDocument** (success + 400 when no file), **uploadResponseDocument** (success + 400 when no file). All named by route/step (e.g. "getProjects (GET /projects)"). |
| `src/compliance/compliance.service.spec.ts` | Added **AdminService** mock (`getSerialFromIdpId`). New describe blocks: **getProjects** (success + ComplianceError on getSerialFromIdpId failure), **getProjectById** (success + ProjectNotFoundError), **createProject** (success), **deleteProject** (success when archived + ProjectNotFoundError + ProjectStatusError when not archived), **updateProject** (success + ProjectNotFoundError), **setProjectStatus** (success + ProjectNotFoundError + UserNotFoundError). |
| `src/compliance/dto/compliance-project-response.dto.spec.ts` | No change (existing shape tests sufficient). |
| `src/compliance/dto/upload-document-result.dto.spec.ts` | No change (existing shape tests sufficient). |

**Frontend (Karma/Jasmine, Playwright):** No frontend changes were in scope for steps 1–17 (backend Swagger/contracts only). E2E for compliance routes can be added when UI is implemented (step 19 / frontend phase).

---

## Issues

1. **UpdateComplianceProjectDto.projectOwnerId:** Resolved — service now parses string to number with `Number()` and only sets `projectOwner` when the result is an integer (DTO/contract remain string).
2. **Swagger UI verification (Step 18):** Not executed in this run. Recommend manual check at `/docs` for all Compliance routes, file upload bodies, and response codes before handoff to frontend.
3. **No integration/e2e for API:** Only unit tests were added. Consider integration tests against a test DB for critical paths (e.g. create project → set status → delete when archived) if not already covered elsewhere.

---

## Next owner

- **Next phase:** [PLANNER] or [TEST_REVIEW] for **Step 18** (verify Swagger UI at `/docs`, update contracts if needed) and **Step 19** (share contracts + Swagger URL with frontend).

---

## Definition of done checklist

- [x] Tests exist and are clearly named for the completed plan steps reviewed (4–11, 13–17; controller + service).
- [x] Serious issues either fixed (PUT path) or called out in Review notes / Issues.
- [x] Handoff summary (this document) with Scope, Test updates, Issues, Next owner.
