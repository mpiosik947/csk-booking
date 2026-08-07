do $preflight$
declare
  v_events_oid oid;
  v_admin_create_event_oid oid;
  v_admin_update_event_oid oid;
  v_admin_set_event_active_oid oid;
begin
  if pg_catalog.to_regclass('public.events') is null then
    raise exception 'Brak wymaganej tabeli public.events.' using errcode = '42P01';
  end if;

  v_events_oid := 'public.events'::pg_catalog.regclass;
  v_admin_create_event_oid := pg_catalog.to_regprocedure(
    'public.admin_create_event(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'
  );
  v_admin_update_event_oid := pg_catalog.to_regprocedure(
    'public.admin_update_event(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'
  );
  v_admin_set_event_active_oid := pg_catalog.to_regprocedure(
    'public.admin_set_event_active(uuid,boolean)'
  );

  if not exists (
    select 1
    from pg_catalog.pg_class as class_record
    join pg_catalog.pg_roles as owner_role
      on owner_role.oid = class_record.relowner
    where class_record.oid = v_events_oid
      and owner_role.rolname = 'postgres'
      and class_record.relrowsecurity
      and not class_record.relforcerowsecurity
  ) then
    raise exception 'Nieoczekiwany owner lub stan RLS public.events.' using errcode = '55000';
  end if;

  if not (
    pg_catalog.has_table_privilege('authenticated', v_events_oid, 'SELECT')
    and pg_catalog.has_table_privilege('authenticated', v_events_oid, 'INSERT')
    and pg_catalog.has_table_privilege('authenticated', v_events_oid, 'UPDATE')
    and pg_catalog.has_table_privilege('authenticated', v_events_oid, 'DELETE')
    and pg_catalog.has_table_privilege('authenticated', v_events_oid, 'TRUNCATE')
    and pg_catalog.has_table_privilege('authenticated', v_events_oid, 'REFERENCES')
    and pg_catalog.has_table_privilege('authenticated', v_events_oid, 'TRIGGER')
    and pg_catalog.has_table_privilege('anon', v_events_oid, 'SELECT')
    and pg_catalog.has_table_privilege('anon', v_events_oid, 'INSERT')
    and pg_catalog.has_table_privilege('anon', v_events_oid, 'UPDATE')
    and pg_catalog.has_table_privilege('anon', v_events_oid, 'DELETE')
    and pg_catalog.has_table_privilege('anon', v_events_oid, 'TRUNCATE')
    and pg_catalog.has_table_privilege('anon', v_events_oid, 'REFERENCES')
    and pg_catalog.has_table_privilege('anon', v_events_oid, 'TRIGGER')
    and pg_catalog.has_table_privilege('service_role', v_events_oid, 'SELECT')
    and pg_catalog.has_table_privilege('service_role', v_events_oid, 'INSERT')
    and pg_catalog.has_table_privilege('service_role', v_events_oid, 'UPDATE')
    and pg_catalog.has_table_privilege('service_role', v_events_oid, 'DELETE')
    and pg_catalog.has_table_privilege('service_role', v_events_oid, 'TRUNCATE')
    and pg_catalog.has_table_privilege('service_role', v_events_oid, 'REFERENCES')
    and pg_catalog.has_table_privilege('service_role', v_events_oid, 'TRIGGER')
  ) then
    raise exception 'Nieoczekiwane ACL public.events przed migracją.' using errcode = '55000';
  end if;

  if exists (
    select 1
    from pg_catalog.pg_class as class_record
    cross join lateral pg_catalog.aclexplode(
      coalesce(class_record.relacl, pg_catalog.acldefault('r', class_record.relowner))
    ) as acl
    where class_record.oid = v_events_oid
      and acl.grantee = 0
  ) then
    raise exception 'PUBLIC posiada nieoczekiwane ACL public.events.' using errcode = '55000';
  end if;

  if (select count(*) from pg_catalog.pg_policy where polrelid = v_events_oid) <> 6
     or not exists (select 1 from pg_catalog.pg_policy where polrelid = v_events_oid and polname = 'Admins and staff can delete events' and polcmd = 'd')
     or not exists (select 1 from pg_catalog.pg_policy where polrelid = v_events_oid and polname = 'Admins and staff can insert events' and polcmd = 'a')
     or not exists (select 1 from pg_catalog.pg_policy where polrelid = v_events_oid and polname = 'Admins and staff can update events' and polcmd = 'w')
     or not exists (select 1 from pg_catalog.pg_policy where polrelid = v_events_oid and polname = 'Admins and staff can view all events' and polcmd = 'r')
     or not exists (select 1 from pg_catalog.pg_policy where polrelid = v_events_oid and polname = 'Public can view active events' and polcmd = 'r')
     or not exists (select 1 from pg_catalog.pg_policy where polrelid = v_events_oid and polname = 'Users can view active events' and polcmd = 'r') then
    raise exception 'Nieoczekiwany zestaw polityk public.events przed migracją.' using errcode = '55000';
  end if;

  if exists (
    select 1
    from pg_catalog.pg_policies as policy_record
    where policy_record.schemaname = 'public'
      and policy_record.tablename = 'events'
      and (
        (policy_record.policyname = 'Admins and staff can delete events'
          and (policy_record.roles <> array['authenticated']::name[]
            or policy_record.cmd <> 'DELETE'
            or policy_record.qual is distinct from 'is_admin_or_staff()'
            or policy_record.with_check is not null))
        or (policy_record.policyname = 'Admins and staff can insert events'
          and (policy_record.roles <> array['authenticated']::name[]
            or policy_record.cmd <> 'INSERT'
            or policy_record.qual is not null
            or policy_record.with_check is distinct from 'is_admin_or_staff()'))
        or (policy_record.policyname = 'Admins and staff can update events'
          and (policy_record.roles <> array['authenticated']::name[]
            or policy_record.cmd <> 'UPDATE'
            or policy_record.qual is distinct from 'is_admin_or_staff()'
            or policy_record.with_check is distinct from 'is_admin_or_staff()'))
        or (policy_record.policyname = 'Admins and staff can view all events'
          and (policy_record.roles <> array['authenticated']::name[]
            or policy_record.cmd <> 'SELECT'
            or policy_record.qual is distinct from 'is_admin_or_staff()'
            or policy_record.with_check is not null))
        or (policy_record.policyname = 'Public can view active events'
          and (policy_record.roles <> array['anon']::name[]
            or policy_record.cmd <> 'SELECT'
            or policy_record.qual is distinct from '(is_active = true)'
            or policy_record.with_check is not null))
        or (policy_record.policyname = 'Users can view active events'
          and (policy_record.roles <> array['authenticated']::name[]
            or policy_record.cmd <> 'SELECT'
            or policy_record.qual is distinct from '(is_active = true)'
            or policy_record.with_check is not null))
      )
  ) then
    raise exception 'Nieoczekiwana definicja polityki public.events przed migracją.' using errcode = '55000';
  end if;

  if v_admin_create_event_oid is null
     or v_admin_update_event_oid is null
     or v_admin_set_event_active_oid is null
     or (select count(*) from pg_catalog.pg_proc as procedure_record join pg_catalog.pg_namespace as namespace_record on namespace_record.oid = procedure_record.pronamespace where namespace_record.nspname = 'public' and procedure_record.proname = 'admin_create_event') <> 1
     or (select count(*) from pg_catalog.pg_proc as procedure_record join pg_catalog.pg_namespace as namespace_record on namespace_record.oid = procedure_record.pronamespace where namespace_record.nspname = 'public' and procedure_record.proname = 'admin_update_event') <> 1
     or (select count(*) from pg_catalog.pg_proc as procedure_record join pg_catalog.pg_namespace as namespace_record on namespace_record.oid = procedure_record.pronamespace where namespace_record.nspname = 'public' and procedure_record.proname = 'admin_set_event_active') <> 1
     or exists (
       select 1
       from pg_catalog.pg_proc as procedure_record
       join pg_catalog.pg_namespace as namespace_record
         on namespace_record.oid = procedure_record.pronamespace
       join pg_catalog.pg_roles as owner_role
         on owner_role.oid = procedure_record.proowner
       where procedure_record.oid in (
         v_admin_create_event_oid,
         v_admin_update_event_oid,
         v_admin_set_event_active_oid
       )
         and (
           not procedure_record.prosecdef
           or owner_role.rolname <> 'postgres'
           or procedure_record.proconfig is distinct from array['search_path=public, pg_temp']
           or not pg_catalog.has_function_privilege('authenticated', procedure_record.oid, 'EXECUTE')
           or not pg_catalog.has_function_privilege('service_role', procedure_record.oid, 'EXECUTE')
           or pg_catalog.has_function_privilege('anon', procedure_record.oid, 'EXECUTE')
           or exists (
             select 1
             from pg_catalog.aclexplode(
               coalesce(procedure_record.proacl, pg_catalog.acldefault('f', procedure_record.proowner))
             ) as acl
             where acl.grantee = 0
               and acl.privilege_type = 'EXECUTE'
           )
         )
     ) then
    raise exception 'Nieoczekiwany kontrakt SECURITY DEFINER RPC eventów.' using errcode = '55000';
  end if;
end;
$preflight$;

revoke all on table public.events from public;
revoke insert, update, delete, truncate, references, trigger on table public.events from anon;
revoke insert, update, delete, truncate, references, trigger on table public.events from authenticated;

grant select on table public.events to anon;
grant select on table public.events to authenticated;

drop policy if exists "Admins and staff can insert events" on public.events;
drop policy if exists "Admins and staff can update events" on public.events;
drop policy if exists "Admins and staff can delete events" on public.events;
