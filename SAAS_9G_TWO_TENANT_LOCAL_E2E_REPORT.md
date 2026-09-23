# SAAS-9G TWO-TENANT LOCAL E2E REPORT

Date: 2026-09-23 (Europe/Warsaw)

## Scope and safety

SAAS-9G used two active tenants only in the local Supabase database. The
production database was not changed and no second production tenant was
created or activated. The local single-active guard was dropped only around
the deterministic Playwright fixture and recreated in `finally`.

## Matrix

| Area | Evidence | Result |
|---|---|---|
| Global account A+B | one authenticated account received active memberships and dashboard cards for both tenants | PASS |
| Admin A / Admin B | each admin opened its own dashboard and was denied the other tenant route | PASS |
| Employee / instructor | existing RLS/RPC role matrices in the 1608-test DB suite; scopes unchanged | PASS |
| Public booking/events | both active tenant slugs resolved independently and rendered tenant routes | PASS |
| Reservations/events/participants | explicit-tenant owner/staff readers and RLS matrices in full DB suite | PASS |
| Lanes/config/blocks | tenant hierarchy SQL plus updated current-contract concurrency harnesses | PASS |
| Reports/users/PII | tenant-scoped report/user SQL matrices; unrelated-tenant rows and PII excluded | PASS |
| Verification/notes/check-in | same-user A/B state, resource binding, note isolation, membership-status races | PASS |
| ICS/email/promotion | resource-derived owner contracts, claim binding, first-confirmed-wins and idempotency | PASS |
| Audit | tenant-owned mutations retain explicit tenant audit binding | PASS |
| Account lifecycle/profile | account-wide operations remain global while tenant relationships remain independent | PASS |
| Compatibility routes | deterministic CSK aliases do not become selected-tenant authority | PASS |

## Semantic test cutover

Eight historical concurrency harnesses were updated only to reflect contracts
already deployed before 9G:

- global accounts now receive explicit active tenant memberships;
- retired `admin_create_lane_booking_family_v1` callers use v2 with an explicit
  tenant argument;
- retired `update_my_profile_v1` callers use v2;
- retired `update_profile_identity` uses the tenant-scoped v2 writer;
- one profile fixture now deterministically updates rows created by the
  `auth.users` profile trigger.

No application, migration, RLS, ACL, role scope, or production function was
changed in 9G.

## Concurrency

- event capacity registration: one registered + one reserve; PASS
- confirmation email prepare/complete: one winner, idempotent duplicate; PASS
- waitlist promotion: FIFO/first-confirmed-wins, cross-tenant isolation; PASS
- lane family creation/writes: optimistic lock, hierarchy isolation; PASS
- verification/check-in: membership status race denied, same-user A/B independent; PASS
- account lifecycle/profile: no lost valid updates, no privilege escalation; PASS
- deadlocks: 0
- cross-tenant effects: 0
- broken invariants: 0
- fixture cleanup: 0

The older monolithic `final_cross_writer_regression.ps1` still targets a
retired `admin_create_event_v2` signature and is not the authoritative current
contract runner. The current per-domain harnesses listed above are the 9G
concurrency evidence.

## Full regression

- clean local migration replay through `20261002100000`: PASS
- full DB: 55 files, 1608/1608 PASS
- Node: 789/789 PASS
- TypeScript: PASS
- production build: PASS
- changed-file ESLint: PASS
- Playwright: 39/39 PASS, including the dedicated two-active-tenant test
- SECURITY DEFINER: 74
- compatibility defaults: 0
- bridge definitions: 0
- active tenants after cleanup: 1 (CSK)
- synthetic SAAS-9G users/tenants after cleanup: 0/0
- single-active production guard restored locally: true
- `git diff --check`: PASS, Windows EOL notices only

## Verdict

SAAS-9G TWO-TENANT LOCAL E2E: **PASS**

CROSS-TENANT EFFECTS: **0**

CROSS-TENANT PII LEAKS: **0**

DEADLOCKS: **0**

FIXTURE CLEANUP: **PASS**

SECOND PRODUCTION TENANT: **NO-GO pending SAAS-9H**

READY FOR SAAS-9H FINAL AUDIT: **GO**

SEC-004: **OPEN pending final audit**
