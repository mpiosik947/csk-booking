import assert from 'node:assert/strict';
import test from 'node:test';
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import ts from 'typescript';
import { renderAdminVisual } from '../tests/fixtures/admin-visual-render.mjs';

const files = ['app/admin/_components/AdminShell.tsx', 'app/admin/calendar/_components/CalendarToolbar.tsx',
  'app/admin/calendar/_components/DayCalendar.tsx', 'app/admin/events/page.tsx', 'app/admin/lane-blocks/page.tsx'];
function withoutPresentation(source) {
  const tree = ts.createSourceFile('component.tsx', source.replace(/\r\n/g, '\n'), ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
  const result = ts.transform(tree, [context => node => {
    const visit = n => ts.isJsxAttribute(n) && ['className', 'data-testid'].includes(n.name.getText())
      ? undefined : ts.visitEachChild(n, visit, context);
    return ts.visitNode(node, visit);
  }]);
  const text = ts.createPrinter().printFile(result.transformed[0]); result.dispose(); return text;
}
for (const file of files) test(`${file}: only presentation attributes changed`, () => {
  const baseline = execFileSync('git', ['show', `HEAD:${file}`], { encoding: 'utf8' });
  assert.equal(withoutPresentation(readFileSync(file, 'utf8')), withoutPresentation(baseline));
});
for (const moduleName of ['dashboard','calendar','reservations','events','lane-blocks','settings']) {
  test(`${moduleName}: real component renders without DB or auth access`, () => {
    const html = renderAdminVisual(moduleName);
    assert.match(html, /data-testid="admin-panel"/);
    assert.doesNotMatch(html, /platform-ui/);
    if (moduleName === 'calendar') assert.match(html, /scrollbar-color:#536143_#111511/);
    if (moduleName === 'settings') assert.match(html, /Nazwa publiczna/);
    if (moduleName === 'events') assert.match(html, /Nowe wydarzenie/);
  });
}
