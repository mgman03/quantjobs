import Foundation
import Observation

@MainActor
@Observable
final class AppModel {

    // MARK: config

    var companies: [Company] = []
    var categories: [JobCategory] = []
    var selectedCategoryID: String = "swe"

    var selectedCategory: JobCategory? {
        categories.first { $0.name == selectedCategoryID } ?? categories.first
    }

    // MARK: query

    var level: Level = .intern
    var locationFilter = ""
    var sinceDays: Int? = nil
    var newOnly = false
    var deep = false
    var search = ""
    var tagFilter: String? = nil       // the finer descriptive tags
    var recordState = true
    /// Fold the same role at several offices into one row.
    var mergeRoles = true

    /// Both empty means unrestricted. Cities are only ever offered from within
    /// the chosen continents, so the two behave as one drill-down.
    var continentFilter: Set<String> = []
    var cityFilter: Set<String> = []

    /// The two broad buckets the firm list is organised into.
    static let groups = ["quant", "bigtech"]

    static func groupLabel(_ tag: String?) -> String {
        switch tag {
        case "quant": "Quant"
        case "bigtech": "Big Tech"
        default: "All Firms"
        }
    }

    /// Descriptive tags worth offering, with the two group tags left out —
    /// choosing quant vs big tech is what the Firms picker is for.
    var allTags: [String] {
        let pool = companies.filter(\.enabled)
        return Set(pool.flatMap(\.tags))
            .subtracting(Self.groups)
            .sorted()
    }

    func firmCount(inGroup group: String?) -> Int {
        companies.filter { c in
            guard c.enabled, c.isConfigured else { return false }
            guard let group else { return true }
            return c.tags.contains(group)
        }.count
    }

