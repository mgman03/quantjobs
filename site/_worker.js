// Asks for a password before serving anything.
//
// Cloudflare Pages runs this on every request if the deployed directory has a
// _worker.js at its root, so this is the whole lock: no Zero Trust account, no
// identity provider, nothing to onboard. The workflow copies this file next to
// the built page.
//
// The page carries an application history — what was applied to, what was
// rejected — which is why the obvious alternative, the Pages "Access policy"
// toggle, is not enough: it covers preview deployments only and leaves the real
// quantjobs.pages.dev URL open to anyone with the link.
//
// Basic auth rather than a login form because the browser owns it: Safari and
// Chrome offer to save it to the keychain, so it is one tap after the first
// time, and there is no cookie, session or sign-in page to get wrong.
//
// _worker.js rather than functions/_middleware.js because this is a direct
// upload: `wrangler pages deploy web` resolves a functions directory relative
// to the working directory rather than to the directory being deployed, and a
// gate that silently fails to install is worse than no gate. A _worker.js at
// the root of the deployed directory is unambiguous — Pages hands it every
// request, and static files come back through the ASSETS binding.

const REALM = 'Quant Jobs';

export default {
  async fetch(request, env) {
    // Fails closed. An unset password is a misconfiguration, and serving the
    // history to the internet is the failure this exists to prevent — so say
    // what is wrong instead, to whoever asks.
    if (!env.SITE_PASSWORD) return unconfigured();

    const given = passwordFrom(request.headers.get('Authorization'));
    if (given === null || !(await sameSecret(given, env.SITE_PASSWORD))) {
      return challenge();
    }

    const url = new URL(request.url);
    if (url.pathname === '/state') return state(request, env);
    if (url.pathname === '/refresh') return refresh(request, env);

    const response = await env.ASSETS.fetch(request);
    // The response is per-viewer now, so nothing in between may keep a copy.
    const out = new Response(response.body, response);
    out.headers.set('Cache-Control', 'private, no-store');
    return out;
  },
};

// ---- /refresh: ask the scheduled fetch to run now ----
//
// The page is a file. It cannot scrape, and the phone has no business holding a
// token that could — so the button asks the thing that *does* build it, and the
// token stays here, where only this worker can reach it.
//
// GET reports the newest run so the page can tell when a fresh copy exists.
// POST starts one. Both need the same password as the page.

// Set by the deploy from ${{ github.repository }}, so a fork dispatches its own
// workflow rather than this one's. The fallback only matters for a deploy that
// predates the variable being set.
const WORKFLOW = 'fetch.yml';
const repoOf = env => env.GITHUB_REPO || 'mgman03/quantjobs';

async function refresh(request, env) {
  if (!env.REFRESH_TOKEN) {
    return json({ error: 'no token bound; refreshing is not set up' }, 501);
  }
  const repo = repoOf(env);
  const api = (path, init) => fetch(`https://api.github.com/repos/${repo}${path}`, {
    ...init,
    headers: {
      Authorization: `Bearer ${env.REFRESH_TOKEN}`,
      Accept: 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
      // GitHub rejects an API request with no user agent.
      'User-Agent': 'quantjobs-worker',
      ...(init?.headers || {}),
    },
  });

  if (request.method === 'GET') {
    const r = await api(`/actions/workflows/${WORKFLOW}/runs?per_page=1`);
    if (!r.ok) return json({ error: `github answered ${r.status}` }, 502);
    const run = (await r.json()).workflow_runs?.[0];
    return json(run
      ? { status: run.status, conclusion: run.conclusion, finished: run.updated_at }
      : { status: 'none' });
  }

  if (request.method !== 'POST') {
    return json({ error: 'GET or POST' }, 405, { Allow: 'GET, POST' });
  }

  const r = await api(`/actions/workflows/${WORKFLOW}/dispatches`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ ref: 'main' }),
  });
  // 204 is the success here; anything else is worth passing on rather than
  // swallowing, because "nothing happened" is the confusing failure.
  if (r.status !== 204) {
    return json({ error: `github answered ${r.status}`,
                  detail: (await r.text()).slice(0, 300) }, 502);
  }
  return json({ started: true }, 202);
}

// ---- /state: the marks and filters, shared between the phone and the Mac ----
//
// The page is rebuilt from scratch every hour, so anything tapped on the phone
// has to live somewhere that survives a deploy, and the repository cannot be it:
// it is public, and these are rejections. So a KV namespace, reachable only
// through the password above.
//
// One document rather than a key per posting. It is a few hundred entries at
// most, both clients want all of it at once, and KV's free tier counts writes:
// one PUT for a burst of taps beats one per tap.

const KEY = 'state';

