param(
  [string]$DockerContainerName = 'supabase_db_csk-booking',
  [switch]$ConfirmIsolatedDatabase
)

$ErrorActionPreference = 'Stop'
if (-not $ConfirmIsolatedDatabase) { throw 'Use only an isolated local database.' }

$tenant = 'c5c00000-0000-4000-8000-000000000001'
$tenantB = [guid]::NewGuid().ToString()
$admin1 = [guid]::NewGuid().ToString()
$admin2 = [guid]::NewGuid().ToString()
$customer = [guid]::NewGuid().ToString()
$lane = [guid]::NewGuid().ToString()
$price = [guid]::NewGuid().ToString()
$reservation = [guid]::NewGuid().ToString()
$laneB = [guid]::NewGuid().ToString()
$priceB = [guid]::NewGuid().ToString()
$reservationB = [guid]::NewGuid().ToString()
$run = [guid]::NewGuid().ToString('N')
$marker = "[TEST][SAAS-9D-4B-2B-RACE][$run]"
$userIds = "'$admin1','$admin2','$customer'"

function Invoke-LocalSql([string]$Sql) {
  $output = $Sql | & docker exec -i $DockerContainerName psql -v ON_ERROR_STOP=1 -U postgres -d postgres -At
  if ($LASTEXITCODE -ne 0) { throw "Local SQL failed: $output" }
  return ($output -join "`n").Trim()
}

function Start-LocalSqlJob([string]$Sql) {
  Start-Job -ScriptBlock {
    param($container,$statement)
    $result = $statement | & docker exec -i $container psql -v ON_ERROR_STOP=1 -U postgres -d postgres -At
    if ($LASTEXITCODE -ne 0) { throw ($result -join "`n") }
    ($result -join "`n").Trim()
  } -ArgumentList $DockerContainerName,$Sql
}

function Start-LocalSqlResultJob([string]$Sql) {
  Start-Job -ScriptBlock {
    param($container,$statement)
    $result = $statement | & docker exec -i $container psql -v ON_ERROR_STOP=1 -U postgres -d postgres -At 2>&1
    [pscustomobject]@{ ExitCode=$LASTEXITCODE; Output=(($result | ForEach-Object { "$_" }) -join "`n") }
  } -ArgumentList $DockerContainerName,$Sql
}

function Receive-Pair($First,$Second) {
  Wait-Job $First,$Second | Out-Null
  try { return @((Receive-Job $First -ErrorAction Stop),(Receive-Job $Second -ErrorAction Stop)) }
  finally { Remove-Job $First,$Second -Force }
}

function New-ActorSql([string]$User,[string]$Call) {
  "begin; select set_config('request.jwt.claims',jsonb_build_object('sub','$User','role','authenticated')::text,true); select set_config('request.jwt.claim.sub','$User',true); set local role authenticated; $Call; commit;"
}

$setup = @"
insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at) values
('$admin1','00000000-0000-0000-0000-000000000000','authenticated','authenticated','4b2b-race-a1-$run@example.invalid','',now(),'{}','{}',now(),now()),
('$admin2','00000000-0000-0000-0000-000000000000','authenticated','authenticated','4b2b-race-a2-$run@example.invalid','',now(),'{}','{}',now(),now()),
('$customer','00000000-0000-0000-0000-000000000000','authenticated','authenticated','4b2b-race-user-$run@example.invalid','',now(),'{}','{}',now(),now());
insert into public.profiles(id,user_id,email,full_name,phone,role,verification_status,created_at,updated_at)
select id,id,email,'$marker','000','user','pending',now(),now() from auth.users where id in($userIds)
on conflict(user_id) do update set email=excluded.email,full_name=excluded.full_name,phone=excluded.phone,updated_at=now();
update public.profiles set role='admin' where user_id in('$admin1','$admin2');
insert into public.tenants(id,name,slug,status) values('$tenantB','$marker Tenant B','saas9d4b2b-race-$($run.Substring(0,12))','dormant');
insert into public.shooting_lanes(id,tenant_id,name,type,is_active,max_shooters,booking_step_minutes,display_order,currency_code,resource_kind,parent_lane_id,whole_lane_bookable,positions_bookable)
values('$lane','$tenant','$marker Lane A','test',true,2,60,9997,'PLN','lane',null,true,false),
('$laneB','$tenantB','$marker Lane B','test',true,2,60,9998,'PLN','lane',null,true,false);
insert into public.lane_pricing_rules(id,lane_id,day_group,min_shooters,max_shooters,label,hourly_price)
values('$price','$lane','mon_thu',1,2,'$marker Price A',10),('$priceB','$laneB','mon_thu',1,2,'$marker Price B',10);
insert into public.reservations(id,user_id,tenant_id,lane_id,customer_name,customer_email,customer_phone,reservation_date,start_time,end_time,duration_minutes,price,reservation_status,payment_status,attendance_status,check_in_token,shooters_count,pricing_rule_id,pricing_day_group_snapshot,lane_name_snapshot,pricing_label_snapshot,price_per_hour_snapshot,total_price,currency_code,creation_request_id)
values('$reservation','$customer','$tenant','$lane','$marker','4b2b-race-user-$run@example.invalid','000',date '2099-10-20',time '08:00',time '09:00',60,10,'confirmed','pay_on_site','planned',gen_random_uuid(),1,'$price','mon_thu','$marker Lane A','$marker Price A',10,10,'PLN',gen_random_uuid()),
('$reservationB','$customer','$tenantB','$laneB','$marker','4b2b-race-user-$run@example.invalid','000',date '2099-10-21',time '08:00',time '09:00',60,10,'confirmed','pay_on_site','planned',gen_random_uuid(),1,'$priceB','mon_thu','$marker Lane B','$marker Price B',10,10,'PLN',gen_random_uuid());
insert into public.tenant_user_verifications(tenant_id,user_id,verification_status,permissions_verified)
values('$tenant','$customer','verified',true),('$tenantB','$customer','pending',false)
on conflict(tenant_id,user_id) do update set verification_status=excluded.verification_status,permissions_verified=excluded.permissions_verified;
"@

