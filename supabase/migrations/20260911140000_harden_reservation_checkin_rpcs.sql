-- SAAS-9D-1: 12 RPC hardening changes plus one legacy ACL-only cleanup.
-- Active application signatures and business implementations stay compatible.

set lock_timeout = '5s';
set statement_timeout = '120s';

do $preflight$
declare
  v_expected record;
  v_actual text;
begin
  if pg_catalog.to_regprocedure('public.is_tenant_member_v1(uuid)') is null
     or pg_catalog.to_regprocedure('public.get_my_tenant_role_v1(uuid)') is null then
    raise exception 'SAAS-9D-1 preflight failed: tenant authorization helpers are absent.';
  end if;

  if exists (
       select 1 from pg_catalog.pg_proc procedure
       join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace
       where namespace.nspname='public' and procedure.proname like '%__saas9d1_core'
     ) then
    raise exception 'SAAS-9D-1 preflight failed: planned hardening objects already exist.';
  end if;

  for v_expected in
    select * from (values
      ('public.cancel_reservation(uuid)','8a8e46f00dcbb9e0eba45d8b5b86b6da'),
      ('public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)','601664ae4957ed0eef29f85ded57a191'),
      ('public.get_check_in_reservation_v1(uuid)','d0c3aa17b9104dd7d7ad70c5abdcb214'),
      ('public.get_lane_booking_busy_ranges(uuid,date)','95accb3363de7fb5e8b2f03bde18555c'),
      ('public.get_lane_booking_busy_ranges_v2(uuid,date)','573f69aa8ab31a8f26c5734cebf9a785'),
      ('public.get_lane_booking_busy_ranges_v3(uuid,date)','119f24a2b9226fdd4a85b9bec8013e4e'),
      ('public.get_my_reservations_v2()','37fc831189c125fd3ba94149813010d3'),
      ('public.get_public_check_in_status_v1(uuid)','ea4a14a4e8e7d3c6d36d4c9b92da15c5'),
      ('public.get_reservation_customer_profiles_v1(uuid[])','34ca36a24032d4606cec1a3327e1bdaf'),
      ('public.update_reservation_admin_note(uuid,text)','89830fb63e81252389d5ce30c43fe0da'),
      ('public.update_reservation_attendance(uuid,text)','a8b1ac70f0ba227ad53ebed39b2c4c10'),
      ('public.update_reservation_payment(uuid,text)','24b46f6834d825020392ee18ba5c11ba')
    ) expected(signature,fingerprint)
  loop
    if pg_catalog.to_regprocedure(v_expected.signature) is null then
      raise exception 'SAAS-9D-1 preflight failed: missing function %.',v_expected.signature;
    end if;
    -- Canonicalize line endings only. All other whitespace and catalog-rendered
    -- function metadata remain part of the guarded definition.
    select pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(
      pg_catalog.pg_get_functiondef(v_expected.signature::pg_catalog.regprocedure),
      E'\r\n',E'\n'
    ),E'\r',E'\n'))
    into v_actual;
    if v_actual is distinct from v_expected.fingerprint then
      raise exception 'SAAS-9D-1 preflight failed: fingerprint drift for %.',v_expected.signature;
    end if;
  end loop;
end;
$preflight$;

do $legacy_preflight$
declare
  v_function constant pg_catalog.regprocedure :=
    'public.create_reservation(uuid,date,time without time zone,integer,integer,uuid,text)'::pg_catalog.regprocedure;
  v_owner oid;
