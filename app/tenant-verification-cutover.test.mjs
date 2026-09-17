import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const read = (path) => readFileSync(new URL(path, import.meta.url), "utf8");

test("owner surfaces read tenant verification through the controlled RPC", () => {
  for (const path of ["./account/page.tsx", "./dashboard/page.tsx", "./booking/BookingForm.tsx"]) {
    const source = read(path);
    assert.match(source, /get_my_active_tenant_verification_v1/);
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
