begin;

do $preflight$
declare
  v_trigger_oid oid := pg_catalog.to_regprocedure('public.prevent_non_admin_profile_privilege_changes()');
begin
  if v_trigger_oid is null
     or pg_catalog.to_regprocedure('public.active_single_tenant_id_v1()') is null
     or pg_catalog.to_regprocedure('public.get_my_tenant_role_v1(uuid)') is null
     or pg_catalog.to_regprocedure('public.legacy_profile_role_to_tenant_role_v1(text)') is null then
    raise exception 'SAAS-9D-4D-1 dependencies are missing.';
  end if;

  if pg_catalog.md5(
       pg_catalog.replace(
         pg_catalog.replace(pg_catalog.pg_get_functiondef(v_trigger_oid), E'\r\n', E'\n'),
         E'\r', E'\n'
       )
     ) <> 'd28cb697d8355a5e8005296a03ad63ea' then
    raise exception 'prevent_non_admin_profile_privilege_changes input fingerprint drifted.';
  end if;

  if not exists (
       select 1
       from pg_catalog.pg_proc procedure_record
       where procedure_record.oid = v_trigger_oid
         and procedure_record.prosecdef
         and pg_catalog.pg_get_userbyid(procedure_record.proowner) = 'postgres'
         and procedure_record.proconfig = array['search_path=pg_catalog, public, pg_temp']::text[]
     )
     or pg_catalog.has_function_privilege('public', v_trigger_oid, 'EXECUTE')
     or pg_catalog.has_function_privilege('anon', v_trigger_oid, 'EXECUTE')
     or pg_catalog.has_function_privilege('authenticated', v_trigger_oid, 'EXECUTE')
     or pg_catalog.has_function_privilege('service_role', v_trigger_oid, 'EXECUTE') then
    raise exception 'Profile privilege trigger metadata or ACL drifted.';
  end if;

  if (
       select pg_catalog.count(*)
       from pg_catalog.pg_trigger trigger_record
       where trigger_record.tgrelid = 'public.profiles'::pg_catalog.regclass
         and trigger_record.tgfoid = v_trigger_oid
         and not trigger_record.tgisinternal
         and trigger_record.tgname = 'prevent_non_admin_profile_privilege_changes_trigger'
     ) <> 1 then
    raise exception 'Expected profile privilege trigger binding is missing or duplicated.';
  end if;

  if exists (
       select 1
       from (
         values
           ('public.update_my_profile_v1(text,text,text,text,text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean)'::pg_catalog.regprocedure, 'eed0787e7c5a67e537b5703289abf536'),
           ('public.admin_set_user_role_v1(uuid,text)'::pg_catalog.regprocedure, '9732b7d53eaa080ebc6348cd1dd68ca2'),
           ('public.update_profile_identity(uuid,text,text)'::pg_catalog.regprocedure, '33e0a05fb0d142cd9ba7d99cc66c6652'),
           ('public.update_profile_contact_details(uuid,text,text,text,text,text,text)'::pg_catalog.regprocedure, 'ce0146bccc9a1cc1d89c3e4d26462586'),
           ('public.sync_csk_membership_role_to_profile()'::pg_catalog.regprocedure, 'd7075b43007466d1a6deb59c590f026d')
       ) expected(function_oid, normalized_md5)
       where pg_catalog.md5(
         pg_catalog.replace(
           pg_catalog.replace(pg_catalog.pg_get_functiondef(expected.function_oid), E'\r\n', E'\n'),
           E'\r', E'\n'
         )
       ) <> expected.normalized_md5
     ) then
    raise exception 'Approved profile writer fingerprint drifted.';
  end if;
end;
$preflight$;

create or replace function public.prevent_non_admin_profile_privilege_changes()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $function$
declare
  v_actor_id uuid := auth.uid();
  v_tenant_id uuid;
  v_actor_tenant_role text;
  v_target_tenant_role text;
  v_expected_tenant_role text;
  v_role_changed boolean := old.role is distinct from new.role;
  v_note_changed boolean := old.admin_note is distinct from new.admin_note;
  v_identity_changed boolean := old.first_name is distinct from new.first_name
    or old.last_name is distinct from new.last_name
    or old.full_name is distinct from new.full_name;
  v_legacy_verification_changed boolean :=
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
  v_target_related boolean := false;
