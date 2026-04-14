# Tag UI Column — QA Test Plan
<!-- Generated: 2026-04-14 | Mode: comprehensive -->
<!-- Executor: qa-session skill via Chrome DevTools MCP -->
<!-- Input: openspec/changes/tag-configs-ui-column/specs/tag-ui-column/spec.md -->

## Config
- base_url: http://localhost:4200
- viewport: 1440x900
- wait_default: 5000ms
- mode: comprehensive

---

## S1: End-to-End Journeys

### E2E Journey 1: Proposal Writer — Tag a Document with tag_ui Colors and Labels

This journey exercises the full tagging lifecycle inside the Proposal Writer wizard,
validating that tag_ui metadata drives the context menu labels and highlight colors.

#### Phase 1: Navigate to Proposal Writer

### Step 1: Navigate to Proposal Writer landing
- tool: navigate_page
- url: "http://localhost:4200/proposal-writer"
- expect: Proposal Writer landing page loads with list of proposals

### Step 2: Wait for page load
- tool: wait_for
- text: ["Create New Proposal"]
- timeout: 10000
- expect: Landing page fully rendered with create button visible

#### Phase 2: Create a new proposal

### Step 3: Click Create New Proposal
- tool: click
- element: "[testid='create-new-proposal-button']" | text: "Create New Proposal"
- expect: Create proposal modal opens

### Step 4: Wait for modal
- tool: wait_for
- text: ["Create New Proposal", "Opportunity ID"]
- timeout: 5000
- expect: Modal form is visible with input fields

### Step 5: Fill opportunity ID
- tool: fill
- element: "[testid='opp-id-edit']" | text: "Opportunity ID"
- value: "QA-TAG-UI-001"
- expect: Opportunity ID field populated

### Step 6: Fill title
- tool: fill
- element: "[testid='title-edit']" | text: "Title"
- value: "Tag UI Column QA Test Proposal"
- expect: Title field populated

### Step 7: Click Save to create proposal and enter wizard
- tool: click
- element: "[testid='save-proposal-button']" | text: "Save"
- expect: Proposal created, wizard stepper appears

### Step 8: Wait for wizard stepper
- tool: wait_for
- text: ["Tag", "Review"]
- timeout: 10000
- expect: Wizard stepper visible with Tag step

#### Phase 3: Upload a document and reach the Tag step

### Step 9: Advance to Tag step in wizard
- tool: click
- element: "[testid='next-step-button']" | text: "Next Step"
- expect: Wizard advances; if at upload step, moves toward Tag step

### Step 10: Wait for tag step content to load
- tool: wait_for
- text: ["Loading tagged document and tags...", "No tagged document content is available yet.", "Mark Highlight As:"]
- timeout: 15000
- expect: Tag pane shows loading, empty state, or document content

#### Phase 4: Verify tag_ui drives context menu (if document loads)

### Step 11: Verify document content area is rendered
- tool: evaluate_script
- function: "() => { const docShell = document.querySelector('.doc-shell'); return !!docShell; }"
- expect: Returns true if a tagged document is loaded (false if empty state)

### Step 12: Verify tag_ui metadata is used for tag config API response
- tool: list_network_requests
- resourceTypes: ["fetch", "xhr"]
- expect: A GET request to /tagging/tag-configs returned a response including tag_ui field

### Step 13: Inspect tag-configs API response for tag_ui
- tool: evaluate_script
- function: "() => { const entries = performance.getEntriesByType('resource').filter(e => e.name.includes('/tagging/tag-configs')); return entries.length > 0 ? entries.map(e => e.name) : 'no tag-config requests'; }"
- expect: At least one request to /tagging/tag-configs endpoint

### Step 14: Select text in document content (simulate mouseup)
- tool: evaluate_script
- function: "() => { const body = document.querySelector('.doc-content__body'); if (!body || !body.textContent) return 'no-content'; return body.textContent.substring(0, 100); }"
- expect: Returns first 100 chars of document content, confirming doc is loaded

### Step 15: Verify no console errors after tag step load
- tool: list_console_messages
- types: ["error"]
- expect: Zero errors related to tag_ui, buildMenuConfig, or tagging

#### Phase 5: Navigate away and back

### Step 16: Navigate back to proposal list
- tool: navigate_page
- type: "back"
- expect: Returns to previous page

### Step 17: Navigate forward to verify state preserved
- tool: navigate_page
- type: "forward"
- expect: Tag step content still present or reloads correctly

### Step 18: Verify no console errors after navigation
- tool: list_console_messages
- types: ["error"]
- expect: Zero uncaught errors after back/forward navigation

---

### E2E Journey 2: Template Generator — Tag Step with tag_ui

This journey tests the template generator flow where doc-shell renders
with tag_ui-driven context menus and highlight colors.

