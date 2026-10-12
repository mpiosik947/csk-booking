import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { test, expect, type Page, type TestInfo } from "@playwright/test";

// Real Auth/PostgREST/Next, disposable canonical local replay only. No API mocks.
const fixture = JSON.parse(readFileSync(process.env.LEGAL_3E_E2E_FIXTURE!, "utf8")) as {
  app: string; origin: string; password: string; scratchDatabase: string;
};
for (const url of [fixture.app, fixture.origin]) {
  if (new URL(url).hostname !== "127.0.0.1") throw Error("Loopback fixture required");
}
if (!/^sbr3_[a-f0-9]{16}$/.test(fixture.scratchDatabase)) throw Error("Disposable database required");

function sql(statement: string) {
  return execFileSync("docker", ["exec", "-i", "supabase_db_csk-booking", "psql", "-X", "-At",
    "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", fixture.scratchDatabase], {
    input: statement, encoding: "utf8", windowsHide: true,
  }).trim();
}

test.beforeEach(async ({ context }) => {
  await context.route("**/*", route => new URL(route.request().url()).hostname === "127.0.0.1" ? route.continue() : route.abort());
});

async function login(page: Page, actor: string) {
  await page.goto(fixture.app + "/login?redirectTo=%2Fdashboard");
  await page.getByLabel("E-mail", { exact: true }).fill(actor + "@synthetic.invalid");
  await page.getByLabel("Hasło", { exact: true }).fill(fixture.password);
  await page.getByRole("button", { name: "Zaloguj się", exact: true }).click();
  await expect(page).toHaveURL(/\/dashboard$/);
}

async function noLegacyPresentation(page: Page) {
  await expect(page.locator("body")).not.toContainText(/CSK|Krutla/);
  await expect(page.locator('img[alt*="CSK"],img[alt*="Krutla"],img[src*="login-brand"]')).toHaveCount(0);
}

async function layout(page: Page, info: TestInfo, name: string) {
  await expect(page.locator("h1").first()).toBeVisible();
  await expect(page.getByText(/^(?:Ładowanie|Sprawdzanie użytkownika).*\.\.\.$/)).toHaveCount(0);
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
  for (const logo of await page.getByRole("img", { name: "StrzelajTu.pl", exact: true }).all()) {
    await expect(logo).toBeVisible();
    await expect.poll(() => logo.evaluate((img: HTMLImageElement) => img.complete && img.naturalWidth > 0)).toBe(true);
    const ratio = await logo.evaluate(img => img.getBoundingClientRect().width / img.getBoundingClientRect().height);
    expect(ratio).toBeCloseTo(2048 / 682, 1);
  }
  await page.screenshot({ path: info.outputPath(name + ".png"), fullPage: true });
}

