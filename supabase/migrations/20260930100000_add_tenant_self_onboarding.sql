begin;

do $preflight$
begin
  if pg_catalog.to_regclass('public.tenants') is null
     or pg_catalog.to_regclass('public.tenant_memberships') is null
     or pg_catalog.to_regclass('public.profiles') is null then
    raise exception 'SAAS-9D-5A-1 preflight failed: tenant foundation is missing.';
  end if;
  if pg_catalog.to_regprocedure('public.self_onboard_tenant_v1(text)') is not null then
    raise exception 'SAAS-9D-5A-1 preflight failed: onboarding contract already exists.';
  end if;
  if not exists (
    select 1 from pg_catalog.pg_constraint
    where conrelid='public.tenant_memberships'::pg_catalog.regclass
      and contype='p' and conkey=array[
        (select attnum from pg_catalog.pg_attribute where attrelid='public.tenant_memberships'::pg_catalog.regclass and attname='tenant_id'),
        (select attnum from pg_catalog.pg_attribute where attrelid='public.tenant_memberships'::pg_catalog.regclass and attname='user_id')
      ]::smallint[]
  ) then
    raise exception 'SAAS-9D-5A-1 preflight failed: membership idempotency key differs.';
  end if;
  if (select pg_catalog.count(*) from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.prosecdef)<>96 then
    raise exception 'SAAS-9D-5A-1 preflight failed: SECURITY DEFINER baseline differs.';
  end if;
  if (select pg_catalog.count(*) from information_schema.columns
      where table_schema='public' and column_name='tenant_id'
        and table_name in('shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','email_deliveries')
        and column_default='''c5c00000-0000-4000-8000-000000000001''::uuid')<>7 then
    raise exception 'SAAS-9D-5A-1 preflight failed: compatibility defaults differ.';
  end if;
end;
$preflight$;

create function public.self_onboard_tenant_v1(p_tenant_slug text)
returns table(
  tenant_id uuid,
  user_id uuid,
  role text,
  status text,
  created boolean
)
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $function$
declare
  v_actor_id uuid:=auth.uid();
  v_tenant_id uuid;
  v_inserted boolean:=false;
  v_rows integer:=0;
begin
  if v_actor_id is null then
    raise exception 'Uwierzytelnienie jest wymagane.' using errcode='42501';
  end if;
  if p_tenant_slug is null
     or p_tenant_slug<>pg_catalog.btrim(p_tenant_slug)
     or pg_catalog.char_length(p_tenant_slug) not between 2 and 63
     or p_tenant_slug!~'^[a-z0-9]+(?:-[a-z0-9]+)*$' then
    raise exception 'Nieprawidłowy tenant.' using errcode='22023';
  end if;
  if not exists(
    select 1 from auth.users auth_user
    where auth_user.id=v_actor_id and auth_user.deleted_at is null
      and (auth_user.banned_until is null or auth_user.banned_until<=pg_catalog.statement_timestamp())
  ) then
    raise exception 'Konto nie jest aktywne.' using errcode='42501';
  end if;

  select tenant.id into v_tenant_id
  from public.tenants tenant
  where tenant.slug=p_tenant_slug and tenant.status='active'
  for share;
  if not found then
    raise exception 'Nie znaleziono aktywnej lokalizacji.' using errcode='P0002';
  end if;

  insert into public.tenant_memberships as membership(tenant_id,user_id,role,status)
  values(v_tenant_id,v_actor_id,'user','active')
  on conflict on constraint tenant_memberships_pkey do nothing;
  get diagnostics v_rows=row_count;
  v_inserted:=v_rows=1;

  if v_inserted then
    insert into public.audit_logs(
      tenant_id,actor_user_id,actor_name,actor_role,action,target_type,target_id,target_name,details
    ) values(
      v_tenant_id,v_actor_id,'Tenant user','user','tenant_user_role_updated',
      'tenant_user_role',v_actor_id,'Tenant user',
      pg_catalog.jsonb_build_object('previous_role',null,'new_role','user','status','active',
        'operation','self_onboarding','source','explicit_tenant_slug')
    );
  end if;

  return query
  select membership.tenant_id,membership.user_id,membership.role,membership.status,v_inserted
  from public.tenant_memberships membership
  where membership.tenant_id=v_tenant_id and membership.user_id=v_actor_id;
end;
$function$;

alter function public.self_onboard_tenant_v1(text) owner to postgres;
revoke all on function public.self_onboard_tenant_v1(text) from public, anon, service_role;
grant execute on function public.self_onboard_tenant_v1(text) to authenticated;

comment on function public.self_onboard_tenant_v1(text) is
  'Explicit authenticated self-onboarding into one server/DB-validated active tenant. New relationships are always active user memberships; existing membership role/status is never modified.';

do $postflight$
declare v_oid oid:='public.self_onboard_tenant_v1(text)'::pg_catalog.regprocedure;
begin
  if not exists(
    select 1 from pg_catalog.pg_proc p
    where p.oid=v_oid and p.prosecdef and p.provolatile='v'
      and pg_catalog.pg_get_userbyid(p.proowner)='postgres'
      and p.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[]
      and pg_catalog.strpos(p.prosrc,'active_single_tenant_id_v1')=0
      and pg_catalog.strpos(p.prosrc,'profiles.role')=0
  ) then
    raise exception 'SAAS-9D-5A-1 postflight failed: onboarding metadata or authority differs.';
  end if;
  if pg_catalog.has_function_privilege('public',v_oid,'EXECUTE')
     or pg_catalog.has_function_privilege('anon',v_oid,'EXECUTE')
     or not pg_catalog.has_function_privilege('authenticated',v_oid,'EXECUTE')
     or pg_catalog.has_function_privilege('service_role',v_oid,'EXECUTE') then
    raise exception 'SAAS-9D-5A-1 postflight failed: onboarding ACL differs.';
  end if;
  if (select pg_catalog.count(*) from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.prosecdef)<>97 then
    raise exception 'SAAS-9D-5A-1 postflight failed: SECURITY DEFINER count differs.';
  end if;
end;
$postflight$;

commit;
