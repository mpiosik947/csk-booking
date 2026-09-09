-- SAAS-9B-2B: deterministic CSK ownership backfill and validation.
-- Tenant-aware runtime authorization remains deferred to SAAS-9C/9D.

set lock_timeout = '5s';
set statement_timeout = '120s';

do $preflight$
declare
  v_table text;
begin
  if (select pg_catalog.count(*) from public.tenants) <> 1
     or not exists (
       select 1
       from public.tenants
       where id = 'c5c00000-0000-4000-8000-000000000001'::uuid
         and name = 'CSK'
         and slug = 'csk'
         and status = 'active'
     )
     or (select pg_catalog.count(*) from public.tenants where status = 'active') <> 1 then
    raise exception 'SAAS-9B-2B preflight failed: canonical CSK tenant differs.';
  end if;

  foreach v_table in array array[
    'shooting_lanes', 'reservations', 'lane_blocks', 'events',
    'event_lanes', 'event_registrations', 'email_deliveries', 'audit_logs'
  ] loop
    if not exists (
      select 1
      from information_schema.columns
      where table_schema = 'public'
        and table_name = v_table
        and column_name = 'tenant_id'
        and udt_schema = 'pg_catalog'
        and udt_name = 'uuid'
        and is_nullable = 'YES'
    ) then
      raise exception 'SAAS-9B-2B preflight failed: 9B-2A state for % differs.', v_table;
    end if;
  end loop;

  if exists (
    select 1
    from public.shooting_lanes child
    left join public.shooting_lanes parent on parent.id = child.parent_lane_id
    where child.parent_lane_id is not null
      and parent.id is null
  ) then
    raise exception 'SAAS-9B-2B preflight failed: orphan lane hierarchy.';
  end if;

  if exists (
    select 1 from public.reservations record
    left join public.shooting_lanes lane on lane.id = record.lane_id
    where lane.id is null
  ) or exists (
    select 1 from public.lane_blocks record
    left join public.shooting_lanes lane on lane.id = record.lane_id
    where lane.id is null
  ) or exists (
    select 1 from public.event_lanes relation
    left join public.events event_record on event_record.id = relation.event_id
    left join public.shooting_lanes lane on lane.id = relation.lane_id
    where event_record.id is null or lane.id is null
  ) or exists (
    select 1 from public.event_registrations registration
    left join public.events event_record on event_record.id = registration.event_id
    where registration.event_id is null or event_record.id is null
  ) then
    raise exception 'SAAS-9B-2B preflight failed: core ownership orphan/null found.';
  end if;

  if exists (
    select 1
    from public.email_deliveries delivery
    left join public.reservations reservation on reservation.id = delivery.record_id
    where delivery.message_type <> 'reservation_confirmation'
       or reservation.id is null
  ) then
    raise exception 'SAAS-9B-2B preflight failed: unknown or orphan email delivery mapping.';
  end if;

  if exists (
    with classification(action, target_type, scope) as (values
      ('lane_booking_family_created', 'lane_booking_family', 'tenant'),
      ('lane_booking_family_configuration_updated', 'lane_booking_family', 'tenant'),
      ('event_registration_approved_by_staff', 'event_registration', 'tenant'),
      ('event_registration_cancelled_by_staff', 'event_registration', 'tenant'),
      ('event_registration_cancelled_by_user', 'event_registration', 'tenant'),
      ('event_registration_payment_marked_by_staff', 'event_registration', 'tenant'),
      ('reservation_created', 'reservation', 'tenant'),
      ('reservation_cancelled_by_user', 'reservation', 'tenant'),
      ('reservation_cancelled_by_staff', 'reservation', 'tenant'),
      ('RESERVATION_ADMIN_NOTE_CHANGED', 'reservation', 'tenant'),
      ('RESERVATION_STARTED', 'reservation', 'tenant'),
      ('RESERVATION_ATTENDANCE_RESET', 'reservation', 'tenant'),
      ('CHECK_IN_COMPLETED', 'reservation', 'tenant'),
      ('RESERVATION_NO_SHOW', 'reservation', 'tenant'),
      ('RESERVATION_PAYMENT_STATUS_CHANGED', 'reservation', 'tenant'),
      ('profile_admin_note_updated', 'profile', 'global'),
      ('profile_contact_details_updated', 'profile', 'global'),
      ('profile_identity_updated', 'profile', 'global'),
      ('profile_role_changed', 'profile', 'global'),
      ('profile_verification_verified', 'profile', 'global'),
      ('profile_verification_marked_pending', 'profile', 'global'),
      ('profile_verification_rejected', 'profile', 'global'),
      ('PROFILE_PERMISSIONS_VERIFICATION_UPDATED', 'profile', 'global'),
      ('PROFILE_ROLE_CHANGED', 'profile', 'global'),
      ('PROFILE_VERIFICATION_CHANGED', 'profile', 'global'),
      ('account_anonymized', 'account', 'global')
    )
    select 1
    from public.audit_logs audit
    left join classification known
      on known.action = audit.action
     and known.target_type = audit.target_type
    where known.action is null
  ) then
    raise exception 'SAAS-9B-2B preflight failed: UNKNOWN audit action/target_type.';
  end if;

  if exists (
    select 1
    from public.audit_logs audit
    left join public.reservations reservation on reservation.id = audit.target_id
    where audit.target_type = 'reservation'
      and reservation.id is null
  ) or exists (
    select 1
    from public.audit_logs audit
    left join public.event_registrations registration on registration.id = audit.target_id
    where audit.target_type = 'event_registration'
      and registration.id is null
  ) or exists (
    select 1
    from public.audit_logs audit
    left join public.shooting_lanes lane on lane.id = audit.target_id
    where audit.target_type = 'lane_booking_family'
      and lane.id is null
  ) then
    raise exception 'SAAS-9B-2B preflight failed: tenant audit target is missing.';
  end if;
