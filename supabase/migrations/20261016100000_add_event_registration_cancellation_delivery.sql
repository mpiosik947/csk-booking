-- PRODUCT-10G-C2: cancellation receipts only. No business/lifecycle mutation.
begin;
set local lock_timeout='5s';
set local statement_timeout='60s';

alter table public.event_registrations add column cancellation_email_initialized_at timestamptz;
-- No trustworthy canonical cancellation timestamp exists. Legacy rows are blocked,
-- not queued. The DDL lock serializes this backfill with concurrent cancellations.
update public.event_registrations set cancellation_email_initialized_at=transaction_timestamp()
where registration_status='cancelled';

create function public.guard_cancellation_email_marker_v1() returns trigger
language plpgsql security invoker set search_path=pg_catalog as $$
begin
 if tg_op='INSERT' then
  if new.cancellation_email_initialized_at is not null then
   raise exception 'Marker is DB controlled' using errcode='42501'; end if;
 elsif new.cancellation_email_initialized_at is distinct from old.cancellation_email_initialized_at then
  if current_user<>'postgres' or old.cancellation_email_initialized_at is not null
    or new.cancellation_email_initialized_at is null or new.registration_status<>'cancelled' then
   raise exception 'Marker is immutable and DB controlled' using errcode='42501'; end if;
 end if;
 return new;
end;$$;
create trigger guard_cancellation_email_marker before insert or update on public.event_registrations
for each row execute function public.guard_cancellation_email_marker_v1();
revoke all on function public.guard_cancellation_email_marker_v1() from public,anon,authenticated,service_role;

-- Narrow metadata-only exception. Existing new-business guards stay unchanged.
do $$declare definition text; anchor text:='if tenant_status=''suspended'' and tg_op=''UPDATE'' then'; begin
 definition:=pg_get_functiondef('public.enforce_suspended_obligations_v1()'::regprocedure);
 if strpos(definition,anchor)=0 then raise exception 'Suspension baseline drift'; end if;
 execute replace(definition,anchor,anchor||$guard$
 if tg_table_name='event_registrations'
  and to_jsonb(old)->>'registration_status'='cancelled' and to_jsonb(new)->>'registration_status'='cancelled'
  and to_jsonb(old)->>'cancellation_email_initialized_at' is null
  and to_jsonb(new)->>'cancellation_email_initialized_at' is not null
  and (to_jsonb(new)-'cancellation_email_initialized_at')=(to_jsonb(old)-'cancellation_email_initialized_at')
 then return new; end if;
 $guard$);
end;$$;

alter table public.email_deliveries drop constraint email_deliveries_message_type_check;
alter table public.email_deliveries add constraint email_deliveries_message_type_check check(message_type in (
 'event_registration_confirmation','reservation_confirmation','reservation_cancellation',
 'event_reserve_acceptance_confirmation','event_registration_cancellation'));

-- Extend the existing state shape without altering old message semantics.
do $$declare definition text; begin
 select pg_get_constraintdef(oid) into definition from pg_constraint
 where conrelid='public.email_deliveries'::regclass and conname='email_deliveries_acceptance_state_check';
 if definition is null then raise exception 'Missing delivery state baseline'; end if;
 definition:=replace(definition,$a$message_type <> 'event_reserve_acceptance_confirmation'::text$a$,
  $a$message_type NOT IN ('event_reserve_acceptance_confirmation','event_registration_cancellation')$a$);
 definition:=replace(definition,$a$message_type = 'event_reserve_acceptance_confirmation'::text$a$,
  $a$message_type IN ('event_reserve_acceptance_confirmation','event_registration_cancellation')$a$);
 execute 'alter table public.email_deliveries drop constraint email_deliveries_acceptance_state_check';
 execute 'alter table public.email_deliveries add constraint email_deliveries_acceptance_state_check '||definition;
end;$$;

-- Preserve the old resource trigger body; only add a branch for the new type.
do $$declare definition text; anchor text:='if new.message_type in (''reservation_confirmation'',''reservation_cancellation'') then'; begin
 definition:=pg_get_functiondef('public.set_email_delivery_tenant_id()'::regprocedure);
 if strpos(definition,anchor)=0 then raise exception 'Resource binding baseline drift'; end if;
 execute replace(definition,anchor,$branch$
 if tg_op='UPDATE' and old.message_type='event_registration_cancellation' and new.message_type is distinct from old.message_type then
  raise exception 'Cancellation receipt identity immutable' using errcode='23514'; end if;
 if new.message_type='event_registration_cancellation' then
  select r.tenant_id,r.user_id into v_tenant_id,v_user_id from public.event_registrations r
  join public.events e on e.id=r.event_id and e.tenant_id=r.tenant_id
  where r.id=new.record_id and r.registration_status='cancelled'
   and r.cancellation_email_initialized_at is not null and r.pii_anonymized_at is null;
  if tg_op='INSERT' and current_user<>'postgres' then
   raise exception 'Use authorized preparation' using errcode='42501'; end if;
  if v_tenant_id is null or v_user_id is null or new.recipient_user_id is distinct from v_user_id then
   raise exception 'Cancellation receipt unavailable' using errcode='23514'; end if;
  if tg_op='UPDATE' and (new.record_id is distinct from old.record_id or new.message_type is distinct from old.message_type
   or new.tenant_id is distinct from old.tenant_id or new.recipient_user_id is distinct from old.recipient_user_id) then
   raise exception 'Cancellation receipt identity immutable' using errcode='23514'; end if;
 elsif new.message_type in ('reservation_confirmation','reservation_cancellation') then
 $branch$);
