# PRCR-1421 — Add `tag_ui` JSONB Column to `tag_configs`

## Problem Statement

The `tag_configs` table stores all tag configuration in a single `tag_schema` JSONB column, mixing backend processing data (classification strategies, indicators, element types, priority) with UI display data (colors, display names). This makes the frontend's parsing fragile — it must interpret two different structures (`tags[]` vs `categories[]`) and extract display fields from a schema designed for backend consumption.

Adding a dedicated `tag_ui` JSONB column separates concerns: `tag_schema` remains the backend processing contract sent to Python via `AutoTagRequestMessage`, while `tag_ui` holds a normalized, UI-only display contract that the frontend can consume directly.

## Key Architectural Observations

### Database (`Database/rohan_api/scripts/sql/`)

- `tag_configs` is created in `init_tagging_tables.sql` with a `UNIQUE` constraint on `product_code`.
- Seed data in `init_tag_configs.sql` uses `ON CONFLICT (product_code) DO UPDATE SET` — upsert pattern.
- Four products exist: `template_generator`, `compliance`, `compliance_response`, `proposal_writer`.
- `tag_schema` holds different shapes per product:
  - `template_generator`: `{ categories: [{ id, name, color, element_types }] }`
  - `compliance`: `{ color, tags: [{ tag_type, display_name }], grouping_strategy, ... }`
  - `compliance_response`: `{ categories: [], dynamic: true }`
  - `proposal_writer`: `{ categories: [{ id, name, color, priority, indicators, element_types }], classification, default_tag }`

### NestJS Backend (`rohan_api/src/tagging/`)

- `TagConfig` entity maps `tag_schema` as `Record<string, any>` JSONB.
- DTOs (`CreateTagConfigDto`, `UpdateTagConfigDto`) validate `tag_schema` as `@IsObject()`.
- `TaggingTagConfigsService` is a straightforward CRUD service; `updateById` merges only provided fields.
- `TaggingTagConfigsController` returns the raw `TagConfig` entity for all endpoints.
- `AutoTagRequestMessage` copies `tag_schema` into the Service Bus message — **`tag_ui` must NOT be added here**.
- `TaggingService.requestAutoTag()` loads `config.tag_schema` and sends it to Python.

### Angular Frontend (`rohan_ui/src/app/shared-services/tagging/`)

- `TaggingService` caches and resolves display metadata (labels, colors, kinds) from `tag_schema` via `resolveConfiguredTagMetadata()` → `resolveSchemaTags()`.
- `resolveSchemaTags()` handles two tag_schema shapes: `tags[]` → `{ tag_type, display_name, color, kind }`, `categories[]` → `{ id→tag_type, name→display_name, color, kind }`.
- `DocShellComponent.buildMenuConfig()` reads `tag_schema` to build the tagging context menu (tag type + display name per entry).
- `DocumentTaggingFacadeService.toInlineTag()` calls `resolveConfiguredTagColor()` and `resolveTagLabelAndKind()` for rendering.
- Types in `tagging.tag-config.types.ts` define `TagSchema` with the dual `tags[]`/`categories[]` structure.

### proposal-writer.documents.service.ts (NOT in scope)

- This file does **not** read from `tag_schema`. Colors are hardcoded in `getHighlightColor()` and `getCssClassName()` for HTML export rendering. This is a separate concern from inline tagging display and is excluded from this change.

## Assumptions

1. `tag_ui` is **nullable** — new column, defaults to `NULL` for rows that don't need UI metadata.
2. Colors and display names **remain in `tag_schema`** — no breaking change to existing data or Python consumers.
3. The UI **falls back to `tag_schema`** if `tag_ui` is null (backward compatibility during rollout).
4. `tag_ui` uses a **single normalized structure** — no `tags[]` vs `categories[]` ambiguity.
5. `compliance_response` gets `tag_ui = NULL` since its schema is dynamic (tags determined at runtime).
6. `AutoTagRequestMessage` is **not modified** — `tag_ui` is never sent to Python.
7. All work targets the `feature` worktree for both API and UI.

