# PRCR-1517 — Bidirectional tag↔item selection in Compliance

Jira: https://rohirrim.atlassian.net/browse/PRCR-1517
Type: Bug
Repo(s): `rohan_ui-parent/rohan_ui`

## Problem statement

In the Compliance detail view (`ComplianceListCreatorComponent`), the left pane shows compliance item cards and the right pane shows the source document with inline tags. Clicking a **card on the left** scrolls the right pane's highlight into view (works). Clicking a **tag on the right** does **not** do the reverse — the left pane's matching card is neither selected nor scrolled into view. Fix by making tag clicks emit an item-selection event that flows up to `ComplianceListCreatorComponent.onItemSelected`, and add a scroll-into-view effect in `ComplianceItemsPanelComponent` so the selected card becomes visible.

## Key architectural observations

- `InlineTag.id` rendered by `TagLayerComponent` equals the compliance item id. Already established in `DocumentViewerPanelComponent.inlineTags` (line 81): `id: item.id`.
- Selection flows through `ComplianceStateService.setSelectedItem(itemId)` which updates `_selectedItemId` and `_selectedDocumentId` signals. Both panes already read `selectedItemId` as an input.
- Right-pane scroll already driven by an `effect()` on `selectedItemId` in `DocumentViewerPanelComponent` (lines 97–108) that calls `scrollToSelectedHighlight()`.
- Left-pane (`ComplianceItemsPanelComponent`) receives `selectedItemId` and toggles `[isSelected]` on cards, but has **no scroll-into-view logic** today.
- Tag elements in `tag-layer.component.html` already carry `[attr.data-tag-id]="tag.id"` but no click handler. `app-tag-chip` has only a `remove` output. `DocShellComponent` has a hover-sync path via `data-tag-id` but not a click path.
- `TagLayerComponent` / `DocShellComponent` live under `shared-components/document-shredding/` and are reused outside compliance. Any new output must be opt-in (consumers that don't bind it see no behaviour change).

## Assumptions

1. Tag click should both **select** the item (same semantics as clicking its left-pane card) and scroll its card into view.
2. Clicking the tag's **remove** (×) button must NOT also fire the new tag-click event. Enforce via `$event.stopPropagation()` on the remove chip, or by only binding click to non-remove targets.
3. Scroll behaviour in the left pane should match the right pane: `scrollIntoView({ behavior: 'smooth', block: 'center' })`, only when `selectedItemId` is non-null and the card exists.
4. Existing consumers of `TagLayerComponent` / `DocShellComponent` outside compliance stay unchanged — new output is additive.
5. A card in the left pane can be targeted via a `data-item-id` attribute added to `app-compliance-item-card`'s host or a wrapper div. No id exists today; we'll add one.

## Open questions

| # | Question | Proposed default |
|---|----------|------------------|
| Q1 | Should clicking an already-selected tag do anything? | No-op — emit anyway, let parent ignore if same id. Matches left-pane card behaviour. |
| Q2 | Smooth scroll in left pane — same spec as right? | Yes: `behavior: 'smooth', block: 'center'`. |
| Q3 | Should clicking the tag chip's label region also count (vs. only the surrounding `tag-layer__item` div)? | Entire `tag-layer__item` counts, except the remove button. |
| Q4 | Keyboard a11y — make tags focusable / keyboard-clickable? | Yes. Add `tabindex="0"` and `(keydown.enter)` / `(keydown.space)` on `tag-layer__item`. |
| Q5 | Should the whole shared `DocShellComponent` path propagate the tag click, or do we add it only to `TagLayerComponent`? | Both. `TagLayerComponent` emits `tagClick`; `DocShellComponent` re-emits it; `DocumentViewerPanelComponent` emits `selectItem`. Keeps shared component flexible for future consumers. |

## Implementation phases

### Phase 1 — Wire tag-click through to item selection and add left-pane scroll [FRONTEND]

```phase-meta
phase: 1
title: Wire tag-click to item selection + scroll-into-view on left pane
tags: [FRONTEND]
repo: rohan_ui
base_branch: main
depends_on: []
files:
  - src/app/shared-components/document-shredding/components/document-tagging/tag-layer/tag-layer.component.ts
  - src/app/shared-components/document-shredding/components/document-tagging/tag-layer/tag-layer.component.html
  - src/app/shared-components/document-shredding/components/document-tagging/doc-shell/doc-shell.component.ts
  - src/app/shared-components/document-shredding/components/document-tagging/doc-shell/doc-shell.component.html
  - src/app/pages/compliance/components/document-viewer-panel/document-viewer-panel.component.ts
  - src/app/pages/compliance/components/document-viewer-panel/document-viewer-panel.component.html
  - src/app/pages/compliance/components/compliance-list-creator/compliance-list-creator.component.html
  - src/app/pages/compliance/components/compliance-items-panel/compliance-items-panel.component.ts
  - src/app/pages/compliance/components/compliance-items-panel/compliance-items-panel.component.html
  - src/app/pages/compliance/components/compliance-item-card/compliance-item-card.component.html
contracts:
  - "1.1 TagLayerComponent tagClick output"
  - "1.2 DocShellComponent tagClick output"
  - "1.3 DocumentViewerPanelComponent selectItem output"
  - "2.1 ComplianceItemsPanelComponent scroll-into-view"
  - "2.2 ComplianceItemCardComponent data-item-id attribute"
verification:
  - npm run lint
  - npm run test -- --include='**/tag-layer.component.spec.ts'
  - npm run test -- --include='**/doc-shell.component.spec.ts'
  - npm run test -- --include='**/document-viewer-panel.component.spec.ts'
  - npm run test -- --include='**/compliance-items-panel.component.spec.ts'
  - npm run test -- --include='**/compliance-list-creator.component.spec.ts'
```

**Goal**: Clicking a tag on the right pane selects the matching compliance item and scrolls its card into view on the left pane.

**Steps**:

- [ ] **1.1** Add `tagClick` output to `TagLayerComponent`.
  - `@Output() tagClick = new EventEmitter<string>();`
  - File: `src/app/shared-components/document-shredding/components/document-tagging/tag-layer/tag-layer.component.ts`
  - Add `onTagClick(tagId: string, event: Event): void { event.stopPropagation(); this.tagClick.emit(tagId); }`.

- [ ] **1.2** Wire click + keyboard handlers on `tag-layer__item` div.
  - File: `tag-layer.component.html`
  - Add `(click)="onTagClick(tag.id, $event)"`, `(keydown.enter)="onTagClick(tag.id, $event)"`, `(keydown.space)="onTagClick(tag.id, $event)"`, `tabindex="0"`, `role="button"`, `[attr.aria-label]="'Select ' + tag.label"`.
  - The inner `<app-tag-chip>` already handles `(remove)` via `matChipRemove` — verify the remove button's `click` stops propagation (Material's `matChipRemove` already stops it; add `(click)="$event.stopPropagation()"` on the `<app-tag-chip>` host as a belt-and-suspenders guard).