try {
  Invoke-LocalSql $setup | Out-Null
  $deadlocksBefore = [int](Invoke-LocalSql "select deadlocks from pg_stat_database where datname=current_database();")
  $call1 = New-ActorSql $admin1 "select public.update_reservation_customer_verification_v1('$reservation','mark_pending','race-one')->>'verification_status'"
  $call2 = New-ActorSql $admin2 "select public.update_reservation_customer_verification_v1('$reservation','reject','race-two')->>'verification_status'"
  $results = Receive-Pair (Start-LocalSqlJob $call1) (Start-LocalSqlJob $call2)
  $joined = $results -join "`n"
  if ($joined -notmatch '(?m)^pending\r?$' -or $joined -notmatch '(?m)^rejected\r?$') { throw "Concurrent results differ: $joined" }

  $integrity = Invoke-LocalSql "select ((select count(*) from public.tenant_user_verifications where tenant_id='$tenant' and user_id='$customer')=1 and (select verification_status in('pending','rejected') from public.tenant_user_verifications where tenant_id='$tenant' and user_id='$customer') and (select count(*) from public.audit_logs where tenant_id='$tenant' and target_type='tenant_user_verification' and target_id='$customer')=2)::text;"
  if ($integrity -ne 'true') { throw 'Concurrent verification writes broke row or audit invariants.' }
  $deadlocksAfter = [int](Invoke-LocalSql "select deadlocks from pg_stat_database where datname=current_database();")
  if ($deadlocksAfter -ne $deadlocksBefore) { throw 'A database deadlock was recorded.' }
  Write-Output 'CONCURRENT_VERIFICATION_WRITERS=PASS'
  Write-Output 'ONE_TENANT_VERIFICATION_ROW=PASS'
  Write-Output 'TENANT_BOUND_AUDITS=2'

  Invoke-LocalSql "update public.reservations set reservation_status='confirmed',attendance_status='planned',checked_in_at=null,completed_at=null where id='$reservation'; delete from public.audit_logs where target_id='$customer' or (target_id='$reservation' and action='RESERVATION_STARTED'); update public.tenant_user_verifications set verification_status='verified',permissions_verified=true where tenant_id='$tenant' and user_id='$customer';" | Out-Null
  $verificationCall = New-ActorSql $admin1 "select public.update_reservation_customer_verification_v1('$reservation','mark_pending','check-in race')->>'verification_status'"
  $attendanceCall = New-ActorSql $admin2 "select public.update_reservation_attendance('$reservation','start')->>'code'"
  $results = Receive-Pair (Start-LocalSqlJob $verificationCall) (Start-LocalSqlJob $attendanceCall)
  $joined = $results -join "`n"
  if ($joined -notmatch '(?m)^pending\r?$' -or $joined -notmatch '(?m)^started\r?$') { throw "Verification/check-in race differs: $joined" }
  if ((Invoke-LocalSql "select ((select verification_status='pending' from public.tenant_user_verifications where tenant_id='$tenant' and user_id='$customer') and (select attendance_status='present' from public.reservations where id='$reservation'))::text;") -ne 'true') { throw 'Verification/check-in race lost a committed update.' }
  Write-Output 'VERIFICATION_VS_CHECKIN=PASS'

  Invoke-LocalSql "update public.reservations set reservation_status='confirmed',attendance_status='planned',checked_in_at=null,completed_at=null where id='$reservation'; delete from public.audit_logs where target_id='$reservation' and action='RESERVATION_STARTED';" | Out-Null
  $retryCall = New-ActorSql $admin1 "select public.update_reservation_attendance('$reservation','start')->>'code'"
  $results = Receive-Pair (Start-LocalSqlJob $retryCall) (Start-LocalSqlJob $retryCall)
  $joined = $results -join "`n"
  if ($joined -notmatch '(?m)^started\r?$' -or $joined -notmatch '(?m)^already_started\r?$') { throw "Concurrent check-in retry differs: $joined" }
  if ((Invoke-LocalSql "select ((select attendance_status='present' from public.reservations where id='$reservation') and (select count(*)=1 from public.audit_logs where target_id='$reservation' and action='RESERVATION_STARTED'))::text;") -ne 'true') { throw 'Concurrent check-in retry was not idempotent.' }
  Write-Output 'CHECKIN_RETRY_IDEMPOTENCY=PASS'

  $statusJob = Start-LocalSqlJob "begin; update public.tenant_memberships set status='suspended' where tenant_id='$tenant' and user_id='$admin1'; select pg_sleep(0.5); commit; select 'suspended';"
  Start-Sleep -Milliseconds 100
  $deniedJob = Start-LocalSqlResultJob (New-ActorSql $admin1 "select public.update_reservation_customer_verification_v1('$reservation','verify','must deny')->>'verification_status'")
  Wait-Job $statusJob,$deniedJob | Out-Null
  try {
    $statusResult = Receive-Job $statusJob -ErrorAction Stop
    $deniedResult = Receive-Job $deniedJob -ErrorAction Stop
  } finally { Remove-Job $statusJob,$deniedJob -Force }
  if (($statusResult -join "`n") -notmatch '(?m)^suspended\r?$' -or $deniedResult.ExitCode -eq 0) { throw 'Membership-status race did not fail closed.' }
  Invoke-LocalSql "update public.tenant_memberships set status='active' where tenant_id='$tenant' and user_id='$admin1';" | Out-Null
  Write-Output 'MEMBERSHIP_STATUS_RACE=DENY'

  $validCall = New-ActorSql $admin1 "select public.update_reservation_customer_verification_v1('$reservation','reject','valid A')->>'verification_status'"
  $foreignCall = New-ActorSql $admin1 "select public.update_reservation_customer_verification_v1('$reservationB','verify','invalid B')->>'verification_status'"
  $validJob = Start-LocalSqlResultJob $validCall
  $foreignJob = Start-LocalSqlResultJob $foreignCall
  $results = Receive-Pair $validJob $foreignJob
  $validResult = $results | Where-Object ExitCode -eq 0
  $foreignResult = $results | Where-Object ExitCode -ne 0
  if ($validResult.Count -ne 1 -or $foreignResult.Count -ne 1 -or $validResult.Output -notmatch '(?m)^rejected\r?$') { throw 'Concurrent foreign-resource denial differs.' }
  if ((Invoke-LocalSql "select ((select verification_status='rejected' from public.tenant_user_verifications where tenant_id='$tenant' and user_id='$customer') and (select verification_status='pending' from public.tenant_user_verifications where tenant_id='$tenantB' and user_id='$customer'))::text;") -ne 'true') { throw 'Concurrent foreign-resource attempt contaminated Tenant B.' }
  Write-Output 'RESOURCE_TENANT_MISMATCH_RACE=DENY'
  Write-Output 'CROSS_TENANT_EFFECTS=0'

  $rowA = "begin; update public.tenant_user_verifications set verification_status='verified',permissions_verified=true where tenant_id='$tenant' and user_id='$customer'; commit; select 'A';"
  $rowB = "begin; update public.tenant_user_verifications set verification_status='rejected',permissions_verified=false where tenant_id='$tenantB' and user_id='$customer'; commit; select 'B';"
  $results = Receive-Pair (Start-LocalSqlJob $rowA) (Start-LocalSqlJob $rowB)
  if (($results -join "`n") -notmatch '(?m)^A\r?$' -or ($results -join "`n") -notmatch '(?m)^B\r?$') { throw 'Independent tenant rows did not complete concurrently.' }
  if ((Invoke-LocalSql "select ((select verification_status='verified' from public.tenant_user_verifications where tenant_id='$tenant' and user_id='$customer') and (select verification_status='rejected' from public.tenant_user_verifications where tenant_id='$tenantB' and user_id='$customer'))::text;") -ne 'true') { throw 'Independent tenant rows contaminated each other.' }
  Write-Output 'SAME_USER_TWO_TENANT_ROWS_CONCURRENT=PASS'
  Write-Output 'DEADLOCKS=0'
}
finally {
  $cleanup = "delete from public.audit_logs where target_id in('$customer','$reservation','$reservationB'); delete from public.reservations where id in('$reservation','$reservationB'); delete from public.tenant_user_verifications where user_id='$customer' and tenant_id in('$tenant','$tenantB'); delete from public.lane_pricing_rules where id in('$price','$priceB'); delete from public.shooting_lanes where id in('$lane','$laneB'); delete from public.tenant_memberships where user_id in($userIds) or tenant_id='$tenantB'; delete from public.profiles where user_id in($userIds); delete from public.tenants where id='$tenantB'; delete from auth.users where id in($userIds); select (not exists(select 1 from auth.users where id in($userIds)) and not exists(select 1 from public.reservations where id in('$reservation','$reservationB')) and not exists(select 1 from public.tenant_user_verifications where user_id='$customer') and not exists(select 1 from public.tenants where id='$tenantB'))::text;"
  $clean = Invoke-LocalSql $cleanup
  if (($clean -split "`n")[-1] -ne 'true') { throw 'Fixture cleanup failed.' }
  Write-Output 'fixture_cleanup=0'
}
