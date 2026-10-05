import Foundation

/// What this phone concludes about where it is - programme §1D.
///
/// Conservative on purpose. The failure that matters is not "JARVIS could not say where I am", it
/// is "JARVIS said I was at home when I was two streets away", because the owner then stops
/// believing the ones that are right. Every case that cannot be answered confidently is answered
/// honestly instead.
enum PlaceVerdict: Equatable {
    /// Inside a place, and sure enough to name it.
    case at(MobilePlace)

    /// Inside a place, but the fix is old enough that saying it in the present tense would be a
    /// claim about now that the evidence is not about.
    case lastAt(MobilePlace, Date)

    /// The fix is good but is nowhere this phone knows.
    case somewhereElse

    /// Two places fit and nothing separates them. Saying either would be a coin toss.
    case between([MobilePlace])

    /// A fix too vague to place: indoors on cell towers, or a first reading still settling.
    case tooVague(Double)

    /// There is no fix at all - permission withheld, or location switched off.
    case noFix

    /// Whether this names somewhere.
    var place: MobilePlace? {
        switch self {
        case .at(let place): return place
        case .lastAt(let place, _): return place
        default: return nil
        }
    }
}

/// Resolving a coordinate against the places this phone holds.
enum PlaceResolution {
    /// How old a fix may be and still describe where the owner is now.
    static let freshFor: TimeInterval = 10 * 60

    /// A fix vaguer than this says nothing about which place the owner is in.
    ///
    /// The same figure the PC's place book uses, for the same reason: a reading good to 250 m
    /// inside a 80 m place would put the owner in a place they are a quarter of a mile from.
    static let uselessAccuracyMetres: Double = 250

    /// Resolves a fix against the local subset.
    ///
    /// - Parameters:
    ///   - fix: the last position this phone took, or nil when there is none.
    ///   - places: the local subset.
    ///   - moment: the clock, so staleness is testable.
    static func read(
        _ fix: Whereabouts?,
        in places: [MobilePlace],
        at moment: Date = Date()
    ) -> PlaceVerdict {
        guard let fix else { return .noFix }

        if fix.accuracy > uselessAccuracyMetres { return .tooVague(fix.accuracy) }

        // Everything the fix could be inside. The accuracy has to be good enough to distinguish
        // the place at all: a fix good to 100 m tells you nothing about an 80 m place, even when
        // its centre happens to land inside.
        let inside = places
            .filter { $0.radius >= fix.accuracy }
            .map { (place: $0, away: metres(fix, $0)) }
            .filter { $0.away <= $0.place.radius }
            .sorted { $0.away < $1.away }

        // Nowhere known, fresh or stale alike: a stale fix in an unknown place is still an unknown
        // place, and dressing that up as "last placed you somewhere I can't name" says less.
        guard let nearest = inside.first else { return .somewhereElse }

        // Two places overlapping is not automatically ambiguous - a room inside a building is a
        // sensible pair. It is ambiguous when the fix cannot tell them apart, which is when the
        // second is no further away than the error in the measurement.
        if inside.count > 1, inside[1].away - nearest.away <= fix.accuracy {
            return .between(inside.map(\.place))
        }

        return fresh(fix, at: moment) ? .at(nearest.place) : .lastAt(nearest.place, fix.at)
    }

    static func fresh(_ fix: Whereabouts, at moment: Date) -> Bool {
        moment.timeIntervalSince(fix.at) <= freshFor
    }

    /// Whether a fix puts the owner in a particular place, for "am I at X?".
    static func isAt(_ fix: Whereabouts?, _ place: MobilePlace, at moment: Date = Date()) -> PlaceVerdict {
        guard let fix else { return .noFix }
        if fix.accuracy > uselessAccuracyMetres { return .tooVague(fix.accuracy) }

        guard metres(fix, place) <= place.radius, place.radius >= fix.accuracy else { return .somewhereElse }

        return fresh(fix, at: moment) ? .at(place) : .lastAt(place, fix.at)
    }

    static func metres(_ fix: Whereabouts, _ place: MobilePlace) -> Double {
        WhereaboutsRules.metres(
            fix,
            Whereabouts(latitude: place.latitude, longitude: place.longitude, accuracy: 0, at: fix.at))
    }
}

/// A learned pattern as this phone holds it. Matches the PC's `SharedRoutine`.
struct MobileRoutine: Codable, Equatable, Identifiable {
    let id: String
    let kind: String
    let subject: String
    let day: String
    let typical: Int
    let spread: Int
    let samples: Int
    let confidence: Double
    let reinforced: Date

    var window: (from: Int, to: Int) { (typical - spread, typical + spread) }

    init?(_ row: [String: String]) {
        guard let id = row["id"], !id.isEmpty, let kind = row["kind"], !kind.isEmpty else { return nil }

        self.id = id
        self.kind = kind
        subject = row["subject"] ?? ""
        day = row["day"] ?? ""
        typical = Int(row["typical"] ?? "") ?? 0
        spread = Int(row["spread"] ?? "") ?? 0
        samples = Int(row["samples"] ?? "") ?? 0
        confidence = Double(row["confidence"] ?? "") ?? 0
        reinforced = Double(row["reinforced"] ?? "").map { Date(timeIntervalSince1970: $0) } ?? .distantPast
    }
}

