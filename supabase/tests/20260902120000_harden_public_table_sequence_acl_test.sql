\set ON_ERROR_STOP on
\pset format unaligned

select '1..29';

begin;

create temporary table test_results(
  test_order integer primary key,
  test_name text not null,
  passed boolean not null,
  result text not null
) on commit drop;

create function pg_temp.record_result(integer,text,boolean,text)
returns void language sql as $function$
  insert into pg_temp.test_results values ($1,$2,coalesce($3,false),$4);
$function$;

create temporary table expected_table_acl(
  table_name text primary key,
  category text not null check (category in ('A','B','C','D','E')),
  anon_privileges text[] not null,
  authenticated_privileges text[] not null,
  service_role_privileges text[] not null
) on commit drop;

insert into expected_table_acl values
  ('audit_logs','E','{}','{SELECT}','{DELETE,INSERT,MAINTAIN,REFERENCES,SELECT,TRIGGER,TRUNCATE,UPDATE}'),
  ('confirmation_email_rate_limits','D','{}','{}','{MAINTAIN,REFERENCES,TRIGGER,TRUNCATE}'),
  ('email_deliveries','D','{}','{}','{DELETE,INSERT,MAINTAIN,REFERENCES,SELECT,TRIGGER,TRUNCATE,UPDATE}'),
  ('event_lanes','C','{}','{SELECT}','{DELETE,INSERT,MAINTAIN,REFERENCES,SELECT,TRIGGER,TRUNCATE,UPDATE}'),
  ('event_registrations','B','{}','{SELECT}','{DELETE,INSERT,MAINTAIN,REFERENCES,SELECT,TRIGGER,TRUNCATE,UPDATE}'),
  ('events','A','{SELECT}','{SELECT}','{DELETE,INSERT,MAINTAIN,REFERENCES,SELECT,TRIGGER,TRUNCATE,UPDATE}'),
  ('lane_blocks','C','{}','{SELECT}','{DELETE,INSERT,MAINTAIN,REFERENCES,SELECT,TRIGGER,TRUNCATE,UPDATE}'),
  ('lane_booking_durations','A','{SELECT}','{SELECT}','{DELETE,INSERT,MAINTAIN,REFERENCES,SELECT,TRIGGER,TRUNCATE,UPDATE}'),
  ('lane_booking_family_configuration_versions','D','{}','{}','{MAINTAIN,REFERENCES,TRIGGER,TRUNCATE}'),
  ('lane_booking_rules','A','{SELECT}','{SELECT}','{DELETE,INSERT,MAINTAIN,REFERENCES,SELECT,TRIGGER,TRUNCATE,UPDATE}'),
  ('lane_pricing_rules','A','{SELECT}','{SELECT}','{DELETE,INSERT,MAINTAIN,REFERENCES,SELECT,TRIGGER,TRUNCATE,UPDATE}'),
  ('profiles','B','{}','{INSERT,SELECT,UPDATE}','{DELETE,INSERT,MAINTAIN,REFERENCES,SELECT,TRIGGER,TRUNCATE,UPDATE}'),
  ('reservations','B','{}','{DELETE,SELECT}','{DELETE,INSERT,MAINTAIN,REFERENCES,SELECT,TRIGGER,TRUNCATE,UPDATE}'),
  ('shooting_lanes','A','{SELECT}','{SELECT}','{DELETE,INSERT,MAINTAIN,REFERENCES,SELECT,TRIGGER,TRUNCATE,UPDATE}');

create function pg_temp.table_privileges(p_table text,p_role text)
returns text[]
language sql
stable
set search_path=pg_catalog,public,pg_temp
as $function$
  select coalesce(array_agg(acl.privilege_type order by acl.privilege_type),'{}'::text[])
  from pg_catalog.pg_class relation
  join pg_catalog.pg_namespace namespace on namespace.oid=relation.relnamespace
  left join lateral pg_catalog.aclexplode(coalesce(relation.relacl,pg_catalog.acldefault('r',relation.relowner))) acl on true
  left join pg_catalog.pg_roles grantee on grantee.oid=acl.grantee
  where namespace.nspname='public'
    and relation.relname=p_table
    and relation.relkind in ('r','p')
    and grantee.rolname=p_role;
$function$;

create function pg_temp.set_client(p_role text,p_user_id uuid)
returns void
language plpgsql
as $function$
begin
  perform pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object('sub',p_user_id,'role',p_role)::text,
    true
  );
  perform pg_catalog.set_config('request.jwt.claim.sub',coalesce(p_user_id::text,''),true);
  execute pg_catalog.format('set local role %I',p_role);
