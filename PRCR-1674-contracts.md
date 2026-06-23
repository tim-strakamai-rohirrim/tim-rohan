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
requirements record) plus mission scalars. There is **no document upload, no ingestion subset, no
`document_uris`** — rohan_api claim-checks the record to MinIO and the conf carries a **pointer**
(`canonical_record_ref`), and the ONERING graph is a single LLM synthesis call, not the 4-phase
extraction. Generation is therefore gated on a non-empty `canonicalRecord`.

**Already shipped — reused verbatim, NOT re-specified here:**

| Reused (shipped by the Requirements slice) | Where |
|---|---|
| `RunStatus.MATERIALIZING` | `src/onering/enums/run-status.enum.ts` |
| `or_pipeline_runs.mission_id` + `materialized_at` columns (index is on `organization_id`; the `run_type`+`mission_id`+status in-flight-guard query is unindexed but fine at this scale) | shipped S4 (no new DB work) |
| Per-`run_type` materializer dispatch in `refreshRunStatus()` | `onering-pipeline.service.ts:1062` |
| `reconcileTriggerFailure()` Airflow-probe idempotency | `onering-pipeline.service.ts:967` |
| Dev Airflow mock harness (`shouldHandle`/`triggerDagRun`/`getDagRunStatus`) | `onering-airflow-mock.service.ts` |
| `onering_api` `/v1/acquisition` router + `get_principal`/tenant headers | `onering_api/routers/acquisition.py` |
| Gateway upload route + `OneringApiClient.uploadAcquisitionDocument` (record claim-check write) — **client reused verbatim; the gateway key validator is extended in P6.0** to accept the `pathways/` prefix (see C9/C13) | `onering_api/routers/acquisition.py` + `onering/clients/onering-api.client.ts` |
| Engine cross-prefix `get_object_bytes(key)` read (record claim-check read) | shipped S11 (`storage/minio_store.py`/`sync_wrapper.py`) |
| FE `AcquisitionRunService.pollRun/getState/patchState` | `acquisition-run.service.ts` |
| `GET /onering/runs/:id` run-status poll endpoint (drives both `generate→poll` and hydrate-on-reload; generic over `run_type`, **not** in scope to build) | `onering` module (shipped) |
| `CrrField`/`SourcePill` types (the record input shape) | `acquisition-pathways/types/crr-field.ts` |

---

## Contract → Phase mapping

| Contract Section | Phase(s) | Notes |
|------------------|----------|-------|
| C1 `acquisition_pathways:build_steps` factory | P1 | ONERING factory — no ingestion, single synthesis step |
| C2 `pipelines.acquisition_pathways` output models | P1 | Pydantic models (ported from prototype `Pathway`) |
| C3 `ui_projection_acquisition_pathways.json` v1 | P1, P2 | P1 writes the artifact; P2 freezes the JSON Schema |
| C4 `arc_acquisition_pathways` DAG `dag_run.conf` envelope | P2 | Conf carries a **claim-check ref** to the record (MinIO key), not the record inline |
| C5 Enum extensions (`OneringDagId`/`RunType`) | P3 | `MATERIALIZING` already exists — not re-added |
| C6 `AcquisitionPathwaysConf` | P3 | Extends `DagRunConf` union |
| C7 Trigger DTO + `PathwaysRunResponse` + rohan_api `AcquisitionPathway`/`PathwayDimensions` | P3 | `class-validator` + swagger; types net-new in rohan_api |
| C8 `POST …/missions/:id/pathways:generate` | P4, P8 | P4 implements; P8 (FE) consumes |
| C9 `OneringPipelineService.triggerAcquisitionPathways()` | P4 (+ P6.0) | Reads `canonicalRecord`, claim-checks it under `pathways/`; P6.0 extends the gateway upload validator to accept that prefix (P4 happy path depends on it) |
| C10 Pathways artifact validator (ajv, version-strict) | P5 | Reads via gateway; mirrors C12 of the slice |
| C11 Materializer behavior + field→`AcquisitionPathway` mapping | P5 | PATCHes `run_state.pathways` + default `selectedPathway` |
| C12 Dev Airflow mock extension (pathways fixture) | P5 | Mock `shouldHandle` accepts the pathways DAG too |
| C13 `GET /v1/acquisition/runs/{run_id}/pathways-projection` (+ trigger parity) | P6 | Gateway read route mirroring C19 of the slice; P6 **also** ships the P6.0 upload-validator extension for the C9 claim-check write key |
| C14 FE consumption + hydration (`triggerPathways`, `generate` swap, `dimensions`/`score` types) | P8 | rohan_ui |
| C15 Contract-vehicle catalog + deterministic two-layer scorer | P7 | ONERING; populates `score`/`evidence`/`recommendationKind` behind the frozen schema |

