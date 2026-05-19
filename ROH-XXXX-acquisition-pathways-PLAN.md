# ROH-XXXX — Acquisition Pathways page (base structure)

> Ticket ID is a placeholder (`ROH-XXXX-acquisition-pathways`). Replace `ROH-XXXX` throughout once the real JIRA ticket exists. Rename this file and the companion contracts file to match.

## Problem statement

Introduce a new page called **Acquisition Pathways** that ships on **both** the low side and the high side of the Rohan platform. This change is the **base structure** — the page itself is an empty scaffold (heading + non-functional search bar + "No pathways yet" empty state) — but it is wired into the existing feature-flag and RBAC infrastructure exactly like Acquisition Center is. A new Postgres-backed feature flag `AcquisitionPathways` controls visibility per user. No data, no API endpoints, no DB tables in this ticket — those land in follow-up tickets.

## Key architectural observations

### How Acquisition Center handles low/high side variants

- **One Angular module, one route, one side-nav entry** serves both variants: `ProcurementWriterModule` at `/acquisition-center`. The new Acquisition Pathways module follows the same shape.
- **Variant differences live inside the module**, driven by `ProcurementWriterUtils.highSideEnabled` (a static getter over `RohanSettings.PROCURE_HIGH_SIDE_ENABLED`):
  - **Routing-level variants** — `procurement-writer-routing.module.ts:45-64` uses `...(ProcurementWriterUtils.highSideEnabled ? [highSideRoutes] : [lowSideRoutes])` inside the route table. High side gets `analysis-assistant`; low side gets `rfi-assistant` + `mra-assistant`.
  - **Template-level variants** — `procurement-writer-landing-page.component.html:41` uses `@if (highSideEnabled) { ... }` to render the Projects table only on high side.
  - **Code-level variants** — `procurement-writer-landing-page.component.ts:64-72` branches navigation logic on `ProcurementWriterUtils.highSideEnabled`.
- For this ticket the page is **identical across both sides**, so no variant code is added yet — but the page is structured so a future PR can drop `highSideEnabled` checks in the same way Acquisition Center does.

### Two-layer per-user gating (Postgres flag + RBAC group)

Newer features (`COMPLIANCE`, `ONE_RING`, `PROPOSAL_ENGINE`, `DEVELOPER_TOOLS`, `EVALUATION`) follow a consistent gate pattern. Acquisition Pathways will mirror it exactly:

1. **Postgres-backed feature flag** via `FeatureFlagsService.isFeatureEnabled(FeatureFlag.X)`. This hits `GET /admin/feature-flag/{flagName}` on rohan_api (`feature-flags.service.ts:37`), which validates the name against `FeatureFlagsEnum` (`rohan_api/.../types/featureFlags.ts:3-32`) and reads the row from the `feature_flags` Postgres table.
2. **`FeatureBlock` key** — every gate-able page has a boolean field in `FeatureBlock` (`src/app/shared-types/feature-block.types.ts`). `FeatureBlockingService.getEnabledFeatures$()` populates it from the Postgres flag and ANDs it with the user's RBAC group membership.
3. **RBAC group description** — `FeatureBlockingService.getUserFeatures()` (`feature-blocking.service.ts:225-277`) walks the user's `MemberRole[]` and flips `userFeatures.X = true` when a group with `description === 'X'` is found. Non-admin users only get the feature if both the Postgres flag AND a group grant it.
4. **`AuthGuard` route segment** — `AUTH_GUARD_FEATURE_SEGMENTS` (`auth.guard.constants.ts:22`) maps URL segments to FeatureBlock keys. Users whose `FeatureBlock[key]` is `false` are redirected on navigation.
5. **Side-nav rendering** — `side-nav-bar.component.html` wraps each link in `@if (features['X']) { ... }`. The features signal is supplied by `AuthStateService.features$`.

### Deployment-time vs per-user gating (clarification)

