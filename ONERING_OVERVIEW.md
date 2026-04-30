# ONERING: Comprehensive Overview

## What It Is

ONERING is the codename for **ARC Agent Writer**, an automated proposal-generation system. It ingests RFP (Request for Proposal) documents from government and commercial sources and produces complete proposal packages as Microsoft Office files — DOCX (Word), PPTX (PowerPoint), and XLSX (Excel). The whole system is built around a resumable, 22-step DAG (Directed Acyclic Graph) pipeline orchestrated through OpenAI's GPT-5.2 model, with deep-research synthesis from the o3-deep-research model.

It lives at `/Users/tim/Documents/code/rohan/ONERING/` and is embedded as a git submodule inside `rohan-python-api/backend/arc_agent_writer/`.

## Repository Layout

```
arc_agent_writer/
├── cli.py              (~9K lines) — CLI entry point; the canonical DAG is defined
│                                     in build_builtin_steps() at line 7953
├── orchestrator.py     (~48KB)     — DAG runner using Kahn's algorithm for topological sort
├── artifact_store.py   (~40KB)     — File-based persistence with atomic writes + manifest checkpointing
├── config.py           (~42KB)     — Pydantic v2 config; env-var overrides via prefix ARC_,
│                                     nested delimiter __
├── arc_config.json                 — Runtime config file (~5KB)
├── ingestion/          (~1.3MB across 11 files)  — Document parsing, OCR, chunking
├── pipelines/                                    — Six extraction pipelines + compliance matrix
├── pipelines_gold/                               — "GOLD" reference-proposal pattern mining
├── writer/                                       — Section drafting / critique / revision
├── render/                                       — DOCX, PPTX, XLSX renderers
├── llm/                (~144KB)                  — LLM (Large Language Model) controller
├── storage/                                      — MinIO and local filesystem backends
├── integrations/                                 — OneDrive (Microsoft Graph) client
├── opportunities/                                — SAM.gov opportunity discovery
├── amendments/                                   — Post-publish tracked-change handling
└── tests/                                        — Sparse pytest suite
```

## The 22-Step DAG Pipeline

A DAG is a graph where steps have dependencies but no cycles, so the orchestrator can compute a valid execution order and run independent steps in parallel. Each step is registered as a `StepDef` (Step Definition) object, and the run manifest tracks each step's status as PENDING → RUNNING → SUCCEEDED/FAILED/SKIPPED.

### Ingestion Phase (10 steps)

1. **`ingestion.docling_parse_base`** — Docling is a document-parsing library that handles PDF, DOCX, PPTX, XLSX, and ZIP, producing a structured DOM (Document Object Model) representation.
2. **`ingestion.missing_image_recovery`** — Detects vector graphics, org charts, and figures that Docling missed.
3. **`ingestion.page_classifier`** — Classifies each page as text-based or image-only (scanned).
4. **`ingestion.docling_parse_ocr_pages`** — Runs OCR (Optical Character Recognition) on image-only pages via Docling.
5. **`ingestion.openai_page_ocr`** — Falls back to GPT-5.2 vision for pages where Docling OCR is insufficient.
6. **`ingestion.openai_image_ocr`** — Runs OCR on extracted figures and tables using OpenAI multimodal calls.
7. **`ingestion.canonical_markdown`** — Merges DOM and OCR outputs into a single `canonical.md` file with marker tags (`ARC_PAGE_START`, `ARC_FIGURE_START`, `ARC_IMAGE_OCR_START`).
8. **`ingestion.line_numbering`** — Assigns immutable line IDs; this is what enables every later extraction to cite specific lines as evidence.
9. **`ingestion.line_map`** — Builds a mapping from line number to page and bbox (bounding box) coordinates so the UI can highlight source spans.
10. **`ingestion.chunk_plan`** — Splits the document into ~55K-token chunks with 1K overlap, preferring heading boundaries.