end;
$function$;

create function pg_temp.noop_trigger()
returns trigger language plpgsql as $function$
begin
  return new;
end;
$function$;

grant execute on function pg_temp.noop_trigger() to authenticated;

do $tests$
declare
  v_admin uuid := '6c02b000-0000-4000-8000-000000000001';
  v_user uuid := '6c02b000-0000-4000-8000-000000000002';
  v_other uuid := '6c02b000-0000-4000-8000-000000000003';
  v_lane uuid := '6c02b000-0000-4000-8000-000000000010';
  v_price uuid := '6c02b000-0000-4000-8000-000000000011';
  v_reservation uuid := '6c02b000-0000-4000-8000-000000000012';
  v_count integer;
  v_denied boolean;
begin
  perform pg_temp.record_result(1,'Complete public table inventory',
    (select count(*)=14 from pg_temp.expected_table_acl)
    and (select count(*)=14 from pg_catalog.pg_class relation join pg_catalog.pg_namespace namespace on namespace.oid=relation.relnamespace where namespace.nspname='public' and relation.relkind in ('r','p')),
    'Oczekiwano dokładnie 14 zinwentaryzowanych tabel public.');

  perform pg_temp.record_result(2,'RLS enabled on every public table',
    not exists(select 1 from pg_catalog.pg_class relation join pg_catalog.pg_namespace namespace on namespace.oid=relation.relnamespace where namespace.nspname='public' and relation.relkind in ('r','p') and not relation.relrowsecurity),
    'Każda tabela aplikacyjna musi mieć włączone RLS.');

  perform pg_temp.record_result(3,'PUBLIC has no public-table privileges',
    not exists(select 1 from pg_temp.expected_table_acl expected where pg_temp.table_privileges(expected.table_name,'PUBLIC')<>'{}'::text[]),
    'PUBLIC nie może mieć praw do tabel aplikacyjnych.');

  perform pg_temp.record_result(4,'Exact anon table ACL',
    not exists(select 1 from pg_temp.expected_table_acl expected where pg_temp.table_privileges(expected.table_name,'anon')<>expected.anon_privileges),
    'anon ma wyłącznie pięć jawnych publicznych odczytów.');

  perform pg_temp.record_result(5,'Exact authenticated table ACL',
    not exists(select 1 from pg_temp.expected_table_acl expected where pg_temp.table_privileges(expected.table_name,'authenticated')<>expected.authenticated_privileges),
    'authenticated ma wyłącznie prawa wymagane przez istniejące RLS.');

  perform pg_temp.record_result(6,'service_role table ACL unchanged',
    not exists(select 1 from pg_temp.expected_table_acl expected where pg_temp.table_privileges(expected.table_name,'service_role')<>expected.service_role_privileges),
    'Migracja nie może mechanicznie redukować service_role.');

  perform pg_temp.record_result(7,'anon lacks technical table privileges',
    not exists(select 1 from pg_temp.expected_table_acl expected where pg_catalog.has_table_privilege('anon',pg_catalog.format('public.%I',expected.table_name),'TRUNCATE,REFERENCES,TRIGGER,MAINTAIN')),
    'anon nie może mieć TRUNCATE, REFERENCES, TRIGGER ani MAINTAIN.');

  perform pg_temp.record_result(8,'authenticated lacks technical table privileges',
    not exists(select 1 from pg_temp.expected_table_acl expected where pg_catalog.has_table_privilege('authenticated',pg_catalog.format('public.%I',expected.table_name),'TRUNCATE,REFERENCES,TRIGGER,MAINTAIN')),
    'authenticated nie może mieć TRUNCATE, REFERENCES, TRIGGER ani MAINTAIN.');

  perform pg_temp.record_result(9,'Public sequence inventory is empty and client-safe',
    not exists(select 1 from pg_catalog.pg_class relation join pg_catalog.pg_namespace namespace on namespace.oid=relation.relnamespace where namespace.nspname='public' and relation.relkind='S'),
    'Schemat public nie zawiera istniejących sekwencji.');

  perform pg_temp.record_result(10,'Default TABLE privileges are client-safe',
    not exists(
      select 1 from pg_catalog.pg_default_acl defaults
      join pg_catalog.pg_roles owner on owner.oid=defaults.defaclrole
      join pg_catalog.pg_namespace namespace on namespace.oid=defaults.defaclnamespace
      cross join lateral pg_catalog.aclexplode(defaults.defaclacl) acl
      left join pg_catalog.pg_roles grantee on grantee.oid=acl.grantee
      where owner.rolname='postgres' and namespace.nspname='public' and defaults.defaclobjtype='r'
        and (acl.grantee=0 or grantee.rolname in ('anon','authenticated'))
    ),'Nowe tabele postgres nie mogą dziedziczyć praw klienta.');

  perform pg_temp.record_result(11,'Default SEQUENCE privileges are client-safe',
    not exists(
      select 1 from pg_catalog.pg_default_acl defaults
      join pg_catalog.pg_roles owner on owner.oid=defaults.defaclrole
      join pg_catalog.pg_namespace namespace on namespace.oid=defaults.defaclnamespace
      cross join lateral pg_catalog.aclexplode(defaults.defaclacl) acl
      left join pg_catalog.pg_roles grantee on grantee.oid=acl.grantee
      where owner.rolname='postgres' and namespace.nspname='public' and defaults.defaclobjtype='S'
        and (acl.grantee=0 or grantee.rolname in ('anon','authenticated'))
    ),'Nowe sekwencje postgres nie mogą dziedziczyć praw klienta.');

  create table public.csk_sec002b_table_probe(id bigint primary key);
  create sequence public.csk_sec002b_sequence_probe;

  perform pg_temp.record_result(12,'NEW TABLE SAFE DEFAULT',
    not pg_catalog.has_any_column_privilege('anon','public.csk_sec002b_table_probe','SELECT,INSERT,UPDATE,REFERENCES')
    and not pg_catalog.has_any_column_privilege('authenticated','public.csk_sec002b_table_probe','SELECT,INSERT,UPDATE,REFERENCES')
    and not pg_catalog.has_table_privilege('anon','public.csk_sec002b_table_probe','SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN')
    and not pg_catalog.has_table_privilege('authenticated','public.csk_sec002b_table_probe','SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN'),
    'Nowa tabela ma bezpieczne owner-only/client-deny defaults.');

  perform pg_temp.record_result(13,'NEW SEQUENCE SAFE DEFAULT',
    not pg_catalog.has_sequence_privilege('anon','public.csk_sec002b_sequence_probe','USAGE,SELECT,UPDATE')
    and not pg_catalog.has_sequence_privilege('authenticated','public.csk_sec002b_sequence_probe','USAGE,SELECT,UPDATE'),
    'Nowa sekwencja ma bezpieczne owner-only/client-deny defaults.');

  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values
    (v_admin,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','test-sec002b-admin@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now()),
    (v_user,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','test-sec002b-user@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now()),
    (v_other,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','test-sec002b-other@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now());

  insert into public.profiles(user_id,role,first_name,last_name,full_name,email)
  values
    (v_admin,'admin','[TEST]','SEC-002B Admin','[TEST][SEC-002B] Admin','test-sec002b-admin@example.invalid'),
    (v_user,'user','[TEST]','SEC-002B User','[TEST][SEC-002B] User','test-sec002b-user@example.invalid'),
    (v_other,'user','[TEST]','SEC-002B Other','[TEST][SEC-002B] Other','test-sec002b-other@example.invalid');

  insert into public.shooting_lanes(id,name,type,is_active,max_shooters,booking_step_minutes,resource_kind,whole_lane_bookable,positions_bookable)
  values(v_lane,'[TEST][SEC-002B] Lane','shooting',false,1,60,'lane',true,false);
  insert into public.lane_pricing_rules(id,lane_id,day_group,min_shooters,max_shooters,label,hourly_price)
  values(v_price,v_lane,'mon_thu',1,1,'[TEST][SEC-002B]',10);
  insert into public.reservations(
    id,user_id,lane_id,customer_name,customer_email,customer_phone,reservation_date,start_time,end_time,
    duration_minutes,price,reservation_status,payment_status,shooters_count,pricing_rule_id,
    pricing_day_group_snapshot,lane_name_snapshot,pricing_label_snapshot,price_per_hour_snapshot,total_price,
    currency_code,creation_request_id
  ) values(
    v_reservation,v_user,v_lane,'[TEST] User','test-sec002b-user@example.invalid','000000000',date '2099-01-05',time '10:00',time '11:00',
    60,10,'confirmed','pay_on_site',1,v_price,'mon_thu','[TEST][SEC-002B] Lane','[TEST][SEC-002B]',10,10,'PLN','6c02b000-0000-4000-8000-000000000013'
  );

  begin
    perform pg_temp.set_client('anon',null);
    perform count(*) from public.events;
    execute 'reset role';
    v_denied:=false;
  exception when others then v_denied:=true;
  end;
  perform pg_temp.record_result(14,'Anonymous public event read remains allowed',not v_denied,'Publiczny SELECT aktywnych eventów działa.');

  begin
    perform pg_temp.set_client('anon',null);
    perform count(*) from public.profiles;
    execute 'reset role';
    v_denied:=false;
  exception when insufficient_privilege then v_denied:=true;
  end;
  perform pg_temp.record_result(15,'Anonymous profile read is denied by SQL ACL',v_denied,'anon otrzymuje SQLSTATE 42501 dla profiles.');

  begin
    perform pg_temp.set_client('authenticated',v_user);
    select count(*) into v_count from public.profiles where user_id=v_user;
    execute 'reset role';
  end;
  perform pg_temp.record_result(16,'Authenticated own profile read remains allowed',v_count=1,'Własny profil pozostaje czytelny przez RLS.');

  begin
    perform pg_temp.set_client('authenticated',v_user);
    update public.profiles set phone='000000001' where user_id=v_user;
    get diagnostics v_count=row_count;
    execute 'reset role';
  end;
  perform pg_temp.record_result(17,'Authenticated own profile update remains allowed',v_count=1,'Dozwolona aktualizacja własnych danych działa.');

  begin
    perform pg_temp.set_client('authenticated',v_user);
    select count(*) into v_count from public.profiles where user_id=v_other;
    execute 'reset role';
  end;
  perform pg_temp.record_result(18,'Authenticated other profile remains hidden',v_count=0,'RLS nie ujawnia cudzego profilu.');

  begin
    perform pg_temp.set_client('authenticated',v_user);
    insert into public.audit_logs(action,target_type,details) values('sec002b_denied','test','{}');
    execute 'reset role';
    v_denied:=false;
  exception when insufficient_privilege then v_denied:=true;
  end;
  perform pg_temp.record_result(19,'Ordinary user audit insert is denied',v_denied,'RLS blokuje zapis audytu przez zwykłego użytkownika.');

  begin
    perform pg_temp.set_client('authenticated',v_admin);
    insert into public.audit_logs(actor_user_id,action,target_type,details) values(v_admin,'sec002b_admin','test','{}');
    execute 'reset role';
    v_denied:=false;
  exception when insufficient_privilege then v_denied:=true;
  end;
  perform pg_temp.record_result(20,'Admin direct audit insert is denied',v_denied,'Audyt może powstać wyłącznie przez zaufany flow SECURITY DEFINER.');

  begin
    perform pg_temp.set_client('authenticated',v_user);
    select count(*) into v_count from public.reservations where id=v_reservation;
    execute 'reset role';
  end;
  perform pg_temp.record_result(21,'Authenticated own reservation read remains allowed',v_count=1,'Własna rezerwacja pozostaje czytelna.');

  begin
    perform pg_temp.set_client('authenticated',v_user);
    delete from public.reservations where id=v_reservation;
    get diagnostics v_count=row_count;
    execute 'reset role';
  end;
  perform pg_temp.record_result(22,'Ordinary user cannot directly delete reservation',v_count=0,'RLS nie dopuszcza bezpośredniego DELETE zwykłego użytkownika.');

  begin
    perform pg_temp.set_client('anon',null);
    execute 'truncate table public.events';
    execute 'reset role';
    v_denied:=false;
  exception when insufficient_privilege then v_denied:=true;
  end;
  perform pg_temp.record_result(23,'anon TRUNCATE actual SQL deny',v_denied,'TRUNCATE zwraca SQLSTATE 42501.');

  begin
    perform pg_temp.set_client('authenticated',v_user);
    execute 'truncate table public.profiles';
    execute 'reset role';
    v_denied:=false;
  exception when insufficient_privilege then v_denied:=true;
  end;
  perform pg_temp.record_result(24,'authenticated TRUNCATE actual SQL deny',v_denied,'TRUNCATE zwraca SQLSTATE 42501.');

  execute 'create schema csk_sec002b_auth authorization authenticated';
  begin
    perform pg_temp.set_client('authenticated',v_user);
    execute 'create table csk_sec002b_auth.reference_probe(profile_id uuid)';
    begin
      execute 'alter table csk_sec002b_auth.reference_probe add constraint csk_sec002b_reference_probe_fkey foreign key(profile_id) references public.profiles(id)';
      v_denied:=false;
    exception when insufficient_privilege then
      v_denied:=true;
    end;
    execute 'reset role';
  exception when others then
    execute 'reset role';
    v_denied:=false;
  end;
  perform pg_temp.record_result(25,'authenticated REFERENCES actual SQL deny',v_denied,'Utworzenie FK do profiles zwraca SQLSTATE 42501.');

  begin
    perform pg_temp.set_client('authenticated',v_user);
    execute 'create trigger csk_sec002b_trigger_probe before update on public.profiles for each row execute function pg_temp.noop_trigger()';
    execute 'reset role';
    v_denied:=false;
  exception when insufficient_privilege then v_denied:=true;
  end;
  perform pg_temp.record_result(26,'authenticated TRIGGER actual SQL deny',v_denied,'CREATE TRIGGER na profiles zwraca SQLSTATE 42501.');

  begin
    perform pg_temp.set_client('anon',null);
    perform count(*) from public.get_public_booking_configuration_v1();
    execute 'reset role';
    v_denied:=false;
  exception when others then v_denied:=true;
  end;
  perform pg_temp.record_result(27,'Public booking configuration remains allowed',not v_denied,'Anon RPC reader działa bez bezpośredniego dostępu do tabel wewnętrznych.');

  perform pg_temp.record_result(28,'Fixture is transaction-scoped',
    (select count(*)=1 from public.shooting_lanes where id=v_lane)
    and (select count(*)=1 from public.reservations where id=v_reservation),
    'Fixture [TEST][SEC-002B] istnieje wyłącznie przed końcowym ROLLBACK.');
