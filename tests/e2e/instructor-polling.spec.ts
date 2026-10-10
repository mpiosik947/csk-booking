import { test, expect, type Page, type Route } from '@playwright/test';
import { readFileSync } from 'node:fs';

const bundle = readFileSync('test-results/instructor-browser/fixture.js', 'utf8');
const denied = 'Brak dostępu do szkoleń w tej lokalizacji.';
const error = 'Nie udało się wczytać danych. Spróbuj ponownie.';
const empty = 'Brak przypisanych szkoleń w tym zakresie.';
const data = { events: { items: [], total: 0 } };
async function setup(page: Page, handler: (route: Route) => Promise<void>) {
  await page.clock.install();
  await page.route('http://instructor.test/**', async route => {
    if (new URL(route.request().url()).pathname.startsWith('/api/')) return handler(route);
    await route.fulfill({ contentType: 'text/html', body: `<html><body><div id="root"></div><script>${bundle}</script></body></html>` });
  });
  await page.goto('http://instructor.test/?lifecycle=1');
}
async function auth(page: Page, event: string, token: string, user = 'synthetic-user') {
  await page.evaluate(({ event, token, user }) => window.dispatchEvent(new CustomEvent('fixture-auth', {
    detail: { event, session: { user: { id: user }, access_token: token } },
  })), { event, token, user });
}
async function lifecycleNoise(page: Page) {
  await page.evaluate(() => {
    for (const event of ['blur', 'pagehide', 'pageshow', 'focus']) window.dispatchEvent(new Event(event));
    document.dispatchEvent(new Event('visibilitychange'));
  });
}

for (const outcome of [403, 401, 503, 'network'] as const) {
  test(`${outcome}: one request over 60s; focus/equivalent auth do not retry; manual recovery works`, async ({ page }, info) => {
    let calls = 0, recovered = false;
    await setup(page, async route => {
      calls++;
      if (recovered) await route.fulfill({ json: data });
      else if (outcome === 'network') await route.abort('failed');
      else await route.fulfill({ status: outcome, json: { error: 'unavailable' } });
    });
    const message = outcome === 401 || outcome === 403 ? denied : error;
    await expect(page.getByRole('alert')).toHaveText(message);
    expect(calls).toBe(1);
    const counts = [{ seconds: 0, calls }];
    for (const seconds of [15, 30, 45, 60]) {
      await lifecycleNoise(page);
      await auth(page, 'SIGNED_IN', 'synthetic-initial-token');
      await page.clock.runFor(15000);
      await expect(page.getByRole('alert')).toHaveText(message);
      expect(calls).toBe(1);
      counts.push({ seconds, calls });
    }
    await info.attach('terminal-request-count', { body: JSON.stringify({ outcome, counts }), contentType: 'application/json' });
    recovered = true;
    await page.getByRole('button', { name: 'Odśwież', exact: true }).click();
    await expect(page.getByText(empty, { exact: true })).toBeVisible();
    expect(calls).toBe(2);
  });
}

for (const trigger of ['SIGNED_IN', 'TOKEN_REFRESHED'] as const) {
  test(`${trigger}: changed session rechecks once after 403; success resumes 15s refresh`, async ({ page }) => {
    let calls = 0;
    await setup(page, async route => {
      calls++;
      await route.fulfill({ status: calls === 1 ? 403 : 200, json: calls === 1 ? { error: 'denied' } : data });
    });
    await expect(page.getByRole('alert')).toHaveText(denied);
    await page.clock.runFor(60000);
    expect(calls).toBe(1);
    await auth(page, trigger, 'new-session-token', trigger === 'SIGNED_IN' ? 'different-user' : 'synthetic-user');
    await expect(page.getByText(empty, { exact: true })).toBeVisible();
    expect(calls).toBe(2);
    for (let i = 0; i < 3; i++) await auth(page, 'SIGNED_IN', 'new-session-token', trigger === 'SIGNED_IN' ? 'different-user' : 'synthetic-user');
    expect(calls).toBe(2);
    await page.clock.runFor(15000);
    await expect.poll(() => calls).toBe(3);
    await expect(page.getByText(empty, { exact: true })).toBeVisible();
  });
}

