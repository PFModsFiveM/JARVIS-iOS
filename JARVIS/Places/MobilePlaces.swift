import Foundation

/// What kind of place somewhere is. Matches the PC's `PlaceCategory` name for name.
enum MobilePlaceCategory: String, Codable, CaseIterable {
    case unknown = "Unknown"
    case home = "Home"
    case study = "Study"
    case work = "Work"
    case other = "Other"

    /// Nothing is inferred from a category; it only ever softens how a place is said.
    var word: String {
        switch self {
        case .unknown: return ""
        case .home: return "home"
        case .study: return "where you study"
        case .work: return "where you work"
        case .other: return ""
        }
    }
}

/// A place the owner goes, as this phone holds it - programme §1B.
///
/// The PC learns places; this phone is told about them. That split is the whole design: the PC has
/// the months of history and the arithmetic, and the phone is the thing that is actually there. A
/// phone that held coordinates and no places would know where it was to six decimal places and
/// still be unable to say "you're at home", which is the one thing the owner asks.
struct MobilePlace: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let aliases: [String]
    let category: MobilePlaceCategory
    let latitude: Double
    let longitude: Double
    let radius: Double
    let confidence: Double
    let visits: Int
    let named: Bool
    let revision: Int64
    let firstSeen: Date
    let lastSeen: Date
    let updated: Date

    /// When the owner usually gets here, in minutes from midnight, when a routine says so.
    let arrives: Int?

    /// When they usually leave.
    let leaves: Int?

    /// Every name it answers to, canonical first.
    var names: [String] {
        guard !name.isEmpty else { return aliases }

        return [name] + aliases.filter { $0.caseInsensitiveCompare(name) != .orderedSame }
    }

    /// Whether this place answers to a word the owner just said.
    func called(_ said: String) -> Bool {
        let want = said.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !want.isEmpty else { return false }

        return names.contains { $0.caseInsensitiveCompare(want) == .orderedSame }
    }

    /// What it may be called out loud. Never a coordinate.
    var spoken: String {
        if !name.isEmpty { return name }

        return visits == 1 ? "somewhere you have been once" : "somewhere you have been \(visits) times"
    }

    /// One row as the PC's `places.pull` sends it, or nil when it is not one.
    init?(_ row: [String: String]) {
        guard let id = row["id"], !id.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }

        self.id = id.trimmingCharacters(in: .whitespaces)
        name = row["name"] ?? ""
        aliases = (row["aliases"] ?? "").split(separator: "\u{1f}").map(String.init)
        category = MobilePlaceCategory(rawValue: row["category"] ?? "") ?? .unknown
        latitude = MobilePlace.number(row["lat"])
        longitude = MobilePlace.number(row["lon"])
        radius = MobilePlace.number(row["radius"], or: 80)
        confidence = MobilePlace.number(row["confidence"])
        visits = Int(MobilePlace.number(row["visits"]))
        named = row["named"] == "1"
        revision = Int64(MobilePlace.number(row["revision"]))
        firstSeen = MobilePlace.moment(row["firstSeen"])
        lastSeen = MobilePlace.moment(row["lastSeen"])
        updated = MobilePlace.moment(row["updated"])
        arrives = row["arrives"].flatMap { Int($0) }
        leaves = row["leaves"].flatMap { Int($0) }
    }

    /// Whether this row is the PC saying to forget the place.
    static func gone(_ row: [String: String]) -> String? {
        guard row["gone"] == "1", let id = row["id"], !id.isEmpty else { return nil }

        return id
    }

    private static func number(_ text: String?, or fallback: Double = 0) -> Double {
        guard let text, let value = Double(text) else { return fallback }

        return value
    }

    private static func moment(_ text: String?) -> Date {
        guard let text, let seconds = Double(text) else { return .distantPast }

        return Date(timeIntervalSince1970: seconds)
    }
}

/// The protocol's constants, matching the PC's `PlaceProtocol`.
enum MobilePlaceProtocol {
    static let schema = 1

