param(
  [Parameter(Mandatory = $true)]
  [string]$DatabaseUrl,

  [string]$PsqlPath = 'psql',
  [string]$DockerContainerName = '',
  [string]$DockerDatabasePassword = '',

  [ValidateRange(500, 5000)]
  [int]$DeterministicHoldMilliseconds = 900,

  [ValidateRange(50, 100)]
  [int]$StressIterations = 50,

  [switch]$ConfirmIsolatedDatabase
)

$ErrorActionPreference = 'Stop'

if (-not $ConfirmIsolatedDatabase) {
  throw '6B-4E is blocked. Confirm an isolated schema-only database explicitly.'
}

$marker = '[TEST][6B-4E]'
$runId = [Guid]::NewGuid().ToString('N').Substring(0, 10)
$workDir = Join-Path $env:TEMP "csk-6b4e-$runId"
$workDirFull = [System.IO.Path]::GetFullPath($workDir)
$tempRootFull = [System.IO.Path]::GetFullPath($env:TEMP)
if (-not $workDirFull.StartsWith($tempRootFull, [StringComparison]::OrdinalIgnoreCase)) {
  throw 'Refusing to create regression artifacts outside the temporary directory.'
}
New-Item -ItemType Directory -Path $workDirFull | Out-Null

$invariantSourcePath = [System.IO.Path]::GetFullPath(
  (Join-Path $PSScriptRoot 'final_cross_writer_invariants.sql')
)
if (-not (Test-Path -LiteralPath $invariantSourcePath)) {
  throw "Invariant suite is missing: $invariantSourcePath"
}
$invariantPath = Join-Path $workDirFull 'final-cross-writer-invariants.sql'
[System.IO.File]::Copy($invariantSourcePath, $invariantPath, $true)

$ids = @{
  Admin = '6b4e0000-0000-4000-8000-000000000001'
  User1 = '6b4e0000-0000-4000-8000-000000000002'
  User2 = '6b4e0000-0000-4000-8000-000000000003'
  RootA = '6b4e0000-0000-4000-8000-000000000101'
  A1 = '6b4e0000-0000-4000-8000-000000000102'
  A2 = '6b4e0000-0000-4000-8000-000000000103'
  RootB = '6b4e0000-0000-4000-8000-000000000201'
  B1 = '6b4e0000-0000-4000-8000-000000000202'
  B2 = '6b4e0000-0000-4000-8000-000000000203'
  Standalone = '6b4e0000-0000-4000-8000-000000000301'
  EventSwapA = '6b4e0000-0000-4000-8000-000000000401'
  EventSwapB = '6b4e0000-0000-4000-8000-000000000402'
  EventSame = '6b4e0000-0000-4000-8000-000000000403'
  EventActivate = '6b4e0000-0000-4000-8000-000000000404'
  EventInactive = '6b4e0000-0000-4000-8000-000000000405'
  BlockSwapA = '6b4e0000-0000-4000-8000-000000000501'
  BlockSwapB = '6b4e0000-0000-4000-8000-000000000502'
  BlockSame = '6b4e0000-0000-4000-8000-000000000503'
  BlockActivate = '6b4e0000-0000-4000-8000-000000000504'
  BlockInactive = '6b4e0000-0000-4000-8000-000000000505'
}

$script:Results = @()
$script:SqlStates = @{
  '40P01' = 0
  '55P03' = 0
  '40001' = 0
  unexpected = 0
}

function Get-PsqlLaunch {
  param([Parameter(Mandatory = $true)][string]$Path)

  if ($DockerContainerName) {
    $containerPath = "/tmp/csk-6b4e-$runId-$([System.IO.Path]::GetFileName($Path))"
    & docker cp $Path "${DockerContainerName}:$containerPath" | Out-Null
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to copy SQL into the isolated container: $Path"
    }
    $arguments = @('exec')
    if ($DockerDatabasePassword) {
      $arguments += @('--env', "PGPASSWORD=$DockerDatabasePassword")
    }
    $arguments += @(
      $DockerContainerName, 'psql', '--no-psqlrc', '--set', 'ON_ERROR_STOP=1',
      '--dbname', $DatabaseUrl, '--file', $containerPath,
      '--no-align', '--tuples-only'
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
  $path = Join-Path $workDirFull "$Name.sql"
  [System.IO.File]::WriteAllText(
    $path,
    "\set ON_ERROR_STOP on`n\set VERBOSITY verbose`n$Sql",
    [System.Text.UTF8Encoding]::new($false)
  )
  return $path
}

function Start-PsqlFile {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$OutputPath
  )
  $launch = Get-PsqlLaunch -Path $Path
  $errorPath = "$OutputPath.err"
  $process = Start-Process -FilePath $launch.FilePath -ArgumentList $launch.ArgumentList `
    -RedirectStandardOutput $OutputPath -RedirectStandardError $errorPath `
    -WindowStyle Hidden -PassThru
  $null = $process.Handle
  return [pscustomobject]@{
    Process = $process
    OutputPath = $OutputPath
    ErrorPath = $errorPath
  }
}

function Read-ProcessResult {
  param([Parameter(Mandatory = $true)]$Run)
  $Run.Process.WaitForExit()
  $Run.Process.Refresh()
  $output = if (Test-Path $Run.OutputPath) { Get-Content -Raw $Run.OutputPath } else { '' }
  $errorText = if (Test-Path $Run.ErrorPath) { Get-Content -Raw $Run.ErrorPath } else { '' }
  return [pscustomobject]@{
    ExitCode = $Run.Process.ExitCode
    Output = $output
    Error = $errorText
  }
}

function Invoke-PsqlFile {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$OutputPath
  )
  return Read-ProcessResult (Start-PsqlFile -Path $Path -OutputPath $OutputPath)
}

function Invoke-Check {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$Sql
  )
  $path = New-SqlFile -Name $Name -Sql $Sql
  $result = Invoke-PsqlFile -Path $path -OutputPath (Join-Path $workDirFull "$Name.out")
  if ($result.ExitCode -ne 0) {
    throw "$Name failed: $($result.Error)"
  }
  return ([string]$result.Output).Trim()
}

function Invoke-InvariantSuite {
  param([Parameter(Mandatory = $true)][string]$Name)
  $result = Invoke-PsqlFile -Path $invariantPath -OutputPath (Join-Path $workDirFull "$Name-invariants.out")
  if ($result.ExitCode -ne 0) {
    throw "$Name invariant suite failed: $($result.Error)"
  }
  return ([string]$result.Output).Trim()
}

function New-SessionSql {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$UserId,
    [Parameter(Mandatory = $true)][string]$OperationSql,
    [Parameter(Mandatory = $true)][int]$HoldMilliseconds
  )
  $holdSeconds = ($HoldMilliseconds / 1000.0).ToString(
    '0.000', [Globalization.CultureInfo]::InvariantCulture
  )
  $sleepSql = if ($HoldMilliseconds -gt 0) {
    "select pg_catalog.pg_sleep($holdSeconds);"
  } else { '' }
  return New-SqlFile -Name $Name -Sql @"
begin;
set local lock_timeout = '12s';
set local statement_timeout = '30s';
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
  values(v_started, pg_catalog.clock_timestamp(), v_result);
end;
`$session`$;
select 'wait_seconds=' || pg_catalog.round(
  extract(epoch from (finished_at-started_at))::numeric, 3
) from pg_temp.csk_session_result;
select 'result=' || rpc_result::text from pg_temp.csk_session_result;
$sleepSql
commit;
"@
}

function Read-SessionResult {
  param([Parameter(Mandatory = $true)]$Run)
  $processResult = Read-ProcessResult $Run
  $waitMatch = [regex]::Match($processResult.Output, 'wait_seconds=([0-9.]+)')
  $resultMatch = [regex]::Match($processResult.Output, 'result=([^\r\n]+)')
  $json = if ($resultMatch.Success) {
    $resultMatch.Groups[1].Value | ConvertFrom-Json
  } else { $null }
  return [pscustomobject]@{
    Completed = $processResult.ExitCode -eq 0 -and $processResult.Output -match '(?m)^COMMIT\s*$'
    Output = $processResult.Output
    Error = $processResult.Error
    WaitSeconds = if ($waitMatch.Success) {
      [double]::Parse(
        $waitMatch.Groups[1].Value,
        [Globalization.CultureInfo]::InvariantCulture
      )
    } else { -1 }
    Json = $json
  }
}

function Register-SqlStates {
  param([string]$Text)
  foreach ($state in @('40P01', '55P03', '40001')) {
    $script:SqlStates[$state] += ([regex]::Matches($Text, $state)).Count
  }
  $knownBusinessError = $Text -match 'ERROR:\s+(P0002|22023|42501|55000|23505):'
  if ($Text -match 'ERROR:\s+[0-9A-Z]{5}:' -and -not $knownBusinessError) {
    $script:SqlStates.unexpected++
  }
}

