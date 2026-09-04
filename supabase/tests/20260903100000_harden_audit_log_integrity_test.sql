\set ON_ERROR_STOP on
\pset format unaligned

select '1..18';

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
returns void
language plpgsql
as $function$
begin
  perform pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object('sub',p_user_id,'role',p_role)::text,
    true
  );
  perform pg_catalog.set_config('request.jwt.claim.sub',coalesce(p_user_id::text,''),true);
  execute pg_catalog.format('set local role %I',p_role);
end;
$function$;

create function pg_temp.direct_insert_is_denied(p_role text,p_user_id uuid,p_actor_id uuid,p_action text)
returns boolean
language plpgsql
as $function$
begin
  perform pg_temp.set_client(p_role,p_user_id);
  insert into public.audit_logs(actor_user_id,actor_name,actor_role,action,target_type,target_id,target_name,details)
  values(p_actor_id,'Forged actor','admin',p_action,'profile',p_actor_id,'Forged target','{"forged":true}'::jsonb);
  execute 'reset role';
  return false;
exception when insufficient_privilege then
  execute 'reset role';
  return true;
end;
$function$;

create function pg_temp.direct_update_is_denied(p_user_id uuid,p_audit_id uuid)
returns boolean
language plpgsql
as $function$
begin
  perform pg_temp.set_client('authenticated',p_user_id);
  update public.audit_logs set action='forged_update' where id=p_audit_id;
  execute 'reset role';
  return false;
exception when insufficient_privilege then
  execute 'reset role';
  return true;
end;
$function$;

create function pg_temp.direct_delete_is_denied(p_user_id uuid,p_audit_id uuid)
returns boolean
language plpgsql
as $function$
begin
  perform pg_temp.set_client('authenticated',p_user_id);
  delete from public.audit_logs where id=p_audit_id;
  execute 'reset role';
  return false;
exception when insufficient_privilege then
  execute 'reset role';
  return true;
end;
$function$;

create function pg_temp.direct_truncate_is_denied(p_user_id uuid)
returns boolean
language plpgsql
as $function$
begin
  perform pg_temp.set_client('authenticated',p_user_id);
  truncate table public.audit_logs;
  execute 'reset role';
  return false;
exception when insufficient_privilege then
  execute 'reset role';
  return true;
end;
$function$;

do $tests$
declare
  v_admin uuid := '7c007000-0000-4000-8000-000000000001';
  v_employee uuid := '7c007000-0000-4000-8000-000000000002';
  v_instructor uuid := '7c007000-0000-4000-8000-000000000003';
  v_user uuid := '7c007000-0000-4000-8000-000000000004';
  v_target uuid := '7c007000-0000-4000-8000-000000000005';
  v_audit_id uuid;
  v_first_result jsonb;
  v_repeat_result jsonb;
  v_audit public.audit_logs%rowtype;
  v_writer_count integer;
  v_untrusted_writer_count integer;
