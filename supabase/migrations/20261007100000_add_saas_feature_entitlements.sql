-- PRODUCT-10D: closed SaaS plan/feature foundation and effective feature enforcement.
set lock_timeout = '5s';
set statement_timeout = '120s';

do $preflight$
begin
  if (select count(*) from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prosecdef) <> 80 then
    raise exception 'PRODUCT-10D preflight failed: SECURITY DEFINER baseline differs';
  end if;
  if (select count(*) from public.tenants where slug='csk' and status='active') <> 1 then
    raise exception 'PRODUCT-10D preflight failed: CSK tenant is not unique and active';
  end if;
  if pg_catalog.to_regclass('public.saas_features') is not null
     or pg_catalog.to_regclass('public.saas_plans') is not null
     or pg_catalog.to_regclass('public.saas_plan_features') is not null
     or pg_catalog.to_regclass('public.tenant_plan_assignments') is not null then
    raise exception 'PRODUCT-10D preflight failed: entitlement schema already exists';
  end if;
end;
$preflight$;

create table public.saas_features (
  feature_key text primary key,
  description text not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  constraint saas_features_key_format check (feature_key ~ '^[a-z][a-z0-9_]{1,62}$')
);

create table public.saas_plans (
  id uuid primary key default gen_random_uuid(),
  plan_key text not null unique,
  status text not null default 'active',
  created_at timestamptz not null default now(),
  constraint saas_plans_key_format check (plan_key ~ '^[a-z][a-z0-9_]{1,62}$'),
  constraint saas_plans_status check (status in ('active','inactive'))
);

create table public.saas_plan_features (
  plan_id uuid not null references public.saas_plans(id) on delete cascade,
  feature_key text not null references public.saas_features(feature_key) on delete restrict,
  created_at timestamptz not null default now(),
  primary key (plan_id, feature_key)
);

create table public.tenant_plan_assignments (
  tenant_id uuid primary key references public.tenants(id) on delete restrict,
  plan_id uuid not null references public.saas_plans(id) on delete restrict,
  status text not null default 'active',
  assigned_at timestamptz not null default now(),
  constraint tenant_plan_assignments_status check (status in ('active','suspended','ended'))
);

alter table public.saas_features enable row level security;
alter table public.saas_plans enable row level security;
alter table public.saas_plan_features enable row level security;
alter table public.tenant_plan_assignments enable row level security;
revoke all on table public.saas_features,public.saas_plans,public.saas_plan_features,public.tenant_plan_assignments from public,anon,authenticated,service_role;

insert into public.saas_features(feature_key,description) values
  ('booking','Public booking, reservations, lane configuration and public pricing'),
  ('events','Public events, registrations, waitlist and event management'),
  ('instructors','Public instructor shooting presentation'),
  ('staff','Tenant staff and user operations'),
  ('checkin','Reservation check-in operations'),
  ('reports','Operational reservation reports and exports'),
  ('lane_blocks','Lane block management'),
  ('advanced_calendar','Staff calendar views and feeds'),
  ('branding','Future advanced branding beyond baseline tenant identity'),
  ('custom_domain','Future custom-domain capability; no DNS authority');

insert into public.saas_plans(plan_key,status) values ('current_full_v1','active'),('booking_only_v1','active');
insert into public.saas_plan_features(plan_id,feature_key)
select plan.id,feature.feature_key from public.saas_plans plan cross join public.saas_features feature
where plan.plan_key='current_full_v1';
insert into public.saas_plan_features(plan_id,feature_key)
select plan.id,'booking' from public.saas_plans plan where plan.plan_key='booking_only_v1';
insert into public.tenant_plan_assignments(tenant_id,plan_id,status)
select tenant.id,plan.id,'active' from public.tenants tenant cross join public.saas_plans plan
where tenant.slug='csk' and tenant.status='active' and plan.plan_key='current_full_v1';

