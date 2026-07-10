# AP Step Shell — Common Step UI Components (PLAN)

> **Ticket:** none yet. Working slug `AP-STEP-SHELL`. Rename `AP-STEP-SHELL-PLAN.md` / `AP-STEP-SHELL-contracts.md` and the branch prefixes once a JIRA ticket exists (likely under the PE / Pathway Engines epic **PRCR-1633**).

## Problem statement

The Acquisition Pathways wizard has four step components — `requirements-record`, `integrity-check`, `package-assembly`, `finalize-package`. They share a visual structure but each re-implements it from scratch with its own BEM prefix (`ap-rr`, `ap-ic`, `ap-pa`, `ap-fp`). The result is **~2,259 lines of step SCSS** and ~812 lines of step HTML, much of it copy-pasted-with-renamed-selectors. Empty states, filter sidebars, filter pills, source pills and artifact cards drift independently and there is no single place to enforce consistency.

We want a small set of **presentational (dumb) components** that steps compose with `<ng-content>`, plus a shared SCSS token/mixin partial. Each step keeps its own logic and data; it just stops re-declaring the shared chrome. This is deliberately **not** a config-driven "mega step" component — the wizard host (`shared-components/wizard/wizard.component.ts`) already owns config-driven step orchestration; adding a second config layer would duplicate it.

## Key architectural observations

- **Two structural families:**
  - _Workbench_ (`requirements-record`, `integrity-check`): a two-column `__sidebar` + `__main` grid (`280px 1fr`, collapses at 960px, sticky sidebar). Sidebar holds filter cards ("Filters" header + active-count reset badge + filter pills with label/count/dot/icon). Both also render source pills.
  - _Gallery_ (`finalize-package`, `package-assembly`): single-column card grids of artifact cards (icon header, title, type/`· DOCX`, footer actions), plus a loading/queued banner.
- **Universal across all four:** an empty state — `<mat-icon>` + explanatory message — and artifact/card markup (`__card`, `__card-header`).
- **Wizard instantiation constraint:** the wizard host renders each *step* dynamically and wires inputs via `Object.assign(instance, config.inputs)`, which requires classic `@Input()` decorators (see root `CLAUDE.md`). This constraint applies only to the step components themselves. The new shared components are used **inside** step templates, never dynamically instantiated by the wizard, so they are free to use modern `input()`/`output()` signal APIs.
- **Existing inconsistency:** `finalize-package` wraps its body in `<app-card-shell>`; the other three do not. The shared scaffold/empty-state must **not** force a card-shell wrapper — leave that choice to each step.
- **Styling:** step SCSS uses `@use 'styles/index' as *` and pulls tokens like `$content-background`, `$activity-border`, `$card-shadow`, `$secondary-text`, `$teal`, `$main-text`. The shared partial lives alongside these tokens.
- **Module wiring:** steps are declared in `acquisition-pathways.module.ts` (`standalone: false`). The module already imports standalone components (`ApChatPanelComponent`, `ApShellComponent`), so new **standalone** presentational components can be added to `imports` the same way. A barrel already exists at `shared/index.ts`.

## Assumptions

- New shared components are **standalone** and live under `pages/acquisition-pathways/shared/` (module-local; only AP uses them — do not promote to app-wide `shared-components/` yet). If a second module ever needs them, promote later.
- Components use signal `input()`/`output()`; they hold no business logic and inject nothing beyond `MatIcon`/`MatTooltip` where needed.
- Visual output after migration is intended to be **pixel-equivalent** to today (this is a refactor, not a redesign). Percy/visual diffs are the safety net. **Caveat:** `npm run test:percy` runs the *full* Playwright E2E suite under Percy and requires `PERCY_TOKEN` + a decrypted `.env.test` (via `dotenv-cli`) — it is not a step-scoped check and will no-op/fail in an environment without those secrets (e.g. an autonomous run without Percy configured). In that case the unit specs are the gate and the Percy diff must be reviewed manually before merge; the migration should not be considered visually verified on the spec pass alone.
- FullStory analytics stay in the *step* components. Shared pills expose `(pillClick)` / `(reset)` outputs; the step supplies the `data-analytics-id` and calls `trackEvent`. No analytics logic moves into shared components.
- No backend, API, or DB changes. Frontend-only.

