param(
  [Parameter(Mandatory = $true)]
  [string]$DatabaseUrl,
  [int]$LockHoldSeconds = 8
)

$ErrorActionPreference = 'Stop'
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$migrationPath = Join-Path $repoRoot 'supabase\migrations\20260809061955_add_hierarchy_aware_create_reservation_v2.sql'
$marker = '[TEST][6B-3B-CONCURRENCY]'
$tempFiles = [System.Collections.Generic.List[string]]::new()
$migrationApplied = $false

function Invoke-PsqlFile {
  param([Parameter(Mandatory = $true)][string]$Path)
  & psql $DatabaseUrl -X -q -v ON_ERROR_STOP=1 -f $Path
  if ($LASTEXITCODE -ne 0) {
    throw "psql failed for $Path with exit code $LASTEXITCODE"
  }
}

function Invoke-PsqlText {
  param([Parameter(Mandatory = $true)][string]$Sql)
  $path = Join-Path ([System.IO.Path]::GetTempPath()) ("csk-6b3b-{0}.sql" -f ([guid]::NewGuid()))
  [System.IO.File]::WriteAllText($path, "\set ON_ERROR_STOP on`n$Sql", [System.Text.UTF8Encoding]::new($false))
  $tempFiles.Add($path)
  Invoke-PsqlFile -Path $path
}

function New-SessionSql {
  param(
    [string]$UserId,
    [string]$LaneId,
    [string]$Date,
    [string]$Start,
    [string]$RequestId,
    [int]$SleepSeconds
  )

  $sleep = if ($SleepSeconds -gt 0) { "select pg_catalog.pg_sleep($SleepSeconds);" } else { '' }
  return @"
begin;
do `$claims`$
begin
  perform pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object('sub','$UserId','role','authenticated')::text,
    true
  );
end;
`$claims`$;
set local role authenticated;
create temporary table session_result (
  started_at timestamptz not null,
  finished_at timestamptz not null,
  rpc_result jsonb not null
);
do `$session`$
declare
  v_started timestamptz := pg_catalog.clock_timestamp();
  v_result jsonb;
begin
  select public.create_reservation_v2(
    '$LaneId'::uuid,
    date '$Date',
    time '$Start',
    60,
    1,
    '$RequestId'::uuid,
    '$marker'
  ) into v_result;
  insert into pg_temp.session_result
  values (v_started, pg_catalog.clock_timestamp(), v_result);
end;
`$session`$;
$sleep
commit;
select
  pg_catalog.to_char(started_at, 'YYYY-MM-DD HH24:MI:SS.USOF'),
  pg_catalog.to_char(finished_at, 'YYYY-MM-DD HH24:MI:SS.USOF'),
  pg_catalog.round(extract(epoch from (finished_at-started_at))::numeric,3),
  rpc_result::text
from pg_temp.session_result;
"@
}

function Start-PsqlSession {
  param([string]$Name, [string]$Sql)
  $sqlPath = Join-Path ([System.IO.Path]::GetTempPath()) ("csk-6b3b-$Name-{0}.sql" -f ([guid]::NewGuid()))
  $stdoutPath = "$sqlPath.out"
  $stderrPath = "$sqlPath.err"
  [System.IO.File]::WriteAllText($sqlPath, "\set ON_ERROR_STOP on`n$Sql", [System.Text.UTF8Encoding]::new($false))
  $tempFiles.Add($sqlPath)
  $tempFiles.Add($stdoutPath)
  $tempFiles.Add($stderrPath)

  $process = Start-Process -FilePath 'psql' -ArgumentList @(
    $DatabaseUrl, '-X', '-qAt', '-F', '|', '-f', $sqlPath
  ) -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath

  return [pscustomobject]@{
    Name = $Name
    Process = $process
    Stdout = $stdoutPath
    Stderr = $stderrPath
  }
}

function Wait-PsqlSession {
  param($Session)
  $Session.Process.WaitForExit()
  $stdout = if (Test-Path $Session.Stdout) { (Get-Content -Raw $Session.Stdout).Trim() } else { '' }
  $stderr = if (Test-Path $Session.Stderr) { (Get-Content -Raw $Session.Stderr).Trim() } else { '' }
  if ($Session.Process.ExitCode -ne 0) {
    throw "$($Session.Name) failed with exit code $($Session.Process.ExitCode): $stderr"
  }
  [pscustomobject]@{ Name = $Session.Name; Output = $stdout; Error = $stderr }
}