create function public.tenant_has_feature_v1(p_tenant_id uuid,p_feature_key text)
returns boolean language plpgsql stable security definer
set search_path=pg_catalog,public,pg_temp
as $function$
begin
  -- Database-owner migration/test fixtures are not application traffic.
  if session_user='postgres' and current_setting('app.product10d_test_enforce',true) is distinct from 'on' then return true; end if;
  return coalesce((select exists(
    select 1 from public.tenant_plan_assignments assignment
    join public.saas_plans plan on plan.id=assignment.plan_id and plan.status='active'
    join public.saas_plan_features plan_feature on plan_feature.plan_id=plan.id
    join public.saas_features feature on feature.feature_key=plan_feature.feature_key and feature.active
    join public.tenants tenant on tenant.id=assignment.tenant_id and tenant.status='active'
    where assignment.tenant_id=p_tenant_id and assignment.status='active'
      and feature.feature_key=p_feature_key
  )),false);
end;
$function$;
alter function public.tenant_has_feature_v1(uuid,text) owner to postgres;
revoke all on function public.tenant_has_feature_v1(uuid,text) from public,anon,authenticated,service_role;
grant execute on function public.tenant_has_feature_v1(uuid,text) to service_role;

create function public.get_my_tenant_feature_access_v1(p_tenant_id uuid,p_feature_key text)
returns boolean language plpgsql stable security definer
set search_path=pg_catalog,public,auth,pg_temp
as $function$
begin
  if session_user='postgres' and current_setting('app.product10d_test_enforce',true) is distinct from 'on' then return true; end if;
  if auth.uid() is null or not exists(
    select 1 from public.tenant_memberships membership
    join public.tenants tenant on tenant.id=membership.tenant_id and tenant.status='active'
    where membership.tenant_id=p_tenant_id and membership.user_id=auth.uid() and membership.status='active'
  ) then return false; end if;
  return public.tenant_has_feature_v1(p_tenant_id,p_feature_key);
end;
$function$;
alter function public.get_my_tenant_feature_access_v1(uuid,text) owner to postgres;
revoke all on function public.get_my_tenant_feature_access_v1(uuid,text) from public,anon,authenticated,service_role;
grant execute on function public.get_my_tenant_feature_access_v1(uuid,text) to authenticated;

create function public.get_my_tenant_features_v1(p_tenant_id uuid)
returns text[] language plpgsql stable security definer
set search_path=pg_catalog,public,auth,pg_temp
as $function$
begin
  if auth.uid() is null or not exists(
    select 1 from public.tenant_memberships membership
    join public.tenants tenant on tenant.id=membership.tenant_id and tenant.status='active'
    where membership.tenant_id=p_tenant_id and membership.user_id=auth.uid() and membership.status='active'
  ) then return array[]::text[]; end if;
  return coalesce((select array_agg(feature.feature_key order by feature.feature_key)
    from public.tenant_plan_assignments assignment
    join public.saas_plans plan on plan.id=assignment.plan_id and plan.status='active'
    join public.saas_plan_features plan_feature on plan_feature.plan_id=plan.id
    join public.saas_features feature on feature.feature_key=plan_feature.feature_key and feature.active
    where assignment.tenant_id=p_tenant_id and assignment.status='active'),array[]::text[]);
end;
$function$;
alter function public.get_my_tenant_features_v1(uuid) owner to postgres;
revoke all on function public.get_my_tenant_features_v1(uuid) from public,anon,authenticated,service_role;
grant execute on function public.get_my_tenant_features_v1(uuid) to authenticated;

