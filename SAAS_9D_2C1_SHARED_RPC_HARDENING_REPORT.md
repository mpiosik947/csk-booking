# SAAS-9D-2C-1 — Shared confirmation-email RPC hardening

## 1. Executive summary

SAAS-9D-2C-1 is implemented and verified locally. The shared confirmation-email
prepare/complete flow is now bound to the tenant-owned reservation or event
registration. The owner path requires an active membership; the staff
cancellation path requires an active same-tenant `admin` or `employee`
membership. A global `profiles.role` is no longer authorization for the RPC.

`complete_confirmation_email` is now a service-only SECURITY INVOKER and
revalidates the claim against the delivery, typed business resource, tenant and
recipient before changing delivery state. The rate-limit function remains
byte-for-byte unchanged as approved. No application file changed.

## 2. Exact function scope

| Function | 2C-1 treatment |
|---|---|
| `prepare_confirmation_email(text,uuid)` | body hardening; retain authenticated-only definer |
| `complete_confirmation_email(uuid,boolean,text,text)` | body hardening; convert to service-only invoker |
| `check_confirmation_email_rate_limit(uuid,text)` | fingerprint-frozen; no body, metadata or ACL change |

Deferred unchanged to SAAS-9D-2C-2:

- `prepare_event_reserve_promotions(uuid)`
- `complete_event_reserve_promotion(uuid,uuid,boolean,text)`

## 3. Pre-change fingerprints

Normalization: CRLF and CR are converted to LF before MD5.

| Function | Pre-change normalized MD5 |
|---|---|
| `prepare_confirmation_email(text,uuid)` | `449dbd830a7ece7f0c5b8b046dc1ee2c` |
| `complete_confirmation_email(uuid,boolean,text,text)` | `8ca5430a2d7e625d10ebc61617a03dd5` |
| `check_confirmation_email_rate_limit(uuid,text)` | `e693411c3fc7f24510313e60a1d8e2a5` |

The migration stops on function, overload, metadata, ACL, data-integrity or
SECURITY DEFINER inventory drift.

## 4. Function classification

| Function | Classification | Result |
|---|---|---|
| prepare | A — body hardening | tenant/resource/membership enforcement and explicit tenant write |
| complete | A + C — body hardening and invoker candidate | converted to invoker with typed-resource consistency validation |
| rate limit | D — safe/no change | exact fingerprint retained |

No ACL-only function and no application-cutover dependency exists in 2C-1.

## 5. Caller inventory

There are no SQL-to-SQL, cron or background callers.

| File | RPC use | Auth context | Tenant/resource context | App change |
|---|---|---|---|---|
| `app/api/send-event-registration-confirmation/route.ts` | rate, prepare, complete | verified user JWT for prepare; server service client for rate/complete | registration -> event -> tenant | no |
| `app/api/send-reservation-confirmation/route.ts` | rate, prepare, complete | verified owner JWT; server service completion | reservation -> tenant | no |
| `app/api/send-reservation-cancellation/route.ts` | rate, prepare, complete | verified JWT; DB is final owner/staff authority; server service completion | reservation -> tenant | no |
| `lib/server/confirmation-email-delivery.ts` | orchestrates prepare/provider/complete | server helper; receives authenticated prepare client and server completion client | exact prepared claim only | no |

Signatures, arguments, response codes and idempotency keys remain compatible.

## 6. Tenant derivation

- reservation confirmation/cancellation: `record_id -> reservations.tenant_id`;
- event confirmation: `record_id -> event_registrations.tenant_id`, with an
  inner consistency join to `events(id, tenant_id)`;
- completion: `claim_id -> email_deliveries -> typed resource -> tenant`;
- browser-supplied tenant IDs are not accepted;
- `email_deliveries.tenant_id` is written explicitly.

## 7. Service-role authorization

The service role is used only by the three server API flows for the existing
rate check and completion. The request is authenticated before prepare. The
service client cannot execute prepare. Completion accepts only an opaque claim
issued by the authenticated prepare path and independently validates its typed
resource, tenant and recipient. Service credential possession is not treated
as business authorization for preparation.

## 8. Email/confirmation flow

`prepare -> rate/provider orchestration -> complete` now guarantees:

