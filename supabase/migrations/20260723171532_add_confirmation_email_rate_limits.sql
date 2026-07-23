-- Add a durable sliding-window limiter for confirmation-email endpoints.
-- Scope keys contain only a user UUID or an HMAC-SHA256 IP digest.

create table public.confirmation_email_rate_limits (
  scope_type text not null,
  scope_key text not null,
  request_timestamps timestamptz[] not null
    default '{}'::timestamptz[],
  updated_at timestamptz not null
    default pg_catalog.transaction_timestamp(),
  constraint confirmation_email_rate_limits_pkey
    primary key (scope_type, scope_key),
  constraint confirmation_email_rate_limits_scope_type_check
    check (scope_type in ('user', 'ip')),
  constraint confirmation_email_rate_limits_scope_key_check
    check (
      (
        scope_type = 'user'
        and scope_key ~
          '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      )
      or
      (
        scope_type = 'ip'
        and scope_key ~ '^[0-9a-f]{64}$'
      )
    )
);

comment on table public.confirmation_email_rate_limits is
  'Active sliding-window timestamps for confirmation email user and HMAC IP scopes.';

comment on column public.confirmation_email_rate_limits.scope_key is
  'User UUID or lowercase HMAC-SHA256 IP digest; never a raw IP address.';

alter table public.confirmation_email_rate_limits enable row level security;

revoke all on table public.confirmation_email_rate_limits from public;
revoke all on table public.confirmation_email_rate_limits from anon;
revoke all on table public.confirmation_email_rate_limits from authenticated;
revoke all on table public.confirmation_email_rate_limits from service_role;

create or replace function public.check_confirmation_email_rate_limit(
  p_user_id uuid,
  p_ip_hash text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_now timestamptz := pg_catalog.transaction_timestamp();
  v_window_start timestamptz := v_now - interval '10 minutes';
  v_user_key text;
  v_ip_hash text := pg_catalog.lower(pg_catalog.btrim(p_ip_hash));
  v_user_timestamps timestamptz[];
  v_ip_timestamps timestamptz[];
  v_user_retry integer := 0;
  v_ip_retry integer := 0;
  v_retry_after integer;
begin
  if p_user_id is null
     or v_ip_hash is null
     or v_ip_hash !~ '^[0-9a-f]{64}$' then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'code', 'invalid_input',
      'allowed', false
    );
  end if;

  v_user_key := p_user_id::text;

  insert into public.confirmation_email_rate_limits (
    scope_type,
    scope_key
  )
  values ('ip', v_ip_hash)
  on conflict (scope_type, scope_key) do nothing;

  insert into public.confirmation_email_rate_limits (
    scope_type,
    scope_key
  )
  values ('user', v_user_key)
  on conflict (scope_type, scope_key) do nothing;

  perform 1
  from public.confirmation_email_rate_limits as rate_limit
  where (rate_limit.scope_type, rate_limit.scope_key) in (
    ('ip', v_ip_hash),
    ('user', v_user_key)
  )
  order by rate_limit.scope_type, rate_limit.scope_key
  for update;

  select
    rate_limit.request_timestamps
  into v_user_timestamps
  from public.confirmation_email_rate_limits as rate_limit
  where rate_limit.scope_type = 'user'
    and rate_limit.scope_key = v_user_key;

  select
    rate_limit.request_timestamps
  into v_ip_timestamps
  from public.confirmation_email_rate_limits as rate_limit
  where rate_limit.scope_type = 'ip'
    and rate_limit.scope_key = v_ip_hash;

  v_user_timestamps := array(
    select timestamp_value
    from pg_catalog.unnest(
      coalesce(
        v_user_timestamps,
        '{}'::timestamptz[]
      )
    ) as timestamp_record(timestamp_value)
    where timestamp_value > v_window_start
    order by timestamp_value
  );

  v_ip_timestamps := array(
    select timestamp_value
    from pg_catalog.unnest(
      coalesce(
        v_ip_timestamps,
        '{}'::timestamptz[]
      )
    ) as timestamp_record(timestamp_value)
    where timestamp_value > v_window_start
    order by timestamp_value
  );

  update public.confirmation_email_rate_limits as rate_limit
  set
    request_timestamps = case rate_limit.scope_type
      when 'user' then v_user_timestamps
      else v_ip_timestamps
    end,
    updated_at = v_now
  where (rate_limit.scope_type, rate_limit.scope_key) in (
    ('ip', v_ip_hash),
    ('user', v_user_key)
  );

  if pg_catalog.cardinality(v_user_timestamps) >= 10 then
    v_user_retry := pg_catalog.ceil(
      extract(
        epoch from (
          v_user_timestamps[
            pg_catalog.cardinality(v_user_timestamps) - 10 + 1
          ] + interval '10 minutes' - v_now
        )
      )
    )::integer;
  end if;

  if pg_catalog.cardinality(v_ip_timestamps) >= 30 then
    v_ip_retry := pg_catalog.ceil(
      extract(
        epoch from (
          v_ip_timestamps[
            pg_catalog.cardinality(v_ip_timestamps) - 30 + 1
          ] + interval '10 minutes' - v_now
        )
      )
    )::integer;
  end if;

  if v_user_retry > 0 or v_ip_retry > 0 then
    v_retry_after := least(
      600,
      greatest(1, v_user_retry, v_ip_retry)
    );

    return pg_catalog.jsonb_build_object(
      'ok', true,
      'code', 'rate_limited',
      'allowed', false,
      'retry_after_seconds', v_retry_after
    );
  end if;

  update public.confirmation_email_rate_limits as rate_limit
  set
    request_timestamps = case rate_limit.scope_type
      when 'user' then
        pg_catalog.array_append(v_user_timestamps, v_now)
      else
        pg_catalog.array_append(v_ip_timestamps, v_now)
    end,
    updated_at = v_now
  where (rate_limit.scope_type, rate_limit.scope_key) in (
    ('ip', v_ip_hash),
    ('user', v_user_key)
  );

  return pg_catalog.jsonb_build_object(
    'ok', true,
    'code', 'allowed',
    'allowed', true
  );
end;
$function$;

alter function public.check_confirmation_email_rate_limit(uuid, text)
  owner to postgres;

comment on function public.check_confirmation_email_rate_limit(uuid, text) is
  'Atomically enforces 10 user and 30 HMAC IP requests per sliding 10-minute window.';

revoke all on function public.check_confirmation_email_rate_limit(uuid, text)
  from public;
revoke all on function public.check_confirmation_email_rate_limit(uuid, text)
  from anon;
revoke all on function public.check_confirmation_email_rate_limit(uuid, text)
  from authenticated;
revoke all on function public.check_confirmation_email_rate_limit(uuid, text)
  from service_role;
grant execute on function public.check_confirmation_email_rate_limit(uuid, text)
  to service_role;
