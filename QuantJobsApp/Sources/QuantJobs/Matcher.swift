import Foundation

/// One alternation regex built from a list of phrases.
///
/// Phrases are word-bounded when they start/end alphanumerically, so "intern"
/// won't fire on "internal" while "c++" still matches. Spaces inside a phrase
/// also match hyphens and slashes, so "co op" catches "Co-Op" and
/// "summer analyst" catches "Summer-Analyst".
struct PhraseMatcher: Sendable {

    private let regex: NSRegularExpression

    init?(_ phrases: [String]) {
        var parts: [String] = []
        for phrase in phrases {
            let p = phrase.trimmingCharacters(in: .whitespaces).lowercased()
            guard !p.isEmpty else { continue }

            let body = p.split(separator: " ")
                .map { NSRegularExpression.escapedPattern(for: String($0)) }
                .joined(separator: #"[\s\-/]+"#)

            let pre = p.first!.isAlphanumeric ? #"(?<![a-z0-9])"# : ""
            let post = p.last!.isAlphanumeric ? #"(?![a-z0-9])"# : ""
            parts.append(pre + body + post)
        }
        guard !parts.isEmpty,
              let rx = try? NSRegularExpression(pattern: parts.joined(separator: "|"),
                                                options: [.caseInsensitive])
        else { return nil }
        regex = rx
    }

    func matches(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        return regex.firstMatch(in: s, range: NSRange(location: 0,
                                                      length: (s as NSString).length)) != nil
    }

    /// Offsets of every hit, used to judge whether a topic runs through a whole
    /// posting or is clustered in a single boilerplate sentence.
    func positions(in s: String) -> [Int] {
        guard !s.isEmpty else { return [] }
        let range = NSRange(location: 0, length: (s as NSString).length)
        return regex.matches(in: s, range: range).map(\.range.location)
    }
}

private extension Character {
    var isAlphanumeric: Bool { isLetter || isNumber }
}

// MARK: - Level vocabulary

enum Levels {

    static let intern = PhraseMatcher([
        "intern", "interns", "internship", "summer analyst", "summer associate",
        "co-op", "coop", "industrial placement", "work placement",
        "placement student", "summer programme", "summer program", "sophomore",
        "freshman", "penultimate", "student programme", "student program",
    ])!

    static let newgrad = PhraseMatcher([
        "new grad", "new graduate", "graduate", "campus", "university",
        "entry level", "junior", "early career", "class of", "trainee",
        "graduate programme", "graduate program", "rotational",
    ])!

    /// Some boards label a role "Graduate Trader" but mean experienced;
    /// these tokens veto a level match outright.
    static let senior = PhraseMatcher([
        "senior", "staff", "principal", "lead", "head of", "director", "vp",
        "vice president", "manager", "experienced", "10+ years", "5+ years",
    ])!

    static func matcher(for key: String) -> PhraseMatcher? {
        switch key {
        case "intern": intern
        case "newgrad": newgrad
        default: nil
        }
    }

    /// Same rule `classify` uses: the level words must appear in the title or
    /// department, and a seniority word in the title vetoes it.
    static func matches(_ level: Level, title: String, department: String) -> Bool {
        let wanted = level.matchKeys
        guard !wanted.isEmpty else { return true }
        let label = "\(title.lowercased()) \(department.lowercased())"
        guard wanted.contains(where: { matcher(for: $0)?.matches(label) ?? false })
        else { return false }
        return !senior.matches(title.lowercased())
    }

    /// Best-guess label for a posting, shown in the Level column.
    static func detect(title: String, department: String) -> String {
        let blob = "\(title) \(department)".lowercased()
        if intern.matches(blob) { return "intern" }
        if newgrad.matches(blob) { return "newgrad" }
        return ""
    }
}

// MARK: - Category matching

/// A category's include/exclude lists, compiled once per scrape.
struct CategoryMatcher: Sendable {
    let name: String
    let include: PhraseMatcher?
    let exclude: PhraseMatcher?

    init(_ category: JobCategory) {
        name = category.name
        include = PhraseMatcher(category.include)
        exclude = PhraseMatcher(category.exclude)
    }

    /// Category only — no level test. Split out so a scrape can record which
    /// categories a posting belongs to once, and switching category afterwards
    /// is a set lookup rather than another trip to the boards.
    func acceptsCategory(_ job: RawJob, deep: Bool) -> Bool {
        accepts(job, level: .any, deep: deep)
    }

    /// Does this posting match the requested category and level?
    func accepts(_ job: RawJob, level: Level, deep: Bool) -> Bool {
        let title = job.title.lowercased()
        let label = "\(title) \(job.department.lowercased())"
        let body = deep ? job.description.lowercased() : ""

        if let include, !include.matches(label) {
            // No signal in the title/department. Fall back to the description, but
            // only if the topic runs through the whole posting. Most firms open
            // every JD with the same blurb ("…low-latency programming, FPGA
            // technology, hardware acceleration and machine learning…"), which
            // trivially satisfies any "mentions it twice" test — so also require
            // the mentions to be spread out rather than clustered in one sentence.
            if body.isEmpty { return false }
            let hits = include.positions(in: body)
            if hits.count < 3 || (hits.last! - hits.first!) < 400 { return false }
        }

        // Exclusions are judged on the title only: a C++ role whose description
        // happens to mention "sales" shouldn't be thrown away.
        if let exclude, exclude.matches(title) { return false }

        let wanted = level.matchKeys
        if !wanted.isEmpty {
            // Judge seniority on the title/department only. Almost every JD body
            // says "our internship programme" somewhere, so matching the
            // description would make every posting look like an internship.
            let levelHit = wanted.contains { Levels.matcher(for: $0)?.matches(label) ?? false }
            if !levelHit { return false }
            if Levels.senior.matches(title) { return false }
        }
        return true
    }
}
