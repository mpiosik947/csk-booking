\set ON_ERROR_STOP on
\pset format unaligned
\pset tuples_only on

select '1..37';
begin;

create temporary table test_results(n integer primary key,name text,passed boolean,result text) on commit drop;
create function pg_temp.ok(integer,text,boolean,text) returns void language sql as $f$
  insert into pg_temp.test_results values($1,$2,coalesce($3,false),$4);
$f$;
create function pg_temp.set_client(p_role text,p_uid uuid) returns void language plpgsql as $f$
begin
  perform pg_catalog.set_config('request.jwt.claims',pg_catalog.jsonb_build_object('sub',p_uid,'role',p_role)::text,true);
  perform pg_catalog.set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  execute pg_catalog.format('set local role %I',p_role);
end;$f$;
create function pg_temp.note_call(p_uid uuid,p_tenant uuid,p_target uuid,p_note text) returns jsonb language plpgsql as $f$
declare r jsonb;
begin
  perform pg_temp.set_client('authenticated',p_uid);
  select public.admin_set_user_note_v2(p_tenant,p_target,p_note) into r;
  reset role; return r;
exception when others then reset role; raise;
end;$f$;
create function pg_temp.list_call(p_uid uuid,p_tenant uuid) returns jsonb language plpgsql as $f$
declare r jsonb;
begin
  perform pg_temp.set_client('authenticated',p_uid);
  select coalesce(jsonb_agg(to_jsonb(item) order by item.user_id),'[]'::jsonb)
  into r from public.admin_list_users_v2(p_tenant,100,0,null,null,null,'newest') item;
  reset role; return r;
exception when others then reset role; raise;
end;$f$;
create function pg_temp.list_denied(p_uid uuid,p_tenant uuid) returns boolean language plpgsql as $f$
begin perform pg_temp.list_call(p_uid,p_tenant); return false;
exception when insufficient_privilege then return true; end;$f$;
create function pg_temp.table_denied(p_role text,p_sql text) returns boolean language plpgsql as $f$
begin execute pg_catalog.format('set local role %I',p_role); execute p_sql; reset role; return false;
exception when insufficient_privilege then reset role; return true; end;$f$;
create function pg_temp.second_active_denied(p_tenant uuid) returns boolean language plpgsql as $f$
begin update public.tenants set status='active' where id=p_tenant; return false;
exception when unique_violation then return true; end;$f$;

create temporary table untouched_profile_rpc_snapshot on commit drop as
select procedure.oid,procedure.prosrc,procedure.prosecdef,procedure.proowner,
       procedure.proconfig,procedure.proacl
from pg_catalog.pg_proc procedure
where procedure.oid in(
  'public.admin_set_user_role_v2(uuid,uuid,text)'::regprocedure,
  'public.update_tenant_profile_identity_v2(uuid,uuid,text,text)'::regprocedure,
  'public.update_tenant_profile_contact_details_v2(uuid,uuid,text,text,text,text,text,text)'::regprocedure,
  'public.update_tenant_profile_verification_v2(uuid,uuid,text,text)'::regprocedure
);

do $tests$
declare
  tenant_a constant uuid:='c5c00000-0000-4000-8000-000000000001'::uuid;
  tenant_b uuid:=pg_catalog.gen_random_uuid();
  admin_a uuid:=pg_catalog.gen_random_uuid(); admin_b uuid:=pg_catalog.gen_random_uuid();
  shared_user uuid:=pg_catalog.gen_random_uuid(); b_only uuid:=pg_catalog.gen_random_uuid();
  unrelated uuid:=pg_catalog.gen_random_uuid(); global_admin uuid:=pg_catalog.gen_random_uuid();
  pending_admin uuid:=pg_catalog.gen_random_uuid(); suspended_admin uuid:=pg_catalog.gen_random_uuid();
  run_id text:=pg_catalog.replace(pg_catalog.gen_random_uuid()::text,'-','');
  list_a jsonb; list_b jsonb; result jsonb; audit_before bigint; legacy_value text;
