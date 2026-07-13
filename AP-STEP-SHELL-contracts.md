# AP Step Shell — Contracts

Frontend-only. No REST endpoints, DTOs, DB schema, or events. The "contracts" here are the **public component APIs** (selectors, inputs, outputs, content-projection slots) and the shared SCSS token list. Downstream phases must match these signatures exactly.

## Contract → Phase mapping

| Contract Section | Phase(s) | Notes |
|------------------|----------|-------|
| 1. ApStepScaffoldComponent | 1 (build), 2 (consume) | Workbench two-column layout |
| 2. ApStepEmptyStateComponent | 1 (build), 2 & 3 (consume) | Universal empty/loading block |
| 3. ApFilterCardComponent | 1 (build), 2 (consume) | Sidebar filter card |
| 4. ApFilterPillComponent | 1 (build), 2 (consume) | Filter pill w/ count |
| 5. ApStepCardComponent | 1 (build), 3 (consume) | Artifact/gallery card |
| 6. ApSourcePillComponent _(optional)_ | 1 (build), 2 (consume) | Source pill; defer if awkward |
| 7. Shared SCSS tokens (`_ap-step.scss`) | 1 | Mixins/tokens consumed by the components |

**Conventions for all components:** `standalone: true`, `changeDetection: ChangeDetectionStrategy.OnPush`, signal `input()`/`output()`, no injected services beyond `MatIconModule`/`MatTooltipModule` where used. Neutral BEM prefixes. Located under `src/app/pages/acquisition-pathways/shared/<name>/`. Exported from `shared/index.ts`.

---

## 1. ApStepScaffoldComponent

Two-column sidebar + main layout for workbench steps.

```ts
@Component({
  selector: 'ap-step-scaffold',
  standalone: true,
  templateUrl: './ap-step-scaffold.component.html',
  styleUrl: './ap-step-scaffold.component.scss',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class ApStepScaffoldComponent {
  /** Sidebar column width. Default keeps parity with existing `.ap-rr`/`.ap-ic` (280px). */
  readonly sidebarWidth = input<string>('280px');
  /** Viewport max-width at which the layout collapses to a single column. */
  readonly collapseAt = input<string>('960px');
}
```

**Template (shape):**
```html
<div class="ap-step-scaffold" [style.--ap-sidebar-w]="sidebarWidth()">
  <aside class="ap-step-scaffold__sidebar"><ng-content select="[sidebar]"></ng-content></aside>
  <section class="ap-step-scaffold__main"><ng-content></ng-content></section>
</div>
```

**Slots:** `[sidebar]` → sticky sidebar column; default → main column.
**Behavior:** grid `var(--ap-sidebar-w) 1fr`, gap 24px, sticky sidebar (`top:16px`, `max-height:calc(100vh - 32px)`, `overflow-y:auto`), collapses to `1fr` under `collapseAt`.

---

## 2. ApStepEmptyStateComponent

Universal empty / loading placeholder. Replaces all four `__empty` blocks and the `package-assembly` loading banner.

```ts
@Component({
  selector: 'ap-step-empty-state',
  standalone: true,
  imports: [MatIconModule],
  templateUrl: './ap-step-empty-state.component.html',
  styleUrl: './ap-step-empty-state.component.scss',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class ApStepEmptyStateComponent {
  /** Material Symbol name for the idle (non-loading) state, e.g. 'description', 'fact_check', 'inventory_2', 'folder_zip'. */
  readonly icon = input<string>('info');
  /** When true, renders the loading variant (hourglass_top + role="status"). */
  readonly loading = input<boolean>(false);
}
```

**Template (shape):**
```html
<div class="ap-step-empty" [attr.role]="loading() ? 'status' : null">
  <mat-icon class="ap-step-empty__icon">{{ loading() ? 'hourglass_top' : icon() }}</mat-icon>
  <div class="ap-step-empty__msg"><ng-content></ng-content></div>
</div>
```

