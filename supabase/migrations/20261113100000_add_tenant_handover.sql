-- NEW-TENANT-2D: atomic first-admin handover; public activation is a separate action.
set lock_timeout='5s';
set statement_timeout='120s';

create table app_private.tenant_handovers (
 tenant_id uuid primary key references public.tenants(id) on delete restrict,
 actor_user_id uuid not null,
 selected_admin_user_id uuid not null,
 request_id uuid not null check(request_id<>'00000000-0000-0000-0000-000000000000'::uuid),
 configuration_revision text not null check(configuration_revision~'^[a-f0-9]{64}$'),
 handed_over_at timestamptz not null default transaction_timestamp(),
 unique(actor_user_id,request_id)
);
alter table app_private.tenant_handovers enable row level security;
revoke all on app_private.tenant_handovers from public,anon,authenticated,service_role;

create function public.platform_get_tenant_handover_v1(p_tenant_id uuid) returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,public,pg_temp as $$
declare result jsonb;
begin
 if not public.is_platform_admin_v1() or not app_private.is_platform_draft_v1(p_tenant_id) then raise exception 'Not authorized' using errcode='42501';end if;
 select jsonb_build_object('tenant_id',t.id,'name',t.name,'tenant_slug',t.slug,'status',t.status,
 'public_access_state',c.public_access_state,'is_public',p.is_public,
 'active_admin_count',(select count(*) from public.tenant_memberships m where m.tenant_id=t.id and m.role='admin' and m.status='active'),
 'handover',case when h.tenant_id is null then null else to_jsonb(h)||jsonb_build_object('selected_admin_email',u.email) end,
 'readiness',case when h.tenant_id is null then app_private.draft_readiness_result_v1(t.id) else null end)
 into result from public.tenants t join public.tenant_public_profiles p on p.tenant_id=t.id
 join public.tenant_public_access_controls c on c.tenant_id=t.id
 left join app_private.tenant_handovers h on h.tenant_id=t.id left join auth.users u on u.id=h.selected_admin_user_id and u.deleted_at is null
 where t.id=p_tenant_id;
 return result;
end;$$;

create function public.platform_handover_tenant_v1(p_tenant_id uuid,p_user_id uuid,p_expected_revision text,p_request_id uuid) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public,pg_temp as $$
declare actor uuid:=auth.uid(); prior app_private.tenant_handovers; readiness jsonb;
begin
 if not public.is_platform_admin_v1() then raise exception 'Not authorized' using errcode='42501';end if;
 perform 1 from public.platform_admins where user_id=actor and status='active' for share nowait;
 if not found then raise exception 'Not authorized' using errcode='42501';end if;
 if p_tenant_id is null or p_user_id is null or p_request_id is null or p_request_id='00000000-0000-0000-0000-000000000000'::uuid
 or p_expected_revision is null or p_expected_revision !~ '^[a-f0-9]{64}$' then raise exception 'INVALID_HANDOVER_REQUEST' using errcode='22023';end if;
 if not pg_try_advisory_xact_lock(hashtextextended(actor::text||':'||p_request_id::text,1113000)) then raise exception 'HANDOVER_BUSY' using errcode='55P03';end if;
 select * into prior from app_private.tenant_handovers where actor_user_id=actor and request_id=p_request_id;
 if found then
  if prior.tenant_id<>p_tenant_id or prior.selected_admin_user_id<>p_user_id or prior.configuration_revision<>p_expected_revision then raise exception 'HANDOVER_REQUEST_MISMATCH' using errcode='PT409';end if;
  return to_jsonb(prior);
 end if;
 perform app_private.lock_draft_readiness_v1(p_tenant_id);
 if exists(select 1 from app_private.tenant_handovers where tenant_id=p_tenant_id) then raise exception 'HANDOVER_ALREADY_COMPLETED' using errcode='PT409';end if;
 if not exists(select 1 from public.tenants where id=p_tenant_id and status='dormant') then raise exception 'HANDOVER_TENANT_NOT_DORMANT' using errcode='55000';end if;
 if not pg_try_advisory_xact_lock(hashtextextended(p_tenant_id::text,9401)) then raise exception 'HANDOVER_BUSY' using errcode='55P03';end if;
 if exists(select 1 from public.tenant_memberships where tenant_id=p_tenant_id) then raise exception 'HANDOVER_MEMBERSHIP_CONFLICT' using errcode='55000';end if;
 if not pg_try_advisory_xact_lock(hashtextextended(p_user_id::text,0)) then raise exception 'HANDOVER_BUSY' using errcode='55P03';end if;
 perform 1 from public.profiles where user_id=p_user_id for share nowait;
 perform 1 from auth.users where id=p_user_id for share nowait;
 if not found or not public.onboarding_admin_eligible_core_v1(p_user_id) then raise exception 'HANDOVER_ACCOUNT_UNAVAILABLE' using errcode='22023';end if;
 readiness:=app_private.draft_readiness_result_v1(p_tenant_id);
 if readiness->>'current_revision' is distinct from p_expected_revision then raise exception 'HANDOVER_REVISION_STALE' using errcode='PT409';end if;
 if not app_private.is_tenant_ready_for_handover_v1(p_tenant_id) then raise exception 'HANDOVER_READINESS_REQUIRED' using errcode='55000';end if;
 insert into app_private.tenant_handovers(tenant_id,actor_user_id,selected_admin_user_id,request_id,configuration_revision)
 values(p_tenant_id,actor,p_user_id,p_request_id,p_expected_revision) returning * into prior;
 insert into public.tenant_memberships(tenant_id,user_id,role,status)values(p_tenant_id,p_user_id,'admin','active');
 insert into public.platform_audit_logs(actor_user_id,tenant_id,action,details)values
 (actor,p_tenant_id,'tenant_admin_assigned',jsonb_build_object('user_id',p_user_id,'source','first_admin_handover','request_id',p_request_id)),
 (actor,p_tenant_id,'tenant_handed_over',jsonb_build_object('user_id',p_user_id,'configuration_revision',p_expected_revision,'request_id',p_request_id));
 return to_jsonb(prior);
