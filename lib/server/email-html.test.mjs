import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import { escapeEmailHref, escapeHtml } from "./email-html.ts";

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
    const html = getTemplate(source, "html");
    const plainText = getTemplate(source, "text");
    const interpolations = [...html.matchAll(/\$\{([^}]+)\}/g)].map(
      (match) => match[1]
    );

    assert.match(source, /(?:@\/lib\/server\/|\.\/)email-html/);
    assert.doesNotMatch(source, /function escapeHtml\s*\(/);
    assert.match(html, /<div\b/);
    assert.match(html, /<p\b/);
    assert.ok(interpolations.length > 0);
    assert.deepEqual(
      interpolations.filter(
        (value) => !value.startsWith("safe") && value !== "cancelledByText"
      ),
      [],
      `${relativePath} contains an unescaped dynamic HTML value`
    );
    assert.match(plainText, /\$\{/);
    assert.doesNotMatch(plainText, /\$\{safe[A-Z]/);
  }
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
    const html = getTemplate(source, "html");

    assert.match(source, /escapeEmailHref\(/);
    assert.match(html, /href="\$\{safe[A-Za-z]+Url\}"/);
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
