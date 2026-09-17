\set ON_ERROR_STOP on
\pset format unaligned

select '1..32';

begin;

create temporary table test_results(test_order integer primary key,test_name text,passed boolean,result text) on commit drop;
create function pg_temp.ok(integer,text,boolean,text) returns void language sql as $function$
  insert into pg_temp.test_results values($1,$2,coalesce($3,false),$4);
$function$;
create function pg_temp.as_actor_json(p_role text,p_user uuid,p_sql text) returns jsonb language plpgsql as $function$
declare v jsonb;
begin
  perform set_config('request.jwt.claims',jsonb_build_object('sub',p_user,'role',p_role)::text,true);
  perform set_config('request.jwt.claim.sub',coalesce(p_user::text,''),true);
  execute format('set local role %I',p_role); execute p_sql into v; reset role;
  perform set_config('request.jwt.claims','{}',true); perform set_config('request.jwt.claim.sub','',true); return v;
exception when others then reset role; perform set_config('request.jwt.claims','{}',true); perform set_config('request.jwt.claim.sub','',true); raise;
end;$function$;

do $tests$
declare
  csk constant uuid:='c5c00000-0000-4000-8000-000000000001';
  tenant_b uuid:=gen_random_uuid(); admin_a uuid:=gen_random_uuid(); employee_a uuid:=gen_random_uuid();
  instructor_a uuid:=gen_random_uuid(); user_a uuid:=gen_random_uuid(); pending_admin uuid:=gen_random_uuid();
  suspended_admin uuid:=gen_random_uuid(); no_member_admin uuid:=gen_random_uuid();
  lane_a uuid:=gen_random_uuid(); lane_b uuid:=gen_random_uuid(); event_a uuid:=gen_random_uuid(); event_b uuid:=gen_random_uuid();
  created_event uuid; run_id text:=replace(gen_random_uuid()::text,'-',''); marker text; result jsonb; before_count integer;
