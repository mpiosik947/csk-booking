-- CSK-PARTNERS-4A. Historical IDs survive deletion; no audit data rewrite.
set lock_timeout='5s';
set statement_timeout='60s';
alter table app_private.tenant_partner_changes drop constraint tenant_partner_changes_partner_id_fkey;
alter table app_private.tenant_partner_changes add column partner_name text;
alter table app_private.tenant_partner_media
 add column cleanup_partner_id uuid,
 add column cleanup_token uuid,
 add column cleanup_until timestamptz;

create function app_private.partner_audit_integrity_v1() returns trigger
language plpgsql security invoker set search_path=pg_catalog,public,pg_temp as $$
begin
 if tg_op<>'INSERT' then raise exception 'audit_append_only' using errcode='42501'; end if;
 select p.name into new.partner_name from public.tenant_partners p where p.id=new.partner_id and p.tenant_id=new.tenant_id;
 if not found then raise exception 'invalid_audit_subject' using errcode='23503'; end if;
 return new;
end; $$;
revoke all on function app_private.partner_audit_integrity_v1() from public,anon,authenticated,service_role;
create trigger partner_audit_integrity before insert or update or delete on app_private.tenant_partner_changes
for each row execute function app_private.partner_audit_integrity_v1();

-- The media row lock serializes attachment with cleanup preparation. The pin
-- survives failed HTTP calls and lease expiry; it is removed only with media.
create function app_private.partner_media_attachment_v1() returns trigger
language plpgsql security invoker set search_path=pg_catalog,public,pg_temp as $$
declare pinned uuid;
begin
 select cleanup_partner_id into pinned from app_private.tenant_partner_media
 where id=new.media_id and tenant_id=new.tenant_id for update;
 if pinned is not null then raise exception 'MEDIA_CLEANUP_PENDING' using errcode='PT409'; end if;
 return new;
end; $$;
revoke all on function app_private.partner_media_attachment_v1() from public,anon,authenticated,service_role;
create trigger partner_media_attachment before insert or update of media_id,tenant_id on public.tenant_partners
for each row execute function app_private.partner_media_attachment_v1();

-- Same lock order as the existing writer: tenant, membership, partner, media.
create function app_private.lock_archived_partner_v1(slug text,pid uuid,rev uuid)
returns public.tenant_partners language plpgsql security invoker
set search_path=pg_catalog,public,pg_temp as $$
declare tid uuid; p public.tenant_partners;
begin
 select id into tid from public.tenants where tenants.slug=lock_archived_partner_v1.slug;
 if not app_private.partner_admin_v1(tid,auth.uid()) then raise exception 'forbidden' using errcode='42501'; end if;
 perform 1 from public.tenants where id=tid for update;
 perform 1 from public.tenant_memberships where tenant_id=tid and user_id=auth.uid() for share;
 if not app_private.partner_admin_v1(tid,auth.uid()) then raise exception 'forbidden' using errcode='42501'; end if;
 select * into p from public.tenant_partners where id=pid for update;
 if p.tenant_id is distinct from tid then raise exception 'forbidden' using errcode='42501'; end if;
 if rev is null or p.revision is distinct from rev then raise exception 'PARTNER_CONFLICT' using errcode='PT409'; end if;
 if p.archived_at is null or p.is_active then raise exception 'ARCHIVE_REQUIRED' using errcode='22023'; end if;
 return p;
end; $$;
revoke all on function app_private.lock_archived_partner_v1(text,uuid,uuid) from public,anon,authenticated,service_role;

