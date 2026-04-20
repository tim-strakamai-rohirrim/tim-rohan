# PRCR-1229: Phase 1 & 2 – Testing/Review handoff

## Scope reviewed

- **Phase 1:** Backend cache in `FeatureFlagsService` and module.
  - **Files:** `rohan_api-parent/rohan_api/src/utils/feature-flags/feature-flags.service.ts`, `feature-flags.module.ts`
- **Phase 2:** Unit tests for cache hit/miss and invalidation.
  - **Files:** `rohan_api-parent/rohan_api/src/utils/feature-flags/feature-flags.service.spec.ts`
- **Contracts:** `PRCR-1229-contracts.md` (no API change; cache semantics documented).

---

## Implementation review

- **feature-flags.service.ts:** Correct. Single cache key `feature-flags:db`, TTL 300s, read path checks cache then DB and sets cache on miss; `addOrEnableFeatureFlag` and `removeFeatureFlag` call `cache.del(FEATURE_FLAGS_CACHE_KEY)` after success. Matches plan and contracts.
- **feature-flags.module.ts:** No change; relies on global `CacheModule` (via `OrganizationFeaturesModule`). Correct per plan.
- **feature-flags.service.spec.ts:** Mock `CACHE_MANAGER` was already present. Added `FEATURE_FLAGS_CACHE_KEY` and `FEATURE_FLAGS_CACHE_TTL_SEC` in spec for assertions. New describe **"cache behavior (PRCR-1229)"** with four tests: (1) first read misses cache, hits DB, sets cache with key and TTL; (2) second read hits cache, `set` not called again; (3) after `addOrEnableFeatureFlag`, `del` called and next read refetches; (4) after `removeFeatureFlag`, same. Asserted `mockCache.del(FEATURE_FLAGS_CACHE_KEY)` in existing "adds a new feature flag", "enables an existing feature flag", "remove feature flag successfully", and "not remove feature flag if does not exists".

---

## Test updates

| File | Change |
|------|--------|
| `rohan_api-parent/rohan_api/src/utils/feature-flags/feature-flags.service.spec.ts` | Added constants `FEATURE_FLAGS_CACHE_KEY`, `FEATURE_FLAGS_CACHE_TTL_SEC`; new describe **"cache behavior (PRCR-1229)"** with 4 tests; added `expect(mockCache.del).toHaveBeenCalledWith(FEATURE_FLAGS_CACHE_KEY)` in 4 existing write tests. |

---

## Test run

- `npm run test -- src/utils/feature-flags/feature-flags.service.spec.ts` — **19 tests passed.**

---

## Issues

- None. No refactors applied; implementation and tests align with plan and contracts.

---

## Optional follow-up

- Run a feature-flag–related E2E for sanity (e.g. `admin.e2e-spec.ts` GET `/admin/feature-flag/:flag-name` or proposal-writer E2E that mocks `FeatureFlagsService`) to confirm no regression. Not required for Phase 2 definition of done.

---

## Next owner

- **[PLANNER]** for next phase or closure. No [FRONTEND] or [BACKEND_DB] fixes required from this review.
