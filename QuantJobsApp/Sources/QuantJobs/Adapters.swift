import Foundation

/// One posting exactly as a board handed it over, before we know anything
/// about which company or category it belongs to.
struct RawJob: Sendable {
    var title = ""
    var location = ""
    var url = ""
    var posted = ""
    var department = ""
    var description = ""
    /// "ok" for a firm's own board — it is the source of truth. Aggregated
    /// rows get checked and come back "ok" or "blocked".
    var linkStatus: String = "ok"
}

/// Each adapter turns a company config into raw postings.
/// Adding a new ATS means writing one function and registering it in `fetch`.
enum Adapters {

    static func fetch(_ c: Company, deep: Bool) async throws -> [RawJob] {
        switch c.ats {
        case .greenhouse:      try await greenhouse(c, deep: deep)
        case .lever:           try await lever(c, deep: deep)
        case .ashby:           try await ashby(c, deep: deep)
        case .smartrecruiters: try await smartrecruiters(c, deep: deep)
        case .workday:         try await workday(c, deep: deep)
        case .amazon:          try await amazon(c, deep: deep)
        case .eightfold:       try await eightfold(c, deep: deep)
        case .jibe:            try await jibe(c, deep: deep)
        case .uber:            try await uber(c, deep: deep)
        case .wolverine:       try await wolverine(c, deep: deep)
        case .citadel:         try await citadel(c, deep: deep)
        case .sitemap:         try await sitemapJobs(c, deep: deep)
        case .janestreet:      try await janeStreet(c, deep: deep)
        case .optiver:         try await optiver(c, deep: deep)
        case .twosigma:        try await twoSigma(c, deep: deep)
        case .simplify:        try await simplify(c, deep: deep)
        }
    }

    private static func token(_ c: Company) throws -> String {
        guard let t = c.token, !t.isEmpty else {
            throw FetchError.misconfigured("\(c.ats.label) needs a token")
        }
        return t
    }

    // MARK: - Greenhouse

    static func greenhouse(_ c: Company, deep: Bool) async throws -> [RawJob] {
        let token = try token(c)
        var url = "https://boards-api.greenhouse.io/v1/boards/\(token)/jobs"
        if deep { url += "?content=true" }
        let payload = try await HTTP.object(url)
        let jobs = payload["jobs"] as? [[String: Any]] ?? []

        return jobs.map { j in
            let offices = (j["offices"] as? [[String: Any]] ?? [])
                .compactMap { $0["name"] as? String }.filter { !$0.isEmpty }
            let depts = (j["departments"] as? [[String: Any]] ?? [])
                .compactMap { $0["name"] as? String }.filter { !$0.isEmpty }
            let named = (j["location"] as? [String: Any])?["name"] as? String ?? ""

            return RawJob(
                title: j["title"] as? String ?? "",
                location: named.isEmpty ? offices.joined(separator: ", ") : named,
                url: j["absolute_url"] as? String ?? "",
                posted: Clean.isoDate(j["updated_at"] ?? j["first_published"]),
                department: depts.joined(separator: ", "),
                description: deep ? Clean.html(j["content"] as? String) : "")
        }
    }

    // MARK: - Lever

    static func lever(_ c: Company, deep: Bool) async throws -> [RawJob] {
        let token = try token(c)
        let raw = try await HTTP.json("https://api.lever.co/v0/postings/\(token)?mode=json")
        guard let jobs = raw as? [[String: Any]] else {
            throw FetchError.badPayload("unexpected Lever payload")
        }

        return jobs.map { j in
            let cats = j["categories"] as? [String: Any] ?? [:]
            let team = cats["team"] as? String
            let commitment = cats["commitment"] as? String

            return RawJob(
                title: j["text"] as? String ?? "",
                location: cats["location"] as? String ?? "",
                url: j["hostedUrl"] as? String ?? "",
                posted: Clean.isoDate(j["createdAt"]),
                department: [team, commitment].compactMap { $0 }.joined(separator: " / "),
                // Lever ships the description inline, so `deep` costs nothing here.
                description: j["descriptionPlain"] as? String ?? "")
        }
    }

    // MARK: - Ashby

    /// Ashby's public posting API.
    ///
    /// The older non-user-graphql endpoint used to work, but Ashby dropped
    /// `departmentName` / `publishedDate` from that schema and now rejects the
    /// query outright. This REST board is public, carries the publish date, and
    /// ships descriptions inline — so `deep` costs nothing here, same as Lever.
    static func ashby(_ c: Company, deep: Bool) async throws -> [RawJob] {
        let token = try token(c)
        let payload = try await HTTP.object(
            "https://api.ashbyhq.com/posting-api/job-board/\(token)")

        guard let jobs = payload["jobs"] as? [[String: Any]] else {
            throw FetchError.badPayload("no such Ashby board")
        }

        return jobs.map { j in
            let dept = j["department"] as? String
            let type = j["employmentType"] as? String

            return RawJob(
                title: j["title"] as? String ?? "",
                location: j["location"] as? String ?? "",
                url: j["jobUrl"] as? String ?? "",
                posted: Clean.isoDate(j["publishedAt"]),
                department: [dept, type].compactMap { $0 }.joined(separator: " / "),
                description: j["descriptionPlain"] as? String ?? "")
        }
    }

