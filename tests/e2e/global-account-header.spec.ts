import { randomUUID } from "node:crypto";
import { createClient } from "@supabase/supabase-js";
import { expect, test } from "@playwright/test";
import { getLocalSupabaseTestEnvironment } from "./local-supabase";

const local = getLocalSupabaseTestEnvironment();
const service = createClient(local.supabaseUrl, local.serviceRoleKey, {
  auth: { persistSession: false, autoRefreshToken: false },
});

for (const named of [true, false]) {
  test(`global account greeting, responsive layout and real local logout: name=${named}`, async ({ page }, testInfo) => {
    const marker = randomUUID();
    const email = `account-header-${marker}@example.invalid`;
    const password = `Local-${marker}!Aa1`;
    const { data, error } = await service.auth.admin.createUser({
      email, password, email_confirm: true,
      user_metadata: named ? { first_name: "Michał", last_name: "Testowy" } : {},
    });
    if (error || !data.user) throw new Error(error?.message ?? "Local fixture failed");
    const id = data.user.id;
    try {
      await page.goto("/login");
      await page.getByLabel("E-mail").fill(email);
      await page.getByLabel("Hasło").fill(password);
      await page.getByRole("button", { name: "Zaloguj się", exact: true }).click();
      await expect(page).toHaveURL(/\/dashboard$/);
      for (const path of ["dashboard", "account"]) {
        await page.goto(`/${path}`);
        const header = page.getByTestId("global-account-header");
        await expect(header.getByText(named ? "Witaj, Michał" : "Witaj", { exact: true })).toBeVisible();
        await expect(header.getByRole("button", { name: "Wyloguj", exact: true })).toBeVisible();
        for (const width of [375, 1440]) {
          await page.setViewportSize({ width, height: 1000 });
          expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
          if (path === "dashboard") {
            const emailText = page.getByTestId("account-email");
            await expect(emailText).toHaveText(email);
            expect(await emailText.evaluate(element => {
              const parent = element.parentElement!;
              const bounds = parent.getBoundingClientRect();
              return [...element.getClientRects()].every(rect => rect.left >= bounds.left && rect.right <= bounds.right);
            })).toBe(true);
          }
          if (named) await page.screenshot({ path: testInfo.outputPath(`${path}-${width}.png`), fullPage: false });
        }
      }
      // Only the destination document is stubbed; Supabase signOut is real and local.
      await page.route("https://strzelajtu.pl/", route => route.fulfill({ body: "Platform home", contentType: "text/html" }));
      const logoutResponse = page.waitForResponse(response => response.url().includes("/auth/v1/logout"));
      await page.getByRole("button", { name: "Wyloguj", exact: true }).click();
      expect((await logoutResponse).ok()).toBe(true);
      await expect(page).toHaveURL("https://strzelajtu.pl/");
      await page.goto("/account");
      await expect(page.getByText("Logowanie wymagane", { exact: true })).toBeVisible();
      await expect(page.getByTestId("global-account-header")).toHaveCount(0);
    } finally {
      const cleanup = await service.auth.admin.deleteUser(id);
      if (cleanup.error) throw cleanup.error;
      const remaining = await service.auth.admin.getUserById(id);
      expect(remaining.data.user).toBeNull();
    }
  });
}
