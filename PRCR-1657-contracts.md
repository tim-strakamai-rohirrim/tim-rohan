# PRCR-1657 — Contracts

> Companion to `PRCR-1657-PLAN.md`. Jira: <https://rohirrim.atlassian.net/browse/PRCR-1657>
>
> Additive change set on top of the **already-shipped** PRCR-1649 surface
> (`archive/PRCR-1649-PLAN.md`, `archive/PRCR-1649-contracts.md`). Every
> change here is delta-only — fields that aren't called out are unchanged
> from the PRCR-1649 contracts and continue to behave as documented there.

## Contract → Phase mapping

| Contract section | Phase(s) | Notes |
|---|---|---|
| 1.0 SQL DDL — `acquisition_missions.type` column | 1 | Idempotent `ALTER TABLE … ADD COLUMN IF NOT EXISTS` appended to the existing `init_acquisition_pathways.sql` |
| 2.0 `AcquisitionMission` entity — `type` column | 1 | New `@Column` + `AcquisitionMissionType` union + `ACQUISITION_MISSION_TYPES` const |
| 3.1 `CreateAcquisitionMissionDto.type` | 1 | Optional on the wire; DB DEFAULT supplies `'NEW'` when omitted |
| 3.2 `UpdateAcquisitionMissionDto.type` | 1 | `null` rejected via `@ValidateIf` (column is `NOT NULL`) |
| 3.3 `ListAcquisitionMissionsQueryDto.type` | 1 | New query DTO for the `?type=` filter |
| 3.4 `AcquisitionMissionResponseDto.type` + `AcquisitionMissionListItemResponseDto.type` | 1 | Both response DTOs gain `type` |
| 4.1 `POST /acquisition-pathways/missions` — accepts `type` | 1 | Defaults to `'NEW'` |
| 4.2 `GET /acquisition-pathways/missions?type=` — list filter + slim projection includes `type` | 1 | Single-value query param; missing param = no filter (returns both) |
| 4.3 `GET /acquisition-pathways/missions/:id` — returns `type` | 1 | Additive |
| 4.4 `PATCH /acquisition-pathways/missions/:id` — accepts `type` | 1 | `null` rejected (NOT NULL column) |
| 5.0 Error responses — `invalidMissionType` constant | 1 | New literal string + `AcquisitionPathwaysErrors` key |
| 6.0 Shared FE union — `AcquisitionMissionType` | 2 | One union shared by both FE service layers (typed BE client + UI-prototype mock) — type values are identical on both sides |
| 6.1 BE-aligned FE types — `type` field | 2 | `AcquisitionMission` (required), `AcquisitionMissionListItem` (auto-inherits via `Omit`), `Create/UpdateAcquisitionMissionPayload` (optional) |
| 6.2 UI-prototype FE types — `type` field | 2 | `Mission` (required), `CreateMissionPayload` (optional) |
| 7.1 `AcquisitionPathwaysApiService.listMissions(filters?)` | 2 | Typed BE client — routes through `RequestService.getWithParams` when `filters.type` is present |
| 7.2 `AcquisitionPathwaysService.getMissions(type?)` | 2 | UI-prototype mock — in-memory filter on `MOCK_MISSIONS` |

---

## 1.0 SQL DDL — `acquisition_missions.type` column

Append to `Database/rohan_api/scripts/sql/init_acquisition_pathways.sql` — **do not** rewrite the file. The whole script is re-run on every container boot via `run_all.sql`, so every statement here must be idempotent.

```sql
-- Mission classification: 'NEW' for freshly-drafted missions, 'LEGACY' for
-- missions imported / carried over from a prior system. Required column;
-- DB DEFAULT 'NEW' backfills existing rows on the ADD COLUMN.
ALTER TABLE acquisition_missions
  ADD COLUMN IF NOT EXISTS type varchar(16) NOT NULL DEFAULT 'NEW';

-- Drop-then-add is the simplest path to "CHECK constraint exists with this
-- exact definition" — Postgres has no `ADD CONSTRAINT IF NOT EXISTS` and a
-- bare `ADD CONSTRAINT` on a re-run would 42710. The DROP is no-op on the
-- first boot and idempotent on every subsequent boot.
ALTER TABLE acquisition_missions
  DROP CONSTRAINT IF EXISTS acquisition_missions_type_check;
ALTER TABLE acquisition_missions
  ADD CONSTRAINT acquisition_missions_type_check
  CHECK (type IN ('NEW', 'LEGACY'));

-- Partial index for the `?type=` filter. Excluding archived rows mirrors
-- the existing org+user+archived index and keeps it lean for the common
-- predicate `org_id = ? AND user_id = ? AND type = ? AND archived = false`.
CREATE INDEX IF NOT EXISTS idx_acquisition_missions_org_user_type_active
  ON acquisition_missions (org_id, user_id, type)
  WHERE archived = false;
```

