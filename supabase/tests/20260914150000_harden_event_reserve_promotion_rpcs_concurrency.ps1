param(
  [string]$DockerContainerName = 'supabase_db_csk-booking',
  [switch]$ConfirmIsolatedDatabase
)

$ErrorActionPreference = 'Stop'
if (-not $ConfirmIsolatedDatabase) { throw 'Use only an isolated local database.' }

$csk = 'c5c00000-0000-4000-8000-000000000001'
$tenantB = [guid]::NewGuid().ToString()
$users = 1..10 | ForEach-Object { [guid]::NewGuid().ToString() }
$events = 1..6 | ForEach-Object { [guid]::NewGuid().ToString() }
$registrations = 1..12 | ForEach-Object { [guid]::NewGuid().ToString() }
$run = [guid]::NewGuid().ToString('N')

function Invoke-LocalSql([string]$Sql) {
  $output = $Sql | & docker exec -i $DockerContainerName psql -v ON_ERROR_STOP=1 -U postgres -d postgres -At
  if ($LASTEXITCODE -ne 0) { throw "Local SQL failed: $output" }
  return ($output -join "`n").Trim()
}

function Start-LocalSqlJob([string]$Sql) {
  Start-Job -ScriptBlock {
    param($container, $statement)
    $result = $statement | & docker exec -i $container psql -v ON_ERROR_STOP=1 -U postgres -d postgres -At
    if ($LASTEXITCODE -ne 0) { throw ($result -join "`n") }
    ($result -join "`n").Trim()
  } -ArgumentList $DockerContainerName, $Sql
}

function Receive-Pair($First, $Second) {
  Wait-Job $First, $Second | Out-Null
  try { return @((Receive-Job $First), (Receive-Job $Second)) }
  finally { Remove-Job $First, $Second -Force }
}

$userValues = for ($i = 0; $i -lt $users.Count; $i++) {
  "('$($users[$i])','00000000-0000-0000-0000-000000000000','authenticated','authenticated','9d2c2-race-$i-$run@example.invalid','',now(),'{}','{}',now(),now())"
}
$profileIds = ($users | ForEach-Object { "'$_'" }) -join ','
$cskMembershipValues = (0..8 | ForEach-Object { "('$csk','$($users[$_])','user','active')" }) -join ",`n"

$setup = @"
insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at) values
$($userValues -join ",`n");
insert into public.profiles(id,user_id,email,phone,first_name,last_name,full_name,role,verification_status)
select id,id,email,'000','Test','2C2 Race','[TEST][SAAS-9D-2C-2][$run]','user','verified'
from auth.users where id in($profileIds)
  and not exists(select 1 from public.profiles where profiles.user_id=auth.users.id);
