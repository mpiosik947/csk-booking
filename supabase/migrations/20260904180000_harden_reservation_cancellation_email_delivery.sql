-- SEC-015: make reservation cancellation email delivery bounded and idempotent.

do $preflight$
declare
  v_prepare_oid oid := pg_catalog.to_regprocedure('public.prepare_confirmation_email(text,uuid)');
  v_complete_oid oid := pg_catalog.to_regprocedure('public.complete_confirmation_email(uuid,boolean,text,text)');
  v_rate_limit_oid oid := pg_catalog.to_regprocedure('public.check_confirmation_email_rate_limit(uuid,text)');
  v_constraint text;
begin
  if pg_catalog.to_regclass('public.email_deliveries') is null then
    raise exception 'SEC-015 preflight failed: email_deliveries is absent.';
  end if;

  select pg_catalog.regexp_replace(pg_catalog.pg_get_constraintdef(constraint_record.oid),'\s','','g')
  into v_constraint
  from pg_catalog.pg_constraint as constraint_record
  where constraint_record.conrelid='public.email_deliveries'::regclass
    and constraint_record.conname='email_deliveries_message_type_check'
    and constraint_record.contype='c';

  if v_constraint is distinct from
    'CHECK((message_type=ANY(ARRAY[''event_registration_confirmation''::text,''reservation_confirmation''::text])))' then
    raise exception 'SEC-015 preflight failed: email delivery message types changed.';
  end if;

  if v_prepare_oid is null or v_complete_oid is null or v_rate_limit_oid is null
     or (select pg_catalog.count(*) from pg_catalog.pg_proc as procedure
         join pg_catalog.pg_namespace as namespace on namespace.oid=procedure.pronamespace
         where namespace.nspname='public' and procedure.proname='prepare_confirmation_email') <> 1
     or (select pg_catalog.count(*) from pg_catalog.pg_proc as procedure
         join pg_catalog.pg_namespace as namespace on namespace.oid=procedure.pronamespace
         where namespace.nspname='public' and procedure.proname='complete_confirmation_email') <> 1
     or (select pg_catalog.count(*) from pg_catalog.pg_proc as procedure
         join pg_catalog.pg_namespace as namespace on namespace.oid=procedure.pronamespace
         where namespace.nspname='public' and procedure.proname='check_confirmation_email_rate_limit') <> 1 then
    raise exception 'SEC-015 preflight failed: delivery RPC signatures or overload counts changed.';
  end if;

  if not exists (
    select 1 from pg_catalog.pg_proc as procedure
    join pg_catalog.pg_roles as owner_role on owner_role.oid=procedure.proowner
    where procedure.oid=v_prepare_oid and procedure.prosecdef
      and procedure.provolatile='v' and procedure.prorettype='jsonb'::regtype
      and procedure.proconfig=array['search_path=public, pg_temp']::text[]
      and owner_role.rolname='postgres'
  ) or not pg_catalog.has_function_privilege('authenticated',v_prepare_oid,'EXECUTE')
     or pg_catalog.has_function_privilege('anon',v_prepare_oid,'EXECUTE')
     or pg_catalog.has_function_privilege('service_role',v_prepare_oid,'EXECUTE')
     or exists (
       select 1 from pg_catalog.pg_proc as procedure
       cross join lateral pg_catalog.aclexplode(
         coalesce(procedure.proacl,pg_catalog.acldefault('f',procedure.proowner))
       ) as acl
       where procedure.oid=v_prepare_oid and acl.grantee=0 and acl.privilege_type='EXECUTE'
     ) then
    raise exception 'SEC-015 preflight failed: prepare RPC properties or ACL changed.';
  end if;

  if not pg_catalog.has_function_privilege('service_role',v_complete_oid,'EXECUTE')
     or pg_catalog.has_function_privilege('authenticated',v_complete_oid,'EXECUTE')
     or pg_catalog.has_function_privilege('anon',v_complete_oid,'EXECUTE')
     or not pg_catalog.has_function_privilege('service_role',v_rate_limit_oid,'EXECUTE')
     or pg_catalog.has_function_privilege('authenticated',v_rate_limit_oid,'EXECUTE')
     or pg_catalog.has_function_privilege('anon',v_rate_limit_oid,'EXECUTE') then
    raise exception 'SEC-015 preflight failed: completion or rate-limit RPC ACL changed.';
  end if;

  if exists (
    select 1 from public.email_deliveries
    where message_type='reservation_cancellation'
  ) then
    raise exception 'SEC-015 preflight failed: cancellation delivery state already exists.';
  end if;
