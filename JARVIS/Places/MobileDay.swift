import Foundation

/// One stretch this phone spent in one place.
struct MobileVisit: Codable, Equatable, Identifiable {
    let placeId: String
    let from: Date
    var to: Date?

    /// How many fixes landed inside it, which is how much the stretch is worth believing.
    var fixes: Int

    var id: String { "\(placeId)@\(from.timeIntervalSince1970)" }

    var length: TimeInterval { (to ?? Date()).timeIntervalSince(from) }

    var open: Bool { to == nil }
}

/// What this phone has seen of the owner's day - programme §2A.
///
/// Bounded and local. It exists so the phone can answer "when did I get here" with the PC switched
/// off, which it could not do from a queue of coordinates - resolving a hundred fixes against the
/// place subset for every question would be both slow and a different answer each time.
///
/// **Deliberately not filed into the shared timeline.** The PC already derives arrivals and
/// departures from the trail this phone sends, through its own place book, and that is the single
/// authority on them. If this phone also filed arrival events, the same arrival would exist twice
/// under two ids - once derived by the PC and once asserted by the phone - and the routine learner
/// would count it twice, which is exactly how a median gets quietly dragged. Nothing is lost by
/// staying quiet: the fixes still reach the PC, so the evidence does, and only the conclusion is
/// drawn in one place.
@MainActor
final class MobileDay: ObservableObject {
    static let shared = MobileDay()

    /// How many days of visits are kept. Enough for "yesterday", not a movement history.
    static let keepDays = 3

    /// The most visits held, as a backstop against a day of a phone deciding where it is.
    static let most = 60

    @Published private(set) var visits: [MobileVisit] = []

    private var loaded = false

    private init() { load() }

    /// Today's visits, oldest first.
    func today(_ moment: Date = Date()) -> [MobileVisit] {
        let start = Calendar.current.startOfDay(for: moment)

        return visits.filter { $0.from >= start }.sorted { $0.from < $1.from }
    }

    /// The stretch the owner is in now, if this phone thinks they are in one.
    var current: MobileVisit? { visits.last(where: { $0.open }) }

    /// When the owner got to the place they are in, if that is known.
    var hereSince: Date? { current?.from }

    /// When they last left the named place, by any of its names.
    func leftLast(_ place: MobilePlace) -> Date? {
        visits
            .filter { $0.placeId == place.id }
            .compactMap(\.to)
            .max()
    }

    /// When they last arrived at the named place.
    func arrivedLast(_ place: MobilePlace) -> Date? {
        visits.filter { $0.placeId == place.id }.map(\.from).max()
    }

    /// Takes a fix and keeps the day's shape up to date.
    ///
    /// Idempotent in the sense that matters: a second fix in the same place extends the stretch
    /// rather than starting another, so a phone sitting on a table all afternoon is one visit with
    /// a growing count and not an afternoon of one-minute arrivals.
    func saw(_ fix: Whereabouts, in places: [MobilePlace], at moment: Date = Date()) {
        load()

        let verdict = PlaceResolution.read(fix, in: places, at: fix.at)

        // Only a confident placing moves the day on. An ambiguous or vague fix is not evidence of
        // having left anywhere either, so the open stretch is left exactly as it was.
        switch verdict {
        case .at(let place), .lastAt(let place, _):
            if let open = current, open.placeId == place.id {
                if let index = visits.lastIndex(where: { $0.id == open.id }) {
                    visits[index].fixes += 1
                }
            } else {
                close(at: fix.at)
                visits.append(MobileVisit(placeId: place.id, from: fix.at, to: nil, fixes: 1))
            }

        case .somewhereElse:
            close(at: fix.at)

        case .between, .tooVague, .noFix:
            break
        }

        trim(at: moment)
        save()
    }

    /// Forgets everything. For the owner turning location off, and for tests.
    func forget() {
        visits = []
        save()
    }

    private func close(at moment: Date) {
        guard let open = current, let index = visits.lastIndex(where: { $0.id == open.id }) else { return }

        visits[index].to = moment
    }

    private func trim(at moment: Date) {
        let floor = Calendar.current.startOfDay(for: moment).addingTimeInterval(-Double(Self.keepDays - 1) * 86_400)

        visits.removeAll { ($0.to ?? $0.from) < floor }

        if visits.count > Self.most {
            visits = Array(visits.sorted { $0.from < $1.from }.suffix(Self.most))
        }
    }

    // MARK: on disk

    private static var file: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        return folder.appendingPathComponent("jarvis-day.json")
    }

    private func load() {
        guard !loaded else { return }

        loaded = true

        guard let data = try? Data(contentsOf: Self.file),
              let read = try? JSONDecoder().decode([MobileVisit].self, from: data)
        else { return }

        visits = read
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(visits) else { return }

        try? data.write(to: Self.file, options: [.atomic])

        // A visit is a place and a time, which together say where the owner lives and when they
        // are out. The same protection as the places themselves.
        try? (Self.file as NSURL).setResourceValue(
            URLFileProtection.completeUntilFirstUserAuthentication,
            forKey: .fileProtectionKey)
    }
}
