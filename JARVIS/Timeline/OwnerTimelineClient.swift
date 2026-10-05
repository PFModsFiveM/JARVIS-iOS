import CryptoKit
import Foundation

/// One observation this phone made about its owner - programme §5 and §6.
///
/// The same shape the PC files, field for field, because there is one timeline and this is a node
/// of it rather than a client of it. The phone sees what the PC cannot: where its owner is, what
/// its own battery is doing, which network it is on, and every conversation held away from the
/// desk. None of that reaches the machine that can reason about it unless something carries it.
///
/// **The id is derived from the observation, never generated.** A queue flushed twice - a lost
/// acknowledgement, a reconnect, a relaunch - must file one event, and that is guaranteed here
/// rather than hoped for at the far end.
struct OwnerEvent: Codable, Equatable, Identifiable {
    let id: String
    let type: String
    let category: String
    let occurred: Date
    let observed: Date
    let payload: [String: String]
    let confidence: Double
    let sensitivity: String
    let schema: Int

    /// Which clock this phone was on when it observed this.
    ///
    /// The PC learns times of day from these events - when the owner leaves, when they get home -
    /// and a time of day is a statement about a wall clock, not about an instant. Sending the
    /// instant alone made every learned time wrong by the owner's summer offset, because
    /// `ISO8601DateFormatter` defaults to GMT and so every arrival this phone has ever filed
    /// arrived stamped as if the owner lived in UTC.
    let zone: String

    /// The shape this build writes. Must match the PC's `OwnerTimeline.Schema`.
    static let currentSchema = 1

    /// Spelled out rather than synthesised, because this type has a custom decoder and a reader
    /// should not have to know which of the two Swift still generates.
    enum CodingKeys: String, CodingKey {
        case id, type, category, occurred, observed, payload, confidence, sensitivity, schema, zone
    }

    init(
        id: String,
        type: String,
        category: OwnerEventCategory,
        occurred: Date,
        observed: Date = Date(),
        payload: [String: String] = [:],
        confidence: Double = 1,
        sensitivity: OwnerEventSensitivity = .medium,
        zone: String = TimeZone.current.identifier
    ) {
        self.id = id
        self.type = type
        self.category = category.rawValue
        self.occurred = occurred
        self.observed = observed
        self.payload = payload
        self.confidence = confidence
        self.sensitivity = sensitivity.rawValue
        self.zone = zone
        schema = Self.currentSchema
    }

    /// The row as `timeline.push` carries it.
    var body: [String: Any] {
        [
            "id": id,
            "type": type,
            "category": category,
            "occurred": OwnerEvent.stamp(occurred),
            "observed": OwnerEvent.stamp(observed),
            "payload": payload,
            "confidence": confidence,
            "sensitivity": sensitivity,
            "schema": schema,
            "zone": zone
        ]
    }

    /// One row as the PC sends it back, or nil when it is not one.
    init?(_ row: [String: Any]) {
        guard let id = row["id"] as? String, !id.isEmpty,
              let type = row["type"] as? String, !type.isEmpty
        else { return nil }

        self.id = id
        self.type = type
        category = row["category"] as? String ?? OwnerEventCategory.unknown.rawValue
        occurred = OwnerEvent.date(row["occurred"]) ?? Date()
        observed = OwnerEvent.date(row["observed"]) ?? occurred
        payload = (row["payload"] as? [String: Any] ?? [:]).reduce(into: [:]) { into, pair in
            into[pair.key] = pair.value as? String ?? String(describing: pair.value)
        }
        confidence = (row["confidence"] as? NSNumber)?.doubleValue ?? 1
        sensitivity = row["sensitivity"] as? String ?? OwnerEventSensitivity.medium.rawValue
        schema = (row["schema"] as? NSNumber)?.intValue ?? OwnerEvent.currentSchema

        // Empty when the sender did not say, which the PC reads as the owner's own clock. Never
        // this phone's zone: an event the PC observed was not observed here.
        zone = row["zone"] as? String ?? ""
    }

    /// Reads a stored event, tolerating one written before events said which clock they were on.
    ///
    /// Without this, adding `zone` to a stored shape would make every queued event undecodable and
    /// the whole offline queue would be dropped on the first launch after an update - losing
    /// exactly the observations the owner was away for, which are the ones the queue exists to
    /// keep. An old row decodes with an empty zone, and the PC reads an empty zone as home.
    init(from decoder: Decoder) throws {
        let row = try decoder.container(keyedBy: CodingKeys.self)

        id = try row.decode(String.self, forKey: .id)
        type = try row.decode(String.self, forKey: .type)
        category = try row.decode(String.self, forKey: .category)
        occurred = try row.decode(Date.self, forKey: .occurred)
        observed = try row.decode(Date.self, forKey: .observed)
        payload = try row.decodeIfPresent([String: String].self, forKey: .payload) ?? [:]
        confidence = try row.decodeIfPresent(Double.self, forKey: .confidence) ?? 1
        sensitivity = try row.decodeIfPresent(String.self, forKey: .sensitivity)
            ?? OwnerEventSensitivity.medium.rawValue
        schema = try row.decodeIfPresent(Int.self, forKey: .schema) ?? OwnerEvent.currentSchema
        zone = try row.decodeIfPresent(String.self, forKey: .zone) ?? ""
    }

