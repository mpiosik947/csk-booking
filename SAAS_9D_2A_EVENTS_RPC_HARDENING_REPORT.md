# SAAS-9D-2A — Events RPC hardening report

## 1. Executive summary

The approved local-only phase is complete. Seven event-registration RPCs now authorize against active tenant membership derived from their target resource. No caller supplies or selects a tenant, no public read contract changed, and no production operation was performed.

## 2. Exact 2A function scope

| Function | Signature | Runtime callers | Tenant source |
|---|---|---|---|
| `register_for_event` | `(uuid, boolean)` | `/api/register-event` | `events.tenant_id` from event ID |
| `cancel_event_registration` | `(uuid)` | `/api/cancel-event-registration` | `event_registrations.tenant_id` |
| `approve_event_registration` | `(uuid)` | `/admin/events` | `event_registrations.tenant_id` |
| `mark_event_registration_paid` | `(uuid)` | `/admin/events` | `event_registrations.tenant_id` |
| `confirm_event_reserve_promotion` | `(text)` | `/api/confirm-event-reserve-promotion` | registration located by promotion token |
| `get_my_event_registrations_v1` | `(text,text,integer,integer)` | `/my-events` | each owned registration plus active membership |
| `admin_list_event_registrations_v1` | `(uuid,text,text,integer,integer)` | `/admin/events` | `events.tenant_id` from event ID |

Event management/public-reader functions (2B) and promotion/e-mail claim functions (2C) were not changed.

## 3. Pre-change fingerprints

Normalized CRLF/CR-to-LF MD5 guards:

| Signature | Fingerprint |
|---|---|
| admin participant list | `ed5fe967179ec6c60590ce7b75722242` |
| approve | `504923e851372eb41daa128f324763aa` |
| cancel | `9776e23faf4205f569fb7ab024aed1cc` |
| confirm promotion | `c8725ce4a78d2fa5294e1fa61b827314` |
| my events | `1b0235278e128425bdbe54ac02ffc040` |
| mark paid | `e97f15b3013b296895594c6a48447efb` |
| register | `c59b5c42cc718d7370a8a4ee8a42f750` |

Owner, definer and effective ACL are also preflight-guarded. The migration uses one transaction; any mismatch rolls back everything.

## 4. Tenant derivation

Tenant is obtained only from the event, registration, or token-resolved registration. `register_for_event` writes `v_event.tenant_id` explicitly. Existing composite tenant/event integrity remains authoritative.

## 5. Owner authorization

Registration cancellation requires `auth.uid() = registration.user_id` unless the caller has an allowed staff membership. Promotion confirmation requires token ownership and active membership. Foreign same-tenant and cross-tenant IDs fail closed.

## 6. Staff authorization

Approve and payment require active `admin` or `employee` membership in the target tenant. Participant list preserves the existing `admin`/`employee`/`instructor` matrix. Pending, suspended, missing membership, and a global admin profile without target membership are denied.

## 7. Public contract

`get_public_event_list_v2` and `get_public_event_availability_v1` were not modified. Anon public listing remains available and PII-free; availability remains backend-authoritative.

## 8. Claim/concurrency behavior

The frozen business cores retain event locking, active-registration uniqueness, reserve ordering and atomic promotion. A real two-session local race against capacity 1 produced exactly one registered row and one reserve row. The focused test also proves cancel/promotion transitions and authoritative post-transition counts.

## 9. Email side effects

No delivery/claim function is in 2A. The cancellation return contract remains compatible with the existing reserve-promotion caller. E-mail claim tenant binding remains explicitly deferred to 2C.

## 10. Grants/search_path

The seven public wrappers are postgres-owned `SECURITY DEFINER`, `search_path=pg_catalog, public, pg_temp`, with EXECUTE only for `authenticated`. Their seven `SECURITY INVOKER` cores have no grants for `PUBLIC`, `anon`, `authenticated`, or `service_role`. Total public-schema definers remain 73.

## 11. Caller compatibility

