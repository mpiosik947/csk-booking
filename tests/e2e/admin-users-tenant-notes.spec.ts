import { randomUUID } from "node:crypto";
import { spawnSync } from "node:child_process";
import { createClient } from "@supabase/supabase-js";
import { expect, test, type Page } from "@playwright/test";
import { getLocalSupabaseTestEnvironment } from "./local-supabase";

const environment = getLocalSupabaseTestEnvironment();
const service = createClient(environment.supabaseUrl, environment.serviceRoleKey, {
  auth: { autoRefreshToken: false, persistSession: false },
});
const runMarker = `${Date.now()}-${randomUUID().slice(0, 8)}`;
const adminEmail = `test-9d4b1a-admin-${runMarker}@example.invalid`;
const targetEmail = `test-9d4b1a-user-${runMarker}@example.invalid`;
const password = `Local-9D4B1A-${randomUUID()}!Aa1`;
const note = `[TEST][SAAS-9D-4B-1A][${runMarker}] tenant note`;
const CSK_ID = "c5c00000-0000-4000-8000-000000000001";
let adminUserId = "";
let targetUserId = "";

function assertNoError(error: { message: string } | null, context: string) {
  if (error) throw new Error(`${context}: ${error.message}`);
}

async function createUser(email: string) {
  const { data, error } = await service.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
    user_metadata: { test_marker: "[TEST][SAAS-9D-4B-1A-E2E]" },
  });
  assertNoError(error, `create ${email}`);
  if (!data.user) throw new Error(`User ${email} was not created.`);
  return data.user.id;
}

async function login(page: Page) {
  await page.goto("/login");
  await page.getByLabel("E-mail").fill(adminEmail);
  await page.getByLabel("Hasło").fill(password);
  await page.getByRole("button", { name: "Zaloguj się" }).click();
  await expect(page).toHaveURL(/\/dashboard$/u);
}

test.describe.serial("SAAS-9D-4B-1A admin user tenant notes", () => {
  test.beforeAll(async () => {
    adminUserId = await createUser(adminEmail);
    targetUserId = await createUser(targetEmail);

    const { error: profileError } = await service.from("profiles").upsert(
      [
        {
          user_id: adminUserId,
          email: adminEmail,
          first_name: "Test",
          last_name: "Administrator 9D4B1A",
          full_name: "[TEST] Administrator 9D4B1A",
          role: "admin",
          verification_status: "verified",
        },
        {
          user_id: targetUserId,
          email: targetEmail,
          first_name: "Test",
          last_name: "Użytkownik 9D4B1A",
          full_name: "[TEST] Użytkownik 9D4B1A",
          role: "user",
          verification_status: "verified",
        },
      ],
      { onConflict: "user_id" },
    );
    assertNoError(profileError, "configure profiles");
    const membershipSetup = spawnSync(
      "docker",
      ["exec", "-i", "supabase_db_csk-booking", "psql", "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", "postgres", "-At"],
      {
        encoding: "utf8",
        input: `insert into public.tenant_memberships(tenant_id,user_id,role,status) values ('${CSK_ID}','${adminUserId}','admin','active'),('${CSK_ID}','${targetUserId}','user','active') on conflict (tenant_id,user_id) do update set role=excluded.role,status=excluded.status;\nselect count(*) from public.tenant_memberships where tenant_id='${CSK_ID}' and user_id in ('${adminUserId}','${targetUserId}') and status='active';`,
      },
    );
    if (membershipSetup.status !== 0 || membershipSetup.stdout.trim().split(/\r?\n/u).at(-1) !== "2") {
      throw new Error(`Local membership fixture setup failed: ${membershipSetup.stderr || membershipSetup.stdout}`);
    }
  });

  test.afterAll(async () => {
    const userIds = [targetUserId, adminUserId].filter(Boolean);
    if (userIds.length === 0) return;
    const sqlIds = userIds.map((userId) => `'${userId}'::uuid`).join(",");
    const cleanup = spawnSync(
      "docker",
      ["exec", "-i", "supabase_db_csk-booking", "psql", "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", "postgres", "-At"],
      {
        encoding: "utf8",
        input: `delete from auth.users where id in (${sqlIds});\nselect count(*) from auth.users where id in (${sqlIds});`,
      },
    );
    if (cleanup.status !== 0 || cleanup.stdout.trim().split(/\r?\n/u).at(-1) !== "0") {
      throw new Error(`Local fixture cleanup failed: ${cleanup.stderr || cleanup.stdout}`);
    }
  });

  test("admin reads and writes a related user's tenant-scoped note", async ({ page }) => {
    await page.setViewportSize({ width: 375, height: 850 });
    await login(page);
    await page.goto(`/admin/users?search=${encodeURIComponent(targetEmail)}`);

    const targetCard = page.locator("article").filter({ hasText: targetEmail });
    await expect(targetCard).toBeVisible();
    await targetCard.getByRole("button", { name: "Szczegóły" }).click();
    const dialog = page.getByRole("dialog");
    await expect(dialog).toBeVisible();
    const noteInput = dialog.getByLabel("Treść notatki administratora");
    await noteInput.fill(note);
    await dialog.getByRole("button", { name: "Zapisz notatkę" }).click();
    await expect(
      dialog.getByRole("status").filter({
        hasText: "Notatka administratora została zapisana.",
      }),
    ).toBeVisible();
    await expect(noteInput).toHaveValue(note);

    await page.reload();
    const reloadedTargetCard = page.locator("article").filter({ hasText: targetEmail });
    await expect(reloadedTargetCard).toBeVisible();
    await reloadedTargetCard.getByRole("button", { name: "Szczegóły" }).click();
    await expect(
      page.getByRole("dialog").getByLabel("Treść notatki administratora"),
    ).toHaveValue(note);

    const { data: profile, error: profileError } = await service
      .from("profiles")
      .select("admin_note")
      .eq("user_id", targetUserId)
      .single();
    assertNoError(profileError, "verify frozen legacy note");
    expect(profile?.admin_note).toBeNull();
  });
});
