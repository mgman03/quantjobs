# quantjobs

Finds internship and new-grad postings by reading firms' job boards directly — 181 of
them, quant shops and big tech — and keeps track of what you've applied to. A native
Mac app, no account and no server.

Dead links are dropped before you see them.

```
COMPANY             TITLE                                        LOCATION       LEVEL   POSTED
────────────────────────────────────────────────────────────────────────────────────────────────
Virtu Financial     2027 Internship - Frontend Engineer (UI)     New York       intern  2026-07-31
DRW                 Platform Engineer Intern                     Chicago        intern  2026-07-30
Jump Trading        Campus Software Engineer (Intern)            London         intern  2026-07-24
Akuna Capital       Software Engineer Intern - C++, Summer 2027  Chicago, IL    intern  2026-07-14
Old Mission Capital Software Engineer – 2027 Internship Program  Chicago, IL    intern  2026-07-15
...
```

There used to be a Python CLI alongside this, implementing the same twenty board
adapters and the same matching rules a second time. Every new board and every filter
had to be written twice and then proved identical, so it was deleted rather than kept
limping — `git log` has it if you want it back. What it could do that the app couldn't
is now `--check` on the app binary; see [INTERNALS.md](INTERNALS.md).

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

**Build it yourself instead of downloading it (needs Xcode command-line tools):

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
  that it shows as *OA (2nd)* rather than overwriting the first.
- **An OA you've been given and an OA you've handed in are different states**, and
  the tracker says which. A step you sit — online assessment, interview, final
  round — carries two dates: when it arrived and when you actually sat it. Until
  the second one is set, the row reads `OA · to do` and the stage heading counts it
  in *"2 to do"*; afterwards it reads `OA · done` and ages from the day you sat it
  rather than the day it landed. One is a deadline you still owe and the other is a
  wait for a result, which the old single-date `OA · 5d` couldn't tell apart. Each
  occurrence is completed separately, so a second OA doesn't inherit the first's. All of it survives a board
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
  marking it inferred rather than stated, and it is when the *tracker* first saw it
  rather than when this Mac did (see Notes). Boards that ship no posted date used to
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

**181 of the 193 boards answer** — **Scrape ▸ Manage Boards ▸ Verify** reports
*181 working, 12 broken*. Ten of the twelve are firms with no scriptable board at
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

**Tier 1, live**: AQR Capital · Citadel · Citadel Securities · D. E. Shaw · DRW ·
G-Research · Hudson River Trading · IMC Trading · Jane Street · Jump Trading · Millennium ·
Optiver · Point72 · Qube RT · Radix Trading · SIG · Squarepoint Capital ·
Tower Research · Two Sigma · Virtu Financial · XTX Markets

**Tier 1, no readable board**: BlackRock · Bloomberg · Bridgewater ·
Goldman Sachs · JPMorgan Chase. They're in the file and off, with a note
each — see the table below for what's in the way. They're marked Tier 1 because that's
what they are to someone applying, not because anything can be read from them yet.

`enabled` isn't a fixed shipped default — the app writes your Firms selection back to
the same file, so whatever you last picked is what the file says. The Firms picker
shows the current state.

**Frontier AI**: Anduril · Anthropic · Aurora · Cohere · Cursor · Databricks ·
Decagon · ElevenLabs · Figure AI · Glean · Harvey · LangChain · Mercor · Modal ·
Nuro · OpenAI · Perplexity · Physical Intelligence · Replit · Scale AI · Sierra ·
Together AI · Waymo · Wayve · xAI · Zoox

Open **Scrape ▸ Manage Boards** for the full list rather than trusting a README that
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

**The names that aren't here, and why.** Eight firms people do apply to have no board
this can read, and each sits in `companies.json` disabled with a `note` rather than
being left out:

| firm | what's in the way |
|---|---|
| Goldman Sachs | Avature (`recruiting360.avature.net`) — no adapter |
| JPMorgan Chase | Oracle HCM (`jpmc.fa.oraclecloud.com`) — no adapter |
| Cisco | Phenom People — no adapter |
| Plaid | RippleMatch — no adapter |
| Bridgewater · BlackRock · Bloomberg · Tesla | careers site answers 403 to scripted callers |

