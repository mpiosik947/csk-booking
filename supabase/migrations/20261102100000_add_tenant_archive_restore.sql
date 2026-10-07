-- PAM-1C: archive retains data; restore returns to unpublished dormant setup.
set lock_timeout='5s';
set statement_timeout='60s';
alter table public.tenants drop constraint tenants_status_check;
alter table public.tenants add constraint tenants_status_check check(status in ('dormant','active','suspended','disabled','archived'));
alter table public.tenants add column lifecycle_revision bigint not null default 0 check(lifecycle_revision>=0);

create table public.platform_tenant_lifecycle_requests(
 actor_user_id uuid not null,request_id uuid not null,tenant_id uuid not null references public.tenants(id) on delete restrict,
 payload jsonb not null,result jsonb not null,created_at timestamptz not null default transaction_timestamp(),
 primary key(actor_user_id,request_id)
);
alter table public.platform_tenant_lifecycle_requests enable row level security;
revoke all on public.platform_tenant_lifecycle_requests from public,anon,authenticated,service_role;

-- Closed continuity predicate: only a successful restore at the current revision
-- opens dormant history. Initial dormant tenants and unrelated state changes do not.
create function public.tenant_has_restored_history_core_v1(p_tenant_id uuid) returns boolean
language sql stable set search_path=pg_catalog,public,pg_temp as $$
 select exists(select 1 from public.tenants t
 join public.platform_tenant_lifecycle_requests r on r.tenant_id=t.id
 where t.id=p_tenant_id and t.status='dormant'
 and r.payload->>'operation'='restore' and r.result->>'status'='dormant'
 and r.result->>'revision'=t.lifecycle_revision::text);
$$;
alter function public.tenant_has_restored_history_core_v1(uuid) owner to postgres;
revoke all on function public.tenant_has_restored_history_core_v1(uuid) from public,anon,authenticated,service_role;

create function public.guard_tenant_archive_state_v1() returns trigger language plpgsql security definer
set search_path=pg_catalog,public,pg_temp as $$
begin
 if old.status='archived' and new.status not in ('archived','dormant') then
  raise exception 'TENANT_STATE_CONFLICT' using errcode='55000'; end if;
 if new.status is distinct from old.status then new.lifecycle_revision:=old.lifecycle_revision+1;
 else new.lifecycle_revision:=old.lifecycle_revision; end if;
 if new.status='archived' and exists(select 1 from public.tenant_public_profiles where tenant_id=new.id and is_public) then
  raise exception 'TENANT_PUBLICATION_CONFLICT' using errcode='55000'; end if;
 return new;
end;$$;
create trigger tenant_archive_state_guard before update on public.tenants for each row execute function public.guard_tenant_archive_state_v1();

-- Reminder occurrences have no tenant_id. Canonical reminder_source_v1 joins
-- schedule -> reservation, or schedule -> event -> registration, including tenant
-- equality. It excludes archived/dormant sources. Discovery inserts occurrence
-- and tenant-bound email delivery atomically; the email guard below serializes
-- discovery/claim with archive. Preserve occurrence tombstones and existing purge.
-- Fail-fast row SHARE serializes all guarded resource changes with archive.
-- No database-owner bypass for archived state; historical fixture bypasses cannot reopen it.
create function public.guard_archived_tenant_write_v1() returns trigger language plpgsql security definer
set search_path=pg_catalog,public,pg_temp as $$
declare t uuid:=coalesce(new.tenant_id,old.tenant_id); life text;
begin
 select status into life from public.tenants where id=t for share nowait;
 if life is distinct from 'archived' then return coalesce(new,old); end if;
 if tg_table_name='tenant_public_profiles' then
  if tg_op='UPDATE' and not new.is_public then return new; end if;
 elsif tg_table_name='email_deliveries' then
  if tg_op='DELETE' and auth.uid()=old.recipient_user_id then return old; end if;
  if tg_op='UPDATE' and new.claim_id is null then return new; end if;
  if tg_op<>'DELETE' and new.message_type in ('reservation_cancellation','event_registration_cancellation','event_cancellation','instructor_removal','instructor_event_cancellation') then return new; end if;
 elsif tg_table_name='events' and tg_op='UPDATE' then
  if not new.is_active and new.cancelled_at is not null and old.cancelled_at is null
   and (to_jsonb(new)-array['is_active','cancelled_at','cancelled_by','updated_at'])=(to_jsonb(old)-array['is_active','cancelled_at','cancelled_by','updated_at']) then return new; end if;
 elsif tg_table_name in ('reservations','event_registrations') and tg_op='UPDATE' then
  -- Existing suspended-obligation guard validates exact cancellation/redaction shape.
  return new;
 elsif tg_table_name='event_instructors' and tg_op='UPDATE' then
  -- Preserve account lifecycle redaction; no new assignment or identity reassignment.
  if (to_jsonb(new)-array['assigned_by','unassigned_by'])=(to_jsonb(old)-array['assigned_by','unassigned_by'])
   and (new.assigned_by is null or new.assigned_by=old.assigned_by)
   and (new.unassigned_by is null or new.unassigned_by=old.unassigned_by) then return new; end if;
 end if;
 raise exception 'TENANT_ARCHIVED' using errcode='55000';
