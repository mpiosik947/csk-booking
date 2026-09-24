\set ON_ERROR_STOP on
\pset format unaligned
\pset tuples_only on

select '1..34';

begin;

create temporary table test_results(test_order integer primary key,test_name text,passed boolean,result text) on commit drop;
create function pg_temp.ok(integer,text,boolean,text) returns void language sql as $function$
  insert into pg_temp.test_results values($1,$2,coalesce($3,false),$4);
$function$;
create function pg_temp.resource_payload(p_name text,p_max integer default 2) returns jsonb language sql immutable as $function$
  select jsonb_build_object(
    'name',p_name,'is_active',true,'online_bookable',true,
    'max_shooters',p_max,'max_people_online',p_max,'booking_step_minutes',60,
    'durations_minutes',jsonb_build_array(60,120),
    'pricing',jsonb_build_array(
      jsonb_build_object('day_group','mon_thu','min_shooters',1,'max_shooters',p_max,'label','Pon-Czw','hourly_price',100),
      jsonb_build_object('day_group','fri_sun','min_shooters',1,'max_shooters',p_max,'label','Pt-Nd','hourly_price',120)
    )
  );
$function$;
create function pg_temp.family_payload(p_name text,p_positions jsonb default '[]'::jsonb) returns jsonb language sql immutable as $function$
  select jsonb_build_object(
    'root',pg_temp.resource_payload(p_name,4)||jsonb_build_object('whole_lane_bookable',true,'positions_bookable',jsonb_array_length(p_positions)>0),
    'positions',p_positions
  );
$function$;
create function pg_temp.as_actor_json(p_user uuid,p_sql text) returns jsonb language plpgsql as $function$
declare v jsonb;
begin
  perform set_config('request.jwt.claims',jsonb_build_object('sub',p_user,'role','authenticated')::text,true);
  perform set_config('request.jwt.claim.sub',coalesce(p_user::text,''),true);
  execute 'set local role authenticated'; execute p_sql into v; reset role;
  perform set_config('request.jwt.claims','{}',true); perform set_config('request.jwt.claim.sub','',true); return v;
exception when others then reset role; perform set_config('request.jwt.claims','{}',true); perform set_config('request.jwt.claim.sub','',true); raise;
end;$function$;
create function pg_temp.role_denied(p_role text,p_sql text) returns boolean language plpgsql as $function$
begin execute format('set local role %I',p_role); execute p_sql; reset role; return false;
exception when insufficient_privilege then reset role; return true; end;$function$;
create function pg_temp.fk_rejected(p_sql text) returns boolean language plpgsql as $function$
begin execute p_sql; return false;
exception when foreign_key_violation or check_violation then return true; end;$function$;

do $tests$
declare
  csk constant uuid:='c5c00000-0000-4000-8000-000000000001';
  tenant_b uuid:=gen_random_uuid(); admin_a uuid:=gen_random_uuid(); admin_b uuid:=gen_random_uuid();
  employee_a uuid:=gen_random_uuid(); instructor_a uuid:=gen_random_uuid(); user_a uuid:=gen_random_uuid();
  pending_a uuid:=gen_random_uuid(); suspended_a uuid:=gen_random_uuid(); global_admin uuid:=gen_random_uuid();
  root_b uuid:=gen_random_uuid(); cross_child uuid:=gen_random_uuid(); root_a uuid; child_a uuid;
  marker text:='[TEST][SAAS-9D-3C]['||replace(gen_random_uuid()::text,'-','')||']';
  result jsonb; snapshot jsonb; resources jsonb; updated_resources jsonb; mixed_resources jsonb; spoof_resources jsonb;
  version_before bigint; version_after bigint; audit_before bigint; audit_after bigint; root_b_name text;
