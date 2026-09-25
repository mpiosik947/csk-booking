-- PRODUCT-10E. Private preview and draft-only tenant-admin settings access.
set lock_timeout='5s';
set statement_timeout='60s';

create function public.tenant_setup_has_feature_core_v1(p_tenant_id uuid,p_feature text)
returns boolean language sql stable security invoker
set search_path=pg_catalog,public,pg_temp
as $$select exists(select 1 from public.tenant_plan_assignments a
 join public.saas_plans p on p.id=a.plan_id and p.status='active'
 join public.saas_plan_features f on f.plan_id=p.id
 join public.saas_features feature on feature.feature_key=f.feature_key and feature.active
 join public.tenants t on t.id=a.tenant_id and t.status in ('dormant','active')
 where a.tenant_id=p_tenant_id and a.status='active' and f.feature_key=p_feature);$$;
revoke all on function public.tenant_setup_has_feature_core_v1(uuid,text) from public,anon,authenticated,service_role;

do $settings$
declare item record; definition text;
begin
 for item in select * from(values
 ('public.admin_get_tenant_public_settings_v1(text)','cf8da39cbba58444b9674ce88e243587'),
 ('public.admin_update_tenant_public_settings_v1(text,jsonb,timestamptz)','c7def683e49f6041deb352bfcc27b08c')
 ) targets(signature,fingerprint) loop
 definition:=replace(replace(pg_get_functiondef(item.signature::regprocedure),chr(13)||chr(10),chr(10)),chr(13),chr(10));
 if md5(definition)<>item.fingerprint then raise exception 'Settings input drift'; end if;
 definition:=replace(definition,'tenant.status=''active''','tenant.status in (''dormant'',''active'')');
 -- Only the settings presentation uses draft plan metadata. Operational feature
 -- checks and the general membership helper still require an ACTIVE tenant.
 definition:=replace(definition,'public.tenant_has_feature_v1(','public.tenant_setup_has_feature_core_v1(');
 execute definition;
 end loop;
end;$settings$;

create function public.platform_preview_tenant_v1(p_tenant_id uuid)
returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,pg_temp
as $$
declare result jsonb;
begin
 if not public.is_platform_admin_v1() then raise exception 'Not authorized' using errcode='42501'; end if;
 select jsonb_build_object('tenant_slug',t.slug,'public_slug',p.public_slug,'tenant_name',p.display_name,
 'tenant_city',p.city,'tenant_logo_path',p.logo_path,'tenant_hero_image_path',p.hero_image_path,
 'tenant_description',case when p.show_about then p.description end,
 'tenant_regulations_path',case when p.show_regulations then p.regulations_path end,
 'tenant_public_address',case when p.show_contact then p.public_address end,
 'tenant_public_phone',case when p.show_contact then p.public_phone end,
 'tenant_public_email',case when p.show_contact then p.public_email end,
 'tenant_opening_hours',case when p.show_contact then p.opening_hours end,
 'tenant_social_links',case when p.show_contact then p.social_links else '{}'::jsonb end,
 'show_booking',p.show_booking and public.tenant_setup_has_feature_core_v1(t.id,'booking'),
 'show_pricing',p.show_pricing and public.tenant_setup_has_feature_core_v1(t.id,'booking'),
 'show_events',p.show_events and public.tenant_setup_has_feature_core_v1(t.id,'events'),
 'show_instructor',p.show_instructor and public.tenant_setup_has_feature_core_v1(t.id,'instructors'),
 'show_about',p.show_about,'show_contact',p.show_contact,'show_regulations',p.show_regulations)
 into result from public.tenants t join public.tenant_public_profiles p on p.tenant_id=t.id where t.id=p_tenant_id;
 return result;
end;$$;
revoke all on function public.platform_preview_tenant_v1(uuid) from public,anon,authenticated,service_role;
grant execute on function public.platform_preview_tenant_v1(uuid) to authenticated;