## Open questions

| # | Question | Proposed default |
|---|----------|------------------|
| 1 | JIRA ticket + epic? | File under PE epic PRCR-1633; rename docs/branches then. |
| 2 | Should the empty-state and loading/extracting states be one component (`state` input) or two? | **One** `ApStepEmptyStateComponent` with a `loading` boolean that swaps icon + copy. Fewer files. |
| 3 | Extract `ApSourcePillComponent` too (used 2×, but each step maps `kind → icon` slightly differently)? | Yes, but lowest priority — it's the last step of Phase 2. If the icon-mapping divergence makes it awkward, leave source pills per-step and note it. |
| 4 | Unify BEM prefix? Shared components own neutral prefixes (`ap-step-scaffold`, `ap-filter-card`, …); steps keep their own prefix for *remaining* step-specific markup. | Yes — neutral prefixes on shared components. |
| 5 | Should `finalize-package` keep its `<app-card-shell>` wrapper? | Yes, leave as-is; out of scope. |

## Component set (the "common structure")

| Component | Selector | Used by | Replaces |
|-----------|----------|---------|----------|
| `ApStepScaffoldComponent` | `ap-step-scaffold` | workbench (2) | `.ap-rr` / `.ap-ic` sidebar+main grid |
| `ApStepEmptyStateComponent` | `ap-step-empty-state` | all (4) | `__empty` + loading banner blocks |
| `ApFilterCardComponent` | `ap-filter-card` | workbench (2) | `__card` + `__card-header` + active badge |
| `ApFilterPillComponent` | `ap-filter-pill` | workbench (2) | `__filter-pill` |
| `ApStepCardComponent` | `ap-step-card` | gallery (2) | `__card` artifact card |
| `ApSourcePillComponent` _(optional)_ | `ap-source-pill` | workbench (2) | `__src-pill` |

Exact public APIs (inputs/outputs/slots) and the shared SCSS token list are in `AP-STEP-SHELL-contracts.md`.

---

## Implementation phases

### Phase 1 — Build shared presentational components + SCSS partial [FRONTEND]

```phase-meta
phase: 1
title: Build shared step components
tags: [FRONTEND]
repo: rohan_ui
base_branch: main
depends_on: []
files:
  - src/app/pages/acquisition-pathways/shared/step-scaffold/ap-step-scaffold.component.ts
  - src/app/pages/acquisition-pathways/shared/step-scaffold/ap-step-scaffold.component.html
  - src/app/pages/acquisition-pathways/shared/step-scaffold/ap-step-scaffold.component.scss
  - src/app/pages/acquisition-pathways/shared/step-empty-state/ap-step-empty-state.component.ts
  - src/app/pages/acquisition-pathways/shared/step-empty-state/ap-step-empty-state.component.html
  - src/app/pages/acquisition-pathways/shared/step-empty-state/ap-step-empty-state.component.scss
  - src/app/pages/acquisition-pathways/shared/filter-card/ap-filter-card.component.ts
  - src/app/pages/acquisition-pathways/shared/filter-card/ap-filter-card.component.html
  - src/app/pages/acquisition-pathways/shared/filter-card/ap-filter-card.component.scss
  - src/app/pages/acquisition-pathways/shared/filter-pill/ap-filter-pill.component.ts
  - src/app/pages/acquisition-pathways/shared/filter-pill/ap-filter-pill.component.html
  - src/app/pages/acquisition-pathways/shared/filter-pill/ap-filter-pill.component.scss
  - src/app/pages/acquisition-pathways/shared/step-card/ap-step-card.component.ts
  - src/app/pages/acquisition-pathways/shared/step-card/ap-step-card.component.html
  - src/app/pages/acquisition-pathways/shared/step-card/ap-step-card.component.scss
  - src/app/pages/acquisition-pathways/shared/_ap-step.scss
  - src/app/pages/acquisition-pathways/shared/index.ts
  - src/app/pages/acquisition-pathways/acquisition-pathways.module.ts
contracts:
  - "1. ApStepScaffoldComponent"
  - "2. ApStepEmptyStateComponent"
  - "3. ApFilterCardComponent"
  - "4. ApFilterPillComponent"
  - "5. ApStepCardComponent"
  - "7. Shared SCSS tokens (_ap-step.scss)"
verification:
  - npm run lint
  - npm run test:ci
  - npm run build
```

