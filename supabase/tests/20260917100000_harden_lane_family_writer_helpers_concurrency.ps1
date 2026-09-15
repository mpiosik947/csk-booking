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
$run = [guid]::NewGuid().ToString('N')
$marker = "[TEST][SAAS-9D-3C-RACE][$run]"
$userIds = "'$adminA1','$adminA2'"

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
  try { return @((Receive-Job $First -ErrorAction Stop), (Receive-Job $Second -ErrorAction Stop)) }
  finally { Remove-Job $First,$Second -Force }
}

function New-FamilyPayload([string]$Name) {
  $root = @{
    name=$Name; is_active=$true; online_bookable=$true; max_shooters=4;
    max_people_online=4; booking_step_minutes=60; durations_minutes=@(60,120);
    pricing=@(
      @{day_group='mon_thu';min_shooters=1;max_shooters=4;label='Pon-Czw';hourly_price=100},
      @{day_group='fri_sun';min_shooters=1;max_shooters=4;label='Pt-Nd';hourly_price=120}
    ); whole_lane_bookable=$true; positions_bookable=$true
  }
  $child = @{
    name="$Name Child"; is_active=$true; online_bookable=$true; max_shooters=2;
    max_people_online=2; booking_step_minutes=60; durations_minutes=@(60,120);
    pricing=@(
      @{day_group='mon_thu';min_shooters=1;max_shooters=2;label='Pon-Czw';hourly_price=50},
      @{day_group='fri_sun';min_shooters=1;max_shooters=2;label='Pt-Nd';hourly_price=60}
    )
  }
  (@{root=$root;positions=@($child)} | ConvertTo-Json -Depth 8 -Compress)
}

function New-ActorSql([string]$User,[string]$Call) {
  "begin; select set_config('request.jwt.claims',jsonb_build_object('sub','$User','role','authenticated')::text,true); select set_config('request.jwt.claim.sub','$User',true); set local role authenticated; $Call; commit;"
}

function New-UpdateSql([string]$User,[string]$Root,[long]$Version,[string]$PayloadBase64,[int]$DelayMilliseconds = 0) {
  $delay = if ($DelayMilliseconds -gt 0) { "select pg_sleep($($DelayMilliseconds / 1000.0)); " } else { '' }
  $call = "${delay}select public.admin_set_lane_booking_family_configuration_v2('$Root',$Version,convert_from(decode('$PayloadBase64','base64'),'UTF8')::jsonb,false)->>'code'"
  New-ActorSql $User $call
}

function Get-Version([string]$Root) {
  [long](Invoke-LocalSql "select configuration_version from public.lane_booking_family_configuration_versions where root_lane_id='$Root';")
}

function Get-RenamePayloadBase64([string]$Root,[string]$Name) {
  $escaped = $Name.Replace("'","''")
  Invoke-LocalSql "select encode(convert_to(jsonb_agg(case when item->>'lane_id'='$Root' then item||jsonb_build_object('name','$escaped') else item end order by item->>'lane_id')::text,'UTF8'),'base64') from jsonb_array_elements(public.lane_booking_family_business_snapshot_v2('$Root')) item;"
}

function Get-MixedPayloadBase64([string]$Root,[string]$Child,[string]$ForeignRoot) {
  Invoke-LocalSql "select encode(convert_to(jsonb_agg(case when item->>'lane_id'='$Child' then item||jsonb_build_object('lane_id','$ForeignRoot'::uuid) else item end order by item->>'lane_id')::text,'UTF8'),'base64') from jsonb_array_elements(public.lane_booking_family_business_snapshot_v2('$Root')) item;"
}

