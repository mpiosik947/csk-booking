\set ON_ERROR_STOP on
begin;
create temporary table results(n serial,label text) on commit drop;
create function pg_temp.ok(label text, passed boolean) returns void language plpgsql as $$begin
 if passed is distinct from true then raise exception 'FAIL: %',label; end if;
 insert into results(label) values(label);
end;$$;
create function pg_temp.actor(actor uuid) returns void language plpgsql as $$begin
 perform set_config('request.jwt.claims',jsonb_build_object('sub',actor,'role','authenticated')::text,true);
 perform set_config('request.jwt.claim.sub',coalesce(actor::text,''),true);
end;$$;
create function pg_temp.call(actor uuid, q text, caller text default 'authenticated') returns jsonb language plpgsql as $$
declare r jsonb; begin
 perform pg_temp.actor(actor); execute format('set local role %I',caller); execute q into r; reset role;
 perform pg_temp.actor(null); return jsonb_build_object('state','00000','value',r);
exception when others then reset role; perform pg_temp.actor(null); return jsonb_build_object('state',sqlstate,'error',sqlerrm); end;$$;
create function pg_temp.attempt(q text) returns text language plpgsql as $$begin execute q; return '00000'; exception when others then return sqlstate; end;$$;
create function pg_temp.version(doc uuid, label text, required boolean default true) returns uuid language plpgsql as $$
declare d public.legal_documents; v uuid:=gen_random_uuid(); kind text; body jsonb; begin
 select * into strict d from public.legal_documents where id=doc;
 kind:=case d.document_type when 'platform_cookie_storage_notice' then 'none' when 'adult_self_declaration' then 'self_declaration' when 'platform_privacy_notice' then 'acknowledgement' when 'tenant_privacy_notice' then 'acknowledgement' else 'acceptance' end;
 body:=jsonb_build_object('format','legal-content-v1','document_id',doc,'document_type',d.document_type,'scope_type',d.scope_type,'tenant_id',d.tenant_id,
  'version',label,'evidence_kind',kind,'requires_reacceptance',required,'locale','pl-PL','title','SYNTHETIC NOT FOR PUBLICATION',
  'blocks',jsonb_build_array(jsonb_build_object('type','paragraph','text','Zażółć synthetic '||label)));
 insert into public.legal_document_versions(id,document_id,version,evidence_kind,requires_reacceptance,content_canonical)
 values(v,doc,label,kind,required,app_private.legal_canonical_content_v1(body)); return v;
end;$$;
create function pg_temp.bundle(actor uuid, context text default 'account', resource uuid default null) returns jsonb language plpgsql as $$
declare r jsonb; begin
 r:=pg_temp.call(actor,format('select public.get_my_legal_requirements_v1(%L,%L)',context,resource));
 if r->>'state'<>'00000' then raise exception 'requirements: %',r; end if;
 return (select jsonb_agg(jsonb_build_object('document_version_id',x->'document_version_id','content_hash',x->'content_hash','kind',x->'kind') order by x->>'document_version_id') from jsonb_array_elements(r->'value'->'required_documents') x);
end;$$;
create function pg_temp.accept(actor uuid, req uuid, bundle jsonb, confirmations jsonb default '{"acceptance":true,"acknowledgement":true,"self_declaration":true}') returns jsonb language sql as $$
 select pg_temp.call(actor,format('select public.accept_my_account_legal_v1(%L,%L,%L)',req,bundle,confirmations));
$$;
create function pg_temp.fail_receipt() returns trigger language plpgsql as $$begin raise exception 'synthetic receipt failure' using errcode='PT599'; end;$$;

do $tests$
declare u uuid:=gen_random_uuid(); other_user uuid:=gen_random_uuid(); pa uuid:=gen_random_uuid(); ta uuid:=gen_random_uuid();
 t uuid:=gen_random_uuid(); b uuid:=gen_random_uuid(); e uuid:=gen_random_uuid(); eb uuid:=gen_random_uuid(); reg uuid:=gen_random_uuid();
 doc uuid; v uuid; terms uuid; terms_v1 uuid; terms_v2 uuid; tenant_doc uuid; tenant_v uuid; future uuid;
 req uuid:=gen_random_uuid(); r jsonb; first_result jsonb; bundle jsonb; current_bundle jsonb; history jsonb; sub uuid; action_key uuid;
 kind text; role_name text; tab text; signature text; command text; ids uuid[]; before_time timestamptz; before_count bigint; old_hash bytea;
