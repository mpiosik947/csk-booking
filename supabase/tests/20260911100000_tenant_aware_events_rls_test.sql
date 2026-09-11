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

create function pg_temp.as_actor_json(p_role text,p_user uuid,p_sql text)
returns jsonb language plpgsql as $function$
declare v_result jsonb;
begin
  perform pg_catalog.set_config('request.jwt.claims',pg_catalog.jsonb_build_object('sub',p_user,'role',p_role)::text,true);
  perform pg_catalog.set_config('request.jwt.claim.sub',coalesce(p_user::text,''),true);
  execute pg_catalog.format('set local role %I',p_role);
  execute p_sql into v_result;
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
  v_no_membership uuid := pg_catalog.gen_random_uuid();
  v_global_admin_no_membership uuid := pg_catalog.gen_random_uuid();
  v_pending_admin uuid := pg_catalog.gen_random_uuid();
  v_suspended_admin uuid := pg_catalog.gen_random_uuid();
  v_lane_a uuid := pg_catalog.gen_random_uuid();
  v_lane_b uuid := pg_catalog.gen_random_uuid();
  v_event_a_active uuid := pg_catalog.gen_random_uuid();
  v_event_a_inactive uuid := pg_catalog.gen_random_uuid();
  v_event_b_active uuid := pg_catalog.gen_random_uuid();
  v_reg_a_own uuid := pg_catalog.gen_random_uuid();
  v_reg_b_own uuid := pg_catalog.gen_random_uuid();
  v_reg_a_foreign uuid := pg_catalog.gen_random_uuid();
  v_reg_a_none uuid := pg_catalog.gen_random_uuid();
  v_reg_a_pending uuid := pg_catalog.gen_random_uuid();
  v_reg_a_suspended uuid := pg_catalog.gen_random_uuid();
  v_run text := pg_catalog.replace(pg_catalog.gen_random_uuid()::text,'-','');
  v_marker text;
  v_rpc jsonb;
