// Presentation-only fixtures: real components, synthetic state, no effects or DB access.
import { readFileSync, existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { createRequire } from 'node:module';
import ts from 'typescript';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';

const require = createRequire(import.meta.url);
const root = resolve(import.meta.dirname, '../..');
const settings = {
  display_name: 'CSK — Centrum Szkolenia Krutla', city: 'Wolsztyn',
  logo_path: '/logo.png', hero_image_path: null, description: 'Opis demonstracyjny obiektu.',
  regulations_path: null, public_address: null, public_phone: null, public_email: null,
  opening_hours: null, social_links: {}, about_offer: null, about_audience: null,
  public_map_url: null, pricing_items: [], updated_at: '2026-09-26T12:00:00Z',
  feature_access: { booking: true, events: true, instructors: true },
  ...Object.fromEntries(['booking','pricing','instructor','events','about','contact','regulations'].map(k => [`show_${k}`, true])),
};
const state = { loading: false, role: 'admin', userRole: 'admin', settings,
  features: new Set(['booking','events','instructors','staff','checkin','reports','lane_blocks','advanced_calendar']),
};
const cache = new Map();
function load(path) {
  path = resolve(path);
  if (cache.has(path)) return cache.get(path);
  const source = readFileSync(path, 'utf8');
  const code = ts.transpileModule(source, {
    compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS, jsx: ts.JsxEmit.ReactJSX, esModuleInterop: true },
    transformers: { before: [context => node => {
      const visit = n => {
        if (ts.isVariableDeclaration(n) && ts.isArrayBindingPattern(n.name) && n.initializer &&
            ts.isCallExpression(n.initializer) && n.initializer.expression.getText() === 'useState') {
          const key = n.name.elements[0].name.getText();
          if (Object.hasOwn(state, key)) return ts.factory.updateVariableDeclaration(n, n.name, n.exclamationToken, n.type,
            ts.factory.updateCallExpression(n.initializer, n.initializer.expression, n.initializer.typeArguments,
              [ts.factory.createElementAccessExpression(ts.factory.createIdentifier('__fixtureState'), ts.factory.createStringLiteral(key))]));
        }
        return ts.visitEachChild(n, visit, context);
      };
      return ts.visitNode(node, visit);
    }] },
  }).outputText;
  const compiled = { exports: {} };
  cache.set(path, compiled.exports);
  new Function('require', 'exports', 'module', '__fixtureState', code)(name => {
    if (name === 'next/link') return { __esModule: true, default: props => React.createElement('a', props) };
    if (name.endsWith('/supabase')) return { supabase: new Proxy({}, { get() { throw new Error('DB access forbidden in visual fixture'); } }) };
    if (name.startsWith('.') || name.startsWith('@/')) {
      const base = name.startsWith('@/') ? resolve(root, name.slice(2)) : resolve(dirname(path), name);
      const target = [base, `${base}.ts`, `${base}.tsx`, `${base}.js`].find(p => existsSync(p));
      if (!target) throw new Error(`Unresolved fixture import: ${name}`);
      return load(target);
    }
    return require(name);
  }, compiled.exports, compiled, state);
  return compiled.exports;
}

export function renderAdminVisual(moduleName) {
  const props = { tenantId: 'visual-fixture-only', tenantSlug: 'csk' };
  let content;
  if (moduleName === 'calendar') {
    const Shell = load(resolve(root, 'app/admin/_components/AdminShell.tsx')).default;
    const Toolbar = load(resolve(root, 'app/admin/calendar/_components/CalendarToolbar.tsx')).default;
    const Day = load(resolve(root, 'app/admin/calendar/_components/DayCalendar.tsx')).default;
    const lanes = ['Oś 25 m', 'Oś 50 m — długa nazwa zasobu do testu responsywności'].map((name, i) => ({
      id: `lane-${i}`, name, displayName: name, parentName: null, isActive: true,
      isHistoricalOnly: false, displayOrder: i, bookingStepMinutes: 60,
      resourceKind: 'lane', parentLaneId: null, depth: 0, isParent: false, isPosition: false,
    }));
    const noop = () => {};
    content = React.createElement(Shell, { eyebrow: 'Administracja', title: 'Kalendarz', description: 'Widok harmonogramu osi i wydarzeń.' },
      React.createElement(Toolbar, { date: '2026-09-26', view: 'day', periodLabel: '26 września 2026', laneId: 'all', lanes,
        types: ['reservation','event','lane_block'], includeHistoricalStatuses: false,
        ...Object.fromEntries(['onDateChange','onViewChange','onPreviousDay','onNextDay','onToday','onLaneChange','onTypeToggle','onHistoricalStatusesChange'].map(k => [k, noop])),
      }), React.createElement(Day, { lanes, entries: [], openingStart: '08:00', openingEnd: '20:00', onSelectEntry: noop }));
  } else {
    const paths = { dashboard: 'page.tsx', reservations: 'reservations/page.tsx', events: 'events/page.tsx', 'lane-blocks': 'lane-blocks/page.tsx', settings: 'settings/TenantAdminSettings.tsx' };
    content = React.createElement(load(resolve(root, 'app/admin', paths[moduleName])).default, props);
  }
  // Match the unchanged tenant layout's real class names, not a replacement shell.
  const layout = readFileSync(resolve(root, 'app/t/[slug]/layout.tsx'), 'utf8');
  const outer = layout.match(/data-testid="tenant-shell" className="([^"]+)"/)[1];
  const inner = layout.match(/className="(mx-auto w-full max-w-5xl[^"]+)"/)[1];
  return renderToStaticMarkup(React.createElement('div', { 'data-testid': 'tenant-shell', className: outer },
    React.createElement('div', { className: inner },
      React.createElement('nav', { className: 'mb-8 flex flex-wrap items-center gap-3 text-sm' }, 'StrzelajTu.pl / CSK — Centrum Szkolenia Krutla'), content)));
}
