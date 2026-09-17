begin;

set local lock_timeout = '5s';
set local statement_timeout = '120s';

do $preflight$
declare
  v_expected record;
  v_actual text;
begin
  if pg_catalog.md5(pg_catalog.regexp_replace(E'alpha\nbeta\ngamma',E'\r\n?',E'\n','g'))
       is distinct from pg_catalog.md5(pg_catalog.regexp_replace(E'alpha\r\nbeta\r\ngamma',E'\r\n?',E'\n','g'))
     or pg_catalog.md5(pg_catalog.regexp_replace(E'alpha\nbeta\ngamma',E'\r\n?',E'\n','g'))
       is distinct from pg_catalog.md5(pg_catalog.regexp_replace(E'alpha\rbeta\rgamma',E'\r\n?',E'\n','g'))
     or pg_catalog.md5(pg_catalog.regexp_replace(E'alpha\nbeta\ngamma',E'\r\n?',E'\n','g'))
       is not distinct from pg_catalog.md5(pg_catalog.regexp_replace(E'alpha\nbeta\nGAMMA',E'\r\n?',E'\n','g')) then
    raise exception 'SAAS-9D-4B-1B fingerprint normalization self-test failed';
  end if;

  for v_expected in
    select * from (values
      ('public.admin_set_user_role_v1(uuid,text)'::regprocedure,'f30c0568743acb638e316e13f32496f5'),
      ('public.update_profile_identity(uuid,text,text)'::regprocedure,'4c535b7788eb39606f8f8202c9a4b135'),
      ('public.update_profile_contact_details(uuid,text,text,text,text,text,text)'::regprocedure,'eaa03f94556c709e84dda089f3d010fd'),
      ('public.set_audit_log_tenant_id()'::regprocedure,'66154375df9ee963c266c0ff468d2526'),
      ('public.admin_list_users_v1(integer,integer,text,text,text,text)'::regprocedure,'2a95b1f3ba9c404adfa84f7eb9b8d425'),
      ('public.prevent_non_admin_profile_privilege_changes()'::regprocedure,'d28cb697d8355a5e8005296a03ad63ea'),
      ('public.update_profile_verification(uuid,text,text)'::regprocedure,'a0522b6beb94bde3bdff22799afc1368'),
      ('public.export_my_data_v1()'::regprocedure,'ffa6b35c5502a347e463110401032061'),
      ('public.anonymize_my_account_v1()'::regprocedure,'7e4d950e75e6e5782b139f11269d03a0')
    ) frozen(signature,fingerprint)
  loop
    select pg_catalog.md5(pg_catalog.regexp_replace(
      pg_catalog.pg_get_functiondef(v_expected.signature),E'\r\n?',E'\n','g'
    )) into v_actual;
    if v_actual is distinct from v_expected.fingerprint then
      raise exception 'SAAS-9D-4B-1B preflight fingerprint mismatch: %, actual %, expected %',v_expected.signature,v_actual,v_expected.fingerprint;
    end if;
  end loop;

  if public.active_single_tenant_id_v1() is distinct from 'c5c00000-0000-4000-8000-000000000001'::uuid then
    raise exception 'SAAS-9D-4B-1B requires the exact active CSK tenant';
  end if;
  if exists(select 1 from public.tenant_memberships where tenant_id=public.active_single_tenant_id_v1())
     and not exists(select 1 from public.tenant_memberships where tenant_id=public.active_single_tenant_id_v1() and status='active' and role='admin') then
    raise exception 'SAAS-9D-4B-1B requires an active tenant administrator';
  end if;
  if (select count(*) from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prosecdef)<>67 then
    raise exception 'SAAS-9D-4B-1B SECURITY DEFINER baseline differs';
  end if;
  if (select count(*) from information_schema.columns where table_schema='public' and table_name in('shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','email_deliveries') and column_name='tenant_id' and column_default='''c5c00000-0000-4000-8000-000000000001''::uuid')<>7 then
    raise exception 'SAAS-9D-4B-1B compatibility defaults differ';
  end if;
end;
$preflight$;

create or replace function public.set_audit_log_tenant_id()
returns trigger
language plpgsql security invoker
set search_path=pg_catalog
as $function$
declare
  v_tenant_id uuid;
begin
  case new.target_type
    when 'reservation' then
      select record.tenant_id into v_tenant_id from public.reservations record where record.id=new.target_id;
    when 'event_registration' then
      select record.tenant_id into v_tenant_id from public.event_registrations record where record.id=new.target_id;
    when 'lane_booking_family' then
      select record.tenant_id into v_tenant_id from public.shooting_lanes record where record.id=new.target_id;
    when 'tenant_user_admin_note' then
      if new.action is distinct from 'tenant_user_admin_note_updated' then
        raise exception using errcode='23514',message='tenant_user_admin_note_audit_mismatch';
      end if;
    when 'tenant_user_role' then
      if new.action is distinct from 'tenant_user_role_updated' then
        raise exception using errcode='23514',message='tenant_user_role_audit_mismatch';
      end if;
    when 'tenant_user_identity' then
      if new.action is distinct from 'tenant_user_identity_updated' then
        raise exception using errcode='23514',message='tenant_user_identity_audit_mismatch';
      end if;
    when 'tenant_user_contact' then
      if new.action is distinct from 'tenant_user_contact_updated' then
        raise exception using errcode='23514',message='tenant_user_contact_audit_mismatch';
      end if;
    when 'profile','account' then
      if new.tenant_id is not null then
        raise exception using errcode='23514',message='global_audit_must_not_have_tenant';
      end if;
      return new;
    else
      raise exception using errcode='23514',message='unsupported_audit_target_type';
  end case;

  if new.target_type like 'tenant_user_%' then
    if new.tenant_id is null or new.target_id is null
       or not exists(select 1 from public.tenants tenant where tenant.id=new.tenant_id)
       or not exists(select 1 from public.profiles profile where profile.user_id=new.target_id)
       or not (
         exists(select 1 from public.tenant_memberships membership where membership.tenant_id=new.tenant_id and membership.user_id=new.target_id)
         or exists(select 1 from public.reservations reservation where reservation.tenant_id=new.tenant_id and reservation.user_id=new.target_id)
         or exists(select 1 from public.event_registrations registration join public.events event_record on event_record.id=registration.event_id and event_record.tenant_id=registration.tenant_id where registration.tenant_id=new.tenant_id and registration.user_id=new.target_id)
       ) then
      raise exception using errcode='23514',message='tenant_user_audit_mismatch';
    end if;
    return new;
  end if;

  if v_tenant_id is null then
    raise exception using errcode='23503',message='audit_target_not_found';
  end if;
  if new.tenant_id is not null and new.tenant_id is distinct from v_tenant_id then
    raise exception using errcode='23514',message='audit_tenant_mismatch';
  end if;
  new.tenant_id:=v_tenant_id;
  return new;
end;
$function$;

alter function public.set_audit_log_tenant_id() owner to postgres;
revoke all on function public.set_audit_log_tenant_id() from public,anon,authenticated,service_role;

create or replace function public.admin_set_user_role_v1(p_target_user_id uuid,p_new_role text)
returns jsonb
language plpgsql security definer
set search_path=pg_catalog,public,pg_temp
as $function$
declare
  v_actor_id uuid:=auth.uid();
  v_tenant_id uuid:=public.active_single_tenant_id_v1();
  v_new_legacy_role text:=pg_catalog.lower(pg_catalog.btrim(p_new_role));
  v_new_tenant_role text;
  v_current_tenant_role text;
  v_current_legacy_role text;
  v_admin_count bigint;
  v_changed_at timestamptz:=pg_catalog.transaction_timestamp();
begin
  if v_actor_id is null or v_tenant_id is null then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','not_allowed');
  end if;
  if p_target_user_id is null then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','invalid_target');
  end if;
  v_new_tenant_role:=public.legacy_profile_role_to_tenant_role_v1(v_new_legacy_role);
  if v_new_tenant_role is null then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','invalid_role');
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_tenant_id::text,9401));
  perform 1 from public.tenant_memberships membership
  where membership.tenant_id=v_tenant_id and membership.status='active' and membership.role='admin'
  order by membership.user_id for update;
  if public.get_my_tenant_role_v1(v_tenant_id) is distinct from 'admin' then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','not_allowed');
  end if;

  select membership.role into v_current_tenant_role
  from public.tenant_memberships membership
  where membership.tenant_id=v_tenant_id and membership.user_id=p_target_user_id
  for update;
  if not found then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','not_allowed');
  end if;
  v_current_legacy_role:=public.tenant_role_to_legacy_profile_role_v1(v_current_tenant_role);
  if v_current_legacy_role is null then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','invalid_current_role');
  end if;
  if v_current_tenant_role=v_new_tenant_role then
    return pg_catalog.jsonb_build_object('ok',true,'changed',false,'code','no_change','target_user_id',p_target_user_id,'role',v_current_legacy_role);
  end if;
  if v_current_tenant_role='admin' and v_new_tenant_role<>'admin' then
    select pg_catalog.count(*) into v_admin_count from public.tenant_memberships membership
    where membership.tenant_id=v_tenant_id and membership.status='active' and membership.role='admin';
    if v_admin_count<=1 then
      return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','last_admin','target_user_id',p_target_user_id,'role',v_current_legacy_role);
    end if;
  end if;

  update public.tenant_memberships membership set role=v_new_tenant_role,updated_at=v_changed_at
  where membership.tenant_id=v_tenant_id and membership.user_id=p_target_user_id;

  insert into public.audit_logs(tenant_id,actor_user_id,actor_name,actor_role,action,target_type,target_id,target_name,details)
  values(v_tenant_id,v_actor_id,'Tenant administrator','admin','tenant_user_role_updated','tenant_user_role',p_target_user_id,'Tenant user',
    pg_catalog.jsonb_build_object('previous_role',v_current_tenant_role,'new_role',v_new_tenant_role,'operator_role','admin'));

  return pg_catalog.jsonb_build_object('ok',true,'changed',true,'code','updated','target_user_id',p_target_user_id,
    'previous_role',v_current_legacy_role,'role',v_new_legacy_role,'updated_at',v_changed_at);
end;
$function$;

alter function public.admin_set_user_role_v1(uuid,text) owner to postgres;
revoke all on function public.admin_set_user_role_v1(uuid,text) from public,anon,authenticated,service_role;
grant execute on function public.admin_set_user_role_v1(uuid,text) to authenticated;

create or replace function public.update_profile_identity(p_target_user_id uuid,p_first_name text,p_last_name text)
returns jsonb
language plpgsql security definer
set search_path=pg_catalog,public,pg_temp
as $function$
declare
  v_actor_id uuid:=auth.uid();
  v_tenant_id uuid:=public.active_single_tenant_id_v1();
  v_target public.profiles%rowtype;
  v_updated public.profiles%rowtype;
  v_first text:=nullif(pg_catalog.regexp_replace(pg_catalog.btrim(p_first_name),'[[:space:]]+',' ','g'),'');
  v_last text:=nullif(pg_catalog.regexp_replace(pg_catalog.btrim(p_last_name),'[[:space:]]+',' ','g'),'');
  v_full text;
  v_changed_at timestamptz:=pg_catalog.transaction_timestamp();
  v_changed text[]:=array[]::text[];
begin
  if v_actor_id is null or v_tenant_id is null or public.get_my_tenant_role_v1(v_tenant_id) is distinct from 'admin' then
    raise exception 'Brak uprawnień do korekty imienia i nazwiska.' using errcode='42501';
  end if;
  if p_target_user_id is null then raise exception 'Identyfikator profilu docelowego jest wymagany.' using errcode='22023'; end if;
  if v_first is null then raise exception 'Imię jest wymagane.' using errcode='22023'; end if;
  if v_last is null then raise exception 'Nazwisko jest wymagane.' using errcode='22023'; end if;
  if pg_catalog.char_length(v_first)>120 then raise exception 'Imię jest zbyt długie.' using errcode='22023'; end if;
  if pg_catalog.char_length(v_last)>160 then raise exception 'Nazwisko jest zbyt długie.' using errcode='22023'; end if;
  if not (
    exists(select 1 from public.tenant_memberships m where m.tenant_id=v_tenant_id and m.user_id=p_target_user_id)
    or exists(select 1 from public.reservations r where r.tenant_id=v_tenant_id and r.user_id=p_target_user_id)
    or exists(select 1 from public.event_registrations er join public.events e on e.id=er.event_id and e.tenant_id=er.tenant_id where er.tenant_id=v_tenant_id and er.user_id=p_target_user_id)
  ) then raise exception 'Brak uprawnień do korekty imienia i nazwiska.' using errcode='42501'; end if;

  v_full:=pg_catalog.concat_ws(' ',v_first,v_last);
  select profile.* into v_target from public.profiles profile where profile.user_id=p_target_user_id for update;
  if not found then raise exception 'Nie znaleziono profilu docelowego.' using errcode='P0002'; end if;
  if v_target.first_name is distinct from v_first then v_changed:=pg_catalog.array_append(v_changed,'first_name'); end if;
  if v_target.last_name is distinct from v_last then v_changed:=pg_catalog.array_append(v_changed,'last_name'); end if;
  if v_target.full_name is distinct from v_full then v_changed:=pg_catalog.array_append(v_changed,'full_name'); end if;
  if pg_catalog.cardinality(v_changed)=0 then
    return pg_catalog.jsonb_build_object('user_id',v_target.user_id,'first_name',v_target.first_name,'last_name',v_target.last_name,'full_name',v_target.full_name,'updated_at',v_target.updated_at,'changed_fields',pg_catalog.to_jsonb(v_changed));
  end if;
  perform pg_catalog.set_config('csk.profile_identity_rpc_actor',v_actor_id::text,true);
  perform pg_catalog.set_config('csk.profile_identity_rpc_target',p_target_user_id::text,true);
  update public.profiles profile set first_name=v_first,last_name=v_last,full_name=v_full,updated_at=v_changed_at
  where profile.user_id=p_target_user_id returning profile.* into v_updated;
  perform pg_catalog.set_config('csk.profile_identity_rpc_actor','',true);
  perform pg_catalog.set_config('csk.profile_identity_rpc_target','',true);
  insert into public.audit_logs(tenant_id,actor_user_id,actor_name,actor_role,action,target_type,target_id,target_name,details)
  values(v_tenant_id,v_actor_id,'Tenant administrator','admin','tenant_user_identity_updated','tenant_user_identity',p_target_user_id,'Tenant user',
    pg_catalog.jsonb_build_object('changed_fields',pg_catalog.to_jsonb(v_changed),'changed_field_count',pg_catalog.cardinality(v_changed),'operator_role','admin'));
  return pg_catalog.jsonb_build_object('user_id',v_updated.user_id,'first_name',v_updated.first_name,'last_name',v_updated.last_name,'full_name',v_updated.full_name,'updated_at',v_updated.updated_at,'changed_fields',pg_catalog.to_jsonb(v_changed));
end;
$function$;

alter function public.update_profile_identity(uuid,text,text) owner to postgres;
revoke all on function public.update_profile_identity(uuid,text,text) from public,anon,authenticated,service_role;
grant execute on function public.update_profile_identity(uuid,text,text) to authenticated;

create or replace function public.update_profile_contact_details(p_target_user_id uuid,p_phone text,p_postal_code text,p_city text,p_street text,p_house_number text,p_apartment_number text)
returns jsonb
language plpgsql security definer
set search_path=pg_catalog,public,pg_temp
as $function$
declare
  v_actor_id uuid:=auth.uid();
  v_tenant_id uuid:=public.active_single_tenant_id_v1();
  v_actor_role text;
  v_target_role text;
  v_target public.profiles%rowtype;
  v_updated public.profiles%rowtype;
  v_phone text:=nullif(pg_catalog.btrim(p_phone),'');
  v_postal text:=nullif(pg_catalog.btrim(p_postal_code),'');
  v_city text:=nullif(pg_catalog.btrim(p_city),'');
  v_street text:=nullif(pg_catalog.btrim(p_street),'');
  v_house text:=nullif(pg_catalog.btrim(p_house_number),'');
  v_apartment text:=nullif(pg_catalog.btrim(p_apartment_number),'');
  v_changed_at timestamptz:=pg_catalog.transaction_timestamp();
  v_changed text[]:=array[]::text[];
begin
  if v_actor_id is null or v_tenant_id is null then raise exception 'Brak uprawnień do aktualizacji danych kontaktowych.' using errcode='42501'; end if;
  v_actor_role:=public.get_my_tenant_role_v1(v_tenant_id);
  if v_actor_role is null or v_actor_role not in('admin','employee') then raise exception 'Brak uprawnień do aktualizacji danych kontaktowych.' using errcode='42501'; end if;
  if p_target_user_id is null then raise exception 'Identyfikator profilu docelowego jest wymagany.' using errcode='22023'; end if;
  if pg_catalog.length(v_phone)>32 then raise exception 'Numer telefonu jest zbyt długi.' using errcode='22023'; end if;
  if pg_catalog.length(v_postal)>20 then raise exception 'Kod pocztowy jest zbyt długi.' using errcode='22023'; end if;
  if pg_catalog.length(v_city)>120 then raise exception 'Nazwa miasta jest zbyt długa.' using errcode='22023'; end if;
  if pg_catalog.length(v_street)>160 then raise exception 'Nazwa ulicy jest zbyt długa.' using errcode='22023'; end if;
  if pg_catalog.length(v_house)>30 then raise exception 'Numer domu jest zbyt długi.' using errcode='22023'; end if;
  if pg_catalog.length(v_apartment)>30 then raise exception 'Numer mieszkania jest zbyt długi.' using errcode='22023'; end if;
  if not (
    exists(select 1 from public.tenant_memberships m where m.tenant_id=v_tenant_id and m.user_id=p_target_user_id)
    or exists(select 1 from public.reservations r where r.tenant_id=v_tenant_id and r.user_id=p_target_user_id)
    or exists(select 1 from public.event_registrations er join public.events e on e.id=er.event_id and e.tenant_id=er.tenant_id where er.tenant_id=v_tenant_id and er.user_id=p_target_user_id)
  ) then raise exception 'Brak uprawnień do aktualizacji danych kontaktowych.' using errcode='42501'; end if;
  select m.role into v_target_role from public.tenant_memberships m where m.tenant_id=v_tenant_id and m.user_id=p_target_user_id;
  if v_actor_role='employee' and (p_target_user_id=v_actor_id or v_target_role in('admin','employee','instructor')) then
    raise exception 'Pracownik może aktualizować dane kontaktowe wyłącznie klienta.' using errcode='42501';
  end if;
  select profile.* into v_target from public.profiles profile where profile.user_id=p_target_user_id for update;
  if not found then raise exception 'Nie znaleziono profilu docelowego.' using errcode='P0002'; end if;
  if v_target.phone is distinct from v_phone then v_changed:=pg_catalog.array_append(v_changed,'phone'); end if;
  if v_target.postal_code is distinct from v_postal then v_changed:=pg_catalog.array_append(v_changed,'postal_code'); end if;
  if v_target.city is distinct from v_city then v_changed:=pg_catalog.array_append(v_changed,'city'); end if;
  if v_target.street is distinct from v_street then v_changed:=pg_catalog.array_append(v_changed,'street'); end if;
  if v_target.house_number is distinct from v_house then v_changed:=pg_catalog.array_append(v_changed,'house_number'); end if;
  if v_target.apartment_number is distinct from v_apartment then v_changed:=pg_catalog.array_append(v_changed,'apartment_number'); end if;
  if pg_catalog.cardinality(v_changed)=0 then
    return pg_catalog.jsonb_build_object('user_id',v_target.user_id,'phone',v_target.phone,'postal_code',v_target.postal_code,'city',v_target.city,'street',v_target.street,'house_number',v_target.house_number,'apartment_number',v_target.apartment_number,'updated_at',v_target.updated_at,'changed_fields',pg_catalog.to_jsonb(v_changed));
  end if;
  perform pg_catalog.set_config('csk.profile_contact_rpc_actor',v_actor_id::text,true);
  perform pg_catalog.set_config('csk.profile_contact_rpc_target',p_target_user_id::text,true);
  update public.profiles profile set phone=v_phone,postal_code=v_postal,city=v_city,street=v_street,house_number=v_house,apartment_number=v_apartment,updated_at=v_changed_at
  where profile.user_id=p_target_user_id returning profile.* into v_updated;
  perform pg_catalog.set_config('csk.profile_contact_rpc_actor','',true);
  perform pg_catalog.set_config('csk.profile_contact_rpc_target','',true);
  insert into public.audit_logs(tenant_id,actor_user_id,actor_name,actor_role,action,target_type,target_id,target_name,details)
  values(v_tenant_id,v_actor_id,'Tenant staff',v_actor_role,'tenant_user_contact_updated','tenant_user_contact',p_target_user_id,'Tenant user',
    pg_catalog.jsonb_build_object('changed_fields',pg_catalog.to_jsonb(v_changed),'changed_field_count',pg_catalog.cardinality(v_changed),'operator_role',v_actor_role));
  return pg_catalog.jsonb_build_object('user_id',v_updated.user_id,'phone',v_updated.phone,'postal_code',v_updated.postal_code,'city',v_updated.city,'street',v_updated.street,'house_number',v_updated.house_number,'apartment_number',v_updated.apartment_number,'updated_at',v_updated.updated_at,'changed_fields',pg_catalog.to_jsonb(v_changed));
end;
$function$;

alter function public.update_profile_contact_details(uuid,text,text,text,text,text,text) owner to postgres;
revoke all on function public.update_profile_contact_details(uuid,text,text,text,text,text,text) from public,anon,authenticated,service_role;
grant execute on function public.update_profile_contact_details(uuid,text,text,text,text,text,text) to authenticated;

do $postflight$
begin
  if pg_catalog.md5(pg_catalog.regexp_replace(pg_catalog.pg_get_functiondef('public.admin_list_users_v1(integer,integer,text,text,text,text)'::regprocedure),E'\r\n?',E'\n','g'))<>'2a95b1f3ba9c404adfa84f7eb9b8d425' then raise exception 'admin_list_users_v1 drifted'; end if;
  if (select pg_catalog.count(*)=3 and pg_catalog.bool_and(p.prosecdef and r.rolname='postgres' and p.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[] and pg_catalog.has_function_privilege('authenticated',p.oid,'EXECUTE') and not pg_catalog.has_function_privilege('public',p.oid,'EXECUTE') and not pg_catalog.has_function_privilege('anon',p.oid,'EXECUTE') and not pg_catalog.has_function_privilege('service_role',p.oid,'EXECUTE')) from pg_catalog.pg_proc p join pg_catalog.pg_roles r on r.oid=p.proowner where p.oid in('public.admin_set_user_role_v1(uuid,text)'::regprocedure,'public.update_profile_identity(uuid,text,text)'::regprocedure,'public.update_profile_contact_details(uuid,text,text,text,text,text,text)'::regprocedure)) is not true then raise exception 'writer metadata/ACL differs'; end if;
  if (select count(*) from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prosecdef)<>67 then raise exception 'SECURITY DEFINER count drifted'; end if;
  if (select count(*) from information_schema.columns where table_schema='public' and table_name in('shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','email_deliveries') and column_name='tenant_id' and column_default='''c5c00000-0000-4000-8000-000000000001''::uuid')<>7 then raise exception 'compatibility defaults drifted'; end if;
end;
$postflight$;

commit;