create function public.get_public_tenant_feature_access_v1(p_tenant_id uuid,p_feature_key text)
returns boolean language plpgsql stable security definer
set search_path=pg_catalog,public,pg_temp
as $function$
begin
  if p_feature_key not in ('booking','events','instructors') or not exists(
    select 1 from public.tenants tenant
    where tenant.id=p_tenant_id and tenant.status='active'
  ) then return false; end if;
  if session_user='postgres' and current_setting('app.product10d_test_enforce',true) is distinct from 'on' then return true; end if;
  if not exists(
    select 1 from public.tenant_public_profiles profile
    where profile.tenant_id=p_tenant_id and profile.is_public
  ) then return false; end if;
  return public.tenant_has_feature_v1(p_tenant_id,p_feature_key);
end;
$function$;
alter function public.get_public_tenant_feature_access_v1(uuid,text) owner to postgres;
revoke all on function public.get_public_tenant_feature_access_v1(uuid,text) from public,anon,authenticated,service_role;
grant execute on function public.get_public_tenant_feature_access_v1(uuid,text) to anon,authenticated;

-- Public operational readers are fail-closed even when called directly.
create or replace function public.get_public_booking_configuration_v2(p_tenant_id uuid)
returns table(lane_id uuid,parent_lane_id uuid,resource_kind text,name text,display_name text,display_order integer,
  effective_online_bookable boolean,whole_lane_bookable boolean,positions_bookable boolean,max_people_online integer,
  booking_step_minutes integer,currency_code text,durations_minutes integer[],pricing jsonb)
language plpgsql stable security definer set search_path=pg_catalog,public,pg_temp
as $function$
begin
  if not public.get_public_tenant_feature_access_v1(p_tenant_id,'booking') then
    raise exception 'Moduł jest niedostępny.' using errcode='42501';
  end if;
  return query select * from public.get_public_booking_configuration_v1__saas9d4e_core(p_tenant_id);
end;
$function$;

create or replace function public.get_public_event_list_v3(p_tenant_id uuid,p_search text default null,p_scope text default 'upcoming',p_page integer default 1,p_page_size integer default 20)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public,pg_temp
as $function$
begin
  if not public.get_public_tenant_feature_access_v1(p_tenant_id,'events') then
    return pg_catalog.jsonb_build_object('ok',false,'code','not_available');
  end if;
  return public.get_public_event_list_v2__saas9d2b2_core(p_tenant_id,p_search,p_scope,p_page,p_page_size);
end;
$function$;

create or replace function public.get_public_event_availability_v2(p_tenant_id uuid)
returns table(event_id uuid,title text,description text,event_date date,start_time time without time zone,end_time time without time zone,location text,price numeric,max_participants integer,registered_count integer,reserve_count integer,available_spots integer,sold_out boolean)
language plpgsql stable security definer set search_path=pg_catalog,public,pg_temp
as $function$
begin
  if not public.get_public_tenant_feature_access_v1(p_tenant_id,'events') then
    raise exception 'Moduł jest niedostępny.' using errcode='42501';
  end if;
  return query select * from public.get_public_event_availability_v1__saas9d2b2_core(p_tenant_id);
end;
$function$;

create or replace function public.admin_get_lane_booking_configuration_v3(p_tenant_id uuid)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public,pg_temp as $function$
begin
  if not public.get_my_tenant_feature_access_v1(p_tenant_id,'booking') then raise exception using errcode='42501',message='feature_not_available'; end if;
  return public.admin_get_lane_booking_configuration_v3__saas9ec2b_core(p_tenant_id);
end;
$function$;

create or replace function public.admin_create_lane_booking_family_v2(p_tenant_id uuid,p_family jsonb)
returns jsonb language plpgsql volatile security definer set search_path=pg_catalog,public,pg_temp as $function$
begin
  if not public.get_my_tenant_feature_access_v1(p_tenant_id,'booking') then raise exception using errcode='42501',message='feature_not_available'; end if;
  return public.admin_create_lane_booking_family_v2__saas9ec2b_core(p_tenant_id,p_family);
end;
$function$;

