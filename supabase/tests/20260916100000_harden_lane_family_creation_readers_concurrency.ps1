param(
  [string]$DockerContainerName = 'supabase_db_csk-booking',
  [switch]$ConfirmIsolatedDatabase
)

$ErrorActionPreference = 'Stop'
if (-not $ConfirmIsolatedDatabase) { throw 'Use only an isolated local database.' }

$csk = 'c5c00000-0000-4000-8000-000000000001'
$tenantB = [guid]::NewGuid().ToString()
$adminA1 = [guid]::NewGuid().ToString()
$adminA2 = [guid]::NewGuid().ToString()
$adminB = [guid]::NewGuid().ToString()
$run = [guid]::NewGuid().ToString('N')
$marker = "[TEST][SAAS-9D-3B-RACE][$run]"
$users = @($adminA1,$adminA2,$adminB)
$userIds = ($users | ForEach-Object { "'$_'" }) -join ','

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

function Receive-Pair($First,$Second) {
  Wait-Job $First,$Second | Out-Null
  try { return @((Receive-Job $First), (Receive-Job $Second)) }
  finally { Remove-Job $First,$Second -Force }
}

function New-FamilyPayload([string]$Name) {
  $resource = @{
    name = $Name
    is_active = $true
    online_bookable = $true
    max_shooters = 4
    max_people_online = 4
    booking_step_minutes = 60
    durations_minutes = @(60,120)
    pricing = @(
      @{ day_group='mon_thu'; min_shooters=1; max_shooters=4; label='Pon-Czw'; hourly_price=100 },
      @{ day_group='fri_sun'; min_shooters=1; max_shooters=4; label='Pt-Nd'; hourly_price=120 }
    )
  }
  $position1 = $resource.Clone(); $position1.name = "$Name Position 1"; $position1.max_shooters=2; $position1.max_people_online=2
  $position1.pricing = @(
    @{ day_group='mon_thu'; min_shooters=1; max_shooters=2; label='Pon-Czw'; hourly_price=50 },
    @{ day_group='fri_sun'; min_shooters=1; max_shooters=2; label='Pt-Nd'; hourly_price=60 }
  )
  $position2 = $position1.Clone(); $position2.name = "$Name Position 2"
  return (@{ root=($resource + @{ whole_lane_bookable=$true; positions_bookable=$true }); positions=@($position1,$position2) } | ConvertTo-Json -Depth 8 -Compress)
}

function New-CreateSql([string]$User,[string]$Payload) {
  $escaped = $Payload.Replace("'","''")
  return "begin; select set_config('request.jwt.claims',jsonb_build_object('sub','$User','role','authenticated')::text,true); select set_config('request.jwt.claim.sub','$User',true); set local role authenticated; select public.admin_create_lane_booking_family_v1('$escaped'::jsonb)->>'code'; commit;"
}

$userValues = @(
  "('$adminA1','00000000-0000-0000-0000-000000000000','authenticated','authenticated','9d3b-a1-$run@example.invalid','',now(),'{}','{}',now(),now())",
  "('$adminA2','00000000-0000-0000-0000-000000000000','authenticated','authenticated','9d3b-a2-$run@example.invalid','',now(),'{}','{}',now(),now())",
  "('$adminB','00000000-0000-0000-0000-000000000000','authenticated','authenticated','9d3b-b-$run@example.invalid','',now(),'{}','{}',now(),now())"
) -join ",`n"

$setup = @"
insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at) values
$userValues;
insert into public.profiles(id,user_id,email,role,verification_status)
select id,id,email,'user','verified' from auth.users u
where id in($userIds) and not exists(select 1 from public.profiles p where p.user_id=u.id);
update public.profiles set role='admin',first_name='Test',last_name='9D3B Race',full_name='$marker',verification_status='verified'
where user_id in('$adminA1','$adminA2');
update public.profiles set role='admin',first_name='Test',last_name='9D3B Race',full_name='$marker',verification_status='verified'
where user_id='$adminB';
delete from public.tenant_memberships where tenant_id='$csk' and user_id='$adminB';
insert into public.tenants(id,name,slug,status) values('$tenantB','$marker Tenant B','saas9d3b-race-$($run.Substring(0,12))','dormant');
insert into public.tenant_memberships(tenant_id,user_id,role,status) values('$tenantB','$adminB','admin','active');
"@

