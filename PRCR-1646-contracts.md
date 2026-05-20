# PRCR-1646 — Pathway Selection Contracts

Frontend types, mock data shape, and service interface for the Pathway Selection
screen inside the **Acquisition Pathways** module (`rohan_ui`). No backend
endpoints are introduced in this ticket — pathway data is mocked client-side.
A "Future backend" section at the bottom captures the proposed API shape so a
later ticket can wire it up without redesigning the frontend.

---

## Contract → Phase mapping

| Contract section                                | Phase(s) | Notes                                                                                                                                |
| ----------------------------------------------- | -------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| 1.1 `AcquisitionPathway` core type              | 1        | Replaces the placeholder in `acquisition-pathways.types.ts`.                                                                         |
| 1.2 `AcquisitionPathwayTier` literal union      | 1        | Three tiers — `'low' \| 'medium' \| 'high'`.                                                                                         |
| 1.3 `AcquisitionPathwayFeature` row type        | 1        | Bullet rows on each card with optional `tone`.                                                                                       |
| 1.4 `AcquisitionPathwayVehicleType` union       | 1        | `'existing' \| 'new'` — drives the top-of-card vehicle pill.                                                                         |
| 1.5 `RequirementsRecordSummary` (mock input)    | 1        | Best-guess shape of what the upstream Requirements Record screen will publish; pathways generation reads from it.                    |
| 1.6 `AcquisitionPathwayContractType` enum       | 1        | Closed set of known federal contract types; values are the human-readable labels shown on the card pill.                             |
| 2.1 `PATHWAY_SELECTION_MOCK_PATHWAYS` constant  | 1        | Three-card mock matching the screenshot.                                                                                             |
| 2.2 `PATHWAY_SELECTION_MOCK_RECORD` constant    | 1        | Mock requirements-record summary used as the (future) upstream input.                                                                |
| 3.1 `PathwaySelectionService`                   | 1        | RxJS service holding pathway list + selection. Mirrors the prototype's `PathwaysService`.                                            |
| 4.1 `app-pathway-card` component                | 2        | Dumb presentational card. Inputs: `pathway`, `selected`. Output: `select`.                                                           |
| 5.1 `app-pathway-selection` page                | 3        | Page that lists three cards and the action row. Routed at `acquisition-pathways/pathway-selection`.                                  |
| 6.1 Routing — `pathway-selection` child route   | 3        | Adds the new screen under the existing `acquisition-pathways` lazy route without removing the legacy search-bar landing page.        |
| 7.1 Future backend endpoint (informational)     | —        | Documented but not implemented. Future ticket creates `POST /acquisition-pathways/score` in `rohan_api`.                             |

---

## 1 · Frontend types

