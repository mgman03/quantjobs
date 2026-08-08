import Foundation
import CryptoKit

/// Reads and writes the same `companies.json` / `categories.json` the Python CLI uses,
/// so the two tools can share one config folder.
enum ConfigStore {

    static let dirDefaultsKey = "configDirectory"

    /// A named suite rather than `.standard`.
    ///
    /// `UserDefaults.standard` keys off the bundle identifier, so the installed
    /// .app and a `swift run` from the checkout read two different domains — a
    /// `defaults write QuantJobs configDirectory` aimed at one silently missed
    /// the other, and the app carried on reading a stale seeded copy in
    /// Application Support. One suite, one place to point either at.
    nonisolated(unsafe) static let overrides =
        UserDefaults(suiteName: overrideDomain) ?? .standard
    static let overrideDomain = "local.quantjobs.shared"

    /// The checkout this binary is running from, found by walking up from the
    /// executable until a `companies.json` turns up.
    ///
    /// This used to be hardcoded to ~/Desktop/quant-internships, which only
    /// worked on the machine it was written on — anyone cloning the repo
    /// somewhere else got a folder that didn't exist.
    static var repoDirectory: URL? {
        var dir = Bundle.main.bundleURL.resolvingSymlinksInPath()
        // .build/debug/QuantJobs, or QuantJobs.app/Contents/MacOS — either way
        // the checkout is a few levels up if we're running from one.
        for _ in 0..<6 {
            dir.deleteLastPathComponent()
            if dir.path == "/" { break }
            let candidate = dir.appendingPathComponent("companies.json")
            if FileManager.default.fileExists(atPath: candidate.path) { return dir }
        }
        return nil
    }

    /// Legacy location this tool shipped with. Only used if it's actually there.
    private static var legacyDirectory: URL {
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

    /// Resolution order, most explicit first:
    ///   1. a process override (the headless checks)
    ///   2. $QUANTJOBS_CONFIG
    ///   3. whatever the user picked, stored in defaults
    ///   4. the checkout this binary is running from, so the app and the CLI
    ///      share one folder without anything being hardcoded
    ///   5. the legacy ~/Desktop location, if it happens to exist
    ///   6. Application Support
    static var directory: URL {
        get {
            if let directoryOverride { return directoryOverride }
            if let env = ProcessInfo.processInfo.environment["QUANTJOBS_CONFIG"],
               !env.isEmpty {
                return URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
            }
            if let s = overrides.string(forKey: dirDefaultsKey) {
                return URL(fileURLWithPath: s)
            }
            if let repo = repoDirectory { return repo }
            if FileManager.default.fileExists(
                atPath: legacyDirectory.appendingPathComponent("companies.json").path) {
                return legacyDirectory
            }
            return appSupportDirectory
        }
        set { overrides.set(newValue.path, forKey: dirDefaultsKey) }
    }

    static var companiesURL: URL { directory.appendingPathComponent("companies.json") }
    static var categoriesURL: URL { directory.appendingPathComponent("categories.json") }
    static var locationsURL: URL { directory.appendingPathComponent("locations.json") }
    static var seenURL: URL { directory.appendingPathComponent(".seen.json") }
    static var trackedURL: URL { directory.appendingPathComponent(".tracked.json") }
    static var cacheURL: URL { directory.appendingPathComponent(".cache.json") }

    // MARK: seeding

    /// The bundled copy of the config, or nil if it isn't there.
    ///
    /// Deliberately not the compiler-generated `Bundle.module`, which *traps*
    /// when the resource bundle is missing. Because seeding runs on every
    /// launch, a damaged or half-copied install didn't degrade — it killed the
    /// app at startup with no window and no message. Looking the bundle up by
    /// hand turns that into "no seed available".
    nonisolated(unsafe) static let seedBundle: Bundle? = {
        let name = "QuantJobs_QuantJobs.bundle"
        var roots = [Bundle.main.bundleURL]
        if let resources = Bundle.main.resourceURL { roots.insert(resources, at: 0) }
        roots.append(Bundle.main.bundleURL.deletingLastPathComponent())
        for root in roots {
            if let found = Bundle(url: root.appendingPathComponent(name)) { return found }
        }
        return nil
    }()

    /// Copy the bundled defaults into the config folder the first time we run
    /// against a location that has no config yet.
    static func seedIfNeeded() {
        seedMissingFiles()
        mergeBundledRoster()
    }

    private static func seedMissingFiles() {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)

        for (name, url) in [("companies", companiesURL), ("categories", categoriesURL),
                            ("locations", locationsURL)] {
            guard !fm.fileExists(atPath: url.path) else { continue }
            if let seed = seedBundle?.url(forResource: name, withExtension: "json") {
                try? fm.copyItem(at: seed, to: url)
            }
        }
    }

    /// Where we recorded the roster the bundle last shipped: its hash, and the
    /// names it contained. The names matter — without them a firm the user
    /// deleted looks identical to a firm they've never seen, so every upgrade
    /// resurrected everything they'd removed.
    private static var seedStampURL: URL {
        directory.appendingPathComponent(".seed-version")
    }

    private struct SeedStamp: Codable {
        var hash: String
        var names: [String]
    }

