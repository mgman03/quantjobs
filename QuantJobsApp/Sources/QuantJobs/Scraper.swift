import Foundation

/// Result of hitting one board.
struct BoardResult: Sendable {
    var company: Company
    var jobs: [Job]
    var failure: String?
    /// How long the board took. Only read by `--check --timing`, but measured
    /// always: the cost of a Date() either side of a network call is nothing,
    /// and a scheduler that guesses at costs deserves a way to check itself.
    var seconds: Double = 0
}

/// Fetches many boards at once. A board that fails is reported and never
/// takes the run down with it.
enum Scraper {

    /// Hit one board and stamp the company's details onto everything it returns.
    static func one(_ c: Company, deep: Bool) async -> BoardResult {
        let started = Date()
        func elapsed() -> Double { Date().timeIntervalSince(started) }
        do {
            let raw = try await Adapters.fetch(c, deep: deep)
            let jobs = await parseJobs(raw, company: c)
            return BoardResult(company: c, jobs: jobs, failure: nil,
                               seconds: elapsed())
        } catch let e as FetchError {
            return BoardResult(company: c, jobs: [],
                               failure: e.errorDescription ?? "failed",
                               seconds: elapsed())
        } catch is CancellationError {
            return BoardResult(company: c, jobs: [], failure: "cancelled",
                               seconds: elapsed())
        } catch {
            return BoardResult(company: c, jobs: [], failure: error.localizedDescription,
                               seconds: elapsed())
        }
    }

    static func parseJobs(_ raw: [RawJob], company: Company) async -> [Job] {
        await ParallelJobMap.compactMap(raw) { makeJob($0, company: company) }
    }

    static func parseJobsSerial(_ raw: [RawJob], company: Company) -> [Job] {
        raw.compactMap { makeJob($0, company: company) }
    }

    private static func makeJob(_ raw: RawJob, company: Company) -> Job? {
        let title = raw.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty,
              !title.localizedCaseInsensitiveContains("No intern program at this time")
        else { return nil }
        return Job(company: company.name, title: raw.title, location: raw.location,
                   url: raw.url, posted: raw.posted, department: raw.department,
                   description: raw.description, ats: company.ats, tags: company.tags,
                   level: Levels.detect(title: raw.title, department: raw.department),
                   places: LocationParser.parse(raw.location),
                   linkStatus: raw.linkStatus)
    }

    /// Roughly how long each kind of board takes. Some sources need hundreds of
    /// requests; keep them in flight without filling every initial worker slot.
    static func expectedCost(_ ats: ATS) -> Int {
        switch ats {
        // A request per posting, eight hundred and fifty of them. Nothing else
        // here is in the same bracket, and starting it last leaves the whole
        // run waiting on one board with everything else long finished.
        case .meta: 1000
        case .citadel: 100
        case .twosigma: 90
        case .eightfold: 80
        case .jibe: 40
        case .workday: 30
        case .oracle: 25          // pages 200 at a time; a big tenant is several
        case .optiver, .amazon: 20
        case .simplify: 15
        case .uber: 10
        case .smartrecruiters: 8
        case .wolverine: 3
        default: 1
        }
    }

    /// Start two expensive boards alongside quick ones. Previously the ten
    /// initial workers all went to the slowest sources, so launch could show
    /// 0/71 boards for a long time even though dozens of one-request boards
    /// were waiting in the queue.
    static func orderedForProgress(_ companies: [Company], workers: Int) -> [Company] {
        let slow = companies.filter { expectedCost($0.ats) >= 20 }
            .sorted { expectedCost($0.ats) > expectedCost($1.ats) }
        let quick = companies.filter { expectedCost($0.ats) < 20 }
            .sorted { expectedCost($0.ats) < expectedCost($1.ats) }
        let warm = workers <= 1 ? 0 : min(slow.count, max(1, workers / 4))
        return Array(slow.prefix(warm)) + quick + Array(slow.dropFirst(warm))
    }

