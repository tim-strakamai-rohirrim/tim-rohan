# Acquisition Pathways — ONERING integration, wizard-step I/O contracts

> **Purpose.** This is the **synchronization boundary** between the full-stack verticals in
> `acquisition-pathways-onering-integration-PLAN.md`. It specifies, for **each wizard step**,
> exactly what goes *in* (trigger params, upstream `run_state` keys, uploaded documents) and
> what comes *out* (the `ui_projection_*.json` artifact → the materialized `run_state` key →
> the frontend type it deserializes into). Freeze a step's section here **before** its vertical
> starts; the owner then builds engine → api → ui against the frozen shapes without
> cross-vertical coordination.
>
> **What this doc is *not*.** It is not the exhaustive NestJS-DTO/DDL reference. The literal
> `class-validator` DTOs, Pydantic models, and JSON Schemas already exist per vertical:
> Requirements in `acquisition-pathways-step1-requirements-slice.md`, Pathway in
> `PRCR-1674-contracts.md` (`C1…C15`). This doc states the **data shapes flowing through each
> step** and points to those for decorator-level detail.
>
> **Altitude.** Each step's *output* shape is a slice of the shared `AcquisitionRunState` blob
> (§2). The *transport* (trigger endpoint, DAG conf envelope, run-poll, materializer lifecycle)
> is identical across steps and is specified once in §8.

---

## Contract → Vertical mapping

| Contract section | Vertical(s) | Notes |
|------------------|-------------|-------|
| §1 Per-step I/O at a glance | all | The one-screen map every owner reads first |
| §2 `AcquisitionRunState` (shared blob) | V0 | Frozen by Foundation; every step writes a slice of it |
| §3 Requirements Record I/O | V1 | `canonicalRecord` (+ user-owned `requirementsRecordNotes`) |
| §4 Pathway Selection I/O | V2 | `pathways`, `selectedPathway`, `pathwayCommitted` |
| §5 Package Assembly I/O | V3 | `scheduledArtifacts` (+ `artifacts`, `documents`) |
| §6 Integrity Check I/O | V4 | `findings` with server-side `mergeReplace` |
| §7 Finalize I/O | V5 | `ledger` + bundle/download |
| §8 Trigger + DAG-conf envelope (shared) | V0/all | Endpoint, conf claim-check, run-poll, materializer lifecycle |
| §9 Chat / MCP control-plane I/O | V6 | Read/mutate + generation-trigger tools, Watcher |
| §10 Error responses | all | Literal status/message strings per endpoint |

---

## §1 — Per-step I/O at a glance

| Wizard step | Trigger (`POST …/missions/:id/…`) | ONERING DAG | **Inputs consumed** | `ui_projection_*.json` artifact | **`run_state` key written** | FE type |
|---|---|---|---|---|---|---|
| **Requirements Record** | `…:extract` (or `generate {phase:'record'}`) | `arc_acquisition_requirements` | uploaded docs (claim-check), mission name/statement | `ui_projection_acquisition_requirements.json` | `canonicalRecord` | `CrrField[]` |
| **Pathway Selection** | `…/pathways:generate` | `arc_acquisition_pathways` | `canonicalRecord` (claim-checked under `pathways/`) | `ui_projection_acquisition_pathways.json` | `pathways`, `selectedPathway` | `AcquisitionPathway[]` |
| **Package Assembly** | `…/artifacts:generate` | `arc_acquisition_package` | `canonicalRecord` + `selectedPathway` | `ui_projection_acquisition_package.json` | `scheduledArtifacts` (+ `artifacts`, `documents`) | `Artifact[]` / `AssemblyCard[]` |
| **Integrity Check** | `…/findings:generate` | `arc_acquisition_integrity` | `artifacts` (V3 output) | `ui_projection_acquisition_integrity.json` | `findings` (mergeReplace) | `FindingGroup[]` |
| **Finalize** | `…/finalize` (or download) | (reuses V3 render) | `artifacts` | `ui_projection_acquisition_ledger.json` | `ledger` | `LedgerRow[]` |

