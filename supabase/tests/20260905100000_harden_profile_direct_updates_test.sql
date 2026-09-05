\set ON_ERROR_STOP on
\pset format unaligned

select '1..30';

begin;

create temporary table test_results(
  test_order integer primary key,
  test_name text not null,
  passed boolean not null,
  result text not null
) on commit drop;

create function pg_temp.record_result(integer,text,boolean,text)
returns void language sql as $function$
  insert into pg_temp.test_results values ($1,$2,coalesce($3,false),$4);
$function$;

create function pg_temp.set_client(p_role text,p_user_id uuid)
returns void language plpgsql as $function$
begin
  perform pg_catalog.set_config('request.jwt.claims',pg_catalog.jsonb_build_object('sub',p_user_id,'role',p_role)::text,true);
  perform pg_catalog.set_config('request.jwt.claim.sub',coalesce(p_user_id::text,''),true);
  execute pg_catalog.format('set local role %I',p_role);
end;
$function$;

create function pg_temp.direct_update_denied(p_role text,p_actor uuid,p_target uuid,p_assignment text)
returns boolean language plpgsql as $function$
begin
  perform pg_temp.set_client(p_role,p_actor);
  execute pg_catalog.format('update public.profiles set %s where user_id=%L::uuid',p_assignment,p_target);
  execute 'reset role';
  return false;
exception when insufficient_privilege then
  execute 'reset role';
  return true;
end;
$function$;

create function pg_temp.call_self_update(p_user uuid,p_permission_sport boolean default true)
returns jsonb language plpgsql as $function$
declare v_result jsonb;
begin
  perform pg_temp.set_client('authenticated',p_user);
  select public.update_my_profile_v1(
    '500600700','00-001','Warszawa','Testowa','1',null,
    p_permission_sport,false,false,false,false,false,false,false,false,false
  ) into v_result;
  execute 'reset role';
  return v_result;
exception when others then execute 'reset role'; raise;
end;
$function$;

do $tests$
declare
  v_admin uuid := pg_catalog.gen_random_uuid();
  v_employee uuid := pg_catalog.gen_random_uuid();
  v_instructor uuid := pg_catalog.gen_random_uuid();
  v_user uuid := pg_catalog.gen_random_uuid();
  v_other uuid := pg_catalog.gen_random_uuid();
  v_lifecycle uuid := pg_catalog.gen_random_uuid();
  v_run text := pg_catalog.replace(pg_catalog.gen_random_uuid()::text,'-','');
  v_result jsonb;
  v_before jsonb;
  v_after jsonb;
  v_audit_count integer;
