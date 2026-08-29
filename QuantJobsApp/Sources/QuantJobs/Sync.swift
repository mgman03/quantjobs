import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Marks and filters, the same here as on the phone.
//
// The other half of this — when a posting was first seen — travels through the
// repository, because it is public information about public job boards. These
// are not: they are what was applied to and what came back a rejection. So they
// go through the deployed page instead, which sits behind a password, into a KV
// namespace only that page can reach. See site/_worker.js for the server end.
//
// The document is small enough to send whole. What is *not* whole is the merge:
// each posting carries the instant it was last edited and the newest edit wins,
// milestones excepted, which are unioned. Two clients that both read at
// breakfast and write at lunch therefore keep each other's marks — the failure
// this is built to avoid is a phone that quietly deletes a month of history.

/// One posting's marks, in the shape the page and the worker use.
///
/// Deliberately not `TrackedJob`: that carries a whole `Job` snapshot so an
/// entry survives the board delisting it, and the page has no use for a copy of
/// every field of every posting it is already showing.
struct SyncMarks: Codable, Sendable {
    var saved = false
    var hidden = false
    var note = ""
    var milestones: [SyncStep] = []
    /// ISO instant. What decides which side is newer.
    var updated = ""
    /// The posting itself, so a client that cannot see it on any board can
    /// still show the application.
    ///
    /// The page is built on a runner with no marks of its own, and a firm you
    /// have switched off is never fetched at all — so without this an Amazon
    /// interview lived in the store, arrived in the browser, and was dropped on
    /// the floor for want of a row to land on. The app has always kept this
    /// snapshot for the same reason: an application outlives the posting.
    ///
    /// Optional because a document written by an older client will not have it,
    /// and a mark with no posting is still a mark worth keeping.
    var job: Job?
}

/// A step in the shape the page writes into its rows.
///
/// `stage` is the short label — "OA", not "assessment" — because that is what
/// the page puts in the table and reads back out of it. Translating happens
/// here rather than there, on the side that has the enum.
struct SyncStep: Codable, Sendable {
    var stage: String
    var date: String
    var done: String?
}

struct SyncDoc: Codable, Sendable {
    var rev: Int?
    var tracked: [String: SyncMarks] = [:]
    var filters: [String: String]?
    var filtersUpdated: String?
}

/// Where to sync and how to get in.
///
/// A file in the config folder rather than a settings pane, so it can be written
/// in one command and so the CLI shares it. It sits next to `.tracked.json` and
/// is exactly as private, which is why it is gitignored.
struct SyncConfig: Codable, Sendable {
    var url: String
    var password: String
    /// Left out means on. Present and false turns syncing off without deleting
    /// the password.
    var enabled: Bool?

    var isOn: Bool { enabled ?? true }

    /// The worker's endpoint, however the URL was written down.
    var endpoint: String {
        var base = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix("/state") { return base }
        return base + "/state"
    }

    var authorization: String {
        // The username is ignored by the worker; there is one page and one person.
        "Basic " + Data("quantjobs:\(password)".utf8).base64EncodedString()
    }
}

enum StateSync {

    static func pull(_ c: SyncConfig) async throws -> SyncDoc {
        let raw = try await HTTP.data(c.endpoint, headers: [
            "Authorization": c.authorization,
            "Accept": "application/json",
        ], retries: 1)
        return try decode(raw)
    }

    /// Sends what this machine knows and returns what the server made of it.
    static func push(_ doc: SyncDoc, to c: SyncConfig) async throws -> SyncDoc {
        let body = try JSONEncoder().encode(doc)
        let raw = try await HTTP.data(c.endpoint, method: "PUT", body: body,
                                      headers: [
            "Authorization": c.authorization,
            "Accept": "application/json",
        ], retries: 1)
        return try decode(raw)
    }

    private static func decode(_ raw: Data) throws -> SyncDoc {
        do {
            return try JSONDecoder().decode(SyncDoc.self, from: raw)
        } catch {
            throw FetchError.badPayload("the sync endpoint did not answer with a "
                                        + "state document")
        }
    }
}

// MARK: - Translating

extension SyncStep {
    /// Nil for a stage this version does not know, rather than a guess — a
    /// mystery step is better dropped than recorded as the wrong one.
    var milestone: Milestone? {
        guard let s = Stage.allCases.first(where: { $0.short == stage })
                ?? Stage(rawValue: stage.lowercased())
        else { return nil }
        guard !date.isEmpty else { return nil }
        let sat = (done?.isEmpty ?? true) ? nil : done
        return Milestone(stage: s, date: date, done: sat)
    }

    init(_ m: Milestone) {
        self.init(stage: m.stage.short, date: m.date, done: m.done)
    }
}

extension SyncMarks {
    init(_ t: TrackedJob) {
        self.init(saved: t.saved, hidden: t.hidden, note: t.note,
                  milestones: t.milestones.map(SyncStep.init),
                  updated: t.syncStamp, job: t.job)
    }

    /// Everything except the history, which is unioned by the caller.
    func applied(to t: TrackedJob) -> TrackedJob {
        var out = t
        out.saved = saved
        out.hidden = hidden
        out.note = note
        out.touched = updated
        return out
    }

    var steps: [Milestone] { milestones.compactMap(\.milestone) }
}

/// The union the merge needs: same stage and same date is the same step, and a
/// sat date known to either side is kept.
///
/// A step is a history rather than a value — the Mac holding "applied 3 June,
/// OA 20 June" and the phone adding an interview has to end up with three, not
/// with whichever side was touched last. The worker does this too; both ends
/// need it, because either can be the one that merges first.
func unionMilestones(_ a: [Milestone], _ b: [Milestone]) -> [Milestone] {
    var byID: [String: Milestone] = [:]
    for m in a + b {
        if var had = byID[m.id] {
            had.done = had.done ?? m.done
            byID[m.id] = had
        } else {
            byID[m.id] = m
        }
    }
    return byID.values.sorted {
        $0.date == $1.date ? $0.stage.order < $1.stage.order : $0.date < $1.date
    }
}
