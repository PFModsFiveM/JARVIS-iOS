import AppIntents
import Foundation
import UIKit

/// Siri, Shortcuts and the Action button. Each intent connects to the PC, does one thing, and answers. They can all be
/// used in Shortcuts automations - "when I get home", "when I connect CarPlay", "at 23:00" - as well as by voice.

// MARK: - asking

struct AskJarvisIntent: AppIntent {
    static var title: LocalizedStringResource { "Ask JARVIS" }
    static var description: IntentDescription { "Sends a request to JARVIS on your PC and speaks the answer. Anything JARVIS can do at the desk." }
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Request", requestValueDialog: "What would you like, sir?")
    var request: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let answer = try await IntentLink.run { client in
            let reply = try await client.request("ask", ["text": request], timeout: 90)
            return reply.kind == "answer" ? (reply.text("text") ?? "Done.") : reply.message
        }
        return .result(value: answer, dialog: IntentDialog(stringLiteral: answer))
    }
}

// MARK: - media and volume

enum MediaCommand: String, AppEnum {
    case playPause, next, previous

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Media command" }
    static var caseDisplayRepresentations: [MediaCommand: DisplayRepresentation] {
        [.playPause: "Play or pause", .next: "Next track", .previous: "Previous track"]
    }
}

struct MediaIntent: AppIntent {
    static var title: LocalizedStringResource { "Control music on my PC" }
    static var description: IntentDescription { "Play or pause, skip, or go back on whatever is playing on your PC." }
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Command", default: .playPause)
    var command: MediaCommand

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try await IntentLink.run { try await $0.request("media.action", ["action": command.rawValue]).message }
        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}

struct NowPlayingIntent: AppIntent {
    static var title: LocalizedStringResource { "What's playing on my PC" }
    static var description: IntentDescription { "Says the song and artist playing on your PC." }
    static var openAppWhenRun: Bool { false }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let sentence = try await IntentLink.run { client -> String in
            let b = try await client.request("media").body
            guard let title = b["title"] as? String else { return "Nothing is playing on your PC." }
            let artist = (b["artist"] as? String).map { " by \($0)" } ?? ""
            let paused = (b["playing"] as? Bool) == true ? "" : " (paused)"
            return "\(title)\(artist)\(paused)."
        }
        return .result(value: sentence, dialog: IntentDialog(stringLiteral: sentence))
    }
}

struct SetVolumeIntent: AppIntent {
    static var title: LocalizedStringResource { "Set my PC's volume" }
    static var description: IntentDescription { "Sets your PC's master volume." }
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Volume", description: "0 to 100", inclusiveRange: (0, 100))
    var percent: Int

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try await IntentLink.run { try await $0.request("volume", ["percent": percent]).message }
        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}

struct MuteIntent: AppIntent {
    static var title: LocalizedStringResource { "Mute my PC" }
    static var description: IntentDescription { "Mutes or unmutes your PC." }
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Muted", default: true)
    var muted: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try await IntentLink.run { try await $0.request("volume", ["muted": muted]).message }
        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}

// MARK: - the PC

struct PCStatusIntent: AppIntent {
    static var title: LocalizedStringResource { "How's my PC doing" }
    static var description: IntentDescription { "CPU, GPU and its temperature, memory, and what game is running." }
    static var openAppWhenRun: Bool { false }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let sentence = try await IntentLink.run { client -> String in
            let b = try await client.request("stats").body
            func n(_ key: String) -> Double? { (b[key] as? NSNumber)?.doubleValue }
            var parts: [String] = []
            if let cpu = n("cpu") { parts.append("CPU \(Int(cpu)) percent") }
            if let gpu = n("gpu") {
                parts.append("GPU \(Int(gpu)) percent" + (n("gpuTemperature").map { " at \(Int($0)) degrees" } ?? ""))
            }
            if let used = n("memoryUsedGb"), let total = n("memoryTotalGb") { parts.append(String(format: "memory %.0f of %.0f gigabytes", used, total)) }
            var sentence = parts.isEmpty ? "Your PC didn't say." : parts.joined(separator: ", ") + "."
            if let game = b["game"] as? String { sentence += " You're playing \(game)." }
            return sentence.prefix(1).uppercased() + sentence.dropFirst()
        }
        return .result(value: sentence, dialog: IntentDialog(stringLiteral: sentence))
    }
}

struct OpenOnPCIntent: AppIntent {
    static var title: LocalizedStringResource { "Open an app on my PC" }
    static var description: IntentDescription { "Opens an application or game on your PC by name, as \"open\" does at the desk." }
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "App or game", requestValueDialog: "What should I open?")
    var name: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try await IntentLink.run { try await $0.request("app.open", ["name": name], timeout: 60).message }
        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}

