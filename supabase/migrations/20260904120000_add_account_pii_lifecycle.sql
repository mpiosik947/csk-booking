-- SEC-009 core lifecycle: owner export and atomic business-data anonymization.
-- Time-based retention remains outside this migration (SECURITY REMEDIATION 10B).

do $preflight$
declare
  v_reservations oid := pg_catalog.to_regclass('public.reservations');
  v_registrations oid := pg_catalog.to_regclass('public.event_registrations');
begin
  if pg_catalog.to_regclass('auth.users') is null
     or pg_catalog.to_regclass('public.profiles') is null
     or v_reservations is null
     or v_registrations is null
     or pg_catalog.to_regclass('public.audit_logs') is null
     or pg_catalog.to_regclass('public.email_deliveries') is null
     or pg_catalog.to_regclass('public.confirmation_email_rate_limits') is null then
    raise exception 'SEC-009 preflight failed: required relations are missing.';
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_constraint as constraint_record
    where constraint_record.conrelid = v_reservations
      and constraint_record.contype = 'f'
      and constraint_record.confrelid = 'auth.users'::pg_catalog.regclass
      and constraint_record.confdeltype = 'r'
      and constraint_record.conkey = array[
        (select attribute.attnum
         from pg_catalog.pg_attribute as attribute
         where attribute.attrelid = v_reservations
           and attribute.attname = 'user_id')
      ]::smallint[]
  ) then
    raise exception 'SEC-009 preflight failed: reservations Auth FK is not ON DELETE RESTRICT.';
  end if;

  if exists (
    select 1
    from pg_catalog.pg_constraint as constraint_record
    where constraint_record.conrelid = v_registrations
      and constraint_record.contype = 'f'
      and constraint_record.confrelid = 'auth.users'::pg_catalog.regclass
      and constraint_record.conkey @> array[
        (select attribute.attnum
         from pg_catalog.pg_attribute as attribute
         where attribute.attrelid = v_registrations
           and attribute.attname = 'user_id')
      ]::smallint[]
  ) then
    raise exception 'SEC-009 preflight failed: event_registrations unexpectedly has an Auth user FK.';
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_attribute as attribute
    where attribute.attrelid = v_reservations
      and attribute.attname = 'user_id'
      and attribute.atttypid = 'uuid'::pg_catalog.regtype
      and attribute.attnotnull
      and not attribute.attisdropped
  ) or not exists (
    select 1
    from pg_catalog.pg_attribute as attribute
    where attribute.attrelid = v_reservations
      and attribute.attname = 'check_in_token'
      and attribute.atttypid = 'uuid'::pg_catalog.regtype
      and attribute.attnotnull
      and not attribute.attisdropped
  ) then
    raise exception 'SEC-009 preflight failed: reservation identity/token nullability differs.';
  end if;

  if not exists (
    select 1 from pg_catalog.pg_constraint
    where conrelid = v_registrations
      and conname = 'event_registrations_promotion_confirmed_token_check'
      and contype = 'c'
  ) or not exists (
    select 1 from pg_catalog.pg_constraint
    where conrelid = v_registrations
      and conname = 'event_registrations_promotion_sent_token_check'
      and contype = 'c'
  ) then
    raise exception 'SEC-009 preflight failed: promotion token checks are absent.';
  end if;

  if exists (
    select 1
    from pg_catalog.pg_proc as procedure
    join pg_catalog.pg_namespace as namespace
      on namespace.oid = procedure.pronamespace
    where namespace.nspname = 'public'
      and procedure.proname in (
        'redact_account_audit_details_v1',
        'export_my_data_v1',
        'anonymize_my_account_v1'
      )
  ) then
    raise exception 'SEC-009 preflight failed: target function name already exists.';
  end if;

  if exists (
    select 1
    from pg_catalog.pg_class as relation
    where relation.oid in (
      'public.profiles'::pg_catalog.regclass,
      v_reservations,
      v_registrations,
      'public.audit_logs'::pg_catalog.regclass,
      'public.email_deliveries'::pg_catalog.regclass,
      'public.confirmation_email_rate_limits'::pg_catalog.regclass
    )
      and not relation.relrowsecurity
  ) then
    raise exception 'SEC-009 preflight failed: required public table has RLS disabled.';
  end if;

  if pg_catalog.has_table_privilege(
       'authenticated', 'public.audit_logs',
       'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN'
     ) then
    raise exception 'SEC-009 preflight failed: SEC-007 audit mutation boundary differs.';
  end if;
