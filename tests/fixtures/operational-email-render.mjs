import assert from 'node:assert/strict';
import { operationalEmailLayout } from '../../lib/server/operational-email-layout.ts';

// Evaluate only the presentation expression in a checked-in renderer, with
// synthetic bindings. Never import a route, DB client or provider SDK.
export function renderEmailExpression(source, name, values) {
  const expression = name === 'html'
    ? source.match(/const html = (operationalEmailLayout\([\s\S]*?\n\s*\}\));/)?.[1]
    : source.match(new RegExp('const ' + name + ' = (`[\\s\\S]*?`);'))?.[1];
  assert.ok(expression, `${name} presentation expression exists`);
  const bindings = { ...values, operationalEmailLayout };
  return Function(...Object.keys(bindings), 'return ' + expression)(...Object.values(bindings));
}
