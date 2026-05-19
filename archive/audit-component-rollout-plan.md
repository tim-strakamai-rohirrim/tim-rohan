# Reusable Audit Component — Phased Rollout Plan

> Read `audit-component-design.md` first for the target architecture. This doc is the "how we get there without breaking anything" plan.

## Guiding Principles for the Rollout

- **Each phase is one PR, independently mergeable and shippable.** If we stop after phase 2, Settings audit still works and the project has gained a reusable table for free.
- **No user-visible regressions until the final cleanup.** Existing route URLs, column sets, filter behavior, CSV formats, keyboard focus, and scroll behavior stay identical during migration.
- **Feature-flag only if needed.** A global `audit-v2` flag is probably overkill for this work — the swap happens at the component-internals level, not at the page level. Revisit if QA surfaces a phased rollback need.
- **Verify every phase against both live pages.** Settings → Audit tab, and Template Generator → `/template-generator/:id/audit-log`. Eyeball diffs, run unit tests, run the Angular build.

---

## Phase Overview

| # | Goal | Risk | Ships value alone? |
|---|------|------|-------------------|
| 1 | Answer open questions; pick final scope | none | n/a |
| 2 | Scaffold new shared audit primitives (dumb components) | low | partially — new code exercised only by tests |
| 3 | Migrate Settings `AuditTrailComponent` to use new primitives | medium | yes — reduces duplication even before next step |
| 4 | Migrate `TemplateAuditLogComponent` to use new primitives | medium | yes |
| 5 | Introduce `<app-audit-trail-page>` smart container; migrate Settings and Template to use it | medium | yes — consolidates state mgmt |
| 6 | Fill `RunHistoryTabComponent` with the new page | low | yes — ships a feature |
| 7 | Fill `ComplianceProjectAuditPageComponent` (gated on product priority) | low | yes — ships a feature |
| 8 | Delete `AuditTrailManager` and any duplicated HTML/SCSS; doc the component API | low | cleanup |

Phases 6 and 7 are parallelizable with each other and with phase 8 once phase 5 is in.

---

## Phase 1 — Pre-work: resolve open questions

**Not code.** Before touching anything:

- Confirm OneRing data source (same `audit_trail` table, or a separate log?). Drives whether `AuditTrailPageService` needs an injected data-source interface.
- Confirm product priority for compliance project audit. If truly post-MVP, deprioritize phase 7.
- Confirm whether action-text filter should move client→server. Quick look at the backend handler + keystroke behavior.
- Sanity check with anyone who owns the Settings audit tab that the UX should remain identical.

**Deliverables:** one-paragraph decision record appended to `audit-component-design.md` under "Open Questions" before starting phase 2.

**Time estimate:** half a day of async questions, no coding.

---

## Phase 2 — Scaffold shared primitives

**Goal:** new components exist and are unit-tested, but no page consumes them yet.

**Changes:**
- Create `rohan_ui-parent/rohan_ui/src/app/shared-components/audit/`:
  - `audit-table/audit-table.component.{ts,html,scss,spec.ts}`
  - `audit-filter-toolbar/audit-filter-toolbar.component.{ts,html,scss,spec.ts}`
  - `types.ts` — `AuditColumn`, `AuditScope`, `DateRangePreset`, re-exports.
  - `index.ts` — barrel.
- Extract the expandable action-cell logic from the current Settings audit into a private sub-component of `audit-table`.
- Both new components are `standalone: true`, OnPush, signal-friendly.
- Unit tests cover:
  - Table renders N rows given records.
  - Column config hides/shows correct columns.
  - `scrolledToBottom` emits on infinite scroll directive event.
  - Toolbar emits `filtersChanged` with correct shape for each input type.
  - Toolbar feature-toggle inputs correctly hide/show sections.

**Out of scope:** no changes to `AuditTrailComponent`, `TemplateAuditLogComponent`, routes, module declarations beyond the new file.

**Verification:**
- `npm run lint` clean.
- `npm run test -- --include='**/audit/**'` passes.
- Build completes.
- Dev server loads Settings audit and Template audit unchanged (regression check — nothing should differ yet).

**Risk:** low. Strictly additive.

**Branch / PR:** `feature/PRCR-XXXX-audit-primitives` → PR titled something like "Scaffold shared audit-table and audit-filter-toolbar components".

---

## Phase 3 — Migrate Settings `AuditTrailComponent`

**Goal:** Settings audit page looks and behaves identically, but its template body is now `<app-audit-filter-toolbar>` + `<app-audit-table>`.

