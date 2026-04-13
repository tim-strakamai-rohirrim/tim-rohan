## 1. Database

- [x] 1.1 Add `ALTER TABLE tag_configs ADD COLUMN IF NOT EXISTS tag_ui JSONB;` to `Database/rohan_api/scripts/sql/init_tagging_tables.sql`
- [x] 1.2 Add `tag_ui` JSONB values to each of the four `INSERT INTO tag_configs` statements in `Database/rohan_api/scripts/sql/init_tag_configs.sql` — seed normalized `{"tags": [{id, name, color}]}` for `template_generator`, `compliance`, and `proposal_writer`; `NULL` for `compliance_response`
- [x] 1.3 Extend the `ON CONFLICT ... DO UPDATE SET` clause in each upsert to include `tag_ui = EXCLUDED.tag_ui`

## 2. NestJS Entity & DTOs

- [x] 2.1 Add `tag_ui` column to `TagConfig` entity (`rohan_api-parent/feature/src/tagging/entities/tagConfig.entity.ts`) as `@Column({ type: 'jsonb', nullable: true }) tag_ui: Record<string, any> | null;`
- [x] 2.2 Add optional `tag_ui` field to `CreateTagConfigDto` (`rohan_api-parent/feature/src/tagging/dto/create-tag-config.dto.ts`) with `@IsOptional()` and `@IsObject()` validators
- [x] 2.3 Add optional `tag_ui` field to `UpdateTagConfigDto` (`rohan_api-parent/feature/src/tagging/dto/update-tag-config.dto.ts`) with `@IsOptional()` and `@IsObject()` validators
- [x] 2.4 Verify `AutoTagRequestMessage.toJSON()` (`rohan_api-parent/feature/src/utils/roh-azure-utils/message-types/AutoTagRequestMessage.ts`) does not include `tag_ui` — no change needed, just confirm

## 3. Angular Types

- [x] 3.1 Add `TagUiEntry` interface to `tagging.tag-config.types.ts` with `id: string`, `name: string`, `color: string`
- [x] 3.2 Add `TagUi` interface to `tagging.tag-config.types.ts` with `tags: TagUiEntry[]`
- [x] 3.3 Add `tag_ui: TagUi | null` to `TagConfigResponse` interface
- [x] 3.4 Add optional `tag_ui?: TagUi | null` to `TagConfigRequest` and `UpdateTagConfigRequest` interfaces

## 4. Angular TaggingService

- [x] 4.1 Update `getConfiguredTagMetadata` in `tagging.service.ts` to check `tag_ui.tags` first — if non-empty array, resolve metadata directly from it without normalization; else fall back to existing `resolveConfiguredTagMetadata(tagSchema)` logic
- [x] 4.2 Update `configuredTagMetadataCache` to key on both `tagSchema` and `tagUi` references for correct cache invalidation
- [x] 4.3 Add a private `resolveTagUiMetadata(tagUi: TagUi)` method that maps `tag_ui.tags[]` directly to labelsByType, colorsByType, kindsByType maps (no categories/tags normalization needed)

## 5. Angular DocShellComponent

- [x] 5.1 Update `buildMenuConfig()` in `doc-shell.component.ts` to prefer `tagConfig.tag_ui?.tags` when present and non-empty, falling back to `tag_schema` via the existing `resolveSchemaTags()` path
- [x] 5.2 Update the null-check error message to reflect that either `tag_ui` or `tag_schema` must be present

## 6. Testing

- [x] 6.1 Add or update unit tests for `TaggingService` to verify `tag_ui`-first resolution and `tag_schema` fallback
- [x] 6.2 Add or update unit tests for `DocShellComponent.buildMenuConfig()` to verify `tag_ui`-first context menu and `tag_schema` fallback
- [x] 6.3 Verify existing NestJS unit tests for `TaggingTagConfigsService` and `TaggingTagConfigsController` still pass with the new entity field (run `npm run test -- src/tagging`)
