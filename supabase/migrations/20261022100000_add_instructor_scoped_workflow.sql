-- INSTRUCTOR-1B/C draft: atomic event staffing contracts. No historical edits.
begin;
set local lock_timeout='5s';
set local statement_timeout='30s';

-- Private INVOKER helper: canonical structural revision, not caller authority.
-- Includes visibility/cancellation and lane IDs so concurrent changes cannot be
-- silently overwritten. No grants to browser or service roles.
create function public.instructor_event_revision_v1(p_event_id uuid)
returns jsonb language sql stable security invoker
set search_path=pg_catalog,public,pg_temp as $fn$
 select jsonb_build_object('title',e.title,'description',e.description,
   'event_date',e.event_date,'start_time',e.start_time,'end_time',e.end_time,
   'location',e.location,'price',e.price,'max_participants',e.max_participants,
   'is_active',e.is_active,'cancelled_at',e.cancelled_at,
   'lane_ids',coalesce((select jsonb_agg(l.lane_id order by l.lane_id)
     from public.event_lanes l where l.event_id=e.id and l.tenant_id=e.tenant_id),'[]'::jsonb))
 from public.events e where e.id=p_event_id;
$fn$;

create function public.admin_list_tenant_instructors_v1(
 p_tenant_id uuid,p_limit integer default 100,p_offset integer default 0
) returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,pg_temp as $fn$
declare v_items jsonb;
begin
 if auth.uid() is null
   or coalesce(public.get_my_tenant_role_v1(p_tenant_id),'') not in ('admin','employee')
   or public.get_my_tenant_feature_access_v1(p_tenant_id,'events') is distinct from true
   or not exists(select 1 from public.tenants where id=p_tenant_id and status='active') then
  raise exception 'Not authorized' using errcode='42501';
 end if;
 if p_limit is null or p_limit<1 or p_limit>100 or p_offset is null or p_offset<0 or p_offset>100000 then
  raise exception 'Invalid pagination' using errcode='22023';
 end if;
 select coalesce(jsonb_agg(jsonb_build_object('user_id',q.user_id,'display_name',q.display_name) order by q.user_id),'[]'::jsonb)
 into v_items from (
  select m.user_id,coalesce(nullif(btrim(p.full_name),''),nullif(btrim(concat_ws(' ',p.first_name,p.last_name)),''),'Instruktor') display_name
  from public.tenant_memberships m join public.profiles p on p.user_id=m.user_id
  where m.tenant_id=p_tenant_id and m.role='instructor' and m.status='active'
  order by m.user_id limit p_limit offset p_offset
 ) q;
 return v_items;
end;
$fn$;

create function public.admin_create_event_with_instructors_v1(
 p_tenant_id uuid,p_title text,p_description text,p_event_date date,
 p_start_time time without time zone,p_end_time time without time zone,
 p_location text,p_price numeric,p_max_participants integer,
 p_lane_ids uuid[],p_instructor_user_ids uuid[]
) returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,pg_temp as $fn$
declare v_result jsonb;v_event uuid;v_lookup jsonb;v_assignments jsonb;
begin
 -- Existing create contract performs its original tenant, lifecycle, entitlement,
 -- lane-conflict and input checks. No exception handler may commit partial work.
 v_result:=public.admin_create_event_v3(p_tenant_id,p_title,p_description,p_event_date,
   p_start_time,p_end_time,p_location,p_price,p_max_participants,p_lane_ids);
 if (v_result->>'ok') is distinct from 'true' then return v_result;end if;
 v_event:=(v_result->>'event_id')::uuid;
 if v_event is null then raise exception 'Invalid event result' using errcode='22023';end if;
 v_lookup:=public.admin_list_available_event_instructors_v1(v_event);
 v_assignments:=public.admin_set_event_instructors_v1(v_event,p_instructor_user_ids,v_lookup->>'revision');
 return v_result||jsonb_build_object('event_revision',public.instructor_event_revision_v1(v_event),
   'assignments',v_assignments);
end;
$fn$;