**Changes:**
- Replace the HTML of `AuditTrailComponent` with the two new primitives.
- Map existing inputs (`auditTrail`, `resultsCount`, `auditTrailFiltersData`) to the primitives' inputs.
- Wire existing outputs (`filters`, `downloadCSVEvent`, `infiniteScrollEvent`) from the primitives' events.
- Delete the extracted HTML/SCSS from the old component.
- Keep `AuditTrailManager` and `settings.component.ts` untouched — they still feed data in via the same @Input/@Output contract.

**Verification:**
- Side-by-side screenshots of Settings → Audit tab before vs after. Must be visually identical.
- Manual test script:
  - Date range presets all work.
  - Custom date range modal works.
  - Email multi-select + search work.
  - Feature multi-select + search work.
  - Clear All clears everything.
  - CSV download triggers with correct filename and timezone.
  - Infinite scroll fetches next page.
  - Action cell expand/collapse works on long actions.
- Existing `AuditTrailComponent` spec still passes (may need adjustments for new child components; prefer shallow rendering).

**Risk:** medium. User-facing page, but the delta is purely HTML restructuring.

**Branch / PR:** `feature/PRCR-XXXX-migrate-settings-audit` stacked on phase 2.

---

## Phase 4 — Migrate `TemplateAuditLogComponent`

**Goal:** Template audit page looks and behaves identically, using the same two primitives as Settings.

**Changes:**
- Replace HTML of `TemplateAuditLogComponent` with `<app-audit-filter-toolbar>` (configured with `showFeatureFilter=false`, `showActionTextFilter=true`) + `<app-audit-table>` (columns: `['timestamp','action','performed_by']`, `infiniteScroll=false`).
- Keep existing fetch logic (`getAuditTrail({templateId, pageSize: 10000})`) — that still lives in the component's `.ts` file for now.
- Keep client-side action filter unless phase 1 decided to flip it server-side.

**Verification:**
- Side-by-side screenshots of `/template-generator/:id/audit-log` before vs after.
- Manual test script:
  - Default 6-month date range applied on load.
  - Email multi-select works.
  - Action text filter works (client-side, same as today, unless flipped in phase 1).
  - Back link navigates to template generator.
  - CSV download filters by action text client-side (or server-side if flipped).
  - Spinner displays during load.

**Risk:** medium.

**Branch / PR:** `feature/PRCR-XXXX-migrate-template-audit` stacked on phase 3.

---

## Phase 5 — Introduce `<app-audit-trail-page>` smart container

**Goal:** Both Settings and Template audit become thin one-liner consumers. State management moves out of page-level code and into `AuditTrailPageService`.

**Changes:**
- Create `shared-components/audit/audit-trail-page/audit-trail-page.component.{ts,html,scss,spec.ts}`.
- Create `shared-components/audit/audit-trail-page.service.ts` with signal-based state (see design doc).
- Migrate `settings.component.ts`: drop the audit-trail slice of state; replace `<app-audit-trail>` in its template with `<app-audit-trail-page>`.
- Migrate `TemplateAuditLogComponent`: becomes essentially `<app-audit-trail-page [scope]="{feature:'Template-Generator', templateId}" [showFeatureFilter]="false" [showActionTextFilter]="true" [columns]="['timestamp','action','performed_by']" [infiniteScroll]="false" />` + the back-link header.
- Deprecate `AuditTrailManager` (mark `@deprecated`, leave file for now — phase 8 deletes).

**Verification:**
- Same regression screenshots + test scripts as phases 3 and 4.
- New spec for `AuditTrailPageService`: scope setting, filter application, pagination, CSV delegation.
- New spec for `AuditTrailPageComponent`: inputs flow through to children; scope changes trigger service reset.

**Risk:** medium-high. Touches more state than phases 3–4. Recommend merging phases 3 and 4 first and letting them soak for at least a sprint before phase 5.

**Branch / PR:** `feature/PRCR-XXXX-audit-trail-page-container`.

---

## Phase 6 — Fill `RunHistoryTabComponent`

**Goal:** OneRing run history tab stops being a placeholder.

**Changes (assuming OneRing uses the shared `audit_trail` table — confirm in phase 1):**
- Replace `run-history-tab.component.html` placeholder text with `<app-audit-trail-page [scope]="{scopeType: 'one-ring-run', scopeId: runId()}" [showFeatureFilter]="false" [showActionTextFilter]="true" [columns]="['timestamp','action','performed_by']" />`.
- Wire `runId` from the OneRing state service.
- Confirm the backend emits audit rows with matching `scopeType` / `scopeId` values. If not, this phase depends on a small backend change first.

