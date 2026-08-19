import Foundation

/// Everything the user picks in the UI, so a launch comes back the way they
/// left it rather than resetting to the defaults every time.
///
/// This lives in UserDefaults rather than the shared config folder: it's the
/// app's own view state, and the CLI has no use for it.
struct AppSettings: Codable, Sendable, Equatable {

    var categoryID = "swe"
    var level = Level.intern.rawValue
    var list = "results"

    var tagFilter: String?
    var locationFilter = ""
    var sinceDays: Int?
    var continents: [String] = []
    var cities: [String] = []

    var newOnly = false
    var deep = false
    var mergeRoles = true
    var recordState = true
    var showHidden = false
    /// What to do about roles you've already applied to. Decoded from the older
    /// `hideApplied` boolean when that's what's on disk, so upgrading keeps the
    /// setting instead of silently resetting it.
    var appliedFilter = AppliedFilter.show.rawValue
    /// Stacks kept by the filter. Empty means all.
    var stacks: [String] = []
    /// Which intake year the results are narrowed to, if any.
    var intakeFilter: Int?
    /// Leave out roles that ask for a doctorate.
    var excludePhD = false
    var hideApplied: Bool? = nil
    /// Which stage sections are folded shut in the Applied list.
    var collapsedStages: [String] = []
    /// When the filters last changed on this machine, as an ISO instant.
    /// Compared against the phone's stamp to decide whose filters are newer —
    /// see Sync.swift. Not itself a filter.
    var filtersUpdated = ""

    /// Refresh on open, and how stale the cache has to be before that's worth
    /// doing. A full run is a hundred-odd boards and tens of thousands of
    /// postings, so repeating it every time you open the window is wasteful.
    var refreshOnLaunch = true
    var refreshIfOlderThanHours = 6

    /// Nothing special on a first run any more. This used to force the quant
    /// half via a group filter, but that control was folded into the Firms
    /// picker — and the leftover filter silently overrode it, so turning big
    /// tech on in the picker scraped nothing.
    static var firstRun: AppSettings { AppSettings() }

    static let defaultsKey = "appSettings"

    /// Where settings are read and written. Overridable so `--check` can point at
    /// a throwaway suite: the checks drive the real AppModel, which persists every
    /// setting it touches, and they were writing into the user's own domain. That
    /// left `Applied firms: hidden` and a stray category set on a real install more
    /// than once — a test changing what someone sees when they next open the app.
    nonisolated(unsafe) static var store: UserDefaults = .standard

    /// Sends settings to a volatile suite and returns nothing to clean up: a
    /// suite that was never registered vanishes with the process.
    static func useScratchStore(_ name: String) {
        store = UserDefaults(suiteName: "local.quantjobs.check.\(name)") ?? .standard
        store.removePersistentDomain(forName: "local.quantjobs.check.\(name)")
    }

    static func load() -> AppSettings {
        guard let data = store.data(forKey: defaultsKey),
              var s = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return .firstRun }
        // The boolean became a three-way choice.
        if s.hideApplied == true, s.appliedFilter == AppliedFilter.show.rawValue {
            s.appliedFilter = AppliedFilter.roles.rawValue
        }
        s.hideApplied = nil
        return s
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        Self.store.set(data, forKey: Self.defaultsKey)
    }
}
