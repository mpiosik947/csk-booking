begin;

-- The canonical auth trigger is not represented by the historical public-schema
-- baseline dump, but it is present in production. Reconcile that dump boundary
-- without replacing an already-correct production trigger. The function is
-- guarded positively before any trigger is accepted or created.
do $auth_profile_trigger_reconciliation$
declare
  v_function oid:=pg_catalog.to_regprocedure('public.handle_new_user()');
  v_trigger_count integer;
  v_definition text;
begin
  if v_function is null then
    raise exception 'SAAS-9D-5A-3 preflight failed: canonical auth profile function is missing.';
  end if;

  select pg_catalog.replace(pg_catalog.replace(
    pg_catalog.pg_get_functiondef(v_function),E'\r\n',E'\n'),E'\r',E'\n')
  into v_definition;

  if pg_catalog.md5(pg_catalog.regexp_replace(
       (select p.prosrc from pg_catalog.pg_proc p where p.oid=v_function),
       '[[:space:]]+',' ','g'))<>'1de0460e8b4298219dd8be7d953bb0f5'
     or not exists(select 1 from pg_catalog.pg_proc p where p.oid=v_function
       and pg_catalog.pg_get_function_identity_arguments(p.oid)=''
       and p.prosecdef
       and pg_catalog.pg_get_userbyid(p.proowner)='postgres'
       and p.proconfig=array['search_path=public, pg_temp']::text[])
     or pg_catalog.has_function_privilege('public',v_function,'EXECUTE')
     or pg_catalog.has_function_privilege('anon',v_function,'EXECUTE')
     or pg_catalog.has_function_privilege('authenticated',v_function,'EXECUTE')
     or pg_catalog.has_function_privilege('service_role',v_function,'EXECUTE')
     or pg_catalog.strpos(v_definition,'tenant_memberships')>0
     or pg_catalog.strpos(v_definition,'active_single_tenant')>0
     or pg_catalog.strpos(v_definition,'self_onboard_tenant')>0
     or pg_catalog.strpos(v_definition,'sync_profile_role')>0
     or pg_catalog.strpos(v_definition,'sync_csk_membership')>0 then
    raise exception 'SAAS-9D-5A-3 preflight failed: canonical auth profile function drifted or gained tenant side effects.';
  end if;

  select pg_catalog.count(*) into v_trigger_count
  from pg_catalog.pg_trigger t
  where not t.tgisinternal and t.tgrelid='auth.users'::regclass;

  if v_trigger_count=0 then
    execute $trigger$
      create trigger on_auth_user_created
      after insert on auth.users
      for each row
      execute function public.handle_new_user()
    $trigger$;
  elsif v_trigger_count<>1
     or not exists(select 1 from pg_catalog.pg_trigger t
       where not t.tgisinternal and t.tgrelid='auth.users'::regclass
         and t.tgname='on_auth_user_created' and t.tgfoid=v_function
         and t.tgenabled='O' and t.tgtype=5 and t.tgqual is null) then
    raise exception 'SAAS-9D-5A-3 preflight failed: auth profile trigger target or inventory differs.';
  end if;

  if (select pg_catalog.count(*) from pg_catalog.pg_trigger t
      where not t.tgisinternal and t.tgrelid='auth.users'::regclass
        and t.tgname='on_auth_user_created' and t.tgfoid=v_function)<>1 then
    raise exception 'SAAS-9D-5A-3 preflight failed: canonical auth profile trigger is not unique.';
  end if;
end;
$auth_profile_trigger_reconciliation$;

