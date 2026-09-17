begin;

set local lock_timeout = '5s';
set local statement_timeout = '120s';

do $preflight$
declare
  v_expected record;
  v_actual text;
begin
  if pg_catalog.to_regclass('public.tenant_user_verifications') is null then
    raise exception 'SAAS-9D-4B-2B preflight failed: verification foundation is missing.';
  end if;
  if pg_catalog.to_regprocedure('public.update_reservation_customer_verification_v1(uuid,text,text)') is not null
     or pg_catalog.to_regprocedure('public.get_my_active_tenant_verification_v1()') is not null
     or pg_catalog.to_regprocedure('public._apply_tenant_user_verification_v1(uuid,uuid,text,text,text,uuid)') is not null
     or pg_catalog.to_regprocedure('public._tenant_verification_status_for_lane_v1(uuid,uuid)') is not null then
    raise exception 'SAAS-9D-4B-2B preflight failed: target functions already exist.';
  end if;

  for v_expected in
    select * from (values
      ('public.update_profile_verification(uuid,text,text)'::regprocedure,'a0522b6beb94bde3bdff22799afc1368'),
      ('public.prevent_non_admin_profile_privilege_changes()'::regprocedure,'d28cb697d8355a5e8005296a03ad63ea'),
      ('public.admin_list_users_v1(integer,integer,text,text,text,text)'::regprocedure,'2a95b1f3ba9c404adfa84f7eb9b8d425'),
      ('public.get_reservation_customer_profiles_v1(uuid[])'::regprocedure,'5902d87f82e5dd15a71ad6d4842bf5cf'),
      ('public.update_my_profile_v1(text,text,text,text,text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean)'::regprocedure,'c160d8797e167741d36fa88348d952d1'),
      ('public.create_reservation_v2__saas9d1_core(uuid,date,time without time zone,integer,integer,uuid,text)'::regprocedure,'b16bda3267a5db217d6b3e282b013968'),
      ('public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)'::regprocedure,'ff1c273379e9ee3af3a1a60d131af81b'),
      ('public.create_reservation(uuid,date,time without time zone,integer,integer,uuid,text)'::regprocedure,'3212b32f37ebc8e665a9a94e94260976'),
      ('public.set_audit_log_tenant_id()'::regprocedure,'')
    ) expected(signature,fingerprint)
  loop
    v_actual:=pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(
      pg_catalog.pg_get_functiondef(v_expected.signature),pg_catalog.chr(13)||pg_catalog.chr(10),pg_catalog.chr(10)),pg_catalog.chr(13),pg_catalog.chr(10)));
    if v_expected.fingerprint<>'' and v_actual<>v_expected.fingerprint then
      raise exception 'SAAS-9D-4B-2B preflight failed: % fingerprint drift (%).',v_expected.signature,v_actual;
    end if;
  end loop;

  if (select pg_catalog.count(*) from pg_catalog.pg_proc procedure
      join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace
      where namespace.nspname='public' and procedure.prosecdef)<>67 then
    raise exception 'SAAS-9D-4B-2B preflight failed: SECURITY DEFINER baseline differs.';
  end if;
  if (select pg_catalog.count(*) from information_schema.columns
      where table_schema='public'
        and table_name in('shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','email_deliveries')
        and column_name='tenant_id'
        and column_default='''c5c00000-0000-4000-8000-000000000001''::uuid')<>7 then
    raise exception 'SAAS-9D-4B-2B preflight failed: compatibility defaults differ.';
  end if;
  if (select pg_catalog.count(*) from pg_catalog.pg_policies
      where schemaname='public' and tablename='tenant_user_verifications')<>0
     or pg_catalog.has_table_privilege('anon','public.tenant_user_verifications','SELECT,INSERT,UPDATE,DELETE')
     or pg_catalog.has_table_privilege('authenticated','public.tenant_user_verifications','SELECT,INSERT,UPDATE,DELETE')
     or pg_catalog.has_table_privilege('service_role','public.tenant_user_verifications','SELECT,INSERT,UPDATE,DELETE') then
    raise exception 'SAAS-9D-4B-2B preflight failed: verification table is not closed.';
  end if;
end;
$preflight$;

create or replace function public.set_audit_log_tenant_id()
returns trigger
language plpgsql
set search_path=pg_catalog
as $function$
declare
  v_tenant_id uuid;
begin
  case new.target_type
    when 'reservation' then
      select record.tenant_id into v_tenant_id from public.reservations record where record.id=new.target_id;
    when 'event_registration' then
      select record.tenant_id into v_tenant_id from public.event_registrations record where record.id=new.target_id;
    when 'lane_booking_family' then
      select record.tenant_id into v_tenant_id from public.shooting_lanes record where record.id=new.target_id;
    when 'tenant_user_admin_note' then
      if new.action is distinct from 'tenant_user_admin_note_updated' then raise exception using errcode='23514',message='tenant_user_admin_note_audit_mismatch'; end if;
    when 'tenant_user_role' then
      if new.action is distinct from 'tenant_user_role_updated' then raise exception using errcode='23514',message='tenant_user_role_audit_mismatch'; end if;
    when 'tenant_user_identity' then
      if new.action is distinct from 'tenant_user_identity_updated' then raise exception using errcode='23514',message='tenant_user_identity_audit_mismatch'; end if;
    when 'tenant_user_contact' then
      if new.action is distinct from 'tenant_user_contact_updated' then raise exception using errcode='23514',message='tenant_user_contact_audit_mismatch'; end if;
    when 'tenant_user_verification' then
      if new.action not in('tenant_user_verification_verified','tenant_user_verification_marked_pending','tenant_user_verification_rejected','tenant_user_verification_invalidated') then
        raise exception using errcode='23514',message='tenant_user_verification_audit_mismatch';
      end if;
    when 'profile','account' then
      if new.tenant_id is not null then raise exception using errcode='23514',message='global_audit_must_not_have_tenant'; end if;
      return new;
    else
      raise exception using errcode='23514',message='unsupported_audit_target_type';
  end case;

  if new.target_type like 'tenant_user_%' then
    if new.tenant_id is null or new.target_id is null
       or not exists(select 1 from public.tenants tenant where tenant.id=new.tenant_id)
       or not exists(select 1 from public.profiles profile where profile.user_id=new.target_id)
       or not (
         exists(select 1 from public.tenant_memberships membership where membership.tenant_id=new.tenant_id and membership.user_id=new.target_id)
         or exists(select 1 from public.reservations reservation where reservation.tenant_id=new.tenant_id and reservation.user_id=new.target_id)
         or exists(select 1 from public.event_registrations registration join public.events event_record on event_record.id=registration.event_id and event_record.tenant_id=registration.tenant_id where registration.tenant_id=new.tenant_id and registration.user_id=new.target_id)
       ) then
      raise exception using errcode='23514',message='tenant_user_audit_mismatch';
    end if;
    return new;
  end if;
  if v_tenant_id is null then raise exception using errcode='23503',message='audit_target_not_found'; end if;
  if new.tenant_id is not null and new.tenant_id is distinct from v_tenant_id then raise exception using errcode='23514',message='audit_tenant_mismatch'; end if;
  new.tenant_id:=v_tenant_id;
  return new;
end;
$function$;

alter function public.set_audit_log_tenant_id() owner to postgres;
revoke all on function public.set_audit_log_tenant_id() from public,anon,authenticated,service_role;

create function public._tenant_verification_status_for_lane_v1(p_lane_id uuid,p_user_id uuid)
returns text
language sql stable security invoker
set search_path=pg_catalog,public,pg_temp
as $function$
  select coalesce(verification.verification_status,'pending')
  from public.shooting_lanes lane
  left join public.tenant_user_verifications verification
    on verification.tenant_id=lane.tenant_id and verification.user_id=p_user_id
  where lane.id=p_lane_id;
$function$;

alter function public._tenant_verification_status_for_lane_v1(uuid,uuid) owner to postgres;
revoke all on function public._tenant_verification_status_for_lane_v1(uuid,uuid) from public,anon,authenticated,service_role;

create function public._apply_tenant_user_verification_v1(
  p_tenant_id uuid,p_target_user_id uuid,p_action text,p_note text,
  p_resource_type text,p_resource_id uuid
) returns jsonb
language plpgsql security invoker
set search_path=pg_catalog,public,pg_temp
as $function$
declare
  v_actor_id uuid:=auth.uid();
  v_actor_role text;
  v_actor_profile_id uuid;
  v_action text:=pg_catalog.lower(pg_catalog.btrim(coalesce(p_action,'')));
  v_note text:=nullif(pg_catalog.btrim(coalesce(p_note,'')),'');
  v_old public.tenant_user_verifications%rowtype;
  v_updated public.tenant_user_verifications%rowtype;
  v_status text;
  v_permissions boolean;
  v_now timestamptz:=pg_catalog.transaction_timestamp();
  v_audit_action text;
begin
  if v_actor_id is null or p_tenant_id is null or p_target_user_id is null
     or v_action not in('verify','mark_pending','reject')
     or pg_catalog.char_length(v_note)>2000 then
    raise exception 'Nieprawidłowa operacja weryfikacyjna.' using errcode='22023';
  end if;
  select membership.role into v_actor_role
  from public.tenant_memberships membership
  join public.tenants tenant on tenant.id=membership.tenant_id and tenant.status='active'
  where membership.tenant_id=p_tenant_id and membership.user_id=v_actor_id and membership.status='active';
  if v_actor_role is null or v_actor_role not in('admin','employee') then
    raise exception 'Brak uprawnień do weryfikacji.' using errcode='42501';
  end if;
  select profile.id into v_actor_profile_id from public.profiles profile where profile.user_id=v_actor_id;
  if v_actor_profile_id is null then raise exception 'Brak profilu operatora.' using errcode='42501'; end if;

  insert into public.tenant_user_verifications(tenant_id,user_id)
  values(p_tenant_id,p_target_user_id) on conflict(tenant_id,user_id) do nothing;
  select verification.* into v_old from public.tenant_user_verifications verification
  where verification.tenant_id=p_tenant_id and verification.user_id=p_target_user_id for update;

  v_status:=case v_action when 'verify' then 'verified' when 'reject' then 'rejected' else 'pending' end;
  v_permissions:=v_action='verify';
  v_note:=coalesce(v_note,case v_action
    when 'verify' then 'Uprawnienia klienta zostały zweryfikowane podczas wizyty.'
    when 'reject' then 'Weryfikacja klienta została odrzucona.'
    else 'Weryfikacja klienta oczekuje na ponowne sprawdzenie.' end);

  if v_old.verification_status=v_status
     and v_old.permissions_verified=v_permissions
     and v_old.permissions_verification_note is not distinct from v_note then
    return pg_catalog.jsonb_build_object('ok',true,'changed',false,'code','no_change','user_id',p_target_user_id,
      'verification_status',v_old.verification_status,'permissions_verified',v_old.permissions_verified,
      'permissions_verified_at',v_old.permissions_verified_at,'permissions_verified_by',v_old.permissions_verified_by,
      'permissions_verification_note',v_old.permissions_verification_note,'verified_at',v_old.verified_at,
      'verified_by',v_old.verified_by,'unverified_at',v_old.unverified_at,'unverified_by',v_old.unverified_by,'updated_at',v_old.updated_at);
  end if;

  update public.tenant_user_verifications verification set
    verification_status=v_status,permissions_verified=v_permissions,
    permissions_verified_at=case when v_action='verify' then v_now else null end,
    permissions_verified_by=case when v_action='verify' then v_actor_id else null end,
    permissions_verification_note=v_note,
    verified_at=case when v_action='verify' then v_now else null end,
    verified_by=case when v_action='verify' then v_actor_id else null end,
    unverified_at=case when v_action='verify' then null else v_now end,
    unverified_by=case when v_action='verify' then null else v_actor_id end,
    updated_at=v_now
  where verification.tenant_id=p_tenant_id and verification.user_id=p_target_user_id
  returning verification.* into v_updated;

  perform pg_catalog.set_config('csk.profile_verification_rpc_actor',v_actor_id::text,true);
  perform pg_catalog.set_config('csk.profile_verification_rpc_target',p_target_user_id::text,true);
  update public.profiles profile set
    verification_status=v_updated.verification_status,
    permissions_verified=v_updated.permissions_verified,
    permissions_verified_at=v_updated.permissions_verified_at,
    permissions_verified_by=case when v_updated.permissions_verified_by is null then null else v_actor_profile_id end,
    permissions_verification_note=v_updated.permissions_verification_note,
    verified_at=v_updated.verified_at,
    verified_by=case when v_updated.verified_by is null then null else v_actor_profile_id end,
    unverified_at=v_updated.unverified_at,
    unverified_by=case when v_updated.unverified_by is null then null else v_actor_profile_id::text end,
    updated_at=v_now
  where profile.user_id=p_target_user_id;
  perform pg_catalog.set_config('csk.profile_verification_rpc_actor','',true);
  perform pg_catalog.set_config('csk.profile_verification_rpc_target','',true);

  v_audit_action:=case v_action when 'verify' then 'tenant_user_verification_verified' when 'reject' then 'tenant_user_verification_rejected' else 'tenant_user_verification_marked_pending' end;
  insert into public.audit_logs(tenant_id,actor_user_id,actor_name,actor_role,action,target_type,target_id,target_name,details)
  values(p_tenant_id,v_actor_id,'Tenant staff',v_actor_role,v_audit_action,'tenant_user_verification',p_target_user_id,'Tenant user',
    pg_catalog.jsonb_build_object('previous_status',v_old.verification_status,'new_status',v_updated.verification_status,
      'previous_permissions_verified',v_old.permissions_verified,'new_permissions_verified',v_updated.permissions_verified,
      'resource_type',p_resource_type,'resource_id',p_resource_id,'operator_role',v_actor_role));

  return pg_catalog.jsonb_build_object('ok',true,'changed',true,'code','updated','user_id',p_target_user_id,
    'verification_status',v_updated.verification_status,'permissions_verified',v_updated.permissions_verified,
    'permissions_verified_at',v_updated.permissions_verified_at,'permissions_verified_by',v_updated.permissions_verified_by,
    'permissions_verification_note',v_updated.permissions_verification_note,'verified_at',v_updated.verified_at,
    'verified_by',v_updated.verified_by,'unverified_at',v_updated.unverified_at,'unverified_by',v_updated.unverified_by,'updated_at',v_updated.updated_at);
end;
$function$;

alter function public._apply_tenant_user_verification_v1(uuid,uuid,text,text,text,uuid) owner to postgres;
revoke all on function public._apply_tenant_user_verification_v1(uuid,uuid,text,text,text,uuid) from public,anon,authenticated,service_role;

create or replace function public.update_profile_verification(p_target_user_id uuid,p_action text,p_note text default null)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,pg_temp
as $function$
declare
  v_actor_id uuid:=auth.uid();
  v_tenant_id uuid:=public.active_single_tenant_id_v1();
  v_actor_role text;
  v_target_role text;
begin
  if v_actor_id is null or v_tenant_id is null or p_target_user_id is null then raise exception 'Brak uprawnień do weryfikacji profili.' using errcode='42501'; end if;
  select membership.role into v_actor_role from public.tenant_memberships membership
  where membership.tenant_id=v_tenant_id and membership.user_id=v_actor_id and membership.status='active' for update;
  if v_actor_role is null or v_actor_role not in('admin','employee') then raise exception 'Brak uprawnień do weryfikacji profili.' using errcode='42501'; end if;
  if not (
    exists(select 1 from public.tenant_memberships membership where membership.tenant_id=v_tenant_id and membership.user_id=p_target_user_id)
    or exists(select 1 from public.reservations reservation where reservation.tenant_id=v_tenant_id and reservation.user_id=p_target_user_id)
    or exists(select 1 from public.event_registrations registration join public.events event_record on event_record.id=registration.event_id and event_record.tenant_id=registration.tenant_id where registration.tenant_id=v_tenant_id and registration.user_id=p_target_user_id)
  ) then raise exception 'Brak uprawnień do weryfikacji profili.' using errcode='42501'; end if;
  select membership.role into v_target_role from public.tenant_memberships membership where membership.tenant_id=v_tenant_id and membership.user_id=p_target_user_id;
  if v_actor_role='employee' and (p_target_user_id=v_actor_id or v_target_role in('admin','employee','instructor')) then
    raise exception 'Pracownik może weryfikować wyłącznie klienta.' using errcode='42501';
  end if;
  return public._apply_tenant_user_verification_v1(v_tenant_id,p_target_user_id,p_action,p_note,'operational_relation',null);
end;
$function$;

alter function public.update_profile_verification(uuid,text,text) owner to postgres;
revoke all on function public.update_profile_verification(uuid,text,text) from public,anon,authenticated,service_role;
grant execute on function public.update_profile_verification(uuid,text,text) to authenticated;

create function public.update_reservation_customer_verification_v1(p_reservation_id uuid,p_action text,p_note text default null)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,pg_temp
as $function$
declare
  v_actor_id uuid:=auth.uid();
  v_reservation public.reservations%rowtype;
  v_actor_role text;
  v_target_role text;
begin
  if v_actor_id is null or p_reservation_id is null then raise exception 'Brak uprawnień do weryfikacji rezerwacji.' using errcode='42501'; end if;
  select reservation.* into v_reservation from public.reservations reservation where reservation.id=p_reservation_id for update;
  if not found or v_reservation.user_id is null then raise exception 'Brak uprawnień do weryfikacji rezerwacji.' using errcode='42501'; end if;
  select membership.role into v_actor_role from public.tenant_memberships membership
  join public.tenants tenant on tenant.id=membership.tenant_id and tenant.status='active'
  where membership.tenant_id=v_reservation.tenant_id and membership.user_id=v_actor_id and membership.status='active' for update of membership;
  if v_actor_role is null or v_actor_role not in('admin','employee') then raise exception 'Brak uprawnień do weryfikacji rezerwacji.' using errcode='42501'; end if;
  select membership.role into v_target_role from public.tenant_memberships membership
  where membership.tenant_id=v_reservation.tenant_id and membership.user_id=v_reservation.user_id;
  if v_actor_role='employee' and (v_reservation.user_id=v_actor_id or v_target_role in('admin','employee','instructor')) then
    raise exception 'Pracownik może weryfikować wyłącznie klienta.' using errcode='42501';
  end if;
  return public._apply_tenant_user_verification_v1(v_reservation.tenant_id,v_reservation.user_id,p_action,p_note,'reservation',v_reservation.id);
end;
$function$;

alter function public.update_reservation_customer_verification_v1(uuid,text,text) owner to postgres;
revoke all on function public.update_reservation_customer_verification_v1(uuid,text,text) from public,anon,authenticated,service_role;
grant execute on function public.update_reservation_customer_verification_v1(uuid,text,text) to authenticated;

create function public.get_my_active_tenant_verification_v1()
returns table(verification_status text,permissions_verified boolean,permissions_verified_at timestamptz,updated_at timestamptz)
language plpgsql stable security definer set search_path=pg_catalog,public,pg_temp
as $function$
declare
  v_user_id uuid:=auth.uid();
  v_tenant_id uuid:=public.active_single_tenant_id_v1();
begin
  if v_user_id is null or v_tenant_id is null then raise exception 'Brak kontekstu weryfikacji.' using errcode='42501'; end if;
  return query select coalesce(verification.verification_status,'pending'),coalesce(verification.permissions_verified,false),
    verification.permissions_verified_at,verification.updated_at
  from (select 1) anchor
  left join public.tenant_user_verifications verification on verification.tenant_id=v_tenant_id and verification.user_id=v_user_id;
end;
$function$;

alter function public.get_my_active_tenant_verification_v1() owner to postgres;
revoke all on function public.get_my_active_tenant_verification_v1() from public,anon,authenticated,service_role;
grant execute on function public.get_my_active_tenant_verification_v1() to authenticated;

create or replace function public.admin_list_users_v1(
  p_limit integer default 50,p_offset integer default 0,p_search text default null,
  p_role text default null,p_verification_filter text default null,p_sort text default 'newest'
) returns table(
  user_id uuid,email text,first_name text,last_name text,full_name text,phone text,
  role text,verification_status text,admin_note text,created_at timestamptz,
  updated_at timestamptz,postal_code text,city text,street text,house_number text,
  apartment_number text,permission_sport boolean,permission_collector boolean,
  permission_hunting boolean,permission_training boolean,permission_personal_protection boolean,
  permission_other boolean,qualification_instructor boolean,qualification_range_officer boolean,
  qualification_pzss_license boolean,qualification_hunter boolean,permissions_verified boolean,
  permissions_verified_at timestamptz,permissions_verification_note text,total_count bigint
) language plpgsql stable security definer set search_path=pg_catalog,public,pg_temp
as $function$
declare
  v_actor_id uuid:=auth.uid(); v_tenant_id uuid:=public.active_single_tenant_id_v1();
  v_search text:=nullif(pg_catalog.btrim(p_search),''); v_role text:=nullif(pg_catalog.lower(pg_catalog.btrim(p_role)),'');
  v_verification text:=nullif(pg_catalog.lower(pg_catalog.btrim(p_verification_filter)),'');
  v_sort text:=pg_catalog.lower(pg_catalog.btrim(coalesce(p_sort,'newest')));
begin
  if v_actor_id is null or v_tenant_id is null or public.get_my_tenant_role_v1(v_tenant_id) is distinct from 'admin' then raise exception 'Brak uprawnień do listy użytkowników.' using errcode='42501'; end if;
  if p_limit is null or p_limit<1 or p_limit>100 or p_offset is null or p_offset<0 then raise exception 'Nieprawidłowe parametry stronicowania.' using errcode='22023'; end if;
  if v_role is not null and v_role not in('admin','pracownik','instruktor','user') then raise exception 'Nieprawidłowy filtr roli.' using errcode='22023'; end if;
  if v_verification is not null and v_verification not in('pending','unverified','verified','rejected') then raise exception 'Nieprawidłowy filtr weryfikacji.' using errcode='22023'; end if;
  if v_sort not in('newest','oldest','name','role') then raise exception 'Nieprawidłowy sposób sortowania.' using errcode='22023'; end if;
  return query
  with eligible_users as materialized(
    select membership.user_id from public.tenant_memberships membership where membership.tenant_id=v_tenant_id
    union select reservation.user_id from public.reservations reservation where reservation.tenant_id=v_tenant_id and reservation.user_id is not null
    union select registration.user_id from public.event_registrations registration join public.events event_record on event_record.id=registration.event_id and event_record.tenant_id=registration.tenant_id where registration.tenant_id=v_tenant_id and registration.user_id is not null
  ), scoped as materialized(
    select profile.*,
      case membership.role when 'employee' then 'pracownik' when 'instructor' then 'instruktor' when 'admin' then 'admin' else 'user' end as tenant_role,
      note.admin_note as tenant_admin_note,
      coalesce(verification.verification_status,'pending') as tenant_verification_status,
      coalesce(verification.permissions_verified,false) as tenant_permissions_verified,
      verification.permissions_verified_at as tenant_permissions_verified_at,
      verification.permissions_verification_note as tenant_permissions_verification_note,
      greatest(profile.updated_at,note.updated_at,verification.updated_at) as scoped_updated_at
    from eligible_users eligible join public.profiles profile on profile.user_id=eligible.user_id
    left join public.tenant_memberships membership on membership.tenant_id=v_tenant_id and membership.user_id=eligible.user_id
    left join public.tenant_user_admin_notes note on note.tenant_id=v_tenant_id and note.user_id=eligible.user_id
    left join public.tenant_user_verifications verification on verification.tenant_id=v_tenant_id and verification.user_id=eligible.user_id
  ), filtered as(
    select scoped.* from scoped where (v_role is null or scoped.tenant_role=v_role)
      and (v_verification is null
        or (v_verification='pending' and scoped.tenant_verification_status='pending')
        or (v_verification='verified' and scoped.tenant_verification_status='verified' and scoped.tenant_permissions_verified)
        or (v_verification='rejected' and scoped.tenant_verification_status='rejected')
        or (v_verification='unverified' and (scoped.tenant_verification_status is distinct from 'verified' or not scoped.tenant_permissions_verified)))
      and (v_search is null or coalesce(scoped.first_name,'') ilike '%'||v_search||'%' or coalesce(scoped.last_name,'') ilike '%'||v_search||'%' or coalesce(scoped.full_name,'') ilike '%'||v_search||'%' or coalesce(scoped.email,'') ilike '%'||v_search||'%' or coalesce(scoped.phone,'') ilike '%'||v_search||'%')
  )
  select filtered.user_id,filtered.email,filtered.first_name,filtered.last_name,filtered.full_name,filtered.phone,
    filtered.tenant_role,filtered.tenant_verification_status,filtered.tenant_admin_note,filtered.created_at,filtered.scoped_updated_at,
    filtered.postal_code,filtered.city,filtered.street,filtered.house_number,filtered.apartment_number,
    filtered.permission_sport,filtered.permission_collector,filtered.permission_hunting,filtered.permission_training,
    filtered.permission_personal_protection,filtered.permission_other,filtered.qualification_instructor,
    filtered.qualification_range_officer,filtered.qualification_pzss_license,filtered.qualification_hunter,
    filtered.tenant_permissions_verified,filtered.tenant_permissions_verified_at,filtered.tenant_permissions_verification_note,
    pg_catalog.count(*) over()
  from filtered order by
    case when v_sort='newest' then filtered.created_at end desc nulls last,
    case when v_sort='oldest' then filtered.created_at end asc nulls last,
    case when v_sort='name' then pg_catalog.lower(coalesce(nullif(pg_catalog.btrim(filtered.full_name),''),nullif(pg_catalog.btrim(filtered.first_name||' '||filtered.last_name),''),filtered.email,'')) end asc,
    case when v_sort='role' then filtered.tenant_role end asc,filtered.user_id asc
  limit p_limit offset p_offset;
end;
$function$;

alter function public.admin_list_users_v1(integer,integer,text,text,text,text) owner to postgres;
revoke all on function public.admin_list_users_v1(integer,integer,text,text,text,text) from public,anon,authenticated,service_role;
grant execute on function public.admin_list_users_v1(integer,integer,text,text,text,text) to authenticated;

create or replace function public.get_reservation_customer_profiles_v1(p_reservation_ids uuid[])
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
  if v_requested<1 or v_requested>200 or pg_catalog.array_position(p_reservation_ids,null) is not null then raise exception 'Nieprawidłowy zakres rezerwacji.' using errcode='22023'; end if;
  select pg_catalog.count(distinct id)::integer into v_distinct from pg_catalog.unnest(p_reservation_ids) requested(id);
  if v_distinct<>v_requested then raise exception 'Identyfikatory rezerwacji nie mogą się powtarzać.' using errcode='22023'; end if;
  select pg_catalog.count(*),pg_catalog.count(distinct tenant_id),pg_catalog.min(tenant_id::text)::uuid into v_found,v_tenants,v_tenant from public.reservations where id=any(p_reservation_ids);
  if v_found<>v_requested or v_tenants<>1 or public.get_my_tenant_role_v1(v_tenant) not in('admin','employee') then raise exception 'Brak uprawnień do danych operacyjnych profilu.' using errcode='42501'; end if;
  return query
  select reservation.id,profile.user_id,profile.email,profile.full_name,profile.phone,
    case membership.role when 'employee' then 'pracownik' when 'instructor' then 'instruktor' when 'admin' then 'admin' else 'user' end,
    coalesce(verification.verification_status,'pending'),profile.postal_code,profile.city,profile.street,profile.house_number,profile.apartment_number,
    profile.permission_sport,profile.permission_collector,profile.permission_hunting,profile.permission_training,
    profile.permission_personal_protection,profile.permission_other,profile.qualification_instructor,
    profile.qualification_range_officer,profile.qualification_pzss_license,profile.qualification_hunter,
    coalesce(verification.permissions_verified,false),verification.permissions_verified_at,
    verification.permissions_verification_note,greatest(profile.updated_at,verification.updated_at)
  from public.reservations reservation
  join public.profiles profile on profile.user_id=reservation.user_id
  left join public.tenant_memberships membership on membership.tenant_id=reservation.tenant_id and membership.user_id=reservation.user_id
  left join public.tenant_user_verifications verification on verification.tenant_id=reservation.tenant_id and verification.user_id=reservation.user_id
  where reservation.id=any(p_reservation_ids)
  order by pg_catalog.array_position(p_reservation_ids,reservation.id);
end;
$function$;

alter function public.get_reservation_customer_profiles_v1(uuid[]) owner to postgres;
revoke all on function public.get_reservation_customer_profiles_v1(uuid[]) from public,anon,authenticated,service_role;
grant execute on function public.get_reservation_customer_profiles_v1(uuid[]) to authenticated;

do $patch_booking$
declare
  v_signature regprocedure;
  v_definition text;
  v_patched text;
begin
  foreach v_signature in array array[
    'public.create_reservation_v2__saas9d1_core(uuid,date,time without time zone,integer,integer,uuid,text)'::regprocedure,
    'public.create_reservation(uuid,date,time without time zone,integer,integer,uuid,text)'::regprocedure
  ] loop
    v_definition:=pg_catalog.pg_get_functiondef(v_signature);
    v_patched:=pg_catalog.regexp_replace(v_definition,
      E'v_verification_status := pg_catalog\\.lower\\(\\s*pg_catalog\\.btrim\\(\\s*coalesce\\(v_profile\\.verification_status::text, ''pending''\\)\\s*\\)\\s*\\);',
      E'v_verification_status := public._tenant_verification_status_for_lane_v1(p_lane_id,v_user_id);','n');
    v_patched:=pg_catalog.regexp_replace(v_patched,
      E'where reservation\\.user_id = v_user_id\\s+and pg_catalog\\.lower\\(',
      E'where reservation.user_id = v_user_id\n         and reservation.tenant_id=(select lane.tenant_id from public.shooting_lanes lane where lane.id=p_lane_id)\n         and pg_catalog.lower(','n');
    if v_patched=v_definition
       or pg_catalog.strpos(v_patched,'v_profile.verification_status::text')>0
       or pg_catalog.strpos(v_patched,'reservation.tenant_id=(select lane.tenant_id')=0 then
      raise exception 'SAAS-9D-4B-2B booking patch failed for %.',v_signature;
    end if;
    execute v_patched;
  end loop;
end;
$patch_booking$;

create or replace function public.update_my_profile_v1(
  p_phone text,p_postal_code text,p_city text,p_street text,p_house_number text,p_apartment_number text,
  p_permission_sport boolean,p_permission_collector boolean,p_permission_hunting boolean,p_permission_training boolean,
  p_permission_personal_protection boolean,p_permission_other boolean,p_qualification_instructor boolean,
  p_qualification_range_officer boolean,p_qualification_pzss_license boolean,p_qualification_hunter boolean
) returns jsonb language plpgsql volatile security definer set search_path=pg_catalog,public,pg_temp
as $function$
declare
  v_user_id uuid:=auth.uid(); v_profile public.profiles%rowtype; v_updated public.profiles%rowtype;
  v_phone text:=pg_catalog.btrim(coalesce(p_phone,'')); v_postal text:=pg_catalog.btrim(coalesce(p_postal_code,''));
  v_city text:=pg_catalog.btrim(coalesce(p_city,'')); v_street text:=pg_catalog.btrim(coalesce(p_street,''));
  v_house text:=pg_catalog.btrim(coalesce(p_house_number,'')); v_apartment text:=nullif(pg_catalog.btrim(coalesce(p_apartment_number,'')),'');
  v_declarations_changed boolean; v_changed boolean; v_tenant_id uuid:=public.active_single_tenant_id_v1();
  v_status text; v_permissions boolean; v_permissions_at timestamptz; v_row record;
begin
  if v_user_id is null then return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','not_allowed'); end if;
  if p_permission_sport is null or p_permission_collector is null or p_permission_hunting is null or p_permission_training is null or p_permission_personal_protection is null or p_permission_other is null or p_qualification_instructor is null or p_qualification_range_officer is null or p_qualification_pzss_license is null or p_qualification_hunter is null
     or pg_catalog.length(v_phone)>32 or pg_catalog.length(v_postal)>20 or pg_catalog.length(v_city)>120 or pg_catalog.length(v_street)>160 or pg_catalog.length(v_house)>30 or pg_catalog.length(v_apartment)>30 then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','invalid_input');
  end if;
  select profile.* into v_profile from public.profiles profile where profile.user_id=v_user_id for update;
  if not found then return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','profile_not_found'); end if;
  v_declarations_changed:=v_profile.permission_sport is distinct from p_permission_sport or v_profile.permission_collector is distinct from p_permission_collector or v_profile.permission_hunting is distinct from p_permission_hunting or v_profile.permission_training is distinct from p_permission_training or v_profile.permission_personal_protection is distinct from p_permission_personal_protection or v_profile.permission_other is distinct from p_permission_other or v_profile.qualification_instructor is distinct from p_qualification_instructor or v_profile.qualification_range_officer is distinct from p_qualification_range_officer or v_profile.qualification_pzss_license is distinct from p_qualification_pzss_license or v_profile.qualification_hunter is distinct from p_qualification_hunter;
  v_changed:=v_declarations_changed or v_profile.phone is distinct from v_phone or v_profile.postal_code is distinct from v_postal or v_profile.city is distinct from v_city or v_profile.street is distinct from v_street or v_profile.house_number is distinct from v_house or v_profile.apartment_number is distinct from v_apartment;
  if v_changed then
    update public.profiles profile set phone=v_phone,postal_code=v_postal,city=v_city,street=v_street,house_number=v_house,apartment_number=v_apartment,
      permission_sport=p_permission_sport,permission_collector=p_permission_collector,permission_hunting=p_permission_hunting,permission_training=p_permission_training,
      permission_personal_protection=p_permission_personal_protection,permission_other=p_permission_other,qualification_instructor=p_qualification_instructor,
      qualification_range_officer=p_qualification_range_officer,qualification_pzss_license=p_qualification_pzss_license,qualification_hunter=p_qualification_hunter
    where profile.user_id=v_user_id returning profile.* into v_updated;
  else v_updated:=v_profile; end if;

  if v_declarations_changed then
    for v_row in
      update public.tenant_user_verifications verification set verification_status='pending',permissions_verified=false,
        permissions_verified_at=null,permissions_verified_by=null,permissions_verification_note=null,verified_at=null,verified_by=null,
        unverified_at=pg_catalog.transaction_timestamp(),unverified_by=v_user_id,updated_at=pg_catalog.transaction_timestamp()
      where verification.user_id=v_user_id and (verification.verification_status<>'pending' or verification.permissions_verified or verification.permissions_verification_note is not null)
      returning verification.tenant_id
    loop
      insert into public.audit_logs(tenant_id,actor_user_id,actor_name,actor_role,action,target_type,target_id,target_name,details)
      values(v_row.tenant_id,v_user_id,'Account owner','user','tenant_user_verification_invalidated','tenant_user_verification',v_user_id,'Tenant user',
        pg_catalog.jsonb_build_object('reason','declarations_changed','operator_role','user'));
    end loop;
  end if;
  select coalesce(verification.verification_status,'pending'),coalesce(verification.permissions_verified,false),verification.permissions_verified_at
  into v_status,v_permissions,v_permissions_at from (select 1) anchor left join public.tenant_user_verifications verification on verification.tenant_id=v_tenant_id and verification.user_id=v_user_id;
  return pg_catalog.jsonb_build_object('ok',true,'changed',v_changed,'code',case when v_changed then 'updated' else 'no_change' end,
    'declarations_changed',v_declarations_changed,'verification_status',coalesce(v_status,'pending'),
    'permissions_verified',coalesce(v_permissions,false),'permissions_verified_at',v_permissions_at,'updated_at',v_updated.updated_at);
end;
$function$;

alter function public.update_my_profile_v1(text,text,text,text,text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean) owner to postgres;
revoke all on function public.update_my_profile_v1(text,text,text,text,text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean) from public,anon,authenticated,service_role;
grant execute on function public.update_my_profile_v1(text,text,text,text,text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean) to authenticated;

do $postflight$
begin
  if pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef('public.prevent_non_admin_profile_privilege_changes()'::regprocedure),pg_catalog.chr(13)||pg_catalog.chr(10),pg_catalog.chr(10)),pg_catalog.chr(13),pg_catalog.chr(10)))<>'d28cb697d8355a5e8005296a03ad63ea' then
    raise exception 'SAAS-9D-4B-2B postflight failed: frozen profile trigger drifted.';
  end if;
  if (select pg_catalog.count(*) from pg_catalog.pg_proc procedure join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace where namespace.nspname='public' and procedure.prosecdef)<>69 then raise exception 'SAAS-9D-4B-2B postflight failed: SECURITY DEFINER count differs.'; end if;
  if (select pg_catalog.count(*) from information_schema.columns where table_schema='public' and table_name in('shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','email_deliveries') and column_name='tenant_id' and column_default='''c5c00000-0000-4000-8000-000000000001''::uuid')<>7 then raise exception 'SAAS-9D-4B-2B postflight failed: compatibility defaults differ.'; end if;
  if pg_catalog.has_table_privilege('anon','public.tenant_user_verifications','SELECT,INSERT,UPDATE,DELETE') or pg_catalog.has_table_privilege('authenticated','public.tenant_user_verifications','SELECT,INSERT,UPDATE,DELETE') or pg_catalog.has_table_privilege('service_role','public.tenant_user_verifications','SELECT,INSERT,UPDATE,DELETE') then raise exception 'SAAS-9D-4B-2B postflight failed: direct table access widened.'; end if;
  if not pg_catalog.has_function_privilege('authenticated','public.update_reservation_customer_verification_v1(uuid,text,text)','EXECUTE')
     or not pg_catalog.has_function_privilege('authenticated','public.get_my_active_tenant_verification_v1()','EXECUTE')
     or pg_catalog.has_function_privilege('service_role','public.update_profile_verification(uuid,text,text)','EXECUTE') then raise exception 'SAAS-9D-4B-2B postflight failed: RPC ACL differs.'; end if;
  if pg_catalog.strpos((select prosrc from pg_catalog.pg_proc where oid='public.admin_list_users_v1(integer,integer,text,text,text,text)'::regprocedure),'tenant_user_verifications')=0
     or pg_catalog.strpos((select prosrc from pg_catalog.pg_proc where oid='public.get_reservation_customer_profiles_v1(uuid[])'::regprocedure),'tenant_user_verifications')=0
     or pg_catalog.strpos((select prosrc from pg_catalog.pg_proc where oid='public.get_reservation_customer_profiles_v1(uuid[])'::regprocedure),'profile.verification_status')>0 then raise exception 'SAAS-9D-4B-2B postflight failed: reader cutover differs.'; end if;
end;
$postflight$;

commit;
