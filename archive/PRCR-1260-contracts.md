# PRCR-1260: API Contracts — Document HTML Content

## New Endpoints

---

### 1. `GET /compliance/projects/:projectId/documents/:documentId/html` (NestJS)

Returns the Docling-converted HTML (with `data-linenum` attributes on block elements) for a compliance source document. Conversion happens asynchronously on document upload — this endpoint only serves cached results.

**Auth:** JWT + compliance permission (same guards as other compliance endpoints).

#### Path Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `projectId` | UUID | Compliance project ID |
| `documentId` | UUID | Compliance document ID |

#### Success Response — `200 OK` (conversion complete)

```jsonc
{
  "documentId": "3fa85f64-5717-4562-b3fc-2c963f66afa6",
  "documentName": "HT001426RE001.pdf",
  "mimeType": "application/pdf",
  "conversionStatus": "COMPLETE",
  "html": "<p data-linenum=\"1\">Unless specifically agreed upon...</p><h2 data-linenum=\"2\">Section 1</h2>..."
}
```

The `html` field contains the Docling-converted HTML with `data-linenum` attributes on block elements (1-based sequential integers on `p, h1-h6, li, table, tr`). The frontend sanitizes and renders it via `innerHTML`.

#### Pending Response — `202 Accepted` (conversion in progress)

```jsonc
{
  "documentId": "3fa85f64-5717-4562-b3fc-2c963f66afa6",
  "documentName": "HT001426RE001.pdf",
  "mimeType": "application/pdf",
  "conversionStatus": "PENDING"
}
```

Returned when the document has been uploaded but Docling conversion has not yet completed. The frontend should show a "processing" state and retry after a short delay.

#### Error Responses

| Status | Condition | Body |
|--------|-----------|------|
| `404 Not Found` | Document does not exist, is not linked to the project, or user lacks project access. | `{ "statusCode": 404, "message": "Document not found" }` |
| `502 Bad Gateway` | Conversion failed (Docling error during async processing). | `{ "statusCode": 502, "message": "Document conversion failed", "conversionStatus": "FAILED" }` |
| `401 Unauthorized` | Missing or invalid JWT. | Standard NestJS 401. |
| `403 Forbidden` | User lacks compliance permission. | Standard NestJS 403. |

---

### ~~2. `POST /compliance/convert-document` (Python FastAPI)~~ — REMOVED