create function public.admin_update_event_with_instructors_v1(
 p_tenant_id uuid,p_event_id uuid,p_title text,p_description text,p_event_date date,
 p_start_time time without time zone,p_end_time time without time zone,
 p_location text,p_price numeric,p_max_participants integer,
 p_lane_ids uuid[],p_instructor_user_ids uuid[],
 p_expected_event_revision jsonb,p_expected_assignment_revision text
) returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,pg_temp as $fn$
declare v_result jsonb;v_assignments jsonb;
begin
 -- Authorize before comparing the revision; unauthorized callers learn no state.
 if auth.uid() is null or coalesce(public.get_my_tenant_role_v1(p_tenant_id),'') not in ('admin','employee')
   or public.get_my_tenant_feature_access_v1(p_tenant_id,'events') is distinct from true then
  raise exception 'Not authorized' using errcode='42501';
 end if;
 perform 1 from public.events e where e.id=p_event_id and e.tenant_id=p_tenant_id for update;
 if not found then raise exception 'Not authorized' using errcode='42501';end if;
 if p_expected_event_revision is null or p_expected_event_revision is distinct from public.instructor_event_revision_v1(p_event_id) then
  raise exception 'Event revision conflict' using errcode='40001';
 end if;
 v_result:=public.admin_update_event_v3(p_tenant_id,p_event_id,p_title,p_description,p_event_date,
   p_start_time,p_end_time,p_location,p_price,p_max_participants,p_lane_ids);
 if (v_result->>'ok') is distinct from 'true' then return v_result;end if;
 -- This existing writer locks/revalidates actor, selected memberships, lifecycle,
 -- cancellation and revision. Any exception rolls back the event update above.
 v_assignments:=public.admin_set_event_instructors_v1(p_event_id,p_instructor_user_ids,p_expected_assignment_revision);
 return v_result||jsonb_build_object('event_revision',public.instructor_event_revision_v1(p_event_id),
   'assignments',v_assignments);
end;
$fn$;

alter function public.instructor_event_revision_v1(uuid) owner to postgres;
revoke all on function public.instructor_event_revision_v1(uuid) from public,anon,authenticated,service_role;
alter function public.admin_list_tenant_instructors_v1(uuid,integer,integer) owner to postgres;
revoke all on function public.admin_list_tenant_instructors_v1(uuid,integer,integer) from public,anon,authenticated,service_role;
grant execute on function public.admin_list_tenant_instructors_v1(uuid,integer,integer) to authenticated;
alter function public.admin_create_event_with_instructors_v1(uuid,text,text,date,time,time,text,numeric,integer,uuid[],uuid[]) owner to postgres;
revoke all on function public.admin_create_event_with_instructors_v1(uuid,text,text,date,time,time,text,numeric,integer,uuid[],uuid[]) from public,anon,authenticated,service_role;
grant execute on function public.admin_create_event_with_instructors_v1(uuid,text,text,date,time,time,text,numeric,integer,uuid[],uuid[]) to authenticated;
alter function public.admin_update_event_with_instructors_v1(uuid,uuid,text,text,date,time,time,text,numeric,integer,uuid[],uuid[],jsonb,text) owner to postgres;
revoke all on function public.admin_update_event_with_instructors_v1(uuid,uuid,text,text,date,time,time,text,numeric,integer,uuid[],uuid[],jsonb,text) from public,anon,authenticated,service_role;
grant execute on function public.admin_update_event_with_instructors_v1(uuid,uuid,text,text,date,time,time,text,numeric,integer,uuid[],uuid[],jsonb,text) to authenticated;
create function public.get_my_instructor_events_v1(
 p_tenant_id uuid,p_scope text default 'upcoming',p_event_id uuid default null,
 p_limit integer default 20,p_offset integer default 0
) returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,pg_temp as $fn$
declare v_result jsonb;
begin
 if auth.uid() is null or public.get_my_tenant_role_v1(p_tenant_id) is distinct from 'instructor'
   or public.get_my_tenant_feature_access_v1(p_tenant_id,'events') is distinct from true
   or not exists(select 1 from public.tenants where id=p_tenant_id and status='active') then
  raise exception 'Not authorized' using errcode='42501';
 end if;
 if p_scope is null or p_scope not in ('upcoming','past','cancelled') or p_limit is null
   or p_limit<1 or p_limit>50 or p_offset is null or p_offset<0 or p_offset>100000 then
  raise exception 'Invalid pagination' using errcode='22023';
 end if;
 if p_event_id is not null and not exists(select 1 from public.events e join public.event_instructors i
   on i.event_id=e.id and i.tenant_id=e.tenant_id where e.id=p_event_id and e.tenant_id=p_tenant_id
   and i.instructor_user_id=auth.uid() and i.unassigned_at is null) then
  raise exception 'Not authorized' using errcode='42501';
 end if;
 with scoped as materialized (
  select e.id,e.title,e.description,e.event_date,e.start_time,e.end_time,e.location,e.cancelled_at,
   (e.event_date+e.end_time) at time zone 'Europe/Warsaw' as ends_at
  from public.events e join public.event_instructors i on i.event_id=e.id and i.tenant_id=e.tenant_id
  where e.tenant_id=p_tenant_id and i.instructor_user_id=auth.uid() and i.unassigned_at is null
   and (p_event_id is null or e.id=p_event_id)
 ), filtered as materialized (
  select * from scoped where p_event_id is not null or case p_scope
   when 'cancelled' then cancelled_at is not null
   when 'past' then cancelled_at is null and ends_at<=statement_timestamp()
   else cancelled_at is null and ends_at>statement_timestamp() end
 ), page_rows as (
  select * from filtered order by event_date,start_time,id limit p_limit offset p_offset
 ) select jsonb_build_object('total',(select count(*) from filtered),'items',coalesce((select jsonb_agg(
  jsonb_build_object('id',id,'title',title,'description',description,'event_date',event_date,
   'start_time',start_time,'end_time',end_time,'location',location,
   'status',case when cancelled_at is not null then 'cancelled' when ends_at<=statement_timestamp() then 'past' else 'upcoming' end,
   'participants_available',cancelled_at is null and statement_timestamp()<ends_at+interval '30 days')
   order by event_date,start_time,id) from page_rows),'[]'::jsonb)) into v_result;
 return v_result;