begin
  if pg_catalog.to_regprocedure(v_function::text) is null then
    raise exception 'SAAS-9D-1 preflight failed: legacy reservation writer is absent.';
  end if;

  select procedure.proowner into v_owner
  from pg_catalog.pg_proc procedure
  where procedure.oid=v_function;

  if pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(
       pg_catalog.pg_get_functiondef(v_function),E'\r\n',E'\n'
     ),E'\r',E'\n')) is distinct from '3212b32f37ebc8e665a9a94e94260976'
     or v_owner<>(select oid from pg_catalog.pg_roles where rolname='postgres')
     or (select proconfig from pg_catalog.pg_proc where oid=v_function)
          is distinct from array['search_path=pg_catalog, public, pg_temp']::text[]
     or pg_catalog.has_function_privilege('public',v_function,'EXECUTE')
     or pg_catalog.has_function_privilege('anon',v_function,'EXECUTE')
     or pg_catalog.has_function_privilege('authenticated',v_function,'EXECUTE')
     or not pg_catalog.has_function_privilege('service_role',v_function,'EXECUTE')
     or (select pg_catalog.count(distinct grants.grantee)
         from pg_catalog.aclexplode(coalesce(
           (select proacl from pg_catalog.pg_proc where oid=v_function),
           pg_catalog.acldefault('f',v_owner)
         )) grants)<>2 then
    raise exception 'SAAS-9D-1 preflight failed: legacy reservation writer baseline differs.';
  end if;
end;
$legacy_preflight$;

create temporary table saas9d1_legacy_snapshot on commit drop as
select
  pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(
    pg_catalog.pg_get_functiondef(procedure.oid),E'\r\n',E'\n'
  ),E'\r',E'\n')) as fingerprint,
  procedure.proowner,
  procedure.proconfig
from pg_catalog.pg_proc procedure
where procedure.oid=
  'public.create_reservation(uuid,date,time without time zone,integer,integer,uuid,text)'::pg_catalog.regprocedure;

create temporary table saas9d1_unchanged_definer_snapshot on commit drop as
select
  procedure.proname,
  pg_catalog.pg_get_function_identity_arguments(procedure.oid) as identity_arguments,
  pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(
    pg_catalog.pg_get_functiondef(procedure.oid),E'\r\n',E'\n'
  ),E'\r',E'\n')) as fingerprint,
  procedure.proowner,
  procedure.proconfig,
  procedure.proacl
from pg_catalog.pg_proc procedure
join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace
where namespace.nspname='public'
  and procedure.prosecdef
  and procedure.proname not in (
    'cancel_reservation','create_reservation','create_reservation_v2','get_check_in_reservation_v1',
    'get_lane_booking_busy_ranges','get_lane_booking_busy_ranges_v2',
    'get_lane_booking_busy_ranges_v3','get_my_reservations_v2',
    'get_public_check_in_status_v1','get_reservation_customer_profiles_v1',
    'update_reservation_admin_note','update_reservation_attendance',
    'update_reservation_payment'
  );

-- Preserve the reviewed business implementations as non-client, invoker cores.
alter function public.cancel_reservation(uuid) rename to cancel_reservation__saas9d1_core;
alter function public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text) rename to create_reservation_v2__saas9d1_core;
alter function public.get_check_in_reservation_v1(uuid) rename to get_check_in_reservation_v1__saas9d1_core;
alter function public.get_lane_booking_busy_ranges(uuid,date) rename to get_lane_booking_busy_ranges__saas9d1_core;
alter function public.get_lane_booking_busy_ranges_v2(uuid,date) rename to get_lane_booking_busy_ranges_v2__saas9d1_core;
alter function public.get_lane_booking_busy_ranges_v3(uuid,date) rename to get_lane_booking_busy_ranges_v3__saas9d1_core;
alter function public.get_my_reservations_v2() rename to get_my_reservations_v2__saas9d1_core;
alter function public.get_public_check_in_status_v1(uuid) rename to get_public_check_in_status_v1__saas9d1_core;
alter function public.get_reservation_customer_profiles_v1(uuid[]) rename to get_reservation_customer_profiles_v1__saas9d1_core;
alter function public.update_reservation_admin_note(uuid,text) rename to update_reservation_admin_note__saas9d1_core;
alter function public.update_reservation_attendance(uuid,text) rename to update_reservation_attendance__saas9d1_core;
alter function public.update_reservation_payment(uuid,text) rename to update_reservation_payment__saas9d1_core;

