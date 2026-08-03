import Foundation

/// Result of hitting one board.
struct BoardResult: Sendable {
    var company: Company
    var jobs: [Job]
    var failure: String?
}

/// Fetches many boards at once. A board that fails is reported and never
/// takes the run down with it.
enum Scraper {

    /// Hit one board and stamp the company's details onto everything it returns.
    static func one(_ c: Company, deep: Bool) async -> BoardResult {
        do {
            let raw = try await Adapters.fetch(c, deep: deep)
            let jobs = raw.map { r in
                Job(company: c.name, title: r.title, location: r.location,
                    url: r.url, posted: r.posted, department: r.department,
                    description: r.description, ats: c.ats, tags: c.tags,
                    level: Levels.detect(title: r.title, department: r.department),
                    places: LocationParser.parse(r.location),
                    linkStatus: r.linkStatus)
            }
            return BoardResult(company: c, jobs: jobs, failure: nil)
        } catch let e as FetchError {
            return BoardResult(company: c, jobs: [],
                               failure: e.errorDescription ?? "failed")
        } catch is CancellationError {
            return BoardResult(company: c, jobs: [], failure: "cancelled")
        } catch {
            return BoardResult(company: c, jobs: [], failure: error.localizedDescription)
        }
    }

    /// Run every board with at most `workers` in flight, reporting each one as
    /// it lands so the UI can show progress rather than a long blank spinner.
    static func run(_ companies: [Company], deep: Bool, workers: Int = 8,
                    onBoard: @Sendable @escaping (BoardResult) async -> Void) async {
        guard !companies.isEmpty else { return }
        let limit = max(1, min(workers, companies.count))

        await withTaskGroup(of: BoardResult.self) { group in
            var next = 0
            for _ in 0..<limit {
                let c = companies[next]; next += 1
                group.addTask { await one(c, deep: deep) }
            }
            while let result = await group.next() {
                await onBoard(result)
                if next < companies.count {
                    let c = companies[next]; next += 1
                    group.addTask { await one(c, deep: deep) }
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
    func matchesLiveFilters(_ job: Job, cutoff: String?) -> Bool {
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
        return matchesSearch(job)
    }

    func matchesSearch(_ job: Job) -> Bool {
        guard !search.isEmpty else { return true }
        let hay = "\(job.title) \(job.company) \(job.location) "
            + "\(job.locationDisplay) \(job.department)"
        return hay.lowercased().contains(search.lowercased())
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
    func deduplicated() -> [Job] {
        var seen = Set<String>()
        return filter { seen.insert($0.key).inserted }
    }

    /// Folds the same role posted at several locations into one row.
    ///
    /// Firms list one job per office, so "Campus Software Engineer" shows up
    /// five times differing only by city. The extra postings survive as
    /// `variants` — each keeps its own link, and the detail panel lists them.
    func mergedByRole() -> [Job] {
        var order: [String] = []
        var groups: [String: [Job]] = [:]

        for job in self {
            let key = "\(job.company.lowercased())|\(job.title.lowercased())"
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
            if a.posted.isEmpty != b.posted.isEmpty { return !a.posted.isEmpty }
            if a.posted != b.posted { return a.posted > b.posted }
            return a.company.localizedCaseInsensitiveCompare(b.company) == .orderedAscending
        }
    }
}
