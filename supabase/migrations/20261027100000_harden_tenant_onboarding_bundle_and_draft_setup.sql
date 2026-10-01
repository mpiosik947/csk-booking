-- ONBOARD-1A: atomic existing-account onboarding; dormant configuration only.
-- Forward-only. No production fixtures, invitations, domains or hours changes.
create table public.platform_tenant_creation_requests (
 actor_user_id uuid not null,
 creation_request_id uuid not null,
 payload_hash text not null check(payload_hash ~ '^[0-9a-f]{64}$'),
 tenant_id uuid not null references public.tenants(id) on delete restrict,
 created_at timestamptz not null default now(),
 primary key(actor_user_id,creation_request_id),
 unique(tenant_id)
);
alter table public.platform_tenant_creation_requests owner to postgres;
alter table public.platform_tenant_creation_requests enable row level security;
revoke all on public.platform_tenant_creation_requests from public,anon,authenticated,service_role;

-- Owner-only eligibility predicate, shared by lookup/assign/readiness/setup.
create function public.onboarding_admin_eligible_core_v1(p_user_id uuid)
returns boolean language sql stable set search_path='pg_catalog','public','pg_temp' as $function$
select exists(select 1 from auth.users u join public.profiles p on p.user_id=u.id
 where u.id=p_user_id and u.email_confirmed_at is not null and u.deleted_at is null
 and not coalesce(u.is_anonymous,false) and (u.banned_until is null or u.banned_until<=statement_timestamp())
 and coalesce(u.email,'')<>''
 and not exists(select 1 from public.audit_logs a where a.action='account_anonymized'
   and a.actor_user_id=md5(u.id::text||':csk-sec009-v1')::uuid));
$function$;

-- Lifecycle-compatible order: per-user advisory -> profile -> Auth.
-- NOWAIT on row locks makes inverse external Auth cascades fail/retry rather than deadlock.
create function public.onboarding_lock_admin_core_v1(p_user_id uuid)
returns void language plpgsql set search_path='pg_catalog','public','pg_temp' as $function$
begin
 if p_user_id is null then raise exception 'Account cannot be assigned' using errcode='22023'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_user_id::text,0));
 perform 1 from public.profiles where user_id=p_user_id for share nowait;
 perform 1 from auth.users where id=p_user_id for share nowait;
 if not public.onboarding_admin_eligible_core_v1(p_user_id) then
  raise exception 'Account cannot be assigned' using errcode='22023'; end if;
end;$function$;

create function public.platform_create_tenant_bundle_v2(
 p_name text,p_tenant_slug text,p_public_slug text,p_city text,p_plan_key text,
 p_initial_admin_user_id uuid,p_creation_request_id uuid)
returns jsonb language plpgsql security definer set search_path='pg_catalog','public','pg_temp' as $function$
declare actor uuid:=auth.uid(); target uuid; selected_plan uuid; digest_value text; prior public.platform_tenant_creation_requests%rowtype;
begin
 if not public.is_platform_admin_v1() then raise exception 'Not authorized' using errcode='42501'; end if;
 if p_creation_request_id is null or p_creation_request_id='00000000-0000-0000-0000-000000000000'::uuid
 or p_name is null or p_city is null or length(btrim(p_name)) not between 1 and 120
 or length(btrim(p_city)) not between 1 and 120 or p_plan_key is null or p_initial_admin_user_id is null
 or not public.platform_slug_valid_v1(p_tenant_slug) or not public.platform_slug_valid_v1(p_public_slug)
 or p_tenant_slug=p_public_slug then raise exception 'Invalid onboarding payload' using errcode='22023'; end if;
 digest_value:=encode(sha256(convert_to(jsonb_build_object('name',btrim(p_name),'city',btrim(p_city),
  'tenant_slug',p_tenant_slug,'public_slug',p_public_slug,'plan_key',p_plan_key,'admin',p_initial_admin_user_id)::text,'UTF8')),'hex');
 perform pg_advisory_xact_lock(hashtextextended(actor::text||':'||p_creation_request_id::text,271000));
 select * into prior from public.platform_tenant_creation_requests where actor_user_id=actor and creation_request_id=p_creation_request_id;
 if found then
  if prior.payload_hash<>digest_value then raise exception 'Creation request payload conflict' using errcode='22023'; end if;
  target:=prior.tenant_id;
 else
  perform public.onboarding_lock_admin_core_v1(p_initial_admin_user_id);
  select id into selected_plan from public.saas_plans where plan_key=p_plan_key and status='active' for share nowait;
  if not found then raise exception 'Plan unavailable' using errcode='22023'; end if;
  perform pg_advisory_xact_lock(722025101);
  insert into public.tenants(name,slug,status) values(btrim(p_name),p_tenant_slug,'dormant') returning id into target;
  insert into public.tenant_public_profiles(tenant_id,display_name,city,public_slug,is_public,
   show_booking,show_pricing,show_instructor,show_events,show_about,show_contact,show_regulations)
  values(target,btrim(p_name),btrim(p_city),p_public_slug,false,false,false,false,false,false,false,false);
  insert into public.tenant_plan_assignments(tenant_id,plan_id,status) values(target,selected_plan,'active');
  insert into public.tenant_memberships(tenant_id,user_id,role,status) values(target,p_initial_admin_user_id,'admin','active');
  insert into public.platform_tenant_creation_requests(actor_user_id,creation_request_id,payload_hash,tenant_id)
  values(actor,p_creation_request_id,digest_value,target);
  insert into public.platform_audit_logs(actor_user_id,tenant_id,action,details) values
   (actor,target,'tenant_created','{}'::jsonb),
   (actor,target,'plan_assigned',jsonb_build_object('plan_key',p_plan_key)),
   (actor,target,'tenant_admin_assigned',jsonb_build_object('user_id',p_initial_admin_user_id));
 end if;
 -- Stable creation receipt: replay never leaks current operational data or changes its meaning.
 return jsonb_build_object('tenant_id',target,'name',btrim(p_name),'tenant_slug',p_tenant_slug,
  'public_slug',p_public_slug,'city',btrim(p_city),'initial_status','dormant','initial_is_public',false,
  'plan_key',p_plan_key,'initial_admin_user_id',p_initial_admin_user_id,'creation_request_id',p_creation_request_id);
end;$function$;

CREATE OR REPLACE FUNCTION public.platform_lookup_initial_admin_v1(p_email text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
declare result jsonb;
begin
 if not public.is_platform_admin_v1() then raise exception 'Not authorized' using errcode='42501'; end if;
 if p_email is null or length(p_email)>254 or p_email<>btrim(p_email)
 or p_email !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' then
 raise exception 'Exact email required' using errcode='22023'; end if;
 select jsonb_build_object('user_id',id,'email',email) into strict result from auth.users
 where lower(email)=lower(p_email) and public.onboarding_admin_eligible_core_v1(id);
 return result;
exception when no_data_found then return null;
 when too_many_rows then raise exception 'Account cannot be selected' using errcode='22023';
end;$function$;

CREATE OR REPLACE FUNCTION public.platform_assign_initial_admin_v1(p_tenant_id uuid, p_user_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
begin
 if not public.is_platform_admin_v1() then raise exception 'Not authorized' using errcode='42501'; end if;
 perform public.onboarding_lock_admin_core_v1(p_user_id);
 perform 1 from public.tenants where id=p_tenant_id and status='dormant' for no key update;
 if not found then raise exception 'Initial admin assignment requires draft tenant' using errcode='55000'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_tenant_id::text,9401));
 if exists(select 1 from public.tenant_memberships where tenant_id=p_tenant_id and role='admin' and status='active') then
 raise exception 'Initial admin already assigned' using errcode='55000'; end if;
 if not public.onboarding_admin_eligible_core_v1(p_user_id)
 or exists(select 1 from public.tenant_memberships where tenant_id=p_tenant_id and user_id=p_user_id) then
 raise exception 'Account cannot be assigned' using errcode='22023'; end if;
 insert into public.tenant_memberships(tenant_id,user_id,role,status) values(p_tenant_id,p_user_id,'admin','active');
 insert into public.platform_audit_logs(actor_user_id,tenant_id,action,details)
 values(auth.uid(),p_tenant_id,'tenant_admin_assigned',jsonb_build_object('user_id',p_user_id));
end;$function$;