-- The active V2 writer previously relied on the temporary CSK column default.
-- Patch only its reviewed INSERT so the stored tenant comes from the locked lane.
do $patch_create_core$
declare
  v_definition text;
  v_patched text;
begin
  select pg_catalog.pg_get_functiondef(
    'public.create_reservation_v2__saas9d1_core(uuid,date,time without time zone,integer,integer,uuid,text)'::pg_catalog.regprocedure
  ) into v_definition;

  v_patched := pg_catalog.regexp_replace(
    v_definition,
    '(insert into public[.]reservations [(][[:space:]]*)user_id, lane_id',
    E'\\1tenant_id, user_id, lane_id'
  );
  v_patched := pg_catalog.regexp_replace(
    v_patched,
    '([)] values [(][[:space:]]*)v_user_id, p_lane_id',
    E'\\1v_lane.tenant_id, v_user_id, p_lane_id'
  );

  if v_patched is not distinct from v_definition
     or pg_catalog.strpos(v_patched,'tenant_id, user_id, lane_id')=0
     or pg_catalog.strpos(v_patched,'v_lane.tenant_id, v_user_id, p_lane_id')=0 then
    raise exception 'SAAS-9D-1 failed to patch deterministic reservation tenant ownership.';
  end if;

  execute v_patched;
end;
$patch_create_core$;

alter function public.cancel_reservation__saas9d1_core(uuid) security invoker;
alter function public.create_reservation_v2__saas9d1_core(uuid,date,time without time zone,integer,integer,uuid,text) security invoker;
alter function public.get_check_in_reservation_v1__saas9d1_core(uuid) security invoker;
alter function public.get_lane_booking_busy_ranges__saas9d1_core(uuid,date) security invoker;
alter function public.get_lane_booking_busy_ranges_v2__saas9d1_core(uuid,date) security invoker;
alter function public.get_lane_booking_busy_ranges_v3__saas9d1_core(uuid,date) security invoker;
alter function public.get_my_reservations_v2__saas9d1_core() security invoker;
alter function public.get_public_check_in_status_v1__saas9d1_core(uuid) security invoker;
alter function public.get_reservation_customer_profiles_v1__saas9d1_core(uuid[]) security invoker;
alter function public.update_reservation_admin_note__saas9d1_core(uuid,text) security invoker;
alter function public.update_reservation_attendance__saas9d1_core(uuid,text) security invoker;
alter function public.update_reservation_payment__saas9d1_core(uuid,text) security invoker;

revoke all on function public.cancel_reservation__saas9d1_core(uuid) from public,anon,authenticated,service_role;
revoke all on function public.create_reservation_v2__saas9d1_core(uuid,date,time without time zone,integer,integer,uuid,text) from public,anon,authenticated,service_role;
revoke all on function public.get_check_in_reservation_v1__saas9d1_core(uuid) from public,anon,authenticated,service_role;
revoke all on function public.get_lane_booking_busy_ranges__saas9d1_core(uuid,date) from public,anon,authenticated,service_role;
revoke all on function public.get_lane_booking_busy_ranges_v2__saas9d1_core(uuid,date) from public,anon,authenticated,service_role;
revoke all on function public.get_lane_booking_busy_ranges_v3__saas9d1_core(uuid,date) from public,anon,authenticated,service_role;
revoke all on function public.get_my_reservations_v2__saas9d1_core() from public,anon,authenticated,service_role;
revoke all on function public.get_public_check_in_status_v1__saas9d1_core(uuid) from public,anon,authenticated,service_role;
revoke all on function public.get_reservation_customer_profiles_v1__saas9d1_core(uuid[]) from public,anon,authenticated,service_role;
revoke all on function public.update_reservation_admin_note__saas9d1_core(uuid,text) from public,anon,authenticated,service_role;
revoke all on function public.update_reservation_attendance__saas9d1_core(uuid,text) from public,anon,authenticated,service_role;
revoke all on function public.update_reservation_payment__saas9d1_core(uuid,text) from public,anon,authenticated,service_role;