### Extraction Phase (12 steps — six domains, each with extract + UI projection)

Each domain follows the same pattern: parallel chunk-level extraction (up to 20 workers, GPT-5.2 with strict JSON schema) → per-document aggregation → cross-document aggregation → UI projection (a plain-text JSON summary the frontend can render).

- **`pipelines.metadata`** — Title, dates, agency, NAICS (North American Industry Classification System) codes, contract vehicle.
- **`pipelines.instructions`** — Submission mechanics, formatting rules, required certifications.
- **`pipelines.attachments`** — Referenced forms, templates, and field structures.
- **`pipelines.structure`** — Response volumes, section hierarchy, page limits.
- **`pipelines.evaluation`** — Evaluation factors, subfactors, weights, scoring methods.
- **`pipelines.requirements`** — "Shall / must / will" statements, mapped onto the structure tree and the evaluation factors.

### Aggregation, Writing, and Rendering

- **`pipelines.compliance_matrix`** — Merges the six UI projections into a requirement × structure × evaluation cross-reference and emits both JSON and a six-tab XLSX.
- **`pipelines.proposal_outline`** — Generates the writing plan from the compliance matrix.
- **Writer prep** (`writer_prep_pipeline.py`, ~60KB) — Calls the o3-deep-research model with web search to produce competitive analysis and strategy synthesis.
- **Section writer** (`writer/section_writer.py`, ~36KB) — For each writing unit: assembles ~260K tokens of context (strategy, compliance matrix, GOLD patterns, consistency ledger), then runs draft → critique (deterministic, temperature=0) → revise, updating a consistency ledger so later sections stay coherent with earlier ones.
- **Renderers** — `docx_renderer.py` produces WordprocessingML with `{{ANCHOR:id}}` placeholders for amendments; `pptx_renderer.py` and `xlsx_renderer.py` handle slides and spreadsheets respectively, preserving formulas and named ranges.

## The GOLD Pipeline

GOLD is a parallel pipeline that mines past *winning* proposals for reusable patterns. It runs three LLM passes:

- **Pass 1** (3 sub-prompts) — Structure skeleton, content units, visual inventory.
- **Pass 2** (4 sub-prompts) — Rhetorical flow; FBPV (Features, Benefits, Proofs, Value — a standard proposal-writing framework); linguistic quality; callout content.
- **Pass 3** (4 sub-prompts) — Tables, graphics, past-performance citations, resumes.
- **Aggregation** — Per-document `pro_document.json` files merge into `master_pro.json`, which the section writer uses as a template library.

## Run Artifacts

Every run lives under `AGENT_RUNS/{run_id}/`:

```
{run_id}/
├── manifests/
│   ├── run_manifest.json              ← DAG state: per-step status, output pointers
│   └── history/                       ← Timestamped snapshots if enabled
├── logs/events.jsonl                  ← Append-only audit log
├── documents/{doc_id}/
│   ├── raw/{filename}                 ← Original RFP files
│   └── source.json                    ← File metadata (size, SHA256, ingested_at)
├── discovery/                         ← SAM.gov scoring data, if discovery was used
├── ingest_output/docs/{doc_id}/canonical/
│   ├── canonical.md
│   ├── line_numbered.md
│   ├── line_offsets.json
│   ├── line_map.json
│   ├── chunk_plan.json
│   └── page_classification.json
├── pipelines/{domain}/ui/*.json
├── pipelines/compliance_matrix/{json,xlsx}
├── pipelines/proposal_outline/ui/writing_plan.json
├── writer_prep/strategy_context.json
├── writer/
│   ├── drafts/{unit_id}/{v1,v2}.json
│   └── consistency_ledger.json
├── rendered/volume_*.{docx,pptx,xlsx}
├── render/insertion_maps/{stem}.json  ← Paragraph IDs for amendment tracking
├── llm_calls/{step}/{prompt}/{call_id}/
│   ├── request.json
│   ├── response.raw.json
│   ├── output.parsed.json
│   └── metrics.json
└── publish/{local,onedrive}/
```

