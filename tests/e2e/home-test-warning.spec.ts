import { expect, test } from "@playwright/test";

test.describe("V1.1-04 home test-mode warning", () => {
  for (const width of [320, 375, 430, 768, 1440]) {
    test(`warning and primary CTA remain usable at ${width}px`, async ({ page }) => {
      await page.setViewportSize({ width, height: width < 768 ? 900 : 1000 });
      await page.goto("/");

      const warning = page.getByRole("region", {
        name: "UWAGA — SYSTEM W WERSJI TESTOWEJ",
      });
      await expect(warning).toBeVisible();
      await expect(
        page.getByRole("heading", { name: "UWAGA — SYSTEM W WERSJI TESTOWEJ" })
      ).toBeVisible();
      await expect(warning).toContainText("nie są wiążące");
      await expect(page.getByRole("link", { name: /Zarezerwuj termin/u })).toBeVisible();
      await expect(page.getByRole("link", { name: /Szkolenia i eventy/u })).toBeVisible();

      const overflow = await page.evaluate(
        () => document.documentElement.scrollWidth - document.documentElement.clientWidth
      );
      expect(overflow).toBeLessThanOrEqual(1);
    });
  }

  test("primary CTA destinations remain unchanged", async ({ page }) => {
    await page.goto("/");
    await expect(page.getByRole("link", { name: /Zarezerwuj termin/u })).toHaveAttribute(
      "href",
      "/booking"
    );
    await expect(page.getByRole("link", { name: /Szkolenia i eventy/u })).toHaveAttribute(
      "href",
      "/events"
    );
  });
});
