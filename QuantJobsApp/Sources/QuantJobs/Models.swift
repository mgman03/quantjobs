import Foundation

// MARK: - ATS

enum ATS: String, Codable, CaseIterable, Identifiable, Sendable {
    case greenhouse, lever, ashby, smartrecruiters, workday, amazon
    case eightfold, jibe, uber, wolverine, citadel, optiver, twosigma, simplify

    var id: String { rawValue }

    var label: String {
        switch self {
        case .greenhouse: "Greenhouse"
        case .lever: "Lever"
        case .ashby: "Ashby"
        case .smartrecruiters: "SmartRecruiters"
        case .workday: "Workday"
        case .amazon: "amazon.jobs"
        case .eightfold: "Eightfold"
        case .jibe: "Jibe"
        case .uber: "uber.com"
        case .wolverine: "wolve.com"
        case .citadel: "citadel.com"
        case .optiver: "optiver.com"
        case .twosigma: "twosigma.com"
        case .simplify: "Simplify feed"
        }
    }

    /// What a board of this kind needs in companies.json.
    enum ConfigStyle: Sendable {
        case token      // a single board slug
        case workday    // host + tenant + site
        case query      // no slug at all; one search index, narrowed by a query
    }

    var configStyle: ConfigStyle {
        switch self {
        // Eightfold and Jibe are hosted platforms addressed by hostname, so
        // they reuse the Workday-style host fields rather than a slug.
        case .workday, .eightfold, .jibe, .citadel: .workday
        case .amazon, .uber, .wolverine, .optiver, .twosigma, .simplify: .query
        default: .token
        }
    }

    var usesToken: Bool { configStyle == .token }
}

// MARK: - Company

struct Company: Codable, Identifiable, Hashable, Sendable {
    var name: String
    var ats: ATS
    var token: String?
    var host: String?
    var tenant: String?
    var site: String?
    var query: String?
    var enabled: Bool
    var tags: [String]
    var note: String?
    /// 1 = the names people target first, 2 = strong, 3 = everything else.
    var tier: Int = 3

    var id: String { name }

    /// What to show in the "board" column — a slug for most, a host for
    /// Workday, the search terms for a query-style board.
    var identifier: String {
        switch ats.configStyle {
        case .token: token ?? ""
        case .workday: host ?? ""
        case .query: query ?? "intern"
        }
    }

    var isConfigured: Bool {
        switch ats {
        case .eightfold: !(host ?? "").isEmpty && !(tenant ?? "").isEmpty
        case .jibe, .citadel: !(host ?? "").isEmpty
        default:
            switch ats.configStyle {
            case .token: !(token ?? "").isEmpty
            case .workday: !(host ?? "").isEmpty && !(tenant ?? "").isEmpty
                            && !(site ?? "").isEmpty
            case .query: true      // nothing to configure
            }
        }
    }

    init(name: String, ats: ATS, token: String? = nil, host: String? = nil,
         tenant: String? = nil, site: String? = nil, query: String? = nil,
         enabled: Bool = true, tags: [String] = [], note: String? = nil,
         tier: Int = 3) {
        self.name = name; self.ats = ats; self.token = token
        self.host = host; self.tenant = tenant; self.site = site
        self.query = query
        self.enabled = enabled; self.tags = tags; self.note = note
        self.tier = tier
    }

    enum CodingKeys: String, CodingKey {
        case name, ats, token, host, tenant, site, query, enabled, tags, note, tier
    }

    var tierLabel: String {
        switch tier {
        case 1: "Tier 1"
        case 2: "Tier 2"
        default: "Tier 3"
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        ats = (try? c.decode(ATS.self, forKey: .ats)) ?? .greenhouse
        token = try c.decodeIfPresent(String.self, forKey: .token)
        host = try c.decodeIfPresent(String.self, forKey: .host)
        tenant = try c.decodeIfPresent(String.self, forKey: .tenant)
        site = try c.decodeIfPresent(String.self, forKey: .site)
        query = try c.decodeIfPresent(String.self, forKey: .query)
        tier = try c.decodeIfPresent(Int.self, forKey: .tier) ?? 3
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        note = try c.decodeIfPresent(String.self, forKey: .note)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(ats, forKey: .ats)
        // Only write the keys that apply to this ATS, so the file stays readable.
        switch ats.configStyle {
        case .token:
            try c.encode(token ?? "", forKey: .token)
        case .workday:
            try c.encode(host ?? "", forKey: .host)
            try c.encode(tenant ?? "", forKey: .tenant)
            try c.encode(site ?? "", forKey: .site)
        case .query:
            if let query, !query.isEmpty { try c.encode(query, forKey: .query) }
        }
        try c.encode(tier, forKey: .tier)
        try c.encode(enabled, forKey: .enabled)
        if !tags.isEmpty { try c.encode(tags, forKey: .tags) }
        if let note, !note.isEmpty { try c.encode(note, forKey: .note) }
    }
}

/// Mirrors companies.json, preserving the `_comment` block the CLI ships with.
struct CompanyFile: Codable, Sendable {
    var comment: [String]?
    var companies: [Company]

