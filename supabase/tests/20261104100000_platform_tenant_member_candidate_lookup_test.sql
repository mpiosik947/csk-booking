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
create function pg_temp.lookup(actor uuid,t uuid,email text) returns jsonb language sql as $$
 select pg_temp.rpc(actor,format('select public.platform_lookup_tenant_admin_candidate_v1(%L,%L)',t,email));
$$;
-- Integration deliberately derives expected_state only from the returned DTO.
-- It does not peek at tenant_memberships or guess a role on a failed mutation.
create function pg_temp.expected(candidate jsonb) returns jsonb language sql as $$
 select case when (candidate->'membership'->>'exists')::boolean
 then jsonb_build_object('role',candidate->'membership'->'role','status',candidate->'membership'->'status') else null end;
$$;

do $tests$
declare pa uuid:=gen_random_uuid(); anchor uuid:=gen_random_uuid(); u uuid:=gen_random_uuid(); stranger uuid:=gen_random_uuid();
 t uuid:=gen_random_uuid(); b uuid:=gen_random_uuid(); archived uuid:=gen_random_uuid();
 email text:=u||'@example.invalid'; candidate jsonb; r jsonb; q text; req uuid; role_name text; member_status text; lifecycle text;
 e uuid:=gen_random_uuid(); assignment uuid:=gen_random_uuid(); duplicate uuid:=gen_random_uuid(); bad_email text;
 before_audit bigint; before_requests bigint; before_members jsonb;