    var sensitive: Bool {
        sensitivity == OwnerEventSensitivity.sensitive.rawValue
            || sensitivity == OwnerEventSensitivity.secret.rawValue
    }

    func value(_ key: String) -> String? { payload[key] }

    /// Which node observed it, when the PC said. Empty for this phone's own.
    var node: String { payload["node"] ?? "" }

    /// The stamp this phone writes.
    ///
    /// `ISO8601DateFormatter` defaults to GMT, and `.withInternetDateTime` then writes a `Z`. The
    /// instant was always right and the offset was always a lie: an arrival at ten past six on a
    /// July evening went out as `17:10Z`, and the PC - which learns a time of day from exactly
    /// these events - read it as ten past five. Setting the zone makes it `18:10+01:00`, which is
    /// the same instant and now says which clock it was. Not computed once and cached: a phone
    /// crosses into another zone mid-flight, and the whole point is to say where it actually was.
    private static var formatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = .current
        return formatter
    }

    static func stamp(_ date: Date) -> String { formatter.string(from: date) }

    /// A date as the PC writes it. .NET gives seven fractional digits, which is more than
    /// ISO8601DateFormatter is sure to accept, so `SmartDevice`'s reader does the trimming.
    static func date(_ value: Any?) -> Date? { SmartDevice.date(value) }
}

/// The buckets, matching the PC's `TimelineCategory` name for name.
enum OwnerEventCategory: String, Codable, CaseIterable {
    case unknown = "Unknown"
    case conversation = "Conversation"
    case activity = "Activity"
    case location = "Location"
    case device = "Device"
    case power = "Power"
    case security = "Security"
    case learning = "Learning"
    case task = "Task"
    case node = "Node"
}

/// How carefully an observation has to be handled, matching the PC's `Sensitivity`.
enum OwnerEventSensitivity: String, Codable {
    case low = "Low"
    case medium = "Medium"
    case sensitive = "Sensitive"
    case secret = "Secret"
}

/// The dotted names, matching the PC's `TimelineEventTypes`.
///
/// Duplicated rather than fetched, which is the right trade for a protocol constant: a name that
/// arrived over the wire could not be used in a switch, and the two lists disagreeing shows up as
/// an event the other side files under `Unknown` rather than as a crash.
enum OwnerEventTypes {
    static let asked = "conversation.asked"
    static let corrected = "conversation.corrected"
    static let deviceWorked = "device.worked"
    static let powerRead = "power.read"
    static let chargingChanged = "power.charging"
    static let pcWoken = "node.pc.woken"
    static let nodeUp = "node.up"
    static let nodeDown = "node.down"
    static let footageViewed = "security.footage.viewed"
    static let network = "node.network"
    static let arrived = "location.arrived"
    static let left = "location.left"
}

/// Whether an observation travels now or waits - programme §46.
///
/// The same rule as the PC's `SyncPolicy`, and it has to be: a phone that sent everything at once
/// would be the reason the battery went flat, and one that batched a security alert would make
/// JARVIS slower to tell the owner something than their own lock screen.
enum OwnerSyncPolicy {
    static let batchEvery: TimeInterval = 300
    static let batchOf = 25

    /// The most events held for a PC that is not answering.
    ///
    /// Bounded because a phone away from its PC for a month must not hold a month of observations
    /// to send in one burst - the same reason the location queue is bounded, for the same month.
    static let queueLimit = 2000

    /// The most of the PC's own events the phone keeps, so it can answer without the PC.
    ///
    /// A working subset rather than the whole history - programme §8. Enough to say what the owner
    /// was doing before they left, not enough to be a second copy of the timeline.
    static let keepFromThePC = 300

    static func urgent(_ event: OwnerEvent) -> Bool {
        switch OwnerEventCategory(rawValue: event.category) {
        case .security, .node, .conversation, .learning: return true
        default: return false
        }
    }

    static func dueNow(queued: Int, anyUrgent: Bool, lastSent: Date?, now: Date = Date()) -> Bool {
        guard queued > 0 else { return false }
        if anyUrgent { return true }
        if queued >= batchOf { return true }

        guard let lastSent else { return true }
        return now.timeIntervalSince(lastSent) >= batchEvery
    }

