-- SYNTB-001-R2: globally unique, tenant-bound concurrency revisions.
-- Keep deployed bigint lifecycle / decimal-text plan RPC signatures unchanged.
-- Supabase CLI executes the file and ledger insert in one implicit transaction
-- batch, without an explicit BEGIN block. Acquire locks inside DO so PostgreSQL
-- accepts LOCK TABLE in that context; they remain held until the batch commits.
-- Do not add COMMIT here: that would split schema changes from the ledger write.
set lock_timeout='5s';
set statement_timeout='60s';
do $revision_cutover_lock$
begin
 lock table public.tenants,public.tenant_plan_assignments in access exclusive mode;
end
$revision_cutover_lock$;

-- No existing application-private schema exists. Keep infrastructure schemas
-- separate and preserve SEC-002B: public must contain no sequences.
create schema app_private authorization postgres;
revoke all on schema app_private from public,anon,authenticated,service_role;

-- One WAL-logged allocator shared by both revision domains. Start above every
-- previously persisted/issued counter, including retained idempotency receipts.
-- CACHE 1 / NO CYCLE: no recycling on rollback or after exhaustion; no table-wide
-- runtime tenant lock. Only postgres-owned trigger code can allocate values.
do $$declare ceiling bigint; rows_needed bigint;begin
 select greatest(
  coalesce((select max(lifecycle_revision) from public.tenants),0),
  coalesce((select max(revision) from public.tenant_plan_assignments),0),
  coalesce((select max((payload->>'revision')::bigint) from public.platform_tenant_lifecycle_requests),0),
  coalesce((select max((result->>'revision')::bigint) from public.platform_tenant_lifecycle_requests),0),
  coalesce((select max((payload->>'expected_revision')::bigint) from public.platform_plan_change_requests),0),
  coalesce((select max((result->>'revision')::bigint) from public.platform_plan_change_requests),0)
 ) into ceiling;
 select (select count(*) from public.tenants)+(select count(*) from public.tenant_plan_assignments) into rows_needed;
 if ceiling::numeric+rows_needed+1>9007199254740991 then
  raise exception 'Concurrency revision capacity exceeded' using errcode='22003';
 end if;
 execute format('create sequence app_private.tenant_concurrency_revision_seq as bigint minvalue 1 maxvalue 9007199254740991 start with %s increment by 1 no cycle cache 1',ceiling+1);
end$$;
alter sequence app_private.tenant_concurrency_revision_seq owner to postgres;
revoke all on sequence app_private.tenant_concurrency_revision_seq from public,anon,authenticated,service_role;

-- One-time bridge for already-restored dormant history. Existing audit/request
-- receipts stay byte-for-byte unchanged. The marker is retained only until the
-- next lifecycle transition and cannot be supplied/changed by a table caller.
alter table public.tenants add column lifecycle_restore_revision bigint;
comment on column public.tenants.lifecycle_restore_revision is
 'Concurrency migration continuity marker; cleared on lifecycle/identity change. Not an authorization token.';

-- The exclusive transaction prevents any concurrent writer entering this brief
-- trigger replacement. Rebind concurrency metadata only, never business state.
drop trigger tenant_archive_state_guard on public.tenants;
-- Preserve business timestamps during the metadata-only rebind under the same
-- exclusive transaction; normal timestamp behavior resumes before releasing it.
alter table public.tenants disable trigger set_tenants_updated_at;
with allocated as materialized (
 select id,nextval('app_private.tenant_concurrency_revision_seq') token,
  public.tenant_has_restored_history_core_v1(id) restored
 from public.tenants order by id
)
update public.tenants t set lifecycle_revision=a.token,
 lifecycle_restore_revision=case when a.restored then a.token else null end
from allocated a where t.id=a.id;
alter table public.tenants enable trigger set_tenants_updated_at;
update public.tenant_plan_assignments set revision=nextval('app_private.tenant_concurrency_revision_seq');
alter table public.tenants add constraint tenants_lifecycle_revision_unique unique(lifecycle_revision);
alter table public.tenant_plan_assignments add constraint tenant_plan_assignments_revision_unique unique(revision);

