# SAAS-9D — Tenant-Aware RPC / SECURITY DEFINER Hardening

Technical implementation plan with the approved SAAS-9D-1 local execution record. Planning and local implementation date: 2026-09-11 (Europe/Warsaw).

Repository baseline: `02af6857a88e37d30b6e4b1159496cecff91bac1` on `main`, identical to `origin/main` when this plan was prepared.

The original plan was planning-only. SAAS-9D-1 is now closed with production PASS, and the later sections record its checkpoint plus the reviewed SAAS-9D-2 plan. Nothing in this document authorizes SAAS-9D-2 implementation, a production write or a second tenant.

## 1. Executive summary

SAAS-9C closed the direct-table RLS boundary, but every `SECURITY DEFINER` function can execute outside that boundary. The authoritative SAAS-9C-2E production catalog contains exactly 73 such functions, fingerprint `0dd807bea5ca20cfbaae9434b53d97a4`. The local schema reconstructed from the same migration history has the same 73 signatures and security metadata.

The central 9D invariant is:

1. resolve the authenticated actor with `auth.uid()`;
2. derive the tenant from an existing trusted resource whenever one exists;
3. require an active membership and the exact allowed tenant role;
4. bind every related read, mutation and audit row to that same tenant;
5. reject a caller-supplied tenant when it differs from the resource tenant;
6. never use global `profiles.role` as tenant authorization.

Existing-resource operations can normally preserve their signatures because tenant is derived from `reservation_id`, `registration_id`, `event_id`, `lane_id`, `block_id`, token or claim. Create/list/report/user-management/public-list operations have no trusted target and need either a versioned tenant argument plus application cutover, or a narrowly bounded CSK compatibility wrapper while the single-active-tenant guard remains effective. The compatibility wrapper is not permission to activate Tenant B.

The recommended first implementation slice is 9D-1A: reservation creation, cancellation, check-in and operational reservation RPCs. It needs no application tenant selector because all target tenants can be derived. Production write remains separately gated.

## 2. Authoritative 73-function inventory

Legend used to keep the complete inventory readable:

- `SP1` = `pg_catalog, public, pg_temp` (target baseline); `SP2` = `public, pg_temp`; `SP3` = `public`.
- grants list direct EXECUTE grantees in addition to owner `postgres`: `A` authenticated, `N` anon, `S` service_role, `—` none.
- caller codes: `RES` reservation UI/API, `EVT` event UI/API, `LANE` lane admin UI, `REP` reports UI, `USR` users/check-in UI, `PUB` public UI, `MAIL` email route/helper, `PROMO` reserve-promotion helper, `ACCT` account API/UI, `DB` trigger/internal SQL, `LEG` no current TypeScript caller or retained legacy version.
- `derive` names the trusted lookup; `context` means the function must receive or resolve a selected tenant before a second tenant can exist.
- all rows below are `SECURITY DEFINER=yes`, owner `postgres`, and therefore an RLS-bypass boundary.

