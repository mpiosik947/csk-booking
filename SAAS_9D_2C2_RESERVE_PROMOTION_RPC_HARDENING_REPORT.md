# SAAS-9D-2C-2 — Event reserve promotion RPC hardening

## 1. Executive summary

The local SAAS-9D-2C-2 implementation is complete. The manual promotion route now authenticates the caller, derives the tenant from the requested event, requires an active `admin` or `employee` membership in that tenant, and only then crosses the service-role boundary. The two service-only promotion claim functions retain their public signatures and business response contracts, but now run as `SECURITY INVOKER` with explicit event/registration/tenant binding.

No production operation, Git staging, commit, push, or deployment was performed.

## 2. Exact RPC scope

- `prepare_event_reserve_promotions(uuid)` — event ID input; returns registration ID, claim ID, promotion token, expiry, and token reuse state.
- `complete_event_reserve_promotion(uuid,uuid,boolean,text)` — registration ID, claim ID, provider success flag, and bounded provider error code; returns JSON completion state.
- Both signatures and result contracts are unchanged.

## 3. Manual endpoint scope

Only `POST /api/send-event-reserve-promotion` in `app/api/send-event-reserve-promotion/route.ts` changed. It remains Bearer-authenticated through `verifyAuthUser`, accepts exactly one `eventId`, and calls the existing `promoteEventReserve(eventId)` helper. No UI, browser contract, shared auth framework, or other endpoint changed.

## 4. Pre-change fingerprints

Normalized CRLF/CR -> LF MD5 baselines guarded by the migration:

| Function | Baseline MD5 |
|---|---|
| `prepare_event_reserve_promotions(uuid)` | `4e73ef1df59936a1a3f41a00e121f6e9` |
| `complete_event_reserve_promotion(uuid,uuid,boolean,text)` | `dd5025876008d6eb9551497d84cef90e` |

The migration also freezes non-target function metadata/body fingerprints, exact overload inventory, owner, search path, ACL, service-role table permissions, tenant/claim/token invariants, the 72-function pre-state, and all seven compatibility defaults.

## 5. Caller inventory

The only application caller is `lib/server/event-reserve-promotion.ts`. It is reached by the manual route and the existing event-registration cancellation workflow. No SQL-to-SQL caller was found. The helper and automatic cancellation provenance were intentionally left unchanged.

## 6. APP FIRST rollout contract

Real local HTTP checks were run both before and after applying the new migration:

- NEW APP + OLD DB: valid tenant admin path `200`; global admin without membership `403`; foreign-tenant event `404`; malformed input `400`; unknown event `404`; fixture `0`.
- NEW APP + NEW DB: the same matrix passed after a clean local reset.

The first synthetic harness attempt lacked a trigger-created profile in this local setup. The harness was corrected to create/update only its own synthetic profiles, cleaned to zero, and the repeated compatibility runs passed. This was a fixture issue, not an application defect.

## 7. Endpoint authorization

The route order is now: Bearer authentication -> strict body/UUID validation -> caller-scoped event lookup -> tenant derivation -> `has_tenant_role_v1(event.tenant_id, ['admin','employee'])` -> service helper. Legacy `profiles.role` is no longer queried. Pending, suspended, absent, ordinary-user, instructor, global-role-only, and foreign-tenant membership paths fail closed.

## 8. Tenant derivation

The request cannot provide `tenant_id`, recipient, user ID, claim, or registration. Tenant authority comes only from `events.tenant_id` returned through the authenticated caller's existing event read contract. Unknown or inaccessible events return the same controlled not-found response.

## 9. Prepare promotion

`prepare_event_reserve_promotions(uuid)` is now `SECURITY INVOKER`. It locks and resolves the event, derives its tenant, and selects only reserve registrations whose `event_id` and `tenant_id` both match that event. It preserves the existing candidate count, token reuse, claim TTL, token TTL, attempt tracking, and exact return shape.

## 10. Complete promotion

`complete_event_reserve_promotion(uuid,uuid,boolean,text)` is now `SECURITY INVOKER`. It derives registration -> event -> tenant, locks the event before the registration, revalidates event/registration tenant equality, active claim identity and expiry, and performs success/failure updates with exact tenant, event, registration, and claim predicates. Cancellation or event deactivation cannot be reversed by provider completion; only the already-authorized technical delivery state is finalized.

## 11. Service-role boundary

The service role is created and used only inside the existing server helper after caller authentication and tenant-role authorization. Browser input cannot select a tenant or recipient. Local tests prove that service-role invoker execution has the required table privileges and remains bound by exact resource predicates.

## 12. SECURITY INVOKER conversion

Exactly the two target functions changed from `SECURITY DEFINER` to `SECURITY INVOKER`. The local public `SECURITY DEFINER` inventory changed from 72 to the expected 70. Non-target function fingerprint drift is zero.

## 13. ACL and search path

Both functions retain owner `postgres`, volatile mode, SP1 `pg_catalog, public, pg_temp`, and exact service-only EXECUTE. `PUBLIC`, `anon`, and `authenticated` have no EXECUTE; `service_role` has EXECUTE. No table grant or RLS policy was widened.

## 14. FIFO

Candidate ordering remains the existing stable `created_at`, then `id` ordering. Focused SQL and concurrency tests show that tenant filtering does not reorder Tenant A candidates.

## 15. Multiple notifications

The existing multi-recipient model is preserved. Focused SQL proves two eligible reserve candidates are prepared when capacity permits; the migration does not arbitrarily reduce the batch to one candidate.

## 16. First-confirmed-wins

The existing confirmation writer remains authoritative. With one free place and competing reserve confirmations, exactly one registration becomes capacity-occupying; the other cannot exceed capacity. Concurrent test result: `FIRST_CONFIRMED_WINS`, deadlocks `0`, broken invariants `0`.

