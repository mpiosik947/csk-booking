import test from 'node:test';
import assert from 'node:assert/strict';
import {deleteArchivedPartner,deleteInput} from './tenant-partner-delete.ts';
const id='00000000-0000-4000-8000-000000000001',mid='00000000-0000-4000-8000-000000000002',token='00000000-0000-4000-8000-000000000003';
const input={id,revision:token},plan={tenant_id:id,media_id:mid,token};
test('delete payload rejects browser-controlled tenant, key, media and token',()=>{
 assert.equal(deleteInput(input),true);
 for(const extra of ['tenant_id','media_id','path','token'])assert.equal(deleteInput({...input,[extra]:id}),false);
 for(const value of [null,[],{}, {...input,revision:null},{...input,id:'../escape'}])assert.equal(deleteInput(value),false);
});
test('only authoritative key is removed and success follows confirmed finalization',async()=>{
 const calls=[];const result=await deleteArchivedPartner(async(name,args)=>{calls.push(name);if(name.includes('prepare'))return{data:plan,error:null};assert.equal(args.p_token,token);return{data:true,error:null};},async path=>{calls.push(path);return true;},'csk',input);
 assert.deepEqual(result,{status:200,deleted:true});assert.deepEqual(calls,['admin_prepare_partner_delete_v1',`${id}/partners/${mid}.webp`,'admin_finish_partner_delete_v1']);
});
for(const failure of ['storage-error','storage-throw','finish-error','finish-throw','finish-false'])test('recoverable '+failure,async()=>{
 const calls=[];const result=await deleteArchivedPartner(async name=>{calls.push(name);if(name.includes('prepare'))return{data:plan,error:null};if(name.includes('finish')){if(failure==='finish-throw')throw Error();return{data:failure==='finish-false'?false:null,error:failure==='finish-error'?{code:'PT409'}:null};}return{data:null,error:null};},async()=>{if(failure==='storage-throw')throw Error();return failure!=='storage-error';},'csk',input);
 assert.notEqual(result.status,200);assert.equal(calls.at(-1),'admin_release_partner_delete_v1');if(failure.startsWith('storage'))assert.ok(!calls.includes('admin_finish_partner_delete_v1'));
});
for(const [code,status]of[['42501',403],['PT409',409],['22023',400]])test('denial never invokes storage '+code,async()=>{
 let removed=false;const result=await deleteArchivedPartner(async()=>({data:null,error:{code}}),async()=>{removed=true;return true;},'csk',input);assert.equal(result.status,status);assert.equal(removed,false);
});
test('malformed server plan fails closed without deleting a path',async()=>{
 let removed=false;const result=await deleteArchivedPartner(async()=>({data:{...plan,media_id:'../other'},error:null}),async()=>{removed=true;return true;},'csk',input);assert.equal(result.status,502);assert.equal(removed,false);
});
