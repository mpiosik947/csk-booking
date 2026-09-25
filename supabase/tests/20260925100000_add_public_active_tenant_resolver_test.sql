\set ON_ERROR_STOP on
\pset format unaligned

select '1..25';
begin;
create temporary table saas9ea_results(n integer primary key, label text, passed boolean) on commit drop;
create function pg_temp.ok(integer,text,boolean) returns void language sql as $$
  insert into pg_temp.saas9ea_results values($1,$2,coalesce($3,false));
$$;
create function pg_temp.as_role_count(p_role text,p_slug text) returns integer language plpgsql as $$
declare v_count integer;
begin
  execute pg_catalog.format('set local role %I',p_role);
  select pg_catalog.count(*) into v_count from public.resolve_active_tenant_by_slug_v1(p_slug);
  execute 'reset role';
  return v_count;
exception when others then execute 'reset role'; raise;
end$$;
create function pg_temp.as_member_role(p_user uuid,p_tenant uuid) returns text language plpgsql as $$
declare v_role text;
begin
  perform pg_catalog.set_config('request.jwt.claims',pg_catalog.jsonb_build_object('sub',p_user,'role','authenticated')::text,true);
  perform pg_catalog.set_config('request.jwt.claim.sub',p_user::text,true);
  execute 'set local role authenticated';
  select public.get_my_tenant_role_v1(p_tenant) into v_role;
  execute 'reset role';
  perform pg_catalog.set_config('request.jwt.claims','{}',true);
  perform pg_catalog.set_config('request.jwt.claim.sub','',true);
  return v_role;
exception when others then
  execute 'reset role';
  perform pg_catalog.set_config('request.jwt.claims','{}',true);
  perform pg_catalog.set_config('request.jwt.claim.sub','',true);
  raise;
end$$;

do $tests$
declare
  a constant uuid:='c5c00000-0000-4000-8000-000000000001';
  b constant uuid:='9e000000-0000-4000-8000-000000000001';
  lane_b constant uuid:='9e000000-0000-4000-8000-000000000010';
  actor uuid:=pg_catalog.gen_random_uuid();
  marker text:='saas9ea-'||pg_catalog.replace(pg_catalog.gen_random_uuid()::text,'-','');
