create or replace function public.register_for_event(
  p_event_id uuid,
  p_as_reserve boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path to public, pg_temp
as $function$
declare
  v_user_id uuid := auth.uid();
  v_profile public.profiles%rowtype;
  v_profile_found boolean;
  v_auth_email text;
  v_customer_name text;
  v_customer_email text;
  v_customer_phone text;
  v_event public.events%rowtype;
  v_event_start timestamptz;
  v_now timestamptz := pg_catalog.transaction_timestamp();
  v_existing_registration public.event_registrations%rowtype;
  v_participants_count integer;
  v_has_reserve boolean;
  v_registration_status text;
  v_inserted_registration public.event_registrations%rowtype;
  v_constraint_name text;
begin
  if p_event_id is null then
    raise exception using
      errcode = '22023',
      message = 'Identyfikator szkolenia jest wymagany.';
  end if;

  if v_user_id is null then
    raise exception using
      errcode = '42501',
      message = 'Uwierzytelniona sesja jest wymagana.';
  end if;

  select profile.*
  into v_profile
  from public.profiles as profile
  where profile.user_id = v_user_id;

  v_profile_found := found;

  if v_profile_found then
    select nullif(pg_catalog.btrim(auth_user.email), '')
    into v_auth_email
    from auth.users as auth_user
    where auth_user.id = v_user_id;

    v_customer_email := coalesce(
      nullif(pg_catalog.btrim(v_profile.email), ''),
      v_auth_email
    );

    v_customer_name := coalesce(
      nullif(
        pg_catalog.btrim(
          pg_catalog.concat_ws(
            ' ',
            nullif(pg_catalog.btrim(v_profile.first_name), ''),
            nullif(pg_catalog.btrim(v_profile.last_name), '')
          )
        ),
        ''
      ),
      nullif(pg_catalog.btrim(v_profile.full_name), ''),
      v_customer_email
    );

    v_customer_phone := nullif(pg_catalog.btrim(v_profile.phone), '');
  end if;

  if not v_profile_found
     or v_customer_name is null
     or v_customer_email is null
     or v_customer_phone is null then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'changed', false,
      'code', 'profile_incomplete'
    );
  end if;

  select event_record.*
  into v_event
  from public.events as event_record
  where event_record.id = p_event_id
  for update;

  if not found then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'changed', false,
      'code', 'event_not_found'
    );
  end if;

  if not v_event.is_active then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'changed', false,
      'code', 'event_inactive'
    );
  end if;

  v_event_start :=
    (v_event.event_date + v_event.start_time) at time zone 'Europe/Warsaw';

  if v_now >= v_event_start then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'changed', false,
      'code', 'event_ended'
    );
  end if;

  select registration.*
  into v_existing_registration
  from public.event_registrations as registration
  where registration.event_id = p_event_id
    and registration.user_id = v_user_id
    and pg_catalog.lower(pg_catalog.btrim(registration.registration_status)) in (
      'registered',
      'approved',
      'reserve',
      'participant'
    )
  order by registration.created_at, registration.id
  limit 1
  for update;

  if found then
    return pg_catalog.jsonb_build_object(
      'ok', true,
      'changed', false,
      'code', case
        when pg_catalog.lower(pg_catalog.btrim(v_existing_registration.registration_status))
          in ('registered', 'approved')
          then 'already_registered'
        when pg_catalog.lower(pg_catalog.btrim(v_existing_registration.registration_status)) = 'reserve'
          then 'already_reserve'
        else 'already_active'
      end,
      'registration_id', v_existing_registration.id,
      'registration_status',
        pg_catalog.lower(pg_catalog.btrim(v_existing_registration.registration_status))
    );
  end if;

  select count(*)
  into v_participants_count
  from public.event_registrations as registration
  where registration.event_id = p_event_id
    and pg_catalog.lower(pg_catalog.btrim(registration.registration_status)) in (
      'registered',
      'approved'
    );

  select exists (
    select 1
    from public.event_registrations as registration
    where registration.event_id = p_event_id
      and pg_catalog.lower(pg_catalog.btrim(registration.registration_status)) = 'reserve'
  )
  into v_has_reserve;

  v_registration_status := case
    when coalesce(p_as_reserve, false)
      or v_event.max_participants <= 0
      or v_participants_count >= v_event.max_participants
      or v_has_reserve
      then 'reserve'
    else 'registered'
  end;

  begin
    insert into public.event_registrations (
      event_id,
      user_id,
      customer_name,
      customer_email,
      customer_phone,
      registration_status
    )
    values (
      p_event_id,
      v_user_id,
      v_customer_name,
      v_customer_email,
      v_customer_phone,
      v_registration_status
    )
    returning * into v_inserted_registration;
  exception
    when unique_violation then
      get stacked diagnostics v_constraint_name = constraint_name;

      if v_constraint_name <> 'event_registrations_one_active_per_user_event_idx' then
        raise;
      end if;

      select registration.*
      into v_existing_registration
      from public.event_registrations as registration
      where registration.event_id = p_event_id
        and registration.user_id = v_user_id
        and pg_catalog.lower(pg_catalog.btrim(registration.registration_status)) in (
          'registered',
          'approved',
          'reserve',
          'participant'
        )
      order by registration.created_at, registration.id
      limit 1
      for update;

      if not found then
        return pg_catalog.jsonb_build_object(
          'ok', false,
          'changed', false,
          'code', 'conflict'
        );
      end if;

      return pg_catalog.jsonb_build_object(
        'ok', true,
        'changed', false,
        'code', case
          when pg_catalog.lower(pg_catalog.btrim(v_existing_registration.registration_status))
            in ('registered', 'approved')
            then 'already_registered'
          when pg_catalog.lower(pg_catalog.btrim(v_existing_registration.registration_status)) = 'reserve'
            then 'already_reserve'
          else 'already_active'
        end,
        'registration_id', v_existing_registration.id,
        'registration_status',
          pg_catalog.lower(pg_catalog.btrim(v_existing_registration.registration_status))
      );
  end;

  return pg_catalog.jsonb_build_object(
    'ok', true,
    'changed', true,
    'code', v_registration_status,
    'registration_id', v_inserted_registration.id,
    'registration_status', v_registration_status
  );
end;
$function$;

alter function public.register_for_event(uuid, boolean) owner to postgres;

comment on function public.register_for_event(uuid, boolean) is
  'Atomowo rejestruje uwierzytelnionego uzytkownika na szkolenie lub liste rezerwowa.';

revoke all on function public.register_for_event(uuid, boolean) from public;
revoke all on function public.register_for_event(uuid, boolean) from anon;
revoke all on function public.register_for_event(uuid, boolean) from service_role;
grant execute on function public.register_for_event(uuid, boolean) to authenticated;
