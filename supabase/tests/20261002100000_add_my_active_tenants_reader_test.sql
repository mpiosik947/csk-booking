\set ON_ERROR_STOP on
\pset format unaligned

select '1..8';

begin;

create temporary table saas9f_results (
  test_no integer primary key,
  description text not null,
  passed boolean not null,
  detail text
) on commit drop;

create function pg_temp.ok(p_no integer,p_description text,p_passed boolean,p_detail text default null)
returns void language plpgsql as $$
begin
  insert into saas9f_results values(p_no,p_description,p_passed,p_detail);
end $$;

create function pg_temp.as_actor(p_user uuid)
returns jsonb language plpgsql as $$
declare result jsonb;
begin
  perform set_config('request.jwt.claim.role','authenticated',true);
  perform set_config('request.jwt.claim.sub',p_user::text,true);
  select coalesce(jsonb_agg(to_jsonb(row_data) order by row_data.tenant_slug),'[]'::jsonb)
    into result from public.get_my_active_tenants_v1() row_data;
  perform set_config('request.jwt.claim.role','',true);
  perform set_config('request.jwt.claim.sub','',true);
  return result;
end $$;

do $test$
declare
  tenant_a uuid:=pg_catalog.gen_random_uuid();
  tenant_b uuid:=pg_catalog.gen_random_uuid();
  user_ab uuid:=pg_catalog.gen_random_uuid();
  user_b uuid:=pg_catalog.gen_random_uuid();
  result jsonb;
begin
  insert into auth.users(id,email) values
    (user_ab,'saas9f-ab@example.invalid'),
    (user_b,'saas9f-b@example.invalid');

  drop index public.tenants_single_active_runtime_guard;
  insert into public.tenants(id,name,slug,status) values
    (tenant_a,'[TEST][SAAS-9F] Tenant A','saas9f-a','active'),
    (tenant_b,'[TEST][SAAS-9F] Tenant B','saas9f-b','active');
  insert into public.tenant_memberships(tenant_id,user_id,role,status) values
    (tenant_a,user_ab,'user','active'),
    (tenant_b,user_ab,'admin','active'),
    (tenant_b,user_b,'user','suspended');

  result:=pg_temp.as_actor(user_ab);
  perform pg_temp.ok(1,'one global account lists both active tenant relationships',
    jsonb_array_length(result)=2,result::text);
  perform pg_temp.ok(2,'tenant A selector and role are returned',
    result @> '[{"tenant_slug":"saas9f-a","tenant_role":"user"}]'::jsonb,result::text);
  perform pg_temp.ok(3,'tenant B selector and role are returned',
    result @> '[{"tenant_slug":"saas9f-b","tenant_role":"admin"}]'::jsonb,result::text);
  perform pg_temp.ok(4,'contract is PII-free',
    not (result::text ~* 'email|phone|address|user_id|admin_note|token'),result::text);

  result:=pg_temp.as_actor(user_b);
  perform pg_temp.ok(5,'suspended membership is excluded',result='[]'::jsonb,result::text);

  perform set_config('request.jwt.claim.role','',true);
  perform set_config('request.jwt.claim.sub','',true);
  select coalesce(jsonb_agg(to_jsonb(row_data)),'[]'::jsonb) into result
    from public.get_my_active_tenants_v1() row_data;
  perform pg_temp.ok(6,'missing authenticated identity returns no tenant selector',
    result='[]'::jsonb,result::text);

  perform pg_temp.ok(7,'ACL is authenticated-only',
    not has_function_privilege('public','public.get_my_active_tenants_v1()','EXECUTE')
    and not has_function_privilege('anon','public.get_my_active_tenants_v1()','EXECUTE')
    and has_function_privilege('authenticated','public.get_my_active_tenants_v1()','EXECUTE')
    and not has_function_privilege('service_role','public.get_my_active_tenants_v1()','EXECUTE'));
  perform pg_temp.ok(8,'reader has fixed DEFINER metadata',exists(
    select 1 from pg_catalog.pg_proc procedure join pg_catalog.pg_roles owner_role on owner_role.oid=procedure.proowner
    where procedure.oid='public.get_my_active_tenants_v1()'::regprocedure
      and procedure.prosecdef and owner_role.rolname='postgres'
      and procedure.proconfig=array['search_path=pg_catalog, public, pg_temp']));
end
$test$;

select case when passed then 'ok ' else 'not ok ' end||test_no||' - '||description||
  case when detail is null then '' else ' # '||detail end
from saas9f_results order by test_no;

do $assert$
begin
  if (select count(*) from saas9f_results)<>8
     or exists(select 1 from saas9f_results where not passed) then
    raise exception 'SAAS-9F focused test failed';
  end if;
end
$assert$;

rollback;
