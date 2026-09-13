-- SAAS-9D-2A: tenant hardening for seven event-registration RPCs.
-- Public event readers, event-management RPCs and delivery/promotion claims are deferred to 2B/2C.

begin;

set lock_timeout = '5s';
set statement_timeout = '120s';

do $preflight$
begin
  if pg_catalog.to_regprocedure('public.is_tenant_member_v1(uuid)') is null
     or pg_catalog.to_regprocedure('public.get_my_tenant_role_v1(uuid)') is null then
    raise exception 'SAAS-9D-2A preflight failed: tenant authorization helpers are absent.';
  end if;

  if exists (
    select 1
    from pg_catalog.pg_proc procedure
    join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace
    where namespace.nspname='public'
      and procedure.proname like '%__saas9d2a_core'
  ) then
    raise exception 'SAAS-9D-2A preflight failed: planned core objects already exist.';
  end if;

end;
$preflight$;

create temporary table saas9d2a_preflight_guards (
  guard_name text primary key,
  matched_count integer not null check (matched_count=7)
);

insert into saas9d2a_preflight_guards(guard_name,matched_count)
select 'definition_owner_definer',pg_catalog.count(*)
from (values
  ('public.admin_list_event_registrations_v1(uuid,text,text,integer,integer)','ed5fe967179ec6c60590ce7b75722242'),
  ('public.approve_event_registration(uuid)','504923e851372eb41daa128f324763aa'),
  ('public.cancel_event_registration(uuid)','9776e23faf4205f569fb7ab024aed1cc'),
  ('public.confirm_event_reserve_promotion(text)','c8725ce4a78d2fa5294e1fa61b827314'),
  ('public.get_my_event_registrations_v1(text,text,integer,integer)','1b0235278e128425bdbe54ac02ffc040'),
  ('public.mark_event_registration_paid(uuid)','e97f15b3013b296895594c6a48447efb'),
  ('public.register_for_event(uuid,boolean)','c59b5c42cc718d7370a8a4ee8a42f750')
) expected(signature,fingerprint)
join pg_catalog.pg_proc procedure
  on procedure.oid=pg_catalog.to_regprocedure(expected.signature)
where pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(
        pg_catalog.pg_get_functiondef(procedure.oid),E'\r\n',E'\n'
      ),E'\r',E'\n'))=expected.fingerprint
  and procedure.proowner=(select role.oid from pg_catalog.pg_roles role where role.rolname='postgres')
  and procedure.prosecdef;

insert into saas9d2a_preflight_guards(guard_name,matched_count)
select 'execute_acl',pg_catalog.count(*)
from pg_catalog.pg_proc procedure
join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace
where namespace.nspname='public'
  and procedure.proname=any(array[
    'admin_list_event_registrations_v1','approve_event_registration',
    'cancel_event_registration','confirm_event_reserve_promotion',
    'get_my_event_registrations_v1','mark_event_registration_paid',
    'register_for_event'
  ])
  and not pg_catalog.has_function_privilege('public',procedure.oid,'EXECUTE')
  and not pg_catalog.has_function_privilege('anon',procedure.oid,'EXECUTE')
  and pg_catalog.has_function_privilege('authenticated',procedure.oid,'EXECUTE')
  and (
    pg_catalog.has_function_privilege('service_role',procedure.oid,'EXECUTE')
    is not distinct from (procedure.proname='cancel_event_registration')
  );

create temporary table saas9d2a_unchanged_definer_snapshot on commit drop as
select
  procedure.proname,
  pg_catalog.pg_get_function_identity_arguments(procedure.oid) as identity_arguments,
  pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(
    pg_catalog.pg_get_functiondef(procedure.oid),E'\r\n',E'\n'
  ),E'\r',E'\n')) as fingerprint,
  procedure.proowner,
  procedure.proconfig,
  procedure.proacl
from pg_catalog.pg_proc procedure
join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace
where namespace.nspname='public'
  and procedure.prosecdef
  and procedure.proname not in (
    'admin_list_event_registrations_v1','approve_event_registration',
    'cancel_event_registration','confirm_event_reserve_promotion',
    'get_my_event_registrations_v1','mark_event_registration_paid',
    'register_for_event'
  );

