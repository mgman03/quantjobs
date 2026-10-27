import Foundation

/// Refresh parser-derived fields from a saved cache without blocking the window.
enum CachedJobClassifier {
    static func reclassify(_ jobs: [Job], research: CategoryMatcher?,
                           software: CategoryMatcher?,
                           deep: Bool, seen: [String: Sighting]) async -> [Job] {
        guard !jobs.isEmpty else { return [] }
        let workers = min(4, max(1, ProcessInfo.processInfo.activeProcessorCount))
        let chunkSize = max(1, (jobs.count + workers - 1) / workers)
        var chunks = Array(repeating: [Job](), count: (jobs.count + chunkSize - 1) / chunkSize)

        await withTaskGroup(of: (Int, [Job]).self) { group in
            for index in chunks.indices {
                let start = index * chunkSize
                let end = min(start + chunkSize, jobs.count)
                group.addTask {
                    let classified = (start..<end).map { offset -> Job in
                        var copy = jobs[offset]
                        if let research {
                            let raw = RawJob(title: copy.title, location: copy.location,
                                             url: copy.url, posted: copy.posted,
                                             department: copy.department,
                                             description: copy.description)
                            if research.acceptsCategory(raw, deep: deep) {
                                copy.matchedCategories.insert("quant-research")
                            } else {
                                copy.matchedCategories.remove("quant-research")
                            }
                        }
                        // Older caches marked every "research engineer" as SWE.
                        // Recheck those rows with the narrower current rule.
                        if let software,
                           copy.matchedCategories.contains("swe"),
                           (copy.title + " " + copy.department)
                            .localizedCaseInsensitiveContains("research engineer") {
                            let raw = RawJob(title: copy.title, location: copy.location,
                                             url: copy.url, posted: copy.posted,
                                             department: copy.department,
                                             description: copy.description)
                            if !software.acceptsCategory(raw, deep: deep) {
                                copy.matchedCategories.remove("swe")
                            }
                        }
                        let classification = Levels.classification(
                            title: copy.title, department: copy.department)
                        copy.level = classification.level
                        copy.matchedLevels = classification.matches
                        if copy.posted.isEmpty {
                            copy.firstSeen = Sighting.firstSeen(of: copy, in: seen) ?? ""
                        }
                        return copy
                    }
                    return (index, classified)
                }
            }
            for await (index, classified) in group {
                chunks[index] = classified
            }
        }
        return chunks.flatMap { $0 }
    }
}