begin
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values
    (v_admin,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','clean005-admin-'||v_run||'@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now()),
    (v_employee,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','clean005-employee-'||v_run||'@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now()),
    (v_instructor,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','clean005-instructor-'||v_run||'@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now()),
    (v_user,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','clean005-user-'||v_run||'@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now()),
    (v_other,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','clean005-other-'||v_run||'@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now()),
    (v_lifecycle,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','clean005-lifecycle-'||v_run||'@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now());

  insert into public.profiles(user_id,role,first_name,last_name,full_name,email)
  select fixture.user_id,fixture.role,'[TEST]',fixture.label,'[TEST][CLEAN-005] '||fixture.label,fixture.email
  from (values
    (v_admin,'admin','Admin','clean005-admin-'||v_run||'@example.invalid'),
    (v_employee,'pracownik','Employee','clean005-employee-'||v_run||'@example.invalid'),
    (v_instructor,'instruktor','Instructor','clean005-instructor-'||v_run||'@example.invalid'),
    (v_user,'user','User','clean005-user-'||v_run||'@example.invalid'),
    (v_other,'user','Other','clean005-other-'||v_run||'@example.invalid'),
    (v_lifecycle,'user','Lifecycle','clean005-lifecycle-'||v_run||'@example.invalid')
  ) fixture(user_id,role,label,email)
  where not exists(select 1 from public.profiles profile where profile.user_id=fixture.user_id);

  update public.profiles profile set role=fixture.role,first_name='[TEST]',last_name=fixture.label,
    full_name='[TEST][CLEAN-005] '||fixture.label,email=fixture.email
  from (values
    (v_admin,'admin','Admin','clean005-admin-'||v_run||'@example.invalid'),
    (v_employee,'pracownik','Employee','clean005-employee-'||v_run||'@example.invalid'),
    (v_instructor,'instruktor','Instructor','clean005-instructor-'||v_run||'@example.invalid'),
    (v_user,'user','User','clean005-user-'||v_run||'@example.invalid'),
    (v_other,'user','Other','clean005-other-'||v_run||'@example.invalid'),
    (v_lifecycle,'user','Lifecycle','clean005-lifecycle-'||v_run||'@example.invalid')
  ) fixture(user_id,role,label,email) where profile.user_id=fixture.user_id;

  update public.profiles set verification_status='verified',permissions_verified=true,
    permissions_verified_at=pg_catalog.now() where user_id=v_user;

  perform pg_temp.record_result(1,'Profiles RLS and owner unchanged',exists(
    select 1 from pg_catalog.pg_class relation join pg_catalog.pg_roles owner_role on owner_role.oid=relation.relowner
    where relation.oid='public.profiles'::regclass and relation.relrowsecurity and owner_role.rolname='postgres'
  ),'profiles must remain postgres-owned with RLS.');
  perform pg_temp.record_result(2,'No direct UPDATE policy remains',not exists(
    select 1 from pg_catalog.pg_policies where schemaname='public' and tablename='profiles' and cmd='UPDATE'
  ),'All profile mutations must use controlled writers.');
  perform pg_temp.record_result(3,'Authenticated profile ACL is SELECT and INSERT only',
    pg_catalog.has_table_privilege('authenticated','public.profiles','SELECT,INSERT')
    and not pg_catalog.has_table_privilege('authenticated','public.profiles','UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN'),
    'authenticated must not have direct UPDATE.');
  perform pg_temp.record_result(4,'Anon and PUBLIC profile ACL is empty',
    not pg_catalog.has_table_privilege('anon','public.profiles','SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN')
    and not exists(select 1 from pg_catalog.pg_class relation cross join lateral pg_catalog.aclexplode(coalesce(relation.relacl,pg_catalog.acldefault('r',relation.relowner))) acl where relation.oid='public.profiles'::regclass and acl.grantee=0),
    'No anonymous or PUBLIC profile privilege is allowed.');
  perform pg_temp.record_result(5,'Service role profile ACL unchanged',
    pg_catalog.has_table_privilege('service_role','public.profiles','SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN'),
    'Service role keeps its managed baseline.');
  perform pg_temp.record_result(6,'Self profile RPC is hardened',exists(
    select 1 from pg_catalog.pg_proc procedure join pg_catalog.pg_roles owner_role on owner_role.oid=procedure.proowner
    where procedure.oid='public.update_my_profile_v1(text,text,text,text,text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean)'::regprocedure
      and procedure.prosecdef and procedure.provolatile='v' and procedure.prorettype='jsonb'::regtype
      and procedure.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[] and owner_role.rolname='postgres'
  ),'Self writer must be postgres-owned SECURITY DEFINER with safe search_path.');
  perform pg_temp.record_result(7,'Self profile RPC ACL is authenticated only',
    pg_catalog.has_function_privilege('authenticated','public.update_my_profile_v1(text,text,text,text,text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean)','EXECUTE')
    and not pg_catalog.has_function_privilege('anon','public.update_my_profile_v1(text,text,text,text,text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean)','EXECUTE')
    and not pg_catalog.has_function_privilege('service_role','public.update_my_profile_v1(text,text,text,text,text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean)','EXECUTE'),
    'Only authenticated may execute the auth.uid-scoped writer.');
  perform pg_temp.record_result(8,'Existing controlled writers remain available',
    pg_catalog.has_function_privilege('authenticated','public.admin_set_user_role_v1(uuid,text)','EXECUTE')
    and pg_catalog.has_function_privilege('authenticated','public.admin_set_user_note_v1(uuid,text)','EXECUTE')
    and pg_catalog.has_function_privilege('authenticated','public.update_profile_verification(uuid,text,text)','EXECUTE')
    and pg_catalog.has_function_privilege('authenticated','public.update_profile_identity(uuid,text,text)','EXECUTE')
    and pg_catalog.has_function_privilege('authenticated','public.update_profile_contact_details(uuid,text,text,text,text,text,text)','EXECUTE'),
    'Admin and employee flows must retain their RPC surface.');

  select pg_catalog.to_jsonb(profile) into v_before from public.profiles profile where user_id=v_other;
  perform pg_temp.record_result(9,'Admin direct role UPDATE denied',pg_temp.direct_update_denied('authenticated',v_admin,v_other,$q$role='admin'$q$),'Direct role tampering must fail.');
  perform pg_temp.record_result(10,'Admin direct verification UPDATE denied',pg_temp.direct_update_denied('authenticated',v_admin,v_other,$q$verification_status='verified'$q$),'Direct verification tampering must fail.');
  perform pg_temp.record_result(11,'Admin direct email UPDATE denied',pg_temp.direct_update_denied('authenticated',v_admin,v_other,$q$email='changed@example.invalid'$q$),'Direct email tampering must fail.');
  perform pg_temp.record_result(12,'Admin direct phone UPDATE denied',pg_temp.direct_update_denied('authenticated',v_admin,v_other,$q$phone='123'$q$),'Direct phone tampering must fail.');
  perform pg_temp.record_result(13,'Admin direct user_id UPDATE denied',pg_temp.direct_update_denied('authenticated',v_admin,v_other,'user_id=gen_random_uuid()'),'Direct identity-key tampering must fail.');
  perform pg_temp.record_result(14,'Admin direct created_at UPDATE denied',pg_temp.direct_update_denied('authenticated',v_admin,v_other,'created_at=now()'),'Direct timestamp tampering must fail.');
  perform pg_temp.record_result(15,'Employee arbitrary direct UPDATE denied',pg_temp.direct_update_denied('authenticated',v_employee,v_other,$q$phone='123'$q$),'Employee direct mutation must fail.');
  perform pg_temp.record_result(16,'Instructor direct UPDATE denied',pg_temp.direct_update_denied('authenticated',v_instructor,v_other,$q$phone='123'$q$),'Instructor direct mutation must fail.');
  perform pg_temp.record_result(17,'Anon direct UPDATE denied',pg_temp.direct_update_denied('anon',null,v_other,$q$phone='123'$q$),'Anon direct mutation must fail.');
  perform pg_temp.record_result(18,'Cross-user direct UPDATE denied',pg_temp.direct_update_denied('authenticated',v_user,v_other,$q$phone='123'$q$),'User A cannot update User B.');
  perform pg_temp.record_result(19,'Self direct UPDATE denied',pg_temp.direct_update_denied('authenticated',v_user,v_user,$q$phone='123'$q$),'Self service must use the allowlisted RPC.');
  select pg_catalog.to_jsonb(profile) into v_after from public.profiles profile where user_id=v_other;
  perform pg_temp.record_result(20,'Denied field tampering changed nothing',v_after=v_before,'Denied statements must leave the complete target row unchanged.');

  v_result:=pg_temp.call_self_update(v_user,true);
  perform pg_temp.record_result(21,'Self RPC updates allowlisted fields',
    v_result @> '{"ok":true,"changed":true,"code":"updated","declarations_changed":true}'::jsonb
    and exists(select 1 from public.profiles where user_id=v_user and phone='500600700' and city='Warszawa' and permission_sport),
    'Owner contact and declarations must update through the RPC.');
  perform pg_temp.record_result(22,'Declaration change resets verification',exists(
    select 1 from public.profiles where user_id=v_user and verification_status='pending' and not permissions_verified
      and permissions_verified_at is null and permissions_verified_by is null and permissions_verification_note is null
  ),'Existing re-verification semantics must remain.');
  perform pg_temp.record_result(23,'Self RPC cannot mutate privileged fields',exists(
    select 1 from public.profiles where user_id=v_user and role='user' and email='clean005-user-'||v_run||'@example.invalid'
      and first_name='[TEST]' and created_at is not null
  ),'RPC signature and update statement must exclude privileged fields.');
  v_result:=pg_temp.call_self_update(v_user,true);
  perform pg_temp.record_result(24,'Self RPC no-change is idempotent',v_result @> '{"ok":true,"changed":false,"code":"no_change"}'::jsonb,'Repeat must not write.');

  perform pg_temp.set_client('authenticated',v_admin);
  select public.admin_set_user_role_v1(v_other,'instruktor') into v_result;
  execute 'reset role';
  perform pg_temp.record_result(25,'Admin role RPC remains controlled and audited',
    v_result @> '{"ok":true,"changed":true,"code":"updated","role":"instruktor"}'::jsonb
    and (select pg_catalog.count(*)=1 from public.audit_logs where action='profile_role_changed' and target_id=v_other and actor_user_id=v_admin),
    'Role writer changes role only and records trusted actor.');

  perform pg_temp.set_client('authenticated',v_admin);
  select public.update_profile_verification(v_other,'verify','[TEST][CLEAN-005] verified') into v_result;
  execute 'reset role';
  perform pg_temp.record_result(26,'Admin verification RPC remains controlled and audited',
    v_result->>'verification_status'='verified'
    and (select pg_catalog.count(*)=1 from public.audit_logs where action='profile_verification_verified' and target_id=v_other and actor_user_id=v_admin),
    'Verification writer remains available.');

  perform pg_temp.set_client('authenticated',v_admin);
  select public.admin_set_user_note_v1(v_other,'[TEST][CLEAN-005] note') into v_result;
  execute 'reset role';
  perform pg_temp.record_result(27,'Admin note RPC remains controlled and audited',
    v_result @> '{"ok":true,"changed":true,"code":"updated"}'::jsonb
    and (select pg_catalog.count(*)=1 from public.audit_logs where action='profile_admin_note_updated' and target_id=v_other and actor_user_id=v_admin),
    'Admin note writer changes the note through its dedicated contract.');

  select pg_catalog.count(*) into v_audit_count from public.audit_logs where action='profile_admin_note_updated' and target_id=v_other;
  perform pg_temp.set_client('authenticated',v_admin);
  select public.admin_set_user_note_v1(v_other,'[TEST][CLEAN-005] note') into v_result;
  execute 'reset role';
  perform pg_temp.record_result(28,'Admin no-change creates no duplicate audit',
    v_result @> '{"ok":true,"changed":false,"code":"no_change"}'::jsonb
    and (select pg_catalog.count(*) from public.audit_logs where action='profile_admin_note_updated' and target_id=v_other)=v_audit_count,
    'Idempotent admin writer must not create false audit.');

  perform pg_temp.set_client('authenticated',v_lifecycle);
  select public.anonymize_my_account_v1() into v_result;
  execute 'reset role';
  perform pg_temp.record_result(29,'SEC-009 lifecycle remains functional',
    v_result @> '{"ok":true,"changed":true,"code":"anonymized"}'::jsonb
    and not exists(select 1 from public.profiles where user_id=v_lifecycle),
    'SEC-009 SECURITY DEFINER lifecycle must not depend on direct table UPDATE.');
  perform pg_temp.record_result(30,'Synthetic fixture remains transaction scoped',
    (select pg_catalog.count(*)=6 from auth.users where id in (v_admin,v_employee,v_instructor,v_user,v_other,v_lifecycle)),
    'All fixture belongs to this transaction and final rollback.');
end;
$tests$;

select (case when passed then 'ok ' else 'not ok ' end)||test_order::text||' - '||test_name
  ||case when passed then '' else E'\n# '||result end
from pg_temp.test_results order by test_order;

do $assertions$
declare v_failures text;
begin
  select pg_catalog.string_agg(test_order::text||': '||test_name,', ' order by test_order)
  into v_failures from pg_temp.test_results where not passed;
  if v_failures is not null then raise exception 'CLEAN-005 tests failed: %',v_failures; end if;
end;
$assertions$;

rollback;
