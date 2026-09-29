import { spawn, spawnSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import assert from 'node:assert/strict';

// Explicit isolated-local database only; never run against a linked project.
export async function runInstructorAtomicEditRaces(database) {
  if (!/^c2b_[a-f0-9]{16}$/.test(database)) throw Error('ISOLATED_LOCAL_ONLY');
  const args = ['exec', '-i', 'supabase_db_csk-booking', 'psql', '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-U', 'postgres', '-d', database];
  const sql = statement => {
    const result = spawnSync('docker', args, { input: statement, encoding: 'utf8', timeout: 20000 });
    if (result.status) throw Error(result.stderr);
    return result.stdout.trim();
  };
  function hold(statement) {
    const child = spawn('docker', args);
    let output = '', errors = '', readyResolve;
    const ready = new Promise(resolve => { readyResolve = resolve; });
    const done = new Promise((resolve, reject) => {
      child.stdout.on('data', data => { output += data; if (output.includes('LOCK_HELD')) readyResolve(); });
      child.stderr.on('data', data => { errors += data; });
      child.on('error', reject);
      child.on('close', code => code ? reject(Error(errors)) : resolve(output));
    });
    child.stdin.end(statement + "\nselect 'LOCK_HELD'; select pg_sleep(0.7); commit;");
    return { ready: Promise.race([ready, done.then(() => { if (!output.includes('LOCK_HELD')) throw Error('NO_LOCK'); })]), done };
  }
  const [tenant, admin, employee, instructor, other, event] = Array.from({ length: 6 }, randomUUID);
  const auth = actor => `select set_config('request.jwt.claim.sub','${actor}',true); select set_config('request.jwt.claims','{"sub":"${actor}","role":"authenticated"}',true); set local role authenticated;`;
  const value = output => JSON.parse(output.split(/\r?\n/).filter(line => line.startsWith('{')).at(-1));
  const get = () => ({...value(sql(`begin; ${auth(admin)} select public.admin_list_available_event_instructors_v1('${event}'); rollback;`)), event_revision: JSON.parse(sql(`select public.instructor_event_revision_v1('${event}');`))});
  const set = (actor, ids, revision, eventRevision) => `${auth(actor)} select public.admin_update_event_with_instructors_v1('${tenant}','${event}','Changed',null,current_date+30,'10:00','11:00',null,0,10,'{}',array[${ids.map(id => `'${id}'`).join(',')}]::uuid[],'${JSON.stringify(eventRevision).replaceAll("'", "''")}'::jsonb,'${revision}');`;
  try {
    sql(`begin;
      insert into public.tenants(id,slug,name,status) values('${tenant}','i1bc-race-${tenant}','Synthetic','active');
      insert into public.tenant_plan_assignments(tenant_id,plan_id,status) select '${tenant}',id,'active' from public.saas_plans where plan_key='current_full_v1';
      insert into auth.users(id,email,email_confirmed_at) select u,u||'@example.invalid',now() from unnest(array['${admin}','${employee}','${instructor}','${other}']::uuid[])u;
      insert into public.profiles(id,user_id,email) select id,id,email from auth.users where id in('${admin}','${employee}','${instructor}','${other}') on conflict(user_id) do nothing;
      insert into public.tenant_memberships(tenant_id,user_id,role,status) values('${tenant}','${admin}','admin','active'),('${tenant}','${employee}','admin','active'),('${tenant}','${instructor}','instructor','active'),('${tenant}','${other}','instructor','active');
      insert into public.events(id,tenant_id,title,event_date,start_time,end_time,max_participants,is_active) values('${event}','${tenant}','Synthetic',current_date+30,'10:00','11:00',10,true);
      commit;`);
    for (const scenario of ['simultaneous-add', 'add-remove']) {
      const before = get();
      const firstIds = scenario === 'simultaneous-add' ? [instructor] : [];
      const secondIds = scenario === 'simultaneous-add' ? [other] : [instructor, other];
      const first = hold('begin;' + set(admin, firstIds, before.revision, before.event_revision));
      await first.ready;
      assert.throws(() => sql('begin;' + set(employee, secondIds, before.revision, before.event_revision) + 'commit;'), /(Event|Assignment) revision conflict/);
      await first.done;
      assert.deepEqual(get().active_user_ids, firstIds);
      assert.equal(sql(`select count(*) from (select instructor_user_id from public.event_instructors where event_id='${event}' and unassigned_at is null group by instructor_user_id having count(*)>1)x;`), '0');
      console.log(`INSTRUCTOR_ATOMIC_RACE ${scenario}: PASS one winner; stale edit denied; no lost update`);
    }
    assert.equal(sql(`select count(*) from public.event_instructors where event_id='${event}' and unassigned_at is not null;`), '1');
    const beforeSuspension = get();
    const suspension = hold(`begin; update public.tenant_memberships set status='suspended' where tenant_id='${tenant}' and user_id='${instructor}';`);
    await suspension.ready;
    assert.throws(() => sql('begin;' + set(admin, [instructor], beforeSuspension.revision, beforeSuspension.event_revision) + 'commit;'), /Invalid instructor membership/);
    await suspension.done;
    assert.deepEqual(get().active_user_ids, []);
    console.log('INSTRUCTOR_ATOMIC_RACE membership-suspension: PASS revalidated after lock wait');
  } finally {
    sql(`begin;
      delete from public.events where id='${event}';
      delete from public.tenant_plan_assignments where tenant_id='${tenant}';
      delete from public.tenant_public_profiles where tenant_id='${tenant}';
      delete from auth.users where id in('${admin}','${employee}','${instructor}','${other}');
      delete from public.tenants where id='${tenant}'; commit;`);
    assert.equal(sql(`select (select count(*) from public.event_instructors where tenant_id='${tenant}')+(select count(*) from public.events where id='${event}')+(select count(*) from auth.users where id in('${admin}','${employee}','${instructor}','${other}'));`), '0');
    console.log('INSTRUCTOR_ATOMIC_RACE_FIXTURE_CLEANUP=0');
  }
}