All seven signatures, defaults and JSON contracts are retained. No application file required modification. A registration whose event is missing still reaches the frozen core and returns its existing controlled `event_not_found` result.

Compatibility matrix:

| App | DB | Result |
|---|---|---|
| old | old | current production behavior |
| old | new | safe for the already-backfilled active CSK memberships |
| new | old | unchanged; no app change in 2A |
| new | new | tenant-bounded single-active-tenant behavior |

## 12. Temporary CSK defaults

| Table | Writer now explicit? | Still uses default? | Removal gate |
|---|---|---|---|
| `event_registrations` | yes, `register_for_event` | no for the hardened create path | 9D-5/9E before second tenant |
| `audit_logs` | yes for approve/cancel/payment | no default exists | none |
| `events`, `event_lanes`, `email_deliveries` | outside 2A | unchanged | later approved phase |

No temporary default was removed.

## 13. Cross-tenant tests

Focused SQL: 32/32 PASS. Coverage includes public access, User A owner/foreign/cross-tenant cases, Admin A, Employee A, Instructor A current scope, pending/suspended/no membership, global-role bypass, token ownership, participant PII boundary, explicit tenant writes, grants, core isolation, defaults, and 2B/2C fingerprint preservation. Fixture post-check is zero.

## 14. Regression

- local reset: PASS;
- Supabase DB: 28 files, 820 tests, PASS;
- registration concurrency: PASS, fixture cleanup 0;
- Node: 734/734 PASS;
- TypeScript: PASS;
- Next.js production build: PASS (known middleware-to-proxy warning only);
- Playwright: 14/14 PASS for Events, My Events, Admin Events, cancellation/Booking and admin lane-family smoke;
- `git diff --check`: reported separately at final handoff.

## 15. Deferred 2B/2C functions

2B retains public event list/availability and admin event create/update/activate/list. 2C retains promotion prepare/complete and shared confirmation e-mail claims. No route/helper change was made.

## 16. Production deployment plan

Production remains gated. Preflight must verify the exact seven normalized fingerprints, owners, ACL, active CSK membership completeness, migration history, SHA-256 and a dry run showing only `20260912100000`. After explicit approval, deploy DB first, verify wrapper/core inventory and execute rollback-only Tenant A/B checks, then run Events/My Events/Admin Events operational smoke. Stop on any fingerprint, membership, ACL, count, or fixture mismatch.

## 17. Git status

The implementation is intentionally uncommitted. No `git add`, commit or push was performed. The exact final status is captured in the handoff.

## 18. Final verdict

SAAS-9D-2A LOCAL: **PASS**

EVENT RPC TENANT ISOLATION: **PASS**

GLOBAL ROLE BYPASS: **REMOVED**

OWNER OPERATIONS: **PASS**

STAFF OPERATIONS: **PASS**

PUBLIC EVENT CONTRACT: **PASS**

CONCURRENCY / CLAIMS: **PASS**

CALLER COMPATIBILITY: **PASS**

READY FOR SAAS-9D-2A PRODUCTION PREFLIGHT: **GO**

READY FOR SAAS-9D-2B: **NO-GO until review**

READY FOR PRODUCTION WRITE: **NO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## 19. PRODUCTION DEPLOYMENT & POST-DEPLOY VERIFICATION

Production deployment and post-deploy verification completed on 2026-09-13 against project `yuyxfodozzpzrdzkmolu`. The only applied migration was `20260912100000_harden_event_registration_rpcs.sql`, with the approved SHA-256:

`24F31584FA69C4A29CB97680FDF24B2B8FC9F3142818629BDFE0812783AE248F`

### 19.1 Deployment and migration history

The final pre-push gates remained unchanged immediately before deployment: the seven production definitions matched their frozen normalized baselines, unrelated SECURITY DEFINER inventory matched, tenant/membership/event consistency checks were zero, and the dry run listed only `20260912100000`. `supabase db push --linked` applied that one migration successfully.

After deployment, `supabase migration list --linked` showed `20260912100000` as LOCAL=REMOTE. A fresh `supabase db push --linked --dry-run` returned `Remote database is up to date`; there are no additional pending or remote-only migrations.

