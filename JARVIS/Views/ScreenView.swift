import SwiftUI

/// Live view and remote control of the PC. Pick a display and watch it (Face ID once per session); take control
/// (Face ID once more) and a tap on the picture clicks there, the strip on the right scrolls, and the keyboard bar types.
/// Pinch to zoom and drag to look around in either mode.
struct ScreenView: View {
    @EnvironmentObject var model: AppModel
    @State private var selected = 0
    @State private var zoom: CGFloat = 1
    @State private var settledZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var settledOffset: CGSize = .zero
    @State private var sideways = false
    @State private var rightClick = false
    @State private var typed = ""
    @State private var scrollCarry: CGFloat = 0
    @FocusState private var typing: Bool

    var body: some View {
        VStack(spacing: 10) {
            header

            if model.screenDisplays.count > 1 {
                Picker("Display", selection: $selected) {
                    ForEach(model.screenDisplays) { display in
                        Text(display.primary ? "\(display.index + 1) ★" : "\(display.index + 1)").tag(display.index)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: selected) { _, display in
                    reset()
                    if model.liveDisplay != nil { Task { await model.startLive(display) } }
                }
            }

            HStack(spacing: 6) {
                screen
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                    .overlay(Rectangle().stroke((model.controlling ? HUD.amber : HUD.accent).opacity(0.4), lineWidth: 1))
                    .clipped()
                if model.controlling { scrollStrip }
            }

            if model.controlling { keyboardBar }
            buttons
        }
        .padding(12)
        .background(HUD.background.ignoresSafeArea())
        .task {
            await model.loadDisplays()
            if let primary = model.screenDisplays.first(where: { $0.primary }) { selected = primary.index }
        }
        .onDisappear {
            if model.liveDisplay != nil { Task { await model.stopLive() } }
        }
    }

    // MARK: header and buttons

    private var header: some View {
        HStack {
            HUDLabel(text: model.controlling ? "Remote control" : "Live view", color: model.controlling ? HUD.amber : HUD.accent)
            Spacer()
            if model.liveDisplay != nil {
                HUDLabel(text: model.network.cellular ? "Mobile data" : "Wi-Fi")
                HUDLabel(text: String(format: "%.0f fps", model.screenFramesPerSecond), color: HUD.good)
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            if model.liveDisplay == nil {
                Button("Watch") { Task { await model.startLive(selected) } }
                    .buttonStyle(HUDButtonStyle(filled: true))
                    .disabled(!model.link.isOnline)
            } else {
                Button("Stop") { Task { await model.stopLive() } }
                    .buttonStyle(HUDButtonStyle(tint: HUD.alert))
                if model.controlling {
                    Button("Release") { model.releaseControl() }.buttonStyle(HUDButtonStyle(tint: HUD.amber))
                } else {
                    Button("Control") { Task { await model.takeControl() } }.buttonStyle(HUDButtonStyle(tint: HUD.amber))
                }
            }
            Button(sideways ? "Upright" : "Sideways") { withAnimation { sideways.toggle(); reset() } }
                .buttonStyle(HUDButtonStyle())
        }
    }

    // MARK: the picture

    @ViewBuilder
    private var screen: some View {
        if let image = model.screenFrame {
            GeometryReader { geometry in
                let container = geometry.size
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: sideways ? container.height : container.width,
                           height: sideways ? container.width : container.height)
                    .rotationEffect(.degrees(sideways ? 90 : 0))
                    .frame(width: container.width, height: container.height)
                    .scaleEffect(zoom)
                    .offset(offset)
                    .opacity(model.liveDisplay == nil ? 0.4 : 1)
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { tap in
                        click(at: tap.location, in: container, image: image.size, clicks: 1)
                    })
                    .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { tap in
                        if model.controlling {
                            click(at: tap.location, in: container, image: image.size, clicks: 2)
                        } else {
                            withAnimation { reset() }
                        }
                    })
            }
            .gesture(
                MagnifyGesture()
                    .onChanged { value in zoom = min(6, max(1, settledZoom * value.magnification)) }
                    .onEnded { _ in settledZoom = zoom; if zoom == 1 { offset = .zero; settledOffset = .zero } }
                    .simultaneously(with: DragGesture(minimumDistance: 12)
                        .onChanged { value in
                            guard zoom > 1 else { return }
                            offset = CGSize(width: settledOffset.width + value.translation.width, height: settledOffset.height + value.translation.height)
                        }
                        .onEnded { _ in settledOffset = offset })
            )
        } else {
            VStack(spacing: 10) {
                Image(systemName: "display").font(.system(size: 42)).foregroundStyle(HUD.dim)
                Text(model.liveDisplay == nil ? "Press Watch to see this display." : "Waiting for the first frame…")
                    .foregroundStyle(HUD.dim)
            }
        }
    }

    /// Where on the PC's display a point on the phone's picture is, 0-1 each way - undoing the offset, the zoom, the
    /// sideways turn and the letterboxing, in that order. Nil outside the picture.
    private func displayPoint(_ point: CGPoint, in container: CGSize, image: CGSize) -> CGPoint? {
        guard image.width > 0, image.height > 0 else { return nil }

        var x = point.x - container.width / 2 - offset.width
        var y = point.y - container.height / 2 - offset.height
        x /= zoom
        y /= zoom
        if sideways { (x, y) = (y, -x) }

        let frame = sideways ? CGSize(width: container.height, height: container.width) : container
        let fit = min(frame.width / image.width, frame.height / image.height)
        let shown = CGSize(width: image.width * fit, height: image.height * fit)
        let nx = x / shown.width + 0.5
        let ny = y / shown.height + 0.5
        guard (0...1).contains(nx), (0...1).contains(ny) else { return nil }
        return CGPoint(x: nx, y: ny)
    }

    private func click(at location: CGPoint, in container: CGSize, image: CGSize, clicks: Int) {
        guard model.controlling, let point = displayPoint(location, in: container, image: image) else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        model.input("input.click", ["x": point.x, "y": point.y, "button": rightClick ? "right" : "left", "clicks": clicks])
        if rightClick { rightClick = false }
    }

    // MARK: scrolling

    /// Drag up or down on the strip to turn the PC's mouse wheel: one notch per 24 points of travel.
    private var scrollStrip: some View {
        VStack(spacing: 6) {
            Image(systemName: "chevron.up").font(.caption)
            Spacer()
            Image(systemName: "arrow.up.and.down").font(.caption)
            Spacer()
            Image(systemName: "chevron.down").font(.caption)
        }
        .foregroundStyle(HUD.amber)
        .padding(.vertical, 10)
        .frame(width: 30)
        .frame(maxHeight: .infinity)
        .background(HUD.amber.opacity(0.08))
        .overlay(Rectangle().stroke(HUD.amber.opacity(0.4), lineWidth: 1))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 2)
            .onChanged { value in
                let step: CGFloat = 24
                let travelled = value.translation.height - scrollCarry
                let notches = Int(travelled / step)
                guard notches != 0 else { return }
                scrollCarry += CGFloat(notches) * step
                // Dragging up moves the page up, like a finger on a touchscreen: the wheel turns the other way.
                model.input("input.scroll", ["dy": -notches])
            }
            .onEnded { _ in scrollCarry = 0 })
    }

    // MARK: keyboard

    private var keyboardBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                TextField("Type on the PC", text: $typed)
                    .focused($typing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .foregroundStyle(HUD.text)
                    .padding(8)
                    .background(HUD.panel)
                    .overlay(Rectangle().stroke(HUD.amber.opacity(0.4), lineWidth: 1))
                    .submitLabel(.send)
                    .onSubmit(sendTyped)
                Button { sendTyped() } label: {
                    Image(systemName: "arrow.up").foregroundStyle(HUD.background).frame(width: 36, height: 36).background(HUD.amber)
                }
                Button { rightClick.toggle() } label: {
                    Image(systemName: "cursorarrow.click.2").foregroundStyle(rightClick ? HUD.background : HUD.amber)
                        .frame(width: 36, height: 36).background(rightClick ? HUD.amber : HUD.amber.opacity(0.1))
                }
                .accessibilityLabel("Next tap is a right-click")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Self.keys, id: \.chord) { key in
                        Button(key.label) { model.input("input.key", ["chord": key.chord]) }
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(HUD.amber)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .overlay(Rectangle().stroke(HUD.amber.opacity(0.4), lineWidth: 1))
                    }
                }
            }
        }
    }

    private static let keys: [(label: String, chord: String)] = [
        ("Esc", "Escape"), ("Tab", "Tab"), ("Enter", "Enter"), ("⌫", "Backspace"), ("Del", "Delete"),
        ("←", "Left"), ("↑", "Up"), ("↓", "Down"), ("→", "Right"),
        ("Win", "Win"), ("Alt+Tab", "Alt+Tab"), ("Copy", "Ctrl+C"), ("Paste", "Ctrl+V"), ("Undo", "Ctrl+Z"),
        ("Select all", "Ctrl+A"), ("Close", "Alt+F4"), ("Task Mgr", "Ctrl+Shift+Escape"), ("Desktop", "Win+D"),
        ("Space", "Space"), ("F5", "F5"), ("F11", "F11")
    ]

    private func sendTyped() {
        let text = typed
        typed = ""
        if !text.isEmpty { model.input("input.type", ["text": text]) }
    }

    private func reset() {
        zoom = 1; settledZoom = 1
        offset = .zero; settledOffset = .zero
    }
}
