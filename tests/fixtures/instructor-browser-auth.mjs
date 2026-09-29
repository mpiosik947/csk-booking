export const supabase = { rpc: async (name,args) => {
 const response=await fetch('/fixture-rpc/'+name,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(args)});
 return response.json();
}, auth: { onAuthStateChange(callback) {
  const handler = event => callback(event.detail);
  window.addEventListener('fixture-auth', handler);
  callback('INITIAL_SESSION');
  return {data:{subscription:{unsubscribe:()=>window.removeEventListener('fixture-auth',handler)}}};
} } };
