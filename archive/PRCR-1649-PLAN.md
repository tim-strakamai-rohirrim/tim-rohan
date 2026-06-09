# PRCR-1649 — Acquisition Pathways backend bootstrap

> Jira: <https://rohirrim.atlassian.net/browse/PRCR-1649>

## Problem statement

The **Acquisition Pathways** page exists as a UI scaffold in `rohan_ui` (under `src/app/pages/acquisition-pathways/`) and is fully gated by an existing Postgres feature flag (`AcquisitionPathways`), an existing `acquisition-pathways` permission, and an existing `AuthGuard` segment. **There is no backend.** The page has nothing to call.

The product target — fully scoped in the `UA-Acquisition-Pathways` prototype at `/Users/tim/Documents/code/UA-Acquisition-Pathways` and its [`docs/HANDOFF.md`](file:///Users/tim/Documents/code/UA-Acquisition-Pathways/docs/HANDOFF.md) — is a mission-centric workflow: a CO drafts a mission, Rohan (the LLM agent) drives them through a Requirements Record → Pathway selection → Package Assembly → Integrity Check → Export, and the result is a downloadable package. The prototype runs everything client-side through a Node proxy; production must move state to a DB and tool dispatch to the server.

This ticket lays the **minimum** backend that unblocks every follow-up: a mission resource and a generic per-mission JSON `run_state` blob, exposed as REST. Per-stage tables (canonical-record fields, pathways, findings, ledger, artifacts) and the LLM/agent endpoint are explicitly **out of scope** and left for follow-up tickets.

## Key architectural observations

### How API call topology breaks down in the production target

The prototype's `core/seeds/*.seed.ts` files map 1:1 to per-stage `GET` endpoints in the HANDOFF doc:

| Prototype seed | Future read endpoint |
|---|---|
| `missions.seed.ts` | `GET /api/missions` |
| `canonical-record.seed.ts` | `GET /api/missions/:id/canonical-record` |
| `pathways.seed.ts` | `GET /api/missions/:id/pathways` |
| `findings.seed.ts` | `GET /api/missions/:id/findings` |
| `ledger.seed.ts` | `GET /api/missions/:id/ledger` |
| `artifacts.seed.ts` | `GET /api/missions/:id/artifacts` |
| `interview.seed.ts` | `GET /api/missions/:id/interview` |
| `source-docs.seed.ts` | `GET /api/library/source-docs/:id` |

**These are reads.** They hydrate the UI without invoking the LLM. They are cheap, cacheable, easy to test, and the natural shape for a per-stage page.

The *mutations* that populate those stages (`populate_canonical_record`, `populate_pathways`, `populate_findings`, etc.) are intentionally **NOT separate REST endpoints**. They are **tools dispatched inside a single streaming agent endpoint** — the same shape `rohan_api/src/answer-engine-v2/` already uses today. The client opens an SSE connection, sends a sentinel kickoff (`[RECORD-ANALYSIS]`, `[PATHWAY-ANALYSIS]`, …), and the server-side LangGraph loop streams `text_delta` + `tool_use` events, dispatching tool handlers that write to the DB.

So the production surface is **two distinct shapes, not N**:

1. **Per-stage REST reads** (and minimal mutation endpoints for direct user edits — e.g. "user toggled a finding to dismissed without going through chat"). Cheap to add per-stage.
2. **One streaming agent endpoint** (SSE) whose tool handlers dispatch the heavy population.

### Why this ticket deliberately collapses (1) into a single JSON blob — for now

Modeling per-stage tables before the data shapes are stable will cost more than it saves. The prototype's models (in `core/models/canonical-record.ts`, `pathway.ts`, `finding.ts`, `artifact.ts`, `ledger.ts`) are still evolving as PMs vibe-code against the prototype. Locking them into TypeORM entities + migrations now creates churn every time the prototype shifts.

Instead, this ticket stores all per-stage state as a single `run_state` JSONB column on the `acquisition_missions` row. The UI gets one `GET /missions/:id/state` to hydrate the entire workflow, plus `PUT`/`PATCH` for writes. When the per-stage tables get modelled in a follow-up ticket, the migration is a straight DB-side `INSERT … FROM jsonb_*` extraction; no API contract changes for the read paths because they'll keep returning JSON blobs of the same shape, just sourced from columns.

This is the **same pattern** `procurements.wizard_state JSONB` uses today (`Database/rohan_api/scripts/sql/init_procurements.sql:30`).

### Permission + feature-flag wiring is already done

`Database/rohan_api/scripts/sql/init_organizations.sql:322` seeds:

```sql
('acquisition-pathways', 'ACQUISITION_PATHWAYS', 'Acquisition Pathways'),
```

`Database/rohan_api/scripts/sql/init_featureFlags.sql:20` seeds:

```sql
('AcquisitionPathways'),
```

`rohan_api/src/utils/feature-flags/types/featureFlags.ts` already includes `AcquisitionPathways = 'AcquisitionPathways'`. The frontend `FeatureBlock.ACQUISITION_PATHWAYS` is wired through `FeatureBlockingService` per the merged plan archived at `archive/ROH-XXXX-acquisition-pathways-PLAN.md`.

This ticket reuses all of it. Every endpoint is guarded with:

```ts
@UseGuards(AuthGuard('jwt'), FeatureGuard, PermissionsGuard)
@Features('AcquisitionPathways')
@Permissions('acquisition-pathways')
```

The `@Features` string **must match a `FeatureFlagsEnum` key exactly** (`AcquisitionPathways`, not `ACQUISITION_PATHWAYS`) so that `FeatureGuard.canActivate` resolves it through `FeatureFlagsService.listFeatureFlags()` (the Postgres `feature_flags` row seeded at `init_featureFlags.sql:20`). The screaming-snake string would silently fall through to the Azure `features.json` "paid features" blob lookup instead, which is **not** what `pnpm enable-flag AcquisitionPathways` toggles. The shape mirrors `procurement-writer.controller.ts:65-67` — the only structural divergence is the flag name (procurement-writer's `ACQUISITION_CENTER` is intentionally routed through the Azure blob; this ticket's flag is intentionally routed through Postgres).

### Module shape mirrors `procurement-writer`

Per `CLAUDE.md`: "Prefer using private helper class functions, if they exist, but within reason." The leanest reuse here is to **structurally mirror** `procurement-writer` (a known-good module of the same domain shape — multi-tenant org-scoped resource with a wizard-state JSON column) without sharing any of its services (which carry a lot of Weaviate/Perplexity/Langchain weight that we do not yet need). Once the LLM/agent endpoint lands in a follow-up ticket, that ticket can decide whether to depend on `OpenaiHelpersModule` / `LangchainModule` directly or to share the chat plumbing of `AnswerEngineModuleV2`.

## Assumptions

1. **No LLM, no streaming, no tool dispatch in this ticket.** Pure CRUD + a JSON state blob.
2. **No per-stage tables** (no `acquisition_canonical_record_fields`, `acquisition_pathways`, `acquisition_findings`, etc.). Per-stage modelling is deferred to follow-up tickets after the data shapes settle.
3. **No file upload endpoint.** Attached files are recorded as JSON metadata only on the mission row (filename + size + optional MIME). Actual file ingestion (storage, parsing, extraction) reuses `procurement-writer`'s existing `POST /procurement-writer/:procurement_id/documents` pattern when a future ticket needs it.
4. **No frontend UI binding to the new service in this ticket.** The existing `AcquisitionPathwaysComponent` (empty-search scaffold) stays untouched. A follow-up ticket replaces its empty state with a real mission list once the BE is live.
5. **Mission-level org scoping only.** A mission belongs to one `org_id` + one `user_id` (the creator). Admin users can list every mission in their org (mirrors `procurement-writer.findAll`'s admin branch). No sharing, no cross-user grants in this ticket.
6. **Soft delete via `archived: boolean`** rather than hard delete (matches `procurements.archived`). Soft-deleted missions are excluded from `findAll` by default.
7. **`run_state` is `Record<string, unknown>` on the wire.** No server-side schema validation of its contents. The client (and the future tool handlers) are the source of truth for what keys live inside.
8. **No new Postgres functions or triggers.** Reuse the existing `trigger_set_timestamp()` function (defined globally in `init_procurements.sql:98`) for `updated_on` maintenance.
9. **Branch convention.** Phases produce stacked branches: `{user}/PRCR-1649/phase-{N}`. Phase 1 branches from `develop`; Phase 2 branches from `develop` in `rohan_ui` (different repo, so "stacked" means "merge-order coupled" — Phase 2 cannot deploy until Phase 1 ships).
10. **`:id` path validation uses `ParseIntPipe`.** Every `:id` parameter on this module is decorated `@Param('id', ParseIntPipe) id: number`. Non-integer values 400 with NestJS's default `ParseIntPipe` error before any service code runs. The legacy `@Param('id') id: string` + `+id` + `Number.isNaN(id)` pattern in `procurement-writer.controller.ts` is **not** copied — that pattern is older and noisier. Negative or zero ids are accepted by `ParseIntPipe` but will simply 404 from the repository lookup (no separate "non-positive" 400 in this ticket).
11. **`stage` column is authoritative; `run_state.stage` is forbidden.** The `acquisition_missions.stage` column (with its CHECK constraint) is the single source of truth for which stage the user is on. The `run_state` blob **must not** contain a top-level `stage` key — the service rejects `PUT`/`PATCH /state` bodies whose `run_state` contains `stage` with a 400 (`run_state must not include a 'stage' key — use PATCH /missions/:id`). This prevents two writers from disagreeing on the same datum.
12. **`run_state` writes are wrapped in a single repository transaction.** `replaceState` writes in one `UPDATE`. `mergeState` performs `SELECT … FOR UPDATE` then `UPDATE` inside a `queryRunner.startTransaction()` so concurrent PATCHes cannot lose data via interleaved read-modify-write. This ticket does **not** add an `If-Match`/ETag header or a `version` column — that's deferred — but the row-level lock removes the same-process race that the future LLM agent endpoint would otherwise hit on day one.
13. **List endpoint returns a slim projection.** `GET /missions` omits `run_state` and `attached_files` from the response shape (see contracts §4.2 + §6.0). Both can be large once the agent endpoint lands. Per-row hydration of the full blob is the job of `GET /missions/:id` and `GET /missions/:id/state`.
14. **`findOne` enforces `user_id = user.sub` for non-admins.** Admins (per `AdminService.getMemberRoles`) see any mission in their `org_id`. Non-admins see only missions they created — cross-user reads within the same org return 404, matching the §4.3 "don't leak existence" guarantee. This mirrors the org+user scoping `findAll` already does for non-admins.
15. **No audit-log integration in this ticket.** `acquisition_missions` mutations do **not** write rows to `audit_trail`. A follow-up ticket can opt in once the audit shape stabilizes; explicitly deferred so the slice stays small.
16. **No request-body size override.** The repo's Fastify body limit applies (default 1 MiB). Once the agent endpoint lands and `run_state` payloads grow, a follow-up ticket can bump the per-route limit via Fastify config. Document this so the first oversized PATCH doesn't surprise anyone with a 413.
17. **No throttling / idempotency on POST or state writes.** A double-tapped Create button creates two missions. An autosave loop on `PATCH /state` will hit the DB on every call. The FE is expected to debounce; the BE doesn't enforce. Add `@Throttle()` and idempotency keys in a follow-up only if a real workload demands it.
18. **No HTML sanitization on `name` or `statement`.** Stored verbatim. The FE is responsible for rendering them as text (Angular's default binding is text-safe). Any future surface that uses `innerHTML` or markdown-rendering against these fields must add its own sanitization step.

## Open questions

| # | Question | Default |
|---|---|---|
| 1 | Should `acquisition_missions` have a `title` / `name` separate from `mission_name`? The prototype has only `name`. | Use a single `name` column. Match the prototype. |
| 2 | Should `mode` (`'drive' \| 'auto'`) and `stage` (`'record' \| 'pathways' \| 'interview' \| 'integrity' \| 'export' \| null`) be Postgres `enum` types or just `varchar`? | `varchar` with a `CHECK` constraint. Cheaper to evolve; `procurements.status` does the same. |
| 3 | Should `GET /missions` accept a `?search=` query for name/statement substring filter? | **No** — the existing UI scaffold has a non-functional search bar; wire it up in a follow-up. |
| 4 | Should the list endpoint paginate? | **No** in this ticket. Missions per user will be small in the near term. Add `?offset=&limit=` later when there's evidence we need it. The list endpoint enforces a server-side hard cap of `LIMIT 1000` ordered by `updated_on DESC` as a runaway-query guardrail. |
| 5 | Should `PATCH /missions/:id/state` shallow-merge top-level keys, deep-merge, or just be a `PUT` (full replace)? | Ship **both** `PUT` (full replace) and `PATCH` (shallow top-level merge). The shallow-merge semantics are simple and let the client update one stage's blob without round-tripping the whole state. Both writes are wrapped in a `queryRunner` transaction with a `SELECT … FOR UPDATE` row lock so concurrent PATCHes don't lose data. |
| 6 | Does the FE service need to live under `shared-services/` or under the existing `pages/acquisition-pathways/` folder? | **Page-local** at `pages/acquisition-pathways/services/`. No reuse outside this page yet; promoting to `shared-services/` later is mechanical. |
| 7 | Should the list endpoint accept `?include_archived=true` so a non-admin user can list their own soft-deleted missions to restore them? | **No** in this ticket. The UI to restore archived missions ships with the follow-up UI ticket and can add the query param at the same time. The detail endpoint already returns archived rows, so a user with the id can still restore by `PATCH { "archived": false }`. |
| 8 | Should we return the slim list projection as a separate `AcquisitionMissionListItem` type (omitting `run_state` + `attached_files`) or just return the full row? | **Slim projection**. Per assumption 13. Avoids shipping every mission's full state blob on every page-load. |

## Implementation phases

### Phase 1 — Backend: Acquisition Pathways module + mission CRUD + run_state JSON [BACKEND_DB]

```phase-meta
phase: 1
title: Acquisition Pathways backend module + mission CRUD
tags: [BACKEND_DB]
repo: rohan_api
base_branch: base
depends_on: []
files:
  - Database/rohan_api/scripts/sql/init_acquisition_pathways.sql
  - Database/rohan_api/scripts/run_all.sql
  - rohan_api-parent/rohan_api/src/acquisition-pathways/acquisition-pathways.module.ts
  - rohan_api-parent/rohan_api/src/acquisition-pathways/acquisition-pathways.controller.ts
  - rohan_api-parent/rohan_api/src/acquisition-pathways/acquisition-pathways.controller.spec.ts
  - rohan_api-parent/rohan_api/src/acquisition-pathways/acquisition-pathways.service.ts
  - rohan_api-parent/rohan_api/src/acquisition-pathways/acquisition-pathways.service.spec.ts
  - rohan_api-parent/rohan_api/src/acquisition-pathways/acquisition-pathways.constants.ts
  - rohan_api-parent/rohan_api/src/acquisition-pathways/acquisition-pathways.errors.ts
  - rohan_api-parent/rohan_api/src/acquisition-pathways/entities/acquisition-mission.entity.ts
  - rohan_api-parent/rohan_api/src/acquisition-pathways/dto/acquisition-mission.dto.ts
  - rohan_api-parent/rohan_api/src/acquisition-pathways/dto/create-acquisition-mission.dto.ts
  - rohan_api-parent/rohan_api/src/acquisition-pathways/dto/update-acquisition-mission.dto.ts
  - rohan_api-parent/rohan_api/src/acquisition-pathways/dto/acquisition-mission-state.dto.ts
  - rohan_api-parent/rohan_api/src/acquisition-pathways/types/run-state.types.ts
  - rohan_api-parent/rohan_api/src/app.module.ts
  - rohan_api-parent/rohan_api/test/acquisition-pathways.e2e-spec.ts
contracts:
  - "1.0 SQL DDL — acquisition_missions table"
  - "2.0 AcquisitionMission TypeORM entity"
  - "3.0 DTOs — create / update / state"
  - "4.1 POST /acquisition-pathways/missions"
  - "4.2 GET /acquisition-pathways/missions (slim projection)"
  - "4.3 GET /acquisition-pathways/missions/:id"
  - "4.4 PATCH /acquisition-pathways/missions/:id"
  - "4.5 DELETE /acquisition-pathways/missions/:id"
  - "4.6 GET /acquisition-pathways/missions/:id/state"
  - "4.7 PUT /acquisition-pathways/missions/:id/state"
  - "4.8 PATCH /acquisition-pathways/missions/:id/state"
  - "5.0 Error responses"
verification:
  - npm run lint
  - npm run format
  - npm run test -- src/acquisition-pathways/acquisition-pathways.service.spec.ts
  - npm run test -- src/acquisition-pathways/acquisition-pathways.controller.spec.ts
  - npm run test:e2e:ci -- --testPathPattern=acquisition-pathways.e2e-spec
```

**Goal**: Stand up a new NestJS module at `src/acquisition-pathways/` that exposes mission CRUD and a generic JSON `run_state` read/write surface, gated by the existing `AcquisitionPathways` feature flag + `acquisition-pathways` permission.

**Steps**:

- [ ] **1.1** Create `Database/rohan_api/scripts/sql/init_acquisition_pathways.sql` with the DDL from contracts §1.0. Idempotent (`CREATE TABLE IF NOT EXISTS`, `ADD COLUMN IF NOT EXISTS`). Reuse the existing `trigger_set_timestamp()` function (defined in `init_procurements.sql:98`) for the `updated_on` trigger.
  - File: `Database/rohan_api/scripts/sql/init_acquisition_pathways.sql`

- [ ] **1.2** Wire the new SQL file into the bootstrap order. `Database/rohan_api/scripts/run_all.sql` is a hand-maintained `\i` list (not an auto-glob — verified). Add `\i ./sql/init_acquisition_pathways.sql` immediately after the existing `\i ./sql/init_procurements.sql` line (currently line 12). `entrypoint.sh` does not need editing; it executes `run_all.sql` directly.
  - File: `Database/rohan_api/scripts/run_all.sql`

- [ ] **1.3** Create the entity at `src/acquisition-pathways/entities/acquisition-mission.entity.ts` per contracts §2.0. Single table `acquisition_missions`. No relations.

- [ ] **1.4** Create the DTOs per contracts §3.0:
  - `AcquisitionMissionDto` — full mission shape returned by the service.
  - `CreateAcquisitionMissionDto` — required: `name`; optional: `statement`, `mode`, `attached_files`. No `run_state` on create (defaults to `null`).
  - `UpdateAcquisitionMissionDto` — `PartialType(CreateAcquisitionMissionDto)` + optional `stage`, `archived`.
  - `AcquisitionMissionStateDto` — wraps a generic `run_state: Record<string, unknown>` payload.
  - All with `class-validator` decorators and `@ApiProperty()` for Swagger.

- [ ] **1.5** Create `acquisition-pathways.errors.ts` and `acquisition-pathways.constants.ts`:
  - Errors: `AcquisitionPathwaysError`, `MissionSessionError`, mirroring `ProcurementError` / `SessionError` in `procurement-writer.errors.ts`.
  - Constants: an `AcquisitionPathwaysErrors` `as const` object with one literal string per failure mode — creation, lookup, list, update, delete, invalid id, mission not found, state read/update, `invalidRunState`, and `runStateStageKey` (the rejection message when `run_state` contains a top-level `stage` key). See contracts §5.0 for exact strings.

- [ ] **1.6** Create the service at `src/acquisition-pathways/acquisition-pathways.service.ts`:
  - Injects `Repository<AcquisitionMission>` + `DataSource` (for transactional `mergeState` / `replaceState`) + `AdminService` (for admin detection) + `RohanLogger`.
  - Methods: `create`, `findAll`, `findOne`, `update`, `remove`, `getState`, `replaceState`, `mergeState`. Signatures and behaviours in contracts §4.
  - Org-scoping:
    - `findAll`, `findOne`, `update`, `remove`, `getState`, `replaceState`, `mergeState` all filter `org_id = user.org_id`.
    - `findOne`, `getState`, `replaceState`, `mergeState`, `update`, `remove` **additionally** filter `user_id = user.sub` when the caller is NOT admin (per assumption 14) — cross-user reads within the same org return 404 with `CustomEntityNotFoundError`, satisfying the §4.3 "don't leak existence" rule.
    - `findAll` admin branch mirrors `procurement-writer.service.ts:368-411` (admins see every mission in their org; non-admins see only `user_id = user.sub`).
  - Admin detection: single helper `isAdmin(user: User): Promise<boolean>` that calls `AdminService.getSerialFromIdpId` + `AdminService.getMemberRoles` and checks `roles_name === 'Admin'`. Reuse it everywhere a non-admin scope-narrowing branch is needed. Do not invent a separate helper.
  - `findAll` slim projection: select only the columns documented in contracts §4.2 (omit `run_state`, omit `attached_files`). Use a `createQueryBuilder` projection (matching the procurement-writer pattern) rather than `find()` so unwanted JSONB columns never leave the DB. Append `.limit(1000)`.
  - `findAll` and `findOne` lookup behaviour with respect to `archived`:
    - `findAll` always excludes `archived = true`.
    - `findOne` (and the lookups backing `update`, `remove`, `getState`, `replaceState`, `mergeState`) include archived rows — otherwise a user can't restore via `PATCH { "archived": false }` or read state of an archived mission.
  - Soft delete: `remove` flips `archived = true` (single UPDATE; no row deletion). Returns `{ mission_id, archived: true }` (matches contracts §4.5 — controller does not return the full entity).
  - `update`: rejects bodies that set `mission_id`, `user_id`, `org_id`, `created_on`, `updated_on`, or `run_state` (validation enforced by `UpdateAcquisitionMissionDto`, which does not declare them).
  - `mergeState` performs a **shallow top-level merge** in TypeScript inside a single transaction:
    1. `queryRunner.startTransaction()`.
    2. `SELECT … FOR UPDATE` the row (scoped by org and user-if-non-admin).
    3. Reject if the body's `run_state` contains a `stage` key (per assumption 11) — throw `MissionSessionError(invalidRunStateStageKey)`.
    4. Compute `{ ...current, ...patch }`.
    5. `UPDATE … SET run_state = $merged` and commit.
    - Postgres' `jsonb_set` is intentionally not used here — keep merge semantics in TS so they're trivially testable.
  - `replaceState` also runs inside a transaction with `SELECT … FOR UPDATE` even though the merge step is trivial, so the same `stage`-key rejection and concurrency model apply.

- [ ] **1.7** Create the controller at `src/acquisition-pathways/acquisition-pathways.controller.ts`:
  - `@Controller('acquisition-pathways')` — endpoints become `/acquisition-pathways/missions[/...]`.
  - Every method decorated with `@UseGuards(AuthGuard('jwt'), FeatureGuard, PermissionsGuard)`, `@Features('AcquisitionPathways')` (the literal `FeatureFlagsEnum` key — NOT `ACQUISITION_PATHWAYS`; see the architectural-observations section), `@Permissions('acquisition-pathways')`.
  - Every `:id` path param uses `@Param('id', ParseIntPipe) id: number` (per assumption 10). No manual `Number.isNaN` checks needed in the service — `ParseIntPipe` produces the 400 before the service runs.
  - 8 endpoints per contracts §4.1–§4.8. Each catches service errors and rethrows as `HttpException` with the appropriate status, mirroring `procurement-writer.controller.ts` patterns.
  - `DELETE /:id` returns `{ mission_id, archived: true }` literally — do **not** return the full entity (see contracts §4.5).

- [ ] **1.8** Create the module at `src/acquisition-pathways/acquisition-pathways.module.ts`:
  - `TypeOrmModule.forFeature([AcquisitionMission])`.
  - Imports: `AdminModule` (for admin detection).
  - Controllers: `[AcquisitionPathwaysController]`. Providers: `[AcquisitionPathwaysService]`. Exports: `[TypeOrmModule]` (matches `procurement-writer.module.ts:49`).
  - **Entity registration**: confirm `AcquisitionMission` is picked up by the project's TypeORM `entities` configuration. The repo currently uses `entities: ['dist/**/*.entity{.ts,.js}']`-style globs in `app.module.ts` `TypeOrmModule.forRoot(...)`, so this is a no-op once the file lives under `src/acquisition-pathways/entities/`. If the glob has changed to a hardcoded list (read `app.module.ts` to confirm), append `AcquisitionMission` to it. The repository injection will silently 500 with "No metadata for AcquisitionMission" if missed.

- [ ] **1.9** Register the module in `src/app.module.ts`. Add the import + place it in the `imports` array, alphabetically-near `ProcurementWriterModule`.

- [ ] **1.10** Add `acquisition-pathways.service.spec.ts`:
  - `create` — happy path; verifies `user_id` and `org_id` injection.
  - `findAll` admin — returns every non-archived row in the org; verifies the slim projection (no `run_state`, no `attached_files`).
  - `findAll` non-admin — returns only rows with matching `user_id`; same slim-projection check.
  - `findAll` — `LIMIT 1000` cap is applied.
  - `findOne` admin — can read any mission in the org regardless of `user_id`.
  - `findOne` non-admin — can read own mission; cross-user same-org read throws `CustomEntityNotFoundError`.
  - `findOne` cross-org — throws `CustomEntityNotFoundError`.
  - `findOne` archived — returns the archived row (so detail page can render "archived" state).
  - `update` — happy path returns updated row; rejects updates to `mission_id`/`user_id`/`org_id`/`created_on`/`updated_on`/`run_state` (caught at DTO level — spec the DTO via a separate `class-validator` test).
  - `update archived: false` — restores a soft-deleted mission.
  - `remove` — flips `archived = true`, doesn't delete, returns `{ mission_id, archived: true }`.
  - `getState` — returns `{}` when `run_state IS NULL`, returns the stored object otherwise.
  - `replaceState` — overwrites entirely; verifies `updated_on` advances (trigger).
  - `replaceState` — rejects body whose `run_state` contains a `stage` key with `MissionSessionError`.
  - `mergeState` — shallow-merges (verifies sub-keys NOT in the patch are preserved).
  - `mergeState` — nested replace semantics (`{ pathways: [] }` patch replaces, doesn't deep-merge).
  - `mergeState` — rejects body whose `run_state` contains a `stage` key with `MissionSessionError`.
  - `mergeState` concurrency — two interleaved `mergeState` calls against a shared repository mock that simulates `SELECT … FOR UPDATE` serialization both write — neither loses data. Use a `Promise.all` with a manual barrier mock to assert the second call reads the first call's committed result.
  - Stub the repository (use a `mockRepository` factory similar to other `*.service.spec.ts` files in the repo). Also stub `DataSource.createQueryRunner` for the transactional state writes — the procurement-writer service has no equivalent precedent because it doesn't transact, so mirror the `QueryRunner` mock shape from `compliance/compliance.service.spec.ts` (which does).

- [ ] **1.11** Add `acquisition-pathways.controller.spec.ts`:
  - Verifies routing wiring + that each method calls the corresponding service method with the right args.
  - Verifies `ParseIntPipe` rejects non-integer `:id` with a 400 before the service runs (e.g. `request(app).get('/acquisition-pathways/missions/abc').expect(400)`).
  - Verifies error translation (service throws `AcquisitionPathwaysError` → controller throws `HttpException(..., 500)`; throws `MissionSessionError` → `HttpException(..., 400)`; throws `CustomEntityNotFoundError` → `HttpException(..., 404)`).
  - Verifies `DELETE /:id` controller returns `{ mission_id, archived: true }` exactly — not the full entity.
  - Stub `AcquisitionPathwaysService`.

- [ ] **1.12** Add one e2e happy-path test in `test/acquisition-pathways.e2e-spec.ts` (mirrors the shape of any existing `test/*.e2e-spec.ts`):
  - Boots the test app + Docker Postgres via `npm run test:e2e:ci`'s setup (no extra plumbing).
  - With a seeded JWT and the `AcquisitionPathways` flag enabled at DB level: `POST` → `GET /missions` (asserts the slim shape returns) → `GET /missions/:id` (asserts the full shape) → `PATCH /missions/:id/state` (asserts merge preserves untouched keys) → `GET /missions/:id/state` (asserts the persisted shape).
  - One negative test: cross-user same-org `GET /missions/:id` returns 404 (verifies the `findOne` non-admin scoping from step 1.6).
  - The intent is to catch SQL DDL errors, trigger misfires, and `@Features`/`@Permissions` wiring regressions that mocked unit tests cannot — not full integration coverage.

- [ ] **1.13** Run verification commands from the phase-meta block.

---

### Phase 2 — Frontend: typed Angular API service for the mission resource [FRONTEND]

```phase-meta
phase: 2
title: Acquisition Pathways API service (rohan_ui)
tags: [FRONTEND]
repo: rohan_ui
base_branch: develop
depends_on: [1]
files:
  - rohan_ui-parent/rohan_ui/src/app/pages/acquisition-pathways/services/acquisition-pathways-api.service.ts
  - rohan_ui-parent/rohan_ui/src/app/pages/acquisition-pathways/services/acquisition-pathways-api.service.spec.ts
  - rohan_ui-parent/rohan_ui/src/app/pages/acquisition-pathways/types/acquisition-pathways.types.ts
contracts:
  - "6.0 Frontend types — AcquisitionMission / RunState / DTOs"
  - "7.0 AcquisitionPathwaysApiService interface"
verification:
  - npm run lint
  - npm run test:ci -- --include='src/app/pages/acquisition-pathways/**/*.spec.ts'
```

**Goal**: Give the existing `AcquisitionPathwaysComponent` (and any sibling component a follow-up ticket creates) a typed HTTP service it can inject. No UI binding in this ticket — the service is the seam.

**Steps**:

- [ ] **2.1** Expand `src/app/pages/acquisition-pathways/types/acquisition-pathways.types.ts` (currently holds a placeholder `AcquisitionPathway` type). Replace its content with the types in contracts §6.0: `AcquisitionMission`, `AcquisitionMissionListItem` (a real slim projection — `Omit<AcquisitionMission, 'run_state' | 'attached_files'>`), `AcquisitionRunState`, `CreateAcquisitionMissionPayload`, `UpdateAcquisitionMissionPayload`. Keep the existing `AcquisitionPathway` interface (used by the empty-state component) for now and mark it `@deprecated` — a follow-up ticket can remove it once the component is rewired.

- [ ] **2.2** Create `src/app/pages/acquisition-pathways/services/acquisition-pathways-api.service.ts` per contracts §7.0:
  - `@Injectable({ providedIn: 'root' })`.
  - Injects `RequestService` from `@shared-services/request/request.service`.
  - **`RequestService` generics gap**: `RequestService.get()`, `.post()`, and `.patch()` currently return `Observable<any>` (no generic) while `.put<T>()` and `.delete<T>()` are generic. Don't add generics to `RequestService` itself (out of scope, broad blast radius). Instead, cast the untyped responses inside this service with an explicit `.pipe(map((res) => res as T))` so each public method's return type is honest. Do **not** use `as Observable<T>` on the bare `request.get(...)` call — RxJS operator inference relies on the cast happening on the emitted value, not the stream wrapper.
  - 8 methods, one per BE endpoint. Use `AcquisitionMissionListItem[]` for the list method's return type so consumers know `run_state` / `attached_files` are absent from list rows. All other methods return the full `AcquisitionMission` (or `AcquisitionMissionStatePayload` / `AcquisitionMissionDeleteResponse`).
  - All use the `/acquisition-pathways/missions[...]` paths.

- [ ] **2.3** Create the spec file:
  - One `it()` per public method. Stub `RequestService` and verify URL, verb, and body.
  - Verify the cast on `get`/`post`/`patch` does not throw at runtime when the stubbed response is `null` (mirror how `RequestService`'s underlying `HttpClient` behaves on 204).
  - Do **NOT** add an `it()` that "confirms the service is provided in 'root'". `TestBed.inject(...)` succeeds either way and the test is unenforceable. If we care about the `providedIn: 'root'` invariant, rely on the ESLint/TypeScript layer instead (it's plain decorator metadata).
  - Cover the "not found" / 400 / 500 error mapping if the project has a standard HTTP error interceptor pattern (read a neighbor `*-api.service.spec.ts` first to mirror the pattern). If the project's interceptor swallows errors before the service sees them, document that and skip the error-path tests.

- [ ] **2.4** Do **NOT** modify `AcquisitionPathwaysComponent` or its template in this ticket. The minimum surface is the service. UI wire-up is a deliberate follow-up.

- [ ] **2.5** Run verification commands.

## Phase order and parallelism

### File-touch matrix

| File | P1 | P2 |
| ---- | -- | -- |
| `Database/rohan_api/scripts/sql/init_acquisition_pathways.sql` (new) | new | — |
| `Database/rohan_api/scripts/run_all.sql` | edit | — |
| `rohan_api/src/acquisition-pathways/**` (new module) | new | — |
| `rohan_api/src/app.module.ts` | edit | — |
| `rohan_ui/src/app/pages/acquisition-pathways/services/**` (new) | — | new |
| `rohan_ui/src/app/pages/acquisition-pathways/types/acquisition-pathways.types.ts` | — | edit |

No file is touched by both phases. Phase 1 ships independently; Phase 2 cannot be merged until Phase 1's contract is locked.

### Parallelism

**Sequential.** Phase 2 references endpoints that Phase 1 introduces. Bundling them into one PR would cross two repos (`rohan_api`, `rohan_ui`), which the repo's convention disallows.

If the team wants to **start** Phase 2 in parallel against the contracts doc before Phase 1 merges, that's safe — the API is small enough that drift is unlikely. But the PR must hold until Phase 1 is in `develop` and a staging deploy has confirmed the endpoints respond.

### Recommended order

1. **Phase 1** (`rohan_api`) — single-PR backend module + SQL + tests.
2. **Phase 2** (`rohan_ui`) — single-PR FE service + types + tests.

## Phase context summaries

**Phase 1 — Backend module + mission CRUD + run_state JSON.** New NestJS module at `rohan_api/src/acquisition-pathways/`. Adds one Postgres table `acquisition_missions` via a new idempotent SQL script `Database/rohan_api/scripts/sql/init_acquisition_pathways.sql` (mirrors `init_procurements.sql` shape, reuses the global `trigger_set_timestamp()` trigger). The new script is wired into `Database/rohan_api/scripts/run_all.sql` (a hand-maintained `\i` list — there is no auto-glob). Exposes 8 endpoints under `/acquisition-pathways/missions[/...]`: full CRUD + read/replace/merge of a single JSON `run_state` blob. Reuses the existing `acquisition-pathways` permission (seeded at `init_organizations.sql:322`) and `AcquisitionPathways` Postgres feature flag (seeded at `init_featureFlags.sql:20` and listed in `FeatureFlagsEnum`). Service unit tests cover org+user-scoping, admin branch in `findAll` and `findOne`, soft-delete + restore, JSON merge semantics + concurrency, and `stage`-in-`run_state` rejection. Controller unit tests cover routing, `ParseIntPipe` validation, and error translation. One e2e happy-path test boots the real DB to catch SQL/trigger regressions. Depends on nothing in this ticket. Gotchas: (a) `@Features('AcquisitionPathways')` — literal enum-key, NOT `ACQUISITION_PATHWAYS` (the screaming-snake string would silently bypass the Postgres flag and route through the Azure paid-features blob); (b) the `mergeState` shallow-merge runs inside a `queryRunner` transaction with `SELECT … FOR UPDATE` — keep that lock so multi-tab / agent-vs-user writes don't lose data; (c) `findAll` returns a **slim projection** (no `run_state`, no `attached_files`) capped at `LIMIT 1000`; (d) `findOne` adds a `user_id = user.sub` filter for non-admins so cross-user same-org reads 404; (e) `update`'s lookup must include archived rows so `PATCH { "archived": false }` can restore; (f) `stage` lives on the column, never inside `run_state`; (g) admin detection uses the same `AdminService.getMemberRoles(...).some(r => r.roles_name === 'Admin')` pattern as `procurement-writer.service.ts:368-374` — extract a single `isAdmin(user)` helper rather than inlining 4 copies.

**Phase 2 — Angular API service + types.** Adds `src/app/pages/acquisition-pathways/services/acquisition-pathways-api.service.ts` (`providedIn: 'root'`) with 8 methods, one per BE endpoint. Expands `pages/acquisition-pathways/types/acquisition-pathways.types.ts` to add `AcquisitionMission`, `AcquisitionMissionListItem` (real slim projection, `Omit<AcquisitionMission, 'run_state' | 'attached_files'>`), `AcquisitionRunState`, and create/update payload types. The existing `AcquisitionPathway` placeholder type is kept and marked `@deprecated` so the existing component compiles untouched. **No UI binding** — `AcquisitionPathwaysComponent` is left alone, which is intentional: a follow-up ticket can replace its empty-search scaffold with a real mission list once design has nailed the screen. Depends on Phase 1 being deployable (Phase 2 PR can be opened in parallel, but cannot merge first). Gotchas: (a) `RequestService.get/post/patch` return `Observable<any>` — wrap with `.pipe(map(res => res as T))` rather than casting the stream or expanding `RequestService` itself; (b) the list method's return type must be `AcquisitionMissionListItem[]` so callers know `run_state` and `attached_files` are absent; (c) `AcquisitionRunState` is `Record<string, unknown>` — DO NOT type it as `any`; (d) the spec must cover all 8 methods, not just the ones planned for the next ticket's UI; (e) skip the "service is providedIn root" test — it's unenforceable via `TestBed`.

## Branching convention

```
{user}/PRCR-1649/phase-{N}
```

- Phase 1 branches off `develop` in `rohan_api-parent/rohan_api`.
- Phase 2 branches off `develop` in `rohan_ui-parent/rohan_ui`. Different repo from Phase 1 — `depends_on: [1]` in the phase-meta block captures the **merge-order coupling**, not a git-parent relationship. The Phase 2 PR can open in parallel against the contracts doc, but it must not merge until Phase 1 has shipped to `develop` and the endpoints respond on staging.

## Future-tickets backlog (informational, NOT in scope here)

For context so reviewers understand where this slots in. None of these are implemented in PRCR-1649.

| Follow-up | What it adds | Why deferred |
|---|---|---|
| **PRCR-XXXX — Per-stage tables** | Extract `run_state` into `acquisition_canonical_record_fields`, `acquisition_pathways`, `acquisition_findings`, `acquisition_ledger_entries`, `acquisition_artifacts` tables with per-stage `GET` endpoints. | Premature; let the prototype's data shapes stabilize. The `run_state` blob and the per-stage tables can coexist during migration — the read endpoint shape stays the same. |
| **PRCR-XXXX — File upload** | `POST /acquisition-pathways/missions/:id/documents` for attached mission files, mirroring `POST /procurement-writer/:procurement_id/documents`. | Not blocking; the prototype records file metadata only. Adding file ingestion early ties this ticket to `RfpPythonServerService` for no UI gain. |
| **PRCR-XXXX — LLM/agent endpoint** | `POST /acquisition-pathways/missions/:id/agent` (SSE) implementing the per-phase sentinel-driven flow described in the prototype's [`docs/ROHAN_SPEC.md`](file:///Users/tim/Documents/code/UA-Acquisition-Pathways/docs/ROHAN_SPEC.md). Server-side tool dispatch (`populate_canonical_record`, `populate_pathways`, etc.) writes to per-stage tables. | Largest scope item by far. Should not block read-path development. Will reuse `AnswerEngineModuleV2` patterns and `prompts` table rows for the system prompts. |
| **PRCR-XXXX — Mission documents (uploads, OCR, extraction)** | Real attached-file pipeline through `RfpPythonServerService`, mirroring `procurement-writer.uploadFileForPythonServer`. | Same pattern, same plumbing — should land alongside the agent endpoint so library/source-doc references work. |
| **PRCR-XXXX — UI wire-up** | Replace `AcquisitionPathwaysComponent` empty-search scaffold with a real mission list (cards or table), Create-mission dialog, navigation into per-mission stage pages. | Done after the BE in this ticket lands. |

## Jira ticket

**Title**: `[PRCR-1649] Acquisition Pathways — backend bootstrap (mission CRUD + run_state JSON)`

**Description**:

> Stand up the minimum backend that unblocks every Acquisition Pathways follow-up. Introduce a new NestJS module at `rohan_api/src/acquisition-pathways/` and a single Postgres table `acquisition_missions` keyed by `(org_id, user_id)`. Expose CRUD endpoints plus generic read/replace/shallow-merge endpoints for a per-mission JSON `run_state` blob. Reuse the existing `acquisition-pathways` permission and `AcquisitionPathways` Postgres feature flag (both already seeded in `init_organizations.sql` and `init_featureFlags.sql`). No per-stage tables, no LLM agent endpoint, no file upload, no UI binding — all explicitly deferred to follow-up tickets so this slice stays small enough to land in a single PR per repo.
>
> The prototype at `/Users/tim/Documents/code/UA-Acquisition-Pathways` defines the long-term feature shape. The handoff doc at [`docs/HANDOFF.md`](file:///Users/tim/Documents/code/UA-Acquisition-Pathways/docs/HANDOFF.md) describes the production target. This ticket is intentionally the smallest cut: a mission resource + an opaque state blob. Per-stage modelling and the agent loop are larger, separate tickets.
>
> Ships behind the existing `AcquisitionPathways` Postgres `feature_flags` row — `pnpm enable-flag AcquisitionPathways` per environment to expose, in addition to RBAC group membership with `description: 'ACQUISITION_PATHWAYS'` (the permission `feature` column on `permissions` is unrelated to the Postgres flag and continues to use the screaming-snake form).

**Acceptance criteria**:

- [ ] **Phase 1** — `rohan_api/src/acquisition-pathways/` module is registered in `app.module.ts`. Eight endpoints under `/acquisition-pathways/missions[/...]` respond per contracts §4. All require JWT + the `AcquisitionPathways` Postgres feature flag (gated via `@Features('AcquisitionPathways')`, which resolves through `FeatureFlagsService` against the `feature_flags` table — not the Azure `features.json` paid-features path) + `acquisition-pathways` permission. `acquisition_missions` table is created on app boot via `Database/rohan_api/scripts/sql/init_acquisition_pathways.sql` after `run_all.sql` is updated. Service unit tests pass (org scoping, non-admin user_id filter on `findOne`, admin branch, soft delete + restore, JSON merge wrapped in a transaction). Controller unit tests pass (error translation, `ParseIntPipe` path validation). One e2e happy-path test passes (`POST` → `GET list` → `PATCH state` → `GET state`). `npm run lint` and `npm run format` pass.
- [ ] **Phase 2** — `AcquisitionPathwaysApiService` exposes 8 typed methods matching contracts §7. Spec exercises each method's URL + verb + body. Existing `AcquisitionPathwaysComponent` still builds (no rebinding required). `npm run lint` and `npm run test:ci -- --include='src/app/pages/acquisition-pathways/**/*.spec.ts'` pass.
- [ ] **Manual smoke** — with the `AcquisitionPathways` Postgres flag set to `true` (`pnpm enable-flag AcquisitionPathways`) and a user in an `ACQUISITION_PATHWAYS` RBAC group: `POST /acquisition-pathways/missions` with `{ "name": "Test mission" }` returns a 201 with the row; `GET /acquisition-pathways/missions` returns it in the list (with `run_state` and `attached_files` omitted per the slim list projection); `PATCH /missions/:id/state` with `{ "run_state": { "canonicalRecord": [...] } }` persists and is returned by `GET /missions/:id/state`. Toggling the Postgres flag off (`pnpm disable-flag AcquisitionPathways`) causes every endpoint to 403 through `FeatureGuard` on the next request (no app restart required — `FeatureFlagsService.listFeatureFlags` is per-request).
