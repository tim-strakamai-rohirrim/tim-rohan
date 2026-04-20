# PRCR-697: Template Publishing to Procurement Projects Tiles

## Problem Statement

Users need the ability to publish templates so they become available as tiles in the Procurement Projects area of the Acquisition Center, accessible to all authenticated users. When a template is published, it should appear as a clickable card/tile that allows users to start a new procurement project from that template. When a template is unpublished, it should be removed from the Procurement Projects area with a confirmation step to prevent accidental removal.

Currently:
- Templates can be published/unpublished via the template generator UI
- The Procurement Projects landing page shows hardcoded mock templates
- Published templates are not automatically displayed in Procurement Projects
- No confirmation dialog exists for unpublishing

## Assumptions

1. **Tiles are published templates**: Tiles in Procurement Projects are simply published templates (`status='published'`) displayed as cards. No separate tile entity is needed.
2. **Idempotency**: Re-publishing the same template should update the existing tile (no duplicates) - this is handled by filtering published templates by status.
3. **Template versioning**: The tile always points to the latest published version of the template. If a template has draft edits after publishing, the tile continues to show the published version until re-published.
4. **Permissions**: Template publishing/unpublishing is restricted to Admins (already enforced by backend permissions).
5. **Tile visibility**: All authenticated users can view tiles in Procurement Projects (no additional permission checks needed beyond authentication).
6. **Error handling**: Tile creation failures should be handled gracefully with user-friendly error messages and retry capability.
7. **Audit logging**: Publish/unpublish actions are already logged via audit trail (from previous PR).
8. **Card component compatibility**: Published templates can be converted to `CardData` format for display using existing `app-card` component.

## Open Questions

1. **Tile click behavior**: When a user clicks a published template tile, should it:
   - Navigate to a template preview/details page?
   - Immediately create a new procurement project from the template (current behavior for mock templates)?
   - **Decision needed**: Yes, immediate procurement creation for now.

2. **Image handling**: Published templates may not have `image_url` set. Should we:
   - Use a default placeholder image?
   - Generate/assign a default image on publish?
   - **Decision needed**: Yes, use default placeholder if `image_url` is null/empty.

3. **Template description**: Some templates may not have descriptions. Should we:
   - Use a default description?
   - Show empty description?
   - **Decision needed**: Yes, show empty description as fallback.

4. **Unpublish confirmation modal styling**: Should the "Unpublish" button be styled as destructive (red)?
   - **Decision**: Yes, use destructive styling (similar to delete modals).

5. **Error retry mechanism**: Should retry be:
   - Automatic with exponential backoff (background job)?
   - Manual user-initiated retry button?
   - **Decision**: Manual retry button for immediate user feedback in initial implementation. Background job retry with exponential backoff (max 3 attempts) is a future enhancement (Phase 2).

6. **Published template ordering**: How should published templates be ordered in the tile list?
   - **Decision**: Order by `published_on` DESC (most recently published first), fallback to `updated_on` DESC.

## Implementation Checklist

### Phase 1: Backend - Publish/Unpublish Enhancement (if needed)

- [x] **[BACKEND_DB]** Verify publish endpoint handles idempotency correctly
  - **File**: `rohan_api/src/template-generator/template-generator.service.ts`
  - **Verification**: Check that `publishTemplate` method already handles re-publishing (returns existing template if already published)
  - **Note**: Current implementation already returns template if status is PUBLISHED (line 936-938), so idempotency is handled

- [x] **[BACKEND_DB]** Verify unpublish endpoint sets status correctly
  - **File**: `rohan_api/src/template-generator/template-generator.service.ts`
  - **Verification**: Confirm `unpublishTemplate` sets status to COMPLETED (line 997-999)
  - **Note**: Current implementation is correct

- [x] **[BACKEND_DB]** Add endpoint to fetch published templates (if not already available)
  - **File**: `rohan_api/src/template-generator/template-generator.controller.ts`
  - **Verification**: Check if `GET /procurement-templates?status=published` already works
  - **Note**: Existing `findAll` method supports status filtering, so this should already work

### Phase 2: Frontend - Fetch Published Templates

- [x] **[FRONTEND]** Update `getTemplateStubs()` to fetch published templates from API
  - **File**: `rohan_ui/src/app/pages/acquisition-center/services/procurement-writer.service.ts`
  - **Change**: Replace `return of(mockTemplateStubs)` with API call to `GET /procurement-templates?status=published`
  - **Transform**: Convert `ProcurementTemplateDto[]` to `TemplatePreview[]` format
  - **Mapping**:
    - `id`: `procurement_template_id.toString()`
    - `name`: `title`
    - `description`: `description || ''` (fallback to empty string)
    - `image`: `image_url || './assets/images/templates/custom-template.png'` (use default placeholder)
    - `procurement_template_id`: `procurement_template_id`
  - **Error handling**: Log error, show toast notification, fallback to empty array
  - **Note**: Implemented - API templates are appended to mock templates (maintains backward compatibility)

