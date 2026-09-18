import SwiftUI

/// Games, what's in progress, and OBS - the Control tab's second half. Each panel loads when it appears and refreshes
/// with the rest of the tab.
@MainActor
final class LibraryModel: ObservableObject {
    static let shared = LibraryModel()

    struct Game: Identifiable, Hashable {
        let platform: String
        let id: String
        let name: String
        let art: URL?
        let sizeGb: Double?
    }

    struct Progress: Identifiable, Hashable {
        let id: String
        let label: String
        let source: String
        let state: String
        let percent: Double?
        let secondsLeft: Double?
    }

    struct Obs: Equatable {
        var available = false
        var problem: String?
        var recording = false
        var paused = false
        var streaming = false
        var recordTime: String?
        var scene: String?
        var scenes: [String] = []
    }

    @Published private(set) var games: [Game] = []
    @Published private(set) var progress: [Progress] = []
    @Published private(set) var obs = Obs()

    private var model: AppModel { AppModel.shared }

    private func request(_ kind: String, _ body: [String: Any] = [:]) async -> BridgeMessage? {
        do {
            return try await model.session().request(kind, body, timeout: 30)
        } catch {
            return nil
        }
    }

    private func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }

    func refreshGames() async {
        guard let reply = await request("games"), reply.kind == "games" else { return }
        games = (reply.body["games"] as? [[String: Any]] ?? []).map {
            Game(platform: $0["platform"] as? String ?? "", id: $0["id"] as? String ?? "", name: $0["name"] as? String ?? "",
                 art: ($0["art"] as? String).flatMap(URL.init(string:)), sizeGb: number($0["sizeGb"]))
        }
    }

    func launch(_ game: Game) async {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if let reply = await request("game.launch", ["platform": game.platform, "id": game.id]) { model.toast = reply.message }
    }

    func refreshProgress() async {
        guard let reply = await request("progress"), reply.kind == "progress" else { return }
        progress = (reply.body["items"] as? [[String: Any]] ?? []).map {
            Progress(id: $0["id"] as? String ?? UUID().uuidString, label: $0["label"] as? String ?? "", source: $0["source"] as? String ?? "",
                     state: $0["state"] as? String ?? "", percent: number($0["percent"]), secondsLeft: number($0["secondsLeft"]))
        }
    }

    func refreshObs() async {
        guard let reply = await request("obs"), reply.kind == "obs" else { return }
        let b = reply.body
        obs = Obs(available: b["available"] as? Bool ?? false, problem: b["problem"] as? String, recording: b["recording"] as? Bool ?? false,
                  paused: b["recordingPaused"] as? Bool ?? false, streaming: b["streaming"] as? Bool ?? false,
                  recordTime: b["recordTime"] as? String, scene: b["currentScene"] as? String, scenes: b["scenes"] as? [String] ?? [])
    }

    func obsAction(_ action: String, scene: String? = nil) async {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        var body: [String: Any] = ["action": action]
        if let scene { body["scene"] = scene }
        if let reply = await request("obs.action", body) { model.toast = reply.message }
        try? await Task.sleep(nanoseconds: 500_000_000)
        await refreshObs()
    }
}

struct GamesPanel: View {
    @StateObject private var library = LibraryModel.shared
    @State private var showAll = false

    var body: some View {
        HUDFrame(title: "Games") {
            if library.games.isEmpty {
                Text("No installed games found.").foregroundStyle(HUD.dim)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(library.games.prefix(showAll ? 200 : 12)) { game in
                        Button { Task { await library.launch(game) } } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                ZStack {
                                    HUD.background
                                    if let art = game.art {
                                        AsyncImage(url: art) { image in image.resizable().scaledToFill() } placeholder: { Image(systemName: "gamecontroller").foregroundStyle(HUD.dim) }
                                    } else {
                                        Image(systemName: "gamecontroller").font(.title2).foregroundStyle(HUD.dim)
                                    }
                                }
                                .frame(width: 150, height: 70)
                                .clipped()
                                Text(game.name).font(.caption).foregroundStyle(HUD.text).lineLimit(1).frame(width: 150, alignment: .leading)
                                Text(game.platform).font(.caption2).foregroundStyle(HUD.dim)
                            }
                        }
                    }
                }
            }
            if library.games.count > 12 {
                Button(showAll ? "Fewer" : "All \(library.games.count)") { showAll.toggle() }.font(.footnote).foregroundStyle(HUD.accent)
            }
            Text("Tap to launch on the PC. Steam, Epic, EA, Ubisoft, Battle.net, Rockstar and Xbox.").font(.footnote).foregroundStyle(HUD.dim)
        }
        .task { await library.refreshGames() }
    }
}

