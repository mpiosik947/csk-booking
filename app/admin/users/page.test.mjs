import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const pagePath = new URL("./page.tsx", import.meta.url);
const middlewarePath = new URL("../../../middleware.ts", import.meta.url);

test("admin users uses hardened read and mutation RPCs", async () => {
  const source = await readFile(pagePath, "utf8");

  assert.match(source, /rpc\("admin_list_users_v1"/);
  assert.match(source, /rpc\("admin_set_user_role_v1"/);
  assert.match(source, /rpc\("admin_set_user_note_v1"/);
  assert.match(source, /p_limit:\s*pageSize/);
  assert.match(source, /p_offset:\s*page \* pageSize/);
  assert.doesNotMatch(source, /\.from\("profiles"\)\s*\.select\(\s*`/);
  assert.doesNotMatch(source, /\.from\("profiles"\)\s*\.update\(/);
  assert.doesNotMatch(source, /\.from\("audit_logs"\)\s*\.insert\(/);
});

test("role selection requires an explicit confirmed save", async () => {
  const source = await readFile(pagePath, "utf8");

  assert.match(source, /setRoleDrafts/);
  assert.match(source, /window\.confirm/);
  assert.match(source, />\s*Zapisz rolę\s*</);
  assert.doesNotMatch(source, /onChange=\{\(event\)\s*=>\s*updateAdminProfile/);
});

test("admin users route is admin-only in middleware", async () => {
  const source = await readFile(middlewarePath, "utf8");
  assert.match(source, /"\/admin\/users": \["admin"\]/);
  assert.doesNotMatch(source, /"\/admin\/users": \["admin", "pracownik"\]/);
});
