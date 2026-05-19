# Reusable Audit Component — Design Proposal

> Companion to `audit-components-inventory.md`. Read that first for context on the eight existing components.

## Scope of This Proposal

**In scope:** Consolidate the two full-featured audit pages (`AuditTrailComponent` in settings, `TemplateAuditLogComponent` in acquisition-center) into a reusable component, and provide a clear plug-in point for the two placeholders (`RunHistoryTabComponent`, `ComplianceProjectAuditPageComponent`).

**Out of scope (and why):** The `ActivityPanel` / `ActivityList` / `ActivityItem` family is intentionally excluded. Those render streaming, in-flight activity (LLM reasoning, search events) — a fundamentally different concept from persisted audit records. Forcing them under one umbrella would create a component with two contradictory shapes. Leave them alone.

---

## Design Principles

1. **Separate display from data.** A dumb, pure-view table component that knows nothing about HTTP, and a smart container that owns state and service calls. Same split the codebase already uses informally (`AuditTrailComponent` is the dumb view; `settings.component.ts` + `AuditTrailManager` are the smart shell).
2. **Scope by config, not by subclass.** Differences between Settings audit and Template audit (feature filter vs action-text filter, infinite scroll vs bulk load, column set) are all configuration, not behavior that needs its own class.
3. **Backend contract already supports this.** The GET `/audit_trail` endpoint already accepts `scopeType`, `scopeId`, `entityType`, `entityId`, `templateId`, `feature`, and `action`. The frontend just needs to hand these through.
4. **Preserve existing UX exactly.** No user-visible change for Settings or Template audit during consolidation. Verify by diffing screenshots per phase.
5. **Standalone-ready.** New components should be `standalone: true` and signal-based where it fits — aligns with direction the codebase has been moving (see `ActivityPanelComponent`, `TemplateAuditLogComponent`).

---

## Proposed Architecture

Three layers, bottom-up:

```
┌─────────────────────────────────────────────────────────────┐
│  SMART:  <app-audit-trail-page [scope]="...">              │
│          provides AuditTrailPageService                     │
│          orchestrates fetch + filters + pagination          │
└─────────────────────────────────────────────────────────────┘
                              │ binds via inputs/outputs
                              ▼
┌─────────────────────────────────────────────────────────────┐
│  DUMB:   <app-audit-table>                                  │
│          <app-audit-filter-toolbar>                         │
│          <app-audit-action-cell>                            │
│          pure inputs/outputs, no service calls              │
└─────────────────────────────────────────────────────────────┘
                              │ shared primitives
                              ▼
┌─────────────────────────────────────────────────────────────┐
│  SHARED: AuditTrailService (exists)                         │
│          AuditTrailRecord / AuditTrailFilters (exist)       │
│          DatePickerModalComponent (exists, reusable)        │
└─────────────────────────────────────────────────────────────┘
```

### Layer 1 — Shared primitives (mostly exists)

These already live in the codebase and do not need to change:
- `AuditTrailService` — HTTP client for `/audit_trail*` endpoints.
- `AuditTrailRecord`, `AuditTrailFilters`, `AuditTrailFiltersData`, `AUDIT_TRAIL_FEATURES` — types and enums in `audit-trail.constants.ts`.
- `DatePickerModalComponent` — already used by both audit pages.

### Layer 2 — Dumb presentational components (new, extracted)

#### `<app-audit-filter-toolbar>`

Owns the filter chrome: date range select + email multi-select + feature multi-select + action text filter + Clear All + Download CSV.

```typescript
@Component({
  selector: 'app-audit-filter-toolbar',
  standalone: true,
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class AuditFilterToolbarComponent {
  @Input() filtersData: AuditTrailFiltersData | null = null;
  @Input() initialFilters: AuditTrailFilters | null = null;

  // Feature toggles — turn filters on/off per consumer
  @Input() showFeatureFilter = true;
  @Input() showEmailFilter = true;
  @Input() showDateRangeFilter = true;
  @Input() showActionTextFilter = false;
  @Input() showCsvDownload = true;
  @Input() showClearAll = true;

  // Date range presets to expose
  @Input() dateRangePresets: DateRangePreset[] = DEFAULT_DATE_PRESETS;

  @Output() filtersChanged = new EventEmitter<AuditTrailFilters>();
  @Output() csvDownloadClicked = new EventEmitter<AuditTrailFilters>();
}
```