create function public.create_reservation_v2(
  p_lane_id uuid,p_reservation_date date,p_start_time time without time zone,
  p_duration_minutes integer,p_shooters_count integer,p_creation_request_id uuid,
  p_reservation_note text default null
) returns jsonb
language plpgsql security definer
set search_path=pg_catalog,public,pg_temp
as $function$
declare v_tenant_id uuid; v_role text;
begin
  select lane.tenant_id into v_tenant_id from public.shooting_lanes lane where lane.id=p_lane_id;
  if not found or v_tenant_id is null then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','lane_not_found');
  end if;
  v_role := public.get_my_tenant_role_v1(v_tenant_id);
  if v_role is distinct from 'user' then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code',
      case when auth.uid() is null then 'unauthorized' else 'not_allowed' end);
  end if;
  return public.create_reservation_v2__saas9d1_core(
    p_lane_id,p_reservation_date,p_start_time,p_duration_minutes,p_shooters_count,
    p_creation_request_id,p_reservation_note
  );
end;
$function$;

create function public.cancel_reservation(p_reservation_id uuid)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,pg_temp
as $function$
declare v_actor uuid:=auth.uid(); v_tenant uuid; v_owner uuid; v_role text;
begin
  if v_actor is null then raise exception 'Brak aktywnej sesji użytkownika.' using errcode='42501'; end if;
  if p_reservation_id is null then raise exception 'Brak identyfikatora rezerwacji.' using errcode='22023'; end if;
  select reservation.tenant_id,reservation.user_id into v_tenant,v_owner
  from public.reservations reservation where reservation.id=p_reservation_id;
  if not found then raise exception 'Nie znaleziono rezerwacji.' using errcode='P0002'; end if;
  v_role:=public.get_my_tenant_role_v1(v_tenant);
  if v_role is null or (v_owner is distinct from v_actor and v_role not in ('admin','employee')) then
    raise exception 'Brak uprawnień do anulowania tej rezerwacji.' using errcode='42501';
  end if;
  return public.cancel_reservation__saas9d1_core(p_reservation_id);
end;
$function$;

