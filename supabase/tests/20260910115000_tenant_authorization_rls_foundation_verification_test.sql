\set ON_ERROR_STOP on
\pset format unaligned

select '1..25';

begin;

create temporary table test_results (
  test_order integer primary key,
  test_name text not null,
  passed boolean not null,
  result text not null
) on commit drop;

create function pg_temp.ok(integer, text, boolean, text)
returns void language sql as $function$
  insert into pg_temp.test_results values ($1, $2, coalesce($3, false), $4);
$function$;

create function pg_temp.as_authenticated_text(p_user uuid, p_sql text)
returns text language plpgsql as $function$
declare v_result text;
begin
  perform pg_catalog.set_config('request.jwt.claims', pg_catalog.jsonb_build_object('sub',p_user,'role','authenticated')::text, true);
  perform pg_catalog.set_config('request.jwt.claim.sub', p_user::text, true);
  execute 'set local role authenticated';
  execute 'select (' || p_sql || ')::text' into v_result;
  execute 'reset role';
  perform pg_catalog.set_config('request.jwt.claims','{}',true);
  perform pg_catalog.set_config('request.jwt.claim.sub','',true);
  return v_result;
exception when others then
  execute 'reset role';
  perform pg_catalog.set_config('request.jwt.claims','{}',true);
  perform pg_catalog.set_config('request.jwt.claim.sub','',true);
  raise;
end;
$function$;

create function pg_temp.as_authenticated_raises(p_user uuid, p_sql text, p_state text)
returns boolean language plpgsql as $function$
begin
  perform pg_catalog.set_config('request.jwt.claims', pg_catalog.jsonb_build_object('sub',p_user,'role','authenticated')::text, true);
  perform pg_catalog.set_config('request.jwt.claim.sub', p_user::text, true);
  execute 'set local role authenticated';
  execute p_sql;
  execute 'reset role';
  perform pg_catalog.set_config('request.jwt.claims','{}',true);
  perform pg_catalog.set_config('request.jwt.claim.sub','',true);
  return false;
exception when others then
  execute 'reset role';
  perform pg_catalog.set_config('request.jwt.claims','{}',true);
  perform pg_catalog.set_config('request.jwt.claim.sub','',true);
  return sqlstate = p_state;
end;
$function$;

do $tests$
declare
  v_csk constant uuid := 'c5c00000-0000-4000-8000-000000000001'::uuid;
  v_user uuid := pg_catalog.gen_random_uuid();
  v_no_membership uuid := pg_catalog.gen_random_uuid();
  v_other uuid := pg_catalog.gen_random_uuid();
  v_run text := pg_catalog.replace(pg_catalog.gen_random_uuid()::text,'-','');