---

## C1 — `acquisition_pathways:build_steps` step factory (ONERING)

```python
# arc_agent_writer/factories/acquisition_pathways.py
from arc_agent_writer.orchestrator import StepDef

def build_steps(*, cfg, artifact_store) -> list[StepDef]:
    """Thin buyer-side pathway-synthesis graph. NO document ingestion — the requirements
    record is claim-checked: stage_run seeds `canonical_record_ref` into run_meta; a
    load step fetches the record JSON from MinIO via the shipped cross-prefix getter.
    load_run_state_record → pipelines.acquisition_pathways → ui_projection."""
    # step "load_run_state_record"   (read canonical_record_ref from run_meta →
    #                                  store.get_object_bytes(key) → parse CrrField[])
    # step "pipelines.acquisition_pathways"            (single LLM synthesis call)
    # step "pipelines.ui_projection_acquisition_pathways"
    ...
```

**Factory signature is keyword** `build_steps(*, cfg, artifact_store) -> list[StepDef]` — the CLI
loader always invokes factories as `fn(cfg=cfg, artifact_store=store)` (`cli.py`; mirrors the shipped
`acquisition_requirements:build_steps`). Do **not** mirror the zero-arg
`cli.py:build_strategy_only_steps()` (shipped bug). `mission_context` arrives inline via `run_meta`;
the **record** is read from MinIO at `canonical_record_ref` using the shipped S11
`get_object_bytes(key)` cross-prefix getter (bare key, scheme rejected) — the same getter
`stage_documents` uses for the Requirements slice. No document ingestion subset.

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

# --- score + evidence: OPTIONAL (P1 pure-LLM may leave score thin / omit it; P7's catalog
# scorer populates them). Present so P7 + the grounding/provenance fast-follow drop in
# WITHOUT a schema_version bump (P7 = C15; see "Future work" in the PLAN). ---
class PathwayScoreComponent(RecordModel):
    key: str                                   # e.g. "ceiling_fit"
    label: str
    weight: float | None = None
    value: float | None = None                 # 0..1
    rationale: str | None = None

class PathwayScore(RecordModel):
    total: float                               # 0..100 (v1 may derive from the LLM's overall fit)
    deterministic: float | None = None         # 0..1 — populated when the catalog scorer lands
    llm: float | None = None                   # 0..1
    components: list[PathwayScoreComponent] | None = None
    disqualifiers: list[dict] | None = None    # [{"code": str, "reason": str}]

class PathwayEvidence(RecordModel):           # → SourcePill[] in the materializer
    kind: Literal["upload", "web", "library"] | None = None
    label: str                                 # title / doc_name / doc_id
    href: str | None = None                    # web citations
    doc_id: str | None = None                  # library/upload citations
    snippet: str | None = None

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
    recommendation_kind: Literal["best-balanced", "best-fit"] | None = None  # forward-compat for re-rank
    dimensions: PathwayDimensions | None = None
    score: PathwayScore | None = None          # optional in v1
    evidence: list[PathwayEvidence] | None = None  # optional in v1; may be empty

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
      "recommendation_kind": "best-balanced",
      "dimensions": {
        "protest_exposure": "low",
        "time_to_award_months": { "min": 4, "max": 6 },
        "vendor_pool_size": 310,
        "vehicle_stand_up": "none",
        "cost_risk_owner": "contractor",
        "scope_flexibility": "low",
        "best_for": "agencies with mature, stable requirements already on a GWAC",
        "main_risk": "limited flexibility if scope needs to shift"
      },
      "score": {                                // OPTIONAL in v1 — pure-LLM may emit just `total`
        "total": 91,
        "deterministic": null,                  // populated when the catalog scorer lands (no version bump)
        "llm": 0.91,
        "components": [],
        "disqualifiers": []
      },
      "evidence": [                             // OPTIONAL in v1; may be empty
        { "kind": "library", "label": "FY24 NITAAC award history", "doc_id": "lib_42",
          "snippet": "3 analogous FAA radar awards on CIO-SP4 …" }
      ]
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

