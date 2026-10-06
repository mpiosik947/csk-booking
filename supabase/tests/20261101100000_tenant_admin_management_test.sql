\set ON_ERROR_STOP on
begin;
select set_config('app.product10d_test_enforce','on',true);
create temporary table results(n serial,label text) on commit drop;
create function pg_temp.ok(label text,passed boolean) returns void language plpgsql as $$begin
 if passed is distinct from true then raise exception 'FAIL: %',label; end if;
 insert into results(label) values(label);
end;$$;
create function pg_temp.rpc(actor uuid,statement text) returns jsonb language plpgsql as $$
declare result jsonb;
begin
 perform set_config('request.jwt.claims',jsonb_build_object('sub',actor,'role',case when actor is null then 'anon' else 'authenticated' end)::text,true);
 perform set_config('request.jwt.claim.sub',coalesce(actor::text,''),true);
 if actor is null then set local role anon; else set local role authenticated; end if;
 execute statement into result;
 reset role;
 perform set_config('request.jwt.claims','{}',true); perform set_config('request.jwt.claim.sub','',true);
 return jsonb_build_object('state','00000','value',result);
exception when others then
 reset role;
 perform set_config('request.jwt.claims','{}',true); perform set_config('request.jwt.claim.sub','',true);
 return jsonb_build_object('state',sqlstate,'error',sqlerrm);
end;$$;
create function pg_temp.change(actor uuid,t uuid,u uuid,op text,req uuid default gen_random_uuid()) returns jsonb language plpgsql as $$
declare state jsonb;
begin
 select jsonb_build_object('role',role,'status',status) into state from public.tenant_memberships where tenant_id=t and user_id=u;
 return pg_temp.rpc(actor,format('select public.platform_%s_tenant_admin_v1(%L,%L,%L::jsonb,%L)',op,t,u,state,req));
end;$$;
do $test$
declare pa uuid:=gen_random_uuid(); a uuid:=gen_random_uuid(); b uuid:=gen_random_uuid(); u uuid:=gen_random_uuid();
 t uuid:=gen_random_uuid(); other uuid:=gen_random_uuid(); r jsonb; q text; req uuid:=gen_random_uuid(); role_name text;
 e uuid:=gen_random_uuid(); i uuid:=gen_random_uuid(); d uuid:=gen_random_uuid(); count_before bigint;
