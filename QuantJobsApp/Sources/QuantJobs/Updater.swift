// Wrapped so the package still builds where SwiftUI does not exist —
// the scraper has to run on Linux for the scheduled fetch, and only the
// window needs Apple's UI frameworks.
#if canImport(SwiftUI)
import Foundation
import AppKit

/// Checks GitHub for a newer release and installs it in place.
///
/// Deliberately not Sparkle. Sparkle is the right answer when you're notarised
/// and shipping to strangers; here it would add a package dependency and an
/// EdDSA key to a project that has neither, and it wouldn't remove the
/// Gatekeeper prompt — only an Apple developer account does that. This does
/// what Sparkle does minus the ceremony: ask the releases API, compare
/// versions, swap the bundle.
///
/// One thing that makes the swap work: a disk image fetched with URLSession
/// carries no `com.apple.quarantine` attribute, because quarantine is applied
/// by browsers rather than by the network. So the replacement bundle launches
/// without the "Apple could not verify" dialog a manual download triggers.
@MainActor
@Observable
final class Updater {

    static let repo = "mgman03/quantjobs"

    /// Matched against the disk image before anything is swapped in. A fixed
    /// value rather than `Bundle.main.bundleIdentifier`, which is nil whenever
    /// we aren't running from a bundle and would make the check vacuous.
    /// Must track CFBundleIdentifier in make-app.sh.
    static let bundleIdentifier = "local.quantjobs.app"

    struct Release: Equatable, Sendable {
        var version: String
        var notes: String
        var page: URL
        var dmg: URL
    }

    enum Phase: Equatable {
        case idle
        case checking
        case available(Release)
        case busy(String)
        case upToDate
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// Set when the user waves the banner away, so it doesn't come back for
    /// this release until they ask or the app restarts.
    var dismissed = false

    private static let lastCheckKey = "lastUpdateCheck"

    // MARK: - What we are

    nonisolated static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "0"
    }

