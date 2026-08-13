-- 6C-2F-A: admin-only user administration and reservation-scoped profile access.

do $preflight$
declare
  v_missing_columns text;
begin
  if pg_catalog.to_regclass('public.profiles') is null
     or pg_catalog.to_regclass('public.reservations') is null
     or pg_catalog.to_regclass('public.audit_logs') is null then
    raise exception '6C-2F-A preflight failed: required tables are missing.';
  end if;

  select pg_catalog.string_agg(required.column_name, ', ' order by required.column_name)
  into v_missing_columns
  from (values
    ('id'), ('user_id'), ('email'), ('first_name'), ('last_name'), ('full_name'),
    ('phone'), ('role'), ('verification_status'), ('admin_note'), ('created_at'),
    ('updated_at'), ('postal_code'), ('city'), ('street'), ('house_number'),
    ('apartment_number'), ('permission_sport'), ('permission_collector'),
    ('permission_hunting'), ('permission_training'),
    ('permission_personal_protection'), ('permission_other'),
    ('qualification_instructor'), ('qualification_range_officer'),
    ('qualification_pzss_license'), ('qualification_hunter'),
    ('permissions_verified'), ('permissions_verified_at'),
    ('permissions_verified_by'), ('permissions_verification_note'),
    ('weapon_permit_number'), ('weapon_permit_type'), ('weapon_permit_issuer'),
    ('has_range_officer'), ('range_officer_number'), ('has_instructor'),
    ('instructor_number'), ('verification_note'), ('verified_at'), ('verified_by'),
    ('unverified_at'), ('unverified_by')
  ) as required(column_name)
  where not exists (
    select 1
    from pg_catalog.pg_attribute as attribute
    where attribute.attrelid = 'public.profiles'::pg_catalog.regclass
      and attribute.attname = required.column_name
      and attribute.attnum > 0
      and not attribute.attisdropped
  );

  if v_missing_columns is not null then
    raise exception '6C-2F-A preflight failed: profiles columns missing: %.', v_missing_columns;
  end if;

  if pg_catalog.to_regprocedure('public.update_profile_verification(uuid,text,text)') is null
     or pg_catalog.to_regprocedure('public.prevent_non_admin_profile_privilege_changes()') is null
     or pg_catalog.to_regprocedure('public.is_admin()') is null then
    raise exception '6C-2F-A preflight failed: required profile functions are missing.';
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_policy as policy
    where policy.polrelid = 'public.profiles'::pg_catalog.regclass
      and policy.polname = 'Admins and staff can view all profiles'
      and policy.polcmd = 'r'
  ) then
    raise exception '6C-2F-A preflight failed: expected global profile SELECT policy is missing.';
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_policy as policy
    where policy.polrelid = 'public.profiles'::pg_catalog.regclass
      and policy.polname = 'Users can view own profile'
      and policy.polcmd = 'r'
  ) or not exists (
    select 1
    from pg_catalog.pg_policy as policy
    where policy.polrelid = 'public.profiles'::pg_catalog.regclass
      and policy.polname = 'Users can update own basic profile'
      and policy.polcmd = 'w'
  ) then
    raise exception '6C-2F-A preflight failed: canonical own-profile policies are missing.';
  end if;
end;
$preflight$;

create or replace function public.admin_list_users_v1(
  p_limit integer default 50,
  p_offset integer default 0,
  p_search text default null,
  p_role text default null,
  p_verification_filter text default null,
  p_sort text default 'newest'
)
returns table (
  user_id uuid,
  email text,
  first_name text,
  last_name text,
  full_name text,
  phone text,
  role text,
  verification_status text,
  admin_note text,
  created_at timestamptz,
  updated_at timestamptz,
  postal_code text,
  city text,
  street text,
  house_number text,
  apartment_number text,
  permission_sport boolean,
  permission_collector boolean,
  permission_hunting boolean,
  permission_training boolean,
  permission_personal_protection boolean,
  permission_other boolean,
  qualification_instructor boolean,
  qualification_range_officer boolean,
  qualification_pzss_license boolean,
  qualification_hunter boolean,
  permissions_verified boolean,
  permissions_verified_at timestamptz,
  permissions_verification_note text,
  total_count bigint
)
language plpgsql
stable
security definer
set search_path = pg_catalog, public, pg_temp
as $function$
declare
  v_actor_id uuid := auth.uid();
  v_actor_role text;
  v_search text := nullif(pg_catalog.btrim(p_search), '');
  v_role text := nullif(pg_catalog.lower(pg_catalog.btrim(p_role)), '');
  v_verification text := nullif(pg_catalog.lower(pg_catalog.btrim(p_verification_filter)), '');
  v_sort text := pg_catalog.lower(pg_catalog.btrim(coalesce(p_sort, 'newest')));