    /// The queue with one more in it, oldest dropped first if that takes it over the limit.
    static func queue(_ queue: [OwnerEvent], adding event: OwnerEvent) -> [OwnerEvent] {
        // Already held: the same observation, offered twice by whatever noticed it twice. Filed
        // once here as well as at the far end, so a duplicate does not even cost a round trip.
        guard !queue.contains(where: { $0.id == event.id }) else { return queue }

        let grown = queue + [event]

        return grown.count <= queueLimit ? grown : Array(grown.suffix(queueLimit))
    }
}

/// How the exchange with the PC stands, for the settings page and the diagnostics - programme §64.
struct OwnerSyncState: Equatable {
    var queued = 0
    var kept = 0
    var cursor: Int64 = 0
    var pcRevision: Int64 = 0
    var lastSync: Date?
    var problem: String?

    /// Whether the phone is behind what the PC has.
    var behind: Bool { pcRevision > cursor }
}

/// This phone as a node of the one timeline: what it files, and catching up on the rest.
///
/// **Nothing here has a Sync button, and that is the requirement rather than an omission**
/// (programme §9, §10). The owner granted the pairing; being asked to press Sync afterwards would
/// mean JARVIS knew less than it could because nobody tapped. So an exchange happens on every
/// connection, whenever an urgent observation is filed, and whenever a batch is old or big enough.
///
/// **Push and pull are separate.** They fail independently and should: a phone that gets its own
/// events filed and loses the answer can push again for nothing, because the ids are stable, and
/// its pull cursor has not moved, so it has not quietly skipped anything of the PC's.
@MainActor
final class OwnerTimelineClient: ObservableObject {
    static let shared = OwnerTimelineClient()

    /// Waiting to go to the PC.
    @Published private(set) var queue: [OwnerEvent] = []

    /// What the PC has told this phone, newest first. The working subset - programme §8.
    @Published private(set) var kept: [OwnerEvent] = []

    @Published private(set) var cursor: Int64 = 0
    @Published private(set) var pcRevision: Int64 = 0
    @Published private(set) var lastSync: Date?
    @Published private(set) var problem: String?

    /// This phone's id in the timeline. Set once the pairing is known.
    private var nodeId = "phone"

    private var exchanging = false

    private init() {
        let stored = Self.read()
        queue = stored.queue
        kept = stored.kept
        cursor = stored.cursor
    }

    var state: OwnerSyncState {
        OwnerSyncState(
            queued: queue.count,
            kept: kept.count,
            cursor: cursor,
            pcRevision: pcRevision,
            lastSync: lastSync,
            problem: problem)
    }

    /// Tells the client which node it is, so its ids are stable across launches.
    func identify(as deviceId: String) {
        guard !deviceId.isEmpty else { return }
        nodeId = deviceId
    }

    // MARK: Filing an observation

    /// Files one observation and, when it is due, sends what is waiting.
    ///
    /// - Parameter exchange: puts a request on the bridge. Nil means queue only, which is what
    ///   happens with the PC off - and is the ordinary case rather than a failure.
    func record(
        _ type: String,
        category: OwnerEventCategory,
        payload: [String: String] = [:],
        occurred: Date = Date(),
        confidence: Double = 1,
        sensitivity: OwnerEventSensitivity = .medium,
        key: String,
        exchange: ((String, [String: Any]) async throws -> [String: Any])? = nil
    ) {
        let event = OwnerEvent(
            id: identify(type, key),
            type: type,
            category: category,
            occurred: occurred,
            payload: payload,
            confidence: confidence,
            sensitivity: sensitivity)

        let before = queue.count
        queue = OwnerSyncPolicy.queue(queue, adding: event)

        // Already held. Nothing changed, so nothing is written and nothing is sent.
        guard queue.count != before else { return }

        save()

        guard let exchange,
              OwnerSyncPolicy.dueNow(queued: queue.count,
                                     anyUrgent: queue.contains(where: OwnerSyncPolicy.urgent),
                                     lastSent: lastSync)
        else { return }

        Task { await self.sync(exchange) }
    }

