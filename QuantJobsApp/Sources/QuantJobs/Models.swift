import Foundation
import SwiftUI

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
    /// Set only when a firm has more than one board, to say which one this is —
    /// "Campus" for Millennium's separate student site. Plenty of firms keep
    /// graduate hiring on its own portal that their main board never lists, so
    /// one entry per firm would silently miss exactly the roles this tool is
    /// for. Purely a label: postings still carry the plain firm name.
    var board: String?

    /// Two entries can share a name — see `board` — so identity has to include
    /// where the roles come from, or SwiftUI hands them the same identity and
    /// clicking one row toggles the other.
    var id: String { "\(name)\u{1}\(boardFingerprint)" }

    /// The firm name, with the board appended when there is more than one.
    var displayName: String {
        guard let board, !board.isEmpty else { return name }
        return "\(name) · \(board)"
    }

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
        case segment, sitemap, path, board
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
        board = try c.decodeIfPresent(String.self, forKey: .board)
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
        // Dropped on a save, the second board of a firm would come back looking
        // like a duplicate of the first.
        if let board, !board.isEmpty { try c.encode(board, forKey: .board) }
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
    /// Set when this category is a slice of another rather than a peer of it —
    /// "the SWE roles that are C++". The sidebar nests it and the matcher applies
    /// both sets of rules.
    var parent: String?
    var description: String
    var include: [String]
    var exclude: [String]

    var id: String { name }

    // `name` is the dictionary key, filled in by the loader.
    enum CodingKeys: String, CodingKey { case description, include, exclude, parent }

    init(name: String, description: String, include: [String], exclude: [String],
         parent: String? = nil) {
        self.name = name; self.description = description; self.parent = parent
        self.include = include; self.exclude = exclude
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = ""   // filled in by the loader, which knows the dictionary key
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        include = try c.decodeIfPresent([String].self, forKey: .include) ?? []
        exclude = try c.decodeIfPresent([String].self, forKey: .exclude) ?? []
        parent = try c.decodeIfPresent(String.self, forKey: .parent)
    }

    /// Short enough for "No C++ +1" in a filter-row button.
    var shortName: String {
        switch name {
        case "cpp": "C++"
        case "python": "Python"
        case "frontend": "UI/Web"
        default: displayName
        }
    }

    var symbol: String {
        switch name {
        case "swe": "chevron.left.forwardslash.chevron.right"
        case "quant-trading": "chart.line.uptrend.xyaxis"
        case "quant-research": "function"
        case "quant-dev": "cpu"
        case "hardware": "memorychip"
        case "data": "cylinder.split.1x2"
        case "cpp": "chevron.left.forwardslash.chevron.right"
        case "python": "text.and.command.macwindow"
        case "frontend": "macwindow"
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
        case "cpp": "C++ / Low Latency"
        case "python": "Python"
        case "frontend": "UI / Web / Full Stack"
        case "all": "Everything"
        default: name.capitalized
        }
    }
}

// MARK: - Level

