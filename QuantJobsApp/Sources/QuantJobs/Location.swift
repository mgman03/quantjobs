import Foundation

/// One resolved place. A posting can name several.
struct Place: Hashable, Sendable, Codable {
    var city = ""
    var region = ""
    var regionAbbr = ""
    var country = ""          // ISO2
    var countryName = ""
    var continent = ""

    /// "Santa Clara, CA" / "London, GB"
    var label: String {
        let tail = regionAbbr.isEmpty ? country : regionAbbr
        if city.isEmpty { return tail }
        return tail.isEmpty ? city : "\(city), \(tail)"
    }
}

/// The gazetteer, read from the same `locations.json` the Python CLI uses so
/// the two can't drift on how a location string is read.
struct Gazetteer: Sendable {

    struct CountryInfo: Sendable { var name: String; var continent: String }
    struct RegionInfo: Sendable { var country: String; var name: String; var abbr: String }
    struct CityInfo: Sendable { var name: String; var country: String }

    var countries: [String: CountryInfo] = [:]
    var countryAliases: [String: String] = [:]
    var regions: [String: RegionInfo] = [:]
    var cities: [String: CityInfo] = [:]
    var remoteTerms: Set<String> = []
    var noiseTerms: Set<String> = []

    static let empty = Gazetteer()

    init() {}

    init(data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FetchError.badPayload("locations.json is not an object")
        }
        for (code, raw) in root["countries"] as? [String: [String: Any]] ?? [:] {
            countries[code] = CountryInfo(name: raw["name"] as? String ?? "",
                                          continent: raw["continent"] as? String ?? "")
        }
        countryAliases = root["countryAliases"] as? [String: String] ?? [:]
        for (key, raw) in root["regions"] as? [String: [String: Any]] ?? [:] {
            regions[key] = RegionInfo(country: raw["country"] as? String ?? "",
                                      name: raw["name"] as? String ?? "",
                                      abbr: raw["abbr"] as? String ?? "")
        }
        for (key, raw) in root["cities"] as? [String: [String: Any]] ?? [:] {
            cities[key] = CityInfo(name: raw["name"] as? String ?? "",
                                   country: raw["country"] as? String ?? "")
        }
        remoteTerms = Set(root["remoteTerms"] as? [String] ?? [])
        noiseTerms = Set(root["noiseTerms"] as? [String] ?? [])
    }
}

/// Turns a board's free-text location into structured places.
///
/// A direct port of `parse_locations` in quantjobs.py — the ordering rules in
/// `parseGroup` in particular are load-bearing and must stay in step.
enum LocationParser {

    nonisolated(unsafe) static var gazetteer = Gazetteer.empty