- `RohanSettings.PROCURE_HIGH_SIDE_ENABLED` is a **deployment** flag baked into `src/assets/scripts/settings.js` from `helm/values.yaml`. It does **not** control whether Acquisition Pathways appears — it only flips which **variant** of the page renders for any user who already has access.
- `FeatureFlag.ACQUISITION_PATHWAYS` (new, Postgres) + RBAC group decide **who has access** on each deployment.
- The same code ships to both deployments; the deployment toggle merely changes the in-page variant.

### Existing FeatureFlag enum mirroring

The `FeatureFlag` enum on the FE (`src/app/shared-types/feature-flag.constants.ts`) must always match the rohan_api `FeatureFlagsEnum` (`src/utils/feature-flags/types/featureFlags.ts`). If a FE flag name is missing from the BE enum, the BE logs `Unknown feature flag` warnings and `/admin/feature-flag/{name}` returns `{ isEnabled: false }` regardless of the DB row. Therefore the BE enum update must land **first**.

### Per-environment Postgres seed (operational, not code)

A new `FeatureFlagsEnum` value does **not** create the corresponding row in the `feature_flags` table. The flag row must be created per environment using `pnpm enable-flag AcquisitionPathways` from `rohan_api/`. This is captured in the deployment notes section of this plan but is **not** part of any code phase.

## Assumptions

1. The placeholder ticket ID `ROH-XXXX-acquisition-pathways` will be replaced with the real ticket before merge; both files renamed accordingly.
2. The page lives at the **top level** as `/acquisition-pathways`, parallel to `/acquisition-center`. It is **not** nested under `/acquisition-center`.
3. The page is **identical for low side and high side in this ticket**. No `highSideEnabled` branches are introduced yet; future tickets may add them inside the new module following the Acquisition Center pattern.
4. The new module is **NgModule-based, non-standalone** (workspace convention).
5. Visibility is gated by **all three**: (a) Postgres-backed `FeatureFlag.ACQUISITION_PATHWAYS`, (b) RBAC group with `description === 'ACQUISITION_PATHWAYS'`, (c) AuthGuard segment mapping. Admins bypass via the existing admin branch in `FeatureBlockingService.getEnabledFeatures$()`.
6. The search bar is **non-functional** in this phase — it stores `searchTerm` locally and toggles the empty-results message. No service is created.
7. Page tracking uses the existing `AppInsightsService` (`pageView` on `ngOnInit`, `logTimeSpent` on `ngOnDestroy`) and `TimeMetricTrackerService.startTracking('Acquisition-Pathways')` triggered from the side-nav, matching Graphics Lookbook and Compliance.
8. A placeholder SVG `acquisition-pathways.svg` ships under `src/assets/icons/nav/`. Final designer artwork can swap in without code changes.

## Open questions

1. **Backend flag-enum group membership.** Should the new flag join `FeatureFlagGroups['unified-acquire']` in `rohan_api/.../groups.ts`? Default: **no** — Acquisition Pathways is a new feature, not part of the existing unified-acquire bundle. Operators enable it explicitly.
2. **Side-nav placement.** Default: immediately below the **Acquisition Center** link, before the Proposal Engine link. Adjust to taste; the gating is independent.
3. **Empty-state copy.** Default: idle = `Enter a concept to start exploring acquisition pathways.`; post-search empty = `No pathways yet.`. Easy to change in `acquisition-pathways.constants.ts`.
4. **Analytics ID naming.** Default: `NAV_ACQUISITION_PATHWAYS = 'side_nav_acquisition_pathways'` (matches existing snake_case `side_nav_*` convention).
5. **Time-metric feature label.** Default: `'Acquisition-Pathways'` (matches `'Acquisition-Center'` / `'Graphics-Lookbook'`).
6. **Icon artwork.** Default: temporary placeholder SVG; designer asset swaps in later.

## Implementation phases

### Phase 1 — Register `AcquisitionPathways` in the backend feature-flag enum [BACKEND_DB]

