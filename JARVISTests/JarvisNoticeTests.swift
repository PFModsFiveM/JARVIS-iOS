import XCTest
@testable import JARVIS

/// What is worth telling the owner about while they are not looking - programme §57.
///
/// One rule, tested from every angle: a notice is a *state transition*, never a condition. "The PC
/// is offline" is a condition and notifying on it would notify for ever; "the PC has just come
/// online" happens once. Everything here is about keeping that distinction, because the failure
/// mode is an owner who turns notifications off and loses the security one with them.
final class JarvisNoticeTests: XCTestCase {
    private func state(pcAnswering: Bool = false, wake: Bool = false) -> MobileCapabilities.NodeState {
        var state = MobileCapabilities.NodeState()
        state.pcName = "DOM-PC"
        state.pcAnswering = pcAnswering
        state.wakeEnabled = wake
        state.wakeReachable = wake
        return state
    }

    private func reading(_ name: String, _ percent: Int?, charge: ChargeReading = .discharging) -> PowerReading {
        PowerReading(
            deviceId: name.lowercased(), name: name, percent: percent, charge: charge,
            measuredAt: Date(), lowPowerMode: false, because: nil)
    }

    private static let noon = Date(timeIntervalSince1970: 1_793_000_000)

    // MARK: A launch is not a transition

    /// Announcing the state of the world when the app opens is how an assistant becomes noise.
    func testTheFirstReadingSaysNothing() {
        XCTAssertTrue(JarvisNotices.notices(from: nil, to: state(pcAnswering: true)).isEmpty)
        XCTAssertTrue(JarvisNotices.notices(from: nil, to: state()).isEmpty)
    }

    // MARK: Transitions

    func testThePCComingBackIsWorthSaying() {
        let notices = JarvisNotices.notices(from: state(), to: state(pcAnswering: true))

        XCTAssertEqual(notices.count, 1)
        XCTAssertEqual(notices[0].kind, .pcAnswering)
        XCTAssertTrue(notices[0].body.contains("DOM-PC"))
        XCTAssertTrue(notices[0].body.contains("sir"))
    }

    func testThePCGoingAwayIsWorthSayingAndOffersTheWake() {
        let canWake = JarvisNotices.notices(from: state(pcAnswering: true, wake: true), to: state(wake: true))
        XCTAssertEqual(canWake.first?.kind, .pcAway)
        XCTAssertTrue(canWake.first!.body.contains("wake"), canWake.first!.body)

        let cannot = JarvisNotices.notices(from: state(pcAnswering: true), to: state())
        XCTAssertFalse(cannot.first!.body.contains("wake"), cannot.first!.body)
    }

    /// The condition staying the same is not a transition.
    func testNothingIsSaidWhileNothingChanges() {
        XCTAssertTrue(JarvisNotices.notices(from: state(), to: state()).isEmpty)
        XCTAssertTrue(JarvisNotices.notices(from: state(pcAnswering: true), to: state(pcAnswering: true)).isEmpty)
    }

    // MARK: Batteries

    func testALowBatteryIsOneNoticePerDeviceAndBand() {
        let first = JarvisNotices.notices(
            from: state(pcAnswering: true), to: state(pcAnswering: true), power: [reading("iPhone", 19)])
        let later = JarvisNotices.notices(
            from: state(pcAnswering: true), to: state(pcAnswering: true), power: [reading("iPhone", 17)])

        // Same token, so the memory treats 19% then 17% as one occurrence.
        XCTAssertEqual(first.first?.token, later.first?.token)
        XCTAssertEqual(first.first?.kind, .batteryLow)
    }

    func testAHealthyBatteryIsNotANotice() {
        XCTAssertTrue(JarvisNotices.notices(
            from: state(pcAnswering: true), to: state(pcAnswering: true),
            power: [reading("iPhone", 84)]).isEmpty)
    }

    func testABatteryOnChargeIsNotANotice() {
        for charge in [ChargeReading.charging, .full] {
            XCTAssertTrue(JarvisNotices.notices(
                from: state(pcAnswering: true), to: state(pcAnswering: true),
                power: [reading("iPhone", 8, charge: charge)]).isEmpty, "\(charge)")
        }
    }

    func testADeviceWithNoReadingIsNotALowDevice() {
        XCTAssertTrue(JarvisNotices.notices(
            from: state(pcAnswering: true), to: state(pcAnswering: true),
            power: [reading("AirPods Pro", nil)]).isEmpty)
    }

    // MARK: Re-arming, so the second time is heard

    /// Without this the second arrival of the day is silent.
    func testAPCGoingAwayRearmsItsReturn() {
        XCTAssertTrue(JarvisNotices.rearmed(from: state(pcAnswering: true), to: state()).contains(.pcAnswering))
        XCTAssertTrue(JarvisNotices.rearmed(from: state(), to: state(pcAnswering: true)).contains(.pcAway))
    }

    /// A battery hovering at the line must not be a stream of notices, so recovery is above it.
    func testABatteryOnlyRearmsOnceItHasActuallyRecovered() {
        let justAbove = JarvisNotices.rearmed(
            from: state(), to: state(), power: [reading("iPhone", JarvisNotices.lowAt + 1)])
        XCTAssertFalse(justAbove.contains(.batteryLow), "one point above the line is not recovery")

        let recovered = JarvisNotices.rearmed(
            from: state(), to: state(), power: [reading("iPhone", JarvisNotices.recoveredAt)])
        XCTAssertTrue(recovered.contains(.batteryLow))
    }

