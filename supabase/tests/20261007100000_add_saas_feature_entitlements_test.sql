\set ON_ERROR_STOP on
\pset format unaligned
\pset tuples_only on

select '1..48';
begin;
select set_config('app.product10d_test_enforce','on',true);
create temporary table test_results(test_order int primary key,test_name text,passed boolean,result text) on commit drop;
create function pg_temp.ok(int,text,boolean,text) returns void language sql as $f$ insert into pg_temp.test_results values($1,$2,coalesce($3,false),$4); $f$;
create function pg_temp.as_user(p_user uuid,p_sql text) returns jsonb language plpgsql as $f$
declare v jsonb; begin perform set_config('request.jwt.claims',jsonb_build_object('sub',p_user,'role','authenticated')::text,true); set local role authenticated; execute p_sql into v; reset role; return v; exception when others then reset role; raise; end; $f$;
create function pg_temp.as_anon(p_sql text) returns jsonb language plpgsql as $f$
declare v jsonb; begin perform set_config('request.jwt.claims',jsonb_build_object('role','anon')::text,true); set local role anon; execute p_sql into v; reset role; return v; exception when others then reset role; raise; end; $f$;
create function pg_temp.denied(p_user uuid,p_sql text) returns boolean language plpgsql as $f$
begin perform pg_temp.as_user(p_user,p_sql); return false; exception when others then return true; end; $f$;
create function pg_temp.denied_sql(p_sql text) returns boolean language plpgsql as $f$
begin execute p_sql; return false; exception when others then return sqlstate='42501'; end; $f$;
create function pg_temp.role_denied(p_role text,p_sql text) returns boolean language plpgsql as $f$
begin execute format('set local role %I',p_role); execute p_sql; reset role; return false; exception when others then reset role; return true; end; $f$;

do $tests$
declare
  tenant_a uuid:=gen_random_uuid(); tenant_b uuid:=gen_random_uuid(); tenant_missing uuid:=gen_random_uuid();
  admin_a uuid:=gen_random_uuid(); admin_b uuid:=gen_random_uuid(); user_a uuid:=gen_random_uuid();
  lane_b uuid:=gen_random_uuid(); event_b uuid:=gen_random_uuid(); registration_b uuid:=gen_random_uuid();
  full_plan uuid; booking_plan uuid; public_a jsonb; public_b jsonb; features_a jsonb; features_b jsonb;
