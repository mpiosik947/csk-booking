\set ON_ERROR_STOP on
\pset format unaligned
\pset tuples_only on
select '1..18';
begin;
create temporary table test_results(n integer primary key,label text,passed boolean,detail text) on commit drop;
create function pg_temp.ok(integer,text,boolean,text) returns void language sql as $fn$ insert into pg_temp.test_results values($1,$2,coalesce($3,false),$4); $fn$;
create function pg_temp.actor(p_user uuid,p_query text) returns jsonb language plpgsql as $fn$
declare v jsonb; begin
  perform set_config('request.jwt.claims',jsonb_build_object('sub',p_user,'role','authenticated')::text,true);
  perform set_config('request.jwt.claim.sub',p_user::text,true);
  execute 'set local role authenticated'; execute p_query into v; reset role;
  perform set_config('request.jwt.claim.sub','',true); return v;
exception when others then reset role; perform set_config('request.jwt.claim.sub','',true); raise; end;$fn$;
create function pg_temp.reader_denied(p_user uuid,p_tenant uuid) returns boolean language plpgsql as $fn$
begin perform pg_temp.actor(p_user,format('select public.admin_get_lane_booking_configuration_v3(%L)',p_tenant)); return false;
exception when insufficient_privilege then return true; end;$fn$;
create function pg_temp.family_payload(p_name text) returns jsonb language sql immutable as $fn$
  select jsonb_build_object('root',jsonb_build_object(
    'name',p_name,'is_active',true,'online_bookable',true,'max_shooters',4,'max_people_online',4,
    'booking_step_minutes',60,'whole_lane_bookable',true,'positions_bookable',false,
    'durations_minutes',jsonb_build_array(60,120),'pricing',jsonb_build_array(
      jsonb_build_object('day_group','mon_thu','min_shooters',1,'max_shooters',4,'label','Pon-Czw','hourly_price',100),
      jsonb_build_object('day_group','fri_sun','min_shooters',1,'max_shooters',4,'label','Pt-Nd','hourly_price',120))),
    'positions','[]'::jsonb);
$fn$;
do $tests$
declare a constant uuid:='c5c00000-0000-4000-8000-000000000001';
  b uuid:=gen_random_uuid(); admin_a uuid:=gen_random_uuid(); admin_b uuid:=gen_random_uuid();
  employee uuid:=gen_random_uuid(); global_admin uuid:=gen_random_uuid(); pending uuid:=gen_random_uuid();
  root_a uuid; root_b uuid:=gen_random_uuid(); snapshot jsonb; result jsonb; resources jsonb; audit_before bigint;
  marker text:='[TEST][SAAS-9E-C2-B]['||replace(gen_random_uuid()::text,'-','')||']';