begin
  perform pg_temp.ok(1,'all four 9C-1 helpers exist',
    pg_catalog.to_regprocedure('public.is_tenant_member_v1(uuid)') is not null
    and pg_catalog.to_regprocedure('public.has_tenant_role_v1(uuid,text[])') is not null
    and pg_catalog.to_regprocedure('public.get_my_tenant_role_v1(uuid)') is not null
    and pg_catalog.to_regprocedure('public.active_single_tenant_id_v1()') is not null,
    '9C-1 helper inventory differs.');

  perform pg_temp.ok(2,'9C-1 helpers are SECURITY DEFINER owned by postgres',
    (select pg_catalog.count(*)=4
     from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
     where n.nspname='public'
       and p.proname in ('is_tenant_member_v1','has_tenant_role_v1','get_my_tenant_role_v1','active_single_tenant_id_v1')
       and p.prosecdef and pg_catalog.pg_get_userbyid(p.proowner)='postgres'),
    'Helper owner/SECURITY DEFINER contract differs.');

  perform pg_temp.ok(3,'9C-1 helper search_path is hardened',
    (select pg_catalog.count(*)=4
     from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
     where n.nspname='public'
       and p.proname in ('is_tenant_member_v1','has_tenant_role_v1','get_my_tenant_role_v1','active_single_tenant_id_v1')
       and p.proconfig @> array['search_path=pg_catalog, public, pg_temp']),
    'Helper search_path differs.');

  perform pg_temp.ok(4,'membership helpers retain authenticated-only EXECUTE',
    not pg_catalog.has_function_privilege('anon','public.is_tenant_member_v1(uuid)','EXECUTE')
    and pg_catalog.has_function_privilege('authenticated','public.is_tenant_member_v1(uuid)','EXECUTE')
    and not pg_catalog.has_function_privilege('service_role','public.is_tenant_member_v1(uuid)','EXECUTE')
    and not pg_catalog.has_function_privilege('anon','public.has_tenant_role_v1(uuid,text[])','EXECUTE')
    and pg_catalog.has_function_privilege('authenticated','public.has_tenant_role_v1(uuid,text[])','EXECUTE')
    and not pg_catalog.has_function_privilege('service_role','public.has_tenant_role_v1(uuid,text[])','EXECUTE'),
    'Membership helper grants expanded.');

  perform pg_temp.ok(5,'role lookup retains authenticated-only EXECUTE',
    not pg_catalog.has_function_privilege('anon','public.get_my_tenant_role_v1(uuid)','EXECUTE')
    and pg_catalog.has_function_privilege('authenticated','public.get_my_tenant_role_v1(uuid)','EXECUTE')
    and not pg_catalog.has_function_privilege('service_role','public.get_my_tenant_role_v1(uuid)','EXECUTE'),
    'Role lookup grants expanded.');

  perform pg_temp.ok(6,'active tenant id helper remains internal',
    not pg_catalog.has_function_privilege('public','public.active_single_tenant_id_v1()','EXECUTE')
    and not pg_catalog.has_function_privilege('anon','public.active_single_tenant_id_v1()','EXECUTE')
    and not pg_catalog.has_function_privilege('authenticated','public.active_single_tenant_id_v1()','EXECUTE')
    and not pg_catalog.has_function_privilege('service_role','public.active_single_tenant_id_v1()','EXECUTE'),
    'Internal active-tenant helper grant expanded.');

  perform pg_temp.ok(7,'CSK profile memberships are reconciled after reset/backfill',
    not exists(
      select 1 from public.profiles profile
      left join public.tenant_memberships membership
        on membership.tenant_id=v_csk and membership.user_id=profile.user_id
      where membership.user_id is null
         or membership.status<>'active'
         or membership.role is distinct from public.legacy_profile_role_to_tenant_role_v1(profile.role)
    ), 'Existing profile/member reconciliation differs.');

  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values
    (v_user,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','saas9c2-foundation-'||v_run||'@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now()),
    (v_no_membership,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','saas9c2-none-'||v_run||'@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now());
  insert into public.profiles(user_id,email,role) values(v_user,'saas9c2-foundation-'||v_run||'@example.invalid','user');
  insert into public.tenants(id,name,slug,status) values(v_other,'[TEST][SAAS-9C-2] B','saas9c2-'||pg_catalog.left(v_run,16),'dormant');
  insert into public.tenant_memberships(tenant_id,user_id,role,status) values(v_other,v_user,'admin','active');

  perform pg_temp.ok(8,'new profile creates active CSK membership',
    exists(select 1 from public.tenant_memberships where tenant_id=v_csk and user_id=v_user and role='user' and status='active'),
    'CSK membership bridge failed.');
  perform pg_temp.ok(9,'non-CSK membership does not rewrite legacy role',
    exists(select 1 from public.profiles where user_id=v_user and role='user'),
    'Non-CSK membership changed profiles.role.');
  perform pg_temp.ok(10,'active CSK membership is recognized',
    pg_temp.as_authenticated_text(v_user,pg_catalog.format('public.is_tenant_member_v1(%L::uuid)',v_csk))='true',
    'Active CSK membership denied.');
  perform pg_temp.ok(11,'active user role is recognized exactly',
    pg_temp.as_authenticated_text(v_user,pg_catalog.format('public.has_tenant_role_v1(%L::uuid,array[''user''])',v_csk))='true',
    'Exact user role denied.');
  perform pg_temp.ok(12,'user role does not imply admin',
    pg_temp.as_authenticated_text(v_user,pg_catalog.format('public.has_tenant_role_v1(%L::uuid,array[''admin''])',v_csk))='false',
    'Role helper escalated user.');
  perform pg_temp.ok(13,'canonical role lookup returns user',
    pg_temp.as_authenticated_text(v_user,pg_catalog.format('public.get_my_tenant_role_v1(%L::uuid)',v_csk))='user',
    'Canonical role lookup differs.');
  perform pg_temp.ok(14,'dormant tenant denies membership helper',
    pg_temp.as_authenticated_text(v_user,pg_catalog.format('public.is_tenant_member_v1(%L::uuid)',v_other))='false',
    'Dormant tenant membership authorized.');
  perform pg_temp.ok(15,'missing membership fails closed',
    pg_temp.as_authenticated_text(v_no_membership,pg_catalog.format('public.is_tenant_member_v1(%L::uuid)',v_csk))='false',
    'Missing membership authorized.');

  update public.tenant_memberships set status='pending' where tenant_id=v_csk and user_id=v_user;
  perform pg_temp.ok(16,'pending membership fails closed',
    pg_temp.as_authenticated_text(v_user,pg_catalog.format('public.is_tenant_member_v1(%L::uuid)',v_csk))='false',
    'Pending membership authorized.');
  update public.tenant_memberships set status='suspended' where tenant_id=v_csk and user_id=v_user;
  perform pg_temp.ok(17,'suspended membership fails closed',
    pg_temp.as_authenticated_text(v_user,pg_catalog.format('public.has_tenant_role_v1(%L::uuid,array[''user''])',v_csk))='false',
    'Suspended membership authorized.');
  update public.tenant_memberships set status='active' where tenant_id=v_csk and user_id=v_user;

  perform pg_temp.ok(18,'authenticated sees only own memberships without recursion',
    pg_temp.as_authenticated_text(v_user,'(select count(*) from public.tenant_memberships)')='2',
    'Self-read returned another user or recursed.');
  perform pg_temp.ok(19,'no-membership user self-read returns zero without recursion',
    pg_temp.as_authenticated_text(v_no_membership,'(select count(*) from public.tenant_memberships)')='0',
    'No-membership self-read leaked rows or recursed.');
  perform pg_temp.ok(20,'self membership INSERT is denied',
    pg_temp.as_authenticated_raises(v_user,pg_catalog.format('insert into public.tenant_memberships(tenant_id,user_id,role,status) values(%L,%L,''admin'',''active'')',v_csk,v_no_membership),'42501'),
    'Authenticated membership INSERT was not denied.');
  perform pg_temp.ok(21,'self role UPDATE is denied',
    pg_temp.as_authenticated_raises(v_user,pg_catalog.format('update public.tenant_memberships set role=''admin'' where tenant_id=%L and user_id=%L',v_csk,v_user),'42501'),
    'Authenticated membership UPDATE was not denied.');
  perform pg_temp.ok(22,'self membership DELETE is denied',
    pg_temp.as_authenticated_raises(v_user,pg_catalog.format('delete from public.tenant_memberships where tenant_id=%L and user_id=%L',v_csk,v_user),'42501'),
    'Authenticated membership DELETE was not denied.');
  perform pg_temp.ok(23,'unknown requested role fails closed',
    pg_temp.as_authenticated_text(v_user,pg_catalog.format('public.has_tenant_role_v1(%L::uuid,array[''owner''])',v_csk))='false',
    'Unknown role was accepted.');
  perform pg_temp.ok(24,'NULL tenant fails closed',
    pg_temp.as_authenticated_text(v_user,'public.is_tenant_member_v1(null::uuid)')='false',
    'NULL tenant was accepted.');
  perform pg_temp.ok(25,'public tenant policy helper exposes boolean only',
    pg_catalog.pg_get_function_result('public.is_active_public_tenant_v1(uuid)'::regprocedure)='boolean'
    and pg_catalog.has_function_privilege('anon','public.is_active_public_tenant_v1(uuid)','EXECUTE')
    and pg_catalog.has_function_privilege('authenticated','public.is_active_public_tenant_v1(uuid)','EXECUTE')
    and not pg_catalog.has_function_privilege('service_role','public.is_active_public_tenant_v1(uuid)','EXECUTE'),
    'Public policy helper contract differs.');
end;
$tests$;

select case when passed then 'ok ' else 'not ok ' end || test_order || ' - ' || test_name || case when passed then '' else E'\n# '||result end
from test_results order by test_order;

do $assert$
begin
  if exists(select 1 from test_results where not passed) then
    raise exception 'SAAS-9C-2A foundation verification failed.';
  end if;
end;
$assert$;

rollback;
