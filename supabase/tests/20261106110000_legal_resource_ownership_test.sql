\set ON_ERROR_STOP on
begin;
-- This prefix is also used only in disposable local migration/concurrency DBs.
create schema legal_test;
create table legal_test.fixture(side text primary key,tenant uuid,user_id uuid,admin_id uuid,lane uuid,price uuid,event uuid,reservation uuid,registration uuid);
create table legal_test.results(n serial,label text);
create function legal_test.ok(label text,passed boolean) returns void language plpgsql as $$begin
 if passed is distinct from true then raise exception 'FAIL: %',label; end if;
 insert into legal_test.results(label) values(label);
end;$$;
create function legal_test.actor(actor uuid) returns void language plpgsql as $$begin
 perform set_config('request.jwt.claim.sub',coalesce(actor::text,''),true);
 perform set_config('request.jwt.claims',jsonb_build_object('sub',actor,'role','authenticated')::text,true);
end;$$;
create function legal_test.try_as(caller text,q text,actor uuid default null) returns jsonb language plpgsql as $$
declare state text; constraint_name text; affected integer; begin
 perform legal_test.actor(actor);
 execute format('set local role %I',caller); execute q; get diagnostics affected=row_count; reset role;
 perform legal_test.actor(null); return jsonb_build_object('state','00000','affected',affected);
exception when others then
 get stacked diagnostics state=returned_sqlstate,constraint_name=constraint_name;
 reset role; perform legal_test.actor(null); return jsonb_build_object('state',state,'constraint',constraint_name);
end;$$;
do $seed$
declare s text;f legal_test.fixture; begin
 foreach s in array array['A','B'] loop
  insert into legal_test.fixture values(s,gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid()) returning * into f;
  insert into auth.users(id,email,email_confirmed_at,is_anonymous) select id,id||'@legal-ownership.invalid',now(),false from unnest(array[f.user_id,f.admin_id]) id;
  insert into public.profiles(id,user_id,email,role) select id,id,email,'user' from auth.users where id=any(array[f.user_id,f.admin_id]) on conflict(user_id) do nothing;
  insert into public.tenants(id,name,slug,status) values(f.tenant,'Synthetic Legal '||s,'legal-r2-'||f.tenant,'active');
  insert into public.tenant_plan_assignments(tenant_id,plan_id,status) select f.tenant,id,'active' from public.saas_plans where plan_key='current_full_v1';
  insert into public.tenant_memberships(tenant_id,user_id,role,status) values(f.tenant,f.user_id,'user','active'),(f.tenant,f.admin_id,'admin','active');
  insert into public.shooting_lanes(id,tenant_id,name,type,is_active,max_shooters,booking_step_minutes,display_order,currency_code,resource_kind,whole_lane_bookable,positions_bookable)
   values(f.lane,f.tenant,'Synthetic '||s,'test',true,2,60,901,'PLN','lane',true,false);
  insert into public.lane_pricing_rules(id,lane_id,day_group,min_shooters,max_shooters,label,hourly_price,display_order,is_active)
   values(f.price,f.lane,'mon_thu',1,2,'Synthetic',10,1,true);
  insert into public.reservations(id,user_id,tenant_id,lane_id,customer_name,customer_email,customer_phone,reservation_date,start_time,end_time,duration_minutes,price,reservation_status,payment_status,attendance_status,shooters_count,pricing_rule_id,pricing_day_group_snapshot,lane_name_snapshot,pricing_label_snapshot,price_per_hour_snapshot,total_price,currency_code,creation_request_id)
   values(f.reservation,f.user_id,f.tenant,f.lane,'Synthetic','synthetic@legal-ownership.invalid','000',current_date+10,'12:00','13:00',60,10,'confirmed','pay_on_site','planned',1,f.price,'mon_thu','Synthetic','Synthetic',10,10,'PLN',gen_random_uuid());
  insert into public.events(id,tenant_id,title,event_date,start_time,end_time,is_active)
   values(f.event,f.tenant,'Synthetic '||s,current_date+10,'12:00','13:00',true);
  insert into public.event_registrations(id,tenant_id,event_id,user_id,customer_name,customer_email,customer_phone,registration_status,payment_status)
   values(f.registration,f.tenant,f.event,f.user_id,'Synthetic','synthetic@legal-ownership.invalid','000','registered','free');
 end loop;
