import Foundation

/// Whether the owner has heard a result. The same six states as the PC's `ResultDelivery`.
///
/// Named identically on purpose: this is one mechanism with two halves, and a phone that called
/// the states something else would be a phone whose logs could not be read against the PC's.
enum MobileDeliveryState: String, Codable, Equatable {
    /// The work is still going.
    case notReady = "NotReady"
    /// There is a result and nobody has delivered it.
    case ready = "Ready"
    /// A node has claimed it and is delivering it.
    case deliveryPending = "DeliveryPending"
    /// Somebody delivered it and said so. Terminal.
    case delivered = "Delivered"
    /// Handed to a transport that never acknowledged it. Neither delivered nor safe to repeat.
    case deliveryUnknown = "DeliveryUnknown"
    /// Too old to be worth saying.
    case expired = "Expired"

    /// Whether this phone may still say it.
    var sayable: Bool { self == .ready }

    /// Whether it is settled, one way or another, and must never be said again.
    var settled: Bool {
        self == .delivered || self == .deliveryUnknown || self == .expired
    }
}

/// One result, and what this phone knows about whether it reached the owner.
struct MobileResult: Codable, Equatable, Identifiable {
    let id: String
    let turn: String
    let conversation: String
    let task: String?
    let state: MobileDeliveryState
    /// Which node delivered it, once somebody did.
    let by: String?
    let revision: Int64
    /// What the PC said about it, in words, for the history screen.
    let because: String

    /// Whether this phone was the one that said it.
    func mine(_ node: String) -> Bool {
        by?.caseInsensitiveCompare(node) == .orderedSame
    }
}

/// What the phone has itself said, so it does not repeat itself with the PC unreachable.
///
/// Separate from what the PC told it, and that separation is the point. The PC's record is
/// authoritative about every node; this is the only record that exists while the PC is off, and a
/// phone that merged the two would lose the distinction between "nobody has said this" and "I have
/// no idea whether anybody has said this".
struct SpokenHere: Codable, Equatable {
    var resultId: String
    var at: Date
}

/// Whether the owner has already heard something - priority §1D.
///
/// The hole this fills, from the owner's side: they ask the phone to open Blender, put the phone in
/// a pocket, the PC opens it and says so out loud, and then the phone comes back. Without this the
/// phone has a turn it believes it owns and an answer it has never given, so it gives it - and the
/// owner is told twice about one thing, by two devices, which is the single most obviously broken
/// behaviour an assistant with two bodies can have.
///
/// Bounded and durable, because the case that matters is a phone that was off overnight.
@MainActor
final class MobileDelivery: ObservableObject {
    static let shared = MobileDelivery()

    /// How many results are remembered.
    static let keep = 120

    /// How long a settled result is worth remembering.
    ///
    /// Two days, matching the PC's ledger. Long enough that a phone which was off overnight still
    /// learns it must not repeat yesterday's answer, which is the entire reason this is on disk.
    static let keepFor: TimeInterval = 60 * 60 * 24 * 2

    /// What the PC has told this phone about each result.
    @Published private(set) var results: [MobileResult] = []

    /// How far through the PC's ledger this phone has read.
    @Published private(set) var revision: Int64 = 0

    /// What this phone itself has said, which is all it knows while the PC is away.
    @Published private(set) var spoken: [SpokenHere] = []

    /// Why the last attempt to catch up failed, for the diagnostic.
    @Published private(set) var failed: String?

    private let store: URL?

    init(store: URL? = MobileDelivery.defaultStore()) {
        self.store = store
        load()
    }

    // MARK: - what the PC says

    /// Applies rows from `delivery.pull`, forward only.
    ///
    /// Idempotent by revision, like every other store here: the same batch applied twice leaves the
    /// same state, which is what makes a retry after a dropped acknowledgement safe.
    func apply(_ rows: [MobileResult], through: Int64) {
        guard through >= revision || !rows.isEmpty else { return }

        var held = Dictionary(uniqueKeysWithValues: results.map { ($0.id, $0) })

        for row in rows {
            // A row with a revision no higher than the one held is a replay. Applying it would
            // undo a newer state this phone has already been told about.
            if let already = held[row.id], already.revision >= row.revision { continue }

            held[row.id] = row
        }

        results = Array(held.values).sorted { $0.revision > $1.revision }
        revision = max(revision, through)
        failed = nil

        trim()
        save()
    }

    /// Records that catching up did not work, without losing what is already known.
    func couldNotCatchUp(_ why: String) {
        failed = why
    }

    // MARK: - the question that matters

