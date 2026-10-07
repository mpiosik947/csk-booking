-- PAM-1E-R1: exact-account candidate lookup; no directory or mutation authority.
-- STABLE keeps authority, account eligibility and membership in one statement snapshot.
create function public.platform_lookup_tenant_admin_candidate_v1(p_tenant_id uuid,p_email text)
returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,pg_temp
as $function$
declare normalized_email text:=lower(btrim(p_email)); result jsonb;
begin
 if not public.is_platform_admin_v1() then raise exception 'Not authorized' using errcode='42501'; end if;
 if p_tenant_id is null or not exists(select 1 from public.tenants where id=p_tenant_id) then
  raise exception 'TENANT_UNAVAILABLE' using errcode='22023';
 end if;
 if normalized_email is null or length(p_email)>254
  or normalized_email !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' then
  raise exception 'Exact email required' using errcode='22023';
 end if;
 -- Same account eligibility as the existing onboarding lookup; no auth metadata leaves DB.
 -- lower(email) uses the existing auth.users instance/email expression index.
 select jsonb_build_object('user_id',u.id,'email',u.email,
  'membership',jsonb_build_object('exists',m.user_id is not null,'role',m.role,'status',m.status))
 into strict result
 from auth.users u left join public.tenant_memberships m on m.tenant_id=p_tenant_id and m.user_id=u.id
 where lower(u.email)=normalized_email and public.onboarding_admin_eligible_core_v1(u.id)
 limit 2;
 return result;
exception when no_data_found then return null;
 when too_many_rows then raise exception 'Account cannot be selected' using errcode='22023';
end;$function$;
alter function public.platform_lookup_tenant_admin_candidate_v1(uuid,text) owner to postgres;
revoke all on function public.platform_lookup_tenant_admin_candidate_v1(uuid,text) from public,anon,authenticated,service_role;
grant execute on function public.platform_lookup_tenant_admin_candidate_v1(uuid,text) to authenticated;

-- PAM-1B expected_state (JSON object key order is irrelevant):
-- membership.exists=false -> SQL NULL (JSON null RPC parameter), not an object of nulls.
-- membership.exists=true  -> {"role": membership.role, "status": membership.status}.
-- Do not send "exists" in expected_state. The writer rechecks exact current state;
-- this read is not a lock or permission to skip confirmation, stale checks or request UUIDs.
