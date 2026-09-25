-- New PRODUCT-10E records participate in the existing account-wide redaction.
-- This does not implement leave-tenant or change any account authorization.
set lock_timeout='5s';
set statement_timeout='60s';
do $lifecycle$
declare definition text; anchor text:='  delete from public.profiles profile where profile.user_id=v_user_id;';
begin
 definition:=replace(replace(pg_get_functiondef('public.anonymize_my_account_v1()'::regprocedure),chr(13)||chr(10),chr(10)),chr(13),chr(10));
 if md5(definition)<>'70b5f590399aa3f3a147935459b7f085' then raise exception 'Account lifecycle input drift'; end if;
 if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then raise exception 'Account lifecycle anchor drift'; end if;
 definition:=replace(definition,anchor,$replacement$
  update public.platform_audit_logs entry set
    actor_user_id=case when entry.actor_user_id=v_user_id then v_pseudonym_id else entry.actor_user_id end,
    details=public.redact_account_audit_details_v1(entry.details,v_user_id,v_pseudonym,v_direct_values)
  where entry.actor_user_id=v_user_id or entry.details->>'user_id'=v_user_id::text;
  update public.external_settlement_records entry set
    actor_user_id=case when entry.actor_user_id=v_user_id then v_pseudonym_id else entry.actor_user_id end,
    external_reference='[redacted]'
  where entry.actor_user_id=v_user_id or entry.reservation_id=any(v_reservation_ids) or entry.registration_id=any(v_registration_ids);
  delete from public.platform_admins where user_id=v_user_id;
  delete from public.profiles profile where profile.user_id=v_user_id;
$replacement$);
 execute definition;
end;$lifecycle$;
