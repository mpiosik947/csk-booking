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

## 25. SAAS-9D-2B — EVENT MANAGEMENT RPC HARDENING FINAL PLAN

Planning baseline: checkpoint `b37386902b42c12f6902de27e172e516c69ed9d4` on `main`, identical to `origin/main` when this section was prepared. SAAS-9D-2A is closed with production PASS. This section is planning-only: it creates no migration, changes no application file, executes no production write and does not authorize a second tenant.

### 25.1 Exact function scope

SAAS-9D-2B contains exactly nine existing public functions. No 2A registration function and no 2C promotion/e-mail claim function belongs to this phase.

| Function | Signature | Current caller | SECURITY DEFINER | Current auth / global role | Resource argument | Planned tenant derivation | Required role / instructor scope | Cross-tenant risk | Severity |
|---|---|---|---|---|---|---|---|---|---|
| `admin_create_event` | `(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])` | none found; legacy | yes | `profiles.role` check; service-only EXECUTE | lane IDs only | no runtime derivation retained; retire client/service EXECUTE | owner-only; instructor DENY | service/global legacy entry point | CRITICAL |
| `admin_create_event_v2` | `(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])` | `app/admin/events/page.tsx` | yes | global `admin`/`pracownik` | optional lane IDs; empty is valid | exact `active_single_tenant_id_v1()`, then every lane must match | active `admin` or `employee`; instructor DENY | global create and default-owned children | CRITICAL |
| `admin_list_events_v1` | `(text,text,text,integer,integer)` | `app/admin/events/page.tsx` | yes | global `admin`/`pracownik`/`instruktor` | none | exact active-single tenant bridge | active `admin`, `employee` or `instructor`; preserve instructor read | global event aggregation | HIGH |
| `admin_set_event_active` | `(uuid,boolean)` | none found; legacy | yes | `profiles.role` check; service-only EXECUTE | event ID | no runtime derivation retained; retire client/service EXECUTE | owner-only; instructor DENY | service/global legacy mutation | CRITICAL |
| `admin_set_event_active_v2` | `(uuid,boolean)` | `app/admin/events/page.tsx` | yes | global `admin`/`pracownik` | event ID | locked event -> `events.tenant_id` | active `admin` or `employee`; instructor DENY | foreign event activation/deactivation | CRITICAL |
| `admin_update_event` | `(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])` | none found; legacy | yes | `profiles.role` check; service-only EXECUTE | event ID and lane IDs | no runtime derivation retained; retire client/service EXECUTE | owner-only; instructor DENY | service/global legacy mutation | CRITICAL |
| `admin_update_event_v2` | `(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])` | `app/admin/events/page.tsx` | yes | global `admin`/`pracownik` | event ID and lane IDs | locked event -> tenant; every old/new lane must match | active `admin` or `employee`; instructor DENY | foreign event mutation or mixed-tenant lane binding | CRITICAL |
| `get_public_event_availability_v1` | `()` | no current page caller; retained contract | yes | public, no role check | none | exact active-single tenant bridge | public read; no membership | cross-tenant aggregate mixing | HIGH |
| `get_public_event_list_v2` | `(text,text,integer,integer)` | `app/events/page.tsx` | yes | public, no role check | none | exact active-single tenant bridge | public read; no membership | cross-tenant list/count mixing | HIGH |

No additional participant-management RPC remains in 2B. Registration cancellation, approval, payment, owner reads and participant listing were completed in 2A. Promotion preparation/completion and shared confirmation delivery remain exclusively in 2C.

### 25.2 Risk classification and implementation boundary

The three active event writers are CRITICAL because they bypass RLS and can create or mutate event/lane state. The admin list and public readers are HIGH because an unscoped definer can aggregate foreign-tenant records, and admin list exposes operational event data. The three legacy service-only writers are CRITICAL exposed surface despite having no current caller; their correct treatment is grant retirement, not a new authorization path.

2B changes authorization, tenant predicates and explicit tenant writes only. It must not change validation messages, event dates/times, operating hours, active semantics, conflict-family locking, reservation/lane-block/event conflict rules, pagination, ordering, capacity display, waitlist accounting or DTO shape.

### 25.3 Tenant derivation

- `admin_create_event_v2`, `admin_list_events_v1`, `get_public_event_list_v2` and `get_public_event_availability_v1` have no pre-existing resource from which a tenant can be derived. They call the owner-only `active_single_tenant_id_v1()` bridge and fail closed unless it returns exactly one active tenant.
- `admin_update_event_v2` and `admin_set_event_active_v2` lock/read the target event first and derive authority only from `events.tenant_id`.
- `admin_update_event_v2` validates the persisted `event_lanes.tenant_id`, the event tenant and every requested `shooting_lanes.tenant_id` before deleting or inserting relationships.
- No public signature accepts `tenant_id`; no query, form or browser value becomes an authorization source.
- Event create writes `events.tenant_id` explicitly. Event create/update writes `event_lanes.tenant_id` explicitly from the already-authorized event tenant.
- All conflict reads are additionally constrained to the derived tenant while the existing composite tenant FKs remain the final integrity barrier.

The bridge is valid only while the partial unique active-tenant guard prevents a second active tenant. It is not the selected-tenant design and must be replaced during 9E before second-tenant activation.

### 25.4 Staff authorization and global-role negative contract

Every privileged active 2B function requires `auth.uid()`, an active membership in the derived/resolved tenant and an allowed membership role:

- `admin`: create, update, activate/deactivate and admin list;
- `employee`: same existing management scope as legacy `pracownik`;
- `instructor`: admin event list read only, exactly matching the existing contract;
- `user`, missing membership, pending membership and suspended membership: DENY.

`profiles.role` is not consulted as authority. The critical negative test sets `profiles.role=admin` while omitting an active membership in the target tenant; create, update, activation and admin list must return controlled `not_allowed` and produce no write. Admin/employee A may act on Tenant A and must be denied for Tenant B.

### 25.5 Instructor scope

Instructor access is neither expanded nor redesigned. An instructor with active membership may retain the current `admin_list_events_v1` read scope for that tenant. Instructor remains denied event creation, update, activation/deactivation and every legacy writer. Participant PII scope remains the deferred SEC-008 decision and is not modified by 2B.

### 25.6 Event creation

`admin_create_event_v2` keeps its public signature and caller payload. Its wrapper resolves the exact active tenant and requires active `admin`/`employee` membership before validation or conflict reads. The internal implementation receives that resolved tenant explicitly, rejects every lane outside it, permits an empty lane list only within that resolved tenant, and explicitly writes tenant ownership to event and event-lane rows.

The old application therefore remains compatible without 9E tenant UI. If the active-single invariant is absent or ambiguous, creation fails closed rather than falling back to a default or caller hint. No app-cutover is required for 2B; selected tenant creation remains a 9E dependency.

### 25.7 Event update, deactivation and activation

Update and status changes first lock the event, derive its tenant and authorize the actor in that tenant. Tenant B event IDs are denied to Tenant A staff without revealing the foreign record. Update locks the globally ordered union of old/new conflict families only after confirming that all referenced lanes belong to the event tenant. Cross-tenant lane arrays fail before relationship deletion or any event update.

There is no separate event-cancellation RPC: the product uses `admin_set_event_active_v2` for activation/deactivation. 2B does not invent a new status transition. Existing `no_change`, `created`, `updated`, `activated`, `deactivated`, conflict and validation codes remain stable.

### 25.8 Capacity and status semantics

Current event update validation requires a positive `max_participants` but does not enforce a separate lower bound against the current occupied count. 2B must characterize and preserve that existing contract; it must not silently add a new business rule. Registration capacity remains authoritative in the 2A registration/promotion locks. If local implementation reveals an undocumented capacity invariant rather than the observed behavior, implementation stops for a separate business decision.

Status changes preserve current event/lane conflict checks and do not alter registration, reserve or payment state. Deactivation does not delete event registrations or history.

### 25.9 Event/lane consistency

For every create/update lane assignment the invariant is:

`events.tenant_id = event_lanes.tenant_id = shooting_lanes.tenant_id`.

Event A plus Lane B is denied even for an admin of Tenant A. Mixed A+B arrays, missing lanes, inactive lanes/parents and invalid hierarchy remain atomic failures. Conflict queries for reservations, lane blocks and other events include the derived tenant and retain existing family-lock ordering, so a foreign-tenant row cannot become either an authorization channel or an accidental conflict result.

### 25.10 Participant admin actions

There is no new participant action in 2B. `admin_list_event_registrations_v1`, `approve_event_registration`, `mark_event_registration_paid` and staff cancellation are frozen 2A dependencies. Focused 2B regression must assert their post-2A fingerprints and cross-tenant behavior unchanged; 2B must not duplicate or replace their implementations.

### 25.11 Public contract

Both public readers remain anon/authenticated callable without membership. They resolve the exact active tenant internally, filter events and registration counts to that tenant, preserve `registered + approved` occupied semantics, keep reserve separate and clamp available spots at zero. The return columns/JSON keys, pagination limits and stable ordering remain unchanged and PII-free.

Public mutation permissions remain absent. `/events` continues to call only `get_public_event_list_v2`; `get_public_event_availability_v1` remains a compatible retained contract.

### 25.12 ACL, owner and search path

All nine functions remain owned by `postgres`; no grant is widened.

| Contract group | Target EXECUTE | Target path/definition |
|---|---|---|
| active staff wrappers: create V2, update V2, active V2, admin list | authenticated only | SECURITY DEFINER, SP1 |
| public list and availability wrappers | anon + authenticated only | SECURITY DEFINER, SP1 |
| six private `__saas9d2b_core` implementations | owner only | SECURITY INVOKER, SP1 |
| three legacy admin event functions | owner only | retain definition and SP2, revoke service-role EXECUTE only |

PUBLIC receives no implicit EXECUTE. Service role receives no 2B EXECUTE. The three legacy functions remain present for forward rollback compatibility but have no runtime caller. A frozen zero-caller search is a migration/test precondition.

### 25.13 Application callers

| File | RPC | Arguments | Current tenant/resource context | App change required in 2B |
|---|---|---|---|---|
| `app/admin/events/page.tsx` | `admin_list_events_v1` | search, scope, sort, page, page size | no resource; DB active-single bridge | no |
| `app/admin/events/page.tsx` | `admin_create_event_v2` | event fields and lane ID array | lane array optional; DB resolves tenant | no |
| `app/admin/events/page.tsx` | `admin_update_event_v2` | event ID, event fields, lane ID array | event ID is authoritative | no |
| `app/admin/events/page.tsx` | `admin_set_event_active_v2` | event ID, boolean | event ID is authoritative | no |
| `app/events/page.tsx` | `get_public_event_list_v2` | search, upcoming scope, page, page size | no resource; DB active-single bridge | no |
| none | `get_public_event_availability_v1` | none | no resource; DB active-single bridge | no |
| none | three legacy functions | none | deprecated service surface | no; revoke grant |

No caller currently supplies tenant context, and none will be added in 2B. Host/slug-selected context belongs to 9E.

### 25.14 Normalized production fingerprint baseline

Fingerprint normalization is exactly CRLF and lone CR to LF before MD5. The production baseline captured read-only after the 2A checkpoint is:

| Signature | Source fingerprint | Current path | Current effective grants |
|---|---|---|---|
| `admin_create_event(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])` | `26f51acb0a0f56677a86dbddec9974b2` | SP2 | service |
| `admin_create_event_v2(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])` | `6b8d29b11797a346ae9387a9bd3ec6b9` | SP1 | authenticated |
| `admin_list_events_v1(text,text,text,integer,integer)` | `7972f35024b6202a149afbe09f50d5a2` | SP1 | authenticated |
| `admin_set_event_active(uuid,boolean)` | `b547b0c8d2b056273b10fe57f78f89c0` | SP2 | service |
| `admin_set_event_active_v2(uuid,boolean)` | `ad56e445e74634f540425d92ff93acb1` | SP1 | authenticated |
| `admin_update_event(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])` | `60301f5e0b290117105bc9637f10d3ce` | SP2 | service |
| `admin_update_event_v2(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])` | `a525123389f3a646cd3da6f26e466ed5` | SP1 | authenticated |
| `get_public_event_availability_v1()` | `40adf74cb5adec5df3b4745fc7851433` | SP1 | anon + authenticated |
| `get_public_event_list_v2(text,text,integer,integer)` | `fe075d7057149b0a0bad0129419a3e99` | SP1 | anon + authenticated |

Every proposed migration fails closed unless all source fingerprints, signatures, owners, paths and grants match its phase baseline. Target fingerprints are calculated only after the reviewed local implementation exists, then frozen in focused tests and the production preflight report. The migration must also prove that 2A and 2C representative fingerprints are unchanged.

### 25.15 Temporary CSK defaults

| Table | 2B writer | Current default | Explicit after 2B | Default still required | Removal phase |
|---|---|---|---|---|---|
| `events` | `admin_create_event_v2` | bootstrap CSK tenant | yes, resolved tenant | yes for other legacy compatibility | 9D-5/9E cutover gate |
| `event_lanes` | create/update V2 | bootstrap CSK tenant | yes, event tenant | yes for other legacy compatibility | 9D-5/9E cutover gate |
| `event_registrations` | none in 2B | bootstrap CSK tenant | already explicit in 2A register path | yes pending all legacy writers | 9D-5 |
| `email_deliveries` | none in 2B | bootstrap CSK tenant | deferred to 2C | yes | after 2C production proof and 9D-5 gate |
| `audit_logs` | no 2B writer currently writes event-management audit | none | unchanged | not applicable | no change |

No default is removed in 2B. The explicit gate remains: remove compatibility defaults before selected-tenant writer cutover and before a second active tenant.

### 25.16 Concurrency test plan

Focused deterministic two-session tests must cover:

1. two overlapping creates on the same conflict family: exactly one create, one controlled conflict;
2. simultaneous independent Tenant A/Tenant B event operations: no cross-tenant conflict leak or deadlock;
3. update swapping old/new lane families in opposite order: global lock ordering, no deadlock;
4. simultaneous updates of one event: serialized existing behavior with no partial event-lane replacement;
5. activate versus overlapping reservation/lane block/event creation: existing conflict result remains deterministic;
6. update versus registration while capacity changes: observed current capacity contract remains stable and registration never overbooks;
7. mixed-tenant lane array under concurrent change: DENY before event or event-lane mutation;
8. no-change update/activation: no extra write and stable response;
9. public/admin list during a committed mutation: bounded consistent result and no PII/cross-tenant row.

Reuse the existing hierarchy event concurrency and final cross-writer harnesses. Add a focused 2B harness only where existing barriers cannot prove tenant separation. No production stress test is planned.

### 25.17 Cross-tenant and authorization matrix

- Admin A: create/list/update/activate Event A ALLOW; Event B DENY.
- Employee A: preserve create/list/update/activate scope in A; B DENY.
- Instructor A: admin list A ALLOW; every management mutation DENY; B list DENY.
- User, no membership, pending and suspended membership: all privileged calls DENY.
- Global legacy admin profile without active target membership: all active privileged 2B calls DENY.
- Event A plus Lane B, mixed A+B lane list and tenant-spoof attempt: DENY atomically.
- Public list/availability: anon and authenticated ALLOW for the exact active tenant, no membership required, no PII.
- Legacy service functions: service-role EXECUTE DENY after retirement.
- 2A participant operations and 2C claim functions: fingerprints and grants unchanged.

Every denial must leave event, event-lane, registration and audit counts unchanged. Fixture cleanup must equal zero.

### 25.18 Service-role analysis

Only the three legacy event management functions currently grant service-role EXECUTE; repository-wide caller search finds no TypeScript/JavaScript caller. Their internal reliance on `auth.uid()` plus global profile role is not a valid service business-authorization model. 2B revokes service EXECUTE and leaves them owner-only.

No active V2 writer, admin reader or public reader grants service-role EXECUTE today, and 2B preserves that. Service role is never treated as automatic business authorization. The service-only promotion/e-mail claims belong to 2C and are untouched.

### 25.19 Proposed migration split and local sequence

Implement locally in two separately reviewable migrations, without creating either during this planning task:

1. **9D-2B-1 — staff event management**: harden `admin_create_event_v2`, `admin_update_event_v2`, `admin_set_event_active_v2`, `admin_list_events_v1`; create four non-client invoker cores; retire service EXECUTE on the three zero-caller legacy functions while preserving their bodies, signatures, owners and SP2 paths. Add focused SQL, ACL/inventory updates and management concurrency coverage.
2. **9D-2B-2 — public event readers**: tenant-scope `get_public_event_list_v2` and `get_public_event_availability_v1` behind two non-client invoker cores while preserving exact public signatures/DTO/grants. Add PII-free, availability, pagination and public browser regressions.

Order is 2B-1 local PASS and review, then 2B-2 local PASS and review. Each phase gets its own production preflight, SHA, dry-run, explicit deployment approval and rollback-only postflight. Both are DB-first and old-app compatible because public signatures and result contracts remain unchanged.

### 25.20 Test and regression plan

For each subphase run focused 2B SQL and ACL tests, tenant A/B IDOR matrix, no-membership/pending/suspended/global-role negatives, event/lane composite-FK checks, RLS recursion checks, direct-DML denial and fixture cleanup. Run the existing event hierarchy/concurrency harnesses, 2A regression, full Supabase DB suite, all Node tests, TypeScript, production build, Events/Admin Events Playwright at mobile and desktop widths, `npm audit --omit=dev`, changed-files ESLint and `git diff --check`.

2B-2 additionally proves public anon/authenticated parity, PII-free keys, counts for registered/approved/reserve/cancelled, sold-out clamp, pagination <=50, stable order and no fetch-all/N+1 regression. All tests remain local until a separately approved production preflight.

### 25.21 Rollback plan

- Capture exact phase-specific definitions, owners, grants, paths and normalized fingerprints before implementation and again before deployment.
- Preserve every public signature and response contract so application rollback remains possible.
- Rollback is a reviewed forward migration restoring only the prior definitions/grants for the affected subphase; never edit an applied migration and never use migration repair.
- Do not remove tenant columns, memberships, composite FKs, the single-active guard or temporary defaults.
- STOP on baseline drift, unexpected caller, grant widening, mixed-tenant allow, public PII, changed business code, concurrency regression, nonzero fixture or unexpected pending migration.

### 25.22 SEC-004 impact, blockers and verdict

Already closed by 9D-2A: event registration owner/staff global-role bypasses for registration, cancellation, approval, payment, promotion confirmation, My Events and participant listing.

9D-2B will close: global staff authority in active event create/update/activate/list, unscoped event/public aggregation, mixed-tenant event-lane assignment through these writers, and the three unused legacy service event-management entry points.

Still open afterward: 9D-2C event promotion/e-mail claim boundaries; 9D-3 lane/block/configuration RPC; 9D-4 reports/profile/account helpers; 9D-5 compatibility retirement; 9E trusted tenant selection/routing; 9F module cutover; 9G full cross-tenant E2E/concurrency; and 9H final SEC-004/second-tenant audit.

No unresolved business decision blocks local 2B-1. The active-single bridge and current role mapping are already approved architecture. The absent capacity-floor rule is explicitly preserved rather than invented. A second tenant and selected-tenant UI remain prohibited.

SAAS-9D-2B TECHNICAL PLAN: **READY**

READY FOR SAAS-9D-2B LOCAL IMPLEMENTATION: **GO**

READY FOR PRODUCTION WRITE: **NO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## SAAS-9D-4B-2C — LEGACY GLOBAL VERIFICATION PATH CLOSURE — FINAL PLAN

### 4B-2C.1 Planning baseline and boundary

This final plan is based on repository HEAD
`11466eb157c10bcaf746df6888b77640f5131416` after the successful 4B-2B
application and database cutover. Production is in the **NEW APP + NEW DB**
state, `tenant_user_verifications` is authoritative, the current SECURITY
DEFINER count is **69**, compatibility ownership defaults remain **7/7**, and
the second tenant remains blocked.

This is a planning-only phase. 4B-2C closes the remaining global verification
write projection and temporary compatibility authorization. It does not remove
global declaration/qualification fields, redesign account lifecycle, change
tenant routing, remove ownership defaults, or implement leave-tenant.

### 4B-2C.2 Exact residual inventory

| Object / field / function | Currently used? | Current callers / dependency | Current source and scope | Safe action in 4B-2C | App change | DB/data change | Target phase |
|---|---:|---|---|---|---:|---:|---|
| `profiles.verification_status` | lifecycle/history only | `export_my_data_v1`; `_apply_tenant_user_verification_v1` mirror; frozen profile trigger | global legacy projection | stop all tenant workflow writes; retain frozen/historical | no | function body only; no data rewrite | 4B-2C freeze; lifecycle decision 4C |
| `profiles.permissions_verified` | lifecycle/history only | export; mirror; frozen trigger | global legacy projection | same | no | same | 4B-2C / 4C |
| `profiles.permissions_verified_at` | lifecycle/history only | export; mirror; frozen trigger | global legacy projection | same | no | same | 4B-2C / 4C |
| `profiles.permissions_verified_by` | mirror/history | mirror; FK to `profiles(id)`; frozen trigger | global legacy projection | stop writes; retain FK/column | no | no data rewrite | 4B-2C / 4C |
| `profiles.permissions_verification_note` | lifecycle/history only | anonymization PII collection; mirror; frozen trigger | global legacy PII | stop writes; retain frozen for account-wide anonymization | no | no data rewrite | 4B-2C / 4C |
| `profiles.verified_at` | mirror/history | mirror; frozen trigger | global legacy projection | stop writes; retain frozen | no | no data rewrite | 4B-2C / 4C |
| `profiles.verified_by` | mirror/history | mirror; frozen trigger | global legacy projection | stop writes; retain frozen | no | no data rewrite | 4B-2C / 4C |
| `profiles.unverified_at` | mirror/history | mirror; frozen trigger | global legacy projection | stop writes; retain frozen | no | no data rewrite | 4B-2C / 4C |
| `profiles.unverified_by` | mirror/history | mirror; frozen trigger | global legacy projection | stop writes; retain frozen | no | no data rewrite | 4B-2C / 4C |
| `_apply_tenant_user_verification_v1(uuid,uuid,text,text,text,uuid)` | active internal helper | two tenant writers | tenant table **plus temporary global mirror** | retain INVOKER signature; delete profile mirror and transaction-setting bridge | no | body replacement | 4B-2C |
| `update_profile_verification(uuid,text,text)` | **active** | `app/admin/users/page.tsx`; focused Admin Users test | tenant-scoped via active-single bridge despite legacy name | retain signature/DTO and authenticated ACL; remove temporary employee compatibility; admin-only tenant writer | no | body replacement | 4B-2C; bridge removal 9E |
| `update_reservation_customer_verification_v1(uuid,text,text)` | active | Check-in | resource-bound tenant writer | retain unchanged except dependency fingerprint guard | no | none | safe/no change |
| `get_my_active_tenant_verification_v1()` | active | Account, Dashboard, Booking | active-single tenant reader | retain unchanged | no | none | 9E routing dependency |
| `admin_list_users_v1(...)` | active | Admin Users | tenant table reader | retain unchanged; named DTO fields are tenant values, not profile fallback | no | none | safe/no change |
| `get_reservation_customer_profiles_v1(uuid[])` | active | Check-in and cancellation server route | reservation-bound tenant reader | retain unchanged | no | none | safe/no change |
| `get_reservation_customer_profiles_v1__saas9d1_core(uuid[])` | no runtime caller | historical tests/inventory only; outer reader no longer calls it | closed INVOKER legacy profile reader | retain fail-closed in 4B-2C unless catalog dependency proof permits a separately asserted DROP; no runtime grant | no | optional object removal, no data | 4B-2C cleanup candidate |
| `_backfill_csk_tenant_user_verifications_v1()` | no runtime caller | foundation migration/tests only | closed INVOKER one-time backfill | retain closed for reproducibility; never expose or rerun in runtime | no | none | safe/no change |
| `create_reservation_v2` closed core and retained `create_reservation` | active compatibility contracts | booking RPC callers | tenant status through `_tenant_verification_status_for_lane_v1`; no profile fallback | retain unchanged and fingerprint-guard | no | none | safe/no change / later API retirement |
| `update_my_profile_v1(...)` | active owner contract | Account | global declarations/profile plus tenant-table invalidation | retain unchanged; no global verification write | no | none | safe/no change |
| `export_my_data_v1()` | active account-wide contract | account export API | reads three historical global profile values | retain unchanged in 4B-2C | no | none | 4C lifecycle review |
| `anonymize_my_account_v1()` | active account-wide contract | account deletion API | captures legacy note for PII redaction, then deletes profile | retain unchanged in 4B-2C | no | none | 4C lifecycle review |
| `prevent_non_admin_profile_privilege_changes()` | active profile UPDATE trigger | all profile UPDATE paths | global profile guard; fingerprint frozen | leave byte-for-byte unchanged | no | none | 4D |
| profile verification indexes and `permissions_verified_by` FK | schema residual | columns above | global historical storage | retain; no tenant authority | no | none | 4C/schema-retention decision |

The application uses verification-shaped DTO field names in Admin Users and
Check-in, but those values now come from `tenant_user_verifications`. That is
not a legacy global read. Searches of application and server code find no
direct selection of the legacy profile verification columns. Reports and
Events do not consume them. Reservation admission uses the lane-bound tenant
helper. Check-in mutation uses the reservation-bound writer.

### 4B-2C.3 Global profile field classification

| Field | Type | Active tenant reader | Active writer before 4B-2C | Account-wide meaning | Tenant-only meaning | 4B-2C state | Remove now? | PII / retention |
|---|---|---:|---|---:|---:|---|---:|---|
| `verification_status` | `text` | none | temporary mirror | no | yes | frozen/historical | no | lifecycle export dependency |
| `permissions_verified` | `boolean not null` | none | temporary mirror | no | yes | frozen/historical | no | lifecycle export dependency |
| `permissions_verified_at` | `timestamptz` | none | temporary mirror | no | yes | frozen/historical | no | lifecycle export dependency |
| `permissions_verified_by` | `uuid` | none | temporary mirror | no | yes | frozen/historical | no | profile FK/history |
| `permissions_verification_note` | `text` | none | temporary mirror | no | yes | frozen/historical | no | PII; anonymization dependency |
| `verified_at` | `timestamptz` | none | temporary mirror | no | yes | frozen/historical | no | history |
| `verified_by` | `uuid` | none | temporary mirror | no | yes | frozen/historical | no | history |
| `unverified_at` | `timestamptz` | none | temporary mirror | no | yes | frozen/historical | no | history |
| `unverified_by` | `text` | none | temporary mirror | no | yes | frozen/historical | no | history/legacy mixed type |

The account-wide declaration and qualification columns (`permission_*` and
`qualification_*`) are explicitly outside this closure. They remain global
user assertions and continue to invalidate tenant decisions through
`update_my_profile_v1`; they must not be confused with staff verification.

Retained legacy verification columns have this strict post-4B-2C contract:

- **FROZEN / HISTORICAL ONLY**;
- zero tenant workflow reads;
- zero tenant workflow writes;
- zero fallback into any tenant authorization or business decision;
- no backfill from tenant state and no cross-tenant aggregation;
- physical deletion, export semantics and retention belong to 4C after an
  explicit lifecycle decision.

### 4B-2C.4 Caller and dependency proof

Repository evidence gives the following current caller counts:

| Contract | App callers | Server callers | RPC/trigger callers | Lifecycle/report dependency | Result |
|---|---:|---:|---:|---:|---|
| legacy global profile verification read | 0 | 0 | 0 tenant workflows | export/anonymization only | no active tenant fallback |
| `_apply_tenant_user_verification_v1` global mirror | 0 direct | 0 direct | 2 tenant writer RPCs | none | removable internal projection |
| `update_profile_verification` signature | **1** (`/admin/users`) | 0 | none | none | retain and harden, do not DROP/revoke authenticated |
| old reservation profile core | 0 | 0 | 0 after outer replacement | historical tests only | closed, safe cleanup candidate |
| foundation backfill helper | 0 | 0 | 0 runtime | migration reproducibility/tests | retain closed |

Therefore “zero legacy callers” is false if interpreted as the old RPC
signature: one active Admin Users caller remains. It is not a blocker because
the target preserves that exact signature and output while eliminating its
global behavior. Any plan that revokes or drops it without an app cutover is
rejected.

Before implementation, a fail-closed migration preflight must re-prove:

1. exactly one application caller of `update_profile_verification` and no
   server caller;
2. zero active reads of profile verification columns outside account lifecycle;
3. exact two internal callers of `_apply_tenant_user_verification_v1`;
4. zero dependencies on the old reservation profile core from live functions;
5. exact lifecycle dependencies above and frozen trigger fingerprint;
6. no unexpected function overloads or grants.

Any extra caller or dependency is a STOP condition and requires plan review.

### 4B-2C.5 Final disposition of `update_profile_verification`

Selected disposition: **redirect/retain**.

The existing signature remains because Admin Users actively calls it. The
function remains SECURITY DEFINER, owned by `postgres`, SP1, and executable
only by `authenticated`. It continues to derive the temporary tenant through
the exact-one-active-tenant bridge, requires an active `admin` membership,
requires an approved operational relationship to the target, and delegates to
the tenant mutation helper. It returns the current JSON contract.

The temporary 4B-2B employee compatibility branch is removed. Employees keep
the resource-bound Check-in path only. `profiles.role`, caller-supplied tenant
data, target UUID existence, service_role, pending/suspended/no membership and
a Tenant-B-only relationship never authorize this writer.

This retains caller compatibility while closing the legacy **global** writer.
It is not a no-op and does not write any global verification column. The
active-single bridge remains an explicit 9E dependency and is not permission
to activate Tenant B.

### 4B-2C.6 Mutation core and no-dual-source target

`_apply_tenant_user_verification_v1` remains a closed SECURITY INVOKER helper
with its signature, owner, SP1 and zero runtime EXECUTE grants unchanged. Its
profile mirror block is removed in full:

- no lookup of actor `profiles.id` solely for the mirror;
- no `set_config('csk.profile_verification_rpc_actor', ...)`;
- no `set_config('csk.profile_verification_rpc_target', ...)`;
- no UPDATE of any verification column in `profiles`;
- no mirror-reset transaction settings.

Tenant row locking, status transition, note validation, no-change behavior,
return JSON and explicit tenant-bound PII-free audit remain unchanged. After
the replacement, `tenant_user_verifications` is the only read/write source for
tenant verification.

`prevent_non_admin_profile_privilege_changes()` can remain byte-for-byte
**FROZEN**: removing the mirror requires no trigger change because no 4B-2C
path attempts a profile verification UPDATE. A discovered need to modify that
trigger is a STOP condition and a 4D dependency.

### 4B-2C.7 ACL and metadata target

| Function | PUBLIC | anon | authenticated | service_role | Mode / owner / path | 4B-2C action |
|---|---|---|---|---|---|---|
| `update_profile_verification(uuid,text,text)` | DENY | DENY | ALLOW | DENY | DEFINER / postgres / SP1 | retain exact public boundary; admin-only body |
| `_apply_tenant_user_verification_v1(...)` | DENY | DENY | DENY | DENY | INVOKER / postgres / SP1 | retain closed; remove mirror |
| `update_reservation_customer_verification_v1(...)` | DENY | DENY | ALLOW | DENY | DEFINER / postgres / SP1 | unchanged |
| `get_my_active_tenant_verification_v1()` | DENY | DENY | ALLOW | DENY | DEFINER / postgres / SP1 | unchanged |
| `admin_list_users_v1(...)` | DENY | DENY | ALLOW | DENY | DEFINER / postgres / SP1 | unchanged |
| `get_reservation_customer_profiles_v1(uuid[])` | DENY | DENY | ALLOW | DENY | DEFINER / postgres / SP1 | unchanged |
| old reservation profile core | DENY | DENY | DENY | DENY | INVOKER / postgres / SP1 | retain closed or DROP only after catalog zero-dependency assertion |
| foundation backfill helper | DENY | DENY | DENY | DENY | INVOKER / postgres / SP1 | unchanged |

Fail-closed ACL is preferred over unnecessary object deletion. The old core
may be dropped only in the same transactional migration if a catalog assertion
proves zero live dependencies and regression tests no longer require its
presence; otherwise it remains closed. This choice does not affect the
security target or function count.

### 4B-2C.8 Security invariants and cross-tenant gate

The implementation must prove:

- Admin A plus an approved Tenant-A relationship can update A;
- Admin A cannot update a Tenant-B-only or unrelated global user;
- Employee A cannot use the compatibility signature and may use only the
  resource-bound Check-in writer within its present scope;
- global `profiles.role=admin` without active A membership is denied;
- pending, suspended and missing membership are denied;
- a Tenant-A decision changes only `(tenant_a,user)` and never `(tenant_b,user)`;
- changing retained profile legacy values cannot alter tenant reads,
  reservation admission, Admin Users, Check-in or account UI;
- no RPC trusts caller-supplied tenant authority;
- audit tenant ID is the resolved tenant, and no PII/note contents enter audit;
- account export, global anonymization, Auth deletion and future leave-tenant
  remain distinct contracts.

### 4B-2C.9 SECURITY DEFINER inventory and expected delta

Current count: **69**.

4B-2C does not add, remove or convert a SECURITY DEFINER function:

- retained DEFINER: `update_profile_verification`,
  `update_reservation_customer_verification_v1`,
  `get_my_active_tenant_verification_v1`, `admin_list_users_v1`,
  `get_reservation_customer_profiles_v1` and all unrelated inventory;
- retained INVOKER: `_apply_tenant_user_verification_v1`,
  `_tenant_verification_status_for_lane_v1` and the closed backfill/core
  helpers;
- losing EXECUTE: none; the legacy-signature Admin Users writer must remain
  authenticated-callable, but its global behavior is removed;
- optional DROP: only the closed INVOKER reservation profile core, with zero
  count impact.

Expected post-4B-2C SECURITY DEFINER count: **69**. Expected unexpected drift:
**0**. UNKNOWN: **0**. Compatibility defaults remain **7/7**.

### 4B-2C.10 Proposed migration scope and implementation order

Proposed single migration name for later review:
`20260921100000_close_legacy_global_verification_path.sql`.