end;
$preflight$;

alter table public.email_deliveries
  drop constraint email_deliveries_message_type_check;

alter table public.email_deliveries
  add constraint email_deliveries_message_type_check check (
    message_type in (
      'event_registration_confirmation',
      'reservation_confirmation',
      'reservation_cancellation'
    )
  );

comment on table public.email_deliveries is
  'Technical delivery state for idempotent confirmation and cancellation emails; contains no message content or recipient PII.';

comment on column public.email_deliveries.message_type is
  'Closed technical category of a confirmation or cancellation email.';

create or replace function public.prepare_confirmation_email(
  p_message_type text,
  p_record_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_actor_user_id uuid := auth.uid();
  v_actor_role text;
  v_message_type text := pg_catalog.lower(pg_catalog.btrim(p_message_type));
  v_now timestamptz := pg_catalog.transaction_timestamp();
  v_source_user_id uuid;
  v_source_status text;
  v_delivery public.email_deliveries%rowtype;
  v_attempt_count integer;
  v_attempt_window_started_at timestamptz;
  v_claim_id uuid;
begin
  if v_actor_user_id is null then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'unauthorized'
    );
  end if;

  if p_record_id is null
     or v_message_type is null
     or v_message_type not in (
       'event_registration_confirmation',
       'reservation_confirmation',
       'reservation_cancellation'
     ) then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_status'
    );
  end if;

  if v_message_type = 'event_registration_confirmation' then
    select registration.user_id,
           pg_catalog.lower(pg_catalog.btrim(registration.registration_status))
    into v_source_user_id,v_source_status
    from public.event_registrations as registration
    where registration.id=p_record_id
      and registration.user_id=v_actor_user_id
    for update;

    if not found then
      return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','not_found');
    end if;

    if v_source_status not in ('registered','reserve') then
      return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','invalid_status');
    end if;
  elsif v_message_type = 'reservation_confirmation' then
    select reservation.user_id,
           pg_catalog.lower(pg_catalog.btrim(reservation.reservation_status))
    into v_source_user_id,v_source_status
    from public.reservations as reservation
    where reservation.id=p_record_id
      and reservation.user_id=v_actor_user_id
    for update;

    if not found then
      return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','not_found');
    end if;

    if v_source_status <> 'confirmed' then
      return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','invalid_status');
    end if;
  else
    select reservation.user_id,
           pg_catalog.lower(pg_catalog.btrim(reservation.reservation_status))
    into v_source_user_id,v_source_status
    from public.reservations as reservation
    where reservation.id=p_record_id
    for update;

    if not found then
      return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','not_found');
    end if;

    if v_source_user_id is distinct from v_actor_user_id then
      select pg_catalog.lower(pg_catalog.btrim(profile.role::text))
      into v_actor_role
      from public.profiles as profile
      where profile.user_id=v_actor_user_id;

      if not found or coalesce(v_actor_role,'') not in ('admin','pracownik') then
        return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','not_found');
      end if;
    end if;

    if v_source_status not in (
      'cancelled','canceled','cancelled_by_admin','cancelled_by_user'
    ) then
      return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','invalid_status');
    end if;
  end if;

  insert into public.email_deliveries(message_type,record_id,recipient_user_id)
  values(v_message_type,p_record_id,v_source_user_id)
  on conflict(message_type,record_id) do nothing;

  select delivery.* into v_delivery
  from public.email_deliveries as delivery
  where delivery.message_type=v_message_type
    and delivery.record_id=p_record_id
  for update;

  if not found or v_delivery.recipient_user_id is distinct from v_source_user_id then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','not_found');
  end if;

  if v_delivery.sent_at is not null then
    return pg_catalog.jsonb_build_object('ok',true,'changed',false,'code','already_sent');
  end if;

  if v_delivery.claim_id is not null and v_delivery.claim_expires_at > v_now then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','in_progress');
  end if;

  v_attempt_count := v_delivery.attempt_count;
  v_attempt_window_started_at := v_delivery.attempt_window_started_at;

  if v_attempt_window_started_at is null
     or v_attempt_window_started_at <= v_now - interval '24 hours' then
    v_attempt_count := 0;
    v_attempt_window_started_at := v_now;
  end if;

  if v_attempt_count >= 3 then
    return pg_catalog.jsonb_build_object(
      'ok',false,'changed',false,'code','attempt_limit_reached'
    );
  end if;

  v_claim_id := pg_catalog.gen_random_uuid();
  v_attempt_count := v_attempt_count + 1;

  update public.email_deliveries as delivery
  set claim_id=v_claim_id,
      claim_expires_at=v_now+interval '5 minutes',
      attempt_count=v_attempt_count,
      attempt_window_started_at=v_attempt_window_started_at,
      last_attempt_at=v_now,
      last_error_code=null,
      updated_at=v_now
  where delivery.id=v_delivery.id;

  return pg_catalog.jsonb_build_object(
    'ok',true,
    'changed',true,
    'code','ready',
    'delivery_id',v_delivery.id,
    'claim_id',v_claim_id,
    'claim_expires_at',v_now+interval '5 minutes',
    'attempt_count',v_attempt_count,
    'idempotency_key','confirmation/'||v_message_type||'/'||v_delivery.id::text
  );