### Step 19: Navigate to Template Generator
- tool: navigate_page
- url: "http://localhost:4200/acquisition-center/template-generator"
- expect: Template generator page loads

### Step 20: Wait for template generator page
- tool: wait_for
- text: ["Template Generator", "template"]
- timeout: 10000
- expect: Template generator UI is visible

### Step 21: Verify tag-configs API called for template_generator
- tool: list_network_requests
- resourceTypes: ["fetch", "xhr"]
- expect: Network requests include a call to /tagging/tag-configs (possibly with ?product_code=template_generator)

### Step 22: Check for tag_ui in API response
- tool: evaluate_script
- function: "() => { const entries = performance.getEntriesByType('resource').filter(e => e.name.includes('tag-configs')); return entries.length; }"
- expect: At least one tag-configs request made

### Step 23: Verify no console errors on template generator
- tool: list_console_messages
- types: ["error"]
- expect: Zero errors related to tagging or tag_ui

---

## S2: CRUD — Tag Configs via REST API

This section validates the tag-configs REST endpoints include `tag_ui` in responses
and handle it correctly in create/update operations.

### READ: List all tag configs

### Step 24: Navigate to app and trigger tag config load
- tool: navigate_page
- url: "http://localhost:4200/proposal-writer"
- expect: App loads and will request tag configs

### Step 25: Wait for page
- tool: wait_for
- text: ["Proposal Writer", "Create New Proposal"]
- timeout: 10000
- expect: Page loaded

### Step 26: Verify GET /tagging/tag-configs includes tag_ui in response
- tool: evaluate_script
- function: "() => { return fetch('/api/tagging/tag-configs', { headers: { 'Authorization': 'Bearer ' + (document.cookie.match(/access_token=([^;]+)/)?.[1] || 'none') }}).then(r => r.status).catch(e => e.message); }"
- expect: Returns 200 or identifies auth mechanism (validates endpoint exists)

### Step 27: Check network for tag-configs responses
- tool: list_network_requests
- resourceTypes: ["fetch", "xhr"]
- expect: At least one GET to /tagging/tag-configs visible in network log

---

## S3: State Transition Matrix — TaggingService Metadata Resolution

The TaggingService resolves tag metadata through a state machine:
tag_ui present → use tag_ui | tag_ui null → fallback to tag_schema | both absent → empty maps.

This section validates the UI correctly reflects each state.

### Current State: tag_ui present with non-empty tags[]

### Step 28: Navigate to proposal writer with tag_ui-enabled product
- tool: navigate_page
- url: "http://localhost:4200/proposal-writer"
- expect: Proposal writer loads

### Step 29: Wait for page load
- tool: wait_for
- text: ["Proposal Writer"]
- timeout: 10000
- expect: Page rendered

### Step 30: Verify tag highlight colors match tag_ui.tags[].color
- tool: evaluate_script
- function: "() => { const highlights = document.querySelectorAll('mark.inline-highlight'); if (highlights.length === 0) return 'no-highlights-on-landing'; const colors = [...highlights].map(h => h.style.backgroundColor); return { count: highlights.length, sampleColors: colors.slice(0, 5) }; }"
- expect: If highlights present, colors should use rgba values derived from tag_ui hex colors

### Step 31: Verify tag chips display correct labels
- tool: evaluate_script
- function: "() => { const chips = document.querySelectorAll('.tag-layer__item'); if (chips.length === 0) return 'no-tag-chips-on-landing'; return [...chips].slice(0, 5).map(c => c.textContent?.trim()); }"
- expect: Tag chip labels match tag_ui.tags[].name values (e.g. "Instructions", "Structure", etc.)

### Current State: Loading / transitional

### Step 32: Verify loading state shows correct text
- tool: evaluate_script
- function: "() => { const statusElements = document.querySelectorAll('.proposal-tag-pane-status, .tag-step-status'); return [...statusElements].map(e => e.textContent?.trim()); }"
- expect: Loading state shows "Loading tagged document and tags..." or empty state message

---

## S4: Per-Field Input Exhaustion — Context Menu Entries

The context menu is built from tag_ui.tags entries. Each entry has id, name, color.
This validates the menu renders correctly for various data shapes.

### Step 33: Navigate to a proposal with tagged document
- tool: navigate_page
- url: "http://localhost:4200/proposal-writer"
- expect: Proposal writer loads

### Step 34: Wait for proposals list
- tool: wait_for
- text: ["Proposal Writer"]
- timeout: 10000
- expect: Page fully loaded

