param(
  [Parameter(Mandatory = $true)]
  [string]$DatabaseUrl,

  [string]$PsqlPath = 'psql',

  [string]$DockerContainerName = '',

  [ValidateRange(3, 30)]
  [int]$HoldSeconds = 8,

  [switch]$ConfirmIsolatedDatabase
)

$ErrorActionPreference = 'Stop'

if (-not $ConfirmIsolatedDatabase) {
  throw 'Concurrency harness is blocked. Re-run only against an isolated non-production database with -ConfirmIsolatedDatabase.'
}

$migrationPath = Join-Path $PSScriptRoot '..\migrations\20260809120000_add_multi_family_lane_lock_helper.sql'
$migrationPath = [System.IO.Path]::GetFullPath($migrationPath)
$runId = [Guid]::NewGuid().ToString('N').Substring(0, 10)
$workDir = Join-Path $env:TEMP "csk-6b4b1-concurrency-$runId"
New-Item -ItemType Directory -Path $workDir | Out-Null

$migrationIncludePath = $migrationPath
if ($DockerContainerName) {
  $migrationIncludePath = "/tmp/csk-6b4b1-migration-$runId.sql"
  & docker cp $migrationPath "${DockerContainerName}:$migrationIncludePath" | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw 'Failed to copy the migration into the isolated PostgreSQL container.'
  }
}

$ids = @{
  RootA = '6b4b1c00-0000-4000-8000-000000000201'
  A1 = '6b4b1c00-0000-4000-8000-000000000202'
  A2 = '6b4b1c00-0000-4000-8000-000000000203'
  RootB = '6b4b1c00-0000-4000-8000-000000000301'
  B1 = '6b4b1c00-0000-4000-8000-000000000302'
  B2 = '6b4b1c00-0000-4000-8000-000000000303'
}

function Get-PsqlLaunch {
  param(
    [Parameter(Mandatory = $true)][string]$Path
  )

  if ($DockerContainerName) {
    $containerPath = "/tmp/csk-6b4b1-$runId-$([System.IO.Path]::GetFileName($Path))"
    & docker cp $Path "${DockerContainerName}:$containerPath" | Out-Null
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to copy SQL script into isolated container: $Path"
    }

    return [pscustomobject]@{
      FilePath = 'docker'
      ArgumentList = @(
        'exec', $DockerContainerName, 'psql',
        '--no-psqlrc', '--set', 'ON_ERROR_STOP=1', '--dbname', $DatabaseUrl,
        '--file', $containerPath, '--no-align', '--tuples-only'
      )
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

function New-SessionSql {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string[]]$RequestedIds,
    [Parameter(Mandatory = $true)][bool]$HoldLocks
  )

  $arraySql = ($RequestedIds | ForEach-Object { "'$_'::uuid" }) -join ','
  $sleepSql = if ($HoldLocks) { "select pg_catalog.pg_sleep($HoldSeconds);" } else { '' }
  $path = Join-Path $workDir "$Name.sql"
  $sql = @"
\set ON_ERROR_STOP on
\set VERBOSITY verbose
begin;
set local lock_timeout = '20s';
set local statement_timeout = '45s';
create temporary table csk_session_timing (
  started_at timestamptz not null default pg_catalog.clock_timestamp(),
  finished_at timestamptz
) on commit preserve rows;
insert into pg_temp.csk_session_timing default values;
create temporary table csk_session_result on commit preserve rows as
select *
from public.lock_lane_conflict_families_v1(array[$arraySql]::uuid[]);
update pg_temp.csk_session_timing set finished_at = pg_catalog.clock_timestamp();
select 'wait_seconds=' || pg_catalog.round(
  extract(epoch from (finished_at - started_at))::numeric,
  3
) from pg_temp.csk_session_timing;
select 'result=' || coalesce(
  pg_catalog.jsonb_agg(
    pg_catalog.to_jsonb(result_record)
    order by result_record.root_lane_id, result_record.requested_lane_id
  )::text,
  '[]'
)
from pg_temp.csk_session_result as result_record;
$sleepSql
commit;
"@
  Set-Content -LiteralPath $path -Value $sql -Encoding utf8
  return $path
}

