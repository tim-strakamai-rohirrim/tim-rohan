# PRCR-1649 — Contracts

> Companion to `PRCR-1649-PLAN.md`. Jira: <https://rohirrim.atlassian.net/browse/PRCR-1649>

## Contract → Phase mapping

| Contract section | Phase(s) | Notes |
|---|---|---|
| 1.0 SQL DDL — `acquisition_missions` table | 1 | New SQL file in `Database/rohan_api/scripts/sql/` |
| 2.0 `AcquisitionMission` TypeORM entity | 1 | `src/acquisition-pathways/entities/` |
| 3.0 DTOs — create / update / state / response | 1 | `src/acquisition-pathways/dto/` |
| 4.1 `POST /acquisition-pathways/missions` | 1 | Create mission |
| 4.2 `GET /acquisition-pathways/missions` | 1 | List missions (slim projection — no `run_state`, no `attached_files`) |
| 4.3 `GET /acquisition-pathways/missions/:id` | 1 | Detail |
| 4.4 `PATCH /acquisition-pathways/missions/:id` | 1 | Update name/statement/mode/stage/archived |
| 4.5 `DELETE /acquisition-pathways/missions/:id` | 1 | Soft delete (`archived = true`) |
| 4.6 `GET /acquisition-pathways/missions/:id/state` | 1 | Read JSON run_state blob |
| 4.7 `PUT /acquisition-pathways/missions/:id/state` | 1 | Replace run_state |
| 4.8 `PATCH /acquisition-pathways/missions/:id/state` | 1 | Shallow top-level merge of run_state |
| 5.0 Error responses | 1 | Across all endpoints |
| 6.0 Frontend types | 2 | `pages/acquisition-pathways/types/` |
| 7.0 `AcquisitionPathwaysApiService` interface | 2 | `pages/acquisition-pathways/services/` |

---

## 1.0 SQL DDL — `acquisition_missions` table

New file: `Database/rohan_api/scripts/sql/init_acquisition_pathways.sql`.

Idempotent — safe to re-run. Reuses the global `trigger_set_timestamp()` function defined in `init_procurements.sql:98`.

```sql
CREATE TABLE IF NOT EXISTS acquisition_missions (
  mission_id      SERIAL PRIMARY KEY,
  user_id         varchar(128) NOT NULL,
  org_id          varchar(128) NOT NULL,
  name            varchar(256) NOT NULL,
  statement       text,
  mode            varchar(16)  NOT NULL DEFAULT 'drive',
  stage           varchar(32),
  attached_files  JSONB        NOT NULL DEFAULT '[]'::jsonb,
  run_state       JSONB,
  archived        boolean      NOT NULL DEFAULT FALSE,
  created_on      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  updated_on      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),

  CONSTRAINT acquisition_missions_mode_check
    CHECK (mode IN ('drive', 'auto')),
  CONSTRAINT acquisition_missions_stage_check
    CHECK (stage IS NULL OR stage IN ('record', 'pathways', 'interview', 'integrity', 'export'))
);

CREATE INDEX IF NOT EXISTS idx_acquisition_missions_org_id
  ON acquisition_missions (org_id);

CREATE INDEX IF NOT EXISTS idx_acquisition_missions_user_id
  ON acquisition_missions (user_id);

CREATE INDEX IF NOT EXISTS idx_acquisition_missions_org_user_active
  ON acquisition_missions (org_id, user_id, archived);

CREATE OR REPLACE TRIGGER set_timestamp
  BEFORE UPDATE ON acquisition_missions
  FOR EACH ROW
  EXECUTE PROCEDURE trigger_set_timestamp();
```

**Field notes**:

| Field | Notes |
|---|---|
| `mission_id` | `SERIAL` PK — same pattern as `procurements.procurement_id`. |
| `user_id` | Auth0/Okta `sub` of the creator. `varchar(128)` matches `procurements.user_id`. |
| `org_id` | Org tenant id. Same shape and width as `procurements.org_id`. |
| `name` | Display name shown in the topbar / home composer. Required. |
| `statement` | The full mission-statement body (mission-need prose). Nullable so a user can create a draft mission with only a name. |
| `mode` | `'drive'` (default) or `'auto'`. `CHECK` constraint enforces the literal set without locking us into a Postgres `enum` type. |
| `stage` | Nullable until the user advances past intake. One of `record / pathways / interview / integrity / export`. `CHECK` allows `NULL`. **This column is the single source of truth for the user's current stage.** A `stage` key inside `run_state` is rejected at the API layer (see §4.7 / §4.8) — do not store it in two places. |
| `attached_files` | JSON array of `{ name, size?, mime? }` metadata objects. Just records intake chips for now — no file upload pipeline in this ticket. Defaults to `[]` so the column is never NULL. Omitted from the list endpoint response (see §4.2). |
| `run_state` | Opaque JSON blob keyed by stage name. Schema documented in §2 and §6 but **NOT** enforced by Postgres or the API layer. Top-level `stage` key is rejected by §4.7 / §4.8 (use the column). Omitted from the list endpoint response (see §4.2). |
| `archived` | Soft-delete flag. `findAll` excludes by default. Defaults `FALSE`. |
| `created_on` / `updated_on` | `TIMESTAMPTZ` with `NOW()` defaults; the `set_timestamp` trigger maintains `updated_on`. |