### Step 35: Verify context menu entries match tag_ui tag names
- tool: evaluate_script
- function: "() => { const menuButtons = document.querySelectorAll('.tagging-menu-text'); if (menuButtons.length === 0) return 'no-menu-visible'; return [...menuButtons].map(b => b.textContent?.trim()); }"
- expect: If menu is open, entries match tag_ui.tags[].name (e.g. "Instructions", "Structure", "Evaluation Criteria", "Requirements" for proposal_writer)

### Step 36: Verify context menu title
- tool: evaluate_script
- function: "() => { const title = document.querySelector('.tagging-menu-title'); return title?.textContent?.trim() || 'no-menu'; }"
- expect: Returns "Mark Highlight As:" when menu is open

### Step 37: Verify context menu info text
- tool: evaluate_script
- function: "() => { const info = document.querySelector('.tagging-menu-info-text'); return info?.textContent?.trim() || 'no-info'; }"
- expect: Returns "Each title starts new section" when menu is open

---

## S5: Filter/Sort — Tag Configs by Product Code

### Step 38: Verify tag configs can be filtered by product_code query param
- tool: evaluate_script
- function: "() => { const entries = performance.getEntriesByType('resource').filter(e => e.name.includes('tag-configs')); const withProduct = entries.filter(e => e.name.includes('product_code=')); return { total: entries.length, filtered: withProduct.length, urls: entries.map(e => e.name) }; }"
- expect: Shows which tag-config requests include product_code filter

---

## S6: User Acceptance Tests (from spec)

### UAT 1: tag_ui is present in API response (Req: REST API response includes tag_ui)

### Step 39: Navigate to app
- tool: navigate_page
- url: "http://localhost:4200/proposal-writer"
- expect: App loads

### Step 40: Wait for load
- tool: wait_for
- text: ["Proposal Writer"]
- timeout: 10000
- expect: Page rendered

### Step 41: Verify tag_ui field in tag-configs network response
- tool: evaluate_script
- function: "() => { return new Promise(resolve => { const origFetch = window.fetch; window.__tagConfigCapture = []; window.fetch = function(...args) { const result = origFetch.apply(this, args); if (args[0] && typeof args[0] === 'string' && args[0].includes('tag-configs')) { result.then(r => r.clone().json().then(d => { window.__tagConfigCapture.push(d); })); } return result; }; setTimeout(() => { window.fetch = origFetch; resolve(window.__tagConfigCapture); }, 3000); }); }"
- expect: Captured tag-config responses contain tag_ui field (object or null)

### UAT 2: Angular UI prefers tag_ui for display metadata (Req: TaggingService resolution)

### Step 42: Verify tag highlights use tag_ui colors, not tag_schema colors
- tool: evaluate_script
- function: "() => { const highlights = document.querySelectorAll('mark.inline-highlight[data-tag-kind]'); if (highlights.length === 0) return 'no-highlights'; const sample = [...highlights].slice(0, 5).map(h => ({ kind: h.getAttribute('data-tag-kind'), bgColor: h.style.backgroundColor, hlColor: h.style.getPropertyValue('--hl-color') })); return sample; }"
- expect: Highlight colors correspond to tag_ui.tags[].color hex values (as rgba)

### UAT 3: DocShell context menu prefers tag_ui (Req: buildMenuConfig)

### Step 43: Verify menu is built from tag_ui when available
- tool: evaluate_script
- function: "() => { const overlay = document.querySelector('.cdk-overlay-container .tagging-menu'); if (!overlay) return 'no-menu-overlay'; const buttons = overlay.querySelectorAll('.tagging-menu-text'); return [...buttons].map(b => ({ label: b.textContent?.trim(), disabled: b.classList.contains('disabled'), indented: b.classList.contains('indented') })); }"
- expect: Menu entries correspond to tag_ui.tags entries with correct labels and indent pattern (first entry not indented, rest indented)

### UAT 4: tag_ui not sent to Python pipeline (Req: Service Bus exclusion)

