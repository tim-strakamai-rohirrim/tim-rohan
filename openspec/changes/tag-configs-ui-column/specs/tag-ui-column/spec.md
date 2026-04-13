## ADDED Requirements

### Requirement: tag_configs table has a tag_ui JSONB column
The `tag_configs` table SHALL have a nullable `tag_ui JSONB` column that stores UI-specific display metadata separately from the backend-facing `tag_schema` column.

#### Scenario: Column exists after schema initialization
- **WHEN** the database initialization scripts run (`init_tagging_tables.sql`)
- **THEN** the `tag_configs` table has a `tag_ui` column of type `JSONB` that allows null values

#### Scenario: Existing rows are unaffected
- **WHEN** the `ALTER TABLE` migration runs on a database with existing `tag_configs` rows
- **THEN** existing rows have `tag_ui = NULL` and all other columns are unchanged

### Requirement: tag_ui is seeded for each product
The seed script SHALL populate `tag_ui` for every product code (except dynamic-schema products) with a normalized `tags[]` array containing display metadata (`id`, `name`, `color`) extracted from the corresponding `tag_schema` values. Products with dynamic schemas SHALL have `tag_ui = NULL`.

#### Scenario: template_generator tag_ui seed
- **WHEN** the seed script runs for `template_generator`
- **THEN** `tag_ui` contains `{"tags": [...]}` with one entry per category in `tag_schema.categories`, each having `id` matching the category `id`, `name` matching the category `name`, and `color` matching the category `color`

#### Scenario: compliance tag_ui seed
- **WHEN** the seed script runs for `compliance`
- **THEN** `tag_ui` contains `{"tags": [{"id": "compliance_item", "name": "Add Compliance Item", "color": "#CCE5FF"}]}` — a normalized entry for the compliance tagging action

#### Scenario: compliance_response tag_ui seed
- **WHEN** the seed script runs for `compliance_response`
- **THEN** `tag_ui` is `NULL` (dynamic schema — no static UI metadata)

#### Scenario: proposal_writer tag_ui seed
- **WHEN** the seed script runs for `proposal_writer`
- **THEN** `tag_ui` contains `{"tags": [...]}` with one entry per category in `tag_schema.categories`, each having `id` matching the category `id`, `name` matching the category `name`, and `color` matching the category `color`

#### Scenario: Upsert updates tag_ui
- **WHEN** the seed script runs and a row for that product_code already exists
- **THEN** the `tag_ui` column is updated to the new value alongside `tag_schema`

### Requirement: NestJS TagConfig entity includes tag_ui
The `TagConfig` TypeORM entity SHALL include a `tag_ui` property mapped to the `tag_ui` JSONB column, typed as `Record<string, any> | null`.

#### Scenario: Entity shape
- **WHEN** a `TagConfig` entity is loaded from the database
- **THEN** the `tag_ui` property is present and contains the JSONB value (or null if not set)

### Requirement: NestJS DTOs include tag_ui
The `CreateTagConfigDto` and `UpdateTagConfigDto` SHALL accept an optional `tag_ui` field. The field MUST be validated as an object when present.

#### Scenario: Create with tag_ui
- **WHEN** a `POST /tagging/tag-configs` request includes a `tag_ui` object in the body
- **THEN** the created `TagConfig` row has the provided `tag_ui` value

#### Scenario: Create without tag_ui
- **WHEN** a `POST /tagging/tag-configs` request omits `tag_ui`
- **THEN** the created `TagConfig` row has `tag_ui = NULL`

#### Scenario: Update tag_ui
- **WHEN** a `PATCH /tagging/tag-configs/:id` request includes a `tag_ui` object
- **THEN** the `tag_ui` column is updated to the new value

### Requirement: REST API response includes tag_ui
The `GET /tagging/tag-configs` and `GET /tagging/tag-configs/:id` endpoints SHALL include `tag_ui` in the response payload.

#### Scenario: List all returns tag_ui
- **WHEN** a client calls `GET /tagging/tag-configs`
- **THEN** each `TagConfig` object in the response array includes a `tag_ui` field (object or null)

#### Scenario: Get by ID returns tag_ui
- **WHEN** a client calls `GET /tagging/tag-configs/:id`
- **THEN** the response includes a `tag_ui` field (object or null)

### Requirement: tag_ui is not sent to the Python pipeline
The `AutoTagRequestMessage` SHALL NOT include `tag_ui` in its serialized `tag_config` envelope. The Python pipeline has no use for UI display metadata.

#### Scenario: Service Bus message excludes tag_ui
- **WHEN** an auto-tag request is sent to the Service Bus queue
- **THEN** the serialized message's `tag_config` object does not contain a `tag_ui` key

### Requirement: Angular UI prefers tag_ui for display metadata
The Angular `TaggingService` SHALL resolve tag colors, labels, and kinds from `tag_ui.tags` when the field is present and contains a non-empty array. It SHALL fall back to the existing `tag_schema` resolution logic when `tag_ui` is absent or its `tags` array is empty.

#### Scenario: Resolve color from tag_ui
- **WHEN** the active `TagConfigResponse` has a `tag_ui` with a non-empty `tags` array
- **AND** the caller requests the color for a tag_type that exists in `tag_ui.tags`
- **THEN** the color from `tag_ui.tags` is returned

#### Scenario: Resolve label from tag_ui
- **WHEN** the active `TagConfigResponse` has a `tag_ui` with a non-empty `tags` array
- **AND** the caller requests the label for a tag_type that exists in `tag_ui.tags`
- **THEN** the `name` from the matching `tag_ui.tags` entry is returned

#### Scenario: Fallback to tag_schema when tag_ui is null
- **WHEN** the active `TagConfigResponse` has `tag_ui: null`
- **THEN** the service resolves display metadata from `tag_schema` using existing logic

#### Scenario: Fallback to tag_schema when tag_ui.tags is empty
- **WHEN** the active `TagConfigResponse` has `tag_ui` with an empty `tags` array
- **THEN** the service resolves display metadata from `tag_schema` using existing logic

### Requirement: DocShell context menu prefers tag_ui
The `DocShellComponent.buildMenuConfig()` method SHALL build context-menu entries from `tag_ui.tags` when available, falling back to `tag_schema` when it is not.

#### Scenario: Menu built from tag_ui
- **WHEN** the input `tagConfig` has a `tag_ui` with a non-empty `tags` array
- **THEN** the context menu entries use `name` as label and `id` as value from `tag_ui.tags`

#### Scenario: Menu falls back to tag_schema
- **WHEN** the input `tagConfig` has `tag_ui: null`
- **THEN** the context menu entries are built from `tag_schema` using existing logic

### Requirement: Angular TagConfigResponse type includes tag_ui
The `TagConfigResponse` interface SHALL include `tag_ui: TagUi | null` and a new `TagUi` interface defining the normalized shape.

#### Scenario: Type shape
- **WHEN** a developer inspects the `TagConfigResponse` type
- **THEN** it includes `tag_ui: TagUi | null`
- **AND** `TagUi` has `tags: TagUiEntry[]` where `TagUiEntry` has `id: string`, `name: string`, and `color: string`