**Indexes**:

- `idx_acquisition_missions_org_id` — supports admin `findAll` (org-wide scan).
- `idx_acquisition_missions_user_id` — supports non-admin user-scoped listings.
- `idx_acquisition_missions_org_user_active` — covering index for the common predicate `org_id = ? AND user_id = ? AND archived = false`.

---

## 2.0 `AcquisitionMission` TypeORM entity

`src/acquisition-pathways/entities/acquisition-mission.entity.ts`:

```ts
import {
  Column,
  CreateDateColumn,
  Entity,
  Index,
  PrimaryGeneratedColumn,
  UpdateDateColumn,
} from 'typeorm';

export type AcquisitionMissionMode = 'drive' | 'auto';
export type AcquisitionMissionStage =
  | 'record'
  | 'pathways'
  | 'interview'
  | 'integrity'
  | 'export';

export interface AcquisitionAttachedFile {
  name: string;
  size?: number;
  mime?: string;
}

/**
 * Opaque per-mission run-state blob. Keys correspond to stages in the
 * Acquisition Pathways workflow; values are intentionally untyped here
 * because shape is owned by the client (and future server-side tool
 * handlers) and not the DB layer.
 *
 * Typical shape (informational only — not enforced):
 *   {
 *     canonicalRecord?: CrrField[],
 *     pathways?: Pathway[],
 *     findings?: FindingGroup[],
 *     ledger?: LedgerEntry[],
 *     artifacts?: Artifact[],
 *     documents?: Document[],
 *     selectedPathway?: 'low' | 'medium' | 'high' | null,
 *     pathwayCommitted?: boolean,
 *   }
 */
export type AcquisitionRunState = Record<string, unknown>;

@Entity('acquisition_missions')
@Index('idx_acquisition_missions_org_id', ['org_id'])
@Index('idx_acquisition_missions_user_id', ['user_id'])
@Index('idx_acquisition_missions_org_user_active', ['org_id', 'user_id', 'archived'])
export class AcquisitionMission {
  @PrimaryGeneratedColumn()
  mission_id: number;

  @Column({ type: 'varchar', length: 128 })
  user_id: string;

  @Column({ type: 'varchar', length: 128 })
  org_id: string;

  @Column({ type: 'varchar', length: 256 })
  name: string;

  @Column({ type: 'text', nullable: true })
  statement: string | null;

  @Column({ type: 'varchar', length: 16, default: 'drive' })
  mode: AcquisitionMissionMode;

  @Column({ type: 'varchar', length: 32, nullable: true })
  stage: AcquisitionMissionStage | null;

  @Column({ type: 'jsonb', default: () => "'[]'::jsonb" })
  attached_files: AcquisitionAttachedFile[];

  @Column({ type: 'jsonb', nullable: true })
  run_state: AcquisitionRunState | null;

  @Column({ type: 'boolean', default: false })
  archived: boolean;

  @CreateDateColumn({ type: 'timestamptz' })
  created_on: Date;

  @UpdateDateColumn({ type: 'timestamptz' })
  updated_on: Date;
}
```

---

## 3.0 DTOs

All under `src/acquisition-pathways/dto/`.

### 3.1 `CreateAcquisitionMissionDto`

`src/acquisition-pathways/dto/create-acquisition-mission.dto.ts`:

```ts
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { Type } from 'class-transformer';
import {
  ArrayMaxSize,
  IsArray,
  IsIn,
  IsInt,
  IsOptional,
  IsString,
  Length,
  Min,
  ValidateNested,
} from 'class-validator';
import {
  AcquisitionAttachedFile,
  AcquisitionMissionMode,
} from 'src/acquisition-pathways/entities/acquisition-mission.entity';

export class AttachedFileDto implements AcquisitionAttachedFile {
  @IsString()
  @Length(1, 256)
  @ApiProperty({ maxLength: 256 })
  name: string;

  @IsOptional()
  @IsInt()
  @Min(0)
  @ApiPropertyOptional({ description: 'Size in bytes; 0 if unknown.' })
  size?: number;

  @IsOptional()
  @IsString()
  @Length(1, 128)
  @ApiPropertyOptional({ maxLength: 128 })
  mime?: string;
}

const MODES: readonly AcquisitionMissionMode[] = ['drive', 'auto'] as const;

export class CreateAcquisitionMissionDto {
  @IsString()
  @Length(1, 256)
  @ApiProperty({ maxLength: 256 })
  name: string;

  @IsOptional()
  @IsString()
  @ApiPropertyOptional()
  statement?: string;

  @IsOptional()
  @IsIn(MODES)
  @ApiPropertyOptional({ enum: MODES, default: 'drive' })
  mode?: AcquisitionMissionMode;

  @IsOptional()
  @IsArray()
  @ArrayMaxSize(50)
  @ValidateNested({ each: true })
  @Type(() => AttachedFileDto)
  @ApiPropertyOptional({ type: () => [AttachedFileDto] })
  attached_files?: AttachedFileDto[];
}
```

