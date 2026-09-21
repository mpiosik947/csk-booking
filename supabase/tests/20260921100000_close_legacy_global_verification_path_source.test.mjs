import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import test from "node:test";

const root = resolve(import.meta.dirname, "..", "..");
const read = (path) => readFileSync(resolve(root, path), "utf8");

test("update_profile_verification has no active application caller after tenant cutover", () => {
  const files = [
    "app/admin/users/page.tsx",
    "app/admin/check-in/page.tsx",
    "app/account/page.tsx",
    "app/booking/BookingForm.tsx",
    "app/dashboard/page.tsx",
    "app/api/send-reservation-cancellation/route.ts",
  ];
  const callers = files.filter((file) =>
    /"update_profile_verification"/.test(read(file)),
  );
  assert.deepEqual(callers, []);
  assert.match(read("app/admin/users/page.tsx"), /"update_tenant_profile_verification_v2"/);
});

test("active application profile reads do not select legacy verification fields", () => {
  for (const file of [
    "app/account/page.tsx",
    "app/booking/BookingForm.tsx",
    "app/dashboard/page.tsx",
  ]) {
    const source = read(file);
    for (const selection of source.matchAll(/\.from\("profiles"\)[\s\S]{0,300}?\.select\(([^;]+?)\)/g)) {
      assert.doesNotMatch(
        selection[1],
        /verification_status|permissions_verified|permissions_verification_note|verified_at|unverified_at/,
        `${file} must obtain tenant verification from its tenant RPC`,
      );
    }
  }
});

test("4B-2C migration removes only the global mirror and employee compatibility", () => {
  const migration = read(
    "supabase/migrations/20260921100000_close_legacy_global_verification_path.sql",
  );
  const core = migration.match(
    /create or replace function public\._apply_tenant_user_verification_v1[\s\S]+?\$function\$;/,
  )?.[0];
  const compatibility = migration.match(
    /create or replace function public\.update_profile_verification[\s\S]+?\$function\$;/,
  )?.[0];
  assert.ok(core);
  assert.ok(compatibility);
  assert.doesNotMatch(core, /update public\.profiles|profile_verification_rpc_/);
  assert.doesNotMatch(compatibility, /profiles\.role|['"]employee['"]/);
  assert.match(compatibility, /v_actor_role is distinct from 'admin'/);
  assert.match(compatibility, /_apply_tenant_user_verification_v1/);
});

test("4B-2C leaves application code and frozen trigger outside implementation scope", () => {
  const migration = read(
    "supabase/migrations/20260921100000_close_legacy_global_verification_path.sql",
  );
  assert.doesNotMatch(
    migration,
    /create or replace function public\.prevent_non_admin_profile_privilege_changes/,
  );
  assert.match(migration, /d28cb697d8355a5e8005296a03ad63ea/);
  assert.doesNotMatch(migration, /drop column|alter table public\.profiles/);
});
