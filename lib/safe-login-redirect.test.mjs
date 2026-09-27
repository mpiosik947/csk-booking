import assert from "node:assert/strict";
import test from "node:test";
import { getSafeLoginRedirect } from "./safe-login-redirect.ts";

test("tenant login redirects preserve only known tenant module paths", () => {
  for (const path of [
    "/t/csk/booking", "/t/tenant-b/events", "/t/tenant-b/my-reservations",
    "/t/tenant-b/my-events", "/t/tenant-b/admin", "/t/tenant-b/admin/calendar",
    "/t/tenant-b/admin/lane-configuration",
  ]) assert.equal(getSafeLoginRedirect(path), path);
});

test("resource-bound reserve confirmation preserves only an exact UUID path", () => {
  const path = "/events/confirm/123e4567-e89b-12d3-a456-426614174000";
  assert.equal(getSafeLoginRedirect(path), path);
  assert.equal(getSafeLoginRedirect(`${path}?tenant=csk`), "/");
  assert.equal(getSafeLoginRedirect("/events/confirm/not-a-token"), "/");
});

test("login redirects reject external, encoded, query and unknown paths", () => {
  for (const path of [
    "https://example.invalid/t/csk/booking", "//example.invalid/t/csk/booking",
    "/t/csk%2fother/booking", "/t/CSK/booking", "/t/csk/admin/unknown",
    "/t/csk/events?token=secret", "/t/csk/events#fragment", "/t/csk/../admin", null,
    "javascript:alert(1)", "data:text/html,test", "/\\evil.example", "/%2fevil.example", "/login", "/reset-password",
  ]) assert.equal(getSafeLoginRedirect(path), "/");
});

test("direct login defaults to home and public tenant selectors preserve context", () => {
  for (const path of ["/", "/csk-krutla", "/synthetic-range-b", "/account", "/dashboard"]) {
    assert.equal(getSafeLoginRedirect(path), path);
  }
  assert.equal(getSafeLoginRedirect(null), "/");
  assert.equal(getSafeLoginRedirect(""), "/");
});
