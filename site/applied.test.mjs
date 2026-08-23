// The Applied tab as a pipeline, and tab counts that match what is drawn.
//
//   quantjobs --check --web /tmp/page.html
//   npm i jsdom && node site/applied.test.mjs /tmp/page.html
//
// Two things the page got wrong that the app has always had right. The tab
// counted postings while the list drew merged rows, so it read 995 above a list
// of 615. And Applied was a flat list, where the app groups it by stage with a
// count and a "to do" badge — which is the whole reason to open that tab.
import { JSDOM } from 'jsdom';
import fs from 'node:fs';

const marks = {
  updated: '2030-01-01T00:00:00Z',
  steps: s => ({ saved: false, hidden: false, note: '', updated: '2030-01-01T00:00:00Z',
                 milestones: s }),
};
const page = fs.readFileSync(process.argv[2], 'utf8');
const keys = [...page.matchAll(/data-key="([^"]+)"/g)].map(m => m[1]);
const tracked = {
  [keys[0]]: marks.steps([{ stage: 'Applied', date: '2026-08-01', done: null }]),
  [keys[1]]: marks.steps([{ stage: 'Applied', date: '2026-08-02', done: null }]),
  [keys[2]]: marks.steps([{ stage: 'Applied', date: '2026-08-03', done: null },
                          { stage: 'OA', date: '2026-08-10', done: null }]),
  [keys[3]]: marks.steps([{ stage: 'Applied', date: '2026-08-04', done: null },
                          { stage: 'OA', date: '2026-08-11', done: '2026-08-12' }]),
  [keys[4]]: marks.steps([{ stage: 'Applied', date: '2026-08-05', done: null },
                          { stage: 'Rejected', date: '2026-08-15', done: null }]),
};
const dom = new JSDOM('<!doctype html><html><head></head><body>' + page + '</body></html>',
  { runScripts: 'dangerously', url: 'https://q/', pretendToBeVisual: true,
    beforeParse(w) {
      w.fetch = async (u, o = {}) => {
        if (!String(u).includes('/state')) return new Response('{}', { status: 501 });
        if ((o.method || 'GET') === 'PUT') return Response.json({});
        return Response.json({ tracked, filters: null });
      };
    } });
const w = dom.window;
await new Promise(r => setTimeout(r, 1200));

let fails = 0;
const check = (n, got, want) => { const ok = String(got) === String(want);
  if (!ok) fails++; console.log(`${ok ? 'ok  ' : 'FAIL'}  ${n}: ${got}${ok ? '' : ` (wanted ${want})`}`); };
const $ = id => w.document.getElementById(id);
const tab = name => [...w.document.querySelectorAll('[role=tab]')]
  .find(b => b.dataset.list === name).dispatchEvent(new w.MouseEvent('click', { bubbles: true }));
const heads = () => [...w.document.querySelectorAll('.stage-head')];

// ---- the counts count what is drawn ----
//
// A tab count is a list size, not a filtered one — the app's sidebar works the
// same way. What it must not do is count postings while the list draws merged
// rows, which is how it came to read 995 above a list of 615.
const merge = on => { $('f-merge').checked = on;
                      $('f-merge').dispatchEvent(new w.Event('change')); };
const footTotal = () => Number($('foot').textContent.split(' of ')[1].split(' ')[0]);

merge(false);
const flat = Number($('n-all').textContent);
merge(true);
const folded = Number($('n-all').textContent);
console.log(`     All: ${flat} postings → ${folded} merged rows`);
check('merging lowers the All count', folded < flat, true);
check('  and the footer total agrees with it', footTotal(), folded);
check('the Applied tab counts the marks', $('n-applied').textContent, '5');

// ---- Applied is a pipeline ----
tab('applied');
await new Promise(r => setTimeout(r, 200));
const labels = heads().map(h => h.querySelector('.sh-name').textContent);
check('it is grouped by stage', labels.join(' · '), 'Applied · Online assessment · Rejected');
check('  each group counts its rows',
      heads().map(h => h.querySelector('.sh-n').textContent).join(','), '2,2,1');
const oa = heads().find(h => h.querySelector('.sh-name').textContent === 'Online assessment');
check('  an unsat step is badged to do', oa.querySelector('.sh-owed')?.textContent, '1 to do');
const done = heads().find(h => h.querySelector('.sh-name').textContent === 'Rejected');
check('  a stage with nothing owed is not', done.querySelector('.sh-owed'), 'null');
check('  headers sort above their rows',
      Number(heads()[0].style.order) < Number(heads()[1].style.order), true);

tab('all');
await new Promise(r => setTimeout(r, 200));
check('leaving the tab removes the headers', heads().length, 0);

console.log(fails ? `\n${fails} FAILED` : '\nall passed');
process.exit(fails ? 1 : 0);