for (const width of [320, 375, 1440]) {
  test(`global auth, legal and token shells at ${width}`, async ({ page }, info) => {
    await page.setViewportSize({ width, height: 1000 });
    for (const route of ["/", "/login", "/register", "/forgot-password", "/reset-password", "/privacy", "/terms", "/check-in/invalid", "/events/confirm/invalid"]) {
      const response = await page.goto(fixture.app + route);
      expect(response?.status()).toBe(200);
      await expect(page.getByRole("img", { name: "StrzelajTu.pl", exact: true }).first()).toBeVisible();
      if (route === "/") {
        await expect(page.locator("header")).not.toContainText(/CSK|Krutla/);
      } else await noLegacyPresentation(page);
      await layout(page, info, route.replaceAll("/", "_") || "home");
    }
    await page.goto(fixture.app + "/login?redirectTo=%2Ft%2Fsynt-b%2Fbooking");
    expect(new URL(page.url()).searchParams.get("redirectTo")).toBe("/t/synt-b/booking");
    await page.getByLabel("E-mail", { exact: true }).focus();
    await expect(page.getByLabel("E-mail", { exact: true })).toBeFocused();
  });

  test(`customer A/B shared pages, account and real downloads at ${width}`, async ({ page }, info) => {
    await page.setViewportSize({ width, height: 1000 });
    await login(page, "customer_shared");
    await page.goto(fixture.app + "/account");
    await expect(page.getByRole("button", { name: "Pobierz moje dane", exact: true })).toBeVisible();
    await noLegacyPresentation(page);
    await layout(page, info, "account");
    const exported = page.waitForResponse(r => r.url().endsWith("/api/account/export"));
    const downloaded = page.waitForEvent("download");
    await page.getByRole("button", { name: "Pobierz moje dane", exact: true }).click();
    const response = await exported, file = await downloaded;
    expect(response.status()).toBe(200);
    expect(response.headers()["content-disposition"]).toBe('attachment; filename="strzelajtu-my-data.json"');
    expect(file.suggestedFilename()).toBe("strzelajtu-my-data.json");
    const data = JSON.parse(readFileSync((await file.path())!, "utf8"));
    expect(data.export_version).toBe(3);
    expect(JSON.stringify(data)).not.toContain("customer_a@synthetic.invalid");
    expect(JSON.stringify(data)).not.toContain("customer_b@synthetic.invalid");
    for (const side of ["a", "b"]) {
      for (const [route, heading] of [["booking", "Zarezerwuj oś"], ["events", "Eventy i szkolenia"], ["my-reservations", "Moje rezerwacje"], ["my-events", "Moje szkolenia"]]) {
        await page.goto(fixture.app + `/t/synt-${side}/${route}`);
        await expect(page.getByRole("heading", { name: heading, exact: true })).toBeVisible();
        await expect(page.getByRole("navigation", { name: "Lokalizacja" })).toContainText("SYNT-" + side.toUpperCase());
        await noLegacyPresentation(page);
        await layout(page, info, side + "-" + route);
        const other = side === "a" ? "B" : "A";
        expect(await page.locator("body").innerText()).not.toMatch(new RegExp(`${other}-LANE|${other}_EVENT`));
        if (route === "my-reservations" || route === "my-events") {
          if (route === "my-events") await page.locator('button[aria-controls^="event-details-"]').first().click();
          const kind = route === "my-reservations" ? "reservations" : "event-registrations";
          const result = page.waitForResponse(r => r.url().includes("/api/calendar/" + kind + "/"));
          const download = page.waitForEvent("download");
          await page.getByRole("button", { name: "Dodaj do kalendarza", exact: true }).first().click();
          const icsResponse = await result, icsDownload = await download;
          expect(icsResponse.status()).toBe(200);
          expect(icsDownload.suggestedFilename()).toBe(route === "my-reservations" ? "strzelajtu-rezerwacja.ics" : "strzelajtu-szkolenie.ics");
          const ics = readFileSync((await icsDownload.path())!, "utf8").replace(/\r\n /g, "");
          const id = new URL(icsResponse.url()).pathname.split("/").at(-1)!;
          const recordType = route === "my-reservations" ? "reservation" : "event-registration";
          const uid = createHash("sha256").update(`csk-booking:${recordType}:${id}`).digest("hex") + "@calendar.csk-booking";
          expect(ics).toContain("UID:" + uid + "\r\n");
          expect(ics).toContain("PRODID:-//CSK Booking//Calendar Export//PL\r\n");
          expect(ics).not.toMatch(new RegExp(`${other}-LANE|${other}_EVENT`));
          expect(ics).not.toContain("@synthetic.invalid");
        }
      }
    }
  });

  for (const side of ["a", "b"]) {
    test(`tenant ${side} admin shared shells at ${width}`, async ({ page }, info) => {
      await page.setViewportSize({ width, height: 1000 });
      await login(page, side + "_admin");
      for (const route of ["admin", "admin/calendar", "admin/check-in", "admin/reservations", "admin/reports"]) {
        const response = await page.goto(fixture.app + `/t/synt-${side}/${route}`);
        expect(response?.status()).toBe(200);
        await expect(page.locator("h1").first()).toBeVisible();
        await noLegacyPresentation(page);
        await layout(page, info, route.replaceAll("/", "_"));
        if (route === "admin/reports" && width === 1440) {
          const reportDate = sql("select (current_date+30)::text;");
          await page.getByLabel("Data do", { exact: true }).fill(reportDate);
          await page.getByLabel("Data od", { exact: true }).fill(reportDate);
          const exportButton = page.getByRole("button", { name: "Eksportuj CSV", exact: true });
          await expect(exportButton).toBeEnabled();
          const csvDownload = page.waitForEvent("download");
          await exportButton.click();
          const csvFile = await csvDownload;
          expect(csvFile.suggestedFilename()).toBe(`rezerwacje-${reportDate}-${reportDate}.csv`);
          const csv = readFileSync((await csvFile.path())!, "utf8");
          expect(csv).toContain(side.toUpperCase() + "-LANE");
          expect(csv).not.toMatch(/CSK|Krutla/);
          expect(csv).not.toContain((side === "a" ? "B" : "A") + "-LANE");
          expect(csv).not.toContain("customer_" + (side === "a" ? "b" : "a") + "@synthetic.invalid");
        }
      }
      const denied = await page.goto(fixture.app + `/t/synt-${side === "a" ? "b" : "a"}/admin`);
      expect(denied?.status()).toBe(404);
    });
  }

  test(`actual CSK identity and synthetic public tenant stay distinct at ${width}`, async ({ page }, info) => {
    await page.setViewportSize({ width, height: 1000 });
    expect((await page.goto(fixture.app + "/csk-krutla"))?.status()).toBe(200);
    const csk = page.getByTestId("tenant-logo");
    await expect(csk).toHaveAttribute("alt", /CSK.*Centrum Szkolenia Krutla/);
    await expect(csk).toHaveAttribute("src", /login-brand/);
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    await page.screenshot({ path: info.outputPath("csk-tenant.png"), fullPage: true });
    await page.goto(fixture.app + "/t/csk/booking");
    await expect(page.getByRole("navigation", { name: "Lokalizacja" })).toContainText(/CSK|Krutla/);
    await expect(page.getByRole("heading", { name: "Zarezerwuj oś", exact: true })).toBeVisible();
    await expect(page.locator("main header")).toContainText("StrzelajTu.pl");
    await expect(page.locator("main header")).not.toContainText(/CSK/);
    await page.goto(fixture.app + "/synt-b-public");
    await expect(page.getByRole("heading", { name: "SYNT-B", exact: true })).toBeVisible();
    await noLegacyPresentation(page);
    await layout(page, info, "tenant-b");
  });

  test(`platform admin shell remains global at ${width}`, async ({ page }, info) => {
    await page.setViewportSize({ width, height: 1000 });
    await login(page, "pa");
    await page.goto(fixture.app + "/platform-admin");
    await expect(page.getByRole("heading", { name: "Obiekty i onboarding", exact: true })).toBeVisible();
    // A CSK tenant row in the directory is legitimate data; only the shared header is global.
    await expect(page.getByTestId("admin-panel").locator("header").first()).toContainText("StrzelajTu.pl");
    for (const header of await page.locator("header").all()) await expect(header).not.toContainText(/CSK|Krutla/);
    await layout(page, info, "platform-admin");
  });
}

