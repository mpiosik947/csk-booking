-- Ownership-scoped read contract for /my-reservations, including inactive
-- hierarchy resources without widening table RLS or table grants.
create temporary table csk_my_reservations_v2_security_baseline (
  policies_hash text not null,
  table_acl_hash text not null
) on commit drop;

insert into pg_temp.csk_my_reservations_v2_security_baseline (
  policies_hash,
  table_acl_hash
)
select
  (
    select pg_catalog.md5(coalesce(pg_catalog.string_agg(
      policy.polrelid::text || ':' || policy.polname || ':' ||
      policy.polcmd::text || ':' || policy.polroles::text || ':' ||
      coalesce(pg_catalog.pg_get_expr(policy.polqual, policy.polrelid), '') || ':' ||
      coalesce(pg_catalog.pg_get_expr(policy.polwithcheck, policy.polrelid), ''),
      E'\n' order by policy.polrelid, policy.polname
    ), ''))
    from pg_catalog.pg_policy as policy
    where policy.polrelid in (
      'public.reservations'::pg_catalog.regclass,
      'public.shooting_lanes'::pg_catalog.regclass
    )
  ),
  (
    select pg_catalog.md5(coalesce(pg_catalog.string_agg(
      relation.oid::text || ':' || acl.grantee::text || ':' ||
      acl.grantor::text || ':' || acl.privilege_type || ':' ||
      acl.is_grantable::text,
      E'\n' order by relation.oid, acl.grantee, acl.privilege_type
    ), ''))
    from pg_catalog.pg_class as relation
    cross join lateral pg_catalog.aclexplode(
      coalesce(
        relation.relacl,
        pg_catalog.acldefault('r', relation.relowner)
      )
    ) as acl
    where relation.oid in (
      'public.reservations'::pg_catalog.regclass,
      'public.shooting_lanes'::pg_catalog.regclass
    )
  );

do $preflight$
declare
  v_required_columns constant jsonb := $json$
  [
    {"table":"reservations","column":"id","type":"uuid"},
    {"table":"reservations","column":"user_id","type":"uuid"},
    {"table":"reservations","column":"lane_id","type":"uuid"},
    {"table":"reservations","column":"reservation_date","type":"date"},
    {"table":"reservations","column":"start_time","type":"time without time zone"},
    {"table":"reservations","column":"end_time","type":"time without time zone"},
    {"table":"reservations","column":"price","type":"numeric"},
    {"table":"reservations","column":"reservation_status","type":"text"},
    {"table":"reservations","column":"payment_status","type":"text"},
    {"table":"reservations","column":"check_in_token","type":"uuid"},
    {"table":"reservations","column":"attendance_status","type":"text"},
    {"table":"reservations","column":"checked_in_at","type":"timestamp with time zone"},
    {"table":"shooting_lanes","column":"id","type":"uuid"},
    {"table":"shooting_lanes","column":"name","type":"text"},
    {"table":"shooting_lanes","column":"resource_kind","type":"text"},
    {"table":"shooting_lanes","column":"parent_lane_id","type":"uuid"}
  ]
  $json$::jsonb;
begin
  if pg_catalog.to_regclass('public.reservations') is null
     or pg_catalog.to_regclass('public.shooting_lanes') is null
     or pg_catalog.to_regprocedure('auth.uid()') is null then
    raise exception 'My reservations V2 preflight failed: required objects are missing.';
  end if;

  if exists (
    select 1
    from pg_catalog.jsonb_array_elements(v_required_columns) as expected
    where not exists (
      select 1
      from information_schema.columns as actual
      where actual.table_schema = 'public'
        and actual.table_name = expected->>'table'
        and actual.column_name = expected->>'column'
        and actual.data_type = expected->>'type'
    )
  ) then
    raise exception 'My reservations V2 preflight failed: source column contract differs.';
  end if;

  if (
    select pg_catalog.count(*)
    from pg_catalog.pg_class as relation
    join pg_catalog.pg_namespace as namespace
      on namespace.oid = relation.relnamespace
    join pg_catalog.pg_roles as owner_role
      on owner_role.oid = relation.relowner
    where namespace.nspname = 'public'
      and relation.relname in ('reservations', 'shooting_lanes')
      and relation.relkind = 'r'
      and relation.relrowsecurity
      and not relation.relforcerowsecurity
      and owner_role.rolname = 'postgres'
  ) <> 2 then
    raise exception 'My reservations V2 preflight failed: owner or RLS flags differ.';
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_policy as policy
    where policy.polrelid = 'public.reservations'::pg_catalog.regclass
      and policy.polname = 'Users can view own reservations'
      and policy.polcmd = 'r'
      and policy.polroles = array['authenticated'::pg_catalog.regrole::oid]
      and pg_catalog.pg_get_expr(policy.polqual, policy.polrelid) =
          '(user_id = auth.uid())'
      and policy.polwithcheck is null
  ) or not exists (
    select 1
    from pg_catalog.pg_policy as policy
    where policy.polrelid = 'public.shooting_lanes'::pg_catalog.regclass
      and policy.polname = 'Public can view active shooting lanes'
      and policy.polcmd = 'r'
      and policy.polroles = array[0::oid]
      and pg_catalog.pg_get_expr(policy.polqual, policy.polrelid) =
          '(is_active = true)'
      and policy.polwithcheck is null
  ) then
    raise exception 'My reservations V2 preflight failed: ownership or lane visibility policy differs.';
  end if;

  if pg_catalog.to_regprocedure('public.get_my_reservations_v2()') is not null
     or exists (
       select 1
       from pg_catalog.pg_proc as procedure
       join pg_catalog.pg_namespace as namespace
         on namespace.oid = procedure.pronamespace
       where namespace.nspname = 'public'
         and procedure.proname = 'get_my_reservations_v2'
     ) then
    raise exception 'My reservations V2 preflight failed: RPC already exists.';
  end if;
