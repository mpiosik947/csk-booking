import { expect, test } from "@playwright/test";

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

test("new paths do not substitute old business views or staff authority", async ({ page }) => {
  await page.goto("/t/csk/booking");
  await expect(page.getByText(/nie został jeszcze przełączony na tenantowy kontrakt/)).toBeVisible();
  await expect(page.getByRole("link", { name: "Otwórz obecny widok CSK" })).toHaveAttribute("href", "/booking");

  await page.goto("/t/csk/admin/users");
  await expect(page).toHaveURL(/\/login\?redirectTo=%2Ft%2Fcsk%2Fadmin%2Fusers$/);
  await page.goto("/booking");
  await expect(page).not.toHaveURL(/\/t\//);
});
