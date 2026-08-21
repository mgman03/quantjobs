import Foundation

/// Exports one self-contained HTML page of what the app knows, styled like the
/// app, for reading and marking up on a phone.
///
/// It is an export, not a second scraper. A browser cannot fetch these boards —
/// no CORS headers, and half of them sit behind Cloudflare — so anything on the
/// web is a snapshot of what this binary already fetched. Twenty adapters
/// re-implemented in JavaScript is the duplication the Python CLI was deleted for.
///
/// The rows are written as real HTML rather than rendered from JSON, because the
/// published page keeps state by saving the DOM inside its synced region: a list
/// built by JavaScript out of a data blob is not saved. Marks made on the phone
/// therefore live in the page itself and survive a reload. Bringing them back to
/// this app is a separate, deliberate step, because the desktop cannot read the
/// page's storage — there is no automatic two-way sync without a server.
@MainActor
enum WebExport {

    static func run(to path: String) async -> Int32 {
        let model = AppModel()
        await model.reload()

        // Every early-career posting in every category, not the one slice the
        // window happens to be showing. The page can only filter what it was
        // given, so giving it less than the app has is what made it a reading
        // list rather than the same tool.
        var seen = Set<String>()
        var rows: [(Job, TrackedJob?)] = []
        for job in model.jobs
        where !job.matchedLevels.isDisjoint(with: ["intern", "newgrad"])
            && seen.insert(job.key).inserted {
            rows.append((job, model.trackedEntry(for: job)))
        }
        // Anything marked comes too, at any level, since a role you applied to
        // matters whether or not it still matches a filter.
        for entry in model.tracked.values
        where (entry.saved || entry.hasApplication || entry.hidden)
            && seen.insert(entry.job.key).inserted {
            rows.append((entry.job, entry))
        }
        rows.sort { $0.0.effectiveDate > $1.0.effectiveDate }

        // matchedStacks is not persisted in the cache — it is tagged at ingest and
        // a cache-restored job carries none — so the stack filter would have had
        // nothing to offer. Recomputing here from the same stack categories the
        // app uses is cheaper than persisting a derived field.
        let stackMatchers = model.stackCategories.map { CategoryMatcher($0) }
        let tagged: [(Job, TrackedJob?)] = rows.map { pair in
            var job = pair.0
            if job.matchedStacks.isEmpty {
                let raw = RawJob(title: job.title, location: job.location,
                                 url: job.url, posted: job.posted,
                                 department: job.department,
                                 description: job.description)
                job.matchedStacks = Set(stackMatchers
                    .filter { $0.acceptsCategory(raw, deep: false) }
                    .map(\.name))
            }
            return (job, pair.1)
        }

        let html = page(rows: tagged.map { row($0.0, $0.1) }.joined(separator: "\n"),
                        made: stamp())
        do {
            try html.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            FileHandle.standardError.write(Data("couldn't write \(path): \(error)\n".utf8))
            return 1
        }
        print("wrote \(path) — \(tagged.count) roles")
        return 0
    }