begin
  perform pg_temp.ok(1,'tenant note table exists',pg_catalog.to_regclass('public.tenant_user_admin_notes') is not null,'table absent');
  perform pg_temp.ok(2,'table owner and RLS fail closed',exists(select 1 from pg_catalog.pg_class relation join pg_catalog.pg_roles owner on owner.oid=relation.relowner where relation.oid='public.tenant_user_admin_notes'::regclass and relation.relrowsecurity and owner.rolname='postgres') and not exists(select 1 from pg_catalog.pg_policies where schemaname='public' and tablename='tenant_user_admin_notes'),'owner/RLS differs');
  perform pg_temp.ok(3,'direct table ACL denied',pg_temp.table_denied('anon','select * from public.tenant_user_admin_notes') and pg_temp.table_denied('authenticated','select * from public.tenant_user_admin_notes') and pg_temp.table_denied('service_role','select * from public.tenant_user_admin_notes'),'direct table access exists');
  perform pg_temp.ok(4,'table key and foreign keys present',exists(select 1 from pg_catalog.pg_constraint where conrelid='public.tenant_user_admin_notes'::regclass and contype='p' and pg_catalog.pg_get_constraintdef(oid)='PRIMARY KEY (tenant_id, user_id)') and (select pg_catalog.count(*) from pg_catalog.pg_constraint where conrelid='public.tenant_user_admin_notes'::regclass and contype='f')=3,'constraints differ');
  perform pg_temp.ok(5,'legacy backfill exact',not exists(select 1 from public.profiles profile where profile.admin_note is not null and (exists(select 1 from public.tenant_memberships membership where membership.tenant_id=tenant_a and membership.user_id=profile.user_id) or exists(select 1 from public.reservations reservation where reservation.tenant_id=tenant_a and reservation.user_id=profile.user_id) or exists(select 1 from public.event_registrations registration join public.events event_record on event_record.id=registration.event_id and event_record.tenant_id=registration.tenant_id where registration.tenant_id=tenant_a and registration.user_id=profile.user_id)) and not exists(select 1 from public.tenant_user_admin_notes note where note.tenant_id=tenant_a and note.user_id=profile.user_id and note.admin_note is not distinct from profile.admin_note)),'eligible legacy note missing');

  insert into public.tenants(id,name,slug,status) values(tenant_b,'[TEST][SAAS-9D-4B-1A] B','saas9d4b1a-'||run_id,'dormant');
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  select actor.id,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',actor.label||'-'||run_id||'@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now()
  from (values(admin_a,'admin-a'),(admin_b,'admin-b'),(shared_user,'shared'),(b_only,'b-only'),(unrelated,'unrelated'),(global_admin,'global-admin'),(pending_admin,'pending'),(suspended_admin,'suspended')) actor(id,label);

  update public.profiles profile set role=actor.legacy_role,first_name='[TEST]',last_name=actor.label,full_name='[TEST][SAAS-9D-4B-1A] '||actor.label,email=actor.label||'-'||run_id||'@example.invalid'
  from (values(admin_a,'admin','Admin A'),(admin_b,'admin','Admin B'),(shared_user,'user','Shared'),(b_only,'user','B Only'),(unrelated,'user','Unrelated'),(global_admin,'admin','Global Admin'),(pending_admin,'admin','Pending'),(suspended_admin,'admin','Suspended')) actor(id,legacy_role,label)
  where profile.user_id=actor.id;

  insert into public.tenant_memberships(tenant_id,user_id,role,status) values
    (tenant_a,admin_a,'admin','active'),
    (tenant_a,shared_user,'user','active'),
    (tenant_a,pending_admin,'admin','pending'),
    (tenant_a,suspended_admin,'admin','suspended')
  on conflict(tenant_id,user_id) do update
  set role=excluded.role,status=excluded.status;
  delete from public.tenant_memberships where tenant_id=tenant_a and user_id in(admin_b,b_only,unrelated,global_admin);
  insert into public.tenant_memberships(tenant_id,user_id,role,status) values
    (tenant_b,admin_b,'admin','active'),(tenant_b,b_only,'user','active'),(tenant_b,shared_user,'user','active')
  on conflict(tenant_id,user_id) do update set role=excluded.role,status=excluded.status;

  update public.profiles set admin_note='LEGACY MUST STAY FROZEN '||run_id where user_id=shared_user;
  select admin_note into legacy_value from public.profiles where user_id=shared_user;
  insert into public.tenant_user_admin_notes(tenant_id,user_id,admin_note,updated_by) values
    (tenant_a,shared_user,'A NOTE',admin_a),(tenant_b,shared_user,'B NOTE',admin_b);

  list_a:=pg_temp.list_call(admin_a,tenant_a);
  perform pg_temp.ok(6,'Admin A list allowed',pg_catalog.jsonb_array_length(list_a)>0,'A list denied/empty');
  perform pg_temp.ok(7,'Admin A reads only Tenant A note',exists(select 1 from pg_catalog.jsonb_array_elements(list_a) row where row->>'user_id'=shared_user::text and row->>'admin_note'='A NOTE') and list_a::text not like '%B NOTE%','A note scope differs');
  perform pg_temp.ok(8,'Tenant B-only user excluded from A',not exists(select 1 from pg_catalog.jsonb_array_elements(list_a) row where row->>'user_id'=b_only::text),'B-only user leaked');
  perform pg_temp.ok(9,'unrelated global user excluded from A',not exists(select 1 from pg_catalog.jsonb_array_elements(list_a) row where row->>'user_id'=unrelated::text),'unrelated user leaked');
  perform pg_temp.ok(10,'legacy note fallback removed',list_a::text not like '%LEGACY MUST STAY FROZEN%','legacy note leaked');

  select pg_catalog.count(*) into audit_before from public.audit_logs where action='tenant_user_admin_note_updated' and target_id=shared_user;
  result:=pg_temp.note_call(admin_a,tenant_a,shared_user,'A UPDATED');
  perform pg_temp.ok(11,'Admin A writes Tenant A note',result@>'{"ok":true,"changed":true,"code":"updated"}'::jsonb and (select admin_note='A UPDATED' from public.tenant_user_admin_notes where tenant_id=tenant_a and user_id=shared_user),'A write failed');
  perform pg_temp.ok(12,'Tenant B note unchanged',(select admin_note='B NOTE' from public.tenant_user_admin_notes where tenant_id=tenant_b and user_id=shared_user),'B note changed');
  perform pg_temp.ok(13,'profiles.admin_note frozen',(select admin_note=legacy_value from public.profiles where user_id=shared_user),'legacy field changed');
  perform pg_temp.ok(14,'tenant-bound PII-free audit',exists(select 1 from public.audit_logs where action='tenant_user_admin_note_updated' and target_type='tenant_user_admin_note' and target_id=shared_user and tenant_id=tenant_a and actor_user_id=admin_a and details::text not like '%A UPDATED%' and actor_name='Tenant administrator' and target_name='Tenant user') and (select pg_catalog.count(*)=audit_before+1 from public.audit_logs where action='tenant_user_admin_note_updated' and target_id=shared_user),'audit differs');
  result:=pg_temp.note_call(admin_a,tenant_a,shared_user,'A UPDATED');
  perform pg_temp.ok(15,'note retry is idempotent',result->>'code'='no_change' and (select pg_catalog.count(*)=audit_before+1 from public.audit_logs where action='tenant_user_admin_note_updated' and target_id=shared_user),'retry created effect');
  perform pg_temp.ok(16,'Admin A cannot write B-only user',pg_temp.note_call(admin_a,tenant_a,b_only,'CROSS')->>'code'='not_allowed' and not exists(select 1 from public.tenant_user_admin_notes where tenant_id=tenant_a and user_id=b_only),'B-only write allowed');
  perform pg_temp.ok(17,'Admin A cannot write unrelated user',pg_temp.note_call(admin_a,tenant_a,unrelated,'CROSS')->>'code'='not_allowed','unrelated write allowed');
  perform pg_temp.ok(18,'global role without membership denied',pg_temp.note_call(global_admin,tenant_a,shared_user,'CROSS')->>'code'='not_allowed' and pg_temp.list_denied(global_admin,tenant_a),'global role bypass remains');
  perform pg_temp.ok(19,'pending membership denied',pg_temp.note_call(pending_admin,tenant_a,shared_user,'CROSS')->>'code'='not_allowed' and pg_temp.list_denied(pending_admin,tenant_a),'pending actor allowed');
  perform pg_temp.ok(20,'suspended membership denied',pg_temp.note_call(suspended_admin,tenant_a,shared_user,'CROSS')->>'code'='not_allowed' and pg_temp.list_denied(suspended_admin,tenant_a),'suspended actor allowed');

  update public.tenants set status='dormant' where id=tenant_a;
  update public.tenants set status='active' where id=tenant_b;
  list_b:=pg_temp.list_call(admin_b,tenant_b);
  perform pg_temp.ok(21,'Admin B reads only Tenant B note',exists(select 1 from pg_catalog.jsonb_array_elements(list_b) row where row->>'user_id'=shared_user::text and row->>'admin_note'='B NOTE') and list_b::text not like '%A UPDATED%','B note scope differs');
  result:=pg_temp.note_call(admin_b,tenant_b,shared_user,'B UPDATED');
  perform pg_temp.ok(22,'Admin B write remains isolated',result->>'code'='updated' and (select admin_note='B UPDATED' from public.tenant_user_admin_notes where tenant_id=tenant_b and user_id=shared_user) and (select admin_note='A UPDATED' from public.tenant_user_admin_notes where tenant_id=tenant_a and user_id=shared_user),'B write contaminated A');
  perform pg_temp.ok(23,'Admin B cannot write A-only user',pg_temp.note_call(admin_b,tenant_b,admin_a,'CROSS')->>'code'='not_allowed','A-only target allowed');

  update public.tenants set status='dormant' where id=tenant_b;
  perform pg_temp.ok(24,'inactive tenant fails closed without an exact-single bridge',pg_catalog.to_regprocedure('public.active_single_tenant_id_v1()') is null and pg_temp.note_call(admin_a,tenant_a,shared_user,'ZERO')->>'code'='not_allowed' and pg_temp.list_denied(admin_a,tenant_a),'inactive tenant allowed');
  update public.tenants set status='active' where id=tenant_a;
  perform pg_temp.ok(25,'explicit tenant-scoped contracts remain authoritative',pg_catalog.to_regprocedure('public.admin_list_users_v2(uuid,integer,integer,text,text,text,text)') is not null and pg_catalog.to_regprocedure('public.admin_set_user_note_v2(uuid,uuid,text)') is not null,'tenant-scoped contract missing');
  perform pg_temp.ok(26,'second active tenant blocked',pg_temp.second_active_denied(tenant_b),'second active tenant accepted');

  perform pg_temp.ok(27,'RPC metadata and ACL minimal',not exists(select 1 from pg_catalog.pg_proc procedure join pg_catalog.pg_roles owner on owner.oid=procedure.proowner where procedure.oid in('public.admin_list_users_v2(uuid,integer,integer,text,text,text,text)'::regprocedure,'public.admin_set_user_note_v2(uuid,uuid,text)'::regprocedure) and not(procedure.prosecdef and owner.rolname='postgres' and procedure.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[] and pg_catalog.has_function_privilege('authenticated',procedure.oid,'EXECUTE') and not pg_catalog.has_function_privilege('anon',procedure.oid,'EXECUTE') and not pg_catalog.has_function_privilege('service_role',procedure.oid,'EXECUTE'))),'RPC metadata/ACL differs');
  perform pg_temp.ok(28,'list DTO signature unchanged',pg_catalog.pg_get_function_result('public.admin_list_users_v2(uuid,integer,integer,text,text,text,text)'::regprocedure) like 'TABLE(user_id uuid, email text, first_name text, last_name text, full_name text, phone text, role text, verification_status text, admin_note text,%','DTO changed');
  perform pg_temp.ok(29,'no legacy note source in active RPCs',(select prosrc not like '%profile.admin_note%' and prosrc like '%tenant_user_admin_notes%' from pg_catalog.pg_proc where oid='public.admin_list_users_v2(uuid,integer,integer,text,text,text,text)'::regprocedure) and (select prosrc not like '%set admin_note =%' and prosrc like '%tenant_user_admin_notes%' from pg_catalog.pg_proc where oid='public.admin_set_user_note_v2(uuid,uuid,text)'::regprocedure),'legacy source remains');
  perform pg_temp.ok(30,'operational relationship predicates present',(select prosrc like '%tenant_memberships%' and prosrc like '%reservations%' and prosrc like '%event_registrations%' from pg_catalog.pg_proc where oid='public.admin_list_users_v2(uuid,integer,integer,text,text,text,text)'::regprocedure) and (select prosrc like '%tenant_memberships%' and prosrc like '%reservations%' and prosrc like '%event_registrations%' from pg_catalog.pg_proc where oid='public.admin_set_user_note_v2(uuid,uuid,text)'::regprocedure),'relationship source missing');
  perform pg_temp.ok(31,'global profile role removed from authority',not exists(select 1 from pg_catalog.pg_proc where oid in('public.admin_list_users_v2(uuid,integer,integer,text,text,text,text)'::regprocedure,'public.admin_set_user_note_v2(uuid,uuid,text)'::regprocedure) and prosrc~'profile[.]role'),'global role remains');
  perform pg_temp.ok(32,'SECURITY DEFINER count is 74 after the 9F tenant selector',(select pg_catalog.count(*) from pg_catalog.pg_proc procedure join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace where namespace.nspname='public' and procedure.prosecdef)=74,'definer count differs');
  perform pg_temp.ok(33,'compatibility defaults remain 7/7',(select pg_catalog.count(*) from information_schema.columns where table_schema='public' and table_name in('shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','email_deliveries') and column_name='tenant_id' and column_default='''c5c00000-0000-4000-8000-000000000001''::uuid')=0,'defaults differ');
  perform pg_temp.ok(34,'account-wide lifecycle remains separate',pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef('public.export_my_data_v1()'::regprocedure),E'\r\n',E'\n'),E'\r',E'\n'))='d159b7d0a14f7ffc9d6c3e5088d18dc5' and pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef('public.anonymize_my_account_v1()'::regprocedure),E'\r\n',E'\n'),E'\r',E'\n'))='70b5f590399aa3f3a147935459b7f085','account lifecycle drifted');
  perform pg_temp.ok(35,'role identity contact and verification untouched',
    not exists(
      select 1 from untouched_profile_rpc_snapshot snapshot
      join pg_catalog.pg_proc procedure on procedure.oid=snapshot.oid
      where procedure.prosrc is distinct from snapshot.prosrc
         or procedure.prosecdef is distinct from snapshot.prosecdef
         or procedure.proowner is distinct from snapshot.proowner
         or procedure.proconfig is distinct from snapshot.proconfig
         or procedure.proacl is distinct from snapshot.proacl
    ) and (select pg_catalog.count(*) from untouched_profile_rpc_snapshot)=4,
    'out-of-scope profile RPC drifted');
  perform pg_temp.ok(36,'fixture is transaction-scoped and marked',run_id<>'' and exists(select 1 from public.profiles where full_name like '[TEST][SAAS-9D-4B-1A]%'),'fixture marker absent');
end;$tests$;

select (case when passed then 'ok ' else 'not ok ' end)||n||' - '||name||case when passed then '' else E'\n# '||result end from pg_temp.test_results order by n;
do $assert$
declare failed text;
begin
  select pg_catalog.string_agg(n||'. '||name||': '||result,E'\n' order by n) into failed from pg_temp.test_results where not passed;
  if (select pg_catalog.count(*) from pg_temp.test_results)<>36 then raise exception 'SAAS-9D-4B-1A expected 36 checks'; end if;
  if failed is not null then raise exception E'SAAS-9D-4B-1A failures:\n%',failed; end if;
end;$assert$;
rollback;

select case when
  not exists(select 1 from public.tenants where slug like 'saas9d4b1a-%')
  and not exists(select 1 from public.profiles where full_name like '[TEST][SAAS-9D-4B-1A]%')
  and not exists(select 1 from public.tenant_user_admin_notes note join public.profiles profile on profile.user_id=note.user_id where profile.full_name like '[TEST][SAAS-9D-4B-1A]%')
then 'ok 37 - rollback removed every SAAS-9D-4B-1A fixture'
else 'not ok 37 - rollback fixture cleanup failed' end;
