import XCTest
@testable import JARVIS

/// The places this phone holds, and what it will and will not claim from them - programme §1B-§1E.
///
/// No real coordinate appears here. Everything is a round number in the North Atlantic, so a test
/// that accidentally printed one would print nothing about anybody.
final class MobilePlaceTests: XCTestCase {
    private static let noon = Date(timeIntervalSince1970: 1_793_016_000)

    private func row(
        id: String,
        name: String,
        lat: Double = 53,
        lon: Double = -7,
        radius: Double = 80,
        named: Bool = true,
        revision: Int = 1,
        visits: Int = 10,
        category: String = "Unknown",
        aliases: String = "",
        arrives: Int? = nil,
        lastSeen: Date = MobilePlaceTests.noon
    ) -> [String: String] {
        var row: [String: String] = [
            "id": id, "name": name,
            "lat": String(lat), "lon": String(lon), "radius": String(radius),
            "named": named ? "1" : "0", "revision": String(revision),
            "visits": String(visits), "category": category, "aliases": aliases,
            "confidence": named ? "1" : "0.5",
            "firstSeen": String(Int(lastSeen.timeIntervalSince1970) - 86_400),
            "lastSeen": String(Int(lastSeen.timeIntervalSince1970)),
            "updated": String(Int(lastSeen.timeIntervalSince1970))
        ]

        if let arrives { row["arrives"] = String(arrives) }

        return row
    }

    private func place(_ id: String = "A", _ name: String = "Home", lat: Double = 53, lon: Double = -7,
                       radius: Double = 80, category: String = "Unknown", aliases: String = "",
                       named: Bool = true, revision: Int = 1) -> MobilePlace {
        MobilePlace(row(id: id, name: name, lat: lat, lon: lon, radius: radius, named: named,
                        revision: revision, category: category, aliases: aliases))!
    }

    private func fix(_ lat: Double = 53, _ lon: Double = -7, accuracy: Double = 20,
                     at moment: Date = MobilePlaceTests.noon) -> Whereabouts {
        Whereabouts(latitude: lat, longitude: lon, accuracy: accuracy, at: moment)
    }

    // MARK: reading a row

    func testARowWithNoIdIsRefusedRatherThanGivenOne() {
        XCTAssertNil(MobilePlace(["name": "Home"]))
        XCTAssertNil(MobilePlace(["id": "   ", "name": "Home"]))
    }

    func testARowSurvivesBeingRead() {
        let read = MobilePlace(row(id: "A", name: "University", category: "Study",
                                   aliases: "uni\u{1f}college", arrives: 550))

        XCTAssertEqual(read?.name, "University")
        XCTAssertEqual(read?.aliases, ["uni", "college"])
        XCTAssertEqual(read?.category, .study)
        XCTAssertEqual(read?.arrives, 550)
        XCTAssertNil(read?.leaves)
    }

    func testAnUnknownFieldIsIgnoredRatherThanFatal() {
        var extra = row(id: "A", name: "Home")
        extra["somethingTheNextBuildAdded"] = "whatever"

        XCTAssertEqual(MobilePlace(extra)?.name, "Home")
    }

    func testAPlaceAnswersToEveryNameItHas() {
        let uni = place("A", "University", aliases: "uni\u{1f}college")

        XCTAssertTrue(uni.called("Uni"))
        XCTAssertTrue(uni.called("university"))
        XCTAssertTrue(uni.called("College"))
        XCTAssertFalse(uni.called("the moon"))
        XCTAssertEqual(uni.names.first, "University")
    }

    func testAnUnnamedPlaceSaysWhatItIsWithoutACoordinate() {
        let noticed = MobilePlace(row(id: "B", name: "", named: false, visits: 4))!

        XCTAssertFalse(noticed.spoken.contains("53"))
        XCTAssertFalse(noticed.spoken.contains("-7"))
        XCTAssertTrue(noticed.spoken.contains("4 times"))
    }

