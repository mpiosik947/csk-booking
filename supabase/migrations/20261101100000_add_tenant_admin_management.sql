-- PAM-1B-R1: single-role admin management; no historical/business cleanup.
set lock_timeout='5s';
set statement_timeout='60s';

create table public.platform_admin_management_requests (
 actor_user_id uuid not null, request_id uuid not null,
 tenant_id uuid not null references public.tenants(id) on delete restrict,
 payload jsonb not null, result jsonb not null,
 created_at timestamptz not null default transaction_timestamp(),
 primary key(actor_user_id,request_id)
);
alter table public.platform_admin_management_requests enable row level security;
revoke all on public.platform_admin_management_requests from public,anon,authenticated,service_role;

create function public.tenant_assert_admin_loss_core_v1(p_tenant_id uuid,p_user_id uuid)
returns void language plpgsql set search_path=pg_catalog,public,pg_temp as $$
begin
 if not pg_try_advisory_xact_lock(hashtextextended(p_tenant_id::text,9401)) then
  raise exception 'ADMIN_MANAGEMENT_BUSY' using errcode='55P03'; end if;
 perform 1 from public.tenants where id=p_tenant_id for no key update nowait;
 if not exists(select 1 from public.tenant_memberships where tenant_id=p_tenant_id
  and user_id<>p_user_id and role='admin' and status='active') then
  raise exception 'LAST_ACTIVE_ADMIN' using errcode='23514'; end if;
end;$$;

create function public.tenant_instructor_has_open_obligations_v1(p_tenant_id uuid,p_user_id uuid)
returns boolean language sql stable set search_path=pg_catalog,public,pg_temp as $$
 select exists(
  select 1 from public.event_instructors i join public.events e on e.id=i.event_id and e.tenant_id=i.tenant_id
  where i.tenant_id=p_tenant_id and i.instructor_user_id=p_user_id and i.unassigned_at is null and e.cancelled_at is null
  and (e.event_date+e.end_time>=statement_timestamp() at time zone 'Europe/Warsaw'
   or (public.event_attendance_window_v1((e.event_date+e.start_time) at time zone 'Europe/Warsaw',
       (e.event_date+e.end_time) at time zone 'Europe/Warsaw',statement_timestamp())
    and exists(select 1 from public.event_registrations r where r.tenant_id=e.tenant_id and r.event_id=e.id
     and r.registration_status in ('registered','approved') and r.attendance_status='unmarked' and r.pii_anonymized_at is null))))
 or exists(select 1 from public.email_deliveries d join public.event_instructors i
  on i.id=d.record_id and i.tenant_id=d.tenant_id and i.instructor_user_id=d.recipient_user_id
  join public.events e on e.id=i.event_id and e.tenant_id=i.tenant_id
  where d.tenant_id=p_tenant_id and d.recipient_user_id=p_user_id and d.message_type='instructor_assignment'
   and i.unassigned_at is null and e.cancelled_at is null
   and public.plan_change_email_is_open_v1(d));
$$;

-- Backstop for every membership writer, including Auth cascades and privacy.
-- NOWAIT prevents reverse-lock waits from existing event/account writers.
create function public.guard_tenant_admin_lifecycle_v1()
returns trigger language plpgsql security definer set search_path=pg_catalog,public,pg_temp as $$
declare t uuid:=coalesce(new.tenant_id,old.tenant_id);
begin
 if tg_op='UPDATE' and (new.tenant_id<>old.tenant_id or new.user_id<>old.user_id) then
  raise exception 'MEMBERSHIP_IDENTITY_IMMUTABLE' using errcode='23514'; end if;
 if not pg_try_advisory_xact_lock(hashtextextended(t::text,9401)) then
  raise exception 'ADMIN_MANAGEMENT_BUSY' using errcode='55P03'; end if;
 perform 1 from public.tenants where id=t for no key update nowait;
 if tg_op<>'INSERT' and old.role='admin' and old.status='active'
  and (tg_op='DELETE' or new.role<>'admin' or new.status<>'active') then
  perform public.tenant_assert_admin_loss_core_v1(t,old.user_id);
 end if;
 if tg_op='UPDATE' and old.role='instructor' and old.status='active' and new.role='admin'
  and public.tenant_instructor_has_open_obligations_v1(t,old.user_id) then
  raise exception 'INSTRUCTOR_HAS_OPEN_OBLIGATIONS' using errcode='55000'; end if;
 return coalesce(new,old);