Why separate from the table: two of the four current/future consumers might want the table without the toolbar (e.g. an embedded "recent activity" preview in a project dashboard). Decoupling now costs nothing.

#### `<app-audit-table>`

Owns the table: sticky-header mat-table, column selection, expandable action cell, infinite-scroll hook, empty state, results count.

```typescript
@Component({
  selector: 'app-audit-table',
  standalone: true,
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class AuditTableComponent {
  @Input() records: AuditTrailRecord[] = [];
  @Input() resultsCount = 0;
  @Input() columns: AuditColumn[] = DEFAULT_COLUMNS;
    // DEFAULT_COLUMNS = ['timestamp', 'feature', 'action', 'performed_by']
  @Input() stickyHeader = true;
  @Input() infiniteScroll = true;
  @Input() loading = false;

  @Output() scrolledToBottom = new EventEmitter<void>();
  @Output() rowClicked = new EventEmitter<AuditTrailRecord>();
}
```

Column config is a typed union (`'timestamp' | 'feature' | 'action' | 'performed_by' | ...`) so future columns (e.g. `entity_type`, `metadata_diff`) can be added centrally.

#### `<app-audit-action-cell>` (optional internal)

Extracted from the current inline expand/collapse logic. Keeps the table template clean. Can live as a private child of `AuditTableComponent` initially; promote to its own file only if reused.

### Layer 3 — Smart container (new)

#### `<app-audit-trail-page>`

A smart component that wires the dumb pieces to `AuditTrailService`. Takes a scope config and exposes display-level toggles.

```typescript
@Component({
  selector: 'app-audit-trail-page',
  standalone: true,
  providers: [AuditTrailPageService], // scoped — one state manager per page instance
  template: `
    <app-audit-filter-toolbar
      [filtersData]="state.filtersData()"
      [showFeatureFilter]="showFeatureFilter"
      [showActionTextFilter]="showActionTextFilter"
      (filtersChanged)="state.applyFilters($event)"
      (csvDownloadClicked)="state.downloadCsv($event)" />

    <app-audit-table
      [records]="state.records()"
      [resultsCount]="state.resultsCount()"
      [columns]="columns"
      [infiniteScroll]="infiniteScroll"
      [loading]="state.loading()"
      (scrolledToBottom)="state.loadMore()" />
  `,
})
export class AuditTrailPageComponent {
  protected readonly state = inject(AuditTrailPageService);

  @Input({ required: true }) set scope(value: AuditScope) {
    this.state.setScope(value);
  }

  @Input() columns: AuditColumn[] = DEFAULT_COLUMNS;
  @Input() showFeatureFilter = true;
  @Input() showActionTextFilter = false;
  @Input() infiniteScroll = true;
  @Input() defaultDateRange: DateRangePreset = 'last-6-months';
}
```

The scope object is the key abstraction:

```typescript
export interface AuditScope {
  // Pick one pattern:
  feature?: AuditTrailFeature;         // Settings mode: filter by feature(s)
  templateId?: number;                  // Template mode: scope to template
  scopeType?: string;                   // Generic: compliance project, one-ring run
  scopeId?: string;
  entityType?: string;
  entityId?: string;
}
```

#### `AuditTrailPageService` (scoped)

Replaces the ad-hoc state living in `AuditTrailManager` and in each audit page's `.ts` file. Provided at component level so each page instance gets its own state.

```typescript
@Injectable()  // no providedIn — scoped to the component
export class AuditTrailPageService {
  private readonly api = inject(AuditTrailService);

  readonly records = signal<AuditTrailRecord[]>([]);
  readonly resultsCount = signal(0);
  readonly filtersData = signal<AuditTrailFiltersData | null>(null);
  readonly loading = signal(false);

  private scope: AuditScope = {};
  private filters: AuditTrailFilters = defaultFilters();
  private page = 0;

  setScope(scope: AuditScope) { /* reset + fetch */ }
  applyFilters(filters: AuditTrailFilters) { /* reset page + fetch */ }
  loadMore() { /* page++ + append */ }
  downloadCsv(filters: AuditTrailFilters) { /* delegate to service */ }
}
```

Signals over observables here: aligns with the Angular 19 direction in the codebase (see `ActivityPanelComponent`), keeps consumers simple (just bind `state.records()`), and side-steps the subscription management that today's audit pages do manually.

---

## Usage Examples

**Settings audit (current Settings page):**
```html
<app-audit-trail-page [scope]="{}" />
<!-- defaults: feature filter on, action-text off, infinite scroll on, all columns -->
```

