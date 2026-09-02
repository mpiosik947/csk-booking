-- SEC-002: fail closed for current and future public-schema tables and sequences.
-- Client roles receive only the explicit table privileges required by existing RLS contracts.

alter default privileges for role postgres in schema public
  revoke all privileges on tables from public, anon, authenticated;

alter default privileges for role postgres in schema public
  revoke all privileges on sequences from public, anon, authenticated;

-- Remove inherited baseline grants, including TRUNCATE, REFERENCES, TRIGGER and MAINTAIN.
revoke all privileges on all tables in schema public from public, anon, authenticated;
revoke all privileges on all sequences in schema public from public, anon, authenticated;

-- Public catalogue data used by anonymous and signed-in application flows.
grant select on table
  public.events,
  public.lane_booking_durations,
  public.lane_booking_rules,
  public.lane_pricing_rules,
  public.shooting_lanes
to anon, authenticated;

-- Signed-in reads protected by row-level security.
grant select on table
  public.audit_logs,
  public.event_lanes,
  public.event_registrations,
  public.lane_blocks,
  public.profiles,
  public.reservations
to authenticated;

-- Mutations retained only where an existing authenticated RLS policy requires them.
grant insert on table public.audit_logs to authenticated;
grant insert, update on table public.profiles to authenticated;
grant insert, delete on table public.event_registrations to authenticated;
grant delete on table public.reservations to authenticated;