end;$$;

revoke all on function public.platform_get_tenant_handover_v1(uuid),public.platform_handover_tenant_v1(uuid,uuid,text,uuid) from public,anon,authenticated,service_role;
grant execute on function public.platform_get_tenant_handover_v1(uuid),public.platform_handover_tenant_v1(uuid,uuid,text,uuid) to authenticated;

CREATE OR REPLACE FUNCTION app_private.guard_platform_draft_v1()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
declare tid uuid;
begin
 if tg_table_name='tenants' then tid:=new.id; else tid:=new.tenant_id; end if;
 if app_private.is_platform_draft_v1(tid) and not exists(select 1 from app_private.tenant_handovers where tenant_id=tid) and (
  tg_table_name='tenant_memberships'
  or (tg_table_name='tenants' and to_jsonb(new)->>'status' not in ('dormant','archived'))
  or (tg_table_name='tenant_public_profiles' and (to_jsonb(new)->>'is_public')::boolean)
  or (tg_table_name='tenant_public_access_controls' and to_jsonb(new)->>'public_access_state'<>'coming_soon')
 ) then raise exception 'DRAFT_HANDOVER_NOT_AVAILABLE' using errcode='55000'; end if;
 return new;
end; $function$
;

CREATE OR REPLACE FUNCTION app_private.recoverable_platform_draft_v1(tid uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
 select app_private.is_platform_draft_v1(tid) and not exists(select 1 from app_private.tenant_handovers where tenant_id=tid)
 and exists(select 1 from public.tenants t join public.tenant_public_profiles p on p.tenant_id=t.id join public.tenant_public_access_controls c on c.tenant_id=t.id
 where t.id=tid and t.status in ('dormant','archived') and not p.is_public and c.public_access_state='coming_soon')
 and not exists(select 1 from public.tenant_memberships where tenant_id=tid)
 and not exists(select 1 from public.reservations where tenant_id=tid)
 and not exists(select 1 from public.events where tenant_id=tid)
 and not exists(select 1 from public.lane_blocks where tenant_id=tid)
 and not exists(select 1 from public.email_deliveries where tenant_id=tid)
 and not exists(select 1 from public.external_settlement_records where tenant_id=tid)
 and not exists(select 1 from public.tenant_domains where tenant_id=tid and status='active');
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
 'is_platform_draft',(app_private.is_platform_draft_v1(t.id) and not exists(select 1 from app_private.tenant_handovers where tenant_id=t.id)),'plan_key',s.plan_key,'created_at',t.created_at,'readiness',public.platform_tenant_readiness_core_v1(t.id)) row_data
 from public.tenants t left join public.tenant_public_profiles p on p.tenant_id=t.id
 left join public.tenant_plan_assignments a on a.tenant_id=t.id
 left join public.saas_plans s on s.id=a.plan_id
 order by t.created_at,t.id limit 25 offset ((p_page::bigint-1)*25)) rows),'[]'::jsonb));
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
  'is_platform_draft',(app_private.is_platform_draft_v1(t.id) and not exists(select 1 from app_private.tenant_handovers where tenant_id=t.id)),
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

