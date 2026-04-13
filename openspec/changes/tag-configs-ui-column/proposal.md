## Why

The `tag_configs.tag_schema` column currently mixes backend classification logic (categories, indicators, element_types, classification strategies) with UI display metadata (colors, display names, kind mappings). This coupling means backend schema changes risk breaking UI rendering, and UI display tweaks require touching data that flows through the Service Bus to the Python classification pipeline. A dedicated `tag_ui` JSONB column cleanly separates "data the backend needs for tagging" from "data the UI needs for rendering," making both easier to evolve independently.

## What Changes

- Add a `tag_ui JSONB` column to the `tag_configs` database table.
- Populate `tag_ui` in the seed script (`init_tag_configs.sql`) for each product with its display contract (`id`, `name`, `color`) — data currently embedded in `tag_schema`. Products with dynamic schemas (`compliance_response`) use `tag_ui = NULL`.
- Expose `tag_ui` through the NestJS `TagConfig` entity, DTOs, and REST API response so the Angular UI receives it.
- Update the Angular UI (`TaggingService`, `DocumentTaggingFacadeService`, `DocShellComponent`, and type definitions) to read display metadata from `tag_ui` instead of `tag_schema`.
- `tag_ui` is **not** included in the `AutoTagRequestMessage` or sent to the Python pipeline — it is UI-only.
- `tag_schema` retains color/display fields during migration for backward compatibility; removal of duplicated fields from `tag_schema` is out of scope.

## Capabilities

### New Capabilities
- `tag-ui-column`: Adds a `tag_ui` JSONB column to `tag_configs` with a normalized `{ id, name, color }` shape and updates the full-stack flow (DB → API → UI) to use it for display metadata instead of `tag_schema`.

### Modified Capabilities

## Impact

- **Database**: `tag_configs` table gains a nullable `tag_ui` JSONB column; seed script updated for all four products (`template_generator`, `compliance`, `proposal_writer` get populated `tags[]`; `compliance_response` gets `NULL`).
- **NestJS API** (`rohan_api`): `TagConfig` entity, `CreateTagConfigDto`, `UpdateTagConfigDto`, and `TaggingConfigPayload` updated. REST response shape gains `tag_ui` field.
- **Angular UI** (`rohan_ui`): `TagConfigResponse` type, `TaggingService` (color/label/kind resolution), `DocumentTaggingFacadeService`, and `DocShellComponent` context-menu builder updated to read from `tag_ui`.
- **Python API**: Zero changes — `tag_ui` is not sent over Service Bus.
- **Risk**: Low. `tag_ui` is additive (nullable column, new response field). UI reads shift source but the data shape is the same. Existing `tag_schema` fields are not removed.