begin
 insert into auth.users(id,email,email_confirmed_at,is_anonymous) select id,id||'@example.invalid',now(),false from unnest(array[pa,a,b,u]) id;
 insert into public.profiles(id,user_id,email,role) select id,id,email,'user' from auth.users where id=any(array[pa,a,b,u]) on conflict(user_id) do nothing;
 insert into public.platform_admins(user_id,status)values(pa,'active');
 insert into public.tenants(id,name,slug,status)values(t,'Synthetic','pam1b-'||t,'active'),(other,'Synthetic B','pam1b-'||other,'dormant');
 insert into public.tenant_public_profiles(tenant_id,public_slug,display_name,city) values(t,'pam1b-public-'||t,'Synthetic','Local'),(other,'pam1b-public-'||other,'Synthetic B','Local');
 insert into public.tenant_plan_assignments(tenant_id,plan_id,status) select t,id,'active' from public.saas_plans where plan_key='current_full_v1';
 r:=pg_temp.change(pa,t,a,'add'); perform pg_temp.ok('add absent: '||r::text,r->>'state'='00000');
 perform pg_temp.ok('sole demote denied',pg_temp.change(pa,t,a,'demote')->>'error'='LAST_ACTIVE_ADMIN');
 perform pg_temp.ok('sole suspend denied',pg_temp.change(pa,t,a,'suspend')->>'error'='LAST_ACTIVE_ADMIN');
 perform pg_temp.ok('sole privacy denied',pg_temp.rpc(a,'select public.anonymize_my_account_v1()')->>'error'='LAST_ACTIVE_ADMIN');
 begin delete from public.tenant_memberships where tenant_id=t and user_id=a; raise exception 'unguarded delete';
 exception when check_violation then perform pg_temp.ok('direct delete guarded',sqlerrm='LAST_ACTIVE_ADMIN'); end;
 perform pg_temp.ok('second admin',pg_temp.change(pa,t,b,'add')->>'state'='00000');
 insert into public.tenant_memberships(tenant_id,user_id,role,status)values(other,a,'user','active');
 q:=format('select public.platform_demote_tenant_admin_v1(%L,%L,%L::jsonb,%L)',t,a,'{"role":"admin","status":"active"}',req);
 r:=pg_temp.rpc(pa,q);perform pg_temp.ok('demote two',r->>'state'='00000');
 perform pg_temp.ok('replay same',pg_temp.rpc(pa,q)=r);
 perform pg_temp.ok('single audit',(select count(*)=1 from public.platform_audit_logs where tenant_id=t and details->>'request_id'=req::text));
 perform pg_temp.ok('cross tenant unchanged',(select role='user' and status='active' from public.tenant_memberships where tenant_id=other and user_id=a));
 perform pg_temp.ok('replay mismatch',pg_temp.change(pa,t,b,'suspend',req)->>'error'='REQUEST_REPLAY_MISMATCH');
 perform pg_temp.ok('active user promoted',pg_temp.change(pa,t,a,'add')->>'state'='00000');
 perform pg_temp.ok('suspend two',pg_temp.change(pa,t,a,'suspend')->>'state'='00000');
 perform pg_temp.ok('generic add cannot reactivate',pg_temp.change(pa,t,a,'add')->>'error'='MEMBERSHIP_SUSPENDED');
 perform pg_temp.ok('explicit reactivate',pg_temp.change(pa,t,a,'reactivate')->>'state'='00000');
 perform pg_temp.ok('active reactivate noop',pg_temp.change(pa,t,a,'reactivate')->'value'->>'code'='no_change');
 perform pg_temp.ok('active add noop',pg_temp.change(pa,t,a,'add')->'value'->>'code'='no_change');
 r:=pg_temp.rpc(pa,format('select public.platform_get_tenant_admin_management_v1(%L)',t));
 perform pg_temp.ok('multiple reader',(r->'value'->>'active_admin_count')::int=2);
 perform pg_temp.ok('DTO boundary',not (r::text ~ 'phone|address|reservation|verification|notes'));
 foreach role_name in array array['user','employee','instructor'] loop
  insert into public.tenant_memberships(tenant_id,user_id,role,status)values(t,u,role_name,'active')
   on conflict(tenant_id,user_id) do update set role=excluded.role,status=excluded.status;
  perform pg_temp.ok('non PA deny '||role_name,pg_temp.change(u,t,a,'suspend')->>'state'='42501');
  perform pg_temp.ok('promote '||role_name,pg_temp.change(pa,t,u,'add')->>'state'='00000');
  perform pg_temp.ok('promoted role '||role_name,(select role='admin' and status='active' from public.tenant_memberships where tenant_id=t and user_id=u));
 end loop;
 perform pg_temp.ok('tenant admin no PA',pg_temp.change(a,t,b,'demote')->>'state'='42501');
 perform pg_temp.ok('anon denied',pg_temp.change(null,t,b,'demote')->>'state'='42501');
 update public.platform_admins set status='suspended' where user_id=pa;
 perform pg_temp.ok('suspended PA denied',pg_temp.change(pa,t,b,'demote')->>'state'='42501');
 delete from public.platform_admins where user_id=pa;
 perform pg_temp.ok('removed PA denied',pg_temp.change(pa,t,b,'demote')->>'state'='42501');
 insert into public.platform_admins(user_id,status)values(pa,'active');
 update public.tenant_memberships set role='user',status='pending' where tenant_id=t and user_id=u;
 perform pg_temp.ok('pending blocked',pg_temp.change(pa,t,u,'add')->>'error'='MEMBERSHIP_PENDING');
 update public.tenant_memberships set status='suspended' where tenant_id=t and user_id=u;
 perform pg_temp.ok('suspended user blocked',pg_temp.change(pa,t,u,'add')->>'error'='MEMBERSHIP_SUSPENDED');
 perform pg_temp.ok('nonadmin reactivate blocked',pg_temp.change(pa,t,u,'reactivate')->>'error'='NOT_TENANT_ADMIN');
 update public.tenant_memberships set role='instructor',status='active' where tenant_id=t and user_id=u;
 insert into public.events(id,tenant_id,title,event_date,start_time,end_time,is_active)values(e,t,'Synthetic',current_date+5,'10:00','11:00',true);
 -- Source fixtures are postgres-only; assignment guard still validates instructor role.
 perform set_config('app.product10d_test_enforce','off',true);
 insert into public.event_instructors(id,tenant_id,event_id,instructor_user_id,assigned_by)values(i,t,e,u,a);
 perform set_config('app.product10d_test_enforce','on',true);
 perform pg_temp.ok('future assignment blocks',pg_temp.change(pa,t,u,'add')->>'error'='INSTRUCTOR_HAS_OPEN_OBLIGATIONS');
 update public.events set event_date=current_date-5 where id=e;
 perform pg_temp.ok('historical pending notification blocks',pg_temp.change(pa,t,u,'add')->>'error'='INSTRUCTOR_HAS_OPEN_OBLIGATIONS');
 update public.email_deliveries set delivery_state='sent',sent_at=now(),attempt_count=1 where tenant_id=t and recipient_user_id=u;
 perform pg_temp.ok('closed history permits',pg_temp.change(pa,t,u,'add')->>'state'='00000');
 perform pg_temp.ok('history preserved',(select count(*)=1 from public.event_instructors where id=i and unassigned_at is null));
 perform pg_temp.ok('own instructor reader denied',pg_temp.rpc(u,format('select public.get_my_instructor_events_v1(%L)',t))->>'state'='42501');
 perform pg_temp.ok('candidate list excludes promoted',not (pg_temp.rpc(a,format('select public.admin_list_tenant_instructors_v1(%L)',t))->'value' @> jsonb_build_array(jsonb_build_object('user_id',u))));
 perform pg_temp.ok('new assignment cannot retain promoted',pg_temp.rpc(a,format('select public.admin_set_event_instructors_v1(%L,array[%L]::uuid[],%L)',e,u,repeat('0',64)))->>'state'='42501');
