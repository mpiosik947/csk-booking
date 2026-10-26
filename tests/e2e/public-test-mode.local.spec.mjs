import { test, expect } from "@playwright/test";
import { createServerClient } from "@supabase/ssr";
import fs from "node:fs";
import assert from "node:assert/strict";

// Explicit disposable fixture file. Never load project .env or production credentials.
const fixture = JSON.parse(fs.readFileSync(process.env.PUBLIC_TEST_MODE_FIXTURE_FILE, "utf8"));
for (const value of [fixture.app, fixture.origin]) assert.equal(new URL(value).hostname, "127.0.0.1");
assert.match(fixture.scratchDatabase, /^sbr3_[a-f0-9]{16}$/);
const A = "e7310000-0000-4000-8000-000000000001";
const B = "e7320000-0000-4000-8000-000000000001";
const eventA = "e7310000-0000-4000-8000-000000000003";
const users = {
  customer: "ptm1-customer@example.invalid", admin: "ptm2-0@example.invalid",
  employee: "ptm2-1@example.invalid", instructor: "ptm2-2@example.invalid",
  suspended: "ptm2-3@example.invalid", pending: "ptm2-4@example.invalid",
  foreign: "ptm2-5@example.invalid", pa: "ptm2-6@example.invalid", removed: "ptm2-7@example.invalid",
  customerB: "ptm2-b-customer@example.invalid",
};
async function session(actor) {
  const cookies = [];
  const client = createServerClient(fixture.origin, fixture.anonKey, {
    cookieOptions: { secure: true },
    cookies: { getAll: () => [], setAll: items => cookies.push(...items) },
  });
  const { data, error } = await client.auth.signInWithPassword({ email: users[actor], password: fixture.password });
  expect(error).toBeNull();
  return { token: data.session.access_token, cookies: cookies.map(({ name, value }) => ({ name, value, domain: "127.0.0.1", path: "/", secure: true, sameSite: "Lax" })) };
}
async function login(context, actor) {
  const auth = await session(actor);
  await context.addCookies(auth.cookies);
  return auth;
}
async function rpc(name, args, token = fixture.anonKey) {
  const response = await fetch(`${fixture.origin}/rest/v1/rpc/${name}`, {
    method: "POST", headers: { apikey: fixture.anonKey, authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: JSON.stringify(args),
  });
  return { status: response.status, body: await response.json() };
}
test.beforeEach(async ({ context }) => {
  await context.route("**/*", route => new URL(route.request().url()).hostname === "127.0.0.1" ? route.continue() : route.abort());
});

test("public card, direct URLs, safe metadata and no premature business requests", async ({ page }) => {
  const business = [];
  page.on("request", req => { if (/rpc\/get_public_(booking_configuration|event_list|event_availability)/.test(req.url())) business.push(req.url()); });
  await page.goto("/");
  await expect(page.getByText("WERSJA TESTOWA", { exact: true })).toBeVisible();
  await expect(page.locator('a[href="/ptm1-public-a"]')).toHaveCount(0);
  await expect(page.locator("article").filter({ hasText: "Dostępna wkrótce" })).toBeVisible();
  await expect(page.locator('a[href="/ptm2-public-b"]')).toBeVisible();
  for (const path of ["/ptm1-public-a", "/t/ptm1-synthetic-a/booking", "/t/ptm1-synthetic-a/events"]) {
    await page.goto(path);
    await expect(page.getByRole("heading", { name: /Dostępna wkrótce/ })).toBeVisible();
    await expect(page.locator('meta[name="robots"]')).toHaveAttribute("content", /noindex/);
    await expect(page.getByText("synthetic@example.invalid", { exact: false })).toHaveCount(0);
  }
  expect(business).toHaveLength(0);
});

for (const actor of ["customer", "suspended", "pending", "foreign", "removed", "admin", "employee", "instructor", "pa"]) {
  const allowed = ["admin", "employee", "instructor", "pa"].includes(actor);
  test(`${actor}: real session, homepage and direct booking/events`, async ({ page, context }) => {
    const auth = await login(context, actor);
    await page.goto("/");
    await expect(page.locator('a[href="/ptm1-public-a"]')).toHaveCount(allowed ? 1 : 0);
    for (const route of ["booking", "events"]) {
      await page.goto(`/t/ptm1-synthetic-a/${route}`);
      if (!allowed) await expect(page.getByRole("heading", { name: /Dostępna wkrótce/ })).toBeVisible();
      else {
        await expect(page.getByRole("heading", { name: /Dostępna wkrótce/ })).toHaveCount(0);
        if (route === "booking") await expect(page.getByRole("heading", { name: "Zarezerwuj oś" })).toBeVisible();
        else await expect(page.getByText("[TEST][PUBLIC-TEST-MODE-2] event", { exact: true }).first()).toBeVisible();
      }
    }
    for (const name of ["get_public_booking_configuration_v2", "get_public_event_list_v3", "get_public_event_availability_v2"]) {
      const result = await rpc(name, { p_tenant_id: A }, auth.token);
      expect(result.status).toBe(allowed ? 200 : 423);
      if (!allowed) expect(result.body.code).toBe("PT423");
    }
  });
}

test("Tenant B stays live with a real customer registration; A creates nothing", async ({ page, context }) => {
  const auth = await login(context, "customerB");
  await page.goto("/t/ptm2-b/events");
  await expect(page.getByText("[TEST][PUBLIC-TEST-MODE-2-B] event", { exact: true }).first()).toBeVisible();
  expect((await rpc("get_public_booking_configuration_v2", { p_tenant_id: B }, auth.token)).body).toHaveLength(1);
  const registered = await rpc("register_for_event", { p_event_id: eventA.replace("e731", "e732"), p_as_reserve: false }, auth.token);
  expect(registered.status).toBe(200);
  expect(registered.body.ok).toBe(true);
  expect((await rpc("register_for_event", { p_event_id: eventA, p_as_reserve: true }, auth.token)).status).toBe(423);
});

test("owned history and cancellation remain available; new API operations are typed unavailable", async ({ page, context, request }) => {
  const auth = await login(context, "customer");
  for (const route of ["my-reservations", "my-events"]) {
    const response = await page.goto(`/t/ptm1-synthetic-a/${route}`);
    expect(response.status()).toBe(200);
    await expect(page.getByRole("heading", { name: /Dostępna wkrótce/ })).toHaveCount(0);
  }
  const denied = await request.post(`${fixture.app}/api/register-event?tenant=ptm1-synthetic-a`, {
    headers: { authorization: `Bearer ${auth.token}` }, data: { eventId: eventA, asReserve: false },
  });
  expect(denied.status()).toBe(423);
  expect((await denied.json()).code).toBe("TENANT_PUBLIC_ACCESS_UNAVAILABLE");
  const promotion = await request.post(`${fixture.app}/api/confirm-event-reserve-promotion`, {
    headers: { authorization: `Bearer ${auth.token}` }, data: { token: "e7310000-0000-4000-8000-000000000099" },
  });
  expect(promotion.status()).toBe(423);
  for (const [name, args] of [
    ["cancel_reservation", { p_reservation_id: "e7310000-0000-4000-8000-000000000031" }],
    ["cancel_event_registration", { p_registration_id: "e7310000-0000-4000-8000-000000000030" }],
  ]) expect((await rpc(name, args, auth.token)).status).toBe(200);
});

test("instructor assigned scope and PA management remain separate from tenant operations", async ({ page, context }) => {
  await login(context, "instructor");
  await page.goto("/t/ptm1-synthetic-a/instructor/events");
  await expect(page.getByRole("link", { name: "[TEST][PUBLIC-TEST-MODE-2] event", exact: true })).toBeVisible();
  expect((await page.goto("/t/ptm2-b/admin/events")).status()).toBe(404);
  await context.clearCookies();
  await login(context, "pa");
  expect((await page.goto("/platform-admin")).status()).toBe(200);
  expect((await page.goto("/t/ptm1-synthetic-a/admin/events")).status()).toBe(404);
});

test("concurrent admin/customer/anon requests do not share cached decisions", async ({ browser }) => {
  const contexts = await Promise.all([0, 1, 2].map(() => browser.newContext({ ignoreHTTPSErrors: true })));
  try {
    await login(contexts[0], "admin"); await login(contexts[1], "customer");
    const pages = await Promise.all(contexts.map(c => c.newPage()));
    for (let round = 0; round < 3; round++) {
      await Promise.all(pages.map(p => p.goto("/t/ptm1-synthetic-a/booking")));
      await expect(pages[0].getByRole("heading", { name: "Zarezerwuj oś" })).toBeVisible();
      for (const page of pages.slice(1)) await expect(page.getByRole("heading", { name: /Dostępna wkrótce/ })).toBeVisible();
    }
  } finally { await Promise.all(contexts.map(c => c.close())); }
});

test("mobile coming-soon card has no link and no horizontal overflow", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 }); await page.goto("/");
  await expect(page.locator('a[href="/ptm1-public-a"]')).toHaveCount(0);
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
});