begin
  select pg_catalog.lower(pg_catalog.btrim(profile.role::text))
  into v_actor_role
  from public.profiles as profile
  where profile.user_id = v_actor_id;

  if v_actor_id is null or coalesce(v_actor_role, '') <> 'admin' then
    raise exception 'Brak uprawnień do listy użytkowników.' using errcode = '42501';
  end if;

  if p_limit is null or p_limit < 1 or p_limit > 100
     or p_offset is null or p_offset < 0 then
    raise exception 'Nieprawidłowe parametry stronicowania.' using errcode = '22023';
  end if;

  if v_role is not null and v_role not in ('admin', 'pracownik', 'instruktor', 'user') then
    raise exception 'Nieprawidłowy filtr roli.' using errcode = '22023';
  end if;

  if v_verification is not null
     and v_verification not in ('pending', 'unverified', 'verified', 'rejected') then
    raise exception 'Nieprawidłowy filtr weryfikacji.' using errcode = '22023';
  end if;

  if v_sort not in ('newest', 'oldest', 'name', 'role') then
    raise exception 'Nieprawidłowy sposób sortowania.' using errcode = '22023';
  end if;

  return query
  with filtered as (
    select profile.*
    from public.profiles as profile
    where (v_role is null or pg_catalog.lower(pg_catalog.btrim(profile.role::text)) = v_role)
      and (
        v_verification is null
        or (v_verification = 'pending' and profile.verification_status = 'pending')
        or (v_verification = 'verified'
            and profile.verification_status = 'verified'
            and profile.permissions_verified)
        or (v_verification = 'rejected' and profile.verification_status = 'rejected')
        or (v_verification = 'unverified'
            and (profile.verification_status is distinct from 'verified'
                 or not profile.permissions_verified))
      )
      and (
        v_search is null
        or coalesce(profile.first_name, '') ilike '%' || v_search || '%'
        or coalesce(profile.last_name, '') ilike '%' || v_search || '%'
        or coalesce(profile.full_name, '') ilike '%' || v_search || '%'
        or coalesce(profile.email, '') ilike '%' || v_search || '%'
        or coalesce(profile.phone, '') ilike '%' || v_search || '%'
      )
  )
  select
    profile.user_id, profile.email, profile.first_name,
    profile.last_name, profile.full_name, profile.phone, profile.role,
    profile.verification_status, profile.admin_note, profile.created_at,
    profile.updated_at, profile.postal_code, profile.city, profile.street,
    profile.house_number, profile.apartment_number, profile.permission_sport,
    profile.permission_collector, profile.permission_hunting,
    profile.permission_training, profile.permission_personal_protection,
    profile.permission_other, profile.qualification_instructor,
    profile.qualification_range_officer, profile.qualification_pzss_license,
    profile.qualification_hunter, profile.permissions_verified,
    profile.permissions_verified_at, profile.permissions_verification_note,
    pg_catalog.count(*) over () as total_count
  from filtered as profile
  order by
    case when v_sort = 'newest' then profile.created_at end desc nulls last,
    case when v_sort = 'oldest' then profile.created_at end asc nulls last,
    case when v_sort = 'name' then pg_catalog.lower(coalesce(
      nullif(pg_catalog.btrim(profile.full_name), ''),
      nullif(pg_catalog.btrim(profile.first_name || ' ' || profile.last_name), ''),
      profile.email,
      ''
    )) end asc,
    case when v_sort = 'role' then pg_catalog.lower(profile.role::text) end asc,
    profile.user_id asc
  limit p_limit
  offset p_offset;
end;
$function$;

