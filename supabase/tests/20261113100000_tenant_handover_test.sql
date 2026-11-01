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
create function pg_temp.config(actor uuid,tid uuid) returns jsonb language sql as $$select pg_temp.rpc(actor,format('select public.platform_get_draft_configuration_v1(%L)',tid));$$;
create function pg_temp.save(actor uuid,tid uuid,section text,payload jsonb,revision text default null,key uuid default gen_random_uuid()) returns jsonb language sql as $$
select pg_temp.rpc(actor,format('select public.platform_save_draft_configuration_v1(%L,%L,%L,%L,%L::jsonb)',tid,coalesce(revision,pg_temp.config(actor,tid)->'value'->>'revision'),key,section,payload));$$;
create function pg_temp.safe(tid uuid) returns boolean language sql as $$select exists(select 1 from public.tenants t join public.tenant_public_profiles p on p.tenant_id=t.id join public.tenant_public_access_controls c on c.tenant_id=t.id where t.id=tid and t.status='dormant' and not p.is_public and c.public_access_state='coming_soon') and not exists(select 1 from public.tenant_memberships where tenant_id=tid);$$;
create function pg_temp.fail_config_audit() returns trigger language plpgsql as $$begin if new.action='tenant_draft_configuration_updated' then raise exception 'injected audit failure'; end if;return new;end;$$;
create function pg_temp.readiness(actor uuid,tid uuid) returns jsonb language sql as $$select pg_temp.rpc(actor,format('select public.platform_get_draft_readiness_v1(%L)',tid));$$;
create function pg_temp.validate(actor uuid,tid uuid,revision text default null) returns jsonb language sql as $$select pg_temp.rpc(actor,format('select public.platform_validate_draft_readiness_v1(%L,%L)',tid,coalesce(revision,pg_temp.readiness(actor,tid)->'value'->>'current_revision')));$$;
create function pg_temp.handover(actor uuid,tid uuid) returns boolean language plpgsql as $$declare result boolean;begin
 perform set_config('request.jwt.claim.sub',actor::text,true);result:=app_private.is_tenant_ready_for_handover_v1(tid);perform set_config('request.jwt.claim.sub','',true);return result;
end;$$;
create function pg_temp.fail_readiness_audit() returns trigger language plpgsql as $$begin if new.action='readiness_validation_passed' then raise exception 'injected readiness audit failure';end if;return new;end;$$;

create function pg_temp.handover_write(actor uuid,tid uuid,selected uuid,rev text default null,request_id uuid default gen_random_uuid()) returns jsonb language sql as $$
select pg_temp.rpc(actor,format('select public.platform_handover_tenant_v1(%L,%L,%L,%L)',tid,selected,coalesce(rev,pg_temp.readiness(actor,tid)->'value'->>'current_revision'),request_id));$$;
create function pg_temp.handover_read(actor uuid,tid uuid) returns jsonb language sql as $$select pg_temp.rpc(actor,format('select public.platform_get_tenant_handover_v1(%L)',tid));$$;
create function pg_temp.reject_handover_audit() returns trigger language plpgsql as $$begin if new.action='tenant_handed_over' then raise exception 'injected handover audit failure';end if;return new;end;$$;
create function pg_temp.reject_handover_membership() returns trigger language plpgsql as $$begin raise exception 'injected handover membership failure';end;$$;
do $$
declare pa uuid:=gen_random_uuid();pa2 uuid:=gen_random_uuid();x uuid:=gen_random_uuid();y uuid:=gen_random_uuid();ta uuid:=gen_random_uuid();emp uuid:=gen_random_uuid();inst uuid:=gen_random_uuid();customer uuid:=gen_random_uuid();actor uuid;
 a uuid:=gen_random_uuid();b uuid:=gen_random_uuid();c uuid;d uuid;legacy uuid;k uuid:=gen_random_uuid();slug text:='handover-'||left(replace(gen_random_uuid()::text,'-',''),12);
 r jsonb;receipt jsonb;rev text;old_rev text;profile jsonb;family jsonb;baseline text;profiles_before text;pa_before text;counts bigint;initial_state jsonb;condition text;
