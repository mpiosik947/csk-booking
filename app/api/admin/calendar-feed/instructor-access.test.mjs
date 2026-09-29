import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import ts from 'typescript';

function calendarRoute(role, tenantId = 'tenant-a') {
  const calls = [];
  const client = {
    auth: { getUser: async () => ({ data: { user: { id: 'actor' } }, error: null }) },
    rpc: async (name, args) => {
      calls.push({ name, args });
      return { data: name === 'get_my_tenant_role_v1' ? role : true, error: null };
    },
    from: name => {
      calls.push({ table: name });
      const query = { then: resolve => Promise.resolve(resolve({ data: [], error: null })) };
      for (const method of ['select', 'eq', 'gte', 'lte', 'in']) query[method] = () => query;
      return query;
    },
  };
  const dependencies = {
    'next/server': { NextResponse: { json: (value, init) => Response.json(value, init) } },
    '@supabase/supabase-js': { createClient: () => client },
    '@/lib/server/auth-user-verification': { verifyAuthUser: async read => { await read(); return { ok: true }; } },
    '@/lib/server/tenant-context': { resolvePublicTenantContext: async () => ({ ok: true, value: { tenantId } }) },
    '@/lib/admin/calendar/query': { parseCalendarFeedQuery: () => ({ ok: true, value: { laneId: 'all', types: ['event'], rangeStart: '2026-10-01', rangeEnd: '2026-10-02' } }) },
    '@/lib/admin/calendar/time': { getWarsawCalendarDate: () => '2026-10-01' },
    '@/lib/admin/calendar/feed': {
      parseCalendarFeedRole: value => ['admin', 'pracownik', 'instruktor'].includes(value) ? value : null,
      buildCalendarFeed: () => ({ ok: true, lanes: [] }),
    },
  };
  const code = ts.transpileModule(readFileSync(new URL('./route.ts', import.meta.url), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 },
  }).outputText;
  const compiled = { exports: {} };
  new Function('require', 'module', 'exports', 'process', code)(name => {
    assert.ok(dependencies[name], `Unexpected dependency ${name}`);
    return dependencies[name];
  }, compiled, compiled.exports, { env: { NEXT_PUBLIC_SUPABASE_URL: 'https://synthetic.invalid', NEXT_PUBLIC_SUPABASE_ANON_KEY: 'synthetic-public-key' } });
  return { ...compiled.exports, calls };
}

for (const role of ['instructor', 'instruktor', 'user', null, 'platform_admin']) {
  test(`calendar denies ${role} before querying any operational table`, async () => {
    const route = calendarRoute(role);
    const response = await route.GET(new Request('https://synthetic.invalid/api/admin/calendar-feed?tenant=a', { headers: { authorization: 'Bearer synthetic' } }));
    assert.equal(response.status, 403);
    assert.equal((await response.json()).code, 'forbidden');
    assert.equal(route.calls.some(call => call.table), false);
    assert.deepEqual(route.calls.map(call => call.name), ['get_my_tenant_role_v1']);
  });
}
for (const role of ['admin', 'employee']) {
  test(`calendar preserves ${role} access using the resolved current tenant`, async () => {
    const route = calendarRoute(role, 'tenant-b');
    const response = await route.GET(new Request('https://synthetic.invalid/api/admin/calendar-feed?tenant=b', { headers: { authorization: 'Bearer synthetic' } }));
    assert.equal(response.status, 200);
    assert.ok(route.calls.some(call => call.table === 'events'));
    assert.equal(route.calls[0].args.p_tenant_id, 'tenant-b');
  });
}
test('calendar still rejects anonymous requests before membership lookup', async () => {
  const route = calendarRoute('admin');
  assert.equal((await route.GET(new Request('https://synthetic.invalid/api/admin/calendar-feed?tenant=a'))).status, 401);
  assert.deepEqual(route.calls, []);
});