**Co-ownership of `run_state` (§2).** The server writes the AI-produced keys above; the client
writes user-edited keys (`requirementsRecordNotes`, `selectedPathway` selection, finding
`dismissed`/`edited`/`dismissReason`, document edits). The shallow top-level `mergeState` keeps
them non-conflicting. **Re-runs must preserve user-owned state** — see the merge rules per step.

**Name-mapping** (phase ↔ key ↔ stage cursor ↔ URL slug ↔ DAG) lives in **Appendix F of the
PLAN** — single source of truth; do not re-derive it here.

---

## §2 — `AcquisitionRunState` (the shared persisted blob)

The full typed interface is **Appendix E of the PLAN** — the authoritative definition; this
section governs *ownership and merge semantics*, not the field-by-field shape.

**Storage.** `acquisition_missions.run_state JSONB`, returned by
`GET /acquisition-pathways/missions/:id/state` as `{ run_state: AcquisitionRunState }`,
mutated by `PATCH …/state` (client-owned keys) and by per-step materializers (server-owned keys).

**Ownership matrix.**

| Key | Owner | Written by | Merge rule on re-run |
|---|---|---|---|
| `canonicalRecord` | server | Requirements materializer | replace whole array |
| `requirementsRecordNotes` | **client** | `PATCH …/state` | never touched by server |
| `pathways` | server | Pathway materializer | replace whole array |
| `selectedPathway` | **client** (server seeds default) | materializer seeds, then `PATCH …/state` | server seeds only if absent |
| `pathwayCommitted` | **client** | `PATCH …/state` | preserved |
| `scheduledArtifacts` | server | Package materializer | replace |
| `artifacts` (resolved card states) | **client** (server may seed terminal) | UI rebuilds; server seeds terminal only | UI owns animation state |
| `documents` / `removedDocuments` | **client** | `PATCH …/state` | preserved |
| `findings` | server + client triage | Integrity materializer (`mergeReplace`) | **preserve `edited`/`dismissed`/`dismissReason`; append only `isNew`; title-dedup per group** |
| `ledger` | server | Finalize materializer | replace |
| `*Run` handle pointers | server | trigger/materializer | replace |

**Invariant.** Every materializer must write keys whose shapes deserialize **1:1** into the five
wizard signals (Appendix E). A `SUCCESS` run with no artifact, or an artifact failing the
version-strict validator, is an **engine-contract violation** → 502 (`AcquisitionSchemaError`),
never a silent partial write.

---

## §3 — Requirements Record I/O (V1)

Fully specified in `acquisition-pathways-step1-requirements-slice.md`. Summary of the contract:

**Inputs**
- Uploaded mission documents → MinIO under `acquisition/{org}/{mission}/uploads/`, passed to the
  DAG as a **claim-check ref** in `dag_run.conf.document_uris` (§8), not inline.
- Mission scalars (`name`, `statement`) read from the mission row.

**Output — `run_state.canonicalRecord: CrrField[]`** (from `acquisition-pathways/types/crr-field.ts`):

```ts
type CrrTag = 'extracted' | 'inferred' | 'needs' | 'user'; // extraction emits first 3; 'user' = UI edit
type SourceKind = 'web' | 'library' | 'upload' | 'user-typed';

interface SourcePill { kind: SourceKind; label: string; href?: string; docId?: string; }

interface CrrField {
  label: string;        // edit key, e.g. "Estimated Value"
  icon?: string;        // material-symbol name
  tag: CrrTag;          // provenance chip; user edits flip tag → 'user'
  text: string;
  sources: SourcePill[];
}
```

**User-owned sibling:** `requirementsRecordNotes?: string` — client-only, never generated.

**Merge on re-run:** replace `canonicalRecord` wholesale; leave `requirementsRecordNotes` untouched.

