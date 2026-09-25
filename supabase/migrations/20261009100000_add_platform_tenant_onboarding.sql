-- PRODUCT-10E. No production platform administrator is bootstrapped here.
set lock_timeout = '5s';
set statement_timeout = '60s';

create table public.platform_admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  status text not null check (status in ('active','suspended')),
  created_at timestamptz not null default now()
);
create table public.platform_audit_logs (
  id uuid primary key default gen_random_uuid(),
  actor_user_id uuid not null,
  tenant_id uuid not null references public.tenants(id) on delete restrict,
  action text not null check (action in ('tenant_created','plan_assigned','plan_changed',
    'tenant_admin_assigned','tenant_activated','tenant_suspended','tenant_published','tenant_unpublished')),
  created_at timestamptz not null default now(),
  details jsonb not null default '{}'::jsonb
);
create index platform_audit_logs_tenant_created_idx on public.platform_audit_logs(tenant_id,created_at desc);
alter table public.platform_admins enable row level security;
alter table public.platform_audit_logs enable row level security;
revoke all on public.platform_admins,public.platform_audit_logs from public,anon,authenticated,service_role;

create function public.is_platform_admin_v1()
returns boolean language sql stable security definer
set search_path=pg_catalog,public,pg_temp
as $$select auth.uid() is not null and exists(
 select 1 from public.platform_admins where user_id=auth.uid() and status='active');$$;
revoke all on function public.is_platform_admin_v1() from public,anon,authenticated,service_role;
grant execute on function public.is_platform_admin_v1() to authenticated;

-- One canonical reserved namespace for both selectors. No tenant authority here.
create function public.platform_slug_valid_v1(p_slug text)
returns boolean language sql immutable security invoker
set search_path=pg_catalog,public,pg_temp
as $$select coalesce(length(p_slug) between 2 and 63
 and p_slug=lower(p_slug) and p_slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'
 and p_slug <> all(array['account','admin','api','auth','booking','check-in','dashboard','events',
 'forgot-password','login','my-events','my-reservations','privacy','register','reset-password','t','terms',
 'platform-admin','continuity','tenant-setup']),false);$$;
revoke all on function public.platform_slug_valid_v1(text) from public,anon,authenticated,service_role;

alter table public.tenants add constraint tenants_platform_slug_check
 check(public.platform_slug_valid_v1(slug));
alter table public.tenant_public_profiles drop constraint tenant_public_profiles_public_slug_check;
alter table public.tenant_public_profiles add constraint tenant_public_profiles_public_slug_check
 check(public.platform_slug_valid_v1(public_slug));

create function public.platform_tenant_readiness_core_v1(p_tenant_id uuid)
returns jsonb language sql stable security invoker
set search_path=pg_catalog,public,pg_temp
as $$select jsonb_build_object(
 'identity_ready',length(btrim(t.name))>0,
 'slug_ready',public.platform_slug_valid_v1(t.slug) and public.platform_slug_valid_v1(p.public_slug),
 'settings_ready',p.tenant_id is not null and length(btrim(p.display_name))>0 and length(btrim(p.city))>0,
 'plan_ready',exists(select 1 from public.tenant_plan_assignments a join public.saas_plans s on s.id=a.plan_id
   where a.tenant_id=t.id and a.status='active' and s.status='active'),
 'admin_ready',exists(select 1 from public.tenant_memberships m join auth.users u on u.id=m.user_id
   where m.tenant_id=t.id and m.role='admin' and m.status='active' and u.email_confirmed_at is not null))
 from public.tenants t left join public.tenant_public_profiles p on p.tenant_id=t.id where t.id=p_tenant_id;$$;
revoke all on function public.platform_tenant_readiness_core_v1(uuid) from public,anon,authenticated,service_role;

