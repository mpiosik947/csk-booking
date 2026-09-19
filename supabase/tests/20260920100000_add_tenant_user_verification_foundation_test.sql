-- SAAS-9D-4B-2A focused regression. All fixtures are rolled back.
begin;

select '1..31';

create temporary table saas9d4b2a_results(
  test_no integer primary key,
  description text not null,
  passed boolean not null,
  detail text
) on commit drop;

create or replace function pg_temp.ok(p_no integer,p_description text,p_passed boolean,p_detail text default null)
returns void language plpgsql as $function$
begin
  insert into saas9d4b2a_results values(p_no,p_description,coalesce(p_passed,false),p_detail);
end;
$function$;

do $test$
declare
  v_csk uuid:=public.active_single_tenant_id_v1();
  v_tenant_b uuid:='b2a00000-0000-4000-8000-000000000001';
  v_admin uuid:='b2a00000-0000-4000-8000-000000000010';
  v_related uuid:='b2a00000-0000-4000-8000-000000000011';
  v_unrelated uuid:='b2a00000-0000-4000-8000-000000000012';
  v_ambiguous uuid:='b2a00000-0000-4000-8000-000000000013';
  v_default uuid:='b2a00000-0000-4000-8000-000000000014';
  v_inserted bigint;
  v_failed boolean;
