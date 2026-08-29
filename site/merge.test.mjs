// Does the page merge listings the way the app does?
//
//   quantjobs --check --web /tmp/page.html
//   npm i jsdom && node site/merge.test.mjs /tmp/page.html
//
// The app folds a role posted in several cities into one row. Getting that
// wrong on the page is quiet in both directions: fold too much and postings
// vanish, fold too little and the list reads as duplicates. So this pins the
// two rules that matter — every sibling hidden but one, and the survivor being
// the most recently posted — and that turning it off puts everything back
// exactly as it was.
import { JSDOM } from 'jsdom';
import fs from 'node:fs';
const dom = new JSDOM('<!doctype html><html><head></head><body>'
  + fs.readFileSync(process.argv[2], 'utf8') + '</body></html>',
  { runScripts: 'dangerously', url: 'https://q/', pretendToBeVisual: true,
    beforeParse(w) {
      // GET stays 501 so no stored state is applied and the assertions below
      // read the page as built. PUT is captured, because what reaches the
      // store is the half of merging that used to be wrong.
      w.fetch = async (u, o = {}) => {
        if (String(u).includes('/state') && (o.method || 'GET') === 'PUT') {
          pushed = JSON.parse(o.body); return Response.json({});
        }
        return new Response('{}', { status: 501 });
      };
    } });
let pushed = null;
const w = dom.window;
await new Promise(r => setTimeout(r, 600));
let fails = 0;
const check = (n, got, want) => { const ok = String(got) === String(want);
  if (!ok) fails++; console.log(`${ok ? 'ok  ' : 'FAIL'}  ${n}: ${got}${ok ? '' : ` (wanted ${want})`}`); };

const all = [...w.document.querySelectorAll('.row')];
const vis = () => all.filter(li => !li.hasAttribute('data-local-hide'));
const box = w.document.getElementById('f-merge');
const toggle = on => { box.checked = on; box.dispatchEvent(new w.Event('change')); };

toggle(false);
const unmerged = vis().length;
toggle(true);
const merged = vis().length;
console.log(`     ${unmerged} rows unmerged → ${merged} merged (${unmerged - merged} folded)`);
check('merging folds rows', merged < unmerged, true);
check('footer counts merged rows',
      w.document.getElementById('foot').textContent.startsWith(String(merged)), true);

const plussed = vis().filter(li => li.querySelector('.plus'));
check('folded rows are marked', plussed.length > 0, true);
if (plussed.length) {
  const li = plussed[0];
  console.log('     e.g.', li.dataset.firm, '·', li.querySelector('.ti').textContent.trim().slice(0, 44));
  console.log('          ', li.querySelector('.me').textContent.trim().slice(0, 74));
  const key = li.dataset.role;
  const sameRole = all.filter(x => x.dataset.role === key);
  check('  all its siblings are hidden',
        sameRole.filter(x => !x.hasAttribute('data-local-hide')).length, 1);
  check('  the survivor is the newest',
        li.dataset.posted, sameRole.map(x => x.dataset.posted).sort().reverse()[0]);
}
toggle(false);
check('unmerging restores the count', vis().length, unmerged);
check('  and removes the badge', vis().filter(li => li.querySelector('.plus')).length, 0);
// Not a bare '+': a posting's own location can read "Hong Kong, HK +1", which
// made this fail on a listing that was perfectly restored. The badge is the
// thing that must be gone, and it always reads "+N more".
const restored = plussed.length ? plussed[0].querySelector('.me').textContent : '';
check('  and the original location text', restored.includes(' more'), false);

// ---- marking a merged row marks every posting it stands for ----
//
// A merged row covers several postings, and the app marks all of them. The page
// marked only the visible one, so the folded copies came back unstarred the
// moment merging was turned off — and because which copy leads is decided by
// posting date, a rebuild could hand the lead to a different posting and the
// star looked like it had moved on its own. That is what "saved does not sync"
// turned out to be.
if (plussed.length) {
  toggle(true);
  const lead = vis().find(li => li.querySelector('.plus'));
  const family = all.filter(x => x.dataset.role === lead.dataset.role);
  lead.querySelector('.mk[data-act=save]')
      .dispatchEvent(new w.MouseEvent('click', { bubbles: true }));
  check('starring a merged row stars every posting in it',
        family.filter(x => x.dataset.saved === '1').length, family.length);

  await new Promise(r => setTimeout(r, 1600));   // past the push debounce
  const sent = Object.keys(pushed?.tracked || {});
  check('  and every one of them reaches the store',
        family.every(x => sent.includes(x.dataset.key)), true);
  check('  each carrying an instant, so the merge can date it',
        family.every(x => (pushed.tracked[x.dataset.key] || {}).updated), true);

  toggle(false);
  check('  so they are still starred with merging off',
        family.filter(x => x.dataset.saved === '1').length, family.length);
}

console.log(fails ? `\n${fails} FAILED` : '\nall passed');
process.exit(fails ? 1 : 0);
