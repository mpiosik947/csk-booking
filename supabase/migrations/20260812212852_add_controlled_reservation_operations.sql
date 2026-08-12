-- Fail closed unless the reservation operational model is exactly the one
-- audited before introducing the controlled writers.
do $preflight$
declare
  v_attendance_function oid := pg_catalog.to_regprocedure(
    'public.update_reservation_attendance(uuid,text)'
  );
  v_cancel_function oid := pg_catalog.to_regprocedure(
    'public.cancel_reservation(uuid)'
  );
begin
  if pg_catalog.to_regclass('public.reservations') is null
     or pg_catalog.to_regclass('public.profiles') is null
     or pg_catalog.to_regclass('public.audit_logs') is null then
    raise exception 'Reservation operations preflight failed: required table is missing.';
  end if;

  if (
    select pg_catalog.count(*)
    from pg_catalog.pg_attribute as attribute
    where attribute.attrelid = 'public.reservations'::pg_catalog.regclass
      and attribute.attname in (
        'id', 'reservation_status', 'attendance_status', 'payment_status',
        'checked_in_at', 'completed_at', 'admin_note'
      )
      and attribute.attnum > 0
      and not attribute.attisdropped
  ) <> 7 then
    raise exception 'Reservation operations preflight failed: required columns differ.';
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_constraint as constraint_record
    where constraint_record.conrelid = 'public.reservations'::pg_catalog.regclass
      and constraint_record.conname = 'reservations_reservation_status_check'
      and pg_catalog.pg_get_constraintdef(constraint_record.oid) like '%confirmed%'
      and pg_catalog.pg_get_constraintdef(constraint_record.oid) like '%completed%'
      and pg_catalog.pg_get_constraintdef(constraint_record.oid) like '%no_show%'
      and pg_catalog.pg_get_constraintdef(constraint_record.oid) like '%cancelled_by_admin%'
      and pg_catalog.pg_get_constraintdef(constraint_record.oid) like '%cancelled_by_user%'
  ) or not exists (
    select 1
    from pg_catalog.pg_constraint as constraint_record
    where constraint_record.conrelid = 'public.reservations'::pg_catalog.regclass
      and constraint_record.conname = 'reservations_attendance_status_check'
      and pg_catalog.pg_get_constraintdef(constraint_record.oid) like '%planned%'
      and pg_catalog.pg_get_constraintdef(constraint_record.oid) like '%present%'
      and pg_catalog.pg_get_constraintdef(constraint_record.oid) like '%completed%'
      and pg_catalog.pg_get_constraintdef(constraint_record.oid) like '%no_show%'
  ) or not exists (
    select 1
    from pg_catalog.pg_constraint as constraint_record
    where constraint_record.conrelid = 'public.reservations'::pg_catalog.regclass
      and constraint_record.conname = 'reservations_payment_status_check'
      and pg_catalog.pg_get_constraintdef(constraint_record.oid) like '%pay_on_site%'
      and pg_catalog.pg_get_constraintdef(constraint_record.oid) like '%paid_on_site%'
      and pg_catalog.pg_get_constraintdef(constraint_record.oid) like '%voucher%'
  ) then
    raise exception 'Reservation operations preflight failed: status constraints differ.';
  end if;

  if v_attendance_function is null or v_cancel_function is null then
    raise exception 'Reservation operations preflight failed: required RPC is missing.';
  end if;

  if (
    select pg_catalog.count(*)
    from pg_catalog.pg_proc as function_record
    join pg_catalog.pg_namespace as function_schema
      on function_schema.oid = function_record.pronamespace
    where function_schema.nspname = 'public'
      and function_record.proname = 'update_reservation_attendance'
  ) <> 1 or (
    select pg_catalog.count(*)
    from pg_catalog.pg_proc as function_record
    join pg_catalog.pg_namespace as function_schema
      on function_schema.oid = function_record.pronamespace
    where function_schema.nspname = 'public'
      and function_record.proname = 'cancel_reservation'
  ) <> 1 then
    raise exception 'Reservation operations preflight failed: unexpected RPC overload.';
  end if;

  if not pg_catalog.has_function_privilege(
    'authenticated', v_attendance_function, 'EXECUTE'
  ) or not pg_catalog.has_function_privilege(
    'authenticated', v_cancel_function, 'EXECUTE'
  ) or pg_catalog.has_function_privilege(
    'anon', v_attendance_function, 'EXECUTE'
  ) or pg_catalog.has_function_privilege(
    'anon', v_cancel_function, 'EXECUTE'
  ) or exists (
    select 1
    from pg_catalog.pg_proc as function_record
    cross join lateral pg_catalog.aclexplode(coalesce(
      function_record.proacl,
      pg_catalog.acldefault('f', function_record.proowner)
    )) as privilege_record
    where function_record.oid in (v_attendance_function, v_cancel_function)
      and privilege_record.grantee = 0
      and privilege_record.privilege_type = 'EXECUTE'
  ) then
    raise exception 'Reservation operations preflight failed: RPC ACL differs.';
  end if;

  if not pg_catalog.has_table_privilege(
    'authenticated', 'public.reservations', 'UPDATE'
  ) or not exists (
    select 1
    from pg_catalog.pg_policy as policy_record
    where policy_record.polrelid = 'public.reservations'::pg_catalog.regclass
      and policy_record.polname = 'Admins and staff can update reservations'
      and policy_record.polcmd = 'w'
  ) then
    raise exception 'Reservation operations preflight failed: legacy UPDATE path differs.';
  end if;

  if exists (
    select 1
    from public.reservations as reservation
    where not (
      (
        reservation.reservation_status = 'confirmed'
        and (
          (
            coalesce(reservation.attendance_status, 'planned') = 'planned'
            and reservation.checked_in_at is null
            and reservation.completed_at is null
          )
          or (
            reservation.attendance_status = 'present'
            and reservation.checked_in_at is not null
            and reservation.completed_at is null
          )
        )
      )
      or (
        reservation.reservation_status = 'completed'
        and reservation.attendance_status = 'completed'
        and reservation.checked_in_at is not null
        and reservation.completed_at is not null
        and reservation.completed_at >= reservation.checked_in_at
      )
      or (
        reservation.reservation_status = 'no_show'
        and reservation.attendance_status = 'no_show'
        and reservation.checked_in_at is null
        and reservation.completed_at is null
      )
      or (
        reservation.reservation_status in (
          'cancelled', 'canceled', 'cancelled_by_admin', 'cancelled_by_user'
        )
        and coalesce(reservation.attendance_status, 'planned') = 'planned'
        and reservation.checked_in_at is null
        and reservation.completed_at is null
      )
    )
  ) then
    raise exception 'Reservation operations preflight failed: inconsistent existing state.';
  end if;
