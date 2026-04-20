# PRCR-1033: Compliance Swagger spec for projects CRUD and MinIO uploads

## Problem statement

UI development needs a single, authoritative reference for the Compliance API: routes, request/response DTOs, status codes, and possible error responses. The Compliance controller currently has no Swagger/OpenAPI decorators, so the spec must be added for:

1. **Projects CRUD**: `GET /projects`, `GET /projects/:id`, `POST /projects`, `PATCH /projects/:id`, `DELETE /projects/:id`, and `PUT /projects/:id` (set status).
2. **MinIO upload routes**: `POST /projects/:project_id/documents` (source document) and `POST /projects/:project_id/responses/:response_id/documents` (response document).
3. **Compliance-items routes**: `GET /projects/:id/compliance-items`, `GET /projects/:id/compliance-items/:itemId`, `POST /projects/:id/compliance-items`, `PATCH /projects/:id/compliance-items/:itemId`, `DELETE /projects/:id/compliance-items/:itemId`.

The deliverable is an initial Swagger spec “as of 02/10” (or current state) so the frontend can develop against a documented contract.

## Assumptions

- **Scope**: The routes listed above (projects CRUD, two upload endpoints, and compliance-items CRUD). Other compliance routes (if any) remain out of scope.
- **Backend repo**: Work is done in the NestJS API repo (e.g. `rohan_api-parent/rohan_api-PRCR-1033` or equivalent). Swagger is already enabled in `main.ts`; we add decorators and explicit response DTOs (Option B) for GET list and GET by-id, plus upload result DTOs.
- **Contracts doc**: `PRCR-1033-contracts.md` is the single source of truth for request/response shapes and error formats shared with the frontend; Swagger decorators in code should align with it.
- **Date “02/10”**: Interpreted as “as of 2025-02-10” or “current implementation as of ticket date”; the spec documents existing behavior, not new behavior.
- **Delete behavior**: `DELETE /projects/:id` uses the service method `deleteProject`. The project must be in `archived` status first; the route then soft-deletes (sets status to `deleted`). Naming in the spec follows the code (delete, not archive).
- **Base path**: Swagger and the contracts doc use the full path **`/compliance/...`** for every route (e.g. `/compliance/projects`, `/compliance/projects/:id`).
- **PUT path**: Effective path is **`/compliance/projects/:id`** (leading slash for consistency in docs).
- **Response DTOs**: **Option B** — introduce explicit response DTOs for `GET /projects` and `GET /projects/:id` so Swagger shows full request/response schemas and frontend can use OpenAPI as the type source.
- **File upload in Swagger**: For both upload endpoints, add `@ApiBody` with **`type: 'string', format: 'binary'`** so Swagger UI shows a file input.
- **Swagger CLI plugin**: The [NestJS Swagger CLI plugin](https://docs.nestjs.com/openapi/cli-plugin#cli-plugin) is enabled. DTO properties can use the plugin’s shorthand conventions: **`@ApiProperty` / `@ApiPropertyOptional` are not required** when the plugin can infer type from TypeScript (e.g. from class property type, `class-validator` decorators, or default values). Use `@ApiProperty` only when you need explicit description, enum, example, or when inference is insufficient (e.g. nested objects, generics).

---

## Ordered checklist

| # | Step | Owner | File paths |
|---|------|--------|------------|
| 1 | Add `PRCR-1033-contracts.md` (or update) with request/response shapes, validation rules, and error formats for projects CRUD and both upload routes. | BACKEND_DB | `PRCR-1033-contracts.md` (repo root) |
| 2 | Add `@ApiTags('Compliance')` (or similar) to Compliance controller. **Note:** NestJS Swagger has **auto-tagging enabled by default** (`autoTagControllers` in `SwaggerDocumentOptions`): controllers get a tag from the class name with the `Controller` suffix stripped (e.g. `ComplianceController` → tag **"Compliance"**). So step 2 is optional unless you want a custom tag name; no code change is required for the default. | BACKEND_DB | `src/compliance/compliance.controller.ts` |
| 3 | Define response DTOs for GET list and GET by-id: e.g. `ComplianceProjectSummaryDto` (list item) and `ComplianceProjectDetailDto` (single with relations). With the Swagger CLI plugin, property types are inferred; add `@ApiProperty` only where needed (description, enum, or weak inference). Align with contracts doc. Optionally add upload result DTOs for steps 10–11. | BACKEND_DB | `src/compliance/dto/` (e.g. `compliance-project-response.dto.ts` or split) |
| 4 | Add Swagger decorators for `GET /projects`: `@ApiOperation`, `@ApiOkResponse({ type: [...] })`, `@ApiInternalServerErrorResponse` (and auth/forbidden if applicable). Refactor service or controller to map entity → response DTO if desired. | BACKEND_DB | `src/compliance/compliance.controller.ts` (and optionally service) |
| 5 | Add Swagger decorators for `GET /projects/:id`: `@ApiOperation`, `@ApiParam('id')`, `@ApiOkResponse({ type: ComplianceProjectDetailDto })`, `@ApiNotFoundResponse`, `@ApiInternalServerErrorResponse`. Refactor to return response DTO if desired. | BACKEND_DB | `src/compliance/compliance.controller.ts` (and optionally service) |
| 6 | Add Swagger decorators for `POST /projects`: `@ApiOperation`, `@ApiBody` (CreateComplianceProjectDto), `@ApiCreatedResponse`, `@ApiBadRequestResponse`, `@ApiInternalServerErrorResponse`. CreateComplianceProjectDto: with CLI plugin, properties are inferred; add `@ApiProperty`/`@ApiPropertyOptional` only when needed (e.g. enum, description). | BACKEND_DB | `src/compliance/compliance.controller.ts`, `src/compliance/dto/create-compliance-project.dto.ts` |
| 7 | Add Swagger decorators for `PATCH /projects/:id`: `@ApiOperation`, `@ApiParam('id')`, `@ApiBody` (UpdateComplianceProjectDto), `@ApiOkResponse`, `@ApiBadRequestResponse`, `@ApiNotFoundResponse`, `@ApiInternalServerErrorResponse`. UpdateComplianceProjectDto: with CLI plugin, properties are inferred; add decorators only when needed. | BACKEND_DB | `src/compliance/compliance.controller.ts`, `src/compliance/dto/update-compliance-project.dto.ts` |
| 8 | Add Swagger decorators for `DELETE /projects/:id`: `@ApiOperation`, `@ApiParam('id')`, `@ApiNoContentResponse` (or 200 if implementation returns void), `@ApiNotFoundResponse`, `@ApiConflictResponse` (cannot delete non-archived project), `@ApiInternalServerErrorResponse`. | BACKEND_DB | `src/compliance/compliance.controller.ts` |
| 9 | Add Swagger decorators for `PUT /projects/:id` (set status): `@ApiOperation`, `@ApiParam('id')`, `@ApiBody` (SetProjectStatusDto), `@ApiOkResponse`, `@ApiBadRequestResponse`, `@ApiNotFoundResponse`, `@ApiInternalServerErrorResponse`. SetProjectStatusDto: CLI plugin infers from `@IsIn([...])`; add `@ApiProperty` only if enum/description is needed. | BACKEND_DB | `src/compliance/compliance.controller.ts`, `src/compliance/dto/set-project-status.dto.ts` |
| 10 | Add Swagger decorators for `POST /projects/:project_id/documents`: `@ApiOperation`, `@ApiParam('project_id')`, `@ApiConsumes('multipart/form-data')`, `@ApiBody({ schema: { type: 'string', format: 'binary' } })`, `@ApiCreatedResponse`/`@ApiOkResponse` with upload response DTO, `@ApiBadRequestResponse` (no file), `@ApiNotFoundResponse`, `@ApiInternalServerErrorResponse`. | BACKEND_DB | `src/compliance/compliance.controller.ts` |
| 11 | Add Swagger decorators for `POST /projects/:project_id/responses/:response_id/documents`: same pattern as step 10 plus `@ApiParam('response_id')`, and 404 for project or response not found. Use `@ApiBody({ schema: { type: 'string', format: 'binary' } })`. | BACKEND_DB | `src/compliance/compliance.controller.ts` |
| 12 | Add/update `PRCR-1033-contracts.md` with request/response shapes, validation rules, and error formats for compliance-items routes (GET list, GET by id, POST, PATCH, DELETE). | BACKEND_DB | `PRCR-1033-contracts.md` (repo root) |
| 13 | Add Swagger decorators for `GET /projects/:id/compliance-items`: `@ApiOperation`, `@ApiParam('id')`, `@ApiOkResponse` (array of compliance items; optionally use response DTO), `@ApiNotFoundResponse`, `@ApiInternalServerErrorResponse`. | BACKEND_DB | `src/compliance/compliance.controller.ts` (optionally `src/compliance/dto/` for compliance-item response DTO) |
| 14 | Add Swagger decorators for `GET /projects/:id/compliance-items/:itemId`: `@ApiOperation`, `@ApiParam('id')`, `@ApiParam('itemId')`, `@ApiOkResponse`, `@ApiNotFoundResponse` (project or compliance item not found), `@ApiInternalServerErrorResponse`. | BACKEND_DB | `src/compliance/compliance.controller.ts` |
| 15 | Add Swagger decorators for `POST /projects/:id/compliance-items`: `@ApiOperation`, `@ApiParam('id')`, `@ApiBody` (CreateComplianceItemDto), `@ApiCreatedResponse`, `@ApiBadRequestResponse`, `@ApiNotFoundResponse`, `@ApiInternalServerErrorResponse`. CreateComplianceItemDto: CLI plugin infers; add decorators only when needed. | BACKEND_DB | `src/compliance/compliance.controller.ts`, `src/compliance/dto/create-compliance-item.dto.ts` |
| 16 | Add Swagger decorators for `PATCH /projects/:id/compliance-items/:itemId`: `@ApiOperation`, `@ApiParam('id')`, `@ApiParam('itemId')`, `@ApiBody` (UpdateComplianceItemDto), `@ApiOkResponse`, `@ApiBadRequestResponse`, `@ApiNotFoundResponse`, `@ApiInternalServerErrorResponse`. UpdateComplianceItemDto: CLI plugin infers; add decorators only when needed. | BACKEND_DB | `src/compliance/compliance.controller.ts`, `src/compliance/dto/update-compliance-item.dto.ts` |
| 17 | Add Swagger decorators for `DELETE /projects/:id/compliance-items/:itemId`: `@ApiOperation`, `@ApiParam('id')`, `@ApiParam('itemId')`, `@ApiNoContentResponse` (or 200 if void), `@ApiNotFoundResponse`, `@ApiInternalServerErrorResponse`. | BACKEND_DB | `src/compliance/compliance.controller.ts` |
| 18 | Verify Swagger UI at `/docs` shows all Compliance routes (projects, uploads, compliance-items) with correct methods, params, bodies (including file upload), and response codes. Update contracts doc if any response shape was refined during implementation. | TEST_REVIEW | `PRCR-1033-contracts.md`, browser at `/docs` |
| 19 | Share `PRCR-1033-contracts.md` and Swagger URL with frontend; confirm they can reference the spec for UI development. | TEST_REVIEW | N/A |

---

## Phase order and parallelism

### Files touched per phase

- **Contracts only**: `PRCR-1033-contracts.md`
- **Controller only**: `src/compliance/compliance.controller.ts`
- **DTOs**: `src/compliance/dto/create-compliance-project.dto.ts`, `src/compliance/dto/update-compliance-project.dto.ts`, `src/compliance/dto/set-project-status.dto.ts`, `src/compliance/dto/create-compliance-item.dto.ts`, `src/compliance/dto/update-compliance-item.dto.ts`, and new response DTOs (e.g. `compliance-project-response.dto.ts`, optionally compliance-item response DTOs).

### Parallelism

- **Step 1** (contracts doc) can be done first and in parallel with any backend work; it does not touch application code.
- **Steps 2–11** touch the controller; steps 3, 6, 7, 9 touch DTOs. Steps 12–17 add compliance-items; step 12 touches contracts, steps 13–17 touch controller and optionally compliance-item DTOs. To avoid merge conflicts:
  - One developer can do steps 2–5 (tags, response DTOs, GET list, GET by-id) in one PR.
  - Another can do steps 6–7 (create + update projects) in a second PR.
  - Another can do steps 8–9 (delete + set status) in a third PR.
  - Steps 10–11 (upload routes with `@ApiBody` type string/binary) can be a fourth PR.
  - Steps 12–17 (contracts for compliance-items + Swagger for all five compliance-items routes) can be a fifth PR.
  - Or a single developer can do 2–17 sequentially in a few PRs.

### Recommended order if sequential

1. **Step 1** – Publish contracts doc so frontend and backend agree on shapes and status codes (projects + uploads).
2. **Steps 2–3** – ApiTags and define response DTOs for list and detail (and optionally upload result DTOs).
3. **Steps 4–5** – GET list and GET by-id with `@ApiOkResponse({ type: ... })` (and mapping to DTOs if refactored).
4. **Steps 6–7** – Create and update (request DTOs; with CLI plugin, property decorators are optional; add controller decorators).
5. **Steps 8–9** – Delete and set status (controller + SetProjectStatusDto).
6. **Steps 10–11** – Upload endpoints with `@ApiBody({ schema: { type: 'string', format: 'binary' } })` and response DTOs.
7. **Step 12** – Add/update contracts doc for compliance-items routes.
8. **Steps 13–17** – Compliance-items Swagger: GET list, GET by id, POST, PATCH, DELETE (controller + CreateComplianceItemDto / UpdateComplianceItemDto as needed).
9. **Steps 18–19** – Verification and handoff.

Rationale: Contracts first de-risks frontend; then grouping by “read vs write” and “CRUD vs upload” keeps each PR small and reviewable.
