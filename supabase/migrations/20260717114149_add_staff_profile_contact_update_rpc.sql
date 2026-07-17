create or replace function public.prevent_non_admin_profile_privilege_changes()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  actor_role text;
begin
  if auth.uid() is null then
    return new;
  end if;

  if coalesce(public.is_admin(), false) then
    return new;
  end if;

  select lower(btrim(profile.role::text))
  into actor_role
  from public.profiles as profile
  where profile.user_id = auth.uid();

  if actor_role = 'pracownik'
    and old.user_id is distinct from auth.uid()
  then
    if coalesce(lower(btrim(old.role::text)), '') = 'admin' then
      raise exception 'Pracownik nie może zmieniać profilu administratora.'
        using errcode = '42501';
    end if;

    if current_setting(
      'csk.profile_contact_rpc_actor',
      true
    ) is not distinct from auth.uid()::text
      and current_setting(
        'csk.profile_contact_rpc_target',
        true
      ) is not distinct from old.user_id::text
    then
      if (to_jsonb(new) - array[
        'phone',
        'postal_code',
        'city',
        'street',
        'house_number',
        'apartment_number',
        'updated_at'
      ]) is distinct from (to_jsonb(old) - array[
        'phone',
        'postal_code',
        'city',
        'street',
        'house_number',
        'apartment_number',
        'updated_at'
      ])
      then
        raise exception 'Pracownik może zmieniać wyłącznie dane kontaktowe klienta.'
          using errcode = '42501';
      end if;

      return new;
    end if;

    if current_setting(
      'csk.profile_verification_rpc_actor',
      true
    ) is distinct from auth.uid()::text
      or current_setting(
        'csk.profile_verification_rpc_target',
        true
      ) is distinct from old.user_id::text
    then
      raise exception 'Pola cudzego profilu można zmieniać wyłącznie przez kontrolowaną operację.'
        using errcode = '42501';
    end if;

    if (to_jsonb(new) - array[
      'verification_status',
      'permissions_verified',
      'permissions_verified_at',
      'permissions_verified_by',
      'permissions_verification_note',
      'verified_at',
      'verified_by',
      'unverified_at',
      'unverified_by',
      'updated_at'
    ]) is distinct from (to_jsonb(old) - array[
      'verification_status',
      'permissions_verified',
      'permissions_verified_at',
      'permissions_verified_by',
      'permissions_verification_note',
      'verified_at',
      'verified_by',
      'unverified_at',
      'unverified_by',
      'updated_at'
    ])
    then
      raise exception 'Pracownik może zmieniać wyłącznie pola weryfikacyjne cudzego profilu.'
        using errcode = '42501';
    end if;

    return new;
  end if;

  if old.id is distinct from new.id
    or old.user_id is distinct from new.user_id
    or old.email is distinct from new.email
    or old.created_at is distinct from new.created_at
    or old.first_name is distinct from new.first_name
    or old.last_name is distinct from new.last_name
  then
    raise exception 'Pola tożsamościowe i techniczne profilu może zmieniać wyłącznie administrator.'
      using errcode = '42501';
  end if;

  if old.role is distinct from new.role
    or old.verification_status is distinct from new.verification_status
    or old.admin_note is distinct from new.admin_note
    or old.permissions_verified is distinct from new.permissions_verified
    or old.permissions_verified_at is distinct from new.permissions_verified_at
    or old.permissions_verified_by is distinct from new.permissions_verified_by
    or old.permissions_verification_note is distinct from new.permissions_verification_note
    or old.verification_note is distinct from new.verification_note
    or old.verified_at is distinct from new.verified_at
    or old.verified_by is distinct from new.verified_by
    or old.unverified_at is distinct from new.unverified_at
    or old.unverified_by is distinct from new.unverified_by
  then
    raise exception 'Pola administracyjne i weryfikacyjne profilu może zmieniać wyłącznie administrator.'
      using errcode = '42501';
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
    or old.qualification_hunter is distinct from new.qualification_hunter
  then
    new.verification_status := 'pending';
    new.permissions_verified := false;
    new.permissions_verified_at := null;
    new.permissions_verified_by := null;
    new.permissions_verification_note := null;
  end if;

  return new;