end;
$preflight$;

create temporary table saas9b2_business_snapshot (
  table_name text primary key,
  row_count bigint not null,
  business_fingerprint text not null
);

insert into saas9b2_business_snapshot
select 'shooting_lanes', pg_catalog.count(*), pg_catalog.md5(coalesce(pg_catalog.string_agg((pg_catalog.to_jsonb(record) - 'tenant_id')::text, E'\n' order by (pg_catalog.to_jsonb(record) - 'tenant_id')::text), '')) from public.shooting_lanes record
union all
select 'reservations', pg_catalog.count(*), pg_catalog.md5(coalesce(pg_catalog.string_agg((pg_catalog.to_jsonb(record) - 'tenant_id')::text, E'\n' order by (pg_catalog.to_jsonb(record) - 'tenant_id')::text), '')) from public.reservations record
union all
select 'lane_blocks', pg_catalog.count(*), pg_catalog.md5(coalesce(pg_catalog.string_agg((pg_catalog.to_jsonb(record) - 'tenant_id')::text, E'\n' order by (pg_catalog.to_jsonb(record) - 'tenant_id')::text), '')) from public.lane_blocks record
union all
select 'events', pg_catalog.count(*), pg_catalog.md5(coalesce(pg_catalog.string_agg((pg_catalog.to_jsonb(record) - 'tenant_id')::text, E'\n' order by (pg_catalog.to_jsonb(record) - 'tenant_id')::text), '')) from public.events record
union all
select 'event_lanes', pg_catalog.count(*), pg_catalog.md5(coalesce(pg_catalog.string_agg((pg_catalog.to_jsonb(record) - 'tenant_id')::text, E'\n' order by (pg_catalog.to_jsonb(record) - 'tenant_id')::text), '')) from public.event_lanes record
union all
select 'event_registrations', pg_catalog.count(*), pg_catalog.md5(coalesce(pg_catalog.string_agg((pg_catalog.to_jsonb(record) - 'tenant_id')::text, E'\n' order by (pg_catalog.to_jsonb(record) - 'tenant_id')::text), '')) from public.event_registrations record
union all
select 'email_deliveries', pg_catalog.count(*), pg_catalog.md5(coalesce(pg_catalog.string_agg((pg_catalog.to_jsonb(record) - 'tenant_id')::text, E'\n' order by (pg_catalog.to_jsonb(record) - 'tenant_id')::text), '')) from public.email_deliveries record
union all
select 'audit_logs', pg_catalog.count(*), pg_catalog.md5(coalesce(pg_catalog.string_agg((pg_catalog.to_jsonb(record) - 'tenant_id')::text, E'\n' order by (pg_catalog.to_jsonb(record) - 'tenant_id')::text), '')) from public.audit_logs record;