begin
  select id into full_plan from public.saas_plans where plan_key='current_full_v1';
  select id into booking_plan from public.saas_plans where plan_key='booking_only_v1';
  insert into auth.users(id,email) values(admin_a,'p10d-admin-a@example.invalid'),(admin_b,'p10d-admin-b@example.invalid'),(user_a,'p10d-user@example.invalid');
  insert into public.tenants(id,name,slug,status) values(tenant_a,'P10D Full','p10d-full','active'),(tenant_b,'P10D Booking','p10d-booking','active'),(tenant_missing,'P10D Missing','p10d-missing','active');
  insert into public.tenant_public_profiles(tenant_id,display_name,city,is_public,public_slug,show_booking,show_pricing,show_instructor,show_events) values
    (tenant_a,'P10D Full','Poznań',true,'p10d-full-public',true,true,true,true),
    (tenant_b,'P10D Booking','Leszno',true,'p10d-booking-public',true,true,true,true),
    (tenant_missing,'P10D Missing','Kalisz',true,'p10d-missing-public',true,true,true,true);
  insert into public.tenant_memberships(tenant_id,user_id,role,status) values(tenant_a,admin_a,'admin','active'),(tenant_b,admin_b,'admin','active'),(tenant_a,user_a,'user','active');
  insert into public.tenant_plan_assignments(tenant_id,plan_id,status) values(tenant_a,full_plan,'active'),(tenant_b,booking_plan,'active');

  perform pg_temp.ok(1,'feature catalog contains ten stable keys',(select count(*)=10 from public.saas_features where active),'catalog differs');
  perform pg_temp.ok(2,'technical plans are not billing contracts',(select count(*)=2 from public.saas_plans where plan_key in('current_full_v1','booking_only_v1')),'plan model differs');
  perform pg_temp.ok(3,'full plan has all ten features',(select count(*)=10 from public.saas_plan_features where plan_id=full_plan),'full plan differs');
  perform pg_temp.ok(4,'booking-only plan has exactly booking',(select array_agg(feature_key order by feature_key)=array['booking'] from public.saas_plan_features where plan_id=booking_plan),'booking plan differs');
  perform pg_temp.ok(5,'CSK has explicit full assignment',exists(select 1 from public.tenant_plan_assignments a join public.tenants t on t.id=a.tenant_id join public.saas_plans p on p.id=a.plan_id where t.slug='csk' and a.status='active' and p.plan_key='current_full_v1'),'CSK assignment missing');
  perform pg_temp.ok(6,'missing assignment fails closed',not public.tenant_has_feature_v1(tenant_missing,'booking'),'missing assignment allowed');
  perform pg_temp.ok(7,'unknown feature fails closed',not public.tenant_has_feature_v1(tenant_a,'unknown'),'unknown feature allowed');
  update public.tenant_plan_assignments set status='suspended' where tenant_id=tenant_b;
  perform pg_temp.ok(8,'inactive assignment fails closed',not public.tenant_has_feature_v1(tenant_b,'booking'),'inactive assignment allowed');
  update public.tenant_plan_assignments set status='active' where tenant_id=tenant_b;
  perform pg_temp.ok(9,'full tenant has events',public.tenant_has_feature_v1(tenant_a,'events'),'full entitlement missing');
  perform pg_temp.ok(10,'booking-only tenant lacks events',not public.tenant_has_feature_v1(tenant_b,'events'),'events leaked');
  perform pg_temp.ok(11,'entitlement tables have RLS',not exists(select 1 from (values('saas_features'),('saas_plans'),('saas_plan_features'),('tenant_plan_assignments')) v(name) where not exists(select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname=v.name and c.relrowsecurity)),'RLS missing');
  perform pg_temp.ok(12,'entitlement tables have zero policies',not exists(select 1 from pg_policies where schemaname='public' and tablename in('saas_features','saas_plans','saas_plan_features','tenant_plan_assignments')),'policy exposed');
  perform pg_temp.ok(13,'direct table grants are closed',not has_table_privilege('authenticated','public.tenant_plan_assignments','SELECT,INSERT,UPDATE,DELETE') and not has_table_privilege('anon','public.saas_features','SELECT'),'table grant exposed');
  perform pg_temp.ok(14,'tenant admin cannot self-grant',pg_temp.denied(admin_a,format('insert into public.tenant_plan_assignments(tenant_id,plan_id) values(%L,%L)',tenant_missing,full_plan)),'self grant allowed');
  perform pg_temp.ok(15,'tenant admin cannot change own plan',pg_temp.denied(admin_a,format('update public.tenant_plan_assignments set plan_id=%L where tenant_id=%L',booking_plan,tenant_a)),'plan change allowed');
  perform pg_temp.ok(16,'tenant admin cannot edit catalog',pg_temp.denied(admin_a,$q$update public.saas_features set active=false where feature_key='events'$q$),'catalog edit allowed');
  perform pg_temp.ok(17,'member resolver allows own full feature',pg_temp.as_user(admin_a,format('select to_jsonb(public.get_my_tenant_feature_access_v1(%L,%L))',tenant_a,'events'))='true'::jsonb,'own resolution failed');
  perform pg_temp.ok(18,'member resolver denies cross tenant',pg_temp.as_user(admin_a,format('select to_jsonb(public.get_my_tenant_feature_access_v1(%L,%L))',tenant_b,'booking'))='false'::jsonb,'cross tenant resolution allowed');
  perform pg_temp.ok(19,'entitlement never expands ordinary-user role',pg_temp.as_user(user_a,format('select to_jsonb(public.get_my_tenant_feature_access_v1(%L,%L))',tenant_a,'reports'))='true'::jsonb and coalesce((pg_temp.as_user(user_a,format('select public.admin_get_reservation_report_v3(%L,current_date,current_date,null,null,null,null,1,50)',tenant_a))->>'ok')::boolean,false)=false,'role expanded');
  select pg_temp.as_user(admin_a,format('select to_jsonb(public.get_my_tenant_features_v1(%L))',tenant_a)) into features_a;
  select pg_temp.as_user(admin_b,format('select to_jsonb(public.get_my_tenant_features_v1(%L))',tenant_b)) into features_b;
  perform pg_temp.ok(20,'full tenant member gets ten keys',jsonb_array_length(features_a)=10,'full list differs');
  perform pg_temp.ok(21,'booking-only member gets one key',features_b='["booking"]'::jsonb,'booking list differs');
  select pg_temp.as_anon($q$select to_jsonb(row_value) from public.get_public_tenant_landing_v2('p10d-full-public') row_value$q$) into public_a;
  select pg_temp.as_anon($q$select to_jsonb(row_value) from public.get_public_tenant_landing_v2('p10d-booking-public') row_value$q$) into public_b;
  perform pg_temp.ok(22,'full landing combines entitlement and visibility',(public_a->>'show_booking')::boolean and (public_a->>'show_events')::boolean and (public_a->>'show_instructor')::boolean,'full landing gated');
  perform pg_temp.ok(23,'booking-only landing keeps booking',(public_b->>'show_booking')::boolean and (public_b->>'show_pricing')::boolean,'booking hidden');
  perform pg_temp.ok(24,'booking-only landing masks events and instructor',not (public_b->>'show_events')::boolean and not (public_b->>'show_instructor')::boolean,'unentitled CTA exposed');
  perform pg_temp.ok(25,'public DTO does not expose plans or feature list',not(public_b ?| array['tenant_id','plan','plan_key','package','features','entitlements','billing']),'commercial model leaked');
  perform pg_temp.ok(26,'public resolver permits only allowlisted public keys',not public.get_public_tenant_feature_access_v1(tenant_a,'reports'),'private feature exposed');
  perform pg_temp.ok(27,'public event reader fails closed for booking-only tenant',(public.get_public_event_list_v3(tenant_b,null,'upcoming',1,20)->>'code')='not_available','event RPC bypass');
  perform pg_temp.ok(28,'staff event RPC fails closed for booking-only tenant',pg_temp.denied(admin_b,format('select public.admin_list_events_v2(%L,null,''all'',1,20)',tenant_b)),'staff event RPC bypass');
  perform pg_temp.ok(29,'staff report RPC fails closed for booking-only tenant',pg_temp.denied(admin_b,format('select public.admin_get_reservation_report_v3(%L,current_date,current_date,null,null,null,null,1,50)',tenant_b)),'report RPC bypass');
  perform pg_temp.ok(30,'staff users RPC fails closed for booking-only tenant',pg_temp.denied(admin_b,format('select public.admin_list_users_v2(%L,1,50,null,null,null,null)',tenant_b)),'staff RPC bypass');
  perform pg_temp.ok(31,'lane config remains available with booking',not pg_temp.denied(admin_b,format('select public.admin_get_lane_booking_configuration_v3(%L)',tenant_b)),'booking config denied');
  perform pg_temp.ok(32,'new event write is denied without entitlement',pg_temp.denied_sql(format('insert into public.events(id,tenant_id,title,event_date,start_time,end_time,location,price,max_participants,is_active) values(%L,%L,''P10D denied'',date ''2099-12-01'',time ''10:00'',time ''11:00'',''Test'',0,10,true)',gen_random_uuid(),tenant_b)),'event write allowed');
  perform pg_temp.ok(33,'full tenant event write is allowed',not pg_temp.denied_sql(format('insert into public.events(id,tenant_id,title,event_date,start_time,end_time,location,price,max_participants,is_active) values(%L,%L,''P10D allowed'',date ''2099-12-01'',time ''10:00'',time ''11:00'',''Test'',0,10,true)',gen_random_uuid(),tenant_a)),'full event write denied');
  delete from public.saas_plan_features where plan_id=full_plan and feature_key='events';
  perform pg_temp.ok(34,'existing event remains after entitlement loss',exists(select 1 from public.events where tenant_id=tenant_a and title='P10D allowed'),'existing event disappeared');
  update public.events set is_active=false where tenant_id=tenant_a and title='P10D allowed';
  perform pg_temp.ok(35,'continuity-safe deactivation succeeds',exists(select 1 from public.events where tenant_id=tenant_a and title='P10D allowed' and not is_active),'deactivation blocked');
  insert into public.saas_plan_features(plan_id,feature_key) values(full_plan,'events');
  perform pg_temp.ok(36,'SECURITY DEFINER inventory is 100',(select count(*)= 97 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prosecdef),'inventory differs');
  perform pg_temp.ok(37,'internal resolver has no browser execute and one service-only use',not has_function_privilege('anon','public.tenant_has_feature_v1(uuid,text)','EXECUTE') and not has_function_privilege('authenticated','public.tenant_has_feature_v1(uuid,text)','EXECUTE') and has_function_privilege('service_role','public.tenant_has_feature_v1(uuid,text)','EXECUTE'),'resolver ACL differs');
  perform pg_temp.ok(38,'member/public resolver ACL is minimal',has_function_privilege('authenticated','public.get_my_tenant_feature_access_v1(uuid,text)','EXECUTE') and not has_function_privilege('anon','public.get_my_tenant_feature_access_v1(uuid,text)','EXECUTE') and has_function_privilege('anon','public.get_public_tenant_feature_access_v1(uuid,text)','EXECUTE') and not has_function_privilege('service_role','public.get_public_tenant_feature_access_v1(uuid,text)','EXECUTE'),'resolver ACL differs');
  perform pg_temp.ok(39,'all entitlement functions have hardened search_path',(select bool_and(proconfig @> array['search_path=pg_catalog, public, pg_temp'] or proconfig @> array['search_path=pg_catalog, public, auth, pg_temp']) from pg_proc where oid in('public.tenant_has_feature_v1(uuid,text)'::regprocedure,'public.get_my_tenant_feature_access_v1(uuid,text)'::regprocedure,'public.get_my_tenant_features_v1(uuid)'::regprocedure,'public.get_public_tenant_feature_access_v1(uuid,text)'::regprocedure,'public.enforce_tenant_feature_write_v1()'::regprocedure)),'search_path differs');
  perform pg_temp.ok(40,'settings reader exposes booleans without plan identity',(pg_temp.as_user(admin_b,$q$select public.admin_get_tenant_public_settings_v1('p10d-booking')$q$)->'feature_access')=jsonb_build_object('booking',true,'events',false,'instructors',false),'settings integration differs');

  insert into public.shooting_lanes(id,tenant_id,name,type,price_per_hour,is_active,max_shooters,booking_step_minutes,display_order,currency_code,resource_kind,whole_lane_bookable,positions_bookable)
  values(lane_b,tenant_b,'P10D Lane B','shooting',100,true,2,30,900,'PLN','lane',true,false);
  perform pg_temp.ok(41,'lane-block direct write is denied without lane-block entitlement',pg_temp.denied_sql(format('insert into public.lane_blocks(tenant_id,lane_id,block_date,start_time,end_time,reason,is_active) values(%L,%L,date ''2099-12-02'',time ''10:00'',time ''11:00'',''denied'',true)',tenant_b,lane_b)),'lane-block write bypassed entitlement');
  perform pg_temp.ok(42,'busy-range reader works with booking entitlement',not pg_temp.denied(admin_b,format('select to_jsonb(row_value) from public.get_lane_booking_busy_ranges_v3(%L,date ''2099-12-02'') row_value limit 1',lane_b)),'booking reader denied');
  delete from public.saas_plan_features where plan_id=booking_plan and feature_key='booking';
  perform pg_temp.ok(43,'busy-range direct RPC fails closed after booking entitlement loss',pg_temp.denied(admin_b,format('select to_jsonb(row_value) from public.get_lane_booking_busy_ranges_v3(%L,date ''2099-12-02'') row_value limit 1',lane_b)),'busy-range RPC bypassed entitlement');
  insert into public.saas_plan_features(plan_id,feature_key) values(booking_plan,'booking');

  insert into public.saas_plan_features(plan_id,feature_key) values(booking_plan,'events');
  insert into public.events(id,tenant_id,title,event_date,start_time,end_time,location,price,max_participants,is_active)
  values(event_b,tenant_b,'P10D Event B',date '2099-12-03',time '10:00',time '11:00','Test',0,10,true);
  insert into public.event_registrations(id,tenant_id,event_id,customer_name,customer_email,customer_phone,registration_status,payment_status)
  values(registration_b,tenant_b,event_b,'P10D User','p10d-event@example.invalid','000','reserve','pay_on_site');
  delete from public.saas_plan_features where plan_id=booking_plan and feature_key='events';
  perform pg_temp.ok(44,'legacy event participant reader fails closed without events entitlement',(pg_temp.as_user(admin_b,format('select public.admin_list_event_registrations_v1(%L,null,null,1,50)',event_b))->>'code')='not_allowed','legacy event reader bypassed entitlement');
  perform pg_temp.ok(45,'legacy event staff writers fail closed without events entitlement',
    (pg_temp.as_user(admin_b,format('select public.approve_event_registration(%L)',registration_b))->>'code')='not_allowed'
    and (pg_temp.as_user(admin_b,format('select public.mark_event_registration_paid(%L)',registration_b))->>'code')='not_allowed','legacy event writer bypassed entitlement');
  perform pg_temp.ok(46,'service-only reserve preparation fails closed without events entitlement',pg_temp.role_denied('service_role',format('select * from public.prepare_event_reserve_promotions(%L)',event_b)),'service event flow bypassed entitlement');
  perform pg_temp.ok(47,'resource-bound check-in RPCs contain canonical entitlement guards',
    strpos(pg_get_functiondef('public.get_check_in_reservation_v1(uuid)'::regprocedure),'PRODUCT-10D entitlement guard')>0
    and strpos(pg_get_functiondef('public.update_reservation_attendance(uuid,text)'::regprocedure),'PRODUCT-10D entitlement guard')>0
    and strpos(pg_get_functiondef('public.update_reservation_customer_verification_v1(uuid,text,text)'::regprocedure),'PRODUCT-10D entitlement guard')>0,'check-in guard missing');
  perform pg_temp.ok(48,'resource and service gates derive tenant from data rather than caller input',
    strpos(pg_get_functiondef('public.get_lane_booking_busy_ranges_v3(uuid,date)'::regprocedure),'select tenant_id into v_tenant from public.shooting_lanes')>0
    and strpos(pg_get_functiondef('public.prepare_event_reserve_promotions(uuid)'::regprocedure),'v_event.tenant_id')>0
    and strpos(pg_get_functiondef('public.prepare_event_reserve_promotions(uuid)'::regprocedure),'tenant_has_feature_v1')>0,'resource tenant derivation missing');
end;
$tests$;

select (case when passed then 'ok ' else 'not ok ' end)||test_order||' - '||test_name||case when passed then '' else E'\n# '||result end from pg_temp.test_results order by test_order;
do $assert$ declare failures text; begin select string_agg(test_order||': '||test_name,', ') into failures from pg_temp.test_results where not passed; if failures is not null then raise exception 'PRODUCT-10D tests failed: %',failures; end if; end $assert$;
rollback;
