-- SAAS-9E-C2-C: selected-tenant reports. Tenant predicate precedes all aggregation/export.
set lock_timeout='5s';
set statement_timeout='120s';
do $preflight$
begin
  if (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prosecdef)<>86 then
    raise exception 'C2-C preflight: DEFINER baseline differs'; end if;
  if md5(replace(replace(pg_get_functiondef('public.admin_get_reservation_report_v2(date,date,uuid,text,text,text,integer,integer)'::regprocedure),E'\r\n',E'\n'),E'\r',E'\n'))<>'ded8346e37b87bbf278d3b7b4673ae18'
    or md5(replace(replace(pg_get_functiondef('public.admin_get_reservation_report_export_v1(date,date,uuid,text,text,text)'::regprocedure),E'\r\n',E'\n'),E'\r',E'\n'))<>'5a8fd638e4c7a867477781876358dcf1' then
    raise exception 'C2-C preflight: report sources drifted'; end if;
  if to_regprocedure('public.admin_get_reservation_report_v3(uuid,date,date,uuid,text,text,text,integer,integer)') is not null
     or to_regprocedure('public.admin_get_reservation_report_export_v2(uuid,date,date,uuid,text,text,text)') is not null then
    raise exception 'C2-C preflight: target already exists'; end if;
end;$preflight$;

do $clone$
declare old_body text; target_body text; source regprocedure; name_from text; name_to text;
begin
  for source,name_from,name_to in values
    ('public.admin_get_reservation_report_v2(date,date,uuid,text,text,text,integer,integer)'::regprocedure,
      'public.admin_get_reservation_report_v2(','public.admin_get_reservation_report_v3('),
    ('public.admin_get_reservation_report_export_v1(date,date,uuid,text,text,text)'::regprocedure,
      'public.admin_get_reservation_report_export_v1(','public.admin_get_reservation_report_export_v2(')
  loop
    old_body:=replace(replace(pg_get_functiondef(source),E'\r\n',E'\n'),E'\r',E'\n');
    if strpos(old_body,name_from||'p_start_date date')=0 or
       strpos(old_body,'v_tenant_id uuid:=public.active_single_tenant_id_v1();')=0 or
       strpos(old_body,'_admin_reservation_report_rows_v2__saas9d4a_core(')=0 then
      raise exception 'C2-C clone: source anchors differ: %',source;
    end if;
    target_body:=replace(old_body,name_from||'p_start_date date',name_to||'p_tenant_id uuid, p_start_date date');
    target_body:=replace(target_body,'v_tenant_id uuid:=public.active_single_tenant_id_v1();','v_tenant_id uuid:=p_tenant_id;');
    if strpos(target_body,'active_single_tenant_id_v1')>0 or strpos(target_body,'v_tenant_id uuid:=p_tenant_id;')=0 then
      raise exception 'C2-C clone: legacy bridge remains: %',source; end if;
    execute target_body;
  end loop;
end;$clone$;

do $acl$
declare sig regprocedure;
begin
  for sig in select to_regprocedure(signature) from (values
    ('public.admin_get_reservation_report_v3(uuid,date,date,uuid,text,text,text,integer,integer)'),
    ('public.admin_get_reservation_report_export_v2(uuid,date,date,uuid,text,text,text)')) v(signature)
  loop
    if sig is null then raise exception 'C2-C target missing'; end if;
    execute format('alter function %s owner to postgres',sig);
    execute format('revoke all on function %s from public,anon,authenticated,service_role',sig);
    execute format('grant execute on function %s to authenticated',sig);
  end loop;
end;$acl$;
do $postflight$
begin
  if (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prosecdef)<>88 then
    raise exception 'C2-C postflight: DEFINER count differs'; end if;
end;$postflight$;
