import { expect, test } from '@playwright/test';

for (const colorScheme of ['light', 'dark'] as const) {
  for (const width of [375, 430, 768, 1024, 1440]) {
    test(`CSK restoration ${width} ${colorScheme}`, async ({ page }, info) => {
      await page.emulateMedia({ colorScheme });
      await page.setViewportSize({ width, height: 1100 });
      expect((await page.goto('/csk-krutla'))?.status()).toBe(200);
      const panel = page.getByTestId('tenant-landing-panel');
      await expect(panel).toBeVisible();
      await expect(page.getByTestId('tenant-landing')).toHaveCSS('background-color', 'rgb(9, 11, 9)');
      await expect(page.locator('.platform-ui')).toHaveCount(0);
      const box = (await panel.boundingBox())!;
      const logo = (await page.getByTestId('tenant-logo').boundingBox())!;
      const ctas = page.getByTestId('tenant-main-ctas').locator('a');
      const a = (await ctas.nth(0).boundingBox())!;
      const b = (await ctas.nth(1).boundingBox())!;
      if (width === 1440) {
        expect(box.width).toBeCloseTo(880, 0);
        expect(logo.width).toBeCloseTo(360, 0);
        expect(a.width).toBeGreaterThan(390); expect(a.width).toBeLessThan(396);
        expect(a.height).toBeCloseTo(128, 0);
      }
      if (width < 768) { expect(b.y).toBeGreaterThan(a.y + a.height); expect(a.width).toBeGreaterThan(box.width - 50); }
      else { expect(a.y).toBeCloseTo(b.y, 0); }
      for (const row of await page.getByTestId('information-row').all()) expect((await row.boundingBox())!.height).toBeCloseTo(72, 0);
      expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
      await info.attach('measurements', { body: JSON.stringify({ width, colorScheme, panel: box, logo, cta1: a, cta2: b }), contentType: 'application/json' });
      await page.screenshot({ path: info.outputPath(`landing-${width}-${colorScheme}.png`), fullPage: true });
      await page.goto('/t/csk/events');
      const shell = page.getByTestId('tenant-shell');
      await expect(shell).toHaveCSS('background-color', 'rgb(9, 11, 9)');
      const shellBox = (await shell.boundingBox())!;
      expect(shellBox.x).toBe(0); expect(shellBox.width).toBeGreaterThanOrEqual(width - 20);
      expect(shellBox.height).toBeGreaterThanOrEqual(1100);
    });
  }
}
test('TCM public subpages retain dark branding and tenant navigation', async ({ page }, info) => {
  await page.setViewportSize({ width: 1440, height: 1000 });
  await page.emulateMedia({ colorScheme: 'light' });
  for (const [suffix, title] of [['cennik', 'Cennik'], ['o-obiekcie', 'O obiekcie'], ['kontakt', 'Kontakt i lokalizacja']]) {
    await page.goto('/csk-krutla');
    await page.getByRole('link', { name: new RegExp(`^${title}`) }).click();
    await expect(page).toHaveURL(new RegExp(`/csk-krutla/${suffix}$`));
    await expect(page.getByRole('heading', { name: title, exact: true })).toBeVisible();
    await expect(page.locator('main').first()).toHaveCSS('background-color', 'rgb(9, 11, 9)');
    await page.screenshot({ path: info.outputPath(`${suffix}.png`), fullPage: true });
  }
});
