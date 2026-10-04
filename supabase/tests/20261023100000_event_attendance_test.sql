\set ON_ERROR_STOP on
begin;
create temporary table attendance_results(name text,passed boolean) on commit drop;
create function pg_temp.ok(n text,v boolean) returns void language plpgsql as $$begin
 insert into attendance_results values(n,coalesce(v,false));
 if v is distinct from true then raise exception 'Attendance assertion: %',n;end if;
end;$$;
create function pg_temp.actor(u uuid,q text,r text default 'authenticated') returns jsonb language plpgsql as $$
declare v jsonb;
begin
 perform set_config('request.jwt.claim.sub',coalesce(u::text,''),true);
 perform set_config('request.jwt.claims',jsonb_build_object('sub',u,'role',r)::text,true);
 execute format('set local role %I',r);execute q into v;reset role;
 perform set_config('request.jwt.claim.sub','',true);perform set_config('request.jwt.claims','{}',true);return v;
exception when others then
 reset role;perform set_config('request.jwt.claim.sub','',true);perform set_config('request.jwt.claims','{}',true);
 return jsonb_build_object('error',sqlstate,'message',sqlerrm);
end;$$;
create function pg_temp.fail_audit() returns trigger language plpgsql as $$begin
 if new.action='event_attendance_changed' and current_setting('app.i1d_fail_audit',true)='on' then raise exception 'Synthetic audit failure';end if;return new;
end;$$;
create trigger i1d_fail_audit before insert on public.audit_logs for each row execute function pg_temp.fail_audit();
do $test$
declare a uuid:=gen_random_uuid();b uuid:=gen_random_uuid();ad uuid:=gen_random_uuid();em uuid:=gen_random_uuid();
 i uuid:=gen_random_uuid();j uuid:=gen_random_uuid();u uuid:=gen_random_uuid();e uuid:=gen_random_uuid();eb uuid:=gen_random_uuid();
 r uuid:=gen_random_uuid();rb uuid:=gen_random_uuid();v jsonb;before_row jsonb;before_event jsonb;who uuid;s text;clock timestamptz:='2026-10-25 10:00:00+01';