end;
$tests$;

create temporary table acl_before_double_apply as
select pg_catalog.md5(pg_catalog.string_agg(
  relation.oid::text||':'||coalesce(relation.relacl::text,'NULL'),',' order by relation.oid
)) as acl_hash
from pg_catalog.pg_class relation
join pg_catalog.pg_namespace namespace on namespace.oid=relation.relnamespace
where namespace.nspname='public' and relation.relkind in ('r','p','S');

-- Repeat the migration's idempotent ACL normalization twice. Supabase's test
-- container mounts tests without the sibling migrations directory, so \ir is
-- intentionally avoided here.
alter default privileges for role postgres in schema public revoke all privileges on tables from public, anon, authenticated;
alter default privileges for role postgres in schema public revoke all privileges on sequences from public, anon, authenticated;
revoke all privileges on all tables in schema public from public, anon, authenticated;
revoke all privileges on all sequences in schema public from public, anon, authenticated;
grant select on table public.events,public.lane_booking_durations,public.lane_booking_rules,public.lane_pricing_rules,public.shooting_lanes to anon,authenticated;
grant select on table public.audit_logs,public.event_lanes,public.event_registrations,public.lane_blocks,public.profiles,public.reservations to authenticated;
grant insert,update on table public.profiles to authenticated;
grant delete on table public.reservations to authenticated;

