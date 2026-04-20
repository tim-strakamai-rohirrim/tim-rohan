# PRCR-1096 — PythonAPI Tagging MinIO Support

## Problem statement

The compliance module in rohan_api (NestJS) already stores documents in MinIO — the
`ComplianceListener` passes `doc.minioObjectKey` as the `blobPath` in the
`AutoTagRequestMessage`. However, `rohan-python-api`'s auto-tag handler
(`handle_auto_tag_message.py`) only speaks Azure Blob Storage: it uses
`BlobServiceClient` to download documents and upload converted HTML.

This causes a storage mismatch: NestJS sends a MinIO object key, but Python tries to
resolve it against Azure Blob, resulting in failed downloads for compliance auto-tagging.

The fix is to make the Python auto-tag handler **dual-mode**: support both Azure Blob
and MinIO, determined by a new `storage_type` field on the request message.

## Assumptions

1. MinIO credentials/endpoint are shared with the existing visualizer config
   (`MINIO_ENDPOINT`, `MINIO_PORT`, `MINIO_ACCESS_KEY`, etc.) but with a
   **separate bucket** (`MINIO_TAGGING_BUCKET`, default `"uploads"`).
2. Template Generator continues to use Azure Blob (`storage_type: "azure_blob"`).
3. Compliance uses MinIO (`storage_type: "minio"`).
4. Future callers are expected to use MinIO as well. The `storage_type` field on the
   message makes this a per-caller decision with no handler changes needed.
5. Azure Service Bus / HTTP callback transport is unchanged — only file I/O changes.
6. The `converted_html_url` in the completion message stays a relative path (works as
   both an Azure Blob path and a MinIO object key).
7. The compliance listener does not currently read `converted_html_url`, so no NestJS
   changes are needed for HTML retrieval.
8. `list_folder_blobs` (batch folder processing) is not called by any NestJS caller
   today; a MinIO equivalent is included for parity and future use.
9. The existing `import-minio.sh` local dev script already creates the `uploads` bucket.
10. The output subfolder for converted HTML is configurable per-request via
    `output_folder` on the message, falling back to `MINIO_TAGGING_FOLDER_OUT` env var,
    then to `"output"`. No startup health-check for MinIO is needed.

## Resolved questions

1. ~~Startup health-check for MinIO?~~ — Not needed. Validation stays at call time.
2. ~~Other product codes needing MinIO?~~ — Only compliance today, but more callers
   are expected. The `storage_type` field handles this without handler changes.
3. ~~Per-request output folder?~~ — Yes. Added `output_folder` field to the message
   with a fallback chain: `message.output_folder` → `MINIO_TAGGING_FOLDER_OUT` → `"output"`.

---

## Implementation checklist

### Phase 1 — Python: schema & config `[BACKEND_DB]`

- [ ] **1.1** Add `storage_type` and `output_folder` fields to `AutoTagRequestMessage`
  - File: `rohan-python-api/backend/app/azure_event_bus/types/tagging_message.py`
  - Add: `storage_type: Literal["azure_blob", "minio"] = "azure_blob"`
  - Add: `output_folder: str | None = None`
  - Backward-compatible defaults ensure existing messages still work.

- [ ] **1.2** Add MinIO tagging config settings
  - File: `rohan-python-api/backend/app/core/config.py`
  - Add to `Settings` class:
    - `MINIO_TAGGING_BUCKET: str = "uploads"`
    - `MINIO_TAGGING_FOLDER_OUT: str = "output"`

### Phase 2 — Python: MinIO storage functions `[BACKEND_DB]`

- [ ] **2.1** Extend `MinioClient` to accept optional bucket override
  - File: `rohan-python-api/backend/app/helpers/minio.py`
  - Change `__init__` to accept `bucket: str | None = None` parameter
    (falls back to `settings.MINIO_BUCKET` when `None`).
  - Add `content_type` parameter to `upload()`.
  - Add `list_objects(prefix, recursive)` method for folder listing.

