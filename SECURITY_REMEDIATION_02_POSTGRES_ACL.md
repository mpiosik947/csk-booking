# SECURITY REMEDIATION 02 — PostgreSQL function ACL

## Finding

- SEC-ID: `SEC-002`
- Severity: `HIGH`
- Status przed poprawką: `CONFIRMED`
- Zakres tej poprawki: domyślne i bieżące uprawnienia `EXECUTE` funkcji/RPC w schemacie `public`

Domyślne przywileje creatora `postgres` automatycznie udostępniały nowe funkcje rolom `anon`, `authenticated` i `service_role`. Dodatkowo wbudowany globalny default PostgreSQL nadawał nowym funkcjom `PUBLIC EXECUTE`. Sześć istniejących funkcji nadal miało `PUBLIC EXECUTE`, w tym trzy funkcje triggerowe i helpery ról/RLS.

Nowa funkcja `SECURITY DEFINER` mogła więc zostać chwilowo lub trwale udostępniona klientom, jeżeli jej migracja nie wykonała kompletnego `REVOKE`. To tworzyło fail-open boundary dla przyszłych RPC.

## Functions audited

- Wszystkie funkcje `public`: **58**
- `SECURITY DEFINER`: **52**
- `SECURITY INVOKER`: **6**
- Funkcje zwracające `trigger`: **8**
- Aktywnie powiązane z triggerami: **7**
- Dormant trigger helper: `handle_new_user()`
- Owner wszystkich 58 funkcji aplikacyjnych: `postgres`

Kategorie dostępu:

- **A — internal only:** 6
- **B — authenticated/public user RPC:** 12
- **C — admin/employee RPC lub helper polityki z wewnętrzną kontrolą roli:** 24
- **D — service/internal privileged:** 8
- **E — trigger-only/dormant trigger helper:** 8

Każda sygnatura, owner, security mode, return type, `proconfig` i rzeczywisty ACL zostały odczytane z `pg_proc`, `pg_namespace`, `pg_roles`, `pg_language` i `aclexplode`. Test katalogowy wymaga dokładnie tych 58 sygnatur i odrzuca brakującą lub dodatkową funkcję.

Legenda macierzy: `Y` — EXECUTE, `N` — brak EXECUTE. Schema każdej funkcji: `public`.

## ACL matrix before

