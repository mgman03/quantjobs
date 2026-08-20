import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // URLSession lives here off Apple platforms
#endif

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
        case .oracle:          try await oracle(c, deep: deep)
        case .meta:            try await meta(c, deep: deep)
        case .stripe:          try await stripe(c, deep: deep)
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
        case .deshaw:          try await deShaw(c, deep: deep)
        case .gresearch:       try await gResearch(c, deep: deep)
        case .google:          try await google(c, deep: deep)
        case .apple:           try await apple(c, deep: deep)
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

    // MARK: - Meta

    /// Meta, read from its sitemap and the structured data on each posting.
    ///
    /// metacareers.com answers 400 to anything that does not look like a
    /// browser *navigating* — the Sec-Fetch-* headers are what it checks, and
    /// with them the whole site opens up, robots.txt included. That is the
    /// whole of the workaround. The job search itself is Relay over GraphQL and
    /// still out of reach: the operation names are in the bundles
    /// (CareersJobSearchResultsDataQuery and friends) but the doc_id that makes
    /// them callable is not, and Meta answers a persisted query it cannot
    /// resolve with a blank 500.
    ///
    /// So: the jobsearch sitemap lists every posting, and every posting page
    /// carries a schema.org JobPosting with the title, the offices and the date
    /// — the same block Google reads to put these in its jobs results.
    ///
    /// The cost is one request per posting, which is why this is the only
    /// adapter here that works that way — around 850 of them, three or four
    /// minutes, and it is most of what a full run now spends its time on.
    ///
    /// Two things that look like they would fix that do not. The sitemap's
    /// lastmod is useless as a recency signal: Meta touches every posting
    /// weekly, so all 859 are "modified this week" and there is no newest slice
    /// to take. And reading only the first two kilobytes of each page — the
    /// structured data sits at byte 1,220 of 530 KB — buys nothing, because
    /// the server sends no Accept-Ranges and URLSession's byte stream awaits
    /// per byte, which costs more than the transfer it saves.
    static func meta(_ c: Company, deep: Bool) async throws -> [RawJob] {
        let host = c.host ?? "www.metacareers.com"
        let raw = try await HTTP.data("https://\(host)/jobsearch/sitemap.xml",
                                      headers: Self.browserHeaders)
        let xml = String(decoding: raw, as: UTF8.self)

        // <loc> and <lastmod> in pairs, newest first, so a cap keeps what is
        // most likely to still be open rather than an arbitrary slice.
        var entries: [(url: String, modified: String)] = []
        for part in xml.components(separatedBy: "<url>").dropFirst() {
            guard let loc = Self.between(part, "<loc>", "</loc>")?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  loc.contains("/job_details/") else { continue }
            let mod = Self.between(part, "<lastmod>", "</lastmod>") ?? ""
            entries.append((loc, mod))
        }
        guard !entries.isEmpty else {
            throw FetchError.badPayload("no postings in Meta's sitemap")
        }
        entries.sort { $0.modified > $1.modified }
        let wanted = Array(entries.prefix(Self.metaCap))

        // Bounded, and gathered as they land. A firm that answers slowly must
        // not hold up the rest of the run, which is why this is a group and not
        // a loop.
        // Four at a time, not eight. A thousand requests to one host is the
        // shape of thing that gets throttled, and it did: eight was fine when
        // Meta was the only board running and lost a fifth of the postings when
        // it was competing with every other firm in a full run.
        func gather(_ urls: [(url: String, modified: String)])
            async -> [(RawJob?, String)] {
            await withTaskGroup(of: (RawJob?, String).self) { group in
                let gate = RequestGate(limit: 4)
                for entry in urls {
                    group.addTask {
                        let job = try? await gate.run {
                            let page = try await HTTP.data(entry.url,
                                                           headers: Self.browserHeaders,
                                                           retries: 2)
                            return Self.metaPosting(String(decoding: page, as: UTF8.self),
                                                    url: entry.url, deep: deep)
                        }
                        return (job ?? nil, entry.url)
                    }
                }
                var out: [(RawJob?, String)] = []
                for await r in group { out.append(r) }
                return out
            }
        }

        var answered = await gather(wanted)
        // One more pass over whatever did not answer, unhurried. Postings that
        // failed under load usually come back on their own.
        let missed = answered.filter { $0.0 == nil }.map(\.1)
        if !missed.isEmpty, missed.count < wanted.count {
            let retried = await gather(missed.map { (url: $0, modified: "") })
            answered = answered.filter { $0.0 != nil } + retried
        }
        let results = answered.compactMap(\.0)

        // A thousand requests to one host is exactly the shape of thing that
        // gets throttled, and a throttled run reads as a firm with six jobs
        // rather than as a firm that failed. Say so instead: better an error in
        // the status bar than a board that quietly shrank.
        guard results.count * 4 >= wanted.count * 3 else {
            throw FetchError.badPayload(
                "only \(results.count) of \(wanted.count) Meta postings answered")
        }
        return results
    }

    /// How many postings to read. Meta lists around nine hundred; this is not a
    /// limit anyone has hit, it is a guard against a sitemap that grows by an
    /// order of magnitude without anyone noticing the run got slower.
    private static let metaCap = 1200

    /// The schema.org JobPosting a Meta posting page carries, which sits in the
    /// first two kilobytes of it.
    private static func metaPosting(_ html: String, url: String, deep: Bool) -> RawJob? {
        guard let open = html.range(of: "application/ld+json"),
              let gt = html.range(of: ">", range: open.upperBound..<html.endIndex),
              let close = html.range(of: "</script>", range: gt.upperBound..<html.endIndex),
              let data = String(html[gt.upperBound..<close.lowerBound])
                .data(using: .utf8),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              d["@type"] as? String == "JobPosting",
              let title = d["title"] as? String, !title.isEmpty
        else { return nil }

        // One Place, or several for a role open in more than one office.
        let places: [String]
        switch d["jobLocation"] {
        case let many as [[String: Any]]: places = many.compactMap { $0["name"] as? String }
        case let one as [String: Any]:    places = [one["name"] as? String].compactMap { $0 }
        default:                          places = []
        }
        return RawJob(
            title: Clean.html(title),
            location: places.joined(separator: "; "),
            url: url,
            // "2026-08-13T08:42:44-07:00" — the date is the first ten of it.
            posted: String((d["datePosted"] as? String ?? "").prefix(10)),
            department: (d["occupationalCategory"] as? String) ?? "",
            description: deep ? Clean.html(d["description"] as? String ?? "") : "")
    }

    private static func between(_ s: String, _ open: String, _ close: String) -> String? {
        guard let a = s.range(of: open),
              let b = s.range(of: close, range: a.upperBound..<s.endIndex)
        else { return nil }
        return String(s[a.upperBound..<b.lowerBound])
    }

    // MARK: - Oracle Cloud (Oracle HCM Candidate Experience)

    /// Oracle's hosted careers site, which is what JPMorgan and a good many
    /// other banks run on.
    ///
    /// A platform rather than one firm, so this is written the way the Workday
    /// adapter is: give it a host and a site number and it reads any tenant.
    /// The REST resource behind the page is public — it is what the page itself
    /// calls — and answers JSON without a key.
    ///
    /// `query` is worth setting on a big tenant. JPMorgan posts 7,388 roles;
    /// the keyword narrows that server-side, loosely (it matches descriptions
    /// too), and the app's own matchers do the rest.
    static func oracle(_ c: Company, deep: Bool) async throws -> [RawJob] {
        guard let host = c.host, !host.isEmpty else {
            throw FetchError.misconfigured("oracle needs a host")
        }
        // Oracle calls a careers site CX_1001, CX_1002 and so on. Almost every
        // tenant has exactly one and it is the first.
        let site = c.site.flatMap { $0.isEmpty ? nil : $0 } ?? "CX_1001"
        let pageSize = 200                 // the most this resource will return
        let cap = 2000

        func page(_ offset: Int) async throws -> ([RawJob], Int) {
            var finder = "findReqs;siteNumber=\(site),limit=\(pageSize)"
                + ",offset=\(offset),sortBy=POSTING_DATES_DESC"
            if let q = c.query, !q.isEmpty {
                finder += ",keyword=\(Self.escape(q))"
            }
            let url = "https://\(host)/hcmRestApi/resources/latest"
                + "/recruitingCEJobRequisitions?onlyData=true"
                + "&expand=requisitionList.secondaryLocations&finder=\(finder)"
            let payload = try await HTTP.object(url)
            // One item, holding the list and the count. Not a list of items.
            guard let head = (payload["items"] as? [[String: Any]])?.first else {
                return ([], 0)
            }
            let total = head["TotalJobsCount"] as? Int ?? 0
            let jobs = (head["requisitionList"] as? [[String: Any]] ?? []).map { j -> RawJob in
                let id = j["Id"].map { "\($0)" } ?? ""
                let places = ([j["PrimaryLocation"] as? String]
                    + (j["secondaryLocations"] as? [[String: Any]] ?? [])
                        .map { $0["Name"] as? String })
                    .compactMap { $0 }.filter { !$0.isEmpty }
                return RawJob(
                    title: j["Title"] as? String ?? "",
                    location: places.joined(separator: "; "),
                    url: "https://\(host)/hcmUI/CandidateExperience/en/sites/"
                        + "\(site)/job/\(id)",
                    posted: j["PostedDate"] as? String ?? "",
                    department: [j["JobFamily"] as? String, j["JobFunction"] as? String]
                        .compactMap { $0 }.filter { !$0.isEmpty }
                        .joined(separator: " / "),
                    description: deep ? (j["ShortDescriptionStr"] as? String ?? "") : "")
            }
            return (jobs, total)
        }

        let (first, total) = try await page(0)
        guard !first.isEmpty else { return first }
        var out = first
        var offset = pageSize
        while offset < min(total, cap) {
            let (more, _) = try await page(offset)
            if more.isEmpty { break }
            out += more
            offset += pageSize
        }
        return out
    }

    /// Percent-encoding for a value going into an Oracle finder clause, where a
    /// comma separates parameters and would otherwise cut the keyword in half.
    private static func escape(_ s: String) -> String {
        s.addingPercentEncoding(
            withAllowedCharacters: CharacterSet.alphanumerics.union(.init(charactersIn: "-_.~")))
            ?? s
    }

    // MARK: - Stripe

    /// Stripe's Greenhouse board, narrowed to what stripe.com actually lists.
    ///
    /// Greenhouse keeps answering for postings Stripe has already taken down:
    /// 578 jobs on the board against 544 on the careers site, and the ones in
    /// between are dead. They look perfectly alive in a list — the Dublin
    /// "Software Engineer, Intern" was one — and the board's own link goes to a
    /// page that says "Sorry", because `stripe.com/jobs/search?gh_jid=…` is a
    /// redirect that only resolves for a posting the site still has. There is
    /// no field on the Greenhouse record that says so.
    ///
    /// The careers page is a Next.js app, so its index of live roles ships
    /// inside the document it serves, keyed by the same Greenhouse id. That
    /// makes the check one extra request for the whole board: keep the
    /// Greenhouse data, which has the posted dates and departments the index
    /// lacks, and drop anything the index does not know about.
    ///
    /// The URL is rebuilt from the index's slug for the same reason — the
    /// direct listing link needs no redirect to resolve.
    static func stripe(_ c: Company, deep: Bool) async throws -> [RawJob] {
        let jobs = try await greenhouse(c, deep: deep)
        guard let live = try? await stripeListings() , !live.isEmpty else {
            // The careers page moved or stopped hydrating. Better a board with
            // a few dead links than no Stripe at all.
            return jobs
        }
        return jobs.compactMap { job in
            guard let id = job.url.components(separatedBy: "gh_jid=").last,
                  let slug = live[id]
            else { return nil }
            var kept = job
            kept.url = "https://stripe.com/careers/listing/\(slug)/\(id)"
            return kept
        }
    }

    /// Greenhouse id → careers-site slug, for every role stripe.com lists.
    private static func stripeListings() async throws -> [String: String] {
        let raw = try await HTTP.data("https://stripe.com/jobs/search",
                                      headers: Self.browserHeaders)
        let html = String(decoding: raw, as: UTF8.self)
        guard let payload = Self.nextDataPayload(html),
              let props = (payload["props"] as? [String: Any])?["pageProps"]
                as? [String: Any],
              let index = props["jobIndexData"] as? [String: Any],
              let listings = index["listings"] as? [[String: Any]]
        else { throw FetchError.badPayload("no job index on the Stripe careers page") }

        var out: [String: String] = [:]
        for l in listings {
            guard let slug = l["slug"] as? String, !slug.isEmpty else { continue }
            // A JSON number in the payload, a string in the Greenhouse URL.
            let id = (l["greenhouseId"] as? NSNumber).map { "\($0)" }
                ?? l["greenhouseId"] as? String ?? ""
            if !id.isEmpty { out[id] = slug }
        }
        return out
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
                    url: "https://jobs.smartrecruiters.com/\(token)/\(Clean.scalar(j["id"]))",
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
                let id = Clean.scalar(j["id"])
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
            // Data rather than HTTP.json: `Any` is not Sendable and this is an
            // actor, so decoding has to happen on this side of the hop.
            let raw = try await HTTP.data(url)
            guard let list = try? JSONSerialization.jsonObject(with: raw)
                    as? [[String: Any]] else {
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

    // MARK: - D. E. Shaw

    /// The D. E. Shaw group, read from the payload its careers page hydrates.
    ///
    /// The site is a Next.js app, so the listing it renders client-side is also
    /// embedded in the document it serves — every role, one request, no API to
    /// find. `__NEXT_DATA__` is a framework convention rather than a private
    /// endpoint, so this is the same read a browser does.
    ///
    static func deShaw(_ c: Company, deep: Bool) async throws -> [RawJob] {
        let host = c.host ?? "www.deshaw.com"
        let raw = try await HTTP.data("https://\(host)/careers",
                                      headers: Self.browserHeaders)
        let html = String(decoding: raw, as: UTF8.self)
        guard let payload = Self.nextDataPayload(html) else {
            throw FetchError.badPayload("no __NEXT_DATA__ on the D. E. Shaw careers page")
        }
        guard let props = (payload["props"] as? [String: Any])?["pageProps"]
                as? [String: Any] else {
            throw FetchError.badPayload("unreadable D. E. Shaw payload")
        }

        var out: [RawJob] = []
        // `internalJobs` is the third bucket and deliberately skipped: those are
        // transfers for people already there, not roles anyone can apply to.
        for bucket in ["internships", "regularJobs"] {
            for entry in props[bucket] as? [[String: Any]] ?? [] {
                guard let data = entry["data"] as? [String: Any],
                      let slug = data["jobUrl"] as? String, !slug.isEmpty
                else { continue }
                let title = Clean.html(data["displayName"] as? String ?? "")
                guard !title.isEmpty else { continue }
                if data["activeOnJobsListing"] as? Bool == false { continue }

                let meta = data["jobMetadata"] as? [String: Any] ?? [:]
                var places = (meta["jobLocations"] as? [[String: Any]] ?? [])
                    .compactMap { $0["name"] as? String }
                if places.isEmpty {
                    places = (entry["office"] as? [[String: Any]] ?? [])
                        .compactMap { $0["name"] as? String }
                }
                let dept = (data["department"] as? [String: Any])?["name"] as? String ?? ""
                let cats = (data["jobCategory"] as? [[String: Any]] ?? [])
                    .compactMap { $0["name"] as? String }.joined(separator: " / ")
                let body = (data["jobDescription"] as? [String: Any])?["websiteDescription"]
                    as? String ?? ""
                out.append(RawJob(
                    title: title,
                    location: places.joined(separator: ", "),
                    // The slug is title-cased in the payload and lowercase on the
                    // site; the title-cased form answers 308 rather than 200.
                    url: "https://\(host)/careers/\(slug.lowercased())",
                    // Nothing in the payload carries one, so these only ever get
                    // the first-seen date.
                    posted: "",
                    department: [dept, cats].filter { !$0.isEmpty }
                        .joined(separator: " / "),
                    description: deep ? Clean.html(body) : ""))
            }
        }
        guard !out.isEmpty else {
            throw FetchError.badPayload("no roles in the D. E. Shaw payload")
        }
        return out
    }

    /// Pulls the JSON out of a Next.js page's `__NEXT_DATA__` script tag.
    private static func nextDataPayload(_ html: String) -> [String: Any]? {
        guard let open = html.range(of: "<script id=\"__NEXT_DATA__\""),
              let gt = html.range(of: ">", range: open.upperBound..<html.endIndex),
              let close = html.range(of: "</script>",
                                     range: gt.upperBound..<html.endIndex)
        else { return nil }
        let json = html[gt.upperBound..<close.lowerBound]
        return try? JSONSerialization.jsonObject(with: Data(json.utf8))
            as? [String: Any]
    }

    // MARK: - G-Research

    /// G-Research's own vacancies listing, which is server-rendered.
    ///
    /// One request gets everything. The page renders /page/2/ and /page/3/ links
    /// but each returns the identical sixty-odd vacancies, so following them
    /// would triple the work to collect duplicates.
    ///
    static func gResearch(_ c: Company, deep: Bool) async throws -> [RawJob] {
        let host = c.host ?? "www.gresearch.com"
        let raw = try await HTTP.data("https://\(host)/vacancies/",
                                      headers: Self.browserHeaders)
        let html = String(decoding: raw, as: UTF8.self)

        var out: [RawJob] = []
        let ns = html as NSString
        for m in Self.gResearchCard.matches(
            in: html, range: NSRange(location: 0, length: ns.length)) {
            let title = Clean.html(ns.substring(with: m.range(at: 2)))
            guard !title.isEmpty else { continue }
            // The location span is optional in the markup, so its group can be
            // absent on a card that names no office.
            let locRange = m.range(at: 3)
            out.append(RawJob(
                title: title,
                location: locRange.location == NSNotFound
                    ? "" : Clean.html(ns.substring(with: locRange)),
                url: ns.substring(with: m.range(at: 1)),
                // Neither the listing nor the detail pages publish a date.
                posted: "",
                department: "",
                description: ""))
        }
        guard !out.isEmpty else {
            throw FetchError.badPayload("no vacancies on the G-Research listing")
        }
        return out
    }

    private static let gResearchCard = try! NSRegularExpression(
        pattern: #"<a href="([^"]+)" class="c-vacancy-result">\s*<span class="c-vacancy-result__title">([^<]*)</span>\s*(?:<span class="c-vacancy-result__location">([^<]*)</span>)?"#,
        options: [.dotMatchesLineSeparators])

    // MARK: - Google

    /// Google's own careers listing, which server-renders its results.
    ///
    /// Two server-side slices rather than the whole board: Google has thousands
    /// of openings at twenty a page, so asking for all of them would be hundreds
    /// of requests to discard nearly everything. `employment_type=INTERN` is the
    /// internships and apprenticeships and `target_level=EARLY` is the new-grad
    /// end of full-time, which together is what this tracker is for.
    ///
    /// Replaces the Simplify feed for Google, whose three rows had all gone dead.
    static func google(_ c: Company, deep: Bool) async throws -> [RawJob] {
        let host = c.host ?? "www.google.com"
        let base = "https://\(host)/about/careers/applications"
        var seen = Set<String>()
        var out: [RawJob] = []

        for slice in ["employment_type=INTERN", "target_level=EARLY"] {
            // EARLY runs to about page 20; the cap sits well past it.
            for page in 1...25 {
                var url = "\(base)/jobs/results?\(slice)&sort_by=date"
                if page > 1 { url += "&page=\(page)" }
                let raw = try await HTTP.data(url, headers: Self.browserHeaders)
                let html = String(decoding: raw, as: UTF8.self)
                let cards = html.components(separatedBy: Self.googleCardSplit)
                    .dropFirst()
                if cards.isEmpty { break }
                for card in cards {
                    let ns = card as NSString
                    let full = NSRange(location: 0, length: ns.length)
                    guard let t = Self.googleTitle.firstMatch(in: card, range: full),
                          let h = Self.googleHref.firstMatch(in: card, range: full)
                    else { continue }
                    let path = ns.substring(with: h.range(at: 1))
                    // A role can sit in both slices.
                    guard seen.insert(path).inserted else { continue }
                    // Extra offices arrive as "; Ann Arbor, MI, USA" spans.
                    var places: [String] = []
                    for m in Self.googleLoc.matches(in: card, range: full) {
                        let p = ns.substring(with: m.range(at: 1))
                            .trimmingCharacters(in: CharacterSet(charactersIn: "; "))
                        if !p.isEmpty && !places.contains(p) { places.append(p) }
                    }
                    out.append(RawJob(
                        title: Clean.html(ns.substring(with: t.range(at: 1))),
                        location: places.joined(separator: ", "),
                        url: "\(base)/\(path)",
                        // The cards carry no date; only the detail pages do, and
                        // that would be a request per role.
                        posted: "",
                        department: "",
                        description: ""))
                }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
        guard !out.isEmpty else {
            throw FetchError.badPayload("no cards on the Google careers listing")
        }
        return out
    }

    /// Google ships compiled CSS class names, which are the fragile part of this.
    /// Of the three anchors, the `aria-label` is sturdiest — it exists for screen
    /// readers, so it survives redesigns that rename classes.
    private static let googleCardSplit = "class=\"lLd3Je\""
    private static let googleTitle = try! NSRegularExpression(
        pattern: #"aria-label="Learn more about ([^"]+)""#)
    private static let googleHref = try! NSRegularExpression(
        pattern: #"href="(jobs/results/[^"?]+)"#)
    private static let googleLoc = try! NSRegularExpression(
        pattern: #"class="r0wTof[^"]*">([^<]+)</span>"#)

    // MARK: - Apple

    /// Apple's own careers search, filtered to the Students/Internships team.
    ///
    /// The pages are server-rendered with semantic markup, so this is a much
    /// steadier read than Google's compiled class names — and Apple dates its
    /// cards, which almost nothing else here does.
    ///
    /// The team filter is what matters: `search=intern` returns retail roles
    /// ("IN-Business Expert") because the keyword is matched against everything.
    ///
    /// Replaces the Simplify feed for Apple, which carried 12 second-hand rows
    /// against the ~51 internships Apple actually lists.
    static func apple(_ c: Company, deep: Bool) async throws -> [RawJob] {
        let host = c.host ?? "jobs.apple.com"
        var seen = Set<String>()
        var out: [RawJob] = []

        for page in 1...15 {
            var url = "https://\(host)/en-us/search?team=internships-STDNT-INTRN"
                + "&sort=newest"
            if page > 1 { url += "&page=\(page)" }
            let raw = try await HTTP.data(url, headers: Self.browserHeaders)
            let html = String(decoding: raw, as: UTF8.self)
            // Not `class="job-title-link"` — the class sits mid-list in the
            // attribute, so anchoring on class= finds nothing.
            let cards = html.components(separatedBy: "job-title-link").dropFirst()
            if cards.isEmpty { break }
            for card in cards {
                let ns = card as NSString
                let full = NSRange(location: 0, length: ns.length)
                guard let m = Self.appleTitle.firstMatch(in: card, range: full)
                else { continue }
                let path = ns.substring(with: m.range(at: 1))
                let title = Clean.html(ns.substring(with: m.range(at: 2)))
                let key = path.split(separator: "/").dropFirst(2).first.map(String.init)
                    ?? path
                guard !title.isEmpty, seen.insert(key).inserted else { continue }
                var place = "", when = ""
                if let l = Self.appleLoc.firstMatch(in: card, range: full) {
                    place = Clean.html(ns.substring(with: l.range(at: 1)))
                }
                if let d = Self.appleDate.firstMatch(in: card, range: full) {
                    when = Self.appleDay(ns.substring(with: d.range(at: 1)))
                }
                out.append(RawJob(title: title, location: place,
                                  url: "https://\(host)\(path)",
                                  posted: when, department: "", description: ""))
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
        guard !out.isEmpty else {
            throw FetchError.badPayload("no cards on the Apple careers search")
        }
        return out
    }

    private static let appleTitle = try! NSRegularExpression(
        pattern: #"href="(/en-us/details/[^"]+)"[^>]*>\s*([^<]{3,140}?)\s*</a>"#,
        options: [.dotMatchesLineSeparators])
    private static let appleDate = try! NSRegularExpression(
        pattern: #"class="job-posted-date"[^>]*>\s*([^<]+?)\s*<"#)
    private static let appleLoc = try! NSRegularExpression(
        pattern: #"id="search-store-name-container-\d+"[^>]*>\s*([^<]+?)\s*<"#)

    /// "Aug 07, 2026" to 2026-08-07. Empty if Apple changes the format.
    private static func appleDay(_ s: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM dd, yyyy"
        guard let d = f.date(from: s.trimmingCharacters(in: .whitespaces))
        else { return "" }
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
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
    /// Optiver's own jobs pages, read from the payload their React app hydrates.
    ///
    /// The listing renders 16 cards and loads the rest with JavaScript, and every
    /// ?page/?offset/?limit variant returns the same 16 — which is why this used
    /// to walk the per-category pages and settle for the newest 16 of each. That
    /// missed real roles: Software Engineer Intern (Summer 2027) in both Austin
    /// and Chicago were absent while the FPGA one, on the same page, was present.
    ///
    /// Two things fix it. The full list for a page sits in the page as JSON,
    /// inside the `React.createElement(Components.JobsFiltered, {…})` call their
    /// SSR emits — no card parsing, and it carries the discipline and seniority as
    /// fields rather than as CSS classes. And the server does honour `?level=`, so
    /// asking one level at a time keeps each response under the 16 it renders.
    ///
    /// `level` is the parameter, not `experience`, which is what the markup calls
    /// it and what the server ignores.
    ///
    /// Early-career coverage is complete this way — internship returns 12 and
    /// graduate 9, both under the cap. Experienced is still the newest 16 of many.
    static func optiver(_ c: Company, deep: Bool) async throws -> [RawJob] {
        let base = "https://www.optiver.com"
        var out: [RawJob] = []
        var seen = Set<String>()

        for level in ["internship", "graduate", "experienced"] {
            guard let raw = try? await HTTP.data(
                    "\(base)/join-us/jobs/?level=\(level)",
                    headers: Self.browserHeaders) else { continue }
            let html = String(decoding: raw, as: UTF8.self)

            for job in optiverItems(html) {
                let path = job["href"] as? String ?? ""
                guard !path.isEmpty, seen.insert(path).inserted else { continue }
                let domain = job["domain"] as? String ?? ""
                let experience = job["experience"] as? String ?? ""
                out.append(RawJob(
                    title: Clean.html(job["title"] as? String ?? ""),
                    location: Clean.html(job["location"] as? String ?? ""),
                    url: base + path,
                    posted: "",       // not stated anywhere in the listing
                    // Their own words for discipline and seniority. The level
                    // detector reads department too, so "Internship" here rescues
                    // a title that never says so itself.
                    department: [domain, experience]
                        .filter { !$0.isEmpty }.joined(separator: " / "),
                    description: ""))
            }
        }
        return out
    }

    private static let optiverProps = "React.createElement(Components.JobsFiltered,"

    /// The `items` array out of the hydration call, or nothing if it moves.
    private static func optiverItems(_ html: String) -> [[String: Any]] {
        guard let at = html.range(of: optiverProps),
              let open = html.range(of: "{", range: at.upperBound..<html.endIndex)
        else { return [] }

        // Brace matching that ignores braces inside strings — a title holding one
        // would otherwise cut the object short.
        var depth = 0, inString = false, escaped = false
        var i = open.lowerBound
        while i < html.endIndex {
            let ch = html[i]
            if inString {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
            } else if ch == "\"" {
                inString = true
            } else if ch == "{" {
                depth += 1
            } else if ch == "}" {
                depth -= 1
                if depth == 0 {
                    let object = try? JSONSerialization.jsonObject(
                        with: Data(String(html[open.lowerBound...i]).utf8))
                    return ((object as? [String: Any])?["items"]
                            as? [[String: Any]]) ?? []
                }
            }
            i = html.index(after: i)
        }
        return []
    }

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
            let id = Clean.scalar(j["ID"])
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
