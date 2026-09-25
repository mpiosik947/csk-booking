import { randomUUID } from "node:crypto";
import { execFileSync } from "node:child_process";
import { createClient } from "@supabase/supabase-js";
import { expect, test } from "@playwright/test";
import { getLocalSupabaseTestEnvironment } from "./local-supabase";

const env = getLocalSupabaseTestEnvironment();
const service = createClient(env.supabaseUrl, env.serviceRoleKey, { auth: { autoRefreshToken: false, persistSession: false } });
const database = process.env.PRODUCT10E_ISOLATED_DATABASE || "postgres";
if (database !== "postgres" && !/^p10e_isolated_[0-9a-f]{16}$/.test(database)) {
  throw new Error("Invalid isolated local database name");
}
function sql(statement: string) {
  return execFileSync("docker", ["exec", "supabase_db_csk-booking", "psql", "-X", "-At", "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", database, "-c", statement], { encoding: "utf8" });
}

test.beforeAll(() => {
  if (database === "postgres") return;
  expect(sql("select max(version) from supabase_migrations.schema_migrations").trim()).toBe("20261009140000");
  expect(sql("select count(*) from pg_proc where pronamespace='public'::regnamespace and prosecdef").trim()).toBe("97");
  expect(sql("select count(*) from pg_proc where pronamespace='public'::regnamespace and proname in('admin_get_tenant_content_v1','admin_update_tenant_content_v1','get_public_tenant_content_v1')").trim()).toBe("0");
});

