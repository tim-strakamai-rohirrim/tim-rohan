#### Summary

- **FeatureGuard** now consults both the **feature_flags** table (via `FeatureFlagsService`) and **features.json** (Azure blob via `OrganizationFeaturesService`). Existing `@Features(...)` usage is unchanged; no need to replace the decorator across the codebase.
- When a feature name is present in both sources, the **database value wins** over features.json. Otherwise, features.json is used for legacy keys, and the DB is used for valid flag names when `FeatureFlagsService` and `org_id` are available.
- The **Compliance** controller is gated by `FeatureGuard` and `@Features('ComplianceEnabled')`, so compliance routes require the `ComplianceEnabled` feature flag (DB) to be enabled, consistent with the UI’s `complianceFeatureGuard` and feature-blocking behavior.

#### Technical Details

- **Backend:**
  - **`FeatureGuard`** (`src/auth/features/features.guard.ts`): Injects optional `FeatureFlagsService`. For each `@Features(routeFeature)` name: if `FeatureFlagsService` and request `org_id` exist and the name is a valid feature flag, uses `readFeaturesFlagValue(routeFeature, orgId)` only (DB overrides features.json); otherwise uses enabled list from `OrganizationFeaturesService.readFeatures()`. Handles undefined/non-object `readFeatures()` by treating as no enabled features. `FeatureFlagsService` is `@Optional()` so modules that don’t import `FeatureFlagsModule` still work (features.json-only behavior).
  - **Compliance controller** (`src/compliance/compliance.controller.ts`): Added `FeatureGuard` to `@UseGuards(AuthGuard('jwt'), PermissionsGuard, FeatureGuard)`, added controller-level `@Features('ComplianceEnabled')`, removed the TODO. ComplianceModule already imports `FeatureFlagsModule` and `OrganizationFeaturesModule`.

- **Frontend:** N/A  
- **Database:** N/A (uses existing `feature_flags` table and existing `FeatureFlagsEnum.ComplianceEnabled`).  
- **Contracts:** No changes to request/response shapes or public API contracts.

#### Testing

- **Manual:**
  - [ ] Call compliance endpoints with JWT; with `ComplianceEnabled` off in DB → expect 403 (or guard denial). With `ComplianceEnabled` on → expect normal compliance behavior (subject to PermissionsGuard).
- **Automated:**
  - **Jest:** New `src/auth/features/features.guard.spec.ts` (16 tests): no route features; features.json-only (allow/deny, multiple features, handler + controller merge); invalid/missing features.json; DB flags (allow/deny, invalid name, DB over JSON when both present, DB true when JSON false, missing orgId); optional `FeatureFlagsService` (features.json still works, DB-only flag denied when service is null).
- **Known gaps / TODO:**
  - No E2E added for compliance + feature flag in this PR (existing compliance E2E may assume flag on or mock guard).

#### Risks & Impact

- **Module dependency:** Any controller that uses `FeatureGuard` with a **DB-only** feature name (e.g. `ComplianceEnabled`) must have `FeatureFlagsModule` in its module imports so `FeatureFlagsService` is resolved. ComplianceModule already does; no change required for controllers that only use features.json keys.
- **Behavior change:** For a feature that exists in both features.json and the DB, the guard now uses the DB value only (previously only features.json was used). If any such feature was intentionally driven only by features.json, that would now be overridden by the DB.
- **Performance:** One extra optional service and, when the flag is a valid DB flag, one `isValidFeatureFlag` + one `readFeaturesFlagValue` per request on guarded routes. No new N+1 or heavy work.

#### Verification Steps for Reviewers

1. Run unit tests: `npm run test -- --testPathPattern="features.guard.spec"` and confirm all 16 tests pass.
2. Open `src/auth/features/features.guard.ts` and confirm: (a) DB is checked first when `FeatureFlagsService` and `orgId` exist and the name is valid; (b) fallback is features.json; (c) `FeatureFlagsService` is `@Optional()`.
3. Open `src/compliance/compliance.controller.ts` and confirm controller has `@UseGuards(..., FeatureGuard)`, `@Features('ComplianceEnabled')`, and that ComplianceModule imports `FeatureFlagsModule` (and `OrganizationFeaturesModule`).
4. Optionally: call `GET /compliance/projects` (or another compliance route) with a valid JWT; toggle `ComplianceEnabled` in the feature_flags table and confirm access is allowed only when the flag is enabled.