- [ ] **2.2** Add MinIO download/upload/list functions to the auto-tag handler
  - File: `rohan-python-api/backend/app/azure_event_bus/handlers/handle_auto_tag_message.py`
  - Add `get_tagging_minio_client() -> MinioClient` factory
    (uses `settings.MINIO_TAGGING_BUCKET`).
  - Add `download_file_minio(object_name, output_path)` — wraps `MinioClient.download`.
  - Add `upload_file_minio(local_path, object_name, content_type)` — wraps
    `MinioClient.upload`, returns the object key.
  - Add `list_folder_minio(folder_path)` — wraps `MinioClient.list_objects`,
    filters by `SUPPORTED_EXTENSIONS`, skips subdirectories.

- [ ] **2.3** Update handler to branch on `storage_type`
  - File: `rohan-python-api/backend/app/azure_event_bus/handlers/handle_auto_tag_message.py`
  - In `process_single_document`: dispatch `download_file` vs `download_file_minio`
    and `upload_file` vs `upload_file_minio` based on `message.storage_type`.
  - In `auto_tag_handler`: dispatch `list_folder_blobs` vs `list_folder_minio`
    based on `message.storage_type`.
  - Resolve output subfolder via the fallback chain:
    `message.output_folder` → `settings.MINIO_TAGGING_FOLDER_OUT` → `"output"`.
    Replace the hardcoded `"output"` in `output_blob_path` construction.

### Phase 3 — NestJS: message type & callers `[BACKEND_DB]`

- [ ] **3.1** Add `storage_type` and `output_folder` to NestJS `AutoTagRequestMessage`
  - File: `rohan_api-parent/rohan_api/src/utils/roh-azure-utils/message-types/AutoTagRequestMessage.ts`
  - Add properties: `storage_type?: 'azure_blob' | 'minio'`, `output_folder?: string`
  - Add to `toJSON()`: `storage_type: this.storage_type ?? 'azure_blob'`
  - Add to `toJSON()`: `...(this.output_folder ? { output_folder: this.output_folder } : {})`

- [ ] **3.2** Add `storageType` and `outputFolder` to `AutoTagRequestOptions`
  - File: `rohan_api-parent/rohan_api/src/tagging/types/auto-tag-request-options.interface.ts`
  - Add: `storageType?: 'azure_blob' | 'minio'`
  - Add: `outputFolder?: string`

- [ ] **3.3** Wire `storage_type` and `output_folder` through `TaggingService.requestAutoTag`
  - File: `rohan_api-parent/rohan_api/src/tagging/tagging.service.ts`
  - In `requestAutoTag`, add to the message `Object.assign` block:
    - `storage_type: opts.storageType ?? 'azure_blob'`
    - `...(opts.outputFolder ? { output_folder: opts.outputFolder } : {})`

- [ ] **3.4** Set `storageType: 'minio'` in compliance listener
  - File: `rohan_api-parent/rohan_api/src/compliance/listeners/compliance.listener.ts`
  - Update `requestAutoTag` call to include `storageType: 'minio'`.

- [ ] **3.5** Set `storageType: 'azure_blob'` in template-generator listener (explicit)
  - File: `rohan_api-parent/rohan_api/src/template-generator/listeners/template-documents.listener.ts`
  - Update `requestAutoTag` call to include `storageType: 'azure_blob'`.
  - Optional (default covers it), but makes intent explicit.

### Phase 4 — Local dev: bucket init `[BACKEND_DB]`

- [x] **4.1** Verify `import-minio.sh` creates the `uploads` bucket
  - File: `LocalDev/databases-runlocal/import-minio.sh`
  - Already creates `uploads` bucket (line 94: `mc mb local/"$MINIO_BUCKET" --ignore-existing`
    with `MINIO_BUCKET='uploads'`).
  - Add a comment noting this bucket is used by both the NestJS MinioService and
    Python auto-tagging.
  - If needed, add a seed step to upload a test document for manual verification.

### Phase 5 — Tests `[TEST_REVIEW]`

