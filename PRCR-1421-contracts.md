# PRCR-1421 — Contracts

## Contract → Phase Mapping

| Contract Section | Phase(s) | Notes |
|------------------|----------|-------|
| 1.1 tag_ui column DDL | 1 | ALTER TABLE in init_tagging_tables.sql |
| 1.2 tag_ui seed data | 1 | Populated in init_tag_configs.sql for all products |
| 2.1 TagConfig entity | 2 | New nullable JSONB column |
| 2.2 CreateTagConfigDto | 2 | Optional tag_ui field |
| 2.3 UpdateTagConfigDto | 2 | Optional tag_ui field |
| 2.4 TaggingTagConfigsService changes | 2 | create() and updateById() handle tag_ui |
| 2.5 API response shape | 2 | tag_ui included in all TagConfig responses |
| 3.1 TagUi interface | 3 | New frontend types |
| 3.2 TagConfigResponse update | 3 | Adds tag_ui to response type |
| 3.3 TaggingService metadata resolution | 3 | Prefers tag_ui over tag_schema |
| 3.4 DocShellComponent menu building | 3 | Prefers tag_ui over tag_schema |

---

## 1. Database Schema Changes

### 1.1 `tag_ui` Column DDL

Add to `Database/rohan_api/scripts/sql/init_tagging_tables.sql`, immediately after the `CREATE TABLE tag_configs` block and before the trigger definition (keeps DDL logically grouped with the table it modifies):

```sql
-- Add tag_ui JSONB column for UI display metadata (colors, labels),
-- kept separate from tag_schema which drives backend classification.
-- NOTE: tag_ui and tag_schema both contain display metadata during migration.
-- Keep them in sync until tag_schema display fields are removed.
ALTER TABLE tag_configs ADD COLUMN IF NOT EXISTS tag_ui JSONB;
```

### 1.2 `tag_ui` Seed Data

Each product's `INSERT` in `Database/rohan_api/scripts/sql/init_tag_configs.sql` adds `tag_ui` as a new column. The `ON CONFLICT ... DO UPDATE SET` clause includes `tag_ui = EXCLUDED.tag_ui`. Seed JSON uses multi-line formatting for readability.

#### `template_generator`

```sql
-- NOTE: tag_ui and tag_schema both contain display metadata (colors, names) during migration.
-- Keep them in sync until tag_schema display fields are removed.
INSERT INTO tag_configs (product_code, segmentation_strategy, prompt_name, rule_pattern, tag_schema, tag_ui)
VALUES (
  'template_generator',
  'block',
  'template_generator_tagging_prompt',
  NULL,
  -- tag_schema unchanged --
  '{...existing tag_schema...}'::jsonb,
  '{
    "tags": [
      { "id": "section_header",    "name": "Section Header",    "color": "#76D2C6" },
      { "id": "sub_section_title", "name": "Sub Section Title", "color": "#9EDFF0" },
      { "id": "helper_text",       "name": "Helper Text",       "color": "#C9B1EE" },
      { "id": "instructions_text", "name": "Instructions Text", "color": "#FFBA7C" }
    ]
  }'::jsonb
)
ON CONFLICT (product_code) DO UPDATE SET
  segmentation_strategy = EXCLUDED.segmentation_strategy,
  prompt_name           = EXCLUDED.prompt_name,
  rule_pattern          = EXCLUDED.rule_pattern,
  tag_schema            = EXCLUDED.tag_schema,
  tag_ui                = EXCLUDED.tag_ui,
  updated_on            = NOW();
```

#### `compliance`

```sql
'{
  "tags": [
    { "id": "compliance_item", "name": "Add Compliance Item", "color": "#CCE5FF" }
  ]
}'::jsonb
```

#### `compliance_response`

```sql
-- Dynamic schema — no static UI metadata
NULL  -- tag_ui
```

#### `proposal_writer`

```sql
'{
  "tags": [
    { "id": "instructions",       "name": "Instructions",       "color": "#FFFFCC" },
    { "id": "structure",           "name": "Structure",           "color": "#CCE5FF" },
    { "id": "evaluation_criteria", "name": "Evaluation Criteria", "color": "#FFD9CC" },
    { "id": "requirements",        "name": "Requirements",        "color": "#CCFFCC" }
  ]
}'::jsonb
```

---

## 2. NestJS Backend Changes

### 2.1 TagConfig Entity

File: `src/tagging/entities/tagConfig.entity.ts`

```typescript
import {
  Entity,
  Column,
  PrimaryGeneratedColumn,
  CreateDateColumn,
  UpdateDateColumn,
} from 'typeorm';
import { ProductCode } from 'src/tagging/types/product-code.enum';
import { SegmentationStrategy } from 'src/tagging/types/segmentation-strategy.enum';

@Entity('tag_configs')
export class TagConfig {
  @PrimaryGeneratedColumn()
  tag_config_id: number;

  @Column({ type: 'enum', enum: ProductCode })
  product_code: ProductCode;

  @Column({ type: 'jsonb' })
  tag_schema: Record<string, any>;

  @Column({ type: 'jsonb', nullable: true })
  tag_ui: Record<string, any> | null;

  @Column({ type: 'enum', enum: SegmentationStrategy })
  segmentation_strategy: SegmentationStrategy;

  @Column({ length: 128 })
  prompt_name: string;

  @Column({ type: 'jsonb', nullable: true })
  rule_pattern: Record<string, any>;

  @CreateDateColumn({ type: 'timestamptz' })
  created_on: Date;

  @UpdateDateColumn({ type: 'timestamptz' })
  updated_on: Date;
}
```

