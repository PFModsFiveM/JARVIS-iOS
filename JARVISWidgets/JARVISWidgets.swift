import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// JARVIS on the home screen, the lock screen and in Control Centre. Every button opens the app at the right place
/// through a `jarvis://` link; the app, which holds the keys, does the rest. (A widget cannot reach the PC itself: it has
/// no connection, and the keys never leave the app's Keychain.)
@main
struct JARVISWidgets: WidgetBundle {
    var body: some Widget {
        QuickActionsWidget()
        LockScreenWidget()
        JarvisLiveActivity()
        LockPCControl()
        WatchPCControl()
        TalkControl()
    }
}

// MARK: - links

enum JarvisLink {
    static let lock = URL(string: "jarvis://lock")!
    static let watch = URL(string: "jarvis://watch")!
    static let talk = URL(string: "jarvis://talk")!
    static let control = URL(string: "jarvis://control")!
}

private let cyan = Color(red: 0.24, green: 0.82, blue: 1.0)
private let ground = Color(red: 0.02, green: 0.04, blue: 0.06)

// MARK: - home screen

struct QuickActionsEntry: TimelineEntry {
    let date: Date
}

struct QuickActionsProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuickActionsEntry { QuickActionsEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (QuickActionsEntry) -> Void) { completion(QuickActionsEntry(date: .now)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<QuickActionsEntry>) -> Void) {
        completion(Timeline(entries: [QuickActionsEntry(date: .now)], policy: .never))
    }
}

struct QuickActionsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "JARVISQuickActions", provider: QuickActionsProvider()) { _ in
            QuickActionsView()
                .containerBackground(ground, for: .widget)
        }
        .configurationDisplayName("JARVIS")
        .description("Talk to JARVIS, watch your PC, open the controls, or lock the PC.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct QuickActionsView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if family == .systemSmall {
            VStack(spacing: 8) {
                Image(systemName: "circle.hexagongrid.fill").font(.system(size: 34)).foregroundStyle(cyan)
                Text("JARVIS").font(.system(size: 13, weight: .heavy, design: .monospaced)).foregroundStyle(cyan)
                Text("Tap to talk").font(.caption2).foregroundStyle(.secondary)
            }
            .widgetURL(JarvisLink.talk)
        } else {
            HStack(spacing: 10) {
                action("mic.fill", "Talk", JarvisLink.talk)
                action("display", "Watch", JarvisLink.watch)
                action("slider.horizontal.3", "Control", JarvisLink.control)
                action("lock.fill", "Lock", JarvisLink.lock)
            }
        }
    }

    private func action(_ symbol: String, _ title: String, _ url: URL) -> some View {
        Link(destination: url) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(cyan)
                Text(title).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(cyan.opacity(0.10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(cyan.opacity(0.35), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

// MARK: - lock screen

struct LockScreenWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "JARVISLockScreen", provider: QuickActionsProvider()) { _ in
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "circle.hexagongrid.fill").font(.system(size: 22))
            }
            .widgetURL(JarvisLink.talk)
            .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Talk to JARVIS")
        .description("Opens JARVIS listening.")
        .supportedFamilies([.accessoryCircular])
    }
}

// MARK: - Control Centre and the Action button

struct LockPCControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "uk.jarvis.phone.lockpc") {
            ControlWidgetButton(action: OpenURLIntent(JarvisLink.lock)) {
                Label("Lock PC", systemImage: "lock.desktopcomputer")
            }
        }
        .displayName("Lock PC")
        .description("Locks your PC through JARVIS.")
    }
}

struct WatchPCControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "uk.jarvis.phone.watch") {
            ControlWidgetButton(action: OpenURLIntent(JarvisLink.watch)) {
                Label("Watch PC", systemImage: "display")
            }
        }
        .displayName("Watch PC")
        .description("Opens live view of your PC.")
    }
}

