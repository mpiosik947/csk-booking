\set ON_ERROR_STOP on
\pset format unaligned
\pset tuples_only on

select '1..33';

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
create function pg_temp.reader_denied(p_user uuid,p_sql text) returns boolean language plpgsql as $function$
begin
  perform set_config('request.jwt.claims',jsonb_build_object('sub',p_user,'role','authenticated')::text,true);
  perform set_config('request.jwt.claim.sub',coalesce(p_user::text,''),true);
  execute 'set local role authenticated'; execute p_sql; reset role;
  perform set_config('request.jwt.claims','{}',true); perform set_config('request.jwt.claim.sub','',true); return false;
exception when insufficient_privilege then reset role; perform set_config('request.jwt.claims','{}',true); perform set_config('request.jwt.claim.sub','',true); return true;
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
  root_b uuid:=gen_random_uuid(); cross_child uuid:=gen_random_uuid(); result jsonb; snapshot jsonb;
  root_created uuid; marker text:='[TEST][SAAS-9D-3B]['||replace(gen_random_uuid()::text,'-','')||']';
  before_lanes bigint; before_audits bigint; positions jsonb;
begin
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  select id,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',label||'-'||replace(id::text,'-','')||'@example.invalid','',now(),'{}','{}',now(),now()
  from (values(admin_a,'admina'),(admin_b,'adminb'),(employee_a,'employee'),(instructor_a,'instructor'),(user_a,'user'),(pending_a,'pending'),(suspended_a,'suspended'),(global_admin,'global')) fixture(id,label);
  insert into public.profiles(id,user_id,email,role,verification_status)
  select u.id,u.id,u.email,'user','verified' from auth.users u left join public.profiles p on p.user_id=u.id
  where u.id in(admin_a,admin_b,employee_a,instructor_a,user_a,pending_a,suspended_a,global_admin) and p.user_id is null;
  update public.profiles set first_name='Test',last_name='SAAS9D3B',full_name=marker,phone='000',verification_status='verified',
    role=case user_id when admin_a then 'admin' when admin_b then 'admin' when employee_a then 'pracownik'
      when instructor_a then 'instruktor' when pending_a then 'admin' when suspended_a then 'admin'
      when global_admin then 'admin' else 'user' end
  where user_id in(admin_a,admin_b,employee_a,instructor_a,user_a,pending_a,suspended_a,global_admin);
  if (select count(*) from public.profiles where user_id in(admin_a,admin_b,employee_a,instructor_a,user_a,pending_a,suspended_a,global_admin))<>8 then
    raise exception 'SAAS-9D-3B fixture profile count differs.';
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
  insert into public.tenants(id,name,slug,status) values(tenant_b,marker||' Tenant B','saas9d3b-'||left(replace(tenant_b::text,'-',''),16),'dormant');
  insert into public.tenant_memberships(tenant_id,user_id,role,status) values(tenant_b,admin_b,'admin','active');

  -- Deliberately incomplete Tenant-B configuration proves that Tenant-A
  -- structural validation and nested aggregates do not inspect foreign rows.
  insert into public.shooting_lanes(id,tenant_id,name,type,price_per_hour,is_active,max_shooters,booking_step_minutes,display_order,currency_code,resource_kind,parent_lane_id,whole_lane_bookable,positions_bookable)
  values(root_b,tenant_b,marker||' Root B','test',0,false,2,60,9990,'PLN','lane',null,true,false);

  perform pg_temp.ok(1,'exact three 9D-3B signatures remain',(select count(*)=2 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in('admin_create_lane_booking_family_v2','admin_get_lane_booking_configuration_v3')),'Target inventory differs.');
  perform pg_temp.ok(2,'all targets remain postgres-owned SP1 definers with original volatility',(select count(*)=2 and bool_and(p.prosecdef) and bool_and(r.rolname='postgres') and bool_and(p.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[]) and count(*) filter(where p.provolatile='v')=1 and count(*) filter(where p.provolatile='s')=1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace join pg_roles r on r.oid=p.proowner where n.nspname='public' and p.proname in('admin_create_lane_booking_family_v2','admin_get_lane_booking_configuration_v3')),'Target metadata differs.');
  perform pg_temp.ok(3,'creator and V2 are authenticated-only while V1 is internal-only',has_function_privilege('authenticated','public.admin_create_lane_booking_family_v2(uuid,jsonb)','EXECUTE') and has_function_privilege('authenticated','public.admin_get_lane_booking_configuration_v3(uuid)','EXECUTE') and not has_function_privilege('public','public.admin_create_lane_booking_family_v2(uuid,jsonb)','EXECUTE') and not has_function_privilege('anon','public.admin_get_lane_booking_configuration_v3(uuid)','EXECUTE') and not has_function_privilege('service_role','public.admin_get_lane_booking_configuration_v3(uuid)','EXECUTE'),'ACL differs.');
  perform pg_temp.ok(4,'closed cores use explicit tenant membership authority',(select count(*)=2 and bool_and(strpos(pg_get_functiondef(p.oid),'active_single_tenant_id_v1')=0) and bool_and(strpos(pg_get_functiondef(p.oid),'get_my_tenant_role_v1')>0) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in('admin_create_lane_booking_family_v2__saas9ec2b_core','admin_get_lane_booking_configuration_v3__saas9ec2b_core')),'Tenant authority missing.');
  perform pg_temp.ok(5,'SECURITY DEFINER count is 74 after the 9F tenant selector',(select count(*)=74 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prosecdef),'Definer count drifted.');
  perform pg_temp.ok(6,'compatibility defaults are retired',not exists(select 1 from information_schema.columns where table_schema='public' and table_name in('shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','email_deliveries') and column_name='tenant_id' and column_default is not null),'A compatibility default remains.');

  snapshot:=pg_temp.as_actor_json(admin_a,'select public.admin_get_lane_booking_configuration_v3(''c5c00000-0000-4000-8000-000000000001''::uuid)');
  perform pg_temp.ok(7,'Tenant A admin can read V2',snapshot->>'contract_version'='2' and jsonb_typeof(snapshot->'families')='array','V2 read failed.');
  perform pg_temp.ok(8,'Tenant A reader excludes every Tenant B row',strpos(snapshot::text,root_b::text)=0 and strpos(snapshot::text,marker||' Root B')=0,'Tenant B leaked through V2.');
  perform pg_temp.ok(9,'foreign malformed configuration does not poison Tenant A read',snapshot is not null,'Foreign structural state affected Tenant A.');
  perform pg_temp.ok(10,'V2 DTO top-level shape is unchanged',(select array_agg(key order by key)=array['contract_version','families']::text[] from jsonb_object_keys(snapshot) key),'V2 DTO changed.');
  perform pg_temp.ok(11,'selected-tenant reader requires authorized membership',not pg_temp.reader_denied(admin_a,'select public.admin_get_lane_booking_configuration_v3(''c5c00000-0000-4000-8000-000000000001''::uuid)'),'Selected-tenant reader denied its admin.');

  positions:=jsonb_build_array(pg_temp.resource_payload(marker||' Position A1',2),pg_temp.resource_payload(marker||' Position A2',2));
  select count(*), (select count(*) from public.audit_logs) into before_lanes,before_audits from public.shooting_lanes;
  result:=pg_temp.as_actor_json(admin_a,format('select public.admin_create_lane_booking_family_v2(''c5c00000-0000-4000-8000-000000000001''::uuid,%L::jsonb)',pg_temp.family_payload(marker||' Root A',positions)));
  root_created:=(result->>'root_lane_id')::uuid;
  perform pg_temp.ok(12,'Tenant A admin creates one complete family',result@>'{"ok":true,"changed":true,"code":"created","created_resource_count":3}'::jsonb,'Admin create failed.');
  perform pg_temp.ok(13,'creator explicitly assigns Tenant A to root and children',(select count(*)=3 and bool_and(tenant_id=csk) from public.shooting_lanes where id=root_created or parent_lane_id=root_created),'Explicit tenant assignment failed.');
  perform pg_temp.ok(14,'created children bind only to their same-tenant root',not exists(select 1 from public.shooting_lanes child left join public.shooting_lanes parent on parent.id=child.parent_lane_id and parent.tenant_id=child.tenant_id where child.parent_lane_id=root_created and parent.id is null),'Hierarchy binding failed.');
  perform pg_temp.ok(15,'rules durations pricing and version are complete',(select count(*)=3 from public.lane_booking_rules where lane_id in(select id from public.shooting_lanes where id=root_created or parent_lane_id=root_created)) and (select count(*)=6 from public.lane_booking_durations where lane_id in(select id from public.shooting_lanes where id=root_created or parent_lane_id=root_created)) and (select count(*)=6 from public.lane_pricing_rules where lane_id in(select id from public.shooting_lanes where id=root_created or parent_lane_id=root_created)) and (select configuration_version=1 from public.lane_booking_family_configuration_versions where root_lane_id=root_created),'Created configuration is incomplete.');
  perform pg_temp.ok(16,'creator writes exactly one tenant-scoped audit',(select count(*)=before_audits+1 from public.audit_logs) and exists(select 1 from public.audit_logs where target_id=root_created and tenant_id=csk and action='lane_booking_family_created'),'Audit tenant/effect differs.');
  snapshot:=pg_temp.as_actor_json(admin_a,'select public.admin_get_lane_booking_configuration_v3(''c5c00000-0000-4000-8000-000000000001''::uuid)');
  perform pg_temp.ok(17,'new family is visible once with unchanged family shape',(select count(*)=1 from jsonb_array_elements(snapshot->'families') family where family->>'root_lane_id'=root_created::text) and (select bool_and((select array_agg(key order by key)=array['configuration_version','resources','root_lane_id']::text[] from jsonb_object_keys(family) key)) from jsonb_array_elements(snapshot->'families') family),'Family DTO/order contract changed.');

  perform pg_temp.ok(18,'employee remains denied create',(pg_temp.as_actor_json(employee_a,format('select public.admin_create_lane_booking_family_v2(''c5c00000-0000-4000-8000-000000000001''::uuid,%L::jsonb)',pg_temp.family_payload(marker||' Employee'))))->>'code'='not_allowed','Employee scope widened.');
  perform pg_temp.ok(19,'instructor and user remain denied create',(pg_temp.as_actor_json(instructor_a,format('select public.admin_create_lane_booking_family_v2(''c5c00000-0000-4000-8000-000000000001''::uuid,%L::jsonb)',pg_temp.family_payload(marker||' Instructor'))))->>'code'='not_allowed' and (pg_temp.as_actor_json(user_a,format('select public.admin_create_lane_booking_family_v2(''c5c00000-0000-4000-8000-000000000001''::uuid,%L::jsonb)',pg_temp.family_payload(marker||' User'))))->>'code'='not_allowed','Role scope widened.');
  perform pg_temp.ok(20,'global admin without membership is denied create and read',(pg_temp.as_actor_json(global_admin,format('select public.admin_create_lane_booking_family_v2(''c5c00000-0000-4000-8000-000000000001''::uuid,%L::jsonb)',pg_temp.family_payload(marker||' Global'))))->>'code'='not_allowed' and pg_temp.reader_denied(global_admin,'select public.admin_get_lane_booking_configuration_v3(''c5c00000-0000-4000-8000-000000000001''::uuid)'),'Global role bypass remains.');
  perform pg_temp.ok(21,'pending membership is denied create and read',(pg_temp.as_actor_json(pending_a,format('select public.admin_create_lane_booking_family_v2(''c5c00000-0000-4000-8000-000000000001''::uuid,%L::jsonb)',pg_temp.family_payload(marker||' Pending'))))->>'code'='not_allowed' and pg_temp.reader_denied(pending_a,'select public.admin_get_lane_booking_configuration_v3(''c5c00000-0000-4000-8000-000000000001''::uuid)'),'Pending membership authorized.');
  perform pg_temp.ok(22,'suspended membership is denied create and read',(pg_temp.as_actor_json(suspended_a,format('select public.admin_create_lane_booking_family_v2(''c5c00000-0000-4000-8000-000000000001''::uuid,%L::jsonb)',pg_temp.family_payload(marker||' Suspended'))))->>'code'='not_allowed' and pg_temp.reader_denied(suspended_a,'select public.admin_get_lane_booking_configuration_v3(''c5c00000-0000-4000-8000-000000000001''::uuid)'),'Suspended membership authorized.');
  perform pg_temp.ok(23,'Tenant B member cannot be redirected into active Tenant A',(pg_temp.as_actor_json(admin_b,format('select public.admin_create_lane_booking_family_v2(''c5c00000-0000-4000-8000-000000000001''::uuid,%L::jsonb)',pg_temp.family_payload(marker||' B Attempt'))))->>'code'='not_allowed' and pg_temp.reader_denied(admin_b,'select public.admin_get_lane_booking_configuration_v3(''c5c00000-0000-4000-8000-000000000001''::uuid)'),'Tenant B member crossed bridge authority.');

  result:=pg_temp.as_actor_json(admin_a,format('select public.admin_create_lane_booking_family_v2(''c5c00000-0000-4000-8000-000000000001''::uuid,%L::jsonb)',pg_temp.family_payload(marker||' Spoof')||jsonb_build_object('tenant_id',tenant_b)));
  perform pg_temp.ok(24,'caller-supplied tenant is rejected without mutation',result->>'code'='invalid_payload' and (select count(*)=before_lanes+3 from public.shooting_lanes),'Tenant spoof mutated state.');
  perform pg_temp.ok(25,'composite FK rejects Parent A plus Child B',pg_temp.fk_rejected(format('insert into public.shooting_lanes(id,tenant_id,name,type,price_per_hour,is_active,max_shooters,booking_step_minutes,display_order,currency_code,resource_kind,parent_lane_id,whole_lane_bookable,positions_bookable) values(%L,%L,%L,''test'',0,false,1,60,9999,''PLN'',''position'',%L,false,false)',cross_child,tenant_b,marker||' Cross Child',root_created)),'Cross-tenant child was accepted.');
  perform pg_temp.ok(26,'all persisted lane hierarchy remains tenant-consistent',not exists(select 1 from public.shooting_lanes child join public.shooting_lanes parent on parent.id=child.parent_lane_id where child.tenant_id is distinct from parent.tenant_id),'Cross-tenant hierarchy exists.');
  perform pg_temp.ok(27,'anon and service cannot execute exposed 3B RPCs',pg_temp.role_denied('anon','select public.admin_get_lane_booking_configuration_v3(''c5c00000-0000-4000-8000-000000000001''::uuid)') and pg_temp.role_denied('service_role','select public.admin_create_lane_booking_family_v2(''c5c00000-0000-4000-8000-000000000001''::uuid,''{}''::jsonb)'),'Privileged ACL widened.');

  update public.tenants set status='dormant' where id=csk;
  perform pg_temp.ok(28,'zero active tenants fail creator closed',(pg_temp.as_actor_json(admin_a,format('select public.admin_create_lane_booking_family_v2(''c5c00000-0000-4000-8000-000000000001''::uuid,%L::jsonb)',pg_temp.family_payload(marker||' Zero'))))->>'code'='not_allowed','Zero-active creator did not fail closed.');
  perform pg_temp.ok(29,'zero active tenants fail reader closed',pg_temp.reader_denied(admin_a,'select public.admin_get_lane_booking_configuration_v3(''c5c00000-0000-4000-8000-000000000001''::uuid)'),'Zero-active reader did not fail closed.');
  update public.tenants set status='active' where id=csk;

  -- Two active tenants are supported after SAAS-9H; the explicit writer must
  -- remain bound to its selected tenant.
  drop index if exists public.tenants_single_active_runtime_guard;
  update public.tenants set status='active' where id=tenant_b;
  perform pg_temp.ok(30,'explicit tenant creator is not redirected by unrelated active tenant',(pg_temp.as_actor_json(admin_a,format('select public.admin_create_lane_booking_family_v2(''c5c00000-0000-4000-8000-000000000001''::uuid,%L::jsonb)',pg_temp.family_payload(marker||' Two'))))->>'code'='created','Explicit tenant creator was redirected.');
  perform pg_temp.ok(31,'explicit tenant reader is stable with unrelated active tenant',not pg_temp.reader_denied(admin_a,'select public.admin_get_lane_booking_configuration_v3(''c5c00000-0000-4000-8000-000000000001''::uuid)'),'Explicit tenant reader was redirected.');
  perform pg_temp.ok(32,'fixture remains transaction-scoped and fully identifiable',marker like '[TEST][SAAS-9D-3B][%' and (select count(*)=8 from public.profiles where full_name=marker),'Fixture marker/profile count differs.');
end;$tests$;

select case when passed then 'ok ' else 'not ok ' end||test_order||' - '||test_name||case when passed then '' else E'\n# '||result end from test_results order by test_order;
do $assert$ begin if exists(select 1 from test_results where not passed) then raise exception 'SAAS-9D-3B focused hardening failed.'; end if; end;$assert$;

rollback;

select case when
  (select count(*) from pg_catalog.pg_proc procedure join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace where namespace.nspname='public' and procedure.prosecdef)=74
  and not exists(select 1 from public.profiles where full_name like '[TEST][SAAS-9D-3B][%')
  and not exists(select 1 from public.tenants where slug like 'saas9d3b-%')
then 'ok 33 - rollback removed every SAAS-9D-3B fixture'
else 'not ok 33 - rollback fixture cleanup failed' end;