```phase-meta
phase: 1
title: Add AcquisitionPathways to rohan_api FeatureFlagsEnum
tags: [BACKEND_DB]
repo: rohan_api
base_branch: base
depends_on: []
files:
  - src/utils/feature-flags/types/featureFlags.ts
contracts:
  - "1.1 FeatureFlagsEnum.AcquisitionPathways (rohan_api)"
verification:
  - npm run lint
  - npm run test -- src/utils/feature-flags/types/featureFlags.spec.ts
  - npm run test -- src/utils/feature-flags/feature-flags.service.spec.ts
```

**Goal**: Make `AcquisitionPathways` a valid flag name on the backend so `/admin/feature-flag/AcquisitionPathways` recognizes the request and returns the DB-backed value (or `{ isEnabled: false }` if no row exists).

**Steps**:

- [ ] **1.1** Add `AcquisitionPathways = 'AcquisitionPathways'` to the `FeatureFlagsEnum` in `src/utils/feature-flags/types/featureFlags.ts`. Insert it in the existing `Procure*` cluster (next to `ProcureHighSide`/`ProcureLowSide`/`ProcurementWriter`) for grouping consistency.

- [ ] **1.2** Run verification: lint + targeted specs (the existing `featureFlags.spec.ts` and `feature-flags.service.spec.ts` validate enum integrity).

- [ ] **1.3** Do **not** add the new flag to `FeatureFlagGroups['unified-acquire']` in `groups.ts` (see Open question 1 — default is no).

---

### Phase 2 — Wire the Postgres flag + RBAC into the rohan_ui feature-blocking layer [FRONTEND]

```phase-meta
phase: 2
title: Add ACQUISITION_PATHWAYS feature flag + FeatureBlock + RBAC wiring
tags: [FRONTEND]
repo: rohan_ui
base_branch: phase-1
depends_on: [1]
files:
  - src/app/shared-types/feature-flag.constants.ts
  - src/app/shared-types/feature-block.types.ts
  - src/app/shared-services/feature-blocking/feature-blocking.constants.ts
  - src/app/shared-services/feature-blocking/feature-blocking.service.ts
  - src/app/shared-services/feature-blocking/feature-blocking.service.spec.ts
  - src/app/shared-services/feature-blocking/auth.guard.constants.ts
  - src/app/shared-services/feature-blocking/auth.guard.spec.ts
contracts:
  - "1.2 FeatureFlag.ACQUISITION_PATHWAYS (rohan_ui)"
  - "2.1 FeatureBlock.ACQUISITION_PATHWAYS"
  - "2.2 FEATURE_BLOCK_ALL_DISABLED update"
  - "3.1 getEnabledFeatures$ — new Postgres flag fetch"
  - "3.2 getUserFeatures — RBAC group description case"
  - "4.1 AUTH_GUARD_URL_SEGMENTS.ACQUISITION_PATHWAYS"
  - "4.2 AUTH_GUARD_FEATURE_SEGMENTS entry"
verification:
  - npm run lint
  - npm run test -- --include='src/app/shared-services/feature-blocking/**/*.spec.ts'
```

**Goal**: Make `features['ACQUISITION_PATHWAYS']` flow from the Postgres flag + RBAC group through `AuthStateService.features$` so any component (side-nav, route guard, page) can gate on it. The new key is **not** yet referenced by any UI in this phase — that lands in Phase 3.

**Steps**:

- [ ] **2.1** Add `ACQUISITION_PATHWAYS = 'AcquisitionPathways'` to `FeatureFlag` in `src/app/shared-types/feature-flag.constants.ts`. The string value must match the BE `FeatureFlagsEnum` value exactly. Place it adjacent to the existing `PROCUREMENT_WRITER` / `PROCURE_HIGH_SIDE` cluster.

- [ ] **2.2** Add `ACQUISITION_PATHWAYS: boolean` to the `FeatureBlock` type in `src/app/shared-types/feature-block.types.ts`. See contracts §2.1.

- [ ] **2.3** Add `ACQUISITION_PATHWAYS: false` to `FEATURE_BLOCK_ALL_DISABLED` in `src/app/shared-services/feature-blocking/feature-blocking.constants.ts`. See contracts §2.2.

