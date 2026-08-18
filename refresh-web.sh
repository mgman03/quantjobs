#!/bin/bash
# Rebuild the phone snapshot from whatever the app last fetched.
#
#   ./refresh-web.sh              → web/index.html
#   ./refresh-web.sh --open       → and open it locally
#
# Deploying it is a separate step and deliberately not automated here: the page
# carries your application history, so where it goes is a decision, not a default.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p web
swift build -c release --package-path QuantJobsApp >/dev/null
BIN=$(swift build -c release --package-path QuantJobsApp --show-bin-path)
"$BIN/QuantJobs" --check --web web/index.html
[ "${1:-}" = "--open" ] && open web/index.html
