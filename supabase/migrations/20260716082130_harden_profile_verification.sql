alter table public.profiles
  add column if not exists first_name text,
  add column if not exists last_name text;

create or replace function public.prevent_non_admin_profile_privilege_changes()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null then
    return new;
  end if;

  if coalesce(public.is_admin(), false) then
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
