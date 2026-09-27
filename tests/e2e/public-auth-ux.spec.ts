import { randomUUID } from "node:crypto";
import { execFileSync } from "node:child_process";
import path from "node:path";
import { createClient } from "@supabase/supabase-js";
import { expect, test, type Page } from "@playwright/test";
import { getLocalSupabaseTestEnvironment } from "./local-supabase";

const local = getLocalSupabaseTestEnvironment();
const service = createClient(local.supabaseUrl, local.serviceRoleKey, { auth: { persistSession: false, autoRefreshToken: false } });
const marker = randomUUID();
const email = `public-auth-${marker}@example.invalid`;
const password = `Local-${marker}!Aa1`;
let userId: string;
const shots = path.resolve("test-results/public-auth-review");
function sql(query: string) {
  return execFileSync("docker", ["exec", "supabase_db_csk-booking", "psql", "-X", "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", "postgres", "-At", "-c", query], { encoding: "utf8" });
}
async function login(page: Page) {
  await page.getByLabel("E-mail", { exact: true }).fill(email);
  await page.getByLabel("Hasło", { exact: true }).fill(password);
  await page.getByRole("button", { name: "Zaloguj się", exact: true }).click();
}
test.beforeAll(async () => {
  const { data, error } = await service.auth.admin.createUser({ email, password, email_confirm: true, user_metadata: { first_name: "Michał", last_name: "Testowy" } });
  if (error || !data.user) throw new Error("Local user fixture failed");
  userId = data.user.id;
});
test.afterAll(async () => {
  if (userId) {
    const { error } = await service.auth.admin.deleteUser(userId);
    if (error) throw error;
    expect((await service.auth.admin.getUserById(userId)).data.user).toBeNull();
  }
});