## 17. Token and claim security

Valid first completion, replay, wrong claim, expired claim, failure completion, replacement/supersession, cancellation, and deactivation paths were tested. Replay and invalid bindings produce no duplicate effect; failure completion is idempotent; tokens and claims remain unique.

## 18. Email side effects

This flow does not create `email_deliveries`; delivery state is held on the tenant-owned `event_registrations` row. Therefore no CSK default is used as an authorization mechanism. Recipient IDs returned by prepare are limited to the exact event/tenant candidate set, and complete revalidates the binding. No real email was sent during local verification.

## 19. Cross-tenant tests

Event A/Registration A succeeds. Event A/Registration B, Claim A/Registration B, Claim B/Registration A, staff A/Event B, and concurrent Tenant A/Tenant B operations are denied or isolated. Tenant B rows remain unchanged.

## 20. Concurrency

The deterministic PowerShell/psql harness passed:

- concurrent prepare;
- concurrent complete of the same claim;
- first-confirmed-wins with one place;
- complete versus registration cancellation;
- complete versus event deactivation;
- simultaneous Tenant A and Tenant B promotions.

Final counters: deadlocks `0`, duplicate final effects `0`, broken invariants `0`, fixture `0`.

## 21. App compatibility matrix

| Application | Database | Result |
|---|---|---|
| old | old | Operational legacy baseline; manual global-role gap remains. |
| new | old | PASS; required APP-FIRST compatibility state. |
| old | new | Calls remain operational, but the old manual endpoint can retain the global-role gap; not an accepted completed security state. |
| new | new | PASS; target tenant-bound route and invoker functions. |

Production recommendation: deploy and verify the application first, then deploy the single approved DB migration in the same controlled low-traffic release.

## 22. PII

Route responses remain bounded to safe status/count fields. Tests reject tenant, membership, recipient, user, token, and claim input. Logs and responses do not expose email, user ID, JWT, service key, full claim/token, provider body, or foreign-resource details.

## 23. Regression

- focused endpoint tests: 5/5 PASS;
- focused 2C-2 SQL: 36/36 PASS;
- concurrency harness: PASS;
- full Supabase DB: 32 files, 972 tests, PASS;
- full Node: 739/739 PASS;
- focused Playwright Events: 8/8 PASS; full Playwright suite: 30/30 PASS;
- TypeScript: PASS;
- Next.js production build: PASS;
- changed-files ESLint: PASS;
- fixture cleanup: all checked categories `0`.

Known unrelated outputs: the existing Next.js middleware-to-proxy deprecation warning remains; `npm audit --omit=dev` reports one MODERATE advisory in transitive `baseline-browser-mapping`. Neither was changed in this scoped remediation.

## 24. SECURITY DEFINER inventory

Expected and actual local count: **70**. Exactly two target functions left the definer inventory. Non-target drift: **0**. UNKNOWN inventory: **0**.

## 25. Compatibility defaults

All 7/7 temporary CSK defaults remain present. Neither target function inserts a tenant-owned row. Event and registration tenants are explicitly derived and compared, so defaults are not used by this flow as a security boundary.

## 26. Migration SHA

`20260914150000_harden_event_reserve_promotion_rpcs.sql`

SHA-256: `A9373F9BCFBB456624720FB2AFFB94A416C428454B7881E6FB2649F21ED39759`

Target normalized MD5 fingerprints after migration:

- prepare: `cdc7abeb7f8ced41cde0f5524a8953ef`
- complete: `2c78ac26c5c55df3aac54360b610d39b`

## 27. Production rollout plan

1. Verify only the approved app diff and deploy APP FIRST.
2. Smoke the manual route: valid active tenant admin/employee allow; global-role-only and foreign-tenant deny.
3. Re-run production read-only fingerprints, ACL, invariants, 72-count, seven-default, migration-history, and pending-migration checks.
4. Stop unless the only pending migration is `20260914150000_harden_event_reserve_promotion_rpcs.sql` with the SHA above.
5. Obtain separate production-write approval; apply through normal linked migration tooling.
6. Verify target fingerprints, INVOKER/SP1/service-only ACL, count 70, no drift, compatibility defaults 7/7, runtime flows, and zero fixture.

Application-only rollback after DB deployment is not an accepted state because it reopens the manual-route gap. Prefer forward fix or coordinated app+DB forward rollback while the second-active-tenant guard remains enforced.

## 28. Git status

The working tree is intentionally dirty with the scoped migration, tests, endpoint, plan, and this report. `AGENTS.md` is a separate Next.js-generated instruction-file change and is not part of SAAS-9D-2C-2. Nothing was staged or committed.

## 29. Final verdict

SAAS-9D-2C-2 LOCAL: **PASS**

MANUAL ENDPOINT AUTHORIZATION: **PASS**

APP FIRST COMPATIBILITY: **PASS**

RPC TENANT ISOLATION: **PASS**

GLOBAL ROLE BYPASS: **REMOVED**

SERVICE_ROLE BOUNDARY: **PASS**

SECURITY INVOKER CONVERSION: **PASS**

FIFO: **PASS**

MULTIPLE NOTIFICATIONS: **PASS**

FIRST-CONFIRMED-WINS: **PASS**

TOKEN / CLAIM SECURITY: **PASS**

EMAIL TENANT CONSISTENCY: **PASS**

CONCURRENCY: **PASS**

PII: **PASS**

REGRESSION 2A/2B/2C-1: **PASS**

EXPECTED SECURITY DEFINER COUNT: **70**

READY FOR SAAS-9D-2C-2 PRODUCTION APP PREFLIGHT: **GO**

READY FOR PRODUCTION WRITE: **NO**

