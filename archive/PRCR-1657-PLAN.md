# PRCR-1657 — Acquisition Pathways: add `type` column to `acquisition_missions`

> Jira: <https://rohirrim.atlassian.net/browse/PRCR-1657>
>
> Builds on the **already-shipped** PRCR-1649 surface
> (`archive/PRCR-1649-PLAN.md`, `archive/PRCR-1649-contracts.md`).
> Phase 1 branches from `main` in `rohan_api` — PRCR-1649 phase 1a/1b
> (PRs #1940 / #1941) and phase 2 (PR #2068) are already in `main`.

## Problem statement

PRCR-1649 stood up the `acquisition_missions` table with `mode` and `stage` enums, but every mission today is implicitly "new" — there's no way to distinguish a mission that was freshly drafted from one carried over from a legacy system. Several downstream consumers (missions table badges, the per-type intake flow in the wizard, eventual reporting) need this distinction.

Add a required `type` column to `acquisition_missions` with two values:

| Value | Meaning |
|---|---|
| `'NEW'` | Default. Mission was drafted from scratch in the current product. |
| `'LEGACY'` | Mission was imported / carried over from a prior system. |

Expose the column on every read path (full detail + slim list projection), accept it on `POST` / `PATCH`, and add a `?type=` filter to `GET /missions`. The frontend's mock `Mission` interface and mock data get the new field too so the FE stays in step with the BE shape ahead of the (separate-ticket) UI wire-up.

## Key architectural observations

### The PRCR-1649 surface is the baseline; this ticket is delta-only

The shipped backend lives at `rohan_api-parent/rohan_api/src/acquisition-pathways/` and matches the surface documented in `archive/PRCR-1649-contracts.md` with a few file-naming differences worth noting up front (so the agent doesn't waste a round-trip looking for the planned-but-renamed file):

| Documented in PRCR-1649 contracts | Actually shipped |
|---|---|
| `acquisition-pathways.controller.ts` | `controllers/ap-missions.controller.ts` |
| `acquisition-pathways.service.ts` | `services/ap-missions.service.ts` |
| `acquisition-pathways.constants.ts` | `ap.constants.ts` |
| `acquisition-pathways.errors.ts` | `ap.errors.ts` |
| `dto/create-acquisition-mission.dto.ts` | `dto/missions/create-acquisition-mission.dto.ts` |
| (no shipped equivalent) | `types/run-state.types.ts` |

Every reference in this plan uses the **shipped** path, not the originally-planned one.

### Idempotent SQL pattern: `ALTER TABLE … ADD COLUMN IF NOT EXISTS`

`Database/rohan_api/scripts/sql/init_acquisition_pathways.sql` is re-run on every container boot from `run_all.sql`. The PRCR-1649 author chose `CREATE TABLE IF NOT EXISTS` so the table-creation is a no-op on subsequent boots. The same pattern applies here: append three idempotent statements (`ADD COLUMN IF NOT EXISTS`, `DROP CONSTRAINT IF EXISTS` + `ADD CONSTRAINT`, `CREATE INDEX IF NOT EXISTS`) to the bottom of the existing file rather than introducing a new migration file. This keeps the table's schema in one place — the next reader of `init_acquisition_pathways.sql` can read the full schema without cross-referencing a migration history.

Postgres has no `ADD CONSTRAINT IF NOT EXISTS`, so the constraint is added via `DROP CONSTRAINT IF EXISTS` + `ADD CONSTRAINT`. This is no-op on first boot and idempotent on every subsequent boot.

### DTO validation pattern: `@ValidateIf` (not `@IsOptional`) for `NOT NULL` columns

The shipped `CreateAcquisitionMissionDto` and `UpdateAcquisitionMissionDto` defend against `null`-bypass: `@IsOptional()` skips validation when the value is `null` (or `undefined`), which would let `{ "mode": null }` slip past validation and 500 at INSERT because `mode` is `NOT NULL`. The current code uses `@ValidateIf((_o, v) => v !== undefined)` for `mode` and `attached_files` so that `null` falls through to `@IsIn` / `@IsArray` and is rejected with a 400.

`type` is also `NOT NULL`, so it MUST use the same `@ValidateIf` pattern. The query DTO is different: query strings can't carry a JSON `null`, so `@IsOptional()` is correct there (mirroring the precedent set by procurement-writer's query DTOs).

### Default value lives in SQL, not the entity decorator

The shipped entity has a comment explaining why column defaults are documented only in the SQL migration:

```ts
// Column defaults (`mode = 'drive'`, `attached_files = '[]'::jsonb`,
// `archived = false`) are owned by the SQL migration in the Database
// repo (init_acquisition_pathways.sql). We deliberately do NOT duplicate
// them in the entity decorators here to avoid drift between the two repos.
```

The new `type` column follows the same convention — `DEFAULT 'NEW'` lives in `init_acquisition_pathways.sql`; the entity's `@Column` decorator does not duplicate it.

### Slim list projection MUST include `type`

The PRCR-1649 author explicitly omitted `run_state` and `attached_files` from the list projection because both are JSONB columns that grow large. `type` is the opposite: a fixed-width scalar that the UI needs on every list row (for badges and `?type=` filter UX). Add it to the `LIST_PROJECTION_COLUMNS` constant in `ap-missions.service.ts`.

### Two FE service layers coexist on `origin/main` — Phase 2 touches both

> **Plan-authoring note**: This plan was written against `rohan_ui` commit `45e2a92b1` (`origin/main` as of 2026-06-03). Implementer: verify `git pull` is up-to-date before branching — earlier versions of this plan made an incorrect call about the FE state because the local checkout was 4 commits behind `origin/main` at authoring time.

`rohan_ui/src/app/pages/acquisition-pathways/services/` ships **two parallel service layers** that both need to know about `type`:

1. **Typed BE client** — `services/acquisition-pathways-api.service.ts` (`AcquisitionPathwaysApiService`, `providedIn: 'root'`, 8 typed methods wrapping `RequestService`), shipped in PRCR-1649 Phase 2 (PR #2068). Talks the BE shape: `AcquisitionMission`, `mission_id: number`, `mode: 'drive' | 'auto'`. Has a comprehensive spec at `acquisition-pathways-api.service.spec.ts` with URL/body assertions per method.
2. **UI-prototype mock service** — `services/acquisition-pathways.service.ts` (`AcquisitionPathwaysService`, also `providedIn: 'root'`), added by PRCR-1636 (PR #2071) for the wizard / mission-composer scaffolding work. Talks the UI-prototype shape: `Mission`, `id: string`, `mode: 'manual' | 'auto'`. Returns hardcoded `MOCK_MISSIONS` from `services/mock-data.ts`.

The two **coexist deliberately** — PRCR-1636 added the mock service alongside the typed BE client rather than replacing it. The types file (`types/acquisition-pathways.types.ts`) carries both type families, with a JSDoc comment on `AcquisitionMissionMode` explicitly calling out the intentional split: *"Intentionally distinct from the UI-facing `MissionMode` ('manual' | 'auto') used by the mission-composer / landing scaffold — the UI label was renamed in PRCR-1650 without changing the persisted enum, so the API contract here still uses `'drive'`."*

For this ticket the FE change therefore touches **both** layers:

- **BE-aligned layer**: add `AcquisitionMissionType` + a required `type` field on `AcquisitionMission` (auto-inherits into `AcquisitionMissionListItem` via the existing `Omit<AcquisitionMission, 'run_state' | 'attached_files'>` — `type` is not in the omit list); optional `type?:` on `CreateAcquisitionMissionPayload` and `UpdateAcquisitionMissionPayload`; extend `AcquisitionPathwaysApiService.listMissions()` to accept a `{ type? }` filter and forward it via `RequestService.getWithParams`; extend the spec accordingly and bump its `mockMission` / `mockListItem` fixtures to satisfy the now-required field.
- **UI-prototype layer**: add the same `AcquisitionMissionType` value to a required `type` field on `Mission` and an optional `type?:` field on `CreateMissionPayload`; bump `MOCK_MISSIONS` rows; thread `type?:` through `AcquisitionPathwaysService.getMissions(type?)`; fix the one component-spec fixture (`ap-missions-table.component.spec.ts`) that constructs `Mission` literals.

The two layers share **one** `AcquisitionMissionType = 'NEW' | 'LEGACY'` union — the type values are identical on both sides (unlike `mode`, where the UI label was renamed). Defining it once in the types file and importing into both service layers keeps the contract symmetric. **No production component / template edits** beyond the spec fixture fix — wiring a `type` badge or `?type=` filter chip into the missions-table is a separate ticket.

## Assumptions

1. **Two values only.** `'NEW'` and `'LEGACY'` — uppercase, mirroring the values the user specified. The CHECK constraint, entity union, DTO `@IsIn`, query DTO `@IsIn`, and FE union all mirror this set exactly. Adding a third value in the future requires touching all five places (plus a data migration if any existing rows need re-classification).
2. **Required column with DB default.** `type` is `NOT NULL DEFAULT 'NEW'` at the database level, so the `ALTER TABLE … ADD COLUMN` backfills every existing row to `'NEW'` and no separate data migration is needed. Clients can omit `type` on `POST` and get `'NEW'` server-side.
3. **`type` is included in the slim list projection.** Per the architectural-observations note above. Excluding it would force a per-row detail fetch any time the UI needs a badge or filter.
4. **`?type=` filter is single-value.** `?type=NEW&type=LEGACY` rejects with a 400. A future ticket can broaden to multi-value with `@IsArray()` if a UI needs both lists composed at once.
5. **No new endpoints.** The two existing list / detail / create / update endpoints absorb the change. No new `GET /missions/types` or similar.
6. **DELETE / state endpoints unchanged.** `DELETE /missions/:id`, `GET /missions/:id/state`, `PUT /missions/:id/state`, `PATCH /missions/:id/state` do not read or write `type`. The `run_state` blob is unrelated to the new column.
7. **No new index beyond the partial one.** `idx_acquisition_missions_org_user_type_active` is `(org_id, user_id, type) WHERE archived = false`. The existing `idx_acquisition_missions_org_user_active` covers queries without the `type` predicate; the new partial index covers the with-`type` path. Both are small (the table is bounded by missions-per-user, which is bounded by users-per-org).
8. **No data migration script.** Backfill is handled by the DB DEFAULT applied at `ADD COLUMN` time. No `UPDATE acquisition_missions SET type = 'NEW' WHERE type IS NULL` step is needed because the column is `NOT NULL DEFAULT 'NEW'` from the moment it's created.
9. **FE service signature changes are forward-compatible on both layers.** The typed BE client (`AcquisitionPathwaysApiService.listMissions`) grows a `filters?: { type? }` arg rather than a positional `type?` arg — so adding `?stage=` / `?mode=` / `?archived=` in a future ticket is a one-line addition to the filter object, not a breaking signature change. The mock service (`AcquisitionPathwaysService.getMissions`) grows a positional `type?` arg because its callers are sparse and the future BE wire-up is a straight `this.apiClient.listMissions({ type })` swap anyway. Existing zero-arg callers of both methods keep compiling.
10. **No UI binding.** No `*.component.ts` / `*.component.html` / `*.component.scss` edits. The missions-table component currently renders mock data and has no `type`-aware affordance; adding one is a separate ticket.
11. **Branch convention.** Phases produce stacked branches: `{user}/PRCR-1657/phase-{N}`. Phase 1 branches off `main` in `rohan_api-parent/rohan_api`; Phase 2 branches off `main` in `rohan_ui-parent/rohan_ui`. Different repos — `depends_on: [1]` captures merge-order coupling, not a git-parent relationship.
12. **PRCR-1649 is already in `main`.** No coordination with PRCR-1649 PR queue. The base for Phase 1 is current `main` in `rohan_api`; the base for Phase 2 is current `main` in `rohan_ui`.

## Open questions

| # | Question | Default |
|---|---|---|
| 1 | Should the `type` field on the FE `Mission` / `AcquisitionMission` interfaces be required (`type:`) or optional (`type?:`)? | **Required on response shapes, optional on request shapes.** The BE column is `NOT NULL`, every BE response carries a value, and a required FE field catches at compile time any consumer that forgets to populate it. This applies to both `Mission` (UI-prototype) and `AcquisitionMission` (BE-aligned). Compile blast radius is three sites — `ap-missions-table.component.spec.ts` `mockMissions`, `acquisition-pathways-api.service.spec.ts` `mockMission` + `mockListItem`, and `services/mock-data.ts` `MOCK_MISSIONS` — all fixed in Phase 2 (steps 2.5, 2.6, 2.10). The matching fields on `Create*Payload` / `UpdateAcquisitionMissionPayload` stay optional because the BE applies a `'NEW'` default when the field is omitted. |
| 2 | Should we add a UI affordance (badge column + filter chip) for `type` in the missions table in this ticket? | **No.** Out of scope. The types + mock data here unblock the UI ticket; bundling the UI work would balloon the diff and force this ticket to touch components that are still actively being scaffolded. |
| 3 | Should the API expose a `GET /acquisition-pathways/missions/types` endpoint that returns the enum membership? | **No.** Two values, hardcoded in `ACQUISITION_MISSION_TYPES` on both sides. An endpoint would mean a network round-trip on every page load for data that changes (at most) annually. If a third value ever lands, the FE bumps its constant in the same PR that ships the BE change. |
| 4 | Should `mode` and `type` share a single Postgres `enum` type instead of separate `varchar` + `CHECK` columns? | **No.** Same answer as the original PRCR-1649 open question about `mode` / `stage`: `varchar` + `CHECK` is cheaper to evolve. `procurements.status` uses the same pattern. |
| 5 | Should we add a Postgres index on `(type)` alone? | **No.** Queries always pair `type` with `org_id` (and usually `user_id` + `archived = false`). The partial composite index `(org_id, user_id, type) WHERE archived = false` covers every plausible query path. A standalone `(type)` index would never be chosen by the planner over the composite. |
| 6 | Should `findOne` / `update` / `remove` / `getState` / `mergeState` accept a `type` predicate too? | **No.** They all key off `mission_id` (PK) and need to read or write whichever `type` the row already has. Adding a `type` filter to those paths would let a caller "lose" a mission by guessing wrong, with no upside. |
| 7 | Should the e2e test cover `?type=NEW` and `?type=LEGACY` separately, or just one? | **Both.** The cost is two extra `it()` blocks; the payoff is catching a future regression where the filter predicate gets dropped or inverted (`!=` vs `=`). |
| 8 | Should the rohan-python-api or ONERING repos see any change? | **No.** Neither reads or writes `acquisition_missions`. The Python services own the per-stage agent loops (which use Service Bus + MinIO, not direct DB access to this table), and the only ONERING entry point is the `arc_agent_writer` CLI which runs against rendered artifacts, not mission rows. |

## Implementation phases

### Phase 1 — Backend: `type` column on `acquisition_missions` [BACKEND_DB]

```phase-meta
phase: 1
title: Acquisition Pathways — add type column + ?type= filter
tags: [BACKEND_DB]
repo: rohan_api
base_branch: main
depends_on: []
files:
  - Database/rohan_api/scripts/sql/init_acquisition_pathways.sql
  - rohan_api-parent/rohan_api/src/acquisition-pathways/entities/acquisition-mission.entity.ts
  - rohan_api-parent/rohan_api/src/acquisition-pathways/dto/missions/create-acquisition-mission.dto.ts
  - rohan_api-parent/rohan_api/src/acquisition-pathways/dto/missions/update-acquisition-mission.dto.ts
  - rohan_api-parent/rohan_api/src/acquisition-pathways/dto/missions/acquisition-mission.dto.ts
  - rohan_api-parent/rohan_api/src/acquisition-pathways/dto/missions/list-acquisition-missions-query.dto.ts
  - rohan_api-parent/rohan_api/src/acquisition-pathways/ap.constants.ts
  - rohan_api-parent/rohan_api/src/acquisition-pathways/services/ap-missions.service.ts
  - rohan_api-parent/rohan_api/src/acquisition-pathways/services/ap-missions.service.spec.ts
  - rohan_api-parent/rohan_api/src/acquisition-pathways/controllers/ap-missions.controller.ts
  - rohan_api-parent/rohan_api/src/acquisition-pathways/controllers/ap-missions.controller.spec.ts
  - rohan_api-parent/rohan_api/test/acquisition-pathways.e2e-spec.ts
contracts:
  - "1.0 SQL DDL — acquisition_missions.type column"
  - "2.0 AcquisitionMission entity — type column"
  - "3.1 CreateAcquisitionMissionDto.type"
  - "3.2 UpdateAcquisitionMissionDto.type"
  - "3.3 ListAcquisitionMissionsQueryDto"
  - "3.4 Response DTOs — type field"
  - "4.1 POST /acquisition-pathways/missions — accepts type"
  - "4.2 GET /acquisition-pathways/missions?type= — list filter"
  - "4.3 GET /acquisition-pathways/missions/:id — returns type"
  - "4.4 PATCH /acquisition-pathways/missions/:id — accepts type"
  - "5.0 Error responses — invalidMissionType constant"
verification:
  - npm run lint
  - npm run format
  - npm run test -- src/acquisition-pathways/services/ap-missions.service.spec.ts
  - npm run test -- src/acquisition-pathways/controllers/ap-missions.controller.spec.ts
  - npm run test:e2e:ci -- --testPathPattern=acquisition-pathways.e2e-spec
```

**Goal**: Add a required `type` column (`'NEW' | 'LEGACY'`, default `'NEW'`) to `acquisition_missions`, surface it on every read path including the slim list projection, accept it on `POST` / `PATCH`, and add a `?type=` query filter to `GET /missions`.

**Steps**:

- [ ] **1.1** Append the three idempotent DDL statements from contracts §1.0 to the **bottom** of `Database/rohan_api/scripts/sql/init_acquisition_pathways.sql`. Do not rewrite the file — the existing `CREATE TABLE` / `CREATE INDEX` / `CREATE TRIGGER` blocks stay as-is. `run_all.sql` already runs this script; no edit needed there.
  - File: `Database/rohan_api/scripts/sql/init_acquisition_pathways.sql`

- [ ] **1.2** Update the entity at `src/acquisition-pathways/entities/acquisition-mission.entity.ts` per contracts §2.0:
  - Export a new `AcquisitionMissionType = 'NEW' | 'LEGACY'` union.
  - Export a new `ACQUISITION_MISSION_TYPES` `as const` array mirroring the CHECK constraint values.
  - Add `@Column({ type: 'varchar', length: 16 }) type: AcquisitionMissionType;` to the `AcquisitionMission` class, placed after `mode`. Do **not** add a `default:` value in the decorator — the DB DEFAULT owns it (see architectural-observations note).
  - File: `rohan_api-parent/rohan_api/src/acquisition-pathways/entities/acquisition-mission.entity.ts`

- [ ] **1.3** Update `dto/missions/create-acquisition-mission.dto.ts` per contracts §3.1:
  - Add `ACQUISITION_MISSION_TYPES` and `AcquisitionMissionType` to the existing import from the entity file.
  - Add the optional `type` field with `@ValidateIf((_o, v) => v !== undefined) @IsIn(ACQUISITION_MISSION_TYPES) @ApiPropertyOptional({ enum: ACQUISITION_MISSION_TYPES, default: 'NEW' })`. Place it alongside `mode`.

- [ ] **1.4** Update `dto/missions/update-acquisition-mission.dto.ts` per contracts §3.2:
  - Add `ACQUISITION_MISSION_TYPES` and `AcquisitionMissionType` to the existing entity import.
  - Re-declare `type` on the class with the same `@ValidateIf` + `@IsIn` pattern used for `mode` (`PartialType`'s auto-applied `@IsOptional` would skip on `null`, which would 500 at the database — see architectural-observations).

- [ ] **1.5** Create the new query DTO at `dto/missions/list-acquisition-missions-query.dto.ts` per contracts §3.3.
  - File: `rohan_api-parent/rohan_api/src/acquisition-pathways/dto/missions/list-acquisition-missions-query.dto.ts`
  - Use `@IsOptional()` (NOT `@ValidateIf`) — query strings can't carry literal `null`, so the only "missing" representation is `undefined` and `@IsOptional()` is the correct match.

- [ ] **1.6** Update both response DTOs in `dto/missions/acquisition-mission.dto.ts` per contracts §3.4:
  - Add `ACQUISITION_MISSION_TYPES` + `AcquisitionMissionType` to the existing entity import.
  - Add `@ApiProperty({ enum: ACQUISITION_MISSION_TYPES }) type: AcquisitionMissionType;` to **both** `AcquisitionMissionResponseDto` and `AcquisitionMissionListItemResponseDto`, placed after `mode` in each.

- [ ] **1.7** Update `ap.constants.ts` per contracts §5.0 — append `invalidMissionType: "type must be one of 'NEW' or 'LEGACY'"` to the end of the `AcquisitionPathwaysErrors` object literal. Do not re-order existing keys.

- [ ] **1.8** Update the service at `services/ap-missions.service.ts` per contracts §4.2:
  - Add `'mission.type'` to the `LIST_PROJECTION_COLUMNS` constant, placed after `'mission.mode'` to mirror the entity column order.
  - Change `findAll(user: User)` to `findAll(user: User, query?: { type?: AcquisitionMissionType })`. Use a `Partial<ListAcquisitionMissionsQueryDto>` shape (or import the DTO and use it directly) so the call site is type-safe.
  - Inside `findAll`, after the `archived` `andWhere`: if `query?.type` is set, append `qb.andWhere('mission.type = :type', { type: query.type })`. Keep the existing admin-vs-non-admin user-scope branch unchanged — `type` composes with both branches.
  - Import `AcquisitionMissionType` from the entity file.
  - Do **not** change `create`, `findOne`, `update`, `remove`, `getState`, `replaceState`, or `mergeState` — the `type` field flows through `create` via TypeORM's `repository.create({ ...dto, ... })` spread, and `update` flows it through `repository.merge(mission, dto)` similarly.

- [ ] **1.9** Update the controller at `controllers/ap-missions.controller.ts` per contracts §4.2:
  - Import `ListAcquisitionMissionsQueryDto`.
  - Change `findAll(@Request() req)` to `findAll(@Query() query: ListAcquisitionMissionsQueryDto, @Request() req)`. The class-level `ValidationPipe` already applies `whitelist: true, forbidNonWhitelisted: true, transform: true`, so unknown keys (`?typo=NEW`) reject with a 400 and `query.type` is typed correctly.
  - Pass `query` through to `this.apMissionsService.findAll(req.user, query)`.
  - Add `@ApiQuery({ name: 'type', enum: ACQUISITION_MISSION_TYPES, required: false })` above the existing `@ApiOperation` on `findAll` so Swagger documents the new param. Import `ApiQuery` from `@nestjs/swagger` and `ACQUISITION_MISSION_TYPES` from the entity file.
  - No edits to `create`, `findOne`, `update`, `remove`, `getState`, `replaceState`, or `mergeState`. The DTO changes flow through automatically.

- [ ] **1.10** Extend `services/ap-missions.service.spec.ts` (do **not** rewrite — append to existing describes):
  - In the `create` describe: one `it` that `create` returns a row with `type` echoed from the DTO; one `it` that `create` accepts `'LEGACY'`; the existing happy-path assertion that builds a default mission gets its `type` property tightened (the `buildMission` helper at the top of the file gains a `type: 'NEW'` default so every downstream test that doesn't care about `type` still type-checks).
  - In the `findAll` describe: one `it` per filter case — `{ type: 'NEW' }` adds the predicate; `{ type: 'LEGACY' }` adds the predicate; no `query` arg / `{}` / `{ type: undefined }` skips the predicate. Assert the call goes through `listQueryBuilder.andWhere('mission.type = :type', { type: ... })`.
  - In the `findAll` describe: assert `LIST_PROJECTION_COLUMNS` (now exported, or asserted via `listQueryBuilder.select` mock call args) includes `'mission.type'`.
  - In the `update` describe: one `it` that `update({ type: 'LEGACY' })` flows through `repository.merge` + `repository.save`.
  - No new `replaceState` / `mergeState` / `getState` tests — none of them touch `type`.

- [ ] **1.11** Extend `controllers/ap-missions.controller.spec.ts`:
  - Add a `findAll` `it` that calls the controller method with `{ type: 'NEW' }` and asserts the service is called with `(req.user, { type: 'NEW' })`.
  - Add an integration-level `it` (using `Test.createTestingModule` + `app.init`) that issues `GET /acquisition-pathways/missions?type=BOGUS` and asserts a 400 — the class-level `ValidationPipe` produces this before the service runs.
  - Add the same shape `GET /acquisition-pathways/missions?typo=NEW` 400 test (unknown query key).
  - In the `create` describe: one `it` that the controller passes a body with `type: 'LEGACY'` through to `apMissionsService.create`.
  - In the `update` describe: same for `PATCH`.
  - Use the existing service stub — don't introduce a new mock pattern.

- [ ] **1.12** Add DTO-level specs (new files):
  - `dto/missions/create-acquisition-mission.dto.spec.ts` — `class-validator` test: valid `'NEW'`, valid `'LEGACY'`, invalid `'OTHER'` → 1 error, explicit `null` → 1 error, omitted → 0 errors.
  - `dto/missions/update-acquisition-mission.dto.spec.ts` — same shape.
  - `dto/missions/list-acquisition-missions-query.dto.spec.ts` — omitted passes; `'NEW'` / `'LEGACY'` pass; `'OTHER'` fails; empty string `''` fails; extra key passes at DTO level (whitelist is a controller-pipe behaviour, not a DTO behaviour).
  - Each spec uses `plainToInstance(Dto, payload)` + `validate(...)` — mirror the pattern from the existing `acquisition-mission-state.dto.spec.ts` (if present) or `procurement-writer`'s DTO specs.

- [ ] **1.13** Extend `test/acquisition-pathways.e2e-spec.ts`:
  - Inside the existing "Happy path" describe, append: one `it` that `POST /missions` with `{ type: 'LEGACY' }` round-trips and `GET /missions/:id` returns the same `type`. Capture the returned `mission_id` and push to `createdMissionIds` for teardown.
  - Add a new describe `'?type= filter'`: `beforeAll` creates two missions (one default `'NEW'`, one explicit `'LEGACY'`), then three `it` blocks:
    1. `GET /missions?type=NEW` returns the NEW mission and excludes the LEGACY mission.
    2. `GET /missions?type=LEGACY` returns the LEGACY mission and excludes the NEW mission.
    3. `GET /missions?type=BOGUS` returns 400.

- [ ] **1.14** Run the verification commands from the phase-meta block. If `npm run test:e2e:ci` requires Docker (it does — boots Postgres), verify Docker is running before invoking.

---

### Phase 2 — Frontend: type system + mock service `?type=` arg [FRONTEND]

```phase-meta
phase: 2
title: Acquisition Pathways — FE type column across typed BE client + mock service
tags: [FRONTEND]
repo: rohan_ui
base_branch: main
depends_on: [1]
files:
  - rohan_ui-parent/rohan_ui/src/app/pages/acquisition-pathways/types/acquisition-pathways.types.ts
  - rohan_ui-parent/rohan_ui/src/app/pages/acquisition-pathways/services/acquisition-pathways-api.service.ts
  - rohan_ui-parent/rohan_ui/src/app/pages/acquisition-pathways/services/acquisition-pathways-api.service.spec.ts
  - rohan_ui-parent/rohan_ui/src/app/pages/acquisition-pathways/services/acquisition-pathways.service.ts
  - rohan_ui-parent/rohan_ui/src/app/pages/acquisition-pathways/services/mock-data.ts
  - rohan_ui-parent/rohan_ui/src/app/pages/acquisition-pathways/components/missions-table/ap-missions-table.component.spec.ts
contracts:
  - "6.0 Shared FE union — AcquisitionMissionType"
  - "6.1 BE-aligned FE types — type field"
  - "6.2 UI-prototype FE types — type field"
  - "7.1 AcquisitionPathwaysApiService.listMissions(filters?) — typed BE client"
  - "7.2 AcquisitionPathwaysService.getMissions(type?) — mock service"
verification:
  - npm run lint
  - npm run test:ci -- --include='src/app/pages/acquisition-pathways/**/*.spec.ts'
```

**Goal**: Add a single `AcquisitionMissionType` union shared by both FE service layers (typed BE client + UI-prototype mock), thread `type` through every typed payload + mock fixture + service signature on both layers, and fix the one component-spec fixture broken by tightening `Mission.type` to required.

> **Implementer pre-step**: verify `git pull` is up-to-date with `origin/main` before branching. This plan was authored against `origin/main` commit `45e2a92b1` and references files that may not exist on a stale local checkout (notably `acquisition-pathways-api.service.ts` — see "Two FE service layers" architectural-observation above).

**Steps**:

- [ ] **2.1** Update `src/app/pages/acquisition-pathways/types/acquisition-pathways.types.ts` per contracts §6.0:
  - Add the `AcquisitionMissionType` union and `ACQUISITION_MISSION_TYPES` const at the top of the file, just above the existing `AcquisitionRunState` block (so both type families can import it from a single anchor near the top).
  - Document inline that this union is shared by both service layers (the typed BE client AND the UI-prototype mock) — the type values are identical on both sides (unlike `mode`, which has the `'drive' / 'manual'` split), so a single union covers both.

- [ ] **2.2** Update the BE-aligned types in the same file per contracts §6.1:
  - Add a **required** `type: AcquisitionMissionType` field to `AcquisitionMission`, placed between `mode` and `stage` (mirrors the entity column order in `acquisition-mission.entity.ts`).
  - **`AcquisitionMissionListItem` inherits automatically.** The existing definition is `Omit<AcquisitionMission, 'run_state' | 'attached_files'>`. Since `type` is NOT in the omit list, the new field auto-propagates — no edit needed. **Do NOT** rewrite the alias to a direct field list; the `Omit` form is the contract.
  - Add an **optional** `type?: AcquisitionMissionType` field to `CreateAcquisitionMissionPayload`, placed after `mode`. Document inline that the BE applies a `'NEW'` default when omitted (mirrors the BE DTO).
  - Add an **optional** `type?: AcquisitionMissionType` field to `UpdateAcquisitionMissionPayload`, placed after `mode`. (No `null` semantics — the BE column is `NOT NULL`; omitting the field skips the update.)

- [ ] **2.3** Update the UI-prototype types in the same file per contracts §6.2:
  - Add a **required** `type: AcquisitionMissionType` field to the existing `Mission` interface, placed between `mode` and `status`. (Required because the BE-side `AcquisitionMission` is required; mirroring the contract avoids a "one shape lies about the other" situation if/when this interface is reconciled to the BE shape.)
  - Add an **optional** `type?: AcquisitionMissionType` field to the existing `CreateMissionPayload` interface, placed after `mode`. Same rationale as §6.1 — BE applies a default.
  - Do **not** touch `AcquisitionPathway`, `RequirementsRecordSummary`, `ApWizardStepMeta`, or any other existing interface in the file.

- [ ] **2.4** Update the typed BE client at `services/acquisition-pathways-api.service.ts` per contracts §7.1:
  - Import `AcquisitionMissionType` from the types file.
  - Import `HttpParams` from `@angular/common/http`.
  - Change `listMissions(): Observable<AcquisitionMissionListItem[]>` to `listMissions(filters?: { type?: AcquisitionMissionType }): Observable<AcquisitionMissionListItem[]>`. (Pass a `filters` object — not a positional `type` arg — so the signature is forward-compatible with adding `stage`, `mode`, `archived`, etc. in a future ticket without breaking callers.)
  - When `filters?.type` is present, build `new HttpParams().set('type', filters.type)` and call `this.request.getWithParams(BASE_PATH, params)` (already shipped on `RequestService` for exactly this case — verified at `shared-services/request/request.service.ts`). When `filters?.type` is absent, keep the existing `this.request.get(BASE_PATH)` call. The `.pipe(map(res => res as AcquisitionMissionListItem[]))` cast stays.
  - Do **not** touch `getMission`, `createMission`, `updateMission`, `deleteMission`, `getMissionState`, `replaceMissionState`, or `patchMissionState`. The DTO changes (steps 2.2 / 2.3) flow through them automatically because they accept and return the typed payloads.

- [ ] **2.5** Update the typed BE client spec at `services/acquisition-pathways-api.service.spec.ts` per contracts §7.1:
  - Bump the `mockMission: AcquisitionMission` literal at the top of the file to include `type: 'NEW'` (required-field compile break — same fix as the component-spec fixture in step 2.10).
  - Bump the `mockListItem: AcquisitionMissionListItem` literal to include `type: 'NEW'`.
  - **Rewrite** the existing `'listMissions calls GET /acquisition-pathways/missions'` `it` to handle the new signature. Two `it` blocks:
    1. `listMissions()` with no filter — still calls `requestSpy.get(BASE_PATH)`. The existing assertion stands.
    2. `listMissions({ type: 'LEGACY' })` — calls `requestSpy.getWithParams(BASE_PATH, paramsMatcher)` where `paramsMatcher.toString() === 'type=LEGACY'`. The cleanest assertion is `expect(requestSpy.getWithParams).toHaveBeenCalledOnceWith(BASE_PATH, jasmine.any(HttpParams))` followed by an `expect(call.args[1].get('type')).toBe('LEGACY')` to verify the param key/value.
  - Add `getWithParams` to the `jasmine.createSpyObj<RequestService>('RequestService', [...])` array (alongside the existing `get`, `post`, `patch`, `put`, `delete`).
  - The existing `BASE_PATH resolves to the literal …` test calls `service.listMissions()` (no arg) — leave it as-is; it still exercises the unfiltered code path.
  - The runtime-cast-safety tests for `listMissions` (`returns null when RequestService.get emits null`) stay as-is — they exercise the no-arg branch.
  - Update the `createMission` / `updateMission` `it` blocks to set `type: 'NEW'` (or `'LEGACY'`) in the test payloads so the BE-aligned DTO compiles; assert that the field is forwarded in `requestSpy.post` / `requestSpy.patch` call args. (Tiny addition — the existing tests stay structurally the same.)

- [ ] **2.6** Update `services/mock-data.ts` per contracts §7.2:
  - Add an explicit `type: 'NEW'` to every row in `MOCK_MISSIONS`, except change one row (author's pick — the most "demo-friendly" candidate) to `type: 'LEGACY'` so a future filter UI has something to demo. No other fields change.

- [ ] **2.7** Update the UI-prototype mock service at `services/acquisition-pathways.service.ts` per contracts §7.2:
  - Import `AcquisitionMissionType` from the types file.
  - Change `getMissions(): Observable<Mission[]>` to `getMissions(type?: AcquisitionMissionType): Observable<Mission[]>`. When `type` is passed, return `of(MOCK_MISSIONS.filter(m => m.type === type))`. When omitted, return `of(MOCK_MISSIONS)` as before.
  - Update the existing `// TODO: Replace with actual API call` comment to mention that the future implementation should pass `type` as a query param (matching the typed BE client's `?type=` shape from step 2.4).
  - Inside `createMission`, ensure the returned mock mission carries `payload.type` through, defaulting to `'NEW'` when `payload.type` is `undefined` (mirrors the BE default and satisfies the now-required `Mission.type` field).
  - Do **not** touch `uploadFiles`, `getAuditTrail`, or `loadSampleMission`.

- [ ] **2.8** Extend the mock service spec at `services/acquisition-pathways.service.spec.ts` (create the file if it doesn't exist — at plan-authoring time it does not; mirror the pattern from the sibling `pathway-selection.service.spec.ts`):
  - One `it` that `getMissions()` (no arg) returns the full `MOCK_MISSIONS` array.
  - One `it` that `getMissions('NEW')` returns only NEW-typed missions.
  - One `it` that `getMissions('LEGACY')` returns only LEGACY-typed missions.
  - One `it` that `createMission({ ..., type: 'LEGACY' })` returns a mock mission with `type === 'LEGACY'`.
  - One `it` that `createMission({ ... })` (no `type`) returns a mock mission with `type === 'NEW'`.

- [ ] **2.9** _(reserved — no step here; left to keep the numbering tied to the contracts mapping above.)_

- [ ] **2.10** Fix the component-spec fixture broken by the required-`type` change in step 2.3:
  - File: `src/app/pages/acquisition-pathways/components/missions-table/ap-missions-table.component.spec.ts`.
  - The `mockMissions: Mission[]` literal (two entries: `'Alpha Mission'` and `'Beta Mission'`) MUST gain a `type` line on each. Use `type: 'NEW'` for `'Alpha Mission'` and `type: 'LEGACY'` for `'Beta Mission'` so the fixture covers both values without changing existing assertions.
  - Verify no other consumer constructs a `Mission` or `AcquisitionMission` literal: search both interface names across `src/app/pages/acquisition-pathways/` for object-literal constructions (the typed BE client spec already gets its fixture bumped in step 2.5; the UI-prototype mock-data file already gets bumped in step 2.6; the component spec fixed here is the only other site at plan-authoring time). If a new consumer has landed since this plan was written, fix that file too.

- [ ] **2.11** Run verification commands from the phase-meta block.

## Phase order and parallelism

### File-touch matrix

| File | P1 | P2 |
| ---- | -- | -- |
| `Database/rohan_api/scripts/sql/init_acquisition_pathways.sql` | edit | — |
| `rohan_api/src/acquisition-pathways/entities/acquisition-mission.entity.ts` | edit | — |
| `rohan_api/src/acquisition-pathways/dto/missions/*.ts` (4 files + 1 new) | edit/new | — |
| `rohan_api/src/acquisition-pathways/ap.constants.ts` | edit | — |
| `rohan_api/src/acquisition-pathways/services/ap-missions.service.ts` (+spec) | edit | — |
| `rohan_api/src/acquisition-pathways/controllers/ap-missions.controller.ts` (+spec) | edit | — |
| `rohan_api/test/acquisition-pathways.e2e-spec.ts` | edit | — |
| `rohan_ui/src/app/pages/acquisition-pathways/types/acquisition-pathways.types.ts` | — | edit |
| `rohan_ui/src/app/pages/acquisition-pathways/services/acquisition-pathways-api.service.ts` | — | edit |
| `rohan_ui/src/app/pages/acquisition-pathways/services/acquisition-pathways-api.service.spec.ts` | — | edit |
| `rohan_ui/src/app/pages/acquisition-pathways/services/acquisition-pathways.service.ts` (+ new spec) | — | edit |
| `rohan_ui/src/app/pages/acquisition-pathways/services/mock-data.ts` | — | edit |
| `rohan_ui/src/app/pages/acquisition-pathways/components/missions-table/ap-missions-table.component.spec.ts` | — | edit |

No file is touched by both phases. Different repos, so no git contention.

### Parallelism

**Sequential, but Phase 2 can start in parallel against the contracts doc.** The FE union (`'NEW' | 'LEGACY'`) is locked in §6.0 and won't change; an author can write Phase 2 against the contracts before Phase 1 merges. The PR must hold until Phase 1 is in `main` and a staging deploy has confirmed the column ships in API responses — otherwise the FE could ship with a typed field the BE doesn't populate yet.

### Recommended order

1. **Phase 1** (`rohan_api`) — single-PR SQL + entity + DTOs + service + controller + tests.
2. **Phase 2** (`rohan_ui`) — single-PR FE type + mock data + mock service signature + service spec.

## Phase context summaries

**Phase 1 — Backend: `type` column + `?type=` filter.** Adds a required `type` column (`varchar(16) NOT NULL DEFAULT 'NEW'` with CHECK constraint `('NEW', 'LEGACY')`) to the existing `acquisition_missions` table by appending three idempotent statements (`ADD COLUMN IF NOT EXISTS`, `DROP/ADD CONSTRAINT`, `CREATE INDEX IF NOT EXISTS`) to `init_acquisition_pathways.sql`. Updates the entity to add `AcquisitionMissionType` + `ACQUISITION_MISSION_TYPES` exports and a new `@Column` on `AcquisitionMission`. DTOs: `CreateAcquisitionMissionDto` and `UpdateAcquisitionMissionDto` gain an optional `type` field guarded with `@ValidateIf((_o, v) => v !== undefined) @IsIn(...)` (NOT `@IsOptional` — see gotcha (a)); response DTOs (`AcquisitionMissionResponseDto`, `AcquisitionMissionListItemResponseDto`) gain a required `type`; new `ListAcquisitionMissionsQueryDto` introduces the `?type=` query param. Service: adds `'mission.type'` to `LIST_PROJECTION_COLUMNS` and a second arg `query?: { type?: AcquisitionMissionType }` to `findAll`, with an `andWhere` clause composed onto the existing org+user+archived predicate. Controller: `findAll` gains `@Query() query: ListAcquisitionMissionsQueryDto` plus an `@ApiQuery` annotation. Constants: append `invalidMissionType` literal to `AcquisitionPathwaysErrors`. Tests: service spec gets per-filter `findAll` cases + `create`/`update` round-trip + `LIST_PROJECTION_COLUMNS` assertion; controller spec gets `?type=`-passthrough + `?type=BOGUS` 400 + `?typo=NEW` 400; DTO specs cover each `class-validator` boundary; e2e gets `LEGACY` create round-trip + two filter cases + invalid-value 400. Depends on nothing. Gotchas: (a) **`@ValidateIf((_o, v) => v !== undefined)` not `@IsOptional()`** on the request-body DTOs — `@IsOptional()` skips on `null` and would let `{ "type": null }` 500 at the database (the same gotcha already documented for `mode` and `attached_files` in the shipped code); (b) the query DTO uses `@IsOptional()` because query strings can't carry literal JSON `null`; (c) **`type` must be in the slim list projection** — it's a fixed-width scalar the UI needs on every row for badges and the `?type=` filter affordance, unlike `run_state` / `attached_files` which are intentionally excluded; (d) the DB DEFAULT (`'NEW'`) owns the default — do not duplicate it in the `@Column` decorator (existing entity comments document this convention); (e) the CHECK constraint is added via `DROP CONSTRAINT IF EXISTS` + `ADD CONSTRAINT` because Postgres has no `ADD CONSTRAINT IF NOT EXISTS`; (f) the partial index is `WHERE archived = false` to keep it lean for the common predicate.

**Phase 2 — Frontend: type column across both FE service layers.** The FE on `origin/main` ships **two parallel service layers** (typed BE client `AcquisitionPathwaysApiService` from PRCR-1649 Phase 2, plus UI-prototype mock `AcquisitionPathwaysService` from PRCR-1636); both must learn about `type` in this ticket. Adds a single `AcquisitionMissionType = 'NEW' | 'LEGACY'` union + `ACQUISITION_MISSION_TYPES` const at the top of `types/acquisition-pathways.types.ts`, shared by both layers (the type values are identical on both sides — unlike `mode`, which has the documented `'drive' / 'manual'` split). BE-aligned types gain `type`: required on `AcquisitionMission`; **auto-inherited** by `AcquisitionMissionListItem` via the existing `Omit<AcquisitionMission, 'run_state' | 'attached_files'>` definition (no edit to the alias); optional on `CreateAcquisitionMissionPayload` and `UpdateAcquisitionMissionPayload`. UI-prototype types gain `type`: required on `Mission`, optional on `CreateMissionPayload`. Typed BE client `listMissions()` grows a forward-compatible `filters?: { type?: AcquisitionMissionType }` arg that builds an `HttpParams` and routes through `RequestService.getWithParams` when a filter is present (and the existing `request.get` when it isn't); the spec adds `getWithParams` to its `createSpyObj`, splits the `listMissions` test into filtered + unfiltered cases, and bumps `mockMission` / `mockListItem` fixtures with `type: 'NEW'`. Mock-prototype `getMissions(type?)` does an in-memory filter; `createMission` defaults the returned mission's `type` to `'NEW'` when omitted (mirrors the BE default and satisfies the now-required field); new spec covers four branches. `MOCK_MISSIONS` rows all get an explicit `type` (one `'LEGACY'` for demo). Fixes the one external consumer that constructs a `Mission` literal: `ap-missions-table.component.spec.ts` `mockMissions` (one entry `'NEW'`, one `'LEGACY'`). **No production component / template edits** — wiring a `?type=` filter chip or `NEW`/`LEGACY` badge column into the missions table is a separate ticket. Depends on Phase 1 being deployable. Gotchas: (a) **two FE service layers exist on `origin/main` and both must be updated** — the typed BE client (PRCR-1649 Phase 2, BE-shape: `mission_id: number`, `mode: 'drive' | 'auto'`) and the UI-prototype mock (PRCR-1636, UI-shape: `id: string`, `mode: 'manual' | 'auto'`); touching only one leaves the other layer typed-incorrectly for the future BE wire-up; (b) **`AcquisitionMissionListItem` is `Omit<AcquisitionMission, 'run_state' | 'attached_files'>` and auto-inherits `type`** — do NOT rewrite it as a direct field list, and do NOT add `'type'` to the omit list (it must ship in the slim list projection per the Phase 1 contract); (c) **response shapes are required, request shapes are optional** on the new `type` field — `AcquisitionMission` and `Mission` are required because the BE column is `NOT NULL`; `Create*Payload` and `Update*Payload` are optional because the BE applies a `'NEW'` default when omitted; (d) the FE `ACQUISITION_MISSION_TYPES` const must mirror the BE constant of the same name exactly — they're independently authored but semantically linked (no shared schema package), so changing one without the other is the most likely future regression; (e) `listMissions(filters)` takes a `filters` object — not a positional `type` arg — so the next ticket that adds `?stage=` / `?mode=` / `?archived=` filters is a one-line addition instead of a signature change; (f) `RequestService.getWithParams(pathname, HttpParams)` is already shipped on `origin/main` (`shared-services/request/request.service.ts`); do NOT introduce a new `RequestService.getWithQuery(pathname, Record<string,string>)` or similar — reuse the existing API; (g) `getMissions(type?)` in the mock uses strict equality — a future row that lands without an explicit `type` would silently be excluded from both filters; the required-`type` interface eliminates this risk at compile time for in-process literals; (h) blast radius of making `Mission` / `AcquisitionMission` `type` required is three known sites: `ap-missions-table.component.spec.ts`, `acquisition-pathways-api.service.spec.ts` (`mockMission` + `mockListItem`), and `mock-data.ts`. Step 2.10 says to re-scan in case a new consumer landed.

## Branching convention

```
{user}/PRCR-1657/phase-{N}
```

- Phase 1 branches off `main` in `rohan_api-parent/rohan_api`. PRCR-1649 phases 1a/1b (PRs #1940 / #1941) are already in `main`.
- Phase 2 branches off `main` in `rohan_ui-parent/rohan_ui`. PRCR-1649 phase 2 (PR #2068, commit `403e0cb7b`) is in `main` and shipped the typed `AcquisitionPathwaysApiService`; PRCR-1636 (PR #2071) added the UI-prototype `AcquisitionPathwaysService` mock **alongside** it (not as a replacement). Phase 2 of THIS ticket touches **both** service layers — see the "Two FE service layers coexist on `origin/main`" architectural-observations note for the full layout. Implementer: verify `git pull` is up-to-date with `origin/main` before branching; this plan was authored against `origin/main` commit `45e2a92b1`.

Different repos for the two phases, so `depends_on: [1]` in the Phase 2 metadata captures **merge-order coupling**, not a git-parent relationship. Phase 2 PR can open in parallel against the contracts doc, but must not merge until Phase 1 has shipped to `main` and a staging deploy has confirmed the column ships in API responses.

## Future-tickets backlog (informational, NOT in scope here)

For context so reviewers understand where this slots in. None of these are implemented in PRCR-1657.

| Follow-up | What it adds | Why deferred |
|---|---|---|
| **PRCR-XXXX — FE missions table type affordance** | Add a `type` badge column and a `NEW` / `LEGACY` filter chip / toggle to the missions-table component (`pages/acquisition-pathways/components/missions-table/`). Wire `getMissions(type)` to the chip state. | UI work, separate skill set, distinct review surface. The types + mock data here unblock it. |
| **PRCR-XXXX — Real BE client for `AcquisitionPathwaysService`** | Replace the mock implementation with the real `RequestService` calls, aligning the FE `Mission` interface to the BE `AcquisitionMission` shape (rename `id: string → mission_id: number`, `mode: 'manual' → 'drive'`, etc.). Tighten `type?:` to `type:`. | The mock-vs-BE interface drift was deliberately introduced by PRCR-1636 to unblock prototype scaffolding; alignment is a non-trivial cross-component refactor and out of scope here. |
| **PRCR-XXXX — Multi-value `?type=` filter** | Broaden the query DTO to accept `?type=NEW&type=LEGACY` (array form) so a UI that needs both lists composed at once can fetch them in one call. | No UI need yet; trivial to add when one materializes (`@IsArray() @IsIn(..., { each: true })`). |
| **PRCR-XXXX — Mission `type` analytics / reporting** | Group-by `type` in any future admin dashboard or org-level rollup. | Premature; no admin dashboard reads this column yet. |

## Jira ticket

**Title**: `[PRCR-1657] Acquisition Pathways — add type column ('NEW' | 'LEGACY') to missions`

**Description**:

> Add a required `type` column to `acquisition_missions` so missions can be classified as freshly-drafted (`'NEW'`) vs imported from a prior system (`'LEGACY'`). Backfilled to `'NEW'` for every existing row via a DB DEFAULT applied at `ADD COLUMN` time — no data migration needed.
>
> Adds the column on every read path including the slim list projection (`type` is a small scalar that drives badges + filter UX; unlike `run_state` / `attached_files` it should not be omitted from the list). Accepts `type` on `POST` and `PATCH` with `@ValidateIf` + `@IsIn` validation (the `@IsOptional`-bypass-`null` gotcha already documented for `mode` applies here too). Adds a single-value `?type=` query filter to `GET /missions`, validated by a new dedicated query DTO.
>
> Frontend change is minimal: an `AcquisitionMissionType` union + optional `Mission.type` field + bumped `MOCK_MISSIONS` + `getMissions(type?)` signature. **No component / template edits** — wiring a `type` badge / filter chip into the missions-table component is a separate ticket so this slice stays small.
>
> Builds on the already-shipped PRCR-1649 surface — both phases branch off `main`.

**Acceptance criteria**:

- [ ] **Phase 1** — `acquisition_missions` table has a `type varchar(16) NOT NULL DEFAULT 'NEW'` column with a `CHECK (type IN ('NEW', 'LEGACY'))` constraint, applied via idempotent `ALTER TABLE` statements appended to `init_acquisition_pathways.sql`. The `AcquisitionMission` entity, `Create/Update/List` DTOs, and both response DTOs carry the new field. `POST /acquisition-pathways/missions` accepts `type` (defaults `'NEW'` server-side when omitted, rejects `null` and out-of-enum values with 400). `PATCH /acquisition-pathways/missions/:id` accepts `type` (same validation). `GET /acquisition-pathways/missions?type=NEW` and `?type=LEGACY` filter correctly; `?type=BOGUS` and `?typo=NEW` both 400 before reaching the service. `GET /acquisition-pathways/missions` (no filter) returns both types with `type` populated on every row in the slim projection. `GET /acquisition-pathways/missions/:id` returns `type` in the full row. Service unit tests pass (per-filter `findAll` branches + `create` + `update` round-trip + list projection includes `type`). Controller unit tests pass (`?type=` passthrough + validation 400s + `POST` / `PATCH` round-trip). DTO unit tests pass (`@IsIn` boundary cases). E2E test passes (`POST { type: 'LEGACY' }` round-trip + two filter cases + invalid-value 400). `npm run lint` and `npm run format` pass.
- [ ] **Phase 2** — `pages/acquisition-pathways/types/acquisition-pathways.types.ts` exports `AcquisitionMissionType` + `ACQUISITION_MISSION_TYPES` (shared by both FE service layers). BE-aligned types: `AcquisitionMission` gains required `type`; `AcquisitionMissionListItem` auto-inherits via the existing `Omit` definition (no edit); `CreateAcquisitionMissionPayload` and `UpdateAcquisitionMissionPayload` gain optional `type?`. UI-prototype types: `Mission` gains required `type`, `CreateMissionPayload` gains optional `type?`. `AcquisitionPathwaysApiService.listMissions(filters?: { type? })` routes through `RequestService.getWithParams` when `filters.type` is present and through `RequestService.get` otherwise; spec covers both branches plus the bumped `mockMission` / `mockListItem` / `createMission` / `updateMission` fixtures. `AcquisitionPathwaysService.getMissions(type?)` filters the mock array and `createMission` defaults `type` to `'NEW'` when omitted; new mock-service spec covers the four branches. `MOCK_MISSIONS` rows all carry an explicit `type`, with at least one `'LEGACY'` entry. `ap-missions-table.component.spec.ts` `mockMissions` literals carry an explicit `type` on every entry. `npm run lint` and `npm run test:ci -- --include='src/app/pages/acquisition-pathways/**/*.spec.ts'` pass.
- [ ] **Manual smoke** — with the `AcquisitionPathways` Postgres flag enabled and a user in an `ACQUISITION_PATHWAYS` RBAC group: `POST /acquisition-pathways/missions` with `{ "name": "Test mission" }` (no `type`) returns a 201 with `"type": "NEW"`; the same POST with `{ "name": "Imported", "type": "LEGACY" }` returns a 201 with `"type": "LEGACY"`. `GET /acquisition-pathways/missions?type=LEGACY` returns only the imported row. `GET /acquisition-pathways/missions` returns both with `type` populated. `PATCH /acquisition-pathways/missions/:id` with `{ "type": "LEGACY" }` flips the type. `PATCH /acquisition-pathways/missions/:id` with `{ "type": null }` returns a 400.
