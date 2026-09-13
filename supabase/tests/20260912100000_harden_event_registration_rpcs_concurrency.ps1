param(
  [string]$DockerContainerName = 'supabase_db_csk-booking',
  [switch]$ConfirmIsolatedDatabase
)

$ErrorActionPreference = 'Stop'
if (-not $ConfirmIsolatedDatabase) { throw 'Use only an isolated local database.' }

$tenant = 'c5c00000-0000-4000-8000-000000000001'
$event = [guid]::NewGuid().ToString()
$userA = [guid]::NewGuid().ToString()
$userB = [guid]::NewGuid().ToString()
$run = [guid]::NewGuid().ToString('N')

function Invoke-LocalSql([string]$Sql) {
  $output = $Sql | & docker exec -i $DockerContainerName psql -v ON_ERROR_STOP=1 -U postgres -d postgres -At
  if ($LASTEXITCODE -ne 0) { throw "Local SQL failed: $output" }
  return ($output -join "`n").Trim()
}

$setup = @"
insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at) values
('$userA','00000000-0000-0000-0000-000000000000','authenticated','authenticated','9d2a-race-a-$run@example.invalid','',now(),'{}','{}',now(),now()),
('$userB','00000000-0000-0000-0000-000000000000','authenticated','authenticated','9d2a-race-b-$run@example.invalid','',now(),'{}','{}',now(),now());
insert into public.profiles(id,user_id,email,phone,first_name,last_name,full_name,role,verification_status)
select id,id,email,'000','Test','Race','[TEST][SAAS-9D-2A][$run]','user','verified' from auth.users
where id in('$userA','$userB') and not exists(select 1 from public.profiles where profiles.user_id=auth.users.id);
update public.profiles set phone='000',first_name='Test',last_name='Race',full_name='[TEST][SAAS-9D-2A][$run]',verification_status='verified' where user_id in('$userA','$userB');
insert into public.events(id,tenant_id,title,description,event_date,start_time,end_time,location,price,max_participants,is_active)
values('$event','$tenant','[TEST][SAAS-9D-2A][$run] Race','race',date '2099-12-01',time '10:00',time '11:00','Test',0,1,true);
"@

$callTemplate = @"
begin;
select set_config('request.jwt.claims',jsonb_build_object('sub','{0}','role','authenticated')::text,true);
select set_config('request.jwt.claim.sub','{0}',true);
set local role authenticated;
select public.register_for_event('$event',false)::text;
commit;
"@

try {
  Invoke-LocalSql $setup | Out-Null
  $jobA = Start-Job -ScriptBlock {
    param($container,$sql)
    $result = $sql | & docker exec -i $container psql -v ON_ERROR_STOP=1 -U postgres -d postgres -At
    if ($LASTEXITCODE -ne 0) { throw ($result -join "`n") }
    ($result -join "`n")
  } -ArgumentList $DockerContainerName,($callTemplate -f $userA)
  $jobB = Start-Job -ScriptBlock {
    param($container,$sql)
    $result = $sql | & docker exec -i $container psql -v ON_ERROR_STOP=1 -U postgres -d postgres -At
    if ($LASTEXITCODE -ne 0) { throw ($result -join "`n") }
    ($result -join "`n")
  } -ArgumentList $DockerContainerName,($callTemplate -f $userB)
  Wait-Job $jobA,$jobB | Out-Null
  $resultA = Receive-Job $jobA
  $resultB = Receive-Job $jobB
  Remove-Job $jobA,$jobB -Force
  $combined = ($resultA + $resultB) -join "`n"
  if (($combined | Select-String '"code": "registered"' -AllMatches).Matches.Count -ne 1) { throw 'Expected exactly one registered result.' }
  if (($combined | Select-String '"code": "reserve"' -AllMatches).Matches.Count -ne 1) { throw 'Expected exactly one reserve result.' }
  $check = Invoke-LocalSql "select (count(*)=2 and count(*) filter(where registration_status='registered')=1 and count(*) filter(where registration_status='reserve')=1 and bool_and(tenant_id='$tenant'::uuid))::text from public.event_registrations where event_id='$event';"
  if ($check -ne 'true') { throw 'Concurrent registration state differs.' }
  Write-Output 'SAAS-9D-2A registration concurrency: PASS'
}
finally {
  $cleanup = "delete from public.event_registrations where event_id='$event'; delete from public.events where id='$event'; delete from public.tenant_memberships where user_id in('$userA','$userB'); delete from public.profiles where user_id in('$userA','$userB'); delete from auth.users where id in('$userA','$userB'); select (not exists(select 1 from auth.users where id in('$userA','$userB')) and not exists(select 1 from public.events where id='$event'))::text;"
  $clean = Invoke-LocalSql $cleanup
  if (($clean -split "`n")[-1] -ne 'true') { throw 'Fixture cleanup failed.' }
  Write-Output 'fixture_cleanup=0'
}