**Slot:** default → the message (steps keep their exact copy, e.g. "No requirements record yet…").
**Note:** For `package-assembly`'s richer two-line banner (`<strong>` + `<span>`), the step passes that markup into the default slot with `loading` true — the component only supplies icon + wrapper.

---

## 3. ApFilterCardComponent

Sidebar card: uppercase label, optional active-count reset badge, projected filter sections.

```ts
@Component({
  selector: 'ap-filter-card',
  standalone: true,
  templateUrl: './ap-filter-card.component.html',
  styleUrl: './ap-filter-card.component.scss',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class ApFilterCardComponent {
  readonly label = input<string>('Filters');
  /** Number of active filters; the reset badge renders only when > 0. */
  readonly activeCount = input<number>(0);
  /** Emitted when the "N active" reset badge is clicked. */
  readonly reset = output<void>();
}
```

**Template (shape):**
```html
<section class="ap-filter-card">
  <header class="ap-filter-card__header">
    <span class="ap-filter-card__label">{{ label() }}</span>
    @if (activeCount() > 0) {
      <button type="button" class="ap-filter-card__badge" (click)="reset.emit()">
        {{ activeCount() }} active
      </button>
    }
    <ng-content select="[header-extra]"></ng-content>
  </header>
  <ng-content></ng-content>
</section>
```

