// Tests the password gate in _worker.js. `node site/_worker.test.mjs`.
//
// Worth having for twenty lines of auth because this is the only thing
// between the internet and a list of what you applied to and were rejected
// from, and every failure mode here is silent: a gate that lets everyone
// through looks exactly like a gate that works.
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

console.log(fails ? `\n${fails} FAILED` : '\nall passed');
process.exit(fails ? 1 : 0);
