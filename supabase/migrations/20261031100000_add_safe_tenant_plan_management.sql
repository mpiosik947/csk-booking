-- PAM-1A. Forward-only, no business data deletion or public flag changes.
set lock_timeout='5s';
set statement_timeout='60s';

alter table public.tenant_plan_assignments add column revision bigint not null default 1
  check (revision > 0);
create table public.platform_plan_change_requests (
  actor_user_id uuid not null,
  change_request_id uuid not null,
  tenant_id uuid not null references public.tenants(id) on delete restrict,
  payload jsonb not null,
  result jsonb not null,
  created_at timestamptz not null default transaction_timestamp(),
  primary key(actor_user_id,change_request_id)
);
alter table public.platform_plan_change_requests enable row level security;
revoke all on public.platform_plan_change_requests from public,anon,authenticated,service_role;

-- Closed lifecycle projection; no worker/scheduler or delivery data is changed.
-- Legacy confirmation retries reset after 24h. Bounded receipts/notices use
-- the existing 23h window; reminder claims have no such window.
create function public.plan_change_email_is_open_v1(p_delivery public.email_deliveries)
returns boolean language sql stable set search_path='pg_catalog','public','pg_temp' as $function$
 select case
  when p_delivery.sent_at is not null or p_delivery.delivery_state='sent' then false
  when p_delivery.claim_id is not null and p_delivery.claim_expires_at>statement_timestamp() then true
  when p_delivery.message_type='event_registration_confirmation' then true
  when p_delivery.message_type='event_reminder_24h' then
   p_delivery.delivery_state in ('pending','sending','failed') and p_delivery.attempt_count<3
   and coalesce(p_delivery.last_error_code,'')<>'ineligible'
  when p_delivery.message_type in ('event_reserve_acceptance_confirmation','event_registration_cancellation',
    'event_cancellation','instructor_assignment','instructor_removal','instructor_event_cancellation') then
   p_delivery.delivery_state in ('pending','sending','failed') and p_delivery.attempt_count<3
   and (p_delivery.attempt_window_started_at is null
     or p_delivery.attempt_window_started_at>statement_timestamp()-interval '23 hours')
  else false end;
$function$;
alter function public.plan_change_email_is_open_v1(public.email_deliveries) owner to postgres;
revoke all on function public.plan_change_email_is_open_v1(public.email_deliveries) from public,anon,authenticated,service_role;

-- Closed aggregate projection. Called only by the PA reader/writer below.
create function public.tenant_plan_change_preview_core_v1(p_tenant_id uuid,p_target_plan_key text)
returns jsonb language plpgsql stable set search_path='pg_catalog','public','pg_temp' as $function$
declare
 t public.tenants; a public.tenant_plan_assignments; target public.saas_plans;
 old_key text; old_features text[]:='{}'; new_features text[]:='{}'; added text[]; removed text[];
 blockers jsonb:='[]'; warnings jsonb:='[]'; n bigint; exposed boolean; feature text;
 moment timestamp:=statement_timestamp() at time zone 'Europe/Warsaw';
