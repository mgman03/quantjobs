# quantjobs

Scrapes internship / new-grad postings straight from firms' job-board APIs — 108 of
them, quant shops and big tech. Pick a category (`swe`, `quant-trading`,
`quant-research`, …), pick which firms to watch, get a table or CSV.

No dependencies — Python 3.9+ standard library only.

```bash
./quantjobs.py scrape --category swe --level intern
```

```
COMPANY             TITLE                                        LOCATION              LEVEL  POSTED
────────────────────────────────────────────────────────────────────────────────────────────────────
Virtu Financial     2027 Internship - Frontend Engineer (UI)     New York              intern 2026-07-31
DRW                 Platform Engineer Intern                     Chicago               intern 2026-07-30
Jump Trading        Campus Software Engineer (Intern)            London                intern 2026-07-24
Akuna Capital       Software Engineer Intern - C++, Summer 2027  Chicago, IL           intern 2026-07-14
Old Mission Capital Software Engineer – 2027 Internship Program  Chicago, IL           intern 2026-07-15
...
```

There's also a native Mac app in `QuantJobsApp/` — see [The Mac app](#the-mac-app).

## Commands

| Command | What it does |
|---|---|
| `scrape` | Fetch and filter postings |
| `companies` | Show the configured firm list |
| `categories` | Show the configured categories |
| `verify` | Check every board still resolves (run after editing `companies.json`) |
| `discover <url>` | Sniff a careers page for its ATS token so you can add the firm |

## Scrape options

```
--category, -c   swe | quant-trading | quant-research | quant-dev | hardware | data | all
--level, -l      intern (default) | newgrad | intern-or-newgrad | any
--location, -L   substring match on location, repeatable:  -L london -L nyc
--company        limit to firms matching a name, repeatable
--tag            limit to firms with a tag (quant, bigtech, hft, london, …)
--continent      Europe | Asia | North America | …, repeatable
--city           match a parsed city name, repeatable:  --city london --city zurich
--since DAYS     only roles posted in the last N days
--new-only       only roles you haven't seen on a previous run
--deep           also match against full job descriptions (slower, wider net)
--format, -f     table (default) | csv | json | md
--out, -o        write to a file instead of stdout
```

Examples:

```bash
./quantjobs.py scrape -c quant-trading -l intern
./quantjobs.py scrape -c swe -L london -L amsterdam
./quantjobs.py scrape -c quant-research --since 7 -f md -o roles.md
./quantjobs.py scrape -c swe -l intern --tag bigtech     # FAANG+ only
./quantjobs.py scrape -c all --tag quant --new-only      # daily driver
```

## Editing the company list

`companies.json` is the whole config. Add, remove, or flip `enabled`:

```json
{ "name": "Jump Trading", "ats": "greenhouse", "token": "jumptrading",
  "enabled": true, "tags": ["hft", "prop"] }
```

Supported `ats` values: `greenhouse`, `lever`, `ashby`, `smartrecruiters`,
`workday`, `amazon`, `eightfold`, `jibe`, `uber`, `wolverine`, `citadel`,
`optiver`, `twosigma`.

The last four came from firms with no ATS at all. `eightfold` (Netflix) and `jibe`
(SIG, AMD) are hosted platforms taking `host` — and `tenant` for Eightfold — so they
work for any firm on them. `uber` and `wolverine` are one-firm APIs with nothing to
configure. `citadel` (Citadel and Citadel Securities) is the one adapter that reads
HTML rather than JSON — their careers site is server-rendered WordPress with the REST
API switched off, so there is no JSON to ask for. It takes a `host`.

Workday needs `host` / `tenant` / `site` instead of `token`:

```json
{ "name": "Some Firm", "ats": "workday",
  "host": "somefirm.wd1.myworkdayjobs.com", "tenant": "somefirm",
  "site": "External", "enabled": true }
```

`amazon` has no slug at all — amazon.jobs is one big search index — so it takes an
optional `query` instead (default `intern`). Workday accepts `query` too, where it
becomes the board's search box; that matters because Workday only serves 20 rows a
page, so an unfiltered board like Nvidia's is dozens of round trips.

```json
{ "name": "Amazon", "ats": "amazon", "query": "intern", "enabled": true }
```

Two tags are meaningful rather than merely descriptive: **`quant`** and **`bigtech`**
split the roster into the two groups the app's filter bar switches between.

`tier` ranks the firm: **1** is the names people target first, **2** is strong and
on by default, **3** is everything else and ships disabled. It's a judgement call
rather than a fact, so edit it freely — it only controls default ordering and what's
switched on.

Don't know a firm's token? Point `discover` at their careers page:

```bash
$ ./quantjobs.py discover https://www.headlandstech.com/careers/
  greenhouse       headlandstechnologiesllc
    → {"name": "…", "ats": "greenhouse", "token": "headlandstechnologiesllc", "enabled": true}
```

