import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // URLSession lives here off Apple platforms
#endif

/// Thin wrapper over URLSession with the same retry policy the Python CLI uses:
/// a 4xx is a real answer (bad token) and fails immediately, everything else
/// gets a couple of backed-off retries before giving up.
enum HTTP {

    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

    static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 25
        cfg.timeoutIntervalForResource = 60
        cfg.httpAdditionalHeaders = [
            "User-Agent": userAgent,
            "Accept": "application/json, text/html;q=0.9",
        ]
        cfg.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: cfg)
    }()

    /// A second session for the one adapter that makes hundreds of requests to
    /// a single host.
    ///
    /// The shared session allows six connections per host, which is polite for
    /// a board that answers in one request and is the entire bottleneck for one
    /// that needs eight hundred and fifty. Measured against Meta, same postings
    /// every time: six connections 92s, twelve 65s, twenty 39s. Kept separate
    /// rather than raising the shared cap, because every other board here wants
    /// one request and none of them should hit a host twenty ways at once.
    static let bulkSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 25
        cfg.timeoutIntervalForResource = 60
        cfg.httpAdditionalHeaders = [
            "User-Agent": userAgent,
            "Accept": "application/json, text/html;q=0.9",
        ]
        cfg.httpMaximumConnectionsPerHost = 20
        return URLSession(configuration: cfg)
    }()

    static func data(_ urlString: String, method: String? = nil, body: Data? = nil,
                     headers: [String: String] = [:],
                     retries: Int = 2,
                     using session: URLSession? = nil) async throws -> Data {
        guard let url = URL(string: urlString) else {
            throw FetchError.misconfigured("bad URL: \(urlString)")
        }

        var last: FetchError = .transport("unknown")
        for attempt in 0...retries {
            var req = URLRequest(url: url)
            if let body {
                req.httpMethod = "POST"
                req.httpBody = body
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            // Named explicitly for the one caller that PUTs; a body still
            // implies POST, which is every board API here.
            if let method { req.httpMethod = method }
            // Some in-house careers APIs only answer with their own referer.
            for (field, value) in headers {
                req.setValue(value, forHTTPHeaderField: field)
            }

            do {
                let (data, response) = try await (session ?? Self.session).data(for: req)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 200
                if (400..<500).contains(code) { throw FetchError.http(code) }
                if code >= 500 {
                    last = .http(code)
                } else {
                    return data
                }
            } catch let e as FetchError {
                throw e                       // 4xx — don't burn retries on it
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                last = .transport((error as NSError).localizedDescription)
            }

            if attempt < retries {
                try await Task.sleep(for: .milliseconds(1500 * (attempt + 1)))
            }
        }
        throw last
    }

    static func json(_ urlString: String, body: Data? = nil,
                     headers: [String: String] = [:],
                     using session: URLSession? = nil) async throws -> Any {
        let raw = try await data(urlString, body: body, headers: headers,
                                 using: session)
        do {
            return try JSONSerialization.jsonObject(with: raw, options: [.fragmentsAllowed])
        } catch {
            throw FetchError.badPayload("bad JSON (\(error.localizedDescription))")
        }
    }

    static func object(_ urlString: String, body: Data? = nil,
                       headers: [String: String] = [:],
                       using session: URLSession? = nil) async throws -> [String: Any] {
        guard let d = try await json(urlString, body: body, headers: headers,
                                     using: session) as? [String: Any] else {
            throw FetchError.badPayload("expected a JSON object")
        }
        return d
    }
}

// MARK: - Small helpers shared by the adapters

enum Clean {

    /// A JSON scalar as text, whether the board sent a string or a number.
    ///
    /// Worth a helper because `as? String` on a numeric field yields nil, and
    /// the fallback is usually "" — which is invisible until it lands in a URL.
    /// Wolverine serves `"ID": 336`, so every posting got the same empty job
    /// link, and since a posting is identified by its URL the whole board
    /// deduplicated down to one row.
    static func scalar(_ v: Any?) -> String {
        switch v {
        case let s as String: s
        case let n as NSNumber:
            // 336, not 336.0 — an integral double in a URL is a broken link.
            n.doubleValue == n.doubleValue.rounded() && abs(n.doubleValue) < 1e15
                ? String(n.int64Value) : n.stringValue
        default: ""
        }
    }

