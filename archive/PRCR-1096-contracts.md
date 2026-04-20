# PRCR-1096 — API Contracts & Data Shapes

> Single source of truth for shared contracts between rohan-python-api and rohan_api (NestJS).

## 1. AutoTagRequestMessage — new fields

### 1a. `storage_type`

#### Python (inbound — `tagging_message.py`)

```python
storage_type: Literal["azure_blob", "minio"] = Field(
    default="azure_blob",
    description="Storage backend for document download/upload: azure_blob or minio",
)
```

#### NestJS (outbound — `AutoTagRequestMessage.ts`)

```typescript
/** Storage backend for document I/O. Defaults to azure_blob for backward compat. */
storage_type?: 'azure_blob' | 'minio';
```

Add to `toJSON()`:

```typescript
storage_type: this.storage_type ?? 'azure_blob',
```

#### AutoTagRequestOptions (NestJS interface)

```typescript
/** Storage backend: 'azure_blob' (default) or 'minio'. */
storageType?: 'azure_blob' | 'minio';
```

#### Backward compatibility

- `storage_type` defaults to `"azure_blob"` on both sides.
- Existing messages without the field are handled as Azure Blob (no breaking change).

### 1b. `output_folder` (per-request override)

#### Python (inbound — `tagging_message.py`)

```python
output_folder: str | None = Field(
    default=None,
    description="Override subfolder for converted HTML output. "
    "Falls back to MINIO_TAGGING_FOLDER_OUT / hardcoded 'output' when None.",
)
```

#### NestJS (outbound — `AutoTagRequestMessage.ts`)

```typescript
/** Optional override for the output subfolder (e.g. "converted"). Falls back to server default. */
output_folder?: string;
```

Add to `toJSON()`:

```typescript
...(this.output_folder ? { output_folder: this.output_folder } : {}),
```

#### AutoTagRequestOptions (NestJS interface)

```typescript
/** Override subfolder for converted HTML output. Falls back to server-side default. */
outputFolder?: string;
```

#### Resolution order (Python handler)

```
message.output_folder  ??  settings.MINIO_TAGGING_FOLDER_OUT  ??  "output"
```

---

## 2. AutoTagCompleteMessage — no changes

The completion message schema is unchanged. `DocumentResult.converted_html_url` remains a
**relative object path** (e.g., `org_abc/docs/output/file1.html`), regardless of storage
backend. The consumer (NestJS) determines how to resolve it based on the product context.

---

## 3. Python config — new settings (`config.py`)

```python
# MinIO Tagging Configuration (reuses MINIO_ENDPOINT/PORT/ACCESS_KEY/SECRET_KEY/USE_SSL/REGION)
MINIO_TAGGING_BUCKET: str = "uploads"
MINIO_TAGGING_FOLDER_OUT: str = "output"
```

| Setting                  | Default     | Description                                           |
|--------------------------|-------------|-------------------------------------------------------|
| `MINIO_TAGGING_BUCKET`   | `"uploads"` | MinIO bucket for tagging document I/O                 |
| `MINIO_TAGGING_FOLDER_OUT` | `"output"` | Subfolder prefix for converted HTML uploads in MinIO |

Connection settings (`MINIO_ENDPOINT`, `MINIO_PORT`, `MINIO_ACCESS_KEY`, `MINIO_SECRET_KEY`,
`MINIO_USE_SSL`, `MINIO_REGION`) are shared with the visualizer.

---

## 4. Validation rules

| Condition                          | Required env vars                                       |
|------------------------------------|---------------------------------------------------------|
| `storage_type == "azure_blob"`     | `STORAGE_CONNECTION_STRING` must be non-empty           |
| `storage_type == "minio"`          | `MINIO_ACCESS_KEY` and `MINIO_SECRET_KEY` must be set   |

Validation is performed at call time (when `download_file` / `upload_file` are invoked),
not at startup, since both backends may be active simultaneously.

---

## 5. Error format — no changes

Error handling and error shapes in `AutoTagCompleteMessage` are unchanged.
Storage-backend errors (e.g., MinIO connection failure, bucket not found) surface through
the existing `DocumentResult.error` string field and the completion `status: "failed"` path.

---

## 6. NestJS caller contract

| Caller                       | `blobPath` source       | `storageType`   | `outputFolder` |
|------------------------------|-------------------------|-----------------|----------------|
| Template Generator listener  | `document.blobstore_id` | `'azure_blob'`  | not set        |
| Compliance listener          | `doc.minioObjectKey`    | `'minio'`       | not set        |
| Future callers               | varies                  | set per product | optional       |

---

## 7. `converted_html_url` resolution by product

| Product            | Storage backend | `converted_html_url` format         | NestJS consumer action              |
|--------------------|-----------------|--------------------------------------|-------------------------------------|
| template_generator | Azure Blob      | Azure Blob relative path             | Stored as `content` on document row |
| compliance         | MinIO           | MinIO object key (same path format)  | Not currently read by listener      |
