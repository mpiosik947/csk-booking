import { test, expect } from "@playwright/test";
import path from "node:path";

const shots = path.resolve("test-results/platform-branding-review");
for (const width of [375, 430, 768, 1024, 1440]) {
  test("platform branding and no overflow " + width, async ({ page }) => {
    await page.setViewportSize({ width, height: 1000 });
    for (const route of ["/", "/login", "/register", "/reset-password", "/account"]) {
      const response = await page.goto(route);
      expect(response?.status()).toBeLessThan(500);
      await expect(page.getByRole("img", { name: "StrzelajTu.pl", exact: true }).first()).toBeVisible();
      // Tenant logos in directory result cards are public tenant data, not platform identity.
      if (route !== "/") expect(await page.locator('img[src*="login-brand"]').count()).toBe(0);
      expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
      await expect(page).toHaveTitle(/StrzelajTu.pl/);
      if (route === "/") {
        const header = page.locator("header");
        await expect(header.getByRole("img", { name: "StrzelajTu.pl", exact: true })).toHaveAttribute("src", /logo-horizontal/);
        await expect(header.getByRole("link", { name: "Zaloguj się", exact: true })).toBeVisible();
        await expect(header.getByRole("link", { name: "Załóż konto", exact: true })).toBeVisible();
        expect(await page.locator("h1").evaluate(el => parseFloat(getComputedStyle(el).fontSize))).toBe(width < 640 ? 26 : 42);
        await expect(page.locator("#tenant-search")).toHaveAttribute("placeholder", width < 640 ? "Szukaj strzelnicy lub miasta" : "Wyszukaj strzelnicę lub miejscowość");
        if (width < 640) {
          const name = page.locator('li a[href="/csk-krutla"] > span:nth-child(2) > span:first-child');
          await expect(name).toBeVisible();
          expect(await name.evaluate(el => el.getBoundingClientRect().height / parseFloat(getComputedStyle(el).lineHeight))).toBeLessThanOrEqual(3);
          await expect(page.locator('footer [aria-hidden="true"]')).toBeHidden();
        }
      }
      if (route === "/account") await expect(page.getByText("Ładowanie konta...", { exact: true })).toHaveCount(0);
      if ((width === 430 && route === "/") || (width === 375 && ["/", "/login"].includes(route)) || (width === 1440)) {
        await page.screenshot({ path: path.join(shots, (route === "/" ? "homepage" : route.slice(1)) + "-" + width + ".png"), fullPage: true });
      }
    }
  });
}
test("tenant return context remains on platform auth", async ({ page }) => {
  await page.goto("/login?redirectTo=%2Ft%2Fcsk%2Fbooking");
  await expect(page.getByRole("heading", { name: "Zaloguj się do konta" })).toBeVisible();
  await expect(page.getByRole("img", { name: "StrzelajTu.pl", exact: true })).toBeVisible();
  expect(new URL(page.url()).searchParams.get("redirectTo")).toBe("/t/csk/booking");
  await page.getByLabel("E-mail", { exact: true }).focus();
  await expect(page.getByLabel("E-mail", { exact: true })).toBeFocused();
});
test("CSK tenant landing preserves tenant branding", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 1000 });
  const response = await page.goto("/csk-krutla");
  expect(response?.status()).toBe(200);
  await expect(page.getByRole("heading", { name: /INFORMACJE/i })).toBeVisible();
  expect(await page.locator(".platform-ui").count()).toBe(0);
  await page.screenshot({ path: path.join(shots, "csk-landing-1440.png"), fullPage: true });
});
test("platform admin without session retains guard and platform login UI", async ({ page }) => {
  await page.goto("/platform-admin");
  await expect(page).toHaveURL(/\/login\?redirectTo=/);
  await expect(page.getByRole("img", { name: "StrzelajTu.pl", exact: true })).toBeVisible();
});
