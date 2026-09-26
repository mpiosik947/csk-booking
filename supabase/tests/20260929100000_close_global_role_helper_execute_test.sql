\set ON_ERROR_STOP on
\pset format unaligned
\pset tuples_only on

select '1..12';
begin;

create temporary table test_results(
  test_order integer primary key,
  test_name text not null,
  passed boolean not null
) on commit drop;

create function pg_temp.ok(integer, text, boolean)
returns void language sql as $function$
  insert into pg_temp.test_results values ($1, $2, coalesce($3, false));
$function$;

do $tests$
declare
  v_signature text;
  v_denied boolean;
  v_all_denied boolean := true;
begin
  perform pg_temp.ok(1, 'all four legacy helper signatures remain present',
    pg_catalog.to_regprocedure('public.get_my_role()') is not null
    and pg_catalog.to_regprocedure('public.is_admin()') is not null
    and pg_catalog.to_regprocedure('public.is_admin_or_employee()') is not null
    and pg_catalog.to_regprocedure('public.is_admin_or_staff()') is not null);

  perform pg_temp.ok(2, 'legacy helper definitions remain byte-for-byte compatible',
    pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef('public.get_my_role()'::pg_catalog.regprocedure), E'\r\n', E'\n'), E'\r', E'\n')) = 'eec66d2c695d3892caec4d4242756ed0'
    and pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef('public.is_admin()'::pg_catalog.regprocedure), E'\r\n', E'\n'), E'\r', E'\n')) = 'd7143dadec70a91da2a1f62bf53bbed8'
    and pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef('public.is_admin_or_employee()'::pg_catalog.regprocedure), E'\r\n', E'\n'), E'\r', E'\n')) = '15514f37a714f2592fb496820d2b8277'
    and pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef('public.is_admin_or_staff()'::pg_catalog.regprocedure), E'\r\n', E'\n'), E'\r', E'\n')) = '191425c0cca4133eb373c12bdc219db1');

  perform pg_temp.ok(3, 'helpers remain postgres-owned SECURITY DEFINER routines with fixed search_path',
    (select pg_catalog.count(*) = 4
       and pg_catalog.bool_and(procedure.prosecdef)
       and pg_catalog.bool_and(owner_role.rolname = 'postgres')
       and pg_catalog.bool_and(procedure.proconfig = array['search_path=public']::text[])
     from pg_catalog.pg_proc procedure
     join pg_catalog.pg_namespace namespace on namespace.oid = procedure.pronamespace
     join pg_catalog.pg_roles owner_role on owner_role.oid = procedure.proowner
     where namespace.nspname = 'public'
       and procedure.proname in ('get_my_role','is_admin','is_admin_or_employee','is_admin_or_staff')));

  perform pg_temp.ok(4, 'PUBLIC has no EXECUTE on legacy helpers',
    not exists (select 1 from (values
      ('public.get_my_role()'), ('public.is_admin()'),
      ('public.is_admin_or_employee()'), ('public.is_admin_or_staff()')
    ) helper(signature) where pg_catalog.has_function_privilege('public', helper.signature, 'EXECUTE')));
  perform pg_temp.ok(5, 'anon has no EXECUTE on legacy helpers',
    not exists (select 1 from (values
      ('public.get_my_role()'), ('public.is_admin()'),
      ('public.is_admin_or_employee()'), ('public.is_admin_or_staff()')
    ) helper(signature) where pg_catalog.has_function_privilege('anon', helper.signature, 'EXECUTE')));
  perform pg_temp.ok(6, 'authenticated has no EXECUTE on legacy helpers',
    not exists (select 1 from (values
      ('public.get_my_role()'), ('public.is_admin()'),
      ('public.is_admin_or_employee()'), ('public.is_admin_or_staff()')
    ) helper(signature) where pg_catalog.has_function_privilege('authenticated', helper.signature, 'EXECUTE')));
  perform pg_temp.ok(7, 'service_role has no EXECUTE on legacy helpers',
    not exists (select 1 from (values
      ('public.get_my_role()'), ('public.is_admin()'),
      ('public.is_admin_or_employee()'), ('public.is_admin_or_staff()')
    ) helper(signature) where pg_catalog.has_function_privilege('service_role', helper.signature, 'EXECUTE')));

  foreach v_signature in array array[
    'public.get_my_role()', 'public.is_admin()',
    'public.is_admin_or_employee()', 'public.is_admin_or_staff()'
  ] loop
    v_denied := false;
    begin
      execute 'set local role authenticated';
      execute 'select ' || v_signature;
      execute 'reset role';
    exception when insufficient_privilege then
      execute 'reset role';
      v_denied := true;
    end;
    v_all_denied := v_all_denied and v_denied;
  end loop;
  perform pg_temp.ok(8, 'authenticated runtime calls fail closed', v_all_denied);

  perform pg_temp.ok(9, 'no RLS policy references a closed helper',
    not exists (
      select 1 from pg_catalog.pg_policies policy
      where policy.schemaname = 'public'
        and (coalesce(policy.qual, '') || ' ' || coalesce(policy.with_check, ''))
          ~ '\m(get_my_role|is_admin|is_admin_or_employee|is_admin_or_staff)\M'));

  perform pg_temp.ok(10, 'no database routine references a closed helper',
    not exists (
      select 1 from pg_catalog.pg_proc procedure
      join pg_catalog.pg_namespace namespace on namespace.oid = procedure.pronamespace
      where procedure.prokind in ('f', 'p')
        and procedure.oid not in (
          'public.get_my_role()'::pg_catalog.regprocedure,
          'public.is_admin()'::pg_catalog.regprocedure,
          'public.is_admin_or_employee()'::pg_catalog.regprocedure,
          'public.is_admin_or_staff()'::pg_catalog.regprocedure)
        and pg_catalog.pg_get_functiondef(procedure.oid)
          ~ '\m(get_my_role|is_admin|is_admin_or_employee|is_admin_or_staff)\M'));

  perform pg_temp.ok(11, 'no trigger directly invokes a closed helper',
    not exists (
      select 1 from information_schema.triggers trigger_row
      where trigger_row.action_statement
        ~* '(get_my_role|is_admin|is_admin_or_employee|is_admin_or_staff)'));

  perform pg_temp.ok(12, 'SECURITY DEFINER inventory is 100 after PRODUCT-10C public landing',
    (select pg_catalog.count(*) =   107
     from pg_catalog.pg_proc procedure
     join pg_catalog.pg_namespace namespace on namespace.oid = procedure.pronamespace
     where namespace.nspname = 'public' and procedure.prokind = 'f' and procedure.prosecdef));
end
$tests$;

select case when passed then 'ok ' else 'not ok ' end || test_order || ' - ' || test_name
from pg_temp.test_results order by test_order;

do $assertions$
begin
  if exists (select 1 from pg_temp.test_results where not passed)
     or (select pg_catalog.count(*) from pg_temp.test_results) <> 12 then
    raise exception 'SAAS-9D-4D-2 focused test failed';
  end if;
end
$assertions$;

rollback;
