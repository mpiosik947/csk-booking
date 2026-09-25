import { test, expect } from "@playwright/test";
import { execFileSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { getLocalSupabaseTestEnvironment } from "./local-supabase";

test("legacy hosts never initiate or complete auth and preserve only safe tenant context", async ({ request }) => {
  for(const host of ["krutla.pl","www.krutla.pl","csk-booking-5nwh.vercel.app"]) {
    const get=(path:string)=>request.get(path,{headers:{host,"x-forwarded-host":"evil.example"},maxRedirects:0});
    for(const path of ["/register","/forgot-password","/account","/booking","/events","/admin","/platform-admin"]){
      const response=await get(path); expect(response.status()).toBe(307);
      expect(response.headers().location).toBe(`https://strzelajtu.pl${path}#canonical`);
      expect(response.headers()["set-cookie"]).toBeUndefined();
    }
    const login=await get("/login?redirectTo=%2Ft%2Ftenant-a%2Fbooking");
    expect(login.headers().location).toBe("https://strzelajtu.pl/login?redirectTo=%2Ft%2Ftenant-a%2Fbooking#canonical");
    for(const bad of ["https://evil.example","//evil.example","javascript:alert(1)","/%2f%2fevil.example"]){
      expect((await get(`/login?redirectTo=${encodeURIComponent(bad)}`)).headers().location)
        .toBe("https://strzelajtu.pl/login?redirectTo=%2Fdashboard#canonical");
    }
    const callback=await get("/auth/callback?code=must-not-transfer&next=https://evil.example");
    expect(callback.status()).toBe(307);
    expect(callback.headers().location).toBe("https://strzelajtu.pl/login#canonical");
    expect(callback.headers()["set-cookie"]).toBeUndefined();
    const reset=await get("/reset-password?token=must-not-transfer");
    expect(reset.status()).toBe(307);
    expect(reset.headers().location).toBe("https://strzelajtu.pl/forgot-password#canonical");
    expect(reset.headers()["set-cookie"]).toBeUndefined();
    expect((await request.post("/auth/callback",{headers:{host},data:{}})).status()).toBe(404);
  }
});

test("verified custom hosts isolate public pages, caches, canonical and operational redirects", async ({ request }) => {
  test.setTimeout(120_000);
  const local=getLocalSupabaseTestEnvironment();
  const ports=execFileSync("docker",["port","supabase_db_csk-booking","5432/tcp"],{encoding:"utf8"});
  expect(ports.trim().split(/\r?\n/).every(line=>/^(?:0\.0\.0\.0|127\.0\.0\.1|\[::\]):54322$/.test(line))).toBe(true);
  const a=randomUUID(),b=randomUUID();
  const sql=(q:string)=>execFileSync("docker",["exec","-i","supabase_db_csk-booking","psql","-X","-At","-v","ON_ERROR_STOP=1","-U","postgres","-d","postgres"],{input:q,encoding:"utf8"});
  const get=(host:string,path:string,extra:Record<string,string>={})=>request.get(path,{headers:{host,...extra},maxRedirects:0});
  try {
    sql(`begin;
      insert into public.tenants(id,name,slug,status) values('${a}','DOMAIN ALPHA','domain-a-${a.slice(0,8)}','active'),('${b}','DOMAIN BETA','domain-b-${b.slice(0,8)}','active');
      insert into public.tenant_public_profiles(tenant_id,display_name,city,is_public,public_slug,description) values('${a}','DOMAIN ALPHA','Alpha',true,'domain-public-${a.slice(0,8)}','Alpha description'),('${b}','DOMAIN BETA','Beta',true,'domain-public-${b.slice(0,8)}','Beta description');
      insert into public.tenant_plan_assignments(tenant_id,plan_id,status) select t.id,p.id,'active' from public.tenants t cross join public.saas_plans p where t.id in('${a}','${b}') and p.plan_key='current_full_v1';
      insert into public.tenant_domains(tenant_id,hostname,domain_type,status,is_primary,verified_at) values('${a}','tenant-a.test','custom_domain','active',true,now()),('${b}','tenant-b.test','custom_domain','active',true,now());commit;`);
    const resolved=await request.post(`${local.supabaseUrl}/rest/v1/rpc/resolve_public_tenant_domain_v1`,{headers:{apikey:local.anonKey,Authorization:`Bearer ${local.anonKey}`},data:{p_hostname:"tenant-a.test"}});
    expect(resolved.status(),await resolved.text()).toBe(200);
    expect(await resolved.json()).toEqual({tenant_slug:`domain-a-${a.slice(0,8)}`,public_slug:`domain-public-${a.slice(0,8)}`});
    for(const [host,own,other] of [["tenant-a.test","DOMAIN ALPHA","DOMAIN BETA"],["tenant-b.test","DOMAIN BETA","DOMAIN ALPHA"],["tenant-b.test","DOMAIN BETA","DOMAIN ALPHA"],["tenant-a.test","DOMAIN ALPHA","DOMAIN BETA"]]) {
      for(const path of ["/","/cennik","/o-obiekcie","/kontakt"]) {
        const response=await get(host,path);expect(response.status(),`${host}${path}: ${(await response.text()).slice(0,150)}`).toBe(200);
        const html=await response.text();expect(html).toContain(own);expect(html).not.toContain(other);
        expect(html).not.toContain(a);expect(html).not.toContain(b);
        expect(response.headers()["cache-control"]).toContain("no-store");
        expect(html).toContain(`https://${host}${path}`);
        expect(response.headers()["set-cookie"]).toBeUndefined();
      }
    }
    const landing=await (await get("tenant-a.test","/")).text();
    expect(landing).toContain(`https://strzelajtu.pl/t/domain-a-${a.slice(0,8)}/booking`);
    for(const path of ["/booking","/events","/admin"]) expect((await get("tenant-a.test",path)).headers().location).toBe(`https://strzelajtu.pl/t/domain-a-${a.slice(0,8)}${path}`);
    expect((await get("tenant-a.test","/login?redirectTo=https://evil.test")).headers().location).toBe(`https://strzelajtu.pl/login?redirectTo=%2Ft%2Fdomain-a-${a.slice(0,8)}%2Fbooking`);
    expect((await get("tenant-a.test","/platform-admin")).headers().location).toBe("https://strzelajtu.pl/platform-admin");
    expect((await get("tenant-a.test","/unknown")).status()).toBe(404);
    expect((await get("unknown.test","/",{"x-forwarded-host":"tenant-a.test",forwarded:"host=tenant-a.test"})).status()).toBe(404);
    const forged=await (await get("tenant-a.test","/",{"x-forwarded-host":"tenant-b.test",forwarded:"host=tenant-b.test"})).text();
    expect(forged).toContain("DOMAIN ALPHA");expect(forged).not.toContain("DOMAIN BETA");
    expect((await request.get(`/domain-view.internal/tenant-a.test`)).status()).toBe(404);
    expect((await request.post("/api/create-reservation",{headers:{host:"tenant-a.test"},data:{}})).status()).toBe(404);
    sql(`update public.tenant_public_profiles set show_pricing=false,show_about=false,show_contact=false where tenant_id='${a}';`);
    for(const path of ["/cennik","/o-obiekcie","/kontakt"]) expect((await get("tenant-a.test",path)).status()).toBe(404);
    sql(`update public.tenant_domains set status='disabled',is_primary=false where tenant_id='${a}';`);
    expect((await get("tenant-a.test","/")).status()).toBe(404);
    expect((await get("tenant-b.test","/")).status()).toBe(200);
  } finally {
    sql(`begin; delete from public.tenant_domains where tenant_id in('${a}','${b}');delete from public.tenant_plan_assignments where tenant_id in('${a}','${b}');delete from public.tenant_public_profiles where tenant_id in('${a}','${b}');delete from public.tenants where id in('${a}','${b}');commit;`);
    expect(sql(`select count(*) from public.tenants where id in('${a}','${b}');`).trim()).toBe("0");
  }
});
