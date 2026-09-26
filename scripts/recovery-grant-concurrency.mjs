import { spawn, spawnSync } from 'node:child_process';
import { randomUUID, randomBytes } from 'node:crypto';
import assert from 'node:assert/strict';

export async function recoveryConcurrency(database) {
  if (!/^p10e_isolated_[0-9a-f]{16}$/.test(database)) throw Error('SCRATCH_ONLY');
  const args=['exec','-i','supabase_db_csk-booking','psql','-X','-At','-v','ON_ERROR_STOP=1','-U','postgres','-d',database];
  const sql=q=>{const r=spawnSync('docker',args,{input:q,encoding:'utf8'});if(r.status!==0)throw Error(r.stderr);return r.stdout.trim();};
  const u=randomUUID(),s=randomUUID(),h=randomBytes(32).toString('hex');
  try {
    sql(`INSERT INTO auth.users(id,email) VALUES('${u}','recovery-race@example.invalid'); INSERT INTO auth.sessions(id,user_id) VALUES('${s}','${u}'); SELECT public.create_recovery_grant_v1('${s}','${h}');`);
    const run=()=>new Promise((resolve,reject)=>{
      const p=spawn('docker',args); let out='',err='';
      p.stdout.on('data',v=>out+=v);p.stderr.on('data',v=>err+=v);p.on('error',reject);
      p.on('close',code=>code===0?resolve(out.trim().split(/\r?\n/).filter(l=>l==='t'||l==='f')[0]):reject(Error(err)));
      p.stdin.end(`BEGIN; SET LOCAL statement_timeout='10s'; SET LOCAL request.jwt.claims='{"sub":"${u}","session_id":"${s}","role":"authenticated"}'; SET LOCAL ROLE authenticated; SELECT public.consume_recovery_grant_v1('${h}'); SELECT pg_sleep(0.2); COMMIT;`);
    });
    const results=await Promise.all(Array.from({length:8},run));
    assert.equal(results.filter(v=>v==='t').length,1);
    assert.equal(results.filter(v=>v==='f').length,7);
    assert.equal(sql(`SELECT count(*) FROM public.recovery_grants WHERE grant_hash='${h}' AND consumed_at IS NOT NULL;`),'1');
    console.log('RECOVERY_CONCURRENCY=1 WINNER / 7 DENIED; DEADLOCKS=0; VALID_SESSION_REPLAY=DENIED');
  } finally {
    sql(`DELETE FROM auth.sessions WHERE id='${s}'; DELETE FROM public.profiles WHERE user_id='${u}'; DELETE FROM auth.users WHERE id='${u}';`);
    assert.equal(sql(`SELECT (SELECT count(*) FROM auth.users WHERE id='${u}')+(SELECT count(*) FROM auth.sessions WHERE id='${s}')+(SELECT count(*) FROM public.recovery_grants WHERE grant_hash='${h}');`),'0');
    console.log('RECOVERY_CONCURRENCY_FIXTURE_CLEANUP=0');
  }
}