end;$seed$;
-- LEGAL_FIXTURE_DOCUMENTS: the prefix above also works before the migration.
do $documents$
declare t uuid;kind text;doc uuid;v uuid;scope text;evidence text;body jsonb; begin
 for t,kind,scope in
  select null::uuid,k,'platform' from unnest(array['platform_terms','platform_privacy_notice','adult_self_declaration']) k
  union all select f.tenant,k,'tenant' from legal_test.fixture f cross join unnest(array['tenant_regulations','tenant_privacy_notice']) k
 loop
  doc:=gen_random_uuid();v:=gen_random_uuid();evidence:=case kind when 'adult_self_declaration' then 'self_declaration' when 'platform_privacy_notice' then 'acknowledgement' when 'tenant_privacy_notice' then 'acknowledgement' else 'acceptance' end;
  insert into public.legal_documents(id,document_type,scope_type,tenant_id) values(doc,kind,scope,t);
  body:=jsonb_build_object('format','legal-content-v1','document_id',doc,'document_type',kind,'scope_type',scope,'tenant_id',t,'version','v1','evidence_kind',evidence,'requires_reacceptance',true,'locale','pl-PL','title','SYNTHETIC NOT FOR PUBLICATION','blocks',jsonb_build_array(jsonb_build_object('type','paragraph','text','Synthetic')));
  insert into public.legal_document_versions(id,document_id,version,evidence_kind,content_canonical) values(v,doc,'v1',evidence,app_private.legal_canonical_content_v1(body));
  perform app_private.legal_publish_version_core_v1(v,null);
 end loop;
end;$documents$;
create function legal_test.evidence(side_name text,kind text,snapshot_tenant uuid default null) returns uuid language plpgsql as $$
declare f legal_test.fixture;subject uuid;action uuid;bundle jsonb;ids uuid[]; begin
 select * into strict f from legal_test.fixture where side=side_name;perform legal_test.actor(f.user_id);
 select id into subject from app_private.legal_subjects where user_id=f.user_id;
 if subject is null then insert into app_private.legal_subjects(user_id) values(f.user_id) returning id into subject;end if;
 bundle:=public.get_my_legal_requirements_v1(kind,case when kind='booking' then f.lane else f.event end)->'required_documents';
 select array_agg((x->>'document_version_id')::uuid order by (x->>'document_version_id')::uuid) into ids from jsonb_array_elements(bundle)x;
 set constraints app_private.legal_action_complete,app_private.legal_acceptance_complete deferred;
 insert into app_private.legal_actions(subject_id,tenant_id,context_type,reservation_id,event_registration_id,request_id,request_hash,outcome,offer_snapshot,required_document_version_ids)
 values(subject,coalesce(snapshot_tenant,f.tenant),kind,case when kind='booking' then f.reservation end,case when kind<>'booking' then f.registration end,gen_random_uuid(),extensions.digest(side_name||kind,'sha256'),case when kind='booking' then 'created' else 'registered' end,
  jsonb_build_object('amount_minor',1000,'currency','PLN','payment','pay_on_site','cancellation_hours',case when kind='booking' then 12 else 72 end),ids) returning id into action;
 insert into app_private.legal_acceptances select action,(x->>'document_version_id')::uuid,x->>'kind' from jsonb_array_elements(bundle)x;
 set constraints app_private.legal_action_complete,app_private.legal_acceptance_complete immediate;
 perform legal_test.actor(null);return action;
