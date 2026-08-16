\set ON_ERROR_STOP on

-- Psql-only 6C-2F-A contract test. Migration and [TEST] fixtures are rolled back.
begin;
set local role postgres;
\ir ../migrations/20260813195210_harden_admin_user_management.sql

create temporary table test_results (
  test_order integer primary key,
  test_name text not null,
  passed boolean not null,
  result text not null
) on commit drop;

create function pg_temp.set_actor(p_user_id uuid)
returns void language plpgsql as $function$
begin
  perform pg_catalog.set_config(
    'request.jwt.claims',
    case when p_user_id is null then '{}'
      else pg_catalog.jsonb_build_object('sub', p_user_id, 'role', 'authenticated')::text
    end,
    true
  );
end;
$function$;

create function pg_temp.profile_count(p_user_id uuid, p_ids uuid[])
returns bigint language plpgsql as $function$
declare v_count bigint;
begin
  perform pg_temp.set_actor(p_user_id);
  execute 'set local role authenticated';
  select pg_catalog.count(*) into v_count
  from public.profiles where user_id = any(p_ids);
  execute 'set local role postgres';
  return v_count;
exception when others then execute 'set local role postgres'; raise;
end;
$function$;

create function pg_temp.call_list(p_user_id uuid)
returns bigint language plpgsql as $function$
declare v_count bigint;
begin
  perform pg_temp.set_actor(p_user_id);
  execute 'set local role authenticated';
  select pg_catalog.count(*) into v_count
  from public.admin_list_users_v1(100,0,null,null,null,'newest');
  execute 'set local role postgres';
  return v_count;
exception when others then execute 'set local role postgres'; return -1;
end;
$function$;

create function pg_temp.call_operational(p_user_id uuid, p_reservation_ids uuid[])
returns bigint language plpgsql as $function$
declare v_count bigint;
begin
  perform pg_temp.set_actor(p_user_id);
  execute 'set local role authenticated';
  select pg_catalog.count(*) into v_count
  from public.get_reservation_customer_profiles_v1(p_reservation_ids);
  execute 'set local role postgres';
  return v_count;
exception when others then execute 'set local role postgres'; return -1;
end;
$function$;

create function pg_temp.call_role(p_user_id uuid, p_target uuid, p_role text)
returns jsonb language plpgsql as $function$
declare v_result jsonb;
begin
  perform pg_temp.set_actor(p_user_id);
  execute 'set local role authenticated';
  select public.admin_set_user_role_v1(p_target,p_role) into v_result;
  execute 'set local role postgres';
  return v_result;
exception when others then execute 'set local role postgres'; raise;
end;
$function$;

create function pg_temp.call_note(p_user_id uuid, p_target uuid, p_note text)
returns jsonb language plpgsql as $function$
declare v_result jsonb;
begin
  perform pg_temp.set_actor(p_user_id);
  execute 'set local role authenticated';
  select public.admin_set_user_note_v1(p_target,p_note) into v_result;
  execute 'set local role postgres';
  return v_result;
exception when others then execute 'set local role postgres'; raise;
end;
$function$;

create function pg_temp.fail_profile_admin_audit()
returns trigger language plpgsql as $function$
begin
  if new.action in ('profile_role_changed', 'profile_admin_note_updated') then
    raise exception 'forced audit failure' using errcode = 'P0001';
  end if;
  return new;
end;
$function$;

do $tests$
declare
  v_admin_a uuid := pg_catalog.gen_random_uuid();
  v_admin_b uuid := pg_catalog.gen_random_uuid();
  v_employee uuid := pg_catalog.gen_random_uuid();
  v_instructor uuid := pg_catalog.gen_random_uuid();
  v_user uuid := pg_catalog.gen_random_uuid();
  v_other uuid := pg_catalog.gen_random_uuid();
  v_ids uuid[];
  v_reservation_id uuid := pg_catalog.gen_random_uuid();
  v_result jsonb;
  v_before jsonb;
  v_after jsonb;
  v_audit_before bigint;
  v_audit_after bigint;
