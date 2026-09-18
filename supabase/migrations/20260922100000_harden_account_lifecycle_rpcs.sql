-- SAAS-9D-4C DB phase: harden the three account-owner lifecycle RPCs.
-- This migration intentionally keeps every signature, owner, ACL and caller.

begin;

set local lock_timeout = '5s';
set local statement_timeout = '120s';

do $preflight$
declare
  v_function regprocedure;
  v_expected text;
begin
  for v_function,v_expected in values
    ('public.update_my_profile_v1(text,text,text,text,text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean)'::regprocedure,'c8c882630f05763f745788e9a108fb65'),
    ('public.export_my_data_v1()'::regprocedure,'ffa6b35c5502a347e463110401032061'),
    ('public.anonymize_my_account_v1()'::regprocedure,'7e4d950e75e6e5782b139f11269d03a0'),
    ('public.redact_account_audit_details_v1(jsonb,uuid,text,text[])'::regprocedure,'43aab16c26223ca68f4b8a34310bcfb5'),
    ('public.set_audit_log_tenant_id()'::regprocedure,'d3e931ecee92180002d1dddd86fc4f06'),
    ('public.prevent_non_admin_profile_privilege_changes()'::regprocedure,'d28cb697d8355a5e8005296a03ad63ea')
  loop
    if pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(
      pg_catalog.pg_get_functiondef(v_function),
      pg_catalog.chr(13)||pg_catalog.chr(10),pg_catalog.chr(10)
    ),pg_catalog.chr(13),pg_catalog.chr(10)))<>v_expected then
      raise exception 'SAAS-9D-4C preflight failed: normalized fingerprint differs for %.',v_function;
    end if;
  end loop;

  if (select pg_catalog.count(*)
      from pg_catalog.pg_proc procedure_record
      join pg_catalog.pg_namespace namespace_record on namespace_record.oid=procedure_record.pronamespace
      where namespace_record.nspname='public' and procedure_record.prosecdef)<>69 then
    raise exception 'SAAS-9D-4C preflight failed: SECURITY DEFINER baseline differs.';
  end if;

  if (select pg_catalog.count(*) from information_schema.columns
      where table_schema='public'
        and table_name in('shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','email_deliveries')
        and column_name='tenant_id'
        and column_default='''c5c00000-0000-4000-8000-000000000001''::uuid')<>7 then
    raise exception 'SAAS-9D-4C preflight failed: compatibility defaults differ.';
  end if;

  if pg_catalog.to_regclass('public.tenant_memberships') is null
     or pg_catalog.to_regclass('public.tenant_user_verifications') is null
     or pg_catalog.to_regclass('public.tenant_user_admin_notes') is null
     or pg_catalog.to_regclass('public.email_deliveries') is null
     or pg_catalog.to_regclass('public.confirmation_email_rate_limits') is null then
    raise exception 'SAAS-9D-4C preflight failed: lifecycle dependency is missing.';
  end if;
end;
$preflight$;

create or replace function public.update_my_profile_v1(
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
  v_active_tenant_id uuid;
  v_status text;
  v_permissions boolean;
  v_permissions_at timestamptz;
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

  select profile.* into v_profile
  from public.profiles profile
  where profile.user_id=v_user_id
  for update;
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
      select verification.*
      from public.tenant_user_verifications verification
      where verification.user_id=v_user_id
      order by verification.tenant_id
      for update
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
            'new_status','pending',
            'new_permissions_verified',false,
            'operator_role','user'
          )
        );
      end if;
    end loop;
  end if;

  v_active_tenant_id:=public.active_single_tenant_id_v1();
  select coalesce(verification.verification_status,'pending'),
         coalesce(verification.permissions_verified,false),
         verification.permissions_verified_at
  into v_status,v_permissions,v_permissions_at
  from (select 1) anchor
  left join public.tenant_user_verifications verification
    on verification.tenant_id=v_active_tenant_id
   and verification.user_id=v_user_id;

  return pg_catalog.jsonb_build_object(
    'ok',true,'changed',v_changed,
    'code',case when v_changed then 'updated' else 'no_change' end,
    'declarations_changed',v_declarations_changed,
    'verification_status',coalesce(v_status,'pending'),
    'permissions_verified',coalesce(v_permissions,false),
    'permissions_verified_at',v_permissions_at,
    'updated_at',v_updated.updated_at
  );
end;
$function$;

alter function public.update_my_profile_v1(text,text,text,text,text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean) owner to postgres;
revoke all on function public.update_my_profile_v1(text,text,text,text,text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean) from public,anon,authenticated,service_role;
grant execute on function public.update_my_profile_v1(text,text,text,text,text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean) to authenticated;

create or replace function public.export_my_data_v1()
returns jsonb
language plpgsql stable security definer
set search_path=pg_catalog,public,pg_temp
as $function$
declare
  v_user_id uuid:=auth.uid();
  v_account jsonb;
  v_profile jsonb;
  v_reservations jsonb;
  v_registrations jsonb;
  v_relationships jsonb;
begin
  if v_user_id is null then
    raise exception 'Authentication is required.' using errcode='42501';
  end if;

  select pg_catalog.jsonb_build_object(
    'id',auth_user.id,'email',auth_user.email,'phone',auth_user.phone,
    'created_at',auth_user.created_at,
    'accepted_terms',case when pg_catalog.lower(auth_user.raw_user_meta_data->>'accepted_terms') in('true','false') then (auth_user.raw_user_meta_data->>'accepted_terms')::boolean else false end,
    'accepted_terms_at',auth_user.raw_user_meta_data->>'accepted_terms_at',
    'accepted_privacy',case when pg_catalog.lower(auth_user.raw_user_meta_data->>'accepted_privacy') in('true','false') then (auth_user.raw_user_meta_data->>'accepted_privacy')::boolean else false end,
    'accepted_privacy_at',auth_user.raw_user_meta_data->>'accepted_privacy_at'
  ) into v_account
  from auth.users auth_user where auth_user.id=v_user_id;
  if not found then
    raise exception 'Authenticated account is unavailable.' using errcode='42501';
  end if;

  select pg_catalog.jsonb_build_object(
    'id',profile.id,'first_name',profile.first_name,'last_name',profile.last_name,
    'full_name',profile.full_name,'email',profile.email,'phone',profile.phone,
    'postal_code',profile.postal_code,'city',profile.city,'street',profile.street,
    'house_number',profile.house_number,'apartment_number',profile.apartment_number,
    'weapon_permit_number',profile.weapon_permit_number,'weapon_permit_type',profile.weapon_permit_type,
    'weapon_permit_issuer',profile.weapon_permit_issuer,'has_range_officer',profile.has_range_officer,
    'range_officer_number',profile.range_officer_number,'has_instructor',profile.has_instructor,
    'instructor_number',profile.instructor_number,'permission_sport',profile.permission_sport,
    'permission_collector',profile.permission_collector,'permission_hunting',profile.permission_hunting,
    'permission_training',profile.permission_training,'permission_personal_protection',profile.permission_personal_protection,
    'permission_other',profile.permission_other,'qualification_instructor',profile.qualification_instructor,
    'qualification_range_officer',profile.qualification_range_officer,
    'qualification_pzss_license',profile.qualification_pzss_license,
    'qualification_hunter',profile.qualification_hunter,
    'verification_status',profile.verification_status,
    'permissions_verified',profile.permissions_verified,
    'permissions_verified_at',profile.permissions_verified_at,
    'created_at',profile.created_at,'updated_at',profile.updated_at
  ) into v_profile
  from public.profiles profile where profile.user_id=v_user_id;

  select coalesce(pg_catalog.jsonb_agg(row_data.value order by row_data.created_at,row_data.id),'[]'::jsonb)
  into v_reservations
  from(
    select reservation.created_at,reservation.id,pg_catalog.jsonb_build_object(
      'id',reservation.id,'lane_id',reservation.lane_id,
      'reservation_date',reservation.reservation_date,'start_time',reservation.start_time,
      'end_time',reservation.end_time,'duration_minutes',reservation.duration_minutes,
      'shooters_count',reservation.shooters_count,'reservation_status',reservation.reservation_status,
      'attendance_status',reservation.attendance_status,'payment_status',reservation.payment_status,
      'checked_in_at',reservation.checked_in_at,'completed_at',reservation.completed_at,
      'lane_name',reservation.lane_name_snapshot,'pricing_day_group',reservation.pricing_day_group_snapshot,
      'pricing_label',reservation.pricing_label_snapshot,'price_per_hour',reservation.price_per_hour_snapshot,
      'total_price',reservation.total_price,'currency_code',reservation.currency_code,
      'reservation_note',reservation.reservation_note,'created_at',reservation.created_at
    ) value
    from public.reservations reservation where reservation.user_id=v_user_id
  ) row_data;

  select coalesce(pg_catalog.jsonb_agg(row_data.value order by row_data.created_at,row_data.id),'[]'::jsonb)
  into v_registrations
  from(
    select registration.created_at,registration.id,pg_catalog.jsonb_build_object(
      'id',registration.id,'event_id',registration.event_id,
      'registration_status',registration.registration_status,
      'payment_status',registration.payment_status,
      'promotion_email_sent_at',registration.promotion_email_sent_at,
      'promotion_confirmed_at',registration.promotion_confirmed_at,
      'created_at',registration.created_at
    ) value
    from public.event_registrations registration where registration.user_id=v_user_id
  ) row_data;

  select coalesce(pg_catalog.jsonb_agg(
    pg_catalog.jsonb_build_object(
      'tenant',pg_catalog.jsonb_build_object(
        'id',tenant.id,'name',tenant.name,'slug',tenant.slug
      ),
      'membership',pg_catalog.jsonb_build_object(
        'role',membership.role,'status',membership.status,
        'created_at',membership.created_at,'updated_at',membership.updated_at
      ),
      'verification',case when verification.user_id is null then null else
        pg_catalog.jsonb_build_object(
          'status',verification.verification_status,
          'permissions_verified',verification.permissions_verified,
          'permissions_verified_at',verification.permissions_verified_at,
          'updated_at',verification.updated_at
        ) end
    ) order by membership.tenant_id
  ),'[]'::jsonb)
  into v_relationships
  from public.tenant_memberships membership
  join public.tenants tenant on tenant.id=membership.tenant_id
  left join public.tenant_user_verifications verification
    on verification.tenant_id=membership.tenant_id
   and verification.user_id=membership.user_id
  where membership.user_id=v_user_id;

  return pg_catalog.jsonb_build_object(
    'export_version',2,'generated_at',pg_catalog.transaction_timestamp(),
    'account',v_account,'profile',v_profile,
    'reservations',v_reservations,'event_registrations',v_registrations,
    'tenant_relationships',v_relationships
  );
end;
$function$;

alter function public.export_my_data_v1() owner to postgres;
revoke all on function public.export_my_data_v1() from public,anon,authenticated,service_role;
grant execute on function public.export_my_data_v1() to authenticated;

create or replace function public.anonymize_my_account_v1()
returns jsonb
language plpgsql volatile security definer
set search_path=pg_catalog,public,pg_temp
as $function$
declare
  v_user_id uuid:=auth.uid();
  v_now timestamptz:=pg_catalog.transaction_timestamp();
  v_pseudonym_hash text;
  v_pseudonym_id uuid;
  v_pseudonym text;
  v_pseudonym_email text;
  v_profile public.profiles%rowtype;
  v_direct_values text[]:='{}'::text[];
  v_reservation_ids uuid[]:='{}'::uuid[];
  v_registration_ids uuid[]:='{}'::uuid[];
  v_reservation_count integer:=0;
  v_registration_count integer:=0;
  v_delivery_count integer:=0;
  v_rate_limit_count integer:=0;
  v_membership_count integer:=0;
  v_verification_count integer:=0;
  v_note_count integer:=0;
  v_audit_count integer:=0;
  v_membership public.tenant_memberships%rowtype;
  v_active_admin_count bigint;
begin
  if v_user_id is null then
    raise exception 'Authentication is required.' using errcode='42501';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_user_id::text,0));

  v_pseudonym_hash:=pg_catalog.md5(v_user_id::text||':csk-sec009-v1');
  v_pseudonym_id:=(
    pg_catalog.substr(v_pseudonym_hash,1,8)||'-'||
    pg_catalog.substr(v_pseudonym_hash,9,4)||'-'||
    pg_catalog.substr(v_pseudonym_hash,13,4)||'-'||
    pg_catalog.substr(v_pseudonym_hash,17,4)||'-'||
    pg_catalog.substr(v_pseudonym_hash,21,12)
  )::uuid;
  v_pseudonym:='deleted-user-'||pg_catalog.substr(v_pseudonym_hash,1,16);
  v_pseudonym_email:=v_pseudonym||'@invalid.local';

  select pg_catalog.count(*) into v_audit_count
  from public.audit_logs audit
  where audit.action='account_anonymized'
    and audit.actor_user_id=v_pseudonym_id
    and audit.target_type='account'
    and audit.target_id=v_pseudonym_id;
  if v_audit_count>1 then
    raise exception 'Account lifecycle state is ambiguous.' using errcode='P0001';
  end if;
  if v_audit_count=1 then
    return pg_catalog.jsonb_build_object('ok',true,'changed',false,'code','already_anonymized');
  end if;

  select profile.* into v_profile
  from public.profiles profile
  where profile.user_id=v_user_id
  for update;

  for v_membership in
    select membership.*
    from public.tenant_memberships membership
    where membership.user_id=v_user_id
    order by membership.tenant_id
  loop
    perform pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended(v_membership.tenant_id::text,9401)
    );
    perform 1 from public.tenant_memberships membership
    where membership.tenant_id=v_membership.tenant_id
    order by membership.user_id
    for update;
    if v_membership.status='active' and v_membership.role='admin' then
      select pg_catalog.count(*) into v_active_admin_count
      from public.tenant_memberships membership
      where membership.tenant_id=v_membership.tenant_id
        and membership.status='active' and membership.role='admin';
      if v_active_admin_count<=1 then
        raise exception 'Account is the last active tenant administrator.'
          using errcode='23514';
      end if;
    end if;
  end loop;

  select coalesce(pg_catalog.array_agg(reservation.id order by reservation.id),'{}'::uuid[])
  into v_reservation_ids from public.reservations reservation where reservation.user_id=v_user_id;
  select coalesce(pg_catalog.array_agg(registration.id order by registration.id),'{}'::uuid[])
  into v_registration_ids from public.event_registrations registration where registration.user_id=v_user_id;

  select coalesce(pg_catalog.array_agg(distinct source.value) filter(where source.value is not null and source.value<>''),'{}'::text[])
  into v_direct_values
  from(
    select value from pg_catalog.unnest(array[
      v_profile.id::text,v_profile.first_name,v_profile.last_name,v_profile.full_name,
      v_profile.email,v_profile.phone,v_profile.postal_code,v_profile.city,
      v_profile.street,v_profile.house_number,v_profile.apartment_number,
      v_profile.weapon_permit_number,v_profile.weapon_permit_type,
      v_profile.weapon_permit_issuer,v_profile.range_officer_number,
      v_profile.instructor_number,v_profile.admin_note,v_profile.verification_note,
      v_profile.permissions_verification_note
    ]::text[]) value
    union all select reservation.customer_name from public.reservations reservation where reservation.user_id=v_user_id
    union all select reservation.customer_email from public.reservations reservation where reservation.user_id=v_user_id
    union all select reservation.customer_phone from public.reservations reservation where reservation.user_id=v_user_id
    union all select reservation.reservation_note from public.reservations reservation where reservation.user_id=v_user_id
    union all select reservation.admin_note from public.reservations reservation where reservation.user_id=v_user_id
    union all select registration.customer_name from public.event_registrations registration where registration.user_id=v_user_id
    union all select registration.customer_email from public.event_registrations registration where registration.user_id=v_user_id
    union all select registration.customer_phone from public.event_registrations registration where registration.user_id=v_user_id
    union all select note.admin_note from public.tenant_user_admin_notes note where note.user_id=v_user_id
    union all select verification.permissions_verification_note from public.tenant_user_verifications verification where verification.user_id=v_user_id
  ) source;

  update public.reservations reservation set
    user_id=null,customer_name=v_pseudonym,customer_email=v_pseudonym_email,
    customer_phone='[redacted]',admin_note=null,reservation_note=null,
    check_in_token=null,pii_anonymized_at=v_now
  where reservation.user_id=v_user_id;
  get diagnostics v_reservation_count=row_count;

  update public.event_registrations registration set
    user_id=null,customer_name=v_pseudonym,customer_email=v_pseudonym_email,
    customer_phone='[redacted]',promotion_token=null,
    promotion_token_expires_at=null,promotion_claim_id=null,
    promotion_claim_expires_at=null,promotion_attempt_count=0,
    promotion_last_attempt_at=null,promotion_last_error_code=null,
    pii_anonymized_at=v_now
  where registration.user_id=v_user_id;
  get diagnostics v_registration_count=row_count;

  update public.audit_logs audit set
    actor_user_id=case when audit.actor_user_id=v_user_id then v_pseudonym_id else audit.actor_user_id end,
    actor_name=case when audit.actor_user_id=v_user_id then v_pseudonym else audit.actor_name end,
    target_id=case when audit.target_type in('profile','account') and audit.target_id=v_user_id then v_pseudonym_id else audit.target_id end,
    target_name=case when audit.target_id=v_user_id then v_pseudonym else audit.target_name end,
    details=public.redact_account_audit_details_v1(audit.details,v_user_id,v_pseudonym,v_direct_values)
  where audit.actor_user_id=v_user_id
     or (audit.target_type in('profile','account','tenant_user_admin_note','tenant_user_verification','tenant_user_role','tenant_user_identity','tenant_user_contact') and audit.target_id=v_user_id)
     or audit.target_id=any(v_reservation_ids)
     or audit.target_id=any(v_registration_ids);

  delete from public.email_deliveries delivery where delivery.recipient_user_id=v_user_id;
  get diagnostics v_delivery_count=row_count;
  delete from public.confirmation_email_rate_limits rate_limit
  where rate_limit.scope_type='user' and rate_limit.scope_key=v_user_id::text;
  get diagnostics v_rate_limit_count=row_count;
  delete from public.tenant_user_admin_notes note where note.user_id=v_user_id;
  get diagnostics v_note_count=row_count;
  delete from public.tenant_user_verifications verification where verification.user_id=v_user_id;
  get diagnostics v_verification_count=row_count;
  delete from public.tenant_memberships membership where membership.user_id=v_user_id;
  get diagnostics v_membership_count=row_count;
  delete from public.profiles profile where profile.user_id=v_user_id;

  insert into public.audit_logs(
    tenant_id,actor_user_id,actor_name,actor_role,action,
    target_type,target_id,target_name,details
  ) values(
    null,v_pseudonym_id,v_pseudonym,'user','account_anonymized',
    'account',v_pseudonym_id,v_pseudonym,
    pg_catalog.jsonb_build_object(
      'anonymization_version',2,
      'reservation_count',v_reservation_count,
      'event_registration_count',v_registration_count,
      'email_delivery_count',v_delivery_count,
      'user_rate_limit_count',v_rate_limit_count,
      'tenant_membership_count',v_membership_count,
      'tenant_verification_count',v_verification_count,
      'tenant_admin_note_count',v_note_count,
      'anonymized_at',v_now
    )
  );

  return pg_catalog.jsonb_build_object(
    'ok',true,'changed',true,'code','anonymized',
    'reservation_count',v_reservation_count,
    'event_registration_count',v_registration_count
  );
end;
$function$;

alter function public.anonymize_my_account_v1() owner to postgres;
revoke all on function public.anonymize_my_account_v1() from public,anon,authenticated,service_role;
grant execute on function public.anonymize_my_account_v1() to authenticated;

comment on function public.update_my_profile_v1(text,text,text,text,text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean) is
  'Updates only auth.uid() account profile fields and invalidates every changed tenant verification decision.';
comment on function public.export_my_data_v1() is
  'Returns the strict version 2 account-wide owner export with allowlisted tenant relationships.';
comment on function public.anonymize_my_account_v1() is
  'Anonymizes auth.uid() account and removes all caller tenant relationships before Auth deletion.';

do $postflight$
declare
  v_function regprocedure;
  v_expected text;
begin
  for v_function,v_expected in values
    ('public.update_my_profile_v1(text,text,text,text,text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean)'::regprocedure,'eed0787e7c5a67e537b5703289abf536'),
    ('public.export_my_data_v1()'::regprocedure,'d159b7d0a14f7ffc9d6c3e5088d18dc5'),
    ('public.anonymize_my_account_v1()'::regprocedure,'70b5f590399aa3f3a147935459b7f085')
  loop
    if not exists(
      select 1 from pg_catalog.pg_proc procedure_record
      join pg_catalog.pg_roles owner_record on owner_record.oid=procedure_record.proowner
      where procedure_record.oid=v_function
        and procedure_record.prosecdef
        and owner_record.rolname='postgres'
        and procedure_record.proconfig=array['search_path=pg_catalog, public, pg_temp']
    ) or not pg_catalog.has_function_privilege('authenticated',v_function,'EXECUTE')
      or pg_catalog.has_function_privilege('public',v_function,'EXECUTE')
      or pg_catalog.has_function_privilege('anon',v_function,'EXECUTE')
      or pg_catalog.has_function_privilege('service_role',v_function,'EXECUTE')
      or pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(
           pg_catalog.pg_get_functiondef(v_function),
           pg_catalog.chr(13)||pg_catalog.chr(10),pg_catalog.chr(10)
         ),pg_catalog.chr(13),pg_catalog.chr(10)))<>v_expected then
      raise exception 'SAAS-9D-4C postflight failed: metadata or ACL differs for %.',v_function;
    end if;
  end loop;

  if (select pg_catalog.count(*)
      from pg_catalog.pg_proc procedure_record
      join pg_catalog.pg_namespace namespace_record on namespace_record.oid=procedure_record.pronamespace
      where namespace_record.nspname='public' and procedure_record.prosecdef)<>69 then
    raise exception 'SAAS-9D-4C postflight failed: SECURITY DEFINER count differs.';
  end if;
  if (select pg_catalog.count(*) from information_schema.columns
      where table_schema='public'
        and table_name in('shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','email_deliveries')
        and column_name='tenant_id'
        and column_default='''c5c00000-0000-4000-8000-000000000001''::uuid')<>7 then
    raise exception 'SAAS-9D-4C postflight failed: compatibility defaults differ.';
  end if;
  if pg_catalog.strpos((select prosrc from pg_catalog.pg_proc where oid='public.update_my_profile_v1(text,text,text,text,text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean)'::regprocedure),'profiles.role')>0
     or pg_catalog.strpos((select prosrc from pg_catalog.pg_proc where oid='public.export_my_data_v1()'::regprocedure),'tenant_relationships')=0
     or pg_catalog.strpos((select prosrc from pg_catalog.pg_proc where oid='public.anonymize_my_account_v1()'::regprocedure),'delete from public.tenant_memberships')=0 then
    raise exception 'SAAS-9D-4C postflight failed: target body contract differs.';
  end if;
end;
$postflight$;

commit;
