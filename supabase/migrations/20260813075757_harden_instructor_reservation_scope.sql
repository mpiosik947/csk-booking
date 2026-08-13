-- Fail closed until a real instructor-to-reservation assignment model exists.
do $preflight$
declare
  v_attendance_definition text;
  v_helper_definition text;
  v_expected_old_authorization constant text := $old$
  if v_action in ('start', 'reset') then
    if coalesce(v_actor_role, '') not in ('admin', 'pracownik') then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'not_allowed'
      );
    end if;
  elsif coalesce(v_actor_role, '') not in ('admin', 'pracownik', 'instruktor') then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'not_allowed'
    );
  end if;
$old$;
begin
  if pg_catalog.to_regclass('public.reservations') is null
     or pg_catalog.to_regclass('public.profiles') is null then
    raise exception 'P0-B preflight failed: reservations or profiles table is missing.';
  end if;

  if (
    select pg_catalog.count(*)
    from pg_catalog.pg_class as relation
    where relation.oid in (
      'public.reservations'::pg_catalog.regclass,
      'public.profiles'::pg_catalog.regclass
    )
      and relation.relrowsecurity
  ) <> 2 then
    raise exception 'P0-B preflight failed: RLS is not enabled on both protected tables.';
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_policy as policy
    where policy.polrelid = 'public.reservations'::pg_catalog.regclass
      and policy.polname = 'Admins and staff can view all reservations'
      and policy.polcmd = 'r'
      and policy.polroles = array['authenticated'::pg_catalog.regrole::oid]
      and pg_catalog.pg_get_expr(policy.polqual, policy.polrelid) = 'is_admin_or_staff()'
      and policy.polwithcheck is null
  ) then
    raise exception 'P0-B preflight failed: legacy reservations staff SELECT policy differs.';
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_policy as policy
    where policy.polrelid = 'public.profiles'::pg_catalog.regclass
      and policy.polname = 'Admins and staff can view all profiles'
      and policy.polcmd = 'r'
      and policy.polroles = array['authenticated'::pg_catalog.regrole::oid]
      and pg_catalog.pg_get_expr(policy.polqual, policy.polrelid) = 'is_admin_or_staff()'
      and policy.polwithcheck is null
  ) then
    raise exception 'P0-B preflight failed: legacy profiles staff SELECT policy differs.';
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_policy as policy
    where policy.polrelid = 'public.reservations'::pg_catalog.regclass
      and policy.polname = 'Users can view own reservations'
      and policy.polcmd = 'r'
      and policy.polroles = array['authenticated'::pg_catalog.regrole::oid]
      and pg_catalog.pg_get_expr(policy.polqual, policy.polrelid) = '(user_id = auth.uid())'
      and policy.polwithcheck is null
  ) or not exists (
    select 1
    from pg_catalog.pg_policy as policy
    where policy.polrelid = 'public.profiles'::pg_catalog.regclass
      and policy.polname = 'Users can view own profile'
      and policy.polcmd = 'r'
      and policy.polroles = array['authenticated'::pg_catalog.regrole::oid]
      and pg_catalog.pg_get_expr(policy.polqual, policy.polrelid) = '(user_id = auth.uid())'
      and policy.polwithcheck is null
  ) then
    raise exception 'P0-B preflight failed: required ownership SELECT policies differ.';
  end if;

  if pg_catalog.to_regprocedure('public.is_admin_or_employee()') is null
     or (
       select pg_catalog.count(*)
       from pg_catalog.pg_proc as procedure
       join pg_catalog.pg_namespace as namespace
         on namespace.oid = procedure.pronamespace
       where namespace.nspname = 'public'
         and procedure.proname = 'is_admin_or_employee'
     ) <> 1 then
    raise exception 'P0-B preflight failed: is_admin_or_employee() signature differs.';
  end if;

  select pg_catalog.pg_get_functiondef(
    'public.is_admin_or_employee()'::pg_catalog.regprocedure
  ) into v_helper_definition;

  if v_helper_definition !~* $$lower\(btrim\(role::text\)\)\s+in\s+\('admin'\s*,\s*'pracownik'\)$$
     or v_helper_definition ~* 'instruktor' then
    raise exception 'P0-B preflight failed: is_admin_or_employee() is not exactly admin + pracownik.';
  end if;

  if pg_catalog.to_regprocedure(
       'public.update_reservation_attendance(uuid,text)'
     ) is null
     or (
       select pg_catalog.count(*)
       from pg_catalog.pg_proc as procedure
       join pg_catalog.pg_namespace as namespace
         on namespace.oid = procedure.pronamespace
       where namespace.nspname = 'public'
         and procedure.proname = 'update_reservation_attendance'
     ) <> 1 then
    raise exception 'P0-B preflight failed: attendance RPC signature differs.';
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_proc as procedure
    join pg_catalog.pg_roles as owner_role on owner_role.oid = procedure.proowner
    join pg_catalog.pg_language as language on language.oid = procedure.prolang
    where procedure.oid = 'public.update_reservation_attendance(uuid,text)'::pg_catalog.regprocedure
      and procedure.prosecdef
      and procedure.provolatile = 'v'
      and procedure.proconfig = array['search_path=pg_catalog, public, pg_temp']::text[]
      and owner_role.rolname = 'postgres'
      and language.lanname = 'plpgsql'
      and pg_catalog.pg_get_function_result(procedure.oid) = 'jsonb'
  ) then
    raise exception 'P0-B preflight failed: attendance RPC security properties differ.';
  end if;

  if not pg_catalog.has_function_privilege(
       'authenticated',
       'public.update_reservation_attendance(uuid,text)',
       'EXECUTE'
     )
     or not pg_catalog.has_function_privilege(
       'service_role',
       'public.update_reservation_attendance(uuid,text)',
       'EXECUTE'
     )
     or pg_catalog.has_function_privilege(
       'anon',
       'public.update_reservation_attendance(uuid,text)',
       'EXECUTE'
     )
     or exists (
       select 1
       from pg_catalog.pg_proc as procedure
       cross join lateral pg_catalog.aclexplode(
         coalesce(
           procedure.proacl,
           pg_catalog.acldefault('f', procedure.proowner)
         )
       ) as acl
       where procedure.oid =
         'public.update_reservation_attendance(uuid,text)'::pg_catalog.regprocedure
         and acl.grantee = 0
         and acl.privilege_type = 'EXECUTE'
     ) then
    raise exception 'P0-B preflight failed: attendance RPC ACL differs.';
  end if;

  select pg_catalog.pg_get_functiondef(
    'public.update_reservation_attendance(uuid,text)'::pg_catalog.regprocedure
  ) into v_attendance_definition;

  if pg_catalog.strpos(v_attendance_definition, v_expected_old_authorization) = 0
     or pg_catalog.strpos(
       pg_catalog.substr(
         v_attendance_definition,
         pg_catalog.strpos(v_attendance_definition, v_expected_old_authorization)
           + pg_catalog.char_length(v_expected_old_authorization)
       ),
       v_expected_old_authorization
     ) > 0 then
    raise exception 'P0-B preflight failed: attendance authorization block differs or is duplicated.';
  end if;
