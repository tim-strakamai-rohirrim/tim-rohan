# PRCR-1634 — Contracts

> Companion to `PRCR-1634-PLAN.md`. Three small phases across three repos. No new HTTP endpoints, no new DTOs, no new DB tables. The change is a single new permission/role seed (Database + rohan_api) plus the corresponding admin UI surface (rohan_ui).

## Contract → Phase mapping

| Contract Section | Phase | Notes |
| ---------------- | ----- | ----- |
| 1.1 `permissions_feature_enum` addition | 1 | DB enum value |
| 1.2 `permissions` row seed | 1 | Postgres seed row |
| 1.3 `roles_permissions_permissions` seed | 1 | Postgres join row |
| 2.1 `Feature.ACQUISITION_PATHWAYS` | 2 | rohan_api TS enum |
| 3.1 `acquisitionPathwaysRoleDescription` constant | 3 | Frontend constant mirror |
| 3.2 `roleNamesForRp` + `roleNamesForRfp` additions | 3 | Allowlist updates |
| 3.3 `FeatureFlag.ACQUISITION_PATHWAYS` gating in `updateGroupedRoles` | 3 | Flag-gated hierarchy |
| 3.4 `groupRolesHierarchically` standalone top-level case | 3 | Render placement |
| 3.5 `getRoleDisplayName` — Acquisition Pathways | 3 | Defensive display name |
| 4 New endpoints / DTOs / events | — | n/a |

## 1. Database seed (`Database/rohan_api/scripts/sql/init_organizations.sql`)

### 1.1 `permissions_feature_enum` addition

Append `'ACQUISITION_PATHWAYS'` to the `CREATE TYPE` block near the top of the file (currently lines 5–18). Place it directly after `'ACQUISITION_CENTER'` for grouping:

```sql
DO $$
BEGIN
    DROP TYPE IF EXISTS "permissions_feature_enum" CASCADE;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'permissions_feature_enum') THEN
        CREATE TYPE "permissions_feature_enum" AS ENUM(
            'ADMIN_DASHBOARD',
            'ANSWER_ENGINE',
            'ANSWER_ENGINE_V2',
            'SOLUTION_ARCHITECT',
            'PROPOSAL_WRITER',
            'ACQUISITION_CENTER',
            'ACQUISITION_PATHWAYS',   -- ← NEW
            'GRAPHICS_ENGINE',
            'DEEP_RESEARCH',
            'AC_DEEP_RESEARCH',
            'KNOWLEDGE_MANAGEMENT',
            'COMPLIANCE',
            'EVALUATION'
        );
    END IF;
END$$;
```

> The script unconditionally drops and recreates the enum on every run (line 3). No separate `ALTER TYPE ... ADD VALUE 'ACQUISITION_PATHWAYS'` migration is required.

### 1.2 `permissions` row seed

Add a row to the `INSERT INTO permissions (name, feature, display_name) VALUES` block (currently lines 314–327). Place it directly after the `acquisition-center` row:

```sql
INSERT INTO permissions (name, feature, display_name) VALUES
    ('admin', 'ADMIN_DASHBOARD', 'Admin'),
    ('answer-engine', 'ANSWER_ENGINE', 'Answer Engine'),
    ('answer-engine-v2', 'ANSWER_ENGINE_V2', 'Answer Engine V2'),
    ('solution-architect-assistant', 'SOLUTION_ARCHITECT', 'Solutions Architect'),
    ('proposal-writer', 'PROPOSAL_WRITER', 'Proposal Writer'),
    ('acquisition-center', 'ACQUISITION_CENTER', 'Acquisition Center'),
    ('acquisition-pathways', 'ACQUISITION_PATHWAYS', 'Acquisition Pathways'),   -- ← NEW
    ('graphics-engine', 'GRAPHICS_ENGINE', 'Graphics Lookbook'),
    ('deep-research', 'DEEP_RESEARCH', 'Deep Research'),
    ('ac-deep-research', 'AC_DEEP_RESEARCH', 'AC Deep Research'),
    ('knowledge-management', 'KNOWLEDGE_MANAGEMENT', 'Knowledge Management'),
    ('compliance', 'COMPLIANCE', 'Compliance'),
    ('evaluation', 'EVALUATION', 'Evaluation')
    ON CONFLICT (name, feature) DO NOTHING;
```