| # | Function signature | Path | Grants | Callers | Global role check | Tenant arg | Resource arg | Can derive tenant? | Cross-tenant risk | Severity | Target phase |
|---:|---|---|---|---|---:|---:|---:|---|---|---|---|
| 1 | `active_single_tenant_id_v1()` | SP1 | — | DB | no | no | no | single-active guard only | bridge misuse after Tenant B | SAFE now | 9D-5 review |
| 2 | `admin_create_event(text,text,date,time,time,text,numeric,int,uuid[])` | SP2 | S | LEG | yes | no | lane IDs | only if every lane is same tenant; empty list cannot | global create/bypass | CRITICAL | 9D-2 retire |
| 3 | `admin_create_event_v2(text,text,date,time,time,text,numeric,int,uuid[])` | SP1 | A | EVT | yes | no | lane IDs | partial; explicit context still required | global create | CRITICAL | 9D-2A |
| 4 | `admin_create_lane_block(uuid,date,time,time,text)` | SP1 | A | LANE | yes | no | lane | lane | foreign-lane write | CRITICAL | 9D-3A |
| 5 | `admin_create_lane_booking_family_v1(jsonb)` | SP1 | A | LANE | yes | no | payload only | no trusted existing resource | global create | CRITICAL | 9D-3B |
| 6 | `admin_get_lane_booking_configuration_v1()` | SP1 | A | LEG | yes | no | no | context required | global admin read | HIGH | 9D-3 retire |
| 7 | `admin_get_lane_booking_configuration_v2()` | SP1 | A | LANE | yes | no | no | context required | global admin read | HIGH | 9D-3B |
| 8 | `admin_get_reservation_report_export_v1(date,date,uuid,text,text,text)` | SP1 | A | REP | yes | no | optional resource | resource if supplied; context otherwise | global report/PII | HIGH | 9D-4A |
| 9 | `admin_get_reservation_report_v1(date,date,int,int)` | SP1 | A | LEG | yes | no | no | context required | global report/PII | HIGH | 9D-4 retire |
| 10 | `admin_get_reservation_report_v2(date,date,uuid,text,text,text,int,int)` | SP1 | A | REP | yes | no | optional resource | resource if supplied; context otherwise | global report/PII | HIGH | 9D-4A |
| 11 | `admin_list_event_registrations_v1(uuid,text,text,int,int)` | SP1 | A | EVT | yes | no | event | event | participant PII across tenants | HIGH | 9D-2B |
| 12 | `admin_list_events_v1(text,text,text,int,int)` | SP1 | A | EVT | yes | no | no | context required | global admin list | HIGH | 9D-2B |
| 13 | `admin_list_users_v1(int,int,text,text,text,text)` | SP1 | A | USR | yes | no | target absent | context + operational relation required | global profile PII | CRITICAL | 9D-4B |
| 14 | `admin_set_event_active(uuid,bool)` | SP2 | S | LEG | yes | no | event | event | service/global mutation | CRITICAL | 9D-2 retire |
| 15 | `admin_set_event_active_v2(uuid,bool)` | SP1 | A | EVT | yes | no | event | event | foreign event mutation | CRITICAL | 9D-2A |
| 16 | `admin_set_lane_block_active(uuid,bool)` | SP1 | A | LANE | yes | no | block | block -> lane tenant | foreign block mutation | CRITICAL | 9D-3A |
| 17 | `admin_set_lane_booking_configuration(uuid,bool,bool,bool,int,bool,int,int[],jsonb)` | SP1 | — | LEG | yes | no | lane | lane | internal legacy writer | HIGH | 9D-3 retire |
| 18 | `admin_set_lane_booking_family_configuration_v2(uuid,bigint,jsonb,bool)` | SP1 | A | LANE | yes | no | root lane | root/family | foreign family mutation | CRITICAL | 9D-3A |
| 19 | `admin_set_user_note_v1(uuid,text)` | SP1 | A | USR | yes | no | user only | context + target relationship | cross-tenant profile update | CRITICAL | 9D-4B |
| 20 | `admin_set_user_role_v1(uuid,text)` | SP1 | A | USR | yes | no | user only | selected tenant membership | global privilege mutation | CRITICAL | 9D-4B |
| 21 | `admin_update_event(uuid,text,text,date,time,time,text,numeric,int,uuid[])` | SP2 | S | LEG | yes | no | event/lanes | event, then cross-check lanes | service/global mutation | CRITICAL | 9D-2 retire |
| 22 | `admin_update_event_v2(uuid,text,text,date,time,time,text,numeric,int,uuid[])` | SP1 | A | EVT | yes | no | event/lanes | event, cross-check every lane | foreign event/lane binding | CRITICAL | 9D-2A |
| 23 | `admin_update_lane_block(uuid,uuid,date,time,time,text,bool)` | SP1 | A | LANE | yes | no | block/lane | block and lane; must match | cross-tenant reparent/write | CRITICAL | 9D-3A |
| 24 | `anonymize_my_account_v1()` | SP1 | A | ACCT | yes | no | caller UID | caller-owned rows across memberships | global lifecycle spill | HIGH | 9D-4C |
| 25 | `approve_event_registration(uuid)` | SP2 | A | EVT | yes | no | registration | registration -> event | foreign participant mutation | CRITICAL | 9D-2A |
| 26 | `cancel_event_registration(uuid)` | SP2 | A,S | EVT | yes | no | registration | registration -> event | owner/staff cross-tenant confusion | CRITICAL | 9D-2A |
| 27 | `cancel_reservation(uuid)` | SP1 | A,S | RES | yes | no | reservation | reservation | owner/staff cross-tenant confusion | CRITICAL | 9D-1A |
| 28 | `check_confirmation_email_rate_limit(uuid,text)` | SP2 | S | MAIL | no | no | user/IP | caller/claim context; user is not sufficient | cross-tenant rate-limit coupling | MEDIUM | 9D-2C |
| 29 | `complete_confirmation_email(uuid,bool,text,text)` | SP2 | S | MAIL | no | no | claim | claim -> delivery tenant | foreign claim completion | HIGH | 9D-2C |
| 30 | `complete_event_reserve_promotion(uuid,uuid,bool,text)` | SP2 | S | PROMO | no | no | registration/claim | both; must match | service cross-tenant completion | CRITICAL | 9D-2C |
| 31 | `confirm_event_reserve_promotion(text)` | SP2 | A | EVT | no | no | bearer token | token -> registration -> event; actor owner | token/owner mismatch | CRITICAL | 9D-2A |
| 32 | `create_reservation(uuid,date,time,int,int,uuid,text)` | SP1 | S | LEG | yes | no | lane | lane | legacy service/global writer | CRITICAL | 9D-1 retire |
| 33 | `create_reservation_v2(uuid,date,time,int,int,uuid,text)` | SP1 | A,S | RES | yes | no | lane | lane | foreign-lane create | CRITICAL | 9D-1A |
| 34 | `export_my_data_v1()` | SP1 | A | ACCT | no | no | caller UID | caller rows, preserving each row tenant | cross-tenant owner export ambiguity | HIGH | 9D-4C |
| 35 | `get_check_in_reservation_v1(uuid)` | SP1 | A | USR | yes | no | check-in token | token -> reservation | staff PII/token bypass | HIGH | 9D-1B |
| 36 | `get_lane_booking_busy_ranges(uuid,date)` | SP1 | A,S | LEG | no | no | lane | lane | tenant-blind legacy availability | MEDIUM | 9D-1 retire |
| 37 | `get_lane_booking_busy_ranges_v2(uuid,date)` | SP1 | A,S | LEG | no | no | lane | lane | tenant-blind legacy availability | MEDIUM | 9D-1 retire |
| 38 | `get_lane_booking_busy_ranges_v3(uuid,date)` | SP1 | A,S | PUB/RES | no | no | lane | lane | cross-tenant availability inference | HIGH | 9D-1B |
| 39 | `get_my_event_registrations_v1(text,text,int,int)` | SP1 | A | EVT | no | no | caller UID | rows by UID; selected context needed in 9E | cross-tenant aggregation in future | MEDIUM | 9D-2B/9E |
| 40 | `get_my_reservations_v2()` | SP1 | A | RES | no | no | caller UID | rows by UID; selected context needed in 9E | cross-tenant aggregation in future | MEDIUM | 9D-1B/9E |
| 41 | `get_my_role()` | SP3 | A | PUB/admin pages | yes | no | no | no | global authorization | CRITICAL | 9D-4D then 9E |
| 42 | `get_my_tenant_role_v1(uuid)` | SP1 | A | DB/future app | no | yes | no | explicit tenant + membership | caller chooses tenant but check binds actor | SAFE | retain |
| 43 | `get_public_booking_configuration_v1()` | SP1 | N,A,S | PUB | no | no | no | active-single bridge only | wrong tenant after activation | HIGH | 9D-4E/9E |
| 44 | `get_public_check_in_status_v1(uuid)` | SP1 | N | PUB | no | no | token | token -> reservation | bearer cross-tenant disclosure | HIGH | 9D-1B |
| 45 | `get_public_event_availability_v1()` | SP1 | N,A | PUB | no | no | no | active-single bridge only | aggregate tenant mixing | HIGH | 9D-2B/9E |
| 46 | `get_public_event_list_v2(text,text,int,int)` | SP1 | N,A | PUB | no | no | no | active-single bridge only | public tenant mixing | HIGH | 9D-2B/9E |
| 47 | `get_reservation_customer_profiles_v1(uuid[])` | SP1 | A | USR/MAIL | yes | no | reservations | every reservation; same tenant required | bulk cross-tenant PII | CRITICAL | 9D-1B |
| 48 | `handle_new_user()` | SP2 | — | DB trigger | yes | no | NEW user | no tenant without onboarding context | wrong automatic membership | HIGH | 9D-4D/9E |
| 49 | `has_tenant_role_v1(uuid,text[])` | SP1 | A | RLS/9D functions | no | yes | no | explicit tenant + membership | low if roles allowlisted | SAFE | retain |
| 50 | `is_active_public_tenant_v1(uuid)` | SP1 | N,A | RLS/public helpers | no | yes | no | explicit tenant + active status | low; public boolean only | SAFE | retain |
| 51 | `is_admin()` | SP3 | A | DB/legacy | yes | no | no | no | global authorization | CRITICAL | 9D-4D retire |
| 52 | `is_admin_or_employee()` | SP3 | A | DB/legacy | yes | no | no | no | global authorization | CRITICAL | 9D-4D retire |
| 53 | `is_admin_or_staff()` | SP3 | A | DB/legacy | yes | no | no | no | global authorization | CRITICAL | 9D-4D retire |
| 54 | `is_tenant_member_v1(uuid)` | SP1 | A | RLS/9D functions | no | yes | no | explicit tenant + membership | low | SAFE | retain |
| 55 | `lane_booking_family_business_snapshot_v2(uuid)` | SP1 | — | DB internal | no | no | root lane | root/family | internal data leak only if grant widens | SAFE | 9D-3 review |
| 56 | `mark_event_registration_paid(uuid)` | SP1 | A | EVT | yes | no | registration | registration -> event | foreign participant/payment mutation | CRITICAL | 9D-2A |
| 57 | `normalize_lane_booking_family_payload_v2(jsonb)` | SP1 | — | DB internal | no | no | payload | caller function must bind result | no direct client surface | SAFE | 9D-3 review |
| 58 | `prepare_confirmation_email(text,uuid)` | SP2 | A | MAIL | yes | no | typed record | message type -> record tenant | cross-tenant recipient/claim | CRITICAL | 9D-2C |
| 59 | `prepare_event_reserve_promotions(uuid)` | SP2 | S | PROMO | no | no | event | event | service cross-tenant token creation | CRITICAL | 9D-2C |
| 60 | `prevent_non_admin_profile_privilege_changes()` | SP1 | — | DB trigger | yes | no | OLD/NEW profile | membership context absent | legacy privilege guard mismatch | HIGH | 9D-4D |
| 61 | `register_for_event(uuid,bool)` | SP2 | A | EVT | no | no | event | event + actor membership/owner semantics | foreign-event registration | CRITICAL | 9D-2A |
| 62 | `sync_csk_membership_role_to_profile()` | SP1 | — | DB trigger | yes | no | NEW membership | fixed CSK bridge | unsafe beyond CSK | HIGH bridge | 9D-5/9E retire |
| 63 | `sync_profile_role_to_csk_membership()` | SP1 | — | DB trigger | no | no | NEW profile | fixed CSK bridge | unsafe beyond CSK | HIGH bridge | 9D-5/9E retire |
| 64 | `update_my_profile_v1(text,text,text,text,text,text,bool,bool,bool,bool,bool,bool,bool,bool,bool,bool)` | SP1 | A | ACCT | yes | no | caller UID | owner profile; membership status policy needed | cross-tenant membership ambiguity | HIGH | 9D-4C |
| 65 | `update_profile_contact_details(uuid,text,text,text,text,text,text)` | SP2 | A,S | USR | yes | no | target user | context + operational relationship | cross-tenant PII mutation | CRITICAL | 9D-4B |
| 66 | `update_profile_identity(uuid,text,text)` | SP2 | A,S | USR | yes | no | target user | context + operational relationship | cross-tenant PII mutation | CRITICAL | 9D-4B |
| 67 | `update_profile_verification(uuid,text,text)` | SP2 | A,S | USR | yes | no | target user | context + operational relationship | cross-tenant privilege/PII | CRITICAL | 9D-4B |
| 68 | `update_reservation_admin_note(uuid,text)` | SP1 | A | RES | yes | no | reservation | reservation | foreign reservation PII mutation | CRITICAL | 9D-1A |
| 69 | `update_reservation_attendance(uuid,text)` | SP1 | A,S | RES/USR | yes | no | reservation | reservation | foreign attendance mutation | CRITICAL | 9D-1A |
| 70 | `update_reservation_payment(uuid,text)` | SP1 | A | RES/USR | yes | no | reservation | reservation | foreign payment mutation | CRITICAL | 9D-1A |
| 71 | `validate_lane_booking_rule_capacity()` | SP1 | — | DB trigger | no | no | NEW lane_id | lane | trigger integrity only | SAFE | 9D-3 review |
| 72 | `validate_shooting_lane_capacity_change()` | SP1 | — | DB trigger | no | no | OLD/NEW lane | lane/root | trigger integrity only | SAFE | 9D-3 review |
| 73 | `validate_shooting_lane_hierarchy()` | SP1 | — | DB trigger | no | no | OLD/NEW lane | lane/root | trigger integrity only | SAFE | 9D-3 review |

