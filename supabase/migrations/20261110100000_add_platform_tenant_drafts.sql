-- NEW-TENANT-2A. No production fixtures; existing tenants keep their contracts.
alter table public.platform_tenant_creation_requests add column creation_kind text not null default 'legacy'
 check(creation_kind in ('legacy','draft'));

create function app_private.is_platform_draft_v1(tid uuid) returns boolean
language sql stable set search_path='pg_catalog','public','pg_temp' as $$
 select exists(select 1 from public.platform_tenant_creation_requests where tenant_id=tid and creation_kind='draft');
$$;

create function public.platform_create_tenant_draft_v1(p_name text,p_tenant_slug text,p_public_slug text,p_city text,p_plan_key text,p_creation_request_id uuid)
returns jsonb language plpgsql security definer set search_path='pg_catalog','public','pg_temp' as $$
declare actor uuid:=auth.uid(); tid uuid; plan uuid; digest_value text; prior public.platform_tenant_creation_requests;
begin
 if not public.is_platform_admin_v1() then raise exception 'Not authorized' using errcode='42501'; end if;
 perform 1 from public.platform_admins where user_id=actor and status='active' for share nowait;
 if not found then raise exception 'Not authorized' using errcode='42501'; end if;
 if p_creation_request_id is null or p_creation_request_id='00000000-0000-0000-0000-000000000000'::uuid
 or p_name is null or p_city is null or length(btrim(p_name)) not between 1 and 120 or length(btrim(p_city)) not between 1 and 120
 or not public.platform_slug_valid_v1(p_tenant_slug) or not public.platform_slug_valid_v1(p_public_slug) or p_tenant_slug=p_public_slug
 or (p_plan_key is not null and p_plan_key !~ '^[a-z][a-z0-9_]{1,62}$') then
 raise exception 'Invalid draft payload' using errcode='22023'; end if;
 digest_value:=encode(sha256(convert_to(jsonb_build_object('name',btrim(p_name),'city',btrim(p_city),'tenant_slug',p_tenant_slug,'public_slug',p_public_slug,'plan_key',p_plan_key,'kind','draft')::text,'UTF8')),'hex');
 perform pg_advisory_xact_lock(hashtextextended(actor::text||':'||p_creation_request_id::text,271000));
 select * into prior from public.platform_tenant_creation_requests where actor_user_id=actor and creation_request_id=p_creation_request_id;
 if found then
  if prior.creation_kind<>'draft' or prior.payload_hash<>digest_value then raise exception 'Creation request payload conflict' using errcode='22023'; end if;
  tid:=prior.tenant_id;
 else
  if p_plan_key is not null then
   select id into plan from public.saas_plans where plan_key=p_plan_key and status='active' for share nowait;
   if not found then raise exception 'Plan unavailable' using errcode='22023'; end if;
  end if;
  perform pg_advisory_xact_lock(722025101);
  insert into public.tenants(name,slug,status) values(btrim(p_name),p_tenant_slug,'dormant') returning id into tid;
  insert into public.tenant_public_profiles(tenant_id,display_name,city,public_slug,is_public,show_booking,show_pricing,show_instructor,show_events,show_about,show_contact,show_regulations)
  values(tid,btrim(p_name),btrim(p_city),p_public_slug,false,false,false,false,false,false,false,false);
  insert into public.tenant_public_access_controls(tenant_id,public_access_state,revision) values(tid,'coming_soon',gen_random_uuid());
  if plan is not null then
   insert into public.tenant_plan_assignments(tenant_id,plan_id,status) values(tid,plan,'active');
   insert into public.platform_audit_logs(actor_user_id,tenant_id,action,details) values(actor,tid,'plan_assigned',jsonb_build_object('plan_key',p_plan_key));
  end if;
  insert into public.platform_tenant_creation_requests(actor_user_id,creation_request_id,payload_hash,tenant_id,creation_kind) values(actor,p_creation_request_id,digest_value,tid,'draft');
  insert into public.platform_audit_logs(actor_user_id,tenant_id,action,details) values(actor,tid,'tenant_created',jsonb_build_object('lifecycle','dormant','public_access_state','coming_soon','is_public',false,'plan_key',p_plan_key,'request_id',p_creation_request_id));
 end if;
 return jsonb_build_object('tenant_id',tid,'name',btrim(p_name),'city',btrim(p_city),'tenant_slug',p_tenant_slug,'public_slug',p_public_slug,'plan_key',p_plan_key,'creation_request_id',p_creation_request_id,'initial_status','dormant','initial_is_public',false,'initial_public_access_state','coming_soon');
