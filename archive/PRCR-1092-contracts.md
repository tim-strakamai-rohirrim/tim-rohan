# PRCR-1092: Compliance Phase 1 Seed Data — Contracts & Data Shapes

> Single source of truth for the seed script's data shapes, fixed UUIDs, and column values.

---

## UUID convention

All seeded rows use a fixed UUID with prefix `00000000-0000-4092-` to make seed data identifiable:

```
00000000-0000-4092-<type><seq>-000000000000
```

| Type prefix | Entity |
|-------------|--------|
| `a` | `compliance_projects` |
| `b` | `compliance_documents` |
| `c` | `compliance_items` |

Example: `00000000-0000-4092-a001-000000000000` = first compliance project.

---

## 1. `compliance_projects` (4 rows)

### Schema (columns set by seed)

| Column | Type | Seed value |
|--------|------|------------|
| `id` | UUID | Fixed (see below) |
| `project_name` | VARCHAR(255) | Descriptive name |
| `contract_number` | VARCHAR(100) | Fake contract number |
| `start_date` | DATE | Recent past date |
| `due_date` | DATE | Near future date |
| `additional_details` | TEXT | Brief description or NULL |
| `project_owner_id` | INTEGER | `support@rohirrim.ai` user_id |
| `status` | VARCHAR(50) | One of: `active`, `creating_compliance_list`, `reviewing_responses`, `archived` |
| `created_by` | INTEGER | Same user_id |
| `updated_by` | INTEGER | Same user_id |
| `deleted_at` | TIMESTAMP | NULL |

### Seed rows

| UUID | `project_name` | `status` |
|------|----------------|----------|
| `00000000-0000-4092-a001-000000000000` | Seed: IT Infrastructure Compliance Review | `active` |
| `00000000-0000-4092-a002-000000000000` | Seed: Cybersecurity Standards Assessment | `creating_compliance_list` |
| `00000000-0000-4092-a003-000000000000` | Seed: Cloud Services Vendor Evaluation | `reviewing_responses` |
| `00000000-0000-4092-a004-000000000000` | Seed: Legacy System Decommission Audit | `archived` |

### Validation / constraints

- `status` must be one of: `active`, `creating_compliance_list`, `reviewing_responses`, `archived` (enforced by `chk_compliance_projects_status`).
- `project_owner_id` and `created_by` must reference valid `users(user_id)`.

---

## 2. `compliance_documents` (5 rows, all `source` category)

### Schema (columns set by seed)

| Column | Type | Seed value |
|--------|------|------------|
| `id` | UUID | Fixed |
| `document_name` | VARCHAR(255) | Descriptive filename |
| `document_category` | VARCHAR(50) | `source` |
| `minio_object_key` | VARCHAR(500) | `seed/compliance/<project-slug>/<filename>` |
| `file_size_bytes` | BIGINT | Fake size (e.g. 1048576) |
| `mime_type` | VARCHAR(100) | `application/pdf` |
| `processing_status` | VARCHAR(50) | `extraction_complete` |
| `uploaded_by` | INTEGER | `support@rohirrim.ai` user_id |

### Seed rows

| UUID | `document_name` | Linked to project |
|------|-----------------|-------------------|
| `00000000-0000-4092-b001-000000000000` | IT-Infrastructure-SOW.pdf | `…a001…` (active) |
| `00000000-0000-4092-b002-000000000000` | Cybersecurity-Requirements.pdf | `…a002…` (creating list) |
| `00000000-0000-4092-b003-000000000000` | Cybersecurity-NIST-Framework.pdf | `…a002…` (creating list) |
| `00000000-0000-4092-b004-000000000000` | Cloud-Services-RFP.pdf | `…a003…` (reviewing) |
| `00000000-0000-4092-b005-000000000000` | Legacy-Decommission-Checklist.pdf | `…a004…` (archived) |

### Validation / constraints

- `document_category` must be `source` or `response` (enforced by `chk_document_ownership`).
- `processing_status` must be one of: `pending_extraction`, `extracting`, `extraction_complete`, `extraction_failed`.
- `uploaded_by` must reference valid `users(user_id)`.

