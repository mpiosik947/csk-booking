\set ON_ERROR_STOP on
begin;
select set_config('app.product10d_test_enforce','on',true);
create temporary table results(n serial,label text,passed boolean) on commit drop;
create temporary table fixture_ids(user_id uuid,tenant_id uuid) on commit drop;
create function pg_temp.assert_true(label text,value boolean) returns void language plpgsql as $$begin
 if value is distinct from true then raise exception 'FAIL: %',label; end if;
 insert into results(label,passed) values(label,true);
end;$$;
create function pg_temp.rpc(actor uuid,statement text) returns jsonb language plpgsql as $$
declare result jsonb;
begin
 perform set_config('request.jwt.claims',jsonb_build_object('sub',actor,'role',case when actor is null then 'anon' else 'authenticated' end)::text,true);
 perform set_config('request.jwt.claim.sub',coalesce(actor::text,''),true);
 if actor is null then set local role anon; else set local role authenticated; end if;
 execute statement into result;
 reset role;
 perform set_config('request.jwt.claims','{}',true); perform set_config('request.jwt.claim.sub','',true);
 return jsonb_build_object('value',result,'state','00000');
exception when others then
 reset role;
 perform set_config('request.jwt.claims','{}',true); perform set_config('request.jwt.claim.sub','',true);
 return jsonb_build_object('state',sqlstate,'test_error',sqlerrm);
end;$$;
do $test$
declare pa uuid:=gen_random_uuid(); ta uuid:=gen_random_uuid(); stranger uuid:=gen_random_uuid();
 t uuid; result jsonb; call text; role_name text; slug text:='onboard-'||substr(gen_random_uuid()::text,1,8);
 e uuid:=gen_random_uuid(); registration uuid:=gen_random_uuid(); lane uuid:=gen_random_uuid();
 price uuid:=gen_random_uuid(); booking uuid:=gen_random_uuid(); request_key uuid:=gen_random_uuid();
 resource_id uuid; resource_kind text; other_tenant uuid;