/// The bucket for a posting that names no stack at all. It's most of them, so a
/// stack filter that couldn't select it would throw away the bulk of the list to
/// gain a handful.
enum Stacks {
    static let unspecified = "unspecified"
}

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
    /// Which stacks the posting names — "cpp", "python", "frontend". Empty means
    /// it names none, which is the large majority: 270 of 310 early-career SWE
    /// roles say nothing about the language. Recorded at scrape time so filtering
    /// on it is a set lookup rather than another trip to the boards.
    var matchedStacks: Set<String> = []
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

    /// Identity for de-duplication only — never for tracking, which stays on
    /// `key` so nothing already saved is disturbed.
    ///
    /// Citadel and Citadel Securities are separate firms sharing one careers
    /// platform, and they cross-list their campus programmes: 22 of the 23
    /// early-career roles they have in common sit at the *same path* on both
    /// hosts. That is one job posted twice, not two jobs, so the host is
    /// dropped and the pair collapses.
    var dedupKey: String {
        for host in ["//www.citadel.com/", "//www.citadelsecurities.com/"]
        where url.contains(host) {
            return "citadel|" + url.components(separatedBy: host)[1]
        }
        return key
    }

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
    var age: String? { postedDate.flatMap(Dates.relative) }

    var isNew: Bool = false

    /// `isNew` is a property of the run, not of the job, so it stays out of
    /// anything written to disk.
    enum CodingKeys: String, CodingKey {
        case company, title, location, url, posted, department, description
        case ats, tags, level, places, variants, linkStatus
        // matchedStacks is deliberately absent: Swift's synthesized decoder
        // throws on a missing key rather than using the property's default, so
        // adding it here made every tracked entry written by an earlier build
        // fail to decode — and because the whole dictionary is decoded in one
        // `try?`, one missing key silently emptied the Saved, Applied and Hidden
        // lists. It's recomputed on every scrape, like `isNew`.
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

// MARK: - Dates

enum Dates {

    static let iso: DateFormatter = Job.dateFormatter

    static var today: String { iso.string(from: Date()) }

    static func date(_ s: String) -> Date? { s.isEmpty ? nil : iso.date(from: s) }

    static func days(since s: String) -> Int? {
        guard let d = date(s) else { return nil }
        return Calendar.current.dateComponents([.day], from: d, to: Date()).day
    }

    /// "today" / "yesterday" / "12 days ago" / "3 weeks ago" / "5 months ago".
    /// Nil for a future date rather than a guess at what it means.
    static func relative(_ d: Date) -> String? {
        let days = Calendar.current.dateComponents([.day], from: d, to: Date()).day ?? 0
        switch days {
        case ..<0: return nil
        case 0: return "today"
        case 1: return "yesterday"
        case 2..<14: return "\(days) days ago"
        case 14..<60: return "\(days / 7) weeks ago"
        default: return "\(days / 30) months ago"
        }
    }

    static func relative(_ s: String) -> String? { date(s).flatMap(relative) }

    /// The same span in the width a table column can spare: 12d, 3w, 5mo.
    static func compact(_ s: String) -> String? {
        guard let days = days(since: s), days >= 0 else { return nil }
        switch days {
        case 0: return "today"
        case 1..<14: return "\(days)d"
        case 14..<60: return "\(days / 7)w"
        default: return "\(days / 30)mo"
        }
    }
}

// MARK: - Tracking

/// A step in an application, listed in the order they normally happen.
///
/// `order` is that listing, and it decides which step counts as "where you are"
/// when two share a date — so a rejection recorded the same day as the interview
/// it followed still reads as the outcome.
enum Stage: String, Codable, CaseIterable, Identifiable, Sendable {
    case applied, assessment, interview, final, offer, rejected, withdrawn

    var id: String { rawValue }

    var label: String {
        switch self {
        case .applied: "Applied"
        case .assessment: "Online assessment"
        case .interview: "Interview"
        case .final: "Final round"
        case .offer: "Offer"
        case .rejected: "Rejected"
        case .withdrawn: "Withdrawn"
        }
    }

    /// For the table, where there's room for a word and not a phrase.
    var short: String {
        switch self {
        case .assessment: "OA"
        case .final: "Final"
        default: label
        }
    }

    var symbol: String {
        switch self {
        case .applied: "paperplane.fill"
        case .assessment: "laptopcomputer"
        case .interview: "bubble.left.and.bubble.right.fill"
        case .final: "person.2.fill"
        case .offer: "checkmark.seal.fill"
        case .rejected: "xmark.circle.fill"
        case .withdrawn: "arrow.uturn.left.circle.fill"
        }
    }

    /// Nothing follows these, so the timeline stops drawing a line after them.
    var isClosed: Bool { self == .rejected || self == .withdrawn }

    /// One colour scale for the whole pipeline. It lives on the stage rather
    /// than on a view because it's what the stage *means* — three views were
    /// reaching into `ContentView` for a static to get at it.
    var tint: Color {
        switch self {
        case .applied: .secondary
        case .assessment, .interview, .final: .orange
        case .offer: .green
        case .rejected: .red
        case .withdrawn: .secondary
        }
    }

    var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

/// One dated step of one application.
struct Milestone: Codable, Hashable, Sendable, Identifiable {
    var stage: Stage
    var date: String              // yyyy-MM-dd

    /// The stage, not the date: a step is recorded once and its date is edited
    /// in place, so an identity that moved when you corrected the date would
    /// make the row jump out from under the picker.
    var id: String { stage.rawValue }

    var relative: String? { Dates.relative(date) }
}

/// What to do in the results list about roles you've already applied to.
///
/// One three-way choice rather than two independent toggles, because hiding a
/// firm already hides its roles — as separate switches, two of the four
/// combinations mean the same thing.
enum AppliedFilter: String, Codable, CaseIterable, Identifiable, Sendable {
    case show, roles, firms

    var id: String { rawValue }

    /// What the filter-row button says.
    ///
    /// It states the *setting*, the way its neighbours do — "Anywhere",
    /// "54 firms", "Any time" — because a control that shows its current value
    /// can't be misread as a button that would do something else. A bare
    /// "Applied" read as a status chip on the row rather than a filter over it,
    /// and "Hide applied" on a control that was already hiding them read as an
    /// offer to hide them.
    var short: String {
        switch self {
        case .show: "Applied: shown"
        case .roles: "Applied: hidden"
        case .firms: "Applied firms: hidden"
        }
    }

    /// The full sentence, for the menu.
    var label: String {
        switch self {
        case .show: "Show roles I've applied to"
        case .roles: "Hide roles I've applied to"
        case .firms: "Hide every role at those firms"
        }
    }

    var help: String {
        switch self {
        case .show: "Applied roles stay in the results"
        case .roles: "Leave out the postings you've applied to"
        case .firms: "Leave out every posting from a firm you've applied to — "
                   + "one application per firm is usually the point"
        }
    }

    /// Every one of these is checked to exist. `paperplane.slash` and
    /// `building.2.slash` read like real SF Symbols and are not — an unknown name
    /// renders as nothing at all, so the filter button sat there blank in both of
    /// its active states and only a screenshot at a width that hid the label made
    /// it obvious.
    var symbol: String {
        switch self {
        case .show: "paperplane"
        case .roles: "paperplane.circle.fill"
        case .firms: "building.2.crop.circle.fill"
        }
    }

    var isFiltering: Bool { self != .show }
}

/// What the user has decided about a posting.
///
/// Kept as a type because the row buttons, the context menu and the sidebar all
/// need to name the three marks. `applied` now means "there's an application
/// here", which may be at any stage.
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
/// One posting the user has marked, and how their application to it is going.
///
/// The three marks are independent. They used to be one `status`, which meant
/// hiding a role you'd applied to overwrote the application — the thing you were
/// most likely to want kept. Hiding is a view preference; an application is a
/// history; saving is a bookmark. None of them should be able to erase another.
struct TrackedJob: Codable, Identifiable, Sendable {
    var saved: Bool = false
    var hidden: Bool = false
    /// Dated steps, earliest first. Empty means there's no application here.
    var milestones: [Milestone] = []
    var job: Job
    var updated: String          // when any of this last changed
    var lastSeen: String         // when a scrape last returned this posting
    var note: String = ""
    /// The board stopped listing it. Set by a run that did reach that firm.
    var isDelisted: Bool = false

    var id: String { job.key }

    // MARK: What state it's in

    var hasApplication: Bool { !milestones.isEmpty }

    /// Nothing marked at all — the entry has no reason to be on disk.
    var isEmpty: Bool { !saved && !hidden && milestones.isEmpty }

    /// Where the application has got to: the furthest step, with the later date
    /// winning and `Stage.order` breaking a tie.
    var stage: Stage? {
        milestones.max { a, b in
            a.date == b.date ? a.stage.order < b.stage.order : a.date < b.date
        }?.stage
    }

    var appliedOn: String? {
        milestones.first { $0.stage == .applied }?.date
    }

    /// When the application last moved, for sorting the Applied list by what's
    /// actually happening rather than by when the board posted the role.
    var lastActivity: String {
        milestones.map(\.date).max() ?? updated
    }

    var isClosed: Bool { stage?.isClosed == true }

    /// Whether this entry carries one of the three marks.
    func carries(_ status: JobStatus) -> Bool {
        switch status {
        case .favorite: saved
        case .applied: hasApplication
        case .hidden: hidden
        }
    }

    func date(of stage: Stage) -> String? {
        milestones.first { $0.stage == stage }?.date
    }

    /// Steps not yet recorded, in pipeline order — what "add a step" offers.
    var remainingStages: [Stage] {
        let have = Set(milestones.map(\.stage))
        return Stage.allCases.filter { !have.contains($0) }
    }

    mutating func record(_ stage: Stage, on date: String) {
        if let i = milestones.firstIndex(where: { $0.stage == stage }) {
            milestones[i].date = date
        } else {
            milestones.append(Milestone(stage: stage, date: date))
        }
        sortMilestones()
    }

    mutating func remove(_ stage: Stage) {
        milestones.removeAll { $0.stage == stage }
    }

    private mutating func sortMilestones() {
        milestones.sort {
            $0.date == $1.date ? $0.stage.order < $1.stage.order : $0.date < $1.date
        }
    }

    // MARK: Codable

    enum CodingKeys: String, CodingKey {
        case saved, hidden, milestones, job, updated, lastSeen, note, isDelisted
        case status      // read for migration, never written
    }

    init(job: Job, updated: String, lastSeen: String,
         saved: Bool = false, hidden: Bool = false,
         milestones: [Milestone] = [], note: String = "",
         isDelisted: Bool = false) {
        self.job = job
        self.updated = updated; self.lastSeen = lastSeen
        self.saved = saved; self.hidden = hidden; self.milestones = milestones
        self.note = note; self.isDelisted = isDelisted
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        job = try c.decode(Job.self, forKey: .job)
        updated = try c.decodeIfPresent(String.self, forKey: .updated) ?? ""
        lastSeen = try c.decodeIfPresent(String.self, forKey: .lastSeen) ?? ""
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        isDelisted = try c.decodeIfPresent(Bool.self, forKey: .isDelisted) ?? false

        if let saved = try c.decodeIfPresent(Bool.self, forKey: .saved) {
            self.saved = saved
            hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
            milestones = try c.decodeIfPresent([Milestone].self, forKey: .milestones) ?? []
        } else {
            // Written by a version with one `status`. An applied role becomes an
            // application dated when it was marked, so nobody loses a history by
            // upgrading.
            switch try? c.decode(JobStatus.self, forKey: .status) {
            case .applied:
                let when = updated.isEmpty ? Dates.today : updated
                milestones = [Milestone(stage: .applied, date: when)]
            case .hidden:
                hidden = true
            default:
                saved = true
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(job, forKey: .job)
        try c.encode(saved, forKey: .saved)      // always written; its presence
        try c.encode(hidden, forKey: .hidden)    // is what marks the new format
        if !milestones.isEmpty { try c.encode(milestones, forKey: .milestones) }
        try c.encode(updated, forKey: .updated)
        try c.encode(lastSeen, forKey: .lastSeen)
        if !note.isEmpty { try c.encode(note, forKey: .note) }
        if isDelisted { try c.encode(true, forKey: .isDelisted) }
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
