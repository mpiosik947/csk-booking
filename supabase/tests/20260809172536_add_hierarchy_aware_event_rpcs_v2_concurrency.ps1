param(
  [Parameter(Mandatory = $true)]
  [string]$DatabaseUrl,

  [string]$PsqlPath = 'psql',
  [string]$DockerContainerName = '',
  [string]$DockerDatabasePassword = '',

  [ValidateRange(3, 20)]
  [int]$HoldSeconds = 5,

  [switch]$ConfirmIsolatedDatabase
)

$ErrorActionPreference = 'Stop'

if (-not $ConfirmIsolatedDatabase) {
  throw 'Concurrency harness is blocked. Use only an isolated non-production database.'
}

$migrationPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\migrations\20260809172536_add_hierarchy_aware_event_rpcs_v2.sql'))
$marker = '[TEST][6B-4C1][CONCURRENCY]'
$runId = [Guid]::NewGuid().ToString('N').Substring(0, 10)
$workDir = Join-Path $env:TEMP "csk-6b4c1-concurrency-$runId"
New-Item -ItemType Directory -Path $workDir | Out-Null

$ids = @{
  Admin = '6b4c1c00-0000-4000-8000-000000000001'
  User = '6b4c1c00-0000-4000-8000-000000000002'
  RootA = '6b4c1c00-0000-4000-8000-000000000101'
  A1 = '6b4c1c00-0000-4000-8000-000000000102'
  A2 = '6b4c1c00-0000-4000-8000-000000000103'
  RootB = '6b4c1c00-0000-4000-8000-000000000201'
  B1 = '6b4c1c00-0000-4000-8000-000000000202'
  B2 = '6b4c1c00-0000-4000-8000-000000000203'
  UpdateA = '6b4c1c00-0000-4000-8000-000000000301'
  UpdateB = '6b4c1c00-0000-4000-8000-000000000302'
  Activate = '6b4c1c00-0000-4000-8000-000000000303'
}

$migrationIncludePath = $migrationPath
if ($DockerContainerName) {
  $migrationIncludePath = "/tmp/csk-6b4c1-migration-$runId.sql"
  & docker cp $migrationPath "${DockerContainerName}:$migrationIncludePath" | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw 'Failed to copy the migration into the isolated PostgreSQL container.'
  }
}

function Get-PsqlLaunch {
  param([Parameter(Mandatory = $true)][string]$Path)

  if ($DockerContainerName) {
    $containerPath = "/tmp/csk-6b4c1-$runId-$([System.IO.Path]::GetFileName($Path))"
    & docker cp $Path "${DockerContainerName}:$containerPath" | Out-Null
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to copy SQL script into isolated container: $Path"
    }

    $arguments = @('exec')
    if ($DockerDatabasePassword) {
      $arguments += @('-e', "PGPASSWORD=$DockerDatabasePassword")
    }
    $arguments += @(
      $DockerContainerName, 'psql', '--no-psqlrc',
      '--set', 'ON_ERROR_STOP=1', '--dbname', $DatabaseUrl,
      '--file', $containerPath, '--no-align', '--tuples-only'
    )
    return [pscustomobject]@{ FilePath = 'docker'; ArgumentList = $arguments }
  }

  return [pscustomobject]@{
    FilePath = $PsqlPath
    ArgumentList = @(
      '--no-psqlrc', '--set', 'ON_ERROR_STOP=1', '--dbname', $DatabaseUrl,
      '--file', $Path, '--no-align', '--tuples-only'
    )
  }
}

function New-SqlFile {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$Sql
  )
  $path = Join-Path $workDir "$Name.sql"
  [System.IO.File]::WriteAllText(
    $path,
    "\set ON_ERROR_STOP on`n\set VERBOSITY verbose`n$Sql",
    [System.Text.UTF8Encoding]::new($false)
  )
  return $path
}

function Get-LaunchForFile {
  param([Parameter(Mandatory = $true)][string]$Path)
  return Get-PsqlLaunch -Path $Path
}