    /// The most places this phone keeps, whatever the PC sends.
    ///
    /// A cap of its own rather than trusting the sender, because the two caps answer different
    /// questions. The PC's bounds what it is willing to disclose; this one bounds what this device
    /// is willing to carry out of the house. They happen to be the same number today and there is
    /// no reason they must stay that way.
    static let most = 32
}

/// The places this phone holds, and the cursor that keeps the sync incremental - programme §1C.
///
/// Stored with `.completeUntilFirstUserAuthentication` rather than `.complete`: the file has to be
/// readable by a background location update that arrives while the phone is locked in a pocket,
/// which is exactly when the owner is arriving somewhere and the answer matters. `.complete` would
/// make the phone unable to name where it was until it was next unlocked, which defeats the point
/// of holding places locally at all. It is still unreadable before the first unlock after a reboot,
/// and still encrypted at rest.
@MainActor
final class MobilePlaceBook: ObservableObject {
    static let shared = MobilePlaceBook()

    @Published private(set) var places: [MobilePlace] = []

    /// The highest place revision this phone has applied.
    @Published private(set) var revision: Int64 = 0

    /// When a pull last completed, for the sync detail page.
    @Published private(set) var syncedAt: Date?

    /// Why the last pull did not work, if it did not.
    @Published private(set) var problem: String?

    private var loaded = false

    private init() { load() }

    /// The place a word picks out, by name or alias.
    func calling(_ said: String) -> MobilePlace? {
        places.first { $0.called(said) }
    }

    func place(_ id: String) -> MobilePlace? {
        places.first { $0.id == id }
    }

    /// The one the owner lives in, when they have said which it is.
    var home: MobilePlace? {
        places.first { $0.category == .home } ?? calling("home")
    }

    /// Applies one batch from `places.pull`.
    ///
    /// Idempotent and order-tolerant. A row at or below a revision already held is ignored rather
    /// than reapplied, so a replayed batch costs nothing; a tombstone removes the place whatever
    /// else the batch says; and the cursor only ever moves forward, so a batch that arrives twice
    /// cannot rewind it and cause a resend.
    @discardableResult
    func apply(_ rows: [[String: String]], through: Int64? = nil, at moment: Date = Date()) -> Int {
        load()

        var changed = 0

        for row in rows {
            if let id = MobilePlace.gone(row) {
                let before = places.count
                places.removeAll { $0.id == id }
                if places.count != before { changed += 1 }

                if let revision = row["revision"].flatMap({ Int64($0) }) {
                    self.revision = max(self.revision, revision)
                }

                continue
            }

            guard let place = MobilePlace(row) else { continue }

            if let held = places.first(where: { $0.id == place.id }), held.revision >= place.revision {
                continue
            }

            places.removeAll { $0.id == place.id }
            places.append(place)
            revision = max(revision, place.revision)
            changed += 1
        }

        trim()

        if let through { revision = max(revision, through) }

        syncedAt = moment
        problem = nil
        save()

        return changed
    }

    /// Records that a pull did not work, without moving the cursor.
    func failed(_ because: String) {
        problem = because
    }

    /// A failure in words the owner could act on, and never a stack trace.
    nonisolated static func because(_ error: Error) -> String {
        if let bridge = error as? BridgeError { return bridge.localizedDescription }

        return (error as NSError).localizedDescription
    }

    /// Forgets everything. For the owner turning the feature off, and for tests.
    func forget() {
        places = []
        revision = 0
        syncedAt = nil
        problem = nil
        save()
    }

    /// Keeps the most useful `MobilePlaceProtocol.most`, by the same argument the PC's subset uses.
    private func trim() {
        guard places.count > MobilePlaceProtocol.most else {
            places.sort { Self.before($0, $1) }
            return
        }

        places.sort { Self.before($0, $1) }
        places = Array(places.prefix(MobilePlaceProtocol.most))
    }

    /// Which of two places is more worth keeping. Deterministic down to the id.
    private static func before(_ left: MobilePlace, _ right: MobilePlace) -> Bool {
        if left.named != right.named { return left.named }
        if left.lastSeen != right.lastSeen { return left.lastSeen > right.lastSeen }
        if left.visits != right.visits { return left.visits > right.visits }

        return left.id < right.id
    }

    // MARK: on disk

