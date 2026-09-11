\set ON_ERROR_STOP on
\pset format unaligned

select '1..51';

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

create function pg_temp.raises(p_sql text,p_state text)
returns boolean language plpgsql as $function$
begin
  execute p_sql;
  return false;
exception when others then
  return sqlstate=p_state;
end;
$function$;

do $tests$
declare
  v_csk constant uuid := 'c5c00000-0000-4000-8000-000000000001'::uuid;
  v_other uuid := pg_catalog.gen_random_uuid();
  v_user uuid := pg_catalog.gen_random_uuid();
  v_lane_a uuid := pg_catalog.gen_random_uuid();
  v_child_a uuid := pg_catalog.gen_random_uuid();
  v_lane_b uuid := pg_catalog.gen_random_uuid();
  v_price_a uuid := pg_catalog.gen_random_uuid();
  v_price_b uuid := pg_catalog.gen_random_uuid();
  v_reservation uuid := pg_catalog.gen_random_uuid();
  v_block uuid := pg_catalog.gen_random_uuid();
  v_event_a uuid := pg_catalog.gen_random_uuid();
  v_event_b uuid := pg_catalog.gen_random_uuid();
  v_registration uuid := pg_catalog.gen_random_uuid();
  v_registration_null uuid := pg_catalog.gen_random_uuid();
  v_delivery_reservation uuid := pg_catalog.gen_random_uuid();
  v_delivery_event uuid := pg_catalog.gen_random_uuid();
  v_audit_tenant uuid := pg_catalog.gen_random_uuid();
  v_audit_global uuid := pg_catalog.gen_random_uuid();
