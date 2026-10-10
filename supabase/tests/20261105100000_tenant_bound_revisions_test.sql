\set ON_ERROR_STOP on
begin;
select set_config('app.product10d_test_enforce','on',true);
create temporary table results(n serial,label text) on commit drop;
create function pg_temp.ok(label text,passed boolean) returns void language plpgsql as $$begin
 if passed is distinct from true then raise exception 'FAIL: %',label;end if;
 insert into results(label)values(label);
end$$;
create function pg_temp.rpc(actor uuid,statement text) returns jsonb language plpgsql as $$declare r jsonb;begin
 perform set_config('request.jwt.claims',jsonb_build_object('sub',actor,'role',case when actor is null then 'anon' else 'authenticated' end)::text,true);
 perform set_config('request.jwt.claim.sub',coalesce(actor::text,''),true);
 if actor is null then set local role anon;else set local role authenticated;end if;
 execute statement into r;reset role;
 perform set_config('request.jwt.claims','{}',true);perform set_config('request.jwt.claim.sub','',true);
 return jsonb_build_object('state','00000','value',r);
exception when others then reset role;
 perform set_config('request.jwt.claims','{}',true);perform set_config('request.jwt.claim.sub','',true);
 return jsonb_build_object('state',sqlstate,'error',sqlerrm);
end$$;
create function pg_temp.life(actor uuid,t uuid,op text,revision bigint,req uuid default gen_random_uuid()) returns jsonb language sql as $$
 select pg_temp.rpc(actor,format('select public.%s(%L,%L,%L)',case op when 'archive' then 'platform_archive_tenant_v1' else 'platform_restore_archived_tenant_v1' end,t,revision,req));
$$;
create function pg_temp.plan(actor uuid,t uuid,revision text,target text default 'current_full_v1',req uuid default gen_random_uuid()) returns jsonb language sql as $$
 select pg_temp.rpc(actor,format('select public.platform_change_tenant_plan_v2(%L,%L,%L,%L)',t,target,revision,req));
$$;
do $tests$
declare pa uuid:=gen_random_uuid();u uuid:=gen_random_uuid();keeper uuid:=gen_random_uuid();a uuid:=gen_random_uuid();b uuid:=gen_random_uuid();
 ar bigint;br bigint;old_a bigint;old_b bigint;ap text;bp text;req uuid;r jsonb;q jsonb;before_audits bigint;operation text;member_role text;burned bigint;fresh bigint;