struct TalkControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "uk.jarvis.phone.talk") {
            ControlWidgetButton(action: OpenURLIntent(JarvisLink.talk)) {
                Label("Talk to JARVIS", systemImage: "mic.fill")
            }
        }
        .displayName("Talk to JARVIS")
        .description("Opens JARVIS listening.")
    }
}

// MARK: - Live Activity and the Dynamic Island

/// What JARVIS is doing right now, on the lock screen and in the Dynamic Island: a power countdown with Cancel, a
/// transfer's progress, live view or control with Stop, or JARVIS listening, thinking and answering.
struct JarvisLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: JarvisActivityAttributes.self) { context in
            LiveActivityBanner(state: context.state, pc: context.attributes.pcName)
                .padding(14)
                .activityBackgroundTint(ground)
                .activitySystemActionForegroundColor(cyan)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: state.symbol).font(.title2).foregroundStyle(activityTint(state))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let ends = state.endsAt {
                        Text(timerInterval: Date()...max(Date(), ends), countsDown: true)
                            .font(.system(.title3, design: .monospaced)).foregroundStyle(activityTint(state))
                            .frame(maxWidth: 64)
                    } else if let progress = state.progress {
                        Text("\(Int(progress * 100))%").font(.system(.title3, design: .monospaced)).foregroundStyle(cyan)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(state.title).font(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        if !state.detail.isEmpty {
                            Text(state.detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                        }
                        if let progress = state.progress {
                            ProgressView(value: progress).tint(cyan)
                        }
                        if let action = state.action {
                            Link(destination: action) {
                                Text(state.actionTitle).font(.system(.body, design: .monospaced).weight(.bold))
                                    .frame(maxWidth: .infinity).padding(.vertical, 6)
                                    .background(activityTint(state).opacity(0.25)).clipShape(Capsule())
                            }
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: state.symbol).foregroundStyle(activityTint(state))
            } compactTrailing: {
                if let ends = state.endsAt {
                    Text(timerInterval: Date()...max(Date(), ends), countsDown: true)
                        .monospacedDigit().frame(maxWidth: 40).foregroundStyle(activityTint(state))
                } else if let progress = state.progress {
                    Text("\(Int(progress * 100))%").monospacedDigit().foregroundStyle(cyan)
                } else {
                    Text("JARVIS").font(.caption2.weight(.heavy)).foregroundStyle(cyan)
                }
            } minimal: {
                Image(systemName: state.symbol).foregroundStyle(activityTint(state))
            }
            .widgetURL(URL(string: "jarvis://open"))
            .keylineTint(activityTint(state))
        }
    }
}

private func activityTint(_ state: JarvisActivityAttributes.ContentState) -> Color {
    switch state.mode {
    case .power: return Color(red: 1.0, green: 0.35, blue: 0.3)
    case .controlling: return Color(red: 1.0, green: 0.72, blue: 0.2)
    default: return cyan
    }
}

struct LiveActivityBanner: View {
    let state: JarvisActivityAttributes.ContentState
    let pc: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: state.symbol).font(.title2).foregroundStyle(activityTint(state))
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title).font(.headline).foregroundStyle(.white).lineLimit(1)
                    Text(pc).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let ends = state.endsAt {
                    Text(timerInterval: Date()...max(Date(), ends), countsDown: true)
                        .font(.system(.title2, design: .monospaced)).foregroundStyle(activityTint(state)).frame(maxWidth: 80)
                }
            }
            if !state.detail.isEmpty {
                Text(state.detail).font(.subheadline).foregroundStyle(.white.opacity(0.85)).lineLimit(3)
            }
            if let progress = state.progress {
                ProgressView(value: progress).tint(cyan)
            }
            if let action = state.action {
                Link(destination: action) {
                    Text(state.actionTitle).font(.system(.body, design: .monospaced).weight(.bold)).foregroundStyle(activityTint(state))
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background(activityTint(state).opacity(0.18)).clipShape(Capsule())
                }
            }
        }
    }
}
