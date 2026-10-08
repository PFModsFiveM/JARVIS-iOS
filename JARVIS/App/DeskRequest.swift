import Foundation

/// Something the owner asked of a PC that was asleep, kept until the PC can hear it - §4.
///
/// **Why the phone keeps it.** "Jarvis, boot my PC and open my latest Blender project" is two
/// requests with a gap between them. The phone can send the wake packet; nothing can open a
/// project until the machine is up, signed in and running JARVIS - a minute at best, several at
/// worst. Holding the second request open across that gap is the design that fails on every
/// dropped connection, every cellular handover and every phone that gets locked and put in a
/// pocket, which is to say always.
///
/// So this phone keeps the intention itself and offers it on the first connection that succeeds.
/// It is already retrying from the moment it sends the wake, so there is nothing new to build and
/// nothing is held open anywhere. It also means the PC's service gains no new verb and no file
/// becomes an instruction: the node that remembers is the node that asked.
struct DeskRequest: Codable, Equatable {
    /// This phone's own id for the request, which is what makes it idempotent on the PC: offered
    /// twice through a bad connection, it is still one task.
    let taskId: String

    /// The project the owner named, or empty for the one they were last on. Advisory: the PC
    /// resolves it against what it can see, and asks when two projects are too close to separate.
    let project: String

    let askedAt: Date

    /// After this it is not offered. Two hours, matching the PC's own bound: long enough for a
    /// machine that needed a power cycle and a slow sign-in, short enough that a request made at
    /// lunchtime does not open Blender when the owner sits down in the evening to do something
    /// else.
    let expiresAt: Date

    static let lastsFor: TimeInterval = 2 * 60 * 60

    init(project: String, now: Date = Date(), id: String = UUID().uuidString) {
        // Hyphens and hex only, which is what the PC's own check accepts. A UUID already is that;
        // saying so here means a change to either end breaks loudly rather than quietly.
        self.taskId = id
        self.project = DeskRequest.plain(project)
        self.askedAt = now
        self.expiresAt = now.addingTimeInterval(DeskRequest.lastsFor)
    }

    func live(_ now: Date = Date()) -> Bool { now < expiresAt }

    /// What may be sent as a project name.
    ///
    /// Letters, digits, spaces and three marks - the same set the PC accepts, and for the same
    /// reason: a name that could be read as a path must not be able to become one. Trimmed rather
    /// than refused here because this is the owner's own phone transcribing their own voice, and
    /// the PC refuses what survives if it is still wrong.
    static func plain(_ said: String) -> String {
        let kept = said.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) || " _-'".unicodeScalars.contains($0) }
            .map(Character.init)

        return String(String(kept).trimmingCharacters(in: .whitespaces).prefix(80))
    }
}

/// The one request waiting for the desk to answer.
///
/// One, not a queue. The owner asking twice means they want it once, and a second request would
/// replace the first rather than queue behind it - which is what they would expect and also what
/// keeps this from becoming a way to fill the PC's task list from a phone.
@MainActor
final class DeskRequests: ObservableObject {
    static let shared = DeskRequests()

    private static let key = "jarvis.desk.pending"

    @Published private(set) var waiting: DeskRequest?

    private let store: UserDefaults

    init(store: UserDefaults = .standard) {
        self.store = store

        if let data = store.data(forKey: Self.key),
           let held = try? JSONDecoder().decode(DeskRequest.self, from: data) {
            waiting = held
        }
    }

    /// Keeps a request until the desk can hear it.
    func hold(_ request: DeskRequest) {
        waiting = request

        if let data = try? JSONEncoder().encode(request) {
            store.set(data, forKey: Self.key)
        }
    }

    /// What should be offered now, or nil. Expiry is checked here so a stale request is dropped
    /// rather than sent to a PC that would refuse it.
    func toOffer(_ now: Date = Date()) -> DeskRequest? {
        guard let waiting else { return nil }

        if !waiting.live(now) {
            forget()
            return nil
        }

        return waiting
    }

    /// Forgotten once the PC has taken it on, or once the owner changes their mind.
    func forget() {
        waiting = nil
        store.removeObject(forKey: Self.key)
    }
}
