-- PRODUCT-10F: host is a public selector, never tenant authority.
set lock_timeout='5s';
set statement_timeout='60s';
create table public.tenant_domains (
 id uuid primary key default gen_random_uuid(),
 tenant_id uuid not null references public.tenants(id),
 hostname text not null unique,
 domain_type text not null check(domain_type in('custom_domain','platform_subdomain')),
 status text not null default 'pending' check(status in('pending','verified','active','disabled')),
 is_primary boolean not null default false,
 verification_hash text,
 verification_version integer not null default 0,
 verification_expires_at timestamptz,
 verification_requested_by uuid references auth.users(id),
 verified_at timestamptz,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 check(hostname=lower(hostname) and length(hostname)<=253 and hostname ~ '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'),
 check(hostname !~ '(^|\.)xn--' and hostname !~ '^[0-9.]+$'),
 check(hostname !~ '(^|\.)strzelajtu\.pl$' and hostname !~ '(^|\.)vercel\.app$'),
 check(not is_primary or status='active'),
 check(status not in('verified','active') or verified_at is not null)
);
create unique index tenant_domains_primary_key on public.tenant_domains(tenant_id) where is_primary;
alter table public.tenant_domains enable row level security;
revoke all on public.tenant_domains from public,anon,authenticated,service_role;

alter table public.platform_audit_logs drop constraint platform_audit_logs_action_check;
alter table public.platform_audit_logs add constraint platform_audit_logs_action_check check(action in(
 'tenant_created','plan_assigned','plan_changed','tenant_admin_assigned','tenant_activated','tenant_suspended','tenant_published','tenant_unpublished','platform_admin_bootstrapped',
 'domain_added','domain_verification_started','domain_verified','domain_activated','domain_disabled','primary_domain_changed'));

create function public.platform_manage_tenant_domain_v1(p_tenant_id uuid,p_action text,p_domain_id uuid default null,p_hostname text default null)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,auth,extensions,pg_temp as $$
declare d public.tenant_domains; token text; result jsonb; action_name text;
begin
 if not public.is_platform_admin_v1() then raise exception 'Forbidden' using errcode='42501'; end if;
 perform 1 from public.tenants where id=p_tenant_id for update;
 if not found then raise exception 'Unavailable' using errcode='42501'; end if;
 if p_action='add' then
  if p_domain_id is not null or p_hostname is null or p_hostname<>btrim(p_hostname) or exists(select 1 from unnest(string_to_array(p_hostname,'.')) l where length(l)>63) then raise exception 'Invalid hostname' using errcode='22023'; end if;
  insert into public.tenant_domains(tenant_id,hostname,domain_type) values(p_tenant_id,lower(p_hostname),'custom_domain') returning * into d;
  action_name:='domain_added';
 else
  select * into d from public.tenant_domains where id=p_domain_id and tenant_id=p_tenant_id for update;
  if not found then raise exception 'Unavailable' using errcode='42501'; end if;
  if p_action='start_verification' then
   if d.status='active' then raise exception 'Disable before reverification' using errcode='22023'; end if;
   token:=encode(extensions.gen_random_bytes(32),'hex');
   update public.tenant_domains set status='pending',is_primary=false,verified_at=null,
    verification_hash=encode(extensions.digest(token,'sha256'),'hex'),verification_version=verification_version+1,
    verification_expires_at=now()+interval '24 hours',verification_requested_by=auth.uid(),updated_at=now() where id=d.id returning * into d;
   action_name:='domain_verification_started';
  elsif p_action='activate' then
   if d.status<>'verified' or d.verified_at is null or d.verification_expires_at<=now() then raise exception 'Verification required' using errcode='42501'; end if;
   update public.tenant_domains set status='active',updated_at=now() where id=d.id returning * into d;
   action_name:='domain_activated';
  elsif p_action='disable' then
   update public.tenant_domains set status='disabled',is_primary=false,verification_hash=null,updated_at=now() where id=d.id returning * into d;
   action_name:='domain_disabled';
  elsif p_action='set_primary' then
   if d.status<>'active' then raise exception 'Active domain required' using errcode='42501'; end if;
   update public.tenant_domains set is_primary=false,updated_at=now() where tenant_id=p_tenant_id and is_primary;
   update public.tenant_domains set is_primary=true,updated_at=now() where id=d.id returning * into d;
   action_name:='primary_domain_changed';
  else raise exception 'Invalid action' using errcode='22023'; end if;
 end if;
 insert into public.platform_audit_logs(actor_user_id,tenant_id,action,details) values(auth.uid(),p_tenant_id,action_name,jsonb_build_object('domain_id',d.id,'hostname',d.hostname));
 result:=jsonb_build_object('id',d.id,'hostname',d.hostname,'status',d.status,'is_primary',d.is_primary,'verification_version',d.verification_version);
 if token is not null then result:=result||jsonb_build_object('txt_name','_strzelajtu-verification.'||d.hostname,'txt_value',token); end if;
 return result;
