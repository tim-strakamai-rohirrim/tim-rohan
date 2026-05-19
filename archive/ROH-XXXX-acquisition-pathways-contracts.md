# ROH-XXXX — Acquisition Pathways: contracts

> Companion to `ROH-XXXX-acquisition-pathways-PLAN.md`. Two-repo, frontend-heavy base structure. No new API endpoints, no DTOs, no DB schema in this ticket.

## Contract → Phase mapping

| Contract Section | Phase(s) | Notes |
| ---------------- | -------- | ----- |
| 1.1 `FeatureFlagsEnum.AcquisitionPathways` (rohan_api) | 1 | BE enum gate |
| 1.2 `FeatureFlag.ACQUISITION_PATHWAYS` (rohan_ui) | 2 | FE enum mirror |
| 2.1 `FeatureBlock.ACQUISITION_PATHWAYS` | 2 | New per-user gate boolean |
| 2.2 `FEATURE_BLOCK_ALL_DISABLED` update | 2 | Default-disabled in constants |
| 3.1 `getEnabledFeatures$` — new Postgres flag fetch | 2 | Service wiring |
| 3.2 `getUserFeatures` — RBAC group description case | 2 | RBAC wiring |
| 4.1 `AUTH_GUARD_URL_SEGMENTS.ACQUISITION_PATHWAYS` | 2 | Route segment constant |
| 4.2 `AUTH_GUARD_FEATURE_SEGMENTS` entry | 2 | Segment → FeatureBlock map |
| 5.1 `AcquisitionPathway` placeholder type | 3 | Frontend-only seed type |
| 5.2 Acquisition Pathways page constants | 3 | User-facing strings |
| 6.1 Routing contract | 3 | Lazy route registration |
| 7.1 Side-nav entry | 3 | Template + gating |
| 7.2 `getFeatureFromUrl` case | 3 | Telemetry routing |
| 8.1 `NAV_ACQUISITION_PATHWAYS` analytics id | 3 | Side-nav analytics |
| 9 New endpoints / DTOs / DB / events | — | n/a (no backend data work) |

## 1. Feature-flag enum additions

### 1.1 `FeatureFlagsEnum.AcquisitionPathways` (rohan_api)

Path: `rohan_api-parent/rohan_api/src/utils/feature-flags/types/featureFlags.ts`

Add the value adjacent to the existing `Procure*` cluster:

```ts
export enum FeatureFlagsEnum {
    // … existing values …
    ProcurementWriter = 'ProcurementWriter',
    ProcureHighSide = 'ProcureHighSide',
    ProcureLowSide = 'ProcureLowSide',
    ProcureTemplateGenerator = 'ProcureTemplateGenerator',
    ProcureDeepResearch = 'ProcureDeepResearch',
    AcquisitionPathways = 'AcquisitionPathways', // ← NEW
    // … existing values …
}
```

> The string value (`'AcquisitionPathways'`) is the canonical flag name across both repos and the Postgres `feature_flags.feature` column. **Do not** rename it without coordinated FE/BE/DB updates.

### 1.2 `FeatureFlag.ACQUISITION_PATHWAYS` (rohan_ui)

Path: `rohan_ui-parent/rohan_ui/src/app/shared-types/feature-flag.constants.ts`

```ts
export enum FeatureFlag {
    // … existing values …
    PROCUREMENT_WRITER = 'ProcurementWriter',
    PROCURE_HIGH_SIDE = 'ProcureHighSide',
    PROCURE_LOW_SIDE = 'ProcureLowSide',
    PROCURE_TEMPLATE_GENERATOR = 'ProcureTemplateGenerator',
    PROCURE_DEEP_RESEARCH = 'ProcureDeepResearch',
    ACQUISITION_PATHWAYS = 'AcquisitionPathways', // ← NEW
    // … existing values …
}
```

> The FE enum string value must equal the rohan_api `FeatureFlagsEnum` value exactly. Mismatched names are silently treated as `isEnabled: false` and logged by the BE as "Unknown feature flag".

## 2. `FeatureBlock` additions