The migration must be transactional and fail closed:

1. assert exact input fingerprints, signatures, overload counts, owner,
   security mode, SP1 and ACL for both replaced functions and every frozen
   dependency;
2. assert application-derived caller inventory in focused source tests, one
   active tenant, membership/verification uniqueness, zero tenant mismatch,
   SECURITY DEFINER 69 and defaults 7/7;
3. replace `_apply_tenant_user_verification_v1` without the global profile
   mirror or transaction settings;
4. replace `update_profile_verification` as admin-only tenant writer with the
   existing signature/DTO and operational relationship gate;
5. optionally drop the closed old reservation core only after a catalog
   zero-dependency assertion; otherwise leave it fail-closed;
6. freeze all other bodies/fingerprints, especially lifecycle functions,
   current readers/writers, reservation admission and profile trigger;
7. postflight no global profile write tokens in either target body, no reader
   fallback, exact ACL/metadata, count 69, defaults 7/7 and unrelated drift 0.

No application file, table/column, RLS policy, account data, verification row,
index, FK, default or trigger is changed. No backfill or data migration occurs.

### 4B-2C.11 Test plan

Focused SQL and source-contract tests must cover:

- the one allowed legacy-signature app caller and zero server callers;
- zero active global verification readers in tenant workflows;
- no profile UPDATE or transaction-setting mirror tokens in the mutation core;
- Admin Users writer: Admin A + related A ALLOW; Tenant-B-only and unrelated
  target DENY;
- employee, global-role-only admin, pending, suspended and no-membership DENY;
- resource-bound Check-in writer remains ALLOW for current employee/admin
  scope and DENY cross-tenant/resource mismatch;
- same user A/B independence and concurrent A/B updates without lost update,
  deadlock or contamination;
- Admin Users, Check-in, Account, Dashboard, Booking and reservation admission
  read only tenant decisions; intentionally conflicting profile legacy values
  cannot affect outcomes;
- no-change idempotency, one audit for a changed tenant decision, explicit
  tenant binding, no denial audit and PII-free details;
- exact ACL/owner/SP1/signatures, direct table/profile DML denial, service_role
  business RPC denial;
- frozen lifecycle/trigger fingerprints and account-wide versus tenant-scoped
  contract preservation;
- SECURITY DEFINER 69, unexpected drift 0, compatibility defaults 7/7;
- focused 4B-2C SQL, 4B-2B regression, CLEAN-005, SEC-007, SEC-009, full DB
  suite, all Node tests, TypeScript, production build, npm audit,
  changed-files ESLint and `git diff --check`;
- Playwright for Admin Users verification, Check-in verification, Account,
  Dashboard and Booking;
- production runtime smoke for Login, Account, Booking, Admin Users, Check-in,
  Reservations and Events; rollback-only A/B matrix and fixture cleanup 0.

### 4B-2C.12 Rollout, rollback and remaining phases

Deployment order: **DB-ONLY / SINGLE-STEP**. The current production app remains
functional because the active Admin Users signature/result is preserved and
all other app callers already use tenant readers/resource-bound writer.

Preflight must prove one pending migration, authoritative SHA, exact production
fingerprints/callers, migration history, one active tenant, verification and
membership integrity, SECURITY DEFINER 69, defaults 7/7 and an exact dry-run.
Any mismatch stops deployment.

The migration rolls back atomically on any assertion. Post-deploy rollback is
forward-only through a separately reviewed corrective migration restoring the
two frozen input definitions; no migration repair or manual SQL. No app
rollback/deployment is needed.

Remaining work is deliberately separated:

- **4C:** account export/anonymization treatment and retention/removal decision
  for frozen global verification columns;
- **4D:** global role helpers and `prevent_non_admin_profile_privilege_changes`;
- **9E:** selected tenant routing and removal of the exact-active-tenant bridge;
- **9D-5/9E gate:** removal of seven compatibility defaults;
- no second tenant before SAAS-9H and SEC-004 closure.

### 4B-2C.13 Final verdicts

SAAS-9D-4B-2C TECHNICAL PLAN: **READY**

ACTIVE LEGACY CALLERS: **1**

LEGACY GLOBAL WRITER: **SAFE TO CLOSE**

LEGACY READ FALLBACK: **ABSENT**

APP CHANGE REQUIRED: **NO**

prevent_non_admin_profile_privilege_changes: **FROZEN**

EXPECTED SECURITY DEFINER COUNT: **69**

DEPLOYMENT ORDER: **DB-ONLY**

READY FOR SAAS-9D-4B-2C LOCAL IMPLEMENTATION: **GO**

READY FOR PRODUCTION WRITE: **NO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

### 4B-2C.14 Local implementation result

Local 4B-2C is implemented by
`20260921100000_close_legacy_global_verification_path.sql`. The retained
`update_profile_verification(uuid,text,text)` signature remains compatible with
its one active `/admin/users` caller, but is now active-admin-only. The closed
INVOKER mutation core no longer sets profile-verification transaction settings
or writes the nine legacy `profiles` verification fields. Employee Check-in
continues through the reservation-bound writer.

The legacy profile fields remain **FROZEN / HISTORICAL ONLY** for the later 4C
lifecycle decision. `prevent_non_admin_profile_privilege_changes()` remains
byte-for-byte unchanged. Application source changes are zero, SECURITY DEFINER
remains 69, defaults remain 7/7, and the migration SHA-256 is
`56242B2575D46C57F7874216CB0F1AF7BCEE4BA1CE1BC769FEA860B4C1884BA0`.

Local evidence: focused SQL 36/36, full DB 1296/1296, Node 746/746,
concurrency/IDOR/cross-tenant PASS, deadlocks 0, contamination 0, TypeScript,
build, changed-file ESLint, focused Admin Users Playwright and
`git diff --check` PASS; fixture cleanup 0.

SAAS-9D-4B-2C LOCAL: **PASS**

READY FOR SAAS-9D-4B-2C PRODUCTION PREFLIGHT: **GO**

READY FOR PRODUCTION WRITE: **NO**

READY FOR 4C: **NO-GO until 4B-2C production PASS/checkpoint**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## SAAS-9D-4B-2B — FINAL PLAN

Planning baseline: checkpoint
`0fc7d5f8a830b27fdd4a43ee5dba818805b8f1bf`, identical to
`origin/main`, after SAAS-9D-4B-2A CLOSED / PROD PASS. Production contains the
closed `tenant_user_verifications(tenant_id,user_id)` foundation, 67 public
SECURITY DEFINER functions and seven temporary CSK ownership defaults. This
section is planning-only. It creates no migration, performs no SQL or Git write
and authorizes no production change.

This section supersedes the provisional 4B-2B notes in section 43. The
foundation now exists in production, so there is no remaining data-model
blocker. The implementation gate is the coordinated RPC/read-model and
application cutover described below.

### 4B-2B.1 Authoritative path inventory

Repository search found no verification reader or writer outside the paths in
this table. Events, event registrations and Reports do not currently consume
verification state. There is no verification server action. UNKNOWN = **0**.

| Caller / function | File / signature | R/W | Current source | Current tenant/resource/target | Auth context | PII | Global role used? | Cross-tenant risk | Target source | App / RPC change |
|---|---|---:|---|---|---|---:|---:|---|---|---|
| Admin Users list | `app/admin/users/page.tsx` -> `admin_list_users_v1(int,int,text,text,text,text)` | R | profile declarations and legacy verification columns; tenant note table | exact-single-active bridge; operational relationship set; target from result rows | browser JWT; RPC already requires active tenant admin | yes | UI calls legacy `get_my_role`; RPC does not rely on it | Tenant-A list currently displays global verification | `tenant_user_verifications` joined by resolved tenant and user | app call/DTO unchanged; RPC body changes |
| Admin Users verification | `app/admin/users/page.tsx` -> `update_profile_verification(uuid,text,text)` | W | `profiles` | target UUID only; no resource | browser JWT | note + decision | yes, in current RPC | global state overwrite | tenant row; legacy profile is write-only mirror during compatibility | app call unchanged; RPC body/ACL changes |
| Check-in list read | `app/admin/check-in/page.tsx`; direct `reservations` SELECT plus `get_reservation_customer_profiles_v1(uuid[])` | R | reservations plus global profile verification | each reservation supplies ID, tenant and target user | browser JWT; RLS and hardened RPC membership | broad operational PII | page UI reads global profile role only as presentation gate | reader can show another tenant's global decision | tenant row keyed by each reservation tenant/user | RPC body changes; caller and DTO stay compatible |
| Check-in token read | `get_check_in_reservation_v1(uuid)` then profile reader | R | reservation DTO, then global profile verification | token -> reservation -> tenant/user | browser JWT; active admin/employee membership | yes | no in hardened RPC | profile hydration currently global | reservation-bound tenant row | verification reader changes; token RPC unchanged |
| Check-in verification | `app/admin/check-in/page.tsx` -> `update_profile_verification(uuid,text,text)` | W | `profiles` | page has reservation ID, but current RPC receives only user ID | browser JWT | note + decision | yes, in current RPC | employee can write without binding the acted-on reservation | new reservation-bound writer | app call and RPC change required |
| Check-in attendance | `update_reservation_attendance(uuid,text)` | W | reservation attendance only | reservation -> tenant/user | browser JWT; active tenant staff | operational PII | no | none for verification | unchanged | no change; regression dependency |
| Cancellation-email recipient fallback | `app/api/send-reservation-cancellation/route.ts` -> `get_reservation_customer_profiles_v1(uuid[])` | R | broad profile DTO; route consumes name/email only | reservation ID -> tenant/user | caller JWT on server route | yes | route obtains legacy role for UI/business gate; RPC is authority | global verification fields are unnecessarily present in returned server DTO | same hardened reservation-bound reader; route ignores verification | no call change; no new exposure |
| Account initial read | `app/account/page.tsx` direct `profiles` SELECT | R | global declarations and legacy verification | caller UID; no tenant context | browser JWT + owner RLS | own PII | no | wrong tenant decision shown once Tenant B exists | global declarations remain profile; tenant decision comes from owner verification RPC | app split-read required |
| Account owner update | `update_my_profile_v1(...)` | W/R | global declarations; resets/returns legacy verification | caller UID; no tenant context | owner browser JWT | own PII | contains legacy admin branch | changed declarations leave tenant rows stale | global declarations stay profile; all existing tenant decision rows become pending | RPC body/result compatibility change; caller remains same |
| Dashboard | `app/dashboard/page.tsx` direct `profiles` SELECT | R | legacy verification | caller UID; no resource | browser JWT + owner RLS | own PII | reads global role for UI | displays global decision | owner verification RPC via temporary active-tenant bridge | app change required |
| Booking UI | `app/booking/BookingForm.tsx` direct `profiles` SELECT | R | legacy verification | caller UID; selected lane exists later but initial profile load has no lane | browser JWT + owner RLS | own PII | no | UI can display stale/global rejection | owner verification RPC for display; backend remains authoritative | app change required |
| Reservation creation API | `app/api/create-reservation/route.ts` -> `create_reservation_v2(...)` | W/read gate | current core reads `profiles.verification_status` | lane ID -> `shooting_lanes.tenant_id`; target=`auth.uid()` | caller JWT forwarded by server route | customer snapshot | no in hardened wrapper | backend limit can use another tenant's decision | tenant row for lane tenant and caller | app call unchanged; DB core/wrapper verification lookup changes |
| Legacy reservation creator | `create_reservation(...)` | W/read gate | legacy profile verification | lane -> tenant; caller | service-only legacy contract; no current repository caller | customer snapshot | legacy body | any retained caller can bypass tenant decision | tenant row derived from lane | DB body hardening or fail-closed retirement in 4B-2B; zero-caller preflight required |
| Account export/delete | `app/api/account/export`, `app/api/account/delete`; `export_my_data_v1()`, `anonymize_my_account_v1()` | R/W | global profile/lifecycle data | account-wide caller UID | server route + owner JWT | yes | no | not a tenant authorization path, but lifecycle must eventually include/erase tenant verification PII | account-wide treatment of every caller-owned tenant row | excluded from 4B-2B body changes; mandatory 4C dependency before legacy removal |

The direct Check-in reservation list remains protected by the tenant-aware RLS
delivered in 9C. Its UI `profiles.role` check is not treated as authority:
every reader/writer below independently requires active tenant membership. The
global UI role gate is a 4D/9E application-context residual, not permission to
weaken the RPC.

### 4B-2B.2 Source-of-truth and compatibility invariant

After the application cutover, every active tenant-specific verification read
or decision in Admin Users, Check-in, Account, Dashboard, Booking and
reservation creation uses `tenant_user_verifications`. There is **no read
fallback** to `profiles.verification_status`, `profiles.permissions_verified`
or related legacy provenance/note fields.

The only temporary bridge is a one-way compatibility projection:

- authoritative write: controlled RPC -> `tenant_user_verifications`;
- compatibility write: the same transaction mirrors the CSK decision into the
  legacy profile columns for OLD APP + NEW DB safety;
- authoritative reads after app deployment: tenant table only;
- forbidden direction: legacy profile fields never overwrite or fill a missing
  tenant row after the 4B-2A backfill;
- period: DB deployment until 4B-2C production closure;
- 4B-2C removes the mirror, the employee-capable legacy writer bridge, closed
  obsolete reader core and legacy verification projection after zero-caller
  proof. Account lifecycle treatment is coordinated with 4C.

A missing tenant verification row is interpreted as the safe default
`pending/false`, not as permission to consult the global profile. A controlled
writer creates the tenant row under its locked trusted relation.

### 4B-2B.3 Trusted resource and tenant derivation

| Flow | Trusted resource / table | Resource ID | Tenant source | Target user source | Verification key | Authorization |
|---|---|---|---|---|---|---|
| Check-in token | `reservations` selected by unique `check_in_token` | token resolves reservation UUID | `reservations.tenant_id`; lane tenant must match existing reservation integrity | `reservations.user_id` | `(reservation.tenant_id,reservation.user_id)` | active admin/employee membership in resource tenant; valid user-bound reservation |
| Check-in list mutation | `reservations` | `p_reservation_id` | locked `reservations.tenant_id` | locked `reservations.user_id` | same | same; employee cannot target self or tenant staff and cannot substitute user/tenant |
| Check-in batch reader | `reservations` | `p_reservation_ids[]` | every requested row must exist and share one tenant | each row's `user_id` | one key per row | active admin/employee membership; mixed/missing/duplicate IDs fail closed |
| Admin Users read/write | membership/reservation/event registration relation | target user (no single resource exists) | temporary exact-single-active tenant bridge | requested/returned user, restricted to approved relationship set | `(resolved tenant,target user)` | active tenant admin; employee never gets generic Admin Users writer |
| Reservation creation | `shooting_lanes` | `p_lane_id` | locked lane `tenant_id` | `auth.uid()` | `(lane.tenant_id,auth.uid())` | existing owner/member booking contract plus tenant decision |
| Owner status | authenticated account; no resource exists | none | exact-single-active bridge only until 9E | `auth.uid()` | `(resolved tenant,auth.uid())` | owner-only read; no privileged write and no note returned |
| Declaration invalidation | all existing caller-owned tenant verification rows | caller UID | each row's stored tenant ID | `auth.uid()` | every existing `(tenant,user)` row | owner may change global assertions; DB may only invalidate decisions, never verify |

There is no current event-registration verification read/write path. Event
registration remains an approved operational relationship for Admin Users but
is not invented as a Check-in resource. Any future event check-in requires a
separate event-registration-bound RPC.

### 4B-2B.4 Current and target Check-in flow

Current list flow:

`browser JWT -> reservations SELECT/RLS -> reservation IDs ->
get_reservation_customer_profiles_v1 -> global profile verification -> UI ->
update_profile_verification(target user) -> global profile -> tenantless audit`.

Current token flow first calls `get_check_in_reservation_v1(token)`, which
correctly resolves and authorizes the reservation tenant, but then loses that
binding when the page calls the global writer with only `user_id`.

Target flow:

`browser JWT -> tenant-aware reservation read or token RPC -> reservation ID ->
reservation-bound profile/verification reader ->
update_reservation_customer_verification_v1(reservation ID, action, note) ->
lock reservation -> derive tenant and user -> lock active actor membership ->
lock (tenant,user) verification row -> mutation -> tenant-bound audit ->
minimal compatible response DTO`.

The target writer accepts no tenant ID and no target user ID. A missing user,
foreign reservation, mixed tenant, resource/user mismatch, pending/suspended
membership or employee self/staff target returns controlled denial before PII
or verification state is returned. Retry/no-change creates no extra audit.

### 4B-2B.5 RPC design

All functions are owned by `postgres` and use
`search_path=pg_catalog,public,pg_temp`. Every migration statement revokes
PUBLIC/anon/authenticated/service_role first, then grants only the explicitly
listed role.

| Name / signature | Mode and EXECUTE | Derivation and authority | Returned PII | Audit / idempotency / concurrency |
|---|---|---|---|---|
| `_apply_tenant_user_verification_v1(uuid,uuid,text,text,text,uuid)` | SECURITY INVOKER; closed to all runtime roles | internal `(tenant,user,action,note,resource type/resource id)` core; outer RPC must already lock and authorize | JSON decision fields only | row lock on tenant PK; changed-only tenant audit; no-change idempotent; deterministic timestamps |
| `update_reservation_customer_verification_v1(uuid,text,text)` | SECURITY DEFINER; authenticated only | reservation ID -> locked tenant/user; active admin/employee membership; employee restrictions; caller cannot supply tenant/user | same decision JSON currently consumed by Check-in, including target user; no unrelated profile data | audit `tenant_id` from reservation; resource ID in allowlisted metadata; membership/resource/verification lock order prevents TOCTOU |
| `update_profile_verification(uuid,text,text)` | existing SECURITY DEFINER; authenticated only after service grant removal | temporary Admin Users/old Check-in bridge; exact active tenant + approved operational relation; active admin, or transitional employee only for OLD APP check-in compatibility | existing JSON contract | calls internal core; mirrors legacy fields until 4B-2C; employee branch removed after app cutover |
| `get_my_active_tenant_verification_v1()` | SECURITY DEFINER; authenticated only | exact-single-active bridge + `auth.uid()`; zero or multiple active tenants deny | `verification_status`, `permissions_verified`, `permissions_verified_at`, `updated_at`; **no staff note or actor IDs** | stable read, no audit, safe pending default; must be replaced by selected tenant context in 9E |
| `admin_list_users_v1(...)` | existing SECURITY DEFINER; authenticated only | exact active tenant + active admin + approved relation set | unchanged existing Admin Users DTO; verification fields joined from tenant table | stable/paginated; filter/count/order use tenant values; no legacy fallback |
| `get_reservation_customer_profiles_v1(uuid[])` | existing SECURITY DEFINER; authenticated only | all reservations exist, unique, same tenant; active admin/employee | unchanged Check-in DTO, with verification fields from tenant row; declarations remain global assertions | stable read; no audit; mixed/foreign IDs deny |
| `update_my_profile_v1(...)` | existing SECURITY DEFINER; authenticated only | caller UID; global declarations remain global | unchanged owner result keys, populated from safe active-tenant row where available | declaration changes lock and invalidate every existing caller-owned tenant row to pending; one PII-free tenant audit per changed row; no verification elevation |
| `create_reservation_v2` plus closed core | existing wrapper/core modes and ACL | lane -> tenant; caller UID | existing reservation JSON only | verification limit/rejection uses tenant row; missing row=pending; booking atomicity unchanged |
| `create_reservation` | existing legacy mode; service-only only if a production caller is proven | lane -> tenant; caller UID/service contract must still identify user | unchanged | use tenant row or fail closed; otherwise retire in 4B-2C after zero-caller proof |

`update_profile_verification` is therefore **not** the final Check-in contract.
It remains a transitional Admin Users/OLD APP wrapper only. The target Check-in
contract is the new reservation-bound RPC. No general RPC accepts
caller-provided `tenant_id`.

The foundation backfill helper stays SECURITY INVOKER and closed. Direct table
access remains denied to PUBLIC, anon, authenticated and service_role; no RLS
policy is added.

### 4B-2B.6 Owner, staff and system contracts

| Contract | Read | Write | Tenant/resource | Audit | PII |
|---|---|---|---|---|---|
| OWNER | own minimal tenant decision through owner RPC | global profile declarations only; may invalidate, never approve/reject | active-single bridge until 9E; invalidation iterates existing own tenant rows | one tenant-bound invalidation audit per changed decision | own status/timestamp; staff note and verifier IDs hidden |
| ADMIN | related-user verification in Admin Users; reservation-bound Check-in | verify/pending/reject within resolved tenant | operational relation for generic Admin Users; reservation required for Check-in | exactly one changed-only audit with explicit tenant | existing Admin Users DTO; Check-in operational DTO only |
| EMPLOYEE | reservation-bound Check-in only | reservation-bound verify/pending/reject under existing self/staff restrictions | reservation is mandatory | same resource tenant audit | only fields required for visit/check-in; no generic user list |
| SYSTEM | no generic service writer or direct table access | declaration invalidation only inside owner RPC; any future automation needs a separately named resource-bound contract | stored row/resource tenant | explicit tenant required | no generic profile DTO |

Global declarations (`permission_*`, `qualification_*`) remain account facts in
`profiles`. Tenant decision/provenance/note fields remain exclusively tenant
state. Leave-tenant is not account deletion; export, anonymization and Auth
deletion remain account-wide 4C contracts.

### 4B-2B.7 Reader and application cutover

| File / reader | Current call / DTO | Target call / DTO | Context source | UI / compatibility impact |
|---|---|---|---|---|
| `app/admin/users/page.tsx` | `admin_list_users_v1`; legacy-shaped verification fields | same call and DTO, DB values from tenant table | active-single bridge in RPC until 9E | no UI change; filter/status now tenant-specific |
| `app/admin/users/page.tsx` writer | `update_profile_verification(target user,...)` | same transitional admin wrapper | active-single bridge + operational relation | no UI/result change; never a Check-in employee authority after final app cutover |
| `app/admin/check-in/page.tsx` reader | `get_reservation_customer_profiles_v1(reservation IDs)` | same call/DTO, tenant verification join | reservation array | no visual change; no fallback |
| `app/admin/check-in/page.tsx` writer | `update_profile_verification(target user,...)` | `update_reservation_customer_verification_v1(reservation ID,...)` | selected reservation | required app change; result DTO remains compatible |
| `app/account/page.tsx` | profile SELECT includes tenant decision/note | profile SELECT only global/account fields + `get_my_active_tenant_verification_v1()` | active-single bridge until 9E | remove staff-note display; status/timestamp UI retained |
| `app/account/page.tsx` save | `update_my_profile_v1` returns legacy result | same call/result keys, values from invalidated tenant row | all existing owner rows; active tenant for returned UI | message unchanged; no stale verified result |
| `app/dashboard/page.tsx` | profile SELECT includes decision | profile identity/role SELECT + owner verification RPC | active-single bridge | same badges; source changes |
| `app/booking/BookingForm.tsx` | profile SELECT includes status | profile contact SELECT + owner verification RPC | active-single bridge for display; lane tenant for authoritative create | same UX; backend result remains authority |
| `app/api/create-reservation/route.ts` | `create_reservation_v2` | same call/result | lane in RPC | no route change |
| `app/api/send-reservation-cancellation/route.ts` | reservation reader used for staff fallback | same reader; verification fields ignored | reservation | no route change; no new browser PII |

No Account/Dashboard/Booking reader has an explicit selected tenant today. This
would be a blocker for Tenant B, but not for 4B-2B while the database enforces
exactly one active tenant. The owner RPC makes this dependency explicit and
fail-closed. It is not the long-term solution: 9E replaces it with trusted
selected tenant context before a second tenant can be active.

### 4B-2B.8 Minimal field matrix

| Field | Owner R | Owner W | Admin R/W | Employee R/W | System | Tenant-scoped | PII | Why |
|---|---:|---:|---|---|---|---:|---:|---|
| global `permission_*` / `qualification_*` | own | own assertions | read related / no direct write | read only for reservation visit | invalidation trigger through owner RPC | no | yes | declared eligibility facts |
| `verification_status` | yes | no | yes/yes | reservation-bound yes/yes | invalidate only | yes | low | operational decision |
| `permissions_verified` | yes | no | yes/yes | reservation-bound yes/yes | invalidate only | yes | low | operational approval |
| `permissions_verified_at` | yes | no | yes/derived | yes/derived | DB timestamp | yes | low | recency/provenance |
| verifier IDs | no | no | only where operationally required; default not returned | no | DB writes actor UID | yes | pseudonymous | audit/provenance, not UI identity |
| verification note | **no after cutover** | no | yes/yes for related user | reservation-bound yes/yes | no generic access | yes | yes | sensitive staff note; not owner-facing |
| `verified_at/by`, `unverified_at/by` | no | no | mutation/result only if existing UI needs it | no | DB-managed | yes | pseudonymous | workflow history |
| email/name/phone/address | own | existing profile contract | current Admin Users related scope | Check-in minimum only | no generic access | global profile PII | yes | operational contact; never added to verification-only RPC |

No new verification RPC returns membership metadata, another user's tenant ID,
tokens, Auth data, password data or unrelated profile fields.

### 4B-2B.9 Audit and concurrency invariants

Every changed privileged tenant verification mutation writes exactly one
`audit_logs` row with `tenant_id` derived from the reservation or approved
operational relation. Check-in audit includes an allowlisted reservation ID and
stable action only. Notes, declarations, email, phone, address and document
data are excluded. Denial and no-change write no audit. A normal tenant
verification audit with `tenant_id IS NULL` is a migration/test failure.

Lock order is fixed: trusted resource (when present), actor membership, target
tenant membership needed for employee restrictions, verification row, then
legacy profile mirror. Generic Admin Users writes take a tenant-scoped advisory
lock before the target row. Declaration invalidation locks the caller profile,
then tenant verification rows ordered by tenant UUID. Tests must prove:

- concurrent verification updates serialize with last committed state and no
  duplicate changed audit;
- verification update versus Check-in/attendance has no deadlock and cannot
  bypass the decision;
- Check-in retry is idempotent;
- simultaneous Tenant-A and Tenant-B decisions for one user affect independent
  rows;
- stale readers never fall back to profiles;
- a resource tenant mismatch fails before state access;
- suspension/pending transition racing a mutation results in denial or a
  fully authorized mutation under the locked membership, never an unbound
  write;
- deadlocks, lost updates, broken invariants and cross-tenant effects are zero.

### 4B-2B.10 Deployment order and intermediate-state safety

Deployment model: **TWO-STEP (DB compatibility first, then application)**.

1. **DB compatibility migration.** Freeze exact fingerprints/metadata/ACL,
   table shape and 67-function baseline. Add the closed INVOKER mutation core,
   the resource-bound Check-in writer and owner reader. Harden the existing
   compatibility writer, Admin Users reader, reservation profile reader,
   reservation creation verification gate and owner declaration invalidation.
   Enable authoritative tenant writes plus one-way legacy mirror. Revoke the
   unproved service_role grant from `update_profile_verification`. Preserve old
   signatures and browser DTOs.
2. **Application deployment.** Switch Check-in mutation to reservation ID;
   split owner profile reads from tenant verification reads in Account,
   Dashboard and Booking; stop rendering the staff verification note to owner.
   Add focused parser/contract tests. Admin Users and server routes retain their
   existing calls.
3. **Observation gate.** Prove no active caller reads legacy verification, no
   employee uses the legacy writer, no tenant/profile divergence and no raw
   errors/PII leak. Only then may 4B-2C be planned/executed.

Why not APP-FIRST: the old database lacks both the reservation-bound writer and
owner reader. Why not a one-shot coordinated deployment: DB-first keeps OLD APP
+ NEW DB functional while the compatibility wrapper and mirror are present.
Every intermediate state is fail-closed, avoids cross-tenant access, preserves
Check-in for current staff and loses no decision.

Compatibility matrix:

| State | Result |
|---|---|
| OLD APP + OLD DB | current production; safe only while one active tenant |
| OLD APP + NEW DB | functional; tenant table authoritative, resource readers hardened, old writer bridge and legacy mirror preserve UI |
| NEW APP + OLD DB | unsupported and must never be deployed; new RPCs absent |
| NEW APP + NEW DB | target 4B-2B state; active operational reads use tenant table only |

### 4B-2B.11 Exact DB, RPC and application scope

Proposed DB migration scope (name reserved only for later implementation
review): `20260920150000_cutover_tenant_user_verification.sql`.

Exact DB scope:

- create the closed INVOKER mutation core;
- add the reservation-bound writer and minimal owner reader;
- replace bodies/ACL as specified for `update_profile_verification`,
  `admin_list_users_v1`, `get_reservation_customer_profiles_v1`,
  `update_my_profile_v1`, `create_reservation_v2`/its closed core and retained
  `create_reservation` verification gate;
- preserve table RLS with zero policies and zero direct runtime grants;
- add no tenant parameter, profile fallback, default or data rewrite;
- freeze `prevent_non_admin_profile_privilege_changes()` fingerprint/body;
- preserve all unrelated RPC fingerprints and seven compatibility defaults.

Exact application scope:

- `app/admin/check-in/page.tsx` and its focused tests;
- `app/account/page.tsx` and tests;
- `app/dashboard/page.tsx` and tests;
- `app/booking/BookingForm.tsx` and booking contract tests;
- generated Supabase types only if this repository maintains them for the two
  new signatures;
- no event, report, role, contact, note, lifecycle or routing feature change.

### 4B-2B.12 Exact 4B-2C residual

After 4B-2B the following remains legacy and is the input to 4B-2C/referenced
later phases:

- global profile verification columns as a **write-only compatibility mirror**;
- `update_profile_verification` as an active-single-tenant Admin Users/old-app
  compatibility wrapper; employee compatibility must be removed after caller
  telemetry/zero-caller proof;
- closed `get_reservation_customer_profiles_v1__saas9d1_core` if the hardened
  wrapper no longer calls it;
- any retained legacy `create_reservation` service contract after production
  caller proof;
- transaction settings used only to permit the legacy profile mirror;
- profile verification indexes/FKs and legacy trigger dependencies;
- account export/anonymization treatment of tenant verification data (4C);
- global `get_my_role`/`is_admin` UI/helper retirement and
  `prevent_non_admin_profile_privilege_changes()` body hardening (4D);
- exact-active-tenant owner/Admin Users bridge replacement with selected tenant
  routing (9E);
- seven compatibility ownership defaults (9D-5/9E gate).

4B-2C may remove the mirror/fallback artifacts only after NEW APP + NEW DB is
proven, account lifecycle is safe, and zero active caller depends on them.
There is no legacy verification **read fallback** in the 4B-2B target.

`prevent_non_admin_profile_privilege_changes()` remains **FROZEN**. 4B-2B uses
the existing controlled transaction-setting bridge only for the temporary
legacy projection. No trigger-body change is required; any discovered need to
change it is a STOP condition and 4D dependency.

### 4B-2B.13 Security inventory and expected count

Current production: SECURITY DEFINER **67**, compatibility defaults **7/7**,
UNKNOWN **0**.

The closed mutation helper is SECURITY INVOKER and does not change the count.
Two new externally callable, table-closing boundaries are required:

1. `update_reservation_customer_verification_v1(...)`;
2. `get_my_active_tenant_verification_v1()`.

Both must be SECURITY DEFINER because direct authenticated and service-role
table access remains denied and no permissive RLS policy may be added. Existing
function replacements do not change the inventory. Expected post-4B-2B
SECURITY DEFINER count: **69**. Unexpected drift: **0**.

### 4B-2B.14 Required local and production test plan

Focused SQL:

- exact function fingerprints, signatures, owner, SP1, mode and ACL;
- table owner/RLS/zero-policy/direct-denial for PUBLIC, anon, authenticated and
  service_role;
- ADMIN_A + related A/resource A ALLOW; B-only/unrelated/resource B DENY;
- EMPLOYEE_A reservation A ALLOW under existing restrictions; self, tenant
  staff, B resource and caller-spoof attempts DENY;
- global `profiles.role=admin` without active A membership, pending,
  suspended and no membership DENY;
- same user verified in A/unverified in B remains independent;
- Admin Users filters/count/DTO use only Tenant-A decision;
- mixed/missing/duplicate reservation reader arrays deny;
- owner reader returns own minimal status and never staff note/verifier IDs;
- declaration edit invalidates every existing own tenant decision, cannot
  verify and produces tenant-bound PII-free audits;
- reservation create rejection/limit uses lane tenant decision; no overbooking,
  idempotency or pricing regression;
- no active target reader contains a legacy verification fallback;
- audit tenant binding, no-change/replay idempotency and fixture cleanup zero;
- concurrency matrix above, deadlocks/lost updates/contamination zero;
- SECURITY DEFINER 69, unexpected drift zero, defaults 7/7.

Regression and application verification:

- focused Admin Users, Check-in, Account, Dashboard, Booking and
  create-reservation Node tests;
- CLEAN-005 profile DML, 9D-1 reservation/check-in, SEC-007 audit and SEC-009
  lifecycle regression;
- full Supabase DB suite and all Node tests;
- TypeScript, production build, npm audit, changed-files ESLint and
  `git diff --check`;
- Playwright: `/admin/users`, Check-in list/token and verification mutation,
  `/account`, dashboard and Booking, including controlled errors and mobile
  layout where the source split changes loading state;
- production preflight: project identity, migration history/SHA, exact single
  pending migration, frozen fingerprints, one active tenant, row/orphan/
  mismatch counts, table ACL, SECURITY DEFINER 67 and defaults 7/7;
- production post-deploy/app smoke: Admin Users, Check-in, Account, Dashboard,
  Booking, reservation create, Login; no 5xx; rollback-only A/B matrix;
  fixture cleanup zero.

Rollback is forward-only: each DB migration is transactional and fail-closed;
post-deploy reversal requires a separately reviewed corrective migration.
Never use migration repair or manual production edits. App rollback is safe
only while the DB compatibility wrapper/mirror remains active.

### 4B-2B.15 Final verdicts

SAAS-9D-4B-2B TECHNICAL PLAN: **READY**

RESOURCE-BOUND TENANT RESOLUTION: **PASS**