    enum CodingKeys: String, CodingKey {
        case comment = "_comment"
        case companies
    }
}

// MARK: - Category

struct JobCategory: Codable, Identifiable, Hashable, Sendable {
    var name: String
    var description: String
    var include: [String]
    var exclude: [String]

    var id: String { name }

    enum CodingKeys: String, CodingKey { case description, include, exclude }

    init(name: String, description: String, include: [String], exclude: [String]) {
        self.name = name; self.description = description
        self.include = include; self.exclude = exclude
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = ""   // filled in by the loader, which knows the dictionary key
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        include = try c.decodeIfPresent([String].self, forKey: .include) ?? []
        exclude = try c.decodeIfPresent([String].self, forKey: .exclude) ?? []
    }

    var symbol: String {
        switch name {
        case "swe": "chevron.left.forwardslash.chevron.right"
        case "quant-trading": "chart.line.uptrend.xyaxis"
        case "quant-research": "function"
        case "quant-dev": "cpu"
        case "hardware": "memorychip"
        case "data": "cylinder.split.1x2"
        case "all": "square.grid.2x2"
        default: "folder"
        }
    }

    var displayName: String {
        switch name {
        case "swe": "Software Engineering"
        case "quant-trading": "Quant Trading"
        case "quant-research": "Quant Research"
        case "quant-dev": "Quant Dev"
        case "hardware": "Hardware / FPGA"
        case "data": "Data / ML"
        case "all": "Everything"
        default: name.capitalized
        }
    }
}

// MARK: - Level

enum Level: String, CaseIterable, Identifiable, Sendable {
    case intern
    case newgrad
    case internOrNewgrad
    case any

    var id: String { rawValue }

    var label: String {
        switch self {
        case .intern: "Internship"
        case .newgrad: "New Grad"
        case .internOrNewgrad: "Intern or New Grad"
        case .any: "Any Level"
        }
    }

    /// Short form, for the segmented control in the filter bar.
    var shortLabel: String {
        switch self {
        case .intern: "Intern"
        case .newgrad: "New Grad"
        case .internOrNewgrad: "Both"
        case .any: "Any"
        }
    }

    var matchKeys: [String] {
        switch self {
        case .intern: ["intern"]
        case .newgrad: ["newgrad"]
        case .internOrNewgrad: ["intern", "newgrad"]
        case .any: []
        }
    }
}

// MARK: - Job

struct Job: Identifiable, Hashable, Sendable, Codable {
    var company: String
    var title: String
    var location: String
    var url: String
    var posted: String        // YYYY-MM-DD, or "" when the board doesn't say
    var department: String
    var description: String
    var ats: ATS
    var tags: [String]
    var level: String = ""

    /// Structured reading of `location`, filled in when the job is built.
    var places: [Place] = []

    /// Other postings of the same role at different locations, folded into
    /// this row. Empty when nothing was merged.
    var variants: [Variant] = []

    struct Variant: Hashable, Sendable, Codable {
        var location: String
        var locationDisplay: String
        var url: String
        var posted: String
        var key: String
    }

    var id: String { key }

    /// The role without the boilerplate every board wraps it in — "2026 -
    /// Internship, Quantitative Researcher" is four words of noise before the
    /// part that tells them apart in a list.
    var shortTitle: String { TitleTidy.shorten(title) }

    /// Every posting this row stands for, the primary one first.
    var allKeys: [String] { [key] + variants.map(\.key) }

    var isMerged: Bool { !variants.isEmpty }

    /// Just this posting's own place, not the merged set.
    var locationLabelForPrimary: String {
        places.first.map { LocationParser.format([$0], raw: location) } ?? location
    }

    /// Tidied location for display: "Santa Clara, CA" rather than
    /// "US, CA, Santa Clara".
    var locationDisplay: String { LocationParser.format(places, raw: location) }

    var continents: [String] { places.map(\.continent).uniqued() }
    var cities: [String] { places.map(\.city).filter { !$0.isEmpty }.uniqued() }
    var countries: [String] { places.map(\.country).filter { !$0.isEmpty }.uniqued() }

    /// Stable identity for de-duplication and the seen-before store.
    var key: String {
        "\(company)|\(title)|\(location)".lowercased()
    }

    var postedDate: Date? {
        guard !posted.isEmpty else { return nil }
        return Job.dateFormatter.date(from: posted)
    }

    var isNew: Bool = false

    /// `isNew` is a property of the run, not of the job, so it stays out of
    /// anything written to disk.
    enum CodingKeys: String, CodingKey {
        case company, title, location, url, posted, department, description
        case ats, tags, level, places, variants
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
}

// MARK: - Tracking

/// What the user has decided about a posting.
enum JobStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case favorite, applied, hidden

