-- D5-C: bounded claim batch and per-function lock waits; no authority change.
begin;
set local lock_timeout='2s';
create or replace function public.claim_reminders_v1() returns jsonb
language plpgsql security definer set search_path=pg_catalog,public,pg_temp as $$
declare d public.email_deliveries%rowtype; o public.reminder_occurrences%rowtype; src record;
 result jsonb:='[]'; lease uuid; stamp timestamptz:=clock_timestamp();
begin
 -- Expired final attempts become terminal rather than remaining sending forever.
 update public.email_deliveries set delivery_state='failed',claim_id=null,claim_expires_at=null,
  last_error_code='attempt_limit_reached',updated_at=stamp
 where id in (select id from public.email_deliveries
  where message_type in ('booking_reminder_24h','event_reminder_24h') and delivery_state='sending'
  and attempt_count>=3 and claim_expires_at<=stamp limit 25 for update skip locked);
 for d in select * from public.email_deliveries where message_type in ('booking_reminder_24h','event_reminder_24h')
  and delivery_state in ('pending','failed','sending') and attempt_count<3
  and (claim_id is null or claim_expires_at<=stamp) and coalesce(last_error_code,'')<>'ineligible'
  order by created_at limit 5 for update skip locked loop
  -- Each locked row gets a fresh decision time; statement time is discovery-only.
  stamp:=clock_timestamp();
  select * into o from public.reminder_occurrences where id=d.record_id;
  select * into src from public.reminder_source_v1(d.message_type,coalesce(o.reservation_id,o.registration_id));
  if not found or src.scheduled_start<=stamp+interval '1 hour'
   or src.generation<>o.generation or src.scheduled_start<>o.scheduled_start
   or src.tenant_id<>d.tenant_id or src.user_id<>d.recipient_user_id then
   update public.email_deliveries set delivery_state='failed',claim_id=null,claim_expires_at=null,
    last_error_code='ineligible',updated_at=stamp where id=d.id;
   continue;
  end if;
  lease:=gen_random_uuid();
  update public.email_deliveries set delivery_state='sending',claim_id=lease,claim_expires_at=stamp+interval '5 minutes',
   attempt_count=attempt_count+1,attempt_window_started_at=coalesce(attempt_window_started_at,stamp),last_attempt_at=stamp,
   last_error_code=null,updated_at=stamp where id=d.id;
  result:=result||jsonb_build_array(jsonb_build_object('claim_id',lease,'occurrence_id',o.id,
   'idempotency_key',d.message_type||'/'||o.id::text));
 end loop;
 return result;
end;$$;


-- lock_timeout takes effect inside functions. statement_timeout is also exposed
-- as function config for PostgREST; HTTP abort alone is NOT server cancellation.
alter function public.discover_reminders_v1() set lock_timeout='2s';
alter function public.discover_reminders_v1() set statement_timeout='4s';
alter function public.claim_reminders_v1() set lock_timeout='2s';
alter function public.claim_reminders_v1() set statement_timeout='4s';
alter function public.final_check_reminder_v1(uuid) set lock_timeout='2s';
alter function public.final_check_reminder_v1(uuid) set statement_timeout='4s';
alter function public.complete_reminder_v1(uuid,boolean,text) set lock_timeout='2s';
alter function public.complete_reminder_v1(uuid,boolean,text) set statement_timeout='4s';
commit;