end;$$;
do $$declare tab text;begin
 foreach tab in array array['tenant_public_profiles','tenant_domains','reservations','event_registrations','events','lane_blocks','shooting_lanes','event_instructors','email_deliveries'] loop
 execute format('create trigger zz_archive_write_guard before insert or update or delete on public.%I for each row execute function public.guard_archived_tenant_write_v1()',tab);
 end loop;
end;$$;

create function public.tenant_archive_preview_core_v1(p_tenant_id uuid) returns jsonb language plpgsql stable
set search_path=pg_catalog,public,pg_temp as $$
declare t public.tenants; admins bigint; leases bigint; plan jsonb; blockers jsonb:='[]'; counts jsonb;
begin
 select * into t from public.tenants where id=p_tenant_id;
 if not found then raise exception 'TENANT_UNAVAILABLE' using errcode='22023'; end if;
 select count(*) into admins from public.tenant_memberships where tenant_id=t.id and role='admin' and status='active';
 select jsonb_build_object('plan_key',p.plan_key,'status',a.status,'plan_status',p.status) into plan
 from public.tenant_plan_assignments a join public.saas_plans p on p.id=a.plan_id where a.tenant_id=t.id;
 select (select count(*) from public.email_deliveries where tenant_id=t.id and claim_id is not null and claim_expires_at>clock_timestamp()
  and message_type not in ('reservation_cancellation','event_registration_cancellation','event_cancellation','instructor_removal','instructor_event_cancellation'))
  +(select count(*) from public.event_registrations where tenant_id=t.id and promotion_claim_id is not null and promotion_claim_expires_at>clock_timestamp()) into leases;
 if t.status not in ('dormant','active','suspended','archived') then blockers:=blockers||'"TENANT_STATE_CONFLICT"'::jsonb; end if;
 if admins=0 then blockers:=blockers||'"TENANT_NO_ACTIVE_ADMIN"'::jsonb; end if;
 if leases>0 then blockers:=blockers||'"TENANT_DELIVERY_IN_FLIGHT"'::jsonb; end if;
 counts:=jsonb_build_object(
 'future_reservations',(select count(*) from public.reservations where tenant_id=t.id and reservation_date>=current_date and reservation_status='confirmed'),
 'future_events',(select count(*) from public.events where tenant_id=t.id and event_date>=current_date and cancelled_at is null),
 'open_registrations',(select count(*) from public.event_registrations where tenant_id=t.id and registration_status in ('registered','approved','reserve')),
 'active_lane_blocks',(select count(*) from public.lane_blocks where tenant_id=t.id and is_active),
 'active_custom_domains',(select count(*) from public.tenant_domains where tenant_id=t.id and domain_type='custom_domain' and status='active'),
 'settlement_records',(select count(*) from public.external_settlement_records where tenant_id=t.id),
 'pending_deliveries',(select count(*) from public.email_deliveries where tenant_id=t.id and sent_at is null),
 'in_flight_positive_deliveries',leases);
 return jsonb_build_object('tenant',jsonb_build_object('tenant_id',t.id,'name',t.name,'status',t.status,'is_public',coalesce((select is_public from public.tenant_public_profiles where tenant_id=t.id),false)),
 'current_plan',plan,'admin_summary',jsonb_build_object('active_admin_count',admins),'operational_counts',counts,
 'warnings',jsonb_build_array('HISTORY_RETAINED','CLOSURE_CONTINUITY_ONLY','RESTORE_REQUIRES_SEPARATE_PUBLICATION'),
 'blockers',blockers,'can_archive',jsonb_array_length(blockers)=0,'revision',t.lifecycle_revision);
end;$$;
create function public.platform_get_tenant_archive_preview_v1(p_tenant_id uuid) returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,pg_temp as $$begin
 if not public.is_platform_admin_v1() then raise exception 'Not authorized' using errcode='42501'; end if;
 return public.tenant_archive_preview_core_v1(p_tenant_id);
end;$$;

