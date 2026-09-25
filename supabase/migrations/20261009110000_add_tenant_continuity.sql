-- PRODUCT-10E: cancellation/history and recording external settlements only.
-- No charge, payment link, refund execution or new obligation is created.
set lock_timeout='5s';
set statement_timeout='60s';

create function public.get_my_continuity_role_core_v1(p_tenant_id uuid)
returns text language sql stable security invoker
set search_path=pg_catalog,public,pg_temp
as $$select m.role from public.tenant_memberships m join public.tenants t on t.id=m.tenant_id
 where m.tenant_id=p_tenant_id and m.user_id=auth.uid() and m.status='active'
 and t.status in ('active','suspended');$$;
revoke all on function public.get_my_continuity_role_core_v1(uuid) from public,anon,authenticated,service_role;

-- Preserve the canonical 12h/72h cancellation bodies. Only the closed authority
-- helper changes; it is never used for creation, promotion or general RLS.
do $cancellation$
declare item record; definition text;
begin
 for item in select * from (values
 ('public.cancel_reservation(uuid)','c5423189dcfab4aa1be39e93e42a6aca'),
 ('public.cancel_event_registration(uuid)','5c45f09d89167548262908f84690f6f4'),
 ('public.cancel_reservation__saas9d1_core(uuid)','c586dabdad344173b3e14f57215522a4'),
 ('public.cancel_event_registration__saas9d2a_core(uuid)','e812ad44e0f258c7346d83f92dda5793')
 ) targets(signature,fingerprint) loop
 definition:=replace(replace(pg_get_functiondef(item.signature::regprocedure),chr(13)||chr(10),chr(10)),chr(13),chr(10));
 if md5(definition)<>item.fingerprint then raise exception 'Continuity input drift: %',item.signature; end if;
 if (length(definition)-length(replace(definition,'public.get_my_tenant_role_v1(','')))/length('public.get_my_tenant_role_v1(')<>1 then
 raise exception 'Continuity authority anchor drift'; end if;
 execute replace(definition,'public.get_my_tenant_role_v1(','public.get_my_continuity_role_core_v1(');
 end loop;
end;$cancellation$;

create table public.external_settlement_records (
 id uuid primary key default gen_random_uuid(),
 tenant_id uuid not null references public.tenants(id) on delete restrict,
 reservation_id uuid references public.reservations(id) on delete restrict,
 registration_id uuid references public.event_registrations(id) on delete restrict,
 actor_user_id uuid not null,
 idempotency_key uuid not null,
 kind text not null check(kind in ('external_refund','external_reconciliation')),
 amount numeric(12,2) not null check(amount>0),
 currency text not null check(currency ~ '^[A-Z]{3}$'),
 external_reference text not null check(length(btrim(external_reference)) between 1 and 100),
 recorded_at timestamptz not null default now(),
 check(num_nonnulls(reservation_id,registration_id)=1),
 unique(tenant_id,idempotency_key)
);
alter table public.external_settlement_records enable row level security;
revoke all on public.external_settlement_records from public,anon,authenticated,service_role;

create function public.record_external_settlement_v1(p_kind text,p_resource_kind text,p_resource_id uuid,
 p_amount numeric,p_currency text,p_reference text,p_idempotency_key uuid)
returns uuid language plpgsql security definer
set search_path=pg_catalog,public,pg_temp
as $$
declare target_tenant uuid; actor_role text; prior public.external_settlement_records%rowtype; result_id uuid;
begin
 if auth.uid() is null then raise exception 'Not authorized' using errcode='42501'; end if;
 if p_resource_kind='reservation' then
 select tenant_id into target_tenant from public.reservations where id=p_resource_id for update;
 elsif p_resource_kind='event_registration' then
 select r.tenant_id into target_tenant from public.event_registrations r join public.events e
 on e.id=r.event_id and e.tenant_id=r.tenant_id where r.id=p_resource_id for update of r;
 end if;
 actor_role:=public.get_my_continuity_role_core_v1(target_tenant);
 if coalesce(actor_role,'') not in ('admin','employee') then raise exception 'Not authorized' using errcode='42501'; end if;
 if p_kind is null or p_kind not in ('external_refund','external_reconciliation') or p_amount is null
 or p_amount<=0 or p_amount<>round(p_amount,2) or p_amount>9999999999.99 or p_currency is null
 or p_currency !~ '^[A-Z]{3}$' or p_reference is null or length(btrim(p_reference)) not between 1 and 100
 or p_idempotency_key is null then raise exception 'Invalid external settlement' using errcode='22023'; end if;
 perform pg_advisory_xact_lock(hashtextextended(target_tenant::text||p_idempotency_key::text,1010));
 select * into prior from public.external_settlement_records where tenant_id=target_tenant and idempotency_key=p_idempotency_key;
 if found then
 if prior.kind<>p_kind or prior.amount<>p_amount or prior.currency<>p_currency or prior.external_reference<>btrim(p_reference)
 or coalesce(prior.reservation_id,prior.registration_id)<>p_resource_id
 or (prior.reservation_id is not null)<>(p_resource_kind='reservation') then
 raise exception 'Idempotency key conflicts' using errcode='22023'; end if;
 return prior.id;
 end if;
 insert into public.external_settlement_records(tenant_id,reservation_id,registration_id,actor_user_id,idempotency_key,
 kind,amount,currency,external_reference)
 values(target_tenant,case when p_resource_kind='reservation' then p_resource_id end,
 case when p_resource_kind='event_registration' then p_resource_id end,auth.uid(),p_idempotency_key,
 p_kind,p_amount,p_currency,btrim(p_reference)) returning id into result_id;
 insert into public.audit_logs(tenant_id,actor_user_id,actor_role,action,target_type,target_id,details)
 values(target_tenant,auth.uid(),actor_role,'external_settlement_recorded',p_resource_kind,p_resource_id,
 jsonb_build_object('record_id',result_id,'kind',p_kind,'amount',p_amount,'currency',p_currency,'external_only',true));
 -- In particular, do NOT turn unpaid into a refund or mutate payment_status.
 return result_id;
