\set ON_ERROR_STOP on
\pset format unaligned
\pset tuples_only on

select '1..28';
begin;
create temporary table test_results(n integer primary key, label text, passed boolean, detail text) on commit drop;
create function pg_temp.ok(integer,text,boolean,text) returns void language sql as $fn$
  insert into pg_temp.test_results values ($1,$2,coalesce($3,false),$4);
$fn$;
create function pg_temp.actor(p_user uuid,p_query text) returns jsonb language plpgsql as $fn$
declare v jsonb;
begin
  perform set_config('request.jwt.claims',jsonb_build_object('sub',p_user,'role','authenticated')::text,true);
  perform set_config('request.jwt.claim.sub',p_user::text,true);
  execute 'set local role authenticated'; execute p_query into v; reset role;
  perform set_config('request.jwt.claim.sub','',true); return v;
exception when others then reset role; perform set_config('request.jwt.claim.sub','',true); raise;
end;$fn$;
create function pg_temp.denied(p_role text,p_query text) returns boolean language plpgsql as $fn$
begin execute format('set local role %I',p_role); execute p_query; reset role; return false;
exception when insufficient_privilege then reset role; return true; end;$fn$;
create function pg_temp.cancel_denied(p_user uuid,p_tenant uuid,p_registration uuid) returns boolean language plpgsql as $fn$
begin
  perform pg_temp.actor(p_user,format('select public.cancel_event_registration_v2(%L,%L)',p_tenant,p_registration));
  return false;
exception when insufficient_privilege then return true; end;$fn$;

do $tests$
declare
  a constant uuid:='c5c00000-0000-4000-8000-000000000001';
  b uuid:=gen_random_uuid(); admin_a uuid:=gen_random_uuid(); admin_b uuid:=gen_random_uuid();
  employee uuid:=gen_random_uuid(); instructor uuid:=gen_random_uuid(); global_admin uuid:=gen_random_uuid();
  pending uuid:=gen_random_uuid(); suspended uuid:=gen_random_uuid(); ordinary uuid:=gen_random_uuid();
  lane_a uuid:=gen_random_uuid(); lane_b uuid:=gen_random_uuid(); event_a uuid:=gen_random_uuid(); event_b uuid:=gen_random_uuid();
  registration_a uuid:=gen_random_uuid(); registration_b uuid:=gen_random_uuid();
  result jsonb; marker text:='[TEST][SAAS-9E-C2-A]['||replace(gen_random_uuid()::text,'-','')||']';
  before_count integer;