    /// A stable id for one observation: this node, the type, and a hash of what makes it itself.
    ///
    /// Hashed so an id can never carry the content it was made from. An id is printed in logs and
    /// shown in a diagnostic, and a conversation in an id would defeat every bit of care taken
    /// over the payload.
    func identify(_ type: String, _ key: String) -> String {
        let digest = SHA256.hash(data: Data("\(nodeId)|\(type)|\(key)".utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()

        return "\(nodeId):\(type):\(hex.prefix(16))"
    }

    // MARK: The exchange

    /// Pushes what is waiting, then pulls what this phone has missed.
    ///
    /// Safe to call as often as anything likes: one exchange runs at a time, and an exchange with
    /// nothing to push still pulls, because the point of a reconnect is finding out what happened
    /// while the phone was away.
    func sync(_ exchange: (String, [String: Any]) async throws -> [String: Any]) async {
        guard !exchanging else { return }

        exchanging = true
        defer { exchanging = false }

        await push(exchange)
        await pull(exchange)
    }

    private func push(_ exchange: (String, [String: Any]) async throws -> [String: Any]) async {
        guard !queue.isEmpty else { return }

        // A bounded batch, oldest first. The rest goes on the next exchange rather than in one
        // message a bridge would refuse for size.
        let batch = Array(queue.prefix(OwnerSyncPolicy.batchOf))

        do {
            let reply = try await exchange("timeline.push", ["events": batch.map(\.body)])

            // Dropped only once the PC says it has them. A batch lost on the way is offered again,
            // which costs nothing because the ids are stable.
            let sent = Set(batch.map(\.id))
            queue.removeAll { sent.contains($0.id) }

            if let revision = (reply["revision"] as? NSNumber)?.int64Value { pcRevision = revision }

            lastSync = Date()
            problem = nil
            save()
        } catch {
            problem = error.localizedDescription
        }
    }

    private func pull(_ exchange: (String, [String: Any]) async throws -> [String: Any]) async {
        do {
            let reply = try await exchange("timeline.pull", ["since": cursor, "limit": OwnerSyncPolicy.batchOf])

            let rows = reply["events"] as? [[String: Any]] ?? []
            let events = rows.compactMap(OwnerEvent.init)

            if let through = (reply["through"] as? NSNumber)?.int64Value, through > cursor {
                cursor = through
            }
            if let revision = (reply["revision"] as? NSNumber)?.int64Value { pcRevision = revision }

            keep(events)

            lastSync = Date()
            problem = nil
            save()

            // More behind the batch: keep going while there is. Bounded by the cursor moving, so a
            // PC that answers without advancing it cannot spin this.
            if (reply["more"] as? Bool) == true, !events.isEmpty {
                await pull(exchange)
            }
        } catch {
            problem = error.localizedDescription
        }
    }

    /// Adds the PC's events to the working subset, newest first, without duplicating.
    func keep(_ events: [OwnerEvent]) {
        guard !events.isEmpty else { return }

        var held = kept

        for event in events {
            if let index = held.firstIndex(where: { $0.id == event.id }) {
                held[index] = event
            } else {
                held.append(event)
            }
        }

        kept = Array(held.sorted { $0.occurred > $1.occurred }.prefix(OwnerSyncPolicy.keepFromThePC))
    }

    /// What happened in a window, oldest first - for "what did I do when I got home".
    func between(_ from: Date, _ to: Date) -> [OwnerEvent] {
        kept.filter { $0.occurred >= from && $0.occurred <= to }.sorted { $0.occurred < $1.occurred }
    }

    /// The most recent of one category, newest first.
    func latest(_ category: OwnerEventCategory, _ count: Int = 10) -> [OwnerEvent] {
        Array(kept.filter { $0.category == category.rawValue }.prefix(count))
    }

    /// Forgets everything. For unpairing: this is the owner's life, and it goes with the pairing.
    func forget() {
        queue = []
        kept = []
        cursor = 0
        pcRevision = 0
        lastSync = nil
        problem = nil
        try? FileManager.default.removeItem(at: Self.file)
    }

    // MARK: On disk

    /// In Application Support rather than the Keychain: this can be thousands of rows, and the
    /// Keychain is for secrets rather than for volume.
    ///
    /// **Protected, and deliberately not with the strongest class** - programme §48. `.complete`
    /// would make a write fail while the phone is locked, and locked is exactly when a significant
    /// location change wakes the app; the observation would be lost to protect it. So the file is
    /// readable only after the owner has unlocked once since boot, which keeps it out of reach of
    /// a lifted handset while still letting a background wake write to it.
    private static var file: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("owner-timeline.json")
    }

    private struct Stored: Codable {
        var queue: [OwnerEvent] = []
        var kept: [OwnerEvent] = []
        var cursor: Int64 = 0
    }

    private static func read() -> Stored {
        guard let data = try? Data(contentsOf: file),
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return Stored() }

        return stored
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Stored(queue: queue, kept: kept, cursor: cursor)) else { return }

        try? data.write(to: Self.file, options: [.atomic])

        // Stated rather than inherited, so the protection is a decision in the source and not a
        // platform default that a later iOS could change underneath this.
        try? (Self.file as NSURL).setResourceValue(
            URLFileProtection.completeUntilFirstUserAuthentication,
            forKey: .fileProtectionKey)
    }
}
