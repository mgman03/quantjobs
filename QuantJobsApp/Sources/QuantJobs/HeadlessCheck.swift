import Foundation
import SwiftUI
import AppKit

/// `QuantJobs --check -c swe -l intern` runs a scrape in the terminal and
/// prints the same table the Python CLI does, so the two can be diffed
/// whenever an adapter or a matcher changes.
enum HeadlessCheck {

    static func run() -> Never {
        let args = CommandLine.arguments
        if args.contains("--model") { runModelCheck() }
        if args.contains("--parse") { runParseCheck() }
        if args.contains("--track") { runTrackCheck() }
        if args.contains("--settings") { runSettingsCheck() }
        if args.contains("--update") { runUpdateCheck() }
        if args.contains("--migrate") { runMigrationCheck() }
        if let i = args.firstIndex(of: "--render"), i + 1 < args.count {
            runRender(to: args[i + 1])
        }

        func flag(_ names: [String], default fallback: String) -> String {
            for name in names {
                if let i = args.firstIndex(of: name), i + 1 < args.count {
                    return args[i + 1]
                }
            }
            return fallback
        }

        let categoryName = flag(["--category", "-c"], default: "swe")
        let levelName = flag(["--level", "-l"], default: "intern")
        let deep = args.contains("--deep")
        // Repeatable, matching the CLI's --no-stack, so the two can be diffed.
        let stacks = Set(args.indices.filter { args[$0] == "--no-stack" && $0 + 1 < args.count }
                             .map { args[$0 + 1] })

        let level: Level = switch levelName {
        case "newgrad": .newgrad
        case "intern-or-newgrad": .internOrNewgrad
        case "any": .any
        default: .intern
        }

        Task {
            exit(await scrape(categoryName: categoryName, level: level, deep: deep,
                              stacks: stacks))
        }
        dispatchMain()   // park the main thread; the task above exits the process
    }

    private static func scrape(categoryName: String, level: Level, deep: Bool,
                               stacks: Set<String> = []) async -> Int32 {
        ConfigStore.seedIfNeeded()
        LocationParser.gazetteer = ConfigStore.loadGazetteer()

        let companies: [Company]
        let categories: [JobCategory]
        do {
            companies = try ConfigStore.loadCompanies().companies
            categories = try ConfigStore.loadCategories()
        } catch {
            FileHandle.standardError.write(Data(
                "couldn't read config in \(ConfigStore.directory.path): \(error)\n".utf8))
            return 1
        }

        guard let category = categories.first(where: { $0.name == categoryName }) else {
            let available = categories.map(\.name).sorted().joined(separator: ", ")
            FileHandle.standardError.write(Data(
                "unknown category '\(categoryName)'. available: \(available)\n".utf8))
            return 1
        }

        let firms = companies.filter { $0.enabled && $0.isConfigured }
        let matcher = CategoryMatcher(
            category, parent: category.parent.flatMap { name in
                categories.first { $0.name == name }
            })
        let query = ScrapeQuery(category: category, level: level, deep: deep)

        print("scraping \(firms.count) firms  ·  category=\(categoryName)  "
              + "·  level=\(level.rawValue)")

        let stackMatchers = categories.filter { $0.parent != nil }.map { CategoryMatcher($0) }
        let collector = Collector()
        await Scraper.run(firms, deep: deep) { result in
            let kept = result.jobs.filter { job in
                guard query.keep(job, matcher: matcher) else { return false }
                guard !stacks.isEmpty else { return true }
                let raw = RawJob(title: job.title, location: job.location, url: job.url,
                                 posted: job.posted, department: job.department,
                                 description: job.description)
                let named = Set(stackMatchers
                    .filter { $0.acceptsCategory(raw, deep: deep) }
                    .map { (m: CategoryMatcher) in m.name })
                return named.isDisjoint(with: stacks)
            }
            await collector.add(kept, failure: result.failure, company: result.company.displayName)
        }

        let jobs = await collector.jobs.deduplicated().sortedByRecency()
        let failures = await collector.failures

        if CommandLine.arguments.contains("--json") {
            for job in jobs {
                print("\(job.company)|\(job.title)|\(job.location)|\(job.posted)")
            }
        } else {
            print(table(jobs))
        }
        print("\n\(jobs.count) roles across \(Set(jobs.map(\.company)).count) firms")
        if !failures.isEmpty {
            print("\(failures.count) board(s) failed:")
            for f in failures { print("  - \(f.company): \(f.reason)") }
        }
        return 0
    }

    /// Points config at a throwaway directory seeded from the real one, so a
    /// check can exercise the actual save paths without touching user data.
    private static func useScratchConfig(_ name: String) {
        let real = ConfigStore.directory
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("quantjobs-\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: scratch,
                                                 withIntermediateDirectories: true)
        for file in ["companies.json", "categories.json", "locations.json"] {
            try? FileManager.default.copyItem(
                at: real.appendingPathComponent(file),
                to: scratch.appendingPathComponent(file))
        }
        ConfigStore.directoryOverride = scratch
    }