    /// A phone on charge is no longer about to die, whatever the number says.
    func testChargingCountsAsRecovery() {
        XCTAssertTrue(JarvisNotices.rearmed(
            from: state(), to: state(), power: [reading("iPhone", 5, charge: .charging)]).contains(.batteryLow))
    }

    // MARK: A queue that has waited

    func testObservationsThatHaveWaitedADayAreMentionedOnce() {
        let old = Self.noon.addingTimeInterval(-JarvisNotices.stuckAfter - 60)

        let notices = JarvisNotices.notices(
            from: state(), to: state(), queuedSince: old, at: Self.noon)

        XCTAssertEqual(notices.first?.kind, .syncStuck)

        // And the same queue an hour later is the same occurrence.
        let again = JarvisNotices.notices(
            from: state(), to: state(), queuedSince: old, at: Self.noon.addingTimeInterval(3600))

        XCTAssertEqual(notices.first?.token, again.first?.token)
    }

    func testAQueueThatHasNotWaitedLongIsNotMentioned() {
        XCTAssertTrue(JarvisNotices.notices(
            from: state(), to: state(),
            queuedSince: Self.noon.addingTimeInterval(-60), at: Self.noon).isEmpty)
    }

    // MARK: The memory

    func testTheSameOccurrenceIsOnlyGivenOnce() {
        var memory = NoticeMemory()
        let notice = JarvisNotice(kind: .batteryLow, title: "iPhone", body: "x", token: "iphone:low")

        XCTAssertTrue(memory.isNew(notice))
        memory.gave(notice)
        XCTAssertFalse(memory.isNew(notice))

        memory.rearm(.batteryLow)
        XCTAssertTrue(memory.isNew(notice))
    }

    func testADifferentOccurrenceOfTheSameKindIsNew() {
        var memory = NoticeMemory()
        memory.gave(JarvisNotice(kind: .batteryLow, title: "iPhone", body: "x", token: "iphone:low"))

        XCTAssertTrue(memory.isNew(
            JarvisNotice(kind: .batteryLow, title: "AirPods", body: "x", token: "airpods:low")))
    }

    // MARK: What interrupts

    /// Only security. A PC coming online buzzing the phone is a notification the owner turns off,
    /// taking the security one with it.
    func testOnlySecurityInterrupts() {
        XCTAssertTrue(NoticeKind.security.interrupts)

        for kind in NoticeKind.allCases where kind != .security {
            XCTAssertFalse(kind.interrupts, "\(kind) should not interrupt")
        }
    }

    // MARK: End to end, through the centre

    @MainActor
    func testTheCentreSaysEachTransitionOnceAndHearsTheSecondOne() async {
        let centre = NoticeCentre.shared
        centre.forget()

        var shown: [JarvisNotice] = []
        centre.show = { shown.append($0) }
        defer { centre.show = nil; centre.forget() }

        // The launch reading: nothing.
        await centre.consider(state())
        XCTAssertTrue(shown.isEmpty)

        // It comes up: once.
        await centre.consider(state(pcAnswering: true))
        XCTAssertEqual(shown.count, 1)
        XCTAssertEqual(shown[0].kind, .pcAnswering)

        // Still up: nothing more.
        await centre.consider(state(pcAnswering: true))
        XCTAssertEqual(shown.count, 1)

        // It goes away: once.
        await centre.consider(state())
        XCTAssertEqual(shown.count, 2)
        XCTAssertEqual(shown[1].kind, .pcAway)

        // And comes back again: heard, because going away re-armed it.
        await centre.consider(state(pcAnswering: true))
        XCTAssertEqual(shown.count, 3)
        XCTAssertEqual(shown[2].kind, .pcAnswering)
    }

    @MainActor
    func testALowBatteryIsSaidOnceAndAgainOnlyAfterRecovery() async {
        let centre = NoticeCentre.shared
        centre.forget()

        var shown: [JarvisNotice] = []
        centre.show = { shown.append($0) }
        defer { centre.show = nil; centre.forget() }

        let up = state(pcAnswering: true)

        await centre.consider(up, power: [reading("iPhone", 60)])
        await centre.consider(up, power: [reading("iPhone", 18)])
        XCTAssertEqual(shown.count, 1, "the crossing")

        await centre.consider(up, power: [reading("iPhone", 15)])
        await centre.consider(up, power: [reading("iPhone", 11)])
        XCTAssertEqual(shown.count, 1, "still low is not a new crossing")

        await centre.consider(up, power: [reading("iPhone", 40)])
        XCTAssertEqual(shown.count, 1, "recovery is not itself news")

        await centre.consider(up, power: [reading("iPhone", 12)])
        XCTAssertEqual(shown.count, 2, "and the next crossing is")
    }

    @MainActor
    func testAnEmptyingQueueResetsTheWaitingClock() async {
        let centre = NoticeCentre.shared
        centre.forget()

        var shown: [JarvisNotice] = []
        centre.show = { shown.append($0) }
        defer { centre.show = nil; centre.forget() }

        let away = state()

        // Queued, then empty, then queued again: a day's waiting has to be a day of this queue.
        await centre.consider(away, queued: 3, at: Self.noon.addingTimeInterval(-JarvisNotices.stuckAfter - 60))
        await centre.consider(away, queued: 0, at: Self.noon.addingTimeInterval(-60))
        await centre.consider(away, queued: 3, at: Self.noon)

        XCTAssertFalse(shown.contains { $0.kind == .syncStuck })
    }

    func testSentinel() {}
}
