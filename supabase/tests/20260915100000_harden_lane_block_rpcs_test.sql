\set ON_ERROR_STOP on
\pset format unaligned

select '1..35';

begin;

create temporary table test_results(test_order integer primary key,test_name text,passed boolean,result text) on commit drop;
create function pg_temp.ok(integer,text,boolean,text) returns void language sql as $function$
  insert into pg_temp.test_results values($1,$2,coalesce($3,false),$4);
$function$;
create function pg_temp.as_actor_json(p_role text,p_user uuid,p_sql text) returns jsonb language plpgsql as $function$
declare v jsonb;
begin
  perform set_config('request.jwt.claims',jsonb_build_object('sub',p_user,'role',p_role)::text,true);
  perform set_config('request.jwt.claim.sub',coalesce(p_user::text,''),true);
  execute format('set local role %I',p_role); execute p_sql into v; reset role;
  perform set_config('request.jwt.claims','{}',true); perform set_config('request.jwt.claim.sub','',true); return v;
exception when others then reset role; perform set_config('request.jwt.claims','{}',true); perform set_config('request.jwt.claim.sub','',true); raise;
end;$function$;
create function pg_temp.denied(p_role text,p_sql text) returns boolean language plpgsql as $function$
begin execute format('set local role %I',p_role); execute p_sql; reset role; return false;
exception when insufficient_privilege then reset role; return true; when others then reset role; raise;
end;$function$;
create function pg_temp.rejected(p_sql text) returns boolean language plpgsql as $function$
begin execute p_sql; return false; exception when foreign_key_violation or check_violation then return true; end;$function$;

do $tests$
declare
  csk constant uuid:='c5c00000-0000-4000-8000-000000000001';
  tenant_b uuid:=gen_random_uuid(); admin_a uuid:=gen_random_uuid(); employee_a uuid:=gen_random_uuid();
  instructor_a uuid:=gen_random_uuid(); user_a uuid:=gen_random_uuid(); pending_a uuid:=gen_random_uuid();
  suspended_a uuid:=gen_random_uuid(); global_admin uuid:=gen_random_uuid(); admin_b uuid:=gen_random_uuid();
  lane_a uuid:=gen_random_uuid(); lane_a2 uuid:=gen_random_uuid(); lane_b uuid:=gen_random_uuid();
  block_a uuid:=gen_random_uuid(); block_b uuid:=gen_random_uuid(); block_toggle uuid:=gen_random_uuid();
  event_a uuid:=gen_random_uuid(); event_b uuid:=gen_random_uuid(); reservation_a uuid:=gen_random_uuid(); reservation_b uuid:=gen_random_uuid();
  price_a uuid:=gen_random_uuid(); price_b uuid:=gen_random_uuid(); result jsonb; created_id uuid;
  run_id text:=replace(gen_random_uuid()::text,'-',''); marker text; before_count integer;
