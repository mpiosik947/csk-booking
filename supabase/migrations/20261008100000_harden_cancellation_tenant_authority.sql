-- PRODUCT-10E prerequisite: global profile roles must not grant cutoff overrides.
-- No suspension expansion, signature changes, or cancellation policy changes.
set lock_timeout = '5s';
set statement_timeout = '30s';

do $remediation$
declare
  item record;
  definition text;
  replacement text;
begin
  for item in select * from (values
    ('public.cancel_reservation__saas9d1_core(uuid)',
     '8c0dc0b91ad855ffc14641697ae5fa46',
     'actor_role := pg_catalog.lower(pg_catalog.btrim(actor_profile.role::text));',
     'reservations','p_reservation_id'),
    ('public.cancel_event_registration__saas9d2a_core(uuid)',
     'b39e1ae3c5e3d885e3a2fa5b5b7760c8',
     'actor_role := lower(btrim(actor_profile.role::text));',
     'event_registrations','p_registration_id')
  ) as targets(signature,fingerprint,anchor,resource_table,resource_argument)
  loop
    definition := replace(replace(pg_catalog.pg_get_functiondef(item.signature::regprocedure),E'\r\n',E'\n'),E'\r',E'\n');
    if pg_catalog.md5(definition) <> item.fingerprint then
      raise exception 'Cancellation remediation input drift: %',item.signature;
    end if;
    if (length(definition)-length(replace(definition,item.anchor,'')))/length(item.anchor) <> 1 then
      raise exception 'Cancellation remediation role anchor drift: %',item.signature;
    end if;
    -- Legacy strings remain response/audit labels only. Membership is authority.
    -- The existing helper requires active membership AND active resource tenant.
    replacement := pg_catalog.format(
      'select case public.get_my_tenant_role_v1(resource.tenant_id)
        when ''employee'' then ''pracownik''
        when ''instructor'' then ''instruktor''
        when ''admin'' then ''admin''
        when ''user'' then ''user''
        else null end
      into actor_role
      from public.%I resource where resource.id = %I;',
      item.resource_table,item.resource_argument);
    definition := replace(definition,item.anchor,replacement);
    execute definition;
  end loop;
end;
$remediation$;

-- Closed INVOKER helpers remain inaccessible to every application role.
alter function public.cancel_reservation__saas9d1_core(uuid)
  security invoker set search_path=pg_catalog,public,pg_temp;
alter function public.cancel_event_registration__saas9d2a_core(uuid)
  security invoker set search_path=pg_catalog,public,pg_temp;
revoke all on function public.cancel_reservation__saas9d1_core(uuid),
  public.cancel_event_registration__saas9d2a_core(uuid)
  from public,anon,authenticated,service_role;