create or replace function public.get_reservation_customer_profiles_v1(
  p_reservation_ids uuid[]
)
returns table (
  reservation_id uuid,
  user_id uuid,
  email text,
  full_name text,
  phone text,
  role text,
  verification_status text,
  postal_code text,
  city text,
  street text,
  house_number text,
  apartment_number text,
  permission_sport boolean,
  permission_collector boolean,
  permission_hunting boolean,
  permission_training boolean,
  permission_personal_protection boolean,
  permission_other boolean,
  qualification_instructor boolean,
  qualification_range_officer boolean,
  qualification_pzss_license boolean,
  qualification_hunter boolean,
  permissions_verified boolean,
  permissions_verified_at timestamptz,
  permissions_verification_note text,
  updated_at timestamptz
)
language plpgsql
stable
security definer
set search_path = pg_catalog, public, pg_temp
as $function$
declare
  v_actor_id uuid := auth.uid();
  v_actor_role text;
  v_requested_count integer;
  v_distinct_count integer;
begin
  select pg_catalog.lower(pg_catalog.btrim(profile.role::text))
  into v_actor_role
  from public.profiles as profile
  where profile.user_id = v_actor_id;

  if v_actor_id is null or coalesce(v_actor_role, '') not in ('admin', 'pracownik') then
    raise exception 'Brak uprawnień do danych operacyjnych profilu.' using errcode = '42501';
  end if;

  v_requested_count := coalesce(pg_catalog.cardinality(p_reservation_ids), 0);
  if v_requested_count < 1 or v_requested_count > 200
     or pg_catalog.array_position(p_reservation_ids, null) is not null then
    raise exception 'Nieprawidłowy zakres rezerwacji.' using errcode = '22023';
  end if;

  select pg_catalog.count(distinct requested.id)::integer
  into v_distinct_count
  from pg_catalog.unnest(p_reservation_ids) as requested(id);

  if v_distinct_count <> v_requested_count then
    raise exception 'Identyfikatory rezerwacji nie mogą się powtarzać.' using errcode = '22023';
  end if;

  return query
  select
    reservation.id, profile.user_id, profile.email, profile.full_name,
    profile.phone, profile.role, profile.verification_status,
    profile.postal_code, profile.city, profile.street, profile.house_number,
    profile.apartment_number, profile.permission_sport,
    profile.permission_collector, profile.permission_hunting,
    profile.permission_training, profile.permission_personal_protection,
    profile.permission_other, profile.qualification_instructor,
    profile.qualification_range_officer, profile.qualification_pzss_license,
    profile.qualification_hunter, profile.permissions_verified,
    profile.permissions_verified_at, profile.permissions_verification_note,
    profile.updated_at
  from public.reservations as reservation
  join public.profiles as profile on profile.user_id = reservation.user_id
  where reservation.id = any(p_reservation_ids)
  order by reservation.id;
end;
$function$;