    /// Writes tracking the way a version before this one would have: keyed on
    /// company|title|location, and with a single `status` instead of the three
    /// independent marks. The current encoder can't produce that shape, so the
    /// test has to build it, or it would only ever check today's format against
    /// itself.
    private static func writeLegacyTracked(_ tracked: [String: TrackedJob]) {
        let enc = JSONEncoder()
        var out: [String: Any] = [:]
        for (key, entry) in tracked {
            guard let data = try? enc.encode(entry),
                  var dict = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any] else { continue }
            for field in ["saved", "hidden", "milestones"] { dict[field] = nil }
            dict["status"] = entry.hasApplication ? "applied"
                           : entry.hidden ? "hidden" : "favorite"
            out[key] = dict
        }
        try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted])
            .write(to: ConfigStore.trackedURL, options: .atomic)
    }

    /// Tracked roles were keyed on company|title|location; they are keyed on
    /// the posting URL now, and one `status` became three marks plus a dated
    /// timeline. Both migrations have to carry an application across, or someone
    /// loses everything they had recorded.
    private static func runMigrationCheck() -> Never {
        useScratchConfig("migrate")
        let job = Job(company: "Jane Street", title: "Software Engineer",
                      location: "London",
                      url: "https://www.janestreet.com/join-jane-street/position/1/",
                      posted: "", department: "Summer Internship", description: "",
                      ats: .janestreet, tags: ["quant"], level: "intern")
        let legacy = job.legacyKey
        print("old key: \(legacy)")
        print("new key: \(job.key)")

        // Write the file the way the previous version would have: keyed on
        // company|title|location, and with one `status` rather than three marks.
        let entry = TrackedJob(job: job, updated: "2026-01-01",
                               lastSeen: "2026-01-01",
                               milestones: [Milestone(stage: .applied,
                                                      date: "2026-01-01")],
                               note: "phone screen booked")
        writeLegacyTracked([legacy: entry])

        let loaded = ConfigStore.loadTracked()
        let byNew = loaded[job.key]
        print("after load: \(loaded.count) entry/entries")
        print("  found under the new key: \(byNew != nil)")
        print("  application kept:        \(byNew?.stage == .applied)")
        print("  applied date kept:       \(byNew?.appliedOn == "2026-01-01")")
        print("  note kept:               \(byNew?.note == "phone screen booked")")
        print("  old key gone:            \(loaded[legacy] == nil)")

        // And it must be written back, not re-migrated on every load.
        let again = ConfigStore.loadTracked()
        let ok = byNew != nil && byNew?.stage == .applied
            && byNew?.note == "phone screen booked" && loaded[legacy] == nil
            && again[job.key] != nil
        print(ok ? "MIGRATION OK — tracking survived the key change"
                 : "MIGRATION FAILED")
        exit(ok ? 0 : 1)
    }

    /// `--check --update` exercises the version comparison and asks GitHub what
    /// the latest release is. The comparison is what decides whether an update is
    /// ever offered, and a string compare gets `1.0.10` vs `1.0.9` backwards.
    private static func runUpdateCheck() -> Never {
        let cases: [(String, String, Bool)] = [
            ("v1.0.2", "1.0.1", true),
            ("v1.0.1", "1.0.1", false),
            ("v1.0.0", "1.0.1", false),
            ("v1.0.10", "1.0.9", true),      // the one string compare fails
            ("v1.1.0", "1.0.99", true),
            ("v2.0", "1.9.9", true),
            ("v1.0", "1.0.0", false),
            ("1.0.2", "1.0.1", true),        // tags without the v
        ]
        var bad = 0
        for (candidate, installed, want) in cases {
            let got = Updater.isNewer(candidate, than: installed)
            if got != want { bad += 1 }
            print("  \(got == want ? "ok  " : "FAIL") \(candidate) newer than "
                  + "\(installed)? \(got) (expected \(want))")
        }
        print(bad == 0 ? "version comparison OK" : "\(bad) COMPARISON(S) WRONG")

        Task { @MainActor in
            let updater = Updater()
            print("\ninstalled version reports: \(Updater.currentVersion)")
            print("running as a bundle: \(Updater.isBundled) "
                  + "(false from .build, so installing is refused)")
            await updater.check(quietly: false)
            switch updater.phase {
            case .available(let r):
                print("latest on GitHub: \(r.version) — \(r.dmg.lastPathComponent)")
            case .upToDate:
                print("GitHub says we're current")
            case .failed(let why):
                print("check failed: \(why)")
            default:
                print("phase: \(updater.phase)")
            }

            // Run the whole install against a throwaway copy: download the real
            // disk image, mount it, verify the bundle, and swap it in. Only the
            // relaunch is skipped, since nothing is running out of the target.
            if CommandLine.arguments.contains("--install"),
               case .available(let release) = updater.phase {
                let target = FileManager.default.temporaryDirectory
                    .appendingPathComponent("QuantJobs-installtest-\(UUID().uuidString).app")
                print("\ninstalling \(release.version) into a throwaway copy…")
                await updater.install(release, into: target, relaunch: false)

                let plist = target.appendingPathComponent("Contents/Info.plist")
                let landed = (NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"]
                              as? String) ?? "nothing"
                print("  phase after install: \(updater.phase)")
                print("  bundle now reports:  \(landed)")
                // A tag and a plist version can legitimately differ, so the
                // test is "a working bundle landed", not "it matches the tag".
                let failed: Bool = if case .failed = updater.phase { true } else { false }
                let runnable = FileManager.default.isExecutableFile(
                    atPath: target.appendingPathComponent("Contents/MacOS/QuantJobs").path)
                let ok = !failed && landed != "nothing" && runnable
                print(ok ? "INSTALL OK — bundle swapped in and executable"
                         : "INSTALL FAILED")
                try? FileManager.default.removeItem(at: target)
                exit(ok && bad == 0 ? 0 : 1)
            }
            exit(bad == 0 ? 0 : 1)
        }
        dispatchMain()
    }

    /// `--check --track` exercises saving, applying and hiding — including the
    /// promise that a tracked posting outlives the board listing it.
    private static func runTrackCheck() -> Never {
        useScratchConfig("track")

        Task { @MainActor in
            let model = AppModel()
            await model.reload()

            func make(_ company: String, _ title: String) -> Job {
                Job(company: company, title: title, location: "New York, NY",
                    url: "https://example.com/\(title.replacingOccurrences(of: " ", with: "-"))",
                    posted: "2026-07-30", department: "Tech", description: "",
                    ats: .greenhouse, tags: ["quant"], level: "intern",
                    places: LocationParser.parse("New York, NY"))
            }
            let saved = make("Jane Street", "SWE Intern")
            let applied = make("Jump Trading", "Campus SWE")
            let hidden = make("Citadel", "Not For Me")

            model.setSaved(true, for: [saved])
            model.record(.applied, for: [applied])
            model.setHidden(true, for: [hidden])
            model.setNote("phone screen booked", for: applied)

            print("marked    saved=\(model.count(.favorite)) "
                  + "applied=\(model.count(.applied)) hidden=\(model.count(.hidden))")

            model.list = .favorite
            print("saved list      \(model.visibleJobs.count) row(s): "
                  + (model.visibleJobs.first?.title ?? "—"))
            model.list = .applied
            print("applied list    \(model.visibleJobs.count) row(s), note="
                  + "\"\(model.trackedEntry(for: applied)?.note ?? "")\"")

            // The real requirement: nothing was ever scraped in this process,
            // so these rows can only be coming from the stored snapshots.
            let reloaded = AppModel()
            await reloaded.reload()
            reloaded.list = .applied
            let survivor = reloaded.visibleJobs.first
            print("after reload    applied=\(reloaded.count(.applied)) "
                  + "title=\"\(survivor?.title ?? "MISSING")\" "
                  + "url=\(survivor?.url.isEmpty == false ? "kept" : "LOST") "
                  + "note=\"\(reloaded.trackedEntry(for: applied)?.note ?? "")\"")
            print("delisted still shows: "
                  + "\(reloaded.jobs.isEmpty && survivor != nil ? "yes" : "no")")

            // The bug this replaced: hiding a role you'd applied to overwrote
            // the application, because the two shared one field.
            print("\nhiding an application:")
            reloaded.setHidden(true, for: [applied])
            print("  still applied:   \(reloaded.hasApplication(applied))")
            print("  also hidden:     \(reloaded.isHidden(applied))")
            print("  in Applied list: \(reloaded.count(.applied) == 1)")
            print("  note kept:       "
                  + "\"\(reloaded.trackedEntry(for: applied)?.note ?? "")\"")
            reloaded.setHidden(false, for: [applied])

            // …and the other direction: saving a hidden role, then unsaving it,
            // must leave it hidden rather than untracked.
            reloaded.setSaved(true, for: [hidden])
            reloaded.setSaved(false, for: [hidden])
            print("  hidden survives a save/unsave: \(reloaded.isHidden(hidden))")

            // A stage can happen twice: two online assessments is normal, and
            // recording the second used to just move the first one's date.
            print("\nrepeat a stage:")
            let twice = make("Optiver", "Quant Intern")
            reloaded.record(.applied, on: "2026-07-01", for: [twice])
            reloaded.record(.assessment, on: "2026-07-10", for: [twice])
            reloaded.record(.assessment, on: "2026-07-24", repeating: true, for: [twice])
            if let e = reloaded.trackedEntry(for: twice) {
                print("  timeline: " + e.milestones
                        .map { "\($0.stage.short) \($0.date)" }.joined(separator: " → "))
                print("  two assessments kept: \(e.count(of: .assessment) == 2) · "
                      + "stage is still OA: \(e.stage == .assessment) · "
                      + "a plain record still corrects rather than duplicates: ", terminator: "")
                reloaded.record(.assessment, on: "2026-07-25", for: [twice])
                let after = reloaded.trackedEntry(for: twice)
                print("\((after?.count(of: .assessment) ?? 0) == 2)")
            }

            // Intake years, so a stale cycle is visible.
            let intakes = reloaded.availableIntakes
            print("\nintake years present: "
                  + intakes.map { "\($0.year)×\($0.count)" }.joined(separator: ", "))

            print("\nprogress:")
            reloaded.record(.applied, on: "2026-07-20", for: [applied])
            reloaded.record(.assessment, on: "2026-07-27", for: [applied])
            reloaded.record(.interview, for: [applied])
            if let entry = reloaded.trackedEntry(for: applied) {
                print("  stage:      \(entry.stage?.label ?? "—")")
                print("  applied on: \(entry.appliedOn ?? "—") "
                      + "(\(Dates.relative(entry.appliedOn ?? "") ?? "?"))")
                print("  timeline:   " + entry.milestones
                        .map { "\($0.stage.short) \($0.date)" }
                        .joined(separator: " → "))
                print("  order kept: "
                      + "\(entry.milestones.map(\.date) == entry.milestones.map(\.date).sorted())")
            }
            // A rejection is where it ends, even recorded the same day.
            reloaded.record(.rejected, on: reloaded
                .trackedEntry(for: applied)?.date(of: .interview) ?? Dates.today,
                            for: [applied])
            print("  after a rejection dated with the interview: "
                  + "\(reloaded.stage(of: applied)?.label ?? "—") "
                  + "closed=\(reloaded.trackedEntry(for: applied)?.isClosed == true)")

            // It has to survive a restart, being the whole point.
            let third = AppModel()
            await third.reload()
            print("  after reload: \(third.trackedEntry(for: applied)?.milestones.count ?? 0) "
                  + "step(s), at \(third.stage(of: applied)?.label ?? "—")")

            // Stage sections: one block per stage reached, in pipeline order,
            // and folding one takes its rows out of the table.
            print("\nstage sections:")
            let more = [make("DRW", "Platform Engineer Intern"),
                        make("Optiver", "Quant Trader Intern"),
                        make("SIG", "Discovery Program")]
            third.record(.applied, for: [more[0]])
            third.record(.applied, for: [more[1]])
            third.record(.interview, for: [more[1]])
            third.record(.applied, for: [more[2]])
            third.record(.offer, for: [more[2]])
            third.list = .applied
            for group in third.appliedGroups {
                print("  \(group.stage.label): \(group.jobs.count) "
                      + "(\(group.jobs.map(\.company).sorted().joined(separator: ", ")))")
            }
            let order = third.appliedGroups.map(\.stage.order)
            print("  in pipeline order: \(order == order.sorted())")
            print("  empty stages left out: "
                  + "\(third.appliedGroups.allSatisfy { !$0.jobs.isEmpty })")
            let visible = third.visibleJobs.count
            third.toggleCollapsed(.applied)
            let folded = third.appliedGroups
                .filter { !third.isCollapsed($0.stage) }
                .reduce(0) { $0 + $1.jobs.count }
            print("  folding Applied: \(visible) rows → \(folded) shown")
            third.toggleCollapsed(.applied)

            third.clearApplication(for: more + [applied])
            print("\ncleared         applied=\(third.count(.applied)) "
                  + "saved=\(third.count(.favorite)) hidden=\(third.count(.hidden))")

            try? FileManager.default.removeItem(at: ConfigStore.directory)
            exit(0)
        }
        dispatchMain()
    }

    /// `--check --settings` changes every remembered setting, then loads a
    /// fresh model to prove they survive a restart.
    private static func runSettingsCheck() -> Never {
        useScratchConfig("settings")
        let previous = UserDefaults.standard.data(forKey: AppSettings.defaultsKey)

        Task { @MainActor in
            let a = AppModel()
            await a.reload()

            a.selectedCategoryID = "quant-research"
            a.level = .internOrNewgrad
            a.tagFilter = "hft"
            a.locationFilter = "london"
            a.sinceDays = 14
            a.continentFilter = ["Europe", "Asia"]
            a.cityFilter = ["London"]
            a.newOnly = true
            a.deep = true
            a.mergeRoles = false
            a.showHidden = true
            a.appliedFilter = .roles
            a.collapsedStages = [.applied, .rejected]
            a.list = .applied
            a.currentSettings.save()      // the view debounces; here, straight through

            let b = AppModel()
            await b.reload()
            let ok = b.selectedCategoryID == "quant-research"
                && b.level == .internOrNewgrad
                && b.tagFilter == "hft" && b.locationFilter == "london"
                && b.sinceDays == 14
                && b.continentFilter == ["Europe", "Asia"]
                && b.cityFilter == ["London"]
                && b.newOnly && b.deep && !b.mergeRoles && b.showHidden
                && b.appliedFilter == .roles
                && b.collapsedStages == [.applied, .rejected]
                && b.list == .applied

            print("settings  category=\(b.selectedCategoryID) level=\(b.level.rawValue) "
                  + "tag=\(b.tagFilter ?? "-") "
                  + "since=\(b.sinceDays.map(String.init) ?? "-")")
            print("          continents=\(b.continentFilter.sorted()) "
                  + "cities=\(b.cityFilter.sorted()) list=\(b.list.rawValue)")
            print("          toggles newOnly=\(b.newOnly) deep=\(b.deep) "
                  + "merge=\(b.mergeRoles) showHidden=\(b.showHidden) "
                  + "applied=\(b.appliedFilter.rawValue)")
            print("          folded=\(b.collapsedStages.map(\.rawValue).sorted())")
            print(ok ? "ALL SETTINGS SURVIVED A RESTART" : "SETTINGS LOST")

            // Leave the real preferences exactly as they were.
            if let previous {
                UserDefaults.standard.set(previous, forKey: AppSettings.defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: AppSettings.defaultsKey)
            }
            try? FileManager.default.removeItem(at: ConfigStore.directory)
            exit(ok ? 0 : 1)
        }
        dispatchMain()
    }

    /// `--check --parse` reads location strings on stdin and prints how each
    /// one resolved, so the Swift parser can be diffed line-for-line against
    /// the Python one over every string the real boards actually emit.
    private static func runParseCheck() -> Never {
        ConfigStore.seedIfNeeded()
        LocationParser.gazetteer = ConfigStore.loadGazetteer()

        while let line = readLine(strippingNewline: true) {
            let places = LocationParser.parse(line)
            let detail = places
                .map { "\($0.city)/\($0.country)/\($0.continent)" }
                .joined(separator: " | ")
            print("\(LocationParser.format(places, raw: line))\t\(detail)")
        }
        exit(0)
    }

    /// `--check --render <dir>` draws the detail panel offscreen, which is the
    /// only way to eyeball it without a display session.
    private static func runRender(to directory: String) -> Never {
        Task { @MainActor in
            let sample = Job(
                company: "Jane Street",
                title: "Software Engineer Internship — Summer 2027",
                location: "New York, NY",
                url: "https://www.janestreet.com/join-jane-street/position/1234/",
                posted: "2026-07-28",
                department: "Technology / Internship",
                description: "You'll spend the summer on a real team, working on "
                    + "problems that matter to the firm — trading systems, research "
                    + "tooling, or the infrastructure underneath both. We care much "
                    + "more about how you think than which language you already know.",
                ats: .greenhouse,
                tags: ["quant", "prop", "market-maker"],
                level: "intern")

            var withNew = sample
            withNew.isNew = true

            // A plain value, so the snapshot needs no model and touches no file.
            let tracking = TrackedJob(
                job: withNew, updated: "2026-08-01", lastSeen: "2026-08-02",
                saved: true,
                milestones: [Milestone(stage: .applied, date: "2026-07-24"),
                             Milestone(stage: .assessment, date: "2026-07-31")],
                note: "phone screen booked for Tuesday")

            @MainActor
            func write(_ view: some View, _ name: String, _ scheme: ColorScheme) {
                let framed = view
                    .background(scheme == .dark ? Color.black : Color.white)
                    .environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: framed)
                renderer.scale = 2
                guard let image = renderer.nsImage,
                      let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:])
                else { return }
                let url = URL(fileURLWithPath: directory)
                    .appendingPathComponent("\(name).png")
                try? png.write(to: url)
                print("wrote \(url.path)")
            }

            // Untracked as well as tracked: the row of action buttons is widest
            // before anything is marked, which is the state that clipped.
            for (name, scheme) in [("detail-untracked-dark", ColorScheme.dark)] {
                write(JobDetailContent(job: sample, tracking: nil)
                        .frame(width: 300), name, scheme)
            }

            for (name, scheme) in [("detail-light", ColorScheme.light),
                                   ("detail-dark", ColorScheme.dark)] {
                // 300, matching ContentView's `.frame(width: 300)`. It was 340,
                // which is why the snapshot looked fine while the real panel
                // clipped its buttons.
                write(JobDetailContent(job: withNew, tracking: tracking)
                        .frame(width: 300), name, scheme)
                // 250 as well: that's the panel's minimum in a narrow window, and
                // the layout that fits at 300 is not automatically the one that
                // fits there.
                write(JobDetailContent(job: withNew, tracking: tracking)
                        .frame(width: 250), name + "-250", scheme)
            }

            // No snapshot of the filter row: it takes a `@Bindable` model, and
            // ImageRenderer never settles on a view that observes @Observable
            // state — the same reason JobDetailContent is handed plain values.
            exit(0)
        }
        dispatchMain()
    }

    /// `--check --model` drives the real `AppModel` — the path the window uses —
    /// rather than calling the scraper directly, so the incremental ingest,
    /// the live filters and the export all get exercised without a UI.
    private static func runModelCheck() -> Never {
        final class Flag: @unchecked Sendable { var done = false }
        let flag = Flag()
        // Without --record the check must not leave a mark on real config.
        if !CommandLine.arguments.contains("--record") { useScratchConfig("model") }

        Task { @MainActor in
            let model = AppModel()
            await model.reload()
            model.selectedCategoryID = "swe"
            model.level = .intern
            // Recording is off unless asked for, so a check never rewrites
            // the seen-state a real run depends on.
            model.recordState = CommandLine.arguments.contains("--record")

            // Seed two postings that no board will return, from a firm this run
            // does reach — so the "is it still listed?" pass has something real
            // to decide about.
            // Distinct URLs, because the URL *is* the key: sharing one made
            // these two the same posting, and the check was quietly asserting
            // that the second mark overwrote the first.
            func ghost(_ company: String, _ title: String) -> Job {
                let slug = title.replacingOccurrences(of: " ", with: "-").lowercased()
                return Job(company: company, title: title, location: "New York, NY",
                           url: "https://example.com/gone/\(slug)", posted: "2026-01-01",
                           department: "", description: "", ats: .greenhouse,
                           tags: ["quant"], level: "intern")
            }
            let ghostSaved = ghost("Jane Street", "Role That No Longer Exists")
            let ghostHidden = ghost("Jane Street", "Hidden Role That Vanished")
            let ghostBoth = ghost("Jane Street", "Applied Then Hidden Then Closed")
            model.setSaved(true, for: [ghostSaved])
            model.setHidden(true, for: [ghostHidden])
            model.record(.assessment, for: [ghostBoth])
            model.setHidden(true, for: [ghostBoth])

            model.scrape()
            while model.isScraping { try? await Task.sleep(for: .milliseconds(100)) }

            print("delisted  saved kept=\(model.count(.favorite) == 1) "
                  + "flagged=\(model.isDelisted(ghostSaved)) · "
                  + "hidden kept=\(model.count(.hidden) == 2)")
            // The one thing that must never be thrown away: a hidden
            // application whose posting has come down.
            print("          hidden application kept="
                  + "\(model.hasApplication(ghostBoth)) "
                  + "at \(model.stage(of: ghostBoth)?.short ?? "GONE")")

            print("model     \(model.visibleJobs.count) roles · "
                  + "\(model.firmsRepresented) firms · \(model.failures.count) failed · "
                  + "\(model.newCount) new")

            model.search = "intern"
            print("search    \(model.visibleJobs.count) roles match \"intern\"")
            model.search = ""
            model.sinceDays = 14
            print("since 14d \(model.visibleJobs.count) roles")
            model.sinceDays = nil

            print("scrape    \(model.selectedFirms.count) boards would run")
            for group in AppModel.groups {
                let on = model.selectedFirms.count { $0.tags.contains(group) }
                print("          \(AppModel.groupLabel(group).padding(toLength: 10, withPad: " ", startingAt: 0)) \(on)")
            }
            // Adding a firm should cost one board, not the whole selection.
            do {
                let all = model.companies.filter { $0.enabled && $0.isConfigured }
                let victim = all.first!.id
                model.setEnabled(false, for: victim)
                model.scrape()
                while model.isScraping { try? await Task.sleep(for: .milliseconds(50)) }
                let baseline = model.jobs.count

                model.setEnabled(true, for: victim)
                model.scrape()
                let asked = model.total
                while model.isScraping { try? await Task.sleep(for: .milliseconds(50)) }
                print("incremental  re-adding 1 firm fetched \(asked) board(s) "
                      + "of \(all.count) selected — rows \(baseline) → \(model.jobs.count)")

                // Same selection again: nothing left to fetch.
                model.scrape()
                print("             unchanged selection fetched \(model.isScraping ? model.total : 0) board(s)")
                while model.isScraping { try? await Task.sleep(for: .milliseconds(50)) }

                model.scrape(full: true)
                let fullCount = model.total
                while model.isScraping { try? await Task.sleep(for: .milliseconds(50)) }
                print("             \u{2318}R refetched \(fullCount) board(s)")
            }

            // A preset replaces the whole roster; undo has to put it back.
            do {
                let before = model.companies.filter(\.enabled).map(\.name).sorted()
                model.snapshotSelection()
                model.setEnabled(true, for: model.companies.filter { $0.tier <= 1 }.map(\.id))
                model.setEnabled(false, for: model.companies.filter { $0.tier > 1 }.map(\.id))
                let afterPreset = model.companies.filter(\.enabled).count
                model.undoSelectionChange()
                let restored = model.companies.filter(\.enabled).map(\.name).sorted()
                print("undo      \(before.count) enabled → preset \(afterPreset) → "
                      + "undo \(restored.count) · identical=\(restored == before)")
            }

            // An edit made on disk while the app is open must win, not be
            // overwritten the next time something is clicked.
            do {
                model.flushCompanies()      // land our own edits first
                let before = model.companies.filter(\.enabled).count
                var file = try! ConfigStore.loadCompanies()
                for i in file.companies.indices { file.companies[i].enabled = false }
                try! ConfigStore.saveCompanies(file)
                model.reloadCompaniesIfChangedOnDisk()
                let after = model.companies.filter(\.enabled).count
                print("disk edit \(before) enabled in memory → file says 0 → "
                      + "model now \(after) · adopted=\(after == 0)")
            }

            // Re-pointing a firm's board must drop what the old one returned.
            do {
                model.flushCompanies()
                // Any firm with rows on screen; the disk-edit check above may
                // have left everything disabled.
                guard let firm = model.jobs.first?.company else {
                    print("repoint   no rows to test with"); return
                }
                let had = model.jobs.count { $0.company == firm }
                var file = try! ConfigStore.loadCompanies()
                for i in file.companies.indices where file.companies[i].name == firm {
                    file.companies[i].token = "repointed-elsewhere"
                }
                try! ConfigStore.saveCompanies(file)
                model.reloadCompaniesIfChangedOnDisk()
                let left = model.jobs.count { $0.company == firm }
                print("repoint   \(firm): \(had) rows before → \(left) after "
                      + "· dropped=\(had > 0 && left == 0)")
            }

            // Saving an internship must not also mark the new-grad role a firm
            // posts under the same title in the same city.
            do {
                let ldn = model.jobs.filter {
                    $0.company == "Jane Street" && $0.title == "Software Engineer"
                        && $0.location == "London" }
                print("\nJane Street 'Software Engineer' London postings: \(ldn.count)")
                if ldn.count >= 2 {
                    model.setSaved(true, for: [ldn[0]])
                    print("    saved the first: \(model.isSaved(ldn[0]))")
                    print("    second untouched: "
                          + "\(model.trackedEntry(for: ldn[1]) == nil)")
                    print("    distinct keys:    \(ldn[0].key != ldn[1].key)")
                    model.clearAll(for: [ldn[0]])
                }
            }

            // Where does a Jane Street SWE internship go?
            do {
                func js(_ list: [Job]) -> [String] {
                    list.filter { $0.company == "Jane Street" }
                        .map { "\($0.title) @ \($0.locationDisplay)" }
                }
                print("\njane street in model.jobs:      \(js(model.jobs).count)")
                for t in js(model.jobs).prefix(6) { print("    \(t)") }
                model.selectedCategoryID = "swe"
                model.level = .intern
                print("jane street in visibleJobs:     \(js(model.visibleJobs).count)")
                for t in js(model.visibleJobs).prefix(6) { print("    \(t)") }
                print("mergeRoles=\(model.mergeRoles) newOnly=\(model.newOnly) "
                      + "continents=\(model.continentFilter.sorted())")

                model.continentFilter = ["Europe"]
                print("\nwith Europe selected:            \(js(model.visibleJobs).count)")
                for t in js(model.visibleJobs) { print("    \(t)") }
                model.mergeRoles = false
                print("...and merging off:              \(js(model.visibleJobs).count)")
                for t in js(model.visibleJobs) { print("    \(t)") }
                model.mergeRoles = true
                model.continentFilter = []

                model.continentFilter = ["Europe"]
                // Spelled out rather than one boolean chain: the type checker
                // gives up on the inline version.
                let isLondonSWE: (Job) -> Bool = { job in
                    guard job.company == "Jane Street" else { return false }
                    guard job.title == "Software Engineer" else { return false }
                    return job.location == "London"
                }
                if let ldn = model.jobs.first(where: isLondonSWE) {
                    let q = model.query
                    print("\nLondon SWE row against each filter:")
                    print("    category swe:  \(ldn.matchedCategories.contains("swe"))")
                    print("    level intern:  \(ldn.matchedLevels.contains("intern")) "
                          + "levels=\(ldn.matchedLevels.sorted())")
                    print("    liveFilters:   \(q.matchesLiveFilters(ldn, cutoff: q.cutoffDate))")
                    print("    cutoff:        \(q.cutoffDate ?? "none")")
                    print("    posted:        \(ldn.posted.debugDescription)")
                } else { print("\nLondon SWE row not found in model.jobs") }
                model.continentFilter = []

                print("\nevery Jane Street 'Software Engineer' row in model.jobs:")
                for j in model.jobs where j.company == "Jane Street"
                    && j.title == "Software Engineer" {
                    print("    \(j.location): levels=\(j.matchedLevels.sorted())")
                    print("        dept=\(j.department.debugDescription)")
                }
            }

            print("filters   hasExtra=\(model.hasExtraFilters) (expected false)")

            print("\nfirm picker layout:")
            for node in model.firmTree {
                print("  \(AppModel.groupLabel(node.group)):")
                for seg in node.tiers {
                    let label = seg.segment.padding(toLength: 14, withPad: " ",
                                                    startingAt: 0)
                    print("     \(label) \(model.enabledCount(seg.ids))/\(seg.usable)")
                }
            }
            let names = model.firmTree.flatMap { $0.tiers.flatMap(\.ids) }
                .compactMap { model.company($0)?.name }
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            print("  firms A-Z, first 6: \(names.prefix(6).joined(separator: ", "))")

            // "Hide applied" narrows the results to what's left to do, without
            // touching the Applied list it's hiding them into.
            do {
                let picks = Array(model.visibleJobs.prefix(3))
                let before = model.visibleJobs.count
                for job in picks { model.record(.applied, for: [job]) }
                model.appliedFilter = .roles
                let after = model.visibleJobs.count
                // Read with the filter on: the count is what it's holding back,
                // which is zero while it's off.
                let tracked = model.appliedInResults
                model.list = .applied
                let inList = model.visibleJobs.count
                model.list = .results
                // Rows removed vs postings held back: a merged row stands for
                // several postings, and the tally counts postings.
                print("hide app  results \(before) → \(after) "
                      + "(\(tracked) postings held), "
                      + "dropped exactly the \(picks.count) marked row(s): "
                      + "\(before - after == picks.count && tracked >= picks.count) · "
                      + "Applied list still \(inList) · "
                      + "counts as a filter: \(model.hasExtraFilters)")
                // Hiding the *firm* has to reach postings you never marked.
                model.appliedFilter = .firms
                let byFirm = model.visibleJobs.count
                let firms = Set(picks.map(\.company))
                let leftFromThose = model.visibleJobs.count { firms.contains($0.company) }
                print("          by firm: \(before) → \(byFirm), "
                      + "none left from \(firms.count) firm(s): \(leftFromThose == 0), "
                      + "stricter than by role: \(byFirm <= after)")

                model.clearFilters()
                print("          Clear turns it off: \(model.appliedFilter == .show), "
                      + "rows back to \(model.visibleJobs.count)")
                model.clearApplication(for: picks)
            }

            // Stacks are additive: one language alone is a handful, and adding
            // "unspecified" gets you almost everything back. That's the whole
            // point of the design — most roles name no language.
            do {
                let all = model.visibleJobs.count
                model.excludedStacks = ["python"]
                let noPy = model.visibleJobs.count
                model.excludedStacks = ["python", "frontend"]
                let noPyUI = model.visibleJobs.count
                model.excludedStacks = ["cpp", "python", "frontend"]
                let noneNamed = model.visibleJobs.count
                model.excludedStacks = []
                print("stacks    all=\(all) no-python=\(noPy) no-python-ui=\(noPyUI) "
                      + "nothing-named-only=\(noneNamed)")
                print("          removes rather than narrows: "
                      + "\(noPy < all && noPyUI <= noPy) · "
                      + "excluding every stack still keeps the unnamed majority: "
                      + "\(noneNamed > all / 2) · clear restores: "
                      + "\(model.visibleJobs.count == all)")
            }

            if let victim = model.visibleJobs.first {
                let before = model.visibleJobs.count
                model.setHidden(true, for: [victim])
                let afterHide = model.visibleJobs.count
                model.showHidden = true
                let shown = model.visibleJobs.count
                model.showHidden = false
                print("hiding    \(before) → \(afterHide) hidden, "
                      + "banner says \(model.hiddenInResults), "
                      + "show-hidden restores \(shown)")
                model.clearAll(for: [victim])
            }

            // A fresh model should come up populated from the cache the scrape
            // just wrote, which is the whole point of not seeing an empty list.
            let relaunched = AppModel()
            await relaunched.reload()
            print("cache     \(relaunched.jobs.count) rows restored, "
                  + "flagged as cached=\(relaunched.showingCache), "
                  + "age=\(relaunched.cacheDate != nil ? "known" : "MISSING")")

            print("\ntitle tidying (table text ← as posted):")
            for job in model.visibleJobs.prefix(40)
            where job.shortTitle != job.title {
                print("  \(job.shortTitle)\n      ← \(job.title)")
            }

            model.mergeRoles = false
            let unmerged = model.visibleJobs.count
            model.mergeRoles = true
            let merged = model.visibleJobs
            // Boards that state no date get a stand-in from .seen.json, so they
            // stop sinking to the bottom of a newest-first list for good.
            do {
                let undated = model.jobs.filter { $0.posted.isEmpty }
                let rescued = undated.filter { !$0.firstSeen.isEmpty }
                let stillBlank = undated.count - rescued.count
                let sorted = model.visibleJobs
                let lastTen = sorted.suffix(10).count { $0.effectiveDate.isEmpty }
                print("dates     \(undated.count) postings state none · "
                      + "\(rescued.count) given a first-seen date · "
                      + "\(stillBlank) still blank · "
                      + "undated rows stuck at the bottom: \(lastTen)")
            }

            print("\nmerge     \(unmerged) postings → \(merged.count) rows")
            for job in merged.filter(\.isMerged).prefix(5) {
                print("  \(job.company) · \(job.shortTitle) → "
                      + "\(job.variants.count + 1) locations: \(job.locationDisplay)")
            }

            let csv = model.exportText(.csv).split(separator: "\n").count
            let md = model.exportText(.md).split(separator: "\n").count
            print("export    csv=\(csv) lines · md=\(md) lines · "
                  + "json ok=\(model.exportText(.json).hasPrefix("["))")
            flag.done = true
        }

        while !flag.done {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        exit(0)
    }

    /// Accumulates results off the main actor while boards land in parallel.
    private actor Collector {
        var jobs: [Job] = []
        var failures: [ScrapeFailure] = []

        func add(_ batch: [Job], failure: String?, company: String) {
            jobs.append(contentsOf: batch)
            if let failure {
                failures.append(ScrapeFailure(company: company, reason: failure))
            }
        }
    }

    private static func table(_ jobs: [Job]) -> String {
        guard !jobs.isEmpty else { return "no matching roles" }

        let columns: [(String, (Job) -> String, Int)] = [
            ("COMPANY", { $0.company }, 26),
            ("TITLE", { $0.title }, 58),
            ("LOCATION", { $0.location }, 30),
            ("LEVEL", { $0.level.isEmpty ? "-" : $0.level }, 8),
            ("POSTED", { $0.posted.isEmpty ? "-" : $0.posted }, 10),
        ]

        let widths = columns.map { header, value, cap in
            min(cap, max(header.count, jobs.map { value($0).count }.max() ?? 0))
        }

        func row(_ cells: [String]) -> String {
            zip(cells, widths)
                .map { $0.count > $1 ? String($0.prefix($1)) : $0.padding(toLength: $1,
                                                                          withPad: " ",
                                                                          startingAt: 0) }
                .joined(separator: " ")
        }

        var lines = [row(columns.map(\.0)),
                     String(repeating: "─", count: widths.reduce(0, +) + widths.count - 1)]
        var previous = ""
        for job in jobs {
            var cells = columns.map { $0.1(job) }
            if job.company == previous { cells[0] = "" }   // quieter repeated column
            previous = job.company
            lines.append(row(cells))
        }
        return lines.joined(separator: "\n")
    }
}