end;
$function$;

alter function public.prepare_confirmation_email(text,uuid) owner to postgres;
revoke all on function public.prepare_confirmation_email(text,uuid)
  from public,anon,authenticated,service_role;
grant execute on function public.prepare_confirmation_email(text,uuid)
  to authenticated;

comment on function public.prepare_confirmation_email(text,uuid) is
  'Validates owner or permitted staff and status, then atomically leases one bounded confirmation or cancellation email attempt.';

do $postflight$
declare
  v_prepare_oid oid := pg_catalog.to_regprocedure('public.prepare_confirmation_email(text,uuid)');
  v_constraint text;
begin
  select pg_catalog.regexp_replace(pg_catalog.pg_get_constraintdef(constraint_record.oid),'\s','','g')
  into v_constraint
  from pg_catalog.pg_constraint as constraint_record
  where constraint_record.conrelid='public.email_deliveries'::regclass
    and constraint_record.conname='email_deliveries_message_type_check'
    and constraint_record.contype='c';

  if v_constraint is distinct from
    'CHECK((message_type=ANY(ARRAY[''event_registration_confirmation''::text,''reservation_confirmation''::text,''reservation_cancellation''::text])))' then
    raise exception 'SEC-015 postflight failed: message type constraint is unexpected.';
  end if;

  if v_prepare_oid is null
     or (select pg_catalog.count(*) from pg_catalog.pg_proc as procedure
         join pg_catalog.pg_namespace as namespace on namespace.oid=procedure.pronamespace
         where namespace.nspname='public' and procedure.proname='prepare_confirmation_email') <> 1
     or not exists (
       select 1 from pg_catalog.pg_proc as procedure
       join pg_catalog.pg_roles as owner_role on owner_role.oid=procedure.proowner
       where procedure.oid=v_prepare_oid and procedure.prosecdef
         and procedure.provolatile='v' and procedure.prorettype='jsonb'::regtype
         and procedure.proconfig=array['search_path=public, pg_temp']::text[]
         and owner_role.rolname='postgres'
     ) then
    raise exception 'SEC-015 postflight failed: prepare RPC contract is unexpected.';
  end if;

  if not pg_catalog.has_function_privilege('authenticated',v_prepare_oid,'EXECUTE')
     or pg_catalog.has_function_privilege('anon',v_prepare_oid,'EXECUTE')
     or pg_catalog.has_function_privilege('service_role',v_prepare_oid,'EXECUTE')
     or exists (
       select 1 from pg_catalog.pg_proc as procedure
       cross join lateral pg_catalog.aclexplode(
         coalesce(procedure.proacl,pg_catalog.acldefault('f',procedure.proowner))
       ) as acl
       where procedure.oid=v_prepare_oid and acl.grantee=0 and acl.privilege_type='EXECUTE'
     ) then
    raise exception 'SEC-015 postflight failed: prepare RPC ACL is unexpected.';
  end if;
end;
$postflight$;
