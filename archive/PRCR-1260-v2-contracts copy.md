# PRCR-1260-v2 — API Contracts, DTOs, and Shared Data Shapes

> Single source of truth for all new or modified request/response shapes between frontend and backend.

> **This document replaces** `PRCR-1260-contracts.md` and `PRCR-1260-VIEWER-contracts.md`. Those earlier documents are superseded.

> **Prerequisite:** This contract targets the `feature/` worktrees (post-tagging-redesign). The `InlineTag` interface referenced here uses flat-text offsets (`startOffset`/`endOffset`), which is the `feature/` branch version. The `main` branch has a different `InlineTag` shape (block-based coordinates).

---

## Table of Contents

1. [New Endpoints](#1-new-endpoints)
2. [Modified Endpoints](#2-modified-endpoints)
3. [New/Modified DTOs (Backend)](#3-newmodified-dtos-backend)
4. [Database Schema Changes](#4-database-schema-changes)
5. [Frontend Types](#5-frontend-types)
6. [Error Responses](#6-error-responses)
7. [Event Payloads (Internal)](#7-event-payloads-internal)

---

## 1. New Endpoints

### 1.1 GET /compliance/projects/:projectId/documents/:documentId/content

**Purpose**: Retrieve the converted HTML content for a compliance source document.

| Field | Value |
|-------|-------|
| Method | `GET` |
| Auth | JWT (same as other compliance endpoints) |
| Path params | `projectId: UUID`, `documentId: UUID` |
| Query params | none |
| Request body | none |

**Response — 200 OK**

```json
{
  "html": "<body><h1>Section 1</h1><p>The contractor shall...</p></body>",
  "documentId": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
  "processingStatus": "extraction_complete"
}
```

| Field | Type | Description |
|-------|------|-------------|
| `html` | `string` | Stripped HTML content from Docling conversion. Contains structural tags (`<p>`, `<table>`, `<h1>`, etc.) but no `<style>`, `<script>`, or `<head>`. **Known limitation**: documents with embedded base64 images can produce multi-megabyte payloads. NestJS/Express gzip compression mitigates this. Streaming/chunked transfer is deferred as future work. |
| `documentId` | `string (UUID)` | Echo of the requested document ID. |
| `processingStatus` | `string` | One of: `pending_extraction`, `extracting`, `extraction_complete`, `extraction_failed`. |

**Error responses**: see [Section 6](#6-error-responses).

---

### 1.2 DELETE /compliance/projects/:projectId/documents/:documentId

**Purpose**: Delete a source document and cascade-remove all associated compliance items, checks, and evidence.

| Field | Value |
|-------|-------|
| Method | `DELETE` |
| Auth | JWT |
| Path params | `projectId: UUID`, `documentId: UUID` |
| Request body | none |

**Response — 204 No Content**

No response body.

**Side effects**:
- MinIO objects deleted (original file + converted HTML).
- `compliance_documents` row deleted.
- DB cascade removes: `compliance_project_documents` link, `compliance_items` (via `source_document_id`), `compliance_checks` (via items), `compliance_item_evidence` (via checks and `response_document_id`).

**Error responses**: see [Section 6](#6-error-responses).

---

### 1.3 POST /compliance/projects/:projectId/documents/:documentId/process

**Purpose**: Trigger auto-tagging for a single document. Used by the overview page after uploading a new document.

| Field | Value |
|-------|-------|
| Method | `POST` |
| Auth | JWT |
| Path params | `projectId: UUID`, `documentId: UUID` |
| Request body | none |

**Response — 202 Accepted**

No response body.

**Behaviour**:
- Verifies document belongs to project via `compliance_project_documents`.
- Sets `processingStatus` to `extracting` on the document.
- Calls `TaggingService.requestAutoTag()` with `ProductCode.COMPLIANCE`, document's `minioObjectKey`, `StorageType.MINIO`.
- Saves returned `taggableDocId` on the `ComplianceDocument`.
- Does **not** modify project-level `autotag_processing` (that flag is only for the wizard's bulk flow).
- Completion is handled by the existing `ComplianceListener.handleAutoTagComplete` (same as bulk flow).

**Error responses**: see [Section 6](#6-error-responses).

---

## 2. Modified Endpoints

### 2.1 GET /compliance/projects/:projectId (existing, minor addition)

**Change**: Include `processingStatus` and `convertedHtmlKey` in the document relations returned with the project.

**Existing response shape** (documents portion):

```json
{
  "id": "...",
  "projectName": "...",
  "documents": [
    {
      "projectId": "...",
      "documentId": "...",
      "document": {
        "id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
        "documentName": "RFP-SOW.pdf",
        "fileSizeBytes": "1048576",
        "mimeType": "application/pdf",
        "processingStatus": "extraction_complete",
        "createdAt": "2025-01-15T10:30:00Z",
        "updatedAt": "2025-01-15T10:35:00Z"
      }
    }
  ]
}
```

**New field on `document`**:

| Field | Type | Description |
|-------|------|-------------|
| `processingStatus` | `string \| null` | One of: `pending_extraction`, `extracting`, `extraction_complete`, `extraction_failed`, or `null`. |

> Note: `convertedHtmlKey` is **not** exposed to the frontend — it's an internal storage detail. The frontend uses the GET content endpoint to retrieve HTML.

---

## 3. New/Modified DTOs (Backend)

### 3.1 DocumentContentResponseDto (new)

```typescript
// rohan_api-parent/feature/src/compliance/dto/document-content-response.dto.ts

import { ApiProperty } from '@nestjs/swagger';

export class DocumentContentResponseDto {
  @ApiProperty({ description: 'Stripped HTML content from Docling conversion' })
  html: string;

  @ApiProperty({ description: 'Document UUID' })
  documentId: string;

  @ApiProperty({
    description: 'Current processing status',
    enum: ['pending_extraction', 'extracting', 'extraction_complete', 'extraction_failed'],
  })
  processingStatus: string;
}
```

### 3.2 AutoTagRequestDto (unchanged)

The existing `AutoTagRequestDto` is not modified. The per-document process endpoint (Section 1.3) takes no request body — it acts on the document identified in the URL path.

```typescript
// rohan_api-parent/feature/src/compliance/dto/auto-tag-request.dto.ts (no change)

export class AutoTagRequestDto {
  @IsOptional()
  @IsBoolean()
  is_auto_tag?: boolean;
}
```

### 3.3 ComplianceProjectResponseDto / project GET (modified)

The `ComplianceDocument` relation already includes `processingStatus` in the entity. **Verified**: the `ComplianceDocument` entity on the `feature/` branch has no `@Exclude()` / `@Expose()` decorators — `processingStatus` serializes naturally. No DTO change needed.

---

## 4. Database Schema Changes

### 4.1 New column on `compliance_documents`

```sql
-- Add to init_compliance.sql or as a migration

ALTER TABLE compliance_documents
  ADD COLUMN converted_html_key VARCHAR(500) NULL;

COMMENT ON COLUMN compliance_documents.converted_html_key IS
  'MinIO object key for the Docling-converted stripped HTML. Populated after auto-tag completion.';
```

**TypeORM entity addition**:

```typescript
// In ComplianceDocument entity

@Column({
  name: 'converted_html_key',
  type: 'varchar',
  length: 500,
  nullable: true,
})
convertedHtmlKey: string | null;
```

### 4.2 No other schema changes

- Existing `ON DELETE CASCADE` constraints handle document deletion.
- `document_start_line` / `document_end_line` on `compliance_items` retain their current semantics (character offsets). No schema change.

---

## 5. Frontend Types

### 5.1 ComplianceDocument (modified)

```typescript
// compliance-project.types.ts

export interface ComplianceDocument {
  id: string;
  documentName: string;
  fileSizeBytes?: string | null;
  mimeType?: string | null;
  processingStatus?: ProcessingStatus | null;  // NEW
  createdAt?: string;
  updatedAt?: string;
}

export type ProcessingStatus =
  | 'pending_extraction'
  | 'extracting'
  | 'extraction_complete'
  | 'extraction_failed';
```

### 5.2 DocumentContentResponse (new)

```typescript
// compliance-project.types.ts (or compliance-item.types.ts)

export interface DocumentContentResponse {
  html: string;
  documentId: string;
  processingStatus: string;
}
```

### 5.3 ComplianceSourceDocument (modified)

The viewer-panel's internal model changes from line-based to HTML-based:

```typescript
// compliance-item.types.ts

export interface ComplianceSourceDocument {
  id: string;
  projectId: string;
  documentName: string;
  documentCode: string;
  processingStatus?: ProcessingStatus | null;  // NEW
  // REMOVED: lines, pageNumber, totalPages
}
```

> `htmlContent` is NOT stored on this interface — it's loaded on-demand by the state service and stored in a separate signal.

### 5.4 ComplianceSourceDocumentLine (deprecated)

This interface is no longer used by the HTML viewer. It may be removed or kept temporarily if tests reference it.

### 5.x InlineTag (shared — no change, for reference)

The `app-doc-shell` component accepts `InlineTag[]` for highlighting. The compliance viewer maps each compliance item to this shape:

```typescript
// shared-services/tagging/types/tagging-ui.types.ts (EXISTING — no change)

export interface InlineTag {
  id: string;
  startOffset: number;  // Flattened text offset (same space as compliance item's documentStartLine)
  endOffset: number;    // Flattened text offset (same space as compliance item's documentEndLine)
  label: string;
  kind?: string;
  color?: string;       // Hex colour with alpha, e.g. "rgba(0,188,212,0.7)" for cyan
  x: number;
  y: number;
  hidden?: boolean;
  isManualPosition?: boolean;
}
```

The compliance viewer component creates `InlineTag[]` from `ComplianceItemView[]`:

```typescript
// In document-viewer-panel.component.ts (conceptual)

const inlineTags: InlineTag[] = items
  .filter(item => item.documentStartLine != null && item.documentEndLine != null)
  .map(item => ({
    id: item.id,
    startOffset: item.documentStartLine!,
    endOffset: item.documentEndLine!,
    label: item.complianceItemTitle,
    color: item.id === selectedItemId ? CYAN_HEX : item.status === 'approved' ? TEAL_HEX : MUTED_HEX,
    x: 0,
    y: 0,
  }));
```

### 5.5 CreateComplianceItemSelection (clarified)

```typescript
// compliance-item.types.ts

export interface CreateComplianceItemSelection {
  documentId: string;
  selectionText: string;
  startLine: number;   // Flattened visible text offset (despite the "line" name — kept for backward compat)
  endLine: number;     // Flattened visible text offset (despite the "line" name — kept for backward compat)
}
```

### 5.6 CreateComplianceItemRequest (clarified)

```typescript
// compliance-item.types.ts

export interface CreateComplianceItemRequest {
  sourceDocumentId: string;
  lineItemNumber?: number;
  complianceItemTitle: string;
  complianceItemText: string;
  outlineNumber?: string;
  sectionName?: string;
  documentStartLine?: number;  // Flattened visible text offset (see note above)
  documentEndLine?: number;    // Flattened visible text offset (see note above)
  extractionMethod?: ExtractionMethod;
}
```

### ~~5.7 HighlightRegion~~ (removed)

`HighlightRegion` is no longer needed. With `app-doc-shell` handling highlighting via `InlineTag[]`, the old line-based overlay data type is superseded. Remove this interface and the `highlightRegions` computed signal in `ComplianceStateService` when the viewer migration is complete.

---

## 6. Error Responses

All error responses follow the existing NestJS `HttpException` format:

```json
{
  "statusCode": 404,
  "message": "Document not found or does not belong to this project.",
  "error": "Not Found"
}
```

### GET /compliance/projects/:projectId/documents/:documentId/content

| Status | Condition | Message |
|--------|-----------|---------|
| **200** | Document is converted and HTML is available | — |
| **404** | Document not found, not linked to project, or no converted HTML key | `"Document not found or content not available."` |
| **409** | Document exists but `processingStatus` is `pending_extraction` or `extracting` | `"Document is still being processed. Please try again later."` |
| **500** | MinIO read failure | `"Failed to retrieve document content."` |

### DELETE /compliance/projects/:projectId/documents/:documentId

| Status | Condition | Message |
|--------|-----------|---------|
| **204** | Document deleted successfully | — |
| **404** | Document not found or not linked to project | `"Document not found or does not belong to this project."` |
| **500** | MinIO delete failure (document row is still deleted) | Logged server-side; 204 still returned (best-effort MinIO cleanup). |

### POST /compliance/projects/:projectId/documents/:documentId/process

| Status | Condition | Message |
|--------|-----------|---------|
| **202** | Auto-tagging triggered successfully | — |
| **404** | Document not found or not linked to project | `"Document not found or does not belong to this project."` |
| **409** | Document is already being processed (`processingStatus` is `extracting`) | `"Document is already being processed."` |

---

## 7. Event Payloads (Internal)

These are internal event shapes — not HTTP contracts — but documented here for cross-service clarity.

### 7.1 ComplianceAutoTagEvent (unchanged)

The bulk auto-tag event used by the wizard flow is not modified. The per-document flow (overview page) bypasses this event entirely — it calls `TaggingService.requestAutoTag()` directly from the service method.

```typescript
// rohan_api-parent/feature/src/compliance/events/autotag.event.ts (no change)

export interface ComplianceAutoTagEvent {
  compliance_project_id: string;
  is_auto_tag?: boolean;
  user: RequestUser;
}
```

### 7.2 AutoTagCompleteEvent (unchanged, for reference)

```typescript
export interface AutoTagCompleteEvent {
  productCode: ProductCode;
  documentId: number | string;
  taggableDocId?: number;
  result: AutoTagCompleteResult;
  is_auto_tag?: boolean;
  convertedHtmlUrl?: string;   // MinIO key or Azure blob URL
  orgId?: string;
  userSub?: string;
}
```

The compliance listener will read `convertedHtmlUrl` and store it as `convertedHtmlKey` on the `ComplianceDocument` entity.

---

## Revision History

| Date | Author | Change |
|------|--------|--------|
| 2026-03-25 | Planner agent | Initial draft |
| 2026-03-25 | Planner agent | Resolved OQ-1 through OQ-6. Changed per-doc auto-tag from bulk endpoint filter to new `POST .../documents/:docId/process` endpoint. Removed `documentIds` from `AutoTagRequestDto` and `ComplianceAutoTagEvent`. Removed confirmation dialog on delete. |
| 2026-03-25 | Planner agent | Resolved OQ-4 and OQ-7. Switched to reusing shared `app-doc-shell` component (from Proposal Writer) for rendering and highlighting. Offsets are flattened visible text (not raw HTML) — Python and `doc-shell` use identical algorithm. Added `InlineTag` mapping reference. Simplified Phases 6 and 7. |
| 2026-03-25 | Review pass | Added `feature/` worktree prerequisite. Verified `ComplianceDocument` entity has no `@Exclude()` decorators. Fixed offset comments to "flattened visible text offset". Removed `HighlightRegion` (superseded by `InlineTag`). Noted large HTML payload limitation. Fixed `BlobStorageService` method name (`downloadBuffer`). Replaced `DocumentShreddingModule` references with `SharedComponentsModule`. |
