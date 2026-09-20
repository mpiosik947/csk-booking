import { randomUUID } from "node:crypto";
import { createClient } from "@supabase/supabase-js";
import { expect, test } from "@playwright/test";
import { getLocalSupabaseTestEnvironment } from "./local-supabase";

const environment = getLocalSupabaseTestEnvironment();
const service = createClient(environment.supabaseUrl, environment.serviceRoleKey, {
  auth: { autoRefreshToken: false, persistSession: false },
});

test("active CSK slug renders only the PII-free venue shell", async ({ page }) => {
  await page.goto("/t/csk");
  await expect(page.getByRole("heading", { name: "CSK" })).toBeVisible();
  await expect(page.getByText(/nie są jeszcze dostępne pod nowym adresem/)).toBeVisible();
  await expect(page.getByRole("link", { name: /Rezerwacje CSK/ })).toHaveAttribute("href", "/booking");
});

test("invalid and inactive slugs fail closed without CSK fallback", async ({ page }) => {
  for (const slug of ["UNKNOWN", "tenant-b", "csk%2Fother"]) {
    await page.goto(`/t/${slug}`);
    await expect(page.getByText("404")).toBeVisible();
    await expect(page.getByRole("link", { name: /Rezerwacje CSK/ })).toHaveCount(0);
  }
});

test("Phase 1 booking uses the tenant route without widening staff authority", async ({ page }) => {
  await page.goto("/t/csk/booking");
  await expect(page.getByRole("heading", { name: "Zarezerwuj oś" })).toBeVisible();
  await expect(page.getByText(/nie został jeszcze przełączony na tenantowy kontrakt/)).toHaveCount(0);

  await page.goto("/t/csk/events");
  await expect(page.getByRole("heading", { name: "Eventy i szkolenia" })).toBeVisible();

  await page.goto("/t/csk/my-reservations");
  await expect(page).toHaveURL(/\/login\?redirectTo=%2Ft%2Fcsk%2Fmy-reservations$/);
  await page.goto("/t/csk/my-events");
  await expect(page).toHaveURL(/\/login\?redirectTo=%2Ft%2Fcsk%2Fmy-events$/);

  await page.goto("/t/csk/admin/users");
  await expect(page).toHaveURL(/\/login\?redirectTo=%2Ft%2Fcsk%2Fadmin%2Fusers$/);
  await page.goto("/booking");
  await expect(page).not.toHaveURL(/\/t\//);
});

test("authenticated tenant owner routes use scoped readers while global account/dashboard avoid tenant verification", async ({ page }) => {
  const marker = randomUUID();
  const email = `phase1-routing-${marker}@example.invalid`;
  const password = `Local-Phase1-${marker}!Aa1`;
  const { data, error } = await service.auth.admin.createUser({
    email, password, email_confirm: true,
    user_metadata: { test_marker: "[TEST][SAAS-9E-C-PHASE1]" },
  });
  if (error || !data.user) throw new Error(`Cannot create local Phase 1 user: ${error?.message}`);

  try {
    await page.goto("/login");
    await page.getByLabel("E-mail").fill(email);
    await page.getByLabel("Hasło").fill(password);
    await page.getByRole("button", { name: "Zaloguj się" }).click();
    await expect(page).toHaveURL(/\/dashboard$/);

    const tenantCalls: { name: string; tenantId: string | null }[] = [];
    const legacyCalls: string[] = [];
    page.on("request", (request) => {
      const match = new URL(request.url()).pathname.match(/\/rest\/v1\/rpc\/(get_my_reservations_v[23]|get_my_event_registrations_v[12]|get_my_tenant_verification_v2|get_my_active_tenant_verification_v1)$/);
      if (!match) return;
      const body = request.postDataJSON() as { p_tenant_id?: string } | null;
      if (match[1].endsWith("v3") || match[1] === "get_my_event_registrations_v2" || match[1] === "get_my_tenant_verification_v2") {
        tenantCalls.push({ name: match[1], tenantId: body?.p_tenant_id ?? null });
      } else {
        legacyCalls.push(match[1]);
      }
    });

    // Local DB has no bookable lanes; supply only the public, PII-free read DTO
    // so BookingForm mounts and its authenticated verification RPC is exercised.
    await page.route("**/rest/v1/rpc/get_public_booking_configuration_v2", async (route) => {
      await route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify([{
        lane_id: "10000000-0000-4000-8000-000000000001", parent_lane_id: null,
        resource_kind: "lane", name: "[TEST] Oś", display_name: "[TEST] Oś",
        display_order: 10, effective_online_bookable: true,
        whole_lane_bookable: true, positions_bookable: false,
        max_people_online: 6, booking_step_minutes: 60, currency_code: "PLN",
        durations_minutes: [60], pricing: [
          { day_group: "mon_thu", min_shooters: 1, max_shooters: 6, hourly_price: 100, label: "Poniedziałek–czwartek" },
          { day_group: "fri_sun", min_shooters: 1, max_shooters: 6, hourly_price: 120, label: "Piątek–niedziela" },
        ],
      }]) });
    });

    await page.goto("/t/csk/booking");
    await expect(page.getByRole("heading", { name: "Zarezerwuj oś" })).toBeVisible();
    await expect(page.getByRole("region", { name: "Formularz rezerwacji" })).toBeVisible();
    await expect.poll(() => tenantCalls.some((call) => call.name === "get_my_tenant_verification_v2")).toBe(true);
    await page.unroute("**/rest/v1/rpc/get_public_booking_configuration_v2");

    await page.goto("/t/csk/my-reservations");
    await expect(page.getByRole("heading", { name: "Moje rezerwacje" })).toBeVisible();
    await expect.poll(() => tenantCalls.some((call) => call.name === "get_my_reservations_v3")).toBe(true);

    await page.goto("/t/csk/my-events");
    await expect(page.getByRole("heading", { name: "Moje szkolenia" })).toBeVisible();
    await expect.poll(() => tenantCalls.some((call) => call.name === "get_my_event_registrations_v2")).toBe(true);
    expect(tenantCalls.every((call) => !!call.tenantId && call.tenantId === tenantCalls[0].tenantId)).toBe(true);
    expect(legacyCalls).toEqual([]);

    await page.goto("/account");
    await expect(page).toHaveURL(/\/account$/);
    await expect(page.getByRole("heading", { name: /Moje konto|Konto/ })).toBeVisible();
    await page.goto("/dashboard");
    await expect(page).toHaveURL(/\/dashboard$/);
    expect(legacyCalls).toEqual([]);
  } finally {
    const { error: cleanupError } = await service.auth.admin.deleteUser(data.user.id);
    if (cleanupError) throw new Error(`Cannot clean local Phase 1 user: ${cleanupError.message}`);
  }
});
