-- CSK-PARTNERS-2: additive tenant content and dependency-catalog reconciliation.
-- No seed, hot-table rewrite, public storage URL, or tenant/PA authority change.
set lock_timeout='5s';
set statement_timeout='60s';

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values ('tenant-partners','tenant-partners',false,1048576,array['image/webp']);
-- Defence against future permissive Storage policies. Only the server's storage
-- client handles this bucket, after normal JWT RPC authority checks.
create policy tenant_partners_no_direct_storage on storage.objects as restrictive
for all to anon,authenticated
using (bucket_id <> 'tenant-partners') with check (bucket_id <> 'tenant-partners');

create table app_private.tenant_partner_media (
 id uuid primary key,
 tenant_id uuid not null references public.tenants(id),
 actor_user_id uuid not null,
 width integer not null check(width between 1 and 2400),
 height integer not null check(height between 1 and 2400),
 byte_size integer not null check(byte_size between 1 and 1048576),
 sha256 text not null check(sha256 ~ '^[a-f0-9]{64}$'),
 created_at timestamptz not null default clock_timestamp(),
 unique(tenant_id,id)
);
alter table app_private.tenant_partner_media enable row level security;
revoke all on app_private.tenant_partner_media from public,anon,authenticated,service_role;

create table public.tenant_partners (
 id uuid primary key,
 tenant_id uuid not null references public.tenants(id),
 name text not null check(name=btrim(name) and length(name) between 1 and 120),
 kind text not null check(kind in ('partner','sponsor','commercial_partner')),
 display_format text not null check(display_format in ('logo','banner')),
 media_id uuid not null,
 target_url text check(target_url is null or (length(target_url)<=1000 and
   target_url ~ '^https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?([/?#][[:graph:]]*)?$' and
   target_url !~ '[\\<>"[:space:][:cntrl:]]' and target_url !~* '%(00|0a|0d)')),
 short_description text check(short_description is null or (short_description=btrim(short_description) and length(short_description) between 1 and 300)),
 is_active boolean not null default false,
 display_order integer not null default 0 check(display_order between 0 and 9999),
 starts_at timestamptz check(starts_at is null or isfinite(starts_at)),
 ends_at timestamptz check(ends_at is null or isfinite(ends_at)),
 archived_at timestamptz,
 revision uuid not null default gen_random_uuid(),
 created_at timestamptz not null default clock_timestamp(),
 updated_at timestamptz not null default clock_timestamp(),
 check(starts_at is null or ends_at is null or ends_at>starts_at),
 check(archived_at is null or not is_active),
 foreign key(tenant_id,media_id) references app_private.tenant_partner_media(tenant_id,id)
);
create index tenant_partners_order on public.tenant_partners(tenant_id,display_order,created_at,id);
create index tenant_partners_media on public.tenant_partners(media_id);
alter table public.tenant_partners enable row level security;
revoke all on public.tenant_partners from public,anon,authenticated,service_role;

-- Minimal private audit, following the public-access audit pattern. No customer
-- data, image bytes or shared audit-trigger rewrite. Actor IDs are historical.
create table app_private.tenant_partner_changes (
 id uuid primary key default gen_random_uuid(),
 tenant_id uuid not null references public.tenants(id),
 partner_id uuid not null references public.tenant_partners(id),
 actor_user_id uuid not null,
 actions text[] not null,
 created_at timestamptz not null default clock_timestamp()
);
alter table app_private.tenant_partner_changes enable row level security;
revoke all on app_private.tenant_partner_changes from public,anon,authenticated,service_role;

create function app_private.partner_admin_v1(tid uuid,actor uuid)
returns boolean language sql stable security invoker set search_path=pg_catalog,public,pg_temp as $$
 select exists(select 1 from public.tenants t join public.tenant_memberships m on m.tenant_id=t.id
 where t.id=tid and t.status='active' and m.user_id=actor and m.status='active' and m.role='admin');
$$;
revoke all on function app_private.partner_admin_v1(uuid,uuid) from public,anon,authenticated,service_role;

create function app_private.partner_public_json_v1(p public.tenant_partners)
returns jsonb language sql immutable security invoker set search_path=pg_catalog,public,pg_temp as $$
 select jsonb_build_object('id',p.id,'name',p.name,'kind',p.kind,'display_format',p.display_format,
 'media_id',p.media_id,'target_url',p.target_url,'short_description',p.short_description,'display_order',p.display_order);
$$;
revoke all on function app_private.partner_public_json_v1(public.tenant_partners) from public,anon,authenticated,service_role;