begin
 insert into auth.users(id,email,email_confirmed_at,is_anonymous)select id,id||'@synthetic.invalid',now(),false from unnest(array[pa,u,keeper])id;
 insert into public.platform_admins(user_id,status)values(pa,'active');
 -- Deliberately identical supplied legacy counters: INSERT guards must replace
 -- both values even for privileged fixture callers; no equal scalar survives.
 insert into public.tenants(id,name,slug,status,lifecycle_revision)values(a,'Revision A','sybr-'||a,'active',13),(b,'Revision B','sybr-'||b,'active',13);
 insert into public.tenant_public_profiles(tenant_id,public_slug,display_name,city,is_public,show_booking,show_events,show_instructor,show_pricing)
 select id,'sybr-public-'||id,'Synthetic','Synthetic',false,false,false,false,false from unnest(array[a,b])id;
 insert into public.tenant_memberships(tenant_id,user_id,role,status)select t,keeper,'admin','active' from unnest(array[a,b])t;
 insert into public.tenant_memberships(tenant_id,user_id,role,status)select t,u,'user','active' from unnest(array[a,b])t;
 select lifecycle_revision into ar from public.tenants where id=a;select lifecycle_revision into br from public.tenants where id=b;
 perform pg_temp.ok('equal supplied lifecycle counters become distinct',ar<>br);
 ap:=pg_temp.rpc(pa,format('select public.platform_get_tenant_plan_change_preview_v1(%L,''booking_only_v1'')',a))->'value'->>'revision';
 bp:=pg_temp.rpc(pa,format('select public.platform_get_tenant_plan_change_preview_v1(%L,''booking_only_v1'')',b))->'value'->>'revision';
 perform pg_temp.ok('missing plan assignment tokens are distinct and nonzero',ap<>bp and ap::bigint>0 and bp::bigint>0);
 before_audits:=(select count(*) from public.platform_audit_logs where tenant_id in(a,b));
 perform pg_temp.ok('missing plan A token on B rejected',pg_temp.plan(pa,b,ap,'booking_only_v1')->>'state'='PT409');
 perform pg_temp.ok('missing plan B token on A rejected',pg_temp.plan(pa,a,bp,'booking_only_v1')->>'state'='PT409');
 perform pg_temp.ok('missing plan rejections do not audit',(select count(*) from public.platform_audit_logs where tenant_id in(a,b))=before_audits);
 r:=pg_temp.plan(pa,a,ap,'booking_only_v1');q:=pg_temp.plan(pa,b,bp,'booking_only_v1');
 perform pg_temp.ok('missing plan correct A token allowed',r->>'state'='00000');
 perform pg_temp.ok('missing plan correct B token allowed',q->>'state'='00000');
 ap:=r->'value'->>'revision';bp:=q->'value'->>'revision';
 perform pg_temp.ok('assigned plan tokens distinct',ap<>bp);
 perform pg_temp.ok('assigned plan A token on B rejected',pg_temp.plan(pa,b,ap)->>'state'='PT409');
 perform pg_temp.ok('assigned plan B token on A rejected',pg_temp.plan(pa,a,bp)->>'state'='PT409');
 req:=gen_random_uuid();r:=pg_temp.plan(pa,a,ap,'current_full_v1',req);
 perform pg_temp.ok('fresh plan A allowed',r->>'state'='00000' and (r->'value'->>'revision')::bigint>ap::bigint);
 perform pg_temp.ok('plan request replay unchanged',pg_temp.plan(pa,a,ap,'current_full_v1',req)=r);
 perform pg_temp.ok('plan request replay one audit',(select count(*)=2 from public.platform_audit_logs where tenant_id=a and action in('plan_assigned','plan_changed')));
 perform pg_temp.ok('stale same-tenant plan rejected',pg_temp.plan(pa,a,ap)->>'state'='PT409');
 perform pg_temp.ok('fresh plan B allowed',pg_temp.plan(pa,b,bp)->>'state'='00000');
 perform pg_temp.ok('legacy plan wrapper remains compatible and target-scoped',pg_temp.rpc(pa,format('select to_jsonb(public.platform_set_tenant_plan_v1(%L,''current_full_v1''))',a))->>'state'='00000');
 old_a:=ar;old_b:=br;
 foreach operation in array array['archive','restore'] loop
  ar:=(pg_temp.rpc(pa,format('select public.platform_get_tenant_archive_preview_v1(%L)',a))->'value'->>'revision')::bigint;
  br:=(pg_temp.rpc(pa,format('select public.platform_get_tenant_archive_preview_v1(%L)',b))->'value'->>'revision')::bigint;
  before_audits:=(select count(*) from public.platform_audit_logs where tenant_id in(a,b));
  r:=pg_temp.life(pa,b,operation,ar);
  perform pg_temp.ok(operation||' A token on B rejected',r->>'state'='PT409' and r->>'error'='TENANT_REVISION_STALE');
  perform pg_temp.ok(operation||' B token on A rejected',pg_temp.life(pa,a,operation,br)->>'state'='PT409');
  perform pg_temp.ok(operation||' cross-tenant denial produces no audit',(select count(*) from public.platform_audit_logs where tenant_id in(a,b))=before_audits);
  req:=gen_random_uuid();r:=pg_temp.life(pa,a,operation,ar,req);
  perform pg_temp.ok(operation||' correct A token allowed',r->>'state'='00000' and (r->'value'->>'revision')::bigint>ar);
  perform pg_temp.ok(operation||' same request returns original result',pg_temp.life(pa,a,operation,ar,req)=r);
  perform pg_temp.ok(operation||' replay audits once',(select count(*) from public.platform_audit_logs where tenant_id in(a,b))=before_audits+1);
  perform pg_temp.ok(operation||' stale same-tenant A denied',pg_temp.life(pa,a,operation,ar)->>'state'='PT409');
  perform pg_temp.ok(operation||' correct B token allowed',pg_temp.life(pa,b,operation,br)->>'state'='00000');
 end loop;
 perform pg_temp.ok('fresh restore retains dormant history A',public.tenant_has_restored_history_core_v1(a));
 perform pg_temp.ok('fresh restore retains dormant history B',public.tenant_has_restored_history_core_v1(b));
 r:=pg_temp.rpc(pa,format('select to_jsonb(public.platform_set_tenant_state_v1(%L,''activate''))',a));
 perform pg_temp.ok('fresh activation after restore allowed',r->>'state'='00000' and (select status='active' from public.tenants where id=a));
 perform pg_temp.ok('activation observes only targeted row; old A stale',pg_temp.life(pa,a,'archive',old_a)->>'state'='PT409');
 perform pg_temp.ok('old B still stale',pg_temp.life(pa,b,'archive',old_b)->>'state'='PT409');
 select lifecycle_revision into ar from public.tenants where id=a;select revision::text into ap from public.tenant_plan_assignments where tenant_id=a;
 foreach member_role in array array['admin','employee','instructor','user'] loop
  update public.tenant_memberships set role=member_role where tenant_id=a and user_id=u;
  perform pg_temp.ok(member_role||' lifecycle denied',pg_temp.life(u,a,'archive',ar)->>'state'='42501');
  perform pg_temp.ok(member_role||' restore denied',pg_temp.life(u,a,'restore',ar)->>'state'='42501');
  perform pg_temp.ok(member_role||' plan denied',pg_temp.plan(u,a,ap)->>'state'='42501');
 end loop;
 perform pg_temp.ok('anon lifecycle denied',pg_temp.life(null,a,'archive',ar)->>'state'='42501');
 perform pg_temp.ok('anon plan denied',pg_temp.plan(null,a,ap)->>'state'='42501');
 update public.platform_admins set status='suspended' where user_id=pa;
 perform pg_temp.ok('suspended PA denied',pg_temp.life(pa,a,'archive',ar)->>'state'='42501' and pg_temp.plan(pa,a,ap)->>'state'='42501');
 update public.platform_admins set status='active' where user_id=pa;
 update public.tenants set lifecycle_revision=br,lifecycle_restore_revision=ar where id=a;
 perform pg_temp.ok('direct lifecycle injection ignored',(select lifecycle_revision=ar and lifecycle_restore_revision is null from public.tenants where id=a));
 update public.tenant_plan_assignments set revision=br where tenant_id=a;
 perform pg_temp.ok('direct plan injection ignored',(select revision::text=ap from public.tenant_plan_assignments where tenant_id=a));
 begin burned:=nextval('app_private.tenant_concurrency_revision_seq');raise exception 'rollback allocation';exception when raise_exception then null;end;
 fresh:=nextval('app_private.tenant_concurrency_revision_seq');
 perform pg_temp.ok('rolled-back allocation never reused',fresh>burned);
 perform pg_temp.ok('sequence cannot cycle',(select not seqcycle and seqmax=9007199254740991 and seqcache=1 from pg_sequence where seqrelid='app_private.tenant_concurrency_revision_seq'::regclass));
 perform pg_temp.ok('all lifecycle and plan values globally unique',(select count(*)=count(distinct token) from(select lifecycle_revision token from public.tenants union all select revision from public.tenant_plan_assignments)x));
 perform pg_temp.ok('no client allocator privileges',not exists(select 1 from unnest(array['anon','authenticated','service_role'])role_name where has_sequence_privilege(role_name,'app_private.tenant_concurrency_revision_seq','USAGE,SELECT,UPDATE')));
 perform pg_temp.ok('PA cannot rewind allocator',pg_temp.rpc(pa,'select to_jsonb(setval(''app_private.tenant_concurrency_revision_seq'',1))')->>'state'='42501');
 perform pg_temp.ok('customer PII absent from lifecycle preview',not(pg_temp.rpc(pa,format('select public.platform_get_tenant_archive_preview_v1(%L)',a))::text ~ 'customer_|synthetic.invalid'));
 perform pg_temp.ok('customer PII absent from plan preview',not(pg_temp.rpc(pa,format('select public.platform_get_tenant_plan_change_preview_v1(%L,''booking_only_v1'')',a))::text ~ 'customer_|synthetic.invalid'));
end;$tests$;
select '1..'||count(*) from results;
select 'ok '||n||' - '||label from results order by n;
rollback;
select 'FIXTURE_CLEANUP='||count(*) from public.tenants where slug like 'sybr-%';