> **Forward-compat (deliberate).** `score`, `evidence`, and `recommendation_kind` are **optional**
> and `additionalProperties: true` so the JSON Schema frozen at P2 already accommodates **P7's
> deterministic two-layer scorer** (score breakdown + disqualifiers — C15, in this ticket) and the
> grounding/provenance + re-rank fast-follows — all land as **content** changes behind this frozen
> schema, with **no `schema_version` bump**. P1 (pure-LLM) may emit a thin `score` (`total` only) and
> an empty `evidence`; P7 fills them. The ajv validator (C10) must not require them.

## C4 — `arc_acquisition_pathways` DAG `dag_run.conf` envelope (ONERING)

The conf carries a **MinIO pointer to the requirements record** + mission context in place of
`document_uris`. The record is **claim-checked** (written to MinIO by rohan_api, referenced by key)
rather than passed inline — a `canonicalRecord` can be large (many fields × evidence snippets) and
`dag_run.conf` is size-bounded (it lands in Airflow's metadata DB). This mirrors the Requirements
slice's `document_uris` mechanism and reuses the **shipped** `uploadAcquisitionDocument` client + the
**shipped** S11 cross-prefix `get_object_bytes` read; the gateway upload-key validator is extended in
**P6.0** to accept the `pathways/` prefix (the only net-new write-side plumbing — see C9/C13).

```jsonc
{
  "org_id": "org_123",
  "user_id": "auth0|abc",
  "mission_id": 123,
  "run_id": "arc_...",                   // bash_for_steps_factory_step() reads dag_run.conf['run_id']
  "canonical_record_ref": "acquisition/org_123/123/pathways/{arc_run_id}/canonical_record.json",
                                         // MinIO bare object key; stage_run fetches it into run_meta.
                                         // Top-level `pathways/` prefix — the gateway upload
                                         // validator is extended to accept it (C9 / P6.0).
  "mission_context": {                     // small scalars — inline is fine
    "name": "FAA En-Route Radar Modernization",
    "statement": "…",                      // optional
    "naics": "541512",                     // optional
    "value_band": "$50M–$100M"             // optional
  },
  "llm_mode": "gpt5_5",                    // optional
  "verbose": false                          // optional
}
```

`canonical_record_ref` is seeded into `run_meta` by the DAG's `stage_run` (the factory reads it back
via the shipped `get_object_bytes(key)` cross-prefix getter — bare key, scheme rejected per S11).
`mission_context` is small enough to forward inline (env/templated arg, exactly as the requirements
DAG forwarded `mission_id`). The shipped helper templates only `run_id`.

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
  canonical_record_ref: string;            // MinIO bare key; the record is claim-checked, NOT inline
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