### 19.2 Seven RPC definitions, ownership, paths and grants

All seven deployed public wrappers retain their exact signatures, are owned by `postgres`, are `SECURITY DEFINER`, use `search_path=pg_catalog, public, pg_temp`, deny PUBLIC/anon/service-role EXECUTE and allow authenticated EXECUTE. Their production normalized fingerprints are the approved targets:

| RPC | Production fingerprint |
|---|---|
| `register_for_event(uuid,boolean)` | `f9053609c0e1f358bc5c1925a48f004e` |
| `cancel_event_registration(uuid)` | `5c45f09d89167548262908f84690f6f4` |
| `approve_event_registration(uuid)` | `4e4e9b3584ab4e4a28b94ab56f20a46f` |
| `mark_event_registration_paid(uuid)` | `3e4ba58f3265e8871430e3a36b728a97` |
| `confirm_event_reserve_promotion(text)` | `958126489f5770e01b89fa1abadd3c0d` |
| `get_my_event_registrations_v1(text,text,integer,integer)` | `45402cdc21696681417c0ee8215cb8cf` |
| `admin_list_event_registrations_v1(uuid,text,text,integer,integer)` | `e72a9091bc97086756ff2b29fb035d81` |

The seven `__saas9d2a_core` functions are invokers and have no PUBLIC, anon, authenticated or service-role EXECUTE. No caller-visible signature or response contract changed.

### 19.3 Tenant derivation and rollback-only authorization smoke

A production smoke reused the complete focused 32-check contract with fresh random identifiers inside one transaction. Success was deliberately signalled by `P0001: SAAS9D2A_PROD_ALL_32_PASS_ROLLBACK`, which rolled back the entire fixture. All 32 checks passed.

The smoke proves:

- tenant is derived from event, registration or token-owned registration, never from caller input;
- a global legacy `profiles.role=admin` without active membership in the target tenant is denied approval, payment marking and participant listing;
- owner access is allowed only for the owner's registration; foreign and cross-tenant IDs are denied;
- Tenant A admin/employee operations are allowed in A and denied in B;
- pending, suspended and missing memberships are denied;
- register persists the event tenant and preserves registered/reserve capacity semantics;
- cancellation remains owner-scoped and foreign/cross-tenant cancellation is denied;
- approval and paid marking require active same-tenant staff membership;
- reserve-promotion token lookup, tenant derivation, ownership, locking and idempotency remain fail-closed;
- My Events and admin participant reads remain bounded to the authenticated owner or authorized tenant staff.

### 19.4 Public contract, capacity and concurrency invariants

The rollback-only smoke confirms the public event availability contract remains callable and PII-free, with correct registered/reserve counts and non-negative capacity. No public mutation grant was added. Constraints, event locking, active-registration uniqueness, capacity accounting and reserve semantics were not changed by the migration. The previously rerun real two-session local race remains the concurrency evidence; production verification intentionally did not run a load or destructive race.

### 19.5 SECURITY DEFINER inventory and compatibility defaults

The final production inventory contains exactly 73 public SECURITY DEFINER functions. Excluding the seven approved wrappers, the remaining 66 definitions retain the expected aggregate fingerprint:

`e6509dbf8e6ab3f7f4db8a293794cb3c`

Unexpected SECURITY DEFINER drift is **0**. All seven approved temporary CSK tenant defaults remain present; 9D-2A did not remove or widen them.

### 19.6 Runtime smoke

Read-only browser smoke passed after deployment:

- public `/events` loads without membership and returns the controlled empty state without participant PII;
- `/my-events` loads the authenticated owner's list and exposes the existing event-detail, calendar and cancellation actions;
- `/admin/events?scope=all` loads event inventory and the participant-list contract;
- `/booking` loads canonical resource selection;
- `/admin` loads the operational dashboard;
- `/account` confirms the authenticated session and account flow.

