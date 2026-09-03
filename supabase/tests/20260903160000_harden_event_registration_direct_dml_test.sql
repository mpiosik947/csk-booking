\set ON_ERROR_STOP on
\pset format unaligned

select '1..27';

begin;

create temporary table test_results(
  test_order integer primary key,
  test_name text not null,
  passed boolean not null,
  result text not null
) on commit drop;

create function pg_temp.record_result(integer,text,boolean,text)
returns void language sql as $function$
  insert into pg_temp.test_results values($1,$2,coalesce($3,false),$4);
$function$;

create function pg_temp.set_client(p_role text,p_user_id uuid)
returns void language plpgsql as $function$
begin
  perform pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object('sub',p_user_id,'role',p_role)::text,true
  );
  perform pg_catalog.set_config('request.jwt.claim.sub',coalesce(p_user_id::text,''),true);
  execute pg_catalog.format('set local role %I',p_role);
end;
$function$;

create function pg_temp.direct_dml_denied(p_role text,p_user_id uuid,p_operation text,p_registration_id uuid,p_event_id uuid)
returns boolean language plpgsql as $function$
begin
  perform pg_temp.set_client(p_role,p_user_id);
  if p_operation='insert' then
    insert into public.event_registrations(
      id,event_id,user_id,customer_name,customer_email,customer_phone,
      registration_status,payment_status,created_at,promotion_token
    ) values(
      pg_catalog.gen_random_uuid(),p_event_id,p_user_id,'[TEST] forged',
      'sec018-forged@example.invalid','000','approved','paid_on_site',
      timestamptz '2000-01-01 00:00:00+00','forged-secret-token'
    );
  elsif p_operation='update' then
    update public.event_registrations
    set user_id=p_user_id,event_id=p_event_id,registration_status='approved',
        payment_status='paid_on_site',promotion_token='forged-secret-token',
        created_at=timestamptz '2000-01-01 00:00:00+00'
    where id=p_registration_id;
  elsif p_operation='delete' then
    delete from public.event_registrations where id=p_registration_id;
  else
    raise exception 'Unknown test operation';
  end if;
  execute 'reset role';
  return false;
exception when insufficient_privilege then
  execute 'reset role';
  return true;
end;
$function$;

create function pg_temp.call_payment(p_user_id uuid,p_registration_id uuid)
returns jsonb language plpgsql as $function$
declare v_result jsonb;
begin
  perform pg_temp.set_client('authenticated',p_user_id);
  select public.mark_event_registration_paid(p_registration_id) into v_result;
  execute 'reset role';
  return v_result;
exception when others then
  execute 'reset role';
  raise;
end;
$function$;

create function pg_temp.anon_payment_is_denied(p_registration_id uuid)
returns boolean language plpgsql as $function$
begin
  perform pg_temp.set_client('anon',null);
  perform public.mark_event_registration_paid(p_registration_id);
  execute 'reset role';
  return false;
exception when insufficient_privilege then
  execute 'reset role';
  return true;
end;
$function$;

do $tests$
declare
  v_admin uuid := '7c018000-0000-4000-8000-000000000001';
  v_employee uuid := '7c018000-0000-4000-8000-000000000002';
  v_instructor uuid := '7c018000-0000-4000-8000-000000000003';
  v_user uuid := '7c018000-0000-4000-8000-000000000004';
  v_event uuid := '7c018000-0000-4000-8000-000000000010';
  v_payment_admin uuid := '7c018000-0000-4000-8000-000000000020';
  v_payment_employee uuid := '7c018000-0000-4000-8000-000000000021';
  v_approve uuid := '7c018000-0000-4000-8000-000000000022';
  v_cancel uuid := '7c018000-0000-4000-8000-000000000023';
  v_without_event uuid := '7c018000-0000-4000-8000-000000000024';
  v_result jsonb;
  v_audit_count integer;
  v_denied boolean;