begin
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  select id,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',label||'-'||replace(id::text,'-','')||'@example.invalid','',now(),'{}','{}',now(),now()
  from (values(admin_a,'admina'),(admin_b,'adminb'),(employee_a,'employee'),(instructor_a,'instructor'),(user_a,'user'),(pending_a,'pending'),(suspended_a,'suspended'),(global_admin,'global')) fixture(id,label);
  insert into public.profiles(id,user_id,email,role,verification_status)
  select u.id,u.id,u.email,'user','verified' from auth.users u left join public.profiles p on p.user_id=u.id
  where u.id in(admin_a,admin_b,employee_a,instructor_a,user_a,pending_a,suspended_a,global_admin) and p.user_id is null;
  update public.profiles set first_name='Test',last_name='SAAS9D3C',full_name=marker,phone='000',verification_status='verified',
    role=case user_id when admin_a then 'admin' when admin_b then 'admin' when employee_a then 'pracownik'
      when instructor_a then 'instruktor' when pending_a then 'admin' when suspended_a then 'admin'
      when global_admin then 'admin' else 'user' end
  where user_id in(admin_a,admin_b,employee_a,instructor_a,user_a,pending_a,suspended_a,global_admin);
  if (select count(*) from public.profiles where user_id in(admin_a,admin_b,employee_a,instructor_a,user_a,pending_a,suspended_a,global_admin))<>8 then
    raise exception 'SAAS-9D-3C fixture profile count differs.';
  end if;

  insert into public.tenant_memberships(tenant_id,user_id,role,status) values
    (csk,admin_a,'admin','active'),
    (csk,employee_a,'employee','active'),
    (csk,instructor_a,'instructor','active'),
    (csk,user_a,'user','active'),
    (csk,pending_a,'admin','pending'),
    (csk,suspended_a,'admin','suspended')
  on conflict (tenant_id,user_id) do update
  set role=excluded.role,status=excluded.status;
  delete from public.tenant_memberships where tenant_id=csk and user_id in(admin_b,global_admin);
  insert into public.tenants(id,name,slug,status) values(tenant_b,marker||' Tenant B','saas9d3c-'||left(replace(tenant_b::text,'-',''),16),'dormant');
  insert into public.tenant_memberships(tenant_id,user_id,role,status) values(tenant_b,admin_b,'admin','active');

  insert into public.shooting_lanes(id,tenant_id,name,type,price_per_hour,is_active,max_shooters,booking_step_minutes,display_order,currency_code,resource_kind,parent_lane_id,whole_lane_bookable,positions_bookable)
  values(root_b,tenant_b,marker||' Root B','test',0,false,2,60,9990,'PLN','lane',null,true,false);
  root_b_name:=marker||' Root B';

  perform pg_temp.ok(1,'exact seven planned functions and one internal core exist',(select count(*)=7 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in('admin_set_lane_booking_configuration','admin_set_lane_booking_family_configuration_v2','lane_booking_family_business_snapshot_v2','normalize_lane_booking_family_payload_v2','validate_lane_booking_rule_capacity','validate_shooting_lane_capacity_change','validate_shooting_lane_hierarchy')) and to_regprocedure('public.admin_set_lane_booking_family_configuration_v2__saas9d3c_core(uuid,bigint,jsonb,boolean)') is not null,'Function inventory differs.');
  perform pg_temp.ok(2,'active writer and three triggers are definers while legacy and helpers are invokers',(select count(*)=4 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in('admin_set_lane_booking_family_configuration_v2','validate_lane_booking_rule_capacity','validate_shooting_lane_capacity_change','validate_shooting_lane_hierarchy') and p.prosecdef) and not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in('admin_set_lane_booking_configuration','lane_booking_family_business_snapshot_v2','normalize_lane_booking_family_payload_v2','admin_set_lane_booking_family_configuration_v2__saas9d3c_core') and p.prosecdef),'Security modes differ.');
  perform pg_temp.ok(3,'writer ACL is authenticated-only and every internal surface is closed',has_function_privilege('authenticated','public.admin_set_lane_booking_family_configuration_v2(uuid,bigint,jsonb,boolean)','EXECUTE') and not has_function_privilege('anon','public.admin_set_lane_booking_family_configuration_v2(uuid,bigint,jsonb,boolean)','EXECUTE') and not has_function_privilege('service_role','public.admin_set_lane_booking_family_configuration_v2(uuid,bigint,jsonb,boolean)','EXECUTE') and pg_temp.role_denied('authenticated','select public.lane_booking_family_business_snapshot_v2(gen_random_uuid())') and pg_temp.role_denied('service_role','select public.normalize_lane_booking_family_payload_v2(''[]''::jsonb)'),'ACL differs.');
  perform pg_temp.ok(4,'all eight objects are postgres-owned SP1',(select count(*)=8 and bool_and(r.rolname='postgres') and bool_and(p.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[]) from pg_proc p join pg_namespace n on n.oid=p.pronamespace join pg_roles r on r.oid=p.proowner where n.nspname='public' and p.proname in('admin_set_lane_booking_configuration','admin_set_lane_booking_family_configuration_v2','admin_set_lane_booking_family_configuration_v2__saas9d3c_core','lane_booking_family_business_snapshot_v2','normalize_lane_booking_family_payload_v2','validate_lane_booking_rule_capacity','validate_shooting_lane_capacity_change','validate_shooting_lane_hierarchy')),'Owner or path differs.');
  perform pg_temp.ok(5,'SECURITY DEFINER count is 77 after PRODUCT-10B public landing',(select count(*)=77 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prosecdef),'Definer count differs.');
  perform pg_temp.ok(6,'seven compatibility defaults remain',(select count(*)=0 from information_schema.columns where table_schema='public' and table_name in('shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','email_deliveries') and column_name='tenant_id' and column_default='''c5c00000-0000-4000-8000-000000000001''::uuid'),'Compatibility defaults changed.');
  perform pg_temp.ok(7,'three trigger definitions retain frozen normalized fingerprints',(select count(*)=3 from (values('public.validate_lane_booking_rule_capacity()','78a6c1beb5048645a46d20d735324e2a'),('public.validate_shooting_lane_capacity_change()','96e0199a327831f40bec66c57d37f5ca'),('public.validate_shooting_lane_hierarchy()','dd3c97078341a74edc83ca79e9b19c0f')) expected(signature,fingerprint) join pg_proc p on p.oid=to_regprocedure(expected.signature) where md5(replace(replace(pg_get_functiondef(p.oid),E'\r\n',E'\n'),E'\r',E'\n'))=expected.fingerprint and p.prosecdef),'Trigger drift exists.');
  perform pg_temp.ok(8,'writer core uses membership and contains no global profile role authority',(select strpos(p.prosrc,'get_my_tenant_role_v1(v_tenant_id)')>0 and strpos(p.prosrc,'profile.role')=0 from pg_proc p where p.oid='public.admin_set_lane_booking_family_configuration_v2__saas9d3c_core(uuid,bigint,jsonb,boolean)'::regprocedure),'Authorization body differs.');

  result:=pg_temp.as_actor_json(admin_a,format('select public.admin_create_lane_booking_family_v2(%L,%L::jsonb)',csk,pg_temp.family_payload(marker||' Root A',jsonb_build_array(pg_temp.resource_payload(marker||' Child A',2)))));
  root_a:=(result->>'root_lane_id')::uuid;
  select id into child_a from public.shooting_lanes where parent_lane_id=root_a;
  select configuration_version into version_before from public.lane_booking_family_configuration_versions where root_lane_id=root_a;
  resources:=public.lane_booking_family_business_snapshot_v2(root_a);
  select jsonb_agg(case when item->>'lane_id'=root_a::text then item||jsonb_build_object('name',marker||' Root A Updated') else item end order by item->>'lane_id') into updated_resources from jsonb_array_elements(resources) item;
  select count(*) into audit_before from public.audit_logs;

  result:=pg_temp.as_actor_json(admin_a,format('select public.admin_set_lane_booking_family_configuration_v2(%L,%s,%L::jsonb,false)',root_a,version_before,updated_resources));
  select configuration_version into version_after from public.lane_booking_family_configuration_versions where root_lane_id=root_a;
  select count(*) into audit_after from public.audit_logs;
  perform pg_temp.ok(9,'Tenant A admin updates own family through unchanged writer contract',result@>'{"ok":true,"changed":true,"code":"updated"}'::jsonb and result->>'root_lane_id'=root_a::text,'Own-family update failed: '||coalesce(result::text,'NULL'));
  perform pg_temp.ok(10,'successful write keeps every family resource explicitly in Tenant A',(select count(*)=2 and bool_and(tenant_id=csk) from public.shooting_lanes where id=root_a or parent_lane_id=root_a),'Family tenant changed.');
  perform pg_temp.ok(11,'successful write increments version exactly once',version_after=version_before+1 and (result->>'configuration_version')::bigint=version_after,'Version effect differs.');
  perform pg_temp.ok(12,'successful write creates exactly one tenant-scoped audit',audit_after=audit_before+1 and exists(select 1 from public.audit_logs where target_id=root_a and tenant_id=csk and action='lane_booking_family_configuration_updated'),'Audit effect differs.');
  perform pg_temp.ok(13,'INVOKER snapshot and normalize helpers remain caller-compatible through writer',result->>'code'='updated' and (select name=marker||' Root A Updated' from public.shooting_lanes where id=root_a),'Helper caller compatibility failed.');

  result:=pg_temp.as_actor_json(admin_a,format('select public.admin_set_lane_booking_family_configuration_v2(%L,%s,%L::jsonb,false)',root_a,version_after,updated_resources));
  perform pg_temp.ok(14,'identical retry returns no_change',result@>'{"ok":true,"changed":false,"code":"no_change"}'::jsonb,'No-change contract differs.');
  perform pg_temp.ok(15,'no_change creates no version or audit effect',(select configuration_version=version_after from public.lane_booking_family_configuration_versions where root_lane_id=root_a) and (select count(*)=audit_after from public.audit_logs),'No-change mutated state.');
  result:=pg_temp.as_actor_json(admin_a,format('select public.admin_set_lane_booking_family_configuration_v2(%L,%s,%L::jsonb,false)',root_a,version_before,updated_resources));
  perform pg_temp.ok(16,'stale expected version remains controlled',result->>'code'='stale_configuration' and (select configuration_version=version_after from public.lane_booking_family_configuration_versions where root_lane_id=root_a),'Stale contract differs.');

  perform pg_temp.ok(17,'global admin without membership is denied',(pg_temp.as_actor_json(global_admin,format('select public.admin_set_lane_booking_family_configuration_v2(%L,%s,%L::jsonb,false)',root_a,version_after,updated_resources)))->>'code'='not_allowed','Global role bypass remains.');
  perform pg_temp.ok(18,'pending membership is denied',(pg_temp.as_actor_json(pending_a,format('select public.admin_set_lane_booking_family_configuration_v2(%L,%s,%L::jsonb,false)',root_a,version_after,updated_resources)))->>'code'='not_allowed','Pending membership authorized.');
  perform pg_temp.ok(19,'suspended membership is denied',(pg_temp.as_actor_json(suspended_a,format('select public.admin_set_lane_booking_family_configuration_v2(%L,%s,%L::jsonb,false)',root_a,version_after,updated_resources)))->>'code'='not_allowed','Suspended membership authorized.');
  perform pg_temp.ok(20,'employee retains no family configuration write scope',(pg_temp.as_actor_json(employee_a,format('select public.admin_set_lane_booking_family_configuration_v2(%L,%s,%L::jsonb,false)',root_a,version_after,updated_resources)))->>'code'='not_allowed','Employee scope widened.');
  perform pg_temp.ok(21,'instructor and ordinary user remain denied',(pg_temp.as_actor_json(instructor_a,format('select public.admin_set_lane_booking_family_configuration_v2(%L,%s,%L::jsonb,false)',root_a,version_after,updated_resources)))->>'code'='not_allowed' and (pg_temp.as_actor_json(user_a,format('select public.admin_set_lane_booking_family_configuration_v2(%L,%s,%L::jsonb,false)',root_a,version_after,updated_resources)))->>'code'='not_allowed','Role scope widened.');
  perform pg_temp.ok(22,'Tenant A admin cannot update Tenant B root',(pg_temp.as_actor_json(admin_a,format('select public.admin_set_lane_booking_family_configuration_v2(%L,1,%L::jsonb,false)',root_b,jsonb_build_array())))->>'code'='not_allowed','Foreign root was authorized.');

  select jsonb_agg(case when item->>'lane_id'=child_a::text then item||jsonb_build_object('lane_id',root_b) else item end order by item->>'lane_id') into mixed_resources from jsonb_array_elements(updated_resources) item;
  result:=pg_temp.as_actor_json(admin_a,format('select public.admin_set_lane_booking_family_configuration_v2(%L,%s,%L::jsonb,false)',root_a,version_after,mixed_resources));
  perform pg_temp.ok(23,'Family A plus Lane B is denied atomically',result->>'code' in('invalid_payload','not_allowed') and (select configuration_version=version_after from public.lane_booking_family_configuration_versions where root_lane_id=root_a),'Mixed family changed state.');
  select jsonb_agg(case when item->>'lane_id'=root_a::text then item||jsonb_build_object('tenant_id',tenant_b) else item end order by item->>'lane_id') into spoof_resources from jsonb_array_elements(updated_resources) item;
  result:=pg_temp.as_actor_json(admin_a,format('select public.admin_set_lane_booking_family_configuration_v2(%L,%s,%L::jsonb,false)',root_a,version_after,spoof_resources));
  perform pg_temp.ok(24,'caller-supplied tenant authority is rejected',result->>'code'='invalid_payload' and (select configuration_version=version_after from public.lane_booking_family_configuration_versions where root_lane_id=root_a),'Tenant spoof changed state.');
  perform pg_temp.ok(25,'Parent A plus Child B is rejected by final integrity net',pg_temp.fk_rejected(format('insert into public.shooting_lanes(id,tenant_id,name,type,price_per_hour,is_active,max_shooters,booking_step_minutes,display_order,currency_code,resource_kind,parent_lane_id,whole_lane_bookable,positions_bookable) values(%L,%L,%L,''test'',0,false,1,60,9999,''PLN'',''position'',%L,false,false)',cross_child,tenant_b,marker||' Cross Child',root_a)),'Cross-tenant child was accepted.');
  perform pg_temp.ok(26,'all persisted hierarchy remains tenant-consistent',not exists(select 1 from public.shooting_lanes child join public.shooting_lanes parent on parent.id=child.parent_lane_id where child.tenant_id is distinct from parent.tenant_id),'Cross-tenant hierarchy exists.');
  perform pg_temp.ok(27,'foreign Tenant B resource is unchanged',(select name=root_b_name and tenant_id=tenant_b from public.shooting_lanes where id=root_b),'Foreign resource changed.');
  perform pg_temp.ok(28,'legacy writer is INVOKER with zero client/service EXECUTE',not (select prosecdef from pg_proc where oid='public.admin_set_lane_booking_configuration(uuid,boolean,boolean,boolean,integer,boolean,integer,integer[],jsonb)'::regprocedure) and pg_temp.role_denied('authenticated','select public.admin_set_lane_booking_configuration(gen_random_uuid(),true,true,false,1,true,1,array[60],''[]''::jsonb)') and pg_temp.role_denied('service_role','select public.admin_set_lane_booking_configuration(gen_random_uuid(),true,true,false,1,true,1,array[60],''[]''::jsonb)'),'Legacy writer surface differs.');
  perform pg_temp.ok(29,'both internal helpers are INVOKER and directly closed',not (select prosecdef from pg_proc where oid='public.lane_booking_family_business_snapshot_v2(uuid)'::regprocedure) and not (select prosecdef from pg_proc where oid='public.normalize_lane_booking_family_payload_v2(jsonb)'::regprocedure) and pg_temp.role_denied('anon','select public.lane_booking_family_business_snapshot_v2(gen_random_uuid())'),'Helper mode or ACL differs.');
  perform pg_temp.ok(30,'trigger functions remain closed to client and service roles',pg_temp.role_denied('authenticated','select public.validate_lane_booking_rule_capacity()') and pg_temp.role_denied('service_role','select public.validate_shooting_lane_hierarchy()'),'Trigger ACL widened.');
  perform pg_temp.ok(31,'writer tenant predicates cover reservation block event and audit domains',(select strpos(p.prosrc,'reservation.tenant_id = v_tenant_id')>0 and strpos(p.prosrc,'lane_block.tenant_id = v_tenant_id')>0 and strpos(p.prosrc,'event_lane.tenant_id = v_tenant_id')>0 and strpos(p.prosrc,'event_record.tenant_id = v_tenant_id')>0 and strpos(p.prosrc,'tenant_id, actor_user_id')>0 from pg_proc p where p.oid='public.admin_set_lane_booking_family_configuration_v2__saas9d3c_core(uuid,bigint,jsonb,boolean)'::regprocedure),'Tenant predicates are incomplete.');
  perform pg_temp.ok(32,'negative calls leave family version and audit unchanged',(select configuration_version=version_after from public.lane_booking_family_configuration_versions where root_lane_id=root_a) and (select count(*)=audit_after from public.audit_logs),'Denied call created an effect.');
  perform pg_temp.ok(33,'fixture is transaction-scoped and identifiable',marker like '[TEST][SAAS-9D-3C][%' and (select count(*)=8 from public.profiles where full_name=marker),'Fixture marker differs.');
end;$tests$;

select case when passed then 'ok ' else 'not ok ' end||test_order||' - '||test_name||case when passed then '' else E'\n# '||result end from test_results order by test_order;
do $assert$ begin if exists(select 1 from test_results where not passed) then raise exception 'SAAS-9D-3C focused hardening failed.'; end if; end;$assert$;

rollback;

select case when
  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prosecdef)=77
  and not exists(select 1 from public.profiles where full_name like '[TEST][SAAS-9D-3C][%')
  and not exists(select 1 from public.tenants where slug like 'saas9d3c-%')
then 'ok 34 - rollback removed every SAAS-9D-3C fixture'
else 'not ok 34 - rollback fixture cleanup failed' end;