-- Insert a membership-aware entitlement guard in selected-tenant staff RPCs.
do $guard_staff_rpcs$
declare item record; definition text; marker integer; insertion text;
begin
  for item in select * from (values
    ('public.admin_list_events_v2(uuid,text,text,text,integer,integer)','events'),
    ('public.admin_create_event_v3(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])','events'),
    ('public.admin_list_event_registrations_v2(uuid,uuid,text,text,integer,integer)','events'),
    ('public.admin_update_event_v3(uuid,uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])','events'),
    ('public.admin_set_event_active_v3(uuid,uuid,boolean)','events'),
    ('public.approve_event_registration_v2(uuid,uuid)','events'),
    ('public.cancel_event_registration_v2(uuid,uuid)','events'),
    ('public.mark_event_registration_paid_v2(uuid,uuid)','events'),
    ('public.admin_get_reservation_report_v3(uuid,date,date,uuid,text,text,text,integer,integer)','reports'),
    ('public.admin_get_reservation_report_export_v2(uuid,date,date,uuid,text,text,text)','reports'),
    ('public.admin_list_users_v2(uuid,integer,integer,text,text,text,text)','staff'),
    ('public.admin_set_user_role_v2(uuid,uuid,text)','staff'),
    ('public.admin_set_user_note_v2(uuid,uuid,text)','staff'),
    ('public.update_tenant_profile_verification_v2(uuid,uuid,text,text)','staff'),
    ('public.update_tenant_profile_identity_v2(uuid,uuid,text,text)','staff'),
    ('public.update_tenant_profile_contact_details_v2(uuid,uuid,text,text,text,text,text,text)','staff'),
    ('public.admin_set_lane_booking_family_configuration_v3(uuid,uuid,bigint,jsonb,boolean)','booking')
  ) value(signature,feature_key)
  loop
    if pg_catalog.to_regprocedure(item.signature) is null then raise exception 'PRODUCT-10D RPC missing: %',item.signature; end if;
    definition:=replace(replace(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(item.signature)),E'\r\n',E'\n'),E'\r',E'\n');
    if pg_catalog.strpos(definition,'PRODUCT-10D entitlement guard')>0 then raise exception 'PRODUCT-10D RPC already guarded: %',item.signature; end if;
    marker:=pg_catalog.strpos(pg_catalog.lower(definition),E'\nbegin\n');
    if marker=0 then raise exception 'PRODUCT-10D RPC main block not found: %',item.signature; end if;
    insertion:=pg_catalog.substr(definition,marker,7)||pg_catalog.format(
      E'  -- PRODUCT-10D entitlement guard\n  if not public.get_my_tenant_feature_access_v1(p_tenant_id,%L) then\n    raise exception using errcode=''42501'',message=''feature_not_available'';\n  end if;\n',item.feature_key);
    definition:=pg_catalog.substr(definition,1,marker-1)||insertion||pg_catalog.substr(definition,marker+7);
    execute definition;
  end loop;
end;
$guard_staff_rpcs$;

