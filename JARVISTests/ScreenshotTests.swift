import SwiftUI
import UIKit
import XCTest
@testable import JARVIS

/// Pictures of the real screens, for looking at rather than asserting on.
///
/// The app is built on a Mac nobody here has, so the only way to see a change to the interface is to
/// have CI draw it. Each screen is put in a real window and drawn with `drawHierarchy`, which renders
/// text fields, toggles and tab bars the way the phone does - `ImageRenderer` would leave those as
/// placeholders. The PNGs are written to the directory CI names in `SCREENSHOTS` and uploaded with the
/// run. With no directory set - Xcode on a desk, Cmd-U - the test skips itself.
@MainActor
final class ScreenshotTests: XCTestCase {
    private var directory: URL? {
        ProcessInfo.processInfo.environment["SCREENSHOTS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    func testDrawTheScreens() throws {
        guard let directory else { throw XCTSkip("SCREENSHOTS is not set; the pictures are a CI artefact") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let model = AppModel.shared
        model.pc = PairedPC(deviceId: "screenshot", serverKey: Data(repeating: 1, count: 65), serviceName: "DOM-PC", host: "192.0.2.1", port: 7788)
        model.showcase(pcName: "DOM-PC", lines: [
            (.you, "Turn the bedroom light off"),
            (.jarvis, "Bedroom Light is off, sir."),
            (.you, "What's on my calendar this afternoon?"),
            (.jarvis, "Two things, sir: the dentist at three, and a call with Sam at half four.")
        ])

        Screens.seed()

        for (name, view) in Screens.all {
            let image = draw(view)
            try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent("\(name).png"))
        }
    }

    /// One screen, the size of an iPhone 15, in a window of its own.
    private func draw(_ view: AnyView, size: CGSize = CGSize(width: 393, height: 852)) -> UIImage {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(origin: .zero, size: size))
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = .dark

        let host = UIHostingController(rootView: view.environmentObject(AppModel.shared).preferredColorScheme(.dark))
        window.rootViewController = host
        window.isHidden = false
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()

        // Long enough for SwiftUI to lay out, for .task blocks to start and for the first animation
        // frame to land; short enough that the run is not waiting on a network that is not there.
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        host.view.layoutIfNeeded()

        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }

        window.isHidden = true
        return image
    }
}

/// The screens worth looking at, each wrapped the way the app shows it.
@MainActor
enum Screens {
    /// Whatever the screens need that the app model does not hold: the smart-home devices, as the PC
    /// would send them - the bedroom light on and confirmed, an office light not set up yet.
    static func seed() {
        SmartHomeModel.shared.apply(list: [
            [
                "id": "bedroom_main_light", "name": "Bedroom Light", "room": "Bedroom", "kind": "light",
                "status": "on", "statusText": "On", "power": "on", "certainty": "confirmed",
                "updating": false, "bound": true, "simulated": false, "battery": 87,
                "capabilities": ["powerOn", "powerOff", "press", "battery"],
                "readAt": ISO8601DateFormatter().string(from: Date().addingTimeInterval(-40)),
                "lastCommand": "powerOn", "lastResult": "accepted"
            ],
            [
                "id": "office_desk_lamp", "name": "Desk Lamp", "room": "Office", "kind": "light",
                "status": "notSetUp", "statusText": "Not set up", "power": "unknown", "certainty": "unknown",
                "updating": false, "bound": false, "simulated": false, "capabilities": ["powerOn", "powerOff", "press"],
                "problem": "Desk Lamp isn't configured yet, sir."
            ]
        ], simulating: false)
    }

    static var all: [(String, AnyView)] {
        [
            ("01-jarvis", AnyView(HomeView())),
            ("02-home", AnyView(ControlView())),
            ("03-security", AnyView(SecurityView())),
            ("04-settings", AnyView(NavigationStack { SettingsView() })),
            ("05-tabs", AnyView(RootView())),
            ("06-device", AnyView(NavigationStack { SmartDeviceView(id: "bedroom_main_light") }))
        ]
    }
}
