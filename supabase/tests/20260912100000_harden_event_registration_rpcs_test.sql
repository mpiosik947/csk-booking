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
create function pg_temp.as_actor_raises(p_role text,p_user uuid,p_sql text,p_state text) returns boolean language plpgsql as $function$
begin
  perform set_config('request.jwt.claims',jsonb_build_object('sub',p_user,'role',p_role)::text,true);
  perform set_config('request.jwt.claim.sub',coalesce(p_user::text,''),true);
  execute format('set local role %I',p_role); execute p_sql; reset role;
  perform set_config('request.jwt.claims','{}',true); perform set_config('request.jwt.claim.sub','',true); return false;
exception when others then reset role; perform set_config('request.jwt.claims','{}',true); perform set_config('request.jwt.claim.sub','',true); return sqlstate=p_state;
end;$function$;

do $tests$
declare
  csk constant uuid:='c5c00000-0000-4000-8000-000000000001';
  tenant_b uuid:=gen_random_uuid(); admin_a uuid:=gen_random_uuid(); employee_a uuid:=gen_random_uuid(); instructor_a uuid:=gen_random_uuid();
  user_a uuid:=gen_random_uuid(); user_b uuid:=gen_random_uuid(); user_register uuid:=gen_random_uuid(); user_promote uuid:=gen_random_uuid();
  pending_admin uuid:=gen_random_uuid(); suspended_admin uuid:=gen_random_uuid(); no_member_admin uuid:=gen_random_uuid();
  event_a uuid:=gen_random_uuid(); event_b uuid:=gen_random_uuid();
  reg_owner uuid:=gen_random_uuid(); reg_foreign uuid:=gen_random_uuid(); reg_promote uuid:=gen_random_uuid(); reg_b uuid:=gen_random_uuid();
  token_promote text:=gen_random_uuid()::text; run_id text:=replace(gen_random_uuid()::text,'-',''); marker text;
  result jsonb; before_count integer;