    // MARK: - SmartRecruiters

    static func smartrecruiters(_ c: Company, deep: Bool) async throws -> [RawJob] {
        let token = try token(c)
        var out: [RawJob] = []
        var offset = 0

        while true {
            let payload = try await HTTP.object(
                "https://api.smartrecruiters.com/v1/companies/\(token)"
                + "/postings?limit=100&offset=\(offset)")
            let batch = payload["content"] as? [[String: Any]] ?? []

            for j in batch {
                let loc = j["location"] as? [String: Any] ?? [:]
                let where_ = [loc["city"], loc["region"], loc["country"]]
                    .compactMap { $0 as? String }.filter { !$0.isEmpty }
                    .joined(separator: ", ")
                let remote = (loc["remote"] as? Bool) ?? false

                out.append(RawJob(
                    title: j["name"] as? String ?? "",
                    location: where_.isEmpty ? (remote ? "Remote" : "") : where_,
                    url: "https://jobs.smartrecruiters.com/\(token)/\(j["id"] as? String ?? "")",
                    posted: Clean.isoDate(j["releasedDate"]),
                    department: (j["department"] as? [String: Any])?["label"] as? String ?? "",
                    description: ""))
            }

            offset += batch.count
            let total = (payload["totalFound"] as? Int) ?? 0
            if batch.isEmpty || offset >= total || offset > 2000 { break }
        }
        return out
    }

    // MARK: - Workday

    /// Shared by every Workday board, so the cap is on the platform as a whole
    /// rather than per firm.
    static let workdayGate = RequestGate(limit: 8)

    /// Workday CXS. Config needs host (tenant.wdN.myworkdayjobs.com), tenant, site.
    static func workday(_ c: Company, deep: Bool) async throws -> [RawJob] {
        guard let host = c.host, let tenant = c.tenant, let site = c.site,
              !host.isEmpty, !tenant.isEmpty, !site.isEmpty else {
            throw FetchError.misconfigured("workday needs host / tenant / site")
        }
        let endpoint = "https://\(host)/wday/cxs/\(tenant)/\(site)/jobs"
        let pageSize = 20      // Workday rejects anything larger
        let cap = 2000

        func page(_ offset: Int) async throws -> [RawJob] {
            // An optional `query` narrows the board server-side.
            let body = try JSONSerialization.data(withJSONObject: [
                "appliedFacets": [String: String](),
                "limit": pageSize, "offset": offset, "searchText": c.query ?? "",
            ])
            let payload = try await workdayGate.run {
                try await HTTP.object(endpoint, body: body)
            }
            return (payload["jobPostings"] as? [[String: Any]] ?? []).map { j in
                let path = j["externalPath"] as? String ?? ""
                let bullets = (j["bulletFields"] as? [String] ?? []).joined(separator: " ")
                return RawJob(
                    title: j["title"] as? String ?? "",
                    location: j["locationsText"] as? String ?? "",
                    url: "https://\(host)/en-US/\(site)\(path)",
                    posted: "",   // Workday says "Posted 5 Days Ago", not a date
                    department: "",
                    description: bullets)
            }
        }

        // The first page carries the count — later pages report total=0, which
        // is what used to end the loop after 40 rows.
        let body = try JSONSerialization.data(withJSONObject: [
            "appliedFacets": [String: String](),
            "limit": pageSize, "offset": 0, "searchText": c.query ?? "",
        ])
        let head = try await workdayGate.run {
            try await HTTP.object(endpoint, body: body)
        }
        let total = min((head["total"] as? Int) ?? 0, cap)
        var out = (head["jobPostings"] as? [[String: Any]] ?? []).map { j -> RawJob in
            let path = j["externalPath"] as? String ?? ""
            let bullets = (j["bulletFields"] as? [String] ?? []).joined(separator: " ")
            return RawJob(
                title: j["title"] as? String ?? "",
                location: j["locationsText"] as? String ?? "",
                url: "https://\(host)/en-US/\(site)\(path)",
                posted: "",
                department: "",
                description: bullets)
        }
        guard !out.isEmpty else { return out }

        // Not every tenant reports a count. Without one there's no way to know
        // how many pages to ask for, so fall back to walking them in order
        // until the board runs dry — same as the CLI does.
        guard total > 0 else {
            var offset = out.count
            while offset <= cap {
                let batch = try await page(offset)
                out.append(contentsOf: batch)
                if batch.isEmpty { break }
                offset += batch.count
            }
            return out
        }
        guard total > out.count else { return out }

        // 20 rows a page makes a large board dozens of round trips, so fetch
        // the rest a few at a time instead of walking them one by one.
        let offsets = Array(stride(from: pageSize, to: total, by: pageSize))
        var pages: [Int: [RawJob]] = [:]
        let lanes = 5

        try await withThrowingTaskGroup(of: (Int, [RawJob]).self) { group in
            var next = 0
            for _ in 0..<min(lanes, offsets.count) {
                let offset = offsets[next]; next += 1
                group.addTask { (offset, try await page(offset)) }
            }
            while let (offset, rows) = try await group.next() {
                pages[offset] = rows
                if next < offsets.count {
                    let offset = offsets[next]; next += 1
                    group.addTask { (offset, try await page(offset)) }
                }
            }
        }

        // Reassemble in offset order so the board reads the same every run.
        for offset in offsets { out.append(contentsOf: pages[offset] ?? []) }
        return out
    }

