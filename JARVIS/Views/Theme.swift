import SwiftUI
import UIKit

/// The PC HUD's look, on a phone: near-black, one cyan at four intensities, thin frames with corner
/// ticks, spaced capitals.
///
/// **One hue.** The interface used to speak in four - cyan, green for good, amber for attention, red
/// for danger - and a screen with all four on it reads as a dashboard of warnings rather than as the
/// holographic display JARVIS is. Now state is carried by *intensity* within a single ice-cyan: dim
/// for idle, the accent for active, near-white `bright` for on and done. Two exceptions remain, each
/// kept for exactly one job - `amber` for something that needs attention, and `alert` red for the
/// Security Protocol and actions that cannot be taken back. Green is retired; `good` is an alias of
/// `bright`, so success is the display lighting up, not a new colour arriving.
enum HUD {
    // Ground: a very dark navy rather than black, so the screen reads as lit glass and not a dead one.
    static let background = Color(red: 0.012, green: 0.027, blue: 0.047)
    static let panel = Color(red: 0.027, green: 0.058, blue: 0.090)
    /// Hairlines: frames, dividers, the edge of an idle control. Etched rather than drawn.
    static let line = Color(red: 0.086, green: 0.220, blue: 0.290)

    // The one hue, dim to hot.
    static let accentDeep = Color(red: 0.16, green: 0.50, blue: 0.64)
    static let accent = Color(red: 0.33, green: 0.84, blue: 1.0)
    /// Almost white with a breath of cyan: on, lit, done. Used sparingly, which is what makes it read as light.
    static let bright = Color(red: 0.80, green: 0.96, blue: 1.0)
    static let dim = Color(red: 0.42, green: 0.57, blue: 0.65)
    static let text = Color(red: 0.87, green: 0.95, blue: 0.98)

    // The two exceptions.
    static let amber = Color(red: 1.0, green: 0.67, blue: 0.28)
    static let alert = Color(red: 1.0, green: 0.28, blue: 0.24)

    /// Retired as a colour of its own. See the note above.
    static let good = bright

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
///
/// The title runs into a hairline rule, the way an instrument labels a region; the frame is etched
/// in the hairline colour and only the corners carry the tint, lit a little, so a stack of panels
/// reads as glass with light caught at its edges rather than as a column of boxes.
struct HUDFrame<Content: View>: View {
    var title: String?
    var tint: Color = HUD.accent
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                HStack(spacing: 10) {
                    HUDLabel(text: title, color: tint)
                        .fixedSize()
                    Rectangle()
                        .fill(LinearGradient(colors: [tint.opacity(0.45), tint.opacity(0)], startPoint: .leading, endPoint: .trailing))
                        .frame(height: 1)
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [HUD.panel.opacity(0.92), HUD.panel.opacity(0.70)], startPoint: .top, endPoint: .bottom)
        )
        .overlay(alignment: .top) {
            // A breath of light along the top edge, as if the panel were lit from above.
            Rectangle().fill(tint.opacity(0.10)).frame(height: 1)
        }
        .overlay(Rectangle().stroke(HUD.line, lineWidth: 1))
        .overlay(Corners().stroke(tint, lineWidth: 1.5).shadow(color: tint.opacity(0.6), radius: 3))
    }
}

struct Corners: Shape {
    var length: CGFloat = 12

    func path(in rect: CGRect) -> Path {
        let l = length
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

    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .bold, design: .monospaced))
            .kerning(2.2)
            .textCase(.uppercase)
            .foregroundStyle(filled ? HUD.background : tint)
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .background(filled ? tint.opacity(configuration.isPressed ? 0.75 : 1) : tint.opacity(configuration.isPressed ? 0.22 : 0.06))
            .overlay(Rectangle().stroke(tint.opacity(filled ? 1 : 0.55), lineWidth: 1))
            .overlay(Corners(length: 6).stroke(tint, lineWidth: 1.5))
            .shadow(color: tint.opacity(configuration.isPressed || filled ? 0.45 : 0), radius: 8)
            .opacity(enabled ? 1 : 0.4)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// The ground every screen stands on: the navy, a faint instrument grid, and light pooled near the top.