-- Resource-bound callers keep their existing signatures and derive tenant authority from the resource.
do $guard_resource_rpcs$
declare definition text; signature text;
begin
  foreach signature in array array[
    'public.get_lane_booking_busy_ranges(uuid,date)',
    'public.get_lane_booking_busy_ranges_v2(uuid,date)',
    'public.get_lane_booking_busy_ranges_v3(uuid,date)'
  ] loop
    definition:=replace(replace(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(signature)),E'\r\n',E'\n'),E'\r',E'\n');
    if pg_catalog.strpos(definition,'PRODUCT-10D entitlement guard')>0 then raise exception 'PRODUCT-10D RPC already guarded: %',signature; end if;
    definition:=pg_catalog.replace(definition,
      'if not found or not public.is_tenant_member_v1(v_tenant) then',
      E'-- PRODUCT-10D entitlement guard\n  if not found or not public.is_tenant_member_v1(v_tenant) or not public.tenant_has_feature_v1(v_tenant,''booking'') then');
    if pg_catalog.strpos(definition,'PRODUCT-10D entitlement guard')=0 then raise exception 'PRODUCT-10D busy-range anchor drifted: %',signature; end if;
    execute definition;
  end loop;

  definition:=replace(replace(pg_catalog.pg_get_functiondef('public.get_check_in_reservation_v1(uuid)'::regprocedure),E'\r\n',E'\n'),E'\r',E'\n');
  definition:=pg_catalog.replace(definition,'if not found then return; end if;',
    E'if not found then return; end if;\n  -- PRODUCT-10D entitlement guard\n  if not public.tenant_has_feature_v1(v_tenant,''checkin'') then raise exception ''Check-in is not available.'' using errcode=''42501''; end if;');
  if pg_catalog.strpos(definition,'PRODUCT-10D entitlement guard')=0 then raise exception 'PRODUCT-10D check-in reader anchor drifted'; end if;
  execute definition;

  definition:=replace(replace(pg_catalog.pg_get_functiondef('public.update_reservation_attendance(uuid,text)'::regprocedure),E'\r\n',E'\n'),E'\r',E'\n');
  definition:=pg_catalog.replace(definition,
    'if not found then return pg_catalog.jsonb_build_object(''ok'',false,''changed'',false,''code'',''reservation_not_found''); end if;',
    E'if not found then return pg_catalog.jsonb_build_object(''ok'',false,''changed'',false,''code'',''reservation_not_found''); end if;\n  -- PRODUCT-10D entitlement guard\n  if not public.tenant_has_feature_v1(v_tenant,''checkin'') then return pg_catalog.jsonb_build_object(''ok'',false,''changed'',false,''code'',''not_allowed''); end if;');
  if pg_catalog.strpos(definition,'PRODUCT-10D entitlement guard')=0 then raise exception 'PRODUCT-10D attendance writer anchor drifted'; end if;
  execute definition;

  definition:=replace(replace(pg_catalog.pg_get_functiondef('public.update_reservation_customer_verification_v1(uuid,text,text)'::regprocedure),E'\r\n',E'\n'),E'\r',E'\n');
  definition:=pg_catalog.replace(definition,
    'if not found or v_reservation.user_id is null then raise exception ''Brak uprawnień do weryfikacji rezerwacji.'' using errcode=''42501''; end if;',
    E'if not found or v_reservation.user_id is null then raise exception ''Brak uprawnień do weryfikacji rezerwacji.'' using errcode=''42501''; end if;\n  -- PRODUCT-10D entitlement guard\n  if not public.tenant_has_feature_v1(v_reservation.tenant_id,''checkin'') then raise exception ''Brak uprawnień do weryfikacji rezerwacji.'' using errcode=''42501''; end if;');
  if pg_catalog.strpos(definition,'PRODUCT-10D entitlement guard')=0 then raise exception 'PRODUCT-10D verification writer anchor drifted'; end if;
  execute definition;

  definition:=replace(replace(pg_catalog.pg_get_functiondef('public.admin_list_event_registrations_v1(uuid,text,text,integer,integer)'::regprocedure),E'\r\n',E'\n'),E'\r',E'\n');
  definition:=pg_catalog.replace(definition,
    'if not found then return pg_catalog.jsonb_build_object(''ok'',false,''code'',''invalid_input''); end if;',
    E'if not found then return pg_catalog.jsonb_build_object(''ok'',false,''code'',''invalid_input''); end if;\n  -- PRODUCT-10D entitlement guard\n  if not public.tenant_has_feature_v1(v_tenant,''events'') then return pg_catalog.jsonb_build_object(''ok'',false,''code'',''not_allowed''); end if;');
  if pg_catalog.strpos(definition,'PRODUCT-10D entitlement guard')=0 then raise exception 'PRODUCT-10D legacy event reader anchor drifted'; end if;
  execute definition;

  foreach signature in array array['public.approve_event_registration(uuid)','public.mark_event_registration_paid(uuid)'] loop
    definition:=replace(replace(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure(signature)),E'\r\n',E'\n'),E'\r',E'\n');
    definition:=pg_catalog.replace(definition,
      'if not found then return pg_catalog.jsonb_build_object(''ok'',false,''changed'',false,''code'',''registration_not_found''); end if;',
      E'if not found then return pg_catalog.jsonb_build_object(''ok'',false,''changed'',false,''code'',''registration_not_found''); end if;\n  -- PRODUCT-10D entitlement guard\n  if not public.tenant_has_feature_v1(v_tenant,''events'') then return pg_catalog.jsonb_build_object(''ok'',false,''changed'',false,''code'',''not_allowed''); end if;');
    if pg_catalog.strpos(definition,'PRODUCT-10D entitlement guard')=0 then raise exception 'PRODUCT-10D legacy event writer anchor drifted: %',signature; end if;
    execute definition;
  end loop;

  definition:=replace(replace(pg_catalog.pg_get_functiondef('public.prepare_event_reserve_promotions(uuid)'::regprocedure),E'\r\n',E'\n'),E'\r',E'\n');
  definition:=pg_catalog.replace(definition,
    E'  if not found then\n    raise exception using\n      errcode=''P0002'',\n      message=''Nie znaleziono szkolenia.'';\n  end if;',
    E'  if not found then\n    raise exception using\n      errcode=''P0002'',\n      message=''Nie znaleziono szkolenia.'';\n  end if;\n\n  -- PRODUCT-10D entitlement guard\n  if not public.tenant_has_feature_v1(v_event.tenant_id,''events'') then\n    raise exception using errcode=''42501'',message=''feature_not_available'';\n  end if;');
  if pg_catalog.strpos(definition,'PRODUCT-10D entitlement guard')=0 then raise exception 'PRODUCT-10D reserve promotion anchor drifted'; end if;
  execute definition;
