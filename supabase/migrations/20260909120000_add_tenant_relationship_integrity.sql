-- SAAS-9B-3A: enforce tenant consistency across existing relationships.
-- Runtime authorization remains legacy/single-tenant until SAAS-9C/9D.

set lock_timeout = '5s';
set statement_timeout = '120s';

do $preflight$
begin
  if (select pg_catalog.count(*) from public.tenants) <> 1
     or not exists (
       select 1 from public.tenants
       where id = 'c5c00000-0000-4000-8000-000000000001'::uuid
         and name = 'CSK' and slug = 'csk' and status = 'active'
     )
     or (select pg_catalog.count(*) from public.tenants where status = 'active') <> 1 then
    raise exception 'SAAS-9B-3A preflight failed: canonical CSK tenant differs.';
  end if;

  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name in ('shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','email_deliveries')
      and column_name = 'tenant_id'
      and (is_nullable <> 'NO' or column_default is distinct from '''c5c00000-0000-4000-8000-000000000001''::uuid')
  ) or (select pg_catalog.count(*) from information_schema.columns
        where table_schema = 'public'
          and table_name in ('shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','email_deliveries')
          and column_name = 'tenant_id') <> 7
     or not exists (
       select 1 from information_schema.columns
       where table_schema = 'public' and table_name = 'audit_logs'
         and column_name = 'tenant_id' and is_nullable = 'YES' and column_default is null
     ) then
    raise exception 'SAAS-9B-3A preflight failed: SAAS-9B-2 ownership/default state differs.';
  end if;

  if pg_catalog.pg_get_constraintdef((select oid from pg_catalog.pg_constraint where conrelid='public.shooting_lanes'::regclass and conname='shooting_lanes_parent_lane_id_fkey'))
       <> 'FOREIGN KEY (parent_lane_id) REFERENCES shooting_lanes(id) ON DELETE RESTRICT'
     or pg_catalog.pg_get_constraintdef((select oid from pg_catalog.pg_constraint where conrelid='public.reservations'::regclass and conname='reservations_lane_id_fkey'))
       <> 'FOREIGN KEY (lane_id) REFERENCES shooting_lanes(id) ON DELETE RESTRICT'
     or pg_catalog.pg_get_constraintdef((select oid from pg_catalog.pg_constraint where conrelid='public.reservations'::regclass and conname='reservations_pricing_rule_id_fkey'))
       <> 'FOREIGN KEY (pricing_rule_id) REFERENCES lane_pricing_rules(id) ON DELETE RESTRICT'
     or pg_catalog.pg_get_constraintdef((select oid from pg_catalog.pg_constraint where conrelid='public.lane_blocks'::regclass and conname='lane_blocks_lane_id_fkey'))
       <> 'FOREIGN KEY (lane_id) REFERENCES shooting_lanes(id) ON DELETE RESTRICT'
     or pg_catalog.pg_get_constraintdef((select oid from pg_catalog.pg_constraint where conrelid='public.event_lanes'::regclass and conname='event_lanes_event_id_fkey'))
       <> 'FOREIGN KEY (event_id) REFERENCES events(id) ON DELETE CASCADE'
     or pg_catalog.pg_get_constraintdef((select oid from pg_catalog.pg_constraint where conrelid='public.event_lanes'::regclass and conname='event_lanes_lane_id_fkey'))
       <> 'FOREIGN KEY (lane_id) REFERENCES shooting_lanes(id) ON DELETE RESTRICT'
     or pg_catalog.pg_get_constraintdef((select oid from pg_catalog.pg_constraint where conrelid='public.event_registrations'::regclass and conname='event_registrations_event_id_fkey'))
       <> 'FOREIGN KEY (event_id) REFERENCES events(id) ON DELETE CASCADE' then
    raise exception 'SAAS-9B-3A preflight failed: simple FK contract differs.';
  end if;

  if exists (select 1 from public.shooting_lanes child join public.shooting_lanes parent on parent.id=child.parent_lane_id where child.tenant_id is distinct from parent.tenant_id)
     or exists (select 1 from public.reservations record join public.shooting_lanes lane on lane.id=record.lane_id where record.tenant_id is distinct from lane.tenant_id)
     or exists (select 1 from public.reservations record join public.lane_pricing_rules price on price.id=record.pricing_rule_id where record.lane_id is distinct from price.lane_id)
     or exists (select 1 from public.lane_blocks record join public.shooting_lanes lane on lane.id=record.lane_id where record.tenant_id is distinct from lane.tenant_id)
     or exists (select 1 from public.event_lanes relation join public.events event_record on event_record.id=relation.event_id join public.shooting_lanes lane on lane.id=relation.lane_id where relation.tenant_id is distinct from event_record.tenant_id or relation.tenant_id is distinct from lane.tenant_id)
     or exists (select 1 from public.event_registrations registration join public.events event_record on event_record.id=registration.event_id where registration.tenant_id is distinct from event_record.tenant_id) then
    raise exception 'SAAS-9B-3A preflight failed: relationship tenant mismatch exists.';
  end if;

  if exists (
    select 1 from public.email_deliveries delivery
    left join public.reservations reservation
      on delivery.message_type in ('reservation_confirmation','reservation_cancellation') and reservation.id=delivery.record_id
    left join public.event_registrations registration
      on delivery.message_type='event_registration_confirmation' and registration.id=delivery.record_id
    where delivery.message_type not in ('reservation_confirmation','reservation_cancellation','event_registration_confirmation')
       or (delivery.message_type in ('reservation_confirmation','reservation_cancellation') and (reservation.id is null or delivery.tenant_id is distinct from reservation.tenant_id))
       or (delivery.message_type='event_registration_confirmation' and (registration.id is null or delivery.tenant_id is distinct from registration.tenant_id))
  ) then
    raise exception 'SAAS-9B-3A preflight failed: email delivery mapping is unknown, orphaned, or mismatched.';
  end if;

  if exists (
    select 1 from public.audit_logs audit
    left join public.reservations reservation on audit.target_type='reservation' and reservation.id=audit.target_id
    left join public.event_registrations registration on audit.target_type='event_registration' and registration.id=audit.target_id
    left join public.shooting_lanes lane on audit.target_type='lane_booking_family' and lane.id=audit.target_id
    where audit.target_type not in ('reservation','event_registration','lane_booking_family','profile','account')
       or (audit.target_type='reservation' and (reservation.id is null or audit.tenant_id is distinct from reservation.tenant_id))
       or (audit.target_type='event_registration' and (registration.id is null or audit.tenant_id is distinct from registration.tenant_id))
       or (audit.target_type='lane_booking_family' and (lane.id is null or audit.tenant_id is distinct from lane.tenant_id))
       or (audit.target_type in ('profile','account') and audit.tenant_id is not null)
  ) then
    raise exception 'SAAS-9B-3A preflight failed: audit ownership classification differs.';
  end if;

  if exists (
    select 1 from pg_catalog.pg_constraint
    where conname in (
      'shooting_lanes_tenant_id_id_key','lane_pricing_rules_lane_id_id_key','events_tenant_id_id_key',
      'shooting_lanes_tenant_parent_lane_id_fkey','reservations_tenant_lane_id_fkey',
      'reservations_lane_pricing_rule_id_fkey','lane_blocks_tenant_lane_id_fkey',
      'event_lanes_tenant_event_id_fkey','event_lanes_tenant_lane_id_fkey',
      'event_registrations_tenant_event_id_fkey'
    )
  ) or to_regprocedure('public.set_email_delivery_tenant_id()') is not null
     or to_regprocedure('public.set_audit_log_tenant_id()') is not null then
    raise exception 'SAAS-9B-3A preflight failed: planned integrity objects already exist.';
  end if;
end;
$preflight$;

create temporary table saas9b3a_security_snapshot as
select
  pg_catalog.md5(coalesce((select pg_catalog.string_agg(pg_catalog.concat_ws('|',tablename,policyname,cmd,roles::text,qual,with_check),E'\n' order by tablename,policyname) from pg_catalog.pg_policies where schemaname='public'),'')) as policy_fingerprint,
  pg_catalog.md5(coalesce((select pg_catalog.string_agg(relation.relname||'|'||coalesce(relation.relacl::text,''),E'\n' order by relation.relname) from pg_catalog.pg_class relation join pg_catalog.pg_namespace namespace on namespace.oid=relation.relnamespace where namespace.nspname='public' and relation.relkind in ('r','p')),'')) as acl_fingerprint,
  pg_catalog.md5(pg_catalog.pg_get_functiondef('public.get_my_role()'::regprocedure)) as role_rpc,
  pg_catalog.md5(pg_catalog.pg_get_functiondef('public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)'::regprocedure)) as reservation_rpc,
  (select pg_catalog.count(*) from public.tenant_memberships) as membership_count;

alter table public.shooting_lanes
  add constraint shooting_lanes_tenant_id_id_key unique (tenant_id,id);
alter table public.lane_pricing_rules
  add constraint lane_pricing_rules_lane_id_id_key unique (lane_id,id);
alter table public.events
  add constraint events_tenant_id_id_key unique (tenant_id,id);

alter table public.shooting_lanes
  add constraint shooting_lanes_tenant_parent_lane_id_fkey
  foreign key (tenant_id,parent_lane_id) references public.shooting_lanes(tenant_id,id)
  on delete restrict not valid;
alter table public.reservations
  add constraint reservations_tenant_lane_id_fkey
  foreign key (tenant_id,lane_id) references public.shooting_lanes(tenant_id,id)
  on delete restrict not valid;
alter table public.reservations
  add constraint reservations_lane_pricing_rule_id_fkey
  foreign key (lane_id,pricing_rule_id) references public.lane_pricing_rules(lane_id,id)
  on delete restrict not valid;
alter table public.lane_blocks
  add constraint lane_blocks_tenant_lane_id_fkey
  foreign key (tenant_id,lane_id) references public.shooting_lanes(tenant_id,id)
  on delete restrict not valid;
alter table public.event_lanes
  add constraint event_lanes_tenant_event_id_fkey
  foreign key (tenant_id,event_id) references public.events(tenant_id,id)
  on delete cascade not valid;
alter table public.event_lanes
  add constraint event_lanes_tenant_lane_id_fkey
  foreign key (tenant_id,lane_id) references public.shooting_lanes(tenant_id,id)
  on delete restrict not valid;
alter table public.event_registrations
  add constraint event_registrations_tenant_event_id_fkey
  foreign key (tenant_id,event_id) references public.events(tenant_id,id)
  match simple on delete cascade not valid;

alter table public.shooting_lanes validate constraint shooting_lanes_tenant_parent_lane_id_fkey;
alter table public.reservations validate constraint reservations_tenant_lane_id_fkey;
alter table public.reservations validate constraint reservations_lane_pricing_rule_id_fkey;
alter table public.lane_blocks validate constraint lane_blocks_tenant_lane_id_fkey;
alter table public.event_lanes validate constraint event_lanes_tenant_event_id_fkey;
alter table public.event_lanes validate constraint event_lanes_tenant_lane_id_fkey;
alter table public.event_registrations validate constraint event_registrations_tenant_event_id_fkey;

alter table public.shooting_lanes drop constraint shooting_lanes_parent_lane_id_fkey;
alter table public.shooting_lanes rename constraint shooting_lanes_tenant_parent_lane_id_fkey to shooting_lanes_parent_lane_id_fkey;
alter table public.reservations drop constraint reservations_lane_id_fkey;
alter table public.reservations rename constraint reservations_tenant_lane_id_fkey to reservations_lane_id_fkey;
alter table public.reservations drop constraint reservations_pricing_rule_id_fkey;
alter table public.reservations rename constraint reservations_lane_pricing_rule_id_fkey to reservations_pricing_rule_id_fkey;
alter table public.lane_blocks drop constraint lane_blocks_lane_id_fkey;
alter table public.lane_blocks rename constraint lane_blocks_tenant_lane_id_fkey to lane_blocks_lane_id_fkey;
alter table public.event_lanes drop constraint event_lanes_event_id_fkey;
alter table public.event_lanes rename constraint event_lanes_tenant_event_id_fkey to event_lanes_event_id_fkey;
alter table public.event_lanes drop constraint event_lanes_lane_id_fkey;
alter table public.event_lanes rename constraint event_lanes_tenant_lane_id_fkey to event_lanes_lane_id_fkey;
alter table public.event_registrations drop constraint event_registrations_event_id_fkey;
alter table public.event_registrations rename constraint event_registrations_tenant_event_id_fkey to event_registrations_event_id_fkey;

create function public.set_email_delivery_tenant_id()
returns trigger
language plpgsql
security invoker
set search_path = pg_catalog
as $function$
declare
  v_tenant_id uuid;
begin
  if new.message_type in ('reservation_confirmation','reservation_cancellation') then
    select record.tenant_id into v_tenant_id
    from public.reservations record where record.id=new.record_id;
  elsif new.message_type='event_registration_confirmation' then
    select record.tenant_id into v_tenant_id
    from public.event_registrations record where record.id=new.record_id;
  else
    raise exception using errcode='23514', message='unsupported_email_delivery_message_type';
  end if;

  if v_tenant_id is null then
    raise exception using errcode='23503', message='email_delivery_target_not_found';
  end if;
  if new.tenant_id is not null and new.tenant_id is distinct from v_tenant_id then
    raise exception using errcode='23514', message='email_delivery_tenant_mismatch';
  end if;
  new.tenant_id := v_tenant_id;
  return new;
end;
$function$;

alter function public.set_email_delivery_tenant_id() owner to postgres;
revoke all on function public.set_email_delivery_tenant_id() from public, anon, authenticated, service_role;

create trigger set_email_delivery_tenant_id
before insert or update on public.email_deliveries
for each row execute function public.set_email_delivery_tenant_id();

create function public.set_audit_log_tenant_id()
returns trigger
language plpgsql
security invoker
set search_path = pg_catalog
as $function$
declare
  v_tenant_id uuid;
begin
  case new.target_type
    when 'reservation' then
      select record.tenant_id into v_tenant_id from public.reservations record where record.id=new.target_id;
    when 'event_registration' then
      select record.tenant_id into v_tenant_id from public.event_registrations record where record.id=new.target_id;
    when 'lane_booking_family' then
      select record.tenant_id into v_tenant_id from public.shooting_lanes record where record.id=new.target_id;
    when 'profile','account' then
      if new.tenant_id is not null then
        raise exception using errcode='23514', message='global_audit_must_not_have_tenant';
      end if;
      return new;
    else
      raise exception using errcode='23514', message='unsupported_audit_target_type';
  end case;

  if v_tenant_id is null then
    raise exception using errcode='23503', message='audit_target_not_found';
  end if;
  if new.tenant_id is not null and new.tenant_id is distinct from v_tenant_id then
    raise exception using errcode='23514', message='audit_tenant_mismatch';
  end if;
  new.tenant_id := v_tenant_id;
  return new;
end;
$function$;

alter function public.set_audit_log_tenant_id() owner to postgres;
revoke all on function public.set_audit_log_tenant_id() from public, anon, authenticated, service_role;

create trigger set_audit_log_tenant_id
before insert or update on public.audit_logs
for each row execute function public.set_audit_log_tenant_id();

do $postflight$
declare
  v_snapshot record;
begin
  if pg_catalog.pg_get_constraintdef((select oid from pg_catalog.pg_constraint where conrelid='public.shooting_lanes'::regclass and conname='shooting_lanes_parent_lane_id_fkey'))
       <> 'FOREIGN KEY (tenant_id, parent_lane_id) REFERENCES shooting_lanes(tenant_id, id) ON DELETE RESTRICT'
     or pg_catalog.pg_get_constraintdef((select oid from pg_catalog.pg_constraint where conrelid='public.reservations'::regclass and conname='reservations_lane_id_fkey'))
       <> 'FOREIGN KEY (tenant_id, lane_id) REFERENCES shooting_lanes(tenant_id, id) ON DELETE RESTRICT'
     or pg_catalog.pg_get_constraintdef((select oid from pg_catalog.pg_constraint where conrelid='public.reservations'::regclass and conname='reservations_pricing_rule_id_fkey'))
       <> 'FOREIGN KEY (lane_id, pricing_rule_id) REFERENCES lane_pricing_rules(lane_id, id) ON DELETE RESTRICT'
     or pg_catalog.pg_get_constraintdef((select oid from pg_catalog.pg_constraint where conrelid='public.lane_blocks'::regclass and conname='lane_blocks_lane_id_fkey'))
       <> 'FOREIGN KEY (tenant_id, lane_id) REFERENCES shooting_lanes(tenant_id, id) ON DELETE RESTRICT'
     or pg_catalog.pg_get_constraintdef((select oid from pg_catalog.pg_constraint where conrelid='public.event_lanes'::regclass and conname='event_lanes_event_id_fkey'))
       <> 'FOREIGN KEY (tenant_id, event_id) REFERENCES events(tenant_id, id) ON DELETE CASCADE'
     or pg_catalog.pg_get_constraintdef((select oid from pg_catalog.pg_constraint where conrelid='public.event_lanes'::regclass and conname='event_lanes_lane_id_fkey'))
       <> 'FOREIGN KEY (tenant_id, lane_id) REFERENCES shooting_lanes(tenant_id, id) ON DELETE RESTRICT'
     or pg_catalog.pg_get_constraintdef((select oid from pg_catalog.pg_constraint where conrelid='public.event_registrations'::regclass and conname='event_registrations_event_id_fkey'))
       <> 'FOREIGN KEY (tenant_id, event_id) REFERENCES events(tenant_id, id) ON DELETE CASCADE' then
    raise exception 'SAAS-9B-3A postflight failed: composite FK contract differs.';
  end if;

  if (select pg_catalog.count(*) from pg_catalog.pg_constraint where conname in ('shooting_lanes_tenant_id_id_key','lane_pricing_rules_lane_id_id_key','events_tenant_id_id_key') and contype='u' and convalidated) <> 3
     or (select pg_catalog.count(*) from pg_catalog.pg_constraint where conname in ('shooting_lanes_parent_lane_id_fkey','reservations_lane_id_fkey','reservations_pricing_rule_id_fkey','lane_blocks_lane_id_fkey','event_lanes_event_id_fkey','event_lanes_lane_id_fkey','event_registrations_event_id_fkey') and contype='f' and convalidated) <> 7 then
    raise exception 'SAAS-9B-3A postflight failed: key inventory differs.';
  end if;

  if (select pg_catalog.count(*) from pg_catalog.pg_trigger where not tgisinternal and tgname in ('set_email_delivery_tenant_id','set_audit_log_tenant_id') and tgenabled='O') <> 2
     or (select pg_catalog.count(*) from pg_catalog.pg_proc function_record join pg_catalog.pg_namespace namespace on namespace.oid=function_record.pronamespace where namespace.nspname='public' and function_record.proname in ('set_email_delivery_tenant_id','set_audit_log_tenant_id') and function_record.prosecdef) <> 0 then
    raise exception 'SAAS-9B-3A postflight failed: trigger security model differs.';
  end if;

  select * into v_snapshot from saas9b3a_security_snapshot;
  if v_snapshot.policy_fingerprint is distinct from pg_catalog.md5(coalesce((select pg_catalog.string_agg(pg_catalog.concat_ws('|',tablename,policyname,cmd,roles::text,qual,with_check),E'\n' order by tablename,policyname) from pg_catalog.pg_policies where schemaname='public'),''))
     or v_snapshot.acl_fingerprint is distinct from pg_catalog.md5(coalesce((select pg_catalog.string_agg(relation.relname||'|'||coalesce(relation.relacl::text,''),E'\n' order by relation.relname) from pg_catalog.pg_class relation join pg_catalog.pg_namespace namespace on namespace.oid=relation.relnamespace where namespace.nspname='public' and relation.relkind in ('r','p')),''))
     or v_snapshot.role_rpc is distinct from pg_catalog.md5(pg_catalog.pg_get_functiondef('public.get_my_role()'::regprocedure))
     or v_snapshot.reservation_rpc is distinct from pg_catalog.md5(pg_catalog.pg_get_functiondef('public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)'::regprocedure))
     or v_snapshot.membership_count is distinct from (select pg_catalog.count(*) from public.tenant_memberships) then
    raise exception 'SAAS-9B-3A postflight failed: security/runtime fingerprint changed.';
  end if;
end;
$postflight$;