## Resolved Questions

| # | Question | Answer |
|---|----------|--------|
| 1 | Should `proposal-writer.documents.service.ts` be migrated to read from `tag_ui`? | **No** — out of scope. It uses hardcoded colors for HTML export, not `tag_schema`. |
| 2 | Should colors be removed from `tag_schema` in the seed SQL? | **No** — leave `tag_schema` unchanged for backward compat and Python consumers. |
| 3 | Should the UI fall back to `tag_schema` when `tag_ui` is null? | **Yes** — `TaggingService` reads `tag_ui` first, falls back to `tag_schema`. |
| 4 | Jira ticket ID | `PRCR-1421` |
| 5 | Should `compliance_response` have a `tag_ui` value? | **No** — `tag_ui = NULL` since tags are dynamic. |

---

## Implementation Phases

### Phase 1 — Add `tag_ui` column and seed data [BACKEND_DB]

```phase-meta
phase: 1
title: Add tag_ui column and seed data
tags: [BACKEND_DB]
repo: Database
base_branch: main
depends_on: []
files:
  - rohan_api/scripts/sql/init_tagging_tables.sql
  - rohan_api/scripts/sql/init_tag_configs.sql
contracts:
  - "1.1 tag_ui column DDL"
  - "1.2 tag_ui seed data"
verification:
  - "Manual: verify SQL is syntactically valid and idempotent"
```

**Goal**: Add the `tag_ui JSONB` column to the `tag_configs` table and populate it for each product code.

**Steps**:

- [ ] **1.1** Add `tag_ui` column to `tag_configs` table.
  - Use `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` for idempotency.
  - `JSONB`, nullable, default `NULL`.
  - Place immediately after `CREATE TABLE tag_configs` and before the trigger definition (keeps DDL logically grouped).
  - Add a comment explaining that `tag_ui` and `tag_schema` both contain display metadata during migration and must stay in sync until `tag_schema` display fields are removed.
  - File: `rohan_api/scripts/sql/init_tagging_tables.sql`
- [ ] **1.2** Populate `tag_ui` for `template_generator` in the seed INSERT.
  - Extract `id`, `name`, `color` from existing `tag_schema.categories`.
  - Use multi-line formatted JSON for readability.
  - File: `rohan_api/scripts/sql/init_tag_configs.sql`
- [ ] **1.3** Populate `tag_ui` for `compliance` in the seed INSERT.
  - Seed a `compliance_item` entry: `{"tags": [{"id": "compliance_item", "name": "Add Compliance Item", "color": "#CCE5FF"}]}`.
  - File: `rohan_api/scripts/sql/init_tag_configs.sql`
- [ ] **1.4** Set `tag_ui = NULL` for `compliance_response` in the seed INSERT.
  - Dynamic schema — `NULL` correctly signals "not applicable" rather than an empty array.
  - File: `rohan_api/scripts/sql/init_tag_configs.sql`
- [ ] **1.5** Populate `tag_ui` for `proposal_writer` in the seed INSERT.
  - Extract `id`, `name`, `color` from existing `tag_schema.categories`.
  - Use multi-line formatted JSON for readability.
  - File: `rohan_api/scripts/sql/init_tag_configs.sql`
- [ ] **1.6** Add `tag_ui` to the `ON CONFLICT ... DO UPDATE SET` clause for all four INSERT statements.
  - Ensures re-runs update `tag_ui` along with other fields.
  - File: `rohan_api/scripts/sql/init_tag_configs.sql`

---

### Phase 2 — NestJS entity, DTOs, service, and tests [BACKEND_DB]

