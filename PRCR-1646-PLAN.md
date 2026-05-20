# PRCR-1646 — Acquisition Pathways: Pathway Selection screen

## Problem statement

Build the **Pathway Selection** screen inside the existing
`acquisition-pathways` page module of `rohan_ui`. The screen shows three
ranked pathway recommendations (one per risk tier) generated from the
upstream Requirements Record output, and lets the user pick one before
moving on to Package Assembly.

The Requirements Record screen is not built yet, and the chat panel and
top-of-page progress bar shown in the design are explicitly out of scope.
This ticket therefore mocks the upstream input client-side so the data flow
is real (typed, observable, swappable) even though the producer is missing.

Reference design: `/Users/tim/Documents/code/UA-Acquisition-Pathways` (the
PM-authored prototype) and the screenshot attached to the ticket.

## Key architectural observations

1. The `acquisition-pathways` page module already exists at
   `src/app/pages/acquisition-pathways/` with a single landing route (`''`)
   wired to `AcquisitionPathwaysComponent`. That component is a search-bar
   placeholder unrelated to the new flow; its types file even comments that
   "the real shape will be defined in a follow-up ticket when the backend
   contract lands". This ticket replaces that placeholder type and adds a new
   sub-route — it does **not** remove the legacy landing page.
2. The route is already registered in `route-config.ts` as a lazy module
   under `/acquisition-pathways`. No top-level routing changes are needed.
3. `SharedComponentsModule` already exports `app-button`, `app-status-chip`,
   `app-page-wrapper`, and `app-card-shell` — enough to compose the screen
   without inventing new chrome. None of the shared cards (`app-card`,
   `app-card-shell`, `app-proposal-card`) match the pathway-card layout
   (badge + pill row + rationale + feature list + footer button), so a new
   presentational `app-pathway-card` is needed inside the page module.
4. State sharing in the prototype is RxJS `BehaviorSubject` services with
   `replaceAll` / `clear` / `generated`. `rohan_ui` follows the same RxJS
   pattern in services like `ProcurementWriterService`. We mirror that with
   a `PathwaySelectionService` provided in the page module (NOT root) so it
   resets when the user navigates away.
5. There is no backend endpoint for pathways yet (no matches for `pathway`
   in `rohan_api` or `rohan-python-api`). The `procurement-writer` controller
   uses `RfpPythonServerService` for AI work — that's the right home for a
   future `/acquisition-pathways/score` endpoint, but it is out of scope here.
6. The screenshot's pathway cards all use `Hybrid CPFF + FFP` as the
   contract type, while the prototype seed uses different values
   (`Firm Fixed Price (FFP)` / `T&M / Level of Effort (LOE)`). The mock
   data in this ticket follows the screenshot — not the prototype — because
   the user explicitly attached the screenshot as the source of truth.

## Assumptions

1. The Requirements Record output, when it lands, will be a typed object
   with at least an `id`, a free-text mission statement, and a structured
   field list. We mock that shape here so the swap is later mechanical.
2. The "Re-run analysis" button regenerates from the same mock for now.
   When the backend lands, it will become a real API call with no public
   surface change to `PathwaySelectionService`.
