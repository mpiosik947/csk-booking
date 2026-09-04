import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import {
  getConfirmEventReserveMessage,
  getConfirmEventReserveStatus,
  isConfirmEventReserveResult,
  parseConfirmEventReservePayload,
} from "./event-reserve-confirmation-contract.ts";

const token = "6c030000-0000-4000-8000-000000000030";
const eventId = "6c030000-0000-4000-8000-000000000010";
const registrationId = "6c030000-0000-4000-8000-000000000020";

test("confirmation payload accepts only one UUID token", () => {
  assert.deepEqual(parseConfirmEventReservePayload({ token }), {
    ok: true,
    token,
  });
  assert.deepEqual(parseConfirmEventReservePayload({ token, user_id: eventId }), {
    ok: false,
  });
  assert.deepEqual(parseConfirmEventReservePayload({ token: "not-a-token" }), {
    ok: false,
  });
});

test("confirmation RPC response contract is fail-closed", () => {
  assert.equal(
    isConfirmEventReserveResult({
      ok: true,
      code: "confirmed",
      message: "confirmed",
      event_id: eventId,
      registration_id: registrationId,
    }),
    true
  );
  assert.equal(
    isConfirmEventReserveResult({
      ok: true,
      code: "confirmed",
      message: "confirmed",
    }),
    false
  );
  assert.equal(
    isConfirmEventReserveResult({
      ok: false,
      code: "unknown",
      message: "details",
    }),
    false
  );
});

test("confirmation response codes retain controlled HTTP semantics", () => {
  assert.equal(getConfirmEventReserveStatus("confirmed"), 200);
  assert.equal(getConfirmEventReserveStatus("not_found"), 404);
  assert.equal(getConfirmEventReserveStatus("expired"), 410);
  assert.equal(getConfirmEventReserveStatus("full"), 409);
  assert.equal(getConfirmEventReserveStatus("not_reserve"), 409);
  assert.equal(
    getConfirmEventReserveMessage("not_found"),
    "Nie znaleziono aktywnego zaproszenia."
  );
});

test("public GET page is read-only and renders only the explicit confirmation form", async () => {
  const source = await readFile(
    new URL("../../app/events/confirm/[token]/page.tsx", import.meta.url),
    "utf8"
  );

  assert.match(source, /ConfirmEventReserveForm/);
  assert.doesNotMatch(source, /createClient|serviceRole|SUPABASE_SERVICE_ROLE_KEY/);
  assert.doesNotMatch(source, /\.rpc\(|\.update\(|\.insert\(|\.delete\(/);
  assert.doesNotMatch(source, /Resend|sendConfirmedPlaceEmail|fetch\(/);
});

test("mutation is an authenticated POST without a service-role client", async () => {
  const source = await readFile(
    new URL(
      "../../app/api/confirm-event-reserve-promotion/route.ts",
      import.meta.url
    ),
    "utf8"
  );

  assert.match(source, /export async function POST/);
  assert.doesNotMatch(source, /export async function GET/);
  assert.match(source, /verifyAuthUser/);
  assert.match(source, /status: 401/);
  assert.match(source, /error\.code === "42501"/);
  assert.match(source, /status: 403/);
  assert.match(source, /confirm_event_reserve_promotion/);
  assert.match(source, /\.eq\("user_id", authResult\.user\.id\)/);
  assert.doesNotMatch(source, /SUPABASE_SERVICE_ROLE_KEY|serviceRole/);
});

test("browser performs no automatic request and submits POST with the session token", async () => {
  const source = await readFile(
    new URL(
      "../../app/events/confirm/[token]/ConfirmEventReserveForm.tsx",
      import.meta.url
    ),
    "utf8"
  );

  assert.match(source, /<form onSubmit={confirmPlace}>/);
  assert.match(source, /method: "POST"/);
  assert.match(source, /Authorization: `Bearer \$\{session\.access_token\}`/);
  assert.match(source, /JSON\.stringify\(\{ token \}\)/);
  assert.match(source, /if \(!session\?\.access_token\)/);
  assert.doesNotMatch(source, /useEffect|method: "GET"/);
  assert.doesNotMatch(source, /response\.message|response\.error/);
});

test("migration derives authorization from auth.uid and narrows EXECUTE", async () => {
  const source = await readFile(
    new URL(
      "../../supabase/migrations/20260816130000_secure_event_reserve_confirmation_post.sql",
      import.meta.url
    ),
    "utf8"
  );

  assert.match(source, /v_user_id uuid := auth\.uid\(\)/);
  assert.match(source, /v_registration_user_id is distinct from v_user_id/);
  assert.match(source, /registration\.user_id = v_user_id/);
  assert.match(source, /grant execute[\s\S]*to authenticated/);
  assert.match(source, /revoke all[\s\S]*from service_role/);
  assert.doesNotMatch(source, /disable row level security|alter table[\s\S]*disable/);
});