READY FOR SAAS-9D-3: **NO-GO until 2C-2 full production rollout/checkpoint**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## 32. DB PRODUCTION PREFLIGHT — AFTER APP-FIRST DEPLOYMENT

Preflight date: 2026-09-14 (Europe/Warsaw). All production database checks in
this section were read-only. No migration push, migration repair, production
DML/DDL, Git staging, commit, or push was performed.

### 32.1 Production state

The production application project `csk-booking-5nwh` reports a successful
Vercel deployment for:

`bc87cda6fc85ff371e6da7d91a40fb42ce11100c`

The application is therefore the approved APP-first version. Production DB is
still PRE-2C-2: linked migration history ends at `20260914100000`, while
`20260914150000` is local-only. The hardened anonymous endpoint boundary also
remains live: an unauthenticated POST returns controlled HTTP 401 and no
service/provider operation is reached.

PRODUCTION STATE NEW APP + OLD DB: **PASS**

### 32.2 Migration SHA and history

The migration SHA-256 was recalculated from the current working-tree artifact:

`A9373F9BCFBB456624720FB2AFFB94A416C428454B7881E6FB2649F21ED39759`

It matches the approved frozen SHA exactly.

`supabase migration list --linked` confirms LOCAL = REMOTE through
`20260914100000`. There is no remote-only migration, divergence, or history
mismatch. The only pending migration is:

`20260914150000_harden_event_reserve_promotion_rpcs.sql`

SHA: **PASS**

MIGRATION HISTORY: **PASS**

### 32.3 Exact RPC scope, fingerprints, and metadata

CRLF/CR was normalized to LF before MD5 calculation.

| Function | Signature / return contract | Production / baseline MD5 | Target MD5 | Current -> target mode | Owner | Current -> target search path |
|---|---|---|---|---|---|---|
| `prepare_event_reserve_promotions` | `(uuid)` -> table `(registration_id uuid, claim_id uuid, promotion_token text, promotion_token_expires_at timestamptz, token_reused boolean)` | `4e73ef1df59936a1a3f41a00e121f6e9` | `cdc7abeb7f8ced41cde0f5524a8953ef` | DEFINER -> INVOKER | postgres -> postgres | `public, pg_temp` -> `pg_catalog, public, pg_temp` |
| `complete_event_reserve_promotion` | `(uuid,uuid,boolean,text)` -> `jsonb` | `dd5025876008d6eb9551497d84cef90e` | `2c78ac26c5c55df3aac54360b610d39b` | DEFINER -> INVOKER | postgres -> postgres | `public, pg_temp` -> `pg_catalog, public, pg_temp` |

Production normalized fingerprints equal their expected PRE-2C-2 baselines:
**2/2 PASS**. The migration contains exactly two `CREATE OR REPLACE FUNCTION`
statements and two matching owner alterations. It contains no other function
replacement, policy statement, table DDL, default alteration, or membership,
public-reader, event-management, or 2C-1 confirmation-email change.

### 32.4 SECURITY INVOKER conversion and ACL

Production currently contains exactly 72 public-schema SECURITY DEFINER
functions. The target converts exactly the two functions above to INVOKER, so
the expected post-migration count is exactly 70.

The direct EXECUTE matrix is unchanged by the migration for both functions:

| Role | Current | Target |
|---|---:|---:|
| PUBLIC | NO | NO |
| anon | NO | NO |
| authenticated | NO | NO |
| service_role | YES | YES |

There is no ACL widening. Owner remains `postgres`, while execution authority
remains service-only.

### 32.5 Service-role INVOKER capability

Fresh production catalog checks returned:

| Required capability | Result |
|---|---|
| `events` SELECT | PASS |
| `event_registrations` SELECT | PASS |
| `event_registrations` UPDATE | PASS |
| `gen_random_uuid()` EXECUTE | PASS |
| `email_deliveries` SELECT/UPDATE | PASS |

The two target RPC bodies directly use only `events`,
`event_registrations`, built-in catalog functions, and promotion claim/token
columns stored on `event_registrations`; they use no sequence and do not access
`email_deliveries`. The broader delivery capability is present but is not
needed to make these two INVOKER functions work. `service_role` also retains
its established BYPASSRLS runtime contract. No missing privilege was found.

SERVICE_ROLE CAPABILITY: **PASS**

### 32.6 APP-first endpoint and target compatibility

The deployed endpoint follows the approved chain:

`authenticated caller -> caller-visible event -> event.tenant_id -> active membership -> admin/employee -> server service client -> service-only RPC`

The deployed commit contains no authorization decision based solely on
`profiles.role`. Global legacy role without active target membership remains
denied by the route contract and the completed real local compatibility matrix.

The target DB preserves both signatures, argument order, prepare table-return
shape, completion JSON contract, and service-role-only caller. It adds no
`tenant_id` argument. The existing server helper therefore requires no change.

NEW APP + TARGET DB: **COMPATIBLE / PASS**

### 32.7 Fresh production tenant baseline

Read-only production results:

| Check | Result |
|---|---:|
| tenants total / active / active CSK | `1 / 1 / 1` |
| memberships total | `9` |
| active admin memberships | `1` |
| active user memberships | `8` |
| other/unknown role or status | `0` |
| orphan tenant memberships | `0` |
| orphan user memberships | `0` |
| duplicate `(tenant_id,user_id)` memberships | `0` |
| events / events with null tenant | `11 / 0` |
| event registrations total | `25` |
| registered / reserve / cancelled | `6 / 1 / 18` |
| registrations with null tenant | `0` |
| active promotion claims | `0` |
| claim on non-reserve registration | `0` |
| duplicate non-null claim IDs | `0` |
| duplicate non-null promotion tokens | `0` |
| email deliveries total | `11` |
| email delivery types | `11 reservation_confirmation` |
| unknown delivery type / null tenant | `0 / 0` |