    var id: String { rawValue }

    var label: String {
        switch self {
        case .favorite: "Saved"
        case .applied: "Applied"
        case .hidden: "Hidden"
        }
    }

    var symbol: String {
        switch self {
        case .favorite: "star.fill"
        case .applied: "checkmark.seal.fill"
        case .hidden: "eye.slash.fill"
        }
    }

    var emptySymbol: String {
        switch self {
        case .favorite: "star"
        case .applied: "checkmark.seal"
        case .hidden: "eye.slash"
        }
    }

    var verb: String {
        switch self {
        case .favorite: "Save"
        case .applied: "Mark Applied"
        case .hidden: "Hide"
        }
    }
}

/// A posting the user has marked, kept with a full copy of the job.
///
/// The snapshot is the point: a board drops a posting the moment it closes, and
/// an application you're tracking shouldn't vanish with it.
struct TrackedJob: Codable, Identifiable, Sendable {
    var status: JobStatus
    var job: Job
    var updated: String          // when the status last changed
    var lastSeen: String         // when a scrape last returned this posting
    var note: String = ""
    /// The board stopped listing it. Set by a run that did reach that firm.
    var isDelisted: Bool = false

    var id: String { job.key }

    enum CodingKeys: String, CodingKey {
        case status, job, updated, lastSeen, note, isDelisted
    }

    init(status: JobStatus, job: Job, updated: String, lastSeen: String,
         note: String = "", isDelisted: Bool = false) {
        self.status = status; self.job = job
        self.updated = updated; self.lastSeen = lastSeen; self.note = note
        self.isDelisted = isDelisted
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = (try? c.decode(JobStatus.self, forKey: .status)) ?? .favorite
        job = try c.decode(Job.self, forKey: .job)
        updated = try c.decodeIfPresent(String.self, forKey: .updated) ?? ""
        lastSeen = try c.decodeIfPresent(String.self, forKey: .lastSeen) ?? ""
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        isDelisted = try c.decodeIfPresent(Bool.self, forKey: .isDelisted) ?? false
    }
}

/// Strips the seasonal boilerplate off a job title.
///
/// Boards front-load titles with the year and the word "Internship", which is
/// exactly the part you already know — it pushes the distinguishing words past
/// the edge of the column.
enum TitleTidy {

    private static let patterns: [String] = [
        // Leading: "2026 - ", "2027 Internship – ", "Summer 2027: "
        #"^\s*(19|20)\d{2}\s*[-–—:,]\s*"#,
        #"^\s*(summer|fall|autumn|winter|spring)\s+(19|20)\d{2}\s*[-–—:,]\s*"#,
        #"^\s*(19|20)\d{2}\s+(summer\s+)?(internships?|intern|graduate\s+programme|graduate\s+program)\s*[-–—:,]\s*"#,
        #"^\s*(summer\s+)?intern(ship)?s?\s+(19|20)\d{2}\s*[-–—:,]\s*"#,
        #"^\s*(internships?|intern)\s*[-–—:,]\s*"#,
        // Trailing: " - Summer 2027", ", 2026", " (Summer 2027)"
        #"\s*[-–—:,]\s*(summer|fall|autumn|winter|spring)?\s*(19|20)\d{2}\s*$"#,
        #"\s*\(\s*(summer|fall|autumn|winter|spring)?\s*(19|20)\d{2}\s*\)\s*$"#,
    ]

    private static let regexes: [NSRegularExpression] = patterns.compactMap {
        try? NSRegularExpression(pattern: $0, options: [.caseInsensitive])
    }

    static func shorten(_ title: String) -> String {
        var out = title
        // Two passes: "2026 - Internship, X" needs the year gone before the
        // "Internship," rule can see the start of the string.
        for _ in 0..<2 {
            for rx in regexes {
                out = rx.stringByReplacingMatches(
                    in: out, range: NSRange(out.startIndex..., in: out),
                    withTemplate: "")
            }
        }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: " -–—:,"))
        // If tidying ate the whole thing, the original was the useful part.
        return out.count >= 4 ? out : title
    }
}

extension String {
    /// Returns the remainder after `prefix`, or nil if it isn't there.
    func dropPrefixIfPresent(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}

extension Sequence where Element: Hashable {
    /// Order-preserving de-duplication.
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

// MARK: - Errors

struct ScrapeFailure: Identifiable, Hashable, Sendable {
    var id: String { company }
    var company: String
    var reason: String
}

enum FetchError: LocalizedError {
    case http(Int)
    case badPayload(String)
    case misconfigured(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .http(let c): "HTTP \(c)"
        case .badPayload(let m): m
        case .misconfigured(let m): m
        case .transport(let m): m
        }
    }
}