CREATE OR REPLACE FUNCTION public.platform_tenant_readiness_core_v1(p_tenant_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$select jsonb_build_object(
 'identity_ready',length(btrim(t.name))>0,
 'slug_ready',public.platform_slug_valid_v1(t.slug) and public.platform_slug_valid_v1(p.public_slug),
 'settings_ready',p.tenant_id is not null and length(btrim(p.display_name))>0 and length(btrim(p.city))>0,
 'plan_ready',exists(select 1 from public.tenant_plan_assignments a join public.saas_plans s on s.id=a.plan_id
   where a.tenant_id=t.id and a.status='active' and s.status='active'),
 'admin_ready',exists(select 1 from public.tenant_memberships m join auth.users u on u.id=m.user_id
   where m.tenant_id=t.id and m.role='admin' and m.status='active' and public.onboarding_admin_eligible_core_v1(u.id)))
 from public.tenants t left join public.tenant_public_profiles p on p.tenant_id=t.id where t.id=p_tenant_id;$function$;

CREATE OR REPLACE FUNCTION public.platform_set_tenant_state_v1(p_tenant_id uuid, p_action text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
declare current_status text; readiness jsonb; audit_action text; initial_admin uuid;
begin
 if not public.is_platform_admin_v1() then raise exception 'Not authorized' using errcode='42501'; end if;
 select status into current_status from public.tenants where id=p_tenant_id for no key update;
 if not found then raise exception 'Tenant unavailable' using errcode='22023'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_tenant_id::text,9401));
 if p_action in ('activate','publish') then
   -- NO KEY UPDATE preserves status serialization without blocking audit/membership FK KEY SHARE.
   -- Nonblocking account/catalog locks avoid reversing account-delete/operator lock orders.
   perform 1 from public.tenant_public_profiles where tenant_id=p_tenant_id for share nowait;
   for initial_admin in select user_id from public.tenant_memberships
     where tenant_id=p_tenant_id and role='admin' and status='active' order by user_id for share nowait loop
     if not pg_try_advisory_xact_lock(hashtextextended(initial_admin::text,0)) then
       raise exception 'Onboarding account busy; retry' using errcode='55P03'; end if;
     perform 1 from public.profiles where user_id=initial_admin for share nowait;
     perform 1 from auth.users where id=initial_admin for share nowait;
   end loop;
   perform 1 from public.tenant_plan_assignments where tenant_id=p_tenant_id for share nowait;
   perform p.id from public.saas_plans p join public.tenant_plan_assignments a on a.plan_id=p.id
     where a.tenant_id=p_tenant_id for share of p nowait;
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
end;$function$;

create or replace function public.is_active_public_tenant_v1(p_tenant_id uuid)
returns boolean language sql stable security definer set search_path='pg_catalog','public','pg_temp' as $function$
select exists(select 1 from public.tenants t join public.tenant_public_profiles p on p.tenant_id=t.id
 where t.id=p_tenant_id and t.status='active' and p.is_public);
$function$;

-- Configuration authority only; no alteration to operational role or feature helpers.
create function public.tenant_draft_setup_role_core_v1(p_tenant_id uuid)
returns text language sql stable set search_path='pg_catalog','public','pg_temp' as $function$
select 'admin'::text from public.tenants t join public.tenant_memberships m on m.tenant_id=t.id
 where t.id=p_tenant_id and t.status='dormant' and m.user_id=auth.uid() and m.role='admin' and m.status='active'
 and public.onboarding_admin_eligible_core_v1(m.user_id)
 and public.tenant_setup_has_feature_core_v1(t.id,'booking')
 and not exists(select 1 from public.reservations r where r.tenant_id=t.id)
 and not exists(select 1 from public.events e where e.tenant_id=t.id)
 and not exists(select 1 from public.lane_blocks b where b.tenant_id=t.id);
$function$;

create function public.lock_tenant_draft_setup_core_v1(p_tenant_id uuid)
returns void language plpgsql set search_path='pg_catalog','public','pg_temp' as $function$
begin
 -- NOWAIT avoids profile/Auth -> tenant lock inversions with account lifecycle.
 perform 1 from public.tenants where id=p_tenant_id and status='dormant' for no key update;
 if not found or public.tenant_draft_setup_role_core_v1(p_tenant_id) is distinct from 'admin' then
  raise exception 'Draft configuration not allowed' using errcode='42501'; end if;
 perform 1 from public.tenant_memberships where tenant_id=p_tenant_id and user_id=auth.uid() for share nowait;
 perform 1 from public.profiles where user_id=auth.uid() for share nowait;
 perform 1 from auth.users where id=auth.uid() for share nowait;
 perform 1 from public.tenant_plan_assignments where tenant_id=p_tenant_id for share nowait;
 perform p.id from public.saas_plans p join public.tenant_plan_assignments a on a.plan_id=p.id
  where a.tenant_id=p_tenant_id for share of p nowait;
 if public.tenant_draft_setup_role_core_v1(p_tenant_id) is distinct from 'admin' then
  raise exception 'Draft configuration not allowed' using errcode='42501'; end if;
end;$function$;

CREATE OR REPLACE FUNCTION public.tenant_draft_lane_resources_core_v1(p_tenant_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
declare
  v_actor_id uuid:=auth.uid();
  v_actor_role text;
  v_tenant_id uuid:=p_tenant_id;
  v_resources jsonb;
begin
  if v_actor_id is null or v_tenant_id is null
     or public.tenant_draft_setup_role_core_v1(v_tenant_id) is distinct from 'admin' then
    raise exception 'Lane configuration access is restricted to administrators.'
      using errcode='42501';
  end if;



  if exists (
       select 1
       from public.shooting_lanes resource
       left join public.shooting_lanes parent
         on parent.id=resource.parent_lane_id
        and parent.tenant_id=resource.tenant_id
       where resource.tenant_id=v_tenant_id
         and (
           resource.resource_kind not in ('lane','position')
           or resource.parent_lane_id=resource.id
           or (resource.resource_kind='lane' and resource.parent_lane_id is not null)
           or (
             resource.resource_kind='position'
             and (
               resource.parent_lane_id is null
               or resource.whole_lane_bookable
               or resource.positions_bookable
               or parent.id is null
               or parent.resource_kind<>'lane'
               or parent.parent_lane_id is not null
             )
           )
         )
     )
     or exists (
       select 1
       from public.shooting_lanes resource
       left join public.lane_booking_rules booking_rule
         on booking_rule.lane_id=resource.id
       where resource.tenant_id=v_tenant_id
         and booking_rule.lane_id is null
     )
     or exists (
       select 1
       from public.lane_booking_durations duration
       join public.shooting_lanes lane
         on lane.id=duration.lane_id and lane.tenant_id=v_tenant_id
       group by duration.lane_id,duration.duration_minutes
       having pg_catalog.count(*)>1
     )
     or exists (
       select 1
       from public.lane_pricing_rules first_rule
       join public.shooting_lanes lane
         on lane.id=first_rule.lane_id and lane.tenant_id=v_tenant_id
       join public.lane_pricing_rules second_rule
         on second_rule.lane_id=first_rule.lane_id
        and second_rule.day_group=first_rule.day_group
        and second_rule.is_active
        and second_rule.id>first_rule.id
        and second_rule.min_shooters<=first_rule.max_shooters
        and second_rule.max_shooters>=first_rule.min_shooters
       where first_rule.is_active
     ) then
    raise exception 'Lane configuration snapshot is structurally ambiguous.'
      using errcode='55000';
  end if;

  select coalesce(pg_catalog.jsonb_agg(
    pg_catalog.jsonb_build_object(
      'lane_id',resource.lane_id,
      'name',resource.name,
      'resource_kind',resource.resource_kind,
      'parent_lane_id',resource.parent_lane_id,
      'display_order',resource.display_order,
      'is_active',resource.is_active,
      'max_shooters',resource.max_shooters,
      'whole_lane_bookable',resource.whole_lane_bookable,
      'positions_bookable',resource.positions_bookable,
      'booking_step_minutes',resource.booking_step_minutes,
      'currency_code',resource.currency_code,
      'online_bookable',resource.online_bookable,
      'max_people_online',resource.max_people_online,
      'durations',resource.durations,
      'pricing',resource.pricing
    ) order by resource.root_display_order,resource.root_id,
      resource.resource_depth,resource.display_order,resource.lane_id
  ),'[]'::jsonb)
  into v_resources
  from (
    select
      lane.id as lane_id,lane.name,lane.resource_kind,lane.parent_lane_id,
      lane.display_order,lane.is_active,lane.max_shooters,
      lane.whole_lane_bookable,lane.positions_bookable,
      lane.booking_step_minutes,lane.currency_code::text as currency_code,
      booking_rule.online_bookable,booking_rule.max_people_online,
      case when lane.resource_kind='lane' then lane.id else lane.parent_lane_id end as root_id,
      case when lane.resource_kind='lane' then lane.display_order else parent.display_order end as root_display_order,
      case when lane.resource_kind='lane' then 0 else 1 end as resource_depth,
      coalesce((
        select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
          'duration_minutes',duration.duration_minutes,
          'display_order',duration.display_order,
          'is_active',duration.is_active
        ) order by duration.display_order,duration.duration_minutes,duration.id)
        from public.lane_booking_durations duration
        where duration.lane_id=lane.id
      ),'[]'::jsonb) as durations,
      coalesce((
        select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
          'day_group',pricing.day_group,
          'min_shooters',pricing.min_shooters,
          'max_shooters',pricing.max_shooters,
          'label',pricing.label,
          'hourly_price',pricing.hourly_price,
          'display_order',pricing.display_order,
          'is_active',pricing.is_active
        ) order by
          case pricing.day_group when 'mon_thu' then 0 when 'fri_sun' then 1 else 2 end,
          pricing.is_active desc,pricing.display_order,pricing.min_shooters,
          pricing.max_shooters,pricing.id)
        from public.lane_pricing_rules pricing
        where pricing.lane_id=lane.id
      ),'[]'::jsonb) as pricing
    from public.shooting_lanes lane
    join public.lane_booking_rules booking_rule on booking_rule.lane_id=lane.id
    left join public.shooting_lanes parent
      on parent.id=lane.parent_lane_id and parent.tenant_id=lane.tenant_id
    where lane.tenant_id=v_tenant_id
  ) resource;

  return pg_catalog.jsonb_build_object('contract_version',1,'resources',v_resources);
