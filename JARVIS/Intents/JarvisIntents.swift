import AppIntents
import Foundation

/// Siri, Shortcuts and the Action button. Each intent connects to the PC, does one thing, and answers.
struct AskJarvisIntent: AppIntent {
    static var title: LocalizedStringResource { "Ask JARVIS" }
    static var description: IntentDescription { "Sends a request to JARVIS on your PC and speaks the answer." }
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

struct JarvisShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AskJarvisIntent(), phrases: ["Ask \(.applicationName)", "Talk to \(.applicationName)"],
                    shortTitle: "Ask JARVIS", systemImageName: "circle.hexagongrid")
        AppShortcut(intent: LockPCIntent(), phrases: ["Lock my PC with \(.applicationName)", "\(.applicationName) lock my PC"],
                    shortTitle: "Lock PC", systemImageName: "lock")
        AppShortcut(intent: SecurityStatusIntent(), phrases: ["\(.applicationName) security status"],
                    shortTitle: "Security status", systemImageName: "lock.shield")
        AppShortcut(intent: InitiateSecurityIntent(), phrases: ["Initiate security protocol with \(.applicationName)"],
                    shortTitle: "Initiate security", systemImageName: "exclamationmark.shield")
    }
}

/// A short-lived connection for an intent: resume, run, close.
enum IntentLink {
    struct NotPaired: LocalizedError {
        var errorDescription: String? { "JARVIS isn't paired with a PC yet. Open the app to pair." }
    }

    static func run<T>(_ body: (BridgeClient) async throws -> T) async throws -> T {
        guard let pc = PairedPC.load() else { throw NotPaired() }
        let client = BridgeClient(endpoint: pc.endpoint)
        defer { Task { await client.close() } }
        _ = try await client.resume(deviceId: pc.deviceId, pinnedServerKey: pc.serverKey)
        return try await body(client)
    }
}
