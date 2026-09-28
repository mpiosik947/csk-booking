-- PRODUCT-10G-D: occurrence-scoped reminders. No scheduler activation.
begin;
set local lock_timeout='5s';
set local statement_timeout='60s';

create table public.reminder_schedules (
 id uuid primary key default gen_random_uuid(),
 reservation_id uuid unique references public.reservations(id) on delete cascade,
 event_id uuid unique references public.events(id) on delete cascade,
 generation bigint not null default 1 check(generation>0),
 scheduled_start timestamptz not null,
 changed_at timestamptz not null default clock_timestamp(),
 check(num_nonnulls(reservation_id,event_id)=1)
);
create table public.reminder_occurrences (
 id uuid primary key default gen_random_uuid(),
 message_type text not null check(message_type in ('booking_reminder_24h','event_reminder_24h')),
 schedule_id uuid not null references public.reminder_schedules(id) on delete cascade,
 reservation_id uuid references public.reservations(id) on delete cascade,
 registration_id uuid references public.event_registrations(id) on delete cascade,
 generation bigint not null check(generation>0),
 scheduled_start timestamptz not null,
 created_at timestamptz not null default clock_timestamp(),
 check((message_type='booking_reminder_24h' and reservation_id is not null and registration_id is null)
    or (message_type='event_reminder_24h' and registration_id is not null and reservation_id is null))
);
create unique index reminder_booking_occurrence on public.reminder_occurrences(reservation_id,generation) where reservation_id is not null;
create unique index reminder_event_occurrence on public.reminder_occurrences(registration_id,generation) where registration_id is not null;
alter table public.reminder_schedules enable row level security;
alter table public.reminder_occurrences enable row level security;
revoke all on public.reminder_schedules,public.reminder_occurrences from public,anon,authenticated,service_role;

-- No resource columns or lifecycle authority are changed. Every schedule change,
-- including A -> B -> A, advances a DB-owned generation under the resource lock.
create function public.track_reminder_schedule_v1() returns trigger
language plpgsql security definer set search_path=pg_catalog,public,pg_temp as $$
declare stamp timestamptz;
begin
 if tg_table_name='reservations' then
  stamp:=(new.reservation_date+new.start_time) at time zone 'Europe/Warsaw';
  insert into public.reminder_schedules(reservation_id,scheduled_start) values(new.id,stamp)
  on conflict(reservation_id) do update set scheduled_start=excluded.scheduled_start,
   generation=reminder_schedules.generation+1,changed_at=clock_timestamp()
  where reminder_schedules.scheduled_start is distinct from excluded.scheduled_start;
 else
  stamp:=(new.event_date+new.start_time) at time zone 'Europe/Warsaw';
  insert into public.reminder_schedules(event_id,scheduled_start) values(new.id,stamp)
  on conflict(event_id) do update set scheduled_start=excluded.scheduled_start,
   generation=reminder_schedules.generation+1,changed_at=clock_timestamp()
  where reminder_schedules.scheduled_start is distinct from excluded.scheduled_start;
 end if;
 return new;
end;$$;
insert into public.reminder_schedules(reservation_id,scheduled_start)
select id,(reservation_date+start_time) at time zone 'Europe/Warsaw' from public.reservations;
insert into public.reminder_schedules(event_id,scheduled_start)
select id,(event_date+start_time) at time zone 'Europe/Warsaw' from public.events;
create trigger track_booking_reminder_schedule after insert or update of reservation_date,start_time on public.reservations
for each row execute function public.track_reminder_schedule_v1();
create trigger track_event_reminder_schedule after insert or update of event_date,start_time on public.events
for each row execute function public.track_reminder_schedule_v1();

-- Internal eligibility projection. No caller tenant/recipient/schedule authority.
create function public.reminder_source_v1(p_type text,p_resource uuid)
returns table(tenant_id uuid,user_id uuid,schedule_id uuid,generation bigint,scheduled_start timestamptz,
 recipient text,title text,local_date date,start_time time,end_time time,location text)