---

## 3. `compliance_project_documents` (5 rows)

### Schema

| Column | Type | Seed value |
|--------|------|------------|
| `project_id` | UUID | References `compliance_projects(id)` |
| `document_id` | UUID | References `compliance_documents(id)` |

### Seed rows

| `project_id` | `document_id` |
|---------------|---------------|
| `…a001…` | `…b001…` |
| `…a002…` | `…b002…` |
| `…a002…` | `…b003…` |
| `…a003…` | `…b004…` |
| `…a004…` | `…b005…` |

### Idempotency

`ON CONFLICT (project_id, document_id) DO NOTHING` — composite PK, no columns to update.

---

## 4. `compliance_items` (~24 rows, 5–8 per project)

### Schema (columns set by seed)

| Column | Type | Seed value |
|--------|------|------------|
| `id` | UUID | Fixed |
| `project_id` | UUID | References parent project |
| `source_document_id` | UUID | References source document |
| `line_item_number` | INTEGER | Explicit sequential number per project |
| `compliance_item_title` | VARCHAR(500) | Short requirement title |
| `compliance_item_text` | TEXT | Requirement description (1–3 sentences) |
| `outline_number` | VARCHAR(100) | e.g. `1.1`, `2.3.1` |
| `section_name` | VARCHAR(255) | e.g. `Security Requirements`, `Data Handling` |
| `document_start_line` | INTEGER | Fake line number |
| `document_end_line` | INTEGER | Fake line number (> start) |
| `extraction_method` | VARCHAR(50) | Mix of `auto_extracted`, `manual`, `edited` |
| `status` | VARCHAR(50) | Mix of `pending_review`, `approved`, `rejected` |
| `reviewed_by` | INTEGER | user_id for `approved`/`rejected` items; NULL for `pending_review` |
| `reviewed_at` | TIMESTAMP | Set for `approved`/`rejected` items; NULL for `pending_review` |

### Status distribution per project (target)

| Status | Count per project (approx.) |
|--------|----------------------------|
| `pending_review` | 2–3 |
| `approved` | 2–4 |
| `rejected` | 1 |

### Extraction method distribution (across all items)

| Method | Approximate share |
|--------|-------------------|
| `auto_extracted` | ~60% |
| `manual` | ~25% |
| `edited` | ~15% |

### UUID range

`00000000-0000-4092-c001-000000000000` through `00000000-0000-4092-c032-000000000000` (reserved range; not all may be used).

### Validation / constraints

- `status` must be one of: `pending_review`, `approved`, `rejected` (enforced by `chk_compliance_item_status`).
- `extraction_method` must be one of: `auto_extracted`, `manual`, `edited` (enforced by `chk_extraction_method`).
- `project_id` must reference existing `compliance_projects(id)`.
- `source_document_id` must reference existing `compliance_documents(id)`.

---

## Sequence reset

After seeding, the script must call:

```sql
SELECT setval(
  'compliance_items_line_item_number_seq',
  GREATEST(
    (SELECT COALESCE(MAX(line_item_number), 0) FROM compliance_items),
    (SELECT last_value FROM compliance_items_line_item_number_seq)
  )
);
```

This ensures the `SERIAL` sequence is advanced past all seeded values so app-inserted items don't collide.

> **Note:** Uses `last_value` from the sequence relation instead of `currval()` to avoid errors when the sequence hasn't been called in the current session. `COALESCE` guards against an empty `compliance_items` table.

---

## Error format

The script uses `RAISE EXCEPTION` for hard failures:

| Condition | Message |
|-----------|---------|
| `support@rohirrim.ai` user not found | `User with email support@rohirrim.ai not found.` |

All other failures rely on PostgreSQL constraint violations (FK, CHECK) which will cause the transaction to roll back.

---

## Changelog

| Date | Change | Reason |
|------|--------|--------|
| 2026-02-19 | `setval()` SQL: replaced `currval()` with `(SELECT last_value FROM …)` and added `COALESCE` | `currval()` fails if the sequence hasn't been called in the current session; `COALESCE` guards against an empty table. |
