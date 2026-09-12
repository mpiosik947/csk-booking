\set ON_ERROR_STOP on
\pset format unaligned

select '1..36';

begin;

create temporary table test_results (
  test_order integer primary key,
  test_name text not null,
  passed boolean not null,
  result text not null
) on commit drop;

create function pg_temp.ok(integer,text,boolean,text)
returns void language sql as $function$
  insert into pg_temp.test_results values ($1,$2,coalesce($3,false),$4);
$function$;

create function pg_temp.as_actor_text(p_role text,p_user uuid,p_sql text)
returns text language plpgsql as $function$
declare v_result text;
begin
  perform pg_catalog.set_config('request.jwt.claims',pg_catalog.jsonb_build_object('sub',p_user,'role',p_role)::text,true);
  perform pg_catalog.set_config('request.jwt.claim.sub',coalesce(p_user::text,''),true);
  execute pg_catalog.format('set local role %I',p_role);
  execute 'select ('||p_sql||')::text' into v_result;
  execute 'reset role';
  perform pg_catalog.set_config('request.jwt.claims','{}',true);
  perform pg_catalog.set_config('request.jwt.claim.sub','',true);
  return v_result;
exception when others then
  execute 'reset role';
  perform pg_catalog.set_config('request.jwt.claims','{}',true);
  perform pg_catalog.set_config('request.jwt.claim.sub','',true);
  raise;
end;
$function$;

create function pg_temp.as_actor_raises(p_role text,p_user uuid,p_sql text,p_state text)
returns boolean language plpgsql as $function$
begin
  perform pg_catalog.set_config('request.jwt.claims',pg_catalog.jsonb_build_object('sub',p_user,'role',p_role)::text,true);
  perform pg_catalog.set_config('request.jwt.claim.sub',coalesce(p_user::text,''),true);
  execute pg_catalog.format('set local role %I',p_role);
  execute p_sql;
  execute 'reset role';
  perform pg_catalog.set_config('request.jwt.claims','{}',true);
  perform pg_catalog.set_config('request.jwt.claim.sub','',true);
  return false;
exception when others then
  execute 'reset role';
  perform pg_catalog.set_config('request.jwt.claims','{}',true);
  perform pg_catalog.set_config('request.jwt.claim.sub','',true);
  return sqlstate=p_state;
end;
$function$;

do $tests$
declare
  v_csk constant uuid := 'c5c00000-0000-4000-8000-000000000001'::uuid;
  v_tenant_b uuid := pg_catalog.gen_random_uuid();
  v_admin uuid := pg_catalog.gen_random_uuid();
  v_employee uuid := pg_catalog.gen_random_uuid();
  v_instructor uuid := pg_catalog.gen_random_uuid();
  v_user_a uuid := pg_catalog.gen_random_uuid();
  v_user_b uuid := pg_catalog.gen_random_uuid();
  v_no_member uuid := pg_catalog.gen_random_uuid();
  v_pending uuid := pg_catalog.gen_random_uuid();
  v_suspended uuid := pg_catalog.gen_random_uuid();
  v_lane_a uuid := pg_catalog.gen_random_uuid();
  v_lane_b uuid := pg_catalog.gen_random_uuid();
  v_price_a uuid := pg_catalog.gen_random_uuid();
  v_price_b uuid := pg_catalog.gen_random_uuid();
  v_res_a uuid := pg_catalog.gen_random_uuid();
  v_res_a_cancel uuid := pg_catalog.gen_random_uuid();
  v_res_b uuid := pg_catalog.gen_random_uuid();
  v_token_a uuid := pg_catalog.gen_random_uuid();
  v_token_b uuid := pg_catalog.gen_random_uuid();
  v_request uuid := pg_catalog.gen_random_uuid();
  v_run text := pg_catalog.replace(pg_catalog.gen_random_uuid()::text,'-','');
  v_created_id uuid;
  v_semantic_lf text := E'create function sample() returns integer\nlanguage sql\nas $$ select 1 $$;';
  v_semantic_crlf text;
