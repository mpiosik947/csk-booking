import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const exportRouteUrl = new URL("./export/route.ts", import.meta.url);
const deleteRouteUrl = new URL("./delete/route.ts", import.meta.url);
const accountPageUrl = new URL("../../account/page.tsx", import.meta.url);

test("owner export is authenticated, parameterless and returns a JSON attachment", async () => {
  const source = await readFile(exportRouteUrl, "utf8");

  assert.match(source, /export async function GET\(request: Request\)/u);
  assert.match(source, /verifyAuthUser/u);
  assert.match(source, /supabase\.rpc\("export_my_data_v1"\)/u);
  assert.match(source, /url\.searchParams\.keys\(\)/u);
  assert.match(source, /Content-Disposition/u);
  assert.match(source, /csk-booking-my-data\.json/u);
  assert.match(source, /Cache-Control/u);
  assert.doesNotMatch(source, /SUPABASE_SERVICE_ROLE_KEY/u);
  assert.doesNotMatch(source, /p_user_id|targetUserId/u);
});

test("self-delete is POST-only, verifies caller and never accepts a user id", async () => {
  const source = await readFile(deleteRouteUrl, "utf8");

  assert.match(source, /export async function POST\(request: Request\)/u);
  assert.doesNotMatch(source, /export async function GET/u);
  assert.match(source, /verifyAuthUser/u);
  assert.match(source, /REQUIRED_CONFIRMATION = "USUŃ KONTO"/u);
  assert.match(source, /Object\.keys\(parsedBody\)\.length !== 1/u);
  assert.match(source, /supabase\.rpc\("anonymize_my_account_v1"\)/u);
  assert.match(source, /deleteUser\(authResult\.user\.id\)/u);
  assert.doesNotMatch(source, /body\.userId|p_user_id|targetUserId/u);
});

test("service role is isolated to the server-side Auth deletion operation", async () => {
  const source = await readFile(deleteRouteUrl, "utf8");
  const authIndex = source.indexOf("verifyAuthUser");
  const adminIndex = source.indexOf("const authAdmin = createClient");
  const rpcIndex = source.indexOf('supabase.rpc("anonymize_my_account_v1")');
  const deleteIndex = source.indexOf("authAdmin.auth.admin.deleteUser");

  assert.match(source, /process\.env\.SUPABASE_SERVICE_ROLE_KEY/u);
  assert.ok(authIndex !== -1 && authIndex < adminIndex);
  assert.ok(adminIndex < rpcIndex && rpcIndex < deleteIndex);
  assert.equal((source.match(/authAdmin\./gu) ?? []).length, 1);
});

test("account UI exposes export and explicit destructive confirmation", async () => {
  const source = await readFile(accountPageUrl, "utf8");

  assert.match(source, /Pobierz moje dane/u);
  assert.match(source, /Usuń konto/u);
  assert.match(source, /USUŃ KONTO/u);
  assert.match(source, /\/api\/account\/export/u);
  assert.match(source, /\/api\/account\/delete/u);
  assert.match(source, /method: "POST"/u);
  assert.match(source, /deletingAccount/u);
  assert.match(source, /disabled=\{deletingAccount/u);
  assert.match(source, /supabase\.auth\.signOut\(\)/u);
  assert.match(source, /window\.location\.assign\("\/"\)/u);
});
