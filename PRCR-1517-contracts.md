# PRCR-1517 — Contracts

Bug fix. No backend, DB, or API contract changes. All contracts are internal Angular component inputs/outputs and template attributes.

## Contract → Phase mapping

| Section | Phase | Notes |
|---------|-------|-------|
| 1.1 TagLayerComponent `tagClick` output | 1 | New, additive |
| 1.2 DocShellComponent `tagClick` output | 1 | New, additive, re-emit |
| 1.3 DocumentViewerPanelComponent `selectItem` output | 1 | New, additive |
| 2.1 ComplianceItemsPanelComponent scroll-into-view effect | 1 | Internal behavior |
| 2.2 ComplianceItemCardComponent `data-item-id` attribute | 1 | Template attribute |
| 3.1 ComplianceListCreatorComponent template binding | 1 | Wire `(selectItem)` to `onItemSelected` |

## 1. Component output contracts

### 1.1 `TagLayerComponent` — new `tagClick` output

**File**: `src/app/shared-components/document-shredding/components/document-tagging/tag-layer/tag-layer.component.ts`

Add:

```ts
@Output() tagClick = new EventEmitter<string>();

onTagClick(tagId: string, event: Event): void {
    event.stopPropagation();
    this.tagClick.emit(tagId);
}
```

**Template** (`tag-layer.component.html`) — annotate the existing `tag-layer__item` div:

```html
<div
    class="tag-layer__item"
    role="button"
    tabindex="0"
    [attr.data-tag-id]="tag.id"
    [attr.aria-label]="'Select ' + tag.label"
    [style.left.px]="tag.x"
    [style.top.px]="tag.y"
    (click)="onTagClick(tag.id, $event)"
    (keydown.enter)="onTagClick(tag.id, $event)"
    (keydown.space)="onTagClick(tag.id, $event)"
>
    <app-tag-chip
        [label]="tag.label"
        [kind]="tag.kind"
        [color]="tag.color"
        [removeDisabled]="
            pendingDeleteTagIds.has(tag.id) || !!tag.isPendingCreate
        "
        (click)="$event.stopPropagation()"
        (remove)="onRemoveTag(tag.id)"
    ></app-tag-chip>
</div>
```

**Contract**: `tagClick` emits the `InlineTag.id` of the clicked tag. Does not emit when the user clicks the tag-chip's remove button. Existing `removeTag` output is unchanged.

### 1.2 `DocShellComponent` — new `tagClick` output (passthrough)

**File**: `src/app/shared-components/document-shredding/components/document-tagging/doc-shell/doc-shell.component.ts`

Add:

```ts
@Output() tagClick = new EventEmitter<string>();
```

**Template** (`doc-shell.component.html`) — bind on the existing `<app-tag-layer>`:

```html
<app-tag-layer
    [tags]="tags"
    [pendingDeleteTagIds]="pendingDeleteTagIds"
    [shellElement]="shell"
    [contentElement]="content"
    (removeTag)="removeTag.emit($event)"
    (tagClick)="tagClick.emit($event)"
></app-tag-layer>
```

**Contract**: Passthrough of `TagLayerComponent.tagClick`. Other existing outputs (`removeTag`, `tagSelection`) are unchanged.

### 1.3 `DocumentViewerPanelComponent` — new `selectItem` output

**File**: `src/app/pages/compliance/components/document-viewer-panel/document-viewer-panel.component.ts`

Add:

```ts
readonly selectItem = output<string>();
```

**Template** (`document-viewer-panel.component.html`) — bind on the existing `<app-doc-shell>`:

```html
<app-doc-shell
    [htmlSource]="documentHtmlContent()!"
    [tags]="inlineTags()"
    [tagConfig]="tagConfig()"
    [externalHoverTagId]="hoveredItemId()"
    (tagSelection)="onTagSelection($event)"
    (tagClick)="selectItem.emit($event)"
></app-doc-shell>
```

**Contract**: `selectItem` emits the compliance item id when the user clicks a tag in the rendered document. Other existing outputs (`documentChange`, `createComplianceItem`) are unchanged.

