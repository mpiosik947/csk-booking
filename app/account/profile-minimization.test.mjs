import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import ts from "typescript";

// Exercise the actual page predicates without loading Next or contacting Auth.
function pageFunction(relativePath, name, bindings = {}) {
  const source = readFileSync(new URL(relativePath, import.meta.url), "utf8");
  const file = ts.createSourceFile("page.tsx", source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
  let found;
  function visit(node) {
    if (ts.isFunctionDeclaration(node) && node.name?.text === name) found = node;
    ts.forEachChild(node, visit);
  }
  visit(file);
  assert.ok(found, name);
  const js = ts.transpileModule(found.getText(file), {
    compilerOptions: { target: ts.ScriptTarget.ES2022 },
  }).outputText;
  return Function(...Object.keys(bindings), `${js}\nreturn ${name};`)(...Object.values(bindings));
}

const contact = {
  phone: "500000000", postalCode: "00-001", city: "Testowo", street: "Testowa",
  houseNumber: "1", apartmentNumber: "2",
};
const validate = (values) => pageFunction("./page.tsx", "validateProfile", values)();

for (const field of ["postalCode", "city", "street", "houseNumber", "apartmentNumber"]) {
  test(`profile saves without ${field} and accepts an optional value`, () => {
    assert.equal(validate({ ...contact, [field]: "" }), "");
    assert.equal(validate(contact), "");
  });
}

test("all residential fields may be empty; contact phone remains required", () => {
  const emptyAddress = { phone: "500000000", postalCode: "", city: "", street: "", houseNumber: "", apartmentNumber: "" };
  assert.equal(validate(emptyAddress), "");
  assert.equal(validate({ ...emptyAddress, phone: "   " }), "Uzupełnij numer telefonu.");
  assert.equal(validate({ ...emptyAddress, postalCode: "SW1A 1AA" }), "");
});

for (const [field, limit] of [["phone", 32], ["postalCode", 20], ["city", 120], ["street", 160], ["houseNumber", 30], ["apartmentNumber", 30]]) {
  test(`profile keeps the existing RPC ${field} length boundary`, () => {
    assert.equal(validate({ ...contact, [field]: "x".repeat(limit) }), "");
    assert.notEqual(validate({ ...contact, [field]: "x".repeat(limit + 1) }), "");
  });
}

test("staff completeness excludes address while retaining each existing name contract", () => {
  const missingUsers = pageFunction("../admin/users/page.tsx", "getMissingFields");
  const missingCheckIn = pageFunction("../admin/check-in/page.tsx", "getMissingFields");
  const completion = pageFunction("../admin/check-in/page.tsx", "getCompletionPercent");
  const profile = { first_name: "Test", last_name: "User", full_name: "Test User", phone: "500000000" };
  assert.deepEqual(missingUsers(profile), []);
  assert.deepEqual(missingCheckIn(profile), []);
  assert.equal(completion(profile), 100);
  assert.deepEqual(missingUsers({ ...profile, first_name: null }), ["imię i nazwisko"]);
  assert.deepEqual(missingCheckIn({ ...profile, full_name: null }), ["imię i nazwisko"]);
  assert.deepEqual(missingCheckIn({ ...profile, phone: null }), ["telefon"]);
  assert.equal(completion({ ...profile, phone: null }), 50);
  assert.deepEqual(missingCheckIn(null), ["brak profilu użytkownika"]);
  assert.equal(completion(null), 0);
});
