param(
  [Parameter(Mandatory = $true)]
  [string]$DatabaseUrl,

  [string]$PsqlPath = 'psql',

  [string]$DockerContainerName = '',

  [string]$DockerDatabasePassword = '',

  [ValidateRange(3, 20)]
  [int]$HoldSeconds = 6,

  [switch]$ConfirmIsolatedDatabase
)

$ErrorActionPreference = 'Stop'

if (-not $ConfirmIsolatedDatabase) {
  throw 'Concurrency harness is blocked. Re-run only against an isolated non-production database with -ConfirmIsolatedDatabase.'
}

$migrationPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\migrations\20260809130000_add_hierarchy_aware_lane_block_rpcs.sql'))
$marker = '[TEST][6B-4B2][CONCURRENCY]'
$runId = [Guid]::NewGuid().ToString('N').Substring(0, 10)
$workDir = Join-Path $env:TEMP "csk-6b4b2-concurrency-$runId"
New-Item -ItemType Directory -Path $workDir | Out-Null

$ids = @{
  Admin = '6b4b2c00-0000-4000-8000-000000000001'
  User = '6b4b2c00-0000-4000-8000-000000000002'
  RootA = '6b4b2c00-0000-4000-8000-000000000201'
  A1 = '6b4b2c00-0000-4000-8000-000000000202'
  A2 = '6b4b2c00-0000-4000-8000-000000000203'
  RootB = '6b4b2c00-0000-4000-8000-000000000301'
  B1 = '6b4b2c00-0000-4000-8000-000000000302'
  B2 = '6b4b2c00-0000-4000-8000-000000000303'
  UpdateA = '6b4b2c00-0000-4000-8000-000000000401'
  UpdateB = '6b4b2c00-0000-4000-8000-000000000402'
  Activate = '6b4b2c00-0000-4000-8000-000000000403'
}

$migrationIncludePath = $migrationPath
if ($DockerContainerName) {
  $migrationIncludePath = "/tmp/csk-6b4b2-migration-$runId.sql"
  & docker cp $migrationPath "${DockerContainerName}:$migrationIncludePath" | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw 'Failed to copy the migration into the isolated PostgreSQL container.'
  }
}

function Get-PsqlLaunch {
  param([Parameter(Mandatory = $true)][string]$Path)

  if ($DockerContainerName) {
    $containerPath = "/tmp/csk-6b4b2-$runId-$([System.IO.Path]::GetFileName($Path))"
    & docker cp $Path "${DockerContainerName}:$containerPath" | Out-Null
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to copy SQL script into isolated container: $Path"
    }

    $dockerArguments = @('exec')
    if ($DockerDatabasePassword) {
      $dockerArguments += @('-e', "PGPASSWORD=$DockerDatabasePassword")
    }
    $dockerArguments += @(
      $DockerContainerName, 'psql', '--no-psqlrc',
      '--set', 'ON_ERROR_STOP=1', '--dbname', $DatabaseUrl,
      '--file', $containerPath, '--no-align', '--tuples-only'
    )

    return [pscustomobject]@{
      FilePath = 'docker'
      ArgumentList = $dockerArguments
    }
  }

  return [pscustomobject]@{
    FilePath = $PsqlPath
    ArgumentList = @(
      '--no-psqlrc', '--set', 'ON_ERROR_STOP=1', '--dbname', $DatabaseUrl,
      '--file', $Path, '--no-align', '--tuples-only'
    )
  }
}

function Invoke-PsqlFile {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$OutputPath
  )

  $errorPath = "$OutputPath.err"
  $launch = Get-PsqlLaunch -Path $Path
  $process = Start-Process -FilePath $launch.FilePath -ArgumentList $launch.ArgumentList `
    -RedirectStandardOutput $OutputPath -RedirectStandardError $errorPath `
    -Wait -PassThru -NoNewWindow

  return [pscustomobject]@{
    ExitCode = $process.ExitCode
    Output = if (Test-Path $OutputPath) { Get-Content -LiteralPath $OutputPath -Raw } else { '' }
    Error = if (Test-Path $errorPath) { Get-Content -LiteralPath $errorPath -Raw } else { '' }
  }
}

