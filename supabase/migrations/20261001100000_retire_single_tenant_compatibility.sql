-- SAAS-9D-5: retire the obsolete exact-single-tenant compatibility layer.
-- This migration is intentionally fail-closed and forward-only.

create temporary table saas9d5_expected_functions (
  signature text primary key,
  fingerprint text not null
) on commit drop;

insert into saas9d5_expected_functions(signature,fingerprint) values
('public._backfill_csk_tenant_user_verifications_v1()','fef26086d52782d583226d8b47abede8'),
('public.active_single_tenant_id_v1()','6017112df961a334320d98dd0645e570'),
('public.admin_create_event(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])','26f51acb0a0f56677a86dbddec9974b2'),
('public.admin_create_event_v2(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])','44c5a76fb1eecab62462ad0efc014f54'),
('public.admin_create_event_v2__saas9d2b1_core(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])','7e47e4f37f2d4daf872348743f4d4adb'),
('public.admin_create_lane_booking_family_v1(jsonb)','1fd4b47a640b52564568670d079e7659'),
('public.admin_get_lane_booking_configuration_v1()','9c6b9b10c6de8359aca5d88981b52523'),
('public.admin_get_lane_booking_configuration_v2()','ff748a9030e88f8e395805d30b33ac93'),
('public.admin_get_reservation_report_export_v1(date,date,uuid,text,text,text)','5a8fd638e4c7a867477781876358dcf1'),
('public.admin_get_reservation_report_v2(date,date,uuid,text,text,text,integer,integer)','ded8346e37b87bbf278d3b7b4673ae18'),
('public.admin_list_events_v1(text,text,text,integer,integer)','e9fbe38591aa39b760d3c5e6e9a0be52'),
('public.admin_list_events_v1__saas9d2b1_core(text,text,text,integer,integer)','487d9f6b036494428269724d60c7ac89'),
('public.admin_list_users_v1(integer,integer,text,text,text,text)','bf37ec48de512ea45f5d4592df5f4eac'),
('public.admin_set_event_active(uuid,boolean)','b547b0c8d2b056273b10fe57f78f89c0'),
('public.admin_set_user_note_v1(uuid,text)','e8245e2156b20e6d1dfd48b4adfb747b'),
('public.admin_set_user_role_v1(uuid,text)','9732b7d53eaa080ebc6348cd1dd68ca2'),
('public.admin_update_event(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])','60301f5e0b290117105bc9637f10d3ce'),
('public.get_my_active_tenant_verification_v1()','951c8262bc118089d8398282e1a95ce8'),
('public.get_public_booking_configuration_v1()','0134f91776a7e967c06a016714f732ca'),
('public.get_public_event_availability_v1()','665b9ac71f99b3de3421d1534b24f088'),
('public.get_public_event_list_v2(text,text,integer,integer)','642b84c0d78066e2071a0f0df1ce97ff'),
('public.update_my_profile_v1(text,text,text,text,text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean)','eed0787e7c5a67e537b5703289abf536'),
('public.update_profile_contact_details(uuid,text,text,text,text,text,text)','722d407b37890d3f7a9886cd2e7cc249'),
('public.update_profile_identity(uuid,text,text)','7e0643ba2c6a6a6a9388339b46dbd729'),
('public.update_profile_verification(uuid,text,text)','022baa5652409d2246cd5e66642e884e');

do $preflight$
declare
  v_bad integer;
  v_default_count integer;
  v_null_count bigint;
  v_table text;
