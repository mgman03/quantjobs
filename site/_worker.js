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

    const response = await env.ASSETS.fetch(request);
    // The response is per-viewer now, so nothing in between may keep a copy.
    const out = new Response(response.body, response);
    out.headers.set('Cache-Control', 'private, no-store');
    return out;
  },
};

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
