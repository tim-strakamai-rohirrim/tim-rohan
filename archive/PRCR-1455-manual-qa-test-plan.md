# PRCR-1455 — Manual QA Test Plan

**PR:** [#1900 — Introduce "Ready for Review" status for compliance lists](https://github.com/rohancapture/rohan_ui/pull/1900)  
**Branch:** `feature/abajwa/PRCR-1455`  
**Scope:** Compliance project overview card status derivation, card badge/button copy, and card navigation behavior.

---

## What Changed

This PR adds a new UI status between "In Progress" and "Complete":

- Backend/project state: `status = creating_compliance_list`
- Autotag state: `autotag_processing = Complete`
- New UI state: `items_ready`
- Expected badge: **Ready for Review**
- Expected button: **Review Compliance List**
- Expected click behavior: open the compliance list creator/review workspace, not the final checklist table.

Main risk: projects whose compliance items are generated may still look like "In Progress", route to the wrong page, show a processing spinner forever, or use the wrong chip styling.

---

## Test Environment

| Item | Required |
|------|----------|
| App | `rohan_ui` with PR #1900 deployed or checked out |
| Browser | Chrome |
| Route | `/compliance/:projectId/overview` |
| User | User with Compliance access and permission to view/create projects |
| Test data | Projects in each status state below |

### Required Test Data

Create or seed these projects before manual QA:

| Fixture | Project `status` | `autotag_processing` | Purpose |
|---------|------------------|----------------------|---------|
| A | `active` | `Not Started` or null | Not-started regression |
| B | `creating_compliance_list` | `Processing` | In-progress regression |
| C | `creating_compliance_list` | `Complete` | New Ready for Review behavior |
| D | `creating_compliance_list` | `Failed` | Failed-state regression |
| E | `reviewing_responses` | `Complete` | Complete/checklist regression |
| F | `archived` | `Complete` | Archived complete regression |

If direct database/API seeding is unavailable, create a Compliance project through the UI, start compliance list generation, and use API/database tooling to update `status` and `autotag_processing` for the fixture records.

---

## Pass/Fail Rules

Pass means:

- New fixture C shows **Ready for Review** and **Review Compliance List**.
- Fixture C does not show persistent processing copy after load.
- Fixture C button click opens `/compliance/:projectId/compliance-creator`.
- Existing Not Started, In Progress, Complete, and Archived states still show their prior labels and navigation.
- No console errors occur during page load, refresh, or card click.

Fail means:

- Fixture C shows **In Progress**, **Complete**, or **View Compliance List**.
- Fixture C routes to `/compliance/:projectId/compliance-checklist`.
- Fixture C opens creator with long-lived "Processing documents..." state after project data has loaded.
- Any adjacent status regresses.

---

## Test Matrix

### TC-01 — Active Project: Not Started Regression

**Data:** Fixture A (`active`, `Not Started` or null).

**Steps**

1. Navigate to `/compliance/<fixtureAProjectId>/overview`.
2. Locate the Compliance List card.
3. Verify the badge text.
4. Verify the primary button text.
5. Click the primary button.

**Expected**

- Badge says **Not Started**.
- Button says **Start Compliance**.
- Click routes to `/compliance/<fixtureAProjectId>/compliance-creator`.
- No console errors.

---

### TC-02 — Processing Project: In Progress Regression

**Data:** Fixture B (`creating_compliance_list`, `Processing`).

**Steps**

1. Navigate to `/compliance/<fixtureBProjectId>/overview`.
2. Locate the Compliance List card.
3. Verify badge and button copy.
4. Verify Base Information and Document Library edit buttons are hidden/disabled while processing.
5. Click the card button.

**Expected**

- Badge says **In Progress**.
- Button says **View Compliance List**.
- Click routes to `/compliance/<fixtureBProjectId>/compliance-creator`.
- Creator page may show **Processing documents... This may take a few minutes.**
- No console errors.

---

### TC-03 — Ready Project: New Badge and Button Copy

**Data:** Fixture C (`creating_compliance_list`, `Complete`).

**Steps**

1. Navigate to `/compliance/<fixtureCProjectId>/overview`.
2. Locate the Compliance List card.
3. Verify badge text.
4. Verify button text.
5. Inspect card visually beside a known Complete project if available.

**Expected**

- Badge says **Ready for Review**.
- Button says **Review Compliance List**.
- Badge uses the same completed/teal visual treatment as Complete status.
- Card aria label includes `Compliance List - Ready for Review`.
- Card is not dimmed or disabled after project load completes.
- No visible text says **In Progress** on the card.

---

### TC-04 — Ready Project: Opens Creator Review Workspace

**Data:** Fixture C (`creating_compliance_list`, `Complete`).

**Steps**

1. Navigate to `/compliance/<fixtureCProjectId>/overview`.
2. Click **Review Compliance List**.
3. Wait for navigation and project load.
4. Inspect URL and visible page content.
5. Use browser Back to return to overview.

**Expected**

- URL becomes `/compliance/<fixtureCProjectId>/compliance-creator`.
- Page does not route to `/compliance/<fixtureCProjectId>/compliance-checklist`.
- Long-lived processing state does not appear after data load.
- Compliance items/documents are reviewable if fixture data contains generated items.
- Browser Back returns to overview with **Ready for Review** still displayed.
- No console errors.

---

### TC-05 — Ready Project: Refresh and Direct Link

**Data:** Fixture C (`creating_compliance_list`, `Complete`).

**Steps**

1. Navigate directly to `/compliance/<fixtureCProjectId>/overview`.
2. Refresh the page.
3. Verify card state after reload.
4. Navigate directly to `/compliance/<fixtureCProjectId>/compliance-creator`.
5. Refresh the creator page.

**Expected**

- Overview reload preserves **Ready for Review** and **Review Compliance List**.
- Creator direct link loads normally.
- Creator refresh does not get stuck in processing state.
- No console errors or unhandled promise rejections.

---

### TC-06 — Failed Autotag: Existing In Progress Behavior

**Data:** Fixture D (`creating_compliance_list`, `Failed`).

**Steps**

1. Navigate to `/compliance/<fixtureDProjectId>/overview`.
2. Verify Compliance List card badge and button.
3. Click the button.

**Expected**

- Badge remains **In Progress**.
- Button remains **View Compliance List**.
- Click routes to `/compliance/<fixtureDProjectId>/compliance-creator`.
- Behavior matches current product expectations for failed autotag projects.
- No **Ready for Review** text appears for failed autotag state.

---

### TC-07 — Reviewing Responses: Complete Regression

**Data:** Fixture E (`reviewing_responses`, `Complete`).

**Steps**

1. Navigate to `/compliance/<fixtureEProjectId>/overview`.
2. Locate the Compliance List card.
3. Verify badge and button copy.
4. Click the card button.

**Expected**

- Badge says **Complete**.
- Button says **View Compliance List**.
- Badge uses completed/teal styling.
- Click routes to `/compliance/<fixtureEProjectId>/compliance-checklist`.
- No **Ready for Review** text appears for final-review projects.

---

### TC-08 — Archived Project: Complete Regression

**Data:** Fixture F (`archived`, `Complete`).

**Steps**

1. Navigate to `/compliance/<fixtureFProjectId>/overview`.
2. Locate the Compliance List card.
3. Verify badge and button copy.
4. Verify Base Information and Document Library edit actions are not available.
5. Click the card button.

**Expected**

- Badge says **Complete**.
- Button says **View Compliance List**.
- Project edit actions remain unavailable because project is archived.
- Click routes to `/compliance/<fixtureFProjectId>/compliance-checklist`.
- No **Ready for Review** text appears for archived projects.

---

### TC-09 — Status Transition: Processing to Ready

**Data:** Fixture B or a freshly started compliance project.

**Steps**

1. Navigate to overview while project has `autotag_processing = Processing`.
2. Verify **In Progress** state.
3. In another tab/tool, update the same project to `autotag_processing = Complete` while keeping `status = creating_compliance_list`.
4. Refresh overview.
5. Click the card button.

**Expected**

- Before update: **In Progress** / **View Compliance List**.
- After update + refresh: **Ready for Review** / **Review Compliance List**.
- Click opens `/compliance/<projectId>/compliance-creator`.
- No stale **Processing documents...** state remains after refresh.

---

### TC-10 — Landing/List Regression Smoke

**Data:** Any active Compliance project list containing fixtures A-C.

**Steps**

1. Navigate to `/compliance`.
2. Confirm project list loads.
3. Open fixture C from the list.
4. Return to `/compliance`.
5. Open fixture B from the list.

**Expected**

- Compliance landing page still loads.
- Project cards/list rows still navigate to project overview.
- No landing-page status badge or action regression is introduced by fixture C.
- No console errors.

---

### TC-11 — Accessibility and Keyboard

**Data:** Fixture C.

**Steps**

1. Navigate to `/compliance/<fixtureCProjectId>/overview`.
2. Use `Tab` to focus the Compliance List card button.
3. Press `Enter`.
4. Return to overview.
5. Repeat with `Space` if supported by the button implementation.
6. Inspect the card accessible name with Chrome DevTools Accessibility pane.

**Expected**

- Button is reachable in logical tab order.
- Focus indicator is visible.
- Keyboard activation opens `/compliance/<fixtureCProjectId>/compliance-creator`.
- Accessible card name includes **Ready for Review**.
- Button accessible name is **Review Compliance List**.

---

### TC-12 — Visual Layout

**Data:** Fixture C.

**Steps**

1. Navigate to `/compliance/<fixtureCProjectId>/overview`.
2. Resize browser to 1440x900.
3. Verify card layout.
4. Resize to 1280x720.
5. Verify card layout again.
6. Resize to 1920x1080.
7. Verify card layout again.

**Expected**

- **Ready for Review** badge fits without clipping/wrapping badly.
- **Review Compliance List** button text fits without truncation.
- No horizontal page overflow.
- Card height remains aligned with neighboring overview content.

---

### TC-13 — Console and Network Sanity

**Data:** Fixture C.

**Steps**

1. Open Chrome DevTools Console and Network tabs.
2. Navigate to `/compliance/<fixtureCProjectId>/overview`.
3. Refresh.
4. Click **Review Compliance List**.
5. Inspect failed network requests and console output.

**Expected**

- Project load request returns successful project data with `status = creating_compliance_list` and `autotag_processing = Complete`.
- No unexpected 4xx/5xx requests.
- No console errors.
- No stack traces or `TypeError` caused by the new `items_ready` enum value.

---

## Final Sign-Off Checklist

- [ ] Fixture A: Not Started shows **Start Compliance**.
- [ ] Fixture B: Processing shows **In Progress** / **View Compliance List**.
- [ ] Fixture C: Ready shows **Ready for Review** / **Review Compliance List**.
- [ ] Fixture C routes to compliance creator, not final checklist.
- [ ] Fixture C does not show persistent processing spinner.
- [ ] Fixture D: Failed does not show Ready for Review.
- [ ] Fixture E: Reviewing responses still shows Complete and routes to checklist.
- [ ] Fixture F: Archived still shows Complete and routes to checklist.
- [ ] Keyboard activation works for Ready state.
- [ ] Ready label/button fit at 1280, 1440, and 1920 desktop widths.
- [ ] No console errors observed.

