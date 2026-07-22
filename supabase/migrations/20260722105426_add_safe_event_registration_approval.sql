create or replace function public.approve_event_registration(
  p_registration_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path to public, pg_temp
as $function$
declare
  actor_user_id uuid := auth.uid();
  actor_role text;
  target_event_id uuid;
  target_event public.events%rowtype;
  target_registration public.event_registrations%rowtype;
  normalized_status text;
  action_time timestamptz := pg_catalog.transaction_timestamp();
begin
  if actor_user_id is null then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'changed', false,
      'code', 'unauthorized'
    );
  end if;

  select pg_catalog.lower(pg_catalog.btrim(profile.role::text))
  into actor_role
  from public.profiles as profile
  where profile.user_id = actor_user_id;

  if not found or coalesce(actor_role, '') not in ('admin', 'pracownik') then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'changed', false,
      'code', 'unauthorized'
    );
  end if;

  if p_registration_id is null then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'changed', false,
      'code', 'registration_not_found'
    );
  end if;

  select registration.event_id
  into target_event_id
  from public.event_registrations as registration
  where registration.id = p_registration_id;

  if not found then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'changed', false,
      'code', 'registration_not_found'
    );
  end if;

  if target_event_id is null then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'changed', false,
      'code', 'event_not_found'
    );
  end if;

  select event_record.*
  into target_event
  from public.events as event_record
  where event_record.id = target_event_id
  for update;

  if not found then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'changed', false,
      'code', 'event_not_found'
    );
  end if;

  select registration.*
  into target_registration
  from public.event_registrations as registration
  where registration.id = p_registration_id
    and registration.event_id = target_event.id
  for update;

  if not found then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'changed', false,
      'code', 'registration_not_found'
    );
  end if;

  normalized_status :=
    pg_catalog.lower(pg_catalog.btrim(target_registration.registration_status));

  if normalized_status = 'approved' then
    return pg_catalog.jsonb_build_object(
      'ok', true,
      'changed', false,
      'code', 'unchanged',
      'registration_id', target_registration.id,
      'event_id', target_registration.event_id,
      'previous_status', 'approved',
      'new_status', 'approved'
    );
  end if;

  if normalized_status <> 'registered' then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'changed', false,
      'code', 'invalid_transition'
    );
  end if;

  update public.event_registrations as registration
  set registration_status = 'approved'
  where registration.id = target_registration.id;

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
    'Obsługa',
    actor_role,
    'event_registration_approved_by_staff',
    'event_registration',
    target_registration.id,
    'Zapis na szkolenie',
    pg_catalog.jsonb_build_object(
      'registration_id', target_registration.id,
      'event_id', target_registration.event_id,
      'previous_status', normalized_status,
      'new_status', 'approved',
      'operator_role', actor_role,
      'changed_at', action_time
    )
  );

  return pg_catalog.jsonb_build_object(
    'ok', true,
    'changed', true,
    'code', 'updated',
    'registration_id', target_registration.id,
    'event_id', target_registration.event_id,
    'previous_status', normalized_status,
    'new_status', 'approved'
  );
end;
$function$;

alter function public.approve_event_registration(uuid) owner to postgres;

comment on function public.approve_event_registration(uuid) is
  'Atomowo zatwierdza istniejący zapis registered dla administratora lub pracownika i zapisuje audit log.';

revoke all on function public.approve_event_registration(uuid) from public;
revoke all on function public.approve_event_registration(uuid) from anon;
revoke all on function public.approve_event_registration(uuid) from service_role;
grant execute on function public.approve_event_registration(uuid) to authenticated;

