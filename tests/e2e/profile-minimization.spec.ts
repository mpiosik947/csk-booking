import { randomUUID } from "node:crypto";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { createClient } from "@supabase/supabase-js";
import { expect, test, type Page } from "@playwright/test";

// Requires a disposable canonical replay with the existing synthetic A/B fixtures.
// The harness disables SMTP/Resend and supplies only loopback services.
const fixture = JSON.parse(readFileSync(process.env.LEGAL_3B_E2E_FIXTURE!, "utf8")) as {
  app: string; origin: string; password: string; anonKey: string; scratchDatabase: string;
};
for (const value of [fixture.app, fixture.origin]) {
  if (new URL(value).hostname !== "127.0.0.1") throw Error("Loopback fixture required");
}
if (!/^sbr3_[a-f0-9]{16}$/.test(fixture.scratchDatabase)) throw Error("Disposable DB required");

function sql(statement: string) {
  return execFileSync("docker", ["exec", "-i", "supabase_db_csk-booking", "psql", "-X", "-At",
    "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", fixture.scratchDatabase], {
    input: statement, encoding: "utf8", windowsHide: true,
  }).trim();
}
const quote = (value: string) => "'" + value.replaceAll("'", "''") + "'";
const columns = ["postal_code", "city", "street", "house_number", "apartment_number"] as const;
const inputs = ["account-postal-code", "account-city", "account-street", "account-house-number", "account-apartment-number"];
const fullAddress = ["00-001", "Testowo", "Testowa", "1A", "2"];

function setAddress(values: (string | null)[]) {
  sql(`update public.profiles set ${columns.map((key, index) => `${key}=${values[index] === null ? "null" : quote(values[index]!)}`).join(",")}
    where user_id=audit_syntb.id('CUSTOMER_A');`);
}
function address() {
  return JSON.parse(sql(`select jsonb_build_array(${columns.join(",")}) from public.profiles where user_id=audit_syntb.id('CUSTOMER_A');`));
}
async function login(page: Page, actor = "customer_a") {
  await page.goto(fixture.app + "/login?redirectTo=%2Fdashboard");
  await page.getByLabel("E-mail", { exact: true }).fill(actor + "@synthetic.invalid");
  await page.getByLabel("Hasło", { exact: true }).fill(fixture.password);
  await page.getByRole("button", { name: "Zaloguj się", exact: true }).click();
  await expect(page).toHaveURL(/\/dashboard$/);
}
async function save(page: Page) {
  const result = page.waitForResponse(r => r.url().includes("/rpc/update_my_profile_v2"));
  await page.getByRole("button", { name: "Zapisz dane", exact: true }).click();
  const response = await result;
  expect(response.ok()).toBe(true);
  expect(await response.json()).toMatchObject({ ok: true, declarations_changed: false });
  await expect(page.getByText("Dane zostały zapisane.", { exact: true })).toBeVisible();
}

test.beforeEach(async ({ context }) => {
  await context.route("**/*", route => new URL(route.request().url()).hostname === "127.0.0.1" ? route.continue() : route.abort());
});

