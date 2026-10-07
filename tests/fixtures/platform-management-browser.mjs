import {createRequire} from 'node:module';
import {readFileSync,writeFileSync,mkdirSync,mkdtempSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {createServer} from 'node:http';
import ts from 'typescript';
import {tenantId,actorId} from './platform-management.mjs';

// Mount the real client component with only Next Link and the network boundary
// replaced. Every RPC is a POST intercepted by Playwright; no DB/Auth is used.
export async function startManagementBrowser() {
 const root=path.resolve(process.cwd()),require=createRequire(path.join(root,'package.json'));
 const folder=mkdtempSync(path.join(tmpdir(),'pam-management-test-'));
 const cleanup=()=>{
  if(path.dirname(path.resolve(folder))!==path.resolve(tmpdir())||!path.basename(folder).startsWith('pam-management-test-'))throw Error('Unexpected scratch path');
  rmSync(folder,{recursive:true,force:true});
 };
 let server;
 try {
  for(const file of ['lib/platform-wizard.ts','lib/platform-management.ts','lib/platform-management-session.ts','app/admin/_components/AdminShell.tsx','app/platform-admin/tenants/[id]/ManagementCards.tsx','app/platform-admin/tenants/[id]/TenantDetail.tsx']){
   const dest=path.join(folder,file);mkdirSync(path.dirname(dest),{recursive:true});
   writeFileSync(dest,ts.transpileModule(readFileSync(path.join(root,file),'utf8'),{fileName:file,compilerOptions:{module:ts.ModuleKind.ESNext,target:ts.ScriptTarget.ES2022,jsx:ts.JsxEmit.ReactJSX}}).outputText);
  }
  writeFileSync(path.join(folder,'network.js'),`export const supabase={
    rpc:(name,args)=>({abortSignal:signal=>fetch('/rpc/'+name,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(args),signal}).then(r=>r.json())}),
    auth:{onAuthStateChange:callback=>{window.testAuthChange=callback;return {data:{subscription:{unsubscribe(){delete window.testAuthChange;}}}};}}
  };`);
  writeFileSync(path.join(folder,'link.js'),`import React from 'react';export default function Link(props){return React.createElement('a',props);}`);
  writeFileSync(path.join(folder,'entry.js'),`import React from 'react';import {createRoot} from 'react-dom/client';import TenantDetail from './app/platform-admin/tenants/[id]/TenantDetail.tsx';createRoot(document.getElementById('root')).render(React.createElement(TenantDetail,{id:${JSON.stringify(tenantId)},actorId:${JSON.stringify(actorId)},initial:null}));`);
  const webpack=require('next/dist/compiled/webpack/webpack').webpack;
  await new Promise((resolve,reject)=>{
   const compiler=webpack({mode:'development',devtool:false,entry:path.join(folder,'entry.js'),output:{path:folder,filename:'app.js'},resolve:{extensions:['.js','.ts','.tsx'],modules:[path.join(root,'node_modules')],alias:{'@/lib/supabase':path.join(folder,'network.js'),'next/link':path.join(folder,'link.js'),'@':folder}},module:{rules:[{test:/\.tsx?$/,type:'javascript/auto'}]}});
   compiler.run((error,stats)=>compiler.close(()=>error?reject(error):stats.hasErrors()?reject(Error(stats.toString({all:false,errors:true}))):resolve()));
  });
  const postcss=require('postcss'),tailwind=require('@tailwindcss/postcss');
  const css=await postcss([tailwind({base:root})]).process(readFileSync(path.join(root,'app/globals.css'),'utf8'),{from:path.join(root,'app/globals.css')});
  writeFileSync(path.join(folder,'style.css'),css.css);
  server=createServer((req,res)=>{
   if(req.url==='/app.js'||req.url==='/style.css'){res.setHeader('Content-Type',req.url.endsWith('.css')?'text/css':'text/javascript');res.end(readFileSync(path.join(folder,req.url.slice(1))));return;}
   if(req.url!=='/'){res.statusCode=404;res.end();return;}
   res.setHeader('Content-Type','text/html; charset=utf-8');res.end('<!doctype html><html lang="pl"><head><meta name="viewport" content="width=device-width,initial-scale=1"><link rel="stylesheet" href="/style.css"></head><body><div id="root"></div><script src="/app.js"></script></body></html>');
  });
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  return {url:`http://127.0.0.1:${server.address().port}`,close:async()=>{await new Promise(resolve=>server.close(resolve));cleanup();}};
 } catch(error){if(server)server.close();cleanup();throw error;}
}