    // Commas are absent on purpose: inside one group they separate city from
    // region from country.
    private static let placeSplit = try! NSRegularExpression(
        pattern: #"\s*[;|]\s*|\s*/\s*|\s+[-–]\s+|\s+\bor\b\s+|\s+\band\b\s+"#,
        options: [.caseInsensitive])
    private static let parens = try! NSRegularExpression(pattern: #"\([^)]*\)"#)
    private static let whitespace = try! NSRegularExpression(pattern: #"\s+"#)
    // Greenhouse writes "3 Locations" when a posting spans several offices.
    private static let countOnly = try! NSRegularExpression(
        pattern: #"^\d+\s+locations?$"#, options: [.caseInsensitive])

    static func parse(_ raw: String?) -> [Place] {
        let g = gazetteer
        guard let raw, !raw.isEmpty else { return [] }

        var s = replace(parens, in: raw, with: " ")
        s = replace(whitespace, in: s, with: " ")
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " ,-"))
        guard !s.isEmpty else { return [] }

        let low = s.lowercased()
        for term in g.remoteTerms
        where low == term || low.hasPrefix(term + " ") || low.hasPrefix(term + ",") {
            return [Place(city: "Remote", continent: "Remote")]
        }

        var out: [Place] = []
        var seen = Set<String>()
        for group in split(s) {
            for place in parseGroup(group, g) {
                let key = "\(place.city.lowercased())|\(place.country)"
                if seen.insert(key).inserted { out.append(place) }
            }
        }

        // Once something real is identified, drop the leftovers a split
        // produces — office codes like "UK2", and the "Remote" half of
        // "United States - Remote", which the country already covers.
        if out.contains(where: { !$0.country.isEmpty }) {
            out = out.filter { !$0.country.isEmpty }
        }
        return out
    }

    static func format(_ places: [Place], raw: String = "") -> String {
        guard let first = places.first else { return raw }
        let label = first.label
        return places.count > 1 ? "\(label) +\(places.count - 1)" : label
    }

    // MARK: - One comma-separated group

    private static func parseGroup(_ group: String, _ g: Gazetteer) -> [Place] {
        let parts = group.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var country: String? = nil
        var region = "", regionAbbr = ""
        var weakRegion: Gazetteer.RegionInfo? = nil
        var remote = false
        var cities: [Gazetteer.CityInfo] = []
        var unknown: [String] = []

        for part in parts {
            let key = part.lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            if key.isEmpty || g.noiseTerms.contains(key) || matches(countOnly, key) {
                continue
            }
            if g.remoteTerms.contains(key) { remote = true; continue }

            // Cities first: plenty of US state names are also city names.
            if let city = g.cities[key] { cities.append(city); continue }

            // Regions before countries: two-letter state codes collide with
            // country codes (IL is Illinois and Israel, CA California and
            // Canada), and getting this backwards sent Chicago to Asia.
            if let r = g.regions[key] {
                let agrees = country == r.country
                    || (country == nil
                        && (cities.isEmpty || cities.contains { $0.country == r.country }))
                if agrees {
                    region = r.name
                    regionAbbr = r.abbr
                    country = country ?? r.country
                    continue
                }
                if g.countryAliases[key] == nil { weakRegion = r; continue }
            }

            if country == nil, let code = g.countryAliases[key] {
                country = code
                continue
            }
            unknown.append(part)
        }

        // "Dublin, OH": nothing corroborated Ohio, but no country was named
        // either, so the state is still the best evidence available.
        if country == nil, let weak = weakRegion {
            country = weak.country
            region = weak.name
            regionAbbr = weak.abbr
        }

        // An explicit country overrides a city's own only when it doesn't
        // contradict it, so "Amsterdam, Netherlands, London, United Kingdom"
        // keeps both.
        let forced: String? = {
            guard let country else { return nil }
            return cities.count <= 1 || cities.allSatisfy({ $0.country == country })
                ? country : nil
        }()

        var out: [Place] = []
        for city in cities {
            let code = forced ?? city.country
            let keep = code == country
            out.append(place(city: city.name, region: keep ? region : "",
                             abbr: keep ? regionAbbr : "", country: code, g))
        }

        if out.isEmpty {
            // "United States - Remote" is a US role, not a placeless one; only
            // fall back to the bare Remote bucket when no country was named.
            if remote && unknown.isEmpty {
                if let country {
                    return [place(city: "Remote", region: region, abbr: regionAbbr,
                                  country: country, g)]
                }
                return [Place(city: "Remote", continent: "Remote")]
            }
            let name = unknown.first
                ?? (region.isEmpty ? (country.flatMap { g.countries[$0]?.name } ?? "")
                                   : region)
            if !name.isEmpty || country != nil {
                out.append(place(city: name, region: region, abbr: regionAbbr,
                                 country: country ?? "", g))
            }
        }
        return out
    }

    private static func place(city: String, region: String, abbr: String,
                              country: String, _ g: Gazetteer) -> Place {
        let info = g.countries[country]
        return Place(city: city, region: region, regionAbbr: abbr,
                     country: country, countryName: info?.name ?? "",
                     continent: info?.continent.isEmpty == false
                         ? info!.continent : "Other")
    }

    // MARK: - Regex helpers

    private static func replace(_ rx: NSRegularExpression, in s: String,
                                with template: String) -> String {
        rx.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s),
                                    withTemplate: template)
    }

    private static func matches(_ rx: NSRegularExpression, _ s: String) -> Bool {
        rx.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// Splits on the separators that mean "another place entirely".
    private static func split(_ s: String) -> [String] {
        let ns = s as NSString
        let full = NSRange(location: 0, length: ns.length)
        var pieces: [String] = []
        var cursor = 0
        for m in placeSplit.matches(in: s, range: full) {
            if m.range.location > cursor {
                pieces.append(ns.substring(with: NSRange(location: cursor,
                                                        length: m.range.location - cursor)))
            }
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length {
            pieces.append(ns.substring(from: cursor))
        }
        return pieces.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