function Invoke-ConcurrentScenario {
  param(
    [int]$Order,
    [string]$Name,
    [string]$Date,
    [string]$UserA,
    [string]$LaneA,
    [string]$RequestA,
    [string]$StartA,
    [string]$UserB,
    [string]$LaneB,
    [string]$RequestB,
    [string]$StartB,
    [int]$ExpectedReservations,
    [string]$ExpectedCodeA,
    [string]$ExpectedCodeB,
    [decimal]$MinWaitB = 0,
    [decimal]$MaxWaitB = 999
  )

  $sqlA = New-SessionSql -UserId $UserA -LaneId $LaneA -Date $Date -Start $StartA -RequestId $RequestA -SleepSeconds $LockHoldSeconds
  $sqlB = New-SessionSql -UserId $UserB -LaneId $LaneB -Date $Date -Start $StartB -RequestId $RequestB -SleepSeconds 0

  $sessionA = Start-PsqlSession -Name "$Order-A" -Sql $sqlA
  Start-Sleep -Seconds 2
  $sessionB = Start-PsqlSession -Name "$Order-B" -Sql $sqlB
  $resultB = Wait-PsqlSession -Session $sessionB
  $resultA = Wait-PsqlSession -Session $sessionA

  $rowA = ($resultA.Output -split "`r?`n" | Where-Object { $_ })[-1] -split '\|', 4
  $rowB = ($resultB.Output -split "`r?`n" | Where-Object { $_ })[-1] -split '\|', 4
  $jsonA = $rowA[3] | ConvertFrom-Json
  $jsonB = $rowB[3] | ConvertFrom-Json
  $waitB = [decimal]$rowB[2]

  if ($jsonA.code -ne $ExpectedCodeA -or $jsonB.code -ne $ExpectedCodeB) {
    throw "Scenario $Order returned unexpected codes: A=$($jsonA.code), B=$($jsonB.code)"
  }
  if ($waitB -lt $MinWaitB -or $waitB -gt $MaxWaitB) {
    throw "Scenario $Order returned unexpected B wait: $waitB seconds"
  }
  if ($Name -eq 'duplicate-request' -and $jsonA.reservation_id -ne $jsonB.reservation_id) {
    throw 'Duplicate scenario returned different reservation IDs.'
  }

  Write-Output "SCENARIO $Order - $Name"
  Write-Output "SESSION_A|$($resultA.Output)"
  Write-Output "SESSION_B|$($resultB.Output)"

  Invoke-PsqlText -Sql @"
select
  '$Order' as scenario_order,
  '$Name' as scenario_name,
  pg_catalog.count(*) as reservation_count,
  pg_catalog.count(*) filter (
    where pg_catalog.lower(pg_catalog.btrim(reservation_status)) not in (
      'completed','no_show','cancelled','canceled',
      'cancelled_by_admin','cancelled_by_user'
    )
  ) as active_count,
  (select pg_catalog.count(*)
   from public.audit_logs as audit
   where audit.action='reservation_created'
     and audit.target_id in (
       select reservation.id
       from public.reservations as reservation
       where reservation.reservation_note='$marker'
         and reservation.reservation_date=date '$Date'
     )) as audit_count,
  pg_catalog.count(*)=$ExpectedReservations as expected_count
from public.reservations
where reservation_note='$marker'
  and reservation_date=date '$Date';

do `$assert`$
begin
  if (select pg_catalog.count(*) from public.reservations
      where reservation_note='$marker' and reservation_date=date '$Date') <> $ExpectedReservations
     or (select pg_catalog.count(*) from public.audit_logs as audit
         where audit.action='reservation_created'
           and audit.target_id in (
             select reservation.id from public.reservations as reservation
             where reservation.reservation_note='$marker'
               and reservation.reservation_date=date '$Date'
           )) <> $ExpectedReservations then
    raise exception 'Scenario $Order failed final count or audit assertion.';
  end if;
end;
`$assert`$;
"@
}