| Column | Value | Notes |
| ------ | ----- | ----- |
| `name` | `acquisition-pathways` | Matches the existing kebab-case convention for the first column. Consumed by `@Permissions('acquisition-pathways')` decorators in any future endpoints. |
| `feature` | `ACQUISITION_PATHWAYS` | Must match the `permissions_feature_enum` value added in §1.1 exactly. |
| `display_name` | `Acquisition Pathways` | Becomes the role's `name` once the downstream `INSERT INTO roles` block (lines 346–356) auto-seeds the role row from the permissions table. |

> The downstream `INSERT INTO roles ... SELECT display_name as name, feature as description, ... true as group_role FROM permissions WHERE name != 'admin'` block requires **no edits** — it iterates over the new permissions row automatically and creates a role with `name = 'Acquisition Pathways'`, `description = 'ACQUISITION_PATHWAYS'`, `group_role = true`.

### 1.3 `roles_permissions_permissions` seed

Add a join row to the `INSERT INTO roles_permissions_permissions ("rolesRoleId", "permissionsPermissionId") VALUES` block (currently lines 358–369). Place it directly after the `ACQUISITION_CENTER` join row:

```sql
INSERT INTO roles_permissions_permissions ("rolesRoleId", "permissionsPermissionId") VALUES
    ((SELECT role_id FROM roles WHERE description = 'ANSWER_ENGINE'), (SELECT permission_id FROM permissions WHERE feature ='ANSWER_ENGINE')),
    ((SELECT role_id FROM roles WHERE description = 'ANSWER_ENGINE_V2'), (SELECT permission_id FROM permissions WHERE feature ='ANSWER_ENGINE_V2')),
    ((SELECT role_id FROM roles WHERE description = 'SOLUTION_ARCHITECT'), (SELECT permission_id FROM permissions WHERE feature ='SOLUTION_ARCHITECT')),
    ((SELECT role_id FROM roles WHERE description = 'PROPOSAL_WRITER'), (SELECT permission_id FROM permissions WHERE feature ='PROPOSAL_WRITER')),
    ((SELECT role_id FROM roles WHERE description = 'ACQUISITION_CENTER'), (SELECT permission_id FROM permissions WHERE feature ='ACQUISITION_CENTER')),
    ((SELECT role_id FROM roles WHERE description = 'ACQUISITION_PATHWAYS'), (SELECT permission_id FROM permissions WHERE feature ='ACQUISITION_PATHWAYS')),   -- ← NEW
    ((SELECT role_id FROM roles WHERE description = 'GRAPHICS_ENGINE'), (SELECT permission_id FROM permissions WHERE feature ='GRAPHICS_ENGINE')),
    ((SELECT role_id FROM roles WHERE description = 'DEEP_RESEARCH'), (SELECT permission_id FROM permissions WHERE feature ='DEEP_RESEARCH')),
    ((SELECT role_id FROM roles WHERE description = 'AC_DEEP_RESEARCH'), (SELECT permission_id FROM permissions WHERE feature ='AC_DEEP_RESEARCH')),
    ((SELECT role_id FROM roles WHERE description = 'KNOWLEDGE_MANAGEMENT'), (SELECT permission_id FROM permissions WHERE feature ='KNOWLEDGE_MANAGEMENT')),
    ((SELECT role_id FROM roles WHERE description = 'COMPLIANCE'), (SELECT permission_id FROM permissions WHERE feature ='COMPLIANCE')),
    ((SELECT role_id FROM roles WHERE description = 'EVALUATION'), (SELECT permission_id FROM permissions WHERE feature ='EVALUATION'))
ON CONFLICT DO NOTHING;
```