    /// Run every board with at most `workers` in flight, reporting each one as
    /// it lands so the UI can show progress rather than a long blank spinner.
    static func run(_ rawCompanies: [Company], deep: Bool, workers: Int = 10,
                    fetch: @Sendable @escaping (Company, Bool) async -> BoardResult = {
                        company, deep in await one(company, deep: deep)
                    },
                    onBoard: @Sendable @escaping (BoardResult) async -> Void) async {
        guard !rawCompanies.isEmpty else { return }
        let limit = max(1, min(workers, rawCompanies.count))
        let companies = orderedForProgress(rawCompanies, workers: limit)

        await withTaskGroup(of: BoardResult.self) { group in
            var next = 0
            for _ in 0..<limit {
                let c = companies[next]; next += 1
                group.addTask { await fetch(c, deep) }
            }
            while let result = await group.next() {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    break
                }
                await onBoard(result)
                if next < companies.count {
                    let c = companies[next]; next += 1
                    group.addTask { await fetch(c, deep) }
                }
            }
        }
    }
}

// MARK: - Filtering

/// Everything the user can dial in before a scrape, plus the post-fetch filters.
struct ScrapeQuery: Sendable {
    var category: JobCategory
    var level: Level = .intern
    var locations: [String] = []
    var sinceDays: Int? = nil
    var newOnly: Bool = false
    var deep: Bool = false
    var search: String = ""
    var group: String? = nil
    var tag: String? = nil
    /// Empty means "no restriction" for both.
    var continents: Set<String> = []
    var cities: Set<String> = []

    /// Category + level + location, applied as postings arrive.
    func keep(_ job: Job, matcher: CategoryMatcher) -> Bool {
        let raw = RawJob(title: job.title, location: job.location, url: job.url,
                         posted: job.posted, department: job.department,
                         description: job.description)
        guard matcher.accepts(raw, level: level, deep: deep) else { return false }

        if !locations.isEmpty {
            let hay = job.location.lowercased()
            guard locations.contains(where: { hay.contains($0.lowercased()) }) else {
                return false
            }
        }
        return true
    }

    /// Cheap filters re-applied on every keystroke, without re-scraping.
    ///
    /// The firm filters live here as well as in the board selection, so
    /// switching group narrows what's already on screen instead of making the
    /// user re-scrape to see the effect.
    ///
    /// `searchText` is the posting's `Self.searchText(of:)` when the caller has
    /// it to hand; working it out per posting per keystroke was most of the cost
    /// of typing into the search box.
    func matchesLiveFilters(_ job: Job, cutoff: String?, searchText: String? = nil) -> Bool {
        if let group, !job.tags.contains(group) { return false }
        if let tag, !job.tags.contains(tag) { return false }
        // A city is a narrower statement than its continent, so picking one
        // takes over. Applying both as AND made "Europe + London" look like
        // two filters when it only ever meant London.
        if !cities.isEmpty {
            if !job.places.contains(where: { cities.contains($0.city) }) { return false }
        } else if !continents.isEmpty,
                  !job.places.contains(where: { continents.contains($0.continent) }) {
            return false
        }
        if newOnly && !job.isNew { return false }
        if let cutoff, job.posted.isEmpty || job.posted < cutoff { return false }
        return matchesSearch(job, searchText: searchText)
    }

    func matchesSearch(_ job: Job, searchText: String? = nil) -> Bool {
        guard !search.isEmpty else { return true }
        var hay = searchText ?? Self.searchText(of: job)
        var needle = search.lowercased().precomposedStringWithCanonicalMapping
        // Bytes, not Characters: both sides are lowercased already, and
        // String.contains walking Characters was ten times slower — 85ms a
        // keystroke across 37,000 postings.
        // Unwrapped by hand: Glibc's memmem takes non-optional pointers, so
        // passing baseAddress straight through built on macOS only — and the
        // hourly fetch, which builds on Linux, failed from then on. The needle
        // is never empty here, so a nil address can only be an empty haystack.
        return hay.withUTF8 { h in
            needle.withUTF8 { n in
                guard let hp = h.baseAddress, let np = n.baseAddress else { return false }
                return memmem(hp, h.count, np, n.count) != nil
            }
        }
    }

