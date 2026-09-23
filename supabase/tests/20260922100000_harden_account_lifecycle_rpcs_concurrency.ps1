param(
  [string]$DockerContainerName = 'supabase_db_csk-booking',
  [switch]$ConfirmIsolatedDatabase
)

$ErrorActionPreference = 'Stop'
if (-not $ConfirmIsolatedDatabase) { throw 'Use only an isolated local database.' }

$tenantA = 'c5c00000-0000-4000-8000-000000000001'
$tenantB = [guid]::NewGuid().ToString()
$ownerUpdate = [guid]::NewGuid().ToString()
$ownerDelete = [guid]::NewGuid().ToString()
$ownerRace = [guid]::NewGuid().ToString()
$adminA = [guid]::NewGuid().ToString()
$adminB = [guid]::NewGuid().ToString()
$run = [guid]::NewGuid().ToString('N')
$marker = "[TEST][SAAS-9D-4C-RACE][$run]"
$userIds = "'$ownerUpdate','$ownerDelete','$ownerRace','$adminA','$adminB'"

function Invoke-LocalSql([string]$Sql) {
  $output = $Sql | & docker exec -i $DockerContainerName psql -v ON_ERROR_STOP=1 -U postgres -d postgres -At
  if ($LASTEXITCODE -ne 0) { throw "Local SQL failed: $output" }
  return ($output -join "`n").Trim()
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
insert into public.tenants(id,name,slug,status) values('$tenantB','$marker Tenant B','saas9d4c-race-$($run.Substring(0,12))','dormant');
insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at) values
('$ownerUpdate','00000000-0000-0000-0000-000000000000','authenticated','authenticated','9d4c-update-$run@example.invalid','',now(),'{}','{}',now(),now()),
('$ownerDelete','00000000-0000-0000-0000-000000000000','authenticated','authenticated','9d4c-delete-$run@example.invalid','',now(),'{}','{}',now(),now()),
('$ownerRace','00000000-0000-0000-0000-000000000000','authenticated','authenticated','9d4c-race-$run@example.invalid','',now(),'{}','{}',now(),now()),
('$adminA','00000000-0000-0000-0000-000000000000','authenticated','authenticated','9d4c-admin-a-$run@example.invalid','',now(),'{}','{}',now(),now()),
('$adminB','00000000-0000-0000-0000-000000000000','authenticated','authenticated','9d4c-admin-b-$run@example.invalid','',now(),'{}','{}',now(),now());
insert into public.profiles(user_id,email,full_name,phone,role)
select id,email,'$marker','000','user' from auth.users where id in($userIds)
on conflict(user_id) do update set email=excluded.email,full_name=excluded.full_name,phone=excluded.phone,role=excluded.role;
update public.profiles set role='admin' where user_id in('$adminA','$adminB');
insert into public.tenant_memberships(tenant_id,user_id,role,status) values
('$tenantA','$ownerUpdate','user','active'),('$tenantB','$ownerUpdate','user','active'),
('$tenantA','$ownerDelete','user','active'),('$tenantB','$ownerDelete','user','active'),
('$tenantA','$ownerRace','user','active'),('$tenantB','$ownerRace','user','active'),
('$tenantA','$adminA','admin','active'),('$tenantB','$adminB','admin','active')
on conflict(tenant_id,user_id) do update set role=excluded.role,status=excluded.status;
insert into public.tenant_user_verifications(tenant_id,user_id,verification_status,permissions_verified) values
('$tenantA','$ownerUpdate','verified',true),('$tenantB','$ownerUpdate','verified',true),
('$tenantA','$ownerDelete','verified',true),('$tenantB','$ownerDelete','verified',true)
on conflict(tenant_id,user_id) do update set verification_status=excluded.verification_status,permissions_verified=excluded.permissions_verified;
insert into public.tenant_user_verifications(tenant_id,user_id,verification_status,permissions_verified) values
('$tenantA','$ownerRace','verified',true),('$tenantB','$ownerRace','verified',true)
on conflict(tenant_id,user_id) do update set verification_status=excluded.verification_status,permissions_verified=excluded.permissions_verified;
"@