CREATE OR REPLACE FUNCTION public.platform_assign_initial_admin_v1(p_tenant_id uuid, p_user_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
begin
 if not public.is_platform_admin_v1() then raise exception 'Not authorized' using errcode='42501'; end if;
 if app_private.is_platform_draft_v1(p_tenant_id) and not exists(select 1 from app_private.tenant_handovers where tenant_id=p_tenant_id) then raise exception 'HANDOVER_REQUIRED' using errcode='55000';end if;
 perform public.onboarding_lock_admin_core_v1(p_user_id);
 perform 1 from public.tenants where id=p_tenant_id and status='dormant' for no key update;
 if not found then raise exception 'Initial admin assignment requires draft tenant' using errcode='55000'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_tenant_id::text,9401));
 if exists(select 1 from public.tenant_memberships where tenant_id=p_tenant_id and role='admin' and status='active') then
 raise exception 'Initial admin already assigned' using errcode='55000'; end if;
 if not public.onboarding_admin_eligible_core_v1(p_user_id)
 or exists(select 1 from public.tenant_memberships where tenant_id=p_tenant_id and user_id=p_user_id) then
 raise exception 'Account cannot be assigned' using errcode='22023'; end if;
 insert into public.tenant_memberships(tenant_id,user_id,role,status) values(p_tenant_id,p_user_id,'admin','active');
 insert into public.platform_audit_logs(actor_user_id,tenant_id,action,details)
 values(auth.uid(),p_tenant_id,'tenant_admin_assigned',jsonb_build_object('user_id',p_user_id));
end;$function$
;