No tested surface returned a 5xx or uncontrolled runtime error. Register, cancel, approve, paid marking and reserve promotion were not repeated as persistent browser mutations; their production behavior was verified by the rollback-only RPC smoke.

### 19.7 Cleanup and final data invariants

An independent post-rollback read returned zero synthetic Auth users, profiles, tenants, events, event registrations and audit rows for the SAAS-9D-2A marker. Final synthetic fixture remaining is **0**.

Post-deploy tenant invariants also pass: one active tenant, no membership anomalies, zero registration/event tenant mismatches and zero event-lane event/lane tenant mismatches.

### 19.8 Remaining blockers and final verdicts

SAAS-9D-2A is deployed and production-verified. SAAS-9D-2B implementation remains blocked until this change receives its separate checkpoint/review. Second-tenant activation remains prohibited and SEC-004 remains open.

SAAS-9D-2A PRODUCTION DEPLOY: **PASS**

SAAS-9D-2A POST-DEPLOY: **PASS**

7 RPC TENANT ISOLATION: **PASS**

GLOBAL ROLE BYPASS: **REMOVED**

OWNER AUTHORIZATION: **PASS**

STAFF AUTHORIZATION: **PASS**

PUBLIC EVENT CONTRACT: **PASS**

CONCURRENCY / CLAIMS: **PASS**

SECURITY DEFINER DRIFT: **0**

FIXTURE CLEANUP: **PASS**

READY FOR GIT CHECKPOINT: **YES**

READY FOR SAAS-9D-2B PLANNING: **GO**

READY FOR SAAS-9D-2B IMPLEMENTATION: **NO-GO until checkpoint/review**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## 20. PRE-DEPLOYMENT EVIDENCE (ARCHIVED)

This preflight was completed on 2026-09-13 against production project `yuyxfodozzpzrdzkmolu`. It was read-only. No migration, writer RPC, production DML, `db push`, migration repair, Git staging, commit or push was performed. The only deployment-related command was `supabase db push --linked --dry-run`.

### 20.1 Working tree reconciliation

The earlier count of ten files was a reporting error. The actual scope contains exactly nine files:

1. `SAAS_9D_RPC_SECURITY_DEFINER_HARDENING_PLAN.md`
2. `SAAS_9D_2A_EVENTS_RPC_HARDENING_REPORT.md`
3. `supabase/migrations/20260912100000_harden_event_registration_rpcs.sql`
4. `supabase/tests/20260912100000_harden_event_registration_rpcs_test.sql`
5. `supabase/tests/20260912100000_harden_event_registration_rpcs_concurrency.ps1`
6. `supabase/tests/20260816130000_secure_event_reserve_confirmation_post_test.sql`
7. `supabase/tests/20260816143000_harden_public_function_execute_acl_test.sql`
8. `supabase/tests/20260903100000_harden_audit_log_integrity_test.sql`
9. `supabase/tests/20260911100000_tenant_aware_events_rls_test.sql`

There is no tenth, temporary or unrelated file. Branch is `main`; preflight HEAD is `d8fe265ccd00b607b3dc99cc53f5c2320c40cc08`. `git diff --check` passes; the only messages are line-ending conversion notices for existing tracked files.

### 20.2 Migration SHA-256 and exact scope

`supabase/migrations/20260912100000_harden_event_registration_rpcs.sql`:

`24F31584FA69C4A29CB97680FDF24B2B8FC9F3142818629BDFE0812783AE248F`

The migration was not modified after this hash or after the full local test evidence. Static DDL inspection confirms that it renames/replaces exactly the approved seven public signatures and creates only their seven private `__saas9d2a_core` counterparts. It does not alter any additional public RPC.

### 20.3 Seven-RPC production/baseline/target matrix

Fingerprints canonicalize only CRLF and lone CR to LF.

