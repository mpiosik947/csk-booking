\set ON_ERROR_STOP on
begin;
create temporary table results(n serial,label text) on commit drop;
create function pg_temp.ok(label text, passed boolean) returns void language plpgsql as $$begin
 if passed is distinct from true then raise exception 'FAIL: %',label; end if; insert into results(label) values(label);
end;$$;
create function pg_temp.rpc(actor uuid,q text,caller text default 'authenticated') returns jsonb language plpgsql as $$
declare r jsonb;begin
 perform set_config('request.jwt.claim.sub',coalesce(actor::text,''),true);
 perform set_config('request.jwt.claims',jsonb_build_object('sub',actor,'role',caller)::text,true);
 execute format('set local role %I',caller);execute q into r;reset role;
 perform set_config('request.jwt.claim.sub','',true);perform set_config('request.jwt.claims','{}',true);
 return jsonb_build_object('state','00000','value',r);
exception when others then reset role;perform set_config('request.jwt.claim.sub','',true);perform set_config('request.jwt.claims','{}',true);
 return jsonb_build_object('state',sqlstate,'error',sqlerrm);end;$$;
do $$
declare a uuid:=gen_random_uuid();b uuid:=gen_random_uuid();admin_a uuid:=gen_random_uuid();admin_b uuid:=gen_random_uuid(); employee uuid:=gen_random_uuid();instructor uuid:=gen_random_uuid();customer uuid:=gen_random_uuid();suspended uuid:=gen_random_uuid();pending uuid:=gen_random_uuid();removed uuid:=gen_random_uuid();pa uuid:=gen_random_uuid();media_a uuid:=gen_random_uuid();media_b uuid:=gen_random_uuid();id_a uuid:=gen_random_uuid();id_b uuid:=gen_random_uuid();revision uuid;actor uuid;role_name text;r jsonb;values jsonb;before_b jsonb;token uuid;old_audit jsonb; shared uuid:=gen_random_uuid();
begin
 insert into public.tenants(id,name,slug,status) values(a,'Partner A','partner-a-'||a,'active'),(b,'Partner B','partner-b-'||b,'active');
 insert into public.tenant_public_profiles(tenant_id,public_slug,display_name,city,is_public) values(a,'public-a-'||a,'Partner A','Test',true),(b,'public-b-'||b,'Partner B','Test',true);
 insert into auth.users(id,email,email_confirmed_at,is_anonymous) select x,x||'@example.invalid',now(),false from unnest(array[admin_a,admin_b,employee,instructor,customer,suspended,pending,removed,pa])x;
 insert into public.tenant_memberships(tenant_id,user_id,role,status) values
 (a,admin_a,'admin','active'),(b,admin_b,'admin','active'),(a,employee,'employee','active'),(a,instructor,'instructor','active'),
 (a,customer,'user','active'),(a,suspended,'admin','suspended'),(a,pending,'admin','pending');
 insert into public.platform_admins(user_id,status) values(pa,'active');
 insert into public.tenant_public_access_controls(tenant_id,public_access_state) values(a,'coming_soon');
 insert into app_private.tenant_partner_media(id,tenant_id,actor_user_id,width,height,byte_size,sha256) values(media_a,a,admin_a,100,100,100,repeat('a',64)),(media_b,b,admin_b,100,100,100,repeat('b',64));
 values:=jsonb_build_object('name','Partner A','kind','partner','display_format','logo','target_url','https://example.invalid/path?q=1#x','short_description',null,'is_active',true,'display_order',0,'starts_at',null,'ends_at',null);
 r:=pg_temp.rpc(admin_a,format('select public.admin_save_tenant_partner_v1(%L,%L,null,%L,%L)', 'partner-a-'||a,id_a,values,media_a));
 perform pg_temp.ok('own admin creates',r->>'state'='00000');
 revision:=(r->'value'->'items'->0->>'revision')::uuid;
 r:=pg_temp.rpc(admin_b,format('select public.admin_save_tenant_partner_v1(%L,%L,null,%L,%L)', 'partner-b-'||b,id_b,values||'{"name":"Partner B"}',media_b));
 perform pg_temp.ok('B admin creates',r->>'state'='00000');
 select to_jsonb(p) into before_b from public.tenant_partners p where id=id_b;

 r:=pg_temp.rpc(admin_a,format('select public.admin_prepare_partner_delete_v1(%L,%L,%L)','partner-a-'||a,id_a,revision));
 perform pg_temp.ok('active denied',r->>'state'='22023');
 update public.tenant_partners set is_active=false where id=id_a;
 r:=pg_temp.rpc(admin_a,format('select public.admin_prepare_partner_delete_v1(%L,%L,%L)','partner-a-'||a,id_a,revision));
 perform pg_temp.ok('inactive nonarchived denied',r->>'state'='22023');
 r:=pg_temp.rpc(admin_a,format('select public.admin_save_tenant_partner_v1(%L,%L,%L,%L,%L,true)','partner-a-'||a,id_a,revision,values,media_a));
 revision:=(r->'value'->'items'->0->>'revision')::uuid;
 foreach actor in array array[employee,instructor,customer,suspended,pending,removed,pa,admin_b] loop
  r:=pg_temp.rpc(actor,format('select public.admin_prepare_partner_delete_v1(%L,%L,%L)','partner-a-'||a,id_a,revision));
  perform pg_temp.ok('role denied '||actor,r->>'state'='42501');
 end loop;
 foreach role_name in array array['anon','service_role'] loop
  r:=pg_temp.rpc(admin_a,format('select public.admin_prepare_partner_delete_v1(%L,%L,%L)','partner-a-'||a,id_a,revision),role_name);
  perform pg_temp.ok('non-user caller denied '||role_name,r->>'state'='42501');
 end loop;
 r:=pg_temp.rpc(admin_a,format('select public.admin_prepare_partner_delete_v1(%L,%L,%L)','partner-b-'||b,id_a,revision));
 perform pg_temp.ok('forged tenant denied',r->>'state'='42501');
 r:=pg_temp.rpc(admin_a,format('select public.admin_prepare_partner_delete_v1(%L,%L,%L)','partner-a-'||a,id_b,revision));
 perform pg_temp.ok('foreign partner denied',r->>'state'='42501');
 r:=pg_temp.rpc(admin_a,format('delete from public.tenant_partners where id=%L returning to_jsonb(tenant_partners)',id_a));
 perform pg_temp.ok('direct table delete denied',r->>'state'='42501');
 insert into public.tenant_partners(id,tenant_id,name,kind,display_format,media_id) values(shared,a,'Shared','partner','logo',media_a);
 r:=pg_temp.rpc(admin_a,format('select public.admin_prepare_partner_delete_v1(%L,%L,%L)','partner-a-'||a,id_a,revision));
 perform pg_temp.ok('shared media refused',r->>'error'='MEDIA_SHARED');
 delete from public.tenant_partners where id=shared;
 r:=pg_temp.rpc(admin_a,format('select public.admin_prepare_partner_delete_v1(%L,%L,%L)','partner-a-'||a,id_a,gen_random_uuid()));
 perform pg_temp.ok('stale revision denied',r->>'state'='PT409');
 select jsonb_agg(to_jsonb(c) order by id) into old_audit from app_private.tenant_partner_changes c where partner_id=id_a;
 insert into storage.objects(bucket_id,name) values('tenant-partners',a::text||'/partners/'||media_a::text||'.webp');
 r:=pg_temp.rpc(admin_a,format('select public.admin_prepare_partner_delete_v1(%L,%L,%L)','partner-a-'||a,id_a,revision));
 perform pg_temp.ok('archived own admin prepares',r->>'state'='00000');token:=(r->'value'->>'token')::uuid;
 r:=pg_temp.rpc(admin_a,format('select public.admin_prepare_partner_delete_v1(%L,%L,%L)','partner-a-'||a,id_a,revision));
 perform pg_temp.ok('second claim denied',r->>'state'='PT409');
 r:=pg_temp.rpc(admin_a,format('select public.admin_save_tenant_partner_v1(%L,%L,null,%L,%L)','partner-a-'||a,gen_random_uuid(),values,media_a));
 perform pg_temp.ok('pinned media cannot be reattached',r->>'state'='PT409');
 r:=pg_temp.rpc(admin_a,format('select public.admin_save_tenant_partner_v1(%L,%L,%L,%L,%L)','partner-a-'||a,id_a,revision,values,media_a));
 perform pg_temp.ok('edit archived during delete denied',r->>'state'='PT409');
 r:=pg_temp.rpc(admin_a,format('select to_jsonb(public.admin_finish_partner_delete_v1(%L,%L,%L,%L))','partner-a-'||a,id_a,revision,token));
 perform pg_temp.ok('finish refuses existing Storage object',r->>'error'='STORAGE_CLEANUP_REQUIRED');
 perform pg_temp.ok('failure retains record and media',exists(select 1 from public.tenant_partners where id=id_a) and exists(select 1 from app_private.tenant_partner_media where id=media_a));
 r:=pg_temp.rpc(admin_a,format('select to_jsonb(public.admin_release_partner_delete_v1(%L,%L,%L,%L))','partner-a-'||a,id_a,revision,token));
 perform pg_temp.ok('release retry lease',r->>'state'='00000');
 perform pg_temp.ok('release keeps attachment pin',(select cleanup_partner_id=id_a and cleanup_token is null from app_private.tenant_partner_media where id=media_a));
 r:=pg_temp.rpc(admin_a,format('select public.admin_prepare_partner_delete_v1(%L,%L,%L)','partner-a-'||a,id_a,revision));
 perform pg_temp.ok('retry prepares',r->>'state'='00000');
 r:=pg_temp.rpc(admin_a,format('select to_jsonb(public.admin_finish_partner_delete_v1(%L,%L,%L,%L))','partner-a-'||a,id_a,revision,token));
 perform pg_temp.ok('old claim cannot finalize',r->>'state'='PT409');
 -- Simulate expired crashed worker; only local transactional fixtures.
 update app_private.tenant_partner_media set cleanup_until=clock_timestamp()-interval '1 second' where id=media_a;
 r:=pg_temp.rpc(admin_a,format('select public.admin_prepare_partner_delete_v1(%L,%L,%L)','partner-a-'||a,id_a,revision));token:=(r->'value'->>'token')::uuid;
 perform pg_temp.ok('crashed request recoverable',r->>'state'='00000');
 -- Local transactional metadata fixture only; real E2E uses the Storage API.
 perform set_config('storage.allow_delete_query','true',true);
 delete from storage.objects where bucket_id='tenant-partners' and name=a::text||'/partners/'||media_a::text||'.webp';
 r:=pg_temp.rpc(admin_a,format('select to_jsonb(public.admin_finish_partner_delete_v1(%L,%L,%L,%L))','partner-a-'||a,id_a,revision,token));
 perform pg_temp.ok('finish succeeds',r->'value'='true');
 perform pg_temp.ok('zero partner/media/storage',not exists(select 1 from public.tenant_partners where id=id_a) and not exists(select 1 from app_private.tenant_partner_media where id=media_a) and not exists(select 1 from storage.objects where name=a::text||'/partners/'||media_a::text||'.webp'));
 perform pg_temp.ok('historical audit byte-identical',(select jsonb_agg(to_jsonb(c) order by id) from app_private.tenant_partner_changes c where partner_id=id_a and not actions @> array['permanent_delete'])=old_audit);
 perform pg_temp.ok('delete audit snapshot',(select count(*)=1 and bool_and(tenant_id=a and actor_user_id=admin_a and partner_name='Partner A' and created_at is not null) from app_private.tenant_partner_changes where partner_id=id_a and actions @> array['permanent_delete']));
 r:=pg_temp.rpc(admin_a,format('select to_jsonb(public.admin_finish_partner_delete_v1(%L,%L,%L,%L))','partner-a-'||a,id_a,revision,token));
 perform pg_temp.ok('double finish denied',r->>'state'<>'00000');
 begin delete from app_private.tenant_partner_changes where partner_id=id_a; raise exception 'audit erase allowed'; exception when insufficient_privilege then null; end;
 perform pg_temp.ok('audit append-only remains',(select count(*)=3 from app_private.tenant_partner_changes where partner_id=id_a));
 perform pg_temp.ok('B unchanged',(select to_jsonb(p)=before_b from public.tenant_partners p where id=id_b));
 perform pg_temp.ok('coming soon unchanged',(select public_access_state='coming_soon' from public.tenant_public_access_controls where tenant_id=a));
end; $$;
select '1..'||count(*) from results;
select 'ok '||n||' - '||label from results order by n;
rollback;