for (const side of ["a", "b"]) {
  test(`customer ${side}: owned records and authenticated global auth shell`, async ({ page }) => {
    await login(page, "customer_" + side);
    for (const route of ["/account", "/login", "/register", "/forgot-password", "/reset-password"]) {
      await page.goto(fixture.app + route);
      await expect(page.getByRole("img", { name: "StrzelajTu.pl", exact: true }).first()).toBeVisible();
      await noLegacyPresentation(page);
    }
    for (const route of ["my-reservations", "my-events"]) {
      await page.goto(fixture.app + `/t/synt-${side}/${route}`);
      await expect(page.getByRole("navigation", { name: "Lokalizacja" })).toContainText("SYNT-" + side.toUpperCase());
      await expect(page.locator("main")).toContainText(side.toUpperCase() + (route === "my-events" ? "_EVENT" : "-LANE"));
      await noLegacyPresentation(page);
      expect(await page.locator("body").innerText()).not.toMatch(new RegExp((side === "a" ? "B" : "A") + "(?:_EVENT|-LANE)"));
    }
  });

  for (const role of ["employee", "instructor"]) {
    test(`${side} ${role} shared UI and cross-tenant boundary`, async ({ page }) => {
      await login(page, side + "_" + role);
      const route = role === "instructor" ? "instructor/events" : "admin/check-in";
      expect((await page.goto(fixture.app + `/t/synt-${side}/${route}`))?.status()).toBe(200);
      await expect(page.locator("h1").first()).toBeVisible();
      await noLegacyPresentation(page);
      const denied = await page.goto(fixture.app + `/t/synt-${side === "a" ? "b" : "a"}/${route}`);
      expect(denied?.status()).toBe(404);
    });
  }
}