end; $$;

-- Until explicit handover is implemented, no alternate membership or publication
-- writer may convert a new-model draft. Legacy tenants are unaffected.
create function app_private.guard_platform_draft_v1() returns trigger language plpgsql
set search_path='pg_catalog','public','pg_temp' as $$
declare tid uuid;
begin
 if tg_table_name='tenants' then tid:=new.id; else tid:=new.tenant_id; end if;
 if app_private.is_platform_draft_v1(tid) and (
  tg_table_name='tenant_memberships'
  or (tg_table_name='tenants' and to_jsonb(new)->>'status' not in ('dormant','archived'))
  or (tg_table_name='tenant_public_profiles' and (to_jsonb(new)->>'is_public')::boolean)
  or (tg_table_name='tenant_public_access_controls' and to_jsonb(new)->>'public_access_state'<>'coming_soon')
 ) then raise exception 'DRAFT_HANDOVER_NOT_AVAILABLE' using errcode='55000'; end if;
 return new;
end; $$;
create trigger platform_draft_guard before insert or update on public.tenant_memberships for each row execute function app_private.guard_platform_draft_v1();
create trigger platform_draft_guard before update on public.tenants for each row execute function app_private.guard_platform_draft_v1();
create trigger platform_draft_guard before insert or update on public.tenant_public_profiles for each row execute function app_private.guard_platform_draft_v1();
create trigger platform_draft_guard before insert or update on public.tenant_public_access_controls for each row execute function app_private.guard_platform_draft_v1();

create function app_private.recoverable_platform_draft_v1(tid uuid) returns boolean
language sql stable set search_path='pg_catalog','public','pg_temp' as $$
 select app_private.is_platform_draft_v1(tid)
 and exists(select 1 from public.tenants t join public.tenant_public_profiles p on p.tenant_id=t.id join public.tenant_public_access_controls c on c.tenant_id=t.id
 where t.id=tid and t.status in ('dormant','archived') and not p.is_public and c.public_access_state='coming_soon')
 and not exists(select 1 from public.tenant_memberships where tenant_id=tid)
 and not exists(select 1 from public.reservations where tenant_id=tid)
 and not exists(select 1 from public.events where tenant_id=tid)
 and not exists(select 1 from public.lane_blocks where tenant_id=tid)
 and not exists(select 1 from public.email_deliveries where tenant_id=tid)
 and not exists(select 1 from public.external_settlement_records where tenant_id=tid)
 and not exists(select 1 from public.tenant_domains where tenant_id=tid and status='active');
$$;

