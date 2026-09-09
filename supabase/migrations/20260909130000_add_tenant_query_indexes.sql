-- SAAS-9B-3B: minimal tenant-prefixed query/FK support indexes.

set lock_timeout = '5s';
set statement_timeout = '120s';

do $preflight$
declare
  v_expected text[][] := array[
    array['shooting_lanes','tenant_id,parent_lane_id,display_order,id'],
    array['reservations','tenant_id,reservation_date,start_time,id'],
    array['lane_blocks','tenant_id,block_date,lane_id,is_active,start_time,end_time'],
    array['events','tenant_id,is_active,event_date,start_time,id'],
    array['event_lanes','tenant_id,event_id,lane_id'],
    array['event_registrations','tenant_id,user_id,created_at,id'],
    array['audit_logs','tenant_id,created_at,id']
  ];
  v_item text[];
  v_columns text[];
begin
  foreach v_item slice 1 in array v_expected loop
    v_columns := pg_catalog.string_to_array(v_item[2], ',');
    if exists (
      select 1
      from pg_catalog.pg_index index_record
      join pg_catalog.pg_class relation on relation.oid=index_record.indrelid
      join pg_catalog.pg_namespace namespace on namespace.oid=relation.relnamespace
      where namespace.nspname='public' and relation.relname=v_item[1]
        and (select pg_catalog.array_agg(attribute.attname::text order by key_position.ordinality)
             from pg_catalog.unnest(index_record.indkey::smallint[]) with ordinality key_position(attnum,ordinality)
             join pg_catalog.pg_attribute attribute on attribute.attrelid=relation.oid and attribute.attnum=key_position.attnum
             where key_position.ordinality <= index_record.indnkeyatts)[1:pg_catalog.array_length(v_columns,1)] = v_columns
    ) then
      raise exception 'SAAS-9B-3B preflight failed: planned index for % is already left-prefix covered.', v_item[1];
    end if;
  end loop;
end;
$preflight$;

create index shooting_lanes_tenant_hierarchy_order_idx
  on public.shooting_lanes(tenant_id,parent_lane_id,display_order,id);
create index reservations_tenant_schedule_idx
  on public.reservations(tenant_id,reservation_date,start_time,id);
create index lane_blocks_tenant_schedule_idx
  on public.lane_blocks(tenant_id,block_date,lane_id,is_active,start_time,end_time);
create index events_tenant_active_schedule_idx
  on public.events(tenant_id,is_active,event_date,start_time,id);
create index event_lanes_tenant_event_lane_idx
  on public.event_lanes(tenant_id,event_id,lane_id);
create index event_registrations_tenant_user_created_idx
  on public.event_registrations(tenant_id,user_id,created_at desc,id);
create index audit_logs_tenant_created_idx
  on public.audit_logs(tenant_id,created_at desc,id)
  where tenant_id is not null;

do $postflight$
begin
  if (select pg_catalog.count(*) from pg_catalog.pg_indexes
      where schemaname='public' and indexname in (
        'shooting_lanes_tenant_hierarchy_order_idx','reservations_tenant_schedule_idx',
        'lane_blocks_tenant_schedule_idx','events_tenant_active_schedule_idx',
        'event_lanes_tenant_event_lane_idx','event_registrations_tenant_user_created_idx',
        'audit_logs_tenant_created_idx'
      )) <> 7 then
    raise exception 'SAAS-9B-3B postflight failed: expected exactly seven tenant indexes.';
  end if;
end;
$postflight$;