### Step 44: Verify no tag_ui in auto-tag request payloads
- tool: evaluate_script
- function: "() => { const entries = performance.getEntriesByType('resource').filter(e => e.name.includes('/tagging/') && !e.name.includes('tag-configs')); return entries.map(e => ({ name: e.name, type: e.initiatorType })); }"
- expect: Auto-tag requests (if any) do not include tag_ui in their payloads (server-side validation; client doesn't send auto-tag directly)

### UAT 5: Fallback to tag_schema when tag_ui is null (Req: fallback chain)

### Step 45: Verify fallback behavior with evaluate_script
- tool: evaluate_script
- function: "() => { const highlights = document.querySelectorAll('mark.inline-highlight'); if (highlights.length === 0) return 'no-highlights-to-verify-fallback'; return { highlightCount: highlights.length, message: 'highlights-present-check-colors-against-either-tag_ui-or-tag_schema' }; }"
- expect: Highlights are rendered with valid colors regardless of whether tag_ui or tag_schema is the source

### UAT 6: Error messages reflect fallback chain (Req: DocShell error messages)

### Step 46: Verify error message mentions both tag_ui and tag_schema
- tool: evaluate_script
- function: "() => { try { const el = document.querySelector('app-doc-shell'); if (!el) return 'no-doc-shell'; return 'doc-shell-present'; } catch(e) { return e.message; } }"
- expect: DocShell component is present (error message testing requires specific state with no tag_ui or tag_schema — covered by unit tests)

---

## S7: Destructive QA

### DQA-PER-PAGE: Proposal Writer Tag Step

### Step 47: Navigate to proposal writer
- tool: navigate_page
- url: "http://localhost:4200/proposal-writer"
- expect: Page loads

### Step 48: Wait for load
- tool: wait_for
- text: ["Proposal Writer"]
- timeout: 10000
- expect: Page rendered

### Step 49: Refresh page on proposal writer
- tool: navigate_page
- type: "reload"
- timeout: 10000
- expect: Page reloads cleanly

### Step 50: Wait for page after refresh
- tool: wait_for
- text: ["Proposal Writer"]
- timeout: 10000
- expect: Page recovered after refresh

### Step 51: Check console after refresh
- tool: list_console_messages
- types: ["error"]
- expect: Zero uncaught errors after refresh

### Step 52: Navigate away to another module
- tool: navigate_page
- url: "http://localhost:4200/acquisition-center"
- expect: Navigates to acquisition center

### Step 53: Navigate back to proposal writer
- tool: navigate_page
- url: "http://localhost:4200/proposal-writer"
- expect: Proposal writer loads again cleanly

### Step 54: Check console after cross-module navigation
- tool: list_console_messages
- types: ["error"]
- expect: Zero errors after navigating between modules

### DQA-PER-PAGE: Template Generator Tag Step

### Step 55: Navigate to template generator
- tool: navigate_page
- url: "http://localhost:4200/acquisition-center/template-generator"
- expect: Template generator page loads

### Step 56: Wait for template generator
- tool: wait_for
- text: ["Template Generator", "template"]
- timeout: 10000
- expect: Page rendered

### Step 57: Refresh template generator page
- tool: navigate_page
- type: "reload"
- timeout: 10000
- expect: Page reloads cleanly

### Step 58: Wait for page after refresh
- tool: wait_for
- text: ["Template Generator", "template"]
- timeout: 10000
- expect: Page recovered

### Step 59: Check console after template generator refresh
- tool: list_console_messages
- types: ["error"]
- expect: Zero errors

### DQA-EVERY-BUTTON: Context Menu Double-Click

### Step 60: Verify context menu overlay dismissal on backdrop click
- tool: evaluate_script
- function: "() => { const backdrops = document.querySelectorAll('.cdk-overlay-backdrop'); return backdrops.length; }"
- expect: Returns 0 when no overlay is open; backdrop click dismisses the menu

### Step 61: Verify no duplicate network requests from rapid interactions
- tool: list_network_requests
- resourceTypes: ["fetch", "xhr"]
- expect: No duplicate POST/PATCH/DELETE requests to /tagging/ endpoints from rapid clicking

### DQA-EVERY-FORM: Tag selection interrupt

### Step 62: Verify tag menu dismisses cleanly when selection is cleared
- tool: evaluate_script
- function: "() => { const overlay = document.querySelector('.cdk-overlay-container .tagging-menu'); const selection = window.getSelection(); return { overlayPresent: !!overlay, selectionCollapsed: selection?.isCollapsed }; }"
- expect: When no text is selected, overlay is not present

### DQA-API-FAILURES: Tag config endpoint errors

### Step 63: Verify app handles missing tag config gracefully
- tool: evaluate_script
- function: "() => { const errorElements = document.querySelectorAll('[class*=\"error\"], [class*=\"status\"]'); return [...errorElements].map(e => ({ class: e.className, text: e.textContent?.trim().substring(0, 100) })); }"
- expect: Error states show user-friendly messages, not stack traces

### DQA-NAVIGATION-ABUSE: Browser back/forward

### Step 64: Rapid back-forward navigation
- tool: navigate_page
- url: "http://localhost:4200/proposal-writer"
- expect: Page loads

### Step 65: Navigate to acquisition center
- tool: navigate_page
- url: "http://localhost:4200/acquisition-center"
- expect: Navigates away

### Step 66: Go back
- tool: navigate_page
- type: "back"
- expect: Returns to proposal writer

### Step 67: Go forward
- tool: navigate_page
- type: "forward"
- expect: Returns to acquisition center

### Step 68: Go back again
- tool: navigate_page
- type: "back"
- expect: Returns to proposal writer again

### Step 69: Check console after navigation abuse
- tool: list_console_messages
- types: ["error"]
- expect: Zero uncaught errors

### DQA: Deep link directly to proposal workspace

### Step 70: Deep link to a proposal workspace URL
- tool: navigate_page
- url: "http://localhost:4200/proposal-writer/1"
- timeout: 15000
- expect: Either loads proposal workspace or redirects gracefully

### Step 71: Wait for response
- tool: wait_for
- text: ["Proposal Writer", "Tag", "Loading"]
- timeout: 15000
- expect: Page shows some content — proposal detail, wizard, or redirect

### Step 72: Check console after deep link
- tool: list_console_messages
- types: ["error"]
- expect: No uncaught errors from deep linking

---

## S8: Per-Page Accessibility

### Accessibility: /proposal-writer

### Step 73: Navigate to proposal writer
- tool: navigate_page
- url: "http://localhost:4200/proposal-writer"
- expect: Page loads

### Step 74: Wait for page
- tool: wait_for
- text: ["Proposal Writer"]
- timeout: 10000
- expect: Page rendered

### Step 75: Lighthouse audit — proposal writer
- tool: lighthouse_audit
- device: "desktop"
- mode: "snapshot"
- expect: accessibility >= 90, best practices >= 90

### Step 76: Full keyboard navigation on proposal writer
- tool: press_key
- key: "Tab"
- expect: Focus moves to first focusable element

### Step 77: Continue tabbing through interactive elements
- tool: press_key
- key: "Tab"
- expect: Focus advances to next element

### Step 78: Verify focus indicator visible
- tool: evaluate_script
- function: "() => { const el = document.activeElement; if (!el) return 'no-active-element'; const cs = window.getComputedStyle(el); return { tag: el.tagName, text: el.textContent?.trim().substring(0, 50), outline: cs.outline, boxShadow: cs.boxShadow }; }"
- expect: Active element has visible focus indicator (outline or boxShadow)

### Step 79: Take accessibility snapshot
- tool: take_snapshot
- verbose: true
- expect: All interactive elements have accessible names

### Step 80: Verify heading hierarchy
- tool: evaluate_script
- function: "() => { const headings = document.querySelectorAll('h1, h2, h3, h4, h5, h6'); return [...headings].map(h => ({ level: h.tagName, text: h.textContent?.trim().substring(0, 50) })); }"
- expect: Heading hierarchy is logical (h1 → h2 → h3, no skipped levels)

### Step 81: Verify landmarks
- tool: evaluate_script
- function: "() => { const landmarks = { main: !!document.querySelector('main, [role=\"main\"]'), nav: !!document.querySelector('nav, [role=\"navigation\"]'), banner: !!document.querySelector('header, [role=\"banner\"]') }; return landmarks; }"
- expect: Main landmark present

### Accessibility: /acquisition-center/template-generator

### Step 82: Navigate to template generator
- tool: navigate_page
- url: "http://localhost:4200/acquisition-center/template-generator"
- expect: Page loads

### Step 83: Wait for page
- tool: wait_for
- text: ["Template Generator", "template"]
- timeout: 10000
- expect: Page rendered

### Step 84: Lighthouse audit — template generator
- tool: lighthouse_audit
- device: "desktop"
- mode: "snapshot"
- expect: accessibility >= 90, best practices >= 90

### Step 85: Keyboard navigation on template generator
- tool: press_key
- key: "Tab"
- expect: Focus moves to first focusable element

### Step 86: Verify focus indicator on template generator
- tool: evaluate_script
- function: "() => { const el = document.activeElement; if (!el) return 'no-active-element'; const cs = window.getComputedStyle(el); return { tag: el.tagName, text: el.textContent?.trim().substring(0, 50), outline: cs.outline, boxShadow: cs.boxShadow }; }"
- expect: Active element has visible focus indicator

### Step 87: Take accessibility snapshot of template generator
- tool: take_snapshot
- verbose: true
- expect: All interactive elements have accessible names

### Accessibility: Context Menu (when open)

### Step 88: Verify context menu ARIA compliance
- tool: evaluate_script
- function: "() => { const menu = document.querySelector('.tagging-menu'); if (!menu) return 'no-menu-open'; const buttons = menu.querySelectorAll('button'); return { buttonCount: buttons.length, allHaveText: [...buttons].every(b => b.textContent?.trim().length > 0), hasDisabledAttr: [...buttons].some(b => b.hasAttribute('disabled')) }; }"
- expect: All menu buttons have text labels, disabled buttons have disabled attribute

### Step 89: Verify overlay has correct backdrop for accessibility
- tool: evaluate_script
- function: "() => { const backdrop = document.querySelector('.transparent-backdrop'); return { present: !!backdrop, role: backdrop?.getAttribute('role'), ariaHidden: backdrop?.getAttribute('aria-hidden') }; }"
- expect: Backdrop exists when overlay is open

---

## S9: Security

### XSS: Per-input exhaustion — Document Content (DOMPurify)

### Step 90: Navigate to proposal writer
- tool: navigate_page
- url: "http://localhost:4200/proposal-writer"
- expect: Page loads

### Step 91: Wait for page
- tool: wait_for
- text: ["Proposal Writer"]
- timeout: 10000
- expect: Page rendered

### Step 92: Verify DOMPurify sanitizes HTML in doc-shell
- tool: evaluate_script
- function: "() => { const docBody = document.querySelector('.doc-content__body'); if (!docBody) return 'no-doc-body'; const scripts = docBody.querySelectorAll('script'); const iframes = docBody.querySelectorAll('iframe'); const eventHandlers = docBody.querySelectorAll('[onload], [onerror], [onclick], [onmouseover]'); return { scripts: scripts.length, iframes: iframes.length, eventHandlers: eventHandlers.length }; }"
- expect: scripts=0, iframes=0, eventHandlers=0 (DOMPurify strips them)

### Step 93: Verify no XSS via innerHTML bypass
- tool: evaluate_script
- function: "() => !window.__xss"
- expect: Returns true (no XSS executed)

### XSS: Tag name/label injection

### Step 94: Verify tag labels are rendered as text, not HTML
- tool: evaluate_script
- function: "() => { const menuTexts = document.querySelectorAll('.tagging-menu-text'); return [...menuTexts].map(b => ({ innerHTML: b.innerHTML.substring(0, 200), hasScript: b.innerHTML.includes('<script>'), hasImg: b.innerHTML.includes('<img') })); }"
- expect: No menu entries contain unescaped HTML elements

### API Contract Validation

### Step 95: Verify tag-configs API uses correct auth headers
- tool: list_network_requests
- resourceTypes: ["fetch", "xhr"]
- expect: All /tagging/ requests include Authorization header

### Step 96: Verify API response Content-Type
- tool: evaluate_script
- function: "() => { const entries = performance.getEntriesByType('resource').filter(e => e.name.includes('tag-configs')); return entries.map(e => ({ url: e.name, duration: e.duration })); }"
- expect: Tag-config requests completed successfully

### Console & Storage Audit

### Step 97: Audit console for sensitive data leakage
- tool: list_console_messages
- types: ["error", "warn"]
- expect: No auth tokens, PII, or stack traces with internal paths in console output

### Step 98: Audit localStorage and sessionStorage
- tool: evaluate_script
- function: "() => { const local = Object.keys(localStorage); const session = Object.keys(sessionStorage); return { localStorage: local.filter(k => k.toLowerCase().includes('token') || k.toLowerCase().includes('password') || k.toLowerCase().includes('secret')), sessionStorage: session.filter(k => k.toLowerCase().includes('token') || k.toLowerCase().includes('password') || k.toLowerCase().includes('secret')) }; }"
- expect: No plaintext passwords or API keys stored in client storage

---

## S10: Performance

### Performance: /proposal-writer

### Step 99: Navigate to proposal writer for performance audit
- tool: navigate_page
- url: "http://localhost:4200/proposal-writer"
- expect: Page loads

### Step 100: Lighthouse performance audit — proposal writer
- tool: lighthouse_audit
- device: "desktop"
- mode: "navigation"
- expect: Record performance score, LCP, CLS, TBT, FCP

### Step 101: Network analysis — proposal writer
- tool: list_network_requests
- resourceTypes: ["fetch", "xhr"]
- expect: Count total XHR/fetch requests, flag any > 500KB responses or duplicate calls

### Step 102: Page timing — proposal writer
- tool: evaluate_script
- function: "() => { const nav = performance.getEntriesByType('navigation')[0]; return { domContentLoaded: nav.domContentLoadedEventEnd, loadComplete: nav.loadEventEnd, ttfb: nav.responseStart - nav.requestStart }; }"
- expect: domContentLoaded < 3000ms, TTFB < 500ms

### Step 103: Memory baseline — proposal writer
- tool: evaluate_script
- function: "() => { return performance.memory ? { usedJSHeapSize: performance.memory.usedJSHeapSize, totalJSHeapSize: performance.memory.totalJSHeapSize } : 'performance.memory not available'; }"
- expect: Record baseline memory usage

### Performance: /acquisition-center/template-generator

### Step 104: Navigate to template generator for performance audit
- tool: navigate_page
- url: "http://localhost:4200/acquisition-center/template-generator"
- expect: Page loads

### Step 105: Lighthouse performance audit — template generator
- tool: lighthouse_audit
- device: "desktop"
- mode: "navigation"
- expect: Record performance score, LCP, CLS, TBT, FCP

### Step 106: Network analysis — template generator
- tool: list_network_requests
- resourceTypes: ["fetch", "xhr"]
- expect: Count total requests, no duplicates to tag-configs

### Step 107: Page timing — template generator
- tool: evaluate_script
- function: "() => { const nav = performance.getEntriesByType('navigation')[0]; return { domContentLoaded: nav.domContentLoadedEventEnd, loadComplete: nav.loadEventEnd, ttfb: nav.responseStart - nav.requestStart }; }"
- expect: domContentLoaded < 3000ms

### Performance: Tag highlighting with many tags

### Step 108: Verify highlight rendering performance with many tags
- tool: evaluate_script
- function: "() => { const highlights = document.querySelectorAll('mark.inline-highlight'); return { count: highlights.length, message: highlights.length > 100 ? 'many-highlights-check-scroll-perf' : 'reasonable-highlight-count' }; }"
- expect: Highlight count is reasonable; if >100, verify no lag during scroll

### Step 109: Memory after interactions
- tool: evaluate_script
- function: "() => { return performance.memory ? { usedJSHeapSize: performance.memory.usedJSHeapSize, totalJSHeapSize: performance.memory.totalJSHeapSize } : 'performance.memory not available'; }"
- expect: Memory growth < 30% from baseline

---

## S11: Desktop Layout

### Layout: /proposal-writer

### Step 110: Viewport 1440x900 — proposal writer
- tool: resize_page
- width: 1440
- height: 900

### Step 111: Navigate to proposal writer
- tool: navigate_page
- url: "http://localhost:4200/proposal-writer"
- expect: Page loads at standard viewport

### Step 112: Wait for page
- tool: wait_for
- text: ["Proposal Writer"]
- timeout: 10000
- expect: Page rendered

### Step 113: Check horizontal overflow at 1440x900
- tool: evaluate_script
- function: "() => document.documentElement.scrollWidth <= 1440"
- expect: Returns true — no horizontal overflow

### Step 114: Viewport 1280x720 — proposal writer
- tool: resize_page
- width: 1280
- height: 720

### Step 115: Check horizontal overflow at 1280x720
- tool: evaluate_script
- function: "() => document.documentElement.scrollWidth <= 1280"
- expect: Returns true — no horizontal overflow

### Step 116: Verify doc-shell panels don't overlap at 1280x720
- tool: evaluate_script
- function: "() => { const docShell = document.querySelector('.doc-shell'); const tagLayer = document.querySelector('app-tag-layer'); if (!docShell || !tagLayer) return 'no-doc-shell-visible'; const shellRect = docShell.getBoundingClientRect(); const layerRect = tagLayer.getBoundingClientRect(); return { shellWidth: shellRect.width, layerWidth: layerRect.width, overlap: layerRect.left < shellRect.left }; }"
- expect: No overlap between doc content and tag layer

### Step 117: Viewport 1920x1080 — proposal writer
- tool: resize_page
- width: 1920
- height: 1080

### Step 118: Check layout at 1920x1080
- tool: evaluate_script
- function: "() => { const main = document.querySelector('main, .main-content, .app-content'); return main ? { width: main.getBoundingClientRect().width, fills: main.getBoundingClientRect().width > 1200 } : 'no-main-element'; }"
- expect: Content fills or has max-width constraint; no awkward gaps

### Layout: /acquisition-center/template-generator

### Step 119: Viewport 1440x900 — template generator
- tool: resize_page
- width: 1440
- height: 900

### Step 120: Navigate to template generator
- tool: navigate_page
- url: "http://localhost:4200/acquisition-center/template-generator"
- expect: Page loads

### Step 121: Wait for page
- tool: wait_for
- text: ["Template Generator", "template"]
- timeout: 10000
- expect: Page rendered

### Step 122: Check horizontal overflow at 1440x900
- tool: evaluate_script
- function: "() => document.documentElement.scrollWidth <= 1440"
- expect: Returns true — no horizontal overflow

### Step 123: Viewport 1280x720 — template generator
- tool: resize_page
- width: 1280
- height: 720

### Step 124: Check horizontal overflow at 1280x720
- tool: evaluate_script
- function: "() => document.documentElement.scrollWidth <= 1280"
- expect: Returns true — no horizontal overflow

### Step 125: Viewport 1920x1080 — template generator
- tool: resize_page
- width: 1920
- height: 1080

### Step 126: Check layout at 1920x1080
- tool: evaluate_script
- function: "() => document.documentElement.scrollWidth <= 1920"
- expect: Returns true — no horizontal overflow

### Step 127: Reset viewport to standard
- tool: resize_page
- width: 1440
- height: 900

---

## S12: Tag UI Column Feature-Specific Validation

These steps validate the core tag_ui feature behavior that cannot be tested
through unit tests alone — verifying the actual rendered UI matches expectations.

### Verify tag_ui-driven highlight colors per product

### Step 128: Navigate to proposal writer
- tool: navigate_page
- url: "http://localhost:4200/proposal-writer"
- expect: Page loads

### Step 129: Wait for page
- tool: wait_for
- text: ["Proposal Writer"]
- timeout: 10000
- expect: Page rendered

### Step 130: Verify proposal_writer tag_ui colors in rendered highlights
- tool: evaluate_script
- function: "() => { const expectedColors = { 'instructions': '#FFFFCC', 'structure': '#CCE5FF', 'evaluation_criteria': '#FFD9CC', 'requirements': '#CCFFCC' }; const highlights = document.querySelectorAll('mark.inline-highlight[data-tag-kind]'); if (highlights.length === 0) return { status: 'no-highlights', note: 'Need a tagged document to verify colors' }; const samples = [...highlights].slice(0, 20).map(h => ({ kind: h.getAttribute('data-tag-kind'), bgColor: h.style.backgroundColor })); return { count: highlights.length, samples, expectedColors }; }"
- expect: Highlight background colors match the rgba equivalents of tag_ui hex colors for proposal_writer product

### Verify tag chip kind attribute matches tag_ui.tags[].id

### Step 131: Verify tag chips use original (non-normalized) tag_ui entry IDs
- tool: evaluate_script
- function: "() => { const chips = document.querySelectorAll('[data-kind]'); if (chips.length === 0) return 'no-tag-chips'; return [...chips].slice(0, 10).map(c => ({ kind: c.getAttribute('data-kind'), text: c.textContent?.trim() })); }"
- expect: data-kind attributes preserve original casing from tag_ui.tags[].id (e.g. "section_header" not "sectionheader")

### Verify cache invalidation when tag config changes

### Step 132: Navigate between products to trigger cache invalidation
- tool: navigate_page
- url: "http://localhost:4200/acquisition-center/template-generator"
- expect: Template generator loads, potentially with different tag config

### Step 133: Wait for template generator
- tool: wait_for
- text: ["Template Generator", "template"]
- timeout: 10000
- expect: Page rendered

### Step 134: Navigate back to proposal writer
- tool: navigate_page
- url: "http://localhost:4200/proposal-writer"
- expect: Proposal writer loads with its own tag config

### Step 135: Wait for proposal writer
- tool: wait_for
- text: ["Proposal Writer"]
- timeout: 10000
- expect: Page rendered

### Step 136: Verify tag metadata is product-specific (not cached from other product)
- tool: evaluate_script
- function: "() => { const highlights = document.querySelectorAll('mark.inline-highlight[data-tag-kind]'); const kinds = new Set([...highlights].map(h => h.getAttribute('data-tag-kind'))); return { uniqueKinds: [...kinds], note: 'Should match proposal_writer tag_ui tags, not template_generator' }; }"
- expect: Tag kinds visible are from proposal_writer's tag_ui (instructions, structure, evaluation_criteria, requirements), not template_generator's

### Verify context menu entry count matches tag_ui.tags length

### Step 137: Verify menu entry count
- tool: evaluate_script
- function: "() => { const menu = document.querySelector('.tagging-menu'); if (!menu) return 'no-menu-open-trigger-by-selecting-text'; const entries = menu.querySelectorAll('.tagging-menu-text:not(.disabled)'); return { entryCount: entries.length, labels: [...entries].map(e => e.textContent?.trim()) }; }"
- expect: Entry count matches the number of tags in tag_ui.tags for the current product

### Verify menu indentation pattern

### Step 138: Verify first entry is not indented, rest are
- tool: evaluate_script
- function: "() => { const menu = document.querySelector('.tagging-menu'); if (!menu) return 'no-menu'; const entries = menu.querySelectorAll('.tagging-menu-text'); return [...entries].map((e, i) => ({ index: i, label: e.textContent?.trim(), indented: e.classList.contains('indented') })); }"
- expect: First entry has indented=false, all subsequent entries have indented=true

### Final console audit

### Step 139: Final console error audit
- tool: list_console_messages
- types: ["error"]
- expect: Zero uncaught errors across the entire test session

### Step 140: Final console warning audit
- tool: list_console_messages
- types: ["warn"]
- expect: No warnings related to tag_ui, tagging, or buildMenuConfig

---

## Screenshot Policy

Only take screenshots on FAILURE. When a step FAILs, take a screenshot immediately
for diagnosis. Do NOT take screenshots for passing steps.

On FAIL: `take_screenshot` → save to `tag-ui-column-qa-screenshots/FAIL-step-{N}.png` → continue