```phase-meta
phase: 2
title: Add tag_ui to NestJS entity and DTOs
tags: [BACKEND_DB]
repo: rohan_api
base_branch: base
depends_on: [1]
files:
  - src/tagging/entities/tagConfig.entity.ts
  - src/tagging/dto/create-tag-config.dto.ts
  - src/tagging/dto/update-tag-config.dto.ts
  - src/tagging/tagging.tag-configs.service.ts
  - src/tagging/tagging.tag-configs.service.spec.ts
contracts:
  - "2.1 TagConfig entity"
  - "2.2 CreateTagConfigDto"
  - "2.3 UpdateTagConfigDto"
  - "2.4 TaggingTagConfigsService changes"
  - "2.5 API response shape"
verification:
  - npm run lint
  - npm run test -- src/tagging/tagging.tag-configs.service.spec.ts
```

**Goal**: Add `tag_ui` to the TypeORM entity and DTOs so the column is persisted and returned in API responses.

**Steps**:

- [ ] **2.1** Add `tag_ui` column to `TagConfig` entity.
  - `@Column({ type: 'jsonb', nullable: true })` — `Record<string, any> | null`.
  - File: `src/tagging/entities/tagConfig.entity.ts`
- [ ] **2.2** Add `tag_ui` to `CreateTagConfigDto`.
  - `@IsOptional() @IsObject()` — optional on create since not all products need it.
  - File: `src/tagging/dto/create-tag-config.dto.ts`
- [ ] **2.3** Add `tag_ui` to `UpdateTagConfigDto`.
  - `@IsOptional() @IsObject()` — same pattern as `tag_schema`.
  - File: `src/tagging/dto/update-tag-config.dto.ts`
- [ ] **2.4** Update `TaggingTagConfigsService.create()` to include `tag_ui`.
  - Pass `dto.tag_ui ?? undefined` in the `create()` call.
  - File: `src/tagging/tagging.tag-configs.service.ts`
- [ ] **2.5** Update `TaggingTagConfigsService.updateById()` to handle `tag_ui`.
  - Add conditional assignment: `if (dto.tag_ui !== undefined) config.tag_ui = dto.tag_ui;`
  - File: `src/tagging/tagging.tag-configs.service.ts`
- [ ] **2.6** Update unit tests to cover `tag_ui` in create, update, and persistence.
  - Add `tag_ui` to `existingConfig` mock, add test for updating `tag_ui`.
  - File: `src/tagging/tagging.tag-configs.service.spec.ts`

---

### Phase 3 — Angular types, tagging service, and doc-shell [FRONTEND]

```phase-meta
phase: 3
title: Update UI to read display metadata from tag_ui
tags: [FRONTEND]
repo: rohan_ui
base_branch: base
depends_on: [2]
files:
  - src/app/shared-services/tagging/types/tagging.tag-config.types.ts
  - src/app/shared-services/tagging/tagging.service.ts
  - src/app/shared-services/tagging/tagging.service.spec.ts
  - src/app/shared-components/document-shredding/components/document-tagging/doc-shell/doc-shell.component.ts
  - src/app/shared-components/document-shredding/components/document-tagging/doc-shell/doc-shell.component.spec.ts
contracts:
  - "3.1 TagUi interface"
  - "3.2 TagConfigResponse update"
  - "3.3 TaggingService metadata resolution"
  - "3.4 DocShellComponent menu building"
verification:
  - npm run lint
  - npm run test:ci
```

**Goal**: Define the `TagUi` type, update `TagConfigResponse` to include `tag_ui`, and switch `TaggingService` and `DocShellComponent` to read display metadata from `tag_ui` (with `tag_schema` fallback).

**Steps**:

- [ ] **3.1** Add `TagUiEntry` and `TagUi` interfaces to `tagging.tag-config.types.ts`.
  - Normalized structure: `{ tags: [{ id, name, color }] }`.
  - File: `src/app/shared-services/tagging/types/tagging.tag-config.types.ts`
- [ ] **3.2** Add `tag_ui: TagUi | null` to `TagConfigResponse`.
  - File: `src/app/shared-services/tagging/types/tagging.tag-config.types.ts`