**Field notes**:

| Field | Notes |
|---|---|
| `type` | `varchar(16)` so the column is the same width class as `mode` (also `varchar(16)`). `NOT NULL DEFAULT 'NEW'` — Postgres backfills the literal `'NEW'` into every existing row at `ADD COLUMN` time, so we don't need a separate `UPDATE` step. |

**CHECK constraint membership** (`'NEW'` / `'LEGACY'`) is the single source of truth — the entity union, DTO `@IsIn` validator, query DTO `@IsIn` validator, and Swagger `enum` metadata all read from `ACQUISITION_MISSION_TYPES` (see §2.0) which mirrors this set exactly. Changing the membership in one place without the others will produce a 500 at INSERT time on a legitimate request.

---

## 2.0 `AcquisitionMission` entity — `type` column

Edit `rohan_api-parent/rohan_api/src/acquisition-pathways/entities/acquisition-mission.entity.ts`. New exports + one new column. Existing exports unchanged.

```ts
export type AcquisitionMissionType = 'NEW' | 'LEGACY';

/**
 * Single source of truth for the `type` enum membership. Mirrored from
 * the SQL `acquisition_missions_type_check` constraint. Imported by the
 * request, query, and response DTOs so all four DTOs stay in lock-step
 * with the DB constraint.
 */
export const ACQUISITION_MISSION_TYPES: readonly AcquisitionMissionType[] = [
  'NEW',
  'LEGACY',
] as const;
```

New column on `AcquisitionMission` (placed after `mode`, before `stage` — visual grouping with the other enum columns):

```ts
// Column default ('NEW') is owned by the SQL migration in the Database
// repo (init_acquisition_pathways.sql). We deliberately do NOT duplicate
// it in the decorator here, matching the existing `mode` / `archived` /
// `attached_files` pattern documented above.
@Column({ type: 'varchar', length: 16 })
type: AcquisitionMissionType;
```

---

## 3.0 DTOs

All under `rohan_api-parent/rohan_api/src/acquisition-pathways/dto/missions/` unless noted.

### 3.1 `CreateAcquisitionMissionDto.type`

Add to `create-acquisition-mission.dto.ts`. Optional on the wire — clients that omit it get the DB default of `'NEW'`.

```ts
import {
  ACQUISITION_MISSION_MODES,
  ACQUISITION_MISSION_TYPES,
  AcquisitionAttachedFile,
  AcquisitionMissionMode,
  AcquisitionMissionType,
} from 'src/acquisition-pathways/entities/acquisition-mission.entity';

// Inside CreateAcquisitionMissionDto, alongside `mode`:
@ValidateIf((_o, value) => value !== undefined)
@IsIn(ACQUISITION_MISSION_TYPES)
@ApiPropertyOptional({ enum: ACQUISITION_MISSION_TYPES, default: 'NEW' })
type?: AcquisitionMissionType;
```

`@ValidateIf((_o, v) => v !== undefined)` (instead of `@IsOptional`) matches the pattern documented on `mode` and `attached_files`: it skips only when the value is `undefined`, so an explicit `null` falls through to `@IsIn` and is rejected with a 400. The DB column is `NOT NULL`, so persisting `null` would 500 at INSERT — reject at the boundary instead.

### 3.2 `UpdateAcquisitionMissionDto.type`

`UpdateAcquisitionMissionDto` extends `PartialType(CreateAcquisitionMissionDto)`, which auto-inherits `type` as optional. But `PartialType` re-wraps every inherited field with `@IsOptional()` — and `@IsOptional()` skips on `null`, which would let `{ "type": null }` slip past validation and 500 at the database. Re-declare `type` here, mirroring the existing `mode` re-declaration:

```ts
// Inside UpdateAcquisitionMissionDto, alongside the existing `mode`
// re-declaration:
@ValidateIf((_o, value) => value !== undefined)
@IsIn(ACQUISITION_MISSION_TYPES)
@ApiPropertyOptional({ enum: ACQUISITION_MISSION_TYPES, default: 'NEW' })
type?: AcquisitionMissionType;
```

