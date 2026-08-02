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

    var groupFilter: String?
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
    var showInspector = true

    /// Refresh on open, and how stale the cache has to be before that's worth
    /// doing. A full run is a hundred-odd boards and tens of thousands of
    /// postings, so repeating it every time you open the window is wasteful.
    var refreshOnLaunch = true
    var refreshIfOlderThanHours = 6

    /// First run starts on the quant half rather than all ~106 boards — the
    /// big-tech Workday boards are the slow ones, and this is a quant tool.
    static var firstRun: AppSettings {
        var s = AppSettings()
        s.groupFilter = "quant"
        return s
    }

    static let defaultsKey = "appSettings"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return .firstRun }
        return s
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}