function Test-ExpectedCode {
  param($Json, [string[]]$Expected)
  return $null -ne $Json -and $Expected -contains [string]$Json.code
}

function Invoke-ConcurrentScenario {
  param(
    [Parameter(Mandatory = $true)][string]$Order,
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$UserA,
    [Parameter(Mandatory = $true)][string]$SqlA,
    [Parameter(Mandatory = $true)][string[]]$ExpectedA,
    [Parameter(Mandatory = $true)][string]$UserB,
    [Parameter(Mandatory = $true)][string]$SqlB,
    [Parameter(Mandatory = $true)][string[]]$ExpectedB,
    [ValidateSet('serialized','parallel','any')][string]$Timing = 'any',
    [Parameter(Mandatory = $true)][string]$CheckSql,
    [int]$HoldMilliseconds = $DeterministicHoldMilliseconds,
    [int]$StartDelayMilliseconds = 180,
    [switch]$Stress
  )
  $safeOrder = $Order.Replace('.', '-')
  $aPath = New-SessionSql -Name "scenario-$safeOrder-a" -UserId $UserA `
    -OperationSql $SqlA -HoldMilliseconds $HoldMilliseconds
  $bPath = New-SessionSql -Name "scenario-$safeOrder-b" -UserId $UserB `
    -OperationSql $SqlB -HoldMilliseconds 0
  $aRun = Start-PsqlFile -Path $aPath -OutputPath (Join-Path $workDirFull "scenario-$safeOrder-a.out")
  Start-Sleep -Milliseconds $StartDelayMilliseconds
  $bRun = Start-PsqlFile -Path $bPath -OutputPath (Join-Path $workDirFull "scenario-$safeOrder-b.out")
  $b = Read-SessionResult $bRun
  $a = Read-SessionResult $aRun
  $combined = "$($a.Output)`n$($b.Output)`n$($a.Error)`n$($b.Error)"
  Register-SqlStates -Text $combined
  $check = Invoke-Check -Name "scenario-$safeOrder-check" -Sql $CheckSql
  $invariants = Invoke-InvariantSuite -Name "scenario-$safeOrder"
  $minimumSerialized = [Math]::Max(0.12, ($HoldMilliseconds - $StartDelayMilliseconds - 250) / 1000.0)
  # Deterministic scenarios prove lock timing. Stress validates safety/state and
  # must not fail because a 250 ms hold races with Windows process scheduling.
  $timingPassed = if ($Stress) { $true } else {
    switch ($Timing) {
      'serialized' { $b.WaitSeconds -ge $minimumSerialized }
      'parallel' { $b.WaitSeconds -ge 0 -and $b.WaitSeconds -lt 0.45 }
      default { $true }
    }
  }
  $passed = $a.Completed -and $b.Completed `
    -and (Test-ExpectedCode $a.Json $ExpectedA) `
    -and (Test-ExpectedCode $b.Json $ExpectedB) `
    -and $timingPassed `
    -and $check -match 'check_passed=true' `
    -and $invariants -match 'total_violations=0' `
    -and $combined -notmatch '40P01|55P03|40001'
  $script:Results += [pscustomobject]@{
    test_order = $Order
    scenario = $Name
    passed = $passed
    session_a_code = if ($a.Json) { $a.Json.code } else { '<missing>' }
    session_b_code = if ($b.Json) { $b.Json.code } else { '<missing>' }
    session_b_wait_seconds = $b.WaitSeconds
    timing = $Timing
    invariant_violations = if ($invariants -match 'total_violations=([0-9]+)') { $Matches[1] } else { '<missing>' }
    stress = [bool]$Stress
    error = (($a.Error + ' ' + $b.Error).Trim())
  }
}