| Function | Cat. | PUBLIC | anon | authenticated | service_role | Intended access |
| --- | --- | --- | --- | --- | --- | --- |
| `admin_create_event_v2(text,text,date,time,time,text,numeric,integer,uuid[])` | C | N | N | Y | N | authenticated + internal admin/pracownik check |
| `admin_create_event(text,text,date,time,time,text,numeric,integer,uuid[])` | D | N | N | N | Y | service rollback RPC |
| `admin_create_lane_block(uuid,date,time,time,text)` | C | N | N | Y | N | authenticated + internal admin/pracownik check |
| `admin_create_lane_booking_family_v1(jsonb)` | C | N | N | Y | N | authenticated + internal admin check |
| `admin_get_lane_booking_configuration_v1()` | C | N | N | Y | N | authenticated + internal admin check |
| `admin_get_lane_booking_configuration_v2()` | C | N | N | Y | N | authenticated + internal admin check |
| `admin_list_users_v1(integer,integer,text,text,text,text)` | C | N | N | Y | N | authenticated + internal admin check |
| `admin_set_event_active_v2(uuid,boolean)` | C | N | N | Y | N | authenticated + internal admin/pracownik check |
| `admin_set_event_active(uuid,boolean)` | D | N | N | N | Y | service rollback RPC |
| `admin_set_lane_block_active(uuid,boolean)` | C | N | N | Y | N | authenticated + internal admin/pracownik check |
| `admin_set_lane_booking_configuration(uuid,boolean,boolean,boolean,integer,boolean,integer,integer[],jsonb)` | A | N | N | N | N | owner/internal only |
| `admin_set_lane_booking_family_configuration_v2(uuid,bigint,jsonb,boolean)` | C | N | N | Y | N | authenticated + internal admin check |
| `admin_set_user_note_v1(uuid,text)` | C | N | N | Y | N | authenticated + internal admin check |
| `admin_set_user_role_v1(uuid,text)` | C | N | N | Y | N | authenticated + internal admin check |
| `admin_update_event_v2(uuid,text,text,date,time,time,text,numeric,integer,uuid[])` | C | N | N | Y | N | authenticated + internal admin/pracownik check |
| `admin_update_event(uuid,text,text,date,time,time,text,numeric,integer,uuid[])` | D | N | N | N | Y | service rollback RPC |
| `admin_update_lane_block(uuid,uuid,date,time,time,text,boolean)` | C | N | N | Y | N | authenticated + internal admin/pracownik check |
| `approve_event_registration(uuid)` | C | N | N | Y | N | authenticated + internal operator check |
| `cancel_event_registration(uuid)` | B | N | N | Y | Y | owner/operator and trusted server |
| `cancel_reservation(uuid)` | B | N | N | Y | Y | owner/operator and trusted server |
| `check_confirmation_email_rate_limit(uuid,text)` | D | N | N | N | Y | trusted mail service only |
| `complete_confirmation_email(uuid,boolean,text,text)` | D | N | N | N | Y | trusted mail service only |
| `complete_event_reserve_promotion(uuid,uuid,boolean,text)` | D | N | N | N | Y | trusted promotion service only |
| `confirm_event_reserve_promotion(text)` | B | N | N | Y | N | authenticated registration owner |
| `create_reservation_v2(uuid,date,time,integer,integer,uuid,text)` | B | N | N | Y | Y | authenticated user/trusted server |
| `create_reservation(uuid,date,time,integer,integer,uuid,text)` | D | N | N | N | Y | service rollback RPC |
| `get_lane_booking_busy_ranges_v2(uuid,date)` | B | N | N | Y | Y | authenticated booking/trusted server |
| `get_lane_booking_busy_ranges_v3(uuid,date)` | B | N | N | Y | Y | authenticated booking/trusted server |
| `get_lane_booking_busy_ranges(uuid,date)` | B | N | N | Y | Y | authenticated rollback reader/trusted server |
| `get_my_reservations_v2()` | B | N | N | Y | N | authenticated owner reader |
| `get_my_role()` | B | Y | Y | Y | Y | authenticated role reader |
| `get_public_booking_configuration_v1()` | B | N | Y | Y | Y | intentionally public non-PII reader |
| `get_reservation_customer_profiles_v1(uuid[])` | C | N | N | Y | N | authenticated + internal operator scope |
| `handle_new_user()` | E | Y | Y | Y | Y | dormant trigger helper only |
| `is_admin_or_employee()` | C | N | N | Y | Y | authenticated RLS helper |
| `is_admin_or_staff()` | C | Y | Y | Y | Y | authenticated RLS helper |
| `is_admin()` | C | Y | Y | Y | Y | authenticated RLS helper |
| `lane_booking_family_business_snapshot_v2(uuid)` | A | N | N | N | N | internal only |
| `lock_lane_booking_configuration()` | E | N | N | N | Y | trigger-only |
| `lock_lane_conflict_families_v1(uuid[])` | A | N | N | N | N | internal writer helper |
| `lock_lane_conflict_family_v1(uuid)` | A | N | N | N | N | internal writer helper |
| `normalize_lane_booking_family_payload_v2(jsonb)` | A | N | N | N | N | internal writer helper |
| `prepare_confirmation_email(text,uuid)` | B | N | N | Y | N | authenticated owner flow |
| `prepare_event_reserve_promotions(uuid)` | D | N | N | N | Y | trusted promotion service only |
| `prevent_non_admin_profile_privilege_changes()` | E | Y | Y | Y | Y | trigger-only |
| `register_for_event(uuid,boolean)` | B | N | N | Y | N | authenticated user RPC |
| `resolve_lane_conflict_scope_v1(uuid)` | A | N | N | N | N | internal writer helper |
| `set_booking_configuration_updated_at()` | E | N | N | N | Y | trigger-only |
| `set_updated_at()` | E | Y | Y | Y | Y | trigger-only |
| `update_profile_contact_details(uuid,text,text,text,text,text,text)` | C | N | N | Y | Y | internally authorized profile writer |
| `update_profile_identity(uuid,text,text)` | C | N | N | Y | Y | internally authorized profile writer |
| `update_profile_verification(uuid,text,text)` | C | N | N | Y | Y | internally authorized operator writer |
| `update_reservation_admin_note(uuid,text)` | C | N | N | Y | N | authenticated + internal operator check |
| `update_reservation_attendance(uuid,text)` | C | N | N | Y | Y | internally authorized operator/trusted server |
| `update_reservation_payment(uuid,text)` | C | N | N | Y | N | authenticated + internal operator check |
| `validate_lane_booking_rule_capacity()` | E | N | N | N | Y | trigger-only |
| `validate_shooting_lane_capacity_change()` | E | N | N | N | Y | trigger-only |
| `validate_shooting_lane_hierarchy()` | E | N | N | N | Y | trigger-only |

