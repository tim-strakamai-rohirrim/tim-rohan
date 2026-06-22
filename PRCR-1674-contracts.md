# PRCR-1674 — Pathway Selection API contracts

> **Companion docs.** Implementation plan: `PRCR-1674-PLAN.md`. Epic reference:
> `acquisition-pathways-onering-integration-PLAN.md` (Workstream **P**). Template this
> slice mirrors: `acquisition-pathways-step1-requirements-slice.md` (the shipped Requirements
> slice S1–S11 — its harness is reused, not rebuilt).

This is the synchronization boundary between the three repos. rohan_api (Stream B) freezes
these first; ONERING (Stream A) and rohan_ui (Stream C) build against the schema + PR diffs,
not against each other's running code.

**What pathway generation consumes.** Unlike Requirements (which ingests uploaded documents),
Pathway Selection consumes the **already-materialized `run_state.canonicalRecord`** (the
requirements record) plus mission scalars. There is **no upload step, no ingestion subset, no
`document_uris`** — the conf carries the record itself and the ONERING graph is a single LLM
synthesis call, not the 4-phase extraction. Generation is therefore gated on a non-empty
`canonicalRecord`.

**Already shipped — reused verbatim, NOT re-specified here:**

| Reused (shipped by the Requirements slice) | Where |
|---|---|
| `RunStatus.MATERIALIZING` | `src/onering/enums/run-status.enum.ts` |
| `or_pipeline_runs.mission_id` + `materialized_at` columns (index is on `organization_id`; the `run_type`+`mission_id`+status in-flight-guard query is unindexed but fine at this scale) | shipped S4 (no new DB work) |
| Per-`run_type` materializer dispatch in `refreshRunStatus()` | `onering-pipeline.service.ts:1062` |
| `reconcileTriggerFailure()` Airflow-probe idempotency | `onering-pipeline.service.ts:967` |
| Dev Airflow mock harness (`shouldHandle`/`triggerDagRun`/`getDagRunStatus`) | `onering-airflow-mock.service.ts` |
| `onering_api` `/v1/acquisition` router + `get_principal`/tenant headers | `onering_api/routers/acquisition.py` |
| FE `AcquisitionRunService.pollRun/getState/patchState` | `acquisition-run.service.ts` |
| `CrrField`/`SourcePill` types (the record input shape) | `acquisition-pathways/types/crr-field.ts` |

---

## Contract → Phase mapping

| Contract Section | Phase(s) | Notes |
|------------------|----------|-------|
| C1 `acquisition_pathways:build_steps` factory | P1 | ONERING factory — no ingestion, single synthesis step |
| C2 `pipelines.acquisition_pathways` output models | P1 | Pydantic models (ported from prototype `Pathway`) |
| C3 `ui_projection_acquisition_pathways.json` v1 | P1, P2 | P1 writes the artifact; P2 freezes the JSON Schema |
| C4 `arc_acquisition_pathways` DAG `dag_run.conf` envelope | P2 | Conf carries the record, **not** `document_uris` |
| C5 Enum extensions (`OneringDagId`/`RunType`) | P3 | `MATERIALIZING` already exists — not re-added |
| C6 `AcquisitionPathwaysConf` | P3 | Extends `DagRunConf` union |
| C7 Trigger DTO + `PathwaysRunResponse` + rohan_api `AcquisitionPathway`/`PathwayDimensions` | P3 | `class-validator` + swagger; types net-new in rohan_api |
| C8 `POST …/missions/:id/pathways:generate` | P4, P7 | P4 implements; P7 consumes |
| C9 `OneringPipelineService.triggerAcquisitionPathways()` | P4 | Reads `canonicalRecord`; mirrors `triggerAcquisitionRequirements` |
| C10 Pathways artifact validator (ajv, version-strict) | P5 | Reads via gateway; mirrors C12 of the slice |
| C11 Materializer behavior + field→`AcquisitionPathway` mapping | P5 | PATCHes `run_state.pathways` + default `selectedPathway` |
| C12 Dev Airflow mock extension (pathways fixture) | P5 | Mock `shouldHandle` accepts the pathways DAG too |
| C13 `GET /v1/acquisition/runs/{run_id}/pathways-projection` (+ trigger parity) | P6 | Gateway read route mirroring C19 of the slice |
| C14 FE consumption + hydration (`triggerPathways`, `generate` swap, `dimensions` type) | P7 | rohan_ui |

