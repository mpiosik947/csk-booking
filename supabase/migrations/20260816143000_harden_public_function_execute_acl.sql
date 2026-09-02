-- SEC-002: make function execution fail closed for current and future public-schema functions.
-- Application RPCs retain their existing explicit grants; only unintended generic exposure is removed.

-- PostgreSQL's built-in function default grants EXECUTE to PUBLIC globally.
-- A per-schema default cannot subtract that global grant, so PUBLIC must be
-- revoked at the creator-role level. Application RPC grants stay explicit.
alter default privileges for role postgres
  revoke execute on functions from public;

alter default privileges for role postgres in schema public
  revoke execute on functions from anon, authenticated, service_role;

-- PUBLIC and anon must not inherit blanket access to existing functions.
revoke execute on all functions in schema public from public, anon;

-- The only intentionally anonymous RPC is the non-PII public booking configuration reader.
grant execute on function public.get_public_booking_configuration_v1()
  to anon, authenticated, service_role;

-- Trigger functions are invoked only by their bound triggers. They are not RPCs.
revoke execute on function
  public.handle_new_user(),
  public.lock_lane_booking_configuration(),
  public.prevent_non_admin_profile_privilege_changes(),
  public.set_booking_configuration_updated_at(),
  public.set_updated_at(),
  public.validate_lane_booking_rule_capacity(),
  public.validate_shooting_lane_capacity_change(),
  public.validate_shooting_lane_hierarchy()
from anon, authenticated, service_role;

-- RLS role helpers are needed by authenticated policies, not by the bypassing service role.
revoke execute on function
  public.get_my_role(),
  public.is_admin(),
  public.is_admin_or_employee(),
  public.is_admin_or_staff()
from service_role;

grant execute on function
  public.get_my_role(),
  public.is_admin(),
  public.is_admin_or_employee(),
  public.is_admin_or_staff()
to authenticated;
