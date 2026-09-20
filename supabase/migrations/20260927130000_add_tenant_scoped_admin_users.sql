-- SAAS-9E-C2-D: selected-tenant admin Users contracts. Legacy functions remain unchanged.
set lock_timeout='5s';
set statement_timeout='120s';
do $preflight$
declare expected text[]:=array[
  'bf37ec48de512ea45f5d4592df5f4eac',
  '9732b7d53eaa080ebc6348cd1dd68ca2',
  'e8245e2156b20e6d1dfd48b4adfb747b',
  '022baa5652409d2246cd5e66642e884e',
  '33e0a05fb0d142cd9ba7d99cc66c6652',
  'ce0146bccc9a1cc1d89c3e4d26462586'];
  sources text[]:=array[
  'public.admin_list_users_v1(integer,integer,text,text,text,text)',
  'public.admin_set_user_role_v1(uuid,text)',
  'public.admin_set_user_note_v1(uuid,text)',
  'public.update_profile_verification(uuid,text,text)',
  'public.update_profile_identity(uuid,text,text)',
  'public.update_profile_contact_details(uuid,text,text,text,text,text,text)'];
  targets text[]:=array[
  'public.admin_list_users_v2(uuid,integer,integer,text,text,text,text)',
  'public.admin_set_user_role_v2(uuid,uuid,text)',
  'public.admin_set_user_note_v2(uuid,uuid,text)',
  'public.update_tenant_profile_verification_v2(uuid,uuid,text,text)',
  'public.update_tenant_profile_identity_v2(uuid,uuid,text,text)',
  'public.update_tenant_profile_contact_details_v2(uuid,uuid,text,text,text,text,text,text)'];
begin
  if (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prosecdef)<>88 then
    raise exception 'C2-D preflight: DEFINER baseline differs'; end if;
  for i in 1..6 loop
    if to_regprocedure(sources[i]) is null or to_regprocedure(targets[i]) is not null or
       md5(replace(replace(pg_get_functiondef(to_regprocedure(sources[i])),E'\r\n',E'\n'),E'\r',E'\n'))<>expected[i] then
      raise exception 'C2-D preflight: source drift or target exists: %',sources[i]; end if;
  end loop;
end;$preflight$;

do $clone$
declare sources text[]:=array[
  'public.admin_list_users_v1(integer,integer,text,text,text,text)',
  'public.admin_set_user_role_v1(uuid,text)',
  'public.admin_set_user_note_v1(uuid,text)',
  'public.update_profile_verification(uuid,text,text)',
  'public.update_profile_identity(uuid,text,text)',
  'public.update_profile_contact_details(uuid,text,text,text,text,text,text)'];
  old_names text[]:=array['admin_list_users_v1','admin_set_user_role_v1','admin_set_user_note_v1',
    'update_profile_verification','update_profile_identity','update_profile_contact_details'];
  new_names text[]:=array['admin_list_users_v2','admin_set_user_role_v2','admin_set_user_note_v2',
    'update_tenant_profile_verification_v2','update_tenant_profile_identity_v2','update_tenant_profile_contact_details_v2'];
  body text; target text;
begin
  for i in 1..6 loop
    body:=replace(replace(pg_get_functiondef(to_regprocedure(sources[i])),E'\r\n',E'\n'),E'\r',E'\n');
    if strpos(body,'public.'||old_names[i]||'(')=0 or
       strpos(body,'v_tenant_id uuid:=public.active_single_tenant_id_v1();')=0 then
      raise exception 'C2-D clone anchors absent: %',sources[i]; end if;
    target:=replace(body,'public.'||old_names[i]||'(',
      'public.'||new_names[i]||'(p_tenant_id uuid, ');
    target:=replace(target,'v_tenant_id uuid:=public.active_single_tenant_id_v1();',
      'v_tenant_id uuid:=p_tenant_id;');
    if strpos(target,'active_single_tenant_id_v1')>0 or strpos(target,'v_tenant_id uuid:=p_tenant_id;')=0 then
      raise exception 'C2-D legacy bridge remains: %',sources[i]; end if;
    execute target;
  end loop;
end;$clone$;

do $acl$
declare signatures text[]:=array[
  'public.admin_list_users_v2(uuid,integer,integer,text,text,text,text)',
  'public.admin_set_user_role_v2(uuid,uuid,text)',
  'public.admin_set_user_note_v2(uuid,uuid,text)',
  'public.update_tenant_profile_verification_v2(uuid,uuid,text,text)',
  'public.update_tenant_profile_identity_v2(uuid,uuid,text,text)',
  'public.update_tenant_profile_contact_details_v2(uuid,uuid,text,text,text,text,text,text)'];
  sig regprocedure;
begin
  foreach sig in array (select array_agg(to_regprocedure(s)) from unnest(signatures) s) loop
    if sig is null then raise exception 'C2-D target missing'; end if;
    execute format('alter function %s owner to postgres',sig);
    execute format('revoke all on function %s from public,anon,authenticated,service_role',sig);
    execute format('grant execute on function %s to authenticated',sig);
  end loop;
end;$acl$;
do $postflight$
begin
  if (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prosecdef)<>94 then
    raise exception 'C2-D postflight: DEFINER count differs'; end if;
end;$postflight$;