language sql stable security invoker set search_path=pg_catalog,public,pg_temp as $$
 select r.tenant_id,r.user_id,s.id,s.generation,s.scheduled_start,r.customer_email,
  'Rezerwacja'::text,r.reservation_date,r.start_time,r.end_time,l.name
 from public.reservations r join public.shooting_lanes l on l.id=r.lane_id and l.tenant_id=r.tenant_id
 join public.tenants t on t.id=r.tenant_id join public.reminder_schedules s on s.reservation_id=r.id
 where p_type='booking_reminder_24h' and r.id=p_resource and r.reservation_status='confirmed'
 and r.pii_anonymized_at is null and r.user_id is not null and nullif(btrim(r.customer_email),'') is not null
 and t.status in ('active','suspended') and r.created_at<=s.scheduled_start-interval '24 hours'
 and s.scheduled_start>statement_timestamp()+interval '1 hour' and s.scheduled_start<=statement_timestamp()+interval '24 hours'
 union all
 select e.tenant_id,r.user_id,s.id,s.generation,s.scheduled_start,r.customer_email,e.title,
  e.event_date,e.start_time,e.end_time,e.location
 from public.event_registrations r join public.events e on e.id=r.event_id and e.tenant_id=r.tenant_id
 join public.tenants t on t.id=e.tenant_id join public.reminder_schedules s on s.event_id=e.id
 where p_type='event_reminder_24h' and r.id=p_resource and r.registration_status='registered' and e.is_active
 and r.pii_anonymized_at is null and r.user_id is not null and nullif(btrim(r.customer_email),'') is not null
 and t.status in ('active','suspended') and greatest(r.created_at,e.created_at)<=s.scheduled_start-interval '24 hours'
 and s.scheduled_start>statement_timestamp()+interval '1 hour' and s.scheduled_start<=statement_timestamp()+interval '24 hours';
$$;

alter table public.email_deliveries drop constraint email_deliveries_message_type_check;
alter table public.email_deliveries add constraint email_deliveries_message_type_check check(message_type in (
 'event_registration_confirmation','reservation_confirmation','reservation_cancellation',
 'event_reserve_acceptance_confirmation','event_registration_cancellation','booking_reminder_24h','event_reminder_24h'));
-- Preserve old state validation verbatim, separately validate the new types.
do $$declare def text; begin
 select pg_get_constraintdef(oid) into def from pg_constraint where conrelid='public.email_deliveries'::regclass
 and conname='email_deliveries_acceptance_state_check';
 if def is null then raise exception 'Missing state baseline'; end if;
 execute 'alter table public.email_deliveries drop constraint email_deliveries_acceptance_state_check';
 execute 'alter table public.email_deliveries add constraint email_deliveries_acceptance_state_check CHECK (message_type IN (''booking_reminder_24h'',''event_reminder_24h'') OR '||substring(def from 7)||')';
end;$$;
alter table public.email_deliveries add constraint reminder_delivery_state_check check(
 message_type not in ('booking_reminder_24h','event_reminder_24h') or
 (delivery_state is not null and (
 (delivery_state='pending' and sent_at is null and claim_id is null and attempt_count=0) or
 (delivery_state='sending' and sent_at is null and claim_id is not null and claim_expires_at is not null and attempt_count between 1 and 3) or
 (delivery_state='sent' and sent_at is not null and claim_id is null and attempt_count between 1 and 3) or
 (delivery_state='failed' and sent_at is null and claim_id is null and attempt_count between 0 and 3))));

