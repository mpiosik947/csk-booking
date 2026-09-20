-- SAAS-9E-C2-B: selected-tenant lane configuration. Existing CSK wrappers stay unchanged.
set lock_timeout='5s';
set statement_timeout='120s';

do $preflight$
declare v_sig regprocedure; v_hash text;
begin
  if (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prosecdef)<>83 then
    raise exception 'C2-B preflight: DEFINER baseline differs';
  end if;
  for v_sig,v_hash in values
    ('public.admin_get_lane_booking_configuration_v1()'::regprocedure,'9c6b9b10c6de8359aca5d88981b52523'),
    ('public.admin_get_lane_booking_configuration_v2()'::regprocedure,'ff748a9030e88f8e395805d30b33ac93'),
    ('public.admin_create_lane_booking_family_v1(jsonb)'::regprocedure,'1fd4b47a640b52564568670d079e7659'),
    ('public.admin_set_lane_booking_family_configuration_v2__saas9d3c_core(uuid,bigint,jsonb,boolean)'::regprocedure,'2dd7c305c6060bcb48af9adaa1c43b64')
  loop
    if md5(replace(replace(pg_get_functiondef(v_sig),E'\r\n',E'\n'),E'\r',E'\n'))<>v_hash then
      raise exception 'C2-B preflight: function drift %',v_sig;
    end if;
  end loop;
  if exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in
      ('admin_get_lane_booking_configuration_v3','admin_get_lane_booking_configuration_v3__saas9ec2b_core',
       'admin_get_lane_booking_configuration_v3__c2b_resource',
       'admin_create_lane_booking_family_v2','admin_create_lane_booking_family_v2__saas9ec2b_core',
       'admin_set_lane_booking_family_configuration_v3')) then
    raise exception 'C2-B preflight: target already exists';
  end if;
end;$preflight$;