- [ ] **2.4** Update `FeatureBlockingService.getEnabledFeatures$()` in `feature-blocking.service.ts` to fetch the new flag:
  - Add a key to the `forkJoin` object: `acquisitionPathwaysEnabled: this.featureFlags.isFeatureEnabled(FeatureFlag.ACQUISITION_PATHWAYS).pipe(take(1))`.
  - Destructure `acquisitionPathwaysEnabled` from the result and pass it into the `featuresV2` object handed to `parseFeaturesToBoolean(...)`.
  - In the non-admin branch (`if (!this.teamService.userIsAdmin())`), add `parsedFeatures.ACQUISITION_PATHWAYS = parsedFeatures.ACQUISITION_PATHWAYS && userFeatures.ACQUISITION_PATHWAYS;`. See contracts §3.1.

- [ ] **2.5** Update `parseFeaturesToBoolean()` so its `featuresV2` parameter type includes `acquisitionPathwaysEnabled?: boolean` and the return value sets `ACQUISITION_PATHWAYS: featuresV2.acquisitionPathwaysEnabled ?? false`. Mirror the existing `COMPLIANCE`/`ONE_RING`/`EVALUATION` pattern. See contracts §3.1.

- [ ] **2.6** Update `getUserFeatures()` switch to add a case:
  ```ts
  case 'ACQUISITION_PATHWAYS': {
      userFeatures.ACQUISITION_PATHWAYS = true;
      break;
  }
  ```
  See contracts §3.2.

- [ ] **2.7** Update the spec at `feature-blocking.service.spec.ts`:
  - Add `ACQUISITION_PATHWAYS: true` to the `mockFeatures: FeatureBlock` literal so the type still type-checks (line ~28).
  - Add a new test under `describe('parseFeaturesToBoolean')` that asserts `ACQUISITION_PATHWAYS` is set from `featuresV2.acquisitionPathwaysEnabled` (mirror the existing `COMPLIANCE`/`EVALUATION` cases).
  - Update any test that mocks `mockFeatureFlagsService.isFeatureEnabled` to also return a value for `FeatureFlag.ACQUISITION_PATHWAYS` (use `.withArgs(...)` if applicable, or default to `of(false)` so the forkJoin completes).
  - Add a test for `getUserFeatures()` that confirms a `MemberRole` with `description: 'ACQUISITION_PATHWAYS'` sets `userFeatures.ACQUISITION_PATHWAYS = true`.

- [ ] **2.8** Add an entry to `AUTH_GUARD_URL_SEGMENTS` in `src/app/shared-services/feature-blocking/auth.guard.constants.ts`:
  ```ts
  ACQUISITION_PATHWAYS: 'acquisition-pathways',
  ```
  and a corresponding entry in `AUTH_GUARD_FEATURE_SEGMENTS`:
  ```ts
  {
      segment: AUTH_GUARD_URL_SEGMENTS.ACQUISITION_PATHWAYS,
      featureKey: 'ACQUISITION_PATHWAYS',
  },
  ```
  See contracts §4.1, §4.2.

- [ ] **2.9** Update `auth.guard.spec.ts` to cover the new segment: a user with `ACQUISITION_PATHWAYS === true` is allowed onto `/acquisition-pathways`; a user with `false` is redirected per the existing redirect rules in `checkEnabledFeature$`. Mirror the existing `ACQUISITION_CENTER` test if one exists.

- [ ] **2.10** Run verification.

---

### Phase 3 — Scaffold the Acquisition Pathways page and side-nav entry [FRONTEND]

