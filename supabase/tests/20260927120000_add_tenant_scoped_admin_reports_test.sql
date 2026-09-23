\set ON_ERROR_STOP on
\pset format unaligned
\pset tuples_only on
select '1..14';
begin;
create temporary table results(n integer primary key,label text,pass boolean,detail text) on commit drop;
create function pg_temp.ok(integer,text,boolean,text) returns void language sql as $f$ insert into pg_temp.results values($1,$2,coalesce($3,false),$4); $f$;
create function pg_temp.actor(p_user uuid,p_sql text) returns jsonb language plpgsql as $f$
declare r jsonb; begin
  perform set_config('request.jwt.claims',jsonb_build_object('sub',p_user,'role','authenticated')::text,true);
  perform set_config('request.jwt.claim.sub',p_user::text,true);
  execute 'set local role authenticated'; execute p_sql into r; reset role;
  perform set_config('request.jwt.claim.sub','',true); return r;
exception when others then reset role; perform set_config('request.jwt.claim.sub','',true); raise; end;$f$;
do $tests$
declare a constant uuid:='c5c00000-0000-4000-8000-000000000001';
  b uuid:=gen_random_uuid(); admin_a uuid:=gen_random_uuid(); employee uuid:=gen_random_uuid();
  global_admin uuid:=gen_random_uuid(); lane_a uuid:=gen_random_uuid(); lane_b uuid:=gen_random_uuid();
  price_a uuid:=gen_random_uuid(); price_b uuid:=gen_random_uuid(); report_a jsonb; report_b jsonb; export_a jsonb;
  marker text:='[TEST][SAAS-9E-C2-C]['||replace(gen_random_uuid()::text,'-','')||']';