CHECK-IN CUTOVER: **READY**

READER CUTOVER: **READY**

APP CUTOVER REQUIRED: **YES**

NEW RPC REQUIRED: **YES**

LEGACY FALLBACK AFTER TARGET: **ABSENT**

DEPLOYMENT ORDER: **TWO-STEP**

DATA MODEL BLOCKER: **NO**

prevent_non_admin_profile_privilege_changes: **FROZEN**

EXPECTED SECURITY DEFINER COUNT: **69**

READY FOR SAAS-9D-4B-2B LOCAL IMPLEMENTATION: **GO**

READY FOR PRODUCTION WRITE: **NO**

READY FOR 4B-2C: **NO-GO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

### 4B-2B.16 Local implementation result — 2026-09-17

SAAS-9D-4B-2B was implemented locally within the approved scope. The DB-first
compatibility migration, resource-bound Check-in writer, minimal owner reader,
tenant-source reader/booking cutover and four application caller changes are
complete. `prevent_non_admin_profile_privilege_changes()` remains byte-semantic
fingerprint unchanged. The authoritative tenant table remains closed to direct
runtime access.

Evidence: focused SQL **37/37 PASS**, full DB **40 files / 1260 tests PASS**,
Node **742/742 PASS**, deterministic concurrency PASS with deadlocks/lost
updates/cross-tenant effects/fixture all zero, TypeScript/build PASS and full
Playwright **31/31 PASS**. SECURITY DEFINER is exactly **69**, unexpected drift
is zero and compatibility defaults remain **7/7**. Migration SHA-256 is
`F6B86E487018DC54DE8A35A026C991E66B9E1B8857F9CCCCA0C763688DAF1412`.

The exact implementation and residual evidence is recorded in
`SAAS_9D_4B2B_VERIFICATION_CHECKIN_CUTOVER_REPORT.md`.

READY FOR SAAS-9D-4B-2B PRODUCTION PREFLIGHT: **GO**

READY FOR PRODUCTION WRITE: **NO**

READY FOR 4B-2C: **NO-GO until production PASS/checkpoint**

## 43. SAAS-9D-4B-2 — FINAL PLAN

Planning baseline: checkpoint `567dfa8ca3a971f8ea2d0490a19594f94199960f`,
identical to `origin/main`, after 4B-1B CLOSED / PROD PASS. Production has 67
public SECURITY DEFINER functions and seven temporary CSK ownership defaults.
This section is planning-only and performs no database or application change.

### 43.1 Exact inventory and scope decision

| Function | Signature | Domain / callers | Mode / owner / path | ACL | Current authority and tenant source | PII / bypass risk | Baseline fingerprint | Expected target |
|---|---|---|---|---|---|---|---|---|
| `update_profile_verification` | `(uuid,text,text)` | tenant staff verification; `app/admin/users/page.tsx`, `app/admin/check-in/page.tsx` | DEFINER / `postgres` / `public,pg_temp` (SP2) | authenticated + service_role | global `profiles.role`; target UUID; no tenant/resource binding | global verification, note and operator fields can be changed across tenants | normalized MD5 `a0522b6beb94bde3bdff22799afc1368` | retain only as a temporary admin compatibility wrapper over tenant storage; remove global-role authority and service grant; employee check-in must move to a resource-bound versioned RPC |
| `prevent_non_admin_profile_privilege_changes` | `()` trigger | `BEFORE UPDATE profiles`; indirectly reached by owner and staff profile writers | DEFINER / `postgres` / `pg_catalog,public,pg_temp` (SP1) | closed | calls global `is_admin`; uses transaction settings for legacy profile verification writes; no tenant context | false allow/deny and global-field invalidation when verification becomes tenant-scoped | normalized MD5 `d28cb697d8355a5e8005296a03ad63ea` | frozen 4B-2 dependency; final body hardening remains 4D after tenant verification cutover |
| `admin_list_users_v1` | `(integer,integer,text,text,text,text)` | `app/admin/users/page.tsx` | DEFINER / `postgres` / SP1 | authenticated | active membership and operational relation, but reads verification columns from `profiles` | Tenant-A list displays global state changed by Tenant B | frozen by 4B-1A/1B | must read tenant verification storage without changing its DTO |
| `get_reservation_customer_profiles_v1` | `(uuid[])` | `app/admin/check-in/page.tsx` | hardened reader from 9D-1 | authenticated contract | reservation relationship, but returns global profile verification fields | check-in can display another tenant's decision | current 9D-1 fingerprint to be captured at preflight | replace/cut over to a reservation-bound tenant verification reader without widening PII |

`update_profile_verification` is the only existing public writer owned directly
by 4B-2. The trigger and two readers are mandatory dependencies, not permission
to absorb unrelated 4D or 9D-1 work. There are no other unclassified 4B-2
functions: UNKNOWN = **0**.

### 43.2 Confirmed data-model blocker

The active implementation stores `verification_status`, `permissions_verified`,
verification timestamps, verifier identifiers and the verification note once
per global row in `profiles`. Both Admin Users and reservation Check-in treat
these values as an operational decision made by tenant staff. Therefore an
authorization-only rewrite is insufficient: Tenant A could still overwrite
the state observed and enforced by Tenant B.

The current owner surfaces (`/account`, `/dashboard`, `/booking`) also read the
same global fields directly. Check-in calls the writer with only a target user
ID even though the trusted tenant/resource is the reservation. Correct isolation
requires both new tenant-scoped storage and caller/read-model cutover. This is a
**DATA MODEL BLOCKER**, not a migration defect and not something that may be
masked with the exact-single-active-tenant bridge.

### 43.3 Required phased design before implementation

4B-2 must be split and separately approved:

1. **4B-2A — tenant verification foundation.** Add a closed table keyed by
   `(tenant_id,user_id)` for tenant verification decision state. RLS is enabled
   with zero direct client policies/grants. Backfill only CSK records whose
   operational relationship is deterministic. Any non-default global state for
   an unrelated or ambiguously related user is a STOP condition. Global profile
   fields remain frozen compatibility data during this expand phase.
2. **4B-2B — RPC/read-model and application cutover.** Make the existing writer
   an admin-only compatibility wrapper using active membership plus the approved
   operational relationship. Introduce a reservation-bound versioned check-in
   writer whose tenant comes from the reservation/lane relationship, not a
   caller value. Cut `admin_list_users_v1`, the check-in reader, Admin Users,
   Check-in, Account, Dashboard and Booking to the tenant state selected by
   trusted application context. The employee path is allowed only through the
   reservation-bound workflow.
3. **4B-2C — legacy closure.** After all readers/writers use tenant storage,
   revoke service_role from the legacy writer, remove its employee use, freeze
   or remove global verification projection, and prove no fallback. Changes to
   `prevent_non_admin_profile_privilege_changes`, global declaration-reset
   behavior and legacy `is_admin` belong to 4D. Removal of the single-active
   bridge and selected-tenant routing belongs to 9E.

Because 4B-2B needs trusted tenant context and application changes, local 4B-2
implementation is blocked until its application-cutover boundary is approved.
It must not be released as a DB-only authorization patch.

### 43.4 Authorization and operational relationship contract

- ADMIN_A + a target related to Tenant A: ALLOW for Tenant-A verification only.
- ADMIN_A + Tenant-B-only or unrelated global target: DENY before profile PII.
- EMPLOYEE_A: ALLOW only through a Tenant-A reservation/check-in resource and
  only within the existing employee restrictions; self and tenant staff targets
  remain denied.
- global `profiles.role=admin` without active target-tenant membership: DENY.
- pending, suspended, missing membership, tenant spoof or target UUID alone:
  DENY.
- owner self: read tenant state through trusted selected tenant; no privileged
  verification write. Owner declaration edits remain a separate self-service
  contract.
- server/system: no generic service-role writer. Any future server path must be
  separately named, resource-bound and service-only.

The approved relationship predicate remains membership, tenant-owned
reservation, or tenant-consistent event registration. The check-in mutation is
narrower and must bind to the supplied reservation. Tenant-A mutation may never
alter the Tenant-B row.

### 43.5 Verification field matrix

| Field group | Scope | Owner | Admin | Employee | System | Reason / cross-tenant risk |
|---|---|---|---|---|---|---|
| `permission_*`, `qualification_*` declarations | global user assertion | read/write own | least-privilege read | least-privilege read in check-in | no direct write | facts declared by the account; an edit must invalidate affected tenant decisions, not silently overwrite them |
| `verification_status` | tenant | read selected tenant | read/write related user | resource-bound read/write only | no generic write | tenant operational decision; global storage contaminates tenants |
| `permissions_verified` | tenant | read selected tenant | read/write related user | resource-bound read/write only | no generic write | approval of declarations by a tenant |
| `permissions_verified_at`, `permissions_verified_by` | tenant | read own tenant result | read/write through RPC | resource-bound write | controlled metadata only | tenant actor and decision provenance |
| `permissions_verification_note` | tenant, sensitive | read own only if product contract retains it; default hide | operational read/write | resource-bound write | no generic write | staff note/PII leakage risk |
| `verified_at/by`, `unverified_at/by` | tenant | minimal status history | operational read/write | resource-bound write | controlled metadata only | workflow history cannot be shared across tenants |
| legacy `verification_note` | unresolved legacy content but operationally tenant-bound if retained | no new access | no fallback | no access | no write | preflight must classify non-empty rows; ambiguous data blocks backfill |

The new table must use trusted actor UUIDs consistently (not mixed profile IDs
and text IDs), tenant-bound audit, deterministic timestamps, a unique
`(tenant_id,user_id)` key and no direct browser DML.

### 43.6 Trigger and audit boundaries

The profile trigger currently protects global fields with `is_admin()` and
transaction settings. 4B-2 must not weaken it. During expand/cutover it remains
frozen and blocks direct global-field mutation. Once tenant storage is
authoritative, direct changes to tenant verification are prevented by the new
table's closed ACL/RLS and controlled RPCs.

Changing global declarations must eventually mark every applicable tenant
verification pending without granting owner authority over tenant decisions.
That multi-row invalidation and removal of global `is_admin` from the profile
trigger is explicitly 4D work. Until then, 4B-2 cannot claim full closure.

Every changed privileged verification mutation creates exactly one audit with
the resolved `tenant_id`, pseudonymous actor/target and no note contents or
document data. Denial/no-change creates no audit. A normal tenant verification
must never create a NULL-tenant audit.

### 43.7 Caller compatibility and deployment gate

| Caller | Current arguments/context | Required target | App change |
|---|---|---|---|
| `app/admin/users/page.tsx` | target user, action, note; no tenant | trusted selected tenant plus related target | YES unless temporary CSK bridge is explicitly accepted only for 4B-2A |
| `app/admin/check-in/page.tsx` | reservation available locally, but RPC receives only target user | reservation-bound versioned RPC; tenant derived from reservation | YES |
| `admin_list_users_v1` | tenant bridge, global verification columns | tenant verification join, unchanged DTO | DB body change plus later trusted-context cutover |
| check-in customer-profile reader | reservation IDs, global verification columns | reservation-derived tenant verification DTO | DB and caller validation change |
| `/account`, `/dashboard`, `/booking` | direct/global profile verification reads | selected-tenant owner read contract | YES; depends on 9E context |

No caller may supply authoritative `tenant_id`. No service-role caller exists
in the repository for the current writer; production dependency inventory must
reconfirm this before its service grant is revoked.

### 43.8 SECURITY DEFINER, compatibility and tests

Current and blocked-plan count is **67**. The proposed phased design keeps the
existing writer as one hardened compatibility DEFINER and uses closed INVOKER
cores/new closed tenant storage, so the expected count after 4B-2A/2B remains
**67**. Retirement of the legacy wrapper may reduce the count later, but is a
9E/closure decision and is not claimed here. Unexpected drift must be zero.
Compatibility defaults remain **7/7** and are not authorization authority.

Required verification after the blocker is resolved:

- focused tenant verification SQL and deterministic CSK backfill tests;
- global-role, pending/suspended/no-membership and unrelated-target negatives;
- ADMIN_A related A ALLOW; B-only/unrelated DENY; Tenant-B state unchanged;
- employee reservation-bound ALLOW plus self/staff/foreign-resource DENY;
- owner self read and declaration-update regression; owner foreign DENY;
- direct profile and tenant-verification DML denial; trigger regression;
- audit tenant binding, no-change idempotency and PII/note exclusion;
- concurrent A/B verification updates with no lost update or contamination;
- ACL/owner/search_path/fingerprint and SECURITY DEFINER 67 checks;
- admin list, check-in reader, Booking, Account and Dashboard contract tests;
- full DB, Node, TypeScript, build, relevant Playwright, fixture cleanup and
  `git diff --check`.

### 43.9 Rollout and rollback

No migration may be created until the tenant verification schema, backfill
classification and trusted tenant-context/app cutover are approved. The later
rollout must be expand -> deterministic backfill -> dual-read comparison with
no fallback authority -> application cutover -> legacy closure. Each DB step is
transactional and fail-closed; rollback uses a separately reviewed corrective
migration, never migration repair or manual production edits. A second active
tenant remains blocked throughout.

SAAS-9D-4B-2 TECHNICAL PLAN: **READY — PHASED ONLY**

DATA MODEL BLOCKER: **RESOLVED LOCALLY BY 4B-2A; PRODUCTION PENDING**

READY FOR SAAS-9D-4B-2 LOCAL IMPLEMENTATION: **4B-2A COMPLETE; 4B-2B/2C NO-GO**

READY FOR PRODUCTION WRITE: **NO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

### 43.10 Approved 4B-2A local implementation status

The architecture decision approves tenant-scoped verification storage and the
4B-2A/2B/2C split. Local 4B-2A is implemented by
`20260920100000_add_tenant_user_verification_foundation.sql`.

The migration adds closed `tenant_user_verifications(tenant_id,user_id)`
storage and an owner-only SECURITY INVOKER deterministic CSK backfill helper.
It copies only tenant-specific decision/provenance fields, translates legacy
profile actor IDs to Auth user IDs, aborts on unrelated/ambiguous meaningful
state, and never overwrites an existing tenant row. Global declarations,
legacy fields, application readers, the verification writer and profile
privilege trigger remain unchanged.

Local evidence: focused 30/30 plus rollback cleanup PASS; full DB 1223/1223;
Node 739/739; TypeScript/build PASS; focused Playwright 1/1; cleanup 0;
SECURITY DEFINER 67; defaults 7/7. Migration SHA-256 is
`3C328182BF2534FB437332F34C0673D62F75A583DD78BC159F971C1F278D99F9`.

SAAS-9D-4B-2A LOCAL: **PASS**

DATA MODEL BLOCKER: **RESOLVED locally; production deployment pending**

READY FOR 4B-2A PRODUCTION PREFLIGHT: **GO**

READY FOR 4B-2B: **NO-GO until production PASS and checkpoint/review**

READY FOR PRODUCTION WRITE: **NO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## 42. SAAS-9D-4B-1B — FINAL PLAN

Planning baseline: reproducible checkpoint
`4f2a521b94a2b0905eca7bfad52c750a231a6f3b`, identical to `origin/main`,
after SAAS-9D-4B-1A CLOSED / PROD PASS. Production has 67 public SECURITY
DEFINER functions and all seven temporary CSK ownership defaults. This section
is planning-only: it creates no migration, changes no application file,
executes no database write and does not authorize a second tenant.

### 42.1 Exact scope and classification

4B-1B owns three active writer RPC bodies and the tenant-audit trigger changes
required by those writers. The already hardened list RPC is a frozen
compatibility dependency, not a fourth writer. Verification remains in 4B-2;
owner lifecycle remains in 4C; global authorization and the CSK sync-bridge
retirement remain in 4D/9E/9D-5.

| Function | Signature | Repository caller | Current metadata and ACL | Current authority | Target tenant source | Classification | 4B-1B disposition |
|---|---|---|---|---|---|---|---|
| `admin_set_user_role_v1` | `(uuid,text)` | `app/admin/users/page.tsx` | DEFINER, `postgres`, SP1; authenticated | global actor/target `profiles.role`; global admin count | exact-single-active bridge, then target membership | A — BODY HARDENING | mutate only the existing tenant membership; tenant-local last-admin guard and audit |
| `update_profile_identity` | `(uuid,text,text)` | `app/admin/users/page.tsx` | DEFINER, `postgres`, SP2; authenticated + service_role | global actor `profiles.role=admin` | exact-single-active bridge plus approved target relation | A — BODY + ACL HARDENING | active tenant admin only; revoke service_role; tenant-bound audit |
| `update_profile_contact_details` | `(uuid,text,text,text,text,text,text)` | `app/admin/users/page.tsx` | DEFINER, `postgres`, SP2; authenticated + service_role | global actor/target profile roles | exact-single-active bridge plus approved target relation | A — BODY + ACL HARDENING | admin or constrained employee; revoke service_role; tenant-bound audit |
| `set_audit_log_tenant_id` | `()` trigger | audit trigger only | INVOKER, `postgres`, `pg_catalog`; closed | explicit target-type dispatch | explicit tenant plus target relationship | A — INTERNAL BODY HARDENING | add allowlisted tenant-user role/identity/contact audit targets; preserve global profile/account semantics |
| `admin_list_users_v1` | `(integer,integer,text,text,text,text)` | `app/admin/users/page.tsx` | DEFINER, `postgres`, SP1; authenticated | active admin membership after 4B-1A | exact-single-active bridge plus relationship set | D — SAFE / NO BODY CHANGE; E — 9E CUTOVER DEPENDENCY | freeze fingerprint, DTO, filters, role mapping and note source; regression-test only |

There is no repository service-role caller for identity or contact. Tests are
the only callers outside `app/admin/users/page.tsx`. Production preflight must
reconfirm this before revoking service_role EXECUTE. `update_profile_verification`
is intentionally excluded and remains SAAS-9D-4B-2. UNKNOWN = **0**.

Proposed migration:
`20260919150000_harden_tenant_user_role_identity_contact.sql`.

### 42.2 Trusted tenant and operational relationship

The unchanged public signatures temporarily resolve the tenant through
`active_single_tenant_id_v1()`. Exactly one active tenant is required; zero or
more than one fails closed. This bridge is compatibility only and must be
replaced by trusted application tenant context in 9E before Tenant B can be
activated.

Actor authorization is `auth.uid()` plus an **active** membership in the
resolved tenant:

- role and identity: tenant role `admin` only;
- contact: tenant role `admin`, or `employee` under the existing customer-only
  restrictions;
- pending, suspended, absent membership, or global `profiles.role` alone:
  DENY before target PII is read.

The approved target operational relationship is the same canonical predicate
as 4B-1A: a membership in that tenant, a reservation with matching tenant and
user, or a tenant-consistent event registration joined to its event. A global
profile, UUID, browser value or relation only in another tenant is not
authority. Role mutation is narrower: the target must have an **existing**
membership in the resolved tenant; it never creates a membership implicitly.

Authorization and relationship checks precede target-profile selection. A
foreign, unrelated or missing target returns the existing controlled denial
surface without revealing whether a foreign global account exists.

### 42.3 Tenant-local role mutation and legacy bridge

`admin_set_user_role_v1` preserves its signature, legacy UI input/output and
stable result codes. It maps only at the boundary:

- `admin -> admin`;
- `user -> user`;
- `pracownik -> employee`;
- `instruktor -> instructor`;
- and maps the tenant values back to the legacy values in its response.

The authoritative mutation is
`tenant_memberships(tenant_id,user_id).role`, not `profiles.role`. The function
first takes a deterministic tenant-scoped advisory transaction lock, then
locks the target membership. It reads the current role and counts last admins
only from active memberships in that same tenant. Demoting the last active
Tenant-A admin is denied even if Tenant B has any number of admins.

All role changes for one tenant serialize on the same advisory lock. Two
concurrent demotions therefore cannot both observe two admins and leave zero.
Lock order is fixed: tenant advisory lock, actor/target membership rows, then
the target profile row touched by the compatibility trigger. Tests must assert
deadlocks 0 and final active-admin count at least one.

The existing CSK-only membership-to-profile trigger may mirror a CSK role into
`profiles.role` using the approved reverse mapping while legacy authorization
still exists. A membership belonging to a non-CSK tenant never changes the
global profile role. Neither the mirrored profile value nor the trigger is an
authorization source. Sync-bridge removal remains 9D-5/9E work.

### 42.4 Identity and contact contracts

`update_profile_identity` keeps its validation limits, signature and response
shape. It requires active tenant admin membership and the approved target
relationship. No owner or employee permission is added. A current owner
self-service route, where allowed, remains a separate caller-owned contract;
4B-1B does not turn this administrative RPC into an owner bypass.

`update_profile_contact_details` also preserves validation and response shape.
An active tenant admin may update a related target. An active tenant employee
may update only a related operational customer, may not target self, and may
not target any membership whose tenant-local role is `admin`, `employee` or
`instructor`, regardless of global `profiles.role` or membership status. A
related customer with no membership, or an active tenant `user` membership,
remains inside the current employee customer scope. Instructor scope is not
expanded.

Both functions normalize to SP1, remain SECURITY DEFINER owned by `postgres`,
and revoke service_role EXECUTE after the zero-caller gate. No direct profile
UPDATE grant or policy is introduced. No-change returns the current authorized
result and writes no audit.

### 42.5 Frozen list contract and least-privilege PII

`admin_list_users_v1` already uses the 4B-1A eligible-user set, active admin
authorization, tenant role mapping and tenant-note source. 4B-1B must not
replace its body unless a fresh fingerprint review finds a real defect; any
unexpected difference is a STOP condition. Its current 30-column DTO remains
because the existing admin page consumes it. This is a known compatibility
surface, not permission to return foreign users.

The writers read only fields required for validation, mutation and their
unchanged response. Identity returns only identity fields; contact returns only
contact fields; role returns only role/change metadata. No function returns
membership internals, other-tenant relationships, tokens, Auth metadata,
password material or unrelated profile PII. Versioned list summary/detail DTO
minimization remains 9E/9F work.

### 42.6 Tenant-bound audit

The audit trigger gains three explicit tenant target types, for example
`tenant_user_role`, `tenant_user_identity` and `tenant_user_contact`, each with
one allowlisted action. It requires non-null `tenant_id` and target user, proves
that tenant and target relationship, and rejects mismatches. It must not relax
the existing rule that global `profile` and `account` audits have NULL tenant.

Every successful changed mutation writes exactly one audit with resolved
tenant, `auth.uid()` actor and database timestamp. Role details contain only
previous/new tenant role identifiers and stable operation metadata. Identity
and contact details contain only changed-field names/counts. Names, email,
phone, address values, membership metadata and tokens are excluded. Actor and
target labels are pseudonymous. Denial and no-change produce no audit.

Historical global profile audits stay unchanged; 4B-1B performs no blanket
audit backfill.

### 42.7 ACL, compatibility and expected inventory

The three public writers remain SECURITY DEFINER, `postgres` owned, SP1 and
authenticated-only. The audit trigger remains closed SECURITY INVOKER. The
list RPC remains unchanged. The expected public SECURITY DEFINER count after
4B-1B is therefore **67**. Unexpected drift must be zero. Compatibility
defaults remain **7/7** and are not an authorization mechanism.

Compatibility:

| Combination | Result |
|---|---|
| OLD APP + OLD DB | current CSK-only behavior; known unsafe for a second tenant |
| OLD APP + NEW DB | supported: signatures and response shapes unchanged; stronger tenant authorization |
| NEW APP + OLD DB | not applicable; 4B-1B has no application change |
| NEW APP + NEW DB | same as old app until 9E introduces trusted selected-tenant context |

Deployment is **DB FIRST / DB ONLY**. Second tenant remains blocked.

### 42.8 Migration sequence and fail-closed guards

1. Assert the exact four changed signatures plus frozen list signature,
   overload counts, normalized fingerprints, metadata and ACL.
2. Freeze verification, 4C lifecycle, note-model, account-wide and sync-bridge
   definitions so out-of-scope drift aborts.
3. Require exactly one active CSK tenant, valid membership roles/statuses, at
   least one active CSK admin, relationship integrity, SECURITY DEFINER 67 and
   defaults 7/7.
4. Reconfirm no repository or production dependency needs service EXECUTE on
   identity/contact.
5. Replace the audit trigger, role, identity and contact bodies; normalize SP1;
   revoke all function grants and restore authenticated-only EXECUTE on the
   three writers.
6. Postflight target fingerprints, role mapping, tenant-local last-admin
   predicates, relationship-before-PII checks, tenant audit targets, frozen
   list fingerprint, SECURITY DEFINER 67, defaults 7/7 and unrelated drift 0.
7. Commit the transaction only if every assertion passes.

No table, column, index, RLS policy, data backfill, application file, default
removal, membership creation or profile-role bulk rewrite belongs to 4B-1B.

### 42.9 Mandatory test matrix

- ADMIN_A + related Tenant-A user: role/identity/contact ALLOW according to
  each workflow;
- ADMIN_A + Tenant-B-only user or unrelated global user: DENY before PII read;
- global `profiles.role=admin` without active A membership: all privileged
  paths DENY;
- pending, suspended and no membership actors: DENY;
- OWNER self: only existing caller-owned contract ALLOW; administrative owner
  bypass remains DENY; OWNER foreign DENY;
- EMPLOYEE_A: contact ALLOW only for related customer; self, admin, employee,
  instructor, unrelated and Tenant-B targets DENY;
- Tenant-A role writer cannot mutate Tenant-B membership and never creates a
  membership;
- all four role mappings work in both directions at the UI boundary;
- non-CSK membership mutation leaves `profiles.role` unchanged;
- Tenant-A last admin cannot be demoted because of admins in Tenant B;
- two concurrent Tenant-A demotions leave at least one active admin, with
  deadlocks 0, duplicate audits 0 and contamination 0;
- identity/contact cross-tenant races cannot mutate a foreign profile;
- changed mutation creates one tenant-bound PII-free audit; no-change/deny
  create none;
- `admin_list_users_v1` fingerprint, DTO, tenant role field, filtering,
  pagination, de-duplication and tenant note source remain unchanged;
- direct profile UPDATE and service-role RPC execution remain denied;
- account export, global anonymization, Auth deletion, future leave-tenant and
  verification fingerprints remain unchanged;
- SECURITY DEFINER 67, unexpected drift 0, defaults 7/7 and fixture cleanup 0.

Regression suite: focused 4B-1B SQL; 4B-1A note tests; CLEAN-005 profile DML;
SEC-007 audit; SEC-009 lifecycle; 9C membership sync/mapping; all Supabase DB
tests; admin-users Node tests; full Node suite; TypeScript; production build;
focused admin-users Playwright; changed-file ESLint; npm audit; and
`git diff --check`.

### 42.10 Production preflight, rollout and rollback

Read-only preflight must verify project identity, migration history, exactly
one pending migration, migration SHA, five frozen/current fingerprints,
overload counts, zero service callers/dependencies, exact active tenant,
membership/admin/status integrity, CSK profile-membership mapping, relationship
orphans/mismatches, SECURITY DEFINER 67, defaults 7/7, and an exact dry-run.
Any difference is a blocker.

After an approved DB push, verify LOCAL=REMOTE, up-to-date dry-run, all target
fingerprints/ACL/metadata, list unchanged, tenant audit binding, global-role
negative cases, role bridge, last-admin concurrency, PII, runtime admin-users
flows and independent fixture cleanup. Production cross-tenant tests are
rollback-only and avoid real users.

The migration is transactional. Pre/postflight failure rolls it back. A
post-deploy defect is reversed only by a separately reviewed corrective
migration restoring frozen definitions and ACL; never by migration repair or
manual production edits. No app rollback is needed because signatures and
response contracts stay unchanged.

### 42.11 Remaining phases and gates

- 4B-2: `update_profile_verification` tenant hardening;
- 4C: owner self-service, export, anonymization and account deletion review;
- 4D: remaining global auth helpers and trigger authorization;
- 9D-5/9E: remove the CSK role sync and exact-single-active compatibility
  bridges, add trusted application tenant context and retire defaults;
- 9F+: application surface cutover and final cross-tenant verification.

The plan has no unresolved function, caller or role-mapping decision.
UNKNOWN = **0**.

SAAS-9D-4B-1B TECHNICAL PLAN: **READY**

READY FOR SAAS-9D-4B-1B LOCAL IMPLEMENTATION: **GO**

READY FOR PRODUCTION WRITE: **NO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## 38. SAAS-9D-4 — reports / profile / audit / privileged helpers final plan

Planning baseline: production and repository checkpoint
`d871785a5fb580d1ac7f8ca94c666d5cfdc3202d`. SAAS-9D-3A, 9D-3B and
9D-3C are closed with production PASS. The production SECURITY DEFINER count
is `67`, unexpected drift is zero, and the seven compatibility defaults remain
present. This section is planning-only and authorizes no migration, SQL write,
application cutover or production deployment.

### 38.1 Exact scope and boundaries

The frozen catalog assigns exactly 19 live functions to 9D-4/9E. All are owned
by `postgres`. No function from 9D-5, a completed 9D phase, or SAFE / NO CHANGE
is moved into 9D-4.

Legend: SP1 = `pg_catalog, public, pg_temp`; SP2 = `public, pg_temp`; SP3 =
`public`. `A`, `N`, and `S` mean direct EXECUTE by `authenticated`, `anon`, and
`service_role`. Every function in this table is currently SECURITY DEFINER.

| Function | Signature | Domain / callers | SQL callers | Path / ACL | Global role check | User/resource argument | Tenant source / service path | PII / bypass / risk | Severity |
|---|---|---|---|---|---|---|---|---|---|
| `admin_get_reservation_report_export_v1` | `(date,date,uuid,text,text,text)` | reports; `app/admin/reports/page.tsx` | closed `_admin_reservation_report_rows_v2` | SP1 / A | yes, `profiles.role=admin` | optional lane | lane if supplied; otherwise missing; no service caller | operational reservation export; definer bypass can mix tenants | HIGH |
| `admin_get_reservation_report_v1` | `(date,date,int,int)` | legacy report; no TypeScript caller | direct table reads | SP1 / A | yes | none | missing | reservation/customer PII and global aggregates | HIGH |
| `admin_get_reservation_report_v2` | `(date,date,uuid,text,text,text,int,int)` | reports; `app/admin/reports/page.tsx` | closed `_admin_reservation_report_rows_v2` | SP1 / A | yes | optional lane | lane if supplied; otherwise missing | name/email/phone details plus global KPI | HIGH |
| `admin_list_users_v1` | `(int,int,text,text,text,text)` | users; `app/admin/users/page.tsx` | none | SP1 / A | yes | no target | missing selected tenant | broad profile/contact/address/permit/verification/admin-note PII | CRITICAL |
| `admin_set_user_note_v1` | `(uuid,text)` | users page | profile trigger; audit insert | SP1 / A | yes | target user | no tenant relation | privileged note plus tenantless audit | CRITICAL |
| `admin_set_user_role_v1` | `(uuid,text)` | users page | profile trigger and CSK role sync bridge | SP1 / A | yes | target user | should be selected membership | global privilege mutation and tenantless audit | CRITICAL |
| `anonymize_my_account_v1` | `()` | `app/api/account/delete/route.ts` under user JWT | internal redaction helper; business tables; global audit | SP1 / A | last-admin logic uses global role | caller UID | owner account across memberships; Auth deletion is a later server step | all caller PII; intentional definer bypass; lifecycle spill risk | HIGH |
| `export_my_data_v1` | `()` | `app/api/account/export/route.ts` under user JWT | `auth.users` and owner business rows | SP1 / A | no | caller UID | owner account across memberships | full caller export; requires controlled access to `auth.users` | HIGH |
| `get_my_role` | `()` | homepage, admin pages and calendar-feed API | no live RLS caller after 9C; application authorization caller | SP3 / A | returns global role | none | none | global authorization result | CRITICAL |
| `get_public_booking_configuration_v1` | `()` | `app/booking/page.tsx` | booking tables | SP1 / N,A,S | no | none | currently no explicit tenant; active-single bridge required | PII-free config, but cross-tenant configuration mixing | HIGH |
| `handle_new_user` | `()` trigger | `auth.users` -> profile trigger | trigger only | SP2 / none | creates legacy global role | `NEW.id` | onboarding has no selected tenant | profile PII/global role creation; required definer boundary | HIGH |
| `is_admin` | `()` | legacy DB helper | called by profile privilege trigger; no current RLS policy after 9C | SP3 / A | yes | none | none | global privilege predicate | CRITICAL |
| `is_admin_or_employee` | `()` | legacy DB helper | no live RLS policy after 9C | SP3 / A | yes | none | none | global privilege predicate | CRITICAL |
| `is_admin_or_staff` | `()` | legacy DB helper | no live RLS policy after 9C | SP3 / A | yes | none | none | global privilege predicate | CRITICAL |
| `prevent_non_admin_profile_privilege_changes` | `()` trigger | profile UPDATE trigger | calls `is_admin`; invoked by profile writers | SP1 / none | yes | `OLD/NEW` profile | lacks membership/resource context | protects global fields using global authority | HIGH |
| `update_my_profile_v1` | `(text,text,text,text,text,text,bool,bool,bool,bool,bool,bool,bool,bool,bool,bool)` | `app/account/page.tsx` | profile trigger | SP1 / A | reads own global admin role for verification reset branch | caller UID | owner profile; no selected tenant | contact/address/declarations; protected-field bypass boundary | HIGH |
| `update_profile_contact_details` | `(uuid,text,text,text,text,text,text)` | users page | profile trigger; audit insert | SP2 / A,S | yes | target user | no tenant/resource relation; no repo service caller | phone/address PII and tenantless audit | CRITICAL |
| `update_profile_identity` | `(uuid,text,text)` | users page | profile trigger; audit insert | SP2 / A,S | yes | target user | no tenant/resource relation; no repo service caller | names/full name and tenantless audit | CRITICAL |
| `update_profile_verification` | `(uuid,text,text)` | users page and `app/admin/check-in/page.tsx` | profile trigger; audit insert | SP2 / A,S | yes | target user | check-in caller does not pass reservation/tenant; no repo service caller | verification/qualification state and tenantless audit | CRITICAL |