    /// Whether this phone may say a result out loud.
    ///
    /// Three answers rather than two, and the third is the one worth having. `.yes` means nobody
    /// has said it; `.no` means somebody has, or it is too old; `.unknown` means this phone cannot
    /// reach the PC and has no record of saying it itself - at which point the honest thing is to
    /// say it, because an owner who hears nothing is worse served than one who hears something
    /// twice, and the PC's ledger will record the duplicate so it can be measured.
    func maySay(_ resultId: String, node: String) -> MaySay {
        if spoken.contains(where: { $0.resultId == resultId }) {
            return .no("this phone already said it")
        }

        guard let held = results.first(where: { $0.id == resultId }) else {
            return .unknown("the PC has not said anything about this result")
        }

        if held.state == .delivered {
            return held.mine(node)
                ? .no("this phone delivered it")
                : .no("\(held.by ?? "another device") delivered it")
        }

        if held.state.settled {
            return .no(held.because)
        }

        if held.state == .deliveryPending {
            return .no("another device is delivering it")
        }

        return held.state.sayable ? .yes : .no(held.because)
    }

    /// What this phone has decided about saying something.
    enum MaySay: Equatable {
        /// Nobody has said it, and the PC agrees.
        case yes
        /// Somebody has, or it is not worth saying. Do not say it.
        case no(String)
        /// The PC cannot be reached and this phone has not said it. Say it, and report later.
        case unknown(String)

        private var isNo: Bool {
            if case .no = self { return true }
            return false
        }

        /// Whether it should actually be said now.
        ///
        /// Both `.yes` and `.unknown`, deliberately. The alternative to speaking under uncertainty
        /// is an owner who asked a question and got silence, which is the worse failure.
        var speak: Bool { !isNo }

        var because: String {
            switch self {
            case .yes: return "nobody has said it"
            case .no(let why), .unknown(let why): return why
            }
        }
    }

    /// Records that this phone said something, so it does not say it again.
    ///
    /// Written before the PC is told, because the order matters: a phone that reported first and
    /// crashed before recording would say it again on relaunch.
    func said(_ resultId: String) {
        guard !spoken.contains(where: { $0.resultId == resultId }) else { return }

        spoken.append(SpokenHere(resultId: resultId, at: Date()))
        trim()
        save()
    }

    /// Everything this phone said while it could not reach the PC, to report on reconnection.
    func unreported() -> [String] {
        spoken
            .map(\.resultId)
            .filter { id in
                guard let held = results.first(where: { $0.id == id }) else { return true }
                return held.state != .delivered
            }
    }

    /// The PC has accepted a report, so it no longer needs sending.
    func reported(_ resultId: String, by node: String) {
        guard let at = results.firstIndex(where: { $0.id == resultId }) else { return }

        let held = results[at]

        results[at] = MobileResult(
            id: held.id, turn: held.turn, conversation: held.conversation, task: held.task,
            state: .delivered, by: node, revision: held.revision,
            because: "this phone delivered it")

        save()
    }

    /// What a turn came to, for the history screen.
    func forTurn(_ turn: String) -> [MobileResult] {
        results.filter { $0.turn == turn }.sorted { $0.revision > $1.revision }
    }

    /// Forgets everything. Pairing again, or the owner clearing the app.
    func forget() {
        results = []
        spoken = []
        revision = 0
        failed = nil
        save()
    }

    // MARK: - storage

    private func trim() {
        let cutoff = Date().addingTimeInterval(-MobileDelivery.keepFor)

        spoken = spoken.filter { $0.at > cutoff }

        if spoken.count > MobileDelivery.keep {
            spoken = Array(spoken.suffix(MobileDelivery.keep))
        }

        if results.count > MobileDelivery.keep {
            // Settled ones go first: an outstanding result is the one this phone might still have
            // to do something about.
            let settled = results.filter { $0.state.settled }.sorted { $0.revision < $1.revision }
            let drop = Set(settled.prefix(results.count - MobileDelivery.keep).map(\.id))

            results = results.filter { !drop.contains($0.id) }
        }
    }

    private struct Stored: Codable {
        var revision: Int64
        var results: [MobileResult]
        var spoken: [SpokenHere]
    }

    nonisolated private static func defaultStore() -> URL? {
        guard let folder = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }

        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        return folder.appendingPathComponent("delivery.json")
    }

    private func load() {
        guard let store, let data = try? Data(contentsOf: store) else { return }
        guard let held = try? JSONDecoder().decode(Stored.self, from: data) else { return }

        revision = held.revision
        results = held.results
        spoken = held.spoken
    }

    private func save() {
        guard let store else { return }

        let held = Stored(revision: revision, results: results, spoken: spoken)

        guard let data = try? JSONEncoder().encode(held) else { return }

        do {
            try data.write(to: store, options: .atomic)

            // The same protection the places store uses, and for the same reason: a background
            // delivery while the phone is locked has to be able to check this, so .complete would
            // make the file unreadable at exactly the moment it is needed.
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: store.path)
        } catch {
            failed = "could not save what has been delivered"
        }
    }
}
