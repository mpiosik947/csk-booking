import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import ts from 'typescript';
import { createRequire } from 'node:module';
import * as context from './recovery-context.ts';
import { NextResponse } from 'next/server.js';
const require = createRequire(import.meta.url);

function load(path, client) {
  const output = ts.transpileModule(fs.readFileSync(new URL(path, import.meta.url), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 },
  }).outputText;
  const compiled = { exports: {} };
  const resolver = name => {
    if (name.endsWith('recovery-context')) return context;
    if (name.endsWith('recovery-grant-mint')) return { recoveryGrantMinter: () => async () => context.newRecoveryGrant() };
    if (name.endsWith('password-policy')) return { getPasswordLengthError: () => null };
    if (name.endsWith('recovery-http')) return {
      recoveryOrigin: () => 'https://strzelajtu.pl', protectResponse: r => r,
      clearRecovery: r => r.cookies.set(context.RECOVERY_COOKIE, '', { path: '/auth', maxAge: 0 }),
      recoveryCookieOptions: () => ({ path: '/auth', httpOnly: true }),
      recoveryClient: () => client,
    };
    if (name === 'next/server') return { NextResponse };
    return require(name);
  };
  new Function('require', 'module', 'exports', output)(resolver, compiled, compiled.exports);
  return compiled.exports;
}

function token(method = 'recovery') {
  return 'synthetic.' + Buffer.from(JSON.stringify({ sub: 'u', session_id: 's', amr: [{ method }] })).toString('base64url') + '.synthetic';
}

test('legacy exchanges once and requires server recovery AMR, not writable SDK redirectType', async () => {
  for (const method of ['recovery', 'password', 'otp']) {
    let exchanges = 0;
    const route = load('../../app/auth/recovery/legacy/route.ts', { auth: {
      exchangeCodeForSession: async () => { exchanges++; return { data: { session: { access_token: token(method) }, user: { id: 'u' }, redirectType: 'recovery' }, error: null }; },
    } });
    const result = await route.GET({ nextUrl: new URL('https://strzelajtu.pl/reset-password?code=synthetic') });
    assert.equal(exchanges, 1);
    assert.equal(result.headers.get('location'), 'https://strzelajtu.pl/reset-password' + (method === 'recovery' ? '' : '?recoveryError=1'));
  }
});

test('signOut failure is explicit and captured grant replay denied with a still-valid session', async () => {
  let updates = 0;
  let consumed = false;
  const receipt = context.newRecoveryGrant();
  const route = load('../../app/auth/recovery/route.ts', {
    rpc: async (name) => { assert.equal(name, 'consume_recovery_grant_v1'); const won = !consumed; consumed = true; return { data: won, error: null }; },
    auth: {
    getSession: async () => ({ data: { session: { access_token: token() } } }),
    getUser: async () => ({ data: { user: { id: 'u' } }, error: null }),
    updateUser: async () => { updates++; return { error: null }; },
    signOut: async () => ({ error: { message: 'Synthetic transport error' } }),
  } });
  const request = { headers: new Headers({ origin: 'https://strzelajtu.pl', 'content-type': 'application/json' }),
    cookies: { get: () => ({ value: receipt }) }, text: async () => JSON.stringify({ password: 'Valid-Synthetic-Password-123' }) };
  const response = await route.POST(request);
  assert.equal(response.status, 503);
  assert.equal((await response.json()).status, 'password_changed_session_cleanup_failed');
  assert.equal(response.cookies.get(context.RECOVERY_COOKIE).maxAge, 0);
  assert.equal((await route.POST(request)).status, 403);
  assert.equal(updates, 1);
});

test('mutation failure and thrown mutation burn grant and require a fresh link', async () => {
  for (const throws of [false, true]) {
    let consumed = false, updates = 0;
    const route = load('../../app/auth/recovery/route.ts', {
      rpc: async () => { const won = !consumed; consumed = true; return { data: won, error: null }; },
      auth: {
        getSession: async () => ({ data: { session: { access_token: token() } } }),
        getUser: async () => ({ data: { user: { id: 'u' } }, error: null }),
        updateUser: async () => { updates++; if (throws) throw Error('synthetic'); return { error: {} }; },
      },
    });
    const request = { headers: new Headers({ origin: 'https://strzelajtu.pl', 'content-type': 'application/json' }), cookies: { get: () => ({ value: context.newRecoveryGrant() }) }, text: async () => JSON.stringify({ password: 'Valid-Synthetic-Password-123' }) };
    const result = await route.POST(request);
    assert.equal((await result.json()).status, 'fresh_recovery_link_required');
    assert.equal(result.cookies.get(context.RECOVERY_COOKIE).maxAge, 0);
    assert.equal((await route.POST(request)).status, 403);
    assert.equal(updates, 1);
  }
});

test('parallel handler submits call password mutation exactly once', async () => {
  let consumed = false, updates = 0;
  const route = load('../../app/auth/recovery/route.ts', {
    rpc: async () => { const won = !consumed; consumed = true; return { data: won, error: null }; },
    auth: {
      getSession: async () => ({ data: { session: { access_token: token() } } }),
      getUser: async () => ({ data: { user: { id: 'u' } }, error: null }),
      updateUser: async () => { updates++; return { error: null }; },
      signOut: async () => ({ error: null }),
    },
  });
  const raw = context.newRecoveryGrant();
  const request = { headers: new Headers({ origin: 'https://strzelajtu.pl', 'content-type': 'application/json' }), cookies: { get: () => ({ value: raw }) }, text: async () => JSON.stringify({ password: 'Valid-Synthetic-Password-123' }) };
  const responses = await Promise.all([route.POST(request), route.POST(request)]);
  assert.deepEqual(responses.map(r => r.status).sort(), [200, 403]);
  assert.equal(updates, 1);
});

test('same_password is allowlisted after consume; grant stays burned and captured-cookie retry denies', async () => {
  let consumed = false, updates = 0, signouts = 0;
  const route = load('../../app/auth/recovery/route.ts', {
    rpc: async () => { const won = !consumed; consumed = true; return { data: won, error: null }; },
    auth: {
      getSession: async () => ({ data: { session: { access_token: token() } } }),
      getUser: async () => ({ data: { user: { id: 'u' } }, error: null }),
      updateUser: async () => {
        assert.equal(consumed, true);
        updates++;
        return { error: { code: 'same_password', message: 'Do not expose internal details' } };
      },
      signOut: async () => { signouts++; return { error: null }; },
    },
  });
  const raw = context.newRecoveryGrant();
  const request = { headers: new Headers({ origin: 'https://strzelajtu.pl', 'content-type': 'application/json' }),
    cookies: { get: () => ({ value: raw }) }, text: async () => JSON.stringify({ password: 'Valid-Synthetic-Password-123' }) };
  const response = await route.POST(request);
  assert.equal(response.status, 400);
  assert.deepEqual(await response.json(), { ok: false, status: 'fresh_recovery_link_required', code: 'same_password' });
  assert.equal(response.cookies.get(context.RECOVERY_COOKIE).maxAge, 0);
  assert.equal(consumed, true);
  assert.equal((await route.POST(request)).status, 403);
  assert.equal(updates, 1);
  assert.equal(signouts, 0);
});