Before totals:

```text
PUBLIC EXECUTE: 6
anon EXECUTE: 7
authenticated EXECUTE: 39
service_role EXECUTE: 31
```

## ACL matrix after

| Function | Cat. | PUBLIC | anon | authenticated | service_role | Intended access |
| --- | --- | --- | --- | --- | --- | --- |
| `admin_create_event_v2(text,text,date,time,time,text,numeric,integer,uuid[])` | C | N | N | Y | N | authenticated + internal admin/pracownik check |
| `admin_create_event(text,text,date,time,time,text,numeric,integer,uuid[])` | D | N | N | N | Y | service rollback RPC |
| `admin_create_lane_block(uuid,date,time,time,text)` | C | N | N | Y | N | authenticated + internal admin/pracownik check |
| `admin_create_lane_booking_family_v1(jsonb)` | C | N | N | Y | N | authenticated + internal admin check |
| `admin_get_lane_booking_configuration_v1()` | C | N | N | Y | N | authenticated + internal admin check |
| `admin_get_lane_booking_configuration_v2()` | C | N | N | Y | N | authenticated + internal admin check |
| `admin_list_users_v1(integer,integer,text,text,text,text)` | C | N | N | Y | N | authenticated + internal admin check |
| `admin_set_event_active_v2(uuid,boolean)` | C | N | N | Y | N | authenticated + internal admin/pracownik check |
| `admin_set_event_active(uuid,boolean)` | D | N | N | N | Y | service rollback RPC |
| `admin_set_lane_block_active(uuid,boolean)` | C | N | N | Y | N | authenticated + internal admin/pracownik check |
| `admin_set_lane_booking_configuration(uuid,boolean,boolean,boolean,integer,boolean,integer,integer[],jsonb)` | A | N | N | N | N | owner/internal only |
| `admin_set_lane_booking_family_configuration_v2(uuid,bigint,jsonb,boolean)` | C | N | N | Y | N | authenticated + internal admin check |
| `admin_set_user_note_v1(uuid,text)` | C | N | N | Y | N | authenticated + internal admin check |
| `admin_set_user_role_v1(uuid,text)` | C | N | N | Y | N | authenticated + internal admin check |
| `admin_update_event_v2(uuid,text,text,date,time,time,text,numeric,integer,uuid[])` | C | N | N | Y | N | authenticated + internal admin/pracownik check |
| `admin_update_event(uuid,text,text,date,time,time,text,numeric,integer,uuid[])` | D | N | N | N | Y | service rollback RPC |
| `admin_update_lane_block(uuid,uuid,date,time,time,text,boolean)` | C | N | N | Y | N | authenticated + internal admin/pracownik check |
| `approve_event_registration(uuid)` | C | N | N | Y | N | authenticated + internal operator check |
| `cancel_event_registration(uuid)` | B | N | N | Y | Y | owner/operator and trusted server |
| `cancel_reservation(uuid)` | B | N | N | Y | Y | owner/operator and trusted server |
| `check_confirmation_email_rate_limit(uuid,text)` | D | N | N | N | Y | trusted mail service only |
| `complete_confirmation_email(uuid,boolean,text,text)` | D | N | N | N | Y | trusted mail service only |
| `complete_event_reserve_promotion(uuid,uuid,boolean,text)` | D | N | N | N | Y | trusted promotion service only |
| `confirm_event_reserve_promotion(text)` | B | N | N | Y | N | authenticated registration owner |
| `create_reservation_v2(uuid,date,time,integer,integer,uuid,text)` | B | N | N | Y | Y | authenticated user/trusted server |
| `create_reservation(uuid,date,time,integer,integer,uuid,text)` | D | N | N | N | Y | service rollback RPC |
| `get_lane_booking_busy_ranges_v2(uuid,date)` | B | N | N | Y | Y | authenticated booking/trusted server |
| `get_lane_booking_busy_ranges_v3(uuid,date)` | B | N | N | Y | Y | authenticated booking/trusted server |
| `get_lane_booking_busy_ranges(uuid,date)` | B | N | N | Y | Y | authenticated rollback reader/trusted server |
| `get_my_reservations_v2()` | B | N | N | Y | N | authenticated owner reader |
| `get_my_role()` | B | N | N | Y | N | authenticated role reader |
| `get_public_booking_configuration_v1()` | B | N | Y | Y | Y | intentionally public non-PII reader |
| `get_reservation_customer_profiles_v1(uuid[])` | C | N | N | Y | N | authenticated + internal operator scope |
| `handle_new_user()` | E | N | N | N | N | dormant trigger helper only |
| `is_admin_or_employee()` | C | N | N | Y | N | authenticated RLS helper |
| `is_admin_or_staff()` | C | N | N | Y | N | authenticated RLS helper |
| `is_admin()` | C | N | N | Y | N | authenticated RLS helper |
| `lane_booking_family_business_snapshot_v2(uuid)` | A | N | N | N | N | internal only |
| `lock_lane_booking_configuration()` | E | N | N | N | N | trigger-only |
| `lock_lane_conflict_families_v1(uuid[])` | A | N | N | N | N | internal writer helper |
| `lock_lane_conflict_family_v1(uuid)` | A | N | N | N | N | internal writer helper |
| `normalize_lane_booking_family_payload_v2(jsonb)` | A | N | N | N | N | internal writer helper |
| `prepare_confirmation_email(text,uuid)` | B | N | N | Y | N | authenticated owner flow |
| `prepare_event_reserve_promotions(uuid)` | D | N | N | N | Y | trusted promotion service only |
| `prevent_non_admin_profile_privilege_changes()` | E | N | N | N | N | trigger-only |
| `register_for_event(uuid,boolean)` | B | N | N | Y | N | authenticated user RPC |
| `resolve_lane_conflict_scope_v1(uuid)` | A | N | N | N | N | internal writer helper |
| `set_booking_configuration_updated_at()` | E | N | N | N | N | trigger-only |
| `set_updated_at()` | E | N | N | N | N | trigger-only |
| `update_profile_contact_details(uuid,text,text,text,text,text,text)` | C | N | N | Y | Y | internally authorized profile writer |
| `update_profile_identity(uuid,text,text)` | C | N | N | Y | Y | internally authorized profile writer |
| `update_profile_verification(uuid,text,text)` | C | N | N | Y | Y | internally authorized operator writer |
| `update_reservation_admin_note(uuid,text)` | C | N | N | Y | N | authenticated + internal operator check |
| `update_reservation_attendance(uuid,text)` | C | N | N | Y | Y | internally authorized operator/trusted server |
| `update_reservation_payment(uuid,text)` | C | N | N | Y | N | authenticated + internal operator check |
| `validate_lane_booking_rule_capacity()` | E | N | N | N | N | trigger-only |
| `validate_shooting_lane_capacity_change()` | E | N | N | N | N | trigger-only |
| `validate_shooting_lane_hierarchy()` | E | N | N | N | N | trigger-only |