The artifact store uses atomic writes (write to a temp file, then rename) so a crashed run never produces a half-written file. To resume, the orchestrator loads the manifest, finds the last SUCCEEDED step, and continues from there.

## CLI Surface

The entry point is `uv run python -m arc_agent_writer.cli`. (`uv` is a fast Python package manager / runner that replaces `pip` + `venv`.)

**Main commands:**
- `run-from-upload` — Create a new run from local files or a folder.
- `resume-run {run_id}` — Continue an existing run from where it left off.
- `apply-amendment` — Apply post-publish amendment files to an existing run.
- `render-only` — Re-render outputs without re-running the pipeline (useful for debugging the renderers).
- `run-discovery-daily` — Scheduled job runner for SAM.gov opportunity discovery.

**Useful flags:**
- `--builtin-steps` or `--steps-factory mod:fn` — Use the default DAG or supply a custom step graph.
- `--start-at`, `--stop-after`, `--only`, `--skip` — Control which steps run.
- `--force-rerun step1,step2` — Re-execute specific steps even if they previously succeeded.
- `--max-step-retries N`, `--dry-run`, `--verbose`.

**Example** — re-run only the requirements extraction:
```bash
uv run python -m arc_agent_writer.cli resume-run my_run \
  --builtin-steps \
  --start-at pipelines.requirements \
  --stop-after pipelines.ui_projection_requirements \
  --force-rerun pipelines.requirements
```

## External Dependencies

**LLMs:**
- **GPT-5.2** — Primary model for extraction, drafting, critique, and OCR vision calls. Invoked via the OpenAI Responses API with strict JSON schema validation.
- **o3-deep-research** — Used for strategy synthesis with web-search tool access enabled.
- **tiktoken** — Token counter, used for context-window budget management.

**Document parsing:**
- **Docling** (v2.72+) — Primary multi-format parser, producing both DOM and image extracts.
- **PyMuPDF** — Supplementary PDF handling.
- **Tesseract** — Optional local OCR engine.

**Rendering:**
- **python-docx**, **python-pptx**, **openpyxl** — Office-format generation libraries.

**Authentication and storage:**
- **MSAL** (Microsoft Authentication Library) — OneDrive auth via device-code or client-credentials flow.
- **MinIO** — S3-compatible object storage; ONERING uses an async client with a `SyncMinIOStore` wrapper that bridges to the synchronous ArtifactStore interface.

ONERING hosts no vector database itself, but it does use OpenAI's hosted vector stores for one specific retrieval task. See the *Retrieval Architecture* section below for the full breakdown.

## Configuration

`arc_config.json` is the runtime config file, with sections for `execution`, `logging`, `artifact_store`, `ingestion`, `ocr`, `chunking`, `writing_context`, `llm` (per-task settings), `openai`, `onedrive`, and `discovery`.

Any setting can be overridden by environment variable using the prefix `ARC_` and `__` as a nested-key delimiter:
```bash
export ARC_LLM__WRITING_DRAFT__TEMPERATURE=0.4
export ARC_OPENAI__API_KEY=sk-...
```

## How It Connects to the Rest of the Application

The platform is a multi-repo workspace. Here's the request flow end-to-end:

```
rohan_ui (Angular frontend)
   │  user uploads RFP
   │  REST over HTTPS, JWT (JSON Web Token) from Auth0 or Okta
   ▼
rohan_api (NestJS, TypeScript)
   │  authentication, RBAC (Role-Based Access Control), multi-tenant scoping
   │  HTTP client at src/utils/rfp-python-server/, JWT-authenticated
   ▼
rohan-python-api (FastAPI, Python)
   │  queues work via Azure Service Bus
   │  calls into the embedded ONERING submodule
   ▼
ONERING ARC Agent Writer
   │  22-step DAG executes, writing artifacts under AGENT_RUNS/{run_id}/
   ├──► MinIO (objects: raw docs, intermediate JSON, rendered Office files)
   ├──► PostgreSQL (run metadata, document records — owned by rohan-python-api)
   └──► OneDrive (optional: published proposal packages)
   ▲
   │  manifest + UI projections
rohan_api polls or streams status
   ▲
   │
rohan_ui renders the compliance matrix, drafts, and download links
```