end;
$guard_resource_rpcs$;

-- Existing-record continuity: gate creation/new feature use, not owner history/cancellation.
create function public.enforce_tenant_feature_write_v1()
returns trigger language plpgsql security definer
set search_path=pg_catalog,public,pg_temp
as $function$
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
    if tg_op='DELETE' or (tg_op='UPDATE' and old.is_active and not new.is_active) then return coalesce(new,old); end if; v_feature:='booking';
  else v_requires:=false;
  end if;
  if v_requires and not public.tenant_has_feature_v1(v_tenant,v_feature) then
    raise exception using errcode='42501',message='feature_not_available';
  end if;
  return coalesce(new,old);
end;
$function$;
alter function public.enforce_tenant_feature_write_v1() owner to postgres;
revoke all on function public.enforce_tenant_feature_write_v1() from public,anon,authenticated,service_role;

create trigger reservations_feature_entitlement before insert or update on public.reservations for each row execute function public.enforce_tenant_feature_write_v1();
create trigger event_registrations_feature_entitlement before insert or update on public.event_registrations for each row execute function public.enforce_tenant_feature_write_v1();
create trigger events_feature_entitlement before insert or update or delete on public.events for each row execute function public.enforce_tenant_feature_write_v1();
create trigger lane_blocks_feature_entitlement before insert or update or delete on public.lane_blocks for each row execute function public.enforce_tenant_feature_write_v1();
create trigger shooting_lanes_feature_entitlement before insert or update or delete on public.shooting_lanes for each row execute function public.enforce_tenant_feature_write_v1();