function Start-PsqlFile {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$OutputPath
  )
  $launch = Get-LaunchForFile -Path $Path
  $errorPath = "$OutputPath.err"
  $process = Start-Process -FilePath $launch.FilePath -ArgumentList $launch.ArgumentList `
    -RedirectStandardOutput $OutputPath -RedirectStandardError $errorPath `
    -PassThru -NoNewWindow
  # Materialize the process handle before waiting so Windows PowerShell retains ExitCode.
  $null = $process.Handle
  return [pscustomobject]@{
    Process = $process
    OutputPath = $OutputPath
    ErrorPath = $errorPath
  }
}

function Invoke-PsqlFile {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$OutputPath
  )
  $run = Start-PsqlFile -Path $Path -OutputPath $OutputPath
  $run.Process.WaitForExit()
  $run.Process.Refresh()
  return [pscustomobject]@{
    ExitCode = $run.Process.ExitCode
    Output = if (Test-Path $run.OutputPath) { Get-Content -Raw $run.OutputPath } else { '' }
    Error = if (Test-Path $run.ErrorPath) { Get-Content -Raw $run.ErrorPath } else { '' }
  }
}

function New-SessionSql {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$UserId,
    [Parameter(Mandatory = $true)][string]$OperationSql,
    [Parameter(Mandatory = $true)][bool]$HoldLocks
  )
  $sleepSql = if ($HoldLocks) { "select pg_catalog.pg_sleep($HoldSeconds);" } else { '' }
  return New-SqlFile -Name $Name -Sql @"
begin;
set local lock_timeout = '20s';
set local statement_timeout = '45s';
select pg_catalog.set_config(
  'request.jwt.claims',
  pg_catalog.jsonb_build_object('sub','$UserId','role','authenticated')::text,
  true
);
select pg_catalog.set_config('request.jwt.claim.sub', '$UserId', true);
select pg_catalog.set_config('request.jwt.claim.role', 'authenticated', true);
set local role authenticated;
create temporary table csk_session_result(
  started_at timestamptz not null,
  finished_at timestamptz not null,
  rpc_result jsonb not null
) on commit preserve rows;
do `$session`$
declare
  v_started timestamptz := pg_catalog.clock_timestamp();
  v_result jsonb;
begin
  select $OperationSql into v_result;
  insert into pg_temp.csk_session_result
  values(v_started,pg_catalog.clock_timestamp(),v_result);
end;
`$session`$;
select 'wait_seconds=' || pg_catalog.round(
  extract(epoch from (finished_at-started_at))::numeric,3
) from pg_temp.csk_session_result;
select 'result=' || rpc_result::text from pg_temp.csk_session_result;
$sleepSql
commit;
"@
}

function Read-SessionResult {
  param([Parameter(Mandatory = $true)]$Run)
  $Run.Process.WaitForExit()
  $Run.Process.Refresh()
  $output = if (Test-Path $Run.OutputPath) { Get-Content -Raw $Run.OutputPath } else { '' }
  $errorText = if (Test-Path $Run.ErrorPath) { Get-Content -Raw $Run.ErrorPath } else { '' }
  $waitMatch = [regex]::Match($output,'wait_seconds=([0-9.]+)')
  $resultMatch = [regex]::Match($output,'result=([^\r\n]+)')
  $json = if ($resultMatch.Success) { $resultMatch.Groups[1].Value | ConvertFrom-Json } else { $null }
  return [pscustomobject]@{
    Completed = $output -match '(?m)^COMMIT\s*$' -and [string]::IsNullOrWhiteSpace($errorText)
    Output = $output
    Error = $errorText
    WaitSeconds = if ($waitMatch.Success) {
      [double]::Parse($waitMatch.Groups[1].Value,[Globalization.CultureInfo]::InvariantCulture)
    } else { -1 }
    Json = $json
  }
}

function Invoke-Check {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$Sql
  )
  $path = New-SqlFile -Name $Name -Sql $Sql
  $result = Invoke-PsqlFile -Path $path -OutputPath (Join-Path $workDir "$Name.out")
  if ($result.ExitCode -ne 0) { throw "$Name failed: $($result.Error)" }
  return $result.Output.Trim()
}

