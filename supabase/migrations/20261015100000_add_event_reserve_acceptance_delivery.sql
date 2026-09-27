-- PRODUCT-10G-C: durable acceptance receipt; no scheduler, no lifecycle widening.
begin;
set local lock_timeout='5s';
set local statement_timeout='60s';

alter table public.email_deliveries drop constraint email_deliveries_message_type_check;
alter table public.email_deliveries add constraint email_deliveries_message_type_check
 check(message_type in ('event_registration_confirmation','reservation_confirmation',
 'reservation_cancellation','event_reserve_acceptance_confirmation'));
-- NULL for old contracts: their semantics and completion RPC remain unchanged.
alter table public.email_deliveries add column delivery_state text;
alter table public.email_deliveries add constraint email_deliveries_acceptance_state_check check (
 (message_type<>'event_reserve_acceptance_confirmation' and delivery_state is null) or
 (message_type='event_reserve_acceptance_confirmation' and delivery_state is not null and (
  (delivery_state='pending' and sent_at is null and claim_id is null and attempt_count=0) or
  (delivery_state='sending' and sent_at is null and claim_id is not null and attempt_count between 1 and 3) or
  (delivery_state='sent' and sent_at is not null and claim_id is null and attempt_count between 1 and 3) or
  (delivery_state='failed' and sent_at is null and claim_id is null and attempt_count between 1 and 3)
 )));

create or replace function public.set_email_delivery_tenant_id()
returns trigger language plpgsql security invoker set search_path=pg_catalog
as $$
declare v_tenant_id uuid; v_user_id uuid;
begin
 if new.message_type in ('reservation_confirmation','reservation_cancellation') then
  select r.tenant_id into v_tenant_id from public.reservations r where r.id=new.record_id;
 elsif new.message_type in ('event_registration_confirmation','event_reserve_acceptance_confirmation') then
  select r.tenant_id,r.user_id into v_tenant_id,v_user_id from public.event_registrations r
   join public.events e on e.id=r.event_id and e.tenant_id=r.tenant_id where r.id=new.record_id;
  if new.message_type='event_reserve_acceptance_confirmation' and
    (v_user_id is null or new.recipient_user_id is distinct from v_user_id) then
   raise exception 'email_delivery_recipient_mismatch' using errcode='23514';
  end if;
 else raise exception 'unsupported_email_delivery_message_type' using errcode='23514'; end if;
 if v_tenant_id is null then raise exception 'email_delivery_target_not_found' using errcode='23503'; end if;
 if new.tenant_id is not null and new.tenant_id is distinct from v_tenant_id then
  raise exception 'email_delivery_tenant_mismatch' using errcode='23514';
 end if;
 if new.message_type='event_reserve_acceptance_confirmation' then
  if tg_op='INSERT' then
   -- Serialize creation against lifecycle suspension. A suspended retry can only
   -- use a row created while active, after the authorized acceptance succeeded.
   perform 1 from public.tenants where id=v_tenant_id and status='active' for share;
   if not found then raise exception 'acceptance_delivery_requires_active_tenant' using errcode='42501'; end if;
   if not exists(select 1 from public.event_registrations r where r.id=new.record_id
    and r.registration_status='registered' and r.promotion_confirmed_at is not null
    and r.pii_anonymized_at is null) then
    raise exception 'acceptance_delivery_requires_prior_acceptance' using errcode='23514';
   end if;
  elsif old.message_type is distinct from new.message_type
    or old.record_id is distinct from new.record_id
    or old.recipient_user_id is distinct from new.recipient_user_id
    or old.tenant_id is distinct from v_tenant_id then
   raise exception 'acceptance_delivery_identity_immutable' using errcode='23514';
  end if;
 end if;
 new.tenant_id:=v_tenant_id;
 return new;
end;$$;