**Submodule integration:** ONERING is added to rohan-python-api via:
```bash
git submodule add git@github.com:rohancapture/ONERING.git backend/arc_agent_writer
```
A GitHub Actions workflow (`notify-downstream.yml`) automatically opens a PR (Pull Request) on rohan-python-api whenever ONERING's `main` branch updates.

**Planned FastAPI endpoints** (the rohan-python-api wrapper around the orchestrator):
- `POST /api/v1/arc-agent-writer/runs` — Create a new run.
- `POST /runs/{id}/documents` — Upload documents.
- `POST /runs/{id}/start` — Begin execution.
- `GET /runs/{id}` — Get run status.
- `POST /runs/{id}/resume` — Resume a paused or failed run.

The handler pattern is straightforward: load config → instantiate ArtifactStore (local or MinIO) → instantiate `RunOrchestrator` → call `run()` or `resume()` → return the manifest plus output pointers. The relevant environment variables in API mode are `ARC_WORKSPACE_ROOT` (e.g., `/data/arc-runs`), `ARC_CONFIG_PATH`, and `OPENAI_API_KEY`.

## Where the Outputs End Up

1. **Local filesystem** (development default) — `AGENT_RUNS/{run_id}/rendered/`.
2. **MinIO** (production) — Objects under `{bucket}/runs/{run_id}/`.
3. **OneDrive** (optional) — Microsoft Graph upload to paths like `ARC Agent Writer/{opportunity_id}/Vol I/`.
4. **PostgreSQL** — Run metadata and document records, stored by rohan-python-api.

The UI projection JSON files (`ui_projection_*.json`) are the contract surface between ONERING and the frontend — the Angular UI reads these to render the compliance matrix, structure tree, and evaluation factors live as the run progresses. The compliance-matrix XLSX is downloadable as-is, and the insertion maps under `render/insertion_maps/` make it possible to apply tracked amendments to already-published documents.

## Why the Architecture Looks Like This

- **Determinism** — Kahn's algorithm gives a stable topological order, so a run is reproducible.
- **Resumability** — The manifest is the source of truth for step state, so any run can recover from any failure.
- **Artifact-first design** — The manifest stores only lightweight pointers; large outputs go to disk or MinIO.
- **Parallelism** — Up to 4 in-process steps in parallel by default (controlled by `ARC_MAX_PARALLEL_STEPS`), plus 20 concurrent workers per chunk-level extraction.
- **Auditability** — Every LLM call is persisted under `llm_calls/{step}/{prompt}/{call_id}/` with the full request, response, parsed output, and metrics.
- **Extensibility** — `--steps-factory mod:fn` lets you swap the entire DAG without changing the orchestrator.

## Key-File Cheat Sheet

| File | Purpose |
|------|---------|
| `cli.py:7953` | DAG definition in `build_builtin_steps()` |
| `orchestrator.py` | Kahn-algorithm DAG runner |
| `artifact_store.py` | Persistence and manifest layer |
| `writer/section_writer.py` (~36KB) | Draft / critique / revise loop |
| `writer_prep_pipeline.py` (~60KB) | Strategy synthesis with deep research |
| `pipelines/compliance_matrix/` | Cross-domain merge into JSON + XLSX |
| `ingestion/canonical_markdown_builder.py` (~98KB) | Merges DOM and OCR overlays |
| `ingestion/line_numbering.py` (~47KB) | Immutable line IDs for evidence linking |