test("multi-tenant customer navigates A to B to A through real Next links and browser history", async ({ page }) => {
  await login(page, "customer_shared");
  for (const routeName of ["booking", "events", "my-reservations", "my-events"]) {
    for (const side of ["a", "b", "a"]) {
      await expect(page).toHaveURL(/\/dashboard$/);
      await page.locator(`a[href="/t/synt-${side}/${routeName}"]`).click();
      await expect(page).toHaveURL(new RegExp(`/t/synt-${side}/${routeName}$`));
      await expect(page.getByRole("navigation", { name: "Lokalizacja" })).toContainText("SYNT-" + side.toUpperCase());
      await expect(page.getByRole("navigation", { name: "Lokalizacja" })).not.toContainText("SYNT-" + (side === "a" ? "B" : "A"));
      await noLegacyPresentation(page);
      await page.goBack();
    }
  }
});

for (const side of ["a", "b"]) {
  test(`extended ${side}: real booking error and confirmation, event signup and empty/error states`, async ({ page }) => {
    const upper = side.toUpperCase();
    const date = sql("select (current_date+44)::text;");
    const cleanup = () => sql(`
      delete from public.events where tenant_id=audit_syntb.id('${upper}') and title='BRANDING ${upper} EVENT';
      delete from public.reservations where tenant_id=audit_syntb.id('${upper}')
        and user_id=audit_syntb.id('CUSTOMER_${upper}') and lane_id=audit_syntb.id('${upper}_LANE_2')
        and reservation_date=current_date+44;`);
    cleanup();
    try {
      await login(page, "customer_" + side);
      await page.goto(fixture.app + `/t/synt-${side}/booking`);
      await page.getByRole("button", { name: side === "a" ? "A-LANE-100" : "B-LANE-50", exact: true }).click();
      await page.getByLabel("Data", { exact: true }).fill(date);
      await page.getByRole("combobox", { name: "Liczba strzelców", exact: true }).selectOption("2");
      await page.getByRole("combobox", { name: "Czas rezerwacji", exact: true }).selectOption("60");
      await page.locator('button[data-slot-state="available"]').first().click();
      await page.getByRole("checkbox", { name: "Akceptuję regulamin i zasady bezpieczeństwa." }).check();
      // Simulate a real local configuration change after rendering; no mocked HTTP payload.
      sql(`update public.lane_booking_rules set max_people_online=1 where lane_id=audit_syntb.id('${upper}_LANE_2');`);
      try {
        const failed = page.waitForResponse(r => r.url().includes("/api/create-reservation"));
        await page.getByRole("button", { name: "Potwierdź rezerwację", exact: true }).click();
        expect(await (await failed).json()).toMatchObject({ ok: false, code: "contact_required" });
        await expect(page.locator("main").getByRole("alert")).toContainText("Dla większej liczby osób wymagany jest kontakt z obsługą tej strzelnicy.");
        await noLegacyPresentation(page);
      } finally {
        sql(`update public.lane_booking_rules set max_people_online=2 where lane_id=audit_syntb.id('${upper}_LANE_2');`);
      }
      const created = page.waitForResponse(r => r.url().includes("/api/create-reservation"));
      await page.getByRole("button", { name: "Potwierdź rezerwację", exact: true }).click();
      expect(await (await created).json()).toMatchObject({ ok: true, code: "created" });
      await expect(page.getByRole("dialog")).toContainText("Rezerwacja przyjęta");
      await expect(page.getByRole("dialog")).toContainText(upper + "-LANE");
      await noLegacyPresentation(page);

      // A fresh event belongs only to this disposable database and is removed with it.
      const result = JSON.parse(sql(`select audit_syntb.rpc(audit_syntb.id('${upper}_ADMIN'),
        format('select public.admin_create_event_with_instructors_v1(%L,%L,%L,current_date+45,%L,%L,%L,10,5,%L::uuid[],%L::uuid[])',
          audit_syntb.id('${upper}'),'BRANDING ${upper} EVENT','Synthetic local event','12:00','13:00','${upper} location',
          array[audit_syntb.id('${upper}_LANE_2')],array[audit_syntb.id('${upper}_INSTRUCTOR')]));`));
      expect(result).toMatchObject({ state: "00000", value: { ok: true, code: "created" } });
      await page.goto(fixture.app + `/t/synt-${side}/events`);
      await page.getByRole("button", { name: new RegExp(`BRANDING ${upper} EVENT`) }).click();
      await page.getByRole("button", { name: "Zapisz się", exact: true }).click();
      await expect(page.getByRole("dialog")).toContainText(`BRANDING ${upper} EVENT`);
      await noLegacyPresentation(page);
      const signup = page.waitForResponse(r => r.url().includes("/api/register-event"));
      await page.getByRole("dialog").getByRole("button", { name: "Zapisz się", exact: true }).click();
      expect(await (await signup).json()).toMatchObject({ ok: true, changed: true });
      await expect(page.getByRole("heading", { name: "Udało się zapisać na szkolenie", exact: true })).toBeVisible();
      await noLegacyPresentation(page);

      await page.goto(fixture.app + `/t/synt-${side}/events`);
      await page.getByLabel("Szukaj szkolenia", { exact: true }).fill("no-such-synthetic-event");
      await expect(page.getByText("Brak szkoleń pasujących do wyszukiwania.", { exact: true })).toBeVisible();
      await noLegacyPresentation(page);
      await page.goto(fixture.app + `/t/synt-${side}/my-events`);
      await page.getByLabel("Zakres", { exact: true }).selectOption("history");
      await page.getByLabel("Status", { exact: true }).selectOption("registered");
      await expect(page.getByText("Brak historycznych szkoleń o wybranym statusie.", { exact: true })).toBeVisible();
      await noLegacyPresentation(page);
      await page.route("**/rest/v1/rpc/get_public_event_list_v3", route => route.abort("connectionfailed"));
      await page.goto(fixture.app + `/t/synt-${side}/events`);
      await expect(page.getByRole("button", { name: "Spróbuj ponownie", exact: true })).toBeVisible();
      await noLegacyPresentation(page);
    } finally {
      cleanup();
    }
  });
}