end;
$preflight$;

alter table public.reservations
  alter column user_id drop not null,
  alter column check_in_token drop not null,
  add column pii_anonymized_at timestamp with time zone;

comment on column public.reservations.pii_anonymized_at is
  'Database time at which direct account PII and owner linkage were removed.';

alter table public.event_registrations
  add column pii_anonymized_at timestamp with time zone;

comment on column public.event_registrations.pii_anonymized_at is
  'Database time at which direct account PII and owner linkage were removed.';

alter table public.event_registrations
  drop constraint event_registrations_promotion_confirmed_token_check,
  drop constraint event_registrations_promotion_sent_token_check;

alter table public.event_registrations
  add constraint event_registrations_promotion_confirmed_token_check
    check (
      promotion_confirmed_at is null
      or promotion_token is not null
      or pii_anonymized_at is not null
    ),
  add constraint event_registrations_promotion_sent_token_check
    check (
      promotion_email_sent_at is null
      or promotion_token is not null
      or pii_anonymized_at is not null
    );

create function public.redact_account_audit_details_v1(
  p_value jsonb,
  p_subject_user_id uuid,
  p_pseudonym text,
  p_direct_values text[]
)
returns jsonb
language plpgsql
immutable
security invoker
set search_path = pg_catalog, public, pg_temp
as $function$
declare
  v_kind text;
  v_key text;
  v_item jsonb;
  v_result jsonb;
  v_scalar text;
begin
  if p_value is null then
    return null;
  end if;

  v_kind := pg_catalog.jsonb_typeof(p_value);

  if v_kind = 'object' then
    v_result := '{}'::jsonb;
    for v_key, v_item in
      select entry.key, entry.value
      from pg_catalog.jsonb_each(p_value) as entry
    loop
      if pg_catalog.lower(v_key) = any (array[
        'first_name', 'last_name', 'full_name',
        'email', 'phone',
        'customer_name', 'customer_email', 'customer_phone',
        'postal_code', 'city', 'street', 'house_number', 'apartment_number',
        'weapon_permit_number', 'weapon_permit_type', 'weapon_permit_issuer',
        'range_officer_number', 'instructor_number',
        'admin_note', 'verification_note', 'permissions_verification_note',
        'reservation_note',
        'check_in_token', 'promotion_token', 'confirmation_token',
        'reserve_token', 'jwt', 'access_token', 'refresh_token'
      ]::text[]) then
        continue;
      end if;

      if pg_catalog.lower(v_key) = any (array[
        'actor_user_id', 'user_id', 'target_user_id', 'recipient_user_id',
        'verified_by', 'unverified_by', 'permissions_verified_by'
      ]::text[])
         and pg_catalog.jsonb_typeof(v_item) = 'string'
         and v_item #>> '{}' = p_subject_user_id::text then
        v_result := v_result || pg_catalog.jsonb_build_object(v_key, p_pseudonym);
      else
        v_result := v_result || pg_catalog.jsonb_build_object(
          v_key,
          public.redact_account_audit_details_v1(
            v_item,
            p_subject_user_id,
            p_pseudonym,
            p_direct_values
          )
        );
      end if;
    end loop;
    return v_result;
  end if;

  if v_kind = 'array' then
    select coalesce(
      pg_catalog.jsonb_agg(
        public.redact_account_audit_details_v1(
          element.value,
          p_subject_user_id,
          p_pseudonym,
          p_direct_values
        ) order by element.ordinality
      ),
      '[]'::jsonb
    )
    into v_result
    from pg_catalog.jsonb_array_elements(p_value)
      with ordinality as element(value, ordinality);
    return v_result;
  end if;

  if v_kind = 'string' then
    v_scalar := p_value #>> '{}';
    if v_scalar = p_subject_user_id::text then
      return pg_catalog.to_jsonb(p_pseudonym);
    end if;
    if v_scalar <> '' and v_scalar = any (coalesce(p_direct_values, '{}'::text[])) then
      return '"[redacted]"'::jsonb;
    end if;
  end if;

  return p_value;
end;
$function$;

alter function public.redact_account_audit_details_v1(jsonb, uuid, text, text[])
  owner to postgres;

