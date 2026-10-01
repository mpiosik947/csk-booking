import { spawnSync, spawn } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { createServer, request } from 'node:http';

const database = process.argv[2];
if (!/^privacy_tech_[0-9a-f]{16}$/.test(database || '')) throw Error('ISOLATED_DATABASE_REQUIRED');
const repo = process.cwd(); const container = 'supabase_db_csk-booking';
function docker(args, input, env = process.env) {
  const r = spawnSync('docker', args, { input, env, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 });
  if (r.status !== 0) throw Error('Local Docker failed: ' + args[0]);
  return r.stdout;
}
const ports = docker(['port', container, '5432/tcp']);
if (!ports.trim().split(/\r?\n/).every(p => /:54322$/.test(p))) throw Error('LOCAL_DB_GATE');
const sql = (db, statement) => docker(['exec', '-i', container, 'psql', '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-U', 'postgres', '-d', db], statement);
if (sql(database, "select count(*) from auth.users;").trim() !== '0') throw Error('EMPTY_FIXTURE_DATABASE_REQUIRED');
const network = Object.keys(JSON.parse(docker(['inspect', container]))[0].NetworkSettings.Networks)[0];
const localEnv = { ...process.env, RESEND_API_KEY: '', NEXT_PUBLIC_SUPABASE_URL: 'http://127.0.0.1:15498', PRIVACY_TECH_DATABASE: database };
for (const line of readFileSync(resolve(repo, '.env.local'), 'utf8').split(/\r?\n/)) {
  const m = line.match(/^(NEXT_PUBLIC_SUPABASE_ANON_KEY|SUPABASE_SERVICE_ROLE_KEY)=(.*)$/);
  if (m) localEnv[m[1]] = m[2].trim().replace(/^['"]|['"]$/g, '');
}
if (!localEnv.NEXT_PUBLIC_SUPABASE_ANON_KEY || !localEnv.SUPABASE_SERVICE_ROLE_KEY) throw Error('LOCAL_KEYS_REQUIRED');
const made = []; let proxy; const armed = new Set(); let failedDeletes = 0;
async function run(args) {
  await new Promise((ok, fail) => {
    const child = spawn(process.execPath, args, { cwd: repo, env: localEnv, stdio: 'inherit' });
    child.on('error', fail); child.on('exit', c => c === 0 ? ok() : fail(Error('Local command exit=' + c)));
  });
}
try {
  const ledger = sql('postgres', "select 'insert into auth.schema_migrations(version) values ('||quote_literal(version)||') on conflict do nothing;' from auth.schema_migrations;");
  docker(['exec', '-i', container, 'sh', '-c', 'PGPASSWORD="$POSTGRES_PASSWORD" exec psql -X -At -v ON_ERROR_STOP=1 -U supabase_admin -d "$1"', 'sh', database], ledger);
  for (const [kind, port] of [['auth', 15499], ['rest', 15500]]) {
    const original = JSON.parse(docker(['inspect', 'supabase_' + kind + '_csk-booking']))[0];
    const env = { ...process.env }; const args = [];
    for (const entry of original.Config.Env) {
      const i = entry.indexOf('='); const key = entry.slice(0, i); let value = entry.slice(i + 1);
      if (['PATH', 'HOME', 'HOSTNAME'].includes(key)) continue;
      if (['GOTRUE_DB_DATABASE_URL', 'PGRST_DB_URI'].includes(key)) {
        const url = new URL(value); if (url.hostname !== container) throw Error('DB_HOST_GATE');
        url.pathname = '/' + database; value = url.toString();
      }
      env[key] = value; args.push('--env', key);
    }
    if (kind === 'auth') {
      env.API_EXTERNAL_URL = localEnv.NEXT_PUBLIC_SUPABASE_URL; env.GOTRUE_SITE_URL = 'http://127.0.0.1:3101';
      if (!args.includes('API_EXTERNAL_URL')) args.push('--env', 'API_EXTERNAL_URL');
    }
    const name = database + '_' + kind;
    docker(['run', '--detach', '--rm', '--name', name, '--network', network, '--publish', '127.0.0.1:' + port + ':' + (kind === 'auth' ? '9999' : '3000'), ...args, original.Config.Image], undefined, env);
    made.push(name);
  }
  proxy = createServer((req, res) => {
    const arm = req.url.match(/^\/__privacy-test\/fail-auth-delete\/([0-9a-f-]{36})$/);
    if (req.method === 'POST' && arm) { armed.add(arm[1]); res.writeHead(204); res.end(); return; }
    if (req.url === '/__privacy-test/status') { res.setHeader('Content-Type', 'application/json'); res.end(JSON.stringify({ failedDeletes })); return; }
    const auth = req.url.startsWith('/auth/v1'); const rest = req.url.startsWith('/rest/v1');
    res.setHeader('Access-Control-Allow-Origin', 'http://127.0.0.1:3101');
    res.setHeader('Access-Control-Allow-Headers', 'authorization,apikey,content-type,accept-profile,content-profile,x-client-info,prefer,x-supabase-api-version');
    res.setHeader('Access-Control-Allow-Methods', 'GET,POST,PATCH,PUT,DELETE,OPTIONS');
    if (req.method === 'OPTIONS') { res.writeHead(204); res.end(); return; }
    if (!auth && !rest) { res.writeHead(404); res.end(); return; }
    const path = req.url.replace(auth ? '/auth/v1' : '/rest/v1', '') || '/';
    const deletion = path.match(/^\/admin\/users\/([0-9a-f-]{36})$/);
    if (auth && req.method === 'DELETE' && deletion && armed.delete(deletion[1])) {
      failedDeletes++; res.writeHead(500, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ code: 'unexpected_failure', msg: 'Synthetic isolated Auth failure' })); return;
    }
    const upstream = request({ hostname: '127.0.0.1', port: auth ? 15499 : 15500, path, method: req.method, headers: req.headers }, r => { res.writeHead(r.statusCode, r.headers); r.pipe(res); });
    upstream.on('error', () => { res.writeHead(502); res.end(); }); req.pipe(upstream);
  });
  await new Promise((ok, fail) => { proxy.once('error', fail); proxy.listen(15498, '127.0.0.1', ok); });
  let ready = false;
  for (let i = 0; i < 30; i++) {
    try { if ((await fetch('http://127.0.0.1:15499/health')).ok && (await fetch('http://127.0.0.1:15500/')).status < 500) { ready = true; break; } } catch {}
    await new Promise(r => setTimeout(r, 1000));
  }
  if (!ready) throw Error('LOCAL_API_NOT_READY');
  console.log('ISOLATED_AUTH_REST_READY');
  await run(['node_modules/next/dist/bin/next', 'build', '--webpack']);
  await run(['node_modules/@playwright/test/cli.js', 'test', '--config=playwright.privacy-tech-local.config.ts']);
} finally {
  if (proxy) await new Promise(r => proxy.close(r));
  for (const name of made.reverse()) docker(['rm', '--force', name]);
  console.log('ISOLATED_AUTH_REST_REMOVED=' + made.length);
}
