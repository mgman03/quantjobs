import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// When a posting was first seen and when it was last still listed.
///
/// The first date is the one the UI shows for boards that state no date of their
/// own. The last is only bookkeeping: it is what lets the scheduled fetch drop
/// postings that are long gone instead of carrying every key it has ever seen
/// forever.
///
/// Encoded as a two-element array rather than an object. This file holds one
/// entry per posting for every board — around nine thousand of them — and
/// spelling out `{"first":…,"last":…}` on each costs a few hundred kilobytes of
/// repeated key names on a file that travels over the network.
struct Sighting: Codable, Sendable, Equatable {
    var first: String
    var last: String

    init(first: String, last: String) {
        self.first = first
        self.last = last
    }

    init(from decoder: Decoder) throws {
        // The shape this file had before it recorded a last date: a bare string,
        // which was the first-seen date. Read rather than discarded, or turning
        // this on would date every posting already on disk to today.
        if let one = try? decoder.singleValueContainer().decode(String.self) {
            self.init(first: one, last: one)
            return
        }
        var c = try decoder.unkeyedContainer()
        let f = try c.decode(String.self)
        let l = try c.decodeIfPresent(String.self) ?? f
        self.init(first: f, last: l)
    }

    /// The date a posting was first seen, under either of its keys — the
    /// legacy one too, so the run after the key scheme changed does not
    /// re-date everything it already knew about.
    static func firstSeen(of job: Job, in store: [String: Sighting]) -> String? {
        (store[job.key] ?? store[job.legacyKey])?.first
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(first)
        try c.encode(last)
    }
}

/// The first-seen dates as the scheduled fetch knows them.
///
/// A posting has one date it was first advertised, not one per machine. Before
/// this, the Mac and the twice-daily fetch each kept their own `.seen.json`, so
/// the same Jane Street role read as three weeks old on the laptop and "found
/// today" on the phone — and the server's copy, living in a workspace that is
/// thrown away when the run ends, said "found today" on every single run.
///
/// So the fetch keeps the ledger on an orphan branch of the repository, one
/// force-pushed commit that carries no history of its own, and the app folds it
/// into its local map: earliest date wins, in both directions, so neither side
/// can make a posting look newer than it is.
enum SharedLedger {
    static let url =
        "https://raw.githubusercontent.com/mgman03/quantjobs/state/first-seen.json"

    /// Nothing here is worth an error message. A posting shows the date this
    /// machine knows if the network is down, which is what it did before.
    static func fetch() async -> [String: Sighting] {
        guard let data = try? await HTTP.data(url, retries: 1),
              let d = try? JSONDecoder().decode([String: Sighting].self, from: data)
        else { return [:] }
        return d
    }

    /// Earliest first-seen wins; latest last-seen wins.
    static func merge(_ incoming: [String: Sighting],
                      into store: inout [String: Sighting]) -> Int {
        var changed = 0
        for (key, theirs) in incoming {
            guard let ours = store[key] else {
                store[key] = theirs
                changed += 1
                continue
            }
            let merged = Sighting(first: min(ours.first, theirs.first),
                                  last: max(ours.last, theirs.last))
            if merged != ours {
                store[key] = merged
                changed += 1
            }
        }
        return changed
    }

    /// Drops postings last listed more than `days` ago.
    ///
    /// Only safe where a run covers every board: the app scrapes one category at
    /// a time, so "not in this run" there means "not in this category". Even on
    /// the server the rule is by date and not by absence, because a board that
    /// times out for one run must not cost its firm every date it has.
    static func pruned(_ store: [String: Sighting], days: Int,
                       now: Date = Date()) -> [String: Sighting] {
        let cutoff = Job.dateFormatter.string(
            from: now.addingTimeInterval(-Double(days) * 86_400))
        return store.filter { $0.value.last >= cutoff }
    }
}
