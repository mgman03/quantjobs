import Foundation

/// Exports one self-contained HTML page of what the app currently knows, so the
/// list can be read on a phone.
///
/// Deliberately an export rather than a second scraper. A browser can't fetch
/// these boards at all — they send no CORS headers, and half of them are behind
/// Cloudflare — so anything on the web is a snapshot of what this binary already
/// fetched. Re-implementing twenty adapters in JavaScript to avoid that would
/// recreate exactly the duplication the Python CLI was deleted for.
///
/// The page is static and says when it was made. Nothing is uploaded by it; where
/// it goes afterwards is the caller's choice.
@MainActor
enum WebExport {

    static func run(to path: String) async -> Int32 {
        let model = AppModel()
        await model.reload()

        let results = model.visibleJobs.map { payload($0, model.trackedEntry(for: $0)) }
        // Saved and applied come out of the tracking file rather than the results,
        // so a role stays readable here after its board has dropped the posting.
        let saved = model.tracked.values
            .filter(\.saved)
            .sorted { $0.job.company < $1.job.company }
            .map { payload($0.job, $0) }
        let applied = model.tracked.values
            .filter(\.hasApplication)
            .sorted { $0.lastActivityOrDone > $1.lastActivityOrDone }
            .map { payload($0.job, $0) }

        let bundle: [String: Any] = [
            "made": stamp(),
            "results": results, "saved": saved, "applied": applied,
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: bundle),
              let text = String(data: json, encoding: .utf8) else {
            FileHandle.standardError.write(Data("couldn't encode the snapshot\n".utf8))
            return 1
        }

        // A posting whose title contains "</script>" would otherwise end the
        // data block early and take the rest of the page with it. Boards put all
        // sorts in titles, so this is cheaper than finding out.
        let safe = text.replacingOccurrences(of: "</", with: "<\\/")

        do {
            try page(data: safe).write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            FileHandle.standardError.write(Data("couldn't write \(path): \(error)\n".utf8))
            return 1
        }
        print("wrote \(path) — \(results.count) results, \(saved.count) saved, "
              + "\(applied.count) applied")
        return 0
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d MMM yyyy, HH:mm"
        return f.string(from: Date())
    }

    /// Short keys because every row is inlined into the page and a phone may be
    /// on a slow connection.
    private static func payload(_ j: Job, _ e: TrackedJob?) -> [String: Any] {
        var out: [String: Any] = [
            "c": j.company,
            "t": j.shortTitle,
            "l": j.locationDisplay,
            "u": j.url,
            "d": j.effectiveDate,
            "i": j.dateIsInferred,
            "v": j.level,
            "saved": e?.saved == true,
        ]
        if let year = j.intakeYear { out["y"] = year }
        if let m = e?.currentMilestone {
            out["s"] = m.stage.short
            out["done"] = m.stage.isSat ? m.isDone : true
            out["owed"] = e?.isAwaitingYou == true
        }
        return out
    }