create function public.admin_prepare_partner_delete_v1(p_tenant_slug text,p_id uuid,p_expected_revision uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,pg_temp set lock_timeout='3s' as $$
declare p public.tenant_partners; m app_private.tenant_partner_media; token uuid:=gen_random_uuid();
begin
 p:=app_private.lock_archived_partner_v1(p_tenant_slug,p_id,p_expected_revision);
 select * into m from app_private.tenant_partner_media where id=p.media_id and tenant_id=p.tenant_id for update;
 if not found then raise exception 'missing_media' using errcode='23503'; end if;
 if exists(select 1 from public.tenant_partners where media_id=m.id and id<>p.id) then
 raise exception 'MEDIA_SHARED' using errcode='22023'; end if;
 if m.cleanup_partner_id is not null and m.cleanup_partner_id<>p.id then raise exception 'MEDIA_CLEANUP_PENDING' using errcode='PT409'; end if;
 if m.cleanup_until>clock_timestamp() then raise exception 'DELETE_IN_PROGRESS' using errcode='PT409'; end if;
 update app_private.tenant_partner_media set cleanup_partner_id=p.id,cleanup_token=token,
 cleanup_until=clock_timestamp()+interval '2 minutes' where id=m.id;
 return jsonb_build_object('tenant_id',p.tenant_id,'media_id',m.id,'token',token);
end; $$;

create function public.admin_finish_partner_delete_v1(p_tenant_slug text,p_id uuid,p_expected_revision uuid,p_token uuid)
returns boolean language plpgsql security definer set search_path=pg_catalog,public,pg_temp set lock_timeout='3s' as $$
declare p public.tenant_partners; m app_private.tenant_partner_media;
begin
 p:=app_private.lock_archived_partner_v1(p_tenant_slug,p_id,p_expected_revision);
 select * into m from app_private.tenant_partner_media where id=p.media_id and tenant_id=p.tenant_id for update;
 if p_token is null or m.cleanup_token is distinct from p_token or m.cleanup_partner_id is distinct from p.id then
 raise exception 'PARTNER_CONFLICT' using errcode='PT409'; end if;
 if exists(select 1 from public.tenant_partners where media_id=m.id and id<>p.id) then raise exception 'MEDIA_SHARED' using errcode='22023'; end if;
 if exists(select 1 from storage.objects where bucket_id='tenant-partners' and name=p.tenant_id::text||'/partners/'||m.id::text||'.webp') then
 raise exception 'STORAGE_CLEANUP_REQUIRED' using errcode='PT409'; end if;
 insert into app_private.tenant_partner_changes(tenant_id,partner_id,actor_user_id,actions)
 values(p.tenant_id,p.id,auth.uid(),array['permanent_delete']);
 delete from public.tenant_partners where id=p.id;
 delete from app_private.tenant_partner_media where id=m.id;
 return true;
end; $$;

-- Failed Storage/finish calls release only the matching claim, never the pin.
-- Lost requests recover after the bounded lease; repeated Storage removal is
-- idempotent for the same immutable key. Only one finalization can succeed.
create function public.admin_release_partner_delete_v1(p_tenant_slug text,p_id uuid,p_expected_revision uuid,p_token uuid)
returns void language plpgsql security definer set search_path=pg_catalog,public,pg_temp set lock_timeout='3s' as $$
declare p public.tenant_partners;
begin
 p:=app_private.lock_archived_partner_v1(p_tenant_slug,p_id,p_expected_revision);
 update app_private.tenant_partner_media set cleanup_until=null,cleanup_token=null
 where id=p.media_id and cleanup_partner_id=p.id and cleanup_token=p_token;
end; $$;
revoke all on function public.admin_prepare_partner_delete_v1(text,uuid,uuid),
 public.admin_finish_partner_delete_v1(text,uuid,uuid,uuid),public.admin_release_partner_delete_v1(text,uuid,uuid,uuid)
 from public,anon,authenticated,service_role;
grant execute on function public.admin_prepare_partner_delete_v1(text,uuid,uuid),
 public.admin_finish_partner_delete_v1(text,uuid,uuid,uuid),public.admin_release_partner_delete_v1(text,uuid,uuid,uuid) to authenticated;

-- Update only the dependency-catalog fingerprint for the exact new columns/FK.
do $$ begin
 if md5(pg_get_functiondef('public.platform_get_tenant_delete_eligibility_v1(uuid)'::regprocedure))<>'06f04148c95f46349b90eb4c37d315b9' then raise exception 'partner delete dependency input drift'; end if;
end; $$;
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

 catalog_matches:=md5(catalog::text)='214e0cf8bbcde9a5341e052c87841a3a';
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
