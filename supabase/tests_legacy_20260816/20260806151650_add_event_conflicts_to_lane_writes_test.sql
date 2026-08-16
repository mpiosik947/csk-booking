\set ON_ERROR_STOP on

-- Test przeznaczony wyłącznie do uruchomienia przez psql.
-- Migracja i dane [TEST][5D-3A] są objęte jedną transakcją z ROLLBACK.
begin;

create temporary table baseline_objects (
  object_name text primary key,
  value text not null
) on commit drop;

insert into baseline_objects (object_name, value)
select 'events_policies', pg_catalog.md5(coalesce(pg_catalog.string_agg(
  policyname || '|' || cmd || '|' || roles::text || '|' ||
  coalesce(qual, '<NULL>') || '|' || coalesce(with_check, '<NULL>'),
  E'\n' order by policyname
), ''))
from pg_catalog.pg_policies
where schemaname = 'public' and tablename = 'events';

insert into baseline_objects (object_name, value)
select 'events_acl', pg_catalog.md5(coalesce(relacl::text, '<NULL>'))
from pg_catalog.pg_class
where oid = 'public.events'::pg_catalog.regclass;

insert into baseline_objects (object_name, value)
select 'admin_event_rpc_acl', pg_catalog.md5(pg_catalog.string_agg(
  proname || '|' || coalesce(proacl::text, '<NULL>'),
  E'\n' order by proname
))
from pg_catalog.pg_proc as procedure_record
join pg_catalog.pg_namespace as namespace_record
  on namespace_record.oid = procedure_record.pronamespace
where namespace_record.nspname = 'public'
  and procedure_record.proname in (
    'admin_create_event', 'admin_update_event', 'admin_set_event_active'
  );

insert into baseline_objects (object_name, value)
select 'create_reservation_md5', pg_catalog.md5(pg_catalog.pg_get_functiondef(
  'public.create_reservation(uuid,date,time without time zone,integer,integer,uuid,text)'::pg_catalog.regprocedure
));

insert into baseline_objects (object_name, value)
select 'lock_helper_md5', pg_catalog.md5(pg_catalog.pg_get_functiondef(
  'public.lock_lane_booking_configuration()'::pg_catalog.regprocedure
));

\ir ../migrations/20260806151650_add_event_conflicts_to_lane_writes.sql

create temporary table test_results (
  test_order integer primary key,
  test_name text not null,
  passed boolean not null,
  result text not null
) on commit drop;

create function pg_temp.call_create_reservation(
  p_user_id uuid,
  p_lane_id uuid,
  p_test_date date,
  p_start time without time zone,
  p_duration integer,
  p_request_id uuid
)
returns jsonb
language plpgsql
as $function$
declare
  v_result jsonb;
begin
  perform pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object('sub',p_user_id,'role','authenticated')::text,
    true
  );
  execute 'set local role authenticated';
  select public.create_reservation(
    p_lane_id,p_test_date,p_start,p_duration,1,p_request_id,'[TEST][5D-3A]'
  ) into v_result;
  execute 'reset role';
  return v_result;
exception when others then
  execute 'reset role';
  raise;
end;
$function$;

create function pg_temp.lane_block_action(
  p_user_id uuid,
  p_action text,
  p_block_id uuid,
  p_lane_id uuid,
  p_test_date date
)
returns jsonb
language plpgsql
as $function$
declare
  v_rows integer := 0;
begin
  perform pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object('sub',p_user_id,'role','authenticated')::text,
    true
  );
  execute 'set local role authenticated';

  if p_action = 'insert' then
    insert into public.lane_blocks (
      id,lane_id,block_date,start_time,end_time,reason,is_active
    ) values (
      p_block_id,p_lane_id,p_test_date,time '14:00',time '15:00',
      '[TEST][5D-3A][ROLE]',true
    );
    get diagnostics v_rows = row_count;
  elsif p_action = 'update' then
    update public.lane_blocks
    set reason='[TEST][5D-3A][ROLE-UPDATED]'
    where id=p_block_id;
    get diagnostics v_rows = row_count;
  elsif p_action = 'delete' then
    delete from public.lane_blocks where id=p_block_id;
    get diagnostics v_rows = row_count;
  else
    raise exception 'Unknown test action';
  end if;

  execute 'reset role';
  return pg_catalog.jsonb_build_object('ok',true,'rows',v_rows);
exception when others then
  execute 'reset role';
  return pg_catalog.jsonb_build_object(
    'ok',false,'rows',0,'sqlstate',sqlstate
  );
end;
$function$;

do $contract_tests$
declare
  v_base_date date := current_date + 5000;
  v_admin uuid := pg_catalog.gen_random_uuid();
  v_employee uuid := pg_catalog.gen_random_uuid();
  v_instructor uuid := pg_catalog.gen_random_uuid();
  v_user uuid := pg_catalog.gen_random_uuid();
  v_lane1 uuid := pg_catalog.gen_random_uuid();
  v_lane2 uuid := pg_catalog.gen_random_uuid();
  v_event uuid;
  v_event2 uuid;
  v_block uuid;
  v_block2 uuid;
  v_duration uuid;
  v_pricing_rule uuid;
  v_result jsonb;
  v_result2 jsonb;
  v_first_id uuid;
  v_constraint text;
  v_passed boolean;
  v_count bigint;
