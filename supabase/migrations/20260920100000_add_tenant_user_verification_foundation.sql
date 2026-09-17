-- SAAS-9D-4B-2A: tenant-scoped verification storage and deterministic CSK backfill.
-- Application readers/writers and legacy profile verification fields remain unchanged.

begin;

set lock_timeout = '5s';
set statement_timeout = '120s';

do $preflight$
declare
  v_tenant_id uuid;
begin
  if pg_catalog.to_regclass('public.tenant_user_verifications') is not null
     or pg_catalog.to_regprocedure('public._backfill_csk_tenant_user_verifications_v1()') is not null then
    raise exception 'SAAS-9D-4B-2A preflight failed: target object already exists.';
  end if;

  if pg_catalog.to_regprocedure('public.active_single_tenant_id_v1()') is null
     or pg_catalog.to_regprocedure('public.update_profile_verification(uuid,text,text)') is null
     or pg_catalog.to_regprocedure('public.prevent_non_admin_profile_privilege_changes()') is null then
    raise exception 'SAAS-9D-4B-2A preflight failed: required frozen function is absent.';
  end if;

  select public.active_single_tenant_id_v1() into v_tenant_id;
  if v_tenant_id is null
     or (select pg_catalog.count(*) from public.tenants where status='active')<>1
     or not exists(select 1 from public.tenants where id=v_tenant_id and slug='csk' and status='active') then
    raise exception 'SAAS-9D-4B-2A preflight failed: exact active CSK tenant is required.';
  end if;

  if pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(
       pg_catalog.pg_get_functiondef('public.update_profile_verification(uuid,text,text)'::regprocedure),
       E'\r\n',E'\n'),E'\r',E'\n'))<>'a0522b6beb94bde3bdff22799afc1368'
     or pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(
       pg_catalog.pg_get_functiondef('public.prevent_non_admin_profile_privilege_changes()'::regprocedure),
       E'\r\n',E'\n'),E'\r',E'\n'))<>'d28cb697d8355a5e8005296a03ad63ea' then
    raise exception 'SAAS-9D-4B-2A preflight failed: frozen writer/trigger fingerprint drift.';
  end if;

  if exists(
    select 1 from public.profiles profile
    where pg_catalog.lower(pg_catalog.btrim(coalesce(profile.verification_status,'niezweryfikowane')))
          not in('niezweryfikowane','pending','verified','rejected')
  ) then
    raise exception 'SAAS-9D-4B-2A preflight failed: unsupported legacy verification status.';
  end if;

  if (select pg_catalog.count(*) from pg_catalog.pg_proc procedure
      join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace
      where namespace.nspname='public' and procedure.prosecdef)<>67 then
    raise exception 'SAAS-9D-4B-2A preflight failed: SECURITY DEFINER baseline is not 67.';
  end if;

  if (select pg_catalog.count(*) from information_schema.columns
      where table_schema='public'
        and table_name in('shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','email_deliveries')
        and column_name='tenant_id'
        and column_default='''c5c00000-0000-4000-8000-000000000001''::uuid')<>7 then
    raise exception 'SAAS-9D-4B-2A preflight failed: compatibility defaults differ.';
  end if;
end;
$preflight$;

create temporary table saas9d4b2a_frozen_functions on commit drop as
select procedure.oid::regprocedure::text signature,
       pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(
         pg_catalog.pg_get_functiondef(procedure.oid),E'\r\n',E'\n'
       ),E'\r',E'\n')) fingerprint,
       procedure.prosecdef,procedure.proowner,procedure.proconfig,procedure.proacl
from pg_catalog.pg_proc procedure
join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace
where namespace.nspname='public'
  and procedure.oid in(
    'public.update_profile_verification(uuid,text,text)'::regprocedure,
    'public.prevent_non_admin_profile_privilege_changes()'::regprocedure,
    'public.admin_list_users_v1(integer,integer,text,text,text,text)'::regprocedure,
    'public.get_reservation_customer_profiles_v1(uuid[])'::regprocedure
  );

create table public.tenant_user_verifications(
  tenant_id uuid not null,
  user_id uuid not null,
  verification_status text default 'pending'::text not null,
  permissions_verified boolean default false not null,
  permissions_verified_at timestamp with time zone,
  permissions_verified_by uuid,
  permissions_verification_note text,
  verified_at timestamp with time zone,
  verified_by uuid,
  unverified_at timestamp with time zone,
  unverified_by uuid,
  updated_at timestamp with time zone default pg_catalog.transaction_timestamp() not null,
  constraint tenant_user_verifications_pkey primary key(tenant_id,user_id),
  constraint tenant_user_verifications_tenant_fkey foreign key(tenant_id)
    references public.tenants(id) on delete cascade,
  constraint tenant_user_verifications_user_fkey foreign key(user_id)
    references auth.users(id) on delete cascade,
  constraint tenant_user_verifications_permissions_verified_by_fkey foreign key(permissions_verified_by)
    references auth.users(id) on delete set null,
  constraint tenant_user_verifications_verified_by_fkey foreign key(verified_by)
    references auth.users(id) on delete set null,
  constraint tenant_user_verifications_unverified_by_fkey foreign key(unverified_by)
    references auth.users(id) on delete set null,
  constraint tenant_user_verifications_status_check check(
    verification_status in('pending','verified','rejected')
  ),
  constraint tenant_user_verifications_verified_state_check check(
    not permissions_verified or verification_status='verified'
  ),
  constraint tenant_user_verifications_note_length_check check(
    permissions_verification_note is null
    or pg_catalog.char_length(permissions_verification_note)<=2000
  )
);

alter table public.tenant_user_verifications owner to postgres;
alter table public.tenant_user_verifications enable row level security;

comment on table public.tenant_user_verifications is
  'Tenant-scoped operational verification state. Direct client and runtime service access is denied; 4B-2B will add controlled resource-bound readers/writers.';
comment on column public.tenant_user_verifications.permissions_verification_note is
  'Tenant staff verification note. Sensitive operational data; never a public or cross-tenant field.';

create index tenant_user_verifications_user_tenant_idx
  on public.tenant_user_verifications(user_id,tenant_id);

revoke all privileges on table public.tenant_user_verifications
  from public,anon,authenticated,service_role;

create or replace function public._backfill_csk_tenant_user_verifications_v1()
returns bigint
language plpgsql
security invoker
set search_path=pg_catalog,public,pg_temp
as $function$
declare
  v_tenant_id uuid:=public.active_single_tenant_id_v1();
  v_unrelated bigint;
  v_ambiguous bigint;
  v_wrong_tenant bigint;
  v_unresolved_actor bigint;
  v_inserted bigint;
begin
  if v_tenant_id is null
     or (select pg_catalog.count(*) from public.tenants where status='active')<>1
     or not exists(select 1 from public.tenants where id=v_tenant_id and slug='csk' and status='active') then
    raise exception using errcode='23514',message='tenant_verification_backfill_requires_exact_active_csk';
  end if;

  with relation_tenants as(
    select membership.user_id,membership.tenant_id from public.tenant_memberships membership
    union
    select reservation.user_id,reservation.tenant_id from public.reservations reservation where reservation.user_id is not null
    union
    select registration.user_id,registration.tenant_id
    from public.event_registrations registration
    join public.events event_record on event_record.id=registration.event_id and event_record.tenant_id=registration.tenant_id
    where registration.user_id is not null
  ), meaningful as(
    select profile.user_id
    from public.profiles profile
    where pg_catalog.lower(pg_catalog.btrim(coalesce(profile.verification_status,'niezweryfikowane')))
            not in('niezweryfikowane','pending')
       or profile.permissions_verified
       or profile.permissions_verified_at is not null
       or profile.permissions_verified_by is not null
       or profile.permissions_verification_note is not null
       or profile.verified_at is not null
       or profile.verified_by is not null
       or profile.unverified_at is not null
       or profile.unverified_by is not null
  ), classified as(
    select meaningful.user_id,pg_catalog.count(distinct relation.tenant_id) tenant_count,
           pg_catalog.min(relation.tenant_id::text)::uuid only_tenant
    from meaningful left join relation_tenants relation on relation.user_id=meaningful.user_id
    group by meaningful.user_id
  )
  select pg_catalog.count(*) filter(where tenant_count=0),
         pg_catalog.count(*) filter(where tenant_count>1),
         pg_catalog.count(*) filter(where tenant_count=1 and only_tenant is distinct from v_tenant_id)
  into v_unrelated,v_ambiguous,v_wrong_tenant
  from classified;

  if v_unrelated<>0 or v_ambiguous<>0 or v_wrong_tenant<>0 then
    raise exception using errcode='23514',
      message=pg_catalog.format('tenant_verification_backfill_not_deterministic unrelated=%s ambiguous=%s wrong_tenant=%s',v_unrelated,v_ambiguous,v_wrong_tenant);
  end if;

  select pg_catalog.count(*) into v_unresolved_actor
  from public.profiles profile
  where exists(
    select 1 from public.tenant_memberships membership where membership.tenant_id=v_tenant_id and membership.user_id=profile.user_id
    union all
    select 1 from public.reservations reservation where reservation.tenant_id=v_tenant_id and reservation.user_id=profile.user_id
    union all
    select 1 from public.event_registrations registration
      join public.events event_record on event_record.id=registration.event_id and event_record.tenant_id=registration.tenant_id
      where registration.tenant_id=v_tenant_id and registration.user_id=profile.user_id
  ) and (
    profile.verified_by is not null and not exists(select 1 from auth.users actor where actor.id=profile.verified_by)
      and not exists(select 1 from public.profiles actor where actor.id=profile.verified_by)
    or profile.permissions_verified_by is not null and not exists(select 1 from auth.users actor where actor.id=profile.permissions_verified_by)
      and not exists(select 1 from public.profiles actor where actor.id=profile.permissions_verified_by)
    or profile.unverified_by is not null and (
      profile.unverified_by !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
      or not exists(select 1 from auth.users actor where actor.id=profile.unverified_by::uuid)
         and not exists(select 1 from public.profiles actor where actor.id=profile.unverified_by::uuid)
    )
  );
  if v_unresolved_actor<>0 then
    raise exception using errcode='23514',message='tenant_verification_backfill_unresolved_actor';
  end if;

  insert into public.tenant_user_verifications(
    tenant_id,user_id,verification_status,permissions_verified,
    permissions_verified_at,permissions_verified_by,permissions_verification_note,
    verified_at,verified_by,unverified_at,unverified_by,updated_at
  )
  select v_tenant_id,profile.user_id,
    case pg_catalog.lower(pg_catalog.btrim(coalesce(profile.verification_status,'niezweryfikowane')))
      when 'verified' then 'verified' when 'rejected' then 'rejected' else 'pending' end,
    profile.permissions_verified,profile.permissions_verified_at,
    coalesce(permission_actor.user_id,permission_auth.id),
    profile.permissions_verification_note,profile.verified_at,
    coalesce(verified_actor.user_id,verified_auth.id),profile.unverified_at,
    coalesce(unverified_actor.user_id,unverified_auth.id),
    coalesce(profile.updated_at,pg_catalog.transaction_timestamp())
  from public.profiles profile
  left join public.profiles permission_actor on permission_actor.id=profile.permissions_verified_by
  left join auth.users permission_auth on permission_auth.id=profile.permissions_verified_by
  left join public.profiles verified_actor on verified_actor.id=profile.verified_by
  left join auth.users verified_auth on verified_auth.id=profile.verified_by
  left join public.profiles unverified_actor on unverified_actor.id=case
    when profile.unverified_by~*'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' then profile.unverified_by::uuid end
  left join auth.users unverified_auth on unverified_auth.id=case
    when profile.unverified_by~*'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' then profile.unverified_by::uuid end
  where exists(
    select 1 from public.tenant_memberships membership where membership.tenant_id=v_tenant_id and membership.user_id=profile.user_id
    union all
    select 1 from public.reservations reservation where reservation.tenant_id=v_tenant_id and reservation.user_id=profile.user_id
    union all
    select 1 from public.event_registrations registration
      join public.events event_record on event_record.id=registration.event_id and event_record.tenant_id=registration.tenant_id
      where registration.tenant_id=v_tenant_id and registration.user_id=profile.user_id
  )
  on conflict(tenant_id,user_id) do nothing;

  get diagnostics v_inserted=row_count;
  return v_inserted;
end;
$function$;

alter function public._backfill_csk_tenant_user_verifications_v1() owner to postgres;
revoke all on function public._backfill_csk_tenant_user_verifications_v1()
  from public,anon,authenticated,service_role;

select public._backfill_csk_tenant_user_verifications_v1();

do $postflight$
declare
  v_snapshot record;
begin
  if not exists(
    select 1 from pg_catalog.pg_class relation
    join pg_catalog.pg_namespace namespace on namespace.oid=relation.relnamespace
    where namespace.nspname='public' and relation.relname='tenant_user_verifications'
      and relation.relrowsecurity
  ) or exists(
    select 1 from pg_catalog.pg_policy policy
    where policy.polrelid='public.tenant_user_verifications'::regclass
  ) then
    raise exception 'SAAS-9D-4B-2A postflight failed: RLS is not fail-closed.';
  end if;

  if pg_catalog.has_table_privilege('anon','public.tenant_user_verifications','SELECT,INSERT,UPDATE,DELETE')
     or pg_catalog.has_table_privilege('authenticated','public.tenant_user_verifications','SELECT,INSERT,UPDATE,DELETE')
     or pg_catalog.has_table_privilege('service_role','public.tenant_user_verifications','SELECT,INSERT,UPDATE,DELETE')
     or pg_catalog.has_function_privilege('anon','public._backfill_csk_tenant_user_verifications_v1()','EXECUTE')
     or pg_catalog.has_function_privilege('authenticated','public._backfill_csk_tenant_user_verifications_v1()','EXECUTE')
     or pg_catalog.has_function_privilege('service_role','public._backfill_csk_tenant_user_verifications_v1()','EXECUTE') then
    raise exception 'SAAS-9D-4B-2A postflight failed: direct access is not closed.';
  end if;

  for v_snapshot in select * from saas9d4b2a_frozen_functions loop
    if not exists(
      select 1 from pg_catalog.pg_proc procedure
      where procedure.oid=pg_catalog.to_regprocedure(v_snapshot.signature)
        and pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef(procedure.oid),E'\r\n',E'\n'),E'\r',E'\n'))=v_snapshot.fingerprint
        and procedure.prosecdef=v_snapshot.prosecdef
        and procedure.proowner=v_snapshot.proowner
        and procedure.proconfig is not distinct from v_snapshot.proconfig
        and procedure.proacl is not distinct from v_snapshot.proacl
    ) then
      raise exception 'SAAS-9D-4B-2A postflight failed: frozen function % drifted.',v_snapshot.signature;
    end if;
  end loop;

  if (select pg_catalog.count(*) from pg_catalog.pg_proc procedure
      join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace
      where namespace.nspname='public' and procedure.prosecdef)<>67
     or (select pg_catalog.count(*) from information_schema.columns
         where table_schema='public'
           and table_name in('shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','email_deliveries')
           and column_name='tenant_id'
           and column_default='''c5c00000-0000-4000-8000-000000000001''::uuid')<>7 then
    raise exception 'SAAS-9D-4B-2A postflight failed: security inventory/defaults drift.';
  end if;
end;
$postflight$;

reset statement_timeout;
reset lock_timeout;

commit;