- owner and active membership, or same-tenant staff membership;
- status eligibility unchanged;
- one `(message_type, record_id)` delivery row;
- explicit resource tenant and trusted resource owner as recipient;
- active claims return `in_progress`;
- sent deliveries return `already_sent`;
- provider failure clears the claim for a bounded retry;
- success after retry creates one final sent state.

## 9. Rate limiting

`check_confirmation_email_rate_limit` remains the approved global anti-abuse
control: 10 verified-user and 30 HMAC-IP attempts per sliding 10 minutes. The
server helper supplies the verified `user.id` and a server-generated HMAC IP
digest. It does not accept browser-selected user IDs or raw IPs. The function
remains service-only because `service_role` intentionally has no direct table
ACL for the rate-limit table. Business limits were not changed.

## 10. Token/claim security

There is no public bearer-token operation in 2C-1. The delivery claim is an
opaque, bounded server completion capability. Invalid, stale, mismatched and
replayed claim identifiers fail closed as `claim_not_found`; mismatched tenant
or recipient state cannot be completed. Public reserve-confirmation token
semantics remain in the completed 2A scope and passed regression tests.

## 11. Reserve promotion

Not in 2C-1. Both reserve-promotion helper functions and the manual route
authorization cutover remain deferred unchanged to 2C-2.

## 12. ACL

| Function | PUBLIC | anon | authenticated | service_role |
|---|---:|---:|---:|---:|
| prepare | no | no | EXECUTE | no |
| complete | no | no | no | EXECUTE |
| rate limit | no | no | no | EXECUTE |

No grant was widened.

## 13. Search path / owner

- prepare: postgres, SECURITY DEFINER, `pg_catalog, public, pg_temp`;
- complete: postgres, SECURITY INVOKER, `pg_catalog, public, pg_temp`;
- rate limit: postgres, SECURITY DEFINER, retained `public, pg_temp` exactly.

All changed function identifiers are schema-qualified.

## 14. PII

RPC responses expose no email address, phone, customer name, profile,
membership, recipient user ID or tenant ID. `email_deliveries` remains a
technical state table without message bodies, recipient addresses, JWTs or
tokens. Provider error input is normalized to a bounded technical code.

## 15. Signature compatibility

All three signatures, defaults, return type and stable response codes are
unchanged. Old application + new database is compatible for the single-active
tenant runtime. Deployment is DB-only.

## 16. Idempotency

Focused tests prove duplicate prepare, repeat after success, failed completion,
retry, success after retry and duplicate complete. Exactly one final provider
identifier and sent timestamp survive.

## 17. Concurrency

The real parallel local harness produced:

- one `ready` and one `in_progress` for concurrent prepare;
- one completing mutation and one controlled `claim_not_found` for concurrent
  complete;
- deadlocks: 0;
- broken invariants: 0;
- duplicate final effects: 0;
- fixture cleanup: 0.

## 18. Cross-tenant tests

PASS cases include Tenant A owner/resource, Tenant B owner/resource after
controlled active-tenant switch, and same-tenant admin/employee cancellation.
DENY cases include foreign resource, global legacy admin without target-tenant
membership, instructor, pending membership and suspended membership. The schema
trigger rejects cross-tenant delivery insertion and completion independently
rechecks tenant and recipient.

## 19. Regression 2A/2B

- focused 2C-1 SQL: 44/44 PASS;
- SAAS-9D-2A SQL: PASS;
- SAAS-9D-2B-1 SQL: PASS;
- SAAS-9D-2B-2 SQL: PASS;
- full Supabase DB suite: 31 files, 936 tests, PASS;
- Node full suite: 734/734 PASS;
- TypeScript: PASS;
- production build: PASS;
- focused Events Playwright: 8/8 PASS.

The build and Playwright runs retain only the known Next.js middleware-to-proxy
deprecation warning.

## 20. SECURITY DEFINER inventory

Before: 73. After: 72. The only reduction is
`complete_confirmation_email`, converted to SECURITY INVOKER. Migration
snapshot comparison proves zero unrelated definer-body drift. Rate-limit body
and metadata remain unchanged.

Post-change normalized MD5:

| Function | MD5 |
|---|---|
| prepare | `17d8b973c9e3df0839f692fd8d9efbde` |
| complete | `c8450fe37a991fda41e8a30ce66732b3` |
| rate limit | `e693411c3fc7f24510313e60a1d8e2a5` |

