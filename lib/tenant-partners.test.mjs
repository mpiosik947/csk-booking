import test from 'node:test';import assert from 'node:assert/strict';
import {safePartnerUrl,validPartnerValues,readPublicPartners,readPartnerList} from './tenant-partners.ts';
const values=()=>({name:'Synthetic partner',kind:'partner',display_format:'logo',target_url:null,short_description:null,is_active:false,display_order:0,starts_at:null,ends_at:null});
test('partner payload rejects forged fields, invalid types, unsafe links and dates',()=>{
 assert.ok(validPartnerValues(values()));
 for(const patch of [{tenant_id:'foreign'},{name:' '},{kind:'constructor'},{display_format:'html'},{is_active:'true'},{display_order:-1},{display_order:1.1},{starts_at:'invalid'},{starts_at:'2099-02-02T00:00:00Z',ends_at:'2099-01-01T00:00:00Z'}])assert.equal(validPartnerValues({...values(),...patch}),false);
 for(const url of ['javascript:alert(1)','data:text/html,hi','http://example.invalid','//example.invalid','https://user:secret@example.invalid','https://example.invalid:443/x','https://example.invalid\\x','https://example.invalid/%0aX','https://example.invalid/\n'])assert.equal(safePartnerUrl(url),false,url);
 assert.ok(safePartnerUrl('https://example.invalid/path?q=1#details'));assert.ok(safePartnerUrl('https://example.invalid?q=1'));
});
test('partner readers fail closed and strip data outside public DTO',()=>{
 const p={...values(),id:'b1222222-1111-1111-1111-111111111111',media_id:'a1111111-1111-1111-1111-111111111111'};
 assert.equal(readPublicPartners([{...p,media_id:'../../secret'}]),null);assert.equal(readPublicPartners([{...p,kind:'__proto__'}]),null);
 assert.equal(readPublicPartners([{...p,secret:'private'}])[0].secret,undefined);
 assert.equal(readPartnerList({tenant_id:p.id,public_slug:'../bad',items:[]}),null);
 assert.equal(readPartnerList({tenant_id:p.id,public_slug:'public-a',items:[p]}),null);
 assert.ok(readPartnerList({tenant_id:p.id,public_slug:'public-a',items:[{...p,revision:p.id,archived_at:null,status:'inactive'}]}));
});
