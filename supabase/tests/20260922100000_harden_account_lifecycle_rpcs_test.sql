\set ON_ERROR_STOP on
\pset format unaligned

select '1..44';
begin;

create temporary table saas9d4c_results(test_no integer primary key,description text not null,passed boolean not null,detail text) on commit drop;
create function pg_temp.ok(integer,text,boolean,text default null) returns void language sql as $f$
  insert into pg_temp.saas9d4c_results values($1,$2,coalesce($3,false),$4);
$f$;
create function pg_temp.as_actor_json(p_user uuid,p_sql text) returns jsonb language plpgsql as $f$
declare v jsonb;
begin
  perform pg_catalog.set_config('request.jwt.claims',pg_catalog.jsonb_build_object('sub',p_user,'role','authenticated')::text,true);
  perform pg_catalog.set_config('request.jwt.claim.sub',p_user::text,true);
  set local role authenticated; execute 'select ('||p_sql||')::jsonb' into v; reset role;
  perform pg_catalog.set_config('request.jwt.claims','{}',true); perform pg_catalog.set_config('request.jwt.claim.sub','',true);
  return v;
exception when others then
  reset role; perform pg_catalog.set_config('request.jwt.claims','{}',true); perform pg_catalog.set_config('request.jwt.claim.sub','',true); raise;
end;$f$;
create function pg_temp.as_actor_raises(p_user uuid,p_sql text,p_state text) returns boolean language plpgsql as $f$
begin
  perform pg_catalog.set_config('request.jwt.claims',pg_catalog.jsonb_build_object('sub',p_user,'role','authenticated')::text,true);
  perform pg_catalog.set_config('request.jwt.claim.sub',p_user::text,true);
  set local role authenticated; execute p_sql; reset role;
  perform pg_catalog.set_config('request.jwt.claims','{}',true); perform pg_catalog.set_config('request.jwt.claim.sub','',true); return false;
exception when others then
  reset role; perform pg_catalog.set_config('request.jwt.claims','{}',true); perform pg_catalog.set_config('request.jwt.claim.sub','',true); return sqlstate=p_state;
end;$f$;

do $tests$
declare
  a uuid:='c5c00000-0000-4000-8000-000000000001';
  b uuid:='42c00000-0000-4000-8000-000000000101';
  c uuid:='42c00000-0000-4000-8000-000000000102';
  owner_x uuid:='42c00000-0000-4000-8000-000000000110';
  foreign_x uuid:='42c00000-0000-4000-8000-000000000111';
  admin_a uuid:='42c00000-0000-4000-8000-000000000112';
  admin_b uuid:='42c00000-0000-4000-8000-000000000113';
  last_admin uuid:='42c00000-0000-4000-8000-000000000114';
  lane_a uuid:='42c00000-0000-4000-8000-000000000120';
  price_a uuid:='42c00000-0000-4000-8000-000000000121';
  event_a uuid:='42c00000-0000-4000-8000-000000000122';
  reservation_a uuid:='42c00000-0000-4000-8000-000000000123';
  registration_a uuid:='42c00000-0000-4000-8000-000000000124';
  result jsonb; exported jsonb; exported_again jsonb; pseudo_hash text; pseudo_id uuid;