No unknown, orphan, duplicate, or promotion-state blocker exists.

### 32.8 Cross-tenant and email integrity

Fresh production checks returned zero for:

- event registration without the exact `(event_id, tenant_id)` event;
- promotion claim attached to a non-reserve registration;
- duplicate claim or promotion token;
- typed email target orphan;
- email delivery tenant mismatch;
- email delivery recipient mismatch.

The target prepare function resolves `event_id -> event.tenant_id` and limits
candidates by both event and tenant. The target completion function follows and
locks `claim -> registration -> event -> tenant`, then updates with the exact
registration, event, tenant, and claim predicates. No cross-tenant email intent
or duplicate final outbound intent is introduced.

TENANT INTEGRITY: **PASS**

EMAIL TENANT CONSISTENCY: **PASS**

### 32.9 Prepare and complete flow review

Prepare remains service-only and stable FIFO by `created_at, id`. It preserves
multiple-notification behavior, token reuse, 24-hour token expiry, 10-minute
claim expiry, attempt counters, and the existing result shape. It writes claim
state only to the exact same-tenant registration and does not rely on the CSK
default as an authorization mechanism.

Complete revalidates registration existence, event binding, tenant equality,
claim identity and expiry before any update. Success and failure paths are
idempotent; wrong, expired, detached, or replayed claims fail closed. Provider
completion records technical delivery outcome only and cannot restore a
cancelled registration, activate an event, change capacity, or bypass the
authoritative confirmation writer.

### 32.10 FIFO, multiple notifications, and first-confirmed-wins

The migration does not change candidate order, batch size, token TTL, claim TTL,
or the separate confirmation/capacity writer. Existing local evidence remains:

- focused SQL: 36/36 PASS;
- two eligible reserve candidates prepared in stable FIFO order;
- concurrent prepare: PASS;
- same-claim concurrent/double completion: PASS;
- one free slot with multiple notified candidates: exactly one confirmation;
- capacity exceeded: false;
- cancellation and event-deactivation races: PASS;
- cross-tenant concurrency: PASS;
- deadlocks: `0`;
- broken invariants: `0`;
- duplicate final effects: `0`.

No production race or real promotion was executed.

### 32.11 Compatibility defaults and writer behavior

All seven temporary CSK defaults remain present on:

- `shooting_lanes`;
- `reservations`;
- `lane_blocks`;
- `events`;
- `event_lanes`;
- `event_registrations`;
- `email_deliveries`.

2C-2 removes none of them. The promotion functions do not insert a new
tenant-owned row: prepare derives event tenant and updates an already-owned
registration; complete independently rederives registration/event tenant.
The existing 2C-1 `prepare_confirmation_email` writer continues to derive and
write `email_deliveries.tenant_id` explicitly. Defaults are compatibility
bridges, not security mechanisms.

### 32.12 Other-function, app, RLS, and policy freeze

The current production non-target function fingerprint was captured as
`aed0dcd0a4aa5522a3b86bf649d21d99`; the current non-target definer-body
fingerprint is `f51296e80c405eb34ab566fdb47efa20`. The migration snapshots these
surfaces before replacement and rejects any before/after drift.

Static scope review confirms the migration changes only the two target
functions. It contains zero policy changes, zero table/default changes, and
zero application changes. Tenant memberships, public event readers, event
management RPCs, confirmation-email 2C-1 RPCs, and all compatibility defaults
remain frozen.

### 32.13 Runtime baseline

Read-only production checks returned HTTP 200 for `/`, `/login`, `/account`,
`/events`, and `/booking`. Anonymous `/admin` and `/admin/events` returned the
expected 307 login redirect. In an existing authenticated session, Account,
Admin, Admin Events, Events, and Booking rendered their expected UI with no
application-error signal. No 5xx was observed.

No real promotion, claim, registration update, provider call, or email was
created by this preflight.

### 32.14 Dry-run

Only after the earlier gates passed, the following read-only deployment preview
was executed:

`supabase db push --linked --dry-run`

Result:

`Would push these migrations: 20260914150000_harden_event_reserve_promotion_rpcs.sql`

Exactly one migration was listed. No push was executed. The only warning was an
optional Supabase CLI update (`2.109.1` installed, `2.117.0` available); the CLI
was not changed and this is not a deployment blocker.

### 32.15 Deployment risk

| Risk | Rating | Assessment |
|---|---|---|
| DEFINER -> INVOKER | MEDIUM | safe only because exact production service-role privileges passed |
| service-role permission regression | LOW | all required capabilities are present |
| reserve-promotion regression | MEDIUM | two live service functions change internally |
| FIFO / notification count | LOW | ordering and batch semantics unchanged and tested |
| first-confirmed-wins / capacity | LOW | separate atomic writer unchanged; concurrency passed |
| email delivery | MEDIUM | outbound orchestration depends on claim completion, so immediate monitoring is required |
| endpoint/DB compatibility | LOW | unchanged signatures, argument order, and return contracts |
| cross-tenant escape | LOW in target | event, registration, tenant, and claim are independently bound |

Overall deployment risk is **MEDIUM**. A low-traffic window is sufficient; a
full maintenance window is not required because the migration replaces two
functions and performs no table rewrite or data backfill. STOP if the frozen
SHA, pending set, baseline fingerprints, 72-count, service-role rights, or
tenant invariants differ immediately before an authorized push.

### 32.16 Remaining blockers and verdict

The technical production preflight is complete. The remaining blocker is a
separate explicit authorization for the actual linked DB push. After any future
authorized deployment, immediate postflight must verify migration history,
target fingerprints, INVOKER/SP1 metadata, service-only ACL, definer count 70,
all data/default invariants, runtime behavior, and zero fixture.

SAAS-9D-2C-2 DB PRODUCTION PREFLIGHT: **PASS**

