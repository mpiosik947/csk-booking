-- PAM-1D: aggregate information only. No deletion authority or retention policy.
-- All STABLE subqueries use the calling statement snapshot, including PA authority.
-- Catalog pin is independently inventoried in tests/fixtures/tenant-delete-dependencies.json.
create function public.platform_get_tenant_delete_eligibility_v1(p_tenant_id uuid)
returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,pg_temp
as $function$
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

 catalog_matches:=md5(catalog::text)='f25b328aa60924468f8b3ba3a9a58c7f';
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
alter function public.platform_get_tenant_delete_eligibility_v1(uuid) owner to postgres;
revoke all on function public.platform_get_tenant_delete_eligibility_v1(uuid) from public,anon,authenticated,service_role;
grant execute on function public.platform_get_tenant_delete_eligibility_v1(uuid) to authenticated;
