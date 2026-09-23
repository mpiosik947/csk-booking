\set ON_ERROR_STOP on
\pset format unaligned

select '1..26';
begin;
create temporary table saas9d4e_results(n integer primary key,description text,passed boolean) on commit drop;
create function pg_temp.ok(integer,text,boolean) returns void language sql as $$
  insert into pg_temp.saas9d4e_results values($1,$2,coalesce($3,false));
$$;
create function pg_temp.role_count(p_role text,p_tenant uuid) returns integer language plpgsql as $$
declare v_count integer;
begin execute pg_catalog.format('set local role %I',p_role); select count(*) into v_count from public.get_public_booking_configuration_v2(p_tenant); reset role; return v_count;
exception when others then reset role; raise; end$$;
create function pg_temp.role_denied(p_role text,p_tenant uuid) returns boolean language plpgsql as $$
begin execute pg_catalog.format('set local role %I',p_role); perform * from public.get_public_booking_configuration_v2(p_tenant); reset role; return false;
exception when others then reset role; return true; end$$;

do $tests$
declare
  tenant_a constant uuid:='c5c00000-0000-4000-8000-000000000001';
  tenant_b constant uuid:='4e000000-0000-4000-8000-000000000001';
  lane_b constant uuid:='4e000000-0000-4000-8000-000000000010';
  a_count integer;
  b_count integer;