## 21. Temporary defaults

All seven compatibility defaults remain. `email_deliveries` no longer relies
on its default in this writer because prepare writes a derived tenant
explicitly. Default removal remains gated to 9D-5 before tenant-aware writer
cutover and before a second tenant.

## 22. Migration SHA

- migration: `20260914100000_harden_shared_confirmation_email_rpcs.sql`
- SHA-256: `C7CCEAD3B0A5ACE67AFE05D87EE6966B885C5BC1111926F01ACD970D7A31E0F1`

Historical migrations were not modified.

## 23. Production deployment plan

Not executed. Required next step is a separate read-only production preflight:
repeat normalized fingerprints, data orphan/mismatch counts, ACL/table-grant
contract, migration history and `db push --dry-run`. If and only if the dry-run
contains exactly this migration, deployment may be separately approved. After
deployment, repeat ACL/fingerprint/cross-tenant/runtime/cleanup verification.

Compatibility: DB first; APP change not required.

## 24. Git status

The working tree is intentionally modified and unstaged. It contains this
report, the 2C plan update, one new migration, one focused SQL test, one local
concurrency harness and three regression assertion updates. No application file
is modified. No `git add`, commit or push was performed.

## 25. Deferred 2C-2

Reserve-promotion prepare/complete hardening and the manual promotion route
membership cutover remain untouched and require separate review.

## 26. Final verdict

SAAS-9D-2C-1 LOCAL: **PASS**

TENANT ISOLATION: **PASS**

SERVICE_ROLE AUTHORIZATION: **PASS**

GLOBAL ROLE BYPASS: **REMOVED**

TOKEN / CLAIM SECURITY: **PASS**

EMAIL CONFIRMATION SECURITY: **PASS**

RATE LIMIT ISOLATION: **NOT APPLICABLE** (approved global user/HMAC-IP anti-abuse scope; exact function unchanged)

IDEMPOTENCY: **PASS**

CONCURRENCY: **PASS**

PII: **PASS**

CALLER COMPATIBILITY: **PASS**

REGRESSION 2A/2B: **PASS**

READY FOR SAAS-9D-2C-1 PRODUCTION PREFLIGHT: **GO**

READY FOR SAAS-9D-2C-2: **NO-GO until review**

READY FOR PRODUCTION WRITE: **NO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## 28. Production deployment & post-deploy verification

Deployment date: 2026-09-13 (Europe/Warsaw).

### 28.1 Deployment result and history

Immediately before deployment the migration SHA-256 remained
`C7CCEAD3B0A5ACE67AFE05D87EE6966B885C5BC1111926F01ACD970D7A31E0F1`.
The linked dry-run listed exactly
`20260914100000_harden_shared_confirmation_email_rpcs.sql`. The separately
authorized `supabase db push --linked` applied exactly that migration and
completed successfully.

After deployment, `supabase migration list --linked` reports LOCAL = REMOTE
through `20260914100000`. The final linked dry-run reports:

`Remote database is up to date.`

No migration repair, second migration or manual production schema change was
performed.

### 28.2 Post-deploy function verification

| Function | Production MD5 after deploy | Mode | Owner / path | Direct EXECUTE | Result |
|---|---|---|---|---|---|
| `prepare_confirmation_email(text,uuid)` | `17d8b973c9e3df0839f692fd8d9efbde` | DEFINER | postgres / SP1 | authenticated only | PASS |
| `complete_confirmation_email(uuid,boolean,text,text)` | `c8450fe37a991fda41e8a30ce66732b3` | INVOKER | postgres / SP1 | service_role only | PASS |
| `check_confirmation_email_rate_limit(uuid,text)` | `e693411c3fc7f24510313e60a1d8e2a5` | DEFINER | postgres / SP2 | service_role only | UNCHANGED |
| `prepare_event_reserve_promotions(uuid)` | `4e73ef1df59936a1a3f41a00e121f6e9` | DEFINER | postgres / SP2 | service_role only | UNCHANGED |
| `complete_event_reserve_promotion(uuid,uuid,boolean,text)` | `dd5025876008d6eb9551497d84cef90e` | DEFINER | postgres / SP2 | service_role only | UNCHANGED |

