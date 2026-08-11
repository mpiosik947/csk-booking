import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const componentUrl = new URL(
  "./HierarchyResourcePresentation.tsx",
  import.meta.url
);

test("shared hierarchy presentation exposes type and textual activity badges", async () => {
  const source = await readFile(componentUrl, "utf8");

  assert.match(source, /export function ResourceTypeBadge/);
  assert.match(source, /isPosition \? "Stanowisko" : "Oś"/);
  assert.match(source, /export function ResourceStatusBadge/);
  assert.match(source, /isActive \? "Aktywne" : "Nieaktywne"/);
  assert.match(source, /border-\[#3f6848\][\s\S]*text-\[#a9d4ad\]/);
  assert.match(source, /border-\[#343a31\][\s\S]*text-\[#858c7f\]/);
});

test("shared label keeps a full generic display name and optional tree cue", async () => {
  const source = await readFile(componentUrl, "utf8");

  assert.match(source, /export function HierarchyResourceLabel/);
  assert.match(source, /resource\.displayName/);
  assert.match(source, /tree && resource\.depth === 1/);
  assert.match(source, /aria-hidden="true"/);
  assert.match(source, /ResourceTypeBadge/);
  assert.match(source, /ResourceStatusBadge/);
  assert.match(source, /min-w-0 max-w-full flex-wrap/);
});

test("shared presentation contains no production lane assumptions", async () => {
  const source = await readFile(componentUrl, "utf8");

  assert.doesNotMatch(source, /Oś 100 m/i);
  assert.doesNotMatch(source, /Stanowisko 1/i);
  assert.doesNotMatch(
    source,
    /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i
  );
});
