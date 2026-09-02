# SECURITY REMEDIATION 02B — TABLE / SEQUENCE ACL

## Finding

```text
SEC-ID: SEC-002
Severity: HIGH
Scope: TABLE / SEQUENCE ACL
```

Date: 2026-09-02

Environment used for validation: local Supabase only (`127.0.0.1`)

Production operations: none

## Inventory

```text
Tables audited: 14
Sequences audited: 0
Owners audited: postgres, supabase_admin
Default privilege definitions audited: TABLES and SEQUENCES in schema public
```

All 14 existing application tables are owned by `postgres`, have RLS enabled, and have no `PUBLIC` table grant. No sequence currently exists in `public`.

Privilege abbreviations used below:

```text
S = SELECT
I = INSERT
U = UPDATE
D = DELETE
T = TRUNCATE
R = REFERENCES
G = TRIGGER
M = MAINTAIN
US = USAGE (sequence)
- = none
```

## Classification and intended access

| Table | Class | Intended anon | Intended authenticated | service_role review |
|---|---|---|---|---|
| `audit_logs` | E — audit/security-sensitive | none | SELECT and INSERT under RLS | REVIEW — backend audit/maintenance needs DML, but technical rights require a separate service-role review |
| `confirmation_email_rate_limits` | D — internal/system | none | none | REVIEW — preserved exactly; access is normally owner-mediated by SECURITY DEFINER RPC |
| `email_deliveries` | D — internal/system | none | none | REVIEW — backend delivery lifecycle needs DML; technical rights were not reduced in this remediation |
| `event_lanes` | C — staff/admin data | none | SELECT under staff RLS | REVIEW — backend/maintenance access preserved |
| `event_registrations` | B — authenticated user data | none | SELECT plus existing staff INSERT/DELETE paths under RLS | REVIEW — backend registration and promotion workflows preserved |
| `events` | A — public read | SELECT active rows | SELECT under RLS | REVIEW — backend/maintenance access preserved |
| `lane_blocks` | C — staff/admin data | none | SELECT under RLS | REVIEW — backend/maintenance access preserved |
| `lane_booking_durations` | A — public read | SELECT active rows | SELECT under RLS | REVIEW — configuration maintenance access preserved |
| `lane_booking_family_configuration_versions` | D — internal/system | none | none | REVIEW — preserved exactly; writer is owner-mediated |
| `lane_booking_rules` | A — public read | SELECT public rows | SELECT under RLS | REVIEW — configuration maintenance access preserved |
| `lane_pricing_rules` | A — public read | SELECT active rows | SELECT under RLS | REVIEW — configuration maintenance access preserved |
| `profiles` | B — authenticated user data | none | SELECT/INSERT/UPDATE under existing ownership/admin RLS | REVIEW — Auth/backend administration needs broad DML; technical rights need separate review |
| `reservations` | B — authenticated user data | none | SELECT and existing admin DELETE under RLS | REVIEW — backend reservation lifecycle access preserved |
| `shooting_lanes` | A — public read | SELECT active rows | SELECT under RLS | REVIEW — configuration maintenance access preserved |

No `service_role` privilege was changed. This is deliberate: distinguishing operational DML from technical privileges such as `TRUNCATE`, `REFERENCES`, `TRIGGER`, and `MAINTAIN` requires a separate service-role threat model and was explicitly excluded from mechanical reduction.

## ACL BEFORE

The matrix expands every effective `ALL` table grant, including PostgreSQL 17 `MAINTAIN`.

