-- SAAS-9D-2C-1: tenant-bind shared confirmation-email delivery claims.

do $preflight$
declare
  v_other_definer_fingerprint text;
begin
  if pg_catalog.to_regprocedure('public.prepare_confirmation_email(text,uuid)') is null
     or pg_catalog.to_regprocedure('public.complete_confirmation_email(uuid,boolean,text,text)') is null
     or pg_catalog.to_regprocedure('public.check_confirmation_email_rate_limit(uuid,text)') is null
     or pg_catalog.to_regprocedure('public.is_tenant_member_v1(uuid)') is null
     or pg_catalog.to_regprocedure('public.has_tenant_role_v1(uuid,text[])') is null then
    raise exception 'SAAS-9D-2C-1 preflight failed: required function is missing.';
  end if;

  if (select pg_catalog.count(*) from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public'
        and p.proname in ('prepare_confirmation_email','complete_confirmation_email','check_confirmation_email_rate_limit'))<>3 then
    raise exception 'SAAS-9D-2C-1 preflight failed: shared RPC overload inventory drift.';
  end if;

  if pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef(
       'public.prepare_confirmation_email(text,uuid)'::pg_catalog.regprocedure),E'\r\n',E'\n'),E'\r',E'\n'))
       <> '449dbd830a7ece7f0c5b8b046dc1ee2c'
     or pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef(
       'public.complete_confirmation_email(uuid,boolean,text,text)'::pg_catalog.regprocedure),E'\r\n',E'\n'),E'\r',E'\n'))
       <> '8ca5430a2d7e625d10ebc61617a03dd5'
     or pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef(
       'public.check_confirmation_email_rate_limit(uuid,text)'::pg_catalog.regprocedure),E'\r\n',E'\n'),E'\r',E'\n'))
       <> 'e693411c3fc7f24510313e60a1d8e2a5' then
    raise exception 'SAAS-9D-2C-1 preflight failed: normalized function fingerprint drift.';
  end if;

  if not exists(select 1 from pg_catalog.pg_proc p join pg_catalog.pg_roles r on r.oid=p.proowner
      where p.oid='public.prepare_confirmation_email(text,uuid)'::pg_catalog.regprocedure
        and p.prosecdef and p.provolatile='v' and r.rolname='postgres'
        and p.proconfig=array['search_path=public, pg_temp']::text[])
     or not exists(select 1 from pg_catalog.pg_proc p join pg_catalog.pg_roles r on r.oid=p.proowner
      where p.oid='public.complete_confirmation_email(uuid,boolean,text,text)'::pg_catalog.regprocedure
        and p.prosecdef and p.provolatile='v' and r.rolname='postgres'
        and p.proconfig=array['search_path=public, pg_temp']::text[])
     or not exists(select 1 from pg_catalog.pg_proc p join pg_catalog.pg_roles r on r.oid=p.proowner
      where p.oid='public.check_confirmation_email_rate_limit(uuid,text)'::pg_catalog.regprocedure
        and p.prosecdef and p.provolatile='v' and r.rolname='postgres'
        and p.proconfig=array['search_path=public, pg_temp']::text[]) then
    raise exception 'SAAS-9D-2C-1 preflight failed: function metadata drift.';
  end if;

  if not pg_catalog.has_function_privilege('authenticated','public.prepare_confirmation_email(text,uuid)','EXECUTE')
     or pg_catalog.has_function_privilege('public','public.prepare_confirmation_email(text,uuid)','EXECUTE')
     or pg_catalog.has_function_privilege('anon','public.prepare_confirmation_email(text,uuid)','EXECUTE')
     or pg_catalog.has_function_privilege('service_role','public.prepare_confirmation_email(text,uuid)','EXECUTE')
     or not pg_catalog.has_function_privilege('service_role','public.complete_confirmation_email(uuid,boolean,text,text)','EXECUTE')
     or pg_catalog.has_function_privilege('public','public.complete_confirmation_email(uuid,boolean,text,text)','EXECUTE')
     or pg_catalog.has_function_privilege('anon','public.complete_confirmation_email(uuid,boolean,text,text)','EXECUTE')
     or pg_catalog.has_function_privilege('authenticated','public.complete_confirmation_email(uuid,boolean,text,text)','EXECUTE')
     or not pg_catalog.has_function_privilege('service_role','public.check_confirmation_email_rate_limit(uuid,text)','EXECUTE')
     or pg_catalog.has_function_privilege('public','public.check_confirmation_email_rate_limit(uuid,text)','EXECUTE')
     or pg_catalog.has_function_privilege('anon','public.check_confirmation_email_rate_limit(uuid,text)','EXECUTE')
     or pg_catalog.has_function_privilege('authenticated','public.check_confirmation_email_rate_limit(uuid,text)','EXECUTE') then
    raise exception 'SAAS-9D-2C-1 preflight failed: shared RPC ACL drift.';
  end if;

  if not pg_catalog.has_table_privilege('service_role','public.email_deliveries','SELECT,UPDATE')
     or not pg_catalog.has_table_privilege('service_role','public.reservations','SELECT')
     or not pg_catalog.has_table_privilege('service_role','public.event_registrations','SELECT')
     or not pg_catalog.has_table_privilege('service_role','public.events','SELECT') then
    raise exception 'SAAS-9D-2C-1 preflight failed: service invoker table contract differs.';
  end if;

  if exists(select 1 from public.email_deliveries where tenant_id is null)
     or exists(select 1 from public.email_deliveries
       where message_type not in ('event_registration_confirmation','reservation_confirmation','reservation_cancellation'))
     or exists(
       select 1
       from public.email_deliveries delivery
       left join public.reservations reservation
         on delivery.message_type in ('reservation_confirmation','reservation_cancellation')
        and reservation.id=delivery.record_id
       left join public.event_registrations registration
         on delivery.message_type='event_registration_confirmation'
        and registration.id=delivery.record_id
       left join public.events event_record
         on event_record.id=registration.event_id
        and event_record.tenant_id=registration.tenant_id
       where (delivery.message_type in ('reservation_confirmation','reservation_cancellation')
              and (reservation.id is null
                   or delivery.tenant_id is distinct from reservation.tenant_id
                   or delivery.recipient_user_id is distinct from reservation.user_id))
          or (delivery.message_type='event_registration_confirmation'
              and (registration.id is null or event_record.id is null
                   or delivery.tenant_id is distinct from registration.tenant_id
                   or delivery.recipient_user_id is distinct from registration.user_id))
     ) then
    raise exception 'SAAS-9D-2C-1 preflight failed: delivery tenant/resource binding is invalid.';
  end if;

  if (select pg_catalog.count(*) from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.prosecdef)<>73 then
    raise exception 'SAAS-9D-2C-1 preflight failed: SECURITY DEFINER inventory drift.';
  end if;

  select pg_catalog.md5(coalesce(pg_catalog.string_agg(
    p.oid::pg_catalog.regprocedure::text||':'||pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(
      pg_catalog.pg_get_functiondef(p.oid),E'\r\n',E'\n'),E'\r',E'\n')),E'\n' order by p.oid::pg_catalog.regprocedure::text),''))
  into v_other_definer_fingerprint
  from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.prosecdef
    and p.proname not in ('prepare_confirmation_email','complete_confirmation_email');

  create temporary table saas9d2c1_preflight_snapshot(
    other_definer_fingerprint text not null,
    rate_limit_fingerprint text not null
  ) on commit drop;
  insert into saas9d2c1_preflight_snapshot values(
    v_other_definer_fingerprint,
    'e693411c3fc7f24510313e60a1d8e2a5'
  );
