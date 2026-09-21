\set ON_ERROR_STOP on
\pset format unaligned

select '1..16';
begin;
create temporary table c3a_results(n integer primary key,label text,passed boolean) on commit drop;
create function pg_temp.ok(p_n integer,p_label text,p_passed boolean)
returns void language sql as $$
  insert into pg_temp.c3a_results values(p_n,p_label,coalesce(p_passed,false));
$$;
create function pg_temp.as_actor(p_actor uuid,p_sql text)
returns jsonb language plpgsql as $$
declare v_result jsonb;
begin
  perform pg_catalog.set_config('request.jwt.claims',
    pg_catalog.jsonb_build_object('sub',p_actor,'role','authenticated')::text,true);
  perform pg_catalog.set_config('request.jwt.claim.sub',p_actor::text,true);
  execute 'set local role authenticated';
  execute p_sql into v_result;
  execute 'reset role';
  perform pg_catalog.set_config('request.jwt.claims','{}',true);
  perform pg_catalog.set_config('request.jwt.claim.sub','',true);
  return v_result;
exception when others then
  execute 'reset role';
  perform pg_catalog.set_config('request.jwt.claims','{}',true);
  perform pg_catalog.set_config('request.jwt.claim.sub','',true);
  raise;
end $$;

do $tests$
declare
  t constant uuid:='c5c00000-0000-4000-8000-000000000001';
  u uuid:=pg_catalog.gen_random_uuid();
  other_u uuid:=pg_catalog.gen_random_uuid();
  lane_id uuid:=pg_catalog.gen_random_uuid();
  price_id uuid:=pg_catalog.gen_random_uuid();
  reservation_id uuid:=pg_catalog.gen_random_uuid();
  marker text:='[TEST][C3A]['||pg_catalog.replace(pg_catalog.gen_random_uuid()::text,'-','')||']';
  owner_row jsonb; other_row jsonb; no_auth_row jsonb;
  update_result jsonb; no_change_result jsonb;
  v_old_role text; v_old_email text;