    // MARK: resolving a fix, conservatively

    func testAFixInsideAPlaceNamesIt() {
        let verdict = PlaceResolution.read(fix(), in: [place()], at: Self.noon)

        XCTAssertEqual(verdict.place?.id, "A")
        XCTAssertEqual(verdict, .at(place()))
    }

    func testAFixNowhereKnownSaysSoRatherThanGuessingTheNearest() {
        let verdict = PlaceResolution.read(fix(54, -8), in: [place()], at: Self.noon)

        XCTAssertEqual(verdict, .somewhereElse)
    }

    /// The failure that matters: claiming home from a reading that cannot tell home from the road.
    func testAFixVaguerThanThePlaceIsNotEvidenceOfBeingInIt() {
        let verdict = PlaceResolution.read(fix(accuracy: 200), in: [place(radius: 80)], at: Self.noon)

        XCTAssertEqual(verdict, .somewhereElse)
    }

    func testAFixTooVagueToPlaceAtAllSaysHowVague() {
        let verdict = PlaceResolution.read(fix(accuracy: 400), in: [place()], at: Self.noon)

        XCTAssertEqual(verdict, .tooVague(400))
    }

    func testNoFixAtAllIsItsOwnAnswer() {
        XCTAssertEqual(PlaceResolution.read(nil, in: [place()], at: Self.noon), .noFix)
    }

    /// Two places the fix cannot separate must not be resolved by a coin toss.
    func testTwoPlacesTheFixCannotSeparateAreAmbiguous() {
        let one = place("A", "Flat", lat: 53, lon: -7, radius: 120)
        let two = place("B", "The Office", lat: 53.0002, lon: -7, radius: 120)

        let verdict = PlaceResolution.read(fix(53.0001, -7, accuracy: 100), in: [one, two], at: Self.noon)

        guard case .between(let both) = verdict else { return XCTFail("\(verdict)") }

        XCTAssertEqual(both.count, 2)
    }

    /// Overlapping is not the same as indistinguishable: a precise fix can still pick one.
    func testOverlappingPlacesAreStillSeparableByAPreciseFix() {
        let building = place("A", "The Building", lat: 53, lon: -7, radius: 150)
        let room = place("B", "The Workshop", lat: 53.0009, lon: -7, radius: 150)

        let verdict = PlaceResolution.read(fix(53, -7, accuracy: 10), in: [building, room], at: Self.noon)

        XCTAssertEqual(verdict.place?.id, "A")
    }

    /// A fix from an hour ago is not a claim about now.
    func testAStaleFixIsSaidInThePastTense() {
        let old = fix(at: Self.noon.addingTimeInterval(-3600))

        let verdict = PlaceResolution.read(old, in: [place()], at: Self.noon)

        guard case .lastAt(let place, let when) = verdict else { return XCTFail("\(verdict)") }

        XCTAssertEqual(place.id, "A")
        XCTAssertEqual(when, old.at)
    }

    // MARK: the wording, which must not overclaim

    func testWhereAmIUsesTheCategoryWhenTheOwnerSetOne() {
        let home = place("A", "22 Somewhere Road", category: "Home")

        let said = PlaceAnswers.whereAmI(.at(home))

        XCTAssertEqual(said, "You're at home, sir.")
        XCTAssertFalse(said.contains("Somewhere Road"))
    }

    func testWhereAmINamesThePlaceWhenThereIsNoCategory() {
        XCTAssertEqual(PlaceAnswers.whereAmI(.at(place("A", "University"))), "You're at University, sir.")
    }

    func testAStaleAnswerSaysWhenRatherThanClaimingNow() {
        let said = PlaceAnswers.whereAmI(
            .lastAt(place("A", "Home"), Self.noon.addingTimeInterval(-38 * 60)), at: Self.noon)

        XCTAssertTrue(said.contains("last placed you"))
        XCTAssertTrue(said.contains("38 minutes ago"))
        XCTAssertFalse(said.contains("You're at"))
    }