end;
$preflight$;

alter table public.reservations
  add constraint reservations_operational_state_check
  check (
    (
      reservation_status = 'confirmed'
      and (
        (
          coalesce(attendance_status, 'planned') = 'planned'
          and checked_in_at is null
          and completed_at is null
        )
        or (
          attendance_status = 'present'
          and checked_in_at is not null
          and completed_at is null
        )
      )
    )
    or (
      reservation_status = 'completed'
      and attendance_status = 'completed'
      and checked_in_at is not null
      and completed_at is not null
      and completed_at >= checked_in_at
    )
    or (
      reservation_status = 'no_show'
      and attendance_status = 'no_show'
      and checked_in_at is null
      and completed_at is null
    )
    or (
      reservation_status in (
        'cancelled', 'canceled', 'cancelled_by_admin', 'cancelled_by_user'
      )
      and coalesce(attendance_status, 'planned') = 'planned'
      and checked_in_at is null
      and completed_at is null
    )
  );

create or replace function public.update_reservation_attendance(
  p_reservation_id uuid,
  p_action text
)
returns jsonb
language plpgsql
security definer
set search_path to pg_catalog, public, pg_temp
as $function$
declare
  v_actor_user_id uuid := auth.uid();
  v_actor_profile public.profiles%rowtype;
  v_target public.reservations%rowtype;
  v_updated public.reservations%rowtype;
  v_actor_role text;
  v_actor_name text;
  v_action text := pg_catalog.lower(pg_catalog.btrim(p_action));
  v_now timestamptz;
  v_audit_action text;
