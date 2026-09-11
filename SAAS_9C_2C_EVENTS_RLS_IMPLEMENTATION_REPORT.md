# SAAS-9C-2C — Events tenant-aware RLS implementation report

Date: 11 September 2026
Scope: local implementation, production deployment, and verification
Production writes: none

## 1. Executive summary

SAAS-9C-2C replaces the six legacy `SELECT` policies on `events`, `event_lanes`, and `event_registrations` with tenant-aware policies. Public event browsing remains membership-free for the guarded active tenant. Customer ownership of event registrations remains global and uses `auth.uid() = user_id`; tenant membership is required only for privileged staff access.

The implementation intentionally does not modify any event RPC, application code, middleware, routing, the legacy `profiles.role` bridge, temporary CSK defaults, or existing booking-domain RLS. Every existing event `SECURITY DEFINER` remains a documented SAAS-9D boundary. A second tenant remains prohibited and SEC-004 remains open.

## 2. Existing Events policies

The migration preflight requires the exact six deployed legacy policies:

- `events`: public active read for `anon`, active read for `authenticated`, and global `is_admin_or_staff()` read;
- `event_lanes`: global `is_admin_or_staff()` read;
- `event_registrations`: owner read using `auth.uid()` and global `is_admin_or_staff()` read.

It also requires RLS enabled on all three tables, one active CSK tenant, the second-active-tenant guard, reconciled CSK profiles/memberships, non-null tenant ownership, and validated composite tenant relationship constraints.

## 3. Policies removed

The atomic migration removes only:

1. `Public can view active events`
2. `Users can view active events`
3. `Admins and staff can view all events`
4. `Admins and staff can view event lanes`
5. `Users can view own event registrations`
6. `Admins and staff can view all event registrations`

No unrelated policy is altered. A catalog fingerprint aborts the migration if unrelated RLS changes inside the transaction.

## 4. Policies added

The migration creates exactly six `SELECT` policies:

1. `Public can view active tenant events` — `anon`, active event plus `is_active_public_tenant_v1(tenant_id)`;
2. `Authenticated users can view active tenant events` — `authenticated`, the same public predicate;
3. `Tenant staff can view events` — active `admin`, `employee`, or `instructor` membership in the row tenant;
4. `Tenant staff can view event lanes` — the same tenant staff membership rule;
5. `Users can view own event registrations` — `user_id = (select auth.uid())`, with no membership requirement;
6. `Tenant staff can view event registrations` — active `admin`, `employee`, or `instructor` membership in the row tenant.

There are no direct `INSERT`, `UPDATE`, or `DELETE` policies.

## 5. Public Events contract

Direct public event reads remain limited to active rows in the single guarded active tenant. Neither `event_lanes` nor `event_registrations` receives an anonymous table grant or public policy. The PII-free `get_public_event_list_v2` and availability contract remain unchanged.

The public RPCs are still legacy `SECURITY DEFINER` functions without explicit tenant binding. This is recorded as a SAAS-9D blocker rather than hidden by the direct-table RLS improvement.

## 6. Events staff access

- `admin`: all events in tenants where the caller has an active `admin` membership;
- `employee`: existing event read in tenants where the caller has an active `employee` membership;
- `instructor`: existing event read in tenants where the caller has an active `instructor` membership;
- ordinary user/no membership: public active event rows only;
- global `profiles.role` alone: no private event access.

## 7. `event_lanes` access

Direct reads require active tenant membership with `admin`, `employee`, or `instructor`. Composite foreign keys continue to enforce:

```text
event_lanes.tenant_id = events.tenant_id = shooting_lanes.tenant_id
```

No direct mutation is opened. Public application data continues through the reviewed PII-free Events RPC rather than an anonymous relation-table grant.

## 8. Event registration owner access

Owner read remains deliberately independent of tenant membership:

```text
auth.uid() = event_registrations.user_id
```

This permits a global customer to retain their own registrations and history across tenant event catalogs. It never permits another user's registration. The validated `(tenant_id,event_id)` foreign key binds every registration to the tenant of its event.

## 9. Admin/employee access

