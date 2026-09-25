-- Public display prices are informational, separate from operational booking prices.
set lock_timeout='5s';
set statement_timeout='60s';

alter table public.tenant_public_profiles
  add column about_offer text check (about_offer is null or (length(about_offer) between 1 and 1200 and about_offer=btrim(about_offer))),
  add column about_audience text check (about_audience is null or (length(about_audience) between 1 and 1200 and about_audience=btrim(about_audience))),
  add column public_map_url text check (public_map_url is null or (length(public_map_url)<=500 and public_map_url ~ '^https://[^[:space:]]+$'));

create table public.tenant_public_pricing_items (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id),
  title text not null check (length(title) between 1 and 120 and title=btrim(title)),
  price numeric not null check (price>=0 and price<=9999999.99 and price=round(price,2) and price::text not in ('NaN','Infinity','-Infinity')),
  currency text not null check (currency ~ '^[A-Z]{3}$'),
  unit text not null check (length(unit) between 1 and 80 and unit=btrim(unit)),
  short_description text check (short_description is null or (length(short_description)<=300 and short_description=btrim(short_description))),
  display_order integer not null check (display_order between 0 and 9999),
  is_active boolean not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index tenant_public_pricing_order_idx on public.tenant_public_pricing_items(tenant_id,display_order,id);
alter table public.tenant_public_pricing_items enable row level security;
revoke all on public.tenant_public_pricing_items from public,anon,authenticated,service_role;
create trigger tenant_public_pricing_updated_at before update on public.tenant_public_pricing_items for each row execute function public.set_updated_at();

