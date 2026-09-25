import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const page=readFileSync(new URL("./TenantAdminSettings.tsx",import.meta.url),"utf8");
const shell=readFileSync(new URL("../../t/[slug]/[...path]/page.tsx",import.meta.url),"utf8");
const routes=readFileSync(new URL("../../../lib/tenant-routing.ts",import.meta.url),"utf8");
const permissions=readFileSync(new URL("../../../lib/admin/route-protection.js",import.meta.url),"utf8");

test("settings UI uses only tenant-scoped RPC contracts",()=>{
  assert.match(page,/admin_get_tenant_content_v1/u);
  assert.match(page,/admin_update_tenant_content_v1/u);
  assert.match(page,/p_tenant_slug:tenantSlug/u);
  assert.doesNotMatch(page,/p_tenant_id|profiles\.role|service_role/u);
});

test("settings route is registered and admin-only",()=>{
  assert.match(shell,/admin\/settings/u);
  assert.match(routes,/"admin\/settings"/u);
  assert.match(permissions,/"\/admin\/settings": Object\.freeze\(\["admin"\]\)/u);
});

test("form covers public profile and all seven presentation toggles",()=>{
  for(const field of ["display_name","city","logo_path","hero_image_path","description","regulations_path","public_address","public_phone","public_email","opening_hours","social_links","show_booking","show_pricing","show_instructor","show_events","show_about","show_contact","show_regulations"]){assert.match(page,new RegExp(field,"u"));}
  assert.match(page,/Obsługa uploadu.+nie jest częścią PRODUCT-10C/u);
});
