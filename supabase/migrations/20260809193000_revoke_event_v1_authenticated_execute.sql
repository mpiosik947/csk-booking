-- Keep Event RPC V1 available only as an administrative rollback path.
revoke execute on function public.admin_create_event(
  text, text, date, time without time zone, time without time zone,
  text, numeric, integer, uuid[]
) from authenticated;

revoke execute on function public.admin_update_event(
  uuid, text, text, date, time without time zone, time without time zone,
  text, numeric, integer, uuid[]
) from authenticated;

revoke execute on function public.admin_set_event_active(uuid, boolean)
from authenticated;