Inventory result: 19/19 classified, UNKNOWN = `0`. The internal report row
helper `_admin_reservation_report_rows_v2(date,date,uuid,text,text,text)` and
the lifecycle redaction helper are dependencies, not additional members of the
67-function SECURITY DEFINER catalog: both remain closed, SECURITY INVOKER
helpers unless a versioned tenant parameter is added to their closed contract.

### 38.2 Final classification

| Class | Functions | Planned disposition |
|---|---|---|
| A. BODY HARDENING REQUIRED | report v2/export; all six admin user/profile functions; `anonymize_my_account_v1`; `export_my_data_v1`; `update_my_profile_v1`; public booking configuration | bind authorization and every read/write/audit to trusted tenant or owner scope; preserve active signatures only where the single-active bridge is an explicit temporary contract |
| B. ACL-ONLY CLEANUP | legacy report v1 | after production zero-caller proof, revoke A/S/N/PUBLIC as applicable; body, owner and search_path fingerprint remain unchanged; final retirement stays 9D-5 |
| C. SECURITY INVOKER CANDIDATE | none accepted in the 19-function scope | export cannot become invoker because it reads `auth.users`; staff/report/profile writers require privileged table access; public config cannot resolve the closed active-tenant bridge as anon without a privileged wrapper |
| D. SAFE / NO CHANGE | none of the 19 | closed report/redaction helpers outside the 19-function catalog remain invoker and internal; previously closed tenant helpers remain outside 9D-4 |
| E. APP-CUTOVER DEPENDENCY | `get_my_role`, `is_admin`, `is_admin_or_employee`, `is_admin_or_staff`, `handle_new_user`, profile privilege trigger | freeze fingerprints and grants in 9D-4; replace/retire only with trusted selected-tenant context and onboarding/role cutover in 9E, then finalize in 9D-5 |

No SECURITY DEFINER function is converted mechanically. The expected count
after the DB-only 9D-4 phases is therefore **67**. A different count is drift
and stops deployment. The later 9E/9D-5 cutover must publish a separate exact
count after the six app-cutover-dependent functions have a proved disposition.

### 38.3 Reporting plan (9D-4A)

1. Add a closed SECURITY INVOKER report core that accepts an already-validated
   tenant UUID. Tenant predicate is applied before KPI aggregation, revenue,
   details pagination and export counting.
2. Preserve active v2/export signatures for OLD APP compatibility. Their small
   definer wrappers resolve exactly one active tenant, require an active `admin`
   membership in it, validate an optional lane belongs to it, and call the core.
   A global `profiles.role=admin` without that membership returns `not_allowed`.
3. Preserve the current admin-only business rule. Employee remains denied; no
   role widening is introduced in 9D-4.
4. Keep KPI/details/export filter semantics identical, page size limits intact,
   CSV at maximum 5000 rows, formula-injection handling unchanged and the
   existing PII-minimized export DTO unchanged. Report details may retain only
   the currently required name/email/phone fields for tenant-authorized admin.
5. The v1 report has no live app caller. 9D-4A performs ACL-only closure after
   production log/caller proof; deletion or signature removal belongs to 9D-5.
6. A future selected-tenant report version and replacement of the active-single
   wrapper belong to 9E/9F. A second active tenant is prohibited before that.

Required proof: Tenant A report has zero Tenant B rows in KPI, revenue, totals,
details and CSV; optional Lane B fails before output; page-independent totals,
DST/calendar ranges, hierarchy and formula/PII safety retain their 6A/6B tests.

### 38.4 Profiles and users plan (9D-4B)

The current functions have only `target_user_id`, which is not a tenant
authority. They must not infer authorization from the target's global profile
role. The recommended operational relationship is:

- active tenant membership in the selected tenant; or
- a reservation owned by that user in the selected tenant; or
- an event registration owned by that user whose event is in the selected
  tenant.

That relationship must be approved as a business rule before implementation.
An unrelated global profile is never enough.

- `admin_list_users_v1`: use the sole-active tenant compatibility wrapper now,
  then return the union of tenant members and operationally related customers,
  de-duplicated by user ID. Admin-only access remains. Search/filter/sort/count
  operate after tenant scoping. Address, declarations, verification and admin
  note remain admin-only because the current page requires them.
- `admin_set_user_role_v1`: role means `tenant_memberships.role`, using the
  approved mapping `admin/user/pracownik/instruktor` <->
  `admin/user/employee/instructor`. Lock target membership and tenant admin
  count, prevent removal/demotion of the last active tenant admin, update the
  selected membership, and let the temporary CSK sync bridge preserve legacy
  `profiles.role`. The global profile value is not the authorization source.
- note and identity: tenant admin only plus an approved target relationship.
  Store one audit with the selected tenant. No employee widening.
- contact details: tenant admin; employee only for an operationally related
  customer and never self/admin/staff, preserving the current restrictions.
- verification: admin for a related target; employee only when a trusted
  reservation/check-in relationship proves the target belongs to the same
  tenant. The existing target-user-only signature cannot prove that relation.
  Introduce a versioned resource-bound RPC for check-in and mark its app caller
  change as a 9E/9F dependency; do not accept a browser tenant UUID alone.

All six functions continue to require definer privilege because authenticated
direct profile UPDATE remains revoked. SP2 functions move to SP1 when their
bodies change. Their service_role grants are removed unless production caller
evidence identifies an exact server-only path; repository inventory found none.

### 38.5 Owner lifecycle plan (9D-4C)

- `update_my_profile_v1` remains strictly `auth.uid()` scoped and cannot accept
  another user or tenant. It keeps the allowlist and verification reset rule.
  Its global-admin special branch must be replaced by a rule based on the
  caller's active memberships or removed if it is not required for self-service.
- `export_my_data_v1` keeps its definer boundary because the allowlisted export
  reads the caller's `auth.users` row. Every business row remains filtered by
  `user_id=auth.uid()` and retains its own tenant ownership internally; no
  tenant, audit, token, admin-note or rate-limit internals are added to output.
- `anonymize_my_account_v1` remains owner-only, locks the caller profile and
  owner rows, anonymizes across the whole account, and never accepts a target
  user. Its single `account_anonymized` audit is an approved global lifecycle
  audit with `tenant_id=NULL`, pseudonymous actor/details and DB timestamp.
  Idempotent retry creates no second audit.

Recommended lifecycle contract is **account-wide across every membership**,
because deletion of the Auth identity cannot safely be tenant-local. This is a
blocking business decision: if deletion is intended to leave other-tenant
access alive, it must become a different "leave tenant" feature and Auth user
deletion must not run. No 9D-4C implementation starts until this is approved.

### 38.6 Audit disposition

There is no standalone client audit writer in the 19-function scope. Audit is
embedded in the admin profile mutations and account anonymization.

| Writer | Tenant derivation | Audit tenant | Read visibility | Required behavior |
|---|---|---|---|---|
| role/note/identity/contact/verification | locked selected membership or locked operational reservation/event-registration relation | exact target tenant | active tenant admin only; no global/foreign audit | actor=`auth.uid()`, DB time, no PII values, no audit on deny/no-change |
| account anonymization | caller-owned account lifecycle | `NULL` | not exposed to tenant staff by tenant audit readers | one pseudonymous global audit; retry creates none |
| self update/export/reports/public reader | no audit mutation | none | n/a | must not create synthetic or denial audits |

All tenant audit inserts explicitly provide `tenant_id`; they do not rely on a
default. Denied cross-tenant attempts are resolved before any update or audit.
No target name, note, email, phone, address, token or raw error is written to
audit details.

### 38.7 Service-role paths

| Function/path | Caller | Authentication / business authorization | Tenant/resource source | Why service is required | Direct EXECUTE target |
|---|---|---|---|---|---|
| account delete route after `anonymize_my_account_v1` | server route | user JWT proves self; DB RPC must succeed first | caller UID/account-wide | Auth Admin `deleteUser` only | lifecycle RPC stays authenticated-only; service never calls it |
| contact/identity/verification current S grants | no live repository caller found | none demonstrated | target user only and therefore insufficient | no demonstrated need | revoke S when body is hardened, after production zero-caller check |
| public booking config S grant | server compatibility only | public PII-free contract | exactly one active tenant | no privileged business mutation | retain only if a live server caller is proved; otherwise N+A only |
| trigger functions | database triggers | trigger event and hardened parent writer | `NEW/OLD` or auth user | required internal trigger execution | no direct N/A/S grants |

Service role is never business authorization. A server caller must first prove
the user or claim and bind the trusted resource; otherwise the call is denied.

### 38.8 PII authorization matrix

| Data | Owner | Tenant admin | Tenant employee | Other tenant / anon |
|---|---|---|---|---|
| own account/profile/export | full approved self contract | only through related admin function | only explicitly allowed operational subset | none |
| name, email, phone for user list | own only | related tenant user/customer | not through global list | none |
| address and declarations | own export/self edit | related tenant user/customer where current admin screen requires | contact edit only for related customer; no broad list grant | none |
| verification state/note | own permitted export/state | related tenant target | related check-in customer only | none |
| admin note | never in self export | related tenant admin only | none | none |
| reservation/event association | owner flows | selected tenant operations | selected tenant existing scope | none |
| tokens, secrets, auth hashes | none | none | none | none |

Every DTO has an allowlist. Tenant UUID may be used internally but is not added
to public DTOs or URLs unless the later trusted 9E routing contract requires a
non-PII tenant selector.

### 38.9 Tenant derivation and authorization rules

1. Reports/public configuration without a resource resolve the existing
   `active_single_tenant_id_v1()` bridge and fail if the result is NULL. This is
   compatibility only and is invalid after a second active tenant.
2. Optional report lane derives its tenant from `shooting_lanes` and must equal
   the resolved tenant.
3. Role mutation derives from the locked target membership in the resolved
   tenant. Caller-supplied user ID is never enough.
4. Profile operations derive from a locked tenant membership or locked
   reservation/event-registration relationship. Mixed or ambiguous relations
   fail; no partial read/update is allowed.
5. Self operations derive the actor only from `auth.uid()` and reject any
   foreign resource even if supplied indirectly.
6. Privileged operations require an active tenant and active membership.
   `profiles.role=admin` without that membership, pending/suspended membership,
   no membership and inactive tenant all deny.
7. Employee is included only in contact/verification operations already
   permitted by the product, with the stronger operational relation. Instructor
   scope is not expanded.

### 38.10 ACL, owner, search_path and compatibility

- Changed definers remain owned by `postgres`, use SP1, schema-qualify objects,
  revoke PUBLIC/N/A/S first, then receive the minimum exact grant.
- Active report/profile/self RPC signatures and response codes remain unchanged
  when the sole-active bridge can safely provide context. Resource-bound
  verification and future selected-tenant list/report contracts are versioned;
  their app switch belongs to 9E/9F.
- ACL-only report-v1 cleanup changes only grants. Its body, security mode,
  owner, path and normalized fingerprint remain unchanged.
- `get_my_role` and `is_admin*` are not rewritten to guess CSK permanently.
  They retain current behavior only until 9E moves every caller to
  `get_my_tenant_role_v1(selected tenant)` and tenant membership checks.
- `handle_new_user` continues to create only the legacy profile. Tenant
  membership onboarding and invitation semantics belong to 9E; it must not
  silently assign users to every active tenant.
- The profile privilege trigger remains frozen until all profile writers and the
  sync bridge have tenant-aware replacements. It is not used as the primary
  authorization control for hardened RPCs.

Caller compatibility:

| File | Caller type | Current args/auth | Required context | App change |
|---|---|---|---|---|
| `app/admin/reports/page.tsx` | browser admin | filters/dates/optional lane; user JWT | active-single bridge now, selected tenant later | no for bridge hardening; yes in 9E |
| `app/admin/users/page.tsx` | browser admin | filters or target user; user JWT | selected/sole tenant plus target relation | versioned relation-aware calls require 9E/9F |
| `app/admin/check-in/page.tsx` | browser employee/admin | target user/action; user JWT | reservation-derived tenant and target relation | yes, pass trusted reservation to a versioned RPC |
| `app/account/page.tsx` | browser owner | self fields; user JWT | `auth.uid()` | no |
| account export/delete routes | server route using user-scoped Supabase client | no target user; bearer JWT | `auth.uid()` account-wide | no; Auth Admin deletion remains server-only |
| `app/booking/page.tsx` | public/browser | no args | sole active tenant now; host/slug in 9E | no now; yes in 9E |
| homepage/admin/calendar-feed callers | browser/server user session | `get_my_role()` | selected tenant membership | 9E dependency; do not break in 9D-4 |

### 38.11 Concurrency and idempotency plan

- Role change: transaction/advisory lock by tenant then target membership;
  concurrent last-admin demotions yield one valid outcome, never zero active
  admins and never cross-tenant profile synchronization.
- Profile mutations: lock target relation then profile in stable UUID order;
  no-change returns without audit; concurrent different-tenant attempts cannot
  affect the target or write audit.
- Account anonymization: preserve existing profile lock and idempotent marker;
  concurrent retries create one anonymization and one global audit. Export
  during deletion returns either a coherent pre-delete snapshot or controlled
  unavailable result, never a mixed cross-user export.
- Reports are STABLE/read-only and must share one transaction snapshot; KPI,
  detail and export tenant scope cannot diverge under concurrent writes.
- Required result for all stress matrices: deadlocks `0`, unintended duplicate
  effects `0`, cross-tenant effects/rows `0`, orphan fixture `0`.

### 38.12 Minimum cross-tenant matrix

| Actor / attempt | Required result |
|---|---|
| ADMIN_A report/resource A | ALLOW; only Tenant A rows/KPI/CSV |
| ADMIN_A report/resource B | DENY before any Tenant B data |
| EMPLOYEE_A report | DENY under current admin-only report contract |
| ADMIN_A related profile A | ALLOW per exact function role |
| ADMIN_A unrelated or Tenant B profile | DENY; zero PII/audit |
| EMPLOYEE_A related customer contact/verification | ALLOW only current operation |
| EMPLOYEE_A admin/staff/self/unrelated/Tenant B target | DENY |
| global profile admin without active target membership | DENY every privileged function |
| pending/suspended/no membership | DENY every privileged function |
| USER_A own self update/export/anonymization | ALLOW per contract |
| USER_A foreign user/resource or spoofed tenant | DENY |
| Tenant A audit reader | no Tenant B or global lifecycle audit |
| anon | public booking config only; no reports/profile/account PII |
| service_role direct profile/report mutation | DENY unless an exact retained server contract is proved |

Tests also freeze DTO field names, status/error codes, report pagination and
CSV behavior, owner lifecycle idempotency, audit actor/time/content, trigger
fingerprints, direct table DML denials and global-role negative cases.

### 38.13 Compatibility defaults

All seven fixed-CSK defaults remain during 9D-4. They are compatibility only,
not authorization or tenant derivation.

| Table | Default | Current tenant-aware writers | Legacy writers / residual | Removal blocker | Target removal |
|---|---|---|---|---|---|
| `reservations` | fixed CSK UUID | active reservation v2 explicitly derives lane tenant | closed legacy v1/default dependency | final writer/caller inventory | 9D-5 after 9E/9F gate |
| `shooting_lanes` | fixed CSK UUID | hardened lane-family create explicitly resolves tenant | dormant/legacy creation paths | selected-tenant app context | 9D-5 after 9E/9F |
| `lane_blocks` | fixed CSK UUID | hardened block writers derive lane tenant | no active browser fallback | production zero-caller proof | 9D-5 |
| `events` | fixed CSK UUID | hardened event create/update resolve tenant | retained legacy service functions | app selected-tenant cutover | 9D-5 after 9E/9F |
| `event_lanes` | fixed CSK UUID | event writers copy verified event tenant | retained legacy event paths | same as events | 9D-5 after 9E/9F |
| `event_registrations` | fixed CSK UUID | register/promotion writers derive event tenant | legacy compatibility paths | complete writer inventory | 9D-5 after 9E/9F |
| `email_deliveries` | fixed CSK UUID | hardened prepare/complete flows bind record tenant | historical/legacy delivery paths | all delivery writers explicit | 9D-5 after 9E/9F |

### 38.14 Proposed sub-phases

1. **9D-4A — reservation reports.** Harden v2/export plus closed report core;
   ACL-close v1. No application change under the active-single bridge.
2. **9D-4B-1 — tenant admin user list and role/note/identity/contact.** Starts
   only after the operational-relationship rule is approved. Preserve current
   admin/employee division and make audits tenant-bound.
3. **9D-4B-2 — verification/check-in relation.** Add resource-bound versioned
   verification, update the check-in caller in the later approved app cutover,
   then close the target-user-only unsafe path.
4. **9D-4C — owner lifecycle.** Starts only after account-wide deletion/export
   semantics are approved; preserve self-only and idempotency.
5. **9D-4E — public booking compatibility.** Bind v1 output to exactly one
   active tenant without changing its DTO; selected host/slug contract remains
   9E.
6. **9D-4D/9E gate — legacy authorization and onboarding.** Do not implement in
   DB-only 9D-4. Replace app callers/onboarding first, then retire in 9D-5.

Each executable sub-phase needs a separate migration, normalized fingerprint
preflight, focused pgTAP/cross-tenant/concurrency tests, full DB/Node/TypeScript/
build regression, production dry-run, explicit production approval, rollback-
only production matrix, postflight and Git checkpoint.

### 38.15 9D-5 entry criteria

Before 9D-5:

- every active writer explicitly sets or derives tenant and no security decision
  relies on a CSK default;
- reports and user/profile paths have zero global-role authorization and zero
  cross-tenant PII/audit leakage;
- account lifecycle semantics are approved and production-proved;
- app and DB callers of `get_my_role`, `is_admin*`, legacy report v1 and legacy
  service grants are inventoried with zero unknown caller;
- onboarding and role management have a tenant-aware replacement ready in 9E;
- all remaining SECURITY DEFINER functions have exact owner/path/ACL/fingerprint
  and retain/convert/retire disposition; UNKNOWN remains zero;
- default-removal preflight proves all seven active and internal writer paths
  explicitly supply tenant;
- final cross-tenant RPC isolation audit can run without activating Tenant B in
  production.

### 38.16 Rollback and STOP conditions

Rollback uses a reviewed forward migration restoring only captured function
bodies, modes, owners, paths and ACL. Never edit applied migrations or use
migration repair. Versioned functions are additive until caller cutover; old
wrappers are not removed in the same deployment. Restoring a global-role body
is allowed only as an emergency single-active-CSK rollback while Tenant B is
still blocked, followed by immediate forward correction.

STOP on any unexpected overload/caller/fingerprint, non-SP1 touched definer,
wider grant, ambiguous user-tenant relation, account-lifecycle decision absent,
zero/multiple active tenants for a compatibility wrapper, resource/tenant
mismatch, global-admin allow without membership, cross-tenant row/PII/audit,
duplicate audit, last-admin race, nonzero fixture, unexpected SECURITY DEFINER
count, changed default, additional pending migration or runtime contract drift.

### 38.17 SEC-004 impact and decisions required

9D-4 will close the current global report, profile administration, account
lifecycle and public booking privileged-function gaps for the single-active
tenant bridge. It will not close SEC-004.

Still required afterward:

- **9D-5:** legacy ACL/function retirement, exact final definer audit and seven
  default retirement after all cutover gates;
- **9E:** trusted host/slug/selected-tenant application context, tenant role
  routing, onboarding and removal of app dependence on `profiles.role`;
- **9F:** Reports/Events/Calendar/Check-in and remaining UI/API context cutover;
- **9G:** full cross-tenant application IDOR/concurrency suite;
- **9H:** SEC-004 closure and second-tenant readiness audit.

Blocking decisions before a complete local 9D-4 implementation:

1. approve or revise the proposed operational user relationship (membership OR
   tenant reservation OR tenant event registration), including which employee
   profile fields/actions it permits;
2. approve account-wide export/anonymization/Auth deletion semantics, distinct
   from a future tenant-leave operation.

The plan is technically complete, but implementation of the entire 9D-4 scope
is not authorized and is not safe until those two decisions are recorded.
9D-4A and 9D-4E are independently implementable after a separate explicit
approval; they do not resolve the 9D-4B/4C blockers.

SAAS-9D-4 TECHNICAL PLAN: **READY**

READY FOR SAAS-9D-4 LOCAL IMPLEMENTATION: **NO-GO**

READY FOR PRODUCTION WRITE: **NO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## 36. SAAS-9D-3C — LANE FAMILY WRITER / HELPERS FINAL PLAN

Planning baseline: repository checkpoint
`0dfd03c5dd1013d1726160d0b13d7bcbe02e7bf4` and the production state after
SAAS-9D-3B CLOSED / PROD PASS. Production has `70` public SECURITY DEFINER
functions, all `7/7` temporary CSK compatibility defaults, exactly one active
tenant and no enabled second-tenant runtime. This section is planning only. It
does not authorize a migration, SQL write, application change or deployment.

### 36.1 Exact scope and evidence boundary

After the completed 9D-3A and 9D-3B slices, exactly seven functions remain
from the frozen 13-function 9D-3 inventory. No function from 9D-4, 9D-5 or 9E
is moved into 3C, and UNKNOWN is `0`.

ACL values below are `PUBLIC / anon / authenticated / service_role`; `D` means
no EXECUTE and `A` means EXECUTE. All seven functions are currently owned by
`postgres` and use the approved SP1 `search_path=pg_catalog, public, pg_temp`.

| FUNCTION | SIGNATURE | CALLERS | SECURITY DEFINER? | OWNER | SEARCH_PATH | ACL | GLOBAL ROLE CHECK? | LANE/FAMILY ARG? | RESOURCE ARG? | TENANT SOURCE | SERVICE_ROLE PATH? | RLS BYPASS? | CROSS-TENANT RISK? | SEVERITY | CLASS |
|---|---|---|---:|---|---|---|---:|---|---|---|---:|---:|---|---|---|
| `admin_set_lane_booking_family_configuration_v2` | `(uuid,bigint,jsonb,boolean) -> jsonb` | `app/admin/lane-configuration/page.tsx`; DB tests; calls normalize and snapshot helpers | yes | `postgres` | SP1 | D/D/A/D | yes, global `profiles.role=admin` | root lane plus complete family payload | root UUID and resource UUIDs in JSON | target: locked root `shooting_lanes.tenant_id`; every resource must match | no | yes | current definer can authorize globally and mutate a foreign root/family, rules, durations, pricing and audit | CRITICAL | A — BODY HARDENING |
| `admin_set_lane_booking_configuration` | `(uuid,boolean,boolean,boolean,integer,boolean,integer,integer[],jsonb) -> jsonb` | no application or active SQL caller; legacy/concurrency tests only | yes | `postgres` | SP1 | D/D/D/D | yes, global `profiles.role=admin` | one lane | lane UUID | lane if ever called; no supported runtime path | no | yes | latent foreign-lane writer if its closed ACL is widened | HIGH / dormant | C — SECURITY INVOKER CANDIDATE |
| `lane_booking_family_business_snapshot_v2` | `(uuid) -> jsonb` | SQL-only from the family V2 writer | yes | `postgres` | SP1 | D/D/D/D | no | root lane | root UUID | hardened outer writer's locked root and validated family | no | yes | internal cross-tenant read only if called without the outer binding or a grant is widened | LOW / internal | C — SECURITY INVOKER CANDIDATE |
| `normalize_lane_booking_family_payload_v2` | `(jsonb) -> jsonb` | SQL-only from the family V2 writer | yes | `postgres` | SP1 | D/D/D/D | no | payload includes lane UUIDs but performs no table access | JSON family payload | none; pure immutable normalization, result must be bound by outer writer | no | technically yes, but no table access | no independent data path; risk is only misuse of its result by a caller | LOW / internal | C — SECURITY INVOKER CANDIDATE |
| `validate_lane_booking_rule_capacity` | `() -> trigger` | `validate_lane_booking_rule_capacity_trigger` only | yes | `postgres` | SP1 | D/D/D/D | no | `NEW.lane_id` | affected rule row | lane reached from `NEW.lane_id`; statement writer supplies row tenant context | no direct RPC | yes, trigger-bound | no client authorization surface; protects capacity integrity | SAFE | D — SAFE / NO CHANGE |
| `validate_shooting_lane_capacity_change` | `() -> trigger` | `validate_shooting_lane_capacity_change_trigger` only | yes | `postgres` | SP1 | D/D/D/D | no | `OLD/NEW` lane | affected lane row | affected lane and its booking rule | no direct RPC | yes, trigger-bound | no client authorization surface; protects physical/online capacity consistency | SAFE | D — SAFE / NO CHANGE |
| `validate_shooting_lane_hierarchy` | `() -> trigger` | `validate_shooting_lane_hierarchy_trigger` only | yes | `postgres` | SP1 | D/D/D/D | no | `OLD/NEW.parent_lane_id` | affected lane and proposed parent | row tenant plus composite tenant/parent FK | no direct RPC | yes, trigger-bound | no client authorization surface; protects parent/child shape | SAFE | D — SAFE / NO CHANGE |

Current normalized production fingerprints carried from the frozen catalog are:

| Signature | Current fingerprint |
|---|---|
| `admin_set_lane_booking_configuration(uuid,boolean,boolean,boolean,integer,boolean,integer,integer[],jsonb)` | `c60876406d007491187869017df989b5` |
| `admin_set_lane_booking_family_configuration_v2(uuid,bigint,jsonb,boolean)` | `00fc387949410273a7cb33589cd8d1c6` |
| `lane_booking_family_business_snapshot_v2(uuid)` | `bc891bbdfab6d033fed72ece1c9fc193` |
| `normalize_lane_booking_family_payload_v2(jsonb)` | `77eee4f69abb6bdf74f1529f8e21589a` |
| `validate_lane_booking_rule_capacity()` | `78a6c1beb5048645a46d20d735324e2a` |
| `validate_shooting_lane_capacity_change()` | `96e0199a327831f40bec66c57d37f5ca` |
| `validate_shooting_lane_hierarchy()` | `dd3c97078341a74edc83ca79e9b19c0f` |

Local implementation must first re-read the actual catalog and fail closed on
any overload, fingerprint, owner, path, ACL, caller or trigger dependency drift.

### 36.2 Classification result

**A. BODY HARDENING**

- `admin_set_lane_booking_family_configuration_v2` is the only body rewrite.
  Its signature, JSON response, stable business codes, optimistic concurrency,
  future-obligation acknowledgement, pricing/duration semantics and UI caller
  contract remain unchanged.

**B. ACL-ONLY**

- none. The three dormant/internal functions already have closed ACLs. The
  active V2 writer retains authenticated-only EXECUTE.

**C. SECURITY INVOKER CANDIDATE**

- `admin_set_lane_booking_configuration`;
- `lane_booking_family_business_snapshot_v2`;
- `normalize_lane_booking_family_payload_v2`.

Their bodies, signatures, owner, search path, volatility and closed ACLs remain
unchanged. Only SECURITY DEFINER is removed. The two helpers then execute with
the already-authorized effective context of the outer writer; neither becomes
a new public, authenticated or service entry point.

**D. SAFE / NO CHANGE**

- `validate_lane_booking_rule_capacity`;
- `validate_shooting_lane_capacity_change`;
- `validate_shooting_lane_hierarchy`.

They stay postgres-owned SP1 SECURITY DEFINER trigger functions with no direct
client/service EXECUTE. Their exact fingerprints and trigger bindings become
negative drift guards.

**E. APP-CUTOVER DEPENDENCY**

- none inside the seven-function 3C change set. The active writer already has
  a trusted root resource from which tenant is derived, so it does not need a
  selected-tenant application parameter. The page's legacy `get_my_role`
  presentation gate remains non-authoritative and is removed only with the
  broader 9D-4D/9E application authorization cutover.

### 36.3 Target writer authorization and tenant binding

`admin_set_lane_booking_family_configuration_v2` must perform the following
sequence before any mutable family/configuration work:

1. require `auth.uid()`;
2. validate scalar inputs and normalize the payload without accepting a
   `tenant_id`, parent override or any other authority field;
3. load and lock `p_root_lane_id`, require a top-level `resource_kind='lane'`,
   and derive the sole authority tenant from `shooting_lanes.tenant_id`;
4. call `get_my_tenant_role_v1(derived_tenant_id)` and require exactly active
   membership role `admin`; global `profiles.role`, browser state and the seven
   CSK defaults are never authorization;
5. lock the conflict family and version in deterministic order, then verify
   that the root, every current child, every payload lane ID and the family
   version resolve to that same tenant and exact family;
6. reject missing, foreign, duplicate, sibling, reparented or mixed-tenant
   resources before writes; the payload's resource-ID set must equal the
   locked current family-ID set;
7. execute every rule, duration and pricing read/write only through the
   already validated same-tenant family lane IDs;
8. add the derived tenant predicate to future reservations, lane blocks,
   events and event-lane obligation/conflict reads, including equality on both
   sides of tenant-owned joins;
9. constrain `shooting_lanes` updates by both resource ID and derived tenant;
   nested lane-owned rows remain bound through the prevalidated lane set;
10. write `audit_logs.tenant_id=derived_tenant_id`; actor identity and display
    fields may still come from the actor profile, but `profiles.role` cannot
    decide authorization and the audit actor role is the tenant role;
11. preserve the existing `no_change`, `stale_configuration`, confirmation,
    conflict and successful version-increment contracts with exactly one audit
    only for a real successful mutation.

Admin A plus Family A is allowed. Admin A plus Family B is denied. Employee,
instructor and ordinary-user membership do not gain configuration-write scope.
A global legacy admin without an active membership in the resource tenant,
pending membership, suspended membership and no membership are denied.

### 36.4 Hierarchy, spoofing and helper boundaries

The active family editor does not support arbitrary reparenting or adding and
removing resource identities. 3C must preserve that contract rather than add a
new hierarchy API.

- Parent A + Child B: DENY before mutation;
- Family A + Lane B in the JSON set: DENY atomically;
- root A plus sibling from another family in A: DENY;
- `tenant_id`, `parent_lane_id`, `root_lane_id` or unexpected authority keys in
  payload: DENY through the unchanged exact-key normalizer contract;
- root/child tenant equality remains protected finally by the existing
  composite FK and hierarchy trigger, but the writer must fail earlier with a
  controlled result;
- the snapshot helper receives only the already authorized and locked root;
- the normalizer remains pure and cannot establish tenant authority;
- direct helper EXECUTE stays denied to PUBLIC, anon, authenticated and
  service_role.

There is no active move/reparent RPC in 3C. `admin_update_lane_block` is a block
move contract already completed in 3A and must not be modified again.

### 36.5 Configuration, pricing and obligation compatibility

The tenant boundary is added without changing product semantics:

- `shooting_lanes` is tenant-owned;
- `lane_booking_rules`, `lane_booking_durations` and `lane_pricing_rules` are
  lane-owned and receive no new tenant column in 3C;
- `lane_booking_family_configuration_versions` is root-lane-owned;
- duration validation, booking-step divisibility, max-shooter and online-limit
  checks, weekday/weekend pricing coverage, canonical ordering and retained
  inactive historical pricing rows stay unchanged;
- current/future reservation, block and event obligations retain the existing
  Europe/Warsaw and acknowledgement behavior but are constrained to the
  derived tenant;
- name-only updates, unchanged payloads and stale expected versions retain the
  current version/audit behavior;
- no public booking/configuration DTO or application payload changes.

All `7/7` CSK compatibility defaults remain present. None is consulted as an
authorization source. Their removal stays gated on 9D-5 after tenant-aware
writers and 9E selected-tenant routing are proven and before Tenant B.

### 36.6 ACL, owner, path and SECURITY DEFINER target

| Function group | Target SECURITY mode | Target ACL | Owner/path |
|---|---|---|---|
| active family V2 writer | DEFINER | D/D/A/D | `postgres`, SP1 |
| legacy single-lane writer | INVOKER | D/D/D/D | `postgres`, SP1 |
| snapshot and normalize helpers | INVOKER | D/D/D/D | `postgres`, SP1 |
| three integrity triggers | DEFINER, unchanged | D/D/D/D | `postgres`, SP1 |

No service_role caller exists for this domain and 3C grants no service_role
EXECUTE. No PUBLIC/anon grant, table ACL or RLS policy changes. The production
SECURITY DEFINER count must change from `70` to exactly `67`; the only mode
changes are the three approved INVOKER conversions. Unexpected drift is `0`.

### 36.7 Concurrency and atomicity plan

The writer must keep one transaction and deterministic lock order. Focused
concurrency coverage must prove:

1. two updates with the same expected version produce exactly one update and
   one `stale_configuration`, one version increment and one audit;
2. Tenant A and Tenant B family updates in parallel never read, lock or mutate
   the other tenant's rows;
3. a mixed Family A + Lane B request racing a legitimate Tenant B update is
   denied without partial mutation;
4. family update versus reservation creation, lane-block creation/toggle and
   event lane assignment preserves the current conflict/obligation contract;
5. pricing/duration replacement racing another family update leaves one
   canonical active snapshot and no broken historical references;
6. name-only update and no-change retry do not create duplicate audit effects;
7. membership transition to pending/suspended before authorization fails
   closed; an already authorized transaction remains bound to the locked
   resource tenant and cannot switch tenant through payload data;
8. no deadlock, orphan row, mixed hierarchy, partial family/configuration,
   duplicate version effect or cross-tenant audit survives.

### 36.8 Proposed implementation files and order

No file is created during planning. The expected local implementation scope is:

- one new forward migration, proposed
  `supabase/migrations/20260917100000_harden_lane_family_writer_helpers.sql`;
- one focused transactional SQL matrix with normalized CRLF/CR-to-LF
  fingerprint guards;
- one deterministic PowerShell concurrency harness;
- updates only to existing ACL/phase inventory tests whose expected mode/count
  genuinely changes;
- this plan and a future
  `SAAS_9D_3C_LANE_FAMILY_WRITER_HELPERS_HARDENING_REPORT.md`.

Implementation order:

1. freeze production definitions, signatures, dependencies, triggers, ACL,
   owner, search path and normalized fingerprints;
2. fail closed on tenant/hierarchy/config/version orphan or mismatch data;
3. rewrite only the active family V2 writer with resource-derived membership
   authorization and tenant-bound predicates/audit;
4. convert exactly the legacy writer and two helpers to INVOKER while retaining
   closed ACLs;
