# quantjobs

Scrapes internship / new-grad postings straight from firms' job-board APIs — 150 of
them, quant shops and big tech, with 110 switched on out of the box. Pick a category
(`swe`, `quant-trading`, `quant-research`, …), pick which firms to watch, get a table
or CSV.

Dead links are dropped before you ever see them — see [Do the links actually
work?](#do-the-links-actually-work).

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

`intern-or-newgrad` and `any` are not the same thing, and the difference bites:
`intern-or-newgrad` means *early career only* — a posting has to read as an
internship **or** a new-grad role. `any` switches the level test off altogether, so
senior and experienced postings come too. Jane Street's SWE board is the clean
example: `intern`, `newgrad` and `intern-or-newgrad` all return 0 right now, while
`any` returns 26 — every one of them experienced. In the Mac app these are the
**Both** and **All levels** segments, and hovering either says which is which.

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
`optiver`, `twosigma`, `simplify`.

The last four came from firms with no ATS at all. `eightfold` (Netflix) and `jibe`
(SIG, AMD) are hosted platforms taking `host` — and `tenant` for Eightfold — so they
work for any firm on them. `uber` and `wolverine` are one-firm APIs with nothing to
configure. `simplify` reads the community internship feed for firms with no board of
their own, matching on `query` (the exact company name) and taking an optional `host`
to point at a different season's file. `citadel` (Citadel and Citadel Securities) is
one of two adapters that read HTML rather than JSON — `optiver` is the other — their careers site is server-rendered WordPress with the REST
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
split the roster into the two groups the app's Firms picker is built around.

`tier` ranks the firm: **1** is the names people target first, **2** is strong,
**3** is everything else. Tiers 1 and 2 ship enabled and tier 3 ships off. It's a
judgement call rather than a fact, so edit it freely — it only controls what's
switched on by default.

`segment` is the sub-group the app's Firms picker lists down its left-hand side.
Quant firms use `Tier 1` / `Tier 2` / `Tier 3`; big tech uses `FAANG+` /
`Frontier AI` / `Startups`. `Startups` means private and still scaling — a public
company belongs in `FAANG+` however small it started.

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

**150 of the 154 entries have a working source**, and **110 ship enabled** —
`./quantjobs.py verify` returns *110 working, 0 broken* in about four and a half
minutes (last run 2026-08-03). The roster splits into the two groups the app's Firms
picker is built around:

| group | segment | firms | on by default |
|---|---|--:|--:|
| Quant | Tier 1 | 19 | 19 |
| Quant | Tier 2 | 30 | 26 |
| Quant | Tier 3 | 8 | 0 |
| Big Tech | FAANG+ | 66 | 55 |
| Big Tech | Frontier AI | 18 | 8 |
| Big Tech | Startups | 13 | 2 |

**Tier 1** — the quant firms people target first, all 19 live:

AQR Capital · Citadel · Citadel Securities · DRW · Hudson River Trading ·
IMC Trading · Jane Street · Jump Trading · Millennium · Optiver · Point72 ·
Qube RT · Radix Trading · SIG · Squarepoint Capital · Tower Research ·
Two Sigma · Virtu Financial · XTX Markets

**Frontier AI** — Anduril · Anthropic · Aurora · Cohere · Databricks · Decagon ·
ElevenLabs · Harvey · LangChain · Mercor · Modal · Nuro · OpenAI · Perplexity ·
Physical Intelligence · Replit · Scale AI · Waymo

For the rest, ask the tool rather than trusting a list in a README that drifts:

```bash
./quantjobs.py companies        # every firm, its board, and whether it's on
./quantjobs.py verify           # prove the enabled ones still resolve
./quantjobs.py verify --all     # including the ones that ship off
```

Boards are spread across 13 platforms — Greenhouse (97), Workday (20), Ashby (16),
Simplify (4), Citadel and Eightfold and Jibe and Lever (2 each), and one apiece for
amazon.jobs, Optiver, Two Sigma, Uber and Wolverine.

### The four firms with no board at all

Only **Chicago Trading Co, Maven Securities, PEAK6 and Quantlab** have no source.
Each sits in `companies.json` as a disabled placeholder carrying a `note` saying what
was tried, so you can see they were considered rather than missed — all four render
their boards client-side with no ATS fingerprint in the HTML (rechecked 2026-08-03).

### Apple, Google, Meta and Microsoft

These four publish nothing a script can read: their own endpoints need a browser
session, and no ATS sits in front of them. They come from the [Simplify / Pitt CSC
community internship feed][simplify] instead, which links to each firm's own
application page. It's second-hand and internships-only, so treat it as a lead rather
than the firm's board.

[simplify]: https://github.com/SimplifyJobs/Summer2027-Internships

Rechecked on 2026-08-03 by pulling the feed and running every link through the
verifier:

| firm | listings | links | ships |
|---|--:|---|---|
| Apple | 12 | 11 resolve 200, 1 dead and dropped | **on** |
| Microsoft | 4 | 3 resolve 200, 1 dead and dropped | **on** |
| Meta | 5 | metacareers.com returns 400 to scripts — unconfirmable | off |
| Google | 3 | all three resolved dead | off |

Meta and Google ship **off** because nothing about them can be confirmed today. Flip
`enabled` if you want the leads anyway; Meta's arrive flagged as unverified in the
detail panel. Each firm's entry records its own verdict, so the caveat travels with
the data rather than living only here.

Caveat on HRT: its public Greenhouse board is a small talent-community board, so most
HRT roles won't appear.

## Do the links actually work?

A job board that sends you to dead postings is worse than no job board, and
second-hand feeds go stale fastest. So every posting's URL is checked before it
reaches you — a `HEAD` (falling back to `GET`) against the real link, run in parallel
at the end of a scrape:

| result | meaning | what happens |
|---|---|---|
| **ok** | under 400 | kept |
| **dead** | 404 or 410 — the posting is gone | **dropped, you never see it** |
| **blocked** | 403, 400, timeout, DNS — inconclusive | kept, flagged |

The three-way split matters. A firm that blocks scripted callers (Meta returns 400 to
anything without a browser session) is not the same as a posting that has closed, and
collapsing the two would either flood the table with dead links or silently delete
every role at the strictest firms. Anything inconclusive is kept and the detail panel
says so — *"Link not confirmed — this firm blocks automated checks"* — rather than
quietly vanishing.

This is why Google ships off: its Simplify entries look fine until you follow them,
and all three resolved dead on the last check.

Both implementations do this; it's `check_link` / `verify_links` in `quantjobs.py`
and `Adapters.checkLink` / `verifyLinks` in the app.

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

- Categories and the Saved / Applied / Hidden lists live in the sidebar. Everything
  that narrows the results sits in one row above the table: level, location, firms,
  date.
- Every active filter shows as a **removable chip** under that row — tag, continent,
  city, date window, free-text search, unseen-only, deep-match — so you can always see
  why the list is as short as it is, and clear any one of them with a click.
- A **detail panel** on the right for the selected role — team, board, tags, the full
  description when the board ships one, and a button straight to the posting.
- **Doesn't re-scrape on every launch.** A full pass is ~110 boards and tens of
  thousands of postings, so it only refreshes when the cached results are more than
  six hours old; otherwise the window opens instantly on what it already had and waits
  for ⌘R. A first run starts on the Quant half rather than all 110 boards.
- **The status bar carries a read-only "sources" panel** — which platforms the results
  came from, how many boards each, and anything that failed. Choosing *which* firms to
  scrape is the Firms picker above the table; adding or editing a board is
  Scrape ▸ Manage Boards.
- **The level switch sits above the table** next to the pickers, and changing it (or
  the category, or which firms are on) re-runs the scrape automatically after a short
  pause, so the list matches the controls without you pressing ⌘R. **Both** means
  early-career only; **All levels** switches the level test off entirely and lets
  senior roles through. Hovering either says so.
- **The detail panel appears when you select a role** and gets out of the way when you
  don't have one, instead of permanently taking a third of the window. It's driven by
  the selection alone — closing it deselects the row.
- **Picking cities overrides the continent.** Choosing Europe *and* London used to
  apply both as an AND, which read as two filters when it only ever meant London. Now
  a continent scopes which cities are on offer, and as soon as you pick one the cities
  do the filtering.
- **Three pickers sit together above the table** — location, firms, date — and all
  work the same way: click the group on the left to narrow the list on the right,
  tick either to select. The firm picker groups quant firms by **tier** and big tech
  by **FAANG+ / Frontier AI / Startups**, in that order, with the firms beside them
  listed A-Z across the whole selection. A part-selected group shows a half-filled
  box, a focused group is highlighted rather than bolded, and hovering says what a
  click will do.
- **Remembers how you left it.** Category, level, the All/Quant/Big Tech switch, every
  filter (continent, city, tag, location, date window), the toggles and which list you
  were on all come back on the next launch.
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
  panel. Roughly 126 postings collapse to 99 rows. Turn it off in Scrape ▸ Merge the
  same role across offices.
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
- **Scrape ▸ Manage Boards** edits `companies.json` — sorted by tier, with a tier
  filter and search.
  **Turn On** / **Turn Off** act on whatever is on screen (or on your selection, if you
  have one), so switching a slice of firms is one click rather than select-then-hunt.
  **Presets** replaces the lot: *Only Tier 1*, *Tier 1 + 2*, *Only Quant*, *Only Big
  Tech*, *Everything On*. Verify and Discover live here too.

The icon is generated, not checked in as a binary blob: `Icon/make-icon.swift` draws
every size natively with Core Graphics, and `make-app.sh` builds the `.icns` on first
run.

By default the app finds the config by walking up from the binary until it hits a
`companies.json` — so a `swift run` in the checkout, or a `.app` built into it, shares
one folder with the CLI and nothing is hardcoded. The CLI reads the config sitting
beside `quantjobs.py` for the same reason.

**`$QUANTJOBS_CONFIG` overrides both**, so pointing one tool somewhere else points the
other:

```bash
export QUANTJOBS_CONFIG=/path/to/checkout                    # both tools, per-run
defaults write QuantJobs configDirectory /path/to/checkout   # the app, persistently
```

A `.app` installed outside the checkout (which is what `make-app.sh` does by default)
can't walk up to one, so point it with one of the above or let it fall back to
`~/Library/Application Support/QuantJobs`, which it seeds from the copy inside the
bundle. `make-app.sh` refreshes that bundled copy from the repo before it builds, so a
fresh install starts on the same defaults the checkout has.

**First launch:** if the config lives somewhere macOS guards — `~/Desktop`,
`~/Documents`, `~/Downloads` — you'll be asked whether QuantJobs may read the folder.
Click Allow, or the board list stays empty. The window comes up either way: the config
is read on a background task precisely so a pending permission prompt can't leave you
staring at a process with no UI. (Re-running `make-app.sh` re-signs the bundle
ad-hoc, which makes macOS ask again.)

### Keeping the two honest

The app binary has a headless mode that prints the same table the CLI does, so a
port change can be diffed against the Python original:

```bash
./.build/debug/QuantJobs --check -c swe -l intern          # same table as ./quantjobs.py
./.build/debug/QuantJobs --check -c swe -l intern --json   # pipe-separated, for diffing
./.build/debug/QuantJobs --check --model                   # drive the real app model
./.build/debug/QuantJobs --check --render /tmp             # snapshot the detail panel
./.build/debug/QuantJobs --check --track                  # saved / applied / hidden
./.build/debug/QuantJobs --check --settings               # settings survive a restart
./.build/debug/QuantJobs --check --parse < locs.txt       # diff the location parser
./.build/debug/QuantJobs --scrape-on-launch               # scrape immediately (screenshots)
```

Anything under `--check` that writes runs against a throwaway config directory, so a
check can exercise the real save paths without touching `companies.json` or
`.tracked.json`.

Both implementations currently return identical results across `swe`,
`quant-trading`, `quant-research`, `quant-dev`, `hardware`, `data` and `all`,
at every level, with and without `--deep`.

The one place they deliberately differ is Workday paging: the app fetches a board's
pages concurrently once the first response reveals the total, where the CLI walks them
in order. The set of roles is the same either way. Both cap how many Workday requests
are in flight at once — see the note on Workday below.

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
- **Workday is rate-limited on purpose.** Every tenant sits behind one front end, a
  board is dozens of round trips because pages cap at 20 rows, and there are 20
  Workday boards in the roster. Unthrottled, a full run put enough load on it that
  seven boards came back as failures — all of which answered fine on their own. Both
  tools now cap how many Workday requests are in flight at once (2 in the CLI, 6 in
  the app, which fetches a board's pages concurrently). If you see a cluster of
  same-platform failures that pass when retried alone, this is the shape of it.
- Nothing is authenticated and nothing is logged in — these are the same public
  endpoints the firms' own careers pages call.
- `tools-build-locations.py` regenerates `locations.json` from scratch. You only need
  it if you're extending the gazetteer.
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