end;$$;
create trigger admin_lifecycle_guard before insert or update or delete on public.tenant_memberships
 for each row execute function public.guard_tenant_admin_lifecycle_v1();

create function public.platform_get_tenant_admin_management_v1(p_tenant_id uuid)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public,pg_temp as $$
declare t public.tenants; items jsonb;
begin
 if not public.is_platform_admin_v1() then raise exception 'Not authorized' using errcode='42501'; end if;
 select * into t from public.tenants where id=p_tenant_id and status in ('dormant','active','suspended');
 if not found then raise exception 'Tenant unavailable' using errcode='22023'; end if;
 select coalesce(jsonb_agg(jsonb_build_object('user_id',m.user_id,'email',u.email,
  'membership_role',m.role,'membership_status',m.status,'updated_at',m.updated_at) order by m.user_id),'[]')
 into items from public.tenant_memberships m join auth.users u on u.id=m.user_id
 where m.tenant_id=t.id and m.role='admin';
 return jsonb_build_object('tenant',jsonb_build_object('tenant_id',t.id,'name',t.name,'status',t.status),
  'admins',items,'active_admin_count',(select count(*) from public.tenant_memberships where tenant_id=t.id and role='admin' and status='active'));
end;$$;

-- Explicit expected role/status is the optimistic state contract, including null
-- for an absent membership. Request replay is checked before current state.
create function public.platform_tenant_admin_mutation_core_v1(p_tenant_id uuid,p_user_id uuid,p_operation text,p_expected_state jsonb,p_request_id uuid)
returns jsonb language plpgsql set search_path=pg_catalog,public,pg_temp as $$
declare actor uuid:=auth.uid(); prior public.platform_admin_management_requests;
 m public.tenant_memberships; payload_value jsonb; state_value jsonb; result_value jsonb;
 next_role text; next_status text; changed boolean;
