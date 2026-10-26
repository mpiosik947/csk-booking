-- PUBLIC-TEST-MODE-2. Empty additive state, absence = live. No production seed.
-- Bounded DDL; no business-table rewrite/backfill. Retain existing RLS/ACL.
set lock_timeout = '5s';
set statement_timeout = '60s';

create table public.tenant_public_access_controls (
  tenant_id uuid primary key references public.tenants(id),
  public_access_state text not null check (public_access_state in ('live','coming_soon')),
  revision uuid not null default gen_random_uuid(),
  updated_at timestamptz not null default clock_timestamp()
);
alter table public.tenant_public_access_controls enable row level security;
revoke all on public.tenant_public_access_controls from public,anon,authenticated,service_role;

-- Private, minimal audit + retry receipt. No customer data or direct client grants.
create table app_private.tenant_public_access_changes (
  tenant_id uuid not null references public.tenants(id),
  request_id uuid not null,
  actor_user_id uuid not null,
  old_state text not null,
  new_state text not null,
  request jsonb not null,
  response jsonb not null,
  created_at timestamptz not null default clock_timestamp(),
  primary key (tenant_id, request_id)
);
alter table app_private.tenant_public_access_changes enable row level security;
revoke all on app_private.tenant_public_access_changes from public,anon,authenticated,service_role;

create function public.can_access_tenant_public_business_v1(p_tenant_id uuid)
returns boolean language sql stable security definer
set search_path = pg_catalog, public, pg_temp as $$
 select coalesce((select
   coalesce(c.public_access_state,'live')='live'
   or (auth.uid() is not null and (
     exists(select 1 from public.platform_admins pa where pa.user_id=auth.uid() and pa.status='active')
     or exists(select 1 from public.tenant_memberships m where m.tenant_id=t.id
       and m.user_id=auth.uid() and m.status='active' and m.role in ('admin','employee','instructor'))
   ))
 from public.tenants t left join public.tenant_public_access_controls c on c.tenant_id=t.id
 where t.id=p_tenant_id and t.status='active'),false);
$$;
revoke all on function public.can_access_tenant_public_business_v1(uuid) from public,anon,authenticated,service_role;
grant execute on function public.can_access_tenant_public_business_v1(uuid) to anon,authenticated;

create function app_private.require_tenant_public_business_v1(p_tenant_id uuid)
returns void language plpgsql stable security invoker
set search_path = pg_catalog, public, pg_temp as $$
begin
 if exists(select 1 from public.tenant_public_access_controls where tenant_id=p_tenant_id and public_access_state='coming_soon')
   and not public.can_access_tenant_public_business_v1(p_tenant_id) then
   raise exception 'TENANT_PUBLIC_ACCESS_UNAVAILABLE' using errcode='PT423';
 end if;
end; $$;
revoke all on function app_private.require_tenant_public_business_v1(uuid) from public,anon,authenticated,service_role;

create function app_private.lock_tenant_public_business_v1(p_tenant_id uuid)
returns void language plpgsql volatile security invoker
set search_path = pg_catalog, public, pg_temp as $$
begin
 if not pg_try_advisory_xact_lock_shared(hashtextextended('tenant-public-access:'||p_tenant_id::text,0)) then
   raise exception 'TENANT_PUBLIC_ACCESS_RETRY' using errcode='PT409';
 end if;
 -- A separate command after the lock obtains a fresh READ COMMITTED snapshot.
 perform app_private.require_tenant_public_business_v1(p_tenant_id);
end; $$;
revoke all on function app_private.lock_tenant_public_business_v1(uuid) from public,anon,authenticated,service_role;

create function public.get_public_tenant_access_v1(p_slug text)
returns jsonb language sql stable security definer
set search_path = pg_catalog, public, pg_temp as $$
 select jsonb_build_object('state',coalesce(c.public_access_state,'live'),
   'allowed',public.can_access_tenant_public_business_v1(t.id))
 from public.tenants t join public.tenant_public_profiles p on p.tenant_id=t.id
 left join public.tenant_public_access_controls c on c.tenant_id=t.id
 where t.status='active' and p.is_public and (t.slug=p_slug or p.public_slug=p_slug)
 order by (p.public_slug=p_slug) desc limit 1;
$$;
revoke all on function public.get_public_tenant_access_v1(text) from public,anon,authenticated,service_role;
grant execute on function public.get_public_tenant_access_v1(text) to anon,authenticated;