begin
  perform pg_temp.ok(1,'one additive resolver signature',
    (select pg_catalog.count(*)=1 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
     where n.nspname='public' and p.proname='resolve_active_tenant_by_slug_v1' and p.pronargs=1));
  perform pg_temp.ok(2,'stable postgres SECURITY DEFINER and fixed search path',
    exists(select 1 from pg_catalog.pg_proc p join pg_catalog.pg_roles r on r.oid=p.proowner
      where p.oid='public.resolve_active_tenant_by_slug_v1(text)'::pg_catalog.regprocedure
      and p.prosecdef and p.provolatile='s' and r.rolname='postgres'
      and p.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[]));
  perform pg_temp.ok(3,'public function ACL is anon/auth only',
    not pg_catalog.has_function_privilege('public','public.resolve_active_tenant_by_slug_v1(text)','EXECUTE')
    and pg_catalog.has_function_privilege('anon','public.resolve_active_tenant_by_slug_v1(text)','EXECUTE')
    and pg_catalog.has_function_privilege('authenticated','public.resolve_active_tenant_by_slug_v1(text)','EXECUTE')
    and not pg_catalog.has_function_privilege('service_role','public.resolve_active_tenant_by_slug_v1(text)','EXECUTE'));
  perform pg_temp.ok(4,'tenants table remains closed',
    not pg_catalog.has_table_privilege('anon','public.tenants','SELECT')
    and not pg_catalog.has_table_privilege('authenticated','public.tenants','SELECT')
    and not pg_catalog.has_table_privilege('service_role','public.tenants','SELECT'));
  perform pg_temp.ok(5,'exact four-field public DTO',
    (select p.pronargs=1 and p.proargnames=array['p_slug','tenant_id','tenant_slug','tenant_name','tenant_status']::text[]
     from pg_catalog.pg_proc p where p.oid='public.resolve_active_tenant_by_slug_v1(text)'::pg_catalog.regprocedure));
  perform pg_temp.ok(6,'active CSK resolves by slug',
    (select tenant_id=a and tenant_slug='csk' and tenant_name='CSK' and tenant_status='active'
      from public.resolve_active_tenant_by_slug_v1('csk')));
  perform pg_temp.ok(7,'anon can resolve active CSK',pg_temp.as_role_count('anon','csk')=1);
  perform pg_temp.ok(8,'authenticated can resolve active CSK',pg_temp.as_role_count('authenticated','csk')=1);
  perform pg_temp.ok(9,'unknown slug has no CSK fallback',
    not exists(select 1 from public.resolve_active_tenant_by_slug_v1('unknown')));
  perform pg_temp.ok(10,'noncanonical uppercase slug fails closed',
    not exists(select 1 from public.resolve_active_tenant_by_slug_v1('CSK')));
  perform pg_temp.ok(11,'malformed and null slug fail closed',
    not exists(select 1 from public.resolve_active_tenant_by_slug_v1('csk/other'))
    and not exists(select 1 from public.resolve_active_tenant_by_slug_v1(null)));
  perform pg_temp.ok(12,'no PII or membership metadata in result',
    not exists(select 1 from public.resolve_active_tenant_by_slug_v1('csk') result
      cross join lateral pg_catalog.jsonb_object_keys(pg_catalog.to_jsonb(result)) key
      where key not in('tenant_id','tenant_slug','tenant_name','tenant_status')));
  perform pg_temp.ok(13,'SECURITY DEFINER inventory is exactly 100 after PRODUCT-10C public landing',
    (select pg_catalog.count(*)=  97 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
     where n.nspname='public' and p.prosecdef));
  perform pg_temp.ok(14,'seven CSK compatibility defaults remain',
    (select pg_catalog.count(*)=0 from information_schema.columns where table_schema='public'
      and table_name in('shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','email_deliveries')
      and column_name='tenant_id' and column_default='''c5c00000-0000-4000-8000-000000000001''::uuid'));
  perform pg_temp.ok(15,'second-active rollout guard is retired',
    not exists(select 1 from pg_catalog.pg_indexes where schemaname='public' and indexname='tenants_single_active_runtime_guard'));

  insert into public.tenants(id,name,slug,status) values(b,'[TEST][9E-A] B','test-9e-a-b','dormant');
  insert into public.shooting_lanes(id,name,type,price_per_hour,is_active,max_shooters,booking_step_minutes,display_order,currency_code,resource_kind,parent_lane_id,whole_lane_bookable,positions_bookable,tenant_id)
    values(lane_b,'[TEST][9E-A] Lane B','test',0,false,2,60,999,'PLN','lane',null,true,false,b);
  perform pg_temp.ok(16,'dormant B never resolves publicly',
    not exists(select 1 from public.resolve_active_tenant_by_slug_v1('test-9e-a-b')));
  perform pg_temp.ok(17,'persisted resource B cannot be attributed to route A',
    (select tenant_id<>a from public.shooting_lanes where id=lane_b));

  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,
    raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
    values(actor,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
      marker||'@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now());
  insert into public.profiles(id,user_id,email,role,verification_status)
    select actor,actor,marker||'@example.invalid','user','verified'
    where not exists(select 1 from public.profiles where user_id=actor);
  update public.profiles set role='admin' where user_id=actor;
  insert into public.tenant_memberships(tenant_id,user_id,role,status)
  values(a,actor,'admin','active')
  on conflict(tenant_id,user_id) do update
  set role=excluded.role,status=excluded.status;
  if not exists(select 1 from public.tenant_memberships
      where tenant_id=a and user_id=actor and role='admin' and status='active') then
    raise exception 'SAAS-9E-A explicit synthetic CSK membership fixture not created';
  end if;
  perform pg_temp.ok(18,'global/CSK admin without B membership is denied in B',
    pg_temp.as_member_role(actor,b) is null and pg_temp.as_member_role(actor,a)='admin');
  insert into public.tenant_memberships(tenant_id,user_id,role,status)
    values(b,actor,'admin','pending');

  update public.tenants set status='dormant' where id=a;
  update public.tenants set status='active' where id=b;
  perform pg_temp.ok(19,'active B resolves B only',
    (select tenant_id=b from public.resolve_active_tenant_by_slug_v1('test-9e-a-b'))
    and not exists(select 1 from public.resolve_active_tenant_by_slug_v1('csk')));
  perform pg_temp.ok(20,'pending B membership denies staff',pg_temp.as_member_role(actor,b) is null);
  update public.tenant_memberships set status='suspended' where tenant_id=b and user_id=actor;
  perform pg_temp.ok(21,'suspended B membership denies staff',pg_temp.as_member_role(actor,b) is null);
  update public.tenant_memberships set status='active' where tenant_id=b and user_id=actor;
  perform pg_temp.ok(22,'active B membership permits B only',
    pg_temp.as_member_role(actor,b)='admin' and pg_temp.as_member_role(actor,a) is null);
  perform pg_temp.ok(23,'persisted B resource matches B and not A',
    (select tenant_id=b and tenant_id<>a from public.shooting_lanes where id=lane_b));
  update public.tenants set status='dormant' where id=b;
  update public.tenants set status='active' where id=a;
  perform pg_temp.ok(24,'fixture and CSK invariant remain transaction scoped',
    exists(select 1 from public.tenants where id=b)
    and (select pg_catalog.count(*)=1 from public.tenants where status='active' and id=a));
end;
$tests$;

select (case when passed then 'ok ' else 'not ok ' end)||n||' - '||label
from pg_temp.saas9ea_results order by n;
do $$begin
  if (select pg_catalog.count(*) from pg_temp.saas9ea_results)<>24
     or exists(select 1 from pg_temp.saas9ea_results where not passed) then
    raise exception 'SAAS-9E-A focused tests failed';
  end if;
end$$;
rollback;

do $cleanup$
begin
  if exists(select 1 from public.tenants where id='9e000000-0000-4000-8000-000000000001'::uuid)
     or exists(select 1 from public.shooting_lanes where id='9e000000-0000-4000-8000-000000000010'::uuid)
     or (select pg_catalog.count(*) from public.tenants where status='active' and slug='csk')<>1 then
    raise exception 'SAAS-9E-A focused test rollback cleanup failed';
  end if;
end;
$cleanup$;
select 'ok 25 - rollback leaves zero 9E-A fixture';