create or replace function public.admin_set_user_role_v1(
  p_target_user_id uuid,
  p_new_role text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, public, pg_temp
as $function$
declare
  v_actor_id uuid := auth.uid();
  v_actor public.profiles%rowtype;
  v_target public.profiles%rowtype;
  v_new_role text := pg_catalog.lower(pg_catalog.btrim(p_new_role));
  v_current_role text;
  v_admin_count bigint;
  v_changed_at timestamptz := pg_catalog.transaction_timestamp();
begin
  if v_actor_id is null then
    return pg_catalog.jsonb_build_object('ok', false, 'changed', false, 'code', 'not_allowed');
  end if;

  perform pg_catalog.pg_advisory_xact_lock(6202, 1);

  select profile.* into v_actor
  from public.profiles as profile
  where profile.user_id = v_actor_id;

  if not found or pg_catalog.lower(pg_catalog.btrim(v_actor.role::text)) <> 'admin' then
    return pg_catalog.jsonb_build_object('ok', false, 'changed', false, 'code', 'not_allowed');
  end if;

  if p_target_user_id is null then
    return pg_catalog.jsonb_build_object('ok', false, 'changed', false, 'code', 'invalid_target');
  end if;

  if v_new_role is null or v_new_role not in ('user', 'instruktor', 'pracownik', 'admin') then
    return pg_catalog.jsonb_build_object('ok', false, 'changed', false, 'code', 'invalid_role');
  end if;

  select profile.* into v_target
  from public.profiles as profile
  where profile.user_id = p_target_user_id
  for update;

  if not found then
    return pg_catalog.jsonb_build_object('ok', false, 'changed', false, 'code', 'target_not_found');
  end if;

  v_current_role := pg_catalog.lower(pg_catalog.btrim(v_target.role::text));
  if v_current_role not in ('user', 'instruktor', 'pracownik', 'admin') then
    return pg_catalog.jsonb_build_object('ok', false, 'changed', false, 'code', 'invalid_current_role');
  end if;

  if v_current_role = v_new_role then
    return pg_catalog.jsonb_build_object(
      'ok', true, 'changed', false, 'code', 'no_change',
      'target_user_id', p_target_user_id, 'role', v_current_role
    );
  end if;

  if v_current_role = 'admin' and v_new_role <> 'admin' then
    select pg_catalog.count(*) into v_admin_count
    from public.profiles as profile
    where pg_catalog.lower(pg_catalog.btrim(profile.role::text)) = 'admin';

    if v_admin_count <= 1 then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'last_admin',
        'target_user_id', p_target_user_id, 'role', v_current_role
      );
    end if;
  end if;

  perform pg_catalog.set_config('csk.profile_role_rpc_actor', v_actor_id::text, true);
  perform pg_catalog.set_config('csk.profile_role_rpc_target', p_target_user_id::text, true);

  update public.profiles as profile
  set role = v_new_role, updated_at = v_changed_at
  where profile.user_id = p_target_user_id;

  insert into public.audit_logs (
    actor_user_id, actor_name, actor_role, action,
    target_type, target_id, target_name, details
  ) values (
    v_actor_id,
    coalesce(
      nullif(pg_catalog.btrim(pg_catalog.concat_ws(' ', v_actor.first_name, v_actor.last_name)), ''),
      nullif(pg_catalog.btrim(v_actor.full_name), ''),
      'Administrator'
    ),
    'admin', 'profile_role_changed', 'profile', p_target_user_id,
    coalesce(
      nullif(pg_catalog.btrim(pg_catalog.concat_ws(' ', v_target.first_name, v_target.last_name)), ''),
      nullif(pg_catalog.btrim(v_target.full_name), ''),
      'Profil użytkownika'
    ),
    pg_catalog.jsonb_build_object(
      'previous_role', v_current_role,
      'new_role', v_new_role,
      'operator_role', 'admin'
    )
  );

  perform pg_catalog.set_config('csk.profile_role_rpc_actor', '', true);
  perform pg_catalog.set_config('csk.profile_role_rpc_target', '', true);

  return pg_catalog.jsonb_build_object(
    'ok', true, 'changed', true, 'code', 'updated',
    'target_user_id', p_target_user_id, 'previous_role', v_current_role,
    'role', v_new_role, 'updated_at', v_changed_at
  );
end;
$function$;

