import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const reservationRouteUrl = new URL("./reservations/[id]/route.ts", import.meta.url);
const eventRouteUrl = new URL("./event-registrations/[id]/route.ts", import.meta.url);
const routeHelperUrl = new URL("../../../lib/server/calendar-export-route.ts", import.meta.url);
const buttonUrl = new URL("../../_components/AddToCalendarButton.tsx", import.meta.url);
const reservationPageUrl = new URL("../../my-reservations/page.tsx", import.meta.url);
const eventPageUrl = new URL("../../my-events/page.tsx", import.meta.url);

test("calendar routes require bearer auth and use only the authenticated anon client", async () => {
  const helper = await readFile(routeHelperUrl, "utf8");
  assert.match(helper, /authorization\?\.match\(\/\^Bearer/u);
  assert.match(helper, /verifyAuthUser\(\(\) => supabase\.auth\.getUser\(accessToken\)\)/u);
  assert.match(helper, /createClient\(supabaseUrl, anonKey/u);
  assert.doesNotMatch(helper, /SERVICE_ROLE|serviceRole/iu);
  assert.match(helper, /"unauthorized", 401/u);
  assert.match(helper, /"auth_unavailable"/u);
});

test("reservation route is owner-scoped and hides foreign or missing records", async () => {
  const source = await readFile(reservationRouteUrl, "utf8");
  assert.match(source, /\.rpc\("get_my_reservations_v2"\)/u);
  assert.match(source, /\.eq\("id", id\)/u);
  assert.match(source, /\.maybeSingle\(\)/u);
  assert.match(source, /"not_found", 404/u);
  assert.match(source, /isCancelledReservationStatus/u);
  assert.match(source, /"invalid_status", 409/u);
  assert.doesNotMatch(source, /service.role|service_role/iu);
});

test("event registration route enforces owner and confirmed status scope", async () => {
  const source = await readFile(eventRouteUrl, "utf8");
  assert.match(source, /\.from\("event_registrations"\)/u);
  assert.match(source, /\.eq\("user_id", context\.user\.id\)/u);
  assert.match(source, /EVENT_REGISTRATION_STATUS\.REGISTERED/u);
  assert.match(source, /EVENT_REGISTRATION_STATUS\.APPROVED/u);
  assert.match(source, /"invalid_status", 409/u);
  assert.match(source, /"not_found", 404/u);
  assert.doesNotMatch(source, /service.role|service_role/iu);
});

test("database projections exclude customer PII, notes and token columns", async () => {
  const reservation = await readFile(reservationRouteUrl, "utf8");
  const event = await readFile(eventRouteUrl, "utf8");
  const eventProjection = event.match(/\.select\("([^"]+)"\)/u)?.[1] ?? "";
  for (const forbidden of [
    "customer_email",
    "customer_phone",
    "customer_name",
    "admin_note",
    "check_in_token",
    "confirmation_token",
    "user_id",
  ]) {
    assert.doesNotMatch(eventProjection, new RegExp(forbidden, "iu"));
    assert.doesNotMatch(reservation, new RegExp(`SUMMARY:[^\\n]*${forbidden}`, "iu"));
  }
});

test("ICS responses use attachment, no-store, nosniff and safe fixed filenames", async () => {
  const [helper, reservation, event] = await Promise.all([
    readFile(routeHelperUrl, "utf8"),
    readFile(reservationRouteUrl, "utf8"),
    readFile(eventRouteUrl, "utf8"),
  ]);
  assert.match(helper, /"Content-Type": ICS_CONTENT_TYPE/u);
  assert.match(helper, /"Content-Disposition": `attachment; filename=/u);
  assert.match(helper, /"Cache-Control": ICS_CACHE_CONTROL/u);
  assert.match(helper, /"X-Content-Type-Options": "nosniff"/u);
  assert.match(reservation, /"csk-rezerwacja\.ics"/u);
  assert.match(event, /"csk-szkolenie\.ics"/u);
});

test("UI exposes CTA only on active reservations and registered or approved events", async () => {
  const [button, reservations, events] = await Promise.all([
    readFile(buttonUrl, "utf8"),
    readFile(reservationPageUrl, "utf8"),
    readFile(eventPageUrl, "utf8"),
  ]);
  assert.match(button, /Dodaj do kalendarza/u);
  assert.match(button, /Authorization: `Bearer \$\{session\.access_token\}`/u);
  assert.match(button, /URL\.createObjectURL/u);
  assert.doesNotMatch(button, /Google|Apple|Microsoft|OAuth|webcal/iu);
  assert.match(reservations, /activeReservations\.map/u);
  assert.match(reservations, /api\/calendar\/reservations/u);
  assert.doesNotMatch(
    reservations.slice(reservations.indexOf("reservationHistory.map")),
    /api\/calendar\/reservations/u,
  );
  assert.match(events, /EVENT_REGISTRATION_STATUS\.REGISTERED/u);
  assert.match(events, /EVENT_REGISTRATION_STATUS\.APPROVED/u);
  assert.match(events, /api\/calendar\/event-registrations/u);
});

test("calendar endpoints are GET-only and expose controlled errors", async () => {
  const sources = await Promise.all([
    readFile(reservationRouteUrl, "utf8"),
    readFile(eventRouteUrl, "utf8"),
  ]);
  for (const source of sources) {
    assert.match(source, /export async function GET/u);
    assert.doesNotMatch(source, /export async function (POST|PUT|PATCH|DELETE)/u);
    assert.doesNotMatch(source, /\.insert\(|\.update\(|\.delete\(|\.rpc\("(?:create|update|delete|cancel)/u);
    assert.doesNotMatch(source, /error\.message|error\.details|error\.hint/u);
  }
});