alter function public.admin_list_event_registrations_v1(uuid,text,text,integer,integer)
  rename to admin_list_event_registrations_v1__saas9d2a_core;
alter function public.approve_event_registration(uuid)
  rename to approve_event_registration__saas9d2a_core;
alter function public.cancel_event_registration(uuid)
  rename to cancel_event_registration__saas9d2a_core;
alter function public.confirm_event_reserve_promotion(text)
  rename to confirm_event_reserve_promotion__saas9d2a_core;
alter function public.get_my_event_registrations_v1(text,text,integer,integer)
  rename to get_my_event_registrations_v1__saas9d2a_core;
alter function public.mark_event_registration_paid(uuid)
  rename to mark_event_registration_paid__saas9d2a_core;
alter function public.register_for_event(uuid,boolean)
  rename to register_for_event__saas9d2a_core;

-- Patch only tenant ownership writes/filters inside the frozen business implementations.
do $patch_cores$
declare
  v_definition text;
  v_patched text;
begin
  select pg_catalog.pg_get_functiondef(
    'public.register_for_event__saas9d2a_core(uuid,boolean)'::pg_catalog.regprocedure
  ) into v_definition;
  v_patched := pg_catalog.regexp_replace(
    v_definition,
    '(insert into public[.]event_registrations [(][[:space:]]*)event_id,',
    E'\\1tenant_id,\n      event_id,'
  );
  v_patched := pg_catalog.regexp_replace(
    v_patched,
    '([)][[:space:]]*values [(][[:space:]]*)p_event_id,',
    E'\\1v_event.tenant_id,\n      p_event_id,'
  );
  if v_patched is not distinct from v_definition
     or pg_catalog.strpos(v_patched,'tenant_id,')=0
     or pg_catalog.strpos(v_patched,'v_event.tenant_id,')=0 then
    raise exception 'SAAS-9D-2A failed to patch registration tenant ownership.';
  end if;
  execute v_patched;

  select pg_catalog.pg_get_functiondef(
    'public.get_my_event_registrations_v1__saas9d2a_core(text,text,integer,integer)'::pg_catalog.regprocedure
  ) into v_definition;
  v_patched := pg_catalog.regexp_replace(
    v_definition,
    '(join public[.]events event_record on event_record[.]id=registration[.]event_id[[:space:]]*)where registration[.]user_id=v_actor',
    E'\\1join public.tenant_memberships membership\n      on membership.tenant_id=registration.tenant_id\n     and membership.user_id=v_actor\n     and membership.status=\'active\'\n    join public.tenants tenant\n      on tenant.id=registration.tenant_id\n     and tenant.status=\'active\'\n    where registration.user_id=v_actor\n      and event_record.tenant_id=registration.tenant_id'
  );
  if v_patched is not distinct from v_definition
     or pg_catalog.strpos(v_patched,'membership.tenant_id=registration.tenant_id')=0
     or pg_catalog.strpos(v_patched,'event_record.tenant_id=registration.tenant_id')=0 then
    raise exception 'SAAS-9D-2A failed to patch my-events tenant filter.';
  end if;
  execute v_patched;

  select pg_catalog.pg_get_functiondef(
    'public.approve_event_registration__saas9d2a_core(uuid)'::pg_catalog.regprocedure
  ) into v_definition;
  v_patched := pg_catalog.regexp_replace(
    v_definition,
    '(insert into public[.]audit_logs [(][[:space:]]*)actor_user_id,',
    E'\\1tenant_id,\n    actor_user_id,'
  );
  v_patched := pg_catalog.regexp_replace(
    v_patched,
    '(values [(][[:space:]]*)actor_user_id,',
    E'\\1target_registration.tenant_id,\n    actor_user_id,'
  );
  if v_patched is not distinct from v_definition
     or pg_catalog.strpos(v_patched,'target_registration.tenant_id')=0 then
    raise exception 'SAAS-9D-2A failed to patch approval audit tenant.';
  end if;
  execute v_patched;

  select pg_catalog.pg_get_functiondef(
    'public.cancel_event_registration__saas9d2a_core(uuid)'::pg_catalog.regprocedure
  ) into v_definition;
  v_patched := pg_catalog.regexp_replace(
    v_definition,
    '(insert into public[.]audit_logs [(][[:space:]]*)actor_user_id,',
    E'\\1tenant_id,\n    actor_user_id,'
  );
  v_patched := pg_catalog.regexp_replace(
    v_patched,
    '(values [(][[:space:]]*)actor_user_id,',
    E'\\1target_registration.tenant_id,\n    actor_user_id,'
  );
  if v_patched is not distinct from v_definition
     or pg_catalog.strpos(v_patched,'target_registration.tenant_id')=0 then
    raise exception 'SAAS-9D-2A failed to patch cancellation audit tenant.';
  end if;
  execute v_patched;

  select pg_catalog.pg_get_functiondef(
    'public.mark_event_registration_paid__saas9d2a_core(uuid)'::pg_catalog.regprocedure
  ) into v_definition;
  v_patched := pg_catalog.regexp_replace(
    v_definition,
    '(insert into public[.]audit_logs[(][[:space:]]*)actor_user_id,',
    E'\\1tenant_id,\n    actor_user_id,'
  );
  v_patched := pg_catalog.regexp_replace(
    v_patched,
    '(values [(][[:space:]]*)v_actor_id,',
    E'\\1v_registration.tenant_id,\n    v_actor_id,'
  );
  if v_patched is not distinct from v_definition
     or pg_catalog.strpos(v_patched,'v_registration.tenant_id')=0 then
    raise exception 'SAAS-9D-2A failed to patch payment audit tenant.';
  end if;
  execute v_patched;