begin
 if p_tenant_id is null or p_target_plan_key is null or p_target_plan_key !~ '^[a-z][a-z0-9_]{1,62}$' then
  raise exception 'Invalid plan selector' using errcode='22023'; end if;
 select * into t from public.tenants where id=p_tenant_id;
 if not found or t.status not in ('dormant','active','suspended') then
  raise exception 'Tenant unavailable' using errcode='22023'; end if;
 select * into a from public.tenant_plan_assignments where tenant_id=t.id;
 select p.plan_key into old_key from public.saas_plans p where p.id=a.plan_id;
 if a.status='active' then
  select coalesce(array_agg(f.feature_key order by f.feature_key),'{}') into old_features
   from public.saas_plan_features pf join public.saas_features f using(feature_key)
   join public.saas_plans p on p.id=pf.plan_id and p.status='active'
   where pf.plan_id=a.plan_id and f.active;
 end if;
 select * into target from public.saas_plans where plan_key=p_target_plan_key;
 if target.id is null or target.status<>'active' then
  blockers:=jsonb_build_array(jsonb_build_object('code',case when target.id is null then 'TARGET_PLAN_UNKNOWN' else 'TARGET_PLAN_INACTIVE' end,'reason','Target plan is unavailable.'));
 else
  select coalesce(array_agg(f.feature_key order by f.feature_key),'{}') into new_features
   from public.saas_plan_features pf join public.saas_features f using(feature_key)
   where pf.plan_id=target.id and f.active;
 end if;
 select coalesce(array_agg(x order by x),'{}') into added from unnest(new_features) x where not x=any(old_features);
 select coalesce(array_agg(x order by x),'{}') into removed from unnest(old_features) x where not x=any(new_features);
 if target.status='active' and (a.plan_id is distinct from target.id or a.status is distinct from 'active') then
  foreach feature in array removed loop
   n:=0;
   if feature='events' then
    -- Closed history (including marked attendance) is not an eternal blocker.
    select count(*) into n from public.events e where e.tenant_id=t.id and e.cancelled_at is null
     and e.is_active and e.event_date+e.end_time>=moment;
    if n>0 then blockers:=blockers||jsonb_build_array(jsonb_build_object('code','EVENTS_OPEN','feature_key',feature,'count',n,'reason','Future active events need management.')); end if;
    select count(*) into n from public.event_registrations r join public.events e on e.id=r.event_id and e.tenant_id=r.tenant_id
     where r.tenant_id=t.id and r.registration_status in ('registered','approved','reserve','participant')
     and e.cancelled_at is null and (e.event_date+e.end_time>=moment or r.attendance_status='unmarked');
    if n>0 then blockers:=blockers||jsonb_build_array(jsonb_build_object('code','EVENT_REGISTRATIONS_OPEN','feature_key',feature,'count',n,'reason','Registrations, waitlist or attendance remain unresolved.')); end if;
    select count(*) into n from public.email_deliveries d where d.tenant_id=t.id
     and d.message_type in ('event_registration_confirmation','event_reserve_acceptance_confirmation','event_registration_cancellation','event_cancellation','event_reminder_24h','instructor_assignment','instructor_removal','instructor_event_cancellation')
     and public.plan_change_email_is_open_v1(d);
    if n>0 then blockers:=blockers||jsonb_build_array(jsonb_build_object('code','EVENT_EMAIL_OBLIGATIONS','feature_key',feature,'count',n,'reason','Operational event mail remains unresolved.')); end if;
   elsif feature='staff' then
    select count(*) into n from public.tenant_memberships m where m.tenant_id=t.id and m.role='employee' and m.status='active';
    if n>0 then blockers:=blockers||jsonb_build_array(jsonb_build_object('code','STAFF_ACTIVE','feature_key',feature,'count',n,'reason','Active employees would lose management tools.')); end if;
   elsif feature='checkin' then
    select count(*) into n from public.reservations r where r.tenant_id=t.id and r.reservation_status='confirmed'
     and coalesce(r.attendance_status,'planned') in ('planned','present') and r.completed_at is null;
    if n>0 then blockers:=blockers||jsonb_build_array(jsonb_build_object('code','CHECKIN_OBLIGATION','feature_key',feature,'count',n,'reason','Reservation attendance remains unresolved.')); end if;
   elsif feature='lane_blocks' then
    select count(*) into n from public.lane_blocks b where b.tenant_id=t.id and b.is_active and b.block_date+b.end_time>=moment;
    if n>0 then blockers:=blockers||jsonb_build_array(jsonb_build_object('code','LANE_BLOCKS_ACTIVE','feature_key',feature,'count',n,'reason','Current or future lane blocks need management.')); end if;
   elsif feature in ('reports','advanced_calendar','branding') then
    warnings:=warnings||jsonb_build_array(jsonb_build_object('code','CAPABILITY_REMOVED','feature_key',feature,'reason','Capability becomes unavailable; retained records and baseline tenant identity are unchanged.'));
   elsif feature='booking' then
    select count(*) into n from public.reservations r where r.tenant_id=t.id and r.reservation_status='confirmed';
    if n>0 then blockers:=blockers||jsonb_build_array(jsonb_build_object('code','BOOKING_OBLIGATIONS','feature_key',feature,'count',n,'reason','Existing bookings need management.')); end if;
   end if;
  end loop;
  if 'events'=any(removed) or 'instructors'=any(removed) then
   select count(*) into n from public.event_instructors i join public.events e on e.id=i.event_id and e.tenant_id=i.tenant_id
    where i.tenant_id=t.id and i.unassigned_at is null and e.cancelled_at is null and e.event_date+e.end_time>=moment;
   if n>0 then blockers:=blockers||jsonb_build_array(jsonb_build_object('code','INSTRUCTORS_ACTIVE','feature_key','instructors','count',n,'reason','Future instructor assignments need management.')); end if;
   select count(*) into n from public.email_deliveries d where d.tenant_id=t.id
    and d.message_type in ('instructor_assignment','instructor_removal','instructor_event_cancellation')
    and public.plan_change_email_is_open_v1(d);
   if n>0 then blockers:=blockers||jsonb_build_array(jsonb_build_object('code','INSTRUCTOR_OBLIGATIONS','feature_key','instructors','count',n,'reason','Instructor notices remain unresolved.')); end if;
  end if;
  -- Strict no-grandfathering also covers inconsistent assignments with no old feature.
  if not 'custom_domain'=any(new_features) then
   select count(*) into n from public.tenant_domains d where d.tenant_id=t.id and d.domain_type='custom_domain' and (d.status='active' or d.is_primary);
   if n>0 then blockers:=blockers||jsonb_build_array(jsonb_build_object('code','CUSTOM_DOMAIN_ACTIVE','feature_key','custom_domain','count',n,'reason','Disable the custom domain before changing plan.')); end if;
  end if;
  foreach feature in array added loop
   select exists(select 1 from public.tenant_public_profiles p where p.tenant_id=t.id and
    case feature when 'events' then p.show_events when 'instructors' then p.show_instructor
     when 'booking' then p.show_booking or p.show_pricing else false end) into exposed;
   if exposed then
    warnings:=warnings||jsonb_build_array(jsonb_build_object('code','RETAINED_PUBLIC_FLAGS','feature_key',feature,'reason','Retained visibility settings require explicit review.'));
    if t.status='active' and exists(select 1 from public.tenant_public_profiles p where p.tenant_id=t.id and p.is_public) then
     blockers:=blockers||jsonb_build_array(jsonb_build_object('code','PUBLIC_REEXPOSURE','feature_key',feature,'reason','Disable retained visibility flags or unpublish before enabling capability.'));
    end if;
   end if;
  end loop;
  if 'custom_domain'=any(added) and t.status='active' and exists(select 1 from public.tenant_public_profiles p where p.tenant_id=t.id and p.is_public)
   and exists(select 1 from public.tenant_domains d where d.tenant_id=t.id and d.domain_type='custom_domain' and (d.status='active' or d.is_primary)) then
   blockers:=blockers||jsonb_build_array(jsonb_build_object('code','DOMAIN_REEXPOSURE','feature_key','custom_domain','reason','Disable the retained domain before enabling public routing.'));
  end if;
 end if;
 return jsonb_build_object('tenant',jsonb_build_object('tenant_id',t.id,'name',t.name,'status',t.status),
  'current_plan',case when a.tenant_id is null then null else jsonb_build_object('plan_key',old_key,'assignment_status',a.status,'enabled_feature_keys',old_features) end,
  'target_plan',jsonb_build_object('plan_key',p_target_plan_key,'enabled_feature_keys',new_features),
  'features_added',added,'features_removed',removed,'blockers',blockers,'warnings',warnings,
  'can_apply',jsonb_array_length(blockers)=0,'revision',coalesce(a.revision,0)::text);
