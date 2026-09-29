import { createRequire } from 'node:module';
import { resolve } from 'node:path';
const require=createRequire(import.meta.url);
const {webpack}=require('next/dist/compiled/webpack/webpack');
await new Promise((ok,fail)=>webpack({
  mode:'development',devtool:false,context:process.cwd(),
  entry:resolve('tests/fixtures/instructor-browser-entry.tsx'),
  output:{path:resolve('test-results/instructor-browser'),filename:'fixture.js'},
  resolve:{extensions:['.tsx','.ts','.js'],alias:{'@/lib/supabase':resolve('tests/fixtures/instructor-browser-auth.mjs'),'@':process.cwd()}},
  module:{rules:[{test:/\.tsx?$/,exclude:/node_modules/,use:resolve('tests/fixtures/instructor-browser-loader.mjs')}]},
},(error,stats)=>error||stats.hasErrors()?fail(error??Error(stats.toString())):ok()));
