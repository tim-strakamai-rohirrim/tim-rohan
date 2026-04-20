# PRCR-1157 API Contracts

> **Status**: FINAL

---

## Endpoint

```
GET /compliance/projects/:projectId/responses/:responseId/checks
```

### Authentication & Authorization

- **Guards**: `AuthGuard('jwt')` + `PermissionsGuard`
- **Required permission**: `compliance`
- **Ownership check**: The authenticated user must own the project. The service validates this by fetching the response scoped to `{ responseId, projectId }` and then calling `ensureProjectOwnership`.

---

## Path Parameters

| Parameter | Type | Validation | Description |
|-----------|------|-----------|-------------|
| `projectId` | UUID string | `ParseUUIDPipe` | UUID of the compliance project |
| `responseId` | UUID string | `ParseUUIDPipe` | UUID of the compliance response |

---

## Request Body

None.

---

## Success Response

**HTTP 200 OK** — array (may be empty if no checks exist yet)

```json
[
  {
    "id": "uuid",
    "automatedStatus": "pass | fail | null",
    "userDetermination": "compliant | non_compliant | not_applicable | null",
    "userNotes": "string | null",
    "reviewer": {
      "id": "uuid",
      "email": "user@example.com"
    },
    "reviewedAt": "2026-01-01T00:00:00.000Z | null",
    "createdAt": "2026-01-01T00:00:00.000Z",
    "updatedAt": "2026-01-01T00:00:00.000Z",
    "complianceItem": {
      "id": "uuid",
      "complianceItemTitle": "string",
      "complianceItemText": "string",
      "lineItemNumber": 1,
      "outlineNumber": "1.2.3 | null",
      "sectionName": "Section A | null",
      "status": "pending_review | approved | rejected"
    }
  }
]
```

`reviewer` is `null` when no human review has been performed yet.

> Evidence is excluded from this endpoint — it will be served by a dedicated evidence endpoint in a future ticket.

---

## TypeScript DTOs

**File**: `rohan_api-parent/rohan_api/src/compliance/dto/compliance-check-response.dto.ts` *(new)*

```typescript
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { AutomatedStatus, UserDetermination, ComplianceItemStatus } from '../compliance.constants';
import { ComplianceUserRefDto } from './compliance-project-response.dto';

export class ComplianceCheckItemRefDto {
  @ApiProperty({ description: 'Compliance item UUID' })
  id: string;

  @ApiProperty({ description: 'Compliance item title' })
  complianceItemTitle: string;

  @ApiProperty({ description: 'Compliance item full text' })
  complianceItemText: string;

  @ApiPropertyOptional({ description: 'Line item number' })
  lineItemNumber: number | null;

  @ApiPropertyOptional({ description: 'Outline number (e.g. 1.2.3)' })
  outlineNumber: string | null;

  @ApiPropertyOptional({ description: 'Section name' })
  sectionName: string | null;

  @ApiProperty({ enum: ComplianceItemStatus, description: 'Item review status' })
  status: ComplianceItemStatus;
}

export class ComplianceCheckResponseDto {
  @ApiProperty({ description: 'Compliance check UUID' })
  id: string;

  @ApiPropertyOptional({ enum: AutomatedStatus, description: 'Automated pass/fail result; null if not yet run' })
  automatedStatus: AutomatedStatus | null;

  @ApiPropertyOptional({ enum: UserDetermination, description: 'Human reviewer determination; null if not yet reviewed' })
  userDetermination: UserDetermination | null;

  @ApiPropertyOptional({ description: 'Reviewer notes' })
  userNotes: string | null;

  @ApiPropertyOptional({ type: () => ComplianceUserRefDto, description: 'User who reviewed; null if not yet reviewed' })
  reviewer: ComplianceUserRefDto | null;

  @ApiPropertyOptional({ description: 'When the review was performed' })
  reviewedAt: Date | null;

  @ApiProperty({ description: 'Created at' })
  createdAt: Date;

  @ApiProperty({ description: 'Updated at' })
  updatedAt: Date;

  @ApiProperty({ type: () => ComplianceCheckItemRefDto })
  complianceItem: ComplianceCheckItemRefDto;
}
```

---

## Error Responses

| HTTP Status | Condition | Source |
|-------------|-----------|--------|
| 401 Unauthorized | Missing or invalid JWT | `AuthGuard('jwt')` |
| 403 Forbidden | User lacks `compliance` permission | `PermissionsGuard` |
| 404 Not Found | `responseId` not found, `projectId` mismatch, or user does not own the project | `ResponseNotFoundError` |
| 500 Internal Server Error | Unexpected DB or service error | `ComplianceError` |

---

## Enum Reference

```
AutomatedStatus:      pass | fail
UserDetermination:    compliant | non_compliant | not_applicable
ComplianceItemStatus: pending_review | approved | rejected
```

---

## TypeORM Relations Required

`complianceCheckRepository.find` must eager-load:
- `complianceItem`
- `reviewer`

> `evidence` and `evidence.responseDocument` are **not** loaded here — evidence is served by a separate endpoint.

---

## No Schema Changes

`compliance_checks` already contains all required data for this endpoint.