After totals:

```text
PUBLIC EXECUTE: 0
anon EXECUTE: 1
authenticated EXECUTE: 36
service_role EXECUTE: 19
```

## Default privileges

### Before

Creator `postgres` miał w `public` automatyczne `EXECUTE` dla:

```text
postgres, anon, authenticated, service_role
```

Ponadto wbudowany globalny default PostgreSQL nadawał `PUBLIC EXECUTE` każdej nowej funkcji. Per-schema `REVOKE` nie może odjąć globalnego wbudowanego grantu.

### After

```text
postgres / global functions: postgres=X/postgres
postgres / public functions: postgres=X/postgres
```

- Globalny default creatora `postgres` odbiera `PUBLIC EXECUTE` przyszłym funkcjom.
- Default dla `public` odbiera automatyczne EXECUTE `anon`, `authenticated` i `service_role`.
- Nowe RPC muszą otrzymać jawny, celowy `GRANT EXECUTE` w swojej migracji.
- Test tworzy `public.csk_sec002_default_acl_probe()` po migracji i potwierdza rzeczywistą odmowę dla `PUBLIC`, `anon`, `authenticated` i `service_role`.
- Wszystkie 58 funkcji aplikacyjnych są własnością `postgres`, więc zabezpieczony creator obejmuje cały aktualny kontrakt aplikacji.

