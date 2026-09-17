import { expect, test } from "@playwright/test";

test.describe("SAAS-9D-4C app-first account lifecycle compatibility", () => {
  test("account surface and owner-only endpoints fail closed without a session", async ({
    page,
    request,
  }) => {
    const accountResponse = await page.goto("/account");
    expect(accountResponse?.status()).toBeLessThan(500);

    const exportResponse = await request.get("/api/account/export");
    expect(exportResponse.status()).toBe(401);
    expect(await exportResponse.json()).toMatchObject({
      ok: false,
      code: "unauthorized",
    });

    const deleteResponse = await request.post("/api/account/delete", {
      data: { confirmation: "USUŃ KONTO" },
    });
    expect(deleteResponse.status()).toBe(401);
    expect(await deleteResponse.json()).toMatchObject({
      ok: false,
      code: "unauthorized",
    });
  });
});