**Goal**: Create the standalone presentational components and shared SCSS partial, register them, and cover them with unit specs — with **no step migrated yet**, so this phase merges safely on its own.

**Steps**:

- [ ] **1.1** Create `_ap-step.scss` with the shared tokens/mixins (muted uppercase label, card border+shadow, pill base, empty-state block, source-pill base). See contracts §7.
  - File: `shared/_ap-step.scss`
- [ ] **1.2** Build `ApStepScaffoldComponent` — `<ng-content select="[sidebar]">` + default slot for main; owns the `280px 1fr` grid, sticky sidebar, 960px collapse. Optional `sidebarWidth` input (default `280px`).
- [ ] **1.3** Build `ApStepEmptyStateComponent` — inputs `icon`, `loading` (default false); default `<ng-content>` for the message. When `loading`, render the hourglass variant. See contracts §2.
- [ ] **1.4** Build `ApFilterCardComponent` — inputs `label`, `activeCount` (default 0); output `reset`; default slot for filter sections; optional `[header-extra]` slot. Renders the active-count reset badge only when `activeCount > 0`.
- [ ] **1.5** Build `ApFilterPillComponent` — inputs `label`, `count`, `active`; output `pillClick`; `[leading]` slot for the dot/icon. Emits `aria-pressed`.
- [ ] **1.6** Build `ApStepCardComponent` — inputs `icon`, `title`, `subtitle`, optional `state`/`accent`; `[actions]` slot (footer) + default slot for body (progress bars etc.). See contracts §5.
- [ ] **1.7** _(Optional, lowest priority)_ Build `ApSourcePillComponent` — inputs `icon`, `label`, `clickable`; output `pillClick`. Skip and note if the per-step icon mapping makes it awkward.
- [ ] **1.8** Export all from `shared/index.ts`; add the standalone components to `acquisition-pathways.module.ts` `imports`.
- [ ] **1.9** Unit specs for each component: renders slots, toggles state/active, emits outputs. Use `FullstoryServiceStub` only if a component injects it (none should).

### Phase 2 — Migrate workbench steps [FRONTEND]

```phase-meta
phase: 2
title: Migrate workbench steps
tags: [FRONTEND]
repo: rohan_ui
base_branch: phase-1
depends_on: [1]
files:
  - src/app/pages/acquisition-pathways/steps/requirements-record-step/requirements-record-step.component.html
  - src/app/pages/acquisition-pathways/steps/requirements-record-step/requirements-record-step.component.scss
  - src/app/pages/acquisition-pathways/steps/integrity-check-step/integrity-check-step.component.html
  - src/app/pages/acquisition-pathways/steps/integrity-check-step/integrity-check-step.component.scss
contracts:
  - "1. ApStepScaffoldComponent"
  - "2. ApStepEmptyStateComponent"
  - "3. ApFilterCardComponent"
  - "4. ApFilterPillComponent"
  - "6. ApSourcePillComponent"
verification:
  - npm run lint
  - npm run test:ci -- --include='src/app/pages/acquisition-pathways/steps/requirements-record-step/requirements-record-step.component.spec.ts'
  - npm run test:ci -- --include='src/app/pages/acquisition-pathways/steps/integrity-check-step/integrity-check-step.component.spec.ts'
  - npm run test:percy   # visual gate — needs PERCY_TOKEN + .env.test; skip locally if unavailable (see Assumptions)
```

**Goal**: Replace the hand-rolled sidebar/main/filter/empty markup in the two workbench steps with the shared components; delete the now-dead SCSS from each step's `.scss`.

**Steps**:

