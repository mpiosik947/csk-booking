-- Keep reservation writer V1 available only as an administrative rollback path.
revoke execute on function public.create_reservation(
  uuid, date, time without time zone, integer, integer, uuid, text
) from authenticated;