### 2.1 `FeatureBlock.ACQUISITION_PATHWAYS`

Path: `rohan_ui-parent/rohan_ui/src/app/shared-types/feature-block.types.ts`

```ts
export type FeatureBlock = {
    INGEST_PIPELINE: boolean;
    INGEST_ONEDRIVE: boolean;
    INGEST_SFTP: boolean;
    ANSWER_ENGINE: boolean;
    ANSWER_ENGINE_V2: boolean;
    GRAPHICS_ENGINE: boolean;
    SOLUTION_ARCHITECT: boolean;
    PROPOSAL_WRITER: boolean;
    ACQUISITION_CENTER: boolean;
    ACQUISITION_PATHWAYS: boolean; // ← NEW
    ADMIN_DASHBOARD: boolean;
    COMPLIANCE: boolean;
    ONE_RING: boolean;
    PROPOSAL_ENGINE: boolean;
    DEVELOPER_TOOLS: boolean;
    EVALUATION: boolean;
};
```

### 2.2 `FEATURE_BLOCK_ALL_DISABLED` update

Path: `rohan_ui-parent/rohan_ui/src/app/shared-services/feature-blocking/feature-blocking.constants.ts`

```ts
export const FEATURE_BLOCK_ALL_DISABLED: FeatureBlock = {
    INGEST_PIPELINE: false,
    INGEST_ONEDRIVE: false,
    INGEST_SFTP: false,
    ANSWER_ENGINE: false,
    ANSWER_ENGINE_V2: false,
    GRAPHICS_ENGINE: false,
    SOLUTION_ARCHITECT: false,
    PROPOSAL_WRITER: false,
    ACQUISITION_CENTER: false,
    ACQUISITION_PATHWAYS: false, // ← NEW
    ADMIN_DASHBOARD: false,
    COMPLIANCE: false,
    ONE_RING: false,
    PROPOSAL_ENGINE: false,
    DEVELOPER_TOOLS: false,
    EVALUATION: false,
};
```

## 3. `FeatureBlockingService` wiring

Path: `rohan_ui-parent/rohan_ui/src/app/shared-services/feature-blocking/feature-blocking.service.ts`

### 3.1 `getEnabledFeatures$` — new Postgres flag fetch

Add a key to the `forkJoin` and pipe the value through `parseFeaturesToBoolean`:

```ts
return forkJoin({
    features: this.request.get('/admin/features'),
    aev1Enabled: this.featureFlags.isFeatureEnabled(FeatureFlag.AEV1).pipe(take(1)),
    complianceEnabled: this.featureFlags
        .isFeatureEnabled(FeatureFlag.COMPLIANCE_ENABLED)
        .pipe(take(1)),
    oneRingEnabled: this.featureFlags
        .isFeatureEnabled(FeatureFlag.ONE_RING)
        .pipe(take(1)),
    proposalEngineEnabled: this.featureFlags
        .isFeatureEnabled(FeatureFlag.PROPOSAL_ENGINE)
        .pipe(take(1)),
    developerToolsEnabled: this.featureFlags
        .isFeatureEnabled(FeatureFlag.DEVELOPER_TOOLS)
        .pipe(take(1)),
    evaluationEnabled: this.featureFlags
        .isFeatureEnabled(FeatureFlag.EVALUATION_ENABLED)
        .pipe(take(1)),
    acquisitionPathwaysEnabled: this.featureFlags // ← NEW
        .isFeatureEnabled(FeatureFlag.ACQUISITION_PATHWAYS)
        .pipe(take(1)),
}).pipe(
    map(({
        features,
        aev1Enabled,
        complianceEnabled,
        oneRingEnabled,
        proposalEngineEnabled,
        developerToolsEnabled,
        evaluationEnabled,
        acquisitionPathwaysEnabled, // ← NEW
    }) => {
        const parsedFeatures = this.parseFeaturesToBoolean(
            features as Record<string, unknown>,
            {
                complianceEnabled,
                oneRingEnabled,
                proposalEngineEnabled,
                developerToolsEnabled,
                evaluationEnabled,
                acquisitionPathwaysEnabled, // ← NEW
            },
        );
        return { parsedFeatures, aev1Enabled };
    }),
    // …
);
```

