import { randomUUID } from "node:crypto";
import { execFileSync } from "node:child_process";
import { createClient } from "@supabase/supabase-js";
import { expect, test } from "@playwright/test";
import { getLocalSupabaseTestEnvironment } from "./local-supabase";

const env = getLocalSupabaseTestEnvironment();
const service = createClient(env.supabaseUrl, env.serviceRoleKey, {
  auth: { autoRefreshToken: false, persistSession: false },
});
const CSK_ID = "c5c00000-0000-4000-8000-000000000001";

test("tenant admin modules use scoped contracts and legacy URLs hand off to CSK", async ({ page }) => {
  const marker = randomUUID();
  const email = `c2a-${marker}@example.invalid`;
  const password = `Local-C2A-${marker}!Aa1`;
  const { data, error } = await service.auth.admin.createUser({
    email, password, email_confirm: true,
    user_metadata: { test_marker: "[TEST][SAAS-9E-C2-A]" },
  });
  if (error || !data.user) throw new Error(`Local fixture creation failed: ${error?.code}`);

  try {
    // service_role deliberately has no direct profile/membership DML. This is
    // a local fixture-only postgres operation; local-supabase.ts rejects remote hosts.
    const updateResult = execFileSync("docker", ["exec", "supabase_db_csk-booking", "psql", "-X", "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", "postgres", "-c",
      `insert into public.profiles(id,user_id,email,role,verification_status) select id,id,email,'user','verified' from auth.users u where u.id='${data.user.id}' and not exists(select 1 from public.profiles p where p.user_id=u.id); update public.profiles set role='admin' where user_id='${data.user.id}'; update public.tenant_memberships set role='admin', status='active' where tenant_id='${CSK_ID}' and user_id='${data.user.id}'`], { encoding: "utf8" });
    if (!/UPDATE 1\b/.test(updateResult)) throw new Error("Local C2-A membership fixture not created");

    await page.goto("/login");
    await page.getByLabel("E-mail").fill(email);
    await page.getByLabel("Hasło").fill(password);
    await page.getByRole("button", { name: "Zaloguj się" }).click();
    await expect(page).toHaveURL(/\/dashboard$/);

    const observed: { rpc: string; tenantId: string | null }[] = [];
    page.on("request", (request) => {
      const rpc = new URL(request.url()).pathname.match(/\/rest\/v1\/rpc\/([^/]+)$/)?.[1];
      if (!rpc) return;
      const body: unknown = request.postDataJSON();
      const tenantId = body && typeof body === "object" && "p_tenant_id" in body && typeof body.p_tenant_id === "string"
        ? body.p_tenant_id : null;
      observed.push({ rpc, tenantId });
    });

    await page.goto("/t/csk/admin/events?scope=all");
    await expect(page.getByText(/nie został jeszcze przełączony na tenantowy kontrakt/)).toHaveCount(0);
    await expect.poll(() => observed.some((call) => call.rpc === "admin_list_events_v2" && call.tenantId === CSK_ID)).toBe(true);
    expect(observed.filter((call) => ["get_my_role", "admin_list_events_v1", "admin_list_event_registrations_v1"].includes(call.rpc))).toHaveLength(0);

    observed.length = 0;
    await page.goto("/t/csk/admin/lane-configuration");
    await expect(page.getByText(/nie został jeszcze przełączony na tenantowy kontrakt/)).toHaveCount(0);
    await expect.poll(() => observed.some((call) => call.rpc === "admin_get_lane_booking_configuration_v3" && call.tenantId === CSK_ID)).toBe(true);
    expect(observed.filter((call) => ["get_my_role", "admin_get_lane_booking_configuration_v2"].includes(call.rpc))).toHaveLength(0);

    observed.length = 0;
    await page.goto("/t/csk/admin/reports");
    await expect(page.getByText(/nie został jeszcze przełączony na tenantowy kontrakt/)).toHaveCount(0);
    await expect.poll(() => observed.some((call) => call.rpc === "admin_get_reservation_report_v3" && call.tenantId === CSK_ID)).toBe(true);
    expect(observed.filter((call) => ["get_my_role", "admin_get_reservation_report_v2"].includes(call.rpc))).toHaveLength(0);

    observed.length = 0;
    await page.goto("/t/csk/admin/users");
    await expect(page.getByText(/nie został jeszcze przełączony na tenantowy kontrakt/)).toHaveCount(0);
    await expect.poll(() => observed.some((call) => call.rpc === "admin_list_users_v2" && call.tenantId === CSK_ID)).toBe(true);
    expect(observed.filter((call) => ["get_my_role", "admin_list_users_v1"].includes(call.rpc))).toHaveLength(0);

    observed.length = 0;
    await page.goto("/account");
    await expect(page.getByText("Weryfikacja w lokalizacji")).toBeVisible();
    expect(observed.some((call) => call.rpc === "get_my_active_tenant_verification_v1")).toBe(false);
    observed.length = 0;
    await page.goto("/dashboard");
    await expect(page.getByRole("heading", { name: "Wybierz lokalizację" })).toBeVisible();
    expect(observed.some((call) => call.rpc === "get_my_active_tenant_verification_v1")).toBe(false);

    for (const [route, heading] of [
      ["admin", "Dashboard operacyjny"],
      ["admin/reservations", "Rezerwacje"],
      ["admin/calendar", "Kalendarz obłożenia"],
      ["admin/check-in", "Check-in i obsługa wizyt"],
      ["admin/lane-blocks", "Blokady osi"],
    ]) {
      observed.length = 0;
      await page.goto(`/t/csk/${route}`);
      await expect(page.getByRole("heading", { name: heading, exact: true })).toBeVisible();
      expect(observed.some((call) => call.rpc === "get_my_role")).toBe(false);
    }

    observed.length = 0;
    await page.goto("/admin/events?scope=all");
    await expect(page).toHaveURL(/\/t\/csk\/admin\/events\?scope=all$/);
    await expect.poll(() => observed.some((call) => call.rpc === "admin_list_events_v2" && call.tenantId === CSK_ID)).toBe(true);
    expect(observed.some((call) => call.rpc === "admin_list_events_v1")).toBe(false);
  } finally {
    const { error: cleanupError } = await service.auth.admin.deleteUser(data.user.id);
    if (cleanupError) throw new Error(`Local C2-A cleanup failed: ${cleanupError.code}`);
  }
});
