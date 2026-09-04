import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { ADMIN_ROUTE_PERMISSIONS } from "../../../lib/admin/route-protection.js";

const pagePath = new URL("./page.tsx", import.meta.url);

test("admin users keeps hardened server-side read and writer RPCs", async () => {
  const source = await readFile(pagePath, "utf8");

  assert.match(source, /rpc\("admin_list_users_v1"/);
  assert.match(source, /rpc\("admin_set_user_role_v1"/);
  assert.match(source, /rpc\("admin_set_user_note_v1"/);
  assert.match(source, /rpc\("update_profile_verification"/);
  assert.match(source, /p_limit:\s*PAGE_SIZE/);
  assert.match(source, /p_offset:\s*page \* PAGE_SIZE/);
  assert.match(source, /p_search:\s*search\.trim\(\) \|\| null/);
  assert.match(source, /p_role:\s*roleFilter === "all" \? null : roleFilter/);
  assert.match(source, /p_verification_filter:/);
  assert.match(source, /p_sort:\s*sort/);
  assert.doesNotMatch(source, /\.from\("profiles"\)\s*\.select\(/);
  assert.doesNotMatch(source, /\.from\("profiles"\)\s*\.update\(/);
  assert.doesNotMatch(source, /\.from\("audit_logs"\)\s*\.insert\(/);
});

test("list provides server filters, supported sorting and bounded pagination", async () => {
  const source = await readFile(pagePath, "utf8");

  assert.match(source, /Szukaj po imieniu, e-mailu lub telefonie/);
  assert.match(source, /Wszystkie role/);
  assert.match(source, /Wszystkie statusy/);
  for (const sort of ["newest", "oldest", "name", "role"]) {
    assert.match(source, new RegExp(`value: "${sort}"`));
  }
  assert.match(source, /const PAGE_SIZE = 25/);
  assert.match(source, /Poprzednia/);
  assert.match(source, /Następna/);
  assert.match(source, /aria-current="page"/);
  assert.match(source, /setPage\(0\)/);
});

test("desktop table and mobile cards show concise badges and details action", async () => {
  const source = await readFile(pagePath, "utf8");

  assert.match(source, /hidden overflow-hidden[\s\S]*md:block/);
  assert.match(source, /grid gap-3 md:hidden/);
  for (const column of ["Użytkownik", "Kontakt", "Rola", "Weryfikacja", "Utworzono", "Akcje"]) {
    assert.match(source, new RegExp(column));
  }
  for (const role of ["Admin", "Pracownik", "Instruktor", "Użytkownik"]) {
    assert.match(source, new RegExp(role));
  }
  assert.match(source, /Szczegóły/);
  assert.match(source, /min-h-11/);
});

test("details are an accessible dialog with compact semantic sections", async () => {
  const source = await readFile(pagePath, "utf8");

  assert.match(source, /role="dialog"/);
  assert.match(source, /aria-modal="true"/);
  assert.match(source, /aria-labelledby="user-details-title"/);
  assert.match(source, /event\.key === "Escape"/);
  assert.match(source, /event\.key !== "Tab"/);
  assert.match(source, /detailsTriggerRef\.current\?\.focus/);
  for (const section of ["Dane podstawowe", "Adres", "Rola", "Weryfikacja", "Kwalifikacje", "Uprawnienia", "Notatka administratora"]) {
    assert.match(source, new RegExp(section));
  }
  assert.match(source, /if \(!value\?\.trim\(\)\) return null/);
  assert.match(source, /getAddress\(selectedProfile\)\.length > 0/);
  assert.match(source, /rpc\("update_profile_identity"/);
  assert.match(source, /rpc\("update_profile_contact_details"/);
  assert.match(source, /Zapisz dane podstawowe/);
  assert.match(source, /Zapisz dane kontaktowe/);
});

test("details render every active declared permission and qualification", async () => {
  const source = await readFile(pagePath, "utf8");

  const declarations = [
    ["permission_sport", "Sportowe"],
    ["permission_collector", "Kolekcjonerskie"],
    ["permission_hunting", "Łowieckie"],
    ["permission_training", "Szkoleniowe"],
    ["permission_personal_protection", "Ochrona osobista"],
    ["permission_other", "Inne"],
    ["qualification_instructor", "Instruktor"],
    ["qualification_range_officer", "Prowadzący strzelanie"],
    ["qualification_pzss_license", "Licencja PZSS"],
    ["qualification_hunter", "Myśliwy"],
  ];

  for (const [field, label] of declarations) {
    assert.match(source, new RegExp(`profile\\.${field}`));
    assert.match(source, new RegExp(`result\\.push\\("${label}"\\)`));
  }
  assert.match(source, /getPermissions\(selectedProfile\)\.map/);
  assert.match(source, /getQualifications\(selectedProfile\)\.map/);
  assert.match(source, /aria-label="Zadeklarowane uprawnienia"/);
  assert.match(source, /aria-label="Zadeklarowane kwalifikacje"/);
});

test("declarations card is visible when empty and precedes role and verification", async () => {
  const source = await readFile(pagePath, "utf8");
  const declarationsHeading = "Deklarowane uprawnienia i kwalifikacje";
  const emptyState = "Brak zadeklarowanych uprawnień i kwalifikacji.";
  const roleHeading = '<h3 className="font-semibold text-[#f2efe4]">Rola</h3>';
  const verificationHeading = '<h3 className="font-semibold text-[#f2efe4]">Weryfikacja</h3>';

  assert.match(source, new RegExp(declarationsHeading));
  assert.match(source, new RegExp(emptyState.replace(".", "\\.")));
  assert.match(source, /Deklaracje nie są równoznaczne z ich weryfikacją przez administratora\./);
  assert.ok(source.indexOf(declarationsHeading) > source.indexOf("Adres i kontakt"));
  assert.ok(source.indexOf(declarationsHeading) < source.indexOf(roleHeading));
  assert.ok(source.indexOf(declarationsHeading) < source.indexOf(verificationHeading));
});

test("role selection requires an explicit confirmed save and handles last admin", async () => {
  const source = await readFile(pagePath, "utf8");

  assert.match(source, /setRoleDrafts/);
  assert.match(source, /window\.confirm/);
  assert.match(source, /Zapisz zmianę roli/);
  assert.match(source, /admin_set_user_role_v1/);
  assert.match(source, /Nie można zmienić roli ostatniego administratora\./);
  assert.match(source, /pełny dostęp administracyjny/);
  assert.doesNotMatch(source, /onChange=\{\(event\)\s*=>\s*saveRole/);
});

test("admin note has explicit save, counter and backend-aligned limit", async () => {
  const source = await readFile(pagePath, "utf8");

  assert.match(source, /maxLength=\{2000\}/);
  assert.match(source, /\.length\} \/ 2000/);
  assert.match(source, /Zapisz notatkę/);
  assert.match(source, /admin_set_user_note_v1/);
  assert.doesNotMatch(source, /onChange=\{[^}]*saveAdminNote/);
});

test("loading, empty, malformed and controlled error states are explicit", async () => {
  const source = await readFile(pagePath, "utf8");

  assert.match(source, /aria-busy=\{loading\}/);
  assert.match(source, /Wczytywanie użytkowników/);
  assert.match(source, /Brak użytkowników spełniających wybrane kryteria\./);
  assert.match(source, /Admin users RPC returned malformed data/);
  assert.match(source, /Nie udało się poprawnie odczytać listy użytkowników\./);
  assert.match(source, /role=\{feedback\.tone === "error" \? "alert" : "status"\}/);
});

test("admin users route remains admin-only in middleware", async () => {
  assert.deepEqual(ADMIN_ROUTE_PERMISSIONS["/admin/users"], ["admin"]);
});
