import Testing
import Foundation
@testable import QuantJobs

/// Times typing into the search box against a real config folder.
///
///   QUANTJOBS_BENCH_DIR=~/Library/Application\ Support/QuantJobs swift test -c release --filter SearchBenchmark
///
/// The folder is copied first, so nothing in it is touched. Skipped without the
/// variable, since the result depends on how many postings the cache holds.
@Suite(.serialized)
struct SearchBenchmark {
    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QUANTJOBS_BENCH_DIR"] != nil))
    func typingAQuery() async throws {
        let source = URL(fileURLWithPath: (ProcessInfo.processInfo.environment["QUANTJOBS_BENCH_DIR"]!
                                           as NSString).expandingTildeInPath)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.copyItem(at: source, to: directory)
        let previous = ConfigStore.directoryOverride
        let previousSettings = AppSettings.store
        ConfigStore.directoryOverride = directory
        AppSettings.useScratchStore("search-benchmark")
        defer {
            ConfigStore.directoryOverride = previous
            AppSettings.store = previousSettings
            try? FileManager.default.removeItem(at: directory)
        }

        let model = AppModel(runBoards: { _, _, _ in })
        let clock = ContinuousClock()
        let loadStart = clock.now
        await model.reload()
        print("BENCH loaded \(model.jobs.count) postings in \(loadStart.duration(to: clock.now))")

        for (scope, categories, level) in [
            ("swe/intern", Set(["swe"]), Level.intern),
            ("swe/any", Set(["swe"]), Level.any),
            ("all categories/intern", Set(model.navCategories.map(\.name)), Level.intern),
            ("all categories/any", Set(model.navCategories.map(\.name)), Level.any),
        ] {
            model.selectedCategoryIDs = categories
            model.level = level
            model.search = ""
            let first = clock.measure { _ = model.visibleJobs.count }

            let query = "software engineer london"
            var list = Duration.zero, places = Duration.zero, worst = Duration.zero
            for end in query.indices {
                model.search = String(query[...end])
                // What one redraw reads: the table, the status bar, the place picker.
                let a = clock.measure { _ = model.visibleJobs.count; _ = model.visibleJobs.count }
                let b = clock.measure { _ = model.availableContinents; _ = model.availableCities }
                list += a; places += b; worst = max(worst, a + b)
            }
            print("BENCH \(scope), \(model.jobs.count) postings: first list \(first); "
                  + "per keystroke \((list + places) / query.count) "
                  + "(list \(list / query.count), places \(places / query.count)), worst \(worst)")
        }

        // A scrape bumps the results once per board; the next read should only
        // pay for what changed, not re-derive every posting.
        model.search = ""
        _ = model.visibleJobs.count
        model.setSaved(true, for: [model.jobs[0]])
        let rebuilt = clock.measure { _ = model.visibleJobs.count }
        print("BENCH re-filter after the results change: \(rebuilt)")

        // Turn on the narrowing controls together to catch any interaction
        // that unexpectedly forces a fresh full-cache pass.
        model.search = "research"
        model.sinceDays = 90
        model.newOnly = true
        model.intakeFilter = 2027
        model.excludePhD = true
        model.excludedStacks = ["python"]
        model.continentFilter = ["Europe"]
        model.appliedFilter = .roles
        let narrowed = clock.measure { _ = model.visibleJobs.count
            _ = model.availableContinents; _ = model.availableCities }
        print("BENCH combined filters: \(narrowed), \(model.visibleJobs.count) rows")
    }
}
