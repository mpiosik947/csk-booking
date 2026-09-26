\set ON_ERROR_STOP on
BEGIN;
CREATE TEMP TABLE recovery_results(n serial,name text,ok boolean) ON COMMIT DROP;
CREATE FUNCTION pg_temp.ok(text,boolean) RETURNS void LANGUAGE sql AS $$INSERT INTO recovery_results(name,ok) VALUES($1,coalesce($2,false));$$;
CREATE FUNCTION pg_temp.as_user(u uuid,s uuid,q text) RETURNS boolean LANGUAGE plpgsql AS $$DECLARE result boolean; BEGIN
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',u,'session_id',s,'role','authenticated')::text,true);
  SET LOCAL ROLE authenticated; EXECUTE q INTO result; RESET ROLE; RETURN result;
EXCEPTION WHEN OTHERS THEN RESET ROLE; RAISE; END;$$;
DO $$
DECLARE u uuid:=gen_random_uuid(); other_u uuid:=gen_random_uuid(); s uuid:=gen_random_uuid(); other_s uuid:=gen_random_uuid();
  tenant uuid:=gen_random_uuid(); h text:=repeat('a',64); r text; f text;
BEGIN
  INSERT INTO auth.users(id,email) VALUES(u,'recovery-grant-fixture@example.invalid'),(other_u,'recovery-grant-other@example.invalid');
  INSERT INTO auth.sessions(id,user_id) VALUES(s,u),(other_s,u);
  PERFORM pg_temp.ok('RLS enabled',(SELECT relrowsecurity FROM pg_class WHERE oid='public.recovery_grants'::regclass));
  PERFORM pg_temp.ok('zero policies',(SELECT count(*)=0 FROM pg_policy WHERE polrelid='public.recovery_grants'::regclass));
  PERFORM pg_temp.ok('minimal columns',(SELECT array_agg(column_name::text ORDER BY ordinal_position)=ARRAY['grant_hash','user_id','session_id','created_at','expires_at','consumed_at'] FROM information_schema.columns WHERE table_schema='public' AND table_name='recovery_grants'));
  FOREACH r IN ARRAY ARRAY['anon','authenticated','service_role'] LOOP
    PERFORM pg_temp.ok(r||' zero direct grants',NOT has_table_privilege(r,'public.recovery_grants','SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'));
  END LOOP;
  PERFORM pg_temp.ok('PUBLIC zero table ACL',NOT EXISTS(SELECT 1 FROM pg_class c CROSS JOIN LATERAL aclexplode(c.relacl) a WHERE c.oid='public.recovery_grants'::regclass AND a.grantee=0));
  FOREACH f IN ARRAY ARRAY['create_recovery_grant_v1(uuid,text)','check_recovery_grant_v1(text)','consume_recovery_grant_v1(text)'] LOOP
    PERFORM pg_temp.ok(f||' no PUBLIC execute',NOT EXISTS(SELECT 1 FROM pg_proc p CROSS JOIN LATERAL aclexplode(p.proacl) a WHERE p.oid=('public.'||f)::regprocedure AND a.grantee=0));
    PERFORM pg_temp.ok(f||' safe owner/mode/path',(SELECT prosecdef AND proowner='postgres'::regrole AND proconfig=ARRAY['search_path=""'] FROM pg_proc WHERE oid=('public.'||f)::regprocedure));
    PERFORM pg_temp.ok(f||' anon denied',NOT has_function_privilege('anon','public.'||f,'EXECUTE'));
  END LOOP;
  PERFORM pg_temp.ok('authenticated cannot mint',NOT has_function_privilege('authenticated','public.create_recovery_grant_v1(uuid,text)','EXECUTE'));
  PERFORM pg_temp.ok('service can mint',has_function_privilege('service_role','public.create_recovery_grant_v1(uuid,text)','EXECUTE'));
  PERFORM pg_temp.ok('service cannot consume',NOT has_function_privilege('service_role','public.consume_recovery_grant_v1(text)','EXECUTE'));
  FOREACH r IN ARRAY ARRAY['ordinary','tenant admin','Platform Admin'] LOOP
    IF r='tenant admin' THEN
      INSERT INTO public.tenants(id,name,slug,status) VALUES(tenant,'Grant ACL','grant-acl-fixture','dormant');
      INSERT INTO public.tenant_memberships(tenant_id,user_id,role,status) VALUES(tenant,u,'admin','active');
    ELSIF r='Platform Admin' THEN INSERT INTO public.platform_admins(user_id,status) VALUES(u,'active'); END IF;
    BEGIN
      PERFORM pg_temp.as_user(u,s,format('SELECT public.create_recovery_grant_v1(%L,%L)',s,h));
      PERFORM pg_temp.ok(r||' actual mint denied',false);
    EXCEPTION WHEN insufficient_privilege THEN PERFORM pg_temp.ok(r||' actual mint denied',true); END;
  END LOOP;
  SET LOCAL ROLE service_role;
  PERFORM public.create_recovery_grant_v1(s,h);
  RESET ROLE;
  PERFORM pg_temp.ok('user derived from auth.sessions',(SELECT user_id=u AND session_id=s FROM public.recovery_grants WHERE grant_hash=h));
  PERFORM pg_temp.ok('DB TTL 600s',(SELECT expires_at-created_at=interval '10 minutes' FROM public.recovery_grants WHERE grant_hash=h));
  PERFORM pg_temp.ok('valid check',pg_temp.as_user(u,s,format('SELECT public.check_recovery_grant_v1(%L)',h)));
  PERFORM pg_temp.ok('check not consumed',(SELECT consumed_at IS NULL FROM public.recovery_grants WHERE grant_hash=h));
  PERFORM pg_temp.ok('cross user denied',NOT pg_temp.as_user(other_u,s,format('SELECT public.consume_recovery_grant_v1(%L)',h)));
  PERFORM pg_temp.ok('different logical session denied',NOT pg_temp.as_user(u,other_s,format('SELECT public.consume_recovery_grant_v1(%L)',h)));
  PERFORM pg_temp.ok('missing session denied',NOT pg_temp.as_user(u,NULL,format('SELECT public.consume_recovery_grant_v1(%L)',h)));
  PERFORM pg_temp.ok('wrong hash denied',NOT pg_temp.as_user(u,s,format('SELECT public.consume_recovery_grant_v1(%L)',repeat('b',64))));
  PERFORM pg_temp.ok('first consume succeeds',pg_temp.as_user(u,s,format('SELECT public.consume_recovery_grant_v1(%L)',h)));
  PERFORM pg_temp.ok('replay denied with valid session',NOT pg_temp.as_user(u,s,format('SELECT public.consume_recovery_grant_v1(%L)',h)));
  PERFORM pg_temp.ok('consumed check denied',NOT pg_temp.as_user(u,s,format('SELECT public.check_recovery_grant_v1(%L)',h)));
  BEGIN PERFORM public.create_recovery_grant_v1(gen_random_uuid(),repeat('c',64)); PERFORM pg_temp.ok('missing session mint rejected',false);
  EXCEPTION WHEN invalid_authorization_specification THEN PERFORM pg_temp.ok('missing session mint rejected',true); END;
  UPDATE auth.sessions SET not_after=now()-interval '1 second' WHERE id=s;
  BEGIN PERFORM public.create_recovery_grant_v1(s,repeat('c',64)); PERFORM pg_temp.ok('expired session mint rejected',false);
  EXCEPTION WHEN invalid_authorization_specification THEN PERFORM pg_temp.ok('expired session mint rejected',true); END;
  UPDATE auth.sessions SET not_after=NULL WHERE id=s;
  PERFORM public.create_recovery_grant_v1(s,repeat('c',64));
  UPDATE public.recovery_grants SET created_at=now()-interval '11 minutes',expires_at=now()-interval '1 minute' WHERE grant_hash=repeat('c',64);
  PERFORM pg_temp.ok('expired grant denied',NOT pg_temp.as_user(u,s,format('SELECT public.consume_recovery_grant_v1(%L)',repeat('c',64))));
  UPDATE auth.users SET banned_until=now()+interval '1 day' WHERE id=u;
  BEGIN PERFORM public.create_recovery_grant_v1(s,repeat('d',64)); PERFORM pg_temp.ok('blocked user mint denied',false);
  EXCEPTION WHEN invalid_authorization_specification THEN PERFORM pg_temp.ok('blocked user mint denied',true); END;
  UPDATE auth.users SET banned_until=NULL,is_anonymous=true WHERE id=u;
  BEGIN PERFORM public.create_recovery_grant_v1(s,repeat('d',64)); PERFORM pg_temp.ok('anonymous user mint denied',false);
  EXCEPTION WHEN invalid_authorization_specification THEN PERFORM pg_temp.ok('anonymous user mint denied',true); END;
  UPDATE auth.users SET is_anonymous=false,deleted_at=now() WHERE id=u;
  BEGIN PERFORM public.create_recovery_grant_v1(s,repeat('d',64)); PERFORM pg_temp.ok('deleted user mint denied',false);
  EXCEPTION WHEN invalid_authorization_specification THEN PERFORM pg_temp.ok('deleted user mint denied',true); END;
END;$$;
SELECT '1..'||count(*) FROM recovery_results;
SELECT (CASE WHEN ok THEN 'ok ' ELSE 'not ok ' END)||n||' - '||name FROM recovery_results ORDER BY n;
DO $$BEGIN IF EXISTS(SELECT 1 FROM recovery_results WHERE NOT ok) THEN RAISE EXCEPTION 'Recovery grant assertions failed'; END IF; END;$$;
ROLLBACK;
SELECT 'FIXTURE_CLEANUP='||count(*) FROM auth.users WHERE email IN ('recovery-grant-fixture@example.invalid','recovery-grant-other@example.invalid');
