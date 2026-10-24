import Foundation

/// One alternation regex built from a list of phrases.
///
/// Phrases are word-bounded when they start/end alphanumerically, so "intern"
/// won't fire on "internal" while "c++" still matches. Spaces inside a phrase
/// also match hyphens and slashes, so "co op" catches "Co-Op" and
/// "summer analyst" catches "Summer-Analyst".
///
/// A phrase ending in a letter also matches its plural. Without that, the word
/// boundary made "graduate" miss "Fresh Graduates", "early career" miss
/// "Software Engineer, Early Careers" and "internship" miss a page titled
/// "Internships" — real early-career postings dropped on a trailing s.
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
            let post = p.last!.isLetter ? #"s?(?![a-z0-9])"#
                     : p.last!.isAlphanumeric ? #"(?![a-z0-9])"# : ""
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

    // A co-op can be a student placement or the name of a product team. The
    // latter appears in titles such as "Co-op and Marketplaces"; that wording
    // alone must not put an experienced role in the internship list.
    private static let coOpTeam = try! NSRegularExpression(
        pattern: #"\bco[- ]?op\s+and\b"#, options: [.caseInsensitive])
    private static let experiencedGrade = try! NSRegularExpression(
        pattern: #"\b(?:engineer|developer|scientist|analyst|researcher|designer|specialist)\s+(?:ii|iii|iv|v|[2-9])\b"#,
        options: [.caseInsensitive])
    private static let recruitingRole = try! NSRegularExpression(
        pattern: #"\b(?:recruit(?:er|ing|ment)|talent acquisition|talent partner)\b"#,
        options: [.caseInsensitive])
    private static let campusEvent = try! NSRegularExpression(
        pattern: #"\b(?:coffee chats?|hack\w*ton|talent community|student founder|interest form|career fair events?)\b"#,
        options: [.caseInsensitive])

    // Student eligibility, insight events and summer enrichment programmes
    // are not evidence that the posting itself is an internship.
    static let intern = PhraseMatcher([
        "intern", "internship", "summer analyst", "summer associate",
        "co-op", "coop", "industrial placement", "work placement",
        "placement student", "praktikant", "praktikum", "vacation scheme",
    ])!

    static let newgrad = PhraseMatcher([
        "new grad", "new graduate", "graduate", "campus", "university",
        "entry level", "junior", "early career", "class of", "trainee",
        "graduate programme", "graduate program", "rotational",
        // Semiconductor firms hire a whole class this way: "New College Grad",
        // "NCG", "Fresh Grads Welcome". Bare "grad" covers all of them.
        "grad", "ncg", "upcoming graduate",
        // Banks call a new-grad seat a full-time analyst, and a plural PhD in a
        // title is campus hiring — singular "PhD" is often a senior role, so
        // only the plural is listed.
        "full time analyst", "fulltime analyst", "phds",
    ])!

    /// Some boards label a role "Graduate Trader" but mean experienced;
    /// these tokens veto a level match outright.
    static let senior = PhraseMatcher([
        "senior", "staff", "principal", "lead", "head of", "director", "vp",
        "vice president", "experienced", "10+ years", "5+ years",
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
        let titleRange = NSRange(title.startIndex..., in: title)
        if experiencedGrade.firstMatch(in: title, range: titleRange) != nil { return false }
        if campusEvent.firstMatch(in: title, range: titleRange) != nil { return false }
        if wanted == ["newgrad"] &&
            recruitingRole.firstMatch(in: title, range: titleRange) != nil { return false }
        let label = "\(title.lowercased()) \(department.lowercased())"
        let labelRange = NSRange(label.startIndex..., in: label)
        let studentLabel = coOpTeam.stringByReplacingMatches(
            in: label, range: labelRange, withTemplate: "")
        guard wanted.contains(where: { matcher(for: $0)?.matches(studentLabel) ?? false })
        else { return false }
        // A title may name the team after the actual role: "Operations Intern –
        // Managing Director Office" is still an internship. Only a seniority
        // marker before the level word describes the candidate's role.
        let firstLevel = wanted.compactMap { matcher(for: $0)?.positions(in: title).first }.min()
        let seniorScope = firstLevel.map { (title as NSString).substring(to: $0) } ?? title
        return !senior.matches(seniorScope.lowercased())
    }

    /// Best-guess label for a posting, shown in the Level column.
    static func detect(title: String, department: String) -> String {
        if matches(.intern, title: title, department: department) { return "intern" }
        if matches(.newgrad, title: title, department: department) { return "newgrad" }
        return ""
    }
}

// MARK: - Category matching

/// A category's include/exclude lists, compiled once per scrape.
struct CategoryMatcher: Sendable {
    let name: String
    let include: PhraseMatcher?
    let exclude: PhraseMatcher?
    /// A sub-category's parent rules. `cpp` means "the SWE roles that are C++",
    /// not "anything C++", so both sets have to pass — without this it also
    /// matched FPGA and hardware postings, which are C++ work but not software
    /// engineering.
    let parentInclude: PhraseMatcher?
    let parentExclude: PhraseMatcher?

    init(_ category: JobCategory, parent: JobCategory? = nil) {
        name = category.name
        include = PhraseMatcher(category.include)
        exclude = PhraseMatcher(category.exclude)
        parentInclude = parent.flatMap { PhraseMatcher($0.include) }
        parentExclude = parent.flatMap { PhraseMatcher($0.exclude) }
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

        // No signal in the title/department falls back to the description, but
        // only if the topic runs through the whole posting. Most firms open every
        // JD with the same blurb ("…low-latency programming, FPGA technology,
        // hardware acceleration and machine learning…"), which trivially
        // satisfies any "mentions it twice" test — so the mentions also have to
        // be spread out rather than clustered in one sentence.
        func included(_ matcher: PhraseMatcher?) -> Bool {
            guard let matcher else { return true }
            if matcher.matches(label) { return true }
            guard !body.isEmpty else { return false }
            let hits = matcher.positions(in: body)
            return hits.count >= 3 && (hits.last! - hits.first!) >= 400
        }

        if !included(include) { return false }
        if !included(parentInclude) { return false }

        // Exclusions are judged on the title only: a C++ role whose description
        // happens to mention "sales" shouldn't be thrown away.
        if let exclude, exclude.matches(title) { return false }
        if let parentExclude, parentExclude.matches(title) { return false }

        return Levels.matches(level, title: job.title, department: job.department)
    }
}