    // MARK: - amazon.jobs

    /// There's no board slug here — the whole site is one search index — so
    /// `query` narrows it up front. It defaults to "intern" because pulling all
    /// ~15k Amazon postings to filter locally would be silly.
    static func amazon(_ c: Company, deep: Bool) async throws -> [RawJob] {
        let query = (c.query?.isEmpty == false) ? c.query! : "intern"
        var out: [RawJob] = []
        var offset = 0

        while true {
            var components = URLComponents(string: "https://www.amazon.jobs/en/search.json")!
            components.queryItems = [
                URLQueryItem(name: "base_query", value: query),
                URLQueryItem(name: "result_limit", value: "100"),
                URLQueryItem(name: "offset", value: String(offset)),
                URLQueryItem(name: "sort", value: "recent"),
            ]
            let payload = try await HTTP.object(components.url!.absoluteString)
            let batch = payload["jobs"] as? [[String: Any]] ?? []

            for j in batch {
                let body = [j["description_short"], j["basic_qualifications"]]
                    .compactMap { $0 as? String }.joined(separator: " ")
                out.append(RawJob(
                    title: j["title"] as? String ?? "",
                    location: j["normalized_location"] as? String ?? "",
                    url: "https://www.amazon.jobs" + (j["job_path"] as? String ?? ""),
                    posted: amazonDate(j["posted_date"]),
                    department: j["job_category"] as? String ?? "",
                    description: deep ? Clean.html(body) : ""))
            }

            offset += batch.count
            let hits = (payload["hits"] as? Int) ?? 0
            // The API stops serving results past ~1000.
            if batch.isEmpty || offset >= hits || offset >= 1000 { break }
        }
        return out
    }

    // MARK: - Eightfold (Netflix and friends)

    /// Config: host (explore.jobs.netflix.net) + tenant (its `domain`).
    static func eightfold(_ c: Company, deep: Bool) async throws -> [RawJob] {
        guard let host = c.host, let domain = c.tenant,
              !host.isEmpty, !domain.isEmpty else {
            throw FetchError.misconfigured("eightfold needs host + tenant")
        }
        var out: [RawJob] = []
        var start = 0

        while true {
            var comps = URLComponents(string: "https://\(host)/api/apply/v2/jobs")!
            comps.queryItems = [
                URLQueryItem(name: "domain", value: domain),
                URLQueryItem(name: "start", value: String(start)),
                URLQueryItem(name: "num", value: "100"),
                URLQueryItem(name: "query", value: c.query ?? ""),
                URLQueryItem(name: "sort_by", value: "timestamp"),
            ]
            let payload = try await HTTP.object(comps.url!.absoluteString)
            let batch = payload["positions"] as? [[String: Any]] ?? []

            for j in batch {
                let places = j["locations"] as? [String]
                    ?? [j["location"] as? String].compactMap { $0 }
                let dept = [j["department"], j["business_unit"]]
                    .compactMap { $0 as? String }.filter { !$0.isEmpty }
                out.append(RawJob(
                    title: j["name"] as? String ?? "",
                    location: places.joined(separator: "; "),
                    url: j["canonicalPositionUrl"] as? String ?? "",
                    posted: epochDate(j["t_create"] ?? j["t_update"]),
                    department: dept.joined(separator: " / "),
                    description: deep ? Clean.html(j["job_description"] as? String) : ""))
            }

            start += batch.count
            let count = (payload["count"] as? Int) ?? 0
            if batch.isEmpty || start >= count || start > 2000 { break }
        }
        return out
    }

    /// Eightfold hands back seconds, not the milliseconds Lever uses.
    static func epochDate(_ v: Any?) -> String {
        guard let n = v as? NSNumber, n.doubleValue > 0 else { return "" }
        return Job.dateFormatter.string(
            from: Date(timeIntervalSince1970: n.doubleValue))
    }

    // MARK: - Jibe (SIG)

    static func jibe(_ c: Company, deep: Bool) async throws -> [RawJob] {
        guard let host = c.host, !host.isEmpty else {
            throw FetchError.misconfigured("jibe needs a host")
        }
        var out: [RawJob] = []
        var page = 1

        while true {
            let payload = try await HTTP.object(
                "https://\(host)/api/jobs?page=\(page)&limit=100")
            let batch = payload["jobs"] as? [[String: Any]] ?? []

            for wrapper in batch {
                let j = wrapper["data"] as? [String: Any] ?? [:]
                let where_ = j["full_location"] as? String
                    ?? [j["city"], j["country"]].compactMap { $0 as? String }
                        .joined(separator: ", ")
                let cats = j["category"] as? [String] ?? []
                out.append(RawJob(
                    title: j["title"] as? String ?? "",
                    location: where_,
                    url: j["apply_url"] as? String ?? "",
                    posted: Clean.isoDate(j["create_date"]),
                    department: cats.isEmpty ? (j["department"] as? String ?? "")
                                             : cats.joined(separator: ", "),
                    description: deep ? Clean.html(j["description"] as? String) : ""))
            }

            page += 1
            let total = (payload["totalCount"] as? Int) ?? 0
            if batch.isEmpty || out.count >= total || out.count > 2000 { break }
        }
        return out
    }