**Slots:** `[header-extra]` → optional extra header content (e.g. `integrity-check`'s Sources count); default → filter sections.
**Analytics:** the step supplies `[attr.data-analytics-id]` on the reset badge via projected wrapper if needed, or handles it in the `reset` listener. No analytics logic inside the component.

---

## 4. ApFilterPillComponent

Single filter pill: leading dot/icon slot, label, count, active state.

```ts
@Component({
  selector: 'ap-filter-pill',
  standalone: true,
  templateUrl: './ap-filter-pill.component.html',
  styleUrl: './ap-filter-pill.component.scss',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class ApFilterPillComponent {
  readonly label = input.required<string>();
  readonly count = input<number | null>(null);
  readonly active = input<boolean>(false);
  readonly pillClick = output<void>();
}
```

**Template (shape):**
```html
<button
  type="button"
  class="ap-filter-pill"
  [class.ap-filter-pill--active]="active()"
  [attr.aria-pressed]="active()"
  (click)="pillClick.emit()"
>
  <ng-content select="[leading]"></ng-content>
  <span class="ap-filter-pill__label">{{ label() }}</span>
  @if (count() !== null) { <span class="ap-filter-pill__count">{{ count() }}</span> }
</button>
```

**Slot:** `[leading]` → the severity dot, category `<mat-icon>`, or field-type dot each step already renders.
**Analytics:** step adds `[attr.data-analytics-id]` on the `<ap-filter-pill>` host and calls `trackEvent` in the `(pillClick)` handler.

---

## 5. ApStepCardComponent

Artifact/gallery card: icon header, title, subtitle, body slot, footer actions slot.

```ts
@Component({
  selector: 'ap-step-card',
  standalone: true,
  imports: [MatIconModule],
  templateUrl: './ap-step-card.component.html',
  styleUrl: './ap-step-card.component.scss',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class ApStepCardComponent {
  readonly icon = input.required<string>();
  readonly title = input.required<string>();
  /** Secondary line, e.g. "Market Research · DOCX". Optional. */
  readonly subtitle = input<string | null>(null);
  /** Optional state accent applied as `ap-step-card--{state}` (e.g. 'done', 'drafting', 'queued', 'removed', or a summary style). */
  readonly accent = input<string | null>(null);
}
```

**Template (shape):**
```html
<article class="ap-step-card" [class]="accent() ? 'ap-step-card--' + accent() : ''">
  <header class="ap-step-card__header">
    <div class="ap-step-card__icon"><mat-icon>{{ icon() }}</mat-icon></div>
    <div class="ap-step-card__meta">
      <div class="ap-step-card__title">{{ title() }}</div>
      @if (subtitle()) { <div class="ap-step-card__subtitle">{{ subtitle() }}</div> }
    </div>
    <ng-content select="[status]"></ng-content>
  </header>
  <ng-content></ng-content>            <!-- body: progress bars, reasons, etc. -->
  <footer class="ap-step-card__footer"><ng-content select="[actions]"></ng-content></footer>
</article>
```

**Slots:** `[status]` → header-right status pill (`package-assembly`); default → body (progress bar, removed-reason); `[actions]` → footer buttons (Review & Edit, download, labels).

---

## 6. ApSourcePillComponent (optional — defer if awkward)

Source citation pill used by both workbench steps. The two steps define **different `kind` types with different key sets**, so there is no single shared enum — pass the resolved icon in rather than moving any `kind → icon` map into the component:

- `requirements-record` — `SourceKind = 'web' | 'library' | 'upload' | 'user-typed'` (4 keys), mapped `web→language`, `library→dataset`, `upload→description`, `user-typed→person` (see `SOURCE_ICONS` / `sourceIcon()`).
- `integrity-check` — `SourcePillKind = 'web' | 'library' | 'upload'` (3 keys; **no `user-typed`**).

This divergence is exactly why this component is optional (Open Q#3): if wiring both step maps through `icon()` doesn't shrink the steps, leave source pills per-step.

```ts
@Component({
  selector: 'ap-source-pill',
  standalone: true,
  imports: [MatIconModule],
  templateUrl: './ap-source-pill.component.html',
  styleUrl: './ap-source-pill.component.scss',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class ApSourcePillComponent {
  readonly icon = input.required<string>();
  readonly label = input.required<string>();
  /** When true, renders as a <button> and emits pillClick; otherwise a static <span>. */
  readonly clickable = input<boolean>(false);
  /** Visual kind, applied as `ap-source-pill--{kind}` (web | library | upload | user-typed). */
  readonly kind = input<string>('upload');
  readonly pillClick = output<void>();
}
```

**Decision rule:** if wiring the per-step icon map through `icon()` reads cleaner than the current inline ternaries — ship it. If it adds indirection without shrinking the step, leave source pills per-step and record that in the plan's Open Questions.

---

## 7. Shared SCSS tokens (`_ap-step.scss`)

`@use 'styles/index' as *` at top. Exposes mixins the components `@include` so visual values live in one place. Values below are lifted from the current step SCSS to preserve parity.

```scss
@use 'styles/index' as *;

// Muted uppercase section/header label (from .ap-rr__card-header-label)
@mixin ap-step-label {
  font-size: 11px;
  font-weight: 700;
  letter-spacing: 0.06em;
  color: $secondary-text;
  text-transform: uppercase;
}

// Card container (from .ap-rr__card)
@mixin ap-step-card-surface {
  background: $content-background;
  border: 1px solid $activity-border;
  border-radius: 12px;
  box-shadow: $card-shadow;
}

// Empty-state block (from .ap-*__empty)
@mixin ap-step-empty {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 12px;
  padding: 48px 24px;
  text-align: center;
  color: $secondary-text;
}

// Filter-pill base (from .ap-rr__filter-pill / .ap-ic__filter-pill)
@mixin ap-step-pill {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 8px 10px;
  border: 1px solid transparent;
  border-radius: 6px;
  background: transparent;
  color: $main-text;
  font-size: 13px;
  cursor: pointer;
}
```

**Tokens referenced (already defined in `styles/index`):** `$content-background`, `$activity-border`, `$card-shadow`, `$secondary-text`, `$main-text`, `$teal`. No new global tokens introduced.

**Note for reference (unchanged):** the field-type/severity dot colors (e.g. `$ap-rr-dot-extracted`) stay in their step SCSS — they are step-specific data coloring projected into the `[leading]` slot, not shared chrome.