end;$$;

create function public.prepare_event_registration_cancellation_email_v1(p_registration_id uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,pg_temp as $$
declare r public.event_registrations%rowtype; d public.email_deliveries%rowtype;
 actor uuid:=auth.uid(); actor_role text; stamp timestamptz:=clock_timestamp(); lease uuid;
begin
 if actor is null then raise exception 'Unavailable' using errcode='42501'; end if;
 select * into r from public.event_registrations where id=p_registration_id for update;
 if not found then raise exception 'Unavailable' using errcode='42501'; end if;
 actor_role:=public.get_my_continuity_role_core_v1(r.tenant_id);
 if actor_role is null or (r.user_id is distinct from actor and actor_role not in ('admin','employee'))
  or r.registration_status<>'cancelled' or r.pii_anonymized_at is not null or r.user_id is null
  or not exists(select 1 from public.events e where e.id=r.event_id and e.tenant_id=r.tenant_id) then
  raise exception 'Unavailable' using errcode='42501'; end if;
 -- Serialize lifecycle changes without granting new business to suspended tenants.
 perform 1 from public.tenants where id=r.tenant_id and status in ('active','suspended') for share;
 if not found then raise exception 'Unavailable' using errcode='42501'; end if;
 select * into d from public.email_deliveries where message_type='event_registration_cancellation'
  and record_id=r.id for update;
 if not found then
  if r.cancellation_email_initialized_at is not null then return jsonb_build_object('code','retired'); end if;
  update public.event_registrations set cancellation_email_initialized_at=stamp where id=r.id;
  insert into public.email_deliveries(tenant_id,message_type,record_id,recipient_user_id,delivery_state)
  values(r.tenant_id,'event_registration_cancellation',r.id,r.user_id,'pending') returning * into d;
 elsif r.cancellation_email_initialized_at is null or d.tenant_id is distinct from r.tenant_id
  or d.recipient_user_id is distinct from r.user_id then
  raise exception 'Receipt invariant failed' using errcode='23514';
 end if;
 if d.delivery_state='sent' then return jsonb_build_object('code','already_sent'); end if;
 if d.claim_id is not null and d.claim_expires_at>stamp then return jsonb_build_object('code','in_progress'); end if;
 if d.attempt_count>=3 or d.attempt_window_started_at<=stamp-interval '23 hours' then
  update public.email_deliveries set delivery_state='failed',claim_id=null,claim_expires_at=null,
   last_error_code='retry_exhausted',updated_at=case when d.delivery_state='failed' then d.updated_at else stamp end where id=d.id;
  return jsonb_build_object('code','retry_exhausted'); end if;
 lease:=gen_random_uuid();
 update public.email_deliveries set delivery_state='sending',claim_id=lease,claim_expires_at=stamp+interval '5 minutes',
  attempt_count=attempt_count+1,attempt_window_started_at=coalesce(attempt_window_started_at,stamp),
  last_attempt_at=stamp,last_error_code=null,updated_at=stamp where id=d.id;
 return jsonb_build_object('code','ready','claim_id',lease,'registration_id',r.id,
  'tenant_id',r.tenant_id,'recipient_user_id',r.user_id,
  'idempotency_key','event-registration-cancellation/'||r.tenant_id::text||'/'||r.id::text);
end;$$;

create function public.complete_event_registration_cancellation_email_v1(p_claim_id uuid,p_success boolean,p_provider_message_id text default null)
returns jsonb language plpgsql security invoker set search_path=pg_catalog,public,pg_temp as $$
declare d public.email_deliveries%rowtype; stamp timestamptz:=clock_timestamp(); begin
 select * into d from public.email_deliveries where claim_id=p_claim_id
  and message_type='event_registration_cancellation' for update;
 if not found or d.delivery_state<>'sending' or d.claim_expires_at<=stamp then
  return jsonb_build_object('code','claim_not_found'); end if;
 if p_success is null or (p_success and (p_provider_message_id is null or p_provider_message_id!~'^[A-Za-z0-9_-]{1,128}$')) then
  raise exception 'Invalid completion' using errcode='22023'; end if;
 update public.email_deliveries set delivery_state=case when p_success then 'sent' else 'failed' end,
  sent_at=case when p_success then stamp else null end,provider_message_id=case when p_success then p_provider_message_id else null end,
  claim_id=null,claim_expires_at=null,last_error_code=case when p_success then null else 'delivery_failed_or_uncertain' end,
  updated_at=stamp where id=d.id;
 return jsonb_build_object('code',case when p_success then 'sent' else 'failed' end);
end;$$;

create function public.purge_event_registration_cancellation_deliveries_v1() returns integer
language plpgsql security invoker set search_path=pg_catalog,public,pg_temp as $$
declare removed integer; begin
 delete from public.email_deliveries where message_type='event_registration_cancellation'
  and delivery_state in ('sent','failed') and updated_at<clock_timestamp()-interval '90 days';
 get diagnostics removed=row_count; return removed;
end;$$;
revoke all on function public.prepare_event_registration_cancellation_email_v1(uuid) from public,anon,authenticated,service_role;
grant execute on function public.prepare_event_registration_cancellation_email_v1(uuid) to authenticated;
revoke all on function public.complete_event_registration_cancellation_email_v1(uuid,boolean,text) from public,anon,authenticated,service_role;
grant execute on function public.complete_event_registration_cancellation_email_v1(uuid,boolean,text) to service_role;
revoke all on function public.purge_event_registration_cancellation_deliveries_v1() from public,anon,authenticated,service_role;
commit;
