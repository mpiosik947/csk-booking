// Local-only, two-session regression. Never invokes a provider or remote database.
// Run: node tests/db/reminder-lock-wait.mjs [--deadline-only]
import { spawn, spawnSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import assert from 'node:assert/strict';

const container = 'supabase_db_csk-booking';
const args = ['exec', '-i', container, 'psql', '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-U', 'postgres', '-d', 'postgres'];
const port = spawnSync('docker', ['port', container, '5432/tcp'], { encoding: 'utf8' });
assert.equal(port.status, 0);
assert.ok(port.stdout.trim().split(/\r?\n/).every(value => /^(?:0\.0\.0\.0|127\.0\.0\.1|\[::\]):54322$/.test(value)));
function sql(input) {
  const result = spawnSync('docker', args, { input, encoding: 'utf8', timeout: 30000 });
  if (result.status !== 0) throw Error(result.stderr || String(result.error));
  return result.stdout.trim();
}
async function locked(claim, seconds, mutation, query) {
  const child = spawn('docker', args);
  let output = '', error = '';
  let ready;
  const acquired = new Promise(resolve => { ready = resolve; });
  const completed = new Promise((resolve, reject) => {
    child.stdout.on('data', data => { output += data; if (output.includes('LOCKED')) ready(); });
    child.stderr.on('data', data => { error += data; });
    child.on('error', reject);
    child.on('close', code => code ? reject(Error(error)) : resolve());
  });
  child.stdin.end(`begin; set local statement_timeout='20s'; select id from public.email_deliveries where claim_id='${claim}' for update; select 'LOCKED'; select pg_sleep(${seconds}); ${mutation} commit;`);
  await Promise.race([acquired, completed.then(() => { throw Error('Lock not acquired'); })]);
  let result;
  try { result = sql(query); } finally { await completed; }
  return JSON.parse(result);
}

let failures = 0;
for (const kind of ['booking', 'event']) {
  const cases = process.argv.includes('--deadline-only') ? ['deadline'] :
    ['deadline', 'control', 'lease', 'completion-lease', 'cancel', 'reschedule', 'generation', 'suspended', 'dormant', 'disabled'];
  for (const scenario of cases) {
    const [t, u, e, r, lane, price, b] = Array.from({ length: 7 }, () => randomUUID());
    const type = `${kind}_reminder_24h`;
    const table = kind === 'booking' ? 'reservations' : 'events';
    const id = kind === 'booking' ? b : e;
    let made = false;
    try {
      sql(`begin;
        insert into public.tenants(id,slug,name,status) values('${t}','lock-${t}','Synthetic lock test','active');
        insert into public.tenant_public_profiles(tenant_id,display_name,city,public_slug,is_public) values('${t}','Synthetic lock test','Test','lock-public-${t}',false);
        insert into public.tenant_plan_assignments(tenant_id,plan_id,status) select '${t}',id,'active' from public.saas_plans where plan_key='current_full_v1';
        insert into auth.users(id,email) values('${u}','${u}@example.invalid');
        insert into public.shooting_lanes(id,tenant_id,name,type,is_active,max_shooters,booking_step_minutes,display_order,currency_code,resource_kind,whole_lane_bookable,positions_bookable) values('${lane}','${t}','Synthetic','test',true,2,60,901,'PLN','lane',true,false);
        insert into public.lane_pricing_rules(id,lane_id,day_group,min_shooters,max_shooters,label,hourly_price,display_order,is_active) values('${price}','${lane}','mon_thu',1,2,'Synthetic',10,1,true);
        insert into public.events(id,tenant_id,title,event_date,start_time,end_time,is_active,created_at) select '${e}','${t}','Synthetic',d::date,d::time,'23:59:59.999999',true,now()-interval '3 days' from(select (clock_timestamp()+interval '2 hours') at time zone 'Europe/Warsaw' d)x;
        insert into public.event_registrations(id,tenant_id,event_id,user_id,customer_name,customer_email,customer_phone,registration_status,payment_status,created_at) values('${r}','${t}','${e}','${u}','Synthetic','synthetic@example.invalid','000','registered','pending',now()-interval '3 days');
        insert into public.reservations(id,user_id,tenant_id,lane_id,customer_name,customer_email,customer_phone,reservation_date,start_time,end_time,duration_minutes,price,reservation_status,payment_status,attendance_status,shooters_count,pricing_rule_id,pricing_day_group_snapshot,lane_name_snapshot,pricing_label_snapshot,price_per_hour_snapshot,total_price,currency_code,creation_request_id,created_at) select '${b}','${u}','${t}','${lane}','Synthetic','synthetic@example.invalid','000',d::date,d::time,'23:59:59.999999',60,10,'confirmed','pay_on_site','planned',1,'${price}','mon_thu','Synthetic','Synthetic',10,10,'PLN',gen_random_uuid(),now()-interval '3 days' from(select (clock_timestamp()+interval '2 hours') at time zone 'Europe/Warsaw' d)x;
        commit;`);
      made = true;
      if (scenario === 'deadline') {
        const dateColumn = kind === 'booking' ? 'reservation_date' : 'event_date';
        sql(`update public.${table} set ${dateColumn}=x.d::date,start_time=x.d::time from (select (clock_timestamp()+interval '1 hour 5 seconds') at time zone 'Europe/Warsaw' d)x where id='${id}';`);
      }
      sql('select public.discover_reminders_v1(); select public.claim_reminders_v1();');
      const claim = sql(`select claim_id from public.email_deliveries where recipient_user_id='${u}' and message_type='${type}' and delivery_state='sending';`);
      assert.match(claim, /^[0-9a-f-]{36}$/);
      if (scenario.includes('lease')) sql(`update public.email_deliveries set claim_expires_at=clock_timestamp()+interval '3 seconds' where claim_id='${claim}';`);
      let mutation = '';
      if (scenario === 'cancel') mutation = kind === 'booking' ? `update public.reservations set reservation_status='cancelled' where id='${b}';` : `update public.event_registrations set registration_status='cancelled' where id='${r}';`;
      if (['reschedule', 'generation'].includes(scenario)) mutation = `update public.${table} set start_time=start_time-interval '15 minutes' where id='${id}';`;
      if (scenario === 'generation') mutation += `update public.${table} set start_time=start_time+interval '15 minutes' where id='${id}';`;
      if (['suspended', 'dormant', 'disabled'].includes(scenario)) mutation = `update public.tenants set status='${scenario}' where id='${t}';`;
      const decision = scenario === 'completion-lease' ? `public.complete_reminder_v1('${claim}',true,'synthetic')` : `public.final_check_reminder_v1('${claim}') is not null`;
      const result = await locked(claim, scenario === 'deadline' ? 7 : scenario.includes('lease') ? 5 : 0.4, mutation,
        `select jsonb_build_object('allowed',${decision},'started_before',statement_timestamp()<(select scheduled_start-interval '1 hour' from public.reminder_schedules where ${kind === 'booking' ? 'reservation_id' : 'event_id'}='${id}'),'ended_after',clock_timestamp()>=(select scheduled_start-interval '1 hour' from public.reminder_schedules where ${kind === 'booking' ? 'reservation_id' : 'event_id'}='${id}'));`);
      assert.equal(result.allowed, ['control', 'suspended'].includes(scenario), JSON.stringify(result));
      if (scenario === 'deadline') { assert.equal(result.started_before, true); assert.equal(result.ended_after, true); }
      if (scenario === 'control') assert.equal(result.ended_after, false);
      console.log(`${kind}/${scenario}: PASS ${JSON.stringify(result)}`);
    } catch (error) {
      failures++;
      console.error(`${kind}/${scenario}: FAIL ${error.message}`);
    } finally {
      if (made) sql(`begin; delete from public.email_deliveries where recipient_user_id='${u}'; delete from public.event_registrations where id='${r}'; delete from public.events where id='${e}'; delete from public.reservations where id='${b}'; delete from public.lane_pricing_rules where id='${price}'; delete from public.shooting_lanes where id='${lane}'; delete from public.tenant_plan_assignments where tenant_id='${t}'; delete from public.tenant_public_profiles where tenant_id='${t}'; delete from auth.users where id='${u}'; delete from public.tenants where id='${t}'; commit;`);
      assert.equal(sql(`select (select count(*) from public.tenants where id='${t}')+(select count(*) from auth.users where id='${u}')+(select count(*) from public.email_deliveries where recipient_user_id='${u}')+(select count(*) from public.reminder_schedules where reservation_id='${b}' or event_id='${e}')+(select count(*) from public.reminder_occurrences where reservation_id='${b}' or registration_id='${r}');`), '0');
    }
  }
}
console.log(`FIXTURE CLEANUP=0; FAILURES=${failures}`);
process.exitCode = failures ? 1 : 0;
