import AVFoundation
import Combine
import Foundation
import UIKit

/// What a device's battery is doing, in the PC's own vocabulary.
///
/// The same five words `ChargeState` uses on the PC, so the wire carries one spelling and neither
/// end translates.
enum ChargeReading: String, Codable, Equatable {
    case unknown
    case discharging
    case charging
    case full
    case mains
}

/// One device's power as this phone can read it.
///
/// `percent` is nil when nothing readable said, and `because` then says why. That pair is the whole
/// honesty of this file: iOS gives an app its own battery and gives it nothing at all about what is
/// paired over Bluetooth, and the difference has to survive all the way to what JARVIS says.
struct PowerReading: Codable, Equatable, Identifiable {
    let deviceId: String
    let name: String
    let percent: Int?
    let charge: ChargeReading
    let measuredAt: Date
    let lowPowerMode: Bool
    let because: String?

    var id: String { deviceId }

    var hasLevel: Bool { percent != nil }

    /// The body of a `power.report` row, in the shape `BridgePowerReading.Read` expects.
    var row: [String: Any] {
        var body: [String: Any] = [
            "deviceId": deviceId,
            "name": name,
            "charge": charge.rawValue,
            "measuredAt": ISO8601DateFormatter().string(from: measuredAt),
            "lowPowerMode": lowPowerMode
        ]
        if let percent { body["percent"] = percent }
        if let because { body["because"] = because }
        return body
    }
}

/// This phone's power, and what it can honestly say about what is plugged into it.
///
/// **Why the phone reports rather than the PC asking.** A battery is readable only by the device it
/// is in. The PC cannot go and look at an iPhone's, so the only shape that works is the phone
/// telling it - which is also the shape that keeps working when the reading is minutes old, because
/// each row carries the time it was taken.
///
/// **What iOS actually gives an app.** Its own battery level and charging state, through `UIDevice`
/// once battery monitoring is switched on, and whether Low Power Mode is on. It does *not* give a
/// third-party app the battery of anything paired over Bluetooth: there is no public API for
/// AirPods' level, and the ones that appear to do it read a private interface. So this reports what
/// it can read and names the accessory it cannot, with the reason, rather than guessing a number or
/// pretending the accessory is not there. A row with no level and a reason is a real answer - it is
/// what lets JARVIS say "your AirPods are connected, and iOS doesn't tell me their battery"
/// instead of either silence or a figure nobody measured.
@MainActor
final class PowerReporter: ObservableObject {
    static let shared = PowerReporter()

    /// What this phone last read about itself and its accessories.
    @Published private(set) var readings: [PowerReading] = []

    /// What was last sent, so an unchanged reading is not sent again on every heartbeat.
    private var sent: [String: PowerReading] = [:]

    /// Called with the rows to send. Set by `AppModel`, which owns the connection.
    var send: (([PowerReading]) async -> Void)?

    private var watching = false