update public.profiles set phone='000',first_name='Test',last_name='2C2 Race',full_name='[TEST][SAAS-9D-2C-2][$run]',verification_status='verified'
where user_id in($profileIds);
insert into public.tenants(id,name,slug,status)
values('$tenantB','[TEST][SAAS-9D-2C-2][$run] Tenant B','saas9d2c2-race-$($run.Substring(0,12))','dormant');
insert into public.tenant_memberships(tenant_id,user_id,role,status)
values
$cskMembershipValues,
('$tenantB','$($users[9])','user','active');
insert into public.events(id,tenant_id,title,description,event_date,start_time,end_time,location,price,max_participants,is_active) values
('$($events[0])','$csk','[TEST][SAAS-9D-2C-2][$run] Prepare','test',date '2099-12-01',time '10:00',time '11:00','Test',0,10,true),
('$($events[1])','$csk','[TEST][SAAS-9D-2C-2][$run] Complete','test',date '2099-12-02',time '10:00',time '11:00','Test',0,10,true),
('$($events[2])','$csk','[TEST][SAAS-9D-2C-2][$run] Confirm','test',date '2099-12-03',time '10:00',time '11:00','Test',0,1,true),
('$($events[3])','$csk','[TEST][SAAS-9D-2C-2][$run] Cancel','test',date '2099-12-04',time '10:00',time '11:00','Test',0,10,true),
('$($events[4])','$csk','[TEST][SAAS-9D-2C-2][$run] Deactivate','test',date '2099-12-05',time '10:00',time '11:00','Test',0,10,true),
('$($events[5])','$tenantB','[TEST][SAAS-9D-2C-2][$run] Tenant B','test',date '2099-12-06',time '10:00',time '11:00','Test',0,10,true);
insert into public.event_registrations(id,tenant_id,event_id,user_id,customer_name,customer_email,customer_phone,registration_status,payment_status,created_at) values
('$($registrations[0])','$csk','$($events[0])','$($users[0])','Test','a@example.invalid','000','reserve','pay_on_site',now()-interval '2 hours'),
('$($registrations[1])','$csk','$($events[0])','$($users[1])','Test','b@example.invalid','000','reserve','pay_on_site',now()-interval '1 hour'),
('$($registrations[2])','$csk','$($events[1])','$($users[2])','Test','c@example.invalid','000','reserve','pay_on_site',now()),
('$($registrations[3])','$csk','$($events[2])','$($users[3])','Test','d@example.invalid','000','reserve','pay_on_site',now()-interval '1 hour'),
('$($registrations[4])','$csk','$($events[2])','$($users[4])','Test','e@example.invalid','000','reserve','pay_on_site',now()),
('$($registrations[5])','$csk','$($events[3])','$($users[5])','Test','f@example.invalid','000','reserve','pay_on_site',now()),
('$($registrations[6])','$csk','$($events[4])','$($users[6])','Test','g@example.invalid','000','reserve','pay_on_site',now()),
('$($registrations[7])','$tenantB','$($events[5])','$($users[9])','Test','h@example.invalid','000','reserve','pay_on_site',now());
"@