begin
  perform pg_temp.ok(1,'tenant verification table exists',pg_catalog.to_regclass('public.tenant_user_verifications') is not null);
  perform pg_temp.ok(2,'backfill helper exists',pg_catalog.to_regprocedure('public._backfill_csk_tenant_user_verifications_v1()') is not null);
  perform pg_temp.ok(3,'table RLS is enabled',(select relrowsecurity from pg_catalog.pg_class where oid='public.tenant_user_verifications'::regclass));
  perform pg_temp.ok(4,'table has zero policies',(select pg_catalog.count(*)=0 from pg_catalog.pg_policy where polrelid='public.tenant_user_verifications'::regclass));
  perform pg_temp.ok(5,'PUBLIC and anon have no direct DML',
    not pg_catalog.has_table_privilege('public','public.tenant_user_verifications','SELECT,INSERT,UPDATE,DELETE')
    and not pg_catalog.has_table_privilege('anon','public.tenant_user_verifications','SELECT,INSERT,UPDATE,DELETE'));
  perform pg_temp.ok(6,'authenticated has no direct DML',not pg_catalog.has_table_privilege('authenticated','public.tenant_user_verifications','SELECT,INSERT,UPDATE,DELETE'));
  perform pg_temp.ok(7,'service_role has no direct DML',not pg_catalog.has_table_privilege('service_role','public.tenant_user_verifications','SELECT,INSERT,UPDATE,DELETE'));
  perform pg_temp.ok(8,'backfill helper has no public runtime EXECUTE',
    not pg_catalog.has_function_privilege('anon','public._backfill_csk_tenant_user_verifications_v1()','EXECUTE')
    and not pg_catalog.has_function_privilege('authenticated','public._backfill_csk_tenant_user_verifications_v1()','EXECUTE')
    and not pg_catalog.has_function_privilege('service_role','public._backfill_csk_tenant_user_verifications_v1()','EXECUTE'));
  perform pg_temp.ok(9,'backfill helper is SECURITY INVOKER',(select not prosecdef from pg_catalog.pg_proc where oid='public._backfill_csk_tenant_user_verifications_v1()'::regprocedure));
  perform pg_temp.ok(10,'identity key is tenant and user',(select pg_catalog.pg_get_constraintdef(oid)='PRIMARY KEY (tenant_id, user_id)' from pg_catalog.pg_constraint where conrelid='public.tenant_user_verifications'::regclass and contype='p'));

  insert into public.tenants(id,name,slug,status) values(v_tenant_b,'[TEST][SAAS-9D-4B-2A] B','test-saas9d4b2a-b','dormant');
  insert into auth.users(id,instance_id,email,encrypted_password,email_confirmed_at,created_at,updated_at,raw_app_meta_data,raw_user_meta_data,aud,role)
  values
    (v_admin,'00000000-0000-0000-0000-000000000000','saas9d4b2a-admin@example.invalid','',now(),now(),now(),'{}','{}','authenticated','authenticated'),
    (v_related,'00000000-0000-0000-0000-000000000000','saas9d4b2a-related@example.invalid','',now(),now(),now(),'{}','{}','authenticated','authenticated'),
    (v_unrelated,'00000000-0000-0000-0000-000000000000','saas9d4b2a-unrelated@example.invalid','',now(),now(),now(),'{}','{}','authenticated','authenticated'),
    (v_ambiguous,'00000000-0000-0000-0000-000000000000','saas9d4b2a-ambiguous@example.invalid','',now(),now(),now(),'{}','{}','authenticated','authenticated'),
    (v_default,'00000000-0000-0000-0000-000000000000','saas9d4b2a-default@example.invalid','',now(),now(),now(),'{}','{}','authenticated','authenticated');

  insert into public.profiles(user_id,email,role,full_name)
  values(v_admin,'saas9d4b2a-admin@example.invalid','admin','[TEST][SAAS-9D-4B-2A] Admin'),
        (v_related,'saas9d4b2a-related@example.invalid','user','[TEST][SAAS-9D-4B-2A] Related'),
        (v_unrelated,'saas9d4b2a-unrelated@example.invalid','user','[TEST][SAAS-9D-4B-2A] Unrelated'),
        (v_ambiguous,'saas9d4b2a-ambiguous@example.invalid','user','[TEST][SAAS-9D-4B-2A] Ambiguous'),
        (v_default,'saas9d4b2a-default@example.invalid','user','[TEST][SAAS-9D-4B-2A] Default');

  update public.profiles set role='user',full_name='[TEST][SAAS-9D-4B-2A]',verification_status='pending',permissions_verified=false
  where user_id in(v_related,v_unrelated,v_ambiguous,v_default);
  update public.profiles set role='admin',full_name='[TEST][SAAS-9D-4B-2A] Admin' where user_id=v_admin;
  update public.profiles set verification_status='verified',permissions_verified=true,
    permissions_verified_at='2026-09-17 10:00:00+00',permissions_verified_by=(select id from public.profiles where user_id=v_admin),
    permissions_verification_note='Tenant A verification',verified_at='2026-09-17 10:00:00+00',
    verified_by=(select id from public.profiles where user_id=v_admin)
  where user_id=v_related;
  update public.profiles set verification_status='rejected',unverified_at='2026-09-17 11:00:00+00',
    unverified_by=(select id::text from public.profiles where user_id=v_admin)
  where user_id in(v_unrelated,v_ambiguous);

  insert into public.tenant_memberships(tenant_id,user_id,role,status)
  values(v_csk,v_admin,'admin','active'),(v_csk,v_related,'user','active'),
        (v_csk,v_ambiguous,'user','active'),(v_tenant_b,v_ambiguous,'user','active'),
        (v_csk,v_default,'user','active')
  on conflict(tenant_id,user_id) do update set role=excluded.role,status=excluded.status;
  delete from public.tenant_memberships where tenant_id=v_csk and user_id=v_unrelated;

  v_failed:=false;
  begin perform public._backfill_csk_tenant_user_verifications_v1(); exception when check_violation then v_failed:=true; end;
  perform pg_temp.ok(11,'unrelated or ambiguous meaningful state fails closed',v_failed);
  perform pg_temp.ok(12,'failed preflight inserted no rows',(select pg_catalog.count(*)=0 from public.tenant_user_verifications where user_id in(v_related,v_unrelated,v_ambiguous,v_default)));

  insert into public.tenant_memberships(tenant_id,user_id,role,status) values(v_csk,v_unrelated,'user','active');
  delete from public.tenant_memberships where tenant_id=v_tenant_b and user_id=v_ambiguous;
  select public._backfill_csk_tenant_user_verifications_v1() into v_inserted;
  perform pg_temp.ok(13,'deterministic CSK backfill inserts every related profile',v_inserted=5,v_inserted::text);
  perform pg_temp.ok(14,'verified state is copied to CSK row',(select verification_status='verified' and permissions_verified from public.tenant_user_verifications where tenant_id=v_csk and user_id=v_related));
  perform pg_temp.ok(15,'legacy profile-id verifier maps to auth user id',(select permissions_verified_by=v_admin and verified_by=v_admin from public.tenant_user_verifications where tenant_id=v_csk and user_id=v_related));
  perform pg_temp.ok(16,'unverified actor maps to auth user id',(select unverified_by=v_admin from public.tenant_user_verifications where tenant_id=v_csk and user_id=v_unrelated));
  perform pg_temp.ok(17,'legacy default normalizes to pending',(select verification_status='pending' and not permissions_verified from public.tenant_user_verifications where tenant_id=v_csk and user_id=v_default));

  update public.profiles set verification_status='rejected',permissions_verified=false where user_id=v_related;
  select public._backfill_csk_tenant_user_verifications_v1() into v_inserted;
  perform pg_temp.ok(18,'backfill rerun is idempotent',v_inserted=0,v_inserted::text);
  perform pg_temp.ok(19,'backfill never overwrites distinct tenant state',(select verification_status='verified' and permissions_verified from public.tenant_user_verifications where tenant_id=v_csk and user_id=v_related));

  insert into public.tenant_user_verifications(tenant_id,user_id,verification_status,permissions_verified,updated_at)
  values(v_tenant_b,v_related,'rejected',false,now());
  perform pg_temp.ok(20,'same user can hold two physical tenant states',(select pg_catalog.count(*)=2 from public.tenant_user_verifications where user_id=v_related));
  perform pg_temp.ok(21,'Tenant A and Tenant B values are independent',
    (select verification_status='verified' from public.tenant_user_verifications where tenant_id=v_csk and user_id=v_related)
    and (select verification_status='rejected' from public.tenant_user_verifications where tenant_id=v_tenant_b and user_id=v_related));
  update public.tenant_user_verifications set verification_status='pending',permissions_verified=false where tenant_id=v_tenant_b and user_id=v_related;
  perform pg_temp.ok(22,'Tenant B update does not change Tenant A',(select verification_status='verified' from public.tenant_user_verifications where tenant_id=v_csk and user_id=v_related));

  update public.tenants set status='dormant' where id=v_csk;
  v_failed:=false;
  begin perform public._backfill_csk_tenant_user_verifications_v1(); exception when check_violation then v_failed:=true; end;
  perform pg_temp.ok(23,'zero active tenant fails closed',v_failed);
  update public.tenants set status='active' where id=v_csk;
  v_failed:=false;
  begin update public.tenants set status='active' where id=v_tenant_b; exception when unique_violation then v_failed:=true; end;
  perform pg_temp.ok(24,'more than one active tenant is structurally denied',v_failed);
  perform pg_temp.ok(25,'exactly one active CSK tenant is restored',(select pg_catalog.count(*)=1 from public.tenants where status='active') and public.active_single_tenant_id_v1()=v_csk);

  perform pg_temp.ok(26,'update_profile_verification matches approved 4B-2C closure',
    pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef('public.update_profile_verification(uuid,text,text)'::regprocedure),E'\r\n',E'\n'),E'\r',E'\n'))='022baa5652409d2246cd5e66642e884e');
  perform pg_temp.ok(27,'profile privilege trigger fingerprint is frozen',
    pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef('public.prevent_non_admin_profile_privilege_changes()'::regprocedure),E'\r\n',E'\n'),E'\r',E'\n'))='8a3cb4dc2d663cbf3c866fc3d9c8dac7');
  perform pg_temp.ok(28,'legacy-signature writer uses only tenant verification source after 4B-2B',
    (select pg_catalog.strpos(prosrc,'update public.profiles')=0 and pg_catalog.strpos(prosrc,'_apply_tenant_user_verification_v1')>0 from pg_catalog.pg_proc where oid='public.update_profile_verification(uuid,text,text)'::regprocedure));
  perform pg_temp.ok(29,'SECURITY DEFINER inventory is 70 after 9E-A',(select pg_catalog.count(*)=70 from pg_catalog.pg_proc procedure join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace where namespace.nspname='public' and procedure.prosecdef));
  perform pg_temp.ok(30,'compatibility defaults remain 7/7',(select pg_catalog.count(*)=7 from information_schema.columns where table_schema='public' and table_name in('shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','email_deliveries') and column_name='tenant_id' and column_default='''c5c00000-0000-4000-8000-000000000001''::uuid'));
end;
$test$;

select (case when passed then 'ok ' else 'not ok ' end)||test_no::text||' - '||description
  ||case when passed then '' else E'\n# '||coalesce(detail,'failed') end
from saas9d4b2a_results order by test_no;

do $assertions$
declare v_failures text;
begin
  select pg_catalog.string_agg(test_no::text||': '||description,', ' order by test_no)
  into v_failures from saas9d4b2a_results where not passed;
  if v_failures is not null then raise exception 'SAAS-9D-4B-2A tests failed: %',v_failures; end if;
end;
$assertions$;

rollback;

select case when
  not exists(select 1 from public.tenants where id='b2a00000-0000-4000-8000-000000000001')
  and not exists(select 1 from auth.users where id::text like 'b2a00000-0000-4000-8000-%')
  and not exists(select 1 from public.profiles where user_id::text like 'b2a00000-0000-4000-8000-%')
  and not exists(select 1 from public.tenant_memberships where user_id::text like 'b2a00000-0000-4000-8000-%')
  and not exists(select 1 from public.tenant_user_verifications where user_id::text like 'b2a00000-0000-4000-8000-%')
then 'ok 31 - rollback removed every SAAS-9D-4B-2A fixture'
else 'not ok 31 - rollback fixture cleanup failed' end;