- [ ] **3.3** Update `TaggingService.getConfiguredTagMetadata()` to try `tag_ui` first.
  - Read `tag_ui` from the config snapshot; if present, resolve metadata from `tag_ui.tags[]`.
  - If `tag_ui` is null, fall back to existing `tag_schema` parsing.
  - Invalidate cache when either `tag_ui` or `tag_schema` reference changes.
  - File: `src/app/shared-services/tagging/tagging.service.ts`
- [ ] **3.4** Add private `resolveTagUiMetadata(tagUi: TagUi)` method to `TaggingService`.
  - Simpler than `resolveConfiguredTagMetadata` — directly maps `tags[].id` → label/color/kind.
  - `kindsByType` must store the **original** `entry.id`, not the normalized form — consistent with how the schema path stores raw `schemaTag.kind`.
  - File: `src/app/shared-services/tagging/tagging.service.ts`
- [ ] **3.5** Update `DocShellComponent.buildMenuConfig()` to try `tag_ui` first.
  - Extract a private `resolveTagUiTags()` helper that trims whitespace from `id`/`name` and filters empty entries.
  - If `tagConfig.tag_ui?.tags` is non-empty, build menu from it (`id` → value, `name` → label).
  - Otherwise fall back to existing `tag_schema` parsing.
  - Update error messages to reflect the new fallback chain ("tag_ui or tag_schema" instead of "Tag schema is required").
  - File: `src/app/shared-components/document-shredding/components/document-tagging/doc-shell/doc-shell.component.ts`
- [ ] **3.6** Update `TaggingService` unit tests.
  - Test metadata resolution when `tag_ui` is present, absent (falls back to `tag_schema`), and mixed.
  - Include a **negative assertion** that `tag_schema` entries are NOT resolved when `tag_ui` is present — proves tag_ui fully replaces (not merges with) tag_schema.
  - File: `src/app/shared-services/tagging/tagging.service.spec.ts`
- [ ] **3.7** Update `DocShellComponent` unit tests.
  - Test menu building from `tag_ui` and fallback to `tag_schema`.
  - Include a **fallback test**: menu builds from `tag_schema` when `tag_ui` is null.
  - File: `src/app/shared-components/document-shredding/components/document-tagging/doc-shell/doc-shell.component.spec.ts`

---

## Phase Order and Parallelism

### File-touch matrix

| File | Phase 1 | Phase 2 | Phase 3 |
|------|---------|---------|---------|
| `Database/.../init_tagging_tables.sql` | W | | |
| `Database/.../init_tag_configs.sql` | W | | |
| `rohan_api/.../tagConfig.entity.ts` | | W | |
| `rohan_api/.../create-tag-config.dto.ts` | | W | |
| `rohan_api/.../update-tag-config.dto.ts` | | W | |
| `rohan_api/.../tagging.tag-configs.service.ts` | | W | |
| `rohan_api/.../tagging.tag-configs.service.spec.ts` | | W | |
| `rohan_ui/.../tagging.tag-config.types.ts` | | | W |
| `rohan_ui/.../tagging.service.ts` | | | W |
| `rohan_ui/.../tagging.service.spec.ts` | | | W |
| `rohan_ui/.../doc-shell.component.ts` | | | W |
| `rohan_ui/.../doc-shell.component.spec.ts` | | | W |

### Parallelism

- **Phases 2 and 3 could run in parallel** (different repos, no file overlap), but Phase 3 depends on Phase 2's API contract being finalized.
- Recommended order: **Phase 1 → Phase 2 → Phase 3** (sequential, each builds on the previous).

### Rationale

Phase 1 must be first because the DB column must exist before the NestJS entity can reference it (and tests use a real DB schema). Phase 2 must produce the API response including `tag_ui` before the UI can consume it. Phase 3 is the final consumer.

## Phase Context Summaries

**Phase 1** adds the `tag_ui JSONB` nullable column to the `tag_configs` table via `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` (placed before the trigger, right after the table DDL) and populates it in the seed upserts. Each product gets a normalized `{ "tags": [...] }` object with `id`, `name`, and `color` extracted from the existing `tag_schema`, using multi-line formatted JSON for readability. `compliance_response` gets `NULL`. A migration comment notes that `tag_ui` and `tag_schema` display fields must stay in sync during the transition. No dependencies on other phases.