PRODUCTION STATE NEW APP + OLD DB: **PASS**

SHA: **PASS**

MIGRATION HISTORY: **PASS**

RPC FINGERPRINTS: **2/2 PASS**

SECURITY INVOKER TARGET: **PASS**

SERVICE_ROLE CAPABILITY: **PASS**

TARGET ACL: **PASS**

ENDPOINT + TARGET DB COMPATIBILITY: **PASS**

TENANT INTEGRITY: **PASS**

FIFO: **PASS**

MULTIPLE NOTIFICATIONS: **PASS**

FIRST-CONFIRMED-WINS: **PASS**

EMAIL TENANT CONSISTENCY: **PASS**

EXPECTED SECURITY DEFINER COUNT: **70**

READY FOR DB PRODUCTION PUSH: **YES**

READY FOR SAAS-9D-3: **NO-GO until 2C-2 DB production PASS and final checkpoint**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## 31. APP-FIRST PRODUCTION DEPLOYMENT

### 31.1 Commit and push

The dedicated APP-first commit was created with exactly the approved two-file scope:

- `app/api/send-event-reserve-promotion/route.ts`
- `app/api/send-event-reserve-promotion/route.test.mjs`

Commit:

`bc87cda6fc85ff371e6da7d91a40fb42ce11100c — SAAS-9D-2C-2 harden reserve promotion endpoint`

The push to `origin/main` completed as an ordinary fast-forward. A post-push fetch confirmed:

- LOCAL HEAD: `bc87cda6fc85ff371e6da7d91a40fb42ce11100c`
- REMOTE `origin/main`: `bc87cda6fc85ff371e6da7d91a40fb42ce11100c`
- divergence: `0 behind / 0 ahead`

No migration, SQL test, report, plan, or `AGENTS.md` change was included in the commit.

### 31.2 Vercel deployment

GitHub/Vercel commit status for the production project `csk-booking-5nwh` reports `success` with `Deployment has completed`. The separate Vercel project named `csk-booking` reports a failed deployment, but it is not the production application URL under verification and does not affect `https://csk-booking-5nwh.vercel.app`.

APP PRODUCTION DEPLOY: **PASS**

### 31.3 Production DB remains PRE-2C-2

A post-deployment read-only `supabase migration list --linked` confirmed:

- LOCAL = REMOTE through `20260914100000`;
- `20260914150000_harden_event_reserve_promotion_rpcs.sql` remains local-only;
- no 2C-2 database migration was executed during the APP-first deployment.

The frozen migration SHA-256 remains:

`A9373F9BCFBB456624720FB2AFFB94A416C428454B7881E6FB2649F21ED39759`

PRODUCTION DB STILL PRE-2C-2: **YES**

### 31.4 Runtime and endpoint verification

Post-deployment production checks were read-only or deliberately rejected before any service/provider path:

| Surface | Result |
|---|---|
| `/` | HTTP 200 |
| `/login` | HTTP 200 |
| `/events` | HTTP 200; public Events UI rendered |
| `/booking` | HTTP 200; public booking UI rendered |
| `/account` | HTTP 200; authenticated account UI rendered |
| `/admin` | anonymous 307 to login; authenticated admin dashboard rendered |
| `/admin/events` | anonymous 307 to login; authenticated event-management UI rendered |
| anonymous `POST /api/send-event-reserve-promotion` | controlled HTTP 401 with stable `Unauthorized` response |
| unsupported `GET /api/send-event-reserve-promotion` | HTTP 405 |

No 5xx was observed. No real event ID was submitted, the service helper/provider path was not reached, no reserve promotion was performed, and no email was sent.

The deployed commit is the SHA-verified implementation whose focused route suite passed 5/5 and whose full Node suite passed 739/739. Its server-side authorization order derives tenant authority from the authenticated event row, checks active `admin`/`employee` membership with `has_tenant_role_v1`, and only then permits the unchanged service helper to call the service-only legacy RPCs. It contains no `profiles.role` authorization branch.

### 31.5 NEW APP + OLD PROD DB

**PASS.** The production application now runs the APP-first commit while production DB migration history remains PRE-2C-2. The route continues to use the unchanged helper and legacy function signatures verified during preflight. Public Events, Booking, Account/Login, Admin, and Admin Events remain operational.

The production test deliberately did not invoke a real promotion. Authorization negatives requiring synthetic membership fixtures remain covered by the real local APP-first compatibility matrix: active tenant administrator allowed, global legacy administrator without active membership denied, inaccessible tenant event denied, malformed request denied, and unknown event denied. No production write was required to verify the rollout bridge.

### 31.6 Working tree and remaining DB rollout

The APP-first route files are clean because they are committed. All database migration/test work, the implementation report, the hardening plan, and the unrelated `AGENTS.md` change remain outside the commit and unstaged. `git diff --check` passes; the reported CRLF notices are informational.

The next permitted step is a separate read-only 2C-2 DB production preflight. It must reconfirm the single pending migration, frozen SHA, target fingerprints, ACL, SECURITY DEFINER inventory, compatibility defaults, and data invariants. A production DB push remains prohibited until that preflight passes and receives separate explicit approval.

APP-FIRST COMMIT: **PASS**

APP-FIRST PUSH: **PASS**

APP PRODUCTION DEPLOY: **PASS**

PRODUCTION DB STILL PRE-2C-2: **YES**

NEW APP + OLD PROD DB: **PASS**

ENDPOINT AUTHORIZATION: **PASS**

GLOBAL ROLE BYPASS: **REMOVED**

SERVICE_ROLE BOUNDARY: **PASS**

SAFE RUNTIME SMOKE: **PASS**

REAL PROMOTION MUTATIONS: **0**

READY FOR 2C-2 DB PRODUCTION PREFLIGHT: **GO**

