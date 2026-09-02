\set ON_ERROR_STOP on
\pset format unaligned
\pset tuples_only on

select '1..10';

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

do $tests$
begin
  perform pg_temp.record_result(1,'No managed-owner application relations',
    not exists(
      with allowed_managed_objects(schema_name,object_name,object_type,owner_name,justification) as (
        select null::text,null::text,null::text,null::text,null::text where false
      )
      select 1
      from pg_catalog.pg_class relation
      join pg_catalog.pg_namespace namespace on namespace.oid=relation.relnamespace
      left join allowed_managed_objects allowed
        on allowed.schema_name=namespace.nspname
       and allowed.object_name=relation.relname
       and allowed.object_type=relation.relkind::text
       and allowed.owner_name=pg_catalog.pg_get_userbyid(relation.relowner)
      where namespace.nspname='public'
        and relation.relkind in ('r','p','S','v','m','f')
        and pg_catalog.pg_get_userbyid(relation.relowner)<>'postgres'
        and allowed.object_name is null
    ),'Każda tabela, sekwencja, view, materialized view i foreign table w public musi należeć do postgres albo jawnej allowlisty.');

  perform pg_temp.record_result(2,'All public functions are application-owned',
    not exists(
      select 1
      from pg_catalog.pg_proc procedure
      join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace
      where namespace.nspname='public'
        and pg_catalog.pg_get_userbyid(procedure.proowner)<>'postgres'
    ),'Każda funkcja public musi należeć do postgres.');

  perform pg_temp.record_result(3,'No anon technical table privileges',
    not exists(
      select 1
      from pg_catalog.pg_class relation
      join pg_catalog.pg_namespace namespace on namespace.oid=relation.relnamespace
      where namespace.nspname='public'
        and relation.relkind in ('r','p')
        and pg_catalog.has_table_privilege(
          'anon',relation.oid,'TRUNCATE,REFERENCES,TRIGGER,MAINTAIN'
        )
    ),'anon nie może posiadać TRUNCATE, REFERENCES, TRIGGER ani MAINTAIN.');

  perform pg_temp.record_result(4,'No authenticated technical table privileges',
    not exists(
      select 1
      from pg_catalog.pg_class relation
      join pg_catalog.pg_namespace namespace on namespace.oid=relation.relnamespace
      where namespace.nspname='public'
        and relation.relkind in ('r','p')
        and pg_catalog.has_table_privilege(
          'authenticated',relation.oid,'TRUNCATE,REFERENCES,TRIGGER,MAINTAIN'
        )
    ),'authenticated nie może posiadać TRUNCATE, REFERENCES, TRIGGER ani MAINTAIN.');

  perform pg_temp.record_result(5,'postgres TABLE defaults remain client-safe',
    not exists(
      select 1
      from pg_catalog.pg_default_acl defaults
      join pg_catalog.pg_roles owner on owner.oid=defaults.defaclrole
      join pg_catalog.pg_namespace namespace on namespace.oid=defaults.defaclnamespace
      cross join lateral pg_catalog.aclexplode(defaults.defaclacl) acl
      left join pg_catalog.pg_roles grantee on grantee.oid=acl.grantee
      where owner.rolname='postgres'
        and namespace.nspname='public'
        and defaults.defaclobjtype='r'
        and (acl.grantee=0 or grantee.rolname in ('anon','authenticated'))
    ),'Default TABLE ACL ownera postgres musi pozostać fail-closed dla ról klienckich.');

  perform pg_temp.record_result(6,'postgres SEQUENCE defaults remain client-safe',
    not exists(
      select 1
      from pg_catalog.pg_default_acl defaults
      join pg_catalog.pg_roles owner on owner.oid=defaults.defaclrole
      join pg_catalog.pg_namespace namespace on namespace.oid=defaults.defaclnamespace
      cross join lateral pg_catalog.aclexplode(defaults.defaclacl) acl
      left join pg_catalog.pg_roles grantee on grantee.oid=acl.grantee
      where owner.rolname='postgres'
        and namespace.nspname='public'
        and defaults.defaclobjtype='S'
        and (acl.grantee=0 or grantee.rolname in ('anon','authenticated'))
    ),'Default SEQUENCE ACL ownera postgres musi pozostać fail-closed dla ról klienckich.');

  create table public.csk_sec002c_table_probe(id bigint primary key);
  create sequence public.csk_sec002c_sequence_probe;

  perform pg_temp.record_result(7,'NEW TABLE has no automatic anon grant',
    not pg_catalog.has_table_privilege(
      'anon','public.csk_sec002c_table_probe',
      'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN'
    ),'Tabela utworzona przez postgres nie może automatycznie udostępniać anon żadnego prawa.');

  perform pg_temp.record_result(8,'NEW TABLE has no automatic authenticated grant',
    not pg_catalog.has_table_privilege(
      'authenticated','public.csk_sec002c_table_probe',
      'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN'
    ),'Tabela utworzona przez postgres nie może automatycznie udostępniać authenticated żadnego prawa.');

  perform pg_temp.record_result(9,'NEW SEQUENCE has no automatic anon grant',
    not pg_catalog.has_sequence_privilege(
      'anon','public.csk_sec002c_sequence_probe','USAGE,SELECT,UPDATE'
    ),'Sekwencja utworzona przez postgres nie może automatycznie udostępniać anon żadnego prawa.');

  perform pg_temp.record_result(10,'NEW SEQUENCE has no automatic authenticated grant',
    not pg_catalog.has_sequence_privilege(
      'authenticated','public.csk_sec002c_sequence_probe','USAGE,SELECT,UPDATE'
    ),'Sekwencja utworzona przez postgres nie może automatycznie udostępniać authenticated żadnego prawa.');
end;
$tests$;

select (case when passed then 'ok ' else 'not ok ' end)
  ||test_order::text||' - '||test_name
  ||case when passed then '' else E'\n# '||result end
from pg_temp.test_results
order by test_order;

do $assertions$
declare v_failures text;
begin
  select pg_catalog.string_agg(test_order::text||': '||test_name,', ' order by test_order)
  into v_failures
  from pg_temp.test_results
  where passed is false;

  if v_failures is not null then
    raise exception 'SEC-002C managed-owner ACL guard failed: %',v_failures;
  end if;
end;
$assertions$;

rollback;