begin
  insert into auth.users (
    id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,
    raw_app_meta_data,raw_user_meta_data,created_at,updated_at
  ) values
    (v_admin,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
     '[TEST]-5d3a-admin@example.invalid','',pg_catalog.transaction_timestamp(),
     '{}'::jsonb,'{}'::jsonb,pg_catalog.transaction_timestamp(),pg_catalog.transaction_timestamp()),
    (v_employee,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
     '[TEST]-5d3a-employee@example.invalid','',pg_catalog.transaction_timestamp(),
     '{}'::jsonb,'{}'::jsonb,pg_catalog.transaction_timestamp(),pg_catalog.transaction_timestamp()),
    (v_instructor,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
     '[TEST]-5d3a-instructor@example.invalid','',pg_catalog.transaction_timestamp(),
     '{}'::jsonb,'{}'::jsonb,pg_catalog.transaction_timestamp(),pg_catalog.transaction_timestamp()),
    (v_user,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
     '[TEST]-5d3a-user@example.invalid','',pg_catalog.transaction_timestamp(),
     '{}'::jsonb,'{}'::jsonb,pg_catalog.transaction_timestamp(),pg_catalog.transaction_timestamp());

  update public.profiles
  set role = case user_id
      when v_admin then 'admin'
      when v_employee then 'pracownik'
      when v_instructor then 'instruktor'
      else 'user'
    end,
    first_name='[TEST]',
    last_name='5D-3A',
    full_name='[TEST][5D-3A]',
    email='[TEST]-5d3a@example.invalid',
    phone='000000000',
    verification_status='verified'
  where user_id in (v_admin,v_employee,v_instructor,v_user);

  insert into public.shooting_lanes (
    id,name,type,description,price_per_hour,is_active,max_shooters,
    booking_step_minutes,display_order,currency_code
  ) values
    (v_lane1,'[TEST][5D-3A][LANE-1]','[TEST]','[TEST]',10,true,5,60,981,'PLN'),
    (v_lane2,'[TEST][5D-3A][LANE-2]','[TEST]','[TEST]',10,true,5,60,982,'PLN');

  insert into public.lane_booking_durations (lane_id,duration_minutes,display_order,is_active)
  values
    (v_lane1,60,1,true),
    (v_lane1,120,2,true),
    (v_lane1,240,3,true),
    (v_lane2,60,1,true);

  insert into public.lane_pricing_rules (
    lane_id,day_group,min_shooters,max_shooters,label,hourly_price,display_order,is_active
  ) values
    (v_lane1,'mon_thu',1,5,'[TEST][5D-3A]',10,1,true),
    (v_lane1,'fri_sun',1,5,'[TEST][5D-3A]',10,1,true),
    (v_lane2,'mon_thu',1,5,'[TEST][5D-3A]',10,1,true),
    (v_lane2,'fri_sun',1,5,'[TEST][5D-3A]',10,1,true);

  -- 1. Rezerwacja bez eventu działa.
  v_result := pg_temp.call_create_reservation(
    v_user,v_lane1,v_base_date,time '10:00',60,pg_catalog.gen_random_uuid()
  );
  insert into test_results values (
    1,'Rezerwacja bez eventu działa',
    v_result->>'code'='created',
    'Oczekiwano created.'
  );

  -- 2. Aktywny event na tej samej osi i czasie blokuje.
  insert into public.events (
    title,event_date,start_time,end_time,price,max_participants,is_active
  ) values (
    '[TEST][5D-3A][ACTIVE-SAME]',v_base_date+1,time '10:00',time '12:00',0,5,true
  ) returning id into v_event;
  insert into public.event_lanes values (v_event,v_lane1,pg_catalog.transaction_timestamp());
  v_result := pg_temp.call_create_reservation(
    v_user,v_lane1,v_base_date+1,time '10:00',60,pg_catalog.gen_random_uuid()
  );
  insert into test_results values (
    2,'Aktywny event blokuje rezerwację',
    v_result = '{"ok":false,"changed":false,"code":"slot_unavailable"}'::jsonb,
    'Oczekiwano bezpiecznego slot_unavailable.'
  );

  -- 3. Nieaktywny event nie blokuje.
  insert into public.events (
    title,event_date,start_time,end_time,price,max_participants,is_active
  ) values (
    '[TEST][5D-3A][INACTIVE]',v_base_date+2,time '10:00',time '12:00',0,5,false
  ) returning id into v_event2;
  insert into public.event_lanes values (v_event2,v_lane1,pg_catalog.transaction_timestamp());
  v_result := pg_temp.call_create_reservation(
    v_user,v_lane1,v_base_date+2,time '10:00',60,pg_catalog.gen_random_uuid()
  );
  insert into test_results values (
    3,'Nieaktywny event nie blokuje rezerwacji',v_result->>'code'='created',
    'Oczekiwano created.'
  );

  -- 4. Event na innej osi nie blokuje.
  insert into public.events (
    title,event_date,start_time,end_time,price,max_participants,is_active
  ) values (
    '[TEST][5D-3A][OTHER-LANE]',v_base_date+3,time '10:00',time '12:00',0,5,true
  ) returning id into v_event2;
  insert into public.event_lanes values (v_event2,v_lane2,pg_catalog.transaction_timestamp());
  v_result := pg_temp.call_create_reservation(
    v_user,v_lane1,v_base_date+3,time '10:00',60,pg_catalog.gen_random_uuid()
  );
  insert into test_results values (
    4,'Event na innej osi nie blokuje rezerwacji',v_result->>'code'='created',
    'Oczekiwano created.'
  );

  -- 5. Event globalny nie blokuje.
  insert into public.events (
    title,event_date,start_time,end_time,price,max_participants,is_active
  ) values (
    '[TEST][5D-3A][GLOBAL]',v_base_date+4,time '10:00',time '12:00',0,5,true
  );
  v_result := pg_temp.call_create_reservation(
    v_user,v_lane1,v_base_date+4,time '10:00',60,pg_catalog.gen_random_uuid()
  );
  insert into test_results values (
    5,'Event globalny nie blokuje rezerwacji',v_result->>'code'='created',
    'Brak event_lanes oznacza brak blokady osi.'
  );

  -- 6. Styk godzin jest dozwolony.
  insert into public.events (
    title,event_date,start_time,end_time,price,max_participants,is_active
  ) values (
    '[TEST][5D-3A][TOUCH]',v_base_date+5,time '10:00',time '11:00',0,5,true
  ) returning id into v_event2;
  insert into public.event_lanes values (v_event2,v_lane1,pg_catalog.transaction_timestamp());
  v_result := pg_temp.call_create_reservation(
    v_user,v_lane1,v_base_date+5,time '11:00',60,pg_catalog.gen_random_uuid()
  );
  insert into test_results values (
    6,'Styk godzin rezerwacja-event jest dozwolony',v_result->>'code'='created',
    'Przedziały [10,11) i [11,12) nie kolidują.'
  );

  -- 7. Częściowe nakładanie jest blokowane.
  insert into public.events (
    title,event_date,start_time,end_time,price,max_participants,is_active
  ) values (
    '[TEST][5D-3A][PARTIAL]',v_base_date+6,time '10:00',time '12:00',0,5,true
  ) returning id into v_event2;
  insert into public.event_lanes values (v_event2,v_lane1,pg_catalog.transaction_timestamp());
  v_result := pg_temp.call_create_reservation(
    v_user,v_lane1,v_base_date+6,time '11:00',60,pg_catalog.gen_random_uuid()
  );
  insert into test_results values (
    7,'Częściowe nakładanie rezerwacji z eventem jest blokowane',
    v_result->>'code'='slot_unavailable','Oczekiwano slot_unavailable.'
  );

  -- 8. Pełne zawarcie eventu jest blokowane.
  insert into public.events (
    title,event_date,start_time,end_time,price,max_participants,is_active
  ) values (
    '[TEST][5D-3A][CONTAINED]',v_base_date+7,time '10:00',time '12:00',0,5,true
  ) returning id into v_event2;
  insert into public.event_lanes values (v_event2,v_lane1,pg_catalog.transaction_timestamp());
  v_result := pg_temp.call_create_reservation(
    v_user,v_lane1,v_base_date+7,time '09:00',240,pg_catalog.gen_random_uuid()
  );
  insert into test_results values (
    8,'Pełne zawarcie eventu jest blokowane',
    v_result->>'code'='slot_unavailable','Oczekiwano slot_unavailable.'
  );

  -- 9. Event wieloosiowy blokuje każdą przypisaną oś.
  insert into public.events (
    title,event_date,start_time,end_time,price,max_participants,is_active
  ) values (
    '[TEST][5D-3A][MULTI]',v_base_date+8,time '10:00',time '12:00',0,5,true
  ) returning id into v_event2;
  insert into public.event_lanes values
    (v_event2,v_lane1,pg_catalog.transaction_timestamp()),
    (v_event2,v_lane2,pg_catalog.transaction_timestamp());
  v_result := pg_temp.call_create_reservation(
    v_user,v_lane1,v_base_date+8,time '10:00',60,pg_catalog.gen_random_uuid()
  );
  v_result2 := pg_temp.call_create_reservation(
    v_user,v_lane2,v_base_date+8,time '10:00',60,pg_catalog.gen_random_uuid()
  );
  insert into test_results values (
    9,'Event wieloosiowy blokuje każdą przypisaną oś',
    v_result->>'code'='slot_unavailable' and v_result2->>'code'='slot_unavailable',
    'Obie osie powinny być niedostępne.'
  );

  -- 10. Kontrakt konfliktu nie ujawnia szczegółów.
  insert into test_results values (
    10,'Konflikt rezerwacji nie ujawnia PII ani eventu',
    (select pg_catalog.array_agg(key order by key)=array['changed','code','ok']::text[]
     from pg_catalog.jsonb_object_keys(v_result) as key)
    and v_result::text !~* 'event_id|title|location|customer|email|phone',
    'Oczekiwano wyłącznie ok, changed i code.'
  );

  -- 11. Idempotency pozostaje niezmienione.
  v_result := pg_temp.call_create_reservation(
    v_user,v_lane1,v_base_date+9,time '10:00',60,
    '11111111-1111-4111-8111-111111111111'::uuid
  );
  v_first_id := (v_result->>'reservation_id')::uuid;
  v_result2 := pg_temp.call_create_reservation(
    v_user,v_lane1,v_base_date+9,time '10:00',60,
    '11111111-1111-4111-8111-111111111111'::uuid
  );
  insert into test_results values (
    11,'Idempotency create_reservation działa',
    v_result->>'code'='created'
      and v_result2->>'code'='already_created'
      and (v_result2->>'reservation_id')::uuid=v_first_id,
    'Drugie identyczne wywołanie powinno zwrócić ten sam rekord.'
  );

  -- Kolejne scenariusze izolują konflikt lane_block-event od rezerwacji
  -- utworzonych przez kontrole 3-6 i 11.
  delete from public.reservations
  where reservation_note = '[TEST][5D-3A]';

  -- 12. Aktywna blokada bez eventu działa.
  insert into public.lane_blocks (
    lane_id,block_date,start_time,end_time,reason,is_active
  ) values (
    v_lane1,v_base_date+20,time '10:00',time '11:00','[TEST][5D-3A][NO-EVENT]',true
  );
  insert into test_results values (
    12,'Aktywna blokada bez eventu działa',true,'INSERT zakończony.'
  );

  -- 13. Aktywny event blokuje INSERT lane_block.
  v_constraint := null;
  begin
    insert into public.lane_blocks (
      lane_id,block_date,start_time,end_time,reason,is_active
    ) values (
      v_lane1,v_base_date+1,time '10:30',time '11:30','[TEST][5D-3A][CONFLICT]',true
    );
  exception when exclusion_violation then
    get stacked diagnostics v_constraint=constraint_name;
  end;
  insert into test_results values (
    13,'Aktywny event blokuje INSERT lane_block',
    v_constraint='lane_blocks_no_active_event_overlap',
    'Oczekiwano SQLSTATE 23P01 i stabilnego constraint name.'
  );

  -- 14. Aktywny event blokuje UPDATE terminu.
  insert into public.lane_blocks (
    id,lane_id,block_date,start_time,end_time,reason,is_active
  ) values (
    pg_catalog.gen_random_uuid(),v_lane1,v_base_date+21,time '10:00',time '11:00',
    '[TEST][5D-3A][UPDATE]',true
  ) returning id into v_block;
  v_constraint := null;
  begin
    update public.lane_blocks set block_date=v_base_date+1,
      start_time=time '10:30',end_time=time '11:30' where id=v_block;
  exception when exclusion_violation then
    get stacked diagnostics v_constraint=constraint_name;
  end;
  insert into test_results values (
    14,'Aktywny event blokuje UPDATE lane_block',
    v_constraint='lane_blocks_no_active_event_overlap'
      and exists(select 1 from public.lane_blocks where id=v_block and block_date=v_base_date+21),
    'Nieudany UPDATE nie może zmienić rekordu.'
  );

  -- 15. Aktywny event blokuje ponowną aktywację.
  insert into public.lane_blocks (
    id,lane_id,block_date,start_time,end_time,reason,is_active
  ) values (
    pg_catalog.gen_random_uuid(),v_lane1,v_base_date+1,time '10:30',time '11:30',
    '[TEST][5D-3A][REACTIVATE]',false
  ) returning id into v_block2;
  v_constraint := null;
  begin
    update public.lane_blocks set is_active=true where id=v_block2;
  exception when exclusion_violation then
    get stacked diagnostics v_constraint=constraint_name;
  end;
  insert into test_results values (
    15,'Aktywny event blokuje reaktywację lane_block',
    v_constraint='lane_blocks_no_active_event_overlap'
      and exists(select 1 from public.lane_blocks where id=v_block2 and not is_active),
    'Blokada powinna pozostać nieaktywna.'
  );

  -- 16. Nieaktywny event nie blokuje lane_block.
  insert into public.lane_blocks (
    lane_id,block_date,start_time,end_time,reason,is_active
  ) values (
    v_lane1,v_base_date+2,time '10:30',time '11:30','[TEST][5D-3A][INACTIVE-EVENT]',true
  );
  insert into test_results values (
    16,'Nieaktywny event nie blokuje lane_block',true,'INSERT zakończony.'
  );

  -- 17. Event na innej osi nie blokuje lane_block.
  insert into public.lane_blocks (
    lane_id,block_date,start_time,end_time,reason,is_active
  ) values (
    v_lane1,v_base_date+3,time '10:30',time '11:30','[TEST][5D-3A][OTHER-LANE]',true
  );
  insert into test_results values (
    17,'Event na innej osi nie blokuje lane_block',true,'INSERT zakończony.'
  );

  -- 18. Event globalny nie blokuje lane_block.
  insert into public.lane_blocks (
    lane_id,block_date,start_time,end_time,reason,is_active
  ) values (
    v_lane1,v_base_date+4,time '10:30',time '11:30','[TEST][5D-3A][GLOBAL]',true
  );
  insert into test_results values (
    18,'Event globalny nie blokuje lane_block',true,'INSERT zakończony.'
  );

  -- 19. Styk godzin lane_block-event jest dozwolony.
  insert into public.lane_blocks (
    lane_id,block_date,start_time,end_time,reason,is_active
  ) values (
    v_lane1,v_base_date+5,time '11:00',time '12:00','[TEST][5D-3A][TOUCH]',true
  );
  insert into test_results values (
    19,'Styk godzin lane_block-event jest dozwolony',true,
    'Przedziały stykające się końcem nie kolidują.'
  );

  -- 20. Częściowe nakładanie lane_block-event jest blokowane.
  v_constraint := null;
  begin
    insert into public.lane_blocks (
      lane_id,block_date,start_time,end_time,reason,is_active
    ) values (
      v_lane1,v_base_date+6,time '11:00',time '13:00','[TEST][5D-3A][PARTIAL]',true
    );
  exception when exclusion_violation then
    get stacked diagnostics v_constraint=constraint_name;
  end;
  insert into test_results values (
    20,'Częściowe nakładanie lane_block-event jest blokowane',
    v_constraint='lane_blocks_no_active_event_overlap','Oczekiwano 23P01.'
  );

  -- 21. Pełne zawarcie eventu przez blokadę jest blokowane.
  v_constraint := null;
  begin
    insert into public.lane_blocks (
      lane_id,block_date,start_time,end_time,reason,is_active
    ) values (
      v_lane1,v_base_date+7,time '09:00',time '13:00','[TEST][5D-3A][CONTAINED]',true
    );
  exception when exclusion_violation then
    get stacked diagnostics v_constraint=constraint_name;
  end;
  insert into test_results values (
    21,'Pełne zawarcie eventu przez lane_block jest blokowane',
    v_constraint='lane_blocks_no_active_event_overlap','Oczekiwano 23P01.'
  );

  -- 22. Dezaktywacja lane_block jest dozwolona nawet przy późniejszym konflikcie.
  insert into public.lane_blocks (
    id,lane_id,block_date,start_time,end_time,reason,is_active
  ) values (
    pg_catalog.gen_random_uuid(),v_lane1,v_base_date+22,time '10:00',time '11:00',
    '[TEST][5D-3A][DEACTIVATE]',true
  ) returning id into v_block;
  insert into public.events (
    title,event_date,start_time,end_time,price,max_participants,is_active
  ) values (
    '[TEST][5D-3A][AFTER-BLOCK]',v_base_date+22,time '10:00',time '11:00',0,5,true
  ) returning id into v_event2;
  insert into public.event_lanes values (v_event2,v_lane1,pg_catalog.transaction_timestamp());
  update public.lane_blocks set is_active=false where id=v_block;
  insert into test_results values (
    22,'Dezaktywacja lane_block jest dozwolona',
    exists(select 1 from public.lane_blocks where id=v_block and not is_active),
    'Nieaktywna NEW nie uruchamia kontroli konfliktu.'
  );

  -- 23. DELETE lane_block jest dozwolony.
  insert into public.lane_blocks (
    id,lane_id,block_date,start_time,end_time,reason,is_active
  ) values (
    pg_catalog.gen_random_uuid(),v_lane1,v_base_date+23,time '10:00',time '11:00',
    '[TEST][5D-3A][DELETE]',true
  ) returning id into v_block;
  delete from public.lane_blocks where id=v_block;
  insert into test_results values (
    23,'DELETE lane_block jest dozwolony',
    not exists(select 1 from public.lane_blocks where id=v_block),
    'Trigger powinien zwrócić OLD bez kontroli eventu.'
  );

  -- 24-26. Admin może INSERT/UPDATE/DELETE.
  v_block := pg_catalog.gen_random_uuid();
  v_result := pg_temp.lane_block_action(v_admin,'insert',v_block,v_lane1,v_base_date+30);
  insert into test_results values (24,'Admin może INSERT lane_block',
    (v_result->>'ok')::boolean and (v_result->>'rows')::integer=1,'Oczekiwano jednego wiersza.');
  v_result := pg_temp.lane_block_action(v_admin,'update',v_block,v_lane1,v_base_date+30);
  insert into test_results values (25,'Admin może UPDATE lane_block',
    (v_result->>'ok')::boolean and (v_result->>'rows')::integer=1,'Oczekiwano jednego wiersza.');
  v_result := pg_temp.lane_block_action(v_admin,'delete',v_block,v_lane1,v_base_date+30);
  insert into test_results values (26,'Admin może DELETE lane_block',
    (v_result->>'ok')::boolean and (v_result->>'rows')::integer=1,'Oczekiwano jednego wiersza.');

  -- 27-29. Pracownik może INSERT/UPDATE/DELETE.
  v_block := pg_catalog.gen_random_uuid();
  v_result := pg_temp.lane_block_action(v_employee,'insert',v_block,v_lane1,v_base_date+31);
  insert into test_results values (27,'Pracownik może INSERT lane_block',
    (v_result->>'ok')::boolean and (v_result->>'rows')::integer=1,'Oczekiwano jednego wiersza.');
  v_result := pg_temp.lane_block_action(v_employee,'update',v_block,v_lane1,v_base_date+31);
  insert into test_results values (28,'Pracownik może UPDATE lane_block',
    (v_result->>'ok')::boolean and (v_result->>'rows')::integer=1,'Oczekiwano jednego wiersza.');
  v_result := pg_temp.lane_block_action(v_employee,'delete',v_block,v_lane1,v_base_date+31);
  insert into test_results values (29,'Pracownik może DELETE lane_block',
    (v_result->>'ok')::boolean and (v_result->>'rows')::integer=1,'Oczekiwano jednego wiersza.');

  -- 30-32. Instruktor nie może mutować.
  v_block := pg_catalog.gen_random_uuid();
  v_result := pg_temp.lane_block_action(v_instructor,'insert',v_block,v_lane1,v_base_date+32);
  insert into test_results values (30,'Instruktor nie może INSERT lane_block',
    not (v_result->>'ok')::boolean and v_result->>'sqlstate'='42501','Oczekiwano RLS 42501.');
  insert into public.lane_blocks (
    id,lane_id,block_date,start_time,end_time,reason,is_active
  ) values (v_block,v_lane1,v_base_date+32,time '14:00',time '15:00','[TEST][5D-3A][INSTRUCTOR]',true);
  v_result := pg_temp.lane_block_action(v_instructor,'update',v_block,v_lane1,v_base_date+32);
  insert into test_results values (31,'Instruktor nie może UPDATE lane_block',
    (v_result->>'ok')::boolean and (v_result->>'rows')::integer=0,'Oczekiwano 0 wierszy.');
  v_result := pg_temp.lane_block_action(v_instructor,'delete',v_block,v_lane1,v_base_date+32);
  insert into test_results values (32,'Instruktor nie może DELETE lane_block',
    (v_result->>'ok')::boolean and (v_result->>'rows')::integer=0,'Oczekiwano 0 wierszy.');

  -- 33. User nie może żadnej mutacji.
  v_block2 := pg_catalog.gen_random_uuid();
  v_result := pg_temp.lane_block_action(v_user,'insert',v_block2,v_lane1,v_base_date+33);
  v_passed := not (v_result->>'ok')::boolean and v_result->>'sqlstate'='42501';
  v_result := pg_temp.lane_block_action(v_user,'update',v_block,v_lane1,v_base_date+32);
  v_passed := v_passed and (v_result->>'ok')::boolean and (v_result->>'rows')::integer=0;
  v_result := pg_temp.lane_block_action(v_user,'delete',v_block,v_lane1,v_base_date+32);
  insert into test_results values (33,'User nie może mutować lane_blocks',
    v_passed and (v_result->>'ok')::boolean and (v_result->>'rows')::integer=0,
    'INSERT odrzucony, UPDATE i DELETE nie widzą wiersza.');

  -- 34. anon i PUBLIC nie mają tabelowych praw mutacyjnych.
  select not pg_catalog.has_table_privilege('anon','public.lane_blocks','INSERT')
    and not pg_catalog.has_table_privilege('anon','public.lane_blocks','UPDATE')
    and not pg_catalog.has_table_privilege('anon','public.lane_blocks','DELETE')
    and not pg_catalog.has_table_privilege('anon','public.lane_blocks','TRUNCATE')
    and not exists (
      select 1
      from pg_catalog.aclexplode(
        coalesce(
          (select relacl from pg_catalog.pg_class
           where oid='public.lane_blocks'::pg_catalog.regclass),
          pg_catalog.acldefault('r',(
            select relowner from pg_catalog.pg_class
            where oid='public.lane_blocks'::pg_catalog.regclass
          ))
        )
      ) as acl
      where acl.grantee=0
        and acl.privilege_type in ('INSERT','UPDATE','DELETE','TRUNCATE')
    )
  into v_passed;
  insert into test_results values (
    34,'anon i PUBLIC bez praw mutacyjnych lane_blocks',v_passed,
    'Sprawdzono ACL INSERT, UPDATE, DELETE i TRUNCATE.'
  );

  -- 35. Aktywna lane_block nadal blokuje create_reservation.
  insert into public.lane_blocks (
    lane_id,block_date,start_time,end_time,reason,is_active
  ) values (
    v_lane1,v_base_date+40,time '10:00',time '11:00','[TEST][5D-3A][ACTIVE-BLOCK]',true
  );
  v_result := pg_temp.call_create_reservation(
    v_user,v_lane1,v_base_date+40,time '10:00',60,pg_catalog.gen_random_uuid()
  );
  insert into test_results values (
    35,'Aktywna lane_block nadal blokuje create_reservation',
    v_result->>'code'='lane_blocked','Oczekiwano lane_blocked.'
  );

  -- 36. Nieaktywna lane_block nie blokuje create_reservation.
  insert into public.lane_blocks (
    lane_id,block_date,start_time,end_time,reason,is_active
  ) values (
    v_lane1,v_base_date+41,time '10:00',time '11:00','[TEST][5D-3A][INACTIVE-BLOCK]',false
  );
  v_result := pg_temp.call_create_reservation(
    v_user,v_lane1,v_base_date+41,time '10:00',60,pg_catalog.gen_random_uuid()
  );
  insert into test_results values (
    36,'Nieaktywna lane_block nie blokuje create_reservation',
    v_result->>'code'='created','Oczekiwano created.'
  );

  -- 37. Konflikt rezerwacja-rezerwacja nadal działa.
  v_result := pg_temp.call_create_reservation(
    v_user,v_lane1,v_base_date+42,time '10:00',60,pg_catalog.gen_random_uuid()
  );
  v_result2 := pg_temp.call_create_reservation(
    v_user,v_lane1,v_base_date+42,time '10:00',60,pg_catalog.gen_random_uuid()
  );
  insert into test_results values (
    37,'Konflikt rezerwacja-rezerwacja nadal działa',
    v_result->>'code'='created' and v_result2->>'code'='slot_unavailable',
    'GiST powinien nadal zwracać kontrolowany slot_unavailable.'
  );

  -- 38. public.events pozostaje identyczne.
  select
    (select value from baseline_objects where object_name='events_acl') =
      (select pg_catalog.md5(coalesce(relacl::text,'<NULL>'))
       from pg_catalog.pg_class where oid='public.events'::pg_catalog.regclass)
    and
    (select value from baseline_objects where object_name='events_policies') =
      (select pg_catalog.md5(coalesce(pg_catalog.string_agg(
        policyname || '|' || cmd || '|' || roles::text || '|' ||
        coalesce(qual,'<NULL>') || '|' || coalesce(with_check,'<NULL>'),
        E'\n' order by policyname
      ),''))
       from pg_catalog.pg_policies
       where schemaname='public' and tablename='events')
  into v_passed;
  insert into test_results values (
    38,'Prawa i polityki public.events nie zostały zmienione',v_passed,
    'Porównano ACL i pełne definicje polityk.'
  );

  -- 39. Trzy RPC admin_event istnieją z tym samym ACL.
  select
    (select value from baseline_objects where object_name='admin_event_rpc_acl') =
      (select pg_catalog.md5(pg_catalog.string_agg(
        proname || '|' || coalesce(proacl::text,'<NULL>'),
        E'\n' order by proname
      ))
       from pg_catalog.pg_proc as procedure_record
       join pg_catalog.pg_namespace as namespace_record
         on namespace_record.oid=procedure_record.pronamespace
       where namespace_record.nspname='public'
         and procedure_record.proname in (
           'admin_create_event','admin_update_event','admin_set_event_active'
         ))
    and (
      select pg_catalog.count(*)=3
      from pg_catalog.pg_proc as procedure_record
      join pg_catalog.pg_namespace as namespace_record
        on namespace_record.oid=procedure_record.pronamespace
      where namespace_record.nspname='public'
        and procedure_record.proname in (
          'admin_create_event','admin_update_event','admin_set_event_active'
        )
    )
  into v_passed;
  insert into test_results values (
    39,'Admin event RPC pozostają bez zmian ACL',v_passed,
    'Wszystkie trzy funkcje istnieją i zachowały ACL.'
  );

  -- 40-41. Wspólny trigger zachowuje INSERT/UPDATE długości rezerwacji.
  insert into public.lane_booking_durations (
    lane_id,duration_minutes,display_order,is_active
  ) values (
    v_lane2,180,3,true
  ) returning id into v_duration;
  insert into test_results values (
    40,'Wspólny trigger pozwala INSERT lane_booking_durations',
    exists (
      select 1 from public.lane_booking_durations
      where id=v_duration and lane_id=v_lane2 and duration_minutes=180
    ),
    'Trigger nie może odczytywać pól właściwych wyłącznie lane_blocks.'
  );

  update public.lane_booking_durations
  set lane_id=v_lane1,display_order=4
  where id=v_duration;
  insert into test_results values (
    41,'Wspólny trigger pozwala UPDATE lane_booking_durations',
    exists (
      select 1 from public.lane_booking_durations
      where id=v_duration and lane_id=v_lane1 and display_order=4
    ),
    'UPDATE ze zmianą osi blokuje OLD i NEW bez logiki event conflict.'
  );

  -- 42-43. Wspólny trigger zachowuje INSERT/UPDATE reguł cenowych.
  insert into public.lane_pricing_rules (
    lane_id,day_group,min_shooters,max_shooters,label,
    hourly_price,display_order,is_active
  ) values (
    v_lane2,'mon_thu',1,5,'[TEST][5D-3A][INACTIVE-PRICE]',11,99,false
  ) returning id into v_pricing_rule;
  insert into test_results values (
    42,'Wspólny trigger pozwala INSERT lane_pricing_rules',
    exists (
      select 1 from public.lane_pricing_rules
      where id=v_pricing_rule and lane_id=v_lane2 and not is_active
    ),
    'Trigger nie może odczytywać pól właściwych wyłącznie lane_blocks.'
  );

  update public.lane_pricing_rules
  set lane_id=v_lane1,hourly_price=12
  where id=v_pricing_rule;
  insert into test_results values (
    43,'Wspólny trigger pozwala UPDATE lane_pricing_rules',
    exists (
      select 1 from public.lane_pricing_rules
      where id=v_pricing_rule and lane_id=v_lane1 and hourly_price=12
    ),
    'UPDATE ze zmianą osi blokuje OLD i NEW bez logiki event conflict.'
  );

  -- 44. Statyczna gotowość do rollbacku.
  select
    pg_catalog.to_regprocedure(
      'public.create_reservation(uuid,date,time without time zone,integer,integer,uuid,text)'
    ) is not null
    and pg_catalog.to_regprocedure('public.lock_lane_booking_configuration()') is not null
    and exists(select 1 from public.events where title like '[TEST][5D-3A]%')
    and exists(select 1 from public.shooting_lanes where name like '[TEST][5D-3A]%')
    and not exists (
      select 1 from test_results where passed is false
    )
  into v_passed;
  insert into test_results values (
    44,'Gotowość do końcowego ROLLBACK',v_passed,
    'Migracja, role i dane syntetyczne są w jednej otwartej transakcji.'
  );