end;
$preflight$;

drop policy "Admins and staff can view all reservations"
on public.reservations;

create policy "Admins and staff can view all reservations"
on public.reservations
for select
to authenticated
using (public.is_admin_or_employee());

drop policy "Admins and staff can view all profiles"
on public.profiles;

create policy "Admins and staff can view all profiles"
on public.profiles
for select
to authenticated
using (public.is_admin_or_employee());

do $replace_attendance_authorization$
declare
  v_definition text;
  v_old constant text := $old$
  if v_action in ('start', 'reset') then
    if coalesce(v_actor_role, '') not in ('admin', 'pracownik') then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'not_allowed'
      );
    end if;
  elsif coalesce(v_actor_role, '') not in ('admin', 'pracownik', 'instruktor') then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'not_allowed'
    );
  end if;
$old$;
  v_new constant text := $new$
  if coalesce(v_actor_role, '') not in ('admin', 'pracownik') then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'not_allowed'
    );
  end if;
$new$;
begin
  select pg_catalog.pg_get_functiondef(
    'public.update_reservation_attendance(uuid,text)'::pg_catalog.regprocedure
  ) into v_definition;

  execute pg_catalog.replace(v_definition, v_old, v_new);
end;
$replace_attendance_authorization$;

do $postflight$
declare
  v_definition text;
  v_expected_authorization constant text := $new$
  if coalesce(v_actor_role, '') not in ('admin', 'pracownik') then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'not_allowed'
    );
  end if;
$new$;
begin
  if not exists (
    select 1
    from pg_catalog.pg_policy as policy
    where policy.polrelid = 'public.reservations'::pg_catalog.regclass
      and policy.polname = 'Admins and staff can view all reservations'
      and policy.polcmd = 'r'
      and policy.polroles = array['authenticated'::pg_catalog.regrole::oid]
      and pg_catalog.pg_get_expr(policy.polqual, policy.polrelid) = 'is_admin_or_employee()'
      and policy.polwithcheck is null
  ) or not exists (
    select 1
    from pg_catalog.pg_policy as policy
    where policy.polrelid = 'public.profiles'::pg_catalog.regclass
      and policy.polname = 'Admins and staff can view all profiles'
      and policy.polcmd = 'r'
      and policy.polroles = array['authenticated'::pg_catalog.regrole::oid]
      and pg_catalog.pg_get_expr(policy.polqual, policy.polrelid) = 'is_admin_or_employee()'
      and policy.polwithcheck is null
  ) then
    raise exception 'P0-B postflight failed: narrowed SELECT policies differ.';
  end if;

  select pg_catalog.pg_get_functiondef(
    'public.update_reservation_attendance(uuid,text)'::pg_catalog.regprocedure
  ) into v_definition;

  if pg_catalog.strpos(v_definition, v_expected_authorization) = 0
     or v_definition ~ $$elsif coalesce\(v_actor_role$$
     or v_definition ~ $$'instruktor'$$ then
    raise exception 'P0-B postflight failed: attendance authorization was not narrowed.';
  end if;

  if not pg_catalog.has_function_privilege(
       'authenticated',
       'public.update_reservation_attendance(uuid,text)',
       'EXECUTE'
     )
     or not pg_catalog.has_function_privilege(
       'service_role',
       'public.update_reservation_attendance(uuid,text)',
       'EXECUTE'
     )
     or pg_catalog.has_function_privilege(
       'anon',
       'public.update_reservation_attendance(uuid,text)',
       'EXECUTE'
     ) then
    raise exception 'P0-B postflight failed: attendance RPC ACL changed.';
  end if;
end;
$postflight$;