create function public.platform_list_tenants_v1(p_page integer default 1)
returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,pg_temp
as $$
begin
 if not public.is_platform_admin_v1() then raise exception 'Not authorized' using errcode='42501'; end if;
 if p_page is null or p_page<1 or p_page>100000 then raise exception 'Invalid page' using errcode='22023'; end if;
 return jsonb_build_object('page',p_page,'page_size',25,'total',(select count(*) from public.tenants),
 'items',coalesce((select jsonb_agg(row_data order by created_at,id) from (
 select t.created_at,t.id,jsonb_build_object('id',t.id,'name',p.display_name,'tenant_slug',t.slug,
 'public_slug',p.public_slug,'city',p.city,'status',t.status,'is_public',p.is_public,
 'plan_key',s.plan_key,'created_at',t.created_at,'readiness',public.platform_tenant_readiness_core_v1(t.id)) row_data
 from public.tenants t left join public.tenant_public_profiles p on p.tenant_id=t.id
 left join public.tenant_plan_assignments a on a.tenant_id=t.id
 left join public.saas_plans s on s.id=a.plan_id
 order by t.created_at,t.id limit 25 offset ((p_page::bigint-1)*25)) rows),'[]'::jsonb));
end;$$;

create function public.platform_lookup_initial_admin_v1(p_email text)
returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,pg_temp
as $$
declare result jsonb;
begin
 if not public.is_platform_admin_v1() then raise exception 'Not authorized' using errcode='42501'; end if;
 if p_email is null or length(p_email)>254 or p_email<>btrim(p_email)
 or p_email !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' then
 raise exception 'Exact email required' using errcode='22023'; end if;
 select jsonb_build_object('user_id',id,'email',email) into strict result from auth.users
 where lower(email)=lower(p_email) and email_confirmed_at is not null and deleted_at is null;
 return result;
exception when no_data_found then return null;
 when too_many_rows then raise exception 'Account cannot be selected' using errcode='22023';
end;$$;

create function public.platform_create_tenant_v1(p_name text,p_tenant_slug text,p_public_slug text,p_city text)
returns uuid language plpgsql security definer
set search_path=pg_catalog,public,pg_temp
as $$
declare target uuid;
begin
 if not public.is_platform_admin_v1() then raise exception 'Not authorized' using errcode='42501'; end if;
 if not public.platform_slug_valid_v1(p_tenant_slug) or not public.platform_slug_valid_v1(p_public_slug)
 or p_tenant_slug=p_public_slug or p_name is null or p_city is null
 or length(btrim(p_name)) not between 1 and 120 or length(btrim(p_city)) not between 1 and 120 then
 raise exception 'Invalid tenant identity' using errcode='22023'; end if;
 -- Same lock as the existing cross-table slug namespace trigger.
 perform pg_advisory_xact_lock(722025101);
 insert into public.tenants(name,slug,status) values(btrim(p_name),p_tenant_slug,'dormant') returning id into target;
 insert into public.tenant_public_profiles(tenant_id,display_name,city,public_slug,is_public,
 show_booking,show_pricing,show_instructor,show_events,show_about,show_contact,show_regulations)
 values(target,btrim(p_name),btrim(p_city),p_public_slug,false,false,false,false,false,false,false,false);
 insert into public.platform_audit_logs(actor_user_id,tenant_id,action) values(auth.uid(),target,'tenant_created');
 return target;
end;$$;

create function public.platform_set_tenant_plan_v1(p_tenant_id uuid,p_plan_key text)
returns void language plpgsql security definer
set search_path=pg_catalog,public,pg_temp
as $$
declare plan_id_value uuid; previous_plan uuid;
begin
 if not public.is_platform_admin_v1() then raise exception 'Not authorized' using errcode='42501'; end if;
 perform 1 from public.tenants where id=p_tenant_id and status in ('dormant','active','suspended') for update;
 if not found then raise exception 'Tenant unavailable' using errcode='22023'; end if;
 select id into plan_id_value from public.saas_plans where plan_key=p_plan_key and status='active' for share;
 if not found then raise exception 'Plan unavailable' using errcode='22023'; end if;
 select plan_id into previous_plan from public.tenant_plan_assignments where tenant_id=p_tenant_id;
 if previous_plan=plan_id_value and exists(select 1 from public.tenant_plan_assignments
   where tenant_id=p_tenant_id and status='active') then return; end if;
 insert into public.tenant_plan_assignments(tenant_id,plan_id,status) values(p_tenant_id,plan_id_value,'active')
 on conflict(tenant_id) do update set plan_id=excluded.plan_id,status='active',assigned_at=now();
 insert into public.platform_audit_logs(actor_user_id,tenant_id,action,details)
 values(auth.uid(),p_tenant_id,case when previous_plan is null then 'plan_assigned' else 'plan_changed' end,
 jsonb_build_object('plan_key',p_plan_key));
