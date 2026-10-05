import XCTest
@testable import JARVIS

/// Which kinds of notification reach this phone - priority §7A and §7B.
///
/// The settings screen this replaces was one switch, and one switch is the switch the owner turns
/// off. They want fewer interruptions about sync queues and the same number about somebody at the
/// door, and with only an on/off there is no way to say that.
@MainActor
final class MobileNoticeCategoryTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "jarvis-notices-\(UUID().uuidString)")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaults.description)
        super.tearDown()
    }

    private func settings() -> NoticeSettings { NoticeSettings(defaults: defaults) }

    func testEveryNoticeKindThisAppMakesHasACategory() {
        for kind in NoticeKind.allCases {
            let category = MobileNoticeCategory.of(kind)

            // Nothing falls through to "everything else". A kind this app makes is a kind
            // somebody decided about.
            XCTAssertNotEqual(category, .other, "\(kind) has no category")
        }
    }

    func testFootageIsSecurityBecauseThatIsWhatItIsAbout() {
        XCTAssertEqual(MobileNoticeCategory.of(.footageArrived), .security)
        XCTAssertEqual(MobileNoticeCategory.of(.security), .security)
        XCTAssertEqual(MobileNoticeCategory.of(.pcAway), .pcState)
        XCTAssertEqual(MobileNoticeCategory.of(.batteryLow), .devicePower)
        XCTAssertEqual(MobileNoticeCategory.of(.syncStuck), .sync)
    }

    func testTheCategoryNamesMatchThePcs() {
        // The owner's setting has to mean the same thing on both screens.
        XCTAssertEqual(MobileNoticeCategory.security.rawValue, "Security")
        XCTAssertEqual(MobileNoticeCategory.pcState.rawValue, "PcState")
        XCTAssertEqual(MobileNoticeCategory.devicePower.rawValue, "DevicePower")
        XCTAssertEqual(MobileNoticeCategory.smartHome.rawValue, "SmartHome")
        XCTAssertEqual(MobileNoticeCategory.routineSuggestion.rawValue, "RoutineSuggestion")
    }

    func testEveryCategoryHasWordsTheOwnerCanActOn() {
        for category in MobileNoticeCategory.allCases {
            XCTAssertFalse(category.name.isEmpty)
            XCTAssertGreaterThan(category.detail.count, 30, "\(category) needs a usable sentence")
            XCTAssertTrue(category.detail.hasSuffix("."))
        }
    }

    func testOnlySecurityInterruptsAndOnlySecurityCannotBeSwitchedOff() {
        for category in MobileNoticeCategory.allCases {
            XCTAssertEqual(category.interrupts, category == .security)
            XCTAssertEqual(category.optional, category != .security)
        }
    }

    func testTheQuietThreeAreOffOnThisPhoneByDefault() {
        let held = settings()

        // Stricter than the PC's default, on purpose: a notification is more intrusive than a
        // sentence spoken in a room the owner is already in.
        XCTAssertFalse(held.wants(.sync))
        XCTAssertFalse(held.wants(.routineSuggestion))
        XCTAssertFalse(held.wants(.learning))

        XCTAssertTrue(held.wants(.security))
        XCTAssertTrue(held.wants(.pcState))
        XCTAssertTrue(held.wants(.devicePower))
        XCTAssertTrue(held.wants(.smartHome))
    }

    func testTurningOneOffSilencesItAndNothingElse() {
        let held = settings()

        XCTAssertTrue(held.set(.devicePower, wanted: false))

        XCTAssertFalse(held.wanted(.batteryLow))
        XCTAssertTrue(held.wanted(.pcAway))
    }

    func testSecurityCannotBeSwitchedOff() {
        let held = settings()

        XCTAssertFalse(held.set(.security, wanted: false))
        XCTAssertTrue(held.wants(.security))
        XCTAssertTrue(held.wanted(.security))
        XCTAssertTrue(held.wanted(.footageArrived))
    }

    func testTurningAQuietOneOnWorks() {
        let held = settings()

        XCTAssertTrue(held.set(.sync, wanted: true))
        XCTAssertTrue(held.wanted(.syncStuck))
    }

    func testOnlyWhatTheOwnerChangedIsStored() {
        let held = settings()
        held.set(.pcState, wanted: false)

        XCTAssertTrue(held.changed(.pcState))
        XCTAssertFalse(held.changed(.devicePower))
        XCTAssertFalse(held.changed(.sync), "a default is not a decision")
    }

    func testADecisionCanBePutBack() {
        let held = settings()
        held.set(.sync, wanted: true)
        held.useDefault(.sync)

        XCTAssertFalse(held.wants(.sync))
        XCTAssertFalse(held.changed(.sync))
    }

    func testADecisionSurvivesTheAppBeingKilled() {
        settings().set(.pcState, wanted: false)

        XCTAssertFalse(NoticeSettings(defaults: defaults).wanted(.pcAway))
    }

    func testSentinel() { XCTAssertTrue(true) }
}