function Invoke-SingleScenario {
  param(
    [Parameter(Mandatory = $true)][string]$Order,
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$UserId,
    [Parameter(Mandatory = $true)][string]$Sql,
    [Parameter(Mandatory = $true)][string[]]$Expected,
    [Parameter(Mandatory = $true)][string]$CheckSql
  )
  $safeOrder = $Order.Replace('.', '-')
  $path = New-SessionSql -Name "scenario-$safeOrder-single" -UserId $UserId `
    -OperationSql $Sql -HoldMilliseconds 0
  $run = Start-PsqlFile -Path $path -OutputPath (Join-Path $workDirFull "scenario-$safeOrder-single.out")
  $result = Read-SessionResult $run
  $combined = "$($result.Output)`n$($result.Error)"
  Register-SqlStates -Text $combined
  $check = Invoke-Check -Name "scenario-$safeOrder-check" -Sql $CheckSql
  $invariants = Invoke-InvariantSuite -Name "scenario-$safeOrder"
  $passed = $result.Completed -and (Test-ExpectedCode $result.Json $Expected) `
    -and $check -match 'check_passed=true' `
    -and $invariants -match 'total_violations=0' `
    -and $combined -notmatch '40P01|55P03|40001'
  $script:Results += [pscustomobject]@{
    test_order = $Order
    scenario = $Name
    passed = $passed
    session_a_code = if ($result.Json) { $result.Json.code } else { '<missing>' }
    session_b_code = '-'
    session_b_wait_seconds = 0
    timing = 'single'
    invariant_violations = if ($invariants -match 'total_violations=([0-9]+)') { $Matches[1] } else { '<missing>' }
    stress = $false
    error = [string]$result.Error
  }
}

function Get-RequestId {
  param([int]$Number)
  return ('6b4e0000-0000-4000-8001-{0:d12}' -f $Number)
}

function Get-ReservationSql {
  param(
    [string]$LaneId, [int]$DateOffset, [int]$RequestNumber,
    [int]$Shooters = 1, [int]$Duration = 60, [string]$Start = '10:00'
  )
  return "public.create_reservation_v2('$LaneId',current_date+$DateOffset,time '$Start',$Duration,$Shooters,'$(Get-RequestId $RequestNumber)','$marker')"
}

function Get-EventSql {
  param(
    [string]$Title, [int]$DateOffset, [string[]]$LaneIds,
    [string]$Start = '10:00', [string]$End = '11:00'
  )
  $laneArray = if ($LaneIds.Count -eq 0) { "array[]::uuid[]" } else {
    "array[$(($LaneIds | ForEach-Object { "'$_'" }) -join ',')]::uuid[]"
  }
  return "public.admin_create_event_v2('$marker[$Title]','$marker',current_date+$DateOffset,time '$Start',time '$End','$marker',10,10,$laneArray)"
}

function Get-BlockSql {
  param(
    [string]$Reason, [int]$DateOffset, [string]$LaneId,
    [string]$Start = '10:00', [string]$End = '11:00'
  )
  return "public.admin_create_lane_block('$LaneId',current_date+$DateOffset,time '$Start',time '$End','$marker[$Reason]')"
}

function Get-PricingSql {
  param([int]$MaxOnline, [int]$Price)
  return "pg_catalog.jsonb_build_array(" +
    "pg_catalog.jsonb_build_object('day_group','mon_thu','min_shooters',1,'max_shooters',$MaxOnline,'label','$marker','hourly_price',$Price)," +
    "pg_catalog.jsonb_build_object('day_group','fri_sun','min_shooters',1,'max_shooters',$MaxOnline,'label','$marker','hourly_price',$($Price + 20)))"
}

function Get-ConfigSql {
  param(
    [string]$LaneId, [bool]$Active = $true, [int]$MaxShooters = 5,
    [int]$MaxOnline = 5, [int]$Price = 100, [int[]]$Durations = @(60),
    [bool]$Position = $false, [bool]$PositionsBookable = $true,
    [bool]$AcknowledgeFutureObligations = $false
  )
  if ($Position) {
    if ($MaxShooters -eq 5) { $MaxShooters = 2 }
    if ($MaxOnline -eq 5) { $MaxOnline = 2 }
  }
  $activeSql = $Active.ToString().ToLowerInvariant()
  $wholeSql = (-not $Position).ToString().ToLowerInvariant()
  $positionsSql = ((-not $Position) -and $PositionsBookable).ToString().ToLowerInvariant()
  $deactivateFamilySql = ((-not $Active) -and (-not $Position)).ToString().ToLowerInvariant()
  $acknowledgeSql = $AcknowledgeFutureObligations.ToString().ToLowerInvariant()
  $durationsSql = 'pg_catalog.to_jsonb(array[' + (($Durations | ForEach-Object { [string]$_ }) -join ',') + ']::integer[])'
  $pricingSql = Get-PricingSql -MaxOnline $MaxOnline -Price $Price
  return @"
(
  with family as materialized (
    select family_item.value
    from pg_catalog.jsonb_array_elements(
      public.admin_get_lane_booking_configuration_v2()->'families'
    ) as family_item(value)
    where exists (
      select 1
      from pg_catalog.jsonb_array_elements(family_item.value->'resources') as resource_item(value)
      where resource_item.value->>'lane_id' = '$LaneId'
    )
  ), payload as (
    select pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'lane_id', resource_item.value->'lane_id',
        'is_active', case
          when $deactivateFamilySql then 'false'::jsonb
          when resource_item.value->>'lane_id' = '$LaneId' then pg_catalog.to_jsonb($activeSql)
          else resource_item.value->'is_active'
        end,
        'whole_lane_bookable', case
          when resource_item.value->>'lane_id' = '$LaneId' then pg_catalog.to_jsonb($wholeSql)
          else resource_item.value->'whole_lane_bookable'
        end,
        'positions_bookable', case
          when $deactivateFamilySql then 'false'::jsonb
          when resource_item.value->>'lane_id' = '$LaneId' then pg_catalog.to_jsonb($positionsSql)
          else resource_item.value->'positions_bookable'
        end,
        'max_shooters', case
          when resource_item.value->>'lane_id' = '$LaneId' then pg_catalog.to_jsonb($MaxShooters)
          else resource_item.value->'max_shooters'
        end,
        'online_bookable', case
          when $deactivateFamilySql then 'false'::jsonb
          when resource_item.value->>'lane_id' = '$LaneId' then pg_catalog.to_jsonb($activeSql)
          else resource_item.value->'online_bookable'
        end,
        'max_people_online', case
          when resource_item.value->>'lane_id' = '$LaneId' then pg_catalog.to_jsonb($MaxOnline)
          else resource_item.value->'max_people_online'
        end,
        'durations_minutes', case
          when resource_item.value->>'lane_id' = '$LaneId' then $durationsSql
          else coalesce((
            select pg_catalog.jsonb_agg(
              (duration_item.value->>'duration_minutes')::integer
              order by (duration_item.value->>'duration_minutes')::integer
            )
            from pg_catalog.jsonb_array_elements(resource_item.value->'durations') as duration_item(value)
            where (duration_item.value->>'is_active')::boolean
          ), '[]'::jsonb)
        end,
        'pricing', case
          when resource_item.value->>'lane_id' = '$LaneId' then $pricingSql
          else coalesce((
            select pg_catalog.jsonb_agg(
              pg_catalog.jsonb_build_object(
                'day_group', price_item.value->'day_group',
                'min_shooters', price_item.value->'min_shooters',
                'max_shooters', price_item.value->'max_shooters',
                'label', price_item.value->'label',
                'hourly_price', price_item.value->'hourly_price'
              ) order by price_item.value->>'day_group',
                         (price_item.value->>'min_shooters')::integer,
                         (price_item.value->>'max_shooters')::integer,
                         price_item.value->>'label'
            )
            from pg_catalog.jsonb_array_elements(resource_item.value->'pricing') as price_item(value)
            where (price_item.value->>'is_active')::boolean
          ), '[]'::jsonb)
        end
      ) order by (resource_item.value->>'lane_id')::uuid
    ) as resources
    from family
    cross join lateral pg_catalog.jsonb_array_elements(family.value->'resources') as resource_item(value)
  )
  select public.admin_set_lane_booking_family_configuration_v2(
    (family.value->>'root_lane_id')::uuid,
    (family.value->>'configuration_version')::bigint,
    payload.resources,
    $acknowledgeSql
  )
  from family cross join payload
)
"@
}

$fingerprintSql = @"
select function_record.proname || '=' || pg_catalog.md5(pg_catalog.pg_get_functiondef(function_record.oid))
from pg_catalog.pg_proc as function_record
join pg_catalog.pg_namespace as namespace_record
  on namespace_record.oid = function_record.pronamespace
where namespace_record.nspname = 'public'
  and function_record.proname in (
    'lock_lane_conflict_families_v1',
    'create_reservation_v2',
    'admin_create_lane_block',
    'admin_update_lane_block',
    'admin_set_lane_block_active',
    'admin_create_event_v2',
    'admin_update_event_v2',
    'admin_set_event_active_v2',
    'admin_get_lane_booking_configuration_v2',
    'admin_set_lane_booking_family_configuration_v2',
    'get_public_booking_configuration_v1'
  )
order by function_record.proname;
"@

$setup = New-SqlFile -Name 'setup' -Sql @"
do `$preflight`$
declare
  v_required_functions text[] := array[
    'public.lock_lane_conflict_families_v1(uuid[])',
    'public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)',
    'public.admin_create_lane_block(uuid,date,time without time zone,time without time zone,text)',
    'public.admin_update_lane_block(uuid,uuid,date,time without time zone,time without time zone,text,boolean)',
    'public.admin_set_lane_block_active(uuid,boolean)',
    'public.admin_create_event_v2(text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])',
    'public.admin_update_event_v2(uuid,text,text,date,time without time zone,time without time zone,text,numeric,integer,uuid[])',
    'public.admin_set_event_active_v2(uuid,boolean)',
    'public.admin_get_lane_booking_configuration_v2()',
    'public.admin_set_lane_booking_family_configuration_v2(uuid,bigint,jsonb,boolean)',
    'public.get_public_booking_configuration_v1()'
  ];
  v_signature text;
begin
  foreach v_signature in array v_required_functions loop
    if pg_catalog.to_regprocedure(v_signature) is null then
      raise exception 'Required production-schema function is missing: %', v_signature;
    end if;
  end loop;

  if pg_catalog.to_regclass('public.lane_booking_family_configuration_versions') is null then
    raise exception 'Required family configuration version table is missing.';
  end if;

  if exists(select 1 from public.shooting_lanes)
     or exists(select 1 from public.reservations)
     or exists(select 1 from public.lane_blocks)
     or exists(select 1 from public.events)
     or exists(select 1 from public.event_lanes)
     or exists(select 1 from auth.users)
     or exists(select 1 from public.profiles) then
    raise exception 'Isolated database is not schema-only or contains prior fixtures.';
  end if;
end;
`$preflight`$;

insert into auth.users(
  id, instance_id, aud, role, email, encrypted_password,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values
  ('$($ids.Admin)','00000000-0000-0000-0000-000000000000','authenticated','authenticated','test-6b4e-admin@example.invalid','','{}','{}',pg_catalog.transaction_timestamp(),pg_catalog.transaction_timestamp()),
  ('$($ids.User1)','00000000-0000-0000-0000-000000000000','authenticated','authenticated','test-6b4e-user1@example.invalid','','{}','{}',pg_catalog.transaction_timestamp(),pg_catalog.transaction_timestamp()),
  ('$($ids.User2)','00000000-0000-0000-0000-000000000000','authenticated','authenticated','test-6b4e-user2@example.invalid','','{}','{}',pg_catalog.transaction_timestamp(),pg_catalog.transaction_timestamp());

insert into public.profiles(
  user_id, role, first_name, last_name, full_name, email, phone,
  verification_status, permissions_verified
) values
  ('$($ids.Admin)','admin','[TEST]','6B-4E-ADMIN','$marker ADMIN','test-6b4e-admin@example.invalid','000000001','verified',true),
  ('$($ids.User1)','user','[TEST]','6B-4E-U1','$marker USER 1','test-6b4e-user1@example.invalid','000000002','verified',true),
  ('$($ids.User2)','user','[TEST]','6B-4E-U2','$marker USER 2','test-6b4e-user2@example.invalid','000000003','verified',true)
on conflict (user_id) do update set
  role=excluded.role, first_name=excluded.first_name, last_name=excluded.last_name,
  full_name=excluded.full_name, email=excluded.email, phone=excluded.phone,
  verification_status=excluded.verification_status,
  permissions_verified=excluded.permissions_verified;

insert into public.shooting_lanes(
  id, name, type, description, price_per_hour, is_active, max_shooters,
  booking_step_minutes, display_order, currency_code, resource_kind,
  parent_lane_id, whole_lane_bookable, positions_bookable
) values
  ('$($ids.RootA)','$marker ROOT A','[TEST]','$marker',100,true,5,60,9700,'PLN','lane',null,true,true),
  ('$($ids.A1)','$marker A1','[TEST]','$marker',100,true,2,60,9701,'PLN','position','$($ids.RootA)',false,false),
  ('$($ids.A2)','$marker A2','[TEST]','$marker',100,true,2,60,9702,'PLN','position','$($ids.RootA)',false,false),
  ('$($ids.RootB)','$marker ROOT B','[TEST]','$marker',100,true,5,60,9800,'PLN','lane',null,true,true),
  ('$($ids.B1)','$marker B1','[TEST]','$marker',100,true,2,60,9801,'PLN','position','$($ids.RootB)',false,false),
  ('$($ids.B2)','$marker B2','[TEST]','$marker',100,true,2,60,9802,'PLN','position','$($ids.RootB)',false,false),
  ('$($ids.Standalone)','$marker STANDALONE C','[TEST]','$marker',100,true,8,60,9900,'PLN','lane',null,true,false);

insert into public.lane_booking_rules(lane_id, online_bookable, max_people_online)
select lane.id, true, case when lane.resource_kind='position' then 2 else 5 end
from public.shooting_lanes as lane
where lane.name like '$marker%';

insert into public.lane_booking_durations(lane_id, duration_minutes, display_order, is_active)
select lane.id, 60, 10, true
from public.shooting_lanes as lane
where lane.name like '$marker%';

insert into public.lane_pricing_rules(
  lane_id, day_group, min_shooters, max_shooters, label,
  hourly_price, display_order, is_active
)
select lane.id, day_group.value, 1,
       case when lane.resource_kind='position' then 2 else 5 end,
       '$marker', 100, 10, true
from public.shooting_lanes as lane
cross join (values ('mon_thu'::text), ('fri_sun'::text)) as day_group(value)
where lane.name like '$marker%';

insert into public.lane_booking_family_configuration_versions(root_lane_id)
values
  ('$($ids.RootA)'),
  ('$($ids.RootB)'),
  ('$($ids.Standalone)');

insert into public.events(
  id, title, description, event_date, start_time, end_time,
  location, price, max_participants, is_active
) values
  ('$($ids.EventSwapA)','$marker EVENT SWAP A','$marker',current_date+9300,time '10:00',time '11:00','$marker',10,10,true),
  ('$($ids.EventSwapB)','$marker EVENT SWAP B','$marker',current_date+9301,time '10:00',time '11:00','$marker',10,10,true),
  ('$($ids.EventSame)','$marker EVENT SAME','$marker',current_date+9332,time '10:00',time '11:00','$marker',10,10,true),
  ('$($ids.EventActivate)','$marker EVENT ACTIVATE','$marker',current_date+9330,time '10:00',time '11:00','$marker',10,10,false),
  ('$($ids.EventInactive)','$marker EVENT INACTIVE','$marker',current_date+9442,time '10:00',time '11:00','$marker',10,10,true);

insert into public.event_lanes(event_id, lane_id) values
  ('$($ids.EventSwapA)','$($ids.RootA)'),
  ('$($ids.EventSwapB)','$($ids.RootB)'),
  ('$($ids.EventSame)','$($ids.A1)'),
  ('$($ids.EventActivate)','$($ids.A1)'),
  ('$($ids.EventInactive)','$($ids.B1)');

insert into public.lane_blocks(
  id, lane_id, block_date, start_time, end_time, reason, is_active
) values
  ('$($ids.BlockSwapA)','$($ids.RootA)',current_date+9310,time '10:00',time '11:00','$marker BLOCK SWAP A',true),
  ('$($ids.BlockSwapB)','$($ids.RootB)',current_date+9311,time '10:00',time '11:00','$marker BLOCK SWAP B',true),
  ('$($ids.BlockSame)','$($ids.A1)',current_date+9333,time '10:00',time '11:00','$marker BLOCK SAME',true),
  ('$($ids.BlockActivate)','$($ids.A1)',current_date+9331,time '10:00',time '11:00','$marker BLOCK ACTIVATE',false),
  ('$($ids.BlockInactive)','$($ids.B1)',current_date+9442,time '12:00',time '13:00','$marker BLOCK INACTIVE',true);
"@

$cleanup = New-SqlFile -Name 'cleanup' -Sql @"
begin;
delete from public.audit_logs;
delete from public.reservations;
delete from public.lane_blocks;
delete from public.events;
delete from public.lane_pricing_rules;
delete from public.lane_booking_durations;
delete from public.lane_booking_rules;
delete from public.lane_booking_family_configuration_versions;
delete from public.shooting_lanes where parent_lane_id is not null;
delete from public.shooting_lanes;
delete from public.profiles;
delete from auth.users;
commit;
select 'cleanup_passed=' || (
  not exists(select 1 from public.shooting_lanes)
  and not exists(select 1 from public.reservations)
  and not exists(select 1 from public.lane_blocks)
  and not exists(select 1 from public.events)
  and not exists(select 1 from public.event_lanes)
  and not exists(select 1 from public.profiles)
  and not exists(select 1 from auth.users)
)::text;
"@

$setupSucceeded = $false
$cleanupComplete = $false
$fingerprintsBefore = ''
$fingerprintsAfter = ''
$finalInvariants = ''

try {
  $fingerprintsBefore = Invoke-Check -Name 'fingerprints-before' -Sql $fingerprintSql
  $setupResult = Invoke-PsqlFile -Path $setup -OutputPath (Join-Path $workDirFull 'setup.out')
  if ($setupResult.ExitCode -ne 0) {
    throw "Setup failed: $($setupResult.Error)"
  }
  $setupSucceeded = $true
  $setupInvariants = Invoke-InvariantSuite -Name 'setup'
  if ($setupInvariants -notmatch 'total_violations=0') {
    throw "Fixture violates invariants: $setupInvariants"
  }

  # 1-8: core reservation parent/child matrix.
  Invoke-ConcurrentScenario -Order '1' -Name 'parent reservation vs child reservation' `
    -UserA $ids.User1 -SqlA (Get-ReservationSql $ids.RootA 9001 1) -ExpectedA @('created') `
    -UserB $ids.User2 -SqlB (Get-ReservationSql $ids.A1 9001 2) -ExpectedB @('slot_unavailable') `
    -Timing serialized -CheckSql "select 'check_passed='||((select count(*)=1 from public.reservations where reservation_date=current_date+9001))::text;"

  Invoke-ConcurrentScenario -Order '2' -Name 'child sibling reservations' `
    -UserA $ids.User1 -SqlA (Get-ReservationSql $ids.A1 9002 3) -ExpectedA @('created') `
    -UserB $ids.User2 -SqlB (Get-ReservationSql $ids.A2 9002 4) -ExpectedB @('created') `
    -Timing parallel -CheckSql "select 'check_passed='||((select count(*)=2 from public.reservations where reservation_date=current_date+9002))::text;"

  Invoke-ConcurrentScenario -Order '3' -Name 'parent reservation vs child lane block' `
    -UserA $ids.User1 -SqlA (Get-ReservationSql $ids.RootA 9003 5) -ExpectedA @('created') `
    -UserB $ids.Admin -SqlB (Get-BlockSql 'S3' 9003 $ids.A1) -ExpectedB @('conflict_reservation') `
    -Timing serialized -CheckSql "select 'check_passed='||(not exists(select 1 from public.lane_blocks where reason='$marker[S3]'))::text;"

  Invoke-ConcurrentScenario -Order '4' -Name 'child reservation vs parent lane block' `
    -UserA $ids.User1 -SqlA (Get-ReservationSql $ids.A1 9004 6) -ExpectedA @('created') `
    -UserB $ids.Admin -SqlB (Get-BlockSql 'S4' 9004 $ids.RootA) -ExpectedB @('conflict_reservation') `
    -Timing serialized -CheckSql "select 'check_passed='||(not exists(select 1 from public.lane_blocks where reason='$marker[S4]'))::text;"

  Invoke-ConcurrentScenario -Order '5' -Name 'child reservation vs sibling lane block' `
    -UserA $ids.User1 -SqlA (Get-ReservationSql $ids.A1 9005 7) -ExpectedA @('created') `
    -UserB $ids.Admin -SqlB (Get-BlockSql 'S5' 9005 $ids.A2) -ExpectedB @('created') `
    -Timing parallel -CheckSql "select 'check_passed='||(exists(select 1 from public.reservations where reservation_date=current_date+9005) and exists(select 1 from public.lane_blocks where reason='$marker[S5]'))::text;"

  Invoke-ConcurrentScenario -Order '6' -Name 'parent reservation vs child event' `
    -UserA $ids.User1 -SqlA (Get-ReservationSql $ids.RootA 9006 8) -ExpectedA @('created') `
    -UserB $ids.Admin -SqlB (Get-EventSql 'S6' 9006 @($ids.A1)) -ExpectedB @('reservation_conflict') `
    -Timing serialized -CheckSql "select 'check_passed='||(not exists(select 1 from public.events where title='$marker[S6]'))::text;"

  Invoke-ConcurrentScenario -Order '7' -Name 'child reservation vs parent event' `
    -UserA $ids.User1 -SqlA (Get-ReservationSql $ids.A1 9007 9) -ExpectedA @('created') `
    -UserB $ids.Admin -SqlB (Get-EventSql 'S7' 9007 @($ids.RootA)) -ExpectedB @('reservation_conflict') `
    -Timing serialized -CheckSql "select 'check_passed='||(not exists(select 1 from public.events where title='$marker[S7]'))::text;"

  Invoke-ConcurrentScenario -Order '8' -Name 'child reservation vs sibling event' `
    -UserA $ids.User1 -SqlA (Get-ReservationSql $ids.A1 9008 10) -ExpectedA @('created') `
    -UserB $ids.Admin -SqlB (Get-EventSql 'S8' 9008 @($ids.A2)) -ExpectedB @('created') `
    -Timing parallel -CheckSql "select 'check_passed='||(exists(select 1 from public.reservations where reservation_date=current_date+9008) and exists(select 1 from public.events where title='$marker[S8]'))::text;"

  # 9-14: block/event matrix in both orderings.
  Invoke-ConcurrentScenario -Order '9' -Name 'parent block vs child event' `
    -UserA $ids.Admin -SqlA (Get-BlockSql 'S9' 9009 $ids.RootA) -ExpectedA @('created') `
    -UserB $ids.Admin -SqlB (Get-EventSql 'S9' 9009 @($ids.A1)) -ExpectedB @('lane_block_conflict') `
    -Timing serialized -CheckSql "select 'check_passed='||(not exists(select 1 from public.events where title='$marker[S9]'))::text;"

  Invoke-ConcurrentScenario -Order '10' -Name 'child block vs parent event' `
    -UserA $ids.Admin -SqlA (Get-BlockSql 'S10' 9010 $ids.A1) -ExpectedA @('created') `
    -UserB $ids.Admin -SqlB (Get-EventSql 'S10' 9010 @($ids.RootA)) -ExpectedB @('lane_block_conflict') `
    -Timing serialized -CheckSql "select 'check_passed='||(not exists(select 1 from public.events where title='$marker[S10]'))::text;"

  Invoke-ConcurrentScenario -Order '11' -Name 'sibling block and event' `
    -UserA $ids.Admin -SqlA (Get-BlockSql 'S11' 9011 $ids.A1) -ExpectedA @('created') `
    -UserB $ids.Admin -SqlB (Get-EventSql 'S11' 9011 @($ids.A2)) -ExpectedB @('created') `
    -Timing parallel -CheckSql "select 'check_passed='||(exists(select 1 from public.lane_blocks where reason='$marker[S11]') and exists(select 1 from public.events where title='$marker[S11]'))::text;"

  Invoke-ConcurrentScenario -Order '12' -Name 'parent event vs child block' `
    -UserA $ids.Admin -SqlA (Get-EventSql 'S12' 9012 @($ids.RootA)) -ExpectedA @('created') `
    -UserB $ids.Admin -SqlB (Get-BlockSql 'S12' 9012 $ids.A1) -ExpectedB @('conflict_event') `
    -Timing serialized -CheckSql "select 'check_passed='||(not exists(select 1 from public.lane_blocks where reason='$marker[S12]'))::text;"

  Invoke-ConcurrentScenario -Order '13' -Name 'child event vs parent block' `
    -UserA $ids.Admin -SqlA (Get-EventSql 'S13' 9013 @($ids.A1)) -ExpectedA @('created') `
    -UserB $ids.Admin -SqlB (Get-BlockSql 'S13' 9013 $ids.RootA) -ExpectedB @('conflict_event') `
    -Timing serialized -CheckSql "select 'check_passed='||(not exists(select 1 from public.lane_blocks where reason='$marker[S13]'))::text;"

  Invoke-ConcurrentScenario -Order '14' -Name 'sibling event and block reverse ordering' `
    -UserA $ids.Admin -SqlA (Get-EventSql 'S14' 9014 @($ids.A1)) -ExpectedA @('created') `
    -UserB $ids.Admin -SqlB (Get-BlockSql 'S14' 9014 $ids.A2) -ExpectedB @('created') `
    -Timing parallel -CheckSql "select 'check_passed='||(exists(select 1 from public.events where title='$marker[S14]') and exists(select 1 from public.lane_blocks where reason='$marker[S14]'))::text;"

  # 15-18: config/reservation serialization and atomic snapshots.
  Invoke-ConcurrentScenario -Order '15' -Name 'parent config first vs child reservation' `
    -UserA $ids.Admin -SqlA (Get-ConfigSql $ids.RootA -Price 115) -ExpectedA @('updated') `
    -UserB $ids.User1 -SqlB (Get-ReservationSql $ids.A1 9015 15) -ExpectedB @('created') `
    -Timing serialized -CheckSql "select 'check_passed='||(exists(select 1 from public.reservations where reservation_date=current_date+9015 and lane_id='$($ids.A1)'))::text;"

  Invoke-ConcurrentScenario -Order '16' -Name 'child reservation first vs parent config' `
    -UserA $ids.User1 -SqlA (Get-ReservationSql $ids.A1 9016 16) -ExpectedA @('created') `
    -UserB $ids.Admin -SqlB (Get-ConfigSql $ids.RootA -Price 116) -ExpectedB @('updated') `
    -Timing serialized -CheckSql "select 'check_passed='||(exists(select 1 from public.reservations where reservation_date=current_date+9016 and price_per_hour_snapshot=100 and pricing_label_snapshot='$marker'))::text;"

  Invoke-ConcurrentScenario -Order '17' -Name 'child config vs sibling reservation' `
    -UserA $ids.Admin -SqlA (Get-ConfigSql $ids.A1 -Position $true -Price 117) -ExpectedA @('updated') `
    -UserB $ids.User1 -SqlB (Get-ReservationSql $ids.A2 9017 17) -ExpectedB @('created') `
    -Timing serialized -CheckSql "select 'check_passed='||(exists(select 1 from public.reservations where reservation_date=current_date+9017 and lane_id='$($ids.A2)'))::text;"

  Invoke-ConcurrentScenario -Order '18' -Name 'atomic config snapshot vs reservation' `
    -UserA $ids.Admin -SqlA (Get-ConfigSql $ids.Standalone -Price 170 -Durations @(120) -PositionsBookable $false -MaxShooters 8) -ExpectedA @('updated') `
    -UserB $ids.User1 -SqlB (Get-ReservationSql $ids.Standalone 9018 18 -Duration 120) -ExpectedB @('created') `
    -Timing serialized -CheckSql "select 'check_passed='||(select duration_minutes=120 and pricing_label_snapshot='$marker' and ((pricing_day_group_snapshot='mon_thu' and price_per_hour_snapshot=170 and total_price=340) or (pricing_day_group_snapshot='fri_sun' and price_per_hour_snapshot=190 and total_price=380)) from public.reservations where reservation_date=current_date+9018 and lane_id='$($ids.Standalone)')::text;"

  # 19-22: config with block/event on the same family and sibling resources.
  Invoke-ConcurrentScenario -Order '19' -Name 'parent config vs child lane block' `
    -UserA $ids.Admin -SqlA (Get-ConfigSql $ids.RootA -Price 119) -ExpectedA @('updated') `
    -UserB $ids.Admin -SqlB (Get-BlockSql 'S19' 9019 $ids.A1) -ExpectedB @('created') `
    -Timing serialized -CheckSql "select 'check_passed='||(exists(select 1 from public.lane_blocks where reason='$marker[S19]'))::text;"

  Invoke-ConcurrentScenario -Order '19.2' -Name 'child lane block first vs parent config' `
    -UserA $ids.Admin -SqlA (Get-BlockSql 'S19-REVERSE' 9119 $ids.A1) -ExpectedA @('created') `
    -UserB $ids.Admin -SqlB (Get-ConfigSql $ids.RootA -Price 219) -ExpectedB @('updated') `
    -Timing serialized -CheckSql "select 'check_passed='||(exists(select 1 from public.lane_blocks where reason='$marker[S19-REVERSE]'))::text;"

  Invoke-ConcurrentScenario -Order '20' -Name 'parent config vs child event' `
    -UserA $ids.Admin -SqlA (Get-ConfigSql $ids.RootA -Price 120) -ExpectedA @('updated') `
    -UserB $ids.Admin -SqlB (Get-EventSql 'S20' 9020 @($ids.A1)) -ExpectedB @('created') `
    -Timing serialized -CheckSql "select 'check_passed='||(exists(select 1 from public.events where title='$marker[S20]'))::text;"

  Invoke-ConcurrentScenario -Order '20.2' -Name 'child event first vs parent config' `
    -UserA $ids.Admin -SqlA (Get-EventSql 'S20-REVERSE' 9120 @($ids.A1)) -ExpectedA @('created') `
    -UserB $ids.Admin -SqlB (Get-ConfigSql $ids.RootA -Price 220) -ExpectedB @('updated') `
    -Timing serialized -CheckSql "select 'check_passed='||(exists(select 1 from public.events where title='$marker[S20-REVERSE]'))::text;"

  Invoke-ConcurrentScenario -Order '21' -Name 'child config vs sibling lane block' `
    -UserA $ids.Admin -SqlA (Get-ConfigSql $ids.A1 -Position $true -Price 121) -ExpectedA @('updated') `
    -UserB $ids.Admin -SqlB (Get-BlockSql 'S21' 9021 $ids.A2) -ExpectedB @('created') `
    -Timing serialized -CheckSql "select 'check_passed='||(exists(select 1 from public.lane_blocks where reason='$marker[S21]'))::text;"

  Invoke-ConcurrentScenario -Order '22' -Name 'child config vs sibling event' `
    -UserA $ids.Admin -SqlA (Get-ConfigSql $ids.A1 -Position $true -Price 122) -ExpectedA @('updated') `
    -UserB $ids.Admin -SqlB (Get-EventSql 'S22' 9022 @($ids.A2)) -ExpectedB @('created') `
    -Timing serialized -CheckSql "select 'check_passed='||(exists(select 1 from public.events where title='$marker[S22]'))::text;"

  # 23-26: globally ordered multi-root locks and unrelated-root independence.
  Invoke-ConcurrentScenario -Order '23' -Name 'multi-root event permutations' `
    -UserA $ids.Admin -SqlA (Get-EventSql 'S23A' 9023 @($ids.RootA,$ids.RootB)) -ExpectedA @('created') `
    -UserB $ids.Admin -SqlB (Get-EventSql 'S23B' 9023 @($ids.RootB,$ids.RootA)) -ExpectedB @('event_conflict') `
    -Timing serialized -CheckSql "select 'check_passed='||((select count(*)=1 from public.events where title in ('$marker[S23A]','$marker[S23B]')))::text;"

  $eventUpdateA = "public.admin_update_event_v2('$($ids.EventSwapA)','$marker EVENT SWAP A UPDATED','$marker',current_date+9324,time '11:00',time '12:00','$marker',10,10,array['$($ids.RootB)']::uuid[])"
  $eventUpdateB = "public.admin_update_event_v2('$($ids.EventSwapB)','$marker EVENT SWAP B UPDATED','$marker',current_date+9325,time '11:00',time '12:00','$marker',10,10,array['$($ids.RootA)']::uuid[])"
  Invoke-ConcurrentScenario -Order '24' -Name 'cross-root event updates' `
    -UserA $ids.Admin -SqlA $eventUpdateA -ExpectedA @('updated') `
    -UserB $ids.Admin -SqlB $eventUpdateB -ExpectedB @('updated') `
    -Timing serialized -CheckSql "select 'check_passed='||((select lane_id='$($ids.RootB)' from public.event_lanes where event_id='$($ids.EventSwapA)') and (select lane_id='$($ids.RootA)' from public.event_lanes where event_id='$($ids.EventSwapB)'))::text;"

  $blockUpdateA = "public.admin_update_lane_block('$($ids.BlockSwapA)','$($ids.B1)',current_date+9326,time '11:00',time '12:00','$marker BLOCK SWAP A UPDATED',true)"
  $blockUpdateB = "public.admin_update_lane_block('$($ids.BlockSwapB)','$($ids.A1)',current_date+9327,time '11:00',time '12:00','$marker BLOCK SWAP B UPDATED',true)"
  Invoke-ConcurrentScenario -Order '25' -Name 'cross-root lane block updates' `
    -UserA $ids.Admin -SqlA $blockUpdateA -ExpectedA @('updated') `
    -UserB $ids.Admin -SqlB $blockUpdateB -ExpectedB @('updated') `
    -Timing serialized -CheckSql "select 'check_passed='||((select lane_id='$($ids.B1)' from public.lane_blocks where id='$($ids.BlockSwapA)') and (select lane_id='$($ids.A1)' from public.lane_blocks where id='$($ids.BlockSwapB)'))::text;"

  Invoke-ConcurrentScenario -Order '26.1' -Name 'config root A vs reservation root B' `
    -UserA $ids.Admin -SqlA (Get-ConfigSql $ids.RootA -Price 126) -ExpectedA @('updated') `
    -UserB $ids.User1 -SqlB (Get-ReservationSql $ids.B1 9026 26) -ExpectedB @('created') `
    -Timing parallel -CheckSql "select 'check_passed='||(exists(select 1 from public.reservations where reservation_date=current_date+9026 and lane_id='$($ids.B1)'))::text;"

  Invoke-ConcurrentScenario -Order '26.2' -Name 'config root A vs event root B' `
    -UserA $ids.Admin -SqlA (Get-ConfigSql $ids.RootA -Price 127) -ExpectedA @('updated') `
    -UserB $ids.Admin -SqlB (Get-EventSql 'S26E' 9027 @($ids.B1)) -ExpectedB @('created') `
    -Timing parallel -CheckSql "select 'check_passed='||(exists(select 1 from public.events where title='$marker[S26E]'))::text;"

  Invoke-ConcurrentScenario -Order '26.3' -Name 'config root A vs block root B' `
    -UserA $ids.Admin -SqlA (Get-ConfigSql $ids.RootA -Price 128) -ExpectedA @('updated') `
    -UserB $ids.Admin -SqlB (Get-BlockSql 'S26B' 9028 $ids.B1) -ExpectedB @('created') `
    -Timing parallel -CheckSql "select 'check_passed='||(exists(select 1 from public.lane_blocks where reason='$marker[S26B]'))::text;"

  Invoke-ConcurrentScenario -Order '26.4' -Name 'config writes on different roots' `
    -UserA $ids.Admin -SqlA (Get-ConfigSql $ids.RootA -Price 129) -ExpectedA @('updated') `
    -UserB $ids.Admin -SqlB (Get-ConfigSql $ids.RootB -Price 229) -ExpectedB @('updated') `
    -Timing parallel -CheckSql "select 'check_passed='||((select bool_and(hourly_price in (129,149)) from public.lane_pricing_rules where lane_id='$($ids.RootA)' and is_active) and (select bool_and(hourly_price in (229,249)) from public.lane_pricing_rules where lane_id='$($ids.RootB)' and is_active))::text;"

  # 27-33: same-resource contention and deterministic idempotency/final state.
  Invoke-ConcurrentScenario -Order '27' -Name 'two reservations same child' `
    -UserA $ids.User1 -SqlA (Get-ReservationSql $ids.B2 9029 27) -ExpectedA @('created') `
    -UserB $ids.User2 -SqlB (Get-ReservationSql $ids.B2 9029 28) -ExpectedB @('slot_unavailable') `
    -Timing serialized -CheckSql "select 'check_passed='||((select count(*)=1 from public.reservations where reservation_date=current_date+9029 and lane_id='$($ids.B2)'))::text;"

  $duplicateReservation = Get-ReservationSql $ids.B2 9030 29
  Invoke-ConcurrentScenario -Order '28' -Name 'duplicate reservation idempotency' `
    -UserA $ids.User1 -SqlA $duplicateReservation -ExpectedA @('created') `
    -UserB $ids.User1 -SqlB $duplicateReservation -ExpectedB @('already_created') `
    -Timing serialized -CheckSql "select 'check_passed='||((select count(*)=1 from public.reservations where creation_request_id='$(Get-RequestId 29)'))::text;"

  $activateBlock = "public.admin_set_lane_block_active('$($ids.BlockActivate)',true)"
  Invoke-ConcurrentScenario -Order '29' -Name 'two lane block activations' `
    -UserA $ids.Admin -SqlA $activateBlock -ExpectedA @('activated') `
    -UserB $ids.Admin -SqlB $activateBlock -ExpectedB @('no_change') `
    -Timing serialized -CheckSql "select 'check_passed='||(select is_active from public.lane_blocks where id='$($ids.BlockActivate)')::text;"

  $activateEvent = "public.admin_set_event_active_v2('$($ids.EventActivate)',true)"
  Invoke-ConcurrentScenario -Order '30' -Name 'two event activations' `
    -UserA $ids.Admin -SqlA $activateEvent -ExpectedA @('activated') `
    -UserB $ids.Admin -SqlB $activateEvent -ExpectedB @('no_change') `
    -Timing serialized -CheckSql "select 'check_passed='||(select is_active from public.events where id='$($ids.EventActivate)')::text;"

  $versionBefore31 = [long](Invoke-Check -Name 'scenario-31-version-before' -Sql "select configuration_version from public.lane_booking_family_configuration_versions where root_lane_id='$($ids.RootB)';")
  $auditBefore31 = [long](Invoke-Check -Name 'scenario-31-audit-before' -Sql "select count(*) from public.audit_logs where action='lane_booking_family_configuration_updated' and target_id='$($ids.RootB)'::uuid;")
  Invoke-ConcurrentScenario -Order '31' -Name 'two config writers same expected version' `
    -UserA $ids.Admin -SqlA (Get-ConfigSql $ids.RootB -Price 231) -ExpectedA @('updated') `
    -UserB $ids.Admin -SqlB (Get-ConfigSql $ids.RootB -Price 232) -ExpectedB @('stale_configuration') `
    -Timing serialized -CheckSql "select 'check_passed='||((select bool_and(hourly_price in (231,251)) from public.lane_pricing_rules where lane_id='$($ids.RootB)' and is_active) and (select configuration_version=$($versionBefore31 + 1) from public.lane_booking_family_configuration_versions where root_lane_id='$($ids.RootB)') and (select count(*)=$($auditBefore31 + 1) from public.audit_logs where action='lane_booking_family_configuration_updated' and target_id='$($ids.RootB)'::uuid))::text;"

  $sameEventUpdateA = "public.admin_update_event_v2('$($ids.EventSame)','$marker EVENT SAME A','$marker',current_date+9332,time '11:00',time '12:00','$marker A',11,11,array['$($ids.A1)']::uuid[])"
  $sameEventUpdateB = "public.admin_update_event_v2('$($ids.EventSame)','$marker EVENT SAME B','$marker',current_date+9332,time '12:00',time '13:00','$marker B',12,12,array['$($ids.A1)']::uuid[])"
  Invoke-ConcurrentScenario -Order '32' -Name 'two updates same event' `
    -UserA $ids.Admin -SqlA $sameEventUpdateA -ExpectedA @('updated') `
    -UserB $ids.Admin -SqlB $sameEventUpdateB -ExpectedB @('updated') `
    -Timing serialized -CheckSql "select 'check_passed='||(select title='$marker EVENT SAME B' and start_time=time '12:00' and max_participants=12 from public.events where id='$($ids.EventSame)')::text;"

  $sameBlockUpdateA = "public.admin_update_lane_block('$($ids.BlockSame)','$($ids.A1)',current_date+9333,time '11:00',time '12:00','$marker BLOCK SAME A',true)"
  $sameBlockUpdateB = "public.admin_update_lane_block('$($ids.BlockSame)','$($ids.A1)',current_date+9333,time '12:00',time '13:00','$marker BLOCK SAME B',true)"
  Invoke-ConcurrentScenario -Order '33' -Name 'two updates same lane block' `
    -UserA $ids.Admin -SqlA $sameBlockUpdateA -ExpectedA @('updated') `
    -UserB $ids.Admin -SqlB $sameBlockUpdateB -ExpectedB @('updated') `
    -Timing serialized -CheckSql "select 'check_passed='||(select reason='$marker BLOCK SAME B' and start_time=time '12:00' from public.lane_blocks where id='$($ids.BlockSame)')::text;"

  # 34-36: half-open [start,end) intervals.
  Invoke-ConcurrentScenario -Order '34.1' -Name 'reservation touches event boundary' `
    -UserA $ids.User1 -SqlA (Get-ReservationSql $ids.A1 9034 34 -Start '10:00') -ExpectedA @('created') `
    -UserB $ids.Admin -SqlB (Get-EventSql 'S34E' 9034 @($ids.RootA) -Start '11:00' -End '12:00') -ExpectedB @('created') `
    -Timing serialized -CheckSql "select 'check_passed='||(exists(select 1 from public.reservations where reservation_date=current_date+9034) and exists(select 1 from public.events where title='$marker[S34E]'))::text;"

  Invoke-ConcurrentScenario -Order '34.2' -Name 'reservation touches block boundary' `
    -UserA $ids.User1 -SqlA (Get-ReservationSql $ids.A1 9035 35 -Start '10:00') -ExpectedA @('created') `
    -UserB $ids.Admin -SqlB (Get-BlockSql 'S34B' 9035 $ids.RootA -Start '11:00' -End '12:00') -ExpectedB @('created') `
    -Timing serialized -CheckSql "select 'check_passed='||(exists(select 1 from public.reservations where reservation_date=current_date+9035) and exists(select 1 from public.lane_blocks where reason='$marker[S34B]'))::text;"

  Invoke-ConcurrentScenario -Order '35' -Name 'event ends when reservation starts' `
    -UserA $ids.Admin -SqlA (Get-EventSql 'S35' 9036 @($ids.RootA) -Start '10:00' -End '11:00') -ExpectedA @('created') `
    -UserB $ids.User1 -SqlB (Get-ReservationSql $ids.A1 9036 36 -Start '11:00') -ExpectedB @('created') `
    -Timing serialized -CheckSql "select 'check_passed='||(exists(select 1 from public.events where title='$marker[S35]') and exists(select 1 from public.reservations where reservation_date=current_date+9036))::text;"

  Invoke-ConcurrentScenario -Order '36' -Name 'lane block ends when reservation starts' `
    -UserA $ids.Admin -SqlA (Get-BlockSql 'S36' 9037 $ids.RootA -Start '10:00' -End '11:00') -ExpectedA @('created') `
    -UserB $ids.User1 -SqlB (Get-ReservationSql $ids.A1 9037 37 -Start '11:00') -ExpectedB @('created') `
    -Timing serialized -CheckSql "select 'check_passed='||(exists(select 1 from public.lane_blocks where reason='$marker[S36]') and exists(select 1 from public.reservations where reservation_date=current_date+9037))::text;"

  # 37-39: global events carry no lane family and therefore remain independent.
  Invoke-ConcurrentScenario -Order '37' -Name 'global event vs reservation' `
    -UserA $ids.Admin -SqlA (Get-EventSql 'S37' 9038 @()) -ExpectedA @('created') `
    -UserB $ids.User1 -SqlB (Get-ReservationSql $ids.A1 9038 38) -ExpectedB @('created') `
    -Timing parallel -CheckSql "select 'check_passed='||(exists(select 1 from public.events where title='$marker[S37]' and not exists(select 1 from public.event_lanes where event_id=events.id)) and exists(select 1 from public.reservations where reservation_date=current_date+9038))::text;"

  Invoke-ConcurrentScenario -Order '38' -Name 'global event vs lane block' `
    -UserA $ids.Admin -SqlA (Get-EventSql 'S38' 9039 @()) -ExpectedA @('created') `
    -UserB $ids.Admin -SqlB (Get-BlockSql 'S38' 9039 $ids.A1) -ExpectedB @('created') `
    -Timing parallel -CheckSql "select 'check_passed='||(exists(select 1 from public.events where title='$marker[S38]') and exists(select 1 from public.lane_blocks where reason='$marker[S38]'))::text;"

  Invoke-ConcurrentScenario -Order '39' -Name 'global event vs config writer' `
    -UserA $ids.Admin -SqlA (Get-EventSql 'S39' 9040 @()) -ExpectedA @('created') `
    -UserB $ids.Admin -SqlB (Get-ConfigSql $ids.A1 -Position $true -Price 139) -ExpectedB @('updated') `
    -Timing parallel -CheckSql "select 'check_passed='||(exists(select 1 from public.events where title='$marker[S39]') and (select bool_and(hourly_price in (139,159)) from public.lane_pricing_rules where lane_id='$($ids.A1)' and is_active))::text;"

  # 40-43: inactive-resource behavior and deactivation recovery.
  $null = Invoke-Check -Name 'prepare-inactive-parent' -Sql "update public.shooting_lanes set is_active=false where id='$($ids.RootA)'; select 'prepared=true';"
  Invoke-SingleScenario -Order '40' -Name 'inactive parent blocks child reservation' `
    -UserId $ids.User1 -Sql (Get-ReservationSql $ids.A1 9041 41) -Expected @('lane_inactive') `
    -CheckSql "select 'check_passed='||(not exists(select 1 from public.reservations where reservation_date=current_date+9041))::text;"

  $null = Invoke-Check -Name 'prepare-inactive-child' -Sql "update public.shooting_lanes set is_active=true where id='$($ids.RootA)'; update public.shooting_lanes set is_active=false where id='$($ids.B1)'; select 'prepared=true';"
  Invoke-SingleScenario -Order '41' -Name 'inactive child rejects reservation' `
    -UserId $ids.User1 -Sql (Get-ReservationSql $ids.B1 9042 42) -Expected @('lane_inactive') `
    -CheckSql "select 'check_passed='||(not exists(select 1 from public.reservations where reservation_date=current_date+9042))::text;"

  Invoke-ConcurrentScenario -Order '42' -Name 'deactivate block and event on inactive child' `
    -UserA $ids.Admin -SqlA "public.admin_set_lane_block_active('$($ids.BlockInactive)',false)" -ExpectedA @('deactivated') `
    -UserB $ids.Admin -SqlB "public.admin_set_event_active_v2('$($ids.EventInactive)',false)" -ExpectedB @('deactivated') `
    -Timing serialized -CheckSql "select 'check_passed='||((select not is_active from public.lane_blocks where id='$($ids.BlockInactive)') and (select not is_active from public.events where id='$($ids.EventInactive)'))::text;"

  $null = Invoke-Check -Name 'prepare-config-deactivate' -Sql "update public.shooting_lanes set is_active=true where id in ('$($ids.RootA)'::uuid,'$($ids.A1)'::uuid,'$($ids.B1)'::uuid); select 'prepared=true';"
  Invoke-ConcurrentScenario -Order '43' -Name 'config deactivation vs reservation' `
    -UserA $ids.Admin -SqlA (Get-ConfigSql $ids.RootA -Active $false -Price 143 -AcknowledgeFutureObligations $true) -ExpectedA @('updated') `
    -UserB $ids.User1 -SqlB (Get-ReservationSql $ids.A1 9043 43) -ExpectedB @('lane_inactive') `
    -Timing serialized -CheckSql "select 'check_passed='||((select not is_active from public.shooting_lanes where id='$($ids.RootA)') and not exists(select 1 from public.reservations where reservation_date=current_date+9043))::text;"

  # 44-46: online capacity boundary and contact-required path.
  Invoke-SingleScenario -Order '44' -Name 'online capacity reservation succeeds' `
    -UserId $ids.User1 -Sql (Get-ReservationSql $ids.Standalone 9044 44 -Shooters 5 -Duration 120) -Expected @('created') `
    -CheckSql "select 'check_passed='||(exists(select 1 from public.reservations where reservation_date=current_date+9044 and shooters_count=5))::text;"

  Invoke-SingleScenario -Order '45' -Name 'above online capacity requires contact' `
    -UserId $ids.User1 -Sql (Get-ReservationSql $ids.Standalone 9045 45 -Shooters 6 -Duration 120) -Expected @('contact_required') `
    -CheckSql "select 'check_passed='||(not exists(select 1 from public.reservations where reservation_date=current_date+9045))::text;"

  Invoke-SingleScenario -Order '46' -Name 'above physical capacity rejected' `
    -UserId $ids.User1 -Sql (Get-ReservationSql $ids.Standalone 9046 46 -Shooters 9 -Duration 120) -Expected @('capacity_exceeded') `
    -CheckSql "select 'check_passed='||(not exists(select 1 from public.reservations where reservation_date=current_date+9046))::text;"

  # Restore active test resources before randomized mixed-writer stress.
  $null = Invoke-Check -Name 'prepare-stress' -Sql "update public.shooting_lanes set is_active=true where name like '$marker%'; update public.shooting_lanes set whole_lane_bookable=true,positions_bookable=true where id in ('$($ids.RootA)'::uuid,'$($ids.RootB)'::uuid); update public.lane_booking_rules set online_bookable=true where lane_id in (select id from public.shooting_lanes where name like '$marker%'); select 'prepared=true';"

  for ($iteration = 1; $iteration -le $StressIterations; $iteration++) {
    $dateOffset = 9600 + $iteration
    $requestBase = 1000 + ($iteration * 2)
    $stressOrder = "S$iteration"
    switch ($iteration % 4) {
      0 {
        Invoke-ConcurrentScenario -Order $stressOrder -Name 'stress parent reservation vs child event' `
          -UserA $ids.User1 -SqlA (Get-ReservationSql $ids.RootA $dateOffset $requestBase) -ExpectedA @('created') `
          -UserB $ids.Admin -SqlB (Get-EventSql "STRESS-$iteration" $dateOffset @($ids.A1)) -ExpectedB @('reservation_conflict') `
          -Timing serialized -CheckSql "select 'check_passed='||((select count(*)=1 from public.reservations where reservation_date=current_date+$dateOffset))::text;" `
          -HoldMilliseconds 250 -StartDelayMilliseconds 45 -Stress
      }
      1 {
        Invoke-ConcurrentScenario -Order $stressOrder -Name 'stress sibling reservation and block' `
          -UserA $ids.User1 -SqlA (Get-ReservationSql $ids.A1 $dateOffset $requestBase) -ExpectedA @('created') `
          -UserB $ids.Admin -SqlB (Get-BlockSql "STRESS-$iteration" $dateOffset $ids.A2) -ExpectedB @('created') `
          -Timing parallel -CheckSql "select 'check_passed='||(exists(select 1 from public.reservations where reservation_date=current_date+$dateOffset) and exists(select 1 from public.lane_blocks where reason='$marker[STRESS-$iteration]'))::text;" `
          -HoldMilliseconds 250 -StartDelayMilliseconds 45 -Stress
      }
      2 {
        Invoke-ConcurrentScenario -Order $stressOrder -Name 'stress sibling config and event' `
          -UserA $ids.Admin -SqlA (Get-ConfigSql $ids.A1 -Position $true -Price (200 + $iteration)) -ExpectedA @('updated') `
          -UserB $ids.Admin -SqlB (Get-EventSql "STRESS-$iteration" $dateOffset @($ids.A2)) -ExpectedB @('created') `
          -Timing serialized -CheckSql "select 'check_passed='||(exists(select 1 from public.events where title='$marker[STRESS-$iteration]'))::text;" `
          -HoldMilliseconds 250 -StartDelayMilliseconds 45 -Stress
      }
      default {
        Invoke-ConcurrentScenario -Order $stressOrder -Name 'stress parent event vs child reservation' `
          -UserA $ids.Admin -SqlA (Get-EventSql "STRESS-$iteration" $dateOffset @($ids.RootB)) -ExpectedA @('created') `
          -UserB $ids.User2 -SqlB (Get-ReservationSql $ids.B1 $dateOffset $requestBase) -ExpectedB @('slot_unavailable') `
          -Timing serialized -CheckSql "select 'check_passed='||((select count(*)=1 from public.events where title='$marker[STRESS-$iteration]'))::text;" `
          -HoldMilliseconds 250 -StartDelayMilliseconds 45 -Stress
      }
    }
  }

  $finalInvariants = Invoke-InvariantSuite -Name 'final'
  $fingerprintsAfter = Invoke-Check -Name 'fingerprints-after' -Sql $fingerprintSql
}
finally {
  if ($setupSucceeded) {
    $cleanupResult = Invoke-PsqlFile -Path $cleanup -OutputPath (Join-Path $workDirFull 'cleanup.out')
    $cleanupComplete = $cleanupResult.ExitCode -eq 0 -and $cleanupResult.Output -match 'cleanup_passed=true'
    if (-not $cleanupComplete) {
      Write-Error "Fixture cleanup failed: $($cleanupResult.Error) $($cleanupResult.Output)"
    }
  }
}