PUBLIC and anon have no EXECUTE on all five. Authenticated cannot execute
completion/rate-limit/2C-2 functions, and service_role cannot execute prepare.
The service invoker contract is present: service_role has SELECT on
reservations, event registrations and events, plus SELECT/UPDATE on
email_deliveries.

The public-schema SECURITY DEFINER count is exactly 72. It decreased only by
the approved completion conversion. The migration's in-transaction snapshot
guard confirmed zero unexpected definer-body drift.

### 28.3 Production data integrity

After deployment, production still contains 11 pre-existing email delivery
rows. Verification found:

- null tenant: 0;
- unknown message type: 0;
- orphan or typed resource/tenant/recipient mismatch: 0;
- active claim: 0;
- stale claim: 0;
- duplicate non-null claim ID: 0.

All seven temporary CSK compatibility defaults remain unchanged.

### 28.4 Rollback-only production behavior test

A uniquely marked synthetic fixture was created inside one explicit transaction
and the transaction ended with `ROLLBACK`. The test did not invoke Resend or any
application email endpoint and sent zero email messages.

Verified behavior:

- owner with active CSK membership can prepare a bound confirmation delivery;
- stored tenant and recipient equal the trusted reservation tenant/owner;
- duplicate prepare while leased returns controlled `in_progress`;
- service_role completes the exact claim once;
- replay/double complete returns `claim_not_found` and cannot replace the first
  provider result;
- prepare after success returns non-mutating `already_sent`;
- a synthetic `profiles.role = admin` caller with no active target membership
  receives fail-closed `not_found`;
- provider failure releases the exact claim and stores only a bounded sanitized
  error code;
- retry receives a new claim and produces one final sent state;
- a delivery using a tenant different from its resource is rejected;
- completion rejects a delivery whose recipient differs from the resource
  owner;
- authenticated direct completion and service_role direct preparation are
  denied by ACL.

This proves the production target's prepare isolation, global-role bypass
removal, claim/resource/tenant/recipient binding, idempotency, failure retry and
replay protection without a persistent production fixture.

### 28.5 Independent cleanup proof

After rollback, an independent read-only query returned:

- synthetic Auth users: 0;
- synthetic profiles: 0;
- synthetic tenants: 0;
- synthetic lanes: 0;
- synthetic reservations: 0;
- synthetic deliveries: 0;
- active delivery claims: 0;
- total pre-existing deliveries: still 11;
- `remaining_synthetic_fixture`: 0.

No temporary SQL file remains outside or inside the repository.

### 28.6 Runtime smoke and caller contract

Post-deploy production HTTP results:

| Path | Result |
|---|---|
| `/events` | HTTP 200 |
| `/booking` | HTTP 200 |
| `/account` | HTTP 200 |
| `/login` | HTTP 200 |
| `/admin/events` as anon | HTTP 307 to the expected login redirect |

All three confirmation-email routes returned the safe, controlled anonymous
contract `HTTP 401 {"ok":false,"code":"unauthorized"}` when called without a
session:

- `/api/send-reservation-confirmation`;
- `/api/send-reservation-cancellation`;
- `/api/send-event-registration-confirmation`.

Their active server contract remains unchanged: verified user JWT performs
prepare; the server-only service client performs rate check and completion.
No 5xx, raw database error, recipient PII or secret appeared. Successful send
was intentionally verified at the DB claim/completion boundary rather than by
sending an unnecessary real production email.

### 28.7 Final production verdict

SAAS-9D-2C-1 PRODUCTION DEPLOY: **PASS**

SAAS-9D-2C-1 POST-DEPLOY VERIFICATION: **PASS**

MIGRATION HISTORY: **LOCAL = REMOTE**

FINAL DRY-RUN: **REMOTE DATABASE IS UP TO DATE**

PREPARE TARGET: **PASS**

COMPLETE SECURITY INVOKER / SERVICE-ONLY: **PASS**

RATE LIMIT FUNCTION: **UNCHANGED**

2C-2 FUNCTIONS: **UNCHANGED**

SECURITY DEFINER COUNT: **72**

UNEXPECTED SECURITY DEFINER DRIFT: **0**

GLOBAL ROLE WITHOUT ACTIVE MEMBERSHIP: **DENY**

PREPARE TENANT ISOLATION: **PASS**

