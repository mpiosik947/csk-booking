-- SECURITY-FIX-RCP1: a missing/inactive resource-tenant membership must deny.
-- Preserve the complete reader/DTO, owner, search_path, volatility and EXECUTE ACL.
-- The fingerprint makes an unexpected baseline fail closed before replacement.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '30s';

do $rcp1$
declare
  v_definition text;
  v_old constant text := 'public.get_my_tenant_role_v1(v_tenant) not in(''admin'',''employee'')';
  v_new constant text := 'coalesce(public.get_my_tenant_role_v1(v_tenant),'''') not in(''admin'',''employee'')';
begin
  select pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef(p.oid), E'\r\n', E'\n'), E'\r', E'\n')
    into strict v_definition
    from pg_catalog.pg_proc p
    where p.oid = 'public.get_reservation_customer_profiles_v1(uuid[])'::regprocedure
      and p.prosecdef
      and pg_catalog.pg_get_userbyid(p.proowner) = 'postgres'
      and p.proconfig = array['search_path=pg_catalog, public, pg_temp']
      and p.proacl::text = '{postgres=X/postgres,authenticated=X/postgres}';

  if pg_catalog.md5(v_definition) <> '3f9ff02e63286a2784891ce4bb75c613'
     or pg_catalog.strpos(v_definition, v_old) = 0 then
    raise exception 'SECURITY-FIX-RCP1 unexpected reader baseline';
  end if;

  execute pg_catalog.replace(v_definition, v_old, v_new);
end;
$rcp1$;

commit;
