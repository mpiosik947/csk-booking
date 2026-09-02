# SECURITY REMEDIATION 02C — MANAGED SUPABASE ACL

## Scope

This remediation closes the application-controlled part of SEC-002 without changing the managed `supabase_admin` role or its default privileges.

Validation date: 2026-09-02

Environment: local Supabase only (`127.0.0.1`). No production operation was performed.

## Ownership

```text
Application tables owned by postgres: 14
Application tables owned by supabase_admin: 0
Application sequences owned by postgres: 0
Application sequences owned by supabase_admin: 0
Application functions owned by postgres: 58
Application functions owned by supabase_admin: 0
Application views: 0
Application materialized views: 0
Application foreign tables: 0
Other relation owners: 0
```

The `public` schema itself is owned by the standard `pg_database_owner` role. This is schema ownership, not ownership of an application relation. Twelve non-internal triggers are attached to `postgres`-owned tables and invoke `postgres`-owned functions; triggers do not have an independent owner. No public enum or domain is present.

### Complete relation inventory

| Object | Type | Owner |
|---|---|---|
| `audit_logs` | TABLE | postgres |
| `confirmation_email_rate_limits` | TABLE | postgres |
| `email_deliveries` | TABLE | postgres |
| `event_lanes` | TABLE | postgres |
| `event_registrations` | TABLE | postgres |
| `events` | TABLE | postgres |
| `lane_blocks` | TABLE | postgres |
| `lane_booking_durations` | TABLE | postgres |
| `lane_booking_family_configuration_versions` | TABLE | postgres |
| `lane_booking_rules` | TABLE | postgres |
| `lane_pricing_rules` | TABLE | postgres |
| `profiles` | TABLE | postgres |
| `reservations` | TABLE | postgres |
| `shooting_lanes` | TABLE | postgres |

No SEQUENCE, VIEW, MATERIALIZED VIEW, or FOREIGN TABLE exists in `public`.

### Complete function inventory

Every function below is a `FUNCTION` owned by `postgres`:

```text
admin_create_event(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])
admin_create_event_v2(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])
admin_create_lane_block(uuid,date,time without time zone,time without time zone,text)
admin_create_lane_booking_family_v1(jsonb)
admin_get_lane_booking_configuration_v1()
admin_get_lane_booking_configuration_v2()
admin_list_users_v1(integer,integer,text,text,text,text)
admin_set_event_active(uuid,boolean)
admin_set_event_active_v2(uuid,boolean)
admin_set_lane_block_active(uuid,boolean)
admin_set_lane_booking_configuration(uuid,boolean,boolean,boolean,integer,boolean,integer,integer[],jsonb)
admin_set_lane_booking_family_configuration_v2(uuid,bigint,jsonb,boolean)
admin_set_user_note_v1(uuid,text)
admin_set_user_role_v1(uuid,text)
admin_update_event(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])
admin_update_event_v2(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])
admin_update_lane_block(uuid,uuid,date,time without time zone,time without time zone,text,boolean)
approve_event_registration(uuid)
cancel_event_registration(uuid)
cancel_reservation(uuid)
check_confirmation_email_rate_limit(uuid,text)
complete_confirmation_email(uuid,boolean,text,text)
complete_event_reserve_promotion(uuid,uuid,boolean,text)
confirm_event_reserve_promotion(text)
create_reservation(uuid,date,time without time zone,integer,integer,uuid,text)
create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)
get_lane_booking_busy_ranges(uuid,date)
get_lane_booking_busy_ranges_v2(uuid,date)
get_lane_booking_busy_ranges_v3(uuid,date)
get_my_reservations_v2()
get_my_role()
get_public_booking_configuration_v1()
get_reservation_customer_profiles_v1(uuid[])
handle_new_user()
is_admin()
is_admin_or_employee()
is_admin_or_staff()
lane_booking_family_business_snapshot_v2(uuid)
lock_lane_booking_configuration()
lock_lane_conflict_families_v1(uuid[])
lock_lane_conflict_family_v1(uuid)
normalize_lane_booking_family_payload_v2(jsonb)
prepare_confirmation_email(text,uuid)
prepare_event_reserve_promotions(uuid)
prevent_non_admin_profile_privilege_changes()
register_for_event(uuid,boolean)
resolve_lane_conflict_scope_v1(uuid)
set_booking_configuration_updated_at()
set_updated_at()
update_profile_contact_details(uuid,text,text,text,text,text,text)
update_profile_identity(uuid,text,text)
update_profile_verification(uuid,text,text)
update_reservation_admin_note(uuid,text)
update_reservation_attendance(uuid,text)
update_reservation_payment(uuid,text)
validate_lane_booking_rule_capacity()
validate_shooting_lane_capacity_change()
validate_shooting_lane_hierarchy()
```