revoke all on function public.redact_account_audit_details_v1(jsonb, uuid, text, text[])
  from public, anon, authenticated, service_role;

create function public.export_my_data_v1()
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public, pg_temp
as $function$
declare
  v_user_id uuid := auth.uid();
  v_account jsonb;
  v_profile jsonb;
  v_reservations jsonb;
  v_registrations jsonb;
begin
  if v_user_id is null then
    raise exception 'Authentication is required.' using errcode = '42501';
  end if;

  select pg_catalog.jsonb_build_object(
    'id', auth_user.id,
    'email', auth_user.email,
    'phone', auth_user.phone,
    'created_at', auth_user.created_at,
    'accepted_terms', case
      when pg_catalog.lower(auth_user.raw_user_meta_data->>'accepted_terms') in ('true', 'false')
        then (auth_user.raw_user_meta_data->>'accepted_terms')::boolean
      else false
    end,
    'accepted_terms_at', auth_user.raw_user_meta_data->>'accepted_terms_at',
    'accepted_privacy', case
      when pg_catalog.lower(auth_user.raw_user_meta_data->>'accepted_privacy') in ('true', 'false')
        then (auth_user.raw_user_meta_data->>'accepted_privacy')::boolean
      else false
    end,
    'accepted_privacy_at', auth_user.raw_user_meta_data->>'accepted_privacy_at'
  )
  into v_account
  from auth.users as auth_user
  where auth_user.id = v_user_id;

  if not found then
    raise exception 'Authenticated account is unavailable.' using errcode = '42501';
  end if;

  select pg_catalog.jsonb_build_object(
    'id', profile.id,
    'first_name', profile.first_name,
    'last_name', profile.last_name,
    'full_name', profile.full_name,
    'email', profile.email,
    'phone', profile.phone,
    'postal_code', profile.postal_code,
    'city', profile.city,
    'street', profile.street,
    'house_number', profile.house_number,
    'apartment_number', profile.apartment_number,
    'weapon_permit_number', profile.weapon_permit_number,
    'weapon_permit_type', profile.weapon_permit_type,
    'weapon_permit_issuer', profile.weapon_permit_issuer,
    'has_range_officer', profile.has_range_officer,
    'range_officer_number', profile.range_officer_number,
    'has_instructor', profile.has_instructor,
    'instructor_number', profile.instructor_number,
    'permission_sport', profile.permission_sport,
    'permission_collector', profile.permission_collector,
    'permission_hunting', profile.permission_hunting,
    'permission_training', profile.permission_training,
    'permission_personal_protection', profile.permission_personal_protection,
    'permission_other', profile.permission_other,
    'qualification_instructor', profile.qualification_instructor,
    'qualification_range_officer', profile.qualification_range_officer,
    'qualification_pzss_license', profile.qualification_pzss_license,
    'qualification_hunter', profile.qualification_hunter,
    'verification_status', profile.verification_status,
    'permissions_verified', profile.permissions_verified,
    'permissions_verified_at', profile.permissions_verified_at,
    'created_at', profile.created_at,
    'updated_at', profile.updated_at
  )
  into v_profile
  from public.profiles as profile
  where profile.user_id = v_user_id;

  select coalesce(pg_catalog.jsonb_agg(row_data.value order by row_data.created_at, row_data.id), '[]'::jsonb)
  into v_reservations
  from (
    select reservation.created_at, reservation.id,
      pg_catalog.jsonb_build_object(
        'id', reservation.id,
        'lane_id', reservation.lane_id,
        'reservation_date', reservation.reservation_date,
        'start_time', reservation.start_time,
        'end_time', reservation.end_time,
        'duration_minutes', reservation.duration_minutes,
        'shooters_count', reservation.shooters_count,
        'reservation_status', reservation.reservation_status,
        'attendance_status', reservation.attendance_status,
        'payment_status', reservation.payment_status,
        'checked_in_at', reservation.checked_in_at,
        'completed_at', reservation.completed_at,
        'lane_name', reservation.lane_name_snapshot,
        'pricing_day_group', reservation.pricing_day_group_snapshot,
        'pricing_label', reservation.pricing_label_snapshot,
        'price_per_hour', reservation.price_per_hour_snapshot,
        'total_price', reservation.total_price,
        'currency_code', reservation.currency_code,
        'reservation_note', reservation.reservation_note,
        'created_at', reservation.created_at
      ) as value
    from public.reservations as reservation
    where reservation.user_id = v_user_id
  ) as row_data;

  select coalesce(pg_catalog.jsonb_agg(row_data.value order by row_data.created_at, row_data.id), '[]'::jsonb)
  into v_registrations
  from (
    select registration.created_at, registration.id,
      pg_catalog.jsonb_build_object(
        'id', registration.id,
        'event_id', registration.event_id,
        'registration_status', registration.registration_status,
        'payment_status', registration.payment_status,
        'promotion_email_sent_at', registration.promotion_email_sent_at,
        'promotion_confirmed_at', registration.promotion_confirmed_at,
        'created_at', registration.created_at
      ) as value
    from public.event_registrations as registration
    where registration.user_id = v_user_id
  ) as row_data;

  return pg_catalog.jsonb_build_object(
    'export_version', 1,
    'generated_at', pg_catalog.transaction_timestamp(),
    'account', v_account,
    'profile', v_profile,
    'reservations', v_reservations,
    'event_registrations', v_registrations
  );