> **Removed per PR review.** Per the [auto-tagging integration guide](https://rohan.atlassian.net/), compliance uses `TaggingService.requestAutoTag()` → queue → completion event flow. The auto-tag pipeline already converts documents to HTML (with `data-linenum`), uploads to MinIO, and returns `converted_html_url` in the completion event. A separate synchronous HTTP endpoint is not needed and has operational problems (no retry, no backpressure, ties up a worker for 30+ seconds).
>
> **File to remove:** `rohan-python-api/backend/app/api/routes/compliance.py`
>
> **Models to remove:** `ConvertDocumentRequest`, `ConvertDocumentResponse`

---

### 3. `DELETE /compliance/projects/:projectId/documents/:documentId` (NestJS)

Permanently deletes a compliance source document, its MinIO files, and all associated compliance items (via DB cascade).

**Auth:** JWT + compliance permission (same guards as other compliance endpoints).

#### Path Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `projectId` | UUID | Compliance project ID |
| `documentId` | UUID | Compliance document ID |

#### Success Response — `204 No Content`

Empty body. The document, its MinIO files (source + converted HTML), and all associated compliance items have been deleted.

#### Error Responses

| Status | Condition | Body |
|--------|-----------|------|
| `404 Not Found` | Document does not exist, is not linked to the project, or user lacks project access. | `{ "statusCode": 404, "message": "Document not found" }` |
| `401 Unauthorized` | Missing or invalid JWT. | Standard NestJS 401. |
| `403 Forbidden` | User lacks compliance permission. | Standard NestJS 403. |

#### Cascade Behavior

Deleting the `compliance_documents` row triggers `ON DELETE CASCADE` on `compliance_items.source_document_id`, which automatically removes all compliance items linked to this document. No separate item deletion call is needed.

MinIO cleanup (source file + converted HTML) is performed in the same operation but wrapped in try/catch — MinIO failures do not prevent the DB delete.

---

### 4. Upload Source Document — `autoTag` Query Parameter (NestJS)

The existing `POST /compliance/projects/:projectId/source-documents` upload endpoint accepts a new optional query parameter:

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `autoTag` | `boolean` | No | `false` | When `true`, auto-tagging is triggered automatically after document conversion completes. Used by overview-page uploads. When `false` (default), auto-tagging is deferred to the wizard's "Finish" button (`processDocuments` batch call). |

**Example:** `POST /compliance/projects/:projectId/source-documents?autoTag=true`

The `autoTag` flag is passed through the internal `compliance.document.uploaded` event as `autoTagAfterConversion`. The conversion listener checks this flag after conversion succeeds:
- If `autoTagAfterConversion: true` AND `taggableDocId` is null → triggers auto-tagging for this single document.
- If `autoTagAfterConversion: false` → no auto-tag (deferred to batch trigger).

---

## TypeScript Types

### Backend (NestJS) — Response DTO

```typescript
// rohan_api-parent/rohan_api/src/compliance/dto/document-html-response.dto.ts

import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';

export class DocumentHtmlResponseDto {
  @ApiProperty({ description: 'Compliance document ID' })
  documentId: string;

  @ApiProperty({ description: 'Original filename' })
  documentName: string;

  @ApiProperty({ description: 'MIME type of the original file' })
  mimeType: string;

  @ApiProperty({
    description: 'Conversion status',
    enum: ['PENDING', 'COMPLETE', 'FAILED'],
  })
  conversionStatus: 'PENDING' | 'COMPLETE' | 'FAILED';

  @ApiPropertyOptional({
    description: 'Docling-converted HTML with data-linenum attributes. Null when conversion is pending or failed.',
  })
  html?: string;
}
```

### Frontend (Angular) — Response Type

```typescript
// Addition to compliance-item.types.ts

export type ConversionStatus = 'PENDING' | 'COMPLETE' | 'FAILED';

export interface DocumentHtmlResponse {
  documentId: string;
  documentName: string;
  mimeType: string;
  conversionStatus: ConversionStatus;
  html?: string;
}
```

### ~~Python (FastAPI) — Request/Response Models~~ — REMOVED

> **Removed per PR review.** The `POST /compliance/convert-document` endpoint has been removed. `ConvertDocumentRequest` and `ConvertDocumentResponse` models are no longer needed.

### ~~Python — Linenum Mapping Types~~ — REMOVED FROM PIPELINE

> **Removed from auto-tag pipeline per PR review.** The `LinenumRange` model and `build_char_to_linenum_map()` utility may remain in `html_linenum.py` for potential future use, but they are **no longer referenced by the auto-tag handler** or shipped in completion messages. The char-offset → linenum mapping is implemented in the NestJS compliance module instead.

### Python — DocumentResult Update (auto-tag handler)

> **`linenum_ranges` field removed per PR review.** The `DocumentResult` model reverts to its original shape — no compliance-specific fields.

```python
# DocumentResult in tagging_message.py — linenum_ranges REMOVED

class DocumentResult(BaseModel):
    filename: str
    status: str
    segments: list[SegmentResult] | None = None
    tags: list[TagResult] | None = None
    converted_html_url: str | None = None
    # linenum_ranges: REMOVED — compliance-specific mapping belongs in NestJS
```

### NestJS — AutoTagCompleteEvent (No Changes Needed)

> **No changes to the event type per PR review.** The `convertedHtmlUrl` field already exists on `AutoTagCompleteEvent` — the compliance listener just needs to persist it (currently discarded). The `LinenumRange` type and `linenumRanges` field are **not added** — the char-offset → linenum mapping is computed in the NestJS compliance module using the HTML from MinIO.

```typescript
// auto-tag-complete.event.ts — NO CHANGES NEEDED
// The existing convertedHtmlUrl field is sufficient.

export interface AutoTagCompleteEvent {
  productCode: ProductCode;
  documentId: number | string;
  taggableDocId?: number;
  result: AutoTagCompleteResult;
  is_auto_tag?: boolean;
  convertedHtmlUrl?: string;  // Already exists — compliance listener must persist this
  orgId?: string;
  userSub?: string;
}
```

---

## Frontend API Method

```typescript
// ComplianceApiService addition

/**
 * GET /compliance/projects/:projectId/documents/:documentId/html
 * Returns the Docling-converted HTML (with data-linenum) for a compliance document.
 * Returns conversionStatus to indicate if HTML is ready, pending, or failed.
 */
getDocumentHtml(projectId: string, documentId: string): Observable<DocumentHtmlResponse> {
  return this.request.getWithoutErrorModal(
    `${BASE_PATH}/projects/${projectId}/documents/${documentId}/html`,
  );
}

/**
 * DELETE /compliance/projects/:projectId/documents/:documentId
 * Permanently deletes a source document and all associated compliance items (DB cascade).
 */
deleteSourceDocument(projectId: string, documentId: string): Observable<void> {
  return this.request.delete(
    `${BASE_PATH}/projects/${projectId}/documents/${documentId}`,
  );
}

/**
 * POST /compliance/projects/:projectId/source-documents?autoTag=true
 * Upload with autoTag=true to trigger auto-tagging after conversion.
 * (Existing uploadSourceDocument method — add optional autoTag query param.)
 */
uploadSourceDocument(projectId: string, file: File, autoTag = false): Observable<any> {
  const params = autoTag ? `?autoTag=true` : '';
  // ... existing upload logic with params appended to URL
}
```

---

## Schema Changes

### `compliance_documents` table — New columns

| Column | Type | Nullable | Default | Description |
|--------|------|----------|---------|-------------|
| `converted_html_key` | `varchar(500)` | Yes | `NULL` | MinIO/blob key of the Docling-converted HTML (with `data-linenum` attributes). Populated by `handleAutoTagComplete` from `event.convertedHtmlUrl`. Non-null indicates HTML is available for the viewer. |

> **`conversion_status` column removed per PR review.** Since conversion happens as part of the auto-tag pipeline (not a separate step), the existing `processingStatus` on `ComplianceDocument` (set by `markDocumentReady`/`markDocumentFailed`) already tracks whether the pipeline succeeded or failed. `convertedHtmlKey` being non-null indicates HTML is ready. A separate `conversion_status` column is not needed. _(Confirm during implementation that the existing `processingStatus` is sufficient.)_

### Compliance items table — Semantic shift (no column rename)

The `document_start_line` / `document_end_line` columns on both `ComplianceItem` and `ComplianceItemEvidence` keep their existing names. Their semantics shift from character offsets to `data-linenum` values (1-based block indices). No data migration or column rename is needed — compliance is in development with no production data.

### Entity Update

```typescript
// ComplianceDocument entity addition

@Column({ name: 'converted_html_key', type: 'varchar', length: 500, nullable: true })
convertedHtmlKey: string | null;

// No conversion_status column — use existing processingStatus + convertedHtmlKey non-null check
```

### Upload Service Update

> **Simplified per PR review.** No `compliance.document.uploaded` event or `conversionStatus: 'PENDING'` setting. The upload just saves the entity. Auto-tagging (and therefore conversion) is triggered separately — either by the wizard "Finish" button (`requestAutoTagging()`) or by the overview-page upload passing `autoTag=true` (Phase 6A).

```typescript
// compliance.service.ts — uploadSourceDocument
// After saving the ComplianceDocument entity:

const savedDocument = await this.complianceDocumentRepository.save({
  // ... existing fields ...
  // No conversionStatus — HTML becomes available when auto-tag completes
});

// Phase 6A addition: if autoTag is true (overview-page uploads),
// call requestAutoTag() immediately.
if (autoTag) {
  const taggableDocId = await this.taggingService.requestAutoTag({
    productCode: ProductCode.COMPLIANCE,
    blobPath: savedDocument.minioObjectKey,
    orgId: user.org_id,
    userSub: user.sub,
    documentId: savedDocument.id,
    storageType: StorageType.MINIO,
  });
  await this.complianceDocumentRepository.update(savedDocument.id, {
    taggable_doc_id: taggableDocId,
  });
}
```

### ~~Conversion Listener~~ — REMOVED

> **Removed per PR review.** There is no separate `compliance.document.uploaded` event or conversion listener. Document conversion happens as part of the auto-tag queue pipeline. The `handleAutoTagComplete` listener (already existing) handles the completion event and persists `convertedHtmlUrl`. See updated "Auto-Tag Completion Listener" section below.

### Auto-Tag Completion Listener Update

The compliance listener's `handleAutoTagComplete` needs two additions:

1. **Persist `convertedHtmlUrl`** — the auto-tag pipeline already produces this but the compliance listener currently discards it.
2. **Convert char offsets to linenum values** — download the HTML from MinIO, build the mapping in TypeScript, and use it when creating compliance items.

```typescript
// compliance.listener.ts — handleAutoTagComplete additions

// 1. Persist the converted HTML key from the auto-tag pipeline.
// event.convertedHtmlUrl is already an object key (e.g. "org_abc/docs/output/file.html")
// despite the "_url" name — no URL parsing needed. Stored directly as convertedHtmlKey.
if (event.convertedHtmlUrl) {
  await this.complianceDocumentRepository.update(documentId, {
    convertedHtmlKey: event.convertedHtmlUrl,
  });
}

// 2. Build char-offset → linenum mapping from the HTML (TypeScript implementation).
// Download the line-numbered HTML from MinIO, parse [data-linenum] elements,
// and build the mapping for converting segment offsets.
const linenumRanges = event.convertedHtmlUrl
  ? await this.buildLinenumMapFromHtml(event.convertedHtmlUrl)
  : [];

// When creating compliance items from segments, convert char offsets to data-linenum values:
createComplianceDto.documentStartLine = this.charOffsetToLinenum(
  Math.min(...groupSegments.map((s) => s.start_offset)),
  linenumRanges,
);
createComplianceDto.documentEndLine = this.charOffsetToLinenum(
  Math.max(...groupSegments.map((s) => s.end_offset)),
  linenumRanges,
);
```

### `buildLinenumMapFromHtml` Helper (New — TypeScript)

This replaces the Python `build_char_to_linenum_map()`. The mapping logic moves to NestJS where it's consumed.

```typescript
// compliance.listener.ts — new helper method
// Uses cheerio (lightweight HTML parser) to extract text and build offset map.

import * as cheerio from 'cheerio';

interface LinenumRange {
  charStart: number;
  charEnd: number;
  linenum: number;
}

private async buildLinenumMapFromHtml(htmlKey: string): Promise<LinenumRange[]> {
  const htmlBuffer = await this.minioService.getObjectBuffer(htmlKey, 'uploads');
  const html = htmlBuffer.toString('utf-8');
  const $ = cheerio.load(html);
  const plainText = $.text();

  const ranges: LinenumRange[] = [];
  let searchStart = 0;

  $('[data-linenum]').each((_, el) => {
    const blockText = $(el).text().trim();
    if (!blockText) return;

    const linenum = Number($(el).attr('data-linenum'));
    const pos = plainText.indexOf(blockText, searchStart);
    if (pos === -1) return;

    ranges.push({ charStart: pos, charEnd: pos + blockText.length, linenum });
    searchStart = pos + blockText.length;
  });

  return ranges;
}
```

### `charOffsetToLinenum` Helper

```typescript
// compliance.listener.ts — helper method

private charOffsetToLinenum(
  charOffset: number,
  linenumRanges: LinenumRange[],
): number | undefined {
  if (!linenumRanges.length) return undefined;

  for (const range of linenumRanges) {
    if (charOffset >= range.charStart && charOffset < range.charEnd) {
      return range.linenum;
    }
  }
  return linenumRanges[linenumRanges.length - 1].linenum;
}
```

### ~~`RfpPythonServerService` Addition~~ — REMOVED

> **Removed per PR review.** No `convertDocument()` method needed. No `COMPLIANCE_CONVERT_DOCUMENT` resource enum entry needed. The compliance module uses `TaggingService.requestAutoTag()` (which sends a queue message) instead of making a direct HTTP call to Python.

### `deleteSourceDocument` Service Method

```typescript
// compliance.service.ts — new method

async deleteSourceDocument(
  projectId: string,
  documentId: string,
  user: AuthenticatedUser,
): Promise<void> {
  const document = await this.complianceDocumentRepository.findOne({
    where: { id: documentId },
    relations: ['projects'],
  });

  if (!document || !document.projects.some((p) => p.id === projectId)) {
    throw new NotFoundException('Document not found');
  }

  // Clean up MinIO files (best-effort — failures don't block DB delete)
  try {
    if (document.minioObjectKey) {
      await this.minioService.deleteObject(document.minioObjectKey, 'uploads');
    }
    if (document.convertedHtmlKey) {
      await this.minioService.deleteObject(document.convertedHtmlKey, 'uploads');
    }
  } catch (error) {
    this.logger.warn(`MinIO cleanup failed for document ${documentId}`, error);
  }

  // Delete the compliance_documents row — ON DELETE CASCADE removes compliance_items
  await this.complianceDocumentRepository.remove(document);
}
```

### `handleAutoTagComplete` Guard for Deleted Documents

```typescript
// compliance.listener.ts — in handleAutoTagComplete, before creating items:

const document = await this.complianceDocumentRepository.findOneBy({ id: documentId });
if (!document) {
  this.logger.warn(
    `Auto-tag complete for document ${documentId} but document no longer exists — skipping`,
  );
  return;
}
```

---

## Modified Frontend Types

### `CreateComplianceItemSelection` — Updated

```typescript
// compliance-item.types.ts

export interface CreateComplianceItemSelection {
  documentId: string;
  selectionText: string;
  startLine: number;   // data-linenum value of first selected block (1-based)
  endLine: number;     // data-linenum value of last selected block (1-based)
}
```

When creating the API request, `startLine` / `endLine` map to `documentStartLine` / `documentEndLine` on `CreateComplianceItemRequest`. The columns keep their existing names (`document_start_line` / `document_end_line`) — their semantics shift from character offsets to `data-linenum` block identifiers. No rename or migration is needed since compliance has no production data.

Both auto-tagged and manually created items now store `data-linenum` values in these columns, ensuring consistent highlighting.

### `ComplianceSourceDocument` — Minimally changed

The `lines` field becomes vestigial (empty array). The document's content is now represented by the HTML string loaded separately. A future cleanup may remove `lines` entirely.

```typescript
// Existing — lines will always be [] in the new flow
export interface ComplianceSourceDocument {
  id: string;
  projectId: string;
  documentName: string;
  documentCode: string;
  pageNumber: number;     // unused for now
  totalPages: number;     // unused for now
  lines: ComplianceSourceDocumentLine[];  // always [] — HTML is the content model
}
```

---

## HTML Rendering Pattern (Frontend)

Modeled on `HtmlRendererComponent` (`proposal-writer/components/html-renderer/`) with sanitization from `DocShellComponent`.

### Sanitization

```typescript
import DOMPurify from 'dompurify';

private sanitizeHtml(rawHtml: string): string {
  const purified = DOMPurify.sanitize(rawHtml, { USE_PROFILES: { html: true } });
  const doc = new DOMParser().parseFromString(purified, 'text/html');
  doc.body.querySelectorAll('base,link,meta,script,style,title').forEach(el => el.remove());
  return doc.body.innerHTML;
}
```

Then bind with `this.sanitizer.bypassSecurityTrustHtml(sanitizedHtml)`.

### Line element cache (from `HtmlRendererComponent`)

```typescript
// Copied from proposal-writer/components/html-renderer/line-elements-cache.ts

export class LineElementsCache {
  private linePositions: { lineNum: string; top: number; bottom: number }[] = [];
  elementsCache: Map<number, HTMLElement> = new Map();

  constructor(lineElements: NodeListOf<Element>, htmlContainerTop: number) { ... }

  getLineElement(lineNum: number): HTMLElement | undefined {
    return this.elementsCache.get(lineNum);
  }
}
```

### Building the cache after render

```typescript
private initLineCache(): void {
  const lineElements = this.documentContent.nativeElement.querySelectorAll('[data-linenum]');
  const containerRect = this.documentContent.nativeElement.getBoundingClientRect();
  this.lineCache = new LineElementsCache(lineElements, containerRect.top);
}
```

### Selection → linenum range

On `mouseup`, resolve selection start/end to `data-linenum` values:

```typescript
private getLinenumFromNode(node: Node): number | null {
  let el = node instanceof HTMLElement ? node : node.parentElement;
  while (el && el !== this.documentContent.nativeElement) {
    const linenum = el.getAttribute('data-linenum');
    if (linenum) return Number(linenum);
    el = el.parentElement;
  }
  return null;
}
```

If DOM traversal fails, use `findNearestLineNumber()` (viewport Y → nearest `[data-linenum]` element) as fallback.

### Block-level highlighting

Apply a CSS attribute to elements in a compliance item's `documentStartLine`–`documentEndLine` range:

```typescript
private applyHighlight(startLineNum: number, endLineNum: number): void {
  if (!this.lineCache) return;
  for (let i = startLineNum; i <= endLineNum; i++) {
    const el = this.lineCache.getLineElement(i);
    if (el) el.setAttribute('data-compliance-active', '');
  }
}
```

```scss
[data-compliance-active] {
  background-color: rgba(0, 188, 212, 0.15);
  outline: 2px solid rgba(0, 188, 212, 0.5);
}
```

---

## Python Utilities

### `add_data_linenum()`

Remains in the auto-tag handler. Enriches the HTML with stable block-level anchors for all consumers.

```python
# rohan-python-api/backend/app/domains/shared/html/html_linenum.py

from bs4 import BeautifulSoup

_LINENUM_BLOCK_TAGS = ["p", "h1", "h2", "h3", "h4", "h5", "h6", "li", "table", "tr"]

def add_data_linenum(html: str) -> str:
    """Add data-linenum attributes to block elements in Docling HTML.

    Assigns 1-based sequential integers to non-empty block elements,
    matching the convention in shred_0120.post_process_docling_html_block_lines().
    """
    soup = BeautifulSoup(html, "html.parser")
    block_index = 1
    for block in soup.find_all(_LINENUM_BLOCK_TAGS):
        if not block.get_text(strip=True):
            continue
        block["data-linenum"] = str(block_index)
        block_index += 1
    return str(soup)
```

### ~~`build_char_to_linenum_map()`~~ — REMOVED FROM PIPELINE

> **Removed from auto-tag pipeline per PR review.** The function may remain in `html_linenum.py` for reference/testing, but it is no longer called by the auto-tag handler or shipped in completion messages. The equivalent mapping logic is now implemented in TypeScript in the NestJS compliance module (see `buildLinenumMapFromHtml` in the contracts above).

---

## Validation Rules

- `projectId` and `documentId` must be valid UUIDs (`ParseUUIDPipe`).
- Document must belong to the project (via `compliance_project_documents` join).
- Python conversion endpoint: `object_key` must reference a file with a supported extension.

---

## Resolved Questions (Contracts)

1. ~~Should the HTML response include the document's `processingStatus`?~~ → **Yes.** The response includes `conversionStatus` (`'PENDING' | 'COMPLETE' | 'FAILED'`) so the frontend can distinguish "ready" from "not yet processed." HTTP status codes also differ (200 vs 202 vs 502). Note: this status is derived from the existing `processingStatus` + `convertedHtmlKey` non-null check — not a separate column.
2. ~~Strip Docling wrapper?~~ → **Yes, strip at the Python level.** The `strip_html_metadata()` utility already removes Docling's wrapper elements. The auto-tag handler calls `strip_html_metadata()` before uploading. The frontend receives clean body content. `DOMPurify` provides an additional safety layer.
3. ~~Rename `documentStartLine`/`documentEndLine`?~~ → **No — keep existing names.** The semantic shift from character offsets to `data-linenum` values is internal. Renaming across entities (`ComplianceItem`, `ComplianceItemEvidence`), DTOs, and frontend types adds complexity without proportional benefit. No migration needed since compliance has no production data.
4. ~~Is `convertedHtmlUrl` a full URL or an object key?~~ → **Object key (path only).** The Python auto-tag handler sets `converted_html_url` to `output_blob_path` (e.g., `org_abc/docs/output/file.html`). The upload functions' return values are never captured. No URL parsing or extraction is needed — the compliance listener stores the value directly as `convertedHtmlKey`. **Bucket:** All writes go to the `uploads` bucket — compliance `putObject` defaults to `uploadsBucket` (hardcoded `'uploads'` in `MinioService`), and the Python auto-tag handler uploads to `MINIO_TAGGING_BUCKET` (default `'uploads'`). However, `getObjectBuffer` defaults to `this.configs.bucket` (from `MINIO_BUCKET` env var), which may differ. The `getDocumentHtml` method should pass `'uploads'` explicitly: `this.minioService.getObjectBuffer(key, 'uploads')`.
5. ~~Should compliance use a dedicated Python HTTP endpoint for conversion?~~ → **No.** Per the [auto-tagging integration guide](https://rohan.atlassian.net/) and PR review, compliance uses `TaggingService.requestAutoTag()` → queue → completion event flow. The auto-tag pipeline already converts documents to HTML as a byproduct. A dedicated synchronous HTTP endpoint has operational problems (no retry, no backpressure, ties up a worker). The `POST /compliance/convert-document` endpoint is removed.
6. ~~Should `linenum_ranges` be shipped in the auto-tag completion message?~~ → **No.** The char-offset → linenum mapping is a compliance-specific concern. It should not be in the shared `DocumentResult` model. The mapping is computed in the NestJS compliance module by downloading the HTML from MinIO and parsing `[data-linenum]` elements in TypeScript.
