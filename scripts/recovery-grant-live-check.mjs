// Real LOCAL GoTrue + PostgREST + DB. Only fault injection is the final Auth
// mutation/signOut result; there is no application runtime test bypass.
import fs from 'node:fs';
import ts from 'typescript';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { createClient } from '@supabase/supabase-js';
import { NextResponse } from 'next/server.js';
import * as context from '../lib/server/recovery-context.ts';
import { getPasswordLengthError } from '../lib/password-policy.ts';

const env=Object.fromEntries(fs.readFileSync('.env.local','utf8').split(/\r?\n/).filter(l=>l.includes('=')&&!l.startsWith('#')).map(l=>{const i=l.indexOf('=');return[l.slice(0,i),l.slice(i+1).replace(/^['"]|['"]$/g,'')];}));
const url=env.NEXT_PUBLIC_SUPABASE_URL;
if (!['127.0.0.1','localhost'].includes(new URL(url).hostname)) throw Error('LOCAL_ONLY');
const options={auth:{persistSession:false,autoRefreshToken:false,detectSessionInUrl:false}};
const admin=createClient(url,env.SUPABASE_SERVICE_ROLE_KEY,options);
const js=ts.transpileModule(fs.readFileSync('app/auth/recovery/route.ts','utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText;
let passed=0;
for(const mode of ['signout-failure','update-failure','concurrent']) {
  const email=`recovery-grant-${randomUUID()}@example.invalid`;
  const created=await admin.auth.admin.createUser({email,password:'Synthetic-Initial-Password-123!',email_confirm:true});
  if(created.error||!created.data.user)throw Error('Fixture creation failed');
  const uid=created.data.user.id;
  const client=createClient(url,env.NEXT_PUBLIC_SUPABASE_ANON_KEY,options);
  try {
    const link=await admin.auth.admin.generateLink({type:'recovery',email});
    assert.equal(Boolean(link.error),false);
    const verified=await client.auth.verifyOtp({token_hash:link.data.properties.hashed_token,type:'recovery'});
    assert.equal(Boolean(verified.error),false);
    const session=verified.data.session;
    assert.ok(session);
    const raw=context.newRecoveryGrant(),hash=context.recoveryGrantHash(raw);
    const minted=await admin.rpc('create_recovery_grant_v1',{p_session_id:context.sessionIdentity(session.access_token),p_grant_hash:hash});
    assert.equal(minted.data,true,'server mint');
    const denied=await client.rpc('create_recovery_grant_v1',{p_session_id:context.sessionIdentity(session.access_token),p_grant_hash:context.recoveryGrantHash(context.newRecoveryGrant())});
    assert.ok(denied.error,'browser-equivalent client cannot mint');
    let updates=0;
    const wrapped={rpc:(...args)=>client.rpc(...args),auth:{
      getSession:()=>client.auth.getSession(),getUser:(token)=>client.auth.getUser(token),
      updateUser:async input=>{updates++;return mode==='update-failure'?{error:{message:'Synthetic rejection'}}:client.auth.updateUser(input);},
      signOut:async()=>({error:{message:'Synthetic signOut transport failure'}}),
    }};
    const loaded={exports:{}};
    const resolve=name=>{
      if(name==='next/server')return{NextResponse};
      if(name.endsWith('recovery-context'))return context;
      if(name.endsWith('password-policy'))return{getPasswordLengthError};
      if(name.endsWith('recovery-http'))return{
        recoveryOrigin:()=> 'https://strzelajtu.pl',protectResponse:r=>r,recoveryClient:()=>wrapped,
        clearRecovery:r=>r.cookies.set(context.RECOVERY_COOKIE,'',{httpOnly:true,path:'/auth',maxAge:0}),
      };
      throw Error('Unexpected import');
    };
    new Function('require','module','exports',js)(resolve,loaded,loaded.exports);
    const request={headers:new Headers({origin:'https://strzelajtu.pl','content-type':'application/json'}),cookies:{get:()=>({value:raw})},text:async()=>JSON.stringify({password:'Synthetic-New-Password-123!'})};
    if(mode==='concurrent') {
      const responses=await Promise.all([loaded.exports.POST(request),loaded.exports.POST(request)]);
      assert.deepEqual(responses.map(r=>r.status).sort(),[403,503]);
    } else {
      const response=await loaded.exports.POST(request);
      assert.equal(response.status,mode==='update-failure'?400:503);
      assert.equal((await response.json()).status,mode==='update-failure'?'fresh_recovery_link_required':'password_changed_session_cleanup_failed');
      assert.equal(response.cookies.get(context.RECOVERY_COOKIE).maxAge,0);
    }
    assert.equal(updates,1);
    const stillValid=await client.auth.getUser(session.access_token);
    assert.equal(stillValid.data.user?.id,uid,'session remains valid when signOut failed');
    assert.equal((await loaded.exports.POST(request)).status,403,'captured cookie replay');
    assert.equal(updates,1,'no second mutation');
    assert.equal((await client.rpc('check_recovery_grant_v1',{p_grant_hash:hash})).data,false);
    console.log(`LIVE_${mode.toUpperCase()}=PASS; CAPTURED_COOKIE_REPLAY=DENY; VALID_SESSION=YES`);
    passed++;
  } finally {
    const deleted=await admin.auth.admin.deleteUser(uid);
    assert.equal(Boolean(deleted.error),false);
    assert.equal((await admin.auth.admin.getUserById(uid)).data.user,null);
    console.log('LIVE_FIXTURE_USER_CLEANUP=0');
  }
}
console.log(`LIVE_SECURITY_MATRIX=${passed}/${passed} PASS`);