- [x] **[FRONTEND]** Add helper method to transform template DTO to TemplatePreview
  - **File**: `rohan_ui/src/app/pages/acquisition-center/services/procurement-writer.service.ts`
  - **Method**: `private transformTemplateToPreview(template: ProcurementTemplateDto): TemplatePreview`
  - **Purpose**: Centralize transformation logic for reusability
  - **Note**: Implemented at line 301

- [x] **[FRONTEND]** Update landing page to handle loading state
  - **File**: `rohan_ui/src/app/pages/acquisition-center/components/procurement-writer-landing-page/procurement-writer-landing-page.component.ts`
  - **Change**: Show spinner while fetching templates, hide when complete
  - **Note**: Spinner already exists (`procure-landing-page`), ensure it's shown during fetch
  - **Note**: Implemented - spinner shows/hides in `getTemplates()` method

### Phase 3: Frontend - Unpublish Confirmation Modal

- [ ] **[FRONTEND]** Add confirmation modal for unpublish action
  - **File**: `rohan_ui/src/app/pages/acquisition-center/components/template-generator/template-generator.component.ts`
  - **Change**: Update `handleTableAction` method to show confirmation modal before unpublishing
  - **Modal configuration**:
    - `mainText`: "Unpublish template?"
    - `secondaryText`: "This will remove the template from Procurement Projects. Existing drafts created from it are unaffected."
    - `button1Text`: "Cancel"
    - `button2Text`: "Unpublish"
    - `isDelete`: `true` (for destructive styling)
  - **Behavior**: Only proceed with unpublish if user confirms (BUTTON_2 clicked)

- [ ] **[FRONTEND]** Inject MatDialog service
  - **File**: `rohan_ui/src/app/pages/acquisition-center/components/template-generator/template-generator.component.ts`
  - **Change**: Add `MatDialog` to constructor dependencies
  - **Import**: `import { MatDialog } from '@angular/material/dialog';`
  - **Import**: `import { GenericModalComponent } from '@shared-components/generic-modal/generic-modal.component';`
  - **Import**: `import { GenericModalData } from '@shared-types/modals/generic-modal.types';`

- [ ] **[FRONTEND]** Extract unpublish logic to separate method
  - **File**: `rohan_ui/src/app/pages/acquisition-center/components/template-generator/template-generator.component.ts`
  - **Method**: `private unpublishTemplate(templateId: string): void`
  - **Purpose**: Separate confirmation logic from API call for cleaner code

### Phase 4: Frontend - Error Handling & Retry - not needed at this time

- [ ] **[FRONTEND]** Add error handling for publish action with retry
  - **File**: `rohan_ui/src/app/pages/acquisition-center/components/template-generator/template-generator.component.ts`
  - **Change**: Update publish error handler to show retry button
  - **Error message**: "Tile creation failed. Retry."
  - **Retry button**: Show in toast notification or error banner
  - **Retry logic**: Re-call publish endpoint with same template ID
  - **Note**: Not implemented - only error toast shown, no retry button

- [x] **[FRONTEND]** Add error handling for template fetch failures
  - **File**: `rohan_ui/src/app/pages/acquisition-center/components/procurement-writer-landing-page/procurement-writer-landing-page.component.ts`
  - **Change**: Update `getTemplates()` error handler to show user-friendly message
  - **Fallback**: Show empty state or fallback to mock templates (if available)
  - **Note**: Implemented - error message displayed, fallback to mock templates in service

- [ ] **[FRONTEND]** Add retry mechanism for failed template fetches
  - **File**: `rohan_ui/src/app/pages/acquisition-center/components/procurement-writer-landing-page/procurement-writer-landing-page.component.ts`
  - **Change**: Add retry button in error state
  - **Implementation**: Call `getTemplates()` again on retry click
  - **Note**: Not implemented - error message shown but no retry button

### Phase 5: Frontend - Tile Click Behavior - will be addressed later