end;
$function$;

alter function public.export_my_data_v1() owner to postgres;
revoke all on function public.export_my_data_v1()
  from public, anon, authenticated, service_role;
grant execute on function public.export_my_data_v1() to authenticated;

comment on function public.export_my_data_v1() is
  'Returns a versioned allowlisted export for auth.uid(); excludes notes, tokens, audit and security internals.';

create function public.anonymize_my_account_v1()
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, public, pg_temp
as $function$
declare
  v_user_id uuid := auth.uid();
  v_now timestamp with time zone := pg_catalog.transaction_timestamp();
  v_pseudonym_hash text;
  v_pseudonym_id uuid;
  v_pseudonym text;
  v_pseudonym_email text;
  v_profile public.profiles%rowtype;
  v_direct_values text[] := '{}'::text[];
  v_reservation_ids uuid[] := '{}'::uuid[];
  v_registration_ids uuid[] := '{}'::uuid[];
  v_reservation_count integer := 0;
  v_registration_count integer := 0;
  v_delivery_count integer := 0;
  v_rate_limit_count integer := 0;
  v_audit_count integer := 0;
begin
  if v_user_id is null then
    raise exception 'Authentication is required.' using errcode = '42501';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(v_user_id::text, 0)
  );

  v_pseudonym_hash := pg_catalog.md5(v_user_id::text || ':csk-sec009-v1');
  v_pseudonym_id := (
    pg_catalog.substr(v_pseudonym_hash, 1, 8) || '-' ||
    pg_catalog.substr(v_pseudonym_hash, 9, 4) || '-' ||
    pg_catalog.substr(v_pseudonym_hash, 13, 4) || '-' ||
    pg_catalog.substr(v_pseudonym_hash, 17, 4) || '-' ||
    pg_catalog.substr(v_pseudonym_hash, 21, 12)
  )::uuid;
  v_pseudonym := 'deleted-user-' || pg_catalog.substr(v_pseudonym_hash, 1, 16);
  v_pseudonym_email := v_pseudonym || '@invalid.local';

  select pg_catalog.count(*)
  into v_audit_count
  from public.audit_logs as audit
  where audit.action = 'account_anonymized'
    and audit.actor_user_id = v_pseudonym_id
    and audit.target_type = 'account'
    and audit.target_id = v_pseudonym_id;

  if v_audit_count > 1 then
    raise exception 'Account lifecycle state is ambiguous.' using errcode = 'P0001';
  end if;

  if v_audit_count = 1 then
    return pg_catalog.jsonb_build_object(
      'ok', true,
      'changed', false,
      'code', 'already_anonymized'
    );
  end if;

  select profile.*
  into v_profile
  from public.profiles as profile
  where profile.user_id = v_user_id
  for update;

  select coalesce(pg_catalog.array_agg(reservation.id order by reservation.id), '{}'::uuid[])
  into v_reservation_ids
  from public.reservations as reservation
  where reservation.user_id = v_user_id;

  select coalesce(pg_catalog.array_agg(registration.id order by registration.id), '{}'::uuid[])
  into v_registration_ids
  from public.event_registrations as registration
  where registration.user_id = v_user_id;

  select coalesce(pg_catalog.array_agg(distinct source.value) filter (
    where source.value is not null and source.value <> ''
  ), '{}'::text[])
  into v_direct_values
  from (
    select value
    from pg_catalog.unnest(array[
      v_profile.id::text,
      v_profile.first_name, v_profile.last_name, v_profile.full_name,
      v_profile.email, v_profile.phone, v_profile.postal_code, v_profile.city,
      v_profile.street, v_profile.house_number, v_profile.apartment_number,
      v_profile.weapon_permit_number, v_profile.weapon_permit_type,
      v_profile.weapon_permit_issuer, v_profile.range_officer_number,
      v_profile.instructor_number, v_profile.admin_note, v_profile.verification_note,
      v_profile.permissions_verification_note
    ]::text[]) as value
    union all
    select reservation.customer_name from public.reservations as reservation where reservation.user_id = v_user_id
    union all
    select reservation.customer_email from public.reservations as reservation where reservation.user_id = v_user_id
    union all
    select reservation.customer_phone from public.reservations as reservation where reservation.user_id = v_user_id
    union all
    select reservation.reservation_note from public.reservations as reservation where reservation.user_id = v_user_id
    union all
    select reservation.admin_note from public.reservations as reservation where reservation.user_id = v_user_id
    union all
    select registration.customer_name from public.event_registrations as registration where registration.user_id = v_user_id
    union all
    select registration.customer_email from public.event_registrations as registration where registration.user_id = v_user_id
    union all
    select registration.customer_phone from public.event_registrations as registration where registration.user_id = v_user_id
  ) as source;

  update public.reservations as reservation
  set user_id = null,
      customer_name = v_pseudonym,
      customer_email = v_pseudonym_email,
      customer_phone = '[redacted]',
      admin_note = null,
      reservation_note = null,
      check_in_token = null,
      pii_anonymized_at = v_now
  where reservation.user_id = v_user_id;
  get diagnostics v_reservation_count = row_count;

  update public.event_registrations as registration
  set user_id = null,
      customer_name = v_pseudonym,
      customer_email = v_pseudonym_email,
      customer_phone = '[redacted]',
      promotion_token = null,
      promotion_token_expires_at = null,
      promotion_claim_id = null,
      promotion_claim_expires_at = null,
      promotion_attempt_count = 0,
      promotion_last_attempt_at = null,
      promotion_last_error_code = null,
      pii_anonymized_at = v_now
  where registration.user_id = v_user_id;
  get diagnostics v_registration_count = row_count;

  update public.audit_logs as audit
  set actor_user_id = case
        when audit.actor_user_id = v_user_id then v_pseudonym_id
        else audit.actor_user_id
      end,
      actor_name = case
        when audit.actor_user_id = v_user_id then v_pseudonym
        else audit.actor_name
      end,
      target_id = case
        when audit.target_type in ('profile', 'account')
          and audit.target_id = v_user_id then v_pseudonym_id
        else audit.target_id
      end,
      target_name = case
        when audit.target_type in ('profile', 'account')
          and audit.target_id = v_user_id then v_pseudonym
        else audit.target_name
      end,
      details = public.redact_account_audit_details_v1(
        audit.details,
        v_user_id,
        v_pseudonym,
        v_direct_values
      )
  where audit.actor_user_id = v_user_id
     or (audit.target_type = 'profile' and audit.target_id = v_user_id)
     or audit.target_id = any (v_reservation_ids)
     or audit.target_id = any (v_registration_ids);

  delete from public.email_deliveries as delivery
  where delivery.recipient_user_id = v_user_id;
  get diagnostics v_delivery_count = row_count;

  delete from public.confirmation_email_rate_limits as rate_limit
  where rate_limit.scope_type = 'user'
    and rate_limit.scope_key = v_user_id::text;
  get diagnostics v_rate_limit_count = row_count;

  delete from public.profiles as profile
  where profile.user_id = v_user_id;

  insert into public.audit_logs (
    actor_user_id,
    actor_name,
    actor_role,
    action,
    target_type,
    target_id,
    target_name,
    details
  ) values (
    v_pseudonym_id,
    v_pseudonym,
    'user',
    'account_anonymized',
    'account',
    v_pseudonym_id,
    v_pseudonym,
    pg_catalog.jsonb_build_object(
      'anonymization_version', 1,
      'reservation_count', v_reservation_count,
      'event_registration_count', v_registration_count,
      'email_delivery_count', v_delivery_count,
      'user_rate_limit_count', v_rate_limit_count,
      'anonymized_at', v_now
    )
  );

  return pg_catalog.jsonb_build_object(
    'ok', true,
    'changed', true,
    'code', 'anonymized',
    'reservation_count', v_reservation_count,
    'event_registration_count', v_registration_count
  );
