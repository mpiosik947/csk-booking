-- NEW-TENANT-2B: explicit PA-only configuration for private, zero-member drafts.
-- Existing tenant-admin entry points retain their existing authority checks.
create table app_private.draft_configuration_requests (
 actor_user_id uuid not null references auth.users(id) on delete cascade,
 request_id uuid not null,
 tenant_id uuid not null references public.tenants(id) on delete cascade,
 payload_hash text not null,
 result jsonb not null,
 created_at timestamptz not null default transaction_timestamp(),
 primary key(actor_user_id,request_id)
);
alter table app_private.draft_configuration_requests enable row level security;
revoke all on app_private.draft_configuration_requests from public,anon,authenticated,service_role;

create function app_private.pa_draft_config_scope_v1(tid uuid) returns boolean
language sql stable set search_path=pg_catalog,public,pg_temp as $$
 select public.is_platform_admin_v1() and app_private.recoverable_platform_draft_v1(tid);
$$;

create function app_private.lock_pa_draft_config_v1(tid uuid) returns void
language plpgsql set search_path=pg_catalog,public,pg_temp as $$
begin
 if not public.is_platform_admin_v1() then raise exception 'Not authorized' using errcode='42501'; end if;
 perform 1 from public.platform_admins where user_id=auth.uid() and status='active' for share nowait;
 if not found then raise exception 'Not authorized' using errcode='42501'; end if;
 perform 1 from public.tenants where id=tid and status='dormant' for no key update nowait;
 if not found or not app_private.pa_draft_config_scope_v1(tid) then
  raise exception 'DRAFT_CONFIGURATION_UNAVAILABLE' using errcode='42501'; end if;
 perform 1 from public.tenant_public_profiles where tenant_id=tid for update nowait;
 perform 1 from public.tenant_public_access_controls where tenant_id=tid for share nowait;
 perform 1 from public.tenant_plan_assignments where tenant_id=tid for share nowait;
 perform 1 from public.saas_plans order by id for share nowait;
 perform 1 from public.saas_plan_features order by plan_id,feature_key for share nowait;
 perform 1 from public.saas_features order by feature_key for share nowait;
end;$$;

create function app_private.draft_configuration_snapshot_v1(tid uuid) returns jsonb
language plpgsql stable set search_path=pg_catalog,public,pg_temp as $$
declare result jsonb; profile jsonb; items jsonb; plan jsonb;
begin
 select to_jsonb(p)-'tenant_id'-'created_at' into profile from public.tenant_public_profiles p where tenant_id=tid;
 select coalesce(jsonb_agg(jsonb_build_object('id',id,'title',title,'price',price,'currency',currency,'unit',unit,
 'short_description',short_description,'display_order',display_order,'is_active',is_active) order by display_order,id),'[]')
 into items from public.tenant_public_pricing_items where tenant_id=tid;
 select jsonb_build_object('plan_key',s.plan_key,'revision',a.revision::text,'status',a.status,'plan_status',s.status,
 'features',coalesce((select jsonb_agg(jsonb_build_object('key',f.feature_key,'active',f.active) order by f.feature_key)
 from public.saas_plan_features pf join public.saas_features f on f.feature_key=pf.feature_key where pf.plan_id=s.id),'[]'))
 into plan from public.tenant_plan_assignments a join public.saas_plans s on s.id=a.plan_id where a.tenant_id=tid;
 select jsonb_build_object('tenant_id',t.id,'name',t.name,'tenant_slug',t.slug,'status',t.status,'lifecycle_revision',t.lifecycle_revision::text,
 'profile',profile,'pricing_items',items,'plan',plan,
 'public_access_state',c.public_access_state,'public_access_revision',c.revision,
 'memberships',(select count(*) from public.tenant_memberships where tenant_id=tid),
 'lanes',public.tenant_draft_lane_configuration_core_v1(tid),
 'feature_access',jsonb_build_object('booking',public.tenant_setup_has_feature_core_v1(tid,'booking'),'events',public.tenant_setup_has_feature_core_v1(tid,'events'),'instructors',public.tenant_setup_has_feature_core_v1(tid,'instructors')),
 'partners',coalesce((select jsonb_agg(app_private.partner_public_json_v1(p)||jsonb_build_object('revision',p.revision) order by p.display_order,p.id) from public.tenant_partners p where p.tenant_id=tid and p.archived_at is null),'[]'))
 into result from public.tenants t join public.tenant_public_access_controls c on c.tenant_id=t.id where t.id=tid;
 return result;
end;$$;

create function public.platform_get_draft_configuration_v1(p_tenant_id uuid) returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,public,pg_temp as $$
declare result jsonb;
begin
 if not app_private.pa_draft_config_scope_v1(p_tenant_id) then raise exception 'Not authorized' using errcode='42501'; end if;
 result:=app_private.draft_configuration_snapshot_v1(p_tenant_id);
 return result||jsonb_build_object('revision',encode(sha256(convert_to(result::text,'UTF8')),'hex'));
end;$$;

create function public.platform_save_draft_configuration_v1(p_tenant_id uuid,p_expected_revision text,p_request_id uuid,p_section text,p_payload jsonb)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,pg_temp as $$
declare actor uuid:=auth.uid(); digest_value text; prior app_private.draft_configuration_requests;
 current_config jsonb; settings jsonb; content jsonb; mutation jsonb:='{"ok":true,"code":"updated","changed":true}';
 result jsonb; next_config jsonb; plan_preview jsonb;
 setting_keys constant text[]:=array['display_name','city','logo_path','hero_image_path','description','regulations_path','public_address','public_phone','public_email','opening_hours','social_links','show_booking','show_pricing','show_instructor','show_events','show_about','show_contact','show_regulations'];
 content_keys constant text[]:=array['about_offer','about_audience','public_map_url'];
begin
 if not public.is_platform_admin_v1() then raise exception 'Not authorized' using errcode='42501'; end if;
 if p_tenant_id is null or p_request_id is null or p_request_id='00000000-0000-0000-0000-000000000000'::uuid
 or p_expected_revision is null or p_expected_revision !~ '^[a-f0-9]{64}$'
 or p_section is null or p_section not in ('identity','profile','pricing','create_lane','update_lane','plan')
 or p_payload is null or jsonb_typeof(p_payload)<>'object' then raise exception 'INVALID_CONFIGURATION_REQUEST' using errcode='22023'; end if;
 digest_value:=encode(sha256(convert_to(jsonb_build_object('tenant_id',p_tenant_id,'revision',p_expected_revision,'section',p_section,'payload',p_payload)::text,'UTF8')),'hex');
 perform pg_advisory_xact_lock(hashtextextended(actor::text||':'||p_request_id::text,111000));
 perform app_private.lock_pa_draft_config_v1(p_tenant_id);
 select * into prior from app_private.draft_configuration_requests where actor_user_id=actor and request_id=p_request_id;
 if found then
  if prior.tenant_id<>p_tenant_id or prior.payload_hash<>digest_value then raise exception 'CONFIGURATION_REQUEST_CONFLICT' using errcode='22023'; end if;
  return prior.result;
 end if;
 current_config:=public.platform_get_draft_configuration_v1(p_tenant_id);
 if current_config->>'revision'<>p_expected_revision then raise exception 'DRAFT_CONFIGURATION_STALE' using errcode='PT409'; end if;
 if p_section='identity' then
  if (select array_agg(k order by k) from jsonb_object_keys(p_payload) k) is distinct from array['city','display_name','name']
  or jsonb_typeof(p_payload->'name')<>'string' or length(btrim(p_payload->>'name')) not between 1 and 120 then raise exception 'INVALID_IDENTITY' using errcode='22023'; end if;
  update public.tenants set name=btrim(p_payload->>'name') where id=p_tenant_id;
  select jsonb_object_agg(k,current_config->'profile'->k) into settings from unnest(setting_keys) k;
  perform app_private.tenant_public_settings_write_v1(p_tenant_id,settings||(p_payload-'name'),(current_config->'profile'->>'updated_at')::timestamptz,'platform_admin');
 elsif p_section in ('profile','pricing') then
  select jsonb_object_agg(k,current_config->'profile'->k) into settings from unnest(setting_keys) k;
  select jsonb_object_agg(k,current_config->'profile'->k) into content from unnest(content_keys) k;
  content:=content||jsonb_build_object('pricing_items',current_config->'pricing_items');
  if p_section='profile' then
   if p_payload='{}' or exists(select 1 from jsonb_object_keys(p_payload) k where not(k=any(setting_keys||content_keys))) then raise exception 'INVALID_PROFILE_PATCH' using errcode='22023'; end if;
   select settings||coalesce(jsonb_object_agg(key,value),'{}') into settings from jsonb_each(p_payload) where key=any(setting_keys);
   select content||coalesce(jsonb_object_agg(key,value),'{}') into content from jsonb_each(p_payload) where key=any(content_keys);
  else
   if (select array_agg(k) from jsonb_object_keys(p_payload) k) is distinct from array['pricing_items'] then raise exception 'INVALID_PRICING_PATCH' using errcode='22023'; end if;
   content:=content||p_payload;
  end if;
  perform app_private.tenant_content_write_v1(p_tenant_id,settings,content,(current_config->'profile'->>'updated_at')::timestamptz,'platform_admin');
 elsif p_section='create_lane' then
  mutation:=public.tenant_draft_create_lane_family_core_v1(p_tenant_id,p_payload);
 elsif p_section='update_lane' then
  if (select array_agg(k order by k) from jsonb_object_keys(p_payload) k) is distinct from array['expected_version','resources','root_lane_id']
  or jsonb_typeof(p_payload->'expected_version')<>'number' or jsonb_typeof(p_payload->'resources')<>'array'
  or jsonb_typeof(p_payload->'root_lane_id')<>'string' then raise exception 'INVALID_LANE_PATCH' using errcode='22023'; end if;
  if not exists(select 1 from public.shooting_lanes where id=(p_payload->>'root_lane_id')::uuid and tenant_id=p_tenant_id) then raise exception 'Not authorized' using errcode='42501'; end if;
  mutation:=public.tenant_draft_set_lane_configuration_core_v1((p_payload->>'root_lane_id')::uuid,(p_payload->>'expected_version')::bigint,p_payload->'resources',false);
 elsif p_section='plan' then
  if (select array_agg(k) from jsonb_object_keys(p_payload) k) is distinct from array['plan_key'] or jsonb_typeof(p_payload->'plan_key')<>'string' then raise exception 'INVALID_PLAN_PATCH' using errcode='22023'; end if;
  plan_preview:=public.platform_get_tenant_plan_change_preview_v1(p_tenant_id,p_payload->>'plan_key');
  perform public.platform_change_tenant_plan_v2(p_tenant_id,p_payload->>'plan_key',plan_preview->>'revision',p_request_id);
 end if;
 if (mutation->>'ok')::boolean is distinct from true then
  if mutation->>'code'='stale_configuration' then raise exception 'DRAFT_CONFIGURATION_STALE' using errcode='PT409'; end if;
  raise exception 'INVALID_LANE_CONFIGURATION' using errcode='22023',detail=mutation->>'code';
 end if;
 next_config:=public.platform_get_draft_configuration_v1(p_tenant_id);
 result:=jsonb_build_object('tenant_id',p_tenant_id,'request_id',p_request_id,'section',p_section,'revision',next_config->>'revision','mutation',mutation);
 insert into app_private.draft_configuration_requests(actor_user_id,request_id,tenant_id,payload_hash,result) values(actor,p_request_id,p_tenant_id,digest_value,result);
 insert into public.platform_audit_logs(actor_user_id,tenant_id,action,details) values(actor,p_tenant_id,'tenant_draft_configuration_updated',jsonb_build_object('section',p_section,'request_id',p_request_id,'previous_revision',p_expected_revision,'revision',next_config->>'revision'));
 return result;