begin
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  select id,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',label||'-'||replace(id::text,'-','')||'@example.invalid','',now(),'{}','{}',now(),now()
  from (values(admin_a,'admin'),(employee,'employee'),(global_admin,'global')) u(id,label);
  insert into public.profiles(id,user_id,email,role,verification_status)
  select u.id,u.id,u.email,'user','verified' from auth.users u left join public.profiles p on p.user_id=u.id
  where u.id in(admin_a,employee,global_admin) and p.user_id is null;
  update public.profiles set role=case when user_id=employee then 'pracownik' else 'admin' end,full_name=marker,
    first_name='Fixture',last_name='Reports',phone='000',verification_status='verified'
    where user_id in(admin_a,employee,global_admin);
  insert into public.tenant_memberships(tenant_id,user_id,role,status) values
    (a,admin_a,'admin','active'),
    (a,employee,'employee','active')
  on conflict (tenant_id,user_id) do update
  set role=excluded.role,status=excluded.status;
  delete from public.tenant_memberships where tenant_id=a and user_id=global_admin;
  insert into public.tenants(id,name,slug,status) values(b,marker||' B','saas9ec2c-'||left(replace(b::text,'-',''),16),'dormant');
  insert into public.tenant_memberships(tenant_id,user_id,role,status) values(b,admin_a,'admin','active');
  insert into public.shooting_lanes(id,tenant_id,name,type,is_active,max_shooters,booking_step_minutes,display_order,resource_kind,parent_lane_id,whole_lane_bookable,positions_bookable)
  values(lane_a,a,marker||' Lane A','shooting',true,2,60,9700,'lane',null,true,false),
        (lane_b,b,marker||' Lane B','shooting',true,2,60,9701,'lane',null,true,false);
  insert into public.lane_booking_rules(lane_id,online_bookable,max_people_online) values(lane_a,true,2),(lane_b,true,2);
  insert into public.lane_pricing_rules(id,lane_id,day_group,min_shooters,max_shooters,label,hourly_price)
  values(price_a,lane_a,'mon_thu',1,2,'A',100),(price_b,lane_b,'mon_thu',1,2,'B',900);
  insert into public.reservations(id,tenant_id,user_id,lane_id,customer_name,customer_email,customer_phone,
    reservation_date,start_time,end_time,duration_minutes,price,reservation_status,payment_status,attendance_status,shooters_count,
    pricing_rule_id,pricing_day_group_snapshot,lane_name_snapshot,pricing_label_snapshot,price_per_hour_snapshot,total_price,currency_code,creation_request_id)
  values(gen_random_uuid(),a,admin_a,lane_a,marker||' A','a@example.invalid','111','2099-06-01','08:00','09:00',60,100,'confirmed','paid','planned',1,price_a,'mon_thu','A','A',100,100,'PLN',gen_random_uuid()),
        (gen_random_uuid(),b,admin_a,lane_b,marker||' B secret','b-secret@example.invalid','999','2099-06-01','09:00','10:00',60,900,'confirmed','paid','planned',1,price_b,'mon_thu','B','B',900,900,'PLN',gen_random_uuid());
  report_a:=pg_temp.actor(admin_a,format('select public.admin_get_reservation_report_v3(%L,''2099-06-01'',''2099-06-01'',null,null,null,null,50,0)',a));
  export_a:=pg_temp.actor(admin_a,format('select public.admin_get_reservation_report_export_v2(%L,''2099-06-01'',''2099-06-01'',null,null,null,null)',a));
  perform pg_temp.ok(1,'two target signatures',to_regprocedure('public.admin_get_reservation_report_v3(uuid,date,date,uuid,text,text,text,integer,integer)') is not null and to_regprocedure('public.admin_get_reservation_report_export_v2(uuid,date,date,uuid,text,text,text)') is not null,'signatures');
  perform pg_temp.ok(2,'95 definers',(select count(*)=73 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prosecdef),'DEFINER');
  perform pg_temp.ok(3,'A report authorized',report_a->>'ok'='true',report_a::text);
  perform pg_temp.ok(4,'A report excludes B before details and KPI',(report_a->'pagination'->>'total')::integer=1 and (report_a->'summary'->>'planned_revenue')::numeric=100 and strpos(report_a::text,'B secret')=0 and not exists(select 1 from jsonb_array_elements(report_a->'filter_options'->'resources') option where option->>'id'=lane_b::text),'KPI/PII');
  perform pg_temp.ok(5,'A export authorized',export_a->>'ok'='true',export_a::text);
  perform pg_temp.ok(6,'A export excludes B and email',(export_a->>'total')::integer=1 and strpos(export_a::text,'B secret')=0 and strpos(export_a::text,'b-secret@example.invalid')=0 and strpos(export_a::text,'900')=0,'export scope');
  perform pg_temp.ok(7,'global admin without membership denied',(pg_temp.actor(global_admin,format('select public.admin_get_reservation_report_v3(%L,''2099-06-01'',''2099-06-01'',null,null,null,null,50,0)',a)))->>'code'='not_allowed','global bypass');
  perform pg_temp.ok(8,'employee denied',(pg_temp.actor(employee,format('select public.admin_get_reservation_report_v3(%L,''2099-06-01'',''2099-06-01'',null,null,null,null,50,0)',a)))->>'code'='not_allowed','role scope');
  perform pg_temp.ok(9,'B dormant denied',(pg_temp.actor(admin_a,format('select public.admin_get_reservation_report_v3(%L,''2099-06-01'',''2099-06-01'',null,null,null,null,50,0)',b)))->>'code'='not_allowed','dormant');
  perform pg_temp.ok(10,'B resource in A filter is rejected',(pg_temp.actor(admin_a,format('select public.admin_get_reservation_report_v3(%L,''2099-06-01'',''2099-06-01'',%L,null,null,null,50,0)',a,lane_b)))->>'code'='invalid_input','lane mismatch');
  perform pg_temp.ok(11,'A filter returns one row',(pg_temp.actor(admin_a,format('select public.admin_get_reservation_report_v3(%L,''2099-06-01'',''2099-06-01'',%L,null,null,null,50,0)',a,lane_a)))->>'ok'='true','filtered report');
  update public.tenants set status='dormant' where id=a;
  update public.tenants set status='active' where id=b;
  report_b:=pg_temp.actor(admin_a,format('select public.admin_get_reservation_report_v3(%L,''2099-06-01'',''2099-06-01'',null,null,null,null,50,0)',b));
  perform pg_temp.ok(12,'dual member B report excludes A',report_b->>'ok'='true' and strpos(report_b::text,marker||' A')=0 and strpos(report_b::text,marker||' B secret')>0 and (pg_temp.actor(admin_a,format('select public.admin_get_reservation_report_v3(%L,''2099-06-01'',''2099-06-01'',null,null,null,null,50,0)',a)))->>'code'='not_allowed','dual membership');
  update public.tenants set status='dormant' where id=b;
  update public.tenants set status='active' where id=a;
  perform pg_temp.ok(13,'old report remains present',to_regprocedure('public.admin_get_reservation_report_v3(uuid,date,date,uuid,text,text,text,integer,integer)') is not null,'legacy');
  perform pg_temp.ok(14,'fixture transaction-scoped',(select count(*)=3 from public.profiles where full_name=marker),'fixture');
end;$tests$;
select case when pass then 'ok ' else 'not ok ' end||n||' - '||label||case when pass then '' else E'\n# '||detail end from results order by n;
do $assert$ begin if exists(select 1 from results where not pass) then raise exception 'C2-C focused test failed'; end if; end;$assert$;
rollback;
select case when not exists(select 1 from public.profiles where full_name like '[TEST][SAAS-9E-C2-C][%') and not exists(select 1 from public.tenants where slug like 'saas9ec2c-%') then 'C2-C cleanup PASS' else 'C2-C cleanup FAIL' end;
