import { expect, test } from '@playwright/test';
// No valid scheduler secret: these requests must never reach DB/provider.
for (const authorization of [undefined, 'Bearer forged', 'Bearer ' + 'x'.repeat(32)]) {
  test(`reminder POST rejects ${authorization ? 'forged '+authorization.length : 'missing'} credential`, async ({request}) => {
    const response=await request.post('/api/internal/reminders', {headers: authorization ? {authorization} : {}});
    expect(response.status()).toBe(401);
    expect(await response.json()).toEqual({error:'Unauthorized'});
    expect(response.headers()['cache-control'].split(',').map(value=>value.trim())).toContain('no-store');
  });
}
test('GET cannot trigger reminders',async({request})=>{
  expect((await request.get('/api/internal/reminders')).status()).toBe(405);
});
