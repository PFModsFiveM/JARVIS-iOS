import Foundation
import UserNotifications

/// Something worth telling the owner about when they are not looking at the app - programme §57.
///
/// Each kind is a *state transition*, never a condition. "The PC is offline" is a condition and
/// notifying on it would notify for ever; "the PC has just come online" happens once. That
/// distinction is the whole of the deduplication, and keeping it in the type rather than in the
/// code that sends is what stops a future kind being added as a condition by accident.
enum NoticeKind: String, CaseIterable, Codable, Equatable {
    /// The machine answered after not answering.
    case pcAnswering
    /// The machine stopped answering, having been there.
    case pcAway
    /// A battery crossed into the low band, discharging.
    case batteryLow
    /// Something the camera kept arrived in the shared store.
    case footageArrived
    /// The security protocol did something the owner should know about.
    case security
    /// Observations have been waiting a long time for a route.
    case syncStuck

    /// Whether this is urgent enough to interrupt.
    ///
    /// Only security. A PC coming online is useful and not urgent, and a notification that
    /// buzzes for it is a notification the owner turns off - taking the security one with it.
    var interrupts: Bool { self == .security }
}

/// One notice, ready to be shown or asserted about.
struct JarvisNotice: Equatable, Identifiable {
    let kind: NoticeKind
    let title: String
    let body: String
    /// What makes this occurrence distinct, so the same transition is not shown twice.
    let token: String

    var id: String { "\(kind.rawValue):\(token)" }
}

/// What has already been said, so nothing is said twice - programme §57.
///
/// The same shape as the PC's `LowBatteryPolicy`: once per crossing, re-armed only on a real
/// recovery. A notice held here is not a notice suppressed for ever; it is a notice whose
/// condition has not changed since it was given.
struct NoticeMemory: Equatable, Codable {
    private var said: [String: String] = [:]

    /// Whether this occurrence is new.
    func isNew(_ notice: JarvisNotice) -> Bool {
        said[notice.kind.rawValue] != notice.token
    }

    /// Records that it was given.
    mutating func gave(_ notice: JarvisNotice) {
        said[notice.kind.rawValue] = notice.token
    }

    /// Forgets one kind, so its next occurrence is new again.
    mutating func rearm(_ kind: NoticeKind) {
        said[kind.rawValue] = nil
    }

    var count: Int { said.count }
}

/// Deciding what is worth a notification, as a function of two states.
///
/// Pure, and that is what makes "it should not say this twice" testable at all. The side that
/// actually schedules is `NoticeCentre`, which does nothing but obey.
enum JarvisNotices {
    /// A battery at or below this, discharging, is worth one notice.
    static let lowAt = 20

    /// And it re-arms only once it is back above this, so a battery hovering at the line is not a
    /// stream of notices.
    static let recoveredAt = 25

    /// How long observations may wait before being worth mentioning.
    static let stuckAfter: TimeInterval = 24 * 60 * 60

    /// Everything worth saying about the move from one state to another.
    ///
    /// - Parameters:
    ///   - before: the state as it was. Nil on the first reading after launch, which deliberately
    ///     produces nothing: the owner opening the app is not a transition, and announcing the
    ///     state of the world at launch is how an assistant becomes noise.
    ///   - now: the state as it is.
    static func notices(
        from before: MobileCapabilities.NodeState?,
        to now: MobileCapabilities.NodeState,
        power: [PowerReading] = [],
        queuedSince: Date? = nil,
        at moment: Date = Date()
    ) -> [JarvisNotice] {
        var notices: [JarvisNotice] = []

        // Nothing on the first reading. A launch is not a transition.
        if let before {
            if !before.pcAnswering && now.pcAnswering {
                notices.append(JarvisNotice(
                    kind: .pcAnswering,
                    title: now.pcName,
                    body: "\(now.pcName) is answering again, sir.",
                    // One per arrival rather than one per minute of being up.
                    token: "up-\(Int(moment.timeIntervalSince1970 / 60))"))
            }

            if before.pcAnswering && !now.pcAnswering {
                notices.append(JarvisNotice(
                    kind: .pcAway,
                    title: now.pcName,
                    body: now.wakeEnabled && now.wakeReachable
                        ? "\(now.pcName) has stopped answering, sir. I can wake it."
                        : "\(now.pcName) has stopped answering, sir.",
                    token: "down-\(Int(moment.timeIntervalSince1970 / 60))"))
            }
        }

        // A battery crossing into the low band. The token is the device and the band rather than
        // the percentage, so 19% then 18% then 17% is one notice.
        for reading in power {
            guard let percent = reading.percent,
                  percent <= lowAt,
                  reading.charge != .charging,
                  reading.charge != .full
            else { continue }

            notices.append(JarvisNotice(
                kind: .batteryLow,
                title: reading.name,
                body: "\(reading.name) is down to \(percent)%, sir.",
                token: "\(reading.deviceId):low"))
        }

        // Observations that have waited a long time. Said once, because the remedy is the owner's
        // and repeating it will not make a PC come online.
        if let queuedSince, moment.timeIntervalSince(queuedSince) >= stuckAfter {
            notices.append(JarvisNotice(
                kind: .syncStuck,
                title: "One JARVIS",
                body: "I have observations that haven't reached \(now.pcName) for over a day, sir.",
                token: "stuck-\(Int(queuedSince.timeIntervalSince1970))"))
        }

        return notices
    }