begin
  perform pg_temp.ok(1,'exact three owner lifecycle signatures exist',
    pg_catalog.to_regprocedure('public.update_my_profile_v2(text,text,text,text,text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean)') is not null
    and pg_catalog.to_regprocedure('public.export_my_data_v1()') is not null
    and pg_catalog.to_regprocedure('public.anonymize_my_account_v1()') is not null);
  perform pg_temp.ok(2,'target normalized fingerprints are exact',
    pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef('public.update_my_profile_v2(text,text,text,text,text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean)'::regprocedure),E'\r\n',E'\n'),E'\r',E'\n'))='6b740226c6de401754dfb9da2fd543f7'
    and pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef('public.export_my_data_v1()'::regprocedure),E'\r\n',E'\n'),E'\r',E'\n'))='d159b7d0a14f7ffc9d6c3e5088d18dc5'
    and pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef('public.anonymize_my_account_v1()'::regprocedure),E'\r\n',E'\n'),E'\r',E'\n'))='c44c385685f00f36449c5ae80a9e81ce');
  perform pg_temp.ok(3,'all three remain postgres SECURITY DEFINER with hardened search_path',
    (select pg_catalog.bool_and(procedure_record.prosecdef and pg_catalog.pg_get_userbyid(procedure_record.proowner)='postgres' and procedure_record.proconfig=array['search_path=pg_catalog, public, pg_temp'])
     from pg_catalog.pg_proc procedure_record where procedure_record.oid in(
       'public.update_my_profile_v2(text,text,text,text,text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean)'::regprocedure,
       'public.export_my_data_v1()'::regprocedure,'public.anonymize_my_account_v1()'::regprocedure)));
  perform pg_temp.ok(4,'all three are authenticated-only',
    (select pg_catalog.bool_and(pg_catalog.has_function_privilege('authenticated',procedure_record.oid,'EXECUTE')
      and not pg_catalog.has_function_privilege('public',procedure_record.oid,'EXECUTE')
      and not pg_catalog.has_function_privilege('anon',procedure_record.oid,'EXECUTE')
      and not pg_catalog.has_function_privilege('service_role',procedure_record.oid,'EXECUTE'))
     from pg_catalog.pg_proc procedure_record where procedure_record.oid in(
       'public.update_my_profile_v2(text,text,text,text,text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean)'::regprocedure,
       'public.export_my_data_v1()'::regprocedure,'public.anonymize_my_account_v1()'::regprocedure)));
  perform pg_temp.ok(5,'SECURITY DEFINER count is 100 after PRODUCT-10C public landing',(select pg_catalog.count(*)=  100 from pg_catalog.pg_proc procedure_record join pg_catalog.pg_namespace namespace_record on namespace_record.oid=procedure_record.pronamespace where namespace_record.nspname='public' and procedure_record.prosecdef));
  perform pg_temp.ok(6,'compatibility defaults remain 7/7',(select pg_catalog.count(*)=0 from information_schema.columns where table_schema='public' and table_name in('shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','email_deliveries') and column_name='tenant_id' and column_default='''c5c00000-0000-4000-8000-000000000001''::uuid'));
  perform pg_temp.ok(7,'frozen lifecycle dependencies remain unchanged',
    pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef('public.redact_account_audit_details_v1(jsonb,uuid,text,text[])'::regprocedure),E'\r\n',E'\n'),E'\r',E'\n'))='43aab16c26223ca68f4b8a34310bcfb5'
    -- Tenant content adds only public-content audit targets; lifecycle branches remain unchanged.
    and pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef('public.set_audit_log_tenant_id()'::regprocedure),E'\r\n',E'\n'),E'\r',E'\n'))='f230cb11fa1b59cc801b48c21e18b66b'
    and pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef('public.prevent_non_admin_profile_privilege_changes()'::regprocedure),E'\r\n',E'\n'),E'\r',E'\n'))='05fe62eb086d5bfe7a6f5bd5a1c2dcca');
  perform pg_temp.ok(8,'no leave-tenant contract was introduced',pg_catalog.to_regprocedure('public.leave_tenant_v1()') is null);

  insert into public.tenants(id,name,slug,status) values
    (b,'[TEST][9D4C] Tenant B','test-9d4c-b','dormant'),
    (c,'[TEST][9D4C] Tenant C','test-9d4c-c','dormant');
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at) values
    (owner_x,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','9d4c-owner@example.invalid','',now(),'{}','{}',now(),now()),
    (foreign_x,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','9d4c-foreign@example.invalid','',now(),'{}','{}',now(),now()),
    (admin_a,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','9d4c-admin-a@example.invalid','',now(),'{}','{}',now(),now()),
    (admin_b,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','9d4c-admin-b@example.invalid','',now(),'{}','{}',now(),now()),
    (last_admin,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','9d4c-last-admin@example.invalid','',now(),'{}','{}',now(),now());
  insert into public.profiles(user_id,email,first_name,last_name,full_name,phone,role)
  select auth_user.id,auth_user.email,'[TEST][9D4C]','User','[TEST][9D4C] User','500000000','user'
  from auth.users auth_user where auth_user.id in(owner_x,foreign_x,admin_a,admin_b,last_admin)
  on conflict(user_id) do update set email=excluded.email,first_name=excluded.first_name,last_name=excluded.last_name,full_name=excluded.full_name,phone=excluded.phone,role=excluded.role;
  update public.profiles set first_name='Owner',last_name='X',full_name='Owner X',phone='500100200',email='9d4c-owner@example.invalid',role='user' where user_id=owner_x;
  update public.profiles set first_name='Foreign',last_name='X',full_name='Foreign X',phone='500100201',email='9d4c-foreign@example.invalid',role='admin' where user_id=foreign_x;
  update public.profiles set role='admin' where user_id in(admin_a,admin_b,last_admin);
  delete from public.tenant_memberships where tenant_id=a and user_id in(foreign_x,admin_b,last_admin);
  insert into public.tenant_memberships(tenant_id,user_id,role,status) values
    (a,owner_x,'user','active'),(b,owner_x,'user','active'),
    (a,admin_a,'admin','active'),(b,admin_b,'admin','active'),
    (c,last_admin,'admin','active'),(b,foreign_x,'user','active')
  on conflict(tenant_id,user_id) do update set role=excluded.role,status=excluded.status;
  insert into public.tenant_user_verifications(tenant_id,user_id,verification_status,permissions_verified,permissions_verified_at,permissions_verified_by,permissions_verification_note,verified_at,verified_by) values
    (a,owner_x,'verified',true,now(),admin_a,'A SECRET NOTE',now(),admin_a),
    (b,owner_x,'rejected',false,null,null,'B SECRET NOTE',null,null);
  insert into public.tenant_user_admin_notes(tenant_id,user_id,admin_note,updated_by) values
    (a,owner_x,'A ADMIN SECRET',admin_a),(b,owner_x,'B ADMIN SECRET',admin_b);

  insert into public.shooting_lanes(id,tenant_id,name,type,is_active,max_shooters,booking_step_minutes,display_order,currency_code,resource_kind,parent_lane_id,whole_lane_bookable,positions_bookable)
  values(lane_a,a,'[TEST][9D4C] Lane','test',true,2,60,9970,'PLN','lane',null,true,false);
  insert into public.lane_pricing_rules(id,lane_id,day_group,min_shooters,max_shooters,label,hourly_price) values(price_a,lane_a,'mon_thu',1,2,'9D4C price',10);
  insert into public.events(id,tenant_id,title,event_date,start_time,end_time,location,price,max_participants,is_active)
  values(event_a,a,'[TEST][9D4C] Event',date '2099-12-01',time '10:00',time '11:00','[TEST]',0,10,true);
  insert into public.reservations(id,tenant_id,user_id,lane_id,customer_name,customer_email,customer_phone,reservation_date,start_time,end_time,duration_minutes,price,reservation_status,payment_status,attendance_status,admin_note,check_in_token,reservation_note,shooters_count,pricing_rule_id,pricing_day_group_snapshot,lane_name_snapshot,pricing_label_snapshot,price_per_hour_snapshot,total_price,currency_code,creation_request_id)
  values(reservation_a,a,owner_x,lane_a,'Owner X','9d4c-owner@example.invalid','500100200',date '2099-12-02',time '10:00',time '11:00',60,10,'confirmed','pay_on_site','planned','RES ADMIN SECRET',pg_catalog.gen_random_uuid(),'RES NOTE SECRET',1,price_a,'mon_thu','Lane','Price',10,10,'PLN',pg_catalog.gen_random_uuid());
  insert into public.event_registrations(id,tenant_id,event_id,user_id,customer_name,customer_email,customer_phone,registration_status,payment_status,promotion_token,promotion_token_expires_at)
  values(registration_a,a,event_a,owner_x,'Owner X','9d4c-owner@example.invalid','500100200','registered','pay_on_site','PROMO SECRET',now()+interval '1 day');
  insert into public.email_deliveries(tenant_id,message_type,record_id,recipient_user_id,sent_at,provider_message_id)
  values(a,'reservation_confirmation',reservation_a,owner_x,now(),'9d4c-provider');
  insert into public.confirmation_email_rate_limits(scope_type,scope_key,request_timestamps) values('user',owner_x::text,array[now()]);

  result:=pg_temp.as_actor_json(owner_x,$sql$public.update_my_profile_v2('500999888','00-001','Warszawa','Testowa','1',null,true,false,false,false,false,false,false,false,false,false)$sql$);
  perform pg_temp.ok(9,'owner profile update succeeds without tenant authority input',result @> '{"ok":true,"changed":true,"declarations_changed":true}'::jsonb);
  perform pg_temp.ok(10,'only allowlisted owner profile fields changed',(select phone='500999888' and city='Warszawa' and permission_sport from public.profiles where user_id=owner_x));
  perform pg_temp.ok(11,'foreign profile remains unchanged',(select phone='500100201' from public.profiles where user_id=foreign_x));
  perform pg_temp.ok(12,'Tenant A verification was invalidated',(select verification_status='pending' and not permissions_verified and permissions_verification_note is null from public.tenant_user_verifications where tenant_id=a and user_id=owner_x));
  perform pg_temp.ok(13,'Tenant B verification was invalidated independently',(select verification_status='pending' and not permissions_verified and permissions_verification_note is null from public.tenant_user_verifications where tenant_id=b and user_id=owner_x));
  perform pg_temp.ok(14,'one PII-free invalidation audit exists per changed tenant',(select pg_catalog.count(*)=2 and pg_catalog.bool_and(not(details ? 'email') and not(details ? 'phone') and not(details ? 'note')) from public.audit_logs where action='tenant_user_verification_invalidated' and target_id=owner_x));
  perform pg_temp.ok(15,'no-change owner update creates no extra tenant audit',
    (pg_temp.as_actor_json(owner_x,$sql$public.update_my_profile_v2('500999888','00-001','Warszawa','Testowa','1',null,true,false,false,false,false,false,false,false,false,false)$sql$)->>'code')='no_change'
    and (select pg_catalog.count(*)=2 from public.audit_logs where action='tenant_user_verification_invalidated' and target_id=owner_x));

  exported:=pg_temp.as_actor_json(owner_x,'public.export_my_data_v1()');
  perform pg_temp.ok(16,'export is version 2 with the exact top-level contract',exported->>'export_version'='2' and (select pg_catalog.array_agg(key order by key)=array['account','event_registrations','export_version','generated_at','profile','reservations','tenant_relationships']::text[] from pg_catalog.jsonb_object_keys(exported) key));
  perform pg_temp.ok(17,'export contains exactly two caller tenant relationships',pg_catalog.jsonb_array_length(exported->'tenant_relationships')=2);
  perform pg_temp.ok(18,'tenant relationship DTO uses only approved fields',(exported->'tenant_relationships')::text !~ '"(admin_note|permissions_verification_note|user_id|actor)"[[:space:]]*:');
  perform pg_temp.ok(19,'relationship ordering is deterministic',(exported->'tenant_relationships'->0->'tenant'->>'id')=b::text and (exported->'tenant_relationships'->1->'tenant'->>'id')=a::text);
  perform pg_temp.ok(20,'Tenant A and B states remain independently represented',(exported->'tenant_relationships'->0->'verification'->>'status')='pending' and (exported->'tenant_relationships'->1->'verification'->>'status')='pending');
  perform pg_temp.ok(21,'foreign tenant relationship and profile are excluded',exported::text not like '%'||foreign_x::text||'%' and exported::text not like '%9d4c-foreign@example.invalid%');
  perform pg_temp.ok(22,'admin notes and verification notes are excluded',exported::text not like '%ADMIN SECRET%' and exported::text not like '%SECRET NOTE%');
  perform pg_temp.ok(23,'technical secrets are excluded',exported::text not like '%PROMO SECRET%' and exported::text not like '%9d4c-provider%' and exported::text !~ '"(check_in_token|promotion_token|jwt|service_role|admin_note)"[[:space:]]*:');
  exported_again:=pg_temp.as_actor_json(owner_x,'public.export_my_data_v1()');
  perform pg_temp.ok(24,'repeat export is deterministic apart from generated_at',(exported-'generated_at')=(exported_again-'generated_at'));
  perform pg_temp.ok(25,'export does not mutate lifecycle rows',(select pg_catalog.count(*)=2 from public.tenant_memberships where user_id=owner_x) and (select pg_catalog.count(*)=2 from public.tenant_user_verifications where user_id=owner_x));

  perform pg_temp.ok(26,'last active tenant admin deletion is blocked',pg_temp.as_actor_raises(last_admin,'select public.anonymize_my_account_v1()','23514'));
  perform pg_temp.ok(27,'blocked last-admin deletion is atomic',(select exists(select 1 from public.profiles where user_id=last_admin) and exists(select 1 from public.tenant_memberships where tenant_id=c and user_id=last_admin)));
  result:=pg_temp.as_actor_json(owner_x,'public.anonymize_my_account_v1()');
  perform pg_temp.ok(28,'first anonymization reports controlled success',result @> '{"ok":true,"changed":true,"code":"anonymized","reservation_count":1,"event_registration_count":1}'::jsonb);
  perform pg_temp.ok(29,'all caller tenant memberships are removed',not exists(select 1 from public.tenant_memberships where user_id=owner_x));
  perform pg_temp.ok(30,'all caller tenant verifications are removed',not exists(select 1 from public.tenant_user_verifications where user_id=owner_x));
  perform pg_temp.ok(31,'all caller tenant notes are removed',not exists(select 1 from public.tenant_user_admin_notes where user_id=owner_x));
  perform pg_temp.ok(32,'global profile is removed but auth account remains',not exists(select 1 from public.profiles where user_id=owner_x) and exists(select 1 from auth.users where id=owner_x));
  perform pg_temp.ok(33,'reservation history is retained and anonymized',(select user_id is null and customer_name like 'deleted-user-%' and customer_email like 'deleted-user-%@invalid.local' and customer_phone='[redacted]' and admin_note is null and reservation_note is null and check_in_token is null and pii_anonymized_at is not null from public.reservations where id=reservation_a));
  perform pg_temp.ok(34,'event registration history is retained and anonymized',(select user_id is null and customer_name like 'deleted-user-%' and customer_email like 'deleted-user-%@invalid.local' and customer_phone='[redacted]' and promotion_token is null and pii_anonymized_at is not null from public.event_registrations where id=registration_a));
  perform pg_temp.ok(35,'technical delivery and rate-limit state is removed',not exists(select 1 from public.email_deliveries where recipient_user_id=owner_x) and not exists(select 1 from public.confirmation_email_rate_limits where scope_type='user' and scope_key=owner_x::text));
  pseudo_hash:=pg_catalog.md5(owner_x::text||':csk-sec009-v1');
  pseudo_id:=(pg_catalog.substr(pseudo_hash,1,8)||'-'||pg_catalog.substr(pseudo_hash,9,4)||'-'||pg_catalog.substr(pseudo_hash,13,4)||'-'||pg_catalog.substr(pseudo_hash,17,4)||'-'||pg_catalog.substr(pseudo_hash,21,12))::uuid;
  perform pg_temp.ok(36,'exactly one global account audit was written',(select pg_catalog.count(*)=1 from public.audit_logs where action='account_anonymized' and tenant_id is null and target_id=pseudo_id));
  perform pg_temp.ok(37,'account audit is PII-free',(select details::text not like '%9d4c-owner@example.invalid%' and details::text not like '%500999888%' and details->>'tenant_membership_count'='2' from public.audit_logs where action='account_anonymized' and target_id=pseudo_id));
  perform pg_temp.ok(38,'historical tenant audit details and actor are pseudonymized',not exists(select 1 from public.audit_logs where actor_user_id=owner_x or actor_name like '%Owner X%' or details::text like '%9d4c-owner@example.invalid%' or details::text like '%500999888%'));
  perform pg_temp.ok(39,'foreign account and tenant relations remain unchanged',exists(select 1 from public.profiles where user_id=foreign_x and email='9d4c-foreign@example.invalid') and exists(select 1 from public.tenant_memberships where tenant_id=b and user_id=foreign_x));
  result:=pg_temp.as_actor_json(owner_x,'public.anonymize_my_account_v1()');
  perform pg_temp.ok(40,'retry is idempotent',result @> '{"ok":true,"changed":false,"code":"already_anonymized"}'::jsonb);
  perform pg_temp.ok(41,'retry creates no second account audit',(select pg_catalog.count(*)=1 from public.audit_logs where action='account_anonymized' and target_id=pseudo_id));
  perform pg_temp.ok(42,'account-wide deletion does not delete other tenant users',(select pg_catalog.count(*)=4 from auth.users where id in(foreign_x,admin_a,admin_b,last_admin)));
  perform pg_temp.ok(43,'tenant-scoped data remains distinct from account-wide contract',(select pg_catalog.count(*)=3 from public.tenants where id in(a,b,c)) and not exists(select 1 from pg_catalog.pg_proc procedure_record where procedure_record.proname like '%leave_tenant%'));
  perform pg_temp.ok(44,'direct sensitive lifecycle tables remain closed and membership read stays owner-scoped',
    pg_catalog.has_table_privilege('authenticated','public.tenant_memberships','SELECT')
    and not pg_catalog.has_table_privilege('authenticated','public.tenant_user_verifications','SELECT')
    and not pg_catalog.has_table_privilege('authenticated','public.tenant_user_admin_notes','SELECT')
    and (select rowsecurity from pg_catalog.pg_tables where schemaname='public' and tablename='tenant_memberships')
    and exists(select 1 from pg_catalog.pg_policies where schemaname='public' and tablename='tenant_memberships' and cmd='SELECT' and qual like '%auth.uid()%'));
end;
$tests$;

select case when passed then 'ok ' else 'not ok ' end||test_no||' - '||description||case when detail is null then '' else ' # '||detail end from saas9d4c_results order by test_no;
do $finish$ begin if exists(select 1 from saas9d4c_results where not passed) or (select pg_catalog.count(*) from saas9d4c_results)<>44 then raise exception 'SAAS-9D-4C focused test failed'; end if; end;$finish$;
rollback;