All types live in `src/app/pages/acquisition-pathways/types/acquisition-pathways.types.ts`.
The existing `AcquisitionPathway` placeholder in that file (with the comment "real
shape will be defined in a follow-up ticket when the backend contract lands") is
replaced by the shapes below.

### 1.1 `AcquisitionPathway`

```ts
/**
 * One scored pathway recommendation rendered as a card on the
 * Pathway Selection screen. Three are shown at a time, one per tier.
 */
export interface AcquisitionPathway {
    /** Stable, human-readable id used for selection state and `track`. */
    id: AcquisitionPathwayTier;

    /** Card title — short pathway name (e.g. "CIO-SP4 Task Order"). */
    name: string;

    /** Sub-title under the name describing the underlying vehicle/route. */
    vehicle: string;

    /** Whether the underlying vehicle already exists at the agency or is new. */
    vehicleType: AcquisitionPathwayVehicleType;

    /** Human label for the risk tier (e.g. "Low risk", "High risk · flexible"). */
    tierLabel: string;

    /** Material symbol name for the tier icon (e.g. "shield", "balance", "science"). */
    tierIcon: string;

    /**
     * Contract type pill — closed enum (see contract section 1.6). The enum
     * value is rendered as the pill text; the enum *key* is used by the card
     * SCSS to pick a color variant via a small `pathway-card.component.scss`
     * map (no separate `contractTypeClass` field is needed).
     */
    contractType: AcquisitionPathwayContractType;

    /**
     * Body paragraph. May contain limited inline HTML (e.g. <strong>) to
     * highlight key facts. Rendered with `[innerHTML]` so callers MUST
     * sanitize before sending to the component (the mock data is hard-coded
     * and trusted; future API responses must be sanitized server-side).
     */
    rationale: string;

    /** 2–4 short bullet rows shown as a feature checklist under the rationale. */
    features: AcquisitionPathwayFeature[];

    /** Recommended-badge label (e.g. "BEST BALANCED"). Omit for non-recommended cards. */
    recommended?: string;
}

export type AcquisitionPathwayTier = 'low' | 'medium' | 'high';

export type AcquisitionPathwayVehicleType = 'existing' | 'new';
```

### 1.6 `AcquisitionPathwayContractType` enum

Closed set of known federal contract types that can show up on the pathway
card pill. The enum **value** is the human-readable label rendered to the
user; the enum **key** is what `pathway-card.component.scss` keys off of for
the pill's color variant.

This is intentionally a small starter set — extend it as new pathway shapes
come up. The frontend uses an exhaustive `switch` (or a typed lookup) over
the enum so adding a new entry without updating the SCSS map is a TypeScript
error rather than a silent default-styled pill.

```ts
/**
 * Recognized federal contract types used on the Pathway Selection screen.
 * Add new entries when a pathway needs a contract type that isn't yet
 * represented; keep enum values aligned with the way the program office
 * writes the type (label-first, parenthetical acronym).
 */
export enum AcquisitionPathwayContractType {
    FFP = 'Firm Fixed Price (FFP)',
    CPFF = 'Cost Plus Fixed Fee (CPFF)',
    CPIF = 'Cost Plus Incentive Fee (CPIF)',
    CPAF = 'Cost Plus Award Fee (CPAF)',
    TM = 'Time & Materials (T&M)',
    LOE = 'Level of Effort (LOE)',
    HybridCpffFfp = 'Hybrid CPFF + FFP',
}
```

> **Why an enum and not a literal-union:** the Phase 2 card SCSS needs a
> stable, finite list of keys to drive the pill-color variants. An enum keys
> the SCSS map by `FFP` / `CPFF` / `HybridCpffFfp` (the keys), while the UI
> renders the enum *value* as the pill text — so the data carries the label
> and the styling stays decoupled. A literal-union would force callers to
> hand-author the styling key separately.

### 1.3 `AcquisitionPathwayFeature`

```ts
/** A single bullet row inside an AcquisitionPathway card. */
export interface AcquisitionPathwayFeature {
    /** Material symbol icon name (e.g. "check_circle", "schedule", "warning"). */
    icon: string;

    /** Short body text for the row. */
    text: string;

    /**
     * Optional visual tone:
     *   - 'ok'   — default green / neutral (omit for default)
     *   - 'warn' — amber, used for tradeoffs ("adds ~6 months …")
     *   - 'fail' — red,   used for hard blockers ("requires D&F …")
     */
    tone?: 'ok' | 'warn' | 'fail';
}
```

### 1.5 `RequirementsRecordSummary` (best-guess upstream input)

The Requirements Record screen does not exist yet. This is the shape Phase 1
will mock and Phase 3 will pass into the (mock) generation function so the data
flow is in place when Requirements Record lands. It is intentionally small —
only the fields a pathway-scoring step would actually consume.

```ts
/**
 * Compact summary of a Requirements Record run. Future Requirements Record
 * screen will produce this shape; pathway scoring reads it as input.
 *
 * For PRCR-1646, this is mocked client-side. Field shapes mirror the
 * prototype's CrrField (see UA-Acquisition-Pathways/src/app/core/models/canonical-record.ts).
 */
export interface RequirementsRecordSummary {
    /** Server-assigned id of the requirements record run. */
    id: string;

    /** Free-text mission statement the user typed/imported. */
    missionStatement: string;

    /** Structured fields extracted/inferred from the mission. */
    fields: RequirementsRecordField[];
}

export interface RequirementsRecordField {
    /** Display label (e.g. "Mission / Objective", "Estimated Value"). */
    label: string;

    /** Provenance tag — drives the colored chip on the field row. */
    tag: 'extracted' | 'inferred' | 'needs' | 'user';

    /** Resolved value text. */
    text: string;
}
```

> **Note**: when the real Requirements Record ticket lands, this contract may
> grow (sources, citations, etc.). Pathway scoring should only depend on the
> fields above so additional Requirements Record fields don't force a pathway
> rebuild.

---

## 2 · Mock data

Lives in `src/app/pages/acquisition-pathways/constants/pathway-selection.mock.ts`.

### 2.1 `PATHWAY_SELECTION_MOCK_PATHWAYS`

Matches the screenshot the user attached (CIO-SP4 / FAA eFAST / Open-Market).
Hybrid CPFF + FFP across all three to mirror the screenshot.

```ts
import {
    AcquisitionPathway,
    AcquisitionPathwayContractType,
} from '@pages/acquisition-pathways/types/acquisition-pathways.types';

export const PATHWAY_SELECTION_MOCK_PATHWAYS: AcquisitionPathway[] = [
    {
        id: 'low',
        recommended: 'BEST BALANCED',
        vehicleType: 'existing',
        name: 'CIO-SP4 Task Order',
        vehicle: 'NITAAC CIO-SP4 · existing GWAC · Task Order',
        tierLabel: 'Low risk',
        tierIcon: 'shield',
        contractType: AcquisitionPathwayContractType.HybridCpffFfp,
        rationale:
            'Best fit for the FY27 ATO / radar modernization schedule because it uses an ' +
            'existing federal IT services GWAC with proceeding room for a hybrid CPFF + FFP ' +
            'task-order structure. <strong>CIO-SP4</strong> aligns with NAICS 541512, ' +
            '$50M-class systems integration, and the prior ADS-B modernization profile, ' +
            'reducing stand-up time while still allowing evaluation of NAS safety, legacy ' +
            'interface, cybersecurity, and transition risk.',
        features: [
            { icon: 'check_circle', text: 'Fastest viable path for FY27 operational capability' },
            {
                icon: 'check_circle',
                text: 'Supports hybrid pricing for integration uncertainty and defined deliverables',
            },
            {
                icon: 'warning',
                text: 'Ordering constraints must not overfit incumbent radar interfaces',
                tone: 'warn',
            },
        ],
    },
    {
        id: 'medium',
        vehicleType: 'new',
        name: 'FAA eFAST or GSA MAS BPA Competition',
        vehicle: 'FAA eFAST / GSA MAS IT · agency-tailored BPA or task-order competition',
        tierLabel: 'Medium risk',
        tierIcon: 'balance',
        contractType: AcquisitionPathwayContractType.HybridCpffFfp,
        rationale:
            'A tailored BPA or task-order competition gives FAA more control over evaluation ' +
            'factors, ordering procedures, transition requirements, and phased modernization ' +
            'work than a straight CIO-SP4 order. It is a balanced fallback if market research ' +
            'shows CIO-SP4 vendor depth is weaker than expected for radar-processing ' +
            'modernization or if FAA wants a repeatable ordering structure for follow-on NAS ' +
            'integration increments.',
        features: [
            { icon: 'check_circle', text: 'More control over evaluation and transition terms' },
            {
                icon: 'schedule',
                text: 'Moderate schedule impact from BPA or tailored competition setup',
                tone: 'warn',
            },
            {
                icon: 'warning',
                text: 'Vendor depth may be thinner for safety-critical radar integration',
                tone: 'warn',
            },
        ],
    },
    {
        id: 'high',
        vehicleType: 'new',
        name: 'Open-Market Full-and-Open Competition',
        vehicle: 'FAR Part 15 · new standalone solicitation · Full-and-Open',
        tierLabel: 'High risk · flexible',
        tierIcon: 'science',
        contractType: AcquisitionPathwayContractType.HybridCpffFfp,
        rationale:
            'A standalone FAR Part 15 competition provides the most flexibility to tailor ' +
            'Section L, Section M, cost realism, data rights, cybersecurity, NAS safety, ' +
            'transition, and phased deployment requirements. It is the most defensible choice ' +
            'only if FAA determines the radar-processing scope cannot fit within an existing ' +
            'vehicle or needs unusually specific contractual controls that outweigh the FY27 ' +
            'schedule pressure.',
        features: [
            {
                icon: 'warning',
                text: 'Maximum tailoring for NAS safety and legacy interface risk',
                tone: 'warn',
            },
            {
                icon: 'warning',
                text: 'Longest time to award and highest protest exposure',
                tone: 'fail',
            },
            {
                icon: 'warning',
                text: 'Requires full solicitation package and more governance review',
                tone: 'fail',
            },
        ],
    },
];
```

### 2.2 `PATHWAY_SELECTION_MOCK_RECORD`

Stands in for the future Requirements Record output. Used by Phase 3's
"Re-run analysis" handler so the data flow is real even though the upstream
screen is missing.

```ts
import {
    RequirementsRecordSummary,
} from '@pages/acquisition-pathways/types/acquisition-pathways.types';

export const PATHWAY_SELECTION_MOCK_RECORD: RequirementsRecordSummary = {
    id: 'mock-record-faa-radar',
    missionStatement:
        "Modernize the ATO's en-route radar processing subsystem to improve severe-weather " +
        'avoidance and resolve legacy system obsolescence. Operational capability targeted ' +
        'by end of FY27.',
    fields: [
        {
            label: 'Mission / Objective',
            tag: 'extracted',
            text:
                "Modernize the ATO's en-route radar processing subsystem to improve " +
                'severe-weather avoidance and resolve legacy system obsolescence. ' +
                'Operational capability targeted by end of FY27.',
        },
        {
            label: 'Estimated Value',
            tag: 'inferred',
            text: '$48M–$62M over 5 years (base + 4 option years)',
        },
        {
            label: 'NAICS / PSC',
            tag: 'extracted',
            text: 'NAICS 541512 · Computer Systems Design Services — PSC D302',
        },
        {
            label: 'Performance Period',
            tag: 'inferred',
            text: '1 Dec 2026 – 30 Nov 2031 (5-year base/option structure)',
        },
        {
            label: 'Contract Type Preference',
            tag: 'needs',
            text: 'Not specified — Hybrid CPFF + FFP suggested from FY23 ADS-B precedent.',
        },
    ],
};
```

---

## 3 · `PathwaySelectionService` (RxJS state)

Lives in `src/app/pages/acquisition-pathways/services/pathway-selection.service.ts`.
Provided in the `AcquisitionPathwaysModule`, **not** root-scoped, so the service
is torn down when the user navigates away.

```ts
import { Injectable } from '@angular/core';
import { BehaviorSubject, Observable, map } from 'rxjs';

import {
    AcquisitionPathway,
    AcquisitionPathwayTier,
    RequirementsRecordSummary,
} from '@pages/acquisition-pathways/types/acquisition-pathways.types';
import {
    PATHWAY_SELECTION_MOCK_PATHWAYS,
    PATHWAY_SELECTION_MOCK_RECORD,
} from '@pages/acquisition-pathways/constants/pathway-selection.mock';

@Injectable()
export class PathwaySelectionService {
    private readonly _pathways$ = new BehaviorSubject<AcquisitionPathway[]>([]);
    private readonly _selectedTier$ = new BehaviorSubject<AcquisitionPathwayTier | null>(null);
    private readonly _loading$ = new BehaviorSubject<boolean>(false);

    readonly pathways$: Observable<AcquisitionPathway[]> = this._pathways$.asObservable();
    readonly selectedTier$: Observable<AcquisitionPathwayTier | null> =
        this._selectedTier$.asObservable();
    readonly loading$: Observable<boolean> = this._loading$.asObservable();

    /** True when the user has explicitly committed to a pathway. */
    readonly committed$: Observable<boolean> = this._selectedTier$.pipe(map((t) => t !== null));

    /**
     * Generate the three pathway recommendations from the upstream
     * requirements record. For PRCR-1646 this is a synchronous mock that
     * returns the static seed regardless of the input. Future tickets will
     * swap the body for a backend call without changing the signature.
     */
    generate(_record: RequirementsRecordSummary = PATHWAY_SELECTION_MOCK_RECORD): void {
        this._loading$.next(true);
        // Mock: clone the seed so callers cannot mutate the source.
        const fresh = PATHWAY_SELECTION_MOCK_PATHWAYS.map((p) => ({
            ...p,
            features: p.features.map((f) => ({ ...f })),
        }));
        this._pathways$.next(fresh);

        // Auto-select the recommended (BEST BALANCED) tier on first land
        // so the "Assemble package" button is enabled by default. Users
        // who agree with the recommendation can proceed without re-clicking.
        if (this._selectedTier$.value === null) {
            const recommended = fresh.find((p) => p.recommended) ?? fresh[0];
            if (recommended) this._selectedTier$.next(recommended.id);
        }

        this._loading$.next(false);
    }

    selectTier(tier: AcquisitionPathwayTier): void {
        this._selectedTier$.next(tier);
    }

    /** Reset to a clean state — used by "Re-run analysis". */
    reset(): void {
        this._pathways$.next([]);
        this._selectedTier$.next(null);
        this._loading$.next(false);
    }

    /** Synchronous accessors for component logic that doesn't need the stream. */
    pathways(): AcquisitionPathway[] {
        return this._pathways$.value;
    }
    selectedTier(): AcquisitionPathwayTier | null {
        return this._selectedTier$.value;
    }
}
```

---

## 4 · `app-pathway-card` component

Lives in `src/app/pages/acquisition-pathways/components/pathway-card/`.

Dumb presentational card — no service injection, no router. Its only job is to
render an `AcquisitionPathway` and emit a `select` event when its action button
is clicked. Internal HTML rendering uses `[innerHTML]` for the rationale string;
mock data is trusted, but the component MUST set `[innerHTML]` only on the
`rationale` string and treat all other inputs as plain text.

### 4.1 Inputs / Outputs

```ts
import { ChangeDetectionStrategy, Component, input, output } from '@angular/core';

import {
    AcquisitionPathway,
    AcquisitionPathwayTier,
} from '@pages/acquisition-pathways/types/acquisition-pathways.types';

@Component({
    selector: 'app-pathway-card',
    templateUrl: './pathway-card.component.html',
    styleUrls: ['./pathway-card.component.scss'],
    changeDetection: ChangeDetectionStrategy.OnPush,
    standalone: false,
})
export class PathwayCardComponent {
    readonly pathway = input.required<AcquisitionPathway>();
    readonly selected = input<boolean>(false);

    readonly select = output<AcquisitionPathwayTier>();

    onSelectClick(): void {
        this.select.emit(this.pathway().id);
    }
}
```

### 4.2 Template structure

Renders, top-to-bottom (mirrors the screenshot):

1. **Recommended badge** (top-left corner) — only when `pathway().recommended` is set; uses Material symbol `star` + label text.
2. **Vehicle-type pill** — `app-status-chip` with label `'EXISTING VEHICLE'` or `'NEW VEHICLE'` and icon `account_balance` / `add_circle`.
3. **Risk-tier pill** — small pill with the tier icon (`pathway().tierIcon`) and `tierLabel` text.
4. **Pathway name** (`<h3>`) and **vehicle** subtitle.
5. **Contract type row** — label "Contract type" + `app-status-chip` with `contractType` (enum value) as its text. The card SCSS keys off the matching enum *key* (e.g. `FFP`, `HybridCpffFfp`) for the pill's color variant via a small map in `pathway-card.component.scss`.
6. **Rationale paragraph** rendered with `[innerHTML]`.
7. **Features list** — one row per `feature`; icon comes from `feature.icon`, text from `feature.text`, tone class from `feature.tone`.
8. **Footer button** — `app-button` with `label = selected() ? 'Selected' : 'Select'` and an active-state appearance when selected.

### 4.3 Accessibility

- The whole card is a `<section>` with `role="group"` and `aria-labelledby` pointing to the pathway-name `<h3>`'s id.
- The footer button is a real `<button>` (via `app-button`); clicking the card body does NOT also select. (The mockup let the whole card be clickable; rohan_ui prefers an explicit button to keep keyboard semantics simple.)
- Selected state is communicated via `aria-pressed` on the footer button.

---

## 5 · `app-pathway-selection` page

Lives in `src/app/pages/acquisition-pathways/pages/pathway-selection/`.

### 5.1 Component skeleton

```ts
import {
    ChangeDetectionStrategy,
    Component,
    OnDestroy,
    OnInit,
    inject,
} from '@angular/core';
import { Observable, Subscription } from 'rxjs';

import { AppInsightsService } from '@shared-services/app-insights/app-insights.service';

import { PathwaySelectionService } from '@pages/acquisition-pathways/services/pathway-selection.service';
import {
    AcquisitionPathway,
    AcquisitionPathwayTier,
} from '@pages/acquisition-pathways/types/acquisition-pathways.types';
import {
    PS_HEADING,
    PS_KICKER,
    PS_SUBHEAD,
    PS_BACK_LABEL,
    PS_RERUN_LABEL,
    PS_NEXT_LABEL,
} from '@pages/acquisition-pathways/constants/pathway-selection.constants';

@Component({
    selector: 'app-pathway-selection',
    templateUrl: './pathway-selection.component.html',
    styleUrls: ['./pathway-selection.component.scss'],
    changeDetection: ChangeDetectionStrategy.OnPush,
    standalone: false,
})
export class PathwaySelectionComponent implements OnInit, OnDestroy { /* … */ }
```

### 5.2 Behavior

| Trigger                                  | Action                                                                                                            |
| ---------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| `ngOnInit`                               | Logs page view via `AppInsightsService`. Calls `pathwaySvc.generate()` if `pathways().length === 0`.              |
| `(select)` from a card                   | `pathwaySvc.selectTier(tier)`.                                                                                    |
| **Re-run analysis** button click         | `pathwaySvc.reset()` then `pathwaySvc.generate()` (no API call yet — same mock).                                  |
| **Back** button click                    | No-op for this ticket; component exposes a `back()` method that the test asserts is wired to a router navigation. |
| **Assemble package** button click        | Same as Back — no destination yet; `next()` method exists for tests, body is a TODO with the future route.        |
| `ngOnDestroy`                            | Logs time spent via `AppInsightsService` and unsubscribes.                                                        |

### 5.3 Constants (`pathway-selection.constants.ts`)

```ts
export const PS_KICKER = 'STEP 2 · PATHWAY SELECTION';
export const PS_HEADING = 'Three pathways. Pick one.';
export const PS_SUBHEAD =
    'Tiers balance risk, speed, and opportunity differently — including vehicles ' +
    'already in place at your agency.';
export const PS_BACK_LABEL = 'Back';
export const PS_RERUN_LABEL = 'Re-run analysis';
export const PS_NEXT_LABEL = 'Assemble package';
export const PS_NEXT_TOOLTIP_DISABLED = 'Select a pathway first.';
export const PS_LOADING_LABEL = 'Scoring pathways for your mission…';
export const PS_EMPTY_LABEL =
    'No pathway analysis yet — complete previous steps so pathways can be scored.';
```

---

## 6 · Routing

Path: `acquisition-pathways/pathway-selection`.

### 6.1 Routes

`acquisition-pathways-routing.module.ts` becomes:

```ts
import { NgModule } from '@angular/core';
import { RouterModule, Routes } from '@angular/router';

import { AcquisitionPathwaysComponent } from './root/acquisition-pathways.component';
import { PathwaySelectionComponent } from './pages/pathway-selection/pathway-selection.component';

const routes: Routes = [
    { path: '', component: AcquisitionPathwaysComponent },
    { path: 'pathway-selection', component: PathwaySelectionComponent },
];

@NgModule({
    imports: [RouterModule.forChild(routes)],
    exports: [RouterModule],
})
export class AcquisitionPathwaysRoutingModule {}
```

> The legacy search-bar landing page (`AcquisitionPathwaysComponent`) is left
> in place at `''` so this ticket does not delete unrelated scaffolding. A
> follow-up ticket can promote `pathway-selection` to the default route or
> remove the legacy page entirely.

---

## 7 · Future backend (informational — out of scope for PRCR-1646)

Recorded here so the next ticket can wire it up without redesigning the
frontend. None of this is implemented in PRCR-1646.

### 7.1 Proposed endpoint

```
POST /acquisition-pathways/score
Auth: Bearer JWT (existing `AuthGuard('jwt')`).
Feature: `ACQUISITION_CENTER` (or a new `ACQUISITION_PATHWAYS` flag — TBD).
Body:    { requirementsRecordId: string }   // server resolves the record server-side
Response 200: { pathways: AcquisitionPathway[] }
Errors:
  400 — { message: 'Invalid requirements record id' }
  404 — { message: 'Requirements record not found' }
  500 — { message: 'Failed to score pathways' }
```

The frontend `PathwaySelectionService.generate()` body would change from
"return mock" to "POST + map response → `_pathways$`", but the public surface
(`pathways$`, `selectedTier$`, `committed$`, `selectTier`, `reset`,
`generate`) is unchanged.

### 7.2 Related work

`docs/HANDOFF.md` in the prototype (`UA-Acquisition-Pathways`) maps each
prototype tool to the production target. The relevant rows:

| Prototype tool                                                                                                | Future production location              |
| ------------------------------------------------------------------------------------------------------------- | --------------------------------------- |
| `pathways.js` (`select_pathway`, `compare_pathways`, `set_recommended_pathway`, `simulate_pathway_change`, `populate_pathways`) | `rohan_api/src/procurement-writer/tools/pathways/` |
| `pathways.seed.ts`                                                                                            | `GET /api/missions/:id/pathways`        |

These are **not** introduced in PRCR-1646.