end;$$;

revoke all on function app_private.pa_draft_config_scope_v1(uuid),app_private.lock_pa_draft_config_v1(uuid),app_private.draft_configuration_snapshot_v1(uuid) from public,anon,authenticated,service_role;
revoke all on function public.platform_get_draft_configuration_v1(uuid),public.platform_save_draft_configuration_v1(uuid,text,uuid,text,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.platform_get_draft_configuration_v1(uuid),public.platform_save_draft_configuration_v1(uuid,text,uuid,text,jsonb) to authenticated;

alter table public.platform_audit_logs drop constraint platform_audit_logs_action_check;
alter table public.platform_audit_logs add constraint platform_audit_logs_action_check CHECK ((action = ANY (ARRAY['tenant_created'::text, 'plan_assigned'::text, 'plan_changed'::text, 'tenant_admin_assigned'::text, 'tenant_activated'::text, 'tenant_suspended'::text, 'tenant_published'::text, 'tenant_unpublished'::text, 'platform_admin_bootstrapped'::text, 'domain_added'::text, 'domain_verification_started'::text, 'domain_verified'::text, 'domain_activated'::text, 'domain_disabled'::text, 'primary_domain_changed'::text, 'tenant_admin_add'::text, 'tenant_admin_reactivate'::text, 'tenant_admin_demote'::text, 'tenant_admin_suspend'::text, 'tenant_archived'::text, 'tenant_restored'::text, 'tenant_draft_configuration_updated'::text])));

CREATE OR REPLACE FUNCTION app_private.tenant_public_settings_write_v1(p_tenant_id uuid, p_settings jsonb, p_expected_updated_at timestamp with time zone, p_actor_role text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY INVOKER
 SET search_path TO 'pg_catalog', 'public', 'auth', 'pg_temp'
AS $function$
declare
  v_tenant_id uuid:=p_tenant_id; v_current public.tenant_public_profiles%rowtype; v_result jsonb;
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
  select * into v_current from public.tenant_public_profiles where tenant_id=v_tenant_id for update;
  if not found then raise exception using errcode='P0002',message='settings_not_found'; end if;
  if p_expected_updated_at is null or v_current.updated_at is distinct from p_expected_updated_at then raise exception using errcode='PT409',message='settings_conflict'; end if;

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
  values(v_tenant_id,auth.uid(),p_actor_role,'tenant_public_profile_updated','tenant_public_profile',v_tenant_id,pg_catalog.jsonb_build_object('changed_fields',coalesce(v_changed,array[]::text[])));
  v_result:=null;
  return v_result;
end;
$function$
;
create or replace function public.admin_update_tenant_public_settings_v1(p_tenant_slug text,p_settings jsonb,p_expected_updated_at timestamptz)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,auth,pg_temp as $$
declare v_tenant_id uuid;
begin
  select tenant.id into v_tenant_id
  from public.tenants tenant join public.tenant_memberships membership on membership.tenant_id=tenant.id
  where tenant.slug=p_tenant_slug and tenant.status in ('dormant','active') and membership.user_id=auth.uid() and membership.status='active' and membership.role='admin';
  if v_tenant_id is null then raise exception using errcode='42501',message='forbidden'; end if;

 perform app_private.tenant_public_settings_write_v1(v_tenant_id,p_settings,p_expected_updated_at,'admin');
 return public.admin_get_tenant_public_settings_v1(p_tenant_slug);
end;$$;

CREATE OR REPLACE FUNCTION app_private.tenant_content_write_v1(p_tenant_id uuid,p_settings jsonb,p_content jsonb,p_expected_updated_at timestamp with time zone,p_actor_role text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY INVOKER
 SET search_path TO 'pg_catalog', 'public', 'auth', 'pg_temp'
AS $function$
declare tid uuid:=p_tenant_id; before_profile public.tenant_public_profiles%rowtype; item jsonb; old_item public.tenant_public_pricing_items%rowtype;
 iid uuid; seen uuid[]:=array[]::uuid[]; changed text[]; action_name text;
begin
 -- Reuse the exact active membership/admin + lifecycle + optimistic concurrency contract.

 select * into before_profile from public.tenant_public_profiles where tenant_id=tid for update;
 if p_content is null or jsonb_typeof(p_content)<>'object'
 or (select array_agg(key order by key) from jsonb_object_keys(p_content) key) is distinct from array['about_audience','about_offer','pricing_items','public_map_url']::text[]
 or jsonb_typeof(p_content->'pricing_items')<>'array' or jsonb_array_length(p_content->'pricing_items')>100
 or exists(select 1 from jsonb_each(p_content) e where key<>'pricing_items' and jsonb_typeof(value) not in ('string','null')) then
 raise exception 'invalid_content_payload' using errcode='22023'; end if;
 perform app_private.tenant_public_settings_write_v1(tid,p_settings,p_expected_updated_at,p_actor_role);
 update public.tenant_public_profiles set about_offer=nullif(btrim(p_content->>'about_offer'),''),
 about_audience=nullif(btrim(p_content->>'about_audience'),''),public_map_url=nullif(btrim(p_content->>'public_map_url'),'') where tenant_id=tid;
 select array_agg(key order by key) into changed from unnest(array['description','about_offer','about_audience']) key
 where to_jsonb(before_profile)->key is distinct from (select to_jsonb(p)->key from public.tenant_public_profiles p where tenant_id=tid);
 if changed is not null then insert into public.audit_logs(tenant_id,actor_user_id,actor_role,action,target_type,target_id,details)
 values(tid,auth.uid(),p_actor_role,'public_about_updated','tenant_public_profile',tid,jsonb_build_object('changed_fields',changed)); end if;
 select array_agg(key order by key) into changed from unnest(array['city','public_address','public_phone','public_email','opening_hours','social_links','public_map_url']) key
 where to_jsonb(before_profile)->key is distinct from (select to_jsonb(p)->key from public.tenant_public_profiles p where tenant_id=tid);
 if changed is not null then insert into public.audit_logs(tenant_id,actor_user_id,actor_role,action,target_type,target_id,details)
 values(tid,auth.uid(),p_actor_role,'public_contact_updated','tenant_public_profile',tid,jsonb_build_object('changed_fields',changed)); end if;
 for item in select value from jsonb_array_elements(p_content->'pricing_items') loop
  if jsonb_typeof(item)<>'object' or (select array_agg(key order by key) from jsonb_object_keys(item) key) is distinct from
   array['currency','display_order','id','is_active','price','short_description','title','unit']::text[]
   or jsonb_typeof(item->'price')<>'number' or jsonb_typeof(item->'display_order')<>'number' or jsonb_typeof(item->'is_active')<>'boolean'
   or exists(select 1 from unnest(array['title','currency','unit']) key where jsonb_typeof(item->key)<>'string')
   or jsonb_typeof(item->'short_description') not in ('null','string') or jsonb_typeof(item->'id') not in ('null','string')
   then raise exception 'invalid_pricing_payload' using errcode='22023'; end if;
  iid:=(item->>'id')::uuid;
  old_item:=null;
  if iid is not null then
   if iid=any(seen) then raise exception 'duplicate_pricing_item' using errcode='22023'; end if;
   select * into old_item from public.tenant_public_pricing_items where id=iid and tenant_id=tid for update;
   if not found then raise exception 'forbidden' using errcode='42501'; end if;
  else iid:=gen_random_uuid(); end if;
  insert into public.tenant_public_pricing_items(id,tenant_id,title,price,currency,unit,short_description,display_order,is_active)
  values(iid,tid,btrim(item->>'title'),(item->>'price')::numeric,item->>'currency',btrim(item->>'unit'),nullif(btrim(item->>'short_description'),''),(item->>'display_order')::integer,(item->>'is_active')::boolean)
  on conflict(id) do update set title=excluded.title,price=excluded.price,currency=excluded.currency,unit=excluded.unit,short_description=excluded.short_description,display_order=excluded.display_order,is_active=excluded.is_active;
  seen:=array_append(seen,iid);
  select array_agg(key order by key) into changed from unnest(array['title','price','currency','unit','short_description','display_order','is_active']) key
  where to_jsonb(old_item)->key is distinct from (select to_jsonb(p)->key from public.tenant_public_pricing_items p where id=iid);
  if changed is not null then
   action_name:=case when old_item.id is null then 'pricing_item_created' when old_item.is_active and not (item->>'is_active')::boolean then 'pricing_item_disabled' else 'pricing_item_updated' end;
   insert into public.audit_logs(tenant_id,actor_user_id,actor_role,action,target_type,target_id,details)
   values(tid,auth.uid(),p_actor_role,action_name,'tenant_public_pricing_item',iid,jsonb_build_object('changed_fields',changed));
   if old_item.id is not null and old_item.display_order<>(item->>'display_order')::integer then
    insert into public.audit_logs(tenant_id,actor_user_id,actor_role,action,target_type,target_id,details)
    values(tid,auth.uid(),p_actor_role,'pricing_order_changed','tenant_public_pricing_item',iid,jsonb_build_object('changed_fields',array['display_order']));
   end if;
  end if;
 end loop;
 if exists(select 1 from public.tenant_public_pricing_items where tenant_id=tid and not(id=any(seen))) then
  raise exception 'pricing_items_must_be_disabled_not_deleted' using errcode='22023'; end if;
 return null;
end;$function$
;
create or replace function public.admin_update_tenant_content_v1(p_tenant_slug text,p_settings jsonb,p_content jsonb,p_expected_updated_at timestamptz)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,auth,pg_temp as $$
declare tid uuid;
begin
 perform public.admin_get_tenant_public_settings_v1(p_tenant_slug);
 select id into tid from public.tenants where slug=p_tenant_slug;
 perform app_private.tenant_content_write_v1(tid,p_settings,p_content,p_expected_updated_at,'admin');
 return public.admin_get_tenant_content_v1(p_tenant_slug);
end;$$;
revoke all on function app_private.tenant_public_settings_write_v1(uuid,jsonb,timestamptz,text),app_private.tenant_content_write_v1(uuid,jsonb,jsonb,timestamptz,text) from public,anon,authenticated,service_role;

-- Existing internal lane business engine; only its explicit draft PA authority/audit branch changes.
CREATE OR REPLACE FUNCTION public.tenant_draft_create_lane_family_core_v1(p_tenant_id uuid, p_family jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
declare
  v_actor_id uuid := auth.uid();
  v_actor public.profiles%rowtype;
  v_actor_role text;
  v_tenant_id uuid;
  v_root jsonb;
  v_positions jsonb;
  v_resources jsonb;
  v_resource record;
  v_price record;
  v_root_id uuid;
  v_position_id uuid;
  v_root_display_order integer;
  v_created_resources jsonb := '[]'::jsonb;
  v_created_count integer := 0;
  v_position_capacity integer := 0;
  v_now timestamptz := pg_catalog.transaction_timestamp();
begin
  perform tenant.id from public.tenants tenant where tenant.id=p_tenant_id for share;
  v_tenant_id:=p_tenant_id;
  if v_actor_id is null or v_tenant_id is null
     or (public.tenant_draft_setup_role_core_v1(v_tenant_id) is distinct from 'admin' and not app_private.pa_draft_config_scope_v1(v_tenant_id)) then
    return pg_catalog.jsonb_build_object(
      'ok',false,'changed',false,'code','not_allowed',
      'root_lane_id',null,'configuration_version',null,
      'created_resource_count',0
    );
  end if;

  select profile.*
  into v_actor
  from public.profiles as profile
  where profile.user_id = v_actor_id;

  v_actor_role := case when app_private.pa_draft_config_scope_v1(v_tenant_id) then 'platform_admin' else public.tenant_draft_setup_role_core_v1(v_tenant_id) end;
  if v_actor_id is null or coalesce(v_actor_role, '') not in ('admin','platform_admin') then
    return pg_catalog.jsonb_build_object(
      'ok', false,
      'changed', false,
      'code', 'not_allowed',
      'root_lane_id', null,
      'configuration_version', null,
      'created_resource_count', 0
    );
  end if;

  begin
    if p_family is null
       or pg_catalog.jsonb_typeof(p_family) <> 'object'
       or (
         select pg_catalog.array_agg(key order by key)
         from pg_catalog.jsonb_object_keys(p_family) as keys(key)
       ) is distinct from array['positions', 'root']::text[]
       or pg_catalog.jsonb_typeof(p_family->'root') <> 'object'
       or pg_catalog.jsonb_typeof(p_family->'positions') <> 'array'
       or pg_catalog.jsonb_array_length(p_family->'positions') > 100 then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'invalid_payload',
        'root_lane_id', null, 'configuration_version', null,
        'created_resource_count', 0
      );
    end if;

    v_root := p_family->'root';
    v_positions := p_family->'positions';

    if (
         select pg_catalog.array_agg(key order by key)
         from pg_catalog.jsonb_object_keys(v_root) as keys(key)
       ) is distinct from array[
         'booking_step_minutes', 'durations_minutes', 'is_active',
         'max_people_online', 'max_shooters', 'name', 'online_bookable',
         'positions_bookable', 'pricing', 'whole_lane_bookable'
       ]::text[]
       or exists (
         select 1
         from pg_catalog.jsonb_array_elements(v_positions) as position(value)
         where pg_catalog.jsonb_typeof(position.value) <> 'object'
            or (
              select pg_catalog.array_agg(key order by key)
              from pg_catalog.jsonb_object_keys(position.value) as keys(key)
            ) is distinct from array[
              'booking_step_minutes', 'durations_minutes', 'is_active',
              'max_people_online', 'max_shooters', 'name', 'online_bookable',
              'pricing'
            ]::text[]
       ) then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'invalid_payload',
        'root_lane_id', null, 'configuration_version', null,
        'created_resource_count', 0
      );
    end if;

    select pg_catalog.jsonb_build_array(
      v_root || pg_catalog.jsonb_build_object(
        'resource_kind', 'lane'
      )
    ) || coalesce(pg_catalog.jsonb_agg(
      position.value || pg_catalog.jsonb_build_object(
        'resource_kind', 'position',
        'whole_lane_bookable', false,
        'positions_bookable', false
      ) order by position.ordinality
    ), '[]'::jsonb)
    into v_resources
    from pg_catalog.jsonb_array_elements(v_positions) with ordinality
      as position(value, ordinality);

    for v_resource in
      select resource.value, resource.ordinality
      from pg_catalog.jsonb_array_elements(v_resources) with ordinality
        as resource(value, ordinality)
      order by resource.ordinality
    loop
      if pg_catalog.jsonb_typeof(v_resource.value->'name') <> 'string'
         or pg_catalog.btrim(v_resource.value->>'name') = ''
         or pg_catalog.char_length(pg_catalog.btrim(v_resource.value->>'name')) > 120
         or v_resource.value->>'name' ~ '[<>]'
         or v_resource.value->>'name' ~ '[[:cntrl:]]'
         or pg_catalog.jsonb_typeof(v_resource.value->'is_active') <> 'boolean'
         or pg_catalog.jsonb_typeof(v_resource.value->'online_bookable') <> 'boolean'
         or pg_catalog.jsonb_typeof(v_resource.value->'whole_lane_bookable') <> 'boolean'
         or pg_catalog.jsonb_typeof(v_resource.value->'positions_bookable') <> 'boolean'
         or pg_catalog.jsonb_typeof(v_resource.value->'max_shooters') <> 'number'
         or v_resource.value->>'max_shooters' !~ '^[1-9][0-9]*$'
         or pg_catalog.jsonb_typeof(v_resource.value->'max_people_online') <> 'number'
         or v_resource.value->>'max_people_online' !~ '^[1-9][0-9]*$'
         or pg_catalog.jsonb_typeof(v_resource.value->'booking_step_minutes') <> 'number'
         or v_resource.value->>'booking_step_minutes' !~ '^[1-9][0-9]*$'
         or (v_resource.value->>'booking_step_minutes')::integer > 1440
         or (v_resource.value->>'max_people_online')::integer
              > (v_resource.value->>'max_shooters')::integer
         or pg_catalog.jsonb_typeof(v_resource.value->'durations_minutes') <> 'array'
         or pg_catalog.jsonb_array_length(v_resource.value->'durations_minutes') = 0
         or pg_catalog.jsonb_typeof(v_resource.value->'pricing') <> 'array'
         or pg_catalog.jsonb_array_length(v_resource.value->'pricing') = 0 then
        return pg_catalog.jsonb_build_object(
          'ok', false, 'changed', false, 'code', 'invalid_payload',
          'root_lane_id', null, 'configuration_version', null,
          'created_resource_count', 0
        );
      end if;

      if exists (
           select 1
           from pg_catalog.jsonb_array_elements(
             v_resource.value->'durations_minutes'
           ) as duration(value)
           where pg_catalog.jsonb_typeof(duration.value) <> 'number'
              or duration.value #>> '{}' !~ '^[1-9][0-9]*$'
              or (duration.value #>> '{}')::integer > 1440
              or (duration.value #>> '{}')::integer
                   % (v_resource.value->>'booking_step_minutes')::integer <> 0
         )
         or (
           select pg_catalog.count(*)
           from pg_catalog.jsonb_array_elements(
             v_resource.value->'durations_minutes'
           )
         ) <> (
           select pg_catalog.count(distinct duration.value #>> '{}')
           from pg_catalog.jsonb_array_elements(
             v_resource.value->'durations_minutes'
           ) as duration(value)
         ) then
        return pg_catalog.jsonb_build_object(
          'ok', false, 'changed', false, 'code', 'invalid_configuration',
          'root_lane_id', null, 'configuration_version', null,
          'created_resource_count', 0
        );
      end if;

      for v_price in
        select price.value
        from pg_catalog.jsonb_array_elements(v_resource.value->'pricing')
          as price(value)
      loop
        if pg_catalog.jsonb_typeof(v_price.value) <> 'object'
           or (
             select pg_catalog.array_agg(key order by key)
             from pg_catalog.jsonb_object_keys(v_price.value) as keys(key)
           ) is distinct from array[
             'day_group', 'hourly_price', 'label', 'max_shooters', 'min_shooters'
           ]::text[]
           or pg_catalog.jsonb_typeof(v_price.value->'day_group') <> 'string'
           or v_price.value->>'day_group' not in ('mon_thu', 'fri_sun')
           or pg_catalog.jsonb_typeof(v_price.value->'label') <> 'string'
           or pg_catalog.btrim(v_price.value->>'label') = ''
           or pg_catalog.jsonb_typeof(v_price.value->'min_shooters') <> 'number'
           or v_price.value->>'min_shooters' !~ '^[1-9][0-9]*$'
           or pg_catalog.jsonb_typeof(v_price.value->'max_shooters') <> 'number'
           or v_price.value->>'max_shooters' !~ '^[1-9][0-9]*$'
           or pg_catalog.jsonb_typeof(v_price.value->'hourly_price') <> 'number'
           or v_price.value->>'hourly_price' !~ '^[0-9]+([.][0-9]{1,2})?$'
           or (v_price.value->>'min_shooters')::integer
                > (v_price.value->>'max_shooters')::integer
           or (v_price.value->>'max_shooters')::integer
                > (v_resource.value->>'max_people_online')::integer
           or (v_price.value->>'hourly_price')::numeric > 9999999999.99 then
          return pg_catalog.jsonb_build_object(
            'ok', false, 'changed', false, 'code', 'invalid_payload',
            'root_lane_id', null, 'configuration_version', null,
            'created_resource_count', 0
          );
        end if;
      end loop;

      if exists (
           with parsed as (
             select
               price.value->>'day_group' as day_group,
               (price.value->>'min_shooters')::integer as min_shooters,
               (price.value->>'max_shooters')::integer as max_shooters,
               pg_catalog.lag((price.value->>'max_shooters')::integer) over (
                 partition by price.value->>'day_group'
                 order by (price.value->>'min_shooters')::integer,
                          (price.value->>'max_shooters')::integer
               ) as previous_max
             from pg_catalog.jsonb_array_elements(v_resource.value->'pricing')
               as price(value)
           )
           select 1 from parsed
           where (previous_max is null and min_shooters <> 1)
              or (previous_max is not null and min_shooters <> previous_max + 1)
         )
         or (
           select pg_catalog.count(*)
           from (
             select price.value->>'day_group' as day_group
             from pg_catalog.jsonb_array_elements(v_resource.value->'pricing')
               as price(value)
             group by price.value->>'day_group'
             having pg_catalog.max((price.value->>'max_shooters')::integer)
                    = (v_resource.value->>'max_people_online')::integer
           ) as complete_group
         ) <> 2 then
        return pg_catalog.jsonb_build_object(
          'ok', false, 'changed', false, 'code', 'invalid_configuration',
          'root_lane_id', null, 'configuration_version', null,
          'created_resource_count', 0
        );
      end if;
    end loop;
  exception
    when sqlstate '22003' or sqlstate '22P02' then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'invalid_payload',
        'root_lane_id', null, 'configuration_version', null,
        'created_resource_count', 0
      );
  end;

  if (v_root->>'online_bookable')::boolean
       and (not (v_root->>'is_active')::boolean
            or not (v_root->>'whole_lane_bookable')::boolean)
     or not (v_root->>'is_active')::boolean
       and (
         (v_root->>'online_bookable')::boolean
         or exists (
           select 1
           from pg_catalog.jsonb_array_elements(v_positions) as position(value)
           where (position.value->>'is_active')::boolean
              or (position.value->>'online_bookable')::boolean
         )
       )
     or exists (
       select 1
       from pg_catalog.jsonb_array_elements(v_positions) as position(value)
       where (position.value->>'online_bookable')::boolean
         and (
           not (position.value->>'is_active')::boolean
           or not (v_root->>'positions_bookable')::boolean
         )
     )
     or (
       (v_root->>'positions_bookable')::boolean
       and not exists (
         select 1
         from pg_catalog.jsonb_array_elements(v_positions) as position(value)
         where (position.value->>'is_active')::boolean
           and (position.value->>'online_bookable')::boolean
       )
     ) then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_configuration',
      'root_lane_id', null, 'configuration_version', null,
      'created_resource_count', 0
    );
  end if;

  select coalesce(pg_catalog.sum((position.value->>'max_shooters')::integer), 0)
  into v_position_capacity
  from pg_catalog.jsonb_array_elements(v_positions) as position(value)
  where (position.value->>'is_active')::boolean
    and (position.value->>'online_bookable')::boolean;

  if (v_root->>'positions_bookable')::boolean
     and v_position_capacity > (v_root->>'max_shooters')::integer then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_configuration',
      'root_lane_id', null, 'configuration_version', null,
      'created_resource_count', 0
    );
  end if;

  lock table public.shooting_lanes in share row exclusive mode;

  select coalesce(pg_catalog.max(lane.display_order), 0) + 10
  into v_root_display_order
  from public.shooting_lanes as lane
  where lane.tenant_id=v_tenant_id;

  v_root_id := pg_catalog.gen_random_uuid();
  insert into public.shooting_lanes(
    tenant_id, id, name, type, description, price_per_hour, is_active,
    max_shooters, booking_step_minutes, display_order, currency_code,
    resource_kind, parent_lane_id, whole_lane_bookable, positions_bookable
  ) values (
    v_tenant_id, v_root_id,
    pg_catalog.btrim(v_root->>'name'),
    'konfigurowalna',
    null,
    0,
    (v_root->>'is_active')::boolean,
    (v_root->>'max_shooters')::integer,
    (v_root->>'booking_step_minutes')::integer,
    v_root_display_order,
    'PLN',
    'lane',
    null,
    (v_root->>'whole_lane_bookable')::boolean,
    (v_root->>'positions_bookable')::boolean
  );

  insert into public.lane_booking_rules(lane_id, online_bookable, max_people_online)
  values (
    v_root_id,
    (v_root->>'online_bookable')::boolean,
    (v_root->>'max_people_online')::integer
  );

  insert into public.lane_booking_durations(
    lane_id, duration_minutes, display_order, is_active
  )
  select
    v_root_id,
    (duration.value #>> '{}')::integer,
    duration.ordinality * 10,
    true
  from pg_catalog.jsonb_array_elements(v_root->'durations_minutes') with ordinality
    as duration(value, ordinality);

  insert into public.lane_pricing_rules(
    lane_id, day_group, min_shooters, max_shooters,
    label, hourly_price, display_order, is_active
  )
  select
    v_root_id,
    price.value->>'day_group',
    (price.value->>'min_shooters')::integer,
    (price.value->>'max_shooters')::integer,
    pg_catalog.btrim(price.value->>'label'),
    (price.value->>'hourly_price')::numeric(12,2),
    pg_catalog.row_number() over (
      partition by price.value->>'day_group'
      order by (price.value->>'min_shooters')::integer,
               (price.value->>'max_shooters')::integer,
               pg_catalog.btrim(price.value->>'label')
    ) * 10,
    true
  from pg_catalog.jsonb_array_elements(v_root->'pricing') as price(value);

  v_created_resources := pg_catalog.jsonb_build_array(
    pg_catalog.jsonb_build_object(
      'resource_id', v_root_id,
      'resource_kind', 'lane',
      'name', pg_catalog.btrim(v_root->>'name')
    )
  );
  v_created_count := 1;

  for v_resource in
    select position.value, position.ordinality
    from pg_catalog.jsonb_array_elements(v_positions) with ordinality
      as position(value, ordinality)
    order by position.ordinality
  loop
    v_position_id := pg_catalog.gen_random_uuid();
    insert into public.shooting_lanes(
      tenant_id, id, name, type, description, price_per_hour, is_active,
      max_shooters, booking_step_minutes, display_order, currency_code,
      resource_kind, parent_lane_id, whole_lane_bookable, positions_bookable
    ) values (
      v_tenant_id, v_position_id,
      pg_catalog.btrim(v_resource.value->>'name'),
      'konfigurowalna',
      null,
      0,
      (v_resource.value->>'is_active')::boolean,
      (v_resource.value->>'max_shooters')::integer,
      (v_resource.value->>'booking_step_minutes')::integer,
      v_root_display_order + v_resource.ordinality::integer,
      'PLN',
      'position',
      v_root_id,
      false,
      false
    );

    insert into public.lane_booking_rules(lane_id, online_bookable, max_people_online)
    values (
      v_position_id,
      (v_resource.value->>'online_bookable')::boolean,
      (v_resource.value->>'max_people_online')::integer
    );

    insert into public.lane_booking_durations(
      lane_id, duration_minutes, display_order, is_active
    )
    select
      v_position_id,
      (duration.value #>> '{}')::integer,
      duration.ordinality * 10,
      true
    from pg_catalog.jsonb_array_elements(
      v_resource.value->'durations_minutes'
    ) with ordinality as duration(value, ordinality);

    insert into public.lane_pricing_rules(
      lane_id, day_group, min_shooters, max_shooters,
      label, hourly_price, display_order, is_active
    )
    select
      v_position_id,
      price.value->>'day_group',
      (price.value->>'min_shooters')::integer,
      (price.value->>'max_shooters')::integer,
      pg_catalog.btrim(price.value->>'label'),
      (price.value->>'hourly_price')::numeric(12,2),
      pg_catalog.row_number() over (
        partition by price.value->>'day_group'
        order by (price.value->>'min_shooters')::integer,
                 (price.value->>'max_shooters')::integer,
                 pg_catalog.btrim(price.value->>'label')
      ) * 10,
      true
    from pg_catalog.jsonb_array_elements(v_resource.value->'pricing')
      as price(value);

    v_created_resources := v_created_resources || pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object(
        'resource_id', v_position_id,
        'resource_kind', 'position',
        'name', pg_catalog.btrim(v_resource.value->>'name')
      )
    );
    v_created_count := v_created_count + 1;
  end loop;

  insert into public.lane_booking_family_configuration_versions(
    root_lane_id, configuration_version
  ) values (v_root_id, 1);

  insert into public.audit_logs(
    tenant_id, actor_user_id, actor_name, actor_role, action,
    target_type, target_id, target_name, details
  ) values (
    v_tenant_id, v_actor_id,
    coalesce(
      nullif(
        pg_catalog.btrim(
          pg_catalog.concat_ws(' ', v_actor.first_name, v_actor.last_name)
        ),
        ''
      ),
      nullif(pg_catalog.btrim(v_actor.full_name), ''),
      'Administrator'
    ),
    v_actor_role,
    'lane_booking_family_created',
    'lane_booking_family',
    v_root_id,
    pg_catalog.btrim(v_root->>'name'),
    pg_catalog.jsonb_build_object(
      'configuration_version', 1,
      'created_resources', v_created_resources,
      'created_at', v_now
    )
  );

  return pg_catalog.jsonb_build_object(
    'ok', true,
    'changed', true,
    'code', 'created',
    'root_lane_id', v_root_id,
    'configuration_version', 1,
    'created_resource_count', v_created_count
  );
end;
$function$
;

-- Existing internal lane business engine; only its explicit draft PA authority/audit branch changes.
CREATE OR REPLACE FUNCTION public.tenant_draft_set_lane_configuration_core_v1(p_root_lane_id uuid, p_expected_version bigint, p_resources jsonb, p_acknowledge_future_obligations boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
declare
  v_actor_id uuid := auth.uid();
  v_actor public.profiles%rowtype;
  v_actor_role text;
  v_tenant_id uuid;
  v_root public.shooting_lanes%rowtype;
  v_root_target jsonb;
  v_target jsonb;
  v_current jsonb;
  v_target_without_names jsonb;
  v_current_without_names jsonb;
  v_renamed_resources jsonb := '[]'::jsonb;
  v_name_only boolean := false;
  v_family_ids uuid[];
  v_target_ids uuid[];
  v_affected_ids uuid[] := '{}'::uuid[];
  v_version bigint;
  v_resource record;
  v_lane public.shooting_lanes%rowtype;
  v_rule public.lane_booking_rules%rowtype;
  v_price record;
  v_previous_max integer;
  v_group_count integer;
  v_position_capacity integer;
  v_max_obligation integer;
  v_future_reservations bigint := 0;
  v_future_blocks bigint := 0;
  v_future_events bigint := 0;
  v_now timestamptz := pg_catalog.transaction_timestamp();
begin
  select profile.* into v_actor
  from public.profiles as profile
  where profile.user_id = v_actor_id;


  if v_actor_id is null then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'not_allowed',
      'root_lane_id', p_root_lane_id
    );
  end if;

  if p_root_lane_id is null or p_expected_version is null
     or p_expected_version < 1 or p_acknowledge_future_obligations is null then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_payload',
      'root_lane_id', p_root_lane_id
    );
  end if;

  select root.tenant_id into v_tenant_id
  from public.shooting_lanes root
  where root.id=p_root_lane_id;

  if not found then
    return pg_catalog.jsonb_build_object(
      'ok',false,'changed',false,'code','family_not_found',
      'root_lane_id',p_root_lane_id
    );
  end if;

  if (public.tenant_draft_setup_role_core_v1(v_tenant_id) is distinct from 'admin' and not app_private.pa_draft_config_scope_v1(v_tenant_id)) then
    return pg_catalog.jsonb_build_object(
      'ok',false,'changed',false,'code','not_allowed',
      'root_lane_id',p_root_lane_id
    );
  end if;

  begin
    v_target := public.normalize_lane_booking_family_payload_v2(p_resources);
  exception when sqlstate '22023' then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_payload',
      'root_lane_id', p_root_lane_id
    );
  end;

  begin
    select scope.conflict_lane_ids into v_family_ids
    from public.lock_lane_conflict_families_v1(array[p_root_lane_id]) as scope
    where scope.requested_lane_id = p_root_lane_id
      and scope.root_lane_id = p_root_lane_id
      and scope.requested_resource_kind = 'lane';
  exception
    when sqlstate 'P0002' then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'family_not_found',
        'root_lane_id', p_root_lane_id
      );
    when sqlstate '55000' or sqlstate '22023' then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'invalid_hierarchy',
        'root_lane_id', p_root_lane_id
      );
  end;

  if v_family_ids is null then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_hierarchy',
      'root_lane_id', p_root_lane_id
    );
  end if;

  if (select pg_catalog.count(*) from public.shooting_lanes lane where lane.id=any(v_family_ids) and lane.tenant_id=v_tenant_id)<>pg_catalog.cardinality(v_family_ids) then
    return pg_catalog.jsonb_build_object(
      'ok',false,'changed',false,'code','not_allowed',
      'root_lane_id',p_root_lane_id
    );
  end if;

  select pg_catalog.array_agg(family_id order by family_id)
  into v_family_ids
  from pg_catalog.unnest(v_family_ids) as family(family_id);

  select root.* into v_root
  from public.shooting_lanes as root
  where root.id = p_root_lane_id
    and root.tenant_id = v_tenant_id;

  select version.configuration_version into v_version
  from public.lane_booking_family_configuration_versions as version
  where version.root_lane_id = p_root_lane_id
  for update;

  if not found then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_hierarchy',
      'root_lane_id', p_root_lane_id
    );
  end if;

  if v_version <> p_expected_version then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'stale_configuration',
      'root_lane_id', p_root_lane_id,
      'current_version', v_version,
      'previous_version', v_version,
      'configuration_version', v_version
    );
  end if;

  select pg_catalog.array_agg((item.value->>'lane_id')::uuid order by (item.value->>'lane_id')::uuid)
  into v_target_ids
  from pg_catalog.jsonb_array_elements(v_target) as item(value);

  if v_target_ids is distinct from v_family_ids then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_payload',
      'root_lane_id', p_root_lane_id,
      'previous_version', v_version,
      'configuration_version', v_version
    );
  end if;

  perform rule.lane_id
  from public.lane_booking_rules as rule
  where rule.lane_id = any(v_family_ids)
  order by rule.lane_id
  for update;

  if (select pg_catalog.count(*) from public.lane_booking_rules
      where lane_id = any(v_family_ids)) <> pg_catalog.cardinality(v_family_ids) then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_hierarchy',
      'root_lane_id', p_root_lane_id,
      'previous_version', v_version,
      'configuration_version', v_version
    );
  end if;

  perform duration.id
  from public.lane_booking_durations as duration
  where duration.lane_id = any(v_family_ids)
  order by duration.lane_id, duration.duration_minutes, duration.id
  for update;

  perform pricing.id
  from public.lane_pricing_rules as pricing
  where pricing.lane_id = any(v_family_ids)
  order by pricing.lane_id, pricing.day_group, pricing.min_shooters,
           pricing.max_shooters, pricing.id
  for update;

  v_current := public.lane_booking_family_business_snapshot_v2(p_root_lane_id);
  v_root_target := (
    select item.value from pg_catalog.jsonb_array_elements(v_target) as item(value)
    where item.value->>'lane_id' = p_root_lane_id::text
  );

  select pg_catalog.jsonb_agg(item.value - 'name' order by (item.value->>'lane_id')::uuid)
  into v_current_without_names
  from pg_catalog.jsonb_array_elements(v_current) as item(value);

  select pg_catalog.jsonb_agg(item.value - 'name' order by (item.value->>'lane_id')::uuid)
  into v_target_without_names
  from pg_catalog.jsonb_array_elements(v_target) as item(value);

  select coalesce(pg_catalog.jsonb_agg(
    pg_catalog.jsonb_build_object(
      'resource_id', (target.value->>'lane_id')::uuid,
      'old_name', current.value->>'name',
      'new_name', target.value->>'name'
    ) order by (target.value->>'lane_id')::uuid
  ), '[]'::jsonb)
  into v_renamed_resources
  from pg_catalog.jsonb_array_elements(v_target) as target(value)
  join pg_catalog.jsonb_array_elements(v_current) as current(value)
    on current.value->>'lane_id' = target.value->>'lane_id'
  where current.value->>'name' is distinct from target.value->>'name';

  v_name_only := v_current_without_names = v_target_without_names;

  if v_root.resource_kind <> 'lane' or v_root.parent_lane_id is not null
     or v_root_target is null then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_hierarchy',
      'root_lane_id', p_root_lane_id,
      'previous_version', v_version,
      'configuration_version', v_version
    );
  end if;

  for v_resource in
    select item.value
    from pg_catalog.jsonb_array_elements(v_target) as item(value)
    order by (item.value->>'lane_id')::uuid
  loop
    select lane.* into v_lane
    from public.shooting_lanes as lane
    where lane.id = (v_resource.value->>'lane_id')::uuid
      and lane.tenant_id = v_tenant_id;

    if not found
       or (v_lane.id = p_root_lane_id and
           (v_lane.resource_kind <> 'lane' or v_lane.parent_lane_id is not null))
       or (v_lane.id <> p_root_lane_id and
           (v_lane.resource_kind <> 'position'
            or v_lane.parent_lane_id is distinct from p_root_lane_id))
       or (v_lane.resource_kind = 'position' and
           ((v_resource.value->>'whole_lane_bookable')::boolean
            or (v_resource.value->>'positions_bookable')::boolean))
       or (v_resource.value->>'max_shooters')::integer < 1
       or (v_resource.value->>'max_people_online')::integer < 1
       or (v_resource.value->>'max_people_online')::integer
            > (v_resource.value->>'max_shooters')::integer then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'invalid_hierarchy',
        'root_lane_id', p_root_lane_id,
        'previous_version', v_version,
        'configuration_version', v_version
      );
    end if;

    if exists (
         select 1
         from pg_catalog.jsonb_array_elements(v_resource.value->'durations_minutes') as duration(value)
         where (duration.value #>> '{}')::integer <= 0
            or (duration.value #>> '{}')::integer > 1440
            or (duration.value #>> '{}')::integer % v_lane.booking_step_minutes <> 0
       )
       or ((v_resource.value->>'online_bookable')::boolean
           and pg_catalog.jsonb_array_length(v_resource.value->'durations_minutes') = 0) then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'invalid_configuration',
        'root_lane_id', p_root_lane_id,
        'previous_version', v_version,
        'configuration_version', v_version
      );
    end if;

    v_previous_max := null;
    v_group_count := 0;
    for v_price in
      select
        price.value->>'day_group' as day_group,
        (price.value->>'min_shooters')::integer as min_shooters,
        (price.value->>'max_shooters')::integer as max_shooters,
        (price.value->>'hourly_price')::numeric as hourly_price
      from pg_catalog.jsonb_array_elements(v_resource.value->'pricing') as price(value)
      order by price.value->>'day_group',
               (price.value->>'min_shooters')::integer,
               (price.value->>'max_shooters')::integer
    loop
      if v_price.min_shooters < 1
         or v_price.max_shooters < v_price.min_shooters
         or v_price.max_shooters > (v_resource.value->>'max_people_online')::integer
         or v_price.hourly_price < 0
         or v_price.hourly_price > 9999999999.99
         or v_price.hourly_price <> pg_catalog.round(v_price.hourly_price, 2) then
        return pg_catalog.jsonb_build_object(
          'ok', false, 'changed', false, 'code', 'invalid_configuration',
          'root_lane_id', p_root_lane_id,
          'previous_version', v_version,
          'configuration_version', v_version
        );
      end if;
    end loop;

    if pg_catalog.jsonb_array_length(v_resource.value->'pricing') > 0 then
      if exists (
           with parsed as (
             select price.value->>'day_group' as day_group,
                    (price.value->>'min_shooters')::integer as min_shooters,
                    (price.value->>'max_shooters')::integer as max_shooters,
                    pg_catalog.lag((price.value->>'max_shooters')::integer) over (
                      partition by price.value->>'day_group'
                      order by (price.value->>'min_shooters')::integer,
                               (price.value->>'max_shooters')::integer
                    ) as previous_max
             from pg_catalog.jsonb_array_elements(v_resource.value->'pricing') as price(value)
           )
           select 1 from parsed
           where (previous_max is null and min_shooters <> 1)
              or (previous_max is not null and min_shooters <> previous_max + 1)
         )
         or (select pg_catalog.count(*) from (
               select price.value->>'day_group'
               from pg_catalog.jsonb_array_elements(v_resource.value->'pricing') as price(value)
               group by price.value->>'day_group'
               having pg_catalog.max((price.value->>'max_shooters')::integer)
                      = (v_resource.value->>'max_people_online')::integer
             ) as valid_group) <> 2 then
        return pg_catalog.jsonb_build_object(
          'ok', false, 'changed', false, 'code', 'invalid_configuration',
          'root_lane_id', p_root_lane_id,
          'previous_version', v_version,
          'configuration_version', v_version
        );
      end if;
    elsif (v_resource.value->>'online_bookable')::boolean then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'invalid_configuration',
        'root_lane_id', p_root_lane_id,
        'previous_version', v_version,
        'configuration_version', v_version
      );
    end if;

    if (v_resource.value->>'online_bookable')::boolean
       and not (v_resource.value->>'is_active')::boolean then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'invalid_configuration',
        'root_lane_id', p_root_lane_id,
        'previous_version', v_version,
        'configuration_version', v_version
      );
    end if;
  end loop;

  if (v_root_target->>'online_bookable')::boolean
     and not (v_root_target->>'whole_lane_bookable')::boolean then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_configuration',
      'root_lane_id', p_root_lane_id,
      'previous_version', v_version,
      'configuration_version', v_version
    );
  end if;

  if not (v_root_target->>'is_active')::boolean
     and ((v_root_target->>'online_bookable')::boolean
          or exists (
            select 1 from pg_catalog.jsonb_array_elements(v_target) as item(value)
            where item.value->>'lane_id' <> p_root_lane_id::text
              and ((item.value->>'is_active')::boolean
                   or (item.value->>'online_bookable')::boolean)
          )) then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_configuration',
      'root_lane_id', p_root_lane_id,
      'previous_version', v_version,
      'configuration_version', v_version
    );
  end if;

  if exists (
       select 1 from pg_catalog.jsonb_array_elements(v_target) as item(value)
       where item.value->>'lane_id' <> p_root_lane_id::text
         and (item.value->>'is_active')::boolean
         and not (v_root_target->>'is_active')::boolean
     )
     or exists (
       select 1 from pg_catalog.jsonb_array_elements(v_target) as item(value)
       where item.value->>'lane_id' <> p_root_lane_id::text
         and (item.value->>'online_bookable')::boolean
         and (not (v_root_target->>'is_active')::boolean
              or not (v_root_target->>'positions_bookable')::boolean)
     ) then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_configuration',
      'root_lane_id', p_root_lane_id,
      'previous_version', v_version,
      'configuration_version', v_version
    );
  end if;

  if (v_root_target->>'positions_bookable')::boolean
     and not exists (
       select 1 from pg_catalog.jsonb_array_elements(v_target) as item(value)
       where item.value->>'lane_id' <> p_root_lane_id::text
         and (item.value->>'is_active')::boolean
         and (item.value->>'online_bookable')::boolean
         and pg_catalog.jsonb_array_length(item.value->'durations_minutes') > 0
         and pg_catalog.jsonb_array_length(item.value->'pricing') > 0
     ) then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_configuration',
      'root_lane_id', p_root_lane_id,
      'previous_version', v_version,
      'configuration_version', v_version
    );
  end if;

  select coalesce(pg_catalog.sum((item.value->>'max_shooters')::integer), 0)
  into v_position_capacity
  from pg_catalog.jsonb_array_elements(v_target) as item(value)
  where item.value->>'lane_id' <> p_root_lane_id::text
    and (item.value->>'is_active')::boolean
    and (item.value->>'online_bookable')::boolean;

  if (v_root_target->>'positions_bookable')::boolean
     and v_position_capacity > (v_root_target->>'max_shooters')::integer then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'invalid_configuration',
      'root_lane_id', p_root_lane_id,
      'previous_version', v_version,
      'configuration_version', v_version
    );
  end if;

  if v_current = v_target then
    return pg_catalog.jsonb_build_object(
      'ok', true, 'changed', false, 'code', 'no_change',
      'root_lane_id', p_root_lane_id,
      'previous_version', v_version,
      'configuration_version', v_version
    );
  end if;

  for v_resource in
    select item.value
    from pg_catalog.jsonb_array_elements(v_target) as item(value)
  loop
    select pg_catalog.max(reservation.shooters_count)
    into v_max_obligation
    from public.reservations as reservation
    where reservation.lane_id = (v_resource.value->>'lane_id')::uuid
      and reservation.tenant_id = v_tenant_id
      and pg_catalog.lower(pg_catalog.btrim(reservation.reservation_status)) not in (
        'completed','no_show','cancelled','canceled',
        'cancelled_by_admin','cancelled_by_user'
      )
      and (reservation.reservation_date, reservation.end_time) >
          ((v_now at time zone 'Europe/Warsaw')::date,
           (v_now at time zone 'Europe/Warsaw')::time);

    if v_max_obligation is not null
       and (v_resource.value->>'max_shooters')::integer < v_max_obligation then
      return pg_catalog.jsonb_build_object(
        'ok', false, 'changed', false, 'code', 'reservation_capacity_conflict',
        'root_lane_id', p_root_lane_id,
        'previous_version', v_version,
        'configuration_version', v_version
      );
    end if;
  end loop;

  if v_root.is_active and not (v_root_target->>'is_active')::boolean then
    v_affected_ids := v_family_ids;
  else
    if v_root.whole_lane_bookable
       and not (v_root_target->>'whole_lane_bookable')::boolean then
      v_affected_ids := pg_catalog.array_append(v_affected_ids, p_root_lane_id);
    end if;
    if v_root.positions_bookable
       and not (v_root_target->>'positions_bookable')::boolean then
      select coalesce(pg_catalog.array_agg(id order by id), '{}'::uuid[])
      into v_affected_ids
      from (
        select distinct id from pg_catalog.unnest(
          v_affected_ids || array(
            select child.id from public.shooting_lanes as child
            where child.parent_lane_id = p_root_lane_id
              and child.tenant_id = v_tenant_id
          )
        ) as ids(id)
      ) as affected;
    end if;
    select coalesce(pg_catalog.array_agg(id order by id), '{}'::uuid[])
    into v_affected_ids
    from (
      select distinct (item.value->>'lane_id')::uuid as id
      from pg_catalog.jsonb_array_elements(v_target) as item(value)
      join public.shooting_lanes as current_lane
        on current_lane.id = (item.value->>'lane_id')::uuid
       and current_lane.tenant_id = v_tenant_id
      where current_lane.is_active
        and not (item.value->>'is_active')::boolean
      union
      select id from pg_catalog.unnest(v_affected_ids) as ids(id)
    ) as affected;
  end if;

  if pg_catalog.cardinality(v_affected_ids) > 0 then
    select pg_catalog.count(*) into v_future_reservations
    from public.reservations as reservation
    where reservation.lane_id = any(v_affected_ids)
      and reservation.tenant_id = v_tenant_id
      and pg_catalog.lower(pg_catalog.btrim(reservation.reservation_status)) not in (
        'completed','no_show','cancelled','canceled',
        'cancelled_by_admin','cancelled_by_user'
      )
      and (reservation.reservation_date, reservation.end_time) >
          ((v_now at time zone 'Europe/Warsaw')::date,
           (v_now at time zone 'Europe/Warsaw')::time);

    select pg_catalog.count(*) into v_future_blocks
    from public.lane_blocks as lane_block
    where lane_block.lane_id = any(v_affected_ids)
      and lane_block.tenant_id = v_tenant_id
      and lane_block.is_active
      and (lane_block.block_date, lane_block.end_time) >
          ((v_now at time zone 'Europe/Warsaw')::date,
           (v_now at time zone 'Europe/Warsaw')::time);

    select pg_catalog.count(distinct event_record.id) into v_future_events
    from public.events as event_record
    join public.event_lanes as event_lane on event_lane.event_id = event_record.id
    where event_lane.lane_id = any(v_affected_ids)
      and event_lane.tenant_id = v_tenant_id
      and event_record.tenant_id = v_tenant_id
      and event_record.is_active
      and (event_record.event_date, event_record.end_time) >
          ((v_now at time zone 'Europe/Warsaw')::date,
           (v_now at time zone 'Europe/Warsaw')::time);
  end if;

  if not p_acknowledge_future_obligations
     and (v_future_reservations + v_future_blocks + v_future_events) > 0 then
    return pg_catalog.jsonb_build_object(
      'ok', false, 'changed', false, 'code', 'confirmation_required',
      'root_lane_id', p_root_lane_id,
      'previous_version', v_version,
      'configuration_version', v_version,
      'future_reservations_count', v_future_reservations,
      'future_lane_blocks_count', v_future_blocks,
      'future_events_count', v_future_events
    );
  end if;

  begin
    if v_name_only then
      for v_resource in
        select item.value
        from pg_catalog.jsonb_array_elements(v_target) as item(value)
        order by (item.value->>'lane_id')::uuid
      loop
        update public.shooting_lanes
        set name = v_resource.value->>'name'
        where id = (v_resource.value->>'lane_id')::uuid
          and tenant_id = v_tenant_id
          and name is distinct from v_resource.value->>'name';
      end loop;
    else
    for v_resource in
      select item.value
      from pg_catalog.jsonb_array_elements(v_target) as item(value)
      order by (item.value->>'lane_id')::uuid
    loop
      select lane.* into v_lane from public.shooting_lanes as lane
      where lane.id = (v_resource.value->>'lane_id')::uuid
      and lane.tenant_id = v_tenant_id;
      select rule.* into v_rule from public.lane_booking_rules as rule
      where rule.lane_id = v_lane.id;

      if (v_resource.value->>'max_shooters')::integer < v_rule.max_people_online then
        update public.lane_booking_rules
        set online_bookable = (v_resource.value->>'online_bookable')::boolean,
            max_people_online = (v_resource.value->>'max_people_online')::integer
        where lane_id = v_lane.id;
      end if;

      update public.shooting_lanes
      set name = v_resource.value->>'name',
          is_active = (v_resource.value->>'is_active')::boolean,
          whole_lane_bookable = (v_resource.value->>'whole_lane_bookable')::boolean,
          positions_bookable = (v_resource.value->>'positions_bookable')::boolean,
          max_shooters = (v_resource.value->>'max_shooters')::integer
      where id = v_lane.id;

      update public.lane_booking_rules
      set online_bookable = (v_resource.value->>'online_bookable')::boolean,
          max_people_online = (v_resource.value->>'max_people_online')::integer
      where lane_id = v_lane.id;

      delete from public.lane_booking_durations where lane_id = v_lane.id;
      insert into public.lane_booking_durations(
        lane_id, duration_minutes, display_order, is_active
      )
      select v_lane.id, (duration.value #>> '{}')::integer,
             duration.ordinality * 10, true
      from pg_catalog.jsonb_array_elements(v_resource.value->'durations_minutes')
        with ordinality as duration(value, ordinality)
      order by (duration.value #>> '{}')::integer;

      update public.lane_pricing_rules set is_active = false
      where lane_id = v_lane.id and is_active;

      with target_price as (
        select
          price.value->>'day_group' as day_group,
          (price.value->>'min_shooters')::integer as min_shooters,
          (price.value->>'max_shooters')::integer as max_shooters,
          pg_catalog.btrim(price.value->>'label') as label,
          (price.value->>'hourly_price')::numeric(12,2) as hourly_price,
          pg_catalog.row_number() over (
            partition by price.value->>'day_group'
            order by (price.value->>'min_shooters')::integer,
                     (price.value->>'max_shooters')::integer,
                     pg_catalog.btrim(price.value->>'label')
          ) * 10 as display_order
        from pg_catalog.jsonb_array_elements(v_resource.value->'pricing') as price(value)
      ), reusable as (
        select existing.id, target_price.display_order,
               pg_catalog.row_number() over (
                 partition by target_price.day_group, target_price.min_shooters,
                              target_price.max_shooters, target_price.label,
                              target_price.hourly_price
                 order by existing.id
               ) as candidate_order
        from target_price
        join public.lane_pricing_rules as existing
          on existing.lane_id = v_lane.id
         and existing.day_group = target_price.day_group
         and existing.min_shooters = target_price.min_shooters
         and existing.max_shooters = target_price.max_shooters
         and existing.label = target_price.label
         and existing.hourly_price = target_price.hourly_price
      )
      update public.lane_pricing_rules as existing
      set display_order = reusable.display_order, is_active = true
      from reusable
      where existing.id = reusable.id and reusable.candidate_order = 1;

      with target_price as (
        select
          price.value->>'day_group' as day_group,
          (price.value->>'min_shooters')::integer as min_shooters,
          (price.value->>'max_shooters')::integer as max_shooters,
          pg_catalog.btrim(price.value->>'label') as label,
          (price.value->>'hourly_price')::numeric(12,2) as hourly_price,
          pg_catalog.row_number() over (
            partition by price.value->>'day_group'
            order by (price.value->>'min_shooters')::integer,
                     (price.value->>'max_shooters')::integer,
                     pg_catalog.btrim(price.value->>'label')
          ) * 10 as display_order
        from pg_catalog.jsonb_array_elements(v_resource.value->'pricing') as price(value)
      )
      insert into public.lane_pricing_rules(
        lane_id, day_group, min_shooters, max_shooters,
        label, hourly_price, display_order, is_active
      )
      select v_lane.id, target_price.day_group,
             target_price.min_shooters,
             target_price.max_shooters,
             target_price.label,
             target_price.hourly_price,
             target_price.display_order,
             true
      from target_price
      where not exists (
        select 1 from public.lane_pricing_rules as existing
        where existing.lane_id = v_lane.id
          and existing.day_group = target_price.day_group
          and existing.min_shooters = target_price.min_shooters
          and existing.max_shooters = target_price.max_shooters
          and existing.label = target_price.label
          and existing.hourly_price = target_price.hourly_price
          and existing.is_active
      );
    end loop;
    end if;

    update public.lane_booking_family_configuration_versions
    set configuration_version = configuration_version + 1,
        updated_at = v_now
    where root_lane_id = p_root_lane_id
    returning configuration_version into v_version;

    insert into public.audit_logs(
      tenant_id, actor_user_id, actor_name, actor_role, action,
      target_type, target_id, target_name, details
    ) values (
      v_tenant_id, v_actor_id,
      coalesce(
        nullif(pg_catalog.btrim(pg_catalog.concat_ws(' ', v_actor.first_name, v_actor.last_name)), ''),
        nullif(pg_catalog.btrim(v_actor.full_name), ''),
        'Administrator'
      ),
      case when app_private.pa_draft_config_scope_v1(v_tenant_id) then 'platform_admin' else 'admin' end, 'lane_booking_family_configuration_updated',
      'lane_booking_family', p_root_lane_id, v_root_target->>'name',
      pg_catalog.jsonb_build_object(
        'previous_version', p_expected_version,
        'new_version', v_version,
        'before', v_current,
        'after', v_target,
        'renamed_resources', v_renamed_resources
      )
    );
  exception when others then
    raise exception 'Lane family configuration update failed.' using errcode = 'P0001';
  end;

  return pg_catalog.jsonb_build_object(
    'ok', true, 'changed', true, 'code', 'updated',
    'root_lane_id', p_root_lane_id,
    'previous_version', p_expected_version,
    'configuration_version', v_version
  );
end;
$function$
;

-- Existing internal lane business engine; only its explicit draft PA authority/audit branch changes.
CREATE OR REPLACE FUNCTION public.tenant_draft_lane_configuration_core_v1(p_tenant_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
declare
  v_actor_id uuid:=auth.uid();
  v_actor_role text;
  v_tenant_id uuid:=p_tenant_id;
  v_v1 jsonb;
  v_families jsonb;
begin
  if v_actor_id is null or v_tenant_id is null
     or (public.tenant_draft_setup_role_core_v1(v_tenant_id) is distinct from 'admin' and not app_private.pa_draft_config_scope_v1(v_tenant_id)) then
    raise exception 'Lane configuration access is restricted to administrators.'
      using errcode='42501';
  end if;



  if (select pg_catalog.count(*)
      from public.shooting_lanes root
      where root.tenant_id=v_tenant_id
        and root.resource_kind='lane' and root.parent_lane_id is null)
     <>
     (select pg_catalog.count(*)
      from public.lane_booking_family_configuration_versions version
      join public.shooting_lanes root
        on root.id=version.root_lane_id and root.tenant_id=v_tenant_id
      where root.resource_kind='lane' and root.parent_lane_id is null) then
    raise exception 'Lane family version snapshot is incomplete.' using errcode='55000';
  end if;

  v_v1:=public.tenant_draft_lane_resources_core_v1(p_tenant_id);

  select coalesce(pg_catalog.jsonb_agg(
    pg_catalog.jsonb_build_object(
      'root_lane_id',root.id,
      'configuration_version',version.configuration_version,
      'resources',coalesce((
        select pg_catalog.jsonb_agg(resource.value order by resource.ordinality)
        from pg_catalog.jsonb_array_elements(v_v1->'resources') with ordinality
          resource(value,ordinality)
        where resource.value->>'lane_id'=root.id::text
           or resource.value->>'parent_lane_id'=root.id::text
      ),'[]'::jsonb)
    ) order by root.display_order,root.id
  ),'[]'::jsonb)
  into v_families
  from public.shooting_lanes root
  join public.lane_booking_family_configuration_versions version
    on version.root_lane_id=root.id
  where root.tenant_id=v_tenant_id
    and root.resource_kind='lane' and root.parent_lane_id is null;

  return pg_catalog.jsonb_build_object('contract_version',2,'families',v_families);
end;
$function$
;

-- Existing internal lane business engine; only its explicit draft PA authority/audit branch changes.
CREATE OR REPLACE FUNCTION public.tenant_draft_lane_resources_core_v1(p_tenant_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
declare
  v_actor_id uuid:=auth.uid();
  v_actor_role text;
  v_tenant_id uuid:=p_tenant_id;
  v_resources jsonb;
begin
  if v_actor_id is null or v_tenant_id is null
     or (public.tenant_draft_setup_role_core_v1(v_tenant_id) is distinct from 'admin' and not app_private.pa_draft_config_scope_v1(v_tenant_id)) then
    raise exception 'Lane configuration access is restricted to administrators.'
      using errcode='42501';
  end if;



  if exists (
       select 1
       from public.shooting_lanes resource
       left join public.shooting_lanes parent
         on parent.id=resource.parent_lane_id
        and parent.tenant_id=resource.tenant_id
       where resource.tenant_id=v_tenant_id
         and (
           resource.resource_kind not in ('lane','position')
           or resource.parent_lane_id=resource.id
           or (resource.resource_kind='lane' and resource.parent_lane_id is not null)
           or (
             resource.resource_kind='position'
             and (
               resource.parent_lane_id is null
               or resource.whole_lane_bookable
               or resource.positions_bookable
               or parent.id is null
               or parent.resource_kind<>'lane'
               or parent.parent_lane_id is not null
             )
           )
         )
     )
     or exists (
       select 1
       from public.shooting_lanes resource
       left join public.lane_booking_rules booking_rule
         on booking_rule.lane_id=resource.id
       where resource.tenant_id=v_tenant_id
         and booking_rule.lane_id is null
     )
     or exists (
       select 1
       from public.lane_booking_durations duration
       join public.shooting_lanes lane
         on lane.id=duration.lane_id and lane.tenant_id=v_tenant_id
       group by duration.lane_id,duration.duration_minutes
       having pg_catalog.count(*)>1
     )
     or exists (
       select 1
       from public.lane_pricing_rules first_rule
       join public.shooting_lanes lane
         on lane.id=first_rule.lane_id and lane.tenant_id=v_tenant_id
       join public.lane_pricing_rules second_rule
         on second_rule.lane_id=first_rule.lane_id
        and second_rule.day_group=first_rule.day_group
        and second_rule.is_active
        and second_rule.id>first_rule.id
        and second_rule.min_shooters<=first_rule.max_shooters
        and second_rule.max_shooters>=first_rule.min_shooters
       where first_rule.is_active
     ) then
    raise exception 'Lane configuration snapshot is structurally ambiguous.'
      using errcode='55000';
  end if;

  select coalesce(pg_catalog.jsonb_agg(
    pg_catalog.jsonb_build_object(
      'lane_id',resource.lane_id,
      'name',resource.name,
      'resource_kind',resource.resource_kind,
      'parent_lane_id',resource.parent_lane_id,
      'display_order',resource.display_order,
      'is_active',resource.is_active,
      'max_shooters',resource.max_shooters,
      'whole_lane_bookable',resource.whole_lane_bookable,
      'positions_bookable',resource.positions_bookable,
      'booking_step_minutes',resource.booking_step_minutes,
      'currency_code',resource.currency_code,
      'online_bookable',resource.online_bookable,
      'max_people_online',resource.max_people_online,
      'durations',resource.durations,
      'pricing',resource.pricing
    ) order by resource.root_display_order,resource.root_id,
      resource.resource_depth,resource.display_order,resource.lane_id
  ),'[]'::jsonb)
  into v_resources
  from (
    select
      lane.id as lane_id,lane.name,lane.resource_kind,lane.parent_lane_id,
      lane.display_order,lane.is_active,lane.max_shooters,
      lane.whole_lane_bookable,lane.positions_bookable,
      lane.booking_step_minutes,lane.currency_code::text as currency_code,
      booking_rule.online_bookable,booking_rule.max_people_online,
      case when lane.resource_kind='lane' then lane.id else lane.parent_lane_id end as root_id,
      case when lane.resource_kind='lane' then lane.display_order else parent.display_order end as root_display_order,
      case when lane.resource_kind='lane' then 0 else 1 end as resource_depth,
      coalesce((
        select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
          'duration_minutes',duration.duration_minutes,
          'display_order',duration.display_order,
          'is_active',duration.is_active
        ) order by duration.display_order,duration.duration_minutes,duration.id)
        from public.lane_booking_durations duration
        where duration.lane_id=lane.id
      ),'[]'::jsonb) as durations,
      coalesce((
        select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
          'day_group',pricing.day_group,
          'min_shooters',pricing.min_shooters,
          'max_shooters',pricing.max_shooters,
          'label',pricing.label,
          'hourly_price',pricing.hourly_price,
          'display_order',pricing.display_order,
          'is_active',pricing.is_active
        ) order by
          case pricing.day_group when 'mon_thu' then 0 when 'fri_sun' then 1 else 2 end,
          pricing.is_active desc,pricing.display_order,pricing.min_shooters,
          pricing.max_shooters,pricing.id)
        from public.lane_pricing_rules pricing
        where pricing.lane_id=lane.id
      ),'[]'::jsonb) as pricing
    from public.shooting_lanes lane
    join public.lane_booking_rules booking_rule on booking_rule.lane_id=lane.id
    left join public.shooting_lanes parent
      on parent.id=lane.parent_lane_id and parent.tenant_id=lane.tenant_id
    where lane.tenant_id=v_tenant_id
  ) resource;

  return pg_catalog.jsonb_build_object('contract_version',1,'resources',v_resources);