    /// An ISO instant, formatted in the reader's own timezone by the page.
    ///
    /// It used to be formatted here, which meant a page built on a runner in
    /// UTC told a reader in Zurich the wrong time by two hours — and labelled
    /// it "from the Mac", which stopped being true the day the scheduled fetch
    /// started building it.
    private static func stamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return f.string(from: Date())
    }

    /// Where this copy was built, which is not always the same place.
    private static var builtBy: String {
        #if canImport(SwiftUI)
        "from the Mac"
        #else
        "fetched"
        #endif
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// One row of the synced list. Every piece of state a tap can change lives in
    /// an attribute on the `<li>`, so a tap is a DOM mutation the page saves.
    private static func row(_ j: Job, _ e: TrackedJob?) -> String {
        let stage = e?.currentMilestone
        let age = Dates.compact(j.effectiveDate)
            .map { (j.dateIsInferred ? "~ " : "") + $0 } ?? ""
        let year = j.intakeYear.map { "’" + String(String($0).suffix(2)) } ?? ""
        // The same fields ScrapeQuery.matchesSearch uses, in the same order.
        // It was the *shortened* title and the display location, so a search for
        // a word the tidier had trimmed, or for a country as the board wrote it,
        // found nothing here and everything in the app.
        let bits = (j.title + " " + j.company + " " + j.location + " "
                    + j.locationDisplay + " " + j.department).lowercased()
        // "Applied,2026-08-01,;OA,2026-08-05,2026-08-09" — stage, arrival, and the
        // date it was sat where that applies. One string keeps the whole history on
        // the row so the sheet can render and edit it.
        let steps = (e?.milestones ?? [])
            .map { "\($0.stage.short),\($0.date),\($0.done ?? "")" }
            .joined(separator: ";")
        // Days since the date the app would show, so the date filter is a number
        // comparison rather than date parsing in the page.
        let days: String = {
            guard !j.effectiveDate.isEmpty else { return "99999" }
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
            guard let d = f.date(from: j.effectiveDate) else { return "99999" }
            return String(max(0, Int(Date().timeIntervalSince(d) / 86400)))
        }()
        return """
          <li class="row" data-key="\(esc(j.key))" data-role="\(esc(j.roleKey))" data-saved="\(e?.saved == true ? 1 : 0)" \
        data-hidden="\(e?.hidden == true ? 1 : 0)" \
        data-stage="\(esc(stage?.stage.short ?? ""))" \
        data-owed="\(e?.isAwaitingYou == true ? 1 : 0)" \
        data-level="\(esc(j.level))" \
        data-year="\(j.intakeYear.map(String.init) ?? "")" \
        data-days="\(days)" \
        data-firm="\(esc(j.company))" \
        data-region="\(esc(j.continents.joined(separator: "|")))" \
        data-stacks="\(esc(j.matchedStacks.sorted().joined(separator: "|")))" \
        data-phd="\(j.wantsPhD ? 1 : 0)" \
        data-cat="\(esc(j.matchedCategories.sorted().joined(separator: "|")))" \
        data-levels="\(esc(j.matchedLevels.sorted().joined(separator: "|")))" \
        data-city="\(esc(j.cities.joined(separator: "|")))" \
        data-full="\(esc(j.title))" \
        data-team="\(esc(j.department))" \
        data-board="\(esc(j.ats.label))" \
        data-tags="\(esc(j.tags.joined(separator: "|")))" \
        data-posted="\(esc(j.effectiveDate))\(j.dateIsInferred ? " (first seen)" : "")" \
        data-desc="\(esc(String(j.description.prefix(1200))))" \
        data-steps="\(esc(steps))" \
        data-note="\(esc(e?.note ?? ""))" \
        data-find="\(esc(bits))">
            <div class="marks">
              <button class="mk save" data-act="save" aria-label="Save">★</button>
              <button class="mk apply" data-act="apply" aria-label="Advance stage">➤</button>
              <button class="mk hide" data-act="hide" aria-label="Hide">◍</button>
            </div>
            <div class="cell">
              <div class="co"><span class="firm">\(esc(j.company))</span>\
        <span class="pill stage"></span><span class="pill owed">to do</span>\
        <span class="pill yr">\(esc(year))</span></div>
              <div class="ti">\(esc(j.shortTitle))</div>
              <div class="me">\(esc(j.locationDisplay))<span class="age">\
        \(age.isEmpty ? "" : " · " + esc(age))</span></div>
            </div>
            <a class="go" href="\(esc(j.url))" target="_blank" rel="noopener"
               aria-label="Open posting">↗</a>
          </li>
        """
    }

    private static func page(rows: String, made: String) -> String {
        """
        <title>Quant Jobs</title>
        <style>
        /* The app's own palette: near-black panels, one blue accent, amber only
           for a step you still owe. */
        :root {
          --bg: #1c1c1e; --panel: #242427; --fg: #f1f1f3; --dim: #96969e;
          --line: #333338; --chip: #2c2c31; --accent: #3b7ff5; --owed: #e2a03f;
          --star: #f5c451;
        }
        :root[data-theme="light"] {
          --bg: #f6f5f3; --panel: #ffffff; --fg: #17181c; --dim: #63656e;
          --line: #e3e2de; --chip: #eeede9; --accent: #2f5fd0; --owed: #a06614;
          --star: #c08a10;
        }
        @media (prefers-color-scheme: light) {
          :root:not([data-theme="dark"]) {
            --bg: #f6f5f3; --panel: #ffffff; --fg: #17181c; --dim: #63656e;
            --line: #e3e2de; --chip: #eeede9; --accent: #2f5fd0; --owed: #a06614;
            --star: #c08a10;
          }
        }
        * { box-sizing: border-box; -webkit-text-size-adjust: 100%; }
        body {
          margin: 0; background: var(--bg); color: var(--fg);
          font: 15px/1.4 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
        }
        header {
          position: sticky; top: 0; z-index: 5; background: var(--bg);
          border-bottom: 1px solid var(--line);
          padding: max(10px, env(safe-area-inset-top)) 12px 10px;
        }
        .top { display: flex; align-items: baseline; gap: 8px; margin-bottom: 9px; }
        .top h1 { margin: 0; font-size: 16px; font-weight: 650; letter-spacing: -0.01em; }
        #merge-wrap { display: inline-flex; align-items: center; gap: 4px;
          font-size: 12px; color: var(--dim); cursor: pointer;
          padding: 4px 8px; border: 1px solid var(--line); border-radius: 7px; }
        #merge-wrap:has(:checked) { color: var(--fg); border-color: var(--accent); }
        .plus { font-size: 11px; color: var(--dim); margin-left: 5px; }
        #refresh { font-size: 15px; line-height: 1; background: none; border: 0;
          color: var(--dim); cursor: pointer; padding: 2px 4px; }
        #refresh:hover { color: var(--fg); }
        #refresh[disabled] { cursor: default; opacity: .5; }
        @keyframes spin { to { transform: rotate(360deg); } }
        #refresh.busy { animation: spin 1.1s linear infinite; color: var(--accent); }
        .made { font-size: 11px; color: var(--dim); margin-left: auto;
                font-variant-numeric: tabular-nums; }
        /* The app's Lists sidebar, folded flat because a phone has no room for it. */
        .lists { display: flex; gap: 5px; }
        .lists button {
          flex: 1; padding: 7px 4px; border: 0; border-radius: 7px; cursor: pointer;
          background: var(--chip); color: var(--fg); font: inherit; font-size: 12.5px;
          display: flex; align-items: center; justify-content: center; gap: 5px;
          -webkit-tap-highlight-color: transparent;
        }
        .lists button[aria-selected="true"] { background: var(--accent); color: #fff; }
        .n { font-variant-numeric: tabular-nums; opacity: .8; font-size: 11px; }
        input[type=search] {
          width: 100%; margin-top: 8px; padding: 8px 10px; font: inherit; font-size: 14px;
          background: var(--chip); color: var(--fg);
          border: 1px solid var(--line); border-radius: 8px;
        }
        /* One scrollable rail of controls, so six filters fit a phone without
           stacking into a wall the list has to scroll past. */
        .filters {
          display: flex; gap: 6px; margin-top: 8px; overflow-x: auto;
          scrollbar-width: none; -webkit-overflow-scrolling: touch;
          padding-bottom: 2px;
        }
        .filters::-webkit-scrollbar { display: none; }
        .filters select, .filters button {
          flex: 0 0 auto; font: inherit; font-size: 12.5px; padding: 6px 26px 6px 10px;
          border: 1px solid var(--line); border-radius: 99px;
          background: var(--chip); color: var(--fg); cursor: pointer;
          appearance: none;
          background-image: linear-gradient(45deg, transparent 50%, var(--dim) 50%),
                            linear-gradient(135deg, var(--dim) 50%, transparent 50%);
          background-position: right 12px center, right 7px center;
          background-size: 5px 5px, 5px 5px; background-repeat: no-repeat;
        }
        .filters button {
          padding: 6px 12px; background-image: none; color: var(--accent);
          border-color: transparent;
        }
        /* A control that is doing something says so, the way the app's do. */
        .filters select.on {
          background-color: color-mix(in srgb, var(--accent) 22%, var(--chip));
          border-color: color-mix(in srgb, var(--accent) 45%, var(--line));
          color: var(--fg);
        }
        ul { list-style: none; margin: 0; padding: 0; }
        .row {
          display: flex; align-items: flex-start; gap: 8px; padding: 9px 12px;
          border-bottom: 1px solid var(--line); background: var(--panel);
        }
        .marks { display: flex; flex-direction: column; gap: 2px; }
        .mk {
          width: 28px; height: 24px; border: 0; border-radius: 6px; cursor: pointer;
          background: transparent; color: var(--dim); font-size: 13px; line-height: 1;
          -webkit-tap-highlight-color: transparent;
        }
        .mk:active { background: var(--chip); }
        .row[data-saved="1"] .save { color: var(--star); }
        .row:not([data-stage=""]) .apply { color: var(--accent); }
        .row[data-hidden="1"] .hide { color: var(--fg); }
        .row[data-hidden="1"] .cell { opacity: .45; }
        .cell { flex: 1; min-width: 0; }
        .co { display: flex; align-items: center; gap: 5px; flex-wrap: wrap;
              font-size: 11.5px; color: var(--dim); }
        .firm { font-weight: 600; color: var(--fg); font-size: 12.5px; }
        .ti { font-size: 14px; font-weight: 550; margin: 1px 0 2px; }
        .me { font-size: 11.5px; color: var(--dim); font-variant-numeric: tabular-nums; }
        .pill { font-size: 10.5px; padding: 1px 6px; border-radius: 99px;
                background: var(--chip); color: var(--dim); white-space: nowrap; }
        .pill.stage { color: var(--accent); font-weight: 600; }
        .pill.owed { color: var(--owed); font-weight: 600; }
        .pill:empty { display: none; }
        .row[data-owed="0"] .pill.owed { display: none; }
        .go { color: var(--dim); text-decoration: none; font-size: 15px;
              padding: 4px 2px 4px 6px; }
        [data-local-hide] { display: none !important; }
        /* Detail sheet: the app's panel, as a sheet because a phone has no room
           for a third column. */
        #sheet { position: fixed; inset: 0; z-index: 20; }
        .sheet-bg { position: absolute; inset: 0; background: rgba(0,0,0,.45); }
        .sheet-card {
          position: absolute; left: 0; right: 0; bottom: 0; max-height: 88vh;
          overflow-y: auto; background: var(--panel); color: var(--fg);
          border-radius: 14px 14px 0 0; padding: 16px 15px
          calc(20px + env(safe-area-inset-bottom));
          box-shadow: 0 -8px 30px rgba(0,0,0,.35);
        }
        .sheet-x {
          position: absolute; top: 12px; right: 12px; width: 28px; height: 28px;
          border: 0; border-radius: 99px; background: var(--chip); color: var(--dim);
          font-size: 13px; cursor: pointer;
        }
        .sheet-card h2 { margin: 0 34px 2px 0; font-size: 17px; line-height: 1.25;
                         text-wrap: balance; }
        .sheet-card h3 { margin: 16px 0 7px; font-size: 12px; color: var(--dim);
                         text-transform: uppercase; letter-spacing: .06em; }
        .s-sub { font-size: 12.5px; color: var(--dim); margin-bottom: 12px; }
        .s-acts { display: flex; gap: 6px; flex-wrap: wrap; }
        .btn {
          flex: 1 1 auto; text-align: center; padding: 9px 12px; font: inherit;
          font-size: 13.5px; border-radius: 8px; border: 1px solid var(--line);
          background: var(--chip); color: var(--fg); cursor: pointer;
          text-decoration: none;
        }
        .btn.primary { background: var(--accent); color: #fff; border-color: transparent; }
        .btn.on { background: color-mix(in srgb, var(--accent) 25%, var(--chip)); }
        .s-grid { display: grid; grid-template-columns: 86px 1fr; gap: 5px 10px;
                  margin-top: 14px; font-size: 13px; }
        .s-grid dt { color: var(--dim); }
        .s-tags { display: flex; gap: 5px; flex-wrap: wrap; margin-top: 12px; }
        .s-steps { display: flex; flex-direction: column; gap: 7px; }
        .step { display: flex; align-items: center; gap: 8px; font-size: 13px; }
        .step .dot { width: 8px; height: 8px; border-radius: 99px;
                     background: var(--accent); flex: 0 0 auto; }
        .step .when { color: var(--dim); font-variant-numeric: tabular-nums;
                      margin-left: auto; font-size: 12px; }
        .step button { border: 0; background: var(--chip); color: var(--dim);
                       border-radius: 6px; padding: 3px 7px; font-size: 11px;
                       cursor: pointer; }
        .s-add { display: flex; gap: 6px; margin-top: 10px; flex-wrap: wrap; }
        .s-add select, .s-add input {
          flex: 1 1 40%; font: inherit; font-size: 13px; padding: 7px 9px;
          border: 1px solid var(--line); border-radius: 8px;
          background: var(--chip); color: var(--fg);
        }
        #s-note { width: 100%; font: inherit; font-size: 13.5px; padding: 9px;
                  border: 1px solid var(--line); border-radius: 8px;
                  background: var(--chip); color: var(--fg); resize: vertical; }
        .s-desc { margin-top: 14px; font-size: 13px; color: var(--dim);
                  white-space: pre-wrap; }
        .empty { padding: 44px 18px; text-align: center; color: var(--dim); }
        footer { padding: 14px 12px calc(20px + env(safe-area-inset-bottom));
                 color: var(--dim); font-size: 11.5px; }
        .mk:focus-visible, .lists button:focus-visible, .go:focus-visible,
        input:focus-visible { outline: 2px solid var(--accent); outline-offset: -2px; }
        /* If the page can't save, the marks are a lie — say so rather than
           letting taps look like they landed. */
        [artifact-sync-state="off"] .mk { opacity: .35; pointer-events: none; }
        </style>

        <header>
          <div class="top">
            <h1>Quant Jobs</h1>
            <span class="made" id="made" data-at="\(made)">\(Self.builtBy)</span>
            <button id="refresh" title="Fetch every board again">⟳</button>
          </div>
          <div class="lists" role="tablist">
            <button role="tab" data-list="all" aria-selected="true">All <span class="n" id="n-all"></span></button>
            <button role="tab" data-list="saved" aria-selected="false">★ <span class="n" id="n-saved"></span></button>
            <button role="tab" data-list="applied" aria-selected="false">➤ <span class="n" id="n-applied"></span></button>
            <button role="tab" data-list="hidden" aria-selected="false">◍ <span class="n" id="n-hidden"></span></button>
          </div>
          <input type="search" id="q" placeholder="Filter by role, firm or place"
                 autocomplete="off" autocapitalize="off" spellcheck="false">
          <div class="filters">
            <select id="f-cat" aria-label="Category"></select>
            <select id="f-level" aria-label="Level">
              <option value="">Both</option>
              <option value="intern" selected>Intern</option>
              <option value="newgrad">New grad</option>
            </select>
            <select id="f-days" aria-label="Posted">
              <option value="">Any time</option>
              <option value="7">Last 7d</option>
              <option value="14">Last 14d</option>
              <option value="30">Last 30d</option>
              <option value="90">Last 90d</option>
            </select>
            <select id="f-year" aria-label="Intake year"></select>
            <select id="f-region" aria-label="Region"></select>
            <select id="f-stack" aria-label="Stack to leave out"></select>
            <select id="f-city" aria-label="City"></select>
            <select id="f-firm" aria-label="Firm"></select>
            <select id="f-phd" aria-label="Doctorate">
              <option value="">PhD roles too</option>
              <option value="1">No PhD roles</option>
            </select>
            <select id="f-applied" aria-label="Roles applied to">
              <option value="">Applied: shown</option>
              <option value="roles">Applied: hidden</option>
              <option value="firms">Applied firms: hidden</option>
            </select>
            <select id="f-sort" aria-label="Sort">
              <option value="date">Newest first</option>
              <option value="firm">By firm</option>
              <option value="role">By role</option>
            </select>
            <label id="merge-wrap" title="One row per role, with its locations folded in">
              <input type="checkbox" id="f-merge" checked>Merge
            </label>
            <button id="clear" hidden>Clear</button>
          </div>
        </header>

        <ul artifact-sync id="list">
        \(rows)
        </ul>
        <div class="empty" id="empty" hidden>Nothing in this list.</div>

        <!-- Local scratch UI: the sheet is a view onto a row, never part of the
             saved document, so it lives outside the synced list. -->
        <artifact-local>
        <div id="sheet" hidden>
          <div class="sheet-bg" data-close></div>
          <div class="sheet-card" role="dialog" aria-modal="true" aria-label="Role">
            <button class="sheet-x" data-close aria-label="Close">✕</button>
            <h2 id="s-title"></h2>
            <div class="s-sub" id="s-sub"></div>
            <div class="s-acts">
              <a id="s-open" class="btn primary" target="_blank" rel="noopener">Open Posting</a>
              <button id="s-save" class="btn">Save</button>
              <button id="s-hide" class="btn">Hide</button>
            </div>
            <div class="s-grid" id="s-grid"></div>
            <div id="s-tags" class="s-tags"></div>
            <h3>Application</h3>
            <div id="s-steps" class="s-steps"></div>
            <div class="s-add">
              <select id="s-stage" aria-label="Add a step">
                <option value="Applied">Applied</option>
                <option value="OA">Online assessment</option>
                <option value="Interview">Interview</option>
                <option value="Final">Final round</option>
                <option value="Offer">Offer</option>
                <option value="Rejected">Rejected</option>
                <option value="Withdrawn">Withdrawn</option>
              </select>
              <input type="date" id="s-date" aria-label="Date">
              <button id="s-add" class="btn">Add step</button>
            </div>
            <h3>Notes</h3>
            <textarea id="s-note" rows="3" placeholder="Anything worth remembering"></textarea>
            <div id="s-desc" class="s-desc"></div>
          </div>
        </div>
        </artifact-local>
        <footer id="foot"></footer>

        <script>
        // The app's pipeline. Tapping ➤ walks it, so an application can move on
        // without the laptop; the attribute is what gets saved, the pill just shows it.
        const STAGES = ["", "Applied", "OA", "Interview", "Final", "Offer", "Rejected"];
        const SAT = ["OA", "Interview", "Final"];
        const list = document.getElementById('list');
        const rows = () => [...list.querySelectorAll('.row')];
        let tab = 'all';

        const paint = li => {
          li.querySelector('.pill.stage').textContent = li.dataset.stage || '';
        };

        const inList = li =>
          tab === 'saved'   ? li.dataset.saved === '1' :
          tab === 'applied' ? li.dataset.stage !== '' :
          tab === 'hidden'  ? li.dataset.hidden === '1' :
                              li.dataset.hidden !== '1';

        // Options come from the rows themselves, so a filter can never offer a
        // year or a region the snapshot does not contain.
        function fill(sel, values, label, prefix) {
          const el = document.getElementById(sel);
          el.innerHTML = '<option value="">' + label + '</option>' +
            values.map(v => '<option value="' + v + '">' + prefix + v + '</option>').join('');
        }
        const uniq = f => [...new Set(rows().flatMap(f).filter(Boolean))].sort();

        // The app lets you pick several regions, cities or stacks; a <select> on
        // a phone picks one. So the value is allowed to be a set, joined with a
        // pipe, and matching is "any of". Without this a round trip through the
        // page silently narrowed "Europe and North America" down to "Europe".
        const anyOf = (chosen, field) => {
          const has = (field || '').split('|');
          return chosen.split('|').some(c => has.includes(c));
        };

        // A set that arrived from the app is not one of the options built from
        // the rows, and a <select> silently drops a value it has no option for.
        function offer(id, value) {
          const el = document.getElementById(id);
          if (!value || [...el.options].some(o => o.value === value)) return;
          const o = document.createElement('option');
          o.value = value;
          o.textContent = value.split('|').join(' + ');
          el.append(o);
        }
        fill('f-year', uniq(li => li.dataset.year ? [li.dataset.year] : []),
             'Any year', '');
        fill('f-region', uniq(li => (li.dataset.region || '').split('|')),
             'Anywhere', '');
        fill('f-stack', uniq(li => (li.dataset.stacks || '').split('|')),
             'All stacks', 'No ');
        fill('f-city', uniq(li => (li.dataset.city || '').split('|')), 'Any city', '');
        fill('f-firm', uniq(li => [li.dataset.firm]), 'All firms', '');
        // The app's sidebar categories, named the way it names them.
        const CATS = {swe: 'Software Engineering', 'quant-trading': 'Quant Trading',
                      'quant-research': 'Quant Research', hardware: 'Hardware / FPGA',
                      data: 'Data / ML'};
        const cats = uniq(li => (li.dataset.cat || '').split('|'))
                       .filter(c => c !== 'all');
        document.getElementById('f-cat').innerHTML =
          '<option value="">Everything</option>' +
          cats.map(c => '<option value="' + c + '">' + (CATS[c] || c) + '</option>').join('');

        const controls = ['q', 'f-cat', 'f-level', 'f-days', 'f-year', 'f-region',
                          'f-city', 'f-firm', 'f-stack', 'f-phd', 'f-applied',
                          'f-sort'];
        const val = id => document.getElementById(id).value;

        // Restores what a row said before any merge folded others into it.
        function unmerge(li) {
          const me = li.querySelector('.me');
          if (me.dataset.plain !== undefined) {
            me.firstChild.textContent = me.dataset.plain;
            delete me.dataset.plain;
          }
          const plus = li.querySelector('.plus');
          if (plus) plus.remove();
        }

        function mergeRows(shown) {
          const visible = rows().filter(li => !li.hasAttribute('data-local-hide'));
          visible.forEach(unmerge);
          if (!document.getElementById('f-merge').checked) return shown;

          const groups = new Map();
          for (const li of visible) {
            const key = li.dataset.role || li.dataset.key;
            if (!groups.has(key)) groups.set(key, []);
            groups.get(key).push(li);
          }
          let folded = 0;
          for (const members of groups.values()) {
            if (members.length < 2) continue;
            // Dated first, newest first — the app's rule for which one leads.
            members.sort((a, b) => (b.dataset.posted || '').localeCompare(a.dataset.posted || ''));
            const [primary, ...rest] = members;
            // Each row's location as a whole. Not split on commas: a single
            // place is already written "Valencia, ES", and splitting turned one
            // Spanish city into two places called Valencia and ES.
            const places = [];
            for (const li of members) {
              const one = (li.querySelector('.me').dataset.plain
                           ?? li.querySelector('.me').firstChild.textContent).trim();
              if (one && !places.includes(one)) places.push(one);
            }
            const me = primary.querySelector('.me');
            if (me.dataset.plain === undefined) me.dataset.plain = me.firstChild.textContent;
            me.firstChild.textContent = places.slice(0, 2).join(' · ');
            const extra = places.length - 2;
            const plus = document.createElement('span');
            plus.className = 'plus';
            // The count is of places, not of rows: two postings in one city are
            // one place, and "+1 more" pointing at a duplicate reads as a bug.
            plus.textContent = extra > 0 ? '+' + extra + ' more' : '';
            if (extra > 0) me.insertBefore(plus, me.querySelector('.age'));
            for (const li of rest) { li.setAttribute('data-local-hide', '1'); folded++; }
          }
          return shown - folded;
        }

        function apply() {
          const q = val('q').trim().toLowerCase();
          const level = val('f-level'), days = val('f-days'), year = val('f-year');
          const region = val('f-region'), stack = val('f-stack'), phd = val('f-phd');
          const cat = val('f-cat'), city = val('f-city'), firm = val('f-firm');
          const applied = val('f-applied');
          // "Hide every role at a firm you've applied to" needs the set of those
          // firms before any row is judged.
          const appliedFirms = new Set(rows().filter(li => li.dataset.stage !== '')
                                             .map(li => li.dataset.firm));
          // Saved, Applied and Hidden honour the search box and nothing else —
          // the same rule the app has. Category, level and date narrow a scrape;
          // applying them to a list of things you are tracking hides the
          // applications you opened the list to find.
          const narrow = tab === 'all';
          let shown = 0;
          for (const li of rows()) {
            const d = li.dataset;
            const ok = inList(li)
              && (!q || d.find.includes(q))
              && (!narrow || !level || (d.levels || d.level || '').split('|').includes(level))
              && (!narrow || (!days || Number(d.days) <= Number(days)))
              // A posting naming no year is kept, as in the app: most name none.
              && (!narrow || (!year || !d.year || d.year === year))
              && (!narrow || (!region || anyOf(region, d.region)))
              // Stack is an exclusion, so it drops rows that name it.
              && (!narrow || (!stack || !anyOf(stack, d.stacks)))
              && (!narrow || (!phd || d.phd !== '1'))
              && (!narrow || (!cat || (d.cat || '').split('|').includes(cat)))
              && (!narrow || (!city || anyOf(city, d.city)))
              && (!narrow || (!firm || d.firm === firm))
              && (!narrow || (applied !== 'roles' || d.stage === ''))
              && (!narrow || (applied !== 'firms' || !appliedFirms.has(d.firm)));
            if (ok) { li.removeAttribute('data-local-hide'); shown++; }
            else { li.setAttribute('data-local-hide', '1'); }
          }

          // One row per role, its other locations folded in — the app's
          // mergeRoles. After filtering, not before, because that is the order
          // the app does it in: a role is merged out of what survived, so
          // narrowing to Zurich does not leave a row claiming four cities.
          //
          // The primary is the most recently posted of the group, so the date
          // on the surviving row is the right one.
          shown = mergeRows(shown);
          document.getElementById('empty').hidden = shown > 0;

          const by = val('f-sort');
          if (by !== window.__sorted) {
            const key = li => by === 'firm' ? li.dataset.firm.toLowerCase()
                            : by === 'role' ? li.querySelector('.ti').textContent.toLowerCase()
                            : '';
            const sorted = rows().sort((a, b) =>
              by === 'date' ? Number(a.dataset.days) - Number(b.dataset.days)
                            : key(a).localeCompare(key(b)));
            // Reordering the synced list is an edit everyone would receive, so the
            // order is applied visually instead.
            sorted.forEach((li, i) => { li.style.order = i; });
            list.style.display = 'flex';
            list.style.flexDirection = 'column';
            window.__sorted = by;
          }

          let active = 0;
          for (const id of controls) {
            const el = document.getElementById(id);
            const on = !!el.value
              && !(id === 'f-level' && el.value === 'intern')
              && !(id === 'f-sort' && el.value === 'date');
            if (el.tagName === 'SELECT') el.classList.toggle('on', on);
            if (on) active++;
          }
          document.getElementById('clear').hidden = active === 0;

          const all = rows();
          document.getElementById('n-all').textContent =
            all.filter(li => li.dataset.hidden !== '1').length;
          document.getElementById('n-saved').textContent =
            all.filter(li => li.dataset.saved === '1').length;
          document.getElementById('n-applied').textContent =
            all.filter(li => li.dataset.stage !== '').length;
          document.getElementById('n-hidden').textContent =
            all.filter(li => li.dataset.hidden === '1').length;
          document.getElementById('foot').textContent = shown + ' of ' + all.length
            + ' shown. ' + (syncNote || 'Marks and filters sync with the Mac app.');
        }

        list.addEventListener('click', e => {
          const b = e.target.closest('.mk');
          if (!b) return;
          const li = b.closest('.row');
          if (b.dataset.act === 'save')
            li.dataset.saved = li.dataset.saved === '1' ? '0' : '1';
          if (b.dataset.act === 'hide')
            li.dataset.hidden = li.dataset.hidden === '1' ? '0' : '1';
          if (b.dataset.act === 'apply') {
            li.dataset.stage = STAGES[(STAGES.indexOf(li.dataset.stage || '') + 1)
                                      % STAGES.length];
            // Only a step you sit can be outstanding, and a fresh one is.
            li.dataset.owed = SAT.includes(li.dataset.stage) ? '1' : '0';
            paint(li);
          }
          apply();
        });

        for (const b of document.querySelectorAll('[role=tab]')) {
          b.onclick = () => {
            tab = b.dataset.list;
            for (const o of document.querySelectorAll('[role=tab]'))
              o.setAttribute('aria-selected', String(o === b));
            apply();
          };
        }
        for (const id of controls) {
          const el = document.getElementById(id);
          el.addEventListener(id === 'q' ? 'input' : 'change', apply);
        }
        document.getElementById('f-merge').addEventListener('change', () => {
          dirtyFilters = true;
          schedulePush();
          apply();
        });
        // What "no filter" means for each control.
        //
        // Empty, for the ten that have an empty option — "Anywhere", "Any city",
        // "Both". Not for the sort, whose options are date/firm/role: handed ""
        // a <select> reports selectedIndex -1 and draws nothing, and Clear was
        // doing exactly that. Worse, the filters sync, so the blank was written
        // to the store, came back on every load, and reached the app — a broken
        // control that pressing Clear could not fix, because Clear caused it.
        function defaultOf(id) {
          const el = document.getElementById(id);
          if (el.tagName !== 'SELECT') return '';
          return [...el.options].some(o => o.value === '') ? '' : el.options[0].value;
        }

        document.getElementById('clear').onclick = () => {
          for (const id of controls) document.getElementById(id).value = defaultOf(id);
          apply();
        };

        // ---- detail sheet: the app's panel, reading and writing the row ----
        const SAT_FULL = {OA: 'submitted', Interview: 'done', Final: 'done'};
        let current = null;
        const $ = id => document.getElementById(id);

        function stepsOf(li) {
          return (li.dataset.steps || '').split(';').filter(Boolean)
            .map(x => { const [stage, at, done] = x.split(','); return {stage, at, done}; });
        }
        function writeSteps(li, arr) {
          const order = STAGES.filter(Boolean);
          arr.sort((a, b) => a.at === b.at ? order.indexOf(a.stage) - order.indexOf(b.stage)
                                           : a.at.localeCompare(b.at));
          li.dataset.steps = arr.map(s => [s.stage, s.at, s.done || ''].join(',')).join(';');
          const last = arr[arr.length - 1];
          li.dataset.stage = last ? last.stage : '';
          li.dataset.owed = last && SAT_FULL[last.stage] && !last.done ? '1' : '0';
          paint(li);
        }
        function ago(d) {
          if (!d) return '';
          const n = Math.round((Date.now() - new Date(d)) / 86400000);
          return n <= 0 ? 'today' : n === 1 ? '1d' : n < 30 ? n + 'd'
               : n < 365 ? Math.round(n / 30) + 'mo' : Math.round(n / 365) + 'y';
        }

        function openSheet(li) {
          current = li;
          const d = li.dataset;
          $('s-title').textContent = d.full || li.querySelector('.ti').textContent;
          $('s-sub').textContent = [d.firm, d.team].filter(Boolean).join(' · ');
          $('s-open').href = li.querySelector('.go').href;
          $('s-save').textContent = d.saved === '1' ? 'Unsave' : 'Save';
          $('s-save').classList.toggle('on', d.saved === '1');
          $('s-hide').textContent = d.hidden === '1' ? 'Unhide' : 'Hide';
          $('s-hide').classList.toggle('on', d.hidden === '1');
          $('s-grid').innerHTML = [['Location', li.querySelector('.me').textContent],
                                   ['Posted', d.posted || '—'],
                                   ['Level', (d.levels || '').split('|').join(', ')],
                                   ['Intake', d.year || '—'],
                                   ['Board', d.board || '—']]
            .map(([k, v]) => '<dt>' + k + '</dt><dd>' + v + '</dd>').join('');
          $('s-tags').innerHTML = (d.tags || '').split('|').filter(Boolean)
            .map(t => '<span class="pill">' + t + '</span>').join('');
          $('s-note').value = d.note || '';
          $('s-desc').textContent = d.desc || '';
          $('s-date').value = new Date().toISOString().slice(0, 10);
          drawSteps();
          $('sheet').hidden = false;
        }

        function drawSteps() {
          const arr = stepsOf(current);
          $('s-steps').innerHTML = arr.length ? '' : '<span class="when">No application recorded.</span>';
          arr.forEach((st, i) => {
            const row = document.createElement('div');
            row.className = 'step';
            const verb = SAT_FULL[st.stage];
            row.innerHTML = '<span class="dot"></span><b>' + st.stage + '</b>' +
              (verb && st.done ? ' <span class="when2">' + verb + ' ' + ago(st.done) + '</span>' : '') +
              '<span class="when">' + st.at + '</span>';
            if (verb && !st.done) {
              const b = document.createElement('button');
              b.textContent = 'mark ' + verb;
              b.onclick = () => { arr[i].done = new Date().toISOString().slice(0,10);
                                  writeSteps(current, arr); drawSteps(); apply(); };
              row.appendChild(b);
            }
            const rm = document.createElement('button');
            rm.textContent = 'remove';
            rm.onclick = () => { arr.splice(i, 1); writeSteps(current, arr);
                                 drawSteps(); apply(); };
            row.appendChild(rm);
            $('s-steps').appendChild(row);
          });
        }

        list.addEventListener('click', e => {
          if (e.target.closest('.mk') || e.target.closest('.go')) return;
          const li = e.target.closest('.row');
          if (li) openSheet(li);
        });
        for (const el of document.querySelectorAll('[data-close]'))
          el.onclick = () => { $('sheet').hidden = true; current = null; };
        $('s-save').onclick = () => {
          current.dataset.saved = current.dataset.saved === '1' ? '0' : '1';
          openSheet(current); apply();
        };
        $('s-hide').onclick = () => {
          current.dataset.hidden = current.dataset.hidden === '1' ? '0' : '1';
          openSheet(current); apply();
        };
        $('s-add').onclick = () => {
          const arr = stepsOf(current);
          arr.push({stage: $('s-stage').value, at: $('s-date').value ||
                    new Date().toISOString().slice(0, 10), done: ''});
          // Recording a later step on its own would leave a pipeline with no
          // start, exactly as the app reasons about it.
          if (!arr.some(x => x.stage === 'Applied'))
            arr.push({stage: 'Applied', at: arr[0].at, done: ''});
          writeSteps(current, arr); drawSteps(); apply();
        };
        $('s-note').addEventListener('change', () => {
          current.dataset.note = $('s-note').value;
        });

        // ---- sync: the same marks and filters here and in the app ----
        //
        // The page is rebuilt from scratch twice a day, so a star tapped on the
        // train has nowhere to live unless something off the phone keeps it. That
        // is /state, which the worker serves out of a KV namespace behind the same
        // password as the page. The Mac app reads and writes the same document.
        //
        // Only what changed is sent. The worker merges by posting and by
        // timestamp, so two clients that both read at breakfast and write at
        // lunch do not delete each other's marks.
        const SYNC = '/state';
        let syncing = false;          // true while incoming state is being applied
        let syncNote = '';
        let dirtyRows = new Set();
        let dirtyFilters = false;
        let pushTimer = null;

        const keyOf = li => li.dataset.key || '';

        function marksOf(li) {
          return {
            saved: li.dataset.saved === '1',
            hidden: li.dataset.hidden === '1',
            note: li.dataset.note || '',
            milestones: stepsOf(li)
              .map(s => ({stage: s.stage, date: s.at, done: s.done || null})),
          };
        }

        function applyMarks(li, t) {
          li.dataset.saved = t.saved ? '1' : '0';
          li.dataset.hidden = t.hidden ? '1' : '0';
          li.dataset.note = t.note || '';
          writeSteps(li, (t.milestones || [])
            .map(s => ({stage: s.stage, at: s.date, done: s.done || ''})));
          paint(li);
        }

        function filterState() {
          const o = {tab, 'f-merge': document.getElementById('f-merge').checked ? '1' : ''};
          for (const id of controls) o[id] = document.getElementById(id).value;
          return o;
        }

        function applyState(d) {
          syncing = true;
          let healed = false;
          const byKey = new Map(rows().map(li => [keyOf(li), li]));
          for (const [key, t] of Object.entries(d.tracked || {})) {
            const li = byKey.get(key);
            // A posting the page no longer lists: left in the document, because
            // the app still has it and dropping it here would delete it there.
            if (li) applyMarks(li, t);
          }
          if (d.filters) {
            if ('f-merge' in d.filters) {
              document.getElementById('f-merge').checked = d.filters['f-merge'] === '1';
            }
            for (const id of controls) {
              if (!(id in d.filters)) continue;
              // After offer(), so a set the app sent — "Europe|North America" —
              // is a real option by the time it is judged, and never mistaken
              // for damage.
              offer(id, d.filters[id]);
              const el = document.getElementById(id);
              el.value = d.filters[id];
              // A value the control cannot hold leaves it blank and unusable.
              // Fixing it here is not enough on its own: the store keeps the bad
              // value and hands it back on the next load, so the repair is
              // pushed as well.
              if (el.tagName === 'SELECT' && el.selectedIndex < 0) {
                el.value = defaultOf(id);
                healed = true;
              }
            }
            if (d.filters.tab) {
              tab = d.filters.tab;
              for (const b of document.querySelectorAll('[role=tab]')) {
                b.setAttribute('aria-selected', String(b.dataset.list === tab));
              }
            }
          }
          syncing = false;
          apply();
          // Written back outside the syncing flag, or the observer would ignore
          // it and the store would stay broken for the other client too.
          if (healed) { dirtyFilters = true; schedulePush(); }
        }

        async function pull() {
          let r;
          try {
            r = await fetch(SYNC, {headers: {Accept: 'application/json'}});
          } catch {
            syncNote = 'offline — marks are not being saved.';
            apply();
            return;
          }
          if (!r.ok) {
            syncNote = r.status === 501
              ? 'no store is bound, so marks are not being saved.'
              : 'sync is unavailable (' + r.status + '), so marks are not being saved.';
            apply();
            return;
          }
          applyState(await r.json());
        }

        function schedulePush() {
          if (syncing) return;
          clearTimeout(pushTimer);
          pushTimer = setTimeout(push, 1200);
        }

        async function push() {
          const at = new Date().toISOString();
          const body = {tracked: {}, filters: null, filtersUpdated: ''};
          for (const li of rows()) {
            if (dirtyRows.has(keyOf(li))) {
              body.tracked[keyOf(li)] = Object.assign(marksOf(li), {updated: at});
            }
          }
          if (dirtyFilters) {
            body.filters = filterState();
            body.filtersUpdated = at;
          }
          if (!dirtyFilters && Object.keys(body.tracked).length === 0) return;
          try {
            const r = await fetch(SYNC, {
              method: 'PUT',
              headers: {'Content-Type': 'application/json'},
              body: JSON.stringify(body),
            });
            if (!r.ok) {
              syncNote = 'that change was not saved (' + r.status + ').';
            } else {
              await r.json();
              dirtyRows.clear();
              dirtyFilters = false;
              syncNote = '';
            }
          } catch {
            syncNote = 'that change was not saved — offline.';
          }
          apply();
        }

        // Watching the rows rather than every button: a mark can change from the
        // list, from the detail sheet, or from a step being added, and a save that
        // silently misses one of those paths is the whole failure mode here.
        new MutationObserver(muts => {
          if (syncing) return;
          for (const m of muts) {
            const li = m.target.closest && m.target.closest('.row');
            if (li) dirtyRows.add(keyOf(li));
          }
          if (dirtyRows.size) schedulePush();
        }).observe(list, {subtree: true, attributes: true, attributeFilter:
          ['data-saved', 'data-hidden', 'data-steps', 'data-note', 'data-stage']});

        for (const id of controls) {
          document.getElementById(id).addEventListener(
            id === 'q' ? 'input' : 'change',
            () => { dirtyFilters = true; schedulePush(); });
        }
        for (const b of document.querySelectorAll('[role=tab]')) {
          b.addEventListener('click', () => { dirtyFilters = true; schedulePush(); });
        }
        document.getElementById('clear').addEventListener('click', () => {
          dirtyFilters = true;
          schedulePush();
        });

        // ---- when this was fetched, in the reader's own timezone ----
        //
        // The page is built wherever the fetch runs, which is a runner in UTC,
        // so formatting the time there told everyone else the wrong one.
        const made = document.getElementById('made');
        (function () {
          const at = new Date(made.dataset.at);
          if (isNaN(at)) return;
          made.textContent = made.textContent + ' ' + at.toLocaleString(undefined,
            {day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit'});
          made.title = at.toString();
        })();

        // ---- refresh: ask the scheduled fetch to run now ----
        //
        // The page cannot scrape — it is a file — so the button asks the thing
        // that builds it to build it again, and reloads when a newer copy
        // exists. Several minutes, mostly Meta.
        const refresh = document.getElementById('refresh');
        const startedAt = new Date(made.dataset.at).getTime();

        function say(text, busy) {
          made.textContent = text;
          refresh.classList.toggle('busy', !!busy);
          refresh.disabled = !!busy;
        }

        async function waitForBuild() {
          for (let i = 0; i < 90; i++) {           // ~15 minutes, then give up
            await new Promise(r => setTimeout(r, 10000));
            let s;
            try { s = await (await fetch('/refresh')).json(); } catch { continue; }
            if (s.status === 'completed' && s.finished
                && new Date(s.finished).getTime() > startedAt) {
              say('fetched — reloading', true);
              location.reload();
              return;
            }
            say('fetching' + '.'.repeat(1 + i % 3), true);
          }
          say('still fetching — reload in a minute', false);
        }

        refresh.onclick = async () => {
          say('asking for a fetch', true);
          let r;
          try {
            r = await fetch('/refresh', {method: 'POST'});
          } catch {
            say('offline', false);
            return;
          }
          if (r.status === 501) {
            say('refreshing is not set up — see the README', false);
            return;
          }
          if (!r.ok) {
            say('could not start a fetch (' + r.status + ')', false);
            return;
          }
          waitForBuild();
        };

        rows().forEach(paint);
        apply();
        pull();
        </script>
        """
    }
}