/// Saying what JARVIS knows about where the owner is, and what it merely expects - programme §2C.
///
/// The distinction between a fact and a pattern is the whole of whether the owner can trust any of
/// this. "You arrived home at 18:07" is an observation and may be stated. "You usually arrive home
/// between about 17:50 and 18:20" is a pattern and must be hedged, every time, because a
/// prediction stated as a fact is a lie the first time it is wrong - and the owner has no way of
/// telling which kind they just heard unless the wording says.
enum PlaceAnswers {
    // MARK: where am I

    static func whereAmI(_ verdict: PlaceVerdict, at moment: Date = Date()) -> String {
        switch verdict {
        case .at(let place):
            if place.category == .home { return "You're at home, sir." }
            if !place.name.isEmpty { return "You're at \(place.name), sir." }

            return "You're \(place.spoken), sir."

        case .lastAt(let place, let when):
            return "Your phone last placed you at \(place.spoken) \(ago(when, at: moment)), sir."

        case .somewhereElse:
            return "You're not anywhere I know by name, sir."

        case .between(let places):
            let named = places.compactMap { $0.name.isEmpty ? nil : $0.name }

            if named.count >= 2 { return "You're either at \(named[0]) or \(named[1]), sir - I can't separate them." }

            return "I can't tell which of two places you're in, sir."

        case .tooVague(let accuracy):
            return "I can only place you to about \(Int(accuracy)) metres, sir, which isn't enough to name anywhere."

        case .noFix:
            return "I can't tell where you are, sir - JARVIS hasn't been given location access."
        }
    }

    /// "Am I home?", "am I at university?" - a yes or no, and never a guess.
    static func amIAt(_ said: String, _ verdict: PlaceVerdict, asked place: MobilePlace?) -> String {
        guard let place else {
            return "I don't know anywhere called \(said), sir."
        }

        let what = place.name.isEmpty ? said : place.name

        switch verdict {
        case .at: return "Yes, sir, you're at \(what)."
        case .lastAt(_, let when): return "You were at \(what) as of \(clock(when)), sir, but that reading is old."
        case .somewhereElse: return "No, sir, you're not at \(what)."
        case .between: return "I can't be sure, sir - two places fit and I can't separate them."
        case .tooVague: return "I can't place you precisely enough to say, sir."
        case .noFix: return "I can't tell where you are, sir - JARVIS hasn't been given location access."
        }
    }

    // MARK: the day

    /// "When did I get here?" - an observation, from this phone's own record.
    static func arrivedAt(_ when: Date?, _ place: MobilePlace?, at moment: Date = Date()) -> String {
        guard let when, let place else {
            return "I've no record of you arriving anywhere today, sir."
        }

        let what = place.name.isEmpty ? place.spoken : place.name

        return "You got to \(what) at \(clock(when)), sir - \(ago(when, at: moment))."
    }

    /// "How long have I been here?"
    static func hereSince(_ when: Date?, _ place: MobilePlace?, at moment: Date = Date()) -> String {
        guard let when, let place else { return "I don't know when you got here, sir." }

        let what = place.name.isEmpty ? place.spoken : place.name

        return "You've been at \(what) about \(span(moment.timeIntervalSince(when))), sir."
    }

    /// "When did I leave home?"
    static func leftAt(_ when: Date?, _ place: MobilePlace?) -> String {
        guard let when, let place else { return "I've no record of you leaving, sir." }

        let what = place.name.isEmpty ? place.spoken : place.name

        return "You left \(what) at \(clock(when)), sir."
    }

    /// "Where was I earlier?" - the places this phone saw today, in order, named.
    static func earlier(_ visits: [(place: MobilePlace, from: Date)]) -> String {
        guard !visits.isEmpty else { return "I've nothing recorded for today, sir." }

        let said = visits
            .map { "\($0.place.name.isEmpty ? $0.place.spoken : $0.place.name) at \(clock($0.from))" }
            .joined(separator: ", then ")

        return "Today, sir: \(said)."
    }

    // MARK: the pattern, which is never a fact

    /// "Where do I normally go around this time?"
    static func usually(_ routines: [MobileRoutine], at moment: Date = Date()) -> String {
        let minutes = Calendar.current.component(.hour, from: moment) * 60
            + Calendar.current.component(.minute, from: moment)

        // Within an hour either side, strongest first. A pattern about four in the morning is not
        // an answer to a question asked at teatime.
        let near = routines
            .filter { abs(apart($0.typical, minutes)) <= 60 }
            .sorted { $0.confidence > $1.confidence }

        guard let best = near.first else {
            return "Nothing I've learned says anything about this time of day, sir."
        }

        return describe(best)
    }