    // MARK: - Uber

    static func uber(_ c: Company, deep: Bool) async throws -> [RawJob] {
        var out: [RawJob] = []
        var page = 0

        while true {
            let body = try JSONSerialization.data(withJSONObject: [
                "params": ["page": page, "limit": 100],
                "page": page, "limit": 100,
            ])
            let payload = try await HTTP.object(
                "https://www.uber.com/api/loadSearchJobsResults?localeCode=en",
                body: body,
                headers: ["Referer": "https://www.uber.com/us/en/careers/list/",
                          "x-csrf-token": "x"])
            let results = (payload["data"] as? [String: Any])?["results"]
                as? [[String: Any]] ?? []

            for j in results {
                let spots = j["allLocations"] as? [[String: Any]]
                    ?? [j["location"] as? [String: Any]].compactMap { $0 }
                let where_ = spots.map { s in
                    [s["city"], s["region"], s["countryName"]]
                        .compactMap { $0 as? String }.joined(separator: ", ")
                }.joined(separator: "; ")
                let id = (j["id"] as? NSNumber).map { "\($0)" } ?? ""
                out.append(RawJob(
                    title: j["title"] as? String ?? "",
                    location: where_,
                    url: "https://www.uber.com/global/en/careers/list/\(id)/",
                    posted: Clean.isoDate(j["creationDate"]),
                    department: (j["department"] as? String)
                        ?? (j["team"] as? String) ?? "",
                    description: deep ? Clean.html(j["description"] as? String) : ""))
            }

            page += 1
            if results.isEmpty || out.count > 2000 { break }
        }
        return out
    }

    // MARK: - Citadel

    /// Citadel and Citadel Securities. Config: host.
    ///
    /// The only adapter that reads HTML: their careers site is server-rendered
    /// WordPress with the REST API switched off, so there's no JSON to ask for.
    static func citadel(_ c: Company, deep: Bool) async throws -> [RawJob] {
        guard let host = c.host, !host.isEmpty else {
            throw FetchError.misconfigured("citadel needs a host")
        }
        var out: [RawJob] = []
        var total: Int?

        for page in 1...30 {
            let url = page == 1
                ? "https://\(host)/careers/open-opportunities/"
                : "https://\(host)/careers/open-opportunities/page/\(page)/"
            // Cloudflare throttles bursts, and a 4xx is normally final — so
            // pace the pages and give a 403 one second chance.
            if page > 1 { try? await Task.sleep(for: .milliseconds(800)) }
            var raw: Data
            do {
                raw = try await HTTP.data(url, headers: Self.browserHeaders)
            } catch FetchError.http(403) {
                try? await Task.sleep(for: .seconds(4))
                raw = try await HTTP.data(url, headers: Self.browserHeaders)
            }
            let html = String(decoding: raw, as: UTF8.self)

            if total == nil {
                total = Self.firstInt(Self.citadelTotal, in: html) ?? 0
            }
            let cards = Self.citadelCards(in: html)
            if cards.isEmpty { break }
            out.append(contentsOf: cards)
            if let total, total > 0, out.count >= total { break }
        }
        return out
    }

    /// Cloudflare in front of it wants a browser-shaped request.
    private static let browserHeaders = [
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.9",
        "Sec-Fetch-Dest": "document",
        "Sec-Fetch-Mode": "navigate",
        "Sec-Fetch-Site": "none",
        "Upgrade-Insecure-Requests": "1",
    ]