-- Extend binding only for new message types; legacy body and unique remain intact.
do $$declare def text; anchor text:='if new.message_type=''event_registration_cancellation'' then'; begin
 def:=pg_get_functiondef('public.set_email_delivery_tenant_id()'::regprocedure);
 if strpos(def,anchor)=0 then raise exception 'Binding baseline mismatch'; end if;
 execute replace(def,anchor,$branch$
 if tg_op='UPDATE' and old.message_type in ('booking_reminder_24h','event_reminder_24h') and
 (new.message_type,new.record_id,new.tenant_id,new.recipient_user_id) is distinct from
 (old.message_type,old.record_id,old.tenant_id,old.recipient_user_id) then
 raise exception 'Reminder identity immutable' using errcode='23514'; end if;
 if new.message_type in ('booking_reminder_24h','event_reminder_24h') then
  if current_user<>'postgres' then raise exception 'Use reminder RPC' using errcode='42501'; end if;
  select coalesce(b.tenant_id,e.tenant_id),coalesce(b.user_id,r.user_id) into v_tenant_id,v_user_id
  from public.reminder_occurrences o left join public.reservations b on b.id=o.reservation_id
  left join public.event_registrations r on r.id=o.registration_id
  left join public.events e on e.id=r.event_id and e.tenant_id=r.tenant_id
  where o.id=new.record_id and o.message_type=new.message_type;
  if v_tenant_id is null or new.recipient_user_id is distinct from v_user_id then
   raise exception 'Reminder binding invalid' using errcode='23514'; end if;
 elsif new.message_type='event_registration_cancellation' then
 $branch$);
end;$$;

create function public.discover_reminders_v1() returns integer
language plpgsql security definer set search_path=pg_catalog,public,pg_temp as $$
declare c record; src record; oid uuid; count_new integer:=0;
begin
 -- Bounded discovery and a transaction-level scheduler lock prevent overlapping scans.
 if not pg_try_advisory_xact_lock(1070171000) then return 0; end if;
 for c in select 'booking_reminder_24h'::text kind,r.id from public.reservations r
  join public.reminder_schedules s on s.reservation_id=r.id
  cross join lateral public.reminder_source_v1('booking_reminder_24h',r.id) eligible
  where s.scheduled_start>statement_timestamp()+interval '1 hour' and s.scheduled_start<=statement_timestamp()+interval '24 hours'
  and not exists(select 1 from public.reminder_occurrences o where o.reservation_id=r.id and o.generation=s.generation)
 union all select 'event_reminder_24h',r.id from public.event_registrations r
  join public.reminder_schedules s on s.event_id=r.event_id
  cross join lateral public.reminder_source_v1('event_reminder_24h',r.id) eligible
  where s.scheduled_start>statement_timestamp()+interval '1 hour' and s.scheduled_start<=statement_timestamp()+interval '24 hours'
  and not exists(select 1 from public.reminder_occurrences o where o.registration_id=r.id and o.generation=s.generation)
 limit 100 loop
  select * into src from public.reminder_source_v1(c.kind,c.id);
  if not found then continue; end if;
  oid:=null;
  insert into public.reminder_occurrences(message_type,schedule_id,reservation_id,registration_id,generation,scheduled_start)
  values(c.kind,src.schedule_id,case when c.kind='booking_reminder_24h' then c.id end,
   case when c.kind='event_reminder_24h' then c.id end,src.generation,src.scheduled_start)
  on conflict do nothing returning id into oid;
  if oid is not null then
   insert into public.email_deliveries(message_type,record_id,tenant_id,recipient_user_id,delivery_state)
   values(c.kind,oid,src.tenant_id,src.user_id,'pending');
   count_new:=count_new+1;
  end if;
 end loop;
 return count_new;
end;$$;

create function public.claim_reminders_v1() returns jsonb
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
  order by created_at limit 25 for update skip locked loop
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