```phase-meta
phase: 3
title: Add Acquisition Pathways module, route, page component, side-nav entry
tags: [FRONTEND]
repo: rohan_ui
base_branch: phase-2
depends_on: [2]
files:
  - src/app/pages/acquisition-pathways/acquisition-pathways.module.ts
  - src/app/pages/acquisition-pathways/acquisition-pathways-routing.module.ts
  - src/app/pages/acquisition-pathways/root/acquisition-pathways.component.ts
  - src/app/pages/acquisition-pathways/root/acquisition-pathways.component.html
  - src/app/pages/acquisition-pathways/root/acquisition-pathways.component.scss
  - src/app/pages/acquisition-pathways/root/acquisition-pathways.component.spec.ts
  - src/app/pages/acquisition-pathways/constants/acquisition-pathways.constants.ts
  - src/app/pages/acquisition-pathways/types/acquisition-pathways.types.ts
  - src/assets/icons/nav/acquisition-pathways.svg
  - src/app/route-config.ts
  - src/app/shared-components/side-nav-bar/side-nav-bar.component.ts
  - src/app/shared-components/side-nav-bar/side-nav-bar.component.html
  - src/app/shared-components/side-nav-bar/side-nav-bar.component.spec.ts
  - src/app/shared-components/constants/analytics-ids.constants.ts
contracts:
  - "5.1 AcquisitionPathway placeholder type"
  - "5.2 Acquisition Pathways page constants"
  - "6.1 Routing contract"
  - "7.1 Side-nav entry"
  - "7.2 getFeatureFromUrl case"
  - "8.1 NAV_ACQUISITION_PATHWAYS analytics id"
verification:
  - npm run lint
  - npm run test -- --include='src/app/pages/acquisition-pathways/**/*.spec.ts'
  - npm run test -- --include='src/app/shared-components/side-nav-bar/side-nav-bar.component.spec.ts'
```

**Goal**: Ship the visible page and the side-nav entry. With Phase 2 merged, the new `features['ACQUISITION_PATHWAYS']` correctly gates both nav and route. The page itself is the same on low side and high side.

**Steps**:

- [ ] **3.1** Create the page directory skeleton at `src/app/pages/acquisition-pathways/`, mirroring `pages/graphics-lookbook/`. Folders: `root/`, `constants/`, `types/`.

- [ ] **3.2** Create the routing module at `acquisition-pathways-routing.module.ts`:
  - Single route `{ path: '', component: AcquisitionPathwaysComponent }`.
  - Pattern is identical to `graphics-lookbook-routing.module.ts`.
  - Note: a future low/high-side split would slot conditional child routes in here using `...(ProcurementWriterUtils.highSideEnabled ? [...] : [...])` exactly like `procurement-writer-routing.module.ts:45-64`. Not in this phase.

- [ ] **3.3** Create `acquisition-pathways.module.ts`:
  - `imports`: `CommonModule`, `SharedComponentsModule`, `AcquisitionPathwaysRoutingModule`.
  - `declarations`: `[AcquisitionPathwaysComponent]`.
  - Non-standalone NgModule.

- [ ] **3.4** Create the root component (`root/acquisition-pathways.component.ts`):
  - `@Component({ selector: 'app-acquisition-pathways', templateUrl, styleUrls, standalone: false })`.
  - Inject `AppInsightsService`; on `ngOnInit` call `appInsights.logEvent('pageView', { page: 'Acquisition Pathways' })` then `appInsights.startTime()`. On `ngOnDestroy` call `appInsights.logTimeSpent('Acquisition Pathways')`. Mirrors `GraphicsLookbookComponent`.
  - Fields: `searchTerm: string = ''`, `pathways: AcquisitionPathway[] = []`.
  - Methods: `searchForPathways(search: string): void` (assigns `this.searchTerm = search`; no service call), `displayIdleText(): boolean`, `displayEmptyResultsText(): boolean`.
  - Do **not** add any `highSideEnabled` field — both sides render identically in this phase.

- [ ] **3.5** Create `constants/acquisition-pathways.constants.ts` with the strings listed in contracts §5.2.

- [ ] **3.6** Create `types/acquisition-pathways.types.ts` with the placeholder `AcquisitionPathway` interface from contracts §5.1.

- [ ] **3.7** Create the template (`acquisition-pathways.component.html`):
  - Wrap content in `<app-page-wrapper>`.
  - Heading `AP_PAGE_HEADING`, description `AP_PAGE_DESCRIPTION`, `<app-search-bar>` bound to `searchForPathways($event)` with `[singleLine]="true"`, idle and empty-results `@if` blocks.
  - Loosely mirror `graphics-lookbook.component.html`.

