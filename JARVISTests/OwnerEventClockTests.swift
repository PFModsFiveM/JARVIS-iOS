import XCTest
@testable import JARVIS

/// Which clock an event this phone files is on - programme §29.
///
/// This phone is where the evidence for the owner's routines comes from: the PC cannot see an
/// arrival or a departure, only the phone can. So if the phone sends an instant without saying
/// which clock it was on, every time of day the PC learns is wrong by the owner's summer offset -
/// which is exactly what was happening, because `ISO8601DateFormatter` defaults to GMT.
final class OwnerEventClockTests: XCTestCase {
    /// Ten past six on a July evening in Ireland, as an instant.
    private static let julyEvening = Date(timeIntervalSince1970: 1_784_131_800)

    private func event(_ zone: String = TimeZone.current.identifier) -> OwnerEvent {
        OwnerEvent(
            id: "a", type: OwnerEventTypes.arrived, category: .location,
            occurred: Self.julyEvening, observed: Self.julyEvening,
            payload: ["place": "Home"], zone: zone)
    }

    // MARK: the stamp

    /// The thing that was wrong: a `Z` on an event the owner lived through on a +01:00 clock.
    func testTheStampCarriesAnOffsetRatherThanClaimingEverythingIsGmt() {
        let summer = TimeZone(identifier: "Europe/Dublin")!

        // The formatter follows the device, so the assertion is about what it does with a zone
        // rather than about where this test happens to run.
        let stamped = OwnerEvent.stamp(Self.julyEvening)

        // Whatever the runner's zone, the stamp must say which one it is - either an explicit
        // offset or a Z that is genuinely UTC. What it must never be is an offset silently
        // dropped, which is what a GMT-defaulted formatter produces for a device that is not.
        let saysWhichClock = stamped.hasSuffix("Z") || stamped.contains("+") || stamped.hasSuffix("00:00")
        XCTAssertTrue(saysWhichClock, stamped)

        if TimeZone.current.secondsFromGMT(for: Self.julyEvening) != 0 {
            XCTAssertFalse(stamped.hasSuffix("Z"), "a device that is not on UTC must not stamp Z: \(stamped)")
        }

        // And the instant is unchanged by any of this, which is the part that must not regress.
        XCTAssertEqual(OwnerEvent.date(stamped)?.timeIntervalSince1970 ?? 0,
                       Self.julyEvening.timeIntervalSince1970, accuracy: 1)
        XCTAssertNotNil(summer)
    }

    func testAnEventNamesTheZoneThePhoneWasIn() {
        XCTAssertEqual(event("Europe/Dublin").zone, "Europe/Dublin")
        XCTAssertEqual(event().zone, TimeZone.current.identifier)
    }

    func testTheZoneTravelsInTheRowThePcReceives() {
        let body = event("Asia/Tokyo").body

        XCTAssertEqual(body["zone"] as? String, "Asia/Tokyo")
    }

    /// An event the PC observed was not observed here, so this phone's zone must not be put on it.
    func testAnEventFromThePcWithNoZoneDoesNotInheritThisPhonesZone() {
        let row: [String: Any] = [
            "id": "pc-1", "type": OwnerEventTypes.arrived, "category": "Location",
            "occurred": OwnerEvent.stamp(Self.julyEvening)
        ]

        let read = OwnerEvent(row)

        XCTAssertNotNil(read)
        XCTAssertEqual(read?.zone, "")
    }

    func testAnEventFromThePcKeepsTheZoneThePcSent() {
        let row: [String: Any] = [
            "id": "pc-2", "type": OwnerEventTypes.arrived, "category": "Location",
            "occurred": OwnerEvent.stamp(Self.julyEvening), "zone": "Europe/Dublin"
        ]

        XCTAssertEqual(OwnerEvent(row)?.zone, "Europe/Dublin")
    }

    // MARK: the stored queue, which must survive the update that added this

    /// The hazard: adding a field to a stored shape and dropping the whole queue on next launch.
    func testAQueuedEventWrittenBeforeZonesExistedStillDecodes() throws {
        let old = """
        {
          "id": "old-1",
          "type": "owner.arrived",
          "category": "Location",
          "occurred": 775000000.0,
          "observed": 775000000.0,
          "payload": {"place": "Home"},
          "confidence": 1,
          "sensitivity": "Medium",
          "schema": 1
        }
        """

        let read = try JSONDecoder().decode(OwnerEvent.self, from: Data(old.utf8))

        XCTAssertEqual(read.id, "old-1")
        XCTAssertEqual(read.payload["place"], "Home")
        XCTAssertEqual(read.zone, "", "an old row has no zone, and empty is how the PC is told so")
    }

    func testAnEventSurvivesBeingStoredAndReadBack() throws {
        let written = try JSONEncoder().encode(event("Europe/Dublin"))
        let read = try JSONDecoder().decode(OwnerEvent.self, from: written)

        XCTAssertEqual(read, event("Europe/Dublin"))
        XCTAssertEqual(read.zone, "Europe/Dublin")
    }

    /// A stored row missing more than the zone should still come back rather than take the queue
    /// with it, because a partial row is still an observation the owner made.
    func testAThinStoredRowDecodesOnWhatItHas() throws {
        let thin = """
        {"id":"thin","type":"owner.arrived","category":"Location",
         "occurred":775000000.0,"observed":775000000.0}
        """

        let read = try JSONDecoder().decode(OwnerEvent.self, from: Data(thin.utf8))

        XCTAssertEqual(read.id, "thin")
        XCTAssertEqual(read.confidence, 1)
        XCTAssertTrue(read.payload.isEmpty)
    }

    func testSentinel() {}
}
