# SAAS-9D — Tenant-Aware RPC / SECURITY DEFINER Hardening

Technical implementation plan with the approved SAAS-9D-1 local execution record. Planning and local implementation date: 2026-09-11 (Europe/Warsaw).

Repository baseline: `02af6857a88e37d30b6e4b1159496cecff91bac1` on `main`, identical to `origin/main` when this plan was prepared.

The original plan was planning-only. Section 22 now records the separately authorized local-only SAAS-9D-1 implementation. Nothing in this document authorizes a production deployment, SAAS-9D-2 or a second tenant.

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

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## 22. SAAS-9D-1 local execution update

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

SAAS-9D-1 LOCAL: **PASS**

READY FOR SAAS-9D-1 PRODUCTION PREFLIGHT: **GO**

READY FOR SAAS-9D-2: **NO-GO until review**

READY FOR PRODUCTION WRITE: **NO**