begin
 if not public.is_platform_admin_v1() then raise exception 'Not authorized' using errcode='42501'; end if;
 perform 1 from public.platform_admins where user_id=actor and status='active' for share nowait;
 if not found then raise exception 'Not authorized' using errcode='42501'; end if;
 if p_tenant_id is null or p_user_id is null or p_request_id is null
  or p_request_id='00000000-0000-0000-0000-000000000000'::uuid
  or p_operation not in ('add','reactivate','demote','suspend') then
  raise exception 'INVALID_ADMIN_REQUEST' using errcode='22023'; end if;
 payload_value:=jsonb_build_object('tenant_id',p_tenant_id,'user_id',p_user_id,'operation',p_operation,'expected_state',p_expected_state);
 if not pg_try_advisory_xact_lock(hashtextextended(actor::text||':'||p_request_id::text,1101000)) then
  raise exception 'ADMIN_MANAGEMENT_BUSY' using errcode='55P03'; end if;
 select * into prior from public.platform_admin_management_requests where actor_user_id=actor and request_id=p_request_id;
 if found then
  if prior.payload<>payload_value then raise exception 'REQUEST_REPLAY_MISMATCH' using errcode='22023'; end if;
  return prior.result;
 end if;
 -- Shared account lifecycle lock; fail fast rather than wait behind a reverse tenant lock.
 if not pg_try_advisory_xact_lock(hashtextextended(p_user_id::text,0)) then
  raise exception 'ADMIN_MANAGEMENT_BUSY' using errcode='55P03'; end if;
 perform 1 from public.profiles where user_id=p_user_id for share nowait;
 perform 1 from auth.users where id=p_user_id for share nowait;
 if not found then raise exception 'ACCOUNT_UNAVAILABLE' using errcode='22023'; end if;
 if not pg_try_advisory_xact_lock(hashtextextended(p_tenant_id::text,9401)) then
  raise exception 'ADMIN_MANAGEMENT_BUSY' using errcode='55P03'; end if;
 perform 1 from public.tenants where id=p_tenant_id and status in ('dormant','active','suspended') for no key update nowait;
 if not found then raise exception 'Tenant unavailable' using errcode='22023'; end if;
 select * into m from public.tenant_memberships where tenant_id=p_tenant_id and user_id=p_user_id for update nowait;
 state_value:=case when m.user_id is null then null else jsonb_build_object('role',m.role,'status',m.status) end;
 if state_value is distinct from p_expected_state then raise exception 'STALE_MEMBERSHIP_STATE' using errcode='PT409'; end if;
 next_role:=m.role; next_status:=m.status;
 if p_operation in ('add','reactivate') and not public.onboarding_admin_eligible_core_v1(p_user_id) then
  raise exception 'ACCOUNT_UNAVAILABLE' using errcode='22023'; end if;
 if p_operation='add' then
  if m.status='pending' then raise exception 'MEMBERSHIP_PENDING' using errcode='55000'; end if;
  if m.status='suspended' then raise exception 'MEMBERSHIP_SUSPENDED' using errcode='55000'; end if;
  next_role:='admin'; next_status:='active';
 elsif p_operation='reactivate' then
  if m.role is distinct from 'admin' then raise exception 'NOT_TENANT_ADMIN' using errcode='55000'; end if;
  if m.status='pending' then raise exception 'MEMBERSHIP_PENDING' using errcode='55000'; end if;
  next_status:='active';
 elsif p_operation='demote' then
  if m.role is distinct from 'admin' or m.status<>'active' then raise exception 'NOT_ACTIVE_TENANT_ADMIN' using errcode='55000'; end if;
  next_role:='user';
 else
  if m.role is distinct from 'admin' or m.status not in ('active','suspended') then raise exception 'NOT_TENANT_ADMIN' using errcode='55000'; end if;
  next_status:='suspended';
 end if;
 changed:=m.role is distinct from next_role or m.status is distinct from next_status;
 if changed then
  insert into public.tenant_memberships(tenant_id,user_id,role,status) values(p_tenant_id,p_user_id,next_role,next_status)
   on conflict(tenant_id,user_id) do update set role=excluded.role,status=excluded.status,updated_at=transaction_timestamp();
  insert into public.platform_audit_logs(actor_user_id,tenant_id,action,details)
  values(actor,p_tenant_id,'tenant_admin_'||p_operation,jsonb_build_object('target_user_id',p_user_id,
   'before',state_value,'after',jsonb_build_object('role',next_role,'status',next_status),'request_id',p_request_id));
 end if;
 result_value:=jsonb_build_object('code',case when changed then 'changed' else 'no_change' end,'user_id',p_user_id,'role',next_role,'status',next_status);
 insert into public.platform_admin_management_requests(actor_user_id,request_id,tenant_id,payload,result)
 values(actor,p_request_id,p_tenant_id,payload_value,result_value);
 return result_value;
end;$$;

do $install$
declare operation text; signature text;
begin
 foreach operation in array array['add','reactivate','demote','suspend'] loop
  execute format('create function public.platform_%s_tenant_admin_v1(p_tenant_id uuid,p_user_id uuid,p_expected_state jsonb,p_request_id uuid) returns jsonb language sql security definer set search_path=pg_catalog,public,pg_temp as %L',
   operation,format('select public.platform_tenant_admin_mutation_core_v1(p_tenant_id,p_user_id,%L,p_expected_state,p_request_id)',operation));
 end loop;
 foreach signature in array array['tenant_assert_admin_loss_core_v1(uuid,uuid)','tenant_instructor_has_open_obligations_v1(uuid,uuid)',
  'guard_tenant_admin_lifecycle_v1()','platform_get_tenant_admin_management_v1(uuid)',
  'platform_tenant_admin_mutation_core_v1(uuid,uuid,text,jsonb,uuid)',
  'platform_add_tenant_admin_v1(uuid,uuid,jsonb,uuid)','platform_reactivate_tenant_admin_v1(uuid,uuid,jsonb,uuid)',
  'platform_demote_tenant_admin_v1(uuid,uuid,jsonb,uuid)','platform_suspend_tenant_admin_v1(uuid,uuid,jsonb,uuid)'] loop
  execute 'alter function public.'||signature||' owner to postgres';
  execute 'revoke all on function public.'||signature||' from public,anon,authenticated,service_role';
 end loop;
