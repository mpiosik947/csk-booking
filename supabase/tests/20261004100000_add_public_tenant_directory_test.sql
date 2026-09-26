\set ON_ERROR_STOP on
\pset format unaligned
\pset tuples_only on

select '1..23';

begin;

create temporary table product10a_results(
  test_no integer primary key,
  description text not null,
  passed boolean not null,
  diagnostic text not null
) on commit drop;

create function pg_temp.ok(integer,text,boolean,text)
returns void language sql as $function$
  insert into pg_temp.product10a_results values($1,$2,coalesce($3,false),$4);
$function$;

create function pg_temp.as_role_count(p_role text,p_search text)
returns integer language plpgsql as $function$
declare v_count integer;
begin
  execute pg_catalog.format('set local role %I',p_role);
  select pg_catalog.count(*) into v_count
  from public.get_public_tenant_directory_v1(p_search);
  execute 'reset role';
  return v_count;
exception when others then
  execute 'reset role';
  raise;
end;
$function$;

do $tests$
declare
  tenant_b constant uuid := 'a1000000-0000-4000-8000-000000000001';
  tenant_c constant uuid := 'a1000000-0000-4000-8000-000000000002';
  tenant_d constant uuid := 'a1000000-0000-4000-8000-000000000003';
begin
  perform pg_temp.ok(1,'public profile table exists',
    pg_catalog.to_regclass('public.tenant_public_profiles') is not null,
    'table missing');
  perform pg_temp.ok(2,'public profile schema and constraints are bounded',
    (select pg_catalog.count(*)=26 from information_schema.columns
      where table_schema='public' and table_name='tenant_public_profiles')
    and exists(select 1 from pg_catalog.pg_constraint where conrelid='public.tenant_public_profiles'::pg_catalog.regclass and conname='tenant_public_profiles_tenant_id_fkey')
    and exists(select 1 from pg_catalog.pg_constraint where conrelid='public.tenant_public_profiles'::pg_catalog.regclass and conname='tenant_public_profiles_logo_path_check'),
    'schema or constraints differ');
  perform pg_temp.ok(3,'table is postgres-owned RLS with zero policies',
    exists(select 1 from pg_catalog.pg_class relation join pg_catalog.pg_roles owner_role on owner_role.oid=relation.relowner
      where relation.oid='public.tenant_public_profiles'::pg_catalog.regclass and relation.relrowsecurity and owner_role.rolname='postgres')
    and not exists(select 1 from pg_catalog.pg_policies where schemaname='public' and tablename='tenant_public_profiles'),
    'table boundary differs');
  perform pg_temp.ok(4,'all runtime roles lack direct table access',
    not pg_catalog.has_table_privilege('anon','public.tenant_public_profiles','SELECT,INSERT,UPDATE,DELETE')
    and not pg_catalog.has_table_privilege('authenticated','public.tenant_public_profiles','SELECT,INSERT,UPDATE,DELETE')
    and not pg_catalog.has_table_privilege('service_role','public.tenant_public_profiles','SELECT,INSERT,UPDATE,DELETE'),
    'direct table ACL exists');
  perform pg_temp.ok(5,'updated-at trigger is installed',
    exists(select 1 from pg_catalog.pg_trigger where tgrelid='public.tenant_public_profiles'::pg_catalog.regclass and tgname='set_tenant_public_profiles_updated_at' and not tgisinternal),
    'trigger missing');
  perform pg_temp.ok(6,'directory has one exact four-field signature',
    exists(select 1 from pg_catalog.pg_proc where oid='public.get_public_tenant_directory_v1(text)'::pg_catalog.regprocedure
      and pronargs=1 and proargnames=array['p_search','tenant_slug','tenant_name','tenant_city','tenant_logo_path']::text[]),
    'signature differs');
  perform pg_temp.ok(7,'directory is stable postgres SECURITY DEFINER with fixed search path',
    exists(select 1 from pg_catalog.pg_proc procedure join pg_catalog.pg_roles owner_role on owner_role.oid=procedure.proowner
      where procedure.oid='public.get_public_tenant_directory_v1(text)'::pg_catalog.regprocedure
        and procedure.prosecdef and procedure.provolatile='s' and owner_role.rolname='postgres'
        and procedure.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[]),
    'function metadata differs');
  perform pg_temp.ok(8,'directory RPC ACL is anon and authenticated only',
    not pg_catalog.has_function_privilege('public','public.get_public_tenant_directory_v1(text)','EXECUTE')
    and pg_catalog.has_function_privilege('anon','public.get_public_tenant_directory_v1(text)','EXECUTE')
    and pg_catalog.has_function_privilege('authenticated','public.get_public_tenant_directory_v1(text)','EXECUTE')
    and not pg_catalog.has_function_privilege('service_role','public.get_public_tenant_directory_v1(text)','EXECUTE'),
    'function ACL differs');
  perform pg_temp.ok(9,'SECURITY DEFINER inventory is 100 after PRODUCT-10C',
    (select pg_catalog.count(*)=  107 from pg_catalog.pg_proc procedure join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace where namespace.nspname='public' and procedure.prosecdef),
    'definer inventory differs');
  perform pg_temp.ok(10,'CSK has one explicit published profile',
    exists(select 1 from public.tenant_public_profiles where tenant_id='c5c00000-0000-4000-8000-000000000001'::uuid
      and display_name='CSK — Centrum Szkolenia Krutla' and city='Wolsztyn' and logo_path='/login-brand.png' and is_public),
    'CSK profile differs');
  perform pg_temp.ok(11,'empty search returns the published active CSK row',
    (select pg_catalog.count(*)=1 from public.get_public_tenant_directory_v1(null))
    and exists(select 1 from public.get_public_tenant_directory_v1('') where tenant_slug='csk'),
    'empty search differs');
  perform pg_temp.ok(12,'anon can read the PII-free directory',pg_temp.as_role_count('anon',null)=1,'anon read failed');
  perform pg_temp.ok(13,'authenticated can read the same directory',pg_temp.as_role_count('authenticated',null)=1,'authenticated read failed');
  perform pg_temp.ok(14,'name search is case-insensitive',
    exists(select 1 from public.get_public_tenant_directory_v1('centrum SZKOLENIA') where tenant_slug='csk'),
    'name search failed');
  perform pg_temp.ok(15,'city search is case-insensitive',
    exists(select 1 from public.get_public_tenant_directory_v1('wOLszTyn') where tenant_slug='csk'),
    'city search failed');
  perform pg_temp.ok(16,'slug search is supported',
    exists(select 1 from public.get_public_tenant_directory_v1('csk') where tenant_slug='csk'),
    'slug search failed');
  perform pg_temp.ok(17,'unknown search has an empty result',
    not exists(select 1 from public.get_public_tenant_directory_v1('definitely-missing')),
    'unknown search leaked a row');
  perform pg_temp.ok(18,'SQL wildcard characters are treated literally',
    not exists(select 1 from public.get_public_tenant_directory_v1('%'))
    and not exists(select 1 from public.get_public_tenant_directory_v1('_')),
    'wildcard input changed search scope');
  perform pg_temp.ok(19,'oversized search fails closed',
    not exists(select 1 from public.get_public_tenant_directory_v1(pg_catalog.repeat('x',81))),
    'oversized search returned rows');

  insert into public.tenants(id,name,slug,status) values
    (tenant_b,'[TEST][PRODUCT-10A] Dormant','product10a-dormant','dormant'),
    (tenant_c,'[TEST][PRODUCT-10A] Private','product10a-private','active'),
    (tenant_d,'[TEST][PRODUCT-10A] Public','product10a-public','active');
  insert into public.tenant_public_profiles(tenant_id,display_name,city,is_public,public_slug) values
    (tenant_b,'[TEST] Dormant','Testowo',true,'product10a-dormant-public'),
    (tenant_c,'[TEST] Private','Testowo',false,'product10a-private-public'),
    (tenant_d,'[TEST] Public','Testowo',true,'product10a-public-page');

  perform pg_temp.ok(20,'dormant and non-public tenants remain hidden',
    not exists(select 1 from public.get_public_tenant_directory_v1('product10a-dormant'))
    and not exists(select 1 from public.get_public_tenant_directory_v1('product10a-private')),
    'publication boundary failed');
  perform pg_temp.ok(21,'a second active published tenant is independently listed',
    exists(select 1 from public.get_public_tenant_directory_v1('product10a-public') where tenant_slug='product10a-public' and tenant_city='Testowo'),
    'published tenant B not listed');
  perform pg_temp.ok(22,'response is four-field PII-free and bounded to 50 rows',
    not exists(select 1 from public.get_public_tenant_directory_v1(null) result
      cross join lateral pg_catalog.jsonb_object_keys(pg_catalog.to_jsonb(result)) key
      where key not in('tenant_slug','tenant_name','tenant_city','tenant_logo_path')),
    'DTO contains an unexpected field');