begin
  perform pg_temp.ok(1,'wrapper target fingerprint exact',md5(replace(replace(pg_get_functiondef('public.get_public_booking_configuration_v2(uuid)'::regprocedure),E'\r\n',E'\n'),E'\r',E'\n'))='c22681300c18658a77e94b58320c5986');
  perform pg_temp.ok(2,'core target fingerprint exact',md5(replace(replace(pg_get_functiondef('public.get_public_booking_configuration_v1__saas9d4e_core(uuid)'::regprocedure),E'\r\n',E'\n'),E'\r',E'\n'))='ff6f0a91a7c8ad66d885e2fd0c5df265');
  perform pg_temp.ok(3,'wrapper is stable postgres SECURITY DEFINER SP1',exists(select 1 from pg_proc p join pg_roles r on r.oid=p.proowner where p.oid='public.get_public_booking_configuration_v2(uuid)'::regprocedure and p.prosecdef and p.provolatile='s' and r.rolname='postgres' and p.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[]));
  perform pg_temp.ok(4,'core is stable postgres SECURITY INVOKER SP1',exists(select 1 from pg_proc p join pg_roles r on r.oid=p.proowner where p.oid='public.get_public_booking_configuration_v1__saas9d4e_core(uuid)'::regprocedure and not p.prosecdef and p.provolatile='s' and r.rolname='postgres' and p.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[]));
  perform pg_temp.ok(5,'wrapper ACL anon/auth only',not has_function_privilege('public','public.get_public_booking_configuration_v2(uuid)','EXECUTE') and has_function_privilege('anon','public.get_public_booking_configuration_v2(uuid)','EXECUTE') and has_function_privilege('authenticated','public.get_public_booking_configuration_v2(uuid)','EXECUTE') and not has_function_privilege('service_role','public.get_public_booking_configuration_v2(uuid)','EXECUTE'));
  perform pg_temp.ok(6,'core direct client/service execution denied',not has_function_privilege('public','public.get_public_booking_configuration_v1__saas9d4e_core(uuid)','EXECUTE') and not has_function_privilege('anon','public.get_public_booking_configuration_v1__saas9d4e_core(uuid)','EXECUTE') and not has_function_privilege('authenticated','public.get_public_booking_configuration_v1__saas9d4e_core(uuid)','EXECUTE') and not has_function_privilege('service_role','public.get_public_booking_configuration_v1__saas9d4e_core(uuid)','EXECUTE'));
  perform pg_temp.ok(7,'exact 14-field DTO',(select p.pronargs=1 and array_length(p.proargnames,1)=15 from pg_proc p where p.oid='public.get_public_booking_configuration_v2(uuid)'::regprocedure));
  perform pg_temp.ok(8,'wrapper accepts one explicit tenant selector',(select p.pronargs=1 from pg_proc p where p.oid='public.get_public_booking_configuration_v2(uuid)'::regprocedure));
  perform pg_temp.ok(9,'wrapper validates selected active public tenant without exact-single authority',strpos(pg_get_functiondef('public.get_public_booking_configuration_v2(uuid)'::regprocedure),'active_single_tenant_id_v1()')=0 and strpos(pg_get_functiondef('public.get_public_booking_configuration_v2(uuid)'::regprocedure),$$status='active'$$)>0);
  perform pg_temp.ok(10,'core filters root tenant',pg_get_functiondef('public.get_public_booking_configuration_v1__saas9d4e_core(uuid)'::regprocedure) ~ 'resource\.tenant_id\s*=\s*p_tenant_id');
  perform pg_temp.ok(11,'core binds parent to resource tenant',pg_get_functiondef('public.get_public_booking_configuration_v1__saas9d4e_core(uuid)'::regprocedure) ~ 'parent\.tenant_id\s*=\s*resource\.tenant_id');
  perform pg_temp.ok(12,'SECURITY DEFINER count is 74 after the 9F tenant selector',(select count(*)=74 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prosecdef));
  perform pg_temp.ok(13,'compatibility defaults are retired',(select count(*)=0 from information_schema.columns where table_schema='public' and table_name in('shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','email_deliveries') and column_name='tenant_id' and column_default is not null));
  select count(*) into a_count from public.get_public_booking_configuration_v2(tenant_a);
  perform pg_temp.ok(14,'explicit active CSK selector resolves exactly its configuration',a_count=(select count(*) from public.get_public_booking_configuration_v1__saas9d4e_core(tenant_a)));
  perform pg_temp.ok(15,'anon public contract works',pg_temp.role_count('anon',tenant_a)=a_count);
  perform pg_temp.ok(16,'authenticated public contract works',pg_temp.role_count('authenticated',tenant_a)=a_count);

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
  perform pg_temp.ok(18,'dormant B is rejected while explicit A stays isolated',pg_temp.role_denied('anon',tenant_b) and not exists(select 1 from public.get_public_booking_configuration_v2(tenant_a) where lane_id=lane_b));

  update public.tenants set status='dormant' where id=tenant_a;
  perform pg_temp.ok(19,'inactive selected tenant fails closed',pg_temp.role_denied('anon',tenant_a));
  update public.tenants set status='active' where id=tenant_b;
  perform pg_temp.ok(20,'explicit active B resolves only B',(select count(*)=1 from public.get_public_booking_configuration_v2(tenant_b)) and exists(select 1 from public.get_public_booking_configuration_v2(tenant_b) where lane_id=lane_b) and pg_temp.role_count('anon',tenant_b)=1 and pg_temp.role_count('authenticated',tenant_b)=1);
  update public.tenants set status='dormant' where id=tenant_b;
  update public.tenants set status='active' where id=tenant_a;

  perform pg_temp.ok(21,'rollout-only second-active guard is retired',not exists(select 1 from pg_indexes where schemaname='public' and indexname='tenants_single_active_runtime_guard'));
  update public.tenants set status='active' where id=tenant_b;
  perform pg_temp.ok(22,'explicit selectors remain isolated without exact-single authority',(select count(*) from public.get_public_booking_configuration_v2(tenant_a))=a_count and (select count(*) from public.get_public_booking_configuration_v2(tenant_b))=1 and not exists(select 1 from public.get_public_booking_configuration_v2(tenant_a) where lane_id=lane_b));
  update public.tenants set status='dormant' where id=tenant_b;

  perform pg_temp.ok(23,'mixed parent hierarchy is blocked by validated tenant FK',exists(select 1 from pg_constraint where conname='shooting_lanes_parent_lane_id_fkey' and convalidated and pg_get_constraintdef(oid) like 'FOREIGN KEY (tenant_id, parent_lane_id)%'));
  perform pg_temp.ok(24,'configuration records inherit tenant through validated lane FKs',(select count(*)=3 from pg_constraint where conname in('lane_booking_rules_lane_id_fkey','lane_booking_durations_lane_id_fkey','lane_pricing_rules_lane_id_fkey') and convalidated));
  perform pg_temp.ok(25,'public DTO contains no PII/internal tenant keys',not exists(select 1 from public.get_public_booking_configuration_v2(tenant_a) row cross join lateral jsonb_object_keys(to_jsonb(row)) key where key in('tenant_id','user_id','email','phone','address','admin_note','membership','audit')));
  perform pg_temp.ok(26,'fixture is transaction scoped',exists(select 1 from public.tenants where id=tenant_b) and exists(select 1 from public.shooting_lanes where id=lane_b));
end;$tests$;

select case when passed then 'ok ' else 'not ok ' end||n||' - '||description from saas9d4e_results order by n;
do $$begin if exists(select 1 from saas9d4e_results where not passed) or (select count(*) from saas9d4e_results)<>26 then raise exception 'SAAS-9D-4E focused test failed'; end if; end$$;
rollback;
