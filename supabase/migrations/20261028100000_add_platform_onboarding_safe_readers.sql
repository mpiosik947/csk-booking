-- ONBOARD-1B-R1: additive Platform Admin configuration readers only.
-- No lifecycle, readiness, table privilege or customer-access changes.
create function public.platform_list_active_plans_v1()
returns jsonb language plpgsql stable security definer
set search_path='pg_catalog','public','pg_temp' as $function$
begin
 if not public.is_platform_admin_v1() then
  raise exception 'Not authorized' using errcode='42501';
 end if;
 -- Fail explicitly instead of silently truncating an unexpectedly large catalog.
 if (select count(*) from public.saas_plans where status='active')>1000 then
  raise exception 'Plan catalog unavailable' using errcode='54000';
 end if;
 return coalesce((select jsonb_agg(jsonb_build_object(
  'plan_key',p.plan_key,'display_name',p.plan_key,'status',p.status,
  'features',coalesce((select jsonb_agg(jsonb_build_object(
   'feature_key',f.feature_key,'description',f.description) order by f.feature_key)
   from public.saas_plan_features pf join public.saas_features f on f.feature_key=pf.feature_key
   where pf.plan_id=p.id and f.active),'[]'::jsonb)) order by p.plan_key)
  from public.saas_plans p where p.status='active'),'[]'::jsonb);
end;
$function$;

create function public.platform_get_tenant_onboarding_detail_v1(p_tenant_id uuid)
returns jsonb language plpgsql stable security definer
set search_path='pg_catalog','public','pg_temp' as $function$
declare result jsonb;
begin
 if not public.is_platform_admin_v1() then
  raise exception 'Not authorized' using errcode='42501';
 end if;
 select jsonb_build_object(
  'tenant',jsonb_build_object('tenant_id',t.id,'name',t.name,'technical_slug',t.slug,'status',t.status),
  'public_profile',case when p.tenant_id is null then null else jsonb_build_object(
   'display_name',p.display_name,'city',p.city,'public_slug',p.public_slug,'is_public',p.is_public) end,
  'plan',case when a.tenant_id is null then null else jsonb_build_object(
   'plan_key',s.plan_key,'status',s.status,'assignment_status',a.status,
   'enabled_feature_keys',coalesce((select jsonb_agg(f.feature_key order by f.feature_key)
    from public.saas_plan_features pf join public.saas_features f on f.feature_key=pf.feature_key
    where pf.plan_id=s.id and f.active and s.status='active' and a.status='active'),'[]'::jsonb)) end,
  'admins',coalesce((select jsonb_agg(jsonb_build_object('user_id',m.user_id,'email',u.email) order by m.user_id)
   from public.tenant_memberships m left join auth.users u on u.id=m.user_id
   where m.tenant_id=t.id and m.role='admin' and m.status='active'),'[]'::jsonb),
  'readiness',public.tenant_onboarding_readiness_core_v2(t.id))
 into result from public.tenants t
 left join public.tenant_public_profiles p on p.tenant_id=t.id
 left join public.tenant_plan_assignments a on a.tenant_id=t.id
 left join public.saas_plans s on s.id=a.plan_id
 where t.id=p_tenant_id;
 -- Unknown/null selector returns JSON null; incomplete existing objects remain inspectable.
 return result;
end;
$function$;

alter function public.platform_list_active_plans_v1() owner to postgres;
alter function public.platform_get_tenant_onboarding_detail_v1(uuid) owner to postgres;
revoke all on function public.platform_list_active_plans_v1() from public,anon,authenticated,service_role;
revoke all on function public.platform_get_tenant_onboarding_detail_v1(uuid) from public,anon,authenticated,service_role;
grant execute on function public.platform_list_active_plans_v1() to authenticated;
grant execute on function public.platform_get_tenant_onboarding_detail_v1(uuid) to authenticated;