### 3.2 `UpdateAcquisitionMissionDto`

`src/acquisition-pathways/dto/update-acquisition-mission.dto.ts`:

```ts
import { ApiPropertyOptional, PartialType } from '@nestjs/swagger';
import { IsBoolean, IsIn, IsOptional } from 'class-validator';
import { CreateAcquisitionMissionDto } from 'src/acquisition-pathways/dto/create-acquisition-mission.dto';
import { AcquisitionMissionStage } from 'src/acquisition-pathways/entities/acquisition-mission.entity';

const STAGES: readonly AcquisitionMissionStage[] = [
  'record',
  'pathways',
  'interview',
  'integrity',
  'export',
] as const;

export class UpdateAcquisitionMissionDto extends PartialType(
  CreateAcquisitionMissionDto,
) {
  @IsOptional()
  @IsIn(STAGES)
  @ApiPropertyOptional({ enum: STAGES, nullable: true })
  stage?: AcquisitionMissionStage | null;

  @IsOptional()
  @IsBoolean()
  @ApiPropertyOptional()
  archived?: boolean;
}
```

`run_state`, `mission_id`, `user_id`, `org_id`, `created_on`, and `updated_on` are deliberately **not** declared on `UpdateAcquisitionMissionDto`. With the global `ValidationPipe` configured `{ whitelist: true, forbidNonWhitelisted: true }` (see app bootstrap in `src/main.ts`), any request body containing these keys 400s before the service runs. This is the enforcement layer for §4.4's "not updatable" guarantee — do not rely on the service to strip them.

### 3.3 `AcquisitionMissionStateDto`

`src/acquisition-pathways/dto/acquisition-mission-state.dto.ts`:

```ts
import { ApiProperty } from '@nestjs/swagger';
import { IsObject } from 'class-validator';
import { AcquisitionRunState } from 'src/acquisition-pathways/entities/acquisition-mission.entity';

/**
 * Wrapper DTO for read/write of the opaque per-mission run_state blob.
 * The blob itself is `Record<string, unknown>`; consumers (and any future
 * server-side tool handlers) own its schema.
 */
export class AcquisitionMissionStateDto {
  @IsObject()
  @ApiProperty({
    type: 'object',
    additionalProperties: true,
    description: 'Opaque per-mission run-state blob.',
  })
  run_state: AcquisitionRunState;
}
```

### 3.4 `AcquisitionMissionResponseDto` and `AcquisitionMissionListItemResponseDto` (response shapes)

The service returns the raw entity for `findOne` / `create` / `update`. The list endpoint returns the slim projection (no `run_state`, no `attached_files`). For Swagger documentation a response DTO mirrors each shape:

```ts
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import {
  AcquisitionMissionMode,
  AcquisitionMissionStage,
  AcquisitionAttachedFile,
  AcquisitionRunState,
} from 'src/acquisition-pathways/entities/acquisition-mission.entity';

export class AcquisitionMissionResponseDto {
  @ApiProperty() mission_id: number;
  @ApiProperty() user_id: string;
  @ApiProperty() org_id: string;
  @ApiProperty() name: string;
  @ApiPropertyOptional({ nullable: true }) statement: string | null;
  @ApiProperty({ enum: ['drive', 'auto'] }) mode: AcquisitionMissionMode;
  @ApiPropertyOptional({
    enum: ['record', 'pathways', 'interview', 'integrity', 'export'],
    nullable: true,
  })
  stage: AcquisitionMissionStage | null;
  @ApiProperty({ type: 'array', items: { type: 'object' } })
  attached_files: AcquisitionAttachedFile[];
  @ApiPropertyOptional({ type: 'object', nullable: true, additionalProperties: true })
  run_state: AcquisitionRunState | null;
  @ApiProperty() archived: boolean;
  @ApiProperty() created_on: Date;
  @ApiProperty() updated_on: Date;
}

export class AcquisitionMissionListItemResponseDto {
  @ApiProperty() mission_id: number;
  @ApiProperty() user_id: string;
  @ApiProperty() org_id: string;
  @ApiProperty() name: string;
  @ApiPropertyOptional({ nullable: true }) statement: string | null;
  @ApiProperty({ enum: ['drive', 'auto'] }) mode: AcquisitionMissionMode;
  @ApiPropertyOptional({
    enum: ['record', 'pathways', 'interview', 'integrity', 'export'],
    nullable: true,
  })
  stage: AcquisitionMissionStage | null;
  @ApiProperty() archived: boolean;
  @ApiProperty() created_on: Date;
  @ApiProperty() updated_on: Date;
}
```