    /// A `swift run` binary isn't a bundle and can't replace itself; someone
    /// running from a checkout should be pulling instead.
    nonisolated static var isBundled: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    /// `1.0.10` is newer than `1.0.9`, which a string compare gets backwards.
    /// Pure arithmetic on two strings, so it needs no isolation.
    nonisolated static func isNewer(_ candidate: String, than installed: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.drop(while: { !$0.isNumber })
                .split(separator: ".")
                .map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let a = parts(candidate), b = parts(installed)
        for i in 0..<max(a.count, b.count) {
            let l = i < a.count ? a[i] : 0
            let r = i < b.count ? b[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    // MARK: - Checking

    /// Called on launch. Quiet about failures — someone offline shouldn't get
    /// an error bar across a window that otherwise works fine.
    func checkOnLaunch() async {
        let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        let day: TimeInterval = 60 * 60 * 24
        guard Date().timeIntervalSince1970 - last > day else { return }
        await check(quietly: true)
    }

    func check(quietly: Bool) async {
        if case .busy = phase { return }
        phase = .checking
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
        do {
            let release = try await Self.fetchLatest()
            if Self.isNewer(release.version, than: Self.currentVersion) {
                dismissed = false
                phase = .available(release)
            } else {
                phase = quietly ? .idle : .upToDate
            }
        } catch {
            phase = quietly ? .idle : .failed(Self.describe(error))
        }
    }

    private static func fetchLatest() async throws -> Release {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(HTTP.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw Failure("GitHub answered \(code)")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let pageText = json["html_url"] as? String,
              let page = URL(string: pageText) else {
            throw Failure("couldn't read the release")
        }
        let assets = json["assets"] as? [[String: Any]] ?? []
        guard let asset = assets.first(where: {
                  ($0["name"] as? String)?.hasSuffix(".dmg") == true }),
              let dmgText = asset["browser_download_url"] as? String,
              let dmg = URL(string: dmgText) else {
            throw Failure("that release ships no disk image")
        }
        return Release(version: tag,
                       notes: json["body"] as? String ?? "",
                       page: page,
                       dmg: dmg)
    }

    /// Put the banner away after a one-off result.
    func clear() { phase = .idle }

    // MARK: - Installing

    /// `into` and `relaunch` exist so the headless check can run the whole
    /// path — download, mount, verify, swap — against a throwaway copy of the
    /// app instead of the one that's running.
    func install(_ release: Release,
                 into destination: URL? = nil,
                 relaunch: Bool = true) async {
        guard destination != nil || Self.isBundled else {
            phase = .failed("Running from a checkout — use git pull instead.")
            return
        }
        let target = destination ?? Bundle.main.bundleURL
        do {
            phase = .busy("Downloading \(release.version)…")
            let dmg = try await Self.download(release.dmg)
            defer { try? FileManager.default.removeItem(at: dmg) }

            phase = .busy("Verifying…")
            let mount = try Self.attach(dmg)
            defer { Self.detach(mount) }

            let source = mount.appendingPathComponent("QuantJobs.app")
            try Self.validate(source, notOlderThan: Self.currentVersion)

            phase = .busy("Installing…")
            let staged = try Self.stage(source)
            guard relaunch else {
                // Straight swap: nothing is running out of the target.
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: staged, to: target)
                phase = .idle
                return
            }
            try Self.scheduleSwap(staged: staged, into: target)

            phase = .busy("Restarting…")
            // The helper waits for this process to go away before moving the
            // bundle — replacing it underneath a running app corrupts it.
            NSApp.terminate(nil)
        } catch {
            phase = .failed(Self.describe(error))
        }
    }

    private static func download(_ url: URL) async throws -> URL {
        var request = URLRequest(url: url)
        request.setValue(HTTP.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 120
        let (temp, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw Failure("download failed (\((response as? HTTPURLResponse)?.statusCode ?? 0))")
        }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuantJobs-\(UUID().uuidString).dmg")
        try FileManager.default.moveItem(at: temp, to: dest)
        return dest
    }

    private static func attach(_ dmg: URL) throws -> URL {
        let mount = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuantJobsMount-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        let result = run("/usr/bin/hdiutil",
                         ["attach", dmg.path, "-nobrowse", "-readonly",
                          "-mountpoint", mount.path])
        guard result.status == 0 else { throw Failure("couldn't open the disk image") }
        return mount
    }

    private static func detach(_ mount: URL) {
        _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"])
        try? FileManager.default.removeItem(at: mount)
    }

    /// Never replace the running app with whatever happened to be on a mounted
    /// image: it has to be our bundle, and it has to be an upgrade.
    ///
    /// Deliberately not "the plist matches the tag exactly". A tag is a label
    /// someone types and a plist is written by the build, so they can differ
    /// harmlessly — v1.0.1 shipped an image reading 1.0. What actually matters
    /// is that we aren't installing something older than what's already here.
    private static func validate(_ app: URL, notOlderThan installed: String) throws {
        guard FileManager.default.fileExists(atPath: app.path) else {
            throw Failure("no QuantJobs.app on the disk image")
        }
        guard let plist = NSDictionary(
                  contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let identifier = plist["CFBundleIdentifier"] as? String,
              identifier == bundleIdentifier else {
            throw Failure("that app isn't QuantJobs")
        }
        let shipped = plist["CFBundleShortVersionString"] as? String ?? ""
        guard !isNewer(installed, than: shipped) else {
            throw Failure("the image holds \(shipped), older than the \(installed) "
                          + "already installed")
        }
    }

    private static func stage(_ source: URL) throws -> URL {
        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuantJobs-new-\(UUID().uuidString).app")
        // ditto rather than copyItem: it preserves the signature and the
        // resource forks a bundle can carry.
        let result = run("/usr/bin/ditto", [source.path, staged.path])
        guard result.status == 0 else { throw Failure("couldn't copy the new version") }
        return staged
    }

    private static func scheduleSwap(staged: URL, into destination: URL) throws {
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("quantjobs-swap-\(UUID().uuidString).sh")
        let body = """
        #!/bin/sh
        # Wait for the old copy to quit, then take its place.
        for _ in $(seq 1 100); do
            kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null || break
            sleep 0.2
        done
        rm -rf '\(destination.path)'
        mv '\(staged.path)' '\(destination.path)' || exit 1
        # Belt and braces: a URLSession download isn't quarantined, but a future
        # change to how it arrives shouldn't resurrect the Gatekeeper dialog.
        xattr -dr com.apple.quarantine '\(destination.path)' 2>/dev/null
        open '\(destination.path)'
        rm -f "$0"
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: script.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path]
        try process.run()      // detached on purpose; it outlives us
    }

    // MARK: - Bits

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private static func describe(_ error: Error) -> String {
        (error as? Failure)?.message ?? error.localizedDescription
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) -> (status: Int32, out: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
#endif
