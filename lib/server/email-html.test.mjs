import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import { escapeEmailHref, escapeHtml } from "./email-html.ts";
import { operationalEmailLayout } from "./operational-email-layout.ts";

const EMAIL_HTML_FILES = [
  "../../app/api/send-reservation-confirmation/route.ts",
  "../../app/api/send-reservation-cancellation/route.ts",
  "../../app/api/send-event-registration-confirmation/route.ts",
  "./event-reserve-promotion.ts",
  "./event-reserve-confirmation-email.ts",
];

function getTemplate(source, name) {
  const match = source.match(
    new RegExp("const " + name + " = `([\\s\\S]*?)`;")
  );

  assert.ok(match, `${name} template should exist`);
  return match[1];
}

test("escapeHtml encodes every HTML-significant character exactly once", () => {
  assert.equal(
    escapeHtml("<script>alert(1)</script>"),
    "&lt;script&gt;alert(1)&lt;/script&gt;"
  );
  assert.equal(
    escapeHtml("<img src=x onerror=alert(1)>"),
    "&lt;img src=x onerror=alert(1)&gt;"
  );
  assert.equal(escapeHtml("Jan & Anna"), "Jan &amp; Anna");
  assert.equal(escapeHtml('"O\'Connor"'), "&quot;O&#39;Connor&quot;");
  assert.doesNotMatch(
    escapeHtml("<script>alert(1)</script>"),
    /&amp;lt;|&amp;gt;/
  );
});

test("escapeEmailHref accepts only absolute HTTP(S) URLs and escapes attributes", () => {
  assert.equal(
    escapeEmailHref("https://example.invalid/path?a=1&b=2"),
    "https://example.invalid/path?a=1&amp;b=2"
  );
  assert.equal(
    escapeEmailHref("http://localhost:3000/my-events"),
    "http://localhost:3000/my-events"
  );

  for (const unsafeUrl of [
    "javascript:alert(1)",
    "data:text/html,<script>alert(1)</script>",
    "mailto:user@example.invalid",
    "/relative/path",
    "not a url",
  ]) {
    assert.throws(() => escapeEmailHref(unsafeUrl), /Invalid email URL/);
  }
});

test("all email HTML call sites use the central escaping helper", async () => {
  for (const relativePath of EMAIL_HTML_FILES) {
    const source = await readFile(new URL(relativePath, import.meta.url), "utf8");
    const plainText = getTemplate(source, "text");
    assert.match(source, /(?:@\/lib\/server\/|\.\/)operational-email-layout/);
    assert.doesNotMatch(source, /function escapeHtml\s*\(/);
    assert.match(source, /const html = operationalEmailLayout\(/);
    assert.doesNotMatch(source, /const html = `/);
    assert.match(plainText, /\$\{/);
    assert.doesNotMatch(plainText, /\$\{safe[A-Z]/);
  }
  const hostile = '<img src=x onerror="alert(1)"> & \'injection\'';
  const html = operationalEmailLayout({ tenantDisplayName: hostile, title: hostile, intro: hostile,
    details: [{ label: hostile, value: hostile }],
    actions: [{ label: hostile, url: 'https://example.invalid/?a=1&b=2', description: hostile }], notes: [hostile] });
  assert.doesNotMatch(html, /<img src=x|&amp;lt;/);
  assert.equal(html.split(escapeHtml(hostile)).length - 1, 9);
  assert.match(html, /href="https:\/\/example.invalid\/\?a=1&amp;b=2"/);
});

test("link-bearing emails validate href values while plain text remains unescaped", async () => {
  const linkFiles = [
    "../../app/api/send-reservation-confirmation/route.ts",
    "../../app/api/send-event-registration-confirmation/route.ts",
    "./event-reserve-promotion.ts",
    "./event-reserve-confirmation-email.ts",
  ];

  for (const relativePath of linkFiles) {
    const source = await readFile(new URL(relativePath, import.meta.url), "utf8");
    assert.match(source, /const html = operationalEmailLayout\(/);
    assert.match(source, /url: (?:checkInUrl|myEventsUrl|confirmUrl)/);
  }
  for (const url of ['javascript:alert(1)', 'data:text/html,bad', '/relative', 'not a url']) {
    assert.throws(() => operationalEmailLayout({ tenantDisplayName: 'Range', title: 'Test', intro: 'Test',
      details: [], actions: [{ label: 'Test', url }] }), /Invalid email URL/);
  }

  const confirmationSource = await readFile(
    new URL("./event-reserve-confirmation-email.ts", import.meta.url),
    "utf8"
  );
  const confirmationText = getTemplate(confirmationSource, "text");

  assert.match(confirmationText, /\$\{displayName\}/);
  assert.match(confirmationText, /\$\{event\?\.title \?\? "-"\}/);
  assert.match(confirmationText, /\$\{myEventsUrl\}/);
  assert.doesNotMatch(confirmationText, /\$\{safeDisplayName\}/);
});
