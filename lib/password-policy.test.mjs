import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  getPasswordLengthError,
  PASSWORD_MAX_LENGTH,
  PASSWORD_MAX_LENGTH_MESSAGE,
  PASSWORD_MIN_LENGTH,
  PASSWORD_MIN_LENGTH_MESSAGE,
} from "./password-policy.ts";

test("SEC-010 uses one 12-72 character application policy", () => {
  assert.equal(PASSWORD_MIN_LENGTH, 12);
  assert.equal(PASSWORD_MAX_LENGTH, 72);
  assert.equal(PASSWORD_MIN_LENGTH_MESSAGE, "Hasło musi mieć minimum 12 znaków.");
  assert.equal(PASSWORD_MAX_LENGTH_MESSAGE, "Hasło może mieć maksymalnie 72 znaki.");
});

test("SEC-010 rejects 5, 6, 8 and 11 characters", () => {
  for (const length of [5, 6, 8, 11]) {
    assert.equal(
      getPasswordLengthError("a".repeat(length)),
      PASSWORD_MIN_LENGTH_MESSAGE,
      `${length} characters must be denied`
    );
  }
});

test("SEC-010 accepts 12 characters and longer passwords through 72", () => {
  for (const length of [12, 24, 64, 72]) {
    assert.equal(
      getPasswordLengthError("a".repeat(length)),
      null,
      `${length} characters must pass application validation`
    );
  }
});

test("SEC-010 rejects passwords above the provider maximum", () => {
  assert.equal(
    getPasswordLengthError("a".repeat(73)),
    PASSWORD_MAX_LENGTH_MESSAGE
  );
});

const passwordFlowPaths = [
  "../app/register/page.tsx",
  "../app/reset-password/page.tsx",
  "../app/account/page.tsx",
];

test("register, reset and account use the shared policy and truthful controls", async () => {
  for (const path of passwordFlowPaths) {
    const source = await readFile(new URL(path, import.meta.url), "utf8");

    assert.match(source, /getPasswordLengthError/u, path);
    assert.match(source, /minLength=\{PASSWORD_MIN_LENGTH\}/u, path);
    assert.match(source, /maxLength=\{PASSWORD_MAX_LENGTH\}/u, path);
    assert.doesNotMatch(source, /password\.length\s*<\s*[68]/u, path);
    assert.doesNotMatch(source, /newPassword\.length\s*<\s*[68]/u, path);
    assert.doesNotMatch(source, /[Mm]inimum [68] znak/u, path);
  }
});

test("local validation runs before each Supabase password mutation", async () => {
  const register = await readFile(
    new URL("../app/register/page.tsx", import.meta.url),
    "utf8"
  );
  const reset = await readFile(
    new URL("../app/reset-password/page.tsx", import.meta.url),
    "utf8"
  );
  const account = await readFile(
    new URL("../app/account/page.tsx", import.meta.url),
    "utf8"
  );
  const accountPasswordFlow = account.slice(account.indexOf("async function changePassword"));

  assert.ok(register.indexOf("getPasswordLengthError(password)") < register.indexOf("supabase.auth.signUp"));
  assert.ok(reset.indexOf("getPasswordLengthError(password)") < reset.indexOf("supabase.auth.updateUser"));
  assert.ok(
    accountPasswordFlow.indexOf("getPasswordLengthError(newPassword)") <
      accountPasswordFlow.indexOf("supabase.auth.updateUser")
  );
});

test("login remains independent from new-password policy enforcement", async () => {
  const login = await readFile(
    new URL("../app/login/page.tsx", import.meta.url),
    "utf8"
  );

  assert.doesNotMatch(login, /getPasswordLengthError|PASSWORD_MIN_LENGTH/u);
  assert.match(login, /signInWithPassword/u);
});