- [ ] **[FRONTEND]** Update tile click handler to use published template
  - **File**: `rohan_ui/src/app/pages/acquisition-center/components/procurement-writer-landing-page/procurement-writer-landing-page.component.ts`
  - **Change**: Update `createNewProcurement()` to handle `TemplatePreview` with `procurement_template_id`
  - **Logic**: If `template.procurement_template_id` exists, use it to create procurement from template
  - **API call**: May need to call template-specific procurement creation endpoint
  - **Note**: Verify if `newProcurement()` already handles template IDs or needs update

- [ ] **[FRONTEND]** Verify procurement creation from template works
  - **File**: `rohan_ui/src/app/pages/acquisition-center/services/procurement-writer.service.ts`
  - **Verification**: Check if `newProcurement()` method accepts template ID
  - **Update**: If not, add support for creating procurement from template ID

### Phase 6: Frontend - Template Refresh After Publish/Unpublish - not needed

- [ ] **[FRONTEND]** Refresh template list after successful publish
  - **File**: `rohan_ui/src/app/pages/acquisition-center/components/procurement-writer-landing-page/procurement-writer-landing-page.component.ts`
  - **Change**: Add method to refresh templates (call `getTemplates()`)
  - **Integration**: May need to listen to publish/unpublish events or use a service/observable pattern
  - **Alternative**: Refresh on navigation back to landing page (simpler, less real-time)

- [ ] **[FRONTEND]** Refresh template list after successful unpublish
  - **File**: `rohan_ui/src/app/pages/acquisition-center/components/procurement-writer-landing-page/procurement-writer-landing-page.component.ts`
  - **Change**: Same as above - refresh templates after unpublish

- [ ] **[FRONTEND]** Consider using shared service/observable for template updates
  - **File**: `rohan_ui/src/app/pages/acquisition-center/services/procurement-writer.service.ts`
  - **Change**: Add `BehaviorSubject` or `Subject` to emit template update events
  - **Purpose**: Allow components to subscribe to template changes for real-time updates
  - **Note**: This is optional - can be deferred to Phase 2 if not critical

### Phase 7: Frontend - Default Image Placeholder

- [x] **[FRONTEND]** Create or verify default template image exists
  - **File**: `rohan_ui/src/assets/images/templates/custom-template.png` (or similar)
  - **Action**: Create placeholder image if it doesn't exist, or use existing placeholder
  - **Alternative**: Use inline SVG or CSS-generated placeholder
  - **Note**: Image verified to exist at correct path, path matches existing pattern used throughout codebase

- [x] **[FRONTEND]** Update template transformation to use default image
  - **File**: `rohan_ui/src/app/pages/acquisition-center/services/procurement-writer.service.ts`
  - **Change**: In `transformTemplateToPreview()`, use default image path when `image_url` is null/empty
  - **Note**: Implemented - fallback to `'./assets/images/templates/custom-template.png'` at line 306

### Phase 8: Testing

- [x] **[TEST_REVIEW]** Add unit tests for template transformation
  - **File**: `rohan_ui/src/app/pages/acquisition-center/services/procurement-writer.service.spec.ts`
  - **Tests**: 
    - Transform template with all fields
    - Transform template with missing description
    - Transform template with missing image_url
    - Transform template with null values
  - **Note**: Implemented - tests added in `transformTemplateToPreview` describe block (lines 110-156)

- [ ] **[TEST_REVIEW]** Add unit tests for unpublish confirmation modal
  - **File**: `rohan_ui/src/app/pages/acquisition-center/components/template-generator/template-generator.component.spec.ts`
  - **Tests**:
    - Modal opens when unpublish action triggered
    - Unpublish proceeds when user confirms
    - Unpublish cancelled when user clicks Cancel
    - Unpublish cancelled when modal dismissed
  - **Note**: Not implemented - unpublish confirmation modal not yet added

- [ ] **[TEST_REVIEW]** Add unit tests for error handling and retry
  - **File**: `rohan_ui/src/app/pages/acquisition-center/components/template-generator/template-generator.component.spec.ts`
  - **Tests**:
    - Error toast shown on publish failure
    - Retry button triggers publish again
    - Error toast shown on unpublish failure
  - **Note**: Not implemented - retry mechanism not yet added

- [x] **[TEST_REVIEW]** Add unit tests for template fetching
  - **File**: `rohan_ui/src/app/pages/acquisition-center/components/procurement-writer-landing-page/procurement-writer-landing-page.component.spec.ts`
  - **Tests**:
    - Templates fetched on component init
    - Error handled gracefully on fetch failure
    - Empty state shown when no published templates
    - Templates displayed correctly after fetch
  - **Note**: Implemented - tests added in `getTemplates` describe block (lines 89-161)

