import { test, expect } from '@playwright/test';
import { readFileSync, readdirSync } from 'node:fs';
import { resolve } from 'node:path';
import { execFileSync } from 'node:child_process';
// Run native ESM separately from Playwright's TS/CommonJS transform.
const modules = ['dashboard', 'calendar', 'reservations', 'events', 'lane-blocks', 'settings'];
const markup: Record<string, string> = JSON.parse(execFileSync(process.execPath, ['--input-type=module', '-e',
  `import { renderAdminVisual } from './tests/fixtures/admin-visual-render.mjs'; console.log(JSON.stringify(Object.fromEntries(${JSON.stringify(modules)}.map(name => [name, renderAdminVisual(name)]))));`,
], { encoding: 'utf8', maxBuffer: 5 * 1024 * 1024 }));

const cssRoot = resolve('.next/static/css');
const css = readdirSync(cssRoot, { recursive: true }).filter(p => String(p).endsWith('.css'))
  .map(p => readFileSync(resolve(cssRoot, String(p)), 'utf8')).join('\n');
for (const width of [375, 430, 768, 1024, 1440]) {
  for (const moduleName of ['dashboard', 'calendar', 'reservations', 'events', 'lane-blocks', 'settings']) {
    test(`${moduleName} ${width}: real rendered layout`, async ({ page }, info) => {
      await page.setViewportSize({ width, height: 1000 });
      // This is a component visual test, NOT an authenticated production E2E claim.
      await page.route('**/*', route => route.abort());
      await page.setContent(`<html><head><style>${css}</style></head><body>${markup[moduleName]}</body></html>`);
      const panel = page.getByTestId('admin-panel');
      const box = await panel.boundingBox();
      expect(box).not.toBeNull();
      if (width < 640) {
        expect(box!.width).toBeGreaterThanOrEqual(width - 34);
        expect(box!.x).toBeGreaterThanOrEqual(12);
        expect(box!.x).toBeLessThanOrEqual(16);
      }
      expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(width);
      const shellStyle = await panel.evaluate(el => {
        const style = getComputedStyle(el);
        return { background: style.backgroundColor, radius: style.borderRadius, padding: style.paddingLeft };
      });
      expect(shellStyle).toEqual({ background: 'rgb(20, 24, 20)', radius: '32px', padding: width < 640 ? '12px' : '32px' });
      if (moduleName === 'dashboard') console.log(JSON.stringify({ viewport: width, panelWidth: box!.width, margin: box!.x }));
      const overflow = await panel.locator('input, select, textarea').evaluateAll(elements => elements.filter(el => {
        const rect = el.getBoundingClientRect();
        const parent = el.parentElement!.getBoundingClientRect();
        return rect.width > 0 && (rect.right > parent.right + 1 || rect.width > parent.width + 1);
      }).map(el => ({ tag: el.tagName, name: el.getAttribute('name'), type: el.getAttribute('type') })));
      expect(overflow).toEqual([]);
      if (moduleName === 'calendar') {
        const toolbar = page.getByRole('region', { name: 'Sterowanie kalendarzem' });
        const bounds = (await toolbar.boundingBox())!;
        for (const field of await toolbar.locator('input[type=date], select').all()) {
          const fieldBox = (await field.boundingBox())!;
          expect(fieldBox.x + fieldBox.width).toBeLessThanOrEqual(bounds.x + bounds.width);
        }
        expect(await page.locator('[class*="scrollbar-color"]').first().evaluate(el => getComputedStyle(el).scrollbarColor))
          .toBe('rgb(83, 97, 67) rgb(17, 21, 17)');
      }
      await info.attach('measurements', { body: JSON.stringify({ moduleName, viewport: width, panel: box }), contentType: 'application/json' });
      await page.screenshot({ path: info.outputPath(`${moduleName}-${width}-viewport.png`), fullPage: false });
      await page.screenshot({ path: info.outputPath(`${moduleName}-${width}.png`), fullPage: true });
    });
  }
}