try {
  Invoke-LocalSql $setup | Out-Null
  $deadlocksBefore = [int](Invoke-LocalSql "select deadlocks from pg_stat_database where datname=current_database();")

  $payload1 = New-FamilyPayload "$marker Family 1"
  $payload2 = New-FamilyPayload "$marker Family 2"
  $pair = Receive-Pair (Start-LocalSqlJob (New-CreateSql $adminA1 $payload1)) (Start-LocalSqlJob (New-CreateSql $adminA2 $payload2))
  $codes = @([regex]::Matches(($pair -join "`n"),'(?m)^created\r?$') | ForEach-Object { $_.Value.Trim() })
  if ($codes.Count -ne 2) { throw "Concurrent create results differ: $($pair -join ' | ')" }
  $state = Invoke-LocalSql "select (count(*)=6 and count(distinct id)=6 and count(*) filter(where resource_kind='lane')=2 and count(*) filter(where resource_kind='position')=4 and bool_and(tenant_id='$csk'::uuid))::text from public.shooting_lanes where name like '$marker Family %';"
  if ($state -ne 'true') { throw 'Concurrent creates left an incomplete or duplicate family.' }
  $display = Invoke-LocalSql "select (count(*)=2 and count(distinct display_order)=2)::text from public.shooting_lanes where name like '$marker Family %' and resource_kind='lane';"
  if ($display -ne 'true') { throw 'Concurrent root display order is not unique.' }
  Write-Output 'CONCURRENT_FAMILY_CREATE=PASS'
  Write-Output 'SIMULTANEOUS_CHILD_ASSIGNMENT=PASS'

  $payloadA = New-FamilyPayload "$marker Mixed A"
  $payloadB = New-FamilyPayload "$marker Mixed B"
  $mixed = Receive-Pair (Start-LocalSqlJob (New-CreateSql $adminA1 $payloadA)) (Start-LocalSqlJob (New-CreateSql $adminB $payloadB))
  $joined = $mixed -join "`n"
  if (([regex]::Matches($joined,'(?m)^created\r?$')).Count -ne 1 -or ([regex]::Matches($joined,'(?m)^not_allowed\r?$')).Count -ne 1) {
    throw "Concurrent Tenant A/B results differ: $joined"
  }
  if ((Invoke-LocalSql "select (count(*)=3 and bool_and(tenant_id='$csk'::uuid) and not exists(select 1 from public.shooting_lanes where tenant_id='$tenantB'::uuid and name like '$marker Mixed %'))::text from public.shooting_lanes where name like '$marker Mixed %';") -ne 'true') {
    throw 'Concurrent Tenant A/B operation contaminated Tenant B.'
  }
  Write-Output 'TENANT_A_B_CONCURRENT_NEGATIVE=PASS'

  $integrity = Invoke-LocalSql "select (not exists(select 1 from public.shooting_lanes child join public.shooting_lanes parent on parent.id=child.parent_lane_id where child.tenant_id<>parent.tenant_id) and not exists(select 1 from public.shooting_lanes lane where lane.name like '$marker%' and not exists(select 1 from public.lane_booking_rules r where r.lane_id=lane.id)) and (select count(*) from public.audit_logs where action='lane_booking_family_created' and target_name like '$marker%')=3)::text;"
  if ($integrity -ne 'true') { throw 'Concurrency broke hierarchy, configuration, or audit invariants.' }
  $deadlocksAfter = [int](Invoke-LocalSql "select deadlocks from pg_stat_database where datname=current_database();")
  if ($deadlocksAfter -ne $deadlocksBefore) { throw 'A database deadlock was recorded.' }
  Write-Output 'HIERARCHY_INTEGRITY_UNDER_RACE=PASS'
  Write-Output 'DUPLICATE_BROKEN_FAMILY_INVARIANTS=0'
  Write-Output 'CROSS_TENANT_HIERARCHY=0'
  Write-Output 'DEADLOCKS=0'
}
finally {
  $cleanup = "delete from public.audit_logs where target_name like '$marker%'; delete from public.lane_booking_family_configuration_versions where root_lane_id in(select id from public.shooting_lanes where name like '$marker%'); delete from public.lane_pricing_rules where lane_id in(select id from public.shooting_lanes where name like '$marker%'); delete from public.lane_booking_durations where lane_id in(select id from public.shooting_lanes where name like '$marker%'); delete from public.lane_booking_rules where lane_id in(select id from public.shooting_lanes where name like '$marker%'); delete from public.shooting_lanes where name like '$marker%'; delete from public.tenant_memberships where user_id in($userIds) or tenant_id='$tenantB'; delete from public.profiles where user_id in($userIds); delete from public.tenants where id='$tenantB'; delete from auth.users where id in($userIds); select (not exists(select 1 from auth.users where id in($userIds)) and not exists(select 1 from public.shooting_lanes where name like '$marker%') and not exists(select 1 from public.tenants where id='$tenantB'))::text;"
  $clean = Invoke-LocalSql $cleanup
  if (($clean -split "`n")[-1] -ne 'true') { throw 'Fixture cleanup failed.' }
  Write-Output 'fixture_cleanup=0'
}
