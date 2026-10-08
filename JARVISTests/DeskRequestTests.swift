import XCTest
@testable import JARVIS

/// "Jarvis, boot my PC and open my latest Blender project" - priority §4, the phone's half.
///
/// Two requests with a gap between them. The phone can send the wake packet; nothing can open a
/// project until the machine is up, signed in and running JARVIS. The design this replaces holds
/// a network request open across that gap, which fails on every dropped connection and every
/// phone that gets locked and put in a pocket - so the phone keeps the intention itself and offers
/// it on the first connection that succeeds.
///
/// No wake packet is sent by any of this.
final class DeskRequestTests: XCTestCase {

    private var store: UserDefaults!
    private var suite = ""

    override func setUp() {
        super.setUp()

        // A suite of its own, so nothing here touches the app's own saved state.
        suite = "jarvis.tests.desk.\(UUID().uuidString)"
        store = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        store.removePersistentDomain(forName: suite)
        store = nil
        super.tearDown()
    }

    // MARK: The sentence

    func testTheCompoundRequestIsOnePieceOfWork() {
        for said in ["boot my pc and open my latest blender project",
                     "wake the computer and load my last project",
                     "turn my pc on and open my blender file",
                     "jarvis, start the workstation and resume my project"] {
            guard case .prepareDesk = LocalCapability.of(said) else {
                return XCTFail("\"\(said)\" should be one piece of work")
            }
        }
    }

    /// A bare wake stays a bare wake. Treating it as a compound would open a project the owner
    /// never mentioned.
    func testABareWakeIsStillABareWake() {
        for said in ["wake my pc", "turn the computer on", "boot the workstation", "get my rig online"] {
            guard case .wake = LocalCapability.of(said) else {
                return XCTFail("\"\(said)\" should be a bare wake")
            }
        }
    }

    /// A wake with an ordinary second half is also a bare wake: the PC will hear the rest itself
    /// once it is up, and there is nothing to keep.
    func testAWakeWithSomethingElseAfterItIsStillAWake() {
        for said in ["wake my pc and tell me the weather",
                     "boot the computer and turn the lights on"] {
            guard case .wake = LocalCapability.of(said) else {
                return XCTFail("\"\(said)\" should be a bare wake")
            }
        }
    }

    func testTheNamedProjectIsCarried() {
        guard case .prepareDesk(let project) =
                LocalCapability.of("boot my pc and open the tow yard project") else {
            return XCTFail("not read as one piece of work")
        }

        XCTAssertEqual(project, "tow yard")
    }

    /// "My latest project" names nothing in particular, and the PC resolves that for itself from
    /// evidence this phone does not have.
    func testTheUsualPhrasingNamesNothingInParticular() {
        guard case .prepareDesk(let project) =
                LocalCapability.of("boot my pc and open my latest blender project") else {
            return XCTFail("not read as one piece of work")
        }

        XCTAssertTrue(project.isEmpty, project)
    }

    func testTheActionNameIsTheOneThePCWouldUse() {
        XCTAssertEqual(LocalCapability.prepareDesk(project: "").action, "workspace.prepare")
    }

    // MARK: What may be sent

    /// §4C, on this side too. A project name that could be read as a path must not become one,
    /// and the phone trims before the PC refuses - two layers, because this is the owner's own
    /// voice being transcribed and the PC is where a wrong one is caught.
    func testAProjectNameCannotCarryAPathOrACommand() {
        for said in [#"C:\Windows\System32\cmd.exe"#,
                     "tow yard & shutdown /s",
                     "../../etc/passwd",
                     #"\\server\share"#,
                     "tow;yard",
                     "$(rm -rf /)"] {
            let plain = DeskRequest.plain(said)

            for mark in ["\\", "/", ":", ";", "|", "&", "$", "(", ")", "."] {
                XCTAssertFalse(plain.contains(mark), "\(mark) survived in: \(plain)")
            }
        }
    }

    func testAnOrdinaryNameSurvivesIntact() {
        XCTAssertEqual(DeskRequest.plain("Salls Digital Den"), "Salls Digital Den")
        XCTAssertEqual(DeskRequest.plain("low-end apartment"), "low-end apartment")
        XCTAssertEqual(DeskRequest.plain("dom's kitchen"), "dom's kitchen")
    }

