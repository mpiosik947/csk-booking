import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import ts from 'typescript';
import { createRequire } from 'node:module';
const source = fs.readFileSync(new URL('./recovery-context.ts', import.meta.url), 'utf8');
const output = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText;
const compiled = { exports: {} };
new Function('require', 'module', 'exports', output)(createRequire(import.meta.url), compiled, compiled.exports);
const { newRecoveryGrant, recoveryGrantHash, validRecoveryQuery } = compiled.exports;

test('opaque 32-byte grants hash decoded bytes; strict canonical encoding', () => {
  const grant = newRecoveryGrant();
  assert.equal(Buffer.from(grant, 'base64url').length, 32);
  assert.match(recoveryGrantHash(grant), /^[a-f0-9]{64}$/);
  assert.notEqual(newRecoveryGrant(), grant);
  assert.equal(recoveryGrantHash(grant), recoveryGrantHash(grant));
  for (const invalid of [undefined, '', grant + '=', 'x'.repeat(1025), 'a'.repeat(43)]) assert.equal(recoveryGrantHash(invalid), null);
});
test('strict next and recovery-only query allowlist', () => {
  const base = 'token_hash=' + 'a'.repeat(64) + '&type=recovery';
  assert.equal(validRecoveryQuery(new URLSearchParams(base)), true);
  assert.equal(validRecoveryQuery(new URLSearchParams(base + '&next=/reset-password')), true);
  for (const next of ['https://evil.example', '//evil.example', 'javascript:alert(1)', '/t/csk', '/reset-password?next=x']) {
    assert.equal(validRecoveryQuery(new URLSearchParams(base + '&next=' + encodeURIComponent(next))), false);
  }
  for (const query of ['', base + '&type=recovery', base + '&token_hash=extra', base.replace('recovery', 'signup'), base + '&code=x']) {
    assert.equal(validRecoveryQuery(new URLSearchParams(query)), false);
  }
});
test('reset page has no SDK URL exchange or generic-session recovery fallback', () => {
  const page = fs.readFileSync(new URL('../../app/reset-password/page.tsx', import.meta.url), 'utf8');
  assert.doesNotMatch(page, /exchangeCodeForSession|supabase\.auth|getSession\(/);
  assert.match(page, /fetch\("\/auth\/recovery"/);
  const forgot = fs.readFileSync(new URL('../../app/forgot-password/page.tsx', import.meta.url), 'utf8');
  assert.match(forgot, /PLATFORM_BASE_URL/);
  assert.doesNotMatch(forgot, /window\.location\.origin/);
});
test('server-only mint has no HMAC or caller-supplied user authority', () => {
  const mint = fs.readFileSync(new URL('./recovery-grant-mint.ts', import.meta.url), 'utf8');
  assert.match(mint, /import "server-only"/);
  assert.match(mint, /process\.env\.SUPABASE_SERVICE_ROLE_KEY/);
  assert.doesNotMatch(mint, /NEXT_PUBLIC_.*SERVICE|p_user_id|console\./);
  assert.doesNotMatch(source, /createHmac|RECOVERY_CONTEXT_SECRET/);
});

test('confirm rejects Supabase otp_expired and transport failure without issuing recovery proof', async () => {
  const routeSource = fs.readFileSync(new URL('../../app/auth/confirm/route.ts', import.meta.url), 'utf8');
  const js = ts.transpileModule(routeSource, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText;
  for (const transportFailure of [false, true]) {
    const loaded = { exports: {} };
    let verified = 0;
    const requireMock = name => {
      if (name.endsWith('recovery-context')) return compiled.exports;
      if (name.endsWith('recovery-grant-mint')) return { recoveryGrantMinter: () => () => assert.fail('No mint after expired token') };
      if (name.endsWith('recovery-http')) return {
        recoveryOrigin: () => 'https://strzelajtu.pl', protectResponse: response => response,
        clearRecovery: () => {}, recoveryCookieOptions: () => ({}),
        recoveryClient: () => ({ auth: { verifyOtp: async input => {
          verified++;
          assert.equal(input.type, 'recovery');
          assert.equal(input.token_hash, 'a'.repeat(64));
          if (transportFailure) throw new Error('Synthetic transport failure');
          return { data: { session: null, user: null }, error: { code: 'otp_expired' } };
        } } }),
      };
      return createRequire(import.meta.url)(name);
    };
    new Function('require', 'module', 'exports', js)(requireMock, loaded, loaded.exports);
    const response = await loaded.exports.GET({ nextUrl: new URL('https://strzelajtu.pl/auth/confirm?token_hash=' + 'a'.repeat(64) + '&type=recovery') });
    assert.equal(verified, 1);
    assert.equal(response.headers.get('location'), 'https://strzelajtu.pl/reset-password?recoveryError=1');
  }
});