function Invoke-Scenario {
  param(
    [Parameter(Mandatory = $true)][int]$Order,
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string[]]$SessionAIds,
    [Parameter(Mandatory = $true)][string[]]$SessionBIds,
    [Parameter(Mandatory = $true)][double]$MaximumBWaitSeconds,
    [Parameter(Mandatory = $true)][double]$MinimumBWaitSeconds,
    [bool]$RequireEqualResults = $false
  )

  $aSql = New-SessionSql -Name "scenario-$Order-a" -RequestedIds $SessionAIds -HoldLocks $true
  $bSql = New-SessionSql -Name "scenario-$Order-b" -RequestedIds $SessionBIds -HoldLocks $false
  $aOutput = Join-Path $workDir "scenario-$Order-a.out"
  $bOutput = Join-Path $workDir "scenario-$Order-b.out"

  $aRun = Start-PsqlFile -Path $aSql -OutputPath $aOutput
  Start-Sleep -Milliseconds 1200
  $bRun = Start-PsqlFile -Path $bSql -OutputPath $bOutput
  $bRun.Process.WaitForExit()
  $aRun.Process.WaitForExit()
  $bRun.Process.Refresh()
  $aRun.Process.Refresh()

  $aText = if (Test-Path $aOutput) { Get-Content -LiteralPath $aOutput -Raw } else { '' }
  $bText = if (Test-Path $bOutput) { Get-Content -LiteralPath $bOutput -Raw } else { '' }
  $aError = if (Test-Path $aRun.ErrorPath) { Get-Content -LiteralPath $aRun.ErrorPath -Raw } else { '' }
  $bError = if (Test-Path $bRun.ErrorPath) { Get-Content -LiteralPath $bRun.ErrorPath -Raw } else { '' }
  $waitMatch = [regex]::Match($bText, 'wait_seconds=([0-9.]+)')
  $waitSeconds = if ($waitMatch.Success) { [double]::Parse($waitMatch.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture) } else { -1 }
  $combined = "$aText`n$bText`n$aError`n$bError"
  $deadlock = $combined -match '40P01|deadlock detected'
  $lockTimeout = $combined -match '55P03|lock timeout'
  $otherSqlStates = @(
    [regex]::Matches($combined, 'ERROR:\s+([0-9A-Z]{5}):') |
      ForEach-Object { $_.Groups[1].Value } |
      Where-Object { $_ -notin @('40P01', '55P03') } |
      Sort-Object -Unique
  )
  $aResult = [regex]::Match($aText, 'result=(.+)').Groups[1].Value
  $bResult = [regex]::Match($bText, 'result=(.+)').Groups[1].Value
  $aSessionCompleted = [string]::IsNullOrWhiteSpace($aError) -and
    $aText -match 'wait_seconds=[0-9.]+' -and
    $aResult -ne '' -and
    $aText -match '(?m)^COMMIT\s*$'
  $bSessionCompleted = [string]::IsNullOrWhiteSpace($bError) -and
    $bText -match 'wait_seconds=[0-9.]+' -and
    $bResult -ne '' -and
    $bText -match '(?m)^COMMIT\s*$'
  $aExit = if ($aSessionCompleted) { 0 } else { 1 }
  $bExit = if ($bSessionCompleted) { 0 } else { 1 }
  $stableResult = -not $RequireEqualResults -or $aResult -eq $bResult
  $passed = $aSessionCompleted -and $bSessionCompleted -and
    -not $deadlock -and -not $lockTimeout -and
    $otherSqlStates.Count -eq 0 -and
    $waitSeconds -ge $MinimumBWaitSeconds -and $waitSeconds -le $MaximumBWaitSeconds -and
    $stableResult

  return [pscustomobject]@{
    test_order = $Order
    scenario = $Name
    passed = $passed
    session_a_exit = $aExit
    session_b_exit = $bExit
    session_b_wait_seconds = $waitSeconds
    deadlock_40P01 = $deadlock
    lock_timeout_55P03 = $lockTimeout
    other_sqlstates = ($otherSqlStates -join ',')
    stable_result = $stableResult
    session_a_result = $aResult
    session_b_result = $bResult
  }
}

$setupPath = Join-Path $workDir 'setup.sql'
$cleanupPath = Join-Path $workDir 'cleanup.sql'
$results = @()

$setupSql = @"
\set ON_ERROR_STOP on
do `$preflight`$
begin
  if pg_catalog.to_regprocedure('public.lock_lane_conflict_families_v1(uuid[])') is not null
     or exists (select 1 from public.shooting_lanes where name like '[TEST][6B-4B1][CONCURRENCY]%') then
    raise exception 'Concurrency fixture or helper already exists.';
  end if;
