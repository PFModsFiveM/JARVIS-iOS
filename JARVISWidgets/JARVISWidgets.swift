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
