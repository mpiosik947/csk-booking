import { randomUUID } from "node:crypto";
import { createClient } from "@supabase/supabase-js";
import { expect, test, type Page, type Route } from "@playwright/test";
import { getLocalSupabaseTestEnvironment } from "./local-supabase";

const environment = getLocalSupabaseTestEnvironment();
const service = createClient(environment.supabaseUrl, environment.serviceRoleKey, {
  auth: { autoRefreshToken: false, persistSession: false },
});
const runMarker = String(Date.now()) + "-" + randomUUID().slice(0, 8);
const email = "test-events-8c-" + runMarker + "@example.invalid";
const password = "Local-Events-" + randomUUID() + "!Aa1";
let adminUserId = "";

const EVENT_ID = "00000000-0000-4000-8000-000000000801";
const SOLD_OUT_ID = "00000000-0000-4000-8000-000000000802";

function assertNoError(error: { message: string } | null, context: string) {
  if (error) throw new Error(context + ": " + error.message);
}

function publicEvent(eventId = EVENT_ID, soldOut = false) {
  return {
    event_id: eventId,
    title: soldOut ? "[TEST] Szkolenie pełne" : "[TEST] Szkolenie mobilne",
    description: "Czytelny opis szkolenia.",
    event_date: "2026-12-20",
    start_time: "10:00:00",
    end_time: "12:00:00",
    location: "Oś testowa",
    price: 150,
    max_participants: 10,
    registered_count: soldOut ? 10 : 3,
    reserve_count: 0,
    available_spots: soldOut ? 0 : 7,
    sold_out: soldOut,
  };
}

function publicPayload(body: Record<string, unknown>) {
  const currentPage = Number(body.p_page ?? 1);
  const items = currentPage === 1
    ? [
        publicEvent(),
        publicEvent(SOLD_OUT_ID, true),
        {
          ...publicEvent("00000000-0000-4000-8000-000000000804"),
          title: "[TEST] Lista rezerwowa",
          registered_count: 9,
          reserve_count: 2,
          available_spots: 1,
        },
      ]
    : [publicEvent("00000000-0000-4000-8000-000000000803")];
  return {
    ok: true,
    code: "ok",
    contract_version: 2,
    filters: { search: body.p_search ?? null, scope: "upcoming" },
    pagination: { page: currentPage, page_size: 20, total: 21 },
    items,
  };
}

function myPayload(body: Record<string, unknown>) {
  const scope = String(body.p_scope ?? "upcoming");
  const currentPage = Number(body.p_page ?? 1);
  const history = scope === "history";
  const item = {
    id: history
      ? "00000000-0000-4000-8000-000000000812"
      : "00000000-0000-4000-8000-000000000811",
    registration_status: history ? "cancelled" : String(body.p_status ?? "approved"),
    payment_status: history ? "unpaid" : "paid",
    created_at: "2026-09-01T10:00:00Z",
    events: {
      id: history
        ? "00000000-0000-4000-8000-000000000822"
        : "00000000-0000-4000-8000-000000000821",
      title: history ? "[TEST] Historia szkolenia" : "[TEST] Moje szkolenie",
      description: "Opis mojego szkolenia.",
      event_date: history ? "2026-01-10" : "2026-12-20",
      start_time: "10:00:00",
      end_time: "12:00:00",
      location: "Oś testowa",
      price: 150,
    },
  };
  return {
    ok: true,
    code: "ok",
    contract_version: 1,
    filters: { scope, status: body.p_status ?? null },
    pagination: { page: currentPage, page_size: 20, total: 21 },
    items: [item],
  };
}

function adminPayload(body: Record<string, unknown>) {
  const currentPage = Number(body.p_page ?? 1);
  return {
    ok: true,
    code: "ok",
    contract_version: 1,
    filters: {
      search: body.p_search ?? null,
      scope: body.p_scope ?? "upcoming",
      sort: body.p_sort ?? "nearest",
    },
    pagination: { page: currentPage, page_size: 20, total: 21 },
    summary: { all_count: 21, upcoming_count: 20, past_count: 1, inactive_count: 1 },
    items: [{
      id: EVENT_ID,
      title: "[TEST] Admin szkolenie",
      description: "Opis szkolenia.",
      event_date: "2026-12-20",
      start_time: "10:00:00",
      end_time: "12:00:00",
      location: "Oś testowa",
      price: 150,
      max_participants: 10,
      is_active: true,
      created_at: "2026-09-01T10:00:00Z",
      lanes: [],
    }],
  };
}

