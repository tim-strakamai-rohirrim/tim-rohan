# PRCR-1260 (Viewer): API Contracts — Document HTML Serving & Lifecycle

> **Companion to:** `PRCR-1260-viewer-PLAN.md` (non-tagging work plan)
> **Also see:** `PRCR-1260-contracts.md` (full contracts including tagging-related types)
> **Created:** 2026-03-25

This file contains the API contracts, DTOs, and data shapes for the **non-tagging** portions of PRCR-1260: document HTML serving, document deletion, and auto-tag-on-upload.

Tagging-related contracts (char-offset → linenum mapping, `buildLinenumMapFromHtml`, `charOffsetToLinenum`, selection types) remain in the original `PRCR-1260-contracts.md` and will be finalized after the tagging redesign merges.

---

## Endpoints

### 1. `GET /compliance/projects/:projectId/documents/:documentId/html` (NestJS)

Returns the Docling-converted HTML (with `data-linenum` attributes) for a compliance source document. Only serves cached HTML produced by the auto-tag pipeline — no on-demand conversion.

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
  "conversionStatus": "COMPLETE",
  "html": "<p data-linenum=\"1\">Unless specifically agreed upon...</p><h2 data-linenum=\"2\">Section 1</h2>..."
}
```

The `html` field contains Docling-converted HTML with `data-linenum` attributes on block elements (`p, h1-h6, li, table, tr`). The frontend sanitizes via DOMPurify and renders via `innerHTML`.

#### Pending Response — `202 Accepted`

```jsonc
{
  "documentId": "3fa85f64-5717-4562-b3fc-2c963f66afa6",
  "documentName": "HT001426RE001.pdf",
  "mimeType": "application/pdf",
  "conversionStatus": "PENDING"
}
```

Returned when the document has been uploaded but auto-tag (which produces the HTML) has not yet completed. The frontend shows a "processing" state.

#### Error Responses

| Status | Condition | Body |
|--------|-----------|------|
| `404 Not Found` | Document does not exist, not linked to project, or user lacks access | `{ "statusCode": 404, "message": "Document not found" }` |
| `502 Bad Gateway` | Auto-tag pipeline failed (conversion error) | `{ "statusCode": 502, "message": "Document conversion failed", "conversionStatus": "FAILED" }` |
| `401 Unauthorized` | Missing or invalid JWT | Standard NestJS 401 |
| `403 Forbidden` | User lacks compliance permission | Standard NestJS 403 |

---

### 2. `DELETE /compliance/projects/:projectId/documents/:documentId` (NestJS)

Permanently deletes a compliance source document, its MinIO/BlobStorage files, and all associated compliance items (via DB cascade).

**Auth:** JWT + compliance permission.

#### Path Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `projectId` | UUID | Compliance project ID |
| `documentId` | UUID | Compliance document ID |

#### Success Response — `204 No Content`

Empty body. The document, its storage files (source + converted HTML), and all associated compliance items have been deleted.

#### Error Responses

| Status | Condition | Body |
|--------|-----------|------|
| `404 Not Found` | Document does not exist, not linked to project, or user lacks access | `{ "statusCode": 404, "message": "Document not found" }` |
| `401 Unauthorized` | Missing or invalid JWT | Standard NestJS 401 |
| `403 Forbidden` | User lacks compliance permission | Standard NestJS 403 |

#### Cascade Behavior

Deleting the `compliance_documents` row triggers `ON DELETE CASCADE` on `compliance_items.source_document_id`, automatically removing all linked compliance items.

Storage cleanup (source file + converted HTML) is best-effort — failures don't prevent the DB delete.

---

### 3. Upload Source Document — `autoTag` Query Parameter

The existing `POST /compliance/projects/:projectId/source-documents` endpoint accepts a new optional query parameter:

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `autoTag` | `boolean` | No | `false` | When `true`, `requestAutoTag()` is called immediately after saving (for overview-page uploads). When `false`, auto-tagging is deferred to the wizard "Finish" button. |

**Example:** `POST /compliance/projects/:projectId/source-documents?autoTag=true`

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
    description:
      'Docling-converted HTML with data-linenum attributes. Null when conversion is pending or failed.',
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

---

## Schema Changes

### `compliance_documents` table — New column

| Column | Type | Nullable | Default | Description |
|--------|------|----------|---------|-------------|
| `converted_html_key` | `varchar(500)` | Yes | `NULL` | MinIO/blob key of the Docling-converted HTML. Populated from `event.convertedHtmlUrl` during auto-tag completion. Non-null means HTML is available. |

No `conversion_status` column — the existing `processingStatus` + `convertedHtmlKey` non-null check is sufficient.

### Entity Update

```typescript
// ComplianceDocument entity addition

