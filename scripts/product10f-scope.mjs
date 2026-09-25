import { readFileSync, existsSync } from 'node:fs';
import { resolve } from 'node:path';
import { execFileSync, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
const base=resolve(process.cwd(),'../product10f-baseline');
if(!existsSync(resolve(base,'package.json')))throw Error('BASELINE_REQUIRED');
const files=execFileSync('rg',['--files','--hidden','-g','!node_modules','-g','!.next','-g','!test-results','-g','!*.log'],{encoding:'utf8'}).trim().split(/\r?\n/).map(f=>f.replaceAll('\\','/'));
const manifest=[];
for(const file of files.sort()) {
 if(file==='AGENTS.md'||file.startsWith('supabase/drafts/')||file.startsWith('.env')||file==='next-env.d.ts'||file.endsWith('.tsbuildinfo'))continue;
 const current=readFileSync(file);const prior=resolve(base,file);
 const norm=b=>b.toString('utf8').replace(/\r\n?/g,'\n');
 if(existsSync(prior)&&norm(readFileSync(prior))===norm(current))continue;
 if(existsSync(prior)) {
  const check=spawnSync('git',['-c','core.autocrlf=false','-c','core.whitespace=blank-at-eol,blank-at-eof,space-before-tab,cr-at-eol','diff','--no-index','--check','--',prior,resolve(file)],{encoding:'utf8'});
  if(check.status>1||check.stdout.trim())throw Error('DIFF_CHECK_FAILED '+file+' '+check.stdout+check.stderr);
 } else if(current.toString('utf8').split(/\r?\n/).some(line=>/[\t ]+$/.test(line)))throw Error('NEW_FILE_WHITESPACE '+file);
 manifest.push({file,sha256:createHash('sha256').update(current).digest('hex')});
}
console.log(JSON.stringify({base:'cc54cdfae90bd237d3f7bcde3c1f9b995354c63c',files:manifest.length,diffCheck:'PASS',manifest},null,2));