Admin and employee participant access now depends on an active membership and the role stored in `tenant_memberships` for the row tenant. A legacy global profile role cannot authorize a different tenant or replace membership.

## 10. Instructor behavior

Instructor table-read behavior is preserved but tenant-scoped. No new mutation, field, or participant DTO is introduced. The deferred instructor-to-event assignment decision (SEC-008) remains outside this phase.

## 11. Membership status semantics

`has_tenant_role_v1` enforces all of the following:

- tenant exists and is active;
- membership exists and is active;
- membership role is explicitly allowlisted;
- authenticated caller identity matches the membership.

Missing, pending, suspended, wrong-tenant, or unsupported membership states fail closed for privileged reads. They do not remove an owner's access to their own event registration.

## 12. Cross-tenant/IDOR tests

The focused SQL test contains 64 checks using unique transaction-scoped identities and a dormant local Tenant B. It covers public, user, admin, employee, instructor, missing-membership, pending, and suspended identities; owner and foreign registrations; Tenant B IDs; and direct mutation attempts.

The test swaps no production state and ends with `ROLLBACK`, removing every Auth user, profile, membership, tenant, lane, event, relation, and registration fixture.

## 13. Privacy tests

The focused suite proves:

- anonymous users have no registration table access;
- User A cannot read User B's registration;
- staff membership in Tenant A does not disclose Tenant B registrations;
- a global legacy admin role without membership cannot read participant data;
- the public event list RPC response contains no participant/customer identifiers, contact fields, notes, or tokens.

## 14. Direct DML restrictions

Target table ACL is fingerprinted before/after the policy replacement. `authenticated` remains `SELECT`-only; anonymous access remains limited to event `SELECT`; and no `PUBLIC` or application-role direct mutation right is introduced.

The focused suite attempts cross-tenant `INSERT`, `UPDATE`, and `DELETE` against events, event lanes, and registrations. Every direct mutation must fail with `42501`.

## 15. RLS recursion

Policies call only the hardened 9C-1/9C-2 helpers. The focused test repeatedly evaluates event policies through a generated row set and requires a deterministic result, catching helper recursion or stack failures.

## 16. Performance

No new index is introduced. The implementation relies on:

- `events_tenant_active_schedule_idx`;
- `event_lanes_tenant_event_lane_idx`;
- `event_registrations_tenant_user_created_idx`;
- the two membership lookup indexes;
- validated composite tenant/event/lane foreign keys.

The local reset and complete SQL regression confirm that these indexes and composite constraints remain present. No new index was required for this policy-only cutover.

## 17. SECURITY DEFINER bypass matrix

| RPC family | RLS secured? | Current tenant check | 9C-2C classification |
|---|---:|---:|---|
| Public list and availability | No | No | Known SAAS-9D blocker |
| Admin event/participant lists | No | No; legacy global role | Known SAAS-9D blocker, participant path critical |
| Own event registrations | No | Owner-scoped, no explicit tenant predicate | Requires SAAS-9D review |
| Registration/cancellation/confirmation | No | Owner/business checks, no complete tenant binding | Known SAAS-9D blocker |
| Reserve promotion lifecycle | No | Service/claim checks, no complete tenant binding | Known SAAS-9D blocker |
| Payment marking | No | Legacy global staff role | Known SAAS-9D blocker |
| Event create/update/activation V2 | No | Legacy global staff role; CSK default bridge | Known SAAS-9D blocker |

The migration fingerprints every existing `SECURITY DEFINER` definition, owner, search path, and configuration. Any drift aborts the transaction.

## 18. Regression results

| Verification | Result |
|---|---|
| Focused Events/Booking/Admin Node tests | PASS — 267 tests |
| All Node tests | PASS — 734 tests |
| TypeScript `tsc --noEmit` | PASS |
| Next.js production build | PASS; existing middleware-to-proxy warning only |
| Local Supabase DB reset | PASS; all migrations through `20260911100000` applied |
| Focused SAAS-9C-2C SQL | PASS — 64/64, one transaction, final `ROLLBACK`, exit 0 |
| Historical phase-isolation SQL | PASS — 32/32, 50/50, and 47/47 after approved Events-scope expectation updates |
| Full Supabase DB suite | PASS — 25 files, 686 tests |
| Relevant Playwright | PASS — Events operational suite 8/8 |
| Fixture cleanup post-check | PASS — Auth users, profiles, tenants, events, and registrations all 0 |
| `git diff --check` | PASS |

