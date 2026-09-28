import { test,expect } from '@playwright/test';
import { randomUUID } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { createClient } from '@supabase/supabase-js';
import { getLocalSupabaseTestEnvironment } from './local-supabase';
const env=getLocalSupabaseTestEnvironment();
const service=createClient(env.supabaseUrl,env.serviceRoleKey,{auth:{persistSession:false,autoRefreshToken:false}});
const marker=randomUUID(), b=randomUUID(), slug=`tiles-b-${marker.slice(0,8)}`;
const email=`tiles-${marker}@example.invalid`,password=`Local-${marker}!Aa1`;
let uid:string,csk:string;
function sql(query:string){return execFileSync('docker',['exec','supabase_db_csk-booking','psql','-X','-At','-v','ON_ERROR_STOP=1','-U','postgres','-d','postgres','-c',query],{encoding:'utf8'}).trim();}
test.beforeAll(async()=>{
 csk=sql("select id from public.tenants where slug='csk'");expect(csk).toMatch(/^[0-9a-f-]{36}$/);
 const {data,error}=await service.auth.admin.createUser({email,password,email_confirm:true,user_metadata:{first_name:'Michał',last_name:'Testowy'}});
 if(error||!data.user)throw Error('Local fixture creation failed');uid=data.user.id;
 sql(`begin; insert into public.tenants(id,slug,name,status) values('${b}','tech-${slug}','Synthetic Range B','active');
 insert into public.tenant_public_profiles(tenant_id,display_name,city,is_public,public_slug) values('${b}','Synthetic Range B','Miasto B',true,'${slug}');
 insert into public.tenant_plan_assignments(tenant_id,plan_id,status) select '${b}',id,'active' from public.saas_plans where plan_key='current_full_v1';commit;`);
});
test.afterAll(async()=>{
 if(uid){sql(`delete from public.tenant_memberships where user_id='${uid}'`);const {error}=await service.auth.admin.deleteUser(uid);if(error)throw error;}
 sql(`begin;delete from public.tenant_plan_assignments where tenant_id='${b}';delete from public.tenant_public_profiles where tenant_id='${b}';delete from public.tenants where id='${b}';commit;`);
 expect(sql(`select count(*) from public.tenants where id='${b}'`)).toBe('0');
});
const cases=[
 {name:'anonymous',role:null,tenant:'csk',width:1440},
 {name:'user',role:'user',tenant:'csk',width:1440},
 {name:'admin',role:'admin',tenant:'csk',width:1440},
 {name:'admin',role:'admin',tenant:'csk',width:375},
 {name:'admin',role:'admin',tenant:'csk',width:430},
 {name:'employee',role:'employee',tenant:'csk',width:1440},
 {name:'instructor',role:'instructor',tenant:'csk',width:1440},
 {name:'B-admin',role:'admin',tenant:'B',width:1440},
 {name:'B-user',role:'user',tenant:'B',width:1440},
 {name:'A-admin-on-B',role:'cross',tenant:'B',width:1440},
 {name:'inactive-admin',role:'inactive',tenant:'csk',width:1440},
];
for(const item of cases)test(`${item.name} ${item.width}`,async({page},info)=>{
 sql(`delete from public.tenant_memberships where user_id='${uid}'`);
 if(item.role){const target=item.role==='cross'?csk:item.tenant==='B'?b:csk;const role=['cross','inactive'].includes(item.role)?'admin':item.role;
 sql(`insert into public.tenant_memberships(tenant_id,user_id,role,status) values('${target}','${uid}','${role}','${item.role==='inactive'?'suspended':'active'}')`);
 await page.goto('/login');await page.getByLabel('E-mail',{exact:true}).fill(email);await page.getByLabel('Hasło',{exact:true}).fill(password);await page.getByRole('button',{name:'Zaloguj się',exact:true}).click();await expect(page).toHaveURL('http://127.0.0.1:3194/');}
 await page.setViewportSize({width:item.width,height:1100});const tech=item.tenant==='B'?`tech-${slug}`:'csk';
 await page.goto(item.tenant==='B'?`/${slug}`:'/csk-krutla');
 const auth=page.getByTestId('public-auth-tenant');await expect(auth).toHaveAttribute('aria-busy','false');
 const client=page.getByRole('link',{name:/^Panel klienta/}),staff=page.getByRole('link',{name:/^Panel obsługi/});
 if(!item.role){await expect(client).toHaveCount(0);await expect(staff).toHaveCount(0);}
 else {await expect(client).toHaveAttribute('href','/dashboard');
 if(['admin','employee','instructor'].includes(item.role))await expect(staff).toHaveAttribute('href',`/t/${tech}/admin`);
 else await expect(staff).toHaveCount(0);
 const box=(await page.getByTestId('tenant-action-tiles').boundingBox())!;
 expect(box.y).toBeGreaterThan((await auth.boundingBox())!.y);
 if(await staff.count()){const a=(await client.boundingBox())!,z=(await staff.boundingBox())!;if(item.width<768){expect(z.y).toBeGreaterThan(a.y);expect(z.width).toBeCloseTo(a.width,0);}else expect(z.y).toBeCloseTo(a.y,0);}
 }
 expect(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth)).toBe(true);
 if(item.tenant==='B')expect(await page.locator('main').innerText()).not.toMatch(/CSK|Krutla/);
 await page.screenshot({path:info.outputPath(`${item.name}-${item.width}.png`),fullPage:true});
});