---

## 4.0 Endpoints

All endpoints share the guards:

```ts
@UseGuards(AuthGuard('jwt'), FeatureGuard, PermissionsGuard)
@Features('AcquisitionPathways')
@Permissions('acquisition-pathways')
```

The `@Features` value is the literal `FeatureFlagsEnum.AcquisitionPathways` key string. `FeatureGuard.canActivate` calls `FeatureFlags.isValidFlag(routeFeature)` which checks `Object.keys(FeatureFlagsEnum)`, so the string **must** match a key (`AcquisitionPathways`) — not a permission-style screaming-snake string (`ACQUISITION_PATHWAYS`). The latter would silently fall through to the Azure `features.json` paid-features lookup, which is **not** what `pnpm enable-flag AcquisitionPathways` toggles.

All `:id` path params are decorated with `@Param('id', ParseIntPipe) id: number`. Non-integer values 400 with NestJS's default `ParseIntPipe` payload before any service code runs. Negative or zero ids are accepted by `ParseIntPipe` but fail the repository lookup and 404.

Base path: `/acquisition-pathways`.

### 4.1 `POST /acquisition-pathways/missions` — Create mission

| | |
|---|---|
| Auth | JWT |
| Feature | `AcquisitionPathways` |
| Permission | `acquisition-pathways` |
| Body | `CreateAcquisitionMissionDto` |
| Success | `201 Created` + `AcquisitionMissionResponseDto` |

Request:

```json
{
  "name": "TRACON Modernization Phase II",
  "statement": "Refresh the en-route radar processing subsystem…",
  "mode": "drive",
  "attached_files": [
    { "name": "PWS_v3.pdf", "size": 1481000, "mime": "application/pdf" }
  ]
}
```

Response (201):

```json
{
  "mission_id": 42,
  "user_id": "auth0|abc",
  "org_id": "org_xyz",
  "name": "TRACON Modernization Phase II",
  "statement": "Refresh the en-route radar processing subsystem…",
  "mode": "drive",
  "stage": null,
  "attached_files": [
    { "name": "PWS_v3.pdf", "size": 1481000, "mime": "application/pdf" }
  ],
  "run_state": null,
  "archived": false,
  "created_on": "2026-05-20T19:00:00.000Z",
  "updated_on": "2026-05-20T19:00:00.000Z"
}
```

**Behaviour**:

- `org_id` and `user_id` are injected from the JWT (`user.org_id`, `user.sub`) — body values are ignored if present.
- `mode` defaults to `'drive'` if omitted.
- `stage` is always `null` on create.
- `run_state` is always `null` on create.
- `archived` is always `false` on create.

### 4.2 `GET /acquisition-pathways/missions` — List missions (slim projection)

| | |
|---|---|
| Auth | JWT |
| Feature | `AcquisitionPathways` |
| Permission | `acquisition-pathways` |
| Query | None in this ticket. |
| Success | `200 OK` + `AcquisitionMissionListItemDto[]` |

**The list endpoint returns a slim projection: `run_state` and `attached_files` are intentionally omitted.** Both are JSONB columns that can grow into hundreds of KB per row once the agent endpoint populates them; shipping them on every page-load list call would dominate payload size and serve no UI need (the list view shows name + status + dates, not state contents). To hydrate state, the caller follows with `GET /missions/:id` (full row) or `GET /missions/:id/state` (just the blob).

Response (200):

```json
[
  {
    "mission_id": 42,
    "user_id": "auth0|abc",
    "org_id": "org_xyz",
    "name": "TRACON Modernization Phase II",
    "statement": null,
    "mode": "drive",
    "stage": null,
    "archived": false,
    "created_on": "2026-05-20T19:00:00.000Z",
    "updated_on": "2026-05-20T19:00:00.000Z"
  }
]
```

**Behaviour**:

- Filters `archived = false` always.
- Filters `org_id = user.org_id` always.
- **Admin branch**: if the caller has the `Admin` role for the org (per `AdminService.getMemberRoles`), returns every non-archived mission in the org. Otherwise filters `user_id = user.sub`.
- Sort: `updated_on DESC`.
- Hard cap: `LIMIT 1000` server-side (runaway-query guardrail; not exposed as a query param). No pagination in this ticket.
- Implemented via `createQueryBuilder` with explicit `.select([...])` of the slim columns (mirrors `procurement-writer.service.ts:368-411`), so unwanted JSONB columns never leave Postgres.