**Phase 2** adds `tag_ui` to the TypeORM `TagConfig` entity as a nullable JSONB column, adds it to both DTOs with `@IsOptional() @IsObject()`, and updates the service's `create()` and `updateById()` methods to handle it. Since the controller returns the raw entity, `tag_ui` automatically appears in API responses. Depends on Phase 1 (column must exist in DB).

**Phase 3** defines the `TagUi` and `TagUiEntry` interfaces in the frontend type file, adds `tag_ui` to `TagConfigResponse`, and updates `TaggingService` and `DocShellComponent` to prefer `tag_ui` for display metadata (labels, colors, menu items) with a fallback to `tag_schema`. Key implementation details from branch comparison: `resolveTagUiMetadata` stores the original `entry.id` (not normalized) for `kindsByType` (consistent with the schema path convention); `DocShellComponent` extracts a `resolveTagUiTags()` helper with trim+filter; error messages reflect the new fallback chain; tests include a negative assertion proving tag_ui fully replaces tag_schema. Depends on Phase 2 (API must return `tag_ui`).

## Jira Ticket Breakdown

### Phase 1 — Database: Add `tag_ui` column and seed data

**Title**: Add `tag_ui` JSONB column to `tag_configs` table

**Description**: Add a nullable `tag_ui` JSONB column to the `tag_configs` table to store UI-specific display metadata (colors, display names) separately from the backend processing `tag_schema`. Populate the column in the seed data for all existing products.

**Acceptance Criteria**:
- `tag_ui` column exists on `tag_configs`, nullable JSONB, placed before the trigger in DDL
- All four product seed rows include `tag_ui` in the upsert
- `template_generator`, `compliance`, `proposal_writer` have normalized `tag_ui.tags[]` with id/name/color (multi-line formatted)
- `compliance_response` has `tag_ui = NULL`
- Migration comment present noting `tag_ui`/`tag_schema` display field sync requirement
- SQL is idempotent (safe to re-run)

### Phase 2 — NestJS: Add `tag_ui` to entity and DTOs

**Title**: Include `tag_ui` in TagConfig entity, DTOs, and API responses

**Description**: Add `tag_ui` to the TypeORM entity and both create/update DTOs so the new column is persisted and returned in all tag config API responses. Update the service and unit tests.

**Acceptance Criteria**:
- `TagConfig` entity includes `tag_ui` as nullable JSONB
- `CreateTagConfigDto` and `UpdateTagConfigDto` accept optional `tag_ui`
- `GET /tagging/tag-configs` and `GET /tagging/tag-configs/:id` responses include `tag_ui`
- `PATCH /tagging/tag-configs/:id` can update `tag_ui`
- Unit tests pass with `tag_ui` coverage

### Phase 3 — Angular: Read display metadata from `tag_ui`

**Title**: Switch UI tagging display to read from `tag_ui`

**Description**: Define `TagUi` types, update `TagConfigResponse`, and modify `TaggingService` and `DocShellComponent` to read display metadata (labels, colors, menu items) from `tag_ui` with a `tag_schema` fallback.

**Acceptance Criteria**:
- `TagUi` and `TagUiEntry` interfaces defined
- `TagConfigResponse` includes `tag_ui: TagUi | null`
- `TaggingService` resolves colors/labels from `tag_ui.tags[]` when present; `kindsByType` stores the original `entry.id` (not normalized)
- `DocShellComponent` builds context menu from `tag_ui.tags[]` via a `resolveTagUiTags()` helper with trim+filter; error messages reflect "tag_ui or tag_schema" fallback chain
- Both fall back to `tag_schema` parsing when `tag_ui` is null
- Unit tests cover both `tag_ui` present and fallback paths, including a negative assertion that tag_schema entries are not resolved when tag_ui is present
