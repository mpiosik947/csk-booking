\set ON_ERROR_STOP on
\pset format unaligned
\pset tuples_only on
select '1..20';
begin;
create temporary table results(n integer primary key,label text,pass boolean,detail text) on commit drop;
create function pg_temp.ok(integer,text,boolean,text) returns void language sql as $f$ insert into pg_temp.results values($1,$2,coalesce($3,false),$4); $f$;
create function pg_temp.actor(p_user uuid,p_sql text) returns jsonb language plpgsql as $f$
declare r jsonb; begin
  perform set_config('request.jwt.claims',jsonb_build_object('sub',p_user,'role','authenticated')::text,true);
  perform set_config('request.jwt.claim.sub',p_user::text,true);
  execute 'set local role authenticated'; execute p_sql into r; reset role;
  perform set_config('request.jwt.claim.sub','',true); return r;
exception when others then reset role; perform set_config('request.jwt.claim.sub','',true); raise; end;$f$;
create function pg_temp.denied(p_user uuid,p_sql text) returns boolean language plpgsql as $f$
declare r jsonb; begin r:=pg_temp.actor(p_user,p_sql); return coalesce(r->>'code','') in ('not_allowed','target_not_found');
exception when insufficient_privilege then return true; end;$f$;
do $tests$
declare a constant uuid:='c5c00000-0000-4000-8000-000000000001';
 b uuid:=gen_random_uuid(); admin_a uuid:=gen_random_uuid(); admin_b uuid:=gen_random_uuid();
 customer_a uuid:=gen_random_uuid(); customer_b uuid:=gen_random_uuid(); unrelated uuid:=gen_random_uuid();
 global_admin uuid:=gen_random_uuid(); pending_admin uuid:=gen_random_uuid(); suspended_admin uuid:=gen_random_uuid();
 marker text:='[TEST][SAAS-9E-C2-D]['||replace(gen_random_uuid()::text,'-','')||']';
 rows_a jsonb; rows_b jsonb; r jsonb; audit_before bigint;
