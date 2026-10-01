\set ON_ERROR_STOP on
begin;
-- BEGIN privacy fixture helpers (also loaded by the isolated Auth/Next E2E).
create function pg_temp.privacy_actor(u uuid,q text) returns jsonb language plpgsql as $$
declare v jsonb;
begin
 perform set_config('request.jwt.claim.sub',u::text,true);
 perform set_config('request.jwt.claims',jsonb_build_object('sub',u,'role','authenticated')::text,true);
 set local role authenticated; execute q into v; reset role;
 perform set_config('request.jwt.claim.sub','',true);perform set_config('request.jwt.claims','{}',true);return v;
exception when others then
 reset role;perform set_config('request.jwt.claim.sub','',true);perform set_config('request.jwt.claims','{}',true);raise;
end;$$;
create function pg_temp.privacy_staff(actor uuid,event_id uuid,ids uuid[]) returns void language plpgsql as $$
declare revision text; result jsonb;
begin
 revision:=pg_temp.privacy_actor(actor,format('select public.admin_list_available_event_instructors_v1(%L)',event_id))->>'revision';
 result:=pg_temp.privacy_actor(actor,format('select public.admin_set_event_instructors_v1(%L,%L::uuid[],%L)',event_id,ids,revision));
 if not (result ? 'revision') or result->>'changed' is distinct from 'true' then raise exception 'Instructor fixture failed: %',result;end if;
end;$$;
create function pg_temp.privacy_fixture(u uuid,f uuid,last_admin uuid,ordinary uuid,staff uuid) returns jsonb language plpgsql as $$
declare
 a uuid:=gen_random_uuid();b uuid:=gen_random_uuid();c uuid:=gen_random_uuid();
 ea uuid:=gen_random_uuid();eb uuid:=gen_random_uuid();lane uuid;price uuid;tenant uuid;
 ra uuid:=gen_random_uuid();rb uuid:=gen_random_uuid();rf uuid:=gen_random_uuid();
 ga uuid:=gen_random_uuid();gb uuid:=gen_random_uuid();gn uuid:=gen_random_uuid();gf uuid:=gen_random_uuid();
 d uuid:=gen_random_uuid();df uuid:=gen_random_uuid();settlement uuid:=gen_random_uuid();sforeign uuid:=gen_random_uuid();
 token uuid:='8edbee00-0000-4000-8000-000000000001'; result jsonb;