    var query: ScrapeQuery {
        ScrapeQuery(
            category: selectedCategory ?? JobCategory(name: "all", description: "",
                                                      include: [], exclude: []),
            level: level,
            locations: locationFilter
                .split(whereSeparator: { $0 == "," || $0 == ";" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty },
            sinceDays: sinceDays, newOnly: newOnly, deep: deep, search: search,
            tag: tagFilter,
            continents: continentFilter, cities: cityFilter)
    }

    // MARK: - Places on offer

    /// Continents present in the current results, with a count each.
    /// Derived from the scrape rather than hard-coded, so the list only ever
    /// offers somewhere you could actually apply.
    var availableContinents: [(name: String, count: Int)] {
        var tally: [String: Int] = [:]
        for job in jobs where passesNonPlaceFilters(job) {
            for continent in job.continents { tally[continent, default: 0] += 1 }
        }
        return tally.map { (name: $0.key, count: $0.value) }
            .sorted { $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count }
    }

    /// Cities inside the chosen continents (or everywhere, if none chosen).
    var availableCities: [(name: String, country: String, count: Int)] {
        var tally: [String: (country: String, count: Int)] = [:]
        for job in jobs where passesNonPlaceFilters(job) {
            for place in job.places where !place.city.isEmpty {
                guard continentFilter.isEmpty
                        || continentFilter.contains(place.continent) else { continue }
                let existing = tally[place.city]
                tally[place.city] = (existing?.country ?? place.country,
                                     (existing?.count ?? 0) + 1)
            }
        }
        return tally.map { (name: $0.key, country: $0.value.country, count: $0.value.count) }
            .sorted { $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count }
    }

    /// Everything except the place filters, so the pickers can show what
    /// choosing each option would actually get you.
    private func passesNonPlaceFilters(_ job: Job) -> Bool {
        var q = query
        q.continents = []
        q.cities = []
        return q.matchesLiveFilters(job, cutoff: q.cutoffDate)
    }

    func toggleContinent(_ name: String) {
        if continentFilter.contains(name) {
            continentFilter.remove(name)
        } else {
            continentFilter.insert(name)
        }
        // A city that's no longer reachable shouldn't keep filtering silently.
        let reachable = Set(availableCities.map(\.name))
        cityFilter.formIntersection(reachable)
    }

    func toggleCity(_ name: String) {
        if cityFilter.contains(name) { cityFilter.remove(name) } else { cityFilter.insert(name) }
    }

    /// True while chosen cities are doing the filtering and the continents are
    /// only scoping which cities are on offer.
    var citiesOverrideContinents: Bool { !cityFilter.isEmpty }

    /// Whether anything beyond category + level is narrowing the list.
    var hasExtraFilters: Bool {
        tagFilter != nil || sinceDays != nil
            || newOnly || deep || !search.isEmpty || !locationFilter.isEmpty
            || !continentFilter.isEmpty || !cityFilter.isEmpty
    }

    func clearFilters() {
        tagFilter = nil
        sinceDays = nil
        newOnly = false
        deep = false
        search = ""
        locationFilter = ""
        continentFilter = []
        cityFilter = []
    }

    // MARK: results

    private(set) var jobs: [Job] = []
    private(set) var failures: [ScrapeFailure] = []
    private(set) var isScraping = false
    private(set) var scanned = 0
    private(set) var total = 0

    /// Identifies the current scrape. Cancelling one clears `isScraping`
    /// immediately, but boards already waiting on the network still call back —
    /// and those callbacks were landing on the *next* run's counters, which is
    /// how the status bar came to read "102/53 boards". Results carrying a
    /// stale id are dropped.
    private var runID = 0
    private(set) var lastRun: Date?
    private(set) var newCount = 0
    var loadError: String?

    private var seen: [String: String] = [:]
    private var task: Task<Void, Never>?

    // MARK: - Lists

    /// Which collection the table is showing.
    enum JobList: String, CaseIterable, Identifiable, Sendable {
        case results, favorite, applied, hidden

        var id: String { rawValue }

        var title: String {
            switch self {
            case .results: "All Roles"
            case .favorite: "Saved"
            case .applied: "Applied"
            case .hidden: "Hidden"
            }
        }

        var symbol: String {
            switch self {
            case .results: "list.bullet"
            case .favorite: "star"
            case .applied: "checkmark.seal"
            case .hidden: "eye.slash"
            }
        }

        var status: JobStatus? {
            switch self {
            case .results: nil
            case .favorite: .favorite
            case .applied: .applied
            case .hidden: .hidden
            }
        }
    }

    var list: JobList = .results
    var showHidden = false
    private(set) var tracked: [String: TrackedJob] = [:]

    func status(of job: Job) -> JobStatus? { tracked[job.key]?.status }
    func trackedEntry(for job: Job) -> TrackedJob? { tracked[job.key] }

    /// Counts rows as the list will show them, so a role saved across three
    /// offices reads as one saved role rather than three.
    func count(_ status: JobStatus) -> Int {
        jobs(with: status).count
    }

    /// Postings carrying one status, newest first.
    ///
    /// Built from the stored snapshots, not from the current scrape, so a role
    /// you've applied to is still here after the board takes it down.
    func jobs(with status: JobStatus) -> [Job] {
        let stored = tracked.values
            .filter { $0.status == status }
            .map { entry -> Job in
                var job = entry.job
                job.isNew = false
                job.variants = []      // rebuilt below, never trusted from disk
                return job
            }
            .sortedByRecency()
        // The saved lists merge too, so a role saved once doesn't come back as
        // one row per office.
        return mergeRoles ? stored.mergedByRole() : stored
    }

    // A scrape now keeps every category, so `jobs` runs to thousands of rows.
    // Filtering, merging and sorting that on every redraw — and the status bar
    // asks for it several times per pass — is far too much work to repeat.
    @ObservationIgnored private var visibleCacheKey = ""
    @ObservationIgnored private var visibleCache: [Job] = []
    @ObservationIgnored private var resultsVersion = 0

    private var visibleKey: String {
        "\(resultsVersion)|\(list.rawValue)|\(showHidden)|\(mergeRoles)|"
        + "\(selectedCategoryID)|\(level.rawValue)|\(search)|"
        + "\(tagFilter ?? "-")|\(sinceDays.map(String.init) ?? "-")|"
        + "\(newOnly)|\(locationFilter)|"
        + "\(continentFilter.sorted().joined(separator: ","))|"
        + "\(cityFilter.sorted().joined(separator: ","))"
    }

    /// Rows actually shown, for whichever list is selected.
    var visibleJobs: [Job] {
        let key = visibleKey
        if key == visibleCacheKey { return visibleCache }
        let computed = computeVisibleJobs()
        visibleCacheKey = key
        visibleCache = computed
        return computed
    }

    private func computeVisibleJobs() -> [Job] {
        if let status = list.status {
            // A saved list honours the search box and nothing else: category,
            // level and date filters exist to narrow a scrape, and applying
            // them here would hide applications you're trying to track.
            let q = query
            return jobs(with: status).filter { q.matchesSearch($0) }
        }

        let q = query
        let cutoff = q.cutoffDate
        let kept = jobs.filter { job in
            guard job.matchedCategories.contains(selectedCategoryID) else { return false }
            guard level == .any || job.matchedLevels.contains(level.rawValue) else {
                return false
            }
            guard q.matchesLiveFilters(job, cutoff: cutoff) else { return false }
            if !showHidden, tracked[job.key]?.status == .hidden { return false }
            return true
        }
        // Merge after filtering, so a city filter leaves a merged row holding
        // only the locations you asked for — then sort, because merging picks a
        // new primary row and would otherwise scramble the order.
        return (mergeRoles ? kept.mergedByRole() : kept).sortedByRecency()
    }

    /// How many results the hidden filter is currently holding back.
    /// Recomputed as filters change, so the badge always matches the list.
    var visibleNewCount: Int { visibleJobs.count { $0.isNew } }

    var hiddenInResults: Int {
        guard list == .results else { return 0 }
        let q = query
        let cutoff = q.cutoffDate
        return jobs.count { job in
            tracked[job.key]?.status == .hidden
                && q.matchesLiveFilters(job, cutoff: cutoff)
        }
    }

    // MARK: - Changing status

    func setStatus(_ status: JobStatus?, for targets: [Job]) {
        guard !targets.isEmpty else { return }
        let today = Job.dateFormatter.string(from: Date())
        for job in targets {
            // A merged row stands for several postings; marking it has to mark
            // all of them, or the ones folded in would come back unmarked the
            // moment merging is turned off.
            for (key, posting) in postings(of: job) {
                if let status {
                    var entry = tracked[key]
                        ?? TrackedJob(status: status, job: posting,
                                      updated: today, lastSeen: today)
                    entry.status = status
                    entry.updated = today
                    entry.job = posting          // keep the snapshot current
                    tracked[key] = entry
                } else {
                    tracked.removeValue(forKey: key)
                }
            }
        }
        ConfigStore.saveTracked(tracked)
        resultsVersion += 1
    }

    /// Splits a row back into the individual postings it stands for.
    ///
    /// Each one is stored on its own, with its own location and link. Storing
    /// the merged row against every key instead made the Saved list show the
    /// same role several times over.
    private func postings(of job: Job) -> [(key: String, job: Job)] {
        var primary = job
        primary.variants = []
        var out = [(job.key, primary)]
        for variant in job.variants {
            var copy = job
            copy.variants = []
            copy.location = variant.location
            copy.url = variant.url
            copy.posted = variant.posted
            copy.places = LocationParser.parse(variant.location)
            out.append((variant.key, copy))
        }
        return out
    }

    /// Flips a status off if it's already set, on otherwise.
    func toggleStatus(_ status: JobStatus, for targets: [Job]) {
        let allSet = targets.allSatisfy { tracked[$0.key]?.status == status }
        setStatus(allSet ? nil : status, for: targets)
    }

    func setNote(_ note: String, for job: Job) {
        guard var entry = tracked[job.key] else { return }
        entry.note = note
        tracked[job.key] = entry
        ConfigStore.saveTracked(tracked)
        resultsVersion += 1
    }

    /// Refresh snapshots and last-seen dates for anything a scrape just returned.
    private func refreshTracked(from results: [Job]) {
        guard !tracked.isEmpty else { return }
        let today = Job.dateFormatter.string(from: Date())
        var changed = false
        for job in results where tracked[job.key] != nil {
            var entry = tracked[job.key]!
            entry.job = job
            entry.lastSeen = today
            tracked[job.key] = entry
            changed = true
        }
        if changed {
            ConfigStore.saveTracked(tracked)
            resultsVersion += 1
        }
    }

    var firmsRepresented: Int { Set(visibleJobs.map(\.company)).count }

    // MARK: - Lifecycle

    private(set) var isLoaded = false

    /// Everything the config load produces, so it can be assembled off the
    /// main actor and handed back in one piece.
    private struct LoadedConfig: Sendable {
        var companies: [Company] = []
        var categories: [JobCategory] = []
        var seen: [String: String] = [:]
        var tracked: [String: TrackedJob] = [:]
        var comment: [String]?
        var cache: ConfigStore.ResultCache?
        var error: String?
    }

    /// Set while the table is showing last run's results rather than fresh ones.
    private(set) var showingCache = false
    private(set) var cacheDate: Date?

    /// Reads config off the main thread.
    ///
    /// This used to run in `init`, which meant the very first `open()` happened
    /// before the window existed — and if macOS decided to ask the user whether
    /// the app may read that folder (anything under ~/Desktop or ~/Documents
    /// will), the process sat blocked on the prompt with nothing on screen.
    // MARK: - Remembering the user's choices

    /// The full board editor, now reachable only from the Scrape menu.
    var showBoardEditor = false

    /// Checks GitHub for a newer release; see Updater.
    let updater = Updater()
    var refreshOnLaunch = true
    var refreshIfOlderThanHours = 6

    /// A cheap value that changes whenever any persisted setting does, so the
    /// view can watch one thing instead of twenty.
    var settingsFingerprint: String {
        [selectedCategoryID, level.rawValue, list.rawValue,
         tagFilter ?? "-", locationFilter,
         sinceDays.map(String.init) ?? "-",
         continentFilter.sorted().joined(separator: ","),
         cityFilter.sorted().joined(separator: ","),
         "\(newOnly)\(deep)\(mergeRoles)\(recordState)\(showHidden)",
         "\(refreshOnLaunch)\(refreshIfOlderThanHours)",
        ].joined(separator: "|")
    }

    var currentSettings: AppSettings {
        AppSettings(categoryID: selectedCategoryID, level: level.rawValue,
                    list: list.rawValue,
                    tagFilter: tagFilter, locationFilter: locationFilter,
                    sinceDays: sinceDays,
                    continents: continentFilter.sorted(),
                    cities: cityFilter.sorted(),
                    newOnly: newOnly, deep: deep, mergeRoles: mergeRoles,
                    recordState: recordState, showHidden: showHidden,
                    refreshOnLaunch: refreshOnLaunch,
                    refreshIfOlderThanHours: refreshIfOlderThanHours)
    }

    private func apply(_ s: AppSettings) {
        selectedCategoryID = s.categoryID
        level = Level(rawValue: s.level) ?? .intern
        list = JobList(rawValue: s.list) ?? .results
        tagFilter = s.tagFilter
        locationFilter = s.locationFilter
        sinceDays = s.sinceDays
        continentFilter = Set(s.continents)
        cityFilter = Set(s.cities)
        newOnly = s.newOnly
        deep = s.deep
        mergeRoles = s.mergeRoles
        recordState = s.recordState
        showHidden = s.showHidden
        refreshOnLaunch = s.refreshOnLaunch
        refreshIfOlderThanHours = s.refreshIfOlderThanHours
    }

    private var settingsSaveTask: Task<Void, Never>?

    /// Coalesced, so dragging a slider or typing doesn't write per keystroke.
    func persistSettings() {
        guard isLoaded else { return }      // don't save the pre-load defaults
        let snapshot = currentSettings
        settingsSaveTask?.cancel()
        settingsSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            snapshot.save()
        }
    }