Inside the non-admin branch of the `switchMap`, AND with the user's RBAC features:

```ts
if (!this.teamService.userIsAdmin()) {
    const userFeatures = this.getUserFeatures(response.group || []);
    // … existing ANDs …
    parsedFeatures.EVALUATION =
        parsedFeatures.EVALUATION && userFeatures.EVALUATION;
    parsedFeatures.ACQUISITION_PATHWAYS =                          // ← NEW
        parsedFeatures.ACQUISITION_PATHWAYS && userFeatures.ACQUISITION_PATHWAYS;
}
```

Update `parseFeaturesToBoolean` to read the new key:

```ts
parseFeaturesToBoolean(
    features: Record<string, unknown>,
    featuresV2: Record<string, boolean>,
): FeatureBlock {
    const retval: FeatureBlock = {
        // … existing fields …
        COMPLIANCE: featuresV2.complianceEnabled ?? false,
        ONE_RING: featuresV2.oneRingEnabled ?? false,
        PROPOSAL_ENGINE: featuresV2.proposalEngineEnabled ?? false,
        DEVELOPER_TOOLS: featuresV2.developerToolsEnabled ?? false,
        EVALUATION: featuresV2.evaluationEnabled ?? false,
        ACQUISITION_PATHWAYS: featuresV2.acquisitionPathwaysEnabled ?? false, // ← NEW
    };
    return retval;
}
```

### 3.2 `getUserFeatures` — RBAC group description case

Add a switch case so a group with `description === 'ACQUISITION_PATHWAYS'` grants the feature:

```ts
getUserFeatures(group: MemberRole[]): FeatureBlock {
    let userFeatures: FeatureBlock = this.getDefaultFeatures(false);

    group.forEach((g) => {
        switch (g.description) {
            // … existing cases …
            case 'ACQUISITION_CENTER': {
                userFeatures.ACQUISITION_CENTER = true;
                break;
            }
            case 'ACQUISITION_PATHWAYS': {           // ← NEW
                userFeatures.ACQUISITION_PATHWAYS = true;
                break;
            }
            // … existing cases …
        }
    });

    return userFeatures;
}
```

> The string `'ACQUISITION_PATHWAYS'` is the **exact** value an operator must set in the Group's `description` field. Spec assertions and admin tooling will match literally.

## 4. `AuthGuard` segment additions

Path: `rohan_ui-parent/rohan_ui/src/app/shared-services/feature-blocking/auth.guard.constants.ts`

### 4.1 `AUTH_GUARD_URL_SEGMENTS.ACQUISITION_PATHWAYS`

```ts
export const AUTH_GUARD_URL_SEGMENTS = {
    ANSWER_ENGINE_V2: 'answer-engine-v2',
    ANSWER_ENGINE: 'answer-engine',
    SOLUTIONS_ARCHITECT: 'solutions-architect',
    PROPOSAL_WRITER: 'proposal-writer',
    GRAPHICS_LOOKBOOK: 'graphics-lookbook',
    ANNOUNCEMENTS: 'announcements',
    ACQUISITION_CENTER: 'acquisition-center',
    ACQUISITION_PATHWAYS: 'acquisition-pathways', // ← NEW
    PROPOSAL_ENGINE: 'proposal-engine',
} as const;
```

### 4.2 `AUTH_GUARD_FEATURE_SEGMENTS` entry

```ts
export const AUTH_GUARD_FEATURE_SEGMENTS: ReadonlyArray<{
    segment: string;
    featureKey: keyof FeatureBlock;
}> = [
    // … existing entries …
    {
        segment: AUTH_GUARD_URL_SEGMENTS.ACQUISITION_CENTER,
        featureKey: 'ACQUISITION_CENTER',
    },
    {                                                // ← NEW
        segment: AUTH_GUARD_URL_SEGMENTS.ACQUISITION_PATHWAYS,
        featureKey: 'ACQUISITION_PATHWAYS',
    },
    {
        segment: AUTH_GUARD_URL_SEGMENTS.PROPOSAL_ENGINE,
        featureKey: 'PROPOSAL_ENGINE',
    },
];
```

