import XCTest
@testable import JARVIS

/// The phone's side of the smart home: reading what the PC sends, and never pretending.
///
/// The rows here are the PC's `BridgeDevice` as `MobileBridgeProtocol.Json` writes it - camelCase
/// names, camelCase enum values - so a change on either side that breaks the other fails here.
final class SmartHomeTests: XCTestCase {
    private func row(_ overrides: [String: Any] = [:]) -> [String: Any] {
        var row: [String: Any] = [
            "id": "bedroom_main_light",
            "name": "Bedroom Light",
            "room": "Bedroom",
            "kind": "light",
            "status": "on",
            "statusText": "On",
            "power": "on",
            "certainty": "confirmed",
            "updating": false,
            "bound": true,
            "simulated": false,
            "provider": "SwitchBot",
            "battery": 87,
            "online": true,
            "capabilities": ["powerOn", "powerOff", "press", "battery"],
            "readAt": "2026-09-25T21:04:12.3456789+00:00",
            "lastCommand": "powerOn",
            "lastResult": "accepted"
        ]
        for (key, value) in overrides { row[key] = value }
        return row
    }

    func testTheBedroomLightIsReadFieldForField() throws {
        let device = try XCTUnwrap(SmartDevice(row()))

        XCTAssertEqual(device.id, "bedroom_main_light")
        XCTAssertEqual(device.name, "Bedroom Light")
        XCTAssertEqual(device.room, "Bedroom")
        XCTAssertEqual(device.status, .on)
        XCTAssertEqual(device.certainty, .confirmed)
        XCTAssertEqual(device.battery, 87)
        XCTAssertTrue(device.canSwitch)
        XCTAssertNotNil(device.readAt, "the PC writes seven fractional digits; that still has to parse")
    }

    func testANotSetUpLightHasNoSwitch() throws {
        // Before the Bot arrives: listed, explained, and nothing to press that could not work.
        let device = try XCTUnwrap(SmartDevice(row(["status": "notSetUp", "bound": false, "problem": "Bedroom Light isn't configured yet, sir."])))

        XCTAssertEqual(device.status, .notSetUp)
        XCTAssertFalse(device.canSwitch)
        XCTAssertEqual(device.problem, "Bedroom Light isn't configured yet, sir.")
    }

    func testSevenFractionalDigitsAndNoneBothParse() {
        // What .NET writes, and what it writes when the fraction happens to be zero.
        XCTAssertNotNil(SmartDevice.date("2026-09-25T21:04:12.3456789+00:00"))
        XCTAssertNotNil(SmartDevice.date("2026-09-25T21:04:12+00:00"))
        XCTAssertNotNil(SmartDevice.date("2026-09-25T21:04:12.5Z"))
        XCTAssertNil(SmartDevice.date("not a date"))
        XCTAssertNil(SmartDevice.date(nil))
    }

    func testAnUnknownStatusIsUnknownNotOff() throws {
        let device = try XCTUnwrap(SmartDevice(row(["status": "somethingNew", "certainty": "somethingNew"])))

        XCTAssertEqual(device.status, .unknown)
        XCTAssertEqual(device.certainty, .unknown)
    }

    func testARowWithoutAnIdIsNotADevice() {
        XCTAssertNil(SmartDevice(["name": "Nameless"]))
        XCTAssertNil(SmartDevice(["id": "", "name": "Empty"]))
    }

    func testPressingShowsUpdatingAtOnceWithoutChangingWhatThePcSaid() throws {
        let device = try XCTUnwrap(SmartDevice(row()))
        let pending = device.pending()

        XCTAssertEqual(pending.shown, .updating)
        XCTAssertEqual(pending.status, .on, "the PC's own word stands until the PC says otherwise")
    }

    @MainActor
    func testRoomsAreGroupedAndADeviceWithNoRoomComesLast() throws {
        let home = SmartHomeModel(model: .shared)
        home.apply(list: [
            row(["id": "hall_lamp", "name": "Lamp", "room": NSNull()]),
            row(["id": "office_light", "name": "Office Light", "room": "Office"]),
            row()
        ], simulating: true)

        XCTAssertEqual(home.rooms.map(\.room), ["Bedroom", "Office", "Elsewhere"])
        XCTAssertTrue(home.simulating)
        XCTAssertTrue(home.loaded)
    }

    @MainActor
    func testAPushFromThePcReplacesTheDevice() throws {
        // Switched off on the PC, or by voice: the phone is told, and shows it.
        let home = SmartHomeModel(model: .shared)
        home.apply(list: [row()], simulating: false)

        home.receive(BridgeMessage(kind: "devices.changed", id: "", body: ["device": row(["status": "off", "power": "off"])]))

        XCTAssertEqual(home.devices.first?.status, .off)
        XCTAssertEqual(home.devices.count, 1)
    }
}