Catalog conclusions:

- 73/73 are RLS-bypass boundaries; 73/73 are owned by `postgres`.
- No function has a tenant argument except the four approved tenant helpers (`get_my_tenant_role_v1`, `has_tenant_role_v1`, `is_active_public_tenant_v1`, `is_tenant_member_v1`).
- Four legacy functions use `search_path=public`; sixteen use `public, pg_temp`; 53 use the target SP1 baseline.
- No new EXECUTE grant is needed. Existing grants are an upper bound; obsolete v1/service-role grants should be removed only after zero-caller proof.

## 3. Severity classification

| Class | Meaning | Functions | Required result |
|---|---|---|---|
| CRITICAL | Mutates tenant-owned data, privileged PII or roles and lacks a complete tenant-bound authorization invariant | 36 functions, including active reservation/event/lane writers, admin profile mutations, email/promotion claims and legacy global-role helpers | harden before Tenant B; cross-tenant deny and audit proof mandatory |
| HIGH | Privileged read, public aggregate, lifecycle, trigger or bridge can cross/mix tenants | 22 functions (including two CSK-only bridge triggers) | tenant-bound read/DTO or explicit retirement gate |
| MEDIUM | Technical/owner/list helper has bounded impact but lacks future tenant context | 5 functions | review and test in its domain phase |
| SAFE / NO CHANGE | approved tenant helpers or internal trigger/normalizer with no client grant and no authorization decision | 10 functions | preserve fingerprint unless review proves a narrowly scoped hardening need |

Counts are planning classifications, not a claim that SAFE functions cease to be privileged. All remain in the final fingerprint/ACL audit.

## 4. Reservation RPCs

### 4.1 Write invariant

- `create_reservation_v2`: load `shooting_lanes.tenant_id` for `p_lane_id` before validation/locking; require the caller to be an active member of that tenant with the existing customer role semantics; explicitly insert `reservations.tenant_id`; keep atomic capacity checks and idempotency key unchanged.
- `cancel_reservation`: load reservation once under lock; derive tenant; allow owner only under the existing cutoff rule or tenant admin/employee under current staff semantics; never authorize using global profile role.
- attendance/payment/admin-note: derive tenant from reservation, require active admin/employee membership, keep existing action transition, no-change and audit semantics.
- profile batch read: every requested reservation must belong to the caller's authorized tenant. Mixed-tenant arrays fail closed; do not silently return a partial set.

### 4.2 Check-in and availability

- authenticated check-in derives tenant from the token's reservation, then requires the current staff role.
- public check-in remains bearer-token scoped and PII-minimized; tenant is derived from the reservation and never supplied by the browser.
- busy ranges derive tenant from the lane and query only rows/blocks/events with matching tenant. Public booking access must still require an active public tenant/lane.
- preserve hierarchy locks, canonical overlap semantics and active/inactive historical visibility.

### 4.3 Compatibility

All active 9D-1 signatures can remain unchanged. That makes `OLD APP + NEW DB` safe for this phase. Legacy `create_reservation` and busy-range v1/v2 remain non-browser contracts and are revoked/retired only after dependency and production-call verification.

## 5. Event RPCs

- Targeted event/registration functions derive tenant from the event or registration and cross-check every lane in `event_lanes`.
- Create requires an explicit trusted tenant because an event can have zero lanes. Introduce a versioned signature or a server-resolved wrapper; do not infer tenant solely from the first lane.
- Update derives tenant from the event, then rejects any lane whose tenant differs.
- Admin list needs selected tenant context; participant list derives tenant from `p_event_id` and checks membership before returning its minimal DTO.
- `register_for_event` binds actor, event tenant and inserted registration tenant; reserve/capacity logic remains atomic.
- Cancel/approve/payment/promotion derive through registration -> event and keep exactly one tenant-bound audit.
- Public list/availability need tenant resolution from trusted host/slug in 9E. Until then, the sole-active-CSK wrapper may remain only while `tenants_single_active_runtime_guard` prevents a second active tenant.
- Promotion and email claims persist tenant identity at preparation and verify the same tenant at completion.

## 6. Lane/configuration RPCs

- Block create derives from lane. Block update derives separately from existing block and proposed lane and rejects mismatch.
- Family configuration derives from root and verifies all payload resource IDs belong to that root and tenant before locking or mutation.
- Family creation has no trusted existing resource. Add a versioned contract with `p_tenant_id`, require tenant admin membership, and explicitly write tenant to root, positions, rules, durations and pricing relations through their lane ownership.
- Admin configuration list requires selected tenant context; public booking configuration is handled as a public selected-tenant contract in 9E.
- Internal snapshot/normalizer/validation functions retain internal-only grants and receive tenant-bound inputs only from the hardened parent writer.

## 7. Reports RPCs

- Add a versioned `p_tenant_id` to unfiltered report/list contracts; require active tenant admin membership.
- If `p_resource_id` is present, derive its tenant and require equality with `p_tenant_id`.
- Apply tenant predicate before aggregate, detail pagination, revenue and export limits so KPI and detail scope stay identical.
- CSV remains bounded to 5000 and PII-minimized; tenant ID does not need to be exposed in the DTO.
- v1/v2 legacy wrappers may resolve sole active CSK only during compatibility; remove after 9E call sites supply trusted context.

## 8. Profile/admin RPCs

- `admin_list_users_v1` must become tenant-contextual and return only members/operationally related customers permitted by the product rule. It must not restore global profile browsing.
- `admin_set_user_role_v1` must evolve into tenant-membership role management. It must not write a future tenant role into global `profiles.role`; the CSK sync bridge remains only during legacy cutover.
- note, identity, contact and verification operations require tenant admin/approved employee membership plus an explicit operational relationship between target user and tenant. Employee restrictions remain unchanged.
- self profile/export/anonymization stay caller-owned. They may operate over the user's rows across tenants only under an explicitly documented account-wide lifecycle contract; they must never use a selected tenant to access another user.
- `get_my_role` and `is_admin*` are removed from authorization only after all app and DB call sites use tenant membership. They are not rewritten to guess the sole tenant as a permanent solution.

## 9. Audit helpers

There is no standalone client audit-writer RPC in the 73-function inventory. Audit writes occur inside trusted business functions. Every hardened writer must:

- set audit `tenant_id` from the same locked resource used for authorization;
- preserve `tenant_id=NULL` only for approved global/account lifecycle actions;
- set actor from `auth.uid()` (or an explicitly documented server identity), timestamp in DB, and stable action/target values;
- create no audit on denied/no-change/idempotent repeat;
- reject mismatched event/registration/lane/reservation targets before an audit is written;
- never include PII, bearer tokens, JWTs, provider secrets or service-role keys.

The final 9D audit must compare the action/target classification map introduced in 9B-2 with every live audit-producing function.

## 10. `service_role` paths

RLS and membership helper grants do not protect a service-role client. Each path therefore needs authorization before the service client is created or used.

| Path | Current use | Current authentication | Tenant resolution target | 9D requirement |
|---|---|---|---|---|
| `app/api/account/delete/route.ts` | Auth Admin `deleteUser` after `anonymize_my_account_v1` | bearer JWT verified by anon client | user-owned account lifecycle; not selected tenant | keep service key only for Auth deletion; DB anonymization remains user-JWT RPC; verify no arbitrary user ID |
| `lib/server/confirmation-email-delivery.ts` plus three send-email routes | service client completes delivery claims and rate limits | each route verifies caller and uses user-JWT `prepare_confirmation_email` | derive at prepare from typed record; persist on delivery claim | completion must verify claim tenant/record and never accept recipient/tenant from browser |
| `lib/server/event-reserve-promotion.ts`, called by `app/api/send-event-reserve-promotion/route.ts` | service RPC prepares/completes reserve promotions | API route must authorize triggering event action | derive from event, bind every registration and claim | pass trusted actor/tenant proof into a hardened server contract; reject cross-tenant event IDs before service RPC |

