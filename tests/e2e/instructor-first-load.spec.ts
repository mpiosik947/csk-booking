import { test, expect, type Page } from '@playwright/test';
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';

const fixture = JSON.parse(readFileSync(process.env.INSTRUCTOR_E2E_FIXTURE!, 'utf8')) as {
  app: string; origin: string; password: string; scratchDatabase: string;
};
for (const value of [fixture.app, fixture.origin]) {
  if (new URL(value).hostname !== '127.0.0.1' || new URL(value).protocol !== 'http:') {
    throw new Error('Real instructor regression requires disposable loopback services.');
  }
}

// Fixture control is confined to a disposable database in the existing LOCAL Docker stack.
// Neither this connection nor this test can target a remote or persistent database.
function membership(side: 'a' | 'b', status: 'active' | 'suspended') {
  if (!/^sbr3_[a-f0-9]{16}$/.test(fixture.scratchDatabase)) throw new Error('Disposable scratch DB required.');
  const result = execFileSync('docker', ['exec', '-i', 'supabase_db_csk-booking', 'psql', '-X', '-At',
    '-v', 'ON_ERROR_STOP=1', '-U', 'postgres', '-d', fixture.scratchDatabase], {
    encoding: 'utf8', windowsHide: true,
    input: `begin;
      do $$begin
        if (select count(*) from auth.users) <> 11 or
          exists(select 1 from auth.users where email not like '%@synthetic.invalid') then
          raise exception 'Not isolated synthetic fixtures';
        end if;
      end$$;
      with changed as (
        update public.tenant_memberships set status='${status}'
        where tenant_id=audit_syntb.id('${side.toUpperCase()}')
          and user_id=audit_syntb.id('${side.toUpperCase()}_INSTRUCTOR') and role='instructor'
        returning 1
      ) select 'fixture_updates='||count(*) from changed;
      commit;`,
  });
  expect(result).toContain('fixture_updates=1');
}
declare global {
  interface Window {
    instructorObservations: { path: string; alerts: string[]; text: string }[];
    instructorNavigationMarker?: string;
  }
}

test.beforeEach(async ({ context }) => {
  await context.route('**/*', route => new URL(route.request().url()).hostname === '127.0.0.1' ? route.continue() : route.abort());
  await context.addInitScript(() => {
    const observed = window;
    observed.instructorObservations = [];
    new MutationObserver(() => {
      if (!location.pathname.includes('/instructor/')) return;
      observed.instructorObservations.push({ path: location.pathname,
        alerts: [...document.querySelectorAll('[role="alert"]')].map(el => el.textContent ?? ''),
        text: document.body?.innerText ?? '' });
    }).observe(document, { childList: true, subtree: true, characterData: true });
  });
});

async function login(page: Page, actor: string) {
  await page.goto(fixture.app + '/login?redirectTo=%2Fdashboard');
  await page.getByLabel('E-mail', { exact: true }).fill(actor.toLowerCase() + '@synthetic.invalid');
  await page.getByLabel('Hasło', { exact: true }).fill(fixture.password);
  await page.getByRole('button', { name: 'Zaloguj się', exact: true }).click();
  await page.waitForURL('**/dashboard');
}
async function ownData(page: Page, side: string) {
  // Bounded below the existing 15-second poll: an automatic later retry cannot hide first-load failure.
  await expect(page.getByRole('link', { name: side.toUpperCase() + '_EVENT', exact: true })).toBeVisible();
  expect(await page.locator('body').innerText()).not.toContain((side === 'a' ? 'B' : 'A') + '_EVENT');
  const observations = await page.evaluate(() => window.instructorObservations);
  expect(observations.flatMap(row => row.alerts)).toEqual([]);
}

for (const side of ['a', 'b']) {
  const path = `/t/synt-${side}/instructor/events`;
  test(`${side}: first load, manual refresh and hard reload use real authorized API`, async ({ page }, info) => {
    await login(page, side + '_INSTRUCTOR');
    const responses: { path: string; status: number }[] = [];
    page.on('response', response => { if (response.url().includes('/api/instructor/')) responses.push({ path: new URL(response.url()).pathname, status: response.status() }); });
    expect((await page.goto(fixture.app + path))?.status()).toBe(200);
    await ownData(page, side);
    await page.getByRole('button', { name: 'Odśwież', exact: true }).click();
    await ownData(page, side);
    await page.reload();
    await ownData(page, side);
    expect(responses.length).toBeGreaterThanOrEqual(3);
    expect(responses.every(row => row.path === `/api/instructor/synt-${side}/events` && row.status === 200)).toBe(true);
    await info.attach('sanitized-api-responses', { body: JSON.stringify(responses), contentType: 'application/json' });
  });
  test(`${side}: client navigation preserves canonical context without a document reload`, async ({ page }) => {
    await login(page, side + '_INSTRUCTOR');
    await page.goto(fixture.app + `/t/synt-${side}/booking`);
    await page.evaluate(() => { window.instructorNavigationMarker = 'same-document'; });
    await page.getByRole('link', { name: 'Moje szkolenia — instruktor', exact: true }).click();
    await page.waitForURL('**' + path);
    expect(await page.evaluate(() => window.instructorNavigationMarker)).toBe('same-document');
    await ownData(page, side);
  });
  test(`${side}: opposite tenant hard load denies without any sibling data flash`, async ({ page }) => {
    await login(page, side + '_INSTRUCTOR');
    const other = side === 'a' ? 'b' : 'a';
    expect((await page.goto(fixture.app + `/t/synt-${other}/instructor/events`))?.status()).toBe(404);
    const observations = await page.evaluate(() => window.instructorObservations);
    expect(observations.every(row => !row.text.includes('_EVENT') && !row.text.includes('Synthetic CUSTOMER'))).toBe(true);
    const api = await page.request.get(fixture.app + `/api/instructor/synt-${other}/events`);
    expect(api.status()).toBe(403);
    expect(await api.text()).not.toContain('_EVENT');
  });
}