**Alternative path if OneRing data source is separate:**
- Add `AuditDataSource` injection token to `AuditTrailPageService`.
- Provide an `OneRingRunLogDataSource` implementing the token that hits OneRing's existing run-log endpoint.
- Set provider scope on `RunHistoryTabComponent` only.

**Verification:**
- Visit the run history tab of an existing run; confirm rows appear and filter/scroll/CSV all work.
- Unit test the component with a mocked page service.

**Risk:** low (UI side). Backend dependency is the variable.

**Branch / PR:** `feature/PRCR-XXXX-one-ring-run-history`.

---

## Phase 7 — Fill `ComplianceProjectAuditPageComponent`

**Goal:** Compliance project audit page stops being a placeholder.

**Gating:** product priority. Skip until scheduled.

**Changes:**
- Replace `<app-compliance-tab-placeholder>` with `<app-audit-trail-page [scope]="{scopeType:'compliance-project', scopeId: projectId()}" [showFeatureFilter]="false" [columns]="['timestamp','action','performed_by']" />`.
- Wire `projectId` from the route.
- Confirm backend emits compliance-project audit rows (if not, add a backend ticket and block on it).

**Verification:** per-row checks on a test project; CSV download; multi-user filter.

**Risk:** low once backend emits the rows.

**Branch / PR:** `feature/PRCR-XXXX-compliance-project-audit`.

---

## Phase 8 — Cleanup

**Goal:** remove the scaffolding that let the migration happen incrementally.

**Changes:**
- Delete `AuditTrailManager` (no callers after phase 5).
- Delete any HTML/SCSS left in old `AuditTrailComponent` / `TemplateAuditLogComponent` that duplicates the new primitives. If those wrappers now only exist to pass-through, consider deleting the wrappers too and pointing consumers directly at `<app-audit-trail-page>`.
- Add a short README in `shared-components/audit/` covering: inputs, scope shapes, how to add a new consumer, how to add a new column.
- Tighten types: `AuditScope` should be a discriminated union if phase 1 clarified that the five scope fields split into mutually-exclusive modes.

**Verification:** build, test suite, lint.

**Risk:** low.

**Branch / PR:** `chore/PRCR-XXXX-audit-cleanup`.

---

## Rollback Strategy

Every migration phase (3, 4, 5) is a revertable PR. Since no routes, no DB schema, and no API contracts change, rolling back a phase is `git revert` + redeploy. The new `shared-components/audit/*` stays in place even on revert — it causes no harm unless a consumer imports it.

If mid-phase something unfixable shows up, we keep the old `AuditTrailComponent` code in a separate file (don't delete in the same PR as the migration — delete in a later cleanup PR). This is already how phase 8 is structured.

---

## Effort & Sequencing

Rough estimates, assuming one engineer working sequentially and no surprise blockers:

| Phase | Dev | Review + QA | Total |
|-------|-----|-------------|-------|
| 1 | 0.5d async | — | 0.5d |
| 2 | 2–3d | 1d | 3–4d |
| 3 | 1–2d | 1d | 2–3d |
| 4 | 1d | 0.5d | 1.5d |
| 5 | 3–4d | 1–2d | 4–6d |
| 6 | 1–2d (UI) + backend-dependent | 1d | 2–3d + backend |
| 7 | 1–2d + backend-dependent | 1d | 2–3d + backend |
| 8 | 1d | 0.5d | 1.5d |

**Total frontend:** roughly 2.5–3.5 weeks of engineering for phases 2–5 + 8 (the core consolidation). Placeholder fills (6, 7) add as their backend data is ready.

**Recommended cadence:** ship phases 2, 3, 4 in one sprint; phase 5 early next sprint so it can bake; 6/7/8 as availability and product priority allow.

---

## Exit Criteria for the Whole Effort

Consider the consolidation done when:
- [ ] Both Settings and Template audit pages render exclusively via `<app-audit-trail-page>`.
- [ ] `AuditTrailManager` is deleted.
- [ ] At least one placeholder (ideally `RunHistoryTabComponent`) is using the new page component and shipping real data.
- [ ] `shared-components/audit/` has a README and ≥80% unit test coverage on its components and service.
- [ ] No visible regression vs pre-migration screenshots on the two live pages.