### 2.2 CreateTagConfigDto

File: `src/tagging/dto/create-tag-config.dto.ts`

Added field (all other fields unchanged):

```typescript
@IsOptional()
@IsObject()
tag_ui?: Record<string, any>;
```

### 2.3 UpdateTagConfigDto

File: `src/tagging/dto/update-tag-config.dto.ts`

Added field (all other fields unchanged):

```typescript
@IsOptional()
@IsObject()
tag_ui?: Record<string, any>;
```

### 2.4 TaggingTagConfigsService Changes

File: `src/tagging/tagging.tag-configs.service.ts`

**`create()` method** — include `tag_ui`:

```typescript
async create(dto: CreateTagConfigDto): Promise<TagConfig> {
  const config = this.tagConfigRepository.create({
    product_code: dto.product_code,
    tag_schema: dto.tag_schema,
    tag_ui: dto.tag_ui ?? undefined,
    segmentation_strategy: dto.segmentation_strategy,
    prompt_name: dto.prompt_name,
    rule_pattern: dto.rule_pattern ?? undefined,
  });
  return this.tagConfigRepository.save(config);
}
```

**`updateById()` method** — add conditional assignment after existing fields:

```typescript
if (dto.tag_ui !== undefined) {
  config.tag_ui = dto.tag_ui;
}
```

### 2.5 API Response Shape

The controller returns the raw `TagConfig` entity. No controller changes needed — `tag_ui` is automatically included.

**GET `/tagging/tag-configs` response** (example, single item):

```json
[
  {
    "tag_config_id": 1,
    "product_code": "template_generator",
    "tag_schema": {
      "categories": [
        { "id": "section_header", "name": "Section Header", "color": "#76D2C6", "element_types": ["h1", "h2", "h3", "h4", "h5", "h6"] }
      ],
      "default_tag": null
    },
    "tag_ui": {
      "tags": [
        { "id": "section_header", "name": "Section Header", "color": "#76D2C6" },
        { "id": "sub_section_title", "name": "Sub Section Title", "color": "#9EDFF0" },
        { "id": "helper_text", "name": "Helper Text", "color": "#C9B1EE" },
        { "id": "instructions_text", "name": "Instructions Text", "color": "#FFBA7C" }
      ]
    },
    "segmentation_strategy": "block",
    "prompt_name": "template_generator_tagging_prompt",
    "rule_pattern": null,
    "created_on": "2025-01-01T00:00:00.000Z",
    "updated_on": "2025-01-01T00:00:00.000Z"
  }
]
```

When `tag_ui` is null (e.g. `compliance_response`):

```json
{
  "tag_config_id": 3,
  "product_code": "compliance_response",
  "tag_schema": { "categories": [], "dynamic": true },
  "tag_ui": null,
  "segmentation_strategy": "sentence",
  "prompt_name": "compliance_response_tagging",
  "rule_pattern": null,
  "created_on": "2025-01-01T00:00:00.000Z",
  "updated_on": "2025-01-01T00:00:00.000Z"
}
```

---

## 3. Angular Frontend Changes

### 3.1 TagUi Interface

File: `src/app/shared-services/tagging/types/tagging.tag-config.types.ts`

New types added before `TagConfigResponse`:

```typescript
export interface TagUiEntry {
    id: string;
    name: string;
    color: string;
}

export interface TagUi {
    tags: TagUiEntry[];
}
```

### 3.2 TagConfigResponse Update

File: `src/app/shared-services/tagging/types/tagging.tag-config.types.ts`

Updated interface (new field only):

```typescript
export interface TagConfigResponse {
    tag_config_id: number;
    product_code: ProductCode;
    tag_schema: TagSchema | null;
    tag_ui: TagUi | null;            // <-- NEW
    prompt_name: string;
    rule_pattern: TagConfigRulePattern | null;
    created_on: Date;
    updated_on: Date;
}
```

For reference, `TagConfigRequest` and `UpdateTagConfigRequest` also get `tag_ui`:

```typescript
export interface TagConfigRequest {
    product_code: ProductCode;
    tag_schema: TagSchema;
    tag_ui?: TagUi | null;           // <-- NEW (optional)
    prompt_name: string;
    rule_pattern: TagConfigRulePattern | null;
}

export interface UpdateTagConfigRequest {
    tag_schema: TagSchema | null;
    tag_ui?: TagUi | null;           // <-- NEW (optional)
    prompt_name: string | null;
    rule_pattern: TagConfigRulePattern | null;
}
```

