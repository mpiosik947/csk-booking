import 'server-only';
import { createClient } from '@supabase/supabase-js';
import { Resend } from 'resend';
import { validReminderSecret,runReminders } from '@/lib/server/reminder-core';
import { getOperationalEmailSenderConfiguration } from '@/lib/server/operational-email-config';
import { emptyReminderBody } from '@/lib/server/reminder-budget';
export const runtime='nodejs';
export const maxDuration=180;
export async function POST(request:Request) {
  const startedAt=performance.now();
  const headers={'Cache-Control':'no-store'};
  if(!validReminderSecret(request.headers.get('authorization'),process.env.REMINDER_CRON_SECRET))
    return Response.json({error:'Unauthorized'},{status:401,headers});
  // Discovery accepts no caller resource/tenant/recipient selectors.
  if(new URL(request.url).search)
    return Response.json({error:'Invalid request'},{status:400,headers});
  try {
    if(!await emptyReminderBody(request)) return Response.json({error:'Invalid request'},{status:400,headers});
  } catch { return Response.json({error:'Invalid request'},{status:400,headers}); }
  const url=process.env.NEXT_PUBLIC_SUPABASE_URL,key=process.env.SUPABASE_SERVICE_ROLE_KEY;
  const {from,resendApiKey,replyTo}=getOperationalEmailSenderConfiguration();
  if(!url||!key||!from||!resendApiKey) return Response.json({error:'Unavailable'},{status:503,headers});
  try {
    const db=createClient(url,key,{auth:{persistSession:false,autoRefreshToken:false}});
    const resend=new Resend(resendApiKey);
    const counts=await runReminders({startedAt,rpc:async(name,args,signal)=>{
      const query=db.rpc(name,args);
      return await (signal ? query.abortSignal(signal) : query);
    },
      send:async(payload,content,signal)=>{
        // SDK 6.12 forwards request options to fetch; regression-tested because
        // its published options type does not yet declare AbortSignal.
        const options={idempotencyKey:payload.idempotency_key,signal};
        const {data,error}=await resend.emails.send({from,to:payload.recipient,...content,replyTo},options);
        if(error) throw Error('Provider unavailable');
        return {id:data?.id};
      }});
    return Response.json(counts,{headers});
  } catch { return Response.json({error:'Reminder processing unavailable'},{status:503,headers}); }
}