Then `./quantjobs.py verify` to confirm it works.

## How locations are read

Boards describe the same place a dozen ways — `US, CA, Santa Clara`,
`Santa Clara, California, United States`, `Austin, TX; New York`,
`New York, London, or Paris`. `locations.json` is a gazetteer (90 countries, ~500
cities, US states and Canadian provinces) that both tools load, so each posting
resolves to a list of `{city, region, country, continent}` and the table can show
`Santa Clara, CA` instead of the raw string.

That's what makes `--continent` and `--city` — and the app's continent → city
drill-down — possible. Of the 15,700 postings across the current roster, **93%**
resolve to a real place; most of the rest are boards saying `3 Locations` or `Hybrid`,
which name nowhere at all.

Two rules in there are load-bearing and easy to get backwards. Cities are matched
before regions, because plenty of US state names are also city names (New York,
Washington). Regions are matched before countries, because two-letter state codes
collide with country codes — `IL` is both Illinois and Israel, `CA` both California
and Canada — and checking countries first quietly filed every Chicago job under Asia.

## Editing the categories

`categories.json` holds `include` / `exclude` phrase lists per category. Matching is
case-insensitive with word boundaries, and spaces match hyphens and slashes too — so
`"co-op"` catches `Co-Op` and `"summer analyst"` catches `Summer-Analyst`. Adding a
category is just a new key in that file.

Exclusions are checked against the **title only**, so a C++ role whose description
happens to mention "sales" is still kept.

## Which firms are wired up

**108 boards are live and verified**, out of 154 in the file. The roster is
ranked into tiers, and tier 3 ships switched off — the default run is the names worth
opening first, not everything that happened to resolve.

**Tier 1 (31)** — the firms people target first:

Amazon · Anthropic · Apple · AQR Capital · Citadel · Citadel Securities ·
Databricks · DRW · Google · Hudson River Trading · IMC Trading · Jane Street ·
Jump Trading · Meta · Microsoft · Millennium · Netflix · Nvidia · OpenAI ·
Optiver · Palantir · Point72 · Qube RT · Radix Trading · SIG ·
Squarepoint Capital · Stripe · Tower Research · Two Sigma · Virtu Financial ·
XTX Markets

Only 4 are still unreachable: Apple, Google, Meta, Microsoft. Apple, Google, Meta and
Microsoft all need a browser session token; Two Sigma renders its listings client-side
with no endpoint in the page or its bundles.

**Tier 2 (81 live)** — strong, well-regarded, on by default:

Adobe · Affirm · Airbnb · Akuna Capital · AMD · Analog Devices · Anduril ·
Applied Materials · Aquatic Capital · Arrowstreet · Asana · Astera Labs ·
Autodesk · Belvedere Trading · Block · Brex · Capstone · Citi · Cloudflare ·
Cohere · Coinbase · Datadog · Discord · Dropbox · eBay · Elastic ·
Engineers Gate · Epic Games · ExodusPoint · Figma · Five Rings ·
Flow Traders · GitLab · GSA Capital · Headlands Tech · Instacart · Intel ·
KLA · Lyft · Man Group · Marshall Wace · Marvell · Mastercard · Micron ·
MongoDB · Morgan Stanley · Nasdaq · NXP · Okta · Old Mission Capital ·
PayPal · PDT Partners · Perplexity · Pinterest · Pure Storage ·
Quadrature Capital · Radix Trading (Experienced) · Ramp · Reddit ·
Riot Games · Robinhood · Roblox · Rubrik · Salesforce · Samsara · Scale AI ·
Schonfeld · SpaceX · TransMarket Group · Twilio · Uber · Vatic Labs · Voleon ·
Walleye Capital · Walleye Capital (Full-Time) · Waymo · Winton ·
Wolverine Trading · Workday · WorldQuant · Zoom

**Tier 3 (38, off by default)** — smaller shops and startups. Switch any of them
on from the Firms tree in the app's sidebar, or flip `enabled` in the file.


### What isn't wired up, and why

16 entries sit in `companies.json` as **disabled placeholders** with a `note`, so you
can see they were considered rather than missed.

Of the actual FAANG, only **Amazon** has an endpoint you can call without a browser
session. The rest were each tried and rejected for a specific reason recorded in the
file: Apple redirects scripted callers to an error page, Google's careers API 404s
without auth, Meta's GraphQL needs an `fb_dtsg` session token, Microsoft's service
refused the connection, and Netflix has moved to Eightfold (which would need its own
adapter).

On the quant side, Citadel Securities, Two Sigma, SIG, Quantlab, Radix, Maven,
Wolverine, PEAK6 and CTC still run client-rendered sites with no public JSON board.
Optiver and Walleye are a different case — their Greenhouse boards *resolve* but serve
zero postings, so they're off rather than broken.

