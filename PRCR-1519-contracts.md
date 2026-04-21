# PRCR-1519 — Contracts

UI-only ticket. No backend API, DB schema, or event contract changes. Sections below cover Angular component inputs and the minor template change.

## Contract → Phase mapping

| Contract Section | Phase(s) | Notes |
|------------------|----------|-------|
| 1.1 `TagChipComponent.displayAsDot` input | 1 | New optional input + dot variant DOM |
| 1.2 `TagLayerComponent.displayAsDot` input | 1 | Passthrough |
| 2.1 `TgTaggingContextMenuComponent` optional `menuTitle` | 2 | Template guard only |
| 2.2 `DocShellComponent` single-tag-type behavior | 2 | New private logic — no public input changes |

## New endpoints

None.

## Modified endpoints

None.

## New / modified DTOs (backend)

None.

## Database schema changes

None.

## Frontend types

### 1.1 `TagChipComponent.displayAsDot` input

File: `src/app/shared-components/document-shredding/components/document-tagging/tag-chip/tag-chip.component.ts`

```ts
import { ChangeDetectionStrategy, Component, EventEmitter, Input, Output } from '@angular/core';

@Component({
    selector: 'app-tag-chip',
    templateUrl: './tag-chip.component.html',
    styleUrl: './tag-chip.component.scss',
    changeDetection: ChangeDetectionStrategy.OnPush,
    standalone: false,
})
export class TagChipComponent {
    @Input() label = '';
    @Input() kind?: string;
    @Input() color?: string;
    @Input() removeDisabled = false;
    /**
     * When true, render a small colored circle instead of the labeled
     * mat-chip. Used when there is only one tag type in the active tagConfig.
     */
    @Input() displayAsDot = false;
    @Output() remove = new EventEmitter<void>();

    readonly removeAriaPrefix = 'Remove ';
    readonly removeIconName = 'close';

    onRemove(): void {
        if (this.removeDisabled) {
            return;
        }
        this.remove.emit();
    }
}
```

Template skeleton (`tag-chip.component.html`):

```html
@if (displayAsDot) {
    <span
        class="tag-chip tag-chip--dot"
        [attr.data-kind]="kind"
        [attr.aria-label]="label"
        [style.background-color]="color || null"
    >
        <button
            type="button"
            class="tag-chip__remove"
            [attr.aria-label]="removeAriaPrefix + label"
            [disabled]="removeDisabled"
            (click)="onRemove()"
        >
            <mat-icon>{{ removeIconName }}</mat-icon>
        </button>
    </span>
} @else {
    <mat-chip
        class="tag-chip"
        [attr.data-kind]="kind"
        [style.--tag-chip-container-color]="color || null"
        [removable]="!removeDisabled"
        (removed)="onRemove()"
    >
        <span class="tag-chip__label">{{ label }}</span>
        <button
            matChipRemove
            type="button"
            class="tag-chip__remove"
            [attr.aria-label]="removeAriaPrefix + label"
            [disabled]="removeDisabled"
        >
            <mat-icon>{{ removeIconName }}</mat-icon>
        </button>
    </mat-chip>
}
```

SCSS additions (`tag-chip.component.scss`):

```scss
.tag-chip--dot {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 12px;
    height: 12px;
    border-radius: 50%;
    box-shadow: 0 2px 6px rgba(0, 0, 0, 0.12);
    background-color: #3d4b52;
    cursor: pointer;
    transition: width 120ms ease, height 120ms ease;

    .tag-chip__remove {
        display: none;
    }

    &:hover,
    &:focus-within {
        width: 20px;
        height: 20px;

        .tag-chip__remove {
            display: inline-flex;
        }
    }
}
```

### 1.2 `TagLayerComponent.displayAsDot` input

File: `src/app/shared-components/document-shredding/components/document-tagging/tag-layer/tag-layer.component.ts`