test("platform onboarding is private, explicit, responsive and separate from tenant authority", async ({ page, browser, baseURL }) => {
  const run = randomUUID(); const slug = `p10e-${run}`; const publicSlug = `pub-${run}`;
  const password = `Local-${run}!Aa9`;
  const platformEmail = `platform-${run}@example.invalid`; const tenantEmail = `tenant-${run}@example.invalid`;
  const users: string[] = [];
  try {
    for (const email of [platformEmail, tenantEmail]) {
      const created = await service.auth.admin.createUser({ email, password, email_confirm: true });
      if (created.error || !created.data.user) throw new Error("Cannot create local synthetic account");
      users.push(created.data.user.id);
    }
    sql(`insert into public.platform_admins(user_id,status) values('${users[0]}','active');`);
    await page.goto("/login"); await page.getByLabel("E-mail").fill(platformEmail); await page.getByLabel("Hasło").fill(password);
    await page.getByRole("button", { name: "Zaloguj się" }).click(); await expect(page).toHaveURL(/\/dashboard$/);
    await page.goto("/platform-admin"); await expect(page.getByRole("heading", { name: "Obiekty i onboarding" })).toBeVisible();
    await page.getByLabel("Nazwa", { exact: true }).fill(`Synthetic ${run}`);
    await page.getByLabel("Miejscowość", { exact: true }).fill("Testowo");
    await page.getByLabel("Stały identyfikator techniczny").fill(slug);
    await page.getByLabel("Publiczny identyfikator URL").fill(publicSlug);
    await page.getByRole("button", { name: "Utwórz draft", exact: true }).click();
    const card = page.locator("section").filter({ has: page.getByRole("heading", { name: `Synthetic ${run}`, exact: true }) }).last();
    await expect(card.getByText("Plan: Nieprzypisany", { exact: false })).toBeVisible();
    await card.getByRole("button", { name: "Konfiguruj" }).click();
    await card.getByLabel("Jawny wybór planu").selectOption("booking_only_v1");
    await card.getByRole("button", { name: "Przypisz / zmień plan" }).click();
    await expect(card.getByText("Plan: booking_only_v1", { exact: false })).toBeVisible();
    await card.getByLabel("Dokładny e-mail istniejącego pierwszego admina").fill(tenantEmail);
    await card.getByRole("button", { name: "Znajdź konto" }).click();
    await card.getByRole("button", { name: "Przypisz pierwszego admina" }).click();
    await expect(card.getByText("Gotowość: Kompletna")).toBeVisible();
    const tenantContext = await browser.newContext({ baseURL });
    try {
      const tenantPage = await tenantContext.newPage();
      await tenantPage.goto("/login"); await tenantPage.getByLabel("E-mail").fill(tenantEmail); await tenantPage.getByLabel("Hasło").fill(password);
      await tenantPage.getByRole("button", { name: "Zaloguj się" }).click(); await expect(tenantPage).toHaveURL(/\/dashboard$/);
      await tenantPage.goto(`/tenant-setup/${slug}`);
      await expect(tenantPage.getByRole("heading", { name: "Ustawienia publiczne" })).toBeVisible();
      await tenantPage.getByLabel("Rezerwacja", { exact: true }).check();
      await tenantPage.getByRole("button", { name: "Zapisz ustawienia" }).click();
      await expect(tenantPage.getByText("Ustawienia publiczne zostały zapisane.")).toBeVisible();
      const denied = await tenantPage.goto("/platform-admin"); expect(denied?.status()).toBe(404);
      await tenantPage.goto("/continuity"); await expect(tenantPage.getByRole("heading", { name: "Historia i rozliczenia" })).toBeVisible();
    } finally { await tenantContext.close(); }
    for (const width of [320, 375, 430, 768, 1440]) {
      await page.setViewportSize({ width, height: 900 });
      expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
    }
    await card.getByRole("link", { name: "Prywatny podgląd" }).click();
    await expect(page.getByText("Prywatny podgląd. Nie publikuje obiektu", { exact: false })).toBeVisible();
    const response = await page.request.get(`/${publicSlug}`); expect(response.status()).toBe(404);
    await page.goto("/platform-admin");
    await card.getByRole("button", { name: "Konfiguruj" }).click();
    await card.getByRole("button", { name: "Aktywuj po sprawdzeniu gotowości" }).click();
    await expect(card.getByText("Testowo · active · Niepubliczny")).toBeVisible();
    const settingsContext = await browser.newContext({ baseURL });
    try {
      const settingsPage = await settingsContext.newPage();
      await settingsPage.goto("/login");
      await settingsPage.getByLabel("E-mail").fill(tenantEmail);
      await settingsPage.getByLabel("Hasło").fill(password);
      await settingsPage.getByRole("button", { name: "Zaloguj się" }).click();
      await expect(settingsPage).toHaveURL(/\/dashboard$/);
      const settingsResponse = await settingsPage.goto(`/t/${slug}/admin/settings`);
      expect(settingsResponse?.status()).toBe(200);
      await expect(settingsPage.getByRole("heading", { name: "Ustawienia publiczne" })).toBeVisible();
      await expect(settingsPage.getByLabel("Miejscowość", { exact: true })).toHaveValue("Testowo");
    } finally { await settingsContext.close(); }
    await card.getByRole("button", { name: "Opublikuj", exact: true }).click();
    await expect(card.getByText("Testowo · active · Opublikowany")).toBeVisible();
    expect((await page.request.get(`/${publicSlug}`)).status()).toBe(200);
    page.once("dialog", dialog => dialog.accept());
    await card.getByRole("button", { name: "Zawieś", exact: true }).click();
    await expect(card.getByText("Testowo · suspended · Niepubliczny")).toBeVisible();
    expect((await page.request.get(`/${publicSlug}`)).status()).toBe(404);
    expect(sql(`select count(*) from public.tenant_memberships where tenant_id=(select id from public.tenants where slug='${slug}') and user_id='${users[0]}';`).trim()).toBe("0");
  } finally {
    sql(`delete from public.platform_audit_logs where tenant_id in(select id from public.tenants where slug='${slug}');
      delete from public.audit_logs where tenant_id in(select id from public.tenants where slug='${slug}');
      delete from public.tenant_memberships where tenant_id in(select id from public.tenants where slug='${slug}');
      delete from public.tenant_public_profiles where tenant_id in(select id from public.tenants where slug='${slug}');
      delete from public.tenant_plan_assignments where tenant_id in(select id from public.tenants where slug='${slug}');
      delete from public.tenants where slug='${slug}';`);
    for (const id of users) {
      sql(`delete from public.platform_admins where user_id='${id}';`);
      const removed = await service.auth.admin.deleteUser(id);
      if (removed.error) throw new Error("Local fixture cleanup failed");
    }
    expect(sql(`select count(*) from public.tenants where slug='${slug}';`).trim()).toBe("0");
  }
});

test("anonymous platform routes never expose management metadata", async ({ page }) => {
  await page.goto("/platform-admin"); await expect(page).toHaveURL(/\/login/);
  await page.goto("/continuity"); await expect(page).toHaveURL(/\/login/);
  await page.goto("/tenant-setup/unknown"); await expect(page).toHaveURL(/\/login/);
});