end;
$preflight$;

create or replace function public.prepare_confirmation_email(
  p_message_type text,
  p_record_id uuid
) returns jsonb
language plpgsql
security definer
set search_path=pg_catalog, public, pg_temp
as $function$
declare
  v_actor_user_id uuid:=auth.uid();
  v_message_type text:=pg_catalog.lower(pg_catalog.btrim(p_message_type));
  v_now timestamptz:=pg_catalog.transaction_timestamp();
  v_source_user_id uuid;
  v_source_status text;
  v_tenant_id uuid;
  v_delivery public.email_deliveries%rowtype;
  v_attempt_count integer;
  v_attempt_window_started_at timestamptz;
  v_claim_id uuid;
begin
  if v_actor_user_id is null then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','unauthorized');
  end if;

  if p_record_id is null or v_message_type is null
     or v_message_type not in ('event_registration_confirmation','reservation_confirmation','reservation_cancellation') then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','invalid_status');
  end if;

  if v_message_type='event_registration_confirmation' then
    select registration.user_id,
           pg_catalog.lower(pg_catalog.btrim(registration.registration_status)),
           registration.tenant_id
    into v_source_user_id,v_source_status,v_tenant_id
    from public.event_registrations registration
    join public.events event_record
      on event_record.id=registration.event_id
     and event_record.tenant_id=registration.tenant_id
    where registration.id=p_record_id
      and registration.user_id=v_actor_user_id
    for update of registration;

    if not found or not public.is_tenant_member_v1(v_tenant_id) then
      return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','not_found');
    end if;
    if v_source_status not in ('registered','reserve') then
      return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','invalid_status');
    end if;
  elsif v_message_type='reservation_confirmation' then
    select reservation.user_id,
           pg_catalog.lower(pg_catalog.btrim(reservation.reservation_status)),
           reservation.tenant_id
    into v_source_user_id,v_source_status,v_tenant_id
    from public.reservations reservation
    where reservation.id=p_record_id and reservation.user_id=v_actor_user_id
    for update;

    if not found or not public.is_tenant_member_v1(v_tenant_id) then
      return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','not_found');
    end if;
    if v_source_status<>'confirmed' then
      return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','invalid_status');
    end if;
  else
    select reservation.user_id,
           pg_catalog.lower(pg_catalog.btrim(reservation.reservation_status)),
           reservation.tenant_id
    into v_source_user_id,v_source_status,v_tenant_id
    from public.reservations reservation
    where reservation.id=p_record_id
    for update;

    if not found then
      return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','not_found');
    end if;
    if v_source_user_id is distinct from v_actor_user_id then
      if not public.has_tenant_role_v1(v_tenant_id,array['admin','employee']::text[]) then
        return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','not_found');
      end if;
    elsif not public.is_tenant_member_v1(v_tenant_id) then
      return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','not_found');
    end if;
    if v_source_status not in ('cancelled','canceled','cancelled_by_admin','cancelled_by_user') then
      return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','invalid_status');
    end if;
  end if;

  insert into public.email_deliveries(tenant_id,message_type,record_id,recipient_user_id)
  values(v_tenant_id,v_message_type,p_record_id,v_source_user_id)
  on conflict(message_type,record_id) do nothing;

  select delivery.* into v_delivery
  from public.email_deliveries delivery
  where delivery.message_type=v_message_type and delivery.record_id=p_record_id
  for update;

  if not found
     or v_delivery.tenant_id is distinct from v_tenant_id
     or v_delivery.recipient_user_id is distinct from v_source_user_id then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','not_found');
  end if;
  if v_delivery.sent_at is not null then
    return pg_catalog.jsonb_build_object('ok',true,'changed',false,'code','already_sent');
  end if;
  if v_delivery.claim_id is not null and v_delivery.claim_expires_at>v_now then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','in_progress');
  end if;

  v_attempt_count:=v_delivery.attempt_count;
  v_attempt_window_started_at:=v_delivery.attempt_window_started_at;
  if v_attempt_window_started_at is null or v_attempt_window_started_at<=v_now-interval '24 hours' then
    v_attempt_count:=0;
    v_attempt_window_started_at:=v_now;
  end if;
  if v_attempt_count>=3 then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','attempt_limit_reached');
  end if;

  v_claim_id:=pg_catalog.gen_random_uuid();
  v_attempt_count:=v_attempt_count+1;
  update public.email_deliveries delivery
  set claim_id=v_claim_id,
      claim_expires_at=v_now+interval '5 minutes',
      attempt_count=v_attempt_count,
      attempt_window_started_at=v_attempt_window_started_at,
      last_attempt_at=v_now,
      last_error_code=null,
      updated_at=v_now
  where delivery.id=v_delivery.id;

  return pg_catalog.jsonb_build_object(
    'ok',true,'changed',true,'code','ready','delivery_id',v_delivery.id,
    'claim_id',v_claim_id,'claim_expires_at',v_now+interval '5 minutes',
    'attempt_count',v_attempt_count,
    'idempotency_key','confirmation/'||v_message_type||'/'||v_delivery.id::text
  );