5. assert the three trigger definitions and bindings are byte-semantically
   unchanged after normalized line endings;
6. run focused role/IDOR/hierarchy/configuration/concurrency suites, then full
   regression;
7. prepare a separate read-only production preflight. Production push requires
   a new explicit approval and exactly one pending approved migration.

One cohesive 3C migration is preferable to 3C-1/3C-2: only one active writer
body changes, its two direct helpers change mode, and the legacy writer's mode
is reduced. Splitting the outer writer from the helper mode changes would add a
temporary mixed security model without reducing rollout risk. If preflight
finds caller or fingerprint drift, stop and reconsider the split rather than
expanding scope.

### 36.9 Test and regression plan

Focused SQL must cover the exact metadata and role matrix plus:

- Admin A + Family A ALLOW; Admin A + Family B DENY;
- Employee A, instructor A and ordinary user A DENY configuration writes;
- global `profiles.role=admin` without matching active membership DENY;
- pending, suspended and no-membership DENY;
- Parent A + Child B, Family A + Lane B, sibling injection and tenant spoof
  DENY with zero partial changes;
- exact payload resource set, root/child identity immutability and hierarchy
  constraints;
- optimistic version, stale, no-change, name-only and future-obligation
  acknowledgement behavior;
- rules/durations/pricing canonical replacement and historical price retention;
- tenant-scoped audit actor, target, before/after content and idempotency;
- helper direct EXECUTE denied for all client/service roles;
- trigger capacity/hierarchy behavior unchanged;
- `7/7` defaults unchanged and SECURITY DEFINER count exactly `67`.

Regression order:

1. focused 3C SQL and cross-tenant/IDOR matrix;
2. focused configuration and pricing suites;
3. deterministic concurrency harness;
4. 9D-3A lane-block and 9D-3B creation/reader suites;
5. booking, reservations, public booking, Events, Calendar, Reports, check-in,
   email and account/auth DB contracts;
6. full Supabase DB suite;
7. all Node tests, TypeScript, production build and focused lane-configuration
   Playwright;
8. changed-files ESLint, `npm audit --omit=dev`, `git diff --check` and exact
   fixture cleanup `0`.

No heavy production stress test is planned. Production verification, if later
approved, uses a rollback-only synthetic matrix and bounded runtime smoke.

### 36.10 Compatibility and rollout

Signatures, active writer ACL, UI payload and response DTO remain stable:

| Combination | Expected result |
|---|---|
| OLD APP + OLD DB | current single-tenant behavior; known global-role risk remains |
| OLD APP + NEW DB | compatible; same RPC name/payload/response, membership becomes authority |
| NEW APP + OLD DB | not applicable; 3C requires no application change |
| NEW APP + NEW DB | target state; identical UI contract with tenant-bound DB authorization |

Deployment model is **DB ONLY**, after local PASS, read-only production
preflight, exact SHA/fingerprint/history checks and separate production-write
approval. No app-first cutover is required.

### 36.11 Rollback and STOP conditions

Rollback is a reviewed forward migration restoring only the four changed
definitions/security modes/ACLs. Never edit an applied migration, run migration
repair or use ad-hoc production SQL as deployment. Restoring the old active
writer would reopen the global-role/cross-tenant defect, so prefer forward-fix
while Tenant B remains blocked.

STOP on any unknown/overloaded function, unexpected caller, fingerprint/owner/
path/ACL drift, nonzero orphan or tenant/hierarchy/config mismatch, changed
signature/DTO/business code, global-role-only allow, employee/instructor scope
expansion, foreign family/resource access, tenant spoof acceptance, non-atomic
write, changed trigger behavior, unexpected audit target/PII, concurrency
failure, SECURITY DEFINER count other than `67`, non-target function drift,
changed compatibility default, additional pending migration or nonzero fixture.

### 36.12 Work deliberately remaining after 3C

**9D-4 remains:**

- 4A tenant-context reservation reports and export;
- 4B tenant-related user/profile administration;
- 4C owner account export/update/anonymization lifecycle review;
- 4D retirement of authorization dependence on global `get_my_role`,
  `is_admin*`, profile privilege guards and related legacy auth paths after
  callers are ready;
- 4E public selected-tenant contract preparation for 9E.

**9D-5 remains:**

- zero-caller legacy RPC retirement and final grant cleanup;
- removal of all seven CSK defaults only after every writer gate passes;
- CSK profile/membership sync-bridge retirement at the 9E reconciliation gate;
- final SECURITY DEFINER and compatibility inventory.

**SAFE / NO CHANGE remains:** the three lane/config integrity triggers in this
section and every unrelated safe helper from the authoritative inventory.

**9E dependency remains:** trusted selected-tenant application context,
routing, replacement of exact-active bridge contracts and removal of global
role presentation/authorization assumptions before Tenant B. 3C neither starts
9E nor makes a second tenant safe.

### 36.13 Final planning gate

The actual repository supplies an exact seven-function boundary, one active
application caller, no service path, stable signatures, deterministic tenant
derivation from the root and no unresolved product decision. UNKNOWN: **0**.
The slice is appropriately sized as one local implementation phase.

SAAS-9D-3C TECHNICAL PLAN: **READY**

READY FOR SAAS-9D-3C LOCAL IMPLEMENTATION: **GO**

READY FOR PRODUCTION WRITE: **NO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## 34. SAAS-9D-3B — LANE FAMILY CREATION / READERS FINAL PLAN

Planning baseline: checkpoint `e3cf1103eb943b274d66770d514ac55b59549068`,
SAAS-9D-3A CLOSED / PROD PASS, production SECURITY DEFINER count `70`, and
compatibility defaults `7/7`. This is a technical plan only. It does not
authorize a migration, SQL write, application change, deployment, commit or
push.

### 34.1 Exact scope

9D-3B contains exactly these three existing functions:

1. `admin_create_lane_booking_family_v1(jsonb)`;
2. `admin_get_lane_booking_configuration_v1()`;
3. `admin_get_lane_booking_configuration_v2()`.

It must not include the 9D-3C family writer or its helpers:
`admin_set_lane_booking_family_configuration_v2`,
`admin_set_lane_booking_configuration`,
`lane_booking_family_business_snapshot_v2`, or
`normalize_lane_booking_family_payload_v2`. Lane-block RPCs are already closed
in 9D-3A. Trigger functions, public booking readers, reservation RPCs, 9D-4,
9D-5 and 9E are also excluded.

The proposed future migration is one narrowly scoped, forward-only migration,
provisionally `20260916100000_harden_lane_family_creation_readers.sql`, plus a
focused SQL test and a deterministic concurrency harness. No file is created
during this planning task.

### 34.2 Function classification and current inventory

ACL values are `PUBLIC / anon / authenticated / service_role`; `D` means no
EXECUTE and `A` means EXECUTE.

| Function | Signature | Current mode | Owner / path | Current ACL | Global role check | Resource/root arg | Current tenant source | Path | RLS bypass / risk | Severity | 3B disposition |
|---|---|---|---|---|---|---|---|---|---|---|---|
| `admin_create_lane_booking_family_v1` | `(jsonb)` | SECURITY DEFINER, VOLATILE | postgres / SP1 | D/D/A/D | yes, `profiles.role=admin` | no | implicit CSK column default | staff writer | yes; can create a global family and audit under elevated rights | CRITICAL | body hardening |
| `admin_get_lane_booking_configuration_v1` | `()` | SECURITY DEFINER, STABLE | postgres / SP1 | D/D/A/D | yes, global admin | no | none; global snapshot | internal/admin reader | yes; returns all lane configuration | HIGH | body hardening plus authenticated ACL revoke |
| `admin_get_lane_booking_configuration_v2` | `()` | SECURITY DEFINER, STABLE | postgres / SP1 | D/D/A/D | yes, global admin | no | none; global V1 result and global versions | admin runtime reader | yes; groups all families | HIGH | body hardening |

SP1 is exactly `search_path=pg_catalog, public, pg_temp`. The three current
normalized production fingerprints, guarded after CRLF and CR normalization to
LF, are respectively:

- creator: `69ec76ae348f83387045a5c343dd906f`;
- V1 reader: `2684f7ea8a3b9eba6dae4d4f7aad653c`;
- V2 reader: `5c729f01536d476a5c8b3cf0d9b40c62`.

Preflight must additionally freeze signatures, volatility, SECURITY mode,
owner, path, ACL, overload count, dependency objects, all seven defaults,
non-target SECURITY DEFINER fingerprints and the absence of tenant/hierarchy
orphans. Any difference is a STOP condition.

### 34.3 Caller inventory and compatibility

| File/caller | Caller type | RPC | Arguments | Auth context | Tenant context | Resource context | App change required? |
|---|---|---|---|---|---|---|---|
| `app/admin/lane-configuration/page.tsx` | browser Supabase client | `admin_get_lane_booking_configuration_v2` | none | authenticated browser JWT; UI also performs legacy presentation gating | none; exact-active bridge is required | none | no |
| same file | browser Supabase client | `admin_create_lane_booking_family_v1` | `{p_family: payload}` | authenticated browser JWT | none; exact-active bridge is required | no pre-existing root; IDs are server-generated | no |
| `admin_get_lane_booking_configuration_v2()` | SQL-to-SQL internal call | `admin_get_lane_booking_configuration_v1` | none | original `auth.uid()` remains visible inside the definer chain | same exact-active tenant | V1 supplies the resource snapshot | no |
| `tests/e2e/lane-family-creation.spec.ts` | local E2E/contract test | creator | existing JSON payload | admin/user/anon test JWTs | bridge | generated family | test expectations updated for membership, not payload/DTO |
| existing SQL/ACL/family tests | DB regression callers | all three | unchanged | simulated JWT or owner test setup | controlled Tenant A/B fixture | controlled lanes/config | tests only |

There is no TypeScript runtime caller of V1. Direct authenticated V1 execution
is therefore removed; V2 can still call it under its postgres-owned definer
context. The creator signature, exact accepted JSON shape, generated IDs,
response keys/codes and atomic business behavior remain unchanged. The V2
signature and DTO remain unchanged. No caller may supply `tenant_id`.

### 34.4 Tenant derivation

All three RPCs are contextless: creation has no existing root and both readers
have no resource argument. Until 9E they must use only
`active_single_tenant_id_v1()`:

- exactly one active tenant: resolve that tenant;
- zero active tenants: helper returns NULL and the RPC fails closed;
- more than one active tenant: helper returns NULL and the RPC fails closed;
- there is no `ORDER BY`, `LIMIT 1`, CSK constant, payload tenant, browser
  state, global profile role or default-based fallback.

The wrapper must stabilize tenant status for the transaction using the same
reviewed tenant-row lock order as prior hardened create contracts, then resolve
the bridge. The bridge and every 3B contract are marked **TEMPORARY UNTIL 9E**.
They do not constitute selected-tenant routing and cannot enable Tenant B.

### 34.5 Family creation

The hardened creator must preserve all current validation and transaction
semantics, then:

1. resolve exactly one active tenant and require
   `get_my_tenant_role_v1(tenant_id) = 'admin'`;
2. reject global admin without active membership and all pending, suspended,
   missing, employee, instructor and ordinary-user memberships;
3. keep the exact payload allowlist so a supplied `tenant_id`, root ID,
   parent ID or other unknown authority field is rejected;
4. explicitly insert the resolved `tenant_id` into the root and every child
   `shooting_lanes` row;
5. scope `max(display_order)` and every duplicate/validation lookup to that
   tenant while retaining the existing serialization lock;
6. create rules, durations, pricing and the family-version row only through
   the newly generated same-tenant lane/root IDs;
7. explicitly set `audit_logs.tenant_id` to the resolved tenant;
8. preserve one atomic transaction: any failure leaves zero root, child,
   rule, duration, pricing, version and audit rows.

The creator does not create or reparent children outside its new family. Its
server-generated root and child IDs prevent caller-selected cross-tenant
targets. The CSK default may remain present but must no longer be consumed by
this writer.

### 34.6 Hierarchy consistency

The database already enforces
`child.(tenant_id,parent_lane_id) -> parent.(tenant_id,id)` with the composite
FK and the hierarchy trigger. 3B adds controlled pre-insert consistency and
postflight assertions; it does not weaken or replace those constraints.

Required outcomes:

- Root A + Child A: ALLOW when all current family validation passes;
- Root A + Child B and Parent A + Child B: DENY atomically;
- caller-selected reparent/move: impossible in creator and DENY in later 3C;
- every generated child has the same tenant as its generated root;
- the version row resolves to a top-level root in that tenant;
- rule, duration and pricing rows resolve only through same-family lanes;
- no orphan child, mixed-tenant family or partial configuration can survive.

### 34.7 Reader design

These two readers are staff/admin configuration readers. They are not public
or ordinary booking readers.

**V1 internal reader:** resolve the exact active tenant, require active admin
membership from `auth.uid()`, and tenant-scope every structural check and base
lane query. Parent joins must include tenant equality. Missing-rule,
duplicate-duration and overlapping-pricing checks must only inspect lanes of
the resolved tenant. Preserve the V1 JSON schema and ordering.

**V2 runtime reader:** independently resolve/stabilize the same bridge and
require active admin membership. Scope root/version cardinality and family
aggregation to that tenant. Call the hardened V1 reader internally and include
only resources and versions from the resolved tenant. Preserve the V2 JSON
schema, family ordering, configuration versions and error contract.

Reader A must return zero family/resource/version rows from Tenant B. Foreign
bad configuration must not make Tenant A's reader fail, and Tenant A defects
must not expose Tenant B details in errors.

### 34.8 Staff authorization

The authoritative privileged check is:

`auth.uid() + exact active tenant + active tenant_memberships row + role admin`.

The UI's legacy `get_my_role` check may remain for presentation during this
phase, but it has no authority in these RPCs. `profiles.role=admin` without an
active matching membership is DENY. Employee, instructor and user remain DENY
for family creation and admin configuration reads. Pending, suspended and no
membership are DENY. Instructor scope is unchanged.

### 34.9 Public and booking contract

The public reader `get_public_booking_configuration_v1()` and authenticated
reservation/busy-range contracts are outside 3B and remain unchanged. 3B must
not add a membership requirement or grant to legal public/user booking paths,
and must not change their DTOs.

Regression must prove unchanged lane list, family labels, hierarchy ordering,
availability, active/inactive and online visibility, whole-axis versus position
semantics, pricing, duration and capacity behavior. Public/user responses must
not gain internal admin configuration, family version, membership data or
cross-tenant lanes. Selected-tenant public routing remains a 9E dependency.

### 34.10 Target ACL, owner, path and modes

| Function | Target mode | Owner | Search path | PUBLIC | anon | authenticated | service_role |
|---|---|---|---|---:|---:|---:|---:|
| creator | SECURITY DEFINER, VOLATILE | postgres | SP1 | DENY | DENY | EXECUTE | DENY |
| V1 reader | SECURITY DEFINER, STABLE | postgres | SP1 | DENY | DENY | DENY | DENY |
| V2 reader | SECURITY DEFINER, STABLE | postgres | SP1 | DENY | DENY | EXECUTE | DENY |

Definer mode remains necessary because protected table ACL/RLS cannot supply
these bounded admin read/write contracts directly. Internal V1 remains a
definer only so the authorized V2 wrapper can use its protected snapshot; its
client/service surface is removed. No PUBLIC, anon or service grant is added.
ACL-only revocation for V1 must be separately guarded to prove its body,
signature, mode, owner and path did not drift.

### 34.11 Concurrency plan

Focused deterministic tests must cover:

1. two concurrent family creates: serialized display ordering, unique IDs and
   two complete families, with no partial rows or deadlock;
2. duplicate-name/child validation race according to the existing business
   contract, with deterministic controlled results;
3. creator versus reader: each reader sees one complete MVCC state, never a
   partially inserted family;
4. root/child assignment and mixed-tenant fixture race: composite FK and
   transaction checks leave zero cross-tenant hierarchy;
5. tenant-status cutover racing creator/reader: the tenant-row lock plus exact
   bridge gives one stable tenant or a fail-closed result;
6. attempted second-active tenant during creation: database guard/bridge
   prevents selection and leaves zero Tenant-B family rows;
7. concurrent Tenant-A caller and Tenant-B-only member: A may act in A; B has
   no selectable tenant context and is denied rather than redirected into A;
8. creator versus reservations, blocks and event-lane reads: no regression in
   existing conflict or hierarchy semantics.

Positive simultaneous A and B creation cannot be a supported 3B scenario,
because the second-active-tenant guard and lack of selected tenant context make
Tenant B intentionally unreachable. It is deferred to 9E/9G; the 3B proof is
the negative invariant: deadlocks `0`, cross-tenant hierarchy `0`, Tenant-B
writes `0`, partial families `0`, duplicate version/audit effects `0`, fixture
`0`.

### 34.12 Cross-tenant matrix

| Scenario | Expected |
|---|---|
| active Admin A + exact active Tenant A | creator/read V2 ALLOW |
| Admin A + Root/Child B payload attempt | DENY; tenant fields/IDs are not accepted |
| active Employee A + Tenant A | DENY for all three 3B contracts |
| active Instructor/User A | DENY |
| global admin without active membership A | DENY |
| pending/suspended/no membership | DENY |
| Admin membership B while A is the only active tenant | DENY, never create/read as A |
| Parent A + Child B | DENY by controlled logic and composite FK |
| Reader A with valid Tenant-B family present | zero B resources/versions |
| 0 active tenants | fail closed |
| more than 1 active tenant | fail closed; no fallback |
| anon/public/service direct execution | DENY by ACL |

Existence and validation failures return only the existing controlled contract;
they must not reveal foreign lane names, configuration, membership or IDs.

### 34.13 Temporary defaults

All seven compatibility defaults remain unchanged in 3B.

| Table | 3B writer | Current default | Tenant explicitly set after 3B? | Default still used by this writer? | Removal phase |
|---|---|---|---:|---:|---|
| `shooting_lanes` | family creator | CSK UUID | yes, bridge result on root and children | no | 9D-5 after 9E cutover gate |
| `reservations` | none | CSK UUID | unchanged | unchanged | 9D-5 |
| `lane_blocks` | none; hardened in 3A | CSK UUID | unchanged | unchanged | 9D-5 |
| `events` | none | CSK UUID | unchanged | unchanged | 9D-5 |
| `event_lanes` | none | CSK UUID | unchanged | unchanged | 9D-5 |
| `event_registrations` | none | CSK UUID | unchanged | unchanged | 9D-5 |
| `email_deliveries` | none | CSK UUID | unchanged | unchanged | 9D-5 |
| `audit_logs` | family creator writes audit | no default | yes, bridge result | not applicable | remains nullable for global audit |

Rules, durations, pricing and family versions have no independent tenant
default; ownership is derived through their lane/root foreign key. The gate
remains: **REMOVE DEFAULT BEFORE TENANT-AWARE WRITER CUTOVER AND BEFORE SECOND
TENANT**. 3B must not remove any default.

### 34.14 SECURITY DEFINER impact

The measured production count after deployed 9D-3A is `70`. All three 3B
functions remain SECURITY DEFINER, so the expected count after 3B is also
`70`. No helper, overload or wrapper is added. Non-target normalized
fingerprints must remain unchanged; unexpected drift must be `0`.

Remaining disposition after 3B:

- 9D-3C: family V2 writer plus legacy/internal helpers; three approved INVOKER
  conversions occur there, not in 3B;
- SAFE / NO CHANGE: three lane/config integrity triggers remain definers;
- 9D-4: reports, profiles/users, account lifecycle and remaining authorization;
- 9D-5: legacy retirement, sync bridges, defaults and final definer cleanup;
- APP-CUTOVER DEPENDENCY: contextless creator/readers remain on the exact-active
  bridge until trusted tenant context/routing exists in 9E.

UNKNOWN functions after inventory reconciliation: `0`.

### 34.15 Test and regression plan

Implementation verification order:

1. clean local DB reset and normalized preflight fingerprint guards;
2. focused 3B SQL tests for exact signatures, modes, owner, path and ACL;
3. role matrix: admin allow; global-role-only, employee, instructor, user,
   pending, suspended, no-membership, anon and service deny;
4. 0/1/>1 bridge and tenant-status race tests;
5. Tenant A/B reader leakage and hierarchy/IDOR matrix;
6. creator atomicity, payload spoof, explicit tenant writes, audit tenant,
   display order and deterministic concurrency harness;
7. existing family creation/configuration, rules, durations, pricing, capacity,
   optimistic-lock and stale-protection tests;
8. 9D-3A lane blocks plus booking/reservation conflict and direct-DML denial;
9. Events, event registrations/management, public event readers, shared email,
   reserve promotion and check-in regressions;
10. full Supabase DB suite, all Node tests, TypeScript, production build,
    focused lane-family/booking/admin Playwright, changed-files ESLint,
    `npm audit --omit=dev`, `git diff --check`, and fixture cleanup.

Production preflight later must be read-only and verify the same fingerprints,
ACL, tenant/hierarchy invariants, SECURITY DEFINER count `70`, defaults `7/7`,
data volumes and exactly one pending approved migration. A separate approval is
required for production write.

### 34.16 Rollback and STOP conditions

Rollback is a reviewed forward migration restoring only the captured three
function definitions and the former authenticated V1 grant. Never edit an
applied migration or use migration repair. Because signatures and V2/creator
contracts are preserved, an application rollback remains compatible, but a DB
rollback would deliberately reopen the global-role/cross-tenant risk and is
only an emergency coordinated action while Tenant B remains blocked.

STOP on any fingerprint, overload, owner, path, mode or unexpected ACL drift;
nonzero tenant/hierarchy orphan or mismatch; non-admin allow; global-role
bypass; foreign row in a reader; payload tenant acceptance; default-dependent
creator insert; partial family; duplicate version/audit effect; deadlock;
changed DTO/signature/business validation; widened table RLS/ACL; public
booking regression; unexpected SECURITY DEFINER drift; changed compatibility
default; additional pending migration; secret/PII leak; or nonzero fixture.

### 34.17 SEC-004 impact

Successful 3B rollout will close the lane-family creator and admin reader
portion of the global-role/RLS-bypass gap. It will not close SEC-004. Remaining
work includes 9D-3C, 9D-4, 9D-5, trusted selected-tenant routing in 9E, module
cutover in 9F, full cross-tenant application/concurrency proof in 9G, and the
9H closure audit.

The bridge deliberately supports only the present single-active-tenant runtime.
SECOND TENANT remains NO-GO before 9H.

### 34.18 GO / NO-GO

The actual repo supplies an unambiguous three-function boundary, stable
callers, tenant ownership constraints, membership helpers, exact-active bridge,
known fingerprints and unchanged DTO/signature requirements. No unresolved
business decision blocks local implementation. The positive dual-active-tenant
operation is intentionally unavailable until 9E and does not block this
single-active compatibility hardening.

SAAS-9D-3B TECHNICAL PLAN: **READY**

READY FOR SAAS-9D-3B LOCAL IMPLEMENTATION: **GO**

READY FOR PRODUCTION WRITE: **NO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## 35. SAAS-9D-3B local implementation result (2026-09-14)

The approved lane-family creation and configuration-reader slice has been
implemented and verified locally.

- `admin_create_lane_booking_family_v1(jsonb)` now resolves the exact single
  active tenant, requires an active admin membership, writes tenant ownership
  explicitly for root/children/audit, and preserves its payload and response.
- `admin_get_lane_booking_configuration_v1()` and V2 now authorize and scope
  every root/resource/nested configuration path to the resolved tenant. V1 no
  longer has direct authenticated EXECUTE; V2 remains the application entry.
- Global `profiles.role` alone cannot authorize any target. Bridge 0/1/>1,
  pending/suspended/no-membership, cross-tenant hierarchy and reader-isolation
  cases all fail closed as required.
- Focused SQL passed 33/33, ACL 17/17, concurrency passed with zero deadlocks or
  broken/cross-tenant hierarchy, full DB passed 1040/1040, Node 739/739,
  TypeScript/build and focused Playwright 5/5 passed, and fixture cleanup is 0.
- Function signatures/DTOs are unchanged, SECURITY DEFINER remains 70, and all
  7/7 compatibility defaults remain present.
- Migration SHA-256:
  `E7A6ABDE21384ED2CC37E6AB3E133A2D06701A43C2BD2E8A64C12736021EA4B7`.

Detailed evidence is recorded in
`SAAS_9D_3B_LANE_FAMILY_RPC_HARDENING_REPORT.md`.

SAAS-9D-3B LOCAL: **PASS**

READY FOR SAAS-9D-3B PRODUCTION PREFLIGHT: **GO**

READY FOR SAAS-9D-3C: **NO-GO until review**

READY FOR PRODUCTION WRITE: **NO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## 33. SAAS-9D-3 — LANE / CONFIGURATION / ADMIN RPC HARDENING FINAL PLAN

Planning baseline: production and repository state after the completed
SAAS-9D-3A checkpoint `e3cf1103eb943b274d66770d514ac55b59549068`.
Production has 70 public SECURITY DEFINER functions and all seven temporary
CSK tenant defaults. SAAS-9D-3A is CLOSED / PROD PASS. This section is
planning only: no migration, SQL write, application change or deployment is
authorized.

### 33.1 Exact function inventory

The production catalog contains exactly the following 13 functions assigned
to 9D-3. There are no UNKNOWN entries and no overloads beyond the signatures
listed here. Every function is currently owned by `postgres`, has SP1
`search_path=pg_catalog, public, pg_temp`, and is SECURITY DEFINER.

ACL columns below are `PUBLIC / anon / authenticated / service_role`.

| Function and signature | Current callers | SQL callers | ACL | Current authority/context | RLS bypass and tenant risk | Severity |
|---|---|---|---|---|---|---|
| `admin_create_lane_block(uuid,date,time without time zone,time without time zone,text)` | `app/admin/lane-blocks/page.tsx` | tests only | D/D/A/D | `auth.uid()` plus global `profiles.role`; lane arg, no tenant arg | definer writes a block and reads conflicts for any supplied lane | CRITICAL |
| `admin_create_lane_booking_family_v1(jsonb)` | `app/admin/lane-configuration/page.tsx`; lane-family E2E/load harness | none | D/D/A/D | `auth.uid()` plus global admin; payload only, no trusted resource/tenant | global resource creation relying on the CSK default | CRITICAL |
| `admin_get_lane_booking_configuration_v1()` | no TypeScript caller | called by V2 | D/D/A/D | `auth.uid()` plus global admin; no resource/tenant input | returns the global lane/config snapshot | HIGH |
| `admin_get_lane_booking_configuration_v2()` | `app/admin/lane-configuration/page.tsx` | calls V1 | D/D/A/D | `auth.uid()` plus global admin; no resource/tenant input | groups every root returned by the global V1 snapshot | HIGH |
| `admin_set_lane_block_active(uuid,boolean)` | `app/admin/lane-blocks/page.tsx` | tests only | D/D/A/D | global admin/pracownik; block arg | block can identify a foreign tenant and definer mutates it | CRITICAL |
| `admin_set_lane_booking_configuration(uuid,boolean,boolean,boolean,integer,boolean,integer,integer[],jsonb)` | no app caller; explicitly rejected by current page tests | none | D/D/D/D | global admin; lane arg | dormant legacy global writer; latent risk if ACL widens | HIGH |
| `admin_set_lane_booking_family_configuration_v2(uuid,bigint,jsonb,boolean)` | `app/admin/lane-configuration/page.tsx` | calls normalize and snapshot helpers | D/D/A/D | global admin; root lane and payload resource IDs | mutates family, rules, durations and pricing without membership boundary | CRITICAL |
| `admin_update_lane_block(uuid,uuid,date,time without time zone,time without time zone,text,boolean)` | no current app caller; concurrency/DB tests only | none | D/D/A/D | global admin/pracownik; block and proposed lane | cross-tenant reparent/mutation possible without block/lane tenant comparison | CRITICAL |
| `lane_booking_family_business_snapshot_v2(uuid)` | no app caller | family V2 writer | D/D/D/D | root lane only; no auth check | internal definer read; no direct client surface | LOW / internal |
| `normalize_lane_booking_family_payload_v2(jsonb)` | no app caller | family V2 writer | D/D/D/D | payload only; pure normalization | immutable internal helper; definer is unnecessary | LOW / internal |
| `validate_lane_booking_rule_capacity()` | trigger only | `validate_lane_booking_rule_capacity_trigger` | D/D/D/D | `NEW.lane_id` | integrity trigger; not a client authorization surface | SAFE |
| `validate_shooting_lane_capacity_change()` | trigger only | `validate_shooting_lane_capacity_change_trigger` | D/D/D/D | `OLD/NEW` lane row | integrity trigger; not a client authorization surface | SAFE |
| `validate_shooting_lane_hierarchy()` | trigger only | `validate_shooting_lane_hierarchy_trigger` | D/D/D/D | `OLD/NEW.parent_lane_id` | integrity plus composite FK; not client callable | SAFE |

Production normalized fingerprints frozen for preflight are:

| Signature | Fingerprint |
|---|---|
| `admin_create_lane_block(uuid,date,time without time zone,time without time zone,text)` | `fba59c6dbe820ab5c81525bb4dc8659e` |
| `admin_create_lane_booking_family_v1(jsonb)` | `69ec76ae348f83387045a5c343dd906f` |
| `admin_get_lane_booking_configuration_v1()` | `2684f7ea8a3b9eba6dae4d4f7aad653c` |
| `admin_get_lane_booking_configuration_v2()` | `5c729f01536d476a5c8b3cf0d9b40c62` |
| `admin_set_lane_block_active(uuid,boolean)` | `58fd6523e0b2fa55c6e6afc2a33a1b1b` |
| `admin_set_lane_booking_configuration(uuid,boolean,boolean,boolean,integer,boolean,integer,integer[],jsonb)` | `c60876406d007491187869017df989b5` |
| `admin_set_lane_booking_family_configuration_v2(uuid,bigint,jsonb,boolean)` | `00fc387949410273a7cb33589cd8d1c6` |
| `admin_update_lane_block(uuid,uuid,date,time without time zone,time without time zone,text,boolean)` | `66f4ba1fb3fe7686b2a04f335851dc43` |
| `lane_booking_family_business_snapshot_v2(uuid)` | `bc891bbdfab6d033fed72ece1c9fc193` |
| `normalize_lane_booking_family_payload_v2(jsonb)` | `77eee4f69abb6bdf74f1529f8e21589a` |
| `validate_lane_booking_rule_capacity()` | `78a6c1beb5048645a46d20d735324e2a` |
| `validate_shooting_lane_capacity_change()` | `96e0199a327831f40bec66c57d37f5ca` |
| `validate_shooting_lane_hierarchy()` | `dd3c97078341a74edc83ca79e9b19c0f` |

### 33.2 Classification and target disposition

**A. BODY HARDENING REQUIRED**

- the three lane-block functions: preserve their signatures and response
  codes, derive tenant from lane/block, require active same-tenant membership,
  retain admin/employee scope and make every conflict query tenant-bound;
- `admin_create_lane_booking_family_v1`: keep its public signature for the
  legacy single-tenant runtime, resolve exactly one active tenant through the
  approved bridge, require active tenant admin, and explicitly write that
  tenant to every new shooting-lane and audit row;
- both configuration readers: resolve exactly one active tenant, require its
  active admin membership and build only that tenant's lane/config snapshot;
- `admin_set_lane_booking_family_configuration_v2`: derive tenant from the
  locked root, require active tenant admin, reject every payload resource not
  in that root and tenant, tenant-bind obligation/conflict queries, and write a
  tenant-scoped audit.

**B. ACL-ONLY CLEANUP**

- revoke authenticated EXECUTE from the unused V1 configuration reader after
  the V2 wrapper remains its only caller. Its body is still hardened because
  V2 depends on it; the ACL operation itself must not alter its owner,
  signature or search path.

**C. SECURITY INVOKER CANDIDATES — APPROVED TARGET**

- `admin_set_lane_booking_configuration`: no current caller and no client or
  service grant; convert to INVOKER without widening ACL or changing body;
- `lane_booking_family_business_snapshot_v2`: internal caller only; convert to
  INVOKER and keep all client/service grants denied;
- `normalize_lane_booking_family_payload_v2`: immutable internal helper;
  convert to INVOKER and keep all grants denied.

An outer hardened definer executes these helpers with its already-authorized
effective context. No helper becomes a new authorization entry point.

**D. SAFE / NO CHANGE**

- the three integrity trigger functions remain SECURITY DEFINER, postgres-owned,
  SP1 and non-callable by client/service roles. Their table-bound trigger
  execution is required to preserve capacity and hierarchy invariants.

**E. APP-CUTOVER DEPENDENCY**

- the contextless family-create and configuration-read contracts depend on
  the exact-single-active-tenant bridge in 9D-3. They are explicitly
  `TEMPORARY UNTIL 9E`; 9E must introduce trusted selected-tenant context
  before Tenant B, then a later versioned contract can remove this bridge.

No 9D-4, 9D-5 or 9E function is moved into 9D-3.

### 33.3 Application and SQL caller inventory

| File/caller | RPC | Arguments | Auth context today | Trusted resource/tenant context | App change in 9D-3 |
|---|---|---|---|---|---|
| `app/admin/lane-blocks/page.tsx` | `admin_create_lane_block` | lane, date, start/end, reason | browser JWT; route protected separately | lane ID -> lane tenant | no |
| `app/admin/lane-blocks/page.tsx` | `admin_set_lane_block_active` | block ID, target active | browser JWT | block -> lane/tenant | no |
| no runtime caller | `admin_update_lane_block` | block, proposed lane and values | retained authenticated RPC contract | block tenant plus proposed lane tenant | no; preserve existing DB contract |
| `app/admin/lane-configuration/page.tsx` | `admin_get_lane_booking_configuration_v2` | none | browser JWT plus legacy UI `get_my_role` check | exact-active bridge; DB membership is authority | no |
| same page | `admin_create_lane_booking_family_v1` | JSON family payload | browser JWT | exact-active bridge because no resource exists | no |
| same page | `admin_set_lane_booking_family_configuration_v2` | root, version, resources, acknowledgement | browser JWT | root lane -> tenant | no |
| V2 reader | `admin_get_lane_booking_configuration_v1` | none | outer definer context | same exact-active tenant resolved by hardened contract | no |
| family writer | snapshot and normalize helpers | root/payload | outer hardened definer | root tenant already established | no |
| table triggers | three validation functions | OLD/NEW | statement effective role | affected lane/rule row | no |

