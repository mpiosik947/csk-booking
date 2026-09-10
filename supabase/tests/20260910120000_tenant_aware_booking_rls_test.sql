\set ON_ERROR_STOP on
\pset format unaligned

select '1..60';

begin;

create temporary table test_results (
  test_order integer primary key,
  test_name text not null,
  passed boolean not null,
  result text not null
) on commit drop;

create function pg_temp.ok(integer, text, boolean, text)
returns void language sql as $function$
  insert into pg_temp.test_results values ($1,$2,coalesce($3,false),$4);
$function$;

create function pg_temp.as_actor_text(p_role text, p_user uuid, p_sql text)
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

create function pg_temp.as_actor_raises(p_role text, p_user uuid, p_sql text, p_state text)
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
  v_no_membership uuid := pg_catalog.gen_random_uuid();
  v_pending uuid := pg_catalog.gen_random_uuid();
  v_suspended uuid := pg_catalog.gen_random_uuid();
  v_lane_a_active uuid := pg_catalog.gen_random_uuid();
  v_lane_a_inactive uuid := pg_catalog.gen_random_uuid();
  v_lane_b_active uuid := pg_catalog.gen_random_uuid();
  v_lane_b_inactive uuid := pg_catalog.gen_random_uuid();
  v_price_a uuid := pg_catalog.gen_random_uuid();
  v_price_b uuid := pg_catalog.gen_random_uuid();
  v_res_a_own uuid := pg_catalog.gen_random_uuid();
  v_res_b_own uuid := pg_catalog.gen_random_uuid();
  v_res_a_foreign uuid := pg_catalog.gen_random_uuid();
  v_res_a_none uuid := pg_catalog.gen_random_uuid();
  v_res_a_pending uuid := pg_catalog.gen_random_uuid();
  v_res_a_suspended uuid := pg_catalog.gen_random_uuid();
  v_block_a_active uuid := pg_catalog.gen_random_uuid();
  v_block_a_inactive uuid := pg_catalog.gen_random_uuid();
  v_block_b_active uuid := pg_catalog.gen_random_uuid();
  v_block_b_inactive uuid := pg_catalog.gen_random_uuid();
  v_run text := pg_catalog.replace(pg_catalog.gen_random_uuid()::text,'-','');
  v_rpc_result jsonb;