---

## §4 — Pathway Selection I/O (V2)

Literal DTOs/JSON Schema/Pydantic models in `PRCR-1674-contracts.md` (`C1…C15`). Shape summary:

**Inputs**
- `run_state.canonicalRecord` — read by `triggerAcquisitionPathways()`, written to MinIO as a
  claim-check under the `pathways/` prefix, referenced in the DAG conf (§8). **422 if absent**
  (`Generate the requirements record before selecting a pathway`).

**Output — `run_state.pathways: AcquisitionPathway[]`** (+ seeded `selectedPathway`):

```ts
interface AcquisitionPathway {
  id: 'low' | 'medium' | 'high';          // tier + track id
  name: string;
  vehicle: string;
  vehicleType: 'existing' | 'new';
  tierLabel: string;
  tierIcon: string;
  contractType: string;                    // free-form pill text, NO enum
  contractTypeClass?: string;              // reserved SCSS modifier
  rationale: string;                       // limited inline HTML; UI sanitizes
  features: Array<{ icon: string; text: string; tone?: 'ok' | 'warn' | 'fail' }>;
  recommended?: string;                    // badge label; omit for non-recommended
  dimensions?: PathwayDimensions;          // protestExposure, timeToAwardMonths, vendorPoolSize,
                                           // vehicleStandUp, costRiskOwner, scopeFlexibility,
                                           // bestFor, mainRisk — feeds compare/simulate tools
  score?: { value: number; components?: Array<{ label: string; value: number }> }; // P7 scorer; optional
}

// seeded by materializer, then client-owned:
type SelectedPathway = 'low' | 'medium' | 'high' | null;
```

**Materializer:** PATCHes `run_state.pathways`; seeds `selectedPathway` to the `recommended`
tier **only if absent** (never overwrites a user selection). `pathwayCommitted` stays client-owned.

**Merge on re-run:** replace `pathways`; preserve `selectedPathway`/`pathwayCommitted` if set.

---

## §5 — Package Assembly I/O (V3)

**Inputs**
- `run_state.canonicalRecord` + `run_state.selectedPathway` — both required; claim-checked into
  the DAG conf (§8). **422 if either absent.**

**Output.** Persist the **durable `Artifact`**, not the volatile `AssemblyCard` (the UI rebuilds
animation/progress state on reload):

```ts
// run_state.scheduledArtifacts — the durable manifest (server-owned):
interface Artifact {
  key: string;
  title: string;
  subtitle?: string;
  type: string;          // 'SOW' | 'RFP' | 'AcqPlan' | 'MRR' | ... free string
  filename: string;
  pages: number;
  icon: string;
  edited?: boolean;
}

// run_state.artifacts — OPTIONAL resolved terminal card states (skip re-animation on reload):
interface ResolvedArtifactCard {
  artifact: Artifact;
  state: 'queued' | 'drafting' | 'done' | 'removed';
  progress: number;
  label: string;
  removedReason?: string;
}

// run_state.documents / removedDocuments — Rohan-created docs, distinct from artifacts (client-owned):
type RunStateDocuments = unknown[];
```

**Download:** rendered files (DOCX/PPTX/XLSX) stream via the artifact gateway
(`GET /v1/acquisition/runs/{run_id}/artifacts/...`), not direct MinIO reads.

**Merge on re-run:** replace `scheduledArtifacts`; UI owns `artifacts` card state; preserve
client `documents`.

---

## §6 — Integrity Check I/O (V4)

**Inputs**
- `run_state.artifacts` (V3 output) — the documents to check; claim-checked into the DAG conf.
  **422 if no package artifacts exist.**

**Output — `run_state.findings: FindingGroup[]`:**