create function public.update_reservation_admin_note(p_reservation_id uuid,p_admin_note text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,pg_temp
as $function$
declare v_tenant uuid;
begin
  select tenant_id into v_tenant from public.reservations where id=p_reservation_id;
  if not found then return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','reservation_not_found'); end if;
  if public.get_my_tenant_role_v1(v_tenant) is null
     or public.get_my_tenant_role_v1(v_tenant) not in ('admin','employee') then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','not_allowed');
  end if;
  return public.update_reservation_admin_note__saas9d1_core(p_reservation_id,p_admin_note);
end;
$function$;

create function public.update_reservation_attendance(p_reservation_id uuid,p_action text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,pg_temp
as $function$
declare v_tenant uuid;
begin
  select tenant_id into v_tenant from public.reservations where id=p_reservation_id;
  if not found then return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','reservation_not_found'); end if;
  if public.get_my_tenant_role_v1(v_tenant) is null
     or public.get_my_tenant_role_v1(v_tenant) not in ('admin','employee') then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','not_allowed');
  end if;
  return public.update_reservation_attendance__saas9d1_core(p_reservation_id,p_action);
end;
$function$;

create function public.update_reservation_payment(p_reservation_id uuid,p_payment_status text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,pg_temp
as $function$
declare v_tenant uuid;
begin
  select tenant_id into v_tenant from public.reservations where id=p_reservation_id;
  if not found then return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','reservation_not_found'); end if;
  if public.get_my_tenant_role_v1(v_tenant) is null
     or public.get_my_tenant_role_v1(v_tenant) not in ('admin','employee') then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','not_allowed');
  end if;
  return public.update_reservation_payment__saas9d1_core(p_reservation_id,p_payment_status);
end;
$function$;

create function public.get_check_in_reservation_v1(p_token uuid)
returns table(
  reservation_id uuid,user_id uuid,customer_name text,customer_email text,customer_phone text,
  reservation_date date,start_time time without time zone,end_time time without time zone,
  reservation_status text,attendance_status text,payment_status text,checked_in_at timestamptz,
  completed_at timestamptz,price numeric,lane_id uuid,lane_name text,lane_resource_kind text,
  lane_parent_lane_id uuid,lane_display_order integer,lane_is_active boolean,parent_lane_id uuid,
  parent_lane_name text,parent_lane_resource_kind text,parent_lane_parent_lane_id uuid,
  parent_lane_display_order integer,parent_lane_is_active boolean
) language plpgsql stable security definer set search_path=pg_catalog,public,pg_temp
as $function$
declare v_tenant uuid;
begin
  if auth.uid() is null then raise exception 'Authentication is required.' using errcode='42501'; end if;
  if p_token is null then return; end if;
  select tenant_id into v_tenant from public.reservations where check_in_token=p_token;
  if not found then return; end if;
  if public.get_my_tenant_role_v1(v_tenant) is null
     or public.get_my_tenant_role_v1(v_tenant) not in ('admin','employee') then
    raise exception 'Check-in staff access is required.' using errcode='42501';
  end if;
  return query select * from public.get_check_in_reservation_v1__saas9d1_core(p_token);
end;
$function$;

create function public.get_public_check_in_status_v1(p_token uuid)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public,pg_temp
as $function$
declare v_tenant uuid;
begin
  if p_token is null then return pg_catalog.jsonb_build_object('ok',false,'code','unavailable'); end if;
  select reservation.tenant_id into v_tenant
  from public.reservations reservation join public.tenants tenant on tenant.id=reservation.tenant_id
  where reservation.check_in_token=p_token and tenant.status='active';
  if not found then return pg_catalog.jsonb_build_object('ok',false,'code','unavailable'); end if;
  return public.get_public_check_in_status_v1__saas9d1_core(p_token);
end;
$function$;

create function public.get_my_reservations_v2()
returns table(
  id uuid,reservation_date date,start_time time without time zone,end_time time without time zone,
  price numeric,reservation_status text,payment_status text,check_in_token uuid,
  attendance_status text,checked_in_at timestamptz,lane_display_name text
) language plpgsql stable security definer set search_path=pg_catalog,public,pg_temp
as $function$
begin
  if auth.uid() is null then raise exception 'Authentication is required.' using errcode='42501'; end if;
  return query
  select core.*
  from public.get_my_reservations_v2__saas9d1_core() core
  join public.reservations reservation on reservation.id=core.id
  join public.tenant_memberships membership
    on membership.tenant_id=reservation.tenant_id and membership.user_id=auth.uid()
   and membership.status='active'
  join public.tenants tenant on tenant.id=membership.tenant_id and tenant.status='active'
  order by core.reservation_date desc,core.start_time desc,core.id desc;
end;
$function$;

create function public.get_reservation_customer_profiles_v1(p_reservation_ids uuid[])
returns table(
  reservation_id uuid,user_id uuid,email text,full_name text,phone text,role text,
  verification_status text,postal_code text,city text,street text,house_number text,
  apartment_number text,permission_sport boolean,permission_collector boolean,
  permission_hunting boolean,permission_training boolean,permission_personal_protection boolean,
  permission_other boolean,qualification_instructor boolean,qualification_range_officer boolean,
  qualification_pzss_license boolean,qualification_hunter boolean,permissions_verified boolean,
  permissions_verified_at timestamptz,permissions_verification_note text,updated_at timestamptz
) language plpgsql stable security definer set search_path=pg_catalog,public,pg_temp
as $function$
declare v_requested integer; v_distinct integer; v_found integer; v_tenants integer; v_tenant uuid;
begin
  v_requested:=coalesce(pg_catalog.cardinality(p_reservation_ids),0);
  if v_requested<1 or v_requested>200 or pg_catalog.array_position(p_reservation_ids,null) is not null then
    raise exception 'Nieprawidłowy zakres rezerwacji.' using errcode='22023';
  end if;
  select pg_catalog.count(distinct id)::integer into v_distinct from pg_catalog.unnest(p_reservation_ids) requested(id);
  if v_distinct<>v_requested then raise exception 'Identyfikatory rezerwacji nie mogą się powtarzać.' using errcode='22023'; end if;
  select pg_catalog.count(*),pg_catalog.count(distinct tenant_id),pg_catalog.min(tenant_id::text)::uuid
  into v_found,v_tenants,v_tenant from public.reservations where id=any(p_reservation_ids);
  if v_found<>v_requested or v_tenants<>1 then raise exception 'Brak uprawnień do danych operacyjnych profilu.' using errcode='42501'; end if;
  if public.get_my_tenant_role_v1(v_tenant) is null
     or public.get_my_tenant_role_v1(v_tenant) not in ('admin','employee') then
    raise exception 'Brak uprawnień do danych operacyjnych profilu.' using errcode='42501';
  end if;
  return query select * from public.get_reservation_customer_profiles_v1__saas9d1_core(p_reservation_ids);
end;
$function$;

create function public.get_lane_booking_busy_ranges(p_lane_id uuid,p_reservation_date date)
returns table(start_time time without time zone,end_time time without time zone)
language plpgsql stable security definer set search_path=pg_catalog,public,pg_temp
as $function$
declare v_tenant uuid;
begin
  select tenant_id into v_tenant from public.shooting_lanes where id=p_lane_id;
  if not found or not public.is_tenant_member_v1(v_tenant) then raise exception 'Lane access is not allowed.' using errcode='42501'; end if;
  return query select * from public.get_lane_booking_busy_ranges__saas9d1_core(p_lane_id,p_reservation_date);
end;
$function$;

create function public.get_lane_booking_busy_ranges_v2(p_lane_id uuid,p_reservation_date date)
returns table(start_time time without time zone,end_time time without time zone,busy_type text)
language plpgsql stable security definer set search_path=pg_catalog,public,pg_temp
as $function$
declare v_tenant uuid;
begin
  select tenant_id into v_tenant from public.shooting_lanes where id=p_lane_id;
  if not found or not public.is_tenant_member_v1(v_tenant) then raise exception 'Lane access is not allowed.' using errcode='42501'; end if;
  return query select * from public.get_lane_booking_busy_ranges_v2__saas9d1_core(p_lane_id,p_reservation_date);
end;
$function$;

create function public.get_lane_booking_busy_ranges_v3(p_lane_id uuid,p_reservation_date date)
returns table(start_time time without time zone,end_time time without time zone,busy_type text)
language plpgsql stable security definer set search_path=pg_catalog,public,pg_temp
as $function$
declare v_tenant uuid;
begin
  select tenant_id into v_tenant from public.shooting_lanes where id=p_lane_id;
  if not found or not public.is_tenant_member_v1(v_tenant) then raise exception 'Lane access is not allowed.' using errcode='42501'; end if;
  return query select * from public.get_lane_booking_busy_ranges_v3__saas9d1_core(p_lane_id,p_reservation_date);
end;
$function$;

-- Restore the exact client-facing ownership and least-privilege grants.
alter function public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text) owner to postgres;
alter function public.cancel_reservation(uuid) owner to postgres;
alter function public.update_reservation_admin_note(uuid,text) owner to postgres;
alter function public.update_reservation_attendance(uuid,text) owner to postgres;
alter function public.update_reservation_payment(uuid,text) owner to postgres;
alter function public.get_check_in_reservation_v1(uuid) owner to postgres;
alter function public.get_public_check_in_status_v1(uuid) owner to postgres;
alter function public.get_my_reservations_v2() owner to postgres;
alter function public.get_reservation_customer_profiles_v1(uuid[]) owner to postgres;
alter function public.get_lane_booking_busy_ranges(uuid,date) owner to postgres;
alter function public.get_lane_booking_busy_ranges_v2(uuid,date) owner to postgres;
alter function public.get_lane_booking_busy_ranges_v3(uuid,date) owner to postgres;

revoke all on function public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text) from public,anon,authenticated,service_role;
revoke all on function public.cancel_reservation(uuid) from public,anon,authenticated,service_role;
revoke all on function public.update_reservation_admin_note(uuid,text) from public,anon,authenticated,service_role;
revoke all on function public.update_reservation_attendance(uuid,text) from public,anon,authenticated,service_role;
revoke all on function public.update_reservation_payment(uuid,text) from public,anon,authenticated,service_role;
revoke all on function public.get_check_in_reservation_v1(uuid) from public,anon,authenticated,service_role;
revoke all on function public.get_public_check_in_status_v1(uuid) from public,anon,authenticated,service_role;
revoke all on function public.get_my_reservations_v2() from public,anon,authenticated,service_role;
revoke all on function public.get_reservation_customer_profiles_v1(uuid[]) from public,anon,authenticated,service_role;
revoke all on function public.get_lane_booking_busy_ranges(uuid,date) from public,anon,authenticated,service_role;
revoke all on function public.get_lane_booking_busy_ranges_v2(uuid,date) from public,anon,authenticated,service_role;
revoke all on function public.get_lane_booking_busy_ranges_v3(uuid,date) from public,anon,authenticated,service_role;

grant execute on function public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text) to authenticated;
grant execute on function public.cancel_reservation(uuid) to authenticated;
grant execute on function public.update_reservation_admin_note(uuid,text) to authenticated;
grant execute on function public.update_reservation_attendance(uuid,text) to authenticated;
grant execute on function public.update_reservation_payment(uuid,text) to authenticated;
grant execute on function public.get_check_in_reservation_v1(uuid) to authenticated;
grant execute on function public.get_my_reservations_v2() to authenticated;
grant execute on function public.get_reservation_customer_profiles_v1(uuid[]) to authenticated;
grant execute on function public.get_lane_booking_busy_ranges(uuid,date) to authenticated;
grant execute on function public.get_lane_booking_busy_ranges_v2(uuid,date) to authenticated;
grant execute on function public.get_lane_booking_busy_ranges_v3(uuid,date) to authenticated;
grant execute on function public.get_public_check_in_status_v1(uuid) to anon;