### 3.3 TaggingService Metadata Resolution

File: `src/app/shared-services/tagging/tagging.service.ts`

**`getConfiguredTagMetadata()` update** — try `tag_ui` first:

```typescript
private getConfiguredTagMetadata(productCode?: ProductCode | null): {
    labelsByType: Map<string, string>;
    colorsByType: Map<string, string>;
    kindsByType: Map<string, string>;
} {
    if (productCode == null) {
        return this.resolveConfiguredTagMetadata(null);
    }

    const config = this.getTagConfigSnapshot(productCode);
    const tagUi = config?.tag_ui ?? null;
    const tagSchema = config?.tag_schema ?? null;

    const cachedMetadata = this.configuredTagMetadataCache.get(productCode);
    if (cachedMetadata?.tagUi === tagUi && cachedMetadata?.tagSchema === tagSchema) {
        return cachedMetadata.metadata;
    }

    const metadata = tagUi?.tags?.length
        ? this.resolveTagUiMetadata(tagUi)
        : this.resolveConfiguredTagMetadata(tagSchema);

    this.configuredTagMetadataCache.set(productCode, {
        tagUi,
        tagSchema,
        metadata,
    });
    return metadata;
}
```

Cache type update:

```typescript
private readonly configuredTagMetadataCache = new Map<
    ProductCode,
    {
        tagUi: TagUi | null;
        tagSchema: TagSchema | null;
        metadata: {
            labelsByType: Map<string, string>;
            colorsByType: Map<string, string>;
            kindsByType: Map<string, string>;
        };
    }
>();
```

**New `resolveTagUiMetadata()` method**:

```typescript
private resolveTagUiMetadata(tagUi: TagUi): {
    labelsByType: Map<string, string>;
    colorsByType: Map<string, string>;
    kindsByType: Map<string, string>;
} {
    return tagUi.tags.reduce(
        (metadata, entry) => {
            const normalizedId = this.normalizeTagType(entry.id);
            metadata.labelsByType.set(normalizedId, entry.name);
            metadata.colorsByType.set(normalizedId, entry.color);
            metadata.kindsByType.set(normalizedId, normalizedId);
            return metadata;
        },
        {
            labelsByType: new Map<string, string>(),
            colorsByType: new Map<string, string>(),
            kindsByType: new Map<string, string>(),
        },
    );
}
```

### 3.4 DocShellComponent Menu Building

File: `src/app/shared-components/document-shredding/components/document-tagging/doc-shell/doc-shell.component.ts`

**`buildMenuConfig()` update** — try `tag_ui` first:

```typescript
private buildMenuConfig(): TagMenuConfig<string>[] {
    if (!this.tagConfig) {
        throw new Error('Tag config is required to build the tagging menu.');
    }

    const tagUi = this.tagConfig.tag_ui;
    if (tagUi?.tags?.length) {
        return tagUi.tags.map((entry, index) => ({
            label: entry.name,
            value: entry.id,
            indent: index > 0,
        }));
    }

    const tagSchema = this.tagConfig.tag_schema;
    if (!tagSchema) {
        throw new Error('Tag schema is required to build the tagging menu.');
    }

    const schemaTags = this.resolveSchemaTags(tagSchema);
    if (schemaTags.length === 0) {
        throw new Error('Tag schema must define at least one menu tag.');
    }

    return schemaTags.map((schemaTag, index) => ({
        label: schemaTag.displayName,
        value: schemaTag.tagType,
        indent: index > 0,
    }));
}
```

The existing `resolveSchemaTags()` method is left intact as the fallback path.

---

## 4. Error Responses

No new error responses. Existing validation applies:

| Status | Condition | Message |
|--------|-----------|---------|
| 400 | `tag_ui` fails `@IsObject()` validation | `"tag_ui must be an object"` |
| 404 | Config not found on update | `TagConfigNotFoundError` (existing) |

---

## 5. Event Payloads (Internal)

**No changes to `AutoTagRequestMessage`**. The `tag_ui` field is not included in the Service Bus message to Python. Only `tag_schema` is sent via `toJSON()`.

**No changes to `TaggingConfigPayload`** or `AutoTagRequestOptions` interfaces — these are backend-only contracts for the auto-tag flow.

---

## 6. Not Modified (for reference)

These files are **not changed** by this work:

| File | Reason |
|------|--------|
| `src/tagging/tagging.tag-configs.controller.ts` | Returns raw entity; `tag_ui` included automatically |
| `src/tagging/tagging.service.ts` | Handles auto-tag flow; reads `tag_schema` for Python — unchanged |
| `src/tagging/tagging.module.ts` | No new providers or entities |
| `src/utils/roh-azure-utils/message-types/AutoTagRequestMessage.ts` | `tag_ui` not sent to Python |
| `src/proposal-writer/proposal-writer.documents.service.ts` | Uses hardcoded colors, not `tag_schema` |
| `src/compliance/listeners/compliance.listener.ts` | Builds dynamic `tagSchema` at runtime, unrelated to `tag_ui` |