-- Effective public presentation is entitlement AND tenant visibility.
create or replace function public.get_public_tenant_landing_v2(p_slug text)
returns table(tenant_slug text,public_slug text,tenant_name text,tenant_city text,tenant_logo_path text,tenant_hero_image_path text,tenant_description text,tenant_regulations_path text,tenant_public_address text,tenant_public_phone text,tenant_public_email text,tenant_opening_hours text,tenant_social_links jsonb,show_booking boolean,show_pricing boolean,show_instructor boolean,show_events boolean,show_about boolean,show_contact boolean,show_regulations boolean)
language plpgsql stable security definer set search_path=pg_catalog,public,pg_temp
as $function$
begin
  if p_slug is null or p_slug<>pg_catalog.lower(p_slug) or pg_catalog.char_length(p_slug) not between 2 and 63 or p_slug !~ '^[a-z0-9]+(?:-[a-z0-9]+)*$' then return; end if;
  return query
  select tenant.slug,profile.public_slug,profile.display_name,profile.city,profile.logo_path,profile.hero_image_path,
    case when profile.show_about then profile.description else null end,
    case when profile.show_regulations then profile.regulations_path else null end,
    case when profile.show_contact then profile.public_address else null end,
    case when profile.show_contact then profile.public_phone else null end,
    case when profile.show_contact then profile.public_email else null end,
    case when profile.show_contact then profile.opening_hours else null end,
    case when profile.show_contact then profile.social_links else '{}'::jsonb end,
    profile.show_booking and public.tenant_has_feature_v1(tenant.id,'booking'),
    profile.show_pricing and public.tenant_has_feature_v1(tenant.id,'booking'),
    profile.show_instructor and public.tenant_has_feature_v1(tenant.id,'instructors'),
    profile.show_events and public.tenant_has_feature_v1(tenant.id,'events'),
    profile.show_about,profile.show_contact,profile.show_regulations
  from public.tenant_public_profiles profile join public.tenants tenant on tenant.id=profile.tenant_id
  where profile.is_public and tenant.status='active' and (profile.public_slug=p_slug or tenant.slug=p_slug)
    and not exists(select 1 from public.tenant_public_profiles other_profile join public.tenants other_tenant on other_tenant.id=other_profile.tenant_id where other_profile.is_public and other_tenant.status='active' and other_profile.tenant_id<>profile.tenant_id and (other_profile.public_slug=p_slug or other_tenant.slug=p_slug))
  limit 1;
end;
$function$;

-- Settings reader exposes booleans only; plan keys and the commercial catalog remain private.
do $settings_reader$
declare definition text;
begin
  definition:=replace(replace(pg_catalog.pg_get_functiondef('public.admin_get_tenant_public_settings_v1(text)'::regprocedure),E'\r\n',E'\n'),E'\r',E'\n');
  if pg_catalog.strpos(definition,'''updated_at'',v_profile.updated_at')=0 then raise exception 'PRODUCT-10D settings reader anchor drifted'; end if;
  definition:=pg_catalog.replace(definition,'''updated_at'',v_profile.updated_at',
    '''updated_at'',v_profile.updated_at,''feature_access'',pg_catalog.jsonb_build_object(''booking'',public.tenant_has_feature_v1(v_tenant_id,''booking''),''events'',public.tenant_has_feature_v1(v_tenant_id,''events''),''instructors'',public.tenant_has_feature_v1(v_tenant_id,''instructors''))');
  execute definition;
end;
$settings_reader$;

do $postflight$
begin
  if (select count(*) from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prosecdef) <> 85 then
    raise exception 'PRODUCT-10D postflight failed: SECURITY DEFINER count differs';
  end if;
  if (select count(*) from public.saas_features)<>10
     or (select count(*) from public.saas_plan_features pf join public.saas_plans p on p.id=pf.plan_id where p.plan_key='current_full_v1')<>10
     or not exists(select 1 from public.tenant_plan_assignments a join public.tenants t on t.id=a.tenant_id join public.saas_plans p on p.id=a.plan_id where t.slug='csk' and a.status='active' and p.plan_key='current_full_v1') then
    raise exception 'PRODUCT-10D postflight failed: bootstrap model differs';
  end if;
end;
$postflight$;
