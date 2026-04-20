# PRCR-1229: API contracts and data shapes

## Summary

**Change:** Add in-memory caching to `FeatureFlagsService` in rohan_api to reduce database calls for feature-flag reads.

**Contract impact:** None. No changes to REST API request/response shapes, DTOs, or error formats. This is an internal backend optimization.

---

## Existing contracts (unchanged)

### Feature flag reads (internal service)

- **`FeatureFlagsService.readFeaturesFlagValue(keyName: string, orgId?: string): Promise<boolean>`**  
  Behavior unchanged: returns whether the flag is enabled. After this change, the result may be served from cache; semantics remain the same.

- **`FeatureFlagsService.listFeatureFlags(): Promise<FeatureFlags>`**  
  Behavior unchanged: returns the current set of flags. May be served from cache.

- **`FeatureFlagsService.knowledgeManagement(orgId?: string): Promise<boolean>`**  
  Behavior unchanged: delegates to `readFeaturesFlagValue` for `langchain_v1_knowledge_management`.

### Feature flag writes (internal service)

- **`FeatureFlagsService.addOrEnableFeatureFlag(keyName, value): Promise<void>`**  
  Behavior unchanged. Implementation will invalidate the read cache after a successful write so the next read sees the new value.

- **`FeatureFlagsService.removeFeatureFlag(keyName): Promise<void>`**  
  Behavior unchanged. Implementation will invalidate the read cache after a successful delete.

### Data shapes (unchanged)

- **`DbFlags`**  
  `{ feature: string; flag_value: boolean }[]` — used internally; no change.

- **`FeatureFlags`**  
  Class built from `DbFlags[]`; public API unchanged.

- **`FeatureFlagsEnum`**  
  Enum of flag names; unchanged.

---

## Cache semantics (internal, not an API contract)

- **Read path:** The first read after startup or after cache invalidation loads flags from the database and stores them in the cache. Subsequent reads are served from the cache until TTL expires or the cache is invalidated.
- **Write path:** On successful `addOrEnableFeatureFlag` or `removeFeatureFlag`, the cache entry for feature flags is deleted. The next read will refetch from the database.
- **TTL:** Cache entry TTL is 5 minutes (300s). Entries expire after 5 minutes even if no write occurs.
- **Consistency:** Callers may observe a short window of stale data (up to 5 minutes) if flags are changed outside this process. For normal use (CLI/admin writes in the same process), invalidation keeps reads up to date after writes.

---

## Validation and errors

No change to validation rules or error formats. Existing error handling (e.g. DB errors, invalid flag names) remains as today.

---

## Changelog

- **Phase 1 (backend cache):** No contract or API change. Implementation added cache for `queryDBForFeatureFlags()` (key `feature-flags:db`, TTL 300s), and write-through invalidation on `addOrEnableFeatureFlag` / `removeFeatureFlag`. Contracts doc unchanged; this entry records the implementation phase.
