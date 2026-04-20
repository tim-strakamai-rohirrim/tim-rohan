#### Summary

- Enables automatic conversion of template sections to procurement sections when creating procurements from published templates, so the procurement writer can use a consistent section/question structure regardless of template source.
- Adds a dedicated conversion method in the template-generator service that maps hierarchical template sections (headers + children) to `Section[]` with `Question[]`, including UUID generation and field mapping.
- Wires conversion into procurement creation: when `POST /procurement-writer` receives template-format sections and a `template_id`, the backend detects them, fetches the latest template from the DB, converts sections, and persists in procurement format.

#### Technical Details

- **Frontend:** N/A (this PR is backend-only).

- **Backend:**
  - **Template generator** (`template-generator.service.ts`): New public method `convertTemplateSectionsToProcurementSections()` (from ~line 1141). Takes flat template sections (with `parent_section_id` / `template_section_id`), groups children by parent, builds `Section` objects with `questions` array. Maps `section_indicator` → `field`, `instructions_text`, `field_prompt`, `helper_text`; sets `answer_text: null`; generates `question_id` via `crypto.randomUUID()`. Preserves order via `sort_order`. Handles empty input, headers without children, and null/empty fields.
  - **Procurement writer** (`procurement-writer.service.ts`): New private helpers `isTemplateSectionFormat(section)` (detects `template_section_id` or `parent_section_id`) and `convertSectionsIfNeeded(procurement)` (validates `template_id`, fetches template via `templateGeneratorService.findOne()`, converts sections, maps to `SectionDto`). `create()` calls `convertSectionsIfNeeded()` before saving; on conversion failure, falls back to original sections and logs a warning. Skips conversion when sections already have `questions` or when `template_id` is missing.
  - **Module** (`procurement-writer.module.ts`): Imports `TemplateGeneratorModule` so `ProcurementWriterService` can inject `TemplateGeneratorService`.
  - **DTOs/types** (`template-generator/dto/converted-section.types.ts`): Exports `Question` interface used by the conversion result (no API surface change).

- **Database:** No schema or migrations. Uses existing `procurement_templates` and `procurement_template_sections`; conversion runs in-memory before persisting procurement sections/questions.

- **Contracts:**
  - No new endpoints. `GET /procurement-templates/:id` and `POST /procurement-writer` unchanged from the client’s perspective.
  - Request/response shapes unchanged: frontend still sends template-format sections in the create payload; backend converts before save. Other services do not need changes.

#### Testing

- **Manual:**
  - TODO: Create a procurement via `POST /procurement-writer` with `template_id` and template-format sections, then confirm stored sections have `questions` and correct field mapping.
- **Automated:**
  - **[Karma/Jasmine]:** N/A (backend).
  - **[Playwright]:** N/A (backend).
  - **[Jest]:**
    - `template-generator.service.spec.ts`: New `describe('convertTemplateSectionsToProcurementSections')` — converts headers + children, headers without children, empty array, sort order, null/empty `helper_text`/`field_prompt`, UUID uniqueness, and field mapping.
    - `procurement-writer.service.spec.ts`: New tests for `isTemplateSectionFormat()` (template vs procurement indicators) and `convertSectionsIfNeeded()` — conversion when `template_id` + template format; fetch from DB and call conversion; skip when already procurement format or no `template_id`; invalid/non-numeric `template_id`; template not found; template with no/null sections; empty/null sections; conversion error fallback. Total 12 tests for conversion flow, 5 for the template-generator conversion method.
- **Known gaps / TODO:**
  - Integration test that runs `create()` with template conversion and asserts DB state (transaction/save path).
  - Performance test for very large section sets (e.g. 500+ sections) if needed later.

#### Risks & Impact

- **Breaking changes:** None. Conversion is opt-in (triggered by `template_id` + template-format sections). Existing procurements and non-template creates unchanged.
- **Performance:** One extra `findOne()` on templates per template-based procurement create. In-memory conversion cost is small for typical template sizes.
- **Failure mode:** If conversion or template fetch fails, creation still succeeds with original sections and a warning log; frontend may see sections in template shape in that edge case.
- **Migration/rollout:** None required.

#### Verification Steps for Reviewers

1. Open `template-generator.service.ts` and review `convertTemplateSectionsToProcurementSections()` (from ~line 1141): confirm header/child grouping, field mapping, and edge handling.
2. Open `procurement-writer.service.ts`: review `isTemplateSectionFormat()` (from ~line 173), `convertSectionsIfNeeded()` (from ~line 185), and where `create()` calls it (~line 297); confirm fallback and logging.
3. Confirm `procurement-writer.module.ts` imports `TemplateGeneratorModule` and that `TemplateGeneratorService` is injected in `ProcurementWriterService`.
4. Run `npm test -- template-generator.service.spec.ts` and `npm test -- procurement-writer.service.spec.ts` in `rohan_api`; all conversion-related tests should pass.
5. (Optional) Call `POST /procurement-writer` with a valid `template_id` and template-format `sections`, then inspect the created procurement’s sections in the DB to confirm `questions` and mapping.