| Table | PUBLIC | anon | authenticated | service_role | RLS |
|---|---|---|---|---|---|
| `audit_logs` | - | S,I,U,D,T,R,G,M | S,I,U,D,T,R,G,M | S,I,U,D,T,R,G,M | on |
| `confirmation_email_rate_limits` | - | T,R,G,M | T,R,G,M | T,R,G,M | on |
| `email_deliveries` | - | T,R,G,M | T,R,G,M | S,I,U,D,T,R,G,M | on |
| `event_lanes` | - | T,R,G,M | S,T,R,G,M | S,I,U,D,T,R,G,M | on |
| `event_registrations` | - | S,I,D,T,R,G,M | S,I,D,T,R,G,M | S,I,U,D,T,R,G,M | on |
| `events` | - | S,T,R,G,M | S,T,R,G,M | S,I,U,D,T,R,G,M | on |
| `lane_blocks` | - | S,T,R,G,M | S,T,R,G,M | S,I,U,D,T,R,G,M | on |
| `lane_booking_durations` | - | S,T,R,G,M | S,T,R,G,M | S,I,U,D,T,R,G,M | on |
| `lane_booking_family_configuration_versions` | - | T,R,G,M | T,R,G,M | T,R,G,M | on |
| `lane_booking_rules` | - | S,T,R,G,M | S,T,R,G,M | S,I,U,D,T,R,G,M | on |
| `lane_pricing_rules` | - | S,T,R,G,M | S,T,R,G,M | S,I,U,D,T,R,G,M | on |
| `profiles` | - | S,I,U,D,T,R,G,M | S,I,U,D,T,R,G,M | S,I,U,D,T,R,G,M | on |
| `reservations` | - | S,D,T,R,G,M | S,D,T,R,G,M | S,I,U,D,T,R,G,M | on |
| `shooting_lanes` | - | S,T,R,G,M | S,T,R,G,M | S,I,U,D,T,R,G,M | on |

## ACL AFTER

| Table | PUBLIC | anon | authenticated | service_role | RLS |
|---|---|---|---|---|---|
| `audit_logs` | - | - | S,I | S,I,U,D,T,R,G,M | on |
| `confirmation_email_rate_limits` | - | - | - | T,R,G,M | on |
| `email_deliveries` | - | - | - | S,I,U,D,T,R,G,M | on |
| `event_lanes` | - | - | S | S,I,U,D,T,R,G,M | on |
| `event_registrations` | - | - | S,I,D | S,I,U,D,T,R,G,M | on |
| `events` | - | S | S | S,I,U,D,T,R,G,M | on |
| `lane_blocks` | - | - | S | S,I,U,D,T,R,G,M | on |
| `lane_booking_durations` | - | S | S | S,I,U,D,T,R,G,M | on |
| `lane_booking_family_configuration_versions` | - | - | - | T,R,G,M | on |
| `lane_booking_rules` | - | S | S | S,I,U,D,T,R,G,M | on |
| `lane_pricing_rules` | - | S | S | S,I,U,D,T,R,G,M | on |
| `profiles` | - | - | S,I,U | S,I,U,D,T,R,G,M | on |
| `reservations` | - | - | S,D | S,I,U,D,T,R,G,M | on |
| `shooting_lanes` | - | S | S | S,I,U,D,T,R,G,M | on |

No RLS policy was changed. Existing `event_registrations` authenticated `UPDATE` remains absent at ACL level, exactly as before this remediation; 02B neither grants nor removes it.

## Sequence ACL BEFORE / AFTER

There are no existing sequences in `public`, so no live sequence grant was removed. A transaction-created probe sequence proves that future `postgres` sequences grant no `USAGE`, `SELECT`, or `UPDATE` to `PUBLIC`, `anon`, or `authenticated`.

## Default privileges BEFORE / AFTER

### Owner `postgres`, schema `public`

| Object | BEFORE | AFTER |
|---|---|---|
| TABLES | `postgres=ALL`, `anon=ALL`, `authenticated=ALL`, `service_role=ALL` | `postgres=ALL`, `service_role=ALL`; no PUBLIC/anon/authenticated grant |
| SEQUENCES | `postgres=USAGE,SELECT,UPDATE`, `anon=USAGE,SELECT,UPDATE`, `authenticated=USAGE,SELECT,UPDATE`, `service_role=USAGE,SELECT,UPDATE` | `postgres=USAGE,SELECT,UPDATE`, `service_role=USAGE,SELECT,UPDATE`; no PUBLIC/anon/authenticated grant |

### Owner `supabase_admin`, schema `public`

The managed owner still has its platform-defined broad defaults for `anon` and `authenticated` on future tables and sequences. The migration role `postgres` is neither a member of nor permitted to assume `supabase_admin`, so PostgreSQL rejects attempts to alter that owner's defaults. No existing application table or sequence is owned by `supabase_admin`.

This residual is not hidden or treated as remediated. It requires a separately authorized platform-owner operation (SECURITY REMEDIATION 02C or an equivalent Supabase-supported control).