## Migration ownership review

```text
Result: PASS
```

All migrations were searched for role and owner changes.

- `SET ROLE supabase_admin`: absent.
- `SET LOCAL ROLE supabase_admin`: absent.
- `OWNER TO supabase_admin`: absent.
- Any `supabase_admin` reference in application migrations: absent.
- Explicit owner changes found in the consolidated baseline and later migrations target `postgres`.
- No application runtime source contains DDL capable of creating a table or sequence.

The consolidated baseline sets the `public` schema owner to `pg_database_owner`, which is expected Supabase/PostgreSQL schema configuration and does not transfer application objects to `supabase_admin`.

## Compensating controls

Added test:

`supabase/tests/20260902130000_managed_supabase_acl_guard_test.sql`

The test is fail-closed and transaction-scoped. It checks:

1. every application table, partitioned table, sequence, view, materialized view, and foreign table in `public` is owned by `postgres`, unless present on an explicit justified allowlist;
2. the current allowlist is empty;
3. every public function is owned by `postgres`;
4. `anon` has no `TRUNCATE`, `REFERENCES`, `TRIGGER`, or `MAINTAIN` on any public table;
5. `authenticated` has none of those technical rights;
6. `postgres` default TABLE privileges remain client-safe;
7. `postgres` default SEQUENCE privileges remain client-safe;
8. a newly created table grants no automatic table right to `anon` or `authenticated`;
9. a newly created sequence grants no automatic `USAGE`, `SELECT`, or `UPDATE` to either client role;
10. all probe objects are removed by the final `ROLLBACK`.

The REMEDIATION 02B test remains unchanged and continues to cover its detailed 29-test ACL matrix, real SQL denial cases, positive operations, and idempotent migration application.

## Managed Supabase residual

`supabase_admin` is a Supabase-managed superuser role. Local inspection confirms that application migration role `postgres`:

```text
is member of supabase_admin: false
can SET ROLE supabase_admin: false
```

The managed role retains broad default TABLE and SEQUENCE grants to `anon` and `authenticated`. It is not modified because doing so from a normal application migration is neither authorized nor portable to hosted Supabase.

The residual can materialize only if a privileged Supabase platform operation or an operator explicitly acting as `supabase_admin` creates a table or sequence inside `public`. The current architecture does not provide this path:

- all application migrations execute/create objects as `postgres`;
- all current application objects are `postgres`-owned;
- no migration assumes `supabase_admin`;
- the application runtime performs no DDL;
- the new CI/database test fails as soon as a non-allowlisted managed-owner relation appears.

Assessment:

```text
Classification: ACCEPTED PLATFORM RISK
Residual severity: LOW
Reachability: privileged platform/operator action required
Current affected application objects: 0
```

This does not eliminate the platform configuration, but it reduces the application-relevant likelihood and supplies a deterministic detection control. If future Supabase tooling creates an application relation in `public` as `supabase_admin`, the ownership test must fail and the object must be reviewed before release; it must not be silently allowlisted.

## service_role

```text
REVIEWED / OUT OF SCOPE
```

No `service_role` ACL or default privilege was changed. The decision and table-by-table review from REMEDIATION 02B remain in force.

## Tests

```text
Focused: PASS — 10/10, exit code 0, final ROLLBACK
Supabase DB: PASS — Files=7, Tests=103
Node: PASS — 540/540
TypeScript: PASS — npx.cmd tsc --noEmit
Changed-files ESLint: N/A — the 02C changes are SQL and Markdown, not ESLint inputs
Full ESLint baseline: EXISTING FAILURE — 14 errors, 6 warnings
NEW ESLINT REGRESSIONS: 0
Build: PASS — Next.js build, 35/35 static pages
git diff --check: PASS — only informational LF/CRLF warnings on pre-existing files
```

The full ESLint result exactly matches the baseline observed before 02C. No JavaScript or TypeScript file was changed by this remediation.

## Final verdict

```text
SEC-002 APPLICATION-CONTROLLED SCOPE: FULLY REMEDIATED
MANAGED PLATFORM RESIDUAL: ACCEPTED
MANAGED PLATFORM RESIDUAL SEVERITY: LOW
```

Rationale: all current application objects use the controlled `postgres` owner, client ACL and `postgres` defaults are hardened by REMEDIATION 02B, REMEDIATION 02 function ACL remains intact, no migration/runtime path uses `supabase_admin`, and the new ownership/default-ACL regression test is active. The managed-role residual therefore no longer keeps the entire SEC-002 finding at HIGH for the application-controlled scope.