Additionally, legacy DB grants to service_role (`admin_create_event`, `admin_set_event_active`, `admin_update_event`, `create_reservation`, and selected active functions) need zero-runtime-caller proof. Revoke obsolete grants; for necessary server completions keep only the exact claim-based function.

## 11. Tenant derivation strategy

| Input | Trusted chain | Required cross-check |
|---|---|---|
| `reservation_id` | `reservations.tenant_id` | lane tenant and any related audit/delivery row match |
| `check_in_token` | token -> reservation -> tenant | token validity/status/window before DTO |
| `lane_id` | `shooting_lanes.tenant_id` | family root and all conflict resources have same tenant |
| `block_id` | block -> lane/tenant | proposed lane tenant equals existing block tenant |
| `event_id` | `events.tenant_id` | all event lanes and registrations match |
| `registration_id` | registration -> event -> tenant | registration tenant equals event tenant |
| `claim_id` | delivery/promotion claim -> record -> tenant | caller-supplied record ID, when present, equals claim target |
| `target_user_id` | selected tenant membership or operational reservation/registration relationship | target relation belongs to selected tenant; global profile role is irrelevant |
| create/list/report without target | trusted `p_tenant_id` selected by server/app context | active tenant plus active membership/role; never rely on client assertion alone |
| public list without target | host/slug -> active tenant (9E) | public contract only; no membership or PII |

Any lookup returning zero or multiple tenants fails closed. Mixed-resource arrays are rejected, not partially processed.

## 12. Membership authorization strategy

- Admin: `has_tenant_role_v1(tenant, ['admin'])` for admin-only operations.
- Employee: include `employee` only where current product behavior allows it; never broaden admin-only config/reports/user-role operations.
- Instructor: include only current approved event/lane read scope. SEC-008 remains deferred and 9D must not invent an instructor-event assignment.
- User: owner action requires `auth.uid() = resource.user_id`; where the current RLS/product requires membership, also require active membership in the resource tenant.
- No membership, pending/suspended membership, inactive tenant or NULL actor: privileged operation denied.
- For server claim completion, authorization is the unforgeable claim created by an already-authorized prepare step, bound to tenant and target; it is not a generic service-role bypass.

Use the tenant helpers for authorization but still perform resource/tenant equality checks in the same transaction. Membership check alone is insufficient for IDOR protection.

## 13. `search_path`, owner and grants baseline

For every changed function:

1. `SECURITY DEFINER`, owner `postgres` only when definer privilege is genuinely required; otherwise convert to invoker/internal SQL where safe.
2. explicit `SET search_path = pg_catalog, public, pg_temp` and schema-qualified objects/functions;
3. `REVOKE ALL ... FROM PUBLIC, anon, authenticated, service_role` followed by the minimum exact grant;
4. no grant widening relative to the inventory;
5. internal triggers/helpers remain owner-only;
6. public PII-free readers get only anon/authenticated as required; token check-in stays anon only;
7. active browser RPCs get authenticated only; service-role claim completions get service_role only;
8. obsolete v1 functions lose non-owner EXECUTE after confirmed zero callers.

SP2/SP3 functions must be normalized when touched. The migration test must fail if any changed function has an unsafe/missing path, unexpected owner, PUBLIC execute or broader grant.

## 14. Application caller matrix

| File(s) | RPCs | Arguments today | Tenant context today | Target context | App change? | Phase |
|---|---|---|---|---|---:|---|
| `app/api/create-reservation/route.ts` | `create_reservation_v2` | lane/date/time/duration/count/request/note | none | derive from lane | no | 9D-1A |
| `app/booking/BookingForm.tsx` | `get_lane_booking_busy_ranges_v3` | lane/date | none | derive from lane | no | 9D-1B |
| `app/booking/page.tsx` | `get_public_booking_configuration_v1` | none | sole active CSK | host/slug tenant | yes, 9E | 9D-4E/9E |
| `app/my-reservations/page.tsx`, `app/api/calendar/reservations/[id]/route.ts` | `get_my_reservations_v2`, `cancel_reservation` | caller or reservation | none | selected tenant for list; derive for cancel | list yes in 9E; cancel no | 9D-1 |
| `lib/reservation-actions.ts`, admin reservation/check-in pages | attendance/payment/note/cancel | reservation/action | none | derive from reservation | no | 9D-1A |
| `app/admin/check-in/page.tsx` | check-in/profile batch/verification | token, reservation IDs, target user | global role | derive reservation tenant; relationship for profile | verification contract likely versioned | 9D-1B/4B |
| `app/check-in/[token]/page.tsx` | `get_public_check_in_status_v1` | token | bearer token | derive from reservation | no | 9D-1B |
| reservation email routes | rate-limit/prepare/complete | user/IP hash, type/record, claim result | authenticated prepare + service completion | record/claim-derived | internal helper change | 9D-2C |
| `app/events/page.tsx` | `get_public_event_list_v2` | search/scope/page | sole active CSK | host/slug tenant | yes, 9E | 9D-2B/9E |
| `app/my-events/page.tsx` | `get_my_event_registrations_v1` | scope/status/page | caller only | selected tenant | yes, 9E | 9D-2B/9E |
| event register/cancel/confirm APIs | register/cancel/confirm RPCs | event/registration/token | none | target-derived | no | 9D-2A |
| `app/admin/events/page.tsx` | list/create/update/active/participants/approve/payment | filters or target IDs | global role | explicit selected tenant for list/create; derive for targets | yes for list/create; target calls can stay | 9D-2 |
| reserve-promotion API/helper | prepare/complete promotion | event/registration/claim | service client | event/claim-derived | server helper change | 9D-2C |
| `app/admin/lane-blocks/page.tsx` | block create/update/active | lane/block | global role | resource-derived | no | 9D-3A |
| `app/admin/lane-configuration/page.tsx` | config list/family create/update | none, payload, root | global role | selected tenant for list/create; derive update | yes for list/create | 9D-3 |
| `app/admin/reports/page.tsx` | report v2/export | dates/filters/optional resource | global role | selected tenant | yes | 9D-4A/9E |
| `app/admin/users/page.tsx` | list/role/note/verification/identity/contact | filters/target user | global role | selected tenant + relationship | yes | 9D-4B/9E |
| `app/account/page.tsx`, account export/delete APIs | self update/export/anonymize | caller/self fields | caller UID | account-wide owner contract | no selected tenant required | 9D-4C |
| homepage/admin pages/calendar feed | `get_my_role` | none | global role | `get_my_tenant_role_v1(selected)` | yes | 9D-4D/9E |

No application source change belongs in the planning task. Calls marked 9E must not be broken by an earlier 9D migration.

## 15. Temporary CSK defaults retirement plan

Current default for all seven rows is fixed CSK UUID `c5c00000-0000-4000-8000-000000000001`.

| Table | Current writer(s) | Tenant-aware writer ready now? | Planned explicit/derived tenant | Remove in | Blocker if early? |
|---|---|---:|---|---|---:|
| `reservations` | `create_reservation_v2` (legacy v1 retained) | no | derive `p_lane_id`; explicit INSERT | 9D-5 after 9D-1 prod proof | yes, creates would fail |
| `shooting_lanes` | `admin_create_lane_booking_family_v1` | no | trusted selected tenant argument | 9D-5 after 9D-3 + app cutover | yes |
| `lane_blocks` | `admin_create_lane_block` | no | derive lane | 9D-5 after 9D-3 prod proof | yes |
| `events` | `admin_create_event_v2` | no | trusted selected tenant; lane cross-check | 9D-5 after 9D-2 + app cutover | yes |
| `event_lanes` | event create/update functions | no | inherit verified event tenant explicitly | 9D-5 after 9D-2 prod proof | yes |
| `event_registrations` | `register_for_event` and promotion flows | no | derive event/registration | 9D-5 after 9D-2 prod proof | yes |
| `email_deliveries` | `prepare_confirmation_email` | no | derive typed record and persist | 9D-5 after 9D-2C prod proof | yes |

Retirement is a separate fail-closed migration. Preflight enumerates every INSERT path and fails if any omits `tenant_id`. Postflight proves all seven defaults NULL, columns remain NOT NULL, no business row changed, and second tenant is still blocked.

## 16. Proposed 9D phases

### 9D-0 — frozen catalog and test harness

- Capture production definitions, grants, owners, paths, dependencies and normalized fingerprint.
- Add a manifest that accounts for all 73 functions and prevents unreviewed new definers.
- Add reusable two-tenant roles/fixtures locally only.

### 9D-1A — reservation writers