Update the import block at the top of the file to add `ACQUISITION_MISSION_TYPES` + `AcquisitionMissionType`.

### 3.3 `ListAcquisitionMissionsQueryDto` (new file)

New file: `rohan_api-parent/rohan_api/src/acquisition-pathways/dto/missions/list-acquisition-missions-query.dto.ts`.

```ts
import { ApiPropertyOptional } from '@nestjs/swagger';
import { IsIn, IsOptional } from 'class-validator';
import {
  ACQUISITION_MISSION_TYPES,
  AcquisitionMissionType,
} from 'src/acquisition-pathways/entities/acquisition-mission.entity';

/**
 * Query-string filters for `GET /acquisition-pathways/missions`. Today
 * there's only one filter (`type`), but the dedicated DTO is the same
 * cheap-to-extend shape `procurement-writer` uses, so the next filter
 * (`stage`? `mode`?) is a one-line add instead of a controller signature
 * change.
 */
export class ListAcquisitionMissionsQueryDto {
  // `@IsOptional()` (NOT `@ValidateIf`) is intentional here — for query
  // params, `undefined` is the only "missing" representation Fastify
  // ever produces (query strings can't carry a literal JSON `null`), so
  // there's no `null`-bypass risk to defend against the way the body
  // DTOs do.
  @IsOptional()
  @IsIn(ACQUISITION_MISSION_TYPES)
  @ApiPropertyOptional({
    enum: ACQUISITION_MISSION_TYPES,
    description:
      'Filter the list to missions of the given type. Omit to return both `NEW` and `LEGACY`.',
  })
  type?: AcquisitionMissionType;
}
```

The controller already mounts a `ValidationPipe({ whitelist: true, forbidNonWhitelisted: true, transform: true })` at the class level, so unknown query keys (e.g. `?typo=NEW`) reject with a 400 the same way unknown body keys do.

### 3.4 `AcquisitionMissionResponseDto.type` + `AcquisitionMissionListItemResponseDto.type`

Add `type` to **both** response DTOs in `dto/missions/acquisition-mission.dto.ts`. Placed after `mode`, before `stage` for symmetry with the entity column order.

```ts
// In AcquisitionMissionResponseDto (and the slim list DTO, same
// placement), update the imports to include ACQUISITION_MISSION_TYPES
// and AcquisitionMissionType, then add:
@ApiProperty({ enum: ACQUISITION_MISSION_TYPES })
type: AcquisitionMissionType;
```