CLAIM / RESOURCE / TENANT / RECIPIENT BINDING: **PASS**

SERVICE_ROLE CALLER COMPATIBILITY: **PASS**

IDEMPOTENCY / REPLAY PROTECTION: **PASS**

PII: **PASS**

COMPATIBILITY DEFAULTS: **7/7 UNCHANGED**

EMAIL DELIVERY INTEGRITY: **PASS**

ROLLBACK / FIXTURE CLEANUP: **0**

READY FOR GIT CHECKPOINT: **YES**

READY FOR SAAS-9D-2C-2: **NO-GO until checkpoint/review**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## 27. Production preflight & deployment readiness

Preflight date: 2026-09-13 (Europe/Warsaw). This section records read-only
production catalog/data checks, read-only HTTP checks and a linked CLI dry-run.
No production SQL write, migration push, migration repair or Git write was
performed.

### 27.1 Working tree reconciliation and migration SHA

The repository is `main` at
`0b5188fdd9fbbd07b56c2ce2c0378ca0c82a4729`. The working tree contains exactly
the eight approved 2C-1 paths:

1. `SAAS_9D_RPC_SECURITY_DEFINER_HARDENING_PLAN.md`
2. `SAAS_9D_2C1_SHARED_RPC_HARDENING_REPORT.md`
3. `supabase/migrations/20260914100000_harden_shared_confirmation_email_rpcs.sql`
4. `supabase/tests/20260914100000_harden_shared_confirmation_email_rpcs_test.sql`
5. `supabase/tests/20260914100000_harden_shared_confirmation_email_rpcs_concurrency.ps1`
6. `supabase/tests/20260904180000_harden_reservation_cancellation_email_delivery_test.sql`
7. `supabase/tests/20260913100000_harden_event_management_rpcs_test.sql`
8. `supabase/tests/20260913150000_harden_public_event_readers_test.sql`

There is no ninth path, no unexpected/temp path and the staging area is empty.
`git diff --check` passes; its only output is the known informational LF-to-CRLF
working-copy warning. The migration SHA-256 was recalculated as:

`C7CCEAD3B0A5ACE67AFE05D87EE6966B885C5BC1111926F01ACD970D7A31E0F1`

### 27.2 Exact function scope and production fingerprints

Normalization for every fingerprint is CRLF/CR to LF before MD5.

| Function | Treatment | Production / expected baseline MD5 | Target MD5 | Current -> target mode | Current -> target path | Current -> target direct grants |
|---|---|---|---|---|---|---|
| `prepare_confirmation_email(text,uuid)` | body hardening | `449dbd830a7ece7f0c5b8b046dc1ee2c` | `17d8b973c9e3df0839f692fd8d9efbde` | DEFINER -> DEFINER | SP2 -> SP1 | authenticated -> authenticated |
| `complete_confirmation_email(uuid,boolean,text,text)` | body hardening + mode change | `8ca5430a2d7e625d10ebc61617a03dd5` | `c8450fe37a991fda41e8a30ce66732b3` | DEFINER -> INVOKER | SP2 -> SP1 | service_role -> service_role |
| `check_confirmation_email_rate_limit(uuid,text)` | unchanged | `e693411c3fc7f24510313e60a1d8e2a5` | same | DEFINER -> DEFINER | SP2 -> SP2 | service_role -> service_role |
| `prepare_event_reserve_promotions(uuid)` | 2C-2 freeze | `4e73ef1df59936a1a3f41a00e121f6e9` | same | DEFINER -> DEFINER | SP2 -> SP2 | service_role -> service_role |
| `complete_event_reserve_promotion(uuid,uuid,boolean,text)` | 2C-2 freeze | `dd5025876008d6eb9551497d84cef90e` | same | DEFINER -> DEFINER | SP2 -> SP2 | service_role -> service_role |

All five production definitions are `postgres`-owned and volatile. SP1 means
`pg_catalog, public, pg_temp`; SP2 means `public, pg_temp`. Production matches
every expected baseline fingerprint, metadata and ACL guard. The migration
creates/replaces and alters only the two approved 2C-1 functions. It does not
touch either 2C-2 function or the rate-limit function.

