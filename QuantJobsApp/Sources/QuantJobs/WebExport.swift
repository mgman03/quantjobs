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

        let html = page(rows: rows.map { row($0.0, $0.1) }.joined(separator: "\n"),
                        made: stamp())
        do {
            try html.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            FileHandle.standardError.write(Data("couldn't write \(path): \(error)\n".utf8))
            return 1
        }
        print("wrote \(path) — \(rows.count) roles")
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
        return """
          <li class="row" data-saved="\(e?.saved == true ? 1 : 0)" \
        data-hidden="\(e?.hidden == true ? 1 : 0)" \
        data-stage="\(esc(stage?.stage.short ?? ""))" \
        data-owed="\(e?.isAwaitingYou == true ? 1 : 0)" \
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

        function apply() {
          const q = document.getElementById('q').value.trim().toLowerCase();
          let shown = 0;
          for (const li of rows()) {
            const ok = inList(li) && (!q || li.dataset.find.includes(q));
            // data-local-* is scratch state: filtering must not be saved as an edit.
            if (ok) { li.removeAttribute('data-local-hide'); shown++; }
            else { li.setAttribute('data-local-hide', '1'); }
          }
          document.getElementById('empty').hidden = shown > 0;
          const all = rows();
          document.getElementById('n-all').textContent =
            all.filter(li => li.dataset.hidden !== '1').length;
          document.getElementById('n-saved').textContent =
            all.filter(li => li.dataset.saved === '1').length;
          document.getElementById('n-applied').textContent =
            all.filter(li => li.dataset.stage !== '').length;
          document.getElementById('n-hidden').textContent =
            all.filter(li => li.dataset.hidden === '1').length;
          document.getElementById('foot').textContent = shown + ' shown · marks made '
            + 'here are saved to this page. Run ./refresh-web.sh on the Mac to pull '
            + 'in new postings.';
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
        document.getElementById('q').oninput = apply;

        rows().forEach(paint);
        apply();
        </script>
        """
    }
}