- [ ] **1.3** Re-emit `tagClick` through `DocShellComponent`.
  - File: `doc-shell.component.ts` — add `@Output() tagClick = new EventEmitter<string>();`
  - File: `doc-shell.component.html` — bind `(tagClick)="tagClick.emit($event)"` on `<app-tag-layer>`.

- [ ] **1.4** Add `selectItem` output on `DocumentViewerPanelComponent`.
  - File: `document-viewer-panel.component.ts`
  - `readonly selectItem = output<string>();`
  - File: `document-viewer-panel.component.html` — bind `(tagClick)="selectItem.emit($event)"` on `<app-doc-shell>`.

- [ ] **1.5** Wire `selectItem` in `ComplianceListCreatorComponent` template to existing `onItemSelected`.
  - File: `compliance-list-creator.component.html`
  - On `<app-document-viewer-panel>`: add `(selectItem)="onItemSelected($event)"`.

- [ ] **1.6** Add `data-item-id` attribute to the compliance item card root.
  - File: `compliance-item-card.component.html`
  - Put `[attr.data-item-id]="item.id"` on the outermost element of the card so the left pane can query it.

- [ ] **1.7** Scroll selected card into view in `ComplianceItemsPanelComponent`.
  - File: `compliance-items-panel.component.ts`
  - Convert to use `inject(ElementRef)` + `effect()` on `selectedItemId()` that, after next render, queries `[data-item-id="<safeId>"]` inside the items scroll area and calls `scrollIntoView({ behavior: 'smooth', block: 'center' })`. Use `afterNextRender` via an injected `Injector`, matching the pattern already used in `DocumentViewerPanelComponent` (lines 96–108, 188–190).
  - Skip when `selectedItemId` is null or when component not yet initialized (guard with a signal like `isViewReady`).