The earlier local Docker blocker is resolved. No imgproxy/pooler repair, Docker configuration change, CLI update, Supabase link, remote fallback, or production operation was performed.

## 19. SAAS-9D blockers

- every listed event RPC remains `SECURITY DEFINER`;
- public definers do not bind the active tenant explicitly;
- staff definers still use global `profiles.role` checks;
- event writers still depend on the temporary CSK default instead of deriving tenant explicitly;
- reserve/payment/management paths remain ID/global-role driven;
- a second tenant therefore remains prohibited.

## 20. Production deployment plan (pre-deploy record)

At the end of local implementation, production deployment was not yet authorized. The required read-only preflight covered the exact six legacy policies, RLS/ACL/owners, helper and function fingerprints, tenant constraints, membership reconciliation, migration history, SHA-256, lock risk, runtime baselines, and a dry-run containing only the new migration. The later explicit deployment authorization and its outcome are recorded in section 24.

## 21. Production preflight & deployment readiness

### 21.1 Fresh production and membership state

Read-only production inspection through the linked Supabase Management API returned:

| Check | Production result |
|---|---|
| Active tenants | 1 — `csk`, `active` |
| Tenant memberships | 9 |
| Role distribution | `admin=1`, `user=8` |
| Status distribution | `active=9` |
| Duplicate `(tenant_id,user_id)` | 0 |
| Orphan `user_id` | 0 |
| Orphan `tenant_id` | 0 |
| Unknown membership role | 0 |
| Invalid membership status | 0 |
| Profile without CSK membership | 0 |
| Legacy profile/membership role mismatch | 0 |

All Events ownership checks also returned zero: null `tenant_id` on `events`, `event_lanes`, or `event_registrations`; event/lane tenant mismatch; and registration/event tenant mismatch. The three composite Events foreign keys are present and validated.

### 21.2 Current production Events RLS baseline

RLS is enabled on all three tables. Production has exactly six policies, all `SELECT`, and zero direct mutation policies:

| Table | Policy | Command | Roles | USING | WITH CHECK |
|---|---|---|---|---|---|
| `events` | `Public can view active events` | SELECT | `anon` | `is_active = true` | NULL |
| `events` | `Users can view active events` | SELECT | `authenticated` | `is_active = true` | NULL |
| `events` | `Admins and staff can view all events` | SELECT | `authenticated` | `is_admin_or_staff()` | NULL |
| `event_lanes` | `Admins and staff can view event lanes` | SELECT | `authenticated` | `is_admin_or_staff()` | NULL |
| `event_registrations` | `Users can view own event registrations` | SELECT | `authenticated` | `user_id = auth.uid()` | NULL |
| `event_registrations` | `Admins and staff can view all event registrations` | SELECT | `authenticated` | `is_admin_or_staff()` | NULL |

The target table ACL fingerprint is `a111e063df57ad30ac9feefcd8b10780`. Client roles retain only the intended reads: `anon SELECT` on `events`, and `authenticated SELECT` on all three tables. No client direct DML privilege is present.

### 21.3 Target Events RLS contract

The reviewed migration removes exactly the six policies above and creates exactly the six policies described in section 4. Public active Events remain membership-free but become constrained by `is_active_public_tenant_v1(tenant_id)`. Privileged reads require `has_tenant_role_v1(row.tenant_id, ARRAY['admin','employee','instructor'])`. Registration owner read remains `user_id = (SELECT auth.uid())` and does not require membership. No target policy uses `profiles.role`, no mutation policy is added, and target ACL remains unchanged.

`event_lanes` remains unavailable by direct anonymous table access. Public list/availability data continues through the reviewed PII-free public RPC contract; it does not require a new anonymous relation-table grant.

### 21.4 Public Events pre-deploy baseline

