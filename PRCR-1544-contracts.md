# PRCR-1544 — Contracts

UI-only ticket. No backend API, DB, or event contract changes.

## Contract → Phase mapping

| Contract Section | Phase(s) | Notes |
|------------------|----------|-------|
| 1.1 `TagChipComponent` remove button tooltip | 1 | Template-only change |

## New endpoints

None.

## Modified endpoints

None.

## New / modified DTOs (backend)

None.

## Database schema changes

None.

## Frontend types

### 1.1 `TagChipComponent` remove button tooltip

No TypeScript input/output signature changes. Template-only change.

File: `src/app/shared-components/document-shredding/components/document-tagging/tag-chip/tag-chip.component.html`

PRCR-1519 is already merged — the template has two `@if` branches, each with its own remove button. Add `matTooltip="Delete"` to both (added lines marked `+`):

```html
@if (displayAsDot) {
    <span
        class="tag-chip tag-chip--dot"
        role="group"
        [attr.data-kind]="kind"
        [attr.aria-label]="label"
        [style.background-color]="color || null"
    >
        <button
            type="button"
            class="tag-chip__remove"
+           matTooltip="Delete"
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
+           matTooltip="Delete"
            [attr.aria-label]="removeAriaPrefix + label"
            [disabled]="removeDisabled"
        >
            <mat-icon>{{ removeIconName }}</mat-icon>
        </button>
    </mat-chip>
}
```

### Module import (for reference)

`MatTooltipModule` is already imported and exported by `SharedComponentsModule` — no module change:

```ts
// src/app/shared-components/shared-components.module.ts
import { MatTooltipModule } from '@angular/material/tooltip';
// …
imports: [
    // …
    MatTooltipModule,
],
```

### Unit test additions

File: `src/app/shared-components/document-shredding/components/document-tagging/tag-chip/tag-chip.component.spec.ts`

```ts
import { MatTooltipModule, MatTooltip } from '@angular/material/tooltip';
import { By } from '@angular/platform-browser';

// In TestBed.configureTestingModule({ imports: [...] }) add MatTooltipModule.

it('shows "Delete" tooltip on labeled remove button', () => {
    const btn = fixture.debugElement.query(By.css('.tag-chip__remove'));
    const tooltip = btn.injector.get(MatTooltip);
    expect(tooltip.message).toBe('Delete');
});

it('shows "Delete" tooltip on dot-variant remove button', () => {
    component.displayAsDot = true;
    fixture.detectChanges();
    const btn = fixture.debugElement.query(By.css('.tag-chip--dot .tag-chip__remove'));
    const tooltip = btn.injector.get(MatTooltip);
    expect(tooltip.message).toBe('Delete');
});
```

## Error responses

None.

## Event payloads (internal)

None.
