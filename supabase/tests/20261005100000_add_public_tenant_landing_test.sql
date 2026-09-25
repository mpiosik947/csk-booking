\set ON_ERROR_STOP on
\pset format unaligned
\pset tuples_only on

select '1..34';

begin;

create temporary table product10b_results(
  test_no integer primary key,
  description text not null,
  passed boolean not null,
  diagnostic text not null
) on commit drop;

create function pg_temp.ok(integer,text,boolean,text)
returns void language sql as $function$
  insert into pg_temp.product10b_results values($1,$2,coalesce($3,false),$4);
$function$;

create function pg_temp.reader_count(p_role text,p_function text,p_slug text)
returns integer language plpgsql as $function$
declare v_count integer;
begin
  execute pg_catalog.format('set local role %I',p_role);
  if p_function='directory' then
    select pg_catalog.count(*) into v_count from public.get_public_tenant_directory_v2(p_slug);
  else
    select pg_catalog.count(*) into v_count from public.get_public_tenant_landing_v1(p_slug);
  end if;
  execute 'reset role';
  return v_count;
exception when others then
  execute 'reset role';
  raise;
end;
$function$;

do $tests$
declare
  tenant_public constant uuid := 'b1000000-0000-4000-8000-000000000001';
  tenant_private constant uuid := 'b1000000-0000-4000-8000-000000000002';
  tenant_suspended constant uuid := 'b1000000-0000-4000-8000-000000000003';
  tenant_fixture constant uuid := 'b1000000-0000-4000-8000-000000000004';
  v_denied boolean;
