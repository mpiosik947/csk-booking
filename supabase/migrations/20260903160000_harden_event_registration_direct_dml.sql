-- SEC-018: application roles manage event registrations only through controlled RPCs.

do $preflight$
declare
  v_table_oid oid := pg_catalog.to_regclass('public.event_registrations');
begin
  if v_table_oid is null then
    raise exception 'SEC-018 preflight failed: public.event_registrations does not exist.';
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_class as relation
    join pg_catalog.pg_roles as owner_role on owner_role.oid = relation.relowner
    where relation.oid = v_table_oid
      and relation.relkind in ('r', 'p')
      and relation.relrowsecurity
      and owner_role.rolname = 'postgres'
  ) then
    raise exception 'SEC-018 preflight failed: table owner or RLS state is unexpected.';
  end if;

  if (
    select pg_catalog.count(*)
    from pg_catalog.pg_policies as policy
    where policy.schemaname = 'public'
      and policy.tablename = 'event_registrations'
  ) <> 5 or not exists (
    select 1 from pg_catalog.pg_policies
    where schemaname='public' and tablename='event_registrations'
      and policyname='Admins and staff can insert event registrations'
      and cmd='INSERT' and roles=array['authenticated']::name[]
      and qual is null and with_check='is_admin_or_employee()'
  ) or not exists (
    select 1 from pg_catalog.pg_policies
    where schemaname='public' and tablename='event_registrations'
      and policyname='Admins and staff can update event registrations'
      and cmd='UPDATE' and roles=array['authenticated']::name[]
      and qual='is_admin_or_employee()' and with_check='is_admin_or_employee()'
  ) or not exists (
    select 1 from pg_catalog.pg_policies
    where schemaname='public' and tablename='event_registrations'
      and policyname='Admins and staff can delete event registrations'
      and cmd='DELETE' and roles=array['authenticated']::name[]
      and qual='is_admin_or_employee()' and with_check is null
  ) then
    raise exception 'SEC-018 preflight failed: mutation policy inventory is unexpected.';
  end if;

  if not exists (
    select 1 from pg_catalog.pg_policies
    where schemaname='public' and tablename='event_registrations'
      and policyname='Admins and staff can view all event registrations'
      and cmd='SELECT' and roles=array['authenticated']::name[]
      and qual='is_admin_or_staff()' and with_check is null
  ) or not exists (
    select 1 from pg_catalog.pg_policies
    where schemaname='public' and tablename='event_registrations'
      and policyname='Users can view own event registrations'
      and cmd='SELECT' and roles=array['authenticated']::name[]
      and qual='(user_id = auth.uid())' and with_check is null
  ) then
    raise exception 'SEC-018 preflight failed: SELECT policies are absent or changed.';
  end if;

  if not pg_catalog.has_table_privilege('authenticated',v_table_oid,'SELECT')
     or not pg_catalog.has_table_privilege('authenticated',v_table_oid,'INSERT')
     or not pg_catalog.has_table_privilege('authenticated',v_table_oid,'DELETE')
     or pg_catalog.has_table_privilege(
       'authenticated',v_table_oid,'UPDATE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN'
     ) then
    raise exception 'SEC-018 preflight failed: authenticated table ACL is unexpected.';
  end if;

  if pg_catalog.has_table_privilege(
    'anon',v_table_oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN'
  ) or exists (
    select 1
    from pg_catalog.pg_class as relation
    cross join lateral pg_catalog.aclexplode(
      coalesce(relation.relacl,pg_catalog.acldefault('r',relation.relowner))
    ) as acl
    where relation.oid=v_table_oid and acl.grantee=0
  ) then
    raise exception 'SEC-018 preflight failed: anon or PUBLIC has unexpected table ACL.';
  end if;

  if pg_catalog.to_regprocedure('public.mark_event_registration_paid(uuid)') is not null then
    raise exception 'SEC-018 preflight failed: payment RPC already exists.';
  end if;
end;
$preflight$;

