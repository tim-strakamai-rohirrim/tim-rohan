# PRCR-1260: API Contracts — Document HTML Content

## New Endpoints

---

### 1. `GET /compliance/projects/:projectId/documents/:documentId/html` (NestJS)

Returns the Docling-converted HTML for a compliance source document. If no converted HTML exists yet, triggers on-demand conversion via the Python API (transparent to the caller).

**Auth:** JWT + compliance permission (same guards as other compliance endpoints).

#### Path Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `projectId` | UUID | Compliance project ID |
| `documentId` | UUID | Compliance document ID |

#### Success Response — `200 OK`

```jsonc
{
  "documentId": "3fa85f64-5717-4562-b3fc-2c963f66afa6",
  "documentName": "HT001426RE001.pdf",
  "mimeType": "application/pdf",
  "html": "<!DOCTYPE html><html><body><p>Unless specifically agreed upon...</p>...</body></html>"
}
```

The `html` field contains the full Docling-converted HTML string. The frontend sanitizes and renders it via `innerHTML`.

#### Error Responses

| Status | Condition | Body |
|--------|-----------|------|
| `404 Not Found` | Document does not exist, is not linked to the project, or user lacks project access. | `{ "statusCode": 404, "message": "Document not found" }` |
| `502 Bad Gateway` | On-demand conversion failed (Python API error or Docling failure). | `{ "statusCode": 502, "message": "Document conversion failed. Please try again." }` |
| `401 Unauthorized` | Missing or invalid JWT. | Standard NestJS 401. |
| `403 Forbidden` | User lacks compliance permission. | Standard NestJS 403. |

---

### 2. `POST /compliance/convert-document` (Python FastAPI)

Standalone Docling document conversion. Downloads from MinIO, converts to HTML, uploads result back.

**Auth:** Service-to-service (same mechanism as other NestJS → Python calls).

#### Request Body

```jsonc
{
  "storage_type": "minio",
  "object_key": "compliance/projects/abc/source-docs/proposal.pdf",
  "output_key": "compliance/projects/abc/source-docs/converted/proposal.html"
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `storage_type` | `"minio" \| "azure_blob"` | Yes | Storage backend. |
| `object_key` | `string` | Yes | Source document path in MinIO/blob. |
| `output_key` | `string` | Yes | Destination path for converted HTML. |

#### Success Response — `200 OK`

```jsonc
{
  "success": true,
  "html_key": "compliance/projects/abc/source-docs/converted/proposal.html",
  "mime_type": "text/html"
}
```

#### Error Responses

| Status | Body |
|--------|------|
| `422 Unprocessable Entity` | `{ "success": false, "error": "Unsupported file format: .psd" }` |
| `500 Internal Server Error` | `{ "success": false, "error": "Docling conversion failed: <detail>" }` |

#### Supported Input Formats

`.pdf`, `.docx`, `.doc`, `.xlsx`, `.xls`, `.pptx`, `.ppt`

---

## TypeScript Types

### Backend (NestJS) — Response DTO

```typescript
// rohan_api-parent/rohan_api/src/compliance/dto/document-html-response.dto.ts

export class DocumentHtmlResponseDto {
  documentId: string;
  documentName: string;
  mimeType: string;
  html: string;
}
```

### Frontend (Angular) — Response Type

```typescript
// Addition to compliance-item.types.ts

export interface DocumentHtmlResponse {
  documentId: string;
  documentName: string;
  mimeType: string;
  html: string;
}
```

### Python (FastAPI) — Request/Response Models

```python
# rohan-python-api/backend/app/api/routes/compliance.py (or schemas.py)

from pydantic import BaseModel

class ConvertDocumentRequest(BaseModel):
    storage_type: str  # "minio" or "azure_blob"
    object_key: str
    output_key: str

class ConvertDocumentResponse(BaseModel):
    success: bool
    html_key: str | None = None
    mime_type: str | None = None
    error: str | None = None
```

---

## Frontend API Method

```typescript
// ComplianceApiService addition

/**
 * GET /compliance/projects/:projectId/documents/:documentId/html
 * Returns the Docling-converted HTML for a compliance document.
 * Backend triggers on-demand conversion if needed.
 */
getDocumentHtml(projectId: string, documentId: string): Observable<DocumentHtmlResponse> {
  return this.request.getWithoutErrorModal(
    `${BASE_PATH}/projects/${projectId}/documents/${documentId}/html`,
  );
}
```

---

## Schema Changes

### `compliance_documents` table — New column

| Column | Type | Nullable | Default | Description |
|--------|------|----------|---------|-------------|
| `converted_html_key` | `varchar(500)` | Yes | `NULL` | MinIO/blob key of the Docling-converted HTML. Populated by auto-tag completion or on-demand conversion. |

### Entity Update

```typescript
// ComplianceDocument entity addition

@Column({ name: 'converted_html_key', type: 'varchar', length: 500, nullable: true })
convertedHtmlKey: string | null;
```

### Compliance Listener Update

```typescript
// compliance.listener.ts — handleAutoTagComplete
// After markDocumentResult(event), persist the converted HTML key:
if (event.convertedHtmlUrl) {
  await this.complianceDocumentRepository.update(
    documentId,
    { convertedHtmlKey: event.convertedHtmlUrl },
  );
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
  startBlock: number;   // 0-based block index in the Docling HTML
  endBlock: number;     // 0-based block index in the Docling HTML
}
```

When creating the API request, `startBlock` / `endBlock` map to `documentStartLine` / `documentEndLine` on `CreateComplianceItemRequest`. The column names are unchanged to avoid a database migration, but their semantic meaning shifts from "line number" to "block index."

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

Borrowed from `DocShellComponent` (`shared-components/document-shredding/`).

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

### Block element collection

```typescript
import { TAGGABLE_BLOCK_SELECTOR } from '@shared-services/tagging/constants/tagging-ui.constants';

private collectBlockElements(contentElement: HTMLElement): HTMLElement[] {
  return Array.from(contentElement.querySelectorAll(TAGGABLE_BLOCK_SELECTOR));
}
```

### Selection → block range

On `mouseup`, resolve selection start/end containers to the nearest block element, find their indices in `blockElements`, and report `{ startBlock, endBlock }`.

### Block-level highlighting

Apply a CSS class to blocks within a compliance item's range:

```scss
[data-compliance-active] {
  background-color: rgba(0, 188, 212, 0.15);
  outline: 2px solid rgba(0, 188, 212, 0.5);
}
```

---

## Validation Rules

- `projectId` and `documentId` must be valid UUIDs (`ParseUUIDPipe`).
- Document must belong to the project (via `compliance_project_documents` join).
- Python conversion endpoint: `object_key` must reference a file with a supported extension.

---

## Open Questions (Contracts)

1. Should the HTML response include the document's `processingStatus` so the frontend can distinguish "ready" from "conversion in progress"?
2. Should we strip Docling's `<html>`/`<head>`/`<body>` wrapper and return only the inner body content, or return the full HTML document? (DOMPurify handles stripping unsafe elements, but the frontend only needs the body.)
3. Should `documentStartLine`/`documentEndLine` be renamed to `documentStartBlock`/`documentEndBlock` at the API level? This would require a DB column rename migration but would be more accurate semantically.