begin
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values
    (v_admin,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','saas9c2-admin-'||v_run||'@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now()),
    (v_employee,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','saas9c2-employee-'||v_run||'@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now()),
    (v_instructor,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','saas9c2-instructor-'||v_run||'@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now()),
    (v_user_a,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','saas9c2-usera-'||v_run||'@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now()),
    (v_user_b,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','saas9c2-userb-'||v_run||'@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now()),
    (v_no_membership,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','saas9c2-none-'||v_run||'@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now()),
    (v_pending,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','saas9c2-pending-'||v_run||'@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now()),
    (v_suspended,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','saas9c2-suspended-'||v_run||'@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now());

  insert into public.profiles(user_id,email,role)
  values
    (v_admin,'saas9c2-admin-'||v_run||'@example.invalid','admin'),
    (v_employee,'saas9c2-employee-'||v_run||'@example.invalid','pracownik'),
    (v_instructor,'saas9c2-instructor-'||v_run||'@example.invalid','instruktor'),
    (v_user_a,'saas9c2-usera-'||v_run||'@example.invalid','user'),
    (v_user_b,'saas9c2-userb-'||v_run||'@example.invalid','user'),
    (v_pending,'saas9c2-pending-'||v_run||'@example.invalid','user'),
    (v_suspended,'saas9c2-suspended-'||v_run||'@example.invalid','user');

  update public.tenant_memberships set status='pending' where tenant_id=v_csk and user_id=v_pending;
  update public.tenant_memberships set status='suspended' where tenant_id=v_csk and user_id=v_suspended;

  insert into public.tenants(id,name,slug,status)
  values(v_tenant_b,'[TEST][SAAS-9C-2] Tenant B','saas9c2-'||pg_catalog.left(v_run,16),'dormant');
  insert into public.tenant_memberships(tenant_id,user_id,role,status)
  values(v_tenant_b,v_user_a,'user','active');

  insert into public.shooting_lanes(id,tenant_id,name,type,is_active,max_shooters,booking_step_minutes,display_order,resource_kind,parent_lane_id,whole_lane_bookable,positions_bookable)
  values
    (v_lane_a_active,v_csk,'[TEST][9C2] A active','test',true,1,60,9810,'lane',null,true,false),
    (v_lane_a_inactive,v_csk,'[TEST][9C2] A inactive','test',false,1,60,9811,'lane',null,false,false),
    (v_lane_b_active,v_tenant_b,'[TEST][9C2] B active','test',true,1,60,9812,'lane',null,true,false),
    (v_lane_b_inactive,v_tenant_b,'[TEST][9C2] B inactive','test',false,1,60,9813,'lane',null,false,false);

  insert into public.lane_pricing_rules(id,lane_id,day_group,min_shooters,max_shooters,label,hourly_price)
  values(v_price_a,v_lane_a_active,'mon_thu',1,1,'[TEST] A',10),(v_price_b,v_lane_b_active,'mon_thu',1,1,'[TEST] B',20);

  insert into public.reservations(id,user_id,tenant_id,lane_id,customer_name,customer_email,customer_phone,reservation_date,start_time,end_time,duration_minutes,price,reservation_status,payment_status,attendance_status,shooters_count,pricing_rule_id,pricing_day_group_snapshot,lane_name_snapshot,pricing_label_snapshot,price_per_hour_snapshot,total_price,currency_code,creation_request_id)
  values
    (v_res_a_own,v_user_a,v_csk,v_lane_a_active,'[TEST] A','a@example.invalid','000',date '2099-10-01',time '08:00',time '09:00',60,10,'confirmed','pay_on_site','planned',1,v_price_a,'mon_thu','A','A',10,10,'PLN',pg_catalog.gen_random_uuid()),
    (v_res_b_own,v_user_a,v_tenant_b,v_lane_b_active,'[TEST] B','b@example.invalid','000',date '2099-10-02',time '08:00',time '09:00',60,20,'confirmed','pay_on_site','planned',1,v_price_b,'mon_thu','B','B',20,20,'PLN',pg_catalog.gen_random_uuid()),
    (v_res_a_foreign,v_user_b,v_csk,v_lane_a_active,'[TEST] Foreign','foreign@example.invalid','000',date '2099-10-03',time '08:00',time '09:00',60,10,'confirmed','pay_on_site','planned',1,v_price_a,'mon_thu','A','A',10,10,'PLN',pg_catalog.gen_random_uuid()),
    (v_res_a_none,v_no_membership,v_csk,v_lane_a_active,'[TEST] None','none@example.invalid','000',date '2099-10-04',time '08:00',time '09:00',60,10,'confirmed','pay_on_site','planned',1,v_price_a,'mon_thu','A','A',10,10,'PLN',pg_catalog.gen_random_uuid()),
    (v_res_a_pending,v_pending,v_csk,v_lane_a_active,'[TEST] Pending','pending@example.invalid','000',date '2099-10-05',time '08:00',time '09:00',60,10,'confirmed','pay_on_site','planned',1,v_price_a,'mon_thu','A','A',10,10,'PLN',pg_catalog.gen_random_uuid()),
    (v_res_a_suspended,v_suspended,v_csk,v_lane_a_active,'[TEST] Suspended','suspended@example.invalid','000',date '2099-10-06',time '08:00',time '09:00',60,10,'confirmed','pay_on_site','planned',1,v_price_a,'mon_thu','A','A',10,10,'PLN',pg_catalog.gen_random_uuid());

  insert into public.lane_blocks(id,tenant_id,lane_id,block_date,start_time,end_time,reason,is_active)
  values
    (v_block_a_active,v_csk,v_lane_a_active,date '2099-11-01',time '10:00',time '11:00','[TEST] A active',true),
    (v_block_a_inactive,v_csk,v_lane_a_active,date '2099-11-02',time '10:00',time '11:00','[TEST] A inactive',false),
    (v_block_b_active,v_tenant_b,v_lane_b_active,date '2099-11-03',time '10:00',time '11:00','[TEST] B active',true),
    (v_block_b_inactive,v_tenant_b,v_lane_b_active,date '2099-11-04',time '10:00',time '11:00','[TEST] B inactive',false);

  perform pg_temp.ok(1,'exactly six booking SELECT policies exist',
    (select pg_catalog.count(*)=6 from pg_catalog.pg_policies where schemaname='public' and tablename in ('shooting_lanes','reservations','lane_blocks') and cmd='SELECT'),
    'Booking policy inventory differs.');
  perform pg_temp.ok(2,'booking policies no longer reference legacy role helpers',
    not exists(select 1 from pg_catalog.pg_policies where schemaname='public' and tablename in ('shooting_lanes','reservations','lane_blocks') and coalesce(qual,'') ~ '\m(is_admin|is_admin_or_employee|is_admin_or_staff)\M'),
    'Legacy global helper remains in booking RLS.');
  perform pg_temp.ok(3,'booking tables have no client mutation policies',
    not exists(select 1 from pg_catalog.pg_policies where schemaname='public' and tablename in ('shooting_lanes','reservations','lane_blocks') and cmd<>'SELECT'),
    'Unexpected mutation policy exists.');
  perform pg_temp.ok(4,'public helper grants are minimal',
    not pg_catalog.has_function_privilege('public','public.is_active_public_tenant_v1(uuid)','EXECUTE')
    and pg_catalog.has_function_privilege('anon','public.is_active_public_tenant_v1(uuid)','EXECUTE')
    and pg_catalog.has_function_privilege('authenticated','public.is_active_public_tenant_v1(uuid)','EXECUTE')
    and not pg_catalog.has_function_privilege('service_role','public.is_active_public_tenant_v1(uuid)','EXECUTE'),
    'Public helper grants differ.');

  perform pg_temp.ok(5,'anon sees active CSK lane',pg_temp.as_actor_text('anon',null,pg_catalog.format('(select count(*) from public.shooting_lanes where id=%L)',v_lane_a_active))='1','Anon lost active CSK lane.');
  perform pg_temp.ok(6,'anon does not see inactive CSK lane',pg_temp.as_actor_text('anon',null,pg_catalog.format('(select count(*) from public.shooting_lanes where id=%L)',v_lane_a_inactive))='0','Anon saw inactive lane.');
  perform pg_temp.ok(7,'anon does not see dormant tenant lane',pg_temp.as_actor_text('anon',null,pg_catalog.format('(select count(*) from public.shooting_lanes where id=%L)',v_lane_b_active))='0','Anon saw dormant tenant lane.');
  perform pg_temp.ok(8,'ordinary member gets no inactive lane privilege',pg_temp.as_actor_text('authenticated',v_user_a,pg_catalog.format('(select count(*) from public.shooting_lanes where id=%L)',v_lane_a_inactive))='0','User received staff lane access.');
  perform pg_temp.ok(9,'admin sees all own-tenant lanes',pg_temp.as_actor_text('authenticated',v_admin,pg_catalog.format('(select count(*) from public.shooting_lanes where tenant_id=%L)',v_csk))='2','Admin own-tenant lane scope differs.');
  perform pg_temp.ok(10,'admin cannot see tenant B lanes',pg_temp.as_actor_text('authenticated',v_admin,pg_catalog.format('(select count(*) from public.shooting_lanes where tenant_id=%L)',v_tenant_b))='0','Admin crossed tenant lane boundary.');
  perform pg_temp.ok(11,'employee sees all own-tenant lanes',pg_temp.as_actor_text('authenticated',v_employee,pg_catalog.format('(select count(*) from public.shooting_lanes where tenant_id=%L)',v_csk))='2','Employee own-tenant lane scope differs.');
  perform pg_temp.ok(12,'employee cannot see tenant B lanes',pg_temp.as_actor_text('authenticated',v_employee,pg_catalog.format('(select count(*) from public.shooting_lanes where tenant_id=%L)',v_tenant_b))='0','Employee crossed tenant lane boundary.');
  perform pg_temp.ok(13,'instructor retains own-tenant lane visibility',pg_temp.as_actor_text('authenticated',v_instructor,pg_catalog.format('(select count(*) from public.shooting_lanes where tenant_id=%L)',v_csk))='2','Instructor lane contract regressed.');
  perform pg_temp.ok(14,'instructor cannot see tenant B lanes',pg_temp.as_actor_text('authenticated',v_instructor,pg_catalog.format('(select count(*) from public.shooting_lanes where tenant_id=%L)',v_tenant_b))='0','Instructor crossed tenant lane boundary.');
  perform pg_temp.ok(15,'no-membership user retains public lane only',pg_temp.as_actor_text('authenticated',v_no_membership,pg_catalog.format('(select count(*) from public.shooting_lanes where tenant_id=%L)',v_csk))='1','Public lane contract or privilege boundary differs.');

  perform pg_temp.ok(16,'user A sees own reservation A',pg_temp.as_actor_text('authenticated',v_user_a,pg_catalog.format('(select count(*) from public.reservations where id=%L)',v_res_a_own))='1','Owner A denied.');
  perform pg_temp.ok(17,'user A cannot see own reservation in dormant B',pg_temp.as_actor_text('authenticated',v_user_a,pg_catalog.format('(select count(*) from public.reservations where id=%L)',v_res_b_own))='0','Dormant tenant private row exposed.');
  perform pg_temp.ok(18,'user A cannot see user B reservation',pg_temp.as_actor_text('authenticated',v_user_a,pg_catalog.format('(select count(*) from public.reservations where id=%L)',v_res_a_foreign))='0','Foreign reservation exposed.');
  perform pg_temp.ok(19,'admin sees all own-tenant reservations',pg_temp.as_actor_text('authenticated',v_admin,pg_catalog.format('(select count(*) from public.reservations where tenant_id=%L)',v_csk))='5','Admin reservation scope differs.');
  perform pg_temp.ok(20,'admin cannot see tenant B reservation',pg_temp.as_actor_text('authenticated',v_admin,pg_catalog.format('(select count(*) from public.reservations where tenant_id=%L)',v_tenant_b))='0','Admin crossed reservation tenant boundary.');
  perform pg_temp.ok(21,'employee sees all own-tenant reservations',pg_temp.as_actor_text('authenticated',v_employee,pg_catalog.format('(select count(*) from public.reservations where tenant_id=%L)',v_csk))='5','Employee reservation scope differs.');
  perform pg_temp.ok(22,'employee cannot see tenant B reservation',pg_temp.as_actor_text('authenticated',v_employee,pg_catalog.format('(select count(*) from public.reservations where tenant_id=%L)',v_tenant_b))='0','Employee crossed reservation tenant boundary.');
  perform pg_temp.ok(23,'instructor has no global reservation access',pg_temp.as_actor_text('authenticated',v_instructor,pg_catalog.format('(select count(*) from public.reservations where tenant_id=%L)',v_csk))='0','Instructor reservation privilege expanded.');
  perform pg_temp.ok(24,'no-membership owner is denied private reservation',pg_temp.as_actor_text('authenticated',v_no_membership,pg_catalog.format('(select count(*) from public.reservations where id=%L)',v_res_a_none))='0','Missing membership authorized owner read.');
  perform pg_temp.ok(25,'pending owner is denied private reservation',pg_temp.as_actor_text('authenticated',v_pending,pg_catalog.format('(select count(*) from public.reservations where id=%L)',v_res_a_pending))='0','Pending membership authorized.');
  perform pg_temp.ok(26,'suspended owner is denied private reservation',pg_temp.as_actor_text('authenticated',v_suspended,pg_catalog.format('(select count(*) from public.reservations where id=%L)',v_res_a_suspended))='0','Suspended membership authorized.');

  update public.tenants set status='dormant' where id=v_csk;
  update public.tenants set status='active' where id=v_tenant_b;
  perform pg_temp.ok(27,'multi-tenant owner sees own reservation when B is active',pg_temp.as_actor_text('authenticated',v_user_a,pg_catalog.format('(select count(*) from public.reservations where id=%L)',v_res_b_own))='1','Active B ownership contract failed.');
  perform pg_temp.ok(28,'public active tenant switches to B without leaking A',
    pg_temp.as_actor_text('anon',null,pg_catalog.format('(select count(*) from public.shooting_lanes where id in (%L,%L))',v_lane_a_active,v_lane_b_active))='1'
    and pg_temp.as_actor_text('anon',null,pg_catalog.format('(select count(*) from public.shooting_lanes where id=%L)',v_lane_b_active))='1',
    'Active public tenant bridge differs.');
  perform pg_temp.ok(29,'global admin A still cannot read active tenant B',pg_temp.as_actor_text('authenticated',v_admin,pg_catalog.format('(select count(*) from public.reservations where tenant_id=%L)',v_tenant_b))='0','Global role bypassed membership tenant.');
  update public.tenants set status='dormant' where id=v_tenant_b;
  update public.tenants set status='active' where id=v_csk;

  perform pg_temp.ok(30,'user sees active own-tenant lane block',pg_temp.as_actor_text('authenticated',v_user_a,pg_catalog.format('(select count(*) from public.lane_blocks where id=%L)',v_block_a_active))='1','Active block contract regressed.');
  perform pg_temp.ok(31,'user cannot see inactive lane block',pg_temp.as_actor_text('authenticated',v_user_a,pg_catalog.format('(select count(*) from public.lane_blocks where id=%L)',v_block_a_inactive))='0','User received staff block access.');
  perform pg_temp.ok(32,'admin sees all own-tenant lane blocks',pg_temp.as_actor_text('authenticated',v_admin,pg_catalog.format('(select count(*) from public.lane_blocks where tenant_id=%L)',v_csk))='2','Admin block scope differs.');
  perform pg_temp.ok(33,'admin cannot see tenant B lane blocks',pg_temp.as_actor_text('authenticated',v_admin,pg_catalog.format('(select count(*) from public.lane_blocks where tenant_id=%L)',v_tenant_b))='0','Admin crossed block tenant boundary.');
  perform pg_temp.ok(34,'employee sees all own-tenant lane blocks',pg_temp.as_actor_text('authenticated',v_employee,pg_catalog.format('(select count(*) from public.lane_blocks where tenant_id=%L)',v_csk))='2','Employee block scope differs.');
  perform pg_temp.ok(35,'employee cannot see tenant B lane blocks',pg_temp.as_actor_text('authenticated',v_employee,pg_catalog.format('(select count(*) from public.lane_blocks where tenant_id=%L)',v_tenant_b))='0','Employee crossed block tenant boundary.');
  perform pg_temp.ok(36,'instructor retains own-tenant lane-block visibility',pg_temp.as_actor_text('authenticated',v_instructor,pg_catalog.format('(select count(*) from public.lane_blocks where tenant_id=%L)',v_csk))='2','Instructor block scope regressed.');
  perform pg_temp.ok(37,'instructor cannot see tenant B lane blocks',pg_temp.as_actor_text('authenticated',v_instructor,pg_catalog.format('(select count(*) from public.lane_blocks where tenant_id=%L)',v_tenant_b))='0','Instructor crossed block tenant boundary.');
  perform pg_temp.ok(38,'no-membership user cannot read active lane blocks',pg_temp.as_actor_text('authenticated',v_no_membership,pg_catalog.format('(select count(*) from public.lane_blocks where id=%L)',v_block_a_active))='0','Missing membership exposed active block.');
  perform pg_temp.ok(39,'anon has no direct lane-block SELECT ACL',not pg_catalog.has_table_privilege('anon','public.lane_blocks','SELECT'),'Anon lane-block ACL expanded.');

  perform pg_temp.ok(40,'admin direct lane UPDATE by tenant B id is denied',pg_temp.as_actor_raises('authenticated',v_admin,pg_catalog.format('update public.shooting_lanes set name=name where id=%L',v_lane_b_active),'42501'),'Direct lane UPDATE was allowed.');
  perform pg_temp.ok(41,'admin direct lane DELETE by tenant B id is denied',pg_temp.as_actor_raises('authenticated',v_admin,pg_catalog.format('delete from public.shooting_lanes where id=%L',v_lane_b_active),'42501'),'Direct lane DELETE was allowed.');
  perform pg_temp.ok(42,'admin direct lane INSERT with tenant B is denied',pg_temp.as_actor_raises('authenticated',v_admin,pg_catalog.format('insert into public.shooting_lanes(id,tenant_id,name,type,is_active,max_shooters,booking_step_minutes,display_order,resource_kind,whole_lane_bookable,positions_bookable) values(%L,%L,''[TEST] IDOR'',''test'',false,1,60,9999,''lane'',false,false)',pg_catalog.gen_random_uuid(),v_tenant_b),'42501'),'Direct lane INSERT was allowed.');
  perform pg_temp.ok(43,'admin direct reservation UPDATE by tenant B id is denied',pg_temp.as_actor_raises('authenticated',v_admin,pg_catalog.format('update public.reservations set customer_name=customer_name where id=%L',v_res_b_own),'42501'),'Direct reservation UPDATE was allowed.');
  perform pg_temp.ok(44,'admin direct reservation DELETE by tenant B id is denied',pg_temp.as_actor_raises('authenticated',v_admin,pg_catalog.format('delete from public.reservations where id=%L',v_res_b_own),'42501'),'Direct reservation DELETE was allowed.');
  perform pg_temp.ok(45,'admin direct reservation INSERT with tenant B is denied',pg_temp.as_actor_raises('authenticated',v_admin,pg_catalog.format('insert into public.reservations(id,tenant_id,lane_id,customer_name,customer_email,customer_phone,reservation_date,start_time,end_time,duration_minutes,price,reservation_status,payment_status,attendance_status,shooters_count,pricing_rule_id,pricing_day_group_snapshot,lane_name_snapshot,pricing_label_snapshot,price_per_hour_snapshot,total_price,currency_code,creation_request_id) values(%L,%L,%L,''[TEST]'',''x@example.invalid'',''000'',date ''2099-12-01'',time ''08:00'',time ''09:00'',60,20,''confirmed'',''pay_on_site'',''planned'',1,%L,''mon_thu'',''B'',''B'',20,20,''PLN'',%L)',pg_catalog.gen_random_uuid(),v_tenant_b,v_lane_b_active,v_price_b,pg_catalog.gen_random_uuid()),'42501'),'Direct reservation INSERT was allowed.');
  perform pg_temp.ok(46,'admin direct block UPDATE by tenant B id is denied',pg_temp.as_actor_raises('authenticated',v_admin,pg_catalog.format('update public.lane_blocks set reason=reason where id=%L',v_block_b_active),'42501'),'Direct block UPDATE was allowed.');
  perform pg_temp.ok(47,'admin direct block DELETE by tenant B id is denied',pg_temp.as_actor_raises('authenticated',v_admin,pg_catalog.format('delete from public.lane_blocks where id=%L',v_block_b_active),'42501'),'Direct block DELETE was allowed.');
  perform pg_temp.ok(48,'admin direct block INSERT with tenant B is denied',pg_temp.as_actor_raises('authenticated',v_admin,pg_catalog.format('insert into public.lane_blocks(id,tenant_id,lane_id,block_date,start_time,end_time,reason,is_active) values(%L,%L,%L,date ''2099-12-02'',time ''10:00'',time ''11:00'',''[TEST] IDOR'',false)',pg_catalog.gen_random_uuid(),v_tenant_b,v_lane_b_active),'42501'),'Direct block INSERT was allowed.');

  perform pg_temp.ok(49,'authenticated has no booking direct DML ACL',
    not pg_catalog.has_table_privilege('authenticated','public.shooting_lanes','INSERT,UPDATE,DELETE')
    and not pg_catalog.has_table_privilege('authenticated','public.reservations','INSERT,UPDATE,DELETE')
    and not pg_catalog.has_table_privilege('authenticated','public.lane_blocks','INSERT,UPDATE,DELETE'),
    'Authenticated booking DML ACL expanded.');
  perform pg_temp.ok(50,'PUBLIC has no booking direct DML ACL',
    not pg_catalog.has_table_privilege('public','public.shooting_lanes','INSERT,UPDATE,DELETE')
    and not pg_catalog.has_table_privilege('public','public.reservations','INSERT,UPDATE,DELETE')
    and not pg_catalog.has_table_privilege('public','public.lane_blocks','INSERT,UPDATE,DELETE'),
    'PUBLIC booking DML ACL expanded.');
  perform pg_temp.ok(51,'repeated tenant helper evaluation has no RLS recursion',
    pg_temp.as_actor_text('authenticated',v_admin,pg_catalog.format('(select count(*) from public.shooting_lanes cross join generate_series(1,20) where tenant_id=%L)',v_csk))='40',
    'Repeated policy evaluation failed or recursed.');
  perform pg_temp.ok(52,'tenant query indexes remain present',
    (select pg_catalog.count(*)=3 from pg_catalog.pg_indexes where schemaname='public' and indexname in ('shooting_lanes_tenant_hierarchy_order_idx','reservations_tenant_schedule_idx','lane_blocks_tenant_schedule_idx')),
    'Tenant booking indexes differ.');
  perform pg_temp.ok(53,'membership lookup indexes remain present',
    (select pg_catalog.count(*)=2 from pg_catalog.pg_indexes where schemaname='public' and indexname in ('tenant_memberships_user_status_tenant_idx','tenant_memberships_tenant_role_status_user_idx')),
    'Membership indexes differ.');

  perform pg_temp.ok(54,'critical booking writers remain SECURITY DEFINER',
    (select pg_catalog.count(*)=6 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in ('create_reservation_v2','cancel_reservation','admin_create_lane_block','admin_update_lane_block','admin_set_lane_block_active','admin_set_lane_booking_family_configuration_v2') and p.prosecdef),
    'Critical writer SECURITY DEFINER inventory differs.');
  perform pg_temp.ok(55,'critical legacy writers do not yet consume tenant membership helpers',
    (select pg_catalog.count(*)=6 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in ('create_reservation_v2','cancel_reservation','admin_create_lane_block','admin_update_lane_block','admin_set_lane_block_active','admin_set_lane_booking_family_configuration_v2') and p.prosrc !~ '\m(is_tenant_member_v1|has_tenant_role_v1|get_my_tenant_role_v1)\M'),
    'Writer inventory unexpectedly changed; re-review 9D boundary.');

  perform pg_catalog.set_config('request.jwt.claims',pg_catalog.jsonb_build_object('sub',v_admin,'role','authenticated')::text,true);
  perform pg_catalog.set_config('request.jwt.claim.sub',v_admin::text,true);
  execute 'set local role authenticated';
  select public.admin_set_lane_block_active(v_block_b_active,false) into v_rpc_result;
  execute 'reset role';
  perform pg_catalog.set_config('request.jwt.claims','{}',true);
  perform pg_catalog.set_config('request.jwt.claim.sub','',true);
  perform pg_temp.ok(56,'legacy definer demonstrably bypasses new cross-tenant RLS',
    v_rpc_result->>'code'='deactivated' and exists(select 1 from public.lane_blocks where id=v_block_b_active and is_active=false),
    'Expected 9D blocker was not reproduced; writer contract requires reclassification.');
  update public.lane_blocks set is_active=true where id=v_block_b_active;

  perform pg_temp.ok(57,'public booking configuration RPC remains executable by anon',pg_catalog.has_function_privilege('anon','public.get_public_booking_configuration_v1()','EXECUTE'),'Public booking RPC ACL regressed.');
  perform pg_temp.ok(58,'busy-range RPC remains executable by authenticated',pg_catalog.has_function_privilege('authenticated','public.get_lane_booking_busy_ranges_v3(uuid,date)','EXECUTE'),'Busy-range RPC ACL regressed.');
  perform pg_temp.ok(59,'temporary CSK defaults remain unchanged',
    (select pg_catalog.count(*)=3 from information_schema.columns where table_schema='public' and table_name in ('shooting_lanes','reservations','lane_blocks') and column_name='tenant_id' and column_default='''c5c00000-0000-4000-8000-000000000001''::uuid'),
    '9C-2 changed a compatibility default.');
  perform pg_temp.ok(60,'second-active-tenant guard remains present',
    exists(select 1 from pg_catalog.pg_indexes where schemaname='public' and tablename='tenants' and indexname='tenants_single_active_runtime_guard'),
    'Second-active-tenant guard is missing.');
end;
$tests$;

select case when passed then 'ok ' else 'not ok ' end || test_order || ' - ' || test_name || case when passed then '' else E'\n# '||result end
from test_results order by test_order;

do $assert$
begin
  if exists(select 1 from test_results where not passed) then
    raise exception 'SAAS-9C-2B tenant-aware booking RLS failed.';
  end if;
end;
$assert$;

rollback;