> Both subqueries must succeed at INSERT time. They will, because the role is seeded by the preceding `INSERT INTO roles ... SELECT ... FROM permissions` block earlier in the same script, and the permission row is added in §1.2.

## 2. NestJS TS enum (`rohan_api/src/admin/entities/permission.entity.ts`)

### 2.1 `Feature.ACQUISITION_PATHWAYS`

Add a single new value to the `Feature` enum, placed adjacent to `ACQUISITION_CENTER`:

```ts
export enum Feature {
  ADMIN = 'admin',
  ANSWER_ENGINE = 'answer-engine',
  SOLUTION_ARCHITECT_ASSISTANT = 'solution-architect-assistant',
  PROPOSAL_WRITER = 'proposal-writer',
  GRAPHICS_ENGINE = 'graphics-engine',
  ACQUISITION_CENTER = 'acquisition-center',
  ACQUISITION_PATHWAYS = 'ACQUISITION_PATHWAYS',   // ← NEW
  ONERING = 'one-ring',
  DEVELOPER_TOOLS = 'developer-tools',
  AEV2FileUpload = 'AEV2FileUpload',
  ProcurementWriter = 'ProcurementWriter',
  ColumnBuilder = 'ColumnBuilder',
  FullStory = 'FullStory',
  TESTING = 'TESTING',
  langchain_v1_knowledge_management = 'langchain_v1_knowledge_management',
  IncludeTablesInAIAnswer_OneShotHero = 'IncludeTablesInAIAnswer_OneShotHero',
  DEEP_RESEARCH = 'DEEP_RESEARCH',
  API_EXCEL_CONVERSION = 'API_EXCEL_CONVERSION',
  TAG_SPLITTING = 'TAG_SPLITTING',
  AEV1 = 'AEV1',
  UPLOAD_FILES_PROXY = 'UPLOAD_FILES_PROXY',
}
```

> The value is UPPER_SNAKE (`'ACQUISITION_PATHWAYS'`) — not kebab-case — because the Postgres `permissions_feature_enum` value is UPPER_SNAKE (see §1.1) and the `@Features(...)` decorator pattern-matches against the TS enum value, which must match what the DB returns. Older entries in the same TS enum use kebab-case (`ACQUISITION_CENTER = 'acquisition-center'`) for historical reasons; new entries follow the `DEEP_RESEARCH = 'DEEP_RESEARCH'` convention.

> No controller, guard, or test currently consumes `Feature.ACQUISITION_PATHWAYS`. The enum entry exists so any future Acquisition Pathways endpoint can use `@Features('ACQUISITION_PATHWAYS')` without further edits.

## 3. Angular UI (`rohan_ui-parent/rohan_ui`)

### 3.1 `acquisitionPathwaysRoleDescription` constant

Path: `src/app/pages/settings/constants/settings.constants.ts`

Add a new exported constant adjacent to the existing role-description constants:

```ts
export const deepResearchRoleDescription: string = 'DEEP_RESEARCH';
export const acDeepResearchRoleDescription: string = 'AC_DEEP_RESEARCH';
export const knowledgeManagementRoleDescription: string = 'KNOWLEDGE_MANAGEMENT';
export const complianceRoleDescription: string = 'COMPLIANCE';
export const evaluationRoleDescription: string = 'EVALUATION';
export const acquisitionPathwaysRoleDescription: string = 'ACQUISITION_PATHWAYS';   // ← NEW
```

> The string `'ACQUISITION_PATHWAYS'` must equal the seeded role's `description` column (see §1.2 downstream effect) exactly. Tests and comparisons in `create-edit-group.component.ts` and `feature-blocking.service.ts` match literally on this value.