    private static func page(data: String) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light dark">
        <title>Quant Jobs</title>
        <style>
        :root {
          /* Neutrals warmed a touch off pure grey so they read as chosen, and
             a semantic amber for "you still owe this" that is not the accent. */
          --bg: #fbfaf8; --fg: #16181d; --dim: #5f6672; --line: #e3e2de;
          --chip: #efeeea; --accent: #2f4fd0; --owed: #a1631a;
        }
        /* The OS preference, then the viewer's own toggle, which must win in
           both directions — a host that stamps data-theme on the root would
           otherwise be overridden by the media query. */
        @media (prefers-color-scheme: dark) { :root { --bg: #101216; --fg: #eceef2;
          --dim: #939aa6; --line: #262a33; --chip: #1c2027; --accent: #7aa2f7;
          --owed: #e0a458; } }
        :root[data-theme="dark"] { --bg: #101216; --fg: #eceef2; --dim: #939aa6;
          --line: #262a33; --chip: #1c2027; --accent: #7aa2f7; --owed: #e0a458; }
        :root[data-theme="light"] { --bg: #fbfaf8; --fg: #16181d; --dim: #5f6672;
          --line: #e3e2de; --chip: #efeeea; --accent: #2f4fd0; --owed: #a1631a; }
        * { box-sizing: border-box; -webkit-text-size-adjust: 100%; }
        body {
          margin: 0; background: var(--bg); color: var(--fg);
          font: 15px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
          padding-bottom: env(safe-area-inset-bottom);
        }
        header {
          position: sticky; top: 0; z-index: 5; background: var(--bg);
          border-bottom: 1px solid var(--line);
          padding: 10px 14px calc(10px + env(safe-area-inset-top)) 14px;
          padding-top: max(10px, env(safe-area-inset-top));
        }
        h1 { margin: 0 0 8px; font-size: 17px; font-weight: 650; }
        h1 span { font-weight: 400; color: var(--dim); font-size: 12px; }
        .tabs { display: flex; gap: 6px; }
        .tabs button {
          flex: 1; padding: 8px 4px; font: inherit; font-size: 13px;
          background: var(--chip); color: var(--fg); border: 0; border-radius: 8px;
          cursor: pointer; -webkit-tap-highlight-color: transparent;
        }
        .tabs button[aria-selected="true"] { background: var(--accent); color: #fff; }
        .tabs button b { font-weight: 600; }
        input[type=search] {
          width: 100%; margin-top: 8px; padding: 9px 11px; font: inherit;
          background: var(--chip); color: var(--fg);
          border: 1px solid var(--line); border-radius: 9px;
        }
        ul { list-style: none; margin: 0; padding: 0; }
        li { border-bottom: 1px solid var(--line); }
        a.row {
          display: block; padding: 11px 14px; color: inherit; text-decoration: none;
        }
        a.row:active { background: var(--chip); }
        .co { font-size: 12px; color: var(--dim); display: flex; gap: 6px;
              align-items: center; flex-wrap: wrap; }
        .ti { font-weight: 600; margin: 1px 0 2px; }
        .me { font-size: 12px; color: var(--dim);
              font-variant-numeric: tabular-nums; }
        a.row:focus-visible, .tabs button:focus-visible, input:focus-visible {
          outline: 2px solid var(--accent); outline-offset: -2px;
        }
        @media (prefers-reduced-motion: reduce) {
          * { animation: none !important; transition: none !important; }
        }
        .tag {
          font-size: 11px; padding: 1px 6px; border-radius: 99px;
          background: var(--chip); color: var(--dim);
        }
        .tag.stage { color: var(--accent); }
        .tag.owed { color: var(--owed); font-weight: 600; }
        .empty { padding: 40px 20px; text-align: center; color: var(--dim); }
        footer { padding: 16px 14px 28px; color: var(--dim); font-size: 12px; }
        </style>
        </head>
        <body>
        <header>
          <h1>Quant Jobs <span id="made"></span></h1>
          <div class="tabs" role="tablist">
            <button role="tab" data-k="results" aria-selected="true">Results <b id="n-results"></b></button>
            <button role="tab" data-k="applied" aria-selected="false">Applied <b id="n-applied"></b></button>
            <button role="tab" data-k="saved" aria-selected="false">Saved <b id="n-saved"></b></button>
          </div>
          <input type="search" id="q" placeholder="Filter by role, firm or place"
                 autocomplete="off" autocapitalize="off" spellcheck="false">
        </header>
        <ul id="list"></ul>
        <footer id="foot"></footer>
        <script id="data" type="application/json">DATA_GOES_HERE</script>
        <script>
        const D = JSON.parse(document.getElementById('data').textContent);
        let tab = 'results';
        document.getElementById('made').textContent = 'snapshot ' + D.made;
        for (const k of ['results', 'applied', 'saved'])
          document.getElementById('n-' + k).textContent = D[k].length;

        const esc = s => (s || '').replace(/[&<>"]/g, c =>
          ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));

        function when(j) {
          if (!j.d) return '';
          const days = Math.round((Date.now() - new Date(j.d)) / 86400000);
          const t = days <= 0 ? 'today' : days === 1 ? '1d' :
                    days < 30 ? days + 'd' :
                    days < 365 ? Math.round(days / 30) + 'mo' :
                                 Math.round(days / 365) + 'y';
          return (j.i ? '~ ' : '') + t;
        }

        function render() {
          const q = document.getElementById('q').value.trim().toLowerCase();
          const rows = D[tab].filter(j => !q ||
            (j.c + ' ' + j.t + ' ' + j.l).toLowerCase().includes(q));
          const list = document.getElementById('list');
          if (!rows.length) {
            list.innerHTML = '<li class="empty">Nothing here.</li>';
          } else {
            list.innerHTML = rows.map(j => {
              const tags = [];
              if (j.s) tags.push('<span class="tag stage">' + esc(j.s) +
                                 (j.owed ? '' : ' done') + '</span>');
              if (j.owed) tags.push('<span class="tag owed">to do</span>');
              if (j.saved && tab !== 'saved') tags.push('<span class="tag">saved</span>');
              if (j.y) tags.push('<span class="tag">\\u2019' + String(j.y).slice(2) + '</span>');
              return '<li><a class="row" href="' + esc(j.u) + '" target="_blank" rel="noopener">' +
                '<div class="co">' + esc(j.c) + tags.join('') + '</div>' +
                '<div class="ti">' + esc(j.t) + '</div>' +
                '<div class="me">' + esc(j.l) + (j.l && j.d ? ' \\u00b7 ' : '') + when(j) + '</div>' +
                '</a></li>';
            }).join('');
          }
          document.getElementById('foot').textContent =
            rows.length + ' of ' + D[tab].length + ' shown \\u00b7 read-only snapshot, ' +
            'made on the Mac. Tap a role to open its posting.';
        }

        for (const b of document.querySelectorAll('[role=tab]')) {
          b.onclick = () => {
            tab = b.dataset.k;
            for (const o of document.querySelectorAll('[role=tab]'))
              o.setAttribute('aria-selected', String(o === b));
            render();
          };
        }
        document.getElementById('q').oninput = render;
        render();
        </script>
        </body>
        </html>
        """.replacingOccurrences(of: "DATA_GOES_HERE", with: data)
    }
}