### 4.3 `GET /acquisition-pathways/missions/:id` — Detail

| | |
|---|---|
| Auth | JWT |
| Feature | `AcquisitionPathways` |
| Permission | `acquisition-pathways` |
| Path param | `id: number` (via `ParseIntPipe`) |
| Success | `200 OK` + `AcquisitionMissionResponseDto` |
| 404 | Mission not found OR belongs to a different org OR (for non-admins) belongs to a different user in the same org |
| 400 | `id` not a valid integer |

Response: same shape as 4.1 (full row including `run_state` and `attached_files`).

**Behaviour**:

- Always filters `org_id = user.org_id`. Cross-org reads 404 (do not leak existence).
- **Non-admin user filter**: if the caller does NOT have the `Admin` role for the org, the lookup additionally filters `user_id = user.sub`. Cross-user same-org reads return 404 — same "don't leak existence" guarantee. Admins (per `AdminService.getMemberRoles`) bypass the user filter and can read any mission in their org.
- Returns archived missions too (lets the UI render a "this mission was archived" state if it loads the detail directly, and lets `PATCH { "archived": false }` find the row to restore it).

### 4.4 `PATCH /acquisition-pathways/missions/:id` — Update

| | |
|---|---|
| Auth | JWT |
| Feature | `AcquisitionPathways` |
| Permission | `acquisition-pathways` |
| Path param | `id: number` (via `ParseIntPipe`) |
| Body | `UpdateAcquisitionMissionDto` |
| Success | `200 OK` + updated `AcquisitionMissionResponseDto` |
| 404 | Mission not found / wrong org / (non-admin) wrong user |
| 400 | Invalid field value |

Updatable fields: `name`, `statement`, `mode`, `attached_files`, `stage`, `archived`.

`mission_id`, `user_id`, `org_id`, `created_on`, `updated_on` are **not** updatable (not declared on `UpdateAcquisitionMissionDto`; `ValidationPipe` with `forbidNonWhitelisted: true` rejects them with a 400). `run_state` is **not** updatable through this endpoint — use 4.7 / 4.8.

`archived` is updatable here so the UI can "restore" a soft-deleted mission with `PATCH { "archived": false }`. The lookup that backs this endpoint **includes archived rows** — if it excluded them, you could never un-archive.

Same scoping as §4.3: org-scoped always; non-admin caller also user-scoped.

### 4.5 `DELETE /acquisition-pathways/missions/:id` — Soft delete

| | |
|---|---|
| Auth | JWT |
| Feature | `AcquisitionPathways` |
| Permission | `acquisition-pathways` |
| Path param | `id: number` (via `ParseIntPipe`) |
| Success | `200 OK` + `{ "mission_id": <id>, "archived": true }` |
| 404 | Mission not found / wrong org / (non-admin) wrong user |

Response shape is **exactly** `{ "mission_id": <id>, "archived": true }` — not the full entity. The controller must construct this object explicitly; the service's `remove` method returns the same shape.

Sets `archived = true`. Does **NOT** physically delete the row. The UI can restore via 4.4 `PATCH { "archived": false }` (the §4.4 lookup includes archived rows).

Same scoping as §4.3: org-scoped always; non-admin caller also user-scoped.

A future ticket can add a hard-delete endpoint (e.g. `DELETE /:id?hard=true` for admins) if/when retention requirements demand it. Out of scope here.

### 4.6 `GET /acquisition-pathways/missions/:id/state` — Read run_state blob

| | |
|---|---|
| Auth | JWT |
| Feature | `AcquisitionPathways` |
| Permission | `acquisition-pathways` |
| Path param | `id: number` (via `ParseIntPipe`) |
| Success | `200 OK` + `AcquisitionMissionStateDto` |
| 404 | Mission not found / wrong org / (non-admin) wrong user |

Response (200):

```json
{
  "run_state": {
    "canonicalRecord": [
      {
        "label": "Mission / Objective",
        "tag": "extracted",
        "text": "Modernize the en-route radar processing subsystem.",
        "sources": [{ "kind": "user-typed", "label": "User — mission statement" }]
      }
    ],
    "pathways": [],
    "findings": [],
    "ledger": [],
    "artifacts": [],
    "selectedPathway": null,
    "pathwayCommitted": false
  }
}
```

**Behaviour**:

- If `run_state IS NULL` in the DB, returns `{ "run_state": {} }`. The client never has to disambiguate `null` vs missing-keys; it always gets an object.
- Same scoping as §4.3: org-scoped always; non-admin caller also user-scoped.

### 4.7 `PUT /acquisition-pathways/missions/:id/state` — Replace run_state

