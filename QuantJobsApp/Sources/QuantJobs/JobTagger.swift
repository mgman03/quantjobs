import Foundation

/// The CPU parsing applied to each fetched board before its rows reach the UI.
enum JobTagger {
    static func tag(_ jobs: [Job], matchers: [CategoryMatcher],
                    stackMatchers: [CategoryMatcher], deep: Bool,
                    seen: [String: Sighting], today: String) async -> [Job] {
        await ParallelJobMap.compactMap(jobs) { original in
            tagOne(original, matchers: matchers, stackMatchers: stackMatchers,
                   deep: deep, seen: seen, today: today)
        }
    }

    static func tagSerial(_ jobs: [Job], matchers: [CategoryMatcher],
                          stackMatchers: [CategoryMatcher], deep: Bool,
                          seen: [String: Sighting], today: String) -> [Job] {
        jobs.compactMap { tagOne($0, matchers: matchers, stackMatchers: stackMatchers,
                                 deep: deep, seen: seen, today: today) }
    }

    private static func tagOne(_ original: Job, matchers: [CategoryMatcher],
                               stackMatchers: [CategoryMatcher], deep: Bool,
                               seen: [String: Sighting], today: String) -> Job? {
        var job = original
        let raw = RawJob(title: job.title, location: job.location, url: job.url,
                         posted: job.posted, department: job.department,
                         description: job.description)
        let cats = matchers.filter { $0.acceptsCategory(raw, deep: deep) }
        guard !cats.isEmpty else { return nil }
        job.matchedCategories = Set(cats.map(\.name))
        job.matchedStacks = Set(stackMatchers
            .filter { $0.acceptsCategory(raw, deep: deep) }
            .map(\.name))
        let classification = Levels.classification(
            title: job.title, department: job.department)
        job.level = classification.level
        job.matchedLevels = classification.matches
        job.isNew = seen[job.key] == nil && seen[job.legacyKey] == nil
        if job.posted.isEmpty {
            job.firstSeen = Sighting.firstSeen(of: job, in: seen) ?? today
        }
        return job
    }
}
