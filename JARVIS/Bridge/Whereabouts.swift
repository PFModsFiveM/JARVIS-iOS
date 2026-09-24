import CoreLocation
import Foundation

/// One position this phone recorded, kept until the PC has it.
///
/// The phone is the only thing that knows where its owner is, and it is awake far more often than
/// the PC is. So it records for itself first and reports second: a walk with the PC asleep is still
/// a walk that happened, and a trail that only exists while the desk is on is a trail with holes in
/// it exactly where somebody was out.
struct Whereabouts: Codable, Equatable {
    let latitude: Double
    let longitude: Double
    let accuracy: Double
    let at: Date

    init(_ location: CLLocation) {
        latitude = location.coordinate.latitude
        longitude = location.coordinate.longitude
        accuracy = location.horizontalAccuracy
        at = location.timestamp
    }

    init(latitude: Double, longitude: Double, accuracy: Double, at: Date) {
        self.latitude = latitude
        self.longitude = longitude
        self.accuracy = accuracy
        self.at = at
    }

    var body: [String: Any] {
        ["latitude": latitude, "longitude": longitude, "accuracy": accuracy, "at": ISO8601DateFormatter().string(from: at)]
    }
}

/// What is worth keeping, and how much of it, decided without a location manager in the way.
///
/// The rules are the same ones the PC's own trail applies, applied here as well: a phone with no
/// connection should not fill its queue with a still afternoon, and a phone that has been away from
/// its PC for a month should not be holding a month of positions to send in one burst.
enum WhereaboutsRules {
    /// How far the phone must move before a reading says anything new.
    static let movedMetres: Double = 50

    /// How long a still phone waits before it reports again anyway.
    static let stillFor: TimeInterval = 600

    /// The most readings held for a PC that is not answering.
    static let queueLimit = 500

    /// A reading claiming to be vaguer than this is a phone guessing from cell towers indoors.
    static let uselessAccuracyMetres: Double = 500

    static func worthKeeping(_ reading: Whereabouts, after last: Whereabouts?) -> Bool {
        if reading.accuracy > uselessAccuracyMetres { return false }

        guard let last else { return true }

        if reading.at.timeIntervalSince(last.at) >= stillFor { return true }

        return metres(last, reading) >= movedMetres
    }

    /// The queue with one more in it, oldest dropped first if that takes it over the limit.
    static func queue(_ queue: [Whereabouts], adding reading: Whereabouts) -> [Whereabouts] {
        let grown = queue + [reading]

        return grown.count <= queueLimit ? grown : Array(grown.suffix(queueLimit))
    }

    /// Distance between two readings, by the haversine formula on a spherical earth.
    ///
    /// Good to a few metres over the distances this cares about, and it needs no CoreLocation, so
    /// the rule above can be tested as arithmetic.
    static func metres(_ from: Whereabouts, _ to: Whereabouts) -> Double {
        let earth = 6_371_000.0
        let lat1 = from.latitude * .pi / 180
        let lat2 = to.latitude * .pi / 180
        let dLat = (to.latitude - from.latitude) * .pi / 180
        let dLon = (to.longitude - from.longitude) * .pi / 180

        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)

        return earth * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}

/// Where the phone is, and telling the PC about it.
///
/// **What this asks for and why.** "When in use" is enough for answering "where am I" while the app
/// is open, and useless for the thing the owner actually wants, which is JARVIS knowing they have
/// left the house. That needs "always", and always is a serious permission - so it is asked for
/// only when the owner turns this on, the switch is off until they do, and turning it off stops the
/// updates rather than merely hiding them.
///
/// **Significant changes, not continuous updates.** `startMonitoringSignificantLocationChanges`
/// wakes the app when the phone moves several hundred metres and costs almost no battery, because
/// iOS is already tracking cell handovers for its own reasons. Continuous updates would drain a
/// battery in an afternoon to answer a question nobody asks that precisely.
///
/// **It keeps what it cannot send.** Every reading goes into a small local queue first. When the
/// bridge is up they are sent oldest first and dropped as they are acknowledged; when it is not -
/// the PC is asleep, the phone is on a train - they wait. The queue is bounded, because a phone
/// that has been away from its PC for a month should not be holding a month of positions to send in
/// one burst.
@MainActor
final class LocationReporter: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var authorised = false
    @Published private(set) var reporting = false
    @Published private(set) var waiting = 0
    @Published private(set) var lastReported: Date?

    private let manager = CLLocationManager()
    private let send: (String, [String: Any]) async throws -> Void
    private var queue: [Whereabouts] = []
    private var last: Whereabouts?
    private var flushing = false

    /// - Parameter send: puts one request on the bridge. Injected so this can be tested without one.
    init(send: @escaping (String, [String: Any]) async throws -> Void) {
        self.send = send
        super.init()

        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.pausesLocationUpdatesAutomatically = true

        // Without this, iOS stops delivering while the app is in the background, which is the only
        // time this matters.
        manager.allowsBackgroundLocationUpdates = false

        queue = Self.readQueue()
        waiting = queue.count
        authorised = manager.authorizationStatus == .authorizedAlways
    }

    /// Asks for permission and begins. The owner's own action, never automatic.
    func start() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestAlwaysAuthorization()
        case .authorizedAlways:
            begin()
        case .authorizedWhenInUse:
            // Ask once to upgrade. iOS shows this at most once per install, and refusing it leaves
            // the app working exactly as it did.
            manager.requestAlwaysAuthorization()
        default:
            reporting = false
        }
    }

    /// Stops reporting. What is already queued stays queued, because it is the owner's own history.
    func stop() {
        manager.stopMonitoringSignificantLocationChanges()
        manager.allowsBackgroundLocationUpdates = false
        reporting = false
    }

    private func begin() {
        guard !reporting else { return }

        manager.allowsBackgroundLocationUpdates = true
        manager.startMonitoringSignificantLocationChanges()
        reporting = true
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            authorised = manager.authorizationStatus == .authorizedAlways

            if authorised {
                begin()
            } else {
                reporting = false
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let readings = locations.map(Whereabouts.init)

        Task { @MainActor in
            for reading in readings where WhereaboutsRules.worthKeeping(reading, after: last) {
                queue = WhereaboutsRules.queue(queue, adding: reading)
                last = reading
            }

            waiting = queue.count
            Self.writeQueue(queue)

            await flush()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // A phone indoors fails to get a fix all the time. It is not worth telling anybody about.
    }

    /// Sends what is queued, oldest first, and stops at the first one that will not go.
    ///
    /// Stopping rather than skipping keeps the trail in order on the PC, and means a PC that is
    /// asleep costs one failed attempt rather than five hundred.
    func flush() async {
        guard !flushing, !queue.isEmpty else { return }

        flushing = true
        defer { flushing = false }

        while let next = queue.first {
            do {
                try await send("location", next.body)
                queue.removeFirst()
                lastReported = next.at
            } catch {
                break
            }
        }

        waiting = queue.count
        Self.writeQueue(queue)
    }

    // MARK: - The queue on disk

    /// In Application Support rather than in the Keychain: it is a list of positions, not a secret,
    /// and it can be large. The folder is covered by the device's own encryption.
    private static var queueFile: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("whereabouts.json")
    }

    private static func readQueue() -> [Whereabouts] {
        guard let data = try? Data(contentsOf: queueFile) else { return [] }
        return (try? JSONDecoder().decode([Whereabouts].self, from: data)) ?? []
    }

    private static func writeQueue(_ queue: [Whereabouts]) {
        guard let data = try? JSONEncoder().encode(queue) else { return }
        try? data.write(to: queueFile, options: .atomic)
    }
}
