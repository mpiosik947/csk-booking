import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { runInNewContext } from "node:vm";
import test from "node:test";
import ts from "typescript";
const exports = {};
runInNewContext(ts.transpileModule(readFileSync(new URL("./public-tenant-content.ts", import.meta.url), "utf8"), {compilerOptions:{module:ts.ModuleKind.CommonJS}}).outputText, {exports, URL});
const parse = exports.parsePublicContent;
const valid = () => ({about_offer:"Oferta", about_audience:null, public_map_url:"https://maps.example.invalid/place", pricing_items:[{title:"Oferta",price:12.5,currency:"PLN",unit:"osoba",short_description:null}]});
test("public content accepts only bounded public display fields", () => { assert.ok(parse(valid())); });
test("public content excludes identifiers and internal metadata", () => {
  for (const key of ["tenant_id","memberships","admin_id","billing","entitlements","internal_notes","secret"]) {
    assert.equal(parse({...valid(),[key]:"private"}),null);
    const row=valid(); row.pricing_items[0][key]="private"; assert.equal(parse(row),null);
  }
});
test("public content rejects unsafe URLs and invalid prices", () => {
  for(const url of ["javascript:alert(1)","http://example.invalid","//example.invalid"]) assert.equal(parse({...valid(),public_map_url:url}),null);
  for(const price of [-1,Infinity,NaN,10000000,"12"]) {const row=valid();row.pricing_items[0].price=price;assert.equal(parse(row),null);}
});
test("public content supports fully masked response without empty fake content", () => {
  assert.ok(parse({about_offer:null,about_audience:null,public_map_url:null,pricing_items:[]}));
  assert.equal(parse(null),null); assert.equal(parse({}),null);
});
