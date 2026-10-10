\set ON_ERROR_STOP on
begin;
create temporary table results(n serial,label text) on commit drop;
create function pg_temp.ok(label text,passed boolean) returns void language plpgsql as $$begin
 if passed is distinct from true then raise exception 'FAIL: %',label;end if;
 insert into results(label)values(label);
end$$;
create function pg_temp.denied_as(client_role text,statement text) returns boolean language plpgsql as $$begin
 execute format('set local role %I',client_role);
 execute statement;reset role;return false;
exception when insufficient_privilege then reset role;return true;
 when others then reset role;raise;
end$$;
do $tests$
declare allocator oid:='app_private.tenant_concurrency_revision_seq'::regclass;client_role text;
begin
 perform pg_temp.ok('SEC-002B public sequence inventory remains empty',not exists(select 1 from pg_class where relnamespace='public'::regnamespace and relkind='S'));
 perform pg_temp.ok('exact private allocator inventory',(select count(*)=1 and bool_and(relname='tenant_concurrency_revision_seq' and relkind='S') from pg_class where relnamespace='app_private'::regnamespace));
 perform pg_temp.ok('private schema owner postgres',(select nspowner='postgres'::regrole from pg_namespace where nspname='app_private'));
 perform pg_temp.ok('allocator owner postgres',(select relowner='postgres'::regrole and relpersistence='p' from pg_class where oid=allocator));
 perform pg_temp.ok('PUBLIC has no schema privileges',not exists(select 1 from pg_namespace n,lateral aclexplode(coalesce(n.nspacl,acldefault('n',n.nspowner)))a where n.nspname='app_private' and a.grantee=0));
 perform pg_temp.ok('sequence ACL owner only',not exists(select 1 from pg_class c,lateral aclexplode(coalesce(c.relacl,acldefault('S',c.relowner)))a where c.oid=allocator and a.grantee<>'postgres'::regrole));
 perform pg_temp.ok('allocator properties safe',(select seqtypid='bigint'::regtype and seqincrement=1 and seqmin=1 and seqmax=9007199254740991 and seqcache=1 and not seqcycle from pg_sequence where seqrelid=allocator));
 foreach client_role in array array['anon','authenticated','service_role'] loop
  perform pg_temp.ok(client_role||' no schema USAGE/CREATE',not has_schema_privilege(client_role,'app_private','USAGE,CREATE'));
  perform pg_temp.ok(client_role||' no sequence USAGE/SELECT/UPDATE',not has_sequence_privilege(client_role,allocator,'USAGE,SELECT,UPDATE'));
  perform pg_temp.ok(client_role||' named nextval denied',pg_temp.denied_as(client_role,'select nextval(''app_private.tenant_concurrency_revision_seq'')'));
  perform pg_temp.ok(client_role||' OID nextval denied',pg_temp.denied_as(client_role,format('select nextval(%s::regclass)',allocator)));
  perform pg_temp.ok(client_role||' OID currval denied',pg_temp.denied_as(client_role,format('select currval(%s::regclass)',allocator)));
  perform pg_temp.ok(client_role||' OID setval denied',pg_temp.denied_as(client_role,format('select setval(%s::regclass,1)',allocator)));
  perform pg_temp.ok(client_role||' direct sequence SELECT denied',pg_temp.denied_as(client_role,'select last_value from app_private.tenant_concurrency_revision_seq'));
  perform pg_temp.ok(client_role||' private object creation denied',pg_temp.denied_as(client_role,'create sequence app_private.unexpected_client_sequence'));
 end loop;
 perform pg_temp.ok('trusted owner can allocate',has_schema_privilege('postgres','app_private','USAGE') and has_sequence_privilege('postgres',allocator,'USAGE,SELECT,UPDATE'));
 perform pg_temp.ok('only closed trusted trigger accesses allocator',(
  select count(*)=1 and bool_and(proname='guard_tenant_archive_state_v1' and prosecdef and proowner='postgres'::regrole
   and proconfig=array['search_path=pg_catalog, public, pg_temp']::text[]
   and not has_function_privilege('anon',oid,'EXECUTE') and not has_function_privilege('authenticated',oid,'EXECUTE') and not has_function_privilege('service_role',oid,'EXECUTE'))
  from pg_proc where pronamespace='public'::regnamespace and prokind='f' and pg_get_functiondef(oid) like '%app_private.tenant_concurrency_revision_seq%'));
 perform pg_temp.ok('no private callable function',(select count(*)=0 from pg_proc where pronamespace='app_private'::regnamespace));
end;$tests$;
select '1..'||count(*) from results;
select 'ok '||n||' - '||label from results order by n;
rollback;