The UI's `get_my_role` call may remain as presentation gating during 9D-3, but
it is never accepted as database authorization. Global `profiles.role` without
an active matching membership must fail in every exposed 9D-3 RPC.

### 33.4 Tenant derivation and table ownership

- lane operations: load and lock `shooting_lanes`, then use
  `shooting_lanes.tenant_id`;
- block toggle: lock `lane_blocks`, derive its tenant and cross-check the
  referenced lane through `(tenant_id,lane_id)`;
- block update: derive tenant from the existing block before accepting the
  proposed lane; proposed lane must have exactly the same tenant;
- family update/snapshot: derive from the top-level root; every current child,
  requested resource, booking rule, duration and pricing row must join through
  a lane in that tenant and family;
- rule/duration/pricing tables are lane-owned and intentionally have no
  independent tenant column. The lane FK is their authority;
- `lane_booking_family_configuration_versions` is root-lane-owned; its root ID
  must resolve to the same locked tenant;
- create-family has no resource ID and therefore uses only the exact-active
  bridge, never a caller-supplied tenant UUID;
- audit rows created by family create/update receive the derived tenant ID;
- supplied tenant identifiers, JSON fields or browser state are never authority.

### 33.5 Lane hierarchy invariants

The existing composite FK already enforces
`child.(tenant_id,parent_lane_id) -> parent.(tenant_id,id)`. The hardened
writers add earlier controlled denial and must not rely on the constraint as
their first authorization check.

Required outcomes:

- Parent A + Child A: allowed subject to current business validation;
- Parent A + Child B: denied before mutation;
- changing resource kind, parent identity or family membership through the
  V2 payload: denied under the existing immutable identity contract;
- mixed A+B resource arrays: whole call denied, no partial updates;
- disabling a parent/position preserves existing future reservation/block
  acknowledgement semantics and cannot affect another tenant;
- no hard-delete or free reparent RPC exists in the active family editor;
  9D-3 must not invent one;
- trigger validation and composite constraints remain the final integrity net.

### 33.6 Lane blocks and conflict domain

Admin and employee retain their present create/update/toggle scope, but only
with an active membership in the block/lane tenant. Instructor, ordinary user,
pending, suspended, no-membership and global-role-only callers are denied.

All reservation, lane-block and event-lane conflict reads must include the
derived tenant in addition to the existing hierarchy family IDs. The existing
global lock ordering in `lock_lane_conflict_families_v1` is preserved. The
helper itself is outside the 13-function 9D-3 inventory and is not modified;
callers validate tenant before and after its result as required.

### 33.7 Configuration and pricing contract

Configuration is resource-owned, not global:

- `shooting_lanes`: tenant-owned;
- booking rule, durations and pricing: lane-owned;
- family version: root-lane-owned;
- admin read/write: tenant admin only;
- public booking reader: separate public contract assigned to 9D-4E/9E and
  explicitly excluded from this migration.

9D-3 changes tenant predicates and authorization only. It preserves duration
sets, min/max people coverage, weekday/weekend pricing, rule precedence,
whole-lane versus position semantics, configuration_version optimistic
locking, stale protection and future-obligation acknowledgement. Lane A can
never read, apply or update a pricing/rule row whose linked lane belongs to B.

### 33.8 Create-resource strategy and temporary bridge

`admin_create_lane_booking_family_v1(jsonb)` keeps its signature to avoid an
unauthorized 9E cutover. It resolves the tenant with the already-reviewed
single-active-tenant helper and fails closed when active tenant count is zero
or greater than one. It then requires active tenant role `admin`, explicitly
inserts `shooting_lanes.tenant_id` for root and positions, and uses those lane
IDs for rule/duration/pricing ownership. It also writes `audit_logs.tenant_id`.

This contract is marked `TEMPORARY UNTIL 9E`. A second tenant remains blocked;
the bridge is compatibility, not multi-tenant routing.

### 33.9 Staff authorization matrix

Privileged authorization is always:

`auth.uid() + active tenant_memberships row + allowed mapped role + resource tenant match`.

| Caller | Lane/block A | Lane/block B | Configuration A | Configuration B |
|---|---|---|---|---|
| active Admin A | ALLOW | DENY | ALLOW | DENY |
| active Employee A | existing block scope ALLOW | DENY | DENY | DENY |
| active Instructor A | DENY | DENY | DENY | DENY |
| ordinary User A | DENY | DENY | DENY | DENY |
| global admin/pracownik without membership | DENY | DENY | DENY | DENY |
| pending/suspended/no membership | DENY | DENY | DENY | DENY |

No instructor scope is extended. Legacy `pracownik` maps only to membership
role `employee`; `instruktor` maps to `instructor` through the approved bridge.

### 33.10 Public and user lane contracts

9D-3 does not widen table RLS or public RPC grants. It keeps three boundaries
separate:

1. public booking/configuration reads — unchanged and deferred to the selected
   tenant cutover assigned to 9D-4E/9E;
2. authenticated booking reads/writes — already hardened by 9D-1 and retained;
3. staff lane/configuration writes — hardened here and tenant-bound.

Public responses must continue excluding admin-only metadata and inactive or
internal pricing state not intended by the current public DTO. Cross-tenant
rows must never appear through a new 9D-3 path.

### 33.11 Service-role paths

Production ACL shows no service_role EXECUTE on any of the 13 functions. No
current application caller requires service_role for lane/configuration RPCs.
9D-3 therefore grants none. Trigger execution is table-bound and does not
justify a direct service RPC grant. Any later server path must provide a
separate reviewed caller, authentication, tenant and resource context; a
service key alone is never authorization.

### 33.12 ACL, owner and search_path target

- exposed active wrappers: SECURITY DEFINER, owner postgres, SP1;
- authenticated EXECUTE only on the six runtime/retained block and V2
  configuration contracts, plus create-family;
- V1 configuration reader: no client/service EXECUTE after cleanup;
- legacy set-single-lane and two internal helpers: SECURITY INVOKER, no
  PUBLIC/anon/authenticated/service EXECUTE;
- trigger functions: unchanged SECURITY DEFINER, owner postgres, SP1, no
  direct client/service EXECUTE;
- no PUBLIC or anon function grant is introduced;
- ACL-only statements are separately fingerprint-guarded so they cannot
  silently modify function body, signature, owner or search path.

### 33.13 Temporary CSK defaults

All defaults remain during 9D-3. None is an authorization mechanism.

| Table | Current default | Current writers | Tenant-aware state after 9D-3 | 9D-3 impact | Target removal |
|---|---|---|---|---|---|
| `shooting_lanes` | CSK UUID | family-create | explicit bridge tenant | writer becomes explicit | 9D-5 after 9E gate |
| `reservations` | CSK UUID | hardened 9D-1 writer | explicit lane tenant | none | 9D-5 |
| `lane_blocks` | CSK UUID | block create/update | explicit lane/block tenant | writer becomes explicit | 9D-5 |
| `events` | CSK UUID | hardened 9D-2 writers | explicit resolved/event tenant | none | 9D-5 |
| `event_lanes` | CSK UUID | hardened 9D-2 writers | explicit event tenant | none | 9D-5 |
| `event_registrations` | CSK UUID | hardened 9D-2 registration writers | explicit event tenant | none | 9D-5 |
| `email_deliveries` | CSK UUID | hardened 9D-2C flows | explicit record tenant | none | 9D-5 |

Mandatory later gate: **REMOVE DEFAULT BEFORE TENANT-AWARE WRITER CUTOVER AND
BEFORE SECOND TENANT**. Removal is not part of 9D-3.

### 33.14 Concurrency plan

Focused deterministic harnesses must cover:

1. concurrent block creates against the same family and interval;
2. concurrent block update/toggle on the same row;
3. opposite-direction block moves between families using global lock order;
4. family configuration updates with the same expected version — one change,
   one stale result;
5. family update versus reservation, event assignment and lane-block create;
6. concurrent create-family display ordering without duplicate or partial
   resources;
7. attempted Parent A + Child B and block A + Lane B during concurrent writes;
8. pricing/duration replacement racing another family update;
9. activation/deactivation with future obligations;
10. exact-active-tenant bridge under 0/1/>1 active-tenant states.

Required final invariants: deadlocks `0`, cross-tenant relations `0`, broken
hierarchy `0`, partial family/config writes `0`, broken pricing/rule coverage
`0`, duplicate audit effects `0`, fixture `0`.

### 33.15 Cross-tenant and spoof matrix

- Admin A + Lane A: ALLOW;
- Admin A + Lane B: DENY;
- Employee A + Lane A block operation: existing scope ALLOW;
- Employee A + Lane B: DENY;
- global admin/pracownik without active membership: DENY;
- pending/suspended/no membership: DENY;
- Parent A + Child B: DENY;
- Lane A + pricing/rule linked to Lane B: DENY;
- Block A reparented to Lane B: DENY;
- mixed A+B payload: DENY atomically;
- caller-supplied tenant field in JSON: ignored/rejected, never authority;
- missing/null/orphan resource: controlled fail closed without existence leak;
- Tenant B rows never create false reservation/block/event conflicts for A.

### 33.16 Regression plan

For each subphase run focused SQL/ACL tests, Tenant A/B IDOR matrices,
no-membership/pending/suspended/global-role negatives, RLS recursion checks,
direct-DML denial and cleanup proof. Preserve and run the existing lane block,
family configuration, family creation, hierarchy, booking and cross-writer
concurrency harnesses.

Final local regression requires the full Supabase DB suite, all Node tests,
TypeScript, production build, lane-family and relevant admin Playwright,
changed-files ESLint, `npm audit --omit=dev`, and `git diff --check`.

Mandatory unaffected-domain smoke covers Booking, reservations, check-in,
Events, event registrations/management/public readers, confirmation email,
reserve promotions, Calendar and Reports. Exact pricing, durations, limits,
availability, hierarchy conflict and optimistic-lock behavior must remain.

### 33.17 SECURITY DEFINER impact

Current production count: **70**.

Planned disposition of the 13 functions:

- 7 hardened exposed/internal-wrapper definers remain (three block contracts,
  family create, V1/V2 admin readers, family V2 writer);
- 3 internal/legacy functions move to SECURITY INVOKER;
- 3 integrity triggers remain safe SECURITY DEFINER.

Expected production count after all 9D-3 subphases: **67**. Any other count or
non-target fingerprint drift is a deployment blocker.

Remaining functions stay assigned only to 9D-4, 9D-5 or SAFE/NO CHANGE as in
the authoritative inventory. APP-CUTOVER dependencies remain 9E. UNKNOWN: **0**.

### 33.18 Proposed subphases and implementation order

**9D-3A — lane-block writers**

- harden create/update/toggle with resource-derived tenant, membership roles,
  explicit `lane_blocks.tenant_id` and tenant-filtered conflicts;
- preserve signatures, response DTOs and admin/employee behavior;
- run block/hierarchy/cross-writer concurrency before proceeding.

**9D-3B — lane-family creation and admin readers**

- harden V1/V2 reader scope and revoke the unused authenticated V1 surface;
- harden create-family with exact-active bridge, admin membership, explicit
  lane/audit tenant and cross-tenant payload denial;
- preserve V2 and creation application contracts; mark bridge TEMPORARY UNTIL 9E.

**9D-3C — family writer and internal helpers**

- harden family V2 update, optimistic locking, root/resource tenant binding,
  obligation/conflict predicates and audit tenant;
- convert legacy single-lane writer, snapshot helper and normalize helper to
  INVOKER with closed ACL;
- retain the three trigger functions unchanged;
- verify final definer count 67 and zero non-target drift.

Each subphase gets its own migration, focused tests, frozen preflight/postflight
fingerprints and separate production approval. No large combined deployment.

### 33.19 Rollback and STOP conditions

Rollback is a reviewed forward migration restoring only the captured function
bodies/security modes/ACLs for the failed subphase. Never edit an applied
migration or use migration repair. Because signatures and app contracts remain
stable, application rollback is not expected for 3A–3C; if a bridge or wrapper
fails, stop and forward-fix while Tenant B remains blocked.

STOP on any unexpected overload/fingerprint/owner/path/ACL drift, missing or
orphan tenant ownership, mixed-tenant hierarchy/config data, unknown caller,
unexpected audit target, pricing/config semantic change, widened role scope,
nonzero fixture, extra pending migration, concurrency invariant failure or
SECURITY DEFINER count other than the phase-specific target.

### 33.20 SEC-004 impact and remaining work

9D-3 will close global-role and cross-tenant bypasses in lane-block operations,
lane-family creation, admin configuration reads and family configuration writes.
It will also remove three unnecessary definer modes and close the unused V1
configuration reader's client surface.

It will not close:

- 9D-4 reports, profiles/users, account and remaining authorization helpers;
- 9D-5 legacy retirement, seven defaults, sync-bridge retirement and final
  definer disposition;
- 9E trusted tenant selection/routing and contextless-contract cutover;
- 9F module-level reports/events/calendar/check-in cutover;
- 9G complete cross-tenant application and concurrency verification;
- 9H final SEC-004 closure and second-tenant readiness audit.

SEC-004 therefore remains OPEN and the second tenant remains NO-GO.

### 33.21 Blocking decisions and final gate

No unresolved business or architecture decision blocks local 9D-3A. The role
mapping, exact-active bridge, employee block scope, admin-only configuration
scope, lane-owned pricing/config model, unchanged public reader boundary and
temporary-default retirement gate are already defined.

Before each local implementation subphase, re-run the production/catalog
fingerprint preflight and confirm the caller inventory. A separate user approval
is required for implementation, for every production preflight/write, and for
each Git checkpoint.

SAAS-9D-3 TECHNICAL PLAN: **READY**

READY FOR SAAS-9D-3 LOCAL IMPLEMENTATION: **GO**

READY FOR PRODUCTION WRITE: **NO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## 30. SAAS-9D-2C-1 local implementation result

SAAS-9D-2C-1 was implemented locally after checkpoint
`0b5188fdd9fbbd07b56c2ce2c0378ca0c82a4729`.

Exact scope:

- `prepare_confirmation_email(text,uuid)`: tenant/resource/membership body
  hardening, authenticated-only SECURITY DEFINER retained and normalized to
  SP1;
- `complete_confirmation_email(uuid,boolean,text,text)`: tenant/resource/
  recipient body hardening and service-only SECURITY INVOKER conversion;
- `check_confirmation_email_rate_limit(uuid,text)`: exact fingerprint,
  metadata, limits and service-only ACL preserved unchanged.

The two reserve-promotion functions remain untouched in 2C-2. No application
file changed.

Local verification:

- database reset: PASS;
- focused SQL: 44/44 PASS;
- real prepare/complete concurrency: PASS, with zero deadlocks, broken
  invariants or duplicate effects;
- 2A, 2B-1 and 2B-2 regressions: PASS;
- full DB suite: 31 files / 936 tests PASS;
- Node: 734/734 PASS;
- TypeScript and build: PASS;
- focused Events Playwright: 8/8 PASS;
- fixture cleanup: every tracked category 0;
- SECURITY DEFINER inventory: 73 -> 72 with zero unrelated drift;
- compatibility defaults: 7/7 retained.

Migration:

`20260914100000_harden_shared_confirmation_email_rpcs.sql`

SHA-256:

`C7CCEAD3B0A5ACE67AFE05D87EE6966B885C5BC1111926F01ACD970D7A31E0F1`

Detailed evidence is recorded in
`SAAS_9D_2C1_SHARED_RPC_HARDENING_REPORT.md`.

SAAS-9D-2C-1 LOCAL: **PASS**

READY FOR SAAS-9D-2C-1 PRODUCTION PREFLIGHT: **GO**

READY FOR SAAS-9D-2C-2: **NO-GO until review**

READY FOR PRODUCTION WRITE: **NO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## 29. SAAS-9D-2C — REMAINING EVENT / SHARED RPC HARDENING FINAL PLAN

This section is planning-only and is based on production after the completed
SAAS-9D-2A, 2B-1 and 2B-2 deployments. The reproducible 2B-2 checkpoint is
`0b5188fdd9fbbd07b56c2ce2c0378ca0c82a4729` on `main`, identical to
`origin/main` when this plan was prepared. No migration, SQL write,
application change or production deployment is authorized here.

### 29.1 Exact 2C function inventory

The exact 2C review boundary contains five existing functions. No function
from 9D-3, 9D-4 or 9D-5 is moved into this phase.

| Function | Current callers | Mode / owner / path | Current grants | Current authorization | Tenant/resource derivation | RLS bypass and cross-tenant risk | Severity |
|---|---|---|---|---|---|---|---|
| `check_confirmation_email_rate_limit(uuid,text)` | three mail API routes through a service client | DEFINER / postgres / `public, pg_temp` | service_role only | route verifies the user; function trusts supplied user UUID plus HMAC IP hash | global user/IP anti-abuse scope; no tenant-owned target | definer is required because service_role has no table ACL; no tenant data is read, but an arbitrary service call can affect another user's rate bucket | MEDIUM |
| `prepare_confirmation_email(text,uuid)` | event-registration confirmation, reservation confirmation and reservation cancellation routes, using caller JWT | DEFINER / postgres / `public, pg_temp` | authenticated only | owner checks for confirmation paths; cancellation staff fallback uses global `profiles.role` | message type + record ID -> reservation or registration -> event -> tenant | bypasses RLS and currently inserts `email_deliveries` using the CSK default rather than a proved tenant; staff branch is globally authorized | CRITICAL |
| `complete_confirmation_email(uuid,boolean,text,text)` | the same three routes through the service completion client | DEFINER / postgres / `public, pg_temp` | service_role only | opaque delivery claim ID | claim -> delivery -> typed record -> tenant | completion updates by claim only and does not re-prove delivery tenant, typed target tenant and recipient equality | HIGH |
| `prepare_event_reserve_promotions(uuid)` | `lib/server/event-reserve-promotion.ts`, called after cancellation and by the manual promotion API | DEFINER / postgres / `public, pg_temp` | service_role only | service credential; manual route currently checks global profile role | event ID -> event tenant; reserve registrations must match it | counts and claims registrations by global event ID without explicit tenant predicates; manual route can authorize a global role with no membership | CRITICAL |
| `complete_event_reserve_promotion(uuid,uuid,boolean,text)` | `lib/server/event-reserve-promotion.ts` after provider outcome | DEFINER / postgres / `public, pg_temp` | service_role only | registration ID + claim ID | registration -> event -> tenant; claim is stored on the registration | exact claim equality is checked, but event/registration tenant equality is not explicitly re-proved | CRITICAL |

Production normalized fingerprints frozen for implementation preflight:

| Signature | Normalized MD5 |
|---|---|
| `check_confirmation_email_rate_limit(uuid,text)` | `e693411c3fc7f24510313e60a1d8e2a5` |
| `prepare_confirmation_email(text,uuid)` | `449dbd830a7ece7f0c5b8b046dc1ee2c` |
| `complete_confirmation_email(uuid,boolean,text,text)` | `8ca5430a2d7e625d10ebc61617a03dd5` |
| `prepare_event_reserve_promotions(uuid)` | `4e73ef1df59936a1a3f41a00e121f6e9` |
| `complete_event_reserve_promotion(uuid,uuid,boolean,text)` | `dd5025876008d6eb9551497d84cef90e` |

All five exist exactly once, are currently SECURITY DEFINER, owned by
`postgres`, and have no PUBLIC or anon EXECUTE. `prepare_confirmation_email`
is authenticated-only; the other four are service-only.

### 29.2 Classification and target decision

| Function | Classification | Target decision |
|---|---|---|
| `prepare_confirmation_email` | A. BODY HARDENING REQUIRED | retain one authenticated SECURITY DEFINER signature, normalize to SP1, derive tenant from the typed resource, require owner or active same-tenant admin/employee membership, write tenant explicitly |
| `complete_confirmation_email` | A + C. BODY HARDENING AND DEFINER REMOVAL CANDIDATE | change to SECURITY INVOKER, SP1, service-only; service_role already has exact DML on `email_deliveries`; verify claim/delivery/typed-target/recipient tenant consistency before completion |
| `prepare_event_reserve_promotions` | A + C + E. BODY HARDENING, DEFINER REMOVAL, APP DEPENDENCY | change to SECURITY INVOKER, SP1, service-only; derive and filter the event tenant; complete manual-route membership cutover in the same 2C-2 release |
| `complete_event_reserve_promotion` | A + C. BODY HARDENING AND DEFINER REMOVAL CANDIDATE | change to SECURITY INVOKER, SP1, service-only; verify registration/event tenant consistency and exact current claim before completion |
| `check_confirmation_email_rate_limit` | D. SAFE / NO BODY CHANGE | preserve fingerprint, DEFINER and service-only ACL in 2C; this is intentionally global anti-abuse state and service_role has no direct table ACL, so converting it would require an unjustified table grant; path normalization is deferred to the final 9D-5 inventory review |

No ACL-only cleanup is required in 2C: current effective function grants are
already the narrow target. No grant is widened. The expected public-schema
SECURITY DEFINER count after both 2C slices is **70**, reduced from 73 by
converting the three service-only claim functions above to invoker. The rate
limit definer and authenticated prepare wrapper remain.

### 29.3 Production data preflight

The read-only production preflight found:

- 11 `email_deliveries`, all `reservation_confirmation`;
- zero unknown message types;
- zero null delivery tenants;
- zero reservation or event-registration target/tenant/recipient issues;
- zero active or expired delivery claims;
- zero active or expired promotion claims;
- zero promotion registration/event tenant issues.

No data migration or new tenant-claim column is required. `email_deliveries`
already has `tenant_id`; promotion claims live on the tenant-owned
`event_registrations` row. Implementation preflight must repeat these counts
and stop on an unknown type, orphan or mismatch.

### 29.4 Caller inventory

| Caller | Functions | Auth context | Tenant context | Resource context | Application change required |
|---|---|---|---|---|---|
| `app/api/send-event-registration-confirmation/route.ts` | rate limit, prepare confirmation, complete confirmation | verified user JWT for reads/prepare; service client only for rate-limit/completion | registration -> event tenant | owner registration ID | no signature change; DB enforcement only |
| `app/api/send-reservation-confirmation/route.ts` | rate limit, prepare confirmation, complete confirmation | verified owner JWT; service completion | reservation tenant | owner reservation ID | no signature change |
| `app/api/send-reservation-cancellation/route.ts` | rate limit, prepare confirmation, complete confirmation | verified JWT; current route also reads legacy profile role; service completion | reservation tenant | owner or staff cancellation reservation ID | no signature change; DB membership becomes authoritative even if legacy UI precheck remains temporarily |
| `app/api/cancel-event-registration/route.ts` | indirect promotion prepare/complete | cancellation RPC authenticates owner/staff; helper receives only the event ID returned by that successful RPC | hardened cancellation result -> event tenant | registration -> event | no request-contract change |
| `app/api/send-event-reserve-promotion/route.ts` | indirect promotion prepare/complete | verified user JWT, but current authorization uses global `profiles.role` | currently absent before service call | browser event ID | **yes in 2C-2**: derive event tenant through authenticated DB context and require active admin/employee membership before service invocation |
| `lib/server/event-reserve-promotion.ts` | promotion prepare/complete and service table reads | server-only service credential | derived inside hardened DB prepare; registration IDs returned by that claim | event ID plus exact prepared registration/claim pairs | retain server-only boundary and signatures; do not accept browser tenant ID |

There is no SQL-to-SQL, cron or background caller for these five functions.
Tests and security reports call them only as regression surfaces. Direct
service helper invocation remains an infrastructure boundary; it is not by
itself business authorization.

### 29.5 Tenant derivation and authorization

`prepare_confirmation_email` must use a message-type allowlist and derive the
tenant as follows:

- `reservation_confirmation` and `reservation_cancellation`: lock the
  reservation and take `reservations.tenant_id`;
- `event_registration_confirmation`: lock the registration, require its
  non-null `event_id`, load the event, and prove
  `registration.tenant_id = event.tenant_id`;
- derive `recipient_user_id` only from that resource, never from request data;
- insert `email_deliveries.tenant_id` explicitly and reject an existing
  delivery whose tenant, record type, record ID or recipient differs.

Owner confirmation requires `auth.uid() = resource.user_id` plus an active
membership in the resource tenant. Cancellation email preparation permits the
same owner or active tenant membership role `admin`/`employee`. Global
`profiles.role`, pending membership, suspended membership, no membership,
user/instructor membership for staff actions and cross-user/cross-tenant IDs
all deny. Existing status eligibility remains unchanged.

`prepare_event_reserve_promotions` locks the event, derives its tenant, counts
only registrations with both matching `tenant_id` and `event_id`, and claims
only reserve registrations in that same tenant. `complete_event_reserve_promotion`
locks the supplied registration, loads its event, proves equal tenants and
then requires the exact current claim ID. Neither accepts tenant ID.

The manual promotion route must replace the global profile-role decision with:

1. authenticated event lookup to derive its stored tenant;
2. `has_tenant_role_v1(derived_tenant_id, ['admin','employee'])` under the
   caller JWT;
3. fail-closed not-found/forbidden behavior before creating a service client;
4. invoke the service helper only with the already-checked event ID.

The tenant UUID is not accepted from the browser. The event tenant is
immutable through client paths, so the lookup plus membership check does not
create a tenant-switch TOCTOU window.

### 29.6 Service-role model

The three completion/promotion functions remain callable only by
`service_role`, but service possession is not treated as business authority:

- mail routes authenticate the actor before creating a delivery claim;
- completion can touch only the exact claim produced by authenticated
  prepare and must re-prove the typed target tenant;
- owner cancellation may promote only the event ID returned by the successful
  hardened cancellation RPC;
- manual promotion must pass the event-derived membership precheck;
- provider recipient reads use only registration IDs returned by the
  tenant-filtered prepare function;
- no browser receives a service credential, claim tenant or arbitrary
  recipient selector.

Production ACL confirms service_role has the table privileges required for
the three proposed invoker functions on `email_deliveries`, `events` and
`event_registrations`. It has no table privilege on
`confirmation_email_rate_limits`, which is why that one narrow definer is
retained rather than widening table ACL.

### 29.7 Public, token, owner, staff and server paths

- **Public read:** none of the five functions is public; public Events readers
  remain the completed 2B-2 contracts and receive no membership requirement.
- **Public token action:** reserve-promotion confirmation is already hardened
  in 2A and remains outside 2C. Token -> registration -> event tenant,
  expiration, owner binding and single-use semantics must regress PASS.
- **Owner action:** confirmation/cancellation delivery prepare is actor JWT +
  owned resource + active membership + resource tenant.
- **Staff action:** cancellation preparation and manual promotion require
  active same-tenant admin/employee membership.
- **Server action:** only rate limiting and exact prepared-claim completion or
  promotion use service_role.

No token alone authorizes a 2C mutation. Promotion token generation is bound
to a tenant-filtered reserve registration. Tokens remain UUIDs, expire after
24 hours, and confirmation remains single-use/idempotent under the completed
2A contract. Full tokens, claims, recipient PII and provider errors remain
absent from logs and public responses.

### 29.8 ACL, owner and search path target

| Function | Target mode | Owner | Target search path | PUBLIC | anon | authenticated | service_role |
|---|---|---|---|---:|---:|---:|---:|
| rate limit | DEFINER | postgres | retain current SP2 in 2C | no | no | no | EXECUTE |
| prepare confirmation | DEFINER | postgres | SP1 | no | no | EXECUTE | no |
| complete confirmation | INVOKER | postgres | SP1 | no | no | no | EXECUTE |
| prepare promotions | INVOKER | postgres | SP1 | no | no | no | EXECUTE |
| complete promotion | INVOKER | postgres | SP1 | no | no | no | EXECUTE |

SP1 means `pg_catalog, public, pg_temp`. All touched identifiers are schema
qualified. The migration must revoke from all four application roles before
granting back only the exact target role. The unchanged rate-limit function
is fingerprint-frozen in both preflight and postflight.

### 29.9 Signature and response compatibility

All five signatures, parameter defaults, return shapes and stable business
codes remain unchanged. No tenant argument is added. Existing callers continue
to pass record, event, registration and claim IDs in the same order.

Compatibility by slice:

| State | 2C-1 shared delivery | 2C-2 promotion |
|---|---|---|
| old app + old DB | current behavior | current behavior |
| old app + new DB | safe for single-active CSK; DB enforcement is stricter and signatures unchanged | safe while second tenant remains blocked; manual route still has legacy precheck until app release |
| new app + old DB | no app change in 2C-1 | membership precheck improves authorization but service RPC bodies remain globally scoped |
| new app + new DB | tenant-bound | tenant-bound |

Recommended rollout for 2C-2 is **DB first followed immediately by APP in one
controlled low-traffic release window**, with the second-active-tenant guard
unchanged. The phase is not complete until both sides pass production smoke.

### 29.10 Concurrency and idempotency

The implementation must preserve and test:

1. two parallel delivery prepares for one typed record: exactly one `ready`,
   the other `in_progress` or `already_sent`;
2. completion with the exact current claim only; foreign and superseded claim
   IDs deny;
3. repeated successful completion returns no second mutation or send state;
4. provider failure clears only its claim, stores a bounded technical code and
   retains the existing three-attempt/24-hour bound;
5. a delayed completion may succeed only while its claim remains the current
   claim; a re-claimed record makes the old completion fail;
6. two parallel promotion prepares serialize on the event and cannot claim or
   email the same reserve registration twice;
7. reserve ordering remains `created_at,id`, capacity uses only registered and
   approved statuses, and reserve does not occupy capacity;
8. cancellation and manual promotion races do not exceed capacity or create
   duplicate active claims;
9. success/failure promotion completion remains idempotent for the same exact
   registration/claim pair;
10. rate-limit user and HMAC-IP scopes retain their current atomic behavior.

### 29.11 Cross-tenant test matrix

Minimum focused tests for each applicable path:

| Scenario | Expected |
|---|---|
| Tenant A resource + active authorized Tenant A caller | ALLOW |
| Tenant B resource + Tenant A caller | DENY |
| global `profiles.role=admin/pracownik` without membership | DENY |
| pending membership | DENY |
| suspended membership | DENY |
| no membership | DENY |
| instructor/user attempting staff action | DENY |
| owner A on another user's resource | DENY |
| browser-supplied tenant spoof | impossible by request contract / DENY |
| delivery tenant differs from typed target tenant | DENY, no state change |
| delivery recipient differs from target owner | DENY, no state change |
| promotion registration tenant differs from event tenant | DENY |
| claim from Tenant B paired with Tenant A registration/event | DENY |
| claim/token replay after successful completion | controlled no-change |
| service direct call without a valid current claim | DENY |

Tests must also prove the legal owner, admin and employee paths, public Events
2B-2 regression, event registration 2A regression, reservation 9D-1
regression, SEC-006 HTML escaping, SEC-015 cancellation delivery, safe errors,
PII minimization and zero fixture.

### 29.12 Full SECURITY DEFINER inventory after 2B-2

Production contains exactly 73 SECURITY DEFINER functions. Every signature is
accounted for below; there is no UNKNOWN classification.

**Already hardened or safe retained (29):**

`admin_create_event_v2`, `admin_list_event_registrations_v1`,
`admin_list_events_v1`, `admin_set_event_active_v2`, `admin_update_event_v2`,
`approve_event_registration`, `cancel_event_registration`,
`cancel_reservation`, `confirm_event_reserve_promotion`,
`create_reservation_v2`, `get_check_in_reservation_v1`,
`get_lane_booking_busy_ranges`, `get_lane_booking_busy_ranges_v2`,
`get_lane_booking_busy_ranges_v3`, `get_my_event_registrations_v1`,
`get_my_reservations_v2`, `get_public_check_in_status_v1`,
`get_public_event_availability_v1`, `get_public_event_list_v2`,
`get_reservation_customer_profiles_v1`, `mark_event_registration_paid`,
`register_for_event`, `update_reservation_admin_note`,
`update_reservation_attendance`, `update_reservation_payment`,
`get_my_tenant_role_v1`, `has_tenant_role_v1`,
`is_active_public_tenant_v1`, `is_tenant_member_v1`.

**9D-2C (5):** the five exact signatures in section 29.1.

**9D-3 lane/block/configuration (13):**

`admin_create_lane_block`, `admin_create_lane_booking_family_v1`,
`admin_get_lane_booking_configuration_v1`,
`admin_get_lane_booking_configuration_v2`,
`admin_set_lane_block_active`, `admin_set_lane_booking_configuration`,
`admin_set_lane_booking_family_configuration_v2`, `admin_update_lane_block`,
`lane_booking_family_business_snapshot_v2`,
`normalize_lane_booking_family_payload_v2`,
`validate_lane_booking_rule_capacity`,
`validate_shooting_lane_capacity_change`,
`validate_shooting_lane_hierarchy`.

**9D-4 / 9E reports, profiles, lifecycle and authorization (19):**

`admin_get_reservation_report_export_v1`,
`admin_get_reservation_report_v1`, `admin_get_reservation_report_v2`,
`admin_list_users_v1`, `admin_set_user_note_v1`, `admin_set_user_role_v1`,
`anonymize_my_account_v1`, `export_my_data_v1`, `get_my_role`,
`get_public_booking_configuration_v1`, `handle_new_user`, `is_admin`,
`is_admin_or_employee`, `is_admin_or_staff`,
`prevent_non_admin_profile_privilege_changes`, `update_my_profile_v1`,
`update_profile_contact_details`, `update_profile_identity`,
`update_profile_verification`.

**9D-5 / 9E retirement or bridge gate (7):**

`active_single_tenant_id_v1`, the owner-only legacy
`admin_create_event`, `admin_set_event_active`, `admin_update_event` and
`create_reservation`, plus `sync_csk_membership_role_to_profile` and
`sync_profile_role_to_csk_membership`.

After converting three 2C service functions to invoker, the projected count
is 70. Later counts may change only in their assigned reviewed phase.

### 29.13 Temporary CSK defaults

