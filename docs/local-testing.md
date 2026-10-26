# Local testing and audits

Keep generated scrape results, title dumps, benchmark data, copied configs, and review worktrees outside tracked source. Use `.local-audit/` in this checkout (ignored by Git) or a temporary directory outside the repository. Do not add generated TSV, JSON, logs, app bundles, or copied private state to commits.

The Swift regression and benchmark **source** in `QuantJobsApp/Tests/` is versioned because it checks behavior for everyone. A benchmark's input cache and output belong in `.local-audit/`. For example:

```sh
mkdir -p .local-audit/benchmark-config
cp companies.json categories.json locations.json .cache.json .local-audit/benchmark-config/
QUANTJOBS_BENCH_DIR="$PWD/.local-audit/benchmark-config" swift test --package-path QuantJobsApp -c release --filter SearchBenchmark
```

To time cache loading without changing app state, build the app target and run
`QuantJobs --check --profile-cache` with `QUANTJOBS_CONFIG` set to a copied config
folder. The command reports the number of cached postings and elapsed load time.

Before committing, run `git status --short` and `git diff --cached --stat` to confirm that only source, tests, and intentionally written documentation are staged.