end;
$function$
;

-- Only draft shooting-lane configuration; business booking/events and legacy tenants keep their feature gates.
CREATE OR REPLACE FUNCTION public.enforce_tenant_feature_write_v1()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
declare v_feature text; v_tenant uuid; v_requires boolean:=true;
begin
 if session_user='postgres' and current_setting('app.product10d_test_enforce',true) is distinct from 'on' then return coalesce(new,old); end if;
 v_tenant:=coalesce(new.tenant_id,old.tenant_id);
 if v_tenant is not null then perform 1 from public.tenants where id=v_tenant for share nowait; end if;
 if tg_table_name='tenant_domains' then
  if tg_op<>'DELETE' and new.domain_type='custom_domain' and
   (tg_op='INSERT' or (new.status='active' and old.status is distinct from new.status) or (new.is_primary and not coalesce(old.is_primary,false)))
   and not public.tenant_setup_has_feature_core_v1(v_tenant,'custom_domain') then
   raise exception 'feature_not_available' using errcode='42501'; end if;
  return coalesce(new,old);
 elsif tg_table_name='reservations' then
  if tg_op<>'INSERT' then return new; end if; v_feature:='booking';
 elsif tg_table_name='event_registrations' then
  if tg_op<>'INSERT' then return new; end if; v_feature:='events';
 elsif tg_table_name='events' then
  if tg_op='UPDATE' and new.cancelled_at is not null and old.cancelled_at is null and not new.is_active
   and exists(select 1 from public.tenants where id=v_tenant and (status='archived' or public.tenant_has_restored_history_core_v1(id))) then return new; end if;
  if tg_op='DELETE' or (tg_op='UPDATE' and old.is_active and not new.is_active) then return coalesce(new,old); end if; v_feature:='events';
 elsif tg_table_name='lane_blocks' then
  if tg_op='DELETE' or (tg_op='UPDATE' and not new.is_active) then return coalesce(new,old); end if; v_feature:='lane_blocks';
 elsif tg_table_name='shooting_lanes' then
  if public.tenant_draft_setup_role_core_v1(v_tenant)='admin' or (app_private.pa_draft_config_scope_v1(v_tenant) and exists(select 1 from public.tenants where id=v_tenant and status='dormant')) then return coalesce(new,old); end if;
  if tg_op='DELETE' or (tg_op='UPDATE' and old.is_active and not new.is_active) then return coalesce(new,old); end if; v_feature:='booking';
 else v_requires:=false;
 end if;
 if v_requires and not public.tenant_has_feature_v1(v_tenant,v_feature) then raise exception 'feature_not_available' using errcode='42501'; end if;
 return coalesce(new,old);
