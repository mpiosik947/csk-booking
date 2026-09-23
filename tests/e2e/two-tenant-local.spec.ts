import { randomUUID } from "node:crypto";
import { execFileSync } from "node:child_process";
import { createClient } from "@supabase/supabase-js";
import { expect, test } from "@playwright/test";
import { getLocalSupabaseTestEnvironment } from "./local-supabase";

const env = getLocalSupabaseTestEnvironment();
const service = createClient(env.supabaseUrl, env.serviceRoleKey, {
  auth: { autoRefreshToken: false, persistSession: false },
});
const TENANT_A = "c5c00000-0000-4000-8000-000000000001";

function localSql(sql: string) {
  return execFileSync("docker", [
    "exec", "supabase_db_csk-booking", "psql", "-X", "-v", "ON_ERROR_STOP=1",
    "-U", "postgres", "-d", "postgres", "-c", sql,
  ], { encoding: "utf8" });
}

async function login(page: import("@playwright/test").Page, email: string, password: string) {
  await page.goto("/login");
  await page.getByLabel("E-mail").fill(email);
  await page.getByLabel("Hasło").fill(password);
  await page.getByRole("button", { name: "Zaloguj się" }).click();
  await expect(page).toHaveURL(/\/dashboard$/);
}

test("two active local tenants stay isolated across selector, public, and staff routes", async ({ browser }) => {
  const runId = randomUUID();
  const tenantB = randomUUID();
  const slugB = `saas9g-${runId}`;
  const password = `Local-SaaS9G-${runId}!Aa1`;
  const accounts = await Promise.all(["shared", "admin-a", "admin-b"].map(async (kind) => {
    const email = `saas9g-${kind}-${runId}@example.invalid`;
    const result = await service.auth.admin.createUser({
      email, password, email_confirm: true,
      user_metadata: { test_marker: "[TEST][SAAS-9G]" },
    });
    if (result.error || !result.data.user) {
      throw new Error(`Cannot create ${kind} fixture: ${result.error?.code}`);
    }
    return { kind, email, id: result.data.user.id };
  }));
  const shared = accounts.find((account) => account.kind === "shared")!;
  const adminA = accounts.find((account) => account.kind === "admin-a")!;
  const adminB = accounts.find((account) => account.kind === "admin-b")!;

  try {
    localSql(`
      drop index public.tenants_single_active_runtime_guard;
      insert into public.tenants(id,name,slug,status)
      values ('${tenantB}','[TEST][SAAS-9G] Tenant B','${slugB}','active');
      insert into public.tenant_memberships(tenant_id,user_id,role,status) values
        ('${TENANT_A}','${shared.id}','user','active'),
        ('${tenantB}','${shared.id}','user','active'),
        ('${TENANT_A}','${adminA.id}','admin','active'),
        ('${tenantB}','${adminB.id}','admin','active');
    `);

    const sharedContext = await browser.newContext();
    const sharedPage = await sharedContext.newPage();
    await login(sharedPage, shared.email, password);
    await expect(sharedPage.getByRole("heading", { name: "Twoje lokalizacje" })).toBeVisible();
    await expect(sharedPage.getByRole("heading", { name: "CSK" })).toBeVisible();
    await expect(sharedPage.getByRole("heading", { name: "[TEST][SAAS-9G] Tenant B" })).toBeVisible();
    const cskCard = sharedPage.getByRole("heading", { name: "CSK" }).locator("..");
    const tenantBCard = sharedPage.getByRole("heading", { name: "[TEST][SAAS-9G] Tenant B" }).locator("..");
    await expect(cskCard.getByRole("link", { name: "Zarezerwuj oś" })).toHaveAttribute("href", "/t/csk/booking");
    await expect(tenantBCard.getByRole("link", { name: "Zarezerwuj oś" })).toHaveAttribute("href", `/t/${slugB}/booking`);
    await sharedPage.goto("/t/csk/booking");
    await expect(sharedPage.getByRole("heading", { name: "Zarezerwuj oś" })).toBeVisible();
    await sharedPage.goto(`/t/${slugB}/booking`);
    await expect(sharedPage.getByRole("heading", { name: "Zarezerwuj oś" })).toBeVisible();
    await sharedPage.goto(`/t/${slugB}/events`);
    await expect(sharedPage.getByRole("heading", { name: "Eventy i szkolenia" })).toBeVisible();
    await sharedContext.close();

    const adminAContext = await browser.newContext();
    const adminAPage = await adminAContext.newPage();
    await login(adminAPage, adminA.email, password);
    await adminAPage.goto("/t/csk/admin");
    await expect(adminAPage.getByRole("heading", { name: "Dashboard operacyjny" })).toBeVisible();
    await adminAPage.goto(`/t/${slugB}/admin`);
    await expect(adminAPage.getByText(/Brak dostępu|404/u)).toBeVisible();
    await adminAContext.close();

    const adminBContext = await browser.newContext();
    const adminBPage = await adminBContext.newPage();
    await login(adminBPage, adminB.email, password);
    await adminBPage.goto(`/t/${slugB}/admin`);
    await expect(adminBPage.getByRole("heading", { name: "Dashboard operacyjny" })).toBeVisible();
    await adminBPage.goto("/t/csk/admin");
    await expect(adminBPage.getByText(/Brak dostępu|404/u)).toBeVisible();
    await adminBContext.close();
  } finally {
    try {
      localSql(`
        delete from public.tenant_memberships where tenant_id='${tenantB}'
          or user_id in ('${shared.id}','${adminA.id}','${adminB.id}');
        delete from public.tenants where id='${tenantB}';
        create unique index if not exists tenants_single_active_runtime_guard
          on public.tenants ((true)) where status='active';
      `);
    } finally {
      for (const account of accounts) {
        const result = await service.auth.admin.deleteUser(account.id);
        if (result.error) throw new Error(`Cannot clean ${account.kind}: ${result.error.code}`);
      }
    }
    const cleanup = localSql(`
      select
        (select count(*) from public.tenants where id='${tenantB}') as tenants,
        (select count(*) from public.tenant_memberships where tenant_id='${tenantB}') as memberships,
        (select count(*) from auth.users where id in ('${shared.id}','${adminA.id}','${adminB.id}')) as users;
    `);
    if (!/\b0\s*\|\s*0\s*\|\s*0\b/u.test(cleanup)) {
      throw new Error(`SAAS-9G fixture cleanup failed: ${cleanup}`);
    }
  }
});
