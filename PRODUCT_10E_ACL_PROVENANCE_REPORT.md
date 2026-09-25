# PRODUCT-10E ACL provenance audit

Date: 2026-09-24. Audit only; no remediation or continuation of PRODUCT-10E.

Repository HEAD: `80341fe4c9512e5fcd719963aa636777098cf705`.

## Scope and evidence

Objects: `public.confirmation_email_rate_limits` and
`public.lane_booking_family_configuration_versions`.

Production was queried read-only through the existing SQL Editor for project
`yuyxfodozzpzrdzkmolu`. Observed production migration head: `20261008110000`.
Three catalog SELECT statements inspected raw ACL, `aclexplode`,
`information_schema.role_table_grants`, effective DML privileges, RLS, policies,
and functions referencing these two tables. No production DML/DDL was executed.

Fresh local replay used a newly created disposable database in
`supabase_db_csk-booking`, whose published DB port is 54322. The existing local
application database was not reset or modified. The managed schemas were copied
schema-only; the scratch public schema was rebuilt from the complete 124-file
migration chain ending at `20261009140000_preserve_onboarding_account_lifecycle.sql`.
Every source migration was executed unchanged. ACL was inspected after every
migration. No test assertion was edited or transformed for this audit.

Audit runner, outside the repository:
`C:/Users/Mpios/Desktop/APP Krutla/acl-provenance-audit.mjs`.

## Historical ACL timeline — both tables

| Migration / source | Action | Role | Cumulative service_role effect |
|---|---|---|---|
| `20260816090000_remote_baseline.sql`, lines 9666/9869 | Creates both tables; owner postgres; RLS enabled later in the file | postgres | No explicit table grant to service_role |
| Same migration, lines 11108–11111, after the table creation statements | `ALTER DEFAULT PRIVILEGES ... GRANT ALL ON TABLES` | postgres, anon, authenticated, service_role | Applies to subsequently created tables, not these already-created tables; still none |
| `20260816100000_add_admin_lane_booking_family_creation.sql` | Uses the version table; grants/revokes apply to the RPC, not its table | authenticated / public roles for function EXECUTE | Unchanged |
| `20260902120000_harden_public_table_sequence_acl.sql`, lines 4–12 | Revokes default/current table and sequence privileges from PUBLIC, anon, authenticated | Not service_role | service_role unchanged; relacl becomes explicit owner-only |
| All subsequent migrations through `20261009140000` | No observed ACL change on either table | — | None |

