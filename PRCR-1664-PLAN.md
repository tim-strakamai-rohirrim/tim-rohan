# PRCR-1664 — Restyle the Requirements Record wizard step to match Pathway Selection

> ## Implementation update (post-review)
>
> The implemented design **diverged from the original plan** below during visual
> review. The plan targeted the **Pathway Selection** reference (open, elevated,
> token-driven cards). The final, shipped design (PR #2133, branch
> `tim/PRCR-1664/phase-1`) is a **flat, table-style list on a full-bleed gray
> section**:
>
> - Field cards were replaced with **divider-separated rows inside a single
>   white "table" panel**; the status bar is a gray (`$content-background-2`)
>   header strip atop that panel; field labels are small/uppercase/muted; the
>   editing state uses a subtle row tint instead of a teal border ring.
> - The sidebar Filters/Sources remain white card panels.
> - The whole step sits on a **full-bleed gray section** so the white panels
>   read as distinct surfaces.
>
> **Scope expanded beyond the original 3 files.** Delivering the full-bleed gray
> section required an **opt-in** mechanism in the shared wizard:
>
> - `wizard.component.ts` — new optional `StepConfig.fullBleedBackground` flag.
> - `wizard.component.html` / `wizard.component.scss` — paint `.main-step-panel`
>   gray when the flag is set.
> - `src/styles/mat-stepper-overrides.scss` — a `:has()`-scoped rule extends the
>   gray over the Material content container's 24px bottom padding, only for the
>   currently-active full-bleed step.
> - `acquisition-pathways-wizard.component.ts` — enable the flag for the
>   Requirements Record step (`index === 0`) only.
>
> All wizard/global additions are **gated on the opt-in flag / `--bleed` class**,
> so every other step and stepper is visually unchanged. The numbered stepper
> header row was intentionally left out of the gray. This change remains
> CSS/markup-only — no behavior, data, API, or public component contract changes.
> The acceptance criteria and file-touch matrix below predate this update; see
> PR #2133 for the as-shipped details.

## Problem statement

The **Requirements Record** step of the Acquisition Pathways wizard
(`/acquisition-pathways/wizard/requirements-record`) is already functional but its
visual styling is inconsistent with the rest of the wizard. The **Pathway
Selection** step (step 2) is the agreed-upon visual reference — it uses an open,
elevated, token-driven card layout, while Requirements Record is wrapped in an
`app-card-shell` "box", uses a different border token, smaller radii, and no card
elevation.

This ticket updates **only the visual styling** of the Requirements Record step so
it matches the Pathway Selection reference. There are **no behavioral, data, API,
or DB changes**. The global app chrome (left nav + right chat panel) is explicitly
out of scope. The Requirements Record's own internal **Filters / Sources sidebar
is in scope** and should be restyled to match.

## Key architectural observations

How the relevant areas work today:

- **Wizard chrome already renders a header.** `WizardComponent`
  (`src/app/shared-components/wizard/wizard.component.html`) renders, above every
  step body, the step `instructions` and `subContext` from `AP_WIZARD_STEPS`
  (`constants/acquisition-pathways.constants.ts`). The "STEP 1 · …" kicker and the
  "One source of truth for every downstream artifact." line in the screenshot come
  from this wizard chrome — **not** from the step component. The step body must
  therefore **not** add its own kicker/H1/subhead (that would duplicate the
  header). This matches the user decision.
- **Requirements Record is the only step wrapped in `app-card-shell`.** Its
  template top-level is `<app-card-shell headerLabel="Requirements Record">`
  (`requirements-record-step.component.html`), which paints a bordered card with a
  gradient divider + duplicated title. Pathway Selection has **no** card-shell — it
  renders an open `.pathway-selection-page` container directly.
- **Token / import mismatch.** Requirements Record SCSS does
  `@use 'styles/variables' as *;` and styles surfaces with
  `border: 1px solid $primary-border-color; border-radius: 8px;` and **no**
  `box-shadow`. The reference (`pathway-selection.component.scss`,
  `pathway-card.component.scss`) does `@use 'styles/index' as *;` and styles
  surfaces with `border: 1px solid $activity-border; border-radius: 12px;
  box-shadow: $card-shadow;`, plus a hover-lift on interactive cards.