begin
  marker:='[TEST][SAAS-9D-2B-1]['||run_id||']';
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  select id,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',label||'-'||run_id||'@example.invalid','',now(),'{}','{}',now(),now()
  from (values(admin_a,'admin'),(employee_a,'employee'),(instructor_a,'instructor'),(user_a,'user'),(pending_admin,'pending'),(suspended_admin,'suspended'),(no_member_admin,'nomember')) fixture(id,label);
  insert into public.profiles(id,user_id,email,role,verification_status)
  select u.id,u.id,u.email,'user','verified' from auth.users u left join public.profiles p on p.user_id=u.id
  where u.id in(admin_a,employee_a,instructor_a,user_a,pending_admin,suspended_admin,no_member_admin) and p.user_id is null;
  update public.profiles set first_name='Test',last_name='SAAS9D2B1',full_name=marker,phone='000',verification_status='verified',
    role=case user_id when admin_a then 'admin' when employee_a then 'pracownik' when instructor_a then 'instruktor'
      when pending_admin then 'admin' when suspended_admin then 'admin' when no_member_admin then 'admin' else 'user' end
  where user_id in(admin_a,employee_a,instructor_a,user_a,pending_admin,suspended_admin,no_member_admin);
  if (select count(*) from public.profiles where user_id in(admin_a,employee_a,instructor_a,user_a,pending_admin,suspended_admin,no_member_admin))<>7 then
    raise exception 'fixture profile count differs';
  end if;
  delete from public.tenant_memberships where tenant_id=csk and user_id=no_member_admin;
  update public.tenant_memberships set status='pending' where tenant_id=csk and user_id=pending_admin;
  update public.tenant_memberships set status='suspended' where tenant_id=csk and user_id=suspended_admin;
  insert into public.tenants(id,name,slug,status) values(tenant_b,marker||' Tenant B','saas9d2b1-'||left(run_id,16),'dormant');
  insert into public.tenant_memberships(tenant_id,user_id,role,status) values
    (tenant_b,admin_a,'admin','active'),(tenant_b,employee_a,'employee','active'),(tenant_b,instructor_a,'instructor','active');
  insert into public.shooting_lanes(id,tenant_id,name,type,is_active,max_shooters,booking_step_minutes,display_order,resource_kind,parent_lane_id,whole_lane_bookable,positions_bookable)
  values
    (lane_a,csk,marker||' Lane A','test',true,10,60,9950,'lane',null,true,false),
    (lane_b,tenant_b,marker||' Lane B','test',true,10,60,9951,'lane',null,true,false);
  insert into public.events(id,tenant_id,title,description,event_date,start_time,end_time,location,price,max_participants,is_active)
  values
    (event_a,csk,marker||' Event A','A',date '2099-11-01',time '10:00',time '11:00','Test',100,10,true),
    (event_b,tenant_b,marker||' Event B','B',date '2099-11-02',time '10:00',time '11:00','Test',100,10,true);
  insert into public.event_lanes(tenant_id,event_id,lane_id) values(csk,event_a,lane_a),(tenant_b,event_b,lane_b);

  perform pg_temp.ok(1,'four hardened wrappers exist',(select count(*)=4 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in('admin_create_event_v2','admin_update_event_v2','admin_set_event_active_v2','admin_list_events_v1')),'wrapper inventory differs');
  perform pg_temp.ok(2,'wrappers are postgres-owned SP1 definers',(select count(*)=4 and bool_and(p.prosecdef) and bool_and(r.rolname='postgres') and bool_and(p.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[]) from pg_proc p join pg_namespace n on n.oid=p.pronamespace join pg_roles r on r.oid=p.proowner where n.nspname='public' and p.proname in('admin_create_event_v2','admin_update_event_v2','admin_set_event_active_v2','admin_list_events_v1')),'wrapper metadata differs');
  perform pg_temp.ok(3,'four cores are invoker-only and inaccessible',(select count(*)=4 and bool_and(not p.prosecdef) and bool_and(not has_function_privilege('public',p.oid,'EXECUTE')) and bool_and(not has_function_privilege('anon',p.oid,'EXECUTE')) and bool_and(not has_function_privilege('authenticated',p.oid,'EXECUTE')) and bool_and(not has_function_privilege('service_role',p.oid,'EXECUTE')) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname like '%__saas9d2b1_core'),'core isolation differs');
  perform pg_temp.ok(4,'active client ACL is authenticated-only',(select count(*)=4 and bool_and(not has_function_privilege('public',p.oid,'EXECUTE')) and bool_and(not has_function_privilege('anon',p.oid,'EXECUTE')) and bool_and(has_function_privilege('authenticated',p.oid,'EXECUTE')) and bool_and(not has_function_privilege('service_role',p.oid,'EXECUTE')) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in('admin_create_event_v2','admin_update_event_v2','admin_set_event_active_v2','admin_list_events_v1')),'active grants differ');
  perform pg_temp.ok(5,'each legacy event writer differs only by approved ACL revoke',(
    select count(*)=3
      and bool_and(md5(replace(replace(pg_get_functiondef(p.oid),E'\r\n',E'\n'),E'\r',E'\n'))=expected.fingerprint)
      and bool_and(p.prosecdef)
      and bool_and(r.rolname='postgres')
      and bool_and(p.proconfig=array['search_path=public, pg_temp']::text[])
      and bool_and(not has_function_privilege('public',p.oid,'EXECUTE'))
      and bool_and(not has_function_privilege('anon',p.oid,'EXECUTE'))
      and bool_and(not has_function_privilege('authenticated',p.oid,'EXECUTE'))
      and bool_and(not has_function_privilege('service_role',p.oid,'EXECUTE'))
    from (values
      ('public.admin_create_event(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])','26f51acb0a0f56677a86dbddec9974b2'),
      ('public.admin_update_event(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])','60301f5e0b290117105bc9637f10d3ce'),
      ('public.admin_set_event_active(uuid,boolean)','b547b0c8d2b056273b10fe57f78f89c0')
    ) expected(signature,fingerprint)
    join pg_proc p on p.oid=to_regprocedure(expected.signature)
    join pg_roles r on r.oid=p.proowner
  ),'legacy body/signature/owner/search_path changed or forbidden EXECUTE remains');
  perform pg_temp.ok(6,'create core explicitly writes event and relation tenant',strpos(pg_get_functiondef('public.admin_create_event_v2__saas9d2b1_core(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'::regprocedure),'insert into public.event_lanes (tenant_id, event_id, lane_id)')>0 and strpos(pg_get_functiondef('public.admin_create_event_v2__saas9d2b1_core(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'::regprocedure),'v_tenant_id')>0,'create tenant ownership absent');
  perform pg_temp.ok(7,'update core explicitly writes relation tenant',strpos(pg_get_functiondef('public.admin_update_event_v2__saas9d2b1_core(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'::regprocedure),'v_original.tenant_id, p_event_id')>0,'update relation tenant absent');
  perform pg_temp.ok(8,'admin list is tenant-filtered and create bridge scope is locked',strpos(pg_get_functiondef('public.admin_list_events_v1__saas9d2b1_core(text,text,text,integer,integer)'::regprocedure),'event_record.tenant_id=v_tenant_id')>0 and strpos(pg_get_functiondef('public.admin_list_events_v1__saas9d2b1_core(text,text,text,integer,integer)'::regprocedure),'where tenant_id=v_tenant_id')>0 and strpos(pg_get_functiondef('public.admin_create_event_v2(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])'::regprocedure),'for share')>0,'tenant filter or create bridge lock absent');

  result:=pg_temp.as_actor_json('authenticated',admin_a,format('select public.admin_create_event_v2(%L,%L,date ''2099-11-03'',time ''10:00'',time ''11:00'',%L,100,10,array[%L]::uuid[])',marker||' Created A','A','Test',lane_a));
  created_event:=(result->>'event_id')::uuid;
  perform pg_temp.ok(9,'admin creates event in active tenant',result@>'{"ok":true,"changed":true,"code":"created"}'::jsonb,'admin create failed');
  perform pg_temp.ok(10,'created event and lane relation store CSK tenant',(select event_record.tenant_id=csk from public.events event_record where event_record.id=created_event) and (select relation.tenant_id=csk from public.event_lanes relation where relation.event_id=created_event and relation.lane_id=lane_a),'created tenant ownership differs');
  result:=pg_temp.as_actor_json('authenticated',employee_a,format('select public.admin_create_event_v2(%L,%L,date ''2099-11-04'',time ''10:00'',time ''11:00'',%L,100,10,array[]::uuid[])',marker||' Employee A','A','Test'));
  perform pg_temp.ok(11,'employee preserves create permission',result->>'code'='created','employee create failed');
  perform pg_temp.ok(12,'instructor and ordinary user cannot create',(pg_temp.as_actor_json('authenticated',instructor_a,format('select public.admin_create_event_v2(%L,%L,date ''2099-11-05'',time ''10:00'',time ''11:00'',%L,100,10,array[]::uuid[])',marker||' Instructor','A','Test')))->>'code'='not_allowed' and (pg_temp.as_actor_json('authenticated',user_a,format('select public.admin_create_event_v2(%L,%L,date ''2099-11-05'',time ''12:00'',time ''13:00'',%L,100,10,array[]::uuid[])',marker||' User','A','Test')))->>'code'='not_allowed','management permission widened');
  select count(*) into before_count from public.events;
  result:=pg_temp.as_actor_json('authenticated',admin_a,format('select public.admin_create_event_v2(%L,%L,date ''2099-11-06'',time ''10:00'',time ''11:00'',%L,100,10,array[%L]::uuid[])',marker||' Mixed','A','Test',lane_b));
  perform pg_temp.ok(13,'event A plus lane B is denied atomically',result->>'code'='not_allowed' and (select count(*) from public.events)=before_count,'cross-tenant lane create mutated state');

  result:=pg_temp.as_actor_json('authenticated',employee_a,format('select public.admin_update_event_v2(%L,%L,%L,date ''2099-11-01'',time ''11:00'',time ''12:00'',%L,120,12,array[%L]::uuid[])',event_a,marker||' Event A updated','A2','Test',lane_a));
  perform pg_temp.ok(14,'employee updates event in own active tenant',result->>'code'='updated','employee update failed');
  perform pg_temp.ok(15,'updated relation retains event tenant',(select relation.tenant_id=csk from public.event_lanes relation where relation.event_id=event_a and relation.lane_id=lane_a),'updated relation tenant differs');
  result:=pg_temp.as_actor_json('authenticated',admin_a,format('select public.admin_update_event_v2(%L,%L,%L,date ''2099-11-02'',time ''11:00'',time ''12:00'',%L,120,12,array[%L]::uuid[])',event_b,marker||' Event B blocked','B2','Test',lane_b));
  perform pg_temp.ok(16,'admin A cannot manage dormant tenant B event',result->>'code'='not_allowed' and (select title=marker||' Event B' from public.events where id=event_b),'cross-tenant event update allowed');
  result:=pg_temp.as_actor_json('authenticated',admin_a,format('select public.admin_update_event_v2(%L,%L,%L,date ''2099-11-01'',time ''12:00'',time ''13:00'',%L,120,12,array[%L]::uuid[])',event_a,marker||' Bad lanes','A3','Test',lane_b));
  perform pg_temp.ok(17,'lane replacement across tenants is denied',result->>'code'='not_allowed' and not exists(select 1 from public.event_lanes where event_id=event_a and lane_id=lane_b),'cross-tenant lane replacement allowed');

  result:=pg_temp.as_actor_json('authenticated',admin_a,format('select public.admin_set_event_active_v2(%L,false)',event_a));
  perform pg_temp.ok(18,'admin can deactivate own-tenant event',result->>'code'='deactivated' and (select not is_active from public.events where id=event_a),'deactivation failed');
  result:=pg_temp.as_actor_json('authenticated',employee_a,format('select public.admin_set_event_active_v2(%L,true)',event_a));
  perform pg_temp.ok(19,'employee can activate own-tenant event',result->>'code'='activated' and (select is_active from public.events where id=event_a),'activation failed');
  perform pg_temp.ok(20,'instructor cannot activate event',(pg_temp.as_actor_json('authenticated',instructor_a,format('select public.admin_set_event_active_v2(%L,false)',event_a)))->>'code'='not_allowed','instructor management widened');
  perform pg_temp.ok(21,'global admin without membership is denied',(pg_temp.as_actor_json('authenticated',no_member_admin,format('select public.admin_set_event_active_v2(%L,false)',event_a)))->>'code'='not_allowed','global profile role bypass remains');
  perform pg_temp.ok(22,'pending and suspended admins are denied',(pg_temp.as_actor_json('authenticated',pending_admin,format('select public.admin_set_event_active_v2(%L,false)',event_a)))->>'code'='not_allowed' and (pg_temp.as_actor_json('authenticated',suspended_admin,format('select public.admin_set_event_active_v2(%L,false)',event_a)))->>'code'='not_allowed','inactive membership authorized');

  result:=pg_temp.as_actor_json('authenticated',admin_a,format('select public.admin_list_events_v1(%L,''all'',''nearest'',1,50)',marker));
  perform pg_temp.ok(23,'admin list returns own active tenant events',result->>'code'='ok' and jsonb_array_length(result->'items')>=3,'admin list failed');
  perform pg_temp.ok(24,'admin list exposes zero Tenant B events',not exists(select 1 from jsonb_array_elements(result->'items') item where item->>'id'=event_b::text),'Tenant B event leaked');
  perform pg_temp.ok(25,'instructor retains read-only admin-list scope',(pg_temp.as_actor_json('authenticated',instructor_a,format('select public.admin_list_events_v1(%L,''all'',''nearest'',1,50)',marker)))->>'code'='ok','instructor read scope regressed');
  perform pg_temp.ok(26,'ordinary and no-membership users cannot list',(pg_temp.as_actor_json('authenticated',user_a,'select public.admin_list_events_v1(null,''all'',''nearest'',1,20)'))->>'code'='not_allowed' and (pg_temp.as_actor_json('authenticated',no_member_admin,'select public.admin_list_events_v1(null,''all'',''nearest'',1,20)'))->>'code'='not_allowed','admin list role bypass remains');

  update public.tenants set status='dormant' where id=csk;
  result:=pg_temp.as_actor_json('authenticated',admin_a,format('select public.admin_create_event_v2(%L,%L,date ''2099-11-07'',time ''10:00'',time ''11:00'',%L,100,10,array[]::uuid[])',marker||' Zero active','A','Test'));
  perform pg_temp.ok(27,'bridge fails closed with zero active tenants',result->>'code'='not_allowed','zero-active bridge selected a tenant');
  update public.tenants set status='active' where id=csk;
  drop index public.tenants_single_active_runtime_guard;
  update public.tenants set status='active' where id=tenant_b;
  result:=pg_temp.as_actor_json('authenticated',admin_a,format('select public.admin_create_event_v2(%L,%L,date ''2099-11-08'',time ''10:00'',time ''11:00'',%L,100,10,array[]::uuid[])',marker||' Two active','A','Test'));
  perform pg_temp.ok(28,'bridge fails closed with two active tenants',result->>'code'='not_allowed','multi-active bridge selected a tenant');
  update public.tenants set status='dormant' where id=tenant_b;
  create unique index tenants_single_active_runtime_guard on public.tenants ((true)) where status='active';

  perform pg_temp.ok(29,'public reader fingerprints match approved 2B-2 wrappers',md5(replace(replace(pg_get_functiondef('public.get_public_event_availability_v1()'::regprocedure),E'\r\n',E'\n'),E'\r',E'\n'))='665b9ac71f99b3de3421d1534b24f088' and md5(replace(replace(pg_get_functiondef('public.get_public_event_list_v2(text,text,integer,integer)'::regprocedure),E'\r\n',E'\n'),E'\r',E'\n'))='642b84c0d78066e2071a0f0df1ce97ff','2B-2 wrapper fingerprint changed');
  result:=pg_temp.as_actor_json('anon',null,format('select public.get_public_event_list_v2(%L,''upcoming'',1,50)',marker));
  perform pg_temp.ok(30,'public events remain available and PII-free',result->>'code'='ok' and result::text !~* 'customer|user_id|registration_id|token|admin_note|phone|email','public event contract regressed');
  perform pg_temp.ok(31,'temporary event defaults remain',(select count(*)=2 from information_schema.columns where table_schema='public' and table_name in('events','event_lanes') and column_name='tenant_id' and column_default='''c5c00000-0000-4000-8000-000000000001''::uuid'),'temporary defaults changed');
  perform pg_temp.ok(32,'SECURITY DEFINER inventory reflects approved hardening through 9D-4B-2B',(select count(*)=69 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prosecdef),'definer inventory drifted');
end;$tests$;

select case when passed then 'ok ' else 'not ok ' end||test_order||' - '||test_name||case when passed then '' else E'\n# '||result end from test_results order by test_order;
do $assert$ begin if exists(select 1 from test_results where not passed) then raise exception 'SAAS-9D-2B-1 event management hardening failed.'; end if; end;$assert$;
rollback;