for (const width of [320, 375, 1440]) {
  test(`registration adult declaration: keyboard, denial, real metadata and layout ${width}`, async ({ page }, info) => {
    const email = `legal3b-${randomUUID()}@synthetic.invalid`;
    try {
      await page.setViewportSize({ width, height: 1000 });
      await page.goto(fixture.app + "/register");
      const adult = page.getByRole("checkbox", { name: "Potwierdzam, że jestem osobą pełnoletnią. (wymagane)" });
      await expect(adult).not.toBeChecked();
      await expect(adult).toHaveAttribute("required", "");
      expect(await page.locator('input[type="date"]').count()).toBe(0);
      await page.getByLabel("Imię", { exact: true }).fill("Synthetic");
      await page.getByLabel("Nazwisko", { exact: true }).fill("Adult");
      await page.getByLabel("Telefon", { exact: true }).fill("500000000");
      await page.getByLabel("E-mail", { exact: true }).fill(email);
      await page.getByLabel("Hasło", { exact: true }).fill(fixture.password);
      await page.getByRole("checkbox", { name: /regulaminem serwisu/ }).check();
      await page.getByRole("checkbox", { name: /polityką prywatności/ }).check();
      let signupCalls = 0;
      page.on("request", r => { if (r.url().includes("/auth/v1/signup")) signupCalls++; });
      await page.getByRole("button", { name: "Utwórz konto", exact: true }).click();
      await expect(page.locator("main").getByRole("alert")).toHaveText("Potwierdź pełnoletność, aby utworzyć konto.");
      await expect(adult).toBeFocused();
      await expect(adult).toHaveAttribute("aria-invalid", "true");
      expect(signupCalls).toBe(0);
      // No hidden form value can replace the actual controlled checkbox state.
      await page.evaluate(() => {
        const input = document.createElement("input"); input.type = "hidden";
        input.name = "adult_self_declaration"; input.value = "true"; document.body.append(input);
      });
      await page.getByRole("button", { name: "Utwórz konto", exact: true }).click();
      expect(signupCalls).toBe(0);
      await adult.press("Space");
      await expect(adult).toBeChecked();
      expect(await adult.evaluate(el => getComputedStyle(el).boxShadow)).not.toBe("none");
      expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
      await page.screenshot({ path: info.outputPath(`adult-${width}.png`), fullPage: true });
      const signup = page.waitForResponse(r => r.url().includes("/auth/v1/signup"));
      await page.getByRole("button", { name: "Utwórz konto", exact: true }).click();
      const response = await signup;
      expect(response.ok()).toBe(true);
      await expect(page.getByRole("dialog")).toBeVisible();
      const metadata = JSON.parse(sql(`select raw_user_meta_data from auth.users where email=${quote(email)};`));
      expect(metadata.adult_self_declaration).toBe(true);
      expect(Number.isFinite(Date.parse(metadata.adult_self_declaration_at))).toBe(true);
      expect(metadata).toMatchObject({ accepted_terms: true, accepted_privacy: true });
      expect(Object.keys(metadata).some(k => /birth|dob|guardian|document_number/i.test(k))).toBe(false);
    } finally {
      sql(`delete from auth.users where email=${quote(email)};`);
      expect(sql(`select count(*) from auth.users where email=${quote(email)};`)).toBe("0");
    }
  });
}

for (const missing of columns.slice(0, 4)) {
  test(`existing profile saves without ${missing} and preserves other address data`, async ({ page }) => {
    setAddress(fullAddress);
    await login(page);
    await page.goto(fixture.app + "/account");
    await page.locator("#" + inputs[columns.indexOf(missing)]).fill("");
    await save(page);
    expect(address()).toEqual(fullAddress.map((v, i) => columns[i] === missing ? "" : v));
  });
}

for (const width of [320, 375, 1440]) {
  test(`empty address: profile save, dashboard completeness, export and layout ${width}`, async ({ page }, info) => {
    setAddress(columns.map(() => null));
    await page.setViewportSize({ width, height: 1000 });
    await login(page);
    await expect(page.getByText("Profil uzupełniony", { exact: true })).toBeVisible();
    await expect(page.getByRole("heading", { name: "Uzupełnij profil", exact: true })).toHaveCount(0);
    await page.goto(fixture.app + "/account");
    await expect(page.getByRole("heading", { name: "Adres — opcjonalnie" })).toBeVisible();
    for (const input of inputs) {
      await expect(page.locator("#" + input)).toHaveValue("");
      await expect(page.locator("#" + input)).not.toHaveAttribute("required");
    }
    await save(page);
    expect(address()).toEqual(["", "", "", "", null]);
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    await page.screenshot({ path: info.outputPath(`profile-${width}.png`), fullPage: true });
    const download = page.waitForEvent("download");
    await page.getByRole("button", { name: "Pobierz moje dane", exact: true }).click();
    const exported = JSON.parse(readFileSync((await (await download).path())!, "utf8"));
    expect(exported.export_version).toBe(3);
    for (const key of columns.slice(0, 4)) expect(exported.profile[key]).toBe("");
    expect(exported.profile.apartment_number).toBeNull();
  });
}

test("optional values and legacy postal text survive reload and unrelated edits; explicit clear works", async ({ page }) => {
  const legacy = ["SW1A 1AA", ...fullAddress.slice(1)];
  setAddress(legacy);
  await login(page);
  await page.goto(fixture.app + "/account");
  await expect(page.locator("#account-postal-code")).toHaveValue(legacy[0]);
  await page.locator("#account-phone").fill("500000001");
  await save(page);
  expect(address()).toEqual(legacy);
  await page.reload();
  for (let i = 0; i < inputs.length; i++) await page.locator("#" + inputs[i]).fill(fullAddress[i]);
  await save(page);
  expect(address()).toEqual(fullAddress);
  for (const input of inputs) await page.locator("#" + input).fill("");
  await save(page);
  expect(address()).toEqual(["", "", "", "", null]);
});