$deterministic = @($script:Results | Where-Object { -not $_.stress })
$stress = @($script:Results | Where-Object { $_.stress })
$failed = @($script:Results | Where-Object { -not $_.passed })
$fingerprintsUnchanged = $fingerprintsBefore -eq $fingerprintsAfter

$deterministic | Format-Table test_order,scenario,passed,session_a_code,session_b_code,session_b_wait_seconds,timing,invariant_violations -AutoSize
Write-Output "deterministic_executions=$($deterministic.Count)"
Write-Output 'deterministic_requirements=52'
Write-Output "stress_iterations=$($stress.Count)"
Write-Output "stress_passed=$(@($stress | Where-Object passed).Count)"
Write-Output "deadlock_40P01=$($script:SqlStates['40P01'])"
Write-Output "lock_timeout_55P03=$($script:SqlStates['55P03'])"
Write-Output "serialization_failure_40001=$($script:SqlStates['40001'])"
Write-Output "unexpected_sqlstate=$($script:SqlStates.unexpected)"
Write-Output "final_invariants=$finalInvariants"
Write-Output "protected_function_fingerprints_unchanged=$($fingerprintsUnchanged.ToString().ToLowerInvariant())"
Write-Output "cleanup_complete=$($cleanupComplete.ToString().ToLowerInvariant())"

if ($workDirFull.StartsWith($tempRootFull, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path $workDirFull)) {
  Remove-Item -LiteralPath $workDirFull -Recurse -Force
}
Write-Output "temporary_logs_removed=$((-not (Test-Path $workDirFull)).ToString().ToLowerInvariant())"

if ($deterministic.Count -ne 52 `
    -or $stress.Count -ne $StressIterations `
    -or $failed.Count -gt 0 `
    -or $script:SqlStates['40P01'] -ne 0 `
    -or $script:SqlStates['55P03'] -ne 0 `
    -or $script:SqlStates['40001'] -ne 0 `
    -or $script:SqlStates.unexpected -ne 0 `
    -or $finalInvariants -notmatch 'total_violations=0' `
    -or -not $fingerprintsUnchanged `
    -or -not $cleanupComplete) {
  throw "6B-4E failed. Failed scenarios: $($failed.test_order -join ', ')"
}

Write-Output '6B-4E FINAL CROSS-WRITER REGRESSION: PASSED'
