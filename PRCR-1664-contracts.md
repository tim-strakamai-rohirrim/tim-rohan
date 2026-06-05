# PRCR-1664 — Contracts

> **Scope note:** This is a **frontend-only, CSS/markup restyle**. There are **no
> new/changed REST endpoints, DTOs, database schema, internal events, or public
> component APIs**. The "contracts" below are therefore the **visual contract**
> (design tokens + surface treatment), the **structural template changes**, and a
> reference snapshot of the (unchanged) component public API so reviewers can verify
> nothing drifted.

## Contract → Phase mapping

| Contract Section | Phase(s) | Notes |
|------------------|----------|-------|
| 1. Visual contract (design tokens + surface treatment) | 1 | SCSS token/radius/shadow alignment to reference |
| 2. Structural template changes | 1 | Remove `app-card-shell`; open page container; `app-button` swap |
| 3. Component public API (unchanged — for reference) | 1 | `@Input`s + `StepComponent` contract must not change |
| 4. Non-changes (explicitly out of scope) | — | API/DB/events/global chrome |

---

## 1. Visual contract (design tokens + surface treatment)

All values reference existing tokens in
`rohan_ui/src/styles/variables.scss`. The target ("after") column matches the
Pathway Selection reference
(`pathway-selection.component.scss`, `pathway-card.component.scss`).

### 1.1 SCSS import

| | Before | After |
|---|---|---|
| Import | `@use 'styles/variables' as *;` | `@use 'styles/index' as *;` |

### 1.2 Surface chrome (cards, status bar, add-row, empty state)

| Property | Before | After (reference) |
|---|---|---|
| Border color | `$primary-border-color` | `$activity-border` |
| Border radius (card surfaces) | `8px` | `12px` |
| Box shadow | _(none)_ | `$card-shadow` |
| Surface background | `$content-background` | `$content-background` (unchanged) |

> Small chrome (tags, source badges, filter pills, source pills, inputs) keep their
> existing small radii (4–20px) — only **card-level surfaces** move to 12px.

### 1.3 Page container (replaces `app-card-shell`)

New root container modeled on `.pathway-selection-page`:

```scss
:host {
    display: block;
    width: 100%;
}

.ap-rr-page {
    box-sizing: border-box;
    display: flex;
    flex-direction: column;
    margin: 0 auto;
    max-width: $content-width;   // 1260px
    padding: 0 30px;
    width: 100%;
}

// existing two-column layout, vertical rhythm aligned to the reference
.ap-rr {
    display: grid;
    grid-template-columns: 280px 1fr;
    gap: 24px;
    align-items: flex-start;
    padding: 32px 0 24px;

    @media (max-width: 960px) {
        grid-template-columns: 1fr;
    }
}
```

### 1.4 Hover affordance

| Element | Hover treatment |
|---|---|
| `.ap-rr__source-item`, clickable source pills | Keep/refine: `border-color: $teal`, subtle background — consistent with reference interactive cards. |
| `.ap-rr__field` (static, editable) | **No** `translateY` hover-lift. Elevation via `$card-shadow` only. |

### 1.5 Removed / dead styles

- `:host { --card-shell-width: 100%; }` override — **removed** (card-shell gone).
- `.ap-rr__btn`, `.ap-rr__btn--primary`, `.ap-rr__btn--secondary` — **removed** if
  buttons are migrated to `app-button` (see §2.3). If a control must stay
  hand-rolled, restyle it to `$activity-border` / reference radii and document the
  deviation in the PR.

### 1.6 Preserved (do NOT change)

- Tag/status accent tokens: `$ap-rr-extracted`, `$ap-rr-inferred`, `$ap-rr-needs`,
  `$ap-rr-user` (and their `-color` pairs), `$ap-rr-fail`.
- Field fade-in keyframes (`apRrFieldFadeIn`) and `:nth-of-type` stagger.
- `--editing` focus ring (`$teal` border + `rgba(20,180,197,0.12)` glow).

---

## 2. Structural template changes

File: `…/requirements-record-step/requirements-record-step.component.html`

### 2.1 Root wrapper

**Before:**

```html
<app-card-shell headerLabel="Requirements Record">
    <div class="ap-rr">
        …
    </div>
</app-card-shell>
```