alter default privileges for role postgres in schema public revoke all privileges on tables from public, anon, authenticated;
alter default privileges for role postgres in schema public revoke all privileges on sequences from public, anon, authenticated;
revoke all privileges on all tables in schema public from public, anon, authenticated;
revoke all privileges on all sequences in schema public from public, anon, authenticated;
grant select on table public.events,public.lane_booking_durations,public.lane_booking_rules,public.lane_pricing_rules,public.shooting_lanes to anon,authenticated;
grant select on table public.audit_logs,public.event_lanes,public.event_registrations,public.lane_blocks,public.profiles,public.reservations to authenticated;
grant insert,update on table public.profiles to authenticated;
grant delete on table public.reservations to authenticated;

select pg_temp.record_result(29,'Double application is idempotent',
  (select acl_hash from pg_temp.acl_before_double_apply)=(
    select pg_catalog.md5(pg_catalog.string_agg(
      relation.oid::text||':'||coalesce(relation.relacl::text,'NULL'),',' order by relation.oid
    ))
    from pg_catalog.pg_class relation
    join pg_catalog.pg_namespace namespace on namespace.oid=relation.relnamespace
    where namespace.nspname='public' and relation.relkind in ('r','p','S')
  ),'Druga aplikacja nie zmienia ACL i nie tworzy dodatkowych grantów.');

select (case when passed then 'ok ' else 'not ok ' end)
  ||test_order::text||' - '||test_name
  ||case when passed then '' else E'\n# '||result end
from pg_temp.test_results
order by test_order;

do $assertions$
declare v_failures text;
begin
  select pg_catalog.string_agg(test_order::text||': '||test_name,', ' order by test_order)
  into v_failures from pg_temp.test_results where passed is false;
  if v_failures is not null then
    raise exception 'SEC-002B table/sequence ACL tests failed: %',v_failures;
  end if;
end;
$assertions$;

rollback;
