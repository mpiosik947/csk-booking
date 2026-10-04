-- ONBOARD-1C-R3: discovery only; returned selectors never confer setup authority.
create function public.get_my_dormant_admin_tenants_v1()
returns table (tenant_id uuid, tenant_slug text, display_name text, city text, tenant_status text)
language plpgsql
stable
security definer
set search_path = pg_catalog, public, auth, pg_temp
as $function$
declare
  v_subject uuid := auth.uid();
begin
  if v_subject is null then
    raise exception using errcode='42501', message='Not authorized';
  end if;
  -- Count before returning: never silently omit a setup location.
  if (select count(*) from public.tenant_memberships m
      join public.tenants t on t.id=m.tenant_id
      where m.user_id=v_subject and m.role='admin' and m.status='active'
        and t.status='dormant') > 100 then
    raise exception using errcode='54000', message='Too many setup locations';
  end if;
  return query
    select t.id, t.slug, coalesce(p.display_name,t.name), p.city, t.status
    from public.tenant_memberships m
    join public.tenants t on t.id=m.tenant_id
    left join public.tenant_public_profiles p on p.tenant_id=t.id
    where m.user_id=v_subject and m.role='admin' and m.status='active'
      and t.status='dormant'
    order by coalesce(p.display_name,t.name) collate "C", t.id;
end;
$function$;

alter function public.get_my_dormant_admin_tenants_v1() owner to postgres;
revoke all on function public.get_my_dormant_admin_tenants_v1()
  from public, anon, authenticated, service_role;
grant execute on function public.get_my_dormant_admin_tenants_v1() to authenticated;
comment on function public.get_my_dormant_admin_tenants_v1() is
  'Current-user dormant admin setup discovery; five identity fields only, maximum 100, no platform bypass.';
