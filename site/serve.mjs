// Runs the real _worker.js on localhost, with the KV namespace held in memory.
//
//   node site/serve.mjs [port]        # default 8791, password "hunter2"
//
// For trying the gate and the sync without deploying, and for the two tests
// beside this file to point at. It is the same worker the deploy uploads: a
// local stand-in for the worker would only prove the stand-in works.
import http from 'node:http';
import { timingSafeEqual } from 'node:crypto';

// Workers keep timingSafeEqual on crypto.subtle; Node keeps it on the crypto
// module. The only shim — everything else is the real thing.
if (!globalThis.crypto.subtle.timingSafeEqual) {
  globalThis.crypto.subtle.timingSafeEqual = (a, b) =>
    a.byteLength === b.byteLength && timingSafeEqual(Buffer.from(a), Buffer.from(b));
}

const { default: worker } = await import('./_worker.js');
const port = Number(process.argv[2]) || 8791;
const password = process.env.SITE_PASSWORD || 'hunter2';
const page = process.argv[3] || null;

let kv = null;
const env = {
  SITE_PASSWORD: password,
  STATE: { get: async () => kv, put: async (_k, v) => { kv = v; } },
  ASSETS: {
    fetch: async () => page
      ? new Response(await import('node:fs/promises').then(fs => fs.readFile(page)),
                     { headers: { 'Content-Type': 'text/html; charset=utf-8' } })
      : new Response('no page given; pass one as the second argument\n',
                     { headers: { 'Content-Type': 'text/plain' } }),
  },
};

http.createServer(async (req, res) => {
  const chunks = [];
  for await (const c of req) chunks.push(c);
  const r = await worker.fetch(new Request('http://127.0.0.1' + req.url, {
    method: req.method,
    headers: req.headers,
    body: chunks.length ? Buffer.concat(chunks) : undefined,
  }), env);
  res.writeHead(r.status, Object.fromEntries(r.headers));
  res.end(Buffer.from(await r.arrayBuffer()));
}).listen(port, '127.0.0.1', () => {
  console.error(`worker on http://127.0.0.1:${port}  password ${password}`);
});
