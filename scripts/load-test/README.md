# Local reservation load test

This harness is intentionally local-only. It reads `.env.local`, accepts only
`localhost`, `127.0.0.1`, or `::1`, and aborts before creating fixtures when a
Supabase or application target is remote. It never contains production keys.

Run a local production-style Next.js server first, then execute:

```powershell
npm.cmd run test:load:local
```

Optional settings:

- `LOADTEST_SCENARIO=all|baseline|hundred|race|parallel|ramp|storm|mixed`
- `LOADTEST_USERS=100..500`
- `LOADTEST_CONCURRENCY=1..500`
- `LOADTEST_OPERATIONS=<count>` for a single selected scenario
- `LOADTEST_DURATION_SECONDS=<deadline>`
- `LOADTEST_FAMILY_COUNT=1..50`
- `LOADTEST_POSITIONS_PER_FAMILY=1..20`
- `LOADTEST_TARGET_URL=http://127.0.0.1:3000`

Every fixture name or note starts with `[LOADTEST]`. Results are written to the
ignored `scripts/load-test/results/latest.json`. Always finish with
`npx.cmd supabase db reset --local`.