begin
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values
    (v_admin,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','saas9d1-admin-'||v_run||'@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now()),
    (v_employee,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','saas9d1-employee-'||v_run||'@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now()),
    (v_instructor,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','saas9d1-instructor-'||v_run||'@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now()),
    (v_user_a,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','saas9d1-usera-'||v_run||'@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now()),
    (v_user_b,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','saas9d1-userb-'||v_run||'@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now()),
    (v_no_member,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','saas9d1-none-'||v_run||'@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now()),
    (v_pending,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','saas9d1-pending-'||v_run||'@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now()),
    (v_suspended,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','saas9d1-suspended-'||v_run||'@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now());

  insert into public.profiles(user_id,email,phone,first_name,last_name,full_name,role,verification_status)
  values
    (v_admin,'saas9d1-admin-'||v_run||'@example.invalid','0001','Test','Admin','Test Admin','admin','verified'),
    (v_employee,'saas9d1-employee-'||v_run||'@example.invalid','0002','Test','Employee','Test Employee','pracownik','verified'),
    (v_instructor,'saas9d1-instructor-'||v_run||'@example.invalid','0003','Test','Instructor','Test Instructor','instruktor','verified'),
    (v_user_a,'saas9d1-usera-'||v_run||'@example.invalid','0004','Test','User A','Test User A','user','verified'),
    (v_user_b,'saas9d1-userb-'||v_run||'@example.invalid','0005','Test','User B','Test User B','user','verified'),
    (v_pending,'saas9d1-pending-'||v_run||'@example.invalid','0006','Test','Pending Admin','Test Pending Admin','admin','verified'),
    (v_suspended,'saas9d1-suspended-'||v_run||'@example.invalid','0007','Test','Suspended Admin','Test Suspended Admin','admin','verified');

  update public.tenant_memberships set status='pending' where tenant_id=v_csk and user_id=v_pending;
  update public.tenant_memberships set status='suspended' where tenant_id=v_csk and user_id=v_suspended;

  insert into public.tenants(id,name,slug,status)
  values(v_tenant_b,'[TEST][SAAS-9D-1] Tenant B','saas9d1-'||pg_catalog.left(v_run,16),'dormant');
  insert into public.tenant_memberships(tenant_id,user_id,role,status)
  values(v_tenant_b,v_user_a,'user','active');

  insert into public.shooting_lanes(id,tenant_id,name,type,is_active,max_shooters,booking_step_minutes,display_order,currency_code,resource_kind,parent_lane_id,whole_lane_bookable,positions_bookable)
  values
    (v_lane_a,v_csk,'[TEST][SAAS-9D-1] Lane A','test',true,2,60,9910,'PLN','lane',null,true,false),
    (v_lane_b,v_tenant_b,'[TEST][SAAS-9D-1] Lane B','test',true,2,60,9911,'PLN','lane',null,true,false);
  insert into public.lane_booking_rules(lane_id,online_bookable,max_people_online)
  values(v_lane_a,true,2),(v_lane_b,true,2);
  insert into public.lane_booking_durations(lane_id,duration_minutes,display_order,is_active)
  values(v_lane_a,60,1,true),(v_lane_b,60,1,true);
  insert into public.lane_pricing_rules(id,lane_id,day_group,min_shooters,max_shooters,label,hourly_price,display_order,is_active)
  values
    (v_price_a,v_lane_a,'mon_thu',1,2,'[TEST] A',10,1,true),
    (pg_catalog.gen_random_uuid(),v_lane_a,'fri_sun',1,2,'[TEST] A',10,1,true),
    (v_price_b,v_lane_b,'mon_thu',1,2,'[TEST] B',20,1,true),
    (pg_catalog.gen_random_uuid(),v_lane_b,'fri_sun',1,2,'[TEST] B',20,1,true);

  insert into public.reservations(id,user_id,tenant_id,lane_id,customer_name,customer_email,customer_phone,reservation_date,start_time,end_time,duration_minutes,price,reservation_status,payment_status,attendance_status,check_in_token,shooters_count,pricing_rule_id,pricing_day_group_snapshot,lane_name_snapshot,pricing_label_snapshot,price_per_hour_snapshot,total_price,currency_code,creation_request_id)
  values
    (v_res_a,v_user_a,v_csk,v_lane_a,'Test User A','a@example.invalid','0004',(pg_catalog.transaction_timestamp() at time zone 'Europe/Warsaw')::date,time '00:01',time '23:59',1438,10,'confirmed','pay_on_site','planned',v_token_a,1,v_price_a,'mon_thu','Lane A','A',10,10,'PLN',pg_catalog.gen_random_uuid()),
    (v_res_a_cancel,v_user_a,v_csk,v_lane_a,'Test User A','a@example.invalid','0004',date '2099-10-10',time '08:00',time '09:00',60,10,'confirmed','pay_on_site','planned',pg_catalog.gen_random_uuid(),1,v_price_a,'mon_thu','Lane A','A',10,10,'PLN',pg_catalog.gen_random_uuid()),
    (v_res_b,v_user_b,v_tenant_b,v_lane_b,'Test User B','b@example.invalid','0005',(pg_catalog.transaction_timestamp() at time zone 'Europe/Warsaw')::date,time '00:01',time '23:59',1438,20,'confirmed','pay_on_site','planned',v_token_b,1,v_price_b,'mon_thu','Lane B','B',20,20,'PLN',pg_catalog.gen_random_uuid());

  perform pg_temp.ok(1,'twelve hardened client signatures remain present',(select pg_catalog.count(*)=12 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in ('cancel_reservation','create_reservation_v2','get_check_in_reservation_v1','get_lane_booking_busy_ranges','get_lane_booking_busy_ranges_v2','get_lane_booking_busy_ranges_v3','get_my_reservations_v2','get_public_check_in_status_v1','get_reservation_customer_profiles_v1','update_reservation_admin_note','update_reservation_attendance','update_reservation_payment')),'Hardened wrapper inventory differs.');
  perform pg_temp.ok(2,'all hardened wrappers are protected definers owned by postgres',(select pg_catalog.count(*)=12 and pg_catalog.bool_and(p.prosecdef) and pg_catalog.bool_and(p.proowner=(select oid from pg_catalog.pg_roles where rolname='postgres')) and pg_catalog.bool_and(p.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[]) from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in ('cancel_reservation','create_reservation_v2','get_check_in_reservation_v1','get_lane_booking_busy_ranges','get_lane_booking_busy_ranges_v2','get_lane_booking_busy_ranges_v3','get_my_reservations_v2','get_public_check_in_status_v1','get_reservation_customer_profiles_v1','update_reservation_admin_note','update_reservation_attendance','update_reservation_payment')),'Wrapper metadata differs.');
  perform pg_temp.ok(3,'twelve cores are invoker-only and non-client',(select pg_catalog.count(*)=12 and pg_catalog.bool_and(not p.prosecdef) and pg_catalog.bool_and(not pg_catalog.has_function_privilege('public',p.oid,'EXECUTE')) and pg_catalog.bool_and(not pg_catalog.has_function_privilege('anon',p.oid,'EXECUTE')) and pg_catalog.bool_and(not pg_catalog.has_function_privilege('authenticated',p.oid,'EXECUTE')) and pg_catalog.bool_and(not pg_catalog.has_function_privilege('service_role',p.oid,'EXECUTE')) from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname like '%__saas9d1_core'),'Core isolation differs.');
  perform pg_temp.ok(4,'V2 create core writes lane-derived tenant explicitly',pg_catalog.strpos(pg_catalog.pg_get_functiondef('public.create_reservation_v2__saas9d1_core(uuid,date,time without time zone,integer,integer,uuid,text)'::pg_catalog.regprocedure),'tenant_id, user_id, lane_id')>0 and pg_catalog.strpos(pg_catalog.pg_get_functiondef('public.create_reservation_v2__saas9d1_core(uuid,date,time without time zone,integer,integer,uuid,text)'::pg_catalog.regprocedure),'v_lane.tenant_id, v_user_id, p_lane_id')>0,'Create core does not derive tenant from lane.');
  perform pg_temp.ok(5,'existing composite FK still rejects tenant mismatch',pg_temp.as_actor_raises('postgres',null,pg_catalog.format('insert into public.reservations(id,user_id,tenant_id,lane_id,customer_name,customer_email,customer_phone,reservation_date,start_time,end_time,duration_minutes,price,reservation_status,payment_status,attendance_status,shooters_count,pricing_rule_id,pricing_day_group_snapshot,lane_name_snapshot,pricing_label_snapshot,price_per_hour_snapshot,total_price,currency_code,creation_request_id) values(%L,%L,%L,%L,%L,%L,%L,date %L,time %L,time %L,60,10,%L,%L,%L,1,%L,%L,%L,%L,10,10,%L,%L)',pg_catalog.gen_random_uuid(),v_user_a,v_tenant_b,v_lane_a,'Mismatch','mismatch@example.invalid','000','2099-12-20','08:00','09:00','confirmed','pay_on_site','planned',v_price_a,'mon_thu','A','A','PLN',pg_catalog.gen_random_uuid()),'23503'),'Cross-tenant reservation row was accepted.');
  perform pg_temp.ok(6,'fixture reservation tenants match their lanes',(select tenant_id=v_csk from public.reservations where id=v_res_a) and (select tenant_id=v_tenant_b from public.reservations where id=v_res_b),'Fixture ownership differs.');
  perform pg_temp.ok(7,'legacy create writer is owner-only',not pg_catalog.has_function_privilege('public','public.create_reservation(uuid,date,time without time zone,integer,integer,uuid,text)','EXECUTE') and not pg_catalog.has_function_privilege('anon','public.create_reservation(uuid,date,time without time zone,integer,integer,uuid,text)','EXECUTE') and not pg_catalog.has_function_privilege('authenticated','public.create_reservation(uuid,date,time without time zone,integer,integer,uuid,text)','EXECUTE') and not pg_catalog.has_function_privilege('service_role','public.create_reservation(uuid,date,time without time zone,integer,integer,uuid,text)','EXECUTE'),'Legacy writer still has client EXECUTE.');
  perform pg_temp.ok(8,'service role broad reservation grants were removed',not pg_catalog.has_function_privilege('service_role','public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)','EXECUTE') and not pg_catalog.has_function_privilege('service_role','public.cancel_reservation(uuid)','EXECUTE') and not pg_catalog.has_function_privilege('service_role','public.get_lane_booking_busy_ranges_v3(uuid,date)','EXECUTE') and not pg_catalog.has_function_privilege('service_role','public.update_reservation_attendance(uuid,text)','EXECUTE'),'service_role reservation grant remains.');

  perform pg_temp.ok(9,'CSK admin may update CSK note',pg_temp.as_actor_text('authenticated',v_admin,pg_catalog.format('public.update_reservation_admin_note(%L,%L)->>%L',v_res_a,'tenant note','code'))='updated','Admin own-tenant update failed.');
  perform pg_temp.ok(10,'CSK admin cannot update tenant B',pg_temp.as_actor_text('authenticated',v_admin,pg_catalog.format('public.update_reservation_admin_note(%L,%L)->>%L',v_res_b,'cross','code'))='not_allowed','Admin crossed tenant boundary.');
  perform pg_temp.ok(11,'CSK employee may update payment',pg_temp.as_actor_text('authenticated',v_employee,pg_catalog.format('public.update_reservation_payment(%L,%L)->>%L',v_res_a,'paid','code'))='updated','Employee own-tenant update failed.');
  perform pg_temp.ok(12,'CSK employee cannot update tenant B',pg_temp.as_actor_text('authenticated',v_employee,pg_catalog.format('public.update_reservation_payment(%L,%L)->>%L',v_res_b,'paid','code'))='not_allowed','Employee crossed tenant boundary.');
  perform pg_temp.ok(13,'instructor cannot mutate reservation',pg_temp.as_actor_text('authenticated',v_instructor,pg_catalog.format('public.update_reservation_payment(%L,%L)->>%L',v_res_a,'paid','code'))='not_allowed','Instructor gained reservation mutation.');
  perform pg_temp.ok(14,'no-membership user cannot mutate reservation',pg_temp.as_actor_text('authenticated',v_no_member,pg_catalog.format('public.update_reservation_payment(%L,%L)->>%L',v_res_a,'paid','code'))='not_allowed','No-membership actor gained mutation.');
  perform pg_temp.ok(15,'pending and suspended admins cannot mutate reservation',pg_temp.as_actor_text('authenticated',v_pending,pg_catalog.format('public.update_reservation_payment(%L,%L)->>%L',v_res_a,'paid','code'))='not_allowed' and pg_temp.as_actor_text('authenticated',v_suspended,pg_catalog.format('public.update_reservation_payment(%L,%L)->>%L',v_res_a,'paid','code'))='not_allowed','Inactive privileged membership was accepted.');
  perform pg_temp.ok(16,'owner can cancel own CSK reservation',pg_temp.as_actor_text('authenticated',v_user_a,pg_catalog.format('public.cancel_reservation(%L)->>%L',v_res_a_cancel,'new_status'))='cancelled_by_user','Owner cancellation regressed.');
  perform pg_temp.ok(17,'foreign user cannot cancel reservation',pg_temp.as_actor_raises('authenticated',v_user_b,pg_catalog.format('select public.cancel_reservation(%L)',v_res_a),'42501'),'Foreign cancellation was allowed.');
  perform pg_temp.ok(18,'owner lacks access when owning tenant is dormant',pg_temp.as_actor_raises('authenticated',v_user_b,pg_catalog.format('select public.cancel_reservation(%L)',v_res_b),'42501'),'Dormant-tenant cancellation was allowed.');

  perform pg_temp.ok(19,'CSK admin can perform CSK check-in lookup',pg_temp.as_actor_text('authenticated',v_admin,pg_catalog.format('(select count(*) from public.get_check_in_reservation_v1(%L))',v_token_a))='1','Admin check-in lookup failed.');
  perform pg_temp.ok(20,'CSK employee can perform CSK check-in lookup',pg_temp.as_actor_text('authenticated',v_employee,pg_catalog.format('(select count(*) from public.get_check_in_reservation_v1(%L))',v_token_a))='1','Employee check-in lookup failed.');
  perform pg_temp.ok(21,'CSK admin cannot read tenant B check-in',pg_temp.as_actor_raises('authenticated',v_admin,pg_catalog.format('select count(*) from public.get_check_in_reservation_v1(%L)',v_token_b),'42501'),'Cross-tenant check-in lookup succeeded.');
  perform pg_temp.ok(22,'ordinary user cannot perform staff check-in lookup',pg_temp.as_actor_raises('authenticated',v_user_a,pg_catalog.format('select count(*) from public.get_check_in_reservation_v1(%L)',v_token_a),'42501'),'User gained staff lookup.');
  perform pg_temp.ok(23,'public CSK check-in status remains available',pg_temp.as_actor_text('anon',null,pg_catalog.format('public.get_public_check_in_status_v1(%L)->>%L',v_token_a,'code'))='ready','Public CSK check-in regressed.');
  perform pg_temp.ok(24,'public dormant-tenant token fails closed',pg_temp.as_actor_text('anon',null,pg_catalog.format('public.get_public_check_in_status_v1(%L)->>%L',v_token_b,'code'))='unavailable','Dormant-tenant token was exposed.');

  perform pg_temp.ok(25,'member can read own-tenant busy ranges',pg_temp.as_actor_text('authenticated',v_user_a,pg_catalog.format('(select count(*) from public.get_lane_booking_busy_ranges_v3(%L,date %L))',v_lane_a,'2099-10-10')) is not null,'Own-tenant busy-range call failed.');
  perform pg_temp.ok(26,'CSK admin cannot read tenant B busy ranges',pg_temp.as_actor_raises('authenticated',v_admin,pg_catalog.format('select count(*) from public.get_lane_booking_busy_ranges_v3(%L,date %L)',v_lane_b,'2099-10-10'),'42501'),'Cross-tenant busy ranges were exposed.');
  perform pg_temp.ok(27,'my reservations returns active tenant rows only',pg_temp.as_actor_text('authenticated',v_user_a,pg_catalog.format('(select count(*) from public.get_my_reservations_v2() where id in (%L,%L,%L))',v_res_a,v_res_a_cancel,v_res_b))='2','My-reservations active tenant filter differs.');
  perform pg_temp.ok(28,'admin profile batch allows a single own tenant',pg_temp.as_actor_text('authenticated',v_admin,pg_catalog.format('(select count(*) from public.get_reservation_customer_profiles_v1(array[%L]::uuid[]))',v_res_a))='1','Own-tenant profile batch failed.');
  perform pg_temp.ok(29,'admin profile batch rejects mixed tenants',pg_temp.as_actor_raises('authenticated',v_admin,pg_catalog.format('select count(*) from public.get_reservation_customer_profiles_v1(array[%L,%L]::uuid[])',v_res_a,v_res_b),'42501'),'Mixed-tenant profile batch succeeded.');

  perform pg_temp.ok(30,'authenticated user may create only in active membership tenant',pg_temp.as_actor_text('authenticated',v_user_a,pg_catalog.format('public.create_reservation_v2(%L,date %L,time %L,60,1,%L,%L)->>%L',v_lane_a,'2099-12-07','10:00',v_request,'[TEST][SAAS-9D-1]','code'))='created','Tenant-aware create failed.');
  select id into v_created_id from public.reservations where creation_request_id=v_request;
  perform pg_temp.ok(31,'created reservation tenant is lane-derived without caller input',v_created_id is not null and (select tenant_id=v_csk from public.reservations where id=v_created_id),'Created reservation tenant differs.');
  perform pg_temp.ok(32,'active CSK user cannot create in dormant tenant B',pg_temp.as_actor_text('authenticated',v_user_a,pg_catalog.format('public.create_reservation_v2(%L,date %L,time %L,60,1,%L,%L)->>%L',v_lane_b,'2099-12-07','11:00',pg_catalog.gen_random_uuid(),'[TEST][SAAS-9D-1]','code'))='not_allowed','Cross-tenant create was allowed.');

  v_semantic_crlf := pg_catalog.replace(v_semantic_lf,E'\n',E'\r\n');
  perform pg_temp.ok(33,'normalized fingerprints treat LF and CRLF as equivalent',
    pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(v_semantic_lf,E'\r\n',E'\n'),E'\r',E'\n'))
      =pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(v_semantic_crlf,E'\r\n',E'\n'),E'\r',E'\n')),
    'Line-ending-only definitions produced different canonical fingerprints.');
  perform pg_temp.ok(34,'normalized fingerprints still detect semantic body changes',
    pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(v_semantic_lf,E'\r\n',E'\n'),E'\r',E'\n'))
      <>pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.replace(v_semantic_lf,'select 1','select 2'),E'\r\n',E'\n'),E'\r',E'\n')),
    'A semantic body change was hidden by canonicalization.');
  perform pg_temp.ok(35,'legacy create definition and security metadata remain unchanged',
    (select pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef(p.oid),E'\r\n',E'\n'),E'\r',E'\n'))='3212b32f37ebc8e665a9a94e94260976'
       and p.proowner=(select oid from pg_catalog.pg_roles where rolname='postgres')
       and p.prosecdef
       and p.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[]
     from pg_catalog.pg_proc p
     where p.oid='public.create_reservation(uuid,date,time without time zone,integer,integer,uuid,text)'::pg_catalog.regprocedure),
    'Legacy definition, owner, definer mode or search_path changed.');
  perform pg_temp.ok(36,'legacy create ACL contains no non-owner grantee',
    not exists (
      select 1
      from pg_catalog.pg_proc p
      cross join lateral pg_catalog.aclexplode(coalesce(p.proacl,pg_catalog.acldefault('f',p.proowner))) grants
      where p.oid='public.create_reservation(uuid,date,time without time zone,integer,integer,uuid,text)'::pg_catalog.regprocedure
        and grants.grantee<>p.proowner
    ),
    'Legacy create retains an unapproved EXECUTE grantee.');
end;
$tests$;

select case when passed then 'ok ' else 'not ok ' end||test_order||' - '||test_name||case when passed then '' else E'\n# '||result end
from test_results order by test_order;

do $assert$
begin
  if exists(select 1 from test_results where not passed) then
    raise exception 'SAAS-9D-1 focused tests failed.';
  end if;
end;
$assert$;

rollback;