struct LockPCIntent: AppIntent {
    static var title: LocalizedStringResource { "Lock my PC" }
    static var description: IntentDescription { "Locks Windows on your PC, the same as Win+L." }
    static var openAppWhenRun: Bool { false }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try await IntentLink.run { try await $0.request("security.lock").message }
        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}

enum PowerCommand: String, AppEnum {
    case sleep, restart, shutdown

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Power" }
    static var caseDisplayRepresentations: [PowerCommand: DisplayRepresentation] {
        [.sleep: "Sleep", .restart: "Restart", .shutdown: "Shut down"]
    }
}

/// Sleep, restart or shut down: Siri confirms, then the app opens for Face ID, as the Control tab does.
struct PowerIntent: AppIntent {
    static var title: LocalizedStringResource { "Sleep, restart or shut down my PC" }
    static var description: IntentDescription { "Asks you to confirm, then opens JARVIS for Face ID." }
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Action", default: .sleep)
    var action: PowerCommand

    @MainActor
    func perform() async throws -> some IntentResult {
        let verb = action == .shutdown ? "shut down" : action.rawValue
        try await requestConfirmation(result: .result(dialog: "\(verb.prefix(1).uppercased() + verb.dropFirst()) your PC?"))
        AppModel.shared.pendingLink = URL(string: "jarvis://power/\(action.rawValue)")
        return .result()
    }
}

struct WatchPCIntent: AppIntent {
    static var title: LocalizedStringResource { "Watch my PC" }
    static var description: IntentDescription { "Opens live view of your PC's screen." }
    static var openAppWhenRun: Bool { true }

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared.pendingLink = URL(string: "jarvis://watch")
        return .result()
    }
}

// MARK: - clipboard

struct SendClipboardIntent: AppIntent {
    static var title: LocalizedStringResource { "Send my clipboard to the PC" }
    static var description: IntentDescription { "Puts this iPhone's copied text on your PC's clipboard." }
    static var openAppWhenRun: Bool { false }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            return .result(dialog: "There's no text on this iPhone's clipboard.")
        }
        let message = try await IntentLink.run { try await $0.request("clipboard.set", ["text": text]).message }
        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}

struct GetClipboardIntent: AppIntent {
    static var title: LocalizedStringResource { "Get my PC's clipboard" }
    static var description: IntentDescription { "Copies your PC's clipboard text to this iPhone." }
    static var openAppWhenRun: Bool { false }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = try await IntentLink.run { try await $0.request("clipboard.get").text("text") ?? "" }
        guard !text.isEmpty else { return .result(value: "", dialog: "Your PC's clipboard has no text.") }
        UIPasteboard.general.string = text
        return .result(value: text, dialog: "Copied from your PC.")
    }
}

// MARK: - macros

struct MacroEntity: AppEntity {
    let id: String
    let name: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Macro" }
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
    static var defaultQuery = MacroQuery()
}

struct MacroQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [MacroEntity] {
        MacroStore.shared.macros.filter { identifiers.contains($0.id.uuidString) }.map { MacroEntity(id: $0.id.uuidString, name: $0.name) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [MacroEntity] {
        MacroStore.shared.macros.filter { $0.name.localizedCaseInsensitiveContains(string) }.map { MacroEntity(id: $0.id.uuidString, name: $0.name) }
    }

    @MainActor
    func suggestedEntities() async throws -> [MacroEntity] {
        MacroStore.shared.macros.map { MacroEntity(id: $0.id.uuidString, name: $0.name) }
    }
}

struct RunMacroIntent: AppIntent {
    static var title: LocalizedStringResource { "Run a JARVIS macro" }
    static var description: IntentDescription { "Runs one of your macros from the Control tab." }
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Macro")
    var macro: MacroEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let found = MacroStore.shared.macros.first(where: { $0.id.uuidString == macro.id }) else {
            return .result(dialog: "I can't find that macro.")
        }
        let message = try await IntentLink.run { try await MacroRunner.run(found, on: $0) }
        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}

// MARK: - security

struct SecurityStatusIntent: AppIntent {
    static var title: LocalizedStringResource { "JARVIS security status" }
    static var description: IntentDescription { "Says what the Security Protocol on your PC is doing." }
    static var openAppWhenRun: Bool { false }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let description = try await IntentLink.run { client in
            let reply = try await client.request("security.status")
            return SecuritySnapshot(reply.body)?.description ?? "unavailable"
        }
        let sentence = "The Security Protocol is \(description)."
        return .result(value: sentence, dialog: IntentDialog(stringLiteral: sentence))
    }
}

struct InitiateSecurityIntent: AppIntent {
    static var title: LocalizedStringResource { "Initiate Security Protocol" }
    static var description: IntentDescription { "Puts the challenge up on your PC now. If it isn't answered, Windows locks." }
    static var openAppWhenRun: Bool { false }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try await IntentLink.run { try await $0.request("security.initiate").message }
        return .result(dialog: IntentDialog(stringLiteral: "Security Protocol: \(message)."))
    }
}

