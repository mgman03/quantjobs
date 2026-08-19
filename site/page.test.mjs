// The built page's sync client, loaded into a DOM and pointed at the real worker.
//
//   node site/serve.mjs 8791 &
//   swift run QuantJobs --check --web /tmp/page.html
//   npm i jsdom && node site/page.test.mjs /tmp/page.html
//
// The page is the half of the sync that cannot be checked by reading it: the
// marks are DOM attributes, the saves are triggered by a MutationObserver, and
// a star that silently fails to travel looks exactly like one that travelled.
// jsdom is not a dependency of anything that ships — install it when you want to
// run this.
//
// The state the test expects is whatever the worker happens to be holding, so
// run it after a --check --sync --push has put something there.
import { JSDOM } from 'jsdom';
import fs from 'node:fs';

const html = fs.readFileSync(process.argv[2], 'utf8');
// jsdom has no fetch, and it has to be there before the page's script runs —
// the page treats a missing fetch as being offline, which is correct of it and
// made this test quietly pass nothing.
const auth = 'Basic ' + Buffer.from('x:hunter2').toString('base64');
const withAuth = (url, opts = {}) => fetch(new URL(url, 'http://127.0.0.1:8791'), {
  ...opts, headers: { ...(opts.headers || {}), Authorization: auth } });

const dom = new JSDOM('<!doctype html><html><head></head><body>' + html + '</body></html>',
  { runScripts: 'dangerously', url: 'http://127.0.0.1:8791/', pretendToBeVisual: true,
    beforeParse(window) { window.fetch = withAuth; } });
const w = dom.window;

const sleep = ms => new Promise(r => setTimeout(r, ms));
let fails = 0;
const check = (name, got, want) => {
  const ok = String(got) === String(want);
  if (!ok) fails++;
  console.log(`${ok ? 'ok  ' : 'FAIL'}  ${name}: ${got}${ok ? '' : ` (wanted ${want})`}`);
};

w.addEventListener('error', e => { fails++; console.log('PAGE ERROR:', e.message); });
await sleep(1500);                      // the page's own pull()
const rows = [...w.document.querySelectorAll('.row')];
check('page has rows', rows.length > 100, true);

// Did the phone's stored marks land on the row they belong to?
// Whichever posting the store already knows about and the page still lists.
const stored = await (await withAuth('/state')).json();
const key = Object.keys(stored.tracked)
  .find(k => rows.some(li => li.dataset.key === k)) || '';
const seeded = rows.find(li => li.dataset.key === key);
check('the synced posting is on the page', !!seeded, true);
if (seeded) {
  check('  its star came from the server', seeded.dataset.saved,
        stored.tracked[key].saved ? '1' : '0');
    const want = stored.tracked[key];
  check('  its steps came too',
        seeded.dataset.steps.split(';').filter(Boolean).length,
        (want.milestones || []).length);
  check('  and its note', seeded.dataset.note, want.note || '');
}

// Now star something else here and confirm it reaches the store.
const fresh = rows.find(li => li.dataset.saved === '0' && li.dataset.key !== key);
fresh.querySelector('.mk.save').dispatchEvent(new w.MouseEvent('click', {bubbles: true}));
check('starring sets the row', fresh.dataset.saved, '1');
await sleep(2000);                      // the debounce, then the PUT

const after = await (await withAuth('/state')).json();
check('the star reached the store', after.tracked[fresh.dataset.key]?.saved, true);
check('  with an instant on it',
      /^\d{4}-\d\d-\d\dT/.test(after.tracked[fresh.dataset.key]?.updated || ''), true);
check('  and did not drop the other', after.tracked[key]?.saved, true);

// A filter change has to travel too.
const cat = w.document.getElementById('f-level');
cat.value = 'newgrad';
cat.dispatchEvent(new w.Event('change'));
await sleep(2000);
const filters = await (await withAuth('/state')).json();
check('the filter reached the store', filters.filters['f-level'], 'newgrad');

console.log(fails ? `\n${fails} FAILED` : '\nall passed');
process.exit(fails ? 1 : 0);