- Harden `create_reservation_v2`, cancel, attendance, payment and note.
- Explicit tenant INSERT/audit binding; keep active signatures.
- Retire legacy v1 only after zero-caller proof.

### 9D-1B — reservation readers/check-in/conflicts

- Harden check-in, profile batch, busy ranges and owner list.
- Preserve public token minimization and hierarchy semantics.

### 9D-2A — event writers

- Harden register/cancel/approve/payment/confirm and v2 event target writers.
- Introduce versioned tenant-aware event create contract; coordinated app switch required.

### 9D-2B — event lists/public reads

- Tenant-bound admin participant list; versioned selected-tenant admin list.
- Preserve sole-CSK public wrappers until 9E routing supplies tenant context.

### 9D-2C — delivery and promotion claims

- Persist/verify tenant in email and reserve-promotion claim lifecycle.
- Constrain service-role grants to exact completion paths.

### 9D-3 — lane/block/configuration

- 3A resource-derived block/family updates.
- 3B versioned selected-tenant family create and admin configuration list.
- Review internal validators and normalize touched function paths.

### 9D-4 — reports, profiles, account and legacy authorization

- 4A tenant-context reports/export.
- 4B tenant-related user/profile administration.
- 4C owner account lifecycle review.
- 4D remove authorization dependence on global helpers after app callers migrate.
- 4E prepare public selected-tenant contracts for 9E.

### 9D-5 — retirement and final definer audit

- Remove seven defaults only after all writers explicitly set tenant.
- Revoke obsolete v1/service-role grants and retire zero-caller functions.
- Retire CSK role sync/global role helpers only after 9E cutover/reconciliation; if roadmap ordering keeps 9E later, this substep becomes an explicit 9E completion gate rather than being forced prematurely.
- Re-inventory all definers and run the final cross-tenant suite.

Each subphase gets its own migration, focused SQL test, compatibility matrix, production preflight, explicit approval and post-deploy verification. No bulk 73-function migration.

## 17. Cross-tenant test matrix

Run for every RPC class, including positive single-tenant regression:

| Actor / attempt | Tenant A resource | Tenant B resource | Required result |
|---|---|---|---|
| `ADMIN_A` | exact admin operation | same operation | ALLOW A / DENY B |
| `EMPLOYEE_A` | currently allowed operation | same operation | ALLOW A / DENY B; admin-only stays denied |
| `INSTRUCTOR_A` | current approved scope only | same operation | current A behavior / DENY B; no SEC-008 expansion |
| `USER_A` | own A resource | User B or Tenant B resource | ALLOW own where canonical / DENY foreign |
| no membership | privileged A/B | — | DENY |
| pending membership | privileged A/B | — | DENY |
| suspended membership | privileged A/B | — | DENY |
| global `profiles.role=admin`, no membership | privileged A/B | — | DENY |
| caller supplies Tenant B but resource belongs A | resource A | tenant arg B | DENY before read/write/audit |
| mixed resource array A+B | batch/profile/lane IDs | — | fail whole call; no partial data or mutation |
| missing/orphan resource | random UUID | — | stable not-found; no tenant existence leak |
| concurrent writer A/B | independent resources | — | locks/capacity/idempotency remain tenant-bound |

Domain assertions additionally cover capacity/overbooking, reservation cutoffs, event waitlist promotion, email claim idempotency, hierarchy conflicts, pagination/filter totals, CSV PII/formula safety, owner lifecycle, audit actor/timestamp and safe error contracts. Test direct `anon`, `authenticated` and `service_role` EXECUTE matrices against the manifest.

## 18. Rollback strategy

- Before every phase, store exact `pg_get_functiondef`, owner, grants, path and dependency fingerprints.
- Function hardening is deployed with `CREATE OR REPLACE` only where the signature is unchanged. Versioned contracts are additive; old wrappers stay until app cutover.
- Rollback restores only the exact prior functions/grants from a reviewed forward migration; never use `migration repair` or edit applied history.
- If a versioned app/RPC cutover fails, route app calls back to the retained old wrapper while the second-active-tenant guard remains in place.
- Claim/audit schema additions, if proven necessary, use expand -> dual-compatible code -> validate -> contract; do not drop data during 9D.
- Default removal occurs last and has a forward rollback that restores the CSK default only while there is exactly one active CSK tenant. It is never a rollback mechanism after Tenant B.
- Production STOP conditions: unexpected catalog fingerprint, extra pending migration, orphan/mismatched tenant row, unclassified service caller, grant widening, cross-tenant allow, audit drift, runtime regression or second active tenant.

## 19. SEC-004 impact

9D closes the principal RLS-bypass gap by making privileged DB functions resource/tenant aware, restricting service claims and removing legacy definer authorization paths.

It does not close SEC-004. Remaining work:

- 9E: trusted application tenant resolution, routing and selected-tenant context;
- 9F: full reports/events/calendar/check-in cutover to selected tenant;
- 9G: cross-tenant application E2E, concurrency and IDOR proof;
- 9H: final catalog/runtime audit, default/bridge retirement confirmation and controlled second-tenant readiness decision.

SEC-004 may close only after 9H passes. A second tenant cannot be activated during 9D.

## 20. Blocking decisions

Decisions required before their affected later phases, but not before 9D-1A:

1. trusted application tenant selector and host/slug resolution contract (9E; blocks list/create/public cutovers);
2. whether account export/anonymization is account-wide across all memberships or tenant-scoped plus a separate global request;
3. exact tenant relationship that permits admin/employee profile note/identity/contact/verification access;
4. future instructor-event assignment remains deferred; current scope must not be broadened;
5. final sequencing of global-role/sync-bridge retirement: recommended after 9E caller cutover, even if tracked as a 9D-5 exit gate;
6. whether email/rate-limit records need an additional immutable tenant claim column beyond the existing `email_deliveries.tenant_id`, based on phase 9D-2C preflight.

No unresolved decision prevents local 9D-1A implementation because its tenant context is resource-derived and existing business semantics remain authoritative.

## 21. GO / NO-GO

Entry conditions for 9D-1A:

- start from clean `main` at this documentation checkpoint;
- perform a fresh read-only production catalog/fingerprint preflight immediately before implementation;
- freeze the exact current signatures and grants in focused tests;
- modify only reservation-domain functions in the first migration;
- prove Tenant A positive behavior and Tenant B/no-membership/global-role-only denial locally;
- do not remove defaults, activate Tenant B, close SEC-004 or deploy without a separate approval.

SAAS-9D TECHNICAL PLAN: **READY**

READY FOR SAAS-9D-1 LOCAL IMPLEMENTATION: **GO**

READY FOR PRODUCTION WRITE: **NO**

## 24. SAAS-9D-2A local implementation result

SAAS-9D-2A was implemented locally in `20260912100000_harden_event_registration_rpcs.sql` for exactly the seven approved event-registration contracts. The public signatures and response shapes remain unchanged. Each reviewed business implementation is retained as a non-client `SECURITY INVOKER` core behind a postgres-owned, SP1 `SECURITY DEFINER` wrapper that derives tenant ownership from the event, registration or promotion token target.

The registration core now writes `v_event.tenant_id` explicitly. Approval, cancellation and payment audits write the registration tenant explicitly. My Events joins active membership and active tenant state to each returned registration. Owner cancellation and promotion confirmation require both `auth.uid()` ownership and active target-tenant membership; staff operations use the active membership role and never trust `profiles.role` alone. Instructor participant access remains at its pre-existing, deferred SEC-008 scope.

All seven wrappers are `authenticated`-only; `PUBLIC`, `anon` and `service_role` have no EXECUTE. All seven cores have no client/service EXECUTE. The total public-schema `SECURITY DEFINER` inventory remains 73. Preflight fingerprints, owner and ACL guards fail closed, and the migration is fully transactional. Representative 2B/2C fingerprints are frozen in focused tests and remain unchanged.

Local evidence:

- clean `supabase db reset`: PASS;
- focused SAAS-9D-2A SQL: 32/32 PASS;
- full Supabase DB suite: 28 files / 820 tests PASS;
- real two-session registration race at capacity 1: exactly one `registered`, one `reserve`, cleanup 0;
- Node: 734/734 PASS;
- TypeScript and production build: PASS;
- focused Events/My Events/Admin Events/Booking/Admin Playwright: 14/14 PASS;
- synthetic fixture post-check: zero auth users, profiles, events, registrations and audits.

SAAS-9D-2A LOCAL: **PASS**

EVENT RPC TENANT ISOLATION: **PASS**