READY FOR DB PRODUCTION PUSH: **NO**

READY FOR SAAS-9D-3: **NO-GO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## 33. DB production deployment and post-deploy verification

Verification date: 2026-09-14 (Europe/Warsaw)

### 33.1 Deployment result

The approved migration was applied with `supabase db push --linked`:

- `20260914150000_harden_event_reserve_promotion_rpcs.sql`
- frozen SHA-256: `A9373F9BCFBB456624720FB2AFFB94A416C428454B7881E6FB2649F21ED39759`
- Supabase CLI result: migration applied and `Finished supabase db push.`
- no other migration was applied;
- no migration repair or manual production DDL/DML was used.

### 33.2 Migration history and final dry-run

- production migration history: LOCAL = REMOTE through `20260914150000` — **PASS**;
- final `supabase db push --linked --dry-run`: `Remote database is up to date.` — **PASS**.

### 33.3 Target RPC metadata and ACL

Production catalog inspection returned:

| RPC | Normalized fingerprint | Security | Owner | search_path | PUBLIC | anon | authenticated | service_role |
|---|---|---|---|---|---:|---:|---:|---:|
| `prepare_event_reserve_promotions(uuid)` | `cdc7abeb7f8ced41cde0f5524a8953ef` | INVOKER | postgres | `pg_catalog, public, pg_temp` | DENY | DENY | DENY | ALLOW |
| `complete_event_reserve_promotion(uuid,uuid,boolean,text)` | `2c78ac26c5c55df3aac54360b610d39b` | INVOKER | postgres | `pg_catalog, public, pg_temp` | DENY | DENY | DENY | ALLOW |

Both signatures are unchanged and exactly match the approved target definitions.

### 33.4 Function drift and compatibility bridge

- public `SECURITY DEFINER` count: **70**;
- non-target function fingerprint: `aed0dcd0a4aa5522a3b86bf649d21d99`, unchanged from pre-deploy;
- other-definer fingerprint: `f51296e80c405eb34ab566fdb47efa20`, unchanged from pre-deploy;
- unexpected function drift: **0**;
- compatibility defaults: **7/7** unchanged.

### 33.5 Tenant and service-role boundaries

Production evidence:

- `service_role` has the required bounded INVOKER capabilities on `events`, `event_registrations`, and `email_deliveries`;
- PUBLIC, anon, and authenticated cannot execute either service RPC;
- registration-to-event tenant mismatches: **0**;
- email deliveries with null tenant: **0**;
- unknown email message types: **0**;
- global `profiles.role` is not consulted by either migrated RPC;
- tenant/resource/registration binding remains enforced by the deployed definitions.

Result: RPC tenant isolation **PASS**, global-role bypass **REMOVED**, service-role boundary **PASS**, email tenant consistency **PASS**.

### 33.6 FIFO, multi-notification and replay properties

The deployed fingerprints exactly match the locally verified migration. Focused SQL and concurrency verification established:

- stable FIFO ordering by `created_at, id`;
- multiple notifications only up to available capacity;
- row locking and re-checks implement first-confirmed-wins;
- claim-id, registration-id, tenant and state binding reject stale or replayed completion;
- idempotent completion prevents duplicate effects.

Production postflight found active claims **0**, claims on non-reserve rows **0**, duplicate claim IDs **0**, and duplicate promotion tokens **0**. No heavy production stress test and no real promotion email were executed.

### 33.7 Application and endpoint runtime

The APP-first endpoint remains the version from commit `bc87cda6fc85ff371e6da7d91a40fb42ce11100c`. After the DB deployment:

- `/`, `/login`, `/account`, `/events`, and `/booking`: HTTP 200;
- anonymous `/admin` and `/admin/events`: fail closed with HTTP 307 to login;
- anonymous reserve-promotion POST: HTTP 401 with stable `Unauthorized` response;
- authenticated Account, Admin, Admin Events, Events and Booking rendered without runtime or console errors;
- no production mutation was required for runtime smoke.

Production compatibility state: **NEW APP + NEW DB — PASS**.

### 33.8 Fixture and repository verification

- no production fixture was created;
- marker post-check: events **0**, event registrations **0**, profiles **0**;
- remaining synthetic fixture: **0**;
- `git diff --check`: **PASS** (line-ending notices only, no whitespace errors);
- no file was staged, committed, or pushed during DB deployment/postflight.

### 33.9 Final checkpoint scope

Include in the final SAAS-9D-2C-2 checkpoint:

1. `SAAS_9D_RPC_SECURITY_DEFINER_HARDENING_PLAN.md`
2. `SAAS_9D_2C2_RESERVE_PROMOTION_RPC_HARDENING_REPORT.md`
3. `supabase/migrations/20260914150000_harden_event_reserve_promotion_rpcs.sql`
4. `supabase/tests/20260914150000_harden_event_reserve_promotion_rpcs_test.sql`
5. `supabase/tests/20260914150000_harden_event_reserve_promotion_rpcs_concurrency.ps1`
6. `supabase/tests/20260911100000_tenant_aware_events_rls_test.sql`
7. `supabase/tests/20260912100000_harden_event_registration_rpcs_test.sql`
8. `supabase/tests/20260913100000_harden_event_management_rpcs_test.sql`
9. `supabase/tests/20260913150000_harden_public_event_readers_test.sql`
10. `supabase/tests/20260914100000_harden_shared_confirmation_email_rpcs_test.sql`

Explicitly exclude `AGENTS.md`. No temporary production-test file remains.

SAAS-9D-2C-2 DB PRODUCTION DEPLOY: **PASS**

SAAS-9D-2C-2 POST-DEPLOY: **PASS**

PRODUCTION STATE NEW APP + NEW DB: **PASS**

SECURITY DEFINER COUNT: **70**

