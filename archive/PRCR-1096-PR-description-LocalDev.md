#### Summary

- Update the MinIO local dev setup script to support manual verification of the new `storage_type: "minio"` auto-tagging flow by seeding a test document into the `uploads` bucket and clarifying shared-bucket ownership.

#### Technical Details

- Backend:
  - **`import-minio.sh`** — added a comment on the `MINIO_BUCKET` variable documenting that the `uploads` bucket is shared between NestJS `MinioService` (document storage) and `rohan-python-api` auto-tagging (download + HTML upload).
  - Added an idempotent seed step that creates a small `test-tagging.txt` file locally and uploads it to `uploads/test-org/docs/test-tagging.txt` via `mc cp`. The step is guarded with fast-fail (`exit 1`) and an error message on upload failure.
  - Extended the script's summary output to print the seed object key and a usage hint (`storage_type='minio'`, `blob_path='test-org/docs/test-tagging.txt'`).

#### Testing

- Manual:
  - Run `./import-minio.sh` against a running local MinIO instance; confirm the seed document appears under `uploads/test-org/docs/test-tagging.txt` in the MinIO Console.
  - Re-run the script a second time to verify idempotency (no errors, file is overwritten cleanly).
- Automated:
  - No automated tests — this is an infrastructure/shell script change.
- Known gaps / TODO:
  - None.

#### Risks & Impact

- **Low risk** — changes are confined to a local dev helper script with no production deployment path.
- The seed step adds a negligible ~50-byte text file; no performance concern.
- No database, migration, or service contract changes.

#### Verification Steps for Reviewers

1. Start the local MinIO stack (`docker compose up minio -d` in `databases-runlocal/`).
2. Run `./import-minio.sh` and confirm it completes without errors.
3. Open the MinIO Console at `http://localhost:9001`, navigate to the `uploads` bucket, and verify `test-org/docs/test-tagging.txt` exists.
4. Run `./import-minio.sh` a second time — the script should succeed again (idempotent).
5. Review the terminal output for the new `Auto-tag test seed:` line with the object key and usage instructions.