// score + evidence are OPTIONAL — present so the deterministic scorer + provenance
// fast-follow drop in without a type change (see PLAN "Future work").
export interface PathwayScoreComponent {
  key: string; label: string; weight?: number; value?: number; rationale?: string;
}
export interface PathwayScore {
  total: number; deterministic?: number; llm?: number;
  components?: PathwayScoreComponent[];
  disqualifiers?: { code: string; reason: string }[];
}
export type PathwayRecommendationKind = 'best-balanced' | 'best-fit';

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
  recommendationKind?: PathwayRecommendationKind;
  dimensions?: PathwayDimensions;
  score?: PathwayScore;
  evidence?: SourcePill[];                    // mapped from artifact evidence[]; reuses the shipped SourcePill
}
```

`SourcePill` is the shipped `acquisition-pathways/types/crr-field.ts` type (reused, not redefined).

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
- **Audit trail:** write an audit entry for the generate action under the existing
  `AuditTrailFeature.ACQUISITION_PATHWAYS` if-and-as the slice does for `requirements::extract`
  (match the slice's pattern; don't invent a new one). Omit if the slice doesn't audit triggers.

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
- **Claim-check the record:** serialize `canonicalRecord` to JSON and write it to MinIO at
  `acquisition/{org_id}/{mission_id}/pathways/{arcRunId}/canonical_record.json` via the gateway
  upload route (`OneringApiClient.uploadAcquisitionDocument`, the same client S5 of the Requirements
  slice already uses). The returned key is `canonical_record_ref`. Do this **before** the DAG
  trigger; on upload failure, fail the run row and surface the error (don't trigger a DAG that can't
  read its input).
  > **Gateway dependency (P6.0).** The shipped upload route validates the key as
  > `acquisition/{org_id}/{mission_id}/uploads/…/{filename}` — the 4th segment must currently be
  > `uploads`, so a top-level `pathways/` key is **rejected 400** until **P6.0 extends the validator**
  > (`_parse_acquisition_upload_key`) to whitelist a `pathways/` folder alongside `uploads/` (4th
  > segment ∈ {`uploads`, `pathways`}). All other guards stay: the `{org_id}` segment must equal the
  > caller's tenant org (403), traversal/absolute/unsafe segments rejected (400). rohan_api has no
  > direct-MinIO write (gateway is the only write path), so **P4's happy path depends on P6.0 being
  > deployed**; P4 can be coded/tested with the client mocked. The engine read side
  > (`get_object_bytes`, S11) already accepts any key under the `acquisition/` whitelist, so the read
  > is unaffected.
- `INSERT or_pipeline_runs(run_type=ACQUISITION_PATHWAYS, mission_id, airflow_dag_id=ACQUISITION_PATHWAYS, status=QUEUED, …)` **before** firing the DAG.
- Build `AcquisitionPathwaysConf` (C6) with `canonical_record_ref`,
  `airflowFor(ACQUISITION_PATHWAYS).triggerDagRun(...)`.
- `reconcileTriggerFailure(saved, err)` on trigger failure (probe by state, no explicit 409 catch).
- Honor the existing `triggersCutoverEnabled()` branch: when on, delegate to
  `oneringApi.triggerAcquisitionPathways(...)` (C13 trigger-parity route) and reconstruct the
  `{arc_run_id, dag_run_id, status}` shape; map upstream 409 → `ConflictException`.

## C10 — Pathways artifact validator (rohan_api)

ajv@^8, compiled once at module init from the C3 schema. `additionalProperties: true`; **strict on
`schema_version`** (reject unknown → `AcquisitionSchemaError`, map to 502). As built for
requirements (rohan_api #2035): `loadAndValidate(run: OrPipelineRun)` takes the run **row** (needs
`organization_id` for tenant headers); a pure `validate(raw, contextId)` half is exposed for tests
+ the P9 E2E. **Provided by `OneringModule`** (not the AP module) to avoid a circular import — same
as the requirements validator. `score`, `evidence`, and `recommendation_kind` are **optional** in
the schema (v1 pure-LLM may omit/thin them; P7 populates them) — the validator must not require them.

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
  `main_risk`→`mainRisk`). Pass `score` + `recommendation_kind`→`recommendationKind` through when
  present (optional in v1). Map `evidence[]` → `SourcePill[]`: `kind` (default `'upload'`), `label`
  (`evidence.label`), `href`, `docId` (`evidence.doc_id`) — mirroring the requirements materializer's
  evidence→pill mapping; an absent/empty `evidence` yields `evidence: []` (or omit). PATCH `run_state`
  shallow-merging:

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

**Concurrency (co-ownership).** Phase B's PATCH and the FE-driven `PATCH run_state` endpoint MUST
both do an atomic read-modify-write under the **same `pessimistic_write` lock** on the mission row,
applying a **shallow top-level merge** (never a full-blob overwrite). This is what makes the
materializer's `pathways`/default-`selectedPathway` write and the user's `selectedPathway`/
`pathwayCommitted` writes non-conflicting (Assumption #3). If the shipped generic PATCH endpoint
does not already lock+shallow-merge, wiring it to do so is a P5 prerequisite. Covered by a
concurrent-write test (FE-PATCH lands mid-materialize, and the reverse).

**Terminal-failure propagation.** On a terminal **non-SUCCESS** outcome for an `ACQUISITION_PATHWAYS`
run — the DAG ends `FAILED`, or validation/materialization raises (`AcquisitionSchemaError`,
`JSON_RUN_ROW_MISMATCH`) — `refreshRunStatus()` must stamp the terminal status into
`run_state.pathwaysRun.status` (locked shallow-merge, same path as above), not only the
`or_pipeline_runs` row. The C14 hydrate-on-reload path treats a non-terminal `pathwaysRun.status` as
"still running, keep polling"; without the failure stamp it loops forever. Mirror the requirements
slice's run-state failure stamp if one exists; otherwise this is net-new for pathways.

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

**Claim-check upload stub (mock mode).** Under the same gate, `triggerAcquisitionPathways` must
**skip** the real `OneringApiClient.uploadAcquisitionDocument` call and synthesize
`canonical_record_ref` = the would-be key directly. The mock serves a fixed fixture and never
dereferences the record (rohan_api has no MinIO write client), so the upload is pure waste locally —
skipping it lets the full slice run with **no gateway reachable**, and means the P6.0 upload-key
extension only matters against a real gateway. Reuse the mock's enablement predicate so mock mode
stays all-or-nothing (trigger + artifact-read + claim-check-write all stubbed together).

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

**Upload-key extension (P6.0, unconditional — the C9 write side):** extend
`_parse_acquisition_upload_key` in `onering_api/services/acquisition.py` to whitelist a top-level
`pathways/` folder alongside `uploads/` (4th segment ∈ {`uploads`, `pathways`}), so rohan_api's
claim-check write to `acquisition/{org_id}/{mission_id}/pathways/{arc_run_id}/canonical_record.json`
is accepted. Preserve every other guard: `{org_id}` segment must equal the caller's tenant org
(403); reject traversal/absolute/unsafe segments (400). Tests: caller-org `pathways/` key accepted;
cross-org `pathways/` key → 403; traversal → 400. **P4's happy path depends on this.**

**Trigger parity (only if `triggersCutoverEnabled()` is on):** add `POST /v1/acquisition/pathways`
mirroring the requirements trigger route the cutover branch calls, owning the in-flight 409 guard.
If cutover is off in all target envs, this route is deferred (C9's legacy branch is the live path).

## C14 — FE consumption + hydration (rohan_ui)

- **`AcquisitionPathway` type** (`types/acquisition-pathways.types.ts`): add the optional
  `dimensions?: PathwayDimensions` field (matching C7's camelCase shape) — required before the UI
  can render or compare dimensions — plus the optional `score?: PathwayScore`,
  `evidence?: SourcePill[]`, and `recommendationKind?: PathwayRecommendationKind` fields (mirror C7;
  the cards can ignore them in v1, but they future-proof the type for the score/provenance and
  re-rank fast-follows). The existing tier/vehicle/feature fields already match C7.
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
  hydrate immediately; else if `run_state.pathwaysRun.status` **non-terminal** → show loading + poll;
  else if `run_state.pathwaysRun.status` **terminal non-SUCCESS** (FAILED) → show the error/retry
  state, do **not** poll. (Relies on the C11 terminal-failure stamp; without it the wizard would
  poll a dead run forever.)
- **Error state on generate/poll:** `generate()` must surface a terminal non-SUCCESS run as an error
  (emit an error signal / `_error$.next(...)`), not hang on the loading banner. The loading banner
  covers `QUEUED → RUNNING → MATERIALIZING`; a terminal FAILED ends it with a retry affordance.
- **Persist selection:** on `selectTier`/commit, debounce-`patchState({ selectedPathway, pathwayCommitted })`.
  (`patchState` must be the locked shallow-merge PATCH — see C11 Concurrency.)

## C15 — Contract-vehicle catalog + deterministic two-layer scorer (ONERING, P7)

The defensibility upgrade, **in-scope this ticket** (P7), landed before the FE swap. Populates the
reserved `score`/`evidence`/`recommendation_kind` (C2/C3) — **content behind the P2-frozen schema, no
`schema_version` bump**. Ports the integration plan's two-layer pattern and the catalog from Alex's
design.

**Vehicle catalog** — `arc_agent_writer/acquisition/vehicles/`:

```python
class Vehicle(RecordModel):                    # closed enums where the scorer keys off them; free text for LLM/UI
    id: str; name: str
    family: Literal["OPEN_MARKET","MAS","GWAC","IDIQ","BPA","SOLE_SOURCE","OTA"]
    far_authority: str
    status: Literal["ACTIVE","ONRAMPING","AWARD_PENDING","SUNSETTING","EXPIRED","CANCELLED"]
    ordering_period_end: str | None = None     # ISO date; CI warns within 90 days
    scope_summary: str
    naics_families: list[str]; psc_families: list[str]; in_scope_keywords: list[str]
    ceiling_usd: float | None = None; order_ceiling_usd: float | None = None
    set_aside: list[Literal["FULL_AND_OPEN","SB","EIGHT_A","SDVOSB","WOSB","HUBZONE"]]
    time_to_award_band: Literal["WEEKS_1_2","MONTHS_1_3","MONTHS_3_6","MONTHS_6_12","MONTHS_12_PLUS"]
    time_to_award_months_min: int; time_to_award_months_max: int   # → dimensions.timeToAwardMonths
    vendor_pool_count_typical: int | None = None                   # → dimensions.vendorPoolSize
    protest_exposure: Literal["LOW","MODERATE","HIGH","SEVERE"]     # SEVERE→high, MODERATE→medium at projection
    scope_change_flexibility: Literal["RIGID","MODERATE","FLEXIBLE","VERY_FLEXIBLE"]
    cost_risk_owner: Literal["GOVERNMENT","SHARED","CONTRACTOR"]    # lowercased at projection
    competition_required: bool; requires_prior_award_to_use: bool
    confidence: Literal["VERIFIED_WEB","SME_VERIFY","ESTIMATED"]    # marks what the SME must validate
    sources: list[dict]                                            # [{label,url,retrieved}] → evidence[]
    last_reviewed: str