Caveat on HRT: its public Greenhouse board is a small talent-community board, so most
HRT roles won't appear.

## The Mac app

`QuantJobsApp/` is a SwiftUI app covering the same ground as `scrape`, `companies`,
`verify` and `discover`, reading and writing the **same** `companies.json`,
`categories.json` and `.seen.json` in this folder — so the two tools stay in sync and
you can use whichever suits the moment.

```bash
cd QuantJobsApp
./make-dmg.sh          # → QuantJobs.dmg, drag-to-Applications installer
./make-app.sh          # → installs straight to /Applications and reveals it
swift run QuantJobs    # or just run it from the checkout
```

`make-app.sh` installs to `/Applications` (falling back to `~/Applications` if that
isn't writable), registers the bundle with Launch Services so Spotlight and Finder pick
it up, and opens a Finder window with it selected. `make-dmg.sh` produces the disk
image you'd hand to someone else.

Because the app is signed ad-hoc rather than notarised, the first launch needs
**right-click → Open** once; double-clicking gets blocked by Gatekeeper. The DMG says
so in a read-me alongside the app.

- Categories in the sidebar; an **All / Quant / Big Tech** switch above the results
  that narrows both what's on screen and which boards the next scrape hits.
- Every other active filter shows as a **removable chip** next to it, so you can always
  see why the list is as short as it is.
- A **detail panel** on the right for the selected role — team, board, tags, the full
  description when the board ships one, and a button straight to the posting.
- **Doesn't re-scrape on every launch.** A full pass is ~107 boards and tens of
  thousands of postings, so it only refreshes when the cached results are more than
  six hours old; otherwise the window opens instantly on what it already had and waits
  for ⌘R. A first run starts on the Quant half rather than all 107 boards.
- **The status bar carries a read-only "sources" panel** — which platforms the results
  came from, how many boards each, and anything that failed. Choosing *which* firms to
  scrape is the Firms tree in the sidebar; adding or editing a board is Scrape ▸ Manage
  Boards.
- **Level and firm-group switches sit together above the table**, and changing either
  (or the category) re-runs the scrape automatically after a short pause, so the list
  matches the controls without you pressing ⌘R.
- **The detail panel appears when you select a role** and gets out of the way when you
  don't have one, instead of permanently taking a third of the window. It's driven by
  the selection alone — closing it deselects the row.
- **Picking cities overrides the continent.** Choosing Europe *and* London used to
  apply both as an AND, which read as two filters when it only ever meant London. Now
  a continent scopes which cities are on offer, and as soon as you pick one the cities
  do the filtering.
- **The firm tree checkbox is tri-state**: a filled tick when every board in a branch
  is on, a dash when only some are, an empty box when none. Hovering says what a click
  will do, since clicking a part-selected branch turns the whole thing on.
- **Remembers how you left it.** Category, level, the All/Quant/Big Tech switch, every
  filter (continent, city, tag, location, date window), the toggles, which list you
  were on and whether the detail panel was open all come back on the next launch.
  Cached results are only restored when they match the query you're returning to, so
  the table is never labelled one thing while showing another.
- **Opens populated.** The last run is cached, so the window comes up with results
  already in it and refreshes behind them — the table never blinks to empty, and if
  every board fails you keep what you had.
- **Titles are tidied for scanning.** Boards front-load the year and the word
  "Internship", so `2026 - Internship, Quantitative Developer` becomes
  **Quantitative Developer** in the table — the full posted title is in the detail
  panel and on hover. The CLI table does the same.
- **The same role across offices folds into one row.** Firms post one job per city, so
  `Campus Software Engineer` appeared five times differing only by location; now it's
  one row reading `London, GB +4`, with a separate link per posting in the detail
  panel. Roughly 126 postings collapse to 99 rows. Turn it off in Filters.
- **Save / Applied / Hidden** as three buttons on every row (plus right-click and the
  detail panel). Hidden roles drop out of the results with a `N hidden roles — Show Hidden`
  strip at the top so they're never silently missing; Saved and Applied get their own
  lists in the sidebar, and Applied carries the date you applied plus a notes field.
- **Every refresh re-checks what you saved.** A saved or applied role the board has
  dropped is struck through and greyed rather than deleted — you still need it, the
  posting just closed. A *hidden* role that's gone is deleted outright, since there's
  nothing left to hide. Only firms that actually answered are judged, so a board being
  off or failing never marks its roles dead.
- **"Not Interested in <firm>"** in the right-click menu switches that board off and
  clears its rows immediately, for when a listing tells you the firm isn't for you.
- Rows stream in as each board answers; a board that fails shows up in the status bar
  instead of taking the run down.
- Unseen roles get a dot, driven by the same `.seen.json` as `--new-only`.
- ⌘R scrapes, double-click opens a posting, and the results export to CSV / JSON / MD.
- **Boards** manages `companies.json` — sorted by tier, with a tier filter and search.
  **Turn On** / **Turn Off** act on whatever is on screen (or on your selection, if you
  have one), so switching a slice of firms is one click rather than select-then-hunt.
  **Presets** replaces the lot: *Only Tier 1*, *Tier 1 + 2*, *Only Quant*, *Only Big
  Tech*, *Everything On*. Verify and Discover live here too.

The icon is generated, not checked in as a binary blob: `Icon/make-icon.swift` draws
every size natively with Core Graphics, and `make-app.sh` builds the `.icns` on first
run.

By default it finds the config by walking up from the binary until it hits a
`companies.json` — so a `swift run` in the checkout, or a `.app` built into it, shares
one folder with the CLI and nothing is hardcoded. Override it with either:

```bash
export QUANTJOBS_CONFIG=/path/to/checkout          # per-run
defaults write QuantJobs configDirectory /path/to/checkout   # persistent
```

A `.app` installed outside the checkout (which is what `make-app.sh` does by default)
won't find it that way, so point it with one of the above or let it fall back to
`~/Library/Application Support/QuantJobs`, which it seeds from its bundled copy.

**First launch:** because that config lives under `~/Desktop`, macOS will ask whether
QuantJobs may read the folder. Click Allow, or the board list stays empty. The window
comes up either way — the config is read on a background task precisely so a pending
permission prompt can't leave you staring at a process with no UI. (Re-running
`make-app.sh` re-signs the bundle ad-hoc, which can make macOS ask again.)

