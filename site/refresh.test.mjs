// The /refresh endpoint, against the real worker with GitHub stubbed.
//
//   node site/refresh.test.mjs
//
// The button on the page cannot scrape — the page is a file — so it asks the
// workflow that builds it to run again. What is worth pinning down is that it
// refuses without a token, refuses without the password, and actually
// dispatches when it says it did: "nothing happened" is the failure that looks
// exactly like success here.
//
// jsdom is not needed for this one; site/page.test.mjs covers the button.
import { timingSafeEqual } from 'node:crypto';
if (!globalThis.crypto.subtle.timingSafeEqual) {
  globalThis.crypto.subtle.timingSafeEqual = (a, b) =>
    a.byteLength === b.byteLength && timingSafeEqual(Buffer.from(a), Buffer.from(b));
}
const { default: worker } = await import('./_worker.js');

let fails = 0;
const check = (n, got, want) => { const ok = String(got) === String(want);
  if (!ok) fails++; console.log(`${ok ? 'ok  ' : 'FAIL'}  ${n}: ${got}${ok ? '' : ` (wanted ${want})`}`); };

// Stub GitHub. Records the dispatch, and reports a run that finishes later.
let dispatched = 0, finished = '2020-01-01T00:00:00Z';
const realFetch = globalThis.fetch;
globalThis.fetch = async (url, init = {}) => {
  const u = String(url);
  if (u.startsWith('https://api.github.com/')) {
    if (u.includes('/dispatches')) { dispatched++; return new Response(null, { status: 204 }); }
    return Response.json({ workflow_runs: [{ status: 'completed', conclusion: 'success',
                                             updated_at: finished }] });
  }
  return realFetch(url, init);
};

const env = { SITE_PASSWORD: 'pw', ASSETS: { fetch: async () => new Response('x') } };
const call = (method, e = {}) => worker.fetch(new Request('https://q/refresh', {
  method, headers: { Authorization: 'Basic ' + Buffer.from('x:pw').toString('base64') } }),
  { ...env, ...e });

check('no token → 501', (await call('POST')).status, 501);
check('unauthenticated → 401', (await worker.fetch(new Request('https://q/refresh',
  { method: 'POST' }), env)).status, 401);
check('PUT → 405', (await call('PUT', { REFRESH_TOKEN: 't' })).status, 405);
const started = await call('POST', { REFRESH_TOKEN: 't' });
check('POST → 202', started.status, 202);
check('  it dispatched the workflow', dispatched, 1);
const status = await (await call('GET', { REFRESH_TOKEN: 't' })).json();
check('GET reports the run', status.conclusion, 'success');

console.log(fails ? `\n${fails} FAILED` : '\nall passed');
process.exit(fails ? 1 : 0);
