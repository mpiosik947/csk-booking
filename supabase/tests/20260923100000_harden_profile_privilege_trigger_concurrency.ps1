param(
  [string]$DockerContainerName = 'supabase_db_csk-booking',
  [switch]$ConfirmIsolatedDatabase
)

$ErrorActionPreference = 'Stop'
if (-not $ConfirmIsolatedDatabase) { throw 'Use only an isolated local database.' }

$tenantA = 'c5c00000-0000-4000-8000-000000000001'
$tenantB = [guid]::NewGuid().ToString()
$adminA = [guid]::NewGuid().ToString()
$employeeA = [guid]::NewGuid().ToString()
$ownerA = [guid]::NewGuid().ToString()
$bOnly = [guid]::NewGuid().ToString()
$run = [guid]::NewGuid().ToString('N')
$marker = "[TEST][SAAS-9D-4D-1-RACE][$run]"
$userIds = "'$adminA','$employeeA','$ownerA','$bOnly'"

function Invoke-LocalSql([string]$Sql) {
  $output = $Sql | & docker exec -i $DockerContainerName psql -v ON_ERROR_STOP=1 -U postgres -d postgres -At 2>&1
  if ($LASTEXITCODE -ne 0) { throw "Local SQL failed: $output" }
  return (($output | ForEach-Object { "$_" }) -join "`n").Trim()
}

function Start-LocalSqlJob([string]$Sql) {
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
insert into public.tenants(id,name,slug,status) values('$tenantB','$marker Tenant B','saas9d4d1-race-$($run.Substring(0,12))','dormant');
insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at) values
('$adminA','00000000-0000-0000-0000-000000000000','authenticated','authenticated','9d4d1-admin-$run@example.invalid','',now(),'{}','{}',now(),now()),
('$employeeA','00000000-0000-0000-0000-000000000000','authenticated','authenticated','9d4d1-employee-$run@example.invalid','',now(),'{}','{}',now(),now()),
('$ownerA','00000000-0000-0000-0000-000000000000','authenticated','authenticated','9d4d1-owner-$run@example.invalid','',now(),'{}','{}',now(),now()),
('$bOnly','00000000-0000-0000-0000-000000000000','authenticated','authenticated','9d4d1-b-only-$run@example.invalid','',now(),'{}','{}',now(),now());
insert into public.profiles(id,user_id,email,first_name,last_name,full_name,phone,role,verification_status)
select id,id,email,'Race','Fixture','$marker','500000000','user','pending' from auth.users where id in($userIds)
on conflict(user_id) do nothing;
update public.profiles set role='admin' where user_id='$adminA';
update public.profiles set role='pracownik' where user_id='$employeeA';
insert into public.tenant_memberships(tenant_id,user_id,role,status) values
('$tenantA','$adminA','admin','active'),('$tenantA','$employeeA','employee','active'),('$tenantA','$ownerA','user','active'),
('$tenantB','$bOnly','user','active')
on conflict(tenant_id,user_id) do update set role=excluded.role,status=excluded.status;
delete from public.tenant_memberships where tenant_id='$tenantA' and user_id='$bOnly';
"@