create function public.platform_tenant_lifecycle_core_v1(p_tenant_id uuid,p_expected_revision bigint,p_request_id uuid,p_operation text)
returns jsonb language plpgsql set search_path=pg_catalog,public,pg_temp as $$
declare actor uuid:=auth.uid(); t public.tenants; prior public.platform_tenant_lifecycle_requests; payload_value jsonb; result_value jsonb; preview jsonb; next_status text;
begin
 if not public.is_platform_admin_v1() then raise exception 'Not authorized' using errcode='42501'; end if;
 perform 1 from public.platform_admins where user_id=actor and status='active' for share nowait;
 if not found then raise exception 'Not authorized' using errcode='42501'; end if;
 if p_tenant_id is null or p_expected_revision is null or p_expected_revision<0 or p_request_id is null
  or p_request_id='00000000-0000-0000-0000-000000000000'::uuid or p_operation not in ('archive','restore') then
  raise exception 'INVALID_LIFECYCLE_REQUEST' using errcode='22023'; end if;
 if not pg_try_advisory_xact_lock(hashtextextended(actor::text||':'||p_request_id::text,1102000)) then raise exception 'TENANT_LIFECYCLE_BUSY' using errcode='55P03'; end if;
 payload_value:=jsonb_build_object('tenant_id',p_tenant_id,'revision',p_expected_revision,'operation',p_operation);
 select * into prior from public.platform_tenant_lifecycle_requests where actor_user_id=actor and request_id=p_request_id;
 if found then
  if prior.payload<>payload_value then raise exception 'REQUEST_REPLAY_MISMATCH' using errcode='22023'; end if;
  return prior.result;
 end if;
 if not pg_try_advisory_xact_lock(hashtextextended(p_tenant_id::text,9401)) then raise exception 'TENANT_LIFECYCLE_BUSY' using errcode='55P03'; end if;
 select * into t from public.tenants where id=p_tenant_id for no key update nowait;
 if not found then raise exception 'TENANT_UNAVAILABLE' using errcode='22023'; end if;
 if t.lifecycle_revision<>p_expected_revision then raise exception 'TENANT_REVISION_STALE' using errcode='PT409'; end if;
 perform 1 from public.tenant_public_profiles where tenant_id=t.id for update nowait;
 if not found then raise exception 'TENANT_STRUCTURE_INVALID' using errcode='55000'; end if;
 perform 1 from public.tenant_memberships where tenant_id=t.id order by user_id for share nowait;
 perform 1 from public.tenant_plan_assignments where tenant_id=t.id for share nowait;
 perform p.id from public.saas_plans p join public.tenant_plan_assignments a on a.plan_id=p.id where a.tenant_id=t.id for share of p nowait;
 preview:=public.tenant_archive_preview_core_v1(t.id);
 if p_operation='archive' then
  if jsonb_array_length(preview->'blockers')>0 then raise exception '%',preview->'blockers'->>0 using errcode='55000'; end if;
  next_status:='archived';
 else
  if t.status<>'archived' then raise exception 'TENANT_NOT_ARCHIVED' using errcode='55000'; end if;
  if (preview->'admin_summary'->>'active_admin_count')::bigint=0 then raise exception 'TENANT_NO_ACTIVE_ADMIN' using errcode='55000'; end if;
  if preview->'current_plan'->>'status' is distinct from 'active' or preview->'current_plan'->>'plan_status' is distinct from 'active' then
   raise exception 'TENANT_PLAN_INVALID' using errcode='55000'; end if;
  next_status:='dormant';
 end if;
 if t.status<>next_status then
  update public.tenant_public_profiles set is_public=false where tenant_id=t.id;
  update public.tenants set status=next_status where id=t.id returning * into t;
  insert into public.platform_audit_logs(actor_user_id,tenant_id,action,details)
  values(actor,t.id,case p_operation when 'archive' then 'tenant_archived' else 'tenant_restored' end,
   jsonb_build_object('previous_status',preview->'tenant'->>'status','new_status',next_status,'request_id',p_request_id,'revision',t.lifecycle_revision));
 end if;
 result_value:=jsonb_build_object('tenant_id',t.id,'status',t.status,'revision',t.lifecycle_revision,'is_public',false);
 insert into public.platform_tenant_lifecycle_requests(actor_user_id,request_id,tenant_id,payload,result) values(actor,p_request_id,t.id,payload_value,result_value);
 return result_value;
end;$$;
create function public.platform_archive_tenant_v1(p_tenant_id uuid,p_expected_revision bigint,p_request_id uuid)
returns jsonb language sql security definer set search_path=pg_catalog,public,pg_temp
as $$select public.platform_tenant_lifecycle_core_v1(p_tenant_id,p_expected_revision,p_request_id,'archive');$$;
create function public.platform_restore_archived_tenant_v1(p_tenant_id uuid,p_expected_revision bigint,p_request_id uuid)
returns jsonb language sql security definer set search_path=pg_catalog,public,pg_temp
as $$select public.platform_tenant_lifecycle_core_v1(p_tenant_id,p_expected_revision,p_request_id,'restore');$$;
do $$declare signature text;begin
 foreach signature in array array['guard_tenant_archive_state_v1()','guard_archived_tenant_write_v1()','tenant_archive_preview_core_v1(uuid)',
 'platform_get_tenant_archive_preview_v1(uuid)','platform_tenant_lifecycle_core_v1(uuid,bigint,uuid,text)',
 'platform_archive_tenant_v1(uuid,bigint,uuid)','platform_restore_archived_tenant_v1(uuid,bigint,uuid)'] loop
 execute 'alter function public.'||signature||' owner to postgres';
 execute 'revoke all on function public.'||signature||' from public,anon,authenticated,service_role';
 end loop;
end;$$;
grant execute on function public.platform_get_tenant_archive_preview_v1(uuid),public.platform_archive_tenant_v1(uuid,bigint,uuid),public.platform_restore_archived_tenant_v1(uuid,bigint,uuid) to authenticated;

-- Reviewed continuity replacements; existing owner/ACL retained.

CREATE OR REPLACE FUNCTION public.get_my_continuity_role_core_v1(p_tenant_id uuid)
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$select m.role from public.tenant_memberships m join public.tenants t on t.id=m.tenant_id
 where m.tenant_id=p_tenant_id and m.user_id=auth.uid() and m.status='active'
 and (t.status in ('active','suspended','archived') or public.tenant_has_restored_history_core_v1(t.id));$function$;