end;
$function$;

alter function public.prepare_confirmation_email(text,uuid) owner to postgres;
revoke all on function public.prepare_confirmation_email(text,uuid)
  from public,anon,authenticated,service_role;
grant execute on function public.prepare_confirmation_email(text,uuid) to authenticated;

comment on function public.prepare_confirmation_email(text,uuid) is
  'Tenant-binds an authorized owner or staff request and atomically leases one bounded confirmation-email attempt.';

create or replace function public.complete_confirmation_email(
  p_claim_id uuid,
  p_success boolean,
  p_provider_message_id text default null,
  p_error_code text default null
) returns jsonb
language plpgsql
security invoker
set search_path=pg_catalog, public, pg_temp
as $function$
declare
  v_now timestamptz:=pg_catalog.transaction_timestamp();
  v_delivery public.email_deliveries%rowtype;
  v_source_user_id uuid;
  v_source_tenant_id uuid;
  v_provider_message_id text;
  v_error_code text;
begin
  if p_claim_id is null then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','claim_not_found');
  end if;

  select delivery.* into v_delivery
  from public.email_deliveries delivery
  where delivery.claim_id=p_claim_id
  for update;
  if not found then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','claim_not_found');
  end if;

  if v_delivery.message_type='event_registration_confirmation' then
    select registration.user_id,registration.tenant_id
    into v_source_user_id,v_source_tenant_id
    from public.event_registrations registration
    join public.events event_record
      on event_record.id=registration.event_id
     and event_record.tenant_id=registration.tenant_id
    where registration.id=v_delivery.record_id;
  elsif v_delivery.message_type in ('reservation_confirmation','reservation_cancellation') then
    select reservation.user_id,reservation.tenant_id
    into v_source_user_id,v_source_tenant_id
    from public.reservations reservation
    where reservation.id=v_delivery.record_id;
  else
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','claim_not_found');
  end if;

  if not found
     or v_delivery.tenant_id is distinct from v_source_tenant_id
     or v_delivery.recipient_user_id is distinct from v_source_user_id then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','claim_not_found');
  end if;

  if v_delivery.sent_at is not null then
    update public.email_deliveries delivery
    set claim_id=null,claim_expires_at=null,updated_at=v_now
    where delivery.id=v_delivery.id and delivery.claim_id=p_claim_id;
    return pg_catalog.jsonb_build_object('ok',true,'changed',false,'code','sent');
  end if;

  if p_success is true then
    v_provider_message_id:=nullif(pg_catalog.left(pg_catalog.btrim(p_provider_message_id),256),'');
    update public.email_deliveries delivery
    set sent_at=coalesce(delivery.sent_at,v_now),
        provider_message_id=coalesce(delivery.provider_message_id,v_provider_message_id),
        claim_id=null,claim_expires_at=null,last_error_code=null,updated_at=v_now
    where delivery.id=v_delivery.id and delivery.claim_id=p_claim_id;
    if not found then
      return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','claim_not_found');
    end if;
    return pg_catalog.jsonb_build_object('ok',true,'changed',true,'code','sent');
  end if;

  v_error_code:=pg_catalog.lower(pg_catalog.btrim(p_error_code));
  v_error_code:=pg_catalog.regexp_replace(coalesce(v_error_code,'delivery_failed'),'[^a-z0-9_.:-]+','_','g');
  v_error_code:=pg_catalog.left(coalesce(nullif(v_error_code,''),'delivery_failed'),128);
  update public.email_deliveries delivery
  set claim_id=null,claim_expires_at=null,last_error_code=v_error_code,updated_at=v_now
  where delivery.id=v_delivery.id and delivery.claim_id=p_claim_id;
  if not found then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','claim_not_found');
  end if;
  return pg_catalog.jsonb_build_object('ok',true,'changed',true,'code','failed');
