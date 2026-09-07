import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const source = readFileSync(new URL("./page.tsx", import.meta.url), "utf8");

test("home presents one prominent test-mode warning before the primary CTA", () => {
  const warning = source.indexOf('id="test-mode-warning-title"');
  const bookingCta = source.indexOf('href="/booking"');

  assert.ok(warning >= 0);
  assert.ok(bookingCta > warning);
  assert.equal(source.match(/UWAGA — SYSTEM W WERSJI TESTOWEJ/gu)?.length, 1);
  assert.doesNotMatch(source, /System w fazie sprawdzania/u);
});

test("warning clearly explains the test-only and non-binding status", () => {
  assert.match(source, /Strzelnica CSK nie została jeszcze oficjalnie uruchomiona/u);
  assert.match(source, /Aplikacja działa obecnie w trybie testowym/u);
  assert.match(source, /nie są wiążące/u);
  assert.match(source, /nie oznaczają potwierdzenia\s+rzeczywistego terminu/u);
  assert.match(source, /oficjalnym uruchomieniu rezerwacji poinformujemy/u);
});

test("warning is semantic and does not rely on color alone", () => {
  assert.match(source, /aria-labelledby="test-mode-warning-title"/u);
  assert.match(source, /<h2\s+[\s\S]*?id="test-mode-warning-title"/u);
  assert.match(source, />\s*TEST\s*</u);
  assert.match(source, /name="warning"/u);
});

test("home keeps the primary booking and events calls to action", () => {
  assert.match(source, /href="\/booking"/u);
  assert.match(source, /Zarezerwuj termin/u);
  assert.match(source, /href="\/events"/u);
  assert.match(source, /Szkolenia i eventy/u);
});

test("warning and CTA layout stay bounded and responsive", () => {
  assert.match(source, /flex min-w-0 items-start/u);
  assert.match(source, /min-w-0 flex-1/u);
  assert.match(source, /p-4[^"]*sm:p-5/u);
  assert.match(source, /grid gap-4 md:grid-cols-2/u);
  assert.doesNotMatch(source, /min-w-\[(?:[4-9]\d\d|\d{4,})px\]/u);
});