    func testANameLongerThanANameIsCutRatherThanSent() {
        XCTAssertEqual(DeskRequest.plain(String(repeating: "a", count: 200)).count, 80)
    }

    // MARK: Keeping it

    @MainActor
    func testWhatIsHeldIsThereAfterTheAppRestarts() {
        let requests = DeskRequests(store: store)
        requests.hold(DeskRequest(project: "tow yard"))

        // A new object, reading the same store - which is what a restart is.
        let after = DeskRequests(store: store)

        XCTAssertEqual(after.waiting?.project, "tow yard")
        XCTAssertNotNil(after.toOffer())
    }

    @MainActor
    func testARequestTheOwnerHasMovedOnFromIsNotOffered() {
        let requests = DeskRequests(store: store)
        let now = Date()
        requests.hold(DeskRequest(project: "tow yard", now: now))

        XCTAssertNotNil(requests.toOffer(now.addingTimeInterval(60)))

        // Three hours later the machine finally comes up. Opening Blender then would act on an
        // intention the owner has moved on from.
        XCTAssertNil(requests.toOffer(now.addingTimeInterval(3 * 60 * 60)))

        // And it is dropped rather than left to be reconsidered.
        XCTAssertNil(requests.waiting)
    }

    @MainActor
    func testAskingTwiceMeansOnceRatherThanTwice() {
        let requests = DeskRequests(store: store)

        requests.hold(DeskRequest(project: "tow yard"))
        requests.hold(DeskRequest(project: "kitchen"))

        // One, not a queue: the owner asking again means they want it once, and the second
        // asking is the one they meant.
        XCTAssertEqual(requests.waiting?.project, "kitchen")
    }

    @MainActor
    func testItIsForgottenOnceTheDeskHasTakenItOn() {
        let requests = DeskRequests(store: store)
        requests.hold(DeskRequest(project: "tow yard"))

        requests.forget()

        XCTAssertNil(requests.toOffer())
        XCTAssertNil(DeskRequests(store: store).waiting)
    }

    @MainActor
    func testEveryRequestHasItsOwnId() {
        let one = DeskRequest(project: "tow yard")
        let two = DeskRequest(project: "tow yard")

        // The id is what makes a request idempotent on the PC, so two askings must not share one.
        XCTAssertNotEqual(one.taskId, two.taskId)
    }

    @MainActor
    func testTheIdIsSomethingThePCWillAccept() {
        // The PC's own check is hyphens, dots, underscores and alphanumerics, bounded at 64. A
        // UUID already is that; asserting it here means a change to either end breaks loudly.
        let id = DeskRequest(project: "").taskId

        XCTAssertLessThanOrEqual(id.count, 64)
        XCTAssertNil(id.rangeOfCharacter(from: CharacterSet(charactersIn: "0123456789ABCDEFabcdef-").inverted))
    }

    // MARK: What it says

    func testNothingClaimsTheProjectIsOpenYet() {
        // Wake-on-LAN has no reply and the project cannot be open before the machine is. Both
        // halves of what is said are about requests having gone, not about outcomes.
        let sending = MobilePhrases.deskIsBeingPrepared("DOM-PC", project: "tow yard")

        XCTAssertTrue(sending.lowercased().contains("sending"), sending)
        XCTAssertTrue(sending.contains("tow yard"), sending)
        XCTAssertFalse(sending.lowercased().contains("is open"), sending)
        XCTAssertFalse(sending.lowercased().contains("i've opened"), sending)

        let taken = MobilePhrases.deskHasTakenItOn("DOM-PC")

        XCTAssertFalse(taken.lowercased().contains("is open"), taken)
        XCTAssertTrue(taken.contains("DOM-PC"), taken)
    }

    func testWithNoWayToWakeItSaysSoRatherThanHoldingARequest() {
        let said = MobilePhrases.cannotPrepareTheDesk("DOM-PC")

        XCTAssertTrue(said.contains("DOM-PC"), said)
        XCTAssertTrue(said.lowercased().contains("can't wake"), said)
    }

    func testTheUnnamedProjectIsDescribedRatherThanLeftBlank() {
        let said = MobilePhrases.deskIsBeingPrepared("DOM-PC", project: "")

        XCTAssertTrue(said.lowercased().contains("last on"), said)
        XCTAssertFalse(said.contains("  "), said)
    }
}