-- Existing owner/membership checks and core lifecycle triggers stay authoritative.
-- The INSERT is in the SAME RPC transaction as reserve -> registered.
create or replace function public.confirm_event_reserve_promotion(p_token text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,pg_temp
as $$
declare v_actor uuid:=auth.uid(); v_tenant uuid; v_owner uuid; result jsonb;
begin
 if v_actor is null then raise exception 'Authentication is required.' using errcode='42501'; end if;
 if p_token is null or btrim(p_token)='' then
  return public.confirm_event_reserve_promotion__saas9d2a_core(p_token);
 end if;
 select r.tenant_id,r.user_id into v_tenant,v_owner from public.event_registrations r
 where r.promotion_token=btrim(p_token);
 if not found then return public.confirm_event_reserve_promotion__saas9d2a_core(p_token); end if;
 if v_owner is distinct from v_actor or not public.is_tenant_member_v1(v_tenant) then
  raise exception 'You cannot confirm this registration.' using errcode='42501';
 end if;
 result:=public.confirm_event_reserve_promotion__saas9d2a_core(p_token);
 if result->>'code'='confirmed' and (result->>'ok')::boolean then
  insert into public.email_deliveries(tenant_id,message_type,record_id,recipient_user_id,delivery_state)
  select r.tenant_id,'event_reserve_acceptance_confirmation',r.id,r.user_id,'pending'
  from public.event_registrations r join public.events e on e.id=r.event_id and e.tenant_id=r.tenant_id
  where r.id=(result->>'registration_id')::uuid and r.user_id=v_actor
   and r.tenant_id=v_tenant and r.registration_status='registered' and r.promotion_confirmed_at is not null;
  if not found then raise exception 'Acceptance receipt invariant failed' using errcode='23514'; end if;
 end if;
 return result;
end;$$;

create function public.claim_event_reserve_acceptance_email_v1(p_registration_id uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,pg_temp
as $$
declare d public.email_deliveries%rowtype; claim uuid; now_at timestamptz:=clock_timestamp();
begin
 select x.* into d from public.email_deliveries x
 where x.message_type='event_reserve_acceptance_confirmation' and x.record_id=p_registration_id for update;
 if not found then return jsonb_build_object('code','not_found'); end if;
 if d.delivery_state='sent' then return jsonb_build_object('code','already_sent'); end if;
 -- Same resource, same owner; no caller tenant/user/email inputs. Suspended receipts
 -- only communicate an already accepted obligation, never promote/accept a seat.
 if not exists(select 1 from public.event_registrations r
  join public.events e on e.id=r.event_id and e.tenant_id=r.tenant_id
  join public.tenants t on t.id=e.tenant_id
  where r.id=d.record_id and r.tenant_id=d.tenant_id and r.user_id=d.recipient_user_id
   and r.registration_status='registered' and r.promotion_confirmed_at is not null
   and r.pii_anonymized_at is null and t.status in ('active','suspended')) then
  return jsonb_build_object('code','unavailable');
 end if;
 if d.claim_id is not null and d.claim_expires_at>now_at then return jsonb_build_object('code','in_progress'); end if;
 -- Never blindly resend beyond the provider's 24h deduplication window.
 if d.attempt_count>=3 or d.attempt_window_started_at<=now_at-interval '23 hours' then
  update public.email_deliveries set delivery_state='failed',claim_id=null,claim_expires_at=null,
   last_error_code=case when d.attempt_count>=3 then 'attempt_limit_reached' else 'retry_window_expired' end,
   updated_at=case when d.delivery_state='failed' then d.updated_at else now_at end where id=d.id;
  return jsonb_build_object('code','retry_exhausted');
 end if;
 claim:=gen_random_uuid();
 update public.email_deliveries set delivery_state='sending',claim_id=claim,claim_expires_at=now_at+interval '5 minutes',
  attempt_count=attempt_count+1,attempt_window_started_at=coalesce(attempt_window_started_at,now_at),
  last_attempt_at=now_at,last_error_code=null,updated_at=now_at where id=d.id;
 return jsonb_build_object('code','ready','claim_id',claim,'registration_id',d.record_id,
  'tenant_id',d.tenant_id,'recipient_user_id',d.recipient_user_id,
  'idempotency_key','event-reserve-acceptance/'||d.tenant_id::text||'/'||d.record_id::text);
end;$$;

create function public.complete_event_reserve_acceptance_email_v1(p_claim_id uuid,p_success boolean,p_provider_message_id text default null)
returns jsonb language plpgsql security invoker set search_path=pg_catalog,public,pg_temp
as $$
declare d public.email_deliveries%rowtype; now_at timestamptz:=clock_timestamp();
begin
 select x.* into d from public.email_deliveries x where x.claim_id=p_claim_id
  and x.message_type='event_reserve_acceptance_confirmation' for update;
 if not found or d.delivery_state<>'sending' or d.claim_expires_at<=now_at then
  return jsonb_build_object('code','claim_not_found'); end if;
 if p_success is null or (p_success and (p_provider_message_id is null or p_provider_message_id!~'^[A-Za-z0-9_-]{1,128}$')) then
  raise exception 'Invalid completion' using errcode='22023'; end if;
 update public.email_deliveries set delivery_state=case when p_success then 'sent' else 'failed' end,
  sent_at=case when p_success then now_at else null end,
  provider_message_id=case when p_success then p_provider_message_id else null end,
  claim_id=null,claim_expires_at=null,last_error_code=case when p_success then null else 'delivery_failed_or_uncertain' end,
  updated_at=now_at where id=d.id;
 return jsonb_build_object('code',case when p_success then 'sent' else 'failed' end);
end;$$;

-- Operator-invoked retention only; no scheduled worker. Account deletion already
-- deletes email_deliveries by recipient_user_id, including this message type.
create function public.purge_event_reserve_acceptance_deliveries_v1()
returns integer language plpgsql security invoker set search_path=pg_catalog,public,pg_temp
as $$
declare removed integer;
begin
 delete from public.email_deliveries where message_type='event_reserve_acceptance_confirmation'
 and delivery_state in ('sent','failed') and updated_at<clock_timestamp()-interval '90 days';
 get diagnostics removed=row_count; return removed;
end;$$;

revoke all on function public.set_email_delivery_tenant_id() from public,anon,authenticated,service_role;
revoke all on function public.confirm_event_reserve_promotion(text) from public,anon,authenticated,service_role;
grant execute on function public.confirm_event_reserve_promotion(text) to authenticated;
revoke all on function public.claim_event_reserve_acceptance_email_v1(uuid) from public,anon,authenticated,service_role;
revoke all on function public.complete_event_reserve_acceptance_email_v1(uuid,boolean,text) from public,anon,authenticated,service_role;
revoke all on function public.purge_event_reserve_acceptance_deliveries_v1() from public,anon,authenticated,service_role;
grant execute on function public.claim_event_reserve_acceptance_email_v1(uuid) to service_role;
grant execute on function public.complete_event_reserve_acceptance_email_v1(uuid,boolean,text) to service_role;
-- No table grants, no RLS changes, no change to confirmation core/entitlements.
commit;
