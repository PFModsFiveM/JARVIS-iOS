import SwiftUI

/// What JARVIS is doing, as the circle and the face show it. The PC's `JarvisVisualState`, reduced to the states the
/// phone can know about.
enum JarvisVisualState: Equatable {
    case offline, idle, listening, thinking, speaking, securityAlert

    /// An RGB colour as 0-255 components, which the face's rasteriser and the circle's canvas both use.
    struct RGB: Equatable {
        var r: Float, g: Float, b: Float
        init(_ r: Float, _ g: Float, _ b: Float) { self.r = r; self.g = g; self.b = b }
        var color: Color { Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255) }
        func mix(_ to: RGB, _ t: Float) -> RGB {
            let k = min(max(t, 0), 1)
            return RGB(r + (to.r - r) * k, g + (to.g - g) * k, b + (to.b - b) * k)
        }
    }

    /// Colour and tempo per state - the PC's `JarvisCore.Appearance`. Cyan does nearly all of it; states differ in
    /// brightness and speed, and a different colour appears only when something is actually wrong.
    var appearance: (accent: RGB, speed: Double, brightness: Double) {
        switch self {
        case .offline: return (RGB(0x1A, 0x5C, 0x6E), 0.35, 0.55)
        case .idle: return (RGB(0x2A, 0x93, 0xA6), 1.0, 0.80)
        case .listening: return (RGB(0x7F, 0xED, 0xF3), 2.0, 1.00)
        case .thinking: return (RGB(0x43, 0xCE, 0xDA), 3.0, 0.92)
        case .speaking: return (RGB(0x43, 0xCE, 0xDA), 1.6, 0.98)
        case .securityAlert: return (RGB(0xDD, 0x53, 0x40), 3.6, 1.00)
        }
    }

    /// The single off-colour arc: amber normally, joining the red in an alert.
    var highlight: RGB { self == .securityAlert ? RGB(0xFF, 0x9A, 0x8A) : RGB(0xD9, 0xA2, 0x57) }

    /// The face's mood for this state - the PC's `FacePolicy.MoodOf`.
    func mood(facialState: Bool) -> FaceMood {
        if self == .securityAlert { return .security }
        if self == .speaking { return .speaking }
        if !facialState { return .neutral }
        switch self {
        case .offline: return .asleep
        case .listening: return .listening
        case .thinking: return .thinking
        default: return .neutral
        }
    }
}

/// Which centrepiece the home screen shows. The PC's `Hud:Centrepiece`.
enum Centrepiece: String, CaseIterable, Identifiable {
    case circle, face, none
    var id: String { rawValue }
    var label: String {
        switch self {
        case .circle: return "Circle"
        case .face: return "Face"
        case .none: return "Off"
        }
    }
}
