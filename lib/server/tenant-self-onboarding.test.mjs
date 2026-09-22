import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const root = new URL("../../", import.meta.url);

test("global registration remains account-only and has no tenant onboarding", async () => {
  const source = await readFile(new URL("app/register/page.tsx", root), "utf8");
  assert.match(source, /supabase\.auth\.signUp/);
  assert.doesNotMatch(source, /self_onboard_tenant_v1|tenant_memberships|tenant_id/);
});

for (const [file, resource, writer] of [
  ["app/api/create-reservation/route.ts", "shooting_lanes", "create_reservation_v2"],
  ["app/api/register-event/route.ts", "events", "register_for_event"],
]) {
  test(`${file} binds a resource before onboarding and business write`, async () => {
    const source = await readFile(new URL(file, root), "utf8");
    const binding = source.indexOf(`tenantResourceMatches(supabase, tenantSlug, "${resource}"`);
    const onboarding = source.indexOf("selfOnboardTenantUser(supabase, tenantSlug, authResult.user.id)");
    const write = source.indexOf(`"${writer}"`);
    assert.ok(binding >= 0 && onboarding > binding && write > onboarding);
    assert.match(source, /if \(!tenantSlug \|\|/);
    assert.doesNotMatch(source, /SUPABASE_SERVICE_ROLE_KEY|service_role/);
  });
}

test("server onboarding adapter exposes no role or tenant id input", async () => {
  const source = await readFile(new URL("lib/server/tenant-self-onboarding.ts", root), "utf8");
  assert.match(source, /self_onboard_tenant_v1/);
  assert.deepEqual(source.match(/p_[a-z_]+:/g), ["p_tenant_slug:"]);
  assert.doesNotMatch(source, /p_role|p_tenant_id|profiles\.role|active_single_tenant_id_v1/);
});

test("global account and dashboard do not create tenant relationships", async () => {
  for (const file of ["app/account/page.tsx", "app/dashboard/page.tsx"]) {
    const source = await readFile(new URL(file, root), "utf8");
    assert.doesNotMatch(source, /selfOnboardTenantUser|self_onboard_tenant_v1/);
  }
});
