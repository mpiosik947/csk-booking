import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const actionsSource = readFileSync(
  new URL("./reservation-actions.ts", import.meta.url),
  "utf8"
);
const reservationsPage = readFileSync(
  new URL("../app/admin/reservations/page.tsx", import.meta.url),
  "utf8"
);
const checkInPage = readFileSync(
  new URL("../app/admin/check-in/page.tsx", import.meta.url),
  "utf8"
);

test("operational reservation mutations use only dedicated RPCs", () => {
  assert.match(actionsSource, /update_reservation_attendance/);
  assert.match(actionsSource, /update_reservation_payment/);
  assert.match(actionsSource, /update_reservation_admin_note/);
  assert.match(actionsSource, /cancel_reservation/);

  for (const source of [actionsSource, reservationsPage, checkInPage]) {
    assert.doesNotMatch(
      source,
      /\.from\(["']reservations["']\)[\s\S]{0,300}?\.update\(/
    );
  }
});

test("start and complete are separate attendance actions", () => {
  assert.match(checkInPage, /type AttendanceAction = "start" \| "complete" \| "no_show"/);
  assert.match(checkInPage, /"start",\s*"Konto i uprawnienia zweryfikowane\. Wizyta rozpoczęta\."/);
  assert.match(checkInPage, /"Rozpocznij wizytę"/);
  assert.match(checkInPage, /"Zakończ wizytę"/);
  assert.match(actionsSource, /runAttendanceAction\(supabase, options, "start"\)/);
  assert.match(actionsSource, /runAttendanceAction\(supabase, options, "complete"\)/);
  assert.match(checkInPage, /result\.action !== "start"/);
  assert.match(checkInPage, /if \(!result\.ok\)/);
  assert.match(checkInPage, /getAttendanceResultMessage\(result\.code\)/);
});

test("payment helper accepts only the requested status argument", () => {
  assert.match(
    actionsSource,
    /update_reservation_payment[\s\S]*p_reservation_id:[\s\S]*p_payment_status:/
  );
  assert.match(
    checkInPage,
    /updatePaymentStatus\(reservation, event\.target\.value\)/
  );
  assert.match(
    reservationsPage,
    /updateReservationPayment\(supabase, \{[\s\S]*paymentStatus: changes\.payment_status/
  );
});

test("critical operational audits are not inserted by the client", () => {
  assert.doesNotMatch(checkInPage, /\.from\(["']audit_logs["']\)\.insert/);
  assert.doesNotMatch(actionsSource, /actor_user_id|actor_role|actor_name/);
});

test("controlled RPC failures do not expose raw database messages", () => {
  assert.doesNotMatch(actionsSource, /error\.message/);
  assert.match(actionsSource, /CONTROLLED_ERROR_MESSAGES/);
  assert.match(actionsSource, /Nie udało się zapisać zmiany\. Spróbuj ponownie\./);
});
