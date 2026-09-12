\set ON_ERROR_STOP on
\pset format unaligned

select '1..64';

begin;

create temporary table test_results (
  test_order integer primary key,
  test_name text not null,
  passed boolean not null,
  result text not null
) on commit drop;

create function pg_temp.ok(integer,text,boolean,text)
returns void language sql as $function$
  insert into pg_temp.test_results values($1,$2,coalesce($3,false),$4);
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
  v_unrelated uuid := pg_catalog.gen_random_uuid();
  v_global_admin uuid := pg_catalog.gen_random_uuid();
  v_pending uuid := pg_catalog.gen_random_uuid();
  v_suspended uuid := pg_catalog.gen_random_uuid();
  v_registered uuid := pg_catalog.gen_random_uuid();
  v_lane_a_public uuid := pg_catalog.gen_random_uuid();
  v_lane_a_private uuid := pg_catalog.gen_random_uuid();
  v_lane_b uuid := pg_catalog.gen_random_uuid();
  v_price_a_public uuid := pg_catalog.gen_random_uuid();
  v_price_a_private uuid := pg_catalog.gen_random_uuid();
  v_price_b uuid := pg_catalog.gen_random_uuid();
  v_reservation_a uuid := pg_catalog.gen_random_uuid();
  v_reservation_b uuid := pg_catalog.gen_random_uuid();
  v_event_a uuid := pg_catalog.gen_random_uuid();
  v_event_b uuid := pg_catalog.gen_random_uuid();
  v_registration_a uuid := pg_catalog.gen_random_uuid();
  v_registration_b uuid := pg_catalog.gen_random_uuid();
  v_audit_a uuid := pg_catalog.gen_random_uuid();
  v_audit_b uuid := pg_catalog.gen_random_uuid();
  v_audit_global uuid := pg_catalog.gen_random_uuid();
  v_run text := pg_catalog.replace(pg_catalog.gen_random_uuid()::text,'-','');
  v_marker text;
  v_created_test_trigger boolean := false;