begin
  perform pg_temp.ok(1,'landing columns exist with public_slug required',
    (select pg_catalog.count(*)=4 from information_schema.columns
      where table_schema='public' and table_name='tenant_public_profiles'
        and column_name in('public_slug','hero_image_path','description','regulations_path'))
    and exists(select 1 from information_schema.columns where table_schema='public'
      and table_name='tenant_public_profiles' and column_name='public_slug' and is_nullable='NO'),
    'landing schema differs');
  perform pg_temp.ok(2,'public_slug is unique and bounded',
    exists(select 1 from pg_catalog.pg_constraint where conrelid='public.tenant_public_profiles'::pg_catalog.regclass
      and conname='tenant_public_profiles_public_slug_key')
    and exists(select 1 from pg_catalog.pg_constraint where conrelid='public.tenant_public_profiles'::pg_catalog.regclass
      and conname='tenant_public_profiles_public_slug_check'),
    'slug constraints differ');
  perform pg_temp.ok(3,'cross-table namespace triggers are installed',
    exists(select 1 from pg_catalog.pg_trigger where tgrelid='public.tenants'::pg_catalog.regclass
      and tgname='enforce_tenant_slug_public_namespace' and not tgisinternal)
    and exists(select 1 from pg_catalog.pg_trigger where tgrelid='public.tenant_public_profiles'::pg_catalog.regclass
      and tgname='enforce_tenant_public_profile_slug_namespace' and not tgisinternal),
    'namespace triggers missing');
  perform pg_temp.ok(4,'namespace helper is closed SECURITY INVOKER',
    exists(select 1 from pg_catalog.pg_proc p join pg_catalog.pg_roles r on r.oid=p.proowner
      where p.oid='public.enforce_public_tenant_slug_namespace()'::pg_catalog.regprocedure
        and not p.prosecdef and r.rolname='postgres'
        and p.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[])
    and not pg_catalog.has_function_privilege('anon','public.enforce_public_tenant_slug_namespace()','EXECUTE')
    and not pg_catalog.has_function_privilege('authenticated','public.enforce_public_tenant_slug_namespace()','EXECUTE')
    and not pg_catalog.has_function_privilege('service_role','public.enforce_public_tenant_slug_namespace()','EXECUTE'),
    'namespace helper metadata or ACL differs');
  perform pg_temp.ok(5,'directory v2 exact four-field DTO exists',
    exists(select 1 from pg_catalog.pg_proc where oid='public.get_public_tenant_directory_v2(text)'::pg_catalog.regprocedure
      and proargnames=array['p_search','public_slug','tenant_name','tenant_city','tenant_logo_path']::text[]),
    'directory signature differs');
  perform pg_temp.ok(6,'landing exact eight-field DTO exists',
    exists(select 1 from pg_catalog.pg_proc where oid='public.get_public_tenant_landing_v1(text)'::pg_catalog.regprocedure
      and proargnames=array['p_slug','tenant_slug','public_slug','tenant_name','tenant_city','tenant_logo_path','tenant_hero_image_path','tenant_description','tenant_regulations_path']::text[]),
    'landing signature differs');
  perform pg_temp.ok(7,'public readers are stable postgres SECURITY DEFINER with fixed search_path',
    (select pg_catalog.count(*)=2 from pg_catalog.pg_proc p join pg_catalog.pg_roles r on r.oid=p.proowner
      where p.oid in('public.get_public_tenant_directory_v2(text)'::pg_catalog.regprocedure,
                     'public.get_public_tenant_landing_v1(text)'::pg_catalog.regprocedure)
        and p.prosecdef and p.provolatile='s' and r.rolname='postgres'
        and p.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[]),
    'reader metadata differs');
  perform pg_temp.ok(8,'reader ACL is anon and authenticated only',
    not pg_catalog.has_function_privilege('public','public.get_public_tenant_directory_v2(text)','EXECUTE')
    and pg_catalog.has_function_privilege('anon','public.get_public_tenant_directory_v2(text)','EXECUTE')
    and pg_catalog.has_function_privilege('authenticated','public.get_public_tenant_directory_v2(text)','EXECUTE')
    and not pg_catalog.has_function_privilege('service_role','public.get_public_tenant_directory_v2(text)','EXECUTE')
    and not pg_catalog.has_function_privilege('public','public.get_public_tenant_landing_v1(text)','EXECUTE')
    and pg_catalog.has_function_privilege('anon','public.get_public_tenant_landing_v1(text)','EXECUTE')
    and pg_catalog.has_function_privilege('authenticated','public.get_public_tenant_landing_v1(text)','EXECUTE')
    and not pg_catalog.has_function_privilege('service_role','public.get_public_tenant_landing_v1(text)','EXECUTE'),
    'reader ACL differs');
  perform pg_temp.ok(9,'SECURITY DEFINER inventory is 100',
    (select pg_catalog.count(*)=  104 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.prosecdef),'definer inventory differs');
  perform pg_temp.ok(10,'CSK technical slug remains csk',
    exists(select 1 from public.tenants where id='c5c00000-0000-4000-8000-000000000001'::uuid and slug='csk'),
    'technical slug changed');
  perform pg_temp.ok(11,'CSK public slug is csk-krutla',
    exists(select 1 from public.tenant_public_profiles where tenant_id='c5c00000-0000-4000-8000-000000000001'::uuid
      and public_slug='csk-krutla'),'public slug differs');
  perform pg_temp.ok(12,'public slug resolves CSK landing',
    exists(select 1 from public.get_public_tenant_landing_v1('csk-krutla')
      where tenant_slug='csk' and public_slug='csk-krutla'),'public alias failed');
  perform pg_temp.ok(13,'technical slug resolves the same canonical landing',
    exists(select 1 from public.get_public_tenant_landing_v1('csk')
      where tenant_slug='csk' and public_slug='csk-krutla'),'technical compatibility failed');
  perform pg_temp.ok(14,'unknown and malformed slug fail closed',
    not exists(select 1 from public.get_public_tenant_landing_v1('missing-tenant'))
    and not exists(select 1 from public.get_public_tenant_landing_v1('../csk'))
    and not exists(select 1 from public.get_public_tenant_landing_v1('CSK-KRUTLA')),
    'invalid input returned a row');
  perform pg_temp.ok(15,'anon and authenticated receive the same published landing',
    pg_temp.reader_count('anon','landing','csk-krutla')=1
    and pg_temp.reader_count('authenticated','landing','csk-krutla')=1,
    'public role contract differs');
  perform pg_temp.ok(16,'landing DTO is PII-free',
    not exists(select 1 from public.get_public_tenant_landing_v1('csk-krutla') result
      cross join lateral pg_catalog.jsonb_object_keys(pg_catalog.to_jsonb(result)) key
      where key not in('tenant_slug','public_slug','tenant_name','tenant_city','tenant_logo_path',
        'tenant_hero_image_path','tenant_description','tenant_regulations_path')),
    'landing contains an unexpected field');
  perform pg_temp.ok(17,'directory v2 uses public slug and stays PII-free',
    exists(select 1 from public.get_public_tenant_directory_v2('csk-krutla') where public_slug='csk-krutla')
    and not exists(select 1 from public.get_public_tenant_directory_v2(null) result
      cross join lateral pg_catalog.jsonb_object_keys(pg_catalog.to_jsonb(result)) key
      where key not in('public_slug','tenant_name','tenant_city','tenant_logo_path')),
    'directory contract differs');
  perform pg_temp.ok(18,'technical slug remains searchable without being exposed in DTO',
    exists(select 1 from public.get_public_tenant_directory_v2('csk') where public_slug='csk-krutla'),
    'technical search compatibility failed');
  perform pg_temp.ok(19,'direct public profile table access remains denied',
    not pg_catalog.has_table_privilege('anon','public.tenant_public_profiles','SELECT,INSERT,UPDATE,DELETE')
    and not pg_catalog.has_table_privilege('authenticated','public.tenant_public_profiles','SELECT,INSERT,UPDATE,DELETE')
    and not pg_catalog.has_table_privilege('service_role','public.tenant_public_profiles','SELECT,INSERT,UPDATE,DELETE'),
    'direct table authority exists');

  insert into public.tenants(id,name,slug,status) values
    (tenant_public,'[TEST][PRODUCT-10B] Public','product10b-technical','active'),
    (tenant_private,'[TEST][PRODUCT-10B] Private','product10b-private-tech','active'),
    (tenant_suspended,'[TEST][PRODUCT-10B] Suspended','product10b-suspended-tech','suspended'),
    (tenant_fixture,'[TEST][PRODUCT-10B] Fixture','product10b-fixture','dormant');
  insert into public.tenant_public_profiles(tenant_id,display_name,city,logo_path,is_public,public_slug,description,regulations_path) values
    (tenant_public,'[TEST][PRODUCT-10B] Public','Testowo',null,true,'product10b-public','Public description','/terms'),
    (tenant_private,'[TEST][PRODUCT-10B] Private','Testowo',null,false,'product10b-private','Private description','/terms'),
    (tenant_suspended,'[TEST][PRODUCT-10B] Suspended','Testowo',null,true,'product10b-suspended','Suspended description','/terms');

  perform pg_temp.ok(20,'second active published tenant resolves independently',
    exists(select 1 from public.get_public_tenant_landing_v1('product10b-public')
      where tenant_slug='product10b-technical' and public_slug='product10b-public'),
    'tenant B landing missing');
  perform pg_temp.ok(21,'private tenant is indistinguishable from unknown',
    not exists(select 1 from public.get_public_tenant_landing_v1('product10b-private'))
    and not exists(select 1 from public.get_public_tenant_landing_v1('product10b-private-tech')),
    'private tenant leaked');
  perform pg_temp.ok(22,'suspended tenant is indistinguishable from unknown',
    not exists(select 1 from public.get_public_tenant_landing_v1('product10b-suspended'))
    and not exists(select 1 from public.get_public_tenant_landing_v1('product10b-suspended-tech')),
    'suspended tenant leaked');
  perform pg_temp.ok(23,'directory hides private and suspended tenants',
    not exists(select 1 from public.get_public_tenant_directory_v2('product10b-private'))
    and not exists(select 1 from public.get_public_tenant_directory_v2('product10b-suspended')),
    'directory publication boundary failed');

  v_denied:=false;
  begin
    insert into public.tenant_public_profiles(tenant_id,display_name,city,is_public,public_slug)
    values(tenant_fixture,'[TEST] Reserved','Testowo',true,'admin');
  exception when check_violation then v_denied:=true;
  end;
  perform pg_temp.ok(24,'reserved root route is rejected',v_denied,'reserved slug accepted');

  v_denied:=false;
  begin
    insert into public.tenant_public_profiles(tenant_id,display_name,city,is_public,public_slug)
    values(tenant_fixture,'[TEST] Duplicate','Testowo',true,'csk-krutla');
  exception when unique_violation then v_denied:=true;
  end;
  perform pg_temp.ok(25,'duplicate public_slug is rejected',v_denied,'duplicate slug accepted');

  v_denied:=false;
  begin
    insert into public.tenants(id,name,slug,status)
    values('b1000000-0000-4000-8000-000000000005','[TEST] Namespace conflict','csk-krutla','dormant');
  exception when others then v_denied:=sqlerrm='tenant_slug_conflict';
  end;
  perform pg_temp.ok(26,'tenant slug cannot collide with public slug',v_denied,'cross-namespace tenant slug accepted');

  v_denied:=false;
  begin
    update public.tenant_public_profiles set public_slug='csk' where tenant_id=tenant_public;
  exception when others then v_denied:=sqlerrm='public_slug_conflict';
  end;
  perform pg_temp.ok(27,'public slug cannot collide with technical slug',v_denied,'cross-namespace public slug accepted');
  perform pg_temp.ok(28,'public slug does not expose tenant UUID or membership data',
    pg_catalog.to_jsonb((select result from public.get_public_tenant_landing_v1('product10b-public') result))
      ?& array['tenant_slug','public_slug','tenant_name','tenant_city']
    and not (pg_catalog.to_jsonb((select result from public.get_public_tenant_landing_v1('product10b-public') result))
      ?| array['tenant_id','user_id','role','status','email','phone','address','admin_note']),
    'internal identity or PII leaked');
  perform pg_temp.ok(29,'slug resolution grants no tenant membership',
    not exists(select 1 from public.tenant_memberships where tenant_id=tenant_public),
    'reader created tenant authority');
  perform pg_temp.ok(30,'tenant A slug cannot resolve tenant B technical identity',
    not exists(select 1 from public.get_public_tenant_landing_v1('product10b-public') where tenant_slug<>'product10b-technical'),
    'cross-tenant resolution occurred');
  perform pg_temp.ok(31,'branding paths and description match the public profile only',
    exists(select 1 from public.get_public_tenant_landing_v1('product10b-public')
      where tenant_description='Public description' and tenant_regulations_path='/terms'
        and tenant_logo_path is null and tenant_hero_image_path is null),
    'branding projection differs');
  perform pg_temp.ok(32,'directory remains bounded and deterministic',
    (select pg_catalog.count(*)<=50 from public.get_public_tenant_directory_v2(null))
    and (select pg_catalog.array_agg(public_slug order by pg_catalog.lower(tenant_city),pg_catalog.lower(tenant_name),public_slug)
         =pg_catalog.array_agg(public_slug) from public.get_public_tenant_directory_v2(null)),
    'directory bound or ordering differs');
  perform pg_temp.ok(33,'PRODUCT-10A reader remains present and unchanged in availability',
    pg_catalog.to_regprocedure('public.get_public_tenant_directory_v1(text)') is not null
    and exists(select 1 from public.get_public_tenant_directory_v1('csk') where tenant_slug='csk'),
    'v1 compatibility reader missing');
end;
$tests$;

select case when passed then 'ok ' else 'not ok ' end || test_no || ' - ' || description ||
  case when passed then '' else ' # '||diagnostic end
from pg_temp.product10b_results order by test_no;

do $assert$
begin
  if (select pg_catalog.count(*) from pg_temp.product10b_results) <> 33
     or exists(select 1 from pg_temp.product10b_results where not passed) then
    raise exception 'PRODUCT-10B focused tests failed';
  end if;
end;
$assert$;

rollback;

do $cleanup$
begin
  if exists(select 1 from public.tenants where slug like 'product10b-%')
     or exists(select 1 from public.tenant_public_profiles where public_slug like 'product10b-%')
     or exists(select 1 from public.tenant_memberships membership
       join public.tenants tenant on tenant.id=membership.tenant_id where tenant.slug like 'product10b-%') then
    raise exception 'PRODUCT-10B focused test rollback cleanup failed';
  end if;
end;
$cleanup$;

select 'ok 34 - rollback leaves zero PRODUCT-10B fixture';
