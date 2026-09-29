-- INSTRUCTOR-1D draft. Attendance is independent of registration/payment state.
begin;
set local lock_timeout='5s';
set local statement_timeout='60s';
alter table public.event_registrations
 add column attendance_status text not null default 'unmarked',
 add column attendance_marked_at timestamptz,
 add column attendance_marked_by uuid references public.profiles(user_id) on delete set null,
 add column attendance_version bigint not null default 0,
 add constraint event_attendance_status_check check(attendance_status in ('unmarked','present','no_show')),
 add constraint event_attendance_version_check check(attendance_version>=0),
 add constraint event_attendance_shape_check check(
  (attendance_version=0 and attendance_status='unmarked' and attendance_marked_at is null and attendance_marked_by is null)
  or (attendance_version>0 and attendance_marked_at is not null));
create index event_attendance_actor_reference on public.event_registrations(attendance_marked_by)
 where attendance_marked_by is not null;

-- Only FK cleanup of the deleting account's own actor reference. The deleted
-- profile must already be absent and this must be a nested trigger invocation.
-- No caller-set GUC, no status/version/time/business-field changes are accepted.
do $privacy$
declare d text; anchor text:=' target:=coalesce(new.tenant_id,old.tenant_id);';
begin
 d:=pg_get_functiondef('public.enforce_suspended_obligations_v1()'::regprocedure);
 if (length(d)-length(replace(d,anchor,'')))/length(anchor)<>1 then raise exception 'Lifecycle anchor drift';end if;
 execute replace(d,anchor,$exception$
 if tg_relid='public.event_registrations'::regclass and tg_op='UPDATE'
  and pg_trigger_depth()>1 and auth.uid() is not null
  and (to_jsonb(old)->>'attendance_marked_by')=auth.uid()::text
  and (to_jsonb(new)->>'attendance_marked_by') is null
  and (to_jsonb(new)-'attendance_marked_by')=(to_jsonb(old)-'attendance_marked_by')
  and not exists(select 1 from public.profiles where user_id=auth.uid()) then
   return new;
 end if;
$exception$||anchor);
end;$privacy$;

create function public.guard_event_attendance_v1() returns trigger
language plpgsql security invoker set search_path=pg_catalog,public,pg_temp as $$
begin
 if current_user<>'postgres' and (
  (tg_op='INSERT' and (new.attendance_status<>'unmarked' or new.attendance_version<>0 or new.attendance_marked_at is not null or new.attendance_marked_by is not null))
  or (tg_op='UPDATE' and row(new.attendance_status,new.attendance_version,new.attendance_marked_at,new.attendance_marked_by)
    is distinct from row(old.attendance_status,old.attendance_version,old.attendance_marked_at,old.attendance_marked_by))) then
  raise exception 'Attendance is RPC controlled' using errcode='42501';
 end if;
 return new;
end;$$;
create trigger guard_event_attendance before insert or update on public.event_registrations
 for each row execute function public.guard_event_attendance_v1();

-- Private pure predicate permits deterministic boundary tests; it grants no
-- authority and is never callable by application roles. Writer supplies DB time.
create function public.event_attendance_window_v1(p_start timestamptz,p_end timestamptz,p_now timestamptz)
returns boolean language sql immutable security invoker set search_path=pg_catalog,public,pg_temp as $$
 select coalesce(p_start<=p_end and p_now>=p_start-interval '2 hours' and p_now<=p_end+interval '24 hours',false);
$$;