The slim list projection `AcquisitionMissionListItemResponseDto` **must** include `type` (it's a small scalar that drives filtering and per-row badges; omitting it would force a per-row detail fetch).

---

## 4.0 Endpoints (delta only)

All endpoints inherit the existing PRCR-1649 guards (`AuthGuard('jwt')`, `FeatureGuard('AcquisitionPathways')`, `PermissionsGuard('acquisition-pathways')`) and the class-level `ValidationPipe`. Only diffs are documented.

### 4.1 `POST /acquisition-pathways/missions` — accepts `type`

Body gains an optional `type` field. Defaults to `'NEW'` server-side (DB column DEFAULT). `null` rejected with a 400 (`@ValidateIf` + `@IsIn`).

Request (new field shown bold; rest unchanged):

```json
{
  "name": "TRACON Modernization Phase II",
  "statement": "Refresh the en-route radar processing subsystem…",
  "mode": "drive",
  "type": "NEW",
  "attached_files": [{ "name": "PWS_v3.pdf" }]
}
```

Response (201) — the full entity with `type` populated:

```json
{
  "mission_id": 42,
  "user_id": "auth0|abc",
  "org_id": "org_xyz",
  "name": "TRACON Modernization Phase II",
  "statement": "Refresh the en-route radar processing subsystem…",
  "mode": "drive",
  "type": "NEW",
  "stage": null,
  "attached_files": [{ "name": "PWS_v3.pdf" }],
  "run_state": null,
  "archived": false,
  "created_on": "2026-06-03T19:00:00.000Z",
  "updated_on": "2026-06-03T19:00:00.000Z"
}
```

**Behaviour**:

- Omitting `type` produces a row with `type = 'NEW'` (the DB DEFAULT — verified in §1.0).
- Explicit `null` 400s before INSERT.
- Any value not in `('NEW', 'LEGACY')` 400s before INSERT (DTO `@IsIn` runs first; even if it didn't, the CHECK constraint would surface a 500 — the DTO is the first line of defence).

### 4.2 `GET /acquisition-pathways/missions?type=` — list filter + slim projection includes `type`

Adds **one** optional query param: `?type=NEW` or `?type=LEGACY`. Validated by `ListAcquisitionMissionsQueryDto` (§3.3); invalid values 400.

| | |
|---|---|
| Query | `type?: 'NEW' \| 'LEGACY'` |
| Filter behaviour | When omitted, no filter is applied — both `NEW` and `LEGACY` are returned. When present, an `AND mission.type = :type` clause is appended to the existing `org_id` / `user_id` / `archived` predicate. |
| Slim projection | `type` is **added** to the `LIST_PROJECTION_COLUMNS` constant in the service. `run_state` and `attached_files` remain omitted per the existing slim-projection contract (`archive/PRCR-1649-contracts.md` §4.2). |

Response (200) — every row now carries `type`:

```json
[
  {
    "mission_id": 42,
    "user_id": "auth0|abc",
    "org_id": "org_xyz",
    "name": "TRACON Modernization Phase II",
    "statement": null,
    "mode": "drive",
    "type": "NEW",
    "stage": null,
    "archived": false,
    "created_on": "2026-06-03T19:00:00.000Z",
    "updated_on": "2026-06-03T19:00:00.000Z"
  }
]
```

**Behaviour notes**:

- The `LIMIT 1000` hard cap, `updated_on DESC` sort, admin-vs-non-admin user-scope branch, and `archived = false` predicate all behave identically to the existing PRCR-1649 contract. The `type` filter composes with them; it does not replace any of them.
- Multiple values are **not** supported in this ticket (`?type=NEW&type=LEGACY` rejects with a 400 from `@IsIn` — Fastify hands a multi-valued query param to the DTO as an array, which fails the scalar `@IsIn` check). A future ticket can broaden to `@IsArray() @IsIn(... { each: true })` if a UI lands that needs both lists composed at once. Out of scope here.
- `?type=` (empty string) rejects with a 400 from `@IsIn` — the DTO treats `''` as a present value, not as omitted.

### 4.3 `GET /acquisition-pathways/missions/:id` — returns `type`

No request change. Response gains the `type` field (full entity shape, mirroring §4.1's 201 response).

### 4.4 `PATCH /acquisition-pathways/missions/:id` — accepts `type`

Updatable fields are now: `name`, `statement`, `mode`, `type`, `attached_files`, `stage`, `archived`. `mission_id` / `user_id` / `org_id` / `created_on` / `updated_on` / `run_state` remain not-updatable for the same reason as before (not declared on `UpdateAcquisitionMissionDto`; `forbidNonWhitelisted` rejects).

Explicit `null` for `type` 400s (NOT NULL column — same `@ValidateIf` + `@IsIn` pattern as `mode`).

Same scoping as before: org-scoped always; non-admin caller also user-scoped.

### 4.5 / 4.6 / 4.7 / 4.8 — `DELETE`, `GET /state`, `PUT /state`, `PATCH /state`

**No change.** These endpoints do not read or write `type`. The `run_state` blob is unrelated to the new column.

---

## 5.0 Error responses (delta only)

One new literal added to `AcquisitionPathwaysErrors`:

```ts
export const AcquisitionPathwaysErrors = {
  // … existing keys unchanged …
  invalidMissionType:
    "type must be one of 'NEW' or 'LEGACY'",
} as const;
```

Append it to the end of the object (after `runStateStageKey`) so the diff is a single-line addition rather than a re-ordering.

**Error matrix delta** (rest of the table from `archive/PRCR-1649-contracts.md` §5.0 still applies):

| Status | Condition | Body |
|---|---|---|
| `400` | `POST /missions` or `PATCH /missions/:id` body sets `type` to a value outside `('NEW', 'LEGACY')`, or to an explicit `null` | NestJS default `ValidationPipe` payload (`@IsIn` constraint violation). The literal `AcquisitionPathwaysErrors.invalidMissionType` is **not** what the wire sees here — that constant exists for service-layer error messages and tests. The constraint message is owned by class-validator. |
| `400` | `GET /missions?type=` value outside `('NEW', 'LEGACY')`, or any unknown query key (e.g. `?typo=NEW`) | NestJS default `ValidationPipe` payload (`forbidNonWhitelisted` + `@IsIn`). |

There is no new `404` / `409` / `500` mode introduced by this ticket — the DB CHECK constraint is unreachable from a valid DTO and only fires if someone bypasses the DTO entirely (which would be a programmer bug, not a user input).

---

## 6.0 Shared FE union — `AcquisitionMissionType`

`rohan_ui-parent/rohan_ui/src/app/pages/acquisition-pathways/types/acquisition-pathways.types.ts` — add at the top of the file, just above the existing `AcquisitionRunState` block so both type families below can import it from a single anchor.

```ts
/**
 * Mission classification surfaced as a badge in the missions table and
 * used as the `?type=` filter on `GET /acquisition-pathways/missions`.
 *
 * Shared by both FE service layers:
 *   - The typed BE client (`AcquisitionPathwaysApiService`) — used by
 *     `AcquisitionMission`, `AcquisitionMissionListItem`, and the
 *     create/update payload types.
 *   - The UI-prototype mock (`AcquisitionPathwaysService`) — used by
 *     `Mission` and `CreateMissionPayload`.
 *
 * Unlike `mode` (where the UI label `'manual' | 'auto'` was renamed in
 * PRCR-1650 without changing the persisted BE enum `'drive' | 'auto'`),
 * the `type` values are identical on both sides — one union covers
 * both layers without a UI-vs-BE split.
 *
 * Mirrors the backend's `ACQUISITION_MISSION_TYPES` constant
 * (rohan_api/src/acquisition-pathways/entities/acquisition-mission.entity.ts).
 * Keep this list in lock-step with that constant and the SQL CHECK in
 * `init_acquisition_pathways.sql`; adding a third value here without
 * the other two will produce a 400 at create / update time and a 500
 * at direct INSERT time.
 */
export type AcquisitionMissionType = 'NEW' | 'LEGACY';

export const ACQUISITION_MISSION_TYPES: readonly AcquisitionMissionType[] = [
    'NEW',
    'LEGACY',
] as const;
```

---

## 6.1 BE-aligned FE types — `type` field

Same file. Edits to the BE-aligned type family shipped by PRCR-1649 Phase 2.

### 6.1.1 `AcquisitionMission` (required `type`)

```ts
export interface AcquisitionMission {
    mission_id: number;
    user_id: string;
    org_id: string;
    name: string;
    statement: string | null;
    mode: AcquisitionMissionMode;
    /**
     * Mission classification. Required because the BE column is
     * `NOT NULL DEFAULT 'NEW'` and every BE response carries a value.
     * Asymmetric with `Create/UpdateAcquisitionMissionPayload.type`,
     * which are optional (BE applies a `'NEW'` default on omission).
     */
    type: AcquisitionMissionType;
    stage: AcquisitionMissionStage | null;
    attached_files: AcquisitionAttachedFile[];
    run_state: AcquisitionRunState | null;
    archived: boolean;
    created_on: string;
    updated_on: string;
}
```

### 6.1.2 `AcquisitionMissionListItem` (auto-inherits via `Omit`)

**No edit.** The existing alias is `Omit<AcquisitionMission, 'run_state' | 'attached_files'>`. `type` is NOT in the omit list, so the new field auto-propagates into the slim list type. Do **not** rewrite the alias to a direct field list — the `Omit` form is the contract and keeps the slim type in mechanical lock-step with the full row.

### 6.1.3 `CreateAcquisitionMissionPayload` (optional `type`)

```ts
export interface CreateAcquisitionMissionPayload {
    name: string;
    /** … existing fields unchanged … */
    statement?: string;
    mode?: AcquisitionMissionMode;
    /**
     * Optional on the wire — BE applies a `'NEW'` default when omitted
     * (DB column DEFAULT). Surfaced here so the create flow can pass
     * `'LEGACY'` for imported / carried-over missions.
     */
    type?: AcquisitionMissionType;
    attached_files?: AcquisitionAttachedFile[];
}
```

### 6.1.4 `UpdateAcquisitionMissionPayload` (optional `type`)

```ts
export interface UpdateAcquisitionMissionPayload {
    name?: string;
    /** … existing fields unchanged … */
    statement?: string | null;
    mode?: AcquisitionMissionMode;
    /**
     * Optional. Omit to skip the update. There is no `null` semantics:
     * the BE column is `NOT NULL`, so `PATCH { "type": null }` 400s.
     */
    type?: AcquisitionMissionType;
    attached_files?: AcquisitionAttachedFile[];
    stage?: AcquisitionMissionStage | null;
    archived?: boolean;
}
```

---

## 6.2 UI-prototype FE types — `type` field

Same file. Edits to the prototype-shape type family added by PRCR-1632 / 1636 / 1646. These are intentionally divergent from the BE-aligned types above (different field names, different `mode` literal set); only the `type` enum values are shared via §6.0.

### 6.2.1 `Mission` (required `type`)

```ts
export interface Mission {
    id: string;
    name: string;
    mode: MissionMode;
    /**
     * Mission classification. Required because the BE-side
     * `AcquisitionMission.type` is required; mirroring that contract
     * here avoids a "one shape lies about the other" situation if/when
     * this interface is reconciled to the BE shape in a follow-up.
     */
    type: AcquisitionMissionType;
    status: string;
    updatedAt: string;
    createdAt: string;
}
```

**Blast radius of making `Mission.type` required** at plan-authoring time:

| Site | Fix |
|---|---|
| `services/mock-data.ts` `MOCK_MISSIONS` | §7.2 bumps every row with an explicit `type` |
| `components/missions-table/ap-missions-table.component.spec.ts` `mockMissions: Mission[]` (two literal entries) | Plan step 2.10 adds a `type` line to each |

Every other consumer in `pages/acquisition-pathways/` reads `Mission` values produced by the service — they're not broken by the tightening. The plan's step 2.10 instructs the implementer to re-scan for any new consumer that landed after plan-authoring.

### 6.2.2 `CreateMissionPayload` (optional `type`)

```ts
export interface CreateMissionPayload {
    name: string;
    statement: string;
    mode: MissionMode;
    /**
     * Optional on the wire — BE applies a `'NEW'` default when omitted.
     * Surfaced here so the missions composer can pass `'LEGACY'` for
     * imported / carried-over missions.
     */
    type?: AcquisitionMissionType;
}
```

The pre-existing `AcquisitionPathway`, `RequirementsRecordSummary`, `ApWizardStepMeta`, and other prototype interfaces are **unchanged** by this ticket.

---

## 7.0 Service signatures (delta only)

### 7.1 `AcquisitionPathwaysApiService.listMissions(filters?)` — typed BE client

`rohan_ui-parent/rohan_ui/src/app/pages/acquisition-pathways/services/acquisition-pathways-api.service.ts` — extend the existing `listMissions` method to forward a `?type=` query param via `RequestService.getWithParams` when a filter is set; keep the existing `request.get(BASE_PATH)` call when no filter is set.

```ts
import { HttpParams } from '@angular/common/http';
import {
    AcquisitionMission,
    AcquisitionMissionDeleteResponse,
    AcquisitionMissionListItem,
    AcquisitionMissionStatePayload,
    AcquisitionMissionType,
    CreateAcquisitionMissionPayload,
    UpdateAcquisitionMissionPayload,
} from '@pages/acquisition-pathways/types/acquisition-pathways.types';
import { RequestService } from '@shared-services/request/request.service';

const BASE_PATH = '/acquisition-pathways/missions';

@Injectable({ providedIn: 'root' })
export class AcquisitionPathwaysApiService {
    private readonly request = inject(RequestService);

    /**
     * Filters are accepted as a single object (not positional args) so the
     * next ticket that adds `?stage=` / `?mode=` / `?archived=` is a
     * one-line addition rather than a breaking signature change. Today
     * only `type` is supported.
     */
    listMissions(
        filters?: { type?: AcquisitionMissionType },
    ): Observable<AcquisitionMissionListItem[]> {
        if (filters?.type) {
            const params = new HttpParams().set('type', filters.type);
            return this.request
                .getWithParams(BASE_PATH, params)
                .pipe(map((res) => res as AcquisitionMissionListItem[]));
        }
        return this.request
            .get(BASE_PATH)
            .pipe(map((res) => res as AcquisitionMissionListItem[]));
    }

    // … other methods unchanged …
}
```

**Implementation notes**:

- **`RequestService.getWithParams` is already shipped** on `origin/main` (`shared-services/request/request.service.ts`). Use it — do NOT add a new `RequestService.getWithQuery(pathname, Record<string,string>)` or similar; the existing API is the right seam.
- **Why not always go through `getWithParams`** with an empty `HttpParams`? Because the spec asserts the un-filtered case still calls `request.get(BASE_PATH)` (matches the existing spec verbatim — keeps the spec diff minimal and the unfiltered code path zero-allocation).
- **Other methods unchanged**: `getMission`, `createMission`, `updateMission`, `deleteMission`, `getMissionState`, `replaceMissionState`, `patchMissionState`. The DTO changes from §6.1 flow through them automatically because they accept and return the typed payloads.

**Spec coverage** (`acquisition-pathways-api.service.spec.ts`):

```ts
// In the existing beforeEach jasmine.createSpyObj call, add 'getWithParams':
requestSpy = jasmine.createSpyObj<RequestService>('RequestService', [
    'get',
    'getWithParams',
    'post',
    'patch',
    'put',
    'delete',
]);

// Bump the mockMission fixture to satisfy the now-required type:
const mockMission: AcquisitionMission = {
    /* … existing fields … */
    type: 'NEW',
    /* … */
};

const mockListItem: AcquisitionMissionListItem = {
    /* … existing fields … */
    type: 'NEW',
    /* … */
};

// Replace the single 'listMissions calls GET …' it() with two:
it('listMissions() with no filter calls GET /acquisition-pathways/missions', async () => {
    const list: AcquisitionMissionListItem[] = [mockListItem];
    requestSpy.get.and.returnValue(of(list));

    const result = await firstValueFrom(service.listMissions());

    expect(result).toEqual(list);
    expect(requestSpy.get).toHaveBeenCalledOnceWith(BASE_PATH);
    expect(requestSpy.getWithParams).not.toHaveBeenCalled();
});

it('listMissions({ type: "LEGACY" }) calls getWithParams with ?type=LEGACY', async () => {
    const list: AcquisitionMissionListItem[] = [{ ...mockListItem, type: 'LEGACY' }];
    requestSpy.getWithParams.and.returnValue(of(list));

    const result = await firstValueFrom(service.listMissions({ type: 'LEGACY' }));

    expect(result).toEqual(list);
    expect(requestSpy.getWithParams).toHaveBeenCalledTimes(1);
    const [path, params] = requestSpy.getWithParams.calls.mostRecent().args;
    expect(path).toBe(BASE_PATH);
    expect(params.get('type')).toBe('LEGACY');
    expect(requestSpy.get).not.toHaveBeenCalled();
});
```

The existing `BASE_PATH resolves to …` test (which calls `service.listMissions()` with no args) stays as-is. The runtime-cast-safety tests for `listMissions` (`returns null when RequestService.get emits null`) stay as-is — they exercise the no-filter branch. Add the symmetric `getWithParams emits null` case to lock in the filtered branch too:

```ts
it('listMissions({ type }) does not throw when getWithParams emits null', async () => {
    requestSpy.getWithParams.and.returnValue(of(null));

    const result = await firstValueFrom(service.listMissions({ type: 'NEW' }));

    expect(result).toBeNull();
});
```

The `createMission` / `updateMission` tests should also pass through a `type` value in their payload fixtures (just to lock in the round-trip — the assertion is `expect(requestSpy.post).toHaveBeenCalledOnceWith(BASE_PATH, payload)` with the new `type` field included).

### 7.2 `AcquisitionPathwaysService.getMissions(type?)` — UI-prototype mock

`rohan_ui-parent/rohan_ui/src/app/pages/acquisition-pathways/services/acquisition-pathways.service.ts` is the prototype-scaffolding mock service. Update it to accept the same filter the typed client does (in a simplified positional form — its callers are sparse) and to default the create round-trip's `type` to `'NEW'`.

```ts
import { AcquisitionMissionType, /* existing imports */ } from '../types/acquisition-pathways.types';

// TODO: Replace with actual API call — GET /acquisition-pathways/missions?type=<type>
getMissions(type?: AcquisitionMissionType): Observable<Mission[]> {
    const rows = type
        ? MOCK_MISSIONS.filter((m) => m.type === type)
        : MOCK_MISSIONS;
    return of(rows);
}

// TODO: Replace with actual API call — POST /acquisition-pathways/missions
createMission(payload: CreateMissionPayload): Observable<Mission> {
    return of({
        id: `mock-${Date.now()}`,
        ...payload,
        type: payload.type ?? 'NEW',
        status: 'Drafting',
        updatedAt: new Date().toISOString(),
        createdAt: new Date().toISOString(),
    } as Mission);
}
```

`uploadFiles`, `getAuditTrail`, `loadSampleMission` are **unchanged**.

**Mock data** — `services/mock-data.ts`: every entry in `MOCK_MISSIONS` gets an explicit `type`. Set most rows to `'NEW'` and at least one to `'LEGACY'` so the filter affordance has something to demo. The exact mix is cosmetic; the author picks whichever mix makes the missions table look healthy in the wizard.

**Spec coverage** — new file `services/acquisition-pathways.service.spec.ts` (mirrors the sibling `pathway-selection.service.spec.ts` pattern). Cover:

- `getMissions()` (no arg) returns the full `MOCK_MISSIONS` array.
- `getMissions('NEW')` returns only NEW-typed missions.
- `getMissions('LEGACY')` returns only LEGACY-typed missions.
- `createMission({ ..., type: 'LEGACY' })` returns a mock mission with `type === 'LEGACY'`.
- `createMission({ ... })` (no `type`) returns a mock mission with `type === 'NEW'`.

### 7.3 Component / template wiring

**Out of scope.** No `*.component.ts` / `*.component.html` / `*.component.scss` files are edited in this ticket. The one component-spec fixture change (`ap-missions-table.component.spec.ts` `mockMissions` literals) is described in plan step 2.10 — it's compile-required because of §6.2.1 making `Mission.type` required, not a UI feature change. Wiring a real filter into the missions-table UI (a `?type=` chip, a `NEW` / `LEGACY` badge column) is a separate ticket — this ticket only locks in the type system + service signatures + mock data so the UI ticket can be authored against stable types and live BE filtering.

---

## Tests added by this ticket (cross-reference; full details in the plan)

| File | New cases |
|---|---|
| `acquisition-pathways/services/ap-missions.service.spec.ts` | `create` defaults `type` when omitted; `create` accepts `'LEGACY'`; `findAll` with `{ type: 'NEW' }` filter; `findAll` with `{ type: 'LEGACY' }` filter; `findAll` with no filter returns both; slim projection includes `type`; `update` can change `type`; `findOne` returns `type` |
| `acquisition-pathways/controllers/ap-missions.controller.spec.ts` | `findAll` threads `?type=NEW` through to the service; invalid `?type=FOO` 400s before reaching the service; unknown query key (`?typo=NEW`) 400s; `POST` accepts `type` in body; `PATCH` accepts `type`; explicit `null` `type` on `POST` / `PATCH` 400s |
| `acquisition-pathways/dto/missions/create-acquisition-mission.dto.spec.ts` | DTO-level class-validator test: `type: 'NEW'` / `'LEGACY'` pass; `type: 'OTHER'` / `null` fail |
| `acquisition-pathways/dto/missions/update-acquisition-mission.dto.spec.ts` | Same shape as above for the update DTO |
| `acquisition-pathways/dto/missions/list-acquisition-missions-query.dto.spec.ts` | New spec: omitted `type` passes; `'NEW'` / `'LEGACY'` pass; `'OTHER'` / empty string fail; extra unknown key fails when whitelisted |
| `test/acquisition-pathways.e2e-spec.ts` | Append: `POST { type: 'LEGACY' }` round-trips; `GET /missions?type=LEGACY` returns the legacy row and excludes the NEW-typed row created earlier in the suite; `GET /missions?type=BOGUS` 400s |
| `pages/acquisition-pathways/services/acquisition-pathways-api.service.spec.ts` | Bump `mockMission` / `mockListItem` fixtures with `type: 'NEW'`; replace single `listMissions` test with filtered (`getWithParams`) + unfiltered (`get`) cases; add `getWithParams` to the `createSpyObj` array; add `getWithParams emits null` runtime-cast-safety case; bump `createMission` / `updateMission` payloads with `type` and assert round-trip |
| `pages/acquisition-pathways/services/acquisition-pathways.service.spec.ts` (new file) | `getMissions()` / `getMissions('NEW')` / `getMissions('LEGACY')` branches; `createMission` defaults `type` to `'NEW'` when omitted; `createMission` round-trips an explicit `'LEGACY'` |
| `pages/acquisition-pathways/components/missions-table/ap-missions-table.component.spec.ts` | Bump `mockMissions: Mission[]` literals: `'Alpha Mission'` → `type: 'NEW'`, `'Beta Mission'` → `type: 'LEGACY'`. Required-field compile fix, not a feature change. |
