import { test, expect } from '@playwright/test';
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';

// No service role or production credentials: only the disposable harness's anon client.
// The harness supplies CUSTOMER_SHARED metadata large enough to require cookie chunks
// and cookieBridge, a local browser bundle importing the actual lib/supabase.ts.
const fixture = JSON.parse(readFileSync(process.env.AUTH_COOKIE_E2E_FIXTURE, 'utf8'));
if (new URL(fixture.app).origin !== 'https://127.0.0.1:3108' ||
    new URL(fixture.origin).origin !== 'http://127.0.0.1:55430' ||
    !/^sbr3_[a-f0-9]{16}$/.test(fixture.scratchDatabase)) throw new Error('Disposable local TLS services required.');
const authCookie = name => /^sb-.*-auth-token(?:-code-verifier)?(?:\.\d+)?$/.test(name);
const sessionCookie = name => /^sb-.*-auth-token(?:\.\d+)?$/.test(name);
const evidence = new Map();
function localSql(statement) {
  return execFileSync('docker', ['exec', '-i', 'supabase_db_csk-booking', 'psql', '-X', '-At',
    '-v', 'ON_ERROR_STOP=1', '-U', 'postgres', '-d', fixture.scratchDatabase],
  { input: `begin; do $$begin
      if (select count(*) from auth.users) <> 11 or
        exists(select 1 from auth.users where email not like '%@synthetic.invalid') then
        raise exception 'Isolated synthetic fixtures required'; end if;
      end$$; ${statement} commit;`, encoding: 'utf8', windowsHide: true }).trim();
}

test.beforeEach(async ({ context }, info) => {
  const writes = [];
  evidence.set(info.testId, writes);
  await context.route('**/*', route => ['127.0.0.1', 'localhost'].includes(new URL(route.request().url()).hostname) ? route.continue() : route.abort());
  await context.exposeBinding('__recordCookieFlags', (_, flags) => writes.push(flags));
  await context.addInitScript(() => {
    const descriptor = Object.getOwnPropertyDescriptor(Document.prototype, 'cookie');
    Object.defineProperty(Document.prototype, 'cookie', {
      configurable: true, get: descriptor.get,
      set(value) {
        const [pair, ...parts] = String(value).split(';');
        const name = pair.slice(0, pair.indexOf('='));
        if (/^sb-.*-auth-token/.test(name)) {
          // Never send cookie values or tokens to the test reporter.
          void window.__recordCookieFlags({ writer: 'document.cookie', name, attributes: parts.map(p => p.trim()) });
        }
        descriptor.set.call(this, value);
      },
    });
  });
});

function checkFlags(flags) {
  expect(flags.secure).toBe(true);
  expect(flags.httpOnly).toBe(false);
  expect(flags.sameSite).toBe('Lax');
  expect(flags.path).toBe('/');
  expect(flags.domain).toBe('127.0.0.1');
}
async function inventory(context) {
  const cookies = (await context.cookies()).filter(c => authCookie(c.name));
  for (const cookie of cookies) checkFlags(cookie);
  expect(new Set(cookies.map(c => `${c.name}|${c.path}|${c.domain}`)).size).toBe(cookies.length);
  return cookies.map(({ name, secure, httpOnly, sameSite, path, domain }) => ({ name, secure, httpOnly, sameSite, path, domain }));
}
test.afterEach(async ({ context }, info) => {
  const writes = evidence.get(info.testId);
  for (const { attributes } of writes) {
    expect(attributes.some(a => /^secure$/i.test(a))).toBe(true);
    expect(attributes.some(a => /^path=\/$/i.test(a))).toBe(true);
    expect(attributes.some(a => /^samesite=lax$/i.test(a))).toBe(true);
    expect(attributes.some(a => /^domain=/i.test(a))).toBe(false);
    expect(attributes.some(a => /^httponly$/i.test(a))).toBe(false);
  }
  await info.attach('cookie-attributes-redacted', { body: JSON.stringify({ writes, active: await inventory(context) }), contentType: 'application/json' });
  evidence.delete(info.testId);
});
async function login(page, actor, app = fixture.app) {
  await page.goto(app + '/login?redirectTo=%2Fdashboard');
  await page.getByLabel('E-mail', { exact: true }).fill(actor.toLowerCase() + '@synthetic.invalid');
  await page.getByLabel('Hasło', { exact: true }).fill(fixture.password);
  await page.getByRole('button', { name: 'Zaloguj się', exact: true }).click();
  await expect(page).toHaveURL(app + '/dashboard');
}
async function bridge(page) {
  // Bundle imports the actual lib/supabase.ts with the local build environment.
  await page.addScriptTag({ path: fixture.cookieBridge });
  expect(await page.evaluate(() => window.cookieAuth.ready())).toBe(true);
}
for (const actor of ['A_ADMIN', 'B_ADMIN', 'A_INSTRUCTOR', 'B_INSTRUCTOR', 'CUSTOMER_SHARED', 'PA']) {
  test(`${actor}: TLS login, reload, shared session and authority`, async ({ page, context }) => {
    await login(page, actor);
    expect((await inventory(context)).length).toBeGreaterThan(0);
    await page.reload();
    await expect(page).toHaveURL(fixture.app + '/dashboard');
    await bridge(page);
    const names = (await inventory(context)).map(c => c.name);
    if (actor === 'CUSTOMER_SHARED') {
      expect(names.length).toBeGreaterThan(1);
      for (const side of ['a', 'b']) {
        await page.goto(fixture.app + `/t/synt-${side}/my-reservations`);
        await expect(page.getByText('Moje rezerwacje', { exact: true }).first()).toBeVisible();
        expect((await inventory(context)).map(c => c.name)).toEqual(names);
      }
    }
    const response = await context.request.get(fixture.app + '/platform-admin');
    expect(response.status()).toBe(actor === 'PA' ? 200 : 404);
  });
}
test('old non-Secure session upgrades in place; refresh, client navigation and logout remove all chunks', async ({ page, context }) => {
  await login(page, 'CUSTOMER_SHARED');
  const previous = (await context.cookies()).filter(c => sessionCookie(c.name));
  expect(previous.length).toBeGreaterThan(1);
  // Model existing cookies with identical host/path/name, preserving the real session in memory.
  await context.addCookies(previous.map(c => ({ ...c, secure: false })));
  expect((await context.cookies()).filter(c => sessionCookie(c.name)).every(c => !c.secure)).toBe(true);
  await bridge(page);
  expect(await page.evaluate(() => window.cookieAuth.refresh())).toBe(true);
  expect((await inventory(context)).map(c => c.name)).toEqual(previous.map(c => c.name));
  await page.getByRole('link', { name: /^Moje konto/ }).first().click();
  await expect(page).toHaveURL(/\/account$/);
  await bridge(page);
  expect(await page.evaluate(() => window.cookieAuth.logoutAndCheckRevocation())).toBe(true);
  expect(await inventory(context)).toEqual([]);
  await page.waitForTimeout(3000);
  expect(await inventory(context)).toEqual([]);
  await page.reload();
  expect(await inventory(context)).toEqual([]);
});

