\set ON_ERROR_STOP on
begin;
create temporary table instructor1a_results(name text,passed boolean not null) on commit drop;
create function pg_temp.iok(text,boolean) returns void language sql as $$
insert into pg_temp.instructor1a_results values($1,coalesce($2,false));$$;
create function pg_temp.iactor(u uuid,q text,r text default 'authenticated') returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform set_config('request.jwt.claim.sub',coalesce(u::text,''),true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',u,'role',r)::text,true);
  execute format('set local role %I',r); execute q into v; reset role;
  perform set_config('request.jwt.claim.sub','',true);perform set_config('request.jwt.claims','{}',true);return v;
exception when others then
  reset role;perform set_config('request.jwt.claim.sub','',true);perform set_config('request.jwt.claims','{}',true);
  return jsonb_build_object('error',sqlstate);
end;$$;
do $test$
declare
 a uuid:=gen_random_uuid();b uuid:=gen_random_uuid();e uuid:=gen_random_uuid();eb uuid:=gen_random_uuid();
 admin uuid:=gen_random_uuid();employee uuid:=gen_random_uuid();i uuid:=gen_random_uuid();i2 uuid:=gen_random_uuid();
 ordinary uuid:=gen_random_uuid();ib uuid:=gen_random_uuid();pending uuid:=gen_random_uuid();suspended uuid:=gen_random_uuid();
 adminb uuid:=gen_random_uuid();outsider uuid:=gen_random_uuid();
 rev text;rev2 text;first_id uuid;result jsonb;v_count integer;row_id uuid;role_name text;
begin
 insert into public.tenants(id,slug,name,status) values(a,'i1a-'||a,'Synthetic A','active'),(b,'i1a-'||b,'Synthetic B','active');
 insert into public.tenant_plan_assignments(tenant_id,plan_id,status)
 select t,id,'active' from unnest(array[a,b])t cross join public.saas_plans where plan_key='current_full_v1';
 insert into auth.users(id,email,email_confirmed_at) select u,u||'@example.invalid',now()
 from unnest(array[admin,employee,i,i2,ordinary,ib,pending,suspended,adminb,outsider])u;
 insert into public.profiles(id,user_id,email,full_name,role,verification_status)
 select u.id,u.id,u.email,'Synthetic Instructor','user','pending' from auth.users u
 where u.id=any(array[admin,employee,i,i2,ordinary,ib,pending,suspended,adminb,outsider])
 on conflict(user_id) do update set full_name=excluded.full_name;
 delete from public.tenant_memberships where user_id=any(array[admin,employee,i,i2,ordinary,ib,pending,suspended,adminb,outsider]);
 insert into public.tenant_memberships(tenant_id,user_id,role,status) values
 (a,admin,'admin','active'),(a,employee,'employee','active'),(a,i,'instructor','active'),(a,i2,'instructor','active'),
 (a,ordinary,'user','active'),(a,pending,'instructor','pending'),(a,suspended,'instructor','suspended'),
 (b,ib,'instructor','active'),(b,adminb,'admin','active'),(b,i,'user','active');
 insert into public.events(id,tenant_id,title,event_date,start_time,end_time,max_participants,is_active)
 values(e,a,'Synthetic A',current_date+30,'10:00','11:00',10,true),(eb,b,'Synthetic B',current_date+30,'10:00','11:00',10,true);
 insert into public.event_registrations(event_id,tenant_id,user_id,customer_name,customer_email,customer_phone,registration_status,payment_status)
 values(e,a,ordinary,'Synthetic','test@example.invalid','000','registered','pending'),(e,a,i,'Synthetic','test@example.invalid','000','registered','pending'),
 (eb,b,ib,'Synthetic','test@example.invalid','000','registered','pending');

 perform pg_temp.iok('zero backfill',(select count(*)=0 from public.event_instructors));
 result:=pg_temp.iactor(admin,format('select public.admin_list_available_event_instructors_v1(%L)',e));rev:=result->>'revision';
 perform pg_temp.iok('lookup active same tenant only',jsonb_array_length(result->'items')=2 and result->'items' @> jsonb_build_array(jsonb_build_object('user_id',i)));
 perform pg_temp.iok('lookup minimal DTO',not exists(select 1 from jsonb_array_elements(result->'items')x cross join lateral jsonb_object_keys(x)k where k not in ('user_id','display_name')));
 perform pg_temp.iok('employee lookup allowed',pg_temp.iactor(employee,format('select public.admin_list_available_event_instructors_v1(%L)',e)) ? 'revision');
 foreach row_id in array array[i,ordinary,outsider,adminb] loop
  perform pg_temp.iok('lookup unauthorized '||row_id,pg_temp.iactor(row_id,format('select public.admin_list_available_event_instructors_v1(%L)',e))->>'error'='42501');
  perform pg_temp.iok('set unauthorized '||row_id,pg_temp.iactor(row_id,format('select public.admin_set_event_instructors_v1(%L,array[%L]::uuid[],%L)',e,i,rev))->>'error'='42501');
 end loop;
 foreach row_id in array array[ib,pending,suspended,ordinary,employee,admin,outsider] loop
  perform pg_temp.iok('invalid target '||row_id,pg_temp.iactor(admin,format('select public.admin_set_event_instructors_v1(%L,array[%L]::uuid[],%L)',e,row_id,rev))->>'error'='42501');
 end loop;
 update public.profiles set role='instruktor' where user_id=outsider;
 perform pg_temp.iok('profiles.role not target authority',pg_temp.iactor(admin,format('select public.admin_set_event_instructors_v1(%L,array[%L]::uuid[],%L)',e,outsider,rev))->>'error'='42501');
 result:=pg_temp.iactor(admin,format('select public.admin_set_event_instructors_v1(%L,array[%L]::uuid[],%L)',e,i,rev));
 perform pg_temp.iok('admin assign allowed',result->>'changed'='true');rev2:=result->>'revision';
 select id into first_id from public.event_instructors where event_id=e and instructor_user_id=i and unassigned_at is null;
 perform pg_temp.iok('actor and tenant derived',exists(select 1 from public.event_instructors where id=first_id and tenant_id=a and assigned_by=admin));
 result:=pg_temp.iactor(admin,format('select public.admin_set_event_instructors_v1(%L,array[%L]::uuid[],%L)',e,i,rev2));
 perform pg_temp.iok('identical save no-op',result->>'changed'='false' and (select count(*)=1 from public.event_instructors where event_id=e));
 perform pg_temp.iok('stale revision denies',pg_temp.iactor(employee,format('select public.admin_set_event_instructors_v1(%L,array[]::uuid[],%L)',e,rev))->>'error'='40001');
 result:=pg_temp.iactor(employee,format('select public.admin_set_event_instructors_v1(%L,array[]::uuid[],%L)',e,rev2));rev:=result->>'revision';
 perform pg_temp.iok('employee removal preserves history',result->>'changed'='true' and exists(select 1 from public.event_instructors where id=first_id and unassigned_at is not null and unassigned_by=employee));
 result:=pg_temp.iactor(employee,format('select public.admin_set_event_instructors_v1(%L,array[%L]::uuid[],%L)',e,i,rev));rev:=result->>'revision';
 perform pg_temp.iok('reassign new generation',(select count(*)=2 from public.event_instructors where event_id=e and instructor_user_id=i) and exists(select 1 from public.event_instructors where event_id=e and instructor_user_id=i and id<>first_id and unassigned_at is null));
 begin insert into public.event_instructors(tenant_id,event_id,instructor_user_id) values(a,e,i);perform pg_temp.iok('unique active assignment',false);
 exception when unique_violation then perform pg_temp.iok('unique active assignment',true);end;
 begin insert into public.event_instructors(tenant_id,event_id,instructor_user_id) values(b,e,ib);perform pg_temp.iok('cross-tenant FK',false);
 exception when foreign_key_violation then perform pg_temp.iok('cross-tenant FK',true);end;
 perform pg_temp.iok('same user instructor A user B cannot assign in B',pg_temp.iactor(adminb,format('select public.admin_set_event_instructors_v1(%L,array[%L]::uuid[],%L)',eb,i,(pg_temp.iactor(adminb,format('select public.admin_list_available_event_instructors_v1(%L)',eb))->>'revision')))->>'error'='42501');

 perform pg_temp.iok('SEC008 instructor direct read self only',pg_temp.iactor(i,format('select to_jsonb(count(*)) from public.event_registrations where event_id=%L',e))='1'::jsonb);
 perform pg_temp.iok('SEC008 instructor B direct denied',pg_temp.iactor(i,format('select to_jsonb(count(*)) from public.event_registrations where event_id=%L',eb))='0'::jsonb);
 perform pg_temp.iok('user self read preserved',pg_temp.iactor(ordinary,format('select to_jsonb(count(*)) from public.event_registrations where event_id=%L',e))='1'::jsonb);
 foreach row_id in array array[admin,employee] loop
  perform pg_temp.iok('staff direct read preserved '||row_id,pg_temp.iactor(row_id,format('select to_jsonb(count(*)) from public.event_registrations where event_id=%L',e))='2'::jsonb);
  perform pg_temp.iok('staff v1 preserved '||row_id,pg_temp.iactor(row_id,format('select public.admin_list_event_registrations_v1(%L)',e))->>'ok'='true');
  perform pg_temp.iok('staff v2 preserved '||row_id,pg_temp.iactor(row_id,format('select public.admin_list_event_registrations_v2(%L,%L)',a,e))->>'ok'='true');
 end loop;
 perform pg_temp.iok('SEC008 instructor v1 denied',pg_temp.iactor(i,format('select public.admin_list_event_registrations_v1(%L)',e))->>'code'='not_allowed');
 perform pg_temp.iok('SEC008 instructor v2 denied',pg_temp.iactor(i,format('select public.admin_list_event_registrations_v2(%L,%L)',a,e))->>'code'='not_allowed');
 perform pg_temp.iok('SEC008 instructor other tenant v1 denied',pg_temp.iactor(i,format('select public.admin_list_event_registrations_v1(%L)',eb))->>'code'='not_allowed');
 update public.events set is_active=false where id in (e,eb);
 perform pg_temp.iok('assigned instructor cannot read private event metadata',pg_temp.iactor(i,format('select to_jsonb(count(*)) from public.events where id=%L',e))='0'::jsonb);
 perform pg_temp.iok('instructor cannot read Tenant B private event metadata',pg_temp.iactor(i,format('select to_jsonb(count(*)) from public.events where id=%L',eb))='0'::jsonb);
 perform pg_temp.iok('instructor admin event list denied despite assignment',pg_temp.iactor(i,format('select public.admin_list_events_v2(%L)',a))->>'code'='not_allowed');
 foreach row_id in array array[admin,employee] loop
  perform pg_temp.iok('staff private event metadata preserved '||row_id,pg_temp.iactor(row_id,format('select to_jsonb(count(*)) from public.events where id=%L',e))='1'::jsonb);
  perform pg_temp.iok('staff admin event list preserved '||row_id,pg_temp.iactor(row_id,format('select public.admin_list_events_v2(%L)',a))->>'ok'='true');
 end loop;
 update public.events set is_active=true where id in (e,eb);
 perform pg_temp.iok('instructor public visibility equals ordinary user contract',pg_temp.iactor(i,format('select to_jsonb(count(*)) from public.events where id=%L',e))=pg_temp.iactor(ordinary,format('select to_jsonb(count(*)) from public.events where id=%L',e)));
 foreach role_name in array array['anon','authenticated','service_role'] loop
  perform pg_temp.iok('assignment table direct select denied '||role_name,pg_temp.iactor(admin,'select to_jsonb(count(*)) from public.event_instructors',role_name)->>'error'='42501');
  perform pg_temp.iok('assignment table direct write denied '||role_name,pg_temp.iactor(admin,format('insert into public.event_instructors(tenant_id,event_id,instructor_user_id) values(%L,%L,%L) returning to_jsonb(id)',a,e,i2),role_name)->>'error'='42501');
 end loop;
 perform pg_temp.iok('null identity denied',pg_temp.iactor(null,format('select public.admin_list_available_event_instructors_v1(%L)',e))->>'error'='42501');
 perform pg_temp.iok('anon RPC denied',pg_temp.iactor(null,format('select public.admin_list_available_event_instructors_v1(%L)',e),'anon')->>'error'='42501');
 perform pg_temp.iok('service RPC denied',pg_temp.iactor(null,format('select public.admin_list_available_event_instructors_v1(%L)',e),'service_role')->>'error'='42501');
 update public.tenant_memberships set role='user' where tenant_id=a and user_id=i;
 perform pg_temp.iok('role change prevents selected assignment',pg_temp.iactor(admin,format('select public.admin_set_event_instructors_v1(%L,array[%L]::uuid[],%L)',e,i,rev))->>'error'='42501');
 update public.tenant_memberships set role='instructor' where tenant_id=a and user_id=i;
 foreach role_name in array array['suspended','dormant'] loop
  update public.tenants set status=role_name where id=a;
  perform pg_temp.iok('tenant lifecycle denies '||role_name,pg_temp.iactor(admin,format('select public.admin_set_event_instructors_v1(%L,array[]::uuid[],%L)',e,rev))->>'error'='42501');
 end loop;
 update public.tenants set status='active' where id=a;
 perform set_config('app.product10d_test_enforce','on',true);
 update public.tenant_plan_assignments set status='suspended' where tenant_id=a;
 perform pg_temp.iok('events entitlement enforced',pg_temp.iactor(admin,format('select public.admin_set_event_instructors_v1(%L,array[]::uuid[],%L)',e,rev))->>'error'='42501');
 update public.tenant_plan_assignments set status='active' where tenant_id=a;

 result:=pg_temp.iactor(i,'select public.anonymize_my_account_v1()');
 perform pg_temp.iok('instructor anonymization allowed',result->>'ok'='true');
 perform pg_temp.iok('anonymous history preserved without identity',(select count(*)=2 from public.event_instructors where event_id=e and instructor_user_id is null));
 perform pg_temp.iok('privacy change revises assignment fingerprint',(pg_temp.iactor(admin,format('select public.admin_list_available_event_instructors_v1(%L)',e))->>'revision') is distinct from rev);
 delete from auth.users where id=i;
 perform pg_temp.iok('auth delete allowed',not exists(select 1 from auth.users where id=i));
 result:=pg_temp.iactor(employee,'select public.anonymize_my_account_v1()');
 perform pg_temp.iok('actor anonymization allowed',result->>'ok'='true');
 perform pg_temp.iok('actor references cleared',not exists(select 1 from public.event_instructors where assigned_by=employee or unassigned_by=employee));
 perform pg_temp.iok('definer exact delta',(select count(*)=122 from pg_proc where pronamespace='public'::regnamespace and prosecdef));
 perform pg_temp.iok('new RPC metadata and ACL',not exists(select 1 from pg_proc where proname in ('admin_list_available_event_instructors_v1','admin_set_event_instructors_v1') and (proowner<>'postgres'::regrole or not prosecdef or proconfig<>array['search_path=pg_catalog, public, pg_temp'] or proacl::text<>'{postgres=X/postgres,authenticated=X/postgres}')));
end;
$test$;
select case when passed then 'ok - ' else 'not ok - ' end||name from instructor1a_results;
select count(*) as assertions from instructor1a_results;
do $$ begin if exists(select 1 from instructor1a_results where not passed) then raise exception 'INSTRUCTOR-1A matrix failed';end if;end;$$;
rollback;
