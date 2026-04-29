# PRCR-1425 — Manual QA Test Plan

**PR:** [#1913 — Compliance Add Fullstory analytics tracking](https://github.com/rohancapture/rohan_ui/pull/1913)
**Branch:** `feature/abajwa/PRCR-1425`
**Scope:** Compliance module only. Fullstory event instrumentation + `data-analytics-id` DOM attributes. Two events renamed, one duplicate event removed.

---

## What Changed (tester read this first)

This PR is **instrumentation-only** — it does not change any user-facing behavior. The risks are:

1. A tracked action no longer works correctly because the wiring was disturbed.
2. An expected `data-analytics-id` is missing from the DOM.
3. An expected Fullstory event is missing, fires with the wrong name, or has the wrong payload.
4. A renamed event is still emitted under the old name, or is double-emitted.
5. The removed duplicate `'Compliance View Project Clicked'` event now fires twice.

**Therefore every test case below has TWO checks:**

- **Functional** — the action still works as before (no regression).
- **Tracking** — the expected DOM attribute is present AND the expected Fullstory event fires with the correct name and payload.

---

## Prerequisites

| Item             | Required                                                                                                                                                      |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Test environment | Staging or local dev with Fullstory enabled (`environment.production` or whatever flag gates Fullstory)                                                       |
| Browser          | Chrome with DevTools                                                                                                                                          |
| Fullstory access | Login + access to the relevant Fullstory org so events can be inspected in **DevTools → Network** OR in the Fullstory **Live** session view                   |
| Test user        | A user that can create/edit/delete Compliance projects                                                                                                        |
| Test data        | At least 2 active Compliance projects (one with responses already analysed, one with responses not yet analysed) and 1 archived project. Pre-stage if needed. |
| Sample upload    | One valid PDF/DOCX response file ready to upload                                                                                                              |

### How to verify a Fullstory event fired

You have three options — pick whichever is easiest in your env:

1. **Fullstory Live / Sessions view** — open your active session, watch the event stream, confirm event name + payload appear within ~5 seconds of the action.
2. **DevTools → Network** — filter by `fullstory` or `fs.com`. Each `trackEvent` call posts a `bundle` request whose payload contains the event name and properties. Inspect the JSON.
3. **DevTools → Console** — `window.FS` is the Fullstory client. Before each test, run:
   ```js
   const _orig = window.FS.event;
   window.__fsEvents = [];
   window.FS.event = (n, p) => {
     window.__fsEvents.push({ n, p });
     return _orig.call(window.FS, n, p);
   };
   ```
   Then after the action: `window.__fsEvents` shows the latest events. Reset between tests with `window.__fsEvents = []`.

### How to verify a `data-analytics-id` attribute

In DevTools → Elements, inspect the target element and confirm `data-analytics-id="<expected_value>"` is present on the rendered DOM node (or, for components, on the component's host element).

---

## Test Matrix

The 13 instrumentation points + 2 renames + 1 removal = **16 test cases**. Plus 2 regression sanity checks at the end.

Legend: ✅ = pass criteria. ❌ = fail criteria.

---

### TC-01 — Project Card: View Project (active)

**Where:** Compliance Landing (`/compliance`) → click any active project card's primary action ("View Project").

**Functional**

- ✅ Navigates to the project overview page (`/compliance/:projectId`).

**Tracking**

- ✅ Project card host element has `data-analytics-id="compliance_view_project_button"`.
- ✅ Fullstory event fires **once**: name `Compliance View Project Clicked`, properties `{}` (no `projectId` field — this was intentionally dropped).
- ❌ Fails if the event fires twice (regression of the removed duplicate from `compliance-landing.component.ts`).
- ❌ Fails if the event fires under any old name.

---

### TC-02 — Project Card: Restore Project (archived)

**Where:** Compliance Landing → switch to **Archived** view → click an archived project card's primary action ("Restore to My Projects").

**Functional**

- ✅ Project moves from archived back to active list.

**Tracking**

- ✅ Project card host element has `data-analytics-id="compliance_restore_project_button"` (computed value flips when archived).
- ✅ Fullstory event fires **once**: `Compliance Restore Project Clicked`, properties `{}`.

---

### TC-03 — Project Overview: Edit Project

**Where:** Open any project → click **Edit Project**.

**Functional**

- ✅ Navigates to `/compliance/create?mode=edit&projectId=...`.

**Tracking**

- ✅ Fullstory event fires: `Compliance Edit Project Clicked`, properties `{}`.

---

### TC-04 — Project Overview: Open Compliance Creator

**Where:** Project overview → click whatever button opens the compliance list creator (label depends on list status).

**Functional**

- ✅ Navigates to the compliance creator route. If list status is `InProgress`, the processing spinner shows.

**Tracking**

- ✅ Fullstory event fires: `Compliance Open Creator Clicked`, properties `{}`.

---

### TC-05 — Project Overview: Open Compliance Checklist

**Where:** Project overview → click button to open the checklist.

**Functional**

- ✅ Navigates to `/compliance/:projectId/compliance-checklist`.

**Tracking**

- ✅ Fullstory event fires: `Compliance Open Checklist Clicked`, properties `{}`.

---

### TC-06 — Compliance List Creator: Create Item

**Where:** Compliance list creator → add a new item via the manual create flow.

**Functional**

- ✅ New item appears in the list.

**Tracking**

- ✅ Fullstory event fires: `Compliance Item Created`, properties `{}`.
- Note: this PR adds a `compliance_create_item_button` constant but does **not** add the `data-analytics-id` attribute to a button in the template. **Do NOT fail the case if the attribute is absent in the DOM** — this is by design today (selector is only used in the trackEvent call). Flag as a follow-up only.

---

### TC-07 — Compliance List Creator: Delete Item

**Where:** Compliance list creator → on any compliance item card, click the trash icon → confirm deletion in the modal.

**Functional**

- ✅ Item is removed from the list after confirming.
- ✅ If the user **cancels** the delete confirmation modal, the item remains AND no event fires.

**Tracking**

- ✅ Trash icon button has `data-analytics-id="compliance_delete_item_button"` (inspect the `<button class="icon-button delete">`).
- ✅ Fullstory event fires **only after confirmation**: `Compliance Item Deleted`, properties `{}`.
- ❌ Fails if event fires when the user cancels the modal.

---

### TC-08 — Compliance List Creator: Finish Review

**Where:** Compliance list creator → click **Finish Review** (or equivalent that triggers `onContinue`/finish flow).

**Functional**

- ✅ Navigates to `/compliance/:projectId/compliance-checklist`.

**Tracking**

- ✅ Fullstory event fires: `Compliance Finish Review Clicked`, properties `{ pendingCount: <number> }` where `pendingCount` matches the visible count of pending items (test once with `pendingCount = 0` and once with a non-zero value if possible).

---

### TC-09 — Checklist Table: Download CSV

**Where:** Compliance checklist page → click **Download** button (visible in `checklist` mode).

**Functional**

- ✅ A CSV file downloads with the expected rows.

**Tracking**

- ✅ Download button has `data-analytics-id="compliance_download_csv_button"`.
- ✅ Fullstory event fires: `Compliance Checklist Downloaded`, properties `{ itemCount: <number> }` where `itemCount` equals the number of currently filtered rows (apply a filter first to verify the count matches the **filtered**, not total, list).

---

### TC-10 — Checklist Table: Complete Checklist

**Where:** Compliance checklist page (mode = checklist) → click **Complete Checklist**.

**Functional**

- ✅ If there are pending review items, the existing "items still pending" warning behavior is unchanged.
- ✅ If clean, the existing completion flow proceeds.

**Tracking**

- ✅ Button has `data-analytics-id="compliance_complete_checklist_button"`.
- ✅ Fullstory event fires: `Compliance Checklist Complete Clicked`, properties `{ totalItems: <number> }` where `totalItems` equals the unfiltered row count.

---

### TC-11 — Checklist Table: Complete Review

**Where:** Compliance checklist page (mode = review, all items reviewed) → click **Complete Review**.

**Functional**

- ✅ Confirmation modal opens. Existing complete-review flow unchanged.
- ✅ Button is disabled when not all items reviewed OR while saving — clicking should do nothing AND not fire the event.

**Tracking**

- ✅ Button has `data-analytics-id="compliance_complete_review_button"`.
- ✅ Fullstory event fires **only when click is allowed**: `Compliance Review Complete Clicked`, properties `{ totalChecks: <number> }`.
- ❌ Fails if event fires while button is disabled.

---

### TC-12 — Response Detail: Run Compliance + Analysis Lifecycle

**Where:** Open a response in `Compliance Review` tab where status allows re-run → click **Re-Run Compliance**.

**Functional**

- ✅ Analysis starts (loading/spinner state). Polling kicks off.
- ✅ On successful completion, success toast appears.
- ✅ On failure, failure toast appears and the failure flag is set.

**Tracking — Start**

- ✅ Re-Run Compliance button has `data-analytics-id="compliance_run_compliance_button"`.
- ✅ Fullstory event fires immediately: `Compliance Analysis Started`, properties `{}`.
- ❌ Fails if the event fires when `projectId` or `responseId` is missing (it should early-return without tracking — per the diff the trackEvent is **after** the early return).

**Tracking — Completion (success path)**

- ✅ When polling lands on `AnalysisComplete` (or any other success status in `analysisSuccessStatuses`), Fullstory event fires: `Compliance Analysis Completed`, properties `{ checkCount: <number> }`.
- ❌ Fails if the event fires twice (the code has two branches that both emit it — verify only one path runs per analysis run).

**Tracking — Completion (failure path)**

- ✅ When the analysis fails, Fullstory event fires: `Compliance Analysis Failed`, properties `{}`.
- ❌ Fails if `Compliance Analysis Completed` also fires on the failure path.

---

### TC-13 — Response Detail: Tab Group

**Where:** Open a response → click each of the 3 tabs in turn: Compliance Review, Document Details, Response Audit.

**Functional**

- ✅ Selected tab content renders. URL query param updates (existing behavior).

**Tracking**

- ✅ The `<mat-tab-group>` element has `data-analytics-id="compliance_response_tab_group"`.
- ✅ For each tab change, Fullstory event fires: `Compliance Response Tab Changed`, properties `{ tabName: "Compliance Review" | "Document Details" | "Response Audit" }`.
- ✅ The tabName matches exactly the friendly name from `RESPONSE_DETAIL_TAB_NAMES` (note exact casing).
- ❌ Fails if `tabName` is empty string or numeric index.
- ❌ Fails if event fires on initial render (only on user-driven change).

---

### TC-14 — Evidence Viewer: Determination Change

**Where:** Open a compliance check in evidence viewer → click each determination chip (e.g. Compliant / Non-Compliant / etc.).

**Functional**

- ✅ Determination updates and persists via API call.

**Tracking**

- ✅ Chip group container has `data-analytics-id="compliance_evidence_determination_chip_group"`.
- ✅ Fullstory event fires for each chip click: `Compliance Determination Changed`, properties `{ userDetermination: "<the chosen determination value>" }`.
- ✅ If the chosen determination is null/undefined for some reason, payload should still be `{ userDetermination: "" }` (empty string fallback per `?? ''`).

---

### TC-15 — Evidence Viewer: Previous / Next Navigation

**Where:** Evidence viewer with multiple checks → click the **Previous** arrow, then the **Next** arrow.

**Functional**

- ✅ The current check changes accordingly. Disabled state respected at the boundaries.

**Tracking — DOM**

- ✅ Previous arrow has `data-analytics-id="compliance_evidence_nav_previous"`.
- ✅ Next arrow has `data-analytics-id="compliance_evidence_nav_next"`.

**Tracking — Events**

- ✅ Click Previous → event `Compliance Evidence Navigate Previous`, properties `{ fromIndex: <current index BEFORE the navigation> }`.
- ✅ Click Next → event `Compliance Evidence Navigate Next`, properties `{ fromIndex: <current index BEFORE the navigation> }`.
- ❌ Fails if `fromIndex` reflects the new index instead of the source.
- ❌ Fails if the event fires when the button is at a boundary and the click is blocked (out-of-range guard runs **before** the trackEvent in the diff — verify it does not fire).

---

### TC-16 — Renamed Events

These two events were renamed; the **old name must no longer appear** anywhere.

**TC-16a — Responses Uploaded (old: `RESPONSES_UPLOADED`)**

**Where:** Project responses page → upload one or more response files such that `summary.createdCount > 0`.

**Functional**

- ✅ Files upload, success toast shown.

**Tracking**

- ✅ Fullstory event fires: `Compliance Responses Uploaded`, properties `{ count: <number> }`.
- ❌ **Critical fail** if `RESPONSES_UPLOADED` (old name) appears.

**TC-16b — Compliance List Started (old: `COMPLIANCE_LIST_STARTED`)**

**Where:** Create project wizard → finish a project save where the document library changed. There is no separate "start processing" button; document processing is triggered automatically after the wizard saves successfully.

**How to trigger it**

Option A — new project:

1. Go to `/compliance/create`.
2. Fill out the required **Base Information** fields.
3. Upload at least one source document in **Document Library**.
4. Click **Next** to reach the Preview step.
5. Click the Preview step's finish button (`finishButtonLabel()` in code; label may vary by mode).

Option B — existing project:

1. Open an existing project's overview page.
2. Click **Edit Project**.
3. Add a new source document or remove an existing source document.
4. Click **Next** to reach the Preview step.
5. Click the Preview step's finish button.
6. If the **Re-run compliance after saving?** modal appears, click **Continue**.

The event is emitted only after `processDocuments(projectId, true)` succeeds. It will not fire if:

- No documents changed.
- The project is already processing.
- The processing request returns `409`.
- The project save/upload fails before processing starts.

**Functional**

- ✅ Project saves successfully.
- ✅ Document processing starts automatically after save.

**Tracking**

- ✅ Fullstory event fires: `Compliance List Processing Started`, properties `{}`.
- ❌ **Critical fail** if `COMPLIANCE_LIST_STARTED` (old name) appears.
- ❌ Fails if the payload still contains `projectId` (this property was intentionally dropped).

---

### TC-17 — Removed Duplicate (no double-fire)

**Where:** Compliance Landing → click any active project card's primary action.

**Tracking**

- ✅ `Compliance View Project Clicked` fires **exactly once** (from `project-card.component.ts`).
- ❌ **Critical fail** if it fires twice — that means the removal in `compliance-landing.component.ts → onViewProject` was reverted or the duplicate re-introduced.

This is essentially a stricter form of TC-01 — call it out separately because the regression risk is the headline change.

---

## Regression Sanity Checks

These exercise the touched files end-to-end to make sure non-tracking behavior wasn't disturbed.

### REG-01 — Folder upload (response-upload.component.ts)

The diff to `response-upload.component.ts` is **comments only**, but the file was touched. Smoke test:

- ✅ Drag-and-drop a folder of mixed valid files into the response upload zone.
- ✅ All files within the folder are picked up (recursion still works — this is the `readEntries` MDN pattern that got the comment).
- ✅ One response is created per folder.

### REG-02 — Compliance Landing initial load

- ✅ `/compliance` loads, both active and archived tabs render projects, no console errors.
- ✅ No Fullstory events fire on page load (events are user-action driven only).

---

## Cross-Cutting Checks

Run these at the end of the session.

### CC-01 — Console hygiene

- ✅ During the entire QA run, no uncaught errors or warnings in the browser console caused by Fullstory wiring (e.g. "FS is not defined", "trackEvent is not a function").

### CC-02 — Network hygiene

- ✅ No 4xx/5xx responses to Fullstory bundle endpoints. (Fullstory failing silently is fine; outright 4xx suggests config issue.)

### CC-03 — No event leakage outside Compliance

- ✅ Navigate around non-Compliance areas of the app (e.g. proposal-writer landing). Confirm no Compliance-prefixed events fire there.

### CC-04 — Event name spelling consistency

- ✅ All new event names use the `Compliance ...` Title Case convention (matching the renames). If you spot any `SCREAMING_SNAKE` or stray hyphenated names in the bundle payloads, flag it — every legacy name should now be in the new convention.

---

## Pass/Fail Summary Template

Tester: **\*\*\*\***\_\_\_\_**\*\*\*\*** Date: **\*\*\*\***\_\_\_\_**\*\*\*\***
Build / Commit: **\*\*\*\***\_\_\_\_**\*\*\*\***
Environment: **\*\*\*\***\_\_\_\_**\*\*\*\***

| Test Case                        | Functional               | Tracking                 | Notes           |
| -------------------------------- | ------------------------ | ------------------------ | --------------- |
| TC-01 View Project               | - [x] Pass<br>- [ ] Fail | - [x] Pass<br>- [ ] Fail |                 |
| TC-02 Restore Project            | - [x] Pass<br>- [ ] Fail | - [x] Pass<br>- [ ] Fail |                 |
| TC-03 Edit Project               | - [x] Pass<br>- [ ] Fail | - [x] Pass<br>- [ ] Fail |                 |
| TC-04 Open Creator               | - [x] Pass<br>- [ ] Fail | - [x] Pass<br>- [ ] Fail |                 |
| TC-05 Open Checklist             | - [x] Pass<br>- [ ] Fail | - [x] Pass<br>- [ ] Fail |                 |
| TC-06 Create Item                | - [x] Pass<br>- [ ] Fail | - [x] Pass<br>- [ ] Fail |                 |
| TC-07 Delete Item                | - [x] Pass<br>- [ ] Fail | - [x] Pass<br>- [ ] Fail |                 |
| TC-08 Finish Review              | - [x] Pass<br>- [ ] Fail | - [x] Pass<br>- [ ] Fail |                 |
| TC-09 Download CSV               | - [x] Pass<br>- [ ] Fail | - [x] Pass<br>- [ ] Fail |                 |
| TC-10 Complete Checklist         | - [x] Pass<br>- [ ] Fail | - [x] Pass<br>- [ ] Fail |                 |
| TC-11 Complete Review            | - [x] Pass<br>- [ ] Fail | - [x] Pass<br>- [ ] Fail |                 |
| TC-12 Run Compliance + Lifecycle | - [x] Pass<br>- [ ] Fail | - [x] Pass<br>- [ ] Fail |                 |
| TC-13 Response Tab Group         | - [x] Pass<br>- [ ] Fail | - [x] Pass<br>- [ ] Fail |                 |
| TC-14 Determination Change       | - [x] Pass<br>- [ ] Fail | - [x] Pass<br>- [ ] Fail |                 |
| TC-15 Evidence Prev/Next         | - [x] Pass<br>- [ ] Fail | - [x] Pass<br>- [ ] Fail |                 |
| TC-16a Responses Uploaded rename | n/a                      | - [x] Pass<br>- [ ] Fail |                 |
| TC-16b List Started rename       | n/a                      | - [x] Pass<br>- [ ] Fail | can't replicate |
| TC-17 No double-fire             | n/a                      | - [x] Pass<br>- [ ] Fail |                 |
| REG-01 Folder upload             | - [x] Pass<br>- [ ] Fail | n/a                      |                 |
| REG-02 Landing load              | - [x] Pass<br>- [ ] Fail | n/a                      |                 |
| CC-01 Console clean              | n/a                      | - [x] Pass<br>- [ ] Fail |                 |
| CC-02 Network clean              | n/a                      | - [x] Pass<br>- [ ] Fail |                 |
| CC-03 No leakage                 | n/a                      | - [x] Pass<br>- [ ] Fail |                 |
| CC-04 Naming convention          | n/a                      | - [x] Pass<br>- [ ] Fail |                 |

**Critical fails (block merge):** TC-16a, TC-16b, TC-17 — these are tracking-correctness failures that affect downstream Fullstory dashboards.