create or replace function public.cancel_event_registration(
  p_registration_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path to public, pg_temp
as $$
declare
  actor_user_id uuid := auth.uid();
  actor_profile public.profiles%rowtype;
  target_registration public.event_registrations%rowtype;
  target_event public.events%rowtype;
  target_event_id uuid;
  actor_role text;
  normalized_status text;
  actor_name text;
  audit_action text;
  is_self_service_actor boolean;
  freed_participant_place boolean := false;
  event_start_at timestamptz;
begin
  if actor_user_id is null then
    raise exception 'Brak aktywnej sesji użytkownika.'
      using errcode = '42501';
  end if;

  if p_registration_id is null then
    raise exception 'Brak identyfikatora zapisu na szkolenie.'
      using errcode = '22023';
  end if;

  select profile.*
  into actor_profile
  from public.profiles as profile
  where profile.user_id = actor_user_id;

  if not found then
    raise exception 'Brak profilu operatora.'
      using errcode = '42501';
  end if;

  actor_role := lower(btrim(actor_profile.role::text));
  is_self_service_actor := actor_role in ('user', 'instruktor');

  if coalesce(actor_role, '') not in (
    'user',
    'instruktor',
    'admin',
    'pracownik'
  ) then
    raise exception 'Brak uprawnień do anulowania zapisu na szkolenie.'
      using errcode = '42501';
  end if;

  select registration.event_id
  into target_event_id
  from public.event_registrations as registration
  where registration.id = p_registration_id;

  if not found then
    raise exception 'Nie znaleziono zapisu na szkolenie.'
      using errcode = 'P0002';
  end if;

  if target_event_id is null then
    raise exception 'Nie można ustalić terminu rozpoczęcia szkolenia.'
      using errcode = '55000';
  end if;

  select event_item.*
  into target_event
  from public.events as event_item
  where event_item.id = target_event_id
  for update;

  if not found then
    raise exception 'Nie można ustalić terminu rozpoczęcia szkolenia.'
      using errcode = '55000';
  end if;

  select registration.*
  into target_registration
  from public.event_registrations as registration
  where registration.id = p_registration_id
    and registration.event_id = target_event.id
  for update;

  if not found then
    raise exception 'Nie znaleziono zapisu na szkolenie.'
      using errcode = 'P0002';
  end if;

  if is_self_service_actor
     and target_registration.user_id is distinct from actor_user_id then
    raise exception 'Brak uprawnień do anulowania tego zapisu na szkolenie.'
      using errcode = '42501';
  end if;

  normalized_status := lower(btrim(target_registration.registration_status));

  if normalized_status = 'cancelled' then
    return jsonb_build_object(
      'registration_id', target_registration.id,
      'event_id', target_registration.event_id,
      'changed', false,
      'previous_status', normalized_status,
      'new_status', normalized_status,
      'operator_role', actor_role,
      'freed_participant_place', false
    );
  end if;

  if coalesce(normalized_status, '') not in (
    'registered',
    'approved',
    'reserve',
    'participant'
  ) then
    raise exception 'Zapisu w tym statusie nie można anulować.'
      using errcode = '55000';
  end if;

  -- Status participant jest przejściowy. Jego semantyka i wpływ na limit miejsc
  -- wymagają późniejszego uporządkowania; obecnie anulowanie nie zwalnia miejsca.
  freed_participant_place := normalized_status in ('registered', 'approved');

  if is_self_service_actor then
    if target_event.event_date is null
       or target_event.start_time is null then
      raise exception 'Nie można ustalić terminu rozpoczęcia szkolenia.'
        using errcode = '55000';
    end if;

    event_start_at :=
      (target_event.event_date + target_event.start_time)
        at time zone 'Europe/Warsaw';

    if event_start_at is null then
      raise exception 'Nie można ustalić terminu rozpoczęcia szkolenia.'
        using errcode = '55000';
    end if;

    if event_start_at - transaction_timestamp() < interval '72 hours' then
      raise exception 'Zapis można anulować najpóźniej 72 godziny przed rozpoczęciem szkolenia.'
        using errcode = '55000';
    end if;
  end if;

  update public.event_registrations
  set registration_status = 'cancelled'
  where id = target_registration.id;

  if is_self_service_actor then
    actor_name := 'Użytkownik';
    audit_action := 'event_registration_cancelled_by_user';
  else
    actor_name := 'Obsługa';
    audit_action := 'event_registration_cancelled_by_staff';
  end if;

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
    'event_registration',
    target_registration.id,
    'Zapis na szkolenie',
    jsonb_build_object(
      'registration_id', target_registration.id,
      'event_id', target_registration.event_id,
      'previous_status', normalized_status,
      'new_status', 'cancelled',
      'operator_role', actor_role,
      'freed_participant_place', freed_participant_place
    )
  );

  return jsonb_build_object(
    'registration_id', target_registration.id,
    'event_id', target_registration.event_id,
    'changed', true,
    'previous_status', normalized_status,
    'new_status', 'cancelled',
    'operator_role', actor_role,
    'freed_participant_place', freed_participant_place
  );
end;
$$;

comment on function public.cancel_event_registration(uuid) is
  'Kontrolowanie anuluje zapis na szkolenie i zwraca flagę informującą, czy zwolniono miejsce uczestnika.';

revoke all on function public.cancel_event_registration(uuid)
from public;

revoke all on function public.cancel_event_registration(uuid)
from anon;

grant execute on function public.cancel_event_registration(uuid)
to authenticated;