Exact production/target ACL for prepare is: PUBLIC no, anon no,
authenticated yes, service_role no. Exact production/target ACL for complete
is: PUBLIC no, anon no, authenticated no, service_role yes. Rate limit and both
2C-2 functions are also service_role-only. No grant is widened.

### 27.3 Prepare authorization and tenant derivation

The target accepts no caller-supplied tenant ID. Its trusted chains are:

- reservation confirmation: `record_id -> reservations -> tenant_id`;
- reservation cancellation: `record_id -> reservations -> tenant_id`;
- event registration confirmation:
  `record_id -> event_registrations -> (event_id, tenant_id) -> events`.

Owner preparation requires `auth.uid()` to equal the resource owner and an
active membership in the derived tenant. Staff cancellation requires an active
same-tenant `admin` or `employee` membership. `profiles.role` does not occur in
the target body. A legacy global admin with no active target membership is
therefore denied; pending, suspended and absent memberships are denied. The
derived tenant and trusted resource owner are written explicitly as
`email_deliveries.tenant_id` and `recipient_user_id`; the compatibility default
is not an authorization mechanism.

### 27.4 Complete service-only invoker model

The target completion function is `postgres`-owned, volatile, SECURITY INVOKER,
SP1 and directly executable only by `service_role`. Before any update it follows
`claim_id -> email_deliveries -> typed reservation/event registration -> tenant`
and rechecks delivery existence, supported message type, resource existence,
event/registration tenant consistency, delivery tenant, recipient and claim
state. The caller cannot finish a delivery using only an arbitrary delivery ID
or a claim detached from the trusted resource.

Invalid, stale, wrong-resource, wrong-tenant, wrong-recipient and replayed
claims fail closed. An already completed delivery is non-mutating; a provider
failure clears the bounded lease and stores only a sanitized technical code;
retry may create one eventual sent state. Parallel completion produced zero
deadlocks and zero duplicate final effects locally.

### 27.5 Service-role caller proof

| Caller | File | Prepare context | Completion context | Resource/tenant context | Active |
|---|---|---|---|---|---|
| reservation confirmation API | `app/api/send-reservation-confirmation/route.ts` | verified user JWT | server service client | reservation -> tenant | yes |
| reservation cancellation API | `app/api/send-reservation-cancellation/route.ts` | verified user/staff JWT | server service client | reservation -> tenant | yes |
| event registration confirmation API | `app/api/send-event-registration-confirmation/route.ts` | verified owner JWT | server service client | registration -> event -> tenant | yes |
| delivery orchestrator | `lib/server/confirmation-email-delivery.ts` | receives authenticated prepare client | creates service client from server-only environment | opaque prepared claim | yes |

There is no active SQL-to-SQL, cron or background caller. Tests are not runtime
callers. The server-side `SUPABASE_SERVICE_ROLE_KEY` is required only for rate
check/completion and is not exposed to the browser. Production confirms that
service_role has the required SELECT access to reservations, event
registrations and events and SELECT/UPDATE capability required by the
email-delivery flow. Converting completion to INVOKER is therefore compatible
with every active caller.

### 27.6 Production email-delivery baseline

Read-only production results:

| Check | Result |
|---|---:|
| total deliveries | 11 |
| `tenant_id IS NULL` | 0 |
| unknown message type | 0 |
| typed resource / tenant / recipient mismatch or orphan | 0 |
| active claims | 0 |
| stale claims | 0 |
| duplicate non-null claim IDs | 0 |

All 11 current rows are `reservation_confirmation`; this is valid and does not
require other message types to be present. No unexplained production data
blocker exists.

### 27.7 Rate limit, PII and error safety

The production and target rate-limit body fingerprint, owner, SP2 path,
SECURITY DEFINER mode and service-only ACL match exactly. Isolation remains
**NOT APPLICABLE — APPROVED GLOBAL SCOPE** for the verified-user/HMAC-IP
anti-abuse control.

Target responses contain stable status codes and opaque claim metadata only;
they do not return recipient email, profile PII, membership details, user ID or
tenant ID. Completion normalizes provider failures to a bounded code. Existing
delivery storage has no message body or recipient address. The target does not
increase account/resource enumeration: authorization and resource-binding
failures use the existing controlled `not_found`/`claim_not_found` behavior.

### 27.8 SECURITY DEFINER inventory, 2C-2 freeze and defaults