create function public.platform_get_tenant_public_access_v1(p_tenant_id uuid)
returns jsonb language plpgsql stable security definer
set search_path = pg_catalog, public, pg_temp as $$
declare result jsonb;
begin
 if not public.is_platform_admin_v1() then raise exception 'Platform authority required' using errcode='42501'; end if;
 select jsonb_build_object('state',coalesce(c.public_access_state,'live'),'revision',c.revision)
 into result from public.tenants t left join public.tenant_public_access_controls c on c.tenant_id=t.id
 where t.id=p_tenant_id;
 if result is null then raise exception 'Tenant not found' using errcode='P0002'; end if;
 return result;
end; $$;
revoke all on function public.platform_get_tenant_public_access_v1(uuid) from public,anon,authenticated,service_role;
grant execute on function public.platform_get_tenant_public_access_v1(uuid) to authenticated;

create function public.platform_set_tenant_public_access_v1(
 p_tenant_id uuid,p_state text,p_expected_state text,p_expected_revision uuid,p_request_id uuid)
returns jsonb language plpgsql volatile security definer
set search_path = pg_catalog, public, pg_temp as $$
declare current_state jsonb; receipt app_private.tenant_public_access_changes%rowtype;
 request_value jsonb; result jsonb; next_revision uuid;
begin
 if not public.is_platform_admin_v1() then raise exception 'Platform authority required' using errcode='42501'; end if;
 if p_tenant_id is null or p_request_id is null or p_state is null or p_expected_state is null
   or p_state not in ('live','coming_soon') or p_expected_state not in ('live','coming_soon') then
   raise exception 'Invalid public access request' using errcode='22023';
 end if;
 if not pg_try_advisory_xact_lock(hashtextextended('tenant-public-access:'||p_tenant_id::text,0)) then
   raise exception 'TENANT_PUBLIC_ACCESS_RETRY' using errcode='PT409';
 end if;
 -- Recheck PA after locking, and never accept caller-supplied actor/role.
 if not public.is_platform_admin_v1() then raise exception 'Platform authority required' using errcode='42501'; end if;
 request_value:=jsonb_build_object('state',p_state,'expected_state',p_expected_state,'expected_revision',p_expected_revision);
 select * into receipt from app_private.tenant_public_access_changes
 where tenant_id=p_tenant_id and request_id=p_request_id;
 if found then
   if receipt.actor_user_id is distinct from auth.uid() or receipt.request is distinct from request_value then
     raise exception 'PUBLIC_ACCESS_REQUEST_CONFLICT' using errcode='PT409';
   end if;
   return receipt.response;
 end if;
 current_state:=public.platform_get_tenant_public_access_v1(p_tenant_id);
 if current_state->>'state' is distinct from p_expected_state
   or (current_state->>'revision')::uuid is distinct from p_expected_revision then
   raise exception 'PUBLIC_ACCESS_STATE_CONFLICT' using errcode='PT409';
 end if;
 next_revision:=(current_state->>'revision')::uuid;
 if p_state is distinct from p_expected_state then
   next_revision:=gen_random_uuid();
   insert into public.tenant_public_access_controls(tenant_id,public_access_state,revision)
   values(p_tenant_id,p_state,next_revision) on conflict(tenant_id) do update
   set public_access_state=excluded.public_access_state,revision=excluded.revision,updated_at=clock_timestamp();
 end if;
 result:=jsonb_build_object('state',p_state,'revision',next_revision,'changed',p_state<>p_expected_state);
 insert into app_private.tenant_public_access_changes(tenant_id,request_id,actor_user_id,old_state,new_state,request,response)
 values(p_tenant_id,p_request_id,auth.uid(),p_expected_state,p_state,request_value,result);
 return result;