- **Page container pattern (reference).** `.pathway-selection-page` is a centered
  `max-width: $content-width` flex column with `padding: 0 30px`; the content block
  is a `gap: 24px` flex column with `padding: 32px 0 24px`. Cards live in a
  responsive `repeat(auto-fit, minmax(min(320px, 100%), 1fr))` grid.
- **Shared `app-button` is the reference control.** Pathway Selection / pathway
  cards use `app-button` (e.g. `appearance="border-blue"`, `symbol="refresh"`).
  Requirements Record uses hand-rolled `.ap-rr__btn` buttons. `app-button` is
  exported by `SharedComponentsModule`, which `AcquisitionPathwaysModule` already
  imports, so it is available with no new imports.
- **Component public API is stable.** `RequirementsRecordStepComponent` exposes
  `@Input() notes` and `@Input() record` (both `WritableSignal`s) and implements the
  `StepComponent` contract (`updateState`, `disableNextButton`). The wizard wires
  these in `AcquisitionPathwaysWizardComponent`. None of this changes — only the
  template markup/classes and SCSS change.
- **No existing spec.** There is currently no
  `requirements-record-step.component.spec.ts`.

## Assumptions

- The change is **CSS/markup only**. All signals, computed values, event handlers,
  analytics `data-analytics-id` attributes, `matTooltip`s, and `testid`s are
  preserved (analytics/tooltips re-applied to the new `app-button` elements via
  `[attr.data-analytics-id]` / `[matTooltip]`).
- Removing `app-card-shell` will not break layout because the wizard's
  `.main-step-content` already provides the outer scroll/padding context (same as
  Pathway Selection embedded mode).
- Dark mode keeps working automatically because all colors come from CSS-variable
  design tokens (`$content-background`, `$activity-border`, `$main-text`, etc.).
- The tag/status accent colors (extracted / inferred / needs / user) are part of
  the screen's meaning and are **kept**; only the surface chrome (borders, radii,
  shadow, container) is aligned to the reference.
- The wizard's bottom Next/Previous button row is owned by the wizard, not this
  step, and is untouched.

## Open questions

| # | Question | Proposed default |
|---|----------|------------------|
| 1 | Should the static field cards get the same hover-lift (`translateY(-4px)`) as `app-pathway-card`? | **No** — field cards are editable content, not selectable options. Apply `$card-shadow` + 12px radius for consistency, but reserve hover-lift/pointer affordance for genuinely clickable elements (source items, source pills). Keeps the "workbench" feel while matching elevation. |
| 2 | Replace the hand-rolled `.ap-rr__btn` add/cancel/confirm buttons with shared `app-button`? | **Yes** — matches the reference's use of `app-button` and removes bespoke button SCSS. Map: primary → `appearance="gradient"`, secondary → `appearance="border-blue"` (or `solid`), preserving analytics ids + labels. If `app-button`'s API can't cleanly express the inline icon+label used today, fall back to keeping `.ap-rr__btn` but restyle to reference radii/tokens, and note it. |
| 3 | Should the responsive breakpoint (`max-width: 960px`) for the sidebar→single-column collapse stay? | **Yes** — keep the existing responsive collapse; just align spacing/gap to the reference's 24px rhythm. |

## Implementation phases

### Phase 1 — Restyle Requirements Record step to match Pathway Selection [FRONTEND]

```phase-meta
phase: 1
title: Restyle Requirements Record step to Pathway Selection reference
tags: [FRONTEND]
repo: rohan_ui
base_branch: base
depends_on: []
files:
  - src/app/pages/acquisition-pathways/steps/requirements-record-step/requirements-record-step.component.html
  - src/app/pages/acquisition-pathways/steps/requirements-record-step/requirements-record-step.component.scss
  - src/app/pages/acquisition-pathways/steps/requirements-record-step/requirements-record-step.component.spec.ts
contracts:
  - "1. Visual contract (design tokens + surface treatment)"
  - "2. Structural template changes"
  - "3. Component public API (unchanged — for reference)"
verification:
  - npm run lint
  - npm run test:ci
  - npm run build
```

**Goal**: Make the Requirements Record step visually match the Pathway Selection
reference (open layout, elevated token-driven cards) without changing any behavior,
data, or public API.

**Steps**:

- [ ] **1.1** Remove the `app-card-shell` wrapper from the template.
  - Replace `<app-card-shell headerLabel="Requirements Record">…</app-card-shell>`
    with an open page container modeled on `.pathway-selection-page`.
  - Do **not** add an in-body kicker/H1/subhead — the wizard renders the header.
  - File: `…/requirements-record-step.component.html`
- [ ] **1.2** Introduce a reference-aligned page container + content wrapper.
  - New root `.ap-rr-page` (centered, `max-width: $content-width`,
    `padding: 0 30px`, `box-sizing: border-box`, `width: 100%`).
  - Content block keeps the existing `280px 1fr` grid (`.ap-rr`) but aligns
    vertical rhythm to the reference (`gap: 24px`, top padding consistent with
    `.pathway-selection-content`).
  - File: `…/requirements-record-step.component.scss`
- [ ] **1.3** Switch the SCSS import from `@use 'styles/variables' as *;` to
  `@use 'styles/index' as *;` (variables + mixins), matching the reference files.
  - File: `…/requirements-record-step.component.scss`
- [ ] **1.4** Align all surface chrome to the reference card treatment.
  - Sidebar cards (`.ap-rr__card`), field cards (`.ap-rr__field`), status bar
    (`.ap-rr__statusbar`), empty state, and add-row: change
    `border-color: $primary-border-color` → `$activity-border`, `border-radius: 8px`
    → `12px`, and add `box-shadow: $card-shadow`.
  - Keep tag/source accent colors (extracted/inferred/needs/user) unchanged.
  - File: `…/requirements-record-step.component.scss`