end;
`$preflight`$;
\ir $($migrationIncludePath.Replace('\','/'))
insert into public.shooting_lanes (
  id, name, type, description, price_per_hour, is_active,
  max_shooters, booking_step_minutes, display_order, currency_code,
  resource_kind, parent_lane_id, whole_lane_bookable, positions_bookable
) values
  ('$($ids.RootA)','[TEST][6B-4B1][CONCURRENCY][ROOT-A]','[TEST]','[TEST]',10,false,5,60,9950,'PLN','lane',null,false,true),
  ('$($ids.RootB)','[TEST][6B-4B1][CONCURRENCY][ROOT-B]','[TEST]','[TEST]',10,false,5,60,9960,'PLN','lane',null,false,true),
  ('$($ids.A1)','[TEST][6B-4B1][CONCURRENCY][A-1]','[TEST]','[TEST]',10,false,1,60,9951,'PLN','position','$($ids.RootA)',false,false),
  ('$($ids.A2)','[TEST][6B-4B1][CONCURRENCY][A-2]','[TEST]','[TEST]',10,false,1,60,9952,'PLN','position','$($ids.RootA)',false,false),
  ('$($ids.B1)','[TEST][6B-4B1][CONCURRENCY][B-1]','[TEST]','[TEST]',10,false,1,60,9961,'PLN','position','$($ids.RootB)',false,false),
  ('$($ids.B2)','[TEST][6B-4B1][CONCURRENCY][B-2]','[TEST]','[TEST]',10,false,1,60,9962,'PLN','position','$($ids.RootB)',false,false);
"@
Set-Content -LiteralPath $setupPath -Value $setupSql -Encoding utf8

$cleanupSql = @"
\set ON_ERROR_STOP on
begin;
delete from public.shooting_lanes
where name like '[TEST][6B-4B1][CONCURRENCY]%';
drop function if exists public.lock_lane_conflict_families_v1(uuid[]);
commit;
select
  pg_catalog.to_regprocedure('public.lock_lane_conflict_families_v1(uuid[])') is null as helper_removed,
  not exists (
    select 1 from public.shooting_lanes
    where name like '[TEST][6B-4B1][CONCURRENCY]%'
  ) as fixtures_removed;
"@
Set-Content -LiteralPath $cleanupPath -Value $cleanupSql -Encoding utf8

try {
  $setupResult = Invoke-PsqlFile -Path $setupPath -OutputPath (Join-Path $workDir 'setup.out')
  if ($setupResult.ExitCode -ne 0) {
    throw "Setup failed: $($setupResult.Error)"
  }

  $results += Invoke-Scenario -Order 1 -Name 'Crossed full/child-only roots avoid deadlock' `
    -SessionAIds @($ids.RootA, $ids.B1) -SessionBIds @($ids.RootB, $ids.A1) `
    -MinimumBWaitSeconds ($HoldSeconds - 2.5) -MaximumBWaitSeconds ($HoldSeconds + 8)

  $results += Invoke-Scenario -Order 2 -Name 'Siblings under one root remain concurrent' `
    -SessionAIds @($ids.A1) -SessionBIds @($ids.A2) `
    -MinimumBWaitSeconds 0 -MaximumBWaitSeconds 2.5

  $results += Invoke-Scenario -Order 3 -Name 'Full family serializes child-only request' `
    -SessionAIds @($ids.RootA) -SessionBIds @($ids.A1) `
    -MinimumBWaitSeconds ($HoldSeconds - 2.5) -MaximumBWaitSeconds ($HoldSeconds + 8)

  $results += Invoke-Scenario -Order 4 -Name 'Reversed child-only roots avoid deadlock' `
    -SessionAIds @($ids.A1, $ids.B1) -SessionBIds @($ids.B2, $ids.A2) `
    -MinimumBWaitSeconds 0 -MaximumBWaitSeconds 2.5

  $results += Invoke-Scenario -Order 5 -Name 'Duplicates and permutations preserve protocol' `
    -SessionAIds @($ids.RootA, $ids.RootA, $ids.B1, $ids.B1) `
    -SessionBIds @($ids.B1, $ids.RootA) `
    -MinimumBWaitSeconds ($HoldSeconds - 2.5) -MaximumBWaitSeconds ($HoldSeconds + 8) `
    -RequireEqualResults $true
}
finally {
  $cleanupResult = Invoke-PsqlFile -Path $cleanupPath -OutputPath (Join-Path $workDir 'cleanup.out')
  if ($cleanupResult.ExitCode -ne 0) {
    Write-Error "Cleanup failed: $($cleanupResult.Error)"
  }
  elseif ($cleanupResult.Output -notmatch 't\|t') {
    Write-Error "Cleanup verification failed: $($cleanupResult.Output)"
  }
}

$results | Format-Table -AutoSize
if ($results.Count -ne 5 -or ($results | Where-Object { -not $_.passed })) {
  throw 'One or more 6B-4B1 concurrency scenarios failed.'
}

Write-Output '6B-4B1 concurrency: 5/5 PASSED'
Write-Output 'deadlock_40P01=false'
Write-Output 'lock_timeout_55P03=false'
Write-Output "Temporary logs: $workDir"
