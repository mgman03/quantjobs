// Is the page still usable on a phone?
//
//   quantjobs --check --web /tmp/page.html
//   npm i jsdom && node site/mobile.test.mjs /tmp/page.html
//
// These are the ones that are silent when they break. A missing viewport tag
// does not throw — it just lays the page out 980px wide and scales it down, and
// the page still "works", at about 40%. A field one pixel under 16px does not
// throw either; Safari zooms in on it and never zooms back out. And a mark that
// does not write a step looks like it landed right up until the next pull takes
// it away again.
//
// Sizes and positions are not checked here: jsdom has no layout. This pins the
// stylesheet's own numbers and the behaviour around them.
import { JSDOM } from 'jsdom';
import fs from 'node:fs';

const html = fs.readFileSync(process.argv[2], 'utf8');
let fails = 0;
const check = (n, got, want) => { const ok = String(got) === String(want);
  if (!ok) fails++; console.log(`${ok ? 'ok  ' : 'FAIL'}  ${n}: ${got}${ok ? '' : ` (wanted ${want})`}`); };

// ---- the two that are invisible in the source ----

const viewport = html.match(/<meta name="viewport" content="([^"]*)"/);
check('the page asks for the phone\'s own width',
      !!viewport && viewport[1].includes('width=device-width'), true);
check('  and for the area behind the notch, which the insets need',
      !!viewport && viewport[1].includes('viewport-fit=cover'), true);

// Every rule that dresses something you can put a caret or a picker in. Under
// 16px Safari zooms the page on focus and leaves it there, which on this page
// means the list ends up half off the side of the screen.
// Comments out first, or the one above a rule reads as part of its selector.
const style = html.slice(html.indexOf('<style>'), html.indexOf('</style>'))
                  .replace(/\/\*[\s\S]*?\*\//g, '');
const FIELD = /(^|[\s,>])(input|select|textarea)\b|#(q|s-note|s-date|s-stage)\b/;
let smallest = 99;
for (const [, selector, body] of style.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
  if (!FIELD.test(selector) || /checkbox/.test(selector)) continue;
  for (const [, px] of body.matchAll(/font-size:\s*([\d.]+)px/g)) {
    if (Number(px) < smallest) smallest = Number(px);
    if (Number(px) < 16) { fails++; console.log(`FAIL  ${selector.trim()} is ${px}px`); }
  }
}
check('no field a phone can focus is under 16px', smallest >= 16, true);

// ---- behaviour ----

// A store that answers like the worker does, so a mark can be followed out and
// back again.
let held = { rev: 0, tracked: {}, filters: null, filtersUpdated: '' };
const fake = async (url, opts = {}) => {
  if (!String(url).includes('/state')) return new Response('{}', { status: 501 });
  if (opts.method === 'PUT') {
    for (const [k, v] of Object.entries(JSON.parse(opts.body).tracked || {}))
      held.tracked[k] = v;
  }
  return new Response(JSON.stringify(held), { status: 200 });
};
const dom = new JSDOM('<!doctype html><html><head></head><body>' + html + '</body></html>',
  { runScripts: 'dangerously', url: 'https://q/', pretendToBeVisual: true,
    beforeParse(w) { w.fetch = fake; } });
const w = dom.window;
const sleep = ms => new Promise(r => setTimeout(r, ms));
const $ = id => w.document.getElementById(id);
const tap = el => el.dispatchEvent(new w.MouseEvent('click', { bubbles: true }));
w.addEventListener('error', e => { fails++; console.log('PAGE ERROR:', e.message); });
await sleep(700);

// The list's ➤ used to set the stage attribute and nothing else. Only the steps
// are sent, so it went up as an empty history and the next pull erased it — the
// quickest mark on the phone was the one that did not last.
const li = [...w.document.querySelectorAll('.row')].find(x => x.dataset.stage === '');
tap(li.querySelector('.mk.apply'));
check('one tap of ➤ marks it applied', li.dataset.stage, 'Applied');
check('  and writes that as a step', li.dataset.steps.split(';').filter(Boolean).length, 1);
await sleep(1600);                        // the debounce, then the PUT
check('  which is what reaches the store',
      (held.tracked[li.dataset.key]?.milestones || []).length, 1);
w.eval('pull()');
await sleep(300);
check('  so a pull does not take it away again', li.dataset.stage, 'Applied');

// Undo. The three marks are a finger's width apart and the last one makes the
// row disappear, so a near miss needs a way back that is not "go and find it in
// the Hidden tab".
const other = [...w.document.querySelectorAll('.row')].find(x => x.dataset.hidden === '0');
tap(other.querySelector('.mk.hide'));
check('hiding a row says so', $('toast-say').textContent, 'Hidden');
check('  and the row is hidden', other.dataset.hidden, '1');
tap($('toast-undo'));
check('undo puts it back', other.dataset.hidden, '0');
check('  and takes the offer away', $('toast').hidden, true);

// Clearing used to blank every control, including the sort, which has no empty
// option — so it was left showing nothing at all.
$('f-city').value = [...$('f-city').options][1]?.value || '';
$('f-city').dispatchEvent(new w.Event('change'));
$('q').value = 'zzzznotathing';
$('q').dispatchEvent(new w.Event('input'));
check('a search nothing matches empties the list', $('empty').hidden, false);
check('  and says which of the two is doing it',
      $('empty-why').textContent.includes('Nothing matches'), true);
check('  and offers the way out', $('empty-clear').hidden, false);
tap($('empty-clear'));
check('clearing goes back to the defaults, not to blank', $('f-sort').value, 'date');
check('  including the level', $('f-level').value, 'intern');
check('  and the list comes back', $('empty').hidden, true);

console.log(fails ? `\n${fails} FAILED` : '\nall passed');
process.exit(fails ? 1 : 0);
