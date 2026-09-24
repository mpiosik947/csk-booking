import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { featureForTenantRoute, TENANT_FEATURE_KEYS } from "../lib/tenant-features.ts";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");

test("feature catalog is stable and route mapping covers every gated operational module", () => {
  assert.deepEqual(TENANT_FEATURE_KEYS, [
    "booking", "events", "instructors", "staff", "checkin", "reports",
    "lane_blocks", "advanced_calendar", "branding", "custom_domain",
  ]);
  assert.equal(featureForTenantRoute("booking"), "booking");
  assert.equal(featureForTenantRoute("events"), "events");
  assert.equal(featureForTenantRoute("admin/reservations"), "booking");
  assert.equal(featureForTenantRoute("admin/lane-configuration"), "booking");
  assert.equal(featureForTenantRoute("admin/events"), "events");
  assert.equal(featureForTenantRoute("admin/users"), "staff");
  assert.equal(featureForTenantRoute("admin/check-in"), "checkin");
  assert.equal(featureForTenantRoute("admin/reports"), "reports");
  assert.equal(featureForTenantRoute("admin/lane-blocks"), "lane_blocks");
  assert.equal(featureForTenantRoute("admin/calendar"), "advanced_calendar");
  assert.equal(featureForTenantRoute("my-reservations"), null);
  assert.equal(featureForTenantRoute("my-events"), null);
});

test("tenant route shell enforces entitlement after authority and before rendering", async () => {
  const source = await read("./t/[slug]/[...path]/page.tsx");
  const authority = source.indexOf("getStaffRouteContext");
  const feature = source.indexOf("tenantRouteHasFeature(");
  const render = source.indexOf('route.path === "booking"');
  assert.ok(authority >= 0 && feature > authority && render > feature);
  assert.match(source, /route\.kind === "public" \? "public" : "member"/u);
  assert.match(source, /if \(!hasFeature\) notFound\(\)/u);
  assert.doesNotMatch(source, /tenantSlug === "csk"|first.*tenant/iu);
});

test("admin navigation is entitlement-backed without exposing commercial plan data", async () => {
  const source = await read("./admin/page.tsx");
  assert.match(source, /get_my_tenant_features_v1/u);
  assert.match(source, /features\.has/u);
  assert.doesNotMatch(source, /current_full_v1|booking_only_v1|plan_key|billing/iu);
});

test("settings toggles cannot present unavailable public modules", async () => {
  const source = await read("./admin/settings/page.tsx");
  assert.match(source, /feature_access/u);
  assert.match(source, /disabled=\{!entitled\}/u);
  assert.match(source, /Niedostępne w obecnym planie/u);
  assert.doesNotMatch(source, /tenant_plan_assignments|saas_plan_features|plan_key/u);
});

test("server API gates advanced calendar and reserve promotion before operational work", async () => {
  const [calendar, promotion] = await Promise.all([
    read("./api/admin/calendar-feed/route.ts"),
    read("./api/send-event-reserve-promotion/route.ts"),
  ]);
  assert.match(calendar, /p_feature_key: "advanced_calendar"/u);
  assert.ok(calendar.indexOf("get_my_tenant_feature_access_v1") < calendar.indexOf('from("shooting_lanes")'));
  assert.match(promotion, /p_feature_key: "events"/u);
  assert.ok(promotion.indexOf("get_my_tenant_feature_access_v1") < promotion.indexOf("promoteEventReserve(eventId)"));
});