end;$$;

create function public.platform_list_tenant_domains_v1(p_tenant_id uuid) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public,pg_temp as $$
begin
 if not public.is_platform_admin_v1() then raise exception 'Forbidden' using errcode='42501'; end if;
 return (select coalesce(jsonb_agg(jsonb_build_object('id',id,'hostname',hostname,'status',status,'is_primary',is_primary,'verified_at',verified_at) order by hostname),'[]'::jsonb) from public.tenant_domains where tenant_id=p_tenant_id);
end;$$;

-- Trusted operator attests actual TXT + provider/TLS verification. Never callable by UI/service_role.
create function public.operator_verify_tenant_domain_v1(p_domain_id uuid,p_version integer,p_txt_value text,p_provider_project text,p_tls_ready boolean)
returns void language plpgsql security invoker set search_path=pg_catalog,public,extensions,pg_temp as $$
declare d public.tenant_domains;
begin
 if current_user<>'postgres' or coalesce(current_setting('request.jwt.claims',true),'') not in('','{}') then raise exception 'Operator only' using errcode='42501'; end if;
 if p_provider_project is distinct from 'csk-booking-5nwh' or p_tls_ready is distinct from true then raise exception 'Provider verification required' using errcode='42501'; end if;
 select * into d from public.tenant_domains where id=p_domain_id;
 perform 1 from public.tenants where id=d.tenant_id for update;
 select * into d from public.tenant_domains where id=p_domain_id for update;
 if not found or d.status<>'pending' or d.verification_version is distinct from p_version or d.verification_expires_at is null or d.verification_expires_at<=now() or d.verification_hash is null or d.verification_hash is distinct from encode(extensions.digest(p_txt_value,'sha256'),'hex') then raise exception 'Verification rejected' using errcode='42501'; end if;
 if not exists(select 1 from public.platform_admins where user_id=d.verification_requested_by and status='active') then raise exception 'Requester inactive' using errcode='42501'; end if;
 update public.tenant_domains set status='verified',verified_at=now(),updated_at=now(),verification_hash=null where id=d.id;
 insert into public.platform_audit_logs(actor_user_id,tenant_id,action,details) values(d.verification_requested_by,d.tenant_id,'domain_verified',jsonb_build_object('domain_id',d.id,'operator',current_user,'provider_project',p_provider_project,'verification_version',p_version));
end;$$;

create function public.resolve_public_tenant_domain_v1(p_hostname text) returns jsonb
language sql stable security definer set search_path=pg_catalog,public,pg_temp as $$
 select jsonb_build_object('tenant_slug',t.slug,'public_slug',p.public_slug)
 from public.tenant_domains d join public.tenants t on t.id=d.tenant_id join public.tenant_public_profiles p on p.tenant_id=t.id
 where d.hostname=p_hostname and d.status='active' and d.verified_at is not null and t.status='active' and p.is_public;
$$;
create function public.get_public_tenant_primary_domain_v1(p_public_slug text) returns text
language sql stable security definer set search_path=pg_catalog,public,pg_temp as $$
 select d.hostname from public.tenant_public_profiles p join public.tenants t on t.id=p.tenant_id join public.tenant_domains d on d.tenant_id=t.id
 where p.public_slug=p_public_slug and p.is_public and t.status='active' and d.status='active' and d.is_primary and d.verified_at is not null;
$$;
revoke all on function public.platform_manage_tenant_domain_v1(uuid,text,uuid,text),public.platform_list_tenant_domains_v1(uuid),public.operator_verify_tenant_domain_v1(uuid,integer,text,text,boolean),public.resolve_public_tenant_domain_v1(text),public.get_public_tenant_primary_domain_v1(text) from public,anon,authenticated,service_role;
grant execute on function public.platform_manage_tenant_domain_v1(uuid,text,uuid,text),public.platform_list_tenant_domains_v1(uuid) to authenticated;
grant execute on function public.resolve_public_tenant_domain_v1(text),public.get_public_tenant_primary_domain_v1(text) to anon,authenticated;