end;
$$;

create or replace function public.update_profile_contact_details(
  p_target_user_id uuid,
  p_phone text,
  p_postal_code text,
  p_city text,
  p_street text,
  p_house_number text,
  p_apartment_number text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  actor_user_id uuid := auth.uid();
  actor_profile public.profiles%rowtype;
  target_profile public.profiles%rowtype;
  updated_profile public.profiles%rowtype;
  actor_role text;
  target_role text;
  actor_name text;
  target_name text;
  action_time timestamptz := now();
  normalized_phone text := nullif(btrim(p_phone), '');
  normalized_postal_code text := nullif(btrim(p_postal_code), '');
  normalized_city text := nullif(btrim(p_city), '');
  normalized_street text := nullif(btrim(p_street), '');
  normalized_house_number text := nullif(btrim(p_house_number), '');
  normalized_apartment_number text := nullif(btrim(p_apartment_number), '');
  changed_fields text[] := array[]::text[];
begin
  if actor_user_id is null then
    raise exception 'Brak aktywnej sesji użytkownika.'
      using errcode = '42501';
  end if;

  select profile.*
  into actor_profile
  from public.profiles as profile
  where profile.user_id = actor_user_id;

  if not found then
    raise exception 'Nie znaleziono profilu operatora.'
      using errcode = '42501';
  end if;

  actor_role := lower(btrim(actor_profile.role::text));

  if coalesce(actor_role, '') not in ('admin', 'pracownik') then
    raise exception 'Brak uprawnień do aktualizacji danych kontaktowych.'
      using errcode = '42501';
  end if;

  if p_target_user_id is null then
    raise exception 'Identyfikator profilu docelowego jest wymagany.'
      using errcode = '22023';
  end if;

  if length(normalized_phone) > 32 then
    raise exception 'Numer telefonu jest zbyt długi.'
      using errcode = '22023';
  end if;

  if length(normalized_postal_code) > 20 then
    raise exception 'Kod pocztowy jest zbyt długi.'
      using errcode = '22023';
  end if;

  if length(normalized_city) > 120 then
    raise exception 'Nazwa miasta jest zbyt długa.'
      using errcode = '22023';
  end if;

  if length(normalized_street) > 160 then
    raise exception 'Nazwa ulicy jest zbyt długa.'
      using errcode = '22023';
  end if;

  if length(normalized_house_number) > 30 then
    raise exception 'Numer domu jest zbyt długi.'
      using errcode = '22023';
  end if;

  if length(normalized_apartment_number) > 30 then
    raise exception 'Numer mieszkania jest zbyt długi.'
      using errcode = '22023';
  end if;

  select profile.*
  into target_profile
  from public.profiles as profile
  where profile.user_id = p_target_user_id
  for update;

  if not found then
    raise exception 'Nie znaleziono profilu docelowego.'
      using errcode = 'P0002';
  end if;

  target_role := lower(btrim(target_profile.role::text));

  if actor_role = 'pracownik'
    and p_target_user_id = actor_user_id
  then
    raise exception 'Pracownik nie może aktualizować własnego profilu w tym module.'
      using errcode = '42501';
  end if;

  if actor_role = 'pracownik'
    and coalesce(target_role, '') = 'admin'
  then
    raise exception 'Pracownik nie może aktualizować profilu administratora.'
      using errcode = '42501';
  end if;

  if actor_role = 'pracownik'
    and coalesce(target_role, '') <> 'user'
  then
    raise exception 'Pracownik może aktualizować dane kontaktowe wyłącznie klienta.'
      using errcode = '42501';
  end if;

  if target_profile.phone is distinct from normalized_phone then
    changed_fields := array_append(changed_fields, 'phone');
  end if;

  if target_profile.postal_code is distinct from normalized_postal_code then
    changed_fields := array_append(changed_fields, 'postal_code');
  end if;

  if target_profile.city is distinct from normalized_city then
    changed_fields := array_append(changed_fields, 'city');
  end if;

  if target_profile.street is distinct from normalized_street then
    changed_fields := array_append(changed_fields, 'street');
  end if;

  if target_profile.house_number is distinct from normalized_house_number then
    changed_fields := array_append(changed_fields, 'house_number');
  end if;

  if target_profile.apartment_number is distinct from normalized_apartment_number then
    changed_fields := array_append(changed_fields, 'apartment_number');
  end if;

  if cardinality(changed_fields) = 0 then
    return jsonb_build_object(
      'user_id', target_profile.user_id,
      'phone', target_profile.phone,
      'postal_code', target_profile.postal_code,
      'city', target_profile.city,
      'street', target_profile.street,
      'house_number', target_profile.house_number,
      'apartment_number', target_profile.apartment_number,
      'updated_at', target_profile.updated_at,
      'changed_fields', to_jsonb(changed_fields)
    );
  end if;

  if actor_role = 'pracownik' then
    perform pg_catalog.set_config(
      'csk.profile_contact_rpc_actor',
      actor_user_id::text,
      true
    );

    perform pg_catalog.set_config(
      'csk.profile_contact_rpc_target',
      p_target_user_id::text,
      true
    );
  end if;

  update public.profiles as profile
  set
    phone = normalized_phone,
    postal_code = normalized_postal_code,
    city = normalized_city,
    street = normalized_street,
    house_number = normalized_house_number,
    apartment_number = normalized_apartment_number,
    updated_at = action_time
  where profile.user_id = p_target_user_id
  returning profile.* into updated_profile;

  if actor_role = 'pracownik' then
    perform pg_catalog.set_config(
      'csk.profile_contact_rpc_actor',
      '',
      true
    );

    perform pg_catalog.set_config(
      'csk.profile_contact_rpc_target',
      '',
      true
    );
  end if;

  actor_name := coalesce(
    nullif(btrim(concat_ws(' ', actor_profile.first_name, actor_profile.last_name)), ''),
    nullif(btrim(actor_profile.full_name), ''),
    nullif(btrim(actor_profile.email), ''),
    'Nieznany użytkownik'
  );

  target_name := coalesce(
    nullif(btrim(concat_ws(' ', target_profile.first_name, target_profile.last_name)), ''),
    nullif(btrim(target_profile.full_name), ''),
    nullif(btrim(target_profile.email), ''),
    'Nieznany profil'
  );

  insert into public.audit_logs (
    actor_user_id,
    actor_name,
    actor_role,
    action,
    target_type,
    target_id,
    target_name,
    details
  )
  values (
    actor_user_id,
    actor_name,
    actor_role,
    'profile_contact_details_updated',
    'profile',
    target_profile.user_id,
    target_name,
    jsonb_build_object(
      'changed_fields', to_jsonb(changed_fields),
      'changed_field_count', cardinality(changed_fields),
      'operator_role', actor_role
    )
  );

  return jsonb_build_object(
    'user_id', updated_profile.user_id,
    'phone', updated_profile.phone,
    'postal_code', updated_profile.postal_code,
    'city', updated_profile.city,
    'street', updated_profile.street,
    'house_number', updated_profile.house_number,
    'apartment_number', updated_profile.apartment_number,
    'updated_at', updated_profile.updated_at,
    'changed_fields', to_jsonb(changed_fields)
  );
end;
$$;

comment on function public.update_profile_contact_details(
  uuid,
  text,
  text,
  text,
  text,
  text,
  text
) is
  'Kontrolowana, transakcyjna aktualizacja danych kontaktowych klienta przez administratora lub pracownika wraz z wpisem audit log.';

revoke all on function public.update_profile_contact_details(
  uuid,
  text,
  text,
  text,
  text,
  text,
  text
) from public;

revoke all on function public.update_profile_contact_details(
  uuid,
  text,
  text,
  text,
  text,
  text,
  text
) from anon;

grant execute on function public.update_profile_contact_details(
  uuid,
  text,
  text,
  text,
  text,
  text,
  text
) to authenticated;
