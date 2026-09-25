import SwiftUI
import UIKit

@main
struct JARVISApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        HUDChrome.apply()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .tint(HUD.accent)
        }
        .onChange(of: scenePhase) { _, phase in
            model.scenePhaseChanged(phase)
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Alerts.shared.register()
        return true
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @State private var tab = "jarvis"

    var body: some View {
        Group {
            if model.pc == nil {
                PairingView()
            } else {
                TabView(selection: $tab) {
                    HomeView()
                        .tabItem { Label("JARVIS", systemImage: "circle.hexagongrid") }
                        .tag("jarvis")
                    ControlView()
                        .tabItem { Label("Home", systemImage: "house") }
                        .tag("control")
                    ScreenView()
                        .tabItem { Label("PC", systemImage: "display") }
                        .tag("pc")
                    SecurityView()
                        .tabItem { Label("Security", systemImage: "lock.shield") }
                        .tag("security")
                    SettingsView()
                        .tabItem { Label("Settings", systemImage: "gearshape") }
                        .tag("settings")
                }
                // One tint for the whole app, so every toggle, slider and selected tab is the HUD's
                // cyan rather than the system blue or green.
                .tint(HUD.accent)
                .task {
                    LiveActivity.shared.start()
                    await model.connect()
                    if model.wakeWordOn { await model.setWakeWord(true) }
                }
            }
        }
        .overlay(alignment: .top) {
            if let toast = model.toast, model.pc != nil {
                Text(toast)
                    .font(.footnote)
                    .foregroundStyle(HUD.text)
                    .padding(10)
                    .background(HUD.panel)
                    .overlay(Rectangle().stroke(HUD.accent.opacity(0.5), lineWidth: 1))
                    .padding(.top, 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onTapGesture { model.toast = nil }
                    .task(id: toast) {
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        if model.toast == toast { model.toast = nil }
                    }
            }
        }
        .animation(.easeOut, value: model.toast)
        .onOpenURL { url in open(url) }
        .onChange(of: model.pendingLink) { _, link in
            // Siri and Shortcuts hand the app a link to act on once it is open.
            guard let link else { return }
            model.pendingLink = nil
            open(link)
        }
    }

    /// The widget, the lock screen and Control Centre open the app with a jarvis:// link saying what to do.
    private func open(_ url: URL) {
        guard url.scheme == "jarvis", model.pc != nil else { return }
        switch url.host {
        case "lock":
            tab = "security"
            Task { await model.connect(); await model.securityAction("lock") }
        case "watch":
            tab = "pc"
        case "control":
            tab = "control"
        case "cancelpower":
            Task { await ControlModel.shared.power("cancel") }
        case "stopwatch":
            tab = "pc"
            model.releaseControl()
            Task { await model.stopLive() }
        case "power":
            // From Siri: "restart my PC" confirmed there, Face ID here.
            let action = url.lastPathComponent
            if ["sleep", "restart", "shutdown"].contains(action) {
                tab = "control"
                Task { await model.connect(); await ControlModel.shared.power(action) }
            }
        case "macro":
            let name = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
            if let macro = MacroStore.shared.macro(named: name) {
                tab = "control"
                Task {
                    await model.connect()
                    if let client = try? await model.session() {
                        model.toast = (try? await MacroRunner.run(macro, on: client)) ?? "\(macro.name) didn't finish."
                    }
                }
            }
        case "talk":
            tab = "jarvis"
            Task {
                await model.connect()
                await model.listenOnce()
            }
        default:
            break
        }
    }
}
