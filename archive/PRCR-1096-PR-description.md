#### Summary

- Add `storage_type` and `output_folder` fields to the `AutoTagRequestMessage` so the Python auto-tag handler knows whether to download/upload documents via Azure Blob or MinIO, fixing the storage mismatch for compliance auto-tagging.
- Wire the new fields through `TaggingService` and set them explicitly in the compliance listener (`minio`) and template-generator listener (`azure_blob`).

#### Technical Details

- Backend:
  - **New `StorageType` enum** (`src/tagging/types/storage-type.enum.ts`) with values `azure_blob` and `minio`.
  - **`AutoTagRequestMessage`** — added `storage_type` (defaults to `azure_blob` in `toJSON()`) and `output_folder` (conditionally included when truthy). This is the wire contract consumed by `rohan-python-api`.
  - **`AutoTagRequestOptions`** — added optional `storageType` and `outputFolder` properties.
  - **`TaggingService.requestAutoTag`** — maps `opts.storageType` → `storage_type` (default `azure_blob`) and `opts.outputFolder` → `output_folder` (omitted when not set) on the outbound Service Bus message.
  - **`ComplianceListener`** — now passes `storageType: StorageType.MINIO` so compliance documents are fetched/uploaded via MinIO.
  - **`TemplateDocumentsListener`** — now passes `storageType: StorageType.AZURE_BLOB` explicitly (matches the default, but makes intent clear for future readers).
- Contracts:
  - `storage_type` is always serialized on the wire (defaults to `"azure_blob"`). Python consumers that pre-date this field will ignore it safely.
  - `output_folder` is only present when explicitly set; the Python handler falls back to `MINIO_TAGGING_FOLDER_OUT` env var, then to `"output"`.
  - No changes to `AutoTagCompleteMessage`.

#### Testing

- Automated:
  - [Jest] **`AutoTagRequestMessage.spec.ts`** (new) — covers `storage_type` default/explicit values, `output_folder` inclusion/omission/empty-string, and `JSON.stringify` round-trip wire format.
  - [Jest] **`tagging.service.spec.ts`** — four new tests: default `storage_type`, explicit `minio`, `output_folder` present, and `output_folder` omitted. Existing assertion updated to expect `storage_type: azure_blob`.
  - [Jest] **`compliance.listener.spec.ts`** — updated assertion to verify `storageType: StorageType.MINIO` is passed to `requestAutoTag`.
  - [Jest] **`template-documents.listener.spec.ts`** — updated assertion to verify `storageType: StorageType.AZURE_BLOB` is passed to `requestAutoTag`.
- Known gaps / TODO:
  - No integration test exercising the full Service Bus round-trip with the new fields; covered by Python-side E2E tests in the companion PR.

#### Risks & Impact

- **Low risk of regression** — `storage_type` defaults to `azure_blob`, so all existing auto-tag flows behave identically until a caller explicitly opts into `minio`.
- **Deployment order** — this NestJS change should be deployed **before** the companion Python changes. Until Python is updated, `storage_type` and `output_folder` are ignored by the handler. Once Python is deployed with MinIO support, compliance auto-tagging will work end-to-end.
- **No database or migration changes.**

#### Verification Steps for Reviewers

1. Run `npm test` in `rohan_api-PRCR-1096` — all new and existing Jest specs should pass.
2. Trigger a compliance auto-tag event (e.g., upload a source document to a compliance project) and inspect the Service Bus message; confirm it includes `"storage_type": "minio"` and no `output_folder` key.
3. Trigger a template-generator auto-tag event and confirm the message includes `"storage_type": "azure_blob"`.
4. Verify that omitting `storageType` from a `requestAutoTag` call still defaults to `"azure_blob"` on the wire (covered by unit tests, but worth a spot-check in logs).
