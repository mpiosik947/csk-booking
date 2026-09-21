-- SAAS-9D-4D-2: close the final client EXECUTE path to legacy global-role helpers.
-- Bodies are deliberately retained unchanged for the separate 9D-5 retirement gate.

do $preflight$
declare
  v_signature text;
  v_expected text;
  v_actual text;
begin
  for v_signature, v_expected in
    select * from (values
      ('public.get_my_role()', 'eec66d2c695d3892caec4d4242756ed0'),
      ('public.is_admin()', 'd7143dadec70a91da2a1f62bf53bbed8'),
      ('public.is_admin_or_employee()', '15514f37a714f2592fb496820d2b8277'),
      ('public.is_admin_or_staff()', '191425c0cca4133eb373c12bdc219db1')
    ) expected(signature, fingerprint)
  loop
    if pg_catalog.to_regprocedure(v_signature) is null then
      raise exception 'SAAS-9D-4D-2 preflight: missing %', v_signature;
    end if;

    select pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(
      pg_catalog.pg_get_functiondef(v_signature::pg_catalog.regprocedure),
      E'\r\n', E'\n'), E'\r', E'\n'))
      into v_actual;

    if v_actual is distinct from v_expected then
      raise exception 'SAAS-9D-4D-2 preflight: fingerprint drift for %', v_signature;
    end if;

    if not pg_catalog.has_function_privilege('authenticated', v_signature, 'EXECUTE')
       or pg_catalog.has_function_privilege('anon', v_signature, 'EXECUTE')
       or pg_catalog.has_function_privilege('service_role', v_signature, 'EXECUTE')
       or pg_catalog.has_function_privilege('public', v_signature, 'EXECUTE') then
      raise exception 'SAAS-9D-4D-2 preflight: unexpected ACL for %', v_signature;
    end if;
  end loop;

  if exists (
    select 1
    from pg_catalog.pg_policies policy
    where policy.schemaname = 'public'
      and (coalesce(policy.qual, '') || ' ' || coalesce(policy.with_check, ''))
        ~ '\m(get_my_role|is_admin|is_admin_or_employee|is_admin_or_staff)\M'
  ) then
    raise exception 'SAAS-9D-4D-2 preflight: an RLS policy still depends on a legacy helper';
  end if;

  if exists (
    select 1
    from pg_catalog.pg_proc procedure
    join pg_catalog.pg_namespace namespace on namespace.oid = procedure.pronamespace
    where procedure.prokind in ('f', 'p')
      and procedure.oid not in (
        'public.get_my_role()'::pg_catalog.regprocedure,
        'public.is_admin()'::pg_catalog.regprocedure,
        'public.is_admin_or_employee()'::pg_catalog.regprocedure,
        'public.is_admin_or_staff()'::pg_catalog.regprocedure
      )
      and pg_catalog.pg_get_functiondef(procedure.oid)
        ~ '\m(get_my_role|is_admin|is_admin_or_employee|is_admin_or_staff)\M'
  ) then
    raise exception 'SAAS-9D-4D-2 preflight: a database routine still depends on a legacy helper';
  end if;
end
$preflight$;

revoke execute on function
  public.get_my_role(),
  public.is_admin(),
  public.is_admin_or_employee(),
  public.is_admin_or_staff()
from authenticated;

do $verify$
declare
  v_signature text;
begin
  foreach v_signature in array array[
    'public.get_my_role()',
    'public.is_admin()',
    'public.is_admin_or_employee()',
    'public.is_admin_or_staff()'
  ]
  loop
    if pg_catalog.has_function_privilege('public', v_signature, 'EXECUTE')
       or pg_catalog.has_function_privilege('anon', v_signature, 'EXECUTE')
       or pg_catalog.has_function_privilege('authenticated', v_signature, 'EXECUTE')
       or pg_catalog.has_function_privilege('service_role', v_signature, 'EXECUTE') then
      raise exception 'SAAS-9D-4D-2 verification: helper remains client-executable: %', v_signature;
    end if;
  end loop;
end
$verify$;
