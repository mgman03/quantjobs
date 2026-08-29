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
let run = { id: 7, status: 'completed', conclusion: 'success', updated_at: finished };
let jobsBody = { jobs: [] }, jobCalls = 0;
const realFetch = globalThis.fetch;
globalThis.fetch = async (url, init = {}) => {
  const u = String(url);
  if (u.startsWith('https://api.github.com/')) {
    if (u.includes('/dispatches')) { dispatched++; return new Response(null, { status: 204 }); }
    if (u.includes('/jobs')) { jobCalls++; return Response.json(jobsBody); }
    return Response.json({ workflow_runs: [{ ...run, updated_at: finished }] });
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
check('  and asks for no steps when nothing is running', jobCalls, 0);

// ---- what it is doing, not just that it is busy ----
//
// Three minutes of "busy" is indistinguishable from stuck, and the page cannot
// find out on its own: the run is on GitHub and only the worker holds a token.
run = { id: 7, status: 'in_progress', conclusion: null, updated_at: finished,
        run_started_at: '2026-08-29T10:00:00Z' };
jobsBody = { jobs: [
  { name: 'fetch', status: 'completed', steps: [] },
  { name: 'deploy', status: 'in_progress', steps: [
      { name: 'Take the page the fetch built', status: 'completed' },
      { name: 'Publish to Cloudflare Pages', status: 'in_progress' },
  ] },
] };
const live = await (await call('GET', { REFRESH_TOKEN: 't' })).json();
check('a running job reports its step', live.phase, 'Publish to Cloudflare Pages');
check('  and when it started', live.started, '2026-08-29T10:00:00Z');
check('  having asked for the steps', jobCalls, 1);

// A job with no step marked in_progress still names something rather than
// falling back to a blank spinner.
jobsBody = { jobs: [{ name: 'fetch', status: 'in_progress', steps: [] }] };
const coarse = await (await call('GET', { REFRESH_TOKEN: 't' })).json();
check('no step in flight falls back to the job', coarse.phase, 'fetch');

// The steps call is allowed to fail; the status still has to come back.
jobsBody = null;
globalThis.fetch = (u, i) => String(u).includes('/jobs')
  ? Promise.resolve(new Response('nope', { status: 500 }))
  : Response.json({ workflow_runs: [{ ...run, updated_at: finished }] });
const degraded = await (await call('GET', { REFRESH_TOKEN: 't' })).json();
check('a failed steps lookup still reports the run', degraded.status, 'in_progress');

console.log(fails ? `\n${fails} FAILED` : '\nall passed');
process.exit(fails ? 1 : 0);