for (const entry of ["direct", "/", "/csk-krutla", "/t/csk/booking", "/t/csk/events"]) {
  test(`safe login returns to ${entry}`, async ({ page }) => {
    if (entry === "/t/csk/events") {
      await page.route("**/rest/v1/rpc/get_public_event_list_v3", route => route.fulfill({ json: {
        ok: true, code: "ok", contract_version: 2, pagination: { page: 1, page_size: 20, total: 1 },
        items: [{ event_id: "10000000-0000-4000-8000-000000000002", title: "Szkolenie testowe", description: "Opis", event_date: "2099-10-15", start_time: "10:00", end_time: "11:00", location: "Oś testowa", price: 100, max_participants: 10, registered_count: 0, reserve_count: 0, available_spots: 10, sold_out: false }],
      } }));
    }
    if (entry === "/t/csk/booking") {
      // Public configuration only: local baseline has no operational lanes.
      await page.route("**/rest/v1/rpc/get_public_booking_configuration_v2", route => route.fulfill({ json: [{
        lane_id: "10000000-0000-4000-8000-000000000001", parent_lane_id: null,
        resource_kind: "lane", name: "Oś testowa", display_name: "Oś testowa", display_order: 10,
        effective_online_bookable: true, whole_lane_bookable: true, positions_bookable: false,
        max_people_online: 6, booking_step_minutes: 60, currency_code: "PLN", durations_minutes: [60],
        pricing: ["mon_thu", "fri_sun"].map(day_group => ({ day_group, min_shooters: 1, max_shooters: 6, hourly_price: 100, label: "Taryfa testowa" })),
      }] }));
    }
    if (entry === "direct") await page.goto("/login");
    else {
      await page.goto(entry);
      if (entry === "/t/csk/events") await page.getByRole("button", { name: /Szkolenie testowe/ }).click();
      await page.getByRole("link", { name: /Zaloguj się/i }).first().click();
      await expect(page).toHaveURL(/\/login\?redirectTo=/);
    }
    await login(page);
    await expect(page).toHaveURL(`http://127.0.0.1:3100${entry === "direct" ? "/" : entry}`);
  });
}
test("public auth controls share one session, preserve layout, and sign out locally", async ({ page, context }) => {
  await page.setViewportSize({ width: 1440, height: 1000 });
  for (const [route, name] of [["/", "homepage"], ["/csk-krutla", "csk"]]) {
    await page.goto(route);
    await expect(page.getByRole("link", { name: "Zaloguj się", exact: true }).first()).toBeVisible();
    await expect(page.getByRole("link", { name: "Moje konto", exact: true })).toHaveCount(0);
    await page.screenshot({ path: path.join(shots, `${name}-anonymous-1440.png`), fullPage: true });
  }
  await page.goto("/login"); await login(page); await expect(page).toHaveURL("http://127.0.0.1:3100/");
  for (const width of [1440, 375]) {
    await page.setViewportSize({ width, height: 1000 });
    for (const [route, name, variant] of [["/", "homepage", "platform"], ["/csk-krutla", "csk", "tenant"]]) {
      await page.goto(route);
      const controls = page.getByTestId(`public-auth-${variant}`);
      await expect(controls.getByText("Witaj, Michał", { exact: true })).toBeVisible();
      await expect(controls.getByRole("link", { name: "Moje konto" })).toHaveAttribute("href", "/account");
      await expect(controls.getByRole("button", { name: "Wyloguj" })).toBeVisible();
      await expect(page.getByRole("link", { name: /Zaloguj się|Załóż konto|Rejestracja/ })).toHaveCount(0);
      expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
      if (name === "csk" && width === 1440) {
        expect((await page.getByTestId("tenant-landing-panel").boundingBox())!.width).toBe(880);
        expect((await page.getByTestId("tenant-logo").boundingBox())!.width).toBe(360);
        for (const row of await page.getByTestId("information-row").all()) expect((await row.boundingBox())!.height).toBe(72);
      }
      await page.screenshot({ path: path.join(shots, `${name}-authenticated-${width}.png`), fullPage: true });
    }
  }
  const other = await context.newPage(); await other.goto("/");
  await expect(other.getByTestId("public-auth-platform").getByText("Witaj, Michał")).toBeVisible();
  // Observe the canonical destination without navigating to production in a local test.
  await page.route("https://strzelajtu.pl/", route => route.fulfill({ body: "Canonical logout destination", contentType: "text/html" }));
  const logout = page.waitForResponse(response => response.url().includes("/auth/v1/logout"));
  await page.getByRole("button", { name: "Wyloguj", exact: true }).click();
  expect((await logout).ok()).toBe(true);
  await expect(page).toHaveURL("https://strzelajtu.pl/");
  await expect(other.getByTestId("public-auth-platform").getByRole("link", { name: "Zaloguj się" })).toBeVisible();
  for (const route of ["/", "/csk-krutla"]) {
    await page.goto(route); await expect(page.getByRole("link", { name: "Zaloguj się", exact: true }).first()).toBeVisible();
  }
  await page.goto("/account"); await expect(page.getByText("Logowanie wymagane", { exact: true })).toBeVisible();
});
test("external return destination fails closed", async ({ page }) => {
  await page.goto("/login?redirectTo=https%3A%2F%2Fevil.example"); await login(page);
  await expect(page).toHaveURL("http://127.0.0.1:3100/");
});
test("synthetic Tenant B uses global identity without membership or CSK fallback", async ({ page }) => {
  const id = randomUUID(); const slug = `auth-b-${id.slice(0, 8)}`;
  try {
    sql(`BEGIN; insert into public.tenants(id,name,slug,status) values('${id}','Synthetic Range B','tech-${slug}','active');
      insert into public.tenant_public_profiles(tenant_id,display_name,city,is_public,public_slug) values('${id}','Synthetic Range B','Miasto B',true,'${slug}'); COMMIT;`);
    await page.goto(`/${slug}`);
    await page.getByRole("link", { name: "Zaloguj się", exact: true }).click();
    await login(page); await expect(page).toHaveURL(`http://127.0.0.1:3100/${slug}`);
    await expect(page.getByTestId("public-auth-tenant").getByText("Witaj, Michał")).toBeVisible();
    expect(await page.locator("main").innerText()).not.toMatch(/CSK|Krutla/);
    expect(sql(`select count(*) from public.tenant_memberships where tenant_id='${id}' and user_id='${userId}'`).trim()).toBe("0");
  } finally {
    sql(`BEGIN; delete from public.audit_logs where tenant_id='${id}'; delete from public.tenant_public_profiles where tenant_id='${id}'; delete from public.tenants where id='${id}'; COMMIT;`);
    expect(sql(`select count(*) from public.tenants where id='${id}'`).trim()).toBe("0");
  }
});
test("missing first name uses safe greeting fallback", async ({ page }) => {
  await page.route("**/rest/v1/profiles?*", route => route.fulfill({ json: { first_name: null } }));
  await page.goto("/login"); await login(page);
  await expect(page.getByTestId("public-auth-platform").getByText("Witaj", { exact: true })).toBeVisible();
});
