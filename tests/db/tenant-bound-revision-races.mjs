// Isolated disposable local database only. Caller must drop it after completion.
import fs from 'node:fs';
import {spawn,spawnSync} from 'node:child_process';
import {randomUUID} from 'node:crypto';
const [db,report]=process.argv.slice(2);
if(!/^sbr[23]_[a-f0-9]{16}$/.test(db??'')||!report)throw Error('LOCAL_SCRATCH_REQUIRED');
const args=['exec','-i','supabase_db_csk-booking','psql','-X','-At','-v','VERBOSITY=verbose','-v','ON_ERROR_STOP=1','-U','postgres','-d',db];
const rows=[];
function sql(q){const r=spawnSync('docker',args,{input:q,encoding:'utf8'});if(r.status)throw Error(r.stderr);return r.stdout.trim();}
const pa=randomUUID(),admin=randomUUID();
sql(`begin;insert into auth.users(id,email,email_confirmed_at,is_anonymous)values('${pa}','${pa}@synthetic.invalid',now(),false),('${admin}','${admin}@synthetic.invalid',now(),false);insert into public.platform_admins(user_id,status)values('${pa}','active');commit;`);
const actor=q=>`select set_config('app.product10d_test_enforce','on',true);select set_config('request.jwt.claims','{"sub":"${pa}","role":"authenticated"}',true);select set_config('request.jwt.claim.sub','${pa}',true);set local role authenticated;${q};reset role;`;
function fixture(){
 const a=randomUUID(),b=randomUUID();
 sql(`begin;insert into public.tenants(id,name,slug,status,lifecycle_revision)select id,'Synthetic revision race','sybr-race-'||id,'active',13 from unnest(array['${a}'::uuid,'${b}'::uuid])id;
 insert into public.tenant_public_profiles(tenant_id,public_slug,display_name,city,is_public,show_booking,show_events,show_instructor,show_pricing)select id,'sybr-public-'||id,'Synthetic','Synthetic',false,false,false,false,false from unnest(array['${a}'::uuid,'${b}'::uuid])id;
 insert into public.tenant_memberships(tenant_id,user_id,role,status)select id,'${admin}','admin','active' from unnest(array['${a}'::uuid,'${b}'::uuid])id;
 insert into public.tenant_plan_assignments(tenant_id,plan_id,status,revision)select t.id,p.id,'active',13 from unnest(array['${a}'::uuid,'${b}'::uuid])t(id) cross join public.saas_plans p where plan_key='booking_only_v1';commit;`);
 return {a,b};
}
const rev=t=>sql(`select lifecycle_revision from public.tenants where id='${t}';`);
const arch=(t,token=rev(t),request=randomUUID())=>actor(`select public.platform_archive_tenant_v1('${t}',${token},'${request}')`);
const plan=t=>actor(`select public.platform_change_tenant_plan_v2('${t}','current_full_v1','${sql(`select revision from public.tenant_plan_assignments where tenant_id='${t}';`)}','${randomUUID()}')`);
async function race(label,first,second,{deny=false,commit=false,expectedFirstNotice}={}){
 let outA='',errA='',outB='',errB='',b,doneB,startB,endA,endB;
 const a=spawn('docker',args,{windowsHide:true});const doneA=new Promise(r=>a.on('close',c=>{endA=Date.now();r(c);}));
 a.stderr.on('data',v=>errA+=v);a.stdout.on('data',v=>{
  outA+=v;if(!b&&outA.includes('REVISION_HOLD')){
   startB=Date.now();b=spawn('docker',args,{windowsHide:true});doneB=new Promise(r=>b.on('close',c=>{endB=Date.now();r(c);}));
   b.stdout.on('data',v=>outB+=v);b.stderr.on('data',v=>errB+=v);
   b.stdin.end(`begin;set local lock_timeout='4s';set local statement_timeout='7s';${second}rollback;`);
  }
 });
 a.stdin.end(`begin;set local lock_timeout='4s';set local statement_timeout='7s';${first}
 select jsonb_build_object('allocator_locks',(select jsonb_agg(jsonb_build_object('mode',mode,'granted',granted)) from pg_locks where pid=pg_backend_pid() and relation='app_private.tenant_concurrency_revision_seq'::regclass));
 select 'REVISION_HOLD';select pg_sleep(1.5);${commit?'commit':'rollback'};`);
 const exitA=await doneA;if(!b)throw Error(label+' holder failed '+errA);const exitB=await doneB;
 const deadlock=/40P01/.test(errA+errB),timeout=/57014|canceling statement due to lock timeout/.test(errA+errB);
 const revisions=s=>[...s.matchAll(/"revision":\s*"?(\d+)/g)].map(m=>m[1]);
 const issued=[...revisions(outA),...revisions(outB)];
 const pass=exitA===0&&!deadlock&&!timeout&&(deny?exitB!==0&&/55P03/.test(errB):exitB===0&&endB<endA)&&(!expectedFirstNotice||errA.includes(expectedFirstNotice))&&new Set(issued).size===issued.length;
 const row={label,pass,exitA,exitB,contenderMs:endB-startB,contenderFinishedBeforeHolder:endB<endA,deadlock,timeout,issued,outA,errA,outB,errB};rows.push(row);
 console.log(JSON.stringify({...row,outA:undefined,errA:undefined,outB:undefined,errB:undefined}));
 if(!pass)throw Error('RACE_FAILED '+label);return row;
}
try{
 let x=fixture();await race('actual archive A vs actual archive B',arch(x.a),arch(x.b));
 x=fixture();await race('actual plan upgrade A vs actual plan upgrade B',plan(x.a),plan(x.b));
 x=fixture();const substituted=actor(`do $proof$ begin begin perform public.platform_archive_tenant_v1('${x.b}',${rev(x.a)},'${randomUUID()}');raise exception 'UNEXPECTED_SUBSTITUTION';exception when sqlstate 'PT409' then raise notice 'EXPECTED_TOKEN_DENIAL';end;end;$proof$`);
 await race('A token substitution denied while fresh B mutation completes',substituted,arch(x.b),{expectedFirstNotice:'EXPECTED_TOKEN_DENIAL'});
 x=fixture();const request=randomUUID(),token=rev(x.a),mutation=arch(x.a,token,request);
 const replayRace=await race('same request concurrency fails fast then safely replays',mutation,mutation,{deny:true,commit:true});
 const replay=sql('begin;'+mutation+'commit;');
 const firstResult=replayRace.outA.split(/\r?\n/).find(s=>s.startsWith('{')&&s.includes('"tenant_id"'));
 const replayResult=replay.split(/\r?\n/).find(s=>s.startsWith('{')&&s.includes('"tenant_id"'));
 const audits=Number(sql(`select count(*) from public.platform_audit_logs where tenant_id='${x.a}' and action='tenant_archived';`));
 if(firstResult!==replayResult||audits!==1)throw Error('REPLAY_REGRESSION');
 rows.push({label:'committed replay exact result and one audit',pass:true,audits});
 const changed=sql('begin;'+actor(`do $proof$ begin begin perform public.platform_archive_tenant_v1('${x.b}',${rev(x.b)},'${request}');raise exception 'UNEXPECTED_PAYLOAD_REUSE';exception when sqlstate '22023' then raise notice 'EXPECTED_PAYLOAD_DENIAL';end;end;$proof$`)+"select 'PAYLOAD_DENIED';rollback;");
 if(!changed.includes('PAYLOAD_DENIED'))throw Error('PAYLOAD_REUSE');rows.push({label:'same request different target denied',pass:true});
}catch(error){console.error(error.message);process.exitCode=1;}
finally{fs.writeFileSync(report,JSON.stringify({db,rows,productionWrites:0},null,2));}
