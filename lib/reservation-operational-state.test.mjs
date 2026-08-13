import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const source = readFileSync(
  new URL("./reservation-operational-state.ts", import.meta.url),
  "utf8"
);
const checkIn = readFileSync(
  new URL("../app/admin/check-in/page.tsx", import.meta.url),
  "utf8"
);
const reservations = readFileSync(
  new URL("../app/admin/reservations/page.tsx", import.meta.url),
  "utf8"
);

test("operational state classifier is fail-closed", () => {
  assert.match(source, /state === "planned"[\s\S]*\["start", "no_show"\]/);
  assert.match(source, /state === "present"[\s\S]*\["complete", "reset"\]/);
  assert.match(source, /return \[\];/);
  assert.match(source, /return "invalid";/);
});

test("planned exposes START and NO-SHOW but not COMPLETE", () => {
  assert.match(source, /reservationStatus === RESERVATION_STATUS\.CONFIRMED/);
  assert.match(source, /attendanceStatus === "planned"/);
});

test("present exposes COMPLETE and RESET but not START or NO-SHOW", () => {
  assert.match(source, /attendanceStatus === "present"/);
  assert.match(source, /hasCheckedInAt/);
});

test("completed, no-show, cancelled and invalid states expose no actions", () => {
  for (const state of ["completed", "no_show", "cancelled", "invalid"]) {
    assert.match(source, new RegExp(`return "${state}"`));
  }
  assert.doesNotMatch(source, /state === "completed"\) return \[/);
  assert.doesNotMatch(source, /state === "no_show"\) return \[/);
  assert.doesNotMatch(source, /state === "cancelled"\) return \[/);
});

test("check-in renders actions only from the shared matrix", () => {
  assert.match(
    checkIn,
    /getReservationAttendanceActions\(\s*reservation\s*\)/
  );
  assert.match(checkIn, /attendanceActions\.includes\("start"\)/);
  assert.match(checkIn, /attendanceActions\.includes\("complete"\)/);
  assert.match(checkIn, /attendanceActions\.includes\("no_show"\)/);
  assert.match(checkIn, /attendanceActions\.includes\("reset"\)/);
  assert.match(
    checkIn,
    /!isInstructor \|\| \(action !== "start" && action !== "reset"\)/
  );
});

test("reservations use controlled action choices and no generic status writer", () => {
  assert.match(reservations, /getReservationAttendanceActions\(reservation\)/);
  assert.match(reservations, /value="start"/);
  assert.match(reservations, /value="complete"/);
  assert.match(reservations, /value="no_show"/);
  assert.match(reservations, /value="reset"/);
  assert.doesNotMatch(reservations, /reservation_status: event\.target\.value/);
});

test("admin cancellation is exposed only with the planned action matrix", () => {
  assert.match(
    reservations,
    /attendanceActions\.includes\("no_show"\)[\s\S]*cancelReservationWithRpc\(reservation\)/
  );
  assert.match(reservations, />\s*Anuluj rezerwację\s*</);
});

test("runtime reservation operations still contain no direct table update", () => {
  for (const runtimeSource of [checkIn, reservations]) {
    assert.doesNotMatch(
      runtimeSource,
      /\.from\(["']reservations["']\)[\s\S]{0,400}?\.update\(/
    );
  }
});
