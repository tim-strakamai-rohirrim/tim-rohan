# PRCR-1596 — Contracts

Frontend-only refactor. No HTTP, DB, DTO, or event payload changes. The "contracts" here are the internal types/helper signatures and the runtime semantics of `analyzeFailed` (now a derived signal) and the underlying `lastPollOutcome` writable signal.

## Contract → Phase mapping

| Contract Section | Phase(s) | Notes |
|------------------|----------|-------|
| 1.1 `LastPollOutcome` type | 1 | New local type |
| 1.2 `lastPollOutcome` signal | 1 | New private writable signal |
| 1.3 `analyzeFailed` computed (derived) | 1 | Converted from writable to derived |
| 1.4 `classifyPollOutcome` helper | 1 | New private helper |
| 1.5 `applyObservedResponse` helper | 1 | New private helper — poll subscribers only |
| 1.6 `notifyAnalysisFailed` helper | 1 | Replaces both v1 notify helpers |
| 2.1 `analyzeFailed` semantics (derived) | 1 | Behavioral contract on the read API |
| 2.2 `lastPollOutcome` write sites | 1 | Behavioral contract on the underlying signal |
| 2.3 `analysisState` derivation (unchanged) | — | For reference |
| 3.1 Spec assertions | 1 | Test-level contract |

---

## 1. Internal types and helper signatures

All new types and helpers live in `CompanyDetailComponent` (`src/app/pages/compliance/components/company-detail/company-detail.component.ts`). All helpers are `private`. The only **public** surface is the read-only `analyzeFailed` computed signal (consumed by tests and `analysisState`).

### 1.1 `LastPollOutcome` type

```ts
/**
 * Outcome of the most recent response observation in this component session.
 *
 * - `'recognized'`: the observation landed on a status we know how to render
 *   from `response` directly (Processing, AnalysisComplete, Reviewed, Approved,
 *   Failed, or Uploaded with prior analysis history).
 * - `'unrecognized'`: the observation landed on an ambiguous state we cannot
 *   render meaningfully — currently only `Uploaded` without any analysis
 *   history, which we treat as "the polling/refresh tick saw something
 *   inert and there's nothing for the UI to do but signal a failure".
 *   Also set explicitly by `onRunComplianceCheck` catchError when an API
 *   error prevents the response from ever transitioning.
 * - `null`: no recent observation outcome (initial, post-reset, or after
 *   `onRunComplianceCheck` start).
 */
type LastPollOutcome = 'recognized' | 'unrecognized';
```

Declare immediately above the local `RESPONSE_DETAIL_TAB_NAMES` constant or near the top of the file. Type alias (not enum) — three values total including `null`, no need for runtime enum overhead.

### 1.2 `lastPollOutcome` signal

```ts
/**
 * Underlying writable signal that drives `analyzeFailed`. See §2.2 for the
 * exhaustive list of write sites. The rule of thumb:
 *   - Poll/refresh observations write via the classifier (`applyObservedResponse`).
 *   - User actions and session boundaries reset to `null`.
 *   - The only non-classifier `'unrecognized'` write is `onRunComplianceCheck`
 *     catchError (no fresh response was observed; the API call itself failed).
 *
 * No other code path writes to this signal.
 */
private readonly lastPollOutcome = signal<LastPollOutcome | null>(null);
```

### 1.3 `analyzeFailed` computed (derived)

```ts
/**
 * Whether the UI should render the response in a "failed" state from a
 * polling/refresh outcome alone (independent of `response.status === Failed`,
 * which `analysisState` ORs separately).
 *
 * Derived from `lastPollOutcome` — has no setter. Drift between
 * `analyzeFailed` and the response state is structurally impossible because
 * every observation passes through `applyObservedResponse`, which sets
 * `lastPollOutcome` based on the classifier.
 */
readonly analyzeFailed = computed(() => this.lastPollOutcome() === 'unrecognized');
```

This **replaces** the writable `analyzeFailed = signal(false)` declaration. Same name preserves the public read API for tests and the `analysisState` computed.

### 1.4 `classifyPollOutcome` helper

