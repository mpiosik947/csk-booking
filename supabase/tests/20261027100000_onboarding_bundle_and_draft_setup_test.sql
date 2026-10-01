\set ON_ERROR_STOP on
begin;
select set_config('app.product10d_test_enforce','on',true);
create temporary table results(n serial,label text) on commit drop;
create function pg_temp.ok(label text,passed boolean) returns void language plpgsql as $$begin
 if passed is distinct from true then raise exception 'FAIL: %',label; end if;
 insert into results(label) values(label);
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
 return jsonb_build_object('state','00000','value',result);
exception when others then
 reset role;
 perform set_config('request.jwt.claims','{}',true); perform set_config('request.jwt.claim.sub','',true);
 return jsonb_build_object('state',sqlstate,'error',sqlerrm);
end;$$;
create function pg_temp.bundle(actor uuid,owner_id uuid,key uuid,slug text,plan text default 'booking_only_v1',name text default 'Synthetic')
returns jsonb language sql as $$select pg_temp.rpc(actor,format(
 'select public.platform_create_tenant_bundle_v2(%L,%L,%L,%L,%L,%L,%L)',name,slug,slug||'-public','City',plan,owner_id,key));$$;
create function pg_temp.reject_insert() returns trigger language plpgsql as $$begin raise exception 'Injected persistence failure'; end;$$;
create function pg_temp.conflict_membership() returns trigger language plpgsql as $$begin
 insert into public.tenant_memberships(tenant_id,user_id,role,status) values(new.tenant_id,new.user_id,'user','active');
 return new;
end;$$;
do $test$
declare pa uuid:=gen_random_uuid(); owner_a uuid:=gen_random_uuid(); owner_b uuid:=gen_random_uuid();
 regular uuid:=gen_random_uuid(); ta uuid:=gen_random_uuid(); emp uuid:=gen_random_uuid(); inst uuid:=gen_random_uuid();
 key uuid:=gen_random_uuid(); key_b uuid:=gen_random_uuid(); slug text:='o1a-'||left(replace(gen_random_uuid()::text,'-',''),12);
 a uuid; b uuid; legacy uuid; no_booking uuid; root_a uuid; root_b uuid; actor uuid; role_name text; relation text; result jsonb; receipt jsonb; family jsonb; events_plan uuid;
 count_before bigint; audit_before bigint; query text; resources jsonb; eligibility_state text;