-- Legacy reservation creation has no repository caller; remove its service bypass.
revoke all on function public.create_reservation(uuid,date,time without time zone,integer,integer,uuid,text)
  from public,anon,authenticated,service_role;

do $postflight$
begin
  if (select pg_catalog.count(*) from pg_catalog.pg_proc procedure
      join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace
      where namespace.nspname='public' and procedure.prosecdef) <> 73 then
    raise exception 'SAAS-9D-1 postflight failed: SECURITY DEFINER count differs.';
  end if;

  if exists (
    select 1 from saas9d1_unchanged_definer_snapshot snapshot
    left join pg_catalog.pg_proc procedure
      on procedure.proname=snapshot.proname
     and pg_catalog.pg_get_function_identity_arguments(procedure.oid)=snapshot.identity_arguments
     and procedure.pronamespace='public'::pg_catalog.regnamespace
    where procedure.oid is null
       or pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(
            pg_catalog.pg_get_functiondef(procedure.oid),E'\r\n',E'\n'
          ),E'\r',E'\n')) is distinct from snapshot.fingerprint
       or procedure.proowner is distinct from snapshot.proowner
       or procedure.proconfig is distinct from snapshot.proconfig
       or procedure.proacl is distinct from snapshot.proacl
  ) then
    raise exception 'SAAS-9D-1 postflight failed: unrelated SECURITY DEFINER changed.';
  end if;

  if exists (
    select 1 from pg_catalog.pg_proc procedure
    join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace
    where namespace.nspname='public'
      and procedure.proname in (
        'cancel_reservation','create_reservation_v2','get_check_in_reservation_v1',
        'get_lane_booking_busy_ranges','get_lane_booking_busy_ranges_v2',
        'get_lane_booking_busy_ranges_v3','get_my_reservations_v2',
        'get_public_check_in_status_v1','get_reservation_customer_profiles_v1',
        'update_reservation_admin_note','update_reservation_attendance','update_reservation_payment'
      )
      and (not procedure.prosecdef or procedure.proowner<>(select oid from pg_catalog.pg_roles where rolname='postgres')
           or procedure.proconfig is distinct from array['search_path=pg_catalog, public, pg_temp']::text[])
  ) then
    raise exception 'SAAS-9D-1 postflight failed: wrapper security metadata differs.';
  end if;

  if exists (
    select 1 from pg_catalog.pg_proc procedure
    join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace
    where namespace.nspname='public' and procedure.proname like '%__saas9d1_core'
      and (procedure.prosecdef or pg_catalog.has_function_privilege('public',procedure.oid,'EXECUTE')
           or pg_catalog.has_function_privilege('anon',procedure.oid,'EXECUTE')
           or pg_catalog.has_function_privilege('authenticated',procedure.oid,'EXECUTE')
           or pg_catalog.has_function_privilege('service_role',procedure.oid,'EXECUTE'))
  ) then
    raise exception 'SAAS-9D-1 postflight failed: internal core exposure differs.';
  end if;

  if (select column_default from information_schema.columns where table_schema='public' and table_name='reservations' and column_name='tenant_id')
        is distinct from '''c5c00000-0000-4000-8000-000000000001''::uuid' then
    raise exception 'SAAS-9D-1 postflight failed: temporary default state differs.';
  end if;
  if pg_catalog.strpos(
       pg_catalog.pg_get_functiondef('public.create_reservation_v2__saas9d1_core(uuid,date,time without time zone,integer,integer,uuid,text)'::pg_catalog.regprocedure),
       'v_lane.tenant_id, v_user_id, p_lane_id'
     )=0 then
    raise exception 'SAAS-9D-1 postflight failed: create core does not store the derived lane tenant.';
  end if;

  if pg_catalog.has_function_privilege('public','public.create_reservation(uuid,date,time without time zone,integer,integer,uuid,text)','EXECUTE')
     or pg_catalog.has_function_privilege('anon','public.create_reservation(uuid,date,time without time zone,integer,integer,uuid,text)','EXECUTE')
     or pg_catalog.has_function_privilege('authenticated','public.create_reservation(uuid,date,time without time zone,integer,integer,uuid,text)','EXECUTE')
     or pg_catalog.has_function_privilege('service_role','public.create_reservation(uuid,date,time without time zone,integer,integer,uuid,text)','EXECUTE') then
    raise exception 'SAAS-9D-1 postflight failed: legacy reservation writer remains exposed.';
  end if;

  if exists (
    select 1
    from saas9d1_legacy_snapshot snapshot
    join pg_catalog.pg_proc procedure
      on procedure.oid='public.create_reservation(uuid,date,time without time zone,integer,integer,uuid,text)'::pg_catalog.regprocedure
    where pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(
            pg_catalog.pg_get_functiondef(procedure.oid),E'\r\n',E'\n'
          ),E'\r',E'\n')) is distinct from snapshot.fingerprint
       or procedure.proowner is distinct from snapshot.proowner
       or procedure.proconfig is distinct from snapshot.proconfig
       or exists (
            select 1
            from pg_catalog.aclexplode(coalesce(
              procedure.proacl,pg_catalog.acldefault('f',procedure.proowner)
            )) grants
            where grants.grantee<>procedure.proowner
          )
  ) then
    raise exception 'SAAS-9D-1 postflight failed: legacy writer changed beyond approved ACL cleanup.';
  end if;
end;
$postflight$;

reset statement_timeout;
reset lock_timeout;
