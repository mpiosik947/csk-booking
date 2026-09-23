import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");

test("global dashboard is membership-backed without a hardcoded CSK authority", async () => {
  const source = await read("./dashboard/page.tsx");
  assert.match(source, /"get_my_active_tenants_v1"/);
  assert.match(source, /tenants\.map/);
  assert.match(source, /`\/t\/\$\{tenant\.tenant_slug\}\/booking`/);
  assert.match(source, /`\/t\/\$\{tenant\.tenant_slug\}\/admin`/);
  assert.doesNotMatch(source, /\/t\/csk/);
});

test("tenant module success navigation keeps the selected tenant slug", async () => {
  const [booking, events] = await Promise.all([
    read("./booking/BookingForm.tsx"), read("./events/page.tsx"),
  ]);
  assert.match(booking, /`\/t\/\$\{tenantSlug\}\/my-reservations`/);
  assert.match(events, /`\/t\/\$\{tenantSlug\}\/my-events`/);
  assert.doesNotMatch(booking, /window\.location\.href = "\/my-reservations"/);
  assert.doesNotMatch(events, /window\.location\.href = "\/my-events"/);
});

test("event cancellation API requires selected tenant context", async () => {
  const source = await read("./api/cancel-event-registration/route.ts");
  assert.match(source, /if \(!tenantSlug\)/);
  assert.match(source, /"cancel_event_registration_v2"/);
  assert.doesNotMatch(source, /\? "cancel_event_registration_v2" : "cancel_event_registration"/);
});

test("owner cancellation has no legacy RPC fallback and token navigation is tenant-neutral", async () => {
  const [reservations, confirmation] = await Promise.all([
    read("./my-reservations/page.tsx"), read("./events/confirm/[token]/page.tsx"),
  ]);
  assert.doesNotMatch(reservations, /supabase\.rpc\("cancel_reservation"/);
  assert.match(reservations, /tenant-cancel-reservation\?tenant=/);
  assert.doesNotMatch(confirmation, /href="\/(?:my-events|events)"/);
  assert.match(confirmation, /href="\/dashboard"/);
});