```

`load_vehicle_catalog()` — version-strict (`SCHEMA_VERSION='1'`), `lru_cache`, **no network/DB**
(air-gap baked). Calendar `CATALOG_VERSION` (e.g. `2026.06.1`), stamped into the artifact.
**Engineering ships a defensible v1** (~15–20 rows incl. lifecycle flags — e.g. CIO-SP4 CANCELLED,
NITAAC SUNSETTING, **plus one always-eligible open-market / Full & Open row** as the guaranteed
3-tier floor); the contracting SME validates `SME_VERIFY` rows behind this schema.

**Deterministic layer** — `DeterministicVehicleScores{ composite, disqualified, disqualifier_reasons }`,
10 weighted signals (sum 1.00): requirement_fit .18, ceiling_fit .15, set_aside_eligibility .14,
naics_psc_applicability .12, time_to_award .10, protest_exposure .09, vendor_pool_depth .07,
scope_change_flexibility .06, cost_risk_alignment .05, agency_already_holds .04. **Hard disqualifiers
(composite → 0):** value > `ceiling_usd`; est. per-order > `order_ceiling_usd`; required set-aside the
vehicle can't satisfy; non-`ACTIVE` status.

**LLM layer + blend** — per-vehicle assessment via `call_structured` (gated on `!disqualified`,
reuses P1's persona) → `overall_fit ∈ [0,1]`. **Bounded fan-out:** assess only the **top-K**
non-disqualified vehicles by deterministic composite (`K` default 8), **concurrently**
(`ThreadPoolExecutor`), so added latency ≈ one LLM round-trip — not K sequential calls (matters
against the Assumption-#5 poll cadence). `composite = 0.40·det + 0.60·llm` (or `det·0.40` when the
LLM didn't run). `collapse_to_tiers` → exactly 3 by a speed-vs-control risk index (best composite per
band). **Fewer-than-3-eligible:** when hard disqualifiers leave <3 eligible vehicles, backfill from
the highest-composite **disqualified** vehicles, each surfaced with its disqualifier reason
(`tone:'fail'` feature + populated `disqualifiers[]`) — never silently hidden. The catalog MUST
include an always-eligible **open-market / Full & Open** entry (nothing to disqualify on) as the
guaranteed floor. `choose_recommended` → balanced default (`recommendation_kind:'best-balanced'`);
**tiebreak `low > medium > high`**; a backfilled (disqualified) tier is never `recommended`.

**Output:** the existing `AcquisitionPathwayItem` (C2), now with `score` populated
(`total` 0–100, `deterministic`, `llm`, `components[]`, `disqualifiers[]`), `recommendation_kind`, and
`evidence[]` from each chosen vehicle's `sources[]`. Artifact path/schema unchanged.

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