function Start-PsqlFile {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$OutputPath
  )

  $errorPath = "$OutputPath.err"
  $launch = Get-PsqlLaunch -Path $Path
  $process = Start-Process -FilePath $launch.FilePath -ArgumentList $launch.ArgumentList `
    -RedirectStandardOutput $OutputPath -RedirectStandardError $errorPath `
    -PassThru -NoNewWindow

  return [pscustomobject]@{
    Process = $process
    OutputPath = $OutputPath
    ErrorPath = $errorPath
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
set local role authenticated;
create temporary table csk_session_result (
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
  values (v_started, pg_catalog.clock_timestamp(), v_result);
end;
`$session`$;
select 'wait_seconds=' || pg_catalog.round(
  extract(epoch from (finished_at - started_at))::numeric,
  3
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
  $output = if (Test-Path $Run.OutputPath) { Get-Content -LiteralPath $Run.OutputPath -Raw } else { '' }
  $errorText = if (Test-Path $Run.ErrorPath) { Get-Content -LiteralPath $Run.ErrorPath -Raw } else { '' }
  $waitMatch = [regex]::Match($output, 'wait_seconds=([0-9.]+)')
  $resultMatch = [regex]::Match($output, 'result=([^\r\n]+)')
  $json = if ($resultMatch.Success) { $resultMatch.Groups[1].Value | ConvertFrom-Json } else { $null }

  return [pscustomobject]@{
    Completed = $output -match '(?m)^COMMIT\s*$' -and
      [string]::IsNullOrWhiteSpace($errorText)
    Output = $output
    Error = $errorText
    WaitSeconds = if ($waitMatch.Success) {
      [double]::Parse($waitMatch.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)
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
  if ($result.ExitCode -ne 0) {
    throw "$Name failed: $($result.Error)"
  }
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

  $aSqlPath = New-SessionSql -Name "scenario-$Order-a" -UserId $UserA -OperationSql $SqlA -HoldLocks $true
  $bSqlPath = New-SessionSql -Name "scenario-$Order-b" -UserId $UserB -OperationSql $SqlB -HoldLocks $false
  $aRun = Start-PsqlFile -Path $aSqlPath -OutputPath (Join-Path $workDir "scenario-$Order-a.out")
  Start-Sleep -Milliseconds 1200
  $bRun = Start-PsqlFile -Path $bSqlPath -OutputPath (Join-Path $workDir "scenario-$Order-b.out")
  $bResult = Read-SessionResult -Run $bRun
  $aResult = Read-SessionResult -Run $aRun
  $combined = "$($aResult.Output)`n$($bResult.Output)`n$($aResult.Error)`n$($bResult.Error)"
  $deadlock = $combined -match '40P01|deadlock detected'
  $lockTimeout = $combined -match '55P03|lock timeout'
  $rawSqlError = -not $aResult.Completed -or -not $bResult.Completed -or
    $combined -match 'ERROR:\s+[0-9A-Z]{5}:'
  $checkResult = Invoke-Check -Name "scenario-$Order-check" -Sql $CheckSql
  $passed = -not $deadlock -and -not $lockTimeout -and -not $rawSqlError -and
    $null -ne $aResult.Json -and $null -ne $bResult.Json -and
    $aResult.Json.code -eq $ExpectedCodeA -and
    $bResult.Json.code -eq $ExpectedCodeB -and
    $bResult.WaitSeconds -ge $MinimumBWaitSeconds -and
    $bResult.WaitSeconds -le $MaximumBWaitSeconds -and
    $checkResult -match 'check_passed=true'

  return [pscustomobject]@{
    test_order = $Order
    scenario = $Name
    passed = $passed
    session_a_code = if ($aResult.Json) { $aResult.Json.code } else { '<missing>' }
    session_b_code = if ($bResult.Json) { $bResult.Json.code } else { '<missing>' }
    session_b_wait_seconds = $bResult.WaitSeconds
    deadlock_40P01 = $deadlock
    lock_timeout_55P03 = $lockTimeout
    raw_sql_error = $rawSqlError
    final_check = $checkResult
  }
}

$setupPath = New-SqlFile -Name 'setup' -Sql @"
do `$preflight`$
begin
  if pg_catalog.to_regprocedure(
       'public.admin_create_lane_block(uuid,date,time without time zone,time without time zone,text)'
     ) is not null
     or exists (
       select 1 from public.shooting_lanes where name like '$marker%'
     )
     or exists (
       select 1 from auth.users where email like 'test-6b4b2-concurrency-%@example.invalid'
     ) then
    raise exception 'Concurrency preflight found prior RPCs or fixtures.';
  end if;
end;
`$preflight`$;
\ir $($migrationIncludePath.Replace('\','/'))
insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at
) values
  ('$($ids.Admin)','00000000-0000-0000-0000-000000000000','authenticated','authenticated','test-6b4b2-concurrency-admin@example.invalid','',pg_catalog.transaction_timestamp(),'{}'::jsonb,'{}'::jsonb,pg_catalog.transaction_timestamp(),pg_catalog.transaction_timestamp()),
  ('$($ids.User)','00000000-0000-0000-0000-000000000000','authenticated','authenticated','test-6b4b2-concurrency-user@example.invalid','',pg_catalog.transaction_timestamp(),'{}'::jsonb,'{}'::jsonb,pg_catalog.transaction_timestamp(),pg_catalog.transaction_timestamp());
update public.profiles
set role = case when user_id = '$($ids.Admin)'::uuid then 'admin' else 'user' end,
    first_name = '[TEST]', last_name = '6B-4B2-CONCURRENCY',
    full_name = '$marker', email = 'test-6b4b2-concurrency-profile@example.invalid',
    phone = '000000000', verification_status = 'verified'
where user_id in ('$($ids.Admin)'::uuid, '$($ids.User)'::uuid);
insert into public.shooting_lanes (
  id, name, type, description, price_per_hour, is_active,
  max_shooters, booking_step_minutes, display_order, currency_code,
  resource_kind, parent_lane_id, whole_lane_bookable, positions_bookable
) values
  ('$($ids.RootA)','$marker[ROOT-A]','[TEST]','[TEST]',10,true,5,60,9970,'PLN','lane',null,true,true),
  ('$($ids.A1)','$marker[A-1]','[TEST]','[TEST]',10,true,5,60,9971,'PLN','position','$($ids.RootA)',false,false),
  ('$($ids.A2)','$marker[A-2]','[TEST]','[TEST]',10,true,5,60,9972,'PLN','position','$($ids.RootA)',false,false),
  ('$($ids.RootB)','$marker[ROOT-B]','[TEST]','[TEST]',10,true,5,60,9980,'PLN','lane',null,true,true),
  ('$($ids.B1)','$marker[B-1]','[TEST]','[TEST]',10,true,5,60,9981,'PLN','position','$($ids.RootB)',false,false),
  ('$($ids.B2)','$marker[B-2]','[TEST]','[TEST]',10,true,5,60,9982,'PLN','position','$($ids.RootB)',false,false);
insert into public.lane_booking_rules(lane_id, online_bookable, max_people_online)
select id, true, 5 from public.shooting_lanes where name like '$marker%';
insert into public.lane_booking_durations(lane_id, duration_minutes, display_order, is_active)
select id, 60, 1, true from public.shooting_lanes where name like '$marker%';
insert into public.lane_pricing_rules(
  lane_id, day_group, min_shooters, max_shooters,
  label, hourly_price, display_order, is_active
)
select lane.id, group_record.day_group, 1, 5, '$marker', 10, 1, true
from public.shooting_lanes as lane
cross join (values ('mon_thu'::text), ('fri_sun'::text)) as group_record(day_group)
where lane.name like '$marker%';
insert into public.lane_blocks(
  id, lane_id, block_date, start_time, end_time, reason, is_active
) values
  ('$($ids.UpdateA)','$($ids.RootA)',current_date+9004,time '10:00',time '11:00','$marker[S5-A]',false),
  ('$($ids.UpdateB)','$($ids.RootB)',current_date+9004,time '10:00',time '11:00','$marker[S5-B]',false),
  ('$($ids.Activate)','$($ids.A1)',current_date+9005,time '10:00',time '11:00','$marker[S6]',false);
"@

$cleanupPath = New-SqlFile -Name 'cleanup' -Sql @"
begin;
delete from public.audit_logs
where action = 'reservation_created'
  and target_id in (
    select id from public.reservations where reservation_note = '$marker'
  );
delete from public.reservations where reservation_note = '$marker';
delete from public.lane_blocks where reason like '$marker%';
delete from public.lane_pricing_rules
where lane_id in (select id from public.shooting_lanes where name like '$marker%');
delete from public.lane_booking_durations
where lane_id in (select id from public.shooting_lanes where name like '$marker%');
delete from public.lane_booking_rules
where lane_id in (select id from public.shooting_lanes where name like '$marker%');
delete from public.shooting_lanes
where parent_lane_id in (select id from public.shooting_lanes where name like '$marker%');
delete from public.shooting_lanes where name like '$marker%';
delete from public.profiles where user_id in ('$($ids.Admin)'::uuid, '$($ids.User)'::uuid);
delete from auth.users where email like 'test-6b4b2-concurrency-%@example.invalid';
drop function if exists public.admin_create_lane_block(uuid,date,time without time zone,time without time zone,text);
drop function if exists public.admin_update_lane_block(uuid,uuid,date,time without time zone,time without time zone,text,boolean);
drop function if exists public.admin_set_lane_block_active(uuid,boolean);
commit;
select
  'cleanup_passed=' || (
    pg_catalog.to_regprocedure('public.admin_create_lane_block(uuid,date,time without time zone,time without time zone,text)') is null
    and not exists (select 1 from public.shooting_lanes where name like '$marker%')
    and not exists (select 1 from public.lane_blocks where reason like '$marker%')
    and not exists (select 1 from public.reservations where reservation_note = '$marker')
    and not exists (select 1 from auth.users where email like 'test-6b4b2-concurrency-%@example.invalid')
  )::text;
"@

$results = @()
$setupSucceeded = $false
$baseDate = [DateTime]::UtcNow.Date.AddDays(9000)

try {
  $setupResult = Invoke-PsqlFile -Path $setupPath -OutputPath (Join-Path $workDir 'setup.out')
  if ($setupResult.ExitCode -ne 0) {
    throw "Setup failed: $($setupResult.Error)"
  }
  $setupSucceeded = $true

  $d1 = $baseDate.ToString('yyyy-MM-dd')
  $d2 = $baseDate.AddDays(1).ToString('yyyy-MM-dd')
  $d3 = $baseDate.AddDays(2).ToString('yyyy-MM-dd')
  $d4 = $baseDate.AddDays(3).ToString('yyyy-MM-dd')

  $results += Invoke-Scenario 1 'Parent reservation first vs child block' `
    $ids.User "public.create_reservation_v2('$($ids.RootA)',date '$d1',time '10:00',60,1,'6b4b2c00-0000-4000-8000-000000001001','$marker')" 'created' `
    $ids.Admin "public.admin_create_lane_block('$($ids.A1)',date '$d1',time '10:00',time '11:00','$marker[S1]')" 'conflict_reservation' `
    ($HoldSeconds - 2.5) ($HoldSeconds + 8) @"
select 'check_passed=' || (
  (select count(*) from public.reservations where reservation_note='$marker' and reservation_date=date '$d1') = 1
  and (select count(*) from public.lane_blocks where reason='$marker[S1]') = 0
)::text;
"@

  $results += Invoke-Scenario 2 'Child block first vs parent reservation' `
    $ids.Admin "public.admin_create_lane_block('$($ids.A1)',date '$d2',time '10:00',time '11:00','$marker[S2]')" 'created' `
    $ids.User "public.create_reservation_v2('$($ids.RootA)',date '$d2',time '10:00',60,1,'6b4b2c00-0000-4000-8000-000000001002','$marker')" 'lane_blocked' `
    ($HoldSeconds - 2.5) ($HoldSeconds + 8) @"
select 'check_passed=' || (
  (select count(*) from public.lane_blocks where reason='$marker[S2]' and is_active) = 1
  and (select count(*) from public.reservations where reservation_note='$marker' and reservation_date=date '$d2') = 0
)::text;
"@

  $results += Invoke-Scenario 3 'Sibling reservation and block remain independent' `
    $ids.User "public.create_reservation_v2('$($ids.A1)',date '$d3',time '10:00',60,1,'6b4b2c00-0000-4000-8000-000000001003','$marker')" 'created' `
    $ids.Admin "public.admin_create_lane_block('$($ids.A2)',date '$d3',time '10:00',time '11:00','$marker[S3]')" 'created' `
    0 2.5 @"
select 'check_passed=' || (
  (select count(*) from public.reservations where reservation_note='$marker' and reservation_date=date '$d3') = 1
  and (select count(*) from public.lane_blocks where reason='$marker[S3]' and is_active) = 1
)::text;
"@

  $results += Invoke-Scenario 4 'Parent block first vs child reservation' `
    $ids.Admin "public.admin_create_lane_block('$($ids.RootA)',date '$d4',time '10:00',time '11:00','$marker[S4]')" 'created' `
    $ids.User "public.create_reservation_v2('$($ids.A1)',date '$d4',time '10:00',60,1,'6b4b2c00-0000-4000-8000-000000001004','$marker')" 'lane_blocked' `
    ($HoldSeconds - 2.5) ($HoldSeconds + 8) @"
select 'check_passed=' || (
  (select count(*) from public.lane_blocks where reason='$marker[S4]' and is_active) = 1
  and (select count(*) from public.reservations where reservation_note='$marker' and reservation_date=date '$d4') = 0
)::text;
"@

  $results += Invoke-Scenario 5 'Cross-root updates use global family order' `
    $ids.Admin "public.admin_update_lane_block('$($ids.UpdateA)','$($ids.RootB)',current_date+9004,time '10:00',time '11:00','$marker[S5-A]',false)" 'updated' `
    $ids.Admin "public.admin_update_lane_block('$($ids.UpdateB)','$($ids.RootA)',current_date+9004,time '10:00',time '11:00','$marker[S5-B]',false)" 'updated' `
    ($HoldSeconds - 2.5) ($HoldSeconds + 8) @"
select 'check_passed=' || (
  (select lane_id='$($ids.RootB)'::uuid and not is_active from public.lane_blocks where id='$($ids.UpdateA)')
  and (select lane_id='$($ids.RootA)'::uuid and not is_active from public.lane_blocks where id='$($ids.UpdateB)')
)::text;
"@

  $results += Invoke-Scenario 6 'Duplicate activation is idempotent' `
    $ids.Admin "public.admin_set_lane_block_active('$($ids.Activate)',true)" 'activated' `
    $ids.Admin "public.admin_set_lane_block_active('$($ids.Activate)',true)" 'no_change' `
    ($HoldSeconds - 2.5) ($HoldSeconds + 8) @"
select 'check_passed=' || (
  (select is_active from public.lane_blocks where id='$($ids.Activate)')
)::text;
"@
}
finally {
  if ($setupSucceeded) {
    $cleanupResult = Invoke-PsqlFile -Path $cleanupPath -OutputPath (Join-Path $workDir 'cleanup.out')
    if ($cleanupResult.ExitCode -ne 0 -or $cleanupResult.Output -notmatch 'cleanup_passed=true') {
      Write-Error "Cleanup failed: $($cleanupResult.Error) $($cleanupResult.Output)"
    }
  }
}

$results | Format-Table -AutoSize
if ($results.Count -ne 6 -or ($results | Where-Object { -not $_.passed })) {
  throw 'One or more 6B-4B2 concurrency scenarios failed.'
}

Write-Output '6B-4B2 concurrency: 6/6 PASSED'
Write-Output 'deadlock_40P01=false'
Write-Output 'lock_timeout_55P03=false'
Write-Output 'raw_sql_error=false'
Write-Output 'lane_block_audit=not_applicable_current_schema'
Write-Output "Temporary logs: $workDir"
