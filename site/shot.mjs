// Renders the page in a real browser and writes a PNG.
//
//   node site/shot.mjs <url> <out.png> [options]
//
// This exists because every other check in this directory runs under jsdom,
// which parses CSS but never lays it out. jsdom will happily tell you a rule
// is present and cannot tell you the heading is invisible, unspaced, or
// stacked on top of the rows — which is exactly the pair of bugs that shipped
// in the Applied tab. Structure passing is not the same as looking right, and
// the only way to know the difference is to let a browser do the layout.
//
// No dependencies. Chrome is already on this machine and node speaks
// WebSocket natively, so this drives the browser over the DevTools protocol
// rather than pulling in puppeteer and a second copy of Chromium.
//
// Options:
//   --width N     viewport CSS px            (default 390, an iPhone 15)
//   --height N    viewport CSS px            (default 844)
//   --dsr N       device pixel ratio         (default 2, so text is legible)
//   --full        capture the whole scrollable page, not just the viewport
//   --auth u:p    HTTP Basic credentials, for the password gate
//   --wait SEL    wait until this selector exists before shooting
//   --eval JS     run this in the page first (click a tab, set a filter)
//   --settle MS   pause after --eval before capturing (default 400)
//   --chrome P    path to a Chrome binary
import { spawn } from 'node:child_process';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const argv = process.argv.slice(2);
const flag = (name, fallback = null) => {
  const i = argv.indexOf(name);
  return i < 0 ? fallback : argv[i + 1];
};
const has = name => argv.includes(name);

const [url, out] = argv.filter((a, i) =>
  !a.startsWith('--') && !(i > 0 && argv[i - 1].startsWith('--') && argv[i - 1] !== '--full'));
if (!url || !out) {
  console.error('usage: node site/shot.mjs <url> <out.png> [--full] [--width N] ...');
  process.exit(2);
}

const width  = Number(flag('--width', 390));
const height = Number(flag('--height', 844));
const dsr    = Number(flag('--dsr', 2));
const chrome = flag('--chrome', '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome');

// A throwaway profile each run. Without it Chrome reuses the default one and
// either refuses to start a second instance or inherits real cookies — this
// must never see the user's browsing state.
const profile = await mkdtemp(join(tmpdir(), 'shot-'));

const proc = spawn(chrome, [
  '--headless', '--disable-gpu', '--no-first-run', '--no-default-browser-check',
  '--hide-scrollbars', '--force-color-profile=srgb',
  `--user-data-dir=${profile}`, '--remote-debugging-port=0', 'about:blank',
], { stdio: ['ignore', 'ignore', 'pipe'] });

// Port 0 means Chrome picks one; it announces the real one on stderr.
const endpoint = await new Promise((resolve, reject) => {
  let buf = '';
  const timer = setTimeout(() => reject(new Error('Chrome never announced a debugging port')), 20000);
  proc.stderr.on('data', d => {
    buf += d;
    const m = buf.match(/ws:\/\/[^\s]+/);
    if (m) { clearTimeout(timer); resolve(m[0]); }
  });
  proc.on('exit', c => { clearTimeout(timer); reject(new Error(`Chrome exited (${c})`)); });
});

const origin = new URL(endpoint).origin.replace('ws://', 'http://');
const targets = await fetch(`${origin}/json/list`).then(r => r.json());
const page = targets.find(t => t.type === 'page');

const ws = new WebSocket(page.webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r, { once: true }));

