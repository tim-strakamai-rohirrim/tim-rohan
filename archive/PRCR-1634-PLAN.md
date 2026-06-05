# PRCR-1634 — Add "Acquisition Pathways" to the Create Group → Feature Permissions UI

> Jira: [PRCR-1634](https://rohirrim.atlassian.net/browse/PRCR-1634).
> Companion contracts: `PRCR-1634-contracts.md`.

## Problem statement

The Settings → Groups → **Create Group** page renders a **Feature Permissions** checkbox list (Answer Engine, Solutions Architect, Proposal Writer, Graphics Lookbook, Compliance, …) that lets an admin grant a permission group access to specific product features. There is **no checkbox for Acquisition Pathways**, so admins cannot grant the `ACQUISITION_PATHWAYS` role from the UI — they would have to insert rows directly into the database.

This ticket adds an **Acquisition Pathways** option to that checkbox list. The end-to-end flow becomes:

1. Admin opens *Create Group*.
2. The Postgres feature flag `AcquisitionPathways` is enabled in this environment, so the new **Acquisition Pathways** checkbox is rendered (mirroring how Compliance/Evaluation gate behind their flags).
3. Admin checks it, names the group, picks members, saves.
4. On save, the `roles` array in the request includes the `role_id` for the seeded `Acquisition Pathways` role (description `ACQUISITION_PATHWAYS`).
5. `FeatureBlockingService.getUserFeatures()` (already implemented) flips `userFeatures.ACQUISITION_PATHWAYS = true` for members of that group, and they see the Acquisition Pathways side-nav link and page.

The actual Acquisition Pathways page, feature flag plumbing, and `FeatureBlock` wiring are **already implemented** under the separate `ROH-XXXX-acquisition-pathways` work (see `ROH-XXXX-acquisition-pathways-PLAN.md`). This ticket is the missing complementary admin UI / seed.

## Key architectural observations

### How Feature Permissions checkboxes are sourced

The list of checkboxes in `CreateEditGroupComponent` comes from three layers that all have to agree on the role's name + description:

1. **Backend Postgres seed** — `Database/rohan_api/scripts/sql/init_organizations.sql` defines:
   - The `permissions_feature_enum` (lines 5–18) — UPPER_SNAKE enum values such as `'ACQUISITION_CENTER'`, `'COMPLIANCE'`, `'EVALUATION'`.
   - The `permissions` rows (lines 314–327) — `(name, feature, display_name)` tuples like `('acquisition-center', 'ACQUISITION_CENTER', 'Acquisition Center')`.
   - The `roles` rows seeded from those permissions (lines 346–356) — name = `display_name`, description = `feature`, `group_role = true`.
   - The `roles_permissions_permissions` join (lines 358–369) — pairs each seeded role with its matching permission.
2. **NestJS `Feature` enum** — `rohan_api/src/admin/entities/permission.entity.ts`. This is consumed by the `@Features(...)` decorator on guarded endpoints. The enum has mixed casing (older kebab-case values like `ACQUISITION_CENTER = 'acquisition-center'`; newer UPPER_SNAKE values like `DEEP_RESEARCH = 'DEEP_RESEARCH'`). New entries follow UPPER_SNAKE because the **DB enum stores UPPER_SNAKE** — the TS enum value is what `@Features(...)` matches against.
3. **Angular Create-Group component** — `rohan_ui/src/app/pages/settings/components/rbac/create-edit-group/create-edit-group.component.ts`:
   - `getRoles()` calls `teamService.getGroupRoles()` (`GET /admin/roles?roles=group`) which returns every `group_role=true` role for the org.
   - The result is then **filtered by name** against one of two hardcoded allowlists:
     - `roleNamesForRp` (when `ProcurementWriterUtils.procureEnabled` is true) — currently includes Acquisition Center, Answer Engine V2, Deep Research, AC Deep Research, Compliance, Evaluation.
     - `roleNamesForRfp` (default) — currently includes Answer Engine V2, Solutions Architect, Proposal Writer, Graphics Lookbook, Deep Research, Knowledge Management, Compliance, Evaluation.
   - `groupRolesHierarchically()` then either nests certain roles (DEEP_RESEARCH under ANSWER_ENGINE_V2; AC_DEEP_RESEARCH under ACQUISITION_CENTER) or appends them as standalone top-level rows (Compliance, Evaluation).
   - Several roles (Deep Research, AC Deep Research, Knowledge Management, Compliance, Evaluation) are additionally **gated by a Postgres feature flag** in `updateGroupedRoles()`. A role passes the name filter but is dropped from the hierarchy if the corresponding `FeatureFlag.X` resolves to `false`.

A role that is missing from any **one** of these three layers does not appear as a checkbox.

### Relationship to the existing Acquisition Pathways work (`ROH-XXXX`)

Code that has already landed:

- `FeatureFlagsEnum.AcquisitionPathways = 'AcquisitionPathways'` in `rohan_api/src/utils/feature-flags/types/featureFlags.ts`.
- `FeatureFlag.ACQUISITION_PATHWAYS = 'AcquisitionPathways'` in `rohan_ui/src/app/shared-types/feature-flag.constants.ts`.
- `FeatureBlock.ACQUISITION_PATHWAYS: boolean` in `rohan_ui/src/app/shared-types/feature-block.types.ts`.
- `FeatureBlockingService.getEnabledFeatures$()` already fetches `acquisitionPathwaysEnabled` and ANDs it with `userFeatures.ACQUISITION_PATHWAYS` in the non-admin branch.
- `FeatureBlockingService.getUserFeatures()` already has a `case 'ACQUISITION_PATHWAYS'` that flips `userFeatures.ACQUISITION_PATHWAYS = true`.
- `AUTH_GUARD_URL_SEGMENTS.ACQUISITION_PATHWAYS = 'acquisition-pathways'` and the matching `AUTH_GUARD_FEATURE_SEGMENTS` entry are in place.
- The `/acquisition-pathways` route + page + side-nav entry are in place.
- `AuditTrailFeature.ACQUISITION_PATHWAYS = 'Acquisition-Pathways'` exists in `rohan_api/src/settings/audit-trail.constants.ts`.

What's **missing** (this ticket fixes):

- **No `'ACQUISITION_PATHWAYS'` value in the Postgres `permissions_feature_enum`** → can't seed a permission row.
- **No `permissions` row** with feature `ACQUISITION_PATHWAYS` → can't seed a role.
- **No `'Acquisition Pathways'` role** (description `ACQUISITION_PATHWAYS`, `group_role=true`) → never returned by `GET /admin/roles?roles=group`.
- **`Feature` TS enum on rohan_api doesn't include `ACQUISITION_PATHWAYS`** → minor: any future `@Features('ACQUISITION_PATHWAYS')` decorator would be untyped.
- **`roleNamesForRp` / `roleNamesForRfp` don't include `'Acquisition Pathways'`** → even if the role was returned, the FE filter would drop it.
- **`groupRolesHierarchically()` has no case for the new role** → never rendered as a checkbox.
- **No flag-gating wired through `updateGroupedRoles()`** → would render unconditionally instead of matching the Compliance/Evaluation pattern.

### Per-deployment behaviour (Rp vs Rfp)

The Acquisition Pathways page is shipped on **both** the low side and the high side per the existing ROH-XXXX plan. By symmetry the admin UI must surface the checkbox on **both** deployment variants, so `'Acquisition Pathways'` is added to **both** `roleNamesForRp` and `roleNamesForRfp`.

### Flag-gating decision

`Acquisition Pathways` follows the **Compliance/Evaluation** pattern: the checkbox is rendered only when the Postgres feature flag `AcquisitionPathways` resolves to `true` for the org. This avoids exposing a checkbox in environments where the feature itself is still hidden, and keeps the admin UI honest about what permissions are currently usable.

## Assumptions

1. The DB seed in `Database/rohan_api/scripts/sql/init_organizations.sql` is the canonical mechanism for creating the new permission + role. The script is run idempotently on every deployment (Helm post-install hook). There is no separate Alembic-style migration for `rohan_api` RBAC.
2. The `permissions_feature_enum` is rebuilt every time `init_organizations.sql` runs (line 3 explicitly `DROP TYPE IF EXISTS ... CASCADE`), so adding the new value to the `CREATE TYPE` list is sufficient — no separate `ALTER TYPE ADD VALUE` migration is required for fresh installs. For installations that already have the enum, the `DROP TYPE ... CASCADE` will rebuild it on the next run.
3. The Postgres feature flag row `AcquisitionPathways` will be enabled per environment via `pnpm enable-flag AcquisitionPathways` (already documented in the existing acquisition-pathways plan). Without it, the new checkbox stays hidden and the role is still seeded but unselectable from the UI.
4. Admins should be able to **select** the role, but assigning a group with the role to a user does **not** grant them anything user-facing until the Postgres flag is enabled in that environment. The two gates are independent on purpose.
5. The `Feature` TypeScript enum on rohan_api is updated for completeness even though no controller currently uses `@Features('ACQUISITION_PATHWAYS')`. Future ticket(s) that add backend endpoints for Acquisition Pathways will use the enum without further changes.
6. No existing role with description `'ACQUISITION_PATHWAYS'` is already present in any environment's database. (If one exists, the `ON CONFLICT DO NOTHING` clauses are safe — they preserve the existing row.)

## Open questions

1. **Role hierarchy placement.** Default: standalone top-level (mirrors Compliance/Evaluation). Acquisition Pathways is an independent feature, not a child of Acquisition Center. Alternative considered and rejected: nesting under Acquisition Center the way AC Deep Research is — semantically wrong because the two are independent pages.
2. **Display ordering.** Default: place "Acquisition Pathways" immediately after "Acquisition Center" in `roleNamesForRp` and at the end of the list in `roleNamesForRfp` (where there is no Acquisition Center). Adjust order in `groupRolesHierarchically()` if design wants a different position.
3. **Audit trail action constants.** Default: `AuditTrailFeature.ACQUISITION_PATHWAYS` already exists; no new audit-trail action strings are needed beyond what already gets emitted for any group create/edit (`AuditTrailAction.addPermissionGroupAction` / `updatePermissionGroupAction`).
4. **E2E coverage.** Default: add a unit-test assertion that the checkbox renders when the flag is enabled and is absent when disabled. Defer Playwright E2E to a follow-up unless QA explicitly wants it in this ticket.

## Implementation phases

### Phase 1 — Seed `Acquisition Pathways` permission + role in Postgres [BACKEND_DB]

```phase-meta
phase: 1
title: Add ACQUISITION_PATHWAYS to permissions_feature_enum + seed permission + role
tags: [BACKEND_DB]
repo: Database
base_branch: base
depends_on: []
files:
  - rohan_api/scripts/sql/init_organizations.sql
contracts:
  - "1.1 permissions_feature_enum addition"
  - "1.2 permissions row seed"
  - "1.3 roles_permissions_permissions seed"
verification:
  - psql -v ON_ERROR_STOP=1 -f rohan_api/scripts/run_all.sql  # local dry-run against a disposable DB
```

**Goal**: After re-running the seed, `SELECT name, description, group_role FROM roles WHERE description = 'ACQUISITION_PATHWAYS'` returns one row per org with `name = 'Acquisition Pathways'`, `group_role = true`, and that role is linked to a permission with feature `ACQUISITION_PATHWAYS`.

**Steps**:

- [ ] **1.1** Add `'ACQUISITION_PATHWAYS'` to the `CREATE TYPE "permissions_feature_enum" AS ENUM(...)` list at the top of `Database/rohan_api/scripts/sql/init_organizations.sql` (currently lines 5–18). Insert it adjacent to `'ACQUISITION_CENTER'` for grouping. See contracts §1.1.

- [ ] **1.2** Add a permission row to the `INSERT INTO permissions (name, feature, display_name) VALUES` block (currently lines 314–327):
  ```sql
  ('acquisition-pathways', 'ACQUISITION_PATHWAYS', 'Acquisition Pathways'),
  ```
  Place it directly after the `acquisition-center` row. See contracts §1.2.

- [ ] **1.3** Add the join row to the `INSERT INTO roles_permissions_permissions ("rolesRoleId", "permissionsPermissionId") VALUES` block (currently lines 358–369):
  ```sql
  ((SELECT role_id FROM roles WHERE description = 'ACQUISITION_PATHWAYS'), (SELECT permission_id FROM permissions WHERE feature ='ACQUISITION_PATHWAYS')),
  ```
  Place it directly after the `ACQUISITION_CENTER` join row. See contracts §1.3.

- [ ] **1.4** No change to the `UPDATE "roles" SET "group_role" = CASE ... WHEN "name" IN (...) THEN true` block (lines 95–102): the existing `COALESCE("group_role", true)` default already covers any newly-seeded `Acquisition Pathways` row.

- [ ] **1.5** No standalone `ALTER TYPE permissions_feature_enum ADD VALUE 'ACQUISITION_PATHWAYS'` migration is needed: line 3 (`DROP TYPE IF EXISTS "permissions_feature_enum" CASCADE`) rebuilds the enum on every run.

- [ ] **1.6** Verification: spin up a disposable Postgres (`docker run --rm postgres:16-alpine`), run `psql -v ON_ERROR_STOP=1 -f rohan_api/scripts/run_all.sql`, then assert:
  ```sql
  SELECT 1 FROM pg_enum WHERE enumlabel = 'ACQUISITION_PATHWAYS' AND enumtypid = 'permissions_feature_enum'::regtype;
  SELECT 1 FROM permissions WHERE feature = 'ACQUISITION_PATHWAYS';
  SELECT 1 FROM roles WHERE description = 'ACQUISITION_PATHWAYS' AND group_role = true;
  SELECT 1 FROM roles_permissions_permissions rpp
    JOIN roles r ON r.role_id = rpp."rolesRoleId"
    JOIN permissions p ON p.permission_id = rpp."permissionsPermissionId"
    WHERE r.description = 'ACQUISITION_PATHWAYS' AND p.feature = 'ACQUISITION_PATHWAYS';
  ```
  All four queries must return one row per org.

---

### Phase 2 — Add `ACQUISITION_PATHWAYS` to the rohan_api `Feature` enum [BACKEND_DB]

```phase-meta
phase: 2
title: Add ACQUISITION_PATHWAYS to permission.entity.ts Feature enum
tags: [BACKEND_DB]
repo: rohan_api
base_branch: base
depends_on: []
files:
  - src/admin/entities/permission.entity.ts
contracts:
  - "2.1 Feature.ACQUISITION_PATHWAYS"
verification:
  - npm run lint
  - npm run test -- src/admin
```

**Goal**: Complete the TypeScript-side mirror of the Postgres enum so that any future `@Features('ACQUISITION_PATHWAYS')` decorator is well-typed and pattern-matches the existing convention. No functional behaviour changes in this phase.

**Steps**:

- [ ] **2.1** Add `ACQUISITION_PATHWAYS = 'ACQUISITION_PATHWAYS'` to the `Feature` enum in `rohan_api/src/admin/entities/permission.entity.ts`. Place it directly after `ACQUISITION_CENTER` for grouping. Note the value is UPPER_SNAKE (matching the Postgres enum) rather than kebab-case — this follows the same convention as the more recent `DEEP_RESEARCH = 'DEEP_RESEARCH'` entry. See contracts §2.1.

- [ ] **2.2** Run verification: `npm run lint && npm run test -- src/admin`. No spec changes expected; the addition is a non-breaking enum extension.

- [ ] **2.3** Do **not** add any `@Features('ACQUISITION_PATHWAYS')` decorator anywhere in this phase. There are no Acquisition Pathways endpoints yet; that lands when the page gets real data.

> Parallelism note: Phase 1 and Phase 2 are in different repos and have no dependency on each other. They can ship in parallel. Phase 3 (rohan_ui) depends on Phase 1 only (the role must exist in the DB before the UI can render and persist it).

---

### Phase 3 — Render and gate the "Acquisition Pathways" checkbox in Create Group [FRONTEND]

```phase-meta
phase: 3
title: Add Acquisition Pathways to Feature Permissions checkbox list
tags: [FRONTEND]
repo: rohan_ui
base_branch: base
depends_on: [1]
files:
  - src/app/pages/settings/constants/settings.constants.ts
  - src/app/pages/settings/components/rbac/create-edit-group/create-edit-group.component.ts
  - src/app/pages/settings/components/rbac/create-edit-group/create-edit-group.component.spec.ts
contracts:
  - "3.1 acquisitionPathwaysRoleDescription constant"
  - "3.2 roleNamesForRp + roleNamesForRfp additions"
  - "3.3 FeatureFlag.ACQUISITION_PATHWAYS gating in updateGroupedRoles"
  - "3.4 groupRolesHierarchically — standalone top-level case"
  - "3.5 getRoleDisplayName — Acquisition Pathways"
verification:
  - npm run lint
  - npm run test -- --include='src/app/pages/settings/components/rbac/create-edit-group/**/*.spec.ts'
```

**Goal**: When the Postgres feature flag `AcquisitionPathways` is enabled, the Feature Permissions section on the Create/Edit Group page renders an **Acquisition Pathways** checkbox as a standalone top-level row. Checking it adds the seeded `Acquisition Pathways` role's `role_id` to the form payload. When the flag is disabled, the checkbox is hidden.

**Steps**:

- [ ] **3.1** Add `acquisitionPathwaysRoleDescription = 'ACQUISITION_PATHWAYS'` to `src/app/pages/settings/constants/settings.constants.ts`, adjacent to the existing `evaluationRoleDescription`. See contracts §3.1.

- [ ] **3.2** Add `'Acquisition Pathways'` to **both** `roleNamesForRp` and `roleNamesForRfp` in `create-edit-group.component.ts`. Place it immediately after `'Acquisition Center'` in `roleNamesForRp`; append to the end of `roleNamesForRfp` (where there is no Acquisition Center entry). See contracts §3.2.

- [ ] **3.3** Add a new feature-flag observable to the component (alongside the existing `complianceFeatureFlag$` / `evaluationFeatureFlag$`):
  ```ts
  acquisitionPathwaysFeatureFlag$: Observable<boolean>;
  ```
  Initialize it in `ngOnInit`:
  ```ts
  this.acquisitionPathwaysFeatureFlag$ = this.ffService.isFeatureEnabled(
      FeatureFlag.ACQUISITION_PATHWAYS,
  );
  ```
  Add a key to the `forkJoin(...)` in `updateGroupedRoles()` and pass the resolved boolean as a new `includeAcquisitionPathways` parameter to `groupRolesHierarchically()`. See contracts §3.3. (Import path: `FeatureFlag` is already imported.)

- [ ] **3.4** Extend `groupRolesHierarchically()` so that when `includeAcquisitionPathways === true` and a role with `description === acquisitionPathwaysRoleDescription` is present in `roles`, it is appended as a standalone top-level row (no children, mirrors how `complianceRole` and `evaluationRole` are appended at the end of the method). Also exclude that description from the main `forEach` that builds parent/child rows, so it is not double-counted. See contracts §3.4.

- [ ] **3.5** Update `getRoleDisplayName()` to return `'Acquisition Pathways'` when `role.description === acquisitionPathwaysRoleDescription` (defensive; matches the Compliance/Evaluation pattern even though `role.name` already equals `'Acquisition Pathways'` from the seed). See contracts §3.5.

- [ ] **3.6** No changes to `updateCheckedRoles()`, `handleRoleDependencies()`, or `isRoleDisabled()` — Acquisition Pathways has no parent/child dependency and is not disabled by any other role.

- [ ] **3.7** Update `create-edit-group.component.spec.ts`:
  - In the existing `FeatureFlagsService` provider mock (`isFeatureEnabled: () => of(true)`), the default of `true` already covers the new flag — no provider change needed.
  - In the existing `AEV1 feature flag role filtering` describe block (and any other test that builds `mockRoles`), add a mock `Acquisition Pathways` role:
    ```ts
    {
        role_id: 99,
        name: 'Acquisition Pathways',
        description: 'ACQUISITION_PATHWAYS',
        // …timestamps and emails…
    } as Role,
    ```
  - Add two new tests under a `Acquisition Pathways feature flag gating` describe:
    1. **enabled**: when `FeatureFlag.ACQUISITION_PATHWAYS` resolves to `true`, `component.groupedRoles` includes one entry with `role.description === 'ACQUISITION_PATHWAYS'` after `getRoles()` resolves.
    2. **disabled**: when `FeatureFlag.ACQUISITION_PATHWAYS` resolves to `false`, `component.groupedRoles` contains no such entry, even though the role is present in the `getGroupRoles()` mock response.
  - Add a test that asserts `getRoleDisplayName({ description: 'ACQUISITION_PATHWAYS', name: 'Acquisition Pathways' } as Role)` returns `'Acquisition Pathways'`.

- [ ] **3.8** Manual smoke (post-deploy):
  1. Confirm the Postgres flag `AcquisitionPathways` is enabled (`pnpm enable-flag AcquisitionPathways` from rohan_api).
  2. As an admin, open `/settings/groups`, create a new group, confirm the **Acquisition Pathways** checkbox appears in Feature Permissions.
  3. Check it, save the group, assign a non-admin user.
  4. Sign in as that user — confirm the Acquisition Pathways side-nav link and page are now accessible.
  5. Disable the flag (`pnpm disable-flag AcquisitionPathways`), reload Create Group — confirm the checkbox is gone.

- [ ] **3.9** Run verification: `npm run lint && npm run test -- --include='src/app/pages/settings/components/rbac/create-edit-group/**/*.spec.ts'`.

## Phase order and parallelism

### File-touch matrix

| File | P1 | P2 | P3 |
| ---- | -- | -- | -- |
| `Database/rohan_api/scripts/sql/init_organizations.sql` | edit | — | — |
| `rohan_api/src/admin/entities/permission.entity.ts` | — | edit | — |
| `rohan_ui/src/app/pages/settings/constants/settings.constants.ts` | — | — | edit |
| `rohan_ui/src/app/pages/settings/components/rbac/create-edit-group/create-edit-group.component.ts` | — | — | edit |
| `rohan_ui/src/app/pages/settings/components/rbac/create-edit-group/create-edit-group.component.spec.ts` | — | — | edit |

### Parallelism

- **Phase 1 and Phase 2 are independent** and can ship in parallel. They live in two different repos with their own CI/CD pipelines; neither imports from the other.
- **Phase 3 depends on Phase 1** at deploy-time, not code-time. Phase 3's UI will compile and the unit tests will pass regardless of Phase 1, but the new checkbox is only useful once Phase 1 has been seeded into the environment's database (otherwise saving a group with it checked would fail because there is no `role_id` to assign).
- Phase 3 does **not** depend on Phase 2 — `Feature.ACQUISITION_PATHWAYS` is a TS-enum hygiene change with no runtime consumer in this ticket.

### Recommended order

1. Phase 1 (Database) — single SQL file, three small edits. Land first so the role row is present in the next deployment.
2. Phase 2 (rohan_api) — trivial enum addition. Can land in parallel with Phase 1.
3. Phase 3 (rohan_ui) — UI + flag gating. Land after Phase 1 has deployed to the target environment.

> Three phases across three repos is the minimum: the "one phase = one PR" convention used by the implementation skills means each repo gets its own PR.

## Phase context summaries

**Phase 1 — Database seed.** Single-file edit to `Database/rohan_api/scripts/sql/init_organizations.sql`. Three changes: add `'ACQUISITION_PATHWAYS'` to the `permissions_feature_enum` CREATE TYPE list (around line 17); add `('acquisition-pathways', 'ACQUISITION_PATHWAYS', 'Acquisition Pathways')` to the `INSERT INTO permissions` block (around line 320); add the matching join row to `INSERT INTO roles_permissions_permissions` (around line 363). The downstream `INSERT INTO roles ... SELECT display_name as name, feature as description ... true as group_role FROM permissions` block at line 346 will then auto-seed a row with `name = 'Acquisition Pathways'`, `description = 'ACQUISITION_PATHWAYS'`, `group_role = true`. No standalone `ALTER TYPE` migration is needed because line 3 `DROP TYPE IF EXISTS ... CASCADE` rebuilds the enum on every run. Depends on nothing. Gotcha: the second column of `INSERT INTO permissions` is the **UPPER_SNAKE** Postgres-enum value (`'ACQUISITION_PATHWAYS'`), not the kebab-case `name` — older entries in the same VALUES block use kebab-case for column 1 but UPPER_SNAKE for column 2, which is correct.

**Phase 2 — rohan_api Feature enum.** Single-line addition to `src/admin/entities/permission.entity.ts`: `ACQUISITION_PATHWAYS = 'ACQUISITION_PATHWAYS'` inside the `Feature` enum, placed next to `ACQUISITION_CENTER`. Use UPPER_SNAKE (matching the Postgres enum value and the newer convention used by `DEEP_RESEARCH = 'DEEP_RESEARCH'`). The TS enum is consumed by the `@Features(...)` decorator on guarded endpoints; no controller in this ticket needs the new value, but adding it now means future Acquisition Pathways endpoints can use `@Features('ACQUISITION_PATHWAYS')` without further changes. Depends on nothing. Gotcha: do **not** copy the old kebab-case pattern (`ACQUISITION_CENTER = 'acquisition-center'`) — that style is legacy.

**Phase 3 — rohan_ui Create Group UI.** Adds `acquisitionPathwaysRoleDescription = 'ACQUISITION_PATHWAYS'` to `settings.constants.ts`; adds `'Acquisition Pathways'` to **both** `roleNamesForRp` and `roleNamesForRfp` in `create-edit-group.component.ts`; introduces `acquisitionPathwaysFeatureFlag$` initialised from `FeatureFlag.ACQUISITION_PATHWAYS`; extends `updateGroupedRoles()`'s `forkJoin` and `groupRolesHierarchically()` to accept and apply the new flag; adds a standalone top-level branch in `groupRolesHierarchically()` that appends the Acquisition Pathways role when the flag is on (mirroring the Compliance/Evaluation pattern); extends `getRoleDisplayName()` with a defensive `ACQUISITION_PATHWAYS` case; and adds spec coverage for the enabled/disabled gating and the display-name case. Depends on Phase 1 at deploy-time (the role must exist before the UI can render and save it). Gotchas: (a) `'Acquisition Pathways'` must be added to **both** `roleNamesFor*` lists or only one deployment variant will show it; (b) when extending `groupRolesHierarchically()`, the new `acquisitionPathwaysRoleDescription` must be added to the `forEach`'s exclusion guard alongside `complianceRoleDescription` and `evaluationRoleDescription`, otherwise the role will appear **twice** (once in the parent loop, once in the standalone append at the end); (c) the existing `FeatureFlagsService` test mock returns `of(true)` by default, so any negative-case test must override with a per-flag stub.

## Branching convention

Phases produce branches in three different repos. There is no shared git history, so "stacking" here means deployment ordering, not branch ancestry:

```
{user}/PRCR-1634/phase-1   (Database repo)
{user}/PRCR-1634/phase-2   (rohan_api repo)
{user}/PRCR-1634/phase-3   (rohan_ui repo)
```

Each phase produces its own PR against the target repo's default branch (`main` / `develop`). Phase 3's PR description should explicitly note that Phase 1 must be deployed to the target environment before Phase 3 is QA'd.

## Deployment notes (operational, not code)

After Phase 1's PR merges and the SQL seed runs in an environment:

```sql
-- Sanity-check the seed landed:
SELECT name, description, group_role FROM roles WHERE description = 'ACQUISITION_PATHWAYS';
```

For the new checkbox to appear in the UI after Phase 3 ships, the Postgres feature flag must be enabled per environment:

```bash
cd rohan_api-parent/rohan_api
pnpm enable-flag AcquisitionPathways
```

(This is the same operational step already documented in `ROH-XXXX-acquisition-pathways-PLAN.md` deployment notes. The same flag gates both the page visibility and the new admin checkbox.)

## Jira ticket

**Title**: `[PRCR-1634] Settings → Create Group: add "Acquisition Pathways" Feature Permission`

**Description**:

> Add an **Acquisition Pathways** checkbox to the Feature Permissions section of the Create/Edit Group page in Settings. Seeds the backing Postgres permission and role (`name = 'Acquisition Pathways'`, `description = 'ACQUISITION_PATHWAYS'`, `group_role = true`) in `init_organizations.sql`, mirrors the value into the rohan_api `Feature` TS enum, adds `'Acquisition Pathways'` to both `roleNamesForRp` and `roleNamesForRfp` allowlists, and renders the checkbox as a standalone top-level row gated by the existing Postgres feature flag `AcquisitionPathways` (mirroring the Compliance/Evaluation pattern).
>
> The page, route, side-nav entry, `FeatureBlock` wiring, AuthGuard segment, and RBAC `case 'ACQUISITION_PATHWAYS'` in `getUserFeatures()` were already implemented under `ROH-XXXX-acquisition-pathways`; this ticket adds the missing admin UI so that the role can be granted through the standard Group editor rather than direct DB inserts.
>
> Operationally, after deploy, `pnpm enable-flag AcquisitionPathways` is required per environment for the checkbox to appear in the UI.

**Acceptance criteria**:

- [ ] **Phase 1**: `Database/rohan_api/scripts/sql/init_organizations.sql` contains `'ACQUISITION_PATHWAYS'` in `permissions_feature_enum`, a `('acquisition-pathways', 'ACQUISITION_PATHWAYS', 'Acquisition Pathways')` row in `INSERT INTO permissions`, and a matching join row in `INSERT INTO roles_permissions_permissions`. A fresh `psql -f run_all.sql` against a disposable DB returns one row from `SELECT * FROM roles WHERE description = 'ACQUISITION_PATHWAYS' AND group_role = true` per org.
- [ ] **Phase 2**: `rohan_api/src/admin/entities/permission.entity.ts` `Feature` enum includes `ACQUISITION_PATHWAYS = 'ACQUISITION_PATHWAYS'`. `npm run lint` and existing `src/admin` Jest specs pass with no changes.
- [ ] **Phase 3**: When `FeatureFlag.ACQUISITION_PATHWAYS` resolves to `true` and the admin opens `/settings/groups/create`, the Feature Permissions section renders an **Acquisition Pathways** checkbox as a standalone top-level row. Checking it includes the role's `role_id` in the `groupForm.value.features` array. When the flag resolves to `false`, the checkbox is absent. `getRoleDisplayName` returns `'Acquisition Pathways'` for a role with `description === 'ACQUISITION_PATHWAYS'`. Unit tests pass; lint passes.
- [ ] **Manual smoke**: With the Postgres flag enabled and a non-admin user assigned to a new group with the Acquisition Pathways permission, that user sees the Acquisition Pathways side-nav link and can navigate to `/acquisition-pathways`. With the flag disabled or the group permission unchecked, the link is hidden and the route redirects per the existing AuthGuard rules.
