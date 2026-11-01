\set ON_ERROR_STOP on
begin;
create temporary table r2_results(n serial,label text) on commit drop;
create function pg_temp.r2_ok(label text,passed boolean) returns void language plpgsql as $$begin
 if passed is distinct from true then raise exception 'FAIL: %',label;end if;insert into r2_results(label)values(label);
end;$$;
create function pg_temp.r2_rpc(actor uuid,statement text) returns jsonb language plpgsql as $$
declare result jsonb;begin
 perform set_config('request.jwt.claim.sub',actor::text,true);perform set_config('request.jwt.claims',jsonb_build_object('sub',actor,'role','authenticated')::text,true);
 set local role authenticated;execute statement into result;reset role;return jsonb_build_object('state','00000','value',result);
exception when others then reset role;return jsonb_build_object('state',sqlstate,'message',sqlerrm);end;$$;
do $$
declare pa uuid:=gen_random_uuid();owner_id uuid:=gen_random_uuid();slug text:='r2-'||replace(gen_random_uuid()::text,'-','');v_tenant_id uuid;dto jsonb;payload jsonb;result jsonb;before_profile jsonb;before_audit bigint;i integer;
begin
 insert into auth.users(id,email,email_confirmed_at,is_anonymous)values(pa,'pa@example.invalid',now(),false),(owner_id,'owner@example.invalid',now(),false);
 insert into public.profiles(id,user_id,email,role)values(pa,pa,'pa@example.invalid','user'),(owner_id,owner_id,'owner@example.invalid','user')on conflict(user_id)do nothing;
 insert into public.platform_admins(user_id,status)values(pa,'active');
 -- Historical pre-handover tenant fixture; all tested RPCs remain real.
 v_tenant_id:=gen_random_uuid();
 insert into public.tenants(id,name,slug,status) values(v_tenant_id,'Synthetic',slug,'dormant');
 insert into public.tenant_public_profiles(tenant_id,display_name,city,public_slug,is_public,show_booking,show_pricing,show_instructor,show_events,show_about,show_contact,show_regulations) values(v_tenant_id,'Synthetic','City','pub-'||slug,false,false,false,false,false,false,false,false);
 insert into public.tenant_plan_assignments(tenant_id,plan_id,status) select v_tenant_id,id,'active' from public.saas_plans where plan_key='current_full_v1';
 insert into public.tenant_memberships(tenant_id,user_id,role,status) values(v_tenant_id,owner_id,'admin','active');
 dto:=pg_temp.r2_rpc(owner_id,format('select public.admin_get_tenant_public_settings_v1(%L)',slug))->'value';payload:=dto-'feature_access'-'updated_at';
 result:=pg_temp.r2_rpc(owner_id,format('select public.admin_update_tenant_public_settings_v1(%L,%L::jsonb,%L::timestamptz)',slug,payload,dto->>'updated_at'));
 perform pg_temp.r2_ok('valid settings save succeeds',result->>'state'='00000');
 perform pg_temp.r2_ok('return DTO unchanged',result->'value'=dto);
 select to_jsonb(p)into before_profile from public.tenant_public_profiles p where p.tenant_id=v_tenant_id;
 select count(*)into before_audit from public.audit_logs a where a.tenant_id=v_tenant_id and action='tenant_public_profile_updated';
 perform pg_temp.r2_ok('successful save audits once',before_audit=1);
 for i in 1..3 loop
  result:=pg_temp.r2_rpc(owner_id,format('select public.admin_update_tenant_public_settings_v1(%L,%L::jsonb,%L::timestamptz)',slug,payload,(dto->>'updated_at')::timestamptz-interval '1 second'));
  perform pg_temp.r2_ok('stale attempt '||i||' returns PT409',result->>'state'='PT409'and result->>'message'='settings_conflict');
 end loop;
 perform pg_temp.r2_ok('stale save changes no fields',before_profile=(select to_jsonb(p)from public.tenant_public_profiles p where p.tenant_id=v_tenant_id));
 perform pg_temp.r2_ok('stale save adds no audit',before_audit=(select count(*)from public.audit_logs a where a.tenant_id=v_tenant_id and action='tenant_public_profile_updated'));
 result:=pg_temp.r2_rpc(pa,format('select public.admin_update_tenant_public_settings_v1(%L,%L::jsonb,%L::timestamptz)',slug,payload,dto->>'updated_at'));
 perform pg_temp.r2_ok('PA without membership remains forbidden',result->>'state'='42501');
 -- NEW-TENANT-2B extracts the same validation engine into an owner-only helper.
 perform pg_temp.r2_ok('TA wrapper delegates to the exact shared settings engine',position('app_private.tenant_public_settings_write_v1' in pg_get_functiondef('public.admin_update_tenant_public_settings_v1(text,jsonb,timestamptz)'::regprocedure))>0);
 perform pg_temp.r2_ok('shared settings engine retains PT409',position('errcode=''PT409'',message=''settings_conflict''' in pg_get_functiondef('app_private.tenant_public_settings_write_v1(uuid,jsonb,timestamptz,text)'::regprocedure))>0);
end;$$;
select '1..'||count(*)from r2_results;
select 'ok '||n||' - '||label from r2_results order by n;
rollback;