begin
  insert into auth.users(
    id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,
    raw_app_meta_data,raw_user_meta_data,created_at,updated_at
  ) values
    (v_admin,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','sec018-admin@example.invalid','',now(),'{}','{}',now(),now()),
    (v_employee,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','sec018-employee@example.invalid','',now(),'{}','{}',now(),now()),
    (v_instructor,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','sec018-instructor@example.invalid','',now(),'{}','{}',now(),now()),
    (v_user,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','sec018-user@example.invalid','',now(),'{}','{}',now(),now());

  insert into public.profiles(user_id,role,first_name,last_name,full_name,email) values
    (v_admin,'admin','[TEST]','SEC-018 Admin','[TEST][SEC-018] Admin','sec018-admin@example.invalid'),
    (v_employee,'pracownik','[TEST]','SEC-018 Employee','[TEST][SEC-018] Employee','sec018-employee@example.invalid'),
    (v_instructor,'instruktor','[TEST]','SEC-018 Instructor','[TEST][SEC-018] Instructor','sec018-instructor@example.invalid'),
    (v_user,'user','[TEST]','SEC-018 User','[TEST][SEC-018] User','sec018-user@example.invalid');

  insert into public.events(id,title,event_date,start_time,end_time,location,price,max_participants,is_active)
  values(v_event,'[TEST][SEC-018] Event',current_date+100,time '10:00',time '11:00','[TEST]',0,10,true);

  insert into public.event_registrations(
    id,event_id,user_id,customer_name,customer_email,customer_phone,
    registration_status,payment_status
  ) values
    (v_payment_admin,v_event,null,'[TEST] User','sec018-user@example.invalid','000','registered','pay_on_site'),
    (v_payment_employee,v_event,null,'[TEST] User','sec018-user@example.invalid','000','reserve','pending'),
    (v_approve,v_event,null,'[TEST] User','sec018-user@example.invalid','000','registered','pay_on_site'),
    (v_cancel,v_event,null,'[TEST] User','sec018-user@example.invalid','000','registered','pay_on_site'),
    (v_without_event,null,null,'[TEST] Orphan','sec018-orphan@example.invalid','000','registered','pay_on_site');

  perform pg_temp.record_result(1,'event_registrations RLS and owner contract',
    exists(select 1 from pg_catalog.pg_class c join pg_catalog.pg_roles r on r.oid=c.relowner
      where c.oid='public.event_registrations'::regclass and c.relrowsecurity and r.rolname='postgres'),
    'RLS ma być włączone, owner postgres.');

  perform pg_temp.record_result(2,'Only two SELECT policies remain',
    (select count(*)=2 from pg_catalog.pg_policies where schemaname='public' and tablename='event_registrations')
    and not exists(select 1 from pg_catalog.pg_policies where schemaname='public' and tablename='event_registrations' and cmd<>'SELECT'),
    'Polityki mutacyjne muszą zostać usunięte, polityki SELECT zachowane.');

  perform pg_temp.record_result(3,'authenticated table ACL is SELECT-only',
    pg_catalog.has_table_privilege('authenticated','public.event_registrations','SELECT')
    and not pg_catalog.has_table_privilege('authenticated','public.event_registrations','INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN'),
    'authenticated nie może mieć bezpośredniego DML ani praw technicznych.');

  perform pg_temp.record_result(4,'anon and PUBLIC have no table ACL',
    not pg_catalog.has_table_privilege('anon','public.event_registrations','SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN')
    and not exists(select 1 from pg_catalog.pg_class c cross join lateral pg_catalog.aclexplode(coalesce(c.relacl,pg_catalog.acldefault('r',c.relowner))) a where c.oid='public.event_registrations'::regclass and a.grantee=0),
    'anon i PUBLIC nie mogą mieć praw tabelowych.');

  perform pg_temp.record_result(5,'service_role table ACL remains complete',
    pg_catalog.has_table_privilege('service_role','public.event_registrations','SELECT')
    and pg_catalog.has_table_privilege('service_role','public.event_registrations','INSERT')
    and pg_catalog.has_table_privilege('service_role','public.event_registrations','UPDATE')
    and pg_catalog.has_table_privilege('service_role','public.event_registrations','DELETE')
    and pg_catalog.has_table_privilege('service_role','public.event_registrations','TRUNCATE')
    and pg_catalog.has_table_privilege('service_role','public.event_registrations','REFERENCES')
    and pg_catalog.has_table_privilege('service_role','public.event_registrations','TRIGGER')
    and pg_catalog.has_table_privilege('service_role','public.event_registrations','MAINTAIN'),
    'service_role zachowuje dotychczasowy pełny ACL.');

  perform pg_temp.record_result(6,'Payment RPC construction is hardened',
    exists(select 1 from pg_catalog.pg_proc p join pg_catalog.pg_roles r on r.oid=p.proowner
      where p.oid='public.mark_event_registration_paid(uuid)'::regprocedure
        and p.prosecdef and p.provolatile='v' and p.prorettype='jsonb'::regtype
        and p.proconfig=array['search_path=pg_catalog, public, pg_temp']::text[] and r.rolname='postgres'),
    'RPC ma być VOLATILE SECURITY DEFINER, owner postgres, RETURNS jsonb i bezpieczny search_path.');

  perform pg_temp.record_result(7,'Payment RPC ACL is authenticated-only',
    pg_catalog.has_function_privilege('authenticated','public.mark_event_registration_paid(uuid)','EXECUTE')
    and not pg_catalog.has_function_privilege('anon','public.mark_event_registration_paid(uuid)','EXECUTE')
    and not pg_catalog.has_function_privilege('service_role','public.mark_event_registration_paid(uuid)','EXECUTE')
    and not exists(select 1 from pg_catalog.pg_proc p cross join lateral pg_catalog.aclexplode(coalesce(p.proacl,pg_catalog.acldefault('f',p.proowner))) a where p.oid='public.mark_event_registration_paid(uuid)'::regprocedure and a.grantee=0 and a.privilege_type='EXECUTE'),
    'Tylko authenticated otrzymuje EXECUTE.');

  perform pg_temp.record_result(8,'RPC has one minimal uuid parameter',
    (select pronargs=1 and proargtypes='2950'::oidvector from pg_catalog.pg_proc where oid='public.mark_event_registration_paid(uuid)'::regprocedure),
    'Klient przekazuje wyłącznie registration_id.');

  perform pg_temp.record_result(9,'Ordinary user direct foreign INSERT denied',pg_temp.direct_dml_denied('authenticated',v_user,'insert',v_payment_admin,v_event),'INSERT ma zwracać 42501.');
  perform pg_temp.record_result(10,'Ordinary user field-tampering UPDATE denied',pg_temp.direct_dml_denied('authenticated',v_user,'update',v_payment_admin,v_event),'UPDATE pól chronionych ma zwracać 42501.');
  perform pg_temp.record_result(11,'Ordinary user direct foreign DELETE denied',pg_temp.direct_dml_denied('authenticated',v_user,'delete',v_payment_admin,v_event),'DELETE ma zwracać 42501.');
  perform pg_temp.record_result(12,'Employee direct INSERT denied',pg_temp.direct_dml_denied('authenticated',v_employee,'insert',v_payment_admin,v_event),'Staff INSERT ma zwracać 42501.');
  perform pg_temp.record_result(13,'Employee direct UPDATE denied',pg_temp.direct_dml_denied('authenticated',v_employee,'update',v_payment_admin,v_event),'Staff UPDATE ma zwracać 42501.');
  perform pg_temp.record_result(14,'Employee direct DELETE denied',pg_temp.direct_dml_denied('authenticated',v_employee,'delete',v_payment_admin,v_event),'Staff DELETE ma zwracać 42501.');
  perform pg_temp.record_result(15,'Admin direct INSERT denied',pg_temp.direct_dml_denied('authenticated',v_admin,'insert',v_payment_admin,v_event),'Admin INSERT ma zwracać 42501.');
  perform pg_temp.record_result(16,'Admin direct UPDATE denied',pg_temp.direct_dml_denied('authenticated',v_admin,'update',v_payment_admin,v_event),'Admin UPDATE ma zwracać 42501.');
  perform pg_temp.record_result(17,'Admin direct DELETE denied',pg_temp.direct_dml_denied('authenticated',v_admin,'delete',v_payment_admin,v_event),'Admin DELETE ma zwracać 42501.');
  perform pg_temp.record_result(18,'Anon direct mutation denied',pg_temp.direct_dml_denied('anon',null,'delete',v_payment_admin,v_event),'Anon DML ma zwracać 42501.');

  v_result:=pg_temp.call_payment(v_admin,v_payment_admin);
  perform pg_temp.record_result(19,'Admin payment RPC succeeds',v_result@>'{"ok":true,"changed":true,"code":"updated","new_payment_status":"paid_on_site"}'::jsonb and v_result->>'registration_id'=v_payment_admin::text,'Admin wykonuje stałą operację płatności przez RPC.');

  v_result:=pg_temp.call_payment(v_employee,v_payment_employee);
  perform pg_temp.record_result(20,'Employee payment RPC succeeds',v_result@>'{"ok":true,"changed":true,"code":"updated","new_payment_status":"paid_on_site"}'::jsonb and v_result->>'registration_id'=v_payment_employee::text,'Pracownik wykonuje stałą operację płatności przez RPC.');

  select count(*) into v_audit_count from public.audit_logs where action='event_registration_payment_marked_by_staff' and target_id=v_payment_admin;
  v_result:=pg_temp.call_payment(v_admin,v_payment_admin);
  perform pg_temp.record_result(21,'Payment RPC is idempotent',v_result@>'{"ok":true,"changed":false,"code":"no_change"}'::jsonb and (select count(*) from public.audit_logs where action='event_registration_payment_marked_by_staff' and target_id=v_payment_admin)=v_audit_count,'Powtórzenie nie zmienia danych ani nie dodaje auditu.');

  perform pg_temp.record_result(22,'Unauthorized roles are denied by RPC',
    pg_temp.call_payment(v_user,v_payment_admin)@>'{"ok":false,"changed":false,"code":"not_allowed"}'::jsonb
    and pg_temp.call_payment(v_instructor,v_payment_admin)@>'{"ok":false,"changed":false,"code":"not_allowed"}'::jsonb,
    'User i instruktor otrzymują kontrolowane not_allowed.');

  perform pg_temp.record_result(23,'Payment audit is trusted and contains no PII or tokens',
    (select count(*)=2 and bool_and(actor_user_id in(v_admin,v_employee))
      and bool_and((details-'registration_id'-'event_id'-'previous_payment_status'-'new_payment_status'-'operator_role'-'changed_at')='{}'::jsonb)
      and bool_and(details::text !~* 'email|phone|token|customer|jwt|secret')
     from public.audit_logs where action='event_registration_payment_marked_by_staff' and target_id in(v_payment_admin,v_payment_employee)),
    'Każda zmiana tworzy jeden techniczny audit bez PII i sekretów.');

  perform pg_temp.set_client('authenticated',v_admin);
  select public.approve_event_registration(v_approve) into v_result;
  execute 'reset role';
  perform pg_temp.set_client('authenticated',v_employee);
  perform public.cancel_event_registration(v_cancel);
  execute 'reset role';
  perform pg_temp.record_result(24,'Existing controlled status operations remain functional',
    v_result@>'{"ok":true,"changed":true,"code":"updated","new_status":"approved"}'::jsonb
    and (select registration_status='approved' from public.event_registrations where id=v_approve)
    and (select registration_status='cancelled' from public.event_registrations where id=v_cancel),
    'Approve i cancel nadal wykonują kontrolowane przejścia statusów.');

  perform pg_temp.record_result(25,'Missing registration is controlled',
    pg_temp.call_payment(v_admin,'7c018000-0000-4000-8000-000000000099')@>'{"ok":false,"changed":false,"code":"registration_not_found"}'::jsonb,
    'Brak rekordu nie może powodować surowego błędu.');

  perform pg_temp.record_result(26,'Registration without event is controlled',
    pg_temp.call_payment(v_admin,v_without_event)@>'{"ok":false,"changed":false,"code":"event_not_found"}'::jsonb,
    'Brak eventu nie może powodować częściowej mutacji.');

  perform pg_temp.record_result(27,'Anon cannot execute payment RPC',
    pg_temp.anon_payment_is_denied(v_payment_admin),
    'Anon wywołujący RPC otrzymuje SQLSTATE 42501.');
end;
$tests$;

select (case when passed then 'ok ' else 'not ok ' end)||test_order::text||' - '||test_name
  ||case when passed then '' else E'\n# '||result end
from pg_temp.test_results order by test_order;

do $assertions$
declare v_failures text;
begin
  select pg_catalog.string_agg(test_order::text||': '||test_name,', ' order by test_order)
  into v_failures from pg_temp.test_results where passed is false;
  if v_failures is not null then
    raise exception 'SEC-018 tests failed: %',v_failures;
  end if;
end;
$assertions$;

rollback;
