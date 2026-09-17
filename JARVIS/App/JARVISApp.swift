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

    var body: some View {
        Group {
            if model.pc == nil {
                PairingView()
            } else {
                TabView {
                    HomeView()
                        .tabItem { Label("JARVIS", systemImage: "circle.hexagongrid") }
                    SecurityView()
                        .tabItem { Label("Security", systemImage: "lock.shield") }
                    SettingsView()
                        .tabItem { Label("Settings", systemImage: "gearshape") }
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
    }
}