The production public-schema SECURITY DEFINER inventory is exactly 73, matching
the migration precondition. The target count is 72 because only
`complete_confirmation_email` becomes INVOKER. Snapshot comparison in the
migration guards all other definer bodies, so expected unrelated drift is 0.

Both 2C-2 fingerprints match their frozen local baselines and the migration
does not reference either function. All seven temporary CSK tenant defaults are
present. 2C-1 neither removes nor adds a default, and prepare writes its derived
tenant explicitly.

### 27.9 Migration history and dry-run

`supabase migration list --linked` shows LOCAL = REMOTE through
`20260913150000`. There is no remote-only or divergent migration. The only
local pending migration is:

`20260914100000_harden_shared_confirmation_email_rpcs.sql`

After all earlier checks passed, `supabase db push --linked --dry-run` completed
successfully and listed exactly that one migration. No push was executed. The
CLI only reported an optional version update (`2.109.1` installed,
`2.117.0` available); this is not a deployment blocker and the CLI was not
changed.

### 27.10 Local evidence reconfirmed

- focused 2C-1 SQL: 44/44 PASS;
- full DB suite: 31 files, 936/936 PASS;
- Node: 734/734 PASS;
- TypeScript: PASS;
- production build: PASS;
- focused Events Playwright: 8/8 PASS;
- concurrency: PASS; deadlocks 0; duplicate final effects 0;
- 2A/2B regression: PASS;
- local synthetic fixture remaining: 0.

### 27.11 Read-only production runtime baseline

Read-only GET checks against the current Vercel production deployment returned
HTTP 200 for `/`, `/events`, `/booking`, `/login` and `/account`. Anonymous
`/admin/events` returned the expected 307 redirect to
`/login?redirectTo=%2Fadmin%2Fevents`, confirming the admin boundary remains
fail-closed. No 5xx occurred.

The three email paths were verified contractually from their active server
callers without sending email or mutating production: each uses a verified JWT
client for prepare and the server-only service client for rate/complete. This
preflight deliberately did not invoke a mail endpoint because doing so would
create delivery/rate-limit state and could send a real message.

### 27.12 Deployment risk and window

| Risk | Rating | Reason |
|---|---|---|
| prepare RPC change | MEDIUM | authorization path changes, signatures/status contract stay stable |
| complete RPC change | MEDIUM | body and execution mode change on delivery finalization |
| DEFINER -> INVOKER | MEDIUM | safe only because the service table contract was proven |
| service-role caller compatibility | LOW | all active callers already use the server service client |
| email-delivery regression | MEDIUM | shared by three mail flows; post-deploy monitoring is required |
| idempotency/concurrency | LOW | row locks, bounded claims and real parallel tests passed |
| cross-tenant escape | LOW in target | tenant/resource/recipient are independently derived and checked |
| PII/error exposure | LOW | stable minimal outputs and bounded technical error code |

A low-traffic deployment window is sufficient. Post-deploy verification must
immediately confirm target fingerprints/ACLs/count 72, exercise controlled
synthetic confirmation flows, verify one final effect, inspect bounded errors
and prove fixture/rate-limit cleanup. Any mail-flow regression is a STOP and
forward-rollback trigger.

### 27.13 Production preflight verdict

SAAS-9D-2C-1 PRODUCTION PREFLIGHT: **PASS**

WORKING TREE SCOPE: **PASS**

SHA: **PASS**

FUNCTION SCOPE: **PASS**

PREPARE TENANT ISOLATION: **PASS**

GLOBAL ROLE BYPASS: **REMOVED IN TARGET**

COMPLETE SERVICE-ONLY SECURITY: **PASS**

SERVICE_ROLE CALLER COMPATIBILITY: **PASS**

CLAIM / RESOURCE / TENANT BINDING: **PASS**

EMAIL CONFIRMATION SECURITY: **PASS**

RATE LIMIT FUNCTION: **UNCHANGED**

IDEMPOTENCY: **PASS**

PII: **PASS**

2C-2 FUNCTIONS: **UNCHANGED**

SECURITY DEFINER DRIFT: **0**

READY FOR PRODUCTION PUSH: **YES**

READY FOR SAAS-9D-2C-2: **NO-GO until 2C-1 production PASS and checkpoint/review**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**
