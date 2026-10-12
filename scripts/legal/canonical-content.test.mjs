import test from "node:test";
import assert from "node:assert/strict";
import { canonicalize, contentSnapshot } from "./canonical-content.mjs";

test("reviewed content ignores source formatting and key order, not textual meaning", () => {
  const a = { title: "Zażółć", blocks: [{ type: "paragraph", text: "A\r\nB" }] };
  const b = { blocks: [{ text: "A\nB", type: "paragraph" }], title: "Zaz\u0307o\u0301łc\u0301" };
  assert.deepEqual(contentSnapshot(a), contentSnapshot(b));
  assert.notEqual(contentSnapshot(a).sha256, contentSnapshot({ ...a, title: "Zmiana" }).sha256);
  assert.notEqual(contentSnapshot(a).sha256, contentSnapshot({ ...a, blocks: [...a.blocks, ...a.blocks] }).sha256);
});
test("restricted canonical serialization has an independent known SHA-256 vector", () => {
  assert.equal(contentSnapshot({}).sha256, "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a");
  assert.equal(canonicalize({ z: [true, null, "\t\n😀"], a: "é" }), '{"a":"é","z":[true,null,"\\t\\n😀"]}');
});
test("unsupported values, controls, non-ASCII field names and oversized documents fail", () => {
  for (const value of [1, NaN, undefined, new Date(), { a: undefined }, { badKey: true }, { a: "\u0000" }, { a: "\ud800" }]) {
    assert.throws(() => canonicalize(value));
  }
  assert.throws(() => contentSnapshot({ text: "x".repeat(262144) }));
});
test("version policy and semantic kind participate in the reviewed content hash", () => {
  const base = { version: "v1", requires_reacceptance: true, evidence_kind: "acceptance" };
  for (const change of [{ version: "v2" }, { requires_reacceptance: false }, { evidence_kind: "acknowledgement" }]) {
    assert.notEqual(contentSnapshot(base).sha256, contentSnapshot({ ...base, ...change }).sha256);
  }
});