end;$$;
-- LEGAL_OWNERSHIP_TESTS: reusable setup ends here (local disposable DB only).
do $tests$
declare f legal_test.fixture;other legal_test.fixture;phase text;tab text;kind text;target uuid;actor uuid;r jsonb;q text;before_count bigint; begin
 perform legal_test.ok('no UNIQUE/index added to hot tables',not exists(select 1 from pg_constraint where conname in ('reservations_legal_tenant_id_key','event_registrations_legal_tenant_id_key')));
 perform legal_test.ok('resource FKs reuse PK with RESTRICT',(select count(*)=2 and bool_and(array_length(conkey,1)=1 and confdeltype='r') from pg_constraint where conrelid='app_private.legal_actions'::regclass and confrelid in ('public.reservations'::regclass,'public.event_registrations'::regclass)));
 perform legal_test.ok('exactly two ownership guards',(select count(*)=2 from pg_trigger where tgfoid='app_private.legal_resource_tenant_immutable_v1()'::regprocedure and not tgisinternal));
 foreach phase in array array['pre-evidence','with-evidence'] loop
  if phase='with-evidence' then
   for f in select * from legal_test.fixture loop
    foreach kind in array array['booking','event_registration'] loop
     perform legal_test.evidence(f.side,kind);
    end loop;
   end loop;
  end if;
  for f in select * from legal_test.fixture loop
   select * into strict other from legal_test.fixture where side<>f.side;
   foreach tab in array array['reservations','event_registrations'] loop
    target:=case when tab='reservations' then f.reservation else f.registration end;
    q:=case when tab='reservations' then format('update public.reservations set tenant_id=%L,lane_id=%L,pricing_rule_id=%L where id=%L',other.tenant,other.lane,other.price,target)
     else format('update public.event_registrations set tenant_id=%L,event_id=%L where id=%L',other.tenant,other.event,target) end;
    foreach actor in array array[f.user_id,f.admin_id] loop
     r:=legal_test.try_as('authenticated',q,actor);perform legal_test.ok(phase||' '||f.side||' '||tab||' authenticated/TA denies',r->>'state'='42501');
    end loop;
    r:=legal_test.try_as('service_role',q);perform legal_test.ok(phase||' '||f.side||' '||tab||' service typed denial',r->>'state'='23514' and r->>'constraint'='legal_resource_tenant_immutable');
    r:=legal_test.try_as('postgres',q);perform legal_test.ok(phase||' '||f.side||' '||tab||' owner normal DML denies',r->>'state'='23514');
    r:=legal_test.try_as('service_role',format('update public.%I set tenant_id=tenant_id where id=%L',tab,target));
    perform legal_test.ok(phase||' '||f.side||' '||tab||' same tenant allowed',r->>'state'='00000' and r->>'affected'='1');
   end loop;
  end loop;
 end loop;
 perform legal_test.ok('all evidence tenant snapshots coherent',not exists(select 1 from app_private.legal_actions a left join public.reservations r on r.id=a.reservation_id left join public.event_registrations e on e.id=a.event_registration_id where a.tenant_id is distinct from coalesce(r.tenant_id,e.tenant_id)));
 for f in select * from legal_test.fixture loop
  r:=legal_test.try_as('service_role',format('update public.reservations set admin_note=%L,payment_status=%L where id=%L','Synthetic note','paid_on_site',f.reservation));perform legal_test.ok(f.side||' reservation metadata/payment succeeds',r->>'state'='00000');
  r:=legal_test.try_as('postgres',format('update public.reservations set attendance_status=%L,checked_in_at=now() where id=%L','present',f.reservation));perform legal_test.ok(f.side||' check-in succeeds',r->>'state'='00000');
  r:=legal_test.try_as('postgres',format('update public.reservations set reservation_status=%L,attendance_status=%L,checked_in_at=null where id=%L','cancelled','planned',f.reservation));perform legal_test.ok(f.side||' reservation cancellation succeeds',r->>'state'='00000');
  r:=legal_test.try_as('service_role',format('update public.event_registrations set registration_status=%L,payment_status=%L,promotion_attempt_count=1,promotion_last_attempt_at=now() where id=%L','reserve','paid_on_site',f.registration));perform legal_test.ok(f.side||' status/payment/promotion metadata succeeds',r->>'state'='00000');
  r:=legal_test.try_as('postgres',format('update public.event_registrations set attendance_status=%L,attendance_version=1,attendance_marked_at=now(),attendance_marked_by=%L where id=%L','present',f.admin_id,f.registration));perform legal_test.ok(f.side||' event attendance succeeds',r->>'state'='00000');
  r:=legal_test.try_as('postgres',format('delete from public.reservations where id=%L',f.reservation));perform legal_test.ok(f.side||' booking history DELETE RESTRICT',r->>'state'='23503');
  r:=legal_test.try_as('postgres',format('delete from public.event_registrations where id=%L',f.registration));perform legal_test.ok(f.side||' event history DELETE RESTRICT',r->>'state'='23503');
 end loop;
 select count(*) into before_count from app_private.legal_acceptances;
 select * into f from legal_test.fixture where side='A';perform legal_test.actor(f.user_id);
 perform public.anonymize_my_account_v1();perform legal_test.actor(null);
 perform legal_test.ok('anonymization retains complete business receipts',(select count(*)=before_count from app_private.legal_acceptances));
 perform legal_test.ok('anonymization leaves resource tenant intact',(select tenant_id=f.tenant and user_id is null from public.reservations where id=f.reservation) and (select tenant_id=f.tenant and user_id is null from public.event_registrations where id=f.registration));
end;$tests$;
select '1..'||count(*) from legal_test.results;
select 'ok '||n||' - '||label from legal_test.results order by n;
rollback;
