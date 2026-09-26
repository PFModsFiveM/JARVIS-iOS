import Foundation

/// The PC's one learning session, as the phone sees it - the `BridgeLearning` shape.
///
/// JARVIS on the PC writes every turn down, notices when it was corrected or repeated, and learns
/// from it. A learning session is the deliberate sweep over all of that. There is exactly one, on
/// the PC: this phone can start it, watch it and stop it, and so can the PC, and a second start is
/// refused wherever it comes from. Progress is the PC's own counts - "step 2 of 5, 140 of 812" -
/// never a percentage made up to look busy.
struct LearningStatus: Equatable {
    let running: Bool
    let state: String
    let phase: String?
    let step: Int
    let steps: Int
    let done: Int
    let of: Int
    let origin: String?
    /// The PC's own sentence for where it is, so both screens say the same thing.
    let said: String

    static let unknown = LearningStatus(running: false, state: "unknown", phase: nil, step: 0, steps: 0, done: 0, of: 0, origin: nil,
                                        said: "Ask the PC how its learning is going.")

    init(running: Bool, state: String, phase: String?, step: Int, steps: Int, done: Int, of: Int, origin: String?, said: String) {
        self.running = running
        self.state = state
        self.phase = phase
        self.step = step
        self.steps = steps
        self.done = done
        self.of = of
        self.origin = origin
        self.said = said
    }

    init?(_ row: [String: Any]?) {
        guard let row, let state = row["state"] as? String else { return nil }

        running = row["running"] as? Bool ?? false
        self.state = state
        phase = row["phase"] as? String
        step = (row["step"] as? NSNumber)?.intValue ?? 0
        steps = (row["steps"] as? NSNumber)?.intValue ?? 0
        done = (row["done"] as? NSNumber)?.intValue ?? 0
        of = (row["of"] as? NSNumber)?.intValue ?? 0
        origin = row["origin"] as? String
        said = row["said"] as? String ?? ""
    }

    /// How far through the current step, when the step has items to count. Nil otherwise - a step
    /// without items is shown as a step, not as a bar that never moves.
    var stepFraction: Double? { of > 0 ? min(1, Double(done) / Double(of)) : nil }
}

@MainActor
final class LearningModel: ObservableObject {
    static let shared = LearningModel()

    @Published private(set) var status = LearningStatus.unknown
    @Published private(set) var message: String?

    private let model: AppModel

    init(model: AppModel = .shared) {
        self.model = model
    }

    /// Asks the PC where its session is. Quietly: a PC that predates learning sessions answers
    /// "failed", and the card says so rather than pretending.
    func refresh() async {
        guard model.link.isOnline, let client = try? await model.session() else { return }

        guard let reply = try? await client.request("learning"), reply.kind == "learning" else {
            message = "This PC's JARVIS doesn't have learning sessions yet."
            return
        }

        apply(reply)
    }

    func start() async {
        await send("learning.start")
    }

    func stop() async {
        await send("learning.stop")
        await refresh()
    }

    /// A `learning.changed` push: the session moved a step or counted further.
    func receive(_ message: BridgeMessage) {
        if let next = LearningStatus(message.object("session")) { status = next }
    }

    private func send(_ kind: String) async {
        message = nil

        do {
            let client = try await model.session()
            let reply = try await client.request(kind, [:], timeout: 15)

            if reply.kind == "failed" {
                message = reply.message
            } else {
                apply(reply)
                message = reply.text("message")
            }
        } catch {
            message = "Couldn't reach your PC."
        }
    }

    private func apply(_ reply: BridgeMessage) {
        if let next = LearningStatus(reply.object("session")) { status = next }
    }
}