test("session lost between server render and hydration invalidates internal links", async ({ page, context }) => {
  await login(context, "admin");
  let held = false;
  await context.route("**/ptm1-public-a", async route => {
    if (held || route.request().resourceType() !== "document") return route.continue();
    held = true;
    const response = await route.fetch();
    await context.clearCookies();
    await route.fulfill({ response });
  });
  await page.goto("/ptm1-public-a");
  await expect(page.getByRole("heading", { name: /Dostępna wkrótce/ })).toBeVisible();
  await expect(page.locator('a[href="/t/ptm1-synthetic-a/booking"]')).toHaveCount(0);
});

test("real UI login then local logout returns to public gate", async ({ page, context }) => {
  await page.goto("/login?redirectTo=%2F");
  await page.getByLabel("E-mail", { exact: true }).fill(users.admin);
  await page.getByLabel("Hasło", { exact: true }).fill(fixture.password);
  await page.getByRole("button", { name: "Zaloguj się", exact: true }).click();
  await page.waitForURL(fixture.app + "/");
  await expect(page.locator('a[href="/ptm1-public-a"]')).toBeVisible();
  // Local network-only mapping of the app's canonical logout navigation.
  await context.route("https://strzelajtu.pl/**", route => route.fulfill({ status: 302, headers: { location: fixture.app + "/" } }));
  await page.getByRole("button", { name: "Wyloguj", exact: true }).first().click();
  await expect(page.locator('a[href="/ptm1-public-a"]')).toHaveCount(0);
  await page.goto("/t/ptm1-synthetic-a/events");
  await expect(page.getByRole("heading", { name: /Dostępna wkrótce/ })).toBeVisible();
});