- [ ] **[TEST_REVIEW]** Manual E2E testing: Publish template and verify tile appears
  - **Steps**: 
    1. Navigate to template generator as admin
    2. Publish a template
    3. Navigate to Procurement Projects landing page
    4. Verify template tile appears in list
    5. Click tile and verify procurement creation works

- [ ] **[TEST_REVIEW]** Manual E2E testing: Unpublish template with confirmation
  - **Steps**:
    1. Navigate to template generator as admin
    2. Unpublish a published template
    3. Verify confirmation modal appears
    4. Click Cancel and verify template remains published
    5. Unpublish again and click Confirm
    6. Navigate to Procurement Projects and verify tile is removed

- [ ] **[TEST_REVIEW]** Manual E2E testing: Error handling and retry
  - **Steps**:
    1. Simulate network error during publish (dev tools)
    2. Verify error message appears
    3. Click retry and verify publish succeeds
    4. Test same for unpublish

- [ ] **[TEST_REVIEW]** Manual E2E testing: Re-publish idempotency
  - **Steps**:
    1. Publish a template
    2. Verify tile appears
    3. Publish same template again
    4. Verify only one tile exists (no duplicates)

## Notes

- **No database changes required**: Published templates are identified by `status='published'` field, which already exists.
- **No new API endpoints required**: Existing `GET /procurement-templates?status=published` endpoint can be used.
- **Backward compatibility**: Mock templates can be kept as fallback for error cases or removed entirely based on product decision.
- **Performance**: Consider caching published templates if the list is large or fetched frequently.
- **Real-time updates**: Template list refresh can be done on navigation (simpler) or via observables (more complex, better UX).
- **Image handling**: Default placeholder image should match design system and be visually consistent with other template images.
- **Background job retry**: The requirement for "Background job retries failures with backoff (max 3 attempts)" is deferred to a future enhancement. Initial implementation uses manual retry button for immediate user feedback. Background job retry would require:
  - Queue system (e.g., Bull/BullMQ, Redis)
  - Background worker process
  - Retry logic with exponential backoff
  - Failure tracking and notification

## Implementation Conflicts & Dependencies

**Conflicts with PLAN.md (Template Audit Trail)**:

### Backend Conflicts
- **`template-generator.service.ts`**: PLAN.md adds audit logging to `publishTemplate()` and `unpublishTemplate()` methods. PRCR-697 verification steps assume these methods are unchanged.
  - **Resolution**: Implement PLAN.md audit logging first, then update PRCR-697 verification to account for additional audit logging calls.

### Frontend Conflicts
- **`template-generator.component.ts`**: Both plans modify `handleTableAction()` method and constructor dependencies.
  - **PRCR-697**: Adds `MatDialog` for unpublish confirmation modal
  - **PLAN.md**: Adds `AuditTrailService` for audit log navigation and may add `Router` for navigation
  - **Resolution**: Combine constructor injections and update `handleTableAction()` to handle both 'unpublish' and 'view audit log' actions.

### Implementation Order Recommendation
1. **Implement PLAN.md first** (audit trail) - establishes logging infrastructure
2. **Then implement PRCR-697** - builds publish/unpublish UI on top of logged operations
3. **Test both features together** - verify audit logging works for publish/unpublish actions

### Testing Considerations
- **Integration testing**: Verify that publish/unpublish actions create appropriate audit log entries
- **UI testing**: Test that both "unpublish" and "view audit log" actions work in table action dropdown
- **End-to-end testing**: Verify complete publish→tile creation→unpublish→tile removal flow includes proper audit logging

## Reference Files

### Backend
- Template service: `rohan_api/src/template-generator/template-generator.service.ts`
- Template controller: `rohan_api/src/template-generator/template-generator.controller.ts`
- Template entity: `rohan_api/src/template-generator/entities/procurement-template.entity.ts`
- Template DTO: `rohan_api/src/template-generator/dto/template.dto.ts`

### Frontend
- Procurement writer service: `rohan_ui/src/app/pages/acquisition-center/services/procurement-writer.service.ts`
- Landing page component: `rohan_ui/src/app/pages/acquisition-center/components/procurement-writer-landing-page/procurement-writer-landing-page.component.ts`
- Template generator component: `rohan_ui/src/app/pages/acquisition-center/components/template-generator/template-generator.component.ts`
- Card component: `rohan_ui/src/app/shared-components/card/card.component.ts`
- Generic modal component: `rohan_ui/src/app/shared-components/generic-modal/generic-modal.component.ts`
- Types: `rohan_ui/src/app/pages/acquisition-center/types/procurement-writer.types.ts`
- Card types: `rohan_ui/src/app/shared-types/card.types.ts`
