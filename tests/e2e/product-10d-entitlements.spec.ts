import { randomUUID } from "node:crypto";
import { execFileSync } from "node:child_process";
import { createClient } from "@supabase/supabase-js";
import { expect, test } from "@playwright/test";
import { getLocalSupabaseTestEnvironment } from "./local-supabase";

const env = getLocalSupabaseTestEnvironment();
const service = createClient(env.supabaseUrl, env.serviceRoleKey, {
  auth: { autoRefreshToken: false, persistSession: false },
});

function localSql(sql: string) {
  return execFileSync("docker", ["exec", "supabase_db_csk-booking", "psql", "-X", "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", "postgres", "-c", sql], { encoding: "utf8" });
}

test("booking-only tenant exposes booking and denies every unavailable direct module route", async ({ page }) => {
  const run = randomUUID();
  const tenant = randomUUID();
  const slug = `p10d-${run}`;
  const publicSlug = `range-${run}`;
  const email = `p10d-${run}@example.invalid`;
  const password = `Local-P10D-${run}!Aa1`;
  const created = await service.auth.admin.createUser({ email, password, email_confirm: true, user_metadata: { test_marker: "[TEST][PRODUCT-10D]" } });
  if (created.error || !created.data.user) throw new Error(`Cannot create PRODUCT-10D admin: ${created.error?.code}`);
  const user = created.data.user;
  try {
    localSql(`
      insert into public.tenants(id,name,slug,status) values('${tenant}','[TEST][PRODUCT-10D] Booking only','${slug}','active');
      insert into public.tenant_public_profiles(tenant_id,display_name,city,is_public,public_slug,show_booking,show_events,show_instructor)
        values('${tenant}','Booking Only','Testowo',true,'${publicSlug}',true,true,true);
      insert into public.tenant_plan_assignments(tenant_id,plan_id,status)
        select '${tenant}',id,'active' from public.saas_plans where plan_key='booking_only_v1';
      insert into public.tenant_memberships(tenant_id,user_id,role,status) values('${tenant}','${user.id}','admin','active');
    `);

    await page.goto(`/${publicSlug}`);
    await expect(page.getByRole("link", { name: "Zarezerwuj termin" })).toHaveAttribute("href", `/t/${slug}/booking`);
    await expect(page.getByRole("link", { name: "Szkolenia i eventy" })).toHaveCount(0);
    await expect(page.getByText("Strzelanie z instruktorem")).toHaveCount(0);
    await page.goto(`/t/${slug}/booking`);
    await expect(page.getByRole("heading", { name: "Zarezerwuj oś" })).toBeVisible();
    await page.goto(`/t/${slug}/events`);
    await expect(page.getByText(/Brak dostępu|404/u)).toBeVisible();

    await page.goto("/login");
    await page.getByLabel("E-mail").fill(email);
    await page.getByLabel("Hasło").fill(password);
    await page.getByRole("button", { name: "Zaloguj się" }).click();
    await expect(page).toHaveURL(/\/dashboard$/u);
    await page.goto(`/t/${slug}/admin`);
    await expect(page.getByRole("heading", { name: "Dashboard operacyjny" })).toBeVisible();
    for (const label of ["Eventy", "Użytkownicy", "Check-in", "Raporty", "Blokady osi", "Kalendarz"]) {
      await expect(page.getByRole("link", { name: new RegExp(label, "iu") })).toHaveCount(0);
    }
    for (const path of ["admin/events", "admin/users", "admin/check-in", "admin/reports", "admin/lane-blocks", "admin/calendar"]) {
      await page.goto(`/t/${slug}/${path}`);
      await expect(page.getByText(/Brak dostępu|404/u)).toBeVisible();
    }
  } finally {
    localSql(`delete from public.audit_logs where tenant_id='${tenant}'; delete from public.tenant_memberships where tenant_id='${tenant}'; delete from public.tenant_plan_assignments where tenant_id='${tenant}'; delete from public.tenant_public_profiles where tenant_id='${tenant}'; delete from public.tenants where id='${tenant}';`);
    const removed = await service.auth.admin.deleteUser(user.id);
    if (removed.error) throw new Error(`Cannot clean PRODUCT-10D admin: ${removed.error.code}`);
    const cleanup = localSql(`select (select count(*) from public.tenants where id='${tenant}'),(select count(*) from public.tenant_memberships where tenant_id='${tenant}'),(select count(*) from public.tenant_plan_assignments where tenant_id='${tenant}'),(select count(*) from auth.users where id='${user.id}');`);
    if (!/\b0\s*\|\s*0\s*\|\s*0\s*\|\s*0\b/u.test(cleanup)) throw new Error(`PRODUCT-10D cleanup failed: ${cleanup}`);
  }
});
