import Foundation

/// A general question answered without the PC.
///
/// Mobile JARVIS stops being JARVIS the moment the PC goes to sleep if the only thing it can do is
/// read a battery and switch a light. This is the third lane: a question with no device and no
/// machine in it - "how long does concrete take to cure", "what's a good interior for a tow
/// company" - answered by a provider this phone talks to itself.
///
/// **It is text in and text out, and that is a security boundary rather than a simplification.**
/// The PC's own intelligence has tools: it can open applications, move windows, read files and
/// switch things in the house. A provider reached from a phone has none of that and must never
/// acquire any, because the phone cannot verify what it would be acting on and the owner is not at
/// the desk to see it happen. So this returns a sentence. Anything that needs doing at the desk is
/// `pcPrime`'s, and waits for the PC - which is the honest answer and also the safe one.
///
/// **Nothing is shipped with a key.** The owner puts their own in, it lives in the Keychain, and
/// until they do `isConfigured` is false and the router never chooses this lane.
enum CloudProviderKind: String, Codable, CaseIterable, Equatable {
    case anthropic

    var display: String {
        switch self {
        case .anthropic: return "Anthropic"
        }
    }

    /// Where the owner gets a key, so the settings page can say it without hard-coding a URL twice.
    var where_: String {
        switch self {
        case .anthropic: return "console.anthropic.com"
        }
    }
}

/// The owner's own provider credential, in the Keychain and nowhere else.
///
/// `description` prints nothing, so a key cannot reach a log through string interpolation - the
/// same protection `SwitchBotCredentials` has, for the same reason.
struct CloudCredential: Equatable, Codable, CustomStringConvertible {
    let kind: CloudProviderKind
    let key: String
    /// The model the owner chose, or empty for this phone's default.
    var model: String

    var description: String { "CloudCredential(\(kind.rawValue), ***)" }

    var usable: Bool { !key.isEmpty }

    private static let account = "cloud-intelligence"

    static func load() -> CloudCredential? {
        guard let data = Keychain.read(account),
              let stored = try? JSONDecoder().decode(CloudCredential.self, from: data),
              stored.usable
        else { return nil }

        return stored
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        Keychain.write(Self.account, data)
    }

    static func forget() { Keychain.delete(account) }
}

/// What a provider can be asked, and what it is allowed to give back.
///
/// One method, returning a string. Deliberately narrow: a protocol that could return an action is a
/// protocol a future provider could use to act, and the point of this type is that it cannot.
protocol CloudAnswering {
    func answer(_ question: String, context: [String], timeout: TimeInterval) async throws -> String
}

/// Why a cloud answer did not happen, in words the owner would recognise.
enum CloudProblem: LocalizedError, Equatable {
    case notConfigured
    case refused(String)
    case unreachable
    case emptyAnswer

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "This phone has no cloud provider of its own yet. Add a key in Settings and I can answer general questions without your PC."
        case .refused(let why):
            return why
        case .unreachable:
            return "I couldn't reach the provider from here."
        case .emptyAnswer:
            return "The provider answered, but said nothing I could pass on."
        }
    }
}

/// Anthropic's Messages API, as little of it as this needs.
struct AnthropicAnswering: CloudAnswering {
    let credential: CloudCredential
    var send: (URLRequest) async throws -> (Data, URLResponse) = { request in
        try await URLSession(configuration: .ephemeral).data(for: request)
    }

    /// The model used when the owner has not named one.
    static let defaultModel = "claude-sonnet-4-5"

    static let version = "2023-06-01"

    func answer(_ question: String, context: [String], timeout: TimeInterval) async throws -> String {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else { throw CloudProblem.unreachable }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(credential.key, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.version, forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": credential.model.isEmpty ? Self.defaultModel : credential.model,
            "max_tokens": 700,
            "system": Self.system(context),
            "messages": [["role": "user", "content": question]]
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let data: Data
        do {
            let (received, response) = try await send(request)

            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw CloudProblem.refused(Self.refusal(http.statusCode, received))
            }

            data = received
        } catch let problem as CloudProblem {
            throw problem
        } catch {
            throw CloudProblem.unreachable
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudProblem.emptyAnswer
        }

        let text = ((json["content"] as? [[String: Any]]) ?? [])
            .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else { throw CloudProblem.emptyAnswer }

        return text
    }