### 3.2 `roleNamesForRp` and `roleNamesForRfp` additions

Path: `src/app/pages/settings/components/rbac/create-edit-group/create-edit-group.component.ts`

Update both class-level allowlists:

```ts
roleNamesForRp: string[] = [
    'Acquisition Center',
    'Acquisition Pathways',   // ← NEW
    'Answer Engine V2',
    'Deep Research',
    'AC Deep Research',
    'Compliance',
    'Evaluation',
];
roleNamesForRfp: string[] = [
    'Answer Engine V2',
    'Solutions Architect',
    'Proposal Writer',
    'Graphics Lookbook',
    'Deep Research',
    'Knowledge Management',
    'Compliance',
    'Evaluation',
    'Acquisition Pathways',   // ← NEW (appended; no Acquisition Center in this list)
];
```

> The literal string `'Acquisition Pathways'` must equal the role's `name` column exactly (i.e. the `display_name` from §1.2). Mismatches silently drop the role from `availableRoles` with no error message.

### 3.3 `FeatureFlag.ACQUISITION_PATHWAYS` gating in `updateGroupedRoles`

Path: `src/app/pages/settings/components/rbac/create-edit-group/create-edit-group.component.ts`

Add a new feature-flag observable to the class (adjacent to `complianceFeatureFlag$` / `evaluationFeatureFlag$`):

```ts
complianceFeatureFlag$: Observable<boolean>;
evaluationFeatureFlag$: Observable<boolean>;
acquisitionPathwaysFeatureFlag$: Observable<boolean>;   // ← NEW
```

Initialise it in `ngOnInit` alongside the existing initialisations:

```ts
this.evaluationFeatureFlag$ = this.ffService.isFeatureEnabled(
    FeatureFlag.EVALUATION_ENABLED,
);
this.acquisitionPathwaysFeatureFlag$ = this.ffService.isFeatureEnabled(   // ← NEW
    FeatureFlag.ACQUISITION_PATHWAYS,
);
```

Extend `updateGroupedRoles()` to include the new flag in the `forkJoin` and pass it through:

```ts
updateGroupedRoles(roles: Role[]): void {
    forkJoin({
        deepResearch: this.deepResearchFeatureFlag$,
        procureDeepResearch: this.procureDeepResearchFeatureFlag$,
        knowledgeManagement: this.knowledgeManagementFeatureFlag$,
        compliance: this.complianceFeatureFlag$,
        evaluation: this.evaluationFeatureFlag$,
        acquisitionPathways: this.acquisitionPathwaysFeatureFlag$,   // ← NEW
    })
        .pipe(takeUntil(this._unsubscribeAll))
        .subscribe((flags) => {
            this.groupedRoles = this.groupRolesHierarchically(
                roles,
                flags.deepResearch,
                flags.procureDeepResearch,
                flags.knowledgeManagement,
                flags.compliance,
                flags.evaluation,
                flags.acquisitionPathways,   // ← NEW
            );
            this.cd.detectChanges();
        });
}
```

> `FeatureFlag` is already imported from `@shared-types/feature-flag.constants`. `FeatureFlag.ACQUISITION_PATHWAYS` is already defined under the existing ROH-XXXX work (string value `'AcquisitionPathways'`). No import or type changes are needed beyond this addition.

### 3.4 `groupRolesHierarchically` standalone top-level case

Path: `src/app/pages/settings/components/rbac/create-edit-group/create-edit-group.component.ts`

Extend the method signature and body. The Acquisition Pathways role is treated as a **standalone top-level row**, mirroring how Compliance and Evaluation are handled:

```ts
groupRolesHierarchically(
    roles: Role[],
    includeDeepResearch: boolean = true,
    includeProcureDeepResearch: boolean = true,
    includeKnowledgeManagement: boolean = true,
    includeCompliance: boolean = true,
    includeEvaluation: boolean = true,
    includeAcquisitionPathways: boolean = true,   // ← NEW
): { role: Role; children: { role: Role }[] }[] {
    const grouped: { role: Role; children: { role: Role }[] }[] = [];
    const deepResearchRole = includeDeepResearch
        ? roles.find((role) => role.description === deepResearchRoleDescription)
        : null;
    const acDeepResearchRole = includeProcureDeepResearch
        ? roles.find((role) => role.description === acDeepResearchRoleDescription)
        : null;
    const knowledgeManagementRole = includeKnowledgeManagement
        ? roles.find((role) => role.description === knowledgeManagementRoleDescription)
        : null;
    const complianceRole = includeCompliance
        ? roles.find((role) => role.description === complianceRoleDescription)
        : null;
    const evaluationRole = includeEvaluation
        ? roles.find((role) => role.description === evaluationRoleDescription)
        : null;
    const acquisitionPathwaysRole = includeAcquisitionPathways   // ← NEW
        ? roles.find(
              (role) => role.description === acquisitionPathwaysRoleDescription,
          )
        : null;

    // Skip child/standalone-handled descriptions in the main parent loop:
    roles.forEach((role) => {
        if (
            role.description !== deepResearchRoleDescription &&
            role.description !== acDeepResearchRoleDescription &&
            role.description !== knowledgeManagementRoleDescription &&
            role.description !== complianceRoleDescription &&
            role.description !== evaluationRoleDescription &&
            role.description !== acquisitionPathwaysRoleDescription   // ← NEW
        ) {
            if (role.description === 'ANSWER_ENGINE_V2') {
                // …existing AE_V2 + Deep Research + KM children block…
            } else if (role.description === 'ACQUISITION_CENTER') {
                // …existing ACQUISITION_CENTER + AC Deep Research children block…
            } else {
                grouped.push({ role, children: [] });
            }
        }
    });

    // Standalone top-level rows (Compliance, Evaluation, Acquisition Pathways):
    if (complianceRole) {
        grouped.push({ role: complianceRole, children: [] });
    }
    if (evaluationRole) {
        grouped.push({ role: evaluationRole, children: [] });
    }
    if (acquisitionPathwaysRole) {   // ← NEW
        grouped.push({ role: acquisitionPathwaysRole, children: [] });
    }

    return grouped;
}
```

> The new role description **must** be added to the `forEach` exclusion guard. Skipping that step causes the role to appear twice — once inside the parent loop's default `else` branch (as a top-level row with no children) and once again from the standalone push at the end of the method.

### 3.5 `getRoleDisplayName` — Acquisition Pathways

Path: `src/app/pages/settings/components/rbac/create-edit-group/create-edit-group.component.ts`

Extend the method with a defensive case so the display name is always `'Acquisition Pathways'` regardless of any future seed-data drift:

```ts
getRoleDisplayName(role: Role): string {
    if (role.description === acDeepResearchRoleDescription) {
        return 'Deep Research';
    }
    if (role.name === 'Answer Engine V2' && this.aev1Disabled) {
        return 'Answer Engine';
    }
    if (role.description === complianceRoleDescription) {
        return 'Compliance';
    }
    if (role.description === evaluationRoleDescription) {
        return 'Evaluation';
    }
    if (role.description === acquisitionPathwaysRoleDescription) {   // ← NEW
        return 'Acquisition Pathways';
    }
    return role.name;
}
```

> `role.name` already equals `'Acquisition Pathways'` under the seed in §1.2, so the explicit return is defensive rather than required. Adding it keeps the pattern symmetrical with Compliance/Evaluation and protects against accidental seed renames.

## 4. New endpoints / DTOs / DB schema / events

n/a — this ticket adds no HTTP endpoints, no DTOs, no new tables, no new event payloads.

