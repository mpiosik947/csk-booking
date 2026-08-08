-- Additive foundation for lane/position hierarchy and public booking rules.
-- Runtime reservation, availability, pricing and calendar behaviour is unchanged.

do $preflight$
declare
  v_lane_table oid := pg_catalog.to_regclass('public.shooting_lanes');
  v_full_acl constant text[] := array[
    'DELETE', 'INSERT', 'MAINTAIN', 'REFERENCES',
    'SELECT', 'TRIGGER', 'TRUNCATE', 'UPDATE'
  ];
begin
  if not exists (
    select 1
    from supabase_migrations.schema_migrations
    where version = '20260808194442'
  ) then
    raise exception 'Preflight failed: migration 20260808194442 is not recorded.';
  end if;

  if v_lane_table is null then
    raise exception 'Preflight failed: public.shooting_lanes does not exist.';
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_class as table_record
    join pg_catalog.pg_namespace as namespace_record
      on namespace_record.oid = table_record.relnamespace
    join pg_catalog.pg_roles as owner_role
      on owner_role.oid = table_record.relowner
    where table_record.oid = v_lane_table
      and namespace_record.nspname = 'public'
      and table_record.relkind = 'r'
      and owner_role.rolname = 'postgres'
      and table_record.relrowsecurity
      and not table_record.relforcerowsecurity
  ) then
    raise exception 'Preflight failed: unexpected owner or RLS flags on shooting_lanes.';
  end if;

  if (select pg_catalog.count(*)
      from pg_catalog.pg_attribute
      where attrelid = v_lane_table and attnum > 0 and not attisdropped) <> 12
     or exists (
       with expected(name, type_name, not_null, default_expression) as (
         values
           ('id', 'uuid', true, 'gen_random_uuid()'),
           ('name', 'text', true, null),
           ('type', 'text', true, null),
           ('description', 'text', false, null),
           ('price_per_hour', 'numeric', true, '0'),
           ('is_active', 'boolean', true, 'true'),
           ('created_at', 'timestamp with time zone', false, 'now()'),
           ('max_shooters', 'integer', true, '1'),
           ('booking_step_minutes', 'integer', true, '60'),
           ('display_order', 'integer', true, '0'),
           ('currency_code', 'character(3)', true, '''PLN''::bpchar'),
           ('updated_at', 'timestamp with time zone', true, 'transaction_timestamp()')
       )
       select 1
       from expected
       left join lateral (
         select
           pg_catalog.format_type(attribute_record.atttypid, attribute_record.atttypmod) as type_name,
           attribute_record.attnotnull as not_null,
           pg_catalog.pg_get_expr(default_record.adbin, default_record.adrelid) as default_expression
         from pg_catalog.pg_attribute as attribute_record
         left join pg_catalog.pg_attrdef as default_record
           on default_record.adrelid = attribute_record.attrelid
          and default_record.adnum = attribute_record.attnum
         where attribute_record.attrelid = v_lane_table
           and attribute_record.attname = expected.name
           and attribute_record.attnum > 0
           and not attribute_record.attisdropped
       ) as actual on true
       where actual.type_name is null
          or actual.type_name is distinct from expected.type_name
          or actual.not_null is distinct from expected.not_null
          or actual.default_expression is distinct from expected.default_expression
     ) then
    raise exception 'Preflight failed: unexpected shooting_lanes column contract.';
  end if;

  if (select pg_catalog.count(*)
      from pg_catalog.pg_constraint
      where conrelid = v_lane_table) <> 5
     or not exists (
       select 1 from pg_catalog.pg_constraint
       where conrelid = v_lane_table
         and conname = 'shooting_lanes_pkey'
         and contype = 'p'
     )
     or not exists (
       select 1 from pg_catalog.pg_constraint
       where conrelid = v_lane_table
         and conname = 'shooting_lanes_max_shooters_check'
         and contype = 'c'
     )
     or not exists (
       select 1 from pg_catalog.pg_constraint
       where conrelid = v_lane_table
         and conname = 'shooting_lanes_booking_step_minutes_check'
         and contype = 'c'
     )
     or not exists (
       select 1 from pg_catalog.pg_constraint
       where conrelid = v_lane_table
         and conname = 'shooting_lanes_display_order_check'
         and contype = 'c'
     )
     or not exists (
       select 1 from pg_catalog.pg_constraint
       where conrelid = v_lane_table
         and conname = 'shooting_lanes_currency_code_check'
         and contype = 'c'
     ) then
    raise exception 'Preflight failed: unexpected shooting_lanes constraints.';
  end if;

  if (select pg_catalog.count(*)
      from pg_catalog.pg_trigger
      where tgrelid = v_lane_table and not tgisinternal) <> 1
     or not exists (
       select 1
       from pg_catalog.pg_trigger
       where tgrelid = v_lane_table
         and not tgisinternal
         and tgname = 'set_shooting_lanes_updated_at'
         and tgenabled = 'O'
         and tgfoid = 'public.set_booking_configuration_updated_at()'::pg_catalog.regprocedure
     ) then
    raise exception 'Preflight failed: unexpected shooting_lanes triggers.';
  end if;

  if pg_catalog.to_regclass('public.lane_booking_rules') is not null
     or exists (
       select 1
       from pg_catalog.pg_attribute
       where attrelid = v_lane_table
         and attname in (
           'resource_kind', 'parent_lane_id',
           'whole_lane_bookable', 'positions_bookable'
         )
         and attnum > 0
         and not attisdropped
     )
     or pg_catalog.to_regprocedure('public.validate_shooting_lane_hierarchy()') is not null
     or pg_catalog.to_regprocedure('public.validate_lane_booking_rule_capacity()') is not null
     or pg_catalog.to_regprocedure('public.validate_shooting_lane_capacity_change()') is not null
     or exists (
       select 1
       from pg_catalog.pg_constraint
       where conrelid = v_lane_table
         and conname in (
           'shooting_lanes_resource_kind_check',
           'shooting_lanes_resource_parent_check',
           'shooting_lanes_parent_not_self_check',
           'shooting_lanes_position_booking_modes_check',
           'shooting_lanes_parent_lane_id_fkey'
         )
     )
     or exists (
       select 1
       from pg_catalog.pg_trigger
       where tgrelid = v_lane_table
         and tgname in (
           'validate_shooting_lane_hierarchy_trigger',
           'validate_shooting_lane_capacity_change_trigger'
         )
     ) then
    raise exception 'Preflight failed: lane hierarchy objects already exist.';
  end if;

  if (select pg_catalog.count(*) from pg_catalog.pg_policies
      where schemaname = 'public' and tablename = 'shooting_lanes') <> 2
     or not exists (
       select 1 from pg_catalog.pg_policies
       where schemaname = 'public'
         and tablename = 'shooting_lanes'
         and policyname = 'Public can view active shooting lanes'
         and permissive = 'PERMISSIVE'
         and roles = array['public']::name[]
         and cmd = 'SELECT'
         and qual = '(is_active = true)'
         and with_check is null
     )
     or not exists (
       select 1 from pg_catalog.pg_policies
       where schemaname = 'public'
         and tablename = 'shooting_lanes'
         and policyname = 'Staff can view all shooting lanes'
         and permissive = 'PERMISSIVE'
         and roles = array['authenticated']::name[]
         and cmd = 'SELECT'
         and qual = 'is_admin_or_staff()'
         and with_check is null
     ) then
    raise exception 'Preflight failed: unexpected shooting_lanes policies.';
  end if;

  if exists (
       select 1
       from pg_catalog.pg_class as table_record
       cross join lateral pg_catalog.aclexplode(
         coalesce(table_record.relacl, pg_catalog.acldefault('r', table_record.relowner))
       ) as acl
       where table_record.oid = v_lane_table and acl.grantee = 0
     )
     or (select coalesce(pg_catalog.array_agg(acl.privilege_type order by acl.privilege_type), array[]::text[])
         from pg_catalog.pg_class as table_record
         cross join lateral pg_catalog.aclexplode(coalesce(table_record.relacl, pg_catalog.acldefault('r', table_record.relowner))) as acl
         where table_record.oid = v_lane_table
           and acl.grantee = (select oid from pg_catalog.pg_roles where rolname = 'anon'))
        is distinct from array['SELECT']::text[]
     or (select coalesce(pg_catalog.array_agg(acl.privilege_type order by acl.privilege_type), array[]::text[])
         from pg_catalog.pg_class as table_record
         cross join lateral pg_catalog.aclexplode(coalesce(table_record.relacl, pg_catalog.acldefault('r', table_record.relowner))) as acl
         where table_record.oid = v_lane_table
           and acl.grantee = (select oid from pg_catalog.pg_roles where rolname = 'authenticated'))
        is distinct from array['SELECT']::text[]
     or (select coalesce(pg_catalog.array_agg(acl.privilege_type order by acl.privilege_type), array[]::text[])
         from pg_catalog.pg_class as table_record
         cross join lateral pg_catalog.aclexplode(coalesce(table_record.relacl, pg_catalog.acldefault('r', table_record.relowner))) as acl
         where table_record.oid = v_lane_table
           and acl.grantee = (select oid from pg_catalog.pg_roles where rolname = 'service_role'))
        is distinct from v_full_acl then
    raise exception 'Preflight failed: unexpected hardened shooting_lanes ACL.';
  end if;
end;
$preflight$;

create temporary table csk_lane_hierarchy_foundation_baseline (
  lane_rows jsonb not null,
  lane_policies_hash text not null,
  lane_acl_hash text not null,
  durations_hash text not null,
  pricing_hash text not null,
  reservations_hash text not null,
  lane_blocks_hash text not null,
  event_lanes_hash text not null
);

insert into pg_temp.csk_lane_hierarchy_foundation_baseline
select
  (select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(row_record) order by row_record.id)
   from public.shooting_lanes as row_record),
  (select pg_catalog.md5(pg_catalog.string_agg(
     policyname || '|' || permissive || '|' || cmd || '|' || roles::text || '|'
       || coalesce(qual, '<null>') || '|' || coalesce(with_check, '<null>'),
     E'\n' order by policyname))
   from pg_catalog.pg_policies
   where schemaname = 'public' and tablename = 'shooting_lanes'),
  (select pg_catalog.md5(pg_catalog.string_agg(
     coalesce(grantee_role.rolname, 'PUBLIC') || '|' || acl.privilege_type || '|'
       || acl.is_grantable::text,
     E'\n' order by coalesce(grantee_role.rolname, 'PUBLIC'), acl.privilege_type))
   from pg_catalog.pg_class as table_record
   cross join lateral pg_catalog.aclexplode(
     coalesce(table_record.relacl, pg_catalog.acldefault('r', table_record.relowner))
   ) as acl
   left join pg_catalog.pg_roles as grantee_role on grantee_role.oid = acl.grantee
   where table_record.oid = 'public.shooting_lanes'::pg_catalog.regclass),
  (select pg_catalog.md5(coalesce(pg_catalog.string_agg(
     pg_catalog.md5(pg_catalog.to_jsonb(row_record)::text), E'\n' order by row_record.id), ''))
   from public.lane_booking_durations as row_record),
  (select pg_catalog.md5(coalesce(pg_catalog.string_agg(
     pg_catalog.md5(pg_catalog.to_jsonb(row_record)::text), E'\n' order by row_record.id), ''))
   from public.lane_pricing_rules as row_record),
  (select pg_catalog.md5(coalesce(pg_catalog.string_agg(
     pg_catalog.md5(pg_catalog.to_jsonb(row_record)::text), E'\n' order by row_record.id), ''))
   from public.reservations as row_record),
  (select pg_catalog.md5(coalesce(pg_catalog.string_agg(
     pg_catalog.md5(pg_catalog.to_jsonb(row_record)::text), E'\n' order by row_record.id), ''))
   from public.lane_blocks as row_record),
  (select pg_catalog.md5(coalesce(pg_catalog.string_agg(
     pg_catalog.md5(pg_catalog.to_jsonb(row_record)::text), E'\n'
       order by row_record.event_id, row_record.lane_id), ''))
   from public.event_lanes as row_record);

alter table public.shooting_lanes
  add column resource_kind text not null default 'lane',
  add column parent_lane_id uuid,
  add column whole_lane_bookable boolean not null default true,
  add column positions_bookable boolean not null default false;

alter table public.shooting_lanes
  alter column resource_kind drop default,
  alter column whole_lane_bookable set default false,
  add constraint shooting_lanes_resource_kind_check
    check (resource_kind in ('lane', 'position')),
  add constraint shooting_lanes_resource_parent_check
    check (
      (resource_kind = 'lane' and parent_lane_id is null)
      or (resource_kind = 'position' and parent_lane_id is not null)
    ),
  add constraint shooting_lanes_parent_not_self_check
    check (parent_lane_id is null or parent_lane_id <> id),
  add constraint shooting_lanes_position_booking_modes_check
    check (
      resource_kind <> 'position'
      or (not whole_lane_bookable and not positions_bookable)
    ),
  add constraint shooting_lanes_parent_lane_id_fkey
    foreign key (parent_lane_id)
    references public.shooting_lanes(id)
    on delete restrict;

create index shooting_lanes_parent_lane_id_idx
on public.shooting_lanes(parent_lane_id)
where parent_lane_id is not null;

create function public.validate_shooting_lane_hierarchy()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $function$
declare
  v_parent_kind text;
  v_parent_parent_id uuid;
begin
  if new.resource_kind = 'position' then
    if new.parent_lane_id is null or new.parent_lane_id = new.id then
      raise exception 'Position requires a different lane parent.'
        using errcode = '23514',
              constraint = 'shooting_lanes_resource_parent_check';
    end if;

    select parent.resource_kind, parent.parent_lane_id
    into v_parent_kind, v_parent_parent_id
    from public.shooting_lanes as parent
    where parent.id = new.parent_lane_id
    for update;

    if not found then
      raise exception 'Parent shooting lane does not exist.'
        using errcode = '23503',
              constraint = 'shooting_lanes_parent_lane_id_fkey';
    end if;

    if v_parent_kind <> 'lane' or v_parent_parent_id is not null then
      raise exception 'Position parent must be a top-level lane.'
        using errcode = '23514',
              constraint = 'shooting_lanes_parent_structure_check';
    end if;

    if exists (
      select 1
      from public.shooting_lanes as child
      where child.parent_lane_id = new.id
        and child.id <> new.id
    ) then
      raise exception 'A lane with children cannot become a position.'
        using errcode = '23514',
              constraint = 'shooting_lanes_parent_structure_check';
    end if;
  end if;

  return new;
end;
$function$;

alter function public.validate_shooting_lane_hierarchy() owner to postgres;
revoke all on function public.validate_shooting_lane_hierarchy() from public;
revoke all on function public.validate_shooting_lane_hierarchy() from anon;
revoke all on function public.validate_shooting_lane_hierarchy() from authenticated;
grant execute on function public.validate_shooting_lane_hierarchy() to service_role;

create trigger validate_shooting_lane_hierarchy_trigger
before insert or update of resource_kind, parent_lane_id
on public.shooting_lanes
for each row
execute function public.validate_shooting_lane_hierarchy();

create table public.lane_booking_rules (
  lane_id uuid primary key,
  online_bookable boolean not null default false,
  max_people_online integer not null,
  created_at timestamptz not null default pg_catalog.transaction_timestamp(),
  updated_at timestamptz not null default pg_catalog.transaction_timestamp(),
  constraint lane_booking_rules_lane_id_fkey
    foreign key (lane_id)
    references public.shooting_lanes(id)
    on delete restrict,
  constraint lane_booking_rules_max_people_online_check
    check (max_people_online >= 1)
);

alter table public.lane_booking_rules owner to postgres;

comment on column public.shooting_lanes.resource_kind is
  'Structural resource kind: lane for a top-level resource or position for its direct child.';
comment on column public.shooting_lanes.parent_lane_id is
  'Direct top-level lane parent for a position; NULL for lane resources.';
comment on column public.shooting_lanes.whole_lane_bookable is
  'Whether the top-level lane supports whole-resource sales; always false for positions.';
comment on column public.shooting_lanes.positions_bookable is
  'Whether the top-level lane supports child-position sales; always false for positions.';

comment on table public.lane_booking_rules is
  'Public booking publication and online capacity for each lane or position resource.';
comment on column public.lane_booking_rules.online_bookable is
  'Whether the resource is published for public online booking.';
comment on column public.lane_booking_rules.max_people_online is
  'Maximum people accepted online; never greater than shooting_lanes.max_shooters.';

create function public.validate_lane_booking_rule_capacity()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $function$
declare
  v_max_shooters integer;
begin
  select lane.max_shooters
  into v_max_shooters
  from public.shooting_lanes as lane
  where lane.id = new.lane_id
  for update;

  if not found then
    raise exception 'Shooting lane does not exist.'
      using errcode = '23503',
            constraint = 'lane_booking_rules_lane_id_fkey';
  end if;

  if new.max_people_online > v_max_shooters then
    raise exception 'Online capacity exceeds physical lane capacity.'
      using errcode = '23514',
            constraint = 'lane_booking_rules_capacity_check';
  end if;

  return new;
end;
$function$;

alter function public.validate_lane_booking_rule_capacity() owner to postgres;
revoke all on function public.validate_lane_booking_rule_capacity() from public;
revoke all on function public.validate_lane_booking_rule_capacity() from anon;
revoke all on function public.validate_lane_booking_rule_capacity() from authenticated;
grant execute on function public.validate_lane_booking_rule_capacity() to service_role;

create trigger validate_lane_booking_rule_capacity_trigger
before insert or update of lane_id, max_people_online
on public.lane_booking_rules
for each row
execute function public.validate_lane_booking_rule_capacity();

create function public.validate_shooting_lane_capacity_change()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $function$
declare
  v_max_people_online integer;
begin
  select rule.max_people_online
  into v_max_people_online
  from public.lane_booking_rules as rule
  where rule.lane_id = new.id
  for update;

  if found and v_max_people_online > new.max_shooters then
    raise exception 'Physical lane capacity cannot be lower than online capacity.'
      using errcode = '23514',
            constraint = 'lane_booking_rules_capacity_check';
  end if;

  return new;
end;
$function$;

alter function public.validate_shooting_lane_capacity_change() owner to postgres;
revoke all on function public.validate_shooting_lane_capacity_change() from public;
revoke all on function public.validate_shooting_lane_capacity_change() from anon;
revoke all on function public.validate_shooting_lane_capacity_change() from authenticated;
grant execute on function public.validate_shooting_lane_capacity_change() to service_role;

create trigger validate_shooting_lane_capacity_change_trigger
before update of max_shooters
on public.shooting_lanes
for each row
execute function public.validate_shooting_lane_capacity_change();

create trigger set_lane_booking_rules_updated_at
before update on public.lane_booking_rules
for each row
execute function public.set_booking_configuration_updated_at();

insert into public.lane_booking_rules (
  lane_id,
  online_bookable,
  max_people_online
)
select lane.id, lane.is_active, lane.max_shooters
from public.shooting_lanes as lane;

alter table public.lane_booking_rules enable row level security;

revoke all privileges on table public.lane_booking_rules from public;
revoke all privileges on table public.lane_booking_rules from anon;
revoke all privileges on table public.lane_booking_rules from authenticated;

grant select on table public.lane_booking_rules to anon;
grant select on table public.lane_booking_rules to authenticated;
grant all privileges on table public.lane_booking_rules to service_role;

create policy "Public can view online lane booking rules"
on public.lane_booking_rules
for select
to anon, authenticated
using (
  online_bookable
  and exists (
    select 1
    from public.shooting_lanes as lane
    where lane.id = lane_booking_rules.lane_id
      and lane.is_active
      and (
        (lane.resource_kind = 'lane' and lane.whole_lane_bookable)
        or (
          lane.resource_kind = 'position'
          and exists (
            select 1
            from public.shooting_lanes as parent
            where parent.id = lane.parent_lane_id
              and parent.resource_kind = 'lane'
              and parent.parent_lane_id is null
              and parent.is_active
              and parent.positions_bookable
          )
        )
      )
  )
);

create policy "Staff can view all lane booking rules"
on public.lane_booking_rules
for select
to authenticated
using (public.is_admin_or_staff());

do $postflight$
declare
  v_rule_table oid := pg_catalog.to_regclass('public.lane_booking_rules');
  v_full_acl constant text[] := array[
    'DELETE', 'INSERT', 'MAINTAIN', 'REFERENCES',
    'SELECT', 'TRIGGER', 'TRUNCATE', 'UPDATE'
  ];
begin
  if v_rule_table is null then
    raise exception 'Postflight failed: lane_booking_rules does not exist.';
  end if;

  if exists (
       select 1 from public.shooting_lanes
       where resource_kind <> 'lane'
          or parent_lane_id is not null
          or not whole_lane_bookable
          or positions_bookable
     )
     or exists (
       select 1
       from pg_temp.csk_lane_hierarchy_foundation_baseline as baseline
       where baseline.lane_rows is distinct from (
         select pg_catalog.jsonb_agg(
           pg_catalog.to_jsonb(lane)
             - 'resource_kind'
             - 'parent_lane_id'
             - 'whole_lane_bookable'
             - 'positions_bookable'
           order by lane.id
         )
         from public.shooting_lanes as lane
       )
     ) then
    raise exception 'Postflight failed: existing shooting_lanes were not preserved.';
  end if;

  if (select pg_catalog.count(*)
      from information_schema.columns
      where table_schema = 'public' and table_name = 'shooting_lanes') <> 16
     or not exists (
       select 1 from information_schema.columns
       where table_schema = 'public' and table_name = 'shooting_lanes'
         and column_name = 'resource_kind' and data_type = 'text'
         and is_nullable = 'NO' and column_default is null
     )
     or not exists (
       select 1 from information_schema.columns
       where table_schema = 'public' and table_name = 'shooting_lanes'
         and column_name = 'parent_lane_id' and data_type = 'uuid'
         and is_nullable = 'YES' and column_default is null
     )
     or not exists (
       select 1 from information_schema.columns
       where table_schema = 'public' and table_name = 'shooting_lanes'
         and column_name = 'whole_lane_bookable' and data_type = 'boolean'
         and is_nullable = 'NO' and column_default = 'false'
     )
     or not exists (
       select 1 from information_schema.columns
       where table_schema = 'public' and table_name = 'shooting_lanes'
         and column_name = 'positions_bookable' and data_type = 'boolean'
         and is_nullable = 'NO' and column_default = 'false'
     ) then
    raise exception 'Postflight failed: shooting_lanes hierarchy columns are invalid.';
  end if;

  if (select pg_catalog.count(*) from public.lane_booking_rules)
       <> (select pg_catalog.count(*) from public.shooting_lanes)
     or exists (
       select 1
       from public.shooting_lanes as lane
       left join public.lane_booking_rules as rule on rule.lane_id = lane.id
       where rule.lane_id is null
          or rule.max_people_online <> lane.max_shooters
          or rule.online_bookable <> lane.is_active
     )
     or exists (select 1 from public.shooting_lanes where resource_kind = 'position') then
    raise exception 'Postflight failed: booking rules backfill is invalid.';
  end if;

  if (select pg_catalog.count(*) from information_schema.columns
      where table_schema = 'public' and table_name = 'lane_booking_rules') <> 5
     or not exists (
       select 1
       from pg_catalog.pg_class as table_record
       join pg_catalog.pg_roles as owner_role on owner_role.oid = table_record.relowner
       where table_record.oid = v_rule_table
         and owner_role.rolname = 'postgres'
         and table_record.relrowsecurity
         and not table_record.relforcerowsecurity
     ) then
    raise exception 'Postflight failed: lane_booking_rules structure or RLS flags are invalid.';
  end if;

  if (select pg_catalog.count(*) from pg_catalog.pg_policies
      where schemaname = 'public' and tablename = 'lane_booking_rules') <> 2
     or exists (
       select 1 from pg_catalog.pg_policies
       where schemaname = 'public'
         and tablename = 'lane_booking_rules'
         and cmd <> 'SELECT'
     )
     or not exists (
       select 1 from pg_catalog.pg_policies
       where schemaname = 'public'
         and tablename = 'lane_booking_rules'
         and policyname = 'Public can view online lane booking rules'
         and roles = array['anon', 'authenticated']::name[]
         and cmd = 'SELECT'
         and with_check is null
     )
     or not exists (
       select 1 from pg_catalog.pg_policies
       where schemaname = 'public'
         and tablename = 'lane_booking_rules'
         and policyname = 'Staff can view all lane booking rules'
         and roles = array['authenticated']::name[]
         and cmd = 'SELECT'
         and qual = 'is_admin_or_staff()'
         and with_check is null
     ) then
    raise exception 'Postflight failed: lane_booking_rules policies are invalid.';
  end if;

  if exists (
       select 1
       from pg_catalog.pg_class as table_record
       cross join lateral pg_catalog.aclexplode(
         coalesce(table_record.relacl, pg_catalog.acldefault('r', table_record.relowner))
       ) as acl
       where table_record.oid = v_rule_table and acl.grantee = 0
     )
     or (select coalesce(pg_catalog.array_agg(acl.privilege_type order by acl.privilege_type), array[]::text[])
         from pg_catalog.pg_class as table_record
         cross join lateral pg_catalog.aclexplode(coalesce(table_record.relacl, pg_catalog.acldefault('r', table_record.relowner))) as acl
         where table_record.oid = v_rule_table
           and acl.grantee = (select oid from pg_catalog.pg_roles where rolname = 'anon'))
        is distinct from array['SELECT']::text[]
     or (select coalesce(pg_catalog.array_agg(acl.privilege_type order by acl.privilege_type), array[]::text[])
         from pg_catalog.pg_class as table_record
         cross join lateral pg_catalog.aclexplode(coalesce(table_record.relacl, pg_catalog.acldefault('r', table_record.relowner))) as acl
         where table_record.oid = v_rule_table
           and acl.grantee = (select oid from pg_catalog.pg_roles where rolname = 'authenticated'))
        is distinct from array['SELECT']::text[]
     or (select coalesce(pg_catalog.array_agg(acl.privilege_type order by acl.privilege_type), array[]::text[])
         from pg_catalog.pg_class as table_record
         cross join lateral pg_catalog.aclexplode(coalesce(table_record.relacl, pg_catalog.acldefault('r', table_record.relowner))) as acl
         where table_record.oid = v_rule_table
           and acl.grantee = (select oid from pg_catalog.pg_roles where rolname = 'service_role'))
        is distinct from v_full_acl then
    raise exception 'Postflight failed: lane_booking_rules ACL is invalid.';
  end if;

  if exists (
    select 1
    from pg_temp.csk_lane_hierarchy_foundation_baseline as baseline
    where baseline.lane_policies_hash is distinct from (
      select pg_catalog.md5(pg_catalog.string_agg(
        policyname || '|' || permissive || '|' || cmd || '|' || roles::text || '|'
          || coalesce(qual, '<null>') || '|' || coalesce(with_check, '<null>'),
        E'\n' order by policyname))
      from pg_catalog.pg_policies
      where schemaname = 'public' and tablename = 'shooting_lanes'
    )
       or baseline.lane_acl_hash is distinct from (
         select pg_catalog.md5(pg_catalog.string_agg(
           coalesce(grantee_role.rolname, 'PUBLIC') || '|' || acl.privilege_type || '|'
             || acl.is_grantable::text,
           E'\n' order by coalesce(grantee_role.rolname, 'PUBLIC'), acl.privilege_type))
         from pg_catalog.pg_class as table_record
         cross join lateral pg_catalog.aclexplode(
           coalesce(table_record.relacl, pg_catalog.acldefault('r', table_record.relowner))
         ) as acl
         left join pg_catalog.pg_roles as grantee_role on grantee_role.oid = acl.grantee
         where table_record.oid = 'public.shooting_lanes'::pg_catalog.regclass
       )
       or baseline.durations_hash is distinct from (
         select pg_catalog.md5(coalesce(pg_catalog.string_agg(
           pg_catalog.md5(pg_catalog.to_jsonb(row_record)::text), E'\n' order by row_record.id), ''))
         from public.lane_booking_durations as row_record
       )
       or baseline.pricing_hash is distinct from (
         select pg_catalog.md5(coalesce(pg_catalog.string_agg(
           pg_catalog.md5(pg_catalog.to_jsonb(row_record)::text), E'\n' order by row_record.id), ''))
         from public.lane_pricing_rules as row_record
       )
       or baseline.reservations_hash is distinct from (
         select pg_catalog.md5(coalesce(pg_catalog.string_agg(
           pg_catalog.md5(pg_catalog.to_jsonb(row_record)::text), E'\n' order by row_record.id), ''))
         from public.reservations as row_record
       )
       or baseline.lane_blocks_hash is distinct from (
         select pg_catalog.md5(coalesce(pg_catalog.string_agg(
           pg_catalog.md5(pg_catalog.to_jsonb(row_record)::text), E'\n' order by row_record.id), ''))
         from public.lane_blocks as row_record
       )
       or baseline.event_lanes_hash is distinct from (
         select pg_catalog.md5(coalesce(pg_catalog.string_agg(
           pg_catalog.md5(pg_catalog.to_jsonb(row_record)::text), E'\n'
             order by row_record.event_id, row_record.lane_id), ''))
         from public.event_lanes as row_record
       )
  ) then
    raise exception 'Postflight failed: existing ACL, policies or business tables changed.';
  end if;
end;
$postflight$;

drop table pg_temp.csk_lane_hierarchy_foundation_baseline;