async function state(request, env) {
  if (!env.STATE) {
    return json({ error: 'no store bound; marks cannot be saved' }, 501);
  }
  if (request.method === 'GET') {
    return json(await load(env));
  }
  if (request.method !== 'PUT') {
    return json({ error: 'GET or PUT' }, 405, { Allow: 'GET, PUT' });
  }

  let incoming;
  try {
    incoming = await request.json();
  } catch {
    return json({ error: 'body is not JSON' }, 400);
  }
  if (!incoming || typeof incoming !== 'object') {
    return json({ error: 'body is not an object' }, 400);
  }

  // Merged here rather than trusting what arrived, because two clients that
  // both read at breakfast and write at lunch would otherwise have the second
  // one silently delete the first one's marks. The rule is per posting and by
  // timestamp, so neither client has to know the other exists.
  const merged = mergeState(await load(env), incoming);
  merged.rev = (merged.rev || 0) + 1;
  await env.STATE.put(KEY, JSON.stringify(merged));
  return json(merged);
}

async function load(env) {
  const raw = await env.STATE.get(KEY);
  if (!raw) return { rev: 0, tracked: {}, filters: null, filtersUpdated: '' };
  try {
    const d = JSON.parse(raw);
    d.tracked ||= {};
    return d;
  } catch {
    // Unparseable is indistinguishable from absent, and refusing to serve
    // would leave both clients stuck on it forever.
    return { rev: 0, tracked: {}, filters: null, filtersUpdated: '' };
  }
}

/// Newest wins, per posting and for the filters separately.
///
/// Milestones are unioned instead, because they are a history: the Mac holding
/// "applied 3 June, OA 20 June" and the phone adding an interview should end up
/// with three steps, not with whichever side was touched last.
function mergeState(mine, theirs) {
  const out = { rev: mine.rev || 0, tracked: { ...(mine.tracked || {}) } };

  for (const [key, t] of Object.entries(theirs.tracked || {})) {
    const m = out.tracked[key];
    if (!m) { out.tracked[key] = t; continue; }
    const newer = (t.updated || '') > (m.updated || '') ? t : m;
    out.tracked[key] = { ...newer, milestones: unionSteps(m, t) };
  }

  const a = mine.filtersUpdated || '', b = theirs.filtersUpdated || '';
  const filtersFrom = b > a ? theirs : mine;
  out.filters = filtersFrom.filters ?? null;
  out.filtersUpdated = filtersFrom.filtersUpdated || '';
  return out;
}

/// Steps are identified by stage and date, so recording the same OA twice is
/// one step and two different OAs stay two. A sat date on either side is kept:
/// "the OA arrived" and "I submitted it" are one step with two dates, and the
/// side that knows the second one is the side that has been used more recently.
function unionSteps(m, t) {
  const by = new Map();
  for (const s of [...(m.milestones || []), ...(t.milestones || [])]) {
    if (!s || !s.stage || !s.date) continue;
    const id = `${s.stage}|${s.date}`;
    const had = by.get(id);
    by.set(id, had ? { ...had, done: had.done || s.done || null } : { ...s });
  }
  return [...by.values()].sort((x, y) => x.date.localeCompare(y.date));
}

function json(body, status = 200, headers = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      'Cache-Control': 'private, no-store',
      ...headers,
    },
  });
}

/// The password out of a Basic credential, or null if there isn't one.
/// The username is ignored — there is one page and one person.
function passwordFrom(header) {
  if (!header) return null;
  const [scheme, encoded] = header.split(' ');
  if (!encoded || scheme.toLowerCase() !== 'basic') return null;
  try {
    const decoded = atob(encoded);
    const colon = decoded.indexOf(':');
    return colon < 0 ? null : decoded.slice(colon + 1);
  } catch {
    return null;                       // not base64 — treat as no credential
  }
}

/// Compared as digests so the two are always the same length, which is what
/// timingSafeEqual requires, and so a wrong guess cannot be narrowed down by
/// how long the comparison took.
async function sameSecret(a, b) {
  const [x, y] = await Promise.all([sha256(a), sha256(b)]);
  return crypto.subtle.timingSafeEqual(x, y);
}

async function sha256(s) {
  return new Uint8Array(
    await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s)));
}

function challenge() {
  return new Response('Password required.\n', {
    status: 401,
    headers: {
      'WWW-Authenticate': `Basic realm="${REALM}", charset="UTF-8"`,
      'Content-Type': 'text/plain; charset=utf-8',
      'Cache-Control': 'no-store',
    },
  });
}

function unconfigured() {
  return new Response(
    'This site has no password set, so it is not serving anything.\n\n' +
    'Add a repository secret named SITE_PASSWORD in GitHub\n' +
    '(Settings -> Secrets and variables -> Actions), then re-run the\n' +
    '"fetch" workflow. The deploy pushes it to Cloudflare for you.\n',
    {
      status: 503,
      headers: {
        'Content-Type': 'text/plain; charset=utf-8',
        'Cache-Control': 'no-store',
      },
    });
}