The four platform gaps are one adapter each and would bring more than one firm with
them; the 403s need a browser rather than a new adapter.

**D. E. Shaw** and **G-Research** used to be in that table and now have adapters of
their own. Neither has an ATS, but neither needs one: D. E. Shaw's careers page is a
Next.js app, so the listing it renders client-side is also embedded in the document it
serves — 86 roles, 14 of them internships, in one request to `__NEXT_DATA__`.
G-Research server-renders its vacancy cards, so a regex over
`/vacancies/` gets all 63. Both give 13 and 4 early-career roles respectively, and
neither publishes a posted date, so those rows carry the first-seen date instead.

**Maven Securities** has no scriptable board — its careers page 404s and shows no ATS
fingerprint — and sits in `companies.json` as a disabled placeholder with a note saying
what was tried. **Quantlab**'s board is Jobvite and was empty when last checked, so it
has nothing to read yet rather than nowhere to read from.

**Google is read from its own careers site.** It server-renders its results, so no
key is needed — but the whole board is thousands of roles at twenty a page, so the
adapter asks for two slices instead: `employment_type=INTERN` (internships and
apprenticeships) and `target_level=EARLY` (the new-grad end of full-time). That's 404
roles, of which 7 are early-career SWE — including *Software Engineer, Early Career,
Campus*. It replaces the Simplify feed for Google, which carried three Student
Researcher rows whose links had all gone dead.

Worth knowing what that filter shows: Google currently has **11 postings typed as
INTERN**, and not one is a software internship — four Student Researcher, three Swiss
apprenticeships, four gReach roles. Google's 2027 SWE internships simply aren't posted
yet. The adapter will pick them up the day they are.

**Apple is read from its own careers search**, filtered to the Students/Internships
team — 51 internships against the feed's 12, and the only board here that dates its own
cards. The filter matters more than the parsing: `search=intern` returns retail roles
like *IN-Business Expert*, because Apple matches the keyword against everything.