end;$function$;
revoke all on function public.tenant_plan_change_preview_core_v1(uuid,text) from public,anon,authenticated,service_role;

create function public.platform_get_tenant_plan_change_preview_v1(p_tenant_id uuid,p_target_plan_key text)
returns jsonb language plpgsql stable security definer set search_path='pg_catalog','public','pg_temp' as $function$
begin
 if not public.is_platform_admin_v1() then raise exception 'Not authorized' using errcode='42501'; end if;
 return public.tenant_plan_change_preview_core_v1(p_tenant_id,p_target_plan_key);
end;$function$;

create function public.platform_change_tenant_plan_v2(p_tenant_id uuid,p_target_plan_key text,p_expected_revision text,p_change_request_id uuid)
returns jsonb language plpgsql security definer set search_path='pg_catalog','public','pg_temp' as $function$
declare actor uuid:=auth.uid(); prior public.platform_plan_change_requests; a public.tenant_plan_assignments;
 selected_plan uuid; old_key text; payload_value jsonb; preview jsonb; result_value jsonb;
begin
 if not public.is_platform_admin_v1() then raise exception 'Not authorized' using errcode='42501'; end if;
 perform 1 from public.platform_admins where user_id=actor and status='active' for share nowait;
 if not found then raise exception 'Not authorized' using errcode='42501'; end if;
 if p_tenant_id is null or p_target_plan_key is null or p_target_plan_key !~ '^[a-z][a-z0-9_]{1,62}$'
  or p_expected_revision is null or p_expected_revision !~ '^(0|[1-9][0-9]{0,18})$'
  or p_change_request_id is null or p_change_request_id='00000000-0000-0000-0000-000000000000'::uuid then
  raise exception 'Invalid plan change' using errcode='22023'; end if;
 payload_value:=jsonb_build_object('tenant_id',p_tenant_id,'target_plan_key',p_target_plan_key,'expected_revision',p_expected_revision);
 perform pg_advisory_xact_lock(hashtextextended(actor::text||':'||p_change_request_id::text,311000));
 select * into prior from public.platform_plan_change_requests where actor_user_id=actor and change_request_id=p_change_request_id;
 if found then
  if prior.payload<>payload_value then raise exception 'Plan request payload conflict' using errcode='22023'; end if;
  return prior.result;
 end if;
 -- No resource locks after this barrier. Business triggers use SHARE NOWAIT to avoid inversion.
 perform 1 from public.tenants where id=p_tenant_id and status in ('dormant','active','suspended') for no key update;
 if not found then raise exception 'Tenant unavailable' using errcode='22023'; end if;
 select * into a from public.tenant_plan_assignments where tenant_id=p_tenant_id for update;
 if coalesce(a.revision,0)::text<>p_expected_revision then raise exception 'PLAN_STALE' using errcode='PT409'; end if;
 perform 1 from public.saas_plans order by id for share nowait;
 perform 1 from public.saas_plan_features order by plan_id,feature_key for share nowait;
 perform 1 from public.saas_features order by feature_key for share nowait;
 select id into selected_plan from public.saas_plans where plan_key=p_target_plan_key and status='active';
 if not found then raise exception 'Target plan unavailable' using errcode='22023'; end if;
 preview:=public.tenant_plan_change_preview_core_v1(p_tenant_id,p_target_plan_key);
 if not (preview->>'can_apply')::boolean then
  raise exception 'Plan change blocked' using errcode='55000',detail=(preview->'blockers')::text;
 end if;
 select plan_key into old_key from public.saas_plans where id=a.plan_id;
 if a.plan_id=selected_plan and a.status='active' then
  result_value:=jsonb_build_object('code','no_change','plan_key',p_target_plan_key,'revision',a.revision::text);
 else
  insert into public.tenant_plan_assignments(tenant_id,plan_id,status)values(p_tenant_id,selected_plan,'active')
   on conflict(tenant_id) do update set plan_id=excluded.plan_id,status='active',assigned_at=transaction_timestamp(),revision=public.tenant_plan_assignments.revision+1;
  select revision into a.revision from public.tenant_plan_assignments where tenant_id=p_tenant_id;
  result_value:=jsonb_build_object('code','changed','plan_key',p_target_plan_key,'revision',a.revision::text);
  insert into public.platform_audit_logs(actor_user_id,tenant_id,action,details)
   values(actor,p_tenant_id,case when old_key is null then 'plan_assigned' else 'plan_changed' end,
    jsonb_build_object('old_plan_key',old_key,'new_plan_key',p_target_plan_key,'change_request_id',p_change_request_id,'revision',a.revision));
 end if;
 insert into public.platform_plan_change_requests(actor_user_id,change_request_id,tenant_id,payload,result)
  values(actor,p_change_request_id,p_tenant_id,payload_value,result_value);
 return result_value;