end;
$function$;

CREATE OR REPLACE FUNCTION public.tenant_draft_lane_configuration_core_v1(p_tenant_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
declare
  v_actor_id uuid:=auth.uid();
  v_actor_role text;
  v_tenant_id uuid:=p_tenant_id;
  v_v1 jsonb;
  v_families jsonb;
begin
  if v_actor_id is null or v_tenant_id is null
     or public.tenant_draft_setup_role_core_v1(v_tenant_id) is distinct from 'admin' then
    raise exception 'Lane configuration access is restricted to administrators.'
      using errcode='42501';
  end if;



  if (select pg_catalog.count(*)
      from public.shooting_lanes root
      where root.tenant_id=v_tenant_id
        and root.resource_kind='lane' and root.parent_lane_id is null)
     <>
     (select pg_catalog.count(*)
      from public.lane_booking_family_configuration_versions version
      join public.shooting_lanes root
        on root.id=version.root_lane_id and root.tenant_id=v_tenant_id
      where root.resource_kind='lane' and root.parent_lane_id is null) then
    raise exception 'Lane family version snapshot is incomplete.' using errcode='55000';
  end if;

  v_v1:=public.tenant_draft_lane_resources_core_v1(p_tenant_id);

  select coalesce(pg_catalog.jsonb_agg(
    pg_catalog.jsonb_build_object(
      'root_lane_id',root.id,
      'configuration_version',version.configuration_version,
      'resources',coalesce((
        select pg_catalog.jsonb_agg(resource.value order by resource.ordinality)
        from pg_catalog.jsonb_array_elements(v_v1->'resources') with ordinality
          resource(value,ordinality)
        where resource.value->>'lane_id'=root.id::text
           or resource.value->>'parent_lane_id'=root.id::text
      ),'[]'::jsonb)
    ) order by root.display_order,root.id
  ),'[]'::jsonb)
  into v_families
  from public.shooting_lanes root
  join public.lane_booking_family_configuration_versions version
    on version.root_lane_id=root.id
  where root.tenant_id=v_tenant_id
    and root.resource_kind='lane' and root.parent_lane_id is null;

  return pg_catalog.jsonb_build_object('contract_version',2,'families',v_families);
end;
$function$;

CREATE OR REPLACE FUNCTION public.tenant_draft_create_lane_family_core_v1(p_tenant_id uuid, p_family jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
declare
  v_actor_id uuid := auth.uid();
  v_actor public.profiles%rowtype;
  v_actor_role text;
  v_tenant_id uuid;
  v_root jsonb;
  v_positions jsonb;
  v_resources jsonb;
  v_resource record;
  v_price record;
  v_root_id uuid;
  v_position_id uuid;
  v_root_display_order integer;
  v_created_resources jsonb := '[]'::jsonb;
  v_created_count integer := 0;
  v_position_capacity integer := 0;
  v_now timestamptz := pg_catalog.transaction_timestamp();
begin
  perform tenant.id from public.tenants tenant where tenant.id=p_tenant_id for share;
  v_tenant_id:=p_tenant_id;
  if v_actor_id is null or v_tenant_id is null
     or public.tenant_draft_setup_role_core_v1(v_tenant_id) is distinct from 'admin' then
    return pg_catalog.jsonb_build_object(
      'ok',false,'changed',false,'code','not_allowed',
      'root_lane_id',null,'configuration_version',null,
      'created_resource_count',0
    );
  end if;

  select profile.*
  into v_actor
  from public.profiles as profile
  where profile.user_id = v_actor_id;

  v_actor_role := public.tenant_draft_setup_role_core_v1(v_tenant_id);
  if v_actor_id is null or coalesce(v_actor_role, '') <> 'admin' then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'changed', false,
      'code', 'not_allowed',
      'root_lane_id', null,
      'configuration_version', null,
      'created_resource_count', 0
    );
  end if;

  begin
    if p_family is null
       or pg_catalog.jsonb_typeof(p_family) <> 'object'
       or (
         select pg_catalog.array_agg(key order by key)
         from pg_catalog.jsonb_object_keys(p_family) as keys(key)
       ) is distinct from array['positions', 'root']::text[]
       or pg_catalog.jsonb_typeof(p_family->'root') <> 'object'
       or pg_catalog.jsonb_typeof(p_family->'positions') <> 'array'
       or pg_catalog.jsonb_array_length(p_family->'positions') > 100 then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'invalid_payload',
        'root_lane_id', null, 'configuration_version', null,
        'created_resource_count', 0
      );
    end if;

    v_root := p_family->'root';
    v_positions := p_family->'positions';

    if (
         select pg_catalog.array_agg(key order by key)
         from pg_catalog.jsonb_object_keys(v_root) as keys(key)
       ) is distinct from array[
         'booking_step_minutes', 'durations_minutes', 'is_active',
         'max_people_online', 'max_shooters', 'name', 'online_bookable',
         'positions_bookable', 'pricing', 'whole_lane_bookable'
       ]::text[]
       or exists (
         select 1
         from pg_catalog.jsonb_array_elements(v_positions) as position(value)
         where pg_catalog.jsonb_typeof(position.value) <> 'object'
            or (
              select pg_catalog.array_agg(key order by key)
              from pg_catalog.jsonb_object_keys(position.value) as keys(key)
            ) is distinct from array[
              'booking_step_minutes', 'durations_minutes', 'is_active',
              'max_people_online', 'max_shooters', 'name', 'online_bookable',
              'pricing'
            ]::text[]
       ) then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'invalid_payload',
        'root_lane_id', null, 'configuration_version', null,
        'created_resource_count', 0
      );
    end if;

    select pg_catalog.jsonb_build_array(
      v_root || pg_catalog.jsonb_build_object(
        'resource_kind', 'lane'
      )
    ) || coalesce(pg_catalog.jsonb_agg(
      position.value || pg_catalog.jsonb_build_object(
        'resource_kind', 'position',
        'whole_lane_bookable', false,
        'positions_bookable', false
      ) order by position.ordinality
    ), '[]'::jsonb)
    into v_resources
    from pg_catalog.jsonb_array_elements(v_positions) with ordinality
      as position(value, ordinality);

    for v_resource in
      select resource.value, resource.ordinality
      from pg_catalog.jsonb_array_elements(v_resources) with ordinality
        as resource(value, ordinality)
      order by resource.ordinality
    loop
      if pg_catalog.jsonb_typeof(v_resource.value->'name') <> 'string'
         or pg_catalog.btrim(v_resource.value->>'name') = ''
         or pg_catalog.char_length(pg_catalog.btrim(v_resource.value->>'name')) > 120
         or v_resource.value->>'name' ~ '[<>]'
         or v_resource.value->>'name' ~ '[[:cntrl:]]'
         or pg_catalog.jsonb_typeof(v_resource.value->'is_active') <> 'boolean'
         or pg_catalog.jsonb_typeof(v_resource.value->'online_bookable') <> 'boolean'
         or pg_catalog.jsonb_typeof(v_resource.value->'whole_lane_bookable') <> 'boolean'
         or pg_catalog.jsonb_typeof(v_resource.value->'positions_bookable') <> 'boolean'
         or pg_catalog.jsonb_typeof(v_resource.value->'max_shooters') <> 'number'
         or v_resource.value->>'max_shooters' !~ '^[1-9][0-9]*$'
         or pg_catalog.jsonb_typeof(v_resource.value->'max_people_online') <> 'number'
         or v_resource.value->>'max_people_online' !~ '^[1-9][0-9]*$'
         or pg_catalog.jsonb_typeof(v_resource.value->'booking_step_minutes') <> 'number'
         or v_resource.value->>'booking_step_minutes' !~ '^[1-9][0-9]*$'
         or (v_resource.value->>'booking_step_minutes')::integer > 1440
         or (v_resource.value->>'max_people_online')::integer
              > (v_resource.value->>'max_shooters')::integer
         or pg_catalog.jsonb_typeof(v_resource.value->'durations_minutes') <> 'array'
         or pg_catalog.jsonb_array_length(v_resource.value->'durations_minutes') = 0
         or pg_catalog.jsonb_typeof(v_resource.value->'pricing') <> 'array'
         or pg_catalog.jsonb_array_length(v_resource.value->'pricing') = 0 then
        return pg_catalog.jsonb_build_object(
          'ok', false, 'changed', false, 'code', 'invalid_payload',
          'root_lane_id', null, 'configuration_version', null,
          'created_resource_count', 0
        );
      end if;

      if exists (
           select 1
           from pg_catalog.jsonb_array_elements(
             v_resource.value->'durations_minutes'
           ) as duration(value)
           where pg_catalog.jsonb_typeof(duration.value) <> 'number'
              or duration.value #>> '{}' !~ '^[1-9][0-9]*$'
              or (duration.value #>> '{}')::integer > 1440
              or (duration.value #>> '{}')::integer
                   % (v_resource.value->>'booking_step_minutes')::integer <> 0
         )
         or (
           select pg_catalog.count(*)
           from pg_catalog.jsonb_array_elements(
             v_resource.value->'durations_minutes'
           )
         ) <> (
           select pg_catalog.count(distinct duration.value #>> '{}')
           from pg_catalog.jsonb_array_elements(
             v_resource.value->'durations_minutes'
           ) as duration(value)
         ) then
        return pg_catalog.jsonb_build_object(
          'ok', false, 'changed', false, 'code', 'invalid_configuration',
          'root_lane_id', null, 'configuration_version', null,
          'created_resource_count', 0
        );
      end if;

      for v_price in
        select price.value
        from pg_catalog.jsonb_array_elements(v_resource.value->'pricing')
          as price(value)
      loop
        if pg_catalog.jsonb_typeof(v_price.value) <> 'object'
           or (
             select pg_catalog.array_agg(key order by key)
             from pg_catalog.jsonb_object_keys(v_price.value) as keys(key)
           ) is distinct from array[
             'day_group', 'hourly_price', 'label', 'max_shooters', 'min_shooters'
           ]::text[]
           or pg_catalog.jsonb_typeof(v_price.value->'day_group') <> 'string'
           or v_price.value->>'day_group' not in ('mon_thu', 'fri_sun')
           or pg_catalog.jsonb_typeof(v_price.value->'label') <> 'string'
           or pg_catalog.btrim(v_price.value->>'label') = ''
           or pg_catalog.jsonb_typeof(v_price.value->'min_shooters') <> 'number'
           or v_price.value->>'min_shooters' !~ '^[1-9][0-9]*$'
           or pg_catalog.jsonb_typeof(v_price.value->'max_shooters') <> 'number'
           or v_price.value->>'max_shooters' !~ '^[1-9][0-9]*$'
           or pg_catalog.jsonb_typeof(v_price.value->'hourly_price') <> 'number'
           or v_price.value->>'hourly_price' !~ '^[0-9]+([.][0-9]{1,2})?$'
           or (v_price.value->>'min_shooters')::integer
                > (v_price.value->>'max_shooters')::integer
           or (v_price.value->>'max_shooters')::integer
                > (v_resource.value->>'max_people_online')::integer
           or (v_price.value->>'hourly_price')::numeric > 9999999999.99 then
          return pg_catalog.jsonb_build_object(
            'ok', false, 'changed', false, 'code', 'invalid_payload',
            'root_lane_id', null, 'configuration_version', null,
            'created_resource_count', 0
          );
        end if;
      end loop;

      if exists (
           with parsed as (
             select
               price.value->>'day_group' as day_group,
               (price.value->>'min_shooters')::integer as min_shooters,
               (price.value->>'max_shooters')::integer as max_shooters,
               pg_catalog.lag((price.value->>'max_shooters')::integer) over (
                 partition by price.value->>'day_group'
                 order by (price.value->>'min_shooters')::integer,
                          (price.value->>'max_shooters')::integer
               ) as previous_max
             from pg_catalog.jsonb_array_elements(v_resource.value->'pricing')
               as price(value)
           )
           select 1 from parsed
           where (previous_max is null and min_shooters <> 1)
              or (previous_max is not null and min_shooters <> previous_max + 1)
         )
         or (
           select pg_catalog.count(*)
           from (
             select price.value->>'day_group' as day_group
             from pg_catalog.jsonb_array_elements(v_resource.value->'pricing')
               as price(value)
             group by price.value->>'day_group'
             having pg_catalog.max((price.value->>'max_shooters')::integer)
                    = (v_resource.value->>'max_people_online')::integer
           ) as complete_group
         ) <> 2 then
        return pg_catalog.jsonb_build_object(
          'ok', false, 'changed', false, 'code', 'invalid_configuration',
          'root_lane_id', null, 'configuration_version', null,
          'created_resource_count', 0
        );
      end if;
    end loop;
  exception
    when sqlstate '22003' or sqlstate '22P02' then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'invalid_payload',
        'root_lane_id', null, 'configuration_version', null,
        'created_resource_count', 0
      );
  end;

  if (v_root->>'online_bookable')::boolean
       and (not (v_root->>'is_active')::boolean
            or not (v_root->>'whole_lane_bookable')::boolean)
     or not (v_root->>'is_active')::boolean
       and (
         (v_root->>'online_bookable')::boolean
         or exists (
           select 1
           from pg_catalog.jsonb_array_elements(v_positions) as position(value)
           where (position.value->>'is_active')::boolean
              or (position.value->>'online_bookable')::boolean
         )
       )
     or exists (
       select 1
       from pg_catalog.jsonb_array_elements(v_positions) as position(value)
       where (position.value->>'online_bookable')::boolean
         and (
           not (position.value->>'is_active')::boolean
           or not (v_root->>'positions_bookable')::boolean
         )
     )
     or (
       (v_root->>'positions_bookable')::boolean
       and not exists (
         select 1
         from pg_catalog.jsonb_array_elements(v_positions) as position(value)
         where (position.value->>'is_active')::boolean
           and (position.value->>'online_bookable')::boolean
       )
     ) then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_configuration',
      'root_lane_id', null, 'configuration_version', null,
      'created_resource_count', 0
    );
  end if;

  select coalesce(pg_catalog.sum((position.value->>'max_shooters')::integer), 0)
  into v_position_capacity
  from pg_catalog.jsonb_array_elements(v_positions) as position(value)
  where (position.value->>'is_active')::boolean
    and (position.value->>'online_bookable')::boolean;

  if (v_root->>'positions_bookable')::boolean
     and v_position_capacity > (v_root->>'max_shooters')::integer then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_configuration',
      'root_lane_id', null, 'configuration_version', null,
      'created_resource_count', 0
    );
  end if;

  lock table public.shooting_lanes in share row exclusive mode;

  select coalesce(pg_catalog.max(lane.display_order), 0) + 10
  into v_root_display_order
  from public.shooting_lanes as lane
  where lane.tenant_id=v_tenant_id;

  v_root_id := pg_catalog.gen_random_uuid();
  insert into public.shooting_lanes(
    tenant_id, id, name, type, description, price_per_hour, is_active,
    max_shooters, booking_step_minutes, display_order, currency_code,
    resource_kind, parent_lane_id, whole_lane_bookable, positions_bookable
  ) values (
    v_tenant_id, v_root_id,
    pg_catalog.btrim(v_root->>'name'),
    'konfigurowalna',
    null,
    0,
    (v_root->>'is_active')::boolean,
    (v_root->>'max_shooters')::integer,
    (v_root->>'booking_step_minutes')::integer,
    v_root_display_order,
    'PLN',
    'lane',
    null,
    (v_root->>'whole_lane_bookable')::boolean,
    (v_root->>'positions_bookable')::boolean
  );

  insert into public.lane_booking_rules(lane_id, online_bookable, max_people_online)
  values (
    v_root_id,
    (v_root->>'online_bookable')::boolean,
    (v_root->>'max_people_online')::integer
  );

  insert into public.lane_booking_durations(
    lane_id, duration_minutes, display_order, is_active
  )
  select
    v_root_id,
    (duration.value #>> '{}')::integer,
    duration.ordinality * 10,
    true
  from pg_catalog.jsonb_array_elements(v_root->'durations_minutes') with ordinality
    as duration(value, ordinality);

  insert into public.lane_pricing_rules(
    lane_id, day_group, min_shooters, max_shooters,
    label, hourly_price, display_order, is_active
  )
  select
    v_root_id,
    price.value->>'day_group',
    (price.value->>'min_shooters')::integer,
    (price.value->>'max_shooters')::integer,
    pg_catalog.btrim(price.value->>'label'),
    (price.value->>'hourly_price')::numeric(12,2),
    pg_catalog.row_number() over (
      partition by price.value->>'day_group'
      order by (price.value->>'min_shooters')::integer,
               (price.value->>'max_shooters')::integer,
               pg_catalog.btrim(price.value->>'label')
    ) * 10,
    true
  from pg_catalog.jsonb_array_elements(v_root->'pricing') as price(value);

  v_created_resources := pg_catalog.jsonb_build_array(
    pg_catalog.jsonb_build_object(
      'resource_id', v_root_id,
      'resource_kind', 'lane',
      'name', pg_catalog.btrim(v_root->>'name')
    )
  );
  v_created_count := 1;

  for v_resource in
    select position.value, position.ordinality
    from pg_catalog.jsonb_array_elements(v_positions) with ordinality
      as position(value, ordinality)
    order by position.ordinality
  loop
    v_position_id := pg_catalog.gen_random_uuid();
    insert into public.shooting_lanes(
      tenant_id, id, name, type, description, price_per_hour, is_active,
      max_shooters, booking_step_minutes, display_order, currency_code,
      resource_kind, parent_lane_id, whole_lane_bookable, positions_bookable
    ) values (
      v_tenant_id, v_position_id,
      pg_catalog.btrim(v_resource.value->>'name'),
      'konfigurowalna',
      null,
      0,
      (v_resource.value->>'is_active')::boolean,
      (v_resource.value->>'max_shooters')::integer,
      (v_resource.value->>'booking_step_minutes')::integer,
      v_root_display_order + v_resource.ordinality::integer,
      'PLN',
      'position',
      v_root_id,
      false,
      false
    );

    insert into public.lane_booking_rules(lane_id, online_bookable, max_people_online)
    values (
      v_position_id,
      (v_resource.value->>'online_bookable')::boolean,
      (v_resource.value->>'max_people_online')::integer
    );

    insert into public.lane_booking_durations(
      lane_id, duration_minutes, display_order, is_active
    )
    select
      v_position_id,
      (duration.value #>> '{}')::integer,
      duration.ordinality * 10,
      true
    from pg_catalog.jsonb_array_elements(
      v_resource.value->'durations_minutes'
    ) with ordinality as duration(value, ordinality);

    insert into public.lane_pricing_rules(
      lane_id, day_group, min_shooters, max_shooters,
      label, hourly_price, display_order, is_active
    )
    select
      v_position_id,
      price.value->>'day_group',
      (price.value->>'min_shooters')::integer,
      (price.value->>'max_shooters')::integer,
      pg_catalog.btrim(price.value->>'label'),
      (price.value->>'hourly_price')::numeric(12,2),
      pg_catalog.row_number() over (
        partition by price.value->>'day_group'
        order by (price.value->>'min_shooters')::integer,
                 (price.value->>'max_shooters')::integer,
                 pg_catalog.btrim(price.value->>'label')
      ) * 10,
      true
    from pg_catalog.jsonb_array_elements(v_resource.value->'pricing')
      as price(value);

    v_created_resources := v_created_resources || pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object(
        'resource_id', v_position_id,
        'resource_kind', 'position',
        'name', pg_catalog.btrim(v_resource.value->>'name')
      )
    );
    v_created_count := v_created_count + 1;
  end loop;

  insert into public.lane_booking_family_configuration_versions(
    root_lane_id, configuration_version
  ) values (v_root_id, 1);

  insert into public.audit_logs(
    tenant_id, actor_user_id, actor_name, actor_role, action,
    target_type, target_id, target_name, details
  ) values (
    v_tenant_id, v_actor_id,
    coalesce(
      nullif(
        pg_catalog.btrim(
          pg_catalog.concat_ws(' ', v_actor.first_name, v_actor.last_name)
        ),
        ''
      ),
      nullif(pg_catalog.btrim(v_actor.full_name), ''),
      'Administrator'
    ),
    'admin',
    'lane_booking_family_created',
    'lane_booking_family',
    v_root_id,
    pg_catalog.btrim(v_root->>'name'),
    pg_catalog.jsonb_build_object(
      'configuration_version', 1,
      'created_resources', v_created_resources,
      'created_at', v_now
    )
  );

  return pg_catalog.jsonb_build_object(
    'ok', true,
    'changed', true,
    'code', 'created',
    'root_lane_id', v_root_id,
    'configuration_version', 1,
    'created_resource_count', v_created_count
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.tenant_draft_set_lane_configuration_core_v1(p_root_lane_id uuid, p_expected_version bigint, p_resources jsonb, p_acknowledge_future_obligations boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
declare
  v_actor_id uuid := auth.uid();
  v_actor public.profiles%rowtype;
  v_actor_role text;
  v_tenant_id uuid;
  v_root public.shooting_lanes%rowtype;
  v_root_target jsonb;
  v_target jsonb;
  v_current jsonb;
  v_target_without_names jsonb;
  v_current_without_names jsonb;
  v_renamed_resources jsonb := '[]'::jsonb;
  v_name_only boolean := false;
  v_family_ids uuid[];
  v_target_ids uuid[];
  v_affected_ids uuid[] := '{}'::uuid[];
  v_version bigint;
  v_resource record;
  v_lane public.shooting_lanes%rowtype;
  v_rule public.lane_booking_rules%rowtype;
  v_price record;
  v_previous_max integer;
  v_group_count integer;
  v_position_capacity integer;
  v_max_obligation integer;
  v_future_reservations bigint := 0;
  v_future_blocks bigint := 0;
  v_future_events bigint := 0;
  v_now timestamptz := pg_catalog.transaction_timestamp();
begin
  select profile.* into v_actor
  from public.profiles as profile
  where profile.user_id = v_actor_id;
  v_actor_role := pg_catalog.lower(pg_catalog.btrim(v_actor.role::text));

  if v_actor_id is null then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'not_allowed',
      'root_lane_id', p_root_lane_id
    );
  end if;

  if p_root_lane_id is null or p_expected_version is null
     or p_expected_version < 1 or p_acknowledge_future_obligations is null then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_payload',
      'root_lane_id', p_root_lane_id
    );
  end if;

  select root.tenant_id into v_tenant_id
  from public.shooting_lanes root
  where root.id=p_root_lane_id;

  if not found then
    return pg_catalog.jsonb_build_object(
      'ok',false,'changed',false,'code','family_not_found',
      'root_lane_id',p_root_lane_id
    );
  end if;

  if public.tenant_draft_setup_role_core_v1(v_tenant_id) is distinct from 'admin' then
    return pg_catalog.jsonb_build_object(
      'ok',false,'changed',false,'code','not_allowed',
      'root_lane_id',p_root_lane_id
    );
  end if;

  begin
    v_target := public.normalize_lane_booking_family_payload_v2(p_resources);
  exception when sqlstate '22023' then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_payload',
      'root_lane_id', p_root_lane_id
    );
  end;

  begin
    select scope.conflict_lane_ids into v_family_ids
    from public.lock_lane_conflict_families_v1(array[p_root_lane_id]) as scope
    where scope.requested_lane_id = p_root_lane_id
      and scope.root_lane_id = p_root_lane_id
      and scope.requested_resource_kind = 'lane';
  exception
    when sqlstate 'P0002' then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'family_not_found',
        'root_lane_id', p_root_lane_id
      );
    when sqlstate '55000' or sqlstate '22023' then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'invalid_hierarchy',
        'root_lane_id', p_root_lane_id
      );
  end;

  if v_family_ids is null then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_hierarchy',
      'root_lane_id', p_root_lane_id
    );
  end if;

  if (select pg_catalog.count(*) from public.shooting_lanes lane where lane.id=any(v_family_ids) and lane.tenant_id=v_tenant_id)<>pg_catalog.cardinality(v_family_ids) then
    return pg_catalog.jsonb_build_object(
      'ok',false,'changed',false,'code','not_allowed',
      'root_lane_id',p_root_lane_id
    );
  end if;

  select pg_catalog.array_agg(family_id order by family_id)
  into v_family_ids
  from pg_catalog.unnest(v_family_ids) as family(family_id);

  select root.* into v_root
  from public.shooting_lanes as root
  where root.id = p_root_lane_id
    and root.tenant_id = v_tenant_id;

  select version.configuration_version into v_version
  from public.lane_booking_family_configuration_versions as version
  where version.root_lane_id = p_root_lane_id
  for update;

  if not found then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_hierarchy',
      'root_lane_id', p_root_lane_id
    );
  end if;

  if v_version <> p_expected_version then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'stale_configuration',
      'root_lane_id', p_root_lane_id,
      'current_version', v_version,
      'previous_version', v_version,
      'configuration_version', v_version
    );
  end if;

  select pg_catalog.array_agg((item.value->>'lane_id')::uuid order by (item.value->>'lane_id')::uuid)
  into v_target_ids
  from pg_catalog.jsonb_array_elements(v_target) as item(value);

  if v_target_ids is distinct from v_family_ids then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_payload',
      'root_lane_id', p_root_lane_id,
      'previous_version', v_version,
      'configuration_version', v_version
    );
  end if;

  perform rule.lane_id
  from public.lane_booking_rules as rule
  where rule.lane_id = any(v_family_ids)
  order by rule.lane_id
  for update;

  if (select pg_catalog.count(*) from public.lane_booking_rules
      where lane_id = any(v_family_ids)) <> pg_catalog.cardinality(v_family_ids) then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_hierarchy',
      'root_lane_id', p_root_lane_id,
      'previous_version', v_version,
      'configuration_version', v_version
    );
  end if;

  perform duration.id
  from public.lane_booking_durations as duration
  where duration.lane_id = any(v_family_ids)
  order by duration.lane_id, duration.duration_minutes, duration.id
  for update;

  perform pricing.id
  from public.lane_pricing_rules as pricing
  where pricing.lane_id = any(v_family_ids)
  order by pricing.lane_id, pricing.day_group, pricing.min_shooters,
           pricing.max_shooters, pricing.id
  for update;

  v_current := public.lane_booking_family_business_snapshot_v2(p_root_lane_id);
  v_root_target := (
    select item.value from pg_catalog.jsonb_array_elements(v_target) as item(value)
    where item.value->>'lane_id' = p_root_lane_id::text
  );

  select pg_catalog.jsonb_agg(item.value - 'name' order by (item.value->>'lane_id')::uuid)
  into v_current_without_names
  from pg_catalog.jsonb_array_elements(v_current) as item(value);

  select pg_catalog.jsonb_agg(item.value - 'name' order by (item.value->>'lane_id')::uuid)
  into v_target_without_names
  from pg_catalog.jsonb_array_elements(v_target) as item(value);

  select coalesce(pg_catalog.jsonb_agg(
    pg_catalog.jsonb_build_object(
      'resource_id', (target.value->>'lane_id')::uuid,
      'old_name', current.value->>'name',
      'new_name', target.value->>'name'
    ) order by (target.value->>'lane_id')::uuid
  ), '[]'::jsonb)
  into v_renamed_resources
  from pg_catalog.jsonb_array_elements(v_target) as target(value)
  join pg_catalog.jsonb_array_elements(v_current) as current(value)
    on current.value->>'lane_id' = target.value->>'lane_id'
  where current.value->>'name' is distinct from target.value->>'name';

  v_name_only := v_current_without_names = v_target_without_names;

  if v_root.resource_kind <> 'lane' or v_root.parent_lane_id is not null
     or v_root_target is null then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_hierarchy',
      'root_lane_id', p_root_lane_id,
      'previous_version', v_version,
      'configuration_version', v_version
    );
  end if;

  for v_resource in
    select item.value
    from pg_catalog.jsonb_array_elements(v_target) as item(value)
    order by (item.value->>'lane_id')::uuid
  loop
    select lane.* into v_lane
    from public.shooting_lanes as lane
    where lane.id = (v_resource.value->>'lane_id')::uuid
      and lane.tenant_id = v_tenant_id;

    if not found
       or (v_lane.id = p_root_lane_id and
           (v_lane.resource_kind <> 'lane' or v_lane.parent_lane_id is not null))
       or (v_lane.id <> p_root_lane_id and
           (v_lane.resource_kind <> 'position'
            or v_lane.parent_lane_id is distinct from p_root_lane_id))
       or (v_lane.resource_kind = 'position' and
           ((v_resource.value->>'whole_lane_bookable')::boolean
            or (v_resource.value->>'positions_bookable')::boolean))
       or (v_resource.value->>'max_shooters')::integer < 1
       or (v_resource.value->>'max_people_online')::integer < 1
       or (v_resource.value->>'max_people_online')::integer
            > (v_resource.value->>'max_shooters')::integer then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'invalid_hierarchy',
        'root_lane_id', p_root_lane_id,
        'previous_version', v_version,
        'configuration_version', v_version
      );
    end if;

    if exists (
         select 1
         from pg_catalog.jsonb_array_elements(v_resource.value->'durations_minutes') as duration(value)
         where (duration.value #>> '{}')::integer <= 0
            or (duration.value #>> '{}')::integer > 1440
            or (duration.value #>> '{}')::integer % v_lane.booking_step_minutes <> 0
       )
       or ((v_resource.value->>'online_bookable')::boolean
           and pg_catalog.jsonb_array_length(v_resource.value->'durations_minutes') = 0) then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'invalid_configuration',
        'root_lane_id', p_root_lane_id,
        'previous_version', v_version,
        'configuration_version', v_version
      );
    end if;

    v_previous_max := null;
    v_group_count := 0;
    for v_price in
      select
        price.value->>'day_group' as day_group,
        (price.value->>'min_shooters')::integer as min_shooters,
        (price.value->>'max_shooters')::integer as max_shooters,
        (price.value->>'hourly_price')::numeric as hourly_price
      from pg_catalog.jsonb_array_elements(v_resource.value->'pricing') as price(value)
      order by price.value->>'day_group',
               (price.value->>'min_shooters')::integer,
               (price.value->>'max_shooters')::integer
    loop
      if v_price.min_shooters < 1
         or v_price.max_shooters < v_price.min_shooters
         or v_price.max_shooters > (v_resource.value->>'max_people_online')::integer
         or v_price.hourly_price < 0
         or v_price.hourly_price > 9999999999.99
         or v_price.hourly_price <> pg_catalog.round(v_price.hourly_price, 2) then
        return pg_catalog.jsonb_build_object(
          'ok', false, 'changed', false, 'code', 'invalid_configuration',
          'root_lane_id', p_root_lane_id,
          'previous_version', v_version,
          'configuration_version', v_version
        );
      end if;
    end loop;

    if pg_catalog.jsonb_array_length(v_resource.value->'pricing') > 0 then
      if exists (
           with parsed as (
             select price.value->>'day_group' as day_group,
                    (price.value->>'min_shooters')::integer as min_shooters,
                    (price.value->>'max_shooters')::integer as max_shooters,
                    pg_catalog.lag((price.value->>'max_shooters')::integer) over (
                      partition by price.value->>'day_group'
                      order by (price.value->>'min_shooters')::integer,
                               (price.value->>'max_shooters')::integer
                    ) as previous_max
             from pg_catalog.jsonb_array_elements(v_resource.value->'pricing') as price(value)
           )
           select 1 from parsed
           where (previous_max is null and min_shooters <> 1)
              or (previous_max is not null and min_shooters <> previous_max + 1)
         )
         or (select pg_catalog.count(*) from (
               select price.value->>'day_group'
               from pg_catalog.jsonb_array_elements(v_resource.value->'pricing') as price(value)
               group by price.value->>'day_group'
               having pg_catalog.max((price.value->>'max_shooters')::integer)
                      = (v_resource.value->>'max_people_online')::integer
             ) as valid_group) <> 2 then
        return pg_catalog.jsonb_build_object(
          'ok', false, 'changed', false, 'code', 'invalid_configuration',
          'root_lane_id', p_root_lane_id,
          'previous_version', v_version,
          'configuration_version', v_version
        );
      end if;
    elsif (v_resource.value->>'online_bookable')::boolean then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'invalid_configuration',
        'root_lane_id', p_root_lane_id,
        'previous_version', v_version,
        'configuration_version', v_version
      );
    end if;

    if (v_resource.value->>'online_bookable')::boolean
       and not (v_resource.value->>'is_active')::boolean then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'invalid_configuration',
        'root_lane_id', p_root_lane_id,
        'previous_version', v_version,
        'configuration_version', v_version
      );
    end if;
  end loop;

  if (v_root_target->>'online_bookable')::boolean
     and not (v_root_target->>'whole_lane_bookable')::boolean then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_configuration',
      'root_lane_id', p_root_lane_id,
      'previous_version', v_version,
      'configuration_version', v_version
    );
  end if;

  if not (v_root_target->>'is_active')::boolean
     and ((v_root_target->>'online_bookable')::boolean
          or exists (
            select 1 from pg_catalog.jsonb_array_elements(v_target) as item(value)
            where item.value->>'lane_id' <> p_root_lane_id::text
              and ((item.value->>'is_active')::boolean
                   or (item.value->>'online_bookable')::boolean)
          )) then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_configuration',
      'root_lane_id', p_root_lane_id,
      'previous_version', v_version,
      'configuration_version', v_version
    );
  end if;

  if exists (
       select 1 from pg_catalog.jsonb_array_elements(v_target) as item(value)
       where item.value->>'lane_id' <> p_root_lane_id::text
         and (item.value->>'is_active')::boolean
         and not (v_root_target->>'is_active')::boolean
     )
     or exists (
       select 1 from pg_catalog.jsonb_array_elements(v_target) as item(value)
       where item.value->>'lane_id' <> p_root_lane_id::text
         and (item.value->>'online_bookable')::boolean
         and (not (v_root_target->>'is_active')::boolean
              or not (v_root_target->>'positions_bookable')::boolean)
     ) then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_configuration',
      'root_lane_id', p_root_lane_id,
      'previous_version', v_version,
      'configuration_version', v_version
    );
  end if;

  if (v_root_target->>'positions_bookable')::boolean
     and not exists (
       select 1 from pg_catalog.jsonb_array_elements(v_target) as item(value)
       where item.value->>'lane_id' <> p_root_lane_id::text
         and (item.value->>'is_active')::boolean
         and (item.value->>'online_bookable')::boolean
         and pg_catalog.jsonb_array_length(item.value->'durations_minutes') > 0
         and pg_catalog.jsonb_array_length(item.value->'pricing') > 0
     ) then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_configuration',
      'root_lane_id', p_root_lane_id,
      'previous_version', v_version,
      'configuration_version', v_version
    );
  end if;

  select coalesce(pg_catalog.sum((item.value->>'max_shooters')::integer), 0)
  into v_position_capacity
  from pg_catalog.jsonb_array_elements(v_target) as item(value)
  where item.value->>'lane_id' <> p_root_lane_id::text
    and (item.value->>'is_active')::boolean
    and (item.value->>'online_bookable')::boolean;

  if (v_root_target->>'positions_bookable')::boolean
     and v_position_capacity > (v_root_target->>'max_shooters')::integer then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_configuration',
      'root_lane_id', p_root_lane_id,
      'previous_version', v_version,
      'configuration_version', v_version
    );
  end if;

  if v_current = v_target then
    return pg_catalog.jsonb_build_object(
      'ok', true, 'changed', false, 'code', 'no_change',
      'root_lane_id', p_root_lane_id,
      'previous_version', v_version,
      'configuration_version', v_version
    );
  end if;

  for v_resource in
    select item.value
    from pg_catalog.jsonb_array_elements(v_target) as item(value)
  loop
    select pg_catalog.max(reservation.shooters_count)
    into v_max_obligation
    from public.reservations as reservation
    where reservation.lane_id = (v_resource.value->>'lane_id')::uuid
      and reservation.tenant_id = v_tenant_id
      and pg_catalog.lower(pg_catalog.btrim(reservation.reservation_status)) not in (
        'completed','no_show','cancelled','canceled',
        'cancelled_by_admin','cancelled_by_user'
      )
      and (reservation.reservation_date, reservation.end_time) >
          ((v_now at time zone 'Europe/Warsaw')::date,
           (v_now at time zone 'Europe/Warsaw')::time);

    if v_max_obligation is not null
       and (v_resource.value->>'max_shooters')::integer < v_max_obligation then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'reservation_capacity_conflict',
        'root_lane_id', p_root_lane_id,
        'previous_version', v_version,
        'configuration_version', v_version
      );
    end if;
  end loop;

  if v_root.is_active and not (v_root_target->>'is_active')::boolean then
    v_affected_ids := v_family_ids;
  else
    if v_root.whole_lane_bookable
       and not (v_root_target->>'whole_lane_bookable')::boolean then
      v_affected_ids := pg_catalog.array_append(v_affected_ids, p_root_lane_id);
    end if;
    if v_root.positions_bookable
       and not (v_root_target->>'positions_bookable')::boolean then
      select coalesce(pg_catalog.array_agg(id order by id), '{}'::uuid[])
      into v_affected_ids
      from (
        select distinct id from pg_catalog.unnest(
          v_affected_ids || array(
            select child.id from public.shooting_lanes as child
            where child.parent_lane_id = p_root_lane_id
              and child.tenant_id = v_tenant_id
          )
        ) as ids(id)
      ) as affected;
    end if;
    select coalesce(pg_catalog.array_agg(id order by id), '{}'::uuid[])
    into v_affected_ids
    from (
      select distinct (item.value->>'lane_id')::uuid as id
      from pg_catalog.jsonb_array_elements(v_target) as item(value)
      join public.shooting_lanes as current_lane
        on current_lane.id = (item.value->>'lane_id')::uuid
       and current_lane.tenant_id = v_tenant_id
      where current_lane.is_active
        and not (item.value->>'is_active')::boolean
      union
      select id from pg_catalog.unnest(v_affected_ids) as ids(id)
    ) as affected;
  end if;

  if pg_catalog.cardinality(v_affected_ids) > 0 then
    select pg_catalog.count(*) into v_future_reservations
    from public.reservations as reservation
    where reservation.lane_id = any(v_affected_ids)
      and reservation.tenant_id = v_tenant_id
      and pg_catalog.lower(pg_catalog.btrim(reservation.reservation_status)) not in (
        'completed','no_show','cancelled','canceled',
        'cancelled_by_admin','cancelled_by_user'
      )
      and (reservation.reservation_date, reservation.end_time) >
          ((v_now at time zone 'Europe/Warsaw')::date,
           (v_now at time zone 'Europe/Warsaw')::time);

    select pg_catalog.count(*) into v_future_blocks
    from public.lane_blocks as lane_block
    where lane_block.lane_id = any(v_affected_ids)
      and lane_block.tenant_id = v_tenant_id
      and lane_block.is_active
      and (lane_block.block_date, lane_block.end_time) >
          ((v_now at time zone 'Europe/Warsaw')::date,
           (v_now at time zone 'Europe/Warsaw')::time);

    select pg_catalog.count(distinct event_record.id) into v_future_events
    from public.events as event_record
    join public.event_lanes as event_lane on event_lane.event_id = event_record.id
    where event_lane.lane_id = any(v_affected_ids)
      and event_lane.tenant_id = v_tenant_id
      and event_record.tenant_id = v_tenant_id
      and event_record.is_active
      and (event_record.event_date, event_record.end_time) >
          ((v_now at time zone 'Europe/Warsaw')::date,
           (v_now at time zone 'Europe/Warsaw')::time);
  end if;

  if not p_acknowledge_future_obligations
     and (v_future_reservations + v_future_blocks + v_future_events) > 0 then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'confirmation_required',
      'root_lane_id', p_root_lane_id,
      'previous_version', v_version,
      'configuration_version', v_version,
      'future_reservations_count', v_future_reservations,
      'future_lane_blocks_count', v_future_blocks,
      'future_events_count', v_future_events
    );
  end if;

  begin
    if v_name_only then
      for v_resource in
        select item.value
        from pg_catalog.jsonb_array_elements(v_target) as item(value)
        order by (item.value->>'lane_id')::uuid
      loop
        update public.shooting_lanes
        set name = v_resource.value->>'name'
        where id = (v_resource.value->>'lane_id')::uuid
          and tenant_id = v_tenant_id
          and name is distinct from v_resource.value->>'name';
      end loop;
    else
    for v_resource in
      select item.value
      from pg_catalog.jsonb_array_elements(v_target) as item(value)
      order by (item.value->>'lane_id')::uuid
    loop
      select lane.* into v_lane from public.shooting_lanes as lane
      where lane.id = (v_resource.value->>'lane_id')::uuid
      and lane.tenant_id = v_tenant_id;
      select rule.* into v_rule from public.lane_booking_rules as rule
      where rule.lane_id = v_lane.id;

      if (v_resource.value->>'max_shooters')::integer < v_rule.max_people_online then
        update public.lane_booking_rules
        set online_bookable = (v_resource.value->>'online_bookable')::boolean,
            max_people_online = (v_resource.value->>'max_people_online')::integer
        where lane_id = v_lane.id;
      end if;

      update public.shooting_lanes
      set name = v_resource.value->>'name',
          is_active = (v_resource.value->>'is_active')::boolean,
          whole_lane_bookable = (v_resource.value->>'whole_lane_bookable')::boolean,
          positions_bookable = (v_resource.value->>'positions_bookable')::boolean,
          max_shooters = (v_resource.value->>'max_shooters')::integer
      where id = v_lane.id;

      update public.lane_booking_rules
      set online_bookable = (v_resource.value->>'online_bookable')::boolean,
          max_people_online = (v_resource.value->>'max_people_online')::integer
      where lane_id = v_lane.id;

      delete from public.lane_booking_durations where lane_id = v_lane.id;
      insert into public.lane_booking_durations(
        lane_id, duration_minutes, display_order, is_active
      )
      select v_lane.id, (duration.value #>> '{}')::integer,
             duration.ordinality * 10, true
      from pg_catalog.jsonb_array_elements(v_resource.value->'durations_minutes')
        with ordinality as duration(value, ordinality)
      order by (duration.value #>> '{}')::integer;

      update public.lane_pricing_rules set is_active = false
      where lane_id = v_lane.id and is_active;

      with target_price as (
        select
          price.value->>'day_group' as day_group,
          (price.value->>'min_shooters')::integer as min_shooters,
          (price.value->>'max_shooters')::integer as max_shooters,
          pg_catalog.btrim(price.value->>'label') as label,
          (price.value->>'hourly_price')::numeric(12,2) as hourly_price,
          pg_catalog.row_number() over (
            partition by price.value->>'day_group'
            order by (price.value->>'min_shooters')::integer,
                     (price.value->>'max_shooters')::integer,
                     pg_catalog.btrim(price.value->>'label')
          ) * 10 as display_order
        from pg_catalog.jsonb_array_elements(v_resource.value->'pricing') as price(value)
      ), reusable as (
        select existing.id, target_price.display_order,
               pg_catalog.row_number() over (
                 partition by target_price.day_group, target_price.min_shooters,
                              target_price.max_shooters, target_price.label,
                              target_price.hourly_price
                 order by existing.id
               ) as candidate_order
        from target_price
        join public.lane_pricing_rules as existing
          on existing.lane_id = v_lane.id
         and existing.day_group = target_price.day_group
         and existing.min_shooters = target_price.min_shooters
         and existing.max_shooters = target_price.max_shooters
         and existing.label = target_price.label
         and existing.hourly_price = target_price.hourly_price
      )
      update public.lane_pricing_rules as existing
      set display_order = reusable.display_order, is_active = true
      from reusable
      where existing.id = reusable.id and reusable.candidate_order = 1;

      with target_price as (
        select
          price.value->>'day_group' as day_group,
          (price.value->>'min_shooters')::integer as min_shooters,
          (price.value->>'max_shooters')::integer as max_shooters,
          pg_catalog.btrim(price.value->>'label') as label,
          (price.value->>'hourly_price')::numeric(12,2) as hourly_price,
          pg_catalog.row_number() over (
            partition by price.value->>'day_group'
            order by (price.value->>'min_shooters')::integer,
                     (price.value->>'max_shooters')::integer,
                     pg_catalog.btrim(price.value->>'label')
          ) * 10 as display_order
        from pg_catalog.jsonb_array_elements(v_resource.value->'pricing') as price(value)
      )
      insert into public.lane_pricing_rules(
        lane_id, day_group, min_shooters, max_shooters,
        label, hourly_price, display_order, is_active
      )
      select v_lane.id, target_price.day_group,
             target_price.min_shooters,
             target_price.max_shooters,
             target_price.label,
             target_price.hourly_price,
             target_price.display_order,
             true
      from target_price
      where not exists (
        select 1 from public.lane_pricing_rules as existing
        where existing.lane_id = v_lane.id
          and existing.day_group = target_price.day_group
          and existing.min_shooters = target_price.min_shooters
          and existing.max_shooters = target_price.max_shooters
          and existing.label = target_price.label
          and existing.hourly_price = target_price.hourly_price
          and existing.is_active
      );
    end loop;
    end if;

    update public.lane_booking_family_configuration_versions
    set configuration_version = configuration_version + 1,
        updated_at = v_now
    where root_lane_id = p_root_lane_id
    returning configuration_version into v_version;

    insert into public.audit_logs(
      tenant_id, actor_user_id, actor_name, actor_role, action,
      target_type, target_id, target_name, details
    ) values (
      v_tenant_id, v_actor_id,
      coalesce(
        nullif(pg_catalog.btrim(pg_catalog.concat_ws(' ', v_actor.first_name, v_actor.last_name)), ''),
        nullif(pg_catalog.btrim(v_actor.full_name), ''),
        'Administrator'
      ),
      'admin', 'lane_booking_family_configuration_updated',
      'lane_booking_family', p_root_lane_id, v_root_target->>'name',
      pg_catalog.jsonb_build_object(
        'previous_version', p_expected_version,
        'new_version', v_version,
        'before', v_current,
        'after', v_target,
        'renamed_resources', v_renamed_resources
      )
    );
  exception when others then
    raise exception 'Lane family configuration update failed.' using errcode = 'P0001';
  end;

  return pg_catalog.jsonb_build_object(
    'ok', true, 'changed', true, 'code', 'updated',
    'root_lane_id', p_root_lane_id,
    'previous_version', p_expected_version,
    'configuration_version', v_version
  );
end;
$function$;

create function public.tenant_setup_get_lane_configuration_v1(p_tenant_id uuid)
returns jsonb language plpgsql security definer set search_path='pg_catalog','public','pg_temp' as $function$
begin
 perform public.lock_tenant_draft_setup_core_v1(p_tenant_id);
 return public.tenant_draft_lane_configuration_core_v1(p_tenant_id);
end;$function$;
create function public.tenant_setup_create_lane_family_v1(p_tenant_id uuid,p_family jsonb)
returns jsonb language plpgsql security definer set search_path='pg_catalog','public','pg_temp' as $function$
begin
 perform public.lock_tenant_draft_setup_core_v1(p_tenant_id);
 return public.tenant_draft_create_lane_family_core_v1(p_tenant_id,p_family);
end;$function$;
create function public.tenant_setup_set_lane_configuration_v1(p_tenant_id uuid,p_root_lane_id uuid,p_expected_version bigint,p_resources jsonb)
returns jsonb language plpgsql security definer set search_path='pg_catalog','public','pg_temp' as $function$
begin
 perform public.lock_tenant_draft_setup_core_v1(p_tenant_id);
 if not exists(select 1 from public.shooting_lanes where id=p_root_lane_id and tenant_id=p_tenant_id) then
  raise exception 'Draft configuration not allowed' using errcode='42501'; end if;
 return public.tenant_draft_set_lane_configuration_core_v1(p_root_lane_id,p_expected_version,p_resources,false);
end;$function$;

CREATE OR REPLACE FUNCTION public.enforce_tenant_feature_write_v1()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
declare v_feature text; v_tenant uuid; v_requires boolean:=true;
begin
  -- Direct database-owner maintenance and migration fixtures are outside the app boundary.
  -- Production PostgREST sessions use `authenticator`; focused tests opt in explicitly.
  if session_user='postgres' and current_setting('app.product10d_test_enforce',true) is distinct from 'on' then
    return coalesce(new,old);
  end if;
  v_tenant:=coalesce(new.tenant_id,old.tenant_id);
  if tg_table_name='reservations' then
    if tg_op<>'INSERT' then return new; end if; v_feature:='booking';
  elsif tg_table_name='event_registrations' then
    if tg_op<>'INSERT' then return new; end if; v_feature:='events';
  elsif tg_table_name='events' then
    if tg_op='DELETE' or (tg_op='UPDATE' and old.is_active and not new.is_active) then return coalesce(new,old); end if; v_feature:='events';
  elsif tg_table_name='lane_blocks' then
    if tg_op='DELETE' or (tg_op='UPDATE' and not new.is_active) then return coalesce(new,old); end if; v_feature:='lane_blocks';
  elsif tg_table_name='shooting_lanes' then
    if public.tenant_draft_setup_role_core_v1(v_tenant)='admin' then return coalesce(new,old); end if;
    if tg_op='DELETE' or (tg_op='UPDATE' and old.is_active and not new.is_active) then return coalesce(new,old); end if; v_feature:='booking';
  else v_requires:=false;
  end if;
  if v_requires and not public.tenant_has_feature_v1(v_tenant,v_feature) then
    raise exception using errcode='42501',message='feature_not_available';
  end if;
  return coalesce(new,old);
end;
$function$;

create function public.tenant_onboarding_readiness_core_v2(p_tenant_id uuid)
returns jsonb language sql stable set search_path='pg_catalog','public','pg_temp' as $function$
with baseline as (select public.platform_tenant_readiness_core_v1(p_tenant_id) flags),
booking as (select public.tenant_setup_has_feature_core_v1(p_tenant_id,'booking') required,
 exists(select 1 from public.get_public_booking_configuration_v1__saas9d4e_core(p_tenant_id) c
  where c.effective_online_bookable) configured),
ready as(select coalesce((select bool_and(value='true'::jsonb) from jsonb_each(flags)),false) identity_ready,
 flags,required,configured from baseline cross join booking)
select jsonb_build_object('create_ready',identity_ready,'activation_ready',identity_ready and (not required or configured),
 'public_ready',identity_ready and (not required or configured), 'booking_ready',required and configured,
 'booking_required',required,'booking_hours','08:00–20:00','checks',flags,
 'publication_gate_enforced',false,'legal_launch_gate','deferred') from ready;
$function$;
create function public.platform_get_tenant_onboarding_readiness_v2(p_tenant_id uuid)
returns jsonb language plpgsql stable security definer set search_path='pg_catalog','public','pg_temp' as $function$
begin
 if not public.is_platform_admin_v1() then raise exception 'Not authorized' using errcode='42501'; end if;
 if not exists(select 1 from public.tenants where id=p_tenant_id) then raise exception 'Tenant unavailable' using errcode='22023'; end if;
 return public.tenant_onboarding_readiness_core_v2(p_tenant_id);
end;$function$;

alter function public.onboarding_admin_eligible_core_v1(uuid) owner to postgres;
revoke all on function public.onboarding_admin_eligible_core_v1(uuid) from public,anon,authenticated,service_role;

alter function public.onboarding_lock_admin_core_v1(uuid) owner to postgres;
revoke all on function public.onboarding_lock_admin_core_v1(uuid) from public,anon,authenticated,service_role;

alter function public.tenant_draft_setup_role_core_v1(uuid) owner to postgres;
revoke all on function public.tenant_draft_setup_role_core_v1(uuid) from public,anon,authenticated,service_role;

alter function public.lock_tenant_draft_setup_core_v1(uuid) owner to postgres;
revoke all on function public.lock_tenant_draft_setup_core_v1(uuid) from public,anon,authenticated,service_role;

alter function public.tenant_draft_lane_resources_core_v1(uuid) owner to postgres;
revoke all on function public.tenant_draft_lane_resources_core_v1(uuid) from public,anon,authenticated,service_role;

alter function public.tenant_draft_lane_configuration_core_v1(uuid) owner to postgres;
revoke all on function public.tenant_draft_lane_configuration_core_v1(uuid) from public,anon,authenticated,service_role;

alter function public.tenant_draft_create_lane_family_core_v1(uuid,jsonb) owner to postgres;
revoke all on function public.tenant_draft_create_lane_family_core_v1(uuid,jsonb) from public,anon,authenticated,service_role;

alter function public.tenant_draft_set_lane_configuration_core_v1(uuid,bigint,jsonb,boolean) owner to postgres;
revoke all on function public.tenant_draft_set_lane_configuration_core_v1(uuid,bigint,jsonb,boolean) from public,anon,authenticated,service_role;

alter function public.tenant_onboarding_readiness_core_v2(uuid) owner to postgres;
revoke all on function public.tenant_onboarding_readiness_core_v2(uuid) from public,anon,authenticated,service_role;

alter function public.platform_create_tenant_bundle_v2(text,text,text,text,text,uuid,uuid) owner to postgres;
revoke all on function public.platform_create_tenant_bundle_v2(text,text,text,text,text,uuid,uuid) from public,anon,authenticated,service_role;

grant execute on function public.platform_create_tenant_bundle_v2(text,text,text,text,text,uuid,uuid) to authenticated;

alter function public.tenant_setup_get_lane_configuration_v1(uuid) owner to postgres;
revoke all on function public.tenant_setup_get_lane_configuration_v1(uuid) from public,anon,authenticated,service_role;

grant execute on function public.tenant_setup_get_lane_configuration_v1(uuid) to authenticated;

alter function public.tenant_setup_create_lane_family_v1(uuid,jsonb) owner to postgres;
revoke all on function public.tenant_setup_create_lane_family_v1(uuid,jsonb) from public,anon,authenticated,service_role;

grant execute on function public.tenant_setup_create_lane_family_v1(uuid,jsonb) to authenticated;

alter function public.tenant_setup_set_lane_configuration_v1(uuid,uuid,bigint,jsonb) owner to postgres;
revoke all on function public.tenant_setup_set_lane_configuration_v1(uuid,uuid,bigint,jsonb) from public,anon,authenticated,service_role;

grant execute on function public.tenant_setup_set_lane_configuration_v1(uuid,uuid,bigint,jsonb) to authenticated;

alter function public.platform_get_tenant_onboarding_readiness_v2(uuid) owner to postgres;
revoke all on function public.platform_get_tenant_onboarding_readiness_v2(uuid) from public,anon,authenticated,service_role;

grant execute on function public.platform_get_tenant_onboarding_readiness_v2(uuid) to authenticated;