end;
$patch_cores$;

alter function public.admin_list_event_registrations_v1__saas9d2a_core(uuid,text,text,integer,integer) security invoker;
alter function public.approve_event_registration__saas9d2a_core(uuid) security invoker;
alter function public.cancel_event_registration__saas9d2a_core(uuid) security invoker;
alter function public.confirm_event_reserve_promotion__saas9d2a_core(text) security invoker;
alter function public.get_my_event_registrations_v1__saas9d2a_core(text,text,integer,integer) security invoker;
alter function public.mark_event_registration_paid__saas9d2a_core(uuid) security invoker;
alter function public.register_for_event__saas9d2a_core(uuid,boolean) security invoker;

revoke all on function public.admin_list_event_registrations_v1__saas9d2a_core(uuid,text,text,integer,integer) from public,anon,authenticated,service_role;
revoke all on function public.approve_event_registration__saas9d2a_core(uuid) from public,anon,authenticated,service_role;
revoke all on function public.cancel_event_registration__saas9d2a_core(uuid) from public,anon,authenticated,service_role;
revoke all on function public.confirm_event_reserve_promotion__saas9d2a_core(text) from public,anon,authenticated,service_role;
revoke all on function public.get_my_event_registrations_v1__saas9d2a_core(text,text,integer,integer) from public,anon,authenticated,service_role;
revoke all on function public.mark_event_registration_paid__saas9d2a_core(uuid) from public,anon,authenticated,service_role;
revoke all on function public.register_for_event__saas9d2a_core(uuid,boolean) from public,anon,authenticated,service_role;

create function public.register_for_event(p_event_id uuid,p_as_reserve boolean default false)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,pg_temp
as $function$
declare v_tenant uuid;
begin
  select event_record.tenant_id into v_tenant
  from public.events event_record where event_record.id=p_event_id;
  if not found then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','event_not_found');
  end if;
  if not public.is_tenant_member_v1(v_tenant) then
    raise exception 'Uwierzytelniona aktywna relacja z tenantem jest wymagana.' using errcode='42501';
  end if;
  return public.register_for_event__saas9d2a_core(p_event_id,p_as_reserve);
end;
$function$;

create function public.cancel_event_registration(p_registration_id uuid)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,pg_temp
as $function$
declare
  v_actor uuid:=auth.uid();
  v_tenant uuid;
  v_owner uuid;
  v_role text;
