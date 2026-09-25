-- Operator provisioning only. This migration never provisions a real account.
set lock_timeout='5s';
set statement_timeout='60s';

alter table public.platform_audit_logs alter column tenant_id drop not null;
alter table public.platform_audit_logs alter column actor_user_id drop not null;
alter table public.platform_audit_logs drop constraint platform_audit_logs_action_check;
alter table public.platform_audit_logs add constraint platform_audit_logs_action_check
 check (action in ('tenant_created','plan_assigned','plan_changed','tenant_admin_assigned',
 'tenant_activated','tenant_suspended','tenant_published','tenant_unpublished','platform_admin_bootstrapped'));
alter table public.platform_audit_logs add constraint platform_audit_scope_check check (
 (action='platform_admin_bootstrapped' and tenant_id is null and actor_user_id is null
  and jsonb_typeof(details)='object'
  -- Account-wide redaction replaces UUIDs with the existing retained pseudonym.
  and coalesce(details->>'user_id','') ~ '^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|deleted-user-[0-9a-f]{16})$'
  and coalesce(details->>'provisioning_role','')='postgres'
  and length(coalesce(details->>'session_role',''))>0)
 or (action<>'platform_admin_bootstrapped' and tenant_id is not null and actor_user_id is not null)
 );
create unique index platform_admin_bootstrap_audit_target_key
 on public.platform_audit_logs ((details->>'user_id')) where action='platform_admin_bootstrapped';

create function public.operator_bootstrap_platform_admin_v1(p_user_id uuid)
returns text language plpgsql security invoker
set search_path=pg_catalog,public,pg_temp
as $$
declare target auth.users%rowtype; existing_status text;
begin
 -- Never trust JWT role/profile/membership or an operator identity from arguments.
 if current_user<>'postgres' or auth.uid() is not null then
  raise exception 'Operator provisioning required' using errcode='42501';
 end if;
 if p_user_id is null then raise exception 'Eligible account required' using errcode='22023'; end if;
 -- Serializes provisioning and concurrent auth-account updates for this UUID.
 select * into target from auth.users where id=p_user_id for update;
 if not found or target.deleted_at is not null or target.email_confirmed_at is null
  or coalesce(target.is_anonymous,true) or target.banned_until>now() then
  raise exception 'Eligible account required' using errcode='22023';
 end if;
 select status into existing_status from public.platform_admins where user_id=p_user_id for update;
 if found then
  if existing_status<>'active' then raise exception 'Provisioning state conflict' using errcode='55000'; end if;
  if (select count(*) from public.platform_audit_logs where action='platform_admin_bootstrapped'
      and details->>'user_id'=p_user_id::text)<>1 then
   raise exception 'Provisioning audit missing' using errcode='55000';
  end if;
  return 'already_assigned';
 end if;
 insert into public.platform_admins(user_id,status) values(p_user_id,'active');
 insert into public.platform_audit_logs(actor_user_id,tenant_id,action,details)
 values(null,null,'platform_admin_bootstrapped',jsonb_build_object(
 'user_id',p_user_id,'provisioning_role',current_user,'session_role',session_user));
 return 'assigned';
end;
$$;
alter function public.operator_bootstrap_platform_admin_v1(uuid) owner to postgres;
revoke all on function public.operator_bootstrap_platform_admin_v1(uuid) from public,anon,authenticated,service_role;
comment on function public.operator_bootstrap_platform_admin_v1(uuid) is
 'Explicit operator-approved exact UUID provisioning. Execute as postgres without a user JWT. Never expose through application UI. Assignment and global audit are atomic.';
