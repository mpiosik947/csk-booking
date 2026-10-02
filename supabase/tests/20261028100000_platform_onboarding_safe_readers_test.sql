\set ON_ERROR_STOP on
begin;
select set_config('app.product10d_test_enforce','on',true);
create temporary table results(n serial,label text) on commit drop;
create function pg_temp.ok(label text,passed boolean) returns void language plpgsql as $$begin
 if passed is distinct from true then raise exception 'FAIL: %',label; end if;
 insert into results(label) values(label);
end;$$;
create function pg_temp.rpc(actor uuid,statement text,client_role text default 'authenticated') returns jsonb language plpgsql as $$
declare result jsonb;
begin
 perform set_config('request.jwt.claims',jsonb_build_object('sub',actor,'role',client_role)::text,true);
 perform set_config('request.jwt.claim.sub',coalesce(actor::text,''),true);
 execute format('set local role %I',client_role);
 execute statement into result;
 reset role;
 return jsonb_build_object('state','00000','value',result);
exception when others then reset role; return jsonb_build_object('state',sqlstate); end;$$;
do $test$
declare pa uuid:=gen_random_uuid(); a1 uuid:=gen_random_uuid(); b1 uuid:=gen_random_uuid(); b2 uuid:=gen_random_uuid();
 customer uuid:=gen_random_uuid(); employee uuid:=gen_random_uuid(); instructor uuid:=gen_random_uuid(); inactive uuid:=gen_random_uuid();
 a uuid:=gen_random_uuid(); b uuid:=gen_random_uuid(); empty_tenant uuid:=gen_random_uuid();
 plan1 uuid:=gen_random_uuid(); plan2 uuid:=gen_random_uuid(); plan_off uuid:=gen_random_uuid();
 prefix text:='r1-'||left(replace(gen_random_uuid()::text,'-',''),12); actor uuid; r jsonb; d jsonb; catalog jsonb;
 item jsonb; state text; query text; role_name text; before_count bigint; after_count bigint;
 foreign_event uuid:=gen_random_uuid(); foreign_reservation uuid:=gen_random_uuid(); foreign_audit uuid:=gen_random_uuid();
 foreign_lane uuid:=gen_random_uuid(); foreign_price uuid:=gen_random_uuid();
