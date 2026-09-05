import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const source = readFileSync(new URL("./page.tsx", import.meta.url), "utf8");

test("account profile save uses the allowlisted self-service RPC", () => {
  assert.match(source, /rpc\(\s*"update_my_profile_v1"/);
  assert.doesNotMatch(source, /\.from\("profiles"\)\s*\.update\(/);
});

test("account passes only contact and declaration fields to the self-service RPC", () => {
  for (const parameter of [
    "p_phone",
    "p_postal_code",
    "p_city",
    "p_street",
    "p_house_number",
    "p_apartment_number",
    "p_permission_sport",
    "p_permission_collector",
    "p_permission_hunting",
    "p_permission_training",
    "p_permission_personal_protection",
    "p_permission_other",
    "p_qualification_instructor",
    "p_qualification_range_officer",
    "p_qualification_pzss_license",
    "p_qualification_hunter",
  ]) {
    assert.match(source, new RegExp(`\\b${parameter}\\s*:`));
  }

  assert.doesNotMatch(source, /p_(?:user_id|role|verification_status|admin_note|created_at)\s*:/);
});

test("account keeps the declaration re-verification UX", () => {
  assert.match(source, /profileResult\.declarations_changed/);
  assert.match(source, /setVerificationStatus\(profileResult\.verification_status \?\? "pending"\)/);
  assert.match(source, /Zmiana deklarowanych uprawnień wymaga ponownej weryfikacji/);
});