begin
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  select id,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',label||'-'||replace(id::text,'-','')||'@example.invalid','',now(),'{}','{}',now(),now()
  from (values(admin_a,'admina'),(admin_b,'adminb'),(employee,'employee'),(global_admin,'global'),(pending,'pending')) u(id,label);
  insert into public.profiles(id,user_id,email,role,verification_status)
  select u.id,u.id,u.email,'user','verified' from auth.users u left join public.profiles p on p.user_id=u.id
  where u.id in(admin_a,admin_b,employee,global_admin,pending) and p.user_id is null;
  update public.profiles set role=case when user_id=employee then 'pracownik' else 'admin' end,
    first_name='Fixture',last_name='Lane',full_name=marker,phone='000',verification_status='verified'
    where user_id in(admin_a,admin_b,employee,global_admin,pending);
  insert into public.tenant_memberships(tenant_id,user_id,role,status) values
    (a,admin_a,'admin','active'),
    (a,employee,'employee','active'),
    (a,pending,'admin','pending')
  on conflict (tenant_id,user_id) do update
  set role=excluded.role,status=excluded.status;
  delete from public.tenant_memberships where tenant_id=a and user_id in(admin_b,global_admin);
  insert into public.tenants(id,name,slug,status) values(b,marker||' B','saas9ec2b-'||left(replace(b::text,'-',''),16),'dormant');
  insert into public.tenant_memberships(tenant_id,user_id,role,status) values(b,admin_a,'admin','active'),(b,admin_b,'admin','active');
  insert into public.shooting_lanes(id,tenant_id,name,type,price_per_hour,is_active,max_shooters,booking_step_minutes,display_order,currency_code,resource_kind,parent_lane_id,whole_lane_bookable,positions_bookable)
  values(root_b,b,marker||' Foreign Root','test',0,false,2,60,9990,'PLN','lane',null,true,false);

  perform pg_temp.ok(1,'three selected public RPCs and closed cores',(select count(*)=3 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in('admin_get_lane_booking_configuration_v3','admin_create_lane_booking_family_v2','admin_set_lane_booking_family_configuration_v3')) and (select count(*)=3 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in('admin_get_lane_booking_configuration_v3__c2b_resource','admin_get_lane_booking_configuration_v3__saas9ec2b_core','admin_create_lane_booking_family_v2__saas9ec2b_core')),'inventory');
  perform pg_temp.ok(2,'77 definers and zero defaults',(select count(*)=77 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prosecdef) and (select count(*)=0 from information_schema.columns where table_schema='public' and table_name in('shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','email_deliveries') and column_name='tenant_id' and column_default='''c5c00000-0000-4000-8000-000000000001''::uuid'),'baseline');
  snapshot:=pg_temp.actor(admin_a,format('select public.admin_get_lane_booking_configuration_v3(%L)',a));
  perform pg_temp.ok(3,'admin reads same family DTO',snapshot->>'contract_version'='2' and jsonb_typeof(snapshot->'families')='array','reader DTO');
  perform pg_temp.ok(4,'A reader excludes B family',strpos(snapshot::text,root_b::text)=0 and strpos(snapshot::text,marker||' Foreign Root')=0,'foreign family leakage');
  perform pg_temp.ok(5,'B reader denied while B dormant',pg_temp.reader_denied(admin_a,b),'dormant tenant');
  perform pg_temp.ok(6,'global admin and pending denied',pg_temp.reader_denied(global_admin,a) and pg_temp.reader_denied(pending,a),'global role bypass');
  select count(*) into audit_before from public.audit_logs;
  result:=pg_temp.actor(admin_a,format('select public.admin_create_lane_booking_family_v2(%L,%L::jsonb)',a,pg_temp.family_payload(marker||' Root A')));
  root_a:=(result->>'root_lane_id')::uuid;
  perform pg_temp.ok(7,'A admin creates family',result->>'code'='created' and (select tenant_id=a from public.shooting_lanes where id=root_a),result::text);
  perform pg_temp.ok(8,'create has tenant-bound audit',(select count(*)=audit_before+1 from public.audit_logs) and exists(select 1 from public.audit_logs where tenant_id=a and target_id=root_a),'create audit');
  perform pg_temp.ok(9,'employee cannot create',(pg_temp.actor(employee,format('select public.admin_create_lane_booking_family_v2(%L,%L::jsonb)',a,pg_temp.family_payload(marker||' Employee'))))->>'code'='not_allowed','employee create');
  perform pg_temp.ok(10,'A admin cannot create in dormant B',(pg_temp.actor(admin_a,format('select public.admin_create_lane_booking_family_v2(%L,%L::jsonb)',b,pg_temp.family_payload(marker||' B'))))->>'code'='not_allowed','dormant B');
  perform pg_temp.ok(11,'global role alone cannot create',(pg_temp.actor(global_admin,format('select public.admin_create_lane_booking_family_v2(%L,%L::jsonb)',a,pg_temp.family_payload(marker||' Global'))))->>'code'='not_allowed','global create bypass');
  snapshot:=pg_temp.actor(admin_a,format('select public.admin_get_lane_booking_configuration_v3(%L)',a));
  select configuration_version into audit_before from public.lane_booking_family_configuration_versions where root_lane_id=root_a;
  resources:=public.lane_booking_family_business_snapshot_v2(root_a);
  perform pg_temp.ok(12,'created family visible only once',(select count(*)=1 from jsonb_array_elements(snapshot->'families') f where f->>'root_lane_id'=root_a::text),'read after create');
  result:=pg_temp.actor(admin_a,format('select public.admin_set_lane_booking_family_configuration_v3(%L,%L,%s,%L::jsonb,false)',a,root_b,1,'[]'));
  perform pg_temp.ok(13,'route A rejects B root despite dual membership',result->>'code'='not_allowed','writer route mismatch');
  result:=pg_temp.actor(admin_a,format('select public.admin_set_lane_booking_family_configuration_v3(%L,%L,%s,%L::jsonb,false)',a,root_a,audit_before,resources));
  perform pg_temp.ok(14,'same-T no-change writer preserves DTO',result->>'code'='no_change',result::text);
  perform pg_temp.ok(15,'pending and global admin denied writer',(pg_temp.actor(pending,format('select public.admin_set_lane_booking_family_configuration_v3(%L,%L,1,%L::jsonb,false)',a,root_a,resources)))->>'code'='not_allowed' and (pg_temp.actor(global_admin,format('select public.admin_set_lane_booking_family_configuration_v3(%L,%L,1,%L::jsonb,false)',a,root_a,resources)))->>'code'='not_allowed','writer membership');
  perform pg_temp.ok(16,'created lanes and rules remain tenant-consistent',not exists(select 1 from public.shooting_lanes child join public.shooting_lanes parent on parent.id=child.parent_lane_id where child.tenant_id is distinct from parent.tenant_id) and exists(select 1 from public.lane_booking_rules r join public.shooting_lanes l on l.id=r.lane_id where l.id=root_a),'hierarchy');
  delete from public.shooting_lanes where id=root_b;
  update public.tenants set status='dormant' where id=a;
  update public.tenants set status='active' where id=b;
  result:=pg_temp.actor(admin_a,format('select public.admin_create_lane_booking_family_v2(%L,%L::jsonb)',b,pg_temp.family_payload(marker||' Root B')));
  root_b:=(result->>'root_lane_id')::uuid;
  snapshot:=pg_temp.actor(admin_a,format('select public.admin_get_lane_booking_configuration_v3(%L)',b));
  perform pg_temp.ok(17,'dual member B reader sees B only',snapshot->>'contract_version'='2' and strpos(snapshot::text,root_b::text)>0 and strpos(snapshot::text,root_a::text)=0,'dual-member B');
  update public.tenants set status='dormant' where id=b;
  update public.tenants set status='active' where id=a;
  perform pg_temp.ok(18,'synthetic fixture stays transaction-local',(select count(*)=5 from public.profiles where full_name=marker) and (select count(*)=1 from public.tenants where id=b),'fixture');
end;$tests$;
select case when passed then 'ok ' else 'not ok ' end||n||' - '||label||case when passed then '' else E'\n# '||detail end from test_results order by n;
do $assert$ begin if exists(select 1 from test_results where not passed) then raise exception 'C2-B focused test failed'; end if; end;$assert$;
rollback;
select case when not exists(select 1 from public.profiles where full_name like '[TEST][SAAS-9E-C2-B][%') and not exists(select 1 from public.tenants where slug like 'saas9ec2b-%') then 'C2-B cleanup PASS' else 'C2-B cleanup FAIL' end;