All 7/7 compatibility defaults remain and are not removed in 2C planning.

| Table | Current active writers | Tenant-aware now? | Still depends on default? | Target removal gate |
|---|---|---:|---:|---|
| `shooting_lanes` | lane-family/configuration writers | no; 9D-3 pending | yes | 9D-5 after 9D-3 production proof |
| `reservations` | hardened `create_reservation_v2` | yes, explicit tenant | no active V2 dependency | 9D-5 after legacy retirement verification |
| `lane_blocks` | lane-block writers | no; 9D-3 pending | yes | 9D-5 after 9D-3 production proof |
| `events` | hardened event V2 create/update | yes, explicit tenant | no active V2 dependency | 9D-5 after 2C and 9D-3/4 gates |
| `event_lanes` | hardened event V2 create/update | yes, explicit event tenant | no active V2 dependency | 9D-5 |
| `event_registrations` | hardened register/promotion contracts | registration owner writers are explicit; promotion updates existing rows | no new-row 2C dependency | 9D-5 after event domain proof |
| `email_deliveries` | `prepare_confirmation_email` | **not yet** | **yes** | 9D-5 only after 2C-1 production proof |

The mandatory gate remains: **REMOVE DEFAULT BEFORE TENANT-AWARE WRITER
CUTOVER AND BEFORE SECOND TENANT**.

### 29.14 Proposed split, implementation order and tests

#### SAAS-9D-2C-1 — shared confirmation delivery

1. freeze all three shared function definitions/ACL plus delivery constraints;
2. fail preflight on any unknown/orphan/mismatched delivery;
3. harden `prepare_confirmation_email` with resource tenant, membership and
   explicit delivery tenant;
4. convert/harden `complete_confirmation_email` as service-only invoker;
5. preserve `check_confirmation_email_rate_limit` exactly;
6. add focused owner/staff/cross-tenant/claim/concurrency tests;
7. run every reservation/event email, SEC-006, SEC-009 and SEC-015 regression;
8. run full DB, Node, TypeScript, build, focused Playwright and diff checks.

Expected migration: one new 2C-1 SQL migration and one focused SQL test. No
application change is expected.

#### SAAS-9D-2C-2 — reserve promotion claims

1. freeze both promotion functions, event/registration constraints and the
   manual/cancellation caller contracts;
2. harden both functions with explicit tenant consistency and convert them to
   service-only invokers;
3. replace the manual route's global role lookup with event-derived active
   admin/employee membership;
4. keep the cancellation path bound to the event ID returned by the hardened
   cancellation RPC;
5. add deterministic parallel prepare/complete/cancellation tests and IDOR
   tests;
6. run all 2A/2B/event availability/public DTO, email, reservation and
   operational Playwright regressions;
7. deploy DB first and APP immediately afterward under a separate approved
   coordinated rollout, then run postflight.

Expected files: one 2C-2 SQL migration, focused SQL test,
`app/api/send-event-reserve-promotion/route.ts` and its focused Node tests.
`lib/server/event-reserve-promotion.ts` should change only if tests prove an
additional server-side tenant assertion is required; its public helper
signature should otherwise remain stable.

### 29.15 Rollback

- Every migration freezes normalized production fingerprints, exact overload
  count, owner, search path and grants and aborts on drift.
- Database rollback is a reviewed forward migration restoring only the
  previous bodies/security modes/paths/grants for that slice; never use
  migration repair or edit an applied migration.
- 2C-1 signatures are backward-compatible, so application rollback is not
  required.
- After 2C-2 DB-first deployment, the old app remains functional while the
  single-active guard is enforced. If the app deployment fails, keep Tenant B
  blocked and either retry the app or deploy the reviewed forward DB rollback.
- The new manual-route precheck is compatible with the old DB; rolling the app
  back after the new DB does not break signatures but reopens the route-level
  authorization gap until restored.
- Never roll back tenant columns, memberships, composite FKs, the active
  tenant guard or completed 9D-1/2A/2B work.

STOP conditions are fingerprint/ACL drift, unknown delivery type, orphan or
tenant mismatch, active claim that cannot be reconciled, global-role-only
authorization, widened grant, cross-tenant allow, duplicate send/promotion,
capacity regression, PII/secret leak, nonzero fixture or any extra pending
migration.

### 29.16 SEC-004 impact and residual work

2C closes the remaining event-domain service claim boundaries: typed email
delivery tenant ownership, exact delivery completion, tenant-filtered reserve
claim creation/completion and manual promotion authorization. It completes
the planned 9D-2 event/shared scope.

It does not close SEC-004. Remaining work stays assigned to:

- 9D-3: lane, block and lane-configuration definers;
- 9D-4: reports, users/profiles, account lifecycle and global role helpers;
- 9D-5: legacy function/default/CSK bridge retirement and final definer audit;
- 9E: trusted selected-tenant application context and routing;
- 9F: reports/events/calendar/check-in selected-tenant cutover;
- 9G: full application cross-tenant IDOR and concurrency suite;
- 9H: SEC-004 closure and second-tenant readiness decision.

### 29.17 Blocking decisions and final gate

No unresolved business decision blocks local 2C-1. Its tenant derivation,
owner/staff roles, delivery types and compatibility contract are explicit.

Local 2C-2 is also implementation-ready provided its approved scope includes
the narrowly required manual-route authorization change described above. No
new RPC, tenant selector or browser tenant argument is needed. Production
deployment remains separately gated per slice and 2C-2 requires coordinated
DB/application approval.

SAAS-9D-2C TECHNICAL PLAN: **READY**

READY FOR SAAS-9D-2C LOCAL IMPLEMENTATION: **GO**

READY FOR PRODUCTION WRITE: **NO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## 28. SAAS-9D-2B-2 local implementation result

SAAS-9D-2B-2 was implemented locally in the single migration
`20260913150000_harden_public_event_readers.sql`. The approved wrapper/core
design is now concrete:

- `get_public_event_availability_v1()` and
  `get_public_event_list_v2(text,text,integer,integer)` retain their exact
  signatures, defaults, stable 13-field public DTO and anon/authenticated
  grants;
- each wrapper resolves only `active_single_tenant_id_v1()` and calls one
  owner-only `SECURITY INVOKER` core;
- both cores independently filter `events` and `event_registrations` by the
  resolved tenant and join counts on both tenant and event ID;
- zero or multiple active tenants return a safe empty public result, while
  invalid list input still returns `invalid_input`;
- no application caller, route, parser, writer, RLS policy, temporary CSK
  default or unrelated RPC changed.

The focused rollback-only SQL suite passed 40/40 checks across Tenant A and
Tenant B, including one-active A, one-active B, zero-active, two-active,
Event A plus Registration B, Event A plus Lane B, canonical count semantics,
anon parity, exact DTO/PII allowlisting, pagination, filters and stable sort.
The full database suite passed 892/892 checks after updating three historical
test assertions that intentionally described the pre-2B-2 function inventory,
global-reader boundary and wrapper fingerprints. All 734 Node tests,
TypeScript, the production build, Events Playwright 8/8 and lane-family/admin
Playwright 5/5 passed. Local fixture post-check was zero for tenants, events,
registrations, lanes and memberships.

Migration SHA-256:
`9E2E1A8530CCFB1A17AC5926F22E885033D0957788B0A27776637A82B35293DD`.

SAAS-9D-2B-2 LOCAL: **PASS**

READY FOR SAAS-9D-2B-2 PRODUCTION PREFLIGHT: **GO**

READY FOR PRODUCTION WRITE: **NO**

READY FOR SAAS-9D-2C: **NO-GO until review**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

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

All touched functions remain owned by `postgres`. Every body-redefined function uses explicit `SET search_path = pg_catalog, public, pg_temp` and schema-qualified objects/functions. The three legacy admin event functions are ACL-only in 9D-2B-1 and retain their production baseline `search_path = public, pg_temp`; any future path hardening requires a separate reviewed change. No EXECUTE grant is widened.

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

## 26. SAAS-9D-2B-1 local implementation record

SAAS-9D-2B-1 was implemented locally on 2026-09-13. The active, signature-compatible wrappers are `admin_create_event_v2`, `admin_update_event_v2`, `admin_set_event_active_v2` and `admin_list_events_v1`. They now require active tenant membership roles, derive tenant from the event where available, use the approved exact-single-active bridge only for contextless create/list, reject mixed-tenant lanes and keep the frozen business implementations in inaccessible `SECURITY INVOKER` cores.

The zero-caller legacy `admin_create_event`, `admin_update_event` and `admin_set_event_active` signatures are owner-only after service-role grant cleanup. This cleanup is ACL-only: their bodies, signatures, owners and production `search_path = public, pg_temp` remain unchanged. Public availability/list readers are unchanged and explicitly deferred to 2B-2.

Verification: focused SQL 32/32, full DB 29 files/852 tests, cross-writer 52/52 deterministic plus 50/50 stress with zero concurrency errors, Node 734/734, TypeScript/build PASS and focused Playwright 14/14. Fixture remaining is zero. Full evidence is in `SAAS_9D_2B1_EVENT_MANAGEMENT_RPC_HARDENING_REPORT.md`.

SAAS-9D-2B-1 LOCAL: **PASS**

READY FOR SAAS-9D-2B-1 PRODUCTION PREFLIGHT: **GO**

READY FOR SAAS-9D-2B-2: **NO-GO until review**

READY FOR PRODUCTION WRITE: **NO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## 27. SAAS-9D-2B-2 — PUBLIC EVENT READERS FINAL PLAN

This section is the implementation-ready technical plan only. It creates no migration, changes no application code and authorizes no database write. SAAS-9D-2B-1 is closed in production at checkpoint `6cd29ab` before this plan begins.

### 27.1 Exact scope

Only these public read contracts are in scope:

1. `public.get_public_event_availability_v1()`
2. `public.get_public_event_list_v2(text,text,integer,integer)`

The local implementation should introduce an inaccessible `SECURITY INVOKER` core for each contract and recreate the exact public signature as a small tenant-resolving `SECURITY DEFINER` wrapper. No event writer, registration writer, admin reader, UI component, RLS policy, table ACL, compatibility default or tenant-routing mechanism is changed in 2B-2.

### 27.2 Current function inventory

| Function | Exact signature | Return contract | SECURITY DEFINER | Current tenant source | Current tenant filtering | Owner | Search path |
|---|---|---|---|---|---|---|---|
| availability | `public.get_public_event_availability_v1()` | 13-column table | yes, stable | none | none; all active events are eligible | `postgres` | `pg_catalog, public, pg_temp` |
| list | `public.get_public_event_list_v2(text,text,integer,integer)` | JSONB contract v2 | yes, stable | none | none; filters only active/search/scope | `postgres` | `pg_catalog, public, pg_temp` |

Current grants for both signatures are identical:

- `PUBLIC`: no `EXECUTE`;
- `anon`: `EXECUTE`;
- `authenticated`: `EXECUTE`;
- `service_role`: no `EXECUTE`.

These grants must remain exact. No direct table grant or RLS policy is widened.

### 27.3 Caller inventory and compatibility

Runtime callers:

- `app/events/page.tsx` calls `get_public_event_list_v2` with `p_search`, `p_scope='upcoming'`, `p_page` and `p_page_size=20`.
- `lib/event-read-contracts.ts` parses the outer v2 JSONB envelope and pagination.
- `lib/public-event-availability.ts` enforces the exact 13-key item DTO and capacity invariants.
- There is no direct application/runtime caller of `get_public_event_availability_v1()` at current HEAD. It remains an externally callable public contract and an authoritative regression surface.

Test and contract callers include:

- `supabase/tests/20260905120000_add_public_event_availability_v1_test.sql`;
- `supabase/tests/20260905190000_add_scalable_event_read_contracts_test.sql`;
- `supabase/tests/20260911100000_tenant_aware_events_rls_test.sql`;
- `supabase/tests/20260912100000_harden_event_registration_rpcs_test.sql`;
- `supabase/tests/20260913100000_harden_event_management_rpcs_test.sql`;
- `lib/public-event-availability.test.mjs`, `lib/event-read-contracts.test.mjs`, `app/events/events-ux.test.mjs` and `tests/e2e/events-responsive.spec.ts`.

Both public signatures, parameter defaults, item keys, list envelope, pagination/filter behavior and status/capacity semantics remain unchanged. No `tenant_id` argument is added, so no UI change is required. Until 9E provides trusted routing, the active-single-tenant bridge is the compatibility mechanism.

Compatibility matrix:

| State | Result |
|---|---|
| old app + old DB | current behavior |
| old app + new DB | safe; identical signatures and DTOs, tenant-bounded result |
| new app + old DB | not applicable to this DB-only phase; current app requires no change |
| current app + new DB | safe for exact-one-active CSK runtime |

Deployment model after local and production preflight PASS: **DB FIRST / DB ONLY**.

### 27.4 Current data paths and risk

`get_public_event_availability_v1()` currently:

- aggregates every non-null `event_registrations.event_id`;
- counts `registered` and `approved` as occupied;
- counts `reserve` separately;
- joins counts to every active event by global `event_id`;
- clamps `available_spots` to zero and derives `sold_out`.

`get_public_event_list_v2(...)` currently:

- builds the active/search/scope-filtered event set globally;
- paginates before counting registrations;
- counts `registered` and `approved` as occupied and `reserve` separately for page event IDs;
- returns a bounded v2 JSONB envelope with maximum page size 50.

Neither function currently reads `event_lanes` or `shooting_lanes`, so lane data is not part of the public DTO. The database already enforces `(tenant_id,event_id)` consistency for `event_registrations` and `(tenant_id,event_id)/(tenant_id,lane_id)` consistency for `event_lanes`; nevertheless, the new cores must include explicit tenant predicates rather than rely only on globally unique IDs or composite FKs.

Current cross-tenant exposure risk is **HIGH once another tenant becomes active**: both definers bypass caller RLS and currently select globally. Current single-active CSK exploitability remains bounded by the second-active-tenant guard, but this is not sufficient for 9E/second-tenant readiness.

### 27.5 Tenant resolution and bridge behavior

The wrappers resolve tenant only through:

```text
public.active_single_tenant_id_v1()
```

The helper already returns an ID only when exactly one tenant has `status='active'`; otherwise it returns `NULL`. It is owner-only, `postgres`-owned, stable, SP1 and must not receive a public grant.

Required public behavior:

| Active tenants | Availability | List v2 |
|---|---|---|
| exactly one A | rows for A only | `ok=true`, items/total for A only |
| exactly one B | rows for B only | `ok=true`, items/total for B only |
| zero | empty result set | contract-compatible `ok=true`, `items=[]`, `pagination.total=0` |
| more than one | empty result set | contract-compatible `ok=true`, `items=[]`, `pagination.total=0` |

Invalid list inputs continue to return `{"ok":false,"code":"invalid_input"}` before any empty-result success is produced. No arbitrary `LIMIT 1`, oldest/newest tenant selection, CSK constant fallback, membership requirement or browser-supplied tenant ID is allowed.

The production partial unique index normally prevents two active tenants. The `>1` path is still tested locally inside a rollback-only fixture that temporarily exercises the resolver invariant and restores the guard before rollback; it is never tested by weakening production.

### 27.6 Proposed wrapper/core design

Availability:

- public wrapper retains signature `()` and exact table return columns;
- wrapper resolves `v_tenant_id` and returns zero rows when it is null;
- inaccessible core accepts one internal UUID tenant argument;
- core filters `events.tenant_id = p_tenant_id`;
- registration aggregation filters `event_registrations.tenant_id = p_tenant_id` and joins on the tenant-consistent event.

List:

- public wrapper retains `(text,text,integer,integer)` and all defaults;
- wrapper resolves one active tenant and calls an inaccessible core with the tenant UUID plus the four existing arguments;
- core preserves validation, search, scope, Warsaw-time comparison, stable ordering, page bounds and outer JSONB contract;
- `filtered` includes `events.tenant_id = p_tenant_id`;
- page registration counts include both `registration.tenant_id = p_tenant_id` and page event IDs;
- valid requests with a null resolved tenant return the exact empty v2 envelope rather than leaking an internal error.

Both cores must be `SECURITY INVOKER`, `postgres`-owned, SP1 and have no `EXECUTE` for `PUBLIC`, `anon`, `authenticated` or `service_role`. Both public wrappers remain stable `SECURITY DEFINER`, `postgres`-owned and SP1 with the existing anon/authenticated-only grants. The total public-schema `SECURITY DEFINER` count therefore remains unchanged.

Direct conversion of the public functions to `SECURITY INVOKER` is not recommended in 2B-2: anon does not have the protected table access needed to count registrations, and granting it would expand the trust boundary. It can be reconsidered only with a separate PII-free view/read-model design.

### 27.7 Public DTO and PII inventory

The exact availability row and each list item remain:

1. `event_id`
2. `title`
3. `description`
4. `event_date`
5. `start_time`
6. `end_time`
7. `location`
8. `price`
9. `max_participants`
10. `registered_count`
11. `reserve_count`
12. `available_spots`
13. `sold_out`

The list envelope additionally contains only `ok`, `code`, `contract_version`, public filters, pagination and `items`.

Forbidden output remains: registration IDs, user IDs, membership IDs/roles, profile data, names of participants, email, phone, address, permit/declaration data, payment/customer fields, registration tokens, promotion/confirmation/check-in tokens, admin notes, audit data and tenant membership internals. `event_id` is intentionally public because registration and event selection require it; `tenant_id` is not added to the DTO in this bridge phase.

### 27.8 Join consistency and authoritative semantics

The tenant predicate must appear independently on the event base and registration aggregate. Registration status semantics remain exact:

- `registered`, `approved`: occupy capacity;
- `reserve`: counted separately and does not occupy capacity;
- `cancelled` and every other non-occupying state: excluded from both counts.

`available_spots = greatest(max_participants - registered_count, 0)` and `sold_out = registered_count >= max_participants` remain unchanged.

`event_lanes` and `shooting_lanes` remain outside both reader queries and DTOs. Tests must nevertheless create Event A with Lane A and a Tenant B lane/relation to prove that no lane relationship introduces a cross-tenant public row. An attempted Event A + Lane B relation must continue to fail under the existing composite tenant FK.

### 27.9 Fingerprint baseline and migration guards

Normalized production fingerprints use `CRLF / CR -> LF` before MD5:

| Function | Production normalized full-definition MD5 |
|---|---|
| `public.get_public_event_availability_v1()` | `40adf74cb5adec5df3b4745fc7851433` |
| `public.get_public_event_list_v2(text,text,integer,integer)` | `fe075d7057149b0a0bad0129419a3e99` |

Implementation preconditions must fail closed unless:

- both exact signatures exist once and match these fingerprints;
- both are stable `SECURITY DEFINER`, owned by `postgres`, with SP1;
- grants are exactly anon/authenticated `EXECUTE`, with none for `PUBLIC` or `service_role`;
- `active_single_tenant_id_v1()` exists with its reviewed owner/path/ACL;
- `events.tenant_id` and `event_registrations.tenant_id` are non-null;
- validated composite tenant/event FKs and the single-active guard exist;
- 2B-1 active/legacy event RPC fingerprints and ACLs have not drifted;
- no unexpected pending migration or function overload exists.

Postflight repeats the catalog, ACL, path, owner, signature, definer-count, core-isolation and public DTO checks. Any mismatch aborts the migration transaction.

### 27.10 Cross-tenant and public test matrix

Focused SQL tests use Tenant A and dormant Tenant B with synthetic events, lanes and registrations:

1. one active Tenant A: anon and authenticated list return only A;
2. one active Tenant A: availability returns only A;
3. switch the exact active tenant to B: both contracts return only B;
4. zero active tenants: availability is empty; valid list is a successful empty envelope;
5. two active tenants in a local rollback-only guard fixture: both contracts fail closed as empty;
6. Event A plus Lane B is rejected and cannot create a public row;
7. Tenant B registrations do not affect Event A counts;
8. A and B may use identical-looking titles/dates without count bleed;
9. anon and authenticated receive identical public results;
10. no-auth REST/RPC access remains allowed;
11. `registered` and `approved` occupy capacity; `reserve` is separate; `cancelled` does not occupy;
12. sold-out clamps at zero and never becomes negative;
13. search, upcoming/all scope, Warsaw time, stable ordering, page 1/page 2, beyond-last page and max page size 50 remain exact;
14. invalid page/scope/search remain `invalid_input`;
15. all response keys match the PII-free allowlist and forbidden strings/values are absent;
16. wrapper cores cannot be called by any client role;
17. `PUBLIC`, `anon`, `authenticated`, `service_role` grants remain exact;
18. 2A registration, cancellation and promotion update availability without cross-tenant effects;
19. 2B-1 create/edit/activate/list regression remains PASS;
20. overbooking remains prevented by the authoritative writer, not by the display reader.

### 27.11 Regression and operational verification

Required local verification after a separately approved implementation:

- fresh local database reset;
- focused 2B-2 SQL suite;
- tenant-aware Events RLS and event-registration privacy suites;
- 2A and 2B-1 focused regression suites;
- full Supabase DB suite;
- all Node tests;
- TypeScript and production build;
- focused `/events` Playwright tests for public list, search, pagination, empty/error/retry and mobile layouts;
- anon/authenticated REST contract smoke;
- `git diff --check` and zero synthetic fixture.

Production preflight remains separate: exact migration SHA, LOCAL/REMOTE history, only-one-pending dry-run, frozen production fingerprints, tenant/data invariants, lock check and explicit deployment approval. Production postflight uses read-only catalog checks plus a rollback-only two-tenant fixture; it performs no persistent second-tenant activation.

No new index is planned initially. The existing tenant/event integrity, `events_tenant_active_schedule_idx`, event registration indexes and bounded page query are retained. Local `EXPLAIN` must confirm no material regression; any proposed additional index is a scope change requiring review before implementation.

### 27.12 Temporary defaults and application scope

2B-2 is read-only and does not use, add or remove any of the seven temporary CSK `tenant_id` defaults. Default removal remains gated before tenant-aware writer cutover and before a second tenant. No route, UI, parser or generated client type change is expected because signatures and DTOs remain stable.

### 27.13 Rollback

Rollback is a reviewed forward migration that restores the two exact pre-2B-2 production function definitions, owners, SP1 paths and grants from the frozen baselines. It removes only the new inaccessible cores after restoring the public functions. It must not remove tenant columns, constraints, indexes, memberships, the single-active guard or any 2A/2B-1 work.

Because the phase is DB-only and signature-compatible, an application rollback is not required. STOP conditions are fingerprint drift, unexpected caller/overload, public PII, tenant bleed, changed status/capacity semantics, widened ACL, changed `SECURITY DEFINER` inventory, nonzero fixture or any additional pending migration.

### 27.14 SEC-004 impact and final gate

2B-2 removes the remaining global public event-read path for the two named readers and makes them fail closed when the bridge cannot resolve exactly one tenant. It does not close SEC-004 because selected tenant routing, remaining RPC families, application context, operational cutover and full cross-tenant verification remain in 9D-2C through 9H.

No unresolved business decision blocks local implementation. The bridge behavior, unchanged signatures/DTOs/grants, explicit tenant predicates and zero/one/many behavior are fully specified. Implementation still requires a separate explicit approval.

SAAS-9D-2B-2 TECHNICAL PLAN: **READY**

READY FOR SAAS-9D-2B-2 LOCAL IMPLEMENTATION: **GO**

READY FOR PRODUCTION WRITE: **NO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## 31. SAAS-9D-2C-2 — EVENT RESERVE PROMOTION RPC HARDENING FINAL PLAN

This section supersedes the preliminary 2C-2 rollout notes in sections 29.9,
29.14 and 29.15 where they conflict with this final plan. It is planning-only
and is based on the production state after the successful 2C-1 deployment and
the reproducible checkpoint `8c781b2c67233f865407abe1318534f57ef86040`.
No migration, application change, SQL write or deployment is authorized by
this section.

### 31.1 Exact scope and production inventory

The implementation boundary contains exactly two existing database functions
and one mandatory server-route authorization correction. It does not include
the public confirmation RPC, event registration writers, public event readers,
shared confirmation-email functions or any 9D-3/4/5 function.

| Function | Exact signature and result | Current callers | SQL-to-SQL callers | Current security metadata | Current arguments / token | Current tenant and authorization model | RLS bypass / risk |
|---|---|---|---|---|---|---|---|
| `prepare_event_reserve_promotions` | `(p_event_id uuid) RETURNS TABLE(registration_id uuid, claim_id uuid, promotion_token text, promotion_token_expires_at timestamptz, token_reused boolean)` | `lib/server/event-reserve-promotion.ts`; indirectly the manual promotion route and the successful cancellation route | none | volatile, SECURITY DEFINER, owner `postgres`, SP2 `public, pg_temp`; only `service_role` EXECUTE | event argument yes; generated token and claim returned; no registration argument | service credential is the present execution gate; event tenant can be derived from `events.tenant_id`; the manual route still uses global `profiles.role` | bypasses RLS and currently filters by global event ID without explicit tenant predicates; CRITICAL |
| `complete_event_reserve_promotion` | `(p_registration_id uuid, p_claim_id uuid, p_success boolean, p_error_code text DEFAULT NULL) RETURNS jsonb` | `lib/server/event-reserve-promotion.ts` after each provider outcome | none | volatile, SECURITY DEFINER, owner `postgres`, SP2 `public, pg_temp`; only `service_role` EXECUTE | registration and claim arguments yes; no token/event/tenant argument | exact claim is checked on the supplied registration; tenant is only implicit in registration/event rows; service credential is not business authorization | bypasses RLS and does not explicitly re-prove registration/event tenant equality; CRITICAL |

Effective EXECUTE is currently and must remain: PUBLIC **no**, anon **no**,
authenticated **no**, service_role **yes**. Both functions exist exactly once.
The service path uses `NEXT_PUBLIC_SUPABASE_URL` plus the server-only
`SUPABASE_SERVICE_ROLE_KEY`; it does not persist or refresh a browser session.
Neither function accepts a caller-controlled tenant ID.

### 31.2 Caller and authorization inventory

| File / caller | Caller type | Auth context | Tenant context | Resource context and current arguments | Application change required |
|---|---|---|---|---|---|
| `app/api/send-event-reserve-promotion/route.ts` | manual authenticated POST | bearer JWT is verified with `getUser`; authorization then reads global `profiles.role` and accepts `admin`/`pracownik` | absent before the service call | browser supplies only `eventId`; route calls `promoteEventReserve(eventId)` | **yes**: use authenticated DB context to resolve the event tenant and require an active membership role `admin` or `employee`; global profile role alone must deny |
| `app/api/cancel-event-registration/route.ts` | owner/staff cancellation POST with automatic follow-on | the hardened `cancel_event_registration` RPC authenticates and authorizes the actor | the successful RPC derives registration -> event -> tenant | promotion is attempted only when the controlled result says `changed=true` and `freed_participant_place=true`; helper receives the returned `event_id`, not authority supplied separately by the browser | no request-contract change; retain this provenance and add regression assertions |
| `lib/server/event-reserve-promotion.ts` | server-only orchestrator | service client only after a caller boundary has authorized the operation | prepare must derive tenant from event; returned registration/claim pairs remain the completion capability | calls prepare with `p_event_id`; calls complete with registration ID, claim ID, success and bounded error code; reads event and recipient fields from DB and sends via Resend | preserve exported helper and RPC signatures; add tenant assertions only if focused tests show the server read step cannot remain bound to the prepared IDs |

There is no cron, background worker or SQL-to-SQL caller. Test and report
references are not runtime callers. The service helper is an infrastructure
boundary, not proof that the initiating user may operate on the event.

The manual route target authorization sequence is:

1. verify the bearer JWT and derive `auth.uid()`;
2. resolve the event and its `tenant_id` through the authenticated client;
3. require an active membership in that exact tenant;
4. allow only tenant roles `admin` or `employee`;
5. pass only the already-authorized event ID into the server helper.

`ADMIN_A` and `EMPLOYEE_A` may trigger Event A. They must be denied for Event
B. A global legacy admin/pracownik without an active Event-B membership,
pending or suspended membership, no membership, user and instructor all deny.
No query string, request body, profile role or service credential may replace
the membership check.

### 31.3 Flow state machine and state transitions

The current business flow, which tenant hardening must preserve, is:

1. **Prepare starts:** validate non-null event ID; lock the event row.
2. **Capacity gate:** count `registered` + `approved`; if the count is at or
   above `max_participants`, return an empty set without claim or email work.
3. **Candidate scan:** select `reserve` rows in `created_at,id` FIFO order,
   excluding a still-active claim and excluding a valid token whose email has
   already been recorded as sent.
4. **Token decision:** reuse a still-valid, unsent token or generate a new UUID
   token valid for 24 hours.
5. **Claim:** generate a claim UUID valid for 10 minutes, increment attempt
   count, set last-attempt time, clear the previous bounded error, and return
   the registration/claim/token tuple.
6. **Recipient and template:** the server reads event data and each claimed
   registration's stored recipient/name, escapes dynamic HTML and constructs
   the public confirmation link. The browser cannot supply recipient, name,
   token or content.
7. **Provider failure:** complete with `success=false`; exact claim is cleared,
   the bounded technical error code is stored and no sent timestamp is added.
8. **Provider success:** complete with `success=true`; `promotion_email_sent_at`
   is set once and the exact claim/error state is cleared.
9. **Retry:** a completion retry after the claim was cleared is a no-change
   controlled result when the requested outcome is already represented;
   mismatched or inactive success claims fail closed.
10. **Public confirmation is separate:**
    `confirm_event_reserve_promotion(text)` authenticates the owner and
    atomically locks/rechecks event capacity before changing `reserve` to
    `registered`. It remains outside this migration and must retain its 9D-2A
    fingerprint and behavior.

Prepare intentionally may notify multiple FIFO reserve candidates while at
least one place is free. Email copy and the existing product rule are
first-successful-confirmation wins. 2C-2 must **not** reinterpret this as one
exclusive prepared claim per free slot. Capacity is protected by the final
confirmation RPC, not by the number of emails prepared.

### 31.4 Tenant derivation and database target bodies

Tenant authority is always resource-derived:

- prepare: `p_event_id -> events.tenant_id`;
- completion: `p_registration_id -> event_registrations.tenant_id` and
  `event_registrations.event_id -> events.tenant_id`;
- claim/token: claim is stored on the registration, which must join its event
  on both event ID and tenant ID.

Target `prepare_event_reserve_promotions` behavior:

- lock the event and capture its non-null tenant;
- apply both `event_id` and `tenant_id` to occupied-count and reserve-candidate
  queries;
- keep the existing statuses, capacity gate, FIFO ordering, token reuse,
  24-hour token TTL, 10-minute claim TTL and response columns unchanged;
- update each candidate by registration ID + event ID + tenant ID and fail
  closed if the locked candidate no longer matches;
- remain service-only, become SECURITY INVOKER and use SP1
  `pg_catalog, public, pg_temp`.

Target `complete_event_reserve_promotion` behavior:

- lock the registration and its event with an exact
  `(event_id, tenant_id)` relationship;
- require non-null, equal registration/event tenants and the exact current
  claim before any changed update;
- update by registration ID + event ID + tenant ID + claim ID;
- preserve validation of `p_success` and the bounded lower-case error-code
  contract, the JSON keys/types, no-change retry behavior and sent timestamp
  idempotency;
- remain service-only, become SECURITY INVOKER and use SP1.

The completion RPC does not receive the email address and therefore cannot
prove the provider recipient independently. Recipient binding remains the
server data-flow invariant: the address is read from the same claimed
registration ID returned by prepare, is never accepted from the request, and
completion binds the outcome to that registration and exact claim. No API
response adds email, user ID, token, claim metadata or participant PII.

### 31.5 Token, claim, status and replay security

The focused contract must deny or return a controlled no-change result for:

- null/invalid registration or claim IDs;
- claim from another registration, event or tenant;
- expired/stale/replaced claim;
- inactive claim that does not match an already-recorded idempotent outcome;
- a token/claim replay after successful completion;
- a claimed row whose event relationship or tenant equality is broken;
- a registration outside the canonical `reserve` candidate set during
  prepare.

Token lookup and public confirmation continue to return stable business
codes without enumeration or extra PII. Tenant hardening does not change
token format, expiry, recipient, email copy, registration statuses or public
confirmation response.

Completion records delivery outcome; it does not promote a participant or
consume capacity. If completion races with event/registration cancellation,
row locks must serialize the writes, record an actual provider success at
most once, clear only the matching claim and never restore an eligible status.
The already-hardened confirmation RPC remains the sole capacity-changing
transition, so cancellation winning the race leaves the token unusable and
capacity uncorrupted. This preserves current business semantics rather than
inventing a new cancellation transition in 2C-2.

### 31.6 Capacity, ordering and concurrency tests

Required deterministic database/concurrency coverage:

| Race / invariant | Expected result |
|---|---|
| two prepare calls for one event | event/registration row locks serialize; a candidate has at most one active claim; duplicate claims for one registration = 0 |
| two reserve candidates and one free place | candidates are prepared in stable FIFO order as today; final public confirmations still allow only capacity-valid transitions |
| same claim completed twice with success | sent timestamp is recorded once; second completion is controlled no-change; duplicate provider effect is prevented by the server claim protocol |
| success and failure completion for one claim | exact row lock/claim predicate permits one changed completion; the loser cannot overwrite the recorded outcome |
| complete versus event cancellation/deactivation | no cross-tenant write, no status restoration, no broken event capacity; existing event-management semantics remain authoritative |
| complete versus registration cancellation | serialized, no status restoration, at most one sent record, cancelled token cannot promote |
| retry after provider/partial failure | claim is safely cleared or remains bounded by expiry; retry creates no duplicate active claim and cannot complete a stale claim |
| Event A with Registration/Claim B | deny; zero changed rows in both tenants |

All tests must assert deadlocks = 0, duplicate changed completions = 0,
cross-tenant promotions = 0, negative availability = 0 and fixture remaining
= 0. Provider calls are mocked locally; production preflight/postflight must
not send real email unless separately authorized.

### 31.7 Email side effects and PII

This promotion flow does **not** insert `email_deliveries`. Its outbound intent
and retry state are the token, claim, attempt, error and sent columns on the
existing tenant-owned `event_registrations` row. Consequently:

