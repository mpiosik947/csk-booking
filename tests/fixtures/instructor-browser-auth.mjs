export const supabase = { auth: { onAuthStateChange(callback) {
  const handler = event => callback(event.detail);
  window.addEventListener('fixture-auth', handler);
  callback('INITIAL_SESSION');
  return {data:{subscription:{unsubscribe:()=>window.removeEventListener('fixture-auth',handler)}}};
} } };