```ts
/**
 * Classifies a poll/refresh response observation into a `LastPollOutcome`.
 * An observation is `'unrecognized'` iff the response is in the only
 * genuinely-ambiguous state: `Uploaded` with no prior analysis history.
 * Every other status — including `Failed` — is `'recognized'` because
 * `analysisState` renders those states directly from `response`
 * (and `response.status === Failed`).
 *
 * Inverted-by-default predicate: any new `ResponseStatus` enum value will be
 * classified `'recognized'`. This is safe by default — new states fall
 * through to `analysisState`'s `Idle`/`Complete`/`Stale` paths rather than
 * silently surfacing as `Failed`.
 *
 * NOTE: This is called **only** from poll/refresh subscribers, not from
 * user-action paths. User actions (`onDocumentsChanged`, `saveName`,
 * `onRunComplianceCheck`) handle `lastPollOutcome` explicitly per §2.2.
 */
private classifyPollOutcome(response: ComplianceResponseDetail): LastPollOutcome {
    const isAmbiguous =
        response.status === ResponseStatusEnum.Uploaded &&
        !this.responseHasAnalysisHistory(response);
    return isAmbiguous ? 'unrecognized' : 'recognized';
}
```

`responseHasAnalysisHistory` is the existing private helper at the bottom of the component (`:635-642`). No change to its body.

### 1.5 `applyObservedResponse` helper

```ts
/**
 * Apply a poll/refresh observed response. Writes both `response` and
 * `lastPollOutcome` together so the derived `analyzeFailed` signal always
 * reflects the observation's classification.
 *
 * **Call this only from poll/refresh subscribers** (`refreshAndStartPollIfNeeded`,
 * `startAnalysisPoll`). Initial load, `saveName`, and `onDocumentsChanged`
 * write `response` and (where needed) `lastPollOutcome` directly per §2.2.
 */
private applyObservedResponse(response: ComplianceResponseDetail): void {
    this.response.set(response);
    this.lastPollOutcome.set(this.classifyPollOutcome(response));
}
```

### 1.6 `notifyAnalysisFailed` helper

```ts
/**
 * Side-effect-only failure notification: stops the in-flight flag, fires the
 * FullStory event, and shows the user-facing toast. Does **not** touch
 * `lastPollOutcome` — classification happens at the observation site
 * (`applyObservedResponse`), not at the notification site. The single helper
 * is correct for both the genuine-`Failed` and catch-all unknown-state
 * branches because they differ only in their *prior observation*, not in
 * their notification behavior.
 */
private notifyAnalysisFailed(): void {
    this.isAnalyzing.set(false);
    this.fullstoryService.trackEvent('Compliance Analysis Failed', {});
    this.toastService.addNotification({
        content: 'Compliance analysis failed. Please try again.',
        status: ToastNotificationStatusMap.ERROR,
    });
}
```

This **replaces** both v1 helpers:
- `markAnalysisPolledToUnknownState` (set `analyzeFailed = true` + side effects) — the flag write is dropped because the classifier already did the equivalent via the prior `applyObservedResponse`.
- `notifyAnalysisBackendFailed` (side effects only) — semantically identical to the new helper.

Same FullStory event name (`'Compliance Analysis Failed'`) and same toast content as the v1 helpers, so downstream FullStory dashboards and user-visible copy are unchanged.

---

## 2. Behavioral contracts

### 2.1 `analyzeFailed` semantics (derived)

| State | `analyzeFailed` value | Driven by |
|-------|----------------------|-----------|
| Initial state (before any observation) | `false` | `lastPollOutcome === null` |
| Initial load with any status (incl. `Failed`, incl. `Uploaded`-no-history) | `false` | Initial load bypasses the classifier (see §2.1.1); `lastPollOutcome` stays at the route-cleanup `null` |
| Poll/refresh observes `Processing` / `AnalysisComplete` / `Reviewed` / `Approved` / `Failed` / `Uploaded + history` | `false` | Classifier returns `'recognized'` |
| Poll/refresh observes `Uploaded` without history | `true` | Classifier returns `'unrecognized'` |
| `onRunComplianceCheck` start | `false` | `lastPollOutcome.set(null)` |
| `onRunComplianceCheck` catchError | `true` | `lastPollOutcome.set('unrecognized')` explicitly |
| `onDocumentsChanged` observes any response | `false` | `lastPollOutcome.set(null)` — user action invalidates prior poll claim (Option C; see plan Open Question 2) |
| `saveName` rename success | unchanged | Rename is a mutation, not an observation — does not write `lastPollOutcome` |
| Route navigation to a new `responseId` | `false` | `lastPollOutcome.set(null)` in cleanup `tap` |

