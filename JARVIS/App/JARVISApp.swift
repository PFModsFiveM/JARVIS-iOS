import SwiftUI
import UIKit

@main
struct JARVISApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared
    @Environment(\.scenePhase) private var scenePhase

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
                        .tabItem { Label("Control", systemImage: "slider.horizontal.3") }
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
                .task {
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