- [ ] **3.8** Create the SCSS (`acquisition-pathways.component.scss`):
  - Minimal styles using existing CSS variables. No hard-coded colors. No `::ng-deep`.

- [ ] **3.9** Create the spec (`acquisition-pathways.component.spec.ts`):
  - Cover: component creates; `displayIdleText()` true initially; `displayEmptyResultsText()` true after `searchForPathways('foo')` with empty `pathways`; `ngOnInit` calls `appInsights.logEvent('pageView', ...)`; `ngOnDestroy` calls `appInsights.logTimeSpent('Acquisition Pathways')`.
  - Use `CUSTOM_ELEMENTS_SCHEMA` + `NO_ERRORS_SCHEMA` + `AppInsightsStubService`. Mirror `graphics-lookbook.component.spec.ts`.

- [ ] **3.10** Add the SVG icon at `src/assets/icons/nav/acquisition-pathways.svg`. Placeholder artwork is acceptable.

- [ ] **3.11** Register the lazy route in `src/app/route-config.ts`:
  ```ts
  'acquisition-pathways': {
      path: 'acquisition-pathways',
      loadChildren: () =>
          import('./pages/acquisition-pathways/acquisition-pathways.module').then(
              (m) => m.AcquisitionPathwaysModule,
          ),
  },
  ```

- [ ] **3.12** Add `NAV_ACQUISITION_PATHWAYS = 'side_nav_acquisition_pathways'` to `SharedAnalyticsIds` in `src/app/shared-components/constants/analytics-ids.constants.ts`, in the Side nav bar section.

- [ ] **3.13** Add the side-nav link in `side-nav-bar.component.html`. Place it immediately after the `acquisition-center` block, guarded by `@if (features['ACQUISITION_PATHWAYS'])`. Use `routerLink="/acquisition-pathways"`, `routerLinkActive="active"`, icon `./assets/icons/nav/acquisition-pathways.svg`, text `Acquisition Pathways`, click handler `onNavItemClick('Acquisition-Pathways')`, and `[attr.data-analytics-id]="analyticsIds.NAV_ACQUISITION_PATHWAYS"`. See contracts §7.1.

- [ ] **3.14** Update `side-nav-bar.component.ts > getFeatureFromUrl()`:
  - Add `case url.includes('/acquisition-pathways'): return 'Acquisition-Pathways';` **before** the `/acquisition-center` case so the substring match doesn't fall through. See contracts §7.2.
  - Do **not** add a new public field — the link uses `features['ACQUISITION_PATHWAYS']` directly from the existing `features` field.

- [ ] **3.15** Update `side-nav-bar.component.spec.ts`:
  - When mocking the `features` input, include `ACQUISITION_PATHWAYS: true` (or `false` in the negative test) — TypeScript will require this once `FeatureBlock` has the new key.
  - Add a test that confirms the Acquisition Pathways link renders when `features['ACQUISITION_PATHWAYS'] === true` and is absent when `false`.

- [ ] **3.16** Run verification.

## Phase order and parallelism

### File-touch matrix

| File | P1 | P2 | P3 |
| ---- | -- | -- | -- |
| `rohan_api/src/utils/feature-flags/types/featureFlags.ts` | edit | — | — |
| `rohan_ui/src/app/shared-types/feature-flag.constants.ts` | — | edit | — |
| `rohan_ui/src/app/shared-types/feature-block.types.ts` | — | edit | — |
| `rohan_ui/src/app/shared-services/feature-blocking/**` | — | edit | — |
| `rohan_ui/src/app/pages/acquisition-pathways/**` (new) | — | — | new |
| `rohan_ui/src/assets/icons/nav/acquisition-pathways.svg` | — | — | new |
| `rohan_ui/src/app/route-config.ts` | — | — | edit |
| `rohan_ui/src/app/shared-components/side-nav-bar/**` | — | — | edit |
| `rohan_ui/src/app/shared-components/constants/analytics-ids.constants.ts` | — | — | edit |

### Parallelism

