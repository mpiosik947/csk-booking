import { spawnSync, spawn } from 'node:child_process';
import { cpSync, readFileSync, existsSync, symlinkSync } from 'node:fs';
import { resolve } from 'node:path';
import { createServer, request } from 'node:http';

const database=process.argv[2];
if(!/^p10e_isolated_[0-9a-f]{16}$/.test(database||''))throw Error('SCRATCH_DATABASE_REQUIRED');
const repo=process.cwd();
const workspace=resolve(repo,'..','product10e-checkpoint-isolated-review');
if(!existsSync(resolve(workspace,'.env.local')))throw Error('EMPTY_ENV_WORKSPACE_REQUIRED');
const dbContainer='supabase_db_csk-booking';
function docker(args,input,env=process.env){const r=spawnSync('docker',args,{input,env,encoding:'utf8',maxBuffer:32*1024*1024});if(r.status!==0){let detail=r.error?.code||r.stderr||'';for(const [key,value] of Object.entries(env))if(/SECRET|TOKEN|PASSWORD|KEY|DB_URI|DATABASE_URL/i.test(key)&&value)detail=detail.split(value).join('[REDACTED]');throw Error('Local Docker operation failed: '+args[0]+' '+detail.slice(-1200));}return r.stdout;}
function sql(db,text){return docker(['exec','-i',dbContainer,'psql','-X','-At','-v','ON_ERROR_STOP=1','-U','postgres','-d',db],text);}
const network=Object.keys(JSON.parse(docker(['inspect',dbContainer]))[0].NetworkSettings.Networks)[0];
const localEnv={...process.env};
for(const line of readFileSync(resolve(repo,'.env.local'),'utf8').split(/\r?\n/)){
 const m=line.match(/^(NEXT_PUBLIC_SUPABASE_ANON_KEY|SUPABASE_SERVICE_ROLE_KEY)=(.*)$/);
 if(m)localEnv[m[1]]=m[2].trim().replace(/^['"]|['"]$/g,'');
}
localEnv.NEXT_PUBLIC_SUPABASE_URL='http://127.0.0.1:15498';
localEnv.PRODUCT10E_ISOLATED_DATABASE=database;
if(!localEnv.NEXT_PUBLIC_SUPABASE_ANON_KEY||!localEnv.SUPABASE_SERVICE_ROLE_KEY)throw Error('LOCAL_KEYS_MISSING');
// Mechanical test-workspace copy; original app/config and its .next remain untouched.
for(const name of ['app','lib','public','tests','package.json','tsconfig.json','next.config.ts','next-env.d.ts','postcss.config.mjs','playwright.config.ts','playwright.product10e-local.config.ts']){
 if(existsSync(resolve(repo,name)))cpSync(resolve(repo,name),resolve(workspace,name),{recursive:true});
}
if(!existsSync(resolve(workspace,'node_modules')))symlinkSync(resolve(repo,'node_modules'),resolve(workspace,'node_modules'),'junction');
const made=[];
let proxy;
async function run(args){await new Promise((ok,fail)=>{const child=spawn(process.execPath,args,{cwd:workspace,env:localEnv,stdio:'inherit'});child.on('error',fail);child.on('exit',c=>c===0?ok():fail(Error('Local command failed: '+args[0]+' exit='+c)));});}
try{
 // Managed Auth migration ledger only; no accounts or business data are copied.
 const ledger=sql('postgres',"select 'insert into auth.schema_migrations(version) values ('||quote_literal(version)||') on conflict do nothing;' from auth.schema_migrations;");
 // Auth's managed ledger is owned by supabase_auth_admin; restore it as the
 // local managed-schema administrator, never by broadening postgres grants.
 docker(['exec','-i',dbContainer,'sh','-c','PGPASSWORD="$POSTGRES_PASSWORD" exec psql -X -At -v ON_ERROR_STOP=1 -U supabase_admin -d "$1"','sh',database],ledger);
 for(const [kind,port] of [['auth',15499],['rest',15500]]){
  const original=JSON.parse(docker(['inspect','supabase_'+kind+'_csk-booking']))[0];
  const env={...process.env};const keys=[];
  for(const entry of original.Config.Env){const i=entry.indexOf('=');const key=entry.slice(0,i);let value=entry.slice(i+1);
   if(['PATH','HOME','HOSTNAME'].includes(key))continue;
   if(key==='GOTRUE_DB_DATABASE_URL'||key==='PGRST_DB_URI'){const url=new URL(value);if(url.hostname!==dbContainer)throw Error('UNEXPECTED_DB_HOST');url.pathname='/'+database;value=url.toString();}
   env[key]=value;keys.push('--env',key);
  }
  if(kind==='auth'){env.API_EXTERNAL_URL=localEnv.NEXT_PUBLIC_SUPABASE_URL;env.GOTRUE_SITE_URL='http://127.0.0.1:3001';if(!keys.includes('API_EXTERNAL_URL'))keys.push('--env','API_EXTERNAL_URL');}
  const name=database+'_'+kind;
  docker(['run','--detach','--rm','--name',name,'--network',network,'--publish','127.0.0.1:'+port+':'+(kind==='auth'?'9999':'3000'),...keys,original.Config.Image],undefined,env);
  made.push(name);
 }
 proxy=createServer((req,res)=>{
  const auth=req.url.startsWith('/auth/v1');const rest=req.url.startsWith('/rest/v1');
  res.setHeader('Access-Control-Allow-Origin','http://127.0.0.1:3001');res.setHeader('Access-Control-Allow-Headers','authorization,apikey,content-type,accept-profile,content-profile,x-client-info,prefer,x-supabase-api-version');res.setHeader('Access-Control-Allow-Methods','GET,POST,PATCH,PUT,DELETE,OPTIONS');
  if(req.method==='OPTIONS'){res.writeHead(204);res.end();return;}
  if(!auth&&!rest){res.writeHead(404);res.end();return;}
  const upstream=request({hostname:'127.0.0.1',port:auth?15499:15500,path:req.url.replace(auth?'/auth/v1':'/rest/v1','')||'/',method:req.method,headers:req.headers},r=>{res.writeHead(r.statusCode,r.headers);r.pipe(res);});upstream.on('error',()=>{res.writeHead(502);res.end();});req.pipe(upstream);
 });
 await new Promise((ok,fail)=>{proxy.once('error',fail);proxy.listen(15498,'127.0.0.1',ok);});
 let ready=false;
 for(let i=0;i<30;i++){try{const a=await fetch('http://127.0.0.1:15499/health');const r=await fetch('http://127.0.0.1:15500/');if(a.ok&&r.status<500){ready=true;break;}}catch{}await new Promise(r=>setTimeout(r,1000));}
 if(!ready)throw Error('ISOLATED_API_NOT_READY');
 console.log('ISOLATED_AUTH_REST_READY; DATABASE='+database+'; TCM=ABSENT');
 await run([resolve(repo,'scripts/product10e-local-concurrency.mjs')]);
 // The disposable workspace shares installed dependencies by junction; Webpack
 // supports that layout without changing the application's normal build config.
 await run([resolve(repo,'node_modules/next/dist/bin/next'),'build','--webpack']);
 await run([resolve(repo,'node_modules/@playwright/test/cli.js'),'test','--config=playwright.product10e-local.config.ts','tests/e2e/platform-onboarding.spec.ts']);
 const remaining=sql(database,"select (select count(*) from auth.users)+(select count(*) from public.platform_admins)+(select count(*) from public.platform_audit_logs)+(select count(*) from public.tenants where slug like 'p10e-%');").trim();
 if(remaining!=='0')throw Error('ISOLATED_E2E_FIXTURE_REMAINING');
 console.log('ISOLATED_E2E_FIXTURE_CLEANUP=0');
}finally{
 if(proxy)await new Promise(r=>proxy.close(r));
 for(const name of made.reverse())docker(['rm','--force',name]);
 console.log('ISOLATED_AUTH_REST_CONTAINERS_REMOVED='+made.length);
}