begin
  if v_actor_user_id is null then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'not_allowed'
    );
  end if;

  if p_reservation_id is null or coalesce(v_action, '') not in (
    'start', 'reset', 'complete', 'no_show'
  ) then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_input'
    );
  end if;

  select profile.*
  into v_actor_profile
  from public.profiles as profile
  where profile.user_id = v_actor_user_id;

  if not found then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'not_allowed'
    );
  end if;

  v_actor_role := pg_catalog.lower(pg_catalog.btrim(v_actor_profile.role::text));

  if v_action in ('start', 'reset') then
    if coalesce(v_actor_role, '') not in ('admin', 'pracownik') then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'not_allowed'
      );
    end if;
  elsif coalesce(v_actor_role, '') not in ('admin', 'pracownik', 'instruktor') then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'not_allowed'
    );
  end if;

  select reservation.*
  into v_target
  from public.reservations as reservation
  where reservation.id = p_reservation_id
  for update;

  if not found then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'reservation_not_found'
    );
  end if;

  if not (
    (
      v_target.reservation_status = 'confirmed'
      and (
        (
          coalesce(v_target.attendance_status, 'planned') = 'planned'
          and v_target.checked_in_at is null
          and v_target.completed_at is null
        )
        or (
          v_target.attendance_status = 'present'
          and v_target.checked_in_at is not null
          and v_target.completed_at is null
        )
      )
    )
    or (
      v_target.reservation_status = 'completed'
      and v_target.attendance_status = 'completed'
      and v_target.checked_in_at is not null
      and v_target.completed_at is not null
      and v_target.completed_at >= v_target.checked_in_at
    )
    or (
      v_target.reservation_status = 'no_show'
      and v_target.attendance_status = 'no_show'
      and v_target.checked_in_at is null
      and v_target.completed_at is null
    )
    or (
      v_target.reservation_status in (
        'cancelled', 'canceled', 'cancelled_by_admin', 'cancelled_by_user'
      )
      and coalesce(v_target.attendance_status, 'planned') = 'planned'
      and v_target.checked_in_at is null
      and v_target.completed_at is null
    )
  ) then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_state',
      'reservation_id', v_target.id, 'action', v_action
    );
  end if;

  if v_action = 'start' then
    if v_target.reservation_status = 'confirmed'
       and v_target.attendance_status = 'present' then
      return pg_catalog.jsonb_build_object(
        'ok', true, 'changed', false, 'code', 'already_started',
        'reservation_id', v_target.id, 'action', v_action,
        'reservation_status', v_target.reservation_status,
        'attendance_status', v_target.attendance_status,
        'checked_in_at', v_target.checked_in_at,
        'completed_at', v_target.completed_at
      );
    end if;
    if v_target.reservation_status <> 'confirmed'
       or coalesce(v_target.attendance_status, 'planned') <> 'planned' then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'invalid_transition',
        'reservation_id', v_target.id, 'action', v_action
      );
    end if;
    v_audit_action := 'RESERVATION_STARTED';
  elsif v_action = 'reset' then
    if v_target.reservation_status = 'confirmed'
       and coalesce(v_target.attendance_status, 'planned') = 'planned' then
      return pg_catalog.jsonb_build_object(
        'ok', true, 'changed', false, 'code', 'already_planned',
        'reservation_id', v_target.id, 'action', v_action,
        'reservation_status', v_target.reservation_status,
        'attendance_status', coalesce(v_target.attendance_status, 'planned'),
        'checked_in_at', v_target.checked_in_at,
        'completed_at', v_target.completed_at
      );
    end if;
    if v_target.reservation_status <> 'confirmed'
       or v_target.attendance_status <> 'present' then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'invalid_transition',
        'reservation_id', v_target.id, 'action', v_action
      );
    end if;
    v_audit_action := 'RESERVATION_ATTENDANCE_RESET';
  elsif v_action = 'complete' then
    if v_target.reservation_status = 'completed'
       and v_target.attendance_status = 'completed' then
      return pg_catalog.jsonb_build_object(
        'ok', true, 'changed', false, 'code', 'already_completed',
        'reservation_id', v_target.id, 'action', v_action,
        'reservation_status', v_target.reservation_status,
        'attendance_status', v_target.attendance_status,
        'checked_in_at', v_target.checked_in_at,
        'completed_at', v_target.completed_at
      );
    end if;
    if v_target.reservation_status <> 'confirmed'
       or v_target.attendance_status <> 'present'
       or v_target.checked_in_at is null then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'invalid_transition',
        'reservation_id', v_target.id, 'action', v_action
      );
    end if;
    v_audit_action := 'CHECK_IN_COMPLETED';
  else
    if v_target.reservation_status = 'no_show'
       and v_target.attendance_status = 'no_show' then
      return pg_catalog.jsonb_build_object(
        'ok', true, 'changed', false, 'code', 'already_no_show',
        'reservation_id', v_target.id, 'action', v_action,
        'reservation_status', v_target.reservation_status,
        'attendance_status', v_target.attendance_status,
        'checked_in_at', v_target.checked_in_at,
        'completed_at', v_target.completed_at
      );
    end if;
    if v_target.reservation_status <> 'confirmed'
       or coalesce(v_target.attendance_status, 'planned') <> 'planned' then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'invalid_transition',
        'reservation_id', v_target.id, 'action', v_action
      );
    end if;
    v_audit_action := 'RESERVATION_NO_SHOW';
  end if;

  v_now := pg_catalog.transaction_timestamp();

  update public.reservations as reservation
  set reservation_status = case v_action
        when 'complete' then 'completed'
        when 'no_show' then 'no_show'
        else 'confirmed'
      end,
      attendance_status = case v_action
        when 'start' then 'present'
        when 'reset' then 'planned'
        when 'complete' then 'completed'
        else 'no_show'
      end,
      checked_in_at = case v_action
        when 'start' then v_now
        when 'reset' then null
        when 'complete' then v_target.checked_in_at
        else null
      end,
      completed_at = case v_action
        when 'complete' then v_now
        else null
      end
  where reservation.id = v_target.id
  returning reservation.* into v_updated;

  v_actor_name := coalesce(
    nullif(pg_catalog.btrim(pg_catalog.concat_ws(
      ' ',
      nullif(pg_catalog.btrim(v_actor_profile.first_name), ''),
      nullif(pg_catalog.btrim(v_actor_profile.last_name), '')
    )), ''),
    nullif(pg_catalog.btrim(v_actor_profile.full_name), ''),
    'Operator'
  );

  insert into public.audit_logs (
    actor_user_id, actor_name, actor_role, action,
    target_type, target_id, target_name, details
  ) values (
    v_actor_user_id, v_actor_name, v_actor_role, v_audit_action,
    'reservation', v_target.id, 'Rezerwacja',
    pg_catalog.jsonb_build_object(
      'action', v_action,
      'operator_role', v_actor_role,
      'previous_reservation_status', v_target.reservation_status,
      'new_reservation_status', v_updated.reservation_status,
      'previous_attendance_status', v_target.attendance_status,
      'new_attendance_status', v_updated.attendance_status,
      'checked_in_at_changed',
        v_target.checked_in_at is distinct from v_updated.checked_in_at,
      'completed_at_changed',
        v_target.completed_at is distinct from v_updated.completed_at,
      'changed_at', v_now
    )
  );

  return pg_catalog.jsonb_build_object(
    'ok', true, 'changed', true, 'code', case v_action
      when 'start' then 'started'
      when 'reset' then 'reset'
      when 'complete' then 'completed'
      else 'no_show'
    end,
    'reservation_id', v_updated.id, 'action', v_action,
    'reservation_status', v_updated.reservation_status,
    'attendance_status', v_updated.attendance_status,
    'payment_status', v_updated.payment_status,
    'checked_in_at', v_updated.checked_in_at,
    'completed_at', v_updated.completed_at
  );
