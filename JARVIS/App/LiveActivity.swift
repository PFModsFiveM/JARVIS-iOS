import ActivityKit
import Combine
import Foundation

/// Keeps one JARVIS Live Activity in step with the app: the most important thing happening is what it shows - a
/// power countdown, then a transfer, then control, then live view, then JARVIS listening, thinking or speaking - and
/// it ends a few seconds after nothing is.
@MainActor
final class LiveActivity {
    static let shared = LiveActivity()

    private var activity: Activity<JarvisActivityAttributes>?
    private var ending: Task<Void, Never>?
    private var lastState: JarvisActivityAttributes.ContentState?

    /// What happened last with power, so the countdown can be shown until it runs out or is cancelled.
    var powerEndsAt: Date?
    var powerTitle = ""
    /// JARVIS's last answer, shown while it speaks.
    var answer = ""

    private var watching: Set<AnyCancellable> = []

    private init() {}

    /// Follows every change to the app's state, a moment later so the change has landed. Called once from the root
    /// view rather than from an initialiser, because the models it watches are themselves being built at launch.
    func start() {
        guard watching.isEmpty else { return }
        let changes = AppModel.shared.objectWillChange.merge(with: ControlModel.shared.objectWillChange)
        changes
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
            .store(in: &watching)
    }

    /// A restart or shut-down was asked for: count it down on the lock screen, with Cancel.
    func powerStarted(_ title: String, seconds: Double) {
        powerTitle = title
        powerEndsAt = Date().addingTimeInterval(seconds)
        refresh()
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((seconds + 1) * 1_000_000_000))
            self?.refresh()
        }
    }

    func powerCancelled() {
        powerEndsAt = nil
        refresh()
    }

    /// Works out what the activity should say now and makes it so. Cheap to call on every change.
    func refresh() {
        let model = AppModel.shared
        let control = ControlModel.shared
        let now = Date()
        var state: JarvisActivityAttributes.ContentState?

        if let ends = powerEndsAt, ends > now {
            state = .init(mode: .power, title: powerTitle, detail: model.pcName, progress: nil, endsAt: ends)
        } else if let transfer = control.transfer {
            state = .init(mode: .transfer, title: transfer.name, detail: "\(Int(transfer.progress * 100))%", progress: transfer.progress, endsAt: nil)
        } else if model.controlling, let display = model.liveDisplay {
            state = .init(mode: .controlling, title: "Controlling display \(display + 1)", detail: model.network.cellular ? "Mobile data" : "Wi-Fi", progress: nil, endsAt: nil)
        } else if let display = model.liveDisplay {
            state = .init(mode: .watching, title: "Watching display \(display + 1)", detail: model.network.cellular ? "Mobile data" : "Wi-Fi", progress: nil, endsAt: nil)
        } else if model.speaking {
            state = .init(mode: .speaking, title: "JARVIS", detail: answer, progress: nil, endsAt: nil)
        } else if model.thinking || model.awaitingVoice {
            state = .init(mode: .thinking, title: "JARVIS is working", detail: "", progress: nil, endsAt: nil)
        } else if case .hearing(let words) = model.wakePhase {
            state = .init(mode: .listening, title: "Listening", detail: words, progress: nil, endsAt: nil)
        }

        guard let state else {
            scheduleEnd()
            return
        }

        ending?.cancel()
        ending = nil
        guard state != lastState else { return }
        lastState = state
        show(state, pc: model.pcName)
    }

    private func show(_ state: JarvisActivityAttributes.ContentState, pc: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let content = ActivityContent(state: state, staleDate: state.endsAt.map { $0.addingTimeInterval(5) })

        if let activity, activity.activityState == .active {
            Task { await activity.update(content) }
        } else {
            activity = try? Activity.request(attributes: JarvisActivityAttributes(pcName: pc), content: content, pushType: nil)
        }
    }

    /// Nothing is happening: keep the last state up briefly (an answer to read, a finished transfer), then end.
    private func scheduleEnd() {
        guard activity != nil, ending == nil else { return }
        ending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.activity?.end(nil, dismissalPolicy: .immediate)
            self.activity = nil
            self.lastState = nil
            self.ending = nil
        }
    }
}