$setup = @"
insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at) values
('$adminA1','00000000-0000-0000-0000-000000000000','authenticated','authenticated','9d3c-a1-$run@example.invalid','',now(),'{}','{}',now(),now()),
('$adminA2','00000000-0000-0000-0000-000000000000','authenticated','authenticated','9d3c-a2-$run@example.invalid','',now(),'{}','{}',now(),now());
insert into public.profiles(id,user_id,email,role,verification_status)
select id,id,email,'user','verified' from auth.users u where id in($userIds)
and not exists(select 1 from public.profiles p where p.user_id=u.id);
update public.profiles set role='admin',first_name='Test',last_name='9D3C Race',full_name='$marker',verification_status='verified'
where user_id in($userIds);
insert into public.tenants(id,name,slug,status) values('$tenantB','$marker Tenant B','saas9d3c-race-$($run.Substring(0,12))','dormant');
"@

try {
  Invoke-LocalSql $setup | Out-Null
  $deadlocksBefore = [int](Invoke-LocalSql "select deadlocks from pg_stat_database where datname=current_database();")
  $createPayload = (New-FamilyPayload "$marker Family").Replace("'","''")
  $created = Invoke-LocalSql (New-ActorSql $adminA1 "select public.admin_create_lane_booking_family_v1('$createPayload'::jsonb)->>'root_lane_id'")
  $rootMatches = [regex]::Matches($created,'(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}')
  $root = if ($rootMatches.Count -gt 0) { $rootMatches[$rootMatches.Count - 1].Value } else { '' }
  if ($root -notmatch '^[0-9a-f-]{36}$') { throw "Family setup failed: $created" }
  $child = Invoke-LocalSql "select id from public.shooting_lanes where parent_lane_id='$root';"
  $rootB = [guid]::NewGuid().ToString()
  Invoke-LocalSql "insert into public.shooting_lanes(id,tenant_id,name,type,price_per_hour,is_active,max_shooters,booking_step_minutes,display_order,currency_code,resource_kind,parent_lane_id,whole_lane_bookable,positions_bookable) values('$rootB','$tenantB','$marker Root B','test',0,false,2,60,9990,'PLN','lane',null,true,false);" | Out-Null

  $version = Get-Version $root
  $payload1 = Get-RenamePayloadBase64 $root "$marker Concurrent 1"
  $payload2 = Get-RenamePayloadBase64 $root "$marker Concurrent 2"
  $pair = Receive-Pair (Start-LocalSqlJob (New-UpdateSql $adminA1 $root $version $payload1)) (Start-LocalSqlJob (New-UpdateSql $adminA2 $root $version $payload2))
  $joined = $pair -join "`n"
  if (([regex]::Matches($joined,'(?m)^updated\r?$')).Count -ne 1 -or ([regex]::Matches($joined,'(?m)^stale_configuration\r?$')).Count -ne 1) { throw "Concurrent optimistic results differ: $joined" }
  if ((Get-Version $root) -ne ($version + 1)) { throw 'Concurrent writer incremented version more than once.' }
  if ((Invoke-LocalSql "select (count(*)=1)::text from public.audit_logs where action='lane_booking_family_configuration_updated' and target_id='$root';") -ne 'true') { throw 'Concurrent writer created an invalid audit count.' }
  Write-Output 'CONCURRENT_FAMILY_WRITER=PASS'
  Write-Output 'OPTIMISTIC_LOCK_ONE_WINNER=PASS'

  $version = Get-Version $root
  $validPayload = Get-RenamePayloadBase64 $root "$marker Mixed Winner"
  $mixedPayload = Get-MixedPayloadBase64 $root $child $rootB
  $pair = Receive-Pair (Start-LocalSqlJob (New-UpdateSql $adminA1 $root $version $validPayload 250)) (Start-LocalSqlJob (New-UpdateSql $adminA2 $root $version $mixedPayload))
  $joined = $pair -join "`n"
  if (([regex]::Matches($joined,'(?m)^updated\r?$')).Count -ne 1 -or ([regex]::Matches($joined,'(?m)^invalid_payload\r?$')).Count -ne 1) { throw "Concurrent mixed-tenant results differ: $joined" }
  if ((Get-Version $root) -ne ($version + 1)) { throw 'Rejected mixed family changed the version.' }
  if ((Invoke-LocalSql "select (name='$marker Root B' and tenant_id='$tenantB'::uuid)::text from public.shooting_lanes where id='$rootB';") -ne 'true') { throw 'Mixed family operation contaminated Tenant B.' }
  Write-Output 'CONCURRENT_REPARENT_UPDATE_DENIAL=PASS'
  Write-Output 'TENANT_A_B_SIMULTANEOUS_OPERATIONS=PASS'

  $version = Get-Version $root
  $validPayload = Get-RenamePayloadBase64 $root "$marker Final Winner"
  $foreign = New-ActorSql $adminA1 "select public.admin_set_lane_booking_family_configuration_v2('$rootB',1,'[]'::jsonb,false)->>'code'"
  $pair = Receive-Pair (Start-LocalSqlJob (New-UpdateSql $adminA2 $root $version $validPayload)) (Start-LocalSqlJob $foreign)
  $joined = $pair -join "`n"
  if (([regex]::Matches($joined,'(?m)^updated\r?$')).Count -ne 1 -or ([regex]::Matches($joined,'(?m)^not_allowed\r?$')).Count -ne 1) { throw "Concurrent foreign-root results differ: $joined" }
  Write-Output 'FOREIGN_ROOT_CONCURRENT_DENIAL=PASS'

  $integrity = Invoke-LocalSql "select (not exists(select 1 from public.shooting_lanes child join public.shooting_lanes parent on parent.id=child.parent_lane_id where child.tenant_id<>parent.tenant_id) and (select count(*) from public.shooting_lanes where id='$root' or parent_lane_id='$root')=2 and (select count(*) from public.lane_booking_rules where lane_id in('$root','$child'))=2 and (select count(*) from public.lane_booking_family_configuration_versions where root_lane_id='$root')=1)::text;"
  if ($integrity -ne 'true') { throw 'Concurrency broke hierarchy or configuration invariants.' }
  $deadlocksAfter = [int](Invoke-LocalSql "select deadlocks from pg_stat_database where datname=current_database();")
  if ($deadlocksAfter -ne $deadlocksBefore) { throw 'A database deadlock was recorded.' }
  Write-Output 'HELPER_CALLS_UNDER_CONTENTION=PASS'
  Write-Output 'HIERARCHY_INVARIANT_UNDER_RACE=PASS'
  Write-Output 'BROKEN_FAMILY_INVARIANTS=0'
  Write-Output 'CROSS_TENANT_HIERARCHY=0'
  Write-Output 'INVALID_FINAL_STATE=0'
  Write-Output 'DEADLOCKS=0'
}
finally {
  $cleanup = "delete from public.audit_logs where target_name like '$marker%' or target_id in(select id from public.shooting_lanes where name like '$marker%'); delete from public.lane_booking_family_configuration_versions where root_lane_id in(select id from public.shooting_lanes where name like '$marker%'); delete from public.lane_pricing_rules where lane_id in(select id from public.shooting_lanes where name like '$marker%'); delete from public.lane_booking_durations where lane_id in(select id from public.shooting_lanes where name like '$marker%'); delete from public.lane_booking_rules where lane_id in(select id from public.shooting_lanes where name like '$marker%'); delete from public.shooting_lanes where name like '$marker%'; delete from public.tenant_memberships where user_id in($userIds) or tenant_id='$tenantB'; delete from public.profiles where user_id in($userIds); delete from public.tenants where id='$tenantB'; delete from auth.users where id in($userIds); select (not exists(select 1 from auth.users where id in($userIds)) and not exists(select 1 from public.shooting_lanes where name like '$marker%') and not exists(select 1 from public.tenants where id='$tenantB'))::text;"
  $clean = Invoke-LocalSql $cleanup
  if (($clean -split "`n")[-1] -ne 'true') { throw 'Fixture cleanup failed.' }
  Write-Output 'fixture_cleanup=0'
}