do $preflight$
declare v_expected record;
begin
  if pg_catalog.to_regprocedure('public.self_onboard_tenant_v1(text)') is null then
    raise exception 'SAAS-9D-5A-3 preflight failed: replacement onboarding is missing.';
  end if;
  for v_expected in select * from (values
    ('public.prevent_non_admin_profile_privilege_changes()'::regprocedure,'8a3cb4dc2d663cbf3c866fc3d9c8dac7'),
    ('public.sync_csk_membership_role_to_profile()'::regprocedure,'d7075b43007466d1a6deb59c590f026d'),
    ('public.sync_profile_role_to_csk_membership()'::regprocedure,'4621f7f4e214313457728a6e4f365894'),
    ('public.update_profile_contact_details(uuid,text,text,text,text,text,text)'::regprocedure,'ce0146bccc9a1cc1d89c3e4d26462586'),
    ('public.update_profile_identity(uuid,text,text)'::regprocedure,'33e0a05fb0d142cd9ba7d99cc66c6652'),
    ('public.update_tenant_profile_contact_details_v2(uuid,uuid,text,text,text,text,text,text)'::regprocedure,'9a446df6a06f1f3f6ce6616c6925b3b6'),
    ('public.update_tenant_profile_identity_v2(uuid,uuid,text,text)'::regprocedure,'b0136d12d54def2800dd914ea32274a9')
  ) frozen(function_oid,fingerprint)
  loop
    if pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(
      pg_catalog.pg_get_functiondef(v_expected.function_oid),E'\r\n',E'\n'),E'\r',E'\n'))<>v_expected.fingerprint then
      raise exception 'SAAS-9D-5A-3 preflight failed: function drift in %.',v_expected.function_oid;
    end if;
  end loop;
  if (select pg_catalog.count(*) from pg_catalog.pg_trigger
      where not tgisinternal and tgname in(
        'sync_profile_role_to_csk_membership','sync_csk_membership_role_to_profile'
      ))<>2 then
    raise exception 'SAAS-9D-5A-3 preflight failed: role-sync trigger inventory differs.';
  end if;
  if (select pg_catalog.count(*) from pg_catalog.pg_trigger
      where not tgisinternal and tgrelid='auth.users'::regclass
        and tgname='on_auth_user_created'
        and tgfoid='public.handle_new_user()'::regprocedure)<>1 then
    raise exception 'SAAS-9D-5A-3 preflight failed: canonical auth profile trigger differs.';
  end if;
  if (select pg_catalog.count(*) from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.prosecdef)<>97 then
    raise exception 'SAAS-9D-5A-3 preflight failed: SECURITY DEFINER baseline differs.';
  end if;
end;
$preflight$;

-- Existing tenant-aware writers now bind the already-authorized tenant to the
-- profile trigger. The trigger never derives a tenant from global state.
do $patch_writers$
declare v_definition text;
begin
  v_definition:=pg_catalog.pg_get_functiondef(
    'public.update_tenant_profile_identity_v2(uuid,uuid,text,text)'::regprocedure);
  v_definition:=pg_catalog.replace(v_definition,
    'perform pg_catalog.set_config(''csk.profile_identity_rpc_target'',p_target_user_id::text,true);',
    'perform pg_catalog.set_config(''csk.profile_identity_rpc_target'',p_target_user_id::text,true);'||E'\n  '||
    'perform pg_catalog.set_config(''csk.profile_identity_rpc_tenant'',v_tenant_id::text,true);');
  v_definition:=pg_catalog.replace(v_definition,
    'perform pg_catalog.set_config(''csk.profile_identity_rpc_target'','''',true);',
    'perform pg_catalog.set_config(''csk.profile_identity_rpc_target'','''',true);'||E'\n  '||
    'perform pg_catalog.set_config(''csk.profile_identity_rpc_tenant'','''',true);');
  if pg_catalog.strpos(v_definition,'csk.profile_identity_rpc_tenant')=0 then
    raise exception 'SAAS-9D-5A-3 failed to bind identity writer tenant context.';
  end if;
  execute v_definition;

  v_definition:=pg_catalog.pg_get_functiondef(
    'public.update_profile_identity(uuid,text,text)'::regprocedure);
  v_definition:=pg_catalog.replace(v_definition,
    'perform pg_catalog.set_config(''csk.profile_identity_rpc_target'',p_target_user_id::text,true);',
    'perform pg_catalog.set_config(''csk.profile_identity_rpc_target'',p_target_user_id::text,true);'||E'\n  '||
    'perform pg_catalog.set_config(''csk.profile_identity_rpc_tenant'',v_tenant_id::text,true);');
  v_definition:=pg_catalog.replace(v_definition,
    'perform pg_catalog.set_config(''csk.profile_identity_rpc_target'','''',true);',
    'perform pg_catalog.set_config(''csk.profile_identity_rpc_target'','''',true);'||E'\n  '||
    'perform pg_catalog.set_config(''csk.profile_identity_rpc_tenant'','''',true);');
  if pg_catalog.strpos(v_definition,'csk.profile_identity_rpc_tenant')=0 then
    raise exception 'SAAS-9D-5A-3 failed to bind legacy identity writer tenant context.';
  end if;
  execute v_definition;

  v_definition:=pg_catalog.pg_get_functiondef(
    'public.update_tenant_profile_contact_details_v2(uuid,uuid,text,text,text,text,text,text)'::regprocedure);
  v_definition:=pg_catalog.replace(v_definition,
    'perform pg_catalog.set_config(''csk.profile_contact_rpc_target'',p_target_user_id::text,true);',
    'perform pg_catalog.set_config(''csk.profile_contact_rpc_target'',p_target_user_id::text,true);'||E'\n  '||
    'perform pg_catalog.set_config(''csk.profile_contact_rpc_tenant'',v_tenant_id::text,true);');
  v_definition:=pg_catalog.replace(v_definition,
    'perform pg_catalog.set_config(''csk.profile_contact_rpc_target'','''',true);',
    'perform pg_catalog.set_config(''csk.profile_contact_rpc_target'','''',true);'||E'\n  '||
    'perform pg_catalog.set_config(''csk.profile_contact_rpc_tenant'','''',true);');
  if pg_catalog.strpos(v_definition,'csk.profile_contact_rpc_tenant')=0 then
    raise exception 'SAAS-9D-5A-3 failed to bind contact writer tenant context.';
  end if;
  execute v_definition;

  v_definition:=pg_catalog.pg_get_functiondef(
    'public.update_profile_contact_details(uuid,text,text,text,text,text,text)'::regprocedure);
  v_definition:=pg_catalog.replace(v_definition,
    'perform pg_catalog.set_config(''csk.profile_contact_rpc_target'',p_target_user_id::text,true);',
    'perform pg_catalog.set_config(''csk.profile_contact_rpc_target'',p_target_user_id::text,true);'||E'\n  '||
    'perform pg_catalog.set_config(''csk.profile_contact_rpc_tenant'',v_tenant_id::text,true);');
  v_definition:=pg_catalog.replace(v_definition,
    'perform pg_catalog.set_config(''csk.profile_contact_rpc_target'','''',true);',
    'perform pg_catalog.set_config(''csk.profile_contact_rpc_target'','''',true);'||E'\n  '||
    'perform pg_catalog.set_config(''csk.profile_contact_rpc_tenant'','''',true);');
  if pg_catalog.strpos(v_definition,'csk.profile_contact_rpc_tenant')=0 then
    raise exception 'SAAS-9D-5A-3 failed to bind legacy contact writer tenant context.';
  end if;
  execute v_definition;