Sequential. Phase 1 must merge first (BE enum must accept `AcquisitionPathways` before the FE flag fetch resolves correctly). Phase 2 wires the flag through `FeatureBlock` and must merge before Phase 3 references `features['ACQUISITION_PATHWAYS']`.

### Recommended order

1. Phase 1 (rohan_api) — single-file enum addition.
2. Phase 2 (rohan_ui) — flag plumbing, stacked on Phase 1.
3. Phase 3 (rohan_ui) — page + nav, stacked on Phase 2.

> Why three phases when the user requested two: the rohan_api change is in a separate repo with its own CI/CD pipeline, so it cannot share a PR with the rohan_ui work. Bundling it into Phase 2's metadata would mean a single phase that produces two PRs across two repos, which breaks the "one phase = one PR" convention used by the implementation skills. Phase 1 is intentionally trivial (one file) so it lands in minutes.

## Phase context summaries

**Phase 1 — rohan_api FeatureFlagsEnum addition.** Single-file change to `src/utils/feature-flags/types/featureFlags.ts`: adds `AcquisitionPathways = 'AcquisitionPathways'`. This makes the flag name valid against `FeatureFlags.isValidFlag()` so `GET /admin/feature-flag/AcquisitionPathways` no longer logs an "Unknown feature flag" warning and returns the Postgres-stored value (defaulting to `false` until a row is seeded per env). Depends on nothing. Gotcha: **do not** add it to `FeatureFlagGroups['unified-acquire']` — that's a separate decision (see Open question 1).

**Phase 2 — rohan_ui feature-flag + RBAC + AuthGuard wiring.** Adds `FeatureFlag.ACQUISITION_PATHWAYS` (FE enum mirroring the BE), `FeatureBlock.ACQUISITION_PATHWAYS` boolean, `FEATURE_BLOCK_ALL_DISABLED` update, a Postgres flag fetch in `FeatureBlockingService.getEnabledFeatures$()` (forkJoin key `acquisitionPathwaysEnabled`), an AND-with-userFeatures in the non-admin branch, an `ACQUISITION_PATHWAYS` case in `getUserFeatures()` (RBAC), and `acquisition-pathways` → `ACQUISITION_PATHWAYS` segment mappings in `AUTH_GUARD_URL_SEGMENTS` and `AUTH_GUARD_FEATURE_SEGMENTS`. After this phase, `features['ACQUISITION_PATHWAYS']` flows through `AuthStateService.features$` but is not yet consumed by any UI. Depends on Phase 1. Gotchas: (a) the `mockFeatures` literal in `feature-blocking.service.spec.ts` (line ~28) is a `FeatureBlock` and must be updated to include the new key, otherwise the type-check fails; (b) any `mockFeatureFlagsService.isFeatureEnabled` mock that doesn't handle the new flag will leave the new key undefined in `featuresV2`, so the spec defaults must return `of(false)`.

**Phase 3 — Acquisition Pathways page and side-nav entry.** Adds the new lazy module at `src/app/pages/acquisition-pathways/` (module, routing module, root component + spec, constants, types), the SVG icon, the route registration, the side-nav link gated by `features['ACQUISITION_PATHWAYS']`, the `getFeatureFromUrl()` case, the `NAV_ACQUISITION_PATHWAYS` analytics id, and side-nav spec updates. The page is identical for low side and high side — no `highSideEnabled` branches in this phase. Depends on Phase 2. Gotchas: (a) the `/acquisition-pathways` case in `getFeatureFromUrl()` must come **before** `/acquisition-center` to avoid substring fall-through; (b) the side-nav spec's `features` mock object must add `ACQUISITION_PATHWAYS: true|false` once the `FeatureBlock` type changes from Phase 2 are merged or TypeScript will fail to compile; (c) the page tracking event name `'Acquisition Pathways'` (used for `AppInsightsService.logEvent`/`logTimeSpent`) is **space-separated**, while the time-metric label `'Acquisition-Pathways'` (used by `TimeMetricTrackerService` / `getFeatureFromUrl`) is **kebab-Title-Case** — both conventions exist intentionally and must be kept consistent with neighbouring pages.