| Function | Production fingerprint | Expected baseline | Target fingerprint | Production authorization | Target authorization and tenant source | Current -> target grants | Path |
|---|---|---|---|---|---|---|---|
| `register_for_event(uuid,boolean)` | `c59b5c42cc718d7370a8a4ee8a42f750` | same | `f9053609c0e1f358bc5c1925a48f004e` | authenticated owner identity and profile/business validation | active membership; `event_id -> events.tenant_id`; explicit registration tenant | authenticated -> authenticated | SP2 -> SP1 |
| `cancel_event_registration(uuid)` | `9776e23faf4205f569fb7ab024aed1cc` | same | `5c45f09d89167548262908f84690f6f4` | owner for user/instructor; otherwise global admin/employee legacy role | registration owner or same-tenant active admin/employee; `registration_id -> event_registrations.tenant_id` | authenticated + service_role -> authenticated | SP2 -> SP1 |
| `approve_event_registration(uuid)` | `504923e851372eb41daa128f324763aa` | same | `4e4e9b3584ab4e4a28b94ab56f20a46f` | global admin/employee legacy role | active admin/employee membership in registration tenant | authenticated -> authenticated | SP2 -> SP1 |
| `mark_event_registration_paid(uuid)` | `e97f15b3013b296895594c6a48447efb` | same | `3e4ba58f3265e8871430e3a36b728a97` | global admin/employee legacy role | active admin/employee membership in registration tenant | authenticated -> authenticated | SP1 -> SP1 |
| `confirm_event_reserve_promotion(text)` | `c8725ce4a78d2fa5294e1fa61b827314` | same | `958126489f5770e01b89fa1abadd3c0d` | token registration owner | token -> registration -> tenant; owner plus active membership | authenticated -> authenticated | SP2 -> SP1 |
| `get_my_event_registrations_v1(text,text,integer,integer)` | `1b0235278e128425bdbe54ac02ffc040` | same | `45402cdc21696681417c0ee8215cb8cf` | `auth.uid()` owner rows | owner rows joined to active membership/active tenant with event-tenant equality | authenticated -> authenticated | SP1 -> SP1 |
| `admin_list_event_registrations_v1(uuid,text,text,integer,integer)` | `ed5fe967179ec6c60590ce7b75722242` | same | `e72a9091bc97086756ff2b29fb035d81` | global admin/employee/instructor legacy role | active admin/employee/instructor membership; `event_id -> events.tenant_id` | authenticated -> authenticated | SP1 -> SP1 |

`SP1` is `pg_catalog, public, pg_temp`; `SP2` is the current legacy `public, pg_temp`. Production has 7/7 exact normalized baseline matches. All seven are owned by `postgres`, are currently `SECURITY DEFINER`, have no PUBLIC or anon EXECUTE, and retain no grant widening. The target makes all wrappers SP1, keeps them postgres-owned definers and grants only authenticated. The cores are invokers with no PUBLIC/anon/authenticated/service-role EXECUTE.

### 20.4 Fresh production data baseline

- tenants: 1 total, 1 active, exactly 1 active `csk`;
- memberships: 9 total; roles `admin=1`, `user=8`; statuses `active=9`;
- unknown membership roles/statuses: 0/0;
- duplicate memberships: 0;
- orphan tenant memberships: 0;
- orphan Auth-user memberships: 0;
- events: 11; null tenant: 0;
- event registrations: 25; `registered=6`, `reserve=1`, `cancelled=18`; active reserve/waitlist: 1; null event/tenant: 0/0; missing events: 0;
- event lanes: 9; null tenant: 0; missing event/lane: 0/0;
- e-mail deliveries: 11, all `reservation_confirmation`; event-confirmation missing-target and tenant-mismatch counts: 0/0.

No PII, token value, registration identifier or user identifier was read into the report.

### 20.5 Tenant relational consistency

Production mismatch counts are all zero:

- `event_registrations.tenant_id <> events.tenant_id`: 0;
- `event_lanes.tenant_id <> events.tenant_id`: 0;
- `event_lanes.tenant_id <> shooting_lanes.tenant_id`: 0;
- missing event/lane relationships: 0.

Tenant consistency gate: **PASS**.

### 20.6 Tenant derivation and authorization contracts