    /// Which kinds a change should re-arm, so their next occurrence is heard.
    ///
    /// A battery back above the recovery line, and a PC that has gone away - because the next time
    /// it comes back is news again. Without this the second arrival of the day is silent.
    static func rearmed(
        from before: MobileCapabilities.NodeState?,
        to now: MobileCapabilities.NodeState,
        power: [PowerReading] = []
    ) -> [NoticeKind] {
        var kinds: [NoticeKind] = []

        if before?.pcAnswering == true && !now.pcAnswering { kinds.append(.pcAnswering) }
        if before?.pcAnswering == false && now.pcAnswering { kinds.append(.pcAway) }

        // Charging counts as recovery as well as being above the line: a phone on charge is no
        // longer a phone about to die, whatever the number says.
        if power.contains(where: { reading in
            guard let percent = reading.percent else { return false }
            return percent >= recoveredAt || reading.charge == .charging || reading.charge == .full
        }) {
            kinds.append(.batteryLow)
        }

        return kinds
    }
}

/// Showing them, once each.
///
/// Thin on purpose: every decision is `JarvisNotices`', and this does nothing but remember what was
/// said and hand the rest to iOS. A notice is only shown when the owner has turned notifications on
/// and iOS has granted them - neither of which this asks for on its own.
@MainActor
final class NoticeCentre: ObservableObject {
    static let shared = NoticeCentre()

    /// What has been said, so nothing is said twice.
    @Published private(set) var memory = NoticeMemory()

    /// The last few, for a diagnostic.
    @Published private(set) var recent: [JarvisNotice] = []

    /// The state the last reading saw, for the next one to compare against.
    private var before: MobileCapabilities.NodeState?

    /// When the outbound queue was first seen non-empty, so "waiting a day" can be measured.
    private var queuedSince: Date?

    /// Pinned by the tests; the live one asks iOS.
    var show: ((JarvisNotice) async -> Void)?

    private init() {}

    /// Takes a reading, says what is new, and remembers it.
    ///
    /// Safe to call as often as anything likes - that is the point of the memory. Called from
    /// `AppModel.refresh`, so every connection and every state change is considered.
    func consider(
        _ now: MobileCapabilities.NodeState,
        power: [PowerReading] = [],
        queued: Int = 0,
        at moment: Date = Date()
    ) async {
        // When the queue first became non-empty. Reset the moment it empties, so a day's waiting
        // has to be a day of this queue rather than a day since any queue.
        if queued == 0 {
            queuedSince = nil
        } else if queuedSince == nil {
            queuedSince = moment
        }

        for kind in JarvisNotices.rearmed(from: before, to: now, power: power) {
            memory.rearm(kind)
        }

        let notices = JarvisNotices.notices(
            from: before, to: now, power: power, queuedSince: queuedSince, at: moment)

        before = now

        for notice in notices where memory.isNew(notice) {
            memory.gave(notice)
            recent = Array((recent + [notice]).suffix(20))

            await (show ?? Self.toIos)(notice)
        }
    }

    /// Hands one to iOS. Immediately, because the thing it is about has already happened.
    private static func toIos(_ notice: JarvisNotice) async {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.sound = notice.kind.interrupts ? .defaultCritical : .default
        content.interruptionLevel = notice.kind.interrupts ? .timeSensitive : .active

        // A thread per kind, so iOS groups them the way the owner thinks about them.
        content.threadIdentifier = notice.kind.rawValue

        let request = UNNotificationRequest(identifier: notice.id, content: content, trigger: nil)

        try? await UNUserNotificationCenter.current().add(request)
    }

    /// Forgets everything. For unpairing.
    func forget() {
        memory = NoticeMemory()
        recent = []
        before = nil
        queuedSince = nil
    }
}