begin
 insert into auth.users(id,email,email_confirmed_at,is_anonymous,raw_user_meta_data)
 select id,id||'@example.invalid',now(),false,'{"phone":"PRIVATE PHONE","address":"PRIVATE ADDRESS"}'::jsonb
 from unnest(array[pa,anchor,u,stranger]) id;
 insert into public.profiles(id,user_id,email,role) select account.id,account.id,account.email,'user' from auth.users account where account.id=any(array[pa,anchor,u,stranger]) on conflict(user_id) do nothing;
 update public.profiles set phone='PRIVATE PHONE',admin_note='PRIVATE NOTE' where user_id=u;
 insert into public.platform_admins(user_id,status)values(pa,'active');
 insert into public.tenants(id,name,slug,status)values(t,'Lookup A','pam1er1-'||t,'active'),(b,'Lookup B','pam1er1-'||b,'active'),(archived,'Archived','pam1er1-'||archived,'archived');
 insert into public.tenant_plan_assignments(tenant_id,plan_id,status)select x,p.id,'active' from unnest(array[t,b])x cross join public.saas_plans p where p.plan_key='current_full_v1';
 insert into public.tenant_memberships(tenant_id,user_id,role,status)values(t,anchor,'admin','active'),(b,anchor,'admin','active');
 r:=pg_temp.lookup(pa,t,email); candidate:=r->'value';
 perform pg_temp.ok('active PA can lookup exact account',r->>'state'='00000' and candidate->>'user_id'=u::text and candidate->>'email'=email);
 perform pg_temp.ok('absent membership is explicit',candidate->'membership'='{"exists":false,"role":null,"status":null}'::jsonb);
 perform pg_temp.ok('absent expected_state is SQL null',pg_temp.expected(candidate) is null);
 perform pg_temp.ok('root DTO allowlist',(select array_agg(k order by k) from jsonb_object_keys(candidate)k)=array['email','membership','user_id']);
 perform pg_temp.ok('membership DTO allowlist',(select array_agg(k order by k) from jsonb_object_keys(candidate->'membership')k)=array['exists','role','status']);
 perform pg_temp.ok('no auth/profile/customer metadata',not(candidate::text ~ 'PRIVATE|phone|address|note|confirmed|provider|metadata|login|identities|reservation|payment'));
 perform pg_temp.ok('normalized exact case and surrounding spaces',pg_temp.lookup(pa,t,'  '||upper(email)||'  ')=r);
 perform pg_temp.ok('nonexistent safe null',pg_temp.lookup(pa,t,'missing-'||email)='{"state":"00000","value":null}'::jsonb);
 perform pg_temp.ok('substring is not a match',pg_temp.lookup(pa,t,substring(email from 2))->'value'='null'::jsonb);
 perform pg_temp.ok('percent is literal, not wildcard',pg_temp.lookup(pa,t,'%@example.invalid')->'value'='null'::jsonb);
 perform pg_temp.ok('underscore is literal, not wildcard',pg_temp.lookup(pa,t,'_'||substring(email from 2))->'value'='null'::jsonb);
 foreach bad_email in array array[null,'','   ','not-email','a@b','a b@example.invalid',E'a\nb@example.invalid',repeat('a',255)||'@example.invalid'] loop
  perform pg_temp.ok('invalid exact-email input rejected',pg_temp.lookup(pa,t,bad_email)->>'state'='22023');
 end loop;
 perform pg_temp.ok('null tenant rejected',pg_temp.lookup(pa,null,email)->>'error'='TENANT_UNAVAILABLE');
 perform pg_temp.ok('unknown tenant rejected',pg_temp.lookup(pa,gen_random_uuid(),email)->>'error'='TENANT_UNAVAILABLE');
 perform pg_temp.ok('archived tenant can be inspected',pg_temp.lookup(pa,archived,email)->>'state'='00000');
 foreach lifecycle in array array['dormant','suspended','active'] loop
  update public.tenants set status=lifecycle where id=t;
  perform pg_temp.ok(lifecycle||' tenant can be inspected',pg_temp.lookup(pa,t,email)->>'state'='00000');
 end loop;

 -- Reader result is unchanged by global profile role and is scoped only to t.
 insert into public.tenant_memberships(tenant_id,user_id,role,status)values(b,u,'admin','active');
 foreach role_name in array array['user','employee','instructor','admin'] loop
  foreach member_status in array array['active','suspended','pending'] loop
   insert into public.tenant_memberships(tenant_id,user_id,role,status)values(t,u,role_name,member_status)
    on conflict(tenant_id,user_id)do update set role=excluded.role,status=excluded.status;
   r:=pg_temp.lookup(pa,t,email); candidate:=r->'value';
   perform pg_temp.ok('exact membership '||role_name||'/'||member_status,r->>'state'='00000' and candidate->'membership'=jsonb_build_object('exists',true,'role',role_name,'status',member_status));
   perform pg_temp.ok('canonical expected_state '||role_name||'/'||member_status,pg_temp.expected(candidate)=jsonb_build_object('role',role_name,'status',member_status));
  end loop;
 end loop;
 update public.tenant_memberships set role='instructor',status='active' where tenant_id=t and user_id=u;
 perform pg_temp.ok('A instructor isolated',pg_temp.lookup(pa,t,email)->'value'->'membership'='{"exists":true,"role":"instructor","status":"active"}'::jsonb);
 perform pg_temp.ok('B admin isolated',pg_temp.lookup(pa,b,email)->'value'->'membership'='{"exists":true,"role":"admin","status":"active"}'::jsonb);
 perform pg_temp.ok('third tenant does not inherit membership',pg_temp.lookup(pa,archived,email)->'value'->'membership'='{"exists":false,"role":null,"status":null}'::jsonb);

 foreach role_name in array array['admin','employee','instructor','user'] loop
  update public.tenant_memberships set role=role_name where tenant_id=t and user_id=u;
  perform pg_temp.ok('tenant '||role_name||' without PA denied',pg_temp.lookup(u,t,email)->>'state'='42501');
 end loop;
 update public.profiles set role='admin' where user_id=stranger;
 perform pg_temp.ok('global profile admin gives no PA authority',pg_temp.lookup(stranger,t,email)->>'state'='42501');
 perform pg_temp.ok('anon denied',pg_temp.lookup(null,t,email)->>'state'='42501');
 perform pg_temp.ok('auth denied before input validation',pg_temp.lookup(stranger,null,null)->>'state'='42501');
 update public.platform_admins set status='suspended' where user_id=pa;
 perform pg_temp.ok('suspended PA denied',pg_temp.lookup(pa,t,email)->>'state'='42501');
 delete from public.platform_admins where user_id=pa;
 perform pg_temp.ok('removed PA denied',pg_temp.lookup(pa,t,email)->>'state'='42501');
 insert into public.platform_admins(user_id,status)values(pa,'active');
 insert into public.tenant_memberships(tenant_id,user_id,role,status)values(t,pa,'user','active');
 perform pg_temp.ok('combined PA and tenant user allowed',pg_temp.lookup(pa,t,email)->>'state'='00000');

 -- Existing account eligibility is preserved without exposing its reasons.
 update auth.users set email_confirmed_at=null where id=u;
 perform pg_temp.ok('unconfirmed account safe null',pg_temp.lookup(pa,t,email)->'value'='null'::jsonb);
 update auth.users set email_confirmed_at=now(),banned_until=now()+interval '1 day' where id=u;
 perform pg_temp.ok('banned account safe null',pg_temp.lookup(pa,t,email)->'value'='null'::jsonb);
 update auth.users set banned_until=null,is_anonymous=true where id=u;
 perform pg_temp.ok('anonymous account safe null',pg_temp.lookup(pa,t,email)->'value'='null'::jsonb);
 update auth.users set is_anonymous=false,deleted_at=now() where id=u;
 perform pg_temp.ok('deleted account safe null',pg_temp.lookup(pa,t,email)->'value'='null'::jsonb);
 update auth.users set deleted_at=null where id=u;
 insert into auth.users(id,email,email_confirmed_at,is_anonymous)values(duplicate,upper(email),now(),false);
 insert into public.profiles(id,user_id,email)values(duplicate,duplicate,upper(email))on conflict(user_id)do nothing;
 perform pg_temp.ok('ambiguous normalized email fails closed',pg_temp.lookup(pa,t,email)->>'error'='Account cannot be selected');
 -- Remove ambiguity without deleting an Auth fixture mid-test.
 update auth.users set email=duplicate||'@example.invalid' where id=duplicate;

 select count(*) into before_audit from public.platform_audit_logs;
 select count(*) into before_requests from public.platform_admin_management_requests;
 select jsonb_agg(to_jsonb(m) order by tenant_id,user_id) into before_members from public.tenant_memberships m;
 perform pg_temp.lookup(pa,t,email); perform pg_temp.lookup(pa,b,email);
 perform pg_temp.ok('lookup writes no audit',before_audit=(select count(*) from public.platform_audit_logs));
 perform pg_temp.ok('lookup writes no request ledger',before_requests=(select count(*) from public.platform_admin_management_requests));
 perform pg_temp.ok('lookup does not mutate memberships',before_members=(select jsonb_agg(to_jsonb(m) order by tenant_id,user_id) from public.tenant_memberships m));

 -- Every mutation below uses only freshly returned reader state, not table reads.
 candidate:=pg_temp.lookup(pa,t,stranger||'@example.invalid')->'value';
 r:=pg_temp.rpc(pa,format('select public.platform_add_tenant_admin_v1(%L,%L,%L::jsonb,%L)',t,candidate->>'user_id',pg_temp.expected(candidate),gen_random_uuid()));
 perform pg_temp.ok('reader absent -> existing add writer',r->>'state'='00000' and r->'value'->>'code'='changed');
 foreach role_name in array array['user','employee','instructor','admin'] loop
  update public.tenant_memberships set role=role_name,status='active' where tenant_id=t and user_id=u;
  candidate:=pg_temp.lookup(pa,t,email)->'value'; req:=gen_random_uuid();
  q:=format('select public.platform_add_tenant_admin_v1(%L,%L,%L::jsonb,%L)',t,candidate->>'user_id',pg_temp.expected(candidate),req);
  r:=pg_temp.rpc(pa,q);
  perform pg_temp.ok('reader -> promote '||role_name,r->>'state'='00000' and r->'value'->>'role'='admin' and r->'value'->>'code'=case when role_name='admin' then 'no_change' else 'changed' end);
  perform pg_temp.ok('same request exact replay '||role_name,pg_temp.rpc(pa,q)=r);
  perform pg_temp.ok('promotion preserves B',pg_temp.lookup(pa,b,email)->'value'->'membership'='{"exists":true,"role":"admin","status":"active"}'::jsonb);
 end loop;
 update public.tenant_memberships set status='suspended' where tenant_id=t and user_id=u;
 candidate:=pg_temp.lookup(pa,t,email)->'value';
 perform pg_temp.ok('suspended admin generic add remains blocked',pg_temp.rpc(pa,format('select public.platform_add_tenant_admin_v1(%L,%L,%L::jsonb,%L)',t,u,pg_temp.expected(candidate),gen_random_uuid()))->>'error'='MEMBERSHIP_SUSPENDED');
 perform pg_temp.ok('reader -> separate reactivation',pg_temp.rpc(pa,format('select public.platform_reactivate_tenant_admin_v1(%L,%L,%L::jsonb,%L)',t,u,pg_temp.expected(candidate),gen_random_uuid()))->>'state'='00000');
 foreach member_status in array array['pending','suspended'] loop
  update public.tenant_memberships set role='employee',status=member_status where tenant_id=t and user_id=u;
  candidate:=pg_temp.lookup(pa,t,email)->'value';
  perform pg_temp.ok('reader -> blocked non-admin '||member_status,pg_temp.rpc(pa,format('select public.platform_add_tenant_admin_v1(%L,%L,%L::jsonb,%L)',t,u,pg_temp.expected(candidate),gen_random_uuid()))->>'error'=case when member_status='pending' then 'MEMBERSHIP_PENDING' else 'MEMBERSHIP_SUSPENDED' end);
 end loop;
 update public.tenant_memberships set role='user',status='active' where tenant_id=t and user_id=u;
 candidate:=pg_temp.lookup(pa,t,email)->'value';
 update public.tenant_memberships set role='employee' where tenant_id=t and user_id=u;
 perform pg_temp.ok('stale lookup cannot authorize promotion',pg_temp.rpc(pa,format('select public.platform_add_tenant_admin_v1(%L,%L,%L::jsonb,%L)',t,u,pg_temp.expected(candidate),gen_random_uuid()))->>'error'='STALE_MEMBERSHIP_STATE');
 perform pg_temp.ok('fresh lookup reports changed state',pg_temp.lookup(pa,t,email)->'value'->'membership'->>'role'='employee');

 update public.tenant_memberships set role='instructor' where tenant_id=t and user_id=u;
 insert into public.events(id,tenant_id,title,event_date,start_time,end_time,is_active)values(e,t,'Local obligation',current_date+5,'10:00','11:00',true);
 perform set_config('app.product10d_test_enforce','off',true);
 insert into public.event_instructors(id,tenant_id,event_id,instructor_user_id,assigned_by)values(assignment,t,e,u,anchor);
 perform set_config('app.product10d_test_enforce','on',true);
 candidate:=pg_temp.lookup(pa,t,email)->'value';
 perform pg_temp.ok('reader identifies instructor for explicit warning',candidate->'membership'='{"exists":true,"role":"instructor","status":"active"}'::jsonb);
 perform pg_temp.ok('writer still owns open-obligation blocker',pg_temp.rpc(pa,format('select public.platform_add_tenant_admin_v1(%L,%L,%L::jsonb,%L)',t,u,pg_temp.expected(candidate),gen_random_uuid()))->>'error'='INSTRUCTOR_HAS_OPEN_OBLIGATIONS');
 perform pg_temp.ok('blocked instructor unchanged',pg_temp.lookup(pa,t,email)->'value'=candidate);

 perform pg_temp.ok('stable postgres definer fixed path',(select provolatile='s' and prosecdef and pg_get_userbyid(proowner)='postgres' and proconfig=array['search_path=pg_catalog, public, pg_temp'] from pg_proc where oid='public.platform_lookup_tenant_admin_candidate_v1(uuid,text)'::regprocedure));
 perform pg_temp.ok('authenticated execute only',has_function_privilege('authenticated','public.platform_lookup_tenant_admin_candidate_v1(uuid,text)','EXECUTE') and not has_function_privilege('anon','public.platform_lookup_tenant_admin_candidate_v1(uuid,text)','EXECUTE') and not has_function_privilege('service_role','public.platform_lookup_tenant_admin_candidate_v1(uuid,text)','EXECUTE'));
 perform pg_temp.ok('no PUBLIC execute',not exists(select 1 from pg_proc p cross join lateral aclexplode(p.proacl)a where p.oid='public.platform_lookup_tenant_admin_candidate_v1(uuid,text)'::regprocedure and a.grantee=0));
 perform pg_temp.ok('exact public function delta',(select count(*)=254 from pg_proc where pronamespace='public'::regnamespace and prokind='f'));
 perform pg_temp.ok('exact definer delta',(select count(*)=158 from pg_proc where pronamespace='public'::regnamespace and prosecdef));
end;$tests$;
select 'ok '||n||' - '||label from results order by n;
rollback;