    /// Starts watching, and reads once so there is something to say immediately.
    ///
    /// Battery monitoring has to be switched on explicitly, and until it is `batteryLevel` reports
    /// -1 and `batteryState` reports `.unknown` - which looks exactly like a device that cannot be
    /// read. Switching it on costs nothing measurable; leaving it off costs the whole feature.
    func start() {
        guard !watching else { return }
        watching = true

        UIDevice.current.isBatteryMonitoringEnabled = true

        let centre = NotificationCenter.default
        for name in [UIDevice.batteryLevelDidChangeNotification,
                     UIDevice.batteryStateDidChangeNotification,
                     .NSProcessInfoPowerStateDidChange,
                     AVAudioSession.routeChangeNotification] {
            centre.addObserver(self, selector: #selector(changed), name: name, object: nil)
        }

        read()
    }

    @objc private func changed() {
        read()
        Task { await report() }
    }

    /// Reads everything readable, now.
    func read() {
        let device = UIDevice.current
        let at = Date()

        // -1 means monitoring is off or the level is genuinely unavailable. Either way there is no
        // level, which is said rather than turned into a plausible number.
        let level = device.batteryLevel
        let percent = level < 0 ? nil : Int((level * 100).rounded())

        var rows: [PowerReading] = [
            PowerReading(
                deviceId: AppModel.shared.pc?.deviceId ?? device.identifierForVendor?.uuidString ?? "this-phone",
                name: device.name,
                percent: percent,
                charge: charge(device.batteryState),
                measuredAt: at,
                lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                because: percent == nil ? "iOS isn't reporting this phone's battery level." : nil)
        ]

        if let accessory = accessory(at: at) { rows.append(accessory) }

        readings = rows
    }

    /// Sends whatever has changed since the last send.
    func report() async { await report(readings) }

    /// Sends whatever of these has changed since the last send.
    ///
    /// Only what changed, because a heartbeat carrying the same percentage every thirty seconds is
    /// noise on the wire and a redraw on every screen at the other end. Takes the rows rather than
    /// reading the property, so the deciding is a function of its argument.
    func report(_ readings: [PowerReading]) async {
        guard let send else { return }

        let changed = readings.filter { reading in
            guard let before = sent[reading.deviceId] else { return true }
            return before.percent != reading.percent
                || before.charge != reading.charge
                || before.lowPowerMode != reading.lowPowerMode
                || before.because != reading.because
        }

        guard !changed.isEmpty else { return }

        await send(changed)
        for reading in changed { sent[reading.deviceId] = reading }
    }

    /// Sends everything, changed or not. For a reconnection: the PC may never have heard any of it.
    func reportEverything() async {
        sent.removeAll()
        read()
        await report(readings)
    }

    private func charge(_ state: UIDevice.BatteryState) -> ChargeReading {
        switch state {
        case .charging: return .charging
        case .full: return .full
        case .unplugged: return .discharging
        case .unknown: return .unknown
        @unknown default: return .unknown
        }
    }

    /// The Bluetooth audio accessory in use, when there is one - without its battery.
    ///
    /// `AVAudioSession`'s current route is the supported way to know that something is connected
    /// and what it is called. It carries no battery level, and iOS offers an app no other route to
    /// one, so this row is deliberately a named device with no number and the reason why. Saying
    /// "connected, and iOS doesn't tell me its battery" is true; everything else available here
    /// would not be.
    private func accessory(at: Date) -> PowerReading? {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs

        let bluetooth = outputs.first { output in
            output.portType == .bluetoothA2DP
                || output.portType == .bluetoothHFP
                || output.portType == .bluetoothLE
        }

        guard let bluetooth else { return nil }

        let owner = AppModel.shared.pc?.deviceId ?? "this-phone"

        return PowerReading(
            deviceId: "\(owner)-\(bluetooth.uid)",
            name: bluetooth.portName,
            percent: nil,
            charge: .unknown,
            measuredAt: at,
            lowPowerMode: false,
            because: "iOS doesn't give an app the battery of anything paired over Bluetooth, so I can only tell you it's connected.")
    }

    /// What JARVIS would say about one of these, with the PC off and no wording service to ask.
    ///
    /// The same rules as the PC's `DevicePowerWording`: a fresh reading in the present tense, an
    /// old one as a memory, and no number where none was measured. Kept short rather than ported
    /// wholesale - this phone only ever says it about readings it took itself seconds ago.
    static func say(_ reading: PowerReading, now: Date = Date()) -> String {
        guard let percent = reading.percent else {
            return reading.because.map { "I've no battery reading for \(reading.name), sir - \($0)" }
                ?? "I've no battery reading for \(reading.name), sir."
        }

        var charging = ""
        if reading.charge == .charging { charging = " and charging" }
        if reading.charge == .full { charging = " and full" }

        let saving = reading.lowPowerMode ? ", in low power mode" : ""
        let age = now.timeIntervalSince(reading.measuredAt)

        // Anything this phone read more than a few minutes ago is said with its age, by the same
        // rule the PC uses: a percentage stated in the present tense is a claim about now.
        if age > 120 {
            let minutes = Int((age / 60).rounded())
            return "\(reading.name) was at \(percent) per cent, sir, \(minutes) minute\(minutes == 1 ? "" : "s") ago."
        }

        return "\(reading.name) is at \(percent) per cent\(charging)\(saving), sir."
    }

    /// Everything readable, as JARVIS would say it.
    static func sayAll(_ readings: [PowerReading], now: Date = Date()) -> String {
        readings.isEmpty
            ? "I can't read anything's battery at the moment, sir."
            : readings.map { say($0, now: now) }.joined(separator: "\n")
    }

    /// The readings a spoken name picks out, or everything when nothing was named.
    ///
    /// The same matching the PC's tool uses: an exact name or id first, then a name containing what
    /// was said, so "phone" finds this iPhone and "airpods" finds the AirPods.
    static func matching(_ wanted: String?, in readings: [PowerReading]) -> [PowerReading] {
        guard let wanted, !wanted.trimmingCharacters(in: .whitespaces).isEmpty else { return readings }

        let said = wanted.trimmingCharacters(in: .whitespaces)

        let exact = readings.filter {
            $0.name.caseInsensitiveCompare(said) == .orderedSame
                || $0.deviceId.caseInsensitiveCompare(said) == .orderedSame
        }
        if !exact.isEmpty { return exact }

        let contains = readings.filter { $0.name.range(of: said, options: .caseInsensitive) != nil }
        if !contains.isEmpty { return contains }

        // "My phone" is this phone, whatever iOS calls it - and what iOS calls it is whatever the
        // owner typed into Settings years ago, which may be anything at all.
        let asking = said.lowercased()
        if ["phone", "iphone", "my phone", "this phone"].contains(asking) {
            return readings.filter { $0.deviceId == (AppModel.shared.pc?.deviceId ?? "this-phone") }
        }

        return []
    }
}