- [ ] **2.1** `requirements-record`: wrap layout in `<ap-step-scaffold>`; move the sidebar into `[sidebar]`. Replace the filters card with `<ap-filter-card [activeCount]="activeTagFilterBadge()" (reset)="resetTagFilter()">` and each pill with `<ap-filter-pill [active]="tagFilter() === pill.key" [count]="countByTag(pill.key)" (pillClick)="setTagFilter(pill.key)">`. Keep `data-analytics-id` + `trackEvent` on the step-supplied elements.
- [ ] **2.2** `requirements-record`: replace the two `__empty`/extracting blocks with `<ap-step-empty-state [loading]="!!extracting?.()" icon="…">`. Convert source pills to `<ap-source-pill>` (if 1.7 shipped).
- [ ] **2.3** `requirements-record`: delete the migrated selectors from the `.scss` (sidebar/card/filter-pill/empty/src-pill). Keep field-row, tag, textarea, add-row styles.
- [ ] **2.4** `integrity-check`: same scaffold + filter-card + filter-pill migration. The methods differ from requirements-record — wire against the real API: `<ap-filter-card [activeCount]="activeFilterCount()" (reset)="resetFilters()">`; Category section pills `<ap-filter-pill [active]="categoryFilter() === key" (pillClick)="setCategory(key)">` with a `<mat-icon>` in the `[leading]` slot; Severity section pills `<ap-filter-pill [active]="severityFilter() === key" (pillClick)="setSeverity(key)">` with a severity **dot** in `[leading]` (note `setSeverity` toggles back to `'all'` on re-click — leave that logic in the step). Keep the "Apply all changes" button and the donut/findings markup as step-specific. Preserve the existing analytics selectors (`categoryPillSelector`, `severityPillSelector`, `resetFiltersSelector`) on the step-supplied elements.
- [ ] **2.5** `integrity-check`: replace `__empty` with `<ap-step-empty-state>`; convert section source pills to `<ap-source-pill>` (if shipped). Delete migrated SCSS.
- [ ] **2.6** Run the two step specs + Percy; reconcile any visual drift against Phase 1 tokens.

### Phase 3 — Migrate gallery steps [FRONTEND]

```phase-meta
phase: 3
title: Migrate gallery steps
tags: [FRONTEND]
repo: rohan_ui
base_branch: phase-2
depends_on: [1]
files:
  - src/app/pages/acquisition-pathways/steps/finalize-package-step/finalize-package-step.component.html
  - src/app/pages/acquisition-pathways/steps/finalize-package-step/finalize-package-step.component.scss
  - src/app/pages/acquisition-pathways/steps/package-assembly-step/package-assembly-step.component.html
  - src/app/pages/acquisition-pathways/steps/package-assembly-step/package-assembly-step.component.scss
contracts:
  - "2. ApStepEmptyStateComponent"
  - "5. ApStepCardComponent"
verification:
  - npm run lint
  - npm run test:ci -- --include='src/app/pages/acquisition-pathways/steps/finalize-package-step/finalize-package-step.component.spec.ts'
  - npm run test:ci -- --include='src/app/pages/acquisition-pathways/steps/package-assembly-step/package-assembly-step.component.spec.ts'
  - npm run test:percy   # visual gate — needs PERCY_TOKEN + .env.test; skip locally if unavailable (see Assumptions)
```

**Goal**: Replace the artifact cards and empty/loading blocks in the two gallery steps with `<ap-step-card>` and `<ap-step-empty-state>`; delete dead SCSS.

**Steps**:

- [ ] **3.1** `package-assembly`: replace `__empty` and the loading banner with `<ap-step-empty-state>` (loading variant for the banner). Replace each artifact `<article>` with `<ap-step-card [icon]…[title]…[subtitle]…[state]="c.state">`; put progress bar in the default slot and Review/labels in `[actions]`.
- [ ] **3.2** `package-assembly`: delete migrated SCSS (card/empty/loading); keep progress-bar, status pill, footer/rerun styles that aren't in the shared card.
- [ ] **3.3** `finalize-package`: keep the `<app-card-shell>` wrapper. Replace `__empty` with `<ap-step-empty-state>`; replace summary + deliverable `<article>`s with `<ap-step-card>` (download/review buttons in `[actions]`).
- [ ] **3.4** `finalize-package`: delete migrated SCSS.
- [ ] **3.5** Run both step specs + Percy.

---

## Phase order and parallelism

**File-touch matrix:**

