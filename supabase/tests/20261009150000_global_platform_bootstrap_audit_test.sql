\set ON_ERROR_STOP on
select (select count(*) from auth.users)+(select count(*) from public.profiles)+(select count(*) from public.tenants)+(select count(*) from public.tenant_memberships)+(select count(*) from public.platform_admins)+(select count(*) from public.platform_audit_logs)+(select count(*) from public.audit_logs) as before_count
\gset
begin;
create temporary table results(n serial,label text) on commit drop;
create function pg_temp.ok(label text, condition boolean) returns void language plpgsql as $$begin
 if condition is distinct from true then raise exception 'FAIL: %',label; end if;
 insert into results(label) values(label);
end;$$;
create function pg_temp.denied(target uuid) returns boolean language plpgsql as $$begin
 perform public.operator_bootstrap_platform_admin_v1(target); return false;
exception when insufficient_privilege then return true; end;$$;
grant execute on function pg_temp.denied(uuid) to anon,authenticated,service_role;
create function pg_temp.reject_bootstrap_audit() returns trigger language plpgsql as $$begin
 if new.action='platform_admin_bootstrapped' then raise exception 'synthetic audit failure'; end if;
 return new;
end;$$;
do $test$
declare u uuid:=gen_random_uuid(); bad uuid:=gen_random_uuid(); t uuid:=gen_random_uuid();
 r text; s text; baseline_role text; before_memberships bigint;