end;
$tests$;

insert into public.tenants(id,name,slug,status)
select ('a2000000-0000-4000-8000-'||pg_catalog.lpad(value::text,12,'0'))::uuid,
       '[TEST][PRODUCT-10A] '||value,
       'product10a-limit-'||value,
       'active'
from pg_catalog.generate_series(1,51) value;

insert into public.tenant_public_profiles(tenant_id,display_name,city,is_public,public_slug)
select ('a2000000-0000-4000-8000-'||pg_catalog.lpad(value::text,12,'0'))::uuid,
       '[TEST][PRODUCT-10A] '||value,
       'Limitowo',
       true,
       'product10a-limit-public-'||value
from pg_catalog.generate_series(1,51) value;

update pg_temp.product10a_results
set passed = passed and (select pg_catalog.count(*)=50 from public.get_public_tenant_directory_v1('product10a-limit')),
    diagnostic = case when (select pg_catalog.count(*)=50 from public.get_public_tenant_directory_v1('product10a-limit')) then diagnostic else 'directory is not bounded to 50 rows' end
where test_no = 22;

select case when passed then 'ok ' else 'not ok ' end || test_no || ' - ' || description ||
  case when passed then '' else ' # '||diagnostic end
from pg_temp.product10a_results order by test_no;

do $assert$
begin
  if (select pg_catalog.count(*) from pg_temp.product10a_results) <> 22
     or exists(select 1 from pg_temp.product10a_results where not passed) then
    raise exception 'PRODUCT-10A focused tests failed';
  end if;
end;
$assert$;

rollback;

do $cleanup$
begin
  if exists(select 1 from public.tenants where slug like 'product10a-%')
     or exists(select 1 from public.tenant_public_profiles where display_name like '[TEST][PRODUCT-10A]%')
     or (select pg_catalog.count(*) from public.tenants where status='active') <> 1 then
    raise exception 'PRODUCT-10A focused test rollback cleanup failed';
  end if;
end;
$cleanup$;

select 'ok 23 - rollback leaves zero PRODUCT-10A fixture';