async function expireSession(context) {
  const cookies = (await context.cookies()).filter(c => sessionCookie(c.name)).sort((a,b) => a.name.localeCompare(b.name, 'en', { numeric: true }));
  const joined = cookies.map(c => c.value).join('');
  expect(joined.startsWith('base64-')).toBe(true);
  const session = JSON.parse(Buffer.from(joined.slice(7), 'base64url').toString());
  session.expires_at = Math.floor(Date.now() / 1000) - 120;
  const expired = 'base64-' + Buffer.from(JSON.stringify(session)).toString('base64url');
  let offset = 0;
  await context.addCookies(cookies.map((cookie, i) => {
    const value = expired.slice(offset, i === cookies.length - 1 ? undefined : offset + cookie.value.length);
    offset += cookie.value.length;
    return { ...cookie, value };
  }));
}
for (const [writer, path, status] of [['middleware', '/admin', 307], ['SSR route helper', '/api/instructor/synt-a/events', 200]]) {
  test(`${writer}: expired session refresh emits Secure Set-Cookie`, async ({ page, context }, info) => {
    // The legacy middleware emits refreshed cookies on its authorized CSK redirect.
    // Give only this disposable actor temporary legacy membership; always remove it.
    if (writer === 'middleware') localSql("insert into public.tenant_memberships(tenant_id,user_id,role,status) select id,audit_syntb.id('A_INSTRUCTOR'),'employee','active' from public.tenants where slug='csk';");
    try {
    await login(page, 'A_INSTRUCTOR');
    // Close the page so a browser refresh cannot consume the deliberately expired session first.
    await page.close();
    await expireSession(context);
    const response = await context.request.get(fixture.app + path, { maxRedirects: 0 });
    expect(response.status()).toBe(status);
    const headers = response.headersArray().filter(h => h.name.toLowerCase() === 'set-cookie')
      .map(h => { const [pair, ...attributes] = h.value.split(';'); return { name: pair.slice(0, pair.indexOf('=')), attributes: attributes.map(a => a.trim()) }; })
      .filter(h => authCookie(h.name));
    expect(headers.length).toBeGreaterThan(0);
    for (const h of headers) expect(h.attributes.some(a => /^secure$/i.test(a))).toBe(true);
    expect((await inventory(context)).length).toBeGreaterThan(0);
    await info.attach('set-cookie-redacted', { body: JSON.stringify({ writer, headers }), contentType: 'application/json' });
    } finally {
      if (writer === 'middleware') localSql("delete from public.tenant_memberships where tenant_id=(select id from public.tenants where slug='csk') and user_id=audit_syntb.id('A_INSTRUCTOR');");
    }
  });
}
test('real browser local HTTP loopback supports Secure login and reload', async ({ page, context }) => {
  await login(page, 'B_ADMIN', 'http://127.0.0.1:3107');
  expect((await inventory(context)).length).toBeGreaterThan(0);
  await page.reload();
  await expect(page).toHaveURL('http://127.0.0.1:3107/dashboard');
  await bridge(page);
  expect(await page.evaluate(() => window.cookieAuth.refresh())).toBe(true);
  expect((await inventory(context)).length).toBeGreaterThan(0);
});