test("missing phone still denies save and no optional address payload is sent", async ({ page }) => {
  await login(page);
  await page.goto(fixture.app + "/account");
  await page.locator("#account-phone").fill("");
  let saves = 0;
  page.on("request", r => { if (r.url().includes("/rpc/update_my_profile_v2")) saves++; });
  await page.getByRole("button", { name: "Zapisz dane", exact: true }).click();
  await expect(page.getByText("Uzupełnij numer telefonu.", { exact: true })).toBeVisible();
  expect(saves).toBe(0);
});

test("grandfathered account without address or adult metadata can book and join an event through real APIs", async ({ page }) => {
  setAddress(columns.map(() => null));
  const auth = createClient(fixture.origin, fixture.anonKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data, error } = await auth.auth.signInWithPassword({ email: "customer_a@synthetic.invalid", password: fixture.password });
  expect(error).toBeNull();
  expect(data.user?.user_metadata.adult_self_declaration).toBeUndefined();
  const ids = JSON.parse(sql("select jsonb_object_agg(label,id) from audit_syntb.ids;"));
  const reservationDate = sql("select (current_date+32)::text;");
  const headers = { Authorization: "Bearer " + data.session!.access_token };
  let reservationId: string | undefined;
  let registrationId: string | undefined;
  try {
    const booking = await page.request.post(fixture.app + "/api/create-reservation?tenant=synt-a", {
      headers, data: { laneId: ids.A_LANE_2, reservationDate, startTime: "14:00", durationMinutes: 60, shootersCount: 1, creationRequestId: randomUUID() },
    });
    const bookingResult = await booking.json();
    reservationId = bookingResult.reservationId;
    expect(bookingResult).toMatchObject({ ok: true, code: "created" });
    const event = await page.request.post(fixture.app + "/api/register-event?tenant=synt-b", {
      headers, data: { eventId: ids.B_EVENT, asReserve: true },
    });
    const eventResult = await event.json();
    if (eventResult.changed) registrationId = eventResult.registrationId;
    expect(eventResult).toMatchObject({ ok: true });
    await login(page);
    for (const side of ["a", "b"]) {
      await page.goto(fixture.app + `/t/synt-${side}/booking`);
      await expect(page.getByRole("heading", { name: "Zarezerwuj oś", exact: true })).toBeVisible();
      await page.goto(fixture.app + `/t/synt-${side}/events`);
      await expect(page.getByRole("heading", { name: "Eventy i szkolenia", exact: true })).toBeVisible();
      await page.goto(fixture.app + `/t/synt-${side}/my-reservations`);
      await expect(page.getByRole("heading", { name: "Moje rezerwacje", exact: true })).toBeVisible();
      expect(await page.locator("body").innerText()).not.toContain((side === "a" ? "B" : "A") + "-LANE");
      await page.goto(fixture.app + `/t/synt-${side}/my-events`);
      expect(await page.locator("body").innerText()).not.toContain((side === "a" ? "B" : "A") + "_EVENT");
    }
  } finally {
    if (reservationId) sql(`delete from public.reservations where id=${quote(reservationId)}::uuid;`);
    if (registrationId) sql(`delete from public.event_registrations where id=${quote(registrationId)}::uuid;`);
    await auth.auth.signOut();
  }
});

for (const actor of ["customer_a", "a_admin", "b_admin", "pa"]) {
  test(`Platform Admin and A/B route boundaries remain unchanged: ${actor}`, async ({ page }) => {
    await login(page, actor);
    const pa = await page.goto(fixture.app + "/platform-admin");
    if (actor === "pa") {
      expect(pa?.status()).toBe(200);
      await expect(page.getByText("SYNT-A", { exact: true }).first()).toBeVisible();
      await expect(page.getByText("SYNT-B", { exact: true }).first()).toBeVisible();
    } else {
      expect(pa?.status()).toBe(404);
    }
    if (actor.endsWith("_admin")) {
      const own = actor[0], foreign = own === "a" ? "b" : "a";
      await page.goto(fixture.app + `/t/synt-${own}/admin/users`);
      await expect(page.getByRole("heading", { name: "Użytkownicy", exact: true })).toBeVisible();
      expect((await page.goto(fixture.app + `/t/synt-${foreign}/admin/users`))?.status()).toBe(404);
    }
  });
}