3. "Back" and "Assemble package" buttons render in the action row but
   navigate nowhere yet (target screens don't exist). Each component method
   is wired and unit-tested for the future router call but the body is a
   `TODO` comment.
4. We use `standalone: false` (NgModule architecture) to match the rest of
   `rohan_ui`.
5. The legacy `AcquisitionPathwaysComponent` (search bar placeholder) stays
   at the `''` route. A separate ticket can promote `pathway-selection` to
   the default or delete the legacy page.
6. Inline HTML in `rationale` is trusted because the data is hard-coded for
   PRCR-1646. When a backend lands, the API response must be sanitized
   server-side (Phase 1's contract spells this out) so the frontend's
   `[innerHTML]` use stays safe.

## Open questions

1. **Should `pathway-selection` be the default route under `acquisition-pathways`?**
   *Resolved (user 2026-05-20): No.* Keep the existing search-bar landing
   page at `''` and add `pathway-selection` as a sub-route — full URL
   `/acquisition-pathways/pathway-selection`. A follow-up ticket can
   promote `pathway-selection` to the default route once the rest of the
   module is built.
2. **Where does "Back" navigate?**
   *Default answer:* `acquisition-pathways/requirements-record` (does not
   exist yet — wire as a TODO with the route string in a constant).
3. **Where does "Assemble package" navigate?**
   *Default answer:* `acquisition-pathways/package-assembly` (does not exist
   yet — same TODO treatment).
4. **Should the Pathway Selection screen require an upstream Requirements
   Record id from the route, or self-mock it?**
   *Default answer: Self-mock for PRCR-1646.* The service exposes
   `generate(record?)` so the future caller (the upstream "Next" button on
   Requirements Record) can pass a real summary in. Phase 1 invokes the mock
   internally if no record is passed.
5. **Loading + empty states — fall back to the existing `app-skeleton`
   shared component, or a small bespoke banner?**
   *Default answer: Bespoke loading + empty banners inside the page,*
   matching the screenshot's spacing. They're styled inline and add no new
   shared components.
6. **Re-run analysis — should it animate (skeleton in cards) or just hide
   the cards?**
   *Default answer: Hide the cards and show a 1-line "Re-running…" banner.*
   Mock generation is synchronous so a flicker isn't great; we add a tiny
   `setTimeout` to keep the UX honest.

## Implementation phases

### Phase 1 — Types, mock data, and PathwaySelectionService [FRONTEND]

```phase-meta
phase: 1
title: Pathway types, mock data, and selection service
tags: [FRONTEND]
repo: rohan_ui
base_branch: base
depends_on: []
files:
  - src/app/pages/acquisition-pathways/types/acquisition-pathways.types.ts
  - src/app/pages/acquisition-pathways/constants/pathway-selection.constants.ts
  - src/app/pages/acquisition-pathways/constants/pathway-selection.mock.ts
  - src/app/pages/acquisition-pathways/services/pathway-selection.service.ts
  - src/app/pages/acquisition-pathways/services/pathway-selection.service.spec.ts
verification:
  - npm run lint
  - npm run test -- --include='src/app/pages/acquisition-pathways/services/pathway-selection.service.spec.ts'
contracts:
  - "1.1 AcquisitionPathway"
  - "1.2 AcquisitionPathwayTier"
  - "1.3 AcquisitionPathwayFeature"
  - "1.4 AcquisitionPathwayVehicleType"
  - "1.5 RequirementsRecordSummary"
  - "1.6 AcquisitionPathwayContractType"
  - "2.1 PATHWAY_SELECTION_MOCK_PATHWAYS"
  - "2.2 PATHWAY_SELECTION_MOCK_RECORD"
  - "3.1 PathwaySelectionService"
```

**Goal**: Establish the typed data plane and observable state for the
screen so subsequent phases only ship UI.

**Steps**:

- [ ] **1.1** Replace the placeholder `AcquisitionPathway` interface in
  `acquisition-pathways.types.ts` with the full set from contract sections
  1.1–1.6 (`AcquisitionPathway`, `AcquisitionPathwayTier`,
  `AcquisitionPathwayVehicleType`, `AcquisitionPathwayFeature`,
  `RequirementsRecordSummary`, `RequirementsRecordField`,
  `AcquisitionPathwayContractType`).
  - File: `src/app/pages/acquisition-pathways/types/acquisition-pathways.types.ts`
  - Remove the existing `id: string; name: string;` placeholder; the new
    `id` is typed as `AcquisitionPathwayTier`.
  - `AcquisitionPathwayContractType` is a TypeScript `enum` whose values are
    the human-readable pill labels and whose keys drive the SCSS variant
    map in Phase 2 (`pathway-card.component.scss`).
  - Drop the `/* istanbul ignore file */` directive — the types file no
    longer needs to be excluded from coverage now that real shapes live in it.

- [ ] **1.2** Add the page-level copy constants used by every layer.
  - File: `src/app/pages/acquisition-pathways/constants/pathway-selection.constants.ts`
  - Exports `PS_KICKER`, `PS_HEADING`, `PS_SUBHEAD`, `PS_BACK_LABEL`,
    `PS_RERUN_LABEL`, `PS_NEXT_LABEL`, `PS_NEXT_TOOLTIP_DISABLED`,
    `PS_LOADING_LABEL`, `PS_EMPTY_LABEL` exactly as in contract section 5.3.

- [ ] **1.3** Add the mock pathways and mock requirements-record.
  - File: `src/app/pages/acquisition-pathways/constants/pathway-selection.mock.ts`
  - Exports `PATHWAY_SELECTION_MOCK_PATHWAYS` (contract 2.1) and
    `PATHWAY_SELECTION_MOCK_RECORD` (contract 2.2).
  - Include a top-of-file JSDoc explaining this is mock data standing in for
    the future Requirements Record output, and that production will replace
    `PathwaySelectionService.generate()` with a real API call.

- [ ] **1.4** Implement `PathwaySelectionService` (contract 3.1).
  - File: `src/app/pages/acquisition-pathways/services/pathway-selection.service.ts`
  - Three private `BehaviorSubject`s: `_pathways$`, `_selectedTier$`,
    `_loading$`. Public `pathways$`, `selectedTier$`, `loading$`,
    `committed$` observables.
  - `generate(record = mock)`: emit `_loading$` → clone-and-emit pathways →
    auto-select the recommended tier if `_selectedTier$.value === null` →
    clear `_loading$`. Wrap the body in `setTimeout(..., 0)` so the
    `_loading$` toggle is observable in tests via `fakeAsync` + `tick()`.
  - `selectTier(tier)`: emit on `_selectedTier$`.
  - `reset()`: empty pathways list, null tier, clear loading.
  - Synchronous accessors `pathways()` / `selectedTier()` for component
    methods that don't need the stream.
  - Decorator: `@Injectable()` (page-scoped), no `providedIn`.

- [ ] **1.5** Unit-test the service.
  - File: `src/app/pages/acquisition-pathways/services/pathway-selection.service.spec.ts`
  - Cases:
    1. `generate()` populates `pathways$` with 3 cards.
    2. `generate()` auto-selects the recommended tier (`'low'`) on first call.
    3. `generate()` does NOT overwrite an explicit prior `selectTier`.
    4. `selectTier('medium')` updates `selectedTier$` and flips `committed$`
       to `true`.
    5. `reset()` empties pathways, nulls the tier, clears loading.
    6. `generate(custom)` accepts a custom `RequirementsRecordSummary` (smoke
       test that the signature is wired — body still returns mock).
    7. `loading$` flips `true → false` across a `generate()` call. Use
       `fakeAsync` + `tick()` per the workspace rule (prefer fakeAsync over
       setTimeout for async stream assertions).

### Phase 2 — Pathway card presentational component [FRONTEND]

```phase-meta
phase: 2
title: app-pathway-card presentational component
tags: [FRONTEND]
repo: rohan_ui
base_branch: phase-1
depends_on: [1]
files:
  - src/app/pages/acquisition-pathways/components/pathway-card/pathway-card.component.ts
  - src/app/pages/acquisition-pathways/components/pathway-card/pathway-card.component.html
  - src/app/pages/acquisition-pathways/components/pathway-card/pathway-card.component.scss
  - src/app/pages/acquisition-pathways/components/pathway-card/pathway-card.component.spec.ts
  - src/app/pages/acquisition-pathways/acquisition-pathways.module.ts
verification:
  - npm run lint
  - npm run test -- --include='src/app/pages/acquisition-pathways/components/pathway-card/pathway-card.component.spec.ts'
contracts:
  - "4.1 PathwayCardComponent"
```

**Goal**: A standalone-style (but `standalone: false`) dumb component that
renders one `AcquisitionPathway` and emits a `select` event.

**Steps**:

- [ ] **2.1** Create `PathwayCardComponent`.
  - File: `src/app/pages/acquisition-pathways/components/pathway-card/pathway-card.component.ts`
  - Use the `@Component` shape from contract section 4.1: `OnPush`,
    `standalone: false`, `pathway = input.required<AcquisitionPathway>()`,
    `selected = input<boolean>(false)`, `select = output<AcquisitionPathwayTier>()`.
  - Single method `onSelectClick()` emits `select` with `pathway().id`.

- [ ] **2.2** Build the template per contract section 4.2.
  - File: `src/app/pages/acquisition-pathways/components/pathway-card/pathway-card.component.html`
  - Reuse `app-status-chip` for the vehicle-type pill and the contract-type
    pill. Reuse `app-button` for the footer Select/Selected button.
  - Use Angular's modern template syntax (`@if` / `@for`) per the workspace
    rule (prefer latest Angular syntax).
  - Use `[innerHTML]` ONLY on `pathway().rationale`. All other bindings are
    plain text.
  - Wrap in a `<section>` with `role="group"` and an
    `[attr.aria-labelledby]` pointing to the unique pathway-name id
    (e.g. `pathway-card-title-{{ pathway().id }}`).

- [ ] **2.3** Style the card.
  - File: `src/app/pages/acquisition-pathways/components/pathway-card/pathway-card.component.scss`
  - Use module-scoped SCSS (no `::ng-deep`). Reuse existing palette tokens
    from `styles/index` for borders and text. Tier accent colors (low /
    medium / high) are a small palette inside this file.
  - Selected state: 2px teal border + light teal background tint.
  - Use `:host` for the card frame; do not bleed styles outside the
    component.

- [ ] **2.4** Register the component in the module.
  - File: `src/app/pages/acquisition-pathways/acquisition-pathways.module.ts`
  - Add `PathwayCardComponent` to `declarations`.
  - `SharedComponentsModule` is already imported; no additional imports
    needed (Material symbols use a global font).

- [ ] **2.5** Unit-test the component.
  - File: `src/app/pages/acquisition-pathways/components/pathway-card/pathway-card.component.spec.ts`
  - Cases:
    1. Renders the pathway name, vehicle, contract type, and tier label.
    2. Renders the recommended badge ONLY when `pathway().recommended` is set.
    3. Renders the correct vehicle-type chip text (`EXISTING VEHICLE` /
       `NEW VEHICLE`) per `vehicleType`.
    4. Renders one row per `pathway().features` entry with the right tone
       class.
    5. Footer button label is `'Select'` when `selected` is false and
       `'Selected'` when true.
    6. Clicking the footer button emits `select` with `pathway().id`.
    7. `aria-pressed` on the footer button reflects `selected`.

### Phase 3 — Pathway Selection page + routing [FRONTEND]

```phase-meta
phase: 3
title: Pathway Selection page, routing, and module wiring
tags: [FRONTEND]
repo: rohan_ui
base_branch: phase-2
depends_on: [1, 2]
files:
  - src/app/pages/acquisition-pathways/pages/pathway-selection/pathway-selection.component.ts
  - src/app/pages/acquisition-pathways/pages/pathway-selection/pathway-selection.component.html
  - src/app/pages/acquisition-pathways/pages/pathway-selection/pathway-selection.component.scss
  - src/app/pages/acquisition-pathways/pages/pathway-selection/pathway-selection.component.spec.ts
  - src/app/pages/acquisition-pathways/acquisition-pathways.module.ts
  - src/app/pages/acquisition-pathways/acquisition-pathways-routing.module.ts
verification:
  - npm run lint
  - npm run test -- --include='src/app/pages/acquisition-pathways/pages/pathway-selection/pathway-selection.component.spec.ts'
  - npm run lint -- --quiet
contracts:
  - "5.1 PathwaySelectionComponent"
  - "6.1 acquisition-pathways routing"
```

**Goal**: Render the full page (kicker, heading, three cards, action row),
wire it to the service, and expose it at
`/acquisition-pathways/pathway-selection`.

**Steps**:

- [ ] **3.1** Create `PathwaySelectionComponent` per contract section 5.1.
  - File: `src/app/pages/acquisition-pathways/pages/pathway-selection/pathway-selection.component.ts`
  - Inject `PathwaySelectionService`, `Router`, and `AppInsightsService`.
  - Public observables for the template: `pathways$`, `selectedTier$`,
    `loading$`, `committed$` (just re-exposed from the service).
  - Methods:
    - `onSelect(tier)` → `pathwaySvc.selectTier(tier)`.
    - `rerun()` → `pathwaySvc.reset(); pathwaySvc.generate();`
    - `back()` → `// TODO PRCR-1647 router.navigate([...PS_BACK_ROUTE])` —
      method body is a single-line comment for now; the test still asserts
      the method exists and is bound to the Back button.
    - `next()` → analogous TODO for `assemble-package`.
  - `ngOnInit` logs `'pageView'` with `{ page: 'Pathway Selection' }` and
    starts the page-time metric. If `pathwaySvc.pathways().length === 0` it
    calls `pathwaySvc.generate()`.
  - `ngOnDestroy` logs time spent and unsubscribes any local subs.

- [ ] **3.2** Build the page template.
  - File: `src/app/pages/acquisition-pathways/pages/pathway-selection/pathway-selection.component.html`
  - Wrap in `app-page-wrapper`.
  - Render kicker / heading / sub-head from the constants.
  - `@if (loading$ | async)` block shows a small bespoke loading banner
    (heading + sub-line, no spinner needed for mock data).
  - `@if ((pathways$ | async)?.length)` block renders three
    `<app-pathway-card>` instances inside a flex grid.
  - Action row: three `app-button` instances —
    - "Back" → `appearance="border-blue"`, `type="standard"`, calls `back()`.
    - "Re-run analysis" → `appearance="border-blue"`, `symbol="refresh"`,
      `[isDisabled]="loading$ | async"`.
    - "Assemble package" → `appearance="gradient"`, `symbol="build"`,
      `iconPosition="right"`, `[isDisabled]="!(committed$ | async)"`,
      `[matTooltip]="(committed$ | async) ? '' : PS_NEXT_TOOLTIP_DISABLED"`.
  - Use Angular modern template syntax (`@if` / `@for`).

- [ ] **3.3** Style the page.
  - File: `src/app/pages/acquisition-pathways/pages/pathway-selection/pathway-selection.component.scss`
  - Use existing `styles/index` tokens for max-width, header height, and
    spacing. Three-card grid with a 24px gap. Stack vertically on narrow
    viewports (CSS grid with `repeat(auto-fit, minmax(320px, 1fr))`).
  - Action row pinned to the bottom of the page content with a top border
    matching other workflow screens.

- [ ] **3.4** Register the page in the module.
  - File: `src/app/pages/acquisition-pathways/acquisition-pathways.module.ts`
  - Add `PathwaySelectionComponent` to `declarations`.
  - Provide `PathwaySelectionService` in the module's `providers` array
    (page-scoped — so navigation away tears it down).
  - Ensure `MatTooltipModule` is reachable (already re-exported via
    `SharedComponentsModule`).

- [ ] **3.5** Add the child route.
  - File: `src/app/pages/acquisition-pathways/acquisition-pathways-routing.module.ts`
  - Add `{ path: 'pathway-selection', component: PathwaySelectionComponent }`.
  - Keep `{ path: '', component: AcquisitionPathwaysComponent }` so the
    legacy landing page is untouched.

- [ ] **3.6** Unit-test the page.
  - File: `src/app/pages/acquisition-pathways/pages/pathway-selection/pathway-selection.component.spec.ts`
  - Stub `PathwaySelectionService` with a minimal class that exposes the
    same observables and spies on `generate`, `reset`, `selectTier`.
  - Stub `Router` with a `navigate` spy and `AppInsightsService` with the
    same stub the legacy spec uses (`AppInsightsStubService`).
  - Cases:
    1. `ngOnInit` calls `pathwaySvc.generate()` when pathways are empty.
    2. `ngOnInit` does NOT call `generate()` if pathways are already loaded.
    3. `ngOnInit` logs the `pageView` analytics event with
       `{ page: 'Pathway Selection' }`.
    4. Renders three `app-pathway-card` instances when the service emits
       three pathways.
    5. The "Assemble package" button is `disabled` while `committed$` is
       false and enabled once a tier is selected.
    6. Clicking "Re-run analysis" calls `reset` then `generate`.
    7. `(select)` from a card calls `pathwaySvc.selectTier` with the
       emitted tier id.
    8. `back()` and `next()` exist and are bound to their buttons (smoke
       test — body is a TODO).
    9. `ngOnDestroy` logs time spent and unsubscribes.

## Phase order and parallelism

### File-touch matrix

| Phase | Files                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| ----- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1     | `types/acquisition-pathways.types.ts`, `constants/pathway-selection.constants.ts`, `constants/pathway-selection.mock.ts`, `services/pathway-selection.service.ts`, `services/pathway-selection.service.spec.ts`                                                                                                                                                                                                                                                                                                                                                                              |
| 2     | `components/pathway-card/*` (4 files), `acquisition-pathways.module.ts` (declaration only)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| 3     | `pages/pathway-selection/*` (4 files), `acquisition-pathways.module.ts` (declaration + providers), `acquisition-pathways-routing.module.ts`                                                                                                                                                                                                                                                                                                                                                                                                                                                  |

### Parallelism options

- **Phase 1 must come first.** Phases 2 and 3 both depend on the types,
  constants, and (for Phase 3) the service from Phase 1.
- Phases 2 and 3 could in principle be developed in parallel because the
  card component depends only on the type contracts, not on the page or the
  service. In practice they touch the same `acquisition-pathways.module.ts`
  declarations array, so two parallel branches will conflict on the module
  file. **Recommended order: 1 → 2 → 3.**

### Recommended sequential order (rationale)

1. **Phase 1** — types & service first so Phase 2's component compiles
   against the real `AcquisitionPathway` shape and Phase 3's spec can
   stub a service with the same surface.
2. **Phase 2** — card alone is easy to review (no service injection, no
   router) and lands the visually-loudest piece in isolation.
3. **Phase 3** — page composes the card, wires the service, and adds the
   route. Reviewers can see the full screen without having to mentally
   reconstruct the missing inputs.

## Phase context summaries

### Phase 1 — Pathway types, mock data, and selection service

Replaces the placeholder `AcquisitionPathway` interface in the page module
with the full set of types from contract sections 1.1–1.6 (pathway shape,
tier and vehicle unions, feature row, the
`AcquisitionPathwayContractType` enum used by the contract-type pill, and a
best-guess `RequirementsRecordSummary`). Adds two constants files: page
copy strings (headings, button labels) and the static mock pathway list +
mock requirements-record. Lands a `PathwaySelectionService` (contract 3.1) — a
non-root-scoped RxJS service with observable streams for pathways, the
selected tier, loading state, and a derived `committed$`. Methods:
`generate(record?)`, `selectTier(tier)`, `reset()`. The mock generation is
intentionally synchronous-with-microtask-delay so streams are testable
under `fakeAsync`. Service spec covers happy path, auto-select, explicit
selection, reset, and the loading toggle. No UI yet — this phase produces
zero visible change but everything compiles and is unit-tested. Watch out
for: NOT marking `PathwaySelectionService` as `providedIn: 'root'` (it
must reset on navigation) and NOT removing the `/* istanbul ignore file */`
directive without re-checking coverage thresholds.

### Phase 2 — Pathway card presentational component

Adds `app-pathway-card` under `components/pathway-card/` — a small
`OnPush` component whose only inputs are the `AcquisitionPathway` and a
`selected` boolean, and whose only output is `select`. Composition reuses
`app-status-chip` (vehicle-type and contract-type pills) and `app-button`
(footer). The template renders, top-to-bottom: optional `BEST BALANCED`
badge, vehicle-type pill, risk-tier pill, name + vehicle subtitle,
contract-type row, rationale (the only `[innerHTML]` binding), feature
list (icon + text + tone class), and footer button whose label flips from
"Select" to "Selected". The contract-type pill text comes from the
`AcquisitionPathwayContractType` enum value; its color variant comes from
a small SCSS map keyed by the enum key (e.g. `FFP`, `HybridCpffFfp`) so
adding a new enum entry without updating the SCSS lights up the typescript
exhaustive check rather than silently default-styling. Styling lives in
module-scoped SCSS that uses the existing palette tokens; tier accent
colors are a small per-tier palette. Module declaration goes in
`acquisition-pathways.module.ts`. Spec covers text rendering, conditional
badge, chip text by `vehicleType`, feature tone classes, footer label,
click emission, and `aria-pressed`. Watch out for: keeping `[innerHTML]`
confined to the rationale and treating all other inputs as plain text.

### Phase 3 — Pathway Selection page, routing, and module wiring

Adds `app-pathway-selection` at
`pages/pathway-selection/pathway-selection.component.*`. The page wraps
in `app-page-wrapper`, renders kicker / heading / sub-head from constants,
shows a bespoke loading banner while the service is generating, renders
three `app-pathway-card` instances bound to `pathways$`, and a three-button
action row (Back / Re-run analysis / Assemble package). The "Assemble
package" button is gated on `committed$` and shows a tooltip when
disabled. `ngOnInit` calls `pathwaySvc.generate()` only when the list is
empty (so a re-mount after a back-and-forth doesn't blow away an explicit
selection). `ngOnInit` and `ngOnDestroy` emit AppInsights events
mirroring the legacy `AcquisitionPathwaysComponent`. `back()` and `next()`
methods are stubbed with TODO comments — the route targets exist as
constants but there are no destination components yet. Module wiring adds
`PathwaySelectionComponent` to `declarations` and `PathwaySelectionService`
to `providers`. Routing adds `{ path: 'pathway-selection', component: ... }`
alongside the existing `''` route. Spec stubs the service, router, and
AppInsights and covers init/destroy semantics, conditional generate,
button gating, click handlers, and template rendering. Watch out for:
making `PathwaySelectionService` page-scoped (provided in
`AcquisitionPathwaysModule.providers`, NOT `providedIn: 'root'`) so
navigating away clears state.

## Jira ticket

**PRCR-1646 — Build Pathway Selection screen in Acquisition Pathways**

**Description**

Implement the Pathway Selection screen inside the Acquisition Pathways
module of `rohan_ui`, mirroring the design from the
`UA-Acquisition-Pathways` prototype and the attached screenshot. The screen
shows three ranked pathway recommendations (low / medium / high risk), lets
the user pick one, and exposes Back / Re-run analysis / Assemble package
actions.

The Requirements Record screen (the upstream producer of the input data) is
not built yet, so this ticket mocks the upstream input client-side. The
chat panel and progress stepper visible in the design are explicitly out
of scope.

Reuse `app-button`, `app-status-chip`, and `app-page-wrapper` from
`SharedComponentsModule` rather than duplicating chrome. A new presentational
`app-pathway-card` lives inside the page module. State is held in a
page-scoped `PathwaySelectionService` (RxJS `BehaviorSubject` pattern,
matching `ProcurementWriterService`).

The `acquisition-pathways` route stays where it is in `route-config.ts`.
The new screen is a child route at
`/acquisition-pathways/pathway-selection`. The legacy search-bar landing
page at `''` is left untouched and is the target of a separate
follow-up cleanup ticket.

**Acceptance criteria**

- [ ] Replace the placeholder `AcquisitionPathway` interface with the typed
      pathway / tier / feature / vehicle / requirements-record summary
      shapes (and the `AcquisitionPathwayContractType` enum) from contract
      sections 1.1–1.6; add a `PathwaySelectionService` (contract 3.1) with
      `pathways$`, `selectedTier$`, `loading$`, `committed$`, `generate`,
      `selectTier`, and `reset`; service spec passes the seven cases in
      step 1.5.
- [ ] Add `app-pathway-card` (contract 4.1) under
      `components/pathway-card/` reusing `app-status-chip` and `app-button`;
      the contract-type pill text comes from the
      `AcquisitionPathwayContractType` enum value and the pill color comes
      from a SCSS map keyed by the enum key; component spec passes the
      seven cases in step 2.5.
- [ ] Add `PathwaySelectionComponent` (contract 5.1) at
      `pages/pathway-selection/`, register the route at
      `/acquisition-pathways/pathway-selection`, and provide
      `PathwaySelectionService` page-scoped; component spec passes the nine
      cases in step 3.6.

## Branching convention

Phases produce stacked branches following the workspace convention:

```
tim/PRCR-1646/phase-{N}
```

- Phase 1 branches off the `acquisition-pathways` working trunk (typically
  `develop`).
- Each subsequent phase branches off the previous phase's branch.
- A single feature worktree at `../rohan_ui-PRCR-1646` (per
  `WORKTREES.md`) holds the work. The plan does not create branches — it
  only references them in `base_branch` metadata.