function participantPayload(body: Record<string, unknown>) {
  const currentPage = Number(body.p_page ?? 1);
  const status = String(body.p_status ?? "");
  const rowStatus = status || (currentPage === 1 ? "registered" : "reserve");
  return {
    ok: true,
    code: "ok",
    contract_version: 1,
    filters: { event_id: EVENT_ID, status: status || null, payment_status: body.p_payment_status ?? null },
    pagination: { page: currentPage, page_size: 50, total: 51 },
    summary: { registered_count: 3, reserve_count: 2, cancelled_count: 1, paid_count: 1 },
    items: [{
      id: currentPage === 1
        ? "00000000-0000-4000-8000-000000000831"
        : "00000000-0000-4000-8000-000000000832",
      customer_name: "[TEST] Uczestnik",
      customer_email: "participant@example.invalid",
      customer_phone: "+48000000000",
      registration_status: rowStatus,
      payment_status: "unpaid",
      created_at: "2026-09-01T10:00:00Z",
    }],
  };
}

async function createAdmin() {
  const { data, error } = await service.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
    user_metadata: { test_marker: "[TEST][EVENTS-8C-E2E]" },
  });
  assertNoError(error, "create EVENTS-8C admin");
  if (!data.user) throw new Error("EVENTS-8C admin was not created.");
  adminUserId = data.user.id;
  const { error: profileError } = await service
    .from("profiles")
    .upsert(
      {
        user_id: adminUserId,
        first_name: "[TEST]",
        last_name: "Events 8C",
        full_name: "[TEST] Events 8C",
        email,
        role: "admin",
      },
      { onConflict: "user_id" },
    );
  assertNoError(profileError, "configure EVENTS-8C admin profile");
}

async function guardLocalRequests(page: Page) {
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
  return forbidden;
}

async function login(page: Page) {
  await page.goto("/login");
  await page.getByLabel("E-mail").fill(email);
  await page.getByLabel("Hasło").fill(password);
  await page.getByRole("button", { name: "Zaloguj się" }).click();
  await expect(page).toHaveURL(/\/dashboard$/u);
}

async function mockRpc(
  page: Page,
  name: string,
  responder: (body: Record<string, unknown>) => unknown,
) {
  await page.route("**/rest/v1/rpc/" + name, async (route: Route) => {
    const body = (route.request().postDataJSON() ?? {}) as Record<string, unknown>;
    await route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify(responder(body)),
    });
  });
}

async function mockLoggedOutUser(page: Page) {
  await page.route("**/auth/v1/user", (route) =>
    route.fulfill({
      status: 401,
      contentType: "application/json",
      body: JSON.stringify({ message: "not authenticated" }),
    }),
  );
}

async function expectNoPageOverflow(page: Page) {
  const dimensions = await page.evaluate(() => ({
    viewport: document.documentElement.clientWidth,
    page: document.documentElement.scrollWidth,
    offenders: Array.from(document.querySelectorAll("body *"))
      .map((element) => {
        const rect = element.getBoundingClientRect();
        return { tag: element.tagName, className: element.className, right: rect.right, width: rect.width };
      })
      .filter((item) => item.right > document.documentElement.clientWidth + 1)
      .slice(0, 5),
  }));
  expect(dimensions.page, JSON.stringify(dimensions.offenders)).toBeLessThanOrEqual(dimensions.viewport);
}

