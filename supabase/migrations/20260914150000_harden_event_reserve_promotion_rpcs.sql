-- SAAS-9D-2C-2: tenant-bind service-only reserve-promotion claims.

do $preflight$
declare
  v_non_target_function_fingerprint text;
  v_other_definer_fingerprint text;
begin
  if pg_catalog.to_regprocedure('public.prepare_event_reserve_promotions(uuid)') is null
     or pg_catalog.to_regprocedure('public.complete_event_reserve_promotion(uuid,uuid,boolean,text)') is null then
    raise exception 'SAAS-9D-2C-2 preflight failed: required function is missing.';
  end if;

  if (select pg_catalog.count(*) from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public'
        and p.proname in ('prepare_event_reserve_promotions','complete_event_reserve_promotion'))<>2 then
    raise exception 'SAAS-9D-2C-2 preflight failed: target overload inventory drift.';
  end if;

  if pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef(
       'public.prepare_event_reserve_promotions(uuid)'::pg_catalog.regprocedure),E'\r\n',E'\n'),E'\r',E'\n'))
       <> '4e73ef1df59936a1a3f41a00e121f6e9'
     or pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef(
       'public.complete_event_reserve_promotion(uuid,uuid,boolean,text)'::pg_catalog.regprocedure),E'\r\n',E'\n'),E'\r',E'\n'))
       <> 'dd5025876008d6eb9551497d84cef90e' then
    raise exception 'SAAS-9D-2C-2 preflight failed: normalized target fingerprint drift.';
  end if;

  if not exists(select 1 from pg_catalog.pg_proc p join pg_catalog.pg_roles r on r.oid=p.proowner
      where p.oid='public.prepare_event_reserve_promotions(uuid)'::pg_catalog.regprocedure
        and p.prosecdef and p.provolatile='v' and r.rolname='postgres'
        and p.proconfig=array['search_path=public, pg_temp']::text[])
     or not exists(select 1 from pg_catalog.pg_proc p join pg_catalog.pg_roles r on r.oid=p.proowner
      where p.oid='public.complete_event_reserve_promotion(uuid,uuid,boolean,text)'::pg_catalog.regprocedure
        and p.prosecdef and p.provolatile='v' and r.rolname='postgres'
        and p.proconfig=array['search_path=public, pg_temp']::text[]) then
    raise exception 'SAAS-9D-2C-2 preflight failed: target metadata drift.';
  end if;

  if not pg_catalog.has_function_privilege('service_role','public.prepare_event_reserve_promotions(uuid)','EXECUTE')
     or pg_catalog.has_function_privilege('public','public.prepare_event_reserve_promotions(uuid)','EXECUTE')
     or pg_catalog.has_function_privilege('anon','public.prepare_event_reserve_promotions(uuid)','EXECUTE')
     or pg_catalog.has_function_privilege('authenticated','public.prepare_event_reserve_promotions(uuid)','EXECUTE')
     or not pg_catalog.has_function_privilege('service_role','public.complete_event_reserve_promotion(uuid,uuid,boolean,text)','EXECUTE')
     or pg_catalog.has_function_privilege('public','public.complete_event_reserve_promotion(uuid,uuid,boolean,text)','EXECUTE')
     or pg_catalog.has_function_privilege('anon','public.complete_event_reserve_promotion(uuid,uuid,boolean,text)','EXECUTE')
     or pg_catalog.has_function_privilege('authenticated','public.complete_event_reserve_promotion(uuid,uuid,boolean,text)','EXECUTE') then
    raise exception 'SAAS-9D-2C-2 preflight failed: target ACL drift.';
  end if;

  if not pg_catalog.has_table_privilege('service_role','public.events','SELECT')
     or not pg_catalog.has_table_privilege('service_role','public.event_registrations','SELECT,UPDATE') then
    raise exception 'SAAS-9D-2C-2 preflight failed: service invoker table contract differs.';
  end if;

  if exists(
       select 1 from public.event_registrations registration
       left join public.events event_record
         on event_record.id=registration.event_id
        and event_record.tenant_id=registration.tenant_id
       where registration.tenant_id is null or event_record.id is null
     )
     or exists(select 1 from public.event_registrations
       where promotion_claim_id is not null and registration_status<>'reserve')
     or exists(select 1 from public.event_registrations
       where promotion_claim_id is not null)
     or exists(select promotion_claim_id from public.event_registrations
       where promotion_claim_id is not null group by promotion_claim_id having pg_catalog.count(*)>1)
     or exists(select promotion_token from public.event_registrations
       where promotion_token is not null group by promotion_token having pg_catalog.count(*)>1) then
    raise exception 'SAAS-9D-2C-2 preflight failed: event/tenant/claim/token invariant differs.';
  end if;

  if (select pg_catalog.count(*) from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.prosecdef)<>72 then
    raise exception 'SAAS-9D-2C-2 preflight failed: SECURITY DEFINER inventory drift.';
  end if;

  if (select pg_catalog.count(*) from information_schema.columns
      where table_schema='public'
        and table_name in('shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','email_deliveries')
        and column_name='tenant_id'
        and column_default='''c5c00000-0000-4000-8000-000000000001''::uuid')<>7 then
    raise exception 'SAAS-9D-2C-2 preflight failed: compatibility defaults drift.';
  end if;

  select pg_catalog.md5(coalesce(pg_catalog.string_agg(
    p.oid::pg_catalog.regprocedure::text||'|'||p.prosecdef::text||'|'||
    pg_catalog.pg_get_userbyid(p.proowner)||'|'||coalesce(p.proconfig::text,'')||'|'||
    pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef(p.oid),E'\r\n',E'\n'),E'\r',E'\n')),
    E'\n' order by p.oid::pg_catalog.regprocedure::text),''))
  into v_non_target_function_fingerprint
  from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public'
    and p.oid not in(
      'public.prepare_event_reserve_promotions(uuid)'::pg_catalog.regprocedure,
      'public.complete_event_reserve_promotion(uuid,uuid,boolean,text)'::pg_catalog.regprocedure
    );

  select pg_catalog.md5(coalesce(pg_catalog.string_agg(
    p.oid::pg_catalog.regprocedure::text||':'||pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(
      pg_catalog.pg_get_functiondef(p.oid),E'\r\n',E'\n'),E'\r',E'\n')),E'\n'
      order by p.oid::pg_catalog.regprocedure::text),''))
  into v_other_definer_fingerprint
  from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.prosecdef
    and p.oid not in(
      'public.prepare_event_reserve_promotions(uuid)'::pg_catalog.regprocedure,
      'public.complete_event_reserve_promotion(uuid,uuid,boolean,text)'::pg_catalog.regprocedure
    );

  create temporary table saas9d2c2_preflight_snapshot(
    non_target_function_fingerprint text not null,
    other_definer_fingerprint text not null
  ) on commit drop;
  insert into saas9d2c2_preflight_snapshot values(
    v_non_target_function_fingerprint,
    v_other_definer_fingerprint
  );
end;
$preflight$;

create or replace function public.prepare_event_reserve_promotions(
  p_event_id uuid
) returns table(
  registration_id uuid,
  claim_id uuid,
  promotion_token text,
  promotion_token_expires_at timestamptz,
  token_reused boolean
)
language plpgsql
security invoker
set search_path=pg_catalog, public, pg_temp
as $function$
declare
  v_event public.events%rowtype;
  v_reserve record;
  v_participants_count integer;
  v_now timestamptz:=pg_catalog.transaction_timestamp();
  v_claim_id uuid;
  v_token text;
  v_token_expires_at timestamptz;
  v_token_reused boolean;
  v_updated integer;
begin
  if p_event_id is null then
    raise exception using
      errcode='22023',
      message='Identyfikator szkolenia jest wymagany.';
  end if;

  select event_record.* into v_event
  from public.events event_record
  where event_record.id=p_event_id
    and event_record.tenant_id is not null
  for update;

  if not found then
    raise exception using
      errcode='P0002',
      message='Nie znaleziono szkolenia.';
  end if;

  select pg_catalog.count(*) into v_participants_count
  from public.event_registrations registration
  where registration.event_id=v_event.id
    and registration.tenant_id=v_event.tenant_id
    and registration.registration_status in('registered','approved');

  if v_participants_count>=coalesce(v_event.max_participants,0) then
    return;
  end if;

  for v_reserve in
    select registration.id,
           registration.event_id,
           registration.tenant_id,
           registration.promotion_token,
           registration.promotion_token_expires_at,
           registration.promotion_email_sent_at,
           registration.promotion_confirmed_at
    from public.event_registrations registration
    where registration.event_id=v_event.id
      and registration.tenant_id=v_event.tenant_id
      and registration.registration_status='reserve'
      and not(
        registration.promotion_claim_id is not null
        and registration.promotion_claim_expires_at>v_now
      )
      and not(
        registration.promotion_email_sent_at is not null
        and registration.promotion_token is not null
        and registration.promotion_token_expires_at>v_now
      )
    order by registration.created_at,registration.id
    for update
  loop
    v_token_reused:=
      v_reserve.promotion_token is not null
      and v_reserve.promotion_token_expires_at>v_now
      and v_reserve.promotion_email_sent_at is null;

    if v_token_reused then
      v_token:=v_reserve.promotion_token;
      v_token_expires_at:=v_reserve.promotion_token_expires_at;
    else
      v_token:=pg_catalog.gen_random_uuid()::text;
      v_token_expires_at:=v_now+interval '24 hours';
    end if;

    v_claim_id:=pg_catalog.gen_random_uuid();

    update public.event_registrations registration
    set promotion_token=v_token,
        promotion_token_expires_at=v_token_expires_at,
        promotion_email_sent_at=case when v_token_reused then registration.promotion_email_sent_at else null end,
        promotion_confirmed_at=case when v_token_reused then registration.promotion_confirmed_at else null end,
        promotion_claim_id=v_claim_id,
        promotion_claim_expires_at=v_now+interval '10 minutes',
        promotion_attempt_count=registration.promotion_attempt_count+1,
        promotion_last_attempt_at=v_now,
        promotion_last_error_code=null
    where registration.id=v_reserve.id
      and registration.event_id=v_reserve.event_id
      and registration.tenant_id=v_reserve.tenant_id
      and registration.registration_status='reserve';
    get diagnostics v_updated=row_count;
    if v_updated<>1 then
      raise exception using
        errcode='55000',
        message='Nie udało się bezpiecznie przypisać claimu promocji.';
    end if;

    registration_id:=v_reserve.id;
    claim_id:=v_claim_id;
    promotion_token:=v_token;
    promotion_token_expires_at:=v_token_expires_at;
    token_reused:=v_token_reused;
    return next;
  end loop;
end;
$function$;

alter function public.prepare_event_reserve_promotions(uuid) owner to postgres;
revoke all on function public.prepare_event_reserve_promotions(uuid)
  from public,anon,authenticated,service_role;
grant execute on function public.prepare_event_reserve_promotions(uuid) to service_role;
comment on function public.prepare_event_reserve_promotions(uuid) is
  'As a service-only invoker, claims same-tenant reserve registrations in stable FIFO order.';

create or replace function public.complete_event_reserve_promotion(
  p_registration_id uuid,
  p_claim_id uuid,
  p_success boolean,
  p_error_code text default null
) returns jsonb
language plpgsql
security invoker
set search_path=pg_catalog, public, pg_temp
as $function$
declare
  v_registration_id uuid;
  v_event_id uuid;
  v_tenant_id uuid;
  v_event_tenant_id uuid;
  v_registration_status text;
  v_event_active boolean;
  v_current_claim_id uuid;
  v_claim_expires_at timestamptz;
  v_email_sent_at timestamptz;
  v_error_code text;
  v_updated integer;
begin
  if p_registration_id is null or p_claim_id is null then
    raise exception using
      errcode='22023',
      message='Identyfikator zapisu i claimu są wymagane.';
  end if;

  if p_success is null then
    raise exception using
      errcode='22023',
      message='Wynik wysyłki jest wymagany.';
  end if;

  if not p_success then
    v_error_code:=pg_catalog.lower(pg_catalog.btrim(coalesce(p_error_code,'')));
    if v_error_code='' then v_error_code:='delivery_failed'; end if;
    if pg_catalog.char_length(v_error_code)>100
       or v_error_code!~'^[a-z][a-z0-9_]{0,99}$' then
      raise exception using
        errcode='22023',
        message='Nieprawidłowy techniczny kod błędu.';
    end if;
  end if;

  select registration.event_id,registration.tenant_id
  into v_event_id,v_tenant_id
  from public.event_registrations registration
  where registration.id=p_registration_id;
  if not found then
    raise exception using
      errcode='P0002',
      message='Nie znaleziono zapisu na szkolenie.';
  end if;

  select event_record.tenant_id,event_record.is_active
  into v_event_tenant_id,v_event_active
  from public.events event_record
  where event_record.id=v_event_id
    and event_record.tenant_id=v_tenant_id
  for update;
  if not found or v_event_tenant_id is distinct from v_tenant_id then
    raise exception using
      errcode='P0002',
      message='Nie znaleziono zapisu na szkolenie.';
  end if;

  select registration.id,
         registration.event_id,
         registration.tenant_id,
         registration.registration_status,
         registration.promotion_claim_id,
         registration.promotion_claim_expires_at,
         registration.promotion_email_sent_at
  into v_registration_id,v_event_id,v_tenant_id,v_registration_status,
       v_current_claim_id,v_claim_expires_at,v_email_sent_at
  from public.event_registrations registration
  where registration.id=p_registration_id
    and registration.event_id=v_event_id
    and registration.tenant_id=v_event_tenant_id
  for update;
  if not found then
    raise exception using
      errcode='P0002',
      message='Nie znaleziono zapisu na szkolenie.';
  end if;

  if v_current_claim_id is null then
    if p_success and v_email_sent_at is not null then
      return pg_catalog.jsonb_build_object(
        'registration_id',v_registration_id,'changed',false,'success',true,
        'claim_cleared',true,'email_sent_recorded',true
      );
    end if;
    if not p_success then
      return pg_catalog.jsonb_build_object(
        'registration_id',v_registration_id,'changed',false,'success',false,
        'claim_cleared',true,'email_sent_recorded',v_email_sent_at is not null
      );
    end if;
    raise exception using errcode='55000',message='Claim promocji nie jest aktywny.';
  end if;

  if v_current_claim_id<>p_claim_id then
    raise exception using
      errcode='55000',
      message='Claim promocji należy do innego procesu.';
  end if;

  if v_claim_expires_at is null
     or v_claim_expires_at<=pg_catalog.transaction_timestamp() then
    raise exception using
      errcode='55000',
      message='Claim promocji wygasł.';
  end if;

  -- Status and event activity are deliberately re-read under locks. Completion
  -- records the actual provider outcome only; it never restores eligibility or
  -- changes registration status/capacity when cancellation wins the race.
  if p_success then
    update public.event_registrations registration
    set promotion_email_sent_at=coalesce(registration.promotion_email_sent_at,pg_catalog.transaction_timestamp()),
        promotion_claim_id=null,
        promotion_claim_expires_at=null,
        promotion_last_error_code=null
    where registration.id=v_registration_id
      and registration.event_id=v_event_id
      and registration.tenant_id=v_tenant_id
      and registration.promotion_claim_id=p_claim_id;
    get diagnostics v_updated=row_count;
    if v_updated<>1 then
      raise exception using errcode='55000',message='Claim promocji nie jest aktywny.';
    end if;
    return pg_catalog.jsonb_build_object(
      'registration_id',v_registration_id,'changed',true,'success',true,
      'claim_cleared',true,'email_sent_recorded',true
    );
  end if;

  update public.event_registrations registration
  set promotion_claim_id=null,
      promotion_claim_expires_at=null,
      promotion_last_error_code=v_error_code
  where registration.id=v_registration_id
    and registration.event_id=v_event_id
    and registration.tenant_id=v_tenant_id
    and registration.promotion_claim_id=p_claim_id;
  get diagnostics v_updated=row_count;
  if v_updated<>1 then
    raise exception using errcode='55000',message='Claim promocji nie jest aktywny.';
  end if;
  return pg_catalog.jsonb_build_object(
    'registration_id',v_registration_id,'changed',true,'success',false,
    'claim_cleared',true,'email_sent_recorded',v_email_sent_at is not null
  );
end;
$function$;

alter function public.complete_event_reserve_promotion(uuid,uuid,boolean,text) owner to postgres;
revoke all on function public.complete_event_reserve_promotion(uuid,uuid,boolean,text)
  from public,anon,authenticated,service_role;
grant execute on function public.complete_event_reserve_promotion(uuid,uuid,boolean,text) to service_role;
comment on function public.complete_event_reserve_promotion(uuid,uuid,boolean,text) is
  'As a service-only invoker, completes only an exact claim with a valid registration/event tenant relationship.';

do $postflight$
declare
  v_snapshot record;
  v_non_target_function_fingerprint text;
  v_other_definer_fingerprint text;
begin
  if not exists(select 1 from pg_catalog.pg_proc p join pg_catalog.pg_roles r on r.oid=p.proowner
      where p.oid='public.prepare_event_reserve_promotions(uuid)'::pg_catalog.regprocedure
        and not p.prosecdef and p.provolatile='v' and r.rolname='postgres'
        and p.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[])
     or not exists(select 1 from pg_catalog.pg_proc p join pg_catalog.pg_roles r on r.oid=p.proowner
      where p.oid='public.complete_event_reserve_promotion(uuid,uuid,boolean,text)'::pg_catalog.regprocedure
        and not p.prosecdef and p.provolatile='v' and r.rolname='postgres'
        and p.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[]) then
    raise exception 'SAAS-9D-2C-2 postflight failed: target metadata differs.';
  end if;

  if pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef(
       'public.prepare_event_reserve_promotions(uuid)'::pg_catalog.regprocedure),E'\r\n',E'\n'),E'\r',E'\n'))
       <> 'cdc7abeb7f8ced41cde0f5524a8953ef'
     or pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef(
       'public.complete_event_reserve_promotion(uuid,uuid,boolean,text)'::pg_catalog.regprocedure),E'\r\n',E'\n'),E'\r',E'\n'))
       <> '2c78ac26c5c55df3aac54360b610d39b' then
    raise exception 'SAAS-9D-2C-2 postflight failed: target fingerprint differs.';
  end if;

  if not pg_catalog.has_function_privilege('service_role','public.prepare_event_reserve_promotions(uuid)','EXECUTE')
     or pg_catalog.has_function_privilege('public','public.prepare_event_reserve_promotions(uuid)','EXECUTE')
     or pg_catalog.has_function_privilege('anon','public.prepare_event_reserve_promotions(uuid)','EXECUTE')
     or pg_catalog.has_function_privilege('authenticated','public.prepare_event_reserve_promotions(uuid)','EXECUTE')
     or not pg_catalog.has_function_privilege('service_role','public.complete_event_reserve_promotion(uuid,uuid,boolean,text)','EXECUTE')
     or pg_catalog.has_function_privilege('public','public.complete_event_reserve_promotion(uuid,uuid,boolean,text)','EXECUTE')
     or pg_catalog.has_function_privilege('anon','public.complete_event_reserve_promotion(uuid,uuid,boolean,text)','EXECUTE')
     or pg_catalog.has_function_privilege('authenticated','public.complete_event_reserve_promotion(uuid,uuid,boolean,text)','EXECUTE') then
    raise exception 'SAAS-9D-2C-2 postflight failed: target ACL differs.';
  end if;

  if (select pg_catalog.count(*) from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.prosecdef)<>70 then
    raise exception 'SAAS-9D-2C-2 postflight failed: SECURITY DEFINER count differs.';
  end if;

  select * into v_snapshot from saas9d2c2_preflight_snapshot;

  select pg_catalog.md5(coalesce(pg_catalog.string_agg(
    p.oid::pg_catalog.regprocedure::text||'|'||p.prosecdef::text||'|'||
    pg_catalog.pg_get_userbyid(p.proowner)||'|'||coalesce(p.proconfig::text,'')||'|'||
    pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef(p.oid),E'\r\n',E'\n'),E'\r',E'\n')),
    E'\n' order by p.oid::pg_catalog.regprocedure::text),''))
  into v_non_target_function_fingerprint
  from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public'
    and p.oid not in(
      'public.prepare_event_reserve_promotions(uuid)'::pg_catalog.regprocedure,
      'public.complete_event_reserve_promotion(uuid,uuid,boolean,text)'::pg_catalog.regprocedure
    );

  select pg_catalog.md5(coalesce(pg_catalog.string_agg(
    p.oid::pg_catalog.regprocedure::text||':'||pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(
      pg_catalog.pg_get_functiondef(p.oid),E'\r\n',E'\n'),E'\r',E'\n')),E'\n'
      order by p.oid::pg_catalog.regprocedure::text),''))
  into v_other_definer_fingerprint
  from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.prosecdef;

  if v_snapshot.non_target_function_fingerprint is distinct from v_non_target_function_fingerprint
     or v_snapshot.other_definer_fingerprint is distinct from v_other_definer_fingerprint then
    raise exception 'SAAS-9D-2C-2 postflight failed: non-target function drift.';
  end if;

  if (select pg_catalog.count(*) from information_schema.columns
      where table_schema='public'
        and table_name in('shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','email_deliveries')
        and column_name='tenant_id'
        and column_default='''c5c00000-0000-4000-8000-000000000001''::uuid')<>7 then
    raise exception 'SAAS-9D-2C-2 postflight failed: compatibility defaults changed.';
  end if;
end;
$postflight$;
