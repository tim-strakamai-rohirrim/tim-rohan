#### Summary

- Migrate the **COMPLIANCE** feature flag from the legacy `features.json` file in Azure Storage to the database-backed `FeatureFlagsService`, aligning it with the new feature-flag system used by AEV1 and other flags.
- Add comprehensive Karma/Jasmine unit tests for both `FeatureBlockingService` and `FeatureFlagsService` (the latter previously had no spec file).

#### Technical Details

- Frontend:
    - `FeatureBlockingService.getEnabledFeatures$` now fetches the `ComplianceEnabled` flag from the database via `FeatureFlagsService.isFeatureEnabled()` in parallel with the existing `AEV1` flag check (using `forkJoin`).
    - `parseFeaturesToBoolean()` accepts a new `complianceEnabled: boolean` parameter and sets `COMPLIANCE` directly from it, instead of parsing the value from the Azure Storage JSON blob.
    - Extracted `isOnSignInPage()` into a private method for testability and reuse.
    - For non-admin users, `COMPLIANCE` is now intersected with the user's roles the same way other features are gated (org-level flag AND user role).

#### Testing

- Manual:
    - TODO: Verify that toggling the `ComplianceEnabled` flag in the database enables/disables the Compliance feature for both admin and non-admin users.
    - TODO: Verify that there is no `COMPLIANCE` key in `features.json`.
- Automated:
    - [Karma/Jasmine]: Added `feature-flags.service.spec.ts` (168 lines) — covers `isFeatureEnabled` (enabled/disabled/missing `isEnabled`), LRU cache hits within TTL, cache expiration after 5-minute TTL, error handling with cache fallback, independent per-flag caching, and `invalidateCache` for single-flag and full-cache clearing.
    - [Karma/Jasmine]: Expanded `feature-blocking.service.spec.ts` from ~150 to ~415 lines — added coverage for `getDefaultFeatures`, `getEnabledFeatures$` (sign-in page, unauthenticated, admin, non-admin, AEV1 gating), `getSetEnabledFeatures` (sign-in bypass, success, error), `parseFeaturesToBoolean` with `complianceEnabled` parameter, and `getUserFeatures` with COMPLIANCE role and unknown roles.
- Known gaps / TODO:
    - No Playwright E2E tests added for this change yet.

#### Risks & Impact

- **Breaking change to `parseFeaturesToBoolean` signature**: the method now requires a second `complianceEnabled` argument. Any code calling it directly must be updated. Since it is an internal service method, the blast radius is limited to `FeatureBlockingService` itself.
- The `COMPLIANCE` key in the Azure Storage `features.json` is now **ignored**. If the database `ComplianceEnabled` flag row does not exist, compliance will default to `false` (the `FeatureFlagsService` error/missing-field fallback).
- No migration or rollout coordination needed — the `ComplianceEnabled` flag already exists in the feature-flags table.

#### Verification Steps for Reviewers

1. Check that the `ComplianceEnabled` row exists in the `feature_flags` database table for the target environment.
2. Log in as an **admin** user with `ComplianceEnabled = true` in the DB → Compliance module should be accessible.
3. Set `ComplianceEnabled = false` in the DB, hard-refresh → Compliance module should be hidden.
4. Log in as a **non-admin** user who has the COMPLIANCE role, with `ComplianceEnabled = true` → Compliance module should be accessible.
5. Log in as a non-admin user **without** the COMPLIANCE role, with `ComplianceEnabled = true` → Compliance module should remain hidden.
6. Run `ng test` and confirm all new and existing specs pass.