**After:**

```html
<div class="ap-rr-page">
    <div class="ap-rr">
        …
    </div>
</div>
```

- No in-body kicker/H1/subhead is added (the wizard renders the header).

### 2.2 Inner markup

- The Filters card, Sources card, status bar, field list, edit textarea, source
  pills, and add-row markup are **structurally preserved** (only classes/SCSS
  change). All `[attr.data-analytics-id]`, `[matTooltip]`, `(click)`/`(ngModelChange)`,
  `[ngModel]`, and `testid` bindings remain.

### 2.3 Button migration (recommended — Open question #2)

Replace hand-rolled buttons with shared `app-button`, preserving labels, icons,
analytics ids, and handlers. Indicative mapping (final `appearance`/`type` confirmed
against `ButtonComponent`'s API during implementation):

| Action | Before (`.ap-rr__btn…`) | After (`app-button`) |
|---|---|---|
| Add field (trigger) | `--secondary`, `<mat-icon>add` | `appearance="border-blue"`, `symbol="add"`, `label="Add field"` |
| Cancel add | `--secondary` | `appearance="border-blue"` (or `solid`), `label="Cancel"` |
| Confirm add | `--primary`, `<mat-icon>check` | `appearance="gradient"`, `symbol="check"`, `label="Add field"` |

Each migrated button keeps:
`[attr.data-analytics-id]="analyticsIds.WIZARD_REQUIREMENTS_RECORD_*"` and
`(buttonClick)="startAdd() | cancelAdd() | confirmAdd()"`.

> `app-button` is provided by `SharedComponentsModule`, already imported by
> `AcquisitionPathwaysModule` — **no new module imports required**.

---

## 3. Component public API (unchanged — for reference)

`RequirementsRecordStepComponent` — **no changes**. Included so reviewers can confirm
the restyle does not alter the contract the wizard depends on.

```ts
@Component({
    selector: 'app-requirements-record-step',
    templateUrl: './requirements-record-step.component.html',
    styleUrl: './requirements-record-step.component.scss',
    changeDetection: ChangeDetectionStrategy.OnPush,
    standalone: false,
})
export class RequirementsRecordStepComponent implements StepComponent, OnInit {
    @Input() notes!: WritableSignal<string>;
    @Input() record!: WritableSignal<CrrField[]>;

    // StepComponent contract (unchanged)
    disableNextButton = false;
    updateState(): void; // persists notes + recomputes disableNextButton
}
```

- Inputs `notes` and `record` are wired by `AcquisitionPathwaysWizardComponent`
  (`stepInputs[0] = { notes, record }`) — unchanged.
- All signals/computeds (`tagFilter`, `visibleFields`, `extractedCount`,
  `inferredCount`, `needsCount`, `addOpen`, etc.) and methods (`setTagFilter`,
  `toggleEdit`, `saveEdit`, `removeField`, `startAdd`, `confirmAdd`, `openSource`, …)
  are unchanged.

### 3.1 Frontend types (unchanged — for reference)

From `requirements-record.types.ts`:

```ts
export type CrrTag = 'extracted' | 'inferred' | 'needs' | 'user';
export type TagFilter = 'all' | CrrTag;

export interface SourcePill {
    readonly kind: 'web' | 'library' | 'upload' | 'user-typed';
    readonly label: string;
    readonly href?: string;
}

export interface CrrField {
    readonly label: string;
    readonly tag: CrrTag;
    readonly text: string;
    readonly icon?: string;
    readonly sources?: ReadonlyArray<SourcePill>;
}

export interface CrrSource { /* …unchanged… */ }
```

No type is added, removed, or modified by this ticket.

---

## 4. Non-changes (explicitly out of scope)

| Area | Status |
|---|---|
| REST endpoints / API | None added or changed |
| DTOs (backend) | None |
| Database schema (Postgres/Alembic/TypeORM) | None |
| Internal/cross-service events | None |
| Error responses | None |
| Global app chrome (left nav + right chat panel) | **Out of scope — untouched** |
| Wizard component + shared `card-shell` component | **Untouched** (card-shell is simply no longer used by this step) |
| `requirements-record-step.component.ts` logic | **Untouched** (markup/SCSS only) |
| Tag/status accent color semantics | **Preserved** |