begin
 insert into auth.users(id,email,email_confirmed_at) values
 (pa,'platform-'||pa||'@example.invalid',now()),(ta,'admin-'||ta||'@example.invalid',now()),
 (stranger,'stranger-'||stranger||'@example.invalid',now());
 insert into fixture_ids(user_id) values(pa),(ta),(stranger);
 insert into public.platform_admins(user_id,status) values(pa,'active');
 update public.profiles set role='admin' where user_id=ta;
 perform pg_temp.assert_true('global role not platform authority',pg_temp.rpc(ta,'select to_jsonb(public.is_platform_admin_v1())')->'value'='false'::jsonb);
 call:=format('select to_jsonb(public.platform_create_tenant_v1(%L,%L,%L,%L))','Synthetic',slug,slug||'-public','Synthetic city');
 perform pg_temp.assert_true('anon create denied',pg_temp.rpc(null,call)->>'state'='42501');
 perform pg_temp.assert_true('global admin create denied',pg_temp.rpc(ta,call)->>'state'='42501');
 result:=pg_temp.rpc(pa,call);
 perform pg_temp.assert_true('platform create allowed',result->>'state'='00000');
 t:=(result->>'value')::uuid;
 update fixture_ids set tenant_id=t where user_id=pa;
 perform pg_temp.assert_true('draft/private bootstrap',exists(select 1 from public.tenants x join public.tenant_public_profiles p on p.tenant_id=x.id
 where x.id=t and x.status='dormant' and not p.is_public and not p.show_booking and not p.show_events));
 perform pg_temp.assert_true('no automatic plan',not exists(select 1 from public.tenant_plan_assignments where tenant_id=t));
 perform pg_temp.assert_true('duplicate slug denied',pg_temp.rpc(pa,call)->>'state'='23505');
 perform pg_temp.assert_true('reserved slug denied',pg_temp.rpc(pa,format('select to_jsonb(public.platform_create_tenant_v1(%L,%L,%L,%L))','Reserved','platform-admin','safe-other','City'))->>'state'='22023');
 perform pg_temp.assert_true('incomplete activation denied',pg_temp.rpc(pa,format('select to_jsonb(public.platform_set_tenant_state_v1(%L,%L))',t,'activate'))->>'state'='55000');
 perform pg_temp.assert_true('invalid plan denied',pg_temp.rpc(pa,format('select to_jsonb(public.platform_set_tenant_plan_v1(%L,%L))',t,'missing'))->>'state'='22023');
 perform pg_temp.assert_true('explicit booking plan',pg_temp.rpc(pa,format('select to_jsonb(public.platform_set_tenant_plan_v1(%L,%L))',t,'booking_only_v1'))->>'state'='00000');
 perform pg_temp.assert_true('exact lookup allowed',pg_temp.rpc(pa,format('select public.platform_lookup_initial_admin_v1(%L)','admin-'||ta||'@example.invalid'))->'value'->>'user_id'=ta::text);
 perform pg_temp.assert_true('lookup not user directory',pg_temp.rpc(pa,'select public.platform_lookup_initial_admin_v1(''%example.invalid'')')->>'state'='22023');
 perform pg_temp.assert_true('lookup nonplatform denied',pg_temp.rpc(ta,format('select public.platform_lookup_initial_admin_v1(%L)','admin-'||ta||'@example.invalid'))->>'state'='42501');
 perform pg_temp.assert_true('initial admin assigned',pg_temp.rpc(pa,format('select to_jsonb(public.platform_assign_initial_admin_v1(%L,%L))',t,ta))->>'state'='00000');
 perform pg_temp.assert_true('initial admin cannot be repeated',pg_temp.rpc(pa,format('select to_jsonb(public.platform_assign_initial_admin_v1(%L,%L))',t,stranger))->>'state'='55000');
 perform pg_temp.assert_true('initial admin membership',exists(select 1 from public.tenant_memberships where tenant_id=t and user_id=ta and role='admin' and status='active'));
 perform pg_temp.assert_true('global profile unchanged',(select role='admin' from public.profiles where user_id=ta));
 perform pg_temp.assert_true('draft settings accessible to initial admin',pg_temp.rpc(ta,format('select public.admin_get_tenant_public_settings_v1(%L)',slug))->>'state'='00000');
 perform pg_temp.assert_true('draft settings denied to platform alone',pg_temp.rpc(pa,format('select public.admin_get_tenant_public_settings_v1(%L)',slug))->>'state'='42501');
 perform pg_temp.assert_true('private preview allowed',pg_temp.rpc(pa,format('select public.platform_preview_tenant_v1(%L)',t))->'value'->>'public_slug'=slug||'-public');
 perform pg_temp.assert_true('preview denied to ordinary tenant admin',pg_temp.rpc(ta,format('select public.platform_preview_tenant_v1(%L)',t))->>'state'='42501');
 perform pg_temp.assert_true('tenant admin no platform plan write',pg_temp.rpc(ta,format('select to_jsonb(public.platform_set_tenant_plan_v1(%L,%L))',t,'current_full_v1'))->>'state'='42501');
 perform pg_temp.assert_true('tenant admin no platform lifecycle',pg_temp.rpc(ta,format('select to_jsonb(public.platform_set_tenant_state_v1(%L,%L))',t,'activate'))->>'state'='42501');
 perform pg_temp.assert_true('activation allowed when ready',pg_temp.rpc(pa,format('select to_jsonb(public.platform_set_tenant_state_v1(%L,%L))',t,'activate'))->>'state'='00000');
 perform pg_temp.assert_true('activation not publication',not(select is_public from public.tenant_public_profiles where tenant_id=t));
 perform pg_temp.assert_true('explicit publication allowed',pg_temp.rpc(pa,format('select to_jsonb(public.platform_set_tenant_state_v1(%L,%L))',t,'publish'))->>'state'='00000');
 perform pg_temp.assert_true('platform operational privilege absent',pg_temp.rpc(pa,format('select to_jsonb(public.get_my_tenant_role_v1(%L))',t))->'value'='null'::jsonb);
 perform pg_temp.assert_true('platform cannot grant itself existing tenant admin',pg_temp.rpc(pa,format('select to_jsonb(public.platform_assign_initial_admin_v1(%L,%L))',t,pa))->>'state'='55000');
 perform pg_temp.assert_true('booking-only features',(select public.tenant_has_feature_v1(t,'booking') and not public.tenant_has_feature_v1(t,'events')));
 perform pg_temp.assert_true('suspension allowed',pg_temp.rpc(pa,format('select to_jsonb(public.platform_set_tenant_state_v1(%L,%L))',t,'suspend'))->>'state'='00000');
 perform pg_temp.assert_true('suspended unpublished',exists(select 1 from public.tenants x join public.tenant_public_profiles p on p.tenant_id=x.id where x.id=t and x.status='suspended' and not p.is_public));
 perform pg_temp.assert_true('suspended new business denied',not public.tenant_has_feature_v1(t,'booking'));
 perform pg_temp.assert_true('general membership remains active-only',pg_temp.rpc(ta,format('select to_jsonb(public.get_my_tenant_role_v1(%L))',t))->'value'='null'::jsonb);
 perform pg_temp.assert_true('audit present',(select count(*)>=5 from public.platform_audit_logs where tenant_id=t and actor_user_id=pa));
 -- Existing resources are created while active, before suspension.
 perform pg_temp.assert_true('reactivation readiness',pg_temp.rpc(pa,format('select to_jsonb(public.platform_set_tenant_state_v1(%L,%L))',t,'activate'))->>'state'='00000');
 perform pg_temp.assert_true('explicit full plan',pg_temp.rpc(pa,format('select to_jsonb(public.platform_set_tenant_plan_v1(%L,%L))',t,'current_full_v1'))->>'state'='00000');
 insert into public.tenant_memberships(tenant_id,user_id,role,status) values(t,stranger,'user','active');
 insert into public.events(id,tenant_id,title,event_date,start_time,end_time,location,price,max_participants,is_active)
 values(e,t,'Synthetic continuity',current_date+7,time '10:00',time '11:00','Synthetic',0,10,true);
 insert into public.event_registrations(id,tenant_id,event_id,user_id,customer_name,customer_email,customer_phone,registration_status,payment_status)
 values(registration,t,e,stranger,'Synthetic','synthetic@example.invalid','000','registered','free');
 insert into public.shooting_lanes(id,tenant_id,name,type,is_active,max_shooters,booking_step_minutes,display_order,currency_code,resource_kind,whole_lane_bookable,positions_bookable)
 values(lane,t,'Synthetic continuity','test',true,2,60,901,'PLN','lane',true,false);
 insert into public.lane_pricing_rules(id,lane_id,day_group,min_shooters,max_shooters,label,hourly_price,display_order,is_active)
 values(price,lane,'mon_thu',1,2,'Synthetic',10,1,true);
 insert into public.reservations(id,user_id,tenant_id,lane_id,customer_name,customer_email,customer_phone,reservation_date,start_time,end_time,duration_minutes,price,reservation_status,payment_status,attendance_status,shooters_count,pricing_rule_id,pricing_day_group_snapshot,lane_name_snapshot,pricing_label_snapshot,price_per_hour_snapshot,total_price,currency_code,creation_request_id)
 values(booking,stranger,t,lane,'Synthetic','synthetic@example.invalid','000',current_date+7,time '10:00',time '11:00',60,10,'confirmed','pay_on_site','planned',1,price,'mon_thu','Synthetic','Synthetic',10,10,'PLN',gen_random_uuid());
 perform pg_temp.assert_true('downgrade explicit writer allowed',pg_temp.rpc(pa,format('select to_jsonb(public.platform_set_tenant_plan_v1(%L,%L))',t,'booking_only_v1'))->>'state'='00000');
 perform pg_temp.assert_true('downgrade gates events but preserves booking',public.tenant_has_feature_v1(t,'booking') and not public.tenant_has_feature_v1(t,'events'));
 perform pg_temp.assert_true('downgrade preserves existing resources',exists(select 1 from public.events where id=e) and exists(select 1 from public.event_registrations where id=registration) and exists(select 1 from public.reservations where id=booking));
 perform pg_temp.assert_true('downgrade preserves owner history',(pg_temp.rpc(stranger,'select public.get_my_continuity_v1(1,null)')->'value'->>'total')::int=2);
 perform pg_temp.assert_true('downgrade preserves cancellation eligibility',not exists(select 1 from jsonb_array_elements(pg_temp.rpc(stranger,'select public.get_my_continuity_v1(1,null)')->'value'->'items') item where not (item->>'can_cancel')::boolean));
 perform pg_temp.assert_true('suspend resources preserved',pg_temp.rpc(pa,format('select to_jsonb(public.platform_set_tenant_state_v1(%L,%L))',t,'suspend'))->>'state'='00000');
 perform pg_temp.assert_true('owner suspended history retained',(pg_temp.rpc(stranger,'select public.get_my_continuity_v1(1,null)')->'value'->>'total')::int=2);
 perform pg_temp.assert_true('platform has no owner history',(pg_temp.rpc(pa,'select public.get_my_continuity_v1(1,null)')->'value'->>'total')::int=0);
 perform pg_temp.assert_true('platform cannot staff read',pg_temp.rpc(pa,format('select public.get_my_continuity_v1(1,%L)',t))->>'state'='42501');
 perform pg_temp.assert_true('staff history limited to own tenant',(pg_temp.rpc(ta,format('select public.get_my_continuity_v1(1,%L)',t))->'value'->>'total')::int=2);
 foreach resource_kind in array array['reservation','event_registration'] loop
 resource_id:=case resource_kind when 'reservation' then booking else registration end;
 call:=format('select public.cancel_continuity_resource_v1(%L,%L)',resource_kind,resource_id);
 perform pg_temp.assert_true(resource_kind||' platform cancellation denied',pg_temp.rpc(pa,call)->>'state'='42501');
 result:=pg_temp.rpc(stranger,call);
 perform pg_temp.assert_true(resource_kind||' suspended owner cancellation',result->'value'->>'changed'='true');
 perform pg_temp.assert_true(resource_kind||' cancellation idempotent',pg_temp.rpc(stranger,call)->'value'->>'changed'='false');
 request_key:=gen_random_uuid();
 call:=format('select to_jsonb(public.record_external_settlement_v1(%L,%L,%L,10,%L,%L,%L))','external_refund',resource_kind,resource_id,'PLN','synthetic-ref',request_key);
 perform pg_temp.assert_true(resource_kind||' ordinary owner settlement denied',pg_temp.rpc(stranger,call)->>'state'='42501');
 perform pg_temp.assert_true(resource_kind||' platform settlement denied',pg_temp.rpc(pa,call)->>'state'='42501');
 result:=pg_temp.rpc(ta,call);
 perform pg_temp.assert_true(resource_kind||' staff external record',result->>'state'='00000');
 perform pg_temp.assert_true(resource_kind||' settlement idempotent',pg_temp.rpc(ta,call)->'value'=result->'value');
 perform pg_temp.assert_true(resource_kind||' idempotency conflict',pg_temp.rpc(ta,replace(call,'synthetic-ref','different-ref'))->>'state'='22023');
 end loop;
 perform pg_temp.assert_true('unpaid not treated as refund',(select payment_status='pay_on_site' from public.reservations where id=booking));
 perform pg_temp.assert_true('external records bound and audited',(select count(*)=2 from public.external_settlement_records where tenant_id=t)
 and (select count(*)=2 from public.audit_logs where tenant_id=t and action='external_settlement_recorded'));
 perform pg_temp.assert_true('no event promotion from continuity',(select promotion_token is null and promotion_claim_id is null from public.event_registrations where id=registration));
 result:=pg_temp.rpc(pa,format('select to_jsonb(public.platform_create_tenant_v1(%L,%L,%L,%L))','Other synthetic',slug||'-b',slug||'-b-public','Other city'));
 other_tenant:=(result->>'value')::uuid;
 insert into fixture_ids(tenant_id) values(other_tenant);
 perform pg_temp.assert_true('second synthetic onboarding via contract',other_tenant is not null);
 perform pg_temp.assert_true('Admin A cannot read draft B settings',pg_temp.rpc(ta,format('select public.admin_get_tenant_public_settings_v1(%L)',slug||'-b'))->>'state'='42501');
 perform pg_temp.assert_true('Admin A cannot staff-read B',pg_temp.rpc(ta,format('select public.get_my_continuity_v1(1,%L)',other_tenant))->>'state'='42501');
 foreach role_name in array array['employee','instructor','user'] loop
 update public.tenant_memberships set role=role_name where tenant_id=t and user_id=ta;
 perform pg_temp.assert_true(role_name||' platform write denied',pg_temp.rpc(ta,format('select to_jsonb(public.platform_set_tenant_plan_v1(%L,%L))',t,'current_full_v1'))->>'state'='42501');
 call:=format('select to_jsonb(public.record_external_settlement_v1(%L,%L,%L,5,%L,%L,%L))','external_reconciliation','reservation',booking,'PLN','synthetic-role',gen_random_uuid());
 perform pg_temp.assert_true(role_name||' continuity settlement scope',pg_temp.rpc(ta,call)->>'state'=case role_name when 'employee' then '00000' else '42501' end);
 end loop;
 update public.tenant_memberships set role='admin' where tenant_id=t and user_id=ta;
 foreach role_name in array array['pending','suspended'] loop
 update public.tenant_memberships set status=role_name where tenant_id=t and user_id=ta;
 perform pg_temp.assert_true(role_name||' continuity privileged read denied',pg_temp.rpc(ta,format('select public.get_my_continuity_v1(1,%L)',t))->>'state'='42501');
 perform pg_temp.assert_true(role_name||' continuity privileged write denied',pg_temp.rpc(ta,call)->>'state'='42501');
 end loop;
 update public.tenant_memberships set status='active' where tenant_id=t and user_id=ta;
 perform pg_temp.assert_true('suspended account-wide anonymization preserved',pg_temp.rpc(stranger,'select public.anonymize_my_account_v1()')->'value'->>'ok'='true');
 perform pg_temp.assert_true('external references redacted on account-wide deletion',not exists(select 1 from public.external_settlement_records where tenant_id=t and external_reference<>'[redacted]'));
 foreach role_name in array array['anon','authenticated','service_role'] loop
 perform pg_temp.assert_true(role_name||' platform tables closed',not has_table_privilege(role_name,'public.platform_admins','INSERT')
 and not has_table_privilege(role_name,'public.platform_audit_logs','SELECT')
 and not has_table_privilege(role_name,'public.external_settlement_records','INSERT'));
 end loop;
 update public.platform_admins set status='suspended' where user_id=pa;
 perform pg_temp.assert_true('suspended platform authority denied',pg_temp.rpc(pa,'select public.platform_list_tenants_v1(1)')->>'state'='42501');
