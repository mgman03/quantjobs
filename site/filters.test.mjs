// Clear, and recovering from a filter value a control cannot hold.
//
//   quantjobs --check --web /tmp/page.html
//   npm i jsdom && node site/filters.test.mjs /tmp/page.html
//
// Pressing Clear set every control to "". Ten of the twelve have an empty
// option, so that is right for them; the sort does not, and a <select> handed a
// value it has no option for reports selectedIndex -1 and draws nothing. The
// filters sync, so that blank was written to the shared store, came back on
// every load, and reached the app — a broken control that pressing Clear could
// not fix, because Clear was what caused it.
//
// Both halves are pinned here: Clear returning to real defaults, and a store
// that is already damaged being repaired on the way in rather than reapplied.
import { JSDOM } from 'jsdom';
import fs from 'node:fs';

const page = fs.readFileSync(process.argv[2], 'utf8');
let fails = 0;
const check = (n, got, want) => { const ok = String(got) === String(want);
  if (!ok) fails++; console.log(`${ok ? 'ok  ' : 'FAIL'}  ${n}: ${got}${ok ? '' : ` (wanted ${want})`}`); };

/// A page wired to a store we control, reporting what it pushes back.
function open_(filters) {
  const state = { pushed: null };
  const dom = new JSDOM('<!doctype html><html><head></head><body>' + page + '</body></html>',
    { runScripts: 'dangerously', url: 'https://q/', pretendToBeVisual: true,
      beforeParse(w) {
        w.fetch = async (u, o = {}) => {
          if (!String(u).includes('/state')) return new Response('{}', { status: 501 });
          if ((o.method || 'GET') === 'PUT') { state.pushed = JSON.parse(o.body); return Response.json({}); }
          return Response.json({ tracked: {},
            filters, filtersUpdated: filters ? '2030-01-01T00:00:00Z' : '' });
        };
      } });
  state.w = dom.window;
  return state;
}
const sleep = ms => new Promise(r => setTimeout(r, ms));

// ---- Clear ----
{
  const s = open_(null);
  await sleep(600);
  const sel = id => s.w.document.getElementById(id);
  sel('clear').dispatchEvent(new s.w.MouseEvent('click', { bubbles: true }));
  await sleep(2000);
  check('Clear leaves sort usable', sel('f-sort').selectedIndex >= 0, true);
  check('  at its default', sel('f-sort').value, 'date');
  check('  and empties the ones that can be empty', sel('f-cat').value, '');
  check('  and pushes nothing broken',
        s.pushed && s.pushed.filters['f-sort'], 'date');
}

// ---- a store that is already damaged ----
{
  const s = open_({ 'f-sort': '', 'f-cat': 'swe', 'f-level': 'intern' });
  await sleep(1500);
  const sel = id => s.w.document.getElementById(id);
  check('a stored blank sort is repaired', sel('f-sort').value, 'date');
  check('  the rest is left alone', sel('f-cat').value, 'swe');
  check('  an empty level is valid and kept', sel('f-level').value, 'intern');
  await sleep(1500);
  check('  and the repair is written back',
        s.pushed && s.pushed.filters['f-sort'], 'date');
}

// ---- a value the app sent that the page has no option for ----
{
  const s = open_({ 'f-region': 'Europe|North America' });
  await sleep(1500);
  check('a set from the app survives',
        s.w.document.getElementById('f-region').value, 'Europe|North America');
}

console.log(fails ? `\n${fails} FAILED` : '\nall passed');
process.exit(fails ? 1 : 0);