$cleanupSql = @"
begin;
delete from public.audit_logs
where action='reservation_created'
  and target_id in (
    select id from public.reservations where reservation_note='$marker'
  );
delete from public.reservations where reservation_note='$marker';
delete from public.lane_pricing_rules
where lane_id in (select id from public.shooting_lanes where name like '$marker%');
delete from public.lane_booking_durations
where lane_id in (select id from public.shooting_lanes where name like '$marker%');
delete from public.lane_booking_rules
where lane_id in (select id from public.shooting_lanes where name like '$marker%');
delete from public.shooting_lanes where parent_lane_id in (
  select id from public.shooting_lanes where name like '$marker%'
);
delete from public.shooting_lanes where name like '$marker%';
delete from public.profiles
where user_id in ('6b3c0000-0000-4000-8000-000000000001','6b3c0000-0000-4000-8000-000000000002');
delete from auth.users where email like 'test-6b3b-concurrency-%@example.invalid';
drop function if exists public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text);
drop function if exists public.lock_lane_conflict_family_v1(uuid);
commit;
"@

try {
  Invoke-PsqlText -Sql @"
do `$preflight`$
begin
  if pg_catalog.to_regprocedure('public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)') is not null
     or pg_catalog.to_regprocedure('public.lock_lane_conflict_family_v1(uuid)') is not null
     or exists(select 1 from public.shooting_lanes where name like '$marker%')
     or exists(select 1 from auth.users where email like 'test-6b3b-concurrency-%@example.invalid') then
    raise exception 'Concurrency preflight found prior objects or fixtures.';
  end if;
end;
`$preflight`$;
"@

  $migrationApplied = $true
  Invoke-PsqlFile -Path $migrationPath

  Invoke-PsqlText -Sql @"
begin;
insert into auth.users(
  id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,
  raw_app_meta_data,raw_user_meta_data,created_at,updated_at
) values
('6b3c0000-0000-4000-8000-000000000001','00000000-0000-0000-0000-000000000000','authenticated','authenticated','test-6b3b-concurrency-1@example.invalid','',pg_catalog.transaction_timestamp(),'{}'::jsonb,'{}'::jsonb,pg_catalog.transaction_timestamp(),pg_catalog.transaction_timestamp()),
('6b3c0000-0000-4000-8000-000000000002','00000000-0000-0000-0000-000000000000','authenticated','authenticated','test-6b3b-concurrency-2@example.invalid','',pg_catalog.transaction_timestamp(),'{}'::jsonb,'{}'::jsonb,pg_catalog.transaction_timestamp(),pg_catalog.transaction_timestamp());
update public.profiles
set role='user',first_name='[TEST]',last_name='6B-3B-CONCURRENCY',
    full_name='$marker',email='test-6b3b-concurrency-profile@example.invalid',
    phone='000000000',verification_status='verified'
where user_id in ('6b3c0000-0000-4000-8000-000000000001','6b3c0000-0000-4000-8000-000000000002');
insert into public.shooting_lanes(
  id,name,type,description,price_per_hour,is_active,max_shooters,
  booking_step_minutes,display_order,currency_code,resource_kind,
  parent_lane_id,whole_lane_bookable,positions_bookable
) values
('6b3c0000-0000-4000-8000-000000000101','$marker[PARENT]','[TEST]','[TEST]',10,true,5,60,9950,'PLN','lane',null,true,true),
('6b3c0000-0000-4000-8000-000000000102','$marker[CHILD-1]','[TEST]','[TEST]',10,true,5,60,9951,'PLN','position','6b3c0000-0000-4000-8000-000000000101',false,false),
('6b3c0000-0000-4000-8000-000000000103','$marker[CHILD-2]','[TEST]','[TEST]',10,true,5,60,9952,'PLN','position','6b3c0000-0000-4000-8000-000000000101',false,false);
insert into public.lane_booking_rules(lane_id,online_bookable,max_people_online)
select id,true,5 from public.shooting_lanes where name like '$marker%';
insert into public.lane_booking_durations(lane_id,duration_minutes,display_order,is_active)
select id,60,1,true from public.shooting_lanes where name like '$marker%';
insert into public.lane_pricing_rules(lane_id,day_group,min_shooters,max_shooters,label,hourly_price,display_order,is_active)
select id,day_group,1,5,'$marker',10,1,true
from public.shooting_lanes
cross join (values('mon_thu'::text),('fri_sun'::text)) as group_record(day_group)
where name like '$marker%';
commit;
"@

  $base = [DateTime]::UtcNow.Date.AddYears(12)
  $u1 = '6b3c0000-0000-4000-8000-000000000001'
  $u2 = '6b3c0000-0000-4000-8000-000000000002'
  $parent = '6b3c0000-0000-4000-8000-000000000101'
  $child1 = '6b3c0000-0000-4000-8000-000000000102'
  $child2 = '6b3c0000-0000-4000-8000-000000000103'

  Invoke-ConcurrentScenario 1 'parent-vs-child' $base.ToString('yyyy-MM-dd') $u1 $parent '6b3c0000-0000-4000-8000-000000001001' '10:00' $u2 $child1 '6b3c0000-0000-4000-8000-000000001002' '10:00' 1 'created' 'slot_unavailable' 4 12
  Invoke-ConcurrentScenario 2 'child-vs-parent' $base.AddDays(1).ToString('yyyy-MM-dd') $u1 $child1 '6b3c0000-0000-4000-8000-000000001003' '10:00' $u2 $parent '6b3c0000-0000-4000-8000-000000001004' '10:00' 1 'created' 'slot_unavailable' 4 12
  Invoke-ConcurrentScenario 3 'child1-vs-child2' $base.AddDays(2).ToString('yyyy-MM-dd') $u1 $child1 '6b3c0000-0000-4000-8000-000000001005' '10:00' $u2 $child2 '6b3c0000-0000-4000-8000-000000001006' '10:00' 2 'created' 'created' 0 2
  Invoke-ConcurrentScenario 4 'duplicate-request' $base.AddDays(3).ToString('yyyy-MM-dd') $u1 $child1 '6b3c0000-0000-4000-8000-000000001007' '10:00' $u1 $child1 '6b3c0000-0000-4000-8000-000000001007' '10:00' 1 'created' 'already_created' 4 12
  Invoke-ConcurrentScenario 5 'touching-intervals' $base.AddDays(4).ToString('yyyy-MM-dd') $u1 $child1 '6b3c0000-0000-4000-8000-000000001008' '10:00' $u2 $child1 '6b3c0000-0000-4000-8000-000000001009' '11:00' 2 'created' 'created' 4 12
  Invoke-ConcurrentScenario 6 'same-child-overlap' $base.AddDays(5).ToString('yyyy-MM-dd') $u1 $child1 '6b3c0000-0000-4000-8000-000000001010' '10:00' $u2 $child1 '6b3c0000-0000-4000-8000-000000001011' '10:00' 1 'created' 'slot_unavailable' 4 12
}
finally {
  if ($migrationApplied) {
    Invoke-PsqlText -Sql $cleanupSql
  }
  foreach ($path in $tempFiles) {
    if (Test-Path $path) { Remove-Item -LiteralPath $path -Force }
  }
}

Invoke-PsqlText -Sql @"
select
  pg_catalog.to_regprocedure('public.create_reservation_v2(uuid,date,time without time zone,integer,integer,uuid,text)') is null as v2_removed,
  pg_catalog.to_regprocedure('public.lock_lane_conflict_family_v1(uuid)') is null as helper_removed,
  not exists(select 1 from public.shooting_lanes where name like '$marker%') as lanes_removed,
  not exists(select 1 from public.reservations where reservation_note='$marker') as reservations_removed,
  not exists(select 1 from public.profiles where user_id in ('6b3c0000-0000-4000-8000-000000000001','6b3c0000-0000-4000-8000-000000000002')) as profiles_removed,
  not exists(select 1 from auth.users where email like 'test-6b3b-concurrency-%@example.invalid') as users_removed;
"@

foreach ($path in $tempFiles) {
  if (Test-Path $path) { Remove-Item -LiteralPath $path -Force }
}