end;$test$;
select '1..'||(count(*)+1) from results;
select 'ok '||n||' - '||label from results order by n;
select count(*)+1 as cleanup_test_no from results
\gset
select string_agg(user_id::text,',') as users,string_agg(tenant_id::text,',') as tenants from fixture_ids
\gset cleanup_
rollback;
with cleanup as (select
 (select count(*) from auth.users where id=any(string_to_array(:'cleanup_users',',')::uuid[]))+
 (select count(*) from public.profiles where user_id=any(string_to_array(:'cleanup_users',',')::uuid[]))+
 (select count(*) from public.tenants where id=any(string_to_array(:'cleanup_tenants',',')::uuid[]))+
 (select count(*) from public.tenant_memberships where tenant_id=any(string_to_array(:'cleanup_tenants',',')::uuid[]))+
 (select count(*) from public.platform_admins where user_id=any(string_to_array(:'cleanup_users',',')::uuid[]))+
 (select count(*) from public.platform_audit_logs where tenant_id=any(string_to_array(:'cleanup_tenants',',')::uuid[]))+
 (select count(*) from public.external_settlement_records where tenant_id=any(string_to_array(:'cleanup_tenants',',')::uuid[]))+
 (select count(*) from public.audit_logs where tenant_id=any(string_to_array(:'cleanup_tenants',',')::uuid[]))+
 (select count(*) from public.reservations where tenant_id=any(string_to_array(:'cleanup_tenants',',')::uuid[]))+
 (select count(*) from public.event_registrations where tenant_id=any(string_to_array(:'cleanup_tenants',',')::uuid[])) as remaining)
select case when remaining=0 then 'ok '||:cleanup_test_no||' - fixture cleanup = 0' else 'not ok '||:cleanup_test_no||' - fixture cleanup = NONZERO' end from cleanup;
