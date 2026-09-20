import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const source = (path) => readFile(new URL(path, import.meta.url), "utf8");

test("selected Events route mounts tenant staff UI, legacy URL remains separately callable", async () => {
  const shell = await source("../../t/[slug]/[...path]/page.tsx");
  const page = await source("./page.tsx");
  assert.match(shell, /route\.kind === "staff" && route\.path === "admin\/events"/);
  assert.match(shell, /<AdminEventsPage tenantId=\{tenantId\} tenantSlug=\{slug\}/);
  assert.match(page, /selectedTenant \? "admin_list_events_v2" : "admin_list_events_v1"/);
  for (const rpc of ["admin_list_event_registrations_v2", "admin_create_event_v3", "admin_update_event_v3", "admin_set_event_active_v3", "approve_event_registration_v2", "mark_event_registration_paid_v2"]) {
    assert.ok(page.includes(`selectedTenant ? "${rpc}" :`), `${rpc} not selected`);
  }
  assert.match(page, /selectedTenant\s*\? await supabase\.rpc\("get_my_tenant_role_v1", \{ p_tenant_id: tenantId \}\)/);
  assert.match(page, /if \(selectedTenant\) query = query\.eq\("tenant_id", tenantId\)/);
  assert.match(page, /selectedTenant \? `\/api\/cancel-event-registration\?tenant=/);
  assert.match(page, /href=\{selectedTenant \? `\/t\/\$\{tenantSlug\}\/events` : "\/events"\}/);
});

test("cancellation checks persisted registration tenant in DB and service recipient reads stay event-bound", async () => {
  const api = await source("../../api/cancel-event-registration/route.ts");
  const service = await source("../../../lib/server/event-reserve-promotion.ts");
  const migration = await source("../../../supabase/migrations/20260927100000_add_tenant_scoped_staff_event_rpcs.sql");
  assert.match(api, /selectedTenantId \? "cancel_event_registration_v2" : "cancel_event_registration"/);
  assert.match(api, /promoteEventReserve\(rpcData\.event_id, selectedTenantId \?\? undefined\)/);
  assert.match(migration, /join public\.events e on e\.id=r\.event_id and e\.tenant_id=r\.tenant_id/);
  assert.match(migration, /where r\.id=p_registration_id and r\.tenant_id=p_tenant_id/);
  assert.match(service, /expectedTenantId && eventData\.tenant_id !== expectedTenantId/);
  assert.match(service, /row\.tenant_id !== eventData\.tenant_id \|\| row\.event_id !== eventId/);
  assert.doesNotMatch(service, /NEXT_PUBLIC_SUPABASE_SERVICE_ROLE_KEY/);
});