begin
 delete from public.tenant_memberships where user_id=any(array[u,f,last_admin,staff]);
 update public.profiles set full_name='Privacy Own',phone='500111222' where user_id=u;
 update public.profiles set full_name='FOREIGN_PRIVATE_PERSON',phone='500999888' where user_id=f;
 update auth.users set recovery_token='NEVER_RECOVERY_SECRET',confirmation_token='NEVER_CONFIRMATION_SECRET',
 raw_user_meta_data=jsonb_build_object('accepted_terms',true,'accepted_privacy',true,'provider_secret','NEVER_PROVIDER_SECRET','service_key','NEVER_SERVICE_KEY') where id=u;
 insert into public.tenants(id,name,slug,status)values(a,'Privacy A','privacy-a-'||a,'active'),(b,'Privacy B','privacy-b-'||b,'active'),(c,'Privacy C','privacy-c-'||c,'active');
 insert into public.tenant_plan_assignments(tenant_id,plan_id,status)
 select t,id,'active' from unnest(array[a,b,c])t cross join public.saas_plans where plan_key='current_full_v1';
 insert into public.tenant_memberships(tenant_id,user_id,role,status)values
 (a,u,'admin','active'),(b,u,'instructor','active'),(a,f,'instructor','active'),(b,f,'user','active'),
 (a,staff,'admin','active'),(b,staff,'admin','active'),(c,last_admin,'admin','active');
 insert into public.tenant_user_admin_notes(tenant_id,user_id,admin_note,updated_by)values(a,u,'NEVER_ADMIN_NOTE',staff);
 insert into public.tenant_user_verifications(tenant_id,user_id,verification_status,permissions_verification_note)values(a,u,'pending','NEVER_VERIFICATION_NOTE');
 insert into public.events(id,tenant_id,title,event_date,start_time,end_time,is_active,max_participants)
 values(ea,a,'Privacy Event A',current_date+30,'10:00','11:00',true,10),(eb,b,'Privacy Event B',current_date,'00:00','23:59',true,10);
 perform pg_temp.privacy_staff(staff,eb,array[u]);
 perform pg_temp.privacy_staff(u,ea,array[f]);
 perform pg_temp.privacy_staff(u,ea,'{}');
 foreach tenant in array array[a,b] loop
  lane:=gen_random_uuid();price:=gen_random_uuid();
  insert into public.shooting_lanes(id,tenant_id,name,type,is_active,max_shooters,booking_step_minutes,currency_code,resource_kind,whole_lane_bookable,positions_bookable)
  values(lane,tenant,'Privacy Lane','test',true,2,60,'PLN','lane',true,false);
  insert into public.lane_pricing_rules(id,lane_id,day_group,min_shooters,max_shooters,label,hourly_price)values(price,lane,'mon_thu',1,2,'Privacy Price',10);
  insert into public.reservations(id,tenant_id,user_id,lane_id,customer_name,customer_email,customer_phone,reservation_date,start_time,end_time,duration_minutes,price,reservation_status,payment_status,attendance_status,shooters_count,pricing_rule_id,pricing_day_group_snapshot,lane_name_snapshot,pricing_label_snapshot,price_per_hour_snapshot,total_price,currency_code,creation_request_id,check_in_token,reservation_note)
  values(case when tenant=a then ra else rb end,tenant,u,lane,'Privacy Own','own@example.invalid','500111222',current_date+10,'10:00','11:00',60,10,'confirmed','pay_on_site','planned',1,price,'mon_thu','Privacy Lane','Privacy Price',10,10,'PLN',gen_random_uuid(),token,'Own reservation note');
  token:=gen_random_uuid();
  if tenant=b then
   insert into public.reservations(id,tenant_id,user_id,lane_id,customer_name,customer_email,customer_phone,reservation_date,start_time,end_time,duration_minutes,price,reservation_status,payment_status,attendance_status,shooters_count,pricing_rule_id,pricing_day_group_snapshot,lane_name_snapshot,pricing_label_snapshot,price_per_hour_snapshot,total_price,currency_code,creation_request_id)
   values(rf,b,f,lane,'FOREIGN_PRIVATE_PERSON','foreign@example.invalid','500999888',current_date+10,'12:00','13:00',60,10,'confirmed','pay_on_site','planned',1,price,'mon_thu','Privacy Lane','Privacy Price',10,10,'PLN',gen_random_uuid());
  end if;
 end loop;
 insert into public.event_registrations(id,tenant_id,event_id,user_id,customer_name,customer_email,customer_phone,registration_status,payment_status,promotion_token,created_at)
 values(ga,a,ea,u,'Privacy Own','own@example.invalid','500111222','registered','pay_on_site','NEVER_PROMOTION_SECRET',now()),
 (gb,b,eb,u,'Privacy Own','own@example.invalid','500111222','registered','pay_on_site',null,now()),
 (gn,a,null,u,'Privacy Own','own@example.invalid','500111222','registered','pay_on_site',null,now()),
 (gf,b,eb,f,'FOREIGN_PRIVATE_PERSON','foreign@example.invalid','500999888','registered','pay_on_site',null,now());
 result:=pg_temp.privacy_actor(u,format('select public.set_event_registration_attendance_v1(%L,''present'',0)',gf));
 if result->>'attendance_status' is distinct from 'present' then raise exception 'Attendance fixture failed: %',result;end if;
 result:=pg_temp.privacy_actor(u,format('select public.set_event_registration_attendance_v1(%L,''no_show'',0)',gb));
 insert into public.email_deliveries(tenant_id,message_type,record_id,recipient_user_id,sent_at,provider_message_id,claim_id,claim_expires_at)
 values(a,'reservation_confirmation',ra,u,now(),'NEVER_PROVIDER_SECRET',token,now()+interval '1 hour'),
 (b,'reservation_confirmation',rf,f,now(),'FOREIGN_DELIVERY',null,null);
 insert into public.reminder_occurrences(message_type,schedule_id,reservation_id,registration_id,generation,scheduled_start)
 select 'booking_reminder_24h',id,reservation_id,null,generation,scheduled_start from public.reminder_schedules where reservation_id in(ra,rb,rf);
 insert into public.reminder_occurrences(message_type,schedule_id,reservation_id,registration_id,generation,scheduled_start)
 select 'event_reminder_24h',s.id,null,g.id,s.generation,s.scheduled_start from public.reminder_schedules s join public.event_registrations g on g.event_id=s.event_id where g.id in(ga,gb,gf);
 insert into public.external_settlement_records(id,tenant_id,reservation_id,actor_user_id,idempotency_key,kind,amount,currency,external_reference)
 values(settlement,a,ra,u,gen_random_uuid(),'external_refund',10,'PLN','NEVER_EXTERNAL_REFERENCE'),
 (sforeign,b,rf,staff,gen_random_uuid(),'external_refund',10,'PLN','FOREIGN_EXTERNAL_REFERENCE');
 perform public.operator_bootstrap_platform_admin_v1(u);
 insert into public.platform_audit_logs(actor_user_id,tenant_id,action,details)
 values(u,a,'tenant_created',jsonb_build_object('user_id',f,'email','foreign@example.invalid','phone','500999888','secret','NEVER_AUDIT_SECRET')),
 (staff,b,'tenant_created',jsonb_build_object('user_id',f,'email','foreign@example.invalid'));
 insert into public.audit_logs(actor_user_id,action,target_type,target_id,details)
 values(u,'foreign@example.invalid','account',u,jsonb_build_object('user_id',u,'email','own@example.invalid','phone','500111222','foreign_email','foreign@example.invalid','secret','NEVER_AUDIT_SECRET'));
 insert into public.tenant_domains(id,tenant_id,hostname,domain_type,status,is_primary,verification_hash,verification_requested_by,verified_at)
 values(d,b,'privacy-own-'||b||'.test','custom_domain','active',true,'NEVER_DOMAIN_SECRET',u,now()),
 (df,a,'privacy-foreign-'||a||'.test','custom_domain','verified',false,null,f,now());
 return jsonb_build_object('subject',u,'foreign',f,'last',last_admin,'ordinary',ordinary,'staff',staff,'a',a,'b',b,'c',c,'ea',ea,'eb',eb,'ra',ra,'rb',rb,'rf',rf,'ga',ga,'gb',gb,'gn',gn,'gf',gf,'domain',d,'foreign_domain',df,'settlement',settlement,'foreign_settlement',sforeign);