end;
$patch_writers$;

drop trigger sync_profile_role_to_csk_membership on public.profiles;
drop trigger sync_csk_membership_role_to_profile on public.tenant_memberships;
drop function public.sync_profile_role_to_csk_membership();
drop function public.sync_csk_membership_role_to_profile();

create or replace function public.prevent_non_admin_profile_privilege_changes()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $function$
declare
  v_actor_id uuid:=auth.uid();
  v_tenant_id uuid;
  v_context_tenant text;
  v_actor_tenant_role text;
  v_target_tenant_role text;
  v_role_changed boolean:=old.role is distinct from new.role;
  v_note_changed boolean:=old.admin_note is distinct from new.admin_note;
  v_identity_changed boolean:=old.first_name is distinct from new.first_name
    or old.last_name is distinct from new.last_name
    or old.full_name is distinct from new.full_name;
  v_legacy_verification_changed boolean:=
    old.verification_status is distinct from new.verification_status
    or old.verification_note is distinct from new.verification_note
    or old.verified_at is distinct from new.verified_at
    or old.verified_by is distinct from new.verified_by
    or old.unverified_at is distinct from new.unverified_at
    or old.unverified_by is distinct from new.unverified_by
    or old.permissions_verified is distinct from new.permissions_verified
    or old.permissions_verified_at is distinct from new.permissions_verified_at
    or old.permissions_verified_by is distinct from new.permissions_verified_by
    or old.permissions_verification_note is distinct from new.permissions_verification_note;
  v_target_related boolean:=false;