end;$function$
;

CREATE OR REPLACE FUNCTION public.platform_get_tenant_delete_eligibility_v1(p_tenant_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
declare
 t public.tenants; catalog jsonb; summary jsonb:='{}'; blockers jsonb;
 is_public_value boolean; catalog_matches boolean;
begin
 if not public.is_platform_admin_v1() then raise exception 'Not authorized' using errcode='42501'; end if;
 select * into t from public.tenants where id=p_tenant_id;
 if not found then raise exception 'TENANT_UNAVAILABLE' using errcode='22023'; end if;
 -- Deliberate policy blocker even for a physically empty synthetic tenant.
 -- This read is not a lock, deletion token, or authorization for future deletion.
 blockers:=jsonb_build_array(jsonb_build_object('code','HARD_DELETE_POLICY_DEFERRED','category','policy','count',1,'hard_blocker',true));
 if t.status<>'archived' then blockers:=blockers||jsonb_build_array(jsonb_build_object('code','TENANT_NOT_ARCHIVED','category','lifecycle','count',1,'hard_blocker',true)); end if;
 select jsonb_build_object(
 'tables',(select jsonb_agg(n.nspname||'.'||c.relname order by n.nspname,c.relname) from pg_class c join pg_namespace n on n.oid=c.relnamespace where (n.nspname='public' or (n.nspname='app_private' and c.relname in ('legal_subjects','legal_actions','legal_acceptances','tenant_public_access_changes','tenant_partner_media','tenant_partner_changes','draft_configuration_requests'))) and c.relkind in('r','p')),
 'columns',(select jsonb_agg(n.nspname||'.'||c.relname||'.'||a.attname||':'||format_type(a.atttypid,a.atttypmod) order by n.nspname,c.relname,a.attnum) from pg_class c join pg_namespace n on n.oid=c.relnamespace join pg_attribute a on a.attrelid=c.oid where (n.nspname='public' or (n.nspname='app_private' and c.relname in ('legal_subjects','legal_actions','legal_acceptances','tenant_public_access_changes','tenant_partner_media','tenant_partner_changes','draft_configuration_requests'))) and c.relkind in('r','p') and a.attnum>0 and not a.attisdropped),
 'foreign_keys',(select jsonb_agg(n.nspname||'.'||c.relname||'.'||k.conname||':'||pg_get_constraintdef(k.oid) order by n.nspname,c.relname,k.conname) from pg_constraint k join pg_class c on c.oid=k.conrelid join pg_namespace n on n.oid=c.relnamespace join pg_class parent on parent.oid=k.confrelid join pg_namespace pn on pn.oid=parent.relnamespace where k.contype='f' and (n.nspname='public' or pn.nspname='public' or (n.nspname='app_private' and c.relname in ('legal_subjects','legal_actions','legal_acceptances','tenant_public_access_changes','tenant_partner_media','tenant_partner_changes','draft_configuration_requests'))))
) into catalog;

 catalog_matches:=md5(catalog::text)='f3695ffd1cd3face088586ea88432fa1';
 if not catalog_matches then
  -- Do not execute stale table/column queries if the catalog contract has changed.
  return jsonb_build_object('tenant',jsonb_build_object('tenant_id',t.id,'name',t.name,'status',t.status),
   'lifecycle',jsonb_build_object('is_archived',t.status='archived','is_public',null),
   'eligibility',jsonb_build_object('can_hard_delete',false,'blocker_count',jsonb_array_length(blockers)+1),
   'blockers',blockers||jsonb_build_array(jsonb_build_object('code','UNKNOWN_DEPENDENCY','category','schema','count',1,'hard_blocker',true)),
   'warnings',jsonb_build_array('DEPENDENCY_COUNTS_UNAVAILABLE'),'dependency_summary',summary);
 end if;
 select coalesce(bool_or(p.is_public),false) into is_public_value from public.tenant_public_profiles p where p.tenant_id=t.id;
 if is_public_value then blockers:=blockers||jsonb_build_array(jsonb_build_object('code','TENANT_PUBLIC','category','lifecycle','count',1,'hard_blocker',true)); end if;
 select jsonb_build_object(
 'draft_configuration_requests',(select count(*) from app_private.draft_configuration_requests where tenant_id=p_tenant_id),
 'tenant_partners',(select count(*) from public.tenant_partners where tenant_id=p_tenant_id),
 'tenant_partner_media',(select count(*) from app_private.tenant_partner_media where tenant_id=p_tenant_id),
 'tenant_partner_changes',(select count(*) from app_private.tenant_partner_changes where tenant_id=p_tenant_id),
 'tenant_public_access_controls',(select count(*) from public.tenant_public_access_controls where tenant_id=p_tenant_id),
 'tenant_public_access_changes',(select count(*) from app_private.tenant_public_access_changes where tenant_id=p_tenant_id),
 'legal_documents',(select count(*) from public.legal_documents d where d.tenant_id=p_tenant_id),
 'legal_document_versions',(select count(*) from public.legal_document_versions v join public.legal_documents d on d.id=v.document_id where d.tenant_id=p_tenant_id),
 'legal_actions',(select count(*) from app_private.legal_actions a where a.tenant_id=p_tenant_id),
 'legal_acceptances',(select count(*) from app_private.legal_acceptances r join app_private.legal_actions a on a.id=r.action_id where a.tenant_id=p_tenant_id),
 'audit_logs',(select count(*) from public.audit_logs x where x.tenant_id=p_tenant_id or x.target_id=p_tenant_id or exists(select 1 from public.reservations r where r.id=x.target_id and r.tenant_id=p_tenant_id) or exists(select 1 from public.event_registrations r where r.id=x.target_id and r.tenant_id=p_tenant_id) or exists(select 1 from public.events e where e.id=x.target_id and e.tenant_id=p_tenant_id) or exists(select 1 from public.shooting_lanes l where l.id=x.target_id and l.tenant_id=p_tenant_id)),
 'email_deliveries',(select count(*) from public.email_deliveries x where x.tenant_id=p_tenant_id or exists(select 1 from public.reservations r where r.id=x.record_id and r.tenant_id=p_tenant_id) or exists(select 1 from public.event_registrations r where r.id=x.record_id and r.tenant_id=p_tenant_id) or exists(select 1 from public.events e where e.id=x.record_id and e.tenant_id=p_tenant_id) or exists(select 1 from public.event_instructors i where i.id=x.record_id and i.tenant_id=p_tenant_id) or exists(select 1 from public.reminder_occurrences o join public.reminder_schedules s on s.id=o.schedule_id where o.id=x.record_id and (exists(select 1 from public.reservations r where r.id=s.reservation_id and r.tenant_id=p_tenant_id) or exists(select 1 from public.events e where e.id=s.event_id and e.tenant_id=p_tenant_id)))),
 'event_instructors',(select count(*) from public.event_instructors x where x.tenant_id=p_tenant_id),
 'event_lanes',(select count(*) from public.event_lanes x where x.tenant_id=p_tenant_id),
 'event_registrations',(select count(*) from public.event_registrations x where x.tenant_id=p_tenant_id),
 'events',(select count(*) from public.events x where x.tenant_id=p_tenant_id),
 'external_settlement_records',(select count(*) from public.external_settlement_records x where x.tenant_id=p_tenant_id),
 'lane_blocks',(select count(*) from public.lane_blocks x where x.tenant_id=p_tenant_id),
 'platform_admin_management_requests',(select count(*) from public.platform_admin_management_requests x where x.tenant_id=p_tenant_id),
 'platform_audit_logs',(select count(*) from public.platform_audit_logs x where x.tenant_id=p_tenant_id),
 'platform_plan_change_requests',(select count(*) from public.platform_plan_change_requests x where x.tenant_id=p_tenant_id),
 'platform_tenant_creation_requests',(select count(*) from public.platform_tenant_creation_requests x where x.tenant_id=p_tenant_id),
 'platform_tenant_lifecycle_requests',(select count(*) from public.platform_tenant_lifecycle_requests x where x.tenant_id=p_tenant_id),
 'reservations',(select count(*) from public.reservations x where x.tenant_id=p_tenant_id),
 'shooting_lanes',(select count(*) from public.shooting_lanes x where x.tenant_id=p_tenant_id),
 'tenant_domains',(select count(*) from public.tenant_domains x where x.tenant_id=p_tenant_id),
 'tenant_memberships',(select count(*) from public.tenant_memberships x where x.tenant_id=p_tenant_id),
 'tenant_plan_assignments',(select count(*) from public.tenant_plan_assignments x where x.tenant_id=p_tenant_id),
 'tenant_public_pricing_items',(select count(*) from public.tenant_public_pricing_items x where x.tenant_id=p_tenant_id),
 'tenant_public_profiles',(select count(*) from public.tenant_public_profiles x where x.tenant_id=p_tenant_id),
 'tenant_user_admin_notes',(select count(*) from public.tenant_user_admin_notes x where x.tenant_id=p_tenant_id),
 'tenant_user_verifications',(select count(*) from public.tenant_user_verifications x where x.tenant_id=p_tenant_id),
 'lane_booking_durations',(select count(*) from public.lane_booking_durations x where exists(select 1 from public.shooting_lanes l where l.id=x.lane_id and l.tenant_id=p_tenant_id)),
 'lane_booking_family_configuration_versions',(select count(*) from public.lane_booking_family_configuration_versions x where exists(select 1 from public.shooting_lanes l where l.id=x.root_lane_id and l.tenant_id=p_tenant_id)),
 'lane_booking_rules',(select count(*) from public.lane_booking_rules x where exists(select 1 from public.shooting_lanes l where l.id=x.lane_id and l.tenant_id=p_tenant_id)),
 'lane_pricing_rules',(select count(*) from public.lane_pricing_rules x where exists(select 1 from public.shooting_lanes l where l.id=x.lane_id and l.tenant_id=p_tenant_id)),
 'reminder_schedules',(select count(*) from public.reminder_schedules x where exists(select 1 from public.reservations r where r.id=x.reservation_id and r.tenant_id=p_tenant_id) or exists(select 1 from public.events e where e.id=x.event_id and e.tenant_id=p_tenant_id)),
 'reminder_occurrences',(select count(*) from public.reminder_occurrences x where exists(select 1 from public.reservations r where r.id=x.reservation_id and r.tenant_id=p_tenant_id) or exists(select 1 from public.event_registrations r where r.id=x.registration_id and r.tenant_id=p_tenant_id) or exists(select 1 from public.reminder_schedules s where s.id=x.schedule_id and (exists(select 1 from public.reservations r where r.id=s.reservation_id and r.tenant_id=p_tenant_id) or exists(select 1 from public.events e where e.id=s.event_id and e.tenant_id=p_tenant_id))))
 ) into summary;
 -- A global profile is not owned by a tenant. Only count related user links.
 summary:=summary||jsonb_build_object('profile_links',(select count(*) from (
  select user_id from public.tenant_memberships where tenant_id=t.id
  union select user_id from public.tenant_user_verifications where tenant_id=t.id
  union select user_id from public.tenant_user_admin_notes where tenant_id=t.id
  union select user_id from public.reservations where tenant_id=t.id
  union select user_id from public.event_registrations where tenant_id=t.id
  union select instructor_user_id from public.event_instructors where tenant_id=t.id
 ) links where user_id is not null));
 select blockers||coalesce(jsonb_agg(jsonb_build_object('code',code,'category',category,'count',(summary->>tab)::bigint,'hard_blocker',true) order by code),'[]'::jsonb) into blockers
 from (values ('draft_configuration_requests','DRAFT_CONFIGURATION_REQUESTS_EXIST','lineage'),('tenant_partners','TENANT_PARTNERS_EXIST','configuration'),('tenant_partner_media','PARTNER_MEDIA_EXISTS','configuration'),('tenant_partner_changes','PARTNER_AUDIT_EXISTS','history'),('tenant_public_access_controls','PUBLIC_ACCESS_CONFIGURATION_EXISTS','configuration'),('tenant_public_access_changes','PUBLIC_ACCESS_AUDIT_EXISTS','history'),('legal_documents','LEGAL_DOCUMENTS_EXIST','history'),('legal_document_versions','LEGAL_VERSIONS_EXIST','history'),('legal_actions','LEGAL_ACTIONS_EXIST','history'),('legal_acceptances','LEGAL_ACCEPTANCES_EXIST','history'),('audit_logs','AUDIT_LOGS_EXIST','history'),
   ('email_deliveries','EMAIL_HISTORY_EXISTS','history'),
   ('event_instructors','EVENT_INSTRUCTORS_EXIST','business'),
   ('event_lanes','EVENT_LANES_EXIST','business'),
   ('event_registrations','EVENT_REGISTRATIONS_EXIST','business'),
   ('events','EVENTS_EXIST','business'),
   ('external_settlement_records','SETTLEMENTS_EXIST','history'),
   ('lane_blocks','LANE_BLOCKS_EXIST','business'),
   ('platform_admin_management_requests','PLATFORM_ADMIN_MANAGEMENT_REQUESTS_EXIST','lineage'),
   ('platform_audit_logs','PLATFORM_AUDIT_EXISTS','history'),
   ('platform_plan_change_requests','PLATFORM_PLAN_CHANGE_REQUESTS_EXIST','lineage'),
   ('platform_tenant_creation_requests','CREATION_LEDGER_EXISTS','lineage'),
   ('platform_tenant_lifecycle_requests','PLATFORM_TENANT_LIFECYCLE_REQUESTS_EXIST','lineage'),
   ('reservations','RESERVATIONS_EXIST','business'),
   ('shooting_lanes','SHOOTING_LANES_EXIST','configuration'),
   ('tenant_domains','CUSTOM_DOMAIN_EXISTS','configuration'),
   ('tenant_memberships','TENANT_MEMBERSHIPS_EXIST','lineage'),
   ('tenant_plan_assignments','PLAN_ASSIGNMENT_EXISTS','lineage'),
   ('tenant_public_pricing_items','TENANT_PUBLIC_PRICING_ITEMS_EXIST','configuration'),
   ('tenant_public_profiles','TENANT_PUBLIC_PROFILES_EXIST','configuration'),
   ('tenant_user_admin_notes','TENANT_USER_ADMIN_NOTES_EXIST','lineage'),
   ('tenant_user_verifications','TENANT_USER_VERIFICATIONS_EXIST','lineage'),
   ('lane_booking_durations','LANE_BOOKING_DURATIONS_EXIST','configuration'),
   ('lane_booking_family_configuration_versions','LANE_BOOKING_FAMILY_CONFIGURATION_VERSIONS_EXIST','configuration'),
   ('lane_booking_rules','LANE_BOOKING_RULES_EXIST','configuration'),
   ('lane_pricing_rules','LANE_PRICING_RULES_EXIST','configuration'),
   ('reminder_schedules','REMINDER_SCHEDULES_EXIST','history'),
   ('reminder_occurrences','REMINDER_HISTORY_EXISTS','history'),('profile_links','TENANT_PROFILE_LINKS_EXIST','lineage')) c(tab,code,category)
 where (summary->>tab)::bigint>0;
 return jsonb_build_object('tenant',jsonb_build_object('tenant_id',t.id,'name',t.name,'status',t.status),
  'lifecycle',jsonb_build_object('is_archived',t.status='archived','is_public',is_public_value),
  'eligibility',jsonb_build_object('can_hard_delete',false,'blocker_count',jsonb_array_length(blockers)),
  'blockers',blockers,'warnings',jsonb_build_array('GLOBAL_ACCOUNTS_NOT_TENANT_OWNED','SNAPSHOT_ONLY_NOT_DELETE_AUTHORIZATION'),
  'dependency_summary',summary);
end;
$function$
;