end;$function$;
alter function public.tenant_plan_change_preview_core_v1(uuid,text) owner to postgres;
alter function public.platform_get_tenant_plan_change_preview_v1(uuid,text) owner to postgres;
alter function public.platform_change_tenant_plan_v2(uuid,text,text,uuid) owner to postgres;
revoke all on function public.platform_get_tenant_plan_change_preview_v1(uuid,text),public.platform_change_tenant_plan_v2(uuid,text,text,uuid) from public,anon,authenticated,service_role;
grant execute on function public.platform_get_tenant_plan_change_preview_v1(uuid,text),public.platform_change_tenant_plan_v2(uuid,text,text,uuid) to authenticated;
-- Compatibility-only transport for the deployed UI. It does not accept or
-- promise client revision/request-id semantics; v2 remains the full contract.
-- A private per-call request UUID avoids inventing parameters in the old API.
-- Safety, assignment revision and audit are implemented only by v2.
create or replace function public.platform_set_tenant_plan_v1(p_tenant_id uuid,p_plan_key text)
returns void language plpgsql security definer set search_path='pg_catalog','public','pg_temp' as $function$
declare revision_value text;
begin
 if not public.is_platform_admin_v1() then raise exception 'Not authorized' using errcode='42501'; end if;
 perform 1 from public.platform_admins where user_id=auth.uid() and status='active' for share nowait;
 if not found then raise exception 'Not authorized' using errcode='42501'; end if;
 if p_tenant_id is null or p_plan_key is null or p_plan_key !~ '^[a-z][a-z0-9_]{1,62}$' then
  raise exception 'Invalid plan selector' using errcode='22023'; end if;
 perform 1 from public.tenants where id=p_tenant_id and status in ('dormant','active','suspended') for no key update;
 if not found then raise exception 'Tenant unavailable' using errcode='22023'; end if;
 select revision::text into revision_value from public.tenant_plan_assignments where tenant_id=p_tenant_id;
 perform public.platform_change_tenant_plan_v2(p_tenant_id,p_plan_key,coalesce(revision_value,'0'),gen_random_uuid());
