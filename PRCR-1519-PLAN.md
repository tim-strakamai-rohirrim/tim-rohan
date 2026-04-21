# PRCR-1519 — Align Compliance tagging styling with original design

**Ticket**: [PRCR-1519](https://rohirrim.atlassian.net/browse/PRCR-1519)
**Type**: Bug
**Repo(s)**: `rohan_ui`

## Problem statement

In the Compliance page, the tag "pills" floating over highlighted text currently render the full tag title (e.g. `app-tag-chip` with `{{ label }}`). Design calls for a small colored **dot** instead of a text pill, because Compliance has only one tag type so the label is redundant.

Also, when the user highlights text in the compliance document viewer, the floating context menu (`TgTaggingContextMenuComponent`) currently shows a title ("Mark Highlight As:") and info text ("Each title starts new section") plus the tag button. Design calls for only the action button (labeled "Add compliance items") in this single-tag-type context.

The affected components are **shared** with Proposal Writer / Template Generator, which have multiple tag types and must keep the current label + title + info-text behavior. The fix must branch on "single tag type" vs "multi tag type".

## Key architectural observations

- `TagChipComponent` (`src/app/shared-components/document-shredding/components/document-tagging/tag-chip/`) renders a `mat-chip` with `<span class="tag-chip__label">{{ label }}</span>`. Inputs: `label`, `kind`, `color`, `removeDisabled`. Consumed only by `TagLayerComponent`.
- `TagLayerComponent` (`.../document-tagging/tag-layer/`) receives `tags: InlineTag[]` and renders one `app-tag-chip` per tag. It is consumed only by `DocShellComponent`.
- `DocShellComponent` (`.../document-tagging/doc-shell/`) owns the overlay that attaches `TgTaggingContextMenuComponent` on mouse-up selection. `buildMenuConfig()` (lines 300–331) already derives `TagMenuConfig[]` from `tagConfig.tag_ui.tags` or `tagConfig.tag_schema.tags`. The single/multi-tag-type test is simply `menuConfig.length === 1`.
- `TgTaggingContextMenuComponent` already accepts `menuTitle` (default `'Mark Section As:'`), `menuInfoText` (default `'Each title starts new section'`), and `menuConfig`. Its template already guards info text with `@if (menuInfoText)`. Title is rendered unconditionally.
- Compliance invokes `<app-doc-shell>` from `DocumentViewerPanelComponent` (`src/app/pages/compliance/components/document-viewer-panel/`) passing `tagConfig`. `tagConfig.product_code === ProductCode.COMPLIANCE`, but **the plan does not branch on product code** — it branches on `menuConfig.length === 1`, per ticket wording ("handle a situation when there is only one type of tag"). Compliance gets the new behavior for free.

## Assumptions

1. "Only one type of tag" = `buildMenuConfig()` returns exactly 1 entry (equivalently `tag_ui.tags.length === 1` or schema has 1 tag).
2. The dot's color is `tag.color` from `InlineTag` (already plumbed through `tag-chip.color`).
3. In single-tag mode, the context menu button text uses the single tag's `displayName` from `tag_ui`/schema (backend currently returns "Add compliance items" for the compliance tag config — if not, backend must be corrected separately, out of scope here).
4. Remove/delete affordance for a tag in dot mode is via clicking the dot (or hover reveal) — keep existing `remove` output; dot still dispatches on click of an `×` control inside the chip. See Open question 2.
5. The tag hover ring / highlight sync behavior in `DocShellComponent` is independent of visual variant and continues to work.

## Resolved decisions

| # | Decision |
|---|----------|
| 1 | Dot keeps remove `×` hidden by default; `:hover`/`:focus-within` reveals it. Dot expands slightly on hover to fit the control. |
| 2 | Dot does **not** expand into full labeled chip on hover — expansion reveals remove control only. |
| 3 | Confirmed: compliance `tag_ui` displayName is already `"Add compliance items"`. No backend change needed. |
| 4 | Pending-create / pending-delete states use existing `removeDisabled` plumbing (dim + disable `×`). |
| 5 | Dot element sets `aria-label` = tag `label` so screen readers still announce it. |

## Implementation phases

### Phase 1 — Tag-chip dot variant [FRONTEND]

```phase-meta
phase: 1
title: Tag-chip dot variant + tag-layer passthrough
tags: [FRONTEND]
repo: rohan_ui
base_branch: base
depends_on: []
files:
  - src/app/shared-components/document-shredding/components/document-tagging/tag-chip/tag-chip.component.ts
  - src/app/shared-components/document-shredding/components/document-tagging/tag-chip/tag-chip.component.html
  - src/app/shared-components/document-shredding/components/document-tagging/tag-chip/tag-chip.component.scss
  - src/app/shared-components/document-shredding/components/document-tagging/tag-chip/tag-chip.component.spec.ts
  - src/app/shared-components/document-shredding/components/document-tagging/tag-layer/tag-layer.component.ts
  - src/app/shared-components/document-shredding/components/document-tagging/tag-layer/tag-layer.component.html
contracts:
  - "1.1 TagChipComponent displayAsDot input"
  - "1.2 TagLayerComponent displayAsDot input"
verification:
  - npm run lint
  - npm run test -- --include='**/tag-chip.component.spec.ts'
  - npm run test -- --include='**/tag-layer.component.spec.ts'
```

**Goal**: Add a `displayAsDot` input to `TagChipComponent` that renders a small colored circle instead of a labeled chip; plumb the input through `TagLayerComponent`.

**Steps**:

- [ ] **1.1** Add `@Input() displayAsDot = false;` to `TagChipComponent`.
  - File: `tag-chip/tag-chip.component.ts`
- [ ] **1.2** In the template, render either the dot variant or the existing `mat-chip` variant based on `displayAsDot`.
  - Dot variant: `<span class="tag-chip tag-chip--dot" [style.background-color]="color || null" [attr.aria-label]="label" [attr.data-kind]="kind">…</span>` with the `×` remove button rendered inside but hidden unless `:hover` / `:focus-within`.
  - Keep the existing `<mat-chip>` branch unchanged for the non-dot case.
  - File: `tag-chip/tag-chip.component.html`
- [ ] **1.3** Add SCSS rules for `.tag-chip--dot`: circle (`border-radius: 50%`, fixed `12px`/`14px` diameter), shadow matching the design, and `&:hover .tag-chip__remove` reveal.
  - File: `tag-chip/tag-chip.component.scss`
- [ ] **1.4** Add `@Input() displayAsDot = false;` to `TagLayerComponent` and pass it through to the inner `<app-tag-chip>` in the template.
  - Files: `tag-layer/tag-layer.component.ts`, `tag-layer/tag-layer.component.html`
- [ ] **1.5** Update `tag-chip.component.spec.ts` to cover:
  - Default render shows `.tag-chip__label`.
  - `displayAsDot=true` renders `.tag-chip--dot`, no `.tag-chip__label`, dot background matches `color` input.
  - `remove` output still fires from the dot variant's `×` button.
  - `aria-label` equals `label` in dot mode.
- [ ] **1.6** Update `tag-layer.component.spec.ts` to assert `displayAsDot` is forwarded to the rendered `app-tag-chip`.

### Phase 2 — Doc-shell single-tag-type simplification [FRONTEND]

```phase-meta
phase: 2
title: Doc-shell detects single tag type and simplifies menu + dot tags
tags: [FRONTEND]
repo: rohan_ui
base_branch: phase-1
depends_on: [1]
files:
  - src/app/shared-components/document-shredding/components/tagging-context-menu/tagging-context-menu.component.html
  - src/app/shared-components/document-shredding/components/tagging-context-menu/tagging-context-menu.component.spec.ts
  - src/app/shared-components/document-shredding/components/document-tagging/doc-shell/doc-shell.component.ts
  - src/app/shared-components/document-shredding/components/document-tagging/doc-shell/doc-shell.component.html
  - src/app/shared-components/document-shredding/components/document-tagging/doc-shell/doc-shell.component.spec.ts
contracts:
  - "2.1 TgTaggingContextMenuComponent optional menuTitle"
  - "2.2 DocShellComponent single-tag-type behavior"
verification:
  - npm run lint
  - npm run test -- --include='**/tagging-context-menu.component.spec.ts'
  - npm run test -- --include='**/doc-shell.component.spec.ts'
  - npm run test -- --include='**/document-viewer-panel.component.spec.ts'
```

**Goal**: When `menuConfig.length === 1`: (a) hide the menu title and info text in `TgTaggingContextMenuComponent`; (b) pass `displayAsDot=true` down to `TagLayerComponent`.

**Steps**:

- [ ] **2.1** In `tagging-context-menu.component.html`, wrap the title `<span class="tagging-menu-title">` in `@if (menuTitle)`. Keep info-text guard as-is.
- [ ] **2.2** In `doc-shell.component.ts`:
  - Cache the built menu config as a class field `private cachedMenuConfig: TagMenuConfig<string>[] | null = null;` (invalidate on `tagConfig` change in `ngOnChanges`).
  - Add a getter `get isSingleTagType(): boolean { return (this.cachedMenuConfig?.length ?? 0) === 1; }`.
  - When attaching the overlay portal in `openTagMenu(...)` (currently lines 247–262), set `menuTitle` to `''` and `menuInfoText` to `''` when `isSingleTagType` is true; otherwise use the existing strings (`'Mark Highlight As:'`, `'Each title starts new section'`).
- [ ] **2.3** In `doc-shell.component.html`, bind `[displayAsDot]="isSingleTagType"` on `<app-tag-layer>`.
- [ ] **2.4** Update `tagging-context-menu.component.spec.ts` to assert the title is not rendered when `menuTitle` is empty / falsy.
- [ ] **2.5** Update `doc-shell.component.spec.ts` to cover:
  - Single-tag-type `tagConfig` → overlay receives empty `menuTitle` and empty `menuInfoText`; tag layer's `displayAsDot` input is true.
  - Multi-tag-type `tagConfig` → overlay receives current default strings; `displayAsDot` is false.
- [ ] **2.6** Smoke-test the compliance page manually: highlight text, confirm popup shows only the single action; confirm existing tags render as dots.

## Phase order and parallelism

### File-touch matrix

| File | Phase 1 | Phase 2 |
|------|:-:|:-:|
| `tag-chip.component.{ts,html,scss,spec.ts}` | X |   |
| `tag-layer.component.{ts,html,spec.ts}` | X |   |
| `tagging-context-menu.component.{html,spec.ts}` |   | X |
| `doc-shell.component.{ts,html,spec.ts}` |   | X |

### Parallelism

No file overlap between phases. They could theoretically be built in parallel, but **Phase 2 depends on the `displayAsDot` input added in Phase 1** and should land stacked on top.

Recommended order: **1 → 2**, stacked via branch `tim/PRCR-1519/phase-2` off `tim/PRCR-1519/phase-1`.

### Branching convention

```
tim/PRCR-1519/phase-1   # off base
tim/PRCR-1519/phase-2   # off phase-1
```

## Phase context summaries

### Phase 1

Adds a `displayAsDot` boolean input to `TagChipComponent` and plumbs it through `TagLayerComponent`. When true the chip renders a small colored circle (background = `color`, `aria-label` = `label`) instead of the labeled `mat-chip`; the remove `×` reveals on hover. The default (false) keeps the existing pill rendering bit-for-bit so Proposal Writer and Template Generator are unaffected. No behavior change on its own — Phase 2 flips the switch. Gotcha: the dot must keep the `data-tag-id` attribute / positioning hooks used by `DocShellComponent`'s hover highlight logic (`highlightElementsByTagId`), so don't move the attribute off the chip root.

### Phase 2

Makes `TgTaggingContextMenuComponent.menuTitle` optional (`@if` guard in template) and teaches `DocShellComponent` to detect `menuConfig.length === 1`. In that single-tag-type case: the overlay is attached with empty `menuTitle` and empty `menuInfoText` (so only the single action button is visible in the popup), and `TagLayerComponent` receives `displayAsDot=true` (so floating tags render as colored dots). Depends on Phase 1's `displayAsDot` input. Gotcha: cache the built `menuConfig` on the doc-shell so the getter doesn't call `buildMenuConfig()` from the template during change detection — invalidate the cache in `ngOnChanges` when `tagConfig` changes.

## Jira ticket

**Title**: `[Compliance] Align tagging styling with original design (dot tags + single-action menu)`

**Description**:
On the Compliance page, floating tag chips should render as colored dots rather than labeled pills, and the highlight-selection popup should show only the single "Add compliance items" action (no title, no info text). `TagChipComponent`, `TagLayerComponent`, `TgTaggingContextMenuComponent`, and `DocShellComponent` are shared across Proposal Writer / Template Generator / Compliance, so the change keys off the number of tag types in the active `tagConfig`: when there is exactly one, the simplified UI renders. Multi-tag-type contexts are unchanged.

**Acceptance criteria**:
- [ ] Phase 1 — `TagChipComponent.displayAsDot` renders a colored circular dot with no text, keeps the remove output working (hover reveal), and is plumbed through `TagLayerComponent`. Existing labeled-pill behavior unchanged when `displayAsDot=false`.
- [ ] Phase 2 — `DocShellComponent` detects `menuConfig.length === 1`, passes empty `menuTitle` and empty `menuInfoText` to the context menu overlay and `displayAsDot=true` to the tag layer. `TgTaggingContextMenuComponent` hides the title when `menuTitle` is empty. Proposal Writer / Template Generator (multi-tag) behavior unchanged.
- [ ] All affected unit tests updated and passing; lint clean.
- [ ] Manual verification on the Compliance document viewer: tags render as dots; highlight selection shows only the "Add compliance items" action.
