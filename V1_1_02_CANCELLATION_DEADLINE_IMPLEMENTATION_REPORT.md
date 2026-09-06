# V1.1-02 — Exact cancellation deadline

## Scope and repository

- Repository: `C:\Users\Mpios\Desktop\APP Krutla\APP Krutla\csk-booking`
- Initial HEAD: `5839cc934c753506bc1bfc6f2d4109a2883f318b`
- Initial working tree: clean
- Deployment model: application only
- Database, SQL, migrations and backend cancellation functions: unchanged

## Implementation

The customer views now show the exact self-service cancellation deadline for
each eligible active item:

- reservations: event start minus 12 elapsed hours,
- event registrations: event start minus 72 elapsed hours.

Both views use the existing canonical Warsaw civil-time conversion. The
displayed deadline is formatted in `Europe/Warsaw` and explicitly names that
time zone. The comparison is inclusive at the exact cutoff, matching the
backend rules. The calculation uses elapsed milliseconds from the resolved
instant, so it remains safe across the spring and autumn DST transitions.

Before the cutoff, the exact deadline and the existing cancellation action are
shown. After the cutoff, the action is hidden and a clear message states that
the self-service cancellation deadline has passed. Cancelled and historical
items do not receive a misleading deadline.

The backend remains authoritative: the existing reservation RPC and event
cancellation API are unchanged and still validate every mutation.

## Files changed

- `app/my-reservations/page.tsx`
- `app/my-events/page.tsx`
- `lib/event-time.ts`
- `lib/event-time.test.mjs`
- `lib/my-reservations.test.mjs`
- `app/my-events/page.test.mjs`
- `tests/e2e/cancellation-deadline.spec.ts`
- `V1_1_02_CANCELLATION_DEADLINE_IMPLEMENTATION_REPORT.md`

## Verification

- Focused deadline tests: PASS — 20/20
- All Node tests: PASS — 699/699
- Relevant Playwright: PASS — 9/9
- Mobile 320/375/430: PASS for reservations and events
- TypeScript (`npx.cmd tsc --noEmit`): PASS
- Production build (`npm.cmd run build`): PASS
- Changed-files ESLint: PASS
- `npm audit --omit=dev`: PASS — 0 vulnerabilities
- `git diff --check`: PASS

Known non-blocking build warning: Next.js reports the existing deprecated
`middleware` file convention. V1.1-02 does not change middleware/proxy code.

## Compatibility

- Reservation deadline: PASS
- Event deadline: PASS
- Backend/UI consistency: PASS
- Boundary semantics: PASS
- Europe/Warsaw: PASS
- DST: PASS
- Mobile UX: PASS
- DB change required: NO
- Deployment model: APP ONLY

## Verdict

V1.1-02 EXACT CANCELLATION DEADLINE: FULLY IMPLEMENTED

RESERVATION DEADLINE: PASS

EVENT DEADLINE: PASS

BACKEND / UI CONSISTENCY: PASS

BOUNDARY SEMANTICS: PASS

EUROPE/WARSAW: PASS

DST: PASS

MOBILE UX: PASS

DB CHANGE REQUIRED: NO

DEPLOYMENT MODEL: APP ONLY