## Removed privileges

Existing table privilege edges removed:

| Role | SELECT | INSERT | UPDATE | DELETE | TRUNCATE | REFERENCES | TRIGGER | MAINTAIN | USAGE | Total |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| anon | 5 | 3 | 2 | 4 | 14 | 14 | 14 | 14 | 0 | 70 |
| authenticated | 0 | 0 | 1 | 2 | 14 | 14 | 14 | 14 | 0 | 59 |
| service_role | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| PUBLIC | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |

Default ACL entries for future `postgres`-owned objects were additionally removed for:

```text
anon TABLE: SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN
authenticated TABLE: SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN
anon SEQUENCE: USAGE, SELECT, UPDATE
authenticated SEQUENCE: USAGE, SELECT, UPDATE
```

## Migration

`supabase/migrations/20260902120000_harden_public_table_sequence_acl.sql`

The migration:

1. revokes client defaults for future `postgres`-owned tables and sequences in `public`,
2. removes all current `PUBLIC`, `anon`, and `authenticated` table/sequence grants,
3. restores only the explicit client allowlist above,
4. leaves every `service_role` grant, function, RPC, RLS policy, and data row unchanged.

## Tests

```text
Focused ACL: PASS — 29/29, exit code 0
Default table test: PASS — NEW TABLE SAFE DEFAULT
Default sequence test: PASS — NEW SEQUENCE SAFE DEFAULT
TRUNCATE negative tests: PASS — actual SQL deny for anon and authenticated
REFERENCES negative tests: PASS — actual FK DDL denied for authenticated
TRIGGER negative tests: PASS — actual CREATE TRIGGER denied for authenticated
Positive flows: PASS — public event read, public config RPC, own profile read/update,
                      own reservation read, admin audit insert/read
Double application: PASS — identical relation ACL hash after both applications
Rollback cleanup: PASS — probe objects and all [TEST][SEC-002B] fixtures absent
Supabase DB: PASS — Files=6, Tests=93
Node: PASS — 540/540
TypeScript: PASS — npx.cmd tsc --noEmit
ESLint: FAIL (pre-existing baseline) — 14 errors and 6 warnings in unrelated existing TS/TSX files;
        no SQL file introduced an ESLint finding
Build: PASS — Next.js production build, 35/35 static pages
git diff --check: PASS (informational LF/CRLF warnings only on pre-existing modified files)
```

The project has no `npm test` script; it is not reported as PASS. The actual lightweight Node suite was executed directly with `node --test` over all `*.test.mjs` files.

## Security review

- Client `TRUNCATE` exposure: removed from all 14 tables and proven by real SQL denial.
- Client `REFERENCES` exposure: removed from all 14 tables and proven by real FK DDL denial.
- Client `TRIGGER` exposure: removed from all 14 tables and proven by real trigger DDL denial.
- Client `MAINTAIN` exposure: removed from all 14 tables.
- Existing sequence exposure: none exists.
- Future `postgres` table/sequence exposure: removed and proven with transaction-created probes.
- Functions/RPC: unchanged; REMEDIATION 02 remains intact and its DB tests pass.
- RLS: unchanged.
- Production database: untouched.

## Verdict

```text
TABLE ACL: PASS
SEQUENCE ACL: PASS
DEFAULT TABLE PRIVILEGES: PARTIAL (postgres PASS; supabase_admin unresolved)
DEFAULT SEQUENCE PRIVILEGES: PARTIAL (postgres PASS; supabase_admin unresolved)
CLIENT TRUNCATE EXPOSURE: PASS
CLIENT REFERENCES EXPOSURE: PASS
CLIENT TRIGGER EXPOSURE: PASS

SEC-002 OVERALL:
PARTIALLY REMEDIATED
```

The remaining condition is precise: default TABLE and SEQUENCE privileges owned by managed role `supabase_admin` still grant broad rights to `anon` and `authenticated`. It is a **CONFIRMED configuration state** and a **POTENTIAL future exposure** if that owner creates an object in `public`; no current application object is affected. Because a future PII table could inherit client access, the residual retains HIGH impact and requires a separately authorized remediation. Full closure is also blocked procedurally by the pre-existing full-project ESLint failures required by the completion criteria.