## 2. Compliance items panel contracts

### 2.1 `ComplianceItemsPanelComponent` — scroll-into-view on `selectedItemId` change

**File**: `src/app/pages/compliance/components/compliance-items-panel/compliance-items-panel.component.ts`

Replace the current class body with (additions marked in comments):

```ts
import {
    AfterViewInit,
    ChangeDetectionStrategy,
    Component,
    ElementRef,
    Injector,
    afterNextRender,
    computed,
    effect,
    inject,
    input,
    output,
    signal,
    viewChild,
} from '@angular/core';

import {
    ComplianceItemDecisionEvent,
    ComplianceItemView,
    SaveComplianceItemEvent,
} from '@pages/compliance/types/compliance-item.types';

@Component({
    selector: 'app-compliance-items-panel',
    templateUrl: './compliance-items-panel.component.html',
    styleUrls: ['./compliance-items-panel.component.scss'],
    changeDetection: ChangeDetectionStrategy.OnPush,
    standalone: false,
})
export class ComplianceItemsPanelComponent implements AfterViewInit {
    private readonly injector = inject(Injector);

    readonly items = input<ComplianceItemView[]>([]);
    readonly selectedItemId = input<string | null>(null);
    readonly pendingCount = input<number>(0);
    readonly canFinishReview = input<boolean>(false);

    readonly pendingLabel = computed(() => {
        const count = this.pendingCount();
        if (count === 1) {
            return '1 item remaining';
        }

        return `${count} items remaining`;
    });

    readonly selectItem = output<string>();
    readonly hoverItem = output<string | null>();
    readonly toggleExpanded = output<string>();
    readonly toggleEdit = output<string>();
    readonly saveItem = output<SaveComplianceItemEvent>();
    readonly deleteItem = output<string>();
    readonly decisionChange = output<ComplianceItemDecisionEvent>();
    readonly finishReview = output<void>();

    private readonly scrollArea =
        viewChild<ElementRef<HTMLElement>>('scrollArea');
    private readonly isViewReady = signal(false);

    constructor() {
        effect(() => {
            const selectedItemId = this.selectedItemId();
            this.items();

            if (!this.isViewReady() || !selectedItemId) {
                return;
            }

            afterNextRender(
                () => this.scrollSelectedItemIntoView(selectedItemId),
                { injector: this.injector },
            );
        });
    }

    ngAfterViewInit(): void {
        this.isViewReady.set(true);
    }

    private scrollSelectedItemIntoView(selectedItemId: string): void {
        const container = this.scrollArea()?.nativeElement;
        if (!container) {
            return;
        }

        const safeId = CSS.escape(selectedItemId);
        const cardElement = container.querySelector<HTMLElement>(
            `[data-item-id="${safeId}"]`,
        );

        cardElement?.scrollIntoView({
            behavior: 'smooth',
            block: 'center',
        });
    }
}
```

**Template** (`compliance-items-panel.component.html`) — add a template ref on the scroll area:

```html
<section class="compliance-items-panel">
    <div
        #scrollArea
        class="items-scroll-area"
    >
        @for (item of items(); track item.id) {
            <app-compliance-item-card
                [item]="item"
                [isSelected]="selectedItemId() === item.id"
                (mouseenter)="hoverItem.emit(item.id)"
                (mouseleave)="hoverItem.emit(null)"
                (focusin)="hoverItem.emit(item.id)"
                (focusout)="hoverItem.emit(null)"
                (selectItem)="selectItem.emit($event)"
                (toggleExpanded)="toggleExpanded.emit($event)"
                (toggleEdit)="toggleEdit.emit($event)"
                (saveItem)="saveItem.emit($event)"
                (deleteItem)="deleteItem.emit($event)"
                (decisionChange)="decisionChange.emit($event)"
            ></app-compliance-item-card>
        }
        <!-- rest unchanged -->
    </div>
    <!-- footer unchanged -->
</section>
```

