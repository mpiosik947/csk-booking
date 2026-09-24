import { randomUUID } from "node:crypto";
import { execFileSync } from "node:child_process";
import { createClient } from "@supabase/supabase-js";
import { expect, test } from "@playwright/test";
import { getLocalSupabaseTestEnvironment } from "./local-supabase";

const env=getLocalSupabaseTestEnvironment();
const service=createClient(env.supabaseUrl,env.serviceRoleKey,{auth:{autoRefreshToken:false,persistSession:false}});
function localSql(sql:string){return execFileSync("docker",["exec","supabase_db_csk-booking","psql","-X","-v","ON_ERROR_STOP=1","-U","postgres","-d","postgres","-c",sql],{encoding:"utf8"});}

test("tenant admin settings are isolated, responsive, and visibility is presentation-only",async({page})=>{
  const run=randomUUID(); const tenant=randomUUID(); const slug=`p10c-${run}`; const publicSlug=`public-${run}`;
  const email=`p10c-${run}@example.invalid`; const password=`Local-P10C-${run}!Aa1`;
  const created=await service.auth.admin.createUser({email,password,email_confirm:true,user_metadata:{test_marker:"[TEST][PRODUCT-10C]"}});
  if(created.error||!created.data.user)throw new Error(`Cannot create PRODUCT-10C admin: ${created.error?.code}`);
  const user=created.data.user;
  try{
    localSql(`insert into public.tenants(id,name,slug,status) values('${tenant}','[TEST][PRODUCT-10C]','${slug}','active');
      insert into public.tenant_memberships(tenant_id,user_id,role,status) values('${tenant}','${user.id}','admin','active');
      insert into public.tenant_public_profiles(tenant_id,display_name,city,is_public,public_slug) values('${tenant}','Testowa Strzelnica','Testowo',true,'${publicSlug}');`);
    await page.goto("/login"); await page.getByLabel("E-mail").fill(email); await page.getByLabel("Hasło").fill(password);
    await page.getByRole("button",{name:"Zaloguj się"}).click(); await expect(page).toHaveURL(/\/dashboard$/u);
    await page.goto(`/t/${slug}/admin/settings`); await expect(page.getByRole("heading",{name:"Ustawienia publiczne"})).toBeVisible();
    await page.getByLabel("Adres").fill("Testowa 10"); await page.getByLabel("Telefon").fill("+48 123 456 789");
    await page.getByLabel("E-mail",{exact:true}).fill("public@example.invalid"); await page.getByLabel("Godziny otwarcia").fill("Pon-Pt 10-18");
    for(const label of ["Rezerwacja","Instruktor","O obiekcie","Regulamin"]){await page.getByLabel(label,{exact:true}).uncheck();}
    await page.getByRole("button",{name:"Zapisz ustawienia"}).click(); await expect(page.getByText("Ustawienia publiczne zostały zapisane.")).toBeVisible();
    for(const width of [320,375,430]){await page.setViewportSize({width,height:850}); expect(await page.evaluate(()=>document.documentElement.scrollWidth<=window.innerWidth)).toBe(true);}
    await page.goto(`/${publicSlug}`); await expect(page.getByText("Testowa 10")).toBeVisible(); await expect(page.getByText("public@example.invalid")).toBeVisible();
    await expect(page.getByRole("link",{name:"Zarezerwuj termin"})).toHaveCount(0); await expect(page.getByText("Strzelanie z instruktorem")).toHaveCount(0); await expect(page.getByRole("heading",{name:"O obiekcie"})).toHaveCount(0);
    await expect(page.getByRole("link",{name:"Szkolenia i eventy"}).first()).toBeVisible();
    await page.goto(`/t/${slug}/booking`); await expect(page.getByRole("heading",{name:"Zarezerwuj oś"})).toBeVisible();
  }finally{
    localSql(`delete from public.audit_logs where tenant_id='${tenant}'; delete from public.tenant_memberships where tenant_id='${tenant}'; delete from public.tenant_public_profiles where tenant_id='${tenant}'; delete from public.tenants where id='${tenant}';`);
    const removed=await service.auth.admin.deleteUser(user.id); if(removed.error)throw new Error(`Cannot clean PRODUCT-10C admin: ${removed.error.code}`);
    const cleanup=localSql(`select (select count(*) from public.tenants where id='${tenant}') as tenants,(select count(*) from public.tenant_memberships where tenant_id='${tenant}') as memberships,(select count(*) from auth.users where id='${user.id}') as users,(select count(*) from public.audit_logs where tenant_id='${tenant}') as audit;`);
    if(!/\b0\s*\|\s*0\s*\|\s*0\s*\|\s*0\b/u.test(cleanup))throw new Error(`PRODUCT-10C cleanup failed: ${cleanup}`);
  }
});