    /// Strip tags and entities out of an HTML description, collapse whitespace.
    static func html(_ s: String?) -> String {
        guard let s, !s.isEmpty else { return "" }
        var t = entities(s)
        t = t.replacingOccurrences(of: "<[^>]+>", with: " ",
                                   options: [.regularExpression])
        t = t.replacingOccurrences(of: "\\s+", with: " ",
                                   options: [.regularExpression])
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let namedEntities = [
        "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'",
        "&apos;": "'", "&nbsp;": " ", "&ndash;": "–", "&mdash;": "—",
        "&rsquo;": "’", "&lsquo;": "‘", "&ldquo;": "“", "&rdquo;": "”",
        "&hellip;": "…", "&bull;": "•",
    ]

    /// Compiled once. This runs over every posting's text on every scrape, so
    /// rebuilding the pattern per call was paying for a regex compile tens of
    /// thousands of times a run.
    private static let numericEntity =
        try! NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);")

    static func entities(_ s: String) -> String {
        var t = s
        for (k, v) in namedEntities { t = t.replacingOccurrences(of: k, with: v) }
        // Numeric entities: &#8217; / &#x2019;
        guard t.contains("&#") else { return t }
        let rx = numericEntity
        let ns = t as NSString
        var out = ""
        var cursor = 0
        for m in rx.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor,
                                              length: m.range.location - cursor))
            let hex = ns.substring(with: m.range(at: 1)) == "x"
            let digits = ns.substring(with: m.range(at: 2))
            if let code = UInt32(digits, radix: hex ? 16 : 10),
               let scalar = Unicode.Scalar(code) {
                out.append(Character(scalar))
            }
            cursor = m.range.location + m.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    /// Normalise the many date shapes these APIs emit down to YYYY-MM-DD.
    static func isoDate(_ v: Any?) -> String {
        switch v {
        case nil, is NSNull:
            return ""
        case let n as NSNumber:
            // Lever hands back epoch millis.
            let secs = n.doubleValue / 1000
            guard secs > 0, secs < 4_102_444_800 else { return "" }
            return Job.dateFormatter.string(from: Date(timeIntervalSince1970: secs))
        default:
            let s = String(describing: v!)
            guard s.count >= 10 else { return "" }
            let head = String(s.prefix(10))
            return Job.dateFormatter.date(from: head) != nil ? head : ""
        }
    }
}

/// Caps how many requests may be in flight against one host at a time.
///
/// Workday needs this: every tenant sits behind the same front end, a board is
/// dozens of round trips because pages cap at 20, and the app fetches those
/// pages five at a time with boards running in parallel. Without a cap a full
/// run puts dozens of requests on Workday at once, and it starts resetting
/// connections — a run once reported seven Workday boards broken that each
/// answered fine on their own.
actor RequestGate {

    private let limit: Int
    private var active = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func acquire() async {
        if active < limit { active += 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        // Hand the slot straight to whoever is queued rather than dropping the
        // count and making them race for it.
        if waiting.isEmpty { active -= 1 } else { waiting.removeFirst().resume() }
    }

    /// Runs `body` holding a slot, releasing it however `body` ends.
    ///
    /// Deliberately `nonisolated`: the body runs in the caller's context, so a
    /// non-Sendable payload like Workday's `[String: Any]` never has to cross
    /// the actor boundary. Only the slot bookkeeping hops onto the actor.
    nonisolated func run<T>(_ body: () async throws -> T) async rethrows -> T {
        await acquire()
        do {
            let value = try await body()
            await release()
            return value
        } catch {
            await release()
            throw error
        }
    }
}