begin
 insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
 select id,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',label||'-'||replace(id::text,'-','')||'@example.invalid','',now(),'{}','{}',now(),now()
 from (values(admin_a,'admina'),(admin_b,'adminb'),(customer_a,'customera'),(customer_b,'customerb'),(unrelated,'unrelated'),(global_admin,'global'),(pending_admin,'pending'),(suspended_admin,'suspended')) u(id,label);
 insert into public.profiles(id,user_id,email,role,verification_status)
 select u.id,u.id,u.email,'user','pending' from auth.users u left join public.profiles p on p.user_id=u.id
 where u.id in(admin_a,admin_b,customer_a,customer_b,unrelated,global_admin,pending_admin,suspended_admin) and p.user_id is null;
 update public.profiles set role='admin',first_name='Fixture',last_name='Users',full_name=marker
 where user_id in(admin_a,admin_b,global_admin,pending_admin,suspended_admin);
 update public.profiles set first_name='Fixture',last_name='Customer',full_name=marker
 where user_id in(customer_a,customer_b,unrelated);
 insert into public.tenant_memberships(tenant_id,user_id,role,status) values
  (a,admin_a,'admin','active'),
  (a,customer_a,'user','active'),
  (a,pending_admin,'admin','pending'),
  (a,suspended_admin,'admin','suspended')
 on conflict (tenant_id,user_id) do update
 set role=excluded.role,status=excluded.status;
 delete from public.tenant_memberships where tenant_id=a and user_id in(admin_b,customer_b,unrelated,global_admin);
 insert into public.tenants(id,name,slug,status) values(b,marker||' B','saas9ec2d-'||left(replace(b::text,'-',''),16),'dormant');
 insert into public.tenant_memberships(tenant_id,user_id,role,status) values
  (b,admin_b,'admin','active'),(b,customer_b,'user','active');
 -- Ensure there are two admins in A for the last-admin test without touching a real account.
 insert into public.tenant_memberships(tenant_id,user_id,role,status) values(b,admin_a,'admin','active');
 perform pg_temp.ok(1,'six versioned signatures',(select count(*)=6 from pg_proc p where p.pronamespace='public'::regnamespace and p.proname in ('admin_list_users_v2','admin_set_user_role_v2','admin_set_user_note_v2','update_tenant_profile_verification_v2','update_tenant_profile_identity_v2','update_tenant_profile_contact_details_v2')),'inventory');
 perform pg_temp.ok(2,'95 DEFINER and seven defaults',(select count(*)=73 from pg_proc p where p.pronamespace='public'::regnamespace and p.prosecdef) and (select count(*)=0 from information_schema.columns where table_schema='public' and table_name in ('shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','email_deliveries') and column_name='tenant_id' and column_default='''c5c00000-0000-4000-8000-000000000001''::uuid'),'inventory');
 -- A principal executes list under authenticated, without service-role browser access.
 perform set_config('request.jwt.claim.sub',admin_a::text,true); execute 'set local role authenticated';
 select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) into rows_a from public.admin_list_users_v2(a,50,0,null,null,null,'newest') x;
 execute 'reset role'; perform set_config('request.jwt.claim.sub','',true);
 perform pg_temp.ok(3,'A admin sees related A user',strpos(rows_a::text,customer_a::text)>0,'list');
 perform pg_temp.ok(4,'A admin excludes B-only and unrelated PII',strpos(rows_a::text,customer_b::text)=0 and strpos(rows_a::text,unrelated::text)=0,'list isolation');
 perform pg_temp.ok(5,'global admin without A membership denied list',pg_temp.denied(global_admin,format('select to_jsonb(x) from public.admin_list_users_v2(%L,50,0,null,null,null,''newest'') x limit 1',a)),'global role');
 perform pg_temp.ok(6,'pending and suspended denied list',pg_temp.denied(pending_admin,format('select to_jsonb(x) from public.admin_list_users_v2(%L,50,0,null,null,null,''newest'') x limit 1',a)) and pg_temp.denied(suspended_admin,format('select to_jsonb(x) from public.admin_list_users_v2(%L,50,0,null,null,null,''newest'') x limit 1',a)),'status');
 perform pg_temp.ok(7,'A admin cannot write B-only note',pg_temp.denied(admin_a,format('select public.admin_set_user_note_v2(%L,%L,''foreign'')',a,customer_b)),'note ownership');
 perform pg_temp.ok(8,'A admin cannot write unrelated identity',pg_temp.denied(admin_a,format('select public.update_tenant_profile_identity_v2(%L,%L,''A'',''B'')',a,unrelated)),'identity ownership');
 perform pg_temp.ok(9,'A admin cannot write B-only contact',pg_temp.denied(admin_a,format('select public.update_tenant_profile_contact_details_v2(%L,%L,''1'',null,null,null,null,null)',a,customer_b)),'contact ownership');
 perform pg_temp.ok(10,'A admin cannot verify B-only user',pg_temp.denied(admin_a,format('select public.update_tenant_profile_verification_v2(%L,%L,''verify'',null)',a,customer_b)),'verification ownership');
 perform pg_temp.ok(11,'global admin cannot mutate A role',pg_temp.denied(global_admin,format('select public.admin_set_user_role_v2(%L,%L,''admin'')',a,customer_a)),'global bypass');
 perform pg_temp.ok(12,'A admin cannot mutate B-only role',pg_temp.denied(admin_a,format('select public.admin_set_user_role_v2(%L,%L,''admin'')',a,customer_b)),'role tenant ownership');
 select count(*) into audit_before from public.audit_logs;
 r:=pg_temp.actor(admin_a,format('select public.admin_set_user_note_v2(%L,%L,%L)',a,customer_a,marker||' A'));
 perform pg_temp.ok(13,'A note write succeeds',r->>'ok'='true','note');
 perform pg_temp.ok(14,'note tenant and audit bound to A',exists(select 1 from public.tenant_user_admin_notes where tenant_id=a and user_id=customer_a and admin_note=marker||' A') and exists(select 1 from public.audit_logs where tenant_id=a and actor_user_id=admin_a and target_id=customer_a) and (select count(*)>audit_before from public.audit_logs),'audit');
 perform pg_temp.ok(15,'pending cannot write note',pg_temp.denied(pending_admin,format('select public.admin_set_user_note_v2(%L,%L,''pending'')',a,customer_a)),'status');
 perform pg_temp.ok(16,'role no-change preserves state',(pg_temp.actor(admin_a,format('select public.admin_set_user_role_v2(%L,%L,''admin'')',a,admin_a)))->>'code'='no_change','role');
 perform pg_temp.ok(17,'B dormant denies B admin',pg_temp.denied(admin_b,format('select to_jsonb(x) from public.admin_list_users_v2(%L,50,0,null,null,null,''newest'') x limit 1',b)),'inactive B');
 update public.tenants set status='dormant' where id=a;
 update public.tenants set status='active' where id=b;
 perform set_config('request.jwt.claim.sub',admin_b::text,true); execute 'set local role authenticated';
 select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) into rows_b from public.admin_list_users_v2(b,50,0,null,null,null,'newest') x;
 execute 'reset role'; perform set_config('request.jwt.claim.sub','',true);
 perform pg_temp.ok(18,'B admin sees B customer, excludes A',strpos(rows_b::text,customer_b::text)>0 and strpos(rows_b::text,customer_a::text)=0,'two tenants');
 perform pg_temp.ok(19,'A note not exposed to B',strpos(rows_b::text,marker||' A')=0,'PII');
 update public.tenants set status='dormant' where id=b;
 update public.tenants set status='active' where id=a;
 perform pg_temp.ok(20,'fixture transaction-local and CSK restored',(select count(*)=8 from public.profiles where full_name=marker) and (select status='active' from public.tenants where id=a),'fixture');
end;$tests$;
select case when pass then 'ok ' else 'not ok ' end||n||' - '||label||case when pass then '' else E'\n# '||detail end from results order by n;
do $assert$ begin if exists(select 1 from results where not pass) then raise exception 'C2-D focused test failed'; end if; end;$assert$;
rollback;
select case when not exists(select 1 from public.profiles where full_name like '[TEST][SAAS-9E-C2-D][%') and not exists(select 1 from public.tenants where slug like 'saas9ec2d-%') then 'C2-D cleanup PASS' else 'C2-D cleanup FAIL' end;
