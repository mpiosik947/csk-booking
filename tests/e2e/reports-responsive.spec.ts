import { randomUUID } from "node:crypto";
import { createClient } from "@supabase/supabase-js";
import { expect, test, type Page, type Route } from "@playwright/test";
import { getLocalSupabaseTestEnvironment } from "./local-supabase";

const environment = getLocalSupabaseTestEnvironment();
const service = createClient(environment.supabaseUrl, environment.serviceRoleKey, {
  auth: { autoRefreshToken: false, persistSession: false },
});
const runMarker = `${Date.now()}-${randomUUID().slice(0, 8)}`;
const email = `test-reports-responsive-${runMarker}@example.invalid`;
const password = `Local-Reports-${randomUUID()}!Aa1`;
const resourceId = "00000000-0000-4000-8000-000000000601";
let adminUserId = "";

function assertNoError(error: { message: string } | null, context: string) {
  if (error) throw new Error(`${context}: ${error.message}`);
}

function reportPayload(body: Record<string, unknown>, details = true) {
  const startDate = String(body.p_start_date);
  const endDate = String(body.p_end_date);
  const offset = Number(body.p_detail_offset ?? 0);
  const rowCount = details ? (offset === 0 ? 50 : 1) : 0;
  const rows = Array.from({ length: rowCount }, (_, index) => {
    const ordinal = offset + index + 1;
    return {
          id: `00000000-0000-4000-8000-${String(ordinal).padStart(12, "0")}`,
          lane_id: resourceId,
          lane_name_snapshot: "[TEST] Oś mobilna",
          lane_display_name: "[TEST] Oś mobilna — Stanowisko 1",
          resource_kind: "position",
          parent_lane_id: resourceId,
          customer_name: "[TEST] Klient",
          customer_email: "test-reports@example.invalid",
          customer_phone: null,
          reservation_date: startDate,
          start_time: "10:00:00",
          end_time: "11:00:00",
          duration_minutes: 60,
          total_price: 70,
          reservation_status: "confirmed",
          payment_status: "paid",
        };
  });

  return {
    ok: true,
    code: "ok",
    contract_version: 2,
    filters: {
      start_date: startDate,
      end_date: endDate,
      resource_id: body.p_resource_id ?? null,
      reservation_status: body.p_reservation_status ?? null,
      payment_status: body.p_payment_status ?? null,
      booking_type: body.p_booking_type ?? null,
    },
    filter_options: {
      resources: [
        {
          id: resourceId,
          name: "[TEST] Oś mobilna",
          resource_kind: "lane",
          parent_lane_id: null,
          display_name: "[TEST] Oś mobilna",
        },
      ],
    },
    range: {
      start_date: startDate,
      end_date: endDate,
      end_inclusive: true,
      days: 1,
      time_zone: "Europe/Warsaw",
      opening_start: "08:00",
      opening_end: "20:00",
      opening_minutes_per_day: 720,
    },
    summary: {
      active_reservation_count: details ? 1 : 0,
      completed_reservation_count: 0,
      cancelled_reservation_count: 0,
      no_show_reservation_count: 0,
      planned_revenue: details ? 70 : 0,
      paid_revenue: details ? 70 : 0,
      outstanding_revenue: 0,
      effective_capacity: 1,
      occupied_minutes: details ? 60 : 0,
      available_minutes: 720,
      occupancy_percent: details ? 8 : 0,
      best_day: details ? { date: startDate, planned_revenue: 70 } : null,
      top_resource: details
        ? {
            lane_id: resourceId,
            lane_name: "[TEST] Oś mobilna",
            reservation_count: 1,
          }
        : null,
    },
    details: rows,
    pagination: { total: details ? 51 : 0, limit: 50, offset },
    history: {
      name_basis: "reservation_snapshot",
      position_parent_name_basis: "current_configuration",
      capacity_basis: "current_configuration",
    },
  };
}

async function createAdmin() {
  const { data, error } = await service.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
    user_metadata: { test_marker: "[TEST][REPORTS-6C-E2E]" },
  });
  assertNoError(error, "create reports admin");
  if (!data.user) throw new Error("Reports admin was not created.");
  adminUserId = data.user.id;
  const { error: profileError } = await service
    .from("profiles")
    .upsert(
      {
        user_id: adminUserId,
        first_name: "[TEST]",
        last_name: "Reports 6C",
        full_name: "[TEST] Reports 6C",
        email,
        role: "admin",
      },
      { onConflict: "user_id" },
    );
  assertNoError(profileError, "configure reports admin profile");
}

