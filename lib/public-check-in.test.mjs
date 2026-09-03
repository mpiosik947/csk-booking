import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

async function publicCheckInSource() {
  return readFile(
    new URL("../app/check-in/[token]/page.tsx", import.meta.url),
    "utf8"
  );
}

test("public check-in uses the anonymous minimal-status RPC", async () => {
  const source = await publicCheckInSource();

  assert.match(source, /NEXT_PUBLIC_SUPABASE_ANON_KEY/);
  assert.match(source, /"get_public_check_in_status_v1"/);
  assert.match(source, /p_token: token/);
  assert.doesNotMatch(source, /SUPABASE_SERVICE_ROLE_KEY|service_role/i);
  assert.doesNotMatch(source, /\.from\("reservations"\)/);
});

test("public check-in accepts only the exact neutral DTO", async () => {
  const source = await publicCheckInSource();

  assert.match(source, /keys\.length !== 2/);
  assert.match(source, /keys\[0\] !== "code" \|\| keys\[1\] !== "ok"/);
  assert.match(source, /"ready"/);
  assert.match(source, /"already_checked_in"/);
  assert.match(source, /"unavailable"/);
});

test("public check-in renders no reservation PII or operational details", async () => {
  const source = await publicCheckInSource();

  for (const forbidden of [
    "customer_name",
    "customer_email",
    "customer_phone",
    "reservation_date",
    "start_time",
    "end_time",
    "payment_status",
    "attendance_status",
    "shooting_lanes",
    "check_in_token",
  ]) {
    assert.doesNotMatch(source, new RegExp(`\\b${forbidden}\\b`));
  }
  assert.match(source, /Dane rezerwacji są dostępne wyłącznie/);
});

test("public GET remains read-only and fail-closed", async () => {
  const source = await publicCheckInSource();

  assert.match(source, /UUID_PATTERN\.test\(token\)/);
  assert.doesNotMatch(source, /\.insert\(|\.update\(|\.delete\(/);
  assert.doesNotMatch(source, /update_reservation_attendance/);
  assert.match(source, /Kod jest nieprawidłowy, nieaktywny albo wygasł/);
  assert.match(source, /Ponowne otwarcie kodu nie wykonuje/);
});

test("public token page suppresses referrers and indexing", async () => {
  const source = await publicCheckInSource();

  assert.match(source, /referrer: "no-referrer"/);
  assert.match(source, /robots: \{ index: false, follow: false \}/);
  assert.match(source, /dynamic = "force-dynamic"/);
  assert.doesNotMatch(source, /console\.(?:log|error)\([^\n]*token/);
});