CREATE OR REPLACE FUNCTION public.platform_tenant_admin_mutation_core_v1(p_tenant_id uuid, p_user_id uuid, p_operation text, p_expected_state jsonb, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
declare actor uuid:=auth.uid(); prior public.platform_admin_management_requests;
 m public.tenant_memberships; payload_value jsonb; state_value jsonb; result_value jsonb;
 next_role text; next_status text; changed boolean;
begin
 if not public.is_platform_admin_v1() then raise exception 'Not authorized' using errcode='42501'; end if;
 if app_private.is_platform_draft_v1(p_tenant_id) and not exists(select 1 from app_private.tenant_handovers where tenant_id=p_tenant_id) then raise exception 'HANDOVER_REQUIRED' using errcode='55000';end if;
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
end;$function$
;

CREATE OR REPLACE FUNCTION public.platform_create_tenant_v1(p_name text, p_tenant_slug text, p_public_slug text, p_city text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
begin
 return (public.platform_create_tenant_draft_v1(p_name,p_tenant_slug,p_public_slug,p_city,null,gen_random_uuid())->>'tenant_id')::uuid;
end;$function$;

CREATE OR REPLACE FUNCTION public.platform_create_tenant_bundle_v2(p_name text, p_tenant_slug text, p_public_slug text, p_city text, p_plan_key text, p_initial_admin_user_id uuid, p_creation_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
declare actor uuid:=auth.uid(); target uuid; selected_plan uuid; digest_value text; prior public.platform_tenant_creation_requests%rowtype;
begin
 if not public.is_platform_admin_v1() then raise exception 'Not authorized' using errcode='42501'; end if;
 if p_creation_request_id is null or p_creation_request_id='00000000-0000-0000-0000-000000000000'::uuid
 or p_name is null or p_city is null or length(btrim(p_name)) not between 1 and 120
 or length(btrim(p_city)) not between 1 and 120 or p_plan_key is null or p_initial_admin_user_id is null
 or not public.platform_slug_valid_v1(p_tenant_slug) or not public.platform_slug_valid_v1(p_public_slug)
 or p_tenant_slug=p_public_slug then raise exception 'Invalid onboarding payload' using errcode='22023'; end if;
 digest_value:=encode(sha256(convert_to(jsonb_build_object('name',btrim(p_name),'city',btrim(p_city),
  'tenant_slug',p_tenant_slug,'public_slug',p_public_slug,'plan_key',p_plan_key,'admin',p_initial_admin_user_id)::text,'UTF8')),'hex');
 perform pg_advisory_xact_lock(hashtextextended(actor::text||':'||p_creation_request_id::text,271000));
 select * into prior from public.platform_tenant_creation_requests where actor_user_id=actor and creation_request_id=p_creation_request_id;
 if found then
  if prior.payload_hash<>digest_value then raise exception 'Creation request payload conflict' using errcode='22023'; end if;
  target:=prior.tenant_id;
 else
  raise exception 'HANDOVER_REQUIRED' using errcode='55000';
 end if;
 -- Stable creation receipt: replay never leaks current operational data or changes its meaning.
 return jsonb_build_object('tenant_id',target,'name',btrim(p_name),'tenant_slug',p_tenant_slug,
  'public_slug',p_public_slug,'city',btrim(p_city),'initial_status','dormant','initial_is_public',false,
  'plan_key',p_plan_key,'initial_admin_user_id',p_initial_admin_user_id,'creation_request_id',p_creation_request_id);
end;$function$
;

alter table public.platform_audit_logs drop constraint platform_audit_logs_action_check;
alter table public.platform_audit_logs add constraint platform_audit_logs_action_check CHECK ((action = ANY (ARRAY['tenant_created'::text, 'plan_assigned'::text, 'plan_changed'::text, 'tenant_admin_assigned'::text, 'tenant_activated'::text, 'tenant_suspended'::text, 'tenant_published'::text, 'tenant_unpublished'::text, 'platform_admin_bootstrapped'::text, 'domain_added'::text, 'domain_verification_started'::text, 'domain_verified'::text, 'domain_activated'::text, 'domain_disabled'::text, 'primary_domain_changed'::text, 'tenant_admin_add'::text, 'tenant_admin_reactivate'::text, 'tenant_admin_demote'::text, 'tenant_admin_suspend'::text, 'tenant_archived'::text, 'tenant_restored'::text, 'tenant_draft_configuration_updated'::text, 'readiness_validation_attempted'::text, 'readiness_validation_passed'::text, 'readiness_validation_failed'::text, 'tenant_handed_over'::text])));

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
 'tables',(select jsonb_agg(n.nspname||'.'||c.relname order by n.nspname,c.relname) from pg_class c join pg_namespace n on n.oid=c.relnamespace where (n.nspname='public' or (n.nspname='app_private' and c.relname in ('legal_subjects','legal_actions','legal_acceptances','tenant_public_access_changes','tenant_partner_media','tenant_partner_changes','draft_configuration_requests','draft_configuration_epochs','draft_readiness_validations','tenant_handovers'))) and c.relkind in('r','p')),
 'columns',(select jsonb_agg(n.nspname||'.'||c.relname||'.'||a.attname||':'||format_type(a.atttypid,a.atttypmod) order by n.nspname,c.relname,a.attnum) from pg_class c join pg_namespace n on n.oid=c.relnamespace join pg_attribute a on a.attrelid=c.oid where (n.nspname='public' or (n.nspname='app_private' and c.relname in ('legal_subjects','legal_actions','legal_acceptances','tenant_public_access_changes','tenant_partner_media','tenant_partner_changes','draft_configuration_requests','draft_configuration_epochs','draft_readiness_validations','tenant_handovers'))) and c.relkind in('r','p') and a.attnum>0 and not a.attisdropped),
 'foreign_keys',(select jsonb_agg(n.nspname||'.'||c.relname||'.'||k.conname||':'||pg_get_constraintdef(k.oid) order by n.nspname,c.relname,k.conname) from pg_constraint k join pg_class c on c.oid=k.conrelid join pg_namespace n on n.oid=c.relnamespace join pg_class parent on parent.oid=k.confrelid join pg_namespace pn on pn.oid=parent.relnamespace where k.contype='f' and (n.nspname='public' or pn.nspname='public' or (n.nspname='app_private' and c.relname in ('legal_subjects','legal_actions','legal_acceptances','tenant_public_access_changes','tenant_partner_media','tenant_partner_changes','draft_configuration_requests','draft_configuration_epochs','draft_readiness_validations','tenant_handovers'))))
) into catalog;

 catalog_matches:=md5(catalog::text)='b0c871dbe612685e8b251609d6c51e50';
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
 'draft_configuration_requests',(select count(*) from app_private.draft_configuration_requests where tenant_id=p_tenant_id),
 'draft_configuration_epochs',(select count(*) from app_private.draft_configuration_epochs where tenant_id=p_tenant_id),
 'draft_readiness_validations',(select count(*) from app_private.draft_readiness_validations where tenant_id=p_tenant_id),
 'tenant_handovers',(select count(*) from app_private.tenant_handovers where tenant_id=p_tenant_id),
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
 from (values ('tenant_handovers','TENANT_HANDOVER_HISTORY_EXISTS','lineage'),('draft_configuration_epochs','DRAFT_CONFIGURATION_HISTORY_EXISTS','lineage'),('draft_readiness_validations','DRAFT_READINESS_PROOF_EXISTS','lineage'),('draft_configuration_requests','DRAFT_CONFIGURATION_REQUESTS_EXIST','lineage'),('tenant_partners','TENANT_PARTNERS_EXIST','configuration'),('tenant_partner_media','PARTNER_MEDIA_EXISTS','configuration'),('tenant_partner_changes','PARTNER_AUDIT_EXISTS','history'),('tenant_public_access_controls','PUBLIC_ACCESS_CONFIGURATION_EXISTS','configuration'),('tenant_public_access_changes','PUBLIC_ACCESS_AUDIT_EXISTS','history'),('legal_documents','LEGAL_DOCUMENTS_EXIST','history'),('legal_document_versions','LEGAL_VERSIONS_EXIST','history'),('legal_actions','LEGAL_ACTIONS_EXIST','history'),('legal_acceptances','LEGAL_ACCEPTANCES_EXIST','history'),('audit_logs','AUDIT_LOGS_EXIST','history'),
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
$function$
;