end;$test$;

do $regressions$
declare t uuid; u uuid; e uuid; b uuid; pa uuid; other uuid; q text; r jsonb; req uuid; op text; state jsonb; role_state text; registration uuid:=gen_random_uuid();
begin
 select i.tenant_id,i.instructor_user_id,i.event_id into strict t,u,e from public.event_instructors i join public.tenants n on n.id=i.tenant_id where n.slug like 'pam1b-%';
 select user_id into strict pa from public.platform_admins where status='active';
 select id into strict other from public.tenants where name='Synthetic B';
 select user_id into b from public.tenant_memberships where tenant_id=t and user_id<>u and role='admin' limit 1;
 insert into public.tenant_memberships(tenant_id,user_id,role,status)values(other,u,'user','active');
 foreach op in array array['add','reactivate','demote','suspend'] loop
  update public.tenant_memberships set role=case when op='add' then 'user' else 'admin' end,status=case when op='reactivate' then 'suspended' else 'active' end where tenant_id=t and user_id=u;
  select jsonb_build_object('role',role,'status',status) into state from public.tenant_memberships where tenant_id=t and user_id=u;
  req:=gen_random_uuid();q:=format('select public.platform_%s_tenant_admin_v1(%L,%L,%L::jsonb,%L)',op,t,u,state,req);
  r:=pg_temp.rpc(pa,q);
  perform pg_temp.ok(op||' writer success',r->>'state'='00000');
  perform pg_temp.ok(op||' exact replay',pg_temp.rpc(pa,q)=r);
  perform pg_temp.ok(op||' audit exactly once',(select count(*)=1 from public.platform_audit_logs where details->>'request_id'=req::text));
  perform pg_temp.ok(op||' replay mismatch',pg_temp.rpc(pa,replace(q,u::text,b::text))->>'error'='REQUEST_REPLAY_MISMATCH');
  perform pg_temp.ok(op||' other tenant unchanged',(select role='user' and status='active' from public.tenant_memberships where tenant_id=other and user_id=u));
  perform pg_temp.ok(op||' non PA denied',pg_temp.rpc(b,q)->>'state'='42501');
  perform pg_temp.ok(op||' anon denied',pg_temp.rpc(null,q)->>'state'='42501');
 end loop;
 foreach role_state in array array['active','pending','suspended'] loop
  update public.tenant_memberships set role='admin',status=role_state where tenant_id=t and user_id=u;
  r:=pg_temp.rpc(pa,format('select public.platform_get_tenant_admin_management_v1(%L)',t));
  perform pg_temp.ok('reader admin status '||role_state,r->'value'->'admins' @> jsonb_build_array(jsonb_build_object('user_id',u,'membership_status',role_state)));
 end loop;
 perform pg_temp.ok('reader non PA denied',pg_temp.rpc(b,format('select public.platform_get_tenant_admin_management_v1(%L)',t))->>'state'='42501');
 perform pg_temp.ok('reader cross tenant excludes target A admins',not (pg_temp.rpc(pa,format('select public.platform_get_tenant_admin_management_v1(%L)',other))->'value'->'admins' @> jsonb_build_array(jsonb_build_object('user_id',u))));
 update public.profiles set phone='PII-PHONE-SECRET',admin_note='PII-NOTE-SECRET' where user_id=u;
 r:=pg_temp.rpc(pa,format('select public.platform_get_tenant_admin_management_v1(%L)',t));
 perform pg_temp.ok('reader PII sentinels absent',r::text not like '%PII-PHONE-SECRET%' and r::text not like '%PII-NOTE-SECRET%');
 update public.tenant_memberships set role='instructor',status='active' where tenant_id=t and user_id=u;
 update public.email_deliveries set delivery_state='failed',sent_at=null,attempt_count=3,last_error_code='retry_exhausted',attempt_window_started_at=now()-interval '24 hours' where tenant_id=t and recipient_user_id=u;
 perform pg_temp.ok('terminal failed history permits',pg_temp.change(pa,t,u,'add')->>'state'='00000');
 update public.tenant_memberships set role='instructor' where tenant_id=t and user_id=u;
 update public.email_deliveries set attempt_count=1,last_error_code='provider_error',attempt_window_started_at=now() where tenant_id=t and recipient_user_id=u;
 perform pg_temp.ok('retryable failed blocks',pg_temp.change(pa,t,u,'add')->>'error'='INSTRUCTOR_HAS_OPEN_OBLIGATIONS');
 update public.email_deliveries set delivery_state='sending',claim_id=gen_random_uuid(),claim_expires_at=now()+interval '5 minutes',attempt_count=3 where tenant_id=t and recipient_user_id=u;
 perform pg_temp.ok('active last-attempt lease blocks',pg_temp.change(pa,t,u,'add')->>'error'='INSTRUCTOR_HAS_OPEN_OBLIGATIONS');
 update public.email_deliveries set delivery_state='sent',sent_at=now(),claim_id=null,claim_expires_at=null where tenant_id=t and recipient_user_id=u;
 update public.events set event_date=current_date-1,start_time='23:00',end_time='23:59' where id=e;
 insert into public.event_registrations(id,tenant_id,event_id,user_id,customer_name,customer_email,customer_phone,registration_status,payment_status)
 values(registration,t,e,b,'PRIVATE CUSTOMER','private@example.invalid','PRIVATE PHONE','registered','free');
 perform pg_temp.ok('open attendance blocks',pg_temp.change(pa,t,u,'add')->>'error'='INSTRUCTOR_HAS_OPEN_OBLIGATIONS');
 update public.event_registrations set attendance_status='present',attendance_version=1,attendance_marked_at=now(),attendance_marked_by=b where id=registration;
 perform pg_temp.ok('closed attendance permits',pg_temp.change(pa,t,u,'add')->>'state'='00000');
 perform pg_temp.ok('attendance history retained',(select attendance_status='present' from public.event_registrations where id=registration));
 foreach role_state in array array['dormant','active','suspended'] loop
  update public.tenants set status=role_state where id=other;
  perform pg_temp.ok('manage tenant state '||role_state,pg_temp.change(pa,other,u,'add')->>'state'='00000');
  perform pg_temp.ok('last admin in tenant state '||role_state,pg_temp.change(pa,other,u,'demote')->>'error'='LAST_ACTIVE_ADMIN');
 end loop;
end;$regressions$;

select 'ok '||n||' - '||label from results order by n;
rollback;