CREATE OR REPLACE FUNCTION public.get_my_continuity_v1(p_page integer DEFAULT 1, p_staff_tenant uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
declare response jsonb;
begin
 if auth.uid() is null then raise exception 'Not authorized' using errcode='42501'; end if;
 if p_page is null or p_page<1 or p_page>100000 then raise exception 'Invalid page' using errcode='22023'; end if;
 if p_staff_tenant is not null and coalesce(public.get_my_continuity_role_core_v1(p_staff_tenant),'') not in ('admin','employee') then
 raise exception 'Not authorized' using errcode='42501'; end if;
 with resources as (
 select 'reservation'::text kind,r.id,r.tenant_id,t.name tenant_name,t.slug,t.status tenant_status,r.user_id,
 coalesce(r.lane_name_snapshot,'Rezerwacja') title,r.reservation_date appointment_date,r.start_time,
 r.reservation_status status,r.payment_status,
 ((r.reservation_date+r.start_time) at time zone 'Europe/Warsaw')-interval '12 hours' deadline,
 coalesce(r.attendance_status,'planned')='planned' and r.checked_in_at is null and r.completed_at is null eligible
 from public.reservations r join public.tenants t on t.id=r.tenant_id
 where (t.status in ('active','suspended','archived') or public.tenant_has_restored_history_core_v1(t.id)) and
 ((p_staff_tenant is null and r.user_id=auth.uid()) or r.tenant_id=p_staff_tenant)
 union all
 select 'event_registration',r.id,r.tenant_id,t.name,t.slug,t.status,r.user_id,e.title,e.event_date,e.start_time,
 r.registration_status,r.payment_status,((e.event_date+e.start_time) at time zone 'Europe/Warsaw')-interval '72 hours',true
 from public.event_registrations r join public.events e on e.id=r.event_id and e.tenant_id=r.tenant_id
 join public.tenants t on t.id=r.tenant_id where (t.status in ('active','suspended','archived') or public.tenant_has_restored_history_core_v1(t.id)) and
 ((p_staff_tenant is null and r.user_id=auth.uid()) or r.tenant_id=p_staff_tenant)
 ), page_rows as (select * from resources order by appointment_date desc,start_time desc,kind,id limit 25 offset((p_page::bigint-1)*25))
 select jsonb_build_object('page',p_page,'page_size',25,'total',(select count(*) from resources),
 'items',coalesce((select jsonb_agg(jsonb_build_object('kind',r.kind,'id',r.id,'tenant_name',r.tenant_name,
 'tenant_slug',r.slug,'tenant_status',r.tenant_status,'title',r.title,'date',r.appointment_date,'start_time',r.start_time,
 'status',r.status,'payment_status',r.payment_status,'deadline',r.deadline,
 'can_cancel',coalesce(public.get_my_continuity_role_core_v1(r.tenant_id),'') in ('admin','employee','user','instructor')
 and r.eligible and (r.kind='event_registration' or public.get_my_continuity_role_core_v1(r.tenant_id)<>'instructor')
 and r.status in ('confirmed','registered','approved','reserve','participant')
 and (public.get_my_continuity_role_core_v1(r.tenant_id) in ('admin','employee') or now()<=r.deadline),
 'settlements',coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'kind',s.kind,'amount',s.amount,
 'currency',s.currency,'recorded_at',s.recorded_at) order by s.recorded_at,s.id)
 from public.external_settlement_records s where s.tenant_id=r.tenant_id and
 ((r.kind='reservation' and s.reservation_id=r.id) or (r.kind='event_registration' and s.registration_id=r.id))),'[]'::jsonb)
 ) order by r.appointment_date desc,r.start_time desc,r.kind,r.id) from page_rows r),'[]'::jsonb)) into response;
 return response || jsonb_build_object('staff_tenants',coalesce((
 select jsonb_agg(jsonb_build_object('id',t.id,'name',t.name,'status',t.status) order by t.name,t.id)
 from public.tenants t join public.tenant_memberships m on m.tenant_id=t.id
 where m.user_id=auth.uid() and m.status='active' and m.role in ('admin','employee')
 and (t.status in ('active','suspended','archived') or public.tenant_has_restored_history_core_v1(t.id))),'[]'::jsonb));
end;$function$;

