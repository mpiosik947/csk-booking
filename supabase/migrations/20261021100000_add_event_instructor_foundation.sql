-- INSTRUCTOR-1A: historical staffing foundation and SEC-008 closure only.
begin;
set local lock_timeout='5s';
set local statement_timeout='30s';

create table public.event_instructors (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  tenant_id uuid not null,
  event_id uuid not null,
  instructor_user_id uuid references public.profiles(user_id) on delete set null,
  assigned_at timestamptz not null default pg_catalog.clock_timestamp(),
  assigned_by uuid references public.profiles(user_id) on delete set null,
  unassigned_at timestamptz,
  unassigned_by uuid references public.profiles(user_id) on delete set null,
  constraint event_instructors_event_fk foreign key (tenant_id,event_id)
    references public.events(tenant_id,id) on delete cascade,
  constraint event_instructors_time_check check (unassigned_at is null or unassigned_at>=assigned_at),
  constraint event_instructors_removal_actor_check check (unassigned_at is not null or unassigned_by is null)
);
alter table public.event_instructors owner to postgres;
alter table public.event_instructors enable row level security;
revoke all on table public.event_instructors from public,anon,authenticated,service_role;
create unique index event_instructors_one_active on public.event_instructors(event_id,instructor_user_id)
  where unassigned_at is null;
create index event_instructors_history on public.event_instructors(tenant_id,event_id,id);
create index event_instructors_user_reference on public.event_instructors(instructor_user_id)
  where instructor_user_id is not null;
create index event_instructors_assigned_by_reference on public.event_instructors(assigned_by)
  where assigned_by is not null;
create index event_instructors_unassigned_by_reference on public.event_instructors(unassigned_by)
  where unassigned_by is not null;

comment on table public.event_instructors is
  'INSTRUCTOR-1A historical generations. No backfill. Profile deletion/anonymization clears user references; timestamps persist. Event CASCADE matches existing system cleanup, not a new app delete capability.';

create function public.admin_list_available_event_instructors_v1(
  p_event_id uuid,p_limit integer default 100,p_offset integer default 0
) returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,pg_temp as $fn$
declare v_tenant uuid; v_revision text; v_active uuid[]; v_items jsonb;
begin
  select e.tenant_id into v_tenant from public.events e where e.id=p_event_id;
  if not found or auth.uid() is null
     or coalesce(public.get_my_tenant_role_v1(v_tenant),'') not in ('admin','employee')
     or not public.get_my_tenant_feature_access_v1(v_tenant,'events') then
    raise exception 'Not authorized' using errcode='42501';
  end if;
  if p_limit is null or p_limit<1 or p_limit>100 or p_offset is null or p_offset<0 or p_offset>100000 then
    raise exception 'Invalid pagination' using errcode='22023';
  end if;
  select pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(coalesce(pg_catalog.jsonb_agg(
    pg_catalog.jsonb_build_array(i.id,i.instructor_user_id,extract(epoch from i.assigned_at),i.assigned_by,extract(epoch from i.unassigned_at),i.unassigned_by)
    order by i.id),'[]'::jsonb)::text,'UTF8')),'hex'),
    coalesce(pg_catalog.array_agg(i.instructor_user_id order by i.instructor_user_id)
      filter(where i.unassigned_at is null and i.instructor_user_id is not null),'{}'::uuid[])
  into v_revision,v_active from public.event_instructors i where i.tenant_id=v_tenant and i.event_id=p_event_id;
  select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('user_id',u.user_id,'display_name',u.display_name)
    order by u.user_id),'[]'::jsonb) into v_items from (
      select m.user_id,coalesce(nullif(pg_catalog.btrim(p.full_name),''),nullif(pg_catalog.btrim(pg_catalog.concat_ws(' ',p.first_name,p.last_name)),''),'Instruktor') as display_name
      from public.tenant_memberships m join public.profiles p on p.user_id=m.user_id
      where m.tenant_id=v_tenant and m.role='instructor' and m.status='active'
      order by m.user_id limit p_limit offset p_offset
    ) u;
  return pg_catalog.jsonb_build_object('revision',v_revision,'active_user_ids',v_active,'items',v_items);
end;
$fn$;

create function public.admin_set_event_instructors_v1(
  p_event_id uuid,p_instructor_user_ids uuid[],p_expected_revision text
) returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,pg_temp as $fn$
declare
  v_event public.events%rowtype; v_actor uuid:=auth.uid(); v_selected uuid[];
  v_current uuid[]; v_revision text; v_count integer; v_now timestamptz;