| | |
|---|---|
| Auth | JWT |
| Feature | `AcquisitionPathways` |
| Permission | `acquisition-pathways` |
| Path param | `id: number` (via `ParseIntPipe`) |
| Body | `AcquisitionMissionStateDto` |
| Success | `200 OK` + updated `AcquisitionMissionStateDto` |
| 404 | Mission not found / wrong org / (non-admin) wrong user |
| 400 | Body missing `run_state` field, `run_state` is not a plain object, or `run_state` contains a top-level `stage` key |

**Behaviour**:

- Wraps the write in a `dataSource.createQueryRunner()` transaction with `SELECT … FOR UPDATE` on the target row, then a single `UPDATE`. The transaction is bookkeeping for parity with `PATCH` — there is no read-modify-write race for a full-replace, but the lock keeps interleaved `PUT`/`PATCH` traffic consistent.
- Rejects bodies whose `run_state` contains a top-level `stage` key with a 400 (`AcquisitionPathwaysErrors.runStateStageKey`). The `stage` column is the single source of truth; the `run_state` blob must not duplicate it. Use `PATCH /missions/:id` (body `{ "stage": "pathways" }`) instead.
- Overwrites the entire `run_state` column with the body's `run_state` value. Existing keys NOT in the body are lost — this is intentional. Use 4.8 for partial updates.
- Empty object `{ "run_state": {} }` is allowed and clears all keys (writes `'{}'::jsonb`, not `NULL`).
- Updates `updated_on` via the trigger.
- Same scoping as §4.3: org-scoped always; non-admin caller also user-scoped.

### 4.8 `PATCH /acquisition-pathways/missions/:id/state` — Shallow-merge run_state

| | |
|---|---|
| Auth | JWT |
| Feature | `AcquisitionPathways` |
| Permission | `acquisition-pathways` |
| Path param | `id: number` (via `ParseIntPipe`) |
| Body | `AcquisitionMissionStateDto` (the `run_state` field acts as a partial patch) |
| Success | `200 OK` + the full post-merge `AcquisitionMissionStateDto` |
| 404 | Mission not found / wrong org / (non-admin) wrong user |
| 400 | Body missing `run_state` field, `run_state` is not a plain object, or `run_state` contains a top-level `stage` key |

**Behaviour**:

- Wrapped in a `dataSource.createQueryRunner()` transaction:
  1. `BEGIN`.
  2. `SELECT run_state FROM acquisition_missions WHERE mission_id = $1 AND org_id = $2 [AND user_id = $3] FOR UPDATE`.
  3. Reject body with `stage` key (see §4.7) → `ROLLBACK` and 400.
  4. Compute `merged = { ...current, ...body.run_state }` in TypeScript (current `NULL` is treated as `{}`).
  5. `UPDATE acquisition_missions SET run_state = $merged WHERE mission_id = $1`.
  6. `COMMIT`.
- The `FOR UPDATE` row lock prevents the read-modify-write race that two concurrent PATCHes (or a PATCH plus a future agent tool-handler) would otherwise hit. **This ticket does NOT add an `If-Match`/ETag header or a `version` column** — that's deferred — but the row lock kills the same-process race today.
- Example: starting from `{ "canonicalRecord": [...], "pathways": [...] }`, a `PATCH` with body `{ "run_state": { "pathways": [] } }` ends with `{ "canonicalRecord": [...], "pathways": [] }`. The `canonicalRecord` array is preserved untouched.
- **Top-level merge only.** Nested objects in the body **replace** the existing nested value at the same key. This is deliberate — deep merge of arbitrary JSON has nasty edge cases (array merge ambiguity) and we don't have a use case for it yet.
- Returns the full post-merge state, not just the patch.
- Same scoping as §4.3: org-scoped always; non-admin caller also user-scoped.

---

## 5.0 Error responses

All endpoints translate service errors via this table. Strings are literal — agents / tests will string-match these.

| Status | Condition | Body |
|---|---|---|
| `400` | `:id` path param is not an integer | NestJS default `ParseIntPipe` payload: `{ "statusCode": 400, "message": "Validation failed (numeric string is expected)", "error": "Bad Request" }`. Produced by the pipe before service code runs. |
| `400` | Body fails class-validator (e.g. `name` missing on create, `mode` not in enum, or any non-whitelisted field on `UpdateAcquisitionMissionDto` such as `user_id`, `org_id`, `run_state`) | NestJS default `ValidationPipe` payload (array of constraint messages). `app.module.ts`'s global `ValidationPipe` is configured with `{ whitelist: true, forbidNonWhitelisted: true }`. |
| `400` | `run_state` payload is not a plain object | `{ "statusCode": 400, "message": "run_state must be a plain object" }` |
| `400` | `run_state` payload contains a top-level `stage` key | `{ "statusCode": 400, "message": "run_state must not include a 'stage' key — use PATCH /missions/:id" }` |
| `404` | Mission not found, belongs to another org, or (non-admin) belongs to another user in the same org | `{ "statusCode": 404, "message": "Acquisition mission not found" }` |
| `403` | User lacks `acquisition-pathways` permission, or the `AcquisitionPathways` Postgres flag is `false` for the caller's org | NestJS default — managed by `PermissionsGuard` / `FeatureGuard` |
| `413` | Request body exceeds Fastify's body limit (default 1 MiB; not overridden in this ticket) | Fastify default — caller should fall back to `PUT` with a slimmer blob or wait for the follow-up ticket that raises the cap. |
| `500` | Create / list / update / delete / state read / state write internal failure | `{ "statusCode": 500, "message": "<corresponding constant>" }` |

