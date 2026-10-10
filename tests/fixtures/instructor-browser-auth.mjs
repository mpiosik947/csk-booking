let session = { user: { id: 'synthetic-user' }, access_token: 'synthetic-initial-token' };
export const supabase = { rpc: async (name,args) => {
 const response=await fetch('/fixture-rpc/'+name,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(args)});
 return response.json();
}, auth: { onAuthStateChange(callback) {
  const handler = event => {
    const detail = event.detail;
    if (typeof detail === 'string') {
      if (detail === 'SIGNED_OUT') session = null;
      callback(detail, session);
    } else {
      session = detail.session; callback(detail.event, session);
    }
  };
  window.addEventListener('fixture-auth', handler);
  callback('INITIAL_SESSION', session);
  return {data:{subscription:{unsubscribe:()=>window.removeEventListener('fixture-auth',handler)}}};
} } };
