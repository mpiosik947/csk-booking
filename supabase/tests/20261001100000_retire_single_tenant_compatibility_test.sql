\set ON_ERROR_STOP on
\pset format unaligned

select '1..21';
begin;
create temporary table saas9d5_results(n integer primary key,label text,passed boolean) on commit drop;
create function pg_temp.ok(p_n integer,p_label text,p_passed boolean)
returns void language sql as $$insert into pg_temp.saas9d5_results values(p_n,p_label,coalesce(p_passed,false))$$;

select pg_temp.ok(1,'exact-single-active bridge definitions are fully retired',(
  select count(*)=0
   from pg_catalog.pg_proc procedure
   join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace
   where namespace.nspname='public'
     and procedure.prokind='f'
     and (procedure.proname='active_single_tenant_id_v1'
       or pg_catalog.pg_get_functiondef(procedure.oid) ilike '%active_single_tenant_id_v1%')));

select pg_temp.ok(2,'all seven CSK compatibility defaults are removed',(
  select count(*)=0 from information_schema.columns
   where table_schema='public' and column_name='tenant_id'
     and table_name in ('shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','email_deliveries')
     and column_default is not null));

select pg_temp.ok(3,'all seven tenant ownership columns remain NOT NULL',(
  select count(*)=7 from information_schema.columns
   where table_schema='public' and column_name='tenant_id'
     and table_name in ('shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','email_deliveries')
     and is_nullable='NO'));

select pg_temp.ok(4,'SECURITY DEFINER inventory reaches the reviewed 9F target',(
  select count(*)=  97 from pg_catalog.pg_proc procedure
   join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace
   where namespace.nspname='public' and procedure.prosecdef));

select pg_temp.ok(5,'three closed legacy event writers are removed',(
  select count(*)=0 from (values
    ('public.admin_create_event(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'),
    ('public.admin_update_event(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'),
    ('public.admin_set_event_active(uuid,boolean)')
  ) legacy(signature) where pg_catalog.to_regprocedure(legacy.signature) is not null));

select pg_temp.ok(6,'tenant-scoped event create replacement remains',pg_catalog.to_regprocedure('public.admin_create_event_v3(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])') is not null);
select pg_temp.ok(7,'tenant-scoped event update replacement remains',pg_catalog.to_regprocedure('public.admin_update_event_v3(uuid,uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])') is not null);
select pg_temp.ok(8,'tenant-scoped event activation replacement remains',pg_catalog.to_regprocedure('public.admin_set_event_active_v3(uuid,uuid,boolean)') is not null);
select pg_temp.ok(9,'tenant-scoped lane-family create replacement remains',pg_catalog.to_regprocedure('public.admin_create_lane_booking_family_v2(uuid,jsonb)') is not null);
select pg_temp.ok(10,'tenant-scoped lane configuration reader remains',pg_catalog.to_regprocedure('public.admin_get_lane_booking_configuration_v3(uuid)') is not null);
select pg_temp.ok(11,'tenant-scoped report replacement remains',pg_catalog.to_regprocedure('public.admin_get_reservation_report_v3(uuid,date,date,uuid,text,text,text,integer,integer)') is not null);
select pg_temp.ok(12,'tenant-scoped report export replacement remains',pg_catalog.to_regprocedure('public.admin_get_reservation_report_export_v2(uuid,date,date,uuid,text,text,text)') is not null);
select pg_temp.ok(13,'tenant-scoped user list remains',pg_catalog.to_regprocedure('public.admin_list_users_v2(uuid,integer,integer,text,text,text,text)') is not null);
select pg_temp.ok(14,'tenant-scoped note writer remains',pg_catalog.to_regprocedure('public.admin_set_user_note_v2(uuid,uuid,text)') is not null);
select pg_temp.ok(15,'tenant-scoped role writer remains',pg_catalog.to_regprocedure('public.admin_set_user_role_v2(uuid,uuid,text)') is not null);
select pg_temp.ok(16,'tenant-scoped owner verification reader remains',pg_catalog.to_regprocedure('public.get_my_tenant_verification_v2(uuid)') is not null);
select pg_temp.ok(17,'tenant-scoped public booking reader remains',pg_catalog.to_regprocedure('public.get_public_booking_configuration_v2(uuid)') is not null);
select pg_temp.ok(18,'tenant-scoped public event reader remains',pg_catalog.to_regprocedure('public.get_public_event_list_v3(uuid,text,text,integer,integer)') is not null);
select pg_temp.ok(19,'account-wide profile writer replacement remains',pg_catalog.to_regprocedure('public.update_my_profile_v2(text,text,text,text,text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean)') is not null);
select pg_temp.ok(20,'single active production guard state is unchanged',(select count(*)=1 from public.tenants where status='active'));
select pg_temp.ok(21,'membership tenant integrity remains valid',(select count(*)=0 from public.tenant_memberships membership left join public.tenants tenant on tenant.id=membership.tenant_id where tenant.id is null));

do $$begin if exists(select 1 from pg_temp.saas9d5_results where not passed) then raise exception 'SAAS-9D-5 focused test failed'; end if; end$$;
select case when passed then 'ok ' else 'not ok ' end||n||' - '||label from pg_temp.saas9d5_results order by n;
rollback;