begin
  insert into public.tenants(id,name,slug,status)
  values(v_other,'[TEST][SAAS-9B-3] Other','saas9b3-'||replace(v_other::text,'-',''),'dormant');

  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values(v_user,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','saas9b3-'||v_user||'@example.invalid','',now(),'{}','{}',now(),now());
  insert into public.profiles(user_id,role,full_name,email)
  values(v_user,'user','[TEST][SAAS-9B-3] User','saas9b3-'||v_user||'@example.invalid');

  insert into public.shooting_lanes(id,tenant_id,name,type,is_active,max_shooters,booking_step_minutes,display_order,resource_kind,parent_lane_id,whole_lane_bookable,positions_bookable)
  values
    (v_lane_a,v_csk,'[TEST][SAAS-9B-3] CSK lane','test',false,1,60,9900,'lane',null,false,false),
    (v_child_a,v_csk,'[TEST][SAAS-9B-3] CSK child','test',false,1,60,9901,'position',v_lane_a,false,false),
    (v_lane_b,v_other,'[TEST][SAAS-9B-3] Other lane','test',false,1,60,9902,'lane',null,false,false);

  perform pg_temp.ok(1,'same-tenant lane parent is allowed',exists(select 1 from public.shooting_lanes where id=v_child_a and parent_lane_id=v_lane_a),'Valid hierarchy insert failed.');
  perform pg_temp.ok(2,'cross-tenant lane parent is denied',pg_temp.raises(pg_catalog.format('insert into public.shooting_lanes(id,tenant_id,name,type,is_active,max_shooters,booking_step_minutes,display_order,resource_kind,parent_lane_id,whole_lane_bookable,positions_bookable) values(%L,%L,%L,%L,false,1,60,9903,%L,%L,false,false)',pg_catalog.gen_random_uuid(),v_other,'[TEST][SAAS-9B-3] Bad child','test','position',v_lane_a),'23503'),'Cross-tenant hierarchy was accepted.');
  perform pg_temp.ok(3,'NULL lane parent remains allowed',pg_temp.raises(pg_catalog.format('insert into public.shooting_lanes(id,tenant_id,name,type,is_active,max_shooters,booking_step_minutes,display_order,resource_kind,parent_lane_id,whole_lane_bookable,positions_bookable) values(%L,%L,%L,%L,false,1,60,9904,%L,null,false,false)',pg_catalog.gen_random_uuid(),v_other,'[TEST][SAAS-9B-3] Null parent','test','lane'),'00000')=false,'NULL parent semantics regressed.');

  insert into public.lane_pricing_rules(id,lane_id,day_group,min_shooters,max_shooters,label,hourly_price)
  values(v_price_a,v_lane_a,'mon_thu',1,1,'[TEST][SAAS-9B-3] A',10),
        (v_price_b,v_lane_b,'mon_thu',1,1,'[TEST][SAAS-9B-3] B',20);

  insert into public.reservations(id,user_id,tenant_id,lane_id,customer_name,customer_email,customer_phone,reservation_date,start_time,end_time,duration_minutes,price,reservation_status,payment_status,attendance_status,shooters_count,pricing_rule_id,pricing_day_group_snapshot,lane_name_snapshot,pricing_label_snapshot,price_per_hour_snapshot,total_price,currency_code,creation_request_id)
  values(v_reservation,v_user,v_csk,v_lane_a,'[TEST]','saas9b3@example.invalid','000',date '2099-09-10',time '08:00',time '09:00',60,10,'confirmed','pay_on_site','planned',1,v_price_a,'mon_thu','[TEST]','[TEST]',10,10,'PLN',pg_catalog.gen_random_uuid());
  perform pg_temp.ok(4,'same-tenant reservation lane is allowed',exists(select 1 from public.reservations where id=v_reservation),'Valid reservation insert failed.');
  perform pg_temp.ok(5,'cross-tenant reservation lane is denied',pg_temp.raises(pg_catalog.format('insert into public.reservations(id,tenant_id,lane_id,customer_name,customer_email,customer_phone,reservation_date,start_time,end_time,duration_minutes,price,reservation_status,payment_status,attendance_status,shooters_count,pricing_rule_id,pricing_day_group_snapshot,lane_name_snapshot,pricing_label_snapshot,price_per_hour_snapshot,total_price,currency_code,creation_request_id) values(%L,%L,%L,%L,%L,%L,date ''2099-09-11'',time ''08:00'',time ''09:00'',60,20,%L,%L,%L,1,%L,%L,%L,%L,20,20,%L,%L)',pg_catalog.gen_random_uuid(),v_csk,v_lane_b,'[TEST]','bad@example.invalid','000','confirmed','pay_on_site','planned',v_price_b,'mon_thu','[TEST]','[TEST]','PLN',pg_catalog.gen_random_uuid()),'23503'),'Cross-tenant reservation was accepted.');
  perform pg_temp.ok(6,'matching reservation pricing lane is allowed',(select pricing_rule_id=v_price_a from public.reservations where id=v_reservation),'Matching pricing relation failed.');
  perform pg_temp.ok(7,'pricing rule from another lane is denied',pg_temp.raises(pg_catalog.format('insert into public.reservations(id,tenant_id,lane_id,customer_name,customer_email,customer_phone,reservation_date,start_time,end_time,duration_minutes,price,reservation_status,payment_status,attendance_status,shooters_count,pricing_rule_id,pricing_day_group_snapshot,lane_name_snapshot,pricing_label_snapshot,price_per_hour_snapshot,total_price,currency_code,creation_request_id) values(%L,%L,%L,%L,%L,%L,date ''2099-09-12'',time ''08:00'',time ''09:00'',60,10,%L,%L,%L,1,%L,%L,%L,%L,10,10,%L,%L)',pg_catalog.gen_random_uuid(),v_csk,v_lane_a,'[TEST]','bad-price@example.invalid','000','confirmed','pay_on_site','planned',v_price_b,'mon_thu','[TEST]','[TEST]','PLN',pg_catalog.gen_random_uuid()),'23503'),'Cross-lane pricing rule was accepted.');
  perform pg_temp.ok(8,'reservation exclusion constraint remains present',exists(select 1 from pg_catalog.pg_constraint where conrelid='public.reservations'::regclass and conname='reservations_no_overlapping_active_booking' and contype='x'),'Reservation concurrency guard is missing.');

  insert into public.lane_blocks(id,tenant_id,lane_id,block_date,start_time,end_time,reason,is_active)
  values(v_block,v_csk,v_lane_a,date '2099-09-13',time '10:00',time '11:00','[TEST][SAAS-9B-3]',false);
  perform pg_temp.ok(9,'same-tenant lane block is allowed',exists(select 1 from public.lane_blocks where id=v_block),'Valid lane block insert failed.');
  perform pg_temp.ok(10,'cross-tenant lane block is denied',pg_temp.raises(pg_catalog.format('insert into public.lane_blocks(id,tenant_id,lane_id,block_date,start_time,end_time,reason,is_active) values(%L,%L,%L,date ''2099-09-14'',time ''10:00'',time ''11:00'',%L,false)',pg_catalog.gen_random_uuid(),v_csk,v_lane_b,'[TEST][SAAS-9B-3]'),'23503'),'Cross-tenant lane block was accepted.');

  insert into public.events(id,tenant_id,title,event_date,start_time,end_time,location,price,max_participants,is_active)
  values(v_event_a,v_csk,'[TEST][SAAS-9B-3] Event A',date '2099-09-15',time '10:00',time '11:00','[TEST]',0,10,false),
        (v_event_b,v_other,'[TEST][SAAS-9B-3] Event B',date '2099-09-16',time '10:00',time '11:00','[TEST]',0,10,false);
  perform pg_temp.ok(11,'event without lane remains allowed',not exists(select 1 from public.event_lanes where event_id=v_event_a),'Event unexpectedly requires a lane.');
  insert into public.event_lanes(tenant_id,event_id,lane_id) values(v_csk,v_event_a,v_lane_a);
  perform pg_temp.ok(12,'same-tenant event lane is allowed',exists(select 1 from public.event_lanes where event_id=v_event_a and lane_id=v_lane_a),'Valid event lane failed.');
  perform pg_temp.ok(13,'event-lane event tenant mismatch is denied',pg_temp.raises(pg_catalog.format('insert into public.event_lanes(tenant_id,event_id,lane_id) values(%L,%L,%L)',v_other,v_event_a,v_lane_b),'23503'),'Mismatched event relation was accepted.');
  perform pg_temp.ok(14,'event-lane lane tenant mismatch is denied',pg_temp.raises(pg_catalog.format('insert into public.event_lanes(tenant_id,event_id,lane_id) values(%L,%L,%L)',v_csk,v_event_a,v_lane_b),'23503'),'Mismatched lane relation was accepted.');

  insert into public.event_registrations(id,tenant_id,event_id,user_id,customer_name,customer_email,customer_phone,registration_status,payment_status)
  values(v_registration,v_csk,v_event_a,v_user,'[TEST]','saas9b3@example.invalid','000','registered','pay_on_site');
  perform pg_temp.ok(15,'same-tenant event registration is allowed',exists(select 1 from public.event_registrations where id=v_registration),'Valid event registration failed.');
  perform pg_temp.ok(16,'cross-tenant event registration is denied',pg_temp.raises(pg_catalog.format('insert into public.event_registrations(id,tenant_id,event_id,customer_name,customer_email,customer_phone,registration_status,payment_status) values(%L,%L,%L,%L,%L,%L,%L,%L)',pg_catalog.gen_random_uuid(),v_other,v_event_a,'[TEST]','bad-event@example.invalid','000','registered','pay_on_site'),'23503'),'Cross-tenant event registration was accepted.');
  insert into public.event_registrations(id,tenant_id,event_id,user_id,customer_name,customer_email,customer_phone,registration_status,payment_status)
  values(v_registration_null,v_other,null,null,'[TEST]','historical@example.invalid','000','cancelled','pay_on_site');
  perform pg_temp.ok(17,'NULL event_id historical registration is allowed',exists(select 1 from public.event_registrations where id=v_registration_null and event_id is null and tenant_id=v_other),'MATCH SIMPLE NULL semantics regressed.');

  insert into public.email_deliveries(id,message_type,record_id,recipient_user_id)
  values(v_delivery_reservation,'reservation_confirmation',v_reservation,v_user);
  perform pg_temp.ok(18,'reservation delivery derives tenant',(select tenant_id=v_csk from public.email_deliveries where id=v_delivery_reservation),'Reservation delivery tenant was not derived.');
  perform pg_temp.ok(19,'matching supplied delivery tenant is allowed',not pg_temp.raises(pg_catalog.format('insert into public.email_deliveries(id,message_type,record_id,recipient_user_id,tenant_id) values(%L,%L,%L,%L,%L)',pg_catalog.gen_random_uuid(),'reservation_cancellation',v_reservation,v_user,v_csk),'23514'),'Matching delivery tenant was denied.');
  insert into public.email_deliveries(id,message_type,record_id,recipient_user_id)
  values(v_delivery_event,'event_registration_confirmation',v_registration,v_user);
  perform pg_temp.ok(20,'event registration delivery derives tenant',(select tenant_id=v_csk from public.email_deliveries where id=v_delivery_event),'Event delivery tenant was not derived.');
  perform pg_temp.ok(21,'mismatching supplied delivery tenant is denied',pg_temp.raises(pg_catalog.format('insert into public.email_deliveries(id,message_type,record_id,recipient_user_id,tenant_id) values(%L,%L,%L,%L,%L)',pg_catalog.gen_random_uuid(),'reservation_confirmation',v_reservation,v_user,v_other),'23514'),'Mismatched delivery tenant was accepted.');
  perform pg_temp.ok(22,'missing delivery target is denied',pg_temp.raises(pg_catalog.format('insert into public.email_deliveries(id,message_type,record_id,recipient_user_id) values(%L,%L,%L,%L)',pg_catalog.gen_random_uuid(),'reservation_confirmation',pg_catalog.gen_random_uuid(),v_user),'23503'),'Missing delivery target was accepted.');
  perform pg_temp.ok(23,'unknown delivery type is denied',pg_temp.raises(pg_catalog.format('insert into public.email_deliveries(id,message_type,record_id,recipient_user_id) values(%L,%L,%L,%L)',pg_catalog.gen_random_uuid(),'unknown_type',v_reservation,v_user),'23514'),'Unknown delivery type was accepted.');
  perform pg_temp.ok(24,'delivery UPDATE cannot switch to mismatched target',pg_temp.raises(pg_catalog.format('update public.email_deliveries set record_id=%L where id=%L',v_registration_null,v_delivery_reservation),'23503'),'Delivery update bypassed target derivation.');

  insert into public.audit_logs(id,action,target_type,target_id,target_name)
  values(v_audit_tenant,'reservation_created','reservation',v_reservation,'[TEST]');
  perform pg_temp.ok(25,'tenant audit derives tenant',(select tenant_id=v_csk from public.audit_logs where id=v_audit_tenant),'Audit tenant was not derived.');
  perform pg_temp.ok(26,'matching supplied audit tenant is allowed',not pg_temp.raises(pg_catalog.format('insert into public.audit_logs(id,action,target_type,target_id,tenant_id) values(%L,%L,%L,%L,%L)',pg_catalog.gen_random_uuid(),'reservation_created','reservation',v_reservation,v_csk),'23514'),'Matching audit tenant was denied.');
  perform pg_temp.ok(27,'mismatching supplied audit tenant is denied',pg_temp.raises(pg_catalog.format('insert into public.audit_logs(id,action,target_type,target_id,tenant_id) values(%L,%L,%L,%L,%L)',pg_catalog.gen_random_uuid(),'reservation_created','reservation',v_reservation,v_other),'23514'),'Mismatched audit tenant was accepted.');
  insert into public.audit_logs(id,action,target_type,target_id) values(v_audit_global,'account_anonymized','account',v_user);
  perform pg_temp.ok(28,'global account audit remains tenant NULL',(select tenant_id is null from public.audit_logs where id=v_audit_global),'Global audit received tenant ownership.');
  perform pg_temp.ok(29,'global account audit with tenant is denied',pg_temp.raises(pg_catalog.format('insert into public.audit_logs(id,action,target_type,target_id,tenant_id) values(%L,%L,%L,%L,%L)',pg_catalog.gen_random_uuid(),'account_anonymized','account',v_user,v_csk),'23514'),'Global audit accepted tenant ownership.');
  perform pg_temp.ok(30,'unknown audit target type is denied',pg_temp.raises(pg_catalog.format('insert into public.audit_logs(id,action,target_type,target_id) values(%L,%L,%L,%L)',pg_catalog.gen_random_uuid(),'future_action','future_target',pg_catalog.gen_random_uuid()),'23514'),'Unknown audit target fell back to CSK.');
  perform pg_temp.ok(31,'missing tenant audit target is denied',pg_temp.raises(pg_catalog.format('insert into public.audit_logs(id,action,target_type,target_id) values(%L,%L,%L,%L)',pg_catalog.gen_random_uuid(),'reservation_created','reservation',pg_catalog.gen_random_uuid()),'23503'),'Missing tenant audit target was accepted.');
  perform pg_temp.ok(32,'audit UPDATE cannot supply mismatching tenant',pg_temp.raises(pg_catalog.format('update public.audit_logs set tenant_id=%L where id=%L',v_other,v_audit_tenant),'23514'),'Audit update bypassed tenant derivation.');
  perform pg_temp.ok(33,'audit has no business-target foreign key',not exists(select 1 from pg_catalog.pg_constraint where conrelid='public.audit_logs'::regclass and contype='f' and confrelid in ('public.reservations'::regclass,'public.event_registrations'::regclass,'public.shooting_lanes'::regclass)),'Audit history was coupled to target lifecycle.');

  perform pg_temp.ok(34,'lane composite unique key exists',exists(select 1 from pg_catalog.pg_constraint where conrelid='public.shooting_lanes'::regclass and conname='shooting_lanes_tenant_id_id_key' and contype='u' and convalidated),'Lane key missing.');
  perform pg_temp.ok(35,'event composite unique key exists',exists(select 1 from pg_catalog.pg_constraint where conrelid='public.events'::regclass and conname='events_tenant_id_id_key' and contype='u' and convalidated),'Event key missing.');
  perform pg_temp.ok(36,'pricing composite unique key exists',exists(select 1 from pg_catalog.pg_constraint where conrelid='public.lane_pricing_rules'::regclass and conname='lane_pricing_rules_lane_id_id_key' and contype='u' and convalidated),'Pricing key missing.');
  perform pg_temp.ok(37,'seven replacement composite FKs are validated',(select count(*)=7 from pg_catalog.pg_constraint where conname in ('shooting_lanes_parent_lane_id_fkey','reservations_lane_id_fkey','reservations_pricing_rule_id_fkey','lane_blocks_lane_id_fkey','event_lanes_event_id_fkey','event_lanes_lane_id_fkey','event_registrations_event_id_fkey') and contype='f' and convalidated),'Composite FK inventory differs.');
  perform pg_temp.ok(38,'simple relationship FKs were removed',not exists(select 1 from pg_catalog.pg_constraint c where c.conname in ('shooting_lanes_parent_lane_id_fkey','reservations_lane_id_fkey','reservations_pricing_rule_id_fkey','lane_blocks_lane_id_fkey','event_lanes_event_id_fkey','event_lanes_lane_id_fkey','event_registrations_event_id_fkey') and pg_catalog.array_length(c.conkey,1)=1),'Simple FK ambiguity remains.');
  perform pg_temp.ok(39,'exactly seven tenant query indexes exist',(select count(*)=7 from pg_catalog.pg_indexes where schemaname='public' and indexname in ('shooting_lanes_tenant_hierarchy_order_idx','reservations_tenant_schedule_idx','lane_blocks_tenant_schedule_idx','events_tenant_active_schedule_idx','event_lanes_tenant_event_lane_idx','event_registrations_tenant_user_created_idx','audit_logs_tenant_created_idx')),'Tenant index inventory differs.');
  perform pg_temp.ok(40,'audit tenant index is partial',position('WHERE (tenant_id IS NOT NULL)' in (select indexdef from pg_catalog.pg_indexes where schemaname='public' and indexname='audit_logs_tenant_created_idx'))>0,'Audit index predicate differs.');
  perform pg_temp.ok(41,'no tenant email delivery index was added',not exists(select 1 from pg_catalog.pg_indexes where schemaname='public' and tablename='email_deliveries' and indexdef like '%(tenant_id%'),'Out-of-scope email index exists.');

  perform pg_temp.ok(42,'active tenant guard still denies second active tenant',pg_temp.raises(pg_catalog.format('insert into public.tenants(name,slug,status) values(%L,%L,%L)','[TEST][SAAS-9B-3] Active','saas9b3-active-'||replace(pg_catalog.gen_random_uuid()::text,'-',''),'active'),'23505'),'Second active tenant was accepted.');
  perform pg_temp.ok(43,'RLS outside approved SAAS-9C cutovers is unchanged',(select pg_catalog.md5(coalesce(pg_catalog.string_agg(pg_catalog.concat_ws('|',tablename,policyname,cmd,roles::text,qual,with_check),E'\n' order by tablename,policyname),''))='d41d8cd98f00b204e9800998ecf8427e' from pg_catalog.pg_policies where schemaname='public' and tablename not in ('tenant_memberships','shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','audit_logs','profiles','lane_booking_rules','lane_booking_durations','lane_pricing_rules')),'RLS changed outside approved 9C phases.');
  perform pg_temp.ok(44,'membership table ACL is self-read only',pg_catalog.has_table_privilege('authenticated','public.tenant_memberships','SELECT') and not pg_catalog.has_table_privilege('authenticated','public.tenant_memberships','INSERT,UPDATE,DELETE') and not pg_catalog.has_table_privilege('anon','public.tenant_memberships','SELECT,INSERT,UPDATE,DELETE') and not pg_catalog.has_table_privilege('service_role','public.tenant_memberships','SELECT,INSERT,UPDATE,DELETE'),'Membership table ACL is broader than approved.');
  perform pg_temp.ok(45,'critical RPC fingerprints are unchanged',pg_catalog.md5(pg_catalog.pg_get_functiondef('public.get_my_role()'::regprocedure))='dc8858eed7d2fd2d1ab47d22b0000b06' and pg_catalog.md5(pg_catalog.pg_get_functiondef('public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)'::regprocedure))='3f201f96dc413736d564089536b98d7d','Critical RPC changed.');
  perform pg_temp.ok(46,'trigger functions are SECURITY INVOKER and protected',(select count(*)=2 and bool_and(not function_record.prosecdef) and bool_and(function_record.proconfig @> array['search_path=pg_catalog']) and bool_and(not has_function_privilege('public',function_record.oid,'EXECUTE')) and bool_and(not has_function_privilege('anon',function_record.oid,'EXECUTE')) and bool_and(not has_function_privilege('authenticated',function_record.oid,'EXECUTE')) and bool_and(not has_function_privilege('service_role',function_record.oid,'EXECUTE')) from pg_catalog.pg_proc function_record join pg_catalog.pg_namespace namespace on namespace.oid=function_record.pronamespace where namespace.nspname='public' and function_record.proname in ('set_email_delivery_tenant_id','set_audit_log_tenant_id')),'Trigger security model differs.');
  perform pg_temp.ok(47,'profiles.role remains legacy authorization source',exists(select 1 from information_schema.columns where table_schema='public' and table_name='profiles' and column_name='role') and position('profiles' in pg_catalog.pg_get_functiondef('public.get_my_role()'::regprocedure))>0,'Legacy role source changed.');
  perform pg_temp.ok(48,'membership foundation and approved SAAS-9C RLS cutovers are active',not exists(select 1 from public.profiles profile left join public.tenant_memberships membership on membership.tenant_id='c5c00000-0000-4000-8000-000000000001'::uuid and membership.user_id=profile.user_id where membership.user_id is null or membership.role is distinct from public.legacy_profile_role_to_tenant_role_v1(profile.role)) and pg_catalog.to_regprocedure('public.has_tenant_role_v1(uuid,text[])') is not null and not exists(select 1 from pg_catalog.pg_policies where schemaname='public' and tablename not in ('tenant_memberships','shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','audit_logs','profiles','lane_booking_rules','lane_booking_durations','lane_pricing_rules') and (coalesce(qual,'')||coalesce(with_check,'')) ~ '(is_tenant_member_v1|has_tenant_role_v1|is_active_public_tenant_v1)'),'Membership foundation or approved RLS phase isolation differs.');
  perform pg_temp.ok(49,'seven temporary CSK defaults remain',(select count(*)=7 from information_schema.columns where table_schema='public' and column_name='tenant_id' and table_name in ('shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','email_deliveries') and column_default='''c5c00000-0000-4000-8000-000000000001''::uuid'),'Temporary compatibility defaults changed.');
  perform pg_temp.ok(50,'remaining tenant-aware RLS phase is active',(select count(*)=9 from pg_catalog.pg_policies where schemaname='public' and tablename in ('audit_logs','profiles','lane_booking_rules','lane_booking_durations','lane_pricing_rules') and cmd='SELECT') and not pg_catalog.has_table_privilege('authenticated','public.profiles','INSERT'),'SAAS-9C-2D policy or profile ACL hardening differs.');
end;
$tests$;

select (case when passed then 'ok ' else 'not ok ' end)||test_order||' - '||test_name||case when passed then '' else E'\n# '||result end
from pg_temp.test_results order by test_order;

do $assert$
declare v_failed text;
begin
  if (select count(*) from pg_temp.test_results)<>50 then raise exception 'SAAS-9B-3 expected 50 transactional checks.'; end if;
  select pg_catalog.string_agg(test_order||'. '||test_name||': '||result,E'\n' order by test_order) into v_failed from pg_temp.test_results where not passed;
  if v_failed is not null then raise exception E'SAAS-9B-3 failures:\n%',v_failed; end if;
end;
$assert$;

rollback;

do $cleanup$
begin
  if exists(select 1 from public.tenants where name like '[TEST][SAAS-9B-3]%')
     or exists(select 1 from auth.users where email like 'saas9b3-%@example.invalid')
     or exists(select 1 from public.profiles where email like 'saas9b3-%@example.invalid')
     or exists(select 1 from public.shooting_lanes where name like '[TEST][SAAS-9B-3]%')
     or exists(select 1 from public.events where title like '[TEST][SAAS-9B-3]%')
     or exists(select 1 from public.reservations where customer_email like 'saas9b3%@example.invalid')
     or exists(select 1 from public.event_registrations where customer_email like 'saas9b3%@example.invalid') then
    raise exception 'SAAS-9B-3 rollback cleanup failed.';
  end if;
end;
$cleanup$;

select 'ok 51 - rollback leaves zero SAAS-9B-3 fixture';