```ts
type Severity = 'high' | 'med' | 'low';                 // NOTE: 'med', not 'medium'
type FindingCategory = 'policy' | 'consistency' | 'protest' | 'clause';

interface FindingSection {
  label: string;
  quote: string;
  isOffending?: boolean;
  sources?: Array<{ kind: 'web' | 'library' | 'upload'; label: string; docId?: string; href?: string }>;
}

interface Finding {
  id: string;
  artifact: string;
  severity: Severity;
  category: FindingCategory;
  categoryLabel: string;
  title: string;
  meta: string;
  sections: FindingSection[];
  actions: Array<{ label: string; icon: string; primary?: boolean; kind: 'apply' | 'dismiss' }>;
  // USER TRIAGE STATE — generator sets initial; UI owns after first render; mergeReplace preserves:
  expanded?: boolean;
  dismissed?: boolean;
  dismissReason?: string;
  edited?: boolean;        // == "applied"
  isNew?: boolean;         // mergeReplace marks genuinely-new re-run findings
}

interface FindingGroup {
  key: string;
  label: string;
  name: string;
  findings: Finding[];
}
```

**Merge on re-run — `mergeReplace` (server-side, mandatory):** for each group, **preserve**
`edited`/`dismissed`/`dismissReason`/`expanded` on findings the user already triaged; **append
only** findings not already present (title-dedup per group); mark genuinely-new ones `isNew: true`.
This mirrors the UI's client-side merge so a re-run never wipes triage.

---

## §7 — Finalize I/O (V5)

**Inputs**
- `run_state.artifacts` (V3 render output) — bundled for release; no new generation engine.

**Output — `run_state.ledger: LedgerRow[]`** (generated; display panel deferred) + a downloadable
bundle:

```ts
interface LedgerRow {
  field?: string;
  value?: string;
  confidence?: number;
  [k: string]: unknown;   // tolerant; panel UI is deferred
}
```

**Download wiring:** replace the placeholder toasts in `finalize-package-step.component.ts` with
real handlers hitting the bundle/download endpoint. **Merge on re-run:** replace `ledger`.

---

## §8 — Trigger + DAG-conf envelope (shared by every step)

Identical mechanism for all steps; specified once. PRCR-1674 `C4/C6/C8/C9/C13` is the concrete
worked instance.

### 8.1 Trigger endpoint

```
POST /acquisition-pathways/missions/:id/{step}:generate
Auth: JWT; @Permissions('acquisition-pathways')  // V6 adds finer per-tool scopes (Appendix G)
Body: { mode?: 'manual' | 'auto' }               // mode ∈ {manual, auto}; default 'manual'
→ 202 { runId: string, runType: RunType, status: RunStatus }   // a PathwaysRunResponse-shaped handle
```

Per-step endpoints **may** sit behind one facade `POST …/missions/:id/generate {phase, mode}` once
≥2 steps exist (PLAN §"Single front door") — the wizard buttons and the V6 MCP tools then call the
**same** path; generation is written once, never forked.

### 8.2 DAG-conf envelope (claim-check, never inline)

```ts
interface AcquisitionDagConf {
  mission_id: string;
  org_id: string;
  run_id: string;
  schema_version: string;          // version-strict; materializer rejects unknown
  // upstream inputs passed as MinIO claim-check refs, NOT inline blobs:
  input_refs: {
    document_uris?: string[];      // Requirements: uploaded docs
    canonical_record_key?: string; // Pathway/Package: canonicalRecord claim-check (e.g. pathways/{mission}.json)
    selected_pathway?: string;     // Package
    artifacts_key?: string;        // Integrity/Finalize
  };
}
```

The gateway upload-key validator must accept each step's claim-check prefix (`pathways/`,
`package/`, `integrity/`); PRCR-1674 `P6.0` is the precedent extension.

### 8.3 Run-poll + materializer lifecycle (reused verbatim)

```
GET /onering/runs/:id  → { status: RunStatus }   // generic over run_type; drives generate→poll AND hydrate-on-reload
```