end;$$;
revoke all on function public.record_external_settlement_v1(text,text,uuid,numeric,text,text,uuid) from public,anon,authenticated,service_role;
grant execute on function public.record_external_settlement_v1(text,text,uuid,numeric,text,text,uuid) to authenticated;

create function public.get_my_continuity_v1(p_page integer default 1,p_staff_tenant uuid default null)
returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,pg_temp
as $$
declare response jsonb;
begin
 if auth.uid() is null then raise exception 'Not authorized' using errcode='42501'; end if;
 if p_page is null or p_page<1 or p_page>100000 then raise exception 'Invalid page' using errcode='22023'; end if;
 if p_staff_tenant is not null and coalesce(public.get_my_continuity_role_core_v1(p_staff_tenant),'') not in ('admin','employee') then
 raise exception 'Not authorized' using errcode='42501'; end if;
 with resources as (
 select 'reservation'::text kind,r.id,r.tenant_id,t.name tenant_name,t.slug,t.status tenant_status,r.user_id,
 coalesce(r.lane_name_snapshot,'Rezerwacja') title,r.reservation_date appointment_date,r.start_time,
 r.reservation_status status,r.payment_status,
 ((r.reservation_date+r.start_time) at time zone 'Europe/Warsaw')-interval '12 hours' deadline,
 coalesce(r.attendance_status,'planned')='planned' and r.checked_in_at is null and r.completed_at is null eligible
 from public.reservations r join public.tenants t on t.id=r.tenant_id
 where t.status in ('active','suspended') and
 ((p_staff_tenant is null and r.user_id=auth.uid()) or r.tenant_id=p_staff_tenant)
 union all
 select 'event_registration',r.id,r.tenant_id,t.name,t.slug,t.status,r.user_id,e.title,e.event_date,e.start_time,
 r.registration_status,r.payment_status,((e.event_date+e.start_time) at time zone 'Europe/Warsaw')-interval '72 hours',true
 from public.event_registrations r join public.events e on e.id=r.event_id and e.tenant_id=r.tenant_id
 join public.tenants t on t.id=r.tenant_id where t.status in ('active','suspended') and
 ((p_staff_tenant is null and r.user_id=auth.uid()) or r.tenant_id=p_staff_tenant)
 ), page_rows as (select * from resources order by appointment_date desc,start_time desc,kind,id limit 25 offset((p_page::bigint-1)*25))
 select jsonb_build_object('page',p_page,'page_size',25,'total',(select count(*) from resources),
 'items',coalesce((select jsonb_agg(jsonb_build_object('kind',r.kind,'id',r.id,'tenant_name',r.tenant_name,
 'tenant_slug',r.slug,'tenant_status',r.tenant_status,'title',r.title,'date',r.appointment_date,'start_time',r.start_time,
 'status',r.status,'payment_status',r.payment_status,'deadline',r.deadline,
 'can_cancel',coalesce(public.get_my_continuity_role_core_v1(r.tenant_id),'') in ('admin','employee','user','instructor')
 and r.eligible and (r.kind='event_registration' or public.get_my_continuity_role_core_v1(r.tenant_id)<>'instructor')
 and r.status in ('confirmed','registered','approved','reserve','participant')
 and (public.get_my_continuity_role_core_v1(r.tenant_id) in ('admin','employee') or now()<=r.deadline),
 'settlements',coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'kind',s.kind,'amount',s.amount,
 'currency',s.currency,'recorded_at',s.recorded_at) order by s.recorded_at,s.id)
 from public.external_settlement_records s where s.tenant_id=r.tenant_id and
 ((r.kind='reservation' and s.reservation_id=r.id) or (r.kind='event_registration' and s.registration_id=r.id))),'[]'::jsonb)
 ) order by r.appointment_date desc,r.start_time desc,r.kind,r.id) from page_rows r),'[]'::jsonb)) into response;
 return response || jsonb_build_object('staff_tenants',coalesce((
 select jsonb_agg(jsonb_build_object('id',t.id,'name',t.name,'status',t.status) order by t.name,t.id)
 from public.tenants t join public.tenant_memberships m on m.tenant_id=t.id
 where m.user_id=auth.uid() and m.status='active' and m.role in ('admin','employee')
 and t.status in ('active','suspended')),'[]'::jsonb));
end;$$;
revoke all on function public.get_my_continuity_v1(integer,uuid) from public,anon,authenticated,service_role;
grant execute on function public.get_my_continuity_v1(integer,uuid) to authenticated;

create function public.cancel_continuity_resource_v1(p_kind text,p_resource_id uuid)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,pg_temp
as $$
begin
 if p_kind='reservation' then return public.cancel_reservation(p_resource_id);
 elsif p_kind='event_registration' then return public.cancel_event_registration(p_resource_id);
 else raise exception 'Invalid resource kind' using errcode='22023'; end if;
 -- This continuity endpoint NEVER initiates waitlist promotions or email delivery.
end;$$;
revoke all on function public.cancel_continuity_resource_v1(text,uuid) from public,anon,authenticated,service_role;
grant execute on function public.cancel_continuity_resource_v1(text,uuid) to authenticated;