## 5. Frontend types and constants

### 5.1 `AcquisitionPathway` placeholder type

Path: `rohan_ui-parent/rohan_ui/src/app/pages/acquisition-pathways/types/acquisition-pathways.types.ts`

```ts
/**
 * Placeholder shape for an Acquisition Pathway. The page does not fetch or render
 * pathway data yet; this type exists so the empty-state scaffold compiles against
 * a typed (but empty) `pathways: AcquisitionPathway[]` field. The real shape will
 * be defined in a follow-up ticket when the backend contract lands.
 */
export interface AcquisitionPathway {
    id: string;
    name: string;
}
```

> When the API contract lands, **extend** this interface rather than replace it. Keep `id: string` and `name: string` as the stable subset.

### 5.2 Acquisition Pathways page constants

Path: `rohan_ui-parent/rohan_ui/src/app/pages/acquisition-pathways/constants/acquisition-pathways.constants.ts`

```ts
export const AP_PAGE_HEADING = 'Acquisition Pathways';
export const AP_PAGE_DESCRIPTION =
    'Explore acquisition pathways that match your needs.';
export const AP_SEARCH_BAR_TEXT = 'Find a pathway';
export const AP_SEARCH_BAR_PLACEHOLDER = 'Search for an acquisition pathway…';
export const AP_SEARCH_BUTTON_TEXT = 'Search';
export const AP_IDLE_TEXT =
    'Enter a concept to start exploring acquisition pathways.';
export const AP_EMPTY_RESULTS_TEXT = 'No pathways yet.';
```

> Reviewers and spec authors may match these literal strings.

## 6. Routing contract

### 6.1 Route registration

Path: `rohan_ui-parent/rohan_ui/src/app/route-config.ts`

Add to `defaultRoutes`:

```ts
'acquisition-pathways': {
    path: 'acquisition-pathways',
    loadChildren: () =>
        import('./pages/acquisition-pathways/acquisition-pathways.module').then(
            (m) => m.AcquisitionPathwaysModule,
        ),
},
```

Page-level routing module (`acquisition-pathways-routing.module.ts`):

```ts
import { NgModule } from '@angular/core';
import { RouterModule, Routes } from '@angular/router';

import { AcquisitionPathwaysComponent } from './root/acquisition-pathways.component';

const routes: Routes = [{ path: '', component: AcquisitionPathwaysComponent }];

@NgModule({
    imports: [RouterModule.forChild(routes)],
    exports: [RouterModule],
})
export class AcquisitionPathwaysRoutingModule {}
```

> Future low/high-side variants would slot in as conditional child routes here using `...(ProcurementWriterUtils.highSideEnabled ? [...] : [...])`, exactly like `procurement-writer-routing.module.ts:45-64`. Out of scope for this ticket.

## 7. Side-nav contract

### 7.1 Side-nav entry

Path: `rohan_ui-parent/rohan_ui/src/app/shared-components/side-nav-bar/side-nav-bar.component.html`

Insert immediately after the existing Acquisition Center block:

```html
@if (features['ACQUISITION_PATHWAYS']) {
    <a
        class="nav-item"
        (click)="onNavItemClick('Acquisition-Pathways')"
        (mouseover)="toggleHover(true)"
        (mouseleave)="toggleHover(false)"
        routerLink="/acquisition-pathways"
        routerLinkActive="active"
        [attr.data-analytics-id]="analyticsIds.NAV_ACQUISITION_PATHWAYS"
    >
        <span class="icon"><img src="./assets/icons/nav/acquisition-pathways.svg" /></span>
        <span class="link-text">Acquisition Pathways</span>
    </a>
}
```

> Gating is on the new `FeatureBlock['ACQUISITION_PATHWAYS']` only — not on `procureHighSideEnabled`. Both low and high side deployments render the same link when the per-user gate is on.

