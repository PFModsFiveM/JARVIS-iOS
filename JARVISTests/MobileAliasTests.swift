import XCTest
@testable import JARVIS

/// What the owner's words mean, on the phone - priority §4D and §6A.
///
/// Resolving a word is in the path of every command, so a phone that had to ask the PC what "the
/// bedroom lamp" means could not switch a light with the PC asleep - which is the entire case the
/// independence work exists for. The phone resolves and does not decide: the strength comes from
/// the PC, which has the evidence, and the phone's only judgement is how to word what it says.
@MainActor
final class MobileAliasTests: XCTestCase {
    private var folder: URL!
    private var store: URL!

    private let light = "switchbot:bedroom-light"
    private let lamp = "switchbot:desk-lamp"

    override func setUp() {
        super.setUp()
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jarvis-aliases-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = folder.appendingPathComponent("aliases.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    private func book() -> MobileAliases { MobileAliases(store: store) }

    private func alias(
        _ said: String,
        _ entity: String,
        kind: MobileEntityKind = .device,
        strength: MobileEvidence = .veryStrong,
        trusted: Bool = true,
        count: Int = 1,
        revision: Int64 = 1
    ) -> MobileAlias {
        MobileAlias(
            said: MobileAliases.normalise(said), entity: entity, kind: kind, strength: strength,
            trusted: trusted, confidence: 1, count: count, revision: revision)
    }

    // MARK: - normalising, which has to match the PC exactly

    func testOneWordForOneThingHoweverItWasSaid() {
        XCTAssertEqual(MobileAliases.normalise("Bedroom Lamp"), "bedroom lamp")
        XCTAssertEqual(MobileAliases.normalise("  the bedroom   lamp "), "bedroom lamp")
        XCTAssertEqual(MobileAliases.normalise("my bedroom lamp"), "bedroom lamp")
        XCTAssertEqual(MobileAliases.normalise("a bedroom lamp"), "bedroom lamp")
    }

    func testASingleWordKeepsItsArticle() {
        // Dropping it would leave nothing, which is a different bug on each side of the bridge.
        XCTAssertEqual(MobileAliases.normalise("the"), "the")
        XCTAssertEqual(MobileAliases.normalise("My"), "my")
    }

    func testNothingIsStemmedOrExpanded() {
        // "light" and "lights" meaning different things happens in real houses. If the two sides
        // ever disagreed here, the phone and the PC would resolve one sentence differently - which
        // is the single failure this whole design exists to make impossible.
        XCTAssertNotEqual(MobileAliases.normalise("light"), MobileAliases.normalise("lights"))
        XCTAssertNotEqual(MobileAliases.normalise("lamp"), MobileAliases.normalise("light"))
    }

    // MARK: - resolving

    func testWhatThePcLearnedThisPhoneResolves() {
        let held = book()
        held.apply([alias("bedroom lamp", light)], forgotten: [], through: 1)

        let verdict = held.resolve("the Bedroom Lamp")

        XCTAssertTrue(verdict.resolved)
        XCTAssertEqual(verdict.alias?.entity, light)
    }

    func testAPartialPhraseResolvesToTheThingItNames() {
        let held = book()
        held.apply([alias("bedroom light", light)], forgotten: [], through: 1)

        XCTAssertEqual(held.resolve("turn off the bedroom light please").alias?.entity, light)
    }

    func testEvidenceThePcDoesNotActOnIsNotActedOnHereEither() {
        let held = book()
        held.apply([alias("whatsit", light, strength: .weak, trusted: false)], forgotten: [], through: 1)

        let verdict = held.resolve("whatsit")

        XCTAssertFalse(verdict.resolved)
        XCTAssertTrue(verdict.spoken.contains("not sure enough"))
    }

    func testTwoThingsEquallyWellDescribedAreAnsweredAsTwo() {
        let held = book()
        held.apply(
            [alias("light", light), alias("lights", lamp, revision: 2)],
            forgotten: [], through: 2)

        let verdict = held.resolve("the lights are on")

        XCTAssertFalse(verdict.resolved)

        guard case .several(let all) = verdict else {
            return XCTFail("two equally good candidates should be answered as two")
        }

        XCTAssertGreaterThanOrEqual(all.count, 2)
        XCTAssertTrue(verdict.spoken.contains("different things"))
    }

    func testAskingForADeviceDoesNotReturnAProject() {
        let held = book()
        held.apply(
            [alias("tow company", "project:tow", kind: .project)],
            forgotten: [], through: 1)

        let verdict = held.resolve("tow company", kind: .device)

        XCTAssertFalse(verdict.resolved)
        XCTAssertTrue(verdict.spoken.contains("project"))
    }

    func testAnUnknownPhraseIsSaidToBeUnknown() {
        let verdict = book().resolve("the thingamajig")

        XCTAssertFalse(verdict.resolved)
        XCTAssertTrue(verdict.spoken.contains("don't know"))
    }

    func testNothingSaidResolvesToNothing() {
        XCTAssertFalse(book().resolve("").resolved)
        XCTAssertFalse(book().resolve("   ").resolved)
    }

    // MARK: - how it is worded

    func testTheOwnersOwnWordIsStatedAndAnInferenceIsHedged() {
        let held = book()
        held.apply(
            [alias("bedroom lamp", light, strength: .veryStrong),
             alias("the usual", "project:tow", kind: .project, strength: .medium, revision: 2)],
            forgotten: [], through: 2)

        XCTAssertFalse(held.resolve("bedroom lamp").spoken.contains("I think"))
        XCTAssertTrue(held.resolve("the usual").spoken.contains("I think"))
    }

    func testStrengthOrdersTheSameWayAsThePcs() {
        XCTAssertTrue(MobileEvidence.veryStrong > MobileEvidence.strong)
        XCTAssertTrue(MobileEvidence.strong > MobileEvidence.medium)
        XCTAssertTrue(MobileEvidence.medium > MobileEvidence.weak)
    }

    func testTheStrengthNamesMatchThePcs() {
        XCTAssertEqual(MobileEvidence.veryStrong.rawValue, "VeryStrong")
        XCTAssertEqual(MobileEvidence.strong.rawValue, "Strong")
        XCTAssertEqual(MobileEvidence.medium.rawValue, "Medium")
        XCTAssertEqual(MobileEvidence.weak.rawValue, "Weak")
    }

    // MARK: - catching up

    func testAReplayedRowChangesNothing() {
        let held = book()
        held.apply([alias("the lamp", lamp, revision: 4)], forgotten: [], through: 4)
        held.apply([alias("the lamp", light, revision: 2)], forgotten: [], through: 4)

        XCTAssertEqual(held.resolve("the lamp").alias?.entity, lamp)
    }

    func testAWordTheOwnerTookBackIsForgottenHereToo() {
        let held = book()
        held.apply([alias("bedroom lamp", light)], forgotten: [], through: 1)
        held.apply([], forgotten: ["The Bedroom Lamp"], through: 2)

        XCTAssertFalse(held.resolve("bedroom lamp").resolved)
    }

    func testEveryWordForOneThingCanBeListed() {
        let held = book()
        held.apply(
            [alias("bedroom lamp", light),
             alias("bedroom light", light, revision: 2),
             alias("desk lamp", lamp, revision: 3)],
            forgotten: [], through: 3)

        XCTAssertEqual(held.words(for: light).count, 2)
        XCTAssertEqual(held.words(for: lamp).count, 1)
    }

    func testWhatWasLearnedSurvivesARestart() {
        let first = book()
        first.apply([alias("bedroom lamp", light, count: 2, revision: 7)], forgotten: [], through: 7)

        let again = MobileAliases(store: store)

        XCTAssertEqual(again.revision, 7)
        XCTAssertEqual(again.resolve("the bedroom lamp").alias?.entity, light)
        XCTAssertEqual(again.resolve("bedroom lamp").alias?.count, 2)
    }

    func testFailingToCatchUpKeepsTheWordsItAlreadyKnows() {
        let held = book()
        held.apply([alias("bedroom lamp", light)], forgotten: [], through: 1)
        held.couldNotCatchUp("the PC isn't answering")

        // The right behaviour rather than a silent failure: the words the phone knows are still
        // the words the owner used.
        XCTAssertEqual(held.failed, "the PC isn't answering")
        XCTAssertTrue(held.resolve("bedroom lamp").resolved)
    }

    func testTheStoreIsBoundedAndKeepsWhatTheOwnerSaid() {
        let held = book()
        held.apply([alias("bedroom lamp", light, strength: .veryStrong)], forgotten: [], through: 1)

        let filler = (0..<(MobileAliases.most + 40)).map {
            alias("thing \($0)", "entity:\($0)", strength: .weak, trusted: false, revision: Int64($0 + 2))
        }

        held.apply(filler, forgotten: [], through: Int64(filler.count + 2))

        XCTAssertLessThanOrEqual(held.aliases.count, MobileAliases.most)
        XCTAssertTrue(held.resolve("bedroom lamp").resolved, "a guess must not evict what the owner said")
    }

    func testSentinel() { XCTAssertTrue(true) }
}