    func testAnAmbiguousAnswerNamesBothRatherThanPickingOne() {
        let said = PlaceAnswers.whereAmI(.between([place("A", "Flat"), place("B", "The Office")]))

        XCTAssertTrue(said.contains("Flat"))
        XCTAssertTrue(said.contains("The Office"))
        XCTAssertTrue(said.contains("can't separate"))
    }

    func testNoPermissionSaysWhyAndNotJustThatItFailed() {
        let said = PlaceAnswers.whereAmI(.noFix)

        XCTAssertTrue(said.contains("location access"))
    }

    func testAVagueAnswerSaysHowVagueSoTheOwnerCanJudgeIt() {
        XCTAssertTrue(PlaceAnswers.whereAmI(.tooVague(380)).contains("380 metres"))
    }

    func testAPlaceNobodyNamedIsAnsweredAsUnknownRatherThanAsNo() {
        let said = PlaceAnswers.amIAt("the dentist", .somewhereElse, asked: nil)

        XCTAssertTrue(said.contains("don't know anywhere called the dentist"))
    }

    func testAmIHomeIsYesOrNoAndNeverAMaybe() {
        let home = place("A", "Home")

        XCTAssertTrue(PlaceAnswers.amIAt("home", .at(home), asked: home).hasPrefix("Yes"))
        XCTAssertTrue(PlaceAnswers.amIAt("home", .somewhereElse, asked: home).hasPrefix("No"))
    }

    // MARK: a pattern is never stated as a fact

    private func routine(_ kind: String, _ subject: String, typical: Int, spread: Int = 15,
                         samples: Int = 12, confidence: Double = 0.9, day: String = "") -> MobileRoutine {
        MobileRoutine([
            "id": "\(kind):\(subject):\(day.isEmpty ? "any" : day)", "kind": kind, "subject": subject,
            "day": day, "typical": String(typical), "spread": String(spread),
            "samples": String(samples), "confidence": String(confidence),
            "reinforced": String(Int(Self.noon.timeIntervalSince1970))
        ])!
    }

    func testARoutineIsHedgedEveryTime() {
        let said = PlaceAnswers.describe(routine("Arriving", "Home", typical: 18 * 60 + 5))

        XCTAssertTrue(said.contains("usually"))
        XCTAssertTrue(said.contains("between about"))
        XCTAssertTrue(said.contains("17:50"))
        XCTAssertTrue(said.contains("18:20"))
    }

    func testAnObservationIsStatedPlainlyBecauseItIsOne() {
        let said = PlaceAnswers.arrivedAt(Self.noon.addingTimeInterval(-1800), place("A", "Home"), at: Self.noon)

        XCTAssertFalse(said.contains("usually"))
        XCTAssertTrue(said.contains("You got to Home at"))
        XCTAssertTrue(said.contains("30 minutes ago"))
    }

    func testAWindowThatWrapsMidnightIsStillAClockTime() {
        let said = PlaceAnswers.describe(routine("Leaving", "Home", typical: 10, spread: 30))

        XCTAssertTrue(said.contains("23:40"))
        XCTAssertFalse(said.contains("-"))
    }

    func testAPatternAboutAnotherTimeOfDayIsNotAnAnswer() {
        let dawn = routine("Arriving", "Work", typical: 4 * 60)

        let said = PlaceAnswers.usually([dawn], at: Self.noon)

        XCTAssertTrue(said.contains("Nothing I've learned"))
    }

    func testTheNearestPatternToNowIsTheOneOffered() {
        let calendar = Calendar.current
        let minutes = calendar.component(.hour, from: Self.noon) * 60 + calendar.component(.minute, from: Self.noon)

        let near = routine("Arriving", "Work", typical: minutes + 10)
        let far = routine("Arriving", "Home", typical: (minutes + 600) % 1440, confidence: 0.99)

        XCTAssertTrue(PlaceAnswers.usually([far, near], at: Self.noon).contains("Work"))
    }