begin
 insert into auth.users(id,email,email_confirmed_at,is_anonymous) values
 (u,u||'@example.invalid',now(),false),(bad,bad||'@example.invalid',now(),false);
 select role into baseline_role from public.profiles where user_id=u;
 select count(*) into before_memberships from public.tenant_memberships where user_id=u;
 insert into public.tenants(id,name,slug,status) values(t,'Bootstrap test','bootstrap-'||t,'dormant');
 foreach r in array array['anon','authenticated','service_role'] loop
  execute format('set local role %I',r);
  execute 'select pg_temp.denied($1)' into s using u;
  reset role;
  perform pg_temp.ok(r||' direct RPC denied',s::boolean);
 end loop;
 foreach r in array array['admin','employee','user'] loop
  insert into public.tenant_memberships(tenant_id,user_id,role,status) values(t,u,r,'active')
  on conflict(tenant_id,user_id) do update set role=excluded.role;
  perform set_config('request.jwt.claim.sub',u::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',u,'role','authenticated')::text,true);
  set local role authenticated;
  s:=pg_temp.denied(u)::text;
  reset role;
  perform pg_temp.ok('tenant '||r||' denied',s::boolean);
 end loop;
 perform pg_temp.ok('postgres with user JWT denied',pg_temp.denied(u));
 perform set_config('request.jwt.claim.sub','',true); perform set_config('request.jwt.claims','{}',true);
 delete from public.tenant_memberships where tenant_id=t and user_id=u;
 begin perform public.operator_bootstrap_platform_admin_v1(null); raise exception 'accepted null';
 exception when invalid_parameter_value then perform pg_temp.ok('null UUID denied',true); end;
 begin perform public.operator_bootstrap_platform_admin_v1(gen_random_uuid()); raise exception 'accepted missing';
 exception when invalid_parameter_value then perform pg_temp.ok('missing UUID denied',true); end;
 foreach r in array array['deleted','blocked','anonymous','unconfirmed'] loop
  update auth.users set deleted_at=case when r='deleted' then now() end,
   banned_until=case when r='blocked' then now()+interval '1 day' end,
   is_anonymous=(r='anonymous'),email_confirmed_at=case when r<>'unconfirmed' then now() end where id=bad;
  begin perform public.operator_bootstrap_platform_admin_v1(bad); raise exception 'accepted ineligible';
  exception when invalid_parameter_value then perform pg_temp.ok(r||' account denied',true); end;
 end loop;
 update auth.users set deleted_at=null,banned_until=null,is_anonymous=false,email_confirmed_at=now() where id=bad;
 execute 'create trigger reject_bootstrap_audit before insert on public.platform_audit_logs for each row execute function pg_temp.reject_bootstrap_audit()';
 begin perform public.operator_bootstrap_platform_admin_v1(bad); raise exception 'audit trigger failed';
 exception when raise_exception then
  if sqlerrm<>'synthetic audit failure' then raise; end if;
 end;
 perform pg_temp.ok('audit failure rolls authority back',not exists(select 1 from public.platform_admins where user_id=bad));
 perform pg_temp.ok('audit failure leaves no event',not exists(select 1 from public.platform_audit_logs where details->>'user_id'=bad::text));
 execute 'drop trigger reject_bootstrap_audit on public.platform_audit_logs';
 perform pg_temp.ok('operator exact UUID allowed',public.operator_bootstrap_platform_admin_v1(u)='assigned');
 perform pg_temp.ok('authority active',exists(select 1 from public.platform_admins where user_id=u and status='active'));
 perform pg_temp.ok('minimal global audit',exists(select 1 from public.platform_audit_logs where action='platform_admin_bootstrapped'
  and tenant_id is null and actor_user_id is null and created_at is not null
  and details=jsonb_build_object('user_id',u,'provisioning_role','postgres','session_role',session_user)));
 perform pg_temp.ok('repeat no-op',public.operator_bootstrap_platform_admin_v1(u)='already_assigned');
 perform pg_temp.ok('one audit only',(select count(*)=1 from public.platform_audit_logs where details->>'user_id'=u::text));
 perform pg_temp.ok('profile role unchanged',(select role from public.profiles where user_id=u) is not distinct from baseline_role);
 perform pg_temp.ok('membership unchanged',(select count(*) from public.tenant_memberships where user_id=u)=before_memberships);
 update public.platform_admins set status='suspended' where user_id=u;
 begin perform public.operator_bootstrap_platform_admin_v1(u); raise exception 'reactivated suspended';
 exception when object_not_in_prerequisite_state then perform pg_temp.ok('suspended authority requires separate review',true); end;
 foreach r in array array['tenant_created','plan_assigned','plan_changed','tenant_admin_assigned','tenant_activated','tenant_suspended','tenant_published','tenant_unpublished'] loop
  begin insert into public.platform_audit_logs(actor_user_id,tenant_id,action) values(u,null,r); raise exception 'accepted tenantless action';
  exception when check_violation then perform pg_temp.ok(r||' requires tenant',true); end;
  insert into public.platform_audit_logs(actor_user_id,tenant_id,action) values(u,t,r);
 end loop;
 begin insert into public.platform_audit_logs(actor_user_id,tenant_id,action,details)
  values(null,t,'platform_admin_bootstrapped',jsonb_build_object('user_id',bad,'provisioning_role','postgres','session_role',session_user)); raise exception 'accepted fake tenant';
 exception when check_violation then perform pg_temp.ok('global action rejects tenant',true); end;
 begin insert into public.platform_audit_logs(actor_user_id,tenant_id,action) values(null,null,'platform_admin_bootstrapped'); raise exception 'accepted missing identity';
 exception when check_violation then perform pg_temp.ok('global action requires provisioning identity',true); end;
 perform pg_temp.ok('security invoker',not (select prosecdef from pg_proc where oid='public.operator_bootstrap_platform_admin_v1(uuid)'::regprocedure));
 perform pg_temp.ok('no client execute',not has_function_privilege('authenticated','public.operator_bootstrap_platform_admin_v1(uuid)','EXECUTE')
  and not has_function_privilege('anon','public.operator_bootstrap_platform_admin_v1(uuid)','EXECUTE')
  and not has_function_privilege('service_role','public.operator_bootstrap_platform_admin_v1(uuid)','EXECUTE'));
 perform set_config('request.jwt.claim.sub',u::text,true);
 perform set_config('request.jwt.claims',jsonb_build_object('sub',u,'role','authenticated')::text,true);
 perform pg_temp.ok('account anonymization remains compatible',(public.anonymize_my_account_v1()->>'ok')::boolean);
 perform set_config('request.jwt.claim.sub','',true); perform set_config('request.jwt.claims','{}',true);
 perform pg_temp.ok('audit target redacted',not exists(select 1 from public.platform_audit_logs where details->>'user_id'=u::text));
 perform pg_temp.ok('anonymization revokes platform role',not exists(select 1 from public.platform_admins where user_id=u));
end;$test$;
select '1..'||(count(*)+1) from results;
select 'ok '||n||' - '||label from results order by n;
rollback;
select case when (select count(*) from auth.users)+(select count(*) from public.profiles)+(select count(*) from public.tenants)+(select count(*) from public.tenant_memberships)+(select count(*) from public.platform_admins)+(select count(*) from public.platform_audit_logs)+(select count(*) from public.audit_logs)=:before_count then 'ok 39 - fixture cleanup = 0' else 'not ok 39 - fixture cleanup failed' end;