    private static let citadelCard = try! NSRegularExpression(
        pattern: #"<a\s[^>]*class="[^"]*careers-listing-card[^"]*"[^>]*?href="([^"]+)"[^>]*?data-position="([^"]*)"(.*?)</a>"#,
        options: [.dotMatchesLineSeparators])
    private static let citadelLoc = try! NSRegularExpression(
        pattern: #"careers-listing-card__location"\s*>\s*([^<]*)"#)
    private static let citadelTotal = try! NSRegularExpression(
        pattern: #"class="total-post"[^>]*>(\d+)<"#)

    private static func firstInt(_ rx: NSRegularExpression, in s: String) -> Int? {
        let ns = s as NSString
        guard let m = rx.firstMatch(in: s, range: NSRange(location: 0, length: ns.length))
        else { return nil }
        return Int(ns.substring(with: m.range(at: 1)))
    }

    private static func citadelCards(in html: String) -> [RawJob] {
        let ns = html as NSString
        return citadelCard
            .matches(in: html, range: NSRange(location: 0, length: ns.length))
            .map { m in
                let rest = ns.substring(with: m.range(at: 3))
                let restNS = rest as NSString
                var where_ = ""
                if let l = citadelLoc.firstMatch(
                    in: rest, range: NSRange(location: 0, length: restNS.length)) {
                    where_ = Clean.html(restNS.substring(with: l.range(at: 1)))
                }
                return RawJob(
                    title: Clean.html(ns.substring(with: m.range(at: 2))),
                    location: where_,
                    url: ns.substring(with: m.range(at: 1)),
                    // The listing carries no date; only the detail pages do.
                    posted: "", department: "", description: "")
            }
    }

    // MARK: - Link checking

    /// A second-hand listing is only worth showing if the posting is still
    /// there, so anything from an aggregator gets its link checked.
    ///
    /// A 404/410 means it's gone. A 403/400 usually means the firm blocks
    /// scripted requests (Meta does), which says nothing about whether the job
    /// exists — so that stays "blocked" and the row survives with a caveat
    /// rather than being silently dropped.
    static func checkLink(_ url: String) async -> String {
        guard let link = URL(string: url), !url.isEmpty else { return "dead" }
        var req = URLRequest(url: link)
        req.timeoutInterval = 12
        req.setValue("text/html,application/xhtml+xml,*/*;q=0.8",
                     forHTTPHeaderField: "Accept")
        do {
            let (_, response) = try await HTTP.session.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 200
            if code == 404 || code == 410 { return "dead" }
            return code < 400 ? "ok" : "blocked"
        } catch {
            return "blocked"          // timeout, DNS, reset — inconclusive
        }
    }

    /// Check every link at once, drop the ones that are definitely gone.
    static func verifyLinks(_ jobs: [RawJob]) async -> [RawJob] {
        guard !jobs.isEmpty else { return jobs }
        var checked = [RawJob?](repeating: nil, count: jobs.count)
        await withTaskGroup(of: (Int, String).self) { group in
            var next = 0
            let lanes = min(6, jobs.count)
            for _ in 0..<lanes {
                let i = next; next += 1
                group.addTask { (i, await checkLink(jobs[i].url)) }
            }
            while let (i, status) = await group.next() {
                var job = jobs[i]
                job.linkStatus = status
                checked[i] = job
                if next < jobs.count {
                    let j = next; next += 1
                    group.addTask { (j, await checkLink(jobs[j].url)) }
                }
            }
        }
        return checked.compactMap { $0 }.filter { $0.linkStatus != "dead" }
    }

    // MARK: - Simplify community feed

    /// A parsed row of the feed. Sendable so it can leave the cache actor —
    /// the raw `[[String: Any]]` cannot.
    struct SimplifyRow: Sendable {
        var company: String
        var job: RawJob
    }

    /// One 11 MB download shared by every firm using this source in a run.
    private actor SimplifyFeed {
        static let shared = SimplifyFeed()
        private var cache: [String: [SimplifyRow]] = [:]

        func rows(_ url: String) async throws -> [SimplifyRow] {
            if let hit = cache[url] { return hit }
            guard let list = try await HTTP.json(url) as? [[String: Any]] else {
                throw FetchError.badPayload("unexpected Simplify payload")
            }
            let parsed = list.compactMap { j -> SimplifyRow? in
                guard (j["active"] as? Bool) ?? true,
                      (j["is_visible"] as? Bool) ?? true else { return nil }
                return SimplifyRow(
                    company: ((j["company_name"] as? String) ?? "")
                        .trimmingCharacters(in: .whitespaces).lowercased(),
                    job: RawJob(
                        title: j["title"] as? String ?? "",
                        location: (j["locations"] as? [String] ?? [])
                            .joined(separator: "; "),
                        url: j["url"] as? String ?? "",
                        posted: Adapters.epochDate(j["date_posted"]),
                        department: j["category"] as? String ?? "",
                        description: ""))
            }
            cache[url] = parsed
            return parsed
        }
    }

    static let simplifyURL = "https://raw.githubusercontent.com/SimplifyJobs/"
        + "Summer2027-Internships/dev/.github/scripts/listings.json"

    /// Community internship feed, for firms with no reachable board of their own.
    ///
    /// Apple, Google, Meta and Microsoft publish nothing a script can read, but
    /// Simplify and the Pitt CS Club maintain a public listings.json covering
    /// them, linking straight to each firm's own application page.
    ///
    /// Second-hand by nature: internships only, and its freshness depends on
    /// that project rather than on the firm.
    static func simplify(_ c: Company, deep: Bool) async throws -> [RawJob] {
        let url = (c.host?.isEmpty == false) ? c.host! : simplifyURL
        let rows = try await SimplifyFeed.shared.rows(url)
        let wanted = ((c.query?.isEmpty == false) ? c.query! : c.name)
            .trimmingCharacters(in: .whitespaces).lowercased()
        // Aggregated rows go stale quietly, so drop anything long in the tooth.
        let cutoff = Job.dateFormatter.string(
            from: Date().addingTimeInterval(-120 * 86_400))
        let out = rows
            .filter { $0.company == wanted }
            .map(\.job)
            .filter { $0.posted.isEmpty || $0.posted >= cutoff }
        if out.isEmpty {
            throw FetchError.badPayload(
                "no current '\(wanted)' listings in the Simplify feed")
        }
        // The whole point of a second-hand source: confirm it's still up.
        return await verifyLinks(out)
    }

    // MARK: - Two Sigma

    /// Two Sigma's Avature portal.
    ///
    /// The listing only renders once `jobOffset` is present — a bare
    /// /OpenRoles returns the shell. Ten per page, and the links are absolute,
    /// which is what made an earlier relative-href pattern come back empty.
    static func twoSigma(_ c: Company, deep: Bool) async throws -> [RawJob] {
        var out: [RawJob] = []
        var seen = Set<String>()
        var offset = 0

        while offset <= 400 {
            let raw = try await HTTP.data(
                "https://careers.twosigma.com/careers/OpenRoles?jobOffset=\(offset)",
                headers: Self.browserHeaders)
            let html = String(decoding: raw, as: UTF8.self)
            let ns = html as NSString

            var added = 0
            for m in Self.twoSigmaAnchor.matches(
                in: html, range: NSRange(location: 0, length: ns.length)) {
                let url = ns.substring(with: m.range(at: 1))
                guard seen.insert(url).inserted else { continue }
                added += 1

                // The location span sits just after the anchor; search a short
                // window rather than letting the regex roam the document.
                let after = m.range.location + m.range.length
                let window = NSRange(location: after,
                                     length: min(900, ns.length - after))
                var where_ = ""
                if window.length > 0,
                   let l = Self.twoSigmaLoc.firstMatch(in: html, range: window) {
                    where_ = Self.twoSigmaLocation(
                        Clean.html(ns.substring(with: l.range(at: 1))))
                }

                out.append(RawJob(
                    title: Clean.html(ns.substring(with: m.range(at: 2))),
                    location: where_,
                    url: url,
                    posted: "",        // not shown in the listing
                    department: "", description: ""))
            }
            if added == 0 { break }
            offset += 10
        }
        return out
    }

    private static let twoSigmaAnchor = try! NSRegularExpression(
        pattern: "href=\"(https://careers\\.twosigma\\.com/careers/JobDetail/[^\"#]+)\"[^>]*>([^<]*)</a>")
    private static let twoSigmaLoc = try! NSRegularExpression(
        pattern: "paragraph_inner-span\">\\s*([^<]*)")

    /// Region code and city, e.g. "NY New York". Compiled once: this is called
    /// per posting.
    private static let twoSigmaRegion =
        try! NSRegularExpression(pattern: "^([A-Z]{2})\\s+(.+)$")

    /// "United States - NY New York" is country-first; flip it round.
    private static func twoSigmaLocation(_ raw: String) -> String {
        let parts = raw.components(separatedBy: " - ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard parts.count == 2 else { return raw.trimmingCharacters(in: .whitespaces) }
        let country = parts[0], rest = parts[1]
        let rx = twoSigmaRegion
        let ns = rest as NSString
        if let m = rx.firstMatch(in: rest, range: NSRange(location: 0, length: ns.length)) {
            return "\(ns.substring(with: m.range(at: 2))), "
                 + "\(ns.substring(with: m.range(at: 1))), \(country)"
        }
        return "\(rest), \(country)"
    }

    // MARK: - Jane Street

    /// Jane Street's Greenhouse board carries experienced hires only — 177
    /// roles and not one internship. Students and new grads live in a JSON file
    /// its own careers page fetches, which holds the ~44 internships and ~23
    /// new-grad roles the board omits entirely.
    private static let janeStreetCities = [
        "NYC": "New York, NY", "LDN": "London", "HKG": "Hong Kong",
        "SGP": "Singapore", "AMS": "Amsterdam",
    ]

    /// A handful of letters are swapped for Lisu lookalikes, presumably to make
    /// the titles awkward to scrape: "\u{A4DF}achine \u{A4E1}earning \u{A4E3}esearcher".
    private static let janeStreetHomoglyphs: [Character: Character] = [
        "\u{A4DF}": "M", "\u{A4E1}": "L", "\u{A4E3}": "R",
    ]

    static func janeStreet(_ c: Company, deep: Bool) async throws -> [RawJob] {
        let host = c.host ?? "www.janestreet.com"
        let raw = try await HTTP.data("https://\(host)/jobs/main.json",
                                      headers: Self.browserHeaders)
        guard let rows = try? JSONSerialization.jsonObject(with: raw) as? [[String: Any]]
        else { throw FetchError.badPayload("unexpected Jane Street payload") }

        var out: [RawJob] = []
        for j in rows {
            let title = String(Clean.html(j["position"] as? String ?? "")
                .map { janeStreetHomoglyphs[$0] ?? $0 })
            guard !title.isEmpty else { continue }
            let city = j["city"] as? String ?? ""
            // Availability is the level — "Summer Internship", "Full-Time: New
            // Grad". Folded into the department so the level matcher sees it;
            // the titles themselves say nothing about seniority.
            let availability = j["availability"] as? String ?? ""
            let team = [j["category"] as? String, j["team"] as? String]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " / ")
            let id = j["id"].map { "\($0)" } ?? ""
            out.append(RawJob(
                title: title,
                location: janeStreetCities[city] ?? city,
                url: id.isEmpty ? "" : "https://\(host)/join-jane-street/position/\(id)/",
                posted: "",
                department: [availability, team].filter { !$0.isEmpty }
                    .joined(separator: " / "),
                description: deep ? Clean.html(j["overview"] as? String ?? "") : ""))
        }
        guard !out.isEmpty else {
            throw FetchError.badPayload("no roles in the Jane Street feed")
        }
        return out
    }

    // MARK: - Sites with no board at all

    /// Firms whose real roles exist only as pages in their own sitemap.
    ///
    /// Some sites publish nothing a job board would recognise — no ATS, no
    /// feed, a careers page that is prose — yet every role has a URL, because
    /// the CMS lists them for search engines. HRT is the type case: its public
    /// Greenhouse board holds three talent-community signposts while seventy
    /// roles sit on its own site.
    static let sitemapGate = RequestGate(limit: 6)

    private static let hrtLoc = try! NSRegularExpression(
        pattern: "class='summary-info'>(.*?)</div>", options: [.dotMatchesLineSeparators])
    private static let hrtTitle = try! NSRegularExpression(
        pattern: "<title>(.*?)</title>", options: [.dotMatchesLineSeparators])
    private static let hrtSitemap = try! NSRegularExpression(
        pattern: "<loc>([^<]+)</loc>")

    static func sitemapJobs(_ c: Company, deep: Bool) async throws -> [RawJob] {
        guard let host = c.host, !host.isEmpty,
              let file = c.sitemap, !file.isEmpty else {
            throw FetchError.misconfigured("sitemap adapter needs host and sitemap")
        }
        let marker = c.path ?? "/"
        let raw = try await HTTP.data("https://\(host)/\(file)",
                                      headers: Self.browserHeaders)
        let xml = String(decoding: raw, as: UTF8.self)
        let ns = xml as NSString
        let urls = hrtSitemap.matches(in: xml,
                                      range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
            .filter { $0.contains(marker) }
        guard !urls.isEmpty else {
            throw FetchError.badPayload("no job pages in \(file)")
        }

        // The sitemap's <lastmod> is deliberately unused: every entry carries
        // the same timestamp, so it says when the sitemap was regenerated, not
        // when anything was posted. Dating all 72 roles today would float them
        // above genuinely fresh postings.
        var out: [RawJob] = []
        await withTaskGroup(of: RawJob?.self) { group in
            for url in urls {
                group.addTask {
                    await sitemapOne(url, titleLoc: c.titleLoc == true, firm: c.name)
                }
            }
            for await job in group { if let job { out.append(job) } }
        }
        // One page per role means a network hiccup silently shrinks the board,
        // and a board that quietly returns 60 of 72 roles is worse than one
        // that says it failed. Tolerate the odd miss, report anything worse.
        let missing = urls.count - out.count
        guard missing <= max(3, urls.count / 10) else {
            throw FetchError.badPayload(
                "only read \(out.count) of \(urls.count) job pages")
        }
        return out
    }

    private static func sitemapOne(_ url: String, titleLoc: Bool,
                                   firm: String) async -> RawJob? {
        guard let raw = try? await sitemapGate.run({
            try await HTTP.data(url, headers: Self.browserHeaders)
        }) else { return nil }
        let html = String(decoding: raw, as: UTF8.self)
        let ns = html as NSString
        let whole = NSRange(location: 0, length: ns.length)

        guard let t = hrtTitle.firstMatch(in: html, range: whole) else { return nil }
        var title = Clean.html(ns.substring(with: t.range(at: 1)))
            .trimmingCharacters(in: .whitespaces)
        // Page titles carry the firm: "AI Researcher | Hudson River Trading",
        // "London Technology Internship - Marshall Wace".
        for sep in ["|", " - ", " – ", " — "] {
            guard let head = title.components(separatedBy: sep).first,
                  head.count != title.count else { continue }
            if sep == "|" || title.lowercased().contains(firm.lowercased()) {
                title = head.trimmingCharacters(in: .whitespaces)
                break
            }
        }
        guard !title.isEmpty else { return nil }

        var where_ = ""
        if let l = hrtLoc.firstMatch(in: html, range: whole) {
            // "London <span>|</span> New York" — the separators are markup.
            where_ = ns.substring(with: l.range(at: 1))
                .replacingOccurrences(of: "<[^>]+>", with: "\u{1}",
                                      options: .regularExpression)
                .components(separatedBy: "\u{1}")
                .map { Clean.html($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && $0 != "|" }
                .joined(separator: ", ")
        }
        if where_.isEmpty && titleLoc { where_ = LocationParser.leadingCity(title) }
        return RawJob(title: title, location: where_, url: url,
                      posted: "", department: "", description: "")
    }

    // MARK: - Optiver

    /// Optiver's own jobs pages.
    ///
    /// Deliberately partial: the listing renders 16 roles then loads the rest
    /// with JavaScript, and there's no API, sitemap or page parameter behind it
    /// (every ?page/?offset/?limit variant returns the same 16). So this walks
    /// the per-category pages, getting the newest 16 of each.
    static func optiver(_ c: Company, deep: Bool) async throws -> [RawJob] {
        let base = "https://www.optiver.com"
        let rootRaw = try await HTTP.data(base + "/join-us/jobs/",
                                          headers: Self.browserHeaders)
        let root = String(decoding: rootRaw, as: UTF8.self)

        // Take the category list from the page rather than hard-coding it.
        var cats: [String] = []
        let catRx = optiverCategory
        let rootNS = root as NSString
        for m in catRx.matches(in: root,
                               range: NSRange(location: 0, length: rootNS.length)) {
            let cat = rootNS.substring(with: m.range(at: 1))
            if !cats.contains(cat) { cats.append(cat) }
        }

        var pages = [root]
        for cat in cats.prefix(8) {
            if let raw = try? await HTTP.data("\(base)/join-us/jobs/\(cat)/",
                                              headers: Self.browserHeaders) {
                pages.append(String(decoding: raw, as: UTF8.self))
            }
        }

        var out: [RawJob] = []
        var seen = Set<String>()
        for html in pages {
            let ns = html as NSString
            for m in Self.optiverJob.matches(
                in: html, range: NSRange(location: 0, length: ns.length)) {
                let path = ns.substring(with: m.range(at: 1))
                guard seen.insert(path).inserted else { continue }
                let cat = ns.substring(with: m.range(at: 2))
                let city = ns.substring(with: m.range(at: 3))
                let title = Clean.html(ns.substring(with: m.range(at: 4)))
                let loc = Clean.html(ns.substring(with: m.range(at: 5)))
                out.append(RawJob(
                    title: title,
                    location: loc.isEmpty
                        ? city.replacingOccurrences(of: "-", with: " ").capitalized
                        : loc,
                    url: base + path,
                    posted: "",       // not shown in the listing
                    department: cat.replacingOccurrences(of: "-", with: " ").capitalized,
                    description: ""))
            }
        }
        return out
    }

    private static let optiverCategory = try! NSRegularExpression(
        pattern: #"href="/join-us/jobs/([a-z0-9-]+)/[a-z0-9-]+/"#)

    private static let optiverJob = try! NSRegularExpression(
        pattern: "<a\\s+href=\"(/join-us/jobs/([a-z0-9-]+)/([a-z0-9-]+)/[^\"#]+)\"[^>]*>([^<]+)</a>\\s*</h3>\\s*<p[^>]*>([^<]*)</p>",
        options: [.caseInsensitive])

    // MARK: - Wolverine Trading

    /// Their in-house listing: one flat array, no paging.
    static func wolverine(_ c: Company, deep: Bool) async throws -> [RawJob] {
        guard let list = try await HTTP.json("https://www.wolve.com/api/positions")
                as? [[String: Any]] else {
            throw FetchError.badPayload("unexpected Wolverine payload")
        }
        return list.compactMap { j in
            let status = (j["Status"] as? String ?? "").lowercased()
            guard status != "closed", status != "filled" else { return nil }
            let where_ = [j["City"], j["State"]]
                .compactMap { $0 as? String }.filter { !$0.isEmpty }
                .joined(separator: ", ")
            let id = j["ID"] as? String ?? ""
            return RawJob(
                title: j["Title"] as? String ?? "",
                location: where_.isEmpty ? (j["Location"] as? String ?? "") : where_,
                url: "https://www.wolve.com/careers?job=\(id)",
                posted: Clean.isoDate(j["DateOpened"] ?? j["CreatedOn"]),
                department: (j["JobDepartment"] as? String)
                    ?? (j["Category"] as? String) ?? "",
                description: deep ? Clean.html(j["Description"] as? String) : "")
        }
    }

    /// amazon.jobs prints dates as "July 31, 2026".
    private static let amazonFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM d, yyyy"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private static func amazonDate(_ v: Any?) -> String {
        guard let s = v as? String,
              let date = amazonFormatter.date(from: s.trimmingCharacters(in: .whitespaces))
        else { return "" }
        return Job.dateFormatter.string(from: date)
    }
}

// MARK: - Discovery

/// Sniffs a careers page for an ATS fingerprint, so a firm can be added
/// without hunting through page source by hand.
enum Discovery {

    struct Hit: Identifiable, Hashable, Sendable {
        var ats: ATS
        var token: String
        var id: String { "\(ats.rawValue)|\(token)" }

        /// A ready-to-paste companies.json entry.
        var snippet: String {
            ats == .workday
                ? #"{ "name": "…", "ats": "workday", "host": "\#(token)", "tenant": "…", "site": "…", "enabled": true }"#
                : #"{ "name": "…", "ats": "\#(ats.rawValue)", "token": "\#(token)", "enabled": true }"#
        }
    }

    private static let patterns: [(ATS, String)] = [
        (.greenhouse, #"(?:boards|job-boards)\.greenhouse\.io/(?:embed/job_board\?for=)?([a-zA-Z0-9_-]+)"#),
        (.greenhouse, #"for=([a-zA-Z0-9_]+)"#),
        (.lever, #"jobs\.lever\.co/([a-zA-Z0-9_-]+)"#),
        (.ashby, #"jobs\.ashbyhq\.com/([a-zA-Z0-9_-]+)"#),
        (.smartrecruiters, #"smartrecruiters\.com/(?:v1/companies/)?([a-zA-Z0-9_-]+)"#),
        (.workday, #"([a-z0-9-]+\.wd\d+\.myworkdayjobs\.com)"#),
    ]

    private static let noise: Set<String> = ["embed", "job_board", "v1", "www", "jobs"]

    static func run(_ urlString: String) async throws -> [Hit] {
        let raw = try await HTTP.data(urlString)
        let html = String(decoding: raw, as: UTF8.self)
        let ns = html as NSString
        var hits: Set<Hit> = []

        for (ats, pattern) in patterns {
            guard let rx = try? NSRegularExpression(pattern: pattern) else { continue }
            for m in rx.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
                let token = ns.substring(with: m.range(at: 1))
                if noise.contains(token.lowercased()) { continue }
                hits.insert(Hit(ats: ats, token: token))
            }
        }
        return hits.sorted { ($0.ats.rawValue, $0.token) < ($1.ats.rawValue, $1.token) }
    }
}
