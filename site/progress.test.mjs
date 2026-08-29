// Does the page show a fetch that is already running?
//
//   quantjobs --check --web /tmp/page.html
//   npm i jsdom && node site/progress.test.mjs /tmp/page.html
//
// The button used to know only about a fetch it had started itself. Reload
// mid-fetch, or open the page on a second phone, or let the schedule start one,
// and the page showed a stale timestamp and no sign that anything was
// happening — which reads exactly like a refresh that did nothing. So the page
// asks on load, and follows whatever it finds.
import { JSDOM } from 'jsdom';
import fs from 'node:fs';

const page = fs.readFileSync(process.argv[2], 'utf8');
let fails = 0;
const check = (n, got, want) => { const ok = String(got) === String(want);
  if (!ok) fails++; console.log(`${ok ? 'ok  ' : 'FAIL'}  ${n}: ${got}${ok ? '' : ` (wanted ${want})`}`); };

/// A page whose /refresh answers with `status`, and whose clock is stopped.
async function open(status) {
  let asked = 0;
  const dom = new JSDOM('<!doctype html><html><head></head><body>' + page + '</body></html>',
    { runScripts: 'dangerously', url: 'https://q/', pretendToBeVisual: true,
      beforeParse(w) {
        w.fetch = async (u, o = {}) => {
          if (String(u).includes('/refresh')) { asked++; return Response.json(status); }
          if (String(u).includes('/state')) return Response.json({ tracked: {}, filters: null });
          return new Response('{}', { status: 501 });
        };
      } });
  await new Promise(r => setTimeout(r, 1400));
  return { w: dom.window, asked: () => asked };
}

// ---- a run someone else started ----
{
  const { w, asked } = await open({
    status: 'in_progress', conclusion: null,
    started: new Date(Date.now() - 95000).toISOString(),
    phase: 'Fetch every board and write the page',
  });
  const made = w.document.getElementById('made');
  check('it asks on load, with no click', asked() > 0, true);
  check('  and says what the runner is doing', made.textContent.includes('reading 193 boards'), true);
  // Anchored on the separator: a bare \d+:\d\d also matches the build
  // timestamp this line normally carries ("20 Aug, 05:51"), so the loose form
  // passed against a page that showed no elapsed time at all.
  check('  with how long it has been going',
        / · \d+:\d\d$/.test(made.textContent.trim()), true);
  check('  and spins', w.document.getElementById('refresh').classList.contains('busy'), true);
}

// ---- a step this page has never heard of ----
{
  const { w } = await open({ status: 'in_progress', phase: 'Some New Step',
                             started: new Date().toISOString() });
  check('an unknown step is shown rather than swallowed',
        w.document.getElementById('made').textContent.includes('some new step'), true);
}

// ---- nothing running ----
{
  const { w } = await open({ status: 'completed', conclusion: 'success',
                             finished: '2020-01-01T00:00:00Z' });
  const made = w.document.getElementById('made');
  check('an old finished run leaves the page alone', /^from the Mac|^fetched/.test(made.textContent.trim()), true);
  check('  and does not spin', w.document.getElementById('refresh').classList.contains('busy'), false);
}

console.log(fails ? `\n${fails} FAILED` : '\nall passed');
process.exit(fails ? 1 : 0);
