# SAAS-9D-4D-2 — GLOBAL HELPER ACL CLOSURE

Updated: 2026-09-21 (Europe/Warsaw)

## Scope

The frozen 4D-2 scope was limited to the final client `EXECUTE` path on four
legacy global-role helpers:

- `public.get_my_role()`
- `public.is_admin()`
- `public.is_admin_or_employee()`
- `public.is_admin_or_staff()`

Their bodies, signatures, owner, `search_path` and `SECURITY DEFINER` mode are
unchanged. The functions remain owner-only compatibility objects for the
separate 9D-5 retirement gate. No application, RLS, table, data or role scope
was changed.

## Entry audit

- Active application/API runtime callers: **0 for each helper**.
- RLS policy dependencies: **0**.
- Database routine dependencies: **0**.
- Trigger dependencies: **0**.
- Production fingerprints: **4/4 match**.
- Trusted tenant context and canonical tenant routes: deployed in C3.
- Compatibility routes: production smoke PASS before and after closure.

## Implementation

Forward migration:

`20260929100000_close_global_role_helper_execute.sql`

SHA-256:

`4086E195BCE1F3A1CB0C107AC5231923BCBAED24132083990A3763BDC335D7AE`

The migration performs a fail-closed fingerprint, ACL and dependency preflight,
then revokes `EXECUTE` from `authenticated`. PUBLIC, `anon` and `service_role`
were already denied. Postcondition: all four client-facing roles are denied.

## Local verification

- Clean reset/replay through 20260929100000: PASS.
- Focused 4D-2 SQL: **12/12 PASS**.
- Central function ACL suite: **17/17 PASS**.
- Full Supabase DB suite: **52 files / 1555 tests PASS**.
- Node: **777/777 PASS**.
- TypeScript: PASS.
- Production build: PASS; existing middleware-to-proxy warning only.
- Playwright: **38/38 PASS** on a clean local replay.
- Fixture cleanup: 0 after final reset.
- `git diff --check`: PASS.

## Production preflight

- Project ref: `yuyxfodozzpzrdzkmolu`.
- LOCAL = REMOTE through `20260928100000`.
- Only pending migration: `20260929100000`.
- Dry-run: exactly one migration.
- Helper fingerprints: 4/4 PASS.
- Helper metadata: postgres owner, `SECURITY DEFINER`, `search_path=public`.
- Dependencies: policy 0, routine 0, trigger 0.
- SECURITY DEFINER baseline: 96.
- Compatibility defaults: 7/7.
- Active production tenants: exactly 1.

## Production deployment and verification

- `supabase db push --linked`: PASS; exactly migration 20260929100000.
- Migration history: LOCAL = REMOTE through 20260929100000.
- Final dry-run: `Remote database is up to date.`
- Production fingerprints: 4/4 PASS.
- PUBLIC/anon/authenticated/service_role EXECUTE: all DENIED, 4/4.
- Function bodies/signatures/owner/search_path/security mode: unchanged.
- SECURITY DEFINER count: 96; unexpected drift 0.
- Compatibility defaults: 7/7.
- Runtime smoke: public, dashboard, account, booking, events, owner pages and
  canonical Admin/Calendar/Reports/Users/Events/Lane Configuration all render
  without 5xx.
- Production data mutation/fixture: none.

## Verdict

SAAS-9D-4D-2 PRODUCTION DEPLOY: **PASS**

SAAS-9D-4D-2 POST-DEPLOY: **PASS**

ZERO ACTIVE APP CALLERS: **PASS (4/4 = 0)**

GLOBAL HELPER CLIENT EXECUTE: **CLOSED**

FUNCTION DEFINITIONS: **RETAINED UNCHANGED FOR 9D-5**

SECURITY DEFINER COUNT: **96**

COMPATIBILITY DEFAULTS: **7/7**

READY FOR GIT CHECKPOINT: **YES**

READY FOR SAAS-9D-5 ENTRY AUDIT: **GO AFTER CHECKPOINT**

SECOND TENANT: **NO-GO**

SEC-004: **OPEN**