end;
$function$;

comment on function public.update_reservation_attendance(uuid, text) is
  'Atomowo rozpoczyna, resetuje, kończy lub oznacza no-show wizyty z row lockiem i auditem.';

create or replace function public.update_reservation_payment(
  p_reservation_id uuid,
  p_payment_status text
)
returns jsonb
language plpgsql
security definer
set search_path to pg_catalog, public, pg_temp
as $function$
declare
  v_actor_user_id uuid := auth.uid();
  v_actor_profile public.profiles%rowtype;
  v_target public.reservations%rowtype;
  v_updated public.reservations%rowtype;
  v_actor_role text;
  v_actor_name text;
  v_payment_status text := pg_catalog.lower(pg_catalog.btrim(p_payment_status));
  v_now timestamptz;
begin
  if v_actor_user_id is null then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'not_allowed'
    );
  end if;

  if p_reservation_id is null or coalesce(v_payment_status, '') not in (
    'pay_on_site', 'paid', 'paid_on_site', 'unpaid', 'free', 'voucher'
  ) then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_input'
    );
  end if;

  select profile.*
  into v_actor_profile
  from public.profiles as profile
  where profile.user_id = v_actor_user_id;

  if not found then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'not_allowed'
    );
  end if;

  v_actor_role := pg_catalog.lower(pg_catalog.btrim(v_actor_profile.role::text));
  if coalesce(v_actor_role, '') not in ('admin', 'pracownik') then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'not_allowed'
    );
  end if;

  select reservation.*
  into v_target
  from public.reservations as reservation
  where reservation.id = p_reservation_id
  for update;

  if not found then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'reservation_not_found'
    );
  end if;

  if v_target.payment_status = v_payment_status then
    return pg_catalog.jsonb_build_object(
      'ok', true, 'changed', false, 'code', 'already_set',
      'reservation_id', v_target.id,
      'payment_status', v_target.payment_status
    );
  end if;

  update public.reservations as reservation
  set payment_status = v_payment_status
  where reservation.id = v_target.id
  returning reservation.* into v_updated;

  v_now := pg_catalog.transaction_timestamp();
  v_actor_name := coalesce(
    nullif(pg_catalog.btrim(pg_catalog.concat_ws(
      ' ',
      nullif(pg_catalog.btrim(v_actor_profile.first_name), ''),
      nullif(pg_catalog.btrim(v_actor_profile.last_name), '')
    )), ''),
    nullif(pg_catalog.btrim(v_actor_profile.full_name), ''),
    'Operator'
  );

  insert into public.audit_logs (
    actor_user_id, actor_name, actor_role, action,
    target_type, target_id, target_name, details
  ) values (
    v_actor_user_id, v_actor_name, v_actor_role,
    'RESERVATION_PAYMENT_STATUS_CHANGED',
    'reservation', v_target.id, 'Rezerwacja',
    pg_catalog.jsonb_build_object(
      'operator_role', v_actor_role,
      'previous_payment_status', v_target.payment_status,
      'new_payment_status', v_updated.payment_status,
      'changed_at', v_now
    )
  );

  return pg_catalog.jsonb_build_object(
    'ok', true, 'changed', true, 'code', 'updated',
    'reservation_id', v_updated.id,
    'reservation_status', v_updated.reservation_status,
    'attendance_status', v_updated.attendance_status,
    'payment_status', v_updated.payment_status,
    'checked_in_at', v_updated.checked_in_at,
    'completed_at', v_updated.completed_at
  );
