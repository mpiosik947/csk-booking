import { randomUUID } from "node:crypto";
import { execFileSync } from "node:child_process";
import { createClient } from "@supabase/supabase-js";
import { createServerClient } from "@supabase/ssr";
import { test, expect } from "@playwright/test";
import { getLocalSupabaseTestEnvironment } from "./local-supabase";
const env = getLocalSupabaseTestEnvironment();
const admin = createClient(env.supabaseUrl, env.serviceRoleKey, { auth: { persistSession: false, autoRefreshToken: false } });

test('same password shows precise UX, leaves DB grant consumed and denies captured-cookie retry', async ({ browser, baseURL }) => {
  const marker = randomUUID();
  const email = `same-password-${marker}@example.invalid`;
  const password = `Initial-${marker}!Aa1`;
  const created = await admin.auth.admin.createUser({ email, password, email_confirm: true });
  if (created.error || !created.data.user) throw new Error('Local fixture creation failed');
  const id = created.data.user.id;
  const context = await browser.newContext();
  try {
    const link = await admin.auth.admin.generateLink({ type: 'recovery', email });
    if (link.error) throw new Error('Local recovery link generation failed');
    const verified = await context.request.get(`${baseURL}/auth/confirm?token_hash=${encodeURIComponent(link.data.properties.hashed_token)}&type=recovery`, { maxRedirects: 0 });
    expect(verified.headers().location).toBe(`${baseURL}/reset-password`);
    const capturedCookies = await context.cookies();
    const page = await context.newPage();
    await page.goto(`${baseURL}/reset-password`);
    await expect(page.getByLabel('Nowe hasło', { exact: true })).toBeEnabled();
    await page.getByLabel('Nowe hasło', { exact: true }).fill(password);
    await page.getByLabel('Powtórz nowe hasło').fill(password);
    await page.getByRole('button', { name: 'Zmień hasło' }).click();
    await expect(page.locator('main').getByRole('alert')).toHaveText('Nowe hasło musi różnić się od obecnego. Ten link resetujący został już wykorzystany.');
    const freshLink = page.getByRole('link', { name: 'Wygeneruj nowy link', exact: true });
    await expect(freshLink).toBeVisible();
    await expect(freshLink).toHaveAttribute('href', '/forgot-password');
    await expect(page.getByRole('button', { name: 'Zmień hasło' })).toBeDisabled();
    expect((await context.cookies()).some(cookie => cookie.name === 'st-recovery-context')).toBe(false);
    if (!/^[0-9a-f-]{36}$/.test(id)) throw new Error('Invalid local fixture UUID');
    const consumed = () => execFileSync('docker', ['exec', 'supabase_db_csk-booking', 'psql', '-U', 'postgres', '-d', 'postgres', '-Atc',
      `SELECT count(*) FROM public.recovery_grants WHERE user_id='${id}'::uuid AND consumed_at IS NOT NULL`], { encoding: 'utf8' }).trim();
    expect(consumed()).toBe('1');
    await context.addCookies(capturedCookies);
    expect((await context.request.post(`${baseURL}/auth/recovery`, {
      headers: { origin: baseURL! }, data: { password: `Different-${marker}!Aa2` },
    })).status()).toBe(403);
    expect(consumed()).toBe('1');
    const loginClient = createClient(env.supabaseUrl, env.anonKey, { auth: { persistSession: false, autoRefreshToken: false } });
    expect((await loginClient.auth.signInWithPassword({ email, password })).error === null).toBe(true);
    await loginClient.auth.signOut();
  } finally {
    await context.close();
    expect((await admin.auth.admin.deleteUser(id)).error === null).toBe(true);
    expect((await admin.auth.admin.getUserById(id)).data.user).toBeNull();
  }
});

