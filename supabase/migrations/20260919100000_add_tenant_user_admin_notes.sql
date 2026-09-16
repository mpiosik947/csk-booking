-- SAAS-9D-4B-1A: tenant-scoped user admin notes and note/list cutover.
-- Role, identity, contact, verification and account-lifecycle RPCs are out of scope.

begin;

set lock_timeout = '5s';
set statement_timeout = '120s';

do $preflight$
declare
  v_tenant_id uuid;
  v_unrelated_notes bigint;
  v_list_fingerprint text;
  v_note_fingerprint text;
begin
  if pg_catalog.to_regclass('public.tenant_user_admin_notes') is not null then
    raise exception 'SAAS-9D-4B-1A preflight failed: target table already exists.';
  end if;

  if pg_catalog.to_regprocedure('public.active_single_tenant_id_v1()') is null
     or pg_catalog.to_regprocedure('public.get_my_tenant_role_v1(uuid)') is null
     or pg_catalog.to_regprocedure('public.set_audit_log_tenant_id()') is null
     or pg_catalog.to_regprocedure('public.admin_list_users_v1(integer,integer,text,text,text,text)') is null
     or pg_catalog.to_regprocedure('public.admin_set_user_note_v1(uuid,text)') is null then
    raise exception 'SAAS-9D-4B-1A preflight failed: required helper or RPC is absent.';
  end if;

  select public.active_single_tenant_id_v1() into v_tenant_id;
  if v_tenant_id is null
     or (select pg_catalog.count(*) from public.tenants where status='active')<>1
     or not exists(select 1 from public.tenants where id=v_tenant_id and slug='csk' and status='active') then
    raise exception 'SAAS-9D-4B-1A preflight failed: exact active CSK tenant is required.';
  end if;

  select pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(
           pg_catalog.pg_get_functiondef('public.admin_list_users_v1(integer,integer,text,text,text,text)'::regprocedure),
           E'\r\n',E'\n'),E'\r',E'\n')),
         pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(
           pg_catalog.pg_get_functiondef('public.admin_set_user_note_v1(uuid,text)'::regprocedure),
           E'\r\n',E'\n'),E'\r',E'\n'))
  into v_list_fingerprint,v_note_fingerprint;
  if v_list_fingerprint<>'e0702f533d7a9ee5b7de93bb68ef3168'
     or v_note_fingerprint<>'e3c20c8cf1cc0d986a54cca8a27bb11d' then
    raise exception 'SAAS-9D-4B-1A preflight failed: target function fingerprint drift (list %, note %).',v_list_fingerprint,v_note_fingerprint;
  end if;
  if pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(
       pg_catalog.pg_get_functiondef('public.set_audit_log_tenant_id()'::regprocedure),
       E'\r\n',E'\n'),E'\r',E'\n'))<>'7c30ab20ec1fecb553e5ef3e31c11868' then
    raise exception 'SAAS-9D-4B-1A preflight failed: audit integrity trigger fingerprint drift.';
  end if;

  if (select pg_catalog.count(*) from pg_catalog.pg_proc procedure
      join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace
      where namespace.nspname='public' and procedure.prosecdef)<>67 then
    raise exception 'SAAS-9D-4B-1A preflight failed: SECURITY DEFINER baseline is not 67.';
  end if;

  if (select pg_catalog.count(*) from information_schema.columns
      where table_schema='public'
        and table_name in('shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','email_deliveries')
        and column_name='tenant_id'
        and column_default='''c5c00000-0000-4000-8000-000000000001''::uuid')<>7 then
    raise exception 'SAAS-9D-4B-1A preflight failed: compatibility defaults differ.';
  end if;

  select pg_catalog.count(*) into v_unrelated_notes
  from public.profiles profile
  where profile.admin_note is not null
    and not (
      exists(select 1 from public.tenant_memberships membership
             where membership.tenant_id=v_tenant_id and membership.user_id=profile.user_id)
      or exists(select 1 from public.reservations reservation
                where reservation.tenant_id=v_tenant_id and reservation.user_id=profile.user_id)
      or exists(select 1 from public.event_registrations registration
                join public.events event_record
                  on event_record.id=registration.event_id
                 and event_record.tenant_id=registration.tenant_id
                where registration.tenant_id=v_tenant_id
                  and registration.user_id=profile.user_id)
    );

  if v_unrelated_notes<>0 then
    raise exception 'SAAS-9D-4B-1A preflight failed: % non-null legacy notes have no CSK operational relationship.',v_unrelated_notes;
  end if;
end;
$preflight$;

create temporary table saas9d4b1a_unchanged_functions on commit drop as
select procedure.oid::regprocedure::text signature,
       pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(
         pg_catalog.pg_get_functiondef(procedure.oid),E'\r\n',E'\n'
       ),E'\r',E'\n')) fingerprint,
       procedure.prosecdef,procedure.proowner,procedure.proconfig,procedure.proacl
from pg_catalog.pg_proc procedure
join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace
where namespace.nspname='public'
  and procedure.oid in(
    'public.admin_set_user_role_v1(uuid,text)'::regprocedure,
    'public.update_profile_identity(uuid,text,text)'::regprocedure,
    'public.update_profile_contact_details(uuid,text,text,text,text,text,text)'::regprocedure,
    'public.update_profile_verification(uuid,text,text)'::regprocedure,
    'public.export_my_data_v1()'::regprocedure,
    'public.anonymize_my_account_v1()'::regprocedure
  );

create temporary table saas9d4b1a_backfill_baseline on commit drop as
select
  (select pg_catalog.count(*) from public.profiles where admin_note is not null) legacy_note_count,
  (select pg_catalog.count(*)
   from public.profiles profile
   where profile.admin_note is not null
     and (
       exists(select 1 from public.tenant_memberships membership
              where membership.tenant_id=public.active_single_tenant_id_v1() and membership.user_id=profile.user_id)
       or exists(select 1 from public.reservations reservation
                 where reservation.tenant_id=public.active_single_tenant_id_v1() and reservation.user_id=profile.user_id)
       or exists(select 1 from public.event_registrations registration
                 join public.events event_record on event_record.id=registration.event_id and event_record.tenant_id=registration.tenant_id
                 where registration.tenant_id=public.active_single_tenant_id_v1() and registration.user_id=profile.user_id)
     )) eligible_note_count;

create table public.tenant_user_admin_notes(
  tenant_id uuid not null,
  user_id uuid not null,
  admin_note text,
  updated_at timestamp with time zone default pg_catalog.transaction_timestamp() not null,
  updated_by uuid,
  constraint tenant_user_admin_notes_pkey primary key(tenant_id,user_id),
  constraint tenant_user_admin_notes_tenant_id_fkey foreign key(tenant_id)
    references public.tenants(id) on delete cascade,
  constraint tenant_user_admin_notes_user_id_fkey foreign key(user_id)
    references auth.users(id) on delete cascade,
  constraint tenant_user_admin_notes_updated_by_fkey foreign key(updated_by)
    references auth.users(id) on delete set null,
  constraint tenant_user_admin_notes_length_check check(
    admin_note is null or pg_catalog.char_length(admin_note)<=2000
  )
);

alter table public.tenant_user_admin_notes owner to postgres;
alter table public.tenant_user_admin_notes enable row level security;

comment on table public.tenant_user_admin_notes is
  'Tenant-scoped operational admin notes. Direct client/server-runtime table access is denied; controlled RPCs are the only access path.';
comment on column public.tenant_user_admin_notes.updated_by is
  'Last authenticated operator. ON DELETE SET NULL preserves tenant note history without retaining a deleted auth identity.';

create index tenant_user_admin_notes_user_tenant_idx
  on public.tenant_user_admin_notes(user_id,tenant_id);

revoke all privileges on table public.tenant_user_admin_notes
  from public,anon,authenticated,service_role;

insert into public.tenant_user_admin_notes(
  tenant_id,user_id,admin_note,updated_at,updated_by
)
select public.active_single_tenant_id_v1(),profile.user_id,profile.admin_note,
       coalesce(profile.updated_at,pg_catalog.transaction_timestamp()),null
from public.profiles profile
where profile.admin_note is not null
  and (
    exists(select 1 from public.tenant_memberships membership
           where membership.tenant_id=public.active_single_tenant_id_v1() and membership.user_id=profile.user_id)
    or exists(select 1 from public.reservations reservation
              where reservation.tenant_id=public.active_single_tenant_id_v1() and reservation.user_id=profile.user_id)
    or exists(select 1 from public.event_registrations registration
              join public.events event_record on event_record.id=registration.event_id and event_record.tenant_id=registration.tenant_id
              where registration.tenant_id=public.active_single_tenant_id_v1() and registration.user_id=profile.user_id)
  );

create or replace function public.set_audit_log_tenant_id()
returns trigger
language plpgsql security invoker
set search_path=pg_catalog
as $function$
declare
  v_tenant_id uuid;
begin
  case new.target_type
    when 'reservation' then
      select record.tenant_id into v_tenant_id from public.reservations record where record.id=new.target_id;
    when 'event_registration' then
      select record.tenant_id into v_tenant_id from public.event_registrations record where record.id=new.target_id;
    when 'lane_booking_family' then
      select record.tenant_id into v_tenant_id from public.shooting_lanes record where record.id=new.target_id;
    when 'tenant_user_admin_note' then
      if new.action is distinct from 'tenant_user_admin_note_updated'
         or new.tenant_id is null
         or new.target_id is null
         or not exists(select 1 from public.tenants tenant where tenant.id=new.tenant_id)
         or not exists(select 1 from public.profiles profile where profile.user_id=new.target_id)
         or not (
           exists(select 1 from public.tenant_memberships membership where membership.tenant_id=new.tenant_id and membership.user_id=new.target_id)
           or exists(select 1 from public.reservations reservation where reservation.tenant_id=new.tenant_id and reservation.user_id=new.target_id)
           or exists(select 1 from public.event_registrations registration
                     join public.events event_record on event_record.id=registration.event_id and event_record.tenant_id=registration.tenant_id
                     where registration.tenant_id=new.tenant_id and registration.user_id=new.target_id)
         ) then
        raise exception using errcode='23514',message='tenant_user_admin_note_audit_mismatch';
      end if;
      return new;
    when 'profile','account' then
      if new.tenant_id is not null then
        raise exception using errcode='23514',message='global_audit_must_not_have_tenant';
      end if;
      return new;
    else
      raise exception using errcode='23514',message='unsupported_audit_target_type';
  end case;

  if v_tenant_id is null then
    raise exception using errcode='23503',message='audit_target_not_found';
  end if;
  if new.tenant_id is not null and new.tenant_id is distinct from v_tenant_id then
    raise exception using errcode='23514',message='audit_tenant_mismatch';
  end if;
  new.tenant_id:=v_tenant_id;
  return new;
end;
$function$;

alter function public.set_audit_log_tenant_id() owner to postgres;
revoke all on function public.set_audit_log_tenant_id() from public,anon,authenticated,service_role;

create or replace function public.admin_list_users_v1(
  p_limit integer default 50,p_offset integer default 0,p_search text default null,
  p_role text default null,p_verification_filter text default null,p_sort text default 'newest'
) returns table(
  user_id uuid,email text,first_name text,last_name text,full_name text,phone text,
  role text,verification_status text,admin_note text,created_at timestamptz,
  updated_at timestamptz,postal_code text,city text,street text,house_number text,
  apartment_number text,permission_sport boolean,permission_collector boolean,
  permission_hunting boolean,permission_training boolean,
  permission_personal_protection boolean,permission_other boolean,
  qualification_instructor boolean,qualification_range_officer boolean,
  qualification_pzss_license boolean,qualification_hunter boolean,
  permissions_verified boolean,permissions_verified_at timestamptz,
  permissions_verification_note text,total_count bigint
)
language plpgsql stable security definer
set search_path=pg_catalog,public,pg_temp
as $function$
declare
  v_actor_id uuid:=auth.uid();
  v_tenant_id uuid:=public.active_single_tenant_id_v1();
  v_search text:=nullif(pg_catalog.btrim(p_search),'');
  v_role text:=nullif(pg_catalog.lower(pg_catalog.btrim(p_role)),'');
  v_verification text:=nullif(pg_catalog.lower(pg_catalog.btrim(p_verification_filter)),'');
  v_sort text:=pg_catalog.lower(pg_catalog.btrim(coalesce(p_sort,'newest')));
begin
  if v_actor_id is null or v_tenant_id is null
     or public.get_my_tenant_role_v1(v_tenant_id) is distinct from 'admin' then
    raise exception 'Brak uprawnień do listy użytkowników.' using errcode='42501';
  end if;
  if p_limit is null or p_limit<1 or p_limit>100 or p_offset is null or p_offset<0 then
    raise exception 'Nieprawidłowe parametry stronicowania.' using errcode='22023';
  end if;
  if v_role is not null and v_role not in('admin','pracownik','instruktor','user') then
    raise exception 'Nieprawidłowy filtr roli.' using errcode='22023';
  end if;
  if v_verification is not null and v_verification not in('pending','unverified','verified','rejected') then
    raise exception 'Nieprawidłowy filtr weryfikacji.' using errcode='22023';
  end if;
  if v_sort not in('newest','oldest','name','role') then
    raise exception 'Nieprawidłowy sposób sortowania.' using errcode='22023';
  end if;

  return query
  with eligible_users as materialized(
    select membership.user_id from public.tenant_memberships membership where membership.tenant_id=v_tenant_id
    union
    select reservation.user_id from public.reservations reservation where reservation.tenant_id=v_tenant_id and reservation.user_id is not null
    union
    select registration.user_id
    from public.event_registrations registration
    join public.events event_record on event_record.id=registration.event_id and event_record.tenant_id=registration.tenant_id
    where registration.tenant_id=v_tenant_id and registration.user_id is not null
  ), scoped as materialized(
    select profile.*,
      case membership.role
        when 'employee' then 'pracownik'
        when 'instructor' then 'instruktor'
        when 'admin' then 'admin'
        when 'user' then 'user'
        else 'user'
      end as tenant_role,
      note.admin_note as tenant_admin_note,
      greatest(profile.updated_at,note.updated_at) as scoped_updated_at
    from eligible_users eligible
    join public.profiles profile on profile.user_id=eligible.user_id
    left join public.tenant_memberships membership
      on membership.tenant_id=v_tenant_id and membership.user_id=eligible.user_id
    left join public.tenant_user_admin_notes note
      on note.tenant_id=v_tenant_id and note.user_id=eligible.user_id
  ), filtered as(
    select scoped.* from scoped
    where (v_role is null or scoped.tenant_role=v_role)
      and (
        v_verification is null
        or (v_verification='pending' and scoped.verification_status='pending')
        or (v_verification='verified' and scoped.verification_status='verified' and scoped.permissions_verified)
        or (v_verification='rejected' and scoped.verification_status='rejected')
        or (v_verification='unverified' and (scoped.verification_status is distinct from 'verified' or not scoped.permissions_verified))
      )
      and (
        v_search is null
        or coalesce(scoped.first_name,'') ilike '%'||v_search||'%'
        or coalesce(scoped.last_name,'') ilike '%'||v_search||'%'
        or coalesce(scoped.full_name,'') ilike '%'||v_search||'%'
        or coalesce(scoped.email,'') ilike '%'||v_search||'%'
        or coalesce(scoped.phone,'') ilike '%'||v_search||'%'
      )
  )
  select filtered.user_id,filtered.email,filtered.first_name,filtered.last_name,
    filtered.full_name,filtered.phone,filtered.tenant_role,filtered.verification_status,
    filtered.tenant_admin_note,filtered.created_at,filtered.scoped_updated_at,
    filtered.postal_code,filtered.city,filtered.street,filtered.house_number,
    filtered.apartment_number,filtered.permission_sport,filtered.permission_collector,
    filtered.permission_hunting,filtered.permission_training,
    filtered.permission_personal_protection,filtered.permission_other,
    filtered.qualification_instructor,filtered.qualification_range_officer,
    filtered.qualification_pzss_license,filtered.qualification_hunter,
    filtered.permissions_verified,filtered.permissions_verified_at,
    filtered.permissions_verification_note,pg_catalog.count(*) over()
  from filtered
  order by
    case when v_sort='newest' then filtered.created_at end desc nulls last,
    case when v_sort='oldest' then filtered.created_at end asc nulls last,
    case when v_sort='name' then pg_catalog.lower(coalesce(nullif(pg_catalog.btrim(filtered.full_name),''),nullif(pg_catalog.btrim(filtered.first_name||' '||filtered.last_name),''),filtered.email,'')) end asc,
    case when v_sort='role' then filtered.tenant_role end asc,
    filtered.user_id asc
  limit p_limit offset p_offset;
end;
$function$;

create or replace function public.admin_set_user_note_v1(p_target_user_id uuid,p_admin_note text)
returns jsonb
language plpgsql security definer
set search_path=pg_catalog,public,pg_temp
as $function$
declare
  v_actor_id uuid:=auth.uid();
  v_tenant_id uuid:=public.active_single_tenant_id_v1();
  v_note text:=nullif(pg_catalog.btrim(p_admin_note),'');
  v_previous_note text;
  v_note_row_found boolean:=false;
  v_changed_at timestamptz:=pg_catalog.transaction_timestamp();
begin
  if v_actor_id is null or v_tenant_id is null
     or public.get_my_tenant_role_v1(v_tenant_id) is distinct from 'admin' then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','not_allowed');
  end if;
  if p_target_user_id is null then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','invalid_target');
  end if;
  if pg_catalog.length(coalesce(v_note,''))>2000 then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','note_too_long');
  end if;
  if not exists(select 1 from public.profiles where user_id=p_target_user_id) then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','target_not_found');
  end if;
  if not (
    exists(select 1 from public.tenant_memberships membership where membership.tenant_id=v_tenant_id and membership.user_id=p_target_user_id)
    or exists(select 1 from public.reservations reservation where reservation.tenant_id=v_tenant_id and reservation.user_id=p_target_user_id)
    or exists(select 1 from public.event_registrations registration
              join public.events event_record on event_record.id=registration.event_id and event_record.tenant_id=registration.tenant_id
              where registration.tenant_id=v_tenant_id and registration.user_id=p_target_user_id)
  ) then
    return pg_catalog.jsonb_build_object('ok',false,'changed',false,'code','not_allowed');
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_tenant_id::text||':'||p_target_user_id::text,0));
  select note.admin_note,true into v_previous_note,v_note_row_found
  from public.tenant_user_admin_notes note
  where note.tenant_id=v_tenant_id and note.user_id=p_target_user_id
  for update;

  if coalesce(v_note_row_found,false) and v_previous_note is not distinct from v_note
     or not coalesce(v_note_row_found,false) and v_note is null then
    return pg_catalog.jsonb_build_object('ok',true,'changed',false,'code','no_change','target_user_id',p_target_user_id);
  end if;

  if v_note is null then
    delete from public.tenant_user_admin_notes
    where tenant_id=v_tenant_id and user_id=p_target_user_id;
  else
    insert into public.tenant_user_admin_notes(tenant_id,user_id,admin_note,updated_at,updated_by)
    values(v_tenant_id,p_target_user_id,v_note,v_changed_at,v_actor_id)
    on conflict(tenant_id,user_id) do update
      set admin_note=excluded.admin_note,updated_at=excluded.updated_at,updated_by=excluded.updated_by;
  end if;

  insert into public.audit_logs(
    tenant_id,actor_user_id,actor_name,actor_role,action,target_type,target_id,target_name,details
  ) values(
    v_tenant_id,v_actor_id,'Tenant administrator','admin',
    'tenant_user_admin_note_updated','tenant_user_admin_note',p_target_user_id,'Tenant user',
    pg_catalog.jsonb_build_object(
      'previous_note_present',v_previous_note is not null,
      'new_note_present',v_note is not null,
      'operator_role','admin'
    )
  );

  return pg_catalog.jsonb_build_object(
    'ok',true,'changed',true,'code','updated','target_user_id',p_target_user_id,
    'admin_note',v_note,'updated_at',v_changed_at
  );
end;
$function$;

alter function public.admin_list_users_v1(integer,integer,text,text,text,text) owner to postgres;
alter function public.admin_set_user_note_v1(uuid,text) owner to postgres;
revoke all on function public.admin_list_users_v1(integer,integer,text,text,text,text) from public,anon,authenticated,service_role;
revoke all on function public.admin_set_user_note_v1(uuid,text) from public,anon,authenticated,service_role;
grant execute on function public.admin_list_users_v1(integer,integer,text,text,text,text) to authenticated;
grant execute on function public.admin_set_user_note_v1(uuid,text) to authenticated;

do $postflight$
declare
  v_snapshot record;
  v_baseline record;
begin
  select * into v_baseline from saas9d4b1a_backfill_baseline;
  if (select pg_catalog.count(*) from public.tenant_user_admin_notes)<>v_baseline.eligible_note_count
     or v_baseline.legacy_note_count<>v_baseline.eligible_note_count then
    raise exception 'SAAS-9D-4B-1A postflight failed: backfill count differs.';
  end if;

  if not exists(select 1 from pg_catalog.pg_class where oid='public.tenant_user_admin_notes'::regclass and relrowsecurity)
     or exists(select 1 from pg_catalog.pg_policies where schemaname='public' and tablename='tenant_user_admin_notes')
     or exists(select 1 from (values('public'::name),('anon'::name),('authenticated'::name),('service_role'::name)) role(name)
               where pg_catalog.has_table_privilege(role.name,'public.tenant_user_admin_notes','SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN')) then
    raise exception 'SAAS-9D-4B-1A postflight failed: table RLS/ACL differs.';
  end if;

  if pg_catalog.strpos((select prosrc from pg_catalog.pg_proc where oid='public.admin_list_users_v1(integer,integer,text,text,text,text)'::regprocedure),'tenant_user_admin_notes')=0
     or pg_catalog.strpos((select prosrc from pg_catalog.pg_proc where oid='public.admin_set_user_note_v1(uuid,text)'::regprocedure),'tenant_user_admin_notes')=0
     or pg_catalog.strpos((select prosrc from pg_catalog.pg_proc where oid='public.admin_list_users_v1(integer,integer,text,text,text,text)'::regprocedure),'profile.admin_note')>0
     or pg_catalog.strpos((select prosrc from pg_catalog.pg_proc where oid='public.admin_set_user_note_v1(uuid,text)'::regprocedure),'profiles as profile\n  set admin_note')>0 then
    raise exception 'SAAS-9D-4B-1A postflight failed: legacy note source remains active.';
  end if;

  if (select pg_catalog.count(*) from pg_catalog.pg_proc procedure join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace where namespace.nspname='public' and procedure.prosecdef)<>67
     or (select pg_catalog.count(*) from information_schema.columns where table_schema='public' and table_name in('shooting_lanes','reservations','lane_blocks','events','event_lanes','event_registrations','email_deliveries') and column_name='tenant_id' and column_default='''c5c00000-0000-4000-8000-000000000001''::uuid')<>7 then
    raise exception 'SAAS-9D-4B-1A postflight failed: security inventory/defaults drift.';
  end if;

  for v_snapshot in select * from saas9d4b1a_unchanged_functions loop
    if not exists(
      select 1 from pg_catalog.pg_proc procedure
      where procedure.oid=pg_catalog.to_regprocedure(v_snapshot.signature)
        and pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(pg_catalog.pg_get_functiondef(procedure.oid),E'\r\n',E'\n'),E'\r',E'\n'))=v_snapshot.fingerprint
        and procedure.prosecdef=v_snapshot.prosecdef and procedure.proowner=v_snapshot.proowner
        and procedure.proconfig is not distinct from v_snapshot.proconfig
        and procedure.proacl is not distinct from v_snapshot.proacl
    ) then
      raise exception 'SAAS-9D-4B-1A postflight failed: out-of-scope function % drifted.',v_snapshot.signature;
    end if;
  end loop;
end;
$postflight$;

reset statement_timeout;
reset lock_timeout;

commit;