- `event_registrations.tenant_id` is derived and checked explicitly;
- no compatibility default is used as the security mechanism;
- event/recipient reads must be limited to the exact prepared event and IDs;
- request/API responses keep the current aggregate counts only;
- logs keep operation/stage and bounded safe error metadata only;
- JWT, service key, full token, claim UUID, provider body, email and other PII
  must not be logged or returned.

Existing `escapeHtml`/`escapeEmailHref` use, plain-text behavior, Resend error
normalization and SEC-006 tests remain mandatory regressions.

### 31.8 ACL, owner, search path and invoker decision

| Function | Target mode | Owner | Target search path | PUBLIC | anon | authenticated | service_role |
|---|---|---|---|---:|---:|---:|---:|
| `prepare_event_reserve_promotions(uuid)` | SECURITY INVOKER | postgres | SP1 `pg_catalog, public, pg_temp` | no | no | no | EXECUTE |
| `complete_event_reserve_promotion(uuid,uuid,boolean,text)` | SECURITY INVOKER | postgres | SP1 `pg_catalog, public, pg_temp` | no | no | no | EXECUTE |

Invoker is viable because production confirms service_role already has the
required SELECT/UPDATE table privileges on `events` and
`event_registrations`. The migration must neither widen table ACL nor grant
function EXECUTE to a client role. Owner remains postgres. All object names
and built-ins are schema-qualified.

### 31.9 Fingerprints and mandatory preconditions

Production `pg_get_functiondef` is normalized CRLF/CR -> LF before hashing:

| Signature | Current normalized MD5 |
|---|---|
| `prepare_event_reserve_promotions(uuid)` | `4e73ef1df59936a1a3f41a00e121f6e9` |
| `complete_event_reserve_promotion(uuid,uuid,boolean,text)` | `dd5025876008d6eb9551497d84cef90e` |

The implementation migration must abort before DDL unless both overload
counts, signatures, result types, fingerprints, owner, SP2 path and exact
service-only ACL match this baseline. It must also freeze the 2A, 2B-1,
2B-2 and 2C-1 function fingerprints and the remaining-definer aggregate.

Repeat the production data preflight immediately before deployment and stop
unless: registration/event tenant mismatches = 0, claims outside reserve = 0,
duplicate non-null claim IDs = 0, duplicate non-null tokens = 0, active claims
= 0, stale claims = 0 and all seven compatibility defaults are present.
The verified planning baseline was 25 registrations, one reserve row, zero
active/stale claims, four token rows, four sent rows, two confirmed rows and
zero tenant/claim/token anomalies. These counts are evidence, not hard-coded
migration assertions except for the zero-invariant checks.

Local clean-baseline definitions match the captured production bodies
semantically. Any new drift before implementation is a STOP condition and
requires plan review; it must not be overwritten by a broad `CREATE OR
REPLACE`.

### 31.10 Cross-tenant and authorization matrix

Minimum local SQL/Node coverage:

- Event A + Registration A + Claim A: prepare/complete valid path;
- Event A + Registration B: deny and both tenants unchanged;
- Claim B with Registration A: deny;
- Claim A cannot be used for Event B or a registration whose tenant/event
  pair differs;
- admin A and employee A manual prepare for Event A: allow;
- admin A / employee A manual prepare for Event B: deny;
- global legacy admin/pracownik without active Event-B membership: deny;
- pending, suspended, no-membership, user and instructor: deny privileged
  manual prepare;
- service caller derives Event A tenant and cannot cause a Registration-B
  claim/update through Event A;
- invalid, expired, replaced, replayed and already-completed claim cases are
  fail closed/idempotent as defined above;
- public token confirmation remains owner-bound, PII-free and capacity-safe.

Direct anon/authenticated calls to both service functions must fail at ACL.
Tests must separately show that a service credential can execute only the
resource-bound semantics; service access itself is not counted as business
authorization.

### 31.11 Compatibility and rollout

Function signatures, argument names/default, return table/JSON fields and
server helper calls remain unchanged.

| Combination | Result |
|---|---|
| old app + old DB | current single-tenant behavior; manual global-role gap remains |
| **new app + old DB** | **safe compatibility step**: manual route enforces event-derived membership before invoking unchanged service RPCs; automatic cancellation provenance unchanged |
| old app + new DB | function calls still work, but the old manual route can authorize a global role for another tenant; therefore this state is operationally compatible but **not an accepted completed security state** |
| new app + new DB | target tenant-bound route and tenant-bound invoker functions |

The final rollout recommendation is **APP FIRST, then DB in one controlled
low-traffic release**, not DB-first. Verify the app deployment's membership
gate before applying the migration. Keep the second-active-tenant guard in
force throughout. The phase is complete only after both deployments and
postflight pass.

Expected implementation files:

- one new 2C-2 SQL migration;
- one focused SQL test and one deterministic concurrency harness;
- `app/api/send-event-reserve-promotion/route.ts`;
- a new focused route/server authorization Node test;
- this plan and a 2C-2 implementation report.

`lib/server/event-reserve-promotion.ts` should remain unchanged unless a
focused test proves that an additional exact-ID assertion is required. No
browser contract, UI, selected-tenant routing or public API signature changes.

### 31.12 Regression plan

Run, in order:

1. local database reset from the clean migration chain;
2. focused 2C-2 SQL authorization, tenant, token/claim and state tests;
3. deterministic parallel prepare/complete/cancellation tests;
4. focused Node tests for missing/invalid auth, auth upstream failure,
   admin/employee A allow, foreign tenant/global role/pending/suspended/no
   membership deny and safe responses;
5. all 9D-2A, 2B-1, 2B-2 and 2C-1 SQL tests;
6. reserve registration, cancellation, public confirmation, public event
   availability/list, event management and shared email delivery regressions;
7. full Supabase DB suite and all Node tests;
8. TypeScript, production build, focused Events/operational Playwright,
   changed-files ESLint, `npm audit --omit=dev` and `git diff --check`.

Production preflight must verify the same fingerprint/data/ACL guards and
show only the approved migration pending. Postflight must prove final dry-run
up to date, target fingerprints, SECURITY DEFINER count, no drift, route/runtime
smoke, zero real email unless authorized and zero fixture.

### 31.13 SECURITY DEFINER impact and remaining inventory

Current production count after 2C-1 is **72**. Converting these exact two
functions to SECURITY INVOKER produces an expected count of **70**. No new
wrapper or definer is added. Every remaining definer has an assigned bucket;
there is no UNKNOWN.

**Safe/already hardened or deliberate no-change in 2C-2 (31):**

`admin_create_event_v2`, `admin_list_event_registrations_v1`,
`admin_list_events_v1`, `admin_set_event_active_v2`, `admin_update_event_v2`,
`approve_event_registration`, `cancel_event_registration`,
`cancel_reservation`, `confirm_event_reserve_promotion`,
`create_reservation_v2`, `get_check_in_reservation_v1`,
`get_lane_booking_busy_ranges`, `get_lane_booking_busy_ranges_v2`,
`get_lane_booking_busy_ranges_v3`, `get_my_event_registrations_v1`,
`get_my_reservations_v2`, `get_public_check_in_status_v1`,
`get_public_event_availability_v1`, `get_public_event_list_v2`,
`get_reservation_customer_profiles_v1`, `mark_event_registration_paid`,
`register_for_event`, `update_reservation_admin_note`,
`update_reservation_attendance`, `update_reservation_payment`,
`get_my_tenant_role_v1`, `has_tenant_role_v1`,
`is_active_public_tenant_v1`, `is_tenant_member_v1`,
`prepare_confirmation_email`, `check_confirmation_email_rate_limit`.

**9D-3 lane/block/configuration (13):**

`admin_create_lane_block`, `admin_create_lane_booking_family_v1`,
`admin_get_lane_booking_configuration_v1`,
`admin_get_lane_booking_configuration_v2`,
`admin_set_lane_block_active`, `admin_set_lane_booking_configuration`,
`admin_set_lane_booking_family_configuration_v2`, `admin_update_lane_block`,
`lane_booking_family_business_snapshot_v2`,
`normalize_lane_booking_family_payload_v2`,
`validate_lane_booking_rule_capacity`,
`validate_shooting_lane_capacity_change`,
`validate_shooting_lane_hierarchy`.

**9D-4 / 9E reports, profiles, lifecycle and authorization (19):**

`admin_get_reservation_report_export_v1`,
`admin_get_reservation_report_v1`, `admin_get_reservation_report_v2`,
`admin_list_users_v1`, `admin_set_user_note_v1`, `admin_set_user_role_v1`,
`anonymize_my_account_v1`, `export_my_data_v1`, `get_my_role`,
`get_public_booking_configuration_v1`, `handle_new_user`, `is_admin`,
`is_admin_or_employee`, `is_admin_or_staff`,
`prevent_non_admin_profile_privilege_changes`, `update_my_profile_v1`,
`update_profile_contact_details`, `update_profile_identity`,
`update_profile_verification`.

**9D-5 / 9E retirement and bridge gate (7):**

`active_single_tenant_id_v1`, legacy `admin_create_event`,
`admin_set_event_active`, `admin_update_event`, `create_reservation`,
`sync_csk_membership_role_to_profile`,
`sync_profile_role_to_csk_membership`.

### 31.14 Temporary CSK defaults

All 7/7 defaults stay present. 2C-2 neither consumes nor removes one as an
authorization mechanism.

| Table | Promotion writer/read | Tenant explicitly derived/set? | Default used by this flow? | Removal phase |
|---|---|---:|---:|---|
| `events` | prepare locks/reads event; helper reads event | derived from the existing event row; no insert | no | 9D-5 after all writer/caller gates |
| `event_registrations` | prepare/complete update existing registrations | explicit event + registration tenant equality | no | 9D-5 after event-domain proof |
| `email_deliveries` | none; promotion state is stored on registration | not applicable | no | 9D-5 after 2C-1 proof |
| `shooting_lanes`, `reservations`, `lane_blocks`, `event_lanes` | no 2C-2 writer | unchanged | unchanged | their assigned 9D-3/5 gates |

The mandatory global gate remains: remove compatibility defaults only after
tenant-aware writer cutover and before a second tenant can be activated.

### 31.15 Rollback and STOP conditions

Database rollback is a reviewed **forward migration** restoring only the two
captured function bodies, SECURITY DEFINER modes, SP2 paths, postgres owner
and exact service-only ACL. Never edit an applied migration or use migration
repair. Application rollback before the DB migration returns to the known
old state; after the DB migration it would reopen the manual-route business
authorization gap, so do not roll back the app alone. Prefer forward-fixing
the app or coordinate app + DB rollback while Tenant B remains blocked.

STOP on fingerprint/ACL/owner/path drift, any unexpected overload, tenant
mismatch, claim outside reserve, duplicate claim/token, active or stale claim
at deployment, widened grant/table ACL, service key in client output,
cross-tenant allow, duplicate provider/completion effect, FIFO/capacity/status
regression, PII/token leak, unexpected SECURITY DEFINER drift, nonzero fixture
or any additional pending migration.

### 31.16 SEC-004 impact and final gate

After a future local, production preflight, APP-FIRST deployment, DB deployment
and postflight PASS, SAAS-9D-2C can be marked **CLOSED / PROD PASS**. It will
close the remaining event reserve-promotion service claim boundaries and the
manual route's global-role authorization gap.

It will not close SEC-004. Exact remaining scope is:

- 9D-3: lane, block and lane-configuration functions;
- 9D-4: reports, users/profiles, account lifecycle and legacy authorization;
- 9D-5: legacy functions, seven defaults, CSK sync bridges and final definer
  disposition;
- 9E+: trusted selected-tenant application context and routing, then module
  cutovers;
- 9G: full cross-tenant application IDOR/concurrency proof;
- 9H: SEC-004 closure and second-tenant readiness audit.

There is no unresolved product-semantic decision for local implementation:
existing multi-recipient notification, first-confirmed-wins capacity rule,
FIFO iteration, token TTL, claim TTL, retry responses and cancellation status
behavior are all preserved. The required manual-route membership correction
is explicitly part of the approved implementation boundary.

SAAS-9D-2C-2 TECHNICAL PLAN: **READY**

READY FOR SAAS-9D-2C-2 LOCAL IMPLEMENTATION: **GO**

READY FOR PRODUCTION WRITE: **NO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## 32. SAAS-9D-2C-2 local implementation result (2026-09-14)

The approved event reserve-promotion slice has been implemented and verified locally.

- `POST /api/send-event-reserve-promotion` now derives `events.tenant_id` through the authenticated caller and requires an active tenant membership with role `admin` or `employee` before the existing service helper is invoked. The legacy global `profiles.role` authorization path is removed.
- `prepare_event_reserve_promotions(uuid)` and `complete_event_reserve_promotion(uuid,uuid,boolean,text)` retain their signatures and response contracts, use explicit event/registration/tenant predicates, and have moved from SECURITY DEFINER/SP2 to SECURITY INVOKER/SP1 with exact service-only EXECUTE.
- APP-FIRST compatibility was proven with real local HTTP calls against both the old DB baseline and the migrated DB: valid Tenant-A admin `200`, membership-less legacy admin `403`, cross-tenant/inaccessible event `404`, malformed `400`, unknown `404`.
- Focused SQL passed 36/36; deterministic concurrency passed all six scenarios with zero deadlocks, duplicate final effects, broken invariants, or fixture; full DB passed 972/972; Node passed 739/739; focused Playwright Events passed 8/8 and the full Playwright suite passed 30/30; TypeScript, build, changed-files ESLint, and fixture cleanup passed.
- The expected SECURITY DEFINER inventory is 70, non-target drift is zero, and all 7/7 compatibility defaults remain present.
- Migration SHA-256: `A9373F9BCFBB456624720FB2AFFB94A416C428454B7881E6FB2649F21ED39759`.
- `npm audit --omit=dev` reports one unrelated MODERATE transitive `baseline-browser-mapping` advisory; it is outside this RPC-hardening scope.

Detailed evidence is recorded in `SAAS_9D_2C2_RESERVE_PROMOTION_RPC_HARDENING_REPORT.md`.

SAAS-9D-2C-2 LOCAL: **PASS**

READY FOR SAAS-9D-2C-2 PRODUCTION APP PREFLIGHT: **GO**

READY FOR PRODUCTION WRITE: **NO**

READY FOR SAAS-9D-3: **NO-GO until 2C-2 full production rollout/checkpoint**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## 37. SAAS-9D-3C local implementation result (2026-09-15)

The approved seven-function lane-family writer/helper slice has been implemented
and verified locally. No application file or production resource was changed.

- The active V2 writer keeps its signature and authenticated-only caller
  contract. A minimal SECURITY DEFINER wrapper delegates to a closed SECURITY
  INVOKER core.
- The core derives the tenant from the locked root lane, requires an active
  tenant `admin` membership, validates every family resource against that
  tenant, scopes reservation/block/event dependency checks and the audit row,
  and does not use `profiles.role` as authority.
- Family identifiers are normalized to UUID order before equality comparison.
  This fixes a pre-existing nondeterministic valid-payload rejection exposed by
  randomized full-suite fixtures.
- The dormant legacy writer and the two internal helpers are SECURITY INVOKER
  with no client or service EXECUTE. The three integrity triggers are unchanged.
- SECURITY DEFINER count is `67`, unexpected non-target drift is zero, and all
  `7/7` compatibility defaults remain present.
- Focused pgTAP passed `34/34`; concurrency/IDOR/integrity checks passed with
  zero deadlocks, invalid final states, cross-tenant contamination, or fixture.
  The full DB suite passed `1074/1074`; Node, TypeScript, production build and
  focused Playwright (`5/5`) passed; final local fixture post-check is zero.
- Migration SHA-256:
  `814F648620F04760874A29C1916104E900ADFFE000B19989282078B27F7C4884`.
- `npm audit --omit=dev` retains one unrelated MODERATE advisory in
  `baseline-browser-mapping`; no HIGH or CRITICAL advisory was reported.

Detailed evidence is recorded in
`SAAS_9D_3C_LANE_FAMILY_WRITER_HELPERS_HARDENING_REPORT.md`.

SAAS-9D-3C LOCAL: **PASS**

READY FOR SAAS-9D-3C PRODUCTION PREFLIGHT: **GO**

READY FOR SAAS-9D-4 PLANNING: **NO-GO until 9D-3C production/checkpoint review**

READY FOR PRODUCTION WRITE: **NO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## 39. SAAS-9D-4A local implementation result (2026-09-15)

The approved reservation-report slice has been implemented and verified
locally. Active v2/report export wrappers preserve their signatures and DTOs,
resolve the approved sole active tenant bridge, and authorize exclusively from
an active tenant `admin` membership. A closed SECURITY INVOKER core applies the
tenant predicate before KPI, revenue, occupancy, pagination, resource options,
details, and export calculations. The global `profiles.role` report bypass is
removed. The unused legacy v1 body remains unchanged and its direct EXECUTE is
closed.

Profile administration is not part of 4A; the approved target-user operational
relationship matrix remains a mandatory 4B requirement. Existing reservation
ownership is the operational relationship for customer detail rows returned by
4A. Tenant-leave and account-wide export/anonymization/Auth deletion remain
separate: their functions and fingerprints are unchanged.

Focused SQL passed `33/33`; REPORTS-6A `25/25`; REPORTS-6B `34/34`; the full
function ACL matrix `17/17`; and the full DB suite `1107/1107`. Node passed
`739/739`, TypeScript and production build passed, focused Reports Playwright
passed `5/5`, and synthetic fixture cleanup is zero. SECURITY DEFINER remains
`67`, unexpected drift is zero, and compatibility defaults remain `7/7`.
Migration SHA-256 is
`54D3EE6B3D37D63374F4EBFFD507B89C7797CE6ED0C813F62080BCBDD8408031`.

Detailed evidence is recorded in
`SAAS_9D_4A_ADMIN_RESERVATION_REPORTS_HARDENING_REPORT.md`.

SAAS-9D-4A LOCAL: **PASS**

READY FOR SAAS-9D-4A PRODUCTION PREFLIGHT: **GO**

READY FOR SAAS-9D-4B-1: **NO-GO until review**

READY FOR PRODUCTION WRITE: **NO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## 40. SAAS-9D-4B-1 — FINAL PLAN

Planning baseline: repository and production checkpoint
`44a3d4699d682689757eb1b8985c7a13ed3064ab`. SAAS-9D-4A is closed with
production PASS. This section is planning-only: it creates no migration,
performs no SQL write and authorizes no production change.

### 40.1 Exact scope

9D-4B-1 contains exactly five active profile/user-administration functions.
Verification is deliberately excluded for 9D-4B-2, owner lifecycle for 4C,
legacy authorization/onboarding for 4D/9E, and compatibility retirement for
9D-5.

| Function | Signature | Domain / callers | Current mode, owner, path | Current ACL | Global role check | Target / tenant source | PII and bypass risk | Severity | Disposition |
|---|---|---|---|---|---|---|---|---|---|
| `admin_list_users_v1` | `(integer,integer,text,text,text,text)` | admin users list; `app/admin/users/page.tsx` | DEFINER, `postgres`, SP1 | authenticated | actor `profiles.role=admin` | no target; tenant currently absent | returns broad profile/contact/address/declaration/verification/note DTO across every profile | CRITICAL | A — BODY HARDENING |
| `admin_set_user_role_v1` | `(uuid,text)` | role editor; `app/admin/users/page.tsx` | DEFINER, `postgres`, SP1 | authenticated | actor and target global roles | target user only; target membership must become authority | global privilege mutation, global last-admin count, tenantless audit | CRITICAL | A — BODY HARDENING |
| `admin_set_user_note_v1` | `(uuid,text)` | admin note editor; `app/admin/users/page.tsx` | DEFINER, `postgres`, SP1 | authenticated | actor global role | target user only; no relation | cross-tenant note mutation and tenantless/PII-bearing audit | CRITICAL | A — BODY HARDENING |
| `update_profile_identity` | `(uuid,text,text)` | identity editor; `app/admin/users/page.tsx` | DEFINER, `postgres`, SP2 | authenticated + service_role | actor global role | target user only; no relation | name/full-name PII mutation; service path has no repository caller | CRITICAL | A — BODY + ACL HARDENING |
| `update_profile_contact_details` | `(uuid,text,text,text,text,text,text)` | contact editor; `app/admin/users/page.tsx` | DEFINER, `postgres`, SP2 | authenticated + service_role | actor/target global roles | target user only; no relation | phone/address PII mutation; employee can target globally; no service caller | CRITICAL | A — BODY + ACL HARDENING |

Repository caller inventory is exact: all five browser calls are in
`app/admin/users/page.tsx`; tests are the only other repository callers. No
server/service caller exists for the identity or contact RPC. Production
preflight must reconfirm zero service caller before revoking those grants.
UNKNOWN = `0`.

One optional implementation dependency is permitted: a closed, owner-only
SECURITY INVOKER helper accepting explicit `(tenant_id,user_id)` and returning
only whether the approved operational relation exists. It must have no
PUBLIC/anon/authenticated/service_role EXECUTE. It is not an external RPC and
does not change the expected SECURITY DEFINER count. If repeated inline
`EXISTS` predicates are clearer after implementation review, no helper is
required.

### 40.2 Trusted tenant and operational relationship

All unchanged public signatures use the temporary
`active_single_tenant_id_v1()` compatibility bridge. The bridge must resolve
exactly one active tenant; zero or more than one returns controlled denial.
It is not valid after second-tenant activation and must be replaced by trusted
selected-tenant context in 9E.

Caller authorization is always `auth.uid()` plus an active membership in the
resolved tenant:

- list, role, note and identity: membership role `admin` only;
- contact: `admin`, or `employee` only under the existing customer-only scope;
- pending, suspended, missing membership and global `profiles.role` alone:
  DENY.

A target is operationally related only when at least one retained row proves:

1. `tenant_memberships(tenant_id,target_user_id)`, or
2. `reservations(tenant_id,user_id=target_user_id)`, or
3. `event_registrations(user_id=target_user_id)` joined to an `events` row with
   the same tenant (and matching registration tenant).

The relationship is derived in SQL from tenant-owned records. Browser tenant
values, target `profiles.role`, the existence of a global profile and the
target UUID alone are never authority. Cross-tenant-only and unrelated global
users fail before profile PII is read or mutated. Retained historical business
rows continue to constitute the approved operational relationship; this does
not change retention or expose data to another tenant.

### 40.3 Per-function target contract

`admin_list_users_v1` keeps its exact signature, return columns, filters,
sorting, pagination cap and stable UUID tie-breaker for old-app compatibility.
It builds a de-duplicated eligible-user ID set from the three approved
relationship sources before joining `profiles`; search/filter/count occur only
inside that set. It remains admin-only. The existing page currently consumes
all returned fields, so removing return columns would require a versioned DTO
and app cutover in 9E/9F. 4B-1 therefore preserves but does not expand the DTO.

The list `role` field comes from the selected tenant membership and maps tenant
roles back to legacy UI values: `employee -> pracownik`, `instructor ->
instruktor`, with `admin` and `user` unchanged. An operational customer without
a membership is displayed as `user`; this display fallback is not authority.

`admin_set_user_role_v1` changes only an existing membership in the resolved
tenant. It does not create membership implicitly. Input keeps the legacy UI
values and maps through the approved bridge:
`admin/user/pracownik/instruktor -> admin/user/employee/instructor`. Lock order
is tenant advisory lock, target membership, then any actor/target profile row
needed by the temporary CSK sync bridge. Last-admin counting is tenant-local
and considers active admin memberships only. Demotion/removal cannot leave the
tenant without an active admin. The CSK sync trigger may mirror the result to
`profiles.role` during compatibility, but the profile value never authorizes
the operation.

`admin_set_user_note_v1` and `update_profile_identity` require tenant admin plus
the approved target relation. `update_profile_contact_details` permits tenant
admin; tenant employee is limited to a related operational customer, cannot
target self, and cannot target a membership whose tenant role is admin,
employee or instructor. For a related customer without membership, the
effective operational class is user. No employee list access or role/note/
identity widening is introduced.

All mutations retain current validation limits, controlled result/error
semantics, no-change behavior and response fields required by the page. Direct
profile UPDATE remains denied.

### 40.4 Least-privilege PII and audit

| Operation | Required profile fields | Permitted actor | Output |
|---|---|---|---|
| list | current page DTO: identity, contact/address, declarations, verification, tenant-mapped role, admin note | related-tenant admin only | existing 30-column contract; no foreign rows |
| role | target ID and tenant membership role; profile only for temporary CSK sync | related-tenant admin | existing status/role timestamps; no profile DTO |
| note | admin note and target ID | related-tenant admin | existing note result only |
| identity | first/last/full name | related-tenant admin | existing identity result only |
| contact | phone/address fields | related-tenant admin or constrained employee | existing contact result only |

No function returns another user's tokens, auth metadata, passwords, audit
internals or unrelated business records. Future DTO minimization must split
list summary/detail in a versioned 9E/9F contract; it cannot silently change
the current table-return signature.

Every successful changed mutation writes exactly one tenant-scoped audit with
explicit `tenant_id`, actor=`auth.uid()` and DB timestamp. Audit details contain
only stable action/changed-field metadata and tenant role mapping, never note
contents, names, email, phone, address or tokens. Actor/target labels are
pseudonymous. Deny and no-change create no audit. No audit default or global
`profiles.role` is used.

### 40.5 Owner, staff and account separation

- OWNER self-service remains exclusively `update_my_profile_v1` and the 4C
  account contracts; none of the five 4B-1 RPCs becomes an owner bypass.
- STAFF means active tenant membership plus allowed membership role plus the
  approved target operational relationship.
- SERVER/service_role receives no business authorization. The unproved SP2
  service grants on identity/contact are revoked.
- Global export, global anonymization, Auth deletion and future leave-tenant
  are untouched. 4B-1 neither calls nor changes those functions. Leave-tenant
  remains membership-scoped; account deletion remains account-wide.

### 40.6 ACL, metadata and compatibility

All five remain SECURITY DEFINER, owned by `postgres`, and use SP1 after
hardening. Each migration statement first revokes PUBLIC/anon/authenticated/
service_role, then grants only authenticated EXECUTE. Authorization remains
inside the function. No table ACL or RLS policy is widened.

Expected SECURITY DEFINER count after 4B-1: **67**. A closed INVOKER helper, if
used, does not change it. Compatibility defaults remain **7/7** and are not
tenant authority.

Compatibility matrix:

| Combination | Result |
|---|---|
| OLD APP + OLD DB | current single-tenant behavior; known unsafe for Tenant B |
| OLD APP + NEW DB | supported; identical signatures/DTOs and active-single bridge |
| NEW APP + OLD DB | not applicable; 4B-1 plans no app change |
| NEW APP + NEW DB | supported; same as old app under the bridge |

Deployment model: **DB FIRST / DB ONLY**, with second tenant still blocked.

### 40.7 Migration and implementation sequence

Proposed single migration name:
`20260919100000_harden_tenant_profile_administration.sql`.

1. Fail closed on exact five signatures, overload count, normalized source
   fingerprints, owner, mode, path and ACL; freeze representative 4A/4B-2/4C
   dependencies and SECURITY DEFINER count 67.
2. Verify exactly one active tenant, membership uniqueness, reservation/event
   relationship integrity, zero cross-tenant mismatches and defaults 7/7.
3. Snapshot unrelated function definitions/metadata/ACL and business row
   counts/fingerprints.
4. Add the optional closed INVOKER relationship helper or use one identical
   inline relation predicate in all relevant bodies.
5. Replace the five bodies, normalize SP2 paths to SP1 and apply exact ACLs.
6. Postflight target fingerprints, relationship predicates, audit tenant,
   global-role absence, count 67, defaults 7/7 and unrelated drift zero.
7. Commit the migration transaction only if every assertion passes.

No application, schema-table, RLS, membership backfill, data rewrite or default
removal belongs to 4B-1.

### 40.8 Test plan

Focused SQL must cover every function plus:

- ADMIN_A + related member/reservation/event-registration user A: ALLOW;
- ADMIN_A + Tenant-B-only or unrelated global user: DENY, zero PII/audit;
- EMPLOYEE_A: contact only for related customer; self/admin/employee/
  instructor/unrelated/Tenant-B target DENY;
- global `profiles.role=admin` without active A membership, pending,
  suspended and no membership: DENY;
- owner self only through existing self contract; foreign owner path DENY;
- tenant role mapping both directions and no implicit membership creation;
- tenant-local last-admin protection under concurrent demotions;
- mixed-tenant relationship and tenant spoof attempts fail closed;
- list de-duplication, filter/sort/page/count and current DTO field contract;
- note/identity/contact validation, no-change idempotency, one tenant audit per
  changed mutation, PII-free audit details and no denial audit;
- direct profile DML remains denied; service_role direct RPC execution denied;
- account export/anonymization/Auth deletion and future leave-tenant separation
  fingerprints unchanged;
- SECURITY DEFINER 67, unexpected drift 0, defaults 7/7, fixture cleanup 0.

Regression: focused 4B-1 SQL, CLEAN-005/profile DML, SEC-007 audit, SEC-009
lifecycle, admin-users Node tests, full Supabase DB suite, all Node tests,
TypeScript, production build, focused admin-users Playwright, npm audit,
changed-files ESLint and `git diff --check`. Concurrency tests require
last-admin races, note/contact no-change races, deadlocks 0, duplicate audits 0
and cross-tenant contamination 0.

### 40.9 Production preflight and rollback

Production preflight is read-only: verify project identity, migration history,
single pending migration, migration SHA, five source fingerprints, zero service
callers, relation/orphan/mismatch counts, one active tenant, membership/admin
baseline, SECURITY DEFINER 67, defaults 7/7 and exact dry-run. Any difference is
a blocker.

The migration is transactional and contains no backfill. A failed pre/postflight
rolls back automatically. After deployment, use catalog checks plus a
rollback-only two-tenant matrix and independent fixture-zero query. If a
post-deploy defect requires reversal, create a separately reviewed corrective
migration restoring frozen definitions and ACLs; never use migration repair or
manual production edits. Application rollback is unnecessary because public
signatures and DTOs are unchanged.

### 40.10 Risks and gates

| Risk | Level | Mitigation |
|---|---|---|
| cross-tenant profile PII | CRITICAL impact | relation-first eligible IDs; foreign/unrelated negative matrix |
| role/last-admin race | HIGH | tenant-scoped advisory lock plus membership row lock |
| employee scope widening | HIGH | contact-only, customer-only relation and target-role checks |
| audit PII or wrong tenant | HIGH | explicit tenant ID and allowlisted pseudonymous details |
| broad list DTO | MEDIUM residual | admin-only related scope now; versioned DTO split in 9E/9F |
| active-single bridge | HIGH before Tenant B | second tenant remains blocked; replace in 9E |
| caller compatibility | LOW | unchanged signatures, result fields and error contracts |

All blocking business decisions for local 4B-1 are resolved by the approved
operational-relationship and account/leave-tenant decisions. The only
implementation gates are empirical: fresh source fingerprints/callers and
production integrity must match this plan. Verification remains explicitly
outside 4B-1 and is handled by 4B-2.

SAAS-9D-4B-1 TECHNICAL PLAN: **READY**

READY FOR SAAS-9D-4B-1 LOCAL IMPLEMENTATION: **GO**

READY FOR PRODUCTION WRITE: **NO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**

## 41. SAAS-9D-4B-1A — tenant user admin-note foundation (implemented locally)

The approved data-model decision supersedes the former assumption in section
40 that 4B-1 would not add a table or perform a backfill. 4B-1 is now split:

- **4B-1A** owns only the tenant note model, fail-closed direct access, one-way
  CSK backfill, `admin_list_users_v1` note-source cutover,
  `admin_set_user_note_v1` write cutover, and tenant-bound audit;
- **4B-1B** retains role, identity, contact, verification and tenant-local
  last-admin hardening. None of those functions is changed by 4B-1A.

Local migration `20260919100000_add_tenant_user_admin_notes.sql` implements a
`tenant_user_admin_notes(tenant_id,user_id)` primary key with note metadata and
foreign keys to `tenants` and `auth.users`. The table is owned by `postgres`,
has RLS enabled with zero policies, and grants no direct table privilege to
PUBLIC, anon, authenticated, or service_role. Access is only through the two
existing, signature-compatible RPCs.

The one-way backfill copies a non-null `profiles.admin_note` only when the user
has an existing relationship to the single active CSK tenant through a
membership, reservation, or tenant-consistent event registration. Any
unrelated legacy note aborts the migration. After cutover,
`profiles.admin_note` is frozen: there is no read fallback and no write path
from either target RPC.

Both RPCs use the temporary exact-single-active-tenant bridge, require an
active admin membership in that tenant, and establish the target relation
before reading or mutating profile data. The same user may therefore hold an
independent note per tenant. Global `profiles.role`, pending/suspended
membership, a foreign-only relationship, or the target UUID alone never grant
access. The temporary bridge remains a **9E cutover dependency** and is not
valid for activating a second tenant.

Changed note mutations write exactly one PII-free audit with explicit
`audit_logs.tenant_id`, action `tenant_user_admin_note_updated`, and target type
`tenant_user_admin_note`; no-change retries produce no audit. The existing
audit tenant trigger is extended only for that explicit action/target pair.
Account export, global anonymization, Auth deletion and future leave-tenant
remain separate contracts.

Local verification:

- focused SQL: **37/37 PASS**;
- full Supabase DB suite: **1144/1144 PASS**;
- all Node tests: **739/739 PASS**;
- focused `/admin/users` Playwright: **1/1 PASS**, including tenant note
  persistence and frozen legacy field;
- TypeScript, production build, changed-file ESLint and `git diff --check`:
  **PASS**;
- SECURITY DEFINER count: **67**; compatibility defaults: **7/7**;
- fixture cleanup: **0**.

Production preflight and production write have not been performed.

SAAS-9D-4B-1A LOCAL: **PASS**

READY FOR SAAS-9D-4B-1A PRODUCTION PREFLIGHT: **GO**

READY FOR SAAS-9D-4B-1B: **NO-GO until review**

READY FOR PRODUCTION WRITE: **NO**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**