@Column({ name: 'converted_html_key', type: 'varchar', length: 500, nullable: true })
convertedHtmlKey: string | null;
```

---

## Frontend API Methods

```typescript
// ComplianceApiService additions

/**
 * GET /compliance/projects/:projectId/documents/:documentId/html
 * Returns the Docling-converted HTML for a compliance document.
 */
getDocumentHtml(projectId: string, documentId: string): Observable<DocumentHtmlResponse> {
  return this.request.getWithoutErrorModal(
    `${BASE_PATH}/projects/${projectId}/documents/${documentId}/html`,
  );
}

/**
 * DELETE /compliance/projects/:projectId/documents/:documentId
 * Permanently deletes a source document and all associated compliance items.
 */
deleteSourceDocument(projectId: string, documentId: string): Observable<void> {
  return this.request
    .deleteWithoutErrorModal(
      `${BASE_PATH}/projects/${projectId}/documents/${documentId}`,
    )
    .pipe(map(() => {}));
}
```

For the upload with `autoTag`:

```typescript
/**
 * POST /compliance/projects/:id/documents?autoTag=true
 * Existing uploadSourceDocument — add optional autoTag query parameter.
 */
uploadSourceDocument(projectId: string, file: File, autoTag = false): Observable<any> {
  const url = autoTag
    ? `${BASE_PATH}/projects/${projectId}/documents?autoTag=true`
    : `${BASE_PATH}/projects/${projectId}/documents`;
  // ... existing multipart upload logic with updated URL
}
```

---

## Backend Service Methods

### `getDocumentHtml`

```typescript
// compliance.service.ts

async getDocumentHtml(
  projectId: string,
  documentId: string,
  user: AuthenticatedUser,
): Promise<DocumentHtmlResponseDto> {
  const document = await this.complianceDocumentRepository.findOne({
    where: { id: documentId },
    relations: ['projectLinks'],
  });

  if (!document || !document.projectLinks.some((pl) => pl.projectId === projectId)) {
    throw new NotFoundException('Document not found');
  }

  if (document.convertedHtmlKey) {
    const htmlBuffer = await this.blobStorageService.download(
      document.convertedHtmlKey,
      'uploads',
    );
    return {
      documentId: document.id,
      documentName: document.documentName,
      mimeType: document.mimeType,
      conversionStatus: 'COMPLETE',
      html: htmlBuffer.toString('utf-8'),
    };
  }

  if (document.processingStatus === 'FAILED') {
    throw new BadGatewayException('Document conversion failed');
  }

  return {
    documentId: document.id,
    documentName: document.documentName,
    mimeType: document.mimeType,
    conversionStatus: 'PENDING',
  };
}
```

> **Note:** The above uses `blobStorageService.download()` assuming the tagging-redesign's `BlobStorageService` is available. If not, use `minioService.getObjectBuffer(key, 'uploads')` instead. Confirm which abstraction is registered in `ComplianceModule` after the tagging redesign merges.

### `deleteSourceDocument`

```typescript
// compliance.service.ts

async deleteSourceDocument(
  projectId: string,
  documentId: string,
  user: AuthenticatedUser,
): Promise<void> {
  const document = await this.complianceDocumentRepository.findOne({
    where: { id: documentId },
    relations: ['projectLinks'],
  });

  if (!document || !document.projectLinks.some((pl) => pl.projectId === projectId)) {
    throw new NotFoundException('Document not found');
  }

  try {
    if (document.minioObjectKey) {
      await this.blobStorageService.delete(document.minioObjectKey, 'uploads');
    }
    if (document.convertedHtmlKey) {
      await this.blobStorageService.delete(document.convertedHtmlKey, 'uploads');
    }
  } catch (error) {
    this.logger.warn(`Storage cleanup failed for document ${documentId}`, error);
  }

  await this.complianceDocumentRepository.remove(document);
}
```

### Listener — Persist `convertedHtmlUrl`

```typescript
// compliance.listener.ts — in handleAutoTagComplete, after markDocumentReady/Failed

