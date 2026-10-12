import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { createHash } from "node:crypto";
import test from "node:test";
import ts from "typescript";
import { CREATE_RESERVATION_MESSAGES } from "../lib/server/create-reservation-contract.ts";
import { createIcsCalendar, getCalendarUid } from "../lib/server/icalendar.ts";

const read = (path) => readFileSync(new URL("../" + path, import.meta.url), "utf8");
function sources(path) {
  return readdirSync(new URL("../" + path, import.meta.url), { withFileTypes: true })
    .flatMap(entry => entry.isDirectory() ? sources(path + "/" + entry.name)
      : /\.(?:tsx?|jsx?)$/.test(entry.name) && !/\.(?:test|spec)\./.test(entry.name)
        ? [path + "/" + entry.name] : []);
}

test("shared runtime has no legacy presentation brand; explicit compatibility files are retained", () => {
  const compatibility = new Set(["lib/platform-domain.ts", "lib/tenant-routing.ts", "lib/server/icalendar.ts"]);
  for (const path of [...sources("app"), ...sources("lib")]) {
    if (!compatibility.has(path)) assert.doesNotMatch(read(path), /CSK|Krutla|csk-booking|login-brand\.png/i, path);
  }
});

test("booking contact messages address the selected range consistently in client and server", () => {
  const source = ts.createSourceFile("BookingForm.tsx", read("app/booking/BookingForm.tsx"), ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
  let messages;
  function visit(node) {
    if (ts.isVariableDeclaration(node) && node.name.getText(source) === "CODE_MESSAGES") {
      messages = Object.fromEntries(node.initializer.properties.map(p => [p.name.getText(source), p.initializer.text]));
    }
    ts.forEachChild(node, visit);
  }
  visit(source);
  for (const code of ["profile_rejected", "contact_required"]) {
    assert.equal(messages[code], CREATE_RESERVATION_MESSAGES[code]);
    assert.match(messages[code], /obsługą tej strzelnicy/);
    assert.doesNotMatch(messages[code], /CSK|StrzelajTu/);
  }
});

test("owner export UI and response use the same platform filename", () => {
  assert.match(read("app/account/page.tsx"), /link\.download = "strzelajtu-my-data\.json"/);
  assert.match(read("app/api/account/export/route.ts"), /attachment; filename="strzelajtu-my-data\.json"/);
});

test("calendar download filenames are presentation only", () => {
  assert.match(read("app/my-reservations/page.tsx"), /filename="strzelajtu-rezerwacja\.ics"/);
  assert.match(read("app/my-events/page.tsx"), /filename="strzelajtu-szkolenie\.ics"/);
});

test("calendar UID seed, namespace and PRODID remain compatible while dynamic tenant content is preserved", () => {
  const id = "10000000-0000-4000-8000-000000000001";
  const expectedUid = createHash("sha256").update("csk-booking:reservation:" + id).digest("hex") + "@calendar.csk-booking";
  assert.equal(getCalendarUid("reservation", id), expectedUid);
  for (const name of ["Centrum Szkolenia Krutla", "Druga strzelnica"]) {
    const ics = createIcsCalendar({ recordType: "reservation", recordId: id, date: "2030-01-15", startTime: "10:00", endTime: "11:00", summary: name, description: "Rezerwacja", location: name });
    assert.ok(ics);
    assert.match(ics, /PRODID:-\/\/CSK Booking\/\/Calendar Export\/\/PL\r\n/);
    assert.ok(ics.replace(/\r\n /g, "").includes("UID:" + expectedUid + "\r\n"));
    assert.ok(ics.includes("SUMMARY:" + name + "\r\n"));
    assert.ok(ics.includes("LOCATION:" + name + "\r\n"));
  }
});

test("global token and legal shells use accessible platform logos at their intrinsic aspect ratio", () => {
  const asset = readFileSync(new URL("../public/brand/strzelajtu/logo-horizontal.png", import.meta.url));
  const width = asset.readUInt32BE(16), height = asset.readUInt32BE(20);
  for (const path of ["app/check-in/[token]/page.tsx", "app/events/confirm/[token]/page.tsx", "app/privacy/page.tsx", "app/terms/page.tsx"]) {
    const images = [...read(path).matchAll(/<Image\s[\s\S]*?\/>/g)];
    assert.ok(images.length);
    for (const [image] of images) {
      assert.match(image, /src="\/brand\/strzelajtu\/logo-horizontal.png"/);
      assert.match(image, /alt="StrzelajTu.pl"/);
      assert.ok(image.includes(`width={${width}}`));
      assert.ok(image.includes(`height={${height}}`));
      assert.match(image, /h-auto/);
    }
  }
  assert.ok(readFileSync(new URL("../public/login-brand.png", import.meta.url)).length > 0);
});
