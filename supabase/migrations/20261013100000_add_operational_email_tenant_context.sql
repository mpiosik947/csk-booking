-- PRODUCT-10G-A: read-only resource-derived context; never permission to send or create business.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

create function public.resolve_operational_email_tenant_context_v1(p_resource_type text, p_resource_id uuid)
returns table(tenant_id uuid, tenant_slug text, public_slug text, display_name text)
language plpgsql stable security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare v_tenant uuid;
begin
  if p_resource_id is null then
    raise exception 'Email context unavailable' using errcode = '22023';
  end if;
  case p_resource_type
    when 'reservation' then
      select r.tenant_id into v_tenant from public.reservations r
      join public.shooting_lanes l on l.id=r.lane_id and l.tenant_id=r.tenant_id
      where r.id=p_resource_id;
    when 'event' then
      select e.tenant_id into v_tenant from public.events e where e.id=p_resource_id;
    when 'event_registration' then
      select e.tenant_id into v_tenant from public.event_registrations r
      join public.events e on e.id=r.event_id and e.tenant_id=r.tenant_id
      where r.id=p_resource_id;
    else
      raise exception 'Email context unavailable' using errcode = '22023';
  end case;
  if v_tenant is null then
    raise exception 'Email context unavailable' using errcode = 'P0002';
  end if;
  -- No active/public filter: existing obligations can require continuity notices.
  -- This projection does not bypass authorization of the operation or email delivery.
  return query select t.id,t.slug,p.public_slug,p.display_name
    from public.tenants t join public.tenant_public_profiles p on p.tenant_id=t.id
    where t.id=v_tenant and nullif(btrim(p.display_name),'') is not null
      and p.public_slug is not null;
  if not found then
    raise exception 'Email context unavailable' using errcode = 'P0002';
  end if;
end;
$$;
alter function public.resolve_operational_email_tenant_context_v1(text,uuid) owner to postgres;
revoke all on function public.resolve_operational_email_tenant_context_v1(text,uuid) from public,anon,authenticated,service_role;
grant execute on function public.resolve_operational_email_tenant_context_v1(text,uuid) to service_role;
comment on function public.resolve_operational_email_tenant_context_v1(text,uuid) is
'Server-only minimal branding projection. Caller must authorize resource operation first. No business writes or delivery authorization.';
commit;