end; $$;
revoke all on function public.platform_set_tenant_public_access_v1(uuid,text,text,uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function public.platform_set_tenant_public_access_v1(uuid,text,text,uuid,uuid) to authenticated;

-- Restrictive gates retain every pre-existing permissive policy and staff restriction.
create policy tenant_public_business_gate on public.shooting_lanes as restrictive for select to anon,authenticated
using (public.can_access_tenant_public_business_v1(tenant_id));
create policy tenant_public_business_gate on public.events as restrictive for select to anon,authenticated
using (public.can_access_tenant_public_business_v1(tenant_id));
create policy tenant_public_business_gate on public.lane_blocks as restrictive for select to anon,authenticated
using (public.can_access_tenant_public_business_v1(tenant_id));
-- tenant_public_pricing_items has no client table privileges; only its guarded RPC reads it.

-- Existing owned reservations/registrations/cancellation policies are intentionally unchanged.

-- Preserve signature, ACL, original authority and core implementation.
CREATE OR REPLACE FUNCTION public.get_public_booking_configuration_v2(p_tenant_id uuid)
 RETURNS TABLE(lane_id uuid, parent_lane_id uuid, resource_kind text, name text, display_name text, display_order integer, effective_online_bookable boolean, whole_lane_bookable boolean, positions_bookable boolean, max_people_online integer, booking_step_minutes integer, currency_code text, durations_minutes integer[], pricing jsonb)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
begin
 perform app_private.require_tenant_public_business_v1(p_tenant_id);
  if not public.get_public_tenant_feature_access_v1(p_tenant_id,'booking') then
    raise exception 'Moduł jest niedostępny.' using errcode='42501';
  end if;
  return query select * from public.get_public_booking_configuration_v1__saas9d4e_core(p_tenant_id);
end;
$function$
;

-- Preserve signature, ACL, original authority and core implementation.
CREATE OR REPLACE FUNCTION public.get_public_event_list_v3(p_tenant_id uuid, p_search text DEFAULT NULL::text, p_scope text DEFAULT 'upcoming'::text, p_page integer DEFAULT 1, p_page_size integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
begin
 perform app_private.require_tenant_public_business_v1(p_tenant_id);
  if not public.get_public_tenant_feature_access_v1(p_tenant_id,'events') then
    return pg_catalog.jsonb_build_object('ok',false,'code','not_available');
  end if;
  return public.get_public_event_list_v2__saas9d2b2_core(p_tenant_id,p_search,p_scope,p_page,p_page_size);
end;
$function$
;

-- Preserve signature, ACL, original authority and core implementation.
CREATE OR REPLACE FUNCTION public.get_public_event_availability_v2(p_tenant_id uuid)
 RETURNS TABLE(event_id uuid, title text, description text, event_date date, start_time time without time zone, end_time time without time zone, location text, price numeric, max_participants integer, registered_count integer, reserve_count integer, available_spots integer, sold_out boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
begin
 perform app_private.require_tenant_public_business_v1(p_tenant_id);
  if not public.get_public_tenant_feature_access_v1(p_tenant_id,'events') then
    raise exception 'Moduł jest niedostępny.' using errcode='42501';
  end if;
  return query select * from public.get_public_event_availability_v1__saas9d2b2_core(p_tenant_id);
end;
$function$
;

-- Preserve signature, ACL, original authority and core implementation.
CREATE OR REPLACE FUNCTION public.get_lane_booking_busy_ranges(p_lane_id uuid, p_reservation_date date)
 RETURNS TABLE(start_time time without time zone, end_time time without time zone)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
declare v_tenant uuid;
begin
  select tenant_id into v_tenant from public.shooting_lanes where id=p_lane_id;
  -- PRODUCT-10D entitlement guard
  if not found or not public.is_tenant_member_v1(v_tenant) or not public.tenant_has_feature_v1(v_tenant,'booking') then raise exception 'Lane access is not allowed.' using errcode='42501'; end if;
 perform app_private.require_tenant_public_business_v1(v_tenant);
  return query select * from public.get_lane_booking_busy_ranges__saas9d1_core(p_lane_id,p_reservation_date);
end;
$function$
;

-- Preserve signature, ACL, original authority and core implementation.
CREATE OR REPLACE FUNCTION public.get_lane_booking_busy_ranges_v2(p_lane_id uuid, p_reservation_date date)
 RETURNS TABLE(start_time time without time zone, end_time time without time zone, busy_type text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
declare v_tenant uuid;
begin
  select tenant_id into v_tenant from public.shooting_lanes where id=p_lane_id;
  -- PRODUCT-10D entitlement guard
  if not found or not public.is_tenant_member_v1(v_tenant) or not public.tenant_has_feature_v1(v_tenant,'booking') then raise exception 'Lane access is not allowed.' using errcode='42501'; end if;
 perform app_private.require_tenant_public_business_v1(v_tenant);
  return query select * from public.get_lane_booking_busy_ranges_v2__saas9d1_core(p_lane_id,p_reservation_date);
end;
$function$
;

-- Preserve signature, ACL, original authority and core implementation.
CREATE OR REPLACE FUNCTION public.get_lane_booking_busy_ranges_v3(p_lane_id uuid, p_reservation_date date)
 RETURNS TABLE(start_time time without time zone, end_time time without time zone, busy_type text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
declare v_tenant uuid;
begin
  select tenant_id into v_tenant from public.shooting_lanes where id=p_lane_id;
  -- PRODUCT-10D entitlement guard
  if not found or not public.is_tenant_member_v1(v_tenant) or not public.tenant_has_feature_v1(v_tenant,'booking') then raise exception 'Lane access is not allowed.' using errcode='42501'; end if;
 perform app_private.require_tenant_public_business_v1(v_tenant);
  return query select * from public.get_lane_booking_busy_ranges_v3__saas9d1_core(p_lane_id,p_reservation_date);
end;
$function$
;

-- Preserve signature, ACL, original authority and core implementation.
CREATE OR REPLACE FUNCTION public.get_public_tenant_content_v1(p_public_slug text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
declare profile public.tenant_public_profiles%rowtype; flags record; result jsonb;
begin
 select * into flags from public.get_public_tenant_landing_v2(p_public_slug);
 if not found or flags.public_slug is distinct from p_public_slug then return null; end if;
 select p.* into profile from public.tenant_public_profiles p join public.tenants t on t.id=p.tenant_id where p.public_slug=p_public_slug and p.is_public and t.status='active';
 if not found then return null; end if;
 perform app_private.require_tenant_public_business_v1(profile.tenant_id);
 return jsonb_build_object('about_offer',case when flags.show_about then profile.about_offer end,
 'about_audience',case when flags.show_about then profile.about_audience end,
 'public_map_url',case when flags.show_contact then profile.public_map_url end,
 'pricing_items',case when flags.show_pricing then (select coalesce(jsonb_agg(jsonb_build_object('title',title,'price',price,'currency',currency,'unit',unit,'short_description',short_description) order by display_order,id),'[]'::jsonb)
 from public.tenant_public_pricing_items where tenant_id=profile.tenant_id and is_active) else '[]'::jsonb end);
end;$function$
;

-- Preserve signature, ACL, original authority and core implementation.
CREATE OR REPLACE FUNCTION public.create_reservation_v2(p_lane_id uuid, p_reservation_date date, p_start_time time without time zone, p_duration_minutes integer, p_shooters_count integer, p_creation_request_id uuid, p_reservation_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
declare v_tenant_id uuid; v_role text;
begin
  select lane.tenant_id into v_tenant_id from public.shooting_lanes lane where lane.id=p_lane_id;
  if not found or v_tenant_id is null then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','lane_not_found');
  end if;
  v_role := public.get_my_tenant_role_v1(v_tenant_id);
 perform app_private.lock_tenant_public_business_v1(v_tenant_id);
  if v_role is distinct from 'user' then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code',
      case when auth.uid() is null then 'unauthorized' else 'not_allowed' end);
  end if;
  return public.create_reservation_v2__saas9d1_core(
    p_lane_id,p_reservation_date,p_start_time,p_duration_minutes,p_shooters_count,
    p_creation_request_id,p_reservation_note
  );
end;
$function$
;

-- Preserve signature, ACL, original authority and core implementation.
CREATE OR REPLACE FUNCTION public.register_for_event(p_event_id uuid, p_as_reserve boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
declare v_tenant uuid;
begin
  select event_record.tenant_id into v_tenant
  from public.events event_record where event_record.id=p_event_id;
  if not found then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','event_not_found');
  end if;
 perform app_private.lock_tenant_public_business_v1(v_tenant);
  if not public.is_tenant_member_v1(v_tenant) then
    raise exception 'Uwierzytelniona aktywna relacja z tenantem jest wymagana.' using errcode='42501';
  end if;
  return public.register_for_event__saas9d2a_core(p_event_id,p_as_reserve);
end;
$function$
;

-- Preserve signature, ACL, original authority and core implementation.
CREATE OR REPLACE FUNCTION public.confirm_event_reserve_promotion(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
declare v_actor uuid:=auth.uid(); v_tenant uuid; v_owner uuid; result jsonb;
begin
 if v_actor is null then raise exception 'Authentication is required.' using errcode='42501'; end if;
 if p_token is null or btrim(p_token)='' then
  return public.confirm_event_reserve_promotion__saas9d2a_core(p_token);
 end if;
 select r.tenant_id,r.user_id into v_tenant,v_owner from public.event_registrations r
 where r.promotion_token=btrim(p_token);
 if not found then return public.confirm_event_reserve_promotion__saas9d2a_core(p_token); end if;
 if v_owner is distinct from v_actor or not public.is_tenant_member_v1(v_tenant) then
  raise exception 'You cannot confirm this registration.' using errcode='42501';
 end if;
 perform app_private.lock_tenant_public_business_v1(v_tenant);
 result:=public.confirm_event_reserve_promotion__saas9d2a_core(p_token);
 if result->>'code'='confirmed' and (result->>'ok')::boolean then
  insert into public.email_deliveries(tenant_id,message_type,record_id,recipient_user_id,delivery_state)
  select r.tenant_id,'event_reserve_acceptance_confirmation',r.id,r.user_id,'pending'
  from public.event_registrations r join public.events e on e.id=r.event_id and e.tenant_id=r.tenant_id
  where r.id=(result->>'registration_id')::uuid and r.user_id=v_actor
   and r.tenant_id=v_tenant and r.registration_status='registered' and r.promotion_confirmed_at is not null;
  if not found then raise exception 'Acceptance receipt invariant failed' using errcode='23514'; end if;
 end if;
 return result;
end;$function$
;

-- Preserve signature, ACL, original authority and core implementation.
CREATE OR REPLACE FUNCTION public.self_onboard_tenant_v1(p_tenant_slug text)
 RETURNS TABLE(tenant_id uuid, user_id uuid, role text, status text, created boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
declare
  v_actor_id uuid:=auth.uid();
  v_tenant_id uuid;
  v_inserted boolean:=false;
  v_rows integer:=0;
begin
  if v_actor_id is null then
    raise exception 'Uwierzytelnienie jest wymagane.' using errcode='42501';
  end if;
  if p_tenant_slug is null
     or p_tenant_slug<>pg_catalog.btrim(p_tenant_slug)
     or pg_catalog.char_length(p_tenant_slug) not between 2 and 63
     or p_tenant_slug!~'^[a-z0-9]+(?:-[a-z0-9]+)*$' then
    raise exception 'Nieprawidłowy tenant.' using errcode='22023';
  end if;
  if not exists(
    select 1 from auth.users auth_user
    where auth_user.id=v_actor_id and auth_user.deleted_at is null
      and (auth_user.banned_until is null or auth_user.banned_until<=pg_catalog.statement_timestamp())
  ) then
    raise exception 'Konto nie jest aktywne.' using errcode='42501';
  end if;

  select tenant.id into v_tenant_id
  from public.tenants tenant
  where tenant.slug=p_tenant_slug and tenant.status='active'
  for share;
  if not found then
    raise exception 'Nie znaleziono aktywnej lokalizacji.' using errcode='P0002';
  end if;
 if not exists(select 1 from public.tenant_memberships m where m.tenant_id=v_tenant_id and m.user_id=v_actor_id) then
    perform app_private.lock_tenant_public_business_v1(v_tenant_id);
  end if;

  insert into public.tenant_memberships as membership(tenant_id,user_id,role,status)
  values(v_tenant_id,v_actor_id,'user','active')
  on conflict on constraint tenant_memberships_pkey do nothing;
  get diagnostics v_rows=row_count;
  v_inserted:=v_rows=1;

  if v_inserted then
    insert into public.audit_logs(
      tenant_id,actor_user_id,actor_name,actor_role,action,target_type,target_id,target_name,details
    ) values(
      v_tenant_id,v_actor_id,'Tenant user','user','tenant_user_role_updated',
      'tenant_user_role',v_actor_id,'Tenant user',
      pg_catalog.jsonb_build_object('previous_role',null,'new_role','user','status','active',
        'operation','self_onboarding','source','explicit_tenant_slug')
    );
  end if;

  return query
  select membership.tenant_id,membership.user_id,membership.role,membership.status,v_inserted
  from public.tenant_memberships membership
  where membership.tenant_id=v_tenant_id and membership.user_id=v_actor_id;
end;
$function$
;



-- Reconcile additive dependency inventory; hard delete remains denied.
CREATE OR REPLACE FUNCTION public.platform_get_tenant_delete_eligibility_v1(p_tenant_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
declare
 t public.tenants; catalog jsonb; summary jsonb:='{}'; blockers jsonb;
 is_public_value boolean; catalog_matches boolean;
begin
 if not public.is_platform_admin_v1() then raise exception 'Not authorized' using errcode='42501'; end if;
 select * into t from public.tenants where id=p_tenant_id;
 if not found then raise exception 'TENANT_UNAVAILABLE' using errcode='22023'; end if;
 -- Deliberate policy blocker even for a physically empty synthetic tenant.
 -- This read is not a lock, deletion token, or authorization for future deletion.
 blockers:=jsonb_build_array(jsonb_build_object('code','HARD_DELETE_POLICY_DEFERRED','category','policy','count',1,'hard_blocker',true));
 if t.status<>'archived' then blockers:=blockers||jsonb_build_array(jsonb_build_object('code','TENANT_NOT_ARCHIVED','category','lifecycle','count',1,'hard_blocker',true)); end if;
 select jsonb_build_object(
 'tables',(select jsonb_agg(n.nspname||'.'||c.relname order by n.nspname,c.relname) from pg_class c join pg_namespace n on n.oid=c.relnamespace where (n.nspname='public' or (n.nspname='app_private' and c.relname in ('legal_subjects','legal_actions','legal_acceptances','tenant_public_access_changes'))) and c.relkind in('r','p')),
 'columns',(select jsonb_agg(n.nspname||'.'||c.relname||'.'||a.attname||':'||format_type(a.atttypid,a.atttypmod) order by n.nspname,c.relname,a.attnum) from pg_class c join pg_namespace n on n.oid=c.relnamespace join pg_attribute a on a.attrelid=c.oid where (n.nspname='public' or (n.nspname='app_private' and c.relname in ('legal_subjects','legal_actions','legal_acceptances','tenant_public_access_changes'))) and c.relkind in('r','p') and a.attnum>0 and not a.attisdropped),
 'foreign_keys',(select jsonb_agg(n.nspname||'.'||c.relname||'.'||k.conname||':'||pg_get_constraintdef(k.oid) order by n.nspname,c.relname,k.conname) from pg_constraint k join pg_class c on c.oid=k.conrelid join pg_namespace n on n.oid=c.relnamespace join pg_class parent on parent.oid=k.confrelid join pg_namespace pn on pn.oid=parent.relnamespace where k.contype='f' and (n.nspname='public' or pn.nspname='public' or (n.nspname='app_private' and c.relname in ('legal_subjects','legal_actions','legal_acceptances','tenant_public_access_changes'))))
) into catalog;

 catalog_matches:=md5(catalog::text)='9e4f6aece3b7c6001a79a53e0e58489d';
 if not catalog_matches then
  -- Do not execute stale table/column queries if the catalog contract has changed.
  return jsonb_build_object('tenant',jsonb_build_object('tenant_id',t.id,'name',t.name,'status',t.status),
   'lifecycle',jsonb_build_object('is_archived',t.status='archived','is_public',null),
   'eligibility',jsonb_build_object('can_hard_delete',false,'blocker_count',jsonb_array_length(blockers)+1),
   'blockers',blockers||jsonb_build_array(jsonb_build_object('code','UNKNOWN_DEPENDENCY','category','schema','count',1,'hard_blocker',true)),
   'warnings',jsonb_build_array('DEPENDENCY_COUNTS_UNAVAILABLE'),'dependency_summary',summary);
 end if;
 select coalesce(bool_or(p.is_public),false) into is_public_value from public.tenant_public_profiles p where p.tenant_id=t.id;
 if is_public_value then blockers:=blockers||jsonb_build_array(jsonb_build_object('code','TENANT_PUBLIC','category','lifecycle','count',1,'hard_blocker',true)); end if;
 select jsonb_build_object(
 'tenant_public_access_controls',(select count(*) from public.tenant_public_access_controls where tenant_id=p_tenant_id),
 'tenant_public_access_changes',(select count(*) from app_private.tenant_public_access_changes where tenant_id=p_tenant_id),
 'legal_documents',(select count(*) from public.legal_documents d where d.tenant_id=p_tenant_id),
 'legal_document_versions',(select count(*) from public.legal_document_versions v join public.legal_documents d on d.id=v.document_id where d.tenant_id=p_tenant_id),
 'legal_actions',(select count(*) from app_private.legal_actions a where a.tenant_id=p_tenant_id),
 'legal_acceptances',(select count(*) from app_private.legal_acceptances r join app_private.legal_actions a on a.id=r.action_id where a.tenant_id=p_tenant_id),
 'audit_logs',(select count(*) from public.audit_logs x where x.tenant_id=p_tenant_id or x.target_id=p_tenant_id or exists(select 1 from public.reservations r where r.id=x.target_id and r.tenant_id=p_tenant_id) or exists(select 1 from public.event_registrations r where r.id=x.target_id and r.tenant_id=p_tenant_id) or exists(select 1 from public.events e where e.id=x.target_id and e.tenant_id=p_tenant_id) or exists(select 1 from public.shooting_lanes l where l.id=x.target_id and l.tenant_id=p_tenant_id)),
 'email_deliveries',(select count(*) from public.email_deliveries x where x.tenant_id=p_tenant_id or exists(select 1 from public.reservations r where r.id=x.record_id and r.tenant_id=p_tenant_id) or exists(select 1 from public.event_registrations r where r.id=x.record_id and r.tenant_id=p_tenant_id) or exists(select 1 from public.events e where e.id=x.record_id and e.tenant_id=p_tenant_id) or exists(select 1 from public.event_instructors i where i.id=x.record_id and i.tenant_id=p_tenant_id) or exists(select 1 from public.reminder_occurrences o join public.reminder_schedules s on s.id=o.schedule_id where o.id=x.record_id and (exists(select 1 from public.reservations r where r.id=s.reservation_id and r.tenant_id=p_tenant_id) or exists(select 1 from public.events e where e.id=s.event_id and e.tenant_id=p_tenant_id)))),
 'event_instructors',(select count(*) from public.event_instructors x where x.tenant_id=p_tenant_id),
 'event_lanes',(select count(*) from public.event_lanes x where x.tenant_id=p_tenant_id),
 'event_registrations',(select count(*) from public.event_registrations x where x.tenant_id=p_tenant_id),
 'events',(select count(*) from public.events x where x.tenant_id=p_tenant_id),
 'external_settlement_records',(select count(*) from public.external_settlement_records x where x.tenant_id=p_tenant_id),
 'lane_blocks',(select count(*) from public.lane_blocks x where x.tenant_id=p_tenant_id),
 'platform_admin_management_requests',(select count(*) from public.platform_admin_management_requests x where x.tenant_id=p_tenant_id),
 'platform_audit_logs',(select count(*) from public.platform_audit_logs x where x.tenant_id=p_tenant_id),
 'platform_plan_change_requests',(select count(*) from public.platform_plan_change_requests x where x.tenant_id=p_tenant_id),
 'platform_tenant_creation_requests',(select count(*) from public.platform_tenant_creation_requests x where x.tenant_id=p_tenant_id),
 'platform_tenant_lifecycle_requests',(select count(*) from public.platform_tenant_lifecycle_requests x where x.tenant_id=p_tenant_id),
 'reservations',(select count(*) from public.reservations x where x.tenant_id=p_tenant_id),
 'shooting_lanes',(select count(*) from public.shooting_lanes x where x.tenant_id=p_tenant_id),
 'tenant_domains',(select count(*) from public.tenant_domains x where x.tenant_id=p_tenant_id),
 'tenant_memberships',(select count(*) from public.tenant_memberships x where x.tenant_id=p_tenant_id),
 'tenant_plan_assignments',(select count(*) from public.tenant_plan_assignments x where x.tenant_id=p_tenant_id),
 'tenant_public_pricing_items',(select count(*) from public.tenant_public_pricing_items x where x.tenant_id=p_tenant_id),
 'tenant_public_profiles',(select count(*) from public.tenant_public_profiles x where x.tenant_id=p_tenant_id),
 'tenant_user_admin_notes',(select count(*) from public.tenant_user_admin_notes x where x.tenant_id=p_tenant_id),
 'tenant_user_verifications',(select count(*) from public.tenant_user_verifications x where x.tenant_id=p_tenant_id),
 'lane_booking_durations',(select count(*) from public.lane_booking_durations x where exists(select 1 from public.shooting_lanes l where l.id=x.lane_id and l.tenant_id=p_tenant_id)),
 'lane_booking_family_configuration_versions',(select count(*) from public.lane_booking_family_configuration_versions x where exists(select 1 from public.shooting_lanes l where l.id=x.root_lane_id and l.tenant_id=p_tenant_id)),
 'lane_booking_rules',(select count(*) from public.lane_booking_rules x where exists(select 1 from public.shooting_lanes l where l.id=x.lane_id and l.tenant_id=p_tenant_id)),
 'lane_pricing_rules',(select count(*) from public.lane_pricing_rules x where exists(select 1 from public.shooting_lanes l where l.id=x.lane_id and l.tenant_id=p_tenant_id)),
 'reminder_schedules',(select count(*) from public.reminder_schedules x where exists(select 1 from public.reservations r where r.id=x.reservation_id and r.tenant_id=p_tenant_id) or exists(select 1 from public.events e where e.id=x.event_id and e.tenant_id=p_tenant_id)),
 'reminder_occurrences',(select count(*) from public.reminder_occurrences x where exists(select 1 from public.reservations r where r.id=x.reservation_id and r.tenant_id=p_tenant_id) or exists(select 1 from public.event_registrations r where r.id=x.registration_id and r.tenant_id=p_tenant_id) or exists(select 1 from public.reminder_schedules s where s.id=x.schedule_id and (exists(select 1 from public.reservations r where r.id=s.reservation_id and r.tenant_id=p_tenant_id) or exists(select 1 from public.events e where e.id=s.event_id and e.tenant_id=p_tenant_id))))
 ) into summary;
 -- A global profile is not owned by a tenant. Only count related user links.
 summary:=summary||jsonb_build_object('profile_links',(select count(*) from (
  select user_id from public.tenant_memberships where tenant_id=t.id
  union select user_id from public.tenant_user_verifications where tenant_id=t.id
  union select user_id from public.tenant_user_admin_notes where tenant_id=t.id
  union select user_id from public.reservations where tenant_id=t.id
  union select user_id from public.event_registrations where tenant_id=t.id
  union select instructor_user_id from public.event_instructors where tenant_id=t.id
 ) links where user_id is not null));
 select blockers||coalesce(jsonb_agg(jsonb_build_object('code',code,'category',category,'count',(summary->>tab)::bigint,'hard_blocker',true) order by code),'[]'::jsonb) into blockers
 from (values ('tenant_public_access_controls','PUBLIC_ACCESS_CONFIGURATION_EXISTS','configuration'),('tenant_public_access_changes','PUBLIC_ACCESS_AUDIT_EXISTS','history'),('legal_documents','LEGAL_DOCUMENTS_EXIST','history'),('legal_document_versions','LEGAL_VERSIONS_EXIST','history'),('legal_actions','LEGAL_ACTIONS_EXIST','history'),('legal_acceptances','LEGAL_ACCEPTANCES_EXIST','history'),('audit_logs','AUDIT_LOGS_EXIST','history'),
   ('email_deliveries','EMAIL_HISTORY_EXISTS','history'),
   ('event_instructors','EVENT_INSTRUCTORS_EXIST','business'),
   ('event_lanes','EVENT_LANES_EXIST','business'),
   ('event_registrations','EVENT_REGISTRATIONS_EXIST','business'),
   ('events','EVENTS_EXIST','business'),
   ('external_settlement_records','SETTLEMENTS_EXIST','history'),
   ('lane_blocks','LANE_BLOCKS_EXIST','business'),
   ('platform_admin_management_requests','PLATFORM_ADMIN_MANAGEMENT_REQUESTS_EXIST','lineage'),
   ('platform_audit_logs','PLATFORM_AUDIT_EXISTS','history'),
   ('platform_plan_change_requests','PLATFORM_PLAN_CHANGE_REQUESTS_EXIST','lineage'),
   ('platform_tenant_creation_requests','CREATION_LEDGER_EXISTS','lineage'),
   ('platform_tenant_lifecycle_requests','PLATFORM_TENANT_LIFECYCLE_REQUESTS_EXIST','lineage'),
   ('reservations','RESERVATIONS_EXIST','business'),
   ('shooting_lanes','SHOOTING_LANES_EXIST','configuration'),
   ('tenant_domains','CUSTOM_DOMAIN_EXISTS','configuration'),
   ('tenant_memberships','TENANT_MEMBERSHIPS_EXIST','lineage'),
   ('tenant_plan_assignments','PLAN_ASSIGNMENT_EXISTS','lineage'),
   ('tenant_public_pricing_items','TENANT_PUBLIC_PRICING_ITEMS_EXIST','configuration'),
   ('tenant_public_profiles','TENANT_PUBLIC_PROFILES_EXIST','configuration'),
   ('tenant_user_admin_notes','TENANT_USER_ADMIN_NOTES_EXIST','lineage'),
   ('tenant_user_verifications','TENANT_USER_VERIFICATIONS_EXIST','lineage'),
   ('lane_booking_durations','LANE_BOOKING_DURATIONS_EXIST','configuration'),
   ('lane_booking_family_configuration_versions','LANE_BOOKING_FAMILY_CONFIGURATION_VERSIONS_EXIST','configuration'),
   ('lane_booking_rules','LANE_BOOKING_RULES_EXIST','configuration'),
   ('lane_pricing_rules','LANE_PRICING_RULES_EXIST','configuration'),
   ('reminder_schedules','REMINDER_SCHEDULES_EXIST','history'),
   ('reminder_occurrences','REMINDER_HISTORY_EXISTS','history'),('profile_links','TENANT_PROFILE_LINKS_EXIST','lineage')) c(tab,code,category)
 where (summary->>tab)::bigint>0;
 return jsonb_build_object('tenant',jsonb_build_object('tenant_id',t.id,'name',t.name,'status',t.status),
  'lifecycle',jsonb_build_object('is_archived',t.status='archived','is_public',is_public_value),
  'eligibility',jsonb_build_object('can_hard_delete',false,'blocker_count',jsonb_array_length(blockers)),
  'blockers',blockers,'warnings',jsonb_build_array('GLOBAL_ACCOUNTS_NOT_TENANT_OWNED','SNAPSHOT_ONLY_NOT_DELETE_AUTHORIZATION'),
  'dependency_summary',summary);
end;
$function$
;

reset lock_timeout;
reset statement_timeout;
