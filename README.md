# quantjobs

Finds internship and new-grad postings by reading firms' job boards directly — 150 of
them, quant shops and big tech. A command-line tool and a native Mac app, sharing one
config.

Dead links are dropped before you see them. No dependencies: Python 3.9+ standard
library only.

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

## Install

**Mac app:** [download QuantJobs.dmg][dmg] (macOS 14+) and drag it onto Applications.
Nothing else to download — the app carries its own copy of the firm list.

The first launch takes one extra step, because this app isn't notarised (that needs a
paid Apple developer account). macOS will refuse to open it and offer only *Move to
Trash* or *Done*:

1. Click **Done** — not Move to Trash.
2. Open **System Settings → Privacy & Security**, scroll to **Security**. There's a
   line saying QuantJobs was blocked, with an **Open Anyway** button.
3. Click it and authenticate. It opens, and you're never asked again.

On macOS 14 and earlier, right-click → Open does the same job in one step. macOS 15
removed that shortcut, so the route above is the one that works now.

[dmg]: https://github.com/mgman03/quantjobs/releases/latest/download/QuantJobs.dmg

**Command line:** clone it and run — there's nothing to install.

```bash
git clone https://github.com/mgman03/quantjobs.git
cd quantjobs
./quantjobs.py scrape -c swe -l intern
```

To build the app yourself instead of downloading it (needs Xcode command-line tools):

```bash
cd QuantJobsApp
./make-app.sh          # builds and installs to /Applications, then shows it in Finder
./make-app.sh --dmg    # or build the disk image yourself
```

An app you built yourself isn't quarantined, so Gatekeeper leaves it alone — the
Privacy & Security step above only applies to a downloaded copy.

**Keep the checkout out of `~/Desktop`, `~/Documents` and `~/Downloads`.** macOS
gates those three folders, so an app reading its config from one gets a permission
prompt — and because `make-app.sh` signs ad-hoc, every rebuild looks like a new app
and the prompt comes back. Anywhere else (`~/quant-internships`, `~/Developer/…`) and
you're never asked. If you do keep it in a guarded folder, click Allow or the board
list stays empty.

## Commands

| Command | What it does |
|---|---|
| `scrape` | Fetch and filter postings |
| `companies` | Show the firm list and which are enabled |
| `categories` | Show the configured categories |
| `verify` | Check every board still resolves |
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

```bash
./quantjobs.py scrape -c quant-trading -l intern
./quantjobs.py scrape -c swe -L london -L amsterdam
./quantjobs.py scrape -c quant-research --since 7 -f md -o roles.md
./quantjobs.py scrape -c swe -l intern --tag bigtech     # FAANG+ only
./quantjobs.py scrape -c all --tag quant --new-only      # daily driver
```

**A note on levels.** `intern-or-newgrad` means *early career only* — a posting has to
read as an internship or a new-grad role. `any` switches the level test off entirely,
so senior postings come too. They are not the same thing: Jane Street's SWE board
returns 0 for all three early-career levels right now, and 26 for `any` — every one of
them experienced. In the app these are the **Both** and **All levels** buttons.

## The Mac app

`QuantJobsApp/` covers the same ground as the CLI and reads the same config files, so
the two stay in sync and you can use whichever suits the moment.

- **Filters in one row above the table** — level, location, firms, date, search.
  Location and firms are drill-down pickers: click a group on the left to narrow the
  list on the right, tick either to select. Active filters show as removable chips
  underneath, so you can always see why the list is short.
- **Changing a filter updates the list straight away.** Level, location, date,
  category and search are applied to what's already been fetched, so they're
  instant — no network at all. Changing *which firms* does need boards fetched, and
  only the ones you added are visited: adding one firm to a selection of a hundred
  costs one request, not a hundred. Deselecting a firm just drops its rows.
  ⌘R refetches everything when you want genuinely fresh results.
- **Click a role for the detail panel** — team, board, tags, the description when the
  board ships one, and a button straight to the posting.
- **Save / Applied / Hidden** on every row, each with its own list in the sidebar.
  Applied carries the date and a notes field. These survive a board deleting the
  posting — a role that closed is struck through rather than lost, because an
  application you're tracking shouldn't disappear with the listing.