end;$$;

create function public.platform_assign_initial_admin_v1(p_tenant_id uuid,p_user_id uuid)
returns void language plpgsql security definer
set search_path=pg_catalog,public,pg_temp
as $$
begin
 if not public.is_platform_admin_v1() then raise exception 'Not authorized' using errcode='42501'; end if;
 perform 1 from public.tenants where id=p_tenant_id and status='dormant' for update;
 if not found then raise exception 'Initial admin assignment requires draft tenant' using errcode='55000'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_tenant_id::text,9401));
 if exists(select 1 from public.tenant_memberships where tenant_id=p_tenant_id and role='admin' and status='active') then
 raise exception 'Initial admin already assigned' using errcode='55000'; end if;
 if not exists(select 1 from auth.users where id=p_user_id and email_confirmed_at is not null and deleted_at is null)
 or exists(select 1 from public.tenant_memberships where tenant_id=p_tenant_id and user_id=p_user_id) then
 raise exception 'Account cannot be assigned' using errcode='22023'; end if;
 insert into public.tenant_memberships(tenant_id,user_id,role,status) values(p_tenant_id,p_user_id,'admin','active');
 insert into public.platform_audit_logs(actor_user_id,tenant_id,action,details)
 values(auth.uid(),p_tenant_id,'tenant_admin_assigned',jsonb_build_object('user_id',p_user_id));
end;$$;

create function public.platform_set_tenant_state_v1(p_tenant_id uuid,p_action text)
returns void language plpgsql security definer
set search_path=pg_catalog,public,pg_temp
as $$
declare current_status text; readiness jsonb; audit_action text;
begin
 if not public.is_platform_admin_v1() then raise exception 'Not authorized' using errcode='42501'; end if;
 select status into current_status from public.tenants where id=p_tenant_id for update;
 if not found then raise exception 'Tenant unavailable' using errcode='22023'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_tenant_id::text,9401));
 if p_action in ('activate','publish') then
   readiness:=public.platform_tenant_readiness_core_v1(p_tenant_id);
   if readiness is null or exists(select 1 from jsonb_each(readiness) where value<>'true'::jsonb) then
     raise exception 'Tenant setup incomplete' using errcode='55000'; end if;
 end if;
 if p_action='activate' and current_status in ('dormant','suspended') then
   update public.tenants set status='active' where id=p_tenant_id; audit_action:='tenant_activated';
 elsif p_action='suspend' and current_status='active' then
   update public.tenants set status='suspended' where id=p_tenant_id;
   update public.tenant_public_profiles set is_public=false where tenant_id=p_tenant_id;
   audit_action:='tenant_suspended';
 elsif p_action='publish' and current_status='active' then
   update public.tenant_public_profiles set is_public=true where tenant_id=p_tenant_id; audit_action:='tenant_published';
 elsif p_action='unpublish' and current_status in ('dormant','active','suspended') then
   update public.tenant_public_profiles set is_public=false where tenant_id=p_tenant_id; audit_action:='tenant_unpublished';
 else raise exception 'Invalid lifecycle transition' using errcode='55000'; end if;
 insert into public.platform_audit_logs(actor_user_id,tenant_id,action) values(auth.uid(),p_tenant_id,audit_action);
end;$$;

-- Immutable selectors after creation: no rename API or hidden status backdoor.
-- Existing namespace constraints/triggers remain authoritative.
do $acl$
declare signature text;
begin
 foreach signature in array array[
 'public.platform_list_tenants_v1(integer)','public.platform_lookup_initial_admin_v1(text)',
 'public.platform_create_tenant_v1(text,text,text,text)','public.platform_set_tenant_plan_v1(uuid,text)',
 'public.platform_assign_initial_admin_v1(uuid,uuid)','public.platform_set_tenant_state_v1(uuid,text)'] loop
 execute format('alter function %s owner to postgres',signature);
 execute format('revoke all on function %s from public,anon,authenticated,service_role',signature);
 execute format('grant execute on function %s to authenticated',signature);
 end loop;
end;$acl$;
