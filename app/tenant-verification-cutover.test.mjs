import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const read = (path) => readFileSync(new URL(path, import.meta.url), "utf8");

test("global Account/Dashboard do not read implicit tenant verification; Booking is explicit", () => {
  for (const path of ["./account/page.tsx", "./dashboard/page.tsx"]) {
    assert.doesNotMatch(read(path), /get_my_active_tenant_verification_v1|active_single_tenant_id_v1/);
  }
  assert.match(read("./booking/BookingForm.tsx"), /get_my_tenant_verification_v2/);
  assert.doesNotMatch(read("./booking/BookingForm.tsx"), /get_my_active_tenant_verification_v1/);
  for (const path of ["./account/page.tsx", "./dashboard/page.tsx", "./booking/BookingForm.tsx"]) {
    const source = read(path);
    const profileSelects = [...source.matchAll(/\.from\("profiles"\)[\s\S]{0,1600}?\.select\(([\s\S]{0,1200}?)\)/g)];
    assert.ok(profileSelects.length > 0, `${path} must retain its owner profile read`);
    for (const [, selection] of profileSelects) {
      assert.doesNotMatch(selection, /verification_status|permissions_verified|permissions_verification_note/);
    }
  }
});

test("account no longer renders the sensitive staff verification note", () => {
  const source = read("./account/page.tsx");
  assert.doesNotMatch(source, /permissionsVerificationNote/);
  assert.doesNotMatch(source, /permissions_verification_note/);
});

test("check-in verification is bound to the reservation resource", () => {
  const source = read("./admin/check-in/page.tsx");
  assert.match(source, /update_reservation_customer_verification_v1/);
  assert.match(source, /p_reservation_id:\s*reservation\.id/);
  assert.doesNotMatch(source, /"update_profile_verification"/);
});