Production read-only smoke passed:

- `/events`: HTTP 200, expected Events content rendered, no 5xx;
- `get_public_event_list_v2`: HTTP 200, `ok=true`, contract version 2; the current upcoming page is legitimately empty;
- `get_public_event_availability_v1`: HTTP 200, three rows;
- availability fields are limited to `event_id`, public event presentation fields, capacity/count fields, `available_spots`, and `sold_out`;
- zero forbidden participant/customer/token fields and zero negative `available_spots` values;
- direct `anon` table read sees three active and zero inactive Events;
- direct `anon` access to `event_lanes` and `event_registrations` is denied by ACL.

PUBLIC EVENTS PRE-DEPLOY BASELINE: **PASS**

### 21.5 Event registration privacy baseline

A transaction-local, read-only `authenticated` role impersonation selected an existing ordinary account without emitting its identifier or PII. It saw one own registration and zero foreign registrations. An equivalent read-only admin check saw the current complete single-tenant baseline: 11 Events, 9 event-lane relations, and 25 registrations. Production currently has no employee or instructor profile, so those two baseline branches are proven by the exact deployed `is_admin_or_staff()` policy and the already-passing application/DB regressions rather than by impersonating nonexistent accounts.

Anonymous access to participant registrations remains denied. No fixture or persistent session/database change was created.

EVENT REGISTRATION PRIVACY BASELINE: **PASS**

### 21.6 Cross-tenant, IDOR, DML, and recursion evidence

The focused local suite was rerun after production baseline collection and again passed all 64 checks in one transaction with final `ROLLBACK`. It proves:

- public active CSK Event allow; inactive CSK and dormant Tenant B deny;
- User A own registrations across A/B allow, User B registration deny;
- Admin A and Employee A allow in A and deny in B;
- Instructor A retains the current same-tenant read and receives no cross-tenant access;
- global legacy admin without membership, missing membership, pending membership, and suspended membership receive no privileged access;
- cross-tenant ID substitution fails;
- direct `INSERT`, `UPDATE`, and `DELETE` remain denied;
- repeated policy evaluation completes deterministically without recursion, stack overflow, or policy recursion errors;
- independent cleanup returned zero synthetic Auth users, profiles, tenants, Events, and registrations.

CROSS-TENANT EVENTS RLS: **PASS**
RLS RECURSION: **PASS**

### 21.7 Performance and lock evidence

The five required indexes exist with the approved definitions:

- `events_tenant_active_schedule_idx`;
- `event_lanes_tenant_event_lane_idx`;
- `event_registrations_tenant_user_created_idx`;
- `tenant_memberships_tenant_role_status_user_idx`;
- `tenant_memberships_user_status_tenant_idx`.

Production membership lookup indexes already show 78 and 6 scans respectively. Event tenant indexes currently show zero scans because the tenant-aware Event policies are not deployed and the tables are very small: 11 Events, 9 event-lane rows, and 25 registrations. Their column order matches the target tenant predicates and existing schedule/user access paths. At this size sequential plans are expected and are not evidence of regression. No additional index is justified.

Policy drop/create takes short catalog/table locks on three small tables. The migration is transactional, uses `lock_timeout='5s'` and `statement_timeout='120s'`, and changes no rows. A low-traffic deployment period is sufficient; a maintenance window is not required. Any lock timeout or preflight exception is a STOP with automatic transaction rollback.

### 21.8 SECURITY DEFINER event bypass matrix

All functions below are postgres-owned `SECURITY DEFINER`, therefore bypass table RLS. None currently consumes the tenant membership helpers. They remain known SAAS-9D boundaries and are not changed by 9C-2C.