end;$$;
-- END privacy fixture helpers
create temporary table privacy_results(n serial,label text) on commit drop;
create function pg_temp.privacy_ok(label text,passed boolean) returns void language plpgsql as $$begin
 if passed is distinct from true then raise exception 'Privacy V3 assertion: %',label;end if;
 insert into privacy_results(label) values(label);end;$$;
do $$
declare u uuid:=gen_random_uuid();f uuid:=gen_random_uuid();l uuid:=gen_random_uuid();o uuid:=gen_random_uuid();s uuid:=gen_random_uuid();
 ids jsonb;v jsonb;v2 jsonb;before_domain jsonb;before_foreign jsonb;before_attendance jsonb;before_settlement jsonb;result jsonb;k text;event_deleted boolean;
begin
 insert into auth.users(id,email,email_confirmed_at,is_anonymous,created_at,updated_at)
 select x,x||'@example.invalid',now(),false,now(),now() from unnest(array[u,f,l,o,s])x;
 ids:=pg_temp.privacy_fixture(u,f,l,o,s);
 v:=pg_temp.privacy_actor(u,'select public.export_my_data_v3()');
 perform pg_temp.privacy_ok('export version 3',v->>'export_version'='3');
 perform pg_temp.privacy_ok('own A/B reservations complete',jsonb_array_length(v->'reservations')=2);
 perform pg_temp.privacy_ok('normal and nullable registrations complete',jsonb_array_length(v->'event_registrations')=3);
 perform pg_temp.privacy_ok('null event retains authoritative registration tenant',exists(select 1 from jsonb_array_elements(v->'event_registrations')r where r->>'id'=ids->>'gn' and r->'event'='null'::jsonb and r#>>'{tenant,id}'=ids->>'a'));
 perform pg_temp.privacy_ok('normal event context remains',exists(select 1 from jsonb_array_elements(v->'event_registrations')r where r->>'id'=ids->>'gb' and r#>>'{event,id}'=ids->>'eb'));
 perform pg_temp.privacy_ok('attendance metadata included',exists(select 1 from jsonb_array_elements(v->'event_registrations')r where r->>'id'=ids->>'gb' and r->>'attendance_status'='no_show' and r->>'attendance_version'='1'));
 perform pg_temp.privacy_ok('instructor and actor history included',jsonb_array_length(v->'event_instructors')=2);
 perform pg_temp.privacy_ok('delivery metadata included',jsonb_array_length(v->'email_deliveries')>=2);
 perform pg_temp.privacy_ok('reminder own resource histories included',jsonb_array_length(v->'reminder_schedules')=4 and jsonb_array_length(v->'reminder_occurrences')=4);
 perform pg_temp.privacy_ok('platform global plus tenant audit included',jsonb_array_length(v->'platform_audit_history')=2 and exists(select 1 from jsonb_array_elements(v->'platform_audit_history')r where r->>'action'='platform_admin_bootstrapped' and r->'tenant'='null'::jsonb));
 perform pg_temp.privacy_ok('settlement and own domain included',jsonb_array_length(v->'external_settlements')=1 and jsonb_array_length(v->'tenant_domain_requests')=1);
 perform pg_temp.privacy_ok('own multi tenant relationships',jsonb_array_length(v->'tenant_relationships')=2);
 perform pg_temp.privacy_ok('no foreign PII or UUID',v::text not like '%foreign@example.invalid%' and v::text not like '%500999888%' and v::text not like '%FOREIGN_PRIVATE_PERSON%' and v::text not like '%'||f::text||'%' and v::text not like '%'||(ids->>'rf')||'%' and v::text not like '%'||(ids->>'gf')||'%');
 perform pg_temp.privacy_ok('no arbitrary audit action or details',not exists(select 1 from jsonb_array_elements(v->'audit_history')r where r ? 'action' or r ? 'details'));
 foreach k in array array['promotion_token','check_in_token','recovery_token','confirmation_token','encrypted_password','claim_id','claim_expires_at','provider_message_id','service_key','details','external_reference'] loop
  perform pg_temp.privacy_ok('secret key excluded '||k,v::text !~ ('"'||k||'"[[:space:]]*:'));
 end loop;
 perform pg_temp.privacy_ok('secret values excluded',v::text not like '%NEVER_%' and v::text not like '%8edbee00-0000-4000-8000-000000000001%');
 perform pg_temp.privacy_ok('legacy export unchanged',pg_temp.privacy_actor(u,'select public.export_my_data_v1()')->>'export_version'='2');
 begin
  delete from public.events where id=(ids->>'ea')::uuid;
  v2:=pg_temp.privacy_actor(u,'select public.export_my_data_v3()');
  event_deleted:=not exists(select 1 from public.event_registrations where id=(ids->>'ga')::uuid) and exists(select 1 from jsonb_array_elements(v2->'event_registrations')r where r->>'id'=ids->>'gn');
  raise exception 'rollback deletion probe' using errcode='P1001';
 exception when sqlstate 'P1001' then null;end;
 perform pg_temp.privacy_ok('event deletion follows actual cascade; independent null registration remains',event_deleted);
 begin
  insert into public.audit_logs(actor_user_id,action,target_type,target_id)select u,'capacity','account',u from generate_series(1,10001);
  perform pg_temp.privacy_actor(u,'select public.export_my_data_v3()');raise exception 'row cap failed';
 exception when sqlstate '54000' then perform pg_temp.privacy_ok('row cap explicit 54000',true);end;
 begin
  update public.profiles set full_name=repeat('x',2097153) where user_id=u;
  perform pg_temp.privacy_actor(u,'select public.export_my_data_v3()');raise exception 'byte cap failed';
 exception when sqlstate '54000' then perform pg_temp.privacy_ok('byte cap explicit 54000',true);end;
 begin
  perform pg_temp.privacy_actor(l,'select public.anonymize_my_account_v1()');raise exception 'last admin allowed';
 exception when check_violation then perform pg_temp.privacy_ok('last admin denied before mutation',exists(select 1 from public.profiles where user_id=l));end;
 select to_jsonb(d) into before_domain from public.tenant_domains d where id=(ids->>'domain')::uuid;
 select to_jsonb(r) into before_foreign from public.reservations r where id=(ids->>'rf')::uuid;
 select to_jsonb(r) into before_attendance from public.event_registrations r where id=(ids->>'gf')::uuid;
 select to_jsonb(r) into before_settlement from public.external_settlement_records r where id=(ids->>'settlement')::uuid;
 update public.tenants set status='suspended' where id=(ids->>'b')::uuid;
 result:=pg_temp.privacy_actor(u,'select public.anonymize_my_account_v1()');
 perform pg_temp.privacy_ok('canonical multi tenant cleanup',result->>'ok'='true');
 perform pg_temp.privacy_ok('canonical retry idempotent',pg_temp.privacy_actor(u,'select public.anonymize_my_account_v1()')->>'code'='already_anonymized');
 delete from auth.users where id=u;
 perform pg_temp.privacy_ok('requester null and full domain unchanged',(select verification_requested_by is null and to_jsonb(d)-'verification_requested_by'=before_domain-'verification_requested_by' from public.tenant_domains d where id=(ids->>'domain')::uuid));
 perform pg_temp.privacy_ok('other reservation unchanged',(select to_jsonb(r)=before_foreign from public.reservations r where id=(ids->>'rf')::uuid));
 perform pg_temp.privacy_ok('attendance actor null; status time version preserved',(select attendance_marked_by is null and to_jsonb(r)-'attendance_marked_by'=before_attendance-'attendance_marked_by' from public.event_registrations r where id=(ids->>'gf')::uuid));
 perform pg_temp.privacy_ok('instructor and own actor references null; history retained',(select count(*)=2 from public.event_instructors where event_id in((ids->>'ea')::uuid,(ids->>'eb')::uuid)) and not exists(select 1 from public.event_instructors where instructor_user_id=u or assigned_by=u or unassigned_by=u));
 perform pg_temp.privacy_ok('own deliveries removed; foreign preserved',not exists(select 1 from public.email_deliveries where recipient_user_id=u) and exists(select 1 from public.email_deliveries where recipient_user_id=f));
 perform pg_temp.privacy_ok('settlement pseudonym and reference redacted; business retained',(select actor_user_id<>u and external_reference='[redacted]' and to_jsonb(r)-array['actor_user_id','external_reference']=before_settlement-array['actor_user_id','external_reference'] from public.external_settlement_records r where id=(ids->>'settlement')::uuid));
 perform pg_temp.privacy_ok('selected audit IDs cleaned',not exists(select 1 from public.audit_logs where actor_user_id=u or target_id=u or details->>'user_id'=u::text) and not exists(select 1 from public.platform_audit_logs where actor_user_id=u or details->>'user_id'=u::text));
 perform pg_temp.privacy_ok('resource based reminder history retained',exists(select 1 from public.reminder_schedules where reservation_id=(ids->>'ra')::uuid) and exists(select 1 from public.reminder_occurrences where reservation_id=(ids->>'ra')::uuid));
 perform pg_temp.privacy_ok('profile memberships and Auth gone',not exists(select 1 from auth.users where id=u) and not exists(select 1 from public.profiles where user_id=u) and not exists(select 1 from public.tenant_memberships where user_id=u));
end;$$;
select 'ok '||n||' - '||label from privacy_results order by n;
select '1..'||count(*) from privacy_results;
rollback;
