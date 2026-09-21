-- SAAS-9E-C3-A: additive owner/resource ICS and account-wide profile contracts.
-- Legacy signatures, bridge definitions, and CSK compatibility defaults stay intact.
do $preflight$
declare v_definers integer; v_bridge integer;
begin
  select count(*) into v_definers from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.prosecdef;
  select count(*) into v_bridge from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.prosrc like '%active_single_tenant_id_v1%';
  if v_definers<>94 or v_bridge<>22 then
    raise exception 'SAAS-9E-C3 input function inventory differs (%,%)',v_definers,v_bridge;
  end if;
  if (select count(*) from information_schema.columns where table_schema='public'
      and table_name in ('shooting_lanes','reservations','lane_blocks','events',
                         'event_lanes','event_registrations','email_deliveries')
      and column_name='tenant_id'
      and column_default='''c5c00000-0000-4000-8000-000000000001''::uuid')<>7 then
    raise exception 'SAAS-9E-C3 compatibility defaults differ';
  end if;
  if pg_catalog.to_regprocedure('public.get_my_reservations_v2()') is null
     or pg_catalog.to_regprocedure('public.update_my_profile_v1(text,text,text,text,text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean)') is null
     or pg_catalog.to_regprocedure('public.is_tenant_member_v1(uuid)') is null then
    raise exception 'SAAS-9E-C3 input contract missing';
  end if;
  if pg_catalog.to_regprocedure('public.get_my_reservation_calendar_v1(uuid)') is not null
     or exists(select 1 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
       where n.nspname='public' and p.proname='update_my_profile_v2') then
    raise exception 'SAAS-9E-C3 target contract already exists';
  end if;
end $preflight$;

create function public.get_my_reservation_calendar_v1(p_reservation_id uuid)
returns table(
  reservation_id uuid,tenant_id uuid,reservation_date date,
  start_time time without time zone,end_time time without time zone,
  reservation_status text,lane_display_name text,tenant_public_name text
)
language plpgsql stable security definer
set search_path=pg_catalog,public,pg_temp
as $function$
declare v_actor uuid:=auth.uid();
begin
  if v_actor is null or p_reservation_id is null then return; end if;
  return query
  select r.id,r.tenant_id,r.reservation_date,r.start_time,r.end_time,r.reservation_status,
    case
      when lane.resource_kind='lane' and lane.parent_lane_id is null
       and pg_catalog.btrim(lane.name)<>'' then lane.name
      when lane.resource_kind='position' and lane.parent_lane_id is not null
       and parent.id=lane.parent_lane_id and parent.resource_kind='lane'
       and parent.parent_lane_id is null and pg_catalog.btrim(parent.name)<>''
       and pg_catalog.btrim(lane.name)<>'' then parent.name||' — '||lane.name
      else null
    end,
    tenant.name
  from public.reservations r
  join public.tenants tenant on tenant.id=r.tenant_id and tenant.status='active'
  left join public.shooting_lanes lane
    on lane.id=r.lane_id and lane.tenant_id=r.tenant_id
  left join public.shooting_lanes parent
    on parent.id=lane.parent_lane_id and parent.tenant_id=r.tenant_id
  where r.id=p_reservation_id
    and r.user_id=v_actor
    and public.is_tenant_member_v1(r.tenant_id);
end;
$function$;

create function public.update_my_profile_v2(
  p_phone text,p_postal_code text,p_city text,p_street text,p_house_number text,p_apartment_number text,
  p_permission_sport boolean,p_permission_collector boolean,p_permission_hunting boolean,p_permission_training boolean,
  p_permission_personal_protection boolean,p_permission_other boolean,p_qualification_instructor boolean,
  p_qualification_range_officer boolean,p_qualification_pzss_license boolean,p_qualification_hunter boolean
) returns jsonb
language plpgsql volatile security definer
set search_path=pg_catalog,public,pg_temp
as $function$
declare
  v_user_id uuid:=auth.uid();
  v_profile public.profiles%rowtype;
  v_updated public.profiles%rowtype;
  v_phone text:=pg_catalog.btrim(coalesce(p_phone,''));
  v_postal text:=pg_catalog.btrim(coalesce(p_postal_code,''));
  v_city text:=pg_catalog.btrim(coalesce(p_city,''));
  v_street text:=pg_catalog.btrim(coalesce(p_street,''));
  v_house text:=pg_catalog.btrim(coalesce(p_house_number,''));
  v_apartment text:=nullif(pg_catalog.btrim(coalesce(p_apartment_number,'')),'');
  v_declarations_changed boolean;
  v_changed boolean;
  v_verification public.tenant_user_verifications%rowtype;
  v_now timestamptz:=pg_catalog.transaction_timestamp();
begin
  if v_user_id is null then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','not_allowed');
  end if;
  if p_permission_sport is null or p_permission_collector is null
     or p_permission_hunting is null or p_permission_training is null
     or p_permission_personal_protection is null or p_permission_other is null
     or p_qualification_instructor is null or p_qualification_range_officer is null
     or p_qualification_pzss_license is null or p_qualification_hunter is null
     or pg_catalog.length(v_phone)>32 or pg_catalog.length(v_postal)>20
     or pg_catalog.length(v_city)>120 or pg_catalog.length(v_street)>160
     or pg_catalog.length(v_house)>30 or pg_catalog.length(v_apartment)>30 then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','invalid_input');
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_user_id::text,0));
  select profile.* into v_profile from public.profiles profile
    where profile.user_id=v_user_id for update;
  if not found then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','profile_not_found');
  end if;
  v_declarations_changed:=
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
  v_changed:=v_declarations_changed
    or v_profile.phone is distinct from v_phone
    or v_profile.postal_code is distinct from v_postal
    or v_profile.city is distinct from v_city
    or v_profile.street is distinct from v_street
    or v_profile.house_number is distinct from v_house
    or v_profile.apartment_number is distinct from v_apartment;
  if v_changed then
    update public.profiles profile set
      phone=v_phone,postal_code=v_postal,city=v_city,street=v_street,
      house_number=v_house,apartment_number=v_apartment,
      permission_sport=p_permission_sport,
      permission_collector=p_permission_collector,
      permission_hunting=p_permission_hunting,
      permission_training=p_permission_training,
      permission_personal_protection=p_permission_personal_protection,
      permission_other=p_permission_other,
      qualification_instructor=p_qualification_instructor,
      qualification_range_officer=p_qualification_range_officer,
      qualification_pzss_license=p_qualification_pzss_license,
      qualification_hunter=p_qualification_hunter
    where profile.user_id=v_user_id
    returning profile.* into v_updated;
  else
    v_updated:=v_profile;
  end if;
  if v_declarations_changed then
    for v_verification in
      select verification.* from public.tenant_user_verifications verification
      where verification.user_id=v_user_id
      order by verification.tenant_id for update
    loop
      if v_verification.verification_status is distinct from 'pending'
         or v_verification.permissions_verified
         or v_verification.permissions_verified_at is not null
         or v_verification.permissions_verified_by is not null
         or v_verification.permissions_verification_note is not null
         or v_verification.verified_at is not null
         or v_verification.verified_by is not null then
        update public.tenant_user_verifications verification set
          verification_status='pending',permissions_verified=false,
          permissions_verified_at=null,permissions_verified_by=null,
          permissions_verification_note=null,verified_at=null,verified_by=null,
          unverified_at=v_now,unverified_by=v_user_id,updated_at=v_now
        where verification.tenant_id=v_verification.tenant_id
          and verification.user_id=v_user_id;
        insert into public.audit_logs(
          tenant_id,actor_user_id,actor_name,actor_role,action,
          target_type,target_id,target_name,details
        ) values(
          v_verification.tenant_id,v_user_id,'Account owner','user',
          'tenant_user_verification_invalidated','tenant_user_verification',
          v_user_id,'Tenant user',
          pg_catalog.jsonb_build_object(
            'reason','declarations_changed',
            'previous_status',v_verification.verification_status,
            'previous_permissions_verified',v_verification.permissions_verified,
            'new_status','pending','new_permissions_verified',false,
            'operator_role','user'
          )
        );
      end if;
    end loop;
  end if;
  return pg_catalog.jsonb_build_object(
    'ok',true,'changed',v_changed,
    'code',case when v_changed then 'updated' else 'no_change' end,
    'declarations_changed',v_declarations_changed,
    'updated_at',v_updated.updated_at
  );
end;
$function$;

alter function public.get_my_reservation_calendar_v1(uuid) owner to postgres;
alter function public.update_my_profile_v2(text,text,text,text,text,text,
  boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean) owner to postgres;
revoke all on function public.get_my_reservation_calendar_v1(uuid)
  from public,anon,authenticated,service_role;
revoke all on function public.update_my_profile_v2(text,text,text,text,text,text,
  boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean) from public,anon,authenticated,service_role;
grant execute on function public.get_my_reservation_calendar_v1(uuid) to authenticated;
grant execute on function public.update_my_profile_v2(text,text,text,text,text,text,
  boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean) to authenticated;

do $postflight$
declare v_definers integer; v_bridge integer;
begin
  select count(*) into v_definers from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.prosecdef;
  select count(*) into v_bridge from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.prosrc like '%active_single_tenant_id_v1%';
  if v_definers<>96 or v_bridge<>22 then
    raise exception 'SAAS-9E-C3 target function inventory differs (%,%)',v_definers,v_bridge;
  end if;
end $postflight$;