try {
  Invoke-LocalSql $setup | Out-Null
  $deadlocksBefore = [int](Invoke-LocalSql "select deadlocks from pg_stat_database where datname=current_database();")

  $update1 = New-ActorSql $ownerUpdate "select public.update_my_profile_v2('501111111','00-001','Warszawa','A','1',null,true,false,false,false,false,false,false,false,false,false)->>'code'"
  $update2 = New-ActorSql $ownerUpdate "select public.update_my_profile_v2('502222222','00-002','Krakow','B','2',null,false,true,false,false,false,false,false,false,false,false)->>'code'"
  $updateResults = Receive-Pair (Start-LocalSqlJob $update1) (Start-LocalSqlJob $update2)
  if (@($updateResults | Where-Object ExitCode -ne 0).Count -ne 0 -or ($updateResults.Output -join "`n") -notmatch '(?m)^updated\r?$') {
    throw "Concurrent owner updates failed: $($updateResults | ConvertTo-Json -Compress -Depth 4)"
  }
  $updateIntegrity = Invoke-LocalSql "select ((select count(*)=2 from public.tenant_user_verifications where user_id='$ownerUpdate' and verification_status='pending' and not permissions_verified) and (select count(*)=2 from public.audit_logs where action='tenant_user_verification_invalidated' and target_id='$ownerUpdate'))::text;"
  if ($updateIntegrity -ne 'true') { throw 'Concurrent updates broke tenant invalidation/audit invariants.' }
  Write-Output 'CONCURRENT_OWNER_UPDATES=PASS'
  Write-Output 'TENANT_INVALIDATION_AUDITS=2'

  $activityCall = New-ActorSql $ownerRace "select public.update_my_profile_v2('503333333','00-003','Gdansk','C','3',null,true,false,false,false,false,false,false,false,false,false)->>'code'"
  $activityDeleteCall = New-ActorSql $ownerRace "select public.anonymize_my_account_v1()->>'code'"
  $activityResults = Receive-Pair (Start-LocalSqlJob $activityCall) (Start-LocalSqlJob $activityDeleteCall)
  if (@($activityResults | Where-Object ExitCode -ne 0).Count -ne 0) { throw "Account/tenant-activity race failed: $($activityResults | ConvertTo-Json -Compress -Depth 4)" }
  $activityJoined = $activityResults.Output -join "`n"
  if ($activityJoined -notmatch '(?m)^anonymized\r?$' -or $activityJoined -notmatch '(?m)^(updated|profile_not_found)\r?$') { throw "Account/tenant-activity race returned an unexpected state: $activityJoined" }
  $activityIntegrity = Invoke-LocalSql "select ((select count(*)=0 from public.profiles where user_id='$ownerRace') and (select count(*)=0 from public.tenant_memberships where user_id='$ownerRace') and (select count(*)=0 from public.tenant_user_verifications where user_id='$ownerRace'))::text;"
  if ($activityIntegrity -ne 'true') { throw 'Account/tenant-activity race left orphan lifecycle rows.' }
  Write-Output 'ANONYMIZE_VS_TENANT_ACTIVITY=PASS'
  Write-Output 'ORPHAN_TENANT_RELATIONSHIPS=0'

  $deleteCall = New-ActorSql $ownerDelete "select public.anonymize_my_account_v1()->>'code'"
  $deleteResults = Receive-Pair (Start-LocalSqlJob $deleteCall) (Start-LocalSqlJob $deleteCall)
  if (@($deleteResults | Where-Object ExitCode -ne 0).Count -ne 0) { throw "Concurrent anonymization failed: $($deleteResults | ConvertTo-Json -Compress -Depth 4)" }
  $deleteJoined = $deleteResults.Output -join "`n"
  if ($deleteJoined -notmatch '(?m)^anonymized\r?$' -or $deleteJoined -notmatch '(?m)^already_anonymized\r?$') { throw "Concurrent anonymization was not idempotent: $deleteJoined" }
  $deleteIntegrity = Invoke-LocalSql "select ((select count(*)=0 from public.profiles where user_id='$ownerDelete') and (select count(*)=0 from public.tenant_memberships where user_id='$ownerDelete') and (select count(*)=0 from public.tenant_user_verifications where user_id='$ownerDelete') and (select count(*)=1 from public.audit_logs where action='account_anonymized' and target_id=(substr(md5('$ownerDelete'||':csk-sec009-v1'),1,8)||'-'||substr(md5('$ownerDelete'||':csk-sec009-v1'),9,4)||'-'||substr(md5('$ownerDelete'||':csk-sec009-v1'),13,4)||'-'||substr(md5('$ownerDelete'||':csk-sec009-v1'),17,4)||'-'||substr(md5('$ownerDelete'||':csk-sec009-v1'),21,12))::uuid))::text;"
  if ($deleteIntegrity -ne 'true') { throw 'Concurrent anonymization broke lifecycle invariants.' }
  Write-Output 'CONCURRENT_ANONYMIZE_RETRY=PASS'
  Write-Output 'ACCOUNT_ANONYMIZED_AUDIT=1'

  $deadlocksAfter = [int](Invoke-LocalSql "select deadlocks from pg_stat_database where datname=current_database();")
  if ($deadlocksAfter -ne $deadlocksBefore) { throw 'A database deadlock was recorded.' }
  Write-Output 'DEADLOCKS=0'
  Write-Output 'CROSS_TENANT_CONTAMINATION=0'
}
finally {
  $cleanup = @"
with pseudonym as(
  select (substr(md5(source.user_id||':csk-sec009-v1'),1,8)||'-'||substr(md5(source.user_id||':csk-sec009-v1'),9,4)||'-'||substr(md5(source.user_id||':csk-sec009-v1'),13,4)||'-'||substr(md5(source.user_id||':csk-sec009-v1'),17,4)||'-'||substr(md5(source.user_id||':csk-sec009-v1'),21,12))::uuid id
  from (values('$ownerDelete'),('$ownerRace')) source(user_id)
) delete from public.audit_logs where target_id in('$ownerUpdate'::uuid,'$ownerDelete'::uuid,'$ownerRace'::uuid) or target_id in(select id from pseudonym) or actor_user_id in(select id from pseudonym);
delete from public.tenant_user_admin_notes where user_id in($userIds);
delete from public.tenant_user_verifications where user_id in($userIds);
delete from public.tenant_memberships where user_id in($userIds) or tenant_id='$tenantB';
delete from public.profiles where user_id in($userIds);
delete from public.tenants where id='$tenantB';
delete from auth.users where id in($userIds);
select (not exists(select 1 from auth.users where id in($userIds)) and not exists(select 1 from public.tenants where id='$tenantB') and not exists(select 1 from public.audit_logs where target_id='$ownerUpdate'))::text;
"@
  $clean = Invoke-LocalSql $cleanup
  if (($clean -split "`n")[-1] -ne 'true') { throw 'Fixture cleanup failed.' }
  Write-Output 'fixture_cleanup=0'
}