end;
$function$;

comment on function public.update_reservation_payment(uuid, text) is
  'Atomowo zmienia wyłącznie status płatności rezerwacji z row lockiem i auditem.';

create or replace function public.update_reservation_admin_note(
  p_reservation_id uuid,
  p_admin_note text
)
returns jsonb
language plpgsql
security definer
set search_path to pg_catalog, public, pg_temp
as $function$
declare
  v_actor_user_id uuid := auth.uid();
  v_actor_profile public.profiles%rowtype;
  v_target public.reservations%rowtype;
  v_actor_role text;
  v_actor_name text;
  v_admin_note text := case
    when p_admin_note is null then null
    when pg_catalog.btrim(p_admin_note) = '' then null
    else p_admin_note
  end;
begin
  if v_actor_user_id is null then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'not_allowed'
    );
  end if;

  if p_reservation_id is null or pg_catalog.char_length(v_admin_note) > 4000 then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_input'
    );
  end if;

  select profile.*
  into v_actor_profile
  from public.profiles as profile
  where profile.user_id = v_actor_user_id;

  if not found then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'not_allowed'
    );
  end if;

  v_actor_role := pg_catalog.lower(pg_catalog.btrim(v_actor_profile.role::text));
  if coalesce(v_actor_role, '') not in ('admin', 'pracownik') then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'not_allowed'
    );
  end if;

  select reservation.*
  into v_target
  from public.reservations as reservation
  where reservation.id = p_reservation_id
  for update;

  if not found then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'reservation_not_found'
    );
  end if;

  if v_target.admin_note is not distinct from v_admin_note then
    return pg_catalog.jsonb_build_object(
      'ok', true, 'changed', false, 'code', 'already_set',
      'reservation_id', v_target.id
    );
  end if;

  update public.reservations as reservation
  set admin_note = v_admin_note
  where reservation.id = v_target.id;

  v_actor_name := coalesce(
    nullif(pg_catalog.btrim(pg_catalog.concat_ws(
      ' ',
      nullif(pg_catalog.btrim(v_actor_profile.first_name), ''),
      nullif(pg_catalog.btrim(v_actor_profile.last_name), '')
    )), ''),
    nullif(pg_catalog.btrim(v_actor_profile.full_name), ''),
    'Operator'
  );

  insert into public.audit_logs (
    actor_user_id, actor_name, actor_role, action,
    target_type, target_id, target_name, details
  ) values (
    v_actor_user_id, v_actor_name, v_actor_role,
    'RESERVATION_ADMIN_NOTE_CHANGED',
    'reservation', v_target.id, 'Rezerwacja',
    pg_catalog.jsonb_build_object(
      'operator_role', v_actor_role,
      'previous_note_present', v_target.admin_note is not null,
      'new_note_present', v_admin_note is not null,
      'changed_at', pg_catalog.transaction_timestamp()
    )
  );

  return pg_catalog.jsonb_build_object(
    'ok', true, 'changed', true, 'code', 'updated',
    'reservation_id', v_target.id,
    'admin_note_is_null', v_admin_note is null
  );