    // MARK: the day this phone keeps for itself

    func testMinutesApartWrapsAroundTheClockFace() {
        XCTAssertEqual(PlaceAnswers.apart(10, 1430), 20)
        XCTAssertEqual(PlaceAnswers.apart(600, 630), 30)
    }

    func testTheDaysPlacesAreListedInOrderAndNamed() {
        let said = PlaceAnswers.earlier([
            (place("A", "Home"), Self.noon.addingTimeInterval(-7200)),
            (place("B", "University"), Self.noon.addingTimeInterval(-3600))
        ])

        XCTAssertTrue(said.contains("Home at"))
        XCTAssertTrue(said.contains("then University at"))
    }

    func testNothingRecordedIsSaidPlainly() {
        XCTAssertTrue(PlaceAnswers.earlier([]).contains("nothing recorded"))
    }

    // MARK: answering, end to end, without the PC

    func testWhereAmIIsAnsweredFromTheLocalSubsetAlone() {
        let evidence = PlaceAnswers.Evidence(
            fix: fix(), places: [place("A", "22 Somewhere Road", category: "Home")], moment: Self.noon)

        XCTAssertEqual(PlaceAnswers.answer(.whereAmI, named: nil, from: evidence), "You're at home, sir.")
    }

    func testAmIHomeFindsTheHomePlaceByCategoryWhenItWasNeverRenamed() {
        let evidence = PlaceAnswers.Evidence(
            fix: fix(), places: [place("A", "22 Somewhere Road", category: "Home")], moment: Self.noon)

        let said = PlaceAnswers.answer(.amIAt, named: "home", from: evidence)

        XCTAssertTrue(said.hasPrefix("Yes"))
    }

    func testWhenDidIGetHereUsesThisPhonesOwnRecord() {
        let arrived = Self.noon.addingTimeInterval(-5400)

        let evidence = PlaceAnswers.Evidence(
            fix: fix(),
            places: [place("A", "Home")],
            visits: [MobileVisit(placeId: "A", from: arrived, to: nil, fixes: 9)],
            moment: Self.noon)

        let said = PlaceAnswers.answer(.arrived, named: nil, from: evidence)

        XCTAssertTrue(said.contains("You got to Home at"))
    }

    func testHowLongHaveIBeenHereCountsFromTheOpenVisit() {
        let evidence = PlaceAnswers.Evidence(
            fix: fix(),
            places: [place("A", "Home")],
            visits: [MobileVisit(placeId: "A", from: Self.noon.addingTimeInterval(-3600), to: nil, fixes: 5)],
            moment: Self.noon)

        XCTAssertTrue(PlaceAnswers.answer(.howLong, named: nil, from: evidence).contains("1 hour"))
    }

    func testWhenDidILeaveHomeUsesTheClosedVisit() {
        let left = Self.noon.addingTimeInterval(-7200)

        let evidence = PlaceAnswers.Evidence(
            fix: fix(54, -8),
            places: [place("A", "Home")],
            visits: [MobileVisit(placeId: "A", from: left.addingTimeInterval(-3600), to: left, fixes: 4)],
            moment: Self.noon)

        XCTAssertTrue(PlaceAnswers.answer(.left, named: "home", from: evidence).contains("You left Home at"))
    }

    func testAQuestionAboutAPlaceWithNoRecordSaysSoRatherThanInventingOne() {
        let evidence = PlaceAnswers.Evidence(fix: fix(), places: [place("A", "Home")], moment: Self.noon)

        XCTAssertTrue(PlaceAnswers.answer(.left, named: "home", from: evidence).contains("no record"))
    }

    // MARK: the day's shape, kept from fixes