    /// A status code as something the owner can act on. Never the key, and never the raw body.
    static func refusal(_ code: Int, _ data: Data) -> String {
        switch code {
        case 401, 403:
            return "The provider didn't accept this phone's key. Check it in Settings."
        case 429:
            return "The provider is rate-limiting that key. Try again shortly."
        case 500...599:
            return "The provider is having trouble at its end."
        default:
            return "The provider refused it."
        }
    }

    /// Who JARVIS is, and - the part that matters - what it must not pretend to be able to do.
    ///
    /// A provider that does not know the PC is off will happily say "I've opened Blender for you",
    /// and a phone that read that out would be lying on JARVIS's behalf. So the limit is stated,
    /// not hoped for.
    static func system(_ context: [String]) -> String {
        var lines = [
            "You are JARVIS, answering on the owner's iPhone while their PC is not reachable.",
            "Address the owner as \"sir\". Be concise and useful; no preamble.",
            "You are the mobile node. You cannot open applications, control Windows, read the owner's files, move windows, or switch anything in the house. Never claim to have done any of those things.",
            "If the request needs the PC, say plainly that it needs the PC and that you will carry it out once the PC is reachable."
        ]

        if !context.isEmpty {
            lines.append("What JARVIS already knows that may bear on this:")
            lines.append(contentsOf: context.map { "- \($0)" })
        }

        return lines.joined(separator: "\n")
    }
}

/// The phone's cloud lane: whether there is one, and asking it.
@MainActor
final class CloudIntelligence: ObservableObject {
    static let shared = CloudIntelligence()

    @Published private(set) var credential: CloudCredential? = CloudCredential.load()

    /// The last thing that went wrong, for the diagnostics page. Never a key.
    @Published private(set) var problem: String?

    /// When the provider last answered. Shown so "configured" and "working" are different words.
    @Published private(set) var lastAnswerAt: Date?

    /// Pinned by the tests; the live one talks to the provider.
    var answering: ((CloudCredential) -> CloudAnswering)?

    var isConfigured: Bool { credential?.usable == true }

    func remember(kind: CloudProviderKind, key: String, model: String) {
        let stored = CloudCredential(
            kind: kind,
            key: key.trimmingCharacters(in: .whitespacesAndNewlines),
            model: model.trimmingCharacters(in: .whitespacesAndNewlines))

        guard stored.usable else { return }

        stored.save()
        credential = stored
        problem = nil
        CloudStatus.shared.configured(true)
    }

    func forget() {
        CloudCredential.forget()
        credential = nil
        problem = nil
        lastAnswerAt = nil
        CloudStatus.shared.configured(false)
    }

    /// Asks the provider, and reports a failure as words rather than as an error the owner reads raw.
    func ask(
        _ question: String,
        context: [String] = [],
        timeout: TimeInterval = CloudStatus.timeout,
        status: CloudStatus? = nil
    ) async -> String {
        let watching = status ?? CloudStatus.shared

        guard let credential else {
            watching.failed(.notConfigured)
            problem = CloudProblem.notConfigured.errorDescription
            return problem ?? ""
        }

        watching.configured(true)

        let provider = answering?(credential) ?? AnthropicAnswering(credential: credential)

        do {
            let answer = try await provider.answer(question, context: context, timeout: timeout)
            problem = nil
            lastAnswerAt = Date()
            watching.worked()
            return answer
        } catch let trouble as CloudProblem {
            problem = trouble.errorDescription
            watching.failed(trouble)
            return problem ?? ""
        } catch is CancellationError {
            // The owner stopped it - priority §8B. Not a failure of the lane, and recording it as
            // one would label a working provider broken because somebody changed their mind.
            watching.stopped()
            problem = nil
            return ""
        } catch let trouble as URLError where trouble.code == .cancelled {
            watching.stopped()
            problem = nil
            return ""
        } catch let trouble as URLError where trouble.code == .timedOut {
            watching.ranOut()
            problem = watching.lastProblem
            return problem ?? ""
        } catch {
            problem = CloudProblem.unreachable.errorDescription
            watching.failed(.unreachable)
            return problem ?? ""
        }
    }
}