**Meta and Microsoft still come from the community feed** and are the two remaining
second-hand sources. Meta's own site posts to a GraphQL endpoint needing an `fb_dtsg`
session token; Microsoft's `gcsservices.careers.microsoft.com` refuses scripted
connections. Both ship off. See
[INTERNALS.md](INTERNALS.md#apple-google-meta-and-microsoft) for the detail.

**On thin-looking firms.** A small count usually means a small firm, not a broken
board. XTX Markets returning 7 roles looks wrong for a firm that size, but its careers
page points at exactly the Greenhouse board being read — that's genuinely all it posts.
Bracebridge (4), Quadrature (4) and Simplex (5) are the same story. The counts worth
chasing are the ones from *aggregators* rather than a firm's own board, which is what
Google and Apple both were.

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
  `twosigma`, `simplify`, `sitemap`, `janestreet`, `deshaw`, `gresearch`, `google`, `apple`. Most take a `token`; a few need other fields — see
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

Don't know a firm's token? **Scrape ▸ Manage Boards ▸ Discover** sniffs a careers page
for its ATS fingerprint and offers the entry to add. To check what a board actually
returns before trusting it:

```bash
./QuantJobsApp/.build/debug/QuantJobs --check --board headlands
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

**The command line:** `make-app.sh` also drops a `quantjobs` wrapper in the first
of `~/.local/bin` or `/usr/local/bin` that is already on your PATH, so the
checks below are typeable. The binary itself lives inside the bundle at
`/Applications/QuantJobs.app/Contents/MacOS/QuantJobs`, which is not on anyone's
PATH — that is what the wrapper is for. Nothing is written over: a `quantjobs`
that is not ours is left alone and the script says so.

**The CLI:** `git pull`. Note that `companies.json` is both the shipped roster and your
live config, so if you've toggled firms in the app git will report a conflict there —
`git checkout --theirs companies.json` takes the new roster if you don't mind losing
your on/off choices.

## The page on your phone

`.github/workflows/fetch.yml` runs the same Swift scraper on GitHub's Ubuntu
runners twice a day, builds a single self-contained HTML page with every filter
the app has, and publishes it to Cloudflare Pages. Free at every step, and it
keeps working with the Mac shut. Turning it on takes three secrets in
**Settings → Secrets and variables → Actions**:

| Secret | What it is |
| --- | --- |
| `CLOUDFLARE_API_TOKEN` | My Profile → API Tokens → Create Token, with *Cloudflare Pages: Edit* |
| `CLOUDFLARE_ACCOUNT_ID` | the id in the dashboard URL, `dash.cloudflare.com/<id>/…` |
| `SITE_PASSWORD` | whatever you want the page to ask for |

The page lists what you applied to and were turned down for, so it is not
published open. `site/_worker.js` runs on every request and asks for
`SITE_PASSWORD` over HTTP Basic auth — the browser's own prompt, which Safari
offers to save to the keychain, so it is one tap after the first time. The
deploy pushes the secret to Cloudflare for you; there is one place to change it.

Deliberately **not** the Pages "Access policy" toggle in the Cloudflare
dashboard: that one covers preview deployments only and leaves the real
`<project>.pages.dev` URL open to anyone with the link. Protecting that through
Cloudflare instead means onboarding Zero Trust, which is a lot of account setup
for one page.

With no `SITE_PASSWORD` set the site answers 503 and says so, rather than
serving the history to whoever asks. `node site/_worker.test.mjs` checks the
gate and the sync below.

### Marks and filters sync both ways

A star tapped on the train shows up in the app, and the app's filters are the
ones the page opens with. The page keeps nothing itself — it is rebuilt from
scratch twice a day — so the marks live in a Cloudflare KV namespace that only
the worker can reach, behind the same password. The workflow creates it; the
API token needs **Workers KV Storage: Edit** on top of Pages: Edit, and until it
has that the site still deploys and the page says marks are not being saved.

On the Mac, once:

```sh
quantjobs --check --sync-setup https://quantjobs.pages.dev   # asks for the password
quantjobs --check --sync                                     # what the phone knows
quantjobs --check --sync --push                              # a full round trip
```

That writes `.sync.json` in the config folder, `chmod 600`, gitignored. The app
syncs on launch, two seconds after any mark you make, and on ⇧⌘S.

Conflicts resolve per posting, by the instant of the last edit, **except**
milestones, which are unioned: the Mac holding "applied 3 June, OA 20 June" and
the phone adding an interview ends up with three steps, not with whichever side
was touched last. Filters are all-or-nothing on their own timestamp. The page's
firm and sort pickers are not synced — the app narrows firms in the Firms picker
and sorts by clicking a column, and there is nothing to map them onto.

To try it without deploying:

```sh
node site/serve.mjs 8791 &                       # the real worker, KV in memory
quantjobs --check --web /tmp/page.html
npm i jsdom && node site/page.test.mjs /tmp/page.html
```

## Notes

- `.seen.json` records when a posting was first seen, which is what dates a role
  whose board publishes no date. Delete it to reset.
- **First-seen dates are shared, not per-machine.** A posting has one date it was
  first advertised, so the scheduled fetch keeps the ledger on the repository's
  `state` branch — one force-pushed commit, no history — and the app folds it in at
  launch, earliest date winning. Without it the twice-daily rebuild started from an
  empty file every run and dated everything "found today", which is what Jane
  Street's board, publishing no dates of its own, looked like on the phone.
  `quantjobs --check --ledger` prints what the fetch knows and what merging it would
  change.
- `.tracked.json` holds what you've saved, applied to or hidden, and the application
  timeline for each. It survives a board deleting the posting.
- Boards are fetched concurrently with retries. A firm that fails is reported in the
  status bar and never kills the run.
- Nothing is authenticated — these are the same public endpoints the firms' own
  careers pages call.
- Locations are resolved through a gazetteer in `locations.json`, so `US, CA, Santa
  Clara` and `Santa Clara, California, United States` both become `Santa Clara, CA`.
  That's what makes the continent and city filters work.
- The app opens on the last run's results and refreshes behind them, so "what's new
  since yesterday" is what you see when you open the window.

## More

[INTERNALS.md](INTERNALS.md) covers the board adapters and their config fields, how
the two implementations are kept in sync, the location parser's rules, and the
failure modes worth knowing about if you extend this.

## Author

Mykhaylo Gershman — <mgershman@ethz.ch>

MIT licensed; see [LICENSE](LICENSE).