begin
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  select id,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',label||'-'||replace(id::text,'-','')||'@example.invalid','',now(),'{}','{}',now(),now()
  from (values(admin_a,'admina'),(admin_b,'adminb'),(employee,'employee'),(instructor,'instructor'),(global_admin,'global'),(pending,'pending'),(suspended,'suspended'),(ordinary,'ordinary')) u(id,label);
  insert into public.profiles(id,user_id,email,role,verification_status)
  select u.id,u.id,u.email,'user','verified' from auth.users u left join public.profiles p on p.user_id=u.id
  where u.id in(admin_a,admin_b,employee,instructor,global_admin,pending,suspended,ordinary) and p.user_id is null;
  update public.profiles set role=case when user_id in(admin_a,admin_b,global_admin,pending,suspended) then 'admin'
    when user_id=employee then 'pracownik' when user_id=instructor then 'instruktor' else 'user' end,
    first_name='Fixture',last_name='Events',full_name=marker,phone='000',verification_status='verified'
    where user_id in(admin_a,admin_b,employee,instructor,global_admin,pending,suspended,ordinary);
  insert into public.tenant_memberships(tenant_id,user_id,role,status) values
    (a,admin_a,'admin','active'),
    (a,employee,'employee','active'),
    (a,instructor,'instructor','active'),
    (a,pending,'admin','pending'),
    (a,suspended,'admin','suspended'),
    (a,ordinary,'user','active')
  on conflict (tenant_id,user_id) do update
  set role=excluded.role,status=excluded.status;
  delete from public.tenant_memberships where tenant_id=a and user_id=global_admin;
  insert into public.tenants(id,name,slug,status) values(b,marker||' B','saas9ec2a-'||left(replace(b::text,'-',''),16),'dormant');
  insert into public.tenant_memberships(tenant_id,user_id,role,status) values
    (b,admin_a,'admin','active'),(b,admin_b,'admin','active');
  insert into public.shooting_lanes(id,tenant_id,name,type,is_active,max_shooters,booking_step_minutes,display_order,resource_kind,parent_lane_id,whole_lane_bookable,positions_bookable)
  values(lane_a,a,marker||' Lane A','test',true,10,60,9980,'lane',null,true,false),
        (lane_b,b,marker||' Lane B','test',true,10,60,9981,'lane',null,true,false);
  insert into public.events(id,tenant_id,title,description,event_date,start_time,end_time,location,price,max_participants,is_active)
  values(event_a,a,marker||' Event A','A','2099-11-01','10:00','11:00','Test',100,10,true),
        (event_b,b,marker||' Event B','B','2099-11-02','10:00','11:00','Test',100,10,true);
  insert into public.event_lanes(tenant_id,event_id,lane_id) values(a,event_a,lane_a),(b,event_b,lane_b);
  insert into public.event_registrations(id,tenant_id,event_id,user_id,customer_name,customer_email,customer_phone,registration_status,payment_status)
  values(registration_a,a,event_a,ordinary,marker||' Customer A','a@example.invalid','000','registered','pay_on_site'),
        (registration_b,b,event_b,admin_b,marker||' Customer B','b@example.invalid','000','registered','pay_on_site');

  perform pg_temp.ok(1,'eight client RPCs and closed core',(select count(*)=9 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in('admin_list_events_v2','admin_create_event_v3','admin_create_event_v3__saas9ec2a_core','admin_list_event_registrations_v2','admin_update_event_v3','admin_set_event_active_v3','approve_event_registration_v2','cancel_event_registration_v2','mark_event_registration_paid_v2')),'inventory');
  perform pg_temp.ok(2,'new client ACL authenticated only',(select count(*)=8 and bool_and(has_function_privilege('authenticated',p.oid,'EXECUTE') and not has_function_privilege('anon',p.oid,'EXECUTE') and not has_function_privilege('service_role',p.oid,'EXECUTE')) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in('admin_list_events_v2','admin_create_event_v3','admin_list_event_registrations_v2','admin_update_event_v3','admin_set_event_active_v3','approve_event_registration_v2','cancel_event_registration_v2','mark_event_registration_paid_v2')),'ACL');
  perform pg_temp.ok(3,'100 definers, zero defaults',(select count(*)=  100 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prosecdef) and (select count(*)=0 from information_schema.columns where table_schema='public' and table_name in('shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','email_deliveries') and column_name='tenant_id' and column_default='''c5c00000-0000-4000-8000-000000000001''::uuid'),'inventory drift');
  result:=pg_temp.actor(admin_a,format('select public.admin_list_events_v2(%L,%L,''all'',''nearest'',1,50)',a,marker));
  perform pg_temp.ok(4,'invoker list returns A',result->>'code'='ok' and exists(select 1 from jsonb_array_elements(result->'items') i where i->>'id'=event_a::text),result::text);
  perform pg_temp.ok(5,'list excludes B even dual-member actor',not exists(select 1 from jsonb_array_elements(result->'items') i where i->>'id'=event_b::text) and result->'pagination'->>'total'='1','cross-tenant aggregation');
  perform pg_temp.ok(6,'instructor retains read', (pg_temp.actor(instructor,format('select public.admin_list_events_v2(%L,%L,''all'',''nearest'',1,50)',a,marker)))->>'code'='ok','instructor RLS');
  perform pg_temp.ok(7,'global role and pending/suspended deny', (pg_temp.actor(global_admin,format('select public.admin_list_events_v2(%L,null,''all'',''nearest'',1,50)',a)))->>'code'='not_allowed' and (pg_temp.actor(pending,format('select public.admin_list_events_v2(%L,null,''all'',''nearest'',1,50)',a)))->>'code'='not_allowed' and (pg_temp.actor(suspended,format('select public.admin_list_events_v2(%L,null,''all'',''nearest'',1,50)',a)))->>'code'='not_allowed','membership bypass');
  result:=pg_temp.actor(admin_a,format('select public.admin_create_event_v3(%L,%L,%L,''2099-11-03'',''10:00'',''11:00'',''Test'',100,10,array[%L]::uuid[])',a,marker||' Created','desc',lane_a));
  perform pg_temp.ok(8,'create stores explicit A tenant',result->>'code'='created' and exists(select 1 from public.events e where e.id=(result->>'event_id')::uuid and e.tenant_id=a),result::text);
  select count(*) into before_count from public.events;
  perform pg_temp.ok(9,'mixed lane B denied without mutation',(pg_temp.actor(admin_a,format('select public.admin_create_event_v3(%L,%L,%L,''2099-11-04'',''10:00'',''11:00'',''Test'',100,10,array[%L]::uuid[])',a,marker||' Mixed','desc',lane_b)))->>'code'='not_allowed' and (select count(*)=before_count from public.events),'lane mismatch');
  perform pg_temp.ok(10,'employee create allowed, instructor denied',(pg_temp.actor(employee,format('select public.admin_create_event_v3(%L,%L,%L,''2099-11-05'',''10:00'',''11:00'',''Test'',100,10,array[]::uuid[])',a,marker||' Employee','desc')))->>'code'='created' and (pg_temp.actor(instructor,format('select public.admin_create_event_v3(%L,%L,%L,''2099-11-05'',''12:00'',''13:00'',''Test'',100,10,array[]::uuid[])',a,marker||' Instructor','desc')))->>'code'='not_allowed','role scope');
  perform pg_temp.ok(11,'A route cannot edit B even dual-member',(pg_temp.actor(admin_a,format('select public.admin_update_event_v3(%L,%L,%L,%L,''2099-11-02'',''10:00'',''11:00'',''Test'',100,10,array[%L]::uuid[])',a,event_b,marker||' SPOOF','desc',lane_b)))->>'code'='not_allowed' and (select title=marker||' Event B' from public.events where id=event_b),'resource mismatch');
  perform pg_temp.ok(12,'A route cannot toggle B',(pg_temp.actor(admin_a,format('select public.admin_set_event_active_v3(%L,%L,false)',a,event_b)))->>'code'='not_allowed' and (select is_active from public.events where id=event_b),'toggle mismatch');
  perform pg_temp.ok(13,'A route cannot read B participants',(pg_temp.actor(admin_a,format('select public.admin_list_event_registrations_v2(%L,%L,null,null,1,50)',a,event_b)))->>'code'='not_allowed','PII mismatch');
  perform pg_temp.ok(14,'A route can read A participants with original DTO',(pg_temp.actor(admin_a,format('select public.admin_list_event_registrations_v2(%L,%L,null,null,1,50)',a,event_a)))->>'code'='ok','participant read');
  perform pg_temp.ok(15,'A route cannot mark B registration by nonexistent ID',(pg_temp.actor(admin_a,format('select public.mark_event_registration_paid_v2(%L,%L)',a,gen_random_uuid())))->>'code'='not_allowed','payment mismatch');
  perform pg_temp.ok(16,'A route cannot approve B registration by nonexistent ID',(pg_temp.actor(admin_a,format('select public.approve_event_registration_v2(%L,%L)',a,gen_random_uuid())))->>'code'='not_allowed','approval mismatch');
  perform pg_temp.ok(17,'cancellation rejects foreign or nonexistent registration',pg_temp.cancel_denied(admin_a,a,gen_random_uuid()),'cancellation mismatch');
  perform pg_temp.ok(18,'ordinary cannot mutate events',(pg_temp.actor(ordinary,format('select public.admin_set_event_active_v3(%L,%L,false)',a,event_a)))->>'code'='not_allowed','ordinary scope');
  perform pg_temp.ok(19,'anon/service cannot invoke staff RPC',pg_temp.denied('anon',format('select public.admin_list_events_v2(%L)',a)) and pg_temp.denied('service_role',format('select public.admin_list_events_v2(%L)',a)),'ACL');
  perform pg_temp.ok(20,'fixture identifiable and transaction-bound',left(marker,20)='[TEST][SAAS-9E-C2-A]' and (select count(*)=8 from public.profiles where full_name=marker),(select count(*)::text from public.profiles where full_name=marker));
  result:=pg_temp.actor(admin_a,format('select public.admin_list_event_registrations_v2(%L,%L,null,null,1,50)',a,event_a));
  perform pg_temp.ok(21,'participant DTO contains A only',result->>'code'='ok' and strpos(result::text,'a@example.invalid')>0 and strpos(result::text,'b@example.invalid')=0,'participant scope or DTO');
  perform pg_temp.ok(22,'route A rejects B participant even actor is B admin',(pg_temp.actor(admin_a,format('select public.approve_event_registration_v2(%L,%L)',a,registration_b)))->>'code'='not_allowed' and (pg_temp.actor(admin_a,format('select public.mark_event_registration_paid_v2(%L,%L)',a,registration_b)))->>'code'='not_allowed' and pg_temp.cancel_denied(admin_a,a,registration_b),'cross-tenant mutation');
  result:=pg_temp.actor(admin_a,format('select public.approve_event_registration_v2(%L,%L)',a,registration_a));
  perform pg_temp.ok(23,'A approve preserves controlled status transition',result->>'code'='updated' and (select registration_status='approved' from public.event_registrations where id=registration_a),'approve');
  result:=pg_temp.actor(employee,format('select public.mark_event_registration_paid_v2(%L,%L)',a,registration_a));
  perform pg_temp.ok(24,'A employee paid action remains allowed',result->>'code'='updated' and (select payment_status='paid_on_site' from public.event_registrations where id=registration_a),'paid');
  result:=pg_temp.actor(admin_a,format('select public.cancel_event_registration_v2(%L,%L)',a,registration_a));
  perform pg_temp.ok(25,'A cancellation preserves controlled result',result->>'changed'='true' and (select registration_status='cancelled' from public.event_registrations where id=registration_a),'cancel');
  perform pg_temp.ok(26,'B registration remains unchanged',(select registration_status='registered' and payment_status='pay_on_site' from public.event_registrations where id=registration_b),'foreign mutation');
  update public.tenants set status='dormant' where id=a;
  update public.tenants set status='active' where id=b;
  perform pg_temp.ok(27,'same actor reads B only when B is active and selected',(pg_temp.actor(admin_a,format('select public.admin_list_event_registrations_v2(%L,%L,null,null,1,50)',b,event_b)))->>'code'='ok' and (pg_temp.actor(admin_a,format('select public.admin_list_event_registrations_v2(%L,%L,null,null,1,50)',a,event_a)))->>'code'='not_allowed','dual membership route');
  update public.tenants set status='dormant' where id=b;
  update public.tenants set status='active' where id=a;
  perform pg_temp.ok(28,'business audit remains tenant bound',not exists(select 1 from public.audit_logs where target_id in(registration_a,registration_b) and tenant_id is distinct from a),'audit');
end;$tests$;
select case when passed then 'ok ' else 'not ok ' end||n||' - '||label||case when passed then '' else E'\n# '||detail end from test_results order by n;
do $assert$ begin if exists(select 1 from test_results where not passed) then raise exception 'C2-A focused test failed'; end if; end;$assert$;
rollback;
select case when not exists(select 1 from public.profiles where full_name like '[TEST][SAAS-9E-C2-A][%')
 and not exists(select 1 from public.tenants where slug like 'saas9ec2a-%') then 'C2-A cleanup PASS' else 'C2-A cleanup FAIL' end;