**One-line definition (drop into JSDoc on `analyzeFailed` — see §1.3)**:

> `analyzeFailed` is `true` iff the most recent poll/refresh observation in the current session landed on the ambiguous state (`Uploaded` without history) or an analyze-start API call failed before any response could be observed. User actions (rename, doc upload, run-analysis) reset this signal; renders consult `response.status === Failed` separately via `analysisState`.

#### 2.1.1 The `Uploaded`-no-history initial-load corner case

A response that the user navigates to with `status === Uploaded` and no analysis history is the "user has just uploaded but never run analysis" state. Today (pre- and post-PR-2035), this lands in `Idle` via `analysisState` because `isAnalyzing === false`, `analyzeFailed === false`, no history. If `applyObservedResponse` were also used on initial load, the classifier would write `'unrecognized'` and `analysisState` would flip to `Failed` — a regression.

**Rule**: classification runs on poll/refresh observations only. Initial load uses `response.set(response)` directly; the route-cleanup `lastPollOutcome.set(null)` from the prior `tap` keeps the flag clean.

Initial-load wiring inside the `ngOnInit` `subscribe` block:
```ts
if (response) {
    this.response.set(response);
    if (response.status === ResponseStatusEnum.Processing) {
        this.isAnalyzing.set(true);
        this.startAnalysisPoll(this.projectId(), this.responseId());
    }
}
```

`refreshAndStartPollIfNeeded` and `startAnalysisPoll` use `applyObservedResponse` because those are the poll/refresh paths where "we polled and saw nothing useful" is a meaningful claim.

#### 2.1.2 Why `onDocumentsChanged` resets instead of classifying (Option C)

A user action (uploading or removing documents) creates a new state-of-the-world that invalidates any prior poll claim. Three scenarios make the case for `lastPollOutcome.set(null)` rather than calling the classifier:

1. **Catch-all + refresh observes healthy response** — user uploaded, response now `AnalysisComplete`. Both options clear `analyzeFailed`. No difference.
2. **No prior failure + refresh observes `Uploaded`-no-history** — user replaced all docs from a `Stale` state, wiping history. Under a full classifier, this newly observed `Uploaded`-no-history would write `'unrecognized'` and render `Failed` — but the user just took a perfectly normal action and the UI should show `Idle`. Resetting `lastPollOutcome` produces the correct render.
3. **Catch-all + refresh observes still-`Uploaded`-no-history** — same status as before. Under a full classifier, `lastPollOutcome` stays `'unrecognized'` and the UI stays `Failed`. Under reset-on-user-action, `lastPollOutcome` clears to `null` and the UI shows `Idle`. The PR-2035 test asserted the former; the latter is arguably better UX because the user just took action and the prior poll claim is stale. The PR-2035 spec is renamed and re-asserted in §3.1.4.

Plan Open Question 2 documents the alternative (Option B — asymmetric classifier) if the team prefers preserving PR-2035 behavior in scenario 3 literally.

### 2.2 `lastPollOutcome` write sites (exhaustive)

The following table is the **complete** list of code paths that write `lastPollOutcome`. Any future PR that introduces a write outside this list must update §2.2 with justification.

