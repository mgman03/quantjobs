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

        // Every posting worth showing, each once: what the results list shows,
        // plus anything marked, which may no longer be on any board.
        var seen = Set<String>()
        var rows: [(Job, TrackedJob?)] = []
        for job in model.visibleJobs where seen.insert(job.key).inserted {
            rows.append((job, model.trackedEntry(for: job)))
        }
        for entry in model.tracked.values
        where (entry.saved || entry.hasApplication || entry.hidden)
            && seen.insert(entry.job.key).inserted {
            rows.append((entry.job, entry))
        }

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

    private static func stamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d MMM, HH:mm"
        return f.string(from: Date())
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
        let bits = (j.company + " " + j.shortTitle + " " + j.locationDisplay).lowercased()
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
          <li class="row" data-saved="\(e?.saved == true ? 1 : 0)" \
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
            <span class="made">from the Mac · \(made)</span>
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
            <select id="f-level" aria-label="Level">
              <option value="">Any level</option>
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
            <select id="f-phd" aria-label="Doctorate">
              <option value="">PhD roles too</option>
              <option value="1">No PhD roles</option>
            </select>
            <button id="clear" hidden>Clear</button>
          </div>
        </header>

        <ul artifact-sync id="list">
        \(rows)
        </ul>
        <div class="empty" id="empty" hidden>Nothing in this list.</div>
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
        fill('f-year', uniq(li => li.dataset.year ? [li.dataset.year] : []),
             'Any year', '');
        fill('f-region', uniq(li => (li.dataset.region || '').split('|')),
             'Anywhere', '');
        fill('f-stack', uniq(li => (li.dataset.stacks || '').split('|')),
             'All stacks', 'No ');

        const controls = ['q', 'f-level', 'f-days', 'f-year', 'f-region',
                          'f-stack', 'f-phd'];
        const val = id => document.getElementById(id).value;

        function apply() {
          const q = val('q').trim().toLowerCase();
          const level = val('f-level'), days = val('f-days'), year = val('f-year');
          const region = val('f-region'), stack = val('f-stack'), phd = val('f-phd');
          let shown = 0;
          for (const li of rows()) {
            const d = li.dataset;
            const ok = inList(li)
              && (!q || d.find.includes(q))
              && (!level || d.level === level)
              && (!days || Number(d.days) <= Number(days))
              // A posting naming no year is kept, as in the app: most name none.
              && (!year || !d.year || d.year === year)
              && (!region || (d.region || '').split('|').includes(region))
              // Stack is an exclusion, so it drops rows that name it.
              && (!stack || !(d.stacks || '').split('|').includes(stack))
              && (!phd || d.phd !== '1');
            if (ok) { li.removeAttribute('data-local-hide'); shown++; }
            else { li.setAttribute('data-local-hide', '1'); }
          }
          document.getElementById('empty').hidden = shown > 0;

          let active = 0;
          for (const id of controls) {
            const el = document.getElementById(id);
            const on = !!el.value && !(id === 'f-level' && el.value === 'intern');
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
            + ' shown. Marks made here are saved to this page; run ./refresh-web.sh '
            + 'on the Mac to pull in new postings.';
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
        document.getElementById('clear').onclick = () => {
          for (const id of controls) document.getElementById(id).value = '';
          apply();
        };

        rows().forEach(paint);
        apply();
        </script>
        """
    }
}
