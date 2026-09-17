import Foundation
import UserNotifications

/// Security alerts on the phone. They arrive while the app is connected - on screen, or in the background while the
/// wake word keeps it running. (Alerts with the app fully closed would need Apple push notifications and a server
/// outside your home network, which this build deliberately does not have.)
final class Alerts: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Alerts()

    private static let challengeCategory = "SECURITY_CHALLENGE"
    private static let approveAction = "APPROVE"
    private static let lockAction = "LOCK"

    func register() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let approve = UNNotificationAction(identifier: Self.approveAction, title: "It's me (Face ID)", options: [.foreground, .authenticationRequired])
        let lock = UNNotificationAction(identifier: Self.lockAction, title: "Not me - lock the PC", options: [.destructive, .foreground])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.challengeCategory, actions: [approve, lock], intentIdentifiers: [])])
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    static func challenge(pc: String, testing: Bool) {
        let content = UNMutableNotificationContent()
        content.title = testing ? "Security Protocol test on \(pc)" : "Someone is at \(pc)"
        content.body = testing
            ? "A test challenge is up. Nothing will be locked."
            : "The Security Protocol has challenged them. If it's you, confirm with Face ID. If not, lock the PC."
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.categoryIdentifier = challengeCategory
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "challenge", content: content, trigger: nil))
    }

    static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        switch response.actionIdentifier {
        case Self.approveAction:
            await AppModel.shared.approveChallenge()
        case Self.lockAction:
            await AppModel.shared.denyChallenge()
        default:
            break
        }
    }
}