do $audit$
declare definition text;
begin
 definition:=replace(replace(pg_get_functiondef('public.set_audit_log_tenant_id()'::regprocedure),chr(13)||chr(10),chr(10)),chr(13),chr(10));
 if md5(definition)<>'7695b54796226d5e95d1594692a5f891' then raise exception 'content audit input drift'; end if;
 definition:=replace(definition,'new.action is distinct from ''tenant_public_profile_updated''',
 'new.action not in (''tenant_public_profile_updated'',''public_about_updated'',''public_contact_updated'')');
 definition:=replace(definition,'    when ''tenant_public_profile'' then',
 '    when ''tenant_public_pricing_item'' then
      if new.action not in (''pricing_item_created'',''pricing_item_updated'',''pricing_item_disabled'',''pricing_order_changed'') then raise exception ''invalid_pricing_audit''; end if;
      select item.tenant_id into v_tenant_id from public.tenant_public_pricing_items item where item.id=new.target_id;
    when ''tenant_public_profile'' then');
 execute definition;
end;$audit$;

create function public.admin_get_tenant_content_v1(p_tenant_slug text)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public,auth,pg_temp as $$
declare settings jsonb; tid uuid; profile public.tenant_public_profiles%rowtype; items jsonb;
begin
 settings:=public.admin_get_tenant_public_settings_v1(p_tenant_slug);
 select id into tid from public.tenants where slug=p_tenant_slug;
 select * into profile from public.tenant_public_profiles where tenant_id=tid;
 select coalesce(jsonb_agg(jsonb_build_object('id',id,'title',title,'price',price,'currency',currency,'unit',unit,
 'short_description',short_description,'display_order',display_order,'is_active',is_active) order by display_order,id),'[]'::jsonb)
 into items from public.tenant_public_pricing_items where tenant_id=tid;
 return settings||jsonb_build_object('about_offer',profile.about_offer,'about_audience',profile.about_audience,'public_map_url',profile.public_map_url,'pricing_items',items);
end;$$;

create function public.admin_update_tenant_content_v1(p_tenant_slug text,p_settings jsonb,p_content jsonb,p_expected_updated_at timestamptz)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,auth,pg_temp as $$
declare tid uuid; before_profile public.tenant_public_profiles%rowtype; item jsonb; old_item public.tenant_public_pricing_items%rowtype;
 iid uuid; seen uuid[]:=array[]::uuid[]; changed text[]; action_name text;
begin
 -- Reuse the exact active membership/admin + lifecycle + optimistic concurrency contract.
 perform public.admin_get_tenant_public_settings_v1(p_tenant_slug);
 select id into tid from public.tenants where slug=p_tenant_slug;
 select * into before_profile from public.tenant_public_profiles where tenant_id=tid for update;
 if p_content is null or jsonb_typeof(p_content)<>'object'
 or (select array_agg(key order by key) from jsonb_object_keys(p_content) key) is distinct from array['about_audience','about_offer','pricing_items','public_map_url']::text[]
 or jsonb_typeof(p_content->'pricing_items')<>'array' or jsonb_array_length(p_content->'pricing_items')>100
 or exists(select 1 from jsonb_each(p_content) e where key<>'pricing_items' and jsonb_typeof(value) not in ('string','null')) then
 raise exception 'invalid_content_payload' using errcode='22023'; end if;
 perform public.admin_update_tenant_public_settings_v1(p_tenant_slug,p_settings,p_expected_updated_at);
 update public.tenant_public_profiles set about_offer=nullif(btrim(p_content->>'about_offer'),''),
 about_audience=nullif(btrim(p_content->>'about_audience'),''),public_map_url=nullif(btrim(p_content->>'public_map_url'),'') where tenant_id=tid;
 select array_agg(key order by key) into changed from unnest(array['description','about_offer','about_audience']) key
 where to_jsonb(before_profile)->key is distinct from (select to_jsonb(p)->key from public.tenant_public_profiles p where tenant_id=tid);
 if changed is not null then insert into public.audit_logs(tenant_id,actor_user_id,actor_role,action,target_type,target_id,details)
 values(tid,auth.uid(),'admin','public_about_updated','tenant_public_profile',tid,jsonb_build_object('changed_fields',changed)); end if;
 select array_agg(key order by key) into changed from unnest(array['city','public_address','public_phone','public_email','opening_hours','social_links','public_map_url']) key
 where to_jsonb(before_profile)->key is distinct from (select to_jsonb(p)->key from public.tenant_public_profiles p where tenant_id=tid);
 if changed is not null then insert into public.audit_logs(tenant_id,actor_user_id,actor_role,action,target_type,target_id,details)
 values(tid,auth.uid(),'admin','public_contact_updated','tenant_public_profile',tid,jsonb_build_object('changed_fields',changed)); end if;
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
   values(tid,auth.uid(),'admin',action_name,'tenant_public_pricing_item',iid,jsonb_build_object('changed_fields',changed));
   if old_item.id is not null and old_item.display_order<>(item->>'display_order')::integer then
    insert into public.audit_logs(tenant_id,actor_user_id,actor_role,action,target_type,target_id,details)
    values(tid,auth.uid(),'admin','pricing_order_changed','tenant_public_pricing_item',iid,jsonb_build_object('changed_fields',array['display_order']));
   end if;
  end if;
 end loop;
 if exists(select 1 from public.tenant_public_pricing_items where tenant_id=tid and not(id=any(seen))) then
  raise exception 'pricing_items_must_be_disabled_not_deleted' using errcode='22023'; end if;
 return public.admin_get_tenant_content_v1(p_tenant_slug);
end;$$;

create function public.get_public_tenant_content_v1(p_public_slug text)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public,pg_temp as $$
declare profile public.tenant_public_profiles%rowtype; flags record; result jsonb;
begin
 select * into flags from public.get_public_tenant_landing_v2(p_public_slug);
 if not found or flags.public_slug is distinct from p_public_slug then return null; end if;
 select p.* into profile from public.tenant_public_profiles p join public.tenants t on t.id=p.tenant_id where p.public_slug=p_public_slug and p.is_public and t.status='active';
 if not found then return null; end if;
 return jsonb_build_object('about_offer',case when flags.show_about then profile.about_offer end,
 'about_audience',case when flags.show_about then profile.about_audience end,
 'public_map_url',case when flags.show_contact then profile.public_map_url end,
 'pricing_items',case when flags.show_pricing then (select coalesce(jsonb_agg(jsonb_build_object('title',title,'price',price,'currency',currency,'unit',unit,'short_description',short_description) order by display_order,id),'[]'::jsonb)
 from public.tenant_public_pricing_items where tenant_id=profile.tenant_id and is_active) else '[]'::jsonb end);
end;$$;

alter function public.admin_get_tenant_content_v1(text) owner to postgres;
alter function public.admin_update_tenant_content_v1(text,jsonb,jsonb,timestamptz) owner to postgres;
alter function public.get_public_tenant_content_v1(text) owner to postgres;
revoke all on function public.admin_get_tenant_content_v1(text),public.admin_update_tenant_content_v1(text,jsonb,jsonb,timestamptz),public.get_public_tenant_content_v1(text) from public,anon,authenticated,service_role;
grant execute on function public.admin_get_tenant_content_v1(text),public.admin_update_tenant_content_v1(text,jsonb,jsonb,timestamptz) to authenticated;
grant execute on function public.get_public_tenant_content_v1(text) to anon,authenticated;