begin
 insert into public.tenants(id,slug,name,status) values(a,'i1d-'||a,'Synthetic A','active'),(b,'i1d-'||b,'Synthetic B','active');
 insert into public.tenant_plan_assignments(tenant_id,plan_id,status) select t,id,'active' from unnest(array[a,b])t cross join public.saas_plans where plan_key='current_full_v1';
 insert into auth.users(id,email,email_confirmed_at) select x,x||'@example.invalid',now() from unnest(array[ad,em,i,j,u])x;
 insert into public.profiles(id,user_id,email,full_name) select id,id,email,'Synthetic' from auth.users where id=any(array[ad,em,i,j,u]) on conflict(user_id) do nothing;
 delete from public.tenant_memberships where user_id=any(array[ad,em,i,j,u]);
 insert into public.tenant_memberships(tenant_id,user_id,role,status) values(a,ad,'admin','active'),(a,em,'employee','active'),(a,i,'instructor','active'),(a,j,'instructor','active'),(a,u,'user','active'),(b,i,'user','active');
 insert into public.events(id,tenant_id,title,event_date,start_time,end_time) values(e,a,'Synthetic',current_date,'00:00','23:59'),(eb,b,'Synthetic B',current_date,'00:00','23:59');
 insert into public.event_registrations(id,tenant_id,event_id,user_id,customer_name,customer_email,customer_phone) values(r,a,e,u,'Synthetic','recipient@example.invalid','0'),(rb,b,eb,u,'Synthetic','recipient@example.invalid','0');
 insert into public.event_instructors(tenant_id,event_id,instructor_user_id,assigned_by) values(a,e,i,ad);
 perform set_config('app.product10d_test_enforce','on',true);
 perform pg_temp.ok('default unmarked', (select attendance_status='unmarked' and attendance_version=0 and attendance_marked_at is null and attendance_marked_by is null from public.event_registrations where id=r));
 perform pg_temp.ok('boundary start inclusive',public.event_attendance_window_v1(clock,clock+interval '1h',clock-interval '2h'));
 perform pg_temp.ok('before start denied',not public.event_attendance_window_v1(clock,clock+interval '1h',clock-interval '2h 0.000001 seconds'));
 perform pg_temp.ok('during event',public.event_attendance_window_v1(clock,clock+interval '1h',clock));
 perform pg_temp.ok('event end',public.event_attendance_window_v1(clock,clock+interval '1h',clock+interval '1h'));
 perform pg_temp.ok('end inclusive',public.event_attendance_window_v1(clock,clock+interval '1h',clock+interval '25h'));
 perform pg_temp.ok('after end denied',not public.event_attendance_window_v1(clock,clock+interval '1h',clock+interval '25h 0.000001 seconds'));
 perform pg_temp.ok('null time fail closed',not public.event_attendance_window_v1(null,clock,clock));
 foreach who in array array[ad,em,i] loop
  v:=pg_temp.actor(who,format('select public.set_event_registration_attendance_v1(%L,''present'',0)',r));
  perform pg_temp.ok('authorized actor '||who,v->>'attendance_status'='present' and v->>'attendance_version'='1');
  select to_jsonb(x) into before_row from public.event_registrations x where id=r;
  v:=pg_temp.actor(who,format('select public.set_event_registration_attendance_v1(%L,''present'',1)',r));
  perform pg_temp.ok('same value no-op '||who,v->>'changed'='false' and before_row=(select to_jsonb(x) from public.event_registrations x where id=r));
  perform pg_temp.ok('stale version conflict',pg_temp.actor(who,format('select public.set_event_registration_attendance_v1(%L,''no_show'',0)',r))->>'error'='40001');
  v:=pg_temp.actor(who,format('select public.set_event_registration_attendance_v1(%L,''unmarked'',1)',r));
  perform pg_temp.ok('clear allowed',v->>'attendance_status'='unmarked' and v->>'attendance_version'='2');
  update public.event_registrations set attendance_status='unmarked',attendance_version=0,attendance_marked_at=null,attendance_marked_by=null where id=r;
 end loop;
 foreach who in array array[j,u] loop
  perform pg_temp.ok('unauthorized actor '||who,pg_temp.actor(who,format('select public.set_event_registration_attendance_v1(%L,''present'',0)',r))->>'error'='42501');
 end loop;
 foreach who in array array[ad,em,i] loop
  perform pg_temp.ok('cross tenant '||who,pg_temp.actor(who,format('select public.set_event_registration_attendance_v1(%L,''present'',0)',rb))->>'error'='42501');
 end loop;
 foreach s in array array['pending','suspended'] loop
  update public.tenant_memberships set status=s where user_id=i and tenant_id=a;
  perform pg_temp.ok('membership '||s,pg_temp.actor(i,format('select public.set_event_registration_attendance_v1(%L,''present'',0)',r))->>'error'='42501');
 end loop;
 update public.tenant_memberships set status='active' where user_id=i and tenant_id=a;
 foreach s in array array['reserve','cancelled','participant','unknown'] loop
  update public.event_registrations set registration_status=s where id=r;
  perform pg_temp.ok('registration status '||s,pg_temp.actor(i,format('select public.set_event_registration_attendance_v1(%L,''present'',0)',r))->>'error'='42501');
 end loop;
 update public.event_registrations set registration_status='approved' where id=r;
 v:=pg_temp.actor(i,format('select public.set_event_registration_attendance_v1(%L,''no_show'',0)',r));
 perform pg_temp.ok('approved allowed',v->>'attendance_status'='no_show');
 select to_jsonb(x) into before_row from public.event_registrations x where id=r;
 select to_jsonb(x) into before_event from public.events x where id=e;
 perform set_config('app.i1d_fail_audit','on',true);
 v:=pg_temp.actor(i,format('select public.set_event_registration_attendance_v1(%L,''present'',1)',r));
 perform pg_temp.ok('audit failure rollback',v->>'error'='P0001' and before_row=(select to_jsonb(x) from public.event_registrations x where id=r));
 perform set_config('app.i1d_fail_audit','off',true);
 foreach who in array array[u,i,ad,em] loop
  perform pg_temp.ok('direct actor update denied '||who,pg_temp.actor(who,format('update public.event_registrations set attendance_marked_by=null where id=%L returning to_jsonb(event_registrations)',r))->>'error'='42501');
 end loop;
 perform pg_temp.ok('anon writer denied',pg_temp.actor(null,format('select public.set_event_registration_attendance_v1(%L,''present'',1)',r),'anon')->>'error'='42501');
 perform pg_temp.ok('service writer denied',pg_temp.actor(i,format('select public.set_event_registration_attendance_v1(%L,''present'',1)',r),'service_role')->>'error'='42501');
 perform pg_temp.ok('service direct actor update denied',pg_temp.actor(i,format('update public.event_registrations set attendance_marked_by=null where id=%L returning to_jsonb(event_registrations)',r),'service_role')->>'error'='42501');
 perform pg_temp.ok('ordinary actor cannot delete another profile',pg_temp.actor(u,format('delete from public.profiles where user_id=%L returning to_jsonb(profiles)',i))->>'error'='42501');
 perform pg_temp.ok('attendance RPC owner and path',(select pg_get_userbyid(proowner)='postgres' and proconfig @> array['search_path=pg_catalog, public, pg_temp'] from pg_proc where oid='public.set_event_registration_attendance_v1(uuid,text,bigint)'::regprocedure));
 perform pg_temp.ok('no PUBLIC execute widening',not exists(select 1 from pg_proc p cross join lateral aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a where p.oid in('public.set_event_registration_attendance_v1(uuid,text,bigint)'::regprocedure,'public.guard_event_attendance_v1()'::regprocedure,'public.event_attendance_window_v1(timestamptz,timestamptz,timestamptz)'::regprocedure) and a.grantee=0 and a.privilege_type='EXECUTE'));
 perform pg_temp.ok('private helpers not browser callable',not has_function_privilege('authenticated','public.guard_event_attendance_v1()','EXECUTE') and not has_function_privilege('authenticated','public.event_attendance_window_v1(timestamptz,timestamptz,timestamptz)','EXECUTE'));
 perform pg_temp.ok('event unchanged by attendance',(select to_jsonb(x)=before_event from public.events x where id=e));
 update public.events set event_date=current_date-40 where id=e;
 perform pg_temp.ok('instructor late denied',pg_temp.actor(i,format('select public.set_event_registration_attendance_v1(%L,''present'',1)',r))->>'error'='42501');
 perform pg_temp.ok('instructor PII expired',pg_temp.actor(i,format('select public.get_instructor_event_participants_v1(%L)',e))->>'error'='42501');
 v:=pg_temp.actor(em,format('select public.set_event_registration_attendance_v1(%L,''present'',1)',r));
 perform pg_temp.ok('employee late correction',v->>'attendance_status'='present');
 -- Canonical actor anonymization, active tenant; actor is not the participant.
 select to_jsonb(x) into before_row from public.event_registrations x where id=r;
 v:=pg_temp.actor(em,'select public.anonymize_my_account_v1()');
 perform pg_temp.ok('active canonical actor deletion',not exists(select 1 from public.profiles where user_id=em));
 perform pg_temp.ok('active history preserved',(select attendance_marked_by is null and to_jsonb(x)-'attendance_marked_by'=before_row-'attendance_marked_by' from public.event_registrations x where id=r));
 update public.events set event_date=current_date where id=e;
 v:=pg_temp.actor(i,format('select public.set_event_registration_attendance_v1(%L,''no_show'',2)',r));
 perform pg_temp.ok('instructor mark before suspension',v->>'attendance_version'='3');
 select to_jsonb(x) into before_row from public.event_registrations x where id=r;
 update public.tenants set status='suspended' where id=a;
 perform pg_temp.ok('normal suspended writer deny',pg_temp.actor(ad,format('select public.set_event_registration_attendance_v1(%L,''present'',3)',r))->>'error'='42501');
 v:=pg_temp.actor(i,'select public.anonymize_my_account_v1()');
 perform pg_temp.ok('suspended canonical actor deletion',not exists(select 1 from public.profiles where user_id=i));
 perform pg_temp.ok('suspended history preserved',(select attendance_marked_by is null and to_jsonb(x)-'attendance_marked_by'=before_row-'attendance_marked_by' from public.event_registrations x where id=r));
 perform pg_temp.ok('no tenant B cleanup',(select attendance_version=0 and attendance_status='unmarked' from public.event_registrations where id=rb));
 update public.tenants set status='active' where id=a;
 update public.events set event_date=current_date+2 where id=e;
 v:=pg_temp.actor(ad,format('select public.admin_cancel_event_v1(%L)',e));
 perform pg_temp.ok('cancel event',(select cancelled_at is not null from public.events where id=e));
 perform pg_temp.ok('cancelled event denies admin',pg_temp.actor(ad,format('select public.set_event_registration_attendance_v1(%L,''present'',3)',r))->>'error'='42501');
 perform pg_temp.ok('audit minimal',not exists(select 1 from public.audit_logs l cross join lateral jsonb_object_keys(l.details) k where l.action='event_attendance_changed' and l.tenant_id=a and k not in ('event_id','old_status','new_status')));
 perform pg_temp.ok('definer exact delta',(select count(*)=143 from pg_proc where pronamespace='public'::regnamespace and prosecdef));
end;$test$;
select 'ok - '||name from attendance_results;
select count(*) as assertions from attendance_results;
rollback;