- **Opens populated.** The last run is cached, so the window comes up with results in
  it and refreshes behind them; it only re-scrapes if the cache is over six hours old.
- **Titles are tidied** — `2026 - Internship, Quantitative Developer` shows as
  *Quantitative Developer*, with the full title in the detail panel.
- **The same role across offices folds into one row**, reading `London, GB +4`, with a
  separate link per posting.
- **Remembers how you left it** — category, level, every filter, which list you were
  on.
- ⌘R scrapes, double-click opens a posting, and results export to CSV / JSON / MD.
- **Scrape ▸ Manage Boards** edits the firm list, with presets (*Only Tier 1*,
  *Tier 1 + 2*, *Only Quant*, …). Verify and Discover live there too.

## Which firms are wired up

**150 of the 154 entries have a working source** and **110 ship enabled** —
`./quantjobs.py verify` returns *110 working, 0 broken*.

| group | segment | firms | on by default |
|---|---|--:|--:|
| Quant | Tier 1 | 19 | 19 |
| Quant | Tier 2 | 30 | 26 |
| Quant | Tier 3 | 8 | 0 |
| Big Tech | FAANG+ | 66 | 55 |
| Big Tech | Frontier AI | 18 | 8 |
| Big Tech | Startups | 13 | 2 |

**Tier 1**, all live: AQR Capital · Citadel · Citadel Securities · DRW ·
Hudson River Trading · IMC Trading · Jane Street · Jump Trading · Millennium ·
Optiver · Point72 · Qube RT · Radix Trading · SIG · Squarepoint Capital ·
Tower Research · Two Sigma · Virtu Financial · XTX Markets

**Frontier AI**: Anduril · Anthropic · Aurora · Cohere · Databricks · Decagon ·
ElevenLabs · Harvey · LangChain · Mercor · Modal · Nuro · OpenAI · Perplexity ·
Physical Intelligence · Replit · Scale AI · Waymo

Run `./quantjobs.py companies` for the full list rather than trusting a README that
drifts.

**Hudson River Trading** is read from its own site. Its public Greenhouse board is a
talent-community placeholder holding three generic entries — not the ~70 roles it
actually has open — so the adapter walks HRT's jobs sitemap instead.