create function public.admin_get_tenant_partners_v1(p_tenant_slug text)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public,pg_temp as $$
declare tid uuid; result jsonb;
begin
 select id into tid from public.tenants where slug=p_tenant_slug;
 if not app_private.partner_admin_v1(tid,auth.uid()) then raise exception 'forbidden' using errcode='42501'; end if;
 select coalesce(jsonb_agg(app_private.partner_public_json_v1(p)||jsonb_build_object(
 'is_active',p.is_active,'starts_at',p.starts_at,'ends_at',p.ends_at,'archived_at',p.archived_at,'revision',p.revision,
 'status',case when p.archived_at is not null then 'archived' when not p.is_active then 'inactive'
 when p.starts_at>statement_timestamp() then 'scheduled' when p.ends_at<=statement_timestamp() then 'expired' else 'active' end)
 order by p.display_order,p.created_at,p.id),'[]'::jsonb) into result from public.tenant_partners p where tenant_id=tid;
 return jsonb_build_object('tenant_id',tid,'public_slug',(select public_slug from public.tenant_public_profiles where tenant_id=tid),'items',result);
end; $$;

create function public.get_public_tenant_partners_v1(p_public_slug text)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public,pg_temp as $$
declare tid uuid; result jsonb;
begin
 select t.id into tid from public.tenants t join public.tenant_public_profiles p on p.tenant_id=t.id
 where t.status='active' and p.is_public and p.public_slug=p_public_slug;
 if tid is null then return '[]'::jsonb; end if;
 perform app_private.require_tenant_public_business_v1(tid);
 select coalesce(jsonb_agg(app_private.partner_public_json_v1(p) order by p.display_order,p.created_at,p.id),'[]'::jsonb)
 into result from public.tenant_partners p where tenant_id=tid and is_active and archived_at is null
 and (starts_at is null or starts_at<=statement_timestamp()) and (ends_at is null or ends_at>statement_timestamp());
 return result;
end; $$;

-- Authenticated actor remains auth.uid() for all content mutation. Service role
-- can only register bounded, server-decoded media; it cannot publish a partner.
create function public.register_tenant_partner_media_v1(p_tenant_id uuid,p_actor_id uuid,p_media_id uuid,p_width integer,p_height integer,p_size integer,p_sha256 text)
returns void language plpgsql security definer set search_path=pg_catalog,public,pg_temp as $$
begin
 if not app_private.partner_admin_v1(p_tenant_id,p_actor_id) then raise exception 'forbidden' using errcode='42501'; end if;
 insert into app_private.tenant_partner_media(id,tenant_id,actor_user_id,width,height,byte_size,sha256)
 values(p_media_id,p_tenant_id,p_actor_id,p_width,p_height,p_size,p_sha256);
end; $$;

create function public.discard_tenant_partner_media_v1(p_tenant_id uuid,p_media_id uuid)
returns boolean language plpgsql security definer set search_path=pg_catalog,public,pg_temp as $$
begin
 -- FK serializes a concurrent attach against deletion. Never remove referenced
 -- assets, including archived entries. Storage removal follows only true.
 delete from app_private.tenant_partner_media m where tenant_id=p_tenant_id and id=p_media_id
 and not exists(select 1 from public.tenant_partners p where p.media_id=m.id);
 return found;
end; $$;

