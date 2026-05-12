# PRCR-1596 — Derive `analyzeFailed` from observed poll state

Eliminate the dual-source-of-truth class for "is this response in a failed render state?" in `CompanyDetailComponent`. Today `analyzeFailed` is a **writable** signal that has to be kept in sync with `response.status === Failed` via a centralizing `setResponse(...)` helper (the v1 design, currently in PR #2035). This plan replaces that approach: `analyzeFailed` becomes a `computed(...)` derived from a more precise underlying signal (`lastPollOutcome`), so the drift class is structurally impossible — not merely "less likely".

- Jira: https://rohirrim.atlassian.net/browse/PRCR-1596
- Parent: PRCR-1562 (FAILED status handling — already merged the OR fix in `analysisState`)
- Supersedes: PR #2035 (v1 — centralize via `setResponse`). The work in PR #2035 should be rebased/amended onto this design (same branch `tim/PRCR-1596/phase-1`) or that PR should be closed and a fresh branch opened. The plan describes the end state; the implementer chooses the migration path.

## Problem statement

After PRCR-1562, `analysisState` correctly renders `Failed` whenever `response.status === Failed`, even if `analyzeFailed === false`. The opposite direction is still broken: if `analyzeFailed` was set to `true` during a prior polling/refresh cycle and the response then transitions to a healthy status (via `onDocumentsChanged`, a poll tick, a route change, etc.), nothing in the current code clears the stale flag. Result: `analysisState` keeps returning `Failed` and the UI is stuck.

The v1 fix (PR #2035) routed every `response` write through a `setResponse(...)` helper that opportunistically cleared `analyzeFailed` when the new response landed on a healthy status. That works for the symptom but leaves the underlying architectural smell intact:

- `analyzeFailed` and `response.status === Failed` are still **two writable sources of truth** for the same UI concept (`analysisState` ORs them).
- Every future contributor must remember to either (a) write through `setResponse`, or (b) explicitly clear `analyzeFailed` when needed.
- New `ResponseStatus` enum values are silently treated as "ambiguous" by the enumeration-based clear-set, which is the opposite of safe-by-default.
- The helper still requires two notify functions (`markAnalysisPolledToUnknownState` vs `notifyAnalysisBackendFailed`) that differ by one line — they exist only because the flag is writable.

This plan moves the failure-flag state into a **precise underlying signal** (`lastPollOutcome: 'recognized' | 'unrecognized' | null`) and derives `analyzeFailed` from it via a `computed(...)`. The result:

- `analyzeFailed` cannot drift — it is a pure function of `lastPollOutcome`.
- Poll/refresh subscribers (the only paths that *observe* a server-driven state transition) classify their observation via `applyObservedResponse(...)`. Every other site writes `lastPollOutcome` explicitly to `null` (user actions, session boundaries) or `'unrecognized'` (analyze-start API failure — no observation possible).
- The catch-all and recovery branches in the poll subscribers no longer manage the flag — the classifier does.
- User actions (`onDocumentsChanged`, `saveName`, route navigation, `onRunComplianceCheck` start) explicitly clear `lastPollOutcome` because the action supersedes any prior poll claim.
- `markAnalysisPolledToUnknownState` and `notifyAnalysisBackendFailed` collapse into one `notifyAnalysisFailed` helper (side effects only).

## Key architectural observations

### `CompanyDetailComponent` state surface today (`src/app/pages/compliance/components/company-detail/company-detail.component.ts`)

| Signal | Type today | Type in this plan | Notes |
|--------|-----------|-------------------|-------|
| `response` | `signal<ComplianceResponseDetail \| null>` | unchanged | Server-side truth |
| `isAnalyzing` | `signal<boolean>` | unchanged | In-flight flag |
| `analyzeFailed` | `signal<boolean>` (writable) | **`computed<boolean>` (derived)** | Now derived from `lastPollOutcome` |
| `lastPollOutcome` | — | **new `signal<LastPollOutcome \| null>` (private)** | Tracks outcome of the most recent observation |
| `analysisState` | `computed<ResponseAnalysisStateEnum>` | unchanged body | Still ORs `analyzeFailed()` with `response.status === Failed`; the OR is now safe because both sides are derived/precise |

### Existing `response.set(...)` / `response.update(...)` / `analyzeFailed.set(...)` call sites

All `response` writes are categorized as **poll observations**, **user-action observations**, **mutations**, or **session boundaries**. Only poll observations classify; the rest write `lastPollOutcome` directly (or not at all). The `analyzeFailed.set(...)` calls go away entirely (the signal becomes read-only). Line numbers are against `main` (pre-PR-2035) to keep the audit independent of the v1 work.

| Site | Category | Today (pre-PR-2035) | After this plan |
|------|----------|---------------------|-----------------|
| `ngOnInit` route-cleanup `tap` | Session boundary | `response.set(null)` + `analyzeFailed.set(false)` | `response.set(null)` + `lastPollOutcome.set(null)` |
| `ngOnInit` initial subscribe | Initial load (special — see §2.1.1) | `response.set(response)` + `if Failed { analyzeFailed.set(true) }` | `response.set(response)` (Failed branch removed; no `lastPollOutcome` write — relies on prior cleanup `null`) |
| `saveName` rename success | Mutation | `response.update(merger)` | `response.update(merger)` (unchanged; no `lastPollOutcome` write) |
| `onDocumentsChanged` inline fresh | User action | `response.set(fresh)` | `response.set(fresh)` + `lastPollOutcome.set(null)` |
| `onDocumentsChanged` refetch | User action | `response.set(response)` | `response.set(response)` + `lastPollOutcome.set(null)` |
| `refreshAndStartPollIfNeeded` `subscribe` | Poll observation | `response.set(updated)` + branch-specific `markAnalysisFailed()` / `analyzeFailed.set(false)` | `applyObservedResponse(updated)` + `notifyAnalysisFailed()` on catch-all/Failed (side effects only) |
| `startAnalysisPoll` `subscribe` | Poll observation | `response.set(updated)` + branch-specific `markAnalysisFailed()` / `analyzeFailed.set(false)` | `applyObservedResponse(updated)` + `notifyAnalysisFailed()` on catch-all/Failed |
| `onRunComplianceCheck` start | Session boundary | `analyzeFailed.set(false)` | `lastPollOutcome.set(null)` |
| `onRunComplianceCheck` catchError | Non-observation failure | `analyzeFailed.set(true)` + toast | `lastPollOutcome.set('unrecognized')` + toast (no fresh response observed) |

### Classification rule

A response observation is classified `'unrecognized'` iff the response is in the only genuinely-ambiguous state — `Uploaded` with no prior analysis history (i.e., we observed a response that has no in-flight, no terminal, and no history). Every other status — including `Failed` — is `'recognized'`. `Failed` is a recognized terminal because `analysisState` already renders `Failed` from `response.status` directly; `lastPollOutcome` doesn't need to also carry that fact.

```ts
private classifyPollOutcome(response: ComplianceResponseDetail): LastPollOutcome {
    const isAmbiguous =
        response.status === ResponseStatusEnum.Uploaded &&
        !this.responseHasAnalysisHistory(response);
    return isAmbiguous ? 'unrecognized' : 'recognized';
}
```

This is an **inverted predicate** vs the v1 plan's enumeration. It is robust to new `ResponseStatus` enum values: anything new is classified `'recognized'` by default (safe — UI shows `Idle`/`Complete`/`Stale`/whatever derives from `response.status`, not `Failed`). The v1 enumeration silently fell into the catch-all (unsafe — would have rendered `Failed`).

### Helper collapse: one notify function instead of two

After this plan, `notifyAnalysisFailed` is a pure-side-effect helper:

```ts
private notifyAnalysisFailed(): void {
    this.isAnalyzing.set(false);
    this.fullstoryService.trackEvent('Compliance Analysis Failed', {});
    this.toastService.addNotification({
        content: 'Compliance analysis failed. Please try again.',
        status: ToastNotificationStatusMap.ERROR,
    });
}
```

It does NOT touch `lastPollOutcome` because the prior `applyObservedResponse(updated)` already classified. Both the catch-all branch (`Uploaded` no history → already `'unrecognized'`) and the genuine-`Failed` branch (`Failed` → `'recognized'`) call the same helper. The difference between them is captured **declaratively** by the classifier, not duplicated across two notify helpers.

### Why this isn't just renaming `analyzeFailed`

The behavioral difference vs v1:

1. **`analyzeFailed` cannot drift** — it has no setter. Any code path that could leave a stale value is a compile error, not a test failure waiting to happen.
2. **No "clear-set enumeration"** — the classifier covers every status with one rule. Adding a new status is a 0-line change to `setResponse`-equivalent logic.
3. **Single notify helper** — `markAnalysisPolledToUnknownState` / `notifyAnalysisBackendFailed` collapse to one because they were artificially distinguished by "do I set the flag?". With the flag derived, that distinction vanishes.
4. **Dead code from PR #2035 disappears** — the explicit `analyzeFailed.set(false)` lines at `:481` and `:539` of PR #2035's `Uploaded + history` recovery branches are no longer needed (classifier handles it).

### `analysisState` derivation (unchanged)

```ts
readonly analysisState = computed<ResponseAnalysisStateEnum>(() => {
    const response = this.response();
    if (!response) return ResponseAnalysisStateEnum.Idle;

    if (this.isAnalyzing()) return ResponseAnalysisStateEnum.Analyzing;

    if (this.analyzeFailed() || response.status === ResponseStatusEnum.Failed) {
        return ResponseAnalysisStateEnum.Failed;
    }

    if (
        response.status === ResponseStatusEnum.Uploaded &&
        this.responseHasAnalysisHistory(response)
    ) {
        return ResponseAnalysisStateEnum.Stale;
    }

    if (this.responseHasAnalysisHistory(response)) {
        return ResponseAnalysisStateEnum.Complete;
    }

    return ResponseAnalysisStateEnum.Idle;
});
```

The body is unchanged. The OR is still there — but now `analyzeFailed()` is derived, so the two sides of the OR can never disagree about a stale fact.

## Assumptions

1. **`Processing` always means a fresh analysis run is underway.** The backend never emits `Processing` for a non-analysis data refresh. Same assumption as v1.
2. **`response.status === Failed` is sufficient to render `Failed` in the UI.** PRCR-1562 shipped the OR in `analysisState`.
3. **The rename merge at `saveName` preserves `status`** — backend returns a `ComplianceResponse` that includes `status`; merging with `{ ...current, ...updated }` lets `updated.status` overwrite `current.status`. If the backend ever returns a stale status on rename, classification would re-evaluate; we surface this in Open questions.
4. **Only `analyzeFailed` semantics are being tightened.** `isAnalyzing` and `response.status` semantics are out of scope.
5. **The classifier's "ambiguous" definition** — `Uploaded` without history — is the only state where we want the UI to show `Failed` from a poll/refresh outcome alone (i.e., without `response.status === Failed`). Any other "weird" status the backend invents in future should fall through to `Idle`/`Complete`/`Stale` derived from `response`, not `Failed`.

## Open questions

| # | Question | Proposed default |
|---|----------|------------------|
| 1 | Should the public read API stay named `analyzeFailed` (computed), or rename to `pollFailed` / `failedFromPoll` to match the new semantics? Template doesn't read it; tests do. | Keep `analyzeFailed` as the computed name to minimize test churn and preserve the public read API. `lastPollOutcome` is private. |
| 2 | **User-action observations: classify or reset?** When `onDocumentsChanged` (or any user-initiated refresh) observes a response, three behaviors are viable:<br>(A) **Full classifier**: write `lastPollOutcome = classify(response)`. Preserves the PR-2035 test `'keeps analyzeFailed true when onDocumentsChanged refetches a still-unrecognized response'` literally — but introduces a new regression: a user who uploads fresh docs from a `Stale` state lands on `Uploaded`-no-history and the UI flips to `Failed` (no prior catch-all required).<br>(B) **Asymmetric classifier** (clear-only): write `lastPollOutcome = 'recognized'` if the classifier returns `'recognized'`; no-op otherwise. Preserves PR-2035 test behavior AND avoids the fresh-upload regression. Two observation helpers needed.<br>(C) **Reset to `null` on user action**: write `response.set(fresh)` + `lastPollOutcome.set(null)`. Simplest semantic — `lastPollOutcome` literally tracks "poll outcomes only". Changes the PR-2035 catch-all-survives-refresh test (after reset, `analyzeFailed === false`, `analysisState === Idle` instead of `Failed`). | **Option C (default).** The PR-2035 catch-all-survives-refresh test asserts an arguably-bad UX: the user uploaded a doc (normal action), the response is `Uploaded`-no-history (normal state), but the UI still shows `Failed` because a *prior* poll cycle hit the catch-all. Resetting `lastPollOutcome` on user action gives the user a clean slate — exactly what they expect after taking an action. The test is renamed and re-asserted: `'resets analyzeFailed when onDocumentsChanged observes any response after a catch-all failure'`. If the team prefers preserving the PR-2035 behavior exactly, swap to Option B. |
| 3 | Should the rename merge at `saveName` re-classify after merging, or skip classification (status unchanged in practice)? | Skip classification. Rename is a mutation, not an observation; `response.update(merger)` writes only `response`. If the backend rename response shape ever changes to alter `status`, that's a separate concern best handled with explicit re-fetch + classify. |
| 4 | `onRunComplianceCheck` start currently does `analyzeFailed.set(false)`. The closest equivalent under the new design is `lastPollOutcome.set(null)`. Some might argue `lastPollOutcome.set('recognized')` is correct because we just kicked off a fresh attempt. | `null` (default). `'recognized'` would falsely imply we observed a terminal; `null` cleanly means "no recent poll outcome yet". |
| 5 | Should the v1 PR (#2035) be amended (force-push the same branch with this design) or closed in favor of a fresh branch? | Amend the same branch `tim/PRCR-1596/phase-1`. Cleaner PR diff once rebased; the existing PR description should be rewritten to match this plan. |

## Implementation phases

### Phase 1 — Replace writable `analyzeFailed` with derived state, classify on poll, reset on user action [FRONTEND]

```phase-meta
phase: 1
title: Derive analyzeFailed from observed poll state
tags: [FRONTEND]
repo: rohan_ui
base_branch: base
depends_on: []
files:
  - src/app/pages/compliance/components/company-detail/company-detail.component.ts
  - src/app/pages/compliance/components/company-detail/company-detail.component.spec.ts
contracts:
  - "1.1 LastPollOutcome type"
  - "1.2 lastPollOutcome signal"
  - "1.3 analyzeFailed computed (derived)"
  - "1.4 classifyPollOutcome helper"
  - "1.5 applyObservedResponse helper"
  - "1.6 notifyAnalysisFailed helper"
  - "2.1 analyzeFailed semantics (derived)"
  - "2.2 lastPollOutcome write sites (exhaustive)"
  - "3.1 Spec assertions"
verification:
  - npm run lint -- --max-warnings=0
  - npm run test:ci -- --include='**/company-detail.component.spec.ts'
```

**Goal**: Make `analyzeFailed` a `computed<boolean>` over a private `lastPollOutcome` signal so the dual-source-of-truth class for "failed render state" is structurally impossible. Classify on poll/refresh observations only; reset on user actions (rename, doc upload, run analysis) so user actions never silently introduce a `Failed` UI state.

**Steps**:

- [ ] **1.1** Add `type LastPollOutcome = 'recognized' | 'unrecognized';` at the top of `company-detail.component.ts` (below the existing local types like `RESPONSE_DETAIL_TAB_NAMES`).
  - File: `src/app/pages/compliance/components/company-detail/company-detail.component.ts`

- [ ] **1.2** Replace the writable `analyzeFailed = signal(false)` declaration at `:109` with:
  - `private readonly lastPollOutcome = signal<LastPollOutcome | null>(null);`
  - `readonly analyzeFailed = computed(() => this.lastPollOutcome() === 'unrecognized');`
  - JSDoc on `analyzeFailed`: see contracts §2.1.
  - Keep the field position adjacent to the other readonly signals so the diff stays local.

- [ ] **1.3** Add private `classifyPollOutcome(response: ComplianceResponseDetail): LastPollOutcome` helper. Returns `'unrecognized'` iff `response.status === Uploaded && !this.responseHasAnalysisHistory(response)`, otherwise `'recognized'`. See contracts §1.4 for the exact body.

- [ ] **1.4** Add private `applyObservedResponse(response: ComplianceResponseDetail): void` helper. Used **only by poll/refresh subscribers** (`refreshAndStartPollIfNeeded`, `startAnalysisPoll`):
  - `this.response.set(response)`
  - `this.lastPollOutcome.set(this.classifyPollOutcome(response))`
  - See contracts §1.5.
  - **Not used by**: initial load, saveName, or onDocumentsChanged. Those paths handle `response`/`lastPollOutcome` directly per the rule in contracts §2.2.

- [ ] **1.5** Replace `markAnalysisPolledToUnknownState` + `notifyAnalysisBackendFailed` (or, against `main`, replace `markAnalysisFailed`) with a single private `notifyAnalysisFailed(): void` helper:
  - `this.isAnalyzing.set(false)`
  - `this.fullstoryService.trackEvent('Compliance Analysis Failed', {})`
  - Same error toast (`'Compliance analysis failed. Please try again.'`, `ToastNotificationStatusMap.ERROR`).
  - **Does not touch** `lastPollOutcome` — the prior `applyObservedResponse` already classified the observation.
  - See contracts §1.6.

- [ ] **1.6** `ngOnInit` route-cleanup `tap` (currently `:209-221`):
  - Replace `this.analyzeFailed.set(false)` with `this.lastPollOutcome.set(null)`.
  - Replace `this.setResponse(null)` (PR-2035) / `this.response.set(null)` (`main`) with `this.response.set(null)` (no classifier — null isn't an observation).

- [ ] **1.7** `ngOnInit` subscribe block (currently `:256-269`):
  - Replace the `if (response)` block's `this.response.set(response)` / `this.setResponse(response)` with **`this.response.set(response)`** (intentionally bypassing the classifier — see contracts §2.1.1 for the rationale). The route-cleanup `tap` already set `lastPollOutcome.set(null)` for this navigation, so the initial state is clean.
  - Remove any remaining `else if (response.status === Failed) { ... }` branch (already removed in PR-2035).
  - Keep the `Processing` branch (sets `isAnalyzing`, starts poll).
  - **Why not classify here?** Initial loads observe a response in any state, including the user's "freshly-uploaded-never-analyzed" baseline (`Uploaded` + no history). Classifying that as `'unrecognized'` would render `Failed` on first paint, which is a regression. Only poll/refresh observations carry "we tried and saw nothing useful" semantics.

- [ ] **1.8** `saveName` subscribe (currently `:307-346`):
  - Replace `this.response.update(merger)` / `this.updateResponse(merger)` with `this.response.update((current) => current ? { ...current, ...updated } : null)` (the `main` form — mutation, not observation).
  - Do not touch `lastPollOutcome`. Rename is a mutation; it doesn't change observation state.

- [ ] **1.9** `onDocumentsChanged` (currently `:348-371`) — **Option C from Open Question 2**:
  - Both branches: set `this.response.set(...)` and then `this.lastPollOutcome.set(null)`. User actions invalidate any prior poll claim — clean slate.
  - This changes one PR-2035 test (renamed and re-asserted in step 1.18).

- [ ] **1.10** `onRunComplianceCheck` (currently `:407-441`):
  - Replace `this.analyzeFailed.set(false)` at start (line 423) with `this.lastPollOutcome.set(null)`.
  - In the `catchError` block, replace `this.analyzeFailed.set(true)` with `this.lastPollOutcome.set('unrecognized')` (no fresh response observed, so explicit set is required).
  - Keep `isAnalyzing.set(false)` and the existing toast — they stay.

- [ ] **1.11** `refreshAndStartPollIfNeeded` (currently `:443-487`):
  - Replace `this.response.set(updated)` / `this.setResponse(updated)` with `this.applyObservedResponse(updated)`.
  - `Failed` branch: call `this.notifyAnalysisFailed()` (was `markAnalysisFailed` / `notifyAnalysisBackendFailed`).
  - `Uploaded + history` recovery branch: remove the now-redundant `this.analyzeFailed.set(false)` line; `applyObservedResponse` already classified as `'recognized'`.
  - Final catch-all `else`: call `this.notifyAnalysisFailed()` (was `markAnalysisFailed` / `markAnalysisPolledToUnknownState`).

- [ ] **1.12** `startAnalysisPoll` (currently `:489-545`):
  - Replace `this.response.set(updated)` / `this.setResponse(updated)` with `this.applyObservedResponse(updated)`.
  - `Failed` branch: call `this.notifyAnalysisFailed()`.
  - `Uploaded + history` recovery branch: remove the now-redundant `this.analyzeFailed.set(false)` line.
  - Final catch-all `else`: call `this.notifyAnalysisFailed()`.

- [ ] **1.13** Delete the v1 helpers that are no longer used: `setResponse`, `updateResponse`, `markAnalysisPolledToUnknownState`, `notifyAnalysisBackendFailed`. (If implementing from `main`, just don't add them.)

- [ ] **1.14** Update existing spec `'sets analyzeFailed when polling reaches a non-processing failure state'` (currently `:333`):
  - No assertion change. The catch-all poll path classifies the observed `Uploaded`-no-history response as `'unrecognized'`, so `analyzeFailed()` is still `true`.
  - Verify it passes unchanged.

- [ ] **1.15** Update existing spec `'renders Failed state and stops polling when backend reports FAILED status'` (PR-2035 name; was `'sets analyzeFailed...'` against `main`):
  - Assertions unchanged from PR-2035: `analyzeFailed() === false`, `analysisState() === Failed`, `isAnalyzing() === false`, toast fired, `getResponse` called twice.
  - The new design produces the same result via classification: classifier returns `'recognized'` for `Failed`, `analysisState` renders `Failed` via `response.status === Failed`.

- [ ] **1.16** Update existing spec `'clears analyzeFailed when onDocumentsChanged refetches a healthy response after a catch-all failure'` (PR-2035 added):
  - Assertions unchanged: `analyzeFailed() === false`, `analysisState() === Complete`.
  - Now passes via the explicit `lastPollOutcome.set(null)` in `onDocumentsChanged`, not via the classifier.

- [ ] **1.17** Update existing spec `'clears analyzeFailed when onDocumentsChanged receives an inline healthy response after a catch-all failure'` (PR-2035 added):
  - Assertions unchanged.

- [ ] **1.18** **Rename and re-assert** existing spec `'keeps analyzeFailed true when onDocumentsChanged refetches a still-unrecognized response'` (PR-2035 added) — this is the **only spec whose assertions change** under Option C:
  - New name: `'resets analyzeFailed when onDocumentsChanged observes any response after a catch-all failure'`.
  - New assertions:
    - `expect(component.analyzeFailed()).toBeFalse();`
    - `expect(component.analysisState()).toBe(ResponseAnalysisStateEnum.Idle);` (was `Failed`).
  - Rationale: under Option C, `onDocumentsChanged` always resets `lastPollOutcome` to `null` because the user just took an action (doc upload/change) that invalidates any prior poll claim. The PR-2035 behavior (catch-all survives a non-recovery refresh) was an arbitrary design choice that produces poor UX (user uploaded a doc, but UI still shows Failed). See Open Question 2 for the alternative (Option B) if the team prefers preserving the PR-2035 behavior literally.

- [ ] **1.19** Update existing spec `'clears analyzeFailed when onDocumentsChanged refetches Uploaded with prior analysis history'` (PR-2035 added):
  - Assertions unchanged: `analyzeFailed() === false`. `analysisState() === Stale` still holds.
  - Now passes via the explicit `lastPollOutcome.set(null)` in `onDocumentsChanged`.

- [ ] **1.20** Update existing spec `'renders Failed without setting analyzeFailed on initial load with a Failed status'` (PR-2035 added):
  - Assertions unchanged. Initial load uses `response.set(response)` directly (no classifier); `lastPollOutcome` stays `null` from route-cleanup `tap`, so `analyzeFailed === false`; `analysisState === Failed` via `response.status === Failed`.

- [ ] **1.21** Rename and adjust spec `'clears stale analyzeFailed when setResponse observes Processing via onDocumentsChanged'` (PR-2035 added):
  - Rename to `'clears stale analyzeFailed when onDocumentsChanged observes Processing'` (drops the now-defunct `setResponse` reference).
  - Body unchanged. Passes via `lastPollOutcome.set(null)` in `onDocumentsChanged`.

- [ ] **1.22** Add new spec — **derived `analyzeFailed` cannot be written from outside** (smoke test for derivation):
  - Pre-set catch-all-failed state via a poll cycle.
  - Assert `analyzeFailed()` is `true`.
  - `component['lastPollOutcome'].set('recognized')` (bracket-access the private signal).
  - Assert `analyzeFailed()` is `false` immediately (computed semantics).
  - `component['lastPollOutcome'].set(null)`. Assert `false`.
  - `component['lastPollOutcome'].set('unrecognized')`. Assert `true`.
  - Documents the new contract: `analyzeFailed` is a pure function of `lastPollOutcome`.

- [ ] **1.23** Add new spec — **poll classifier treats `Failed` as `'recognized'`**:
  - `getResponse` returns `Processing` then `Failed`.
  - Trigger poll via `onRunComplianceCheck()` and `tick`.
  - Assert `component['lastPollOutcome']()` is `'recognized'`.
  - Assert `analyzeFailed()` is `false`.
  - Assert `analysisState()` is `Failed` (via `response.status === Failed`).

- [ ] **1.24** Add new spec — **`onRunComplianceCheck` catchError sets `lastPollOutcome = 'unrecognized'` without a fresh response observation**:
  - Pre-state: response is `Uploaded + history` (would classify as `'recognized'` if observed by a poll).
  - `analyzeResponse` throws.
  - Call `component.onRunComplianceCheck()`.
  - Assert `analyzeFailed()` is `true`.
  - Assert toast `'Failed to start compliance analysis. Please try again.'` fired.
  - Assert `isAnalyzing()` is `false`.

- [ ] **1.25** Add new spec — **user action via `onDocumentsChanged` does not classify (user-action reset)**:
  - Pre-state: no prior failure. `response()` is `null`.
  - Call `component.onDocumentsChanged(buildResponseDetail({ status: ResponseStatusEnum.Uploaded }))` (Uploaded + no history — the ambiguous state).
  - Assert `analyzeFailed()` is `false` (the user just took an action; we don't render Failed from it).
  - Assert `analysisState()` is `Idle`.
  - This is the spec that pins Option C — distinguishing it from a poll classifier.

- [ ] **1.26** Run verification commands listed in phase metadata.

### Phase order and parallelism

#### File-touch matrix

| Phase | Files touched |
|-------|----------------|
| 1 | `company-detail.component.ts`, `company-detail.component.spec.ts` |

#### Parallelism

Single phase → trivially sequential. No external repos. No backend or Python changes. The spec changes co-locate with the component changes.

#### Recommended order

Implement Phase 1 as a single focused PR. If amending PR #2035 on the same branch `tim/PRCR-1596/phase-1`:

1. Reset the branch to `main` (`git reset --hard origin/main`).
2. Re-apply only the changes prescribed by this plan.
3. Force-push and update the PR description to the new title/summary.

If choosing a fresh branch, close PR #2035 with a comment linking to the new PR.

### Phase context summaries

**Phase 1** — Refactor `CompanyDetailComponent` so `analyzeFailed` becomes a `computed<boolean>` over a new private `lastPollOutcome: signal<'recognized' | 'unrecognized' | null>`. Add `classifyPollOutcome(response)` (inverted predicate: `'unrecognized'` iff `Uploaded && !hasHistory`; everything else is `'recognized'`) and `applyObservedResponse(response)` that writes both signals together. Use the helper **only** in poll/refresh subscribers — initial load uses `response.set(response)` directly, `saveName` uses `response.update(merger)` directly (mutations, not observations), and `onDocumentsChanged` explicitly resets `lastPollOutcome` to `null` (user actions invalidate prior poll claims). Collapse `markAnalysisPolledToUnknownState` and `notifyAnalysisBackendFailed` into one `notifyAnalysisFailed` (side effects only — no flag write). `onRunComplianceCheck` start resets `lastPollOutcome` to `null`; its catchError sets `'unrecognized'` (no fresh response was observed). Tests: most PR-2035 assertions are preserved verbatim; one spec is renamed and re-asserted (`'keeps analyzeFailed true when onDocumentsChanged refetches a still-unrecognized response'` → `'resets analyzeFailed when onDocumentsChanged observes any response after a catch-all failure'`) — Open Question 6 documents the alternative if the team prefers preserving the PR-2035 behavior literally. Four new specs cover derivation, Failed-classifies-as-recognized, the analyze-start catchError set point, and user-action-doesn't-classify. Gotcha: dropping `analyzeFailed` writes outside the helpers is the whole point — the derivation spec exists to document that contract.

### Jira ticket

**Title**: Make `analyzeFailed` a derived signal to eliminate the dual-source-of-truth class

**Description**: Replace `CompanyDetailComponent`'s writable `analyzeFailed` signal with a `computed<boolean>` derived from a new private `lastPollOutcome: signal<'recognized' | 'unrecognized' | null>`. Route every poll/refresh response observation through `applyObservedResponse(...)` so the classifier sets `lastPollOutcome` exactly once per poll observation. User actions (rename, doc upload, analyze-start) write `lastPollOutcome` directly to `null` (or `'unrecognized'` for analyze-start API failure). Collapse the two notify helpers into one side-effect-only helper. The drift class — `analyzeFailed === true` after the response transitions to a healthy status — becomes structurally impossible because `analyzeFailed` has no setter.

**Acceptance criteria**:

- [ ] `analyzeFailed` is `readonly` and declared as `computed(() => this.lastPollOutcome() === 'unrecognized')`. No code path writes to it.
- [ ] `lastPollOutcome` is private, initialized to `null`, and set in exactly six places per contracts §2.2: route-cleanup `tap` (`null`), `onDocumentsChanged` inline+refetch (`null`), `onRunComplianceCheck` start (`null`), `onRunComplianceCheck` catchError (`'unrecognized'`), `refreshAndStartPollIfNeeded` subscribe (classifier), `startAnalysisPoll` subscribe (classifier).
- [ ] `applyObservedResponse` is called only from `refreshAndStartPollIfNeeded` and `startAnalysisPoll`. Initial load uses `response.set(response)` directly; `saveName` uses `response.update(merger)` directly; `onDocumentsChanged` writes `response.set(fresh)` + `lastPollOutcome.set(null)` explicitly.
- [ ] `classifyPollOutcome` returns `'unrecognized'` iff `status === Uploaded && !responseHasAnalysisHistory(response)`, otherwise `'recognized'`.
- [ ] A single `notifyAnalysisFailed` helper replaces `markAnalysisPolledToUnknownState` and `notifyAnalysisBackendFailed`. It fires the toast and FullStory event, sets `isAnalyzing(false)`, and does **not** touch `lastPollOutcome`.
- [ ] PR-2035's six spec additions/changes still pass with unchanged assertions, except `'keeps analyzeFailed true when onDocumentsChanged refetches a still-unrecognized response'` which is **renamed and re-asserted** per step 1.18 (Option C from Open Question 2).
- [ ] Four new specs are added: derived-signal-cannot-drift, poll-classifier-treats-Failed-as-recognized, analyze-start-catchError-sets-unrecognized, and user-action-via-onDocumentsChanged-does-not-classify.
- [ ] `npm run lint -- --max-warnings=0` passes (0 new issues introduced).
- [ ] `npm run test:ci -- --include='**/company-detail.component.spec.ts'` passes (existing + new specs).

## Branching convention

Single phase: `tim/PRCR-1596/phase-1`. Two options for migration from PR #2035:

- **Recommended: amend the existing branch.** `git reset --hard origin/main` on `tim/PRCR-1596/phase-1`, re-apply only this plan's changes, force-push, and rewrite the PR description.
- **Alternative: fresh branch.** Close PR #2035 with a comment linking to the replacement. Create `tim/PRCR-1596/phase-1-v2` (or reuse the name on a fresh local branch) and open a new PR.
