import test from "node:test";
import assert from "node:assert/strict";
import { capabilities, pageSections, sectionAvailable, visibleSections } from "../lib/platform-onboarding-features.ts";
import { profileFlagKeys } from "../lib/platform-draft-configuration.ts";
import { isTenantFeatureKey } from "../lib/tenant-features.ts";

test("only persisted public profile flags are editable, each exactly once", () => {
  assert.deepEqual(pageSections.map(s => s.key).sort(), [...profileFlagKeys].sort());
  assert.ok(capabilities.every(c => isTenantFeatureKey(c.entitlement) && c.help && c.name));
  assert.equal(new Set(capabilities.map(c => c.name)).size, capabilities.length);
  assert.deepEqual(capabilities.filter(c => c.lane).map(c => c.entitlement), ["booking","booking"]);
  assert.equal(capabilities.find(c => c.name === "Lista rezerwowa").entitlement, "events");
  assert.ok(!capabilities.some(c => c.entitlement === "branding"));
});

test("saved visibility is intersected with effective access without erasing preferences", () => {
  const profile = Object.fromEntries(profileFlagKeys.map(k => [k, true]));
  const minimum = { booking:true, events:false, instructors:false };
  const noPlan = { booking:false, events:false, instructors:false };
  assert.deepEqual(visibleSections(profile, noPlan).map(s => s.key), ["show_about","show_contact","show_regulations"]);
  assert.deepEqual(visibleSections(profile, minimum).map(s => s.key), ["show_booking","show_pricing","show_about","show_contact","show_regulations"]);
  const full = { booking:true, events:true, instructors:true };
  assert.equal(visibleSections(profile, full).length, 7);
  assert.ok(profile.show_events);
  assert.ok(sectionAvailable(pageSections.find(s => s.key === "show_events"), full));
  assert.ok(!visibleSections({...profile,show_events:false},full).some(s => s.key === "show_events"));
});
