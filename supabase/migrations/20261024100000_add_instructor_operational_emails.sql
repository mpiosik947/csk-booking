-- INSTRUCTOR-1F DRAFT. Transition-only outbox; no backfill or scheduler.
begin;
set local lock_timeout='5s';
set local statement_timeout='60s';

alter table public.email_deliveries drop constraint email_deliveries_message_type_check;
alter table public.email_deliveries add constraint email_deliveries_message_type_check check(message_type in (
 'event_registration_confirmation','reservation_confirmation','reservation_cancellation',
 'event_reserve_acceptance_confirmation','event_registration_cancellation','booking_reminder_24h',
 'event_reminder_24h','event_cancellation','instructor_assignment','instructor_removal','instructor_event_cancellation'));
do $$declare d text;begin
 select pg_get_constraintdef(oid) into d from pg_constraint
 where conrelid='public.email_deliveries'::regclass and conname='email_deliveries_acceptance_state_check';
 if d is null or strpos(d,'''event_cancellation''::text')=0 then raise exception 'Delivery state baseline drift';end if;
 d:=replace(d,'''event_cancellation''::text','''event_cancellation''::text, ''instructor_assignment''::text, ''instructor_removal''::text, ''instructor_event_cancellation''::text');
 alter table public.email_deliveries drop constraint email_deliveries_acceptance_state_check;
 execute 'alter table public.email_deliveries add constraint email_deliveries_acceptance_state_check '||d;
end;$$;

-- Explicit assignment resource binding; existing registration semantics unchanged.
do $$declare d text;a text:='begin';begin
 d:=pg_get_functiondef('public.set_email_delivery_tenant_id()'::regprocedure);
 if strpos(d,a)=0 then raise exception 'Delivery binding baseline drift';end if;
 execute overlay(d placing a||$binding$
 if tg_op='UPDATE' and old.message_type in ('instructor_assignment','instructor_removal','instructor_event_cancellation')
  and (new.message_type,new.record_id,new.tenant_id,new.recipient_user_id) is distinct from
      (old.message_type,old.record_id,old.tenant_id,old.recipient_user_id) then
  raise exception 'Immutable instructor delivery identity' using errcode='23514';end if;
 if new.message_type in ('instructor_assignment','instructor_removal','instructor_event_cancellation') then
  if current_user<>'postgres' then raise exception 'Use instructor delivery contract' using errcode='42501';end if;
  select i.tenant_id,i.instructor_user_id into v_tenant_id,v_user_id from public.event_instructors i
   join public.events e on e.id=i.event_id and e.tenant_id=i.tenant_id where i.id=new.record_id;
  if v_user_id is null or new.recipient_user_id is distinct from v_user_id
   or new.tenant_id is distinct from v_tenant_id then
   raise exception 'Instructor delivery binding mismatch' using errcode='23514';end if;
  -- Only the two transition triggers can insert. No prepare/recreate endpoint exists.
  if tg_op='INSERT' and pg_catalog.pg_trigger_depth()<2 then
   raise exception 'Instructor obligation is transition-only' using errcode='42501';end if;
  return new;
 end if;
 $binding$ from strpos(d,a) for length(a));
end;$$;

create function public.queue_instructor_assignment_email_v1() returns trigger
language plpgsql security invoker set search_path=pg_catalog,public,pg_temp as $$
declare kind text;
begin
 if tg_op='INSERT' and new.unassigned_at is null then kind:='instructor_assignment';
 elsif tg_op='UPDATE' and old.unassigned_at is null and new.unassigned_at is not null then kind:='instructor_removal';
 else return new;end if;
 -- Privacy FK nulling is not a business transition and must never generate mail.
 if new.instructor_user_id is null then return new;end if;
 insert into public.email_deliveries(message_type,record_id,tenant_id,recipient_user_id,delivery_state)
 values(kind,new.id,new.tenant_id,new.instructor_user_id,'pending');
 return new;
end;$$;
create trigger queue_instructor_assignment_email after insert or update on public.event_instructors
 for each row execute function public.queue_instructor_assignment_email_v1();

create function public.queue_instructor_cancellation_email_v1() returns trigger
language plpgsql security invoker set search_path=pg_catalog,public,pg_temp as $$
begin
 if old.cancelled_at is null and new.cancelled_at is not null then
  insert into public.email_deliveries(message_type,record_id,tenant_id,recipient_user_id,delivery_state)
  select 'instructor_event_cancellation',i.id,i.tenant_id,i.instructor_user_id,'pending'
   from public.event_instructors i where i.event_id=new.id and i.tenant_id=new.tenant_id
    and i.unassigned_at is null and i.instructor_user_id is not null;
 end if;
 return new;
end;$$;
create trigger queue_instructor_cancellation_email after update of cancelled_at on public.events
 for each row execute function public.queue_instructor_cancellation_email_v1();

-- Browser may authorize an explicit staff action, never claim or obtain recipients.
create function public.authorize_instructor_email_batch_v1(p_event_id uuid) returns boolean
language plpgsql stable security definer set search_path=pg_catalog,public,pg_temp as $$
declare tenant uuid;begin
 select tenant_id into tenant from public.events where id=p_event_id;
 if not found or auth.uid() is null or coalesce(public.get_my_continuity_role_core_v1(tenant),'') not in ('admin','employee') then
  raise exception 'Not authorized' using errcode='42501';end if;
 return true;
end;$$;

-- Each new claim IS dispatch admission. Same event lock as staffing/cancellation.
-- Return only handles; recipient and content are read by the server lease reader.
create function public.claim_instructor_email_batch_v1(p_event_id uuid) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public,pg_temp as $$
declare e public.events%rowtype;d public.email_deliveries%rowtype;life text;
 stamp timestamptz;lease uuid;result jsonb:='[]';
begin
 select * into e from public.events where id=p_event_id for update;
 if not found then return result;end if;
 select status into life from public.tenants where id=e.tenant_id for share;
 if life is null or life not in ('active','suspended') then return result;end if;
 -- Stabilize profile/membership eligibility in canonical privacy lock order.
 perform 1 from public.profiles p join public.event_instructors i on i.instructor_user_id=p.user_id
  where i.event_id=e.id and i.tenant_id=e.tenant_id order by p.user_id for key share of p;
 perform 1 from public.tenant_memberships m join public.event_instructors i
  on i.instructor_user_id=m.user_id and i.tenant_id=m.tenant_id
  where i.event_id=e.id and i.tenant_id=e.tenant_id order by m.user_id for share of m;
 stamp:=clock_timestamp();
 update public.email_deliveries x set delivery_state='failed',claim_id=null,claim_expires_at=null,
  last_error_code='retry_exhausted',updated_at=stamp
 where x.id in (select z.id from public.email_deliveries z join public.event_instructors i on i.id=z.record_id
  and i.tenant_id=z.tenant_id and i.instructor_user_id=z.recipient_user_id
  where i.event_id=e.id and i.tenant_id=e.tenant_id
   and z.message_type in ('instructor_assignment','instructor_removal','instructor_event_cancellation')
   and z.delivery_state<>'sent' and z.last_error_code is distinct from 'retry_exhausted'
   and (z.claim_expires_at is null or z.claim_expires_at<=stamp) and z.attempt_count>0
   and (z.attempt_count>=3 or z.attempt_window_started_at<=stamp-interval '23 hours')
  order by z.id limit 5 for update of z skip locked);
 for d in select x.* from public.email_deliveries x join public.event_instructors i
  on i.id=x.record_id and i.tenant_id=x.tenant_id and i.instructor_user_id=x.recipient_user_id
  where i.event_id=e.id and i.tenant_id=e.tenant_id
   and x.message_type in ('instructor_assignment','instructor_removal','instructor_event_cancellation')
   and x.delivery_state<>'sent' and (x.claim_expires_at is null or x.claim_expires_at<=stamp)
   and x.attempt_count<3 and (x.attempt_window_started_at is null or x.attempt_window_started_at>stamp-interval '23 hours')
   and (x.message_type='instructor_removal' and i.unassigned_at is not null
    or x.message_type='instructor_event_cancellation' and e.cancelled_at is not null
    or x.message_type='instructor_assignment' and life='active' and e.cancelled_at is null
     and public.tenant_has_feature_v1(e.tenant_id,'events') is true
     and i.unassigned_at is null and exists(select 1 from public.tenant_memberships m
      where m.tenant_id=e.tenant_id and m.user_id=i.instructor_user_id and m.status='active' and m.role='instructor'))
  order by x.id limit 5 for update of x skip locked
 loop
  lease:=gen_random_uuid();
  update public.email_deliveries set delivery_state='sending',claim_id=lease,claim_expires_at=stamp+interval '5 minutes',
   attempt_count=attempt_count+1,attempt_window_started_at=coalesce(attempt_window_started_at,stamp),
   last_attempt_at=stamp,updated_at=stamp where id=d.id;
  result:=result||jsonb_build_array(jsonb_build_object('claim_id',lease,'delivery_id',d.id));
 end loop;
 return result;
end;$$;

-- An exact admitted lease may proceed after later removal/cancellation. A new retry
-- can only enter through claim above and must re-evaluate lifecycle/assignment.
create function public.read_instructor_email_attempt_v1(p_claim_id uuid) returns jsonb
language sql volatile security definer set search_path=pg_catalog,public,pg_temp as $$
 select jsonb_build_object('kind',d.message_type,'assignment_id',i.id,'event_id',e.id,
  'tenant_id',e.tenant_id,'recipient_email',u.email,'title',e.title,'event_date',e.event_date,
  'start_time',e.start_time,'end_time',e.end_time,'location',e.location,
  'idempotency_key',d.message_type||'/'||i.id::text)
 from public.email_deliveries d join public.event_instructors i on i.id=d.record_id
  and i.tenant_id=d.tenant_id and i.instructor_user_id=d.recipient_user_id
 join public.events e on e.id=i.event_id and e.tenant_id=i.tenant_id
 join auth.users u on u.id=i.instructor_user_id
 join public.profiles p on p.user_id=u.id
 where d.claim_id=p_claim_id and d.delivery_state='sending' and d.sent_at is null
  and d.claim_expires_at>clock_timestamp()
  and d.message_type in ('instructor_assignment','instructor_removal','instructor_event_cancellation')
  and u.deleted_at is null and not coalesce(u.is_anonymous,false)
  and (u.banned_until is null or u.banned_until<=clock_timestamp()) and nullif(btrim(u.email),'') is not null;
$$;

create function public.complete_instructor_email_v1(p_claim_id uuid,p_success boolean,p_provider_message_id text default null) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public,pg_temp as $$
declare d public.email_deliveries%rowtype;stamp timestamptz;begin
 select * into d from public.email_deliveries where claim_id=p_claim_id
  and message_type in ('instructor_assignment','instructor_removal','instructor_event_cancellation') for update;
 stamp:=clock_timestamp();
 if not found or d.delivery_state<>'sending' or d.claim_expires_at<=stamp then return jsonb_build_object('code','claim_not_found');end if;
 if p_success is null or (p_success and (p_provider_message_id is null or p_provider_message_id!~'^[A-Za-z0-9_-]{1,128}$')) then
  raise exception 'Invalid completion' using errcode='22023';end if;
 update public.email_deliveries set delivery_state=case when p_success then 'sent' else 'failed' end,
  sent_at=case when p_success then stamp else null end,provider_message_id=case when p_success then p_provider_message_id else null end,
  claim_id=null,claim_expires_at=null,last_error_code=case when p_success then null else 'delivery_failed_or_uncertain' end,
  updated_at=stamp where id=d.id;
 return jsonb_build_object('code',case when p_success then 'sent' else 'failed' end);
end;$$;

create function public.purge_instructor_email_deliveries_v1() returns integer
language plpgsql security invoker set search_path=pg_catalog,public,pg_temp as $$
declare total integer;begin
 delete from public.email_deliveries where message_type in ('instructor_assignment','instructor_removal','instructor_event_cancellation')
  and delivery_state in ('sent','failed') and updated_at<clock_timestamp()-interval '90 days';
 get diagnostics total=row_count;return total;
end;$$;

-- No direct table grants. All new functions owned by postgres; exact SD delta +4.
do $$declare signature text;begin
 foreach signature in array array['queue_instructor_assignment_email_v1()','queue_instructor_cancellation_email_v1()',
 'authorize_instructor_email_batch_v1(uuid)','claim_instructor_email_batch_v1(uuid)',
 'read_instructor_email_attempt_v1(uuid)','complete_instructor_email_v1(uuid,boolean,text)','purge_instructor_email_deliveries_v1()'] loop
  execute 'alter function public.'||signature||' owner to postgres';
  execute 'revoke all on function public.'||signature||' from public,anon,authenticated,service_role';
 end loop;
end;$$;
grant execute on function public.authorize_instructor_email_batch_v1(uuid) to authenticated;
grant execute on function public.claim_instructor_email_batch_v1(uuid) to service_role;
grant execute on function public.read_instructor_email_attempt_v1(uuid) to service_role;
grant execute on function public.complete_instructor_email_v1(uuid,boolean,text) to service_role;
comment on column public.email_deliveries.record_id is 'Typed source identity: reservation, registration, reminder occurrence, or event_instructors generation for instructor_* messages.';
commit;