`RunStatus` flow: `QUEUED → RUNNING → MATERIALIZING → SUCCESS | FAILED`. On terminal `SUCCESS`,
`refreshRunStatus()` dispatches by `run_type` to the step's materializer, which: (1) reads the
`ui_projection_*.json` via the gateway, (2) validates it ajv version-strict, (3) cross-checks
`run_id`/`mission_id`, (4) PATCHes the step's `run_state` key in a Phase-A/Phase-B transaction.
The in-process Airflow dev mock (`onering-airflow-mock.service.ts`) writes a fixture artifact and
flips to `SUCCESS` so api+ui build before the real DAG is green.

---

## §9 — Chat / MCP control-plane I/O (V6)

Baseline RAG chat (Answer Engine V2, `ap-chat.controller.ts`) is shipped and unchanged. V6 adds
**action**. The 38 prototype tools' production homes are **Appendix G of the PLAN**; their I/O
classes:

| Tool class | I/O shape | Home |
|---|---|---|
| **run_state reads** (`get_mission_state`, `list_documents`, `compare_pathways`, …) | in: `{mission_id, …}` → out: slice of `AcquisitionRunState` | rohan_api endpoint / MCP |
| **run_state writes** (`update_crr_field`, `select_pathway`, `apply_finding`, `dismiss_finding`) | in: `{mission_id, …delta}` → out: patched key (same merge rules as §2; `dismiss_finding` reason mandatory) | rohan_api `PATCH …/state` / MCP |
| **generation triggers** (`populate_canonical_record`, `populate_pathways`, `populate_artifacts`, `populate_findings`, `populate_ledger`) | in: `{mission_id, mode?}` → out: §8.1 run handle | fire the **same** `arc_acquisition_*` DAGs (§8) — never re-implement generation |
| **prose generators** (`complete_document`, `edit_document`, `generate_decision_memo`) | in: `{mission_id, …}` → out: HTML prose (memo = two-call grounding: rohan_api read + ONERING synth) | `arc-dag-generator` |
| **retrieval** (`search_library`, `open_source_doc`) | in: `{query|docId}` → out: chunks/doc | ONERING retrieval layer |

**Watcher:**

```
POST /acquisition-pathways/missions/:id/watcher
Body: { event: string, context: unknown }
→ 200 { reply: string }   // ≤2 sentences, NO mutations, ≤1 read-only tool; empty reply is valid
```

Watcher **gating** (enabled toggle, 60s cooldown buckets, 8/session cap, no-interrupt-during-phase,
busy-drop with single-slot replay for high-severity, reset on new mission) stays **client-side**
and decides *whether* to POST.

---

## §10 — Error responses

Shared across trigger endpoints (literal strings — agents match against these):

| Endpoint | Status | Condition | Literal message |
|---|---|---|---|
| `…/{step}:generate` | 404 | Mission not owned by caller's org | (existing AP ownership 404) |
| `…/pathways:generate` | 422 | `run_state.canonicalRecord` absent/empty | `Generate the requirements record before selecting a pathway` |
| `…/artifacts:generate` | 422 | `canonicalRecord` or `selectedPathway` absent | `Select a pathway before assembling the package` |
| `…/findings:generate` | 422 | No package artifacts exist | `Assemble the package before running the integrity check` |
| `…/{step}:generate` | 409 | Non-terminal run of this step exists | `A {step} generation run is already in progress for mission {id} (run_id={runId})` |
| materializer (internal) | 502 | Gateway 404 / schema invalid / unknown `schema_version` | `AcquisitionSchemaError` |
| materializer (internal) | — | `run_id`/`mission_id` cross-check fails | `JSON_RUN_ROW_MISMATCH` |
| gateway `…/{step}-projection` | 404 | Artifact not written | (rohan_api maps → `null` → 502 semantics above) |

> The 422 messages for Package/Integrity are **proposed defaults** — confirm exact wording with the
> V3/V4 owners before freezing (the Pathway 422 string is already shipped via PRCR-1674).