let nextId = 0;
const pending = new Map();
const events = new Map();
ws.addEventListener('message', e => {
  const msg = JSON.parse(e.data);
  if (msg.id !== undefined) {
    const p = pending.get(msg.id);
    pending.delete(msg.id);
    msg.error ? p.reject(new Error(msg.error.message)) : p.resolve(msg.result);
  } else if (events.has(msg.method)) {
    events.get(msg.method).forEach(fn => fn(msg.params));
    events.delete(msg.method);
  }
});
// Every call is bounded. A page that navigates while an evaluate is suspended
// destroys the execution context it was waiting in, and the reply never comes —
// which hangs the whole run rather than failing it. That is not hypothetical:
// this page reloads itself when the fetch it is watching finishes, so shooting
// it at the wrong moment hangs forever without the timeout.
const send = (method, params = {}, ms = 30000) => new Promise((resolve, reject) => {
  const id = ++nextId;
  const timer = setTimeout(() => {
    pending.delete(id);
    reject(new Error(`${method} did not answer in ${ms}ms (did the page navigate?)`));
  }, ms);
  pending.set(id, { resolve: v => { clearTimeout(timer); resolve(v); },
                    reject: e => { clearTimeout(timer); reject(e); } });
  ws.send(JSON.stringify({ id, method, params }));
});
const once = method => new Promise(r => {
  events.set(method, [...(events.get(method) || []), r]);
});

await send('Page.enable');
await send('Runtime.enable');
await send('Network.enable');

// The deployed page sits behind HTTP Basic. Sent as a header rather than as
// credentials in the URL, which Chrome strips on some navigations.
const auth = flag('--auth');
if (auth) {
  await send('Network.setExtraHTTPHeaders',
    { headers: { Authorization: 'Basic ' + Buffer.from(auth).toString('base64') } });
}

await send('Emulation.setDeviceMetricsOverride',
  { width, height, deviceScaleFactor: dsr, mobile: dsr > 1 });

const loaded = once('Page.loadEventFired');
await send('Page.navigate', { url });
await loaded;

const evaluate = expr => send('Runtime.evaluate',
  { expression: expr, awaitPromise: true, returnByValue: true });

// The page fills its list from a fetch, so "loaded" is not "drawn". Poll for
// something that only exists once the content is there.
const waitFor = flag('--wait');
if (waitFor) {
  const deadline = Date.now() + 15000;
  for (;;) {
    const { result } = await evaluate(`!!document.querySelector(${JSON.stringify(waitFor)})`);
    if (result.value) break;
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${waitFor}`);
    await new Promise(r => setTimeout(r, 150));
  }
}

const script = flag('--eval');
if (script) {
  const { result, exceptionDetails } = await evaluate(script);
  if (exceptionDetails) throw new Error('--eval threw: ' + exceptionDetails.text);
  // Printed, because it is usually the answer to a question — what the header
  // says, how many rows are showing — and a screenshot is a slow way to read a
  // string.
  if (result && result.value !== undefined) console.error('  eval: ' + JSON.stringify(result.value));
}

// Always, not only after --eval: a page that finishes its own work after load —
// asking what the runner is doing, say — has nothing on screen yet when the
// load event fires, and shooting it straight away photographs the wrong moment.
// This cost me a screenshot I read as a bug in the page.
await new Promise(r => setTimeout(r, Number(flag('--settle', 400))));

const shot = { format: 'png', captureBeyondViewport: has('--full') };
if (has('--full')) {
  const { cssContentSize, contentSize } = await send('Page.getLayoutMetrics');
  const size = cssContentSize || contentSize;
  shot.clip = { x: 0, y: 0, width: size.width, height: size.height, scale: dsr };
}
const { data } = await send('Page.captureScreenshot', shot);
await writeFile(out, Buffer.from(data, 'base64'));

ws.close();
proc.kill();

// The screenshot is written by now, so nothing below may fail the run.
// Chrome keeps flushing its profile for a moment after the kill, and deleting
// the directory out from under it raises ENOTEMPTY — which threw away a
// perfectly good capture. Wait for the process to go, then sweep, and shrug if
// the sweep loses the race: it is a temp directory the OS will reap anyway.
await new Promise(r => { proc.once('exit', r); setTimeout(r, 2000); });
for (let i = 0; i < 3; i++) {
  try { await rm(profile, { recursive: true, force: true }); break; }
  catch { await new Promise(r => setTimeout(r, 250)); }
}
console.error(`wrote ${out}  (${width}x${height} @${dsr}x${has('--full') ? ', full page' : ''})`);
