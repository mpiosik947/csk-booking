import 'server-only';
import { createClient } from '@supabase/supabase-js';
import { Resend } from 'resend';
import { validReminderSecret,runReminders } from '@/lib/server/reminder-core';
import { getOperationalEmailSenderConfiguration } from '@/lib/server/operational-email-config';
export const runtime='nodejs';
export async function POST(request:Request) {
  const headers={'Cache-Control':'no-store'};
  if(!validReminderSecret(request.headers.get('authorization'),process.env.REMINDER_CRON_SECRET))
    return Response.json({error:'Unauthorized'},{status:401,headers});
  // Discovery accepts no caller resource/tenant/recipient selectors.
  if(new URL(request.url).search || (await request.text()).length)
    return Response.json({error:'Invalid request'},{status:400,headers});
  const url=process.env.NEXT_PUBLIC_SUPABASE_URL,key=process.env.SUPABASE_SERVICE_ROLE_KEY;
  const {from,resendApiKey}=getOperationalEmailSenderConfiguration();
  if(!url||!key||!from||!resendApiKey) return Response.json({error:'Unavailable'},{status:503,headers});
  try {
    const db=createClient(url,key,{auth:{persistSession:false,autoRefreshToken:false}});
    const resend=new Resend(resendApiKey);
    const counts=await runReminders({rpc:async(name,args)=>await db.rpc(name,args),
      send:async(payload,content)=>{
        const {data,error}=await resend.emails.send({from,to:payload.recipient,...content},{idempotencyKey:payload.idempotency_key});
        if(error) throw Error('Provider unavailable');
        return {id:data?.id};
      }});
    return Response.json(counts,{headers});
  } catch { return Response.json({error:'Reminder processing unavailable'},{status:503,headers}); }
}
