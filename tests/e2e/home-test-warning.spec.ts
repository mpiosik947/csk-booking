import { expect, test } from "@playwright/test";

test.describe("PRODUCT-10A public platform home", () => {
  for (const width of [320, 375, 430, 768, 1440]) {
    test(`directory stays usable without horizontal overflow at ${width}px`, async ({ page }) => {
      await page.setViewportSize({ width, height: width < 768 ? 900 : 1000 });
      await page.goto("/");

      await expect(page.getByRole("heading", {
        name: "Znajdź strzelnicę i zarezerwuj termin online",
      })).toBeVisible();
      await expect(page.getByRole("searchbox", {
        name: "Wyszukaj strzelnicę lub miejscowość",
      })).toBeVisible();
      await expect(page.getByRole("button", { name: "Znajdź strzelnicę" })).toBeVisible();

      const overflow = await page.evaluate(
        () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
      );
      expect(overflow).toBeLessThanOrEqual(1);
    });
  }

  test("search filters by city and a directory card reaches the tenant landing", async ({ page }) => {
    await page.goto("/");
    await page.getByRole("searchbox", {
      name: "Wyszukaj strzelnicę lub miejscowość",
    }).fill("Wolsztyn");
    await page.getByRole("button", { name: "Znajdź strzelnicę" }).click();

    await expect(page).toHaveURL(/\?q=Wolsztyn$/u);
    const card = page.getByRole("link", {
      name: /CSK — Centrum Szkolenia Krutla/u,
    });
    await expect(card).toContainText("Wolsztyn");
    await card.click();
    await expect(page).toHaveURL(/\/t\/csk$/u);
    await expect(page.getByRole("heading", { name: "CSK" })).toBeVisible();
  });

  test("unknown search has a contextual empty state", async ({ page }) => {
    await page.goto("/?q=nieistniejaca-lokalizacja");
    await expect(page.getByText(
      "Nie znaleźliśmy strzelnicy pasującej do wyszukiwania.",
    )).toBeVisible();
  });
});