try {
  Invoke-LocalSql $setup | Out-Null
  $deadlocksBefore = [int](Invoke-LocalSql "select deadlocks from pg_stat_database where datname=current_database();")

  $ownerCallA = New-ActorSql $ownerA "select public.update_my_profile_v1('501111111','00-001','Warszawa','A','1',null,true,false,false,false,false,false,false,false,false,false)->>'code'"
  $ownerCallB = New-ActorSql $ownerA "select public.update_my_profile_v1('502222222','00-002','Krakow','B','2',null,false,true,false,false,false,false,false,false,false,false)->>'code'"
  $ownerResults = Receive-Pair (Start-LocalSqlJob $ownerCallA) (Start-LocalSqlJob $ownerCallB)
  if (@($ownerResults | Where-Object ExitCode -ne 0).Count -ne 0 -or @($ownerResults | Where-Object Output -notmatch '(?m)^updated\r?$').Count -ne 0) {
    throw "Concurrent owner updates failed: $($ownerResults | ConvertTo-Json -Compress -Depth 4)"
  }
  $ownerIntegrity = Invoke-LocalSql "select (phone in('501111111','502222222') and city in('Warszawa','Krakow') and role='user' and verification_status='pending')::text from public.profiles where user_id='$ownerA';"
  if ($ownerIntegrity -ne 'true') { throw 'Concurrent owner updates produced an invalid profile state.' }
  Write-Output 'PARALLEL_OWNER_UPDATES=PASS'

  $identityCall = New-ActorSql $adminA "select public.update_profile_identity('$ownerA','Concurrent','Identity')->>'full_name'"
  $contactCall = New-ActorSql $ownerA "select public.update_my_profile_v1('503333333','00-003','Gdansk','C','3',null,true,false,false,false,false,false,false,false,false,false)->>'code'"
  $mixedResults = Receive-Pair (Start-LocalSqlJob $identityCall) (Start-LocalSqlJob $contactCall)
  if (@($mixedResults | Where-Object ExitCode -ne 0).Count -ne 0) { throw "Staff/owner race failed: $($mixedResults | ConvertTo-Json -Compress -Depth 4)" }
  $mixedIntegrity = Invoke-LocalSql "select (first_name='Concurrent' and last_name='Identity' and phone='503333333' and role='user')::text from public.profiles where user_id='$ownerA';"
  if ($mixedIntegrity -ne 'true') { throw 'Staff/owner race lost a valid disjoint update.' }
  Write-Output 'STAFF_VS_OWNER_UPDATE=PASS'

  $allowedCall = New-ActorSql $ownerA "select public.update_my_profile_v1('504444444','00-004','Poznan','D','4',null,false,true,false,false,false,false,false,false,false,false)->>'code'"
  $deniedCall = "begin; select set_config('request.jwt.claims',jsonb_build_object('sub','$ownerA','role','authenticated')::text,true); select set_config('request.jwt.claim.sub','$ownerA',true); update public.profiles set role='admin' where user_id='$ownerA'; commit;"
  $protectedResults = Receive-Pair (Start-LocalSqlJob $allowedCall) (Start-LocalSqlJob $deniedCall)
  if (@($protectedResults | Where-Object ExitCode -eq 0).Count -ne 1 -or ($protectedResults.Output -join "`n") -notmatch '(?m)^updated\r?$') {
    throw "Allowed/protected race did not fail closed: $($protectedResults | ConvertTo-Json -Compress -Depth 4)"
  }
  $protectedIntegrity = Invoke-LocalSql "select (role='user' and phone='504444444')::text from public.profiles where user_id='$ownerA';"
  if ($protectedIntegrity -ne 'true') { throw 'Protected race changed authority or lost the valid owner update.' }
  Write-Output 'ALLOWED_VS_PROTECTED_UPDATE=PASS'
  Write-Output 'PRIVILEGE_ESCALATION=0'

  $crossTenantCall = "begin; select set_config('request.jwt.claims',jsonb_build_object('sub','$adminA','role','authenticated')::text,true); select set_config('request.jwt.claim.sub','$adminA',true); select set_config('csk.profile_contact_rpc_actor','$adminA',true); select set_config('csk.profile_contact_rpc_target','$bOnly',true); update public.profiles set phone='599999999' where user_id='$bOnly'; commit;"
  $crossTenant = Start-LocalSqlJob $crossTenantCall
  Wait-Job $crossTenant | Out-Null
  try { $crossTenantResult = Receive-Job $crossTenant -ErrorAction Stop } finally { Remove-Job $crossTenant -Force }
  if ($crossTenantResult.ExitCode -eq 0) { throw 'Cross-tenant marker spoof unexpectedly succeeded.' }
  $crossIntegrity = Invoke-LocalSql "select ((select phone='500000000' from public.profiles where user_id='$bOnly') and exists(select 1 from public.tenant_memberships where tenant_id='$tenantB' and user_id='$bOnly' and role='user' and status='active') and not exists(select 1 from public.tenant_memberships where tenant_id='$tenantA' and user_id='$bOnly'))::text;"
  if ($crossIntegrity -ne 'true') { throw 'Cross-tenant activity contaminated profile or membership state.' }
  Write-Output 'TENANT_A_B_SIMULTANEOUS_ISOLATION=PASS'
  Write-Output 'CROSS_TENANT_EFFECTS=0'

  $deadlocksAfter = [int](Invoke-LocalSql "select deadlocks from pg_stat_database where datname=current_database();")
  if ($deadlocksAfter -ne $deadlocksBefore) { throw 'A database deadlock was recorded.' }
  Write-Output 'DEADLOCKS=0'
  Write-Output 'LOST_VALID_UPDATES=0'
}
finally {
  $cleanup = @"
delete from public.audit_logs where actor_user_id in($userIds) or target_id in($userIds);
delete from public.tenant_user_admin_notes where user_id in($userIds);
delete from public.tenant_user_verifications where user_id in($userIds);
delete from public.tenant_memberships where user_id in($userIds) or tenant_id='$tenantB';
delete from public.profiles where user_id in($userIds);
delete from public.tenants where id='$tenantB';
delete from auth.users where id in($userIds);
select (not exists(select 1 from auth.users where id in($userIds)) and not exists(select 1 from public.profiles where user_id in($userIds)) and not exists(select 1 from public.tenant_memberships where user_id in($userIds) or tenant_id='$tenantB') and not exists(select 1 from public.tenants where id='$tenantB'))::text;
"@
  $clean = Invoke-LocalSql $cleanup
  if (($clean -split "`n")[-1] -ne 'true') { throw 'Fixture cleanup failed.' }
  Write-Output 'fixture_cleanup=0'
}
