-- SAAS-9D-4B-2C: close the legacy global tenant-verification projection.
-- The retained profiles verification columns are frozen historical data only.

do $preflight$
declare
  v_function regprocedure;
  v_expected text;
begin
  if (select pg_catalog.count(*) from pg_catalog.pg_proc procedure_record
      join pg_catalog.pg_namespace namespace_record on namespace_record.oid=procedure_record.pronamespace
      where namespace_record.nspname='public' and procedure_record.proname='_apply_tenant_user_verification_v1')<>1
     or (select pg_catalog.count(*) from pg_catalog.pg_proc procedure_record
      join pg_catalog.pg_namespace namespace_record on namespace_record.oid=procedure_record.pronamespace
      where namespace_record.nspname='public' and procedure_record.proname='update_profile_verification')<>1 then
    raise exception 'SAAS-9D-4B-2C preflight failed: target overload inventory differs.';
  end if;

  for v_function,v_expected in values
    ('public._apply_tenant_user_verification_v1(uuid,uuid,text,text,text,uuid)'::regprocedure,'1682c8e32403d21ca5b829b70c244da9'),
    ('public.update_profile_verification(uuid,text,text)'::regprocedure,'8df439041f082c25e18a632f952623cb'),
    ('public.prevent_non_admin_profile_privilege_changes()'::regprocedure,'d28cb697d8355a5e8005296a03ad63ea'),
    ('public.update_reservation_customer_verification_v1(uuid,text,text)'::regprocedure,'b4916056e23c1043baf17cbdab55caeb'),
    ('public.get_my_active_tenant_verification_v1()'::regprocedure,'951c8262bc118089d8398282e1a95ce8'),
    ('public.admin_list_users_v1(integer,integer,text,text,text,text)'::regprocedure,'bf37ec48de512ea45f5d4592df5f4eac'),
    ('public.get_reservation_customer_profiles_v1(uuid[])'::regprocedure,'3f9ff02e63286a2784891ce4bb75c613'),
    ('public.update_my_profile_v1(text,text,text,text,text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean)'::regprocedure,'c8c882630f05763f745788e9a108fb65'),
    ('public.export_my_data_v1()'::regprocedure,'ffa6b35c5502a347e463110401032061'),
    ('public.anonymize_my_account_v1()'::regprocedure,'7e4d950e75e6e5782b139f11269d03a0')
  loop
    if pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef(v_function),pg_catalog.chr(13)||pg_catalog.chr(10),pg_catalog.chr(10)),pg_catalog.chr(13),pg_catalog.chr(10)))<>v_expected then
      raise exception 'SAAS-9D-4B-2C preflight failed: normalized fingerprint differs for %.',v_function;
    end if;
  end loop;

  if (select pg_catalog.count(*) from pg_catalog.pg_proc procedure_record
      join pg_catalog.pg_namespace namespace_record on namespace_record.oid=procedure_record.pronamespace
      where namespace_record.nspname='public' and procedure_record.prosecdef)<>69 then
    raise exception 'SAAS-9D-4B-2C preflight failed: SECURITY DEFINER baseline differs.';
  end if;

  if (select pg_catalog.count(*) from information_schema.columns
      where table_schema='public'
        and table_name in('shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','email_deliveries')
        and column_name='tenant_id'
        and column_default='''c5c00000-0000-4000-8000-000000000001''::uuid')<>7 then
    raise exception 'SAAS-9D-4B-2C preflight failed: compatibility defaults differ.';
  end if;

  if not pg_catalog.has_function_privilege('authenticated','public.update_profile_verification(uuid,text,text)','EXECUTE')
     or pg_catalog.has_function_privilege('public','public.update_profile_verification(uuid,text,text)','EXECUTE')
     or pg_catalog.has_function_privilege('anon','public.update_profile_verification(uuid,text,text)','EXECUTE')
     or pg_catalog.has_function_privilege('service_role','public.update_profile_verification(uuid,text,text)','EXECUTE')
     or pg_catalog.has_function_privilege('public','public._apply_tenant_user_verification_v1(uuid,uuid,text,text,text,uuid)','EXECUTE')
     or pg_catalog.has_function_privilege('anon','public._apply_tenant_user_verification_v1(uuid,uuid,text,text,text,uuid)','EXECUTE')
     or pg_catalog.has_function_privilege('authenticated','public._apply_tenant_user_verification_v1(uuid,uuid,text,text,text,uuid)','EXECUTE')
     or pg_catalog.has_function_privilege('service_role','public._apply_tenant_user_verification_v1(uuid,uuid,text,text,text,uuid)','EXECUTE') then
    raise exception 'SAAS-9D-4B-2C preflight failed: target ACL differs.';
  end if;
end;
$preflight$;

create or replace function public._apply_tenant_user_verification_v1(
  p_tenant_id uuid,p_target_user_id uuid,p_action text,p_note text,
  p_resource_type text,p_resource_id uuid
) returns jsonb
language plpgsql security invoker
set search_path=pg_catalog,public,pg_temp
as $function$
declare
  v_actor_id uuid:=auth.uid();
  v_actor_role text;
  v_action text:=pg_catalog.lower(pg_catalog.btrim(coalesce(p_action,'')));
  v_note text:=nullif(pg_catalog.btrim(coalesce(p_note,'')),'');
  v_old public.tenant_user_verifications%rowtype;
  v_updated public.tenant_user_verifications%rowtype;
  v_status text;
  v_permissions boolean;
  v_now timestamptz:=pg_catalog.transaction_timestamp();
  v_audit_action text;
begin
  if v_actor_id is null or p_tenant_id is null or p_target_user_id is null
     or v_action not in('verify','mark_pending','reject')
     or pg_catalog.char_length(v_note)>2000 then
    raise exception 'Nieprawidłowa operacja weryfikacyjna.' using errcode='22023';
  end if;
  select membership.role into v_actor_role
  from public.tenant_memberships membership
  join public.tenants tenant on tenant.id=membership.tenant_id and tenant.status='active'
  where membership.tenant_id=p_tenant_id and membership.user_id=v_actor_id and membership.status='active';
  if v_actor_role is null or v_actor_role not in('admin','employee') then
    raise exception 'Brak uprawnień do weryfikacji.' using errcode='42501';
  end if;

  insert into public.tenant_user_verifications(tenant_id,user_id)
  values(p_tenant_id,p_target_user_id) on conflict(tenant_id,user_id) do nothing;
  select verification.* into v_old from public.tenant_user_verifications verification
  where verification.tenant_id=p_tenant_id and verification.user_id=p_target_user_id for update;

  v_status:=case v_action when 'verify' then 'verified' when 'reject' then 'rejected' else 'pending' end;
  v_permissions:=v_action='verify';
  v_note:=coalesce(v_note,case v_action
    when 'verify' then 'Uprawnienia klienta zostały zweryfikowane podczas wizyty.'
    when 'reject' then 'Weryfikacja klienta została odrzucona.'
    else 'Weryfikacja klienta oczekuje na ponowne sprawdzenie.' end);

  if v_old.verification_status=v_status
     and v_old.permissions_verified=v_permissions
     and v_old.permissions_verification_note is not distinct from v_note then
    return pg_catalog.jsonb_build_object('ok',true,'changed',false,'code','no_change','user_id',p_target_user_id,
      'verification_status',v_old.verification_status,'permissions_verified',v_old.permissions_verified,
      'permissions_verified_at',v_old.permissions_verified_at,'permissions_verified_by',v_old.permissions_verified_by,
      'permissions_verification_note',v_old.permissions_verification_note,'verified_at',v_old.verified_at,
      'verified_by',v_old.verified_by,'unverified_at',v_old.unverified_at,'unverified_by',v_old.unverified_by,'updated_at',v_old.updated_at);
  end if;

  update public.tenant_user_verifications verification set
    verification_status=v_status,permissions_verified=v_permissions,
    permissions_verified_at=case when v_action='verify' then v_now else null end,
    permissions_verified_by=case when v_action='verify' then v_actor_id else null end,
    permissions_verification_note=v_note,
    verified_at=case when v_action='verify' then v_now else null end,
    verified_by=case when v_action='verify' then v_actor_id else null end,
    unverified_at=case when v_action='verify' then null else v_now end,
    unverified_by=case when v_action='verify' then null else v_actor_id end,
    updated_at=v_now
  where verification.tenant_id=p_tenant_id and verification.user_id=p_target_user_id
  returning verification.* into v_updated;

  v_audit_action:=case v_action when 'verify' then 'tenant_user_verification_verified' when 'reject' then 'tenant_user_verification_rejected' else 'tenant_user_verification_marked_pending' end;
  insert into public.audit_logs(tenant_id,actor_user_id,actor_name,actor_role,action,target_type,target_id,target_name,details)
  values(p_tenant_id,v_actor_id,'Tenant staff',v_actor_role,v_audit_action,'tenant_user_verification',p_target_user_id,'Tenant user',
    pg_catalog.jsonb_build_object('previous_status',v_old.verification_status,'new_status',v_updated.verification_status,
      'previous_permissions_verified',v_old.permissions_verified,'new_permissions_verified',v_updated.permissions_verified,
      'resource_type',p_resource_type,'resource_id',p_resource_id,'operator_role',v_actor_role));

  return pg_catalog.jsonb_build_object('ok',true,'changed',true,'code','updated','user_id',p_target_user_id,
    'verification_status',v_updated.verification_status,'permissions_verified',v_updated.permissions_verified,
    'permissions_verified_at',v_updated.permissions_verified_at,'permissions_verified_by',v_updated.permissions_verified_by,
    'permissions_verification_note',v_updated.permissions_verification_note,'verified_at',v_updated.verified_at,
    'verified_by',v_updated.verified_by,'unverified_at',v_updated.unverified_at,'unverified_by',v_updated.unverified_by,'updated_at',v_updated.updated_at);
end;
$function$;

alter function public._apply_tenant_user_verification_v1(uuid,uuid,text,text,text,uuid) owner to postgres;
revoke all on function public._apply_tenant_user_verification_v1(uuid,uuid,text,text,text,uuid) from public,anon,authenticated,service_role;

create or replace function public.update_profile_verification(p_target_user_id uuid,p_action text,p_note text default null)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,pg_temp
as $function$
declare
  v_actor_id uuid:=auth.uid();
  v_tenant_id uuid:=public.active_single_tenant_id_v1();
  v_actor_role text;
begin
  if v_actor_id is null or v_tenant_id is null or p_target_user_id is null then
    raise exception 'Brak uprawnień do weryfikacji profili.' using errcode='42501';
  end if;
  select membership.role into v_actor_role from public.tenant_memberships membership
  where membership.tenant_id=v_tenant_id and membership.user_id=v_actor_id and membership.status='active' for update;
  if v_actor_role is distinct from 'admin' then
    raise exception 'Brak uprawnień do weryfikacji profili.' using errcode='42501';
  end if;
  if not (
    exists(select 1 from public.tenant_memberships membership where membership.tenant_id=v_tenant_id and membership.user_id=p_target_user_id)
    or exists(select 1 from public.reservations reservation where reservation.tenant_id=v_tenant_id and reservation.user_id=p_target_user_id)
    or exists(select 1 from public.event_registrations registration join public.events event_record on event_record.id=registration.event_id and event_record.tenant_id=registration.tenant_id where registration.tenant_id=v_tenant_id and registration.user_id=p_target_user_id)
  ) then
    raise exception 'Brak uprawnień do weryfikacji profili.' using errcode='42501';
  end if;
  return public._apply_tenant_user_verification_v1(v_tenant_id,p_target_user_id,p_action,p_note,'operational_relation',null);
end;
$function$;

alter function public.update_profile_verification(uuid,text,text) owner to postgres;
revoke all on function public.update_profile_verification(uuid,text,text) from public,anon,authenticated,service_role;
grant execute on function public.update_profile_verification(uuid,text,text) to authenticated;

do $postflight$
declare
  v_function regprocedure;
  v_expected text;
begin
  for v_function,v_expected in values
    ('public._apply_tenant_user_verification_v1(uuid,uuid,text,text,text,uuid)'::regprocedure,'1bc256ff8575cb29fe26b8de7f6b6bea'),
    ('public.update_profile_verification(uuid,text,text)'::regprocedure,'022baa5652409d2246cd5e66642e884e')
  loop
    if pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef(v_function),pg_catalog.chr(13)||pg_catalog.chr(10),pg_catalog.chr(10)),pg_catalog.chr(13),pg_catalog.chr(10)))<>v_expected then
      raise exception 'SAAS-9D-4B-2C postflight failed: normalized target fingerprint differs for %.',v_function;
    end if;
  end loop;
  if pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef('public.prevent_non_admin_profile_privilege_changes()'::regprocedure),pg_catalog.chr(13)||pg_catalog.chr(10),pg_catalog.chr(10)),pg_catalog.chr(13),pg_catalog.chr(10)))<>'d28cb697d8355a5e8005296a03ad63ea' then
    raise exception 'SAAS-9D-4B-2C postflight failed: frozen profile trigger drifted.';
  end if;
  if (select pg_catalog.count(*) from pg_catalog.pg_proc procedure_record
      join pg_catalog.pg_namespace namespace_record on namespace_record.oid=procedure_record.pronamespace
      where namespace_record.nspname='public' and procedure_record.prosecdef)<>69 then
    raise exception 'SAAS-9D-4B-2C postflight failed: SECURITY DEFINER count differs.';
  end if;
  if (select pg_catalog.count(*) from information_schema.columns
      where table_schema='public'
        and table_name in('shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','email_deliveries')
        and column_name='tenant_id'
        and column_default='''c5c00000-0000-4000-8000-000000000001''::uuid')<>7 then
    raise exception 'SAAS-9D-4B-2C postflight failed: compatibility defaults differ.';
  end if;
  if pg_catalog.strpos((select prosrc from pg_catalog.pg_proc where oid='public._apply_tenant_user_verification_v1(uuid,uuid,text,text,text,uuid)'::regprocedure),'update public.profiles')>0
     or pg_catalog.strpos((select prosrc from pg_catalog.pg_proc where oid='public._apply_tenant_user_verification_v1(uuid,uuid,text,text,text,uuid)'::regprocedure),'profile_verification_rpc_')>0
     or pg_catalog.strpos((select prosrc from pg_catalog.pg_proc where oid='public.update_profile_verification(uuid,text,text)'::regprocedure),'profiles.role')>0
     or pg_catalog.strpos((select prosrc from pg_catalog.pg_proc where oid='public.update_profile_verification(uuid,text,text)'::regprocedure),'''employee''')>0 then
    raise exception 'SAAS-9D-4B-2C postflight failed: legacy writer residual remains.';
  end if;
  if not pg_catalog.has_function_privilege('authenticated','public.update_profile_verification(uuid,text,text)','EXECUTE')
     or pg_catalog.has_function_privilege('public','public.update_profile_verification(uuid,text,text)','EXECUTE')
     or pg_catalog.has_function_privilege('anon','public.update_profile_verification(uuid,text,text)','EXECUTE')
     or pg_catalog.has_function_privilege('service_role','public.update_profile_verification(uuid,text,text)','EXECUTE') then
    raise exception 'SAAS-9D-4B-2C postflight failed: writer ACL differs.';
  end if;
end;
$postflight$;