try {
  Invoke-LocalSql $setup | Out-Null

  $prepareSql = "begin; set local role service_role; select count(*) from public.prepare_event_reserve_promotions('$($events[0])'); commit;"
  $prepareResults = Receive-Pair (Start-LocalSqlJob $prepareSql) (Start-LocalSqlJob $prepareSql)
  $prepareCounts = @([regex]::Matches(($prepareResults -join "`n"), '(?m)^(0|2)\r?$') | ForEach-Object { [int]$_.Groups[1].Value })
  if ($prepareCounts.Count -ne 2 -or (($prepareCounts | Measure-Object -Sum).Sum -ne 2) -or -not ($prepareCounts -contains 0) -or -not ($prepareCounts -contains 2)) {
    throw "Concurrent prepare results differ: $($prepareResults -join ' | ')"
  }
  $prepareState = Invoke-LocalSql "select (count(*)=2 and count(distinct promotion_claim_id)=2 and bool_and(promotion_attempt_count=1))::text from public.event_registrations where event_id='$($events[0])';"
  if ($prepareState -ne 'true') { throw 'Concurrent prepare created duplicate or missing claims.' }
  Write-Output 'CONCURRENT_PREPARE=PASS'

  $claimRow = Invoke-LocalSql "begin; set local role service_role; select registration_id||'|'||claim_id from public.prepare_event_reserve_promotions('$($events[1])'); commit;"
  $claimMatch = [regex]::Match($claimRow, '(?m)^[0-9a-f-]{36}\|([0-9a-f-]{36})\r?$')
  if (-not $claimMatch.Success) { throw "Prepared claim output differs: $claimRow" }
  $claim = $claimMatch.Groups[1].Value
  $completeSql = "begin; set local role service_role; select (public.complete_event_reserve_promotion('$($registrations[2])','$claim',true,null)->>'changed'); commit;"
  $completeResults = Receive-Pair (Start-LocalSqlJob $completeSql) (Start-LocalSqlJob $completeSql)
  $completeFlags = @([regex]::Matches(($completeResults -join "`n"), '(?m)^(true|false)\r?$') | ForEach-Object { $_.Groups[1].Value })
  if ($completeFlags.Count -ne 2 -or (($completeFlags | Where-Object { $_ -eq 'true' }).Count -ne 1) -or (($completeFlags | Where-Object { $_ -eq 'false' }).Count -ne 1)) {
    throw "Concurrent complete results differ: $($completeResults -join ' | ')"
  }
  Write-Output 'CONCURRENT_COMPLETE=PASS'

  $confirmRows = Invoke-LocalSql "begin; set local role service_role; select registration_id||'|'||promotion_token from public.prepare_event_reserve_promotions('$($events[2])') order by registration_id; update public.event_registrations set promotion_email_sent_at=now(),promotion_claim_id=null,promotion_claim_expires_at=null where event_id='$($events[2])'; commit;"
  $confirmPairs = [regex]::Matches($confirmRows, '(?m)^[0-9a-f-]{36}\|[0-9a-f-]{36}\r?$') | ForEach-Object { $_.Value.Trim() }
  $tokenByRegistration = @{}
  foreach ($pair in $confirmPairs) { $parts = $pair -split '\|'; $tokenByRegistration[$parts[0]] = $parts[1] }
  $confirmSqlA = "begin; select set_config('request.jwt.claims',jsonb_build_object('sub','$($users[3])','role','authenticated')::text,true); select set_config('request.jwt.claim.sub','$($users[3])',true); set local role authenticated; select public.confirm_event_reserve_promotion('$($tokenByRegistration[$registrations[3]])')->>'code'; commit;"
  $confirmSqlB = "begin; select set_config('request.jwt.claims',jsonb_build_object('sub','$($users[4])','role','authenticated')::text,true); select set_config('request.jwt.claim.sub','$($users[4])',true); set local role authenticated; select public.confirm_event_reserve_promotion('$($tokenByRegistration[$registrations[4]])')->>'code'; commit;"
  $confirmResults = Receive-Pair (Start-LocalSqlJob $confirmSqlA) (Start-LocalSqlJob $confirmSqlB)
  $joinedConfirm = $confirmResults -join "`n"
  $confirmCodes = @([regex]::Matches($joinedConfirm, '(?m)^(confirmed|full)\r?$') | ForEach-Object { $_.Groups[1].Value })
  if ($confirmCodes.Count -ne 2 -or (($confirmCodes | Where-Object { $_ -eq 'confirmed' }).Count -ne 1) -or (($confirmCodes | Where-Object { $_ -eq 'full' }).Count -ne 1)) {
    throw "First-confirmed-wins results differ: $joinedConfirm"
  }
  $capacityState = Invoke-LocalSql "select (count(*) filter(where registration_status in('registered','approved'))=1)::text from public.event_registrations where event_id='$($events[2])';"
  if ($capacityState -ne 'true') { throw 'Concurrent confirmation exceeded capacity.' }
  Write-Output 'FIRST_CONFIRMED_WINS=PASS'

  $cancelClaimOutput = Invoke-LocalSql "begin; set local role service_role; select claim_id from public.prepare_event_reserve_promotions('$($events[3])'); commit;"
  $cancelClaim = [regex]::Match($cancelClaimOutput, '(?m)^[0-9a-f-]{36}\r?$').Value.Trim()
  if (-not $cancelClaim) { throw "Cancellation claim output differs: $cancelClaimOutput" }
  $cancelComplete = "begin; set local role service_role; select public.complete_event_reserve_promotion('$($registrations[5])','$cancelClaim',true,null)->>'success'; commit;"
  $cancelUpdate = "begin; update public.event_registrations set registration_status='cancelled' where id='$($registrations[5])'; commit;"
  Receive-Pair (Start-LocalSqlJob $cancelComplete) (Start-LocalSqlJob $cancelUpdate) | Out-Null
  if ((Invoke-LocalSql "select (registration_status='cancelled' and promotion_email_sent_at is not null and promotion_claim_id is null)::text from public.event_registrations where id='$($registrations[5])';") -ne 'true') {
    throw 'Complete/cancellation race broke final state.'
  }
  Write-Output 'COMPLETE_VS_REGISTRATION_CANCELLATION=PASS'

  $deactivateClaimOutput = Invoke-LocalSql "begin; set local role service_role; select claim_id from public.prepare_event_reserve_promotions('$($events[4])'); commit;"
  $deactivateClaim = [regex]::Match($deactivateClaimOutput, '(?m)^[0-9a-f-]{36}\r?$').Value.Trim()
  if (-not $deactivateClaim) { throw "Deactivation claim output differs: $deactivateClaimOutput" }
  $deactivateComplete = "begin; set local role service_role; select public.complete_event_reserve_promotion('$($registrations[6])','$deactivateClaim',true,null)->>'success'; commit;"
  $deactivateEvent = "begin; update public.events set is_active=false where id='$($events[4])'; commit;"
  Receive-Pair (Start-LocalSqlJob $deactivateComplete) (Start-LocalSqlJob $deactivateEvent) | Out-Null
  if ((Invoke-LocalSql "select ((select not is_active from public.events where id='$($events[4])') and (select registration_status='reserve' and promotion_email_sent_at is not null from public.event_registrations where id='$($registrations[6])'))::text;") -ne 'true') {
    throw 'Complete/deactivation race broke final state.'
  }
  Write-Output 'COMPLETE_VS_EVENT_DEACTIVATION=PASS'

  $tenantSqlA = "begin; set local role service_role; select count(*) from public.prepare_event_reserve_promotions('$($events[0])'); commit;"
  $tenantSqlB = "begin; set local role service_role; select count(*) from public.prepare_event_reserve_promotions('$($events[5])'); commit;"
  Receive-Pair (Start-LocalSqlJob $tenantSqlA) (Start-LocalSqlJob $tenantSqlB) | Out-Null
  if ((Invoke-LocalSql "select (promotion_claim_id is not null and tenant_id='$tenantB'::uuid)::text from public.event_registrations where id='$($registrations[7])';") -ne 'true') {
    throw 'Concurrent Tenant B prepare was not isolated.'
  }
  if ((Invoke-LocalSql "select (not exists(select 1 from public.event_registrations r join public.events e on e.id=r.event_id where r.tenant_id<>e.tenant_id))::text;") -ne 'true') {
    throw 'Concurrent tenant promotions broke tenant integrity.'
  }
  Write-Output 'CROSS_TENANT_CONCURRENCY=PASS'
  Write-Output 'DEADLOCKS=0'
  Write-Output 'DUPLICATE_FINAL_EFFECTS=0'
  Write-Output 'BROKEN_INVARIANTS=0'
}
finally {
  $eventIds = ($events | ForEach-Object { "'$_'" }) -join ','
  $cleanup = "delete from public.event_registrations where event_id in($eventIds); delete from public.event_lanes where event_id in($eventIds); delete from public.events where id in($eventIds); delete from public.tenant_memberships where user_id in($profileIds) or tenant_id='$tenantB'; delete from public.profiles where user_id in($profileIds); delete from public.tenants where id='$tenantB'; delete from auth.users where id in($profileIds); select (not exists(select 1 from auth.users where id in($profileIds)) and not exists(select 1 from public.events where id in($eventIds)) and not exists(select 1 from public.event_registrations where event_id in($eventIds)))::text;"
  $clean = Invoke-LocalSql $cleanup
  if (($clean -split "`n")[-1] -ne 'true') { throw 'Fixture cleanup failed.' }
  Write-Output 'fixture_cleanup=0'
}