| # | Site | Value | Reason |
|---|------|-------|--------|
| 1 | `ngOnInit` route-cleanup `tap` | `null` | New responseId → clean slate |
| 2 | `ngOnInit` subscribe initial load | (not written) | Initial loads bypass the classifier; see §2.1.1 |
| 3 | `saveName` rename success | (not written) | Rename is a mutation, not an observation |
| 4 | `onDocumentsChanged` inline fresh | `null` | User action invalidates prior poll claim; see §2.1.2 |
| 5 | `onDocumentsChanged` refetch | `null` | Same |
| 6 | `onRunComplianceCheck` start | `null` | New attempt → clean slate |
| 7 | `onRunComplianceCheck` catchError | `'unrecognized'` (explicit) | Analyze-start API call failed; no fresh response observation possible |
| 8 | `refreshAndStartPollIfNeeded` `subscribe` | result of classifier (via `applyObservedResponse`) | Poll observation |
| 9 | `startAnalysisPoll` `subscribe` | result of classifier (via `applyObservedResponse`) | Poll observation |

### 2.3 `analysisState` derivation (unchanged — for reference)

Reproduced from `company-detail.component.ts:143-169`. No code change in this phase; included to confirm the `Failed` rendering path is unaffected:

```ts
readonly analysisState = computed<ResponseAnalysisStateEnum>(() => {
    const response = this.response();
    if (!response) {
        return ResponseAnalysisStateEnum.Idle;
    }

    if (this.isAnalyzing()) {
        return ResponseAnalysisStateEnum.Analyzing;
    }

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

The body is unchanged. `analyzeFailed()` now resolves to a derived value; the OR is preserved because `response.status === Failed` is a separate (server-truth) signal that `analyzeFailed` deliberately classifies as `'recognized'`.

---

## 3. Test contract

### 3.1 Spec assertions

#### 3.1.1 Toast strings (literal — agents will match against these)

| Origin | Status | Content |
|--------|--------|---------|
| `notifyAnalysisFailed` | `ToastNotificationStatusMap.ERROR` | `'Compliance analysis failed. Please try again.'` |
| `onRunComplianceCheck` analyze catchError | `ToastNotificationStatusMap.ERROR` | `'Failed to start compliance analysis. Please try again.'` |
| `onDocumentsChanged` refetch catchError | `ToastNotificationStatusMap.ERROR` | `'Failed to refresh documents.'` |
| `ngOnInit` `getResponseForReview` catchError | `ToastNotificationStatusMap.ERROR` | `'Unable to load response. Returning to responses list.'` |
| `ngOnInit` `getProject` catchError | `ToastNotificationStatusMap.ERROR` | `'Unable to load project details.'` |
| `saveName` catchError | `ToastNotificationStatusMap.ERROR` | `'Failed to update response name.'` |

(Last five unchanged — listed only to confirm they are untouched.)

#### 3.1.2 FullStory events (unchanged — for reference)

| Event name | Properties | When |
|------------|------------|------|
| `'Compliance Analysis Failed'` | `{}` | `notifyAnalysisFailed` (fires for both genuine-`Failed` and catch-all branches and `onRunComplianceCheck` catchError) |
| `'Compliance Analysis Started'` | `{}` | `onRunComplianceCheck` start |
| `'Compliance Analysis Completed'` | `{ checkCount: number }` | `startAnalysisPoll` on `AnalysisComplete` or success status |
| `'Compliance Response Tab Changed'` | `{ tabName: string }` | `onTabChange` |

Note: `onRunComplianceCheck` catchError today does **not** fire `'Compliance Analysis Failed'` — only the toast. The new design preserves that (it sets `lastPollOutcome` and fires the toast, but does not call `notifyAnalysisFailed`). This is consistent with current behavior.

#### 3.1.3 Existing specs preserved with unchanged assertions

The following PR-2035 specs continue to pass with **unchanged assertions**:

| Spec name | Why it passes unchanged |
|-----------|-------------------------|
| `'sets analyzeFailed when polling reaches a non-processing failure state'` | Catch-all poll observes `Uploaded`-no-history → `applyObservedResponse` classifier returns `'unrecognized'` → `analyzeFailed() === true` |
| `'renders Failed state and stops polling when backend reports FAILED status'` | Poll observes `Failed` → classifier returns `'recognized'` → `analyzeFailed() === false`; `analysisState() === Failed` via `response.status === Failed` |
| `'clears analyzeFailed when onDocumentsChanged refetches a healthy response after a catch-all failure'` | `onDocumentsChanged` writes `lastPollOutcome.set(null)` → `analyzeFailed() === false` |
| `'clears analyzeFailed when onDocumentsChanged receives an inline healthy response after a catch-all failure'` | Same — inline branch writes `lastPollOutcome.set(null)` |
| `'clears analyzeFailed when onDocumentsChanged refetches Uploaded with prior analysis history'` | Same — `onDocumentsChanged` writes `lastPollOutcome.set(null)`; `analysisState === Stale` from `response` |
| `'renders Failed without setting analyzeFailed on initial load with a Failed status'` | Initial load uses `response.set(response)` directly (no classifier — see §2.1.1); `analyzeFailed` stays `false`; `analysisState() === Failed` via `response.status === Failed` |

#### 3.1.4 Existing spec renamed AND re-asserted (Option C behavior change)

The PR-2035 spec `'keeps analyzeFailed true when onDocumentsChanged refetches a still-unrecognized response'` is renamed and its assertions are flipped. This is the **only** PR-2035 spec whose assertions change under this plan.

```ts
it('resets analyzeFailed when onDocumentsChanged observes any response after a catch-all failure', fakeAsync(() => {
    fixture.detectChanges();

    // Pre-state: catch-all-failed via a Processing → Uploaded-no-history poll cycle.
    complianceApi.getResponse.and.returnValues(
        of(buildResponseDetail({ status: ResponseStatusEnum.Processing })),
        of(buildResponseDetail({ status: ResponseStatusEnum.Uploaded })),
    );
    component.onRunComplianceCheck();
    tick(0);
    tick(15000);

    expect(component.analyzeFailed()).toBeTrue();

    // User action: refetch observes still-Uploaded-no-history.
    complianceApi.getResponseForReview.and.returnValue(
        of(buildResponseDetail({ status: ResponseStatusEnum.Uploaded })),
    );

    component.onDocumentsChanged(null);

    expect(component.analyzeFailed()).toBeFalse();
    expect(component.analysisState()).toBe(ResponseAnalysisStateEnum.Idle);
}));
```

Rationale: the user just took an action (uploaded/changed docs). Whatever weird state a prior poll observed is no longer relevant. Showing `Failed` here was an arbitrary PR-2035 choice with poor UX. See plan Open Question 2 for the alternative (Option B — asymmetric classifier — preserves PR-2035 behavior literally).

#### 3.1.5 Existing spec renamed only (no assertion change)

| Old name | New name |
|----------|----------|
| `'clears stale analyzeFailed when setResponse observes Processing via onDocumentsChanged'` | `'clears stale analyzeFailed when onDocumentsChanged observes Processing'` |

Body unchanged. Rename drops the defunct `setResponse` reference.

#### 3.1.6 New specs (Phase 1 acceptance)

**Spec A — `analyzeFailed` is derived and cannot drift from `lastPollOutcome`**

```ts
it('keeps analyzeFailed in sync with lastPollOutcome — derived, no drift', fakeAsync(() => {
    fixture.detectChanges();

    // Pre-state: catch-all-failed via poll
    complianceApi.getResponse.and.returnValues(
        of(buildResponseDetail({ status: ResponseStatusEnum.Processing })),
        of(buildResponseDetail({ status: ResponseStatusEnum.Uploaded })),
    );
    component.onRunComplianceCheck();
    tick(0);
    tick(15000);

    expect(component.analyzeFailed()).toBeTrue();

    // eslint-disable-next-line @typescript-eslint/dot-notation
    component['lastPollOutcome'].set('recognized');
    expect(component.analyzeFailed()).toBeFalse();

    // eslint-disable-next-line @typescript-eslint/dot-notation
    component['lastPollOutcome'].set(null);
    expect(component.analyzeFailed()).toBeFalse();

    // eslint-disable-next-line @typescript-eslint/dot-notation
    component['lastPollOutcome'].set('unrecognized');
    expect(component.analyzeFailed()).toBeTrue();
}));
```

**Spec B — poll classifier treats `Failed` as `'recognized'`**

```ts
it('classifies a polled Failed status as recognized and renders Failed via response.status', fakeAsync(() => {
    fixture.detectChanges();

    complianceApi.getResponse.and.returnValues(
        of(buildResponseDetail({ status: ResponseStatusEnum.Processing })),
        of(buildResponseDetail({ status: ResponseStatusEnum.Failed })),
    );

    component.onRunComplianceCheck();
    tick(0);
    tick(15000);

    // eslint-disable-next-line @typescript-eslint/dot-notation
    expect(component['lastPollOutcome']()).toBe('recognized');
    expect(component.analyzeFailed()).toBeFalse();
    expect(component.analysisState()).toBe(ResponseAnalysisStateEnum.Failed);
}));
```

**Spec C — `onRunComplianceCheck` catchError sets `lastPollOutcome = 'unrecognized'` without an observation**

```ts
it('sets analyzeFailed when onRunComplianceCheck fails to start the analysis API call', () => {
    complianceApi.getResponseForReview.and.returnValue(
        of(
            buildResponseDetail({
                status: ResponseStatusEnum.Uploaded,
                summary: {
                    documentCount: 1,
                    totalCheckCount: 3,
                    reviewedCheckCount: 0,
                    compliantCount: 0,
                    nonCompliantCount: 0,
                    notApplicableCount: 0,
                    progressPercent: 0,
                    complianceScore: 100,
                },
            }),
        ),
    );
    fixture.detectChanges();

    complianceApi.analyzeResponse.and.returnValue(
        throwError(() => new Error('analyze rejected')),
    );

    component.onRunComplianceCheck();

    expect(component.analyzeFailed()).toBeTrue();
    expect(component.isAnalyzing()).toBeFalse();
    expect(toastService.addNotification).toHaveBeenCalledWith({
        content: 'Failed to start compliance analysis. Please try again.',
        status: ToastNotificationStatusMap.ERROR,
    });
});
```

This pins the **only** non-classifier `'unrecognized'` write site. Without it, a future contributor who removes the explicit `lastPollOutcome.set('unrecognized')` line in the catchError handler would silently regress the analyze-start-fails-from-stale case.

**Spec D — user action via `onDocumentsChanged` does not classify (Option C contract)**

```ts
it('does not flip analyzeFailed when onDocumentsChanged observes the ambiguous Uploaded-no-history state', () => {
    complianceApi.getResponseForReview.and.returnValue(
        of(buildResponseDetail({ status: ResponseStatusEnum.AnalysisComplete })),
    );
    fixture.detectChanges();

    expect(component.analyzeFailed()).toBeFalse();

    // User uploads/changes docs; backend reports a fresh Uploaded-no-history
    // state. Under a poll classifier, this would write 'unrecognized'.
    // Under Option C (reset-on-user-action), `analyzeFailed` stays `false`.
    component.onDocumentsChanged(
        buildResponseDetail({ status: ResponseStatusEnum.Uploaded }),
    );

    expect(component.analyzeFailed()).toBeFalse();
    expect(component.analysisState()).toBe(ResponseAnalysisStateEnum.Idle);
});
```

This is the spec that pins Option C — it would FAIL under Option B (asymmetric classifier) only if Option B chose to write `'unrecognized'` on this path, which it would not (Option B is also clear-only). Both Option C and Option B pass this spec; Option A (full classifier on user actions) fails it. The spec exists to document that user actions never silently introduce a `Failed` UI state.

---

## 4. Out of scope (explicit non-contract)

- No HTTP endpoint changes.
- No DTO or backend type changes (`ComplianceResponseDetail`, `ResponseStatus`, `ResponseStatusEnum` unchanged).
- No new database columns or migrations.
- No template (`.html`) or stylesheet (`.scss`) changes — `analysisState` consumers in the template see no behavioral difference.
- No changes to `ComplianceResponsesStateService` or any sibling component.
- No backend Service Bus or event payload changes.
- No FullStory event renames or property additions.
- No new toast strings.
- No changes to `analysisState`'s body (the `OR` between `analyzeFailed()` and `response.status === Failed` is preserved exactly).
- No changes to the `analysisSuccessStatuses` set — it is no longer referenced by the new classifier (the inverted predicate covers the same logical space), but other code paths still use it.