    @MainActor
    func testStayingPutIsOneVisitRatherThanAnAfternoonOfArrivals() {
        let day = MobileDay.shared
        day.forget()
        defer { day.forget() }

        let places = [place("A", "Home")]

        for minute in 0..<10 {
            day.saw(fix(at: Self.noon.addingTimeInterval(Double(minute) * 60)), in: places, at: Self.noon)
        }

        XCTAssertEqual(day.visits.count, 1)
        XCTAssertEqual(day.visits[0].fixes, 10)
        XCTAssertTrue(day.visits[0].open)
        XCTAssertEqual(day.hereSince, Self.noon)
    }

    @MainActor
    func testLeavingClosesTheVisitAndArrivingOpensAnother() {
        let day = MobileDay.shared
        day.forget()
        defer { day.forget() }

        let places = [place("A", "Home"), place("B", "University", lat: 54, lon: -8)]

        day.saw(fix(at: Self.noon), in: places, at: Self.noon)
        day.saw(fix(50, -3, at: Self.noon.addingTimeInterval(1800)), in: places, at: Self.noon)
        day.saw(fix(54, -8, at: Self.noon.addingTimeInterval(3600)), in: places, at: Self.noon)

        XCTAssertEqual(day.visits.count, 2)
        XCTAssertNotNil(day.visits[0].to)
        XCTAssertEqual(day.visits[1].placeId, "B")
        XCTAssertTrue(day.visits[1].open)
    }

    /// An uncertain fix is not evidence of having left anywhere.
    @MainActor
    func testAVagueFixLeavesTheDayExactlyAsItWas() {
        let day = MobileDay.shared
        day.forget()
        defer { day.forget() }

        let places = [place("A", "Home")]

        day.saw(fix(at: Self.noon), in: places, at: Self.noon)
        day.saw(fix(accuracy: 900, at: Self.noon.addingTimeInterval(600)), in: places, at: Self.noon)

        XCTAssertEqual(day.visits.count, 1)
        XCTAssertTrue(day.visits[0].open, "a fix too vague to place is not a departure")
    }

    // MARK: the store

    @MainActor
    func testAppliedRowsAreIdempotentAndTheCursorOnlyGoesForward() {
        let book = MobilePlaceBook.shared
        book.forget()
        defer { book.forget() }

        let rows = [row(id: "A", name: "Home", revision: 5)]

        XCTAssertEqual(book.apply(rows, through: 5), 1)
        XCTAssertEqual(book.apply(rows, through: 5), 0, "the same batch again changes nothing")
        XCTAssertEqual(book.places.count, 1)
        XCTAssertEqual(book.revision, 5)

        _ = book.apply([], through: 2)
        XCTAssertEqual(book.revision, 5, "a cursor must not rewind and cause a resend")
    }

    @MainActor
    func testANewerRevisionReplacesAPlaceAndAnOlderOneIsIgnored() {
        let book = MobilePlaceBook.shared
        book.forget()
        defer { book.forget() }

        book.apply([row(id: "A", name: "Uni", revision: 5)])
        book.apply([row(id: "A", name: "University", revision: 9)])
        book.apply([row(id: "A", name: "Something Stale", revision: 3)])

        XCTAssertEqual(book.places.count, 1)
        XCTAssertEqual(book.place("A")?.name, "University")
    }

    @MainActor
    func testATombstoneRemovesThePlace() {
        let book = MobilePlaceBook.shared
        book.forget()
        defer { book.forget() }

        book.apply([row(id: "A", name: "Home", revision: 5)])
        book.apply([["id": "A", "gone": "1", "revision": "6"]])

        XCTAssertTrue(book.places.isEmpty)
        XCTAssertEqual(book.revision, 6)
    }

    @MainActor
    func testThePhoneKeepsItsOwnCapWhateverTheSenderSends() {
        let book = MobilePlaceBook.shared
        book.forget()
        defer { book.forget() }

        let many = (0..<80).map { index in
            row(id: "P\(index)", name: "Place \(index)", revision: index + 1,
                lastSeen: Self.noon.addingTimeInterval(Double(-index) * 3600))
        }

        book.apply(many)

        XCTAssertEqual(book.places.count, MobilePlaceProtocol.most)

        // And the ones kept are the most recently seen, deterministically.
        XCTAssertEqual(book.places.first?.id, "P0")
    }

