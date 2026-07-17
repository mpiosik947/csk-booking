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
      'csk.profile_verification_rpc_actor',
      true
    ) is distinct from auth.uid()::text
      or current_setting(
        'csk.profile_verification_rpc_target',
        true
      ) is distinct from old.user_id::text
    then
      raise exception 'Pola weryfikacyjne profilu można zmieniać wyłącznie przez kontrolowaną operację weryfikacji.'
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

create or replace function public.update_profile_verification(
  p_target_user_id uuid,
  p_action text,
  p_note text default null
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
  normalized_action text := lower(btrim(p_action));
  normalized_note text := nullif(btrim(p_note), '');
  actor_role text;
  audit_action text;
  actor_name text;
  target_name text;
  action_time timestamptz := now();
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
    raise exception 'Brak uprawnień do weryfikacji profili.'
      using errcode = '42501';
  end if;

  if length(normalized_note) > 2000 then
    raise exception 'Notatka weryfikacyjna jest zbyt długa.'
      using errcode = '22023';
  end if;

  if p_target_user_id is null then
    raise exception 'Identyfikator profilu docelowego jest wymagany.'
      using errcode = '22023';
  end if;

  if normalized_action is null
    or normalized_action not in ('verify', 'mark_pending', 'reject')
  then
    raise exception 'Nieprawidłowe działanie weryfikacyjne.'
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

  if actor_role = 'pracownik'
    and p_target_user_id = actor_user_id
  then
    raise exception 'Pracownik nie może weryfikować własnego konta.'
      using errcode = '42501';
  end if;

  if actor_role = 'pracownik'
    and lower(btrim(target_profile.role::text)) = 'admin'
  then
    raise exception 'Pracownik nie może zmieniać weryfikacji administratora.'
      using errcode = '42501';
  end if;

  if actor_role = 'pracownik' then
    perform pg_catalog.set_config(
      'csk.profile_verification_rpc_actor',
      actor_user_id::text,
      true
    );

    perform pg_catalog.set_config(
      'csk.profile_verification_rpc_target',
      p_target_user_id::text,
      true
    );
  end if;

  update public.profiles as profile
  set
    verification_status = case normalized_action
      when 'verify' then 'verified'
      when 'mark_pending' then 'pending'
      when 'reject' then 'rejected'
    end,
    permissions_verified = normalized_action = 'verify',
    permissions_verified_at = case
      when normalized_action = 'verify' then action_time
      else null
    end,
    permissions_verified_by = case
      when normalized_action = 'verify' then actor_profile.id
      else null
    end,
    permissions_verification_note = case normalized_action
      when 'verify' then coalesce(
        normalized_note,
        'Sprawdzono uprawnienia klienta podczas pierwszej wizyty. Dokumenty okazane do wglądu, bez kopiowania i zapisywania numerów. Klient zapoznany z regulaminem i zasadami bezpieczeństwa. Konto zweryfikowane.'
      )
      when 'mark_pending' then coalesce(
        normalized_note,
        'Nie zakończono pełnej weryfikacji uprawnień. Klient poinformowany o konieczności okazania wymaganych dokumentów przy kolejnej wizycie. Konto pozostaje niezweryfikowane.'
      )
      when 'reject' then coalesce(
        normalized_note,
        'Weryfikacja konta została odrzucona. Wymagane dane lub dokumenty nie zostały potwierdzone.'
      )
    end,
    verified_at = case
      when normalized_action = 'verify' then action_time
      else null
    end,
    verified_by = case
      when normalized_action = 'verify' then actor_profile.id
      else null
    end,
    unverified_at = case
      when normalized_action = 'verify' then null
      else action_time
    end,
    unverified_by = case
      when normalized_action = 'verify' then null
      else actor_profile.id::text
    end,
    updated_at = action_time
  where profile.user_id = p_target_user_id
  returning profile.* into updated_profile;

  if actor_role = 'pracownik' then
    perform pg_catalog.set_config(
      'csk.profile_verification_rpc_actor',
      '',
      true
    );

    perform pg_catalog.set_config(
      'csk.profile_verification_rpc_target',
      '',
      true
    );
  end if;

  audit_action := case normalized_action
    when 'verify' then 'profile_verification_verified'
    when 'mark_pending' then 'profile_verification_marked_pending'
    when 'reject' then 'profile_verification_rejected'
  end;

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
    audit_action,
    'profile',
    target_profile.user_id,
    target_name,
    jsonb_build_object(
      'previous_verification_status', target_profile.verification_status,
      'new_verification_status', updated_profile.verification_status,
      'previous_permissions_verified', target_profile.permissions_verified,
      'new_permissions_verified', updated_profile.permissions_verified,
      'note_changed', target_profile.permissions_verification_note
        is distinct from updated_profile.permissions_verification_note,
      'operator_role', actor_role
    )
  );

  return jsonb_build_object(
    'user_id', updated_profile.user_id,
    'verification_status', updated_profile.verification_status,
    'permissions_verified', updated_profile.permissions_verified,
    'permissions_verified_at', updated_profile.permissions_verified_at,
    'permissions_verified_by', updated_profile.permissions_verified_by,
    'permissions_verification_note', updated_profile.permissions_verification_note,
    'verified_at', updated_profile.verified_at,
    'verified_by', updated_profile.verified_by,
    'unverified_at', updated_profile.unverified_at,
    'unverified_by', updated_profile.unverified_by,
    'updated_at', updated_profile.updated_at
  );
end;
$$;

comment on function public.update_profile_verification(uuid, text, text) is
  'Kontrolowana, transakcyjna weryfikacja profilu przez administratora lub pracownika wraz z wpisem audit log.';

revoke all on function public.update_profile_verification(uuid, text, text) from public;
revoke all on function public.update_profile_verification(uuid, text, text) from anon;
grant execute on function public.update_profile_verification(uuid, text, text) to authenticated;
