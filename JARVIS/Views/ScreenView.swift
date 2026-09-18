import SwiftUI

/// Live view of the PC: pick a display, prove it's you with Face ID, and watch it. Pinch to zoom, drag to look
/// around, double-tap to reset. Watching only - nothing here reaches the PC's keyboard or mouse.
struct ScreenView: View {
    @EnvironmentObject var model: AppModel
    @State private var selected = 0
    @State private var zoom: CGFloat = 1
    @State private var settledZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var settledOffset: CGSize = .zero
    @State private var sideways = false

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                HUDLabel(text: "Live view", color: HUD.accent)
                Spacer()
                if model.liveDisplay != nil {
                    HUDLabel(text: String(format: "%.0f fps", model.screenFramesPerSecond), color: HUD.good)
                }
            }

            if model.screenDisplays.count > 1 {
                Picker("Display", selection: $selected) {
                    ForEach(model.screenDisplays) { display in
                        Text(display.primary ? "\(display.index + 1) ★" : "\(display.index + 1)").tag(display.index)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: selected) { _, display in
                    if model.liveDisplay != nil { Task { await model.startLive(display) } }
                }
            }

            screen
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .overlay(Rectangle().stroke(HUD.accent.opacity(0.3), lineWidth: 1))
                .clipped()

            HStack(spacing: 10) {
                if model.liveDisplay == nil {
                    Button("Watch") { Task { await model.startLive(selected) } }
                        .buttonStyle(HUDButtonStyle(filled: true))
                        .disabled(!model.link.isOnline)
                } else {
                    Button("Stop") { Task { await model.stopLive() } }
                        .buttonStyle(HUDButtonStyle(tint: HUD.alert))
                }
                Button(sideways ? "Upright" : "Sideways") { withAnimation { sideways.toggle(); reset() } }
                    .buttonStyle(HUDButtonStyle())
            }

            Text("Face ID each time you start. The PC keeps a note in its log whenever it is watched. Games in exclusive full screen show as black.")
                .font(.footnote).foregroundStyle(HUD.dim)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(HUD.background.ignoresSafeArea())
        .task {
            await model.loadDisplays()
            if let primary = model.screenDisplays.first(where: { $0.primary }) { selected = primary.index }
        }
        .onDisappear {
            if model.liveDisplay != nil { Task { await model.stopLive() } }
        }
    }

    @ViewBuilder
    private var screen: some View {
        if let image = model.screenFrame {
            GeometryReader { geometry in
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: sideways ? geometry.size.height : geometry.size.width,
                           height: sideways ? geometry.size.width : geometry.size.height)
                    .rotationEffect(.degrees(sideways ? 90 : 0))
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .scaleEffect(zoom)
                    .offset(offset)
                    .opacity(model.liveDisplay == nil ? 0.4 : 1)
            }
            .contentShape(Rectangle())
            .gesture(
                MagnifyGesture()
                    .onChanged { value in zoom = min(6, max(1, settledZoom * value.magnification)) }
                    .onEnded { _ in settledZoom = zoom; if zoom == 1 { offset = .zero; settledOffset = .zero } }
                    .simultaneously(with: DragGesture()
                        .onChanged { value in
                            guard zoom > 1 else { return }
                            offset = CGSize(width: settledOffset.width + value.translation.width, height: settledOffset.height + value.translation.height)
                        }
                        .onEnded { _ in settledOffset = offset })
            )
            .onTapGesture(count: 2) { withAnimation { reset() } }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "display").font(.system(size: 42)).foregroundStyle(HUD.dim)
                Text(model.liveDisplay == nil ? "Press Watch to see this display." : "Waiting for the first frame…")
                    .foregroundStyle(HUD.dim)
            }
        }
    }

    private func reset() {
        zoom = 1; settledZoom = 1
        offset = .zero; settledOffset = .zero
    }
}