GLOBAL ROLE BYPASS: **REMOVED for the seven 2A contracts**

READY FOR SAAS-9D-2A PRODUCTION PREFLIGHT: **GO**

READY FOR SAAS-9D-2B: **NO-GO until review**

READY FOR PRODUCTION WRITE: **NO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## 22. SAAS-9D-2 — EVENTS RPC HARDENING FINAL PLAN

Planning baseline: `d8fe265ccd00b607b3dc99cc53f5c2320c40cc08` on `main`, after the reproducible SAAS-9D-1 checkpoint and production PASS. This section is planning-only. It does not create a migration, change an application caller, authorize a production write or permit a second active tenant.

### 22.1 Exact function inventory and severity

The local catalog reconstructed from the production migration history still contains 73 `SECURITY DEFINER` functions. The 9D-2 boundary contains 20 of them: 19 event-named/event-target functions plus the shared `complete_confirmation_email` claim finalizer. All 20 are owned by `postgres` and bypass table RLS by design.

`SP1` means `pg_catalog, public, pg_temp`; `SP2` means `public, pg_temp`. Grants below are the effective client/service grants in the current catalog, excluding owner `postgres`.

| Function and exact identity arguments | Caller | Path / grants | Current authorization | Resource / tenant derivation | Operation | Current cross-tenant risk | Severity | Planned phase |
|---|---|---|---|---|---|---|---|---|
| `admin_create_event(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])` | no TypeScript caller; legacy | SP2 / service | global `profiles.role` | lane array is insufficient when empty | staff write, RLS bypass | service can create globally | CRITICAL | 2B retire EXECUTE |
| `admin_create_event_v2(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])` | `app/admin/events/page.tsx` | SP1 / authenticated | global admin/pracownik | single-active tenant bridge; cross-check every lane | staff write | global create and default-owned children | CRITICAL | 2B |
| `admin_list_event_registrations_v1(uuid,text,text,integer,integer)` | `app/admin/events/page.tsx` | SP1 / authenticated | global admin/pracownik/instruktor | event -> tenant | staff/instructor PII read | foreign-tenant participant PII | HIGH | 2A |
| `admin_list_events_v1(text,text,text,integer,integer)` | `app/admin/events/page.tsx` | SP1 / authenticated | global admin/pracownik/instruktor | no resource; single-active tenant bridge | staff/instructor read | aggregates all tenants | HIGH | 2B |
| `admin_set_event_active(uuid,boolean)` | no TypeScript caller; legacy | SP2 / service | global `profiles.role` | event -> tenant | staff write, RLS bypass | service/global mutation | CRITICAL | 2B retire EXECUTE |
| `admin_set_event_active_v2(uuid,boolean)` | `app/admin/events/page.tsx` | SP1 / authenticated | global admin/pracownik | event -> tenant | staff write | foreign event mutation | CRITICAL | 2B |
| `admin_update_event(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])` | no TypeScript caller; legacy | SP2 / service | global `profiles.role` | event -> tenant, then lanes | staff write, RLS bypass | service/global mutation | CRITICAL | 2B retire EXECUTE |
| `admin_update_event_v2(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])` | `app/admin/events/page.tsx` | SP1 / authenticated | global admin/pracownik | event -> tenant; every lane must match | staff write | foreign event/lane binding | CRITICAL | 2B |
| `approve_event_registration(uuid)` | `app/admin/events/page.tsx` | SP2 / authenticated | global admin/pracownik | registration -> event -> tenant | staff write/audit | foreign participant mutation | CRITICAL | 2A |
| `cancel_event_registration(uuid)` | register/my/admin flows through `app/api/cancel-event-registration/route.ts` | SP2 / authenticated + service | owner for user/instruktor, otherwise global admin/pracownik | registration -> event -> tenant | owner or staff write/audit | staff global bypass; unnecessary service grant | CRITICAL | 2A |
| `complete_event_reserve_promotion(uuid,uuid,boolean,text)` | `lib/server/event-reserve-promotion.ts` | SP2 / service | claim pair only | registration -> event -> tenant; claim must match | service claim completion | completion is not tenant-bound | CRITICAL | 2C |
| `confirm_event_reserve_promotion(text)` | `app/api/confirm-event-reserve-promotion/route.ts` | SP2 / authenticated | `auth.uid()` owns token registration | token -> registration -> event -> tenant | owner promotion write | no membership/tenant equality check | CRITICAL | 2A |
| `get_my_event_registrations_v1(text,text,integer,integer)` | `app/my-events/page.tsx` | SP1 / authenticated | `auth.uid()` row ownership | actor rows plus single-active tenant bridge until 9E | owner read | future account can aggregate tenants | MEDIUM | 2A |
| `get_public_event_availability_v1()` | no current page caller; retained public contract | SP1 / anon + authenticated | public | single-active public tenant | PII-free public read | aggregates all tenants | HIGH | 2B |
| `get_public_event_list_v2(text,text,integer,integer)` | `app/events/page.tsx` | SP1 / anon + authenticated | public | single-active public tenant | PII-free public read | mixes event counts across tenants | HIGH | 2B |
| `mark_event_registration_paid(uuid)` | `app/admin/events/page.tsx` | SP1 / authenticated | global admin/pracownik | registration -> event -> tenant | staff write/audit | foreign payment mutation | CRITICAL | 2A |
| `prepare_confirmation_email(text,uuid)` | event registration confirmation API plus reservation mail APIs | SP2 / authenticated | owner for event branch; mixed legacy staff branch for reservation cancellation | typed record -> registration/event or reservation -> tenant | owner/staff email claim | delivery tenant is defaulted, not proven | CRITICAL | 2C shared boundary |
| `complete_confirmation_email(uuid,boolean,text,text)` | three mail APIs through the service completion client | SP2 / service | claim ID only | claim -> delivery -> typed record tenant | service claim completion | claim target/tenant equality not enforced | CRITICAL | 2C shared boundary |
| `prepare_event_reserve_promotions(uuid)` | `lib/server/event-reserve-promotion.ts` from cancellation and manual promotion APIs | SP2 / service | trusted server only; route manual path uses global profile role | event -> tenant, registrations must match | service claim/token creation | arbitrary tenant event accepted by service | CRITICAL | 2C |
| `register_for_event(uuid,boolean)` | `app/api/register-event/route.ts` | SP2 / authenticated | `auth.uid()`, profile completeness | event -> tenant; actor active membership | owner create | inserted tenant currently comes from CSK default | CRITICAL | 2A |

No separate event-rejection or event-lane RPC exists. Rejection uses the existing cancellation transition, and event-lane writes are embedded in event create/update. Event reads performed through table RLS by the calendar `.ics` route are outside this `SECURITY DEFINER` inventory and remain covered by SAAS-9C.

### 22.2 Tenant derivation and write invariant

For every target-bound call, the function must lock or read the target, derive its tenant, and authorize against that derived tenant before reading PII, mutating state or writing audit:

- `event_id` -> `events.tenant_id`;
- `registration_id` -> `event_registrations.tenant_id`, with equality to the referenced `events.tenant_id`;
- promotion token -> registration -> event, with token owner equal to `auth.uid()`;
- promotion claim -> registration -> event, with claim ID and tenant bound to that same registration;
- delivery claim -> `email_deliveries.tenant_id` -> typed record, with record tenant, recipient and claim all equal;
- event lane -> both composite FKs must prove `event_lanes.tenant_id = events.tenant_id = shooting_lanes.tenant_id`.

Caller-supplied tenant is never the only authority. No active 9D-2 signature currently accepts tenant. Target-bound signatures can therefore remain stable.

`admin_create_event_v2`, `admin_list_events_v1`, `get_public_event_availability_v1` and `get_public_event_list_v2` lack an existing resource. Before 9E they resolve exactly one active tenant with `active_single_tenant_id_v1()`. They fail closed if that invariant is not exact. Admin create/list additionally require an active membership in that tenant; public reads do not require membership and return only that active tenant's public events. This is a CSK compatibility bridge, not a multi-tenant routing design.

Every new insert must set tenant explicitly:

- `events.tenant_id` from the resolved single-active tenant during the bridge;
- `event_lanes.tenant_id` from the already-authorized event tenant;
- `event_registrations.tenant_id` from the locked event;
- `email_deliveries.tenant_id` from the typed source record;
- event-related `audit_logs.tenant_id` from the target event/registration.

Any null/missing target, tenant mismatch, mixed-tenant lane array or orphan relationship fails before partial writes and before audit.

### 22.3 Owner event-registration operations