create or replace function public.admin_set_user_note_v1(
  p_target_user_id uuid,
  p_admin_note text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, public, pg_temp
as $function$
declare
  v_actor_id uuid := auth.uid();
  v_actor public.profiles%rowtype;
  v_target public.profiles%rowtype;
  v_note text := nullif(pg_catalog.btrim(p_admin_note), '');
  v_changed_at timestamptz := pg_catalog.transaction_timestamp();
begin
  if v_actor_id is null then
    return pg_catalog.jsonb_build_object('ok', false, 'changed', false, 'code', 'not_allowed');
  end if;

  perform pg_catalog.pg_advisory_xact_lock(6202, 1);

  select profile.* into v_actor
  from public.profiles as profile
  where profile.user_id = v_actor_id;

  if not found or pg_catalog.lower(pg_catalog.btrim(v_actor.role::text)) <> 'admin' then
    return pg_catalog.jsonb_build_object('ok', false, 'changed', false, 'code', 'not_allowed');
  end if;

  if p_target_user_id is null then
    return pg_catalog.jsonb_build_object('ok', false, 'changed', false, 'code', 'invalid_target');
  end if;

  if pg_catalog.length(coalesce(v_note, '')) > 2000 then
    return pg_catalog.jsonb_build_object('ok', false, 'changed', false, 'code', 'note_too_long');
  end if;

  select profile.* into v_target
  from public.profiles as profile
  where profile.user_id = p_target_user_id
  for update;

  if not found then
    return pg_catalog.jsonb_build_object('ok', false, 'changed', false, 'code', 'target_not_found');
  end if;

  if v_target.admin_note is not distinct from v_note then
    return pg_catalog.jsonb_build_object(
      'ok', true, 'changed', false, 'code', 'no_change',
      'target_user_id', p_target_user_id
    );
  end if;

  perform pg_catalog.set_config('csk.profile_note_rpc_actor', v_actor_id::text, true);
  perform pg_catalog.set_config('csk.profile_note_rpc_target', p_target_user_id::text, true);

  update public.profiles as profile
  set admin_note = v_note, updated_at = v_changed_at
  where profile.user_id = p_target_user_id;

  insert into public.audit_logs (
    actor_user_id, actor_name, actor_role, action,
    target_type, target_id, target_name, details
  ) values (
    v_actor_id,
    coalesce(
      nullif(pg_catalog.btrim(pg_catalog.concat_ws(' ', v_actor.first_name, v_actor.last_name)), ''),
      nullif(pg_catalog.btrim(v_actor.full_name), ''),
      'Administrator'
    ),
    'admin', 'profile_admin_note_updated', 'profile', p_target_user_id,
    coalesce(
      nullif(pg_catalog.btrim(pg_catalog.concat_ws(' ', v_target.first_name, v_target.last_name)), ''),
      nullif(pg_catalog.btrim(v_target.full_name), ''),
      'Profil użytkownika'
    ),
    pg_catalog.jsonb_build_object(
      'previous_note_present', v_target.admin_note is not null,
      'new_note_present', v_note is not null,
      'operator_role', 'admin'
    )
  );

  perform pg_catalog.set_config('csk.profile_note_rpc_actor', '', true);
  perform pg_catalog.set_config('csk.profile_note_rpc_target', '', true);

  return pg_catalog.jsonb_build_object(
    'ok', true, 'changed', true, 'code', 'updated',
    'target_user_id', p_target_user_id, 'admin_note', v_note,
    'updated_at', v_changed_at
  );
end;
$function$;

create or replace function public.prevent_non_admin_profile_privilege_changes()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $function$
declare
  actor_role text;
  identity_changed boolean;
  role_changed boolean := old.role is distinct from new.role;
  note_changed boolean := old.admin_note is distinct from new.admin_note;
begin
  if auth.uid() is null then
    return new;
  end if;

  if role_changed then
    if not coalesce(public.is_admin(), false)
       or pg_catalog.current_setting('csk.profile_role_rpc_actor', true) is distinct from auth.uid()::text
       or pg_catalog.current_setting('csk.profile_role_rpc_target', true) is distinct from old.user_id::text then
      raise exception 'Rolę można zmieniać wyłącznie przez kontrolowaną operację administratora.'
        using errcode = '42501';
    end if;

    if (pg_catalog.to_jsonb(new) - array['role', 'updated_at'])
       is distinct from (pg_catalog.to_jsonb(old) - array['role', 'updated_at']) then
      raise exception 'Kontrolowana zmiana roli może zmieniać wyłącznie rolę i czas aktualizacji.'
        using errcode = '42501';
    end if;
    return new;
  end if;

  if note_changed then
    if not coalesce(public.is_admin(), false)
       or pg_catalog.current_setting('csk.profile_note_rpc_actor', true) is distinct from auth.uid()::text
       or pg_catalog.current_setting('csk.profile_note_rpc_target', true) is distinct from old.user_id::text then
      raise exception 'Notatkę administracyjną można zmieniać wyłącznie przez kontrolowaną operację administratora.'
        using errcode = '42501';
    end if;

    if (pg_catalog.to_jsonb(new) - array['admin_note', 'updated_at'])
       is distinct from (pg_catalog.to_jsonb(old) - array['admin_note', 'updated_at']) then
      raise exception 'Kontrolowana zmiana notatki może zmieniać wyłącznie notatkę i czas aktualizacji.'
        using errcode = '42501';
    end if;
    return new;
  end if;

  identity_changed := old.first_name is distinct from new.first_name
    or old.last_name is distinct from new.last_name
    or old.full_name is distinct from new.full_name;

  if identity_changed then
    if not coalesce(public.is_admin(), false) then
      raise exception 'Dane imienia i nazwiska może zmieniać wyłącznie administrator przez kontrolowaną operację.'
        using errcode = '42501';
    end if;
    if pg_catalog.current_setting('csk.profile_identity_rpc_actor', true) is distinct from auth.uid()::text
       or pg_catalog.current_setting('csk.profile_identity_rpc_target', true) is distinct from old.user_id::text then
      raise exception 'Dane imienia i nazwiska można zmieniać wyłącznie przez kontrolowaną operację korekty tożsamości.'
        using errcode = '42501';
    end if;
    if (pg_catalog.to_jsonb(new) - array['first_name','last_name','full_name','updated_at'])
       is distinct from (pg_catalog.to_jsonb(old) - array['first_name','last_name','full_name','updated_at']) then
      raise exception 'Kontrolowana korekta tożsamości może zmieniać wyłącznie imię, nazwisko, pełną nazwę i czas aktualizacji.'
        using errcode = '42501';
    end if;
    return new;
  end if;

  if coalesce(public.is_admin(), false) then
    return new;
  end if;

  select pg_catalog.lower(pg_catalog.btrim(profile.role::text)) into actor_role
  from public.profiles as profile where profile.user_id = auth.uid();

  if actor_role = 'pracownik' and old.user_id is distinct from auth.uid() then
    if coalesce(pg_catalog.lower(pg_catalog.btrim(old.role::text)), '') = 'admin' then
      raise exception 'Pracownik nie może zmieniać profilu administratora.' using errcode = '42501';
    end if;
    if pg_catalog.current_setting('csk.profile_contact_rpc_actor', true) is not distinct from auth.uid()::text
       and pg_catalog.current_setting('csk.profile_contact_rpc_target', true) is not distinct from old.user_id::text then
      if (pg_catalog.to_jsonb(new) - array['phone','postal_code','city','street','house_number','apartment_number','updated_at'])
         is distinct from (pg_catalog.to_jsonb(old) - array['phone','postal_code','city','street','house_number','apartment_number','updated_at']) then
        raise exception 'Pracownik może zmieniać wyłącznie dane kontaktowe klienta.' using errcode = '42501';
      end if;
      return new;
    end if;
    if pg_catalog.current_setting('csk.profile_verification_rpc_actor', true) is distinct from auth.uid()::text
       or pg_catalog.current_setting('csk.profile_verification_rpc_target', true) is distinct from old.user_id::text then
      raise exception 'Pola cudzego profilu można zmieniać wyłącznie przez kontrolowaną operację.' using errcode = '42501';
    end if;
    if (pg_catalog.to_jsonb(new) - array[
      'verification_status','permissions_verified','permissions_verified_at',
      'permissions_verified_by','permissions_verification_note','verified_at',
      'verified_by','unverified_at','unverified_by','updated_at'
    ]) is distinct from (pg_catalog.to_jsonb(old) - array[
      'verification_status','permissions_verified','permissions_verified_at',
      'permissions_verified_by','permissions_verification_note','verified_at',
      'verified_by','unverified_at','unverified_by','updated_at'
    ]) then
      raise exception 'Pracownik może zmieniać wyłącznie pola weryfikacyjne cudzego profilu.' using errcode = '42501';
    end if;
    return new;
  end if;

  if old.id is distinct from new.id
     or old.user_id is distinct from new.user_id
     or old.email is distinct from new.email
     or old.created_at is distinct from new.created_at
     or old.first_name is distinct from new.first_name
     or old.last_name is distinct from new.last_name
     or old.weapon_permit_number is distinct from new.weapon_permit_number
     or old.weapon_permit_type is distinct from new.weapon_permit_type
     or old.weapon_permit_issuer is distinct from new.weapon_permit_issuer
     or old.has_range_officer is distinct from new.has_range_officer
     or old.range_officer_number is distinct from new.range_officer_number
     or old.has_instructor is distinct from new.has_instructor
     or old.instructor_number is distinct from new.instructor_number then
    raise exception 'Pola tożsamościowe, techniczne i legacy profilu nie są dostępne w samoobsłudze.' using errcode = '42501';
  end if;

  if old.verification_status is distinct from new.verification_status
     or old.verification_note is distinct from new.verification_note
     or old.verified_at is distinct from new.verified_at
     or old.verified_by is distinct from new.verified_by
     or old.unverified_at is distinct from new.unverified_at
     or old.unverified_by is distinct from new.unverified_by
     or old.permissions_verified is distinct from new.permissions_verified
     or old.permissions_verified_at is distinct from new.permissions_verified_at
     or old.permissions_verified_by is distinct from new.permissions_verified_by
     or old.permissions_verification_note is distinct from new.permissions_verification_note then
    raise exception 'Pola administracyjne i weryfikacyjne profilu nie są dostępne w samoobsłudze.' using errcode = '42501';
  end if;

  if old.permission_sport is distinct from new.permission_sport
     or old.permission_collector is distinct from new.permission_collector
     or old.permission_hunting is distinct from new.permission_hunting
     or old.permission_training is distinct from new.permission_training
     or old.permission_personal_protection is distinct from new.permission_personal_protection
     or old.permission_other is distinct from new.permission_other
     or old.qualification_instructor is distinct from new.qualification_instructor
     or old.qualification_range_officer is distinct from new.qualification_range_officer
     or old.qualification_pzss_license is distinct from new.qualification_pzss_license
     or old.qualification_hunter is distinct from new.qualification_hunter then
    new.verification_status := 'pending';
    new.permissions_verified := false;
    new.permissions_verified_at := null;
    new.permissions_verified_by := null;
    new.permissions_verification_note := null;
  end if;

  return new;
end;
$function$;

drop policy "Admins and staff can view all profiles" on public.profiles;
create policy "Admins can view all profiles"
on public.profiles for select to authenticated
using (public.is_admin());

drop policy if exists "profile_select_own" on public.profiles;
drop policy if exists "profile_update_own" on public.profiles;
drop policy if exists "profile_insert_own" on public.profiles;

alter function public.admin_list_users_v1(integer,integer,text,text,text,text) owner to postgres;
alter function public.get_reservation_customer_profiles_v1(uuid[]) owner to postgres;
alter function public.admin_set_user_role_v1(uuid,text) owner to postgres;
alter function public.admin_set_user_note_v1(uuid,text) owner to postgres;

revoke all on function public.admin_list_users_v1(integer,integer,text,text,text,text) from public, anon, authenticated, service_role;
revoke all on function public.get_reservation_customer_profiles_v1(uuid[]) from public, anon, authenticated, service_role;
revoke all on function public.admin_set_user_role_v1(uuid,text) from public, anon, authenticated, service_role;
revoke all on function public.admin_set_user_note_v1(uuid,text) from public, anon, authenticated, service_role;

grant execute on function public.admin_list_users_v1(integer,integer,text,text,text,text) to authenticated;
grant execute on function public.get_reservation_customer_profiles_v1(uuid[]) to authenticated;
grant execute on function public.admin_set_user_role_v1(uuid,text) to authenticated;
grant execute on function public.admin_set_user_note_v1(uuid,text) to authenticated;

do $postflight$
declare
  v_function_count integer;
begin
  select pg_catalog.count(*) into v_function_count
  from pg_catalog.pg_proc as procedure
  join pg_catalog.pg_namespace as namespace on namespace.oid = procedure.pronamespace
  where namespace.nspname = 'public'
    and procedure.oid in (
      'public.admin_list_users_v1(integer,integer,text,text,text,text)'::pg_catalog.regprocedure,
      'public.get_reservation_customer_profiles_v1(uuid[])'::pg_catalog.regprocedure,
      'public.admin_set_user_role_v1(uuid,text)'::pg_catalog.regprocedure,
      'public.admin_set_user_note_v1(uuid,text)'::pg_catalog.regprocedure
    )
    and procedure.prosecdef
    and procedure.proowner = 'postgres'::pg_catalog.regrole
    and procedure.proconfig = array['search_path=pg_catalog, public, pg_temp'];

  if v_function_count <> 4 then
    raise exception '6C-2F-A postflight failed: RPC security properties differ.';
  end if;

  if exists (
    select 1 from pg_catalog.pg_policy as policy
    where policy.polrelid = 'public.profiles'::pg_catalog.regclass
      and policy.polname in ('Admins and staff can view all profiles','profile_select_own','profile_update_own','profile_insert_own')
  ) or not exists (
    select 1 from pg_catalog.pg_policy as policy
    where policy.polrelid = 'public.profiles'::pg_catalog.regclass
      and policy.polname = 'Admins can view all profiles'
      and policy.polcmd = 'r'
  ) then
    raise exception '6C-2F-A postflight failed: profiles policies differ.';
  end if;
end;
$postflight$;
