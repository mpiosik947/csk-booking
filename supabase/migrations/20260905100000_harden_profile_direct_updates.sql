-- CLEAN-005: remove broad client UPDATE access to profiles and preserve
-- self-service through one allowlisted, auth.uid()-scoped writer.

do $preflight$
begin
  if pg_catalog.to_regclass('public.profiles') is null
     or not exists (
       select 1 from pg_catalog.pg_class as relation
       join pg_catalog.pg_roles as owner_role on owner_role.oid = relation.relowner
       where relation.oid = 'public.profiles'::pg_catalog.regclass
         and relation.relrowsecurity
         and owner_role.rolname = 'postgres'
     ) then
    raise exception 'CLEAN-005 preflight failed: profiles table contract differs.';
  end if;

  if not pg_catalog.has_table_privilege('authenticated', 'public.profiles', 'SELECT,INSERT,UPDATE')
     or pg_catalog.has_table_privilege('authenticated', 'public.profiles', 'DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN')
     or pg_catalog.has_table_privilege('anon', 'public.profiles', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN') then
    raise exception 'CLEAN-005 preflight failed: profiles client ACL differs.';
  end if;

  if (select pg_catalog.count(*) from pg_catalog.pg_policies
      where schemaname = 'public' and tablename = 'profiles' and cmd = 'UPDATE') <> 2
     or not exists (
       select 1 from pg_catalog.pg_policies
       where schemaname = 'public' and tablename = 'profiles'
         and policyname = 'Admins can update all profiles' and cmd = 'UPDATE'
         and roles = array['authenticated']::name[]
         and qual = 'is_admin()' and with_check = 'is_admin()'
     )
     or not exists (
       select 1 from pg_catalog.pg_policies
       where schemaname = 'public' and tablename = 'profiles'
         and policyname = 'Users can update own basic profile' and cmd = 'UPDATE'
         and roles = array['authenticated']::name[]
         and qual = '(user_id = auth.uid())'
         and with_check = '(user_id = auth.uid())'
     ) then
    raise exception 'CLEAN-005 preflight failed: profiles UPDATE policies differ.';
  end if;

  if pg_catalog.to_regprocedure('public.update_my_profile_v1(text,text,text,text,text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean)') is not null then
    raise exception 'CLEAN-005 preflight failed: target self-service RPC already exists.';
  end if;

  if pg_catalog.to_regprocedure('public.admin_set_user_role_v1(uuid,text)') is null
     or pg_catalog.to_regprocedure('public.admin_set_user_note_v1(uuid,text)') is null
     or pg_catalog.to_regprocedure('public.update_profile_verification(uuid,text,text)') is null
     or pg_catalog.to_regprocedure('public.update_profile_identity(uuid,text,text)') is null
     or pg_catalog.to_regprocedure('public.update_profile_contact_details(uuid,text,text,text,text,text,text)') is null
     or pg_catalog.to_regprocedure('public.anonymize_my_account_v1()') is null then
    raise exception 'CLEAN-005 preflight failed: controlled profile writer is missing.';
  end if;
end;
$preflight$;

create function public.update_my_profile_v1(
  p_phone text,
  p_postal_code text,
  p_city text,
  p_street text,
  p_house_number text,
  p_apartment_number text,
  p_permission_sport boolean,
  p_permission_collector boolean,
  p_permission_hunting boolean,
  p_permission_training boolean,
  p_permission_personal_protection boolean,
  p_permission_other boolean,
  p_qualification_instructor boolean,
  p_qualification_range_officer boolean,
  p_qualification_pzss_license boolean,
  p_qualification_hunter boolean
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, public, pg_temp
as $function$
declare
  v_user_id uuid := auth.uid();
  v_profile public.profiles%rowtype;
  v_updated public.profiles%rowtype;
  v_phone text := pg_catalog.btrim(coalesce(p_phone, ''));
  v_postal_code text := pg_catalog.btrim(coalesce(p_postal_code, ''));
  v_city text := pg_catalog.btrim(coalesce(p_city, ''));
  v_street text := pg_catalog.btrim(coalesce(p_street, ''));
  v_house_number text := pg_catalog.btrim(coalesce(p_house_number, ''));
  v_apartment_number text := nullif(pg_catalog.btrim(coalesce(p_apartment_number, '')), '');
  v_declarations_changed boolean;
  v_changed boolean;
begin
  if v_user_id is null then
    return pg_catalog.jsonb_build_object('ok', false, 'changed', false, 'code', 'not_allowed');
  end if;

  if p_permission_sport is null or p_permission_collector is null
     or p_permission_hunting is null or p_permission_training is null
     or p_permission_personal_protection is null or p_permission_other is null
     or p_qualification_instructor is null or p_qualification_range_officer is null
     or p_qualification_pzss_license is null or p_qualification_hunter is null
     or pg_catalog.length(v_phone) > 32
     or pg_catalog.length(v_postal_code) > 20
     or pg_catalog.length(v_city) > 120
     or pg_catalog.length(v_street) > 160
     or pg_catalog.length(v_house_number) > 30
     or pg_catalog.length(v_apartment_number) > 30 then
    return pg_catalog.jsonb_build_object('ok', false, 'changed', false, 'code', 'invalid_input');
  end if;

  select profile.* into v_profile
  from public.profiles as profile
  where profile.user_id = v_user_id
  for update;

  if not found then
    return pg_catalog.jsonb_build_object('ok', false, 'changed', false, 'code', 'profile_not_found');
  end if;

  v_declarations_changed :=
    v_profile.permission_sport is distinct from p_permission_sport
    or v_profile.permission_collector is distinct from p_permission_collector
    or v_profile.permission_hunting is distinct from p_permission_hunting
    or v_profile.permission_training is distinct from p_permission_training
    or v_profile.permission_personal_protection is distinct from p_permission_personal_protection
    or v_profile.permission_other is distinct from p_permission_other
    or v_profile.qualification_instructor is distinct from p_qualification_instructor
    or v_profile.qualification_range_officer is distinct from p_qualification_range_officer
    or v_profile.qualification_pzss_license is distinct from p_qualification_pzss_license
    or v_profile.qualification_hunter is distinct from p_qualification_hunter;

  v_changed := v_declarations_changed
    or v_profile.phone is distinct from v_phone
    or v_profile.postal_code is distinct from v_postal_code
    or v_profile.city is distinct from v_city
    or v_profile.street is distinct from v_street
    or v_profile.house_number is distinct from v_house_number
    or v_profile.apartment_number is distinct from v_apartment_number;

  if not v_changed then
    return pg_catalog.jsonb_build_object(
      'ok', true, 'changed', false, 'code', 'no_change',
      'verification_status', v_profile.verification_status,
      'permissions_verified', v_profile.permissions_verified,
      'permissions_verified_at', v_profile.permissions_verified_at,
      'updated_at', v_profile.updated_at
    );
  end if;

  if pg_catalog.lower(pg_catalog.btrim(v_profile.role::text)) = 'admin'
     and v_declarations_changed then
    update public.profiles as profile
    set phone = v_phone, postal_code = v_postal_code, city = v_city,
        street = v_street, house_number = v_house_number,
        apartment_number = v_apartment_number,
        permission_sport = p_permission_sport,
        permission_collector = p_permission_collector,
        permission_hunting = p_permission_hunting,
        permission_training = p_permission_training,
        permission_personal_protection = p_permission_personal_protection,
        permission_other = p_permission_other,
        qualification_instructor = p_qualification_instructor,
        qualification_range_officer = p_qualification_range_officer,
        qualification_pzss_license = p_qualification_pzss_license,
        qualification_hunter = p_qualification_hunter,
        verification_status = 'pending', permissions_verified = false,
        permissions_verified_at = null, permissions_verified_by = null,
        permissions_verification_note = null
    where profile.user_id = v_user_id
    returning profile.* into v_updated;
  else
    update public.profiles as profile
    set phone = v_phone, postal_code = v_postal_code, city = v_city,
        street = v_street, house_number = v_house_number,
        apartment_number = v_apartment_number,
        permission_sport = p_permission_sport,
        permission_collector = p_permission_collector,
        permission_hunting = p_permission_hunting,
        permission_training = p_permission_training,
        permission_personal_protection = p_permission_personal_protection,
        permission_other = p_permission_other,
        qualification_instructor = p_qualification_instructor,
        qualification_range_officer = p_qualification_range_officer,
        qualification_pzss_license = p_qualification_pzss_license,
        qualification_hunter = p_qualification_hunter
    where profile.user_id = v_user_id
    returning profile.* into v_updated;
  end if;

  return pg_catalog.jsonb_build_object(
    'ok', true, 'changed', true, 'code', 'updated',
    'declarations_changed', v_declarations_changed,
    'verification_status', v_updated.verification_status,
    'permissions_verified', v_updated.permissions_verified,
    'permissions_verified_at', v_updated.permissions_verified_at,
    'updated_at', v_updated.updated_at
  );
end;
$function$;

alter function public.update_my_profile_v1(text,text,text,text,text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean)
  owner to postgres;
revoke all on function public.update_my_profile_v1(text,text,text,text,text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean)
  from public, anon, authenticated, service_role;
grant execute on function public.update_my_profile_v1(text,text,text,text,text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean)
  to authenticated;

comment on function public.update_my_profile_v1(text,text,text,text,text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean) is
  'Allowlisted auth.uid()-scoped profile contact and declaration update; no privileged or identity fields.';

drop policy "Admins can update all profiles" on public.profiles;
drop policy "Users can update own basic profile" on public.profiles;
revoke update on table public.profiles from authenticated;

do $postflight$
declare
  v_rpc oid := pg_catalog.to_regprocedure('public.update_my_profile_v1(text,text,text,text,text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean)');
begin
  if v_rpc is null or not exists (
    select 1 from pg_catalog.pg_proc as procedure
    join pg_catalog.pg_roles as owner_role on owner_role.oid = procedure.proowner
    where procedure.oid = v_rpc and procedure.prosecdef
      and procedure.provolatile = 'v' and procedure.prorettype = 'jsonb'::pg_catalog.regtype
      and procedure.proconfig = array['search_path=pg_catalog, public, pg_temp']::text[]
      and owner_role.rolname = 'postgres'
  ) then
    raise exception 'CLEAN-005 postflight failed: self-service RPC properties differ.';
  end if;

  if not pg_catalog.has_function_privilege('authenticated', v_rpc, 'EXECUTE')
     or pg_catalog.has_function_privilege('anon', v_rpc, 'EXECUTE')
     or pg_catalog.has_function_privilege('service_role', v_rpc, 'EXECUTE')
     or exists (
       select 1 from pg_catalog.pg_proc as procedure
       cross join lateral pg_catalog.aclexplode(coalesce(procedure.proacl, pg_catalog.acldefault('f', procedure.proowner))) as acl
       where procedure.oid = v_rpc and acl.grantee = 0 and acl.privilege_type = 'EXECUTE'
     ) then
    raise exception 'CLEAN-005 postflight failed: self-service RPC ACL differs.';
  end if;

  if pg_catalog.has_table_privilege('authenticated', 'public.profiles', 'UPDATE')
     or exists (select 1 from pg_catalog.pg_policies where schemaname='public' and tablename='profiles' and cmd='UPDATE')
     or not pg_catalog.has_table_privilege('authenticated', 'public.profiles', 'SELECT,INSERT') then
    raise exception 'CLEAN-005 postflight failed: direct profile UPDATE remains reachable.';
  end if;
end;
$postflight$;