**Contract**: When `selectedItemId` becomes non-null or changes, after the next render the component scrolls the DOM element matching `[data-item-id="<safeId>"]` within `#scrollArea` into view with `scrollIntoView({ behavior: 'smooth', block: 'center' })`. No-op if no matching element is found (defensive).

### 2.2 `ComplianceItemCardComponent` — add `data-item-id` attribute

**File**: `src/app/pages/compliance/components/compliance-item-card/compliance-item-card.component.html`

Add `[attr.data-item-id]="item.id"` to the outermost element of the card template. The exact element depends on the current card markup — place it on the same root node that receives `[isSelected]` styling so queries from `ComplianceItemsPanelComponent` resolve to the card's bounding box.

**Contract**: Each rendered compliance item card exposes `data-item-id` equal to the item's `id` on its root DOM element.

## 3. Parent template binding

### 3.1 `ComplianceListCreatorComponent` — bind `(selectItem)` on the viewer panel

**File**: `src/app/pages/compliance/components/compliance-list-creator/compliance-list-creator.component.html`

Add `(selectItem)="onItemSelected($event)"` to the existing `<app-document-viewer-panel>`:

```html
<app-document-viewer-panel
    [documents]="documents()"
    [selectedDocumentId]="selectedDocumentId()"
    [selectedItemId]="selectedItemId()"
    [hoveredItemId]="hoveredItemId()"
    [itemsForSelectedDocument]="itemsForSelectedDocument()"
    [itemCountsByDocument]="itemCountsByDocument()"
    [documentHtmlContent]="documentHtmlContent()"
    [isDocumentHtmlLoading]="isDocumentHtmlLoading()"
    [documentHtmlError]="documentHtmlError()"
    [tagConfig]="complianceTagConfig()"
    (documentChange)="onDocumentChange($event)"
    (createComplianceItem)="onCreateComplianceItem($event)"
    (selectItem)="onItemSelected($event)"
></app-document-viewer-panel>
```

**Contract**: Reuses the existing `onItemSelected(itemId: string)` method in `ComplianceListCreatorComponent`, which calls `this.complianceState.setSelectedItem(itemId)` (no change required in the component's TS).

## 4. DTOs / Database / API

No changes. This is a pure frontend bug fix.

## 5. Error responses

No new error cases. Defensive no-ops already described (missing element, null `selectedItemId`).

## 6. Event payloads (internal)

No cross-service events. All new events are in-component Angular `EventEmitter` / `output()` signals:

| Emitter | Event name | Payload type | Payload meaning |
|---------|-----------|--------------|-----------------|
| `TagLayerComponent` | `tagClick` | `string` | `InlineTag.id` of clicked tag |
| `DocShellComponent` | `tagClick` | `string` | passthrough of `TagLayerComponent.tagClick` |
| `DocumentViewerPanelComponent` | `selectItem` | `string` | compliance item id to select |

## 7. Types (for reference, unchanged)

### `InlineTag` (unchanged)

```ts
// src/app/shared-services/tagging/types/tagging-ui.types.ts
export interface InlineTag {
    id: string;          // compliance item id in the compliance use case
    startOffset: number;
    endOffset: number;
    label: string;
    kind?: string;
    color?: string;
    hidden?: boolean;
    isPendingCreate?: boolean;
    x: number;
    y: number;
}
```

### `ComplianceItemView` (unchanged)

See `src/app/pages/compliance/types/compliance-item.types.ts`. `id: string` is what flows end-to-end.

### Existing left-pane scroll idiom (for reference)

From `DocumentViewerPanelComponent` (matches the new `ComplianceItemsPanelComponent` pattern):

```ts
private scrollToSelectedHighlight(): void {
    const container = this.docShellContainer()?.nativeElement;
    const selectedItemId = this.selectedItemId();

    if (!container || !selectedItemId) {
        return;
    }

    const safeId = CSS.escape(selectedItemId);
    const markElement = container.querySelector<HTMLElement>(
        `mark[${INLINE_HL_TAG_ID_ATTR}="${safeId}"]`,
    );

    markElement?.scrollIntoView({
        behavior: 'smooth',
        block: 'center',
    });
}
```