begin
 insert into auth.users(id,email,email_confirmed_at,is_anonymous) select id,'o1a-'||id||'@example.invalid',now(),false
 from unnest(array[pa,owner_a,owner_b,regular,ta,emp,inst]) id;
 insert into public.profiles(id,user_id,email,role) select id,id,email,'user' from auth.users
 where id=any(array[pa,owner_a,owner_b,regular,ta,emp,inst]) on conflict(user_id) do nothing;
 insert into public.platform_admins(user_id,status) values(pa,'active');
 foreach actor in array array[regular,ta,emp,inst] loop
  perform pg_temp.ok('unprivileged bundle denied '||actor,pg_temp.bundle(actor,owner_a,key,slug)->>'state'='42501');
 end loop;
 perform pg_temp.ok('anon denied',pg_temp.bundle(null,owner_a,key,slug)->>'state'='42501');
 update public.platform_admins set status='suspended' where user_id=pa;
 perform pg_temp.ok('suspended PA denied',pg_temp.bundle(pa,owner_a,key,slug)->>'state'='42501');
 delete from public.platform_admins where user_id=pa;
 perform pg_temp.ok('removed PA denied',pg_temp.bundle(pa,owner_a,key,slug)->>'state'='42501');
 insert into public.platform_admins(user_id,status) values(pa,'active');
 legacy:=(pg_temp.rpc(pa,format('select to_jsonb(public.platform_create_tenant_v1(%L,%L,%L,%L))','Legacy',slug||'-legacy',slug||'-legacy-public','City'))->>'value')::uuid;
 select count(*) into count_before from public.tenants;
 perform pg_temp.ok('missing request id denied',pg_temp.bundle(pa,owner_a,null,slug)->>'state'='22023');
 perform pg_temp.ok('zero request id denied',pg_temp.bundle(pa,owner_a,'00000000-0000-0000-0000-000000000000',slug)->>'state'='22023');
 perform pg_temp.ok('nonexistent admin denied',pg_temp.bundle(pa,gen_random_uuid(),key,slug)->>'state'='22023');
 perform pg_temp.ok('invalid plan denied',pg_temp.bundle(pa,owner_a,key,slug,'missing')->>'state'='22023');
 perform pg_temp.ok('invalid plan rolls back', (select count(*)=count_before from public.tenants));
 foreach eligibility_state in array array['unconfirmed','banned','deleted','anonymous','profile'] loop
  update auth.users set email_confirmed_at=case when eligibility_state='unconfirmed' then null else now() end,
   banned_until=case when eligibility_state='banned' then now()+interval '1 day' else null end,
   deleted_at=case when eligibility_state='deleted' then now() else null end,
   is_anonymous=eligibility_state='anonymous' where id=owner_a;
  if eligibility_state='profile' then delete from public.profiles where user_id=owner_a; end if;
  perform pg_temp.ok('eligibility denied '||eligibility_state,pg_temp.bundle(pa,owner_a,key,slug)->>'state'='22023');
  perform pg_temp.ok('lookup hidden '||eligibility_state,pg_temp.rpc(pa,format('select public.platform_lookup_initial_admin_v1(%L)','o1a-'||owner_a||'@example.invalid'))->'value'='null'::jsonb);
  perform pg_temp.ok('legacy assign eligibility denied '||eligibility_state,pg_temp.rpc(pa,format('select to_jsonb(public.platform_assign_initial_admin_v1(%L,%L))',legacy,owner_a))->>'state'='22023');
  perform pg_temp.ok('eligibility rollback '||eligibility_state,(select count(*)=count_before from public.tenants));
 end loop;
 insert into public.profiles(id,user_id,email,role) values(owner_a,owner_a,'o1a-'||owner_a||'@example.invalid','user');
 update auth.users set email_confirmed_at=now(),banned_until=null,deleted_at=null,is_anonymous=false where id=owner_a;
 -- Failures at late persistence boundaries must not leave any bundle records.
 foreach relation in array array['platform_audit_logs','platform_tenant_creation_requests'] loop
  execute format('create trigger onboard_failure before insert on public.%I for each row execute function pg_temp.reject_insert()',relation);
  perform pg_temp.ok('injected failure '||relation,pg_temp.bundle(pa,owner_a,key,slug)->>'state'<>'00000');
  perform pg_temp.ok('full rollback '||relation,(select count(*)=count_before from public.tenants)
   and not exists(select 1 from public.platform_tenant_creation_requests where actor_user_id=pa));
  execute format('drop trigger onboard_failure on public.%I',relation);
 end loop;
 -- A conflicting insert is simulated by a sibling AFTER-profile trigger, not recursion.
 execute format('create function pg_temp.inject_membership() returns trigger language plpgsql as %L',
  'begin insert into public.tenant_memberships(tenant_id,user_id,role,status) values(new.tenant_id,'||quote_literal(owner_a)||',''user'',''active''); return new; end;');
 create trigger onboard_conflict after insert on public.tenant_public_profiles for each row execute function pg_temp.inject_membership();
 perform pg_temp.ok('membership conflict denied',pg_temp.bundle(pa,owner_a,key,slug)->>'state'='23505');
 perform pg_temp.ok('membership conflict rollback',(select count(*)=count_before from public.tenants));
 drop trigger onboard_conflict on public.tenant_public_profiles;
 result:=pg_temp.bundle(pa,owner_a,key,slug); receipt:=result->'value'; a:=(receipt->>'tenant_id')::uuid;
 perform pg_temp.ok('PA atomic bundle',result->>'state'='00000' and a is not null);
 perform pg_temp.ok('safe receipt keys', (select array_agg(k order by k) from jsonb_object_keys(receipt) k)=
  array['city','creation_request_id','initial_admin_user_id','initial_is_public','initial_status','name','plan_key','public_slug','tenant_id','tenant_slug']);
 perform pg_temp.ok('dormant private flags',exists(select 1 from public.tenants t join public.tenant_public_profiles p on p.tenant_id=t.id
  where t.id=a and t.status='dormant' and not p.is_public and not(p.show_booking or p.show_pricing or p.show_events or p.show_contact or p.show_instructor or p.show_about or p.show_regulations)));
 perform pg_temp.ok('plan and exact admin',exists(select 1 from public.tenant_plan_assignments x join public.saas_plans p on p.id=x.plan_id
  where x.tenant_id=a and x.status='active' and p.plan_key='booking_only_v1') and exists(select 1 from public.tenant_memberships where tenant_id=a and user_id=owner_a and role='admin' and status='active'));
 select count(*) into audit_before from public.platform_audit_logs where tenant_id=a;
 perform pg_temp.ok('three canonical audits',audit_before=3);
 perform pg_temp.ok('replay identical',pg_temp.bundle(pa,owner_a,key,slug)->'value'=receipt);
 perform pg_temp.ok('canonical whitespace replay',pg_temp.bundle(pa,owner_a,key,slug,'booking_only_v1',' Synthetic ')->'value'=receipt);
 perform pg_temp.ok('replay no duplicate', (select count(*)=count_before+1 from public.tenants) and (select count(*)=audit_before from public.platform_audit_logs where tenant_id=a));
 perform pg_temp.ok('different payload denied',pg_temp.bundle(pa,owner_a,key,slug,'current_full_v1')->>'state'='22023');
 update public.platform_admins set status='suspended' where user_id=pa;
 perform pg_temp.ok('fresh authority on replay',pg_temp.bundle(pa,owner_a,key,slug)->>'state'='42501');
 update public.platform_admins set status='active' where user_id=pa;
 update auth.users set banned_until=now()+interval '1 day' where id=owner_a;
 perform pg_temp.ok('readiness rechecks assigned admin eligibility',not (public.platform_tenant_readiness_core_v1(a)->>'admin_ready')::boolean);
 update auth.users set banned_until=null where id=owner_a;
 perform pg_temp.ok('slug conflict rollback',pg_temp.bundle(pa,owner_a,gen_random_uuid(),slug)->>'state'='23505' and (select count(*)=count_before+1 from public.tenants));
 perform pg_temp.ok('cross namespace conflict rollback',pg_temp.bundle(pa,owner_a,gen_random_uuid(),slug||'-public')->>'state'<>'00000' and (select count(*)=count_before+1 from public.tenants));
 perform pg_temp.ok('readiness booking not yet ready',pg_temp.rpc(pa,format('select public.platform_get_tenant_onboarding_readiness_v2(%L)',a))->'value'->>'booking_ready'='false');
 family:='{"root":{"name":"Synthetic lane","is_active":true,"online_bookable":true,"max_shooters":2,"max_people_online":2,"booking_step_minutes":60,"durations_minutes":[60,120],"whole_lane_bookable":true,"positions_bookable":false,"pricing":[{"day_group":"mon_thu","min_shooters":1,"max_shooters":2,"label":"Weekday","hourly_price":100},{"day_group":"fri_sun","min_shooters":1,"max_shooters":2,"label":"Weekend","hourly_price":120}]},"positions":[]}'::jsonb;
 query:=format('select public.tenant_setup_create_lane_family_v1(%L,%L::jsonb)',a,family);
 perform pg_temp.ok('PA alone no config',pg_temp.rpc(pa,query)->>'state'='42501');
 perform pg_temp.ok('foreign user no config',pg_temp.rpc(owner_b,query)->>'state'='42501');
 result:=pg_temp.rpc(owner_a,query); root_a:=(result->'value'->>'root_lane_id')::uuid;
 perform pg_temp.ok('draft admin creates complete family',result->'value'->>'ok'='true' and root_a is not null);
 result:=pg_temp.rpc(owner_a,format('select public.tenant_setup_get_lane_configuration_v1(%L)',a));
 resources:=public.lane_booking_family_business_snapshot_v2(root_a);
 perform pg_temp.ok('draft config read only own family',jsonb_array_length(result->'value'->'families')=1);
 resources:=jsonb_set(resources,'{0,pricing,0,hourly_price}','101'::jsonb);
 perform pg_temp.ok('draft config update',pg_temp.rpc(owner_a,format('select public.tenant_setup_set_lane_configuration_v1(%L,%L,1,%L::jsonb)',a,root_a,resources))->'value'->>'ok'='true');
 perform pg_temp.ok('draft update persisted',exists(select 1 from public.lane_pricing_rules where lane_id=root_a and day_group=resources#>>'{0,pricing,0,day_group}' and hourly_price=101));
 perform pg_temp.ok('booking-ready before active',pg_temp.rpc(pa,format('select public.platform_get_tenant_onboarding_readiness_v2(%L)',a))->'value'->>'booking_ready'='true');
 perform pg_temp.ok('draft public configuration denied',pg_temp.rpc(null,format('select to_jsonb(count(*)) from public.get_public_booking_configuration_v2(%L)',a))->>'state'='42501');
 perform pg_temp.ok('draft operational role absent',pg_temp.rpc(owner_a,format('select to_jsonb(public.get_my_tenant_role_v1(%L))',a))->'value'='null'::jsonb);
 perform pg_temp.ok('draft customer self-onboard denied',pg_temp.rpc(regular,format('select to_jsonb(public.self_onboard_tenant_v1(%L))',slug))->>'state'<>'00000');
 perform pg_temp.ok('active config RPC not broadened',pg_temp.rpc(owner_a,format('select public.admin_create_lane_booking_family_v2(%L,%L::jsonb)',a,family))->>'state'='42501');
 foreach role_name in array array['booking','events','staff','instructors','checkin','reports'] loop
  perform pg_temp.ok('draft operational feature denied '||role_name,pg_temp.rpc(owner_a,format('select to_jsonb(public.get_my_tenant_feature_access_v1(%L,%L))',a,role_name))->'value'='false'::jsonb);
 end loop;
 insert into public.tenant_memberships(tenant_id,user_id,role,status) values(a,regular,'user','active');
 perform pg_temp.ok('draft customer booking denied despite membership',pg_temp.rpc(regular,format('select public.create_reservation_v2(%L,current_date+7,''10:00'',60,1,%L)',root_a,gen_random_uuid()))->'value'->>'ok'='false');
 perform pg_temp.ok('draft booking writes zero reservations',not exists(select 1 from public.reservations where tenant_id=a));
 perform pg_temp.ok('draft reports denied',pg_temp.rpc(owner_a,format('select public.admin_get_reservation_report_v3(%L,current_date,current_date+7)',a))->>'state'='42501');
 result:=pg_temp.bundle(pa,owner_b,key_b,slug||'-b','current_full_v1'); b:=(result->'value'->>'tenant_id')::uuid;
 perform pg_temp.ok('B bundle',b is not null);
 result:=pg_temp.rpc(owner_b,format('select public.tenant_setup_create_lane_family_v1(%L,%L::jsonb)',b,family)); root_b:=(result->'value'->>'root_lane_id')::uuid;
 perform pg_temp.ok('B own setup',root_b is not null);
 perform pg_temp.ok('foreign root denied',pg_temp.rpc(owner_a,format('select public.tenant_setup_set_lane_configuration_v1(%L,%L,1,%L::jsonb)',a,root_b,resources))->>'state'='42501');
 insert into public.tenant_memberships(tenant_id,user_id,role,status) values(a,ta,'admin','active'),(a,emp,'employee','active'),(a,inst,'instructor','active');
 foreach actor in array array[ta,emp,inst] loop
  perform pg_temp.ok('tenant role still no platform create',pg_temp.bundle(actor,owner_a,gen_random_uuid(),slug||'-deny')->>'state'='42501');
 end loop;
 update public.tenants set status='active' where id in(a,b);
 update public.tenant_public_profiles set is_public=true where tenant_id in(a,b);
 perform pg_temp.ok('two active count supported',(select count(*)>=2 from public.tenants where status='active'));
 perform pg_temp.ok('draft RPC denies active',pg_temp.rpc(owner_a,query)->>'state'='42501');
 perform pg_temp.ok('explicit A upgrade for event fixtures',pg_temp.rpc(pa,format('select to_jsonb(public.platform_set_tenant_plan_v1(%L,%L))',a,'current_full_v1'))->>'state'='00000');
 insert into public.events(tenant_id,title,event_date,start_time,end_time,location,price,max_participants,is_active)
 values(a,'Synthetic A',current_date+7,'10:00','11:00','City',0,10,true),(b,'Synthetic B',current_date+7,'10:00','11:00','City',0,10,true);
 foreach relation in array array['events','shooting_lanes','lane_booking_rules','lane_booking_durations','lane_pricing_rules'] loop
  foreach actor in array array[null::uuid,regular,owner_a,owner_b] loop
   perform pg_temp.ok('public A/B table '||relation||' actor '||coalesce(actor::text,'anon'),
    (pg_temp.rpc(actor,case when relation in ('events','shooting_lanes') then format('select to_jsonb(count(distinct tenant_id)) from public.%I where tenant_id in(%L,%L)',relation,a,b) else format('select to_jsonb(count(distinct l.tenant_id)) from public.%I r join public.shooting_lanes l on l.id=r.lane_id where l.tenant_id in(%L,%L)',relation,a,b) end)->>'value')::int=2);
  end loop;
 end loop;
 perform pg_temp.ok('A canonical config', (pg_temp.rpc(null,format('select to_jsonb(count(*)) from public.get_public_booking_configuration_v2(%L)',a))->>'value')::int=1);
 perform pg_temp.ok('B canonical config', (pg_temp.rpc(null,format('select to_jsonb(count(*)) from public.get_public_booking_configuration_v2(%L)',b))->>'value')::int=1);
 perform pg_temp.ok('A scoped admin cannot config B',pg_temp.rpc(owner_a,format('select public.admin_get_lane_booking_configuration_v3(%L)',b))->>'state'='42501');
 perform pg_temp.ok('B scoped admin cannot config A',pg_temp.rpc(owner_b,format('select public.admin_get_lane_booking_configuration_v3(%L)',a))->>'state'='42501');
 foreach role_name in array array['dormant','suspended'] loop
  update public.tenants set status=role_name where id=b;
  foreach relation in array array['events','shooting_lanes','lane_booking_rules','lane_booking_durations','lane_pricing_rules'] loop
   foreach actor in array array[null::uuid,regular] loop
    perform pg_temp.ok(role_name||' public B table denied '||relation,
     (pg_temp.rpc(actor,case when relation in ('events','shooting_lanes') then format('select to_jsonb(count(*)) from public.%I where tenant_id=%L',relation,b) else format('select to_jsonb(count(*)) from public.%I r join public.shooting_lanes l on l.id=r.lane_id where l.tenant_id=%L',relation,b) end)->>'value')::int=0);
   end loop;
  end loop;
  perform pg_temp.ok(role_name||' B canonical denied',pg_temp.rpc(null,format('select to_jsonb(count(*)) from public.get_public_booking_configuration_v2(%L)',b))->>'state'='42501');
 end loop;
 update public.tenants set status='active' where id=b;
 update public.tenant_public_profiles set is_public=false where tenant_id=b;
 perform pg_temp.ok('active private B public lane denied',(pg_temp.rpc(null,format('select to_jsonb(count(*)) from public.shooting_lanes where tenant_id=%L',b))->>'value')::int=0);
 perform pg_temp.ok('ledger and cores inaccessible',not has_table_privilege('authenticated','public.platform_tenant_creation_requests','SELECT')
 and not has_function_privilege('authenticated','public.onboarding_lock_admin_core_v1(uuid)','EXECUTE')
 and not has_function_privilege('service_role','public.platform_create_tenant_bundle_v2(text,text,text,text,text,uuid,uuid)','EXECUTE'));
 insert into public.saas_plans(plan_key,status) values('o1a_events_'||left(replace(gen_random_uuid()::text,'-',''),12),'active') returning id into events_plan;
 insert into public.saas_plan_features(plan_id,feature_key) values(events_plan,'events');
 result:=pg_temp.bundle(pa,owner_b,gen_random_uuid(),slug||'-events-only',(select plan_key from public.saas_plans where id=events_plan));
 no_booking:=(result->'value'->>'tenant_id')::uuid;
 perform pg_temp.ok('nonbooking plan does not require lanes',(public.tenant_onboarding_readiness_core_v2(no_booking)->>'activation_ready')::boolean
  and not (public.tenant_onboarding_readiness_core_v2(no_booking)->>'booking_required')::boolean);
 perform pg_temp.ok('draft booking config respects plan',pg_temp.rpc(owner_b,format('select public.tenant_setup_create_lane_family_v1(%L,%L::jsonb)',no_booking,family))->>'state'='42501');
end;$test$;
select '1..'||count(*) from results;
select 'ok '||n||' - '||label from results order by n;
rollback;
