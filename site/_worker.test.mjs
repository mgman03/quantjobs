// Tests the password gate and the /state sync in _worker.js.
// `node site/_worker.test.mjs`.
//
// Worth having for a small file because this is the only thing between the
// internet and a list of what you applied to and were rejected from, and every
// failure mode is silent: a gate that lets everyone through looks exactly like
// a gate that works, and a merge that drops half your marks looks exactly like
// one that keeps them until the day you look.
//
// Workers keep timingSafeEqual on crypto.subtle; Node keeps it on the crypto
// module. That is the only thing stubbed — the rest is the real file.
import { webcrypto } from 'node:crypto';
import { timingSafeEqual } from 'node:crypto';
// Workers' non-standard extension; Node keeps it on the crypto module instead.
if (!globalThis.crypto.subtle.timingSafeEqual) {
  globalThis.crypto.subtle.timingSafeEqual = (a, b) =>
    a.byteLength === b.byteLength && timingSafeEqual(Buffer.from(a), Buffer.from(b));
}

const { default: worker } = await import('./_worker.js');

const assets = { fetch: async () => new Response('<h1>page</h1>', {
  headers: { 'Content-Type': 'text/html', 'Cache-Control': 'public, max-age=300' } }) };
const basic = (u, p) => 'Basic ' + Buffer.from(`${u}:${p}`).toString('base64');
const get = (auth, env) => worker.fetch(
  new Request('https://quantjobs.pages.dev/', auth ? { headers: { Authorization: auth } } : {}),
  { ASSETS: assets, ...env });

let fails = 0;
const check = (name, got, want) => {
  const ok = got === want;
  if (!ok) fails++;
  console.log(`${ok ? 'ok  ' : 'FAIL'}  ${name}: ${got}${ok ? '' : ` (wanted ${want})`}`);
};

const P = { SITE_PASSWORD: 'correct horse battery staple' };

check('no password configured  → 503', (await get(null, {})).status, 503);
check('no credential           → 401', (await get(null, P)).status, 401);
check('wrong password          → 401', (await get(basic('x', 'nope'), P)).status, 401);
check('right password          → 200', (await get(basic('x', P.SITE_PASSWORD), P)).status, 200);
check('any username works      → 200', (await get(basic('', P.SITE_PASSWORD), P)).status, 200);
check('password containing ":" → 200',
      (await get(basic('u', 'a:b:c'), { SITE_PASSWORD: 'a:b:c' })).status, 200);
check('non-base64 garbage      → 401', (await get('Basic !!!!', P)).status, 401);
check('bearer token            → 401', (await get('Bearer abc', P)).status, 401);
check('scheme is case-insens.  → 200', (await get('basic ' + Buffer.from(':' + P.SITE_PASSWORD).toString('base64'), P)).status, 200);

const okResp = await get(basic('x', P.SITE_PASSWORD), P);
check('challenge names Basic', (await get(null, P)).headers.get('WWW-Authenticate').startsWith('Basic realm='), true);
check('authorized body served', await okResp.text(), '<h1>page</h1>');
check('no shared caching', okResp.headers.get('Cache-Control'), 'private, no-store');
check('unset says what to do', (await get(null, {})).headers.get('Content-Type'), 'text/plain; charset=utf-8');


// ---- /state ----

/// KV, near enough: get and put over one string.
const store = (initial = null) => {
  let v = initial;
  return { get: async () => v, put: async (_k, s) => { v = s; }, read: () => v };
};

const call = (method, body, env) => worker.fetch(
  new Request('https://quantjobs.pages.dev/state', {
    method,
    headers: { Authorization: basic('x', P.SITE_PASSWORD) },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  }),
  { ASSETS: assets, ...P, ...env });

const T = (updated, extra = {}) => ({ saved: true, updated, ...extra });

check('/state needs the password', (await worker.fetch(
  new Request('https://quantjobs.pages.dev/state'), { ASSETS: assets, ...P })).status, 401);
check('/state with no store → 501', (await call('GET', undefined, {})).status, 501);
check('/state POST → 405', (await call('POST', {}, { STATE: store() })).status, 405);
check('/state bad JSON → 400', (await worker.fetch(
  new Request('https://quantjobs.pages.dev/state', {
    method: 'PUT', headers: { Authorization: basic('x', P.SITE_PASSWORD) }, body: 'nope' }),
  { ASSETS: assets, ...P, STATE: store() })).status, 400);