begin
  if v_actor_id is null then
    if session_user='postgres'
       and coalesce(pg_catalog.current_setting('role',true),'none') in('none','postgres') then
      return new;
    end if;
    raise exception 'Aktualizacja profilu bez kontekstu użytkownika jest niedozwolona.' using errcode='42501';
  end if;

  if v_role_changed then
    raise exception 'Legacy global role is frozen and system-only.' using errcode='42501';
  end if;
  if v_note_changed then
    raise exception 'Legacy global admin note is frozen.' using errcode='42501';
  end if;
  if v_legacy_verification_changed then
    raise exception 'Legacy global verification fields are frozen.' using errcode='42501';
  end if;

  if v_identity_changed then
    v_context_tenant:=pg_catalog.current_setting('csk.profile_identity_rpc_tenant',true);
    if v_context_tenant is null or v_context_tenant!~*'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      raise exception 'Brak jawnego kontekstu tenantowego korekty tożsamości.' using errcode='42501';
    end if;
    v_tenant_id:=v_context_tenant::uuid;
    if pg_catalog.current_setting('csk.profile_identity_rpc_actor',true) is distinct from v_actor_id::text
       or pg_catalog.current_setting('csk.profile_identity_rpc_target',true) is distinct from old.user_id::text
       or public.get_my_tenant_role_v1(v_tenant_id) is distinct from 'admin' then
      raise exception 'Dane tożsamości można zmieniać wyłącznie przez kontrolowaną operację tenantową.' using errcode='42501';
    end if;
    select exists(
      select 1 from public.tenant_memberships m where m.tenant_id=v_tenant_id and m.user_id=old.user_id
      union all select 1 from public.reservations r where r.tenant_id=v_tenant_id and r.user_id=old.user_id
      union all select 1 from public.event_registrations er join public.events e
        on e.id=er.event_id and e.tenant_id=er.tenant_id
        where er.tenant_id=v_tenant_id and er.user_id=old.user_id
    ) into v_target_related;
    if not v_target_related
       or (pg_catalog.to_jsonb(new)-array['first_name','last_name','full_name','updated_at'])
          is distinct from (pg_catalog.to_jsonb(old)-array['first_name','last_name','full_name','updated_at']) then
      raise exception 'Kontrolowana korekta tożsamości narusza tenant lub zakres pól.' using errcode='42501';
    end if;
    return new;
  end if;

  if old.user_id is distinct from v_actor_id then
    v_context_tenant:=pg_catalog.current_setting('csk.profile_contact_rpc_tenant',true);
    if v_context_tenant is null or v_context_tenant!~*'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      raise exception 'Brak jawnego kontekstu tenantowego aktualizacji profilu.' using errcode='42501';
    end if;
    v_tenant_id:=v_context_tenant::uuid;
    if pg_catalog.current_setting('csk.profile_contact_rpc_actor',true) is distinct from v_actor_id::text
       or pg_catalog.current_setting('csk.profile_contact_rpc_target',true) is distinct from old.user_id::text then
      raise exception 'Cudzy profil można zmieniać wyłącznie przez kontrolowaną operację tenantową.' using errcode='42501';
    end if;
    v_actor_tenant_role:=public.get_my_tenant_role_v1(v_tenant_id);
    if v_actor_tenant_role not in('admin','employee') then
      raise exception 'Brak aktywnego członkostwa tenantowego do aktualizacji profilu.' using errcode='42501';
    end if;
    select m.role into v_target_tenant_role from public.tenant_memberships m
      where m.tenant_id=v_tenant_id and m.user_id=old.user_id;
    select exists(
      select 1 from public.tenant_memberships m where m.tenant_id=v_tenant_id and m.user_id=old.user_id
      union all select 1 from public.reservations r where r.tenant_id=v_tenant_id and r.user_id=old.user_id
      union all select 1 from public.event_registrations er join public.events e
        on e.id=er.event_id and e.tenant_id=er.tenant_id
        where er.tenant_id=v_tenant_id and er.user_id=old.user_id
    ) into v_target_related;
    if not v_target_related
       or (v_actor_tenant_role='employee' and v_target_tenant_role in('admin','employee','instructor'))
       or (pg_catalog.to_jsonb(new)-array['phone','postal_code','city','street','house_number','apartment_number','updated_at'])
          is distinct from (pg_catalog.to_jsonb(old)-array['phone','postal_code','city','street','house_number','apartment_number','updated_at']) then
      raise exception 'Kontrolowana aktualizacja kontaktu narusza tenant, rolę docelową lub zakres pól.' using errcode='42501';
    end if;
    return new;
  end if;

  if (pg_catalog.to_jsonb(new)-array[
       'phone','postal_code','city','street','house_number','apartment_number',
       'permission_sport','permission_collector','permission_hunting','permission_training',
       'permission_personal_protection','permission_other','qualification_instructor',
       'qualification_range_officer','qualification_pzss_license','qualification_hunter','updated_at'
     ]) is distinct from (pg_catalog.to_jsonb(old)-array[
       'phone','postal_code','city','street','house_number','apartment_number',
       'permission_sport','permission_collector','permission_hunting','permission_training',
       'permission_personal_protection','permission_other','qualification_instructor',
       'qualification_range_officer','qualification_pzss_license','qualification_hunter','updated_at'
     ]) then
    raise exception 'Samoobsługa profilu narusza zatwierdzony zakres pól.' using errcode='42501';
  end if;
  return new;