end;
$fn$;

create function public.get_instructor_event_participants_v1(
 p_event_id uuid,p_section text default 'participants',p_limit integer default 50,p_offset integer default 0
) returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,pg_temp as $fn$
declare v_event public.events%rowtype;v_result jsonb;
begin
 select e.* into v_event from public.events e join public.event_instructors i
  on i.event_id=e.id and i.tenant_id=e.tenant_id
 where e.id=p_event_id and i.instructor_user_id=auth.uid() and i.unassigned_at is null;
 if not found or auth.uid() is null
   or public.get_my_tenant_role_v1(v_event.tenant_id) is distinct from 'instructor'
   or public.get_my_tenant_feature_access_v1(v_event.tenant_id,'events') is distinct from true
   or not exists(select 1 from public.tenants where id=v_event.tenant_id and status='active')
   or v_event.cancelled_at is not null
   or statement_timestamp()>=((v_event.event_date+v_event.end_time) at time zone 'Europe/Warsaw')+interval '30 days' then
  raise exception 'Not authorized' using errcode='42501';
 end if;
 if p_section is null or p_section not in ('participants','reserve') or p_limit is null or p_limit<1 or p_limit>100
   or p_offset is null or p_offset<0 or p_offset>100000 then
  raise exception 'Invalid pagination' using errcode='22023';
 end if;
 with eligible as materialized (
  select r.id,r.customer_name,r.registration_status,r.created_at from public.event_registrations r
  where r.event_id=p_event_id and r.tenant_id=v_event.tenant_id
    and r.pii_anonymized_at is null
    and case p_section when 'reserve' then r.registration_status='reserve'
      else r.registration_status in ('registered','approved') end
 ), page_rows as (
  select * from eligible order by created_at,id limit p_limit offset p_offset
 ) select jsonb_build_object('total',(select count(*) from eligible),'items',coalesce((select jsonb_agg(
  jsonb_build_object('registration_id',id,'display_name',customer_name,'registration_status',registration_status)
  order by created_at,id) from page_rows),'[]'::jsonb)) into v_result;
 return v_result;
end;
$fn$;
alter function public.get_my_instructor_events_v1(uuid,text,uuid,integer,integer) owner to postgres;
revoke all on function public.get_my_instructor_events_v1(uuid,text,uuid,integer,integer) from public,anon,authenticated,service_role;
grant execute on function public.get_my_instructor_events_v1(uuid,text,uuid,integer,integer) to authenticated;
alter function public.get_instructor_event_participants_v1(uuid,text,integer,integer) owner to postgres;
revoke all on function public.get_instructor_event_participants_v1(uuid,text,integer,integer) from public,anon,authenticated,service_role;
grant execute on function public.get_instructor_event_participants_v1(uuid,text,integer,integer) to authenticated;
commit;