end;$function$;
alter function public.platform_set_tenant_plan_v1(uuid,text) owner to postgres;
grant execute on function public.platform_set_tenant_plan_v1(uuid,text) to authenticated;

-- Preserve the existing feature/continuity rules; add a fail-fast plan admission barrier.
create or replace function public.enforce_tenant_feature_write_v1()
returns trigger language plpgsql security definer set search_path='pg_catalog','public','pg_temp' as $function$
declare v_feature text; v_tenant uuid; v_requires boolean:=true;
begin
 if session_user='postgres' and current_setting('app.product10d_test_enforce',true) is distinct from 'on' then return coalesce(new,old); end if;
 v_tenant:=coalesce(new.tenant_id,old.tenant_id);
 if v_tenant is not null then perform 1 from public.tenants where id=v_tenant for share nowait; end if;
 if tg_table_name='tenant_domains' then
  if tg_op<>'DELETE' and new.domain_type='custom_domain' and
   (tg_op='INSERT' or (new.status='active' and old.status is distinct from new.status) or (new.is_primary and not coalesce(old.is_primary,false)))
   and not public.tenant_setup_has_feature_core_v1(v_tenant,'custom_domain') then
   raise exception 'feature_not_available' using errcode='42501'; end if;
  return coalesce(new,old);
 elsif tg_table_name='reservations' then
  if tg_op<>'INSERT' then return new; end if; v_feature:='booking';
 elsif tg_table_name='event_registrations' then
  if tg_op<>'INSERT' then return new; end if; v_feature:='events';
 elsif tg_table_name='events' then
  if tg_op='DELETE' or (tg_op='UPDATE' and old.is_active and not new.is_active) then return coalesce(new,old); end if; v_feature:='events';
 elsif tg_table_name='lane_blocks' then
  if tg_op='DELETE' or (tg_op='UPDATE' and not new.is_active) then return coalesce(new,old); end if; v_feature:='lane_blocks';
 elsif tg_table_name='shooting_lanes' then
  if public.tenant_draft_setup_role_core_v1(v_tenant)='admin' then return coalesce(new,old); end if;
  if tg_op='DELETE' or (tg_op='UPDATE' and old.is_active and not new.is_active) then return coalesce(new,old); end if; v_feature:='booking';
 else v_requires:=false;
 end if;
 if v_requires and not public.tenant_has_feature_v1(v_tenant,v_feature) then raise exception 'feature_not_available' using errcode='42501'; end if;
 return coalesce(new,old);
