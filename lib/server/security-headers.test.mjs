import assert from "node:assert/strict";
import test from "node:test";

const configModule = await import(
  new URL("../../next.config.ts", import.meta.url)
);

const {
  buildContentSecurityPolicy,
  getApplicationSecurityHeaders,
  default: nextConfig,
} = configModule;

function toHeaderMap(headers) {
  return new Map(headers.map(({ key, value }) => [key, value]));
}

test("SEC-012 applies the global browser security header baseline", () => {
  const headers = toHeaderMap(getApplicationSecurityHeaders());

  assert.equal(headers.get("X-Content-Type-Options"), "nosniff");
  assert.equal(
    headers.get("Referrer-Policy"),
    "strict-origin-when-cross-origin"
  );
  assert.equal(headers.get("X-Frame-Options"), "DENY");
  assert.equal(headers.get("Cross-Origin-Opener-Policy"), "same-origin");
  assert.match(headers.get("Permissions-Policy"), /camera=\(\)/);
  assert.match(headers.get("Permissions-Policy"), /microphone=\(\)/);
  assert.match(headers.get("Permissions-Policy"), /geolocation=\(\)/);
});

test("SEC-012 production CSP is restrictive without unsafe-eval or broad wildcards", () => {
  const csp = buildContentSecurityPolicy({
    nodeEnv: "production",
    supabaseUrl: "https://project-ref.supabase.co/path",
  });

  assert.match(csp, /default-src 'self'/);
  assert.match(csp, /base-uri 'self'/);
  assert.match(csp, /form-action 'self'/);
  assert.match(csp, /frame-ancestors 'none'/);
  assert.match(csp, /object-src 'none'/);
  assert.match(csp, /script-src 'self' 'unsafe-inline'/);
  assert.match(csp, /script-src-attr 'none'/);
  assert.match(csp, /style-src 'self' 'unsafe-inline'/);
  assert.match(csp, /img-src 'self' data: blob:/);
  assert.match(csp, /font-src 'self' data:/);
  assert.match(
    csp,
    /connect-src 'self' https:\/\/project-ref\.supabase\.co wss:\/\/project-ref\.supabase\.co/
  );
  assert.doesNotMatch(csp, /unsafe-eval/);
  assert.doesNotMatch(csp, /(?:^|[ ;])\*(?:[ ;]|$)/);
});

test("SEC-012 development CSP permits only the eval capability needed by the dev runtime", () => {
  const csp = buildContentSecurityPolicy({
    nodeEnv: "development",
    supabaseUrl: "http://127.0.0.1:54321",
  });

  assert.match(csp, /script-src 'self' 'unsafe-inline' 'unsafe-eval'/);
  assert.match(
    csp,
    /connect-src 'self' http:\/\/127\.0\.0\.1:54321 ws:\/\/127\.0\.0\.1:54321/
  );
});

test("SEC-012 invalid Supabase origins fail closed instead of widening connect-src", () => {
  const csp = buildContentSecurityPolicy({
    nodeEnv: "production",
    supabaseUrl: "javascript:alert(1)",
  });

  assert.match(csp, /connect-src 'self'(?:;|$)/);
  assert.doesNotMatch(csp, /javascript:/);
});

test("SEC-012 covers public, authenticated, admin, token and API routes centrally", async () => {
  const rules = await nextConfig.headers();
  const bySource = new Map(rules.map((rule) => [rule.source, rule.headers]));
  const globalHeaders = toHeaderMap(bySource.get("/:path*"));

  assert.ok(globalHeaders.has("Content-Security-Policy"));
  assert.ok(globalHeaders.has("X-Content-Type-Options"));
  assert.ok(globalHeaders.has("Referrer-Policy"));
  assert.ok(globalHeaders.has("X-Frame-Options"));
  assert.ok(globalHeaders.has("Permissions-Policy"));

  for (const source of [
    "/api/:path*",
    "/:path(account|dashboard|my-events|my-reservations|reset-password)",
    "/admin/:path*",
    "/check-in/:path*",
    "/events/confirm/:path*",
  ]) {
    const headers = toHeaderMap(bySource.get(source));
    assert.equal(
      headers.get("Cache-Control"),
      "private, no-store, max-age=0, must-revalidate"
    );
  }

  assert.equal(
    toHeaderMap(bySource.get("/check-in/:path*")).get("Referrer-Policy"),
    "no-referrer"
  );
  assert.equal(
    toHeaderMap(bySource.get("/events/confirm/:path*")).get(
      "Referrer-Policy"
    ),
    "no-referrer"
  );
});
