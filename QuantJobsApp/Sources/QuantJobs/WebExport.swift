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

        // The marks, from the store, before anything is written.
        //
        // On a runner there is no .tracked.json — it is private and stays on the
        // Mac — so the page was built with no applications on it at all, and the
        // browser's own pull then had nowhere to put them: applyState only marks
        // a row it can find. An application to a firm you have switched off, or
        // to a posting since taken down, was invisible on the page while the app
        // still showed it.
        //
        // A pull, never a push: the page builder is not a client with opinions
        // about your marks, and a failure here should cost the marks, not the
        // page.
        if let cfg = ConfigStore.loadSync(), cfg.isOn {
            do { model.absorbMarks(try await StateSync.pull(cfg)) }
            catch {
                FileHandle.standardError.write(Data(
                    "couldn't read the marks (\(error)); building without them\n".utf8))
            }
        }

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
            <div class="cell">
              <div class="co"><span class="firm">\(esc(j.company))</span>\
        <span class="pill stage"></span><span class="pill owed">to do</span>\
        <span class="pill yr">\(esc(year))</span></div>
              <div class="ti">\(esc(j.shortTitle))</div>
            </div>
            <a class="go" href="\(esc(j.url))" target="_blank" rel="noopener"
               aria-label="Open posting">↗</a>
            <div class="me">\(esc(j.locationDisplay))<span class="age">\
        \(age.isEmpty ? "" : " · " + esc(age))</span></div>
            <div class="marks">
              <button class="mk save" data-act="save" aria-label="Save">★</button>
              <button class="mk apply" data-act="apply" aria-label="Advance stage">➤</button>
              <button class="mk hide" data-act="hide" aria-label="Hide">◍</button>
            </div>
          </li>
        """
    }

    private static func page(rows: String, made: String) -> String {
        """
        <meta charset="utf-8">
        <!-- Without this a phone lays the page out 980px wide and scales the
             result down, so every size below was being read at about 40% —
             11px rows, and marks too small to hit. It is also what makes the
             safe-area insets below non-zero, so viewport-fit=cover rather than
             the default: the header and the sheet already ask for them. -->
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <!-- Tells the browser its own furniture — form controls, the scrollbar,
             the address bar — which way round this page is. -->
        <meta name="color-scheme" content="dark light">
        <meta name="theme-color" content="#1c1c1e" media="(prefers-color-scheme: dark)">
        <meta name="theme-color" content="#f6f5f3" media="(prefers-color-scheme: light)">
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
        /* Several things here are laid out with flex and start out hidden; the
           attribute has to beat the display that gives them. */
        [hidden] { display: none !important; }
        body {
          margin: 0; background: var(--bg); color: var(--fg);
          font: 15px/1.4 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
        }
        header {
          position: sticky; top: 0; z-index: 5; background: var(--bg);
          border-bottom: 1px solid var(--line);
          padding: max(10px, env(safe-area-inset-top))
                   max(12px, env(safe-area-inset-right)) 10px
                   max(12px, env(safe-area-inset-left));
        }
        /* Four rows of controls is a fifth of a phone screen held permanently.
           So scrolling down folds away the two that are not being used while
           reading — the title line and the search box — and scrolling up brings
           them back, the way a phone's own lists do. The tabs and the filters
           stay, because those are what a glance at the header is for. */
        .top, header #q {
          overflow: hidden;
          transition: height .18s ease, opacity .18s ease, margin .18s ease,
                      padding .18s ease;
        }
        .top { display: flex; align-items: baseline; gap: 8px; height: 22px;
               margin-bottom: 9px; }
        header.tight .top { height: 0; margin-bottom: 0; opacity: 0; }
        header.tight #q {
          height: 0; min-height: 0; margin-top: 0; padding-top: 0;
          padding-bottom: 0; border-width: 0; opacity: 0;
        }
        .top h1 { margin: 0; font-size: 16px; font-weight: 650; letter-spacing: -0.01em; }
        #merge-wrap { flex: 0 0 auto; display: inline-flex; align-items: center;
          gap: 6px; font-size: 15px; color: var(--dim); cursor: pointer;
          min-height: 40px; padding: 6px 13px; border: 1px solid var(--line);
          border-radius: 99px; touch-action: manipulation;
          -webkit-tap-highlight-color: transparent; white-space: nowrap; }
        #merge-wrap input { width: 17px; height: 17px; margin: 0;
          accent-color: var(--accent); }
        #merge-wrap:has(:checked) { color: var(--fg); border-color: var(--accent); }
        .plus { font-size: 11px; color: var(--dim); margin-left: 5px; }
        #refresh { font-size: 18px; line-height: 1; background: none; border: 0;
          color: var(--dim); cursor: pointer; padding: 0;
          width: 44px; height: 44px; margin: -12px -12px -12px 0;
          display: flex; align-items: center; justify-content: center;
          touch-action: manipulation; -webkit-tap-highlight-color: transparent; }
        #refresh:hover { color: var(--fg); }
        #refresh[disabled] { cursor: default; opacity: .5; }
        @keyframes spin { to { transform: rotate(360deg); } }
        #refresh.busy { animation: spin 1.1s linear infinite; color: var(--accent); }
        .made { font-size: 11px; color: var(--dim); margin-left: auto;
                font-variant-numeric: tabular-nums; }
        /* The app's Lists sidebar, folded flat because a phone has no room for it. */
        .lists { display: flex; gap: 5px; }
        .lists button {
          flex: 1; padding: 7px 4px; min-height: 44px; border: 0; border-radius: 9px;
          cursor: pointer;
          background: var(--chip); color: var(--fg); font: inherit; font-size: 14px;
          display: flex; align-items: center; justify-content: center; gap: 5px;
          -webkit-tap-highlight-color: transparent; touch-action: manipulation;
        }
        .lists button:active { transform: scale(.97); }
        .lists button[aria-selected="true"] { background: var(--accent); color: #fff; }
        .n { font-variant-numeric: tabular-nums; opacity: .8; font-size: 11px; }
        /* 16px, not the 14px this used to be, and the same for every control
           below: Safari zooms the page in when a field smaller than that takes
           focus, and does not zoom back out — so one tap on the search box left
           the list half off the side of the screen. */
        input[type=search] {
          width: 100%; margin-top: 8px; padding: 10px 12px; font: inherit;
          font-size: 16px; min-height: 44px;
          background: var(--chip); color: var(--fg);
          border: 1px solid var(--line); border-radius: 10px;
        }
        /* One scrollable rail with eleven controls on it, of which three fit.
           Nothing said so: it ended flush at the edge of the screen, which reads
           as the end of the row. The fade is the only thing that says there is
           more, so it follows the scroll — right edge only at the start, both in
           the middle, left only at the end. */
        .filters {
          display: flex; gap: 6px; margin-top: 8px; overflow-x: auto;
          scrollbar-width: none; -webkit-overflow-scrolling: touch;
          padding-bottom: 2px; scroll-padding: 0 12px;
          overscroll-behavior-x: contain;
        }
        .filters::-webkit-scrollbar { display: none; }
        .filters[data-more="right"] {
          -webkit-mask-image: linear-gradient(to right, #000 calc(100% - 34px), transparent);
                  mask-image: linear-gradient(to right, #000 calc(100% - 34px), transparent);
        }
        .filters[data-more="both"] {
          -webkit-mask-image: linear-gradient(to right, transparent, #000 26px,
                                              #000 calc(100% - 34px), transparent);
                  mask-image: linear-gradient(to right, transparent, #000 26px,
                                              #000 calc(100% - 34px), transparent);
        }
        .filters[data-more="left"] {
          -webkit-mask-image: linear-gradient(to right, transparent, #000 26px);
                  mask-image: linear-gradient(to right, transparent, #000 26px);
        }
        .filters select, .filters button {
          flex: 0 0 auto; font: inherit; font-size: 16px; padding: 8px 30px 8px 13px;
          min-height: 40px; border: 1px solid var(--line); border-radius: 99px;
          background: var(--chip); color: var(--fg); cursor: pointer;
          appearance: none; touch-action: manipulation;
          background-image: linear-gradient(45deg, transparent 50%, var(--dim) 50%),
                            linear-gradient(135deg, var(--dim) 50%, transparent 50%);
          background-position: right 14px center, right 9px center;
          background-size: 6px 6px, 6px 6px; background-repeat: no-repeat;
        }
        .filters button {
          padding: 8px 14px; background-image: none; color: var(--accent);
          border-color: transparent; font-weight: 600;
        }
        /* A control that is doing something says so, the way the app's do. */
        .filters select.on {
          background-color: color-mix(in srgb, var(--accent) 22%, var(--chip));
          border-color: color-mix(in srgb, var(--accent) 45%, var(--line));
          color: var(--fg);
        }
        ul { list-style: none; margin: 0; padding: 0; }
        /* Firm and title across the top with the link beside them, and the
           marks on the last line where the location leaves room for them.
           Stacked in a column beside the text, three targets a thumb can hit
           are taller than everything they sit next to, so the row was two
           thirds empty space; along the bottom they cost nothing at all. */
        /* Stage headings in the Applied tab. Sticky, because the point of the
           grouping is knowing which stage you are reading while you scroll. */
        #list.grouped { display: flex; flex-direction: column; }
        .stage-head {
          display: flex; align-items: baseline; gap: 8px; list-style: none;
          position: sticky; top: 0; z-index: 2;
          /* Split, not one shorthand with max() in it: a parser that cannot read
             max() drops the whole declaration and the heading loses its spacing
             entirely, which is harder to notice than a wrong inset. */
          padding: 16px 14px 8px;
          padding-left: max(14px, env(safe-area-inset-left));
          padding-right: max(14px, env(safe-area-inset-right));
          font-size: 12px; font-weight: 650; letter-spacing: .04em;
          color: var(--dim); text-transform: uppercase;
          background: var(--bg); border-bottom: 1px solid var(--line);
        }
        .stage-head .sh-n {
          font-weight: 500; text-transform: none; letter-spacing: 0;
          font-size: 12px; color: var(--dim); opacity: .8;
        }
        .stage-head .sh-owed {
          margin-left: auto; font-weight: 500; text-transform: none;
          letter-spacing: 0; font-size: 11px; color: var(--owed);
          border: 1px solid var(--owed); border-radius: 99px; padding: 1px 8px;
        }
        .row {
          display: grid; grid-template-columns: minmax(0, 1fr) auto;
          grid-template-areas: "cell cell" "me marks";
          align-items: center; column-gap: 6px;
          padding: 7px max(12px, env(safe-area-inset-right))
                   7px max(12px, env(safe-area-inset-left));
          border-bottom: 1px solid var(--line); background: var(--panel);
          touch-action: manipulation;
        }
        /* The link shares the title's area rather than taking a column of its
           own: a column would be as wide as the three marks below it, and the
           titles would be reading 130px narrower to make room for one arrow. */
        .cell { grid-area: cell; min-width: 0; padding-right: 42px; }
        .go { grid-area: cell; justify-self: end; align-self: start; }
        .me { grid-area: me; }
        .marks { grid-area: marks; display: flex; margin-right: -6px; }
        .row:active { background: color-mix(in srgb, var(--fg) 7%, var(--panel)); }
        /* 44 by 40 rather than 28 by 24, and side by side. One of these three
           makes the row disappear and its neighbour advances an application, so
           a near miss is expensive; 24px apart, up a narrow column, is not
           enough separation for a thumb. */
        .mk {
          width: 44px; height: 40px; border: 0; border-radius: 8px; cursor: pointer;
          background: transparent; color: var(--dim); font-size: 15px; line-height: 1;
          -webkit-tap-highlight-color: transparent; touch-action: manipulation;
          -webkit-user-select: none; user-select: none; -webkit-touch-callout: none;
        }
        .mk:active { background: var(--chip); }
        .row[data-saved="1"] .save { color: var(--star); }
        .row:not([data-stage=""]) .apply { color: var(--accent); }
        .row[data-hidden="1"] .hide { color: var(--fg); }
        .row[data-hidden="1"] .cell, .row[data-hidden="1"] .me { opacity: .45; }
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
        .go { color: var(--dim); text-decoration: none; font-size: 17px;
              width: 44px; min-height: 44px; margin-right: -8px;
              display: flex; align-items: center; justify-content: center;
              touch-action: manipulation; -webkit-tap-highlight-color: transparent; }
        .go:active { background: var(--chip); border-radius: 8px; }
        [data-local-hide] { display: none !important; }
        /* Detail sheet: the app's panel, as a sheet because a phone has no room
           for a third column. */
        #sheet { position: fixed; inset: 0; z-index: 20; }
        .sheet-bg { position: absolute; inset: 0; background: rgba(0,0,0,.45);
                    touch-action: none; }
        .sheet-card {
          position: absolute; left: 0; right: 0; bottom: 0;
          /* dvh, not vh: vh on a phone is the height with the address bar
             retracted, so the last line of a long description sat under the
             browser's own toolbar with nothing to scroll. */
          max-height: 88vh; max-height: 88dvh;
          overflow-y: auto; overscroll-behavior: contain;
          background: var(--panel); color: var(--fg);
          border-radius: 16px 16px 0 0;
          padding: 0 max(15px, env(safe-area-inset-right))
                   calc(20px + env(safe-area-inset-bottom))
                   max(15px, env(safe-area-inset-left));
          box-shadow: 0 -8px 30px rgba(0,0,0,.35);
          transition: transform .22s cubic-bezier(.2,.8,.2,1);
        }
        #sheet.dragging .sheet-card { transition: none; }
        /* The title and the way out ride along with the scroll, so a long
           description cannot carry the close button off the top of the sheet. */
        .sheet-head {
          position: sticky; top: 0; z-index: 1; background: var(--panel);
          padding: 8px 0 10px; margin-bottom: 2px;
          border-bottom: 1px solid transparent;
          touch-action: none;                 /* the drag-to-dismiss handle */
        }
        .sheet-card.scrolled .sheet-head { border-bottom-color: var(--line); }
        /* The grip: what says this sheet can be pulled down. */
        .grab { width: 36px; height: 4px; border-radius: 99px; background: var(--line);
                margin: 0 auto 10px; }
        .sheet-x {
          position: absolute; top: 4px; right: -6px; width: 44px; height: 44px;
          border: 0; border-radius: 99px; background: transparent; color: var(--dim);
          font-size: 15px; cursor: pointer; touch-action: manipulation;
          -webkit-tap-highlight-color: transparent;
        }
        .sheet-x:active { background: var(--chip); }
        .sheet-card h2 { margin: 0 44px 2px 0; font-size: 17px; line-height: 1.25;
                         text-wrap: balance; }
        .sheet-card h3 { margin: 16px 0 7px; font-size: 12px; color: var(--dim);
                         text-transform: uppercase; letter-spacing: .06em; }
        .s-sub { font-size: 12.5px; color: var(--dim); margin: 0 44px 0 0; }
        .s-acts { display: flex; gap: 6px; flex-wrap: wrap; margin-top: 12px; }
        /* Whatever is behind the sheet stays where it was; without this, dragging
           a sheet that is already at its top scrolls the list underneath it. */
        body.sheet-open { overflow: hidden; }
        .btn {
          flex: 1 1 auto; padding: 11px 14px; font: inherit;
          font-size: 15px; min-height: 44px; border-radius: 10px;
          border: 1px solid var(--line);
          background: var(--chip); color: var(--fg); cursor: pointer;
          text-decoration: none; touch-action: manipulation;
          display: flex; align-items: center; justify-content: center;
          -webkit-tap-highlight-color: transparent;
        }
        .btn:active { transform: scale(.98); }
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
                       border-radius: 7px; padding: 8px 11px; font-size: 12px;
                       min-height: 36px; cursor: pointer;
                       touch-action: manipulation; }
        .s-add { display: flex; gap: 6px; margin-top: 10px; flex-wrap: wrap; }
        .s-add select, .s-add input {
          flex: 1 1 40%; font: inherit; font-size: 16px; padding: 10px 11px;
          min-height: 44px;
          border: 1px solid var(--line); border-radius: 9px;
          background: var(--chip); color: var(--fg);
        }
        #s-note { width: 100%; font: inherit; font-size: 16px; padding: 11px;
                  border: 1px solid var(--line); border-radius: 9px;
                  background: var(--chip); color: var(--fg); resize: vertical; }
        .s-desc { margin-top: 14px; font-size: 13px; color: var(--dim);
                  white-space: pre-wrap; }
        .empty { padding: 44px 18px; text-align: center; color: var(--dim); }
        .empty p { margin: 0 0 16px; }
        .empty .btn { display: inline-flex; flex: 0 0 auto; }
        /* Undo, because one of the three marks makes the row disappear and it
           is 44px from the two that do not. */
        #toast {
          position: fixed; left: 50%; transform: translateX(-50%); z-index: 30;
          bottom: calc(16px + env(safe-area-inset-bottom));
          display: flex; align-items: center; gap: 10px;
          max-width: min(92vw, 420px); padding: 4px 6px 4px 16px;
          border-radius: 99px; font-size: 14px;
          background: var(--chip); color: var(--fg);
          border: 1px solid var(--line); box-shadow: 0 6px 24px rgba(0,0,0,.4);
        }
        #toast button {
          border: 0; background: transparent; color: var(--accent); font: inherit;
          font-weight: 650; padding: 9px 14px; min-height: 40px; border-radius: 99px;
          cursor: pointer; touch-action: manipulation;
          -webkit-tap-highlight-color: transparent;
        }
        footer { padding: 14px max(12px, env(safe-area-inset-right))
                          calc(20px + env(safe-area-inset-bottom))
                          max(12px, env(safe-area-inset-left));
                 color: var(--dim); font-size: 11.5px; }
        .mk:focus-visible, .lists button:focus-visible, .go:focus-visible,
        input:focus-visible { outline: 2px solid var(--accent); outline-offset: -2px; }
        /* If the page can't save, the marks are a lie — say so rather than
           letting taps look like they landed. */
        [artifact-sync-state="off"] .mk { opacity: .35; pointer-events: none; }

        /* ---- wider than a phone ----
           Everything above is built for a thumb, and it applied at every width:
           on a laptop a row stretched the whole window, leaving a thousand
           pixels of nothing between the title on the left and the star, send
           and hide buttons pinned to the far right, so the eye had to cross the
           screen to connect a row to its own controls. Capping the column fixes
           that without a second layout — the header bar and its rule still span
           the window, only their contents are reined in.

           One breakpoint, not a redesign: this page is read on a phone, and a
           desktop layout it does not have would be more to keep in step for
           less. */
        @media (min-width: 760px) {
          header > *, #list, footer { max-width: 900px; margin-inline: auto; }
          /* An input is inline-block, and auto margins do not centre one — so
             it sat left while everything above and below it was centred. */
          header > #q { display: block; }
          /* Room for every filter, so the rail has nothing left to scroll and
             drops its fade on its own — railFade clears data-more as soon as
             the contents fit. */
          .filters { flex-wrap: wrap; overflow-x: visible; }
        }
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
            <button id="clear" hidden>✕ Clear</button>
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
          </div>
        </header>

        <ul artifact-sync id="list">
        \(rows)
        </ul>
        <div class="empty" id="empty" hidden>
          <p id="empty-why">Nothing in this list.</p>
          <button id="empty-clear" class="btn" hidden>Clear the filters</button>
        </div>

        <!-- Local scratch UI: the sheet is a view onto a row, never part of the
             saved document, so it lives outside the synced list. -->
        <artifact-local>
        <div id="toast" hidden role="status" aria-live="polite">
          <span id="toast-say"></span><button id="toast-undo">Undo</button>
        </div>
        <div id="sheet" hidden>
          <div class="sheet-bg" data-close></div>
          <div class="sheet-card" role="dialog" aria-modal="true" aria-label="Role">
            <div class="sheet-head">
              <div class="grab"></div>
              <button class="sheet-x" data-close aria-label="Close">✕</button>
              <h2 id="s-title"></h2>
              <div class="s-sub" id="s-sub"></div>
            </div>
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
        // without the laptop; each tap writes a step, which is what gets saved —
        // the stage attribute and the pill are both read back off those.
        const STAGES = ["", "Applied", "OA", "Interview", "Final", "Offer", "Rejected"];
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

        // The stages a row can be at, in pipeline order, named as the app names
        // them. Withdrawn is last because it is an ending rather than a step.
        const GROUPS = [
          ['Applied', 'Applied'], ['OA', 'Online assessment'],
          ['Interview', 'Interview'], ['Final', 'Final round'],
          ['Offer', 'Offer'], ['Rejected', 'Rejected'],
        ];

        function groupByStage(shown) {
          for (const h of document.querySelectorAll('.stage-head')) h.remove();
          list.classList.toggle('grouped', tab === 'applied');
          if (tab !== 'applied' || !shown) {
            // Leaving the tab: the grouping owned the order, so the sort has to
            // be told it is no longer current or it will not re-run.
            if (window.__grouped) { window.__sorted = null; window.__grouped = false; }
            return;
          }
          window.__grouped = true;

          const visible = rows().filter(li => !li.hasAttribute('data-local-hide'));
          let order = 0;
          for (const [stage, label] of GROUPS) {
            const members = visible.filter(li => li.dataset.stage === stage);
            if (!members.length) continue;
            const owed = members.filter(li => li.dataset.owed === '1').length;

            const head = document.createElement('li');
            head.className = 'stage-head';
            head.style.order = order++;
            head.innerHTML = '<span class="sh-name"></span>'
              + '<span class="sh-n"></span>'
              + (owed ? '<span class="sh-owed"></span>' : '');
            head.querySelector('.sh-name').textContent = label;
            head.querySelector('.sh-n').textContent = members.length;
            if (owed) head.querySelector('.sh-owed').textContent = owed + ' to do';
            list.append(head);

            // Newest activity first inside a stage, which is what the app sorts
            // the Applied list by — what is happening, not when it was posted.
            members.sort((a, b) => (b.dataset.posted || '').localeCompare(a.dataset.posted || ''));
            for (const li of members) li.style.order = order++;
          }
        }

        // Every posting a row stands for.
        //
        // A merged row covers several — one role in eight cities is one row —
        // and marking it has to mark all of them, exactly as the app does (see
        // AppModel.edit). Marking only the visible one leaves the folded copies
        // unmarked, so they come back unstarred the moment merging is turned
        // off; and because which copy leads is decided by posting date, a
        // rebuild can hand the lead to a different posting and the star looks
        // like it moved on its own. That is the whole of "saved does not sync".
        //
        // Recorded here rather than read back off the DOM, because the
        // data-local-hide attribute that hides a folded row is the same one the
        // filter pass uses, so the two are indistinguishable afterwards.
        const foldedInto = new WeakMap();
        const targets = li => foldedInto.get(li) || [li];
        const spread = (li, fn) => { for (const r of targets(li)) fn(r); };

        function mergeRows(shown) {
          const visible = rows().filter(li => !li.hasAttribute('data-local-hide'));
          visible.forEach(li => { unmerge(li); foldedInto.delete(li); });
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
            foldedInto.set(primary, members);
          }
          return shown - folded;
        }

        const head = document.querySelector('header');
        const rail = document.querySelector('.filters');
        const search = document.getElementById('q');

        // scrollTo with options is not everywhere, and neither is smooth.
        const glide = (el, to) => {
          try { el.scrollTo({[to.left === undefined ? 'top' : 'left']:
                             to.left === undefined ? to.top : to.left,
                             behavior: 'smooth'}); }
          catch (e) { try { el.scrollLeft = to.left || 0; el.scrollTop = to.top || 0; }
                      catch (e2) {} }
        };
        // Changing what the list contains while parked halfway down it leaves you
        // reading a different list from wherever the old one happened to reach.
        const toTop = () => { if (window.scrollY > 0) glide(window, {top: 0}); };

        // Which way the rail can still go, so the fade can say so.
        function railFade() {
          const room = rail.scrollWidth - rail.clientWidth;
          if (room < 8) { rail.removeAttribute('data-more'); return; }
          const l = rail.scrollLeft > 4, r = rail.scrollLeft < room - 4;
          rail.dataset.more = l && r ? 'both' : r ? 'right' : 'left';
        }
        rail.addEventListener('scroll', railFade, {passive: true});
        window.addEventListener('resize', railFade);

        // The header is four rows of controls, a fifth of the screen, and two of
        // them are of no use while reading. So they fold away on the way down and
        // come back on the way up — never while the search box is in use, because
        // hiding what is narrowing the list is how a list turns into a mystery.
        let lastY = 0, settling = 0;
        const fold = want => {
          if (want === head.classList.contains('tight')) return;
          head.classList.toggle('tight', want);
          // Folding shortens the page, and the browser answers by moving the
          // scroll to keep what you were reading in place. That arrives as a
          // scroll of its own, which read as a change of direction and folded
          // the header straight back — so its own after-effects are ignored.
          settling = Date.now() + 350;
        };
        window.addEventListener('scroll', () => {
          const y = Math.max(0, window.scrollY);
          if (Date.now() < settling) { lastY = y; return; }
          const dy = y - lastY;
          if (Math.abs(dy) < 8) return;
          lastY = y;
          if (search.value || document.activeElement === search) { fold(false); return; }
          if (y <= 150) { fold(false); return; }
          // Down folds it away at once; coming back takes a deliberate pull, so
          // a thumb that wobbles mid-scroll does not make the header flicker.
          if (dy > 0) fold(true);
          else if (dy <= -24) fold(false);
        }, {passive: true});
        search.addEventListener('focus', () => fold(false));

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

          // The Applied tab is a pipeline, not a list — the app groups it by stage
          // with a count and a "to do" badge on each, and reading them in that
          // order is the point of the tab. Headers are real elements ordered
          // into place, because the list is a flex column and the sort already
          // positions rows that way.
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

          // After the sort, never before: the sort assigns an order to every row
          // and would wipe the one the grouping just set — which is what left the
          // headers stacked at the top with the rows scattered underneath.
          groupByStage(shown);

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
          document.getElementById('clear').textContent = '✕ Clear ' + active;
          railFade();

          // An empty list that says only "nothing here" is a dead end on a phone,
          // where the filter doing the hiding is off the side of the screen.
          if (shown === 0) {
            document.getElementById('empty-why').textContent = active
              ? (q ? 'Nothing matches “' + val('q').trim() + '” with these filters.'
                   : 'Nothing matches these filters.')
              : tab === 'all' ? 'Nothing in this snapshot yet.'
              : tab === 'saved' ? 'Nothing saved yet. Tap ★ on a row.'
              : tab === 'applied' ? 'No applications recorded yet. Tap ➤ on a row.'
              : 'Nothing hidden.';
            document.getElementById('empty-clear').hidden = active === 0;
          }

          // Counted the way the list is drawn. With merging on, one role posted
          // in eight cities is one row, so counting the postings said 995 above
          // a list of 615 — the tab disagreeing with what it opens.
          const all = rows();
          const count = pick => {
            const hits = all.filter(pick);
            if (!document.getElementById('f-merge').checked) return hits.length;
            return new Set(hits.map(li => li.dataset.role || li.dataset.key)).size;
          };
          document.getElementById('n-all').textContent =
            count(li => li.dataset.hidden !== '1');
          document.getElementById('n-saved').textContent =
            count(li => li.dataset.saved === '1');
          document.getElementById('n-applied').textContent =
            count(li => li.dataset.stage !== '');
          document.getElementById('n-hidden').textContent =
            count(li => li.dataset.hidden === '1');
          document.getElementById('foot').textContent = shown + ' of '
            + count(() => true) + ' shown. '
            + (syncNote || 'Marks and filters sync with the Mac app.');
        }

        // Undo. ◍ takes the row out of the list and sits next to the two marks
        // you reach for most, so a near miss costs something; without this the
        // only way back was to go and find the row again in the Hidden tab.
        let undoing = null, undoTimer = null;
        function offerUndo(said, restore) {
          undoing = restore;
          document.getElementById('toast-say').textContent = said;
          document.getElementById('toast').hidden = false;
          clearTimeout(undoTimer);
          undoTimer = setTimeout(hideToast, 6000);
        }
        function hideToast() { document.getElementById('toast').hidden = true;
                               undoing = null; }
        document.getElementById('toast-undo').onclick = () => {
          const back = undoing;
          hideToast();
          if (back) back();
        };

        list.addEventListener('click', e => {
          const b = e.target.closest('.mk');
          if (!b) return;
          const li = b.closest('.row');
          const group = targets(li);
          const was = group.map(r => [r, {saved: r.dataset.saved, hidden: r.dataset.hidden,
                                          stage: r.dataset.stage, owed: r.dataset.owed,
                                          steps: r.dataset.steps}]);
          if (b.dataset.act === 'save') {
            const to = li.dataset.saved === '1' ? '0' : '1';
            for (const r of group) r.dataset.saved = to;
          }
          if (b.dataset.act === 'hide') {
            const to = li.dataset.hidden === '1' ? '0' : '1';
            for (const r of group) r.dataset.hidden = to;
          }
          // Advanced once, from the row that was tapped, and the result copied
          // to the rest — not advanced separately on each, which would move a
          // folded copy on from whatever stage it happened to be at.
          if (b.dataset.act === 'apply') {
            advance(li);
            const steps = stepsOf(li);
            for (const r of group) if (r !== li) writeSteps(r, steps.map(x => ({...x})));
          }
          const said = b.dataset.act === 'save'
              ? (li.dataset.saved === '1' ? 'Saved' : 'Removed from saved')
            : b.dataset.act === 'hide'
              ? (li.dataset.hidden === '1' ? 'Hidden' : 'Back in the list')
            : (li.dataset.stage ? 'Marked ' + li.dataset.stage
                                : 'Application cleared');
          offerUndo(said, () => {
            for (const [r, d] of was) { Object.assign(r.dataset, d); paint(r); }
            apply();
          });
          apply();
        });

        /// One tap of ➤ moves the row on one stage, and writes that as a step.
        ///
        /// It used to set data-stage alone. Only the steps are sent to the store,
        /// so the tap went up as an empty history and came back erased by the
        /// next pull — the phone's quickest mark was the one that did not last.
        function advance(li) {
          const next = STAGES[(STAGES.indexOf(li.dataset.stage || '') + 1)
                              % STAGES.length];
          if (!next) { writeSteps(li, []); return; }   // round the loop, and clear
          const today = new Date().toISOString().slice(0, 10);
          const arr = stepsOf(li);
          arr.push({stage: next, at: today, done: ''});
          // A later step on its own would leave a pipeline with no start, exactly
          // as the sheet and the app reason about it.
          if (!arr.some(x => x.stage === 'Applied'))
            arr.push({stage: 'Applied', at: arr[0].at, done: ''});
          writeSteps(li, arr);
        }

        for (const b of document.querySelectorAll('[role=tab]')) {
          b.onclick = () => {
            tab = b.dataset.list;
            for (const o of document.querySelectorAll('[role=tab]'))
              o.setAttribute('aria-selected', String(o === b));
            toTop();
            apply();
          };
        }
        for (const id of controls) {
          const el = document.getElementById(id);
          el.addEventListener(id === 'q' ? 'input' : 'change', apply);
          // Not while typing: the search box is at the top already, and pulling
          // the page about under the keyboard is worse than staying put.
          if (id !== 'q') el.addEventListener('change', toTop);
        }
        document.getElementById('f-merge').addEventListener('change', () => {
          dirtyFilters = true;
          schedulePush();
          apply();
        });
        // Back to the defaults rather than to blank. Ten of the twelve controls
        // have an empty option — "Anywhere", "Any city", "Both" — and for those
        // empty is right. The sort does not: handed "" a <select> reports
        // selectedIndex -1 and draws nothing, which is what Clear was doing.
        // Worse, the filters sync, so the blank was written to the store, came
        // back on every load and reached the app — a control left broken by the
        // one button meant to fix filters.
        //
        // Named where the default is not simply empty, derived from the options
        // otherwise, so a control added later cannot be blanked by someone
        // forgetting to list it here.
        const DEFAULTS = {'f-level': 'intern', 'f-sort': 'date'};
        function defaultOf(id) {
          if (id in DEFAULTS) return DEFAULTS[id];
          const el = document.getElementById(id);
          if (el.tagName !== 'SELECT') return '';
          return [...el.options].some(o => o.value === '') ? '' : el.options[0].value;
        }

        function clearFilters() {
          for (const id of controls) document.getElementById(id).value = defaultOf(id);
          glide(rail, {left: 0});
          toTop();
          apply();
        }
        document.getElementById('clear').onclick = clearFilters;
        document.getElementById('empty-clear').onclick = clearFilters;

        // ---- detail sheet: the app's panel, reading and writing the row ----
        const SAT_FULL = {OA: 'submitted', Interview: 'done', Final: 'done'};
        let current = null;
        let sheetPushed = false;
        const $ = id => document.getElementById(id);
        const card = document.querySelector('.sheet-card');
        const grip = document.querySelector('.sheet-head');

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

        // Reopened rather than opened when a button inside the sheet redraws it,
        // which must not stack a second history entry or scroll it back to the top.
        function openSheet(li) {
          const reopening = current === li && !$('sheet').hidden;
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
          if (reopening) return;
          card.scrollTop = 0;
          card.classList.remove('scrolled');
          card.style.transform = '';
          // Whatever is behind stops scrolling, so a flick meant for the sheet
          // does not carry the list away underneath it.
          document.body.classList.add('sheet-open');
          // Back is how you leave anything on a phone. Without an entry of its
          // own the gesture left the page — and on a page behind a password
          // that means the browser prompt again.
          if (!sheetPushed) {
            try { history.pushState({sheet: 1}, ''); sheetPushed = true; } catch (e) {}
          }
        }

        function closeSheet(fromHistory) {
          $('sheet').hidden = true;
          current = null;
          card.style.transform = '';
          document.body.classList.remove('sheet-open');
          // Popping our own entry, unless the pop is what closed it.
          if (sheetPushed && !fromHistory) { try { history.back(); } catch (e) {} }
          sheetPushed = false;
        }

        window.addEventListener('popstate', () => {
          if (!$('sheet').hidden) closeSheet(true);
        });
        document.addEventListener('keydown', e => {
          if (e.key === 'Escape' && !$('sheet').hidden) closeSheet();
        });

        // A shadow under the title once there is something above it.
        card.addEventListener('scroll', () => {
          card.classList.toggle('scrolled', card.scrollTop > 2);
        }, {passive: true});

        // Pull the sheet down to put it away — the gesture the grip is promising.
        // Only from the head, and only from the top of its scroll, so it can
        // never fight the sheet's own scrolling.
        let dragFrom = null;
        grip.addEventListener('touchstart', e => {
          if (card.scrollTop > 0 || e.touches.length !== 1) return;
          dragFrom = e.touches[0].clientY;
          $('sheet').classList.add('dragging');
        }, {passive: true});
        grip.addEventListener('touchmove', e => {
          if (dragFrom === null) return;
          card.style.transform =
            'translateY(' + Math.max(0, e.touches[0].clientY - dragFrom) + 'px)';
        }, {passive: true});
        const endDrag = e => {
          if (dragFrom === null) return;
          const t = e.changedTouches && e.changedTouches[0];
          const dy = Math.max(0, (t ? t.clientY : dragFrom) - dragFrom);
          dragFrom = null;
          $('sheet').classList.remove('dragging');
          card.style.transform = '';
          if (dy > 90) closeSheet();
        };
        grip.addEventListener('touchend', endDrag);
        grip.addEventListener('touchcancel', endDrag);

        // The keyboard covers the bottom half of the screen, which is where the
        // notes box is.
        $('s-note').addEventListener('focus', () => {
          setTimeout(() => {
            try { $('s-note').scrollIntoView({block: 'center', behavior: 'smooth'}); }
            catch (e) {}
          }, 300);
        });

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
                                  spread(current, r => writeSteps(r, arr.map(x => ({...x}))));
                                  drawSteps(); apply(); };
              row.appendChild(b);
            }
            const rm = document.createElement('button');
            rm.textContent = 'remove';
            rm.onclick = () => { arr.splice(i, 1);
                                 spread(current, r => writeSteps(r, arr.map(x => ({...x}))));
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
          el.onclick = () => closeSheet();
        $('s-save').onclick = () => {
          const to = current.dataset.saved === '1' ? '0' : '1';
          spread(current, r => { r.dataset.saved = to; });
          openSheet(current); apply();
        };
        $('s-hide').onclick = () => {
          const to = current.dataset.hidden === '1' ? '0' : '1';
          spread(current, r => { r.dataset.hidden = to; });
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
          spread(current, r => writeSteps(r, arr.map(x => ({...x}))));
          drawSteps(); apply();
        };
        $('s-note').addEventListener('change', () => {
          spread(current, r => { r.dataset.note = $('s-note').value; });
        });

        // ---- sync: the same marks and filters here and in the app ----
        //
        // The page is rebuilt from scratch every hour, so a star tapped on the
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
        let watching = false;

        function say(text, busy) {
          made.textContent = text;
          refresh.classList.toggle('busy', !!busy);
          refresh.disabled = !!busy;
        }

        // The runner's own step names, said in words. Falls through to the raw
        // name for a step this page has not heard of, which is better than
        // saying nothing and cannot go stale into a lie.
        const PHASE = {
          'Set up job': 'starting up',
          'Initialize containers': 'starting up',
          'Cache the build': 'starting up',
          'Build the scraper': 'building the scraper',
          'Let the builder read the marks': 'reading your marks',
          'Fetch every board and write the page': 'reading 193 boards',
          'Keep the page as an artifact': 'almost there',
          'Publish the first-seen ledger': 'almost there',
          'Take the page the fetch built': 'publishing',
          'Declare the deploy': 'publishing',
          'Publish to Cloudflare Pages': 'publishing',
        };

        const mmss = ms => {
          const s = Math.max(0, Math.round(ms / 1000));
          return Math.floor(s / 60) + ':' + String(s % 60).padStart(2, '0');
        };

        const ask = async () => {
          try { return await (await fetch('/refresh')).json(); } catch { return null; }
        };

        // Reloading under someone's fingers loses what they were typing and
        // shuts the sheet they had open. The marks and filters are in the store,
        // so nothing else is at stake — it can simply wait for a quiet moment.
        const quiet = () => {
          const a = document.activeElement;
          const typing = a && ['INPUT', 'TEXTAREA', 'SELECT'].includes(a.tagName);
          return !typing && !document.body.classList.contains('sheet-open');
        };

        /// Follows a run to its end, whoever started it.
        ///
        /// Every four seconds and asking straight away, rather than sleeping ten
        /// first: the old version could sit silent for ten seconds after the
        /// page had already been rebuilt, on top of a wait that is minutes long
        /// to begin with.
        async function watch() {
          if (watching) return;
          watching = true;
          const began = Date.now();
          for (let i = 0; i < 300; i++) {          // 20 minutes, then give up
            const s = await ask();
            if (s && s.status === 'completed' && s.finished
                && new Date(s.finished).getTime() > startedAt) {
              if (quiet()) { say('fetched — reloading', true); location.reload(); return; }
              say('a newer page is ready — reload when you are done', false);
              watching = false;
              return;
            }
            if (s && s.status && s.status !== 'none' && s.status !== 'completed') {
              const since = s.started ? new Date(s.started).getTime() : began;
              const what = PHASE[s.phase] || (s.phase ? s.phase.toLowerCase() : 'fetching');
              say(what + ' · ' + mmss(Date.now() - since), true);
            }
            await new Promise(r => setTimeout(r, 4000));
          }
          say('still fetching — reload in a minute', false);
          watching = false;
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
          watch();
        };

        // A run started from anywhere — the schedule, the Actions tab, another
        // phone — is one this page should be showing too. Without this the
        // button only knew about a fetch it had started itself, so reloading
        // mid-fetch, or opening the page on a second device, showed a stale
        // timestamp and no sign that anything was happening.
        (async () => {
          const s = await ask();
          if (s && s.status && s.status !== 'none' && s.status !== 'completed') watch();
        })();

        rows().forEach(paint);
        apply();
        pull();
        </script>
        """
    }
}
