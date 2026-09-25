-- Serialize lifecycle changes against new obligations; no widening of RLS.
set lock_timeout='5s';
set statement_timeout='60s';
create function public.enforce_suspended_obligations_v1()
returns trigger language plpgsql security definer
set search_path=pg_catalog,public,pg_temp
as $$
declare tenant_status text; target uuid;
begin
 if session_user='postgres' and current_setting('app.product10d_test_enforce',true) is distinct from 'on' then
 return coalesce(new,old); end if;
 target:=coalesce(new.tenant_id,old.tenant_id);
 -- Row SHARE conflicts with platform lifecycle UPDATE; unlike a snapshot-only
 -- status check it cannot allow a new obligation to race past suspension.
 select status into tenant_status from public.tenants where id=target for share;
 if tenant_status='active' then return coalesce(new,old); end if;
 if tenant_status='suspended' and tg_op='UPDATE' then
 -- Account-wide anonymization remains separate from tenant suspension. Allow
 -- only the existing owner's exact redaction shape, never identity reassignment.
 if (to_jsonb(old)->>'user_id')=auth.uid()::text and (to_jsonb(new)->>'user_id') is null
 and (to_jsonb(new)->>'pii_anonymized_at') is not null
 and (to_jsonb(new)->>'customer_name')='deleted-user-'||substr(md5(auth.uid()::text||':csk-sec009-v1'),1,16)
 and (to_jsonb(new)->>'customer_email')='deleted-user-'||substr(md5(auth.uid()::text||':csk-sec009-v1'),1,16)||'@invalid.local'
 and (to_jsonb(new)->>'customer_phone')='[redacted]' then
 if tg_table_name='reservations' and (to_jsonb(new)-array['user_id','customer_name','customer_email','customer_phone',
 'admin_note','reservation_note','check_in_token','pii_anonymized_at','updated_at','booking_period'])=
 (to_jsonb(old)-array['user_id','customer_name','customer_email','customer_phone',
 'admin_note','reservation_note','check_in_token','pii_anonymized_at','updated_at','booking_period'])
 and (to_jsonb(new)->>'admin_note') is null and (to_jsonb(new)->>'reservation_note') is null and (to_jsonb(new)->>'check_in_token') is null then return new; end if;
 if tg_table_name='event_registrations' and (to_jsonb(new)-array['user_id','customer_name','customer_email','customer_phone',
 'promotion_token','promotion_token_expires_at','promotion_claim_id','promotion_claim_expires_at','promotion_attempt_count',
 'promotion_last_attempt_at','promotion_last_error_code','pii_anonymized_at','updated_at'])=
 (to_jsonb(old)-array['user_id','customer_name','customer_email','customer_phone',
 'promotion_token','promotion_token_expires_at','promotion_claim_id','promotion_claim_expires_at','promotion_attempt_count',
 'promotion_last_attempt_at','promotion_last_error_code','pii_anonymized_at','updated_at']) then return new; end if;
 end if;
 if tg_table_name='reservations'
 and (to_jsonb(new)->>'reservation_status') in ('cancelled','canceled','cancelled_by_user','cancelled_by_admin')
 -- booking_period is GENERATED ALWAYS and unset in a BEFORE trigger.
 and (to_jsonb(new)-array['reservation_status','updated_at','booking_period'])=(to_jsonb(old)-array['reservation_status','updated_at','booking_period']) then return new; end if;
 if tg_table_name='event_registrations' and (to_jsonb(new)->>'registration_status')='cancelled'
 and (to_jsonb(new)-array['registration_status','updated_at'])=(to_jsonb(old)-array['registration_status','updated_at']) then return new; end if;
 end if;
 raise exception 'New business unavailable' using errcode='42501';
end;$$;
revoke all on function public.enforce_suspended_obligations_v1() from public,anon,authenticated,service_role;
create trigger reservations_suspended_obligations before insert or update or delete on public.reservations
 for each row execute function public.enforce_suspended_obligations_v1();
create trigger registrations_suspended_obligations before insert or update or delete on public.event_registrations
 for each row execute function public.enforce_suspended_obligations_v1();
create trigger events_suspended_obligations before insert or update or delete on public.events
 for each row execute function public.enforce_suspended_obligations_v1();