`register_for_event`, `cancel_event_registration`, `confirm_event_reserve_promotion` and `get_my_event_registrations_v1` retain their existing business statuses and response contracts.

- Registration requires `auth.uid()`, an active `user` or `instructor`/staff membership in the event tenant as permitted by the current single-tenant product, a complete owner profile, and an active future event. The insert uses the event tenant explicitly.
- Self-cancellation requires the registration owner, active membership in its tenant and the existing Europe/Warsaw 72-hour rule. Exactly 72 hours remains allowed; less than 72 hours remains denied.
- An instructor can cancel only their own registration. This does not create instructor-to-event assignment and does not expand SEC-008.
- Promotion confirmation requires the token registration owner, active membership in the event tenant, unexpired token and capacity under the locked event.
- My-events remains owner-only and is filtered to the sole active tenant until 9E supplies selected tenant context. A caller cannot pass a user ID or tenant ID.

Required proof: User A own Tenant A operation ALLOW; User A foreign user in A DENY; User A Tenant B IDOR DENY; missing/pending/suspended membership DENY; no partial registration/audit/email row.

### 22.4 Staff and instructor operations

For create/update/activate/approve/payment/staff cancellation, global `profiles.role` is replaced by an active tenant membership role:

- `admin` and `employee` preserve current management permissions;
- `instructor` remains read-only for the currently exposed event and participant lists, scoped to the event tenant/single active tenant;
- `instructor` does not gain approval, payment, event management or foreign cancellation;
- no membership, pending membership, suspended membership and global `profiles.role=admin` without membership all fail closed.

Participant-list authorization derives tenant from `p_event_id` before returning PII. Event update and activation lock the event first. Update cross-checks every requested lane tenant before any conflict query or relationship replacement. Create resolves the compatibility tenant first and rejects every lane outside it. Empty-lane creation is allowed only inside that resolved tenant.

### 22.5 Event management, lanes and audit

Existing validation, operating hours, hierarchy conflict locks, reservation conflicts, lane-block conflicts and event conflicts remain unchanged. The hardening adds tenant predicates to each conflict read and writes event/event-lane tenant explicitly. It does not alter capacity, dates, prices, active semantics or UI responses.

Changed staff actions continue to create exactly one tenant-bound audit with DB actor/time. `no_change`, invalid transitions, authorization denial and not-found paths create no audit. Audit details must not contain promotion tokens, email claims or participant contact fields.

The three legacy service-only event management signatures have no current TypeScript caller. 9D-2B freezes a zero-caller test and revokes `service_role` EXECUTE, leaving owner-only access. It does not drop the functions in the same migration, allowing a forward rollback without reconstructing definitions.

### 22.6 Waitlist, promotion and confirmation claims

The existing order and state machine remain authoritative:

- occupied statuses are `registered` and `approved`;
- `reserve` does not occupy capacity;
- reserve ordering remains `created_at, id`;
- event row lock precedes participant counting and promotion/confirmation;
- registration row locks, unique active registration constraint, promotion claim ID/expiry and email delivery claim ID/expiry remain intact;
- repeated completion remains idempotent and cannot create a second state transition or audit.

The service-only prepare/complete functions retain exact service grants because they are server delivery state machines. They must derive tenant from the event/registration/claim and reject mismatched claims or typed targets. They may not accept a browser-supplied tenant.

The manual `/api/send-event-reserve-promotion` path must replace its global profile-role check with an authenticated, event-target membership check before invoking the service helper. The owner-cancellation path may invoke the helper only with the `event_id` returned by the successfully hardened cancellation RPC; it must not accept a second event ID from the request. The service helper continues to send only after a successful claim and completes only that exact registration/claim pair.

`prepare_confirmation_email` must derive `email_deliveries.tenant_id` for each supported message type. `complete_confirmation_email` must verify that the delivery tenant still equals its typed reservation/event-registration target before completion. This shared change must run all reservation email regressions from SEC-006/SEC-015 as well as event confirmation tests.

### 22.7 Public availability and public list

`get_public_event_list_v2` remains the active `/events` contract. `get_public_event_availability_v1` remains a compatible PII-free contract although no page currently calls it. Both:

- resolve the exact single active tenant;
- filter events and registration counts by that tenant;
- preserve `registered + approved` occupied semantics, reserve count and `available_spots >= 0`;
- remain executable by anon and authenticated only;
- return no registration ID, user ID, contact data, tokens or notes;
- fail closed if the single-active invariant is not exact.

They must not require membership while public CSK routing remains unchanged. Before a second tenant, 9E must replace the implicit single-active selection with a trusted host/slug-selected contract.

### 22.8 Owners, grants and search path

All touched functions remain owned by `postgres`. Every redefined function uses explicit `SET search_path = pg_catalog, public, pg_temp` and schema-qualified objects/functions. No EXECUTE grant is widened.

- public readers: `anon`, `authenticated` only;
- owner/staff client RPCs: `authenticated` only;
- service claim prepare/complete functions: `service_role` only;
- legacy admin event v1 functions: owner-only after service grant revocation;
- `PUBLIC`: no EXECUTE for every non-public contract and no implicit grant drift.

Focused ACL tests must assert effective privileges, owner and search path for all 20 signatures and keep the total `SECURITY DEFINER` inventory explicitly accounted for.

### 22.9 Application caller impact

| File | Current RPC | Current arguments/context | Planned caller impact |
|---|---|---|---|
| `app/events/page.tsx` | `get_public_event_list_v2` | search/scope/page; no tenant | none in 9D-2; compatibility bridge filters CSK |
| `app/my-events/page.tsx` | `get_my_event_registrations_v1` | scope/status/page; actor JWT | none; DB adds tenant membership/filter |
| `app/api/register-event/route.ts` | `register_for_event` | event ID/reserve flag; actor JWT | none |
| `app/api/cancel-event-registration/route.ts` | `cancel_event_registration` | registration ID; actor JWT | preserve call; promotion helper must use only returned event ID |
| `app/api/confirm-event-reserve-promotion/route.ts` | `confirm_event_reserve_promotion` | token; actor JWT | none |
| `app/admin/events/page.tsx` | admin lists/create/update/active/approve/payment | filters or target IDs; browser JWT | active signatures remain; no selected tenant UI yet |
| `app/api/send-event-registration-confirmation/route.ts` | `prepare_confirmation_email`, `complete_confirmation_email` | owner registration claim + server completion | no public contract change; shared claim gets tenant proof |
| `app/api/send-event-reserve-promotion/route.ts` | server helper -> promotion prepare/complete | event ID; currently global profile-role precheck | change server precheck to event-derived active membership |
| `lib/server/event-reserve-promotion.ts` | `prepare_event_reserve_promotions`, `complete_event_reserve_promotion` | service client, event/registration/claim | preserve service-only DB signatures; accept only already-authorized event context from route/cancellation result |

No 9D-2 caller sends tenant ID. Selected-tenant arguments, hostname routing and multi-tenant URL state belong to 9E. If implementation discovers that preserving a signature would require trusting client tenant input, that subphase stops rather than silently changing the caller contract.

### 22.10 Concurrency and business-regression contract

Tests must prove, under deterministic barriers and repeated stress where the current harness supports it:

1. one active registration per user/event remains enforced;
2. event row locking prevents overbooking and preserves reserve fallback;
3. exactly one reserve claimant is promoted for one released place;
4. confirmation cannot exceed capacity under simultaneous tokens;
5. event create/update/activate retains canonical lane-family conflict locks and cannot bind mixed-tenant lanes;
6. claim prepare/complete permits one active delivery/promotion claim, rejects a foreign claim and remains retry-safe;
7. cancellation plus promotion retains the current controlled-warning contract when email delivery fails;
8. changed staff actions write one audit, while no-change/retry writes none;
9. Tenant A and Tenant B operations on independent resources do not deadlock or leak rows.

### 22.11 Required cross-tenant and regression tests

Focused SQL coverage for every phase includes:

- anon public list/availability ALLOW and PII-free; anon mutations DENY;
- User A own registration/register/cancel/confirm in Tenant A ALLOW;
- User A foreign registration and Tenant B event/registration/token DENY;
- Admin A and Employee A allowed Tenant A operations ALLOW, Tenant B DENY;
- Instructor A retains current reads and own cancellation only; management DENY;
- missing, pending and suspended membership DENY privileged/owner tenant operations;
- global legacy admin/pracownik profile without active target membership DENY;
- caller/resource mismatch and mixed A+B lane arrays DENY atomically;
- event registration and event-lane composite tenant constraints remain valid;
- public counts, sold-out, reserve, cancellation and promotion semantics remain exact;
- no cross-tenant PII from admin participant list or my-events;
- service prepare/complete claims cannot cross registration/delivery tenants;
- exact grants/search paths/owners and zero legacy runtime callers;
- no RLS recursion and no direct DML grant regression;
- fixture cleanup equals zero.

