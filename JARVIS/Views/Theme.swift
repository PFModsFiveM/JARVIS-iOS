import SwiftUI

/// The PC HUD's look, on a phone: near-black, one cyan accent, thin frames with corner ticks, spaced capitals.
enum HUD {
    static let background = Color(red: 0.02, green: 0.04, blue: 0.06)
    static let panel = Color(red: 0.04, green: 0.08, blue: 0.11)
    static let accent = Color(red: 0.24, green: 0.82, blue: 1.0)
    static let dim = Color(red: 0.45, green: 0.62, blue: 0.70)
    static let text = Color(red: 0.86, green: 0.94, blue: 0.98)
    static let alert = Color(red: 1.0, green: 0.23, blue: 0.23)
    static let amber = Color(red: 1.0, green: 0.72, blue: 0.20)
    static let good = Color(red: 0.30, green: 0.90, blue: 0.55)

    static func spaced(_ text: String) -> String {
        text.uppercased().map(String.init).joined(separator: " ")
    }
}

struct HUDLabel: View {
    let text: String
    var color: Color = HUD.dim

    var body: some View {
        Text(HUD.spaced(text))
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(color)
    }
}

/// A panel with corner ticks, like the PC's HudFrame.
struct HUDFrame<Content: View>: View {
    var title: String?
    var tint: Color = HUD.accent
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title { HUDLabel(text: title, color: tint) }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HUD.panel.opacity(0.85))
        .overlay(Corners().stroke(tint, lineWidth: 1.5))
        .overlay(Rectangle().stroke(tint.opacity(0.18), lineWidth: 1))
    }
}

private struct Corners: Shape {
    func path(in rect: CGRect) -> Path {
        let l: CGFloat = 12
        var p = Path()
        for (corner, dx, dy) in [(CGPoint(x: rect.minX, y: rect.minY), 1.0, 1.0), (CGPoint(x: rect.maxX, y: rect.minY), -1.0, 1.0),
                                 (CGPoint(x: rect.minX, y: rect.maxY), 1.0, -1.0), (CGPoint(x: rect.maxX, y: rect.maxY), -1.0, -1.0)] {
            p.move(to: CGPoint(x: corner.x + l * dx, y: corner.y))
            p.addLine(to: corner)
            p.addLine(to: CGPoint(x: corner.x, y: corner.y + l * dy))
        }
        return p
    }
}

struct HUDButtonStyle: ButtonStyle {
    var tint: Color = HUD.accent
    var filled = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .bold, design: .monospaced))
            .kerning(2)
            .textCase(.uppercase)
            .foregroundStyle(filled ? HUD.background : tint)
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .background(filled ? tint.opacity(configuration.isPressed ? 0.7 : 1) : tint.opacity(configuration.isPressed ? 0.25 : 0.08))
            .overlay(Rectangle().stroke(tint.opacity(0.8), lineWidth: 1))
    }
}

/// The pulsing ring on the home screen: steady when online, breathing while listening, amber offline.
struct Reactor: View {
    var color: Color
    var active: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.25), lineWidth: 10)
            Circle().trim(from: 0, to: 0.72).stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(pulse ? 360 : 0))
            Circle().fill(color.opacity(active ? 0.35 : 0.12)).padding(26).scaleEffect(pulse && active ? 1.08 : 0.94)
            Circle().stroke(color.opacity(0.6), lineWidth: 1).padding(14)
        }
        .onAppear {
            withAnimation(.linear(duration: 6).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}