end;
$function$;

alter function public.complete_confirmation_email(uuid,boolean,text,text) owner to postgres;
revoke all on function public.complete_confirmation_email(uuid,boolean,text,text)
  from public,anon,authenticated,service_role;
grant execute on function public.complete_confirmation_email(uuid,boolean,text,text) to service_role;

comment on function public.complete_confirmation_email(uuid,boolean,text,text) is
  'As a service-only invoker, completes only a claim whose delivery, typed resource, tenant and recipient remain consistent.';

do $postflight$
declare
  v_other_definer_fingerprint text;
begin
  if not exists(select 1 from pg_catalog.pg_proc p join pg_catalog.pg_roles r on r.oid=p.proowner
      where p.oid='public.prepare_confirmation_email(text,uuid)'::pg_catalog.regprocedure
        and p.prosecdef and p.provolatile='v' and r.rolname='postgres'
        and p.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[])
     or not exists(select 1 from pg_catalog.pg_proc p join pg_catalog.pg_roles r on r.oid=p.proowner
      where p.oid='public.complete_confirmation_email(uuid,boolean,text,text)'::pg_catalog.regprocedure
        and not p.prosecdef and p.provolatile='v' and r.rolname='postgres'
        and p.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[]) then
    raise exception 'SAAS-9D-2C-1 postflight failed: target metadata differs.';
  end if;

  if pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef(
       'public.prepare_confirmation_email(text,uuid)'::pg_catalog.regprocedure),E'\r\n',E'\n'),E'\r',E'\n'))
       <> '17d8b973c9e3df0839f692fd8d9efbde'
     or pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef(
       'public.complete_confirmation_email(uuid,boolean,text,text)'::pg_catalog.regprocedure),E'\r\n',E'\n'),E'\r',E'\n'))
       <> 'c8450fe37a991fda41e8a30ce66732b3' then
    raise exception 'SAAS-9D-2C-1 postflight failed: target fingerprint differs.';
  end if;

  if not pg_catalog.has_function_privilege('authenticated','public.prepare_confirmation_email(text,uuid)','EXECUTE')
     or pg_catalog.has_function_privilege('public','public.prepare_confirmation_email(text,uuid)','EXECUTE')
     or pg_catalog.has_function_privilege('anon','public.prepare_confirmation_email(text,uuid)','EXECUTE')
     or pg_catalog.has_function_privilege('service_role','public.prepare_confirmation_email(text,uuid)','EXECUTE')
     or not pg_catalog.has_function_privilege('service_role','public.complete_confirmation_email(uuid,boolean,text,text)','EXECUTE')
     or pg_catalog.has_function_privilege('public','public.complete_confirmation_email(uuid,boolean,text,text)','EXECUTE')
     or pg_catalog.has_function_privilege('anon','public.complete_confirmation_email(uuid,boolean,text,text)','EXECUTE')
     or pg_catalog.has_function_privilege('authenticated','public.complete_confirmation_email(uuid,boolean,text,text)','EXECUTE') then
    raise exception 'SAAS-9D-2C-1 postflight failed: target ACL differs.';
  end if;

  if pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef(
       'public.check_confirmation_email_rate_limit(uuid,text)'::pg_catalog.regprocedure),E'\r\n',E'\n'),E'\r',E'\n'))
       <> (select rate_limit_fingerprint from saas9d2c1_preflight_snapshot) then
    raise exception 'SAAS-9D-2C-1 postflight failed: rate-limit function changed.';
  end if;

  select pg_catalog.md5(coalesce(pg_catalog.string_agg(
    p.oid::pg_catalog.regprocedure::text||':'||pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(
      pg_catalog.pg_get_functiondef(p.oid),E'\r\n',E'\n'),E'\r',E'\n')),E'\n' order by p.oid::pg_catalog.regprocedure::text),''))
  into v_other_definer_fingerprint
  from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.prosecdef
    and p.proname not in ('prepare_confirmation_email','complete_confirmation_email');
  if v_other_definer_fingerprint is distinct from
     (select other_definer_fingerprint from saas9d2c1_preflight_snapshot) then
    raise exception 'SAAS-9D-2C-1 postflight failed: unrelated SECURITY DEFINER drift.';
  end if;

  if (select pg_catalog.count(*) from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.prosecdef)<>72 then
    raise exception 'SAAS-9D-2C-1 postflight failed: expected 72 SECURITY DEFINER functions.';
  end if;

  if exists(select 1 from public.email_deliveries where tenant_id is null)
     or (select pg_catalog.count(*) from information_schema.columns
         where table_schema='public' and table_name in ('shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','email_deliveries')
           and column_name='tenant_id' and column_default='''c5c00000-0000-4000-8000-000000000001''::uuid')<>7 then
    raise exception 'SAAS-9D-2C-1 postflight failed: tenant ownership/default contract drift.';
  end if;
end;
$postflight$;