end;
$function$;

alter function public.anonymize_my_account_v1() owner to postgres;
revoke all on function public.anonymize_my_account_v1()
  from public, anon, authenticated, service_role;
grant execute on function public.anonymize_my_account_v1() to authenticated;

comment on function public.anonymize_my_account_v1() is
  'Atomically removes auth.uid() PII from business records, preserves operational history, and records one pseudonymous audit.';

do $postflight$
declare
  v_export_oid oid := pg_catalog.to_regprocedure('public.export_my_data_v1()');
  v_anonymize_oid oid := pg_catalog.to_regprocedure('public.anonymize_my_account_v1()');
  v_redact_oid oid := pg_catalog.to_regprocedure(
    'public.redact_account_audit_details_v1(jsonb,uuid,text,text[])'
  );
begin
  if v_export_oid is null or v_anonymize_oid is null or v_redact_oid is null then
    raise exception 'SEC-009 postflight failed: lifecycle function is missing.';
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_proc as procedure
    join pg_catalog.pg_roles as owner_role on owner_role.oid = procedure.proowner
    where procedure.oid = v_export_oid
      and procedure.prosecdef
      and procedure.provolatile = 's'
      and procedure.prorettype = 'jsonb'::pg_catalog.regtype
      and procedure.proconfig = array['search_path=pg_catalog, public, pg_temp']::text[]
      and owner_role.rolname = 'postgres'
  ) or not exists (
    select 1
    from pg_catalog.pg_proc as procedure
    join pg_catalog.pg_roles as owner_role on owner_role.oid = procedure.proowner
    where procedure.oid = v_anonymize_oid
      and procedure.prosecdef
      and procedure.provolatile = 'v'
      and procedure.prorettype = 'jsonb'::pg_catalog.regtype
      and procedure.proconfig = array['search_path=pg_catalog, public, pg_temp']::text[]
      and owner_role.rolname = 'postgres'
  ) then
    raise exception 'SEC-009 postflight failed: lifecycle function security properties differ.';
  end if;

  if not pg_catalog.has_function_privilege('authenticated', v_export_oid, 'EXECUTE')
     or not pg_catalog.has_function_privilege('authenticated', v_anonymize_oid, 'EXECUTE')
     or pg_catalog.has_function_privilege('anon', v_export_oid, 'EXECUTE')
     or pg_catalog.has_function_privilege('anon', v_anonymize_oid, 'EXECUTE')
     or pg_catalog.has_function_privilege('service_role', v_export_oid, 'EXECUTE')
     or pg_catalog.has_function_privilege('service_role', v_anonymize_oid, 'EXECUTE')
     or pg_catalog.has_function_privilege('authenticated', v_redact_oid, 'EXECUTE')
     or exists (
       select 1
       from pg_catalog.pg_proc as procedure
       cross join lateral pg_catalog.aclexplode(
         coalesce(procedure.proacl, pg_catalog.acldefault('f', procedure.proowner))
       ) as acl
       where procedure.oid in (v_export_oid, v_anonymize_oid, v_redact_oid)
         and acl.grantee = 0
         and acl.privilege_type = 'EXECUTE'
     ) then
    raise exception 'SEC-009 postflight failed: lifecycle function ACL differs.';
  end if;

  if exists (
    select 1
    from pg_catalog.pg_attribute as attribute
    where attribute.attrelid = 'public.reservations'::pg_catalog.regclass
      and attribute.attname in ('user_id', 'check_in_token')
      and attribute.attnotnull
      and not attribute.attisdropped
  ) then
    raise exception 'SEC-009 postflight failed: anonymizable reservation fields remain NOT NULL.';
  end if;

  if pg_catalog.has_table_privilege(
       'authenticated', 'public.audit_logs',
       'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN'
     ) then
    raise exception 'SEC-009 postflight failed: SEC-007 audit ACL changed.';
  end if;
end;
$postflight$;