    /// The filters that change *what gets fetched* rather than what's shown,
    /// so a change here has to go back to the boards.
    var refreshFingerprint: String {
        // Category and level are applied to what we already have, so they are
        // deliberately absent: only the set of boards and deep matching change
        // what has to be fetched.
        "\(selectedFirms.map(\.id).joined(separator: ","))|\(deep)"
    }

    private var refreshTask: Task<Void, Never>?

    /// Re-scrape shortly after a category/level/group change, coalescing the
    /// bursts you get from clicking along a segmented control.
    func scheduleRefresh() {
        guard isLoaded else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self else { return }
            self.scrape()
        }
    }

    /// Whether opening the app should kick off a run, or just show the cache.
    ///
    /// A full pass is ~106 boards and tens of thousands of postings; doing that
    /// every time the window opens is why startup felt slow.
    var shouldRefreshOnLaunch: Bool {
        guard refreshOnLaunch else { return false }
        guard let cacheDate else { return true }        // nothing cached yet
        let age = Date().timeIntervalSince(cacheDate) / 3600
        return age >= Double(refreshIfOlderThanHours)
    }

    /// How old the shown results are, for the status bar.
    var cacheAgeDescription: String? {
        guard let cacheDate else { return nil }
        let hours = Date().timeIntervalSince(cacheDate) / 3600
        if hours < 1 { return "updated just now" }
        if hours < 24 { return "updated \(Int(hours))h ago" }
        return "updated \(Int(hours / 24))d ago"
    }

    /// Set when the config read is taking long enough that something is
    /// probably blocking it — in practice, a macOS permission dialog.
    private(set) var loadStalled = false

    func reload() async {
        loadStalled = false
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, !self.isLoaded else { return }
            self.loadStalled = true
        }
        defer { watchdog.cancel() }

        let loaded = await Task.detached(priority: .userInitiated) {
            ConfigStore.seedIfNeeded()
            // Load the gazetteer before anything parses a location.
            LocationParser.gazetteer = ConfigStore.loadGazetteer()
            do {
                let file = try ConfigStore.loadCompanies()
                return LoadedConfig(
                    companies: file.companies,
                    categories: try ConfigStore.loadCategories(),
                    seen: ConfigStore.loadSeen(),
                    tracked: ConfigStore.loadTracked(),
                    comment: file.comment,
                    cache: ConfigStore.loadCache())
            } catch {
                return LoadedConfig(error:
                    "Couldn't read config in \(ConfigStore.directory.path): "
                    + error.localizedDescription)
            }
        }.value

        companies = loaded.companies
        fileComment = loaded.comment
        rebuildFirmIndex()
        categories = loaded.categories
        seen = loaded.seen
        tracked = loaded.tracked
        loadError = loaded.error
        if !categories.contains(where: { $0.name == selectedCategoryID }) {
            selectedCategoryID = categories.first?.name ?? "swe"
        }

        // The user's own choices win over whatever the cache happened to hold.
        let saved = AppSettings.load()
        apply(saved)
        if !categories.contains(where: { $0.name == selectedCategoryID }) {
            selectedCategoryID = categories.first?.name ?? "swe"
        }

        // Show last run's results straight away, then refresh behind them —
        // but only if they're the same query, or the table would be labelled
        // one thing while showing another.
        if let cache = loaded.cache, !cache.jobs.isEmpty,
           cache.category == selectedCategoryID, cache.level == level.rawValue {
            jobs = cache.jobs
            showingCache = true
            cacheDate = cache.savedAt
        }
        isLoaded = true
        loadStalled = false
    }

    // MARK: - Company config

    /// Kept from the last load. Re-reading and decoding the whole file on every
    /// save just to recover the comment block made each checkbox click do a
    /// full parse of 147 entries before writing.
    private var fileComment: [String]?
    private var saveTask: Task<Void, Never>?

    /// Coalesced write. Clicking through the tree fires a burst of changes and
    /// only the last state matters, so the disk write leaves the click path.
    /// Pick up edits made outside the app — by the CLI, or by editing
    /// companies.json by hand — instead of overwriting them.
    ///
    /// The two tools share one file, which the README sells as a feature, but
    /// the app read it once at launch and wrote its own copy back on every
    /// toggle. Anything changed on disk in between was silently lost the next
    /// time you clicked something. Cheap to re-read, and the window becoming
    /// active is exactly when you've come back from the other tool.
    func reloadCompaniesIfChangedOnDisk() {
        guard isLoaded, !isScraping, saveTask == nil,
              let onDisk = try? ConfigStore.loadCompanies(),
              onDisk.companies != companies else { return }

        // A firm whose *board* changed — a new adapter, a corrected token —
        // has rows fetched from the old one. Enabling or disabling it doesn't
        // matter, but re-pointing it does, and the incremental scrape would
        // otherwise keep serving what the previous source returned.
        let before = Dictionary(companies.map { ($0.name, $0.boardFingerprint) },
                                uniquingKeysWith: { a, _ in a })
        for firm in onDisk.companies where before[firm.name] != firm.boardFingerprint {
            fetchedFirms.remove(firm.name)
            jobs.removeAll { $0.company == firm.name }
        }
        companies = onDisk.companies
        fileComment = onDisk.comment
        rebuildFirmIndex()
        resultsVersion += 1
    }

    func saveCompanies() {
        rebuildFirmIndex()
        let snapshot = CompanyFile(comment: fileComment, companies: companies)
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await Task.detached(priority: .utility) {
                try? ConfigStore.saveCompanies(snapshot)
            }.value
            // Cleared so "is a write pending?" is answerable. Left set, it
            // stayed truthy forever after the first save.
            self?.saveTask = nil
        }
    }

    /// Flush a *pending* write early — before a scrape, so what runs matches
    /// what's on disk.
    ///
    /// Only when something is actually queued. Writing unconditionally meant a
    /// long-running app would stamp its in-memory roster over any edit made to
    /// companies.json from outside it.
    func flushCompanies() {
        guard saveTask != nil else { return }
        saveTask?.cancel()
        saveTask = nil
        try? ConfigStore.saveCompanies(
            CompanyFile(comment: fileComment, companies: companies))
    }

    func upsert(_ company: Company, replacing original: String?) {
        if let original, let i = companies.firstIndex(where: { $0.name == original }) {
            companies[i] = company
        } else {
            companies.append(company)
        }
        saveCompanies()
    }

    func delete(_ company: Company) {
        companies.removeAll { $0.name == company.name }
        saveCompanies()
    }

    /// Writes an explicit value rather than flipping.
    ///
    /// This used to be a `toggle()` driven by a Binding whose setter ignored the
    /// value it was handed — so a redundant write from SwiftUI silently flipped
    /// a board instead of doing nothing. The equality guard makes those writes
    /// the no-ops they should always have been.
    func setEnabled(_ value: Bool, for id: Company.ID) {
        guard let i = indexByID[id], i < companies.count,
              companies[i].enabled != value else { return }
        companies[i].enabled = value
        saveCompanies()
    }

    /// Bulk enable/disable. Unconfigured entries can only ever be turned off —
    /// switching on a board with no slug just buys a failure on every run.
    func setEnabled(_ value: Bool, for ids: some Collection<Company.ID>) {
        let wanted = Set(ids)
        var changed = false
        for i in companies.indices where wanted.contains(companies[i].id) {
            let target = value && companies[i].isConfigured
            if companies[i].enabled != target {
                companies[i].enabled = target
                changed = true
            }
        }
        if changed { saveCompanies() }
    }

    /// The selection as it was before the last preset, so a misclick that
    /// replaces a curated roster is one button away from being undone.
    private(set) var undoableSelection: [Company.ID: Bool]?

    func snapshotSelection() {
        undoableSelection = Dictionary(companies.map { ($0.id, $0.enabled) },
                                       uniquingKeysWith: { a, _ in a })
    }

    func undoSelectionChange() {
        guard let snapshot = undoableSelection else { return }
        for i in companies.indices {
            if let was = snapshot[companies[i].id] { companies[i].enabled = was }
        }
        undoableSelection = nil
        saveCompanies()
        rebuildFirmIndex()
        resultsVersion += 1
    }

    /// "I'm not interested in this firm" straight from a job row: switches the
    /// board off and drops its rows from the current results, so the decision
    /// takes effect without waiting for a re-scrape.
    func dismissCompany(named name: String) {
        setEnabled(false, for: [name])
        jobs.removeAll { $0.company == name }
        for (key, entry) in tracked where entry.job.company == name
            && entry.status == .hidden {
            tracked.removeValue(forKey: key)
        }
        ConfigStore.saveTracked(tracked)
        resultsVersion += 1
    }

    func isDelisted(_ job: Job) -> Bool { tracked[job.key]?.isDelisted ?? false }

    // MARK: - The firm tree

    struct FirmTierNode: Identifiable, Sendable {
        let segment: String
        let ids: [Company.ID]
        let usable: Int              // how many are actually configured
        var id: String { segment }
    }

    struct FirmGroupNode: Identifiable, Sendable {
        let group: String
        let tiers: [FirmTierNode]
        let ids: [Company.ID]
        let usable: Int
        var id: String { group }
    }

    /// Precomputed once per structural change.
    ///
    /// The tree used to filter and sort all 147 firms inside every row body —
    /// a few dozen full scans per redraw, on every click.
    private(set) var firmTree: [FirmGroupNode] = []
    private var indexByID: [Company.ID: Int] = [:]

    func rebuildFirmIndex() {
        indexByID = Dictionary(uniqueKeysWithValues:
            companies.enumerated().map { ($0.element.id, $0.offset) })

        firmTree = Self.groups.map { group in
            let members = companies
                .filter { $0.tags.contains(group) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name)
                            == .orderedAscending }
            // A deliberate order — tiers ascending, big tech most-wanted
            // first. Sorting by size put "Tier 2" above "Tier 1".
            let order = ["Tier 1", "Tier 2", "Tier 3",
                         "FAANG+", "Frontier AI", "Startups"]
            let segments = Dictionary(grouping: members, by: \.segment)
                .sorted {
                    let a = order.firstIndex(of: $0.key) ?? Int.max
                    let b = order.firstIndex(of: $1.key) ?? Int.max
                    return a == b ? $0.key < $1.key : a < b
                }
            let tiers = segments.map { name, firms in
                FirmTierNode(segment: name, ids: firms.map(\.id),
                             usable: firms.count { $0.isConfigured })
            }
            return FirmGroupNode(group: group, tiers: tiers,
                                 ids: members.map(\.id),
                                 usable: members.count { $0.isConfigured })
        }
    }

    func company(_ id: Company.ID) -> Company? {
        guard let i = indexByID[id], i < companies.count else { return nil }
        return companies[i]
    }

    func enabledCount(_ ids: [Company.ID]) -> Int {
        ids.count { company($0)?.enabled == true }
    }

    /// Checkbox state for a whole branch: off, mixed, or on.
    enum Checked { case off, mixed, on }

    func checkState(_ ids: [Company.ID], usable: Int) -> Checked {
        guard usable > 0 else { return .off }
        let on = enabledCount(ids)
        if on == 0 { return .off }
        return on >= usable ? .on : .mixed
    }

    /// Flip a whole branch. Anything already fully on gets turned off.
    func toggleBranch(_ ids: [Company.ID], usable: Int) {
        setEnabled(checkState(ids, usable: usable) != .on, for: ids)
    }

    func ids(inGroup group: String?) -> [Company.ID] {
        companies.filter { group == nil || $0.tags.contains(group!) }.map(\.id)
    }

    /// The firms a scrape would actually hit, honouring enabled + both filters.
    var selectedFirms: [Company] {
        companies.filter { c in
            guard c.enabled, c.isConfigured else { return false }
            if let tagFilter, !c.tags.contains(tagFilter) { return false }
            return true
        }
    }

    // MARK: - Scraping

    /// Which firms the rows on screen came from, and whether they were fetched
    /// with deep matching. Lets a selection change fetch only the difference.
    private var fetchedFirms: Set<String> = []
    private var fetchedDeep = false

    /// `full` forces every selected board to be refetched — what ⌘R means.
    /// Otherwise only boards we have no rows for are visited, so adding one
    /// firm to a selection of a hundred costs one request, not a hundred.
    func scrape(full: Bool = false) {
        let selected = selectedFirms
        guard !selected.isEmpty else { return }

        // Deep matching changes what each board returns, so it invalidates
        // everything; otherwise keep what we have and fetch the difference.
        let reusable = !full && deep == fetchedDeep && !showingCache
        let keep = reusable ? fetchedFirms.intersection(selected.map(\.name)) : []
        let firms = selected.filter { !keep.contains($0.name) }

        // Rows from firms that just left the selection shouldn't linger.
        if reusable {
            let wanted = Set(selected.map(\.name))
            let before = jobs.count
            jobs.removeAll { !wanted.contains($0.company) }
            if jobs.count != before { resultsVersion += 1 }
        }

        guard !firms.isEmpty else {
            // Everything on screen already covers the selection — nothing to
            // fetch, so just let the table re-filter.
            fetchedFirms = keep
            resultsVersion += 1
            return
        }

        // A selection change while a run is in flight supersedes it rather than
        // being dropped, which used to leave the results not matching the
        // controls until you pressed ⌘R. Stale callbacks are ignored by runID.
        if isScraping { task?.cancel() }

        flushCompanies()
        let matchers = categories.map(CategoryMatcher.init)
        let q = query
        let known = seen

        // Cached rows stay on screen until the first board answers, so the
        // table never blinks to empty on a refresh.
        if !showingCache && keep.isEmpty { jobs = [] }
        failures = []
        runID += 1
        let run = runID
        scanned = 0
        total = firms.count
        newCount = 0
        isScraping = true
        replacingCache = showingCache
        fetchedDeep = q.deep
        fetchedFirms = keep

        task = Task { [weak self] in
            guard let self else { return }
            // Rows land as each board answers, so the table fills in rather than
            // sitting blank behind a spinner.
            await Scraper.run(firms, deep: q.deep) { result in
                // Tag every posting with the categories and levels it matches,
                // then keep anything that landed in at least one category. That
                // makes switching category or level a filter, not a re-fetch.
                var kept: [Job] = []
                for var job in result.jobs {
                    let raw = RawJob(title: job.title, location: job.location,
                                     url: job.url, posted: job.posted,
                                     department: job.department,
                                     description: job.description)
                    let cats = matchers.filter { $0.acceptsCategory(raw, deep: q.deep) }
                    guard !cats.isEmpty else { continue }
                    job.matchedCategories = Set(cats.map(\.name))
                    job.matchedLevels = Set(Level.allCases
                        .filter { Levels.matches($0, title: job.title,
                                                 department: job.department) }
                        .map(\.rawValue))
                    // The legacy key too, so the run after the key changed
                    // doesn't announce every posting as new.
                    job.isNew = known[job.key] == nil && known[job.legacyKey] == nil
                    kept.append(job)
                }
                // Every key the board returned, before the category filter —
                // that's what "is this posting still listed?" has to be judged
                // against, or a swe-only run would call every quant role dead.
                let allKeys = result.jobs.map(\.key)
                await self.ingest(result, keeping: kept, allKeys: allKeys, run: run)
            }
            self.finishScrape(run: run)
        }
    }

    private var replacingCache = false
    private var scrapedKeys: Set<String> = []
    private var scrapedCompanies: Set<String> = []

    private func ingest(_ result: BoardResult, keeping batch: [Job],
                        allKeys: [String], run: Int) {
        guard run == runID else { return }      // a superseded scrape reporting in
        // First board home: swap the cached rows out for live ones.
        if replacingCache {
            replacingCache = false
            showingCache = false
            jobs = []
        }
        scanned += 1
        // Counted either way: a board that failed has been visited, and
        // retrying it on every filter tweak would make the app crawl. ⌘R
        // refetches everything.
        fetchedFirms.insert(result.company.name)
        if let reason = result.failure {
            failures.append(ScrapeFailure(company: result.company.name, reason: reason))
        } else {
            scrapedCompanies.insert(result.company.name)
            scrapedKeys.formUnion(allKeys)
        }
        jobs.append(contentsOf: batch)
        resultsVersion += 1
    }

    private func finishScrape(run: Int) {
        guard run == runID else { return }
        if replacingCache {          // every board failed; keep what we had
            replacingCache = false
        } else {
            showingCache = false
        }
        jobs = jobs.deduplicated().sortedByRecency()
        resultsVersion += 1
        // Count what the table shows, not the whole cache — now that a scrape
        // keeps every category, the raw figure was in the thousands.
        newCount = visibleJobs.filter(\.isNew).count
        isScraping = false
        lastRun = Date()
        if recordState { recordSeen(jobs) }
        refreshTracked(from: jobs)
        reconcileTracked()

        ConfigStore.saveCache(ConfigStore.ResultCache(
            savedAt: Date(),
            category: selectedCategoryID,
            level: level.rawValue,
            jobs: jobs))
        scrapedKeys = []
        scrapedCompanies = []
    }

    /// Works out which saved postings have gone from the boards.
    ///
    /// Only firms that actually answered this run are judged — a board that
    /// was off or failed says nothing about whether its roles still exist.
    private func reconcileTracked() {
        guard !tracked.isEmpty, !scrapedCompanies.isEmpty else { return }
        var changed = false

        for (key, entry) in tracked {
            guard scrapedCompanies.contains(entry.job.company) else { continue }
            let stillListed = scrapedKeys.contains(key)

            if stillListed {
                if tracked[key]?.isDelisted == true {
                    tracked[key]?.isDelisted = false      // it came back
                    changed = true
                }
            } else if entry.status == .hidden {
                // Nothing to keep: a hidden posting that's gone is just noise.
                tracked.removeValue(forKey: key)
                changed = true
            } else if !entry.isDelisted {
                // Saved and applied roles stay, flagged rather than deleted.
                tracked[key]?.isDelisted = true
                changed = true
            }
        }
        if changed {
            ConfigStore.saveTracked(tracked)
            resultsVersion += 1
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isScraping = false
    }

    private func recordSeen(_ jobs: [Job]) {
        let today = Job.dateFormatter.string(from: Date())
        for j in jobs where seen[j.key] == nil { seen[j.key] = today }
        ConfigStore.saveSeen(seen)
    }

    /// Forget every posting we've shown before, so everything reads as new again.
    func resetSeen() {
        seen = [:]
        ConfigStore.saveSeen(seen)
        for i in jobs.indices { jobs[i].isNew = true }
        newCount = jobs.count
    }

    // MARK: - Verify

    struct VerifyResult: Identifiable, Sendable {
        var company: String
        var ats: ATS
        var identifier: String
        var count: Int
        var failure: String?
        var id: String { company }
        var ok: Bool { failure == nil }
    }

    private(set) var verifyResults: [VerifyResult] = []
    private(set) var isVerifying = false

    func verify(includeDisabled: Bool) {
        guard !isVerifying else { return }
        let firms = includeDisabled
            ? companies.filter(\.isConfigured)
            : companies.filter { $0.enabled && $0.isConfigured }

        verifyResults = []
        isVerifying = true

        Task { [weak self] in
            guard let self else { return }
            await Scraper.run(firms, deep: false) { result in
                await self.record(VerifyResult(
                    company: result.company.name,
                    ats: result.company.ats,
                    identifier: result.company.identifier,
                    count: result.jobs.count,
                    failure: result.failure))
            }
            self.finishVerify()
        }
    }

    private func record(_ result: VerifyResult) {
        verifyResults.append(result)
    }

    private func finishVerify() {
        // Broken boards first — those are the ones worth acting on.
        verifyResults.sort { a, b in a.ok == b.ok ? a.company < b.company : !a.ok }
        isVerifying = false
    }

    // MARK: - Export

    enum ExportFormat: String, CaseIterable, Identifiable {
        case csv, json, md
        var id: String { rawValue }
        var label: String {
            switch self {
            case .csv: "CSV"
            case .json: "JSON"
            case .md: "Markdown"
            }
        }
    }

    func exportText(_ format: ExportFormat) -> String {
        let rows = visibleJobs
        switch format {
        case .csv:
            var out = "company,title,location,level,posted,department,url\n"
            for r in rows {
                let cells = [r.company, r.title, r.location, r.level,
                             r.posted, r.department, r.url]
                out += cells.map(csvCell).joined(separator: ",") + "\n"
            }
            return out

        case .json:
            let payload = rows.map { r -> [String: String] in
                ["company": r.company, "title": r.title, "location": r.location,
                 "level": r.level, "posted": r.posted, "department": r.department,
                 "url": r.url]
            }
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            guard let data = try? enc.encode(payload) else { return "[]" }
            return String(decoding: data, as: UTF8.self)

        case .md:
            var out = "| Company | Role | Location | Level | Posted | Link |\n"
            out += "|---|---|---|---|---|---|\n"
            for r in rows {
                let title = r.title.replacingOccurrences(of: "|", with: "\\|")
                out += "| \(r.company) | \(title) | \(r.location) | "
                out += "\(r.level) | \(r.posted) | [apply](\(r.url)) |\n"
            }
            return out
        }
    }

    private func csvCell(_ s: String) -> String {
        guard s.contains(",") || s.contains("\"") || s.contains("\n") else { return s }
        return "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