## Branching convention

Phases produce stacked branches with the pattern:

```
{user}/{ticket}/phase-{N}
```

- Phase 1 branches off the rohan_api starting branch (typically `develop` or `main` — confirm with the team).
- Phase 2 branches off Phase 1 in rohan_ui (note: it's a different repo from Phase 1; "stacked" here means Phase 2 cannot deploy until Phase 1 merges — they share no git history).
- Phase 3 branches off Phase 2 in rohan_ui.

## Deployment notes (operational, not code)

After Phase 1 merges and is deployed to an environment:

```bash
cd rohan_api-parent/rohan_api
pnpm enable-flag AcquisitionPathways
```

This inserts the `feature_flags` row that `/admin/feature-flag/AcquisitionPathways` will return. Without this step, the flag returns `{ isEnabled: false }` for all users and the page stays invisible. Repeat per environment (`staging`, `prod`, each `client-*` env). For RBAC access, an admin must also create or update a Group with `description: 'ACQUISITION_PATHWAYS'` and grant it to the appropriate users.

## Jira ticket

**Title**: `[ROH-XXXX] Acquisition Pathways — base structure (Postgres flag + RBAC + page scaffold)`

**Description**:

> Introduce the base structure for a new page called **Acquisition Pathways**, shipping on both the low side and the high side. Adds a Postgres-backed feature flag `AcquisitionPathways` (BE + FE), a new `FeatureBlock.ACQUISITION_PATHWAYS` key wired through `FeatureBlockingService` with RBAC group support, an `AuthGuard` segment mapping, and a new Angular module at `/acquisition-pathways` rendering an empty list scaffold (heading + non-functional search bar + idle/empty state). Adds a side-nav entry gated by the new `FeatureBlock` key.
>
> No data, no API endpoints, no DB tables in this ticket. The page is identical for low side and high side; future tickets may introduce variant differences inside the new module using `ProcurementWriterUtils.highSideEnabled`, mirroring Acquisition Center.
>
> Deployment requires `pnpm enable-flag AcquisitionPathways` per environment and an RBAC group with `description: 'ACQUISITION_PATHWAYS'`.

**Acceptance criteria**:

- [ ] **Phase 1**: `FeatureFlagsEnum.AcquisitionPathways` exists on rohan_api. `GET /admin/feature-flag/AcquisitionPathways` no longer logs "Unknown feature flag" and returns the Postgres-stored value.
- [ ] **Phase 2**: `FeatureFlag.ACQUISITION_PATHWAYS` is added to the FE enum with value `'AcquisitionPathways'`. `FeatureBlock.ACQUISITION_PATHWAYS` is wired through `FeatureBlockingService.getEnabledFeatures$()` and ANDed with the user's RBAC group membership (description `'ACQUISITION_PATHWAYS'`). `acquisition-pathways` is mapped to `ACQUISITION_PATHWAYS` in `AUTH_GUARD_FEATURE_SEGMENTS`. Existing feature-blocking specs pass with the new key added to `mockFeatures`.
- [ ] **Phase 3**: A new `/acquisition-pathways` route lazy-loads `AcquisitionPathwaysModule` and renders `AcquisitionPathwaysComponent` showing the heading, description, search bar, and idle/empty-state text. A side-nav link to `/acquisition-pathways` appears when `features['ACQUISITION_PATHWAYS']` is `true` and is absent when `false`. `SideNavBarComponent.getFeatureFromUrl()` returns `'Acquisition-Pathways'` for URLs containing `/acquisition-pathways`. The side-nav link emits `side_nav_acquisition_pathways` analytics. Unit tests pass; lint passes.
- [ ] **Manual smoke**: With the Postgres flag enabled and a user in a group with description `ACQUISITION_PATHWAYS`, the side-nav link appears and the page loads on both `PROCURE_HIGH_SIDE_ENABLED=true` and `=false` deployments. Without the flag or the group, the link is hidden and the route redirects per the existing AuthGuard rules.
