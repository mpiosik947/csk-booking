import { randomUUID } from "node:crypto";
import { createClient } from "@supabase/supabase-js";
import { expect, test, type Page, type Route } from "@playwright/test";
import { getLocalSupabaseTestEnvironment } from "./local-supabase";

const environment = getLocalSupabaseTestEnvironment();
const service = createClient(
  environment.supabaseUrl,
  environment.serviceRoleKey,
  { auth: { autoRefreshToken: false, persistSession: false } }
);
const runMarker = `${Date.now()}-${randomUUID().slice(0, 8)}`;
const email = `test-cancellation-deadline-${runMarker}@example.invalid`;
const password = `Local-Deadline-${randomUUID()}!Aa1`;
let userId = "";

function assertNoError(error: { message: string } | null, context: string) {
  if (error) throw new Error(`${context}: ${error.message}`);
}

async function createUser() {
  const { data, error } = await service.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
    user_metadata: { test_marker: "[TEST][V1.1-02-E2E]" },
  });
  assertNoError(error, "create V1.1-02 user");
  if (!data.user) throw new Error("V1.1-02 user was not created.");
  userId = data.user.id;

  const { error: profileError } = await service
    .from("profiles")
    .update({
      first_name: "[TEST]",
      last_name: "Deadline",
      full_name: "[TEST] Deadline",
      email,
      role: "user",
    })
    .eq("user_id", userId);
  assertNoError(profileError, "configure V1.1-02 profile");
}

async function login(page: Page) {
  await page.goto("/login");
  await page.getByLabel("E-mail").fill(email);
  await page.getByLabel("Hasło").fill(password);
  await page.getByRole("button", { name: "Zaloguj się" }).click();
  await expect(page).toHaveURL(/\/dashboard$/u);
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

async function mockRpc(
  page: Page,
  name: string,
  responder: (body: Record<string, unknown>) => unknown
) {
  const escapedName = name.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");
  await page.route(
    new RegExp(`/rest/v1/rpc/${escapedName}(?:\\?.*)?$`, "u"),
    async (route: Route) => {
    const body = (route.request().postDataJSON() ?? {}) as Record<
      string,
      unknown
    >;
    await route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify(responder(body)),
    });
    }
  );
}

async function expectNoPageOverflow(page: Page) {
  const dimensions = await page.evaluate(() => ({
    viewport: document.documentElement.clientWidth,
    page: document.documentElement.scrollWidth,
  }));
  expect(dimensions.page).toBeLessThanOrEqual(dimensions.viewport);
}

test.describe.serial("V1.1-02 exact cancellation deadline", () => {
  test.beforeAll(createUser);
  test.afterAll(async () => {
    if (!userId) return;
    const { error } = await service.auth.admin.deleteUser(userId);
    assertNoError(error, "delete V1.1-02 user");
  });

  test("reservation and event deadlines remain readable at 320, 375 and 430 px", async ({
    page,
  }) => {
    const forbidden = await guardLocalRequests(page);
    await login(page);

    await mockRpc(page, "get_my_reservations_v2", () => [
      {
        id: "00000000-0000-4000-8000-000000001102",
        reservation_date: "2026-12-20",
        start_time: "10:00:00",
        end_time: "11:00:00",
        price: 100,
        reservation_status: "confirmed",
        payment_status: "pending",
        check_in_token: null,
        attendance_status: "planned",
        checked_in_at: null,
        lane_display_name: "[TEST] Oś — Stanowisko 1",
      },
    ]);
    await page.goto("/my-reservations");
    await expect(
      page.getByText(
        "Samodzielne anulowanie możliwe do: 19 grudnia 2026 22:00 (Europe/Warsaw)."
      )
    ).toBeVisible();
    await expect(
      page.getByRole("button", { name: "Anuluj rezerwację" })
    ).toBeVisible();

    for (const width of [320, 375, 430]) {
      await page.setViewportSize({ width, height: 900 });
      await expectNoPageOverflow(page);
    }

    await mockRpc(page, "get_my_event_registrations_v1", (body) => ({
      ok: true,
      code: "ok",
      contract_version: 1,
      filters: { scope: body.p_scope ?? "upcoming", status: null },
      pagination: { page: 1, page_size: 20, total: 1 },
      items: [
        {
          id: "00000000-0000-4000-8000-000000001103",
          registration_status: "approved",
          payment_status: "paid",
          created_at: "2026-09-01T10:00:00Z",
          events: {
            id: "00000000-0000-4000-8000-000000001104",
            title: "[TEST] Termin szkolenia",
            description: "Opis testowy.",
            event_date: "2026-12-20",
            start_time: "10:00:00",
            end_time: "12:00:00",
            location: "Oś testowa",
            price: 150,
          },
        },
      ],
    }));
    await page.goto("/my-events");
    await page
      .getByRole("button", { name: /\[TEST\] Termin szkolenia/u })
      .click();
    await expect(
      page.getByText(
        "Samodzielne anulowanie możliwe do: 17 grudnia 2026 10:00 (Europe/Warsaw)."
      )
    ).toBeVisible();
    await expect(page.getByRole("button", { name: "Anuluj udział" })).toBeVisible();

    for (const width of [320, 375, 430]) {
      await page.setViewportSize({ width, height: 900 });
      await expectNoPageOverflow(page);
    }

    expect(forbidden).toEqual([]);
  });
});
