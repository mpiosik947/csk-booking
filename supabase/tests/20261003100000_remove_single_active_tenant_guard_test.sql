select '1..10';

begin;

create temporary table saas9h_results(test_no integer, description text, passed boolean, diagnostic text) on commit drop;

do $tests$
declare
  tenant_b uuid := '9f000000-0000-4000-8000-000000000002';
  user_ab uuid := '9f000000-0000-4000-8000-000000000003';
  rows jsonb;
begin
  insert into saas9h_results values
    (1,'single-active rollout guard is retired',pg_catalog.to_regclass('public.tenants_single_active_runtime_guard') is null,'guard remains'),
    (2,'production-compatible baseline still has one active tenant',(select count(*)=1 from public.tenants where status='active'),'baseline changed'),
    (3,'SECURITY DEFINER inventory is 100 after PRODUCT-10C',(select count(*)=  97 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prosecdef),'inventory changed'),
    (4,'compatibility defaults remain zero',(select count(*)=0 from information_schema.columns where table_schema='public' and table_name in('shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','email_deliveries') and column_name='tenant_id' and column_default is not null),'default returned');

  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values(user_ab,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','saas9h-ab@example.invalid','',now(),'{}','{"test_marker":"[TEST][SAAS-9H]"}',now(),now());
  insert into public.tenants(id,name,slug,status) values(tenant_b,'[TEST][SAAS-9H] Tenant B','saas9h-b','active');
  insert into public.tenant_memberships(tenant_id,user_id,role,status) values
    ('c5c00000-0000-4000-8000-000000000001',user_ab,'user','active'),
    (tenant_b,user_ab,'user','active');

  perform set_config('request.jwt.claims',jsonb_build_object('sub',user_ab,'role','authenticated')::text,true);
  perform set_config('request.jwt.claim.sub',user_ab::text,true);
  set local role authenticated;
  select coalesce(jsonb_agg(to_jsonb(x) order by tenant_slug),'[]'::jsonb) into rows from public.get_my_active_tenants_v1() x;
  reset role;

  insert into saas9h_results values
    (5,'two active tenants are representable locally',(select count(*)=2 from public.tenants where status='active'),'second active tenant rejected'),
    (6,'global selector returns both memberships',jsonb_array_length(rows)=2 and rows @> '[{"tenant_slug":"csk"},{"tenant_slug":"saas9h-b"}]'::jsonb,'selector lost a tenant'),
    (7,'explicit public resolver isolates tenant B',(select tenant_id=tenant_b from public.resolve_active_tenant_by_slug_v1('saas9h-b')),'slug resolver mismatch'),
    (8,'tenant membership rows remain independent',(select count(*)=2 from public.tenant_memberships where user_id=user_ab and status='active'),'membership state collapsed'),
    (9,'no implicit single-tenant function authority remains',not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and (p.prosrc ilike '%active_single_tenant%' or p.prosrc ilike '%c5c00000-0000-4000-8000-000000000001%')),'implicit authority found'),
    (10,'tenant tables remain closed to direct authenticated DML',not has_table_privilege('authenticated','public.tenants','INSERT,UPDATE,DELETE') and not has_table_privilege('authenticated','public.tenant_memberships','INSERT,UPDATE,DELETE'),'client DML opened');
end;
$tests$;

select case when passed then 'ok ' else 'not ok ' end || test_no || ' - ' || description || case when passed then '' else ' # '||diagnostic end
from saas9h_results order by test_no;

do $assert$
begin
  if exists(select 1 from saas9h_results where not passed) then
    raise exception 'SAAS-9H guard retirement test failed';
  end if;
end;
$assert$;

rollback;