begin
 insert into auth.users(id,email,email_confirmed_at,is_anonymous)select id,id||'@example.invalid',now(),false from unnest(array[pa,pa2,x,y,ta,emp,inst,customer])id;
 insert into public.platform_admins(user_id,status)values(pa,'active'),(pa2,'active');
 -- A/B represent existing tenants, not new creation paths. Explicit local rollback fixtures.
 insert into public.tenants(id,name,slug,status)values(a,'A',slug||'-a','active'),(b,'B',slug||'-b','active');
 insert into public.tenant_public_profiles(tenant_id,public_slug,display_name,city,is_public)values(a,slug||'-a-public','A','City',true),(b,slug||'-b-public','B','City',true);
 insert into public.tenant_memberships(tenant_id,user_id,role,status)values(a,ta,'admin','active'),(a,emp,'employee','active'),(a,inst,'instructor','active'),(a,customer,'user','active'),(b,x,'user','active');
 select md5(jsonb_build_object('tenants',(select jsonb_agg(to_jsonb(t) order by id)from public.tenants t where id in(a,b)),'memberships',(select jsonb_agg(to_jsonb(m)order by tenant_id,user_id)from public.tenant_memberships m where tenant_id in(a,b)))::text)into baseline;
 c:=(pg_temp.rpc(pa,format('select public.platform_create_tenant_draft_v1(%L,%L,%L,%L,null,%L)','C',slug,slug||'-public','City',gen_random_uuid()))->'value'->>'tenant_id')::uuid;
 d:=(pg_temp.rpc(pa,format('select public.platform_create_tenant_draft_v1(%L,%L,%L,%L,null,%L)','D',slug||'-d',slug||'-d-public','City',gen_random_uuid()))->'value'->>'tenant_id')::uuid;
 perform pg_temp.ok('draft created without membership',pg_temp.safe(c));
 perform pg_temp.ok('initial readiness FAIL',pg_temp.validate(pa,c)->'value'->>'overall'='FAIL');
 perform pg_temp.ok('unvalidated handover denied',pg_temp.handover_write(pa,c,x)->>'state'='55000');
 select count(*) into counts from public.tenants;
 perform pg_temp.ok('new legacy bundle closed before writes',pg_temp.rpc(pa,format('select public.platform_create_tenant_bundle_v2(%L,%L,%L,%L,%L,%L,%L)','Legacy new',slug||'-old',slug||'-old-public','City','booking_only_v1',x,gen_random_uuid()))->>'state'='55000' and (select count(*)=counts from public.tenants));
 legacy:=(pg_temp.rpc(pa,format('select to_jsonb(public.platform_create_tenant_v1(%L,%L,%L,%L))','Legacy wrapper',slug||'-legacy',slug||'-legacy-public','City'))->>'value')::uuid;
 perform pg_temp.ok('legacy create now marked safe draft',app_private.is_platform_draft_v1(legacy) and pg_temp.safe(legacy));
 perform pg_temp.ok('legacy wrapper initial assignment blocked',pg_temp.rpc(pa,format('select to_jsonb(public.platform_assign_initial_admin_v1(%L,%L))',legacy,x))->>'state'='55000');
 perform pg_temp.ok('plan configuration succeeds',pg_temp.save(pa,c,'plan','{"plan_key":"current_full_v1"}')->>'state'='00000');
 family:='{"root":{"name":"C axis","is_active":true,"max_shooters":2,"whole_lane_bookable":true,"positions_bookable":false,"online_bookable":true,"max_people_online":2,"booking_step_minutes":60,"durations_minutes":[60],"pricing":[{"day_group":"mon_thu","min_shooters":1,"max_shooters":2,"label":"Price","hourly_price":10},{"day_group":"fri_sun","min_shooters":1,"max_shooters":2,"label":"Price","hourly_price":10}]},"positions":[]}';
 perform pg_temp.ok('resource configuration succeeds',pg_temp.save(pa,c,'create_lane',family)->>'state'='00000');
 perform pg_temp.ok('readiness PASS before handover',pg_temp.validate(pa,c)->'value'->>'state'='VALIDATED');rev:=pg_temp.readiness(pa,c)->'value'->>'current_revision';
 perform pg_temp.ok('legacy initial cannot bypass even with valid proof',pg_temp.rpc(pa,format('select to_jsonb(public.platform_assign_initial_admin_v1(%L,%L))',c,x))->>'state'='55000');
 perform pg_temp.ok('legacy management cannot bypass valid proof',pg_temp.rpc(pa,format('select public.platform_add_tenant_admin_v1(%L,%L,null,%L)',c,x,gen_random_uuid()))->>'state'='55000');
 foreach actor in array array[ta,emp,inst,customer,null::uuid]loop
  perform pg_temp.ok('role handover denied',pg_temp.handover_write(actor,c,x,rev)->>'state'='42501');
  perform pg_temp.ok('role handover read denied',pg_temp.handover_read(actor,c)->>'state'='42501');
  perform pg_temp.ok('direct membership insert denied',pg_temp.rpc(actor,format('insert into public.tenant_memberships(tenant_id,user_id,role,status)values(%L,%L,%L,%L)returning to_jsonb(user_id)',c,x,'admin','active'))->>'state'='42501');
 end loop;
 perform pg_temp.ok('PA direct membership denied',pg_temp.rpc(pa,format('insert into public.tenant_memberships(tenant_id,user_id,role,status)values(%L,%L,%L,%L)returning to_jsonb(user_id)',c,x,'admin','active'))->>'state'='42501');
 perform pg_temp.ok('PA cannot forge private handover',pg_temp.rpc(pa,format('insert into app_private.tenant_handovers(tenant_id,actor_user_id,selected_admin_user_id,request_id,configuration_revision)values(%L,%L,%L,%L,%L)returning to_jsonb(tenant_id)',c,pa,x,k,rev))->>'state'='42501');
 perform pg_temp.ok('private table all client roles denied',not has_table_privilege('anon','app_private.tenant_handovers','select,insert,update,delete') and not has_table_privilege('authenticated','app_private.tenant_handovers','select,insert,update,delete') and not has_table_privilege('service_role','app_private.tenant_handovers','select,insert,update,delete'));
 update public.platform_admins set status='suspended'where user_id=pa2;perform pg_temp.ok('suspended PA denied',pg_temp.handover_write(pa2,c,x,rev)->>'state'='42501');
 delete from public.platform_admins where user_id=pa2;perform pg_temp.ok('removed PA denied',pg_temp.handover_write(pa2,c,x,rev)->>'state'='42501');insert into public.platform_admins(user_id,status)values(pa2,'active');
 update public.profiles set role='admin' where user_id=ta;perform pg_temp.ok('profiles role spoof denied',pg_temp.handover_write(ta,c,x,rev)->>'state'='42501');
 perform pg_temp.ok('forged tenant denied',pg_temp.handover_write(pa,a,x,rev)->>'state'='42501' and pg_temp.handover_write(pa,gen_random_uuid(),x,rev)->>'state'='42501');
 perform pg_temp.ok('forged user denied',pg_temp.handover_write(pa,c,gen_random_uuid(),rev)->>'state'='22023');
 perform pg_temp.ok('foreign tenant revision denied',pg_temp.handover_write(pa,d,x,rev)->>'state'='PT409');
 perform pg_temp.ok('forged revision denied',pg_temp.handover_write(pa,c,x,repeat('0',64))->>'state'='PT409');
 foreach condition in array array['unconfirmed','banned','deleted','anonymous','profile']loop
  update auth.users set email_confirmed_at=case when condition='unconfirmed'then null else now()end,banned_until=case when condition='banned'then now()+interval '1 day'else null end,deleted_at=case when condition='deleted'then now()else null end,is_anonymous=condition='anonymous'where id=x;
  if condition='profile'then delete from public.profiles where user_id=x;end if;
  perform pg_temp.ok('ineligible account denied '||condition,pg_temp.handover_write(pa,c,x,rev)->>'state'='22023');
  perform pg_temp.ok('ineligible lookup absent '||condition,pg_temp.rpc(pa,format('select public.platform_lookup_tenant_admin_candidate_v1(%L,%L)',c,x||'@example.invalid'))->'value'='null'::jsonb);
 end loop;
 update auth.users set email_confirmed_at=now(),banned_until=null,deleted_at=null,is_anonymous=false where id=x;
 insert into public.profiles(id,user_id,email,role)values(x,x,x||'@example.invalid','user');
 perform pg_temp.ok('exact lookup selects existing global account',pg_temp.rpc(pa,format('select public.platform_lookup_tenant_admin_candidate_v1(%L,%L)',c,x||'@example.invalid'))->'value'->>'user_id'=x::text);
 old_rev:=rev;perform pg_temp.save(pa,c,'profile','{"description":"Changed before confirmation"}');
 perform pg_temp.ok('stale screen denied with no membership',pg_temp.handover_write(pa,c,x,old_rev)->>'state'='PT409' and pg_temp.safe(c));
 perform pg_temp.ok('changed config needs new validation',pg_temp.handover_write(pa,c,x)->>'state'='55000');
 perform pg_temp.validate(pa,c);rev:=pg_temp.readiness(pa,c)->'value'->>'current_revision';
 r:=pg_temp.rpc(pa,format('select public.platform_archive_tenant_v1(%L,%L,%L)',c,(select lifecycle_revision from public.tenants where id=c),gen_random_uuid()));perform pg_temp.ok('archive before handover',r->>'state'='00000');
 perform pg_temp.ok('archived handover denied',pg_temp.handover_write(pa,c,x,rev)->>'state'='55000');
 perform pg_temp.rpc(pa,format('select public.platform_restore_archived_tenant_v1(%L,%L,%L)',c,(select lifecycle_revision from public.tenants where id=c),gen_random_uuid()));
 perform pg_temp.ok('restore needs fresh proof',pg_temp.handover_write(pa,c,x)->>'state'='55000');perform pg_temp.validate(pa,c);rev:=pg_temp.readiness(pa,c)->'value'->>'current_revision';
 create trigger reject_handover_audit before insert on public.platform_audit_logs for each row execute function pg_temp.reject_handover_audit();
 perform pg_temp.ok('audit failure rolls back all',pg_temp.handover_write(pa,c,x,rev,k)->>'state'='P0001' and pg_temp.safe(c) and not exists(select 1 from app_private.tenant_handovers where tenant_id=c));drop trigger reject_handover_audit on public.platform_audit_logs;
 create trigger reject_handover_membership before insert on public.tenant_memberships for each row execute function pg_temp.reject_handover_membership();
 perform pg_temp.ok('membership failure rolls back marker',pg_temp.handover_write(pa,c,x,rev,k)->>'state'='P0001' and not exists(select 1 from app_private.tenant_handovers where tenant_id=c));drop trigger reject_handover_membership on public.tenant_memberships;
 select md5(jsonb_agg(to_jsonb(p)order by user_id)::text) into profiles_before from public.profiles p where user_id in(x,y);select md5(jsonb_agg(to_jsonb(p)order by user_id)::text)into pa_before from public.platform_admins p;
 select jsonb_build_object('tenant',to_jsonb(t),'profile',to_jsonb(p),'access',to_jsonb(s))into initial_state from public.tenants t join public.tenant_public_profiles p on p.tenant_id=t.id join public.tenant_public_access_controls s on s.tenant_id=t.id where t.id=c;
 r:=pg_temp.handover_write(pa,c,x,rev,k);receipt:=r->'value';perform pg_temp.ok('atomic handover succeeds '||r::text,r->>'state'='00000');
 perform pg_temp.ok('first admin exactly one active',(select count(*)=1 and bool_and(user_id=x and role='admin' and status='active')from public.tenant_memberships where tenant_id=c));
 perform pg_temp.ok('server receipt bound',receipt->>'tenant_id'=c::text and receipt->>'actor_user_id'=pa::text and receipt->>'selected_admin_user_id'=x::text and receipt->>'request_id'=k::text and receipt->>'configuration_revision'=rev and receipt->>'handed_over_at' is not null);
 perform pg_temp.ok('no global profile role mutation',(select md5(jsonb_agg(to_jsonb(p)order by user_id)::text)=profiles_before from public.profiles p where user_id in(x,y)));
 perform pg_temp.ok('no platform admins mutation',(select md5(jsonb_agg(to_jsonb(p)order by user_id)::text)=pa_before from public.platform_admins p));
 perform pg_temp.ok('tenant lifecycle profile and access bytes unchanged',(select jsonb_build_object('tenant',to_jsonb(t),'profile',to_jsonb(p),'access',to_jsonb(s))=initial_state from public.tenants t join public.tenant_public_profiles p on p.tenant_id=t.id join public.tenant_public_access_controls s on s.tenant_id=t.id where t.id=c));
 perform pg_temp.ok('handover audit exact actor revision',(select count(*)=1 and bool_and(actor_user_id=pa and details->>'configuration_revision'=rev and details->>'user_id'=x::text)from public.platform_audit_logs where tenant_id=c and action='tenant_handed_over'));
 perform pg_temp.ok('membership audit exactly once',(select count(*)=1 from public.platform_audit_logs where tenant_id=c and action='tenant_admin_assigned'));
 select count(*) into counts from public.platform_audit_logs where tenant_id=c;
 perform pg_temp.ok('lost response retry exact receipt',pg_temp.handover_write(pa,c,x,rev,k)->'value'=receipt);
 perform pg_temp.ok('retry no duplicate audits',(select count(*)=counts from public.platform_audit_logs where tenant_id=c));
 perform pg_temp.ok('different user replay denied',pg_temp.handover_write(pa,c,y,rev,k)->>'state'='PT409');
 perform pg_temp.ok('different first request denied',pg_temp.handover_write(pa2,c,y,rev)->>'state'='PT409');
 perform pg_temp.ok('completed no longer initial-ready',not pg_temp.handover(pa,c));
 perform pg_temp.ok('PA completed reader email',pg_temp.handover_read(pa2,c)->'value'->'handover'->>'selected_admin_email'=x||'@example.invalid');
 perform pg_temp.ok('PA detail shows ordinary management',pg_temp.rpc(pa,format('select public.platform_get_tenant_onboarding_detail_v1(%L)',c))->'value'->>'is_platform_draft'='false');
 perform pg_temp.ok('PA inspect retained',pg_temp.rpc(pa,format('select public.platform_get_tenant_admin_management_v1(%L)',c))->'value'->>'active_admin_count'='1');
 perform pg_temp.ok('old PA configuration scope closes',pg_temp.config(pa,c)->>'state'='42501');
 r:=pg_temp.rpc(x,format('select public.admin_get_tenant_public_settings_v1(%L)',slug));profile:=r->'value';perform pg_temp.ok('selected admin own dormant settings accessible',r->>'state'='00000');
 perform pg_temp.ok('selected admin existing lane setup accessible',pg_temp.rpc(x,format('select public.tenant_setup_get_lane_configuration_v1(%L)',c))->>'state'='00000');
 perform pg_temp.ok('selected admin no PA',pg_temp.rpc(x,'select to_jsonb(public.is_platform_admin_v1())')->'value'='false'::jsonb and pg_temp.handover_read(x,c)->>'state'='42501');
 perform pg_temp.ok('selected admin cannot create tenants',pg_temp.rpc(x,format('select to_jsonb(public.platform_create_tenant_v1(%L,%L,%L,%L))','Forbidden',slug||'-forbidden',slug||'-forbidden-public','City'))->>'state'='42501');
 perform pg_temp.ok('selected admin other tenant denied',pg_temp.rpc(x,format('select public.admin_get_tenant_public_settings_v1(%L)',slug||'-a'))->>'state'='42501');
 r:=pg_temp.rpc(x,format('select public.admin_update_tenant_public_settings_v1(%L,%L::jsonb,%L::timestamptz)',slug,(profile-'feature_access'-'updated_at')||'{"public_phone":"123456789"}',profile->>'updated_at'));
 perform pg_temp.ok('TA operational config save after handover',r->>'state'='00000');
 perform pg_temp.ok('stale readiness does not revoke admin',(select role='admin'and status='active'from public.tenant_memberships where tenant_id=c and user_id=x));
 perform pg_temp.ok('historic replay survives operational change',pg_temp.handover_write(pa,c,x,rev,k)->'value'=receipt);
 perform pg_temp.ok('last admin suspension prevented',pg_temp.rpc(pa,format('select public.platform_suspend_tenant_admin_v1(%L,%L,%L::jsonb,%L)',c,x,'{"role":"admin","status":"active"}',gen_random_uuid()))->>'state'='23514');
 perform pg_temp.ok('PA adds further admin without initial-readiness gate',pg_temp.rpc(pa,format('select public.platform_add_tenant_admin_v1(%L,%L,null,%L)',c,y,gen_random_uuid()))->>'state'='00000');
 perform pg_temp.ok('PA can suspend with other admin',pg_temp.rpc(pa,format('select public.platform_suspend_tenant_admin_v1(%L,%L,%L::jsonb,%L)',c,x,'{"role":"admin","status":"active"}',gen_random_uuid()))->>'state'='00000');
 perform pg_temp.ok('PA can recover suspended admin',pg_temp.rpc(pa,format('select public.platform_reactivate_tenant_admin_v1(%L,%L,%L::jsonb,%L)',c,x,'{"role":"admin","status":"suspended"}',gen_random_uuid()))->>'state'='00000');
 perform pg_temp.ok('PA plan inspection retained',pg_temp.rpc(pa,format('select public.platform_get_tenant_plan_change_preview_v1(%L,%L)',c,'booking_only_v1'))->>'state'='00000');
 perform pg_temp.ok('PA public access inspection retained',pg_temp.rpc(pa,format('select public.platform_get_tenant_public_access_v1(%L)',c))->'value'->>'state'='coming_soon');
 perform pg_temp.ok('PA private preview retained',pg_temp.rpc(pa,format('select public.platform_preview_tenant_v1(%L)',c))->>'state'='00000');
 perform pg_temp.ok('public directory blocked',not exists(select 1 from public.get_public_tenant_directory_v2(null)where public_slug=slug||'-public'));
 foreach actor in array array[null::uuid,customer]loop
  perform pg_temp.ok('public booking blocked after handover',pg_temp.rpc(actor,format('select to_jsonb(count(*))from public.get_public_booking_configuration_v2(%L)',c))->>'state'<>'00000');
  perform pg_temp.ok('public events blocked after handover',pg_temp.rpc(actor,format('select to_jsonb(count(*))from public.get_public_event_list_v3(%L)',c))->>'state'<>'00000');
 end loop;
 perform pg_temp.ok('A/B unchanged',(select md5(jsonb_build_object('tenants',(select jsonb_agg(to_jsonb(t)order by id)from public.tenants t where id in(a,b)),'memberships',(select jsonb_agg(to_jsonb(m)order by tenant_id,user_id)from public.tenant_memberships m where tenant_id in(a,b)))::text)=baseline));
 perform pg_temp.ok('only selected tenant handover',(select count(*)=1 and bool_and(tenant_id=c)from app_private.tenant_handovers));
end;$$;
select 'ok '||n||' - '||label from results order by n;
select '1..'||count(*)from results;
rollback;