### 7.2 `getFeatureFromUrl` case

Path: `rohan_ui-parent/rohan_ui/src/app/shared-components/side-nav-bar/side-nav-bar.component.ts`

In `getFeatureFromUrl()`, add the case **before** `/acquisition-center` to avoid substring fall-through:

```ts
getFeatureFromUrl(url: string): string | null {
    switch (true) {
        case url.includes('/template-generator'):
            return 'Template-Generator';
        case url.includes('/one-ring'):
            return 'One-Ring';
        case url.includes('/acquisition-pathways'):     // ← NEW (must precede /acquisition-center)
            return 'Acquisition-Pathways';
        case url.includes('/acquisition-center'):
            return 'Acquisition-Center';
        // … existing cases …
    }
}
```

> The time-metric label is `'Acquisition-Pathways'` (kebab-Title-Case). The AppInsights page label is `'Acquisition Pathways'` (space-separated). Both conventions exist intentionally and match neighbouring pages.

## 8. Analytics & telemetry contract

### 8.1 `NAV_ACQUISITION_PATHWAYS` analytics id

Path: `rohan_ui-parent/rohan_ui/src/app/shared-components/constants/analytics-ids.constants.ts`

Add to the Side nav bar section of `SharedAnalyticsIds`:

```ts
NAV_ACQUISITION_PATHWAYS = 'side_nav_acquisition_pathways',
```

## 9. New endpoints / DTOs / DB / events

n/a — no backend data work in this ticket. The only backend change is the single-line addition to `FeatureFlagsEnum` (§1.1).

| Section | Status |
| ------- | ------ |
| New endpoints | n/a |
| Modified endpoints | n/a |
| New/modified backend DTOs | n/a |
| Database schema changes | n/a — the `feature_flags` row is seeded operationally via `pnpm enable-flag AcquisitionPathways`, no migration |
| Internal event payloads | n/a |
| Error responses | n/a |

## 10. Existing types referenced (unchanged)

The following symbols are read by the new code without modification. Listed so reviewers can confirm no incidental changes:

| Symbol | Path | Status |
| ------ | ---- | ------ |
| `FeatureFlagsService` | `src/app/shared-services/feature-flags/feature-flags.service.ts` | unchanged — hits `/admin/feature-flag/{name}` |
| `RequestService` | `src/app/shared-services/request/request.service.ts` | unchanged |
| `TeamService` | `src/app/shared-services/team/team.service.ts` | unchanged — admin check |
| `AuthStateService` | `src/app/shared-services/auth/auth-state.service.ts` | unchanged — emits `features$` |
| `AppInsightsService` | `src/app/shared-services/app-insights/app-insights.service.ts` | unchanged |
| `TimeMetricTrackerService` | `src/app/shared-services/audit-trail/time-metric-tracker.service.ts` | unchanged |
| `SharedComponentsModule` | `src/app/shared-components/shared-components.module.ts` | unchanged — provides `app-page-wrapper`, `app-search-bar`, `app-button` |
| `ProcurementWriterUtils` | `src/app/pages/acquisition-center/utilities/procurement-writer.utils.ts` | unchanged — not consumed in this ticket; reserved for future variant work |
| `RohanSettings` | `src/global.d.ts` | unchanged |

## 11. Deployment notes (operational)

The code in this ticket is necessary but not sufficient for users to see the page. After deploying each environment:

```bash
cd rohan_api-parent/rohan_api
pnpm enable-flag AcquisitionPathways
```

This inserts the row into the `feature_flags` Postgres table. Without it the BE returns `{ isEnabled: false }` and `features['ACQUISITION_PATHWAYS']` evaluates `false` for everyone (including admins, because the admin-bypass in `getEnabledFeatures$` does not bypass the Postgres flag itself — it only bypasses the RBAC AND).

For non-admin user access, an admin must also:

1. Create or update a Group with `description: 'ACQUISITION_PATHWAYS'` (exact string).
2. Assign that group to the relevant users.
