# PRCR-818 — Activity Panel: Account for line/bar formatting

## Problem statement

LLM-generated activity messages occasionally contain markdown horizontal rules (`---`). The `ActivityItemComponent` renders markdown via `[innerHTML]="activity.message | markdown"` (`marked` + DOMPurify). Browser default `<hr>` styling produces a thick bar with large vertical margins that looks visually noisy inside the Wizard Activity Panel.

Per Juan: don't filter LLM output. Adjust spacing/appearance of the rendered `<hr>` so it is less obtrusive.

Scope: presentation only. No data model, API, or pipeline changes.

## Key architectural observations

- `ActivityPanelComponent` (`rohan_ui-parent/rohan_ui/src/app/shared-components/activity-panel/`) hosts a `mat-tab-group` with `app-activity-list` + `app-sources-list`.
- `ActivityListComponent` iterates `ActivityItem[]` and renders each via `app-activity-item`.
- `ActivityItemComponent` (`shared-components/activity-item/activity-item.component.html:1-6`) is the only place that pipes activity text through markdown:
  ```html
  @if (activity.type === 'markdown') {
      <span class="activity-message" [innerHTML]="activity.message | markdown"></span>
  }
  ```
- `MarkdownPipe` (`shared-pipes/markdown.pipe.ts`) calls `marked.parse` then `DOMPurify.sanitize`. `<hr>` survives sanitization and is emitted as a vanilla `<hr>` element.
- Component uses default `ViewEncapsulation.Emulated`. Styles in `activity-item.component.scss` do NOT apply to `[innerHTML]` content because Angular's emulated encapsulation does not stamp host attributes onto runtime-injected DOM. Reaching the rendered `<hr>` requires `:host ::ng-deep` (or moving the rule to a global stylesheet).
- The same `MarkdownPipe` is used in other features (Answer Engine v2, etc.). Fix must be scoped to the Activity Panel context to avoid regressing other markdown surfaces.

## Assumptions

- Visual fix in the Activity Panel context is the only requirement; other markdown surfaces are out of scope.
- `:host ::ng-deep` is acceptable. The codebase already relies on `::ng-deep` in several components and Angular still supports it (deprecated but unremoved).
- A subtle 1px divider with reduced vertical margin matches Juan's "make that horizontal line be spaced better, less noticeable" guidance.

## Open questions

| # | Question | Proposed default |
|---|----------|------------------|
| 1 | Hide `<hr>` entirely or render subtle? | Render subtle (Juan: "don't filter content"). |
| 2 | Exact spacing values? | `margin: 8px 0;` `border: 0;` `border-top: 1px solid var(--mat-divider-color, rgba(0,0,0,0.12));` `height: 0;` |
| 3 | Apply to all markdown-typed activity items everywhere, or only inside the Activity Panel? | Scope to `.activity-message` (activity-item host) — covers every Activity Panel usage including `activity-panel-lite` (Answer Engine v2) which also reuses `app-activity-item`. |
| 4 | Style other markdown block elements (`<p>`, `<ul>`) the same way? | No. Out of scope. Only `<hr>` is reported. |

## Implementation phases

### Phase 1 — Soften rendered `<hr>` in activity items [FRONTEND]

```phase-meta
phase: 1
title: Soften rendered <hr> in activity items
tags: [FRONTEND]
repo: rohan_ui
base_branch: develop
depends_on: []
files:
  - src/app/shared-components/activity-item/activity-item.component.scss
  - src/app/shared-components/activity-item/activity-item.component.spec.ts
contracts:
  - "1.1 .activity-message hr style"
verification:
  - npm run lint
  - npm run test -- --include='**/activity-item.component.spec.ts'
```

**Goal**: Render markdown `<hr>` inside an Activity Panel item with reduced vertical margin and a subtle 1px divider, so LLM-emitted `---` no longer reads as a thick bar.

**Steps**:

- [ ] **1.1** Add a scoped `::ng-deep` rule for `<hr>` rendered inside `.activity-message`.
  - File: `src/app/shared-components/activity-item/activity-item.component.scss`
  - Add inside the existing `:host { ... }` block:
    ```scss
    .activity-message {
        ::ng-deep hr {
            border: 0;
            border-top: 1px solid rgba(0, 0, 0, 0.12);
            margin: 8px 0;
            height: 0;
        }
    }
    ```
  - Rationale: `[innerHTML]` content bypasses Emulated encapsulation. `:host ::ng-deep` keeps the rule scoped to this component's DOM subtree.
- [ ] **1.2** Add a regression test that markdown horizontal rules render without inflated spacing.
  - File: `src/app/shared-components/activity-item/activity-item.component.spec.ts`
  - Test: render an `ActivityItem` with `type: 'markdown'` and `message: 'a\n\n---\n\nb'`, query `hr`, assert the element exists inside `.activity-message`.
  - Optional: assert computed style `marginTop` ≤ 12px to lock in the visual fix.
- [ ] **1.3** Run verification commands and screenshot the Wizard Activity Panel before/after for the PR.

## Phase order and parallelism

Single phase. Nothing to stack or parallelize.

| File | Phase 1 |
|------|---------|
| `src/app/shared-components/activity-item/activity-item.component.scss` | ✏️ |
| `src/app/shared-components/activity-item/activity-item.component.spec.ts` | ✏️ |

## Phase context summaries

**Phase 1**: SCSS-only fix in `activity-item.component.scss` plus a spec assertion. Adds `:host ::ng-deep .activity-message hr { ... }` so the `<hr>` produced by the markdown pipe gets a thin divider and tight 8px vertical margins. No TS or template changes. Verification: lint + the activity-item spec. Gotcha: must use `::ng-deep` because `[innerHTML]` content is not reachable by Emulated encapsulation. Affects all consumers of `app-activity-item`, including Answer Engine v2's `activity-panel-lite`, which is intentional — every consumer renders inside the same host element.

## Jira ticket

**PRCR-818 — Activity Panel: Account for line/bar formatting**

Description: Markdown `---` produced by the LLM renders as a thick bar in the Wizard Activity Panel. Soften the rendered `<hr>` rather than filtering content. Single-phase frontend SCSS change in `activity-item.component`.

Acceptance criteria:
- [ ] Phase 1: Activity items containing `---` render a subtle 1px divider with ≤8px vertical margin; no other markdown elements regress; activity-item spec covers the case.

## Branching

`tim/PRCR-818/phase-1` off `develop` (or current `feature/` branch in use). Single PR.