begin
  if v_actor is null then raise exception 'Brak aktywnej sesji użytkownika.' using errcode='42501'; end if;
  if p_registration_id is null then raise exception 'Brak identyfikatora zapisu na szkolenie.' using errcode='22023'; end if;
  select registration.tenant_id,registration.user_id into v_tenant,v_owner
  from public.event_registrations registration
  where registration.id=p_registration_id;
  if not found then raise exception 'Nie znaleziono zapisu na szkolenie.' using errcode='P0002'; end if;
  v_role:=public.get_my_tenant_role_v1(v_tenant);
  if v_role is null or (v_owner is distinct from v_actor and v_role not in ('admin','employee')) then
    raise exception 'Brak uprawnień do anulowania tego zapisu na szkolenie.' using errcode='42501';
  end if;
  return public.cancel_event_registration__saas9d2a_core(p_registration_id);
end;
$function$;

create function public.approve_event_registration(p_registration_id uuid)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,pg_temp
as $function$
declare v_tenant uuid; v_role text;
begin
  select registration.tenant_id into v_tenant
  from public.event_registrations registration
  where registration.id=p_registration_id;
  if not found then return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','registration_not_found'); end if;
  v_role:=public.get_my_tenant_role_v1(v_tenant);
  if v_role is null or v_role not in ('admin','employee') then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','unauthorized');
  end if;
  return public.approve_event_registration__saas9d2a_core(p_registration_id);
end;
$function$;

create function public.mark_event_registration_paid(p_registration_id uuid)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,pg_temp
as $function$
declare v_tenant uuid; v_role text;
begin
  select registration.tenant_id into v_tenant
  from public.event_registrations registration
  where registration.id=p_registration_id;
  if not found then return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','registration_not_found'); end if;
  v_role:=public.get_my_tenant_role_v1(v_tenant);
  if v_role is null or v_role not in ('admin','employee') then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','not_allowed');
  end if;
  return public.mark_event_registration_paid__saas9d2a_core(p_registration_id);
end;
$function$;

create function public.confirm_event_reserve_promotion(p_token text)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,pg_temp
as $function$
declare v_actor uuid:=auth.uid(); v_tenant uuid; v_owner uuid;
begin
  if v_actor is null then raise exception 'Authentication is required.' using errcode='42501'; end if;
  if p_token is null or pg_catalog.btrim(p_token)='' then
    return public.confirm_event_reserve_promotion__saas9d2a_core(p_token);
  end if;
  select registration.tenant_id,registration.user_id into v_tenant,v_owner
  from public.event_registrations registration
  where registration.promotion_token=pg_catalog.btrim(p_token);
  if not found then return public.confirm_event_reserve_promotion__saas9d2a_core(p_token); end if;
  if v_owner is distinct from v_actor or not public.is_tenant_member_v1(v_tenant) then
    raise exception 'You cannot confirm this registration.' using errcode='42501';
  end if;
  return public.confirm_event_reserve_promotion__saas9d2a_core(p_token);
end;
$function$;

create function public.get_my_event_registrations_v1(
  p_scope text default 'upcoming',p_status text default null,
  p_page integer default 1,p_page_size integer default 20
) returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,pg_temp
as $function$
begin
  if auth.uid() is null then
    return pg_catalog.jsonb_build_object('ok',false,'code','not_allowed');
  end if;
  return public.get_my_event_registrations_v1__saas9d2a_core(p_scope,p_status,p_page,p_page_size);
end;
$function$;

create function public.admin_list_event_registrations_v1(
  p_event_id uuid,p_status text default null,p_payment_status text default null,
  p_page integer default 1,p_page_size integer default 50
) returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,pg_temp
as $function$
declare v_tenant uuid; v_role text;
begin
  select event_record.tenant_id into v_tenant
  from public.events event_record where event_record.id=p_event_id;
  if not found then return pg_catalog.jsonb_build_object('ok',false,'code','invalid_input'); end if;
  v_role:=public.get_my_tenant_role_v1(v_tenant);
  if v_role is null or v_role not in ('admin','employee','instructor') then
    return pg_catalog.jsonb_build_object('ok',false,'code','not_allowed');
  end if;
  return public.admin_list_event_registrations_v1__saas9d2a_core(
    p_event_id,p_status,p_payment_status,p_page,p_page_size
  );
end;
$function$;

