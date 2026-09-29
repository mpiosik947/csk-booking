\set ON_ERROR_STOP on
begin;
create temporary table i1bc_results(name text,passed boolean not null) on commit drop;
create function pg_temp.iok(text,boolean) returns void language sql as $$
 insert into pg_temp.i1bc_results values($1,coalesce($2,false));$$;
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
create function pg_temp.fail_assignment() returns trigger language plpgsql as $$
begin if current_setting('app.i1bc_fail_insert',true)='on' then raise exception 'Synthetic assignment failure';end if;return new;end;$$;
create trigger i1bc_fail_insert before insert on public.event_instructors for each row execute function pg_temp.fail_assignment();
do $test$
declare
 a uuid:=gen_random_uuid();b uuid:=gen_random_uuid();ad uuid:=gen_random_uuid();em uuid:=gen_random_uuid();
 i uuid:=gen_random_uuid();j uuid:=gen_random_uuid();ib uuid:=gen_random_uuid();u uuid:=gen_random_uuid();
 pn uuid:=gen_random_uuid();su uuid:=gen_random_uuid();target uuid;actor uuid;e uuid;result jsonb;
 create_sql text;edit_sql text;rev jsonb;ar text;before_count bigint;before_rows bigint;ids uuid[];n int;r text;
begin
 insert into public.tenants(id,slug,name,status) values(a,'i1bc-'||a,'Synthetic A','active'),(b,'i1bc-'||b,'Synthetic B','active');
 insert into public.tenant_plan_assignments(tenant_id,plan_id,status)
 select t,id,'active' from unnest(array[a,b])t cross join public.saas_plans where plan_key='current_full_v1';
 insert into auth.users(id,email,email_confirmed_at) select x,x||'@example.invalid',now() from unnest(array[ad,em,i,j,ib,u,pn,su])x;
 insert into public.profiles(id,user_id,email,full_name) select id,id,email,'Synthetic' from auth.users
 where id=any(array[ad,em,i,j,ib,u,pn,su]) on conflict(user_id) do nothing;
 delete from public.tenant_memberships where user_id=any(array[ad,em,i,j,ib,u,pn,su]);
 insert into public.tenant_memberships(tenant_id,user_id,role,status) values
 (a,ad,'admin','active'),(a,em,'employee','active'),(a,i,'instructor','active'),(a,j,'instructor','active'),
 (a,u,'user','active'),(a,pn,'instructor','pending'),(a,su,'instructor','suspended'),(b,ib,'instructor','active');
 perform set_config('app.product10d_test_enforce','on',true);
 foreach actor in array array[ad,em] loop
  result:=pg_temp.iactor(actor,format('select public.admin_list_tenant_instructors_v1(%L)',a));
  perform pg_temp.iok('lookup active same tenant '||actor,jsonb_array_length(result)=2);
  perform pg_temp.iok('lookup minimal fields '||actor,not exists(select 1 from jsonb_array_elements(result)x cross join lateral jsonb_object_keys(x)k where k not in ('user_id','display_name')));
  for n in 0..2 loop
   ids:=case n when 0 then '{}'::uuid[] when 1 then array[i] else array[i,j] end;
   result:=pg_temp.iactor(actor,format('select public.admin_create_event_with_instructors_v1(%L,%L,null,current_date+30,''10:00'',''11:00'',null,0,10,''{}'',%L::uuid[])',a,'Synthetic '||n,ids));
   perform pg_temp.iok('create '||n||' instructors '||actor,result->>'code'='created');
   e:=(result->>'event_id')::uuid;
   perform pg_temp.iok('exact active count '||n||' '||actor,(select count(*)=n from public.event_instructors where event_id=e and unassigned_at is null));
  end loop;
 end loop;
 create_sql:=format('select public.admin_create_event_with_instructors_v1(%L,''Rollback candidate'',null,current_date+30,''10:00'',''11:00'',null,0,10,''{}'',%%L::uuid[])',a);
 foreach target in array array[ib,pn,su,u,gen_random_uuid()] loop
  select count(*) into before_count from public.events;
  result:=pg_temp.iactor(ad,format(create_sql,array[target]));
  perform pg_temp.iok('invalid target denied '||target,result->>'error'='42501');
  perform pg_temp.iok('create fully rolled back '||target,(select count(*)=before_count from public.events));
 end loop;
 foreach actor in array array[i,u,ib] loop
  result:=pg_temp.iactor(actor,format(create_sql,array[i]));
  perform pg_temp.iok('unauthorized create '||actor,result->>'code'='not_allowed' or result->>'error'='42501');
  perform pg_temp.iok('unauthorized lookup '||actor,pg_temp.iactor(actor,format('select public.admin_list_tenant_instructors_v1(%L)',a))->>'error'='42501');
 end loop;
 perform set_config('app.i1bc_fail_insert','on',true);
 select count(*) into before_count from public.events;
 result:=pg_temp.iactor(ad,format(create_sql,array[i]));
 perform pg_temp.iok('insert failure rolls back event',result->>'error'='P0001' and (select count(*)=before_count from public.events));
 perform set_config('app.i1bc_fail_insert','off',true);
 result:=pg_temp.iactor(ad,format(create_sql,array[i]));e:=(result->>'event_id')::uuid;rev:=result->'event_revision';ar:=result#>>'{assignments,revision}';
 edit_sql:=format('select public.admin_update_event_with_instructors_v1(%L,%L,''Changed'',null,current_date+30,''10:00'',''11:00'',null,0,10,''{}'',%%L::uuid[],%%L::jsonb,%%L)',a,e);
 foreach target in array array[ib,pn,su,u] loop
  result:=pg_temp.iactor(ad,format(edit_sql,array[target],rev,ar));
  perform pg_temp.iok('bad edit fully rollback '||target,result->>'error'='42501' and public.instructor_event_revision_v1(e)=rev);
 end loop;
 result:=pg_temp.iactor(ad,format(edit_sql,array[i],rev||'{"title":"stale"}',ar));
 perform pg_temp.iok('stale event rollback',result->>'error'='40001' and public.instructor_event_revision_v1(e)=rev);
 result:=pg_temp.iactor(ad,format(edit_sql,array[i],rev,repeat('0',64)));
 perform pg_temp.iok('stale assignment rollback',result->>'error'='40001' and public.instructor_event_revision_v1(e)=rev);
 perform set_config('app.i1bc_fail_insert','on',true);
 result:=pg_temp.iactor(ad,format(edit_sql,array[i,j],rev,ar));
 perform pg_temp.iok('edit insert failure rolls back fields',result->>'error'='P0001' and public.instructor_event_revision_v1(e)=rev);
 perform pg_temp.iok('edit insert failure preserves assignment',(select count(*)=1 from public.event_instructors where event_id=e));
 perform set_config('app.i1bc_fail_insert','off',true);
 result:=pg_temp.iactor(em,format(edit_sql,array[i,j],rev,ar));
 perform pg_temp.iok('employee combined edit succeeds',result->>'code'='updated');rev:=result->'event_revision';ar:=result#>>'{assignments,revision}';
 select count(*) into before_rows from public.event_instructors where event_id=e;
 result:=pg_temp.iactor(em,format(edit_sql,array[i,j],rev,ar));
 perform pg_temp.iok('repeated identical edit no generation',result->>'code'='no_change' and result#>>'{assignments,changed}'='false' and (select count(*)=before_rows from public.event_instructors where event_id=e));
 insert into public.event_registrations(event_id,tenant_id,user_id,customer_name,customer_email,customer_phone,registration_status)
 select e,a,who,'Visible name','hidden@example.invalid','private',s from unnest(array[u,ad,em,pn,su],array['registered','approved','reserve','cancelled','participant']) as x(who,s);
 result:=pg_temp.iactor(i,format('select public.get_instructor_event_participants_v1(%L)',e));
 perform pg_temp.iok('scoped participants allow registered approved only',result->>'total'='2');
 perform pg_temp.iok('minimal participant DTO',not exists(select 1 from jsonb_array_elements(result->'items')x cross join lateral jsonb_object_keys(x)k where k not in ('registration_id','display_name','registration_status')));
 perform pg_temp.iok('reserve separate read only',pg_temp.iactor(i,format('select public.get_instructor_event_participants_v1(%L,''reserve'')',e))->>'total'='1');
 perform pg_temp.iok('pagination after scope',jsonb_array_length(pg_temp.iactor(i,format('select public.get_instructor_event_participants_v1(%L,''participants'',1,0)',e))->'items')=1);
 perform pg_temp.iok('assigned detail allow',pg_temp.iactor(i,format('select public.get_my_instructor_events_v1(%L,''upcoming'',%L)',a,e))->>'total'='1');
 foreach actor in array array[ib,u,ad,em] loop
  perform pg_temp.iok('participant noninstructor deny '||actor,pg_temp.iactor(actor,format('select public.get_instructor_event_participants_v1(%L)',e))->>'error'='42501');
 end loop;
 perform pg_temp.iok('unknown event no count leak',pg_temp.iactor(i,format('select public.get_instructor_event_participants_v1(%L)',gen_random_uuid()))->>'error'='42501');
 insert into public.tenant_memberships(tenant_id,user_id,role,status) values(b,i,'user','active');
 perform pg_temp.iok('same user other tenant denied',pg_temp.iactor(i,format('select public.get_my_instructor_events_v1(%L)',b))->>'error'='42501');
 update public.events set event_date=current_date-29 where id=e;
 perform pg_temp.iok('ended under 30 days allowed',pg_temp.iactor(i,format('select public.get_instructor_event_participants_v1(%L)',e))->>'total'='2');
 update public.events set event_date=current_date-31 where id=e;
 perform pg_temp.iok('ended over 30 days PII denied',pg_temp.iactor(i,format('select public.get_instructor_event_participants_v1(%L)',e))->>'error'='42501');
 perform pg_temp.iok('expired metadata retained',pg_temp.iactor(i,format('select public.get_my_instructor_events_v1(%L,''past'',%L)',a,e))->>'total'='1');
 update public.events set event_date=current_date+30 where id=e;
 foreach r in array array['pending','suspended'] loop
  update public.tenant_memberships set status=r where tenant_id=a and user_id=i;
  perform pg_temp.iok('membership revocation '||r,pg_temp.iactor(i,format('select public.get_instructor_event_participants_v1(%L)',e))->>'error'='42501');
 end loop;
 update public.tenant_memberships set status='active' where tenant_id=a and user_id=i;
 foreach r in array array['user','employee'] loop
  update public.tenant_memberships set role=r where tenant_id=a and user_id=i;
  perform pg_temp.iok('role revocation '||r,pg_temp.iactor(i,format('select public.get_instructor_event_participants_v1(%L)',e))->>'error'='42501');
 end loop;
 update public.tenant_memberships set role='instructor' where tenant_id=a and user_id=i;
 update public.event_instructors set unassigned_at=clock_timestamp() where event_id=e and instructor_user_id=j;
 perform pg_temp.iok('unassigned participant DENY',pg_temp.iactor(j,format('select public.get_instructor_event_participants_v1(%L)',e))->>'error'='42501');
 perform pg_temp.iok('unassigned detail DENY',pg_temp.iactor(j,format('select public.get_my_instructor_events_v1(%L,''upcoming'',%L)',a,e))->>'error'='42501');
 foreach r in array array['suspended','dormant'] loop
  update public.tenants set status=r where id=a;
  perform pg_temp.iok('tenant lifecycle deny '||r,pg_temp.iactor(i,format('select public.get_instructor_event_participants_v1(%L)',e))->>'error'='42501');
 end loop;
 update public.tenants set status='active' where id=a;
 update public.tenant_plan_assignments set status='suspended' where tenant_id=a;
 perform pg_temp.iok('missing entitlement denies scoped metadata',pg_temp.iactor(i,format('select public.get_my_instructor_events_v1(%L)',a))->>'error'='42501');
 perform pg_temp.iok('missing entitlement denies PII',pg_temp.iactor(i,format('select public.get_instructor_event_participants_v1(%L)',e))->>'error'='42501');
 perform pg_temp.iok('missing entitlement denies precreate lookup',pg_temp.iactor(ad,format('select public.admin_list_tenant_instructors_v1(%L)',a))->>'error'='42501');
 update public.tenant_plan_assignments set status='active' where tenant_id=a;
 result:=pg_temp.iactor(ad,format('select public.admin_cancel_event_v1(%L)',e));
 perform pg_temp.iok('canonical cancellation succeeded',(select cancelled_at is not null from public.events where id=e));
 perform pg_temp.iok('cancelled event PII denied immediately',pg_temp.iactor(i,format('select public.get_instructor_event_participants_v1(%L)',e))->>'error'='42501');
 perform pg_temp.iok('cancelled assigned metadata retained',pg_temp.iactor(i,format('select public.get_my_instructor_events_v1(%L,''cancelled'',%L)',a,e))->>'total'='1');
 result:=pg_temp.iactor(ad,format(edit_sql,array[]::uuid[],public.instructor_event_revision_v1(e),ar));
 perform pg_temp.iok('cancelled staffing denied',result->>'error'='42501' or result->>'ok'='false');
 perform pg_temp.iok('broad instructor event reader remains denied',pg_temp.iactor(i,format('select public.admin_list_events_v2(%L)',a))->>'code'='not_allowed');
 perform pg_temp.iok('broad participants remain denied',pg_temp.iactor(i,format('select public.admin_list_event_registrations_v1(%L)',e))->>'code'='not_allowed');
 foreach r in array array['anon','service_role'] loop
  perform pg_temp.iok('lookup ACL '||r,pg_temp.iactor(ad,format('select public.admin_list_tenant_instructors_v1(%L)',a),r)->>'error'='42501');
  perform pg_temp.iok('create ACL '||r,pg_temp.iactor(ad,format(create_sql,array[i]),r)->>'error'='42501');
  perform pg_temp.iok('update ACL '||r,pg_temp.iactor(ad,format(edit_sql,array[i],rev,ar),r)->>'error'='42501');
 end loop;
 perform pg_temp.iok('private revision not callable',pg_temp.iactor(ad,format('select public.instructor_event_revision_v1(%L)',e))->>'error'='42501');
 perform pg_temp.iok('exact workflow definer delta',(select count(*)=127 from pg_proc where pronamespace='public'::regnamespace and prosecdef));
 perform pg_temp.iok('five new definers have exact owner searchpath ACL',
  (select count(*)=5 and bool_and(pg_get_userbyid(p.proowner)='postgres'
    and p.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[]
    and has_function_privilege('authenticated',p.oid,'EXECUTE')
    and not has_function_privilege('anon',p.oid,'EXECUTE')
    and not has_function_privilege('service_role',p.oid,'EXECUTE')
    and not exists(select 1 from aclexplode(p.proacl) acl where acl.grantee=0 and acl.privilege_type='EXECUTE'))
  from pg_proc p where p.pronamespace='public'::regnamespace and p.prosecdef and p.proname in
   ('admin_list_tenant_instructors_v1','admin_create_event_with_instructors_v1','admin_update_event_with_instructors_v1','get_my_instructor_events_v1','get_instructor_event_participants_v1')));
end;
$test$;
select case when passed then 'ok - ' else 'not ok - ' end||name from i1bc_results;
select count(*) as assertions from i1bc_results;
do $$ begin if exists(select 1 from i1bc_results where not passed) then raise exception 'INSTRUCTOR atomic matrix failed';end if;end;$$;
rollback;
