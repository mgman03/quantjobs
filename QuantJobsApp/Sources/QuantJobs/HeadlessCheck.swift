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

        let level: Level = switch levelName {
        case "newgrad": .newgrad
        case "intern-or-newgrad": .internOrNewgrad
        case "any": .any
        default: .intern
        }

        Task {
            exit(await scrape(categoryName: categoryName, level: level, deep: deep))
        }
        dispatchMain()   // park the main thread; the task above exits the process
    }

    private static func scrape(categoryName: String, level: Level, deep: Bool) async -> Int32 {
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
        let matcher = CategoryMatcher(category)
        let query = ScrapeQuery(category: category, level: level, deep: deep)

        print("scraping \(firms.count) firms  ·  category=\(categoryName)  "
              + "·  level=\(level.rawValue)")

        let collector = Collector()
        await Scraper.run(firms, deep: deep) { result in
            let kept = result.jobs.filter { query.keep($0, matcher: matcher) }
            await collector.add(kept, failure: result.failure, company: result.company.name)
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

            model.setStatus(.favorite, for: [saved])
            model.setStatus(.applied, for: [applied])
            model.setStatus(.hidden, for: [hidden])
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

            reloaded.toggleStatus(.applied, for: [applied])
            print("un-applied      applied=\(reloaded.count(.applied))")

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
            a.groupFilter = "quant"
            a.tagFilter = "hft"
            a.locationFilter = "london"
            a.sinceDays = 14
            a.continentFilter = ["Europe", "Asia"]
            a.cityFilter = ["London"]
            a.newOnly = true
            a.deep = true
            a.mergeRoles = false
            a.showHidden = true
            a.list = .applied
            a.currentSettings.save()      // the view debounces; here, straight through

            let b = AppModel()
            await b.reload()
            let ok = b.selectedCategoryID == "quant-research"
                && b.level == .internOrNewgrad && b.groupFilter == "quant"
                && b.tagFilter == "hft" && b.locationFilter == "london"
                && b.sinceDays == 14
                && b.continentFilter == ["Europe", "Asia"]
                && b.cityFilter == ["London"]
                && b.newOnly && b.deep && !b.mergeRoles && b.showHidden
                && b.list == .applied

            print("settings  category=\(b.selectedCategoryID) level=\(b.level.rawValue) "
                  + "group=\(b.groupFilter ?? "-") tag=\(b.tagFilter ?? "-") "
                  + "since=\(b.sinceDays.map(String.init) ?? "-")")
            print("          continents=\(b.continentFilter.sorted()) "
                  + "cities=\(b.cityFilter.sorted()) list=\(b.list.rawValue)")
            print("          toggles newOnly=\(b.newOnly) deep=\(b.deep) "
                  + "merge=\(b.mergeRoles) showHidden=\(b.showHidden)")
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
            let tracking = TrackedJob(status: .applied, job: withNew,
                                      updated: "2026-08-01", lastSeen: "2026-08-02",
                                      note: "phone screen booked for Tuesday")

            for (name, scheme) in [("detail-light", ColorScheme.light),
                                   ("detail-dark", ColorScheme.dark)] {
                let view = JobDetailContent(job: withNew, tracking: tracking)
                    .frame(width: 340)
                    .background(scheme == .dark ? Color.black : Color.white)
                    .environment(\.colorScheme, scheme)

                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                guard let image = renderer.nsImage,
                      let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:])
                else { continue }

                let url = URL(fileURLWithPath: directory)
                    .appendingPathComponent("\(name).png")
                try? png.write(to: url)
                print("wrote \(url.path)")
            }
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
            func ghost(_ company: String, _ title: String) -> Job {
                Job(company: company, title: title, location: "New York, NY",
                    url: "https://example.com/gone", posted: "2026-01-01",
                    department: "", description: "", ats: .greenhouse,
                    tags: ["quant"], level: "intern")
            }
            let ghostSaved = ghost("Jane Street", "Role That No Longer Exists")
            let ghostHidden = ghost("Jane Street", "Hidden Role That Vanished")
            model.setStatus(.favorite, for: [ghostSaved])
            model.setStatus(.hidden, for: [ghostHidden])

            model.scrape()
            while model.isScraping { try? await Task.sleep(for: .milliseconds(100)) }

            print("delisted  saved kept=\(model.count(.favorite) == 1) "
                  + "flagged=\(model.isDelisted(ghostSaved)) · "
                  + "hidden pruned=\(model.count(.hidden) == 0)")

            print("model     \(model.visibleJobs.count) roles · "
                  + "\(model.firmsRepresented) firms · \(model.failures.count) failed · "
                  + "\(model.newCount) new")

            model.search = "intern"
            print("search    \(model.visibleJobs.count) roles match \"intern\"")
            model.search = ""
            model.sinceDays = 14
            print("since 14d \(model.visibleJobs.count) roles")
            model.sinceDays = nil

            for group in [nil] + AppModel.groups.map(Optional.init) {
                model.groupFilter = group
                print("group     \(AppModel.groupLabel(group).padding(toLength: 10, withPad: " ", startingAt: 0)) "
                      + "\(model.visibleJobs.count) roles · "
                      + "\(model.selectedFirms.count) boards would scrape")
            }
            model.groupFilter = nil
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

            if let victim = model.visibleJobs.first {
                let before = model.visibleJobs.count
                model.setStatus(.hidden, for: [victim])
                let afterHide = model.visibleJobs.count
                model.showHidden = true
                let shown = model.visibleJobs.count
                model.showHidden = false
                print("hiding    \(before) → \(afterHide) hidden, "
                      + "banner says \(model.hiddenInResults), "
                      + "show-hidden restores \(shown)")
                model.setStatus(nil, for: [victim])
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
