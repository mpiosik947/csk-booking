-- PRODUCT-10C: tenant-owned public profile settings and presentation-only section visibility.

do $preflight$
begin
  if pg_catalog.to_regclass('public.tenant_public_profiles') is null
     or pg_catalog.to_regprocedure('public.get_public_tenant_landing_v1(text)') is null
     or pg_catalog.to_regprocedure('public.set_audit_log_tenant_id()') is null then
    raise exception 'PRODUCT-10C preflight failed: public tenant landing foundation is incomplete.';
  end if;
  if pg_catalog.to_regprocedure('public.get_public_tenant_landing_v2(text)') is not null
     or pg_catalog.to_regprocedure('public.admin_get_tenant_public_settings_v1(text)') is not null
     or pg_catalog.to_regprocedure('public.admin_update_tenant_public_settings_v1(text,jsonb,timestamp with time zone)') is not null then
    raise exception 'PRODUCT-10C preflight failed: target RPC already exists.';
  end if;
  if (select pg_catalog.count(*) from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prosecdef) <> 77 then
    raise exception 'PRODUCT-10C preflight failed: SECURITY DEFINER baseline differs.';
  end if;
end;
$preflight$;

alter table public.tenant_public_profiles
  add column public_address text,
  add column public_phone text,
  add column public_email text,
  add column opening_hours text,
  add column social_links jsonb not null default '{}'::jsonb,
  add column show_booking boolean not null default true,
  add column show_pricing boolean not null default true,
  add column show_instructor boolean not null default true,
  add column show_events boolean not null default true,
  add column show_about boolean not null default true,
  add column show_contact boolean not null default true,
  add column show_regulations boolean not null default true,
  add constraint tenant_public_profiles_public_address_check check (
    public_address is null or (public_address=pg_catalog.btrim(public_address) and pg_catalog.char_length(public_address) between 1 and 300 and public_address !~ '[[:cntrl:]]')
  ),
  add constraint tenant_public_profiles_public_phone_check check (
    public_phone is null or (public_phone=pg_catalog.btrim(public_phone) and pg_catalog.char_length(public_phone) between 5 and 32 and public_phone ~ '^[0-9+(). -]+$')
  ),
  add constraint tenant_public_profiles_public_email_check check (
    public_email is null or (public_email=pg_catalog.btrim(public_email) and pg_catalog.char_length(public_email) between 3 and 254 and public_email ~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$')
  ),
  add constraint tenant_public_profiles_opening_hours_check check (
    opening_hours is null or (opening_hours=pg_catalog.btrim(opening_hours) and pg_catalog.char_length(opening_hours) between 1 and 500 and opening_hours !~ '[[:cntrl:]]')
  );

comment on column public.tenant_public_profiles.social_links is 'Allowlisted public HTTPS links only: facebook, instagram, youtube.';
comment on column public.tenant_public_profiles.show_booking is 'Presentation visibility only; never an entitlement or authorization source.';

create or replace function public.set_audit_log_tenant_id()
returns trigger
language plpgsql
security invoker
set search_path = pg_catalog
as $function$
declare v_tenant_id uuid;
begin
  case new.target_type
    when 'reservation' then select record.tenant_id into v_tenant_id from public.reservations record where record.id=new.target_id;
    when 'event_registration' then select record.tenant_id into v_tenant_id from public.event_registrations record where record.id=new.target_id;
    when 'lane_booking_family' then select record.tenant_id into v_tenant_id from public.shooting_lanes record where record.id=new.target_id;
    when 'tenant_public_profile' then
      if new.action is distinct from 'tenant_public_profile_updated' or new.target_id is null then raise exception using errcode='23514',message='tenant_public_profile_audit_mismatch'; end if;
      select profile.tenant_id into v_tenant_id from public.tenant_public_profiles profile where profile.tenant_id=new.target_id;
    when 'tenant_user_admin_note' then if new.action is distinct from 'tenant_user_admin_note_updated' then raise exception using errcode='23514',message='tenant_user_admin_note_audit_mismatch'; end if;
    when 'tenant_user_role' then if new.action is distinct from 'tenant_user_role_updated' then raise exception using errcode='23514',message='tenant_user_role_audit_mismatch'; end if;
    when 'tenant_user_identity' then if new.action is distinct from 'tenant_user_identity_updated' then raise exception using errcode='23514',message='tenant_user_identity_audit_mismatch'; end if;
    when 'tenant_user_contact' then if new.action is distinct from 'tenant_user_contact_updated' then raise exception using errcode='23514',message='tenant_user_contact_audit_mismatch'; end if;
    when 'tenant_user_verification' then
      if new.action not in('tenant_user_verification_verified','tenant_user_verification_marked_pending','tenant_user_verification_rejected','tenant_user_verification_invalidated') then raise exception using errcode='23514',message='tenant_user_verification_audit_mismatch'; end if;
    when 'profile','account' then
      if new.tenant_id is not null then raise exception using errcode='23514',message='global_audit_must_not_have_tenant'; end if;
      return new;
    else raise exception using errcode='23514',message='unsupported_audit_target_type';
  end case;
  if new.target_type like 'tenant_user_%' then
    if new.tenant_id is null or new.target_id is null
       or not exists(select 1 from public.tenants tenant where tenant.id=new.tenant_id)
       or not exists(select 1 from public.profiles profile where profile.user_id=new.target_id)
       or not (exists(select 1 from public.tenant_memberships membership where membership.tenant_id=new.tenant_id and membership.user_id=new.target_id)
          or exists(select 1 from public.reservations reservation where reservation.tenant_id=new.tenant_id and reservation.user_id=new.target_id)
          or exists(select 1 from public.event_registrations registration join public.events event_record on event_record.id=registration.event_id and event_record.tenant_id=registration.tenant_id where registration.tenant_id=new.tenant_id and registration.user_id=new.target_id)) then
      raise exception using errcode='23514',message='tenant_user_audit_mismatch';
    end if;
    return new;
  end if;
  if v_tenant_id is null then raise exception using errcode='23503',message='audit_target_not_found'; end if;
  if new.tenant_id is not null and new.tenant_id is distinct from v_tenant_id then raise exception using errcode='23514',message='audit_tenant_mismatch'; end if;
  new.tenant_id:=v_tenant_id;
  return new;
end;
$function$;
alter function public.set_audit_log_tenant_id() owner to postgres;
revoke all on function public.set_audit_log_tenant_id() from public,anon,authenticated,service_role;

create function public.admin_get_tenant_public_settings_v1(p_tenant_slug text)
returns jsonb
language plpgsql stable security definer
set search_path=pg_catalog,public,auth,pg_temp
as $function$
declare v_tenant_id uuid; v_profile public.tenant_public_profiles%rowtype;
begin
  select tenant.id into v_tenant_id
  from public.tenants tenant join public.tenant_memberships membership on membership.tenant_id=tenant.id
  where tenant.slug=p_tenant_slug and tenant.status='active' and membership.user_id=auth.uid() and membership.status='active' and membership.role='admin';
  if v_tenant_id is null then raise exception using errcode='42501',message='forbidden'; end if;
  select * into v_profile from public.tenant_public_profiles where tenant_id=v_tenant_id;
  if not found then raise exception using errcode='P0002',message='settings_not_found'; end if;
  return pg_catalog.jsonb_build_object(
    'display_name',v_profile.display_name,'city',v_profile.city,'logo_path',v_profile.logo_path,
    'hero_image_path',v_profile.hero_image_path,'description',v_profile.description,'regulations_path',v_profile.regulations_path,
    'public_address',v_profile.public_address,'public_phone',v_profile.public_phone,'public_email',v_profile.public_email,
    'opening_hours',v_profile.opening_hours,'social_links',v_profile.social_links,
    'show_booking',v_profile.show_booking,'show_pricing',v_profile.show_pricing,'show_instructor',v_profile.show_instructor,
    'show_events',v_profile.show_events,'show_about',v_profile.show_about,'show_contact',v_profile.show_contact,
    'show_regulations',v_profile.show_regulations,'updated_at',v_profile.updated_at
  );
end;
$function$;
alter function public.admin_get_tenant_public_settings_v1(text) owner to postgres;
revoke all on function public.admin_get_tenant_public_settings_v1(text) from public,anon,authenticated,service_role;
grant execute on function public.admin_get_tenant_public_settings_v1(text) to authenticated;

create function public.admin_update_tenant_public_settings_v1(p_tenant_slug text,p_settings jsonb,p_expected_updated_at timestamptz)
returns jsonb
language plpgsql security definer
set search_path=pg_catalog,public,auth,pg_temp
as $function$
declare
  v_tenant_id uuid; v_current public.tenant_public_profiles%rowtype; v_result jsonb;
  v_allowed constant text[]:=array['display_name','city','logo_path','hero_image_path','description','regulations_path','public_address','public_phone','public_email','opening_hours','social_links','show_booking','show_pricing','show_instructor','show_events','show_about','show_contact','show_regulations'];
  v_changed text[];
begin
  if p_settings is null or pg_catalog.jsonb_typeof(p_settings)<>'object'
     or exists(select 1 from pg_catalog.jsonb_object_keys(p_settings) key where not (key=any(v_allowed)))
     or exists(select 1 from pg_catalog.unnest(v_allowed) key where not (p_settings ? key))
     or pg_catalog.jsonb_typeof(p_settings->'social_links')<>'object'
     or exists(select 1 from pg_catalog.jsonb_object_keys(p_settings->'social_links') key where key not in ('facebook','instagram','youtube'))
     or exists(select 1 from pg_catalog.jsonb_each_text(p_settings->'social_links') item where pg_catalog.char_length(item.value)>500 or item.value !~ '^https://[^[:space:]]+$') then
    raise exception using errcode='22023',message='invalid_settings_payload';
  end if;
  select tenant.id into v_tenant_id
  from public.tenants tenant join public.tenant_memberships membership on membership.tenant_id=tenant.id
  where tenant.slug=p_tenant_slug and tenant.status='active' and membership.user_id=auth.uid() and membership.status='active' and membership.role='admin';
  if v_tenant_id is null then raise exception using errcode='42501',message='forbidden'; end if;
  select * into v_current from public.tenant_public_profiles where tenant_id=v_tenant_id for update;
  if not found then raise exception using errcode='P0002',message='settings_not_found'; end if;
  if p_expected_updated_at is null or v_current.updated_at is distinct from p_expected_updated_at then raise exception using errcode='40001',message='settings_conflict'; end if;

  update public.tenant_public_profiles set
    display_name=pg_catalog.btrim(p_settings->>'display_name'), city=pg_catalog.btrim(p_settings->>'city'),
    logo_path=nullif(pg_catalog.btrim(p_settings->>'logo_path'),''), hero_image_path=nullif(pg_catalog.btrim(p_settings->>'hero_image_path'),''),
    description=nullif(pg_catalog.btrim(p_settings->>'description'),''), regulations_path=nullif(pg_catalog.btrim(p_settings->>'regulations_path'),''),
    public_address=nullif(pg_catalog.btrim(p_settings->>'public_address'),''), public_phone=nullif(pg_catalog.btrim(p_settings->>'public_phone'),''),
    public_email=nullif(pg_catalog.lower(pg_catalog.btrim(p_settings->>'public_email')),''), opening_hours=nullif(pg_catalog.btrim(p_settings->>'opening_hours'),''),
    social_links=coalesce(p_settings->'social_links','{}'::jsonb),
    show_booking=(p_settings->>'show_booking')::boolean, show_pricing=(p_settings->>'show_pricing')::boolean,
    show_instructor=(p_settings->>'show_instructor')::boolean, show_events=(p_settings->>'show_events')::boolean,
    show_about=(p_settings->>'show_about')::boolean, show_contact=(p_settings->>'show_contact')::boolean,
    show_regulations=(p_settings->>'show_regulations')::boolean
  where tenant_id=v_tenant_id;

  select pg_catalog.array_agg(key order by key) into v_changed
  from pg_catalog.unnest(v_allowed) key
  where (pg_catalog.to_jsonb(v_current)->key) is distinct from (select pg_catalog.to_jsonb(updated)->key from public.tenant_public_profiles updated where updated.tenant_id=v_tenant_id);
  insert into public.audit_logs(tenant_id,actor_user_id,actor_role,action,target_type,target_id,details)
  values(v_tenant_id,auth.uid(),'admin','tenant_public_profile_updated','tenant_public_profile',v_tenant_id,pg_catalog.jsonb_build_object('changed_fields',coalesce(v_changed,array[]::text[])));
  v_result:=public.admin_get_tenant_public_settings_v1(p_tenant_slug);
  return v_result;
end;
$function$;
alter function public.admin_update_tenant_public_settings_v1(text,jsonb,timestamptz) owner to postgres;
revoke all on function public.admin_update_tenant_public_settings_v1(text,jsonb,timestamptz) from public,anon,authenticated,service_role;
grant execute on function public.admin_update_tenant_public_settings_v1(text,jsonb,timestamptz) to authenticated;

create function public.get_public_tenant_landing_v2(p_slug text)
returns table(
  tenant_slug text,public_slug text,tenant_name text,tenant_city text,tenant_logo_path text,tenant_hero_image_path text,
  tenant_description text,tenant_regulations_path text,tenant_public_address text,tenant_public_phone text,tenant_public_email text,
  tenant_opening_hours text,tenant_social_links jsonb,show_booking boolean,show_pricing boolean,show_instructor boolean,
  show_events boolean,show_about boolean,show_contact boolean,show_regulations boolean
)
language plpgsql stable security definer
set search_path=pg_catalog,public,pg_temp
as $function$
begin
  if p_slug is null or p_slug<>pg_catalog.lower(p_slug) or pg_catalog.char_length(p_slug) not between 2 and 63 or p_slug !~ '^[a-z0-9]+(?:-[a-z0-9]+)*$' then return; end if;
  return query
  select tenant.slug,profile.public_slug,profile.display_name,profile.city,profile.logo_path,profile.hero_image_path,
    case when profile.show_about then profile.description else null end,
    case when profile.show_regulations then profile.regulations_path else null end,
    case when profile.show_contact then profile.public_address else null end,
    case when profile.show_contact then profile.public_phone else null end,
    case when profile.show_contact then profile.public_email else null end,
    case when profile.show_contact then profile.opening_hours else null end,
    case when profile.show_contact then profile.social_links else '{}'::jsonb end,
    profile.show_booking,profile.show_pricing,profile.show_instructor,
    profile.show_events,profile.show_about,profile.show_contact,profile.show_regulations
  from public.tenant_public_profiles profile join public.tenants tenant on tenant.id=profile.tenant_id
  where profile.is_public and tenant.status='active' and (profile.public_slug=p_slug or tenant.slug=p_slug)
    and not exists(select 1 from public.tenant_public_profiles other_profile join public.tenants other_tenant on other_tenant.id=other_profile.tenant_id where other_profile.is_public and other_tenant.status='active' and other_profile.tenant_id<>profile.tenant_id and (other_profile.public_slug=p_slug or other_tenant.slug=p_slug))
  limit 1;
end;
$function$;
alter function public.get_public_tenant_landing_v2(text) owner to postgres;
revoke all on function public.get_public_tenant_landing_v2(text) from public,anon,authenticated,service_role;
grant execute on function public.get_public_tenant_landing_v2(text) to anon,authenticated;

do $postflight$
begin
  if (select pg_catalog.count(*) from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prosecdef)<>80 then raise exception 'PRODUCT-10C postflight failed: SECURITY DEFINER count differs.'; end if;
  if exists(select 1 from pg_catalog.pg_policies where schemaname='public' and tablename='tenant_public_profiles')
     or pg_catalog.has_table_privilege('anon','public.tenant_public_profiles','SELECT,INSERT,UPDATE,DELETE')
     or pg_catalog.has_table_privilege('authenticated','public.tenant_public_profiles','SELECT,INSERT,UPDATE,DELETE')
     or pg_catalog.has_table_privilege('service_role','public.tenant_public_profiles','SELECT,INSERT,UPDATE,DELETE') then
    raise exception 'PRODUCT-10C postflight failed: direct table access opened.';
  end if;
end;
$postflight$;