| RPC | Global role/profile check | Explicit tenant membership check | Safe for second tenant | SAAS-9D blocker |
|---|---:|---:|---:|---:|
| `admin_create_event` | Yes | No | No | Yes |
| `admin_create_event_v2` | Yes | No | No | Yes |
| `admin_update_event` | Yes | No | No | Yes |
| `admin_update_event_v2` | Yes | No | No | Yes |
| `admin_set_event_active` | Yes | No | No | Yes |
| `admin_set_event_active_v2` | Yes | No | No | Yes |
| `admin_list_events_v1` | Yes | No | No | Yes |
| `admin_list_event_registrations_v1` | Yes | No | No | Yes |
| `approve_event_registration` | Yes | No | No | Yes |
| `cancel_event_registration` | Yes | No | No | Yes |
| `mark_event_registration_paid` | Yes | No | No | Yes |
| `register_for_event` | Yes/profile | No | No | Yes |
| `get_my_event_registrations_v1` | No; owner-derived | No | No | Review in 9D |
| `get_public_event_list_v2` | No; public | No | No | Yes |
| `get_public_event_availability_v1` | No; public | No | No | Yes |
| `prepare_event_reserve_promotions` | No | No | No | Yes |
| `complete_event_reserve_promotion` | No | No | No | Yes |
| `confirm_event_reserve_promotion` | No; owner/token checks | No | No | Yes |
| `prepare_confirmation_email` | Yes/profile; shared delivery | No | No | Yes |
| `complete_confirmation_email` | No; shared claim completion | No | No | Review in 9D |

Other cross-domain definers that read Events to enforce lane/reservation conflicts remain unchanged and are also included in the complete 73-function fingerprint. This known bypass inventory is why SAAS-9D and second-tenant activation remain NO-GO.

### 21.9 Security fingerprint comparison

| Surface | Production evidence | Comparison |
|---|---|---|
| Events target ACL | `a111e063df57ad30ac9feefcd8b10780` | matches local |
| Unrelated RLS policies | `3d07aae4c2485702c66fadb946ea41f5` | matches local |
| SECURITY DEFINER inventory, normalized LF | `0dd807bea5ca20cfbaae9434b53d97a4` | all 73 functions match local |
| Sync bridge | `fe4aff8e8cbae28562f62e855004f602` | matches local |
| Tenant integrity constraints | `f698f1152b42f8741d663654eecb9514` | matches local |
| Membership helpers | four functions, postgres-owned, hardened search path | definitions and metadata match local |
| `profiles.role` | `text NOT NULL DEFAULT 'user'` | legacy source unchanged |
| Active tenant guard | partial unique `tenants_single_active_runtime_guard` | present and unchanged |
| Temporary CSK defaults | exactly seven approved core tables | unchanged |
| Event composite FKs | 3/3 validated | unchanged |

Raw cross-environment `pg_get_functiondef` hashes initially differed because Windows local migrations retain CRLF while production stores LF. Inspection isolated that formatting difference; PostgreSQL versions are both 17.6. After CRLF/LF normalization the full SECURITY DEFINER inventory matches exactly. This is not semantic or catalog drift.

### 21.10 Migration history, SHA-256, and dry-run

- Local and remote migration history are identical through `20260910120000`.
- There are no remote-only or divergent migrations.
- The only local-only migration is `20260911100000_add_tenant_aware_events_rls.sql`.
- File size: 13,769 bytes; 264 lines.
- Deployment fingerprint SHA-256: `6afb533458afba903a25eb862079dab045cffe6419dbd2b26a5319a6783d4b90`.
- The hash was recomputed after the dry-run and did not change.
- `supabase db push --linked --dry-run`: exit 0; reported exactly that one migration and explicitly stated that migrations would not be pushed.

The migration must not be edited after this point without repeating review, local verification, production preflight, SHA-256 capture, and dry-run.

### 21.11 Remaining blockers and deployment readiness

At preflight time there was no blocker to a separately authorized 9C-2C production push. That authorization was subsequently granted; the completed deployment and required post-deploy verification are recorded in section 24.

The legacy event SECURITY DEFINER inventory, temporary CSK defaults, global role compatibility bridge, SEC-008 instructor assignment residual, and incomplete application tenant context remain blockers to SAAS-9D completion, SEC-004 closure, and any second tenant.

SAAS-9C-2C PRODUCTION PREFLIGHT: **PASS**
READY FOR PRODUCTION PUSH: **YES**

## 22. Git status

Expected implementation files are unstaged and uncommitted:

- modified planning document;
- new `20260911100000_add_tenant_aware_events_rls.sql`;
- new `20260911100000_tenant_aware_events_rls_test.sql`;
- one historical public-availability test adjusted only to recognize the hardened owner policy expression;
- three historical phase-isolation tests adjusted only to admit the approved Events scope while preserving the out-of-scope RLS fingerprint;
- this implementation report.

No application, package, lockfile, historical migration, or unrelated RLS file is changed.

## 23. Local and preflight verdict

SAAS-9C-2C LOCAL IMPLEMENTATION: **PASS**

PUBLIC EVENTS CONTRACT: **PASS**

EVENT REGISTRATION PRIVACY: **PASS**

CROSS-TENANT EVENTS RLS: **PASS**

RLS RECURSION: **PASS**

LEGACY SINGLE-TENANT RUNTIME: **PASS**

SECURITY DEFINER EVENT BYPASS: **KNOWN**

READY FOR 9C-2C PRODUCTION PREFLIGHT: **GO**

SAAS-9C-2C PRODUCTION PREFLIGHT: **PASS**

PUBLIC EVENTS PRE-DEPLOY BASELINE: **PASS**

EVENT REGISTRATION PRIVACY BASELINE: **PASS**

READY FOR PRODUCTION PUSH: **YES**

READY FOR PRODUCTION WRITE: **NO**

READY FOR SAAS-9D: **NO-GO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## 24. Production deployment & post-deploy verification

### 24.1 Final pre-push gate

The linked production project was reconfirmed as `yuyxfodozzpzrdzkmolu`. Immediately before deployment:

- local and remote migration history matched through `20260910120000`;
- there was no remote-only or divergent migration;
- `20260911100000_add_tenant_aware_events_rls.sql` was the only pending migration;
- there was no migration after it in the local directory;
- SHA-256 was recomputed as `6afb533458afba903a25eb862079dab045cffe6419dbd2b26a5319a6783d4b90`;
- `supabase db push --linked --dry-run` exited 0 and listed exactly that migration.

The final read-only membership/data gate matched the approved baseline:

| Check | Result |
|---|---:|
| Active tenants | 1 |
| Memberships | 9 |
| Active memberships | 9 |
| Roles | `admin=1`, `user=8` |
| Statuses | `active=9` |
| Duplicate `(tenant_id,user_id)` | 0 |
| Orphan `user_id` | 0 |
| Orphan `tenant_id` | 0 |
| Unknown membership role | 0 |
| Invalid membership status | 0 |
| Legacy/profile role mismatch | 0 |

### 24.2 Exact migration deployed

The authorized command `supabase db push --linked` applied exactly:

`20260911100000_add_tenant_aware_events_rls.sql`

The command exited 0. No other migration, manual SQL, migration repair, application change, dependency change, or tenant activation was performed.

Post-deploy verification returned:

- `20260911100000` local = remote;
- no remote-only or local-only migration;
- post-deploy `supabase db push --linked --dry-run`: exit 0, `Remote database is up to date.`

### 24.3 Deployed Events RLS

RLS remains enabled on `events`, `event_lanes`, and `event_registrations`. Production contains exactly six target policies, all `SELECT`, and zero mutation policies:

| Table | Policy | Role | Effective predicate |
|---|---|---|---|
| `events` | `Public can view active tenant events` | anon | active row and active public tenant |
| `events` | `Authenticated users can view active tenant events` | authenticated | active row and active public tenant |
| `events` | `Tenant staff can view events` | authenticated | active tenant membership with admin/employee/instructor role |
| `event_lanes` | `Tenant staff can view event lanes` | authenticated | active tenant membership with admin/employee/instructor role |
| `event_registrations` | `Users can view own event registrations` | authenticated | `user_id = auth.uid()` |
| `event_registrations` | `Tenant staff can view event registrations` | authenticated | active tenant membership with admin/employee/instructor role |

The previous six global/legacy policies are absent. Direct client-table boundaries remain unchanged: anon can read only `events`, not `event_lanes` or `event_registrations`; authenticated has no direct `INSERT`, `UPDATE`, or `DELETE` privilege on any target table.

