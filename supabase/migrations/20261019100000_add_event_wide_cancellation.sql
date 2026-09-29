-- PRODUCT-10G-C2B. No backfill, scheduler or historical registration rewrite.
begin;
set local lock_timeout='5s';
set local statement_timeout='60s';
alter table public.events add column cancelled_at timestamptz;
alter table public.events add column cancelled_by uuid;
alter table public.events add constraint event_cancellation_shape check
 ((cancelled_at is null and cancelled_by is null) or
  (cancelled_at is not null and cancelled_by is not null and not is_active));

create function public.guard_event_cancellation_v1() returns trigger
language plpgsql security invoker set search_path=pg_catalog,public,pg_temp as $$
begin
 if tg_op='INSERT' then
  if new.cancelled_at is not null or new.cancelled_by is not null then
   raise exception 'Cancellation is controlled' using errcode='42501'; end if;
 elsif old.cancelled_at is not null then
  if new.cancelled_at is distinct from old.cancelled_at or new.cancelled_by is distinct from old.cancelled_by
   or new.is_active then raise exception 'Cancellation is irreversible' using errcode='42501'; end if;
 elsif new.cancelled_at is not null or new.cancelled_by is not null then
  if current_user<>'postgres' or auth.uid() is null or new.cancelled_by is distinct from auth.uid()
   or new.cancelled_at is null or new.is_active
   or coalesce(public.get_my_tenant_role_v1(old.tenant_id),'') not in ('admin','employee')
   or not public.get_my_tenant_feature_access_v1(old.tenant_id,'events') then
   raise exception 'Cancellation unavailable' using errcode='42501'; end if;
 end if;
 return new;
end;$$;
create trigger guard_event_cancellation before insert or update on public.events
for each row execute function public.guard_event_cancellation_v1();
revoke all on function public.guard_event_cancellation_v1() from public,anon,authenticated,service_role;

-- Serialize every participation advance with cancellation. No history rewrite.
create function public.guard_cancelled_event_registration_v1() returns trigger
language plpgsql security definer set search_path=pg_catalog,public,pg_temp as $$
declare cancelled timestamptz;
begin
 select e.cancelled_at into cancelled from public.events e
 where e.id=new.event_id and e.tenant_id=new.tenant_id for share;
 if cancelled is not null and (tg_op='INSERT' or
   (new.registration_status is distinct from old.registration_status and new.registration_status<>'cancelled') or
   new.promotion_token is distinct from old.promotion_token and new.promotion_token is not null or
   new.promotion_confirmed_at is distinct from old.promotion_confirmed_at and new.promotion_confirmed_at is not null or
   new.promotion_claim_id is distinct from old.promotion_claim_id and new.promotion_claim_id is not null) then
  raise exception 'Event cancelled' using errcode='42501';
 end if;
 return new;
end;$$;
create trigger guard_cancelled_event_registration before insert or update on public.event_registrations
for each row execute function public.guard_cancelled_event_registration_v1();
revoke all on function public.guard_cancelled_event_registration_v1() from public,anon,authenticated,service_role;

alter table public.email_deliveries drop constraint email_deliveries_message_type_check;
alter table public.email_deliveries add constraint email_deliveries_message_type_check check(message_type in (
 'event_registration_confirmation','reservation_confirmation','reservation_cancellation',
 'event_reserve_acceptance_confirmation','event_registration_cancellation','booking_reminder_24h',
 'event_reminder_24h','event_cancellation'));
