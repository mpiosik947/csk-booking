\set ON_ERROR_STOP on
\pset format unaligned
\pset tuples_only on

select '1..35';
begin;

create temporary table test_results(test_order int primary key,test_name text,passed boolean,result text) on commit drop;
create function pg_temp.ok(int,text,boolean,text) returns void language sql as $f$ insert into pg_temp.test_results values($1,$2,coalesce($3,false),$4); $f$;
create function pg_temp.as_user(p_user uuid,p_sql text) returns jsonb language plpgsql as $f$
declare v jsonb; begin
  perform set_config('request.jwt.claims',jsonb_build_object('sub',p_user,'role','authenticated')::text,true);
  set local role authenticated; execute p_sql into v; reset role; return v;
exception when others then reset role; raise; end; $f$;
create function pg_temp.denied(p_user uuid,p_sql text) returns boolean language plpgsql as $f$
begin perform pg_temp.as_user(p_user,p_sql); return false; exception when others then return true; end; $f$;
create function pg_temp.as_anon(p_sql text) returns jsonb language plpgsql as $f$
declare v jsonb; begin
  perform set_config('request.jwt.claims',jsonb_build_object('role','anon')::text,true);
  set local role anon; execute p_sql into v; reset role; return v;
exception when others then reset role; raise; end; $f$;

do $tests$
declare
  tenant_a uuid:=gen_random_uuid(); tenant_b uuid:=gen_random_uuid(); admin_a uuid:=gen_random_uuid(); admin_b uuid:=gen_random_uuid();
  employee_a uuid:=gen_random_uuid(); global_admin uuid:=gen_random_uuid(); pending_a uuid:=gen_random_uuid();
  instructor_a uuid:=gen_random_uuid(); user_a uuid:=gen_random_uuid(); suspended_a uuid:=gen_random_uuid();
  before_row public.tenant_public_profiles%rowtype; after_json jsonb; payload jsonb;
  visible_anon jsonb; visible_authenticated jsonb; hidden_anon jsonb; hidden_authenticated jsonb;