if (event.convertedHtmlUrl) {
  await this.complianceDocumentRepository.update(documentId, {
    convertedHtmlKey: event.convertedHtmlUrl,
  });
}
```

### Listener — Guard for deleted documents

```typescript
// compliance.listener.ts — before creating items from tags

const document = await this.complianceDocumentRepository.findOneBy({ id: documentId });
if (!document) {
  this.logger.warn(
    `Auto-tag complete for document ${documentId} but document no longer exists — skipping`,
  );
  return;
}
```

---

## HTML Rendering Pattern (Frontend)

Unchanged from original `PRCR-1260-contracts.md`. Key pieces:

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

### Line element cache

```typescript
// Copied from proposal-writer/components/html-renderer/line-elements-cache.ts
// Use Number() instead of parseInt() per project convention

export class LineElementsCache {
  private linePositions: { lineNum: string; top: number; bottom: number }[] = [];
  elementsCache: Map<number, HTMLElement> = new Map();

  constructor(lineElements: NodeListOf<Element>, htmlContainerTop: number) {
    lineElements.forEach((el) => {
      const lineNum = Number(el.getAttribute('data-linenum'));
      if (!isNaN(lineNum)) {
        this.elementsCache.set(lineNum, el as HTMLElement);
        const rect = el.getBoundingClientRect();
        this.linePositions.push({
          lineNum: String(lineNum),
          top: rect.top - htmlContainerTop,
          bottom: rect.bottom - htmlContainerTop,
        });
      }
    });
  }

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

---

## State Management (Frontend)

### `ComplianceStateService` additions for HTML loading

```typescript
// Additions to compliance-state.service.ts

private readonly _documentHtmlCache = new Map<string, string>();
private readonly _isDocumentHtmlLoading = signal(false);
private readonly _documentHtmlError = signal<string | null>(null);
private readonly _documentConversionStatus = signal<ConversionStatus | null>(null);

readonly isDocumentHtmlLoading = this._isDocumentHtmlLoading.asReadonly();
readonly documentHtmlError = this._documentHtmlError.asReadonly();
readonly documentConversionStatus = this._documentConversionStatus.asReadonly();

readonly selectedDocumentHtml = computed(() => {
  const docId = this._selectedDocumentId();
  return docId ? (this._documentHtmlCache.get(docId) ?? null) : null;
});

loadDocumentHtml(projectId: string, documentId: string): void {
  if (this._documentHtmlCache.has(documentId)) {
    this._documentConversionStatus.set('COMPLETE');
    return;
  }

  this._isDocumentHtmlLoading.set(true);
  this._documentHtmlError.set(null);
  this._documentConversionStatus.set(null);

  this.complianceApi
    .getDocumentHtml(projectId, documentId)
    .pipe(
      takeUntilDestroyed(this.destroyRef),
      finalize(() => this._isDocumentHtmlLoading.set(false)),
    )
    .subscribe({
      next: (response) => {
        this._documentConversionStatus.set(response.conversionStatus);
        if (response.conversionStatus === 'COMPLETE' && response.html) {
          this._documentHtmlCache.set(documentId, response.html);
        }
      },
      error: (err) => {
        if (err.status === 502) {
          this._documentConversionStatus.set('FAILED');
          this._documentHtmlError.set('Document conversion failed. Please re-upload.');
        } else {
          this._documentHtmlError.set('Failed to load document content.');
        }
      },
    });
}
```

---

## Validation Rules

- `projectId` and `documentId` must be valid UUIDs (`ParseUUIDPipe`).
- Document must belong to the project (via `compliance_project_documents` join).
- `autoTag` query parameter: parsed as boolean string (`'true'` / `'false'`).

---

## Contracts NOT in This File (Tagging-Dependent)

The following contracts from the original `PRCR-1260-contracts.md` are **not duplicated here** because they depend on the tagging redesign:

- `LinenumRange` type (NestJS)
- `buildLinenumMapFromHtml()` helper
- `charOffsetToLinenum()` helper
- `CreateComplianceItemSelection` type updates (frontend)
- Selection → linenum mapping patterns
- Block-level highlighting CSS patterns

These will be finalized after the tagging redesign merges and the coordinate system is confirmed.