Regression gates: focused event SQL, event concurrency harness, full Supabase DB suite, full Node suite, TypeScript, production build, event Playwright/mobile flows, confirmation/reserve email tests, `npm audit --omit=dev`, changed-files ESLint and `git diff --check`.

### 22.12 Temporary CSK defaults

Current catalog evidence:

| Table | Current `tenant_id` default | 9D-2 writer behavior | Removal |
|---|---|---|---|
| `events` | CSK UUID | create writes resolved tenant explicitly | retain until 9D-5/9E gate |
| `event_lanes` | CSK UUID | create/update write event tenant explicitly | retain until 9D-5/9E gate |
| `event_registrations` | CSK UUID | register/promotion paths write/retain event tenant explicitly | retain until 9D-5/9E gate |
| `email_deliveries` | CSK UUID | prepare writes typed-record tenant explicitly | retain until all reservation/event mail writers pass production proof |
| `audit_logs` | no default | every event audit writes derived tenant explicitly | no change |

The explicit gate remains: **REMOVE DEFAULT BEFORE TENANT-AWARE WRITER CUTOVER AND BEFORE SECOND TENANT**. 9D-2 does not remove any default.

### 22.13 Proposed migration split and rollout

Do not deploy this domain as one migration.

1. **9D-2A — event registration owner/staff contracts**: `register_for_event`, `cancel_event_registration`, `approve_event_registration`, `mark_event_registration_paid`, `confirm_event_reserve_promotion`, `get_my_event_registrations_v1`, `admin_list_event_registrations_v1`; explicit registration/audit tenant, membership enforcement, SP1 normalization, concurrency tests. Active signatures stay unchanged.
2. **9D-2B — event management and public reads**: active admin create/update/activate/list and both public readers; single-active bridge for contextless calls, mixed-lane rejection, explicit event/event-lane tenant; revoke service EXECUTE from the three zero-caller legacy admin functions. Active signatures stay unchanged.
3. **9D-2C — event delivery and promotion claims**: promotion prepare/complete, shared confirmation prepare/complete, tenant-bound claim state; replace the manual promotion route's global role precheck with event-target membership. Run reservation e-mail regressions because the confirmation functions are shared.

Each migration is independently additive/`CREATE OR REPLACE` plus grant hardening, has a frozen preflight fingerprint, focused test, compatibility matrix, local PASS, production dry-run, explicit production approval and rollback-only postflight. Complete 2A production proof before 2B; complete 2B before 2C.

Compatibility target for every subphase:

- old app + old DB: current behavior;
- old app + new DB: safe because active signatures and response codes remain, subject to correct membership backfill already proven in 9C-1;
- new app + old DB: only 2C's route membership precheck dependency requires coordinated ordering; deploy its DB authorization contract before the route change;
- new app + new DB: tenant-bounded CSK behavior, still not second-tenant ready.

### 22.14 Rollback

- Capture exact preflight function definitions, owners, grants, paths and normalized fingerprints for all 20 signatures.
- Rollback is a reviewed forward migration restoring only the previous definitions/grants for the affected subphase; never edit applied migrations or use `migration repair`.
- Keep active signatures stable so application rollback remains possible.
- If 2C application deployment fails, roll back the route/helper to the prior version while the new DB functions remain backward-compatible; do not re-grant legacy browser access.
- Never roll back by removing tenant columns, composite FKs, memberships or the single-active guard.
- STOP on catalog drift, unexpected caller, membership/backfill mismatch, cross-tenant allow, grant widening, capacity/waitlist race regression, audit drift, public PII, nonzero fixture or additional pending migration.

### 22.15 SEC-004 impact and residual work

9D-2 removes global-role authorization and unscoped event/event-registration access from active event RPCs, filters public/admin reads to CSK, explicitly binds event children/audits/deliveries, and constrains service claims to exact tenant-owned targets.

SEC-004 remains OPEN because:

- 9D-3 still must harden lane/block/configuration definers;
- 9D-4 still must harden reports, profile/account and remaining global authorization helpers;
- 9D-5 must retire compatibility grants/default dependencies after all writers are proven;
- 9E must introduce trusted tenant selection/routing and replace single-active wrappers;
- 9F must cut over reports/events/calendar/check-in to selected tenant context;
- 9G must prove application-level cross-tenant IDOR and concurrency;
- 9H alone may authorize SEC-004 closure and second-tenant readiness.

### 22.16 Blocking decisions and GO / NO-GO

No unresolved architecture decision blocks **local 9D-2A**: all its tenant contexts derive from event/registration/token resources, membership role mapping is already approved, and the existing concurrency semantics are explicit.

9D-2B may proceed locally with the already established single-active-CSK compatibility bridge. It must not invent selected-tenant routing. 9D-2C may proceed only after its local preflight freezes the exact server callers and proves the manual promotion endpoint checks membership in the derived event tenant before service execution; this is an implementation gate, not a business decision.

Production remains separately gated per subphase. No 9D-2 work enables Tenant B or closes SEC-004.

SAAS-9D-2 TECHNICAL PLAN: **READY**

READY FOR SAAS-9D-2 LOCAL IMPLEMENTATION: **GO**

READY FOR PRODUCTION WRITE: **NO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## 23. SAAS-9D-1 closure record

The approved first phase was implemented locally in `20260911140000_harden_reservation_checkin_rpcs.sql`. It preserves all public function signatures and the 73-function `SECURITY DEFINER` count while separating 12 reviewed business implementations into non-client `SECURITY INVOKER` cores behind tenant-authorizing wrappers.

Hardened active signatures:

1. `create_reservation_v2(uuid,date,time,integer,integer,uuid,text)`
2. `cancel_reservation(uuid)`
3. `update_reservation_admin_note(uuid,text)`
4. `update_reservation_attendance(uuid,text)`
5. `update_reservation_payment(uuid,text)`
6. `get_check_in_reservation_v1(uuid)`
7. `get_public_check_in_status_v1(uuid)`
8. `get_my_reservations_v2()`
9. `get_reservation_customer_profiles_v1(uuid[])`
10. `get_lane_booking_busy_ranges(uuid,date)`
11. `get_lane_booking_busy_ranges_v2(uuid,date)`
12. `get_lane_booking_busy_ranges_v3(uuid,date)`

The retained legacy `create_reservation(uuid,date,time,integer,integer,uuid,text)` is now owner-only; its prior `service_role` EXECUTE grant was removed. Broad `service_role` grants were also removed from the hardened reservation/busy-range paths. Client-facing grants were not widened.

Tenant derivation is resource-based: lane for create/busy-range, reservation for owner/staff operations and customer profile batches, and check-in token to reservation. The V2 create core now writes `v_lane.tenant_id` explicitly while the existing composite tenant/lane FK continues to reject mismatches. The seven temporary CSK defaults remain because their global removal is deferred to a later approved 9D gate; the reservation writer no longer relies on its default as a security mechanism.

Authorization now requires `auth.uid()`, an active membership in the derived tenant and the allowed membership role. Owner cancellation additionally requires the reservation owner. Global `profiles.role` alone, missing membership, pending membership, instructor role and cross-tenant IDs fail closed.

Local verification outcome:

- fresh local reset: PASS;
- focused SAAS-9D-1 SQL: 32/32 PASS;
- full Supabase DB suite: 27 files / 784 tests PASS;
- cross-writer concurrency: 52/52 deterministic and 50/50 stress PASS, zero deadlock/lock-timeout/serialization failures;
- Node: 734/734 PASS;
- TypeScript and production build: PASS;
- focused Playwright: 11/11 PASS;
- synthetic fixture remaining: 0;
- `SECURITY DEFINER`: 73; protected 9D-1 cores: 12; temporary defaults: 7.

The detailed implementation evidence is recorded in `SAAS_9D_1_RESERVATION_CHECKIN_RPC_HARDENING_REPORT.md`.

SAAS-9D-1: **CLOSED / PROD PASS**

REPOSITORY REPRODUCIBLE: **YES**

GLOBAL ROLE BYPASS — RESERVATION/CHECK-IN: **REMOVED**

READY FOR SAAS-9D-2 PLANNING: **GO; section 22 is authoritative**

READY FOR PRODUCTION WRITE: **NO**