for (const actor of ['PA', 'A_ADMIN', 'B_ADMIN', 'A_EMPLOYEE', 'B_EMPLOYEE', 'CUSTOMER_SHARED']) {
  test(`${actor}: no instructor authority on either tenant`, async ({ page }) => {
    await login(page, actor);
    for (const side of ['a', 'b']) {
      expect((await page.goto(fixture.app + `/t/synt-${side}/instructor/events`))?.status()).toBe(404);
      expect(await page.locator('body').innerText()).not.toContain('_EVENT');
      expect((await page.request.get(fixture.app + `/api/instructor/synt-${side}/events`)).status()).toBe(403);
    }
  });
}
test('anonymous cannot enter either instructor route', async ({ page }) => {
  for (const side of ['a', 'b']) {
    await page.goto(fixture.app + `/t/synt-${side}/instructor/events`);
    expect(new URL(page.url()).pathname).toBe('/login');
    expect((await page.request.get(fixture.app + `/api/instructor/synt-${side}/events`)).status()).toBe(403);
  }
});
test('mixed employee A / instructor B account retains separate route authority', async ({ page }) => {
  await login(page, 'MULTI_ROLE_USER');
  expect((await page.goto(fixture.app + '/t/synt-a/instructor/events'))?.status()).toBe(404);
  expect((await page.goto(fixture.app + '/t/synt-b/instructor/events'))?.status()).toBe(200);
  await expect(page.getByText('Brak przypisanych szkoleń w tym zakresie.', { exact: true })).toBeVisible();
  // Next's route announcer also uses role=alert, outside the instructor section.
  await expect(page.locator('section').filter({ has: page.getByRole('heading', { name: 'Moje szkolenia', exact: true }) }).getByRole('alert')).toHaveCount(0);
});

for (const side of ['a', 'b'] as const) {
  test(`${side}: real revocation stops requests for 60 wall-clock seconds; route change rechecks`, async ({ page }, info) => {
    test.setTimeout(120000);
    await login(page, side + '_INSTRUCTOR');
    await page.goto(fixture.app + `/t/synt-${side}/instructor/events`);
    await ownData(page, side);
    await page.getByRole('link', { name: side.toUpperCase() + '_EVENT', exact: true }).click();
    const panel = page.locator('section').filter({ has: page.getByRole('heading', { name: 'Szczegóły szkolenia', exact: true }) });
    await expect(panel.getByRole('heading', { name: side.toUpperCase() + '_EVENT', exact: true })).toBeVisible();
    const responses: { elapsedMs: number; status: number; path: string }[] = [];
    const started = Date.now();
    let deniedRequests = 0, countDenied = false;
    page.on('request', request => { if (countDenied && request.url().includes('/api/instructor/')) deniedRequests++; });
    page.on('response', response => {
      if (response.url().includes('/api/instructor/')) responses.push({ elapsedMs: Date.now() - started, status: response.status(), path: new URL(response.url()).pathname });
    });
    // A real successful 15-second poll precedes revocation; no clock mocking or API fulfillment.
    await expect.poll(() => responses.filter(row => row.status === 200).length, { timeout: 20000 }).toBe(1);
    await expect(panel.getByRole('heading', { name: side.toUpperCase() + '_EVENT', exact: true })).toBeVisible();
    try {
      membership(side, 'suspended');
      countDenied = true;
      // The next real authorized poll must discover the local membership revocation.
      await expect(panel.getByRole('alert')).toHaveText('Brak dostępu do szkoleń w tej lokalizacji.', { timeout: 20000 });
      expect(deniedRequests).toBe(1);
      const denialStart = Date.now(), counts = [{ elapsedMs: 0, requests: deniedRequests }];
      for (const seconds of [15, 30, 45, 60]) {
        await new Promise(resolve => setTimeout(resolve, 15000));
        await expect(panel.getByRole('alert')).toHaveText('Brak dostępu do szkoleń w tej lokalizacji.');
        await expect(panel.getByRole('heading', { name: side.toUpperCase() + '_EVENT', exact: true })).toHaveCount(0);
        await expect(panel.getByRole('link', { name: 'Pobierz CSV', exact: true })).toHaveCount(0);
        expect(deniedRequests, `denied requests at ${seconds}s`).toBe(1);
        counts.push({ elapsedMs: Date.now() - denialStart, requests: deniedRequests });
      }
      expect(counts.at(-1)!.elapsedMs).toBeGreaterThanOrEqual(60000);
      await info.attach('real-network-60s', { body: JSON.stringify({ side, counts, responses, mockedApi: false, controlledClock: false }), contentType: 'application/json' });
      countDenied = false;
      membership(side, 'active');
      // Server authority changed, but the unchanged denied component still waits for a real trigger.
      await expect(panel.getByRole('alert')).toHaveText('Brak dostępu do szkoleń w tej lokalizacji.');
      await page.getByRole('link', { name: 'Wróć do moich szkoleń', exact: true }).click();
      await expect(page.getByRole('link', { name: side.toUpperCase() + '_EVENT', exact: true })).toBeVisible();
      expect(await page.locator('body').innerText()).not.toContain((side === 'a' ? 'B' : 'A') + '_EVENT');
    } finally {
      membership(side, 'active');
    }
  });
}
