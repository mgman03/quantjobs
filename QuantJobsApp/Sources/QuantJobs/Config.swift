import Foundation

/// Reads and writes the same `companies.json` / `categories.json` the Python CLI uses,
/// so the two tools can share one config folder.
enum ConfigStore {

    static let dirDefaultsKey = "configDirectory"

    /// Where the CLI lives, if the user kept it in the default spot.
    static var cliDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/quant-internships")
    }

    static var appSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        return base.appendingPathComponent("QuantJobs")
    }

    /// Process-only redirect, used by the headless checks so they can exercise
    /// the real save paths without writing over the user's config.
    nonisolated(unsafe) static var directoryOverride: URL?

    /// Resolution order: a process override, then an explicit user choice, else
    /// the CLI folder if it's already there (so both tools stay in sync), else
    /// Application Support.
    static var directory: URL {
        get {
            if let directoryOverride { return directoryOverride }
            if let s = UserDefaults.standard.string(forKey: dirDefaultsKey) {
                return URL(fileURLWithPath: s)
            }
            if FileManager.default.fileExists(
                atPath: cliDirectory.appendingPathComponent("companies.json").path) {
                return cliDirectory
            }
            return appSupportDirectory
        }
        set { UserDefaults.standard.set(newValue.path, forKey: dirDefaultsKey) }
    }

    static var companiesURL: URL { directory.appendingPathComponent("companies.json") }
    static var categoriesURL: URL { directory.appendingPathComponent("categories.json") }
    static var locationsURL: URL { directory.appendingPathComponent("locations.json") }
    static var seenURL: URL { directory.appendingPathComponent(".seen.json") }
    static var trackedURL: URL { directory.appendingPathComponent(".tracked.json") }
    static var cacheURL: URL { directory.appendingPathComponent(".cache.json") }

    // MARK: seeding

    /// Copy the bundled defaults into the config folder the first time we run
    /// against a location that has no config yet.
    static func seedIfNeeded() {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)

        for (name, url) in [("companies", companiesURL), ("categories", categoriesURL),
                            ("locations", locationsURL)] {
            guard !fm.fileExists(atPath: url.path) else { continue }
            if let seed = Bundle.module.url(forResource: name, withExtension: "json") {
                try? fm.copyItem(at: seed, to: url)
            }
        }
    }

    // MARK: companies

    static func loadCompanies() throws -> CompanyFile {
        let data = try Data(contentsOf: companiesURL)
        return try JSONDecoder().decode(CompanyFile.self, from: data)
    }

    static func saveCompanies(_ file: CompanyFile) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try enc.encode(file).write(to: companiesURL, options: .atomic)
    }

    // MARK: categories

    static func loadCategories() throws -> [JobCategory] {
        let data = try Data(contentsOf: categoriesURL)
        let raw = try JSONDecoder().decode([String: JobCategory].self, from: data)
        // Dictionaries lose order; present them in a deliberate one.
        let preferred = ["swe", "quant-trading", "quant-research",
                         "quant-dev", "hardware", "data", "all"]
        return raw.map { key, value in
            var c = value; c.name = key; return c
        }.sorted { a, b in
            let ia = preferred.firstIndex(of: a.name) ?? Int.max
            let ib = preferred.firstIndex(of: b.name) ?? Int.max
            return ia == ib ? a.name < b.name : ia < ib
        }
    }

    static func saveCategories(_ cats: [JobCategory]) throws {
        var dict: [String: JobCategory] = [:]
        for c in cats { dict[c.name] = c }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(dict).write(to: categoriesURL, options: .atomic)
    }

    // MARK: locations

    static func loadGazetteer() -> Gazetteer {
        guard let data = try? Data(contentsOf: locationsURL),
              let g = try? Gazetteer(data: data)
        else { return .empty }
        return g
    }

    // MARK: seen-before state

    static func loadSeen() -> [String: String] {
        guard let data = try? Data(contentsOf: seenURL),
              let d = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return d
    }

    static func saveSeen(_ seen: [String: String]) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        try? enc.encode(seen).write(to: seenURL, options: .atomic)
    }

    // MARK: last results

    /// The previous run's results, so a launch shows something immediately
    /// instead of an empty table while the network catches up.
    struct ResultCache: Codable, Sendable {
        var savedAt: Date
        var category: String
        var level: String
        var jobs: [Job]
    }

    static func loadCache() -> ResultCache? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(ResultCache.self, from: data)
    }

    static func saveCache(_ cache: ResultCache) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.withoutEscapingSlashes]
        try? enc.encode(cache).write(to: cacheURL, options: .atomic)
    }

    // MARK: saved / applied / hidden

    static func loadTracked() -> [String: TrackedJob] {
        guard let data = try? Data(contentsOf: trackedURL),
              let d = try? JSONDecoder().decode([String: TrackedJob].self, from: data)
        else { return [:] }
        return d
    }

    static func saveTracked(_ tracked: [String: TrackedJob]) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try? enc.encode(tracked).write(to: trackedURL, options: .atomic)
    }
}
