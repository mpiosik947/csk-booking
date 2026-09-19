\set ON_ERROR_STOP on
\pset format unaligned

select '1..26';
begin;
create temporary table saas9d4e_results(n integer primary key,description text,passed boolean) on commit drop;
create function pg_temp.ok(integer,text,boolean) returns void language sql as $$
  insert into pg_temp.saas9d4e_results values($1,$2,coalesce($3,false));
$$;
create function pg_temp.role_count(p_role text) returns integer language plpgsql as $$
declare v_count integer;
begin execute pg_catalog.format('set local role %I',p_role); select count(*) into v_count from public.get_public_booking_configuration_v1(); reset role; return v_count;
exception when others then reset role; raise; end$$;

do $tests$
declare
  tenant_a constant uuid:='c5c00000-0000-4000-8000-000000000001';
  tenant_b constant uuid:='4e000000-0000-4000-8000-000000000001';
  lane_b constant uuid:='4e000000-0000-4000-8000-000000000010';
  a_count integer;
  b_count integer;
begin
  perform pg_temp.ok(1,'wrapper target fingerprint exact',md5(replace(replace(pg_get_functiondef('public.get_public_booking_configuration_v1()'::regprocedure),E'\r\n',E'\n'),E'\r',E'\n'))='0134f91776a7e967c06a016714f732ca');
  perform pg_temp.ok(2,'core target fingerprint exact',md5(replace(replace(pg_get_functiondef('public.get_public_booking_configuration_v1__saas9d4e_core(uuid)'::regprocedure),E'\r\n',E'\n'),E'\r',E'\n'))='ff6f0a91a7c8ad66d885e2fd0c5df265');
  perform pg_temp.ok(3,'wrapper is stable postgres SECURITY DEFINER SP1',exists(select 1 from pg_proc p join pg_roles r on r.oid=p.proowner where p.oid='public.get_public_booking_configuration_v1()'::regprocedure and p.prosecdef and p.provolatile='s' and r.rolname='postgres' and p.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[]));
  perform pg_temp.ok(4,'core is stable postgres SECURITY INVOKER SP1',exists(select 1 from pg_proc p join pg_roles r on r.oid=p.proowner where p.oid='public.get_public_booking_configuration_v1__saas9d4e_core(uuid)'::regprocedure and not p.prosecdef and p.provolatile='s' and r.rolname='postgres' and p.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[]));
  perform pg_temp.ok(5,'wrapper ACL anon/auth only',not has_function_privilege('public','public.get_public_booking_configuration_v1()','EXECUTE') and has_function_privilege('anon','public.get_public_booking_configuration_v1()','EXECUTE') and has_function_privilege('authenticated','public.get_public_booking_configuration_v1()','EXECUTE') and not has_function_privilege('service_role','public.get_public_booking_configuration_v1()','EXECUTE'));
  perform pg_temp.ok(6,'core direct client/service execution denied',not has_function_privilege('public','public.get_public_booking_configuration_v1__saas9d4e_core(uuid)','EXECUTE') and not has_function_privilege('anon','public.get_public_booking_configuration_v1__saas9d4e_core(uuid)','EXECUTE') and not has_function_privilege('authenticated','public.get_public_booking_configuration_v1__saas9d4e_core(uuid)','EXECUTE') and not has_function_privilege('service_role','public.get_public_booking_configuration_v1__saas9d4e_core(uuid)','EXECUTE'));
  perform pg_temp.ok(7,'exact 14-field DTO',(select p.pronargs=0 and array_length(p.proargnames,1)=14 from pg_proc p where p.oid='public.get_public_booking_configuration_v1()'::regprocedure));
  perform pg_temp.ok(8,'wrapper accepts no caller tenant argument',(select p.pronargs=0 from pg_proc p where p.oid='public.get_public_booking_configuration_v1()'::regprocedure));
  perform pg_temp.ok(9,'wrapper derives exact active tenant',strpos(pg_get_functiondef('public.get_public_booking_configuration_v1()'::regprocedure),'active_single_tenant_id_v1()')>0);
  perform pg_temp.ok(10,'core filters root tenant',pg_get_functiondef('public.get_public_booking_configuration_v1__saas9d4e_core(uuid)'::regprocedure) ~ 'resource\.tenant_id\s*=\s*p_tenant_id');
  perform pg_temp.ok(11,'core binds parent to resource tenant',pg_get_functiondef('public.get_public_booking_configuration_v1__saas9d4e_core(uuid)'::regprocedure) ~ 'parent\.tenant_id\s*=\s*resource\.tenant_id');
  perform pg_temp.ok(12,'SECURITY DEFINER count is 76 after 9E-C1',(select count(*)=76 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prosecdef));
  perform pg_temp.ok(13,'compatibility defaults remain 7/7',(select count(*)=7 from information_schema.columns where table_schema='public' and table_name in('shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','email_deliveries') and column_name='tenant_id' and column_default='''c5c00000-0000-4000-8000-000000000001''::uuid'));
  select count(*) into a_count from public.get_public_booking_configuration_v1();
  perform pg_temp.ok(14,'one active CSK resolves exactly its configuration',a_count=(select count(*) from public.get_public_booking_configuration_v1__saas9d4e_core(tenant_a)));
  perform pg_temp.ok(15,'anon public contract works',pg_temp.role_count('anon')=a_count);
  perform pg_temp.ok(16,'authenticated public contract works',pg_temp.role_count('authenticated')=a_count);

  insert into public.tenants(id,name,slug,status) values(tenant_b,'[TEST][9D4E] B','test-9d4e-b','dormant');
  insert into public.shooting_lanes(id,name,type,price_per_hour,is_active,max_shooters,booking_step_minutes,display_order,currency_code,resource_kind,parent_lane_id,whole_lane_bookable,positions_bookable,tenant_id)
    values(lane_b,'[TEST][9D4E] Lane B','shooting',100,true,2,30,999,'PLN','lane',null,true,false,tenant_b);
  insert into public.lane_booking_rules(lane_id,online_bookable,max_people_online) values(lane_b,true,2);
  insert into public.lane_booking_durations(id,lane_id,duration_minutes,display_order,is_active) values('4e000000-0000-4000-8000-000000000011',lane_b,60,1,true);
  insert into public.lane_pricing_rules(id,lane_id,day_group,min_shooters,max_shooters,label,hourly_price,display_order,is_active) values
    ('4e000000-0000-4000-8000-000000000012',lane_b,'mon_thu',1,2,'B',100,1,true),
    ('4e000000-0000-4000-8000-000000000013',lane_b,'fri_sun',1,2,'B',100,1,true);
  select count(*) into b_count from public.get_public_booking_configuration_v1__saas9d4e_core(tenant_b);
  perform pg_temp.ok(17,'tenant B core configuration is internally complete',b_count=1);
  perform pg_temp.ok(18,'dormant B is absent from active A wrapper',not exists(select 1 from public.get_public_booking_configuration_v1() where lane_id=lane_b));

  update public.tenants set status='dormant' where id=tenant_a;
  perform pg_temp.ok(19,'zero active tenants fail closed',(select count(*)=0 from public.get_public_booking_configuration_v1()));
  update public.tenants set status='active' where id=tenant_b;
  perform pg_temp.ok(20,'single active B resolves only B',(select count(*)=1 from public.get_public_booking_configuration_v1()) and exists(select 1 from public.get_public_booking_configuration_v1() where lane_id=lane_b) and pg_temp.role_count('anon')=1 and pg_temp.role_count('authenticated')=1);
  update public.tenants set status='dormant' where id=tenant_b;
  update public.tenants set status='active' where id=tenant_a;

  perform pg_temp.ok(21,'normal runtime blocks a second active tenant',exists(select 1 from pg_indexes where schemaname='public' and indexname='tenants_single_active_runtime_guard' and indexdef like 'CREATE UNIQUE INDEX%'));
  execute 'drop index public.tenants_single_active_runtime_guard';
  update public.tenants set status='active' where id=tenant_b;
  perform pg_temp.ok(22,'multiple active tenants fail closed',(select count(*)=0 from public.get_public_booking_configuration_v1()));
  update public.tenants set status='dormant' where id=tenant_b;
  execute 'create unique index tenants_single_active_runtime_guard on public.tenants ((true)) where status=''active''';

  perform pg_temp.ok(23,'mixed parent hierarchy is blocked by validated tenant FK',exists(select 1 from pg_constraint where conname='shooting_lanes_parent_lane_id_fkey' and convalidated and pg_get_constraintdef(oid) like 'FOREIGN KEY (tenant_id, parent_lane_id)%'));
  perform pg_temp.ok(24,'configuration records inherit tenant through validated lane FKs',(select count(*)=3 from pg_constraint where conname in('lane_booking_rules_lane_id_fkey','lane_booking_durations_lane_id_fkey','lane_pricing_rules_lane_id_fkey') and convalidated));
  perform pg_temp.ok(25,'public DTO contains no PII/internal tenant keys',not exists(select 1 from public.get_public_booking_configuration_v1() row cross join lateral jsonb_object_keys(to_jsonb(row)) key where key in('tenant_id','user_id','email','phone','address','admin_note','membership','audit')));
  perform pg_temp.ok(26,'fixture is transaction scoped',exists(select 1 from public.tenants where id=tenant_b) and exists(select 1 from public.shooting_lanes where id=lane_b));
end;$tests$;

select case when passed then 'ok ' else 'not ok ' end||n||' - '||description from saas9d4e_results order by n;
do $$begin if exists(select 1 from saas9d4e_results where not passed) or (select count(*) from saas9d4e_results)<>26 then raise exception 'SAAS-9D-4E focused test failed'; end if; end$$;
rollback;