- [ ] **1.8** Unit tests.
  - `tag-layer.component.spec.ts`: clicking a positioned tag emits `tagClick(tag.id)`; clicking the remove button does not emit `tagClick`; Enter/Space on the tag emits.
  - `doc-shell.component.spec.ts`: forwards `tagClick` from child tag-layer.
  - `document-viewer-panel.component.spec.ts`: emits `selectItem` with id when doc-shell emits `tagClick`.
  - `compliance-items-panel.component.spec.ts`: when `selectedItemId` changes to a known id, the corresponding `[data-item-id]` element's `scrollIntoView` is called with `{ behavior: 'smooth', block: 'center' }`. Use a spy on `HTMLElement.prototype.scrollIntoView`.
  - `compliance-list-creator.component.spec.ts`: `(selectItem)` from viewer-panel invokes `onItemSelected` → `complianceState.setSelectedItem` called with the emitted id.

- [ ] **1.9** E2E check (manual verification in dev server):
  - Load a compliance item detail page with at least two items and a loaded HTML document.
  - Click a tag on the right pane — left card highlights + scrolls into view.
  - Click the tag's remove button — item is NOT selected, only removed.
  - Tab to a tag, press Enter — same as click.

## Phase order and parallelism

Single phase. No parallelism. Sub-steps 1.1–1.6 may be written in parallel by one agent since they only make additive changes; 1.7 depends on 1.6 (needs `data-item-id`); 1.8–1.9 run last.

File-touch matrix (single phase):

| File | Phase |
|------|-------|
| tag-layer.component.ts/.html | 1 |
| doc-shell.component.ts/.html | 1 |
| document-viewer-panel.component.ts/.html | 1 |
| compliance-list-creator.component.html | 1 |
| compliance-items-panel.component.ts/.html | 1 |
| compliance-item-card.component.html | 1 |

## Phase context summaries

**Phase 1**. Bug fix. Adds an additive `tagClick` event chain: `TagLayerComponent` → `DocShellComponent` → `DocumentViewerPanelComponent.selectItem` → `ComplianceListCreatorComponent.onItemSelected` (reuses existing selection pipeline via `ComplianceStateService.setSelectedItem`). Adds a scroll-into-view `effect()` in `ComplianceItemsPanelComponent` keyed on the `selectedItemId` input, and a `data-item-id` attribute on the compliance item card for query selection. Gotchas: (1) tag remove button click must not bubble as a tag-click — rely on Material `matChipRemove` + explicit `$event.stopPropagation()` on the chip host; (2) `CSS.escape` the id when building the query selector; (3) guard scroll with an `isViewReady` signal and `afterNextRender` to avoid pre-init DOM queries; (4) `TagLayerComponent` and `DocShellComponent` are shared — keep the new output purely opt-in. Independent of backend; no API, DB, or Python changes.

## Jira ticket

**Title**: [Compliance] Clicking a tag on the right side should select and scroll to the corresponding card on the left
**Description**: Bidirectional sync for compliance item selection between the right-pane document tags and the left-pane item cards. Currently left→right works; right→left is broken. Add a `tagClick` output on `TagLayerComponent` that propagates through `DocShellComponent` and `DocumentViewerPanelComponent`, feeds into `ComplianceListCreatorComponent.onItemSelected`, and triggers scroll-into-view on the matching card in `ComplianceItemsPanelComponent`. Keep shared components' new output opt-in.

**Acceptance criteria**:
- [ ] Clicking a tag on the right pane selects the matching compliance item in left pane (card shows selected state).
- [ ] Clicking a tag on the right pane scrolls the matching card into view in the left pane with smooth animation, centered.
- [ ] Clicking the tag's remove (×) button still removes the tag and does NOT select the item.
- [ ] Tags are keyboard focusable and respond to Enter/Space as a click.
- [ ] Existing left→right behaviour (clicking a card scrolls the document highlight into view) is unchanged.
- [ ] Shared `TagLayerComponent` / `DocShellComponent` consumers outside compliance still compile and behave identically.
- [ ] Unit tests cover each layer of the event chain and the left-pane scroll.

## Branching convention

```
tim/prcr-1517/phase-1
```
Phase 1 branches off `main`. Since this is a single-phase change, the phase branch IS the PR branch.