```ts
export class TagLayerComponent implements OnChanges, AfterViewInit, OnDestroy {
    // …existing inputs
    @Input() tags: InlineTag[] = [];
    @Input() pendingDeleteTagIds: ReadonlySet<string> = new Set<string>();
    @Input() shellElement: HTMLElement | null = null;
    @Input() contentElement: HTMLElement | null = null;
    /** Forwarded to inner app-tag-chip. */
    @Input() displayAsDot = false;
    @Output() removeTag = new EventEmitter<string>();
    // …rest unchanged
}
```

Template change (`tag-layer.component.html`):

```html
<app-tag-chip
    [label]="tag.label"
    [kind]="tag.kind"
    [color]="tag.color"
    [displayAsDot]="displayAsDot"
    [removeDisabled]="
        pendingDeleteTagIds.has(tag.id) || !!tag.isPendingCreate
    "
    (remove)="onRemoveTag(tag.id)"
></app-tag-chip>
```

### 2.1 `TgTaggingContextMenuComponent` optional `menuTitle`

File: `src/app/shared-components/document-shredding/components/tagging-context-menu/tagging-context-menu.component.html`

Wrap the title in an `@if`:

```html
<div class="tagging-menu">
    @if (menuTitle) {
        <span class="tagging-menu-title">{{ menuTitle }}</span>
        <div class="tagging-menu-divider-container">
            <hr class="tagging-menu-divider" />
        </div>
    }
    @if (menuInfoText) {
        <div class="tagging-menu-info">
            <i class="fa-light fa-circle-info" aria-hidden="true"></i>
            <span class="tagging-menu-info-text">{{ menuInfoText }}</span>
        </div>
    }
    @if (menuConfig.length) {
        @for (item of menuConfig; track item.value) {
            <!-- unchanged -->
        }
    }
    <div class="bottom-padding"></div>
</div>
```

Component class is unchanged — `menuTitle` remains a regular string input that defaults to `'Mark Section As:'`. Callers opting into single-tag mode pass `''` (empty string).

### 2.2 `DocShellComponent` single-tag-type behavior

File: `src/app/shared-components/document-shredding/components/document-tagging/doc-shell/doc-shell.component.ts`

Conceptual additions (private):

```ts
private cachedMenuConfig: TagMenuConfig<string>[] | null = null;

get isSingleTagType(): boolean {
    return (this.cachedMenuConfig?.length ?? 0) === 1;
}

ngOnChanges(changes: SimpleChanges): void {
    // …existing logic
    if (changes['tagConfig']) {
        this.cachedMenuConfig = null;
    }
}

private getMenuConfig(): TagMenuConfig<string>[] {
    if (!this.cachedMenuConfig) {
        this.cachedMenuConfig = this.buildMenuConfig();
    }
    return this.cachedMenuConfig;
}

// In openTagMenu (or equivalent) — replace the existing compRef.setInput calls:
const menuConfig = this.getMenuConfig();
const singleTag = menuConfig.length === 1;
compRef.setInput('menuTitle', singleTag ? '' : 'Mark Highlight As:');
compRef.setInput('menuConfig', menuConfig);
compRef.setInput('menuInfoText', singleTag ? '' : 'Each title starts new section');
```

Template change (`doc-shell.component.html`):

```html
<app-tag-layer
    [tags]="tags"
    [pendingDeleteTagIds]="pendingDeleteTagIds"
    [shellElement]="shell"
    [contentElement]="content"
    [displayAsDot]="isSingleTagType"
    (removeTag)="removeTag.emit($event)"
></app-tag-layer>
```

Exact method signatures of `buildMenuConfig`, `resolveTagUiEntries`, `resolveSchemaTags` are unchanged.

## Error responses

No new error paths. Existing `buildMenuConfig` throws `'Tag config is required to build the tagging menu.'` / `'Tag config must have either tag_ui or tag_schema to build the tagging menu.'` / `'Tag config must define at least one menu tag.'` — unchanged.

## Event payloads (internal)

None.
