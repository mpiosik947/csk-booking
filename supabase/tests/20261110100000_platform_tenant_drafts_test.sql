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
create function pg_temp.draft(actor uuid,key uuid,slug text,plan text default null) returns jsonb language sql as $$
select pg_temp.rpc(actor,format('select public.platform_create_tenant_draft_v1(%L,%L,%L,%L,%L,%L)','Tenant C',slug,slug||'-public','City',plan,key));$$;
create function pg_temp.fail_audit() returns trigger language plpgsql as $$begin if new.action='tenant_created' then raise exception 'injected audit failure'; end if; return new; end;$$;
do $$
declare pa uuid:=gen_random_uuid(); ta uuid:=gen_random_uuid(); emp uuid:=gen_random_uuid(); inst uuid:=gen_random_uuid(); customer uuid:=gen_random_uuid();
 actor uuid; a uuid; b uuid; c uuid; d uuid; k uuid:=gen_random_uuid(); slug text:='nt2a-'||left(replace(gen_random_uuid()::text,'-',''),12);
 r jsonb; first_receipt jsonb; rev bigint; before_count bigint; baseline text; rel text;
begin
 insert into auth.users(id,email,email_confirmed_at,is_anonymous) select x,x||'@example.invalid',now(),false from unnest(array[pa,ta,emp,inst,customer]) x;
 insert into public.profiles(id,user_id,email,role) select id,id,email,'user' from auth.users where id=any(array[pa,ta,emp,inst,customer]) on conflict(user_id) do nothing;
 insert into public.platform_admins(user_id,status) values(pa,'active');
 -- Historical pre-handover tenant fixture; all tested RPCs remain real.
 a:=gen_random_uuid();
 insert into public.tenants(id,name,slug,status) values(a,'A',slug||'-a','dormant');
 insert into public.tenant_public_profiles(tenant_id,display_name,city,public_slug,is_public,show_booking,show_pricing,show_instructor,show_events,show_about,show_contact,show_regulations) values(a,'A','City',slug||'-a-public',false,false,false,false,false,false,false,false);
 -- Historical pre-handover tenant fixture; all tested RPCs remain real.
 b:=gen_random_uuid();
 insert into public.tenants(id,name,slug,status) values(b,'B',slug||'-b','dormant');
 insert into public.tenant_public_profiles(tenant_id,display_name,city,public_slug,is_public,show_booking,show_pricing,show_instructor,show_events,show_about,show_contact,show_regulations) values(b,'B','City',slug||'-b-public',false,false,false,false,false,false,false,false);
 insert into public.tenant_memberships(tenant_id,user_id,role,status) values(a,ta,'admin','active'),(a,emp,'employee','active'),(a,inst,'instructor','active'),(a,customer,'user','active'),(b,ta,'admin','active');
 select md5(jsonb_agg(to_jsonb(t) order by id)::text) into baseline from public.tenants t;
 foreach actor in array array[ta,emp,inst,customer,null::uuid] loop
  perform pg_temp.ok('role cannot create '||coalesce(actor::text,'anon'),pg_temp.draft(actor,k,slug)->>'state'='42501');
 end loop;
 update public.platform_admins set status='suspended' where user_id=pa;
 perform pg_temp.ok('suspended PA denied',pg_temp.draft(pa,k,slug)->>'state'='42501');
 delete from public.platform_admins where user_id=pa;
 perform pg_temp.ok('removed PA denied',pg_temp.draft(pa,k,slug)->>'state'='42501');
 insert into public.platform_admins(user_id,status) values(pa,'active');
 foreach rel in array array['tenants','tenant_memberships','tenant_public_profiles','platform_admins','platform_tenant_creation_requests','tenant_public_access_controls'] loop
  perform pg_temp.ok('no direct client INSERT '||rel,not has_table_privilege('authenticated','public.'||rel,'INSERT') and not has_table_privilege('anon','public.'||rel,'INSERT'));
 end loop;
 select count(*) into before_count from public.tenants;
 perform pg_temp.ok('invalid plan denied',pg_temp.draft(pa,k,slug,'not_existing')->>'state'='22023');
 perform pg_temp.ok('invalid plan atomic',(select count(*)=before_count from public.tenants));
 perform pg_temp.ok('reserved slug denied',pg_temp.draft(pa,k,'admin')->>'state'='22023');
 perform pg_temp.ok('uppercase denied',pg_temp.draft(pa,k,'Bad-Slug')->>'state'='22023');
 r:=pg_temp.draft(pa,k,slug);perform pg_temp.ok('create PA succeeds',r->>'state'='00000');
 first_receipt:=r->'value';c:=(first_receipt->>'tenant_id')::uuid;
 perform pg_temp.ok('explicit dormant',(select status='dormant' from public.tenants where id=c));
 perform pg_temp.ok('explicit coming soon',(select public_access_state='coming_soon' from public.tenant_public_access_controls where tenant_id=c));
 perform pg_temp.ok('unpublished',(select not is_public and not show_booking and not show_events from public.tenant_public_profiles where tenant_id=c));
 perform pg_temp.ok('zero memberships including creator',(select count(*)=0 from public.tenant_memberships where tenant_id=c));
 perform pg_temp.ok('plan safely optional',not exists(select 1 from public.tenant_plan_assignments where tenant_id=c));
 perform pg_temp.ok('replay exact receipt',pg_temp.draft(pa,k,slug)->'value'=first_receipt);
 perform pg_temp.ok('one creation audit',(select count(*)=1 from public.platform_audit_logs where tenant_id=c and action='tenant_created'));
 perform pg_temp.ok('actor and server timestamp',(select actor_user_id=pa and created_at is not null and details->>'public_access_state'='coming_soon' from public.platform_audit_logs where tenant_id=c and action='tenant_created'));
 perform pg_temp.ok('changed payload conflict',pg_temp.draft(pa,k,slug||'-changed')->>'state'='22023');
 perform pg_temp.ok('same slug new key collision',pg_temp.draft(pa,gen_random_uuid(),slug)->>'state'='23505');
 perform pg_temp.ok('cross namespace collision',pg_temp.draft(pa,gen_random_uuid(),slug||'-public')->>'state'<>'00000');
 perform pg_temp.ok('PA reopens without membership',(pg_temp.rpc(pa,format('select public.platform_get_tenant_onboarding_detail_v1(%L)',c))->'value'->>'is_platform_draft')::boolean);
 perform pg_temp.ok('PA preview',(pg_temp.rpc(pa,format('select public.platform_preview_tenant_v1(%L)',c))->>'state')='00000');
 perform pg_temp.ok('foreign tenant admin cannot inspect',pg_temp.rpc(ta,format('select public.platform_get_tenant_onboarding_detail_v1(%L)',c))->>'state'='42501');
 perform pg_temp.ok('public catalog excludes draft',not exists(select 1 from public.get_public_tenant_directory_v2(null) where public_slug=slug||'-public'));
 foreach actor in array array[null::uuid,customer,pa] loop
  perform pg_temp.ok('dormant booking blocked',pg_temp.rpc(actor,format('select to_jsonb(count(*)) from public.get_public_booking_configuration_v2(%L)',c))->>'state'<>'00000');
  perform pg_temp.ok('dormant public business denied',(pg_temp.rpc(actor,format('select to_jsonb(public.can_access_tenant_public_business_v1(%L))',c))->'value')='false'::jsonb);
 end loop;
 perform pg_temp.ok('legacy initial assignment cannot bypass',pg_temp.rpc(pa,format('select to_jsonb(public.platform_assign_initial_admin_v1(%L,%L))',c,ta))->>'state'='55000');
 perform pg_temp.ok('management assignment cannot bypass',pg_temp.rpc(pa,format('select public.platform_add_tenant_admin_v1(%L,%L,null,%L)',c,ta,gen_random_uuid()))->>'state'='55000');
 perform pg_temp.ok('cannot set live',pg_temp.rpc(pa,format('select public.platform_set_tenant_public_access_v1(%L,%L,%L,%L,%L)',c,'live','coming_soon',(select revision from public.tenant_public_access_controls where tenant_id=c),gen_random_uuid()))->>'state'='55000');
 select lifecycle_revision into rev from public.tenants where id=c;
 perform pg_temp.ok('archive zero admin no plan',pg_temp.rpc(pa,format('select public.platform_archive_tenant_v1(%L,%L,%L)',c,rev,gen_random_uuid()))->>'state'='00000');
 select lifecycle_revision into rev from public.tenants where id=c;
 perform pg_temp.ok('restore zero admin no plan',pg_temp.rpc(pa,format('select public.platform_restore_archived_tenant_v1(%L,%L,%L)',c,rev,gen_random_uuid()))->>'state'='00000');
 perform pg_temp.ok('continue after restore',pg_temp.rpc(pa,format('select public.platform_get_tenant_onboarding_detail_v1(%L)',c))->>'state'='00000');
 perform pg_temp.ok('restore safe state',(select t.status='dormant' and not p.is_public and x.public_access_state='coming_soon' from public.tenants t join public.tenant_public_profiles p on p.tenant_id=t.id join public.tenant_public_access_controls x on x.tenant_id=t.id where t.id=c));
 perform pg_temp.ok('other tenants unchanged',(select md5(jsonb_agg(to_jsonb(t) order by id)::text)=baseline from public.tenants t where id<>c));
 r:=pg_temp.draft(pa,gen_random_uuid(),slug||'-plan','booking_only_v1');d:=(r->'value'->>'tenant_id')::uuid;
 perform pg_temp.ok('selected plan assigned',(select count(*)=1 from public.tenant_plan_assignments where tenant_id=d));
 perform pg_temp.ok('plan draft zero memberships',not exists(select 1 from public.tenant_memberships where tenant_id=d));
 create trigger nt2a_fail before insert on public.platform_audit_logs for each row execute function pg_temp.fail_audit();
 select count(*) into before_count from public.tenants;
 perform pg_temp.ok('injected final audit fails',pg_temp.draft(pa,gen_random_uuid(),slug||'-rollback')->>'state'<>'00000');
 perform pg_temp.ok('rollback leaves no tenant',(select count(*)=before_count from public.tenants));
 drop trigger nt2a_fail on public.platform_audit_logs;
 perform pg_temp.ok('create function ACL',has_function_privilege('authenticated','public.platform_create_tenant_draft_v1(text,text,text,text,text,uuid)','EXECUTE') and not has_function_privilege('anon','public.platform_create_tenant_draft_v1(text,text,text,text,text,uuid)','EXECUTE') and not has_function_privilege('service_role','public.platform_create_tenant_draft_v1(text,text,text,text,text,uuid)','EXECUTE'));
end;$$;
select '1..'||count(*) from results;
select 'ok '||n||' - '||label from results order by n;
rollback;