create function public.mark_event_registration_paid(p_registration_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, public, pg_temp
as $function$
declare
  v_actor_id uuid := auth.uid();
  v_actor_role text;
  v_event_id uuid;
  v_registration public.event_registrations%rowtype;
  v_action_time timestamptz := pg_catalog.transaction_timestamp();
begin
  if v_actor_id is null then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','not_allowed');
  end if;

  select pg_catalog.lower(pg_catalog.btrim(profile.role::text))
  into v_actor_role
  from public.profiles as profile
  where profile.user_id=v_actor_id;

  if not found or coalesce(v_actor_role,'') not in ('admin','pracownik') then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','not_allowed');
  end if;

  if p_registration_id is null then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','registration_not_found');
  end if;

  select registration.event_id
  into v_event_id
  from public.event_registrations as registration
  where registration.id=p_registration_id;

  if not found then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','registration_not_found');
  end if;

  if v_event_id is null then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','event_not_found');
  end if;

  perform event_record.id
  from public.events as event_record
  where event_record.id=v_event_id
  for update;

  if not found then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','event_not_found');
  end if;

  select registration.*
  into v_registration
  from public.event_registrations as registration
  where registration.id=p_registration_id
    and registration.event_id=v_event_id
  for update;

  if not found then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','registration_not_found');
  end if;

  if v_registration.payment_status='paid_on_site' then
    return pg_catalog.jsonb_build_object(
      'ok',true,'changed',false,'code','no_change',
      'registration_id',v_registration.id,'event_id',v_registration.event_id,
      'previous_payment_status',v_registration.payment_status,
      'new_payment_status',v_registration.payment_status
    );
  end if;

  update public.event_registrations as registration
  set payment_status='paid_on_site'
  where registration.id=v_registration.id;

  insert into public.audit_logs(
    actor_user_id,actor_name,actor_role,action,target_type,target_id,target_name,details
  ) values (
    v_actor_id,'Obsługa',v_actor_role,'event_registration_payment_marked_by_staff',
    'event_registration',v_registration.id,'Zapis na szkolenie',
    pg_catalog.jsonb_build_object(
      'registration_id',v_registration.id,
      'event_id',v_registration.event_id,
      'previous_payment_status',v_registration.payment_status,
      'new_payment_status','paid_on_site',
      'operator_role',v_actor_role,
      'changed_at',v_action_time
    )
  );

  return pg_catalog.jsonb_build_object(
    'ok',true,'changed',true,'code','updated',
    'registration_id',v_registration.id,'event_id',v_registration.event_id,
    'previous_payment_status',v_registration.payment_status,
    'new_payment_status','paid_on_site'
  );
end;
$function$;

alter function public.mark_event_registration_paid(uuid) owner to postgres;
revoke all on function public.mark_event_registration_paid(uuid) from public, anon, authenticated, service_role;
grant execute on function public.mark_event_registration_paid(uuid) to authenticated;

drop policy "Admins and staff can insert event registrations" on public.event_registrations;
drop policy "Admins and staff can update event registrations" on public.event_registrations;
drop policy "Admins and staff can delete event registrations" on public.event_registrations;

revoke all privileges on table public.event_registrations from public, anon, authenticated;
grant select on table public.event_registrations to authenticated;

do $postflight$
declare
  v_function_oid oid := pg_catalog.to_regprocedure('public.mark_event_registration_paid(uuid)');
begin
  if v_function_oid is null then
    raise exception 'SEC-018 postflight failed: payment RPC is absent.';
  end if;

  if not exists (
    select 1 from pg_catalog.pg_proc as procedure
    join pg_catalog.pg_roles as owner_role on owner_role.oid=procedure.proowner
    where procedure.oid=v_function_oid and procedure.prosecdef
      and procedure.provolatile='v' and procedure.prorettype='jsonb'::regtype
      and procedure.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[]
      and owner_role.rolname='postgres'
  ) then
    raise exception 'SEC-018 postflight failed: payment RPC properties are unexpected.';
  end if;

  if not pg_catalog.has_function_privilege('authenticated',v_function_oid,'EXECUTE')
     or pg_catalog.has_function_privilege('anon',v_function_oid,'EXECUTE')
     or pg_catalog.has_function_privilege('service_role',v_function_oid,'EXECUTE')
     or exists (
       select 1 from pg_catalog.pg_proc as procedure
       cross join lateral pg_catalog.aclexplode(
         coalesce(procedure.proacl,pg_catalog.acldefault('f',procedure.proowner))
       ) as acl
       where procedure.oid=v_function_oid and acl.grantee=0 and acl.privilege_type='EXECUTE'
     ) then
    raise exception 'SEC-018 postflight failed: payment RPC ACL is unexpected.';
  end if;

  if not pg_catalog.has_table_privilege('authenticated','public.event_registrations','SELECT')
     or pg_catalog.has_table_privilege(
       'authenticated','public.event_registrations',
       'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN'
     ) then
    raise exception 'SEC-018 postflight failed: authenticated table ACL is not SELECT-only.';
  end if;

  if exists (
    select 1 from pg_catalog.pg_policies
    where schemaname='public' and tablename='event_registrations'
      and cmd in ('INSERT','UPDATE','DELETE','ALL')
  ) or (
    select pg_catalog.count(*) from pg_catalog.pg_policies
    where schemaname='public' and tablename='event_registrations' and cmd='SELECT'
  ) <> 2 then
    raise exception 'SEC-018 postflight failed: event registration policies are unexpected.';
  end if;
end;
$postflight$;