do $clone$
declare v_old text; v_new text; v_guard text;
begin
  v_old:=replace(replace(pg_get_functiondef('public.admin_get_lane_booking_configuration_v1()'::regprocedure),E'\r\n',E'\n'),E'\r',E'\n');
  v_guard:=E'  select pg_catalog.lower(pg_catalog.btrim(profile.role::text))\n  into v_actor_role\n  from public.profiles profile\n  where profile.user_id=v_actor_id;\n\n  if coalesce(v_actor_role,'''')<>''admin'' then\n    raise exception ''Lane configuration access is restricted to administrators.''\n      using errcode=''42501'';\n  end if;';
  if strpos(v_old,'public.admin_get_lane_booking_configuration_v1()')=0 or strpos(v_old,v_guard)=0 then
    raise exception 'C2-B v1 source anchors differ';
  end if;
  v_new:=replace(v_old,'public.admin_get_lane_booking_configuration_v1()',
    'public.admin_get_lane_booking_configuration_v3__c2b_resource(p_tenant_id uuid)');
  v_new:=replace(v_new,'v_tenant_id uuid:=public.active_single_tenant_id_v1();','v_tenant_id uuid:=p_tenant_id;');
  v_new:=replace(v_new,v_guard,'');
  if strpos(v_new,'active_single_tenant_id_v1')>0 or strpos(v_new,'profile.role')>0 then raise exception 'C2-B v1 authority remains'; end if;
  execute v_new;

  v_old:=replace(replace(pg_get_functiondef('public.admin_get_lane_booking_configuration_v2()'::regprocedure),E'\r\n',E'\n'),E'\r',E'\n');
  if strpos(v_old,v_guard)=0 or strpos(v_old,'v_v1:=public.admin_get_lane_booking_configuration_v1();')=0 then
    raise exception 'C2-B v2 source anchors differ';
  end if;
  v_new:=replace(v_old,'public.admin_get_lane_booking_configuration_v2()',
    'public.admin_get_lane_booking_configuration_v3__saas9ec2b_core(p_tenant_id uuid)');
  v_new:=replace(v_new,'v_tenant_id uuid:=public.active_single_tenant_id_v1();','v_tenant_id uuid:=p_tenant_id;');
  v_new:=replace(v_new,v_guard,'');
  v_new:=replace(v_new,'v_v1:=public.admin_get_lane_booking_configuration_v1();',
    'v_v1:=public.admin_get_lane_booking_configuration_v3__c2b_resource(p_tenant_id);');
  if strpos(v_new,'active_single_tenant_id_v1')>0 or strpos(v_new,'profile.role')>0 then raise exception 'C2-B v2 authority remains'; end if;
  execute v_new;

  v_old:=replace(replace(pg_get_functiondef('public.admin_create_lane_booking_family_v1(jsonb)'::regprocedure),E'\r\n',E'\n'),E'\r',E'\n');
  if strpos(v_old,'v_tenant_id:=public.active_single_tenant_id_v1();')=0 or
     strpos(v_old,'v_actor_role := pg_catalog.lower(pg_catalog.btrim(v_actor.role::text));')=0 then
    raise exception 'C2-B creator source anchors differ';
  end if;
  v_new:=replace(v_old,'public.admin_create_lane_booking_family_v1(p_family jsonb)',
    'public.admin_create_lane_booking_family_v2__saas9ec2b_core(p_tenant_id uuid, p_family jsonb)');
  v_new:=replace(v_new,'v_tenant_id:=public.active_single_tenant_id_v1();','v_tenant_id:=p_tenant_id;');
  v_new:=replace(v_new,'v_actor_role := pg_catalog.lower(pg_catalog.btrim(v_actor.role::text));',
    'v_actor_role := public.get_my_tenant_role_v1(v_tenant_id);');
  if strpos(v_new,'active_single_tenant_id_v1')>0 or strpos(v_new,'v_actor.role::text')>0
     or strpos(v_new,'tenant_id, actor_user_id,')=0 then raise exception 'C2-B creator target guards differ'; end if;
  execute v_new;
end;$clone$;

do $close_cores$
declare v_sig regprocedure;
begin
  for v_sig in select to_regprocedure(signature) from (values
    ('public.admin_get_lane_booking_configuration_v3__c2b_resource(uuid)'),
    ('public.admin_get_lane_booking_configuration_v3__saas9ec2b_core(uuid)'),
    ('public.admin_create_lane_booking_family_v2__saas9ec2b_core(uuid,jsonb)')) s(signature)
  loop
    if v_sig is null then raise exception 'C2-B clone target missing'; end if;
    execute format('alter function %s owner to postgres',v_sig);
    execute format('alter function %s security invoker',v_sig);
    execute format('revoke all on function %s from public,anon,authenticated,service_role',v_sig);
  end loop;
end;$close_cores$;

create function public.admin_get_lane_booking_configuration_v3(p_tenant_id uuid)
returns jsonb language sql stable security definer set search_path=pg_catalog,public,pg_temp as $fn$
  select public.admin_get_lane_booking_configuration_v3__saas9ec2b_core(p_tenant_id);
$fn$;

create function public.admin_create_lane_booking_family_v2(p_tenant_id uuid,p_family jsonb)
returns jsonb language sql volatile security definer set search_path=pg_catalog,public,pg_temp as $fn$
  select public.admin_create_lane_booking_family_v2__saas9ec2b_core(p_tenant_id,p_family);
$fn$;

-- The old core still derives the tenant from the persisted root and performs
-- conflict-family locking. Lock the root before delegation to bind route T.
create function public.admin_set_lane_booking_family_configuration_v3(
  p_tenant_id uuid,p_root_lane_id uuid,p_expected_version bigint,p_resources jsonb,
  p_acknowledge_future_obligations boolean
) returns jsonb language plpgsql volatile security definer set search_path=pg_catalog,public,pg_temp as $fn$
declare v_actual uuid;
begin
  if public.get_my_tenant_role_v1(p_tenant_id) is distinct from 'admin' then
    return jsonb_build_object('ok',false,'changed',false,'code','not_allowed','root_lane_id',p_root_lane_id);
  end if;
  select root.tenant_id into v_actual from public.shooting_lanes root where root.id=p_root_lane_id for share;
  if v_actual is distinct from p_tenant_id then
    return jsonb_build_object('ok',false,'changed',false,'code','not_allowed','root_lane_id',p_root_lane_id);
  end if;
  return public.admin_set_lane_booking_family_configuration_v2__saas9d3c_core(
    p_root_lane_id,p_expected_version,p_resources,p_acknowledge_future_obligations);
end;$fn$;

do $acl$
declare v_sig regprocedure;
begin
  for v_sig in select to_regprocedure(signature) from (values
    ('public.admin_get_lane_booking_configuration_v3(uuid)'),
    ('public.admin_create_lane_booking_family_v2(uuid,jsonb)'),
    ('public.admin_set_lane_booking_family_configuration_v3(uuid,uuid,bigint,jsonb,boolean)')) s(signature)
  loop
    if v_sig is null then raise exception 'C2-B client target missing'; end if;
    execute format('alter function %s owner to postgres',v_sig);
    execute format('revoke all on function %s from public,anon,authenticated,service_role',v_sig);
    execute format('grant execute on function %s to authenticated',v_sig);
  end loop;
end;$acl$;

do $postflight$
begin
  if (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prosecdef)<>86 then
    raise exception 'C2-B postflight: DEFINER count differs';
  end if;
end;$postflight$;
