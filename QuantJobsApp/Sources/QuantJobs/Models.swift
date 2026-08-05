import Foundation

// MARK: - ATS

enum ATS: String, Codable, CaseIterable, Identifiable, Sendable {
    case greenhouse, lever, ashby, smartrecruiters, workday, amazon
    case eightfold, jibe, uber, wolverine, citadel, optiver, twosigma, simplify
    case sitemap, janestreet

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
        case .sitemap: "own site"
        case .janestreet: "janestreet.com"
        }
    }

    /// What a board of this kind needs in companies.json.
    enum ConfigStyle: Sendable {
        case token      // a single board slug
        case workday    // host + tenant + site
        case query      // no slug at all; one search index, narrowed by a query
        case sitemap    // host + which sitemap file to read jobs out of
    }

    var configStyle: ConfigStyle {
        switch self {
        // Eightfold and Jibe are hosted platforms addressed by hostname, so
        // they reuse the Workday-style host fields rather than a slug.
        case .workday, .eightfold, .jibe, .citadel: .workday
        case .sitemap: .sitemap
        case .amazon, .uber, .wolverine, .optiver, .twosigma, .simplify,
             .janestreet: .query
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
    /// `sitemap` adapters: which sitemap file lists the jobs, what marks a URL
    /// as one, and whether the office has to be read out of the page title.
    var sitemap: String?
    var path: String?
    var titleLoc: Bool?
    var enabled: Bool
    var tags: [String]
    var note: String?
    /// 1 = the names people target first, 2 = strong, 3 = everything else.
    var tier: Int = 3
    /// What kind of firm it is — "FAANG+", "Frontier AI", "Hedge Funds"… The
    /// tree groups on this, which reads better than a tier number.
    var segment: String = "Other"

    var id: String { name }

    /// What to show in the "board" column — a slug for most, a host for
    /// Workday, the search terms for a query-style board.
    var identifier: String {
        switch ats.configStyle {
        case .token: token ?? ""
        case .workday: host ?? ""
        case .query: query ?? "intern"
        case .sitemap: host ?? ""
        }
    }

    /// Everything that decides *where* the roles come from. Compared to spot a
    /// board being re-pointed, which invalidates anything already fetched from
    /// it — `enabled` is deliberately absent, since switching a firm on and off
    /// doesn't make its rows wrong.
    var boardFingerprint: String {
        [ats.rawValue, token ?? "", host ?? "", tenant ?? "", site ?? "",
         query ?? "", sitemap ?? "", path ?? "", titleLoc == true ? "1" : ""]
            .joined(separator: "|")
    }

    var isConfigured: Bool {
        switch ats {
        case .eightfold: !(host ?? "").isEmpty && !(tenant ?? "").isEmpty
        case .jibe, .citadel: !(host ?? "").isEmpty
        case .sitemap: !(host ?? "").isEmpty && !(sitemap ?? "").isEmpty
        default:
            switch ats.configStyle {
            case .token: !(token ?? "").isEmpty
            case .workday: !(host ?? "").isEmpty && !(tenant ?? "").isEmpty
                            && !(site ?? "").isEmpty
            case .sitemap: !(host ?? "").isEmpty && !(sitemap ?? "").isEmpty
            case .query: true      // nothing to configure
            }
        }
    }

    init(name: String, ats: ATS, token: String? = nil, host: String? = nil,
         tenant: String? = nil, site: String? = nil, query: String? = nil,
         enabled: Bool = true, tags: [String] = [], note: String? = nil,
         tier: Int = 3, segment: String = "Other") {
        self.name = name; self.ats = ats; self.token = token
        self.host = host; self.tenant = tenant; self.site = site
        self.query = query
        self.enabled = enabled; self.tags = tags; self.note = note
        self.tier = tier
        self.segment = segment
    }

    enum CodingKeys: String, CodingKey {
        case name, ats, token, host, tenant, site, query, enabled, tags, note, tier
        case segment, sitemap, path
        case titleLoc = "title_loc"
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
        sitemap = try c.decodeIfPresent(String.self, forKey: .sitemap)
        path = try c.decodeIfPresent(String.self, forKey: .path)
        titleLoc = try c.decodeIfPresent(Bool.self, forKey: .titleLoc)
        tier = try c.decodeIfPresent(Int.self, forKey: .tier) ?? 3
        segment = try c.decodeIfPresent(String.self, forKey: .segment) ?? "Other"
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
        case .sitemap:
            // Written in full: dropping these would leave the entry unusable,
            // and the encoder only emits the keys its style names.
            try c.encode(host ?? "", forKey: .host)
            try c.encode(sitemap ?? "", forKey: .sitemap)
            if let path, !path.isEmpty { try c.encode(path, forKey: .path) }
            if titleLoc == true { try c.encode(true, forKey: .titleLoc) }
        }
        try c.encode(tier, forKey: .tier)
        try c.encode(segment, forKey: .segment)
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
        case .any: "All Levels"
        }
    }

    /// Short form, for the segmented control in the filter bar.
    var shortLabel: String {
        switch self {
        case .intern: "Intern"
        case .newgrad: "New Grad"
        case .internOrNewgrad: "Both"
        case .any: "All levels"
        }
    }

    /// "Any" reads like "both of the above" when it actually means the opposite:
    /// no level filter, so experienced roles come too. Spell that out on hover.
    var hint: String {
        switch self {
        case .intern: "Internships, summer analyst and co-op programmes."
        case .newgrad: "Graduate, campus and entry-level roles."
        case .internOrNewgrad: "Either of the two — early career only."
        case .any: "No level filter at all — experienced and senior roles included."
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

    /// "ok" unless the row came from an aggregator whose link we couldn't
    /// confirm — "blocked" means the firm refuses scripted requests.
    var linkStatus: String = "ok"

    var linkUnverified: Bool { linkStatus != "ok" }

    /// Worked out once per scrape so category and level become instant
    /// filters instead of reasons to re-fetch every board.
    var matchedCategories: Set<String> = []
    var matchedLevels: Set<String> = []

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
    /// Identity for tracking and the seen list.
    ///
    /// The URL, because it is the only thing separating two postings a firm
    /// makes under the same title in the same city: Jane Street's London
    /// "Software Engineer" exists as both a Summer Internship and a Full-Time
    /// New Grad role, and keying on company/title/location made saving one mark
    /// the other.
    var key: String { url.isEmpty ? legacyKey : url }

    /// What `key` used to be. Kept so tracked entries written before the change
    /// can be re-keyed from their snapshots, and so the seen list still
    /// recognises rows it recorded under the old scheme.
    var legacyKey: String {
        "\(company)|\(title)|\(location)".lowercased()
    }

    var postedDate: Date? {
        guard !posted.isEmpty else { return nil }
        return Job.dateFormatter.date(from: posted)
    }

    /// Short enough for the Level column, which is narrow — "Internship"
    /// truncated to "Interns…" there. Matches the wording on the filter buttons.
    var levelShort: String {
        switch level {
        case "intern": "Intern"
        case "newgrad": "New Grad"
        default: ""
        }
    }

    /// "intern" is what the matcher calls it; this is what a person reads.
    /// The raw value still backs sorting, so the column order is unaffected.
    var levelLabel: String {
        switch level {
        case "intern": "Internship"
        case "newgrad": "New Grad"
        default: ""
        }
    }

    /// How long the posting has been up. Boards state a date and nothing else,
    /// so working out whether 2026-07-28 is recent is left to the reader.
    var age: String? {
        guard let posted = postedDate else { return nil }
        let days = Calendar.current.dateComponents([.day], from: posted, to: Date()).day ?? 0
        switch days {
        case ..<0: return nil            // dated in the future; don't guess
        case 0: return "today"
        case 1: return "yesterday"
        case 2..<14: return "\(days) days ago"
        case 14..<60: return "\(days / 7) weeks ago"
        default: return "\(days / 30) months ago"
        }
    }

    var isNew: Bool = false

    /// `isNew` is a property of the run, not of the job, so it stays out of
    /// anything written to disk.
    enum CodingKeys: String, CodingKey {
        case company, title, location, url, posted, department, description
        case ats, tags, level, places, variants, linkStatus
        case matchedCategories, matchedLevels
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