struct ProgressPanel: View {
    @StateObject private var library = LibraryModel.shared

    var body: some View {
        if !library.progress.isEmpty {
            HUDFrame(title: "In progress") {
                ForEach(library.progress) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(item.label).foregroundStyle(HUD.text).lineLimit(1)
                            Spacer()
                            Text(caption(item)).font(.system(.caption, design: .monospaced)).foregroundStyle(item.state == "Failed" ? HUD.alert : HUD.dim)
                        }
                        if let percent = item.percent {
                            ProgressView(value: min(max(percent / 100, 0), 1)).tint(item.state == "Completed" ? HUD.good : HUD.accent)
                        }
                        HUDLabel(text: item.source)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func caption(_ item: LibraryModel.Progress) -> String {
        switch item.state {
        case "Completed": return "Done"
        case "Failed": return "Failed"
        case "Paused": return "Paused"
        default:
            var parts: [String] = []
            if let percent = item.percent { parts.append("\(Int(percent))%") }
            if let left = item.secondsLeft {
                parts.append(left >= 3600 ? String(format: "%.0f h left", left / 3600) : left >= 60 ? String(format: "%.0f min left", left / 60) : "\(Int(left)) s left")
            }
            return parts.isEmpty ? item.state : parts.joined(separator: " · ")
        }
    }
}

struct ObsPanel: View {
    @StateObject private var library = LibraryModel.shared

    var body: some View {
        HUDFrame(title: "OBS", tint: library.obs.recording || library.obs.streaming ? HUD.alert : HUD.accent) {
            if library.obs.available {
                HStack {
                    if library.obs.recording {
                        Label(library.obs.paused ? "Paused" : "Recording \(library.obs.recordTime.map { String($0.prefix(8)) } ?? "")", systemImage: "record.circle")
                            .foregroundStyle(HUD.alert)
                    }
                    if library.obs.streaming { Label("Live", systemImage: "dot.radiowaves.left.and.right").foregroundStyle(HUD.alert) }
                    if !library.obs.recording && !library.obs.streaming { Text("Idle").foregroundStyle(HUD.dim) }
                    Spacer()
                }
                .font(.system(.body, design: .monospaced))
                HStack(spacing: 8) {
                    Button(library.obs.recording ? "Stop rec" : "Record") { Task { await library.obsAction("record") } }
                        .buttonStyle(HUDButtonStyle(tint: HUD.alert, filled: library.obs.recording))
                    if library.obs.recording {
                        Button(library.obs.paused ? "Resume" : "Pause") { Task { await library.obsAction("pause") } }.buttonStyle(HUDButtonStyle())
                    }
                    Button(library.obs.streaming ? "End stream" : "Go live") { Task { await library.obsAction("stream") } }
                        .buttonStyle(HUDButtonStyle(tint: HUD.amber, filled: library.obs.streaming))
                }
                if !library.obs.scenes.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(library.obs.scenes, id: \.self) { scene in
                                Button(scene) { Task { await library.obsAction("scene", scene: scene) } }
                                    .font(.footnote)
                                    .foregroundStyle(scene == library.obs.scene ? HUD.background : HUD.accent)
                                    .padding(.horizontal, 10).padding(.vertical, 7)
                                    .background(scene == library.obs.scene ? HUD.accent : Color.clear)
                                    .overlay(Rectangle().stroke(HUD.accent.opacity(0.4), lineWidth: 1))
                            }
                        }
                    }
                }
            } else {
                Text(library.obs.problem ?? "OBS isn't running.").font(.footnote).foregroundStyle(HUD.dim)
            }
        }
    }
}