for (const width of [1440, 375]) {
  test(`fresh independent browser recovery, update, logout and reuse denial (${width})`, async ({ browser, baseURL }) => {
    const marker = randomUUID();
    const email = `recovery-${marker}@example.invalid`;
    const password = `Old-${marker}!Aa1`;
    const created = await admin.auth.admin.createUser({ email, password, email_confirm: true });
    if (created.error || !created.data.user) throw new Error('Local fixture creation failed');
    const id = created.data.user.id;
    const context = await browser.newContext({ viewport: { width, height: 900 } });
    try {
      // Real local Supabase token, no initiating-browser cookies or PKCE verifier.
      const link = await admin.auth.admin.generateLink({ type: "recovery", email });
      if (link.error) throw new Error('Local recovery link generation failed');
      const path = `/auth/confirm?token_hash=${encodeURIComponent(link.data.properties.hashed_token)}&type=recovery&next=/reset-password`;
      const verified = await context.request.get(baseURL + path, { maxRedirects: 0 });
      expect(verified.status()).toBe(303);
      expect(verified.headers().location).toBe(`${baseURL}/reset-password`);
      const receipt = (await context.cookies()).find(cookie => cookie.name === "st-recovery-context");
      expect(Boolean(receipt?.httpOnly)).toBe(true);
      expect(receipt?.path).toBe('/auth');
      const capturedCookies = await context.cookies();
      const jar = new Map(capturedCookies.map(cookie => [cookie.name, cookie.value]));
      const refreshing = createServerClient(env.supabaseUrl, env.anonKey, { cookies: {
        getAll: () => [...jar].map(([name, value]) => ({ name, value })),
        setAll: cookies => cookies.forEach(cookie => jar.set(cookie.name, cookie.value)),
      } });
      const before = (await refreshing.auth.getSession()).data.session;
      if (!before) throw new Error('Recovery session missing');
      const claimsBefore = JSON.parse(Buffer.from(before.access_token.split('.')[1], 'base64url').toString());
      const refreshed = await refreshing.auth.refreshSession();
      expect(refreshed.error === null).toBe(true);
      if (!refreshed.data.session) throw new Error('Session refresh failed');
      const claimsAfter = JSON.parse(Buffer.from(refreshed.data.session.access_token.split('.')[1], 'base64url').toString());
      expect(claimsAfter.session_id === claimsBefore.session_id).toBe(true);
      await context.addCookies([...jar].map(([name, value]) => ({ name, value, url: baseURL! })));
      expect((await context.request.get(`${baseURL}/auth/recovery`)).status()).toBe(200);
      expect((await context.request.post(`${baseURL}/auth/recovery`, {
        headers: { origin: "https://evil.example" }, data: { password: "Not-Allowed-Password123!" },
      })).status()).toBe(403);
      const page = await context.newPage();
      await page.goto(`${baseURL}/reset-password`);
      await expect(page.getByLabel("Nowe hasło", { exact: true })).toBeEnabled();
      const nextPassword = `New-${marker}!Aa2`;
      await page.getByLabel("Nowe hasło", { exact: true }).fill(nextPassword);
      await page.getByLabel("Powtórz nowe hasło").fill(nextPassword);
      await page.getByRole("button", { name: "Zmień hasło" }).click();
      await expect(page).toHaveURL(`${baseURL}/login`);
      expect((await context.request.get(`${baseURL}/auth/recovery`)).status()).toBe(403);
      await context.addCookies(capturedCookies);
      const replay = await context.request.post(`${baseURL}/auth/recovery`, {
        headers: { origin: baseURL! }, data: { password: `Replay-${marker}!Aa3` },
      });
      expect(replay.status(), 'Captured recovery and session cookies must not authorize another reset').toBe(403);
      const loginClient = createClient(env.supabaseUrl, env.anonKey, { auth: { persistSession: false, autoRefreshToken: false } });
      const login = await loginClient.auth.signInWithPassword({ email, password: nextPassword });
      expect(login.error === null).toBe(true);
      await loginClient.auth.signOut();
      const reused = await context.request.get(baseURL + path, { maxRedirects: 0 });
      expect(reused.headers().location).toBe(`${baseURL}/reset-password?recoveryError=1`);
    } finally {
      await context.close();
      const cleanup = await admin.auth.admin.deleteUser(id);
      expect(cleanup.error === null).toBe(true);
      expect((await admin.auth.admin.getUserById(id)).data.user).toBeNull();
    }
  });
}