{
  const kv = store();
  const empty = await (await call('GET', undefined, { STATE: kv })).json();
  check('empty store reads as empty', JSON.stringify(empty.tracked), '{}');

  const first = await (await call('PUT',
    { tracked: { a: T('2026-08-01T00:00:00Z') } }, { STATE: kv })).json();
  check('a put comes back merged', first.tracked.a.saved, true);
  check('rev advances', first.rev, 1);
  check('the put was stored', JSON.parse(kv.read()).tracked.a.saved, true);
}
{
  // The phone marks one posting, the Mac another, neither having seen the
  // other's write. Both must survive.
  const kv = store();
  await call('PUT', { tracked: { a: T('2026-08-01T00:00:00Z') } }, { STATE: kv });
  const after = await (await call('PUT',
    { tracked: { b: T('2026-08-02T00:00:00Z') } }, { STATE: kv })).json();
  check('a blind write keeps both', Object.keys(after.tracked).sort().join(), 'a,b');
}
{
  const kv = store();
  await call('PUT', { tracked: { a: T('2026-08-05T00:00:00Z', { note: 'newer' }) } },
             { STATE: kv });
  const after = await (await call('PUT',
    { tracked: { a: T('2026-08-01T00:00:00Z', { note: 'older' }) } },
    { STATE: kv })).json();
  check('an older write does not win', after.tracked.a.note, 'newer');
}
{
  // A history, not a value: three steps out of two clients that each know two.
  const kv = store();
  const step = (stage, date, done = null) => ({ stage, date, done });
  await call('PUT', { tracked: { a: { updated: '2026-08-01T00:00:00Z', milestones: [
    step('applied', '2026-06-03'), step('OA', '2026-06-20')] } } }, { STATE: kv });
  const after = await (await call('PUT', { tracked: { a: {
    updated: '2026-08-02T00:00:00Z', milestones: [
      step('OA', '2026-06-20', '2026-06-21'), step('Interview', '2026-07-01')] } } },
    { STATE: kv })).json();
  const got = after.tracked.a.milestones;
  check('steps are unioned, not replaced', got.length, 3);
  check('steps stay in date order', got.map(s => s.stage).join(), 'applied,OA,Interview');
  check('a sat date is not lost', got.find(s => s.stage === 'OA').done, '2026-06-21');
}
{
  const kv = store();
  await call('PUT', { filters: { 'f-cat': 'swe' }, filtersUpdated: '2026-08-05T00:00:00Z' },
             { STATE: kv });
  const older = await (await call('PUT',
    { filters: { 'f-cat': 'quant-trading' }, filtersUpdated: '2026-08-01T00:00:00Z' },
    { STATE: kv })).json();
  check('newest filters win', older.filters['f-cat'], 'swe');
  const newer = await (await call('PUT',
    { filters: { 'f-cat': 'quant-research' }, filtersUpdated: '2026-08-09T00:00:00Z' },
    { STATE: kv })).json();
  check('newer filters replace them', newer.filters['f-cat'], 'quant-research');
}
// The posting snapshot: a fact about the listing, not an opinion about the
// mark, so it survives whichever side happens to be newer.
//
// This is what kept an Amazon interview off the page. The snapshot was added to
// a payload whose marks had not changed since the last sync, so the timestamps
// tied, `newer` resolved to the stored copy that had none, and the field was
// dropped on every push — for ever, because it could never be the newer one.
{
  const kv = store();
  await call('PUT', { tracked: { a: { saved: true, updated: '2026-08-01T00:00:00Z' } } },
             { STATE: kv });
  const same = await (await call('PUT',
    { tracked: { a: { saved: true, updated: '2026-08-01T00:00:00Z',
                      job: { company: 'Amazon', title: 'SDE Intern' } } } },
    { STATE: kv })).json();
  check('a snapshot lands even when the timestamps tie',
        same.tracked.a.job?.company, 'Amazon');

  const older = await (await call('PUT',
    { tracked: { a: { saved: false, updated: '2026-07-01T00:00:00Z' } } },
    { STATE: kv })).json();
  check('  and an older write without one does not erase it',
        older.tracked.a.job?.company, 'Amazon');

  const newer = await (await call('PUT',
    { tracked: { a: { saved: false, updated: '2026-09-01T00:00:00Z' } } },
    { STATE: kv })).json();
  check('  nor does a newer write from a client that has none',
        newer.tracked.a.job?.company, 'Amazon');
  check('  while the newer mark still wins', newer.tracked.a.saved, false);
}
{
  const kv = store('{ this is not json');
  const r = await call('GET', undefined, { STATE: kv });
  check('a corrupt store still serves', r.status, 200);
  check('a corrupt store reads as empty', JSON.stringify((await r.json()).tracked), '{}');
}

console.log(fails ? `\n${fails} FAILED` : '\nall passed');
process.exit(fails ? 1 : 0);
