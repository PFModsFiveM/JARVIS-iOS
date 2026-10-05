import CoreLocation
import Foundation
import LocalAuthentication
import UserNotifications

/// What one iOS permission actually is right now, read from iOS and not from a flag - §20.
///
/// The brief's instruction is "use OS truth; do not invent permission states", and the reason is
/// that an app's own idea of its permissions drifts: the owner changes something in Settings, iOS
/// knows, and the app shows what it remembered. The only reliable answer comes from asking.
struct OwnerPermission: Identifiable, Equatable {
    enum State: Equatable {
        /// Granted, in whatever form this permission has.
        case allowed(String)
        /// Refused. The owner has said no, and only iOS Settings can change it.
        case refused
        /// Never asked. JARVIS can still ask.
        case notAsked
        /// Not applicable on this device.
        case unavailable(String)

        var allowed: Bool {
            if case .allowed = self { return true }
            return false
        }
    }

    let id: String
    let title: String
    /// What JARVIS can do with it, and what it cannot do without it.
    let why: String
    let state: State

    /// Whether the owner has to go to iOS Settings rather than being asked again.
    ///
    /// iOS only ever asks once. After a refusal the app's own button can do nothing, and showing
    /// one that silently fails is worse than saying where to go.
    var needsSettings: Bool { state == .refused }

    var said: String {
        switch state {
        case .allowed(let how): return how
        case .refused: return "Not allowed"
        case .notAsked: return "Not asked yet"
        case .unavailable(let why): return why
        }
    }
}

/// Every permission JARVIS uses, read from iOS - priority §20.
///
/// One screen, because the alternative is what the app had: each permission explained on whichever
/// page happened to need it, and no way to see the whole picture. An owner wondering why "where am
/// I" stopped working should not have to guess which of four screens mentions location.
///
/// Read-only beyond asking. Nothing here flips a switch, because nothing can: iOS owns these and
/// the honest thing is to say what it says and where to change it.
@MainActor
enum PermissionCentre {
    /// What iOS currently says about each one.
    static func all(
        location: CLAuthorizationStatus,
        notifications: UNAuthorizationStatus,
        localNetwork: Bool?,
        cloud: CloudReadiness,
        microphone: Bool
    ) -> [OwnerPermission] {
        [
            OwnerPermission(
                id: "location",
                title: "Location",
                why: "Lets me say where you are and name the places you go. Without it I can only "
                    + "tell you what your PC last knew.",
                state: locationState(location)),

            OwnerPermission(
                id: "background-location",
                title: "Location in the background",
                why: "Lets me notice you arriving and leaving while the app is closed, which is "
                    + "what makes your routines real rather than guessed.",
                state: backgroundState(location)),

            OwnerPermission(
                id: "notifications",
                title: "Notifications",
                why: "Lets me reach you when you are not looking at the app. Security is the one "
                    + "that matters; the rest you can narrow in \u{201C}What I tell you about\u{201D}.",
                state: notificationState(notifications)),

            OwnerPermission(
                id: "local-network",
                title: "Local network",
                why: "Lets me find your PC on the same Wi-Fi without going through the internet. "
                    + "Without it I can still reach it over Tailscale.",
                state: localNetwork == nil
                    ? .notAsked
                    : localNetwork == true
                        ? .allowed("Allowed")
                        : .refused),

            OwnerPermission(
                id: "face-id",
                title: "Face ID",
                why: "Required before I will unlock your PC, stand the security protocol down, or "
                    + "hand over the key to your shared store.",
                state: faceIdState()),

            OwnerPermission(
                id: "cloud",
                title: "Cloud intelligence",
                why: "Lets me answer general questions with your PC switched off. Nothing about "
                    + "your home, your location or your files is sent.",
                state: cloud == .notConfigured
                    ? .notAsked
                    : cloud == .authenticationFailed
                        ? .refused
                        : .allowed(cloud.title)),

            OwnerPermission(
                id: "microphone",
                title: "Microphone",
                why: "Only for speaking to me directly in the app. I do not listen in the "
                    + "background on this phone.",
                state: microphone ? .allowed("Allowed") : .notAsked)
        ]
    }

    private static func locationState(_ status: CLAuthorizationStatus) -> OwnerPermission.State {
        switch status {
        case .authorizedAlways: return .allowed("Always")
        case .authorizedWhenInUse: return .allowed("While using the app")
        case .denied, .restricted: return .refused
        case .notDetermined: return .notAsked
        @unknown default: return .notAsked
        }
    }

    private static func backgroundState(_ status: CLAuthorizationStatus) -> OwnerPermission.State {
        switch status {
        case .authorizedAlways: return .allowed("Allowed")

        // The distinction that matters and that a single "location" row would hide. While-in-use
        // is granted, and arrivals while the app is closed still will not be noticed.
        case .authorizedWhenInUse:
            return .unavailable("Only while the app is open, so I'll miss arrivals")

        case .denied, .restricted: return .refused
        case .notDetermined: return .notAsked
        @unknown default: return .notAsked
        }
    }

    private static func notificationState(_ status: UNAuthorizationStatus) -> OwnerPermission.State {
        switch status {
        case .authorized: return .allowed("Allowed")
        case .provisional: return .allowed("Quietly, until you decide")
        case .ephemeral: return .allowed("For this session")
        case .denied: return .refused
        case .notDetermined: return .notAsked
        @unknown default: return .notAsked
        }
    }

    private static func faceIdState() -> OwnerPermission.State {
        let context = LAContext()
        var trouble: NSError?

        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &trouble) else {
            // Distinguished, because "this phone has no Face ID" and "you turned it off for
            // JARVIS" need different things from the owner.
            return trouble?.code == LAError.biometryNotAvailable.rawValue
                ? .unavailable("This phone has no Face ID")
                : trouble?.code == LAError.biometryNotEnrolled.rawValue
                    ? .unavailable("Face ID isn't set up on this phone")
                    : .refused
        }

        return .allowed(context.biometryType == .faceID ? "Face ID" : "Touch ID")
    }

    /// How many are granted, for the row the owner sees before opening the page.
    static func summary(_ all: [OwnerPermission]) -> String {
        let allowed = all.filter { $0.state.allowed }.count

        if allowed == all.count { return "All \(all.count) allowed" }

        let needed = all.filter(\.needsSettings).count

        return needed > 0
            ? "\(allowed) of \(all.count) allowed, \(needed) needing iOS Settings"
            : "\(allowed) of \(all.count) allowed"
    }
}