begin
  v_marker := '[TEST][SAAS-9C-2D]['||v_run||']';

  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values
    (v_admin,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','9c2d-admin-'||v_run||'@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now()),
    (v_employee,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','9c2d-employee-'||v_run||'@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now()),
    (v_instructor,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','9c2d-instructor-'||v_run||'@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now()),
    (v_user_a,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','9c2d-usera-'||v_run||'@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now()),
    (v_user_b,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','9c2d-userb-'||v_run||'@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now()),
    (v_unrelated,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','9c2d-unrelated-'||v_run||'@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now()),
    (v_global_admin,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','9c2d-global-'||v_run||'@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now()),
    (v_pending,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','9c2d-pending-'||v_run||'@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now()),
    (v_suspended,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','9c2d-suspended-'||v_run||'@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now());

  insert into public.profiles(user_id,email,role,first_name,last_name,full_name)
  values
    (v_admin,'9c2d-admin-'||v_run||'@example.invalid','admin','[TEST]','Admin',v_marker||' Admin'),
    (v_employee,'9c2d-employee-'||v_run||'@example.invalid','pracownik','[TEST]','Employee',v_marker||' Employee'),
    (v_instructor,'9c2d-instructor-'||v_run||'@example.invalid','instruktor','[TEST]','Instructor',v_marker||' Instructor'),
    (v_user_a,'9c2d-usera-'||v_run||'@example.invalid','user','[TEST]','User A',v_marker||' User A'),
    (v_user_b,'9c2d-userb-'||v_run||'@example.invalid','user','[TEST]','User B',v_marker||' User B'),
    (v_unrelated,'9c2d-unrelated-'||v_run||'@example.invalid','user','[TEST]','Unrelated',v_marker||' Unrelated'),
    (v_global_admin,'9c2d-global-'||v_run||'@example.invalid','admin','[TEST]','Global',v_marker||' Global'),
    (v_pending,'9c2d-pending-'||v_run||'@example.invalid','admin','[TEST]','Pending',v_marker||' Pending'),
    (v_suspended,'9c2d-suspended-'||v_run||'@example.invalid','admin','[TEST]','Suspended',v_marker||' Suspended');

  delete from public.tenant_memberships where tenant_id=v_csk and user_id in(v_user_b,v_global_admin);
  update public.tenant_memberships set status='pending' where tenant_id=v_csk and user_id=v_pending;
  update public.tenant_memberships set status='suspended' where tenant_id=v_csk and user_id=v_suspended;

  insert into public.tenants(id,name,slug,status)
  values(v_tenant_b,v_marker||' Tenant B','saas9c2d-'||pg_catalog.left(v_run,16),'dormant');
  insert into public.tenant_memberships(tenant_id,user_id,role,status)
  values(v_tenant_b,v_user_b,'user','active');

  insert into public.shooting_lanes(id,tenant_id,name,type,is_active,max_shooters,booking_step_minutes,display_order,resource_kind,parent_lane_id,whole_lane_bookable,positions_bookable)
  values
    (v_lane_a_public,v_csk,v_marker||' Lane A public','test',true,1,60,9920,'lane',null,true,false),
    (v_lane_a_private,v_csk,v_marker||' Lane A private','test',false,1,60,9921,'lane',null,false,false),
    (v_lane_b,v_tenant_b,v_marker||' Lane B','test',true,1,60,9922,'lane',null,true,false);

  insert into public.lane_booking_rules(lane_id,online_bookable,max_people_online)
  values(v_lane_a_public,true,1),(v_lane_a_private,false,1),(v_lane_b,true,1);
  insert into public.lane_booking_durations(lane_id,duration_minutes,display_order,is_active)
  values(v_lane_a_public,60,10,true),(v_lane_a_private,90,10,false),(v_lane_b,60,10,true);
  insert into public.lane_pricing_rules(id,lane_id,day_group,min_shooters,max_shooters,label,hourly_price,display_order,is_active)
  values
    (v_price_a_public,v_lane_a_public,'mon_thu',1,1,v_marker||' A public',10,10,true),
    (v_price_a_private,v_lane_a_private,'mon_thu',1,1,v_marker||' A private',11,10,false),
    (v_price_b,v_lane_b,'mon_thu',1,1,v_marker||' B',20,10,true);

  insert into public.reservations(id,user_id,tenant_id,lane_id,customer_name,customer_email,customer_phone,reservation_date,start_time,end_time,duration_minutes,price,reservation_status,payment_status,attendance_status,shooters_count,pricing_rule_id,pricing_day_group_snapshot,lane_name_snapshot,pricing_label_snapshot,price_per_hour_snapshot,total_price,currency_code,creation_request_id)
  values
    (v_reservation_a,v_user_a,v_csk,v_lane_a_public,v_marker||' User A','a@example.invalid','000',date '2099-11-01',time '08:00',time '09:00',60,10,'confirmed','pay_on_site','planned',1,v_price_a_public,'mon_thu','A','A',10,10,'PLN',pg_catalog.gen_random_uuid()),
    (v_reservation_b,v_user_b,v_tenant_b,v_lane_b,v_marker||' User B','b@example.invalid','000',date '2099-11-02',time '08:00',time '09:00',60,20,'confirmed','pay_on_site','planned',1,v_price_b,'mon_thu','B','B',20,20,'PLN',pg_catalog.gen_random_uuid());

  insert into public.events(id,tenant_id,title,description,event_date,start_time,end_time,location,price,max_participants,is_active)
  values
    (v_event_a,v_csk,v_marker||' Event A','A',date '2099-12-01',time '10:00',time '11:00','[TEST]',10,10,true),
    (v_event_b,v_tenant_b,v_marker||' Event B','B',date '2099-12-02',time '10:00',time '11:00','[TEST]',20,10,true);
  insert into public.event_registrations(id,tenant_id,event_id,user_id,customer_name,customer_email,customer_phone,registration_status,payment_status)
  values
    (v_registration_a,v_csk,v_event_a,v_user_a,v_marker||' User A','a@example.invalid','000','registered','pay_on_site'),
    (v_registration_b,v_tenant_b,v_event_b,v_user_b,v_marker||' User B','b@example.invalid','000','registered','pay_on_site');

  insert into public.audit_logs(id,actor_user_id,actor_name,actor_role,action,target_type,target_id,target_name,details)
  values
    (v_audit_a,v_admin,v_marker||' Admin','admin','reservation_created','reservation',v_reservation_a,'A','{}'),
    (v_audit_b,v_admin,v_marker||' Admin','admin','event_registration_approved_by_staff','event_registration',v_registration_b,'B','{}'),
    (v_audit_global,v_admin,v_marker||' Admin','admin','profile_role_changed','profile',v_user_a,'Global','{}');

  perform pg_temp.ok(1,'exact target policy inventory exists',(select pg_catalog.count(*)=9 from pg_catalog.pg_policies where schemaname='public' and tablename in('audit_logs','profiles','lane_booking_rules','lane_booking_durations','lane_pricing_rules')),'Target policy count differs.');
  perform pg_temp.ok(2,'target policies do not use global role helpers',not exists(select 1 from pg_catalog.pg_policies where schemaname='public' and tablename in('audit_logs','profiles','lane_booking_rules','lane_booking_durations','lane_pricing_rules') and (coalesce(qual,'')~'\m(is_admin|is_employee|is_admin_or_employee|is_admin_or_staff|get_my_role)\M' or coalesce(with_check,'')~'\m(is_admin|is_employee|is_admin_or_employee|is_admin_or_staff|get_my_role)\M')),'Legacy role helper remains.');
  perform pg_temp.ok(3,'target policies are SELECT-only',not exists(select 1 from pg_catalog.pg_policies where schemaname='public' and tablename in('audit_logs','profiles','lane_booking_rules','lane_booking_durations','lane_pricing_rules') and cmd<>'SELECT'),'Mutation policy exists.');
  perform pg_temp.ok(4,'RLS remains enabled on all reviewed tables',(select pg_catalog.count(*)=8 from pg_catalog.pg_class where oid in('public.audit_logs'::regclass,'public.profiles'::regclass,'public.lane_booking_rules'::regclass,'public.lane_booking_durations'::regclass,'public.lane_pricing_rules'::regclass,'public.tenants'::regclass,'public.tenant_memberships'::regclass,'public.email_deliveries'::regclass) and relrowsecurity),'RLS flag differs.');

  perform pg_temp.ok(5,'admin A sees tenant A audit',pg_temp.as_actor_text('authenticated',v_admin,pg_catalog.format('(select count(*) from public.audit_logs where id=%L)',v_audit_a))='1','Admin A audit denied.');
  perform pg_temp.ok(6,'admin A cannot see tenant B audit',pg_temp.as_actor_text('authenticated',v_admin,pg_catalog.format('(select count(*) from public.audit_logs where id=%L)',v_audit_b))='0','Admin crossed audit tenant.');
  perform pg_temp.ok(7,'admin A cannot see global audit',pg_temp.as_actor_text('authenticated',v_admin,pg_catalog.format('(select count(*) from public.audit_logs where id=%L)',v_audit_global))='0','Global audit exposed.');
  perform pg_temp.ok(8,'employee A sees tenant A audit',pg_temp.as_actor_text('authenticated',v_employee,pg_catalog.format('(select count(*) from public.audit_logs where id=%L)',v_audit_a))='1','Employee audit denied.');
  perform pg_temp.ok(9,'employee A cannot see tenant B or global audit',pg_temp.as_actor_text('authenticated',v_employee,pg_catalog.format('(select count(*) from public.audit_logs where id in(%L,%L))',v_audit_b,v_audit_global))='0','Employee audit scope leaked.');
  perform pg_temp.ok(10,'ordinary user sees no audit',pg_temp.as_actor_text('authenticated',v_user_a,pg_catalog.format('(select count(*) from public.audit_logs where id in(%L,%L,%L))',v_audit_a,v_audit_b,v_audit_global))='0','User audit access expanded.');
  perform pg_temp.ok(11,'anon audit access is denied',pg_temp.as_actor_raises('anon',null,'select count(*) from public.audit_logs','42501'),'Anon could query audit.');
  perform pg_temp.ok(12,'audit direct mutation ACL remains denied',not pg_catalog.has_table_privilege('authenticated','public.audit_logs','INSERT,UPDATE,DELETE,TRUNCATE'),'Audit mutation ACL expanded.');

  perform pg_temp.ok(13,'user A reads own profile',pg_temp.as_actor_text('authenticated',v_user_a,pg_catalog.format('(select count(*) from public.profiles where user_id=%L)',v_user_a))='1','Own profile denied.');
  perform pg_temp.ok(14,'user A cannot read unrelated profile',pg_temp.as_actor_text('authenticated',v_user_a,pg_catalog.format('(select count(*) from public.profiles where user_id=%L)',v_unrelated))='0','Foreign profile exposed.');
  perform pg_temp.ok(15,'admin A reads reservation-related profile',pg_temp.as_actor_text('authenticated',v_admin,pg_catalog.format('(select count(*) from public.profiles where user_id=%L)',v_user_a))='1','Related profile denied.');
  perform pg_temp.ok(16,'admin A cannot read unrelated global profile',pg_temp.as_actor_text('authenticated',v_admin,pg_catalog.format('(select count(*) from public.profiles where user_id=%L)',v_unrelated))='0','Unrelated profile exposed.');
  perform pg_temp.ok(17,'admin A cannot read tenant-B-only profile',pg_temp.as_actor_text('authenticated',v_admin,pg_catalog.format('(select count(*) from public.profiles where user_id=%L)',v_user_b))='0','Tenant B profile exposed.');
  perform pg_temp.ok(18,'employee direct related-profile scope remains closed',pg_temp.as_actor_text('authenticated',v_employee,pg_catalog.format('(select count(*) from public.profiles where user_id=%L)',v_user_a))='0','Employee profile scope expanded.');
  perform pg_temp.ok(19,'instructor direct related-profile scope remains closed',pg_temp.as_actor_text('authenticated',v_instructor,pg_catalog.format('(select count(*) from public.profiles where user_id=%L)',v_user_a))='0','Instructor profile scope expanded.');
  perform pg_temp.ok(20,'global admin without membership cannot read related profile',pg_temp.as_actor_text('authenticated',v_global_admin,pg_catalog.format('(select count(*) from public.profiles where user_id=%L)',v_user_a))='0','Global role bypassed membership.');
  perform pg_temp.ok(21,'pending admin cannot read related profile',pg_temp.as_actor_text('authenticated',v_pending,pg_catalog.format('(select count(*) from public.profiles where user_id=%L)',v_user_a))='0','Pending membership authorized.');
  perform pg_temp.ok(22,'suspended admin cannot read related profile',pg_temp.as_actor_text('authenticated',v_suspended,pg_catalog.format('(select count(*) from public.profiles where user_id=%L)',v_user_a))='0','Suspended membership authorized.');
  perform pg_temp.ok(23,'authenticated direct profile INSERT is denied',pg_temp.as_actor_raises('authenticated',v_admin,pg_catalog.format('insert into public.profiles(user_id,email,role) values(%L,''blocked@example.invalid'',''user'')',pg_catalog.gen_random_uuid()),'42501'),'Direct profile INSERT allowed.');
  perform pg_temp.ok(24,'profile UPDATE and DELETE remain denied',not pg_catalog.has_table_privilege('authenticated','public.profiles','UPDATE,DELETE,TRUNCATE'),'Profile mutation ACL expanded.');

  perform pg_temp.ok(25,'anon sees public CSK booking rule',pg_temp.as_actor_text('anon',null,pg_catalog.format('(select count(*) from public.lane_booking_rules where lane_id=%L)',v_lane_a_public))='1','Public rule denied.');
  perform pg_temp.ok(26,'anon sees public CSK duration',pg_temp.as_actor_text('anon',null,pg_catalog.format('(select count(*) from public.lane_booking_durations where lane_id=%L)',v_lane_a_public))='1','Public duration denied.');
  perform pg_temp.ok(27,'anon sees public CSK pricing',pg_temp.as_actor_text('anon',null,pg_catalog.format('(select count(*) from public.lane_pricing_rules where lane_id=%L)',v_lane_a_public))='1','Public pricing denied.');
  perform pg_temp.ok(28,'anon cannot see private CSK lane configuration',pg_temp.as_actor_text('anon',null,pg_catalog.format('(select (select count(*) from public.lane_booking_rules where lane_id=%L)+(select count(*) from public.lane_booking_durations where lane_id=%L)+(select count(*) from public.lane_pricing_rules where lane_id=%L))',v_lane_a_private,v_lane_a_private,v_lane_a_private))='0','Private configuration exposed.');
  perform pg_temp.ok(29,'anon cannot see dormant tenant B configuration',pg_temp.as_actor_text('anon',null,pg_catalog.format('(select (select count(*) from public.lane_booking_rules where lane_id=%L)+(select count(*) from public.lane_booking_durations where lane_id=%L)+(select count(*) from public.lane_pricing_rules where lane_id=%L))',v_lane_b,v_lane_b,v_lane_b))='0','Dormant tenant configuration exposed.');

  perform pg_temp.ok(30,'admin A sees all own-tenant rules',pg_temp.as_actor_text('authenticated',v_admin,pg_catalog.format('(select count(*) from public.lane_booking_rules where lane_id in(%L,%L))',v_lane_a_public,v_lane_a_private))='2','Admin rules scope differs.');
  perform pg_temp.ok(31,'admin A sees all own-tenant durations',pg_temp.as_actor_text('authenticated',v_admin,pg_catalog.format('(select count(*) from public.lane_booking_durations where lane_id in(%L,%L))',v_lane_a_public,v_lane_a_private))='2','Admin durations scope differs.');
  perform pg_temp.ok(32,'admin A sees all own-tenant pricing',pg_temp.as_actor_text('authenticated',v_admin,pg_catalog.format('(select count(*) from public.lane_pricing_rules where lane_id in(%L,%L))',v_lane_a_public,v_lane_a_private))='2','Admin pricing scope differs.');
  perform pg_temp.ok(33,'admin A cannot see tenant B configuration',pg_temp.as_actor_text('authenticated',v_admin,pg_catalog.format('(select (select count(*) from public.lane_booking_rules where lane_id=%L)+(select count(*) from public.lane_booking_durations where lane_id=%L)+(select count(*) from public.lane_pricing_rules where lane_id=%L))',v_lane_b,v_lane_b,v_lane_b))='0','Admin crossed configuration tenant.');
  perform pg_temp.ok(34,'employee A sees all own-tenant rules',pg_temp.as_actor_text('authenticated',v_employee,pg_catalog.format('(select count(*) from public.lane_booking_rules where lane_id in(%L,%L))',v_lane_a_public,v_lane_a_private))='2','Employee rules scope differs.');
  perform pg_temp.ok(35,'employee A sees all own-tenant durations and pricing',pg_temp.as_actor_text('authenticated',v_employee,pg_catalog.format('(select (select count(*) from public.lane_booking_durations where lane_id in(%L,%L))+(select count(*) from public.lane_pricing_rules where lane_id in(%L,%L)))',v_lane_a_public,v_lane_a_private,v_lane_a_public,v_lane_a_private))='4','Employee duration/pricing scope differs.');
  perform pg_temp.ok(36,'employee A cannot see tenant B configuration',pg_temp.as_actor_text('authenticated',v_employee,pg_catalog.format('(select (select count(*) from public.lane_booking_rules where lane_id=%L)+(select count(*) from public.lane_booking_durations where lane_id=%L)+(select count(*) from public.lane_pricing_rules where lane_id=%L))',v_lane_b,v_lane_b,v_lane_b))='0','Employee crossed configuration tenant.');
  perform pg_temp.ok(37,'instructor A retains private rule read',pg_temp.as_actor_text('authenticated',v_instructor,pg_catalog.format('(select count(*) from public.lane_booking_rules where lane_id=%L)',v_lane_a_private))='1','Instructor rule scope regressed.');
  perform pg_temp.ok(38,'instructor A gets no private duration or pricing',pg_temp.as_actor_text('authenticated',v_instructor,pg_catalog.format('(select (select count(*) from public.lane_booking_durations where lane_id=%L)+(select count(*) from public.lane_pricing_rules where lane_id=%L))',v_lane_a_private,v_lane_a_private))='0','Instructor duration/pricing scope expanded.');
  perform pg_temp.ok(39,'global admin without membership gets public configuration only',pg_temp.as_actor_text('authenticated',v_global_admin,pg_catalog.format('(select (select count(*) from public.lane_booking_rules where lane_id in(%L,%L))+(select count(*) from public.lane_booking_durations where lane_id in(%L,%L))+(select count(*) from public.lane_pricing_rules where lane_id in(%L,%L)))',v_lane_a_public,v_lane_a_private,v_lane_a_public,v_lane_a_private,v_lane_a_public,v_lane_a_private))='3','Global role granted private configuration.');
  perform pg_temp.ok(40,'pending and suspended admins get no private configuration',pg_temp.as_actor_text('authenticated',v_pending,pg_catalog.format('(select count(*) from public.lane_booking_rules where lane_id=%L)',v_lane_a_private))='0' and pg_temp.as_actor_text('authenticated',v_suspended,pg_catalog.format('(select count(*) from public.lane_booking_rules where lane_id=%L)',v_lane_a_private))='0','Inactive membership authorized.');
  perform pg_temp.ok(41,'ordinary user gets public configuration only',pg_temp.as_actor_text('authenticated',v_user_a,pg_catalog.format('(select (select count(*) from public.lane_booking_rules where lane_id in(%L,%L))+(select count(*) from public.lane_booking_durations where lane_id in(%L,%L))+(select count(*) from public.lane_pricing_rules where lane_id in(%L,%L)))',v_lane_a_public,v_lane_a_private,v_lane_a_public,v_lane_a_private,v_lane_a_public,v_lane_a_private))='3','User received private configuration.');
  perform pg_temp.ok(42,'lane configuration direct DML remains denied',not pg_catalog.has_table_privilege('authenticated','public.lane_booking_rules','INSERT,UPDATE,DELETE') and not pg_catalog.has_table_privilege('authenticated','public.lane_booking_durations','INSERT,UPDATE,DELETE') and not pg_catalog.has_table_privilege('authenticated','public.lane_pricing_rules','INSERT,UPDATE,DELETE'),'Lane configuration DML ACL expanded.');

  perform pg_temp.ok(43,'tenants remains policy-free',(select pg_catalog.count(*)=0 from pg_catalog.pg_policies where schemaname='public' and tablename='tenants'),'Tenant policy added.');
  perform pg_temp.ok(44,'tenants has no client ACL',not pg_catalog.has_table_privilege('public','public.tenants','SELECT,INSERT,UPDATE,DELETE') and not pg_catalog.has_table_privilege('anon','public.tenants','SELECT,INSERT,UPDATE,DELETE') and not pg_catalog.has_table_privilege('authenticated','public.tenants','SELECT,INSERT,UPDATE,DELETE'),'Tenant ACL opened.');
  perform pg_temp.ok(45,'single-active-tenant guard remains',pg_catalog.to_regclass('public.tenants_single_active_runtime_guard') is not null,'Active tenant guard missing.');
  perform pg_temp.ok(46,'membership self-read remains',pg_temp.as_actor_text('authenticated',v_user_a,pg_catalog.format('(select count(*) from public.tenant_memberships where user_id=%L)',v_user_a))='1','Self membership read failed.');
  perform pg_temp.ok(47,'foreign membership remains hidden',pg_temp.as_actor_text('authenticated',v_user_a,pg_catalog.format('(select count(*) from public.tenant_memberships where user_id=%L)',v_admin))='0','Foreign membership exposed.');
  perform pg_temp.ok(48,'membership direct mutation remains denied',not pg_catalog.has_table_privilege('authenticated','public.tenant_memberships','INSERT,UPDATE,DELETE,TRUNCATE'),'Membership DML ACL expanded.');
  perform pg_temp.ok(49,'email deliveries remains policy-free server-only',(select pg_catalog.count(*)=0 from pg_catalog.pg_policies where schemaname='public' and tablename='email_deliveries') and not pg_catalog.has_table_privilege('public','public.email_deliveries','SELECT') and not pg_catalog.has_table_privilege('anon','public.email_deliveries','SELECT') and not pg_catalog.has_table_privilege('authenticated','public.email_deliveries','SELECT'),'Email delivery exposure expanded.');

  perform pg_temp.ok(50,'profile relation indexes exist',exists(select 1 from pg_catalog.pg_indexes where schemaname='public' and indexname='reservations_user_creation_request_key') and exists(select 1 from pg_catalog.pg_indexes where schemaname='public' and indexname='event_registrations_user_created_id_idx'),'Profile relation index missing.');
  perform pg_temp.ok(51,'lane relation indexes exist',exists(select 1 from pg_catalog.pg_indexes where schemaname='public' and indexname='lane_booking_rules_pkey') and exists(select 1 from pg_catalog.pg_indexes where schemaname='public' and indexname='lane_booking_durations_lane_duration_key') and exists(select 1 from pg_catalog.pg_indexes where schemaname='public' and indexname='lane_pricing_rules_lane_id_idx'),'Lane relation index missing.');
  perform pg_temp.ok(52,'repeated profile policy evaluation has no recursion',pg_temp.as_actor_text('authenticated',v_admin,pg_catalog.format('(select count(*) from public.profiles cross join generate_series(1,20) where user_id=%L)',v_user_a))='20','Profile policy recursed.');
  perform pg_temp.ok(53,'repeated lane policy evaluation has no recursion',pg_temp.as_actor_text('authenticated',v_admin,pg_catalog.format('(select count(*) from public.lane_booking_rules cross join generate_series(1,20) where lane_id in(%L,%L))',v_lane_a_public,v_lane_a_private))='40','Lane policy recursed.');

  if not exists (
    select 1 from pg_catalog.pg_trigger trigger_record
    where not trigger_record.tgisinternal
      and trigger_record.tgrelid='auth.users'::regclass
      and trigger_record.tgfoid='public.handle_new_user()'::regprocedure
  ) then
    execute 'create trigger saas9c2d_test_on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user()';
    v_created_test_trigger := true;
  end if;

  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values(v_registered,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','9c2d-register-'||v_run||'@example.invalid','',pg_catalog.now(),'{}',pg_catalog.jsonb_build_object('first_name','[TEST]','last_name','Registered','full_name',v_marker||' Registered','phone','000'),pg_catalog.now(),pg_catalog.now());

  perform pg_temp.ok(54,'registration trigger creates exactly one profile',(select pg_catalog.count(*)=1 from public.profiles where user_id=v_registered),'Registered profile missing or duplicated.');
  perform pg_temp.ok(55,'registration creates active CSK membership',(select pg_catalog.count(*)=1 from public.tenant_memberships where tenant_id=v_csk and user_id=v_registered and role='user' and status='active'),'Registered membership differs.');
  perform pg_temp.ok(56,'registration maps profile role correctly',exists(select 1 from public.profiles where user_id=v_registered and role='user' and first_name='[TEST]' and last_name='Registered'),'Registered role or metadata differs.');

  if v_created_test_trigger then
    execute 'drop trigger saas9c2d_test_on_auth_user_created on auth.users';
  end if;

  perform pg_temp.ok(57,'registration helper remains hardened',exists(select 1 from pg_catalog.pg_proc procedure where procedure.oid='public.handle_new_user()'::regprocedure and procedure.prosecdef and pg_catalog.pg_get_userbyid(procedure.proowner)='postgres' and procedure.proconfig @> array['search_path=public, pg_temp']) and not pg_catalog.has_function_privilege('authenticated','public.handle_new_user()','EXECUTE'),'Registration helper hardening differs.');
  perform pg_temp.ok(58,'registration account can read own profile',pg_temp.as_actor_text('authenticated',v_registered,pg_catalog.format('(select count(*) from public.profiles where user_id=%L)',v_registered))='1','New account profile read failed.');

  perform pg_temp.ok(59,'critical profile RPCs remain SECURITY DEFINER',not exists(select 1 from pg_catalog.unnest(array['admin_list_users_v1','get_reservation_customer_profiles_v1','update_my_profile_v1']::text[]) expected(name) where not exists(select 1 from pg_catalog.pg_proc procedure join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace where namespace.nspname='public' and procedure.proname=expected.name and procedure.prosecdef)),'Profile definer inventory differs.');
  perform pg_temp.ok(60,'9D-1 hardens reservation profile lookup while admin user list remains deferred',exists(select 1 from pg_catalog.pg_proc where proname='get_reservation_customer_profiles_v1' and prosrc~'\mget_my_tenant_role_v1\M') and not exists(select 1 from pg_catalog.pg_proc where proname='admin_list_users_v1' and prosrc~'\m(is_tenant_member_v1|has_tenant_role_v1|get_my_tenant_role_v1)\M'),'Expected phased profile RPC boundary changed.');
  perform pg_temp.ok(61,'lane configuration definer writers remain unchanged',not exists(select 1 from pg_catalog.pg_proc procedure join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace where namespace.nspname='public' and procedure.proname in('admin_set_lane_booking_configuration','admin_set_lane_booking_family_configuration_v2','admin_create_lane_booking_family_v1') and not procedure.prosecdef),'Lane writer boundary differs.');
  perform pg_temp.ok(62,'legacy lane definers remain 9D blockers',not exists(select 1 from pg_catalog.pg_proc procedure where procedure.proname in('admin_set_lane_booking_configuration','admin_set_lane_booking_family_configuration_v2','admin_create_lane_booking_family_v1') and procedure.prosrc~'\m(is_tenant_member_v1|has_tenant_role_v1|get_my_tenant_role_v1)\M'),'Expected lane definer bypass changed.');
  perform pg_temp.ok(63,'9C-2A/B/C policies remain tenant-aware',not exists(select 1 from pg_catalog.pg_policies where schemaname='public' and tablename in('shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations') and coalesce(qual,'')~'\m(is_admin|is_employee|is_admin_or_employee|is_admin_or_staff|get_my_role)\M'),'Earlier tenant RLS regressed.');
  perform pg_temp.ok(64,'temporary defaults and second-tenant guard remain unchanged',(select pg_catalog.count(*)=7 from information_schema.columns where table_schema='public' and table_name in('shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','email_deliveries') and column_name='tenant_id' and column_default='''c5c00000-0000-4000-8000-000000000001''::uuid') and pg_catalog.to_regclass('public.tenants_single_active_runtime_guard') is not null,'Compatibility bridge or guard changed.');
end;
$tests$;

select case when passed then 'ok ' else 'not ok ' end || test_order || ' - ' || test_name || case when passed then '' else E'\n# '||result end
from test_results order by test_order;

do $assert$
begin
  if exists(select 1 from test_results where not passed) then
    raise exception 'SAAS-9C-2D remaining tenant-aware RLS failed.';
  end if;
end;
$assert$;

rollback;
