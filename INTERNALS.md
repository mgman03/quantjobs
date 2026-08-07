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

**`uber`**, **`wolverine`**, **`twosigma`** and **`hrt`** are one-firm sources with
nothing to configure.

**`sitemap`** is the odd one. Hudson River Trading's public Greenhouse board
(`hrttalentcommunity`) holds three generic entries — "HRT Talent Community", "Campus
Talent Community" and one real posting — while the firm has ~70 roles open. The real
ones are a WordPress custom post type that isn't exposed through the REST API and
isn't listed on the careers page, but every one of them appears in
`/hrt_jobs-sitemap.xml`, and each page carries its title in `<title>` and its offices
in a `summary-info` div. Marshall Wace is the same shape — one Recruitment Assistant
on Greenhouse, five internships as pages under `/internships/` — so the adapter takes
`host`, `sitemap`, a `path` marker, and `title_loc` for sites like MW that write
"London Technology Internship" and state the office nowhere else. That last one
matches against the gazetteer rather than trusting `parse`, which accepts any
unrecognised words as a city and will happily call "London Technology Internship" a
place. That's one request per role, so it's rate-limited and
reports failure if it can't read most of them — a board quietly returning 60 of 72
roles is worse than one that says it failed. The sitemap's `<lastmod>` is ignored on
purpose: every entry shares a timestamp, so it records when the sitemap was
regenerated, and using it would date every HRT role today.

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
./.build/debug/QuantJobs --check --update                  # version compare + ask GitHub
./.build/debug/QuantJobs --check --update --install        # ...and do a real install
./.build/debug/QuantJobs --check --migrate                 # tracked keys survive the key change
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

## The updater

`Updater.swift` asks `api.github.com/repos/<repo>/releases/latest`, compares the tag
against the running bundle's `CFBundleShortVersionString`, and if it's newer offers to
download the attached `.dmg`, mount it, and swap the bundle.

Not Sparkle, deliberately: Sparkle is right when you're notarised and shipping to
strangers, but here it adds a package dependency and an EdDSA key to a project with
neither, and it wouldn't remove the Gatekeeper prompt — only an Apple developer
account does that.

Things that are load-bearing:

- **`VERSION` at the repo root is the single source of truth.** `make-app.sh` reads
  it into the Info.plist. Before that existed the bundle said `1.0` while the tag said
  `v1.0.1`, so nothing could compare correctly. Bump it in the same commit as the tag.
- **The comparison is numeric, not lexical.** `1.0.10` is newer than `1.0.9`, which a
  string compare gets backwards. `--check --update` covers that case and seven others.
- **A `swift run` binary refuses to install**, since it isn't a bundle and can't
  replace itself. It says to pull instead.
- **The image is checked before the swap**: it must carry `local.quantjobs.app` as its
  bundle identifier, and must not be older than what's installed. It is *not* required
  to match the tag exactly — a tag is typed by a human and a plist is written by the
  build, so they drift harmlessly.
- **The swap is done by a detached shell script**, because a bundle can't be replaced
  underneath the process running out of it. The script waits for the pid to go away,
  moves the new copy in, and relaunches.
- **A firm you deleted stays deleted.** The stamp records the names the last
  bundle held, so the merge can tell "removed on purpose" from "never seen". With
  no previous stamp it can't, so the *first* merge only updates firms already
  present — an install gains the firms added in the version it's upgrading to on
  the following update, which beats wiping a roster someone curated by hand.
- **No quarantine.** A disk image fetched with URLSession isn't quarantined — that
  attribute is applied by browsers, not by the network — so the replacement launches
  without the "Apple could not verify" dialog.

`--check --update` runs the comparison table and the live GitHub query;
`--check --update --install` additionally runs the real download, mount, verify and
swap against a throwaway copy of the app.

## Auditing for the wrong board

Three firms turned out to be pointed at a board that exists but isn't the one with
the roles: HRT at a talent-community placeholder, Marshall Wace at a single
Recruitment Assistant posting, Jane Street at an experienced-hires-only board with
177 roles and no internships. None of them failed — they answered, plausibly, with
the wrong thing.

The signal that finds it: **a board returning plenty of roles and zero early-career
ones.** Scrape everything at `-c all -l any`, group by firm, and flag any with 10+
roles where nothing matches intern / new grad / campus / co-op / graduate.