begin
  if v_actor is null then raise exception 'Not authorized' using errcode='42501'; end if;
  if p_instructor_user_ids is null or pg_catalog.cardinality(p_instructor_user_ids)>100
     or pg_catalog.array_position(p_instructor_user_ids,null) is not null
     or p_expected_revision is null or p_expected_revision !~ '^[0-9a-f]{64}$' then
    raise exception 'Invalid assignment set' using errcode='22023';
  end if;
  select coalesce(pg_catalog.array_agg(distinct u order by u),'{}'::uuid[]) into v_selected
    from pg_catalog.unnest(p_instructor_user_ids) u;
  if pg_catalog.cardinality(v_selected)<>pg_catalog.cardinality(p_instructor_user_ids) then
    raise exception 'Duplicate instructor' using errcode='22023';
  end if;
  select * into v_event from public.events e where e.id=p_event_id for update;
  if not found or coalesce(public.get_my_tenant_role_v1(v_event.tenant_id),'') not in ('admin','employee') then
    raise exception 'Not authorized' using errcode='42501';
  end if;
  perform 1 from public.tenants t where t.id=v_event.tenant_id and t.status='active' for share;
  if not found or v_event.cancelled_at is not null
     or not public.get_my_tenant_feature_access_v1(v_event.tenant_id,'events') then
    raise exception 'Event staffing unavailable' using errcode='42501';
  end if;
  -- Same profile-before-membership order as account anonymization. Stabilize FK targets
  -- and role/status against concurrent deletion, suspension or role changes.
  perform 1 from public.profiles p where p.user_id=v_actor or p.user_id=any(v_selected)
    order by p.user_id for key share;
  perform 1 from public.tenant_memberships m where m.tenant_id=v_event.tenant_id
    and (m.user_id=v_actor or m.user_id=any(v_selected)) order by m.user_id for share;
  if coalesce(public.get_my_tenant_role_v1(v_event.tenant_id),'') not in ('admin','employee') then
    raise exception 'Not authorized' using errcode='42501';
  end if;
  select pg_catalog.count(*) into v_count from public.tenant_memberships m
    join public.profiles p on p.user_id=m.user_id
    where m.tenant_id=v_event.tenant_id and m.user_id=any(v_selected)
      and m.role='instructor' and m.status='active';
  if v_count<>pg_catalog.cardinality(v_selected) then
    raise exception 'Invalid instructor membership' using errcode='42501';
  end if;
  select pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(coalesce(pg_catalog.jsonb_agg(
    pg_catalog.jsonb_build_array(i.id,i.instructor_user_id,extract(epoch from i.assigned_at),i.assigned_by,extract(epoch from i.unassigned_at),i.unassigned_by)
    order by i.id),'[]'::jsonb)::text,'UTF8')),'hex'),
    coalesce(pg_catalog.array_agg(i.instructor_user_id order by i.instructor_user_id)
      filter(where i.unassigned_at is null and i.instructor_user_id is not null),'{}'::uuid[])
  into v_revision,v_current from public.event_instructors i where i.tenant_id=v_event.tenant_id and i.event_id=p_event_id;
  if v_revision is distinct from p_expected_revision then
    raise exception 'Assignment revision conflict' using errcode='40001';
  end if;
  if v_current=v_selected then
    return pg_catalog.jsonb_build_object('changed',false,'revision',v_revision,'active_user_ids',v_current);
  end if;
  v_now:=pg_catalog.clock_timestamp();
  update public.event_instructors i set unassigned_at=v_now,unassigned_by=v_actor
    where i.tenant_id=v_event.tenant_id and i.event_id=p_event_id and i.unassigned_at is null
      and i.instructor_user_id is not null and not (i.instructor_user_id=any(v_selected));
  insert into public.event_instructors(tenant_id,event_id,instructor_user_id,assigned_at,assigned_by)
    select v_event.tenant_id,p_event_id,u,v_now,v_actor from pg_catalog.unnest(v_selected) u
      where not (u=any(v_current));
  select pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(coalesce(pg_catalog.jsonb_agg(
    pg_catalog.jsonb_build_array(i.id,i.instructor_user_id,extract(epoch from i.assigned_at),i.assigned_by,extract(epoch from i.unassigned_at),i.unassigned_by)
    order by i.id),'[]'::jsonb)::text,'UTF8')),'hex') into v_revision
    from public.event_instructors i where i.tenant_id=v_event.tenant_id and i.event_id=p_event_id;
  return pg_catalog.jsonb_build_object('changed',true,'revision',v_revision,'active_user_ids',v_selected);
end;
$fn$;
alter function public.admin_list_available_event_instructors_v1(uuid,integer,integer) owner to postgres;
alter function public.admin_set_event_instructors_v1(uuid,uuid[],text) owner to postgres;
revoke all on function public.admin_list_available_event_instructors_v1(uuid,integer,integer) from public,anon,authenticated,service_role;
revoke all on function public.admin_set_event_instructors_v1(uuid,uuid[],text) from public,anon,authenticated,service_role;
grant execute on function public.admin_list_available_event_instructors_v1(uuid,integer,integer) to authenticated;
grant execute on function public.admin_set_event_instructors_v1(uuid,uuid[],text) to authenticated;

-- SEC-008: retain self-owned registrations; remove only the broad instructor path.
alter policy "Tenant staff can view event registrations" on public.event_registrations
  using (public.has_tenant_role_v1(tenant_id,array['admin','employee']::text[]));
-- Public visibility stays independent; assignment rows grant no reads in 1A.
alter policy "Tenant staff can view events" on public.events
  using (public.has_tenant_role_v1(tenant_id,array['admin','employee']::text[]));
alter policy "Tenant staff can view event lanes" on public.event_lanes
  using (public.has_tenant_role_v1(tenant_id,array['admin','employee']::text[]));
do $harden$
declare r record; d text;
begin
  for r in select * from (values
    ('public.admin_list_event_registrations_v1(uuid,text,text,integer,integer)','cf89cafac291b048b2dfecd649a00c92'),
    ('public.admin_list_event_registrations_v2(uuid,uuid,text,text,integer,integer)','4fc08d79ffffe3f37c084d0ecd6baba8'),
    ('public.admin_list_events_v2(uuid,text,text,text,integer,integer)','e5bfef5e271e802a1fa805f90f179420')
  ) x(signature,fingerprint) loop
    d:=pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef(r.signature::regprocedure),E'\r\n',E'\n'),E'\r',E'\n');
    if pg_catalog.md5(d)<>r.fingerprint then raise exception 'Unexpected SEC-008 reader baseline'; end if;
    execute pg_catalog.replace(d,'''admin'',''employee'',''instructor''','''admin'',''employee''');
  end loop;
end;
$harden$;
commit;