end;
$preflight$;

create function public.get_my_reservations_v2()
returns table (
  id uuid,
  reservation_date date,
  start_time time without time zone,
  end_time time without time zone,
  price numeric,
  reservation_status text,
  payment_status text,
  check_in_token uuid,
  attendance_status text,
  checked_in_at timestamp with time zone,
  lane_display_name text
)
language plpgsql
stable
security definer
set search_path = pg_catalog, public, pg_temp
as $function$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception 'Authentication is required.'
      using errcode = '42501';
  end if;

  return query
  select
    reservation.id,
    reservation.reservation_date,
    reservation.start_time,
    reservation.end_time,
    reservation.price,
    reservation.reservation_status,
    reservation.payment_status,
    reservation.check_in_token,
    reservation.attendance_status,
    reservation.checked_in_at,
    case
      when lane.resource_kind = 'lane'
       and lane.parent_lane_id is null
       and pg_catalog.btrim(lane.name) <> ''
        then lane.name
      when lane.resource_kind = 'position'
       and lane.parent_lane_id is not null
       and parent.id = lane.parent_lane_id
       and parent.resource_kind = 'lane'
       and parent.parent_lane_id is null
       and pg_catalog.btrim(parent.name) <> ''
       and pg_catalog.btrim(lane.name) <> ''
        then parent.name || ' — ' || lane.name
      else null
    end as lane_display_name
  from public.reservations as reservation
  left join public.shooting_lanes as lane
    on lane.id = reservation.lane_id
  left join public.shooting_lanes as parent
    on parent.id = lane.parent_lane_id
  where reservation.user_id = v_user_id
  order by reservation.reservation_date desc,
           reservation.start_time desc,
           reservation.id desc;
end;
$function$;

alter function public.get_my_reservations_v2() owner to postgres;

comment on function public.get_my_reservations_v2() is
  'Returns only auth.uid() reservations with an ownership-scoped hierarchy label, including inactive resources.';

revoke all on function public.get_my_reservations_v2() from public;
revoke all on function public.get_my_reservations_v2() from anon;
revoke all on function public.get_my_reservations_v2() from authenticated;
revoke all on function public.get_my_reservations_v2() from service_role;
grant execute on function public.get_my_reservations_v2() to authenticated;

do $postflight$
declare
  v_policies_hash text;
  v_table_acl_hash text;
  v_definition text;