There is no `409 Conflict`: the `PATCH /state` row-level `FOR UPDATE` lock serializes concurrent writes inside a single process. Optimistic-locking (`If-Match` + 409 on stale `updated_on`) is deferred to a follow-up ticket alongside the LLM agent endpoint.

The `acquisition-pathways.constants.ts` file holds the literal strings:

```ts
export const AcquisitionPathwaysErrors = {
  createMissionError: 'Failed to create acquisition mission',
  getMissionsError: 'Failed to list acquisition missions',
  getMissionError: 'Failed to get acquisition mission',
  updateMissionError: 'Failed to update acquisition mission',
  deleteMissionError: 'Failed to delete acquisition mission',
  getStateError: 'Failed to read acquisition mission state',
  updateStateError: 'Failed to update acquisition mission state',
  invalidMissionId: 'Invalid mission id',
  missionNotFound: 'Acquisition mission not found',
  invalidRunState: 'run_state must be a plain object',
  runStateStageKey:
    "run_state must not include a 'stage' key — use PATCH /missions/:id",
} as const;
```

---

## 6.0 Frontend types

`src/app/pages/acquisition-pathways/types/acquisition-pathways.types.ts` — replace the placeholder file with:

```ts
/**
 * Per-mission opaque state blob. Keys correspond to workflow stages; values
 * are intentionally untyped at this layer because the shape is owned by the
 * caller (and any future server-side tool handlers).
 *
 * Informational reference shape (do NOT add runtime validation against it):
 *   {
 *     canonicalRecord?: unknown[],
 *     pathways?: unknown[],
 *     findings?: unknown[],
 *     ledger?: unknown[],
 *     artifacts?: unknown[],
 *     documents?: unknown[],
 *     selectedPathway?: 'low' | 'medium' | 'high' | null,
 *     pathwayCommitted?: boolean,
 *   }
 */
export type AcquisitionRunState = Record<string, unknown>;

export type AcquisitionMissionMode = 'drive' | 'auto';

export type AcquisitionMissionStage =
    | 'record'
    | 'pathways'
    | 'interview'
    | 'integrity'
    | 'export';

export interface AcquisitionAttachedFile {
    name: string;
    size?: number;
    mime?: string;
}

export interface AcquisitionMission {
    mission_id: number;
    user_id: string;
    org_id: string;
    name: string;
    statement: string | null;
    mode: AcquisitionMissionMode;
    stage: AcquisitionMissionStage | null;
    attached_files: AcquisitionAttachedFile[];
    run_state: AcquisitionRunState | null;
    archived: boolean;
    created_on: string;
    updated_on: string;
}

/**
 * Slim projection returned by `GET /acquisition-pathways/missions`. `run_state`
 * and `attached_files` are intentionally omitted — both are JSONB columns that
 * grow large once the agent endpoint populates them, and the list view has no
 * need for either. To hydrate the full row, follow up with `GET /missions/:id`
 * (full row) or `GET /missions/:id/state` (just the blob).
 */
export type AcquisitionMissionListItem = Omit<
    AcquisitionMission,
    'run_state' | 'attached_files'
>;

export interface CreateAcquisitionMissionPayload {
    name: string;
    statement?: string;
    mode?: AcquisitionMissionMode;
    attached_files?: AcquisitionAttachedFile[];
}

export interface UpdateAcquisitionMissionPayload {
    name?: string;
    /**
     * Pass `null` to explicitly clear an existing mission statement.
     * The backend's `UpdateAcquisitionMissionDto` accepts `null` because
     * `@IsOptional()` short-circuits the `@IsString()` check, and the
     * `acquisition_missions.statement` column is nullable.
     */
    statement?: string | null;
    mode?: AcquisitionMissionMode;
    attached_files?: AcquisitionAttachedFile[];
    stage?: AcquisitionMissionStage | null;
    archived?: boolean;
}

export interface AcquisitionMissionStatePayload {
    run_state: AcquisitionRunState;
}

export interface AcquisitionMissionDeleteResponse {
    mission_id: number;
    archived: true;
}

/**
 * @deprecated Placeholder type kept so the existing AcquisitionPathwaysComponent
 * empty-search scaffold compiles unchanged in this ticket. Remove when the UI
 * is rewired to render `AcquisitionMissionListItem`s.
 */
export interface AcquisitionPathway {
    id: string;
    name: string;
}
```