    @MainActor
    func testTheHomePlaceIsFoundByCategoryOrByName() {
        let book = MobilePlaceBook.shared
        book.forget()
        defer { book.forget() }

        book.apply([row(id: "A", name: "22 Somewhere Road", revision: 1, category: "Home")])

        XCTAssertEqual(book.home?.id, "A")
    }

    @MainActor
    func testRoutinesAreReplacedWholeBecauseAnAbandonedPatternHasNoTombstone() {
        let book = MobileRoutineBook.shared
        book.forget()
        defer { book.forget() }

        book.replace([[
            "id": "Arriving:home:any", "kind": "Arriving", "subject": "Home",
            "typical": "1085", "spread": "15", "samples": "12", "confidence": "0.9", "reinforced": "0"
        ]], revision: 4)

        XCTAssertEqual(book.routines.count, 1)

        book.replace([], revision: 5)

        XCTAssertTrue(book.routines.isEmpty, "a pattern the PC no longer draws must stop being asserted")
        XCTAssertEqual(book.revision, 5)
    }

    // MARK: which question was asked

    func testTheSentencesTheOwnerActuallySaysAreRecognised() {
        func asked(_ sentence: String) -> Whereabouts.Question? {
            guard case .whereabouts(let question, _) = LocalCapability.of(sentence) else { return nil }
            return question
        }

        XCTAssertEqual(asked("where am I"), .whereAmI)
        XCTAssertEqual(asked("am I home"), .amIAt)
        XCTAssertEqual(asked("am I at university"), .amIAt)
        XCTAssertEqual(asked("when did I get here"), .arrived)
        XCTAssertEqual(asked("when did I leave home"), .left)
        XCTAssertEqual(asked("how long have I been here"), .howLong)
        XCTAssertEqual(asked("where was I earlier"), .earlier)
        XCTAssertEqual(asked("where do I normally go around now"), .usually)
    }

    func testAPlaceNamedInTheSentenceIsPickedUp() {
        guard case .whereabouts(_, let named) = LocalCapability.of("am I at university") else {
            return XCTFail("not recognised")
        }

        XCTAssertEqual(named, "university")
    }

    /// A question about where the owner is must not be routed to the PC, which has a staler fix.
    func testAWhereaboutsQuestionStaysOnThisPhoneEvenWithThePcUp() {
        var state = MobileCapabilities.NodeState()
        state.pcAnswering = true

        let decision = MobileCapabilities.decide("where am I", devices: [], state: state)

        guard case .localMobile(let capability) = decision.lane else { return XCTFail("\(decision.lane)") }
        guard case .whereabouts = capability else { return XCTFail("\(capability)") }

        XCTAssertNil(decision.fallback)
    }

    func testASmartHomeCommandIsStillRoutedToThePcWhenItIsUp() {
        var state = MobileCapabilities.NodeState()
        state.pcAnswering = true

        let light = StandbyDevice([
            "id": "bedroom_main_light", "name": "Bedroom Light", "room": "Bedroom", "kind": "light",
            "provider": "SwitchBot", "providerDeviceId": "C271D2A08E4F", "preferPress": false
        ])!

        let decision = MobileCapabilities.decide("turn the bedroom light off", devices: [light], state: state)

        XCTAssertEqual(decision.lane, .pcPrime)
        XCTAssertNotNil(decision.fallback)
    }

    func testSentinel() {}
}

/// Naming where you are - programme §31.
///
/// The owner's word is authoritative, so it has to take effect without a PC and without a button,
/// and the recogniser has to be narrow enough that "this is ridiculous" does not rename a house.
final class PlaceNamingTests: XCTestCase {
    private func named(_ sentence: String) -> String? {
        guard case .namePlace(let name) = LocalCapability.of(sentence) else { return nil }

        return name
    }