    /// Everything the search box looks through, lowercased.
    static func searchText(of job: Job) -> String {
        "\(job.title) \(job.company) \(job.location) \(job.locationDisplay) \(job.department)"
            .lowercased().precomposedStringWithCanonicalMapping
    }

    var cutoffDate: String? {
        guard let sinceDays else { return nil }
        let day = Calendar(identifier: .gregorian)
            .date(byAdding: .day, value: -sinceDays, to: Date()) ?? Date()
        return Job.dateFormatter.string(from: day)
    }
}

// MARK: - Ordering

extension Array where Element == Job {

    /// De-duplicate on the stable job key, keeping the first sighting.
    /// Drops postings we've already got, keyed on the URL.
    ///
    /// Deliberately not `key`, which is company + title + location and so says
    /// nothing about the level. Jane Street posts a Summer Internship *and* a
    /// Full-Time New Grad "Software Engineer" in London; keyed that way the two
    /// collapsed into one and the new-grad row won, so the internship appeared
    /// while the scrape streamed in and vanished the moment it finished. Two
    /// postings with different URLs are two postings. Rows without a URL fall
    /// back to the old key, since there's nothing better to compare.
    func deduplicated() -> [Job] {
        var seen = Set<String>()
        // Sorted by company first so that when a cross-listed posting collapses
        // the survivor is always the same one — otherwise which firm's name it
        // kept would depend on which board answered first.
        return sorted { $0.company < $1.company }
            .filter { seen.insert($0.dedupKey).inserted }
    }

    /// Folds the same role posted at several locations into one row.
    ///
    /// Firms list one job per office, so "Campus Software Engineer" shows up
    /// five times differing only by city. The extra postings survive as
    /// `variants` — each keeps its own link, and the detail panel lists them.
    ///
    /// `roleKeys`, when given, is each posting's `roleKey` in the same order —
    /// working it out parses the title for places, which across a whole scrape
    /// took most of a second.
    func mergedByRole(roleKeys: [String]? = nil) -> [Job] {
        var order: [String] = []
        var groups: [String: [Job]] = [:]

        for (i, job) in enumerated() {
            let key = roleKeys?[i] ?? job.roleKey
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(job)
        }

        return order.compactMap { key -> Job? in
            guard let members = groups[key], var primary = members.first else { return nil }
            guard members.count > 1 else { return primary }

            // Lead with the most recently posted so the row's date is right.
            let sorted = members.sorted {
                $0.posted.isEmpty != $1.posted.isEmpty
                    ? !$0.posted.isEmpty : $0.posted > $1.posted
            }
            primary = sorted[0]
            primary.places = sorted.flatMap(\.places).uniqued()
            primary.isNew = sorted.contains(where: \.isNew)
            primary.variants = sorted.dropFirst().map {
                Job.Variant(location: $0.location,
                            locationDisplay: LocationParser.format($0.places,
                                                                   raw: $0.location),
                            url: $0.url, posted: $0.posted, key: $0.key)
            }
            return primary
        }
    }

    /// Newest first, undated roles last, company name as the tiebreak.
    func sortedByRecency() -> [Job] {
        sorted { a, b in
            // effectiveDate, so a board that states no dates isn't permanently
            // last — it falls back to when we first saw the posting.
            let (x, y) = (a.effectiveDate, b.effectiveDate)
            if x.isEmpty != y.isEmpty { return !x.isEmpty }
            if x != y { return x > y }
            return a.company.localizedCaseInsensitiveCompare(b.company) == .orderedAscending
        }
    }
}