No target signature accepts `tenant_id`. Register derives it from the event; owner/staff cancellation, approval and payment derive it from the registration; participant listing derives it from the event; promotion derives it from token -> registration; My Events derives it per owned row and requires active membership/tenant consistency.

Completed focused local evidence proves:

- User A own Tenant A registration: allow;
- User A foreign same-tenant and Tenant B registrations: deny;
- Admin A/Employee A operation in A: allow, in B: deny;
- pending, suspended and no-membership actors: deny;
- global `profiles.role=admin` without active target-tenant membership: deny;
- instructor gains no approval/payment/foreign-cancellation right; participant read retains only its existing role scope, now tenant-bound.

Global-role bypass is **REMOVED IN TARGET** for all seven functions.

### 20.7 Operation and claim behavior

The target keeps existing status, capacity, reserve ordering, Europe/Warsaw cancellation and response semantics. Registration explicitly persists the locked event tenant. Cancellation remains owner-scoped with the existing staff path, now tenant-bounded. Approval/payment require an active `admin` or `employee` membership for the registration tenant. Promotion keeps owner/token identity, expiry, event locking, atomic capacity and idempotency behavior while adding active membership for the token registration tenant.

No caller-supplied tenant can authorize an operation. No production mutation was used during preflight.

### 20.8 Public event contract

`get_public_event_list_v2` and `get_public_event_availability_v1` are outside this migration and remain unchanged. Public `/events` loaded successfully without membership, returned its controlled empty state and exposed no participant PII. No new public mutation grant is introduced.

### 20.9 Concurrency rerun

The required real two-session local race was rerun after production catalog verification. Result: **PASS** — exactly one `registered` and one `reserve`, correct tenant on both rows, no duplicate active registration, no deadlock or broken invariant, and `fixture_cleanup=0`.

### 20.10 Caller compatibility

Current callers remain:

- `/api/register-event` -> `register_for_event`;
- `/api/cancel-event-registration` -> `cancel_event_registration`;
- `/api/confirm-event-reserve-promotion` -> `confirm_event_reserve_promotion`;
- `/my-events` -> `get_my_event_registrations_v1`;
- `/admin/events` -> participant list, approval and paid marking.

All signatures/defaults/result contracts are unchanged. No caller passes a tenant ID and no Next.js/API change is required.

### 20.11 SECURITY DEFINER inventory

Fresh production inventory remains 73 public-schema definers. The seven production definitions match their approved baseline exactly. Excluding the seven target names, production and the fully migrated local target both contain 66 definers and have the same canonical definition/owner/security/path/ACL aggregate fingerprint:

`e6509dbf8e6ab3f7f4db8a293794cb3c`

Unexpected unrelated drift: **0**. After deployment the seven public wrapper identities remain definers, while the seven renamed cores are invokers; total definer count remains 73.

### 20.12 Temporary CSK defaults

All approved seven compatibility defaults remain present and equal the bootstrap CSK tenant ID. None is removed.

| Event-related table | Current default | 9D-2A writer explicit? | Default still technically needed? |
|---|---|---|---|
| `events` | CSK UUID bridge | not changed in 2A | yes, until 2B/tenant-aware create cutover |
| `event_lanes` | CSK UUID bridge | not changed in 2A | yes, until 2B |
| `event_registrations` | CSK UUID bridge | yes for `register_for_event` | no for this hardened create path; retain for other legacy compatibility until the removal gate |
| `email_deliveries` | CSK UUID bridge | not changed in 2A | yes, until 2C |

The unrelated defaults on `shooting_lanes`, `reservations` and `lane_blocks` are also still present. Removal remains gated before tenant-aware writer cutover and before a second tenant.

### 20.13 Migration history and dry-run

Supabase CLI 2.109.1 confirmed LOCAL=REMOTE through `20260911140000`, with no remote-only migration or divergence. The only pending migration is:

`20260912100000_harden_event_registration_rpcs.sql`