- [ ] **1.5** Apply hover affordance only to genuinely interactive cards.
  - Source items (`.ap-rr__source-item`) and clickable source pills keep/refine a
    hover state consistent with the reference (border → `$teal`, subtle bg). Do
    **not** add `translateY` hover-lift to static editable field cards (Open
    question #1).
  - File: `…/requirements-record-step.component.scss`
- [ ] **1.6** Replace hand-rolled `.ap-rr__btn` controls with shared `app-button`
  (Open question #2).
  - Add/Cancel/Confirm buttons → `app-button` with matching labels, icons
    (`symbol`/`icon`), `appearance` (primary → `gradient`, secondary →
    `border-blue`), and re-applied `[attr.data-analytics-id]` + `(buttonClick)`.
  - Remove now-dead `.ap-rr__btn*` SCSS.
  - If `app-button` can't cleanly reproduce a control, keep `.ap-rr__btn` but
    restyle to reference tokens/radii and note the deviation in the PR.
  - File: `…/requirements-record-step.component.html` (+ `.scss`)
- [ ] **1.7** Clean up obsolete styles.
  - Remove the `--card-shell-width` `:host` override (no longer needed) and set
    `:host { display: block; width: 100%; }` like the reference.
  - Remove any rules made dead by the card-shell removal.
  - File: `…/requirements-record-step.component.scss`
- [ ] **1.8** Verify responsive behavior is preserved.
  - Keep the `@media (max-width: 960px)` sidebar→single-column collapse; align gaps
    to 24px (Open question #3).
  - File: `…/requirements-record-step.component.scss`
- [ ] **1.9** Add a light smoke spec for the step.
  - New `requirements-record-step.component.spec.ts`: render the component with
    stub `notes`/`record` signals; assert (a) no `app-card-shell` host is rendered,
    (b) the root `.ap-rr-page` exists, (c) the status bar + at least one field card
    render for a seeded record. Use `ChangeDetectionStrategy.OnPush`-friendly
    `fixture.detectChanges()` and existing test utilities.
  - File: `…/requirements-record-step.component.spec.ts`
- [ ] **1.10** Manual visual QA against the reference.
  - Compare side-by-side with Pathway Selection at desktop + narrow widths, in both
    light and dark themes. Confirm no duplicate header, no card-shell box, elevated
    cards, consistent 24px rhythm.

## Phase order and parallelism

Single phase — no ordering or parallelism concerns.

### File-touch matrix

| File | Phase 1 |
|------|:------:|
| `requirements-record-step.component.html` | ✅ |
| `requirements-record-step.component.scss` | ✅ |
| `requirements-record-step.component.spec.ts` (new) | ✅ |

> **As-shipped (post-review) additions** — see the implementation update at the
> top. The following files were also modified to add the opt-in full-bleed step
> background:
>
> | File | Change |
> |------|--------|
> | `shared-components/wizard/wizard.component.ts` | Add optional `StepConfig.fullBleedBackground` flag |
> | `shared-components/wizard/wizard.component.html` | Bind `main-step-panel--bleed` when the flag is set |
> | `shared-components/wizard/wizard.component.scss` | Paint `.main-step-panel--bleed` gray |
> | `pages/acquisition-pathways/wizard/acquisition-pathways-wizard.component.ts` | Enable the flag for the Requirements Record step only |
> | `styles/mat-stepper-overrides.scss` | `:has()`-scoped gray over the stepper content bottom padding |

The original plan modified no other files. `requirements-record-step.component.ts`,
`requirements-record.types.ts`, `requirements-record.seed.ts`, and the shared
`card-shell` component are **not** touched. (The shared `wizard` was originally
out of scope but was extended in an opt-in, backward-compatible way per the
implementation update above.)

## Phase context summaries

**Phase 1** — Pure visual restyle of the Requirements Record wizard step to match
the Pathway Selection reference. Removes the `app-card-shell` wrapper, introduces a
centered `max-width: $content-width` page container, switches the SCSS import to
`styles/index`, and aligns all card surfaces to the reference treatment
(`$activity-border`, 12px radius, `$card-shadow`), with hover affordance limited to
interactive elements. Hand-rolled buttons are replaced with shared `app-button`.
Depends on nothing. Gotchas: do **not** add an in-body header (the wizard already
renders one); preserve every `data-analytics-id`, `matTooltip`, `testid`, signal,
and event handler; keep tag/status accent colors and the 960px responsive collapse.
Behavior, data, public `@Input`s, and the `StepComponent` contract are unchanged.

## Jira ticket

**Title**: PRCR-1664 — Restyle the Requirements Record wizard step to match Pathway
Selection

**Description**:
The Requirements Record step of the Acquisition Pathways wizard is functional but
visually inconsistent with the rest of the wizard. Update its styling to match the
agreed reference (the Pathway Selection step): remove the `app-card-shell` wrapper
in favor of an open, centered page layout; align card surfaces to the shared design
tokens (`$activity-border`, 12px radius, `$card-shadow`); switch the SCSS import to
`styles/index`; and replace hand-rolled buttons with the shared `app-button`. This
is a CSS/markup-only change — no behavioral, data, API, or DB changes. The global
nav and chat panel are out of scope; the step's internal Filters/Sources sidebar is
in scope. The wizard's existing step header is relied upon (no duplicate in-body
header).

**Acceptance criteria**:
- [ ] The Requirements Record step renders without an `app-card-shell` wrapper, in
  an open centered layout matching Pathway Selection.
- [ ] Card surfaces (sidebar cards, field cards, status bar, add-row) use
  `$activity-border`, 12px radius, and `$card-shadow`; the SCSS uses
  `@use 'styles/index'`.
- [ ] Interactive elements (source items / clickable source pills) have a hover
  affordance consistent with the reference; static field cards do not gain a
  hover-lift.
- [ ] Hand-rolled buttons are replaced with `app-button` (or restyled to reference
  tokens if `app-button` can't express a control), with all analytics ids and
  tooltips preserved.
- [ ] No in-body kicker/H1/subhead is added; the wizard header is the only header.
- [ ] All existing behavior, signals, `@Input`s, event handlers, `testid`s, and
  `data-analytics-id`s are unchanged; the screen works in light and dark themes and
  at narrow widths.
- [ ] `npm run lint`, `npm run test:ci`, and `npm run build` pass.

## Branching convention

Phases produce stacked branches named `{user}/{ticket}/phase-{N}`:

- Phase 1 branches off the starting branch (e.g. `develop`/`main`):
  `tim/PRCR-1664/phase-1`.

This plan does not create branches — it only references them in `base_branch`.

## Tech stack reference

| Layer | Stack |
|-------|-------|
| Frontend | Angular 20+ (signals, zoneless, standalone:false module component), SCSS, Karma/Jasmine |
| Design tokens | `src/styles/variables.scss` (CSS-variable tokens), `src/styles/_index.scss`, `src/styles/mixins.scss` |
| Shared UI | `app-button`, `app-card-shell` (being removed here), `WizardComponent` |