begin
  -- SQL migrations and owner-operated maintenance are the only auth-less
  -- profile UPDATE path. PostgREST service_role runs under SET ROLE and is not
  -- covered by this exception.
  if v_actor_id is null then
    if session_user = 'postgres'
       and coalesce(pg_catalog.current_setting('role', true), 'none') in ('none', 'postgres') then
      return new;
    end if;
    raise exception 'Aktualizacja profilu bez kontekstu użytkownika jest niedozwolona.'
      using errcode = '42501';
  end if;

  v_tenant_id := public.active_single_tenant_id_v1();

  if v_role_changed then
    if v_tenant_id is null
       or pg_catalog.current_setting('csk.profile_role_rpc_actor', true) is distinct from v_actor_id::text
       or pg_catalog.current_setting('csk.profile_role_rpc_target', true) is distinct from old.user_id::text
       or public.get_my_tenant_role_v1(v_tenant_id) is distinct from 'admin' then
      raise exception 'Rolę profilu można zmieniać wyłącznie jako kontrolowane lustro roli tenantowej.'
        using errcode = '42501';
    end if;

    v_expected_tenant_role := public.legacy_profile_role_to_tenant_role_v1(new.role);
    select membership.role
      into v_target_tenant_role
    from public.tenant_memberships membership
    where membership.tenant_id = v_tenant_id
      and membership.user_id = old.user_id;

    if v_expected_tenant_role is null
       or v_target_tenant_role is distinct from v_expected_tenant_role then
      raise exception 'Legacy role does not match the authoritative tenant membership.'
        using errcode = '42501';
    end if;

    if (pg_catalog.to_jsonb(new) - array['role', 'updated_at'])
       is distinct from (pg_catalog.to_jsonb(old) - array['role', 'updated_at']) then
      raise exception 'Kontrolowane lustro roli może zmieniać wyłącznie rolę i czas aktualizacji.'
        using errcode = '42501';
    end if;
    return new;
  end if;

  -- The operational note moved to tenant_user_admin_notes. The legacy global
  -- column is frozen and is never a tenant-owned write target.
  if v_note_changed then
    raise exception 'Legacy global admin note is frozen.' using errcode = '42501';
  end if;

  if v_identity_changed then
    if v_tenant_id is null
       or pg_catalog.current_setting('csk.profile_identity_rpc_actor', true) is distinct from v_actor_id::text
       or pg_catalog.current_setting('csk.profile_identity_rpc_target', true) is distinct from old.user_id::text
       or public.get_my_tenant_role_v1(v_tenant_id) is distinct from 'admin' then
      raise exception 'Dane tożsamości można zmieniać wyłącznie przez kontrolowaną operację tenantową.'
        using errcode = '42501';
    end if;

    select exists (
      select 1 from public.tenant_memberships membership
      where membership.tenant_id = v_tenant_id and membership.user_id = old.user_id
      union all
      select 1 from public.reservations reservation
      where reservation.tenant_id = v_tenant_id and reservation.user_id = old.user_id
      union all
      select 1
      from public.event_registrations registration
      join public.events event_record
        on event_record.id = registration.event_id
       and event_record.tenant_id = registration.tenant_id
      where registration.tenant_id = v_tenant_id and registration.user_id = old.user_id
    ) into v_target_related;

    if not v_target_related
       or (pg_catalog.to_jsonb(new) - array['first_name', 'last_name', 'full_name', 'updated_at'])
          is distinct from (pg_catalog.to_jsonb(old) - array['first_name', 'last_name', 'full_name', 'updated_at']) then
      raise exception 'Kontrolowana korekta tożsamości narusza tenant lub zakres pól.'
        using errcode = '42501';
    end if;
    return new;
  end if;

  if v_legacy_verification_changed then
    raise exception 'Legacy global verification fields are frozen.' using errcode = '42501';
  end if;

  -- Foreign contact writes are allowed only through the already hardened
  -- tenant-aware writer and are independently re-bound to its relationship.
  if old.user_id is distinct from v_actor_id then
    if v_tenant_id is null
       or pg_catalog.current_setting('csk.profile_contact_rpc_actor', true) is distinct from v_actor_id::text
       or pg_catalog.current_setting('csk.profile_contact_rpc_target', true) is distinct from old.user_id::text then
      raise exception 'Cudzy profil można zmieniać wyłącznie przez kontrolowaną operację tenantową.'
        using errcode = '42501';
    end if;

    v_actor_tenant_role := public.get_my_tenant_role_v1(v_tenant_id);
    if v_actor_tenant_role not in ('admin', 'employee') then
      raise exception 'Brak aktywnego członkostwa tenantowego do aktualizacji profilu.'
        using errcode = '42501';
    end if;

    select membership.role
      into v_target_tenant_role
    from public.tenant_memberships membership
    where membership.tenant_id = v_tenant_id
      and membership.user_id = old.user_id;

    select exists (
      select 1 from public.tenant_memberships membership
      where membership.tenant_id = v_tenant_id and membership.user_id = old.user_id
      union all
      select 1 from public.reservations reservation
      where reservation.tenant_id = v_tenant_id and reservation.user_id = old.user_id
      union all
      select 1
      from public.event_registrations registration
      join public.events event_record
        on event_record.id = registration.event_id
       and event_record.tenant_id = registration.tenant_id
      where registration.tenant_id = v_tenant_id and registration.user_id = old.user_id
    ) into v_target_related;

    if not v_target_related
       or (v_actor_tenant_role = 'employee' and v_target_tenant_role in ('admin', 'employee', 'instructor'))
       or (pg_catalog.to_jsonb(new) - array[
            'phone', 'postal_code', 'city', 'street', 'house_number',
            'apartment_number', 'updated_at'
          ]) is distinct from (pg_catalog.to_jsonb(old) - array[
            'phone', 'postal_code', 'city', 'street', 'house_number',
            'apartment_number', 'updated_at'
          ]) then
      raise exception 'Kontrolowana aktualizacja kontaktu narusza tenant, rolę docelową lub zakres pól.'
        using errcode = '42501';
    end if;
    return new;
  end if;

  -- Owner self-service is an explicit allowlist. Legacy privilege and
  -- verification columns are never reset or mirrored here.
  if (pg_catalog.to_jsonb(new) - array[
       'phone', 'postal_code', 'city', 'street', 'house_number',
       'apartment_number', 'permission_sport', 'permission_collector',
       'permission_hunting', 'permission_training',
       'permission_personal_protection', 'permission_other',
       'qualification_instructor', 'qualification_range_officer',
       'qualification_pzss_license', 'qualification_hunter', 'updated_at'
     ]) is distinct from (pg_catalog.to_jsonb(old) - array[
       'phone', 'postal_code', 'city', 'street', 'house_number',
       'apartment_number', 'permission_sport', 'permission_collector',
       'permission_hunting', 'permission_training',
       'permission_personal_protection', 'permission_other',
       'qualification_instructor', 'qualification_range_officer',
       'qualification_pzss_license', 'qualification_hunter', 'updated_at'
     ]) then
    raise exception 'Samoobsługa profilu narusza zatwierdzony zakres pól.'
      using errcode = '42501';
  end if;

  return new;
