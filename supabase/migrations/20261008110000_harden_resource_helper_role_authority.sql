-- PRODUCT-10E remediation: active internal helpers must not add global-role gates.
-- Existing resource-scoped wrappers, role sets, signatures and business logic stay intact.
set lock_timeout='5s';
set statement_timeout='30s';
do $fix$
declare item record; definition text; anchor text; replacement text;
begin
 for item in select * from (values
 ('public.admin_create_lane_block__saas9d3a_core(uuid,date,time,time,text)','41a24524f23e3146c591b454508bd0bf','shooting_lanes','id','p_lane_id','v_actor_role','v_actor_id','query'),
 ('public.admin_set_lane_block_active__saas9d3a_core(uuid,boolean)','7817f85bd6f08fb7c8e50f979198d092','lane_blocks','id','p_block_id','v_actor_role','v_actor_id','query'),
 ('public.admin_update_lane_block__saas9d3a_core(uuid,uuid,date,time,time,text,boolean)','54ff3226f115b39a56e6709e498f886f','lane_blocks','id','p_block_id','v_actor_role','v_actor_id','query'),
 ('public.admin_set_event_active_v2__saas9d2b1_core(uuid,boolean)','63a58d9ee496faa9b3f134dcb943b098','events','id','p_event_id','v_actor_role','v_actor_id','query'),
 ('public.admin_update_event_v2__saas9d2b1_core(uuid,text,text,date,time,time,text,numeric,integer,uuid[])','77d90f464806dccca47c9933dd4eb901','events','id','p_event_id','v_actor_role','v_actor_id','query'),
 ('public.approve_event_registration__saas9d2a_core(uuid)','98bb518a6f97fb3596fa3c283dafa1dc','event_registrations','id','p_registration_id','actor_role','actor_user_id','query'),
 ('public.mark_event_registration_paid__saas9d2a_core(uuid)','c4c2088a628c2b0efb21deb726b6b158','event_registrations','id','p_registration_id','v_actor_role','v_actor_id','compact_query'),
 ('public.update_reservation_admin_note__saas9d1_core(uuid,text)','d199fbd9355fa2e1f54319e9879e35a7','reservations','id','p_reservation_id','v_actor_role','v_actor_user_id','assignment'),
 ('public.update_reservation_payment__saas9d1_core(uuid,text)','6795ca562c9c1d528ac32f251f90a600','reservations','id','p_reservation_id','v_actor_role','v_actor_user_id','assignment'),
 ('public.update_reservation_attendance__saas9d1_core(uuid,text)','41f275b12bd3bcc8815ba2da04fe3978','reservations','id','p_reservation_id','v_actor_role','v_actor_user_id','assignment'),
 ('public.create_reservation_v2__saas9d1_core(uuid,date,time,integer,integer,uuid,text)','4d65baa8f2a71c96656aac1943b67244','shooting_lanes','id','p_lane_id','v_role','v_user_id','customer'),
 ('public.get_check_in_reservation_v1__saas9d1_core(uuid)','45535ac83da2e01d788d5054c40992e8','reservations','check_in_token','p_token','v_actor_role','v_actor_user_id','query'),
 ('public.admin_list_event_registrations_v1__saas9d2a_core(uuid,text,text,integer,integer)','ca2d2c54f2a9dd1f45cda38ddce1f7bc','events','id','p_event_id','v_role','v_actor','reader')
 ) targets(signature,fingerprint,resource_table,resource_key,argument,role_variable,actor_variable,shape)
 loop
   definition:=replace(replace(pg_get_functiondef(item.signature::regprocedure),E'\r\n',E'\n'),E'\r',E'\n');
   if md5(definition)<>item.fingerprint then raise exception 'Resource authority input drift: %',item.signature; end if;
   anchor:=case item.shape
     when 'query' then format(E'select pg_catalog.lower(pg_catalog.btrim(profile.role::text))\n  into %s\n  from public.profiles as profile\n  where profile.user_id = %s;',item.role_variable,item.actor_variable)
     when 'compact_query' then E'select pg_catalog.lower(pg_catalog.btrim(profile.role::text))\n  into v_actor_role\n  from public.profiles as profile\n  where profile.user_id=v_actor_id;'
     when 'assignment' then 'v_actor_role := pg_catalog.lower(pg_catalog.btrim(v_actor_profile.role::text));'
     when 'customer' then 'v_role := pg_catalog.lower(pg_catalog.btrim(coalesce(v_profile.role::text, '''')));'
     when 'reader' then E'select pg_catalog.lower(pg_catalog.btrim(profile.role::text)) into v_role\n  from public.profiles profile where profile.user_id=v_actor;'
   end;
   if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then
     raise exception 'Resource authority anchor drift: %',item.signature;
   end if;
   replacement:=format('select case public.get_my_tenant_role_v1(resource.tenant_id)
       when ''employee'' then ''pracownik'' when ''instructor'' then ''instruktor''
       when ''admin'' then ''admin'' when ''user'' then ''user'' else null end
     into %I from public.%I resource where resource.%I=%I;',
     item.role_variable,item.resource_table,item.resource_key,item.argument);
   execute replace(definition,anchor,replacement);
   execute format('alter function %s security invoker set search_path=pg_catalog,public,pg_temp',item.signature);
   execute format('revoke all on function %s from public,anon,authenticated,service_role',item.signature);
 end loop;
end;
$fix$;
