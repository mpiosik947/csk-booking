create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  profile_first_name text;
  profile_last_name text;
  profile_full_name text;
  profile_phone text;
begin
  profile_first_name := nullif(btrim(new.raw_user_meta_data->>'first_name'), '');
  profile_last_name := nullif(btrim(new.raw_user_meta_data->>'last_name'), '');
  profile_full_name := coalesce(
    nullif(btrim(new.raw_user_meta_data->>'full_name'), ''),
    nullif(btrim(concat_ws(' ', profile_first_name, profile_last_name)), ''),
    ''
  );
  profile_phone := coalesce(new.raw_user_meta_data->>'phone', '');

  insert into public.profiles as existing (
    id,
    user_id,
    email,
    full_name,
    first_name,
    last_name,
    phone,
    role,
    verification_status,
    created_at,
    updated_at
  )
  values (
    new.id,
    new.id,
    new.email,
    profile_full_name,
    profile_first_name,
    profile_last_name,
    profile_phone,
    'user',
    'pending',
    now(),
    now()
  )
  on conflict (user_id) do update
  set
    email = excluded.email,
    full_name = case
      when nullif(btrim(existing.full_name), '') is null then excluded.full_name
      else existing.full_name
    end,
    first_name = case
      when nullif(btrim(existing.first_name), '') is null then excluded.first_name
      else existing.first_name
    end,
    last_name = case
      when nullif(btrim(existing.last_name), '') is null then excluded.last_name
      else existing.last_name
    end,
    phone = case
      when nullif(btrim(existing.phone), '') is null then excluded.phone
      else existing.phone
    end,
    updated_at = now();

  return new;
end;
$$;