### Keeping the two honest

The app binary has a headless mode that prints the same table the CLI does, so a
port change can be diffed against the Python original:

```bash
./.build/debug/QuantJobs --check -c swe -l intern          # same table as ./quantjobs.py
./.build/debug/QuantJobs --check -c swe -l intern --json   # pipe-separated, for diffing
./.build/debug/QuantJobs --check --model                   # drive the real app model
./.build/debug/QuantJobs --check --render /tmp             # snapshot the detail panel
./.build/debug/QuantJobs --check --track                  # saved / applied / hidden
./.build/debug/QuantJobs --check --parse < locs.txt       # diff the location parser
./.build/debug/QuantJobs --scrape-on-launch               # scrape immediately (screenshots)
```

Anything under `--check` that writes runs against a throwaway config directory, so a
check can exercise the real save paths without touching `companies.json` or
`.tracked.json`.

Both implementations currently return identical results across `swe`,
`quant-trading`, `quant-research`, `quant-dev`, `hardware`, `data` and `all`,
at every level, with and without `--deep`.

The one place they deliberately differ is Workday paging: the app fetches the pages
concurrently once the first response reveals the total, which takes a full 65-board
scrape from ~45s to ~11s. The set of roles is the same either way.

### Tracking applications

`.tracked.json` holds everything you've saved, applied to, or hidden — and it stores a
**full copy of each posting**, not just an id. That's deliberate: a board deletes a
posting the moment it closes, and an application you're tracking shouldn't disappear
with it. Saved and Applied lists are built from those snapshots, so they survive a
firm pulling the listing, a token breaking, or the board being turned off entirely.
Each entry also records when you marked it and when a scrape last saw it still listed,
so a role that quietly closed is visible rather than merely absent.

The CLI reads the same file:

```bash
./quantjobs.py scrape -c swe --skip-hidden      # respect what you hid in the app
./quantjobs.py scrape -c all --saved-only       # just your saved roles
```

## Notes

- `.seen.json` tracks postings you've already been shown, which is what powers
  `--new-only`. Delete it to reset; pass `--no-state` to leave it untouched.
- Boards are fetched in parallel (`--workers`, default 8) with retries on timeouts.
  A firm that fails is reported at the end and never kills the run.
- Nothing is authenticated and nothing is logged in — these are the same public
  endpoints the firms' own careers pages call.
- Boards drift. Three adapters needed fixing once there were enough firms to notice:
  Ashby had dropped `departmentName` / `publishedDate` from the GraphQL schema it was
  being asked for (it now uses the public posting API, which also ships descriptions
  inline); Workday reports its result count on the *first page only*, and trusting the
  zero on later pages silently truncated every Workday board to 40 rows; and
  amazon.jobs needed an adapter of its own. If a board starts returning suspiciously
  round numbers, that's the shape of the bug to look for.

### Run it daily

```bash
cd /path/to/quantjobs && ./quantjobs.py scrape -c swe --new-only -f md -o new.md
```

Empty output means nothing new since last run.

## Author

Mykhaylo Gershman — <mgershman@ethz.ch>

MIT licensed; see [LICENSE](LICENSE).
