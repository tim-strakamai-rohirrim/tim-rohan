#### Summary

- Fix multipart file upload reliability in the Compliance controller by eagerly buffering the file instead of passing the raw Fastify multipart stream to the service layer.
- Prevents a race condition where the multipart part stream could be consumed or closed before `complianceService` calls `toBuffer()`, which caused intermittent upload failures.

#### Technical Details

- Backend:
  - `uploadSourceDocument` and `uploadResponseDocument` in `compliance.controller.ts` now call `part.toBuffer()` immediately when the file part is encountered, capturing the `Buffer`, `filename`, and `mimetype` before breaking out of the multipart iterator.
  - The service receives a simple object `{ filename, mimetype, toBuffer: () => Promise.resolve(buffer) }` instead of the raw multipart `part` stream. This preserves the same interface the service expects while eliminating stream lifecycle issues.
  - The previous approach stored the raw `part` object and drained remaining parts via `part.file.resume()` to prevent Fastify from hanging. The new approach avoids the drain step entirely by breaking after the first file part and buffering it up front.
  - Guard condition updated from `if (!file)` to `if (!buffer || !filename || !mimetype)` for stricter validation.
  - Missing-file error now throws `BadRequestException` (NestJS built-in, HTTP 400) instead of the custom `ComplianceError`, making the error semantics explicit.

#### Testing

- Manual:
  - TODO: Upload a source document to a compliance project and verify it succeeds.
  - TODO: Upload a response document and verify it succeeds.
  - TODO: Submit a request with no file attached and verify a `400` / `missingFileError` is returned.
- Automated:
  - [Jest]: Added 6 new tests to `compliance.controller.spec.ts` covering both upload endpoints:
    - Happy path — buffers the file and passes `{ filename, mimetype, toBuffer }` to the service.
    - Missing file — throws `BadRequestException` with the `missingFileError` message when no file part is present.
    - Multiple parts — only buffers the first file part; subsequent parts are not consumed.
- Known gaps / TODO:
  - No Playwright E2E tests added for this change.

#### Risks & Impact

- **Low risk.** The service-layer interface (`{ filename, mimetype, toBuffer }`) is unchanged; only the controller-level multipart handling is modified.
- Files are now held entirely in memory as a `Buffer` before being passed to the service. For very large files this increases peak memory usage compared to the streaming approach, but compliance documents are typically small and the trade-off favours reliability.
- The error class for missing file changed from `ComplianceError` to `BadRequestException`. Clients that relied on a specific error shape from this endpoint should verify they handle a standard 400 response.
- No database, migration, or contract changes.

#### Verification Steps for Reviewers

1. Run `npx jest src/compliance/compliance.controller.spec.ts` — all 13 tests should pass (6 new upload tests + 7 existing).
2. Deploy or run locally, then upload a source document via `POST /compliance/projects/:project_id/documents` with a multipart file — confirm upload succeeds and the document appears in MinIO / the database.
3. Upload a response document via `POST /compliance/projects/:project_id/responses/:response_id/documents` — confirm same.
4. Send a multipart request with **no** file field — confirm a `400` / `missingFileError` is returned.
5. (Optional) Upload a moderately large file (~50 MB) to verify memory behaviour is acceptable.
