import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { eventWideCancellationContent } from './event-wide-cancellation-core.ts';
const read=p=>readFileSync(new URL(p,import.meta.url),'utf8');
for (const [slug,name] of [['csk','CSK — Centrum Szkolenia Krutla'],['range-b','Range B']]) {
 test(`${slug}: whole event wording and tenant-bound CTA`,()=>{
  const content=eventWideCancellationContent({tenantId:'internal',tenantSlug:slug,publicSlug:'public-'+slug,displayName:name,canonicalPublicUrl:'https://strzelajtu.pl/public-'+slug},
   {title:'Event <test>',event_date:'2026-11-30',start_time:'10:00',end_time:'11:00',location:'Test range',private_notes:'PRIVATE'});
  assert.equal(content.subject,`StrzelajTu.pl / ${name} — Wydarzenie zostało anulowane`);
  assert.ok(content.text.includes(`/t/${slug}/my-events`));
  assert.ok(content.html.includes('Event &lt;test&gt;'));
  assert.ok(!JSON.stringify(content).includes('PRIVATE'));
  assert.ok(!JSON.stringify(content).includes('internal'));
  if(slug==='range-b')assert.doesNotMatch(JSON.stringify(content),/csk|krutla/i);
 });
}
test('each positive provider call is preceded by exact admitted lease check',()=>{
 for(const path of ['./event-reserve-promotion.ts','./event-reserve-confirmation-email.ts','../../app/api/send-event-registration-confirmation/route.ts']) {
  const s=read(path); assert.ok(s.indexOf('await requireEventDispatchLease')>0);
  assert.ok(s.indexOf('await requireEventDispatchLease')<s.lastIndexOf('.emails.send'));
 }
});
test('new cancellation batch bounded and no participant status rewrite',()=>{
 const sql=read('../../supabase/migrations/20261019100000_add_event_wide_cancellation.sql');
 assert.match(sql,/limit 5 for update of x skip locked/);
 assert.doesNotMatch(sql,/update public\.event_registrations set registration_status/i);
 assert.match(sql,/if e.cancelled_at is not null then return/);
 assert.match(sql,/attempt_count<3/);
 assert.match(sql,/interval '23 hours'/);
 assert.doesNotMatch(sql,/pg_cron|pg_net|vault\./i);
});
test('UI separates irreversible cancellation from visibility toggle',()=>{
 const s=read('../../app/admin/events/page.tsx');
 assert.match(s,/window.confirm\("Nieodwracalnie/);
 assert.match(s,/\/api\/cancel-event/);
 assert.match(s,/"admin_set_event_active_v3"/);
});
