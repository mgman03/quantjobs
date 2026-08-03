# Internals

Notes for extending this — board adapters and their config fields, how the CLI and
the Mac app are kept in step, and the failure modes worth knowing about. For using
the tool, see [README.md](README.md).

## Board adapters

Each adapter takes a company entry and returns raw postings. Most take a `token`
lifted from the firm's careers URL:

```json
{ "name": "Jump Trading", "ats": "greenhouse", "token": "jumptrading", "enabled": true }
```

`greenhouse`, `lever`, `ashby` and `smartrecruiters` all work that way. The rest need
something else:

**`workday`** — `host` / `tenant` / `site` instead of a token:

```json
{ "name": "Some Firm", "ats": "workday", "host": "somefirm.wd1.myworkdayjobs.com",
  "tenant": "somefirm", "site": "External", "enabled": true }
```

It also accepts `query`, which becomes the board's search box. That matters: Workday
serves 20 rows a page, so an unfiltered board is dozens of round trips.

**`eightfold`** (Netflix) and **`jibe`** (SIG, AMD) are hosted platforms addressed by
`host` — plus `tenant` for Eightfold — so they work for any firm on them.

**`amazon`** has no slug at all, since amazon.jobs is one search index. It takes an
optional `query`, defaulting to `intern`, because pulling all ~15k postings to filter
locally would be silly.

**`citadel`** (both Citadel entries) and **`optiver`** read HTML rather than JSON —
their careers sites are server-rendered with no public API. Citadel takes a `host`.

**`uber`**, **`wolverine`** and **`twosigma`** are one-firm APIs with nothing to
configure.

**`simplify`** reads the [Simplify / Pitt CSC community internship feed][simplify] for
firms with no board of their own, matching on `query` (the exact company name) and
taking an optional `host` to point at a different season's file.

[simplify]: https://github.com/SimplifyJobs/Summer2027-Internships

Adding a new ATS means writing one fetch function and registering it in `ADAPTERS`
(Python) and `Adapters` (Swift).

## Apple, Google, Meta and Microsoft

None of them publish anything a script can read: their own endpoints need a browser
session, their sitemaps return the single-page-app shell or 403, and no ATS sits in
front of them. They come from the Simplify feed instead, which links to each firm's
own application page — second-hand and internships-only, so a lead rather than the
firm's board.

Rechecked 2026-08-03 by pulling the feed and running every link through the verifier:

| firm | listings | links | ships |
|---|--:|---|---|
| Apple | 12 | 11 resolve 200, 1 dead and dropped | **on** |
| Microsoft | 4 | 3 resolve 200, 1 dead and dropped | **on** |
| Meta | 5 | metacareers.com returns 400 to scripts — unconfirmable | off |
| Google | 3 | all three resolved dead | off |

Meta and Google ship off because nothing about them can be confirmed. Flip `enabled`
if you want the leads anyway; Meta's arrive flagged as unverified. Each firm's entry
records its own verdict, so the caveat travels with the data.

Four firms have no source at all — Chicago Trading Co, Maven Securities, PEAK6 and
Quantlab. All four render their boards client-side with no ATS fingerprint in the HTML
(rechecked 2026-08-03). They stay in the file as disabled placeholders with a note, so
it's clear they were considered rather than missed.

Caveat on HRT: its public Greenhouse board is a small talent-community board, so most
HRT roles won't appear.

## How locations are read

Boards describe the same place a dozen ways — `US, CA, Santa Clara`,
`Santa Clara, California, United States`, `Austin, TX; New York`,
`New York, London, or Paris`. `locations.json` is a gazetteer (90 countries, ~500
cities, US states and Canadian provinces) that both tools load, so each posting
resolves to a list of `{city, region, country, continent}`.

Two rules are load-bearing and easy to get backwards:

- **Cities before regions**, because plenty of US state names are also city names
  (New York, Washington).
- **Regions before countries**, because two-letter state codes collide with country
  codes. `IL` is both Illinois and Israel, `CA` both California and Canada — checking
  countries first quietly filed every Chicago job under Asia.

`tools-build-locations.py` regenerates the gazetteer. You only need it if you're
extending it.

## Keeping the two implementations honest

The app binary has a headless mode that prints the same table the CLI does, so a port
change can be diffed against the Python original:

```bash
./.build/debug/QuantJobs --check -c swe -l intern          # same table as ./quantjobs.py
./.build/debug/QuantJobs --check -c swe -l intern --json   # pipe-separated, for diffing
./.build/debug/QuantJobs --check --model                   # drive the real app model
./.build/debug/QuantJobs --check --track                   # saved / applied / hidden
./.build/debug/QuantJobs --check --settings                # settings survive a restart
./.build/debug/QuantJobs --check --parse < locs.txt        # diff the location parser
./.build/debug/QuantJobs --check --render /tmp             # snapshot the detail panel
```

Anything under `--check` that writes runs against a throwaway config directory, so a
check can exercise the real save paths without touching `companies.json` or
`.tracked.json`. Both point at `$QUANTJOBS_CONFIG` if it's set, which is the easy way
to run both tools against a small scratch roster.

Both implementations return identical results across every category and level, with
and without `--deep`. The one deliberate difference is Workday paging: the app fetches
a board's pages concurrently once the first response reveals the total, where the CLI
walks them in order. The set of roles is the same either way.

`--check --render` writes PNGs of the detail panel. `TextField` and link-style buttons
are AppKit-backed and `ImageRenderer` can't rasterise them, so they come out as yellow
blocks — that's a snapshot artifact, not a UI bug.

## Failure modes worth knowing

**Boards drift.** Three adapters needed fixing once there were enough firms to notice:

- Ashby dropped `departmentName` / `publishedDate` from the GraphQL schema it was
  being asked for. It now uses the public posting API, which also ships descriptions
  inline.
- Workday reports its result count on the *first page only*. Trusting the zero on
  later pages silently truncated every Workday board to 40 rows.
- amazon.jobs needed an adapter of its own.

If a board starts returning suspiciously round numbers, that's the shape of the bug.

**Workday is rate-limited on purpose.** Every tenant sits behind the same front end, a
board is dozens of round trips, and there are 20 Workday boards in the roster.
Unthrottled, a full run put enough load on it that seven boards came back as failures
— all of which answered fine on their own. Both tools cap how many Workday requests
are in flight at once (6 in the CLI, 8 in the app). If you see a cluster of
same-platform failures that pass when retried alone, this is the shape of it.

**Cloudflare.** Citadel's two boards sit behind one tenant and throttle each other
into 403s if hit in parallel, so those requests are serialised and paced.

**Regex backtracking differs.** A pattern with `.*?` that Python's `re` handles fine
can pin a core in `NSRegularExpression`, which backtracks where Python doesn't. One
Two Sigma pattern rescanned a 110 KB page per match and spun the app at 98% CPU; it's
now a bounded two-step parse.

**Tracked postings store a full copy.** `.tracked.json` keeps a snapshot of each saved
or applied posting, not just an id — a board deletes a posting the moment it closes,
and an application you're tracking shouldn't disappear with it. Only firms that
actually answered a scrape are judged, so a board being off or failing never marks its
roles dead.