    private static func readStamp() -> SeedStamp? {
        guard let data = try? Data(contentsOf: seedStampURL) else { return nil }
        if let stamp = try? JSONDecoder().decode(SeedStamp.self, from: data) {
            return stamp
        }
        // The first version of this file was a bare hash. Treat it as "we have
        // merged before but don't know what was in it".
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : SeedStamp(hash: text, names: [])
    }

    /// Bring an existing config up to date when the app itself is upgraded.
    ///
    /// Seeding only writes files that are *missing*, so an installed app that
    /// already had a config kept the roster it first shipped with — forever. A
    /// new version could add twenty firms, repair a broken token or correct a
    /// note, and none of it reached anyone who had already run the app once.
    ///
    /// So: whenever the bundled roster differs from the one we last merged,
    /// fold it in. The maintainer's fields win, because those are the ones that
    /// get fixed; the user's own on/off choices and any firms they added
    /// themselves are left alone.
    private static func mergeBundledRoster() {
        guard let seedURL = seedBundle?.url(forResource: "companies",
                                            withExtension: "json"),
              let seedData = try? Data(contentsOf: seedURL) else { return }

        let hash = SHA256.hash(data: seedData).map { String(format: "%02x", $0) }.joined()
        let previous = readStamp()
        guard previous?.hash != hash else { return }

        guard let bundled = try? JSONDecoder().decode(CompanyFile.self, from: seedData),
              var current = try? loadCompanies() else { return }

        // Record what this bundle held either way, so a roster we can't merge
        // doesn't make every launch retry it.
        defer {
            let stamp = SeedStamp(hash: hash, names: bundled.companies.map(\.name))
            if let data = try? JSONEncoder().encode(stamp) {
                try? data.write(to: seedStampURL, options: .atomic)
            }
        }

        let mine = Dictionary(current.companies.map { ($0.name, $0) },
                              uniquingKeysWith: { a, _ in a })
        // A firm that was in the last bundle but isn't in the config now was
        // deleted on purpose — the README offers removal as a way to prune the
        // roster, so bringing it back on every update would ignore that. On a
        // first merge there's no previous list, so nothing counts as deleted.
        let removedOnPurpose = Set(previous?.names ?? []).subtracting(mine.keys)

        // With no previous record there's no way to tell a firm the user
        // deleted from one they've never seen, so the first merge only updates
        // what's already there. That costs an install the firms added in the
        // version it's upgrading to — they arrive with the next one — which is
        // a far better trade than wiping a roster someone curated by hand.
        let firstMerge = previous == nil

        var merged: [Company] = []
        for var firm in bundled.companies {
            if let existing = mine[firm.name] {
                // Their choice, not ours — a firm they switched off stays off.
                firm.enabled = existing.enabled
                merged.append(firm)
            } else if !firstMerge && !removedOnPurpose.contains(firm.name) {
                merged.append(firm)
            }
        }
        // Anything they added by hand isn't in the bundle; keep it.
        let bundledNames = Set(bundled.companies.map(\.name))
        merged.append(contentsOf: current.companies.filter { !bundledNames.contains($0.name) })

        // Don't touch the file when the merge is a no-op — the common case
        // after the first launch on a new version.
        guard merged != current.companies || bundled.comment != current.comment else { return }
        current.companies = merged
        current.comment = bundled.comment
        try? saveCompanies(current)
    }

    // MARK: companies

    static func loadCompanies() throws -> CompanyFile {
        let data = try Data(contentsOf: companiesURL)
        return try JSONDecoder().decode(CompanyFile.self, from: data)
    }

    static func saveCompanies(_ file: CompanyFile) throws {
        let enc = JSONEncoder()
        // Sorted keys so the file is byte-stable. Swift and Python order keys
        // differently, so without this every launch rewrote companies.json into
        // a 600-line git diff that changed nothing.
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        try enc.encode(file).write(to: companiesURL, options: .atomic)
    }

    // MARK: categories

    static func loadCategories() throws -> [JobCategory] {
        let data = try Data(contentsOf: categoriesURL)
        let raw = try JSONDecoder().decode([String: JobCategory].self, from: data)
        // Dictionaries lose order; present them in a deliberate one — disciplines
        // first, then the language and stack slices, then Everything. A category
        // missing from this list sorts alphabetically after it, which is how
        // cpp/python/frontend ended up below "Everything" when they were added
        // to the file but not here.
        let preferred = ["swe",
                         "cpp", "python", "frontend",        // slices of swe
                         "quant-trading", "quant-research",
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
        return migrateKeys(d)
    }

    /// Saved and applied roles were keyed on company|title|location until the
    /// key became the posting's URL. Every entry carries a full snapshot of its
    /// posting, so the new key can be computed from what's already on disk —
    /// which means the change costs nobody their tracking history.
    ///
    /// Rewritten in place the first time it's read, so the migration happens
    /// once rather than on every load.
    private static func migrateKeys(_ tracked: [String: TrackedJob]) -> [String: TrackedJob] {
        var out: [String: TrackedJob] = [:]
        var moved = 0
        for (stored, entry) in tracked {
            let current = entry.job.key
            if current != stored { moved += 1 }
            // Last writer wins if two old entries collapse to one posting —
            // they were the same posting recorded twice.
            out[current] = entry
        }
        if moved > 0 { saveTracked(out) }
        return out
    }

    static func saveTracked(_ tracked: [String: TrackedJob]) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try? enc.encode(tracked).write(to: trackedURL, options: .atomic)
    }
}