end;
$function$;

alter function public.prevent_non_admin_profile_privilege_changes() owner to postgres;
revoke all on function public.prevent_non_admin_profile_privilege_changes() from public,anon,authenticated,service_role;
comment on function public.prevent_non_admin_profile_privilege_changes() is
  'Fail-closed global profile UPDATE guard. Role and legacy tenant fields are frozen; controlled foreign writes require an explicit tenant-bound writer context.';

do $postflight$
declare v_guard oid:='public.prevent_non_admin_profile_privilege_changes()'::regprocedure;
begin
  if pg_catalog.to_regprocedure('public.sync_profile_role_to_csk_membership()') is not null
     or pg_catalog.to_regprocedure('public.sync_csk_membership_role_to_profile()') is not null
     or exists(select 1 from pg_catalog.pg_trigger where not tgisinternal
       and tgname in('sync_profile_role_to_csk_membership','sync_csk_membership_role_to_profile')) then
    raise exception 'SAAS-9D-5A-3 postflight failed: legacy role sync remains.';
  end if;
  if (select pg_catalog.count(*) from pg_catalog.pg_trigger
      where not tgisinternal and tgrelid='auth.users'::regclass
        and tgfoid='public.handle_new_user()'::regprocedure
        and tgname='on_auth_user_created'
        and tgenabled='O' and tgtype=5 and tgqual is null)<>1 then
    raise exception 'SAAS-9D-5A-3 postflight failed: global profile creation trigger differs.';
  end if;
  if pg_catalog.md5(pg_catalog.regexp_replace(
       (select p.prosrc from pg_catalog.pg_proc p
        where p.oid='public.handle_new_user()'::regprocedure),
       '[[:space:]]+',' ','g'))<>'1de0460e8b4298219dd8be7d953bb0f5'
     or pg_catalog.strpos((select p.prosrc from pg_catalog.pg_proc p
       where p.oid='public.handle_new_user()'::regprocedure),'tenant_memberships')>0 then
    raise exception 'SAAS-9D-5A-3 postflight failed: global profile function differs.';
  end if;
  if (select pg_catalog.strpos(p.prosrc,'active_single_tenant_id_v1') from pg_catalog.pg_proc p where p.oid=v_guard)<>0
     or (select pg_catalog.strpos(p.prosrc,'profile_role_rpc') from pg_catalog.pg_proc p where p.oid=v_guard)<>0 then
    raise exception 'SAAS-9D-5A-3 postflight failed: profile guard retains legacy tenant/role bridge.';
  end if;
  if not exists(select 1 from pg_catalog.pg_proc p where p.oid=v_guard and p.prosecdef
      and pg_catalog.pg_get_userbyid(p.proowner)='postgres'
      and p.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[]) then
    raise exception 'SAAS-9D-5A-3 postflight failed: profile guard metadata differs.';
  end if;
  if pg_catalog.strpos((select p.prosrc from pg_catalog.pg_proc p where p.oid=
       'public.update_tenant_profile_identity_v2(uuid,uuid,text,text)'::regprocedure),'csk.profile_identity_rpc_tenant')=0
     or pg_catalog.strpos((select p.prosrc from pg_catalog.pg_proc p where p.oid=
       'public.update_tenant_profile_contact_details_v2(uuid,uuid,text,text,text,text,text,text)'::regprocedure),'csk.profile_contact_rpc_tenant')=0
     or pg_catalog.strpos((select p.prosrc from pg_catalog.pg_proc p where p.oid=
       'public.update_profile_identity(uuid,text,text)'::regprocedure),'csk.profile_identity_rpc_tenant')=0
     or pg_catalog.strpos((select p.prosrc from pg_catalog.pg_proc p where p.oid=
       'public.update_profile_contact_details(uuid,text,text,text,text,text,text)'::regprocedure),'csk.profile_contact_rpc_tenant')=0 then
    raise exception 'SAAS-9D-5A-3 postflight failed: controlled writer tenant binding is absent.';
  end if;
  if (select pg_catalog.count(*) from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.prosecdef)<>95 then
    raise exception 'SAAS-9D-5A-3 postflight failed: SECURITY DEFINER count differs.';
  end if;
end;
$postflight$;

commit;