-- Reuse the closed, existing SECURITY DEFINER guard for the two revision sources;
-- no new callable RPC, role, EXECUTE grant, or authorization bypass is introduced.
create or replace function public.guard_tenant_archive_state_v1() returns trigger
language plpgsql security definer set search_path=pg_catalog,public,pg_temp as $$
begin
 if tg_table_name='tenant_plan_assignments' then
  if tg_op='INSERT' then new.revision:=nextval('app_private.tenant_concurrency_revision_seq');
  elsif (new.tenant_id,new.plan_id,new.status) is distinct from (old.tenant_id,old.plan_id,old.status) then
   new.revision:=nextval('app_private.tenant_concurrency_revision_seq');
  else new.revision:=old.revision;end if;
  return new;
 end if;
 if tg_op='INSERT' then
  new.lifecycle_revision:=nextval('app_private.tenant_concurrency_revision_seq');
  new.lifecycle_restore_revision:=null;
  return new;
 end if;
 if old.status='archived' and new.status not in ('archived','dormant') then
  raise exception 'TENANT_STATE_CONFLICT' using errcode='55000';end if;
 if (new.id,new.status) is distinct from (old.id,old.status) then
  new.lifecycle_revision:=nextval('app_private.tenant_concurrency_revision_seq');
  new.lifecycle_restore_revision:=null;
 else
  new.lifecycle_revision:=old.lifecycle_revision;
  new.lifecycle_restore_revision:=old.lifecycle_restore_revision;
 end if;
 if new.status='archived' and exists(select 1 from public.tenant_public_profiles where tenant_id=new.id and is_public) then
  raise exception 'TENANT_PUBLICATION_CONFLICT' using errcode='55000';end if;
 return new;
end$$;
create trigger tenant_archive_state_guard before insert or update on public.tenants
 for each row execute function public.guard_tenant_archive_state_v1();
create trigger tenant_plan_revision_guard before insert or update on public.tenant_plan_assignments
 for each row execute function public.guard_tenant_archive_state_v1();

create or replace function public.tenant_has_restored_history_core_v1(p_tenant_id uuid) returns boolean
language sql stable set search_path=pg_catalog,public,pg_temp as $$
 select exists(select 1 from public.tenants t where t.id=p_tenant_id and t.status='dormant'
 and (t.lifecycle_restore_revision=t.lifecycle_revision or exists(
  select 1 from public.platform_tenant_lifecycle_requests r where r.tenant_id=t.id
  and r.payload->>'operation'='restore' and r.result->>'status'='dormant'
  and r.result->>'revision'=t.lifecycle_revision::text)));
$$;

-- Missing plan assignments use the already-unique tenant lifecycle revision,
-- never the globally ambiguous legacy sentinel 0. All existing writer paths
-- converge on v2; activation continues its unchanged target-row pre-lock check.
CREATE OR REPLACE FUNCTION public.tenant_plan_change_preview_core_v1(p_tenant_id uuid, p_target_plan_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
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
  'can_apply',jsonb_array_length(blockers)=0,'revision',coalesce(a.revision,t.lifecycle_revision)::text);
end;$function$;