test("extended CSK: legitimate tenant name, logo, contact and staff/instructor context", async ({ page }) => {
  sql(`insert into public.tenant_memberships(tenant_id,user_id,role,status)
    select t.id,audit_syntb.id(x.actor),x.role,'active' from public.tenants t
    cross join (values ('A_ADMIN','admin'),('A_INSTRUCTOR','instructor')) x(actor,role) where t.slug='csk'
    on conflict (tenant_id,user_id) do nothing;`);
  // Keep the last-admin invariant intact; these fixtures are removed by dropping the scratch DB.
  await page.goto(fixture.app + "/csk-krutla/kontakt");
  await expect(page.locator("main")).toContainText(/CSK|Krutla/);
  await expect(page.getByRole("img", { name: /Logo.*CSK.*Krutla/ })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Kontakt i lokalizacja", exact: true })).toBeVisible();
  await login(page, "a_admin");
  await page.goto(fixture.app + "/t/csk/admin");
  await expect(page.getByRole("navigation", { name: "Lokalizacja" })).toContainText(/CSK|Krutla/);
  await expect(page.getByTestId("admin-panel").locator("header")).toContainText("StrzelajTu.pl");
  await expect(page.getByTestId("admin-panel").locator("header")).not.toContainText(/CSK|Krutla/);
  await login(page, "a_instructor");
  await page.goto(fixture.app + "/t/csk/instructor/events");
  await expect(page.getByRole("navigation", { name: "Lokalizacja" })).toContainText(/CSK|Krutla/);
  await expect(page.locator("h1").first()).toBeVisible();
});
