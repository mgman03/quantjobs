# quantjobs

Finds internship and new-grad postings by reading firms' job boards directly — 178 of
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
--category, -c   swe | quant-trading | quant-research | hardware | data | all
--no-stack       leave out roles using this stack: cpp | python | frontend, repeatable
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

**Stacks are an exclusion filter, not a category.** `--no-stack` drops roles that
name a given language or layer, and it's repeatable — each one you name removes a
bucket:

```bash
./quantjobs.py scrape -c swe --no-stack python              # everything except Python roles
./quantjobs.py scrape -c swe --no-stack python --no-stack frontend
```

**A role that names no stack is always kept**, and that's the whole reason the
filter works by exclusion. **270 of 310 early-career SWE roles name no language at
all.** An include filter meant ticking every language you'd accept *plus* a
separate "unspecified" box — three ticks to express one preference, and an empty
table if you forgot the last one. Saying "not Python" needs one tick and can't
silently empty the list.

Use `--deep` with it. Boards name the language in the description far more often
than in the title.

In the app it's the `{}` menu in the filter row, with a tick box per stack and
every row reading *"— hide these"*, because a tick box next to a language name
otherwise reads as "I want this one".

A category in `categories.json` becomes a stack by naming its `parent`; the
matching is deliberately *ungated* by that parent, so "does this posting mention
C++" is answerable whichever category you're browsing.

**A note on levels.** `intern-or-newgrad` means *early career only* — a posting has to
read as an internship or a new-grad role. `any` switches the level test off entirely,
so senior postings come too. They are not the same thing: Jane Street's SWE board
returns 0 for all three early-career levels right now, and 26 for `any` — every one of
them experienced. In the app these are the **Both** and **All levels** buttons.

## The Mac app

`QuantJobsApp/` covers the same ground as the CLI and reads the same config files, so
the two stay in sync and you can use whichever suits the moment.

- **Filters in one row above the table** — level, location, firms, posted date,
  intake year, stack, applied, search. Location and firms are drill-down pickers:
  click a group on the left to narrow the list on the right, tick either to select.
  Each control states its own setting, so there's no second row of chips repeating
  them; a **Clear** link appears at the end of the row when anything is on. The row
  picks between three layouts depending on the window: full labels, icon-only, and
  icon-only with the level picker folded into a menu — so it never truncates and
  never squeezes the sidebar.
- **Changing a filter updates the list straight away.** Level, location, date,
  category and search are applied to what's already been fetched, so they're
  instant — no network at all. Changing *which firms* does need boards fetched, and
  only the ones you added are visited: adding one firm to a selection of a hundred
  costs one request, not a hundred. Deselecting a firm just drops its rows.
  ⌘R refetches everything when you want genuinely fresh results.
- **Click a role for the detail panel** — team, board, tags, the description when the
  board ships one, and four buttons: **Open Posting**, then **Save**, **Move to
  Applied** and **Hide** at a matched width. Each says what clicking it will do
  rather than what the role currently is, so a saved role reads *Unsave*.
- **Save, track, hide** — three independent marks on every row, each with its own
  list in the sidebar. Independent matters: hiding a role you've applied to keeps the
  application, and none of the three can erase another.
- **Applications have a timeline.** Record *Applied*, *Online assessment*,
  *Interview*, *Final round*, *Offer*, *Rejected* or *Withdrawn* from the row's
  ✓ menu, and in the Applied list the Progress column reads `OA · 5d` — where you
  are and how long it's been. It appears only there; everywhere else it would be an
  empty column on almost every row. The detail panel shows the whole sequence with
  dates and "2 weeks ago", and lets you correct one, add a step you did out of
  order, or record a stage **twice** — a second online assessment is common enough
  that it shows as *OA (2nd)* rather than overwriting the first. All of it survives a board
  deleting the posting — a role that closed is struck through rather than lost,
  because an application you're tracking shouldn't disappear with the listing.
- **The Applied list is grouped by stage**, one foldable block per stage you've
  reached, in pipeline order and newest activity first. Fold the ones you're not
  thinking about; a folded heading still says how many and how long the stalest has
  been sitting there. Which blocks are folded is remembered.