begin
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values
    (v_admin,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','test-sec007-admin@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now()),
    (v_employee,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','test-sec007-employee@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now()),
    (v_instructor,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','test-sec007-instructor@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now()),
    (v_user,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','test-sec007-user@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now()),
    (v_target,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','test-sec007-target@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now());

  insert into public.profiles(user_id,role,first_name,last_name,full_name,email)
  values
    (v_admin,'admin','[TEST]','SEC-007 Admin','[TEST][SEC-007] Admin','test-sec007-admin@example.invalid'),
    (v_employee,'pracownik','[TEST]','SEC-007 Employee','[TEST][SEC-007] Employee','test-sec007-employee@example.invalid'),
    (v_instructor,'instruktor','[TEST]','SEC-007 Instructor','[TEST][SEC-007] Instructor','test-sec007-instructor@example.invalid'),
    (v_user,'user','[TEST]','SEC-007 User','[TEST][SEC-007] User','test-sec007-user@example.invalid'),
    (v_target,'user','[TEST]','SEC-007 Target','[TEST][SEC-007] Target','test-sec007-target@example.invalid');

  perform pg_temp.record_result(1,'audit_logs remains postgres-owned with RLS enabled',
    exists(
      select 1 from pg_catalog.pg_class relation
      join pg_catalog.pg_namespace namespace on namespace.oid=relation.relnamespace
      join pg_catalog.pg_roles owner_role on owner_role.oid=relation.relowner
      where namespace.nspname='public' and relation.relname='audit_logs'
        and relation.relkind in ('r','p') and relation.relrowsecurity
        and owner_role.rolname='postgres'
    ),'Oczekiwano owner postgres i relrowsecurity=true.');

  perform pg_temp.record_result(2,'Only the admin SELECT policy remains',
    (select pg_catalog.count(*)=1 from pg_catalog.pg_policies where schemaname='public' and tablename='audit_logs')
    and exists(
      select 1 from pg_catalog.pg_policies
      where schemaname='public' and tablename='audit_logs'
        and policyname='Admins can view audit logs' and cmd='SELECT'
        and roles=array['authenticated']::name[]
        and qual='is_admin()' and with_check is null
    ),'Nie może istnieć polityka mutacyjna audit_logs.');

  perform pg_temp.record_result(3,'Client ACL is exact and service_role baseline is preserved',
    not exists(
      select 1
      from pg_catalog.pg_class relation
      cross join lateral pg_catalog.aclexplode(coalesce(relation.relacl,pg_catalog.acldefault('r',relation.relowner))) acl
      where relation.oid='public.audit_logs'::regclass and acl.grantee=0
    )
    and not pg_catalog.has_table_privilege('anon','public.audit_logs','SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN')
    and pg_catalog.has_table_privilege('authenticated','public.audit_logs','SELECT')
    and not pg_catalog.has_table_privilege('authenticated','public.audit_logs','INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN')
    and pg_catalog.has_table_privilege('service_role','public.audit_logs','SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN'),
    'authenticated ma wyłącznie SELECT; anon/PUBLIC nic; service_role zachowuje baseline.');

  perform pg_temp.record_result(4,'Ordinary user cannot insert audit rows',
    pg_temp.direct_insert_is_denied('authenticated',v_user,v_admin,'sec007_forged_user'),
    'Bezpośredni INSERT user musi zwrócić 42501.');
  perform pg_temp.record_result(5,'Employee cannot insert audit rows',
    pg_temp.direct_insert_is_denied('authenticated',v_employee,v_admin,'sec007_forged_employee'),
    'Bezpośredni INSERT pracownika musi zwrócić 42501.');
  perform pg_temp.record_result(6,'Instructor cannot insert audit rows',
    pg_temp.direct_insert_is_denied('authenticated',v_instructor,v_admin,'sec007_forged_instructor'),
    'Bezpośredni INSERT instruktora musi zwrócić 42501.');
  perform pg_temp.record_result(7,'Admin cannot insert audit rows',
    pg_temp.direct_insert_is_denied('authenticated',v_admin,v_admin,'sec007_forged_admin'),
    'Bezpośredni INSERT admina musi zwrócić 42501.');
  perform pg_temp.record_result(8,'Anonymous client cannot insert audit rows',
    pg_temp.direct_insert_is_denied('anon',null,v_admin,'sec007_forged_anon'),
    'Bezpośredni INSERT anon musi zwrócić 42501.');

  perform pg_temp.record_result(9,'Forged actor rows were not created',
    not exists(select 1 from public.audit_logs where action like 'sec007_forged_%'),
    'Żadna próba z caller-controlled actor_user_id nie może pozostawić rekordu.');

  perform pg_temp.set_client('authenticated',v_admin);
  select public.admin_set_user_note_v1(v_target,'[TEST][SEC-007] controlled note') into v_first_result;
  execute 'reset role';

  select id into v_audit_id
  from public.audit_logs
  where action='profile_admin_note_updated' and target_id=v_target
  order by created_at desc,id desc limit 1;

  perform pg_temp.record_result(10,'Admin cannot update trusted audit rows',
    pg_temp.direct_update_is_denied(v_admin,v_audit_id),
    'Bezpośredni UPDATE admina musi zwrócić 42501.');
  perform pg_temp.record_result(11,'Employee cannot update trusted audit rows',
    pg_temp.direct_update_is_denied(v_employee,v_audit_id),
    'Bezpośredni UPDATE pracownika musi zwrócić 42501.');
  perform pg_temp.record_result(12,'Admin cannot delete trusted audit rows',
    pg_temp.direct_delete_is_denied(v_admin,v_audit_id),
    'Bezpośredni DELETE admina musi zwrócić 42501.');
  perform pg_temp.record_result(13,'Employee cannot delete trusted audit rows',
    pg_temp.direct_delete_is_denied(v_employee,v_audit_id),
    'Bezpośredni DELETE pracownika musi zwrócić 42501.');
  perform pg_temp.record_result(14,'Authenticated cannot truncate audit history',
    pg_temp.direct_truncate_is_denied(v_admin) and pg_temp.direct_truncate_is_denied(v_employee),
    'TRUNCATE admina i pracownika musi zwrócić 42501.');

  perform pg_temp.set_client('authenticated',v_admin);
  select public.admin_set_user_note_v1(v_target,'[TEST][SEC-007] controlled note') into v_repeat_result;
  execute 'reset role';

  perform pg_temp.record_result(15,'Trusted flow writes exactly one idempotent audit',
    v_first_result @> '{"ok":true,"changed":true,"code":"updated"}'::jsonb
    and v_repeat_result @> '{"ok":true,"changed":false,"code":"no_change"}'::jsonb
    and (select pg_catalog.count(*)=1 from public.audit_logs where action='profile_admin_note_updated' and target_id=v_target),
    'Pierwsza zmiana tworzy jeden audit, a no_change nie tworzy drugiego.');

  select * into v_audit from public.audit_logs where id=v_audit_id;
  perform pg_temp.record_result(16,'Trusted audit derives actor and exposes no secrets',
    v_audit.actor_user_id=v_admin
    and v_audit.actor_role='admin'
    and v_audit.action='profile_admin_note_updated'
    and v_audit.target_type='profile'
    and v_audit.target_id=v_target
    and v_audit.created_at is not null
    and v_audit.details = '{"new_note_present":true,"operator_role":"admin","previous_note_present":false}'::jsonb
    and not (v_audit.details ?| array['token','access_token','refresh_token','password','authorization','cookie','admin_note']),
    'Actor/action/target/timestamp muszą być kontrolowane; details bez tokenów i treści notatki.');

  with candidates as materialized (
    select procedure.*,owner_role.rolname as owner_name
    from pg_catalog.pg_proc procedure
    join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace
    join pg_catalog.pg_roles owner_role on owner_role.oid=procedure.proowner
    where namespace.nspname='public' and procedure.prokind='f'
  )
  select pg_catalog.count(*),
         pg_catalog.count(*) filter (
           where not procedure.prosecdef
              or procedure.owner_name<>'postgres'
              or procedure.proconfig is null
              or not exists(select 1 from pg_catalog.unnest(procedure.proconfig) config where config like 'search_path=%')
              or pg_catalog.strpos(pg_catalog.pg_get_functiondef(procedure.oid),'auth.uid()')=0
         )
  into v_writer_count,v_untrusted_writer_count
  from candidates procedure
  where pg_catalog.strpos(pg_catalog.pg_get_functiondef(procedure.oid),'audit_logs')>0
    and pg_catalog.strpos(pg_catalog.lower(pg_catalog.pg_get_functiondef(procedure.oid)),'insert into')>0;

  perform pg_temp.record_result(17,'All current audit writers are trusted database functions',
    v_writer_count=17 and v_untrusted_writer_count=0,
    'Oczekiwano 17 SECURITY DEFINER writerów owner=postgres z auth.uid() i explicit search_path.');

  perform pg_temp.record_result(18,'All fixture remains transaction-scoped',
    (select pg_catalog.count(*)=5 from public.profiles where user_id in (v_admin,v_employee,v_instructor,v_user,v_target))
    and (select pg_catalog.count(*)=5 from auth.users where id in (v_admin,v_employee,v_instructor,v_user,v_target))
    and (select pg_catalog.count(*)=1 from public.audit_logs where action='profile_admin_note_updated' and target_id=v_target),
    'Fixture [TEST][SEC-007] istnieje wyłącznie przed końcowym ROLLBACK.');
end;
$tests$;

select (case when passed then 'ok ' else 'not ok ' end)
  ||test_order::text||' - '||test_name
  ||case when passed then '' else E'\n# '||result end
from pg_temp.test_results
order by test_order;

do $assertions$
declare v_failures text;
begin
  select pg_catalog.string_agg(test_order::text||': '||test_name,', ' order by test_order)
  into v_failures from pg_temp.test_results where passed is false;
  if v_failures is not null then
    raise exception 'SEC-007 audit integrity tests failed: %',v_failures;
  end if;
end;
$assertions$;

rollback;