begin
  insert into auth.users (
    id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,
    raw_app_meta_data,raw_user_meta_data,created_at,updated_at
  ) values
    (v_admin_a,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','test-6c2fa-admin-a@example.invalid','',now(),'{}','{}',now(),now()),
    (v_admin_b,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','test-6c2fa-admin-b@example.invalid','',now(),'{}','{}',now(),now()),
    (v_employee,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','test-6c2fa-employee@example.invalid','',now(),'{}','{}',now(),now()),
    (v_instructor,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','test-6c2fa-instructor@example.invalid','',now(),'{}','{}',now(),now()),
    (v_user,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','test-6c2fa-user@example.invalid','',now(),'{}','{}',now(),now()),
    (v_other,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','test-6c2fa-other@example.invalid','',now(),'{}','{}',now(),now());

  update public.profiles set
    role = case user_id when v_admin_a then 'admin' when v_admin_b then 'admin'
      when v_employee then 'pracownik' when v_instructor then 'instruktor' else 'user' end,
    first_name='[TEST]',last_name='6C-2F-A',full_name='[TEST][6C-2F-A]',
    email='test-6c2fa-profile@example.invalid',phone='000000000',
    postal_code='00-000',city='Test',street='Test',house_number='1'
  where user_id in (v_admin_a,v_admin_b,v_employee,v_instructor,v_user,v_other);

  v_ids := array[v_admin_a,v_admin_b,v_employee,v_instructor,v_user,v_other];

  insert into public.reservations (
    id,user_id,lane_id,customer_name,customer_email,customer_phone,
    reservation_date,start_time,end_time,duration_minutes,price,
    reservation_status,payment_status,created_at,attendance_status,admin_note,
    checked_in_at,completed_at,check_in_token,reservation_note,shooters_count,
    pricing_rule_id,pricing_day_group_snapshot,lane_name_snapshot,
    pricing_label_snapshot,price_per_hour_snapshot,total_price,currency_code,
    creation_request_id
  ) select
    v_reservation_id,v_user,baseline.lane_id,'[TEST][6C-2F-A]',
    'test-6c2fa-reservation@example.invalid','000000000',current_date+9000,
    baseline.start_time,baseline.end_time,baseline.duration_minutes,baseline.price,
    'confirmed','pay_on_site',now(),'planned',null,null,null,gen_random_uuid(),
    '[TEST][6C-2F-A]',baseline.shooters_count,baseline.pricing_rule_id,
    baseline.pricing_day_group_snapshot,baseline.lane_name_snapshot,
    baseline.pricing_label_snapshot,baseline.price_per_hour_snapshot,
    baseline.total_price,baseline.currency_code,gen_random_uuid()
  from public.reservations as baseline order by baseline.id limit 1;

  if not found then raise exception '6C-2F-A fixture needs one reservation baseline.'; end if;

  insert into pg_temp.test_results values
    (1,'Admin list: admin ALLOW',pg_temp.call_list(v_admin_a)>=6,'Admin receives a paged list.'),
    (2,'Admin list: pracownik DENY',pg_temp.call_list(v_employee)=-1,'Employee is denied.'),
    (3,'Admin list: instruktor DENY',pg_temp.call_list(v_instructor)=-1,'Instructor is denied.'),
    (4,'Admin list: user DENY',pg_temp.call_list(v_user)=-1,'User is denied.'),
    (5,'Profiles: admin global ALLOW',pg_temp.profile_count(v_admin_a,v_ids)=6,'Admin sees all fixtures.'),
    (6,'Profiles: pracownik global DENY',pg_temp.profile_count(v_employee,v_ids)=1,'Employee sees only own profile.'),
    (7,'Profiles: instruktor global DENY',pg_temp.profile_count(v_instructor,v_ids)=1,'Instructor sees only own profile.'),
    (8,'Profiles: user global DENY',pg_temp.profile_count(v_user,v_ids)=1,'User sees only own profile.'),
    (9,'Operational: employee reservation ALLOW',pg_temp.call_operational(v_employee,array[v_reservation_id])=1,'Employee reads reservation-scoped profile.'),
    (10,'Operational: instructor DENY',pg_temp.call_operational(v_instructor,array[v_reservation_id])=-1,'Instructor is denied.'),
    (11,'Operational: user DENY',pg_temp.call_operational(v_user,array[v_reservation_id])=-1,'User is denied.'),
    (12,'Operational: arbitrary profile unavailable',pg_temp.call_operational(v_employee,array[gen_random_uuid()])=0,'Unknown reservation yields no profile.');

  v_result := pg_temp.call_role(v_employee,v_user,'admin');
  insert into pg_temp.test_results values
    (13,'Role: employee escalation DENY',v_result->>'code'='not_allowed','Controlled denial.'),
    (14,'Role: instructor escalation DENY',(pg_temp.call_role(v_instructor,v_user,'admin')->>'code')='not_allowed','Controlled denial.'),
    (15,'Role: user escalation DENY',(pg_temp.call_role(v_user,v_user,'admin')->>'code')='not_allowed','Controlled denial.'),
    (16,'Role: invalid role DENY',(pg_temp.call_role(v_admin_a,v_user,'owner')->>'code')='invalid_role','Whitelist enforced.'),
    (17,'Role: forged target controlled',(pg_temp.call_role(v_admin_a,gen_random_uuid(),'user')->>'code')='target_not_found','No raw error.');

  v_audit_before := (select count(*) from public.audit_logs where target_id=v_user and action='profile_role_changed');
  v_result := pg_temp.call_role(v_admin_a,v_user,'instruktor');
  v_audit_after := (select count(*) from public.audit_logs where target_id=v_user and action='profile_role_changed');
  insert into pg_temp.test_results values
    (18,'Role: admin valid transition',v_result->>'code'='updated' and (select role from public.profiles where user_id=v_user)='instruktor','Admin transition succeeds.'),
    (19,'Role: audit exactly once',v_audit_after-v_audit_before=1,'Successful role change creates one audit.'),
    (20,'Role: no-change no audit',(pg_temp.call_role(v_admin_a,v_user,'instruktor')->>'code')='no_change' and (select count(*) from public.audit_logs where target_id=v_user and action='profile_role_changed')=v_audit_after,'Idempotent call has no audit.');

  v_result := pg_temp.call_role(v_admin_a,v_admin_a,'user');
  insert into pg_temp.test_results values
    (21,'Role: self downgrade with another admin ALLOW',v_result->>'code'='updated','Self downgrade is safe while another admin exists.');
  insert into pg_temp.test_results values
    (22,'Role: last-admin guard is present',pg_catalog.pg_get_functiondef('public.admin_set_user_role_v1(uuid,text)'::regprocedure) like '%v_admin_count <= 1%' and pg_catalog.pg_get_functiondef('public.admin_set_user_role_v1(uuid,text)'::regprocedure) like '%pg_advisory_xact_lock(6202, 1)%','Guard and global transaction lock are present.'),
    (23,'Role: minimum one admin',(select count(*) from public.profiles where role='admin')>=1,'At least one admin remains.'),
    (24,'Role: denied has zero audit',(select count(*) from public.audit_logs where target_id=v_employee and action='profile_role_changed')=0,'Denied escalation has no audit.');

  v_audit_before := (select count(*) from public.audit_logs where target_id=v_user and action='profile_admin_note_updated');
  v_result := pg_temp.call_note(v_admin_b,v_user,'[TEST][6C-2F-A] note');
  v_audit_after := (select count(*) from public.audit_logs where target_id=v_user and action='profile_admin_note_updated');
  insert into pg_temp.test_results values
    (25,'Note: admin update PASS',v_result->>'code'='updated' and (select admin_note from public.profiles where user_id=v_user)='[TEST][6C-2F-A] note','Admin note updated.'),
    (26,'Note: employee DENY',(pg_temp.call_note(v_employee,v_user,'x')->>'code')='not_allowed','Employee denied.'),
    (27,'Note: instructor DENY',(pg_temp.call_note(v_instructor,v_user,'x')->>'code')='not_allowed','Instructor denied.'),
    (28,'Note: user DENY',(pg_temp.call_note(v_other,v_user,'x')->>'code')='not_allowed','User denied.'),
    (29,'Note: audit exactly once',v_audit_after-v_audit_before=1,'Note change has one audit.'),
    (30,'Note: audit omits content',not exists(select 1 from public.audit_logs where target_id=v_user and action='profile_admin_note_updated' and details::text like '%6C-2F-A%'),'Audit stores booleans, not note content.');

  perform pg_temp.set_actor(v_user);
  execute 'set local role authenticated';
  update public.profiles set phone='111111111',city='Self' where user_id=v_user;
  execute 'set local role postgres';
  insert into pg_temp.test_results values
    (31,'Self: legitimate fields ALLOW',(select phone='111111111' and city='Self' from public.profiles where user_id=v_user),'Self contact edit preserved.');

  v_before := (select to_jsonb(profile) from public.profiles as profile where user_id=v_user);
  begin
    perform pg_temp.set_actor(v_user); execute 'set local role authenticated';
    update public.profiles set role='admin' where user_id=v_user;
    execute 'set local role postgres';
  exception when sqlstate '42501' then execute 'set local role postgres'; end;
  v_after := (select to_jsonb(profile) from public.profiles as profile where user_id=v_user);
  insert into pg_temp.test_results values
    (32,'Self: role escalation DENY',v_before=v_after,'Role and timestamps unchanged.');

  begin
    perform pg_temp.set_actor(v_user); execute 'set local role authenticated';
    update public.profiles set weapon_permit_number='SECRET',has_instructor=true where user_id=v_user;
    execute 'set local role postgres';
  exception when sqlstate '42501' then execute 'set local role postgres'; end;
  insert into pg_temp.test_results values
    (33,'Self: legacy privileged fields DENY',(select weapon_permit_number is null and not has_instructor from public.profiles where user_id=v_user),'Legacy fields unchanged.'),
    (34,'Own INSERT removed',not exists(select 1 from pg_catalog.pg_policy where polrelid='public.profiles'::regclass and polname='profile_insert_own'),'Redundant own insert is absent.'),
    (35,'Duplicate own policies removed',not exists(select 1 from pg_catalog.pg_policy where polrelid='public.profiles'::regclass and polname in ('profile_select_own','profile_update_own')),'Canonical own policies remain.'),
    (36,'RPC ACL',has_function_privilege('authenticated','public.admin_list_users_v1(integer,integer,text,text,text,text)','execute') and not has_function_privilege('anon','public.admin_list_users_v1(integer,integer,text,text,text,text)','execute') and not has_function_privilege('public','public.admin_list_users_v1(integer,integer,text,text,text,text)','execute'),'Authenticated only with internal auth.'),
    (37,'RPC security properties',(select count(*)=4 from pg_catalog.pg_proc where oid in ('public.admin_list_users_v1(integer,integer,text,text,text,text)'::regprocedure,'public.get_reservation_customer_profiles_v1(uuid[])'::regprocedure,'public.admin_set_user_role_v1(uuid,text)'::regprocedure,'public.admin_set_user_note_v1(uuid,text)'::regprocedure) and prosecdef and proowner='postgres'::regrole and proconfig=array['search_path=pg_catalog, public, pg_temp']),'All four functions hardened.'),
    (38,'Direct admin role UPDATE denied',true,'Covered below with a controlled direct-DML attempt.');

  v_before := (select to_jsonb(profile) from public.profiles as profile where user_id=v_other);
  begin
    perform pg_temp.set_actor(v_admin_b); execute 'set local role authenticated';
    update public.profiles set role='admin' where user_id=v_other;
    execute 'set local role postgres';
  exception when sqlstate '42501' then execute 'set local role postgres'; end;
  v_after := (select to_jsonb(profile) from public.profiles as profile where user_id=v_other);
  update pg_temp.test_results set passed=v_before=v_after where test_order=38;

  begin
    perform pg_temp.set_actor(v_user); execute 'set local role authenticated';
    update public.profiles set verification_status='verified',permissions_verified=true where user_id=v_user;
    execute 'set local role postgres';
  exception when sqlstate '42501' then execute 'set local role postgres'; end;
  insert into pg_temp.test_results values
    (39,'Self: verification fields DENY',(select verification_status is distinct from 'verified' and not permissions_verified from public.profiles where user_id=v_user),'Verification remains controlled.');

  execute 'create trigger csk_6c2fa_fail_audit before insert on public.audit_logs for each row execute function pg_temp.fail_profile_admin_audit()';
  v_before := (select to_jsonb(profile) from public.profiles as profile where user_id=v_other);
  begin
    v_result := pg_temp.call_role(v_admin_b,v_other,'instruktor');
  exception when sqlstate 'P0001' then null; end;
  v_after := (select to_jsonb(profile) from public.profiles as profile where user_id=v_other);
  insert into pg_temp.test_results values
    (40,'Role: audit failure rolls back mutation',v_before=v_after,'Role mutation is atomic with audit.');

  v_before := (select to_jsonb(profile) from public.profiles as profile where user_id=v_other);
  begin
    v_result := pg_temp.call_note(v_admin_b,v_other,'must rollback');
  exception when sqlstate 'P0001' then null; end;
  v_after := (select to_jsonb(profile) from public.profiles as profile where user_id=v_other);
  insert into pg_temp.test_results values
    (41,'Note: audit failure rolls back mutation',v_before=v_after,'Note mutation is atomic with audit.');
  execute 'drop trigger csk_6c2fa_fail_audit on public.audit_logs';

  insert into pg_temp.test_results values
    (42,'Admin list has bounded pagination',(select pg_catalog.pg_get_functiondef('public.admin_list_users_v1(integer,integer,text,text,text,text)'::regprocedure) like '%p_limit > 100%'),'Limit is capped at 100.'),
    (43,'Admin list has stable tie-breaker',(select pg_catalog.pg_get_functiondef('public.admin_list_users_v1(integer,integer,text,text,text,text)'::regprocedure) ~* 'profile\.user_id\s+asc'),'Stable UUID tie-breaker is present.'),
    (44,'Fixture scoped',(select count(*) from public.profiles where user_id=any(v_ids))=6 and (select count(*) from public.reservations where id=v_reservation_id)=1,'Fixture is complete.'),
    (45,'Ready for rollback',true,'All test changes are inside this transaction.');
end;
$tests$;

table pg_temp.test_results order by test_order;

do $assertions$
declare v_failures text;
begin
  select pg_catalog.string_agg(test_order::text || ': ' || test_name, ', ' order by test_order)
  into v_failures from pg_temp.test_results where passed is false;
  if v_failures is not null then raise exception '6C-2F-A tests failed: %', v_failures; end if;
  if (select count(*) from pg_temp.test_results) <> 45 then
    raise exception '6C-2F-A expected 45 tests.';
  end if;
end;
$assertions$;

rollback;
