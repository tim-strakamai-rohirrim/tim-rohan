# PRCR-1689 — AP External Integrations — Contracts

> **Ticket:** [PRCR-1689](https://rohirrim.atlassian.net/browse/PRCR-1689), under the PE / Pathway Engines epic [PRCR-1633](https://rohirrim.atlassian.net/browse/PRCR-1633). Plan: `PRCR-1689-PLAN.md`.

REST resource, DTOs, DB schema, and frontend types for the "add an integration to an external source" feature (SAM.gov, FPDS, USASpending, …). All shapes are **snake_case** to match the existing AP module DTOs/entities.

## Contract → Phase mapping

| Contract Section | Phase(s) | Notes |
|------------------|----------|-------|
| 4.1 `acquisition_integrations` table | 1 | Database repo SQL |
| 5.1 `ExternalIntegration` entity | 2 | TypeORM entity + module-slug consts |
| 5.2 pgcrypto secret encryption | 2 | encrypt-on-write, reuses `requireCipherPassword()` |
| 2.1 `GET /integrations` | 2 | list, `?module=` filter |
| 2.2 `POST /integrations` | 2 | connect |
| 2.3 `PATCH /integrations/:id` | 2 | edit metadata / rotate secret / change modules |
| 2.4 `DELETE /integrations/:id` | 2 | disconnect (soft delete — archive + clear secret) |
| 3.1 `IntegrationDto` (response) | 2 | never carries the secret |
| 3.2 `ConnectIntegrationDto` (request) | 2 | |
| 3.3 `UpdateIntegrationDto` (request) | 2 | |
| 3.4 `ListIntegrationsQueryDto` | 2 | |
| 7. Error responses | 2 | literal strings for agent matching |
| 6.1 FE DTO types + mapper | 3 | `IntegrationDto` ↔ `ExternalSource` view model |
| 6.2 `KNOWN_PROVIDERS` catalog | 3 | static; replaces the mock seed |
| 6.3 `ApIntegrationsApiService` | 3 | `RequestService` client |

---

## 1. Terminology & scope

- **Integration** = an org-level connection to an external data source. Admin-managed, shared by all users in the org. Rows are **soft-deleted**: disconnecting sets `archived = true` and clears the stored secret; the row (with its `records_ingested` / `last_synced_at` history) is retained. `status` is derived: `archived = false` ⇒ connected, `archived = true` ⇒ disconnected.
- **Known provider** = an entry in the static frontend `KNOWN_PROVIDERS` catalog (SAM.gov, FPDS, …). The panel's "Disconnected" list = the org's **archived** rows plus catalog providers never connected. Connecting a known provider or a **custom** one (`provider: 'custom'`, user-typed name+URL) creates a row; **reconnecting** a disconnected source goes through `POST /connect` again with fresh credentials, which **revives** the archived row (same `integration_id`) instead of inserting a duplicate.
- **Out of scope this ticket:** record ingestion / sync — that work is a **separate, subsequent plan**. `records_ingested` and `last_synced_at` are display-only fields the ingestion plan will populate; here they persist as `0` / `null`. The stored secret is **written but never read back** in this ticket (decryption belongs to the ingestion plan).

### 1.1 Module slugs

```ts
// Persisted in acquisition_integrations.modules (jsonb string array)
export type AppModuleSlug =
  | 'pathway-engine'
  | 'proposal-engine'
  | 'answer-engine'
  | 'writers-workspace';

export const APP_MODULE_SLUGS: readonly AppModuleSlug[] = [
  'pathway-engine',
  'proposal-engine',
  'answer-engine',
  'writers-workspace',
] as const;
```

Frontend label ↔ slug map (display only; the existing `ExternalSource.modules` uses the labels):

| Slug | Label (`AppModule`) |
|------|---------------------|
| `pathway-engine` | `Pathway Engine` |
| `proposal-engine` | `Proposal Engine` |
| `answer-engine` | `Answer Engine` |
| `writers-workspace` | `Writers Workspace` |

Only `pathway-engine` is user-selectable today; the others render disabled ("coming soon") in the dialog, matching the prototype.

---

## 2. Endpoints

Base path: `/acquisition-pathways/integrations`
Guards (all routes): `AuthGuard('jwt')`, `FeatureGuard` (`@Features('AcquisitionPathways')`), `PermissionsGuard` (`@Permissions('acquisition-pathways')`). Org scope is taken from `req.user.org_id`; the client never supplies `org_id`.

### 2.1 `GET /acquisition-pathways/integrations`

List the caller's org integrations — **both active and archived** (the FE needs archived rows for its "Disconnected" cards; it splits on `archived`).

Query params: `module?` (one of `AppModuleSlug`) — when present, returns only integrations whose `modules` array contains it.

`200 OK`
```json
{
  "count": 2,
  "integrations": [
    {
      "integration_id": 12,
      "provider": "sam_gov",
      "name": "SAM.gov",
      "base_url": "https://sam.gov",
      "auth_method": "password",
      "username": "siddhi@rohirrim.ai",
      "modules": ["pathway-engine", "proposal-engine"],
      "archived": false,
      "records_ingested": 0,
      "last_synced_at": null,
      "created_on": "2026-07-14T12:00:00.000Z",
      "updated_on": "2026-07-14T12:00:00.000Z"
    }
  ]
}
```

### 2.2 `POST /acquisition-pathways/integrations`

Connect a new source. The plaintext `secret` travels over TLS and is encrypted at rest immediately (see 5.2); it is never echoed back.

**Revive semantics:** if the org already has an **archived** row with the same `name`, the connect revives it — same `integration_id`, new secret/metadata/modules, `archived = false`, history (`records_ingested`, `last_synced_at`) preserved. A `409` is returned only when an **active** row holds the name.

Request body → `ConnectIntegrationDto` (§3.2)
```json
{
  "provider": "fpds",
  "name": "FPDS",
  "base_url": "https://fpds.gov",
  "auth_method": "apikey",
  "username": null,
  "secret": "sk_live_…",
  "modules": ["pathway-engine"]
}
```

`201 Created` → `IntegrationDto` (§3.1).

### 2.3 `PATCH /acquisition-pathways/integrations/:id`

Edit metadata (`name`, `base_url`, `username`, `modules`) and/or rotate the secret. All fields optional; the secret is re-encrypted **only** when `secret` is present (metadata-only edits leave it untouched — this is the prototype's "save without re-entering the password" behavior). `provider` and `auth_method` are immutable — to change them, disconnect and reconnect.

Request body → `UpdateIntegrationDto` (§3.3). `200 OK` → `IntegrationDto`.

Scoped to **active** rows: an archived `:id` returns `404` (the FE reconnect path is `POST /connect`, never PATCH).

### 2.4 `DELETE /acquisition-pathways/integrations/:id`

Disconnect. **Soft delete**: sets `archived = true`, clears `secret_ciphertext` (credentials of a disconnected integration are not retained — reconnect requires re-entering them, matching the prototype's Reconnect flow), and keeps `records_ingested` / `last_synced_at` history. `204 No Content`. An already-archived or unknown `:id` returns `404`.

---

## 3. DTOs (backend, NestJS)

### 3.1 `IntegrationDto` — response

`src/acquisition-pathways/dto/integrations/integration.dto.ts`

```ts
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import {
  APP_MODULE_SLUGS,
  AppModuleSlug,
  INTEGRATION_AUTH_METHODS,
  IntegrationAuthMethod,
} from 'src/acquisition-pathways/entities/external-integration.entity';

export class IntegrationDto {
  @ApiProperty()
  integration_id: number;

  @ApiProperty({ description: "Provider slug, e.g. 'sam_gov', or 'custom'." })
  provider: string;

  @ApiProperty()
  name: string;

  @ApiProperty()
  base_url: string;

  @ApiProperty({ enum: INTEGRATION_AUTH_METHODS })
  auth_method: IntegrationAuthMethod;

  @ApiPropertyOptional({ nullable: true, maxLength: 256 })
  username: string | null;

  @ApiProperty({ enum: APP_MODULE_SLUGS, isArray: true })
  modules: AppModuleSlug[];

  @ApiProperty({
    description: 'Soft-delete flag: true = disconnected (secret cleared, history kept).',
  })
  archived: boolean;

  @ApiProperty({ description: 'Display-only; populated by the future ingestion plan.' })
  records_ingested: number;

  @ApiPropertyOptional({ nullable: true, description: 'Display-only; ISO 8601.' })
  last_synced_at: string | null;

  @ApiProperty()
  created_on: Date;

  @ApiProperty()
  updated_on: Date;
  // NOTE: the encrypted secret is intentionally absent — never serialized out.
}

export class IntegrationListResponseDto {
  @ApiProperty()
  count: number;

  @ApiProperty({ type: [IntegrationDto] })
  integrations: IntegrationDto[];
}
```

### 3.2 `ConnectIntegrationDto` — request

`src/acquisition-pathways/dto/integrations/connect-integration.dto.ts`

```ts
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import {
  ArrayMinSize,
  IsArray,
  IsIn,
  IsOptional,
  IsString,
  IsUrl,
  MaxLength,
  MinLength,
  ValidateIf,
} from 'class-validator';
import {
  APP_MODULE_SLUGS,
  AppModuleSlug,
  INTEGRATION_AUTH_METHODS,
  IntegrationAuthMethod,
} from 'src/acquisition-pathways/entities/external-integration.entity';

export class ConnectIntegrationDto {
  @ApiProperty({ description: "Provider slug, e.g. 'sam_gov', or 'custom'." })
  @IsString()
  @MinLength(1)
  @MaxLength(64)
  provider: string;

  @ApiProperty()
  @IsString()
  @MinLength(1)
  @MaxLength(256)
  name: string;

  @ApiProperty()
  @IsUrl({ require_tld: false })
  @MaxLength(2048)
  base_url: string;

  @ApiProperty({ enum: INTEGRATION_AUTH_METHODS })
  @IsIn(INTEGRATION_AUTH_METHODS)
  auth_method: IntegrationAuthMethod;

  // Required for password auth, ignored/optional for apikey auth.
  @ApiPropertyOptional({ nullable: true, maxLength: 256 })
  @ValidateIf((o) => o.auth_method === 'password')
  @IsString()
  @MinLength(1)
  @MaxLength(256)
  username?: string | null;

  @ApiProperty({ description: 'Plaintext password or API key (TLS in transit; encrypted at rest).' })
  @IsString()
  @MinLength(1)
  @MaxLength(4096)
  secret: string;

  @ApiProperty({ enum: APP_MODULE_SLUGS, isArray: true })
  @IsArray()
  @ArrayMinSize(1)
  @IsIn(APP_MODULE_SLUGS, { each: true })
  modules: AppModuleSlug[];
}
```

### 3.3 `UpdateIntegrationDto` — request

`src/acquisition-pathways/dto/integrations/update-integration.dto.ts`

```ts
import { ApiPropertyOptional } from '@nestjs/swagger';
import {
  ArrayMinSize,
  IsArray,
  IsIn,
  IsOptional,
  IsString,
  IsUrl,
  MaxLength,
  MinLength,
} from 'class-validator';
import {
  APP_MODULE_SLUGS,
  AppModuleSlug,
} from 'src/acquisition-pathways/entities/external-integration.entity';

// provider + auth_method are immutable — not present here (disconnect + reconnect to change).
export class UpdateIntegrationDto {
  @ApiPropertyOptional({ maxLength: 256 })
  @IsOptional()
  @IsString()
  @MinLength(1)
  @MaxLength(256)
  name?: string;

  @ApiPropertyOptional({ maxLength: 2048 })
  @IsOptional()
  @IsUrl({ require_tld: false })
  @MaxLength(2048)
  base_url?: string;

  @ApiPropertyOptional({ nullable: true, maxLength: 256 })
  @IsOptional()
  @IsString()
  @MaxLength(256)
  username?: string | null;

  // Present ⇒ rotate + re-encrypt. Absent ⇒ leave the stored secret untouched.
  @ApiPropertyOptional({ maxLength: 4096 })
  @IsOptional()
  @IsString()
  @MinLength(1)
  @MaxLength(4096)
  secret?: string;

  @ApiPropertyOptional({ enum: APP_MODULE_SLUGS, isArray: true })
  @IsOptional()
  @IsArray()
  @ArrayMinSize(1)
  @IsIn(APP_MODULE_SLUGS, { each: true })
  modules?: AppModuleSlug[];
}
```

### 3.4 `ListIntegrationsQueryDto`

`src/acquisition-pathways/dto/integrations/list-integrations-query.dto.ts`

```ts
import { ApiPropertyOptional } from '@nestjs/swagger';
import { IsIn, IsOptional } from 'class-validator';
import {
  APP_MODULE_SLUGS,
  AppModuleSlug,
} from 'src/acquisition-pathways/entities/external-integration.entity';

export class ListIntegrationsQueryDto {
  @ApiPropertyOptional({ enum: APP_MODULE_SLUGS })
  @IsOptional()
  @IsIn(APP_MODULE_SLUGS)
  module?: AppModuleSlug;
}
```

---

## 4. Database schema

### 4.1 `acquisition_integrations` table

`Database/rohan_api/scripts/sql/init_acquisition_integrations.sql` — idempotent, registered in `run_all.sql` after `init_acquisition_missions.sql`. This script does **not** re-declare pgcrypto: the table's `secret_ciphertext` is plain `text` and encryption happens at app runtime (§5.2), so pgcrypto need not exist when the migration runs. `init_connectors.sql` (which owns `CREATE EXTENSION pgcrypto`) runs later in `run_all.sql`, and the extension is available to the app by the time any request arrives.

```sql
-- Acquisition Pathways — org-level external data integrations (SAM.gov, FPDS, …).
-- Idempotent. Safe to re-run on every container boot via run_all.sql.
-- Secrets are stored encrypted (pgcrypto pgp_sym_encrypt, base64) in
-- secret_ciphertext; the app encrypts on write and never selects it back in
-- the connect/manage flow (decryption belongs to the future ingestion plan).
-- Soft delete: disconnect sets archived = true and NULLs secret_ciphertext
-- (credentials of a disconnected integration are not retained); the row and
-- its ingestion history survive. Nullable secret_ciphertext ⇔ archived rows.
-- Reuses the global trigger_set_timestamp() from init_procurements.sql.

CREATE TABLE IF NOT EXISTS acquisition_integrations (
  integration_id    SERIAL PRIMARY KEY,
  org_id            varchar(128) NOT NULL,
  created_by        varchar(128) NOT NULL,
  provider          varchar(64)  NOT NULL,
  name              varchar(256) NOT NULL,
  base_url          text         NOT NULL,
  auth_method       varchar(16)  NOT NULL,
  username          varchar(256),
  secret_ciphertext text,
  modules           JSONB        NOT NULL DEFAULT '["pathway-engine"]'::jsonb,
  archived          boolean      NOT NULL DEFAULT FALSE,
  records_ingested  integer      NOT NULL DEFAULT 0,
  last_synced_at    TIMESTAMPTZ,
  created_on        TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  updated_on        TIMESTAMPTZ  NOT NULL DEFAULT NOW(),

  CONSTRAINT acquisition_integrations_auth_method_check
    CHECK (auth_method IN ('password', 'apikey')),
  -- One row per (org, name) — active OR archived. Blocks duplicate "SAM.gov"
  -- rows while still allowing distinct custom sources; reconnecting a
  -- disconnected source REVIVES its archived row rather than inserting, so a
  -- full (not partial/archived-filtered) unique constraint is correct here.
  -- Case-sensitive; see Open Question 3 for the case-insensitive variant.
  CONSTRAINT acquisition_integrations_org_name_uniq
    UNIQUE (org_id, name)
);

CREATE INDEX IF NOT EXISTS idx_acquisition_integrations_org_id
  ON acquisition_integrations (org_id);

CREATE OR REPLACE TRIGGER set_timestamp
  BEFORE UPDATE ON acquisition_integrations
  FOR EACH ROW
  EXECUTE PROCEDURE trigger_set_timestamp();
```

> **Note on module-slug validation:** `modules` membership is validated in the DTO layer (`@IsIn(APP_MODULE_SLUGS, { each: true })`), not by a DB CHECK — Postgres jsonb-array membership CHECKs are awkward and the enum is small and app-owned. Uniqueness is `(org_id, name)`; if the team prefers case-insensitive, swap to `UNIQUE (org_id, lower(name))` via an expression index (see Open Question 3 in the plan).

---

## 5. TypeORM entity

### 5.1 `ExternalIntegration` entity

`src/acquisition-pathways/entities/external-integration.entity.ts`. SQL defaults are owned by the Database-repo migration (§4.1) and deliberately **not** duplicated in decorators, matching `AcquisitionMission`.

```ts
import {
  Column,
  CreateDateColumn,
  Entity,
  Index,
  PrimaryGeneratedColumn,
  UpdateDateColumn,
} from 'typeorm';

export type IntegrationAuthMethod = 'password' | 'apikey';
export const INTEGRATION_AUTH_METHODS: readonly IntegrationAuthMethod[] = [
  'password',
  'apikey',
] as const;

export type AppModuleSlug =
  | 'pathway-engine'
  | 'proposal-engine'
  | 'answer-engine'
  | 'writers-workspace';
export const APP_MODULE_SLUGS: readonly AppModuleSlug[] = [
  'pathway-engine',
  'proposal-engine',
  'answer-engine',
  'writers-workspace',
] as const;

@Entity('acquisition_integrations')
@Index('idx_acquisition_integrations_org_id', ['org_id'])
export class ExternalIntegration {
  @PrimaryGeneratedColumn()
  integration_id: number;

  @Column({ type: 'varchar', length: 128 })
  org_id: string;

  @Column({ type: 'varchar', length: 128 })
  created_by: string;

  @Column({ type: 'varchar', length: 64 })
  provider: string;

  @Column({ type: 'varchar', length: 256 })
  name: string;

  @Column({ type: 'text' })
  base_url: string;

  @Column({ type: 'varchar', length: 16 })
  auth_method: IntegrationAuthMethod;

  @Column({ type: 'varchar', length: 256, nullable: true })
  username: string | null;

  // Encrypted at rest (pgcrypto). Never mapped into IntegrationDto.
  // Null ⇔ archived (disconnect clears the stored credential).
  @Column({ type: 'text', nullable: true })
  secret_ciphertext: string | null;

  @Column({ type: 'jsonb' })
  modules: AppModuleSlug[];

  // Soft-delete flag: true = disconnected. Secret is cleared on archive;
  // records_ingested / last_synced_at history is kept.
  @Column({ type: 'boolean' })
  archived: boolean;

  @Column({ type: 'integer' })
  records_ingested: number;

  @Column({ type: 'timestamptz', nullable: true })
  last_synced_at: Date | null;

  @CreateDateColumn({ type: 'timestamptz' })
  created_on: Date;

  @UpdateDateColumn({ type: 'timestamptz' })
  updated_on: Date;
}
```

### 5.2 Secret encryption (service-level)

Follow the pattern already in `src/connectors/connectors.service.ts` — pgcrypto via a raw query, keyed by `requireCipherPassword()` (fail-closed when neither `CIPHER_PASSWORD` nor Key Vault is configured). **Encrypt-on-write only** in this ticket. Note the connectors implementation runs the query via `entityManager.query(...)` and aliases the column `as encode` (`result[0].encode`); the snippet below uses an injected `DataSource` and `as ciphertext` — functionally identical, pick either (inject `DataSource` or reuse the repository's `EntityManager`):

```ts
// inside ApIntegrationsService — reuses src/utils/crypto/cipher-password.ts
private async encryptSecret(plaintext: string): Promise<string> {
  const password = requireCipherPassword();
  const rows = await this.dataSource.query(
    `select encode(pgp_sym_encrypt($1, $2), 'base64') as ciphertext;`,
    [plaintext, password],
  );
  return rows[0].ciphertext;
}
```

> `pgp_sym_decrypt` is **not** used in this ticket — no endpoint returns the secret. Decryption is a future-ingestion concern. `ponytail:` this 2-line encrypt block is duplicated from `connectors.service` / `onering-onboarding.service`; extract a shared `PgSymCipher` util if a fourth consumer appears (tracked as a follow-up, not this ticket).

---

## 6. Frontend types & client (rohan_ui)

### 6.1 DTO types + mapper

`src/app/pages/acquisition-pathways/types/acquisition-pathways.types.ts` (extend). The existing `ExternalSource` / `AppModule` (label) view model stays as the panel's render shape; add the wire DTO + a mapper.

```ts
// Wire shape — mirrors backend IntegrationDto (snake_case).
export interface IntegrationDto {
  integration_id: number;
  provider: string;
  name: string;
  base_url: string;
  auth_method: 'password' | 'apikey';
  username: string | null;
  modules: AppModuleSlug[];
  archived: boolean;
  records_ingested: number;
  last_synced_at: string | null;
  created_on: string;
  updated_on: string;
}

export type AppModuleSlug =
  | 'pathway-engine'
  | 'proposal-engine'
  | 'answer-engine'
  | 'writers-workspace';

export interface ConnectIntegrationRequest {
  provider: string;
  name: string;
  base_url: string;
  auth_method: 'password' | 'apikey';
  username?: string | null;
  secret: string;
  modules: AppModuleSlug[];
}

export interface UpdateIntegrationRequest {
  name?: string;
  base_url?: string;
  username?: string | null;
  secret?: string;
  modules?: AppModuleSlug[];
}

// dto → ExternalSource view model. Field names differ from the wire DTO — the
// mapper bridges them:
//   integration_id  → key       (String(dto.integration_id))
//   records_ingested → count
//   last_synced_at  → lastSynced (nullable; passed through / formatted)
//   modules (slugs) → modules    (labels, via moduleSlugToLabel)
//   archived        → status     (false → 'connected', true → 'available')
// logo/desc fall back to the KNOWN_PROVIDERS catalog entry when the provider is
// known (custom → logo = first 2 chars of name, uppercased).
export function toExternalSource(dto: IntegrationDto): ExternalSource;
```

Label ↔ slug helpers (`moduleLabelToSlug`, `moduleSlugToLabel`) live alongside the mapper.

**Dedup identity for the "available" list.** `ExternalSource` has no `provider` field, so the panel can't diff connected rows against `KNOWN_PROVIDERS` by provider slug directly. Add a `provider: string` field to `ExternalSource` and have `toExternalSource` populate it from `dto.provider`; the never-connected part of the available list is then `KNOWN_PROVIDERS` whose `provider` appears in no org row (active or archived). (Alternative if we don't want to touch the view model: dedup by `url`, which both `ExternalSource` and `KnownProvider` already carry — pick one and keep it consistent with §6.2.)

### 6.2 `KNOWN_PROVIDERS` catalog

`src/app/pages/acquisition-pathways/constants/known-providers.ts` (new). Static; replaces the in-memory `EXTERNAL_SOURCES` seed currently in `acquisition-pathways.service.ts`. Six entries (SAM.gov, FPDS, USASpending, GSA eBuy, Grants.gov, SpaceWERX) come from that seed; **BidNet Direct** and **DemandStar** are net-new additions, not present in the prototype.

```ts
export interface KnownProvider {
  provider: string;   // slug, e.g. 'sam_gov'
  name: string;       // 'SAM.gov'
  logo: string;       // 'SAM'
  desc: string;       // 'Federal procurement opportunities'
  url: string;        // 'https://sam.gov'
}

export const KNOWN_PROVIDERS: readonly KnownProvider[] = [
  { provider: 'sam_gov', name: 'SAM.gov', logo: 'SAM', desc: 'Federal procurement opportunities', url: 'https://sam.gov' },
  { provider: 'fpds', name: 'FPDS', logo: 'FP', desc: 'Federal Procurement Data System', url: 'https://fpds.gov' },
  { provider: 'usaspending', name: 'USASpending.gov', logo: 'US', desc: 'Federal contract awards & spend', url: 'https://usaspending.gov' },
  { provider: 'gsa_ebuy', name: 'GSA eBuy', logo: 'GS', desc: 'GSA schedule RFQs', url: 'https://ebuy.gsa.gov' },
  { provider: 'grants_gov', name: 'Grants.gov', logo: 'GG', desc: 'Federal grant opportunities', url: 'https://grants.gov' },
  { provider: 'bidnet', name: 'BidNet Direct', logo: 'BN', desc: 'State & local bids', url: 'https://bidnet.com' },
  { provider: 'spacewerx', name: 'SpaceWERX', logo: 'SW', desc: 'Space Force innovation', url: 'https://www.spacewerx.us' },
  { provider: 'demandstar', name: 'DemandStar', logo: 'DS', desc: 'Government bids marketplace', url: 'https://demandstar.com' },
];
```

The panel's **Disconnected / Available** list = the org's **archived** integrations (mapped via `toExternalSource`, so they keep their real names/history) **plus** `KNOWN_PROVIDERS` entries whose `provider` appears in no org row at all (active or archived), filtered to the current module. `provider: 'custom'` is used for user-typed sources (logo = first 2 chars of name, uppercased). Clicking a disconnected card opens the dialog in reconnect mode, which submits via `connectIntegration` (the backend revives the archived row).

### 6.3 `ApIntegrationsApiService`

`src/app/pages/acquisition-pathways/services/ap-integrations-api.service.ts` (new). Mirrors the existing `acquisition-pathways-api.service.ts` — `RequestService` from `@shared-services/request/request.service`, `BASE_PATH = '/acquisition-pathways/integrations'`.

```ts
@Injectable({ providedIn: 'root' })
export class ApIntegrationsApiService {
  private readonly request = inject(RequestService);
  private static readonly BASE = '/acquisition-pathways/integrations';

  listIntegrations(module?: AppModuleSlug): Observable<IntegrationListResponse>;
  connectIntegration(body: ConnectIntegrationRequest): Observable<IntegrationDto>;
  updateIntegration(id: number, body: UpdateIntegrationRequest): Observable<IntegrationDto>;
  disconnectIntegration(id: number): Observable<void>;
}

export interface IntegrationListResponse {
  count: number;
  integrations: IntegrationDto[];
}
```

---

## 7. Error responses

Literal messages (agents match against these). Errors surface via the existing `ApExceptionFilter` / `AcquisitionPathwaysErrors` constants pattern — add these keys to `src/acquisition-pathways/ap.constants.ts`.

| Endpoint | Status | Condition | Message |
|----------|--------|-----------|---------|
| all | `401 Unauthorized` | missing/invalid JWT | (guard default) |
| all | `403 Forbidden` | lacks `acquisition-pathways` permission or `AcquisitionPathways` flag | `Caller lacks the acquisition-pathways permission or the AcquisitionPathways feature flag` |
| POST | `400 Bad Request` | body validation failure | (class-validator default) |
| POST | `409 Conflict` | an **active** row already holds `(org_id, name)` (an archived one is revived instead) | `An integration named "{name}" already exists for this organization` |
| PATCH | `400 Bad Request` | body validation failure | (class-validator default) |
| PATCH / DELETE | `404 Not Found` | no **active** integration with `:id` in caller's org (unknown, cross-org, or archived id) | `Acquisition integration {id} not found` |
| PATCH | `409 Conflict` | rename collides with an existing `(org_id, name)` | `An integration named "{name}" already exists for this organization` |
| POST / PATCH | `500 Internal Server Error` | `CIPHER_PASSWORD` unset + Key Vault off (`CipherPasswordMissingError`) | `Failed to persist the external integration` (logged detail: fail-closed cipher) |

`404` scoping is by `(integration_id, org_id)` so one org can never probe another's ids (a cross-org id returns `404`, not `403`).