begin
  v_marker := '[TEST][SAAS-9C-2C]['||v_run||']';

  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values
    (v_admin,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','9c2c-admin-'||v_run||'@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now()),
    (v_employee,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','9c2c-employee-'||v_run||'@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now()),
    (v_instructor,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','9c2c-instructor-'||v_run||'@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now()),
    (v_user_a,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','9c2c-usera-'||v_run||'@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now()),
    (v_user_b,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','9c2c-userb-'||v_run||'@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now()),
    (v_no_membership,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','9c2c-none-'||v_run||'@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now()),
    (v_global_admin_no_membership,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','9c2c-global-admin-'||v_run||'@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now()),
    (v_pending_admin,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','9c2c-pending-'||v_run||'@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now()),
    (v_suspended_admin,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','9c2c-suspended-'||v_run||'@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now());

  insert into public.profiles(id,user_id,email,role,verification_status)
  select auth_user.id,auth_user.id,auth_user.email,'user','pending'
  from auth.users auth_user
  left join public.profiles profile on profile.user_id=auth_user.id
  where auth_user.id in(v_admin,v_employee,v_instructor,v_user_a,v_user_b,v_no_membership,v_global_admin_no_membership,v_pending_admin,v_suspended_admin)
    and profile.user_id is null;

  update public.profiles
  set role=case user_id
    when v_admin then 'admin'
    when v_employee then 'pracownik'
    when v_instructor then 'instruktor'
    when v_global_admin_no_membership then 'admin'
    when v_pending_admin then 'admin'
    when v_suspended_admin then 'admin'
    else 'user' end,
    first_name='[TEST]',last_name='SAAS 9C-2C',full_name=v_marker,email=email
  where user_id in(v_admin,v_employee,v_instructor,v_user_a,v_user_b,v_no_membership,v_global_admin_no_membership,v_pending_admin,v_suspended_admin);

  if (select pg_catalog.count(*) from public.profiles where user_id in(v_admin,v_employee,v_instructor,v_user_a,v_user_b,v_no_membership,v_global_admin_no_membership,v_pending_admin,v_suspended_admin)) <> 9 then
    raise exception 'SAAS-9C-2C fixture failed: expected nine profiles.';
  end if;

  delete from public.tenant_memberships where tenant_id=v_csk and user_id in(v_no_membership,v_global_admin_no_membership);
  update public.tenant_memberships set status='pending' where tenant_id=v_csk and user_id=v_pending_admin;
  update public.tenant_memberships set status='suspended' where tenant_id=v_csk and user_id=v_suspended_admin;

  insert into public.tenants(id,name,slug,status)
  values(v_tenant_b,v_marker||' Tenant B','saas9c2c-'||pg_catalog.left(v_run,16),'dormant');
  insert into public.tenant_memberships(tenant_id,user_id,role,status)
  values(v_tenant_b,v_user_a,'user','active');

  insert into public.shooting_lanes(id,tenant_id,name,type,is_active,max_shooters,booking_step_minutes,display_order,resource_kind,parent_lane_id,whole_lane_bookable,positions_bookable)
  values
    (v_lane_a,v_csk,v_marker||' Lane A','test',true,1,60,9910,'lane',null,true,false),
    (v_lane_b,v_tenant_b,v_marker||' Lane B','test',true,1,60,9911,'lane',null,true,false);

  insert into public.events(id,tenant_id,title,description,event_date,start_time,end_time,location,price,max_participants,is_active)
  values
    (v_event_a_active,v_csk,v_marker||' Event A active','Public A',date '2099-10-01',time '10:00',time '11:00','[TEST]',100,20,true),
    (v_event_a_inactive,v_csk,v_marker||' Event A inactive','Internal A',date '2099-10-02',time '10:00',time '11:00','[TEST]',100,20,false),
    (v_event_b_active,v_tenant_b,v_marker||' Event B active','Dormant B',date '2099-10-03',time '10:00',time '11:00','[TEST]',100,20,true);

  insert into public.event_lanes(tenant_id,event_id,lane_id)
  values(v_csk,v_event_a_active,v_lane_a),(v_tenant_b,v_event_b_active,v_lane_b);

  insert into public.event_registrations(id,tenant_id,event_id,user_id,customer_name,customer_email,customer_phone,registration_status,payment_status)
  values
    (v_reg_a_own,v_csk,v_event_a_active,v_user_a,v_marker||' User A','usera@example.invalid','000','registered','pay_on_site'),
    (v_reg_b_own,v_tenant_b,v_event_b_active,v_user_a,v_marker||' User A B','usera@example.invalid','000','registered','pay_on_site'),
    (v_reg_a_foreign,v_csk,v_event_a_active,v_user_b,v_marker||' User B','userb@example.invalid','000','approved','paid_on_site'),
    (v_reg_a_none,v_csk,v_event_a_active,v_no_membership,v_marker||' No membership','none@example.invalid','000','registered','pay_on_site'),
    (v_reg_a_pending,v_csk,v_event_a_active,v_pending_admin,v_marker||' Pending','pending@example.invalid','000','registered','pay_on_site'),
    (v_reg_a_suspended,v_csk,v_event_a_active,v_suspended_admin,v_marker||' Suspended','suspended@example.invalid','000','registered','pay_on_site');

  perform pg_temp.ok(1,'tenant membership helpers exist',
    pg_catalog.to_regprocedure('public.is_tenant_member_v1(uuid)') is not null
    and pg_catalog.to_regprocedure('public.has_tenant_role_v1(uuid,text[])') is not null
    and pg_catalog.to_regprocedure('public.is_active_public_tenant_v1(uuid)') is not null,
    '9C-1/9C-2 foundation helper is absent.');
  perform pg_temp.ok(2,'foundation supports all tenant roles',
    (select pg_catalog.count(*)=4 from public.tenant_memberships where tenant_id=v_csk and user_id in(v_admin,v_employee,v_instructor,v_user_a) and status='active' and role in('admin','employee','instructor','user')),
    'Role mapping or active membership backfill differs.');
  perform pg_temp.ok(3,'pending and suspended memberships are not active',
    pg_temp.as_actor_text('authenticated',v_pending_admin,pg_catalog.format('public.has_tenant_role_v1(%L,array[''admin'']::text[])',v_csk))='false'
    and pg_temp.as_actor_text('authenticated',v_suspended_admin,pg_catalog.format('public.has_tenant_role_v1(%L,array[''admin'']::text[])',v_csk))='false',
    'Inactive membership authorized privileged access.');
  perform pg_temp.ok(4,'booking RLS policies remain tenant-aware',
    (select pg_catalog.count(*)=6 from pg_catalog.pg_policies where schemaname='public' and tablename in('shooting_lanes','reservations','lane_blocks'))
    and not exists(select 1 from pg_catalog.pg_policies where schemaname='public' and tablename in('shooting_lanes','reservations','lane_blocks') and coalesce(qual,'') ~ '\m(is_admin|is_admin_or_employee|is_admin_or_staff)\M'),
    '9C-2A/2B policy foundation regressed.');

  perform pg_temp.ok(5,'exactly six Events SELECT policies exist',
    (select pg_catalog.count(*)=6 from pg_catalog.pg_policies where schemaname='public' and tablename in('events','event_lanes','event_registrations') and cmd='SELECT'),
    'Events policy inventory differs.');
  perform pg_temp.ok(6,'Events policies no longer trust legacy global role helpers',
    not exists(select 1 from pg_catalog.pg_policies where schemaname='public' and tablename in('events','event_lanes','event_registrations') and coalesce(qual,'') ~ '\m(is_admin|is_admin_or_employee|is_admin_or_staff)\M'),
    'Legacy helper remains in Events RLS.');
  perform pg_temp.ok(7,'Events tables have no client mutation policies',
    not exists(select 1 from pg_catalog.pg_policies where schemaname='public' and tablename in('events','event_lanes','event_registrations') and cmd<>'SELECT'),
    'Unexpected direct mutation policy exists.');
  perform pg_temp.ok(8,'RLS remains enabled on all target tables',
    (select pg_catalog.count(*)=3 from pg_catalog.pg_class relation where relation.oid in('public.events'::regclass,'public.event_lanes'::regclass,'public.event_registrations'::regclass) and relation.relrowsecurity),
    'Target RLS flags differ.');

  perform pg_temp.ok(9,'anon sees active public CSK event',pg_temp.as_actor_text('anon',null,pg_catalog.format('(select count(*) from public.events where id=%L)',v_event_a_active))='1','Public event A was denied.');
  perform pg_temp.ok(10,'anon cannot see inactive CSK event',pg_temp.as_actor_text('anon',null,pg_catalog.format('(select count(*) from public.events where id=%L)',v_event_a_inactive))='0','Inactive event was exposed.');
  perform pg_temp.ok(11,'anon cannot see dormant tenant B event',pg_temp.as_actor_text('anon',null,pg_catalog.format('(select count(*) from public.events where id=%L)',v_event_b_active))='0','Dormant tenant event was exposed.');
  perform pg_temp.ok(12,'authenticated no-membership user retains public event access',pg_temp.as_actor_text('authenticated',v_no_membership,pg_catalog.format('(select count(*) from public.events where id=%L)',v_event_a_active))='1','Public authenticated path regressed.');
  perform pg_temp.ok(13,'authenticated no-membership user gets no inactive event',pg_temp.as_actor_text('authenticated',v_no_membership,pg_catalog.format('(select count(*) from public.events where id=%L)',v_event_a_inactive))='0','Private event leaked to ordinary user.');
  perform pg_temp.ok(14,'anon has no direct event_lanes access',not pg_catalog.has_table_privilege('anon','public.event_lanes','SELECT'),'Anon event_lanes ACL expanded.');
  perform pg_temp.ok(15,'anon has no registration access',not pg_catalog.has_table_privilege('anon','public.event_registrations','SELECT'),'Anon registration ACL expanded.');

  perform pg_temp.ok(16,'admin sees all own-tenant events',pg_temp.as_actor_text('authenticated',v_admin,pg_catalog.format('(select count(*) from public.events where id in(%L,%L))',v_event_a_active,v_event_a_inactive))='2','Admin event A scope differs.');
  perform pg_temp.ok(17,'admin cannot see tenant B event',pg_temp.as_actor_text('authenticated',v_admin,pg_catalog.format('(select count(*) from public.events where id=%L)',v_event_b_active))='0','Admin crossed event tenant boundary.');
  perform pg_temp.ok(18,'employee sees all own-tenant events',pg_temp.as_actor_text('authenticated',v_employee,pg_catalog.format('(select count(*) from public.events where id in(%L,%L))',v_event_a_active,v_event_a_inactive))='2','Employee event A scope differs.');
  perform pg_temp.ok(19,'employee cannot see tenant B event',pg_temp.as_actor_text('authenticated',v_employee,pg_catalog.format('(select count(*) from public.events where id=%L)',v_event_b_active))='0','Employee crossed event tenant boundary.');
  perform pg_temp.ok(20,'instructor retains own-tenant event read',pg_temp.as_actor_text('authenticated',v_instructor,pg_catalog.format('(select count(*) from public.events where id in(%L,%L))',v_event_a_active,v_event_a_inactive))='2','Instructor event read regressed.');
  perform pg_temp.ok(21,'instructor cannot see tenant B event',pg_temp.as_actor_text('authenticated',v_instructor,pg_catalog.format('(select count(*) from public.events where id=%L)',v_event_b_active))='0','Instructor crossed event tenant boundary.');
  perform pg_temp.ok(22,'global admin role without membership has no private event access',pg_temp.as_actor_text('authenticated',v_global_admin_no_membership,pg_catalog.format('(select count(*) from public.events where id=%L)',v_event_a_inactive))='0','Legacy global admin bypassed membership.');
  perform pg_temp.ok(23,'pending admin has no private event access',pg_temp.as_actor_text('authenticated',v_pending_admin,pg_catalog.format('(select count(*) from public.events where id=%L)',v_event_a_inactive))='0','Pending membership authorized.');
  perform pg_temp.ok(24,'suspended admin has no private event access',pg_temp.as_actor_text('authenticated',v_suspended_admin,pg_catalog.format('(select count(*) from public.events where id=%L)',v_event_a_inactive))='0','Suspended membership authorized.');

  perform pg_temp.ok(25,'admin sees own-tenant event_lanes',pg_temp.as_actor_text('authenticated',v_admin,pg_catalog.format('(select count(*) from public.event_lanes where event_id=%L)',v_event_a_active))='1','Admin event_lanes scope differs.');
  perform pg_temp.ok(26,'admin cannot read tenant B event_lanes',pg_temp.as_actor_text('authenticated',v_admin,pg_catalog.format('(select count(*) from public.event_lanes where event_id=%L)',v_event_b_active))='0','Admin event_lanes IDOR succeeded.');
  perform pg_temp.ok(27,'employee sees own-tenant event_lanes',pg_temp.as_actor_text('authenticated',v_employee,pg_catalog.format('(select count(*) from public.event_lanes where event_id=%L)',v_event_a_active))='1','Employee event_lanes scope differs.');
  perform pg_temp.ok(28,'employee cannot read tenant B event_lanes',pg_temp.as_actor_text('authenticated',v_employee,pg_catalog.format('(select count(*) from public.event_lanes where event_id=%L)',v_event_b_active))='0','Employee crossed event_lanes boundary.');
  perform pg_temp.ok(29,'instructor retains own-tenant event_lanes read',pg_temp.as_actor_text('authenticated',v_instructor,pg_catalog.format('(select count(*) from public.event_lanes where event_id=%L)',v_event_a_active))='1','Instructor event_lanes read regressed.');
  perform pg_temp.ok(30,'instructor cannot read tenant B event_lanes',pg_temp.as_actor_text('authenticated',v_instructor,pg_catalog.format('(select count(*) from public.event_lanes where event_id=%L)',v_event_b_active))='0','Instructor crossed event_lanes boundary.');
  perform pg_temp.ok(31,'no-membership global admin cannot read event_lanes',pg_temp.as_actor_text('authenticated',v_global_admin_no_membership,pg_catalog.format('(select count(*) from public.event_lanes where event_id=%L)',v_event_a_active))='0','Global role exposed event_lanes.');
  perform pg_temp.ok(32,'pending and suspended staff cannot read event_lanes',
    pg_temp.as_actor_text('authenticated',v_pending_admin,pg_catalog.format('(select count(*) from public.event_lanes where event_id=%L)',v_event_a_active))='0'
    and pg_temp.as_actor_text('authenticated',v_suspended_admin,pg_catalog.format('(select count(*) from public.event_lanes where event_id=%L)',v_event_a_active))='0',
    'Inactive membership exposed event_lanes.');

  perform pg_temp.ok(33,'user A sees own registration A',pg_temp.as_actor_text('authenticated',v_user_a,pg_catalog.format('(select count(*) from public.event_registrations where id=%L)',v_reg_a_own))='1','Owner A registration denied.');
  perform pg_temp.ok(34,'user A sees own registration B without tenant membership requirement',pg_temp.as_actor_text('authenticated',v_user_a,pg_catalog.format('(select count(*) from public.event_registrations where id=%L)',v_reg_b_own))='1','Global customer owner contract regressed.');
  perform pg_temp.ok(35,'user A cannot see user B registration',pg_temp.as_actor_text('authenticated',v_user_a,pg_catalog.format('(select count(*) from public.event_registrations where id=%L)',v_reg_a_foreign))='0','Foreign participant registration exposed.');
  perform pg_temp.ok(36,'no-membership owner can read own registration',pg_temp.as_actor_text('authenticated',v_no_membership,pg_catalog.format('(select count(*) from public.event_registrations where id=%L)',v_reg_a_none))='1','Owner access incorrectly requires membership.');
  perform pg_temp.ok(37,'pending member retains only own registration access',pg_temp.as_actor_text('authenticated',v_pending_admin,pg_catalog.format('(select count(*) from public.event_registrations where id=%L)',v_reg_a_pending))='1' and pg_temp.as_actor_text('authenticated',v_pending_admin,pg_catalog.format('(select count(*) from public.event_registrations where id=%L)',v_reg_a_foreign))='0','Pending member gained privileged participant access.');
  perform pg_temp.ok(38,'suspended member retains only own registration access',pg_temp.as_actor_text('authenticated',v_suspended_admin,pg_catalog.format('(select count(*) from public.event_registrations where id=%L)',v_reg_a_suspended))='1' and pg_temp.as_actor_text('authenticated',v_suspended_admin,pg_catalog.format('(select count(*) from public.event_registrations where id=%L)',v_reg_a_foreign))='0','Suspended member gained privileged participant access.');
  perform pg_temp.ok(39,'admin sees all own-tenant registrations',pg_temp.as_actor_text('authenticated',v_admin,pg_catalog.format('(select count(*) from public.event_registrations where tenant_id=%L)',v_csk))='5','Admin registration scope differs.');
  perform pg_temp.ok(40,'admin cannot see tenant B registration',pg_temp.as_actor_text('authenticated',v_admin,pg_catalog.format('(select count(*) from public.event_registrations where id=%L)',v_reg_b_own))='0','Admin crossed registration tenant boundary.');
  perform pg_temp.ok(41,'employee sees all own-tenant registrations',pg_temp.as_actor_text('authenticated',v_employee,pg_catalog.format('(select count(*) from public.event_registrations where tenant_id=%L)',v_csk))='5','Employee registration scope differs.');
  perform pg_temp.ok(42,'employee cannot see tenant B registration',pg_temp.as_actor_text('authenticated',v_employee,pg_catalog.format('(select count(*) from public.event_registrations where id=%L)',v_reg_b_own))='0','Employee crossed registration tenant boundary.');
  perform pg_temp.ok(43,'instructor retains current own-tenant registration read',pg_temp.as_actor_text('authenticated',v_instructor,pg_catalog.format('(select count(*) from public.event_registrations where tenant_id=%L)',v_csk))='5','Instructor scope changed.');
  perform pg_temp.ok(44,'instructor cannot see tenant B registration',pg_temp.as_actor_text('authenticated',v_instructor,pg_catalog.format('(select count(*) from public.event_registrations where id=%L)',v_reg_b_own))='0','Instructor crossed registration tenant boundary.');
  perform pg_temp.ok(45,'global admin without membership sees no foreign registrations',pg_temp.as_actor_text('authenticated',v_global_admin_no_membership,pg_catalog.format('(select count(*) from public.event_registrations where id=%L)',v_reg_a_foreign))='0','Legacy role exposed participant PII.');

  perform pg_temp.ok(46,'authenticated has SELECT-only target ACL',
    pg_catalog.has_table_privilege('authenticated','public.events','SELECT')
    and pg_catalog.has_table_privilege('authenticated','public.event_lanes','SELECT')
    and pg_catalog.has_table_privilege('authenticated','public.event_registrations','SELECT')
    and not pg_catalog.has_table_privilege('authenticated','public.events','INSERT,UPDATE,DELETE')
    and not pg_catalog.has_table_privilege('authenticated','public.event_lanes','INSERT,UPDATE,DELETE')
    and not pg_catalog.has_table_privilege('authenticated','public.event_registrations','INSERT,UPDATE,DELETE'),
    'Target ACL expanded.');
  perform pg_temp.ok(47,'PUBLIC has no direct target DML ACL',
    not pg_catalog.has_table_privilege('public','public.events','INSERT,UPDATE,DELETE')
    and not pg_catalog.has_table_privilege('public','public.event_lanes','INSERT,UPDATE,DELETE')
    and not pg_catalog.has_table_privilege('public','public.event_registrations','INSERT,UPDATE,DELETE'),
    'PUBLIC target DML expanded.');
  perform pg_temp.ok(48,'admin event UPDATE IDOR is denied',pg_temp.as_actor_raises('authenticated',v_admin,pg_catalog.format('update public.events set title=title where id=%L',v_event_b_active),'42501'),'Direct event UPDATE was allowed.');
  perform pg_temp.ok(49,'admin event DELETE IDOR is denied',pg_temp.as_actor_raises('authenticated',v_admin,pg_catalog.format('delete from public.events where id=%L',v_event_b_active),'42501'),'Direct event DELETE was allowed.');
  perform pg_temp.ok(50,'admin event INSERT IDOR is denied',pg_temp.as_actor_raises('authenticated',v_admin,pg_catalog.format('insert into public.events(id,tenant_id,title,event_date,start_time,end_time,location,price,max_participants,is_active) values(%L,%L,''[TEST] IDOR'',date ''2099-12-01'',time ''10:00'',time ''11:00'',''[TEST]'',0,1,false)',pg_catalog.gen_random_uuid(),v_tenant_b),'42501'),'Direct event INSERT was allowed.');
  perform pg_temp.ok(51,'admin event_lanes UPDATE IDOR is denied',pg_temp.as_actor_raises('authenticated',v_admin,pg_catalog.format('update public.event_lanes set lane_id=lane_id where event_id=%L',v_event_b_active),'42501'),'Direct event_lanes UPDATE was allowed.');
  perform pg_temp.ok(52,'admin event_lanes DELETE IDOR is denied',pg_temp.as_actor_raises('authenticated',v_admin,pg_catalog.format('delete from public.event_lanes where event_id=%L',v_event_b_active),'42501'),'Direct event_lanes DELETE was allowed.');
  perform pg_temp.ok(53,'admin registration UPDATE IDOR is denied',pg_temp.as_actor_raises('authenticated',v_admin,pg_catalog.format('update public.event_registrations set customer_name=customer_name where id=%L',v_reg_b_own),'42501'),'Direct registration UPDATE was allowed.');
  perform pg_temp.ok(54,'admin registration DELETE IDOR is denied',pg_temp.as_actor_raises('authenticated',v_admin,pg_catalog.format('delete from public.event_registrations where id=%L',v_reg_b_own),'42501'),'Direct registration DELETE was allowed.');
  perform pg_temp.ok(55,'user direct registration INSERT is denied',pg_temp.as_actor_raises('authenticated',v_user_a,pg_catalog.format('insert into public.event_registrations(id,tenant_id,event_id,user_id,customer_name,customer_email,customer_phone,registration_status,payment_status) values(%L,%L,%L,%L,''[TEST]'',''x@example.invalid'',''000'',''registered'',''pay_on_site'')',pg_catalog.gen_random_uuid(),v_tenant_b,v_event_b_active,v_user_a),'42501'),'Direct registration INSERT was allowed.');

  perform pg_temp.ok(56,'repeated Events helper evaluation has no RLS recursion',pg_temp.as_actor_text('authenticated',v_admin,pg_catalog.format('(select count(*) from public.events cross join generate_series(1,20) where id in(%L,%L))',v_event_a_active,v_event_a_inactive))='40','Repeated helper evaluation failed or recursed.');
  perform pg_temp.ok(57,'Events tenant indexes remain present',
    (select pg_catalog.count(*)=3 from pg_catalog.pg_indexes where schemaname='public' and indexname in('events_tenant_active_schedule_idx','event_lanes_tenant_event_lane_idx','event_registrations_tenant_user_created_idx')),
    'Tenant Events indexes differ.');
  perform pg_temp.ok(58,'membership lookup indexes remain present',
    (select pg_catalog.count(*)=2 from pg_catalog.pg_indexes where schemaname='public' and indexname in('tenant_memberships_user_status_tenant_idx','tenant_memberships_tenant_role_status_user_idx')),
    'Membership indexes differ.');

  perform pg_temp.ok(59,'critical event RPCs remain SECURITY DEFINER',
    not exists(
      select 1 from pg_catalog.unnest(array[
        'get_public_event_list_v2','get_public_event_availability_v1','admin_list_events_v1',
        'admin_list_event_registrations_v1','get_my_event_registrations_v1','register_for_event',
        'cancel_event_registration','confirm_event_reserve_promotion','prepare_event_reserve_promotions',
        'complete_event_reserve_promotion','mark_event_registration_paid','admin_create_event_v2',
        'admin_update_event_v2','admin_set_event_active_v2'
      ]::text[]) expected(name)
      where not exists(select 1 from pg_catalog.pg_proc procedure join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace where namespace.nspname='public' and procedure.proname=expected.name and procedure.prosecdef)
    ),
    'Critical event definer inventory differs.');
  perform pg_temp.ok(60,'legacy event RPCs do not yet consume tenant membership helpers',
    not exists(
      select 1 from pg_catalog.pg_proc procedure join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace
      where namespace.nspname='public'
        and procedure.proname in('get_public_event_list_v2','get_public_event_availability_v1','admin_list_events_v1','admin_list_event_registrations_v1','get_my_event_registrations_v1','register_for_event','cancel_event_registration','confirm_event_reserve_promotion','prepare_event_reserve_promotions','complete_event_reserve_promotion','mark_event_registration_paid','admin_create_event_v2','admin_update_event_v2','admin_set_event_active_v2')
        and procedure.prosrc ~ '\m(is_tenant_member_v1|has_tenant_role_v1|get_my_tenant_role_v1)\M'
    ),
    'Legacy event RPC boundary unexpectedly changed.');

  v_rpc := pg_temp.as_actor_json('anon',null,pg_catalog.format('select public.get_public_event_list_v2(%L,''upcoming'',1,50)',v_marker));
  perform pg_temp.ok(61,'public event list RPC remains executable and PII-free',
    v_rpc->>'code'='ok'
    and v_rpc::text !~* 'customer|user_id|registration_id|token|admin_note|phone|email',
    'Public event RPC contract regressed or exposed participant data.');
  perform pg_temp.ok(62,'public legacy definer remains an explicit SAAS-9D blocker',
    (v_rpc#>>'{pagination,total}')::integer=2,
    'Expected unscoped public definer behavior changed; reclassify the 9D boundary.');

  v_rpc := pg_temp.as_actor_json('authenticated',v_global_admin_no_membership,pg_catalog.format('select public.admin_list_events_v1(%L,''all'',''nearest'',1,50)',v_marker));
  perform pg_temp.ok(63,'global admin legacy definer bypass remains known for SAAS-9D',
    v_rpc->>'code'='ok' and (v_rpc#>>'{pagination,total}')::integer=3,
    'Expected legacy admin definer bypass changed; re-review transition safety.');
  perform pg_temp.ok(64,'temporary defaults and second-tenant guard remain unchanged',
    (select pg_catalog.count(*)=3 from information_schema.columns where table_schema='public' and table_name in('events','event_lanes','event_registrations') and column_name='tenant_id' and column_default='''c5c00000-0000-4000-8000-000000000001''::uuid')
    and pg_catalog.to_regclass('public.tenants_single_active_runtime_guard') is not null,
    'Compatibility defaults or active-tenant guard changed.');
end;
$tests$;

select case when passed then 'ok ' else 'not ok ' end || test_order || ' - ' || test_name || case when passed then '' else E'\n# '||result end
from test_results order by test_order;

do $assert$
begin
  if exists(select 1 from test_results where not passed) then
    raise exception 'SAAS-9C-2C tenant-aware Events RLS failed.';
  end if;
end;
$assert$;

rollback;
