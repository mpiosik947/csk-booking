-- PRODUCT-10G-B: cancelled reservation email continuity only. No general RLS changes.
begin;
set local lock_timeout='5s';
set local statement_timeout='60s';

do $preflight$
begin
 if md5(replace(replace(pg_get_functiondef('public.prepare_confirmation_email(text,uuid)'::regprocedure),chr(13)||chr(10),chr(10)),chr(13),chr(10)))
    <> '17d8b973c9e3df0839f692fd8d9efbde' then
  raise exception 'Cancellation email input drift';
 end if;
end;$preflight$;

-- Closed helper: callable only from owner-executed SECURITY DEFINER contracts.
create function public.can_authorize_reservation_cancellation_email_core_v1(p_reservation_id uuid)
returns boolean language sql stable security invoker
set search_path=pg_catalog,public,pg_temp
as $$
 select auth.uid() is not null and exists(
  select 1 from public.reservations r join public.tenants t on t.id=r.tenant_id
  where r.id=p_reservation_id and t.status in ('active','suspended')
   and (r.user_id=auth.uid() or exists(
    select 1 from public.tenant_memberships m
    where m.tenant_id=r.tenant_id and m.user_id=auth.uid()
     and m.status='active' and m.role in ('admin','employee')))
 );
$$;
alter function public.can_authorize_reservation_cancellation_email_core_v1(uuid) owner to postgres;
revoke all on function public.can_authorize_reservation_cancellation_email_core_v1(uuid) from public,anon,authenticated,service_role;

create function public.get_reservation_cancellation_email_v1(p_reservation_id uuid)
returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,pg_temp
as $$
declare result jsonb;
begin
 if not public.can_authorize_reservation_cancellation_email_core_v1(p_reservation_id)
    or not exists(select 1 from public.reservations r where r.id=p_reservation_id
      and lower(btrim(r.reservation_status)) in ('cancelled','canceled','cancelled_by_admin','cancelled_by_user')) then
  raise exception 'Reservation unavailable' using errcode='42501';
 end if;
 select jsonb_build_object(
  'recipient_email',coalesce(nullif(btrim(r.customer_email),''),nullif(btrim(p.email),''),
    case when r.user_id=auth.uid() then nullif(btrim(u.email),'') end),
  'customer_name',coalesce(nullif(btrim(r.customer_name),''),nullif(btrim(p.full_name),''),
    nullif(btrim(concat_ws(' ',nullif(btrim(p.first_name),''),nullif(btrim(p.last_name),''))),''),
    nullif(btrim(r.customer_email),''),'Kliencie'),
  'reservation_date',r.reservation_date,'start_time',r.start_time,'end_time',r.end_time,
  'lane_name',coalesce(nullif(btrim(l.name),''),'Brak osi'),
  'cancelled_by',case when r.user_id=auth.uid() then 'user' else 'admin' end)
 into result
 from public.reservations r
 left join public.profiles p on p.user_id=r.user_id
 left join auth.users u on u.id=r.user_id
 left join public.shooting_lanes l on l.id=r.lane_id and l.tenant_id=r.tenant_id
 where r.id=p_reservation_id;
 return result;
end;
$$;
alter function public.get_reservation_cancellation_email_v1(uuid) owner to postgres;
revoke all on function public.get_reservation_cancellation_email_v1(uuid) from public,anon,authenticated,service_role;
grant execute on function public.get_reservation_cancellation_email_v1(uuid) to authenticated;

-- Change ONLY cancellation authorization, leaving confirmation branches, lease,
-- sent marker, bounded retry, recipient binding and provider key untouched.
do $patch$
declare definition text; anchor text;
begin
 definition:=replace(replace(pg_get_functiondef('public.prepare_confirmation_email(text,uuid)'::regprocedure),chr(13)||chr(10),chr(10)),chr(13),chr(10));
 anchor:=$anchor$    if v_source_user_id is distinct from v_actor_user_id then
      if not public.has_tenant_role_v1(v_tenant_id,array['admin','employee']::text[]) then
        return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','not_found');
      end if;
    elsif not public.is_tenant_member_v1(v_tenant_id) then
      return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','not_found');
    end if;$anchor$;
 if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then
  raise exception 'Cancellation email authorization anchor drift';
 end if;
 execute replace(definition,anchor,$replacement$    if not public.can_authorize_reservation_cancellation_email_core_v1(p_record_id) then
      return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','not_found');
    end if;$replacement$);
end;$patch$;
commit;
