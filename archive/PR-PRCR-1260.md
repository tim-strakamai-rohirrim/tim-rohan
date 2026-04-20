#### Summary

- Add `data-linenum` post-processing utilities and a standalone Docling conversion endpoint (`POST /compliance/convert-document`) so the NestJS backend can trigger document-to-HTML conversion asynchronously on upload, returning HTML with stable block-level coordinates for the compliance document viewer.
- Update the auto-tag handler to embed `data-linenum` attributes in uploaded HTML and include a `linenum_ranges` mapping in the completion message, enabling NestJS to convert segment character offsets to `data-linenum` values when creating compliance items.
- Remove unsupported legacy Office extensions (`.doc`, `.xls`, `.ppt`) from the auto-tag handler's `SUPPORTED_EXTENSIONS` — Docling cannot convert these formats, so listing them caused silent failures.

#### Technical Details

- Backend:
  - **New module `domains/shared/html/html_linenum.py`** — two pure-function utilities:
    - `add_data_linenum(html)`: Parses Docling HTML via BeautifulSoup and assigns sequential 1-based `data-linenum` attributes to non-empty block elements (`p`, `h1`–`h6`, `li`, `table`, `tr`). Adapted from the shredding pipeline's `post_process_docling_html_block_lines()` with `ol` removed (avoids double-counting `li`) and `tr` added (row-level table granularity). Empty blocks are skipped and do not consume a linenum value.
    - `build_char_to_linenum_map(html)`: Produces a `list[LinenumRange]` mapping character offset ranges in rendered text to `data-linenum` values. Uses the tagging pipeline's `extract_text_with_mapping()` for offset consistency with the segmenter. Only leaf linenum elements are included (e.g. `<tr>` rows, not their parent `<table>`) to produce non-overlapping ranges.
  - **New endpoint `POST /compliance/convert-document`** (`api/routes/compliance.py`): Service-to-service endpoint for NestJS to call. Downloads a document from MinIO, converts via Docling, strips metadata, adds `data-linenum`, uploads the result back. Validates file extension against `.pdf`, `.docx`, `.xlsx`, `.pptx` — returns `422` for unsupported formats with a descriptive message. Returns `500` on conversion/upload failures. Auth via `get_current_user` dependency (JWT).
  - **Auto-tag handler changes** (`handle_auto_tag_message.py`): After `strip_html_metadata`, the handler now calls `add_data_linenum()` before writing the HTML file and uploading. It also calls `build_char_to_linenum_map()` and includes the result as `linenum_ranges` on the `DocumentResult`. The uploaded HTML now always contains `data-linenum` attributes — additive and harmless to existing consumers (template-generator's `DocShellComponent` ignores unknown attributes).
  - **`SUPPORTED_EXTENSIONS` cleanup** (`handle_auto_tag_message.py`): Removed `.doc`, `.xls`, `.ppt`. These were listed but Docling cannot convert legacy Office formats — attempting them failed silently at conversion time.
- Contracts:
  - **`LinenumRange` model** added to `html_linenum.py` (Pydantic `BaseModel` with `char_start`, `char_end`, `linenum`).
  - **`DocumentResult`** (`tagging_message.py`): New optional `linenum_ranges: list[LinenumRange] | None` field. Backward-compatible — defaults to `None`.
  - **`ConvertDocumentRequest` / `ConvertDocumentResponse`** models define the conversion endpoint contract (`storage_type`, `object_key`, `output_key` → `success`, `html_key`, `mime_type`).
  - The compliance router is registered at `/compliance` in `api/main.py`.

#### Testing

- Automated:
  - [pytest] `test_html_linenum.py` — 22 tests covering `add_data_linenum()` (basic paragraphs, all heading levels, list items, `ol` exclusion, tables with rows, empty/whitespace block skipping, dense sequential numbering, mixed elements, attribute/inner-HTML preservation, nested lists, empty input, no-block input, idempotency, realistic Docling-style document) and `build_char_to_linenum_map()` (offset accuracy against `extract_text_with_mapping`, table leaf-only inclusion, non-overlapping range validation, empty input, char-offset lookup simulation for the NestJS `charOffsetToLinenum` helper, realistic multi-element document).
  - [pytest] `test_compliance.py` — 12 tests covering the conversion endpoint (success with PDF/DOCX/XLSX/PPTX, rejection of `.doc`/`.xls`/`.ppt`/`.psd` with 422, conversion/download/upload error handling with 500, pipeline execution order verification, case-insensitive extension matching).
  - [pytest] `test_auto_tag_handler.py` — 3 new tests on `DocumentResult`: `linenum_ranges` defaults to `None`, stores provided ranges, survives serialization round-trip via `model_dump`.
  - [pytest] `test_auto_tag_handler_e2e.py` — 2 new E2E tests: handler produces `linenum_ranges` and uploads HTML with `data-linenum` on success; failed documents have `linenum_ranges = None`.
- Known gaps / TODO:
  - No integration test with a real Docling conversion (all tests mock `convert_document_to_html`). Manual verification with real PDF/DOCX/XLSX files is recommended before deploying.
  - Multi-sheet XLSX rendering is expected to produce sequential `<table>` elements — should be verified with a sample file during integration testing.

#### Risks & Impact

- **Additive to auto-tag output.** The `data-linenum` attributes are new attributes on existing HTML elements — no existing consumer parses or depends on their absence. The `linenum_ranges` field on `DocumentResult` is optional and defaults to `None`, so existing NestJS listeners that don't read it are unaffected.
- **`SUPPORTED_EXTENSIONS` narrowing is a bug fix, not a breaking change.** The removed extensions (`.doc`, `.xls`, `.ppt`) were already non-functional — Docling throws on them. Any documents with those extensions were silently failing. If any callers rely on the auto-tag handler accepting these extensions, they will now get explicit errors.
- **Performance:** `add_data_linenum()` and `build_char_to_linenum_map()` each do a full BeautifulSoup parse. For the auto-tag handler this adds two parses on top of existing processing. For typical documents this is negligible, but very large HTML files (multi-MB) may see a measurable increase.
- **Conversion endpoint has no rate limiting or queuing.** NestJS calls it fire-and-forget for each uploaded document. If many documents are uploaded simultaneously, the Python service could see concurrent Docling conversions. Docling is CPU-intensive — consider resource limits or queuing if this becomes an issue.

#### Verification Steps for Reviewers

1. Confirm `add_data_linenum()` targets the correct block elements by reviewing `_LINENUM_BLOCK_TAGS` in `html_linenum.py` — it should match `p, h1-h6, li, table, tr` (no `ol`, no `span`).
2. Verify `build_char_to_linenum_map()` skips parent `<table>` elements when child `<tr>` elements also have `data-linenum` (the leaf-only filter at line 99 of `html_linenum.py`).
3. Check the conversion endpoint pipeline order: download → `convert_document_to_html` → `strip_html_metadata` → `add_data_linenum` → upload. The `test_convert_document_pipeline_order` test explicitly asserts this sequence.
4. Confirm `SUPPORTED_EXTENSIONS` in `handle_auto_tag_message.py` no longer includes `.doc`, `.xls`, `.ppt`.
5. Verify the auto-tag handler writes `html_with_linenums` (not the pre-linenum `html_content`) to the output file and includes `linenum_ranges` in the `DocumentResult`.
6. Run `uv run bash scripts/test.sh` from `backend/` to confirm all tests pass.