    private struct Stored: Codable {
        var schema: Int
        var revision: Int64
        var places: [MobilePlace]
        var syncedAt: Date?
    }

    private static var file: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        return folder.appendingPathComponent("jarvis-places.json")
    }

    private func load() {
        guard !loaded else { return }

        loaded = true

        guard let data = try? Data(contentsOf: Self.file),
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return }

        // A file from a schema this build does not know is left alone rather than read wrongly or
        // deleted: the owner's places are not worth guessing at, and a newer build will want it.
        guard stored.schema <= MobilePlaceProtocol.schema else { return }

        places = stored.places
        revision = stored.revision
        syncedAt = stored.syncedAt
    }

    private func save() {
        let stored = Stored(
            schema: MobilePlaceProtocol.schema, revision: revision, places: places, syncedAt: syncedAt)

        guard let data = try? JSONEncoder().encode(stored) else { return }

        try? data.write(to: Self.file, options: [.atomic])

        try? (Self.file as NSURL).setResourceValue(
            URLFileProtection.completeUntilFirstUserAuthentication,
            forKey: .fileProtectionKey)
    }
}

/// The learned patterns this phone holds - programme §2B.
///
/// PC-PRIME stays the learner and this is told the conclusions. Separate from the place book
/// because the two have different lifetimes: places are facts that change rarely, and a routine is
/// a conclusion that can be revised by any day's evidence. Sharing one store would mean a
/// re-learned routine rewriting a place's row.
@MainActor
final class MobileRoutineBook: ObservableObject {
    static let shared = MobileRoutineBook()

    /// The most patterns kept, matching the PC's `RoutineSubset.MostOnMobile`.
    static let most = 24

    @Published private(set) var routines: [MobileRoutine] = []
    @Published private(set) var revision: Int64 = 0
    @Published private(set) var learnedAt: Date?

    private var loaded = false

    private init() { load() }

    /// Replaces the held set.
    ///
    /// A whole set rather than a delta, because a routine that has stopped being true is published
    /// by its absence: there is no tombstone for a conclusion the learner no longer draws, and a
    /// delta would leave this phone asserting a pattern the PC has given up on. The set is two
    /// dozen rows, so sending all of them is cheaper than the bookkeeping to send fewer.
    func replace(_ rows: [[String: String]], revision: Int64, at moment: Date = Date()) {
        load()

        let read = rows.compactMap(MobileRoutine.init)

        routines = Array(read
            .sorted { left, right in
                if left.confidence != right.confidence { return left.confidence > right.confidence }
                if left.samples != right.samples { return left.samples > right.samples }
                return left.id < right.id
            }
            .prefix(Self.most))

        self.revision = max(self.revision, revision)
        learnedAt = moment
        save()
    }

    /// The patterns about one place, by any of its names.
    func about(_ place: MobilePlace) -> [MobileRoutine] {
        routines.filter { routine in place.names.contains { $0.caseInsensitiveCompare(routine.subject) == .orderedSame } }
    }

    func forget() {
        routines = []
        revision = 0
        learnedAt = nil
        save()
    }

    private struct Stored: Codable {
        var schema: Int
        var revision: Int64
        var routines: [MobileRoutine]
        var learnedAt: Date?
    }

    private static var file: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        return folder.appendingPathComponent("jarvis-routines.json")
    }

    private func load() {
        guard !loaded else { return }

        loaded = true

        guard let data = try? Data(contentsOf: Self.file),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              stored.schema <= MobilePlaceProtocol.schema
        else { return }

        routines = stored.routines
        revision = stored.revision
        learnedAt = stored.learnedAt
    }

    private func save() {
        let stored = Stored(
            schema: MobilePlaceProtocol.schema, revision: revision, routines: routines, learnedAt: learnedAt)

        guard let data = try? JSONEncoder().encode(stored) else { return }

        try? data.write(to: Self.file, options: [.atomic])

        // The same protection as the places, and for the same reason: a routine names a place.
        try? (Self.file as NSURL).setResourceValue(
            URLFileProtection.completeUntilFirstUserAuthentication,
            forKey: .fileProtectionKey)
    }
}
