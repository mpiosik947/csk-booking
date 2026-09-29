import { timingSafeEqual } from 'node:crypto';
import { PLATFORM_BASE_URL } from '../platform-domain.ts';
import { operationalEmailLayout } from './operational-email-layout.ts';
import { buildOperationalEmailSubject } from './operational-email-core.ts';
import { boundedOperation, HANDLER_BUDGET_MS, PROVIDER_TIMEOUT_MS, DB_OPERATION_TIMEOUT_MS,
  MAX_CLAIMS_PER_RUN, FINISH_MARGIN_MS, DELIVERY_BUDGET_MS } from './reminder-budget.ts';

export type ReminderPayload = {
  kind: 'booking_reminder_24h' | 'event_reminder_24h'; occurrence_id: string;
  idempotency_key: string; recipient: string; title: string; date: string;
  start: string; end: string; location: string | null; tenant_slug: string; display_name: string;
};
type Claim = { claim_id: string; occurrence_id: string; idempotency_key: string };
type Result = { data: unknown; error: unknown };
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export function validReminderSecret(header: string | null, secret: string | undefined) {
  if (!secret || secret.length < 32 || !header || header.length > 512) return false;
  const expected = Buffer.from(`Bearer ${secret}`), actual = Buffer.from(header);
  return expected.length === actual.length && timingSafeEqual(expected, actual);
}
export function reminderContent(p: ReminderPayload) {
  if (!['booking_reminder_24h', 'event_reminder_24h'].includes(p.kind) || !uuid.test(p.occurrence_id) ||
    p.idempotency_key !== `${p.kind}/${p.occurrence_id}` || !/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(p.tenant_slug) ||
    !/^[^\s<>@]+@[^\s<>@]+$/.test(p.recipient) ||
    ![p.title,p.date,p.start,p.end,p.display_name].every(v => typeof v === 'string' && v.length > 0 && v.length <= 500)) throw Error('Reminder unavailable');
  const booking = p.kind === 'booking_reminder_24h';
  const label = booking ? 'Przypomnienie o rezerwacji' : 'Przypomnienie o wydarzeniu';
  const href = `${PLATFORM_BASE_URL}/t/${p.tenant_slug}/${booking ? 'my-reservations' : 'my-events'}`;
  const rows = [p.title, `Data: ${p.date}`, `Godzina: ${p.start.slice(0,5)}–${p.end.slice(0,5)} (Europe/Warsaw)`,
    `Obiekt: ${p.display_name}`, ...(p.location ? [`${booking ? 'Oś/stanowisko' : 'Miejsce'}: ${p.location}`] : [])];
  const subject = buildOperationalEmailSubject({tenantDisplayName:p.display_name,notificationLabel:label});
  return {subject, text:['StrzelajTu.pl',p.display_name,label,...rows,href].join('\n'),
    html: operationalEmailLayout({
      tenantDisplayName: p.display_name,
      title: label,
      intro: p.title,
      details: [
        { label: 'Data', value: p.date },
        { label: 'Godzina', value: `${p.start.slice(0,5)}–${p.end.slice(0,5)} (Europe/Warsaw)` },
        { label: 'Obiekt', value: p.display_name },
        ...(p.location ? [{ label: booking ? 'Oś/stanowisko' : 'Miejsce', value: p.location }] : []),
      ],
      actions: [{ label: booking ? 'Moje rezerwacje' : 'Moje wydarzenia', url: href }],
    })};
}
export async function runReminders(deps: {
  rpc: (name:string,args?:Record<string,unknown>,signal?:AbortSignal)=>Promise<Result>;
  send:(payload:ReminderPayload,content:ReturnType<typeof reminderContent>,signal?:AbortSignal)=>Promise<{id?:string}>;
  now?:()=>number;
  startedAt?:number;
}) {
  const now=deps.now ?? (()=>performance.now());
  const deadline=(deps.startedAt ?? now())+HANDLER_BUDGET_MS;
  const enough=(required:number)=>deadline-now()>=required+FINISH_MARGIN_MS;
  const rpc=(name:string,args?:Record<string,unknown>)=>boundedOperation(
    signal=>deps.rpc(name,args,signal),DB_OPERATION_TIMEOUT_MS);
  const counts = {sent:0,skipped:0,failed:0,uncertain:0};
  if(!enough(DB_OPERATION_TIMEOUT_MS)) return counts;
  const discovery = await rpc('discover_reminders_v1');
  if(discovery.error) throw Error('Reminder discovery failed');
  // Claim the batch only when ALL its work fits; never preclaim a large backlog.
  if(!enough(DB_OPERATION_TIMEOUT_MS+MAX_CLAIMS_PER_RUN*DELIVERY_BUDGET_MS)) return counts;
  const claimed = await rpc('claim_reminders_v1');
  if(claimed.error || !Array.isArray(claimed.data) || claimed.data.length>MAX_CLAIMS_PER_RUN) throw Error('Reminder claim failed');
  for(const value of claimed.data) {
    // Unexpected scheduling stalls leave a finite DB lease, not a send after deadline.
    if(!enough(DELIVERY_BUDGET_MS)) break;
    const claim=value as Claim;
    if(!claim || !uuid.test(claim.claim_id) || !uuid.test(claim.occurrence_id)) throw Error('Invalid reminder claim');
    let providerId:string|null=null;
    try {
      // Last authoritative check, immediately before rendering and external send.
      const checked=await rpc('final_check_reminder_v1',{p_claim_id:claim.claim_id});
      if(checked.error) {counts.uncertain++;continue;}
      if(!checked.data) {counts.skipped++;continue;}
      const payload=checked.data as ReminderPayload;
      if(payload.occurrence_id!==claim.occurrence_id || payload.idempotency_key!==claim.idempotency_key) throw Error('Claim mismatch');
      const content=reminderContent(payload);
      if(!enough(PROVIDER_TIMEOUT_MS+DB_OPERATION_TIMEOUT_MS)) break;
      const sent=await boundedOperation(signal=>deps.send(payload,content,signal),PROVIDER_TIMEOUT_MS);
      if(typeof sent.id==='string' && /^[A-Za-z0-9_-]{1,128}$/.test(sent.id)) providerId=sent.id;
    } catch { /* No provider/body/recipient/secret error logging. */ }
    try {
      const result=await rpc('complete_reminder_v1',{p_claim_id:claim.claim_id,p_success:providerId!==null,p_provider_message_id:providerId});
      if(result.error || result.data!==true) counts.uncertain++;
      else if(providerId) counts.sent++; else counts.failed++;
    } catch {counts.uncertain++;}
  }
  return counts;
}