CREATE OR REPLACE FUNCTION public.can_authorize_reservation_cancellation_email_core_v1(p_reservation_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
 select auth.uid() is not null and exists(
  select 1 from public.reservations r join public.tenants t on t.id=r.tenant_id
  where r.id=p_reservation_id and (t.status in ('active','suspended','archived') or public.tenant_has_restored_history_core_v1(t.id))
   and (r.user_id=auth.uid() or exists(
    select 1 from public.tenant_memberships m
    where m.tenant_id=r.tenant_id and m.user_id=auth.uid()
     and m.status='active' and m.role in ('admin','employee')))
 );
$function$;

CREATE OR REPLACE FUNCTION public.prepare_event_registration_cancellation_email_v1(p_registration_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
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
 perform 1 from public.tenants where id=r.tenant_id and (status in ('active','suspended','archived') or public.tenant_has_restored_history_core_v1(id)) for share;
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
end;$function$;

CREATE OR REPLACE FUNCTION public.enforce_suspended_obligations_v1()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
declare tenant_status text; target uuid;
begin
 if session_user='postgres' and current_setting('app.product10d_test_enforce',true) is distinct from 'on' then
 return coalesce(new,old); end if;

 if tg_relid='public.event_registrations'::regclass and tg_op='UPDATE'
  and pg_trigger_depth()>1 and auth.uid() is not null
  and (to_jsonb(old)->>'attendance_marked_by')=auth.uid()::text
  and (to_jsonb(new)->>'attendance_marked_by') is null
  and (to_jsonb(new)-'attendance_marked_by')=(to_jsonb(old)-'attendance_marked_by')
  and not exists(select 1 from public.profiles where user_id=auth.uid()) then
   return new;
 end if;
 target:=coalesce(new.tenant_id,old.tenant_id);
 -- Row SHARE conflicts with platform lifecycle UPDATE; unlike a snapshot-only
 -- status check it cannot allow a new obligation to race past suspension.
 select status into tenant_status from public.tenants where id=target for share;
 if tenant_status='active' then return coalesce(new,old); end if;
 if (tenant_status='archived' or public.tenant_has_restored_history_core_v1(target)) and tg_table_name='events' and tg_op='UPDATE'
  and (to_jsonb(new)->>'cancelled_at') is not null and (to_jsonb(old)->>'cancelled_at') is null
  and (to_jsonb(new)->>'is_active')='false'
  and (to_jsonb(new)-array['is_active','cancelled_at','cancelled_by','updated_at'])=(to_jsonb(old)-array['is_active','cancelled_at','cancelled_by','updated_at']) then return new; end if;
 if (tenant_status in ('suspended','archived') or public.tenant_has_restored_history_core_v1(target)) and tg_op='UPDATE' then
 if tg_table_name='event_registrations'
  and to_jsonb(old)->>'registration_status'='cancelled' and to_jsonb(new)->>'registration_status'='cancelled'
  and to_jsonb(old)->>'cancellation_email_initialized_at' is null
  and to_jsonb(new)->>'cancellation_email_initialized_at' is not null
  and (to_jsonb(new)-'cancellation_email_initialized_at')=(to_jsonb(old)-'cancellation_email_initialized_at')
 then return new; end if;

 -- Account-wide anonymization remains separate from tenant suspension. Allow
 -- only the existing owner's exact redaction shape, never identity reassignment.
 if (to_jsonb(old)->>'user_id')=auth.uid()::text and (to_jsonb(new)->>'user_id') is null
 and (to_jsonb(new)->>'pii_anonymized_at') is not null
 and (to_jsonb(new)->>'customer_name')='deleted-user-'||substr(md5(auth.uid()::text||':csk-sec009-v1'),1,16)
 and (to_jsonb(new)->>'customer_email')='deleted-user-'||substr(md5(auth.uid()::text||':csk-sec009-v1'),1,16)||'@invalid.local'
 and (to_jsonb(new)->>'customer_phone')='[redacted]' then
 if tg_table_name='reservations' and (to_jsonb(new)-array['user_id','customer_name','customer_email','customer_phone',
 'admin_note','reservation_note','check_in_token','pii_anonymized_at','updated_at','booking_period'])=
 (to_jsonb(old)-array['user_id','customer_name','customer_email','customer_phone',
 'admin_note','reservation_note','check_in_token','pii_anonymized_at','updated_at','booking_period'])
 and (to_jsonb(new)->>'admin_note') is null and (to_jsonb(new)->>'reservation_note') is null and (to_jsonb(new)->>'check_in_token') is null then return new; end if;
 if tg_table_name='event_registrations' and (to_jsonb(new)-array['user_id','customer_name','customer_email','customer_phone',
 'promotion_token','promotion_token_expires_at','promotion_claim_id','promotion_claim_expires_at','promotion_attempt_count',
 'promotion_last_attempt_at','promotion_last_error_code','pii_anonymized_at','updated_at'])=
 (to_jsonb(old)-array['user_id','customer_name','customer_email','customer_phone',
 'promotion_token','promotion_token_expires_at','promotion_claim_id','promotion_claim_expires_at','promotion_attempt_count',
 'promotion_last_attempt_at','promotion_last_error_code','pii_anonymized_at','updated_at']) then return new; end if;
 end if;
 if tg_table_name='reservations'
 and (to_jsonb(new)->>'reservation_status') in ('cancelled','canceled','cancelled_by_user','cancelled_by_admin')
 -- booking_period is GENERATED ALWAYS and unset in a BEFORE trigger.
 and (to_jsonb(new)-array['reservation_status','updated_at','booking_period'])=(to_jsonb(old)-array['reservation_status','updated_at','booking_period']) then return new; end if;
 if tg_table_name='event_registrations' and (to_jsonb(new)->>'registration_status')='cancelled'
 and (to_jsonb(new)-array['registration_status','updated_at'])=(to_jsonb(old)-array['registration_status','updated_at']) then return new; end if;
 end if;
 raise exception 'New business unavailable' using errcode='42501';
end;$function$;

CREATE OR REPLACE FUNCTION public.claim_instructor_email_batch_v1(p_event_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
declare e public.events%rowtype;d public.email_deliveries%rowtype;life text;
 stamp timestamptz;lease uuid;result jsonb:='[]';
begin
 select * into e from public.events where id=p_event_id for update;
 if not found then return result;end if;
 select status into life from public.tenants where id=e.tenant_id for share;
 if life is null or (life not in ('active','suspended','archived') and not public.tenant_has_restored_history_core_v1(e.tenant_id)) then return result;end if;
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
end;$function$;

CREATE OR REPLACE FUNCTION public.get_my_reservations_v3(p_tenant_id uuid, p_page integer DEFAULT 1, p_page_size integer DEFAULT 50)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
declare
  v_actor uuid:=auth.uid();
  v_offset integer;
  v_result jsonb;
begin
  if v_actor is null then return pg_catalog.jsonb_build_object('ok',false,'code','not_allowed'); end if;
  if p_tenant_id is null or not exists(select 1 from public.tenants where id=p_tenant_id and (status in ('active','archived') or public.tenant_has_restored_history_core_v1(id))) then
    return pg_catalog.jsonb_build_object('ok',false,'code','not_found');
  end if;
  if p_page is null or p_page<1 or p_page>100000
     or p_page_size is null or p_page_size<1 or p_page_size>500 then
    return pg_catalog.jsonb_build_object('ok',false,'code','invalid_input');
  end if;
  v_offset:=(p_page-1)*p_page_size;
  with owned as materialized (
    select reservation.id,reservation.reservation_date,reservation.start_time,reservation.end_time,
      reservation.price,reservation.reservation_status,reservation.payment_status,
      reservation.check_in_token,reservation.attendance_status,reservation.checked_in_at,
      case
        when lane.resource_kind='lane' and lane.parent_lane_id is null
         and pg_catalog.btrim(lane.name)<>'' then lane.name
        when lane.resource_kind='position' and lane.parent_lane_id is not null
         and parent.id=lane.parent_lane_id and parent.resource_kind='lane'
         and parent.parent_lane_id is null and pg_catalog.btrim(parent.name)<>''
         and pg_catalog.btrim(lane.name)<>'' then parent.name||' — '||lane.name
        else null
      end as lane_display_name
    from public.reservations reservation
    left join public.shooting_lanes lane on lane.id=reservation.lane_id and lane.tenant_id=p_tenant_id
    left join public.shooting_lanes parent on parent.id=lane.parent_lane_id and parent.tenant_id=p_tenant_id
    where reservation.user_id=v_actor and reservation.tenant_id=p_tenant_id
  ), page_rows as (
    select * from owned order by reservation_date desc,start_time desc,id desc
    limit p_page_size offset v_offset
  )
  select pg_catalog.jsonb_build_object(
    'ok',true,'code','ok','contract_version',3,
    'pagination',pg_catalog.jsonb_build_object('page',p_page,'page_size',p_page_size,
      'total',(select pg_catalog.count(*) from owned)),
    'items',coalesce((select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(row)
      order by row.reservation_date desc,row.start_time desc,row.id desc)
      from page_rows row),'[]'::jsonb)
  ) into v_result;
  return v_result;
end $function$;

CREATE OR REPLACE FUNCTION public.get_my_event_registrations_v2(p_tenant_id uuid, p_scope text DEFAULT 'upcoming'::text, p_status text DEFAULT NULL::text, p_page integer DEFAULT 1, p_page_size integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
declare
  v_actor uuid:=auth.uid();
  v_scope text:=pg_catalog.lower(pg_catalog.btrim(coalesce(p_scope,'')));
  v_status text:=nullif(pg_catalog.lower(pg_catalog.btrim(p_status)),'');
  v_offset integer;
  v_now timestamp without time zone:=transaction_timestamp() at time zone 'Europe/Warsaw';
  v_result jsonb;
begin
  if v_actor is null then return pg_catalog.jsonb_build_object('ok',false,'code','not_allowed'); end if;
  if p_tenant_id is null or not exists(select 1 from public.tenants where id=p_tenant_id and (status in ('active','archived') or public.tenant_has_restored_history_core_v1(id))) then
    return pg_catalog.jsonb_build_object('ok',false,'code','not_found');
  end if;
  if v_scope not in ('upcoming','history','all')
     or (v_status is not null and v_status not in ('registered','approved','reserve','cancelled','participant'))
     or p_page is null or p_page<1 or p_page>100000
     or p_page_size is null or p_page_size<1 or p_page_size>50 then
    return pg_catalog.jsonb_build_object('ok',false,'code','invalid_input');
  end if;
  v_offset:=(p_page-1)*p_page_size;
  with owned as materialized (
    select registration.id,pg_catalog.lower(pg_catalog.btrim(registration.registration_status)) registration_status,
      pg_catalog.lower(pg_catalog.btrim(registration.payment_status)) payment_status,registration.created_at,
      event_record.id event_id,event_record.title,coalesce(event_record.description,'') description,
      event_record.event_date,event_record.start_time,event_record.end_time,
      coalesce(event_record.location,'') location,event_record.price
    from public.event_registrations registration
    join public.events event_record
      on event_record.id=registration.event_id and event_record.tenant_id=p_tenant_id
    where registration.user_id=v_actor and registration.tenant_id=p_tenant_id
  ), filtered as materialized (
    select * from owned where (v_status is null or registration_status=v_status)
      and case v_scope
        when 'upcoming' then registration_status<>'cancelled' and (event_date+end_time)>v_now
        when 'history' then registration_status='cancelled' or (event_date+end_time)<=v_now
        else true
      end
  ), page_rows as (
    select * from filtered
    order by case when v_scope='upcoming' then event_date end asc,
      case when v_scope='upcoming' then start_time end asc,
      case when v_scope<>'upcoming' then event_date end desc,
      case when v_scope<>'upcoming' then start_time end desc,
      case when v_scope='upcoming' then id end asc,
      case when v_scope<>'upcoming' then id end desc
    limit p_page_size offset v_offset
  )
  select pg_catalog.jsonb_build_object(
    'ok',true,'code','ok','contract_version',2,
    'filters',pg_catalog.jsonb_build_object('scope',v_scope,'status',v_status),
    'pagination',pg_catalog.jsonb_build_object('page',p_page,'page_size',p_page_size,
      'total',(select pg_catalog.count(*) from filtered)),
    'items',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'id',row.id,'registration_status',row.registration_status,
      'payment_status',row.payment_status,'created_at',row.created_at,
      'events',pg_catalog.jsonb_build_object('id',row.event_id,'title',row.title,
        'description',row.description,'event_date',row.event_date,
        'start_time',row.start_time,'end_time',row.end_time,'location',row.location,'price',row.price)
    ) order by case when v_scope='upcoming' then row.event_date end asc,
      case when v_scope='upcoming' then row.start_time end asc,
      case when v_scope<>'upcoming' then row.event_date end desc,
      case when v_scope<>'upcoming' then row.start_time end desc,
      case when v_scope='upcoming' then row.id end asc,
      case when v_scope<>'upcoming' then row.id end desc) from page_rows row),'[]'::jsonb)
  ) into v_result;
  return v_result;