RPC TENANT ISOLATION: **PASS**

GLOBAL ROLE BYPASS: **REMOVED**

SERVICE_ROLE BOUNDARY: **PASS**

FIFO: **PASS**

MULTIPLE NOTIFICATIONS: **PASS**

FIRST-CONFIRMED-WINS: **PASS**

EMAIL TENANT CONSISTENCY: **PASS**

READY FOR FINAL GIT CHECKPOINT: **YES**

READY FOR SAAS-9D-3 PLANNING: **GO**

READY FOR SAAS-9D-3 IMPLEMENTATION: **NO-GO until checkpoint/review**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## 30. PRODUCTION APP PREFLIGHT — APP FIRST

### 30.1 Working tree classification

`git status --short`, `git diff --name-only`, and `git ls-files --others --exclude-standard` report 13 paths: 12 belong to SAAS-9D-2C-2 and one is unrelated.

| Classification | Files |
|---|---|
| APP-FIRST | `app/api/send-event-reserve-promotion/route.ts`; `app/api/send-event-reserve-promotion/route.test.mjs` |
| DB-MIGRATION | `supabase/migrations/20260914150000_harden_event_reserve_promotion_rpcs.sql` |
| TEST | `supabase/tests/20260914150000_harden_event_reserve_promotion_rpcs_test.sql`; `supabase/tests/20260914150000_harden_event_reserve_promotion_rpcs_concurrency.ps1`; downstream expectation updates in `20260911100000_tenant_aware_events_rls_test.sql`, `20260912100000_harden_event_registration_rpcs_test.sql`, `20260913100000_harden_event_management_rpcs_test.sql`, `20260913150000_harden_public_event_readers_test.sql`, and `20260914100000_harden_shared_confirmation_email_rpcs_test.sql` |
| REPORT/DOC | `SAAS_9D_RPC_SECURITY_DEFINER_HARDENING_PLAN.md`; this implementation report |
| UNRELATED | `AGENTS.md` — automatic Next.js agent-instruction update |

There is no second unrelated file. `git diff --check` passes; CRLF conversion notices are informational and are not whitespace errors.

### 30.2 Exact APP-first files

The production APP-first commit must contain exactly:

1. `app/api/send-event-reserve-promotion/route.ts`
2. `app/api/send-event-reserve-promotion/route.test.mjs`

No migration, SQL test, concurrency harness, report, plan, `AGENTS.md`, or other file belongs in this deployment commit.

### 30.3 AGENTS.md exclusion

`AGENTS.md` is not part of SAAS-9D-2C-2 and must remain unstaged for the APP-first commit and the later 2C-2 checkpoint unless separately reviewed and authorized.

AGENTS.md INCLUDED IN 2C-2: **NO**

### 30.4 Current production DB contracts

A live read-only `supabase migration list --linked` and schema dump were performed on 2026-09-14. Production is still PRE-2C-2:

- LOCAL = REMOTE through `20260914100000`;
- `20260914150000` is local-only and pending;
- `prepare_event_reserve_promotions(uuid)` exists with the unchanged table return shape, `SECURITY DEFINER`, owner `postgres`, and SP2 `public, pg_temp`;
- `complete_event_reserve_promotion(uuid,uuid,boolean,text default null)` exists with the unchanged JSON return shape, `SECURITY DEFINER`, owner `postgres`, and SP2 `public, pg_temp`;
- both functions revoke PUBLIC and grant only `service_role`; no client EXECUTE was found.

The live definitions match the frozen PRE-2C-2 semantics and the normalized fingerprints captured in the completed 2C-1 production postflight: prepare `4e73ef1df59936a1a3f41a00e121f6e9`, complete `dd5025876008d6eb9551497d84cef90e`. No migration later than 2C-1 has been applied. The temporary read-only schema dump was removed after inspection.

### 30.5 NEW APP + OLD PROD DB compatibility

**PASS.** The new route calls the same `promoteEventReserve(eventId)` helper and the same two function signatures. Real local APP-FIRST testing against the reconstructed old DB returned `200` for a valid active Tenant-A administrator, `403` for a legacy global administrator without active membership, `404` for an inaccessible Tenant-B event, `400` for malformed input, and `404` for an unknown event. Fixture cleanup was zero.

The production DB still exposes exactly the old signatures and response shapes consumed by this helper, so deploying only the two APP-first files does not require the migration.

### 30.6 Endpoint authorization order

The final route order is:

1. parse Bearer token and authenticate through `verifyAuthUser`;
2. parse a body containing exactly one `eventId` and validate UUID shape;
3. fetch only `events.id, events.tenant_id` through the authenticated caller;
4. derive tenant authority from that returned event row;
5. call `has_tenant_role_v1` for that tenant;
6. require an active `admin` or `employee` membership;
7. only then invoke `promoteEventReserve(eventId)`, which owns the service-role/RPC work.

There is no service operation before business authorization.

### 30.7 Global-role negative case

The route contains no `profiles` query and no `profiles.role = admin/pracownik` decision. A caller with a global legacy admin profile but without an active membership in the event tenant is denied. The real APP-FIRST local HTTP check returned `403` for this case.

GLOBAL ROLE BYPASS: **REMOVED**

### 30.8 Cross-tenant authorization

Admin A and Employee A can act only on an event readable in Tenant A and only while their active membership has an allowed role. Event B is inaccessible/denied. Pending, suspended, absent, user, and instructor memberships are not accepted by the `has_tenant_role_v1(..., ['admin','employee'])` gate. Instructor scope is unchanged.

The route deliberately returns controlled `403` or not-found behavior without disclosing Tenant-B membership or resource details.

### 30.9 Input validation

