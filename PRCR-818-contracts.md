# PRCR-818 — Contracts

Presentation-only fix. No API, DTO, DB, event, or shared-type changes.

## Contract → Phase mapping

| Contract Section | Phase(s) | Notes |
|------------------|----------|-------|
| 1.1 `.activity-message hr` style | 1 | Scoped SCSS in `activity-item.component.scss` |

## 1. Frontend styles

### 1.1 `.activity-message hr` style

File: `rohan_ui-parent/rohan_ui/src/app/shared-components/activity-item/activity-item.component.scss`

Add inside the existing `:host { ... }` block, alongside the existing `.activity-message` rule:

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

Rules:
- `border: 0` removes the browser default 3D bevel (`inset` border).
- `border-top: 1px solid rgba(0, 0, 0, 0.12)` matches Material's default divider color and stays subtle on the toolbar background (`$procure-toolbar-background`).
- `margin: 8px 0` replaces the browser default (~16px top + bottom) so adjacent activity messages do not get pushed apart.
- `height: 0` collapses any UA-applied default block height.
- `::ng-deep` is required because `<hr>` is injected via `[innerHTML]` and Angular's Emulated encapsulation does not stamp the component's host attribute onto runtime-injected DOM.

No other selectors are added or modified. No global stylesheet changes.

## 2. APIs / DTOs / DB / events

None.

## 3. Frontend types

No changes to `ActivityItem` or `ActivityType` (`shared-components/activity-item/activity-item.component.ts`). For reference (unchanged):

```ts
export type ActivityType =
    | 'search'
    | 'reasoning'
    | 'completion'
    | 'open_page'
    | 'error'
    | 'markdown';

export interface ActivityItem {
    message: string;
    id: string;
    type?: ActivityType;
    timestamp?: Date;
    url?: string;
}
```

## 4. Test contract

File: `rohan_ui-parent/rohan_ui/src/app/shared-components/activity-item/activity-item.component.spec.ts`

Add a test inside the existing `describe('ActivityItemComponent', ...)`:

```ts
it('renders markdown horizontal rule inside .activity-message', () => {
    component.activity = {
        id: 'hr-1',
        message: 'before\n\n---\n\nafter',
        timestamp: new Date(),
        type: 'markdown',
    };
    fixture.detectChanges();

    const host: HTMLElement = fixture.nativeElement;
    const hr = host.querySelector('.activity-message hr');
    expect(hr).toBeTruthy();
});
```

The test must pass without further configuration; `MarkdownPipe` is provided in the existing `TestBed` setup if used in the template path. If the pipe is not yet declared in the spec's testing module, add it to `declarations` alongside `ActivityItemComponent`.

## 5. Error responses

None.