begin
  marker:='[TEST][SAAS-9D-2A]['||run_id||']';
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  select id,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',label||'-'||run_id||'@example.invalid','',now(),'{}','{}',now(),now()
  from (values(admin_a,'admin'),(employee_a,'employee'),(instructor_a,'instructor'),(user_a,'usera'),(user_b,'userb'),(user_register,'register'),(user_promote,'promote'),(pending_admin,'pending'),(suspended_admin,'suspended'),(no_member_admin,'nomember')) fixture(id,label);
  insert into public.profiles(id,user_id,email,role,verification_status)
  select u.id,u.id,u.email,'user','verified' from auth.users u left join public.profiles p on p.user_id=u.id
  where u.id in(admin_a,employee_a,instructor_a,user_a,user_b,user_register,user_promote,pending_admin,suspended_admin,no_member_admin) and p.user_id is null;
  update public.profiles set first_name='Test',last_name='SAAS9D2A',full_name=marker,phone='000000000',verification_status='verified',
    role=case user_id when admin_a then 'admin' when employee_a then 'pracownik' when instructor_a then 'instruktor' when pending_admin then 'admin' when suspended_admin then 'admin' when no_member_admin then 'admin' else 'user' end
  where user_id in(admin_a,employee_a,instructor_a,user_a,user_b,user_register,user_promote,pending_admin,suspended_admin,no_member_admin);
  if (select count(*) from public.profiles where user_id in(admin_a,employee_a,instructor_a,user_a,user_b,user_register,user_promote,pending_admin,suspended_admin,no_member_admin))<>10 then raise exception 'fixture profile count differs'; end if;
  delete from public.tenant_memberships where tenant_id=csk and user_id=no_member_admin;
  update public.tenant_memberships set status='pending' where tenant_id=csk and user_id=pending_admin;
  update public.tenant_memberships set status='suspended' where tenant_id=csk and user_id=suspended_admin;
  insert into public.tenants(id,name,slug,status) values(tenant_b,marker||' Tenant B','saas9d2a-'||left(run_id,16),'dormant');
  insert into public.tenant_memberships(tenant_id,user_id,role,status) values(tenant_b,user_a,'user','active');
  insert into public.events(id,tenant_id,title,description,event_date,start_time,end_time,location,price,max_participants,is_active) values
    (event_a,csk,marker||' Event A','A',date '2099-10-01',time '10:00',time '12:00','Test',100,20,true),
    (event_b,tenant_b,marker||' Event B','B',date '2099-10-02',time '10:00',time '12:00','Test',100,20,true);
  insert into public.event_registrations(id,tenant_id,event_id,user_id,customer_name,customer_email,customer_phone,registration_status,payment_status,promotion_token,promotion_token_expires_at) values
    (reg_owner,csk,event_a,user_a,marker||' Owner','owner@example.invalid','000','registered','pay_on_site',null,null),
    (reg_foreign,csk,event_a,user_b,marker||' Foreign','foreign@example.invalid','000','registered','pay_on_site',null,null),
    (reg_promote,csk,event_a,user_promote,marker||' Promote','promote@example.invalid','000','reserve','pay_on_site',token_promote,now()+interval '1 hour'),
    (reg_b,tenant_b,event_b,user_a,marker||' Tenant B','b@example.invalid','000','registered','pay_on_site',null,null);

  perform pg_temp.ok(1,'exact seven hardened wrappers exist',(select count(*)=7 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in('register_for_event','cancel_event_registration','approve_event_registration','mark_event_registration_paid','confirm_event_reserve_promotion','get_my_event_registrations_v1','admin_list_event_registrations_v1')),'wrapper inventory differs');
  perform pg_temp.ok(2,'wrappers are postgres-owned SP1 definers',(select count(*)=7 and bool_and(p.prosecdef) and bool_and(r.rolname='postgres') and bool_and(p.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[]) from pg_proc p join pg_namespace n on n.oid=p.pronamespace join pg_roles r on r.oid=p.proowner where n.nspname='public' and p.proname in('register_for_event','cancel_event_registration','approve_event_registration','mark_event_registration_paid','confirm_event_reserve_promotion','get_my_event_registrations_v1','admin_list_event_registrations_v1')),'wrapper metadata differs');
  perform pg_temp.ok(3,'seven cores are invoker-only and inaccessible',(select count(*)=7 and bool_and(not p.prosecdef) and bool_and(not has_function_privilege('public',p.oid,'EXECUTE')) and bool_and(not has_function_privilege('anon',p.oid,'EXECUTE')) and bool_and(not has_function_privilege('authenticated',p.oid,'EXECUTE')) and bool_and(not has_function_privilege('service_role',p.oid,'EXECUTE')) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname like '%__saas9d2a_core'),'core isolation differs');
  perform pg_temp.ok(4,'client ACL is authenticated-only',(select count(*)=7 and bool_and(not has_function_privilege('public',p.oid,'EXECUTE')) and bool_and(not has_function_privilege('anon',p.oid,'EXECUTE')) and bool_and(has_function_privilege('authenticated',p.oid,'EXECUTE')) and bool_and(not has_function_privilege('service_role',p.oid,'EXECUTE')) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in('register_for_event','cancel_event_registration','approve_event_registration','mark_event_registration_paid','confirm_event_reserve_promotion','get_my_event_registrations_v1','admin_list_event_registrations_v1')),'wrapper grants differ');
  perform pg_temp.ok(5,'registration writer explicitly writes event tenant',strpos(pg_get_functiondef('public.register_for_event__saas9d2a_core(uuid,boolean)'::regprocedure),'v_event.tenant_id')>0,'writer relies on default');
  perform pg_temp.ok(6,'my-events core contains tenant membership filter',strpos(pg_get_functiondef('public.get_my_event_registrations_v1__saas9d2a_core(text,text,integer,integer)'::regprocedure),'membership.tenant_id=registration.tenant_id')>0,'tenant filter absent');

  result:=pg_temp.as_actor_json('authenticated',user_register,format('select public.register_for_event(%L,false)',event_a));
  perform pg_temp.ok(7,'active tenant member can register',result@>'{"ok":true,"changed":true,"code":"reserve"}'::jsonb,'registration failed or waitlist ordering regressed');
  perform pg_temp.ok(8,'new registration stores derived CSK tenant',(select tenant_id=csk from public.event_registrations where id=(result->>'registration_id')::uuid),'tenant not derived');
  perform pg_temp.ok(9,'member cannot register against dormant tenant',pg_temp.as_actor_raises('authenticated',user_a,format('select public.register_for_event(%L,false)',event_b),'42501'),'cross-tenant registration allowed');
  perform pg_temp.ok(10,'no membership global admin cannot register',pg_temp.as_actor_raises('authenticated',no_member_admin,format('select public.register_for_event(%L,false)',event_a),'42501'),'global role bypassed membership');

  perform pg_temp.ok(11,'foreign same-tenant user cannot cancel',pg_temp.as_actor_raises('authenticated',user_b,format('select public.cancel_event_registration(%L)',reg_owner),'42501'),'foreign cancellation allowed');
  result:=pg_temp.as_actor_json('authenticated',user_a,format('select public.cancel_event_registration(%L)',reg_owner));
  perform pg_temp.ok(12,'owner can cancel own registration',result->>'new_status'='cancelled','owner cancellation failed');
  perform pg_temp.ok(13,'cancellation audit carries resource tenant',(select tenant_id=csk from public.audit_logs where target_id=reg_owner and action='event_registration_cancelled_by_user'),'audit tenant differs');

  result:=pg_temp.as_actor_json('authenticated',admin_a,format('select public.approve_event_registration(%L)',reg_foreign));
  perform pg_temp.ok(14,'tenant admin can approve registration',result@>'{"ok":true,"changed":true,"code":"updated","new_status":"approved"}'::jsonb,'admin approval failed');
  perform pg_temp.ok(15,'approval audit carries resource tenant',(select tenant_id=csk from public.audit_logs where target_id=reg_foreign and action='event_registration_approved_by_staff'),'approval audit tenant differs');
  result:=pg_temp.as_actor_json('authenticated',employee_a,format('select public.mark_event_registration_paid(%L)',reg_foreign));
  perform pg_temp.ok(16,'tenant employee can mark payment',result->>'code'='updated','employee payment failed');
  perform pg_temp.ok(17,'payment audit carries resource tenant',(select tenant_id=csk from public.audit_logs where target_id=reg_foreign and action='event_registration_payment_marked_by_staff'),'payment audit tenant differs');
  perform pg_temp.ok(18,'admin cannot mutate dormant tenant registration',(pg_temp.as_actor_json('authenticated',admin_a,format('select public.approve_event_registration(%L)',reg_b)))->>'code'='unauthorized' and (pg_temp.as_actor_json('authenticated',admin_a,format('select public.mark_event_registration_paid(%L)',reg_b)))->>'code'='not_allowed','cross-tenant staff mutation allowed');
  perform pg_temp.ok(19,'pending suspended and no-membership admins are denied',(pg_temp.as_actor_json('authenticated',pending_admin,format('select public.approve_event_registration(%L)',reg_foreign)))->>'code'='unauthorized' and (pg_temp.as_actor_json('authenticated',suspended_admin,format('select public.approve_event_registration(%L)',reg_foreign)))->>'code'='unauthorized' and (pg_temp.as_actor_json('authenticated',no_member_admin,format('select public.approve_event_registration(%L)',reg_foreign)))->>'code'='unauthorized','inactive membership authorized');

  perform pg_temp.ok(20,'foreign user cannot confirm promotion token',pg_temp.as_actor_raises('authenticated',user_a,format('select public.confirm_event_reserve_promotion(%L)',token_promote),'42501'),'foreign token confirmation allowed');
  result:=pg_temp.as_actor_json('authenticated',user_promote,format('select public.confirm_event_reserve_promotion(%L)',token_promote));
  perform pg_temp.ok(21,'promotion token owner can confirm',result->>'code'='confirmed','owner promotion failed');
  perform pg_temp.ok(22,'promotion changes exactly the intended registration',(select registration_status='registered' and promotion_confirmed_at is not null from public.event_registrations where id=reg_promote),'promotion mutation differs');

  result:=pg_temp.as_actor_json('authenticated',user_register,'select public.get_my_event_registrations_v1(''upcoming'',null,1,20)');
  perform pg_temp.ok(23,'my-events returns owner rows from active membership',result->>'code'='ok' and (result#>>'{pagination,total}')::integer=1,'my-events owner scope differs');
  result:=pg_temp.as_actor_json('authenticated',user_a,'select public.get_my_event_registrations_v1(''all'',null,1,20)');
  perform pg_temp.ok(24,'my-events excludes dormant tenant row',not exists(select 1 from jsonb_array_elements(result->'items') item where item->>'id'=reg_b::text),'dormant tenant registration leaked');
  result:=pg_temp.as_actor_json('authenticated',admin_a,format('select public.admin_list_event_registrations_v1(%L,null,null,1,50)',event_a));
  perform pg_temp.ok(25,'admin participant list works in own tenant',result->>'code'='ok' and jsonb_array_length(result->'items')>=3,'admin participant list failed');
  perform pg_temp.ok(26,'participant DTO remains bounded',not exists(select 1 from jsonb_array_elements(result->'items') item cross join lateral jsonb_object_keys(item) key where key not in('id','customer_name','customer_email','customer_phone','registration_status','payment_status','created_at')),'participant DTO expanded');
  perform pg_temp.ok(27,'instructor retains current own-tenant participant scope',(pg_temp.as_actor_json('authenticated',instructor_a,format('select public.admin_list_event_registrations_v1(%L,null,null,1,50)',event_a)))->>'code'='ok','instructor scope regressed');
  perform pg_temp.ok(28,'ordinary user and admin cross-tenant participant reads are denied',(pg_temp.as_actor_json('authenticated',user_a,format('select public.admin_list_event_registrations_v1(%L,null,null,1,50)',event_a)))->>'code'='not_allowed' and (pg_temp.as_actor_json('authenticated',admin_a,format('select public.admin_list_event_registrations_v1(%L,null,null,1,50)',event_b)))->>'code'='not_allowed','participant IDOR allowed');

  result:=pg_temp.as_actor_json('anon',null,format('select public.get_public_event_list_v2(%L,''upcoming'',1,50)',marker));
  perform pg_temp.ok(29,'public event contract remains available and PII-free',result->>'code'='ok' and result::text !~* 'customer|user_id|registration_id|token|admin_note|phone|email','public contract regressed');
  perform pg_temp.ok(30,'capacity and waitlist ordering remain authoritative after register cancel and promotion',(select registered_count=2 and reserve_count=1 and available_spots=18 from public.get_public_event_availability_v1() where event_id=event_a),'capacity or waitlist semantics differ');
  perform pg_temp.ok(31,'2B-1 is hardened while 2C fingerprints remain unchanged',
    strpos(pg_get_functiondef('public.admin_list_events_v1(text,text,text,integer,integer)'::regprocedure),'get_my_tenant_role_v1')>0
    and md5(replace(replace(pg_get_functiondef('public.prepare_event_reserve_promotions(uuid)'::regprocedure),E'\r\n',E'\n'),E'\r',E'\n'))='4e73ef1df59936a1a3f41a00e121f6e9'
    and md5(replace(replace(pg_get_functiondef('public.complete_event_reserve_promotion(uuid,uuid,boolean,text)'::regprocedure),E'\r\n',E'\n'),E'\r',E'\n'))='dd5025876008d6eb9551497d84cef90e',
    'deferred scope changed');
  perform pg_temp.ok(32,'temporary CSK defaults remain on event writers',(select count(*)=3 from information_schema.columns where table_schema='public' and table_name in('events','event_lanes','event_registrations') and column_name='tenant_id' and column_default='''c5c00000-0000-4000-8000-000000000001''::uuid'),'temporary defaults changed');
end;$tests$;

select case when passed then 'ok ' else 'not ok ' end||test_order||' - '||test_name||case when passed then '' else E'\n# '||result end from test_results order by test_order;
do $assert$ begin if exists(select 1 from test_results where not passed) then raise exception 'SAAS-9D-2A event RPC hardening failed.'; end if; end;$assert$;
rollback;
