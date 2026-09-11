\set ON_ERROR_STOP on
\pset format unaligned

select '1..32';

begin;

create temporary table test_results (
  test_order integer primary key,
  test_name text not null,
  passed boolean not null,
  result text not null
) on commit drop;

create function pg_temp.ok(integer, text, boolean, text)
returns void language sql as $function$
  insert into pg_temp.test_results values ($1, $2, coalesce($3, false), $4);
$function$;

create function pg_temp.statement_raises(p_sql text, p_state text)
returns boolean language plpgsql as $function$
begin
  execute p_sql;
  return false;
exception when others then
  return sqlstate = p_state;
end;
$function$;

do $tests$
declare
  v_csk constant uuid := 'c5c00000-0000-4000-8000-000000000001'::uuid;
  v_root uuid := pg_catalog.gen_random_uuid();
  v_event uuid := pg_catalog.gen_random_uuid();
  v_audit uuid := pg_catalog.gen_random_uuid();
begin
  perform pg_temp.ok(1, 'canonical CSK tenant remains sole active tenant',
    (select pg_catalog.count(*) = 1 from public.tenants)
    and exists(select 1 from public.tenants where id=v_csk and name='CSK' and slug='csk' and status='active')
    and (select pg_catalog.count(*) = 1 from public.tenants where status='active'),
    'Canonical tenant invariant differs.');

  perform pg_temp.ok(2, 'exact tenant ownership column inventory',
    (select pg_catalog.count(*) = 8
     from information_schema.columns
     where table_schema='public' and column_name='tenant_id'
       and table_name in ('shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','email_deliveries','audit_logs')),
    'Expected eight ownership columns.');

  perform pg_temp.ok(3, 'tenant ownership columns use UUID',
    not exists(select 1 from information_schema.columns where table_schema='public' and column_name='tenant_id' and table_name in ('shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','email_deliveries','audit_logs') and not(udt_schema='pg_catalog' and udt_name='uuid')),
    'Every ownership column must match tenants.id UUID type.');

  perform pg_temp.ok(4, 'core tenant ownership is NOT NULL',
    (select pg_catalog.count(*) = 7 from information_schema.columns where table_schema='public' and column_name='tenant_id' and is_nullable='NO' and table_name in ('shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','email_deliveries')),
    'Seven core/delivery ownership columns must be NOT NULL.');

  perform pg_temp.ok(5, 'audit ownership remains nullable',
    exists(select 1 from information_schema.columns where table_schema='public' and table_name='audit_logs' and column_name='tenant_id' and is_nullable='YES'),
    'Mixed audit ownership must remain nullable.');

  perform pg_temp.ok(6, 'temporary CSK defaults exist only on approved core tables',
    (select pg_catalog.count(*) = 7 from information_schema.columns where table_schema='public' and column_name='tenant_id' and table_name in ('shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','email_deliveries') and column_default = '''c5c00000-0000-4000-8000-000000000001''::uuid'),
    'Approved temporary defaults differ.');

  perform pg_temp.ok(7, 'audit has no tenant default',
    exists(select 1 from information_schema.columns where table_schema='public' and table_name='audit_logs' and column_name='tenant_id' and column_default is null),
    'Audit tenant_id must not have a default.');

  perform pg_temp.ok(8, 'all eight tenant foreign keys are validated',
    (select pg_catalog.count(*) = 8
     from pg_catalog.pg_constraint constraint_record
     join pg_catalog.pg_class relation on relation.oid=constraint_record.conrelid
     join pg_catalog.pg_namespace namespace on namespace.oid=relation.relnamespace
     where namespace.nspname='public' and constraint_record.contype='f'
       and relation.relname in ('shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','email_deliveries','audit_logs')
       and constraint_record.conname=relation.relname||'_tenant_id_fkey'
       and constraint_record.convalidated),
    'All ownership FKs must be present and validated.');

  perform pg_temp.ok(9, 'all ownership foreign keys reference tenants id',
    not exists(
      select 1
      from pg_catalog.pg_constraint constraint_record
      join pg_catalog.pg_class relation on relation.oid=constraint_record.conrelid
      where constraint_record.conname=relation.relname||'_tenant_id_fkey'
        and relation.relname in ('shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','email_deliveries','audit_logs')
        and constraint_record.confrelid <> 'public.tenants'::pg_catalog.regclass
    ),
    'Ownership FK target differs.');

  perform pg_temp.ok(10, 'all existing core rows have CSK ownership',
    not exists(select 1 from public.shooting_lanes where tenant_id is distinct from v_csk)
    and not exists(select 1 from public.reservations where tenant_id is distinct from v_csk)
    and not exists(select 1 from public.lane_blocks where tenant_id is distinct from v_csk)
    and not exists(select 1 from public.events where tenant_id is distinct from v_csk)
    and not exists(select 1 from public.event_lanes where tenant_id is distinct from v_csk)
    and not exists(select 1 from public.event_registrations where tenant_id is distinct from v_csk)
    and not exists(select 1 from public.email_deliveries where tenant_id is distinct from v_csk),
    'Current single-tenant core distribution differs.');

  perform pg_temp.ok(11, 'lane hierarchy ownership is consistent',
    not exists(select 1 from public.shooting_lanes child join public.shooting_lanes parent on parent.id=child.parent_lane_id where child.tenant_id is distinct from parent.tenant_id),
    'Child and parent ownership differ.');

  perform pg_temp.ok(12, 'reservation ownership follows lane',
    not exists(select 1 from public.reservations record join public.shooting_lanes lane on lane.id=record.lane_id where record.tenant_id is distinct from lane.tenant_id),
    'Reservation/lane ownership differs.');

  perform pg_temp.ok(13, 'lane block ownership follows lane',
    not exists(select 1 from public.lane_blocks record join public.shooting_lanes lane on lane.id=record.lane_id where record.tenant_id is distinct from lane.tenant_id),
    'Lane-block/lane ownership differs.');

  perform pg_temp.ok(14, 'event-lane ownership follows event',
    not exists(select 1 from public.event_lanes relation join public.events event_record on event_record.id=relation.event_id where relation.tenant_id is distinct from event_record.tenant_id),
    'Event-lane/event ownership differs.');

  perform pg_temp.ok(15, 'event-lane ownership matches lane',
    not exists(select 1 from public.event_lanes relation join public.shooting_lanes lane on lane.id=relation.lane_id where relation.tenant_id is distinct from lane.tenant_id),
    'Event-lane/lane ownership differs.');

  perform pg_temp.ok(16, 'event registration ownership follows event',
    not exists(select 1 from public.event_registrations registration join public.events event_record on event_record.id=registration.event_id where registration.tenant_id is distinct from event_record.tenant_id),
    'Event-registration/event ownership differs.');

  perform pg_temp.ok(17, 'email delivery classification remains recognized',
    not exists(select 1 from public.email_deliveries where message_type <> 'reservation_confirmation'),
    'Unknown delivery type exists for the approved production backfill.');

  perform pg_temp.ok(18, 'email delivery ownership follows reservation target',
    not exists(select 1 from public.email_deliveries delivery join public.reservations reservation on reservation.id=delivery.record_id where delivery.message_type='reservation_confirmation' and delivery.tenant_id is distinct from reservation.tenant_id),
    'Delivery/reservation ownership differs.');

  perform pg_temp.ok(19, 'tenant-scoped audits have ownership',
    not exists(select 1 from public.audit_logs where target_type in ('reservation','event_registration','lane_booking_family') and tenant_id is null),
    'Tenant-scoped audit is unowned.');

  perform pg_temp.ok(20, 'global account/profile audits remain unowned',
    not exists(select 1 from public.audit_logs where target_type in ('profile','account') and tenant_id is not null),
    'Global audit was incorrectly assigned to CSK.');

  insert into public.shooting_lanes(id,name,type,is_active,max_shooters,booking_step_minutes,display_order,resource_kind,parent_lane_id,whole_lane_bookable,positions_bookable)
  values(v_root,'[TEST][SAAS-9B-2] Default root','shooting',false,1,60,9990,'lane',null,false,false);
  perform pg_temp.ok(21, 'legacy lane insert receives CSK default',
    (select tenant_id=v_csk from public.shooting_lanes where id=v_root),
    'Legacy lane default did not apply.');

  insert into public.events(id,title,event_date,start_time,end_time,location,price,max_participants,is_active)
  values(v_event,'[TEST][SAAS-9B-2] Default event',date '2099-12-01',time '10:00',time '11:00','[TEST]',0,1,false);
  perform pg_temp.ok(22, 'legacy event insert receives CSK default',
    (select tenant_id=v_csk from public.events where id=v_event),
    'Legacy event default did not apply.');

  insert into public.audit_logs(id,actor_name,actor_role,action,target_type,target_id,target_name)
  values(v_audit,'[TEST]','user','profile_identity_updated','profile',pg_catalog.gen_random_uuid(),'[TEST]');
  perform pg_temp.ok(23, 'global audit insert remains NULL by default',
    (select tenant_id is null from public.audit_logs where id=v_audit),
    'Audit received an implicit tenant.');

  perform pg_temp.ok(24, 'unknown tenant FK fails closed',
    pg_temp.statement_raises(pg_catalog.format(
      'insert into public.events(title,event_date,start_time,end_time,tenant_id) values (''[TEST]'',date ''2099-12-02'',time ''10:00'',time ''11:00'',%L::uuid)',
      pg_catalog.gen_random_uuid()
    ), '23503'),
    'Unknown tenant reference was accepted.');

  perform pg_temp.ok(25, 'second active tenant remains denied',
    pg_temp.statement_raises('insert into public.tenants(name,slug,status) values (''[TEST]'',''saas9b2-second-active'',''active'')','23505'),
    'Single-active guard regressed.');

  perform pg_temp.ok(26, 'profiles role remains the legacy source',
    exists(select 1 from information_schema.columns where table_schema='public' and table_name='profiles' and column_name='role')
    and position('profiles' in pg_catalog.pg_get_functiondef('public.get_my_role()'::pg_catalog.regprocedure)) > 0,
    'Legacy role source changed.');

  perform pg_temp.ok(27, 'CSK memberships are activated without replacing legacy auth',
    not exists(
      select 1 from public.profiles profile
      left join public.tenant_memberships membership
        on membership.tenant_id='c5c00000-0000-4000-8000-000000000001'::uuid and membership.user_id=profile.user_id
      where membership.user_id is null
         or membership.role is distinct from public.legacy_profile_role_to_tenant_role_v1(profile.role)
    )
    and pg_catalog.to_regprocedure('public.is_tenant_member_v1(uuid)') is not null,
    'Membership activation or reconciliation differs.');

  perform pg_temp.ok(28, 'excluded tables did not receive tenant ownership',
    not exists(select 1 from information_schema.columns where table_schema='public' and column_name='tenant_id' and table_name in ('profiles','lane_booking_rules','lane_booking_durations','lane_pricing_rules','lane_booking_family_configuration_versions','confirmation_email_rate_limits','tenants'))
    and exists(select 1 from pg_catalog.pg_constraint where conrelid='public.tenant_memberships'::pg_catalog.regclass and conname='tenant_memberships_pkey' and contype='p'),
    'Out-of-scope ownership column exists.');

  perform pg_temp.ok(29, 'later approved RLS remains isolated to approved SAAS-9C tables',
    (select pg_catalog.md5(coalesce(pg_catalog.string_agg(pg_catalog.concat_ws('|',tablename,policyname,cmd,roles::text,qual,with_check),E'\n' order by tablename,policyname),''))='d41d8cd98f00b204e9800998ecf8427e' from pg_catalog.pg_policies where schemaname='public' and tablename not in ('tenant_memberships','shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','audit_logs','profiles','lane_booking_rules','lane_booking_durations','lane_pricing_rules'))
    and (select pg_catalog.count(*)=1 from pg_catalog.pg_policies where schemaname='public' and tablename='tenant_memberships')
    and (select pg_catalog.count(*)=6 from pg_catalog.pg_policies where schemaname='public' and tablename in ('shooting_lanes','reservations','lane_blocks') and cmd='SELECT')
    and (select pg_catalog.count(*)=6 from pg_catalog.pg_policies where schemaname='public' and tablename in ('events','event_lanes','event_registrations') and cmd='SELECT')
    and (select pg_catalog.count(*)=9 from pg_catalog.pg_policies where schemaname='public' and tablename in ('audit_logs','profiles','lane_booking_rules','lane_booking_durations','lane_pricing_rules') and cmd='SELECT'),
    'RLS changed outside the approved SAAS-9C phases.');

  perform pg_temp.ok(30, 'only membership self-read table ACL was added',
    pg_catalog.has_table_privilege('authenticated','public.tenant_memberships','SELECT')
    and not pg_catalog.has_table_privilege('authenticated','public.tenant_memberships','INSERT,UPDATE,DELETE')
    and not pg_catalog.has_table_privilege('anon','public.tenant_memberships','SELECT,INSERT,UPDATE,DELETE')
    and not pg_catalog.has_table_privilege('service_role','public.tenant_memberships','SELECT,INSERT,UPDATE,DELETE')
    and not pg_catalog.has_table_privilege('authenticated','public.tenants','SELECT,INSERT,UPDATE,DELETE'),
    'Membership/tenant ACL is broader than the SAAS-9C-1 contract.');

  perform pg_temp.ok(31, 'critical RPC definitions are unchanged',
    pg_catalog.md5(pg_catalog.pg_get_functiondef('public.get_my_role()'::pg_catalog.regprocedure))='dc8858eed7d2fd2d1ab47d22b0000b06'
    and pg_catalog.md5(pg_catalog.pg_get_functiondef('public.is_admin()'::pg_catalog.regprocedure))='89a221fa092af2a457db05a64b7e8d18'
    and pg_catalog.md5(pg_catalog.pg_get_functiondef('public.is_admin_or_employee()'::pg_catalog.regprocedure))='39651299fec2cf87a98500395ecc88ac'
    and pg_catalog.md5(pg_catalog.pg_get_functiondef('public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)'::pg_catalog.regprocedure))='3f201f96dc413736d564089536b98d7d',
    'Critical function fingerprint changed.');

  perform pg_temp.ok(32, 'temporarily disabled backfill triggers are enabled',
    exists(select 1 from pg_catalog.pg_trigger where tgrelid='public.shooting_lanes'::pg_catalog.regclass and tgname='set_shooting_lanes_updated_at' and tgenabled='O')
    and exists(select 1 from pg_catalog.pg_trigger where tgrelid='public.lane_blocks'::pg_catalog.regclass and tgname='lock_lane_blocks_configuration' and tgenabled='O'),
    'Backfill trigger state was not restored.');
end;
$tests$;

select (case when passed then 'ok ' else 'not ok ' end) || test_order || ' - ' || test_name || case when passed then '' else E'\n# ' || result end
from pg_temp.test_results
order by test_order;

do $assert$
declare
  v_failed text;
begin
  if (select pg_catalog.count(*) from pg_temp.test_results) <> 32 then
    raise exception 'SAAS-9B-2 expected exactly 32 checks.';
  end if;

  select pg_catalog.string_agg(test_order || '. ' || test_name || ': ' || result, E'\n' order by test_order)
  into v_failed
  from pg_temp.test_results
  where not passed;

  if v_failed is not null then
    raise exception E'SAAS-9B-2 failures:\n%', v_failed;
  end if;
end;
$assert$;

rollback;
