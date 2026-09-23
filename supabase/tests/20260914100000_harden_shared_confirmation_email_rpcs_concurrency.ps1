param(
  [string]$DockerContainerName = 'supabase_db_csk-booking',
  [switch]$ConfirmIsolatedDatabase
)

$ErrorActionPreference = 'Stop'
if (-not $ConfirmIsolatedDatabase) { throw 'Use only an isolated local database.' }

$tenant = 'c5c00000-0000-4000-8000-000000000001'
$user = [guid]::NewGuid().ToString()
$lane = [guid]::NewGuid().ToString()
$price = [guid]::NewGuid().ToString()
$reservation = [guid]::NewGuid().ToString()
$run = [guid]::NewGuid().ToString('N')

function Invoke-LocalSql([string]$Sql) {
  $output = $Sql | & docker exec -i $DockerContainerName psql -v ON_ERROR_STOP=1 -U postgres -d postgres -At
  if ($LASTEXITCODE -ne 0) { throw "Local SQL failed: $output" }
  return ($output -join "`n").Trim()
}

$setup = @"
insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values('$user','00000000-0000-0000-0000-000000000000','authenticated','authenticated','2c1-race-$run@example.invalid','',now(),'{}','{}',now(),now());
insert into public.profiles(id,user_id,email,phone,first_name,last_name,full_name,role,verification_status)
select id,id,email,'000','Test','Race','[TEST][SAAS-9D-2C-1][$run]','user','verified' from auth.users
where id='$user' and not exists(select 1 from public.profiles where profiles.user_id=auth.users.id);
update public.profiles set phone='000',first_name='Test',last_name='Race',full_name='[TEST][SAAS-9D-2C-1][$run]',role='user',verification_status='verified' where user_id='$user';
insert into public.tenant_memberships(tenant_id,user_id,role,status)
values('$tenant','$user','user','active');
insert into public.shooting_lanes(id,tenant_id,name,type,price_per_hour,is_active,max_shooters,booking_step_minutes,display_order,currency_code,resource_kind,parent_lane_id,whole_lane_bookable,positions_bookable)
values('$lane','$tenant','[TEST][SAAS-9D-2C-1][$run] Lane','test',10,true,1,60,9988,'PLN','lane',null,true,false);
insert into public.lane_pricing_rules(id,lane_id,day_group,min_shooters,max_shooters,label,hourly_price)
values('$price','$lane','mon_thu',1,1,'[TEST][SAAS-9D-2C-1]',10);
insert into public.reservations(id,user_id,tenant_id,lane_id,customer_name,customer_email,customer_phone,reservation_date,start_time,end_time,duration_minutes,price,reservation_status,payment_status,attendance_status,shooters_count,pricing_rule_id,pricing_day_group_snapshot,lane_name_snapshot,pricing_label_snapshot,price_per_hour_snapshot,total_price,currency_code,creation_request_id)
values('$reservation','$user','$tenant','$lane','[TEST][SAAS-9D-2C-1]','race@example.invalid','000',date '2099-12-20',time '08:00',time '09:00',60,10,'confirmed','pay_on_site','planned',1,'$price','mon_thu','Race','Race',10,10,'PLN',gen_random_uuid());
"@

$prepare = @"
begin;
select set_config('request.jwt.claims',jsonb_build_object('sub','$user','role','authenticated')::text,true);
select set_config('request.jwt.claim.sub','$user',true);
set local role authenticated;
select public.prepare_confirmation_email('reservation_confirmation','$reservation')::text;
commit;
"@

$jobScript = {
  param($container,$sql)
  $result = $sql | & docker exec -i $container psql -v ON_ERROR_STOP=1 -U postgres -d postgres -At
  if ($LASTEXITCODE -ne 0) { throw ($result -join "`n") }
  ($result -join "`n")
}

try {
  Invoke-LocalSql $setup | Out-Null
  $prepareA = Start-Job -ScriptBlock $jobScript -ArgumentList $DockerContainerName,$prepare
  $prepareB = Start-Job -ScriptBlock $jobScript -ArgumentList $DockerContainerName,$prepare
  Wait-Job $prepareA,$prepareB | Out-Null
  $prepareOutput = ((Receive-Job $prepareA) + (Receive-Job $prepareB)) -join "`n"
  Remove-Job $prepareA,$prepareB -Force
  if (($prepareOutput | Select-String '"code": "ready"' -AllMatches).Matches.Count -ne 1) { throw 'Expected exactly one ready prepare.' }
  if (($prepareOutput | Select-String '"code": "in_progress"' -AllMatches).Matches.Count -ne 1) { throw 'Expected exactly one in-progress prepare.' }

  $claim = Invoke-LocalSql "select claim_id::text from public.email_deliveries where message_type='reservation_confirmation' and record_id='$reservation';"
  if ($claim -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') { throw 'Prepared claim is missing.' }
  $complete = @"
begin;
set local role service_role;
select public.complete_confirmation_email('$claim',true,'2c1-race-provider',null)::text;
commit;
"@
  $completeA = Start-Job -ScriptBlock $jobScript -ArgumentList $DockerContainerName,$complete
  $completeB = Start-Job -ScriptBlock $jobScript -ArgumentList $DockerContainerName,$complete
  Wait-Job $completeA,$completeB | Out-Null
  $completeOutput = ((Receive-Job $completeA) + (Receive-Job $completeB)) -join "`n"
  Remove-Job $completeA,$completeB -Force
  if (($completeOutput | Select-String '"changed": true' -AllMatches).Matches.Count -ne 1) { throw 'Expected exactly one completing mutation.' }
  if (($completeOutput | Select-String '"code": "claim_not_found"' -AllMatches).Matches.Count -ne 1) { throw 'Expected exactly one controlled duplicate completion.' }

  $state = Invoke-LocalSql "select (count(*)=1 and bool_and(sent_at is not null) and bool_and(provider_message_id='2c1-race-provider') and bool_and(claim_id is null) and bool_and(tenant_id='$tenant'::uuid))::text from public.email_deliveries where record_id='$reservation';"
  if ($state -ne 'true') { throw 'Concurrent final delivery state differs.' }
  Write-Output 'SAAS-9D-2C-1 prepare concurrency: PASS'
  Write-Output 'SAAS-9D-2C-1 complete concurrency: PASS'
  Write-Output 'deadlocks=0 broken_invariants=0 duplicate_final_effects=0'
}
finally {
  $cleanup = "delete from public.email_deliveries where record_id='$reservation'; delete from public.reservations where id='$reservation'; delete from public.lane_pricing_rules where id='$price'; delete from public.shooting_lanes where id='$lane'; delete from public.tenant_memberships where user_id='$user'; delete from public.profiles where user_id='$user'; delete from auth.users where id='$user'; select (not exists(select 1 from auth.users where id='$user') and not exists(select 1 from public.email_deliveries where record_id='$reservation'))::text;"
  $clean = Invoke-LocalSql $cleanup
  if (($clean -split "`n")[-1] -ne 'true') { throw 'Fixture cleanup failed.' }
  Write-Output 'fixture_cleanup=0'
}