end;
$function$;

alter function public.prevent_non_admin_profile_privilege_changes() owner to postgres;
revoke all on function public.prevent_non_admin_profile_privilege_changes()
  from public, anon, authenticated, service_role;

comment on function public.prevent_non_admin_profile_privilege_changes() is
  'Fail-closed profile UPDATE guard. Tenant authority comes from active memberships and controlled writer context; profiles.role is compatibility data only.';

do $postflight$
declare
  v_trigger_oid oid := 'public.prevent_non_admin_profile_privilege_changes()'::pg_catalog.regprocedure;
begin
  if not exists (
       select 1
       from pg_catalog.pg_proc procedure_record
       where procedure_record.oid = v_trigger_oid
         and procedure_record.prosecdef
         and pg_catalog.pg_get_userbyid(procedure_record.proowner) = 'postgres'
         and procedure_record.proconfig = array['search_path=pg_catalog, public, pg_temp']::text[]
         and pg_catalog.strpos(procedure_record.prosrc, 'public.is_admin') = 0
         and procedure_record.prosrc !~ 'profile[.]role'
     ) then
    raise exception 'Hardened profile privilege trigger metadata or authority model differs.';
  end if;

  if pg_catalog.has_function_privilege('public', v_trigger_oid, 'EXECUTE')
     or pg_catalog.has_function_privilege('anon', v_trigger_oid, 'EXECUTE')
     or pg_catalog.has_function_privilege('authenticated', v_trigger_oid, 'EXECUTE')
     or pg_catalog.has_function_privilege('service_role', v_trigger_oid, 'EXECUTE') then
    raise exception 'Profile privilege trigger EXECUTE ACL widened.';
  end if;

  if (
       select pg_catalog.count(*)
       from pg_catalog.pg_proc procedure_record
       join pg_catalog.pg_namespace namespace_record
         on namespace_record.oid = procedure_record.pronamespace
       where namespace_record.nspname = 'public' and procedure_record.prosecdef
     ) <> 69 then
    raise exception 'SECURITY DEFINER count drifted.';
  end if;

  if (
       select pg_catalog.count(*)
       from information_schema.columns
       where table_schema = 'public'
         and table_name in (
           'shooting_lanes', 'reservations', 'lane_blocks', 'events',
           'event_lanes', 'event_registrations', 'email_deliveries'
         )
         and column_name = 'tenant_id'
         and column_default = '''c5c00000-0000-4000-8000-000000000001''::uuid'
     ) <> 7 then
    raise exception 'Compatibility defaults drifted.';
  end if;
end;
$postflight$;

commit;