begin
  select count(*) into v_bad
  from saas9d5_expected_functions expected
  left join pg_catalog.pg_proc procedure
    on procedure.oid=pg_catalog.to_regprocedure(expected.signature)
  where procedure.oid is null
     or pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(
          pg_catalog.pg_get_functiondef(procedure.oid),chr(13)||chr(10),chr(10)),chr(13),chr(10)))<>expected.fingerprint;
  if v_bad<>0 then
    raise exception 'SAAS-9D-5 preflight failed: % target function fingerprints are missing or changed',v_bad;
  end if;

  if (select count(*) from saas9d5_expected_functions)<>25 then
    raise exception 'SAAS-9D-5 preflight failed: expected function inventory is not 25';
  end if;

  if exists (
    select 1
    from pg_catalog.pg_trigger trigger_row
    join saas9d5_expected_functions expected
      on trigger_row.tgfoid=pg_catalog.to_regprocedure(expected.signature)
    where not trigger_row.tgisinternal
  ) then
    raise exception 'SAAS-9D-5 preflight failed: a target function still owns a trigger';
  end if;

  if exists (
    select 1
    from pg_catalog.pg_policies policy
    join saas9d5_expected_functions expected
      on (coalesce(policy.qual,'')||' '||coalesce(policy.with_check,'')) ilike
         '%'||split_part(substr(expected.signature,8),'(',1)||'%'
  ) then
    raise exception 'SAAS-9D-5 preflight failed: a policy still references a target function';
  end if;

  select count(*) into v_default_count
  from information_schema.columns
  where table_schema='public'
    and column_name='tenant_id'
    and table_name in ('shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','email_deliveries')
    and column_default='''c5c00000-0000-4000-8000-000000000001''::uuid'
    and is_nullable='NO';
  if v_default_count<>7 then
    raise exception 'SAAS-9D-5 preflight failed: expected 7 compatibility defaults, found %',v_default_count;
  end if;

  foreach v_table in array array['shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','email_deliveries'] loop
    execute format('select count(*) from public.%I where tenant_id is null',v_table) into v_null_count;
    if v_null_count<>0 then
      raise exception 'SAAS-9D-5 preflight failed: public.% has % null tenant rows',v_table,v_null_count;
    end if;
  end loop;

  if (select count(*) from pg_catalog.pg_proc procedure join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace where namespace.nspname='public' and procedure.prosecdef)<>95 then
    raise exception 'SAAS-9D-5 preflight failed: SECURITY DEFINER baseline is not 95';
  end if;
end
$preflight$;

-- Drop public wrappers before their closed internal cores and finally the resolver.
drop function public.admin_create_event_v2(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[]);
drop function public.admin_list_events_v1(text,text,text,integer,integer);
drop function public.admin_get_lane_booking_configuration_v2();

drop function public.admin_create_event_v2__saas9d2b1_core(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[]);
drop function public.admin_list_events_v1__saas9d2b1_core(text,text,text,integer,integer);
drop function public.admin_get_lane_booking_configuration_v1();

drop function public._backfill_csk_tenant_user_verifications_v1();
drop function public.admin_create_lane_booking_family_v1(jsonb);
drop function public.admin_get_reservation_report_export_v1(date,date,uuid,text,text,text);
drop function public.admin_get_reservation_report_v2(date,date,uuid,text,text,text,integer,integer);
drop function public.admin_list_users_v1(integer,integer,text,text,text,text);
drop function public.admin_set_user_note_v1(uuid,text);
drop function public.admin_set_user_role_v1(uuid,text);
drop function public.get_my_active_tenant_verification_v1();
drop function public.get_public_booking_configuration_v1();
drop function public.get_public_event_availability_v1();
drop function public.get_public_event_list_v2(text,text,integer,integer);
drop function public.update_my_profile_v1(text,text,text,text,text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean);
drop function public.update_profile_contact_details(uuid,text,text,text,text,text,text);
drop function public.update_profile_identity(uuid,text,text);
drop function public.update_profile_verification(uuid,text,text);
drop function public.active_single_tenant_id_v1();

-- These three owner-only legacy event writers have no active caller or DB dependency.
drop function public.admin_create_event(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[]);
drop function public.admin_update_event(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[]);
drop function public.admin_set_event_active(uuid,boolean);

alter table public.shooting_lanes alter column tenant_id drop default;
alter table public.reservations alter column tenant_id drop default;
alter table public.lane_blocks alter column tenant_id drop default;
alter table public.events alter column tenant_id drop default;
alter table public.event_lanes alter column tenant_id drop default;
alter table public.event_registrations alter column tenant_id drop default;
alter table public.email_deliveries alter column tenant_id drop default;

do $postflight$
declare
  v_bridge_count integer;
begin
  select count(*) into v_bridge_count
  from pg_catalog.pg_proc procedure
  join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace
  where namespace.nspname='public'
    and procedure.prokind='f'
    and (
      procedure.proname='active_single_tenant_id_v1'
      or pg_catalog.pg_get_functiondef(procedure.oid) ilike '%active_single_tenant_id_v1%'
    );
  if v_bridge_count<>0 then
    raise exception 'SAAS-9D-5 postflight failed: % bridge definitions remain',v_bridge_count;
  end if;

  if exists (
    select 1 from information_schema.columns
    where table_schema='public'
      and column_name='tenant_id'
      and table_name in ('shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','email_deliveries')
      and column_default is not null
  ) then
    raise exception 'SAAS-9D-5 postflight failed: a tenant compatibility default remains';
  end if;

  if (select count(*) from pg_catalog.pg_proc procedure join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace where namespace.nspname='public' and procedure.prosecdef)<>73 then
    raise exception 'SAAS-9D-5 postflight failed: SECURITY DEFINER target is not 73';
  end if;
end
$postflight$;