end;$install$;
grant execute on function public.platform_get_tenant_admin_management_v1(uuid),
 public.platform_add_tenant_admin_v1(uuid,uuid,jsonb,uuid),public.platform_reactivate_tenant_admin_v1(uuid,uuid,jsonb,uuid),
 public.platform_demote_tenant_admin_v1(uuid,uuid,jsonb,uuid),public.platform_suspend_tenant_admin_v1(uuid,uuid,jsonb,uuid) to authenticated;

-- Keep existing transport/PII behavior; centralize only admin-loss predicate.
CREATE OR REPLACE FUNCTION public.admin_set_user_role_v2(p_tenant_id uuid, p_target_user_id uuid, p_new_role text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
declare
  v_actor_id uuid:=auth.uid();
  v_tenant_id uuid:=p_tenant_id;
  v_new_legacy_role text:=pg_catalog.lower(pg_catalog.btrim(p_new_role));
  v_new_tenant_role text;
  v_current_tenant_role text;
  v_current_legacy_role text;
  v_admin_count bigint;
  v_changed_at timestamptz:=pg_catalog.transaction_timestamp();
begin
  -- PRODUCT-10D entitlement guard
  if not public.get_my_tenant_feature_access_v1(p_tenant_id,'staff') then
    raise exception using errcode='42501',message='feature_not_available';
  end if;
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
    begin
      perform public.tenant_assert_admin_loss_core_v1(v_tenant_id,p_target_user_id);
    exception when check_violation then
      if sqlerrm<>'LAST_ACTIVE_ADMIN' then raise; end if;
      return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','last_admin','target_user_id',p_target_user_id,'role',v_current_legacy_role);
    end;
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

CREATE OR REPLACE FUNCTION public.anonymize_my_account_v1()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
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
      perform public.tenant_assert_admin_loss_core_v1(v_membership.tenant_id,v_user_id);
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

  update public.platform_audit_logs entry set
    actor_user_id=case when entry.actor_user_id=v_user_id then v_pseudonym_id else entry.actor_user_id end,
    details=public.redact_account_audit_details_v1(entry.details,v_user_id,v_pseudonym,v_direct_values)
  where entry.actor_user_id=v_user_id or entry.details->>'user_id'=v_user_id::text;
  update public.external_settlement_records entry set
    actor_user_id=case when entry.actor_user_id=v_user_id then v_pseudonym_id else entry.actor_user_id end,
    external_reference='[redacted]'
  where entry.actor_user_id=v_user_id or entry.reservation_id=any(v_reservation_ids) or entry.registration_id=any(v_registration_ids);
  delete from public.platform_admins where user_id=v_user_id;
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
$function$;;

alter table public.platform_audit_logs drop constraint platform_audit_logs_action_check;
alter table public.platform_audit_logs add constraint platform_audit_logs_action_check check(action in (
 'tenant_created','plan_assigned','plan_changed','tenant_admin_assigned','tenant_activated','tenant_suspended',
 'tenant_published','tenant_unpublished','platform_admin_bootstrapped','domain_added','domain_verification_started',
 'domain_verified','domain_activated','domain_disabled','primary_domain_changed',
 'tenant_admin_add','tenant_admin_reactivate','tenant_admin_demote','tenant_admin_suspend'));