After all data, catalog, fingerprint and history gates passed, `supabase db push --linked --dry-run` succeeded and reported exactly that one migration. The first local CLI attempt did not reach the database because only the package shim had been extracted; after extracting its matching `supabase-go` 2.109.1 binary from the same official archive in `/tmp`, the definitive dry-run passed. The newer-CLI notice is informational. No push occurred.

### 20.14 Production runtime baseline

Read-only production browser checks passed for:

- public Events and public controlled empty state;
- My Events with the authenticated owner's paginated registration list;
- Admin Events in upcoming and all scopes, including event list and participant-list entry points;
- Booking configuration/resource selection;
- authenticated account/session;
- Admin dashboard and links to Reservations, Calendar, Reports, Events and Check-in.

No page produced a 5xx or uncontrolled runtime error. Registration, cancellation, approval, paid marking and promotion were not executed against production because this phase expressly prohibits writes. Their current production function definitions match the frozen baselines, their caller surfaces load, and their target behavior is covered by focused/local regression and concurrency evidence.

### 20.15 Deployment risk

| Area | Risk | Assessment |
|---|---|---|
| transactional rename/create function DDL | MEDIUM | Exact fingerprint/owner/ACL guards and 5-second lock timeout fail closed; short function catalog locks remain possible. |
| register/cancel | MEDIUM | Critical owner paths; signatures and frozen cores remain compatible, explicit tenant write and authorization tested. |
| approve/paid | MEDIUM | Operational staff mutations; target membership matrix and audit tenant binding pass. |
| reserve promotion | MEDIUM | Atomic/event-lock core preserved; owner/token/membership and idempotency tests pass. |
| concurrency | LOW | Lock order, unique constraints and reserve accounting unchanged; real race rerun passes. |
| public Events | LOW | Public readers are not modified and production page baseline passes. |
| caller compatibility | LOW | No signature or application change. |

A low-traffic window is sufficient; a maintenance window is not required by current evidence. Stop on any migration guard failure, lock timeout, unexpected migration scope or immediate Events/My Events/Admin Events regression.

### 20.16 Remaining blockers and final preflight verdict

There is no remaining SAAS-9D-2A preflight blocker. Production deployment still requires separate explicit approval. SAAS-9D-2B remains blocked until 9D-2A production PASS and checkpoint/review. Second-tenant activation remains prohibited and SEC-004 remains open.

SAAS-9D-2A PRODUCTION PREFLIGHT: **PASS**

WORKING TREE SCOPE: **PASS**

NORMALIZED FINGERPRINTS: **7/7 PASS**

FINAL RPC SCOPE: **PASS**

TENANT CONSISTENCY: **PASS**

TENANT DERIVATION: **PASS**

GLOBAL ROLE BYPASS: **REMOVED IN TARGET**

OWNER AUTHORIZATION: **PASS**

STAFF AUTHORIZATION: **PASS**

PUBLIC EVENT CONTRACT: **PASS**

CONCURRENCY / CLAIMS: **PASS**

CALLER COMPATIBILITY: **PASS**

READY FOR PRODUCTION PUSH: **YES**

READY FOR SAAS-9D-2B: **NO-GO until 9D-2A production PASS and checkpoint/review**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## 21. FINAL PRODUCTION STATUS

The archived pre-deployment evidence in section 20 is superseded by the completed deployment evidence in section 19.

SAAS-9D-2A PRODUCTION DEPLOY: **PASS**

SAAS-9D-2A POST-DEPLOY: **PASS**

7 RPC TENANT ISOLATION: **PASS**

GLOBAL ROLE BYPASS: **REMOVED**

OWNER AUTHORIZATION: **PASS**

STAFF AUTHORIZATION: **PASS**

PUBLIC EVENT CONTRACT: **PASS**

CONCURRENCY / CLAIMS: **PASS**

SECURITY DEFINER DRIFT: **0**

FIXTURE CLEANUP: **PASS**

READY FOR GIT CHECKPOINT: **YES**

READY FOR SAAS-9D-2B PLANNING: **GO**

READY FOR SAAS-9D-2B IMPLEMENTATION: **NO-GO until checkpoint/review**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**