create temporary table saas9b2_security_snapshot as
select
  pg_catalog.md5(coalesce((
    select pg_catalog.string_agg(pg_catalog.pg_get_functiondef(function_record.oid), E'\n' order by function_record.oid)
    from pg_catalog.pg_proc function_record
    join pg_catalog.pg_namespace namespace on namespace.oid = function_record.pronamespace
    where namespace.nspname = 'public'
  ), '')) as function_fingerprint,
  pg_catalog.md5(coalesce((
    select pg_catalog.string_agg(pg_catalog.concat_ws('|', policy.tablename, policy.policyname, policy.cmd, policy.roles::text, policy.qual, policy.with_check), E'\n' order by policy.tablename, policy.policyname)
    from pg_catalog.pg_policies policy
    where policy.schemaname = 'public'
  ), '')) as policy_fingerprint,
  pg_catalog.md5(coalesce((
    select pg_catalog.string_agg(relation.relname || '|' || coalesce(relation.relacl::text, ''), E'\n' order by relation.relname)
    from pg_catalog.pg_class relation
    join pg_catalog.pg_namespace namespace on namespace.oid = relation.relnamespace
    where namespace.nspname = 'public' and relation.relkind in ('r', 'p')
  ), '')) as acl_fingerprint,
  (select pg_catalog.count(*) from public.tenant_memberships) as membership_count;

alter table public.shooting_lanes disable trigger set_shooting_lanes_updated_at;
alter table public.lane_blocks disable trigger lock_lane_blocks_configuration;

update public.shooting_lanes
set tenant_id = 'c5c00000-0000-4000-8000-000000000001'::uuid
where tenant_id is null;

do $hierarchy_validation$
begin
  if exists (
    select 1
    from public.shooting_lanes child
    left join public.shooting_lanes parent on parent.id = child.parent_lane_id
    where child.parent_lane_id is not null
      and (parent.id is null or child.tenant_id is distinct from parent.tenant_id)
  ) then
    raise exception 'SAAS-9B-2B failed: lane hierarchy ownership mismatch.';
  end if;
end;
$hierarchy_validation$;

update public.events
set tenant_id = 'c5c00000-0000-4000-8000-000000000001'::uuid
where tenant_id is null;

update public.reservations record
set tenant_id = lane.tenant_id
from public.shooting_lanes lane
where lane.id = record.lane_id
  and record.tenant_id is null;

update public.lane_blocks record
set tenant_id = lane.tenant_id
from public.shooting_lanes lane
where lane.id = record.lane_id
  and record.tenant_id is null;

do $event_lane_validation$
begin
  if exists (
    select 1
    from public.event_lanes relation
    join public.events event_record on event_record.id = relation.event_id
    join public.shooting_lanes lane on lane.id = relation.lane_id
    where event_record.tenant_id is distinct from lane.tenant_id
       or (relation.tenant_id is not null and relation.tenant_id is distinct from event_record.tenant_id)
  ) then
    raise exception 'SAAS-9B-2B failed: event/lane tenant mismatch.';
  end if;
end;
$event_lane_validation$;

update public.event_lanes relation
set tenant_id = event_record.tenant_id
from public.events event_record
where event_record.id = relation.event_id
  and relation.tenant_id is null;

update public.event_registrations registration
set tenant_id = event_record.tenant_id
from public.events event_record
where event_record.id = registration.event_id
  and registration.tenant_id is null;

update public.email_deliveries delivery
set tenant_id = reservation.tenant_id
from public.reservations reservation
where delivery.message_type = 'reservation_confirmation'
  and reservation.id = delivery.record_id
  and delivery.tenant_id is null;

update public.audit_logs audit
set tenant_id = reservation.tenant_id
from public.reservations reservation
where audit.target_type = 'reservation'
  and audit.target_id = reservation.id
  and audit.tenant_id is null;

update public.audit_logs audit
set tenant_id = registration.tenant_id
from public.event_registrations registration
where audit.target_type = 'event_registration'
  and audit.target_id = registration.id
  and audit.tenant_id is null;

update public.audit_logs audit
set tenant_id = lane.tenant_id
from public.shooting_lanes lane
where audit.target_type = 'lane_booking_family'
  and audit.target_id = lane.id
  and audit.tenant_id is null;

alter table public.shooting_lanes enable trigger set_shooting_lanes_updated_at;
alter table public.lane_blocks enable trigger lock_lane_blocks_configuration;