| File | P1 | P2 | P3 |
|------|----|----|----|
| `shared/**` (new components, `_ap-step.scss`, `index.ts`) | ✎ | | |
| `acquisition-pathways.module.ts` | ✎ | | |
| `requirements-record-step.*` | | ✎ | |
| `integrity-check-step.*` | | ✎ | |
| `finalize-package-step.*` | | | ✎ |
| `package-assembly-step.*` | | | ✎ |

**Parallelism:** Phases 2 and 3 both depend only on Phase 1 and touch disjoint files, so they can run in parallel once Phase 1 merges. For a clean stacked-PR series, sequence P1 → P2 → P3.

**Recommended order:** 1 → 2 → 3. Phase 1 is a pure addition that merges with zero risk (nothing consumes the components yet). Phase 2 (workbench, higher SCSS density) proves the scaffold + filter components under the harder case. Phase 3 (gallery) is then mechanical.

**Branches (stacked):** `{user}/AP-STEP-SHELL/phase-{N}` — Phase 1 off `main`, each later phase off the prior.

## Phase context summaries

**Phase 1** — Adds six (or five, if `ap-source-pill` is deferred) standalone presentational components under `pages/acquisition-pathways/shared/` plus a `_ap-step.scss` token/mixin partial, wires the barrel and module `imports`, and ships unit specs. Consumes nothing yet, so it merges risk-free. Components use signal `input()`/`output()` and content projection; they inject nothing beyond Material icon/tooltip. Gotcha: keep neutral BEM prefixes (`ap-step-scaffold`, `ap-filter-card`…) and do **not** force an `<app-card-shell>` wrapper — steps decide that. Public APIs are fixed by `AP-STEP-SHELL-contracts.md`; downstream phases match those signatures exactly.

**Phase 2** — Migrates the two workbench steps (`requirements-record`, `integrity-check`) onto `ap-step-scaffold` + `ap-filter-card` + `ap-filter-pill` + `ap-step-empty-state` (+ `ap-source-pill` if shipped), then deletes the now-dead SCSS from each step. Depends on Phase 1's component APIs. Gotcha: analytics stay in the step — supply `data-analytics-id` on the projected elements and keep `trackEvent` calls; the shared pills only emit `(pillClick)`/`(reset)`. Preserve step-specific markup (field rows, donut, findings). Percy is the visual-equivalence gate.

**Phase 3** — Migrates the two gallery steps (`finalize-package`, `package-assembly`) onto `ap-step-card` + `ap-step-empty-state` (loading variant for the assembly banner), then deletes dead SCSS. Depends only on Phase 1; disjoint from Phase 2. Gotcha: keep `finalize-package`'s `<app-card-shell>` wrapper; keep progress-bar/status styling that isn't part of the shared card; put footer buttons in the card's `[actions]` slot. Percy gate.

## Jira ticket

**Title:** Extract common Acquisition Pathways wizard step UI into shared presentational components

**Description:**
The four AP wizard steps (`requirements-record`, `integrity-check`, `package-assembly`, `finalize-package`) each re-implement a shared visual structure — sidebar+main layout, filter cards/pills, empty/loading states, artifact cards — with per-step BEM prefixes, producing ~2,259 lines of largely duplicated SCSS. Introduce a small set of standalone presentational components (`ap-step-scaffold`, `ap-step-empty-state`, `ap-filter-card`, `ap-filter-pill`, `ap-step-card`, optional `ap-source-pill`) plus a shared SCSS token partial, then migrate all four steps onto them. Presentational-only, content-projection based; no config-driven mega-component (the wizard host already owns step orchestration). Refactor only — visual output stays pixel-equivalent, guarded by Percy. Frontend-only; no API/DB changes.

**Acceptance criteria:**
- [ ] Shared components + `_ap-step.scss` exist under `pages/acquisition-pathways/shared/`, are exported from the barrel, registered in the module, and unit-tested (Phase 1).
- [ ] `requirements-record` and `integrity-check` render via `ap-step-scaffold` / `ap-filter-card` / `ap-filter-pill` / `ap-step-empty-state`, with their duplicated SCSS removed and analytics preserved (Phase 2).
- [ ] `finalize-package` and `package-assembly` render via `ap-step-card` / `ap-step-empty-state`, with their duplicated SCSS removed (Phase 3).
- [ ] `npm run lint`, `npm run test:ci`, and `npm run build` pass; Percy shows no unintended visual diffs.