| Section | Status |
| ------- | ------ |
| New endpoints | n/a |
| Modified endpoints | n/a (existing `POST /admin/groups`, `PATCH /admin/groups/:id`, `GET /admin/roles?roles=group` already handle the new role transparently) |
| New/modified backend DTOs | n/a (the existing `SaveEditPermissionGroupData.roles: number[]` already accepts arbitrary role IDs) |
| Database schema changes | n/a — the new permission/role is a **seed row**, not a schema change. The `permissions_feature_enum` is rebuilt by the seed script itself (§1.1). |
| Internal event payloads | n/a |
| Error responses | n/a |

## 5. Existing types referenced (unchanged)

These symbols are read or extended by the new code without modification. Listed so reviewers can confirm no incidental changes:

| Symbol | Path | Status |
| ------ | ---- | ------ |
| `FeatureFlag.ACQUISITION_PATHWAYS` | `rohan_ui/src/app/shared-types/feature-flag.constants.ts` | unchanged — already added under ROH-XXXX-acquisition-pathways |
| `FeatureBlock.ACQUISITION_PATHWAYS` | `rohan_ui/src/app/shared-types/feature-block.types.ts` | unchanged — already added under ROH-XXXX-acquisition-pathways |
| `FeatureBlockingService.getUserFeatures()` | `rohan_ui/src/app/shared-services/feature-blocking/feature-blocking.service.ts` | unchanged — already has `case 'ACQUISITION_PATHWAYS'` |
| `AUTH_GUARD_URL_SEGMENTS.ACQUISITION_PATHWAYS` | `rohan_ui/src/app/shared-services/feature-blocking/auth.guard.constants.ts` | unchanged — already added |
| `AuditTrailFeature.ACQUISITION_PATHWAYS` | `rohan_api/src/settings/audit-trail.constants.ts` | unchanged — already exists |
| `FeatureFlagsEnum.AcquisitionPathways` | `rohan_api/src/utils/feature-flags/types/featureFlags.ts` | unchanged — already added under ROH-XXXX-acquisition-pathways |
| `Role`, `MemberRole`, `DetailedPermissionGroup`, `SaveEditPermissionGroupData` | `rohan_ui/src/app/pages/settings/types/settings.types.ts` | unchanged |
| `TeamService.getGroupRoles()` | `rohan_ui/src/app/shared-services/team/team.service.ts` | unchanged — already returns every `group_role=true` row for the org |
| `AdminService.getRoles()` | `rohan_api/src/admin/admin.service.ts` | unchanged — already filters by `group_role=true` when `?roles=group` |
| `FeatureFlagsService.isFeatureEnabled()` | `rohan_ui/src/app/shared-services/feature-flags/feature-flags.service.ts` | unchanged |
| `Permission` entity / `permissions_feature_enum` | `rohan_api/src/admin/entities/permission.entity.ts` + `Database/.../init_organizations.sql` | enum **extended** (§1.1, §2.1), schema otherwise unchanged |

## 6. Deployment notes (operational)

The code in this ticket is necessary but not sufficient for the new checkbox to appear in production:

1. **Phase 1** must merge to `Database` and the Helm post-install hook must re-run `init_organizations.sql` in the target environment. After this, `SELECT * FROM roles WHERE description = 'ACQUISITION_PATHWAYS'` returns one row per org.
2. **Phase 3** must merge to `rohan_ui` and ship to the target environment.
3. The Postgres feature flag must be enabled for the org so the new checkbox is rendered:
   ```bash
   cd rohan_api-parent/rohan_api
   pnpm enable-flag AcquisitionPathways
   ```
   (This is the same operational step already required for the Acquisition Pathways page itself per `ROH-XXXX-acquisition-pathways-PLAN.md` §11.)

After steps 1–3, an admin can open `/settings/groups/create`, check the **Acquisition Pathways** option, assign members, and save. Members of that group will see `features['ACQUISITION_PATHWAYS'] === true` through the already-wired `FeatureBlockingService.getEnabledFeatures$()` pipeline.
