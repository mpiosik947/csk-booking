-- A stale settings version is a business conflict, not a retryable serialization failure.
-- Preserve the reviewed function verbatim except for this single SQLSTATE literal.
do $migration$
declare
  v_function regprocedure := 'public.admin_update_tenant_public_settings_v1(text,jsonb,timestamptz)'::regprocedure;
  v_definition text;
  v_old constant text := 'errcode=''40001'',message=''settings_conflict''';
  v_new constant text := 'errcode=''PT409'',message=''settings_conflict''';
begin
  v_definition := pg_catalog.pg_get_functiondef(v_function);
  if pg_catalog.md5(v_definition) <> '5e1a8b0fab9acb1fe8090abf2c32521a'
     or (pg_catalog.length(v_definition) - pg_catalog.length(pg_catalog.replace(v_definition,v_old,''))) <> pg_catalog.length(v_old) then
    raise exception 'ONBOARD-1C-R2 preflight failed: settings writer differs from reviewed baseline';
  end if;
  execute pg_catalog.replace(v_definition,v_old,v_new);
  if pg_catalog.replace(pg_catalog.pg_get_functiondef(v_function),v_new,v_old) <> v_definition then
    raise exception 'ONBOARD-1C-R2 postflight failed: unexpected function delta';
  end if;
end;
$migration$;