begin
 insert into auth.users(id,email,email_confirmed_at,is_anonymous) select id,id||'@legal-fixture.invalid',now(),false from unnest(array[u,other_user,pa,ta]) id;
 insert into public.profiles(id,user_id,email,role) select id,id,email,'user' from auth.users where id=any(array[u,other_user,pa,ta]) on conflict(user_id) do nothing;
 insert into public.platform_admins(user_id,status) values(pa,'active');
 insert into public.tenants(id,name,slug,status) values(t,'Legal A','legal-'||t,'active'),(b,'Legal B','legal-'||b,'active');
 insert into public.tenant_plan_assignments(tenant_id,plan_id,status) select tenant,id,'active' from unnest(array[t,b]) tenant cross join public.saas_plans where plan_key='current_full_v1';
 insert into public.tenant_memberships(tenant_id,user_id,role,status) values(t,ta,'admin','active'),(b,ta,'admin','active'),(t,u,'user','active'),(b,other_user,'user','active');
 insert into public.events(id,tenant_id,title,event_date,start_time,end_time) values(e,t,'Legal fixture',current_date+10,'12:00','13:00'),(eb,b,'Legal B fixture',current_date+10,'12:00','13:00');
 perform pg_temp.ok('no fabricated evidence',(select count(*)=0 from app_private.legal_actions));
 perform pg_temp.ok('empty registry account contract fails closed',pg_temp.call(u,'select public.get_my_legal_requirements_v1()')->>'state'='PT503');
 perform pg_temp.ok('empty registry public document is null',pg_temp.call(null,$q$select public.get_published_legal_document_v1('platform_terms')$q$,'anon')->'value'='null'::jsonb);
 foreach tab in array array['public.legal_documents','public.legal_document_versions','app_private.legal_subjects','app_private.legal_actions','app_private.legal_acceptances'] loop
  perform pg_temp.ok(tab||' owner and RLS',(select relrowsecurity and relowner='postgres'::regrole from pg_class where oid=tab::regclass));
  foreach role_name in array array['anon','authenticated','service_role'] loop
   perform pg_temp.ok(tab||' no direct privileges for '||role_name,not has_table_privilege(role_name,tab,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'));
   perform pg_temp.ok(tab||' actual SELECT denial '||role_name,pg_temp.call(u,'select to_jsonb(x) from '||tab||' x',role_name)->>'state'='42501');
  end loop;
 end loop;
 for signature in select oid::regprocedure::text from pg_proc where pronamespace='app_private'::regnamespace and proname like 'legal_%' loop
  foreach role_name in array array['anon','authenticated','service_role'] loop
   perform pg_temp.ok(signature||' private execute denied '||role_name,not has_function_privilege(role_name,signature,'EXECUTE'));
  end loop;
 end loop;
 perform pg_temp.ok('4 new fixed-path SD RPCs',(select count(*)=4 and bool_and(proowner='postgres'::regrole and proconfig=array['search_path=pg_catalog, public, pg_temp']) from pg_proc where proname in ('get_published_legal_document_v1','get_my_legal_requirements_v1','get_my_legal_acceptances_v1','accept_my_account_legal_v1') and prosecdef));
 perform pg_temp.ok('no private SD',(select count(*)=0 from pg_proc where pronamespace='app_private'::regnamespace and proname like 'legal_%' and prosecdef));
 foreach kind in array array['platform_terms','platform_privacy_notice','adult_self_declaration','platform_cookie_storage_notice','tenant_regulations','tenant_privacy_notice'] loop
  doc:=gen_random_uuid(); insert into public.legal_documents(id,document_type,scope_type,tenant_id) values(doc,kind,case when kind like 'tenant_%' then 'tenant' else 'platform' end,case when kind like 'tenant_%' then t else null end);
  v:=pg_temp.version(doc,'v1');
  perform pg_temp.ok(kind||' draft invisible',pg_temp.call(null,format('select public.get_published_legal_document_v1(null,null,%L)',v),'anon')->'value'='null'::jsonb);
  perform app_private.legal_publish_version_core_v1(v,null);
  perform pg_temp.ok(kind||' published visible',pg_temp.call(null,format('select public.get_published_legal_document_v1(null,null,%L)',v),'anon')->'value'->>'document_version_id'=v::text);
  perform pg_temp.ok(kind||' generated content hash',(select content_hash=extensions.digest(content_canonical,'sha256') from public.legal_document_versions where id=v));
  if kind='platform_terms' then terms:=doc; terms_v1:=v; end if;
  if kind='tenant_regulations' then tenant_doc:=doc; tenant_v:=v; end if;
 end loop;
 perform pg_temp.ok('SQL canonical SHA vector',encode(extensions.digest(app_private.legal_canonical_content_v1('{}'),'sha256'),'hex')='44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a');
 perform pg_temp.ok('SQL key order stable',app_private.legal_canonical_content_v1('{"z":[true,null,"\t\n😀"],"a":"é"}')=E'{"a":"é","z":[true,null,"\\t\\n😀"]}');
 perform pg_temp.ok('noncanonical NFC rejected',pg_temp.attempt($q$select app_private.legal_canonical_content_v1(jsonb_build_object('text',U&'e\0301'))$q$)='22023');
 perform pg_temp.ok('numbers rejected',pg_temp.attempt($q$select app_private.legal_canonical_content_v1('{"a":1}')$q$)='22023');
 perform pg_temp.ok('anon own history denied',pg_temp.call(null,'select public.get_my_legal_acceptances_v1()','anon')->>'state'='42501');
 perform pg_temp.ok('missing JWT own reader denied',pg_temp.call(null,'select public.get_my_legal_requirements_v1()')->>'state'='42501');
 perform pg_temp.ok('missing profile denied',pg_temp.call(gen_random_uuid(),'select public.get_my_legal_requirements_v1()')->>'state'='42501');
 perform pg_temp.ok('legacy classification explicit',(pg_temp.call(u,'select public.get_my_legal_requirements_v1()')->'value'->>'pre_registry_no_evidence')::boolean);
 bundle:=pg_temp.bundle(u);
 perform pg_temp.ok('account exactly three semantic kinds',jsonb_array_length(bundle)=3 and (select array_agg(x->>'kind' order by x->>'kind') from jsonb_array_elements(bundle)x)=array['acceptance','acknowledgement','self_declaration']);
 perform pg_temp.ok('cookie not an acceptance',not exists(select 1 from jsonb_array_elements(bundle)x where x->>'kind'='none'));
 perform pg_temp.ok('explicit confirmation required',pg_temp.accept(u,req,bundle,'{"acceptance":true,"acknowledgement":true,"self_declaration":false}')->>'state'='22023');
 perform pg_temp.ok('client timestamp not an accepted input',pg_temp.accept(u,req,bundle,'{"acceptance":true,"acknowledgement":true,"self_declaration":true,"accepted_at":"2000-01-01"}')->>'state'='22023');
 perform pg_temp.ok('wrong hash rejected',pg_temp.accept(u,req,jsonb_set(bundle,'{0,content_hash}','"forged"'))->>'state'='PT409');
 perform pg_temp.ok('NULL bundle denied',pg_temp.accept(u,req,null)->>'state'='22023');
 perform pg_temp.ok('empty bundle denied',pg_temp.accept(u,req,'[]')->>'state'='22023');
 perform pg_temp.ok('unknown version denied',pg_temp.accept(u,req,jsonb_set(bundle,'{0,document_version_id}',to_jsonb(gen_random_uuid())))->>'state'='PT409');
 doc:=pg_temp.version(terms,'unpublished');
 perform pg_temp.ok('draft version denied',pg_temp.accept(u,req,jsonb_set(bundle,'{0,document_version_id}',to_jsonb(doc)))->>'state'='PT409');
 perform pg_temp.ok('client user override rejected',pg_temp.accept(u,req,jsonb_set(bundle,'{0,user_id}',to_jsonb(other_user)))->>'state'='PT409');
 perform pg_temp.ok('missing required version rejected',pg_temp.accept(u,req,bundle-0)->>'state'='PT409');
 perform pg_temp.ok('duplicate version rejected',pg_temp.accept(u,req,bundle||jsonb_build_array(bundle->0))->>'state'='PT409');
 perform pg_temp.ok('wrong kind rejected',pg_temp.accept(u,req,jsonb_set(bundle,'{0,kind}','"none"'))->>'state'='PT409');
 perform pg_temp.ok('failed writes leave no subject/action',(select count(*)=0 from app_private.legal_subjects) and (select count(*)=0 from app_private.legal_actions));
 before_time:=clock_timestamp(); first_result:=pg_temp.accept(u,req,bundle); action_key:=(first_result->'value'->>'action_id')::uuid;
 perform pg_temp.ok('post-auth completion succeeds',first_result->>'state'='00000' and (first_result->'value'->>'changed')::boolean);
 perform pg_temp.ok('time generated once by DB',(select accepted_at>=before_time and accepted_at<=clock_timestamp() from app_private.legal_actions where id=action_key));
 select subject_id into sub from app_private.legal_actions where id=action_key;
 perform pg_temp.ok('actor bound to JWT',(select user_id=u from app_private.legal_subjects where id=sub));
 perform pg_temp.ok('three complete receipts',(select count(*)=3 from app_private.legal_acceptances where action_id=action_key));
 set constraints all immediate; set constraints all deferred;
 r:=pg_temp.accept(u,req,bundle); perform pg_temp.ok('same request idempotent',r->'value'->>'action_id'=action_key::text and r->'value'->>'changed'='false');
 r:=pg_temp.accept(u,gen_random_uuid(),bundle); perform pg_temp.ok('same bundle new request no duplicate',r->'value'->>'action_id'=action_key::text and (select count(*)=1 from app_private.legal_actions));
 perform pg_temp.ok('request replay mismatched body denied',pg_temp.accept(u,req,bundle-0)->>'state'='PT409');
 foreach role_name in array array['anon','service_role'] loop
  foreach command in array array['select public.get_my_legal_requirements_v1()','select public.get_my_legal_acceptances_v1()',format('select public.accept_my_account_legal_v1(%L,%L,%L)',req,bundle,'{"acceptance":true,"acknowledgement":true,"self_declaration":true}')] loop
   perform pg_temp.ok(role_name||' account RPC execute denied',pg_temp.call(u,command,role_name)->>'state'='42501');
  end loop;
 end loop;
 perform pg_temp.ok('PA cannot invoke publisher',pg_temp.call(pa,format('select app_private.legal_publish_version_core_v1(%L,null)',terms_v1))->>'state'='42501');
 perform pg_temp.ok('TA cannot invoke detach helper',pg_temp.call(ta,'select app_private.legal_detach_subject_core_v1()')->>'state'='42501');
 perform pg_temp.actor(other_user);
 perform pg_temp.ok('even owner fixture cannot forge actor',pg_temp.attempt(format('insert into app_private.legal_subjects(user_id) values(%L)',pa))='42501');
 perform pg_temp.actor(null);
 select count(*) into before_count from app_private.legal_actions;
 create trigger fixture_fail_receipt before insert on app_private.legal_acceptances for each row execute function pg_temp.fail_receipt();
 perform pg_temp.ok('receipt failure fails entire account RPC',pg_temp.accept(other_user,gen_random_uuid(),bundle)->>'state'='PT599');
 drop trigger fixture_fail_receipt on app_private.legal_acceptances;
 perform pg_temp.ok('receipt failure rolls back action and subject',(select count(*)=before_count from app_private.legal_actions) and not exists(select 1 from app_private.legal_subjects where user_id=other_user));
 select array_agg((x->>'document_version_id')::uuid order by (x->>'document_version_id')::uuid) into ids from jsonb_array_elements(bundle)x;
 perform pg_temp.actor(u);
 perform pg_temp.ok('deferred missing receipt rejected at transaction boundary',pg_temp.attempt(format($q$do $fault$begin
  insert into app_private.legal_actions(subject_id,context_type,request_id,request_hash,outcome,required_document_version_ids)
  values(%L,'account_reacceptance',gen_random_uuid(),extensions.digest('incomplete','sha256'),'account_reaccepted',%L);
  set constraints all immediate;
 end;$fault$;$q$,sub,ids))='23514');
 perform pg_temp.actor(null);
 perform pg_temp.ok('deferred failure leaves no incomplete action',(select count(*)=before_count from app_private.legal_actions));
 history:=pg_temp.call(u,'select public.get_my_legal_acceptances_v1()')->'value';
 perform pg_temp.ok('owner history complete',jsonb_array_length(history)=1 and jsonb_array_length(history->0->'documents')=3);
 perform pg_temp.ok('history PII/authority minimal',not(history::text ~ 'user_id|email|phone|subject_id|request_hash|request_id|ip_address|user_agent|promotion_token'));
 foreach v in array array[other_user,ta,pa] loop perform pg_temp.ok('other actor cannot see history',pg_temp.call(v,'select public.get_my_legal_acceptances_v1()')->'value'='[]'::jsonb); end loop;
 perform pg_temp.ok('forged cursor is not authority',pg_temp.call(other_user,format('select public.get_my_legal_acceptances_v1(now(),%L,100)',action_key))->'value'='[]'::jsonb);
 perform pg_temp.ok('half cursor rejected',pg_temp.call(u,format('select public.get_my_legal_acceptances_v1(null,%L,10)',action_key))->>'state'='22023');
 perform pg_temp.ok('unbounded history rejected',pg_temp.call(u,'select public.get_my_legal_acceptances_v1(null,null,101)')->>'state'='22023');
 foreach tab in array array['app_private.legal_actions','app_private.legal_acceptances'] loop
  perform pg_temp.ok(tab||' DELETE owner guard',pg_temp.attempt('delete from '||tab)='42501');
  perform pg_temp.ok(tab||' TRUNCATE owner guard',pg_temp.attempt('truncate '||tab||' cascade')='42501');
 end loop;
 perform pg_temp.ok('action UPDATE immutable',pg_temp.attempt('update app_private.legal_actions set accepted_at=now()')='42501');
 perform pg_temp.ok('receipt UPDATE immutable',pg_temp.attempt($q$update app_private.legal_acceptances set acceptance_kind='acceptance'$q$)='42501');
 perform pg_temp.ok('published content immutable',pg_temp.attempt(format('update public.legal_document_versions set content_canonical=content_canonical||%L where id=%L',' ',terms_v1))='42501');
 perform pg_temp.ok('published effective date immutable',pg_temp.attempt(format('update public.legal_document_versions set effective_at=now() where id=%L',terms_v1))='42501');
 perform pg_temp.ok('document tenant identity immutable',pg_temp.attempt(format('update public.legal_documents set tenant_id=%L where id=%L',b,tenant_doc))='42501');
 perform pg_temp.ok('version deletion guarded',pg_temp.attempt(format('delete from public.legal_document_versions where id=%L',terms_v1))='42501');
 perform pg_temp.ok('tenant deletion denied',pg_temp.attempt(format('delete from public.tenants where id=%L',t))<>'00000');
 perform pg_temp.ok('tenant registry FK is RESTRICT',(select confdeltype='r' from pg_constraint where conrelid='public.legal_documents'::regclass and confrelid='public.tenants'::regclass));
 terms_v2:=pg_temp.version(terms,'v2'); select content_hash into old_hash from public.legal_document_versions where id=terms_v1;
 perform pg_temp.ok('changed snapshot hash changes',(select content_hash<>old_hash from public.legal_document_versions where id=terms_v2));
 perform pg_temp.ok('publication expected pointer conflict',pg_temp.attempt(format('select app_private.legal_publish_version_core_v1(%L,null)',terms_v2))='PT409');
 perform app_private.legal_publish_version_core_v1(terms_v2,terms_v1);
 perform pg_temp.ok('old version is durable archive',pg_temp.call(null,format('select public.get_published_legal_document_v1(null,null,%L)',terms_v1),'anon')->'value'->>'status'='retired');
 perform pg_temp.ok('stale submission rejected',pg_temp.accept(other_user,gen_random_uuid(),bundle)->>'state'='PT409');
 perform pg_temp.ok('required change marks reacceptance',pg_temp.call(u,'select public.get_my_legal_requirements_v1()')->'value'->>'needs_reacceptance'='true');
 current_bundle:=pg_temp.bundle(u); r:=pg_temp.accept(u,gen_random_uuid(),current_bundle);
 perform pg_temp.ok('reacceptance succeeds',r->>'state'='00000' and (select count(*)=1 from app_private.legal_actions where context_type='account_reacceptance'));
 v:=pg_temp.version(terms,'v3',false); perform app_private.legal_publish_version_core_v1(v,terms_v2);
 perform pg_temp.ok('nonrequiring version preserves valid old receipt',pg_temp.call(u,'select public.get_my_legal_requirements_v1()')->'value'->>'needs_reacceptance'='false');
 perform pg_temp.ok('no fictitious receipt for v3',not exists(select 1 from app_private.legal_acceptances where document_version_id=v));
 future:=pg_temp.version(terms,'v4'); perform app_private.legal_publish_version_core_v1(future,v,clock_timestamp()+interval '1 day');
 perform pg_temp.ok('future publication not current',(select current_version_id=v from public.legal_documents where id=terms));
 doc:=pg_temp.version(terms,'v5'); perform pg_temp.ok('ambiguous future publication rejected',pg_temp.attempt(format('select app_private.legal_publish_version_core_v1(%L,%L)',doc,v))='23514');
 perform pg_temp.ok('tenant A user cannot resolve B event',pg_temp.call(u,format('select public.get_my_legal_requirements_v1(%L,%L)','event_registration',eb))->>'state'='42501');
 perform pg_temp.ok('tenant B user cannot resolve A event',pg_temp.call(other_user,format('select public.get_my_legal_requirements_v1(%L,%L)','event_registration',e))->>'state'='42501');
 perform pg_temp.ok('random resource denied',pg_temp.call(u,format('select public.get_my_legal_requirements_v1(%L,%L)','booking',gen_random_uuid()))->>'state'='42501');
 perform pg_temp.ok('invalid context rejected',pg_temp.call(u,$q$select public.get_my_legal_requirements_v1('delete')$q$)->>'state'='22023');
 perform pg_temp.ok('account cannot take tenant/resource parameter',pg_temp.call(u,format('select public.get_my_legal_requirements_v1(%L,%L)','account',t))->>'state'='22023');
 -- Synthetic business receipt inserted only by the owner fixture. No new business writer is exposed.
 insert into public.event_registrations(id,tenant_id,event_id,user_id,customer_name,customer_email,customer_phone,registration_status) values(reg,t,e,u,'Synthetic',u||'@legal-fixture.invalid','000000000','reserve');
 bundle:=pg_temp.bundle(u,'event_registration',e); select array_agg((x->>'document_version_id')::uuid order by (x->>'document_version_id')::uuid) into ids from jsonb_array_elements(bundle)x;
 perform pg_temp.actor(u);
 set constraints app_private.legal_action_complete,app_private.legal_acceptance_complete deferred;
 insert into app_private.legal_actions(subject_id,tenant_id,context_type,event_registration_id,request_id,request_hash,outcome,offer_snapshot,required_document_version_ids)
 values(sub,t,'event_registration',reg,gen_random_uuid(),extensions.digest('fixture','sha256'),'reserve','{"amount_minor":0,"currency":"PLN","payment":"pay_on_site","cancellation_hours":72}',ids) returning id into action_key;
 insert into app_private.legal_acceptances select action_key,(x->>'document_version_id')::uuid,x->>'kind' from jsonb_array_elements(bundle)x;
 set constraints all immediate; set constraints all deferred; perform pg_temp.actor(null);
 perform pg_temp.ok('same waitlist versions need no new evidence',pg_temp.call(u,format('select public.get_my_legal_requirements_v1(%L,%L)','event_promotion',reg))->'value'->>'promotion_reacceptance_required'='false');
 perform pg_temp.ok('wrong waitlist owner denied',pg_temp.call(other_user,format('select public.get_my_legal_requirements_v1(%L,%L)','event_promotion',reg))->>'state'='42501');
 v:=pg_temp.version(tenant_doc,'v2'); perform app_private.legal_publish_version_core_v1(v,tenant_v);
 perform pg_temp.ok('changed waitlist required version demands reacceptance',pg_temp.call(u,format('select public.get_my_legal_requirements_v1(%L,%L)','event_promotion',reg))->'value'->>'promotion_reacceptance_required'='true');
 perform pg_temp.ok('historical business deletion restricted',pg_temp.attempt(format('delete from public.event_registrations where id=%L',reg))='23503');
 r:=pg_temp.call(pa,format('select public.platform_get_tenant_delete_eligibility_v1(%L)',t));
 perform pg_temp.ok('dependency pin reconciled',r->>'state'='00000' and not(r::text like '%UNKNOWN_DEPENDENCY%'));
 perform pg_temp.ok('dependency counts minimal',r->'value'->'dependency_summary'->>'legal_actions'='1' and r->'value'->'eligibility'->>'can_hard_delete'='false');
 perform pg_temp.ok('no private identity column expansion',(select count(*)=0 from information_schema.columns where table_schema='app_private' and table_name like 'legal_%' and column_name in ('email','name','ip','user_agent','date_of_birth','device_fingerprint')));
 create table public.legal_unexpected_dependency(id uuid);
 perform pg_temp.ok('dependency reader still fails closed for unknown drift',pg_temp.call(pa,format('select public.platform_get_tenant_delete_eligibility_v1(%L)',t))::text like '%UNKNOWN_DEPENDENCY%');
 drop table public.legal_unexpected_dependency;
 perform pg_temp.ok('published registry content remains unprivileged',pg_temp.call(pa,format('update public.legal_document_versions set version=%L where id=%L returning to_jsonb(legal_document_versions)','forged',terms_v1))->>'state'='42501');
 set constraints all immediate;
 select count(*) into before_count from app_private.legal_acceptances;
 r:=pg_temp.call(u,'select public.anonymize_my_account_v1()');
 perform pg_temp.ok('existing anonymization succeeds',r->>'state'='00000');
 perform pg_temp.ok('identity detached but receipts retained',(select user_id is null from app_private.legal_subjects where id=sub) and (select count(*)=before_count from app_private.legal_acceptances));
 perform pg_temp.ok('pending Auth deletion cannot create evidence',pg_temp.accept(u,gen_random_uuid(),pg_temp.bundle(other_user))->>'state'='42501');
 perform pg_temp.ok('detached identity cannot see receipts',pg_temp.call(u,'select public.get_my_legal_acceptances_v1()')->>'state'='42501');
 delete from auth.users where id=u;
 perform pg_temp.ok('Auth delete retains evidence',(select count(*)=before_count from app_private.legal_acceptances));
 r:=pg_temp.accept(other_user,gen_random_uuid(),pg_temp.bundle(other_user));
 perform pg_temp.ok('second actor owns separate evidence',r->>'state'='00000');
 set constraints all immediate;
 select count(*) into before_count from app_private.legal_acceptances;
 delete from auth.users where id=other_user;
 perform pg_temp.ok('direct Auth deletion SET NULL safety net',(select count(*)=before_count from app_private.legal_acceptances) and not exists(select 1 from app_private.legal_subjects where user_id=other_user));
end;$tests$;
select '1..'||count(*) from results;
select 'ok '||n||' - '||label from results order by n;
rollback;