async function login(page: Page) {
  const forbidden: string[] = [];
  await page.route("**/*", async (route) => {
    const hostname = new URL(route.request().url()).hostname.toLowerCase();
    if (hostname.endsWith(".supabase.co")) {
      forbidden.push(hostname);
      await route.abort("blockedbyclient");
      return;
    }
    await route.continue();
  });
  await page.goto("/login");
  await page.getByLabel("E-mail").fill(email);
  await page.getByLabel("Hasło").fill(password);
  await page.getByRole("button", { name: "Zaloguj się" }).click();
  await expect(page).toHaveURL(/\/dashboard$/u);
  expect(forbidden).toEqual([]);
  return forbidden;
}

async function mockReport(page: Page, response: "success" | "empty" | "error") {
  await page.route("**/rest/v1/rpc/admin_get_reservation_report_v2", async (route: Route) => {
    if (response === "error") {
      await route.fulfill({ status: 500, contentType: "application/json", body: "{}" });
      return;
    }
    const body = (route.request().postDataJSON() ?? {}) as Record<string, unknown>;
    await route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify(reportPayload(body, response === "success")),
    });
  });
}

test.describe.serial("REPORTS-6C responsive UX", () => {
  test.beforeAll(createAdmin);
  test.afterAll(async () => {
    if (!adminUserId) return;
    const { error } = await service.auth.admin.deleteUser(adminUserId);
    assertNoError(error, "delete reports admin");
  });

  for (const viewport of [
    { name: "mobile 320", width: 320, height: 800 },
    { name: "mobile 375", width: 375, height: 850 },
    { name: "mobile 430", width: 430, height: 900 },
    { name: "desktop", width: 1440, height: 1000 },
  ]) {
    test(`${viewport.name} keeps reports usable without page overflow`, async ({ page }) => {
      await page.setViewportSize({ width: viewport.width, height: viewport.height });
      const forbidden = await login(page);
      await mockReport(page, "success");
      await page.goto("/admin/reports?from=2026-09-05&to=2026-09-05");
      await expect(page.getByRole("heading", { name: "Kluczowe wskaźniki" })).toBeVisible();
      await expect(page.getByLabel("Oś lub stanowisko")).toBeVisible();
      await expect(page.getByRole("button", { name: "Eksportuj CSV" })).toBeEnabled();
      await expect(page.getByText("Strona 1 z 2")).toBeVisible();

      if (viewport.width < 1280) {
        const cards = page.getByLabel("Rezerwacje w okresie — widok kart");
        await expect(cards).toBeVisible();
        await expect(
          cards.getByText("Pojedyncze stanowisko", { exact: true }).first(),
        ).toBeVisible();
        await expect(page.getByLabel("Tabela rezerwacji w okresie")).toBeHidden();
      } else {
        await expect(page.getByLabel("Tabela rezerwacji w okresie")).toBeVisible();
        await expect(page.getByLabel("Rezerwacje w okresie — widok kart")).toBeHidden();
      }

      const dimensions = await page.evaluate(() => ({
        viewport: document.documentElement.clientWidth,
        page: document.documentElement.scrollWidth,
      }));
      expect(dimensions.page).toBeLessThanOrEqual(dimensions.viewport);

      await page.getByLabel("Status rezerwacji").selectOption("confirmed");
      await expect(page).toHaveURL(/status=confirmed/u);
      await expect(page.getByText("Strona 1 z 2")).toBeVisible();
      await page.getByRole("button", { name: "Następna strona raportu" }).click();
      await expect(page.getByText("Strona 2 z 2")).toBeVisible();
      expect(forbidden).toEqual([]);
    });
  }

  test("empty and error states remain controlled", async ({ page }) => {
    await page.setViewportSize({ width: 375, height: 850 });
    await login(page);
    await mockReport(page, "empty");
    await page.goto("/admin/reports?from=2026-09-05&to=2026-09-05");
    await expect(page.getByText("Brak rezerwacji zgodnych z aktywnymi filtrami.")).toBeVisible();
    await expect(page.getByText("Brak danych do eksportu dla aktywnych filtrów.")).toBeVisible();
    await expect(page.getByRole("button", { name: "Eksportuj CSV" })).toBeDisabled();

    await page.unroute("**/rest/v1/rpc/admin_get_reservation_report_v2");
    await mockReport(page, "error");
    await page.reload();
    await expect(
      page.getByRole("alert").filter({
        hasText: "Nie udało się pobrać kompletnego zestawu danych raportu.",
      }),
    ).toBeVisible();
    await expect(page.getByRole("button", { name: "Spróbuj ponownie" })).toBeVisible();
  });
});