**Template-scoped audit:**
```html
<app-audit-trail-page
  [scope]="{ feature: 'Template-Generator', templateId: templateId() }"
  [showFeatureFilter]="false"
  [showActionTextFilter]="true"
  [columns]="['timestamp', 'action', 'performed_by']"
  [infiniteScroll]="false" />
```

**Compliance project audit (today a placeholder):**
```html
<app-audit-trail-page
  [scope]="{ scopeType: 'compliance-project', scopeId: projectId() }"
  [showFeatureFilter]="false"
  [columns]="['timestamp', 'action', 'performed_by']" />
```

**OneRing run history (today a placeholder):**
```html
<app-audit-trail-page
  [scope]="{ scopeType: 'one-ring-run', scopeId: runId() }"
  [showFeatureFilter]="false"
  [showActionTextFilter]="true"
  [columns]="['timestamp', 'action', 'performed_by']" />
```

---

## What Goes, What Stays

| Code | Verdict | Notes |
|------|---------|-------|
| `AuditTrailService` | **Keep as-is** | Already the right API surface. |
| `audit-trail.constants.ts` (DTOs) | **Keep as-is** | Canonical types. |
| `DatePickerModalComponent` | **Keep as-is** | Already reusable; new toolbar consumes it. |
| `AuditTrailComponent` (Settings) | **Shrink → wrap** | Becomes a thin wrapper around `<app-audit-trail-page>` during migration, eventually removed. |
| `TemplateAuditLogComponent` | **Shrink → wrap** | Same pattern. Route stays; internals swap. |
| `AuditTrailManager` | **Replace** | Logic absorbed by `AuditTrailPageService`. |
| `RunHistoryTabComponent` | **Fill in** | Drops `<app-audit-trail-page>` in. Also: check with owners whether OneRing uses `AuditTrailService` or needs a distinct endpoint — if distinct, the page service needs an injection seam for the data source. |
| `ComplianceProjectAuditPageComponent` | **Fill in when un-blocked** | Post-MVP per product. Component is ready once prioritized. |
| Activity family (`ActivityPanel` / `ActivityList` / `ActivityItem` / `ActivityPanelLite`) | **Leave alone** | Different purpose. Not consolidating. |

---

## Open Questions / Assumptions to Verify

These are the things I'd want confirmed before finalizing. Calling them out rather than hiding them in the plan.

1. **OneRing run history data source.** Does OneRing emit into the shared `audit_trail` table, or does it have its own run-log table? If the latter, `AuditTrailPageService` needs an injected fetcher so the same UI can sit on top of either data source. Likely wants a small `AuditDataSource` interface with the existing service as the default impl.
2. **Compliance project audit.** Product has flagged it post-MVP. Is the backend already emitting audit rows scoped to project IDs? If not, phase 5 below is a no-op until the backend is in.
3. **CSV export parity.** The template page filters action-text client-side when downloading CSV — because the backend doesn't accept an `action` query param on the CSV endpoint (it does on GET `/audit_trail`). Is that a backend gap worth fixing while we're in here, or status quo?
4. **Column extensibility.** The proposed `AuditColumn` type is a string union today. If consumers will need custom columns with custom cell templates, we'd want `<ng-template>` content projection instead. My read: not needed yet — push that off until a real use case shows up.
5. **Action text filter — client vs server.** Today's template page does client-side action filtering. The backend `action` query param exists. Consolidating to server-side action filter would simplify the code; confirm no reason the template page chose client-side on purpose (e.g. to avoid a round-trip on keystroke).

---

## Why This Design, Not Alternatives

**Alternative A: one monolithic `<app-audit-page>` with many `@Input` toggles.**
Simpler to wire up, but every new consumer either bloats the input surface or silently forces everyone else to adopt an unused option. And there's no good escape hatch when (inevitably) one consumer needs a truly custom column. Rejected.

**Alternative B: headless state management + slot-based templates.**
Maximum flexibility. But way more framework than the problem needs — the UI variation between consumers is limited to column set + two filter toggles + pagination style. Overkill today; revisit if divergence grows. Rejected for now.

**Alternative C (chosen): dumb components + smart container + scoped service.**
Mirrors what the codebase already does with `AuditTrailManager` and `settings.component.ts`, just formalized and with signals instead of RxJS plumbing. Easy to migrate existing pages incrementally, and the dumb layer is usable standalone if a consumer needs to skip the smart container.