    func testTheWaysTheOwnerWouldSayItAreRecognised() {
        XCTAssertEqual(named("this is home"), "home")
        XCTAssertEqual(named("this is my house"), "house")
        XCTAssertEqual(named("call this place university"), "university")
        XCTAssertEqual(named("call this place the workshop"), "workshop")
        XCTAssertEqual(named("this place is the dentist"), "dentist")
    }

    /// The reason the recogniser is narrow rather than clever.
    ///
    /// The first version took any "this is X" and read "this is ridiculous" as an instruction to
    /// rename the owner's house. A bare "this is X" is now accepted only when X is a word that is
    /// a place on its own; anything else has to say "place", which is what separates an
    /// instruction from a remark.
    func testAnOrdinaryRemarkDoesNotRenameAnywhere() {
        XCTAssertNil(named("this is ridiculous"))
        XCTAssertNil(named("this is going well"))
        XCTAssertNil(named("this is a disaster"))
        XCTAssertNil(named("call mum"))
        XCTAssertNil(named("call this a day"))
        XCTAssertNil(named("where am I"))
        XCTAssertNil(named("this is"))
    }

    func testNamingIsNotTreatedAsADeviceCommand() {
        guard case .namePlace = LocalCapability.of("this is home") else { return XCTFail("not recognised") }

        XCTAssertFalse(LocalCapability.of("this is home")!.isADeviceCommand)
        XCTAssertTrue(LocalCapability.of("this is home")!.answeredBestHere)
    }

    @MainActor
    func testANameTakesEffectAtOnceAndIsRememberedAsUnsent() {
        let book = MobilePlaceBook.shared
        book.forget()
        defer { book.forget() }

        book.apply([[
            "id": "A", "name": "", "named": "0", "revision": "4",
            "lat": "53", "lon": "-7", "radius": "80", "visits": "6"
        ]])

        book.rename("A", to: "Home")

        XCTAssertEqual(book.place("A")?.name, "Home")
        XCTAssertEqual(book.place("A")?.named, true)
        XCTAssertEqual(book.place("A")?.confidence, 1)
        XCTAssertEqual(book.unsent["A"], "Home")

        // The revision is untouched, so the PC's next word on this place still wins.
        XCTAssertEqual(book.place("A")?.revision, 4)
    }

    @MainActor
    func testSayingItTwiceLeavesOneInstruction() {
        let book = MobilePlaceBook.shared
        book.forget()
        defer { book.forget() }

        book.apply([["id": "A", "name": "", "named": "0", "revision": "1", "lat": "53", "lon": "-7"]])

        book.rename("A", to: "Hom")
        book.rename("A", to: "Home")

        XCTAssertEqual(book.unsent.count, 1)
        XCTAssertEqual(book.unsent["A"], "Home")
    }

    @MainActor
    func testOnceSentItIsNoLongerPending() {
        let book = MobilePlaceBook.shared
        book.forget()
        defer { book.forget() }

        book.apply([["id": "A", "name": "", "named": "0", "revision": "1", "lat": "53", "lon": "-7"]])
        book.rename("A", to: "Home")
        book.sent("A")

        XCTAssertTrue(book.unsent.isEmpty)
    }

    func testTheConfirmationSaysWhetherThePcHasItYet() {
        XCTAssertTrue(PlaceAnswers.named("Home", waiting: true).contains("when it's next up"))
        XCTAssertFalse(PlaceAnswers.named("Home", waiting: false).contains("next up"))
    }

    func testNamingNowhereExplainsRatherThanFailing() {
        XCTAssertTrue(PlaceAnswers.cannotName(.somewhereElse).contains("stopped here a few times"))
        XCTAssertTrue(PlaceAnswers.cannotName(.noFix).contains("location access"))
        XCTAssertTrue(PlaceAnswers.cannotName(.tooVague(300)).contains("300 metres"))
    }

    func testSentinel() {}
}