begin
  insert into auth.users(id,email) values(admin_a,'p10c-admin-a@example.invalid'),(admin_b,'p10c-admin-b@example.invalid'),(employee_a,'p10c-employee@example.invalid'),(global_admin,'p10c-global@example.invalid'),(pending_a,'p10c-pending@example.invalid'),(instructor_a,'p10c-instructor@example.invalid'),(user_a,'p10c-user@example.invalid'),(suspended_a,'p10c-suspended@example.invalid');
  update public.profiles set role='admin' where user_id=global_admin;
  insert into public.tenants(id,name,slug,status) values(tenant_a,'P10C A','p10c-a','active'),(tenant_b,'P10C B','p10c-b','active');
  insert into public.tenant_memberships(tenant_id,user_id,role,status) values
    (tenant_a,admin_a,'admin','active'),(tenant_b,admin_b,'admin','active'),(tenant_a,employee_a,'employee','active'),(tenant_a,pending_a,'admin','pending'),(tenant_a,instructor_a,'instructor','active'),(tenant_a,user_a,'user','active'),(tenant_a,suspended_a,'admin','suspended');
  insert into public.tenant_public_profiles(tenant_id,display_name,city,is_public,public_slug) values
    (tenant_a,'PRODUCT 10C A','Poznań',true,'product-10c-a'),(tenant_b,'PRODUCT 10C B','Leszno',true,'product-10c-b');

  perform pg_temp.ok(1,'settings columns and seven flags exist',(select count(*)=12 from information_schema.columns where table_schema='public' and table_name='tenant_public_profiles' and column_name in('public_address','public_phone','public_email','opening_hours','social_links','show_booking','show_pricing','show_instructor','show_events','show_about','show_contact','show_regulations')),'columns missing');
  perform pg_temp.ok(2,'visibility defaults preserve current UX',(select show_booking and show_pricing and show_instructor and show_events and show_about and show_contact and show_regulations from public.tenant_public_profiles where tenant_id=tenant_a),'defaults differ');
  perform pg_temp.ok(3,'direct table remains closed',not has_table_privilege('anon','public.tenant_public_profiles','SELECT,INSERT,UPDATE,DELETE') and not has_table_privilege('authenticated','public.tenant_public_profiles','SELECT,INSERT,UPDATE,DELETE') and not has_table_privilege('service_role','public.tenant_public_profiles','SELECT,INSERT,UPDATE,DELETE') and not exists(select 1 from pg_policies where schemaname='public' and tablename='tenant_public_profiles'),'direct access opened');
  perform pg_temp.ok(4,'three RPC ACLs are minimal',has_function_privilege('authenticated','public.admin_get_tenant_public_settings_v1(text)','EXECUTE') and has_function_privilege('authenticated','public.admin_update_tenant_public_settings_v1(text,jsonb,timestamp with time zone)','EXECUTE') and has_function_privilege('anon','public.get_public_tenant_landing_v2(text)','EXECUTE') and not has_function_privilege('service_role','public.get_public_tenant_landing_v2(text)','EXECUTE'),'ACL differs');
  perform pg_temp.ok(5,'SECURITY DEFINER inventory is 80',(select count(*)=80 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prosecdef),'inventory differs');
  perform pg_temp.ok(6,'all new RPCs have explicit hardened search_path',(select bool_and(proconfig @> array['search_path=pg_catalog, public, auth, pg_temp'] or proconfig @> array['search_path=pg_catalog, public, pg_temp']) from pg_proc where oid in('public.admin_get_tenant_public_settings_v1(text)'::regprocedure,'public.admin_update_tenant_public_settings_v1(text,jsonb,timestamp with time zone)'::regprocedure,'public.get_public_tenant_landing_v2(text)'::regprocedure)),'search path differs');
  perform pg_temp.ok(7,'Admin A reads only A',pg_temp.as_user(admin_a,$q$select public.admin_get_tenant_public_settings_v1('p10c-a')$q$)->>'display_name'='PRODUCT 10C A','same tenant read failed');
  perform pg_temp.ok(8,'Admin A cannot read B',pg_temp.denied(admin_a,$q$select public.admin_get_tenant_public_settings_v1('p10c-b')$q$),'cross tenant read allowed');
  perform pg_temp.ok(9,'employee cannot read settings',pg_temp.denied(employee_a,$q$select public.admin_get_tenant_public_settings_v1('p10c-a')$q$),'employee read allowed');
  perform pg_temp.ok(10,'global profiles admin has no tenant authority',pg_temp.denied(global_admin,$q$select public.admin_get_tenant_public_settings_v1('p10c-a')$q$),'global role bypass');
  perform pg_temp.ok(11,'pending membership is denied',pg_temp.denied(pending_a,$q$select public.admin_get_tenant_public_settings_v1('p10c-a')$q$),'pending membership allowed');
  select * into before_row from public.tenant_public_profiles where tenant_id=tenant_a;
  payload:=jsonb_build_object('display_name','PRODUCT 10C A UPDATED','city','Poznań','logo_path',null,'hero_image_path',null,'description','Publiczny opis','regulations_path','/terms','public_address','Testowa 1','public_phone','+48 123 456 789','public_email','PUBLIC@EXAMPLE.INVALID','opening_hours','Pon-Pt 10-18','social_links',jsonb_build_object('facebook','https://facebook.example/test'),'show_booking',false,'show_pricing',true,'show_instructor',false,'show_events',true,'show_about',true,'show_contact',true,'show_regulations',true);
  after_json:=pg_temp.as_user(admin_a,format('select public.admin_update_tenant_public_settings_v1(%L,%L::jsonb,%L::timestamptz)','p10c-a',payload::text,before_row.updated_at));
  perform pg_temp.ok(12,'admin updates own public profile',after_json->>'display_name'='PRODUCT 10C A UPDATED' and (after_json->>'show_booking')::boolean=false,'update failed');
  perform pg_temp.ok(13,'contact normalization is deterministic',after_json->>'public_email'='public@example.invalid','normalization failed');
  perform pg_temp.ok(14,'Tenant B remains unchanged',(select display_name='PRODUCT 10C B' and show_booking from public.tenant_public_profiles where tenant_id=tenant_b),'cross contamination');
  perform pg_temp.ok(15,'optimistic concurrency rejects stale update',pg_temp.denied(admin_a,format('select public.admin_update_tenant_public_settings_v1(%L,%L::jsonb,%L::timestamptz)','p10c-a',payload::text,before_row.updated_at-interval '1 second')),'stale update allowed');
  perform pg_temp.ok(16,'audit is tenant-bound and excludes values',exists(select 1 from public.audit_logs where tenant_id=tenant_a and actor_user_id=admin_a and action='tenant_public_profile_updated' and target_type='tenant_public_profile' and target_id=tenant_a and details ? 'changed_fields' and details::text not like '%public@example.invalid%'),'audit differs');
  perform pg_temp.ok(17,'public V2 exposes presentation state',(select not show_booking and show_events and tenant_public_email='public@example.invalid' from public.get_public_tenant_landing_v2('product-10c-a')),'public state differs');
  perform pg_temp.ok(18,'public DTO is allowlisted',(select count(*)=20 from jsonb_object_keys(to_jsonb((select row_value from public.get_public_tenant_landing_v2('product-10c-a') row_value)))),'DTO shape differs');
  perform pg_temp.ok(19,'public DTO contains no tenant UUID or membership data',(select not (to_jsonb(row_value) ?| array['tenant_id','user_id','membership','admin_note','billing']) from public.get_public_tenant_landing_v2('product-10c-a') row_value),'PII/internal leak');
  perform pg_temp.ok(20,'invalid social link is rejected',pg_temp.denied(admin_a,format('select public.admin_update_tenant_public_settings_v1(%L,%L::jsonb,%L::timestamptz)','p10c-a',(payload||jsonb_build_object('social_links',jsonb_build_object('facebook','javascript:alert(1)')))::text,after_json->>'updated_at')),'unsafe URL allowed');
  perform pg_temp.ok(21,'unknown payload key is rejected',pg_temp.denied(admin_a,format('select public.admin_update_tenant_public_settings_v1(%L,%L::jsonb,%L::timestamptz)','p10c-a',(payload||jsonb_build_object('tenant_id',tenant_b))::text,after_json->>'updated_at')),'tenant spoof key allowed');
  update public.tenant_public_profiles set is_public=false where tenant_id=tenant_b;
  perform pg_temp.ok(22,'private tenant is not enumerable',not exists(select 1 from public.get_public_tenant_landing_v2('product-10c-b')),'private tenant leaked');
  perform pg_temp.ok(23,'legacy landing remains available',exists(select 1 from public.get_public_tenant_landing_v1('product-10c-a')),'V1 compatibility failed');
  perform pg_temp.ok(24,'visibility flags do not mutate tenant status or operational data',(select status='active' from public.tenants where id=tenant_a) and (select count(*)=0 from public.reservations where tenant_id=tenant_a) and (select count(*)=0 from public.events where tenant_id=tenant_a),'visibility became authority');
  perform pg_temp.ok(25,'instructor cannot read settings',pg_temp.denied(instructor_a,$q$select public.admin_get_tenant_public_settings_v1('p10c-a')$q$),'instructor read allowed');
  perform pg_temp.ok(26,'ordinary user cannot read settings',pg_temp.denied(user_a,$q$select public.admin_get_tenant_public_settings_v1('p10c-a')$q$),'ordinary user read allowed');
  perform pg_temp.ok(27,'suspended admin membership is denied',pg_temp.denied(suspended_a,$q$select public.admin_get_tenant_public_settings_v1('p10c-a')$q$),'suspended membership allowed');

  visible_anon:=pg_temp.as_anon($q$select to_jsonb(row_value) from public.get_public_tenant_landing_v2('product-10c-a') row_value$q$);
  visible_authenticated:=pg_temp.as_user(user_a,$q$select to_jsonb(row_value) from public.get_public_tenant_landing_v2('product-10c-a') row_value$q$);
  perform pg_temp.ok(28,'anon receives enabled contact about and regulations',visible_anon->>'tenant_public_address'='Testowa 1' and visible_anon->>'tenant_public_phone'='+48 123 456 789' and visible_anon->>'tenant_public_email'='public@example.invalid' and visible_anon->>'tenant_opening_hours'='Pon-Pt 10-18' and visible_anon->'tenant_social_links'=jsonb_build_object('facebook','https://facebook.example/test') and visible_anon->>'tenant_description'='Publiczny opis' and visible_anon->>'tenant_regulations_path'='/terms','enabled anon projection differs');
  perform pg_temp.ok(29,'authenticated public reader receives enabled fields',visible_authenticated->>'tenant_public_email'='public@example.invalid' and visible_authenticated->>'tenant_description'='Publiczny opis' and visible_authenticated->>'tenant_regulations_path'='/terms','enabled authenticated projection differs');

  payload:=payload||jsonb_build_object('show_contact',false,'show_about',false,'show_regulations',false);
  after_json:=pg_temp.as_user(admin_a,format('select public.admin_update_tenant_public_settings_v1(%L,%L::jsonb,%L::timestamptz)','p10c-a',payload::text,after_json->>'updated_at'));
  hidden_anon:=pg_temp.as_anon($q$select to_jsonb(row_value) from public.get_public_tenant_landing_v2('product-10c-a') row_value$q$);
  hidden_authenticated:=pg_temp.as_user(user_a,$q$select to_jsonb(row_value) from public.get_public_tenant_landing_v2('product-10c-a') row_value$q$);
  perform pg_temp.ok(30,'anon raw DTO masks disabled contact',hidden_anon->'tenant_public_address'='null'::jsonb and hidden_anon->'tenant_public_phone'='null'::jsonb and hidden_anon->'tenant_public_email'='null'::jsonb and hidden_anon->'tenant_opening_hours'='null'::jsonb and hidden_anon->'tenant_social_links'='{}'::jsonb,'disabled anon contact leaked');
  perform pg_temp.ok(31,'authenticated raw DTO masks disabled contact',hidden_authenticated->'tenant_public_address'='null'::jsonb and hidden_authenticated->'tenant_public_phone'='null'::jsonb and hidden_authenticated->'tenant_public_email'='null'::jsonb and hidden_authenticated->'tenant_opening_hours'='null'::jsonb and hidden_authenticated->'tenant_social_links'='{}'::jsonb,'disabled authenticated contact leaked');
  perform pg_temp.ok(32,'raw DTO masks disabled about content',hidden_anon->'tenant_description'='null'::jsonb and hidden_authenticated->'tenant_description'='null'::jsonb,'disabled description leaked');
  perform pg_temp.ok(33,'raw DTO masks disabled regulations path',hidden_anon->'tenant_regulations_path'='null'::jsonb and hidden_authenticated->'tenant_regulations_path'='null'::jsonb,'disabled regulations leaked');
  perform pg_temp.ok(34,'raw public DTO excludes internal authority and secrets',not (hidden_anon ?| array['tenant_id','user_id','membership','admin_id','billing','package','entitlements','admin_note','audit','secret','service_role']) and not (hidden_authenticated ?| array['tenant_id','user_id','membership','admin_id','billing','package','entitlements','admin_note','audit','secret','service_role']),'internal public field leaked');
  perform pg_temp.ok(35,'masked DTO retains explicit visibility state',(hidden_anon->>'show_contact')::boolean=false and (hidden_anon->>'show_about')::boolean=false and (hidden_anon->>'show_regulations')::boolean=false,'visibility state differs');
end;
$tests$;

select (case when passed then 'ok ' else 'not ok ' end)||test_order||' - '||test_name||case when passed then '' else E'\n# '||result end from pg_temp.test_results order by test_order;
do $assert$ declare failures text; begin select string_agg(test_order||': '||test_name,', ') into failures from pg_temp.test_results where not passed; if failures is not null then raise exception 'PRODUCT-10C tests failed: %',failures; end if; end $assert$;
rollback;