The baseline file was introduced by `1442563` (2026-08-16, "Consolidate Supabase
migration baseline") and has no later Git changes. Searches covered all migrations,
including broad/default grants; the per-migration catalog snapshots additionally
covered dynamically generated SQL. Later account lifecycle and lane-family
migrations reference the tables but do not add direct service_role table grants.

## Test provenance

`supabase/tests/20260902120000_harden_public_table_sequence_acl_test.sql`:

- line 37: confirmation table expected service ACL
  `{MAINTAIN,REFERENCES,TRIGGER,TRUNCATE}`;
- line 44: version table has the same expectation;
- check 6, lines 131–133, compares the complete explicit service_role ACL with
  that expected array using the `pg_temp.table_privileges` / `aclexplode` helper;
- checks for PUBLIC/anon/authenticated separately require no privileges on these
  two tables.

Both service-role arrays were introduced unchanged in commit
`d04c17163b8eb4717bbcfa0d040163140a267b7e` on 2026-09-02
("security: remediate high severity audit findings"). Git blame and history show
no later update to these two arrays. This is a maintained cumulative regression
test, not a test isolated to a historical checkpoint: its surrounding inventory
has received subsequent SaaS/product changes.

No later migration was found that deliberately changed these two service ACLs
from the asserted four privileges to the current state. The assertion is not
supported by the committed baseline's table grants or by current production.
The exact external environment/snapshot that originally produced the four-value
expectation is not available in the audited evidence; it must not be invented.

Other tests referencing these tables cover existence, data, optimistic versions,
cleanup, or schema ownership. The explicit exact service_role table ACL assertions
for these objects are the two rows consumed by check 6 above.

## Fresh replay versus production

| Object | Historical-order fresh replay | Production | Test expectation | Match |
|---|---|---|---|---|
| confirmation_email_rate_limits | service_role `{}` | service_role `{}` | `{MAINTAIN,REFERENCES,TRIGGER,TRUNCATE}` | Replay = production; test differs |
| lane_booking_family_configuration_versions | service_role `{}` | service_role `{}` | `{MAINTAIN,REFERENCES,TRIGGER,TRUNCATE}` | Replay = production; test differs |

For each table, fresh replay and production both have:

```text
owner = postgres
RLS = true
raw relacl = {postgres=arwdDxtm/postgres}
aclexplode entries for service_role = 0
information_schema.role_table_grants entries for service_role = 0
```

Production additionally confirmed policies = 0 and effective
`has_table_privilege(service_role, ..., SELECT/INSERT/UPDATE/DELETE) = false`
for all four operations on both objects.

Fresh replay inventory: migration head `20261009140000`, 124 migrations,
SECURITY DEFINER = 97, TCM table and three TCM RPCs absent. Scratch cleanup = 0.
This is ACL provenance evidence, not a claim of full PRODUCT-10E test-suite PASS.

## Why the previous replay had eight privileges

The existing, unmodified
`scripts/product10e-isolated-schema-check.mjs` restores current public-schema
default privileges before replaying the historical baseline. In particular, this
injects `postgres|public|r|{postgres=arwdDxtm/postgres,service_role=arwdDxtm/postgres}`
before these tables are created. Both tables then inherit ALL privileges for
service_role. Later migrations preserve that preexisting service_role ACL.

A separate control replay uses exactly that initialization and confirms the
extra grants arise at `20260816090000_remote_baseline.sql`, not in PRODUCT-10E.
At that point both tables have:

```text
relacl = {postgres=arwdDxtm/postgres,service_role=arwdDxtm/postgres}
aclexplode = DELETE,INSERT,MAINTAIN,REFERENCES,SELECT,TRIGGER,TRUNCATE,UPDATE
role_table_grants = DELETE,INSERT,REFERENCES,SELECT,TRIGGER,TRUNCATE,UPDATE
```

The information_schema view does not list MAINTAIN in this environment; the raw
ACL/aclexplode output is therefore necessary for the complete eight-item set.

No grant was manually removed from an existing database to obtain the matching
replay. The matching run simply did not move end-state defaults ahead of their
historical creation point. Both audit runs used independent new scratch databases.
The original isolation script remains unmodified pending a separate remediation
decision.

The control run also completed all 124 migrations through `20261009140000`:
both eight-privilege ACLs remained unchanged after the baseline, SECURITY DEFINER
was 97, TCM objects were absent, and its scratch cleanup was 0. Thus both complete
runs finished successfully and neither left a disposable database behind.

## Runtime and security interpretation

### confirmation_email_rate_limits

No direct app/lib table access was found. The three server email endpoints call
`check_confirmation_email_rate_limit(uuid,text)` through a server-side
service-role client. Production metadata confirms this RPC is SECURITY DEFINER,
owner postgres, `search_path=public, pg_temp`, with EXECUTE only for postgres and
service_role. Its table operations therefore use the owner's authority; they do
not require a direct table grant to service_role.

`anonymize_my_account_v1()` also deletes the account's technical rate-limit rows.
It is SECURITY DEFINER, owner postgres, and authenticated EXECUTE. This is a
separate authenticated account lifecycle contract, not a direct table permission.

Absence of service_role direct DML is consistent with these paths. Broad direct
DML would allow a holder of service credentials to read/alter limiter state
outside the rate-limit RPC (including user-scope identifiers/HMAC IP scope keys),
but no such direct production grant exists. This audit did not send email or run
account deletion to prove behavior dynamically.

### lane_booking_family_configuration_versions

No direct app/lib table access was found. The admin lane-configuration page calls
`admin_get_lane_booking_configuration_v3`,
`admin_create_lane_booking_family_v2`, and
`admin_set_lane_booking_family_configuration_v3`.

The table-referencing cores observed on production are SECURITY INVOKER,
postgres-owned, `search_path=pg_catalog, public, pg_temp`, owner-only EXECUTE:

- `admin_create_lane_booking_family_v2__saas9ec2b_core(uuid,jsonb)`;
- `admin_get_lane_booking_configuration_v3__saas9ec2b_core(uuid)`;
- `admin_set_lane_booking_family_configuration_v2__saas9d3c_core(uuid,bigint,jsonb,boolean)`.

They are delegated to by protected SECURITY DEFINER wrappers. Within that call
chain the effective owner supplies table access. Direct service_role table DML
is not required. Such DML would unnecessarily permit bypassing the wrapper's
version/locking/tenant workflow; it is absent on production. The former test's
TRUNCATE permission is not harmless merely because it is non-DML; there is no
runtime justification for restoring it here.

## Decision

**CASE A for canonical historical-order replay: replay = production; test
expectation is stale.** An additional local harness initialization defect explains
the previously reported broader replay ACL. This is not evidence of a deployed
migration ordering defect or production drift (CASE B/D), and no excessive
production ACL was found requiring CASE C remediation.

Recommended next action, requiring a separate change scope:

1. Correct isolated replay bootstrap so current public defaults are not injected
   before the historical baseline.
2. Update only the two stale service_role expected arrays to `{}`, preserving all
   other authorization assertions and adding a regression for bootstrap provenance.
3. Rerun the isolated PRODUCT-10E gate through `20261009140000`, without TCM.

Do not add production grants to satisfy the old test. Do not change historical
migrations. No remediation was performed during this audit.

```text
PRODUCTION DRIFT: NO (these two ACLs)
TEST BASELINE STALE: YES
SECURITY REMEDIATION REQUIRED: NO (production ACLs); local harness/test correction required
PRODUCT-10E READY TO RESUME: NO
PRODUCTION WRITE: NO
TEST ASSERTIONS CHANGED: NO
APPLICATION / MIGRATIONS CHANGED: NO
GIT STAGING / COMMIT / PUSH: NO
TCM: FROZEN
```