-- Extend only the acceptance/cancellation state branch; all existing checks retained.
do $$declare def text; begin
 select pg_get_constraintdef(oid) into def from pg_constraint
 where conrelid='public.email_deliveries'::regclass and conname='email_deliveries_acceptance_state_check';
 if def is null or strpos(def,'''event_registration_cancellation''::text')=0 then raise exception 'State baseline drift'; end if;
 def:=replace(def,'''event_registration_cancellation''::text','''event_registration_cancellation''::text, ''event_cancellation''::text');
 alter table public.email_deliveries drop constraint email_deliveries_acceptance_state_check;
 execute 'alter table public.email_deliveries add constraint email_deliveries_acceptance_state_check '||def;
end;$$;

-- Immutable resource-derived identity. No PII or body persisted in deliveries.
do $$declare def text; anchor text:='if new.message_type in (''booking_reminder_24h'',''event_reminder_24h'') then'; begin
 def:=pg_get_functiondef('public.set_email_delivery_tenant_id()'::regprocedure);
 if strpos(def,anchor)=0 then raise exception 'Delivery baseline drift'; end if;
 execute replace(def,anchor,$branch$
 if tg_op='UPDATE' and old.message_type='event_cancellation' and
  (new.message_type is distinct from old.message_type or new.record_id is distinct from old.record_id
   or new.recipient_user_id is distinct from old.recipient_user_id or new.tenant_id is distinct from old.tenant_id) then
  raise exception 'Immutable cancellation identity' using errcode='23514'; end if;
 if new.message_type='event_cancellation' then
  select r.tenant_id,r.user_id into v_tenant_id,v_user_id from public.event_registrations r
  join public.events e on e.id=r.event_id and e.tenant_id=r.tenant_id
  where r.id=new.record_id and e.cancelled_at is not null and r.pii_anonymized_at is null;
  if v_tenant_id is null or v_user_id is null or new.recipient_user_id is distinct from v_user_id
   or new.tenant_id is distinct from v_tenant_id then raise exception 'Cancellation identity mismatch' using errcode='23514'; end if;
  if tg_op='INSERT' and (current_user<>'postgres' or not exists(select 1 from public.events e
    join public.event_registrations r on r.event_id=e.id where r.id=new.record_id
    and e.cancelled_at=transaction_timestamp() and e.cancelled_by=auth.uid()
    and r.registration_status in ('registered','approved','reserve'))) then
   raise exception 'Cancellation obligation is transition-only' using errcode='42501'; end if;
  if tg_op='UPDATE' and (new.record_id is distinct from old.record_id or new.message_type is distinct from old.message_type
   or new.recipient_user_id is distinct from old.recipient_user_id or new.tenant_id is distinct from old.tenant_id) then
   raise exception 'Immutable cancellation identity' using errcode='23514'; end if;
 elsif new.message_type in ('booking_reminder_24h','event_reminder_24h') then
 $branch$);
end;$$;

create function public.admin_cancel_event_v1(p_event_id uuid) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public,pg_temp as $$
declare e public.events%rowtype; total integer;
begin
 select * into e from public.events where id=p_event_id for update;
 if not found or coalesce(public.get_my_tenant_role_v1(e.tenant_id),'') not in ('admin','employee')
  or not public.get_my_tenant_feature_access_v1(e.tenant_id,'events') then
  raise exception 'Unavailable' using errcode='42501'; end if;
 if e.cancelled_at is not null then return jsonb_build_object('code','already_cancelled'); end if;
 if (e.event_date+e.end_time) at time zone 'Europe/Warsaw' <= clock_timestamp() then
  raise exception 'Past event unavailable' using errcode='22023'; end if;
 -- Lock recipient rows before the transition: cancellation vs self-cancel is serialized.
 perform 1 from public.event_registrations where event_id=e.id and tenant_id=e.tenant_id order by id for update;
 update public.events set cancelled_at=transaction_timestamp(),cancelled_by=auth.uid(),is_active=false where id=e.id;
 insert into public.email_deliveries(message_type,record_id,tenant_id,recipient_user_id,delivery_state)
 select 'event_cancellation',r.id,r.tenant_id,r.user_id,'pending' from public.event_registrations r
 where r.event_id=e.id and r.tenant_id=e.tenant_id and r.registration_status in ('registered','approved','reserve')
 and r.user_id is not null and r.pii_anonymized_at is null;
 get diagnostics total=row_count;
 return jsonb_build_object('code','cancelled','obligations',total);
end;$$;
revoke all on function public.admin_cancel_event_v1(uuid) from public,anon,authenticated,service_role;
grant execute on function public.admin_cancel_event_v1(uuid) to authenticated;

-- Existing positive claims: gate under an event lock, without touching sent history.
do $$declare def text; anchor text; begin
 def:=pg_get_functiondef('public.prepare_confirmation_email(text,uuid)'::regprocedure);
 anchor:='if v_message_type=''event_registration_confirmation'' then';
 if strpos(def,anchor)=0 then raise exception 'Confirmation baseline drift'; end if;
 execute replace(def,anchor,anchor||$gate$
    perform 1 from public.events e join public.event_registrations r on r.event_id=e.id and r.tenant_id=e.tenant_id
    where r.id=p_record_id and r.user_id=auth.uid() and e.cancelled_at is null for update of e;
    if not found then return jsonb_build_object('ok',false,'changed',false,'code','invalid_status'); end if;
 $gate$);
 def:=pg_get_functiondef('public.claim_event_reserve_acceptance_email_v1(uuid)'::regprocedure);
 anchor:='begin';
 execute overlay(def placing anchor||$gate$
 perform 1 from public.events e join public.event_registrations r on r.event_id=e.id and r.tenant_id=e.tenant_id
 where r.id=p_registration_id for update of e;
 if exists(select 1 from public.events e join public.event_registrations r on r.event_id=e.id and r.tenant_id=e.tenant_id
  where r.id=p_registration_id and e.cancelled_at is not null) then
  return jsonb_build_object('code','unavailable'); end if;
 $gate$ from strpos(def,anchor) for length(anchor));
 def:=pg_get_functiondef('public.prepare_event_reserve_promotions(uuid)'::regprocedure);
 anchor:='begin';
 execute overlay(def placing anchor||$gate$
 perform 1 from public.events e where e.id=p_event_id and e.cancelled_at is null for update;
 if not found then return; end if;
 $gate$ from strpos(def,anchor) for length(anchor));
end;$$;

create function public.claim_event_cancellation_batch_v1(p_event_id uuid) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public,pg_temp as $$
declare e public.events%rowtype; d public.email_deliveries%rowtype; stamp timestamptz:=clock_timestamp();
 lease uuid; result jsonb:='[]';
begin
 select * into e from public.events where id=p_event_id;
 if not found or e.cancelled_at is null or coalesce(public.get_my_continuity_role_core_v1(e.tenant_id),'') not in ('admin','employee') then
  raise exception 'Unavailable' using errcode='42501'; end if;
 -- A crashed final attempt must not remain sending forever. Preserve sent history.
 update public.email_deliveries target set delivery_state='failed',claim_id=null,claim_expires_at=null,
  last_error_code='retry_exhausted',updated_at=clock_timestamp()
 where target.id in (
  select x.id from public.email_deliveries x join public.event_registrations r on r.id=x.record_id
  where x.message_type='event_cancellation' and r.event_id=e.id and r.tenant_id=e.tenant_id
   and x.tenant_id=e.tenant_id and x.recipient_user_id=r.user_id and r.pii_anonymized_at is null and x.delivery_state<>'sent'
   and x.last_error_code is distinct from 'retry_exhausted'
   and (x.claim_expires_at is null or x.claim_expires_at<=clock_timestamp())
   and (x.attempt_count>=3 or x.attempt_window_started_at<=clock_timestamp()-interval '23 hours')
  order by x.id limit 5 for update of x skip locked
 );
 for d in select x.* from public.email_deliveries x join public.event_registrations r on r.id=x.record_id
  where x.message_type='event_cancellation' and r.event_id=e.id and r.tenant_id=e.tenant_id
   and x.tenant_id=e.tenant_id and x.recipient_user_id=r.user_id and r.pii_anonymized_at is null
   and x.delivery_state<>'sent' and (x.claim_expires_at is null or x.claim_expires_at<=stamp)
   and x.attempt_count<3 and (x.attempt_window_started_at is null or x.attempt_window_started_at>stamp-interval '23 hours')
  order by x.id limit 5 for update of x skip locked
 loop
  lease:=gen_random_uuid();
  update public.email_deliveries set delivery_state='sending',claim_id=lease,claim_expires_at=stamp+interval '5 minutes',
   attempt_count=attempt_count+1,attempt_window_started_at=coalesce(attempt_window_started_at,stamp),last_attempt_at=stamp,updated_at=stamp
   where id=d.id;
  result:=result||jsonb_build_array(jsonb_build_object('claim_id',lease,'registration_id',d.record_id,
   'tenant_id',d.tenant_id,'recipient_user_id',d.recipient_user_id,
   'idempotency_key','event-cancellation/'||e.id::text||'/'||d.record_id::text));
 end loop;
 return result;
end;$$;
revoke all on function public.claim_event_cancellation_batch_v1(uuid) from public,anon,authenticated,service_role;
grant execute on function public.claim_event_cancellation_batch_v1(uuid) to authenticated;

-- Reuse the proven completion state machine for the new, separate logical type.
do $$declare def text; begin
 def:=pg_get_functiondef('public.complete_event_registration_cancellation_email_v1(uuid,boolean,text)'::regprocedure);
 def:=replace(def,'complete_event_registration_cancellation_email_v1','complete_event_cancellation_email_v1');
 def:=replace(def,'''event_registration_cancellation''','''event_cancellation''');
 execute def;
end;$$;
revoke all on function public.complete_event_cancellation_email_v1(uuid,boolean,text) from public,anon,authenticated,service_role;
grant execute on function public.complete_event_cancellation_email_v1(uuid,boolean,text) to service_role;
create function public.purge_event_cancellation_deliveries_v1() returns integer
language plpgsql security invoker set search_path=pg_catalog,public,pg_temp as $$
declare removed integer; begin
 delete from public.email_deliveries where message_type='event_cancellation'
 and delivery_state in ('sent','failed') and updated_at<clock_timestamp()-interval '90 days';
 get diagnostics removed=row_count; return removed;
end;$$;
revoke all on function public.purge_event_cancellation_deliveries_v1() from public,anon,authenticated,service_role;

-- No new admission here: only the exact existing claim, within its DB-clock lease.
-- Every new claim (including reclaim after crash) locks events and checks cancellation above.
create function public.check_event_email_dispatch_lease_v1(p_claim_id uuid,p_kind text) returns boolean
language sql volatile security invoker set search_path=pg_catalog,public,pg_temp as $$
 select case when p_kind='promotion' then exists(
  select 1 from public.event_registrations r where r.promotion_claim_id=p_claim_id
   and r.promotion_claim_expires_at>clock_timestamp() and r.promotion_email_sent_at is null
   and r.registration_status='reserve' and r.pii_anonymized_at is null
 ) when p_kind in ('registration','acceptance') then exists(
  select 1 from public.email_deliveries d join public.event_registrations r on r.id=d.record_id
   and r.tenant_id=d.tenant_id and r.user_id=d.recipient_user_id
  where d.claim_id=p_claim_id and d.claim_expires_at>clock_timestamp() and d.sent_at is null
   and d.message_type=case p_kind when 'registration' then 'event_registration_confirmation' else 'event_reserve_acceptance_confirmation' end
   and r.pii_anonymized_at is null
   and r.registration_status in ('registered','reserve')
 ) else false end;
$$;
revoke all on function public.check_event_email_dispatch_lease_v1(uuid,text) from public,anon,authenticated,service_role;
grant execute on function public.check_event_email_dispatch_lease_v1(uuid,text) to service_role;
commit;