CREATE OR REPLACE FUNCTION public.platform_change_tenant_plan_v2(p_tenant_id uuid, p_target_plan_key text, p_expected_revision text, p_change_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
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
 if coalesce(a.revision,(select lifecycle_revision from public.tenants where id=p_tenant_id))::text<>p_expected_revision then raise exception 'PLAN_STALE' using errcode='PT409'; end if;
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
   on conflict(tenant_id) do update set plan_id=excluded.plan_id,status='active',assigned_at=transaction_timestamp();
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

CREATE OR REPLACE FUNCTION public.platform_set_tenant_plan_v1(p_tenant_id uuid, p_plan_key text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
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
 perform public.platform_change_tenant_plan_v2(p_tenant_id,p_plan_key,coalesce(revision_value,(select lifecycle_revision::text from public.tenants where id=p_tenant_id)),gen_random_uuid());
end;$function$;

-- PAM-1D catalog pin updated only for the reviewed concurrency metadata delta.
CREATE OR REPLACE FUNCTION public.platform_get_tenant_delete_eligibility_v1(p_tenant_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
declare
 t public.tenants; catalog jsonb; summary jsonb:='{}'; blockers jsonb;
 is_public_value boolean; catalog_matches boolean;
begin
 if not public.is_platform_admin_v1() then raise exception 'Not authorized' using errcode='42501'; end if;
 select * into t from public.tenants where id=p_tenant_id;
 if not found then raise exception 'TENANT_UNAVAILABLE' using errcode='22023'; end if;
 -- Deliberate policy blocker even for a physically empty synthetic tenant.
 -- This read is not a lock, deletion token, or authorization for future deletion.
 blockers:=jsonb_build_array(jsonb_build_object('code','HARD_DELETE_POLICY_DEFERRED','category','policy','count',1,'hard_blocker',true));
 if t.status<>'archived' then blockers:=blockers||jsonb_build_array(jsonb_build_object('code','TENANT_NOT_ARCHIVED','category','lifecycle','count',1,'hard_blocker',true)); end if;
 select jsonb_build_object(
 'tables',(select jsonb_agg(n.nspname||'.'||c.relname order by n.nspname,c.relname) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind in('r','p')),
 'columns',(select jsonb_agg(n.nspname||'.'||c.relname||'.'||a.attname||':'||format_type(a.atttypid,a.atttypmod) order by n.nspname,c.relname,a.attnum) from pg_class c join pg_namespace n on n.oid=c.relnamespace join pg_attribute a on a.attrelid=c.oid where n.nspname='public' and c.relkind in('r','p') and a.attnum>0 and not a.attisdropped),
 'foreign_keys',(select jsonb_agg(n.nspname||'.'||c.relname||'.'||k.conname||':'||pg_get_constraintdef(k.oid) order by n.nspname,c.relname,k.conname) from pg_constraint k join pg_class c on c.oid=k.conrelid join pg_namespace n on n.oid=c.relnamespace join pg_class parent on parent.oid=k.confrelid join pg_namespace pn on pn.oid=parent.relnamespace where k.contype='f' and (n.nspname='public' or pn.nspname='public'))
) into catalog;

 catalog_matches:=md5(catalog::text)='680133347514c33a103736d5af7615fe';
 if not catalog_matches then
  -- Do not execute stale table/column queries if the catalog contract has changed.
  return jsonb_build_object('tenant',jsonb_build_object('tenant_id',t.id,'name',t.name,'status',t.status),
   'lifecycle',jsonb_build_object('is_archived',t.status='archived','is_public',null),
   'eligibility',jsonb_build_object('can_hard_delete',false,'blocker_count',jsonb_array_length(blockers)+1),
   'blockers',blockers||jsonb_build_array(jsonb_build_object('code','UNKNOWN_DEPENDENCY','category','schema','count',1,'hard_blocker',true)),
   'warnings',jsonb_build_array('DEPENDENCY_COUNTS_UNAVAILABLE'),'dependency_summary',summary);
 end if;
 select coalesce(bool_or(p.is_public),false) into is_public_value from public.tenant_public_profiles p where p.tenant_id=t.id;
 if is_public_value then blockers:=blockers||jsonb_build_array(jsonb_build_object('code','TENANT_PUBLIC','category','lifecycle','count',1,'hard_blocker',true)); end if;
 select jsonb_build_object(
 'audit_logs',(select count(*) from public.audit_logs x where x.tenant_id=p_tenant_id or x.target_id=p_tenant_id or exists(select 1 from public.reservations r where r.id=x.target_id and r.tenant_id=p_tenant_id) or exists(select 1 from public.event_registrations r where r.id=x.target_id and r.tenant_id=p_tenant_id) or exists(select 1 from public.events e where e.id=x.target_id and e.tenant_id=p_tenant_id) or exists(select 1 from public.shooting_lanes l where l.id=x.target_id and l.tenant_id=p_tenant_id)),
 'email_deliveries',(select count(*) from public.email_deliveries x where x.tenant_id=p_tenant_id or exists(select 1 from public.reservations r where r.id=x.record_id and r.tenant_id=p_tenant_id) or exists(select 1 from public.event_registrations r where r.id=x.record_id and r.tenant_id=p_tenant_id) or exists(select 1 from public.events e where e.id=x.record_id and e.tenant_id=p_tenant_id) or exists(select 1 from public.event_instructors i where i.id=x.record_id and i.tenant_id=p_tenant_id) or exists(select 1 from public.reminder_occurrences o join public.reminder_schedules s on s.id=o.schedule_id where o.id=x.record_id and (exists(select 1 from public.reservations r where r.id=s.reservation_id and r.tenant_id=p_tenant_id) or exists(select 1 from public.events e where e.id=s.event_id and e.tenant_id=p_tenant_id)))),
 'event_instructors',(select count(*) from public.event_instructors x where x.tenant_id=p_tenant_id),
 'event_lanes',(select count(*) from public.event_lanes x where x.tenant_id=p_tenant_id),
 'event_registrations',(select count(*) from public.event_registrations x where x.tenant_id=p_tenant_id),
 'events',(select count(*) from public.events x where x.tenant_id=p_tenant_id),
 'external_settlement_records',(select count(*) from public.external_settlement_records x where x.tenant_id=p_tenant_id),
 'lane_blocks',(select count(*) from public.lane_blocks x where x.tenant_id=p_tenant_id),
 'platform_admin_management_requests',(select count(*) from public.platform_admin_management_requests x where x.tenant_id=p_tenant_id),
 'platform_audit_logs',(select count(*) from public.platform_audit_logs x where x.tenant_id=p_tenant_id),
 'platform_plan_change_requests',(select count(*) from public.platform_plan_change_requests x where x.tenant_id=p_tenant_id),
 'platform_tenant_creation_requests',(select count(*) from public.platform_tenant_creation_requests x where x.tenant_id=p_tenant_id),
 'platform_tenant_lifecycle_requests',(select count(*) from public.platform_tenant_lifecycle_requests x where x.tenant_id=p_tenant_id),
 'reservations',(select count(*) from public.reservations x where x.tenant_id=p_tenant_id),
 'shooting_lanes',(select count(*) from public.shooting_lanes x where x.tenant_id=p_tenant_id),
 'tenant_domains',(select count(*) from public.tenant_domains x where x.tenant_id=p_tenant_id),
 'tenant_memberships',(select count(*) from public.tenant_memberships x where x.tenant_id=p_tenant_id),
 'tenant_plan_assignments',(select count(*) from public.tenant_plan_assignments x where x.tenant_id=p_tenant_id),
 'tenant_public_pricing_items',(select count(*) from public.tenant_public_pricing_items x where x.tenant_id=p_tenant_id),
 'tenant_public_profiles',(select count(*) from public.tenant_public_profiles x where x.tenant_id=p_tenant_id),
 'tenant_user_admin_notes',(select count(*) from public.tenant_user_admin_notes x where x.tenant_id=p_tenant_id),
 'tenant_user_verifications',(select count(*) from public.tenant_user_verifications x where x.tenant_id=p_tenant_id),
 'lane_booking_durations',(select count(*) from public.lane_booking_durations x where exists(select 1 from public.shooting_lanes l where l.id=x.lane_id and l.tenant_id=p_tenant_id)),
 'lane_booking_family_configuration_versions',(select count(*) from public.lane_booking_family_configuration_versions x where exists(select 1 from public.shooting_lanes l where l.id=x.root_lane_id and l.tenant_id=p_tenant_id)),
 'lane_booking_rules',(select count(*) from public.lane_booking_rules x where exists(select 1 from public.shooting_lanes l where l.id=x.lane_id and l.tenant_id=p_tenant_id)),
 'lane_pricing_rules',(select count(*) from public.lane_pricing_rules x where exists(select 1 from public.shooting_lanes l where l.id=x.lane_id and l.tenant_id=p_tenant_id)),
 'reminder_schedules',(select count(*) from public.reminder_schedules x where exists(select 1 from public.reservations r where r.id=x.reservation_id and r.tenant_id=p_tenant_id) or exists(select 1 from public.events e where e.id=x.event_id and e.tenant_id=p_tenant_id)),
 'reminder_occurrences',(select count(*) from public.reminder_occurrences x where exists(select 1 from public.reservations r where r.id=x.reservation_id and r.tenant_id=p_tenant_id) or exists(select 1 from public.event_registrations r where r.id=x.registration_id and r.tenant_id=p_tenant_id) or exists(select 1 from public.reminder_schedules s where s.id=x.schedule_id and (exists(select 1 from public.reservations r where r.id=s.reservation_id and r.tenant_id=p_tenant_id) or exists(select 1 from public.events e where e.id=s.event_id and e.tenant_id=p_tenant_id))))
 ) into summary;
 -- A global profile is not owned by a tenant. Only count related user links.
 summary:=summary||jsonb_build_object('profile_links',(select count(*) from (
  select user_id from public.tenant_memberships where tenant_id=t.id
  union select user_id from public.tenant_user_verifications where tenant_id=t.id
  union select user_id from public.tenant_user_admin_notes where tenant_id=t.id
  union select user_id from public.reservations where tenant_id=t.id
  union select user_id from public.event_registrations where tenant_id=t.id
  union select instructor_user_id from public.event_instructors where tenant_id=t.id
 ) links where user_id is not null));
 select blockers||coalesce(jsonb_agg(jsonb_build_object('code',code,'category',category,'count',(summary->>tab)::bigint,'hard_blocker',true) order by code),'[]'::jsonb) into blockers
 from (values ('audit_logs','AUDIT_LOGS_EXIST','history'),
   ('email_deliveries','EMAIL_HISTORY_EXISTS','history'),
   ('event_instructors','EVENT_INSTRUCTORS_EXIST','business'),
   ('event_lanes','EVENT_LANES_EXIST','business'),
   ('event_registrations','EVENT_REGISTRATIONS_EXIST','business'),
   ('events','EVENTS_EXIST','business'),
   ('external_settlement_records','SETTLEMENTS_EXIST','history'),
   ('lane_blocks','LANE_BLOCKS_EXIST','business'),
   ('platform_admin_management_requests','PLATFORM_ADMIN_MANAGEMENT_REQUESTS_EXIST','lineage'),
   ('platform_audit_logs','PLATFORM_AUDIT_EXISTS','history'),
   ('platform_plan_change_requests','PLATFORM_PLAN_CHANGE_REQUESTS_EXIST','lineage'),
   ('platform_tenant_creation_requests','CREATION_LEDGER_EXISTS','lineage'),
   ('platform_tenant_lifecycle_requests','PLATFORM_TENANT_LIFECYCLE_REQUESTS_EXIST','lineage'),
   ('reservations','RESERVATIONS_EXIST','business'),
   ('shooting_lanes','SHOOTING_LANES_EXIST','configuration'),
   ('tenant_domains','CUSTOM_DOMAIN_EXISTS','configuration'),
   ('tenant_memberships','TENANT_MEMBERSHIPS_EXIST','lineage'),
   ('tenant_plan_assignments','PLAN_ASSIGNMENT_EXISTS','lineage'),
   ('tenant_public_pricing_items','TENANT_PUBLIC_PRICING_ITEMS_EXIST','configuration'),
   ('tenant_public_profiles','TENANT_PUBLIC_PROFILES_EXIST','configuration'),
   ('tenant_user_admin_notes','TENANT_USER_ADMIN_NOTES_EXIST','lineage'),
   ('tenant_user_verifications','TENANT_USER_VERIFICATIONS_EXIST','lineage'),
   ('lane_booking_durations','LANE_BOOKING_DURATIONS_EXIST','configuration'),
   ('lane_booking_family_configuration_versions','LANE_BOOKING_FAMILY_CONFIGURATION_VERSIONS_EXIST','configuration'),
   ('lane_booking_rules','LANE_BOOKING_RULES_EXIST','configuration'),
   ('lane_pricing_rules','LANE_PRICING_RULES_EXIST','configuration'),
   ('reminder_schedules','REMINDER_SCHEDULES_EXIST','history'),
   ('reminder_occurrences','REMINDER_HISTORY_EXISTS','history'),('profile_links','TENANT_PROFILE_LINKS_EXIST','lineage')) c(tab,code,category)
 where (summary->>tab)::bigint>0;
 return jsonb_build_object('tenant',jsonb_build_object('tenant_id',t.id,'name',t.name,'status',t.status),
  'lifecycle',jsonb_build_object('is_archived',t.status='archived','is_public',is_public_value),
  'eligibility',jsonb_build_object('can_hard_delete',false,'blocker_count',jsonb_array_length(blockers)),
  'blockers',blockers,'warnings',jsonb_build_array('GLOBAL_ACCOUNTS_NOT_TENANT_OWNED','SNAPSHOT_ONLY_NOT_DELETE_AUTHORIZATION'),
  'dependency_summary',summary);
end;
$function$;