- [ ] **5.1** Update Python `AutoTagRequestMessage` unit tests
  - File: `rohan-python-api/backend/app/tests/azure_event_bus/test_auto_tag_handler.py`
  - Add test: message with `storage_type="minio"` round-trips correctly.
  - Add test: message without `storage_type` defaults to `"azure_blob"`.
  - Add test: `output_folder` is included when set, absent when `None`.

- [ ] **5.2** Add Python unit tests for MinIO download/upload/list
  - File: `rohan-python-api/backend/app/tests/helpers/test_minio.py`
  - Test `MinioClient` with custom bucket parameter.
  - Test `list_objects` filters and non-recursive behavior.

- [ ] **5.3** Update Python E2E handler tests for `storage_type`
  - File: `rohan-python-api/backend/app/tests/azure_event_bus/test_auto_tag_handler_e2e.py`
  - Add test: `storage_type="minio"` single-file flow (mock MinIO download/upload).
  - Add test: `storage_type="minio"` folder flow (mock MinIO list + download/upload).
  - Add test: custom `output_folder` is used in the output path.
  - Existing Azure Blob tests remain unchanged (default `storage_type`).

- [ ] **5.4** Update NestJS `TaggingService` unit tests
  - File: `rohan_api-parent/rohan_api/src/tagging/tagging.service.spec.ts`
  - Add test: `requestAutoTag` with `storageType: 'minio'` includes `storage_type`
    in the sent message.
  - Add test: `requestAutoTag` without `storageType` sends `storage_type: 'azure_blob'`.
  - Add test: `outputFolder` is passed through as `output_folder` when provided.

- [ ] **5.5** Update NestJS compliance listener tests
  - File: `rohan_api-parent/rohan_api/src/compliance/listeners/compliance.listener.spec.ts`
  - Verify `requestAutoTag` is called with `storageType: 'minio'`.

- [ ] **5.6** Update NestJS template-generator listener tests
  - File: `rohan_api-parent/rohan_api/src/template-generator/listeners/template-documents.listener.spec.ts`
  - Verify `requestAutoTag` is called with `storageType: 'azure_blob'`.

---

## Phase order and parallelism

### Files touched per phase

| Phase | Files |
|-------|-------|
| 1     | `rohan-python-api/.../tagging_message.py`, `rohan-python-api/.../config.py` |
| 2     | `rohan-python-api/.../helpers/minio.py`, `rohan-python-api/.../handle_auto_tag_message.py` |
| 3     | `rohan_api-parent/.../AutoTagRequestMessage.ts`, `rohan_api-parent/.../auto-tag-request-options.interface.ts`, `rohan_api-parent/.../tagging.service.ts`, `rohan_api-parent/.../compliance.listener.ts`, `rohan_api-parent/.../template-documents.listener.ts` |
| 4     | `LocalDev/databases-runlocal/import-minio.sh` |
| 5     | Test files in both repos (see checklist above) |

### Parallelism

- **Phase 1 and Phase 3** can run in parallel (different repos, no file overlap).
- **Phase 4** is independent of all other phases.
- **Phase 2** depends on Phase 1 (needs `storage_type` on message and config settings).
- **Phase 5** depends on Phases 2 and 3 (tests exercise the new code paths).

### Recommended sequential order

1. **Phase 1** — Python schema & config (foundation for Phase 2)
2. **Phase 3** — NestJS message & callers (can start immediately, parallel with Phase 1)
3. **Phase 2** — Python MinIO storage functions (after Phase 1)
4. **Phase 4** — Local dev bucket init (anytime)
5. **Phase 5** — Tests (after Phases 2 and 3)

Rationale: Phases 1 and 3 establish the contract on both sides. Phase 2 implements the
Python handler logic that depends on the contract. Phase 5 validates everything end-to-end.
Phase 4 is standalone infrastructure.

### Deployment order

Deploy **NestJS (Phase 3) first** with `storage_type` defaulting to `"azure_blob"`.
This is a no-op change — existing messages behave identically. Then deploy
**Python (Phases 1+2)**. Once both are live, NestJS compliance callers will send
`storage_type: "minio"` and Python will handle it correctly.
