import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The house from the phone: the things that can be switched on and off at the top, then what's
/// playing and the volume, how the PC is running, what's open, the clipboard and files. Refreshes
/// itself every few seconds while on screen.
///
/// Power moved to each device's own page on 25 September, with the button that was missing beside
/// it: turning the PC on. Two places to shut a PC down was one too many.
struct ControlView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var control = ControlModel.shared
    @State private var openName = ""
    @State private var photo: PhotosPickerItem?
    @State private var importing = false
    @State private var volumeDraft: Double?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    DevicesPanel()
                    mediaPanel
                    MacrosPanel()
                    ProgressPanel()
                    GamesPanel()
                    ObsPanel()
                    statsPanel
                    appsPanel
                    transferPanel
                }
                .padding(16)
            }
            .background(HUD.background.ignoresSafeArea())
            .navigationTitle("Home")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(HUD.panel, for: .navigationBar)
            .refreshable { await refreshAll() }
            .task {
                // Every three seconds while this tab is on screen, and not at all once it is not.
                while !Task.isCancelled {
                    if model.link.isOnline { await refreshAll() }
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
            .onChange(of: photo) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        let type = item.supportedContentTypes.first
                        let ext = type?.preferredFilenameExtension ?? "jpg"
                        await control.send(data: data, name: "iPhone \(Self.stamp()).\(ext)")
                    }
                    photo = nil
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
                if case .success(let url) = result { Task { await control.send(url) } }
            }
            .sheet(item: Binding(get: { control.downloaded.map(SharedFile.init) }, set: { if $0 == nil { control.downloaded = nil } })) { file in
                ShareSheet(url: file.url)
            }
        }
    }

    private func refreshAll() async {
        async let media: Void = control.refreshMedia()
        async let stats: Void = control.refreshStats()
        async let apps: Void = control.refreshApps()
        async let progress: Void = LibraryModel.shared.refreshProgress()
        async let obs: Void = LibraryModel.shared.refreshObs()
        _ = await (media, stats, apps, progress, obs)
    }

    private static func stamp() -> String {
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return format.string(from: Date())
    }

    // MARK: media

    private var mediaPanel: some View {
        HUDFrame(title: "Now playing") {
            HStack(spacing: 14) {
                Group {
                    if let art = control.media.art {
                        Image(uiImage: art).resizable().scaledToFill()
                    } else {
                        Image(systemName: "music.note").font(.system(size: 28)).foregroundStyle(HUD.dim)
                    }
                }
                .frame(width: 72, height: 72)
                .background(HUD.background)
                .clipped()
                .overlay(Rectangle().stroke(HUD.accent.opacity(0.3), lineWidth: 1))

                VStack(alignment: .leading, spacing: 3) {
                    Text(control.media.title ?? "Nothing playing").font(.headline).foregroundStyle(HUD.text).lineLimit(2)
                    if let artist = control.media.artist { Text(artist).foregroundStyle(HUD.dim).lineLimit(1) }
                    if let source = control.media.source { HUDLabel(text: source) }
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 28) {
                Spacer()
                mediaButton("backward.fill") { await control.mediaAction("previous") }
                mediaButton(control.media.playing ? "pause.fill" : "play.fill", size: 30) { await control.mediaAction("playPause") }
                mediaButton("forward.fill") { await control.mediaAction("next") }
                Spacer()
            }

            HStack(spacing: 10) {
                Button { Task { await control.toggleMute() } } label: {
                    Image(systemName: control.media.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundStyle(control.media.muted ? HUD.amber : HUD.accent)
                        .frame(width: 28)
                }
                // The PC is told once, when the finger lifts, not for every step of the drag.
                Slider(value: Binding(get: { volumeDraft ?? control.media.volume }, set: { volumeDraft = $0 }), in: 0...100, step: 2) { editing in
                    if !editing, let value = volumeDraft {
                        Task {
                            await control.setVolume(value)
                            volumeDraft = nil
                        }
                    }
                }
                .tint(HUD.accent)
                Text("\(Int(volumeDraft ?? control.media.volume))").font(.system(.footnote, design: .monospaced)).foregroundStyle(HUD.dim).frame(width: 30)
            }
        }
    }

    private func mediaButton(_ symbol: String, size: CGFloat = 22, action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            Image(systemName: symbol).font(.system(size: size)).foregroundStyle(HUD.accent).frame(width: 48, height: 44)
        }
    }

    // MARK: stats

    private var statsPanel: some View {
        HUDFrame(title: "PC") {
            let s = control.stats
            meter("CPU", s.cpu, suffix: "%")
            meter("Memory", s.memoryUsed.flatMap { used in s.memoryTotal.map { used / max($0, 0.1) * 100 } },
                  detail: s.memoryUsed.map { String(format: "%.1f / %.0f GB", $0, s.memoryTotal ?? 0) })
            meter("GPU", s.gpu, suffix: "%", detail: s.gpuTemperature.map { t in String(format: "%.0f%% · %.0f °C", s.gpu ?? 0, t) })
            if let used = s.vramUsed, let total = s.vramTotal {
                meter("VRAM", used / max(total, 0.1) * 100, detail: String(format: "%.1f / %.0f GB", used, total))
            }
            ForEach(Array(s.drives.enumerated()), id: \.offset) { _, drive in
                meter(drive.name, drive.total > 0 ? (drive.total - drive.free) / drive.total * 100 : nil,
                      detail: String(format: "%.0f GB free", drive.free))
            }
            HStack {
                HUDLabel(text: String(format: "Up %.1f h", s.uptimeHours))
                Spacer()
                if let game = s.game { HUDLabel(text: "Playing \(game)", color: HUD.good) }
            }
        }
    }

    private func meter(_ label: String, _ percent: Double?, suffix: String = "", detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                HUDLabel(text: label)
                Spacer()
                Text(detail ?? percent.map { String(format: "%.0f%@", $0, suffix) } ?? "-")
                    .font(.system(.footnote, design: .monospaced)).foregroundStyle(HUD.text)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle().fill(HUD.accent.opacity(0.12))
                    Rectangle().fill((percent ?? 0) > 90 ? HUD.amber : HUD.accent)
                        .frame(width: geometry.size.width * CGFloat(min(max((percent ?? 0) / 100, 0), 1)))
                }
            }
            .frame(height: 4)
        }
    }

    // MARK: apps

    private var appsPanel: some View {
        HUDFrame(title: "Apps and games") {
            HStack(spacing: 8) {
                TextField("Open… (Spotify, Steam, Blender)", text: $openName)
                    .foregroundStyle(HUD.text)
                    .padding(9)
                    .background(HUD.background)
                    .overlay(Rectangle().stroke(HUD.accent.opacity(0.4), lineWidth: 1))
                    .submitLabel(.go)
                    .onSubmit(openTyped)
                Button("Open", action: openTyped).buttonStyle(HUDButtonStyle(filled: true)).frame(width: 90)
            }

            if !control.recents.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(control.recents, id: \.self) { name in
                            Button(name) { Task { await control.open(name) } }
                                .font(.footnote)
                                .foregroundStyle(HUD.accent)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .overlay(Rectangle().stroke(HUD.accent.opacity(0.4), lineWidth: 1))
                        }
                    }
                }
            }

            ForEach(control.apps) { app in
                HStack {
                    Circle().fill(app.foreground ? HUD.good : HUD.dim.opacity(0.4)).frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(app.title).foregroundStyle(HUD.text).lineLimit(1)
                        Text(app.process).font(.caption).foregroundStyle(HUD.dim)
                    }
                    Spacer()
                    Button { Task { await control.close(app) } } label: {
                        Image(systemName: "xmark.circle").foregroundStyle(HUD.alert.opacity(0.8)).font(.system(size: 20))
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func openTyped() {
        let name = openName
        openName = ""
        Task { await control.open(name) }
    }

    // MARK: clipboard and files

    private var transferPanel: some View {
        HUDFrame(title: "Clipboard and files") {
            HStack(spacing: 10) {
                Button("PC → iPhone") { Task { await control.fetchClipboard() } }.buttonStyle(HUDButtonStyle())
                Button("iPhone → PC") { Task { await control.sendClipboard() } }.buttonStyle(HUDButtonStyle())
            }
            HStack(spacing: 10) {
                PhotosPicker(selection: $photo, matching: .any(of: [.images, .videos])) {
                    Text("Send photo").frame(maxWidth: .infinity)
                }
                .buttonStyle(HUDButtonStyle())
                Button("Send file") { importing = true }.buttonStyle(HUDButtonStyle())
            }
            NavigationLink {
                FilesView(path: nil, title: "PC files")
            } label: {
                HStack {
                    Image(systemName: "folder")
                    Text("Browse the PC's files")
                    Spacer()
                    Image(systemName: "chevron.right")
                }
                .foregroundStyle(HUD.accent)
                .padding(.vertical, 6)
            }
            if let transfer = control.transfer {
                VStack(alignment: .leading, spacing: 4) {
                    HUDLabel(text: transfer.name)
                    ProgressView(value: transfer.progress).tint(HUD.accent)
                }
            }
            Text("Files you send land in Downloads › From iPhone on the PC. Face ID the first time each session.")
                .font(.footnote).foregroundStyle(HUD.dim)
        }
    }

    // MARK: power
    //
    // The buttons were here and are now on the PC's own page, reached by tapping it at the top of
    // this screen - together with the one that was missing, which is turning it on. Two places to
    // shut a PC down is one place too many, and the wake button belongs beside the others rather
    // than on a different screen from them.

}

/// A downloaded file, identified for the share sheet.
struct SharedFile: Identifiable {
    let url: URL
    var id: String { url.path }
}

/// The system share sheet: save to Files, AirDrop, open in another app.
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// One folder on the PC: folders first, then files newest first. Tap a file to copy it to the phone.
struct FilesView: View {
    let path: String?
    let title: String
    @StateObject private var control = ControlModel.shared
    @State private var entries: [ControlModel.FileEntry] = []
    @State private var loading = true

    var body: some View {
        List {
            if loading {
                ProgressView().tint(HUD.accent)
            } else if entries.isEmpty {
                Text("Empty.").foregroundStyle(HUD.dim)
            }
            ForEach(entries) { entry in
                if entry.folder {
                    NavigationLink {
                        FilesView(path: entry.path, title: entry.name)
                    } label: {
                        Label(entry.name, systemImage: "folder").foregroundStyle(HUD.text)
                    }
                } else {
                    Button {
                        Task { await control.fetch(entry) }
                    } label: {
                        HStack {
                            Label(entry.name, systemImage: "doc").foregroundStyle(HUD.text).lineLimit(1)
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                                .font(.caption).foregroundStyle(HUD.dim)
                        }
                    }
                }
            }
            .listRowBackground(HUD.panel)
        }
        .scrollContentBackground(.hidden)
        .background(HUD.background.ignoresSafeArea())
        .navigationTitle(title)
        .overlay(alignment: .bottom) {
            if let transfer = control.transfer {
                VStack(alignment: .leading, spacing: 4) {
                    HUDLabel(text: transfer.name)
                    ProgressView(value: transfer.progress).tint(HUD.accent)
                }
                .padding(12)
                .background(HUD.panel)
            }
        }
        .sheet(item: Binding(get: { control.downloaded.map(SharedFile.init) }, set: { if $0 == nil { control.downloaded = nil } })) { file in
            ShareSheet(url: file.url)
        }
        .task {
            entries = path == nil ? await control.roots() : await control.list(path!)
            loading = false
        }
    }
}