end;
$function$;

comment on function public.update_reservation_admin_note(uuid, text) is
  'Atomowo zmienia wyłącznie notatkę administracyjną rezerwacji z row lockiem i auditem bez treści notatki w audicie.';

-- Preserve the existing cancellation contract while rejecting cancellation
-- after a visit has already started.
create or replace function public.cancel_reservation(
  p_reservation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path to pg_catalog, public, pg_temp
as $function$
declare
  actor_user_id uuid := auth.uid();
  actor_profile public.profiles%rowtype;
  target_reservation public.reservations%rowtype;
  actor_role text;
  actor_name text;
  current_status text;
  result_status text;
  cancelled_by_value text;
  audit_action text;
  reservation_start_at timestamptz;
  cancellation_window_hours_raw numeric;
  cancellation_window_hours_rounded numeric;
  within_client_cancellation_window boolean;
begin
  if actor_user_id is null then
    raise exception 'Brak aktywnej sesji użytkownika.' using errcode = '42501';
  end if;
  if p_reservation_id is null then
    raise exception 'Brak identyfikatora rezerwacji.' using errcode = '22023';
  end if;

  select profile.* into actor_profile
  from public.profiles as profile
  where profile.user_id = actor_user_id;
  if not found then
    raise exception 'Brak profilu operatora.' using errcode = '42501';
  end if;

  actor_role := pg_catalog.lower(pg_catalog.btrim(actor_profile.role::text));
  if coalesce(actor_role, '') not in ('user', 'admin', 'pracownik') then
    raise exception 'Brak uprawnień do anulowania rezerwacji.' using errcode = '42501';
  end if;

  select reservation.* into target_reservation
  from public.reservations as reservation
  where reservation.id = p_reservation_id
  for update;
  if not found then
    raise exception 'Nie znaleziono rezerwacji.' using errcode = 'P0002';
  end if;

  if actor_role = 'user'
     and target_reservation.user_id is distinct from actor_user_id then
    raise exception 'Brak uprawnień do anulowania tej rezerwacji.' using errcode = '42501';
  end if;

  current_status := pg_catalog.lower(pg_catalog.btrim(target_reservation.reservation_status));
  reservation_start_at :=
    (target_reservation.reservation_date + target_reservation.start_time)
      at time zone 'Europe/Warsaw';
  cancellation_window_hours_raw := extract(
    epoch from (reservation_start_at - pg_catalog.transaction_timestamp())
  ) / 3600.0;
  cancellation_window_hours_rounded := pg_catalog.round(cancellation_window_hours_raw, 2);
  within_client_cancellation_window := cancellation_window_hours_raw >= 12;

  if current_status in (
    'cancelled', 'canceled', 'cancelled_by_user', 'cancelled_by_admin'
  ) then
    cancelled_by_value := case current_status
      when 'cancelled_by_user' then 'user'
      when 'cancelled_by_admin' then 'staff'
      else null
    end;
    return pg_catalog.jsonb_build_object(
      'reservation_id', target_reservation.id, 'changed', false,
      'previous_status', target_reservation.reservation_status,
      'new_status', target_reservation.reservation_status,
      'cancelled_by', cancelled_by_value, 'operator_role', actor_role,
      'cancellation_window_hours', cancellation_window_hours_rounded,
      'within_client_cancellation_window', within_client_cancellation_window
    );
  end if;

  if current_status is distinct from 'confirmed' then
    raise exception 'Rezerwacji w tym statusie nie można anulować.' using errcode = '55000';
  end if;
  if coalesce(target_reservation.attendance_status, 'planned') <> 'planned'
     or target_reservation.checked_in_at is not null
     or target_reservation.completed_at is not null then
    raise exception 'Rozpoczętej wizyty nie można anulować.' using errcode = '55000';
  end if;
  if actor_role = 'user' and not within_client_cancellation_window then
    raise exception 'Rezerwację można anulować najpóźniej 12 godzin przed rozpoczęciem.' using errcode = '55000';
  end if;

  if actor_role = 'user' then
    result_status := 'cancelled_by_user';
    cancelled_by_value := 'user';
    audit_action := 'reservation_cancelled_by_user';
  else
    result_status := 'cancelled_by_admin';
    cancelled_by_value := 'staff';
    audit_action := 'reservation_cancelled_by_staff';
  end if;

  update public.reservations as reservation
  set reservation_status = result_status
  where reservation.id = p_reservation_id
  returning reservation.reservation_status into result_status;

  actor_name := coalesce(
    nullif(pg_catalog.btrim(pg_catalog.concat_ws(
      ' ',
      nullif(pg_catalog.btrim(actor_profile.first_name), ''),
      nullif(pg_catalog.btrim(actor_profile.last_name), '')
    )), ''),
    nullif(pg_catalog.btrim(actor_profile.full_name), ''),
    nullif(pg_catalog.btrim(actor_profile.email), ''),
    'Nieznany użytkownik'
  );

  insert into public.audit_logs (
    actor_user_id, actor_name, actor_role, action,
    target_type, target_id, target_name, details
  ) values (
    actor_user_id, actor_name, actor_role, audit_action,
    'reservation', target_reservation.id, 'Rezerwacja',
    pg_catalog.jsonb_build_object(
      'previous_status', target_reservation.reservation_status,
      'new_status', result_status, 'operator_role', actor_role,
      'cancellation_window_hours', cancellation_window_hours_rounded,
      'within_client_cancellation_window', within_client_cancellation_window
    )
  );

  return pg_catalog.jsonb_build_object(
    'reservation_id', target_reservation.id, 'changed', true,
    'previous_status', target_reservation.reservation_status,
    'new_status', result_status, 'cancelled_by', cancelled_by_value,
    'operator_role', actor_role,
    'cancellation_window_hours', cancellation_window_hours_rounded,
    'within_client_cancellation_window', within_client_cancellation_window
  );
end;
$function$;

comment on function public.cancel_reservation(uuid) is
  'Atomowo anuluje nierozpoczętą rezerwację z kontrolą sesji, roli, własności, statusu i limitu czasu oraz zapisuje audit log.';

revoke all on function public.update_reservation_attendance(uuid, text) from public;
revoke all on function public.update_reservation_attendance(uuid, text) from anon;
grant execute on function public.update_reservation_attendance(uuid, text) to authenticated;
grant execute on function public.update_reservation_attendance(uuid, text) to service_role;

revoke all on function public.update_reservation_payment(uuid, text) from public;
revoke all on function public.update_reservation_payment(uuid, text) from anon;
revoke all on function public.update_reservation_payment(uuid, text) from service_role;
grant execute on function public.update_reservation_payment(uuid, text) to authenticated;

revoke all on function public.update_reservation_admin_note(uuid, text) from public;
revoke all on function public.update_reservation_admin_note(uuid, text) from anon;
revoke all on function public.update_reservation_admin_note(uuid, text) from service_role;
grant execute on function public.update_reservation_admin_note(uuid, text) to authenticated;

revoke all on function public.cancel_reservation(uuid) from public;
revoke all on function public.cancel_reservation(uuid) from anon;
grant execute on function public.cancel_reservation(uuid) to authenticated;
grant execute on function public.cancel_reservation(uuid) to service_role;

drop policy "Admins and staff can update reservations"
on public.reservations;

revoke update on table public.reservations from authenticated;
revoke update on table public.reservations from anon;
revoke update on table public.reservations from public;