create function public.admin_save_tenant_partner_v1(p_tenant_slug text,p_id uuid,p_expected_revision uuid,p_values jsonb,p_media_id uuid,p_archive boolean default false)
returns jsonb language plpgsql volatile security definer set search_path=pg_catalog,public,pg_temp set lock_timeout='3s' as $$
declare tid uuid; old public.tenant_partners%rowtype; next_row public.tenant_partners%rowtype; acts text[]:=array[]::text[];
begin
 select id into tid from public.tenants where slug=p_tenant_slug;
 if not app_private.partner_admin_v1(tid,auth.uid()) then raise exception 'forbidden' using errcode='42501'; end if;
 -- Protect lifecycle and membership while publishing; compatible with existing
 -- tenant/member row locks. Tenant lock also bounds concurrent creations.
 perform 1 from public.tenants where id=tid for update;
 perform 1 from public.tenant_memberships where tenant_id=tid and user_id=auth.uid() for share;
 if not app_private.partner_admin_v1(tid,auth.uid()) then raise exception 'forbidden' using errcode='42501'; end if;
 select * into old from public.tenant_partners where id=p_id for update;
 if old.id is not null and old.tenant_id<>tid then raise exception 'forbidden' using errcode='42501'; end if;
 if p_id is null or old.revision is distinct from p_expected_revision or old.archived_at is not null then
 raise exception 'PARTNER_CONFLICT' using errcode='PT409'; end if;
 if p_archive is null then raise exception 'invalid_request' using errcode='22023'; end if;
 if p_archive then
   if old.id is null then raise exception 'invalid_request' using errcode='22023'; end if;
   update public.tenant_partners set is_active=false,archived_at=clock_timestamp(),updated_at=clock_timestamp(),revision=gen_random_uuid() where id=p_id;
   acts:=array['archive'];
 else
   if p_values is null or jsonb_typeof(p_values)<>'object' or
   (select array_agg(key order by key) from jsonb_object_keys(p_values) key) is distinct from
   array['display_format','display_order','ends_at','is_active','kind','name','short_description','starts_at','target_url']::text[]
   or exists(select 1 from unnest(array['name','kind','display_format']) k where jsonb_typeof(p_values->k)<>'string')
   or exists(select 1 from unnest(array['short_description','target_url','starts_at','ends_at']) k where jsonb_typeof(p_values->k) not in ('string','null'))
   or jsonb_typeof(p_values->'is_active')<>'boolean' or (p_values->>'display_order') !~ '^[0-9]{1,4}$'
   then raise exception 'invalid_request' using errcode='22023'; end if;
   if old.id is null and (select count(*) from public.tenant_partners where tenant_id=tid)>=100 then
   raise exception 'PARTNER_LIMIT' using errcode='22023'; end if;
   if not exists(select 1 from app_private.tenant_partner_media where id=p_media_id and tenant_id=tid
     and (actor_user_id=auth.uid() or id=old.media_id)) then raise exception 'forbidden_media' using errcode='42501'; end if;
   insert into public.tenant_partners(id,tenant_id,name,kind,display_format,media_id,target_url,short_description,is_active,display_order,starts_at,ends_at)
   values(p_id,tid,p_values->>'name',p_values->>'kind',p_values->>'display_format',p_media_id,p_values->>'target_url',
   p_values->>'short_description',(p_values->>'is_active')::boolean,(p_values->>'display_order')::integer,
   (p_values->>'starts_at')::timestamptz,(p_values->>'ends_at')::timestamptz)
   on conflict(id) do update set name=excluded.name,kind=excluded.kind,display_format=excluded.display_format,
   media_id=excluded.media_id,target_url=excluded.target_url,short_description=excluded.short_description,
   is_active=excluded.is_active,display_order=excluded.display_order,starts_at=excluded.starts_at,ends_at=excluded.ends_at,
   updated_at=clock_timestamp(),revision=gen_random_uuid()
   -- Two tenants lock different tenant rows. A simultaneous first insertion
   -- of the same UUID must never update the other tenant's winning row.
   where tenant_partners.tenant_id=tid
     and tenant_partners.revision=p_expected_revision;
   if not found then raise exception 'PARTNER_CONFLICT' using errcode='PT409'; end if;
   select * into next_row from public.tenant_partners where id=p_id;
   acts:=array[case when old.id is null then 'create' else 'edit' end];
   if next_row.is_active and (old.id is null or not old.is_active) then acts:=acts||'activate'::text; end if;
   if old.is_active and not next_row.is_active then acts:=acts||'deactivate'::text; end if;
   if old.id is not null and old.display_order<>next_row.display_order then acts:=acts||'reorder'::text; end if;
 end if;
 insert into app_private.tenant_partner_changes(tenant_id,partner_id,actor_user_id,actions) values(tid,p_id,auth.uid(),acts);
 return public.admin_get_tenant_partners_v1(p_tenant_slug);
end; $$;

-- Returns only a server-generated path after the same visibility gate as the
-- public list. Admin preview includes inactive items, but only for own tenant.
create function public.get_tenant_partner_media_v1(p_media_id uuid)
returns text language sql stable security definer set search_path=pg_catalog,public,pg_temp as $$
 select m.tenant_id::text||'/partners/'||m.id::text||'.webp'
 from app_private.tenant_partner_media m join public.tenant_partners p on p.media_id=m.id and p.tenant_id=m.tenant_id
 where m.id=p_media_id and (app_private.partner_admin_v1(m.tenant_id,auth.uid()) or
 (p.is_active and p.archived_at is null and (p.starts_at is null or p.starts_at<=statement_timestamp())
 and (p.ends_at is null or p.ends_at>statement_timestamp())
 and exists(select 1 from public.tenant_public_profiles profile where profile.tenant_id=p.tenant_id and profile.is_public)
 and public.can_access_tenant_public_business_v1(m.tenant_id))) limit 1;
$$;

revoke all on function public.admin_get_tenant_partners_v1(text),public.get_public_tenant_partners_v1(text),
 public.register_tenant_partner_media_v1(uuid,uuid,uuid,integer,integer,integer,text),public.discard_tenant_partner_media_v1(uuid,uuid),
 public.admin_save_tenant_partner_v1(text,uuid,uuid,jsonb,uuid,boolean),public.get_tenant_partner_media_v1(uuid)
 from public,anon,authenticated,service_role;
grant execute on function public.admin_get_tenant_partners_v1(text),public.admin_save_tenant_partner_v1(text,uuid,uuid,jsonb,uuid,boolean) to authenticated;
grant execute on function public.get_public_tenant_partners_v1(text),public.get_tenant_partner_media_v1(uuid) to anon,authenticated;
grant execute on function public.register_tenant_partner_media_v1(uuid,uuid,uuid,integer,integer,integer,text),public.discard_tenant_partner_media_v1(uuid,uuid) to service_role;

-- Reconcile the existing fail-closed dependency catalog with the three additive
-- partner tables. This reader still never authorizes hard deletion.
do $$ begin
 if md5(pg_get_functiondef('public.platform_get_tenant_delete_eligibility_v1(uuid)'::regprocedure))<>'bf99bf5dba55e24659435da4790cd7c6' then raise exception 'partner dependency input drift'; end if;
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

 catalog_matches:=md5(catalog::text)='bbd16e963567ded6886895c1736953d4';
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
$function$

;