---

## 7.0 `AcquisitionPathwaysApiService` interface

`src/app/pages/acquisition-pathways/services/acquisition-pathways-api.service.ts`:

```ts
import { Injectable, inject } from '@angular/core';
import { map, Observable } from 'rxjs';

import { RequestService } from '@shared-services/request/request.service';

import {
    AcquisitionMission,
    AcquisitionMissionDeleteResponse,
    AcquisitionMissionListItem,
    AcquisitionMissionStatePayload,
    CreateAcquisitionMissionPayload,
    UpdateAcquisitionMissionPayload,
} from '@pages/acquisition-pathways/types/acquisition-pathways.types';

const BASE_PATH = '/acquisition-pathways/missions';

@Injectable({ providedIn: 'root' })
export class AcquisitionPathwaysApiService {
    private readonly request = inject(RequestService);

    listMissions(): Observable<AcquisitionMissionListItem[]> {
        return this.request
            .get(BASE_PATH)
            .pipe(map((res) => res as AcquisitionMissionListItem[]));
    }

    getMission(id: number): Observable<AcquisitionMission> {
        return this.request
            .get(`${BASE_PATH}/${id}`)
            .pipe(map((res) => res as AcquisitionMission));
    }

    createMission(payload: CreateAcquisitionMissionPayload): Observable<AcquisitionMission> {
        return this.request
            .post(BASE_PATH, payload)
            .pipe(map((res) => res as AcquisitionMission));
    }

    updateMission(
        id: number,
        payload: UpdateAcquisitionMissionPayload,
    ): Observable<AcquisitionMission> {
        return this.request
            .patch(`${BASE_PATH}/${id}`, payload)
            .pipe(map((res) => res as AcquisitionMission));
    }

    deleteMission(id: number): Observable<AcquisitionMissionDeleteResponse> {
        return this.request.delete<AcquisitionMissionDeleteResponse>(`${BASE_PATH}/${id}`);
    }

    getMissionState(id: number): Observable<AcquisitionMissionStatePayload> {
        return this.request
            .get(`${BASE_PATH}/${id}/state`)
            .pipe(map((res) => res as AcquisitionMissionStatePayload));
    }

    replaceMissionState(
        id: number,
        payload: AcquisitionMissionStatePayload,
    ): Observable<AcquisitionMissionStatePayload> {
        return this.request.put<AcquisitionMissionStatePayload>(
            `${BASE_PATH}/${id}/state`,
            payload,
        );
    }

    patchMissionState(
        id: number,
        payload: AcquisitionMissionStatePayload,
    ): Observable<AcquisitionMissionStatePayload> {
        return this.request
            .patch(`${BASE_PATH}/${id}/state`, payload)
            .pipe(map((res) => res as AcquisitionMissionStatePayload));
    }
}
```

**Implementation notes**:

- **`RequestService` generics gap**: in the current codebase (`src/app/shared-services/request/request.service.ts`), `get()`, `post()`, and `patch()` return `Observable<any>` with no generic. Only `put<T>()` and `delete<T>()` are generic. The service above sidesteps the gap by wrapping each call in `.pipe(map((res) => res as T))` — this preserves the public method return type without expanding `RequestService` (which would have broad blast radius and is out of scope for this ticket). **Do not** write `request.get(...) as Observable<T>` — that casts the stream wrapper, not the emitted value, and silently undermines RxJS operator inference downstream.
- **Do not type the request body or response as `any`.** Use the explicit payload / response interfaces from §6.0.
- All methods take their own arguments rather than DTO classes. The payload interfaces are plain `interface`s, not class-validated DTOs (that's a server concern).
- `BASE_PATH` is a module-private `const`. Do not export it.
- If a global HTTP error interceptor is present, no `catchError` is needed in this service. If not, mirror whatever the nearest neighbour service does — but do **not** invent a new error-handling shape just for this service.

**Spec coverage** (`acquisition-pathways-api.service.spec.ts`):

- One `it()` per public method, verifying URL + verb + body.
- One `it()` confirming `BASE_PATH` is the literal `/acquisition-pathways/missions`.
- For the `get`/`post`/`patch` wrappers, one `it()` verifying the cast does not throw at runtime when the stubbed response is `null` or `undefined` (mirrors the 204/no-body HTTP case).
- **Do NOT** add an `it()` "confirming the service is provided in `'root'`". `TestBed.inject(AcquisitionPathwaysApiService)` succeeds whether the service is `providedIn: 'root'` OR present in the testing module's `providers` array — the assertion is unenforceable. If the project cares about the invariant, rely on the decorator metadata + lint.
