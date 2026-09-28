import test from 'node:test';
import assert from 'node:assert/strict';
import { loadTenantActionTiles } from './tenant-action-tiles.js';
const id='10000000-0000-4000-8000-000000000001';
function client(role,slug='range-b',authenticated=true){return {auth:{getUser:async()=>({data:{user:authenticated?{id:'user',role:'admin'}:null},error:null})},rpc:async(name,args)=>{
 if(name==='resolve_active_tenant_by_slug_v1'){assert.deepEqual(args,{p_slug:slug});return {data:[{tenant_id:id,tenant_slug:slug,tenant_status:'active'}]};}
 assert.equal(name,'get_my_tenant_role_v1');assert.deepEqual(args,{p_tenant_id:id});return {data:role};
}};}
test('anonymous has no tiles',async()=>assert.equal(await loadTenantActionTiles(client(null,'range-b',false),'range-b'),null));
for(const role of ['user',null,'platform_admin','pending']) test(`${role}: client only (no global role authority)`,async()=>assert.deepEqual(await loadTenantActionTiles(client(role),'range-b'),{clientHref:'/dashboard',staffHref:null}));
for(const role of ['admin','employee','instructor']) test(`${role}: existing root staff contract`,async()=>assert.deepEqual(await loadTenantActionTiles(client(role),'range-b'),{clientHref:'/dashboard',staffHref:'/t/range-b/admin'}));
test('CSK staff link',async()=>assert.equal((await loadTenantActionTiles(client('admin','csk'),'csk')).staffHref,'/t/csk/admin'));
test('resolver mismatch fails closed',async()=>{const c=client('admin');c.rpc=async()=>({data:[{tenant_id:id,tenant_slug:'other',tenant_status:'active'}]});assert.equal((await loadTenantActionTiles(c,'range-b')).staffHref,null);});
test('RPC failure hides staff',async()=>{const c=client('admin');c.rpc=async()=>{throw Error('offline')};assert.equal((await loadTenantActionTiles(c,'range-b')).staffHref,null);});
test('invalid selector denied',async()=>assert.equal(await loadTenantActionTiles(client('admin'),'../admin'),null));
