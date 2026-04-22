# PRCR-1544 — Delete tooltip on tag remove button

**Ticket**: [PRCR-1544](https://rohirrim.atlassian.net/browse/PRCR-1544)
**Type**: Story
**Repo(s)**: `rohan_ui`

## Problem statement

On the Compliance page the tag "dots" (added by PRCR-1519) reveal an `×` remove control on hover. Hovering the `×` currently shows no tooltip. Design calls for a "Delete" tooltip when the pointer is on the `×`.

The same `TagChipComponent` is rendered as a labeled pill in Proposal Writer / Template Generator. The `×` in that labeled variant must also get the "Delete" tooltip.

## Key architectural observations

- `TagChipComponent` (`src/app/shared-components/document-shredding/components/document-tagging/tag-chip/`) owns the single `<button class="tag-chip__remove">` used in both variants. Adding `matTooltip` to that one button covers both dot and labeled cases.
- PRCR-1519 is merged. `tag-chip.component.html` now has two `<button class="tag-chip__remove">` — one in the `@if (displayAsDot)` dot branch, one in the `@else` labeled-chip branch. Both need `matTooltip="Delete"`.
- The dot variant's remove button is hidden until `:hover` / `:focus-within` on the chip root. The tooltip only has to appear when the button is already visible, so no extra hover-chain logic is required — `matTooltip` attaches directly to the button.
- `MatTooltipModule` is already imported in `SharedComponentsModule` (`src/app/shared-components/shared-components.module.ts:26,154`), which declares `TagChipComponent`. No module wiring needed.
- The `removeDisabled` state already disables the button. `matTooltip` on a disabled host element is still rendered by Material; acceptable because the dimmed-pending state is brief and the tooltip text is still truthful.

## Assumptions

1. Tooltip text is the literal string `"Delete"` — matches ticket wording.
2. No positioning / delay overrides needed; Material defaults (below, 500 ms show delay) match existing app conventions.
3. PRCR-1519 is already merged to `main` — both dot and labeled variants exist in `tag-chip.component.html`.

## Open questions

| # | Question | Default |
|---|----------|---------|
| 1 | Should the tooltip also appear on focus (keyboard users)? | Yes — `matTooltip` shows on focus by default; keep default. |
| 2 | Localize "Delete"? | No — other strings in this component (e.g. `'Mark Highlight As:'`) are hard-coded. Out of scope. |

## Implementation phases

### Phase 1 — matTooltip on tag-chip remove button [FRONTEND]

```phase-meta
phase: 1
title: Add Delete tooltip to tag-chip remove button
tags: [FRONTEND]
repo: rohan_ui
base_branch: base
depends_on: []
files:
  - src/app/shared-components/document-shredding/components/document-tagging/tag-chip/tag-chip.component.html
  - src/app/shared-components/document-shredding/components/document-tagging/tag-chip/tag-chip.component.spec.ts
contracts:
  - "1.1 TagChipComponent remove button tooltip"
verification:
  - npm run lint
  - npm run test -- --include='**/tag-chip.component.spec.ts'
```

**Goal**: Add `matTooltip="Delete"` to the `<button class="tag-chip__remove">` inside `TagChipComponent` so a "Delete" tooltip appears on hover/focus in both the dot and labeled variants.

**Steps**:

- [ ] **1.1** In `tag-chip.component.html`, add `matTooltip="Delete"` to **both** `<button class="tag-chip__remove">` elements:
  - The button inside the `@if (displayAsDot)` branch (dot variant).
  - The button inside the `@else` branch with `matChipRemove` (labeled variant).
  - Keep existing attributes (`matChipRemove`, `[disabled]="removeDisabled"`, `[attr.aria-label]`, `(click)`/`(removed)`) unchanged.
  - File: `tag-chip/tag-chip.component.html`
- [ ] **1.2** Update `tag-chip.component.spec.ts`:
  - Add `MatTooltipModule` to the `TestBed` imports.
  - New test (labeled variant, existing default): query `.tag-chip__remove`, resolve the `MatTooltip` directive from its injector, assert `tooltip.message === 'Delete'`.
  - New test (dot variant): set `component.displayAsDot = true; fixture.detectChanges();` then repeat the assertion on the dot-branch remove button.
- [ ] **1.3** Smoke test in Chrome:
  - Compliance page: highlight text, create a tag, hover the dot, then hover the `×` → "Delete" tooltip appears.
  - Proposal Writer: hover the `×` on a labeled tag chip → "Delete" tooltip appears.

## Phase order and parallelism

### File-touch matrix

| File | Phase 1 |
|------|:-:|
| `tag-chip.component.html` | X |
| `tag-chip.component.spec.ts` | X |

### Parallelism

Single-phase change. Branches off `main`. PRCR-1519 already merged — both template branches exist and get the attribute.

### Branching convention

```
tim/PRCR-1544/phase-1   # off main
```

## Phase context summaries

### Phase 1

Adds `matTooltip="Delete"` to **both** `<button class="tag-chip__remove">` elements in `tag-chip.component.html` — the dot-variant button in the `@if (displayAsDot)` branch (Compliance) and the labeled-variant button in the `@else` branch (Proposal Writer / Template Generator). `MatTooltipModule` is already in `SharedComponentsModule`, so no module wiring. Unit test adds `MatTooltipModule` to its TestBed and asserts the `MatTooltip` directive on each remove button has `message === 'Delete'`, once with `displayAsDot = false` (default) and once after flipping to `true`. Gotcha: `matTooltip` still renders on a disabled host; that's the intended behavior during the brief pending-delete state.

## Jira ticket

**Title**: `[Compliance] Add "Delete" tooltip on tag chip remove button`

**Description**:
On the Compliance page, hovering a floating tag dot reveals an `×` remove control. Hovering the `×` should show a tooltip reading "Delete". The same `×` is present on labeled tag chips in Proposal Writer / Template Generator and needs the same tooltip. Implemented by adding `matTooltip="Delete"` on the existing `<button class="tag-chip__remove">` in `TagChipComponent`.

**Acceptance criteria**:
- [ ] Phase 1 — `TagChipComponent` remove button shows a "Delete" tooltip on hover and on keyboard focus in both dot and labeled variants. Unit test asserts the tooltip directive has message `"Delete"`. Lint clean.
- [ ] Manual: Compliance tag dot → hover `×` → tooltip "Delete"; Proposal Writer labeled chip → hover `×` → tooltip "Delete".
