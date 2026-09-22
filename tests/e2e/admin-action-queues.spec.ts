import { randomUUID } from "node:crypto";
import { execFileSync } from "node:child_process";
import { createClient } from "@supabase/supabase-js";
import { expect, test, type Page } from "@playwright/test";
import { getWarsawDateISO } from "../../lib/admin/action-queues.js";
import { getLocalSupabaseTestEnvironment } from "./local-supabase";

const environment = getLocalSupabaseTestEnvironment();
const service = createClient(environment.supabaseUrl, environment.serviceRoleKey, {
  auth: { autoRefreshToken: false, persistSession: false },
});
const runId = `${Date.now()}-${randomUUID().slice(0, 8)}`;
const email = `test-admin-queues-${runId}@example.invalid`;
const password = `Local-Queues-${randomUUID()}!Aa1`;
const CSK_ID = "c5c00000-0000-4000-8000-000000000001";
let adminUserId = "";

function assertNoError(error: { message: string } | null, context: string) {
  if (error) throw new Error(`${context}: ${error.message}`);
}

async function login(page: Page) {
  await page.goto("/login");
  await page.getByLabel("E-mail").fill(email);
  await page.getByLabel("Hasło").fill(password);
  await page.getByRole("button", { name: "Zaloguj się" }).click();
  await expect(page).toHaveURL(/\/dashboard$/u);
}

test.describe.serial("V1.1-03 admin action queues", () => {
  test.beforeAll(async () => {
    const { data, error } = await service.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
      user_metadata: { test_marker: `[TEST][V1.1-03][${runId}]` },
    });
    assertNoError(error, "create queue admin");
    if (!data.user) throw new Error("Queue admin was not created.");
    adminUserId = data.user.id;

    execFileSync(
      "docker",
      [
        "exec", "supabase_db_csk-booking", "psql", "-X", "-v", "ON_ERROR_STOP=1",
        "-U", "postgres", "-d", "postgres", "-c",
        `update public.profiles set first_name='[TEST]',last_name='Queues ${runId}',full_name='[TEST] Queues ${runId}',email='${email}',role='admin' where user_id='${adminUserId}'; insert into public.tenant_memberships(tenant_id,user_id,role,status) values ('${CSK_ID}','${adminUserId}','admin','active') on conflict (tenant_id,user_id) do update set role=excluded.role,status=excluded.status`,
      ],
      { encoding: "utf8" },
    );
  });

  test.afterAll(async () => {
    if (!adminUserId) return;
    const { error } = await service.auth.admin.deleteUser(adminUserId);
    assertNoError(error, "delete queue admin");
  });

  for (const width of [320, 375, 430]) {
    test(`dashboard queues have no horizontal overflow at ${width}px`, async ({ page }) => {
      await page.setViewportSize({ width, height: 900 });
      await login(page);
      await page.goto("/admin");
      await expect(page.getByRole("heading", { name: "Wymaga uwagi" })).toBeVisible();
      const overflow = await page.evaluate(
        () => document.documentElement.scrollWidth - document.documentElement.clientWidth
      );
      expect(overflow).toBeLessThanOrEqual(1);
      await expect(page.getByRole("link", { name: /Oczekiwani dzisiaj/u })).toBeVisible();
      await expect(page.getByRole("link", { name: /Dzisiejsze rezerwacje/u })).toBeVisible();
    });
  }

  test("deep links carry safe Warsaw filters and browser history", async ({ page }) => {
    await login(page);
    await page.goto("/admin");
    const today = getWarsawDateISO();

    await expect(page.getByRole("link", { name: /Oczekiwani dzisiaj/u })).toHaveAttribute(
      "href",
      `/t/csk/admin/check-in?date=${today}&attendance=expected&page=1`
    );
    await expect(page.getByRole("link", { name: /^Nieopłacone/u })).toHaveAttribute(
      "href",
      `/t/csk/admin/reservations?date=${today}&status=confirmed&payment=unpaid&page=1`
    );
    await expect(page.getByRole("link", { name: /Lista rezerwowa eventów/u })).toHaveAttribute(
      "href",
      "/t/csk/admin/events?participantStatus=reserve&participantPage=1&page=1"
    );

    await page.getByRole("link", { name: /Oczekiwani dzisiaj/u }).click();
    await expect(page).toHaveURL(new RegExp(`/t/csk/admin/check-in\\?date=${today}&attendance=expected&page=1$`, "u"));
    await page.goBack();
    await expect(page).toHaveURL(/\/t\/csk\/admin$/u);
  });

  test("operational admin split reads and unaffected modules load without server errors", async ({ page }) => {
    const serverErrors: string[] = [];
    page.on("response", (response) => {
      if (response.status() >= 500) {
        serverErrors.push(`${response.status()} ${response.url()}`);
      }
    });

    await login(page);

    for (const [path, heading] of [
      ["/admin", "Dashboard operacyjny"],
      ["/admin/reservations", "Rezerwacje"],
      ["/admin/check-in", "Check-in i obsługa wizyt"],
      ["/admin/calendar", "Kalendarz obłożenia"],
      ["/admin/reports", "Raport"],
      ["/admin/events", "Eventy i szkolenia"],
      ["/admin/lane-configuration", "Konfiguracja osi"],
      ["/booking", "Zarezerwuj oś"],
    ] as const) {
      await page.goto(path);
      await expect(page.getByRole("heading", { name: heading, exact: true })).toBeVisible();
    }

    expect(serverErrors).toEqual([]);
  });
});
