## Context

The `tag_configs` table stores per-product tagging configuration as a `tag_schema JSONB` column. This JSONB blob serves two audiences: the Python classification pipeline (categories, indicators, element_types, classification strategy, default_tag) and the Angular UI (display names, colors, kind mappings for rendering tagged highlights and context menus).

Today the Angular `TaggingService` contains ~130 lines of normalization logic (`resolveSchemaTags`, `resolveSchemaTag`, `resolveCategorySchemaTag`, `resolveCategoryKindByReference`) to reconcile the two different shapes (`tags[]` vs `categories[]`) and extract display metadata from `tag_schema`. The `DocShellComponent` duplicates a subset of this normalization for context-menu building.

Adding a `tag_ui` column with a single, normalized shape for display data lets the UI consume it directly with minimal transformation, and decouples UI display concerns from the backend classification schema.

## Goals / Non-Goals

**Goals:**
- Add a `tag_ui JSONB` nullable column to `tag_configs`.
- Define a single normalized shape for `tag_ui` that covers all products, eliminating the tags-vs-categories duality.
- Seed `tag_ui` in `init_tag_configs.sql` for all four products, extracting display data from existing `tag_schema` values.
- Expose `tag_ui` through the NestJS entity, DTOs, and REST API response.
- Update Angular `TaggingService` to prefer `tag_ui` over `tag_schema` for color, label, and kind resolution. Fall back to `tag_schema` when `tag_ui` is null (backward compatibility during rollout).
- Update Angular `DocShellComponent.buildMenuConfig()` to prefer `tag_ui` over `tag_schema` for context-menu entries.

**Non-Goals:**
- Removing display fields (color, name) from `tag_schema`. This is a future cleanup.
- Sending `tag_ui` to the Python pipeline via `AutoTagRequestMessage`. It is UI-only.
- Changing the hardcoded color map in `proposal-writer.documents.service.ts` (NestJS). That map is for HTML export highlighting, unrelated to tag config display metadata.
- Redesigning the UI rendering or highlight system.
- Changing the `tag_schema` structure or seed data.

## Decisions

### 1. Normalized `tag_ui` shape

`tag_ui` uses a flat `tags[]` array — no categories/tags duality:

```json
{
  "tags": [
    { "id": "section_header", "name": "Section Header", "color": "#76D2C6" }
  ]
}
```

Each entry has:
- `id` (string, required): matches `document_tags.tag_type` and `tag_schema` category `id` — the key used for lookups.
- `name` (string, required): human-readable label for UI menus and tooltips.
- `color` (string, required): hex color for highlight rendering.

**Rationale**: The existing `tag_schema` has two shapes — `tags[]` (compliance) and `categories[]` (template_generator, proposal_writer). The UI normalizes both into a common internal structure. Using a minimal `{ id, name, color }` shape in `tag_ui` eliminates that normalization and avoids redundancy (the previous `tag_type`/`kind` fields always carried the same value as `id`). A single `tags[]` array is chosen over `categories[]` because `tags` better describes display metadata entries (they aren't categories in the classification sense).

**Alternative considered**: A richer shape with `tag_type`, `display_name`, `color`, and `kind` — rejected because `tag_type`/`kind` were always identical to `id`, creating redundant fields with no semantic distinction.

### 2. Nullable column with UI-side fallback

`tag_ui` is `JSONB NULL` (nullable), and the UI falls back to reading `tag_schema` when `tag_ui` is absent. This allows incremental rollout: the column can be populated per-product without requiring a synchronized deployment across all services. Products with dynamic tag schemas (e.g., `compliance_response`) use `NULL` to signal that no static UI metadata exists.

**Rationale**: A non-null column with a default empty value (`'{}'`) would require the UI to still handle the "no display data" case identically to the "read from tag_schema" case. Making it nullable makes the fallback explicit: `if tag_ui → use it; else → use tag_schema`. `NULL` is semantically distinct from an empty `{"tags": []}`, which would imply "we have display metadata and it's intentionally empty."

**Alternative considered**: Non-nullable with `DEFAULT '{}'` — rejected because an empty object is semantically ambiguous (does it mean "no display metadata" or "not yet populated"?). Also considered `{"tags": []}` for dynamic products — rejected because `NULL` correctly signals "not applicable."

### 3. Column added via ALTER TABLE in init_tagging_tables.sql

The column is added with `ALTER TABLE tag_configs ADD COLUMN IF NOT EXISTS tag_ui JSONB;` in `init_tagging_tables.sql`, placed immediately after the `CREATE TABLE tag_configs` block and before the trigger definition. This keeps the DDL logically grouped — you read the table definition and its additive migrations together before moving on to triggers and constraints. The column is populated in `init_tag_configs.sql` (where seed data lives). This follows the existing pattern for the `rule_pattern` column.

### 4. ON CONFLICT upsert includes tag_ui

The existing `ON CONFLICT (product_code) DO UPDATE` in `init_tag_configs.sql` is extended to include `tag_ui = EXCLUDED.tag_ui` so re-running the seed script updates display data for existing rows.

### 5. UI resolution strategy

The Angular `TaggingService` method `getConfiguredTagMetadata` gains a `tag_ui`-aware path:
1. If `tag_ui?.tags` is a non-empty array → resolve metadata from `tag_ui.tags` directly (map `id` → tag_type, `name` → label, `color` → color; no normalization needed).
2. Else → fall back to existing `resolveConfiguredTagMetadata(tagSchema)` logic (unchanged).

This keeps the fallback intact and requires minimal code changes. The `configuredTagMetadataCache` key changes from `tagSchema` reference equality to include `tagUi` as well.

`DocShellComponent.buildMenuConfig()` similarly prefers `tag_ui.tags` for menu entries (using `id` as value, `name` as label), falling back to `tag_schema`.

## Risks / Trade-offs

- **Data duplication**: `tag_ui` duplicates display fields already in `tag_schema`. → Mitigated by treating `tag_schema` as the backend's contract and `tag_ui` as the UI's contract. A future cleanup can remove display fields from `tag_schema` once all consumers are migrated.
- **Seed data drift**: If someone updates `tag_schema` colors but forgets `tag_ui`. → Mitigated by placing `tag_ui` values right next to `tag_schema` in the seed script, and adding a comment noting both must stay in sync until `tag_schema` display fields are removed.
- **Cache invalidation**: The metadata cache in `TaggingService` keys on `tagSchema` reference identity. Adding `tag_ui` changes the cache key. → Handled by updating the cache check to compare both `tagSchema` and `tagUi` references.