revoke all on function app_private.is_platform_draft_v1(uuid),app_private.recoverable_platform_draft_v1(uuid),app_private.guard_platform_draft_v1() from public,anon,authenticated,service_role;
revoke all on function public.platform_create_tenant_draft_v1(text,text,text,text,text,uuid) from public,anon,authenticated,service_role;
grant execute on function public.platform_create_tenant_draft_v1(text,text,text,text,text,uuid) to authenticated;
;
CREATE OR REPLACE FUNCTION public.tenant_archive_preview_core_v1(p_tenant_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
declare t public.tenants; admins bigint; leases bigint; plan jsonb; blockers jsonb:='[]'; counts jsonb;
begin
 select * into t from public.tenants where id=p_tenant_id;
 if not found then raise exception 'TENANT_UNAVAILABLE' using errcode='22023'; end if;
 select count(*) into admins from public.tenant_memberships where tenant_id=t.id and role='admin' and status='active';
 select jsonb_build_object('plan_key',p.plan_key,'status',a.status,'plan_status',p.status) into plan
 from public.tenant_plan_assignments a join public.saas_plans p on p.id=a.plan_id where a.tenant_id=t.id;
 select (select count(*) from public.email_deliveries where tenant_id=t.id and claim_id is not null and claim_expires_at>clock_timestamp()
  and message_type not in ('reservation_cancellation','event_registration_cancellation','event_cancellation','instructor_removal','instructor_event_cancellation'))
  +(select count(*) from public.event_registrations where tenant_id=t.id and promotion_claim_id is not null and promotion_claim_expires_at>clock_timestamp()) into leases;
 if t.status not in ('dormant','active','suspended','archived') then blockers:=blockers||'"TENANT_STATE_CONFLICT"'::jsonb; end if;
 if admins=0 and not app_private.recoverable_platform_draft_v1(t.id) then blockers:=blockers||'"TENANT_NO_ACTIVE_ADMIN"'::jsonb; end if;
 if leases>0 then blockers:=blockers||'"TENANT_DELIVERY_IN_FLIGHT"'::jsonb; end if;
 counts:=jsonb_build_object(
 'future_reservations',(select count(*) from public.reservations where tenant_id=t.id and reservation_date>=current_date and reservation_status='confirmed'),
 'future_events',(select count(*) from public.events where tenant_id=t.id and event_date>=current_date and cancelled_at is null),
 'open_registrations',(select count(*) from public.event_registrations where tenant_id=t.id and registration_status in ('registered','approved','reserve')),
 'active_lane_blocks',(select count(*) from public.lane_blocks where tenant_id=t.id and is_active),
 'active_custom_domains',(select count(*) from public.tenant_domains where tenant_id=t.id and domain_type='custom_domain' and status='active'),
 'settlement_records',(select count(*) from public.external_settlement_records where tenant_id=t.id),
 'pending_deliveries',(select count(*) from public.email_deliveries where tenant_id=t.id and sent_at is null),
 'in_flight_positive_deliveries',leases);
 return jsonb_build_object('tenant',jsonb_build_object('tenant_id',t.id,'name',t.name,'status',t.status,'is_public',coalesce((select is_public from public.tenant_public_profiles where tenant_id=t.id),false)),
 'current_plan',plan,'admin_summary',jsonb_build_object('active_admin_count',admins),'operational_counts',counts,
 'warnings',jsonb_build_array('HISTORY_RETAINED','CLOSURE_CONTINUITY_ONLY','RESTORE_REQUIRES_SEPARATE_PUBLICATION'),
 'blockers',blockers,'can_archive',jsonb_array_length(blockers)=0,'revision',t.lifecycle_revision);
end;$function$
;
CREATE OR REPLACE FUNCTION public.platform_tenant_lifecycle_core_v1(p_tenant_id uuid, p_expected_revision bigint, p_request_id uuid, p_operation text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
declare actor uuid:=auth.uid(); t public.tenants; prior public.platform_tenant_lifecycle_requests; payload_value jsonb; result_value jsonb; preview jsonb; next_status text;
begin
 if not public.is_platform_admin_v1() then raise exception 'Not authorized' using errcode='42501'; end if;
 perform 1 from public.platform_admins where user_id=actor and status='active' for share nowait;
 if not found then raise exception 'Not authorized' using errcode='42501'; end if;
 if p_tenant_id is null or p_expected_revision is null or p_expected_revision<0 or p_request_id is null
  or p_request_id='00000000-0000-0000-0000-000000000000'::uuid or p_operation not in ('archive','restore') then
  raise exception 'INVALID_LIFECYCLE_REQUEST' using errcode='22023'; end if;
 if not pg_try_advisory_xact_lock(hashtextextended(actor::text||':'||p_request_id::text,1102000)) then raise exception 'TENANT_LIFECYCLE_BUSY' using errcode='55P03'; end if;
 payload_value:=jsonb_build_object('tenant_id',p_tenant_id,'revision',p_expected_revision,'operation',p_operation);
 select * into prior from public.platform_tenant_lifecycle_requests where actor_user_id=actor and request_id=p_request_id;
 if found then
  if prior.payload<>payload_value then raise exception 'REQUEST_REPLAY_MISMATCH' using errcode='22023'; end if;
  return prior.result;
 end if;
 if not pg_try_advisory_xact_lock(hashtextextended(p_tenant_id::text,9401)) then raise exception 'TENANT_LIFECYCLE_BUSY' using errcode='55P03'; end if;
 select * into t from public.tenants where id=p_tenant_id for no key update nowait;
 if not found then raise exception 'TENANT_UNAVAILABLE' using errcode='22023'; end if;
 if t.lifecycle_revision<>p_expected_revision then raise exception 'TENANT_REVISION_STALE' using errcode='PT409'; end if;
 perform 1 from public.tenant_public_profiles where tenant_id=t.id for update nowait;
 if not found then raise exception 'TENANT_STRUCTURE_INVALID' using errcode='55000'; end if;
 perform 1 from public.tenant_memberships where tenant_id=t.id order by user_id for share nowait;
 perform 1 from public.tenant_plan_assignments where tenant_id=t.id for share nowait;
 perform p.id from public.saas_plans p join public.tenant_plan_assignments a on a.plan_id=p.id where a.tenant_id=t.id for share of p nowait;
 preview:=public.tenant_archive_preview_core_v1(t.id);
 if p_operation='archive' then
  if jsonb_array_length(preview->'blockers')>0 then raise exception '%',preview->'blockers'->>0 using errcode='55000'; end if;
  next_status:='archived';
 else
  if t.status<>'archived' then raise exception 'TENANT_NOT_ARCHIVED' using errcode='55000'; end if;
  if (preview->'admin_summary'->>'active_admin_count')::bigint=0 and not app_private.recoverable_platform_draft_v1(t.id) then raise exception 'TENANT_NO_ACTIVE_ADMIN' using errcode='55000'; end if;
  if not app_private.recoverable_platform_draft_v1(t.id) and (preview->'current_plan'->>'status' is distinct from 'active' or preview->'current_plan'->>'plan_status' is distinct from 'active') then
   raise exception 'TENANT_PLAN_INVALID' using errcode='55000'; end if;
  next_status:='dormant';
 end if;
 if t.status<>next_status then
  update public.tenant_public_profiles set is_public=false where tenant_id=t.id;
  update public.tenants set status=next_status where id=t.id returning * into t;
  insert into public.platform_audit_logs(actor_user_id,tenant_id,action,details)
  values(actor,t.id,case p_operation when 'archive' then 'tenant_archived' else 'tenant_restored' end,
   jsonb_build_object('previous_status',preview->'tenant'->>'status','new_status',next_status,'request_id',p_request_id,'revision',t.lifecycle_revision));
 end if;
 result_value:=jsonb_build_object('tenant_id',t.id,'status',t.status,'revision',t.lifecycle_revision,'is_public',false);
 insert into public.platform_tenant_lifecycle_requests(actor_user_id,request_id,tenant_id,payload,result) values(actor,p_request_id,t.id,payload_value,result_value);
 return result_value;
end;$function$
;
CREATE OR REPLACE FUNCTION public.platform_get_tenant_onboarding_detail_v1(p_tenant_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
declare result jsonb;
begin
 if not public.is_platform_admin_v1() then
  raise exception 'Not authorized' using errcode='42501';
 end if;
 select jsonb_build_object(
  'tenant',jsonb_build_object('tenant_id',t.id,'name',t.name,'technical_slug',t.slug,'status',t.status),
  'public_profile',case when p.tenant_id is null then null else jsonb_build_object(
   'display_name',p.display_name,'city',p.city,'public_slug',p.public_slug,'is_public',p.is_public) end,
  'plan',case when a.tenant_id is null then null else jsonb_build_object(
   'plan_key',s.plan_key,'status',s.status,'assignment_status',a.status,
   'enabled_feature_keys',coalesce((select jsonb_agg(f.feature_key order by f.feature_key)
    from public.saas_plan_features pf join public.saas_features f on f.feature_key=pf.feature_key
    where pf.plan_id=s.id and f.active and s.status='active' and a.status='active'),'[]'::jsonb)) end,
  'admins',coalesce((select jsonb_agg(jsonb_build_object('user_id',m.user_id,'email',u.email) order by m.user_id)
   from public.tenant_memberships m left join auth.users u on u.id=m.user_id
   where m.tenant_id=t.id and m.role='admin' and m.status='active'),'[]'::jsonb),
  'is_platform_draft',app_private.is_platform_draft_v1(t.id),
  'readiness',public.tenant_onboarding_readiness_core_v2(t.id))
 into result from public.tenants t
 left join public.tenant_public_profiles p on p.tenant_id=t.id
 left join public.tenant_plan_assignments a on a.tenant_id=t.id
 left join public.saas_plans s on s.id=a.plan_id
 where t.id=p_tenant_id;
 -- Unknown/null selector returns JSON null; incomplete existing objects remain inspectable.
 return result;
end;
$function$
;
CREATE OR REPLACE FUNCTION public.platform_list_tenants_v1(p_page integer DEFAULT 1)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
begin
 if not public.is_platform_admin_v1() then raise exception 'Not authorized' using errcode='42501'; end if;
 if p_page is null or p_page<1 or p_page>100000 then raise exception 'Invalid page' using errcode='22023'; end if;
 return jsonb_build_object('page',p_page,'page_size',25,'total',(select count(*) from public.tenants),
 'items',coalesce((select jsonb_agg(row_data order by created_at,id) from (
 select t.created_at,t.id,jsonb_build_object('id',t.id,'name',p.display_name,'tenant_slug',t.slug,
 'public_slug',p.public_slug,'city',p.city,'status',t.status,'is_public',p.is_public,
 'is_platform_draft',app_private.is_platform_draft_v1(t.id),'plan_key',s.plan_key,'created_at',t.created_at,'readiness',public.platform_tenant_readiness_core_v1(t.id)) row_data
 from public.tenants t left join public.tenant_public_profiles p on p.tenant_id=t.id
 left join public.tenant_plan_assignments a on a.tenant_id=t.id
 left join public.saas_plans s on s.id=a.plan_id
 order by t.created_at,t.id limit 25 offset ((p_page::bigint-1)*25)) rows),'[]'::jsonb));
end;$function$
;

-- Exact dependency fingerprint: creation_kind column; hard-delete policy unchanged.
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
 'tables',(select jsonb_agg(n.nspname||'.'||c.relname order by n.nspname,c.relname) from pg_class c join pg_namespace n on n.oid=c.relnamespace where (n.nspname='public' or (n.nspname='app_private' and c.relname in ('legal_subjects','legal_actions','legal_acceptances','tenant_public_access_changes','tenant_partner_media','tenant_partner_changes'))) and c.relkind in('r','p')),
 'columns',(select jsonb_agg(n.nspname||'.'||c.relname||'.'||a.attname||':'||format_type(a.atttypid,a.atttypmod) order by n.nspname,c.relname,a.attnum) from pg_class c join pg_namespace n on n.oid=c.relnamespace join pg_attribute a on a.attrelid=c.oid where (n.nspname='public' or (n.nspname='app_private' and c.relname in ('legal_subjects','legal_actions','legal_acceptances','tenant_public_access_changes','tenant_partner_media','tenant_partner_changes'))) and c.relkind in('r','p') and a.attnum>0 and not a.attisdropped),
 'foreign_keys',(select jsonb_agg(n.nspname||'.'||c.relname||'.'||k.conname||':'||pg_get_constraintdef(k.oid) order by n.nspname,c.relname,k.conname) from pg_constraint k join pg_class c on c.oid=k.conrelid join pg_namespace n on n.oid=c.relnamespace join pg_class parent on parent.oid=k.confrelid join pg_namespace pn on pn.oid=parent.relnamespace where k.contype='f' and (n.nspname='public' or pn.nspname='public' or (n.nspname='app_private' and c.relname in ('legal_subjects','legal_actions','legal_acceptances','tenant_public_access_changes','tenant_partner_media','tenant_partner_changes'))))
) into catalog;

 catalog_matches:=md5(catalog::text)='5504f823760ec89e0d9163aeb2a83653';
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
 'tenant_partners',(select count(*) from public.tenant_partners where tenant_id=p_tenant_id),
 'tenant_partner_media',(select count(*) from app_private.tenant_partner_media where tenant_id=p_tenant_id),
 'tenant_partner_changes',(select count(*) from app_private.tenant_partner_changes where tenant_id=p_tenant_id),
 'tenant_public_access_controls',(select count(*) from public.tenant_public_access_controls where tenant_id=p_tenant_id),
 'tenant_public_access_changes',(select count(*) from app_private.tenant_public_access_changes where tenant_id=p_tenant_id),
 'legal_documents',(select count(*) from public.legal_documents d where d.tenant_id=p_tenant_id),
 'legal_document_versions',(select count(*) from public.legal_document_versions v join public.legal_documents d on d.id=v.document_id where d.tenant_id=p_tenant_id),
 'legal_actions',(select count(*) from app_private.legal_actions a where a.tenant_id=p_tenant_id),
 'legal_acceptances',(select count(*) from app_private.legal_acceptances r join app_private.legal_actions a on a.id=r.action_id where a.tenant_id=p_tenant_id),
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
 from (values ('tenant_partners','TENANT_PARTNERS_EXIST','configuration'),('tenant_partner_media','PARTNER_MEDIA_EXISTS','configuration'),('tenant_partner_changes','PARTNER_AUDIT_EXISTS','history'),('tenant_public_access_controls','PUBLIC_ACCESS_CONFIGURATION_EXISTS','configuration'),('tenant_public_access_changes','PUBLIC_ACCESS_AUDIT_EXISTS','history'),('legal_documents','LEGAL_DOCUMENTS_EXIST','history'),('legal_document_versions','LEGAL_VERSIONS_EXIST','history'),('legal_actions','LEGAL_ACTIONS_EXIST','history'),('legal_acceptances','LEGAL_ACCEPTANCES_EXIST','history'),('audit_logs','AUDIT_LOGS_EXIST','history'),
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