end $function$;

CREATE OR REPLACE FUNCTION public.platform_get_tenant_admin_management_v1(p_tenant_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
declare t public.tenants; items jsonb;
begin
 if not public.is_platform_admin_v1() then raise exception 'Not authorized' using errcode='42501'; end if;
 select * into t from public.tenants where id=p_tenant_id and status in ('dormant','active','suspended','archived');
 if not found then raise exception 'Tenant unavailable' using errcode='22023'; end if;
 select coalesce(jsonb_agg(jsonb_build_object('user_id',m.user_id,'email',u.email,
  'membership_role',m.role,'membership_status',m.status,'updated_at',m.updated_at) order by m.user_id),'[]')
 into items from public.tenant_memberships m join auth.users u on u.id=m.user_id
 where m.tenant_id=t.id and m.role='admin';
 return jsonb_build_object('tenant',jsonb_build_object('tenant_id',t.id,'name',t.name,'status',t.status),
  'admins',items,'active_admin_count',(select count(*) from public.tenant_memberships where tenant_id=t.id and role='admin' and status='active'));
end;$function$;

CREATE OR REPLACE FUNCTION public.admin_cancel_event_v1(p_event_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
declare e public.events%rowtype; total integer;
begin
 select * into e from public.events where id=p_event_id for update;
 if not found or coalesce(public.get_my_continuity_role_core_v1(e.tenant_id),'') not in ('admin','employee')
  or (not public.get_my_tenant_feature_access_v1(e.tenant_id,'events') and not exists(select 1 from public.tenants where id=e.tenant_id and (status='archived' or public.tenant_has_restored_history_core_v1(id)))) then
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
end;$function$;

CREATE OR REPLACE FUNCTION public.enforce_tenant_feature_write_v1()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
declare v_feature text; v_tenant uuid; v_requires boolean:=true;
begin
 if session_user='postgres' and current_setting('app.product10d_test_enforce',true) is distinct from 'on' then return coalesce(new,old); end if;
 v_tenant:=coalesce(new.tenant_id,old.tenant_id);
 if v_tenant is not null then perform 1 from public.tenants where id=v_tenant for share nowait; end if;
 if tg_table_name='tenant_domains' then
  if tg_op<>'DELETE' and new.domain_type='custom_domain' and
   (tg_op='INSERT' or (new.status='active' and old.status is distinct from new.status) or (new.is_primary and not coalesce(old.is_primary,false)))
   and not public.tenant_setup_has_feature_core_v1(v_tenant,'custom_domain') then
   raise exception 'feature_not_available' using errcode='42501'; end if;
  return coalesce(new,old);
 elsif tg_table_name='reservations' then
  if tg_op<>'INSERT' then return new; end if; v_feature:='booking';
 elsif tg_table_name='event_registrations' then
  if tg_op<>'INSERT' then return new; end if; v_feature:='events';
 elsif tg_table_name='events' then
  if tg_op='UPDATE' and new.cancelled_at is not null and old.cancelled_at is null and not new.is_active
   and exists(select 1 from public.tenants where id=v_tenant and (status='archived' or public.tenant_has_restored_history_core_v1(id))) then return new; end if;
  if tg_op='DELETE' or (tg_op='UPDATE' and old.is_active and not new.is_active) then return coalesce(new,old); end if; v_feature:='events';
 elsif tg_table_name='lane_blocks' then
  if tg_op='DELETE' or (tg_op='UPDATE' and not new.is_active) then return coalesce(new,old); end if; v_feature:='lane_blocks';
 elsif tg_table_name='shooting_lanes' then
  if public.tenant_draft_setup_role_core_v1(v_tenant)='admin' then return coalesce(new,old); end if;
  if tg_op='DELETE' or (tg_op='UPDATE' and old.is_active and not new.is_active) then return coalesce(new,old); end if; v_feature:='booking';
 else v_requires:=false;
 end if;
 if v_requires and not public.tenant_has_feature_v1(v_tenant,v_feature) then raise exception 'feature_not_available' using errcode='42501'; end if;
 return coalesce(new,old);
end;$function$;

alter table public.platform_audit_logs drop constraint platform_audit_logs_action_check;
alter table public.platform_audit_logs add constraint platform_audit_logs_action_check CHECK ((action = ANY (ARRAY['tenant_created'::text, 'plan_assigned'::text, 'plan_changed'::text, 'tenant_admin_assigned'::text, 'tenant_activated'::text, 'tenant_suspended'::text, 'tenant_published'::text, 'tenant_unpublished'::text, 'platform_admin_bootstrapped'::text, 'domain_added'::text, 'domain_verification_started'::text, 'domain_verified'::text, 'domain_activated'::text, 'domain_disabled'::text, 'primary_domain_changed'::text, 'tenant_admin_add'::text, 'tenant_admin_reactivate'::text, 'tenant_admin_demote'::text, 'tenant_admin_suspend'::text, 'tenant_archived'::text, 'tenant_restored'::text])));

CREATE OR REPLACE FUNCTION public.guard_event_cancellation_v1()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
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
   or coalesce(public.get_my_continuity_role_core_v1(old.tenant_id),'') not in ('admin','employee')
   or (not public.get_my_tenant_feature_access_v1(old.tenant_id,'events') and not exists(select 1 from public.tenants where id=old.tenant_id and (status='archived' or public.tenant_has_restored_history_core_v1(id)))) then
   raise exception 'Cancellation unavailable' using errcode='42501'; end if;
 end if;
 return new;
end;$function$;

-- PAM-1C-R3: detect stale activation across an intervening lifecycle transition.
CREATE OR REPLACE FUNCTION public.platform_set_tenant_state_v1(p_tenant_id uuid, p_action text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
declare current_status text; readiness jsonb; audit_action text; initial_admin uuid; observed_revision bigint; locked_revision bigint;
begin
 if not public.is_platform_admin_v1() then raise exception 'Not authorized' using errcode='42501'; end if;
 -- Preserve the live v1 signature. Capture before any mutation-lock wait so a
 -- request begun during restore cannot adopt the newly restored state silently.
 if p_action='activate' then
   select lifecycle_revision into observed_revision from public.tenants where id=p_tenant_id;
   if not found then raise exception 'Tenant unavailable' using errcode='22023'; end if;
 end if;
 select status,lifecycle_revision into current_status,locked_revision
 from public.tenants where id=p_tenant_id for no key update;
 if not found then raise exception 'Tenant unavailable' using errcode='22023'; end if;
 if p_action='activate' and locked_revision is distinct from observed_revision then
   raise exception 'TENANT_REVISION_STALE' using errcode='PT409';
 end if;
 perform pg_advisory_xact_lock(hashtextextended(p_tenant_id::text,9401));
 if p_action in ('activate','publish') then
   -- NO KEY UPDATE preserves status serialization without blocking audit/membership FK KEY SHARE.
   -- Nonblocking account/catalog locks avoid reversing account-delete/operator lock orders.
   perform 1 from public.tenant_public_profiles where tenant_id=p_tenant_id for share nowait;
   for initial_admin in select user_id from public.tenant_memberships
     where tenant_id=p_tenant_id and role='admin' and status='active' order by user_id for share nowait loop
     if not pg_try_advisory_xact_lock(hashtextextended(initial_admin::text,0)) then
       raise exception 'Onboarding account busy; retry' using errcode='55P03'; end if;
     perform 1 from public.profiles where user_id=initial_admin for share nowait;
     perform 1 from auth.users where id=initial_admin for share nowait;
   end loop;
   perform 1 from public.tenant_plan_assignments where tenant_id=p_tenant_id for share nowait;
   perform p.id from public.saas_plans p join public.tenant_plan_assignments a on a.plan_id=p.id
     where a.tenant_id=p_tenant_id for share of p nowait;
   readiness:=public.platform_tenant_readiness_core_v1(p_tenant_id);
   if readiness is null or exists(select 1 from jsonb_each(readiness) where value<>'true'::jsonb) then
     raise exception 'Tenant setup incomplete' using errcode='55000'; end if;
 end if;
 if p_action='activate' and current_status in ('dormant','suspended') then
   update public.tenants set status='active' where id=p_tenant_id; audit_action:='tenant_activated';
 elsif p_action='suspend' and current_status='active' then
   update public.tenants set status='suspended' where id=p_tenant_id;
   update public.tenant_public_profiles set is_public=false where tenant_id=p_tenant_id;
   audit_action:='tenant_suspended';
 elsif p_action='publish' and current_status='active' then
   update public.tenant_public_profiles set is_public=true where tenant_id=p_tenant_id; audit_action:='tenant_published';
 elsif p_action='unpublish' and current_status in ('dormant','active','suspended') then
   update public.tenant_public_profiles set is_public=false where tenant_id=p_tenant_id; audit_action:='tenant_unpublished';
 else raise exception 'Invalid lifecycle transition' using errcode='55000'; end if;
 insert into public.platform_audit_logs(actor_user_id,tenant_id,action) values(auth.uid(),p_tenant_id,audit_action);
end;$function$;