test('authorized polling detects revocation and stops at its first 403', async ({ page }) => {
  let calls = 0;
  await setup(page, async route => {
    calls++;
    await route.fulfill({ status: calls < 3 ? 200 : 403, json: calls < 3 ? data : { error: 'denied' } });
  });
  await expect(page.getByText(empty, { exact: true })).toBeVisible();
  expect(calls).toBe(1);
  await page.clock.runFor(15000);
  await expect.poll(() => calls).toBe(2);
  await expect(page.getByText(empty, { exact: true })).toBeVisible();
  await page.clock.runFor(15000);
  await expect(page.getByRole('alert')).toHaveText(denied);
  await page.clock.runFor(60000);
  expect(calls).toBe(3);
  await expect(page.getByText(empty, { exact: true })).toHaveCount(0);
});

for (const side of ['a', 'b']) {
  test(`denied tenant ${side} does not poison the other tenant or retain its timer`, async ({ page }) => {
    const paths: string[] = [];
    await setup(page, async route => {
      const path = new URL(route.request().url()).pathname; paths.push(path);
      const blocked = path.includes(`synthetic-${side}/`);
      await route.fulfill({ status: blocked ? 403 : 200, json: blocked ? { error: 'denied' } : data });
    });
    if (side === 'a') {
      await expect(page.getByText(empty, { exact: true })).toBeVisible();
      await page.getByRole('button', { name: 'Tenant A', exact: true }).click();
    }
    await expect(page.getByRole('alert')).toHaveText(denied);
    const before = paths.length;
    await page.clock.runFor(60000);
    expect(paths).toHaveLength(before);
    const other = side === 'a' ? 'B' : 'A';
    await page.getByRole('button', { name: `Tenant ${other}`, exact: true }).click();
    await expect(page.getByText(empty, { exact: true })).toBeVisible();
    expect(paths.slice(before)).toEqual([`/api/instructor/synthetic-${other.toLowerCase()}/events`]);
    await page.clock.runFor(15000);
    await expect.poll(() => paths.length).toBe(before + 2);
    expect(paths.at(-1)).toBe(`/api/instructor/synthetic-${other.toLowerCase()}/events`);
  });
}

for (const action of ['logout', 'unmount']) {
  test(`${action} clears authorized polling and lifecycle listeners cannot restart it`, async ({ page }) => {
    let calls = 0;
    await setup(page, async route => { calls++; await route.fulfill({ json: data }); });
    await expect(page.getByText(empty, { exact: true })).toBeVisible();
    if (action === 'logout') {
      await page.evaluate(() => window.dispatchEvent(new CustomEvent('fixture-auth', { detail: 'SIGNED_OUT' })));
      await expect(page.getByRole('alert')).toHaveText(denied);
    } else await page.getByRole('button', { name: 'Unmount reader', exact: true }).click();
    await expect(page.getByText(empty, { exact: true })).toHaveCount(0);
    await lifecycleNoise(page);
    await page.clock.runFor(60000);
    expect(calls).toBe(1);
  });
}

for (const change of ['session', 'tenant', 'unmount']) {
  test(`late success from previous ${change} cannot restore data or polling`, async ({ page }) => {
    // Simulate a transport that finishes despite abort, exercising stale-response guards too.
    await page.addInitScript(() => {
      const original = window.fetch;
      window.fetch = (input, init) => original(input, { ...init, signal: undefined });
    });
    let calls = 0, release: (() => void) | undefined;
    await setup(page, async route => {
      calls++;
      if (calls === 1) {
        await new Promise<void>(resolve => { release = resolve; });
        await route.fulfill({ json: { events: { total: 1, items: [{ id: 'old', title: 'OLD PRIVATE EVENT', event_date: '2026-12-01', start_time: '10:00', end_time: '11:00', status: 'upcoming' }] } } });
      } else await route.fulfill({ status: 403, json: { error: 'denied' } });
    });
    await expect.poll(() => typeof release).toBe('function');
    if (change === 'session') await auth(page, 'SIGNED_IN', 'different-token', 'different-user');
    else await page.getByRole('button', { name: change === 'tenant' ? 'Tenant A' : 'Unmount reader', exact: true }).click();
    if (change !== 'unmount') await expect(page.getByRole('alert')).toHaveText(denied);
    release!();
    await page.clock.runFor(60000);
    await expect(page.getByText('OLD PRIVATE EVENT', { exact: true })).toHaveCount(0);
    expect(calls).toBe(change === 'unmount' ? 1 : 2);
  });
}
