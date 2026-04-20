# PRCR-1229: Add caching to feature-flags service

## Problem statement

`FeatureFlagsService` in rohan_api currently queries the database on **every** read:

- `readFeaturesFlagValue()` → calls `queryDBForFeatureFlags()` each time
- `listFeatureFlags()` → calls `queryDBForFeatureFlags()` each time
- `knowledgeManagement()` → calls `readFeaturesFlagValue()` → DB read

Feature-flag checks are used across many modules (auth guards, answer-engine, proposal-writer, admin, compliance, etc.), so a single request can trigger multiple DB round-trips for the same immutable-within-request data. This increases latency and database load without benefit, since flags change infrequently (typically via CLI or admin).

**Goal:** Reduce the number of database calls for feature-flag reads by caching the result of `queryDBForFeatureFlags()` and invalidating the cache on writes.

---

## Assumptions

- Use the **existing** `@nestjs/cache-manager` stack already used elsewhere (e.g. `OrganizationFeaturesService`, `CategoriesService`). `CacheModule` is registered globally via `OrganizationFeaturesModule` with `isGlobal: true`, so no new global cache registration is required.
- Cache key is a single key for “all flags” (e.g. `feature-flags:db`). No per-flag or per-org cache keys in this change.
- **Write-through invalidation:** After `addOrEnableFeatureFlag()` or `removeFeatureFlag()` succeeds, the cache is invalidated (delete key) so the next read refetches from the DB.
- Public API of `FeatureFlagsService` (method signatures and return types) remains unchanged; callers do not need to change.
- No frontend or API contract changes: feature-flag endpoints and responses stay the same; only backend implementation adds caching.
- **TTL:** Cache entry TTL is **5 minutes (300s)** so that stale data is refreshed even without a write (e.g. external DB changes or missed invalidations).
- **Manual invalidation:** Not in scope. Write operations (`addOrEnableFeatureFlag`, `removeFeatureFlag`) invalidate the cache; no separate admin/CLI invalidation for this ticket.

---

## Ordered checklist (by phase)

### Phase 1: Backend – add cache to FeatureFlagsService and module

- [x] **[BACKEND_DB]** Introduce cache for feature-flag DB read.
  - **Owner:** BACKEND_DB  
  - **Steps:**
    1. In `FeatureFlagsService`, inject `CACHE_MANAGER` (from `@nestjs/cache-manager`) and define a private cache key constant (e.g. `FEATURE_FLAGS_CACHE_KEY = 'feature-flags:db'`).
    2. In `queryDBForFeatureFlags()` (or a thin wrapper used only by reads): check cache first; if hit, return cached `DbFlags[]`; if miss, call DB, then `cache.set(key, result, ttlMs)` and return result. Use TTL of **300_000 ms (5 minutes)**.
    3. After successful `addOrEnableFeatureFlag()` and `removeFeatureFlag()`, call `cache.del(FEATURE_FLAGS_CACHE_KEY)` so the next read refetches.
  - **Files:**  
    - `rohan_api-parent/rohan_api/src/utils/feature-flags/feature-flags.service.ts`

- [x] **[BACKEND_DB]** Ensure `FeatureFlagsModule` can use the global cache.
  - **Owner:** BACKEND_DB  
  - **Steps:**
    1. Confirm `CacheModule` is already available globally (via `OrganizationFeaturesModule` in `AppModule`). No change to `FeatureFlagsModule` if so.
    2. If for any reason the global cache is not available in the context where `FeatureFlagsModule` is imported, add `CacheModule` to `FeatureFlagsModule` imports (same pattern as `OrganizationFeaturesModule`).
  - **Files:**  
    - `rohan_api-parent/rohan_api/src/utils/feature-flags/feature-flags.module.ts` (only if step 2 is needed)

### Phase 2: Tests and review

- [x] **[BACKEND_DB]** Unit tests: cache hit/miss and invalidation.
  - **Owner:** BACKEND_DB  
  - **Steps:**
    1. In `feature-flags.service.spec.ts`, inject a mock `CACHE_MANAGER` (e.g. `get`/`set`/`del` spies).
    2. Add tests: (a) first call misses cache and hits DB, then sets cache; (b) second call hits cache and does not call DB; (c) after `addOrEnableFeatureFlag` or `removeFeatureFlag`, next read misses cache and hits DB again.
  - **Files:**  
    - `rohan_api-parent/rohan_api/src/utils/feature-flags/feature-flags.service.spec.ts`

- [x] **[TEST_REVIEW]** Run unit tests and sanity-check one E2E path that uses feature flags.
  - **Owner:** TEST_REVIEW  
  - **Steps:**
    1. Run `npm run test -- src/utils/feature-flags/feature-flags.service.spec.ts` in rohan_api.
    2. Optionally run a relevant E2E that touches feature flags (e.g. proposal-writer or admin) to ensure no regression.
  - **Files:**  
    - N/A (test execution only)

---

## Phase order and parallelism

- **Files touched per phase**
  - **Phase 1:**  
    - `rohan_api-parent/rohan_api/src/utils/feature-flags/feature-flags.service.ts`  
    - Possibly `rohan_api-parent/rohan_api/src/utils/feature-flags/feature-flags.module.ts`
  - **Phase 2:**  
    - `rohan_api-parent/rohan_api/src/utils/feature-flags/feature-flags.service.spec.ts`

- **Parallelism**
  - Phase 1 and Phase 2 cannot be done in parallel: Phase 2 depends on Phase 1 implementation (tests target the new cache behavior).
  - Within Phase 1, the two checklist items can be done in one commit (service change first, then confirm module).

- **Recommended order**
  1. Phase 1 (backend cache + module check) in a single PR.
  2. Phase 2 (unit tests, then test/review).  
  Rationale: Small, reviewable change; tests verify cache behavior and invalidation without touching other repos or API contracts.

---

## Definition of done (recap)

- [ ] `PRCR-1229-PLAN.md` exists and contains problem, assumptions, decisions, ordered checklist with owner tags, phase order and file list. *(this file)*
- [ ] `PRCR-1229-contracts.md` created/updated with any API/contract impact. *(no API change; contracts doc records “no contract change” and cache semantics.)*
- [ ] Implementation and tests completed per checklist; no “big bang” edits.