alter function public.admin_list_event_registrations_v1(uuid,text,text,integer,integer) owner to postgres;
alter function public.approve_event_registration(uuid) owner to postgres;
alter function public.cancel_event_registration(uuid) owner to postgres;
alter function public.confirm_event_reserve_promotion(text) owner to postgres;
alter function public.get_my_event_registrations_v1(text,text,integer,integer) owner to postgres;
alter function public.mark_event_registration_paid(uuid) owner to postgres;
alter function public.register_for_event(uuid,boolean) owner to postgres;

revoke all on function public.admin_list_event_registrations_v1(uuid,text,text,integer,integer) from public,anon,authenticated,service_role;
revoke all on function public.approve_event_registration(uuid) from public,anon,authenticated,service_role;
revoke all on function public.cancel_event_registration(uuid) from public,anon,authenticated,service_role;
revoke all on function public.confirm_event_reserve_promotion(text) from public,anon,authenticated,service_role;
revoke all on function public.get_my_event_registrations_v1(text,text,integer,integer) from public,anon,authenticated,service_role;
revoke all on function public.mark_event_registration_paid(uuid) from public,anon,authenticated,service_role;
revoke all on function public.register_for_event(uuid,boolean) from public,anon,authenticated,service_role;

grant execute on function public.admin_list_event_registrations_v1(uuid,text,text,integer,integer) to authenticated;
grant execute on function public.approve_event_registration(uuid) to authenticated;
grant execute on function public.cancel_event_registration(uuid) to authenticated;
grant execute on function public.confirm_event_reserve_promotion(text) to authenticated;
grant execute on function public.get_my_event_registrations_v1(text,text,integer,integer) to authenticated;
grant execute on function public.mark_event_registration_paid(uuid) to authenticated;
grant execute on function public.register_for_event(uuid,boolean) to authenticated;

do $postflight$
declare v_changed integer; v_unchanged integer; v_snapshot integer;
begin
  select pg_catalog.count(*) into v_changed
  from pg_catalog.pg_proc procedure
  join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace
  where namespace.nspname='public'
    and procedure.prosecdef
    and procedure.proname in (
      'admin_list_event_registrations_v1','approve_event_registration',
      'cancel_event_registration','confirm_event_reserve_promotion',
      'get_my_event_registrations_v1','mark_event_registration_paid',
      'register_for_event'
    )
    and procedure.proowner=(select role.oid from pg_catalog.pg_roles role where role.rolname='postgres')
    and procedure.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[];
  if v_changed<>7 then raise exception 'SAAS-9D-2A postflight failed: wrapper metadata differs.'; end if;

  if (select pg_catalog.count(*) from pg_catalog.pg_proc procedure
      join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace
      where namespace.nspname='public' and procedure.proname like '%__saas9d2a_core'
        and not procedure.prosecdef)<>7 then
    raise exception 'SAAS-9D-2A postflight failed: core inventory differs.';
  end if;

  select pg_catalog.count(*) into v_unchanged
  from pg_catalog.pg_proc procedure
  join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace
  join saas9d2a_unchanged_definer_snapshot snapshot
    on snapshot.proname=procedure.proname
   and snapshot.identity_arguments=pg_catalog.pg_get_function_identity_arguments(procedure.oid)
  where namespace.nspname='public' and procedure.prosecdef
    and snapshot.fingerprint=pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(
      pg_catalog.pg_get_functiondef(procedure.oid),E'\r\n',E'\n'
    ),E'\r',E'\n'))
    and snapshot.proowner=procedure.proowner
    and snapshot.proconfig is not distinct from procedure.proconfig
    and snapshot.proacl is not distinct from procedure.proacl;
  select pg_catalog.count(*) into v_snapshot from saas9d2a_unchanged_definer_snapshot;
  if v_unchanged<>v_snapshot then
    raise exception 'SAAS-9D-2A postflight failed: an out-of-scope definer changed.';
  end if;

  if (select pg_catalog.count(*) from pg_catalog.pg_proc procedure
      join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace
      where namespace.nspname='public' and procedure.prosecdef)<>73 then
    raise exception 'SAAS-9D-2A postflight failed: SECURITY DEFINER count changed.';
  end if;
end;
$postflight$;

commit;
