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
declare a uuid:=gen_random_uuid();b uuid:=gen_random_uuid();admin_a uuid:=gen_random_uuid();admin_b uuid:=gen_random_uuid();
 employee uuid:=gen_random_uuid();instructor uuid:=gen_random_uuid();customer uuid:=gen_random_uuid();suspended uuid:=gen_random_uuid();pending uuid:=gen_random_uuid();removed uuid:=gen_random_uuid();pa uuid:=gen_random_uuid();
 media_a uuid:=gen_random_uuid();media_b uuid:=gen_random_uuid();id_a uuid:=gen_random_uuid();id_b uuid:=gen_random_uuid();revision uuid;
 actor uuid; role_name text;r jsonb;values jsonb;bad text;before_b jsonb;count_a int;
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
 foreach actor in array array[employee,instructor,customer,suspended,pending,removed,pa,admin_b] loop
  r:=pg_temp.rpc(actor,format('select public.admin_get_tenant_partners_v1(%L)','partner-a-'||a));
  perform pg_temp.ok('non-own-admin list denied '||actor,r->>'state'='42501');
  r:=pg_temp.rpc(actor,format('select public.admin_save_tenant_partner_v1(%L,%L,null,%L,%L)','partner-a-'||a,gen_random_uuid(),values,media_a));
  perform pg_temp.ok('non-own-admin create denied '||actor,r->>'state'='42501');
  r:=pg_temp.rpc(actor,format('select public.admin_save_tenant_partner_v1(%L,%L,%L,%L,%L,true)','partner-a-'||a,id_a,revision,values,media_a));
  perform pg_temp.ok('non-own-admin archive denied '||actor,r->>'state'='42501');
 end loop;
 foreach role_name in array array['anon','authenticated','service_role'] loop
  r:=pg_temp.rpc(admin_a,'select to_jsonb(p) from public.tenant_partners p',role_name);
  perform pg_temp.ok('direct table read denied '||role_name,r->>'state'='42501');
  r:=pg_temp.rpc(admin_a,format('delete from public.tenant_partners where id=%L returning to_jsonb(tenant_partners)',id_a),role_name);
  perform pg_temp.ok('direct delete denied '||role_name,r->>'state'='42501');
 end loop;
 r:=pg_temp.rpc(null,format('select public.admin_save_tenant_partner_v1(%L,%L,null,%L,%L)','partner-a-'||a,gen_random_uuid(),values,media_a),'anon');
 perform pg_temp.ok('anonymous writer denied',r->>'state'='42501');
 r:=pg_temp.rpc(admin_a,format('select public.admin_save_tenant_partner_v1(%L,%L,%L,%L,%L)','partner-a-'||a,id_a,revision,values,media_a),'service_role');
 perform pg_temp.ok('service cannot substitute for admin writer',r->>'state'='42501');
 foreach actor in array array[null::uuid,customer,suspended,pending,removed,admin_b] loop
  r:=pg_temp.rpc(actor,format('select public.get_public_tenant_partners_v1(%L)','public-a-'||a),case when actor is null then 'anon' else 'authenticated' end);
  perform pg_temp.ok('coming soon payload denied '||coalesce(actor::text,'anon'),r->>'state'='PT423');
  r:=pg_temp.rpc(actor,format('select to_jsonb(public.get_tenant_partner_media_v1(%L))',media_a),case when actor is null then 'anon' else 'authenticated' end);
  perform pg_temp.ok('coming soon image denied '||coalesce(actor::text,'anon'),r->'value'='null');
 end loop;
 foreach actor in array array[admin_a,employee,instructor,pa] loop
  r:=pg_temp.rpc(actor,format('select public.get_public_tenant_partners_v1(%L)','public-a-'||a));
  perform pg_temp.ok('authorized preview '||actor,r->>'state'='00000' and jsonb_array_length(r->'value')=1);
  r:=pg_temp.rpc(actor,format('select to_jsonb(public.get_tenant_partner_media_v1(%L))',media_a));
  perform pg_temp.ok('authorized media '||actor,r->>'value'=a::text||'/partners/'||media_a::text||'.webp');
 end loop;
 r:=pg_temp.rpc(admin_a,format('select public.admin_save_tenant_partner_v1(%L,%L,%L,%L,%L)','partner-a-'||a,id_b,(before_b->>'revision')::uuid,values,media_a));
 perform pg_temp.ok('forged foreign record denied',r->>'state'='42501');
 r:=pg_temp.rpc(admin_a,format('select public.admin_save_tenant_partner_v1(%L,%L,%L,%L,%L)','partner-a-'||a,id_a,revision,values,media_b));
 perform pg_temp.ok('foreign media denied',r->>'state'='42501');
 r:=pg_temp.rpc(admin_a,format('select public.admin_save_tenant_partner_v1(%L,%L,%L,%L,%L)','partner-a-'||a,id_a,revision,values||jsonb_build_object('tenant_id',b),media_a));
 perform pg_temp.ok('forged tenant field denied',r->>'state'='22023');
 foreach bad in array array['javascript:alert(1)','data:image/svg+xml,x','http://example.invalid','//example.invalid','https://user:password@example.invalid','https://example.invalid\evil','https://example.invalid/%0aX'] loop
  r:=pg_temp.rpc(admin_a,format('select public.admin_save_tenant_partner_v1(%L,%L,%L,%L,%L)','partner-a-'||a,id_a,revision,values||jsonb_build_object('target_url',bad),media_a));
  perform pg_temp.ok('unsafe URL rejected '||bad,r->>'state'='23514');
 end loop;
 r:=pg_temp.rpc(admin_a,format('select public.admin_save_tenant_partner_v1(%L,%L,%L,%L,%L)','partner-a-'||a,id_a,gen_random_uuid(),values,media_a));
 perform pg_temp.ok('stale revision conflicts',r->>'state'='PT409');
 r:=pg_temp.rpc(admin_a,format('select public.admin_save_tenant_partner_v1(%L,%L,%L,%L,%L)','partner-a-'||a,id_a,revision,values||'{"display_order":8,"is_active":false}',media_a));
 perform pg_temp.ok('edit reorder deactivate',r->>'state'='00000' and r->'value'->'items'->0->>'status'='inactive');
 revision:=(r->'value'->'items'->0->>'revision')::uuid;
 r:=pg_temp.rpc(admin_a,format('select public.admin_save_tenant_partner_v1(%L,%L,%L,%L,%L,true)','partner-a-'||a,id_a,revision,values,media_a));
 perform pg_temp.ok('archive preserves record',r->>'state'='00000' and r->'value'->'items'->0->>'status'='archived');
 perform pg_temp.ok('audit actual actor and actions',(select count(*)=3 and bool_and(actor_user_id=admin_a) from app_private.tenant_partner_changes where tenant_id=a));
 perform pg_temp.ok('audit reorder',(select count(*)=1 from app_private.tenant_partner_changes where tenant_id=a and actions @> array['reorder','deactivate']));
 perform pg_temp.ok('B untouched',(select to_jsonb(p)=before_b from public.tenant_partners p where id=id_b));
 insert into public.tenant_partners(id,tenant_id,name,kind,display_format,media_id,is_active,starts_at,ends_at,display_order) values
 (gen_random_uuid(),b,'Inactive','partner','logo',media_b,false,null,null,0),
 (gen_random_uuid(),b,'Future','partner','logo',media_b,true,now()+interval '1 day',null,0),
 (gen_random_uuid(),b,'Expired','partner','logo',media_b,true,null,now(),0),
 (gen_random_uuid(),b,'First','sponsor','banner',media_b,true,now()-interval '1 day',now()+interval '1 day',0);
 r:=pg_temp.rpc(null,format('select public.get_public_tenant_partners_v1(%L)','public-b-'||b),'anon');
 perform pg_temp.ok('live filters inactive future expired',r->>'state'='00000' and jsonb_array_length(r->'value')=2);
 perform pg_temp.ok('stable fallback ordering',r->'value'->0->>'name'='Partner B' and r->'value'->1->>'name'='First');
 perform pg_temp.ok('public DTO exact',(select array_agg(k order by k) from jsonb_object_keys(r->'value'->0)k)=array['display_format','display_order','id','kind','media_id','name','short_description','target_url']);
 r:=pg_temp.rpc(admin_a,format('select to_jsonb(public.register_tenant_partner_media_v1(%L,%L,%L,100,100,100,%L))',a,admin_a,gen_random_uuid(),repeat('f',64)));
 perform pg_temp.ok('client cannot attest unvalidated image',r->>'state'='42501');
 r:=pg_temp.rpc(null,format('select to_jsonb(public.discard_tenant_partner_media_v1(%L,%L))',a,media_a),'service_role');
 perform pg_temp.ok('referenced media cannot be removed',r->'value'='false');
 r:=pg_temp.rpc(pa,format('select public.platform_get_tenant_delete_eligibility_v1(%L)',a));
 perform pg_temp.ok('partner dependency explicit and hard delete prohibited',r->'value'->'blockers' @> '[{"code":"TENANT_PARTNERS_EXIST"},{"code":"PARTNER_AUDIT_EXISTS"},{"code":"PARTNER_MEDIA_EXISTS"}]' and r->'value'->'eligibility'->>'can_hard_delete'='false');
 perform pg_temp.ok('private bucket',(select not public and file_size_limit=1048576 and allowed_mime_types=array['image/webp'] from storage.buckets where id='tenant-partners'));
 perform pg_temp.ok('mandatory storage deny policy',exists(select 1 from pg_policies where schemaname='storage' and policyname='tenant_partners_no_direct_storage' and permissive='RESTRICTIVE' and cmd='ALL'));
 select count(*) into count_a from public.tenant_partners where tenant_id=a;
 perform pg_temp.ok('failed writes leave no new A rows',count_a=1);
end;$$;
select '1..'||count(*) from results;
select 'ok '||n||' - '||label from results order by n;
rollback;