// MARK: - waking the PC

/// The one intent here that does not need the PC, because it is the one about a PC that is off.
///
/// Every other intent goes through `IntentLink`, which connects to the PC and asks it. This cannot:
/// a sleeping PC has nothing listening to be asked. So it goes to the same `WakeOnLanService` the
/// button on the home screen uses - one action, `device.power.wake`, reached by a button, by a typed
/// sentence, by the wake word and by Siri.
///
/// It reports a request sent, never a PC woken. There is no reply in Wake-on-LAN to learn otherwise
/// from; the app establishes the PC is awake by it answering the bridge, which is what the home
/// screen then waits for.
struct WakePCIntent: AppIntent {
    static var title: LocalizedStringResource { "Wake my PC" }
    static var description: IntentDescription {
        IntentDescription("Sends a wake request to your PC's network card. Works while the PC is asleep and JARVIS is not running - that is the point of it.")
    }

    // Opened on purpose: the app then waits for the PC to answer and shows it coming up, which is
    // the half of this that matters and cannot happen in a Shortcuts action that has already ended.
    static var openAppWhenRun: Bool { true }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = AppModel.shared
        let answer = model.wakeAnswer()
        model.wakePC()
        return .result(dialog: IntentDialog(stringLiteral: answer))
    }
}

// MARK: - Siri phrases

/// At most ten appear as Siri phrases; every intent above is in the Shortcuts app either way.
struct JarvisShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AskJarvisIntent(), phrases: ["Ask \(.applicationName)", "Talk to \(.applicationName)"],
                    shortTitle: "Ask JARVIS", systemImageName: "circle.hexagongrid")
        AppShortcut(intent: LockPCIntent(), phrases: ["Lock my PC with \(.applicationName)", "\(.applicationName) lock my PC"],
                    shortTitle: "Lock PC", systemImageName: "lock")
        AppShortcut(intent: PCStatusIntent(), phrases: ["How's my PC with \(.applicationName)", "\(.applicationName) PC status"],
                    shortTitle: "PC status", systemImageName: "gauge.medium")
        AppShortcut(intent: NowPlayingIntent(), phrases: ["What's playing on my PC with \(.applicationName)", "\(.applicationName) what's playing"],
                    shortTitle: "Now playing", systemImageName: "music.note")
        AppShortcut(intent: MediaIntent(), phrases: ["\(.applicationName) pause the music", "\(.applicationName) next song", "Control music with \(.applicationName)"],
                    shortTitle: "Music", systemImageName: "playpause")
        AppShortcut(intent: SetVolumeIntent(), phrases: ["Set PC volume with \(.applicationName)", "\(.applicationName) volume"],
                    shortTitle: "PC volume", systemImageName: "speaker.wave.2")
        AppShortcut(intent: OpenOnPCIntent(), phrases: ["Open an app on my PC with \(.applicationName)", "\(.applicationName) open on my PC"],
                    shortTitle: "Open on PC", systemImageName: "macwindow")
        AppShortcut(intent: RunMacroIntent(), phrases: ["Run \(\.$macro) with \(.applicationName)", "\(.applicationName) run \(\.$macro)"],
                    shortTitle: "Run macro", systemImageName: "sparkles")
        AppShortcut(intent: WatchPCIntent(), phrases: ["Watch my PC with \(.applicationName)", "\(.applicationName) show my screen"],
                    shortTitle: "Watch PC", systemImageName: "display")
        AppShortcut(intent: WakePCIntent(),
                    phrases: ["\(.applicationName) wake my PC", "Wake my PC with \(.applicationName)",
                              "\(.applicationName) turn my computer on", "\(.applicationName) start my PC"],
                    shortTitle: "Wake PC", systemImageName: "power")
        AppShortcut(intent: SecurityStatusIntent(), phrases: ["\(.applicationName) security status"],
                    shortTitle: "Security status", systemImageName: "lock.shield")
    }
}

/// A short-lived connection for an intent: resume, run, close. Tries home first, then the away-from-home address.
enum IntentLink {
    struct NotPaired: LocalizedError {
        var errorDescription: String? { "JARVIS isn't paired with a PC yet. Open the app to pair." }
    }

    static func run<T>(_ body: (BridgeClient) async throws -> T) async throws -> T {
        guard let pc = PairedPC.load() else { throw NotPaired() }
        var lastError: Error = BridgeError.closed

        for endpoint in [pc.endpoint] + [pc.remoteEndpoint].compactMap({ $0 }) {
            let client = BridgeClient(endpoint: endpoint)
            do {
                _ = try await client.resume(deviceId: pc.deviceId, pinnedServerKey: pc.serverKey)
            } catch {
                await client.close()
                lastError = error
                if (error as? BridgeError)?.needsPairingAgain == true { throw error }
                continue
            }
            defer { Task { await client.close() } }
            return try await body(client)
        }

        throw lastError
    }
}
