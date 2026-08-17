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
            || newOnly || deep || appliedFilter.isFiltering || !excludedStacks.isEmpty || intakeFilter != nil
            || !search.isEmpty
            || !locationFilter.isEmpty
            || !continentFilter.isEmpty || !cityFilter.isEmpty
    }

    func clearFilters() {
        tagFilter = nil
        sinceDays = nil
        newOnly = false
        deep = false
        appliedFilter = .show
        excludedStacks = []
        intakeFilter = nil
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

        /// The ones the sidebar offers. `.results` isn't a list you pick — it's
        /// the mode you're in when a category is selected, and the Everything
        /// category already means "all roles".
        static var pickable: [JobList] { allCases.filter { $0.status != nil } }
    }

    var list: JobList = .results
    var showHidden = false
    /// What the results list does about roles you've already applied to.
    /// Results only — the Applied list is where they live either way.
    var appliedFilter: AppliedFilter = .show
    /// Stacks to leave out. Ticking one removes those roles; empty means keep
    /// everything.
    ///
    /// Exclusion rather than inclusion because that's the shape of the request:
    /// "not Python, not UI, anything else is fine" is one tick per unwanted
    /// stack. As an include list the same thing needed a tick on every stack you
    /// would accept *plus* one on "unspecified" — three ticks to express one
    /// exclusion, and unusable if you forgot the last one, since 87% of roles
    /// name no stack at all.
    var excludedStacks: Set<String> = []
    /// Which intake year to keep. Nil means every year.
    var intakeFilter: Int?
    /// Stage sections folded shut in the Applied list.
    var collapsedStages: Set<Stage> = []
    private(set) var tracked: [String: TrackedJob] = [:]

    func trackedEntry(for job: Job) -> TrackedJob? { tracked[job.key] }

    func isSaved(_ job: Job) -> Bool { tracked[job.key]?.saved == true }
    func isHidden(_ job: Job) -> Bool { tracked[job.key]?.hidden == true }
    func stage(of job: Job) -> Stage? { tracked[job.key]?.stage }
    func hasApplication(_ job: Job) -> Bool {
        tracked[job.key]?.hasApplication == true
    }

    /// Whether one of the three marks is set — what the row buttons and the
    /// context menu read. The switch lives on TrackedJob, so this and the list
    /// filter can't drift apart.
    func isSet(_ status: JobStatus, for job: Job) -> Bool {
        tracked[job.key]?.carries(status) ?? false
    }

    /// Counts rows as the list will show them, so a role saved across three
    /// offices reads as one saved role rather than three.
    func count(_ status: JobStatus) -> Int {
        jobs(with: status).count
    }

    /// Postings carrying one mark, newest first — or, for applications, by when
    /// they last moved, since that's what you came to the list to see.
    ///
    /// Built from the stored snapshots, not from the current scrape, so a role
    /// you've applied to is still here after the board takes it down.
    func jobs(with status: JobStatus) -> [Job] {
        let entries = tracked.values.filter { $0.carries(status) }
        let stored: [Job]
        if status == .applied {
            stored = entries
                .sorted { $0.lastActivity > $1.lastActivity }
                .map(Self.snapshot)
        } else {
            stored = entries.map(Self.snapshot).sortedByRecency()
        }
        // The saved lists merge too, so a role saved once doesn't come back as
        // one row per office.
        return mergeRoles ? stored.mergedByRole() : stored
    }

    private static func snapshot(_ entry: TrackedJob) -> Job {
        var job = entry.job
        job.isNew = false
        job.variants = []          // rebuilt by the merge, never trusted from disk
        return job
    }

    // A scrape now keeps every category, so `jobs` runs to thousands of rows.
    // Filtering, merging and sorting that on every redraw — and the status bar
    // asks for it several times per pass — is far too much work to repeat.
    @ObservationIgnored private var visibleCacheKey = ""
    @ObservationIgnored private var visibleCache: [Job] = []
    @ObservationIgnored private var resultsVersion = 0

    private var visibleKey: String {
        "\(resultsVersion)|\(list.rawValue)|\(showHidden)|\(appliedFilter.rawValue)|\(mergeRoles)|"
        + "\(excludedStacks.sorted().joined(separator: ","))|"
        + "\(intakeFilter.map(String.init) ?? "-")|"
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
            heldHidden = 0; heldApplied = 0
            return jobs(with: status).filter { q.matchesSearch($0) }

        }

        // One pass. Measuring "rows the list would gain if this filter were off"
        // needed a second and third full filter+merge+sort, because the marks are
        // applied before the merge — and at "All levels" across every board that
        // tripled the cost of every filter change. The tally now comes out of the
        // same pass, counting postings, which is what the banner has always said.
        return resultRows(showHidden: showHidden, applied: appliedFilter)
    }

    /// The results list under a given pair of mark filters.
    ///
    /// The marks are applied *before* the merge, deliberately: hiding one office
    /// of a role posted in four should leave the other three, which dropping
    /// whole merged rows wouldn't.
    private func resultRows(showHidden: Bool, applied: AppliedFilter) -> [Job] {
        let q = query
        let cutoff = q.cutoffDate
        // Built once, not per posting.
        let firms = applied == .firms ? appliedFirms : []
        var hiddenHeld = 0, appliedHeld = 0
        let kept = jobs.filter { job in
            guard job.matchedCategories.contains(selectedCategoryID) else { return false }
            guard level == .any || job.matchedLevels.contains(level.rawValue) else {
                return false
            }
            guard q.matchesLiveFilters(job, cutoff: cutoff) else { return false }
            // A posting goes only if it names something you excluded. Naming
            // nothing can never exclude it, which is what keeps the majority.
            if !excludedStacks.isEmpty,
               !job.matchedStacks.isDisjoint(with: excludedStacks) {
                return false
            }
            // A posting that names no year is kept: most don't, and dropping them
            // would be the same mistake the stack filter started out making.
            if let wanted = intakeFilter, let year = job.intakeYear, year != wanted {
                return false
            }
            let entry = tracked[job.key]
            if entry?.hidden == true {
                hiddenHeld += 1
                if !showHidden { return false }
            }
            switch applied {
            case .show:
                break
            case .roles:
                if entry?.hasApplication == true { appliedHeld += 1; return false }
            case .firms:
                if firms.contains(job.company) { appliedHeld += 1; return false }
            }
            return true
        }
        heldHidden = hiddenHeld
        heldApplied = appliedHeld
        // Merge after filtering, so a city filter leaves a merged row holding
        // only the locations you asked for — then sort, because merging picks a
        // new primary row and would otherwise scramble the order.
        return (mergeRoles ? kept.mergedByRole() : kept).sortedByRecency()
    }

    /// The Applied list, split into one block per stage in pipeline order.
    ///
    /// Empty stages are left out — a section header for a stage you've never
    /// reached is noise, and the sections are how you fold the list down to the
    /// part you're actually waiting on.
    struct StageGroup: Identifiable, Sendable {
        let stage: Stage
        let jobs: [Job]
        var id: String { stage.rawValue }
    }

    var appliedGroups: [StageGroup] {
        let rows = visibleJobs
        var byStage: [Stage: [Job]] = [:]
        for job in rows {
            guard let stage = tracked[job.key]?.stage else { continue }
            byStage[stage, default: []].append(job)
        }
        return Stage.allCases.compactMap { stage in
            guard let jobs = byStage[stage] else { return nil }
            return StageGroup(stage: stage, jobs: jobs)
        }
    }

    /// Firms you have at least one application at. Cached against the tracking
    /// dictionary's size and version rather than rebuilt per posting, since the
    /// filter asks for it once per pass over tens of thousands of rows.
    private var appliedFirms: Set<String> {
        Set(tracked.values.lazy.filter(\.hasApplication).map { $0.job.company })
    }

    /// Categories that name a parent describe a stack, not a discipline: they're
    /// offered as a filter rather than as a place to navigate to.
    var stackCategories: [JobCategory] { categories.filter { $0.parent != nil } }
    var navCategories: [JobCategory] { categories.filter { $0.parent == nil } }

    /// Intake years present in the current results, newest first, so the menu only
    /// ever offers a year you could actually pick.
    var availableIntakes: [(year: Int, count: Int)] {
        var tally: [Int: Int] = [:]
        for job in jobs where job.matchedCategories.contains(selectedCategoryID) {
            if let y = job.intakeYear { tally[y, default: 0] += 1 }
        }
        return tally.map { (year: $0.key, count: $0.value) }.sorted { $0.year > $1.year }
    }

    var intakeLabel: String { intakeFilter.map { "\($0) intake" } ?? "Any year" }

    func toggleStack(_ name: String) {
        if excludedStacks.contains(name) { excludedStacks.remove(name) }
        else { excludedStacks.insert(name) }
    }

    /// "All stacks" / "No Python" / "No Python +1" — the filter-row label, which
    /// states what's being left out rather than what's being kept.
    var stackLabel: String {
        guard !excludedStacks.isEmpty else { return "All stacks" }
        let names = excludedStacks.sorted()
        let short = { (n: String) -> String in
            self.categories.first { $0.name == n }?.shortName ?? n.capitalized
        }
        return names.count == 1 ? "No \(short(names[0]))"
                                : "No \(short(names[0])) +\(names.count - 1)"
    }

    func isCollapsed(_ stage: Stage) -> Bool { collapsedStages.contains(stage) }

    func toggleCollapsed(_ stage: Stage) {
        if collapsedStages.contains(stage) {
            collapsedStages.remove(stage)
        } else {
            collapsedStages.insert(stage)
        }
    }

    /// How many results the hidden filter is currently holding back.
    /// Recomputed as filters change, so the badge always matches the list.
    var visibleNewCount: Int { visibleJobs.count { $0.isNew } }

    /// How many postings each mark filter is currently holding back, filled in
    /// by the same pass that builds the list so the numbers always agree with
    /// it. Two Ints rather than a dictionary: it's written on the filter path.
    @ObservationIgnored private var heldHidden = 0
    @ObservationIgnored private var heldApplied = 0

    var hiddenInResults: Int {
        guard list == .results else { return 0 }
        _ = visibleJobs                       // makes sure the tally is current
        return heldHidden
    }

    /// What "Hide applied" is keeping back, so the chip can say how many rather
    /// than leaving you to wonder whether it did anything.
    var appliedInResults: Int {
        guard list == .results else { return 0 }
        _ = visibleJobs
        return heldApplied
    }

    // MARK: - Changing status

    /// Applies an edit to every posting a row stands for.
    ///
    /// A merged row covers several postings; marking it has to mark all of them,
    /// or the ones folded in come back unmarked the moment merging is turned off.
    /// An entry with nothing left set is dropped rather than kept as a husk.
    private func edit(_ targets: [Job], _ change: (inout TrackedJob) -> Void) {
        guard !targets.isEmpty else { return }
        let today = Dates.today
        for job in targets {
            for (key, posting) in postings(of: job) {
                var entry = tracked[key]
                    ?? TrackedJob(job: posting, updated: today, lastSeen: today)
                change(&entry)
                entry.updated = today
                entry.job = posting              // keep the snapshot current
                if entry.isEmpty {
                    tracked.removeValue(forKey: key)
                } else {
                    tracked[key] = entry
                }
            }
        }
        ConfigStore.saveTracked(tracked)
        resultsVersion += 1
    }

    func setSaved(_ value: Bool, for targets: [Job]) {
        edit(targets) { $0.saved = value }
    }

    func setHidden(_ value: Bool, for targets: [Job]) {
        edit(targets) { $0.hidden = value }
    }

    /// Records a step, dated today unless a date is given. Recording the same
    /// step again just moves its date, so this doubles as "correct that".
    /// `repeating` records another occurrence instead of moving the existing one's
    /// date — a second online assessment rather than a correction to the first.
    func record(_ stage: Stage, on date: String? = nil, repeating: Bool = false,
                for targets: [Job]) {
        let when = date ?? Dates.today
        edit(targets) { $0.record(stage, on: when, repeating: repeating) }
    }

    /// Records that a sat step was actually sat — or unrecords it, with `on` nil.
    /// Keyed by the arrival date so a second OA doesn't overwrite the first.
    func markDone(_ stage: Stage, dated: String, on date: String?,
                  for targets: [Job]) {
        edit(targets) { entry in
            if let date { entry.markDone(stage, dated: dated, on: date) }
            else { entry.clearDone(stage, dated: dated) }
        }
    }

    func removeStage(_ stage: Stage, for targets: [Job]) {
        edit(targets) { $0.remove(stage) }
    }

    /// Throws away the whole application history. Kept separate from the marks
    /// because it's the one destructive edit here.
    func clearApplication(for targets: [Job]) {
        edit(targets) { $0.milestones = [] }
    }

    /// Drops every mark on a posting.
    func clearAll(for targets: [Job]) {
        edit(targets) {
            $0.saved = false; $0.hidden = false; $0.milestones = []
        }
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

    /// Flips a mark off if it's already set, on otherwise.
    ///
    /// Turning `applied` off drops the whole history, which is the only way to
    /// undo the button that set it — so callers that might be discarding several
    /// steps ask first.
    func toggleStatus(_ status: JobStatus, for targets: [Job]) {
        let allSet = targets.allSatisfy { isSet(status, for: $0) }
        switch status {
        case .favorite: setSaved(!allSet, for: targets)
        case .hidden: setHidden(!allSet, for: targets)
        case .applied:
            if allSet { clearApplication(for: targets) }
            else { record(.applied, for: targets) }
        }
    }

    /// How many recorded steps toggling `applied` off would discard.
    func stepsAtRisk(_ targets: [Job]) -> Int {
        targets.reduce(0) { $0 + (tracked[$1.key]?.milestones.count ?? 0) }
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
        // Built in pieces rather than one literal: at a dozen interpolations in a
        // single array the type checker gives up.
        var parts: [String] = [selectedCategoryID, level.rawValue, list.rawValue]
        parts.append(tagFilter ?? "-")
        parts.append(locationFilter)
        parts.append(sinceDays.map(String.init) ?? "-")
        parts.append(continentFilter.sorted().joined(separator: ","))
        parts.append(cityFilter.sorted().joined(separator: ","))
        parts.append("\(newOnly)\(deep)\(mergeRoles)\(recordState)")
        parts.append("\(showHidden)\(appliedFilter.rawValue)")
        parts.append(excludedStacks.sorted().joined(separator: ","))
        parts.append(intakeFilter.map(String.init) ?? "-")
        parts.append(collapsedStages.map(\.rawValue).sorted().joined(separator: ","))
        parts.append("\(refreshOnLaunch)\(refreshIfOlderThanHours)")
        return parts.joined(separator: "|")
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
                    appliedFilter: appliedFilter.rawValue,
                    stacks: excludedStacks.sorted(),
                    intakeFilter: intakeFilter,
                    collapsedStages: collapsedStages.map(\.rawValue).sorted(),
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
        appliedFilter = AppliedFilter(rawValue: s.appliedFilter) ?? .show
        excludedStacks = Set(s.stacks)
        intakeFilter = s.intakeFilter
        collapsedStages = Set(s.collapsedStages.compactMap(Stage.init(rawValue:)))
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
        // navCategories, not categories: a stack persisted as the selected
        // category from before they became a filter would otherwise stick, and
        // its rows can no longer be reached from the sidebar.
        if !navCategories.contains(where: { $0.name == selectedCategoryID }) {
            selectedCategoryID = navCategories.first?.name ?? "swe"
        }

        // The user's own choices win over whatever the cache happened to hold.
        let saved = AppSettings.load()
        apply(saved)
        // navCategories, not categories: a stack persisted as the selected
        // category from before they became a filter would otherwise stick, and
        // its rows can no longer be reached from the sidebar.
        if !navCategories.contains(where: { $0.name == selectedCategoryID }) {
            selectedCategoryID = navCategories.first?.name ?? "swe"
        }

        // Show last run's results straight away, then refresh behind them —
        // but only if they're the same query, or the table would be labelled
        // one thing while showing another.
        if let cache = loaded.cache, !cache.jobs.isEmpty,
           cache.category == selectedCategoryID, cache.level == level.rawValue {
            // firstSeen isn't persisted (see Job.firstSeen), so restore it here or
            // every undated cached row would show "–" until the next scrape.
            jobs = cache.jobs.map { job in
                guard job.posted.isEmpty else { return job }
                var copy = job
                copy.firstSeen = seen[job.key] ?? seen[job.legacyKey] ?? ""
                return copy
            }
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
        //
        // Compared as a set per firm, not one fingerprint per firm: a firm can
        // have several boards, and matching only the first would call every
        // other one re-pointed on every reload — a full refetch each time the
        // window came forward.
        func boards(_ list: [Company]) -> [String: Set<String>] {
            Dictionary(grouping: list, by: \.name)
                .mapValues { Set($0.map(\.boardFingerprint)) }
        }
        let before = boards(companies), after = boards(onDisk.companies)
        for (name, prints) in after where before[name] != prints {
            fetchedFirms.subtract(companies.filter { $0.name == name }.map(\.id))
            jobs.removeAll { $0.company == name }
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

    /// `original` is a `Company.ID`, not a name — a firm can have more than one
    /// board, and keying on the name would edit or delete both.
    func upsert(_ company: Company, replacing original: Company.ID?) {
        if let original, let i = companies.firstIndex(where: { $0.id == original }) {
            companies[i] = company
        } else {
            companies.append(company)
        }
        saveCompanies()
    }

    func delete(_ company: Company) {
        companies.removeAll { $0.id == company.id }
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
            && entry.hidden && !entry.saved && !entry.hasApplication {
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
        // `uniqueKeysWithValues` traps on a collision, and companies.json is a
        // file people hand-edit — two byte-identical entries shouldn't be able
        // to kill the app on launch. First one wins.
        indexByID = Dictionary(
            companies.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { first, _ in first })

        firmTree = Self.groups.map { group in
            let members = companies
                .filter { $0.tags.contains(group) }
                // displayName, not name: Swift's sort isn't stable, so two
                // boards of the same firm would swap places between rebuilds.
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
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

    /// Which *boards* the rows on screen came from, and whether they were
    /// fetched with deep matching. Lets a selection change fetch only the
    /// difference. Keyed by `Company.ID` rather than name, so switching on a
    /// firm's second board doesn't count as already visited because its first
    /// one was.
    private var fetchedFirms: Set<Company.ID> = []
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
        let keep = reusable ? fetchedFirms.intersection(selected.map(\.id)) : []
        let firms = selected.filter { !keep.contains($0.id) }

        // Rows from firms that just left the selection shouldn't linger. Names,
        // not ids: a posting only knows which firm it came from, not which of
        // that firm's boards.
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
        // Each sub-category is handed its parent, so "cpp" means the SWE roles
        // that are C++ rather than anything C++.
        let byName = Dictionary(categories.map { ($0.name, $0) },
                                uniquingKeysWith: { a, _ in a })
        let today = Dates.today
        let matchers = navCategories.map {
            CategoryMatcher($0, parent: $0.parent.flatMap { byName[$0] })
        }
        // Stack matchers are ungated on purpose: "does this posting mention C++"
        // is worth answering in any category, and the parent only records which
        // discipline the stack belongs to.
        let stackMatchers = stackCategories.map { CategoryMatcher($0) }
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
                    job.matchedStacks = Set(stackMatchers
                        .filter { $0.acceptsCategory(raw, deep: q.deep) }
                        .map(\.name))
                    job.matchedLevels = Set(Level.allCases
                        .filter { Levels.matches($0, title: job.title,
                                                 department: job.department) }
                        .map(\.rawValue))
                    // The legacy key too, so the run after the key changed
                    // doesn't announce every posting as new.
                    job.isNew = known[job.key] == nil && known[job.legacyKey] == nil
                    // Stand-in date for boards that state none. Today for one we
                    // have never seen, since that's when we first saw it.
                    if job.posted.isEmpty {
                        job.firstSeen = known[job.key] ?? known[job.legacyKey] ?? today
                    }
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
        fetchedFirms.insert(result.company.id)
        if let reason = result.failure {
            failures.append(ScrapeFailure(company: result.company.displayName,
                                          reason: reason))
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
            } else if !entry.isDelisted {
                // Nothing is deleted here any more. This used to drop a hidden
                // posting once the board stopped listing it, on the grounds that
                // it was just noise — but hiding something is a decision, and the
                // pass ran on every launch, so a run that didn't happen to return
                // a posting quietly threw that decision away. 23 hidden roles went
                // that way, and restoring them was futile until this changed: the
                // next launch scraped and deleted them again.
                //
                // They're flagged instead, like saved and applied ones, and only
                // ever surface in the Hidden list.
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