---

## C1 — `acquisition_pathways:build_steps` step factory (ONERING)

```python
# arc_agent_writer/factories/acquisition_pathways.py
from arc_agent_writer.orchestrator import StepDef

def build_steps(*, cfg, artifact_store) -> list[StepDef]:
    """Thin buyer-side pathway-synthesis graph. NO ingestion — the requirements
    record is supplied in dag_run.conf and seeded into run_meta by the DAG's stage_run.
    seed record/context → pipelines.acquisition_pathways → ui_projection."""
    # step "pipelines.acquisition_pathways"            (single LLM synthesis call)
    # step "pipelines.ui_projection_acquisition_pathways"
    ...
```

**Factory signature is keyword** `build_steps(*, cfg, artifact_store) -> list[StepDef]` — the CLI
loader always invokes factories as `fn(cfg=cfg, artifact_store=store)` (`cli.py`; mirrors the shipped
`acquisition_requirements:build_steps`). Do **not** mirror the zero-arg
`cli.py:build_strategy_only_steps()` (shipped bug). The record + mission context arrive via
`run_meta` (the DAG's `stage_run` seeds them from `dag_run.conf` — C4); the synthesis step reads
them rather than ingesting documents.

## C2 — `pipelines.acquisition_pathways` output models (ONERING)

Ported from the prototype `Pathway` / `PathwayDimensionsPerMission`
(`/Users/tim/Documents/code/UA-Acquisition-Pathways/src/app/core/models/pathway.ts` — sibling repo,
not in the `rohan` tree). The synthesis step emits **exactly
three** items (`low`/`medium`/`high`), exactly one carrying `recommended`.

```python
from typing import Literal
from arc_agent_writer.pipelines._common.record_model import RecordModel

PathwayTier = Literal["low", "medium", "high"]

class PathwayFeature(RecordModel):
    icon: str                                  # material-symbol name
    text: str
    tone: Literal["ok", "warn", "fail"] | None = None

class PathwayDimensions(RecordModel):
    # mission-specific — the prompt forbids generic reused numbers (C2 note)
    protest_exposure: Literal["low", "medium", "high"] | None = None
    time_to_award_months: dict | None = None   # {"min": int, "max": int}
    vendor_pool_size: int | None = None
    vehicle_stand_up: Literal["none", "minor", "major"] | None = None
    cost_risk_owner: Literal["contractor", "shared", "government"] | None = None
    scope_flexibility: Literal["low", "medium", "high"] | None = None
    best_for: str | None = None                # one sentence, <=400 chars
    main_risk: str | None = None               # one sentence, <=400 chars

class AcquisitionPathwayItem(RecordModel):
    id: PathwayTier
    name: str                                  # concrete vehicle, e.g. "CIO-SP4 Full & Open"
    vehicle: str                               # "NITAAC GWAC · active at FAA · Task Order"
    vehicle_type: Literal["existing", "new"]
    tier_label: str                            # "Low risk"
    tier_icon: str                             # material-symbol, e.g. "shield"
    contract_type: str                         # free text, e.g. "Firm Fixed Price (FFP)"
    rationale: str                             # limited inline HTML (<strong> ok); UI sanitizes
    features: list[PathwayFeature]
    recommended: str | None = None             # badge label, e.g. "BEST BALANCED"; one item only
    dimensions: PathwayDimensions | None = None

class AcquisitionPathwaysUIProjection(RecordModel):
    schema_version: str = "1"
    run_id: str
    mission_id: int
    pathways: list[AcquisitionPathwayItem]     # length 3
```

> **Field-name note.** The prototype dimension key was `flexibilityToScopeChange`; this contract
> standardizes on `scopeFlexibility` (the integration plan Appendix E name). Snake_case in the
> artifact (`scope_flexibility`) → camelCase in TS (`scopeFlexibility`).

## C3 — `ui_projection_acquisition_pathways.json` v1 (ONERING → rohan_api)

```jsonc
{
  "schema_version": "1",
  "run_id": "arc_...",
  "mission_id": 123,
  "pathways": [
    {
      "id": "low",
      "name": "CIO-SP4 Full & Open",
      "vehicle": "NITAAC GWAC · active at FAA · Task Order",
      "vehicle_type": "existing",
      "tier_label": "Low risk",
      "tier_icon": "shield",
      "contract_type": "Firm Fixed Price (FFP)",
      "rationale": "Leverage the GWAC FAA already holds. <strong>310+ pre-vetted vendors</strong> …",
      "features": [
        { "icon": "check_circle", "text": "No new vehicle stand-up — vehicle is live" },
        { "icon": "schedule", "text": "New vehicle adds ~6 months", "tone": "warn" }
      ],
      "recommended": "BEST BALANCED",
      "dimensions": {
        "protest_exposure": "low",
        "time_to_award_months": { "min": 4, "max": 6 },
        "vendor_pool_size": 310,
        "vehicle_stand_up": "none",
        "cost_risk_owner": "contractor",
        "scope_flexibility": "low",
        "best_for": "agencies with mature, stable requirements already on a GWAC",
        "main_risk": "limited flexibility if scope needs to shift"
      }
    }
    // … exactly two more: "medium", "high"
  ]
}
```

Path: `pipelines/acquisition_pathways_extraction/ui/ui_projection_acquisition_pathways.json`
under the run root — mirrors the shipped `REQUIREMENTS_UI_RELPATH` convention. Writer's local prefix
is `AGENT_RUNS/{run_id}/`; read-side consumers derive the runs prefix via
`onering_shared.storage.paths.runs_prefix_for(store)` — never hard-code it. Update
`docs/specs/minio_path_contract.md` in the same PR. Any rohan_api-breaking change bumps
`schema_version` (rohan_api rejects unknown versions).

## C4 — `arc_acquisition_pathways` DAG `dag_run.conf` envelope (ONERING)

The conf carries the **requirements record + mission context** in place of `document_uris`.

```jsonc
{
  "org_id": "org_123",
  "user_id": "auth0|abc",
  "mission_id": 123,
  "run_id": "arc_...",                   // bash_for_steps_factory_step() reads dag_run.conf['run_id']
  "canonical_record": [                    // run_state.canonicalRecord, verbatim (CrrField[] shape)
    { "label": "Mission / objective", "tag": "extracted", "text": "Modernize FAA terminal radar …",
      "sources": [ { "kind": "upload", "label": "AcquisitionPlan.pdf", "docId": "doc_A" } ] }
  ],
  "mission_context": {                     // mission scalars for the synthesis prompt
    "name": "FAA En-Route Radar Modernization",
    "statement": "…",                      // optional
    "naics": "541512",                     // optional
    "value_band": "$50M–$100M"             // optional
  },
  "llm_mode": "gpt5_5",                    // optional
  "verbose": false                          // optional
}
```

`canonical_record` + `mission_context` are forwarded from conf to the CLI/factory as env or
templated args (new DAG-side templating, exactly as the requirements DAG added `document_uris`/
`mission_id`). The shipped helper templates only `run_id`.

## C5 — Enum extensions (rohan_api)

```ts
// src/onering/types/airflow.types.ts
enum OneringDagId { /* …existing incl. ACQUISITION_REQUIREMENTS… */
  ACQUISITION_PATHWAYS = 'arc_acquisition_pathways' }
// src/onering/enums/run-type.enum.ts
enum RunType { /* …existing incl. ACQUISITION_REQUIREMENTS… */
  ACQUISITION_PATHWAYS = 'ACQUISITION_PATHWAYS' }
// src/onering/enums/run-status.enum.ts — MATERIALIZING ALREADY EXISTS (shipped). No change.
```

## C6 — `AcquisitionPathwaysConf` (rohan_api)

```ts
// src/onering/types/airflow.types.ts
interface AcquisitionPathwaysConf {
  org_id: string;
  user_id: string;
  mission_id: number;
  run_id: string;                          // conf key MUST be `run_id`
  canonical_record: CrrField[];            // run_state.canonicalRecord verbatim
  mission_context: {
    name: string;
    statement?: string;
    naics?: string;
    value_band?: string;
  };
  llm_mode?: string;
  verbose?: boolean;
}
// extend the DagRunConf union with AcquisitionPathwaysConf
```

`CrrField` is the shipped `acquisition-pathways/types/crr-field.ts` type (imported, not redefined).

## C7 — Trigger DTO + response + rohan_api pathway types (rohan_api)

```ts
// src/acquisition-pathways/dto/runs/generate-pathways.dto.ts
class TriggerPathwaysGenerateDto {}        // body empty; record resolved server-side from run_state

// src/acquisition-pathways/dto/runs/index.ts  (mirror RequirementsRunResponse shape exactly)
interface PathwaysRunResponse {
  arc_run_id: string;
  dag_run_id: string;
  status: RunStatus;                       // snake_case wire convention (matches RequirementsRunResponse)
}
```

```ts
// src/acquisition-pathways/types/acquisition-pathway.ts — NET-NEW in rohan_api
// (today run_state is opaque Record<string, unknown>; the materializer needs the shape).
export type PathwayTier = 'low' | 'medium' | 'high';

export interface PathwayFeature { icon: string; text: string; tone?: 'ok' | 'warn' | 'fail'; }

export interface PathwayDimensions {
  protestExposure?: 'low' | 'medium' | 'high';
  timeToAwardMonths?: { min: number; max: number };
  vendorPoolSize?: number;
  vehicleStandUp?: 'none' | 'minor' | 'major';
  costRiskOwner?: 'contractor' | 'shared' | 'government';
  scopeFlexibility?: 'low' | 'medium' | 'high';
  bestFor?: string;
  mainRisk?: string;
}

export interface AcquisitionPathway {
  id: PathwayTier;
  name: string;
  vehicle: string;
  vehicleType: 'existing' | 'new';
  tierLabel: string;
  tierIcon: string;
  contractType: string;
  rationale: string;
  features: PathwayFeature[];
  recommended?: string;
  dimensions?: PathwayDimensions;
}
```

## C8 — `POST /acquisition-pathways/missions/:id/pathways:generate` (rohan_api)

Same guards as the existing AP routes (`ap-missions.controller.ts`):
`@UseGuards(AuthGuard('jwt'), FeatureGuard, PermissionsGuard)` + `@Features('AcquisitionPathways')`
+ `@Permissions('acquisition-pathways')`, plus mission-ownership check.

- **422** when `run_state.canonicalRecord` is absent/empty (cannot score pathways without a
  requirements record — literal: `Generate the requirements record before selecting a pathway`).
- **409** when a non-terminal `ACQUISITION_PATHWAYS` run already exists for the mission
  (`QUEUED | RUNNING | MATERIALIZING`), mirroring C10 of the slice.
- Resolves `canonicalRecord` + mission scalars from the mission, calls C9, PATCHes
  `run_state.pathwaysRun = { arcRunId, status }`, returns `PathwaysRunResponse`.

> **Fastify route escape:** the literal colon in `pathways:generate` must be escaped `::` for
> find-my-way v9 (the slice's S8.4 fix-forward — `requirements:extract` hit the same trap). Pin
> the success status to `200`.

## C9 — `OneringPipelineService.triggerAcquisitionPathways()` (rohan_api)

```ts
triggerAcquisitionPathways(
  user: RequestUser,
  missionId: number,
  canonicalRecord: CrrField[],
  missionContext: { name: string; statement?: string; naics?: string; value_band?: string },
  options?: { llmMode?: string; verbose?: boolean },
): Promise<PathwaysRunResponse>
```

Mirrors `triggerAcquisitionRequirements` (`onering-pipeline.service.ts:832`) exactly, swapping the
DAG id / run_type / conf:

- In-flight guard over `RunType.ACQUISITION_PATHWAYS` (`QUEUED | RUNNING | MATERIALIZING`) → 409.
- `arc_run_id` prefix `'arc_acq_path_'`; `dagRunId = control__acq_path__{arcRunId}`.
- `INSERT or_pipeline_runs(run_type=ACQUISITION_PATHWAYS, mission_id, airflow_dag_id=ACQUISITION_PATHWAYS, status=QUEUED, …)` **before** firing the DAG.
- Build `AcquisitionPathwaysConf` (C6), `airflowFor(ACQUISITION_PATHWAYS).triggerDagRun(...)`.
- `reconcileTriggerFailure(saved, err)` on trigger failure (probe by state, no explicit 409 catch).
- Honor the existing `triggersCutoverEnabled()` branch: when on, delegate to
  `oneringApi.triggerAcquisitionPathways(...)` (C13 trigger-parity route) and reconstruct the
  `{arc_run_id, dag_run_id, status}` shape; map upstream 409 → `ConflictException`.

## C10 — Pathways artifact validator (rohan_api)

ajv@^8, compiled once at module init from the C3 schema. `additionalProperties: true`; **strict on
`schema_version`** (reject unknown → `AcquisitionSchemaError`, map to 502). As built for
requirements (rohan_api #2035): `loadAndValidate(run: OrPipelineRun)` takes the run **row** (needs
`organization_id` for tenant headers); a pure `validate(raw, contextId)` half is exposed for tests
+ the P8 E2E. **Provided by `OneringModule`** (not the AP module) to avoid a circular import — same
as the requirements validator.

## C11 — Materializer behavior + field→`AcquisitionPathway` mapping (rohan_api)

`ApPathwaysMaterializerService.materialize(arcRunId)`, mirroring the requirements materializer:

- **Phase A (no tx):** read via the gateway client (C13) + validate (C10); cross-check
  `json.run_id === run.arc_run_id` **and** `json.mission_id === run.mission_id` (reject
  `JSON_RUN_ROW_MISMATCH`).
- **Phase B (single short tx, `pessimistic_write` lock on the mission, no network IO):** map
  `pathways[]` → `AcquisitionPathway[]` (snake_case → camelCase: `vehicle_type`→`vehicleType`,
  `tier_label`→`tierLabel`, `contract_type`→`contractType`, `time_to_award_months`→`timeToAwardMonths`,
  `vendor_pool_size`→`vendorPoolSize`, `vehicle_stand_up`→`vehicleStandUp`,
  `cost_risk_owner`→`costRiskOwner`, `scope_flexibility`→`scopeFlexibility`, `best_for`→`bestFor`,
  `main_risk`→`mainRisk`). PATCH `run_state` shallow-merging:

```ts
{
  pathways: AcquisitionPathway[],
  // selectedPathway default: the recommended tier — ONLY when not already set by the user
  // (co-ownership; a re-run must not clobber the user's prior pick).
  ...(currentSelectedPathway == null
      ? { selectedPathway: pathways.find(p => p.recommended)?.id ?? null }
      : {}),
  pathwaysRun: { arcRunId, status: 'SUCCEEDED' },
}
```

  Never write `pathwayCommitted` (user-owned; the FE sets it on explicit commit). Set
  `materialized_at`; flip run `SUCCESS`. Idempotent via `materialized_at`.

## C12 — Dev Airflow mock extension (rohan_api)

The shipped mock (`onering-airflow-mock.service.ts`) is scoped to `ACQUISITION_REQUIREMENTS`.
Extend `shouldHandle(dagId)` to also accept `OneringDagId.ACQUISITION_PATHWAYS`, and have
`triggerDagRun` pick the **pathways** fixture
(`src/onering/__mocks__/ui_projection_acquisition_pathways.fixture.json`, copied from the P1 ONERING
sample) when the dag id is the pathways DAG — stamping live `run_id`/`mission_id`, serving it
in-memory at the artifact-read seam (rohan_api has no MinIO write client). Same gate as requirements:
`ONERING_AIRFLOW_BASE_URL` empty + `NODE_ENV !== 'production'` + no `KEY_VAULT_NAME` +
`ONERING_AIRFLOW_MOCK !== 'disabled'`. The C20/S10 restart-recovery path already covers both DAGs
(it keys off `shouldHandle`).

## C13 — `GET /v1/acquisition/runs/{run_id}/pathways-projection` (onering_api gateway)

Mirrors the shipped `…/requirements-projection` route (C19 of the slice). Auth
`Depends(get_principal)` + tenant headers (rohan_api sends `org_id` only on this poll-driven path).
Resolve the run prefix via `runs_prefix_for(store)`, read
`{runs_prefix}/{run_id}/pipelines/acquisition_pathways_extraction/ui/ui_projection_acquisition_pathways.json`,
return it verbatim.

| Status | Condition | Body |
|--------|-----------|------|
| 200 | Artifact exists | The raw C3 artifact JSON (gateway does not validate; rohan_api's ajv owns that) |
| 404 | Not written yet / run unknown | error body (rohan_api maps → `null` → "SUCCESS but no artifact = engine-contract violation", 502 semantics) |

rohan_api client method `getAcquisitionPathwaysProjection(runId, ctx)` mirrors
`getAcquisitionRequirementsProjection` incl. the 25 MB per-request `maxContentLength` cap (S10
finding 5) — do not touch the shared client default.

**Trigger parity (only if `triggersCutoverEnabled()` is on):** add `POST /v1/acquisition/pathways`
mirroring the requirements trigger route the cutover branch calls, owning the in-flight 409 guard.
If cutover is off in all target envs, this route is deferred (C9's legacy branch is the live path).

## C14 — FE consumption + hydration (rohan_ui)

- **`AcquisitionPathway` type** (`types/acquisition-pathways.types.ts`): add the optional
  `dimensions?: PathwayDimensions` field (matching C7's camelCase shape) — required before the UI
  can render or compare dimensions. The existing tier/vehicle/feature fields already match C7.
- **`AcquisitionRunService.triggerPathways(missionId)`** → `POST …/missions/:id/pathways:generate`
  (mirror `triggerRequirements`, `acquisition-run.service.ts:50`). Reuse the existing generic
  `pollRun` / `getState` / `patchState`.
- **`PathwaySelectionService.generate()`** (`pathway-selection.service.ts:51`): replace the
  `setTimeout` + `PATHWAY_SELECTION_MOCK_PATHWAYS` body with:
  `triggerPathways(missionId)` → `pollRun(arcRunId)` (emit QUEUED→RUNNING→MATERIALIZING for the
  loading banner) → on terminal SUCCESS `getState(missionId)` → `_pathways$.next(run_state.pathways)`
  and `_selectedTier$.next(run_state.selectedPathway ?? recommended)`. The signature stays
  side-effect-only; keep `reset()`/`selectTier()` unchanged. Keep `PATHWAY_SELECTION_MOCK_PATHWAYS`
  importable behind `?demo=1`.
- **Hydration on wizard load** with `:missionId`: if `run_state.pathways` present →
  hydrate immediately; else if `run_state.pathwaysRun.status` non-terminal → show loading + poll.
- **Persist selection:** on `selectTier`/commit, debounce-`patchState({ selectedPathway, pathwayCommitted })`.

---

## Error responses

| Endpoint | Status | Condition | Literal message |
|----------|--------|-----------|-----------------|
| `POST …/pathways:generate` | 404 | Mission not owned by caller's org | (existing AP ownership 404) |
| `POST …/pathways:generate` | 422 | `run_state.canonicalRecord` absent/empty | `Generate the requirements record before selecting a pathway` |
| `POST …/pathways:generate` | 409 | Non-terminal pathways run exists | `A pathway generation run is already in progress for mission {id} (run_id={runId})` |
| materializer (internal) | 502 | Gateway 404 / schema invalid / `schema_version` unknown | `AcquisitionSchemaError` |
| materializer (internal) | — | `run_id`/`mission_id` cross-check fails | `JSON_RUN_ROW_MISMATCH` |
| gateway `…/pathways-projection` | 404 | Artifact absent | (rohan_api maps → `null`) |
