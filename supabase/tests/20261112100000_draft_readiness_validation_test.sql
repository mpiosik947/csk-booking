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

do $$
declare pa uuid:=gen_random_uuid(); pa2 uuid:=gen_random_uuid(); ta uuid:=gen_random_uuid(); emp uuid:=gen_random_uuid(); inst uuid:=gen_random_uuid(); customer uuid:=gen_random_uuid();
 actor uuid; a uuid; b uuid; c uuid; d uuid; root uuid; foreign_root uuid; k uuid:=gen_random_uuid(); slug text:='nt2b-'||left(replace(gen_random_uuid()::text,'-',''),12);
 r jsonb; current_config jsonb; receipt jsonb; snapshot jsonb; payload jsonb; family jsonb; resources jsonb; version bigint; rev text; baseline text; relation text;
proof jsonb; old_proof jsonb; entry jsonb; before_epoch bigint; audit_count bigint; check_value boolean;
begin
 insert into auth.users(id,email,email_confirmed_at,is_anonymous) select x,x||'@example.invalid',now(),false from unnest(array[pa,pa2,ta,emp,inst,customer]) x;
 insert into public.platform_admins(user_id,status) values(pa,'active'),(pa2,'active');
 -- Historical pre-handover tenant fixture; all tested RPCs remain real.
 a:=gen_random_uuid();
 insert into public.tenants(id,name,slug,status) values(a,'A',slug||'-a','dormant');
 insert into public.tenant_public_profiles(tenant_id,display_name,city,public_slug,is_public,show_booking,show_pricing,show_instructor,show_events,show_about,show_contact,show_regulations) values(a,'A','City',slug||'-a-public',false,false,false,false,false,false,false,false);
 -- Historical pre-handover tenant fixture; all tested RPCs remain real.
 b:=gen_random_uuid();
 insert into public.tenants(id,name,slug,status) values(b,'B',slug||'-b','dormant');
 insert into public.tenant_public_profiles(tenant_id,display_name,city,public_slug,is_public,show_booking,show_pricing,show_instructor,show_events,show_about,show_contact,show_regulations) values(b,'B','City',slug||'-b-public',false,false,false,false,false,false,false,false);
 insert into public.tenant_memberships(tenant_id,user_id,role,status) values(a,ta,'admin','active'),(a,emp,'employee','active'),(a,inst,'instructor','active'),(a,customer,'user','active'),(b,ta,'admin','active');
 select md5(jsonb_agg(to_jsonb(t) order by id)::text) into baseline from public.tenants t where id in(a,b);
 c:=(pg_temp.rpc(pa,format('select public.platform_create_tenant_draft_v1(%L,%L,%L,%L,null,%L)','C',slug,slug||'-public','City',gen_random_uuid()))->'value'->>'tenant_id')::uuid;
 d:=(pg_temp.rpc(pa,format('select public.platform_create_tenant_draft_v1(%L,%L,%L,%L,null,%L)','D',slug||'-d',slug||'-d-public','City',gen_random_uuid()))->'value'->>'tenant_id')::uuid;
 perform pg_temp.ok('created safe C',pg_temp.safe(c));
 r:=pg_temp.validate(pa,c);perform pg_temp.ok('initial missing plan and booking FAIL',r->>'state'='00000' and r->'value'->>'overall'='FAIL');
 perform pg_temp.ok('failed validation creates no proof',not exists(select 1 from app_private.draft_readiness_validations where tenant_id=c));
 perform pg_temp.ok('failed event recorded',exists(select 1 from public.platform_audit_logs where tenant_id=c and action='readiness_validation_failed'));
 current_config:=pg_temp.config(pa,c)->'value';rev:=current_config->>'revision';
 perform pg_temp.ok('PA read without membership',rev~'^[a-f0-9]{64}$' and current_config->>'memberships'='0');
 foreach actor in array array[ta,emp,inst,customer,null::uuid] loop
  perform pg_temp.ok('non PA read denied',pg_temp.config(actor,c)->>'state'='42501');
  perform pg_temp.ok('non PA write denied',pg_temp.save(actor,c,'identity','{"name":"Forged","display_name":"Forged","city":"City"}',rev)->>'state'='42501');
 end loop;
 update public.profiles set role='admin' where user_id=ta;
 perform pg_temp.ok('profiles role does not confer PA',pg_temp.config(ta,c)->>'state'='42501');
 update public.platform_admins set status='suspended' where user_id=pa2;
 perform pg_temp.ok('suspended PA denied',pg_temp.config(pa2,c)->>'state'='42501');
 delete from public.platform_admins where user_id=pa2;
 perform pg_temp.ok('removed PA denied',pg_temp.config(pa2,c)->>'state'='42501');
 insert into public.platform_admins(user_id,status)values(pa2,'active');
 perform pg_temp.ok('legacy A unavailable to draft flow',pg_temp.config(pa,a)->>'state'='42501');
 perform pg_temp.ok('legacy B cannot be written',pg_temp.save(pa,b,'identity','{"name":"Forged","display_name":"Forged","city":"City"}',rev)->>'state'='42501');
 payload:='{"name":"Tenant C configured","display_name":"C public","city":"Testowo"}';
 r:=pg_temp.save(pa,c,'identity',payload,rev,k);
 perform pg_temp.ok('identity save '||r::text,r->>'state'='00000');receipt:=r->'value';
 perform pg_temp.ok('identical retry same receipt',pg_temp.save(pa,c,'identity',payload,rev,k)->'value'=receipt);
 perform pg_temp.ok('changed retry payload denied',pg_temp.save(pa,c,'identity',payload||'{"name":"Different"}',rev,k)->>'state'='22023');
 perform pg_temp.ok('stale revision denied',pg_temp.save(pa,c,'identity',payload,rev)->>'state'='PT409');
 perform pg_temp.ok('foreign draft revision denied',pg_temp.save(pa,c,'identity',payload,pg_temp.config(pa,d)->'value'->>'revision')->>'state'='PT409');
 perform pg_temp.ok('identity safe',pg_temp.safe(c));
 r:=pg_temp.save(pa,c,'profile','{"logo_path":"/next.svg","hero_image_path":"/vercel.svg"}');
 perform pg_temp.ok('branding save '||r::text,r->>'state'='00000');perform pg_temp.ok('branding safe',pg_temp.safe(c));
 perform pg_temp.ok('unsafe remote branding denied',pg_temp.save(pa,c,'profile','{"logo_path":"https://other.invalid/logo.png"}')->>'state'='23514');
 perform pg_temp.ok('path traversal denied',pg_temp.save(pa,c,'profile','{"logo_path":"/a/../secret.png"}')->>'state'='23514');
 r:=pg_temp.save(pa,c,'profile','{"public_address":"Public range address","public_phone":"123456789","public_email":"range@example.invalid","public_map_url":"https://maps.example.invalid/range","opening_hours":"09:00–18:00","social_links":{"facebook":"https://example.invalid/range"}}');
 perform pg_temp.ok('contact hours save '||r::text,r->>'state'='00000');perform pg_temp.ok('contact safe',pg_temp.safe(c));
 perform pg_temp.ok('publication payload denied',pg_temp.save(pa,c,'profile','{"is_public":true}')->>'state'='22023');
 perform pg_temp.ok('forged tenant selector denied',pg_temp.save(pa,c,'profile',jsonb_build_object('tenant_id',b))->>'state'='22023');
 family:='{"root":{"name":"C axis","is_active":true,"max_shooters":2,"whole_lane_bookable":false,"positions_bookable":false,"online_bookable":false,"max_people_online":2,"booking_step_minutes":60,"durations_minutes":[60],"pricing":[{"day_group":"mon_thu","min_shooters":1,"max_shooters":2,"label":"Initial price","hourly_price":10},{"day_group":"fri_sun","min_shooters":1,"max_shooters":2,"label":"Initial price","hourly_price":10}]},"positions":[{"name":"C position","is_active":false,"max_shooters":1,"online_bookable":false,"max_people_online":1,"booking_step_minutes":60,"durations_minutes":[60],"pricing":[{"day_group":"mon_thu","min_shooters":1,"max_shooters":1,"label":"Initial price","hourly_price":10},{"day_group":"fri_sun","min_shooters":1,"max_shooters":1,"label":"Initial price","hourly_price":10}]}]}';
 rev:=pg_temp.config(pa,c)->'value'->>'revision';k:=gen_random_uuid();r:=pg_temp.save(pa,c,'create_lane',family,rev,k);
 perform pg_temp.ok('partial lane family save '||r::text,r->>'state'='00000');root:=(r->'value'->'mutation'->>'root_lane_id')::uuid;receipt:=r->'value';
 perform pg_temp.ok('lane create lost response replay',pg_temp.save(pa,c,'create_lane',family,rev,k)->'value'=receipt);
 perform pg_temp.ok('no duplicated resources',(select count(*)=2 from public.shooting_lanes where tenant_id=c));perform pg_temp.ok('lanes safe',pg_temp.safe(c));
 current_config:=pg_temp.config(pa,c)->'value';
 select jsonb_agg(jsonb_build_object('lane_id',resource_row->'lane_id','name',resource_row->'name','is_active',true,'whole_lane_bookable',resource_row->>'resource_kind'='lane','positions_bookable',resource_row->>'resource_kind'='lane','max_shooters',(resource_row->>'max_shooters')::int,'online_bookable',true,'max_people_online',(resource_row->>'max_people_online')::int,'durations_minutes',jsonb_build_array(60),'pricing',jsonb_build_array(jsonb_build_object('day_group','mon_thu','min_shooters',1,'max_shooters',(resource_row->>'max_people_online')::int,'label','C price','hourly_price',30),jsonb_build_object('day_group','fri_sun','min_shooters',1,'max_shooters',(resource_row->>'max_people_online')::int,'label','C price','hourly_price',40)))) into resources from jsonb_array_elements(current_config->'lanes'->'families'->0->'resources') resource_row;
 payload:=jsonb_build_object('root_lane_id',root,'expected_version',1,'resources',resources);rev:=current_config->>'revision';k:=gen_random_uuid();r:=pg_temp.save(pa,c,'update_lane',payload,rev,k);
 perform pg_temp.ok('booking and pricing save '||r::text,r->>'state'='00000');receipt:=r->'value';
 perform pg_temp.ok('lane update retry stable',pg_temp.save(pa,c,'update_lane',payload,rev,k)->'value'=receipt);perform pg_temp.ok('booking safe',pg_temp.safe(c));
 perform pg_temp.ok('family stale conflict',pg_temp.save(pa,c,'update_lane',payload)->>'state'='PT409');
 r:=pg_temp.save(pa,d,'create_lane',family);foreign_root:=(r->'value'->'mutation'->>'root_lane_id')::uuid;
 perform pg_temp.ok('foreign root denied',pg_temp.save(pa,c,'update_lane',payload||jsonb_build_object('root_lane_id',foreign_root))->>'state'='42501');
 rev:=pg_temp.config(pa,c)->'value'->>'revision';k:=gen_random_uuid();payload:='{"pricing_items":[{"id":null,"title":"Training","price":100,"currency":"PLN","unit":"godzina","short_description":null,"display_order":0,"is_active":true}]}';r:=pg_temp.save(pa,c,'pricing',payload,rev,k);
 perform pg_temp.ok('public pricing save '||r::text,r->>'state'='00000');receipt:=r->'value';
 perform pg_temp.ok('pricing lost response retry',pg_temp.save(pa,c,'pricing',payload,rev,k)->'value'=receipt);
 perform pg_temp.ok('one public price',(select count(*)=1 from public.tenant_public_pricing_items where tenant_id=c));perform pg_temp.ok('pricing safe',pg_temp.safe(c));
 r:=pg_temp.save(pa,c,'profile','{"description":"Draft description","about_offer":"Offer","about_audience":"Adults","regulations_path":"/terms","show_booking":true,"show_events":true,"show_pricing":true,"show_about":true,"show_contact":true}');
 perform pg_temp.ok('public content save '||r::text,r->>'state'='00000');perform pg_temp.ok('content safe',pg_temp.safe(c));
 r:=pg_temp.save(pa,c,'plan','{"plan_key":"current_full_v1"}');perform pg_temp.ok('plan save '||r::text,r->>'state'='00000');perform pg_temp.ok('plan safe',pg_temp.safe(c));
 current_config:=pg_temp.config(pa,c)->'value';
 perform pg_temp.ok('saved profile persisted',current_config->'profile'->>'display_name'='C public' and current_config->'profile'->>'about_offer'='Offer' and current_config->'profile'->>'public_email'='range@example.invalid');
 r:=pg_temp.validate(pa,c);perform pg_temp.ok('complete configuration validates '||r::text,r->>'state'='00000' and r->'value'->>'state'='VALIDATED');proof:=r->'value';
 perform pg_temp.ok('server revision proof exact',proof->>'current_revision'=proof->>'last_validated_revision' and (proof->>'validation_current')::boolean);
 perform pg_temp.ok('optional partners warning only',proof->>'overall'='PASS' and exists(select 1 from jsonb_array_elements(proof->'warnings') x where x->>'key'='partners'));
 perform pg_temp.ok('future handover predicate true',pg_temp.handover(pa,c));
 perform pg_temp.ok('validation remains private zero members',pg_temp.safe(c));
 select count(*) into audit_count from public.platform_audit_logs where tenant_id=c;
 perform pg_temp.ok('retry same exact authoritative result',pg_temp.validate(pa2,c)->'value'=proof);
 perform pg_temp.ok('retry does not duplicate audit',(select count(*)=audit_count from public.platform_audit_logs where tenant_id=c));
 perform pg_temp.ok('server actor time recorded',proof->>'validated_by'=pa::text and proof->>'validated_at' is not null);
 foreach actor in array array[ta,emp,inst,customer,null::uuid] loop
  perform pg_temp.ok('non PA readiness denied',pg_temp.readiness(actor,c)->>'state'='42501');
  perform pg_temp.ok('non PA validation denied',pg_temp.validate(actor,c,proof->>'current_revision')->>'state'='42501');
  perform pg_temp.ok('proof insert denied',pg_temp.rpc(actor,format('insert into app_private.draft_readiness_validations(tenant_id,configuration_revision,validation_version,checks)values(%L,%L,1,%L) returning to_jsonb(tenant_id)',d,proof->>'current_revision','[]'))->>'state'='42501');
  perform pg_temp.ok('proof update denied',pg_temp.rpc(actor,format('update app_private.draft_readiness_validations set configuration_revision=%L where tenant_id=%L returning to_jsonb(tenant_id)',proof->>'current_revision',c))->>'state'='42501');
 end loop;
 perform pg_temp.ok('PA cannot forge proof directly',pg_temp.rpc(pa,format('update app_private.draft_readiness_validations set configuration_revision=%L where tenant_id=%L returning to_jsonb(tenant_id)',repeat('0',64),c))->>'state'='42501');
 perform pg_temp.ok('private predicate not client executable',pg_temp.rpc(pa,format('select to_jsonb(app_private.is_tenant_ready_for_handover_v1(%L))',c))->>'state'='42501');
 update public.platform_admins set status='suspended' where user_id=pa2;
 perform pg_temp.ok('suspended PA validation denied',pg_temp.validate(pa2,c,proof->>'current_revision')->>'state'='42501');
 delete from public.platform_admins where user_id=pa2;
 perform pg_temp.ok('removed PA validation denied',pg_temp.validate(pa2,c,proof->>'current_revision')->>'state'='42501');
 insert into public.platform_admins(user_id,status)values(pa2,'active');
 perform pg_temp.ok('profiles role spoof still denied',pg_temp.validate(ta,c,proof->>'current_revision')->>'state'='42501');
 perform pg_temp.ok('legacy tenant denied',pg_temp.validate(pa,a,proof->>'current_revision')->>'state'='42501');
 perform pg_temp.ok('random tenant denied',pg_temp.validate(pa,gen_random_uuid(),proof->>'current_revision')->>'state'='42501');
 perform pg_temp.ok('cross draft revision denied',pg_temp.validate(pa,d,proof->>'current_revision')->>'state'='PT409');
 perform pg_temp.ok('forged revision denied',pg_temp.validate(pa,c,repeat('0',64))->>'state'='PT409');
 perform pg_temp.ok('invalid revision denied',pg_temp.validate(pa,c,'PASS')->>'state'='22023');
 k:=gen_random_uuid();
 insert into app_private.tenant_partner_media(id,tenant_id,actor_user_id,width,height,byte_size,sha256)values(k,c,pa,100,100,100,repeat('a',64));
 insert into public.tenant_partners(id,tenant_id,name,kind,display_format,media_id,is_active,display_order)values(k,c,'Optional synthetic partner','partner','logo',k,true,0);
 perform pg_temp.ok('partner configuration invalidates',not pg_temp.handover(pa,c));
 delete from public.tenant_partners where id=k;delete from app_private.tenant_partner_media where id=k;
 perform pg_temp.ok('partner revert cannot revive proof',not pg_temp.handover(pa,c));
 perform pg_temp.ok('optional partner removed revalidation',pg_temp.validate(pa,c)->'value'->>'state'='VALIDATED');
 -- Every 2B section changes the revision and makes historical evidence unusable.
 for entry in select value from jsonb_array_elements('[
 {"section":"identity","payload":{"name":"C revised","display_name":"C revised","city":"Testowo"}},
 {"section":"profile","payload":{"logo_path":"/vercel.svg"}},
 {"section":"profile","payload":{"public_phone":"987654321"}},
 {"section":"profile","payload":{"opening_hours":"10:00–19:00"}},
 {"section":"profile","payload":{"description":"Revised public description"}},
 {"section":"pricing","payload":{"pricing_items":[{"id":null,"title":"New training","price":150,"currency":"PLN","unit":"godzina","short_description":null,"display_order":0,"is_active":true}]}},
 {"section":"plan","payload":{"plan_key":"booking_only_v1"}}
 ]'::jsonb) loop
  if entry->>'section'='pricing' then entry:=jsonb_set(entry,'{payload,pricing_items,0,id}',to_jsonb((select id from public.tenant_public_pricing_items where tenant_id=c limit 1)));end if;
  old_proof:=pg_temp.readiness(pa,c)->'value';r:=pg_temp.save(pa,c,entry->>'section',entry->'payload');
  perform pg_temp.ok('material writer succeeds '||entry::text||' '||r::text,r->>'state'='00000');
  proof:=pg_temp.readiness(pa,c)->'value';
  perform pg_temp.ok('writer invalidates '||entry::text,proof->>'current_revision'<>old_proof->>'current_revision' and (proof->>'stale')::boolean and not (proof->>'validation_current')::boolean and not pg_temp.handover(pa,c));
  perform pg_temp.ok('stale validation token rejected',pg_temp.validate(pa,c,old_proof->>'current_revision')->>'state'='PT409');
  perform pg_temp.ok('revalidate material writer',pg_temp.validate(pa,c)->'value'->>'state'='VALIDATED');
 end loop;
 proof:=pg_temp.readiness(pa,c)->'value';
 perform pg_temp.save(pa,c,'identity','{"name":"Temporary","display_name":"C revised","city":"Testowo"}');
 perform pg_temp.save(pa,c,'identity','{"name":"C revised","display_name":"C revised","city":"Testowo"}');
 perform pg_temp.ok('ABA cannot revive old proof',pg_temp.readiness(pa,c)->'value'->>'current_revision'<>proof->>'current_revision' and not pg_temp.handover(pa,c));
 perform pg_temp.ok('ABA revalidate',pg_temp.validate(pa,c)->'value'->>'state'='VALIDATED');
 -- Direct material-table writers are covered too. Every mutation is reverted after checking,
 -- and that revert itself must not revive the historical validation.
 for relation in select unnest(array['lane_name','lane_price','duration','booking_rule','public_price','feature','feature_status','plan']) loop
  proof:=pg_temp.readiness(pa,c)->'value';
  perform set_config('app.product10d_test_enforce','off',true);
  case relation
   when 'lane_name' then update public.shooting_lanes set name=name||' edited' where id=root;
   when 'lane_price' then update public.lane_pricing_rules set hourly_price=hourly_price+1 where lane_id=root;
   when 'duration' then update public.lane_booking_durations set duration_minutes=120 where lane_id=root;
   when 'booking_rule' then update public.lane_booking_rules set max_people_online=1 where lane_id=root;
   when 'public_price' then update public.tenant_public_pricing_items set price=price+1 where tenant_id=c;
   when 'feature' then delete from public.saas_plan_features where plan_id=(select plan_id from public.tenant_plan_assignments where tenant_id=c) and feature_key='booking';
   when 'feature_status' then update public.saas_features set active=false where feature_key='booking';
   when 'plan' then update public.saas_plans set status='inactive' where id=(select plan_id from public.tenant_plan_assignments where tenant_id=c);
  end case;
  perform pg_temp.ok('hidden writer stale '||relation,coalesce((pg_temp.readiness(pa,c)->'value'->>'stale')::boolean,false) and not pg_temp.handover(pa,c));
  case relation
   when 'lane_name' then update public.shooting_lanes set name=replace(name,' edited','') where id=root;
   when 'lane_price' then update public.lane_pricing_rules set hourly_price=hourly_price-1 where lane_id=root;
   when 'duration' then update public.lane_booking_durations set duration_minutes=60 where lane_id=root;
   when 'booking_rule' then update public.lane_booking_rules set max_people_online=2 where lane_id=root;
   when 'public_price' then update public.tenant_public_pricing_items set price=price-1 where tenant_id=c;
   when 'feature' then insert into public.saas_plan_features(plan_id,feature_key) select plan_id,'booking' from public.tenant_plan_assignments where tenant_id=c;
   when 'feature_status' then update public.saas_features set active=true where feature_key='booking';
   when 'plan' then update public.saas_plans set status='active' where id=(select plan_id from public.tenant_plan_assignments where tenant_id=c);
  end case;
  perform set_config('app.product10d_test_enforce','on',true);
  perform pg_temp.ok('hidden writer revert remains stale '||relation,not pg_temp.handover(pa,c));
  perform pg_temp.ok('hidden writer revalidate '||relation,pg_temp.validate(pa,c)->'value'->>'state'='VALIDATED');
 end loop;
 begin
  insert into public.tenant_memberships(tenant_id,user_id,role,status)values(c,customer,'user','active');
  raise exception 'membership unexpectedly allowed';
 exception when sqlstate '55000' then perform pg_temp.ok('existing guard forbids draft membership',true);end;
 proof:=pg_temp.readiness(pa,c)->'value';
 update public.tenant_public_profiles set updated_at=clock_timestamp() where tenant_id=c;
 perform set_config('app.product10d_test_enforce','off',true);
 update public.shooting_lanes set name=name where tenant_id=c;
 perform set_config('app.product10d_test_enforce','on',true);
 perform pg_temp.save(pa,c,'profile','{"description":"Revised public description"}');
 perform pg_temp.ok('no-op bookkeeping and audit do not invalidate',pg_temp.readiness(pa,c)->'value'->>'current_revision'=proof->>'current_revision' and pg_temp.handover(pa,c));
 -- Real 2B lane-family creation and update are material, including lane structure/prices/booking.
 r:=pg_temp.save(pa,c,'create_lane',family);perform pg_temp.ok('2B create lane invalidates',r->>'state'='00000' and not pg_temp.handover(pa,c));
 perform pg_temp.ok('inactive additional family does not block',pg_temp.validate(pa,c)->'value'->>'state'='VALIDATED');
 current_config:=pg_temp.config(pa,c)->'value';
 select jsonb_agg(jsonb_build_object('lane_id',x->'lane_id','name',x->'name','is_active',x->'is_active','whole_lane_bookable',x->'whole_lane_bookable','positions_bookable',x->'positions_bookable','max_shooters',x->'max_shooters','online_bookable',x->'online_bookable','max_people_online',x->'max_people_online','durations_minutes',jsonb_build_array(60,120),'pricing',jsonb_build_array(jsonb_build_object('day_group','mon_thu','min_shooters',1,'max_shooters',(x->>'max_people_online')::int,'label','Price','hourly_price',30),jsonb_build_object('day_group','fri_sun','min_shooters',1,'max_shooters',(x->>'max_people_online')::int,'label','Price','hourly_price',40)))) into resources from jsonb_array_elements((select f from jsonb_array_elements(current_config->'lanes'->'families') f where f->>'root_lane_id'=root::text)->'resources') x;
 select (f->>'configuration_version')::bigint into version from jsonb_array_elements(current_config->'lanes'->'families') f where f->>'root_lane_id'=root::text;
 r:=pg_temp.save(pa,c,'update_lane',jsonb_build_object('root_lane_id',root,'expected_version',version,'resources',resources));
 perform pg_temp.ok('2B update lane invalidates '||r::text,r->>'state'='00000' and not pg_temp.handover(pa,c));
 perform pg_temp.ok('2B booking update revalidate',pg_temp.validate(pa,c)->'value'->>'state'='VALIDATED');
 -- Missing sellable pricing fails without replacing the last positive proof.
 select to_jsonb(v) into old_proof from app_private.draft_readiness_validations v where tenant_id=c;
 select jsonb_agg(id) into payload from public.lane_pricing_rules where is_active and lane_id in(select id from public.shooting_lanes where tenant_id=c);
 update public.lane_pricing_rules set is_active=false where lane_id in(select id from public.shooting_lanes where tenant_id=c);
 r:=pg_temp.validate(pa,c);perform pg_temp.ok('broken sellable pricing FAIL',r->>'state'='00000' and r->'value'->>'overall'='FAIL' and not pg_temp.handover(pa,c));
 perform pg_temp.ok('failed validation preserves historical proof only',(select to_jsonb(v)=old_proof from app_private.draft_readiness_validations v where tenant_id=c));
 update public.lane_pricing_rules set is_active=true where id in(select value::uuid from jsonb_array_elements_text(payload));
 create trigger reject_readiness_audit before insert on public.platform_audit_logs for each row execute function pg_temp.fail_readiness_audit();
 r:=pg_temp.validate(pa,c);perform pg_temp.ok('audit failure rolls back proof',r->>'state'='P0001' and not pg_temp.handover(pa,c));
 drop trigger reject_readiness_audit on public.platform_audit_logs;
 perform pg_temp.ok('audit recovery validates',pg_temp.validate(pa,c)->'value'->>'state'='VALIDATED');
 r:=pg_temp.rpc(pa,format('select public.platform_archive_tenant_v1(%L,%L,%L)',c,pg_temp.config(pa,c)->'value'->>'lifecycle_revision',gen_random_uuid()));
 perform pg_temp.ok('archive succeeds '||r::text,r->>'state'='00000');
 perform pg_temp.ok('archive forbids validation',pg_temp.validate(pa,c,repeat('0',64))->>'state'='42501' and not pg_temp.handover(pa,c));
 r:=pg_temp.rpc(pa,format('select public.platform_restore_archived_tenant_v1(%L,%L,%L)',c,pg_temp.config(pa,c)->'value'->>'lifecycle_revision',gen_random_uuid()));
 perform pg_temp.ok('restore cannot revive proof',r->>'state'='00000' and not pg_temp.handover(pa,c));
 perform pg_temp.ok('restored draft revalidates',pg_temp.validate(pa,c)->'value'->>'state'='VALIDATED');
 perform pg_temp.ok('public directory excludes validated C',not exists(select 1 from public.get_public_tenant_directory_v2(null) where public_slug=slug||'-public'));
 perform pg_temp.ok('validated public booking blocked',pg_temp.rpc(null,format('select to_jsonb(count(*)) from public.get_public_booking_configuration_v2(%L)',c))->>'state'<>'00000');
 perform pg_temp.ok('validated public events blocked',pg_temp.rpc(null,format('select to_jsonb(count(*)) from public.get_public_event_list_v3(%L)',c))->>'state'<>'00000');
 perform pg_temp.ok('validation final safe zero memberships',pg_temp.safe(c));
 perform pg_temp.ok('A and B tenants unchanged',(select md5(jsonb_agg(to_jsonb(t) order by id)::text)=baseline from public.tenants t where id in(a,b)));
 perform pg_temp.ok('no A/B readiness writes',not exists(select 1 from app_private.draft_readiness_validations where tenant_id in(a,b)) and not exists(select 1 from app_private.draft_configuration_epochs where tenant_id in(a,b)));
 perform pg_temp.ok('all readiness audits real PA and tenant C',not exists(select 1 from public.platform_audit_logs where action like 'readiness_validation_%' and (actor_user_id not in(pa,pa2) or tenant_id<>c)));
end;$$;
select 'ok '||n||' - '||label from results order by n;
select '1..'||count(*) from results;
rollback;