begin
  marker:='[TEST][SAAS-9D-3A]['||run_id||']';

  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  select id,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',label||'-'||run_id||'@example.invalid','',now(),'{}','{}',now(),now()
  from (values(admin_a,'admin'),(employee_a,'employee'),(instructor_a,'instructor'),(user_a,'user'),(pending_a,'pending'),(suspended_a,'suspended'),(global_admin,'global'),(admin_b,'adminb')) fixture(id,label);
  insert into public.profiles(id,user_id,email,role,verification_status)
  select u.id,u.id,u.email,'user','verified' from auth.users u left join public.profiles p on p.user_id=u.id
  where u.id in(admin_a,employee_a,instructor_a,user_a,pending_a,suspended_a,global_admin,admin_b) and p.user_id is null;
  update public.profiles set first_name='Test',last_name='SAAS9D3A',full_name=marker,phone='000',verification_status='verified',
    role=case user_id when admin_a then 'admin' when employee_a then 'pracownik' when instructor_a then 'instruktor'
      when pending_a then 'admin' when suspended_a then 'pracownik' when global_admin then 'admin' when admin_b then 'admin' else 'user' end
  where user_id in(admin_a,employee_a,instructor_a,user_a,pending_a,suspended_a,global_admin,admin_b);
  if (select count(*) from public.profiles where user_id in(admin_a,employee_a,instructor_a,user_a,pending_a,suspended_a,global_admin,admin_b))<>8 then
    raise exception 'SAAS-9D-3A fixture profile count differs.';
  end if;

  insert into public.tenant_memberships(tenant_id,user_id,role,status) values
    (csk,admin_a,'admin','active'),
    (csk,employee_a,'employee','active'),
    (csk,instructor_a,'instructor','active'),
    (csk,user_a,'user','active'),
    (csk,pending_a,'admin','pending'),
    (csk,suspended_a,'employee','suspended')
  on conflict (tenant_id,user_id) do update
  set role=excluded.role,status=excluded.status;
  delete from public.tenant_memberships where tenant_id=csk and user_id=global_admin;
  insert into public.tenants(id,name,slug,status) values(tenant_b,marker||' Tenant B','saas9d3a-'||left(run_id,16),'dormant');
  insert into public.tenant_memberships(tenant_id,user_id,role,status) values(tenant_b,admin_b,'admin','active');

  insert into public.shooting_lanes(id,tenant_id,name,type,price_per_hour,is_active,max_shooters,booking_step_minutes,display_order,currency_code,resource_kind,parent_lane_id,whole_lane_bookable,positions_bookable)
  values
    (lane_a,csk,marker||' Lane A','test',10,true,1,60,9960,'PLN','lane',null,true,false),
    (lane_a2,csk,marker||' Lane A2','test',10,true,1,60,9961,'PLN','lane',null,true,false),
    (lane_b,tenant_b,marker||' Lane B','test',20,true,1,60,9962,'PLN','lane',null,true,false);
  insert into public.lane_pricing_rules(id,lane_id,day_group,min_shooters,max_shooters,label,hourly_price)
  values(price_a,lane_a,'mon_thu',1,1,marker,10),(price_b,lane_b,'mon_thu',1,1,marker,20);
  insert into public.lane_blocks(id,tenant_id,lane_id,block_date,start_time,end_time,reason,is_active)
  values(block_a,csk,lane_a,date '2099-12-10',time '08:00',time '09:00',marker||' Block A',true),
        (block_toggle,csk,lane_a2,date '2099-12-11',time '08:00',time '09:00',marker||' Toggle',false),
        (block_b,tenant_b,lane_b,date '2099-12-12',time '08:00',time '09:00',marker||' Block B',true);
  insert into public.events(id,tenant_id,title,description,event_date,start_time,end_time,location,price,max_participants,is_active)
  values(event_a,csk,marker||' Event A','A',date '2099-12-20',time '10:00',time '11:00','A',0,10,true),
        (event_b,tenant_b,marker||' Event B','B',date '2099-12-21',time '10:00',time '11:00','B',0,10,true);
  insert into public.event_lanes(tenant_id,event_id,lane_id) values(csk,event_a,lane_a),(tenant_b,event_b,lane_b);
  insert into public.reservations(id,user_id,tenant_id,lane_id,customer_name,customer_email,customer_phone,reservation_date,start_time,end_time,duration_minutes,price,reservation_status,payment_status,attendance_status,shooters_count,pricing_rule_id,pricing_day_group_snapshot,lane_name_snapshot,pricing_label_snapshot,price_per_hour_snapshot,total_price,currency_code,creation_request_id)
  values
    (reservation_a,user_a,csk,lane_a,marker,'a@example.invalid','000',date '2099-12-22',time '10:00',time '11:00',60,10,'confirmed','pay_on_site','planned',1,price_a,'mon_thu','A','A',10,10,'PLN',gen_random_uuid()),
    (reservation_b,admin_b,tenant_b,lane_b,marker,'b@example.invalid','000',date '2099-12-23',time '10:00',time '11:00',60,20,'confirmed','pay_on_site','planned',1,price_b,'mon_thu','B','B',20,20,'PLN',gen_random_uuid());

  perform pg_temp.ok(1,'exact three active lane-block signatures remain',(select count(*)=3 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in('admin_create_lane_block','admin_set_lane_block_active','admin_update_lane_block')),'Active signature inventory differs.');
  perform pg_temp.ok(2,'wrappers are postgres-owned volatile SP1 definers',(select count(*)=3 and bool_and(p.prosecdef) and bool_and(p.provolatile='v') and bool_and(r.rolname='postgres') and bool_and(p.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[]) from pg_proc p join pg_namespace n on n.oid=p.pronamespace join pg_roles r on r.oid=p.proowner where n.nspname='public' and p.proname in('admin_create_lane_block','admin_set_lane_block_active','admin_update_lane_block')),'Wrapper metadata differs.');
  perform pg_temp.ok(3,'active RPC ACL is authenticated-only',(select count(*)=3 and bool_and(not has_function_privilege('public',p.oid,'EXECUTE')) and bool_and(not has_function_privilege('anon',p.oid,'EXECUTE')) and bool_and(has_function_privilege('authenticated',p.oid,'EXECUTE')) and bool_and(not has_function_privilege('service_role',p.oid,'EXECUTE')) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in('admin_create_lane_block','admin_set_lane_block_active','admin_update_lane_block')),'Active ACL differs.');
  perform pg_temp.ok(4,'three internal cores are invoker-only and inaccessible',(select count(*)=3 and bool_and(not p.prosecdef) and bool_and(not has_function_privilege('public',p.oid,'EXECUTE')) and bool_and(not has_function_privilege('anon',p.oid,'EXECUTE')) and bool_and(not has_function_privilege('authenticated',p.oid,'EXECUTE')) and bool_and(not has_function_privilege('service_role',p.oid,'EXECUTE')) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname like '%__saas9d3a_core'),'Core isolation differs.');
  perform pg_temp.ok(5,'normalized wrapper definitions use membership authority',(select count(*)=3 and bool_and(strpos(replace(replace(pg_get_functiondef(p.oid),E'\r\n',E'\n'),E'\r',E'\n'),'get_my_tenant_role_v1')>0) and bool_and(strpos(pg_get_functiondef(p.oid),'profile.role')=0) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in('admin_create_lane_block','admin_set_lane_block_active','admin_update_lane_block')),'Membership authority guard is absent.');
  perform pg_temp.ok(6,'create core stores explicit tenant and tenant-filters conflicts',strpos(pg_get_functiondef('public.admin_create_lane_block__saas9d3a_core(uuid,date,time without time zone,time without time zone,text)'::regprocedure),'v_lane.tenant_id,')>0 and strpos(pg_get_functiondef('public.admin_create_lane_block__saas9d3a_core(uuid,date,time without time zone,time without time zone,text)'::regprocedure),'reservation.tenant_id = v_lane.tenant_id')>0 and strpos(pg_get_functiondef('public.admin_create_lane_block__saas9d3a_core(uuid,date,time without time zone,time without time zone,text)'::regprocedure),'event_record.tenant_id = v_lane.tenant_id')>0,'Create core tenant binding differs.');
  perform pg_temp.ok(7,'update and toggle cores tenant-filter every conflict domain',strpos(pg_get_functiondef('public.admin_update_lane_block__saas9d3a_core(uuid,uuid,date,time without time zone,time without time zone,text,boolean)'::regprocedure),'reservation.tenant_id = v_current.tenant_id')>0 and strpos(pg_get_functiondef('public.admin_update_lane_block__saas9d3a_core(uuid,uuid,date,time without time zone,time without time zone,text,boolean)'::regprocedure),'event_record.tenant_id = v_current.tenant_id')>0 and strpos(pg_get_functiondef('public.admin_set_lane_block_active__saas9d3a_core(uuid,boolean)'::regprocedure),'reservation.tenant_id = v_current.tenant_id')>0 and strpos(pg_get_functiondef('public.admin_set_lane_block_active__saas9d3a_core(uuid,boolean)'::regprocedure),'event_record.tenant_id = v_current.tenant_id')>0,'Update/toggle tenant predicates differ.');
  perform pg_temp.ok(8,'seven compatibility defaults remain',(select count(*)=0 from information_schema.columns where table_schema='public' and table_name in('shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','email_deliveries') and column_name='tenant_id' and column_default='''c5c00000-0000-4000-8000-000000000001''::uuid'),'Compatibility defaults changed.');

  result:=pg_temp.as_actor_json('authenticated',admin_a,format('select public.admin_create_lane_block(%L,date ''2099-12-13'',time ''10:00'',time ''11:00'',%L)',lane_a,marker||' Admin create'));
  created_id:=(result->>'lane_block_id')::uuid;
  perform pg_temp.ok(9,'Tenant A admin creates Lane A block',result@>'{"ok":true,"changed":true,"code":"created"}'::jsonb,'Admin create failed.');
  perform pg_temp.ok(10,'created block derives CSK tenant from lane',(select tenant_id=csk and lane_id=lane_a from public.lane_blocks where id=created_id),'Create used wrong tenant.');
  result:=pg_temp.as_actor_json('authenticated',employee_a,format('select public.admin_create_lane_block(%L,date ''2099-12-14'',time ''10:00'',time ''11:00'',%L)',lane_a2,marker||' Employee create'));
  perform pg_temp.ok(11,'Tenant A employee preserves create permission',result->>'code'='created','Employee create failed.');

  select count(*) into before_count from public.lane_blocks;
  result:=pg_temp.as_actor_json('authenticated',admin_a,format('select public.admin_create_lane_block(%L,date ''2099-12-15'',time ''10:00'',time ''11:00'',%L)',lane_b,marker||' Cross tenant'));
  perform pg_temp.ok(12,'Tenant A staff cannot create on Lane B',result->>'code'='not_allowed' and (select count(*) from public.lane_blocks)=before_count,'Cross-tenant create mutated state.');
  perform pg_temp.ok(13,'Tenant A staff cannot toggle Block B',(pg_temp.as_actor_json('authenticated',admin_a,format('select public.admin_set_lane_block_active(%L,false)',block_b)))->>'code'='not_allowed' and (select is_active from public.lane_blocks where id=block_b),'Cross-tenant toggle mutated state.');
  result:=pg_temp.as_actor_json('authenticated',admin_a,format('select public.admin_update_lane_block(%L,%L,date ''2099-12-16'',time ''10:00'',time ''11:00'',%L,true)',block_a,lane_b,marker));
  perform pg_temp.ok(14,'Block A cannot move to Lane B',result->>'code'='not_allowed' and (select tenant_id=csk and lane_id=lane_a from public.lane_blocks where id=block_a),'Cross-tenant move mutated block.');
  perform pg_temp.ok(15,'Tenant A staff cannot update Block B',(pg_temp.as_actor_json('authenticated',employee_a,format('select public.admin_update_lane_block(%L,%L,date ''2099-12-17'',time ''10:00'',time ''11:00'',%L,true)',block_b,lane_b,marker)))->>'code'='not_allowed' and (select tenant_id=tenant_b and lane_id=lane_b from public.lane_blocks where id=block_b),'Foreign block update mutated state.');

  perform pg_temp.ok(16,'global legacy admin without membership is denied',(pg_temp.as_actor_json('authenticated',global_admin,format('select public.admin_set_lane_block_active(%L,false)',block_a)))->>'code'='not_allowed','Global role bypass remains.');
  perform pg_temp.ok(17,'pending membership is denied',(pg_temp.as_actor_json('authenticated',pending_a,format('select public.admin_create_lane_block(%L,date ''2099-12-18'',time ''10:00'',time ''11:00'',%L)',lane_a,marker)))->>'code'='not_allowed','Pending membership authorized.');
  perform pg_temp.ok(18,'suspended membership is denied',(pg_temp.as_actor_json('authenticated',suspended_a,format('select public.admin_set_lane_block_active(%L,false)',block_a)))->>'code'='not_allowed','Suspended membership authorized.');
  perform pg_temp.ok(19,'instructor and ordinary user are denied',(pg_temp.as_actor_json('authenticated',instructor_a,format('select public.admin_set_lane_block_active(%L,false)',block_a)))->>'code'='not_allowed' and (pg_temp.as_actor_json('authenticated',user_a,format('select public.admin_set_lane_block_active(%L,false)',block_a)))->>'code'='not_allowed','Role scope widened.');

  result:=pg_temp.as_actor_json('authenticated',employee_a,format('select public.admin_update_lane_block(%L,%L,date ''2099-12-19'',time ''12:00'',time ''13:00'',%L,true)',block_a,lane_a2,marker||' Updated'));
  perform pg_temp.ok(20,'same-tenant employee updates block',result@>'{"ok":true,"changed":true,"code":"updated"}'::jsonb and (select tenant_id=csk and lane_id=lane_a2 from public.lane_blocks where id=block_a),'Same-tenant update failed.');
  result:=pg_temp.as_actor_json('authenticated',admin_a,format('select public.admin_set_lane_block_active(%L,true)',block_toggle));
  perform pg_temp.ok(21,'same-tenant admin activates block',result->>'code'='activated' and (select is_active from public.lane_blocks where id=block_toggle),'Activation failed.');
  perform pg_temp.ok(22,'repeat activation is idempotent',(pg_temp.as_actor_json('authenticated',admin_a,format('select public.admin_set_lane_block_active(%L,true)',block_toggle)))->>'code'='no_change','Activation no-change contract regressed.');

  result:=pg_temp.as_actor_json('authenticated',admin_a,format('select public.admin_create_lane_block(%L,date ''2099-12-22'',time ''10:15'',time ''10:45'',%L)',lane_a,marker||' Reservation conflict'));
  perform pg_temp.ok(23,'same-tenant reservation conflict remains enforced',result->>'code'='conflict_reservation','Reservation conflict was missed.');
  result:=pg_temp.as_actor_json('authenticated',admin_a,format('select public.admin_create_lane_block(%L,date ''2099-12-20'',time ''10:15'',time ''10:45'',%L)',lane_a,marker||' Event conflict'));
  perform pg_temp.ok(24,'same-tenant event conflict remains enforced',result->>'code'='conflict_event','Event conflict was missed.');
  perform pg_temp.ok(25,'invalid input response remains compatible',(pg_temp.as_actor_json('authenticated',admin_a,format('select public.admin_create_lane_block(%L,null,time ''10:00'',time ''11:00'',null)',lane_a)))->>'code'='invalid_input','Invalid input contract changed.');
  perform pg_temp.ok(26,'missing block response remains compatible',(pg_temp.as_actor_json('authenticated',admin_a,format('select public.admin_set_lane_block_active(%L,false)',gen_random_uuid())))->>'code'='block_not_found','Missing block contract changed.');

  update public.tenants set status='dormant' where id=csk;
  update public.tenants set status='active' where id=tenant_b;
  result:=pg_temp.as_actor_json('authenticated',admin_b,format('select public.admin_create_lane_block(%L,date ''2099-12-24'',time ''10:00'',time ''11:00'',%L)',lane_b,marker||' Tenant B'));
  perform pg_temp.ok(27,'active Tenant B admin creates Lane B block',result->>'code'='created' and (select tenant_id=tenant_b from public.lane_blocks where id=(result->>'lane_block_id')::uuid),'Tenant B create failed.');
  perform pg_temp.ok(28,'inactive Tenant A membership cannot manage while tenant dormant',(pg_temp.as_actor_json('authenticated',admin_a,format('select public.admin_set_lane_block_active(%L,false)',block_a)))->>'code'='not_allowed','Dormant tenant authorized staff.');
  update public.tenants set status='dormant' where id=tenant_b;
  update public.tenants set status='active' where id=csk;

  perform pg_temp.ok(29,'anon cannot execute lane-block writers',pg_temp.denied('anon',format('select public.admin_set_lane_block_active(%L,false)',block_a)),'Anon executed writer.');
  perform pg_temp.ok(30,'service role cannot execute lane-block writers',pg_temp.denied('service_role',format('select public.admin_set_lane_block_active(%L,false)',block_a)),'Service role executed client writer.');
  perform pg_temp.ok(31,'composite FK rejects a mismatched block/lane tenant',pg_temp.rejected(format('insert into public.lane_blocks(id,tenant_id,lane_id,block_date,start_time,end_time,is_active) values(%L,%L,%L,date ''2099-12-30'',time ''10:00'',time ''11:00'',true)',gen_random_uuid(),tenant_b,lane_a)),'Mismatched direct row was accepted.');
  perform pg_temp.ok(32,'lane-block rows remain tenant-consistent',not exists(select 1 from public.lane_blocks block left join public.shooting_lanes lane on lane.id=block.lane_id and lane.tenant_id=block.tenant_id where lane.id is null),'A cross-tenant block exists.');
  perform pg_temp.ok(33,'SECURITY DEFINER inventory includes PRODUCT-10B public readers',(select count(*)=  100 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prosecdef),'Definer count drifted.');
  perform pg_temp.ok(34,'Booking and Events public contract fingerprints include PRODUCT-10D entitlement gates',md5(replace(replace(pg_get_functiondef('public.get_public_booking_configuration_v2(uuid)'::regprocedure),E'\r\n',E'\n'),E'\r',E'\n'))='96b419fa86c59606bc6f953abbeac73f' and md5(replace(replace(pg_get_functiondef('public.get_public_event_list_v3(uuid,text,text,integer,integer)'::regprocedure),E'\r\n',E'\n'),E'\r',E'\n'))='11584f47abc277a6885f419822b917a2','Public entitlement gate drifted.');
  perform pg_temp.ok(35,'test fixture is isolated by unique marker and transaction',(select count(*)>=8 from public.profiles where full_name=marker) and marker like '[TEST][SAAS-9D-3A][%','Fixture isolation marker differs.');
end;$tests$;

select case when passed then 'ok ' else 'not ok ' end||test_order||' - '||test_name||case when passed then '' else E'\n# '||result end from test_results order by test_order;
do $assert$ begin if exists(select 1 from test_results where not passed) then raise exception 'SAAS-9D-3A lane-block hardening failed.'; end if; end;$assert$;

rollback;
