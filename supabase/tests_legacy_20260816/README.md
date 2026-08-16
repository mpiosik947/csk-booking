# Historical database tests absorbed by the 20260816090000 baseline

These files are preserved as references for the original migration lifecycle.
They are intentionally outside `supabase/tests/`, because `supabase test db`
starts from the consolidated current schema and must not replay historical DDL.

## Classification

### A — active current-state tests

Kept in `supabase/tests/`:

- `current_remote_baseline_contracts_test.sql` — current schema, RLS, ACL and RPC contracts.
- `20260816100000_add_admin_lane_booking_family_creation_test.sql` — current behavioral contract for the lane-family creator.
- `final_cross_writer_invariants.sql` — read-only integrity checks against the current schema.

### B — historical migration lifecycle tests

All SQL files in this directory originally embedded a migration, expected the
tested object to be absent before that migration, or asserted rollback to a
pre-migration schema. Those assumptions are deliberately false after the
consolidated baseline. Their original assertions and fixtures remain unchanged
here for audit/reference purposes.

### C — valuable scenarios requiring current fixtures before reactivation

The following groups contain behavior worth porting in future focused batches,
but their setup is coupled to removed historical DML or implicit profile
creation and therefore must not run as current baseline tests yet:

- `20260724071150_*`, `20260724081359_*`: lane fixtures need current hierarchy fields, including `resource_kind` and `parent_lane_id`.
- `20260804062227_*`, `20260804113522_*`, `20260810133000_*`, `20260814133431_*`: depend on former production-like initial lane inserts; replacements must use isolated `[TEST]` families.
- `20260808194442_*`: relies on a historical `auth.users` profile trigger; current tests must insert synthetic profiles explicitly.
- Availability, Reservation V2, Lane Blocks, Events V2, controlled reservation operations, instructor scope, user-management and configuration writer tests: retain valuable role/business scenarios, but must be rewritten as current-contract tests without `\ir`, migration preflights or rollback-to-absence assertions.

No production data or backup fixture is permitted when porting these scenarios.