    /// A pattern, hedged, with its evidence available to the owner who wants to judge it.
    static func describe(_ routine: MobileRoutine) -> String {
        let when = routine.day.isEmpty ? "most days" : "on \(routine.day)s"

        switch routine.kind {
        case "Leaving":
            return "You usually leave \(routine.subject) between about "
                + "\(clock(minutes: routine.window.from)) and \(clock(minutes: routine.window.to)) \(when), sir."

        case "Arriving":
            return "You usually get to \(routine.subject) between about "
                + "\(clock(minutes: routine.window.from)) and \(clock(minutes: routine.window.to)) \(when), sir."

        case "Working":
            return "You usually start working in \(routine.subject) between about "
                + "\(clock(minutes: routine.window.from)) and \(clock(minutes: routine.window.to)) \(when), sir."

        case "Staying":
            return "You usually stay at \(routine.subject) about \(span(TimeInterval(routine.typical * 60))), sir."

        default:
            return "I've learned something about \(routine.subject), sir, but I can't put it in words."
        }
    }

    // MARK: wording

    static func clock(_ when: Date) -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: when)

        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    static func clock(minutes: Int) -> String {
        let wrapped = ((minutes % 1440) + 1440) % 1440

        return String(format: "%02d:%02d", wrapped / 60, wrapped % 60)
    }

    static func span(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)

        if minutes < 1 { return "a moment" }
        if minutes < 60 { return "\(minutes) minute\(minutes == 1 ? "" : "s")" }

        let hours = Double(minutes) / 60

        return hours == hours.rounded()
            ? "\(Int(hours)) hour\(hours == 1 ? "" : "s")"
            : String(format: "%.1f hours", hours)
    }

    static func ago(_ when: Date, at moment: Date) -> String {
        "\(span(moment.timeIntervalSince(when))) ago"
    }

    /// Minutes apart on a clock face, so midnight is near one minute past.
    static func apart(_ left: Int, _ right: Int) -> Int {
        let straight = abs(left - right)

        return min(straight, 1440 - straight)
    }
}

extension PlaceAnswers {
    /// Everything this phone needs to answer a question about whereabouts, in one place.
    ///
    /// Passed in rather than reached for, so the whole of the answering is a function of its
    /// arguments and every case below is testable without a location manager, a clock or a disk.
    struct Evidence {
        let fix: Whereabouts?
        let places: [MobilePlace]
        let visits: [MobileVisit]
        let routines: [MobileRoutine]
        let moment: Date

        init(
            fix: Whereabouts?,
            places: [MobilePlace],
            visits: [MobileVisit] = [],
            routines: [MobileRoutine] = [],
            moment: Date = Date()
        ) {
            self.fix = fix
            self.places = places
            self.visits = visits
            self.routines = routines
            self.moment = moment
        }

        func place(_ id: String) -> MobilePlace? { places.first { $0.id == id } }

        func calling(_ said: String) -> MobilePlace? {
            // "Home" answers to the category as well as to the name, because an owner who
            // categorised their house and never renamed it still says "am I home".
            if said.caseInsensitiveCompare("home") == .orderedSame,
               let home = places.first(where: { $0.category == .home }) {
                return home
            }

            return places.first { $0.called(said) }
        }
    }

    /// The answer to one question about whereabouts, deterministically and without the PC.
    static func answer(_ asked: Whereabouts.Question, named: String?, from evidence: Evidence) -> String {
        let verdict = PlaceResolution.read(evidence.fix, in: evidence.places, at: evidence.moment)

        switch asked {
        case .whereAmI:
            return whereAmI(verdict, at: evidence.moment)

        case .amIAt:
            guard let named else { return whereAmI(verdict, at: evidence.moment) }

            guard let place = evidence.calling(named) else {
                return amIAt(named, verdict, asked: nil)
            }

            return amIAt(named, PlaceResolution.isAt(evidence.fix, place, at: evidence.moment), asked: place)

        case .arrived:
            let place = named.flatMap(evidence.calling) ?? verdict.place

            guard let place else { return arrivedAt(nil, nil, at: evidence.moment) }

            let when = evidence.visits
                .filter { $0.placeId == place.id }
                .map(\.from)
                .max()

            return arrivedAt(when, place, at: evidence.moment)

        case .left:
            guard let place = named.flatMap(evidence.calling) else { return leftAt(nil, nil) }

            let when = evidence.visits
                .filter { $0.placeId == place.id }
                .compactMap(\.to)
                .max()

            return leftAt(when, place)

        case .howLong:
            let open = evidence.visits.last { $0.open }

            return hereSince(open?.from, open.flatMap { evidence.place($0.placeId) }, at: evidence.moment)

        case .earlier:
            let start = Calendar.current.startOfDay(for: evidence.moment)

            let today = evidence.visits
                .filter { $0.from >= start }
                .sorted { $0.from < $1.from }
                .compactMap { visit -> (place: MobilePlace, from: Date)? in
                    guard let place = evidence.place(visit.placeId) else { return nil }
                    return (place, visit.from)
                }

            return earlier(today)

        case .usually:
            return usually(evidence.routines, at: evidence.moment)
        }
    }
}