function Invoke-Scenario {
  param(
    [Parameter(Mandatory = $true)][int]$Order,
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$UserA,
    [Parameter(Mandatory = $true)][string]$SqlA,
    [Parameter(Mandatory = $true)][string]$ExpectedCodeA,
    [Parameter(Mandatory = $true)][string]$UserB,
    [Parameter(Mandatory = $true)][string]$SqlB,
    [Parameter(Mandatory = $true)][string]$ExpectedCodeB,
    [Parameter(Mandatory = $true)][double]$MinimumBWaitSeconds,
    [Parameter(Mandatory = $true)][double]$MaximumBWaitSeconds,
    [Parameter(Mandatory = $true)][string]$CheckSql
  )
  $aPath = New-SessionSql "scenario-$Order-a" $UserA $SqlA $true
  $bPath = New-SessionSql "scenario-$Order-b" $UserB $SqlB $false
  $aRun = Start-PsqlFile $aPath (Join-Path $workDir "scenario-$Order-a.out")
  Start-Sleep -Milliseconds 1200
  $bRun = Start-PsqlFile $bPath (Join-Path $workDir "scenario-$Order-b.out")
  $b = Read-SessionResult $bRun
  $a = Read-SessionResult $aRun
  $combined = "$($a.Output)`n$($b.Output)`n$($a.Error)`n$($b.Error)"
  $deadlock = $combined -match '40P01|deadlock detected'
  $lockTimeout = $combined -match '55P03|lock timeout'
  $serialization = $combined -match '40001|serialization failure'
  $rawSqlError = -not $a.Completed -or -not $b.Completed -or $combined -match 'ERROR:\s+[0-9A-Z]{5}:'
  $check = Invoke-Check "scenario-$Order-check" $CheckSql
  $passed = -not $deadlock -and -not $lockTimeout -and -not $serialization -and -not $rawSqlError `
    -and $null -ne $a.Json -and $null -ne $b.Json `
    -and $a.Json.code -eq $ExpectedCodeA -and $b.Json.code -eq $ExpectedCodeB `
    -and $b.WaitSeconds -ge $MinimumBWaitSeconds -and $b.WaitSeconds -le $MaximumBWaitSeconds `
    -and $check -match 'check_passed=true'
  return [pscustomobject]@{
    test_order = $Order
    scenario = $Name
    passed = $passed
    session_a_code = if ($a.Json) { $a.Json.code } else { '<missing>' }
    session_b_code = if ($b.Json) { $b.Json.code } else { '<missing>' }
    session_b_wait_seconds = $b.WaitSeconds
    deadlock_40P01 = $deadlock
    lock_timeout_55P03 = $lockTimeout
    serialization_failure = $serialization
    raw_sql_error = $rawSqlError
    final_check = $check
  }
}

$setup = New-SqlFile 'setup' @"
do `$preflight`$
begin
  if pg_catalog.to_regprocedure('public.admin_create_event_v2(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])') is not null
     or exists(select 1 from public.shooting_lanes where name like '$marker%')
     or exists(select 1 from auth.users where email like 'test-6b4c1-concurrency-%@example.invalid') then
    raise exception 'Concurrency preflight found existing V2 or fixtures.';
  end if;