alter table public.shooting_lanes validate constraint shooting_lanes_tenant_id_fkey;
alter table public.reservations validate constraint reservations_tenant_id_fkey;
alter table public.lane_blocks validate constraint lane_blocks_tenant_id_fkey;
alter table public.events validate constraint events_tenant_id_fkey;
alter table public.event_lanes validate constraint event_lanes_tenant_id_fkey;
alter table public.event_registrations validate constraint event_registrations_tenant_id_fkey;
alter table public.email_deliveries validate constraint email_deliveries_tenant_id_fkey;
alter table public.audit_logs validate constraint audit_logs_tenant_id_fkey;

alter table public.shooting_lanes alter column tenant_id set not null;
alter table public.reservations alter column tenant_id set not null;
alter table public.lane_blocks alter column tenant_id set not null;
alter table public.events alter column tenant_id set not null;
alter table public.event_lanes alter column tenant_id set not null;
alter table public.event_registrations alter column tenant_id set not null;
alter table public.email_deliveries alter column tenant_id set not null;

do $postflight$
declare
  v_table text;
  v_current_count bigint;
  v_current_fingerprint text;
  v_snapshot record;
  v_security record;
begin
  foreach v_table in array array[
    'shooting_lanes', 'reservations', 'lane_blocks', 'events',
    'event_lanes', 'event_registrations', 'email_deliveries'
  ] loop
    if exists (
      select 1 from information_schema.columns
      where table_schema = 'public' and table_name = v_table
        and column_name = 'tenant_id' and is_nullable <> 'NO'
    ) or not exists (
      select 1 from information_schema.columns
      where table_schema = 'public' and table_name = v_table
        and column_name = 'tenant_id'
    ) then
      raise exception 'SAAS-9B-2B postflight failed: %.tenant_id is not NOT NULL.', v_table;
    end if;
  end loop;

  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'audit_logs'
      and column_name = 'tenant_id' and is_nullable = 'YES' and column_default is null
  ) then
    raise exception 'SAAS-9B-2B postflight failed: audit tenant ownership differs.';
  end if;

  if (select pg_catalog.count(*)
      from pg_catalog.pg_constraint constraint_record
      join pg_catalog.pg_class relation on relation.oid = constraint_record.conrelid
      join pg_catalog.pg_namespace namespace on namespace.oid = relation.relnamespace
      where namespace.nspname = 'public'
        and relation.relname in ('shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','email_deliveries','audit_logs')
        and constraint_record.contype = 'f'
        and constraint_record.conname = relation.relname || '_tenant_id_fkey'
        and constraint_record.convalidated) <> 8 then
    raise exception 'SAAS-9B-2B postflight failed: tenant FK validation differs.';
  end if;

  if exists (select 1 from public.shooting_lanes where tenant_id is distinct from 'c5c00000-0000-4000-8000-000000000001'::uuid)
     or exists (select 1 from public.events where tenant_id is distinct from 'c5c00000-0000-4000-8000-000000000001'::uuid)
     or exists (select 1 from public.reservations record join public.shooting_lanes lane on lane.id=record.lane_id where record.tenant_id is distinct from lane.tenant_id)
     or exists (select 1 from public.lane_blocks record join public.shooting_lanes lane on lane.id=record.lane_id where record.tenant_id is distinct from lane.tenant_id)
     or exists (select 1 from public.event_lanes relation join public.events event_record on event_record.id=relation.event_id join public.shooting_lanes lane on lane.id=relation.lane_id where relation.tenant_id is distinct from event_record.tenant_id or relation.tenant_id is distinct from lane.tenant_id)
     or exists (select 1 from public.event_registrations registration join public.events event_record on event_record.id=registration.event_id where registration.tenant_id is distinct from event_record.tenant_id)
     or exists (select 1 from public.email_deliveries delivery join public.reservations reservation on reservation.id=delivery.record_id where delivery.message_type='reservation_confirmation' and delivery.tenant_id is distinct from reservation.tenant_id) then
    raise exception 'SAAS-9B-2B postflight failed: core tenant distribution mismatch.';
  end if;

  if exists (
    with classification(action, target_type, scope) as (values
      ('lane_booking_family_created', 'lane_booking_family', 'tenant'),
      ('lane_booking_family_configuration_updated', 'lane_booking_family', 'tenant'),
      ('event_registration_approved_by_staff', 'event_registration', 'tenant'),
      ('event_registration_cancelled_by_staff', 'event_registration', 'tenant'),
      ('event_registration_cancelled_by_user', 'event_registration', 'tenant'),
      ('event_registration_payment_marked_by_staff', 'event_registration', 'tenant'),
      ('reservation_created', 'reservation', 'tenant'),
      ('reservation_cancelled_by_user', 'reservation', 'tenant'),
      ('reservation_cancelled_by_staff', 'reservation', 'tenant'),
      ('RESERVATION_ADMIN_NOTE_CHANGED', 'reservation', 'tenant'),
      ('RESERVATION_STARTED', 'reservation', 'tenant'),
      ('RESERVATION_ATTENDANCE_RESET', 'reservation', 'tenant'),
      ('CHECK_IN_COMPLETED', 'reservation', 'tenant'),
      ('RESERVATION_NO_SHOW', 'reservation', 'tenant'),
      ('RESERVATION_PAYMENT_STATUS_CHANGED', 'reservation', 'tenant'),
      ('profile_admin_note_updated', 'profile', 'global'),
      ('profile_contact_details_updated', 'profile', 'global'),
      ('profile_identity_updated', 'profile', 'global'),
      ('profile_role_changed', 'profile', 'global'),
      ('profile_verification_verified', 'profile', 'global'),
      ('profile_verification_marked_pending', 'profile', 'global'),
      ('profile_verification_rejected', 'profile', 'global'),
      ('PROFILE_PERMISSIONS_VERIFICATION_UPDATED', 'profile', 'global'),
      ('PROFILE_ROLE_CHANGED', 'profile', 'global'),
      ('PROFILE_VERIFICATION_CHANGED', 'profile', 'global'),
      ('account_anonymized', 'account', 'global')
    )
    select 1
    from public.audit_logs audit
    join classification known on known.action=audit.action and known.target_type=audit.target_type
    where (known.scope='tenant' and audit.tenant_id is null)
       or (known.scope='global' and audit.tenant_id is not null)
  ) then
    raise exception 'SAAS-9B-2B postflight failed: audit classification mismatch.';
  end if;

  for v_snapshot in select * from saas9b2_business_snapshot loop
    execute pg_catalog.format(
      'select count(*), md5(coalesce(string_agg((to_jsonb(record)-''tenant_id'')::text, E''\n'' order by (to_jsonb(record)-''tenant_id'')::text),'''')) from public.%I record',
      v_snapshot.table_name
    ) into v_current_count, v_current_fingerprint;

    if v_current_count is distinct from v_snapshot.row_count
       or v_current_fingerprint is distinct from v_snapshot.business_fingerprint then
      raise exception 'SAAS-9B-2B postflight failed: business fingerprint changed for %.', v_snapshot.table_name;
    end if;
  end loop;

  select * into v_security from saas9b2_security_snapshot;

  if v_security.function_fingerprint is distinct from pg_catalog.md5(coalesce((
       select pg_catalog.string_agg(pg_catalog.pg_get_functiondef(function_record.oid), E'\n' order by function_record.oid)
       from pg_catalog.pg_proc function_record
       join pg_catalog.pg_namespace namespace on namespace.oid=function_record.pronamespace
       where namespace.nspname='public'
     ), ''))
     or v_security.policy_fingerprint is distinct from pg_catalog.md5(coalesce((
       select pg_catalog.string_agg(pg_catalog.concat_ws('|', policy.tablename, policy.policyname, policy.cmd, policy.roles::text, policy.qual, policy.with_check), E'\n' order by policy.tablename, policy.policyname)
       from pg_catalog.pg_policies policy where policy.schemaname='public'
     ), ''))
     or v_security.acl_fingerprint is distinct from pg_catalog.md5(coalesce((
       select pg_catalog.string_agg(relation.relname || '|' || coalesce(relation.relacl::text,''), E'\n' order by relation.relname)
       from pg_catalog.pg_class relation join pg_catalog.pg_namespace namespace on namespace.oid=relation.relnamespace
       where namespace.nspname='public' and relation.relkind in ('r','p')
     ), ''))
     or v_security.membership_count is distinct from (select pg_catalog.count(*) from public.tenant_memberships) then
    raise exception 'SAAS-9B-2B postflight failed: runtime security contract changed.';
  end if;

  if not exists (
    select 1 from pg_catalog.pg_indexes
    where schemaname='public' and tablename='tenants'
      and indexname='tenants_single_active_runtime_guard'
  ) or (select pg_catalog.count(*) from public.tenants where status='active') <> 1 then
    raise exception 'SAAS-9B-2B postflight failed: second-tenant guard differs.';
  end if;
end;
$postflight$;

drop table saas9b2_security_snapshot;
drop table saas9b2_business_snapshot;

reset statement_timeout;
reset lock_timeout;
