\set ON_ERROR_STOP on
begin;
create temporary table r3_results(n serial, label text) on commit drop;
create function pg_temp.r3_ok(label text, passed boolean) returns void language plpgsql as $$begin
 if passed is distinct from true then raise exception 'FAIL: %',label; end if;
 insert into r3_results(label) values(label);
end;$$;
create function pg_temp.r3_read(actor uuid) returns jsonb language plpgsql as $$
declare result jsonb;
begin
 perform set_config('request.jwt.claim.sub',coalesce(actor::text,''),true);
 perform set_config('request.jwt.claims',jsonb_build_object('sub',actor,'role','authenticated')::text,true);
 set local role authenticated;
 select coalesce(jsonb_agg(to_jsonb(r)),'[]'::jsonb) into result from public.get_my_dormant_admin_tenants_v1() r;
 reset role; return result;
exception when others then reset role; return jsonb_build_object('error',sqlstate); end;$$;
do $$
declare a uuid:=gen_random_uuid(); b uuid:=gen_random_uuid(); pa uuid:=gen_random_uuid(); deleted uuid:=gen_random_uuid();
 ids uuid[]; result jsonb; again jsonb; i integer; forbidden boolean;
begin
 insert into auth.users(id,email,email_confirmed_at,is_anonymous) values
 (a,'r3-a@example.invalid',now(),false),(b,'r3-b@example.invalid',now(),false),
 (pa,'r3-pa@example.invalid',now(),false),(deleted,'r3-deleted@example.invalid',now(),false);
 insert into public.profiles(user_id,email,role,phone,first_name,last_name) values
 (a,'r3-a@example.invalid','user','+48 555 000 001','Synthetic','Customer'),
 (b,'r3-b@example.invalid','user','+48 555 000 002','Synthetic','Customer')
 on conflict(user_id) do update set phone=excluded.phone,first_name=excluded.first_name,last_name=excluded.last_name;
 insert into public.platform_admins(user_id,status) values(pa,'active');
 select array_agg(gen_random_uuid()) into ids from generate_series(1,12);
 for i in 1..12 loop
  insert into public.tenants(id,name,slug,status) values(ids[i],'R3 fixture '||i,'r3-'||replace(ids[i]::text,'-',''),
   case i when 2 then 'active' when 6 then 'suspended' when 7 then 'disabled' else 'dormant' end);
  insert into public.tenant_public_profiles(tenant_id,display_name,city,public_slug,public_email,public_phone,public_address)
  values(ids[i],case when i in (1,10) then 'Same name' else 'R3 fixture '||i end,'Synthetic city',
   'pub-r3-'||replace(ids[i]::text,'-',''),'secret@example.invalid','+48 555 000 003','Secret customer address');
 end loop;
 insert into public.tenant_memberships(tenant_id,user_id,role,status) values
 (ids[1],a,'admin','active'),(ids[2],a,'user','active'),(ids[3],a,'employee','active'),
 (ids[4],a,'admin','suspended'),(ids[5],b,'admin','active'),(ids[6],a,'admin','active'),
 (ids[7],a,'admin','active'),(ids[8],a,'instructor','active'),(ids[9],a,'admin','pending'),
 (ids[12],a,'user','active');
 result:=pg_temp.r3_read(a);
 perform pg_temp.r3_ok('own dormant admin only; matrix excludes foreign active suspended disabled and other roles',
  jsonb_array_length(result)=1 and result->0->>'tenant_id'=ids[1]::text);
 update public.tenant_memberships set role='admin' where tenant_id=ids[2] and user_id=a;
 perform pg_temp.r3_ok('active tenant excluded even with admin membership',jsonb_array_length(pg_temp.r3_read(a))=1);
 perform pg_temp.r3_ok('foreign account sees only its own tenant',pg_temp.r3_read(b)->0->>'tenant_id'=ids[5]::text);
 perform pg_temp.r3_ok('PA without membership sees empty',pg_temp.r3_read(pa)='[]'::jsonb);
 insert into public.tenant_memberships(tenant_id,user_id,role,status) values(ids[11],pa,'admin','active');
 perform pg_temp.r3_ok('PA explicit admin membership sees only own',pg_temp.r3_read(pa)->0->>'tenant_id'=ids[11]::text);
 insert into public.tenant_memberships(tenant_id,user_id,role,status) values(ids[10],a,'admin','active');
 result:=pg_temp.r3_read(a); again:=pg_temp.r3_read(a);
 perform pg_temp.r3_ok('multiple own dormant tenants supported',jsonb_array_length(result)=2);
 perform pg_temp.r3_ok('deterministic stable ordering including name ties',result=again and
  (result->0->>'tenant_id')::uuid=least(ids[1],ids[10]));
 perform pg_temp.r3_ok('no duplicate rows',(select count(distinct x->>'tenant_id')=2 from jsonb_array_elements(result)x));
 perform pg_temp.r3_ok('DTO exact allowlist prevents any rich customer data',not exists(
  select 1 from jsonb_array_elements(result)x where
  (select array_agg(k order by k) from jsonb_object_keys(x)k)<>array['city','display_name','tenant_id','tenant_slug','tenant_status']));
 perform pg_temp.r3_ok('canonical technical slug and dormant status',result->0->>'tenant_status'='dormant' and
  result->0->>'tenant_slug'='r3-'||replace(result->0->>'tenant_id','-',''));
 perform pg_temp.r3_ok('email phone address absent',result::text not like '%secret@example.invalid%' and
  result::text not like '%555%' and result::text not like '%Secret customer address%');
 perform pg_temp.r3_ok('unauthenticated subject denied',pg_temp.r3_read(null)->>'error'='42501');
 perform pg_temp.r3_ok('missing Auth account safely empty',pg_temp.r3_read(gen_random_uuid())='[]'::jsonb);
 insert into public.tenant_memberships(tenant_id,user_id,role,status) values(ids[1],deleted,'admin','active');
 delete from auth.users where id=deleted;
 perform pg_temp.r3_ok('deleted Auth account safely empty after cascade',pg_temp.r3_read(deleted)='[]'::jsonb);
 perform pg_temp.r3_ok('anon and service role have no execute',
  not has_function_privilege('anon','public.get_my_dormant_admin_tenants_v1()','EXECUTE') and
  not has_function_privilege('service_role','public.get_my_dormant_admin_tenants_v1()','EXECUTE'));
 perform pg_temp.r3_ok('owner definer search path exact',exists(select 1 from pg_proc where oid='public.get_my_dormant_admin_tenants_v1()'::regprocedure
  and proowner='postgres'::regrole and prosecdef and provolatile='s' and proconfig=array['search_path=pg_catalog, public, auth, pg_temp']));
 -- Isolate overflow fixtures to the same current user. No truncation at 101.
 for i in 1..98 loop
  insert into public.tenants(name,slug) values('Overflow','r3-overflow-'||replace(gen_random_uuid()::text,'-','')) returning id into deleted;
  insert into public.tenant_memberships(tenant_id,user_id,role,status) values(deleted,a,'admin','active');
 end loop;
 perform pg_temp.r3_ok('exact hard maximum 100 is supported',jsonb_array_length(pg_temp.r3_read(a))=100);
 insert into public.tenants(name,slug) values('Overflow','r3-overflow-'||replace(gen_random_uuid()::text,'-','')) returning id into deleted;
 insert into public.tenant_memberships(tenant_id,user_id,role,status) values(deleted,a,'admin','active');
 perform pg_temp.r3_ok('overflow fails explicitly instead of truncating',pg_temp.r3_read(a)->>'error'='54000');
end;$$;
select '1..'||count(*) from r3_results;
select 'ok '||n||' - '||label from r3_results order by n;
rollback;
