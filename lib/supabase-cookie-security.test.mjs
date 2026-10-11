import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import ts from 'typescript';
import { createStorageFromOptions, applyServerStorage } from '@supabase/ssr/dist/main/cookies.js';

const writers = [
  ['lib/supabase.ts', 'createBrowserClient'],
  ['lib/server/tenant-route-context.ts', 'createServerClient'],
  ['middleware.ts', 'createServerClient'],
  ['app/auth/callback/route.ts', 'createServerClient'],
  ['lib/server/recovery-http.ts', 'createServerClient'],
];

// Exercise the installed SDK with the configuration actually passed by each writer.
// SDK internals are used only by this test to inspect chunk writes without real tokens.
for (const [file, factory] of writers) {
  test(`${file}: Secure on every chunk, replacement, PKCE and deletion`, async () => {
    const source = ts.createSourceFile(file, readFileSync(file, 'utf8'), ts.ScriptTarget.Latest, true);
    const calls = [];
    function visit(node) {
      if (ts.isCallExpression(node) && node.expression.getText(source) === factory) calls.push(node);
      ts.forEachChild(node, visit);
    }
    visit(source);
    assert.equal(calls.length, 1);
    const config = calls[0].arguments[2];
    assert.ok(ts.isObjectLiteralExpression(config));
    const policy = config.properties.find(p => p.name?.getText(source) === 'cookieOptions')?.initializer;
    assert.ok(policy && ts.isObjectLiteralExpression(policy));
    // No implicit environment/header downgrade or unrelated attribute changes.
    assert.equal(policy.properties.length, 1);
    assert.equal(policy.properties[0].name.getText(source), 'secure');
    assert.equal(policy.properties[0].initializer.kind, ts.SyntaxKind.TrueKeyword);
    const cookieOptions = { secure: true };
    const jar = new Map(), writes = [];
    const options = { cookieOptions, cookieEncoding: 'base64url', cookies: {
      getAll: () => [...jar].map(([name, value]) => ({ name, value })),
      setAll: values => { for (const c of values) {
        writes.push(c);
        if (c.options.maxAge === 0) jar.delete(c.name); else jar.set(c.name, c.value);
      } },
    } };
    const server = factory === 'createServerClient';
    const store = createStorageFromOptions(options, server);
    const flush = async () => {
      if (!server) return;
      await applyServerStorage(store, options);
      for (const key of Object.keys(store.setItems)) delete store.setItems[key];
      for (const key of Object.keys(store.removedItems)) delete store.removedItems[key];
    };
    const name = 'sb-synthetic-auth-token';
    const large = JSON.stringify({ synthetic: 'x'.repeat(10000) });
    await store.storage.setItem(name, large); await flush();
    assert.ok(jar.size > 2, 'must exercise multiple chunks');
    assert.equal(await store.storage.getItem(name), large);
    await store.storage.setItem(name, JSON.stringify({ synthetic: 'short' })); await flush();
    assert.deepEqual([...jar.keys()], [name], 'obsolete chunks removed when session shrinks');
    await store.storage.setItem(name + '-code-verifier', JSON.stringify('synthetic-verifier')); await flush();
    await store.storage.removeItem(name); await store.storage.removeItem(name + '-code-verifier'); await flush();
    assert.equal(jar.size, 0);
    assert.ok(writes.some(c => c.options.maxAge === 0));
    for (const { options: flags } of writes) {
      assert.equal(flags.secure, true);
      assert.equal(flags.path, '/');
      assert.equal(flags.sameSite, 'lax');
      assert.equal(flags.httpOnly, false);
      assert.equal(flags.domain, undefined);
      assert.ok([0, 400 * 86400].includes(flags.maxAge));
    }
  });
}