begin
 -- Synthetic isolated SQL fixtures only; every statement is rolled back.
 insert into auth.users(id,email,email_confirmed_at,is_anonymous)
 select id,'r1-'||id||'@example.invalid',now(),false from unnest(array[pa,a1,b1,b2,customer,employee,instructor,inactive]) id;
 insert into public.profiles(id,user_id,email,role)
 select id,id,email,'user' from auth.users where id=any(array[pa,a1,b1,b2,customer,employee,instructor,inactive]) on conflict(user_id) do nothing;
 insert into public.platform_admins(user_id,status) values(pa,'active');
 insert into public.tenants(id,name,slug,status) values(a,'Tenant A',prefix||'-a','active'),(b,'Tenant B',prefix||'-b','dormant'),(empty_tenant,'Incomplete',prefix||'-empty','dormant');
 insert into public.tenant_public_profiles(tenant_id,display_name,city,public_slug,is_public)
 values(a,'Public A','City A',prefix||'-a-public',true),(b,'Public B','City B',prefix||'-b-public',false);
 insert into public.saas_plans(id,plan_key,status) values(plan1,replace(prefix,'-','_')||'_plan_a','active'),(plan2,replace(prefix,'-','_')||'_plan_b','active'),(plan_off,replace(prefix,'-','_')||'_plan_off','inactive');
 insert into public.saas_features(feature_key,description,active) values(replace(prefix,'-','_')||'_off','PRIVATE_INACTIVE_FEATURE',false);
 insert into public.saas_plan_features(plan_id,feature_key) values(plan1,'booking'),(plan1,'events'),(plan1,replace(prefix,'-','_')||'_off'),(plan2,'booking'),(plan_off,'reports');
 insert into public.tenant_plan_assignments(tenant_id,plan_id,status) values(a,plan1,'active'),(b,plan1,'active');
 insert into public.tenant_memberships(tenant_id,user_id,role,status)
 values(a,a1,'admin','active'),(a,customer,'user','active'),(b,b1,'admin','active'),(b,employee,'employee','active'),(b,instructor,'instructor','active'),(b,inactive,'admin','suspended');
 update public.profiles set phone='FOREIGN_PHONE',postal_code='00-001',city='FOREIGN_CITY',street='FOREIGN_ADDRESS',house_number='88',admin_note='FOREIGN_NOTE',
 weapon_permit_number='FOREIGN_PERMIT',weapon_permit_issuer='FOREIGN_ISSUER',instructor_number='FOREIGN_QUALIFICATION',permissions_verification_note='FOREIGN_VERIFICATION_NOTE' where user_id=customer;
 update auth.users set raw_user_meta_data='{"permit":"FOREIGN_PERMIT","qualification":"FOREIGN_QUALIFICATION"}' where id=customer;
 insert into public.events(id,tenant_id,title,event_date,start_time,end_time,is_active,max_participants)
 values(foreign_event,a,'FOREIGN_EVENT',current_date+30,'10:00','11:00',true,10);
 insert into public.shooting_lanes(id,tenant_id,name,type,is_active,max_shooters,booking_step_minutes,currency_code,resource_kind,whole_lane_bookable,positions_bookable)
 values(foreign_lane,a,'FOREIGN_LANE','test',true,2,60,'PLN','lane',true,false);
 insert into public.lane_pricing_rules(id,lane_id,day_group,min_shooters,max_shooters,label,hourly_price)
 values(foreign_price,foreign_lane,'mon_thu',1,2,'FOREIGN_PRICE',10);
 insert into public.reservations(id,tenant_id,user_id,lane_id,customer_name,customer_email,customer_phone,reservation_date,start_time,end_time,duration_minutes,
 price,reservation_status,payment_status,attendance_status,shooters_count,pricing_rule_id,pricing_day_group_snapshot,lane_name_snapshot,pricing_label_snapshot,price_per_hour_snapshot,total_price,currency_code,creation_request_id)
 values(foreign_reservation,a,customer,foreign_lane,'FOREIGN_CUSTOMER','foreign-customer@example.invalid','FOREIGN_RESERVATION_PHONE',current_date+10,'10:00','11:00',60,
 10,'confirmed','pay_on_site','planned',1,foreign_price,'mon_thu','FOREIGN_LANE','FOREIGN_PRICE',10,10,'PLN',gen_random_uuid());
 insert into public.audit_logs(id,tenant_id,actor_user_id,action,target_type,target_id,details)
 values(foreign_audit,a,customer,'r1_fixture','reservation',foreign_reservation,'{"secret":"FOREIGN_AUDIT_PAYLOAD"}');
 foreach actor in array array[a1,b1,customer,employee,instructor] loop
  foreach query in array array['select public.platform_list_active_plans_v1()',format('select public.platform_get_tenant_onboarding_detail_v1(%L)',b),format('select public.platform_get_tenant_onboarding_detail_v1(%L)',a)] loop
   perform pg_temp.ok('non-PA denied '||actor||query,pg_temp.rpc(actor,query)->>'state'='42501');
  end loop;
 end loop;
 foreach role_name in array array['anon','service_role'] loop
  perform pg_temp.ok(role_name||' catalog ACL denied',pg_temp.rpc(null,'select public.platform_list_active_plans_v1()',role_name)->>'state'='42501');
  perform pg_temp.ok(role_name||' detail ACL denied',pg_temp.rpc(null,format('select public.platform_get_tenant_onboarding_detail_v1(%L)',b),role_name)->>'state'='42501');
 end loop;
 update public.platform_admins set status='suspended' where user_id=pa;
 perform pg_temp.ok('suspended PA catalog denied',pg_temp.rpc(pa,'select public.platform_list_active_plans_v1()')->>'state'='42501');
 perform pg_temp.ok('suspended PA detail denied',pg_temp.rpc(pa,format('select public.platform_get_tenant_onboarding_detail_v1(%L)',b))->>'state'='42501');
 delete from public.platform_admins where user_id=pa;
 perform pg_temp.ok('removed PA catalog denied',pg_temp.rpc(pa,'select public.platform_list_active_plans_v1()')->>'state'='42501');
 perform pg_temp.ok('removed PA detail denied',pg_temp.rpc(pa,format('select public.platform_get_tenant_onboarding_detail_v1(%L)',b))->>'state'='42501');
 insert into public.platform_admins(user_id,status) values(pa,'active');
 r:=pg_temp.rpc(pa,'select public.platform_list_active_plans_v1()');catalog:=r->'value';
 perform pg_temp.ok('PA catalog allowed',r->>'state'='00000');
 perform pg_temp.ok('future active plans returned',(select count(*)=2 from jsonb_array_elements(catalog) x where x->>'plan_key' in(replace(prefix,'-','_')||'_plan_a',replace(prefix,'-','_')||'_plan_b')));
 perform pg_temp.ok('inactive plan absent',not exists(select 1 from jsonb_array_elements(catalog) x where x->>'plan_key'=replace(prefix,'-','_')||'_plan_off'));
 perform pg_temp.ok('all catalog plans active',not exists(select 1 from jsonb_array_elements(catalog) x where x->>'status'<>'active'));
 perform pg_temp.ok('catalog deterministic',catalog=pg_temp.rpc(pa,'select public.platform_list_active_plans_v1()')->'value');
 perform pg_temp.ok('plan ordering canonical',(select jsonb_agg(x order by x->>'plan_key')=catalog from jsonb_array_elements(catalog) x));
 foreach item in array array(select value from jsonb_array_elements(catalog)) loop
  perform pg_temp.ok('plan DTO allowlist '||(item->>'plan_key'),(select array_agg(key order by key)=array['display_name','features','plan_key','status'] from jsonb_object_keys(item) key));
  perform pg_temp.ok('features deterministic '||(item->>'plan_key'),coalesce((select jsonb_agg(x order by x->>'feature_key') from jsonb_array_elements(item->'features') x),'[]'::jsonb)=item->'features');
 end loop;
 perform pg_temp.ok('inactive feature description absent',position('PRIVATE_INACTIVE_FEATURE' in catalog::text)=0);
 select value into item from jsonb_array_elements(catalog) where value->>'plan_key'=replace(prefix,'-','_')||'_plan_a';
 perform pg_temp.ok('active mapped features exact',(select array_agg(x->>'feature_key' order by x->>'feature_key')=array['booking','events'] from jsonb_array_elements(item->'features') x));
 perform pg_temp.ok('feature DTO allowlist',not exists(select 1 from jsonb_array_elements(item->'features') x where (select array_agg(k order by k) from jsonb_object_keys(x) k)<>array['description','feature_key']));
 r:=pg_temp.rpc(pa,format('select public.platform_get_tenant_onboarding_detail_v1(%L)',b));d:=r->'value';
 perform pg_temp.ok('PA detail allowed',r->>'state'='00000');
 perform pg_temp.ok('detail top DTO allowlist',(select array_agg(k order by k)=array['admins','plan','public_profile','readiness','tenant'] from jsonb_object_keys(d) k));
 perform pg_temp.ok('exact tenant B binding',d#>>'{tenant,tenant_id}'=b::text and d#>>'{tenant,name}'='Tenant B' and d#>>'{public_profile,city}'='City B');
 perform pg_temp.ok('tenant DTO allowlist',(select array_agg(k order by k)=array['name','status','technical_slug','tenant_id'] from jsonb_object_keys(d->'tenant') k));
 perform pg_temp.ok('profile DTO allowlist',(select array_agg(k order by k)=array['city','display_name','is_public','public_slug'] from jsonb_object_keys(d->'public_profile') k));
 perform pg_temp.ok('plan DTO allowlist',(select array_agg(k order by k)=array['assignment_status','enabled_feature_keys','plan_key','status'] from jsonb_object_keys(d->'plan') k));
 perform pg_temp.ok('one active admin exact',jsonb_array_length(d->'admins')=1 and d#>>'{admins,0,user_id}'=b1::text);
 perform pg_temp.ok('admin DTO allowlist',(select array_agg(k order by k)=array['email','user_id'] from jsonb_object_keys(d#>'{admins,0}') k));
 perform pg_temp.ok('only related minimal email',d#>>'{admins,0,email}'='r1-'||b1||'@example.invalid');
 perform pg_temp.ok('foreign users and non-admins absent',position(a1::text in d::text)=0 and position(customer::text in d::text)=0 and position(employee::text in d::text)=0 and position(instructor::text in d::text)=0 and position(inactive::text in d::text)=0);
 foreach state in array array['FOREIGN_PHONE','FOREIGN_CITY','FOREIGN_ADDRESS','FOREIGN_NOTE','FOREIGN_PERMIT','FOREIGN_QUALIFICATION','FOREIGN_ISSUER','FOREIGN_VERIFICATION_NOTE','FOREIGN_EVENT','FOREIGN_LANE','FOREIGN_PRICE','FOREIGN_CUSTOMER','foreign-customer@example.invalid','FOREIGN_RESERVATION_PHONE','FOREIGN_AUDIT_PAYLOAD'] loop
  perform pg_temp.ok('foreign customer PII absent '||state,position(state in d::text)=0);
 end loop;
 perform pg_temp.ok('foreign reservation event audit IDs absent',position(foreign_reservation::text in d::text)=0 and position(foreign_event::text in d::text)=0 and position(foreign_audit::text in d::text)=0);
 perform pg_temp.ok('no broad DTO datasets',not (d ?| array['profiles','reservations','events','audit','memberships','customers']));
 perform pg_temp.ok('readiness exact reuse',d->'readiness'=public.tenant_onboarding_readiness_core_v2(b));
 perform pg_temp.ok('zero lanes booking false',d#>>'{readiness,booking_ready}'='false');
 perform pg_temp.ok('readiness legal caveat unchanged',d#>>'{readiness,publication_gate_enforced}'='false' and d#>>'{readiness,legal_launch_gate}'='deferred');
 foreach state in array array['dormant','active','suspended'] loop
  update public.tenants set status=state where id=b;
  d:=pg_temp.rpc(pa,format('select public.platform_get_tenant_onboarding_detail_v1(%L)',b))->'value';
  perform pg_temp.ok('current lifecycle '||state,d#>>'{tenant,status}'=state);
 end loop;
 update public.tenant_public_profiles set is_public=true where tenant_id=b;
 perform pg_temp.ok('publication current true',pg_temp.rpc(pa,format('select public.platform_get_tenant_onboarding_detail_v1(%L)',b))#>>'{value,public_profile,is_public}'='true');
 update public.tenant_public_profiles set is_public=false where tenant_id=b;
 perform pg_temp.ok('publication current false',pg_temp.rpc(pa,format('select public.platform_get_tenant_onboarding_detail_v1(%L)',b))#>>'{value,public_profile,is_public}'='false');
 insert into public.tenant_memberships(tenant_id,user_id,role,status) values(b,b2,'admin','active');
 d:=pg_temp.rpc(pa,format('select public.platform_get_tenant_onboarding_detail_v1(%L)',b))->'value';
 perform pg_temp.ok('multiple active admins supported',jsonb_array_length(d->'admins')=2);
 perform pg_temp.ok('admin order deterministic',(select jsonb_agg(x order by x->>'user_id')=d->'admins' from jsonb_array_elements(d->'admins') x));
 foreach state in array array['active','suspended','ended'] loop
  update public.tenant_plan_assignments set status=state where tenant_id=b;
  d:=pg_temp.rpc(pa,format('select public.platform_get_tenant_onboarding_detail_v1(%L)',b))->'value';
  perform pg_temp.ok('assignment current '||state,d#>>'{plan,assignment_status}'=state);
  perform pg_temp.ok('features reflect assignment '||state,jsonb_array_length(d#>'{plan,enabled_feature_keys}')=case when state='active' then 2 else 0 end);
 end loop;
 update public.saas_plans set status='inactive' where id=plan1;
 update public.tenant_plan_assignments set status='active' where tenant_id=b;
 d:=pg_temp.rpc(pa,format('select public.platform_get_tenant_onboarding_detail_v1(%L)',b))->'value';
 perform pg_temp.ok('inactive assigned plan not fabricated',d#>>'{plan,status}'='inactive' and d#>>'{plan,plan_key}'=replace(prefix,'-','_')||'_plan_a' and d#>'{plan,enabled_feature_keys}'='[]'::jsonb);
 d:=pg_temp.rpc(pa,format('select public.platform_get_tenant_onboarding_detail_v1(%L)',empty_tenant))->'value';
 perform pg_temp.ok('no assignment safely null',d->'plan'='null'::jsonb);
 perform pg_temp.ok('no public profile safely null',d->'public_profile'='null'::jsonb);
 perform pg_temp.ok('no admins safely empty',d->'admins'='[]'::jsonb);
 perform pg_temp.ok('incomplete readiness remains technical object',jsonb_typeof(d->'readiness')='object' and d#>>'{readiness,create_ready}'='false');
 perform pg_temp.ok('unknown tenant null',pg_temp.rpc(pa,format('select public.platform_get_tenant_onboarding_detail_v1(%L)',gen_random_uuid()))->'value'='null'::jsonb);
 perform pg_temp.ok('null tenant null',pg_temp.rpc(pa,'select public.platform_get_tenant_onboarding_detail_v1(null)')->'value'='null'::jsonb);
 select count(*) into before_count from public.platform_audit_logs;
 perform pg_temp.rpc(pa,'select public.platform_list_active_plans_v1()');
 perform pg_temp.rpc(pa,format('select public.platform_get_tenant_onboarding_detail_v1(%L)',b));
 select count(*) into after_count from public.platform_audit_logs;
 perform pg_temp.ok('reads do not audit-write',before_count=after_count);
end;$test$;
select '1..'||count(*) from results;
select 'ok '||n||' - '||label from results order by n;
rollback;