Platformowe defaults innych creatorów i defaults tabel/sekwencji nie są modyfikowane przez tę funkcjową remediation. Nie należą do powierzchni `EXECUTE` określonej w tym zadaniu.

## Migration operations

- `ALTER DEFAULT PRIVILEGES FOR ROLE postgres REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC`
- `ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM anon, authenticated, service_role`
- `REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC, anon`
- Jawny `GRANT` dla `anon` wyłącznie do `get_public_booking_configuration_v1()`
- `REVOKE` client/service dla ośmiu funkcji triggerowych
- `REVOKE service_role` dla czterech helperów ról/RLS; `authenticated` zachowuje jawny grant

Migracja nie zmienia definicji funkcji, tabel, danych, RLS, argumentów, return types ani logiki biznesowej. Dwukrotne wykonanie w jednej transakcji zakończonej `ROLLBACK` przeszło poprawnie.

## SECURITY DEFINER review

**PASS — 52 funkcje:** wszystkie są własnością `postgres`, mają jawny `search_path` i po zmianie nie mają `PUBLIC EXECUTE`. Ich dostęp odpowiada kategoriom A–D z macierzy.

```text
admin_create_event_v2, admin_create_event,
admin_create_lane_block, admin_create_lane_booking_family_v1,
admin_get_lane_booking_configuration_v1, admin_get_lane_booking_configuration_v2,
admin_list_users_v1, admin_set_event_active_v2, admin_set_event_active,
admin_set_lane_block_active, admin_set_lane_booking_configuration,
admin_set_lane_booking_family_configuration_v2,
admin_set_user_note_v1, admin_set_user_role_v1,
admin_update_event_v2, admin_update_event, admin_update_lane_block,
approve_event_registration, cancel_event_registration, cancel_reservation,
check_confirmation_email_rate_limit, complete_confirmation_email,
complete_event_reserve_promotion, confirm_event_reserve_promotion,
create_reservation_v2, create_reservation,
get_lane_booking_busy_ranges_v2, get_lane_booking_busy_ranges_v3,
get_lane_booking_busy_ranges, get_my_reservations_v2, get_my_role,
get_public_booking_configuration_v1, get_reservation_customer_profiles_v1,
handle_new_user, is_admin_or_employee, is_admin_or_staff, is_admin,
lane_booking_family_business_snapshot_v2,
normalize_lane_booking_family_payload_v2, prepare_confirmation_email,
prepare_event_reserve_promotions, prevent_non_admin_profile_privilege_changes,
register_for_event, update_profile_contact_details, update_profile_identity,
update_profile_verification, update_reservation_admin_note,
update_reservation_attendance, update_reservation_payment,
validate_lane_booking_rule_capacity, validate_shooting_lane_capacity_change,
validate_shooting_lane_hierarchy
```