test.describe.serial("EVENTS-8C responsive UX", () => {
  test.beforeAll(createAdmin);
  test.afterAll(async () => {
    if (!adminUserId) return;
    const { error } = await service.auth.admin.deleteUser(adminUserId);
    assertNoError(error, "delete EVENTS-8C admin");
  });

  for (const viewport of [
    { name: "mobile 320", width: 320, height: 800 },
    { name: "mobile 375", width: 375, height: 850 },
    { name: "mobile 430", width: 430, height: 900 },
    { name: "tablet", width: 768, height: 1024 },
    { name: "desktop", width: 1440, height: 1000 },
  ]) {
    test(viewport.name + " renders public events without overflow", async ({ page }) => {
      await page.setViewportSize({ width: viewport.width, height: viewport.height });
      const forbidden = await guardLocalRequests(page);
      await mockLoggedOutUser(page);
      await mockRpc(page, "get_public_event_list_v2", publicPayload);
      await page.goto("/events");
      await expect(page.getByText("[TEST] Szkolenie mobilne")).toBeVisible();
      await expect(page.getByText("Pełne", { exact: true })).toBeVisible();
      await expect(page.getByText("Lista rezerwowa: 2")).toBeVisible();
      await expectNoPageOverflow(page);
      expect(forbidden).toEqual([]);
    });
  }

  test("public search, pagination, controlled error and retry remain usable", async ({ page }) => {
    await guardLocalRequests(page);
    await mockLoggedOutUser(page);
    await mockRpc(page, "get_public_event_list_v2", publicPayload);
    await page.goto("/events");
    await page.getByLabel("Szukaj szkolenia").fill("mobilne");
    await expect(page).toHaveURL(/q=mobilne/u);
    await page.getByRole("button", { name: "Następna" }).click();
    await expect(page).toHaveURL(/page=2/u);
    await expect(page.getByText("Strona 2 z 2")).toBeVisible();

    await page.unroute("**/rest/v1/rpc/get_public_event_list_v2");
    await page.route("**/rest/v1/rpc/get_public_event_list_v2", (route) =>
      route.fulfill({ status: 500, contentType: "application/json", body: "{}" }),
    );
    await page.reload();
    await expect(
      page.getByRole("alert").filter({ hasText: "Nie udało się pobrać szkoleń" }),
    ).toContainText("Nie udało się pobrać szkoleń");
    await expect(page.getByRole("button", { name: "Spróbuj ponownie" })).toBeVisible();
  });

  test("my events supports upcoming, history, all, status and pagination on mobile", async ({ page }) => {
    await page.setViewportSize({ width: 320, height: 800 });
    const forbidden = await guardLocalRequests(page);
    await login(page);
    await mockRpc(page, "get_my_event_registrations_v1", myPayload);
    await page.goto("/my-events");
    await expect(page.getByText("[TEST] Moje szkolenie")).toBeVisible();
    await page.getByRole("button", { name: /\[TEST\] Moje szkolenie/u }).click();
    await expect(page.getByRole("button", { name: "Anuluj udział" })).toBeVisible();
    await page.getByLabel("Status").selectOption("approved");
    await expect(page).toHaveURL(/status=approved/u);
    await page.getByLabel("Zakres").selectOption("history");
    await expect(page).toHaveURL(/scope=history/u);
    await expect(page.getByText("[TEST] Historia szkolenia")).toBeVisible();
    await page.getByLabel("Zakres").selectOption("all");
    await expect(page).toHaveURL(/scope=all/u);
    await page.getByRole("button", { name: "Następna" }).click();
    await expect(page).toHaveURL(/page=2/u);
    for (const width of [320, 375, 430, 768, 1440]) {
      await page.setViewportSize({ width, height: width < 700 ? 900 : 1024 });
      await expectNoPageOverflow(page);
    }
    expect(forbidden).toEqual([]);
  });

  test("admin filters and participant cards stay bounded and responsive", async ({ page }) => {
    await page.setViewportSize({ width: 375, height: 900 });
    const forbidden = await guardLocalRequests(page);
    await login(page);
    await mockRpc(page, "admin_list_events_v1", adminPayload);
    await mockRpc(page, "admin_list_event_registrations_v1", participantPayload);
    await page.goto("/admin/events");
    await expect(page.getByText("[TEST] Admin szkolenie")).toBeVisible();
    await page.getByLabel("Szukaj").fill("admin");
    await expect(page).toHaveURL(/q=admin/u);
    await page.getByLabel("Zakres").selectOption("all");
    await expect(page).toHaveURL(/scope=all/u);
    await page.getByRole("button", { name: "Pokaż zapisanych" }).click();
    await expect(page.getByText("[TEST] Uczestnik")).toBeVisible();
    await expect(page.getByText("Imię i nazwisko", { exact: true }).last()).toBeVisible();
    await page.getByLabel("Status zapisu").selectOption("reserve");
    await expect(page.getByRole("heading", { name: "Lista rezerwowa" })).toBeVisible();
    await page.getByLabel("Status płatności").selectOption("unpaid");
    await page.getByRole("button", { name: "Następna" }).last().click();
    await expect(page.getByText("Strona 2 z 2")).toBeVisible();
    for (const width of [320, 375, 430, 768, 1440]) {
      await page.setViewportSize({ width, height: width < 700 ? 900 : 1024 });
      await expectNoPageOverflow(page);
    }
    expect(forbidden).toEqual([]);
  });
});
