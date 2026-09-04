import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const privacyPageUrl = new URL("./page.tsx", import.meta.url);
const termsPageUrl = new URL("../terms/page.tsx", import.meta.url);
const homePageUrl = new URL("../page.tsx", import.meta.url);
const registerPageUrl = new URL("../register/page.tsx", import.meta.url);
const accountPageUrl = new URL("../account/page.tsx", import.meta.url);

async function readLegalSources() {
  const [privacy, terms] = await Promise.all([
    readFile(privacyPageUrl, "utf8"),
    readFile(termsPageUrl, "utf8"),
  ]);

  return { privacy, terms, combined: `${privacy}\n${terms}` };
}

test("privacy and terms pages no longer present general draft copy", async () => {
  const { privacy, terms, combined } = await readLegalSources();

  assert.match(privacy, /Ostatnia aktualizacja: 4 września 2026 r\./u);
  assert.doesNotMatch(combined, /wersj[ai] robocz/u);
  assert.doesNotMatch(combined, /example\.com|\bTODO\b/u);
  assert.match(privacy, /export default function PrivacyPage/u);
  assert.match(terms, /export default function TermsPage/u);
});

test("approved owner placeholders are explicit and limited to owner data", async () => {
  const { privacy } = await readLegalSources();

  assert.match(
    privacy,
    /DO UZUPEŁNIENIA PRZED FORMALNYM URUCHOMIENIEM USŁUGI/u,
  );
  for (const label of [
    "Nazwa / imię i nazwisko",
    "Forma prawna",
    "Adres",
    "Kontakt w sprawach prywatności",
  ]) {
    assert.match(privacy, new RegExp(`${label}: \\[DO UZUPEŁNIENIA\\]`, "u"));
  }

  assert.doesNotMatch(privacy, /NIP|REGON|KRS|Telefon:/u);
  assert.equal((privacy.match(/\[DO UZUPEŁNIENIA\]/gu) ?? []).length, 4);
});

test("privacy content reflects current PII and operational flows", async () => {
  const { privacy } = await readLegalSources();

  for (const expected of [
    "dane konta i profilu",
    "adres e-mail",
    "numer telefonu",
    "deklarowane uprawnienia i kwalifikacje",
    "dane rezerwacji",
    "dane zapisów na wydarzenia i szkolenia",
    "check-in",
    "status płatności",
    "wiadomości e-mail",
    "dane bezpieczeństwa i sesji",
    "ograniczania nadużyć",
    "logi audytowe",
  ]) {
    assert.match(privacy, new RegExp(expected, "u"));
  }

  for (const provider of ["Supabase", "Vercel", "Resend"]) {
    assert.match(privacy, new RegExp(provider, "u"));
  }
});

test("privacy content matches account export and anonymization lifecycle", async () => {
  const [privacy, account] = await Promise.all([
    readFile(privacyPageUrl, "utf8"),
    readFile(accountPageUrl, "utf8"),
  ]);

  assert.match(privacy, /Pobierz moje dane/u);
  assert.match(privacy, /Eksport nie zawiera haseł, tokenów/u);
  assert.match(privacy, /notatek administracyjnych/u);
  assert.match(
    privacy,
    /Użytkownik może również zażądać usunięcia własnego konta/u,
  );
  assert.match(privacy, /nieidentyfikujące dane operacyjne i\s+statystyczne/u);
  assert.match(privacy, /formie pseudonimizowanej/u);

  assert.match(account, /Pobierz moje dane/u);
  assert.match(account, /Historyczne rezerwacje i\s+zapisy na szkolenia/u);
  assert.match(account, /zanonimizowane\s+dane operacyjne i statystyczne/u);
});

test("all user-facing legal links target existing privacy and terms pages", async () => {
  const [privacy, terms, home, register] = await Promise.all([
    readFile(privacyPageUrl, "utf8"),
    readFile(termsPageUrl, "utf8"),
    readFile(homePageUrl, "utf8"),
    readFile(registerPageUrl, "utf8"),
  ]);

  assert.match(privacy, /href="\/terms"/u);
  assert.match(terms, /href="\/privacy"/u);
  assert.match(home, /href="\/terms"/u);
  assert.match(register, /href="\/terms"/u);
  assert.match(register, /href="\/privacy"/u);
});