Run against all 150 boards that return anything, that flags 61. Most are genuinely
empty — it's August, and Summer 2027 postings largely open between then and October.
Datadog's 441-role board really does have no internships on it. So the flag is a
prompt to look, not a verdict.

What to look for once flagged, in order of how often it pays off:

- **A second board on the same platform.** Arrowstreet splits its Workday tenant:
  the site we had was experienced hires, `Campus_Careers` held the internships. Radix
  and Walleye do the same. Millennium was the worst case — its Eightfold board carries
  244 roles and not one is early-career, while 56 2027 internships sit on
  `campusjobs.mlp.com`, the same tenant behind a different host.
- **A separate students page on their own site**, which is how Arrowstreet's split
  surfaced — `/student-careers/` linked to a Workday host the professional page never
  mentions.
- **A JSON feed the careers page fetches**, which is where Jane Street's are.

Two of those are cheap to sweep for rather than eyeball, and worth re-running when the
roster grows:

- For every Workday tenant, POST to `wday/cxs/<tenant>/<site>/jobs` with `site` set to
  `Campus`, `Campus_Careers`, `University`, `Students`, `Early_Careers` and friends, and
  keep any that reports a non-zero `total`. Across 21 tenants that found Arrowstreet
  (already paired) and **Mastercard**, whose `Campus` site holds 24 early-career roles
  its `CorporateCareers` site doesn't list.
- For every Greenhouse token, try `<token>campus`, `<token>university`,
  `<token>students`, `<token>internships`, `<token>grad` and the like. Across 94 tokens
  that found nothing — so it's a cheap negative, not a dead end.

**The sweep only covers firms that already have a token.** Four entries were sitting in
the file with an empty token and a note saying no board could be found, which excluded
them from every probe above — and two of them did have one. **Chicago Trading Co** has
*two* Greenhouse boards, `chicagotrading` for experienced hires and `ctccampusboard`
for the 2027 SWE and quant internships, neither linked from a careers page that renders
its listings client-side. **PEAK6**'s `careers.peak6.com` is a custom front end over
`peak6group.wd1.myworkdayjobs.com`. A web search for `"<firm> internship apply"` found
both in one step, which no amount of fingerprinting the careers page would have. Re-run
that for any entry whose note says there's nothing to read.

### The category can hide a role as thoroughly as a missing board

Same method, one step further in: take the early-career postings, keep the ones a
category *rejects*, and grep those for words the category ought to have caught. For
`swe`, grepping the rejects for `engineer|developer|software|technolog` surfaced 416
titles. Most are correctly out — `hardware`, `fpga` and `mechanical` are excluded on
purpose and have their own category — but four gaps were real:

- The include list had `software engineer` and `software developer` but not bare
  `software`, so a comma-inverted title didn't match: SpaceX's
  *New Graduate Engineer, Software (Starlink)*, *Software/Firmware Engineering - Intern*,
  *Development Tools Software Intern*. 23 postings.
- `machine learning engineer`, `ml engineer` and `ai engineer` were only in `data`.
  Categories aren't exclusive — a posting can match several — so listing them under
  `swe` too costs nothing and recovers Millennium's *Applied AI Engineer Intern* and
  Jane Street's *Machine Learning Engineer*. 11 postings.
- `research engineer` was in no category at all, which dropped Jump's four
  *Campus AI Research Engineer* postings and Qube's
  *Quantitative Research Engineer – PhD Intern (Europe)*. 14 postings.

`engineering intern` / `engineer intern` were tried and rejected: they pull in
industrial, facilities and mechatronics roles that `swe` shouldn't claim.

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

**A word boundary is not a plural.** The level vocabulary matched `graduate` but not
*Graduates*, `internship` but not *Internships*, `early career` but not
*Early Careers* — the trailing `s` fell outside the boundary. Quadrature's board has a
posting titled exactly "Internships"; it read as senior. Both matchers now allow an
optional `s` after any phrase ending in a letter, which recovered 172 postings across
21 firms, including every SIG `Quantitative Researcher – Master's: 2027`, Point72's five
`Academy … for Upcoming Graduates (2027)`, IMC's `C++ Software Engineer, Early Careers`
and HRT's `Algorithm Developer … – 2027 PhDs`.

