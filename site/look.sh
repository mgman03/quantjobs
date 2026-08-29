#!/usr/bin/env bash
# Build the page, run it under the real worker, and photograph it.
#
#   site/look.sh [outdir]        # default: /tmp/quantjobs-look
#
# The jsdom checks beside this file verify structure. They cannot see layout,
# so they once passed on an Applied tab whose headings were stacked at the top
# with no styling at all. This renders the same page in Chrome and writes PNGs,
# which is the only check that would have caught it.
#
# The marks come from your own .tracked.json, baked in at build time — so the
# output is your real application history. Fine to look at, never to commit or
# publish. The README screenshots are captured from a scratch config instead.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-/tmp/quantjobs-look}"
PORT=8791
mkdir -p "$OUT"

# The freshly built binary first: the point of looking is to see the change you
# just made, not whatever is installed in /Applications.
BIN=QuantJobsApp/.build/release/QuantJobs
[ -x "$BIN" ] || BIN=$(command -v quantjobs || true)
[ -n "$BIN" ] || { echo "no binary; swift build --package-path QuantJobsApp -c release" >&2; exit 1; }

echo "building the page with $BIN ..."
"$BIN" --check --web "$OUT/page.html" >/dev/null

cleanup() { [ -n "${SRV:-}" ] && kill "$SRV" 2>/dev/null || true; }
trap cleanup EXIT
node site/serve.mjs "$PORT" "$OUT/page.html" 2>/dev/null &
SRV=$!
for _ in $(seq 40); do
  curl -sf -u q:hunter2 "http://127.0.0.1:$PORT/" -o /dev/null && break
  sleep 0.25
done

AUTH="q:hunter2"
URL="http://127.0.0.1:$PORT/"
TAB="[...document.querySelectorAll('[role=tab]')].find(b=>b.dataset.list==='%s').dispatchEvent(new MouseEvent('click',{bubbles:true}))"

shoot() { # name, width, extra-eval
  local name=$1 w=$2 ev=$3
  node site/shot.mjs "$URL" "$OUT/$name.png" --auth "$AUTH" \
    --width "$w" --height 844 --dsr 2 --wait "#list li" --eval "$ev" --settle 900
}

shoot phone-all     390 "void 0"
shoot phone-applied 390 "$(printf "$TAB" applied)"
shoot wide-all     1280 "void 0"
shoot wide-applied 1280 "$(printf "$TAB" applied)"

echo
echo "wrote:"; ls -1 "$OUT"/*.png