test('missing, malformed, wrong type and external next fail closed; ordinary login is not recovery', async ({ page, context, baseURL }) => {
  for (const query of ['', '?token_hash=bad&type=recovery', '?token_hash=' + 'a'.repeat(64) + '&type=recovery', '?token_hash=' + 'a'.repeat(64) + '&type=signup', '?token_hash=' + 'a'.repeat(64) + '&type=recovery&next=https://evil.example']) {
    const response = await context.request.get(`${baseURL}/auth/confirm${query}`, { maxRedirects: 0 });
    expect(response.headers().location).toBe(`${baseURL}/reset-password?recoveryError=1`);
  }
  await page.goto('/reset-password');
  await expect(page.getByLabel('Nowe hasło', { exact: true })).toBeDisabled();
  const marker = randomUUID();
  const email = `ordinary-${marker}@example.invalid`;
  const password = `Old-${marker}!Aa1`;
  const created = await admin.auth.admin.createUser({ email, password, email_confirm: true });
  if (created.error || !created.data.user) throw new Error('Local fixture failed');
  try {
    await page.goto('/login');
    await page.getByLabel('E-mail').fill(email);
    await page.getByLabel('Hasło').fill(password);
    await page.getByRole('button', { name: 'Zaloguj się', exact: true }).click();
    await expect(page).toHaveURL(/\/dashboard$/);
    await page.goto('/reset-password');
    await expect(page.getByLabel('Nowe hasło', { exact: true })).toBeDisabled();
    expect((await context.request.post(`${baseURL}/auth/recovery`, { headers: { origin: baseURL! }, data: { password: 'Different-Password-123!' } })).status()).toBe(403);
  } finally {
    expect((await admin.auth.admin.deleteUser(created.data.user.id)).error === null).toBe(true);
  }
});

for (const width of [1440, 375]) {
  test(`legacy ConfirmationURL PKCE same-browser succeeds, separate browser denies (${width})`, async ({ browser, baseURL }) => {
    const marker = randomUUID();
    const email = `legacy-${marker}@example.invalid`;
    const created = await admin.auth.admin.createUser({ email, password: `Initial-${marker}!Aa1`, email_confirm: true });
    if (created.error || !created.data.user) throw new Error('Local fixture failed');
    const context = await browser.newContext({ viewport: { width, height: 900 } });
    const other = await browser.newContext();
    let mailId: string | undefined;
    try {
      const jar = new Map<string, string>();
      const initiating = createServerClient(env.supabaseUrl, env.anonKey, { cookies: {
        getAll: () => [...jar].map(([name, value]) => ({ name, value })),
        setAll: cookies => cookies.forEach(cookie => jar.set(cookie.name, cookie.value)),
      } });
      const request = await initiating.auth.resetPasswordForEmail(email, { redirectTo: 'http://localhost:3000/reset-password' });
      expect(request.error === null).toBe(true);
      await expect.poll(async () => {
        const result = await fetch(`http://127.0.0.1:54324/api/v1/search?query=${encodeURIComponent('to:' + email)}`).then(response => response.json());
        mailId = result.messages?.[0]?.ID;
        return Boolean(mailId);
      }).toBe(true);
      const mail = await fetch(`http://127.0.0.1:54324/api/v1/message/${mailId}`).then(response => response.json());
      const link = String(mail.HTML).match(/href="([^"]*\/auth\/v1\/verify[^\"]*)"/i)?.[1]?.replaceAll('&amp;', '&');
      if (!link || !['localhost', '127.0.0.1'].includes(new URL(link).hostname)) throw new Error('Local-only recovery mail expected');
      const verify = await fetch(link, { redirect: 'manual' });
      const destination = verify.headers.get('location');
      if (!destination) throw new Error('Missing legacy redirect');
      const code = new URL(destination).searchParams.get('code');
      if (!code) throw new Error('Legacy PKCE code missing');
      const path = `/reset-password?code=${encodeURIComponent(code)}`;
      const crossDevice = await other.request.get(baseURL + path, { maxRedirects: 0 });
      expect(crossDevice.headers().location).toBe(`${baseURL}/reset-password?recoveryError=1`);
      await context.addCookies([...jar].map(([name, value]) => ({ name, value, url: baseURL! })));
      const completed = await context.request.get(baseURL + path, { maxRedirects: 0 });
      expect(completed.headers().location).toBe(`${baseURL}/reset-password`);
      const page = await context.newPage();
      let browserExchanges = 0;
      page.on('request', request => { if (request.url().includes('grant_type=pkce')) browserExchanges++; });
      await page.goto(`${baseURL}/reset-password`);
      await expect(page.getByLabel('Nowe hasło', { exact: true })).toBeEnabled();
      expect(browserExchanges).toBe(0);
    } finally {
      await context.close();
      await other.close();
      expect((await admin.auth.admin.deleteUser(created.data.user.id)).error === null).toBe(true);
      if (mailId) await fetch(`http://127.0.0.1:54324/api/v1/messages`, { method: 'DELETE', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ IDs: [mailId] }) });
    }
  });
}