end;
`$preflight`$;
\ir $($migrationIncludePath.Replace('\','/'))
insert into auth.users(id,instance_id,aud,role,email,encrypted_password,raw_app_meta_data,raw_user_meta_data,created_at,updated_at) values
  ('$($ids.Admin)','00000000-0000-0000-0000-000000000000','authenticated','authenticated','test-6b4c1-concurrency-admin@example.invalid','','{}','{}',pg_catalog.transaction_timestamp(),pg_catalog.transaction_timestamp()),
  ('$($ids.User)','00000000-0000-0000-0000-000000000000','authenticated','authenticated','test-6b4c1-concurrency-user@example.invalid','','{}','{}',pg_catalog.transaction_timestamp(),pg_catalog.transaction_timestamp());
insert into public.profiles(user_id,role,first_name,last_name,full_name,email,phone,verification_status)
values
  ('$($ids.Admin)','admin','[TEST]','6B-4C1-CONCURRENCY','$marker','test-6b4c1-concurrency-profile@example.invalid','000000000','verified'),
  ('$($ids.User)','user','[TEST]','6B-4C1-CONCURRENCY','$marker','test-6b4c1-concurrency-profile@example.invalid','000000000','verified')
on conflict (user_id) do update set
  role=excluded.role,
  first_name=excluded.first_name,
  last_name=excluded.last_name,
  full_name=excluded.full_name,
  email=excluded.email,
  phone=excluded.phone,
  verification_status=excluded.verification_status;
insert into public.shooting_lanes(id,name,type,description,price_per_hour,is_active,max_shooters,booking_step_minutes,display_order,currency_code,resource_kind,parent_lane_id,whole_lane_bookable,positions_bookable) values
  ('$($ids.RootA)','$marker[ROOT-A]','[TEST]','[TEST]',10,true,5,60,9970,'PLN','lane',null,true,true),
  ('$($ids.A1)','$marker[A1]','[TEST]','[TEST]',10,true,5,60,9971,'PLN','position','$($ids.RootA)',false,false),
  ('$($ids.A2)','$marker[A2]','[TEST]','[TEST]',10,true,5,60,9972,'PLN','position','$($ids.RootA)',false,false),
  ('$($ids.RootB)','$marker[ROOT-B]','[TEST]','[TEST]',10,true,5,60,9980,'PLN','lane',null,true,true),
  ('$($ids.B1)','$marker[B1]','[TEST]','[TEST]',10,true,5,60,9981,'PLN','position','$($ids.RootB)',false,false),
  ('$($ids.B2)','$marker[B2]','[TEST]','[TEST]',10,true,5,60,9982,'PLN','position','$($ids.RootB)',false,false);
insert into public.lane_booking_rules(lane_id,online_bookable,max_people_online)
select id,true,5 from public.shooting_lanes where name like '$marker%';
insert into public.lane_booking_durations(lane_id,duration_minutes,display_order,is_active)
select id,60,1,true from public.shooting_lanes where name like '$marker%';
insert into public.lane_pricing_rules(lane_id,day_group,min_shooters,max_shooters,label,hourly_price,display_order,is_active)
select lane.id,day_group.value,1,5,'$marker',10,1,true
from public.shooting_lanes lane
cross join (values('mon_thu'::text),('fri_sun'::text)) day_group(value)
where lane.name like '$marker%';
insert into public.events(id,title,description,event_date,start_time,end_time,location,price,max_participants,is_active) values
  ('$($ids.UpdateA)','$marker[UPDATE-A]','$marker',current_date+7007,time '10:00',time '11:00','$marker',10,10,true),
  ('$($ids.UpdateB)','$marker[UPDATE-B]','$marker',current_date+7008,time '10:00',time '11:00','$marker',10,10,true),
  ('$($ids.Activate)','$marker[ACTIVATE]','$marker',current_date+7011,time '10:00',time '11:00','$marker',10,10,false);
insert into public.event_lanes(event_id,lane_id) values
  ('$($ids.UpdateA)','$($ids.RootA)'),
  ('$($ids.UpdateB)','$($ids.RootB)'),
  ('$($ids.Activate)','$($ids.A1)');
"@

$cleanup = New-SqlFile 'cleanup' @"
begin;
delete from public.audit_logs where action='reservation_created' and target_id in (select id from public.reservations where reservation_note='$marker');
delete from public.reservations where reservation_note='$marker';
delete from public.lane_blocks where reason like '$marker%';
delete from public.events where title like '$marker%';
delete from public.lane_pricing_rules where lane_id in (select id from public.shooting_lanes where name like '$marker%');
delete from public.lane_booking_durations where lane_id in (select id from public.shooting_lanes where name like '$marker%');
delete from public.lane_booking_rules where lane_id in (select id from public.shooting_lanes where name like '$marker%');
delete from public.shooting_lanes where parent_lane_id in (select id from public.shooting_lanes where name like '$marker%');
delete from public.shooting_lanes where name like '$marker%';
delete from public.profiles where user_id in ('$($ids.Admin)'::uuid,'$($ids.User)'::uuid);
delete from auth.users where email like 'test-6b4c1-concurrency-%@example.invalid';
drop function if exists public.admin_create_event_v2(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[]);
drop function if exists public.admin_update_event_v2(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[]);
drop function if exists public.admin_set_event_active_v2(uuid,boolean);
commit;
select 'cleanup_passed=' || (
  pg_catalog.to_regprocedure('public.admin_create_event_v2(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])') is null
  and not exists(select 1 from public.events where title like '$marker%')
  and not exists(select 1 from public.shooting_lanes where name like '$marker%')
  and not exists(select 1 from public.reservations where reservation_note='$marker')
  and not exists(select 1 from public.lane_blocks where reason like '$marker%')
  and not exists(select 1 from auth.users where email like 'test-6b4c1-concurrency-%@example.invalid')
)::text;
"@

$results = @()
$setupSucceeded = $false
try {
  $setupResult = Invoke-PsqlFile $setup (Join-Path $workDir 'setup.out')
  if ($setupResult.ExitCode -ne 0) { throw "Setup failed: $($setupResult.Error)" }
  $setupSucceeded = $true

  $createEvent = {
    param($title,$dateOffset,$lanes)
    "public.admin_create_event_v2('$marker[$title]','$marker',current_date+$dateOffset,time '10:00',time '11:00','$marker',10,10,array[$lanes]::uuid[])"
  }
  $createReservation = {
    param($lane,$dateOffset,$request)
    "public.create_reservation_v2('$lane',current_date+$dateOffset,time '10:00',60,1,'$request','$marker')"
  }

  $results += Invoke-Scenario 1 'parent reservation first vs child event' $ids.User `
    (&$createReservation $ids.RootA 7001 '6b4c1c00-0000-4000-8000-000000001001') 'created' $ids.Admin `
    (&$createEvent 'S1' 7001 "'$($ids.A1)'") 'reservation_conflict' ($HoldSeconds-2.5) ($HoldSeconds+8) `
    "select 'check_passed='||((select count(*) from public.reservations where reservation_note='$marker' and reservation_date=current_date+7001)=1 and not exists(select 1 from public.events where title='$marker[S1]'))::text;"

  $results += Invoke-Scenario 2 'child event first vs parent reservation' $ids.Admin `
    (&$createEvent 'S2' 7002 "'$($ids.A1)'") 'created' $ids.User `
    (&$createReservation $ids.RootA 7002 '6b4c1c00-0000-4000-8000-000000001002') 'slot_unavailable' ($HoldSeconds-2.5) ($HoldSeconds+8) `
    "select 'check_passed='||(exists(select 1 from public.events where title='$marker[S2]') and not exists(select 1 from public.reservations where reservation_note='$marker' and reservation_date=current_date+7002))::text;"

  $results += Invoke-Scenario 3 'child siblings reservation and event' $ids.User `
    (&$createReservation $ids.A1 7003 '6b4c1c00-0000-4000-8000-000000001003') 'created' $ids.Admin `
    (&$createEvent 'S3' 7003 "'$($ids.A2)'") 'created' 0 2.5 `
    "select 'check_passed='||((select count(*) from public.reservations where reservation_note='$marker' and reservation_date=current_date+7003)=1 and exists(select 1 from public.events where title='$marker[S3]'))::text;"

  $results += Invoke-Scenario 4 'parent block first vs child event' $ids.Admin `
    "public.admin_create_lane_block('$($ids.RootA)',current_date+7004,time '10:00',time '11:00','$marker[S4]')" 'created' $ids.Admin `
    (&$createEvent 'S4' 7004 "'$($ids.A1)'") 'lane_block_conflict' ($HoldSeconds-2.5) ($HoldSeconds+8) `
    "select 'check_passed='||(exists(select 1 from public.lane_blocks where reason='$marker[S4]') and not exists(select 1 from public.events where title='$marker[S4]'))::text;"

  $results += Invoke-Scenario 5 'child event first vs parent block' $ids.Admin `
    (&$createEvent 'S5' 7005 "'$($ids.A1)'") 'created' $ids.Admin `
    "public.admin_create_lane_block('$($ids.RootA)',current_date+7005,time '10:00',time '11:00','$marker[S5]')" 'conflict_event' ($HoldSeconds-2.5) ($HoldSeconds+8) `
    "select 'check_passed='||(exists(select 1 from public.events where title='$marker[S5]') and not exists(select 1 from public.lane_blocks where reason='$marker[S5]'))::text;"

  $results += Invoke-Scenario 6 'child sibling block and event' $ids.Admin `
    "public.admin_create_lane_block('$($ids.A1)',current_date+7006,time '10:00',time '11:00','$marker[S6]')" 'created' $ids.Admin `
    (&$createEvent 'S6' 7006 "'$($ids.A2)'") 'created' 0 2.5 `
    "select 'check_passed='||(exists(select 1 from public.lane_blocks where reason='$marker[S6]') and exists(select 1 from public.events where title='$marker[S6]'))::text;"

  $results += Invoke-Scenario 7 'multi-root input permutations' $ids.Admin `
    (&$createEvent 'S7-A' 7012 "'$($ids.RootA)','$($ids.RootB)'") 'created' $ids.Admin `
    (&$createEvent 'S7-B' 7012 "'$($ids.RootB)','$($ids.RootA)'") 'event_conflict' ($HoldSeconds-2.5) ($HoldSeconds+8) `
    "select 'check_passed='||((select count(*) from public.events where title in ('$marker[S7-A]','$marker[S7-B]'))=1)::text;"

  $updateA = "public.admin_update_event_v2('$($ids.UpdateA)','$marker[UPDATE-A2]','$marker',current_date+7008,time '11:00',time '12:00','$marker',10,10,array['$($ids.RootB)']::uuid[])"
  $updateB = "public.admin_update_event_v2('$($ids.UpdateB)','$marker[UPDATE-B2]','$marker',current_date+7009,time '11:00',time '12:00','$marker',10,10,array['$($ids.RootA)']::uuid[])"
  $results += Invoke-Scenario 8 'cross-root updates' $ids.Admin $updateA 'updated' $ids.Admin $updateB 'updated' ($HoldSeconds-2.5) ($HoldSeconds+8) `
    "select 'check_passed='||((select lane_id='$($ids.RootB)' from public.event_lanes where event_id='$($ids.UpdateA)') and (select lane_id='$($ids.RootA)' from public.event_lanes where event_id='$($ids.UpdateB)'))::text;"

  $results += Invoke-Scenario 9 'parent event vs child event' $ids.Admin `
    (&$createEvent 'S9-A' 7009 "'$($ids.RootA)'") 'created' $ids.Admin `
    (&$createEvent 'S9-B' 7009 "'$($ids.A1)'") 'event_conflict' ($HoldSeconds-2.5) ($HoldSeconds+8) `
    "select 'check_passed='||((select count(*) from public.events where title in ('$marker[S9-A]','$marker[S9-B]'))=1)::text;"

  $results += Invoke-Scenario 10 'child sibling events' $ids.Admin `
    (&$createEvent 'S10-A' 7010 "'$($ids.A1)'") 'created' $ids.Admin `
    (&$createEvent 'S10-B' 7010 "'$($ids.A2)'") 'created' 0 2.5 `
    "select 'check_passed='||((select count(*) from public.events where title in ('$marker[S10-A]','$marker[S10-B]'))=2)::text;"

  $activate = "public.admin_set_event_active_v2('$($ids.Activate)',true)"
  $results += Invoke-Scenario 11 'simultaneous activation same event' $ids.Admin $activate 'activated' $ids.Admin $activate 'no_change' ($HoldSeconds-2.5) ($HoldSeconds+8) `
    "select 'check_passed='||(select is_active from public.events where id='$($ids.Activate)')::text;"
}
finally {
  if ($setupSucceeded) {
    $cleanupResult = Invoke-PsqlFile $cleanup (Join-Path $workDir 'cleanup.out')
    if ($cleanupResult.ExitCode -ne 0 -or $cleanupResult.Output -notmatch 'cleanup_passed=true') {
      Write-Error "Cleanup failed: $($cleanupResult.Error) $($cleanupResult.Output)"
    }
  }
}

$results | Format-Table -AutoSize
if ($results.Count -ne 11 -or ($results | Where-Object { -not $_.passed })) {
  throw 'One or more 6B-4C1 concurrency scenarios failed.'
}

Write-Output '6B-4C1 concurrency: 11/11 PASSED'
Write-Output 'deadlock_40P01=false'
Write-Output 'lock_timeout_55P03=false'
Write-Output 'serialization_failure=false'
Write-Output 'raw_sql_error=false'
Write-Output 'cleanup_complete=true'
Write-Output "Temporary logs: $workDir"
