import { expect, test } from "@playwright/test";
import { randomUUID } from "node:crypto";
import { execFileSync } from "node:child_process";
import { getLocalSupabaseTestEnvironment } from "./local-supabase";

for (const width of [375, 430, 768, 1440]) {
  test(`public subpages and landing links at ${width}px`, async ({ page }, info) => {
    await page.setViewportSize({ width, height: 1000 });
    for (const [label, route] of [["Cennik", "cennik"], ["O obiekcie", "o-obiekcie"], ["Kontakt i lokalizacja", "kontakt"]]) {
      await page.goto("/csk-krutla");
      const link = page.getByRole("link", { name: new RegExp(label) });
      await expect(link).toHaveAttribute("href", `/csk-krutla/${route}`);
      await link.click();
      await expect(page).toHaveURL(new RegExp(`/csk-krutla/${route}$`));
      await expect(page.getByRole("heading", { name: label, exact: true })).toBeVisible();
      expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
      if (route === "cennik") await expect(page.getByRole("link", { name: "Zarezerwuj termin", exact: true })).toHaveAttribute("href", "/t/csk/booking");
      await page.screenshot({ path: info.outputPath(`${route}-${width}.png`), fullPage: true });
    }
  });
}
test("unknown public subpages are safe 404; spoofed query cannot select tenant", async ({ page }) => {
  for (const route of ["cennik", "o-obiekcie", "kontakt"]) {
    const response = await page.goto(`/unknown-public-fixture-9283/${route}?tenant_id=csk&show_contact=true`);
    expect(response?.status()).toBe(404);
    await expect(page.getByRole("heading", { name: /Cennik|Kontakt i lokalizacja|O obiekcie/ })).toHaveCount(0);
  }
});

test("real local DB visibility, private/suspended routes and tenant data isolation", async ({ page }) => {
  test.setTimeout(120_000);
  getLocalSupabaseTestEnvironment(); // Refuses non-loopback environments.
  const a = randomUUID(); const b = randomUUID();
  const slug = `sp-${a}`; const publicSlug = `pub-${a}`;
  const sql = (query: string) => execFileSync("docker", ["exec", "supabase_db_csk-booking", "psql", "-X", "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", "postgres", "-Atc", query], { encoding: "utf8" });
  try {
    sql(`BEGIN;
      insert into public.tenants(id,name,slug,status) values ('${a}','Subpage A','${slug}','active'),('${b}','Subpage B','sp-${b}','active');
      insert into public.tenant_plan_assignments(tenant_id,plan_id,status) select t.id,p.id,'active' from public.tenants t cross join public.saas_plans p where t.id in ('${a}','${b}') and p.plan_key='current_full_v1';
      insert into public.tenant_public_profiles(tenant_id,display_name,city,is_public,public_slug,description,public_address)
      values ('${a}','Subpage A','Miasto A',true,'${publicSlug}','Opis tylko A','Adres tylko A'),('${b}','Subpage B','Miasto B',true,'pub-${b}','Opis tylko B','Adres tylko B'); COMMIT;`);
    for (let mask = 0; mask < 8; mask++) {
      sql(`update public.tenant_public_profiles set show_pricing=${Boolean(mask & 1)},show_about=${Boolean(mask & 2)},show_contact=${Boolean(mask & 4)} where tenant_id='${a}';`);
      for (const [bit, route] of ["cennik", "o-obiekcie", "kontakt"].entries()) {
        const response = await page.goto(`/${publicSlug}/${route}?tenant_id=${b}`);
        expect(response?.status()).toBe(mask & (1 << bit) ? 200 : 404);
        const html = await page.content();
        expect(html).not.toContain("Opis tylko B");
        expect(html).not.toContain("Adres tylko B");
        // Query parameters may be echoed by Next; check rendered public content.
        expect(await page.locator("body").innerText()).not.toContain(a);
        expect(await page.locator("body").innerText()).not.toContain(b);
      }
    }
    sql(`delete from public.tenant_plan_assignments where tenant_id='${a}';`);
    expect((await page.goto(`/${publicSlug}/cennik`))?.status()).toBe(404);
    expect((await page.goto(`/${publicSlug}/o-obiekcie`))?.status()).toBe(200);
    await expect(page.getByText("Opis tylko A", { exact: true })).toBeVisible();
    expect((await page.goto(`/${publicSlug}/kontakt`))?.status()).toBe(200);
    await expect(page.getByText("Adres tylko A", { exact: true })).toBeVisible();
    for (const state of ["private", "suspended"]) {
      sql(state === "private" ? `update public.tenant_public_profiles set is_public=false where tenant_id='${a}';`
        : `update public.tenant_public_profiles set is_public=true where tenant_id='${a}'; update public.tenants set status='suspended' where id='${a}';`);
      for (const route of ["cennik", "o-obiekcie", "kontakt"]) expect((await page.goto(`/${publicSlug}/${route}`))?.status()).toBe(404);
    }
  } finally {
    sql(`BEGIN; delete from public.audit_logs where tenant_id in ('${a}','${b}'); delete from public.tenant_public_profiles where tenant_id in ('${a}','${b}'); delete from public.tenant_plan_assignments where tenant_id in ('${a}','${b}'); delete from public.tenants where id in ('${a}','${b}'); COMMIT;`);
    expect(sql(`select count(*) from public.tenants where id in ('${a}','${b}');`).trim()).toBe("0");
  }
});