- missing Bearer session -> controlled `401`;
- Auth service/upstream error -> existing safe `503`/`500` classifier contract, never a false allow;
- malformed JSON, additional keys, missing ID, or malformed UUID -> controlled `400`;
- unknown or caller-inaccessible event -> controlled `404`;
- active membership with an unapproved role, pending/suspended/no membership -> controlled `403`;
- unsupported GET -> framework `405`;
- duplicate requests remain protected by the existing prepare claim/idempotency contract;
- inactive/stale event handling is unchanged by APP-FIRST: neither the legacy prepare function nor the approved new contract invents a new activation rule in this phase; capacity, reserve status, active claims, sent state, and claim TTL remain authoritative.

No error returns tenant, membership, registration, recipient, claim, or token details.

### 30.10 Service-role boundary

`AUTHENTICATED CALLER -> EVENT -> EVENT TENANT -> ACTIVE MEMBERSHIP -> ADMIN/EMPLOYEE ROLE -> SERVICE HELPER -> SERVICE-ONLY RPC`

The caller cannot supply `tenant_id`, membership, recipient, registration, or claim authority. The existing server helper is unchanged and is reached only after the route gate.

### 30.11 Old DB transition risk

The legacy prepare function locks and scopes candidates by the exact `p_event_id`, preserves stable FIFO `created_at, id`, and returns only claims for that event. The legacy complete function locks the exact registration and verifies the active claim ID before changing delivery bookkeeping. Because the new route has already authorized the exact event and passes only that ID, the old functions do not undo the endpoint membership decision.

Residual during the APP-FIRST interval: the old RPC bodies do not yet independently enforce tenant equality and still run as definers. This is compensated for the manual path by the new route, while the trusted cancellation path continues to use the event ID returned by its controlled cancellation RPC. The interval is accepted only as a short deployment bridge; the DB migration must follow after app verification.

### 30.12 Test evidence

Re-run for this production app preflight:

- focused route tests: 5/5 PASS;
- full Node suite: 739/739 PASS;
- TypeScript `tsc --noEmit`: PASS;
- production Next.js build: PASS;
- changed application files ESLint: PASS;
- `git diff --check`: PASS.

Previously completed compatibility evidence remains valid and SHA-bound:

- NEW APP + OLD DB: PASS;
- NEW APP + NEW DB: PASS;
- focused SQL 36/36, full DB 972/972, concurrency, and full Playwright 30/30: PASS.

The known Next.js middleware-to-proxy warning is unchanged and unrelated.

### 30.13 Production runtime baseline

Read-only production checks completed without creating an event, claim, registration, or email:

| Surface | Evidence |
|---|---|
| Login | `/login` HTTP 200 |
| Account | HTTP 200 shell and authenticated account UI rendered |
| Admin | anonymous HTTP redirect to login; authenticated admin dashboard rendered |
| Admin Events | anonymous HTTP redirect; authenticated event-management UI and lane data rendered |
| Events | HTTP 200; public bounded event view rendered |
| Booking | HTTP 200; public lane selection rendered |
| Promotion endpoint | anonymous POST `{}` returned controlled 401; GET returned 405; no service/provider path was reached |

No 5xx was observed. No production promotion was attempted and no email was sent.

### 30.14 Deployment mechanism

The repository is on `main` at `8c781b2c67233f865407abe1318534f57ef86040`, tracking `origin/main` with no divergence. `origin` is the GitHub repository used by the established Vercel production integration. There is no repository-local manual Vercel deployment configuration or GitHub deployment workflow requiring a different command. Therefore the safe mechanism is a dedicated ordinary commit on `main`, followed by a separately authorized fast-forward push to `origin/main`, which triggers the Vercel app deployment.

No commit, push, or deployment was performed in this preflight.

### 30.15 Proposed APP-first commit

Proposed scope only:

- `app/api/send-event-reserve-promotion/route.ts`
- `app/api/send-event-reserve-promotion/route.test.mjs`

Proposed message: `SAAS-9D-2C-2 harden reserve promotion endpoint`

Before a future authorized commit, staging must be inspected with `git diff --cached --name-only` and must contain exactly these two paths. `git add .` and `git add -A` must not be used.

### 30.16 DB migration SHA freeze

The migration was not modified during this preflight.

`20260914150000_harden_event_reserve_promotion_rpcs.sql`

SHA-256: `A9373F9BCFBB456624720FB2AFFB94A416C428454B7881E6FB2649F21ED39759` — **PASS**

No `db push`, migration repair, database DML, or DDL was executed.

### 30.17 Remaining blockers

- explicit authorization is still required to stage and create the two-file APP-first commit;
- explicit authorization is still required to push that commit and trigger Vercel;
- after deployment, NEW APP + OLD PROD DB must be verified before any DB write;
- a separate DB production preflight must prove fingerprints, ACL, invariants, the only pending migration, and the frozen SHA;
- a separate explicit approval is required for `supabase db push --linked`;
- production postflight and a final checkpoint remain required before SAAS-9D-3.

SAAS-9D-2C-2 PRODUCTION APP PREFLIGHT: **PASS**

WORKING TREE CLASSIFICATION: **PASS**

APP-FIRST FILE SCOPE: **PASS**

AGENTS.md EXCLUDED: **YES**

NEW APP + OLD PROD DB: **PASS**

ENDPOINT TENANT AUTHORIZATION: **PASS**

GLOBAL ROLE BYPASS: **REMOVED**

SERVICE_ROLE BOUNDARY: **PASS**

CROSS-TENANT ENDPOINT ISOLATION: **PASS**

CALLER / RPC COMPATIBILITY: **PASS**

DB MIGRATION SHA: **PASS**

READY FOR APP-FIRST PRODUCTION DEPLOY: **YES**

READY FOR DB PRODUCTION PUSH: **NO**

READY FOR SAAS-9D-3: **NO-GO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**