///
/// Drawn once per screen with Canvas, and still - the grid is texture, not motion, and costs nothing
/// after the first frame.
struct HUDBackdrop: View {
    var body: some View {
        ZStack {
            HUD.background

            RadialGradient(colors: [HUD.accent.opacity(0.10), HUD.accent.opacity(0)], center: .init(x: 0.5, y: 0.0), startRadius: 0, endRadius: 420)

            Canvas { context, size in
                let step: CGFloat = 28
                var grid = Path()
                var x: CGFloat = 0
                while x <= size.width { grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height)); x += step }
                var y: CGFloat = 0
                while y <= size.height { grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y)); y += step }
                context.stroke(grid, with: .color(HUD.accent.opacity(0.035)), lineWidth: 0.5)
            }

            // Darker at the bottom, where the input bar and the tab bar sit.
            LinearGradient(colors: [.clear, HUD.background.opacity(0.85)], startPoint: .center, endPoint: .bottom)
        }
    }
}

extension View {
    /// A navigation title in the HUD's type: small spaced capitals in the accent, centred, instead of the
    /// system's bold white. The plain title is still set, for the back button and accessibility.
    func hudTitle(_ title: String) -> some View {
        navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(title.uppercased())
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .kerning(3)
                        .foregroundStyle(HUD.accent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .shadow(color: HUD.accent.opacity(0.5), radius: 4)
                        .accessibilityAddTraits(.isHeader)
                }
            }
    }

    /// A full screen in the HUD's clothes: the backdrop behind it and a dark navigation bar over it.
    func hudScreen() -> some View {
        background(HUDBackdrop().ignoresSafeArea())
            .toolbarBackground(HUD.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
    }
}

/// The tab bar and navigation bars in the HUD's type and colours, set once for the whole app.
///
/// UIKit appearance rather than SwiftUI modifiers because the tab bar is UIKit's own, and its
/// default - translucent grey, blue tint, the system font - was the most un-JARVIS thing on the screen.
enum HUDChrome {
    static func apply() {
        let label = UIFont.monospacedSystemFont(ofSize: 9.5, weight: .semibold)

        let item = UITabBarItemAppearance()
        item.normal.iconColor = UIColor(HUD.dim)
        item.normal.titleTextAttributes = [.foregroundColor: UIColor(HUD.dim), .font: label, .kern: 1.2]
        item.selected.iconColor = UIColor(HUD.accent)
        item.selected.titleTextAttributes = [.foregroundColor: UIColor(HUD.accent), .font: label, .kern: 1.2]

        let tabs = UITabBarAppearance()
        tabs.configureWithOpaqueBackground()
        tabs.backgroundColor = UIColor(HUD.background)
        tabs.shadowColor = UIColor(HUD.line)
        tabs.stackedLayoutAppearance = item
        tabs.inlineLayoutAppearance = item
        tabs.compactInlineLayoutAppearance = item
        UITabBar.appearance().standardAppearance = tabs
        UITabBar.appearance().scrollEdgeAppearance = tabs
        // The item appearance above is not read by every tab bar style (the floating glass bar of
        // recent iOS ignores it); these two are, so unselected items are dim cyan there too.
        UITabBar.appearance().unselectedItemTintColor = UIColor(HUD.dim)
        UITabBar.appearance().tintColor = UIColor(HUD.accent)
        UISwitch.appearance().onTintColor = UIColor(HUD.accent)

        let bar = UINavigationBarAppearance()
        bar.configureWithOpaqueBackground()
        bar.backgroundColor = UIColor(HUD.background)
        bar.shadowColor = UIColor(HUD.line)
        bar.titleTextAttributes = [.foregroundColor: UIColor(HUD.text), .font: UIFont.monospacedSystemFont(ofSize: 14, weight: .semibold), .kern: 2.5]
        bar.largeTitleTextAttributes = [.foregroundColor: UIColor(HUD.text), .font: UIFont.monospacedSystemFont(ofSize: 26, weight: .bold)]
        UINavigationBar.appearance().standardAppearance = bar
        UINavigationBar.appearance().scrollEdgeAppearance = bar
        UINavigationBar.appearance().compactAppearance = bar
        UINavigationBar.appearance().tintColor = UIColor(HUD.accent)
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