- **The Applied filter** in the filter row has three settings: show everything,
  hide the roles you've applied to, or hide *every* role at a firm you've applied
  to — because one application per firm is usually the point, and a firm's other
  twelve postings are noise once you've sent one. Either way they stay in the
  Applied list.
- **Intake year is parsed out of the title and filterable.** Boards leave stale
  cycles up, and Qube's internship still says 2026, which in a list reads
  identically to a 2027 one. The Level chip carries the year (`Intern '27`) and the
  filter offers only years actually present, with a count each. A posting that names
  no year is never filtered out, because most name none.
- **A posting with no date shows when it was first seen** — `~ 6d`, with the tilde
  marking it inferred rather than stated. Boards that ship no posted date used to
  leave the column blank, which sorted them to the bottom and made a role found
  yesterday look older than one from last month.
- **The Firms picker narrows by tier**, so "only the premium ones" is one click.
  The quant half always had this because its segments *are* tiers; big tech's are
  themes, so FAANG+ meant Apple and Google sitting alongside 49 mid-tier names
  with no way to ask for just the first kind. `Tier 1` there is Amazon, Apple,
  Google, Meta, Microsoft, Netflix, Nvidia, Palantir and Stripe.
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

**178 of the 193 boards answer** — `./quantjobs.py verify --all` returns
*178 working, 15 broken*. Twelve of the fifteen are firms with no scriptable board at
all, kept in the file with a `note` so you can see they were considered rather than
missed; they're named further down. One, **Uber**, is a board that used to work and
now 404s.

| group | segment | boards |
|---|---|--:|
| Quant | Tier 1 | 26 |
| Quant | Tier 2 | 36 |
| Quant | Tier 3 | 11 |
| Big Tech | FAANG+ | 75 |
| Big Tech | Frontier AI | 26 |
| Big Tech | Startups | 19 |

