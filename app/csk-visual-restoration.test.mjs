import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import ts from 'typescript';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';

const require = createRequire(import.meta.url);
const source = readFileSync(new URL('./_components/PublicTenantLanding.tsx', import.meta.url), 'utf8');
const compiled = { exports: {} };
const code = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, jsx: ts.JsxEmit.ReactJSX, esModuleInterop: true } }).outputText;
new Function('require', 'exports', code)(name => {
  if (name === 'next/link') return { __esModule: true, default: props => React.createElement('a', props) };
  if (name === 'next/image') return { __esModule: true, default: props => { const clean = { ...props }; delete clean.priority; delete clean.fill; return React.createElement('img', clean); } };
  if (name === '@/lib/platform-domain') return { PLATFORM_BASE_URL: 'https://strzelajtu.pl' };
  return require(name);
}, compiled.exports);
const flags = ['showBooking', 'showEvents', 'showInstructor', 'showPricing', 'showAbout', 'showRegulations', 'showContact'];
const tenant = { tenantSlug: 'test-range', publicSlug: 'public-range', name: 'Test Range', city: 'City', logoPath: '/logo.png', description: 'Public description', regulationsPath: '/terms', socialLinks: {}, ...Object.fromEntries(flags.map(f => [f, true])) };
const render = (data = tenant, props = {}) => renderToStaticMarkup(React.createElement(compiled.exports.PublicTenantLanding, { tenant: data, ...props }));

test('all 128 visibility combinations omit unavailable UI without empty information section', () => {
  const targets = ['Zarezerwuj termin', 'Szkolenia i eventy', 'Strzelanie z instruktorem', 'Cennik', 'O obiekcie', 'Regulamin', 'Kontakt i lokalizacja'];
  for (let mask = 0; mask < 128; mask++) {
    const html = render({ ...tenant, ...Object.fromEntries(flags.map((f, i) => [f, !!(mask & (1 << i))])) });
    targets.forEach((text, i) => assert.equal(html.includes(text), !!(mask & (1 << i)), `${mask}: ${text}`));
    assert.equal(html.includes('Informacje o obiekcie'), !!(mask & 124));
  }
});
test('canonical and custom domain links retain public selectors and platform operational origin', () => {
  const normal = render(); const custom = render(tenant, { customDomain: true });
  for (const suffix of ['booking', 'events']) {
    assert.ok(normal.includes(`href="/t/test-range/${suffix}"`));
    assert.ok(custom.includes(`href="https://strzelajtu.pl/t/test-range/${suffix}"`));
  }
  for (const suffix of ['cennik', 'o-obiekcie', 'kontakt']) {
    assert.ok(normal.includes(`href="/public-range/${suffix}"`));
    assert.ok(custom.includes(`href="/${suffix}"`));
  }
  assert.ok(custom.includes('href="https://strzelajtu.pl/login"'));
});
test('preview remains inert and has no clickable links', () => {
  const html = render(tenant, { preview: true });
  assert.match(html, /inert=""/);
  assert.doesNotMatch(html, /<a\s/);
});
test('tenant style boundary is independent of platform theme and guards remain intact', () => {
  const shell = readFileSync(new URL('./t/[slug]/layout.tsx', import.meta.url), 'utf8');
  assert.match(shell, /min-h-screen w-full flex-1 bg-\[#090b09\]/);
  assert.match(shell, /if \(!context.ok\) notFound\(\)/);
  assert.doesNotMatch(source + shell, /platform-ui|PlatformBrand/);
  assert.match(source, /max-w-\[880px\]/);
  assert.match(source, /max-w-\[360px\]/);
  assert.match(source, /h-\[72px\]/);
});