### 24.4 Public Events and registration privacy

Post-deploy public verification passed:

- `/events` rendered successfully with no 5xx, raw backend error, or browser console error;
- anon direct RLS read returned three active Events and zero inactive Events;
- `get_public_event_list_v2(null,'upcoming',1,50)` returned `ok=true`, contract version 2;
- `get_public_event_availability_v1()` returned three rows;
- zero negative `available_spots` values;
- zero fields outside the approved PII-free availability contract;
- anon retains EXECUTE on both public read RPCs.

A transaction-local read-only ordinary-user impersonation returned one own registration and zero foreign registrations. The user saw the three public active Events and no direct `event_lanes`. No identifier or PII was emitted.

A transaction-local read-only admin impersonation returned 11 Events, nine event-lane relations, and 25 registrations, all for CSK; non-CSK counts were zero for every target table. Production still has no employee or instructor account, so those branches are proven by the exact deployed tenant-membership predicates and the focused 64-check local matrix rather than by inventing production identities.

### 24.5 Application runtime smoke

The existing authenticated production session was used only for read-only navigation. The following routes rendered their expected headings and data without a 5xx, raw DB/Supabase error, or browser console error:

- `/booking`;
- `/login` and `/register`;
- `/account`;
- `/admin`;
- `/admin/reservations`;
- `/admin/calendar` (final schedule grid and filters loaded);
- `/admin/reports`;
- `/events`;
- `/my-events` (the owner registration loaded; details and cancellation eligibility rendered);
- `/admin/events?scope=all` (event list, lane assignment data, availability and participant view loaded);
- `/admin/check-in`;
- `/admin/lane-configuration`.

No mutation CTA was submitted. No fixture was created, so cleanup was not required.

### 24.6 Security fingerprint after deployment

Only the approved Events policy fingerprint changed. All protected comparison surfaces remained identical to the pre-deploy baseline:

| Surface | Post-deploy value/result |
|---|---|
| Target Events ACL | `a111e063df57ad30ac9feefcd8b10780` — unchanged |
| Unrelated RLS policies | `3d07aae4c2485702c66fadb946ea41f5` — unchanged |
| SECURITY DEFINER inventory | 73 functions, normalized fingerprint `0dd807bea5ca20cfbaae9434b53d97a4` — unchanged |
| Membership helpers | local = production fingerprint `5f1144a2c049b5f2d2c4c3ff1e638e7c` |
| `profiles.role` | `text NOT NULL DEFAULT 'user'` — unchanged |
| Active tenant guard | `tenants_single_active_runtime_guard` — unchanged |
| Temporary CSK defaults | exactly seven approved tables — unchanged |
| Sync bridge | pre-deploy protected fingerprint unchanged by transactional migration postflight |
| Tenant integrity | pre-deploy protected fingerprint unchanged by transactional migration postflight |

The migration itself captured and compared unrelated policy, full SECURITY DEFINER, and target ACL fingerprints inside the same transaction. Its successful completion is additional fail-closed proof that no unauthorized catalog surface changed during deployment.

### 24.7 Remaining risk and phase boundary

Legacy event `SECURITY DEFINER` functions still bypass direct-table RLS and do not yet consume tenant membership context. Their inventory is known and unchanged. This remains explicit SAAS-9D work; it is not a 9C-2C regression.

Temporary CSK defaults, the legacy global role compatibility bridge, missing application tenant context, and the SEC-008 instructor assignment residual also remain. Therefore a second tenant is still prohibited and SEC-004 remains open.

## 25. Final production verdict

SAAS-9C-2C PRODUCTION DEPLOY: **PASS**

SAAS-9C-2C POST-DEPLOY: **PASS**

PUBLIC EVENTS: **PASS**

EVENT REGISTRATION PRIVACY: **PASS**

TENANT-AWARE EVENTS RLS: **PASS**

SECURITY DEFINER EVENT BYPASS: **KNOWN / UNCHANGED**

READY FOR GIT CHECKPOINT: **YES**

READY FOR NEXT SAAS-9C PHASE: **GO**

READY FOR SAAS-9D: **NO-GO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**
