-- Local disposable database only. All fixture creation is rolled back.
\set ON_ERROR_STOP on
begin;
create temp table cases(label text primary key, tid uuid unique not null, expected text[], response jsonb);
create function pg_temp.as_pa(actor uuid, statement text) returns jsonb language plpgsql as $$
declare result jsonb;
begin
  perform set_config('request.jwt.claims',jsonb_build_object('sub',actor,'role','authenticated')::text,true);
  perform set_config('request.jwt.claim.sub',actor::text,true);
  set local role authenticated;
  execute statement into result;
  reset role;
  return result;
end;$$;
do $matrix$
declare pa uuid:=gen_random_uuid(); u uuid:=gen_random_uuid(); lane uuid:=gen_random_uuid(); price uuid:=gen_random_uuid();
  media uuid:=gen_random_uuid(); draft uuid; r jsonb; item record; control jsonb; h uuid; rid uuid:=gen_random_uuid();
begin
  insert into auth.users(id,email,email_confirmed_at,is_anonymous) select x,x||'@example.invalid',now(),false from unnest(array[pa,u])x;
  insert into public.profiles(id,user_id,email) select id,id,email from auth.users where id in(pa,u) on conflict(user_id) do nothing;
  insert into public.platform_admins(user_id,status) values(pa,'active');
  insert into cases(label,tid,expected) select label,gen_random_uuid(),expected from (values
    ('A0 bare archived',array[]::text[]),('B member',array['TENANT_MEMBERSHIPS_EXIST','TENANT_PROFILE_LINKS_EXIST']),
    ('C reservation',array['RESERVATIONS_EXIST','SETTLEMENTS_EXIST']),('D event',array['EVENTS_EXIST','EVENT_REGISTRATIONS_EXIST']),
    ('E audit',array['PLATFORM_AUDIT_EXISTS']),('F partners',array['TENANT_PARTNERS_EXIST','PARTNER_AUDIT_EXISTS','PARTNER_MEDIA_EXISTS']),
    ('G legal',array['LEGAL_DOCUMENTS_EXIST']),('H control',array[]::text[])
  ) f(label,expected);
  insert into public.tenants(id,name,slug,status) select tid,label,'ux2e-'||tid,case when left(label,1) in ('C','D') then 'active' else 'archived' end from cases;
  select tid into h from cases where label='H control';
  control:=pg_temp.as_pa(pa,format('select public.platform_get_tenant_delete_eligibility_v1(%L)',h));
  insert into public.tenant_memberships(tenant_id,user_id,role,status) select tid,u,'admin','active' from cases where label='B member';
  insert into public.platform_audit_logs(actor_user_id,tenant_id,action,details) select pa,tid,'tenant_created','{"private":"LOCAL_ONLY"}' from cases where label='E audit';
  select tid into draft from cases where label='F partners';
  insert into app_private.tenant_partner_media(id,tenant_id,actor_user_id,width,height,byte_size,sha256) values(media,draft,pa,100,100,100,repeat('a',64));
  insert into public.tenant_partners(id,tenant_id,name,kind,display_format,media_id,is_active,archived_at) values
    (gen_random_uuid(),draft,'Active','partner','logo',media,true,null),(gen_random_uuid(),draft,'Archived','sponsor','banner',media,false,now());
  insert into app_private.tenant_partner_changes(tenant_id,partner_id,actor_user_id,actions) select draft,id,pa,array['test'] from public.tenant_partners where tenant_id=draft;
  insert into public.legal_documents(document_type,scope_type,tenant_id) select 'tenant_regulations','tenant',tid from cases where label='G legal';
  select tid into draft from cases where label='D event';
  insert into public.events(id,tenant_id,title,event_date,start_time,end_time,is_active) values(rid,draft,'Local event',current_date+7,'10:00','11:00',true);
  insert into public.event_registrations(tenant_id,event_id,user_id,customer_name,customer_email,customer_phone,registration_status,payment_status)
    values(draft,rid,u,'Local','local@example.invalid','000','registered','free');
  select tid into draft from cases where label='C reservation';
  insert into public.shooting_lanes(id,tenant_id,name,type,is_active,max_shooters,booking_step_minutes,display_order,currency_code,resource_kind,whole_lane_bookable,positions_bookable)
    values(lane,draft,'Local lane','test',true,2,60,1,'PLN','lane',true,false);
  insert into public.lane_pricing_rules(id,lane_id,day_group,min_shooters,max_shooters,label,hourly_price,display_order,is_active)
    values(price,lane,'mon_thu',1,2,'Local',10,1,true);
  insert into public.reservations(id,user_id,tenant_id,lane_id,customer_name,customer_email,customer_phone,reservation_date,start_time,end_time,duration_minutes,price,reservation_status,payment_status,attendance_status,shooters_count,pricing_rule_id,pricing_day_group_snapshot,lane_name_snapshot,pricing_label_snapshot,price_per_hour_snapshot,total_price,currency_code,creation_request_id)
    values(rid,u,draft,lane,'Local','local@example.invalid','000',current_date+7,'10:00','11:00',60,10,'confirmed','pay_on_site','planned',1,price,'mon_thu','Local','Local',10,10,'PLN',gen_random_uuid());
  insert into public.external_settlement_records(tenant_id,reservation_id,actor_user_id,idempotency_key,kind,amount,currency,external_reference)
    values(draft,rid,pa,gen_random_uuid(),'external_refund',1,'PLN','LOCAL_ONLY');
  r:=pg_temp.as_pa(pa,format('select public.platform_create_tenant_draft_v1(%L,%L,%L,%L,null,%L)','Local draft','ux2e-'||rid,'ux2e-public-'||rid,'Local',gen_random_uuid()));
  draft:=(r->>'tenant_id')::uuid;
  perform pg_temp.as_pa(pa,format('select public.platform_archive_tenant_v1(%L,%L,%L)',draft,(select lifecycle_revision from public.tenants where id=draft),gen_random_uuid()));
  insert into cases(label,tid,expected) values('A product draft',draft,array['CREATION_LEDGER_EXISTS','PLATFORM_AUDIT_EXISTS','PLATFORM_TENANT_LIFECYCLE_REQUESTS_EXIST']);
  for item in select * from cases order by label loop
    r:=pg_temp.as_pa(pa,format('select public.platform_get_tenant_delete_eligibility_v1(%L)',item.tid));
    if r#>>'{eligibility,can_hard_delete}' is distinct from 'false' or r#>>'{tenant,tenant_id}' is distinct from item.tid::text
      or not (r->'blockers' @> '[{"code":"HARD_DELETE_POLICY_DEFERRED","hard_blocker":true}]') or r::text like '%LOCAL_ONLY%'
      or exists(select 1 from unnest(item.expected) code where not exists(select 1 from jsonb_array_elements(r->'blockers') b where b->>'code'=code and (b->>'count')::int>0))
      or (item.label in ('A0 bare archived','H control') and jsonb_array_length(r->'blockers')<>1)
    then raise exception 'Wrong eligibility: % %',item.label,r; end if;
    if item.label='H control' and r is distinct from control then raise exception 'Cross-tenant change'; end if;
    update cases set response=r where tid=item.tid;
  end loop;
end;$matrix$;
select jsonb_agg(jsonb_build_object('fixture',label,'status',response#>>'{tenant,status}','eligible',response#>'{eligibility,can_hard_delete}','blockers',response->'blockers') order by label) from cases;
rollback;