begin
  perform pg_temp.ok(1,'two exact signatures exist',
    pg_catalog.to_regprocedure('public.get_my_reservation_calendar_v1(uuid)') is not null
    and pg_catalog.to_regprocedure('public.update_my_profile_v2(text,text,text,text,text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean)') is not null);
  perform pg_temp.ok(2,'two new postgres-owned definers with fixed paths and volatility',
    (select count(*)=2 and pg_catalog.bool_and(p.prosecdef
      and r.rolname='postgres'
      and p.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[]
      and ((p.proname='get_my_reservation_calendar_v1' and p.provolatile='s')
        or (p.proname='update_my_profile_v2' and p.provolatile='v')))
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid=p.pronamespace
      join pg_catalog.pg_roles r on r.oid=p.proowner
      where n.nspname='public' and p.proname in
        ('get_my_reservation_calendar_v1','update_my_profile_v2')));
  perform pg_temp.ok(3,'exact authenticated-only ACL',
    not pg_catalog.has_function_privilege('public','public.get_my_reservation_calendar_v1(uuid)','EXECUTE')
    and not pg_catalog.has_function_privilege('anon','public.get_my_reservation_calendar_v1(uuid)','EXECUTE')
    and pg_catalog.has_function_privilege('authenticated','public.get_my_reservation_calendar_v1(uuid)','EXECUTE')
    and not pg_catalog.has_function_privilege('service_role','public.get_my_reservation_calendar_v1(uuid)','EXECUTE')
    and not pg_catalog.has_function_privilege('public','public.update_my_profile_v2(text,text,text,text,text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean)','EXECUTE')
    and not pg_catalog.has_function_privilege('anon','public.update_my_profile_v2(text,text,text,text,text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean)','EXECUTE')
    and pg_catalog.has_function_privilege('authenticated','public.update_my_profile_v2(text,text,text,text,text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean)','EXECUTE')
    and not pg_catalog.has_function_privilege('service_role','public.update_my_profile_v2(text,text,text,text,text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean)','EXECUTE'));
  perform pg_temp.ok(4,'function definitions are fingerprintable and avoid active bridge',
    (select count(*)=2 and pg_catalog.bool_and(
      pg_catalog.length(pg_catalog.md5(pg_catalog.replace(pg_catalog.replace(
        pg_catalog.pg_get_functiondef(p.oid),E'\r\n',E'\n'),E'\r',E'\n')))=32
      and pg_catalog.strpos(p.prosrc,'active_single_tenant_id_v1')=0)
      from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.proname in
        ('get_my_reservation_calendar_v1','update_my_profile_v2')));
  perform pg_temp.ok(5,'inventory 96 definers, 22 bridge, seven defaults',
    (select count(*)=96 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.prosecdef)
    and (select count(*)=22 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.prosrc like '%active_single_tenant_id_v1%')
    and (select count(*)=7 from information_schema.columns
      where table_schema='public' and column_name='tenant_id'
        and table_name in ('shooting_lanes','reservations','lane_blocks','events',
          'event_lanes','event_registrations','email_deliveries')
        and column_default='''c5c00000-0000-4000-8000-000000000001''::uuid'));

  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,
    raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  select actor_id,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
    marker||label||'@example.invalid','',pg_catalog.now(),'{}','{}',pg_catalog.now(),pg_catalog.now()
  from (values(u,'owner'),(other_u,'foreign')) actor(actor_id,label);
  insert into public.profiles(id,user_id,email,phone,first_name,last_name,full_name,role,verification_status)
  select auth_user.id,auth_user.id,auth_user.email,'000','C3','Test',marker,'user','pending'
  from auth.users auth_user left join public.profiles profile on profile.user_id=auth_user.id
  where auth_user.id in(u,other_u) and profile.user_id is null;
  insert into public.tenant_memberships(tenant_id,user_id,role,status)
    values(t,u,'user','active') on conflict (tenant_id,user_id)
    do update set role='user',status='active';
  insert into public.shooting_lanes(id,tenant_id,name,type,is_active,max_shooters,
    booking_step_minutes,display_order,currency_code,resource_kind,parent_lane_id,
    whole_lane_bookable,positions_bookable)
    values(lane_id,t,marker||' inactive lane','test',false,2,60,9901,'PLN','lane',null,true,false);
  insert into public.lane_pricing_rules(id,lane_id,day_group,min_shooters,max_shooters,label,hourly_price)
    values(price_id,lane_id,'mon_thu',1,2,marker||' pricing',10);
  insert into public.reservations(id,user_id,tenant_id,lane_id,customer_name,customer_email,
    customer_phone,reservation_date,start_time,end_time,duration_minutes,price,
    reservation_status,payment_status,attendance_status,check_in_token,shooters_count,pricing_rule_id,
    pricing_day_group_snapshot,lane_name_snapshot,pricing_label_snapshot,
    price_per_hour_snapshot,total_price,currency_code,creation_request_id)
    values(reservation_id,u,t,lane_id,marker,marker||'@example.invalid','000',
      date '2099-10-01',time '08:00',time '09:00',60,10,'confirmed','pay_on_site',
      'planned',pg_catalog.gen_random_uuid(),1,price_id,'mon_thu',marker,'Test',10,10,'PLN',
      pg_catalog.gen_random_uuid());
  owner_row:=pg_temp.as_actor(u,pg_catalog.format(
    'select pg_catalog.to_jsonb(r) from public.get_my_reservation_calendar_v1(%L::uuid) r',reservation_id));
  other_row:=pg_temp.as_actor(other_u,pg_catalog.format(
    'select pg_catalog.to_jsonb(r) from public.get_my_reservation_calendar_v1(%L::uuid) r',reservation_id));
  no_auth_row:=(select pg_catalog.to_jsonb(r) from public.get_my_reservation_calendar_v1(reservation_id) r);
  perform pg_temp.ok(6,'owner sees exact resource-derived CSK reservation',
    owner_row->>'reservation_id'=reservation_id::text
    and owner_row->>'tenant_id'=t::text
    and owner_row->>'tenant_public_name'='CSK');
  perform pg_temp.ok(7,'inactive historical lane label is retained',
    owner_row->>'lane_display_name'=marker||' inactive lane');
  perform pg_temp.ok(8,'foreign and unauthenticated callers see no row',
    other_row is null and no_auth_row is null);
  perform pg_temp.ok(9,'nonexistent reservation has identical no-row contract',
    pg_temp.as_actor(u,pg_catalog.format(
      'select pg_catalog.to_jsonb(r) from public.get_my_reservation_calendar_v1(%L::uuid) r',
      pg_catalog.gen_random_uuid())) is null);
  perform pg_temp.ok(10,'calendar DTO has only eight approved fields',
    (select pg_catalog.count(*)=8 from pg_catalog.jsonb_object_keys(owner_row))
    and not (owner_row ?| array['user_id','customer_name','email','phone','check_in_token','admin_note']));

  select role,email into v_old_role,v_old_email from public.profiles where user_id=u;
  insert into public.tenant_user_verifications(tenant_id,user_id,verification_status,permissions_verified)
    values(t,u,'verified',true)
    on conflict(tenant_id,user_id) do update
      set verification_status='verified',permissions_verified=true;
  update_result:=pg_temp.as_actor(u,
    'select public.update_my_profile_v2(''123456789'',''00-001'',''Test City'',''Test St'',''1'',null,true,false,false,false,false,false,false,false,false,false)');
  perform pg_temp.ok(11,'owner updates only allowed contact and declarations',
    update_result->>'ok'='true' and update_result->>'changed'='true'
    and update_result->>'declarations_changed'='true'
    and exists(select 1 from public.profiles where user_id=u and phone='123456789' and permission_sport));
  perform pg_temp.ok(12,'global response has no tenant or verification state',
    (select pg_catalog.count(*)=5 from pg_catalog.jsonb_object_keys(update_result))
    and not (update_result ?| array['tenant_id','role','verification_status',
      'permissions_verified','membership','user_id']));
  perform pg_temp.ok(13,'privileged profile fields and other owner remain unchanged',
    exists(select 1 from public.profiles where user_id=u and role=v_old_role and email=v_old_email
      and admin_note is null)
    and exists(select 1 from public.profiles where user_id=other_u and phone is distinct from '123456789'));
  perform pg_temp.ok(14,'declaration change invalidates tenant verification with audit binding',
    exists(select 1 from public.tenant_user_verifications
      where tenant_id=t and user_id=u and verification_status='pending'
        and permissions_verified=false)
    and exists(select 1 from public.audit_logs
      where tenant_id=t and actor_user_id=u
        and action='tenant_user_verification_invalidated'
        and target_id=u));
  no_change_result:=pg_temp.as_actor(u,
    'select public.update_my_profile_v2(''123456789'',''00-001'',''Test City'',''Test St'',''1'',null,true,false,false,false,false,false,false,false,false,false)');
  perform pg_temp.ok(15,'repeat no-change creates no extra audit',
    no_change_result->>'code'='no_change'
    and (select count(*)=1 from public.audit_logs
      where tenant_id=t and actor_user_id=u
        and action='tenant_user_verification_invalidated' and target_id=u));
  perform pg_temp.ok(16,'no arbitrary target/privilege arguments exist',
    pg_catalog.pg_get_function_identity_arguments('public.update_my_profile_v2(text,text,text,text,text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean)'::regprocedure)
      not ilike '%user_id%'
    and pg_catalog.strpos((select p.prosrc from pg_catalog.pg_proc p
      where p.oid='public.update_my_profile_v2(text,text,text,text,text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean)'::regprocedure),
      'profiles.role')=0);
end $tests$;

do $assert$
declare failed text;
begin
  select pg_catalog.string_agg(n::text||' '||label,', ' order by n)
    into failed from pg_temp.c3a_results where not passed;
  if failed is not null or (select count(*) from pg_temp.c3a_results)<>16 then
    raise exception 'SAAS-9E-C3-A focused tests failed: %',coalesce(failed,'missing checks');
  end if;
end $assert$;
select 'ok '||n||' - '||label from pg_temp.c3a_results order by n;
rollback;
