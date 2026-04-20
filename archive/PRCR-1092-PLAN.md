# PRCR-1092: Seed script for compliance phase 1 data

## Problem statement

Developers and testers need compliance data to test against locally and in staging environments. There is currently no seed script for the compliance tables. The deliverable is a single, manually-run SQL script that idempotently populates phase 1 compliance data: projects, source documents, project–document links, and compliance items.

The script must be safe to run multiple times (idempotent via `ON CONFLICT … DO UPDATE`) and must not be wired into any automatic seed runner.

## Assumptions

- **User**: All `project_owner_id`, `created_by`, `uploaded_by`, and `reviewed_by` references resolve to the `support@rohirrim.ai` user. The script fails fast if this user doesn't exist.
- **Fixed UUIDs**: Every seeded row uses a deterministic UUID so the script is idempotent (`INSERT … ON CONFLICT (id) DO UPDATE`). UUIDs use a `00000000-0000-4092-` prefix to make seed data easy to identify and clean up.
- **No MinIO files**: `compliance_documents.minio_object_key` values are clearly-fake placeholders (e.g. `seed/compliance/…`). No actual files are uploaded.
- **Tables in scope** (phase 1):
  1. `compliance_projects` — 4 rows, one per status (`active`, `creating_compliance_list`, `reviewing_responses`, `archived`).
  2. `compliance_documents` — source-category documents, ~1-2 per project.
  3. `compliance_project_documents` — join-table rows linking each document to its project.
  4. `compliance_items` — 5–8 per project, covering all three statuses (`pending_review`, `approved`, `rejected`), with a mix of extraction methods.
- **Tables out of scope**: `compliance_responses`, `compliance_response_documents`, `compliance_checks`, `compliance_item_evidence`.
- **File location**: `Database-PRCR-1033/rohan_api/scripts/sql/test/seed_compliance.sql`. Not included in `run_seeds.sql` or `run_all.sql`.
- **`compliance_project_documents` is required**: The app loads project documents via the `ComplianceProjectDocument` join table (used in `GET /projects/:id`, `checkForDocumentCompletion`, etc.). Without it, seeded projects would appear to have no documents.

## Open questions

_All resolved._

## Resolved decisions

1. **`autotag_processing` column**: Omit from seed; rely on DB default (`'n'`).
2. **`taggable_doc_id` column**: Omit from seed; defaults to NULL.
3. **Realistic data fidelity**: Generic placeholder strings are sufficient for compliance item text.
4. **`line_item_number` SERIAL**: Explicitly set in seed for deterministic re-runs; `setval()` call at end to advance the sequence.

---

## Ordered checklist

| # | Step | Owner | File(s) |
|---|------|-------|---------|
| 1 | Create `PRCR-1092-contracts.md` documenting the seed data shapes, table schemas, fixed UUIDs, and sample values. | `[BACKEND_DB]` | `PRCR-1092-contracts.md` |
| 2 | Create `seed_compliance.sql` with header comments (purpose, usage instructions, compatibility notes). Wrap everything in a single transaction (`BEGIN; … COMMIT;`). | `[BACKEND_DB]` | `Database-PRCR-1033/rohan_api/scripts/sql/test/seed_compliance.sql` |
| 3 | Add Step 1 to the script: resolve `support@rohirrim.ai` → `user_id` into a temp table; `RAISE EXCEPTION` if not found. Follow the pattern from existing high-side seeds. | `[BACKEND_DB]` | `Database-PRCR-1033/rohan_api/scripts/sql/test/seed_compliance.sql` |
| 4 | Add Step 2: upsert 4 `compliance_projects` rows (one per status) using fixed UUIDs and `ON CONFLICT (id) DO UPDATE`. Include realistic project names, contract numbers, date ranges. | `[BACKEND_DB]` | `Database-PRCR-1033/rohan_api/scripts/sql/test/seed_compliance.sql` |
| 5 | Add Step 3: upsert `compliance_documents` rows (category = `source`, processing_status = `extraction_complete`). One or two per project, using fixed UUIDs and fake `minio_object_key` values. | `[BACKEND_DB]` | `Database-PRCR-1033/rohan_api/scripts/sql/test/seed_compliance.sql` |
| 6 | Add Step 4: upsert `compliance_project_documents` join-table rows linking each document to its project. Use `ON CONFLICT (project_id, document_id) DO NOTHING`. | `[BACKEND_DB]` | `Database-PRCR-1033/rohan_api/scripts/sql/test/seed_compliance.sql` |
| 7 | Add Step 5: upsert `compliance_items` (5–8 per project), covering `pending_review`, `approved`, and `rejected` statuses, with `auto_extracted`, `manual`, and `edited` extraction methods. Use fixed UUIDs. Include section names and outline numbers for realistic display. | `[BACKEND_DB]` | `Database-PRCR-1033/rohan_api/scripts/sql/test/seed_compliance.sql` |
| 8 | Add Step 6: `setval()` call on the `compliance_items_line_item_number_seq` sequence to max seeded value + 1, so future app-inserted items don't collide. | `[BACKEND_DB]` | `Database-PRCR-1033/rohan_api/scripts/sql/test/seed_compliance.sql` |
| 9 | Add a final `\echo` summary reporting how many rows were upserted per table. | `[BACKEND_DB]` | `Database-PRCR-1033/rohan_api/scripts/sql/test/seed_compliance.sql` |
| 10 | Run the script against a local PostgreSQL instance to verify it completes without errors and is re-runnable. | `[TEST_REVIEW]` | `Database-PRCR-1033/rohan_api/scripts/sql/test/seed_compliance.sql` |
| 11 | Verify seeded data appears correctly in the UI (compliance landing page shows 4 projects, project detail shows documents and items). | `[TEST_REVIEW]` | N/A (browser) |
| 12 | Update `PRCR-1092-contracts.md` if any data shapes were adjusted during implementation. | `[BACKEND_DB]` | `PRCR-1092-contracts.md` |

---

## Phase order and parallelism

### Files touched per phase

| Phase | Files |
|-------|-------|
| **A — Contracts doc** (step 1) | `PRCR-1092-contracts.md` |
| **B — Seed script** (steps 2–9) | `Database-PRCR-1033/rohan_api/scripts/sql/test/seed_compliance.sql` |
| **C — Verification** (steps 10–12) | `seed_compliance.sql` (read-only), `PRCR-1092-contracts.md` (possible update), browser |

### Parallelism

- **Phase A and Phase B** can be done in parallel — they touch different files and Phase B only reads the contracts doc for reference.
- **Phase C** depends on both A and B being complete.

### Recommended sequential order

1. **Phase A** first — establishes the data shapes and UUID conventions before writing SQL.
2. **Phase B** next — implements the seed script referencing the contracts doc.
3. **Phase C** last — validates everything end-to-end.

Rationale: Writing the contracts doc first forces alignment on UUID conventions, column coverage, and sample values before committing to SQL. This avoids rework.