The test suite (`tests/test_storage.py` and friends) is intentionally sparse — most validation comes from running the CLI against real RFP fixtures.

## Clarifications & Deeper Dives

These sections expand on points that warranted more precision than the high-level overview gave.

### Pipeline Parallelism Has Two Axes

It's tempting to picture extraction as "each chunk fans out to all six pipelines in parallel," but that's not quite right. Parallelism actually happens on two independent axes:

1. **Across pipelines.** The six extraction pipelines (`metadata`, `instructions`, `attachments`, `structure`, `evaluation`, `requirements`) are independent of each other. The orchestrator schedules them concurrently, capped by `ARC_MAX_PARALLEL_STEPS` (default 4 in-process at a time).
2. **Within each pipeline.** Each pipeline takes the same chunk plan and dispatches up to 20 parallel workers, each calling GPT-5.2 on one chunk with that pipeline's strict JSON schema.

So the unit of parallelism is the *pipeline*, not the chunk. Each pipeline independently iterates over all the chunks, with worker-level parallelism inside it.

After chunk-level extraction, each pipeline runs its own per-document aggregation, then a UI projection step (which is why it's 12 steps total — six pairs of `extract` + `ui_projection`).

Once all six pipelines finish, aggregation is sequential: `compliance_matrix` merges the six UI projections → `proposal_outline` builds the writing plan → `writer_prep` runs deep research and synthesizes strategy → the section writer iterates over each writing unit (draft → critique → revise) → renderers emit DOCX/PPTX/XLSX.

The GOLD pipeline runs as an independent parallel track during all of this, not gated on the RFP ingestion. Its output (`master_pro.json`) feeds into the section writer's context.

### What a UI Projection Is

Each of the six extraction pairs ends with a `ui_projection` step. Its job is to take the raw, evidence-heavy extraction output and reshape it into something the Angular frontend can render directly.

The raw extraction output is dense and traceability-focused — every requirement, evaluation factor, or structure node carries its full evidence trail (chunk IDs, line ranges, bbox coordinates, dedup metadata, confidence scores, cross-references to other domains). That's the "ground truth" representation, optimized for downstream LLM steps and audit. It's not what you want to ship to a browser.

The UI projection strips that down to:

- **Plain-text fields** — clean descriptions, titles, summaries that render directly in a UI control. The compliance matrix step does an extra LLM pass to clean markdown out of these so they sit nicely in XLSX cells too.
- **Light evidence pointers** — line numbers and bbox coordinates so the frontend can deep-link back into the source document for highlighting (using `line_map.json` from ingestion), without dragging the entire extraction blob along.
- **Stable shape** — the projection is the contract surface between ONERING and rohan_ui. The internal extraction schema can evolve freely; as long as the projection stays stable, the frontend keeps working.

UI projections land at `pipelines/{domain}/ui/*.json` inside the run folder (`ui_projection_requirements.json`, `ui_projection_structure.json`, `ui_projection_evaluation.json`, plus `rfp_ui.json` for metadata). They serve two consumers:

1. **The Angular frontend** reads them (via the rohan-python-api proxy) to render the compliance matrix tab, structure tree, and evaluation factors panel live as the run progresses.
2. **The compliance matrix step** itself consumes them — it doesn't need the full raw evidence, just the projected summaries plus their references, which is enough to align requirements to structure nodes and evaluation factors.

### GOLD Pipeline Sourcing

The GOLD pipeline does *not* take its winning proposals from per-run user uploads. GOLD is a curated reference library, separate from the per-run upload flow.

Drawn from `cli.py:108-139` and the project's CLAUDE.md:

- **GOLD documents are operator-provided.** They live in a dedicated folder, by default `ONERING/GOLD/`, configurable via the `ARC_GOLD_DIR` environment variable. Someone (a proposal team lead, an admin, whoever curates the reference library) drops past winning proposals into this folder. The CLI comment explicitly calls this out: *"Input documents (operator-provided)."*
- **Ingestion is incremental and persistent.** Unlike a per-run RFP, GOLD documents get ingested once into a shared location: `GOLD/ingest_processed/docs/<doc_id>/canonical/...`. A `processed_manifest.json` at the root tracks which files have already been processed, so each run only ingests new files added since last time. From `cli.py:1071-1130`, `_discover_new_gold_files()` walks the directory, compares against the manifest, and stages only the new ones.
- **The processing path is parallel to the RFP DAG.** GOLD documents are routed to a separate steps factory (`arc_agent_writer.pipelines_gold:build_steps`) instead of `build_builtin_steps()`. They go through the same ingestion (Docling parse, OCR, canonical markdown, line numbering, chunking) but then take the three-pass `pro_ontology` extraction route, producing `pro_document.json` per file, then aggregated to `master_pro.json`.
- **The library accumulates over time.** Every new winning proposal added to the GOLD folder enriches the reference set for *all* future RFP runs. The section writer reads `master_pro.json` as part of its 260K-token context budget when drafting sections.

When ONERING runs as a submodule behind the FastAPI service, the GOLD directory presumably sits on shared storage (a MinIO bucket or a mounted volume), not per-tenant per-user. The exact partitioning model — global library vs. per-organization library — is a design decision at the API wrapper layer, since the underlying CLI just takes whatever path `ARC_GOLD_DIR` points to.

End-user experience: upload your RFP, kick off a run, and ONERING uses a curated library someone else maintains. The library is an organizational asset, not a per-run input.

### Retrieval Architecture (Three Tiers)

ONERING does *not* host a vector database itself — `pyproject.toml` lists no vector libraries (the stale `requirement.txt` mentions `faiss-cpu` and `weaviate-client` but `grep import` confirms nothing in the codebase actually imports them; they're leftover from an older environment dump). However, the system has three distinct retrieval mechanisms, only one of which is "plain chunked text matching":

#### 1. RFP extraction — no retrieval, exhaustive chunked LLM passes

The six extraction pipelines don't *retrieve* anything. They iterate over every chunk in the chunk plan, sending each one to GPT-5.2 with a strict JSON schema, then aggregate. The `chunk_plan` step exists to ensure every chunk fits inside a single context window. Comprehensiveness comes from reading everything, not from similarity search.

#### 2. KM (Knowledge Management) retrieval — LLM-as-retriever, no embeddings

`writer_prep_pipeline.py:1-31` describes its own approach:

> Knowledge Management (KM) retrieval over local markdown/json corpora:
> - chunk KM files (<10k tokens) breaking only on table-row boundaries
> - auto-generate a KM query plan from deep research output
> - run chunked matching calls (structured outputs)
> - aggregate per file + master aggregate

Concretely:

- A configured `km_root` directory holds a corpus of internal markdown/JSON documents (past performance, capability statements, technical notes, etc.).
- `_iter_km_files()` (`writer_prep_pipeline.py:1309`) walks the directory; `chunk_km_file()` (line 1011) splits each file into chunks up to `km_chunk_max_tokens=10_000`. Markdown chunks try to break on table-row boundaries; JSON chunks have their own splitter.
- `generate_km_query_plan()` (line 1257) takes the deep-research output and asks GPT to produce a structured list of focused queries — "what should we be looking for in the KM corpus?"
- `run_km_retrieval()` (line 1323) iterates: for each KM chunk, send it to GPT *along with* the query plan and ask "does this chunk contain evidence for any of these queries?" The LLM returns structured matches with quotes and citations. Per-file matches go to `writer_prep/km_matches/`, then a per-file aggregate, then a master aggregate at `writer_prep/km_master_evidence.json`.

This is genuinely brute-force semantic filtering: every chunk gets read by the LLM under the lens of the query plan. No embedding model, no vector index, no similarity search. Trade-offs: slow and expensive, but perfect recall, the LLM understands nuance an embedding might miss, and the output is already structured (with quotes and reasoning) rather than just a ranked list.

#### 3. GOLD topic alignment — OpenAI's hosted vector store

`proposal_outline_generator.py` has two services — `GoldEnrichmentService` (line 3792) and `TopicAlignmentService` (line ~5108) — that *do* use vector search, just not a self-hosted one:

```python
vector_store = self.client.vector_stores.create(...)
batch = self.client.vector_stores.file_batches.create_and_poll(
    vector_store_id=self.vector_store_id, ...
)
"tool_resources": {"file_search": {"vector_store_ids": [self.vector_store_id]}}
```

This is the OpenAI SDK's hosted-vector-store feature: ONERING uploads the GOLD library to OpenAI, OpenAI handles embedding and indexing internally, and queries go through the `file_search` tool. The vector store is created at the start of the writer phase and deleted at cleanup (lines 4125-4132 and 5057-5064). From the codebase's perspective it's just another API call — no embedding model, no similarity code, no index management.

#### Why these design choices make sense

- **Per-RFP extraction reads everything** because missing a "shall" statement is much worse than a slow run, and the whole document fits in tens of chunks anyway.
- **KM retrieval uses brute-force LLM scanning** because a curated KM corpus is bounded in size, the team can tolerate slowness for completeness, and they get structured output with reasoning instead of a ranking. It also avoids embedding-drift issues — when KM content changes, you don't have to re-embed.
- **GOLD topic alignment uses OpenAI's vector store** because that corpus could be much larger (every winning proposal the org has ever produced), iterating chunk-by-chunk would be cost-prohibitive, and embedding similarity is a reasonable proxy for "show me the section that talks about cybersecurity past performance."

**Corrected one-liner:** ONERING hosts no vector database. Within-document extraction reads every chunk via LLM. The local KM corpus is filtered chunk-by-chunk via LLM (no embeddings). The GOLD library uses OpenAI's hosted vector store for embedding-based topic alignment.

## Acronym Glossary

| Term | Meaning |
|------|---------|
| **API** | Application Programming Interface |
| **ARC** | The internal product name for the ONERING agent writer (not an acronym in source) |
| **AST** | Abstract Syntax Tree |
| **bbox** | Bounding box (rectangle coordinates) |
| **CLI** | Command-Line Interface |
| **DAG** | Directed Acyclic Graph |
| **DOCX/PPTX/XLSX** | Microsoft Office formats: Word / PowerPoint / Excel |
| **DOM** | Document Object Model (structured representation of a document) |
| **DTO** | Data Transfer Object |
| **FBPV** | Features, Benefits, Proofs, Value (a proposal-writing framework) |
| **GOLD** | Internal name for the winning-proposal reference pipeline |
| **HTTPS** | HyperText Transfer Protocol Secure |
| **JSON** | JavaScript Object Notation |
| **JWT** | JSON Web Token |
| **KM** | Knowledge Management (the local corpus of internal markdown/JSON documents like past performance and capability statements) |
| **LLM** | Large Language Model |
| **MinIO** | S3-compatible self-hosted object storage |
| **MS Graph** | Microsoft Graph API (the unified Microsoft 365 endpoint) |
| **MSAL** | Microsoft Authentication Library |
| **NAICS** | North American Industry Classification System |
| **OCR** | Optical Character Recognition |
| **PR** | Pull Request |
| **RBAC** | Role-Based Access Control |
| **REST** | Representational State Transfer (an HTTP API style) |
| **RFP** | Request for Proposal |
| **SAM.gov** | System for Award Management — the US-government opportunity portal |
| **SHA256** | Secure Hash Algorithm, 256-bit (file-integrity hash) |
| **uv** | A fast Python package manager / runner replacing `pip` + `venv` |