begin
  if pg_catalog.to_regprocedure('public.get_my_reservations_v2()') is null
     or (
       select pg_catalog.count(*)
       from pg_catalog.pg_proc as procedure
       join pg_catalog.pg_namespace as namespace
         on namespace.oid = procedure.pronamespace
       where namespace.nspname = 'public'
         and procedure.proname = 'get_my_reservations_v2'
     ) <> 1 then
    raise exception 'My reservations V2 postflight failed: exact RPC is missing or overloaded.';
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_proc as procedure
    join pg_catalog.pg_roles as owner_role
      on owner_role.oid = procedure.proowner
    join pg_catalog.pg_language as language
      on language.oid = procedure.prolang
    where procedure.oid =
          'public.get_my_reservations_v2()'::pg_catalog.regprocedure
      and procedure.prosecdef
      and procedure.provolatile = 's'
      and procedure.proconfig =
          array['search_path=pg_catalog, public, pg_temp']::text[]
      and owner_role.rolname = 'postgres'
      and language.lanname = 'plpgsql'
      and pg_catalog.pg_get_function_identity_arguments(procedure.oid) = ''
      and (
        select pg_catalog.jsonb_agg(
          pg_catalog.jsonb_build_array(
            procedure.proargnames[argument_index],
            pg_catalog.format_type(
              procedure.proallargtypes[argument_index], null
            )
          )
          order by argument_index
        )
        from pg_catalog.generate_subscripts(
          procedure.proargnames, 1
        ) as argument_index
        where procedure.proargmodes[argument_index] = 't'
      ) = $json$[
        ["id", "uuid"],
        ["reservation_date", "date"],
        ["start_time", "time without time zone"],
        ["end_time", "time without time zone"],
        ["price", "numeric"],
        ["reservation_status", "text"],
        ["payment_status", "text"],
        ["check_in_token", "uuid"],
        ["attendance_status", "text"],
        ["checked_in_at", "timestamp with time zone"],
        ["lane_display_name", "text"]
      ]$json$::jsonb
  ) then
    raise exception 'My reservations V2 postflight failed: security properties differ.';
  end if;

  if not pg_catalog.has_function_privilege(
       'authenticated', 'public.get_my_reservations_v2()', 'EXECUTE'
     )
     or pg_catalog.has_function_privilege(
       'anon', 'public.get_my_reservations_v2()', 'EXECUTE'
     )
     or pg_catalog.has_function_privilege(
       'service_role', 'public.get_my_reservations_v2()', 'EXECUTE'
     )
     or exists (
       select 1
       from pg_catalog.pg_proc as procedure
       cross join lateral pg_catalog.aclexplode(
         coalesce(
           procedure.proacl,
           pg_catalog.acldefault('f', procedure.proowner)
         )
       ) as acl
       where procedure.oid =
             'public.get_my_reservations_v2()'::pg_catalog.regprocedure
         and acl.grantee = 0
         and acl.privilege_type = 'EXECUTE'
     ) then
    raise exception 'My reservations V2 postflight failed: EXECUTE ACL differs.';
  end if;

  select pg_catalog.pg_get_functiondef(
    'public.get_my_reservations_v2()'::pg_catalog.regprocedure
  ) into v_definition;

  if v_definition !~ 'auth\.uid\(\)'
     or v_definition !~ 'reservation\.user_id = v_user_id'
     or v_definition ~* '\mexecute\M'
     or v_definition ~* '\mformat\s*\('
     or v_definition ~* '\m(insert|update|delete|merge|truncate|alter|drop|grant|revoke)\M'
     or v_definition ~* 'customer_(name|email|phone)'
     or v_definition ~* '\madmin_note\M'
     or v_definition ~* '\mreservation_note\M' then
    raise exception 'My reservations V2 postflight failed: definition is not ownership-scoped or minimal.';
  end if;

  select pg_catalog.md5(coalesce(pg_catalog.string_agg(
    policy.polrelid::text || ':' || policy.polname || ':' ||
    policy.polcmd::text || ':' || policy.polroles::text || ':' ||
    coalesce(pg_catalog.pg_get_expr(policy.polqual, policy.polrelid), '') || ':' ||
    coalesce(pg_catalog.pg_get_expr(policy.polwithcheck, policy.polrelid), ''),
    E'\n' order by policy.polrelid, policy.polname
  ), ''))
  into v_policies_hash
  from pg_catalog.pg_policy as policy
  where policy.polrelid in (
    'public.reservations'::pg_catalog.regclass,
    'public.shooting_lanes'::pg_catalog.regclass
  );

  select pg_catalog.md5(coalesce(pg_catalog.string_agg(
    relation.oid::text || ':' || acl.grantee::text || ':' ||
    acl.grantor::text || ':' || acl.privilege_type || ':' ||
    acl.is_grantable::text,
    E'\n' order by relation.oid, acl.grantee, acl.privilege_type
  ), ''))
  into v_table_acl_hash
  from pg_catalog.pg_class as relation
  cross join lateral pg_catalog.aclexplode(
    coalesce(
      relation.relacl,
      pg_catalog.acldefault('r', relation.relowner)
    )
  ) as acl
  where relation.oid in (
    'public.reservations'::pg_catalog.regclass,
    'public.shooting_lanes'::pg_catalog.regclass
  );

  if not exists (
    select 1
    from pg_temp.csk_my_reservations_v2_security_baseline as baseline
    where baseline.policies_hash = v_policies_hash
      and baseline.table_acl_hash = v_table_acl_hash
  ) then
    raise exception 'My reservations V2 postflight failed: existing RLS or table ACL changed.';
  end if;
end;
$postflight$;

drop table pg_temp.csk_my_reservations_v2_security_baseline;