The same audit turned up vocabulary that no plural rule reaches: Nvidia, Micron,
Applied Materials, NXP and Astera Labs all hire a whole class as **New College Grad** or
**NCG**, which is 82 postings' worth of new-grad roles reading as senior, and Israeli
and German boards say intern with **Student**, **Working Student** or **Praktikant**.
The way to find these is to scrape at `-l any`, keep the rows the level test rejected,
and grep them for every early-career word you can think of — the ones that hit are your
gaps.

**A numeric id read as a string becomes an empty string, and empty strings collide.**
Wolverine serves `"ID": 336`; the app read it with `as? String ?? ""`, so every posting
got the URL `.../careers?job=` — and since a posting is identified by its URL, the whole
19-role board deduplicated down to a single row. It had been that way since the adapter
was written, and nothing failed: the board answered, the row was real, and the count was
plausible enough not to look at. `Clean.scalar` now coerces either shape, and it's used
everywhere a JSON value lands in a URL. If one implementation shows a board a tenth the
size of the other's, look for a field one of them is silently defaulting.

**One regex spanning two things swallows what's between them.** Two Sigma's cards
were matched with a single pattern running from the job anchor to the location span
via `.*?`, so one match could consume the anchors in between: 58 roles on the page
came back as 10, and the CLI silently under-reported the board for weeks. Both tools
now match the anchor, then look for the location in a bounded window after it.

**Regex backtracking differs.** A pattern with `.*?` that Python's `re` handles fine
can pin a core in `NSRegularExpression`, which backtracks where Python doesn't. One
Two Sigma pattern rescanned a 110 KB page per match and spun the app at 98% CPU; it's
now a bounded two-step parse.

**Citadel cross-lists with Citadel Securities.** They are separate firms sharing one
careers platform, and 22 of the 23 early-career roles they have in common sit at the
*same path* on both hosts — one job posted twice. `dedupKey` drops the host for those
two domains so the pair collapses, and the list is sorted by company first so the
survivor is always the same one rather than whichever board answered first. Keeping
only one entry would be wrong: 12 early-career roles exist only on citadel.com and 18
only on citadelsecurities.com. Tracking still uses `key`, so this changes nothing
about saved roles.

**A posting is identified by its URL.** It used to be company + title +
location, which cannot tell apart two postings a firm makes under one title in one
city — Jane Street's London "Software Engineer" exists as both a Summer Internship
and a Full-Time New Grad role. Keyed that way, deduplication collapsed the pair and
the new-grad row won, so the internship appeared while a scrape streamed in and
vanished when it finished; saving one also marked the other.

`legacyKey` keeps the old form for two reasons. Tracked entries store a full snapshot
of their posting, so `ConfigStore.loadTracked` recomputes the new key from that and
rewrites the file once — nobody loses saved or applied roles. And the seen list has no
snapshot to migrate from, so `isNew` checks both keys; without that, the first run
after the change would announce every posting as new. `--check --migrate` covers it.

**Tracked postings store a full copy.** `.tracked.json` keeps a snapshot of each saved
or applied posting, not just an id — a board deletes a posting the moment it closes,
and an application you're tracking shouldn't disappear with it. Only firms that
actually answered a scrape are judged, so a board being off or failing never marks its
roles dead.

**The three marks are three fields, not one.** They were one `status` enum, which meant
hiding a role you'd applied to *overwrote the application* — the single most valuable
thing in the file. They're independent now: `saved`, `hidden`, and `milestones`, a list
of dated `Stage` steps. An entry with none of them set is deleted rather than kept as a
husk, and the delisting pass only discards a vanished posting when hiding is all it
carries — a hidden application is exactly the history worth keeping.

Two things fall out of that split:

- **The current stage is derived, not stored.** It's the milestone with the latest date,
  with `Stage.order` breaking a tie — so a rejection recorded the same day as the
  interview it followed still reads as the outcome.
- **Upgrading has to be lossless.** A file written with one `status` is read by
  presence: no `saved` key means the old shape, and `status: applied` becomes an
  application dated when it was marked. `--check --migrate` writes the old format by
  hand and reads it back, because the current encoder can't produce it and the check
  would otherwise only compare today's format against itself.

Fixing this exposed a bug in `--check --model`, which had been giving two test postings
the same URL. The URL *is* the key, so they were one posting, and the check was quietly
asserting that the second mark overwrote the first — the behaviour being removed.
