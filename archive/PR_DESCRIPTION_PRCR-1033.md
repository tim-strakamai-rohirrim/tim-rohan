# PR Description: PRCR-1033

#### Summary

- Adds a full **Swagger/OpenAPI spec** for the Compliance API so the frontend has a single, authoritative reference for routes, request/response shapes, and error codes.
- Introduces **explicit response DTOs** for project list/detail and document uploads (`ComplianceProjectSummaryDto`, `ComplianceProjectDetailDto`, `UploadSourceDocumentResultDto`, `UploadResponseDocumentResultDto`) and wires them into `@ApiOkResponse` / `@ApiCreatedResponse` for accurate schema generation.
- Documents **projects CRUD**, **PUT set status**, **MinIO uploads** (source + response document), and **compliance-items CRUD** with `@ApiOperation`, `@ApiParam`, `@ApiBody`, and standard error decorators (401, 403, 404, 409, 500; 400 where applicable).

#### Technical Details

- **Frontend:**  
  - No frontend changes in this PR.

- **Backend:**
  - **Compliance controller:** Swagger decorators added for all in-scope routes: `GET/POST/PATCH/DELETE/PUT /compliance/projects`, `POST .../documents` and `POST .../responses/:response_id/documents`, and `GET/POST/PATCH/DELETE /compliance/projects/:id/compliance-items` (and GET by itemId). Route path fix: `PUT` uses `@Put('/projects/:id')` for consistency. Upload endpoints use `@ApiConsumes('multipart/form-data')` and `@ApiBody({ schema: { type: 'string', format: 'binary' } })` so Swagger UI shows a file input. All routes document 401/403/500; 404 and 409 (delete when not archived) where applicable.
  - **Response DTOs:** New `compliance-project-response.dto.ts` with `ComplianceProjectSummaryDto`, `ComplianceProjectDetailDto`, and nested DTOs for documents, responses, compliance checks, evidence. New `upload-document-result.dto.ts` with `UploadSourceDocumentResultDto` and `UploadResponseDocumentResultDto`.
  - **Request DTOs:** `CreateComplianceProjectDto`, `UpdateComplianceProjectDto`, `SetProjectStatusDto`, `CreateComplianceItemDto`, `UpdateComplianceItemDto` updated with `@ApiProperty` / `@ApiPropertyOptional` only where needed for Swagger (e.g. enums, descriptions); NestJS Swagger CLI plugin infers the rest.
  - **Service:** `updateProject` parses `projectOwnerId` from string to number via `Number()` and only sets `projectOwner` when the result is an integer; DTO/contract remain string for the API.
  - **Auto-tagging (same branch):** New endpoint `POST /compliance/projects/:id/documents/process` and `ComplianceService.requestAutoTagging`; `ComplianceListener` and event handling; `TaggingInProgressError`; module imports for `MessagingModule`, `TaggingModule`, `RfpPythonServerModule`. Service spec covers `requestAutoTagging`, `markDocumentReady`, `markDocumentFailed`, `processAutoTagNotification`, `checkForDocumentCompletion`.

- **Database:**  
  - No new tables, columns, or migrations in this PR.

- **Contracts:**
  - Request/response shapes and error formats aligned with the documented contracts: project list (summary) and detail (with relations), upload result objects (`success`, `key`, `filename`, `projectId`, `documentId`; plus `responseId` for response upload), and compliance-items request/response. Validation rules match (e.g. `SetProjectStatusDto` with `@IsIn(['active', 'archived'])`; UUID path params). `UpdateComplianceProjectDto.projectOwnerId` is string in contract and DTO; service parses to number when setting owner.

#### Testing

- **Manual:**
  - TODO: Verify Swagger UI at `/docs` for all Compliance routes (methods, params, request/response schemas, file upload body, and response codes).
- **Automated:**
  - **Jest (controller):** `compliance.controller.spec.ts` — tests for **compliance-items CRUD** (getComplianceItems, getComplianceItemById, createComplianceItem, updateComplianceItem, deleteComplianceItem) and **autoTag** (calls requestAutoTagging with id, is_auto_tag, user). No dedicated controller tests for projects CRUD or upload endpoints in this spec.
  - **Jest (service):** `compliance.service.spec.ts` — **uploadSourceDocument** (success, ProjectNotFoundError, UserNotFoundError, UploadSourceDocumentError); **uploadResponseDocument** (success, ProjectNotFoundError, ResponseNotFoundError, UserNotFoundError, UploadResponseDocumentError); **updateProject** (parses projectOwnerId string to number and sets project owner); **getComplianceItems** / **getComplianceItemById** / **createComplianceItem** / **updateComplianceItem** / **deleteComplianceItem** (success and error cases); **requestAutoTagging** (emit event, TaggingInProgressError, ProjectNotFoundError, ComplianceError); **markDocumentReady**, **markDocumentFailed**; **processAutoTagNotification**; **checkForDocumentCompletion** (Complete/Failed/not all processed).
  - **Jest (DTOs):** `compliance-project-response.dto.spec.ts` and `upload-document-result.dto.spec.ts` — shape/serialization tests for response DTOs.
- **Karma/Jasmine:** N/A (no frontend changes).
- **Playwright:** N/A (no E2E in this PR).
- **Known gaps / TODO:**
  - No controller-level unit tests for getProjects, getProjectById, createProject, updateProject, deleteProject, setProjectStatus, uploadSourceDocument, uploadResponseDocument.
  - No service-level unit tests for getProjects, getProjectById, createProject, deleteProject, setProjectStatus.
  - No integration or E2E tests against a real API/DB.
  - Swagger UI at `/docs` not manually verified; reviewer should confirm before frontend handoff.

#### Risks & Impact

- **Non-breaking:** Swagger is additive; existing API behavior and response shapes are unchanged. Frontend can rely on OpenAPI for types and client generation.
- **Auto-tagging:** New endpoint and listener add surface area (event handling, Python server, messaging). Ensure feature flags or rollout plan are clear if this is behind a flag.
- **Test coverage:** Projects CRUD and uploads are covered by Swagger and existing service behavior but not by new controller/service unit tests in this PR; consider adding tests in a follow-up if desired.

#### Verification Steps for Reviewers

1. Run the API and open Swagger UI at `/docs`. Confirm the **Compliance** tag lists all routes: GET/POST/PATCH/DELETE/PUT for projects, both document uploads, and compliance-items CRUD.
2. For **GET /compliance/projects** and **GET /compliance/projects/:id**, check that the response schemas reference `ComplianceProjectSummaryDto` and `ComplianceProjectDetailDto` and that nested shapes (documents, responses, compliance checks) look correct.
3. For **POST .../documents** and **POST .../responses/:response_id/documents**, confirm the request body shows a file upload (type `string`, format `binary`) and the response schema matches the upload result DTOs.
4. Run `npm test` (or equivalent) in the API project and ensure `compliance.controller.spec.ts`, `compliance.service.spec.ts`, and the DTO specs pass.
5. Optionally call one or two endpoints (e.g. GET list with a valid JWT and compliance permission) and confirm responses match the documented shapes.
