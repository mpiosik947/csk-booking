import {randomUUID} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {writeFileSync} from 'node:fs';
import {createClient} from '@supabase/supabase-js';
import {test,expect} from '@playwright/test';
import {getLocalSupabaseTestEnvironment} from './local-supabase';
const env=getLocalSupabaseTestEnvironment(),db=process.env.ONBOARD_1C_DATABASE;
if(!/^onboard_1c_[0-9a-f]{16}$/.test(db??''))throw Error('ISOLATED_SCRATCH_DATABASE_REQUIRED');
const sql=(s:string)=>execFileSync('docker',['exec','supabase_db_csk-booking','psql','-X','-At','-v','ON_ERROR_STOP=1','-U','postgres','-d',db!,'-c',s],{encoding:'utf8'}).trim();
const service=createClient(env.supabaseUrl,env.serviceRoleKey,{auth:{persistSession:false}});
test('PT409 promptly rejects stale browser saves and permits fresh retry',async({page})=>{
 const run=randomUUID(),tenant=randomUUID(),slug=`r2-browser-${run}`,email=`r2-${run}@example.invalid`,password=`Local-${run}!Aa9`;
 const created=await service.auth.admin.createUser({email,password,email_confirm:true});if(created.error||!created.data.user)throw Error('LOCAL_AUTH_FIXTURE');const user=created.data.user.id;const timings:unknown[]=[];
 try{
  sql(`insert into public.tenants(id,name,slug,status)values('${tenant}','Synthetic','${slug}','dormant');insert into public.tenant_plan_assignments(tenant_id,plan_id,status)select '${tenant}',id,'active'from public.saas_plans where plan_key='current_full_v1';insert into public.tenant_memberships(tenant_id,user_id,role,status)values('${tenant}','${user}','admin','active');insert into public.tenant_public_profiles(tenant_id,display_name,city,is_public,public_slug,show_booking,show_pricing,show_instructor,show_events,show_about,show_contact,show_regulations)values('${tenant}','Synthetic','Testowo',false,'pub-${slug}',false,false,false,false,false,false,false);`);
  await page.goto('/login?redirectTo=%2Fdashboard');await page.getByLabel('E-mail',{exact:true}).fill(email);await page.getByLabel('Hasło',{exact:true}).fill(password);await page.getByRole('button',{name:'Zaloguj się',exact:true}).click();await expect(page).toHaveURL(/\/dashboard$/);await page.goto(`/tenant-setup/${slug}`);await expect(page.locator('[data-field=city]')).toHaveValue('Testowo');
  const client=createClient(env.supabaseUrl,env.anonKey,{auth:{persistSession:false}});expect((await client.auth.signInWithPassword({email,password})).error).toBeNull();const read=await client.rpc('admin_get_tenant_public_settings_v1',{p_tenant_slug:slug});expect(read.error).toBeNull();const {feature_access,updated_at,...payload}=read.data;expect(feature_access.booking).toBe(true);const saved=await client.rpc('admin_update_tenant_public_settings_v1',{p_tenant_slug:slug,p_settings:{...payload,city:'T2'},p_expected_updated_at:updated_at});expect(saved.error).toBeNull();
  await page.locator('[data-field=city]').fill('Preserve typed city');
  for(let n=0;n<3;n++){
   const responsePromise=page.waitForResponse(r=>r.url().endsWith('/rpc/admin_update_tenant_public_settings_v1'),{timeout:5000});const started=new Date().toISOString(),start=performance.now();await page.getByRole('button',{name:'Zapisz i zostań',exact:true}).click();const response=await responsePromise;const body=await response.json();const durationMs=performance.now()-start;timings.push({started,finished:new Date().toISOString(),durationMs,status:response.status(),body});
   expect(response.status()).toBe(409);expect(body).toEqual({code:'PT409',details:null,hint:null,message:'settings_conflict'});expect(durationMs).toBeLessThan(5000);await expect(page.getByText('Ustawienia zostały zmienione w innym miejscu. Odśwież dane i spróbuj ponownie.')).toBeVisible();await expect(page.locator('[data-field=city]')).toHaveValue('Preserve typed city');
  }
  expect(sql(`select city from public.tenant_public_profiles where tenant_id='${tenant}'`)).toBe('T2');
  await page.getByRole('button',{name:'Odśwież dane (zastąpi wpisane wartości)'}).click();await expect(page.locator('[data-field=city]')).toHaveValue('T2');await page.locator('[data-field=city]').fill('Fresh retry');await page.getByRole('button',{name:'Zapisz i zostań',exact:true}).click();await expect(page.getByText('Ustawienia zapisane.')).toBeVisible();await page.reload();await expect(page.locator('[data-field=city]')).toHaveValue('Fresh retry');
  expect(sql(`select count(*)from public.audit_logs where tenant_id='${tenant}'and action='tenant_public_profile_updated'`)).toBe('2');
  expect(sql("select count(*)from pg_stat_activity where datname=current_database()and pid<>pg_backend_pid()and state like 'idle in transaction%'")).toBe('0');
 }finally{
  writeFileSync('../onboard-1c-bugfix/r2-browser-timings.json',JSON.stringify(timings,null,2));sql(`delete from public.audit_logs where tenant_id='${tenant}';delete from public.tenant_memberships where tenant_id='${tenant}';delete from public.tenant_public_profiles where tenant_id='${tenant}';delete from public.tenant_plan_assignments where tenant_id='${tenant}';delete from public.tenants where id='${tenant}';`);expect((await service.auth.admin.deleteUser(user)).error).toBeNull();expect(sql('select count(*)from auth.users')).toBe('0');
 }
});
