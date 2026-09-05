# CSK Booking — EVENTS-8B implementation report

## Result

EVENTS-8B is implemented locally as an additive, paginated read layer for public events, the administrator event list and participants, and the current user's registrations. No production deployment, remote database operation, commit, or push was performed.

Verdict: **EVENTS-8B FULLY IMPLEMENTED — READY FOR DB-FIRST ROLLOUT**

## Root cause and old read model

The three event screens were bounded only by the amount of data currently present:

- `/events` fetched the complete public availability result and filtered/rendered it in the browser.
- `/admin/events` fetched all events together with nested lane relations, then loaded the complete participant list for the selected event.
- `/my-events` directly selected all owner-visible `event_registrations` with nested event data.

Those reads had no stable server-side pagination. The administrator path also transferred more registration data than its list needed, and growth in events or registrations increased browser work and response size. The public page was already PII-free after EVENTS-8A, but it still lacked a bounded list contract.

## New authoritative contracts

Migration `20260905190000_add_scalable_event_read_contracts.sql` adds four versioned `SECURITY DEFINER`, `STABLE` RPCs owned by `postgres`, each with `search_path = pg_catalog, public, pg_temp` and fail-closed argument/role validation:

1. `get_public_event_list_v2(text, text, integer, integer)`
   - title search, upcoming/all scope, stable date/time/id ordering, bounded pages (maximum 50);
   - returns event presentation fields plus authoritative `registered_count`, `reserve_count`, `available_spots`, and `sold_out`;
   - registration aggregates are computed only for the already selected page of events;
   - contains no registration identifiers, user identifiers, contact data, tokens, notes, or profile data.
2. `admin_list_events_v1(text, text, text, integer, integer)`
   - search, all/upcoming/past/inactive scope, nearest/latest sorting, stable pagination;
   - returns page rows with lane hierarchy display data and page-independent list totals.
3. `admin_list_event_registrations_v1(uuid, text, text, integer, integer)`
   - status and payment filters, stable pagination with maximum page size 50;
   - returns the existing minimal operational participant DTO and page-independent status/payment totals.
4. `get_my_event_registrations_v1(text, text, integer, integer)`
   - derives ownership exclusively from `auth.uid()`;
   - supports upcoming/history/all scope, status filtering, and stable pagination.

The public contract is executable only by `anon` and `authenticated`. The three authenticated contracts have no `PUBLIC`, `anon`, or `service_role` execute grant. Administrator reads preserve the existing route authorization model (`admin`, `pracownik`, and the currently deferred `instruktor` access) rather than changing SEC-008 as part of EVENTS-8B. Ordinary users fail closed.

No table RLS policy or table grant was widened. No browser-side `service_role` use was added.

## Count and status semantics

The public list preserves the canonical EVENTS-8A availability semantics:

- `registered` and `approved` occupy capacity;
- `reserve` is counted separately and does not occupy capacity;
- cancelled registrations do not occupy capacity;
- `available_spots` is clamped to zero;
- the existing atomic registration RPC remains the authority for preventing overbooking.

## Frontend changes

- `/events` now uses `get_public_event_list_v2`, with URL-backed title search and page state. It no longer depends on an unbounded result or any direct registration relation.
- `/admin/events` now uses `admin_list_events_v1` and `admin_list_event_registrations_v1`. Event search/scope/sort/page and participant status/payment/page are server-side and bounded.
- `/my-events` now uses `get_my_event_registrations_v1`; the direct nested `event_registrations` select was removed.
- URL query state is restored on reload/back-forward navigation. Invalid page values fail safely to page 1, and filter changes reset pagination.
- Existing event create/update/activation, registration, cancellation, payment, reserve promotion, and confirmation mutations were not changed.
- Existing controlled loading, empty, malformed-response, and error behavior remains fail closed.

## Scalability and indexes

The migration adds targeted indexes for the new stable access paths:

- `events_active_date_time_id_idx`
- `event_registrations_user_created_id_idx`
- `event_registrations_event_payment_created_id_idx`

The contracts perform one bounded RPC per list request rather than N+1 reads. Public aggregation is restricted to page event IDs. The DB contract test covers 500 events and 5,000 synthetic registrations, page boundaries, deterministic ordering, page-independent totals, and a maximum page size of 50. These checks establish bounded response behavior; they are not presented as a production load benchmark.

## Security and data minimization

- Public output is PII-free and does not expose registration IDs or internal tokens.
- My-events ownership is DB-derived and cannot be selected by a caller-supplied user ID.
- Participant output is limited to the operational fields already required by the administrator UI.
- Public and ordinary-user access to administrator reads is denied.
- Existing instructor behavior is preserved; the deferred instructor/event assignment model was not altered.
- The centralized function ACL inventory was updated from 71 to 75 functions and now covers all four signatures.

## Tests

- Focused EVENTS-8B Node tests: **46/46 PASS**.
- All Node tests: **674/674 PASS**.
- Focused EVENTS-8B DB contract: **28/28 PASS**.
- Complete local Supabase DB suite: **18 files, 378 tests, PASS**.
- Local database target: **127.0.0.1:54322**, verified before execution.
- TypeScript (`npx.cmd tsc --noEmit`): **PASS**.
- Next.js production build: **PASS**, 37 routes generated.
- Production dependency audit (`npm audit --omit=dev`): **0 vulnerabilities**.
- `git diff --check`: **PASS** (Git emitted line-ending notices only).
- Full ESLint: existing repository baseline **12 errors / 5 warnings**; **new EVENTS-8B regressions: 0**.

The known Next.js `middleware` to `proxy` deprecation warning remains unchanged and outside this feature.

## Compatibility and deployment order

| Application | Database | Result | Reason |
|---|---|---|---|
| Old | Old | SAFE | Existing contracts remain unchanged. |
| Old | New | SAFE | Migration is additive; old calls and behavior remain available. |
| New | Old | UNSAFE | New versioned RPCs do not exist; reads fail closed. |
| New | New | SAFE | Intended EVENTS-8B state. |

Recommended deployment: **DB FIRST**, verify the four signatures/ACLs, then deploy the application. Application rollback remains safe because the migration does not remove or change old contracts.

## Files changed

- `app/events/page.tsx`
- `app/admin/events/page.tsx`
- `app/admin/events/page.test.mjs`
- `app/my-events/page.tsx`
- `app/my-events/page.test.mjs`
- `lib/event-read-contracts.ts`
- `lib/event-read-contracts.test.mjs`
- `lib/public-event-availability.test.mjs`
- `supabase/migrations/20260905190000_add_scalable_event_read_contracts.sql`
- `supabase/tests/20260905190000_add_scalable_event_read_contracts_test.sql`
- `supabase/tests/20260816143000_harden_public_function_execute_acl_test.sql`
- `tsconfig.json`
- `EVENTS_8B_IMPLEMENTATION_REPORT.md`

## Scope confirmation

No production DB push, migration repair, linked Supabase operation, deployment, commit, or push was performed. EVENTS-8C, Reports, SaaS/tenant isolation, and the deferred instructor assignment model were not changed.