- Writery dostępne dla `authenticated` zachowują istniejące `auth.uid()`/profile-role/ownership checks.
- Service-only functions zachowują tylko jawny `service_role EXECUTE`.
- Publiczny reader konfiguracji jest `STABLE`, ograniczony do nie-PII shape i nie mutuje danych.
- Trigger functions nie są bezpośrednio wykonywalne przez role klienckie.
- Nie znaleziono nowego, niezależnego argument-abuse lub role-escalation wymagającego zmiany funkcji w ramach SEC-002.

**PASS — SECURITY INVOKER/internal helpers:** `lock_lane_booking_configuration`, `lock_lane_conflict_families_v1`, `lock_lane_conflict_family_v1`, `resolve_lane_conflict_scope_v1`, `set_booking_configuration_updated_at`, `set_updated_at`. Żaden nie ma klientowskiego EXECUTE po migracji.

## Tests

```text
Supabase DB tests: PASS — Files=5, Tests=64, failed=0
Focused ACL tests: PASS — 17/17
Node tests: PASS — 540/540
TypeScript: PASS — npx.cmd tsc --noEmit
ESLint: PASS — changed TypeScript/TSX files
Build: PASS — npm.cmd run build
git diff --check: PASS — informational LF/CRLF warnings only
```

Focused SQL coverage includes:

- exact 58-signature inventory;
- exact ACL matrices for `anon`, `authenticated` and `service_role`;
- zero `PUBLIC EXECUTE` across all existing functions and the probe;
- real runtime DENY for anon privileged RPC;
- real runtime DENY for ordinary user against admin-only RPC;
- admin ALLOW, pracownik ALLOW on staff writer and user DENY;
- real service-role ALLOW reaching business validation;
- all trigger functions isolated from direct execution;
- creator default ACL and new-function runtime denial;
- all SECURITY DEFINER owner/search_path contracts;
- final exception when any assertion is false;
- one transaction ending in `ROLLBACK`, with no remaining fixture.

The initial local validation caught two harness/design issues and failed closed: an unauthorized attempt to alter platform-owned `supabase_admin` defaults, and the PostgreSQL global-vs-per-schema default behavior for built-in `PUBLIC EXECUTE`. Both were corrected without bypassing permissions. Final applicable runs pass.

## Security verdict

```text
POSTGRES ACL: PASS (function EXECUTE scope)
PUBLIC EXECUTE EXPOSURE: PASS
ANON RPC EXPOSURE: PASS
PRIVILEGED RPC ISOLATION: PASS
REGRESSION RISK: MEDIUM
```

Regression risk is `MEDIUM` because the migration changes execution privileges for every current public-schema function and global defaults for future postgres-owned functions. Risk is controlled by the exact 58-function matrix, actual role calls, full DB regression, application regression, successful build and explicit re-grants. No function definition or business behavior changed.

## OUT OF SCOPE FINDING

The source SEC-002 also documents broad default/table/sequence privileges. This remediation was explicitly limited to function/RPC `EXECUTE`; table and sequence ACL are unchanged and require a separate scoped remediation with their own DML/TRUNCATE regression analysis.

## Delivery status

- Production database: unchanged.
- Remote Supabase: not contacted or modified.
- Git commit: not performed.
- Git push: not performed.
- Deployment: not performed.
