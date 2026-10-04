import { randomUUID } from "node:crypto";
import { execFileSync } from "node:child_process";
import { createClient } from "@supabase/supabase-js";
import { test, expect } from "@playwright/test";
import { getLocalSupabaseTestEnvironment } from "./local-supabase";
const env = getLocalSupabaseTestEnvironment(), db = process.env.ONBOARD_1C_DATABASE;
if (!/^onboard_1c_[0-9a-f]{16}$/.test(db ?? "")) throw Error("ISOLATED_DATABASE_REQUIRED");
const sql = (s: string) => execFileSync("docker", ["exec", "supabase_db_csk-booking", "psql", "-X", "-At", "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", db!, "-c", s], { encoding: "utf8" }).trim();
const service = createClient(env.supabaseUrl, env.serviceRoleKey, { auth: { persistSession: false } });

test("dormant discovery, canonical PA roles, checklist refresh and safe setup routes", async ({ browser }) => {
  const run = randomUUID(), a = randomUUID(), b = randomUUID(), slug = `setup-${run}`, password = `Local-${run}!Aa9`;
  const actors: Record<string, { id: string; email: string }> = {};
  const roles = ["admin", "other", "user", "employee", "instructor", "pa", "suspended", "removed", "combined"];
  const anonymous = await browser.newContext(); const anonymousPage = await anonymous.newPage(); await anonymousPage.goto("/dashboard"); await expect(anonymousPage.getByRole("link", { name: "Zaloguj się", exact: true })).toBeVisible(); await expect(anonymousPage.getByRole("heading", { name: "Panel głównego administratora", exact: true })).toHaveCount(0); await anonymous.close();
  try {
    for (const role of roles) {
      const email = `${role}-${run}@example.invalid`;
      const created = await service.auth.admin.createUser({ email, password, email_confirm: true });
      expect(created.error).toBeNull(); actors[role] = { id: created.data.user!.id, email };
    }
    sql(`insert into public.tenants(id,name,slug,status)values('${a}','Synthetic Active','active-${run}','active'),('${b}','Synthetic Dormant','${slug}','dormant');
      insert into public.tenant_public_profiles(tenant_id,display_name,city,public_slug)values('${a}','Synthetic Active','City','pub-active-${run}'),('${b}','Synthetic Dormant','City','pub-${slug}');
      insert into public.tenant_plan_assignments(tenant_id,plan_id,status)select '${b}',id,'active'from public.saas_plans where plan_key='booking_only_v1';
      insert into public.tenant_memberships(tenant_id,user_id,role,status)values
      ('${b}','${actors.admin.id}','admin','active'),('${a}','${actors.admin.id}','user','active'),('${a}','${actors.other.id}','admin','active'),
      ('${b}','${actors.user.id}','user','active'),('${b}','${actors.employee.id}','employee','active'),('${b}','${actors.instructor.id}','instructor','active'),('${b}','${actors.combined.id}','admin','active');
      insert into public.platform_admins(user_id,status)values('${actors.pa.id}','active'),('${actors.combined.id}','active'),('${actors.suspended.id}','suspended');`);
    for (const role of roles) {
      const context = await browser.newContext(); const page = await context.newPage();
      try {
        await page.goto("/login?redirectTo=/dashboard"); await page.getByLabel("E-mail").fill(actors[role].email); await page.getByLabel("Hasło").fill(password);
        await page.getByRole("button", { name: "Zaloguj się", exact: true }).click(); await expect(page).toHaveURL(/\/dashboard$/);
        await expect(page.getByRole("heading", { name: "Panel klienta", exact: true })).toBeVisible();
        const owns = ["admin", "combined"].includes(role), isPA = ["pa", "combined"].includes(role);
        await expect(page.getByRole("heading", { name: "Obiekty w przygotowaniu", exact: true })).toHaveCount(owns ? 1 : 0);
        await expect(page.getByRole("heading", { name: "Panel głównego administratora", exact: true })).toHaveCount(isPA ? 1 : 0);
        if (role === "admin") {
          await expect(page.getByRole("heading", { name: "Synthetic Active", exact: true })).toBeVisible();
          for (const width of [320, 768, 1440]) { await page.setViewportSize({ width, height: 900 }); expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true); }
          await page.getByRole("link", { name: "Dokończ konfigurację", exact: true }).click();
          await expect(page).toHaveURL(new RegExp(`/tenant-setup/${slug}$`));
          await expect(page.getByText("W przygotowaniu", { exact: true })).toBeVisible();
          const list = page.getByRole("region", { name: "Lista konfiguracji" });
          await expect(list.getByText("Osie / stanowiska:", { exact: false })).toContainText("Do konfiguracji");
          await page.getByRole("button", { name: "Zapisz i zostań", exact: true }).click();
          await expect(page.getByRole("status").filter({ hasText: "Ustawienia zapisane." })).toBeVisible();
          await page.getByRole("link", { name: "Przejdź do konfiguracji osi", exact: true }).click();
          await expect(page).toHaveURL(new RegExp(`/tenant-setup/${slug}/lanes$`));
          await expect(page.getByRole("button", { name: "+ Dodaj nową oś", exact: true })).toBeVisible();
          // The real current-user draft RPC configures the disposable fixture, without activation.
          const client = createClient(env.supabaseUrl, env.anonKey, { auth: { persistSession: false } });
          expect((await client.auth.signInWithPassword({ email: actors.admin.email, password })).error).toBeNull();
          const family = { root: { name: "Synthetic setup lane", is_active: true, online_bookable: true, max_shooters: 2, max_people_online: 2, booking_step_minutes: 60, durations_minutes: [60, 120], whole_lane_bookable: true, positions_bookable: false, pricing: [
            { day_group: "mon_thu", min_shooters: 1, max_shooters: 2, label: "Weekday", hourly_price: 100 },
            { day_group: "fri_sun", min_shooters: 1, max_shooters: 2, label: "Weekend", hourly_price: 120 }] }, positions: [] };
          const created = await client.rpc("tenant_setup_create_lane_family_v1", { p_tenant_id: b, p_family: family });
          expect(created.error).toBeNull(); expect(created.data.code).toBe("created");
          await page.goto(`/tenant-setup/${slug}`);
          await expect(list.getByText("Osie / stanowiska:", { exact: false })).toContainText("Gotowe");
          await expect(list.getByText("Czasy rezerwacji:", { exact: false })).toContainText("Gotowe");
          await expect(list.getByText("Cennik:", { exact: false })).toContainText("Gotowe");
          for (const width of [320, 768, 1440]) { await page.setViewportSize({ width, height: 900 }); expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true); }
          // A read error must clear confirmed configuration, rather than keep stale readiness.
          await page.route("**/rpc/tenant_setup_get_lane_configuration_v1", route => route.request().method() === "OPTIONS" ? route.continue() : route.fulfill({ status: 500, contentType: "application/json", body: '{"code":"synthetic_failure"}' }));
          await page.getByRole("button", { name: "Odśwież konfigurację", exact: true }).click();
          await expect(list.getByRole("alert")).toContainText("Stan tych sekcji nie został potwierdzony");
          await expect(list.getByText("Cennik:", { exact: false })).toContainText("Do konfiguracji");
          await page.unroute("**/rpc/tenant_setup_get_lane_configuration_v1");
          // Presentation-only response fixture validates the existing no-booking contract.
          await page.route("**/rpc/admin_get_tenant_public_settings_v1", async route => {
            if (route.request().method() === "OPTIONS") return route.continue();
            const response = await route.fetch(); const data = await response.json();
            data.feature_access.booking = false;
            await route.fulfill({ response, json: data });
          });
          await page.goto(`/tenant-setup/${slug}`);
          await expect(list.getByText("Niedostępne w planie", { exact: true })).toHaveCount(3);
          await expect(page.getByRole("link", { name: "Przejdź do konfiguracji osi", exact: true })).toHaveCount(0);
          await page.unroute("**/rpc/admin_get_tenant_public_settings_v1");
          // Dormant read failure does not remove active tenant presentation.
          await page.route("**/rpc/get_my_dormant_admin_tenants_v1", route => route.request().method() === "OPTIONS" ? route.continue() : route.fulfill({ status: 500, contentType: "application/json", body: '{"code":"synthetic_failure"}' }));
          await page.goto("/dashboard"); await expect(page.getByText("Nie udało się pobrać obiektów w przygotowaniu.", { exact: false })).toBeVisible();
          await expect(page.getByRole("heading", { name: "Synthetic Active", exact: true })).toBeVisible();
        } else if (!owns) {
          await page.goto(`/tenant-setup/${slug}`); await expect(page.locator("[data-field=display_name]")).toHaveCount(0);
          await page.goto(`/tenant-setup/${slug}/lanes`); await expect(page.getByRole("button", { name: "+ Dodaj nową oś" })).toHaveCount(0);
        }
        if (isPA) {
          await page.goto("/dashboard"); await page.getByRole("link", { name: /Przejdź do Platform Admin/ }).click();
          await expect(page).toHaveURL(/\/platform-admin$/);
        }
      } finally { await context.close(); }
    }
    expect(sql(`select status||':'||is_public from public.tenants t join public.tenant_public_profiles p on p.tenant_id=t.id where t.id='${b}'`)).toBe("dormant:false");
  } finally {
    for (const id of [a, b]) sql(`delete from public.audit_logs where tenant_id='${id}';delete from public.lane_booking_durations where lane_id in(select id from public.shooting_lanes where tenant_id='${id}');delete from public.lane_pricing_rules where lane_id in(select id from public.shooting_lanes where tenant_id='${id}');delete from public.lane_booking_rules where lane_id in(select id from public.shooting_lanes where tenant_id='${id}');delete from public.lane_booking_family_configuration_versions where root_lane_id in(select id from public.shooting_lanes where tenant_id='${id}');delete from public.shooting_lanes where tenant_id='${id}';delete from public.tenant_memberships where tenant_id='${id}';delete from public.tenant_public_profiles where tenant_id='${id}';delete from public.tenant_plan_assignments where tenant_id='${id}';delete from public.tenants where id='${id}';`);
    for (const actor of Object.values(actors)) { sql(`delete from public.platform_admins where user_id='${actor.id}';`); expect((await service.auth.admin.deleteUser(actor.id)).error).toBeNull(); }
    expect(sql("select count(*)from auth.users")).toBe("0");
  }
});