Boards, not firms: a few firms have two — see [`board`](#configuring).

**Tier 1, live**: AQR Capital · Citadel · Citadel Securities · DRW ·
Hudson River Trading · IMC Trading · Jane Street · Jump Trading · Millennium ·
Optiver · Point72 · Qube RT · Radix Trading · SIG · Squarepoint Capital ·
Tower Research · Two Sigma · Virtu Financial · XTX Markets

**Tier 1, no readable board**: BlackRock · Bloomberg · Bridgewater · D. E. Shaw ·
G-Research · Goldman Sachs · JPMorgan Chase. They're in the file and off, with a note
each — see the table below for what's in the way. They're marked Tier 1 because that's
what they are to someone applying, not because anything can be read from them yet.

`enabled` isn't a fixed shipped default — the app writes your Firms selection back to
the same file, so whatever you last picked is what the file says. `./quantjobs.py
companies` prints the current state.

**Frontier AI**: Anduril · Anthropic · Aurora · Cohere · Cursor · Databricks ·
Decagon · ElevenLabs · Figure AI · Glean · Harvey · LangChain · Mercor · Modal ·
Nuro · OpenAI · Perplexity · Physical Intelligence · Replit · Scale AI · Sierra ·
Together AI · Waymo · Wayve · xAI · Zoox

Run `./quantjobs.py companies` for the full list rather than trusting a README that
drifts.

**Jane Street** is read from its own careers JSON. Its Greenhouse board is experienced
hires only — 177 roles and not one internship — while ~44 internships and ~23 new-grad
roles sit in the feed its careers page reads.

**A firm's campus roles are often on a different board from its main one**, and reading
only the main one misses every internship it has. **Millennium**'s Eightfold board
carries 244 roles and not one of them is early-career; its 56 2027 internships are on a
separate site. **Chicago Trading Co** posts its 2027 SWE and quant internships to a
Greenhouse board its careers page never links to. **Arrowstreet** and **Mastercard**
each split one Workday tenant into an experienced site and a campus site. Those firms
have one entry per board, told apart by `board` (see [Configuring](#configuring)); the
postings still say just "Millennium".

**Hudson River Trading** and **Marshall Wace** are read from their own sites. HRT's
public Greenhouse board is a talent-community placeholder holding three generic
entries rather than the ~70 roles it has open; Marshall Wace's carries a single
Recruitment Assistant posting while its internships live as pages on mwam.com. The
`sitemap` adapter walks each firm's own sitemap instead.

**ExodusPoint** ships off. Its Greenhouse board holds two signposts — "Investment -
ExodusPoint Jobs Page" and "Non-Investment - Referral" — rather than roles, and its
site lists nothing. Two non-jobs in the table is worse than an absent firm.

**The names that aren't here, and why.** Ten firms people do apply to have no board
this can read, and each sits in `companies.json` disabled with a `note` rather than
being left out:

| firm | what's in the way |
|---|---|
| Goldman Sachs | Avature (`recruiting360.avature.net`) — no adapter |
| JPMorgan Chase | Oracle HCM (`jpmc.fa.oraclecloud.com`) — no adapter |
| Cisco | Phenom People — no adapter |
| Plaid | RippleMatch — no adapter |
| D. E. Shaw · G-Research | own client-side careers app, no JSON endpoint found |
| Bridgewater · BlackRock · Bloomberg · Tesla | careers site answers 403 to scripted callers |

The four platform gaps are one adapter each and would bring more than one firm with
them; the 403s need a browser rather than a new adapter.

**Maven Securities** has no scriptable board — its careers page 404s and shows no ATS
fingerprint — and sits in `companies.json` as a disabled placeholder with a note saying
what was tried. **Quantlab**'s board is Jobvite and was empty when last checked, so it
has nothing to read yet rather than nowhere to read from.

Apple, Google, Meta and Microsoft come from a community internship feed rather than
their own boards, and it shows: the feed had 12 Apple roles, 10 Microsoft, 4 Meta and 3
Google when last checked, against the hundreds each firm actually has. Treat those four
as a hint, not as coverage — Apple and Microsoft ship on, Meta and Google off. See
[INTERNALS.md](INTERNALS.md#apple-google-meta-and-microsoft) for the detail.

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
  `twosigma`, `simplify`, `sitemap`, `janestreet`. Most take a `token`; a few need other fields — see
  [INTERNALS.md](INTERNALS.md#board-adapters).
- **`tags`** — `quant` and `bigtech` decide which half of the app's Firms picker a
  firm lands in. The rest are descriptive and usable with `--tag`.
- **`tier`** — 1, 2 or 3. Tiers 1 and 2 ship enabled, tier 3 ships off. A judgement
  call, so edit it freely.
- **`segment`** — the sub-group the Firms picker lists. `Tier 1/2/3` for quant;
  `FAANG+`, `Frontier AI` or `Startups` for big tech.
- **`board`** — only for a firm with more than one board. Plenty of them keep campus
  hiring on a separate portal their main board never lists, so the firm gets one
  entry per board and `board` says which is which. Postings still carry the plain
  firm name; the label shows up in the Firms picker and in `companies`:

  ```json
  { "name": "Millennium", "ats": "eightfold", "host": "mlp.eightfold.ai",  "tenant": "mlp.com" }
  { "name": "Millennium", "ats": "eightfold", "host": "campusjobs.mlp.com", "tenant": "mlp.com",
    "board": "Campus" }
  ```

Matching is case-insensitive, word-bounded, and plural-tolerant: `"graduate"` also
catches *Fresh Graduates*, and spaces match hyphens and slashes, so `"co-op"` catches
*Co-Op*. That applies to the level vocabulary and to `categories.json` alike.

Don't know a firm's token? Point `discover` at their careers page, then `verify`:

```bash
$ ./quantjobs.py discover https://www.headlandstech.com/careers/
  greenhouse       headlandstechnologiesllc
    → {"name": "…", "ats": "greenhouse", "token": "headlandstechnologiesllc", "enabled": true}
```

`categories.json` holds the `include` / `exclude` phrase lists per category, matched by
the same rules. Adding a category is a new key in that file.

There is no separate **Quant Dev** category. It was folded into `swe`, because the
hybrid seat is a software job under another name and the split meant checking two
lists for one kind of role — and because `swe` already includes the bare term
`developer`, so nearly every quant-dev posting had been matching both lists anyway.
Its fourteen phrases (`quantitative developer`, `quant technologist`, `trading
systems`, `strat`, …) now live in `swe`.

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