create function public.set_event_registration_attendance_v1(
 p_registration_id uuid,p_attendance_status text,p_expected_attendance_version bigint
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public,pg_temp as $$
declare v_actor uuid:=auth.uid();v_event_id uuid;v_event public.events%rowtype;
 v_registration public.event_registrations%rowtype;v_role text;v_now timestamptz;
begin
 if v_actor is null then raise exception 'Not authorized' using errcode='42501';end if;
 if p_attendance_status is null or p_attendance_status not in ('unmarked','present','no_show')
  or p_expected_attendance_version is null or p_expected_attendance_version<0 then
  raise exception 'Invalid attendance input' using errcode='22023';end if;
 select event_id into v_event_id from public.event_registrations where id=p_registration_id;
 -- Same event lock as cancellation and assignment replacement.
 select * into v_event from public.events where id=v_event_id for update;
 if not found or v_event.cancelled_at is not null then raise exception 'Not authorized' using errcode='42501';end if;
 perform 1 from public.tenants where id=v_event.tenant_id and status='active' for share;
 if not found then raise exception 'Not authorized' using errcode='42501';end if;
 perform 1 from public.profiles where user_id=v_actor for key share;
 if not found then raise exception 'Not authorized' using errcode='42501';end if;
 select role into v_role from public.tenant_memberships
  where tenant_id=v_event.tenant_id and user_id=v_actor and status='active' for share;
 if not found or v_role not in ('admin','employee','instructor')
  or public.get_my_tenant_feature_access_v1(v_event.tenant_id,'events') is distinct from true then
  raise exception 'Not authorized' using errcode='42501';end if;
 if v_role='instructor' then
  perform 1 from public.event_instructors where event_id=v_event.id and tenant_id=v_event.tenant_id
   and instructor_user_id=v_actor and unassigned_at is null for share;
  if not found then raise exception 'Not authorized' using errcode='42501';end if;
 end if;
 select * into v_registration from public.event_registrations
  where id=p_registration_id and event_id=v_event.id and tenant_id=v_event.tenant_id for update;
 if not found or v_registration.registration_status not in ('registered','approved')
  or v_registration.pii_anonymized_at is not null then raise exception 'Not authorized' using errcode='42501';end if;
 -- Time sampled AFTER all lock waits, never transaction/statement start time.
 v_now:=clock_timestamp();
 if v_now<((v_event.event_date+v_event.start_time) at time zone 'Europe/Warsaw')-interval '2 hours'
  or (v_role='instructor' and public.event_attendance_window_v1(
   (v_event.event_date+v_event.start_time) at time zone 'Europe/Warsaw',
   (v_event.event_date+v_event.end_time) at time zone 'Europe/Warsaw',v_now) is distinct from true) then
  raise exception 'Attendance window unavailable' using errcode='42501';end if;
 if v_registration.attendance_version<>p_expected_attendance_version then raise exception 'Attendance revision conflict' using errcode='40001';end if;
 if v_registration.attendance_status=p_attendance_status then
  return jsonb_build_object('attendance_status',v_registration.attendance_status,'attendance_version',v_registration.attendance_version,'changed',false);
 end if;
 update public.event_registrations set attendance_status=p_attendance_status,
  attendance_marked_at=v_now,attendance_marked_by=v_actor,attendance_version=attendance_version+1 where id=p_registration_id;
 insert into public.audit_logs(tenant_id,actor_user_id,actor_role,action,target_type,target_id,details)
 values(v_event.tenant_id,v_actor,v_role,'event_attendance_changed','event_registration',p_registration_id,
  jsonb_build_object('event_id',v_event.id,'old_status',v_registration.attendance_status,'new_status',p_attendance_status));
 return jsonb_build_object('attendance_status',p_attendance_status,'attendance_version',v_registration.attendance_version+1,'changed',true);
end;$$;

-- Preserve every existing instructor scope/retention guard; extend DTO only.
do $reader$
declare d text;a text:='select r.id,r.customer_name,r.registration_status,r.created_at';
 b text:='''registration_status'',registration_status)';
begin
 d:=pg_get_functiondef('public.get_instructor_event_participants_v1(uuid,text,integer,integer)'::regprocedure);
 if strpos(d,a)=0 or strpos(d,b)=0 then raise exception 'Participant reader baseline drift';end if;
 d:=replace(d,a,a||',r.attendance_status,r.attendance_version');
 d:=replace(d,b,'''registration_status'',registration_status,''attendance_status'',attendance_status,''attendance_version'',attendance_version)');
 execute d;
end;$reader$;
alter function public.guard_event_attendance_v1() owner to postgres;
alter function public.event_attendance_window_v1(timestamptz,timestamptz,timestamptz) owner to postgres;
alter function public.set_event_registration_attendance_v1(uuid,text,bigint) owner to postgres;
revoke all on function public.guard_event_attendance_v1() from public,anon,authenticated,service_role;
revoke all on function public.event_attendance_window_v1(timestamptz,timestamptz,timestamptz) from public,anon,authenticated,service_role;
revoke all on function public.set_event_registration_attendance_v1(uuid,text,bigint) from public,anon,authenticated,service_role;
grant execute on function public.set_event_registration_attendance_v1(uuid,text,bigint) to authenticated;
commit;