create function public.final_check_reminder_v1(p_claim_id uuid) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public,pg_temp as $$
declare d public.email_deliveries%rowtype; o public.reminder_occurrences%rowtype; src record; branding record;
begin
 select * into d from public.email_deliveries where claim_id=p_claim_id
 and message_type in ('booking_reminder_24h','event_reminder_24h') for update;
 if not found or d.delivery_state<>'sending' or d.claim_expires_at<=clock_timestamp() then return null; end if;
 select * into o from public.reminder_occurrences where id=d.record_id;
 select * into src from public.reminder_source_v1(d.message_type,coalesce(o.reservation_id,o.registration_id));
 if not found or src.generation<>o.generation or src.scheduled_start<>o.scheduled_start
  or src.tenant_id<>d.tenant_id or src.user_id<>d.recipient_user_id then
  update public.email_deliveries set delivery_state='failed',claim_id=null,claim_expires_at=null,
   last_error_code='ineligible',updated_at=clock_timestamp() where id=d.id;
  return null;
 end if;
 select * into branding from public.resolve_operational_email_tenant_context_v1(
  case when o.reservation_id is not null then 'reservation' else 'event_registration' end,
  coalesce(o.reservation_id,o.registration_id));
 if branding.tenant_id is distinct from src.tenant_id then return null; end if;
 -- Re-read wall clock after the delivery lock and all eligibility/branding reads.
 -- statement_timestamp() predates any lock wait and cannot authorize a send.
 if src.scheduled_start<=clock_timestamp()+interval '1 hour'
  or d.claim_expires_at<=clock_timestamp() then
  update public.email_deliveries set delivery_state='failed',claim_id=null,claim_expires_at=null,
   last_error_code='ineligible',updated_at=clock_timestamp() where id=d.id;
  return null;
 end if;
 return jsonb_build_object('kind',d.message_type,'occurrence_id',o.id,'idempotency_key',d.message_type||'/'||o.id::text,
  'recipient',src.recipient,'title',src.title,'date',src.local_date,'start',src.start_time,'end',src.end_time,
  'location',src.location,'tenant_slug',branding.tenant_slug,'display_name',branding.display_name);
end;$$;

create function public.complete_reminder_v1(p_claim_id uuid,p_success boolean,p_provider_message_id text default null)
returns boolean language plpgsql security definer set search_path=pg_catalog,public,pg_temp as $$
declare d public.email_deliveries%rowtype;
begin
 if p_success is null or (p_success and (p_provider_message_id is null or p_provider_message_id!~'^[A-Za-z0-9_-]{1,128}$')) then
 raise exception 'Invalid completion' using errcode='22023'; end if;
 -- Do not evaluate lease validity before a potentially blocking UPDATE lock.
 select * into d from public.email_deliveries where claim_id=p_claim_id
 and message_type in ('booking_reminder_24h','event_reminder_24h') for update;
 if not found or d.delivery_state<>'sending' or d.claim_expires_at<=clock_timestamp() then return false; end if;
 update public.email_deliveries set delivery_state=case when p_success then 'sent' else 'failed' end,
 sent_at=case when p_success then clock_timestamp() end,provider_message_id=case when p_success then p_provider_message_id end,
 claim_id=null,claim_expires_at=null,last_error_code=case when p_success then null else 'delivery_failed_or_uncertain' end,
 updated_at=clock_timestamp() where claim_id=p_claim_id and claim_expires_at>clock_timestamp()
 and message_type in ('booking_reminder_24h','event_reminder_24h') and delivery_state='sending';
 return found;
end;$$;
create function public.purge_reminder_deliveries_v1() returns integer
language plpgsql security definer set search_path=pg_catalog,public,pg_temp as $$
declare n integer; begin
 delete from public.email_deliveries where message_type in ('booking_reminder_24h','event_reminder_24h')
 and delivery_state in ('sent','failed') and updated_at<clock_timestamp()-interval '90 days';
 get diagnostics n=row_count; return n;
end;$$;
revoke all on function public.track_reminder_schedule_v1(),public.reminder_source_v1(text,uuid),
 public.discover_reminders_v1(),public.claim_reminders_v1(),public.final_check_reminder_v1(uuid),
 public.complete_reminder_v1(uuid,boolean,text),public.purge_reminder_deliveries_v1() from public,anon,authenticated,service_role;
grant execute on function public.discover_reminders_v1(),public.claim_reminders_v1(),
 public.final_check_reminder_v1(uuid),public.complete_reminder_v1(uuid,boolean,text) to service_role;
-- Purge is operator-only. Registry survives purge/anonymization; resource deletion cascades.
commit;