end;
$contract_tests$;

select test_order,test_name,passed,result
from test_results
order by test_order;

do $assertions$
declare
  v_failures text;
begin
  select pg_catalog.string_agg(
    test_order::text || ': ' || test_name,
    ', ' order by test_order
  )
  into v_failures
  from test_results
  where passed is false;

  if v_failures is not null then
    raise exception '5D-3A contract tests failed: %',v_failures;
  end if;
end;
$assertions$;

rollback;

do $rollback_assertions$
begin
  if pg_catalog.md5(pg_catalog.pg_get_functiondef(
       'public.create_reservation(uuid,date,time without time zone,integer,integer,uuid,text)'::pg_catalog.regprocedure
     )) <> '4d615296efa4676694216f122f123071'
     or pg_catalog.md5(pg_catalog.pg_get_functiondef(
       'public.lock_lane_booking_configuration()'::pg_catalog.regprocedure
     )) <> 'd6667e49fdd6014747fca37a3e41266d'
     or (
       select pg_catalog.count(*) <> 5
       from pg_catalog.pg_policies
       where schemaname='public' and tablename='lane_blocks'
     )
     or not exists (
       select 1 from pg_catalog.pg_policies
       where schemaname='public' and tablename='lane_blocks'
         and policyname='Admins and staff can insert lane blocks'
         and cmd='INSERT'
         and with_check ~ 'is_admin_or_staff[(][)]'
     )
     or not exists (
       select 1 from pg_catalog.pg_policies
       where schemaname='public' and tablename='lane_blocks'
         and policyname='Admins and staff can update lane blocks'
         and cmd='UPDATE'
         and qual ~ 'is_admin_or_staff[(][)]'
         and with_check ~ 'is_admin_or_staff[(][)]'
     )
     or not exists (
       select 1 from pg_catalog.pg_policies
       where schemaname='public' and tablename='lane_blocks'
         and policyname='Admins and staff can delete lane blocks'
         and cmd='DELETE'
         and qual ~ 'is_admin_or_staff[(][)]'
     )
     or not pg_catalog.has_table_privilege(
       'anon','public.lane_blocks','TRUNCATE'
     )
     or not pg_catalog.has_table_privilege(
       'authenticated','public.lane_blocks','TRUNCATE'
     )
     or exists(select 1 from public.events where title like '[TEST][5D-3A]%')
     or exists(select 1 from public.shooting_lanes where name like '[TEST][5D-3A]%')
     or exists(select 1 from public.lane_blocks where reason like '[TEST][5D-3A]%')
     or exists(select 1 from public.reservations where reservation_note='[TEST][5D-3A]')
     or exists(select 1 from auth.users where email like '[TEST]-5d3a-%@example.invalid') then
    raise exception 'ROLLBACK nie przywrócił stanu sprzed testu.';
  end if;
end;
$rollback_assertions$;

select true as rollback_confirmed;
