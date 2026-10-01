-- PRIVACY-TECH-1. No legal-policy/retention change. Legacy export v1/v2 remains intact.
begin;
set local lock_timeout='5s';
set local statement_timeout='30s';

do $preflight$
begin
 if to_regprocedure('public.export_my_data_v3()') is not null then raise exception 'Export v3 already exists'; end if;
 if not exists(select 1 from pg_constraint where conrelid='public.tenant_domains'::regclass
  and conname='tenant_domains_verification_requested_by_fkey' and contype='f' and confdeltype='a'
  and pg_get_constraintdef(oid)='FOREIGN KEY (verification_requested_by) REFERENCES auth.users(id)') then
  raise exception 'Domain requester FK drift';
 end if;
 if not exists(select 1 from pg_proc where oid='public.export_my_data_v1()'::regprocedure
  and prosecdef and proowner='postgres'::regrole and proconfig=array['search_path=pg_catalog, public, pg_temp']) then
  raise exception 'Owner export authority drift';
 end if;
end;$preflight$;

alter table public.tenant_domains drop constraint tenant_domains_verification_requested_by_fkey;
alter table public.tenant_domains add constraint tenant_domains_verification_requested_by_fkey
 foreign key(verification_requested_by) references auth.users(id) on delete set null;

create function public.export_my_data_v3()
returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,pg_temp as $function$
declare
 subject uuid:=auth.uid(); base jsonb; result jsonb; row_count bigint;
 account_additions jsonb; profile_additions jsonb; reservation_data jsonb; registration_data jsonb;
 assignment_data jsonb; delivery_data jsonb; schedule_data jsonb; occurrence_data jsonb;
 platform_role jsonb; platform_history jsonb; audit_history jsonb; settlement_data jsonb; domain_data jsonb;