Four firms have no scriptable board at all — Chicago Trading Co, Maven Securities,
PEAK6 and Quantlab — and sit in `companies.json` as disabled placeholders with a note
saying what was tried. Apple, Google, Meta and Microsoft publish nothing a script can
read either, so they come from a community internship feed instead; Apple and
Microsoft ship on, Meta and Google ship off because their links can't be confirmed.
See [INTERNALS.md](INTERNALS.md#apple-google-meta-and-microsoft) for the detail.

## Do the links actually work?

A job board that sends you to dead postings is worse than no job board. Every URL is
checked before it reaches you:

| result | meaning | what happens |
|---|---|---|
| **ok** | under 400 | kept |
| **dead** | 404 or 410 — the posting is gone | **dropped, you never see it** |
| **blocked** | 403, timeout, DNS — inconclusive | kept, flagged |

The three-way split matters. A firm that blocks scripted callers is not the same as a
posting that has closed, and collapsing the two would either flood the table with dead
links or silently delete every role at the strictest firms. Anything inconclusive is
kept, and the detail panel says the link couldn't be confirmed rather than quietly
dropping it.

## Configuring

`companies.json` is the firm list. Add, remove, or flip `enabled`:

```json
{ "name": "Jump Trading", "ats": "greenhouse", "token": "jumptrading",
  "enabled": true, "tags": ["hft", "prop"], "tier": 1, "segment": "Tier 1" }
```

- **`ats`** — one of `greenhouse`, `lever`, `ashby`, `smartrecruiters`, `workday`,
  `amazon`, `eightfold`, `jibe`, `uber`, `wolverine`, `citadel`, `optiver`,
  `twosigma`, `simplify`, `hrt`. Most take a `token`; a few need other fields — see
  [INTERNALS.md](INTERNALS.md#board-adapters).
- **`tags`** — `quant` and `bigtech` decide which half of the app's Firms picker a
  firm lands in. The rest are descriptive and usable with `--tag`.
- **`tier`** — 1, 2 or 3. Tiers 1 and 2 ship enabled, tier 3 ships off. A judgement
  call, so edit it freely.
- **`segment`** — the sub-group the Firms picker lists. `Tier 1/2/3` for quant;
  `FAANG+`, `Frontier AI` or `Startups` for big tech.

Don't know a firm's token? Point `discover` at their careers page, then `verify`:

```bash
$ ./quantjobs.py discover https://www.headlandstech.com/careers/
  greenhouse       headlandstechnologiesllc
    → {"name": "…", "ats": "greenhouse", "token": "headlandstechnologiesllc", "enabled": true}
```

`categories.json` holds the `include` / `exclude` phrase lists per category. Matching
is case-insensitive with word boundaries, and spaces match hyphens and slashes, so
`"co-op"` catches `Co-Op`. Adding a category is a new key in that file.

**Where the config lives.** Both tools read the files sitting in the checkout.
`$QUANTJOBS_CONFIG` overrides that for both:

```bash
export QUANTJOBS_CONFIG=/path/to/checkout
```

An app installed to `/Applications` isn't in the checkout, so it falls back to
`~/Library/Application Support/QuantJobs`, seeded from a copy inside the bundle. To
have it share your checkout instead — which is what you want if you use both tools —
point it there once:

```bash
defaults write local.quantjobs.shared configDirectory ~/quant-internships
```

(That domain is deliberate — `UserDefaults.standard` keys off the bundle
identifier, so the installed app and a `swift run` from the checkout would
otherwise read two different places.)

## Updating

**The app updates itself.** It asks GitHub once a day whether there's a newer
release, and if there is, a bar appears above the results with the version, a link
to what changed, and an Update button. Press it and the app downloads the disk
image, checks it really is QuantJobs and really is newer, swaps itself out and
relaunches. There's also **QuantJobs ▸ Check for Updates…** if you'd rather ask.

Nothing is installed without you clicking Update, and nothing is sent anywhere — the
check is one unauthenticated GET to the public releases API.

Updating this way skips the Gatekeeper prompt a manual download triggers, because
quarantine is applied by browsers rather than by the network.

**By hand instead:** download the [latest DMG][dmg] and drag it over the old one. Your saved
and applied roles, settings and on/off choices are kept — they live outside the app.
The firm list is refreshed from the new version on first launch: firms added since
your version arrive, repaired tokens and corrected notes come with them, and firms you
switched on or off stay how you left them. Anything you added by hand is untouched.

**The CLI:** `git pull`. Note that `companies.json` is both the shipped roster and your
live config, so if you've toggled firms in the app git will report a conflict there —
`git checkout --theirs companies.json` takes the new roster if you don't mind losing
your on/off choices.

## Notes

- `.seen.json` tracks postings you've already been shown, which powers `--new-only`.
  Delete it to reset; pass `--no-state` to leave it untouched.
- `.tracked.json` holds what you've saved, applied to or hidden, and the CLI reads it
  too: `--skip-hidden` and `--saved-only`.
- Boards are fetched in parallel (`--workers`, default 8) with retries. A firm that
  fails is reported at the end and never kills the run.
- Nothing is authenticated — these are the same public endpoints the firms' own
  careers pages call.
- Locations are resolved through a gazetteer in `locations.json`, so `US, CA, Santa
  Clara` and `Santa Clara, California, United States` both become `Santa Clara, CA`.
  That's what makes `--continent` and `--city` work.

Run it daily and only see what's new:

```bash
cd /path/to/quantjobs && ./quantjobs.py scrape -c swe --new-only -f md -o new.md
```

Empty output means nothing new since the last run.

## More

[INTERNALS.md](INTERNALS.md) covers the board adapters and their config fields, how
the two implementations are kept in sync, the location parser's rules, and the
failure modes worth knowing about if you extend this.

## Author

Mykhaylo Gershman — <mgershman@ethz.ch>

MIT licensed; see [LICENSE](LICENSE).