end;$function$;
-- Existing feature triggers cover events/reservations/registrations/blocks/lanes.
-- These additional resources can change preview blockers or public exposure.
create trigger pam_plan_admission before insert or update or delete on public.tenant_memberships for each row execute function public.enforce_tenant_feature_write_v1();
create trigger pam_plan_admission before insert or update or delete on public.event_instructors for each row execute function public.enforce_tenant_feature_write_v1();
create trigger pam_plan_admission before insert or update or delete on public.email_deliveries for each row execute function public.enforce_tenant_feature_write_v1();
create trigger pam_plan_admission before insert or update or delete on public.tenant_public_profiles for each row execute function public.enforce_tenant_feature_write_v1();
create trigger pam_plan_admission before insert or update or delete on public.tenant_domains for each row execute function public.enforce_tenant_feature_write_v1();

create or replace function public.resolve_public_tenant_domain_v1(p_hostname text)
returns jsonb language sql stable security definer set search_path='pg_catalog','public','pg_temp' as $function$
 select jsonb_build_object('tenant_slug',t.slug,'public_slug',p.public_slug)
 from public.tenant_domains d join public.tenants t on t.id=d.tenant_id join public.tenant_public_profiles p on p.tenant_id=t.id
 where d.hostname=p_hostname and d.status='active' and d.verified_at is not null and t.status='active' and p.is_public
  and (d.domain_type<>'custom_domain' or public.tenant_has_feature_v1(t.id,'custom_domain'));
$function$;

create or replace function public.get_public_tenant_primary_domain_v1(p_public_slug text)
returns text language sql stable security definer set search_path='pg_catalog','public','pg_temp' as $function$
 select d.hostname from public.tenant_public_profiles p join public.tenants t on t.id=p.tenant_id join public.tenant_domains d on d.tenant_id=t.id
 where p.public_slug=p_public_slug and p.is_public and t.status='active' and d.status='active' and d.is_primary and d.verified_at is not null
  and (d.domain_type<>'custom_domain' or public.tenant_has_feature_v1(t.id,'custom_domain'));
$function$;
