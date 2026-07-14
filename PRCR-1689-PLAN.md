# PRCR-1689 — AP External Integrations — Implementation Plan

> **Ticket:** [PRCR-1689](https://rohirrim.atlassian.net/browse/PRCR-1689), under the PE / Pathway Engines epic [PRCR-1633](https://rohirrim.atlassian.net/browse/PRCR-1633). Contracts: `PRCR-1689-contracts.md`.

## Problem statement

The Acquisition Pathways (Pathway Engine) admin panel lets a user "add an integration to an external source" — SAM.gov, FPDS, USASpending, etc. — via the Quick Config slide-out and connect-source dialog. Today that flow is **entirely in-memory mock**: `AcquisitionPathwaysService` holds an `EXTERNAL_SOURCES` seed and mutates it client-side, the connect dialog fakes a 2FA/connecting sequence, and no credential ever leaves the browser (see the `No real backend` notes in `ap-admin-quick-config-panel.component.ts` and `ap-connect-source-dialog.component.ts`).

We want a **real, persisted, org-scoped** integrations subsystem: connect / edit / rotate-credentials / disconnect (soft delete), with the external source's secret encrypted at rest and each integration's module scoping (which product modules it feeds) persisted.

> **Scope note:** this plan covers connect/manage only. The **record ingestion / sync work** (pulling records from SAM.gov/FPDS, populating `records_ingested` / `last_synced_at`, secret decryption) **will be handled in a separate, subsequent plan.**

**Deliberate design choice (per product owner):** rather than reuse the existing `/onering/portals/*` system (which the team considers fragile — it proxies credential storage to ONERING and juggles an RSA keypair with per-request `key_id` tracking), we build a **self-contained AP-owned resource** in `rohan_api` backed by its own Postgres table. The onering/portals feature is used only as design inspiration.

## Key architectural observations

- **AP module already has the shape to copy.** `rohan_api/src/acquisition-pathways/` has `AcquisitionMission` (entity + snake_case DTOs + service + controller with `AuthGuard('jwt')` + `FeatureGuard('AcquisitionPathways')` + `PermissionsGuard('acquisition-pathways')`), an `ApExceptionFilter`, and `AcquisitionPathwaysErrors` constants. The new integrations resource slots in beside it as a second controller/service.
- **Encryption at rest is already a solved pattern.** `src/connectors/connectors.service.ts` encrypts sensitive connector fields with pgcrypto (`pgp_sym_encrypt(...)`, base64) keyed by `requireCipherPassword()` (`src/utils/crypto/cipher-password.ts`), which **fails closed** when neither `CIPHER_PASSWORD` nor Key Vault is set (the 2026-06-22 audit finding). We reuse this verbatim — encrypt-on-write only (no read-back needed this ticket). pgcrypto is enabled by `init_connectors.sql`.
- **Migrations live in the Database repo as idempotent raw SQL**, registered in `run_all.sql`; entity decorators intentionally omit SQL defaults to avoid drift (see the comment in `acquisition-mission.entity.ts`). The new `init_acquisition_integrations.sql` follows `init_acquisition_missions.sql`.
- **Frontend HTTP convention is set.** `acquisition-pathways-api.service.ts` already calls `/acquisition-pathways/missions` via `RequestService` (`@shared-services/request`). The new `ApIntegrationsApiService` mirrors it exactly.
- **The FE view model already exists.** `ExternalSource` / `AppModule` (label) types drive the panel + dialog. We keep them as the render shape and add a wire DTO (`IntegrationDto`, snake_case) plus a mapper; the mock seed becomes a static `KNOWN_PROVIDERS` catalog.
- **Proposal Engine's portal UI was evaluated for reuse — components no, patterns yes.** PE's `ProposalEngineSourcesPanelComponent` / `ProposalEnginePortalDialogComponent` (`pages/proposal-engine/root/`, ~830 lines combined) are smart components hard-wired to exactly what this plan avoids: the `/onering/portals/*` query/mutation layer, the RSA `encryptPasswordWithPubkey` + `key_id` cipher, the simulated `'connecting'`/`'twofa'` steps, and a per-source enablement toggle AP doesn't have. The genuinely shared display layer is the app-wide `SharedComponentsModule` (`app-modal-wrapper`, `app-form-input`, `app-toggle-pill`, `app-button`), which AP's `ap-connect-source-dialog` **already composes** — so component-level reuse has effectively happened. What we do adopt from PE are its backend-agnostic **UX patterns**: a confirm-disconnect step and success toasts via the shared `ToastNotificationService` (Phase 4).
- **Status is derived from a soft-delete flag.** `archived = false` ⇒ connected; disconnect sets `archived = true` **and clears the stored secret** (credentials of a disconnected integration are not retained — the prototype's Reconnect flow requires re-entering them anyway), keeping `records_ingested`/`last_synced_at` history for the future ingestion plan. Reconnecting **revives** the archived row via the same connect endpoint (same `integration_id`), so the `(org_id, name)` UNIQUE stays a full constraint. The FE "Disconnected" list = archived rows + never-connected catalog providers. No separate `status`/`enabled` column.

## Assumptions

- Integrations are **org-level** (shared by all users in the org, admin-managed), keyed by `req.user.org_id`; the client never sends `org_id`. `created_by` records who connected.
- **Credential security posture:** plaintext secret travels over **TLS** in the request body and is encrypted at rest with **pgcrypto AES (`pgp_sym_encrypt`)**, fail-closed on missing key. We deliberately **drop** the onering/portals client-side RSA-OAEP pre-encryption + `key_id` dance — it is the fragility we were asked to avoid, and the `connectors` module already establishes the simpler "plaintext-over-TLS → encrypt-at-rest" posture in this codebase. (Confirm — Open Question 1.)
- **Scope = connect/manage only.** No record ingestion/sync — **the ingestion work (sync jobs, pulling records from SAM.gov/FPDS, populating counts) will be handled in a separate, subsequent plan.** `records_ingested` (0) and `last_synced_at` (null) are display-only fields that plan will populate. The stored secret is written but never read back in this ticket (decryption belongs to the ingestion plan).
- **2FA dropped.** The prototype's simulated 2FA/Rohan-chat verification is removed; the real connect is a synchronous request/response.
- **Module scoping is persisted** (`modules` jsonb array of slugs). Only `pathway-engine` is user-selectable today; other module chips render disabled ("coming soon"), matching the prototype. The admin panel is scoped to Pathway Engine, so new sources default to `['pathway-engine']`.
- Errors flow through the existing `ApExceptionFilter` + `AcquisitionPathwaysErrors` constants.

## Open questions

| # | Question | Proposed default |
|---|----------|------------------|
| 1 | Confirm the security posture: TLS + pgcrypto-at-rest, **no** client-side RSA pre-encryption? | **Yes** — matches the `connectors` module; encryption-at-rest + fail-closed key is preserved. If defense-in-depth against request-body loggers is required, add a client-side encrypt step in a follow-up (don't rebuild the portals `key_id` system). |
| 2 | Should connecting/managing an org-wide integration require an **admin-specific** permission, or is the `acquisition-pathways` permission enough? | Reuse `@Permissions('acquisition-pathways')` for now (FE already admin-gates the panel via `CurrentUserContext.isAdmin`). If there's a distinct admin scope/role, add it to the guard — name it here. |
| 3 | Uniqueness: `(org_id, name)` exact, or case-insensitive `(org_id, lower(name))`? | Exact `(org_id, name)`. Switch to an expression index if "SAM.gov" vs "sam.gov" duplicates become a problem. |
| 4 | Provider slug set — is `custom` (user-typed name+URL) allowed, or only known providers? | Allow `custom`. The dialog already supports a blank-form flow; `KNOWN_PROVIDERS` is only a convenience catalog. |
| 5 | ~~On disconnect, hard-delete or soft-delete?~~ **RESOLVED (2026-07-14): soft delete.** Disconnect sets `archived = true` + clears `secret_ciphertext`; reconnect revives the row via `POST /connect`. | — |

---

## Implementation phases

### Phase 1 — Database migration [BACKEND_DB]

```phase-meta
phase: 1
title: acquisition_integrations table
tags: [BACKEND_DB]
repo: Database
base_branch: main
depends_on: []
files:
  - rohan_api/scripts/sql/init_acquisition_integrations.sql
  - rohan_api/scripts/run_all.sql
contracts:
  - "4.1 acquisition_integrations table"
verification:
  - "psql -f rohan_api/scripts/run_all.sql against a scratch DB (or docker boot) — table + index + trigger created, re-run is a no-op"
```

**Goal**: Add the idempotent `acquisition_integrations` table and register it in the boot sequence.

**Steps**:

- [ ] **1.1** Create `init_acquisition_integrations.sql` per contracts §4.1 (table with `archived boolean NOT NULL DEFAULT FALSE` soft-delete flag and **nullable** `secret_ciphertext` (null ⇔ archived), `auth_method` CHECK, full `(org_id, name)` UNIQUE — reconnect revives, so no partial index — `org_id` index, `set_timestamp` trigger). Idempotent (`CREATE TABLE IF NOT EXISTS`, `CREATE OR REPLACE TRIGGER`).
  - File: `rohan_api/scripts/sql/init_acquisition_integrations.sql`
- [ ] **1.2** Register it in `run_all.sql` on the line **after** `\i ./sql/init_acquisition_missions.sql`. This script never calls pgcrypto (the `secret_ciphertext` column is plain `text`; encryption happens at app runtime), so its position relative to `init_connectors.sql` (which runs later and owns `CREATE EXTENSION pgcrypto`) doesn't matter — by request time the full boot has completed. Do not re-declare pgcrypto here.
  - File: `rohan_api/scripts/run_all.sql`
- [ ] **1.3** Boot the DB container (or run `run_all.sql` twice against a scratch DB) to confirm creation and idempotency.

### Phase 2 — Backend resource: entity, DTOs, service, controller [BACKEND_DB]

```phase-meta
phase: 2
title: Integrations REST resource
tags: [BACKEND_DB]
repo: rohan_api
base_branch: main
depends_on: [1]
files:
  - src/acquisition-pathways/entities/external-integration.entity.ts
  - src/acquisition-pathways/dto/integrations/integration.dto.ts
  - src/acquisition-pathways/dto/integrations/connect-integration.dto.ts
  - src/acquisition-pathways/dto/integrations/update-integration.dto.ts
  - src/acquisition-pathways/dto/integrations/list-integrations-query.dto.ts
  - src/acquisition-pathways/services/ap-integrations.service.ts
  - src/acquisition-pathways/services/ap-integrations.service.spec.ts
  - src/acquisition-pathways/controllers/ap-integrations.controller.ts
  - src/acquisition-pathways/controllers/ap-integrations.controller.spec.ts
  - src/acquisition-pathways/ap.constants.ts
  - src/acquisition-pathways/acquisition-pathways.module.ts
contracts:
  - "2.1 GET /integrations"
  - "2.2 POST /integrations"
  - "2.3 PATCH /integrations/:id"
  - "2.4 DELETE /integrations/:id"
  - "3.1 IntegrationDto"
  - "3.2 ConnectIntegrationDto"
  - "3.3 UpdateIntegrationDto"
  - "3.4 ListIntegrationsQueryDto"
  - "5.1 ExternalIntegration entity"
  - "5.2 pgcrypto secret encryption"
  - "7. Error responses"
verification:
  - npm run lint
  - npm run test -- src/acquisition-pathways/services/ap-integrations.service.spec.ts
  - npm run test -- src/acquisition-pathways/controllers/ap-integrations.controller.spec.ts
  - npm run build
```

**Goal**: A working, guarded, org-scoped CRUD resource at `/acquisition-pathways/integrations` that encrypts secrets at rest and never returns them.

**Steps**:

- [ ] **2.1** Create the `ExternalIntegration` entity + `INTEGRATION_AUTH_METHODS` / `AppModuleSlug` / `APP_MODULE_SLUGS` consts (contracts §5.1). No SQL defaults in decorators.
- [ ] **2.2** Create the four DTOs (contracts §3.1–3.4) with `@ApiProperty()` + class-validator decorators. `IntegrationDto` has **no** secret field.
- [ ] **2.3** Add error-message keys to `ap.constants.ts` per contracts §7 (`integrationNotFound`, `integrationNameConflict`, `persistIntegrationError`).
- [ ] **2.4** Build `ApIntegrationsService` (inject `@InjectRepository(ExternalIntegration)` + `DataSource` for the pgcrypto query):
  - `list(user, module?)` → filter `org_id = user.org_id` (active **and** archived — the FE splits on `archived`), optional jsonb `modules ? :module` (or `@> '["module"]'`); map rows → `IntegrationDto` (drop `secret_ciphertext`).
  - `connect(dto, user)` → `encryptSecret(dto.secret)` (contracts §5.2). If an **archived** row matches `(org_id, name)`, **revive** it: new secret/metadata/modules, `archived = false`, history preserved, same `integration_id`. Else insert with `org_id`/`created_by` from `user`, `records_ingested = 0`; unique violation (active row holds the name) → name-conflict error.
  - `update(id, dto, user)` → load **active** row by `(integration_id, org_id, archived = false)` or throw not-found; re-encrypt only if `dto.secret` present; apply metadata/modules; save.
  - `disconnect(id, user)` → load active row by `(integration_id, org_id, archived = false)` or throw not-found; set `archived = true`, `secret_ciphertext = null`; save. History columns untouched.
  - `ponytail:` inline the 2-line `pgp_sym_encrypt` block (dup of `connectors.service`); extract a shared `PgSymCipher` util only if a 4th consumer appears.
- [ ] **2.5** Build `ApIntegrationsController` — mirror `ApMissionsController`'s guards/decorators (`@UseGuards(AuthGuard('jwt'), FeatureGuard, PermissionsGuard)`, `@Features('AcquisitionPathways')`, `@Permissions('acquisition-pathways')`, `@ApiTags`). Routes per contracts §2; `@GetUser()`/`req.user` for org scope; `@UsePipes(ValidationPipe)`; `DELETE` returns `204` (`@HttpCode(204)`). Wrap service errors through `ApExceptionFilter` / `toHttpException` like the missions controller.
- [ ] **2.6** Register in `acquisition-pathways.module.ts`: add `ExternalIntegration` to `TypeOrmModule.forFeature([...])`, `ApIntegrationsController` to `controllers`, `ApIntegrationsService` to `providers`.
- [ ] **2.7** Unit specs: service (encrypt called, org scoping, not-found, name-conflict, secret never in output, **disconnect archives + clears the secret**, **connect revives an archived row instead of 409ing**, **update/disconnect 404 on archived ids**) and controller (routes, guards wired, 204 on delete). Mock the pgcrypto query in the service spec.

### Phase 3 — Frontend API client, types, provider catalog [FRONTEND]

```phase-meta
phase: 3
title: Integrations API client + types
tags: [FRONTEND]
repo: rohan_ui
base_branch: main
depends_on: [2]
files:
  - src/app/pages/acquisition-pathways/types/acquisition-pathways.types.ts
  - src/app/pages/acquisition-pathways/constants/known-providers.ts
  - src/app/pages/acquisition-pathways/services/ap-integrations-api.service.ts
  - src/app/pages/acquisition-pathways/services/ap-integrations-api.service.spec.ts
contracts:
  - "6.1 FE DTO types + mapper"
  - "6.2 KNOWN_PROVIDERS catalog"
  - "6.3 ApIntegrationsApiService"
verification:
  - npm run lint
  - npm run test:ci -- --include='src/app/pages/acquisition-pathways/services/ap-integrations-api.service.spec.ts'
```

**Goal**: A typed HTTP client + the wire types/mapper + static provider catalog — consumed by nothing yet, so it merges safely.

**Steps**:

- [ ] **3.1** Extend `acquisition-pathways.types.ts` (contracts §6.1): `IntegrationDto`, `AppModuleSlug`, `ConnectIntegrationRequest`, `UpdateIntegrationRequest`, the `toExternalSource(dto)` mapper, and `moduleLabelToSlug` / `moduleSlugToLabel` helpers.
- [ ] **3.2** Create `known-providers.ts` (contracts §6.2) with eight known providers — the six from the prototype seed (SAM.gov, FPDS, USASpending, GSA eBuy, Grants.gov, SpaceWERX) plus two net-new (BidNet Direct, DemandStar). This is the source of logos/descriptions and the "available" catalog.
- [ ] **3.3** Create `ApIntegrationsApiService` (contracts §6.3) mirroring `acquisition-pathways-api.service.ts`: `RequestService`, `BASE = '/acquisition-pathways/integrations'`, methods `listIntegrations(module?)` / `connectIntegration` / `updateIntegration` / `disconnectIntegration`.
- [ ] **3.4** Spec the API service the same way as `acquisition-pathways-api.service.spec.ts` (assert method + path + body per call), plus a mapper unit test (dto → ExternalSource; known vs custom provider; `archived` → `status: 'available'` vs `'connected'`).

### Phase 4 — Wire the panel + dialog to the real backend [FRONTEND]

```phase-meta
phase: 4
title: Wire admin panel + connect dialog
tags: [FRONTEND]
repo: rohan_ui
base_branch: phase-3
depends_on: [3]
files:
  - src/app/pages/acquisition-pathways/shared/admin-quick-config-panel/ap-admin-quick-config-panel.component.ts
  - src/app/pages/acquisition-pathways/shared/admin-quick-config-panel/ap-admin-quick-config-panel.component.html
  - src/app/pages/acquisition-pathways/shared/admin-quick-config-panel/ap-admin-quick-config-panel.component.spec.ts
  - src/app/pages/acquisition-pathways/shared/connect-source-dialog/ap-connect-source-dialog.component.ts
  - src/app/pages/acquisition-pathways/shared/connect-source-dialog/ap-connect-source-dialog.component.html
  - src/app/pages/acquisition-pathways/services/acquisition-pathways.service.ts
contracts:
  - "6.1 FE DTO types + mapper"
  - "6.2 KNOWN_PROVIDERS catalog"
  - "6.3 ApIntegrationsApiService"
verification:
  - npm run lint
  - npm run test:ci -- --include='src/app/pages/acquisition-pathways/shared/admin-quick-config-panel/ap-admin-quick-config-panel.component.spec.ts'
  - npm run build
```

**Goal**: The panel loads real integrations, the dialog performs real connect/edit/disconnect, and the mock seed + 2FA theater are gone.

**Steps**:

- [ ] **4.1** Remove the `EXTERNAL_SOURCES` seed + `_externalSources$` BehaviorSubject + `getExternalSources`/`connectSource`/`saveSource`/`disconnectSource` mock methods from `acquisition-pathways.service.ts`.
- [ ] **4.2** Rewire `ap-admin-quick-config-panel.component.ts` to `ApIntegrationsApiService`:
  - Load via `listIntegrations('pathway-engine')` → map with `toExternalSource`. **Connected** = rows with `archived = false`; **disconnected** = archived rows (mapped, keeping their names/history) + `KNOWN_PROVIDERS` entries whose `provider` appears in no org row at all (contracts §6.2).
  - `handleDialogResult`: `connect` (incl. reconnect of an archived source — the backend revives it) → `connectIntegration(...)`, `save` → `updateIntegration(id, ...)`, `disconnect` → `disconnectIntegration(id)`; refresh the list on success.
  - Add loading + error signals; show an inline error state on failure (no silent swallow). Keep the `isAdmin` gate.
- [ ] **4.3** Update the dialog `ap-connect-source-dialog.component.ts`:
  - **Drop** the `'connecting'` / `'twofa'` steps and their timers — emit the connect/save/disconnect result directly (the panel performs the async call and shows progress).
  - Emit a `ConnectIntegrationRequest`/`UpdateIntegrationRequest`-shaped payload (provider from catalog match or `'custom'`, `secret` from the password/apikey field, `modules` from the chips as slugs). On edit, omit `secret` when the field is untouched (metadata-only save).
  - Keep the module chips (Pathway Engine enabled, others disabled "coming soon") and the password/apikey auth toggle.
  - **Adopt PE's UX patterns** (pattern reuse, not component reuse — see Key architectural observations): add a `confirm-disconnect` step before emitting `disconnect` (AP currently disconnects with no confirmation; mirror `ProposalEnginePortalDialogComponent`'s step), and have the panel fire `ToastNotificationService` toasts on successful connect / disconnect (e.g. PE's copy: "This source has been disconnected. Reconnect it anytime…" adapted to AP wording).
- [ ] **4.4** Update `ap-connect-source-dialog.component.html` to drop the 2FA/connecting markup and add the confirm-disconnect step markup.
- [ ] **4.5** Update the panel spec: mock `ApIntegrationsApiService`, assert connected/disconnected derivation, dialog-result → correct API call, error-state rendering, and success toasts. Adjust the dialog spec for the removed 2FA steps and the new confirm-disconnect step.
- [ ] **4.6** Manual/e2e smoke (optional, if a seeded org + `CIPHER_PASSWORD` are available): connect SAM.gov → appears connected; edit modules; disconnect → returns to disconnected list; reconnect with fresh credentials → same integration revived.

---

## Phase order and parallelism

**File-touch matrix:**

| File / area | P1 | P2 | P3 | P4 |
|-------------|----|----|----|----|
| `Database/…/init_acquisition_integrations.sql`, `run_all.sql` | ✎ | | | |
| `rohan_api/…/acquisition-pathways/**` (entity, dto, service, controller, module, constants) | | ✎ | | |
| `rohan_ui/…/types`, `constants/known-providers`, `services/ap-integrations-api` | | | ✎ | |
| `rohan_ui/…/shared/admin-quick-config-panel/*`, `shared/connect-source-dialog/*`, `services/acquisition-pathways.service` | | | | ✎ |

**Cross-repo note:** the four phases span three repos (Database, rohan_api, rohan_ui). Stacked branches are **per-repo**: P1 (Database) and P2 (rohan_api) each branch off their own repo's `main`; P3 and P4 (both rohan_ui) stack (P4 off `phase-3`). `depends_on` is a **logical/contract** dependency, not a git-branch base across repos.

**Parallelism:** P1 and P2 can be written in parallel (different repos), but P2 can't be integration-tested against a real DB until P1's SQL is applied — its unit specs mock the DB, so P2's PR can still land independently. P3 depends on P2's contracts (the DTO shapes); P4 depends on P3. Frontend P3→P4 is strictly sequential.

**Recommended order:** 1 → 2 → 3 → 4. Backend-first so the contract is real before the FE consumes it. P1 and P2 are safe standalone merges (table + unused resource). P3 is an additive FE merge (client consumed by nothing yet). P4 is the switch-over that removes the mock.

**Branches (stacked, per repo):** `{user}/PRCR-1689/phase-{N}`.

## Phase context summaries

**Phase 1** (Database repo) — Adds the idempotent `acquisition_integrations` table (org-scoped; **nullable** `secret_ciphertext`, `modules` jsonb, `archived` soft-delete flag, `auth_method` CHECK, full `(org_id,name)` UNIQUE — reconnect revives archived rows, so no partial index — `org_id` index, `set_timestamp` trigger) and registers it in `run_all.sql` after `init_acquisition_missions.sql`. The migration never calls pgcrypto (encryption is app-runtime), so its placement relative to `init_connectors.sql` (which owns `CREATE EXTENSION pgcrypto` and runs later in `run_all.sql`) is irrelevant — don't re-declare pgcrypto. No app code. Gotcha: keep it idempotent (re-run on every container boot); SQL defaults live here, not in the entity.

**Phase 2** (rohan_api) — Adds the `/acquisition-pathways/integrations` REST resource beside the missions resource: `ExternalIntegration` entity + module-slug consts, four snake_case DTOs, `ApIntegrationsService` (org-scoped CRUD, encrypt-on-write via pgcrypto reusing `requireCipherPassword()` — encrypt only, never decrypt this ticket), `ApIntegrationsController` (same guards as `ApMissionsController`), constants, module registration. Depends on Phase 1's table for real runs; specs mock the DB. Soft delete: disconnect archives + clears the secret; connect revives an archived `(org_id, name)` match; PATCH/DELETE see only active rows. Gotchas: `IntegrationDto` must never carry the secret; `404` is scoped by `(id, org_id, active)` so cross-org and archived ids can't be probed/patched; `409` name conflict only against **active** rows; fail closed if `CIPHER_PASSWORD` is unset.

**Phase 3** (rohan_ui) — Adds the FE wire types (`IntegrationDto` + request shapes), the `toExternalSource` mapper + label↔slug helpers, the static `KNOWN_PROVIDERS` catalog (replacing the mock seed), and `ApIntegrationsApiService` (mirrors `acquisition-pathways-api.service.ts` on `RequestService`). Consumed by nothing yet → safe merge. Depends on Phase 2's DTO contract. Gotcha: keep `ExternalSource`/`AppModule` (label) as the render shape — the DTO is snake_case slugs and the mapper bridges them.

**Phase 4** (rohan_ui, stacks on Phase 3) — Switches the admin panel + connect dialog from the in-memory mock to `ApIntegrationsApiService`: panel splits `listIntegrations` results on `archived` (connected = active rows; disconnected = archived rows + never-connected `KNOWN_PROVIDERS`); dialog performs real connect/edit/disconnect — reconnect submits through connect and the backend revives the row — and **drops** the simulated 2FA/connecting steps; the `EXTERNAL_SOURCES` seed + mock service methods are deleted; loading/error states added. Depends on Phase 3. Also adopts PE's backend-agnostic UX patterns (confirm-disconnect step + `ToastNotificationService` success toasts) — PE's portal components themselves are **not** reused (they're welded to the onering/portals query layer, RSA cipher, and 2FA steps this plan avoids; the shared display layer is `SharedComponentsModule`, which AP's dialog already composes). Gotchas: on metadata-only edit, omit `secret` so the stored credential isn't overwritten; reconnect always requires fresh credentials (the archived row's secret was cleared); keep the `isAdmin` gate and the disabled non-Pathway-Engine module chips; surface errors (don't swallow).

## Jira ticket

**Ticket:** [PRCR-1689](https://rohirrim.atlassian.net/browse/PRCR-1689) (epic [PRCR-1633](https://rohirrim.atlassian.net/browse/PRCR-1633)). Title/description/AC below are the intended ticket content — sync them to Jira if the ticket body differs.

**Title:** Acquisition Pathways — persist external data-source integrations (connect / manage) for Pathway Engine

**Description:**
The Pathway Engine admin Quick Config panel lets an admin add integrations to external data sources (SAM.gov, FPDS, USASpending, …), but the flow is entirely an in-memory mock — no persistence, no real credentials, simulated 2FA. Build a self-contained, org-scoped integrations resource in `rohan_api` (its own `acquisition_integrations` table) that supports connect / edit / rotate-credentials / disconnect, encrypts each source's secret at rest with pgcrypto (fail-closed key, reusing the `connectors` pattern), and persists each integration's module scoping. Disconnect is a **soft delete** (`archived` flag; secret cleared, ingestion history kept; reconnect revives the row). Wire the existing admin panel + connect-source dialog to it and remove the mock seed and 2FA theater. Deliberately **not** reusing the `/onering/portals/*` system (fragile RSA/`key_id` proxy) — inspiration only. Record ingestion/sync is out of scope here and **will be handled in a separate, subsequent plan** (`records_ingested`/`last_synced_at` are display-only placeholders for that plan). File under the Pathway Engines epic (PRCR-1633).

**Acceptance criteria:**
- [ ] `acquisition_integrations` table exists (idempotent SQL, registered in `run_all.sql`) with org scoping, encrypted (nullable) secret column, jsonb `modules`, `archived` soft-delete flag, and `(org_id, name)` uniqueness (Phase 1).
- [ ] `/acquisition-pathways/integrations` GET/POST/PATCH/DELETE is live, JWT + feature + permission guarded, org-scoped; secrets are encrypted at rest via pgcrypto and never returned; disconnect soft-deletes (archives + clears the secret) and connect revives archived rows; name conflicts against active rows → 409, cross-org/absent/archived ids → 404 on PATCH/DELETE; service + controller unit-tested (Phase 2).
- [ ] `ApIntegrationsApiService`, wire DTO types + `toExternalSource` mapper (incl. `archived` → status), and the static `KNOWN_PROVIDERS` catalog exist and are unit-tested (Phase 3).
- [ ] The admin panel lists real integrations split on `archived` and derives the never-connected list from the catalog; the dialog connects/edits/disconnects/reconnects against the backend with no simulated 2FA; the in-memory mock is removed; loading/error states handled (Phase 4).
- [ ] `npm run lint`, backend `npm run test` (new specs) + `npm run build`, and frontend `npm run test:ci` (new specs) + `npm run build` all pass.