begin
 if subject is null then raise exception 'Authentication is required.' using errcode='42501'; end if;
 -- Fail explicitly, never LIMIT/truncate. Count before materializing old/new arrays.
 select
  (select count(*) from public.reservations r where r.user_id=subject)+
  (select count(*) from public.event_registrations r where r.user_id=subject)+
  (select count(*) from public.tenant_memberships m where m.user_id=subject)+
  (select count(*) from public.event_instructors i where i.instructor_user_id=subject or i.assigned_by=subject or i.unassigned_by=subject)+
  (select count(*) from public.email_deliveries d where d.recipient_user_id=subject)+
  (select count(*) from public.reminder_schedules s where exists(select 1 from public.reservations r where r.id=s.reservation_id and r.user_id=subject)
   or exists(select 1 from public.event_registrations r where r.event_id=s.event_id and r.user_id=subject))+
  (select count(*) from public.reminder_occurrences o where exists(select 1 from public.reservations r where r.id=o.reservation_id and r.user_id=subject)
   or exists(select 1 from public.event_registrations r where r.id=o.registration_id and r.user_id=subject))+
  (select count(*) from public.platform_audit_logs a where a.actor_user_id=subject or a.details->>'user_id'=subject::text)+
  (select count(*) from public.audit_logs a where a.actor_user_id=subject or (a.target_id=subject and a.target_type in
   ('profile','account','tenant_user_admin_note','tenant_user_verification','tenant_user_role','tenant_user_identity','tenant_user_contact'))
   or exists(select 1 from public.reservations r where r.id=a.target_id and r.user_id=subject)
   or exists(select 1 from public.event_registrations r where r.id=a.target_id and r.user_id=subject))+
  (select count(*) from public.external_settlement_records s where s.actor_user_id=subject
   or exists(select 1 from public.reservations r where r.id=s.reservation_id and r.user_id=subject)
   or exists(select 1 from public.event_registrations r where r.id=s.registration_id and r.user_id=subject))+
  (select count(*) from public.tenant_domains d where d.verification_requested_by=subject)
 into row_count;
 if row_count>10000 then raise exception 'Complete export exceeds synchronous capacity.' using errcode='54000'; end if;

 base:=public.export_my_data_v1(); -- Existing strict allowlist and auth.uid authority, not a table dump.
 select jsonb_build_object('updated_at',u.updated_at,'email_confirmed_at',u.email_confirmed_at,
  'phone_confirmed_at',u.phone_confirmed_at,'last_sign_in_at',u.last_sign_in_at,
  'pending_email',nullif(u.email_change,''),'pending_phone',nullif(u.phone_change,''))
 into account_additions from auth.users u where u.id=subject;
 select jsonb_build_object('verified_at',p.verified_at,'unverified_at',p.unverified_at)
 into profile_additions from public.profiles p where p.user_id=subject;

 select coalesce(jsonb_agg(item.value||jsonb_build_object(
  'tenant',jsonb_build_object('id',t.id,'name',t.name,'slug',t.slug),
  'customer_name',r.customer_name,'customer_email',r.customer_email,'customer_phone',r.customer_phone,
  'pii_anonymized_at',r.pii_anonymized_at) order by r.created_at,r.id),'[]'::jsonb)
 into reservation_data from jsonb_array_elements(base->'reservations') item(value)
 join public.reservations r on r.id=(item.value->>'id')::uuid and r.user_id=subject
 join public.tenants t on t.id=r.tenant_id;

 select coalesce(jsonb_agg(item.value||jsonb_build_object(
  'tenant',jsonb_build_object('id',t.id,'name',t.name,'slug',t.slug),
  'event',case when e.id is null then null else jsonb_build_object('id',e.id,'title',e.title,'event_date',e.event_date,'start_time',e.start_time,'end_time',e.end_time) end,
  'customer_name',r.customer_name,'customer_email',r.customer_email,'customer_phone',r.customer_phone,
  'cancellation_email_initialized_at',r.cancellation_email_initialized_at,
  'attendance_status',r.attendance_status,'attendance_marked_at',r.attendance_marked_at,
  'attendance_version',r.attendance_version,'attendance_marked_by_me',coalesce(r.attendance_marked_by=subject,false),
  'pii_anonymized_at',r.pii_anonymized_at) order by r.created_at,r.id),'[]'::jsonb)
 into registration_data from jsonb_array_elements(base->'event_registrations') item(value)
 join public.event_registrations r on r.id=(item.value->>'id')::uuid and r.user_id=subject
 join public.tenants t on t.id=r.tenant_id left join public.events e on e.id=r.event_id and e.tenant_id=r.tenant_id;

 select coalesce(jsonb_agg(jsonb_build_object('id',i.id,
  'tenant',jsonb_build_object('id',t.id,'name',t.name,'slug',t.slug),
  'event',jsonb_build_object('id',e.id,'title',e.title,'event_date',e.event_date,'start_time',e.start_time,'end_time',e.end_time),
  'assigned_at',i.assigned_at,'unassigned_at',i.unassigned_at,
  'assignment_status',case when i.unassigned_at is null then 'active' else 'history' end,
  'is_instructor',coalesce(i.instructor_user_id=subject,false),'assigned_by_me',coalesce(i.assigned_by=subject,false),
  'unassigned_by_me',coalesce(i.unassigned_by=subject,false)) order by i.assigned_at,i.id),'[]'::jsonb)
 into assignment_data from public.event_instructors i join public.tenants t on t.id=i.tenant_id
 join public.events e on e.id=i.event_id and e.tenant_id=i.tenant_id
 where i.instructor_user_id=subject or i.assigned_by=subject or i.unassigned_by=subject;

 select coalesce(jsonb_agg(jsonb_build_object('id',d.id,'tenant',jsonb_build_object('id',t.id,'name',t.name,'slug',t.slug),
  'message_type',d.message_type,'resource_id',d.record_id,'sent_at',d.sent_at,'delivery_state',d.delivery_state,
  'attempt_count',d.attempt_count,'created_at',d.created_at,'updated_at',d.updated_at) order by d.created_at,d.id),'[]'::jsonb)
 into delivery_data from public.email_deliveries d join public.tenants t on t.id=d.tenant_id where d.recipient_user_id=subject;

 select coalesce(jsonb_agg(x.value order by x.resource_id,x.schedule_id),'[]'::jsonb) into schedule_data from (
  select r.id resource_id,s.id schedule_id,jsonb_build_object('id',s.id,'tenant',jsonb_build_object('id',t.id,'name',t.name,'slug',t.slug),
   'resource_type','reservation','resource_id',r.id,'generation',s.generation,'scheduled_start',s.scheduled_start,'changed_at',s.changed_at) value
  from public.reminder_schedules s join public.reservations r on r.id=s.reservation_id and r.user_id=subject join public.tenants t on t.id=r.tenant_id
  union all
  select r.id,s.id,jsonb_build_object('id',s.id,'tenant',jsonb_build_object('id',t.id,'name',t.name,'slug',t.slug),
   'resource_type','event_registration','resource_id',r.id,'generation',s.generation,'scheduled_start',s.scheduled_start,'changed_at',s.changed_at)
  from public.reminder_schedules s join public.event_registrations r on r.event_id=s.event_id and r.user_id=subject
  join public.events e on e.id=r.event_id and e.tenant_id=r.tenant_id join public.tenants t on t.id=r.tenant_id
 ) x;
 select coalesce(jsonb_agg(jsonb_build_object('id',o.id,'schedule_id',o.schedule_id,
  'tenant',jsonb_build_object('id',t.id,'name',t.name,'slug',t.slug),'message_type',o.message_type,
  'resource_type',case when r.id is not null then 'reservation' else 'event_registration' end,
  'resource_id',coalesce(r.id,g.id),'generation',o.generation,'scheduled_start',o.scheduled_start,'created_at',o.created_at)
  order by o.created_at,o.id),'[]'::jsonb)
 into occurrence_data from public.reminder_occurrences o
 left join public.reservations r on r.id=o.reservation_id and r.user_id=subject
 left join public.event_registrations g on g.id=o.registration_id and g.user_id=subject
 join public.tenants t on t.id=coalesce(r.tenant_id,g.tenant_id) where r.id is not null or g.id is not null;

 select jsonb_build_object('status',p.status,'created_at',p.created_at) into platform_role
 from public.platform_admins p where p.user_id=subject;
 select coalesce(jsonb_agg(jsonb_build_object('id',a.id,'tenant',case when t.id is null then null else jsonb_build_object('id',t.id,'name',t.name,'slug',t.slug) end,
  'action',a.action,'created_at',a.created_at,'relation',case when a.actor_user_id=subject then 'actor' else 'subject' end)
  order by a.created_at,a.id),'[]'::jsonb) into platform_history
 from public.platform_audit_logs a left join public.tenants t on t.id=a.tenant_id
 where a.actor_user_id=subject or a.details->>'user_id'=subject::text;

 -- action is unconstrained free text in audit_logs: omit it entirely, never scrub heuristically.
 -- Export event metadata only. Never emit arbitrary details or the target identity of another person.
 select coalesce(jsonb_agg(jsonb_build_object('id',a.id,
  'tenant',case when t.id is null then null else jsonb_build_object('id',t.id,'name',t.name,'slug',t.slug) end,
  'target_type',a.target_type,'created_at',a.created_at,
  'relation',case when a.actor_user_id=subject then 'actor' when a.target_id=subject then 'subject' else 'resource' end)
  order by a.created_at,a.id),'[]'::jsonb) into audit_history from public.audit_logs a left join public.tenants t on t.id=a.tenant_id
 where a.actor_user_id=subject or (a.target_id=subject and a.target_type in
  ('profile','account','tenant_user_admin_note','tenant_user_verification','tenant_user_role','tenant_user_identity','tenant_user_contact'))
 or exists(select 1 from public.reservations r where r.id=a.target_id and r.user_id=subject)
 or exists(select 1 from public.event_registrations r where r.id=a.target_id and r.user_id=subject);

 select coalesce(jsonb_agg(jsonb_build_object('id',s.id,'tenant',jsonb_build_object('id',t.id,'name',t.name,'slug',t.slug),
  'kind',s.kind,'amount',s.amount,'currency',s.currency,'recorded_at',s.recorded_at,
  'acted_by_me',s.actor_user_id=subject,'reservation_id',r.id,'registration_id',g.id)
  order by s.recorded_at,s.id),'[]'::jsonb) into settlement_data from public.external_settlement_records s
 left join public.reservations r on r.id=s.reservation_id and r.user_id=subject
 left join public.event_registrations g on g.id=s.registration_id and g.user_id=subject join public.tenants t on t.id=s.tenant_id
 where s.actor_user_id=subject or r.id is not null or g.id is not null;

 select coalesce(jsonb_agg(jsonb_build_object('id',d.id,'tenant',jsonb_build_object('id',t.id,'name',t.name,'slug',t.slug),
  'hostname',d.hostname,'domain_type',d.domain_type,'status',d.status,'is_primary',d.is_primary,
  'verified_at',d.verified_at,'created_at',d.created_at,'updated_at',d.updated_at) order by d.created_at,d.id),'[]'::jsonb)
 into domain_data from public.tenant_domains d join public.tenants t on t.id=d.tenant_id where d.verification_requested_by=subject;

 result:=base||jsonb_build_object('export_version',3,'account',(base->'account')||account_additions,
  'profile',case when base->'profile'='null'::jsonb then 'null'::jsonb else (base->'profile')||profile_additions end,
  'reservations',reservation_data,'event_registrations',registration_data,
  'event_instructors',assignment_data,'email_deliveries',delivery_data,
  'reminder_schedules',schedule_data,'reminder_occurrences',occurrence_data,
  'platform_admin',platform_role,'platform_audit_history',platform_history,'audit_history',audit_history,
  'external_settlements',settlement_data,'tenant_domain_requests',domain_data);
 if octet_length(result::text)>2097152 then raise exception 'Complete export exceeds synchronous capacity.' using errcode='54000'; end if;
 return result;
end;$function$;
alter function public.export_my_data_v3() owner to postgres;
revoke all on function public.export_my_data_v3() from public,anon,authenticated,service_role;
grant execute on function public.export_my_data_v3() to authenticated;
comment on function public.export_my_data_v3() is
 'PRIVACY-TECH-1 account-wide own allowlist; explicit capacity error, never partial export. Raw audit payloads/notes/secrets require separately authorized manual handling.';
commit;
