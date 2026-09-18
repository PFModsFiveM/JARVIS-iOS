import Foundation
import SwiftUI
import UIKit

/// The PC's controls as the phone sees them: media, volume, stats, apps, power, the clipboard and files both ways. Requests go over the same encrypted connection as everything else (`AppModel.session()`).
@MainActor
final class ControlModel: ObservableObject {
    static let shared = ControlModel()

    struct Media: Equatable {
        var title: String?
        var artist: String?
        var source: String?
        var playing = false
        var volume: Double = 0
        var muted = false
        var art: UIImage?
    }

    struct Stats: Equatable {
        var cpu: Double?
        var memoryUsed: Double?
        var memoryTotal: Double?
        var gpu: Double?
        var gpuName: String?
        var gpuTemperature: Double?
        var vramUsed: Double?
        var vramTotal: Double?
        var uptimeHours: Double = 0
        var processes = 0
        var game: String?
        var drives: [(name: String, free: Double, total: Double)] = []

        static func == (a: Stats, b: Stats) -> Bool {
            a.cpu == b.cpu && a.memoryUsed == b.memoryUsed && a.gpu == b.gpu && a.gpuTemperature == b.gpuTemperature
                && a.game == b.game && a.drives.map(\.name) == b.drives.map(\.name) && a.drives.map(\.free) == b.drives.map(\.free)
        }
    }

    struct App: Identifiable, Equatable {
        let pid: Int
        let process: String
        let title: String
        let foreground: Bool
        var id: Int { pid }
    }

    struct FileEntry: Identifiable, Equatable, Hashable {
        let name: String
        let path: String
        let folder: Bool
        let size: Int64
        var id: String { path }
    }

    @Published private(set) var media = Media()
    @Published private(set) var stats = Stats()
    @Published private(set) var apps: [App] = []
    @Published private(set) var pcClipboard: String?
    @Published private(set) var transfer: (name: String, progress: Double)?
    @Published var downloaded: URL?

    /// Names opened from the phone before, most recent first - one tap to open again.
    @Published private(set) var recents: [String] = UserDefaults.standard.stringArray(forKey: "recentApps") ?? []

    private var fileGrant = false
    private var download: (id: String, name: String, count: Int, handle: FileHandle, url: URL, received: Int)?

    private var model: AppModel { AppModel.shared }

    /// A request, with the PC's refusal shown as a toast rather than thrown.
    @discardableResult
    private func call(_ kind: String, _ body: [String: Any] = [:], timeout: TimeInterval = 30) async -> BridgeMessage? {
        do {
            let reply = try await model.session().request(kind, body, timeout: timeout)
            if reply.kind == "failed" || reply.kind == "error" { model.toast = reply.message }
            return reply
        } catch {
            model.toast = error.localizedDescription
            return nil
        }
    }

    private func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }

    // MARK: media

    func refreshMedia() async {
        guard let reply = await call("media"), reply.kind == "media" else { return }
        let b = reply.body
        var next = Media(title: b["title"] as? String, artist: b["artist"] as? String, source: b["source"] as? String,
                         playing: b["playing"] as? Bool ?? false, volume: number(b["volume"]) ?? 0, muted: b["muted"] as? Bool ?? false)
        if let art = b["art"] as? String, let data = Data(base64Encoded: art) { next.art = UIImage(data: data) }
        media = next
    }

    func mediaAction(_ action: String) async {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        await call("media.action", ["action": action])
        try? await Task.sleep(nanoseconds: 400_000_000)
        await refreshMedia()
    }

    func setVolume(_ percent: Double) async {
        media.volume = percent
        await call("volume", ["percent": Int(percent.rounded())])
    }

    func toggleMute() async {
        media.muted.toggle()
        await call("volume", ["muted": media.muted])
    }

    // MARK: stats

    func refreshStats() async {
        guard let reply = await call("stats"), reply.kind == "stats" else { return }
        let b = reply.body
        stats = Stats(cpu: number(b["cpu"]), memoryUsed: number(b["memoryUsedGb"]), memoryTotal: number(b["memoryTotalGb"]),
                      gpu: number(b["gpu"]), gpuName: b["gpuName"] as? String, gpuTemperature: number(b["gpuTemperature"]),
                      vramUsed: number(b["vramUsedGb"]), vramTotal: number(b["vramTotalGb"]),
                      uptimeHours: number(b["uptimeHours"]) ?? 0, processes: Int(number(b["processes"]) ?? 0),
                      game: b["game"] as? String,
                      drives: (b["drives"] as? [[String: Any]] ?? []).map { ($0["name"] as? String ?? "?", number($0["freeGb"]) ?? 0, number($0["totalGb"]) ?? 0) })
    }

    // MARK: apps

    func refreshApps() async {
        guard let reply = await call("apps"), reply.kind == "apps" else { return }
        apps = (reply.body["apps"] as? [[String: Any]] ?? []).map {
            App(pid: Int(number($0["pid"]) ?? 0), process: $0["process"] as? String ?? "", title: $0["title"] as? String ?? "",
                foreground: $0["foreground"] as? Bool ?? false)
        }
    }

    func open(_ name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        recents = [trimmed] + recents.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }.prefix(7)
        UserDefaults.standard.set(recents, forKey: "recentApps")
        if let reply = await call("app.open", ["name": trimmed], timeout: 60), reply.kind == "done" { model.toast = reply.message }
        await refreshApps()
    }

    func close(_ app: App) async {
        if let reply = await call("app.close", ["pid": app.pid]), reply.kind == "done" { model.toast = reply.message }
        await refreshApps()
    }

    // MARK: power

    /// Sleep, restart and shut down ask for Face ID every time; cancelling never does.
    func power(_ action: String) async {
        do {
            let client = try await model.session()
            let reply = action == "cancel"
                ? try await client.request("power", ["action": action])
                : try await client.approvedRequest("power", reason: "\(action == "shutdown" ? "Shut down" : action.capitalized) your PC", ["action": action])
            model.toast = reply.message
            UINotificationFeedbackGenerator().notificationOccurred(reply.kind == "done" ? .success : .warning)
            if reply.kind == "done" {
                switch action {
                case "restart": LiveActivity.shared.powerStarted("Restarting", seconds: 15)
                case "shutdown": LiveActivity.shared.powerStarted("Shutting down", seconds: 15)
                case "cancel": LiveActivity.shared.powerCancelled()
                default: break
                }
            }
        } catch {
            model.toast = error.localizedDescription
        }
    }

    // MARK: clipboard

    func fetchClipboard() async {
        guard let reply = await call("clipboard.get"), reply.kind == "clipboard" else { return }
        pcClipboard = reply.text("text") ?? ""
        if let text = pcClipboard, !text.isEmpty {
            UIPasteboard.general.string = text
            model.toast = "The PC's clipboard is on this iPhone's clipboard."
        } else {
            model.toast = "The PC's clipboard has no text."
        }
    }

    func sendClipboard() async {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            model.toast = "This iPhone's clipboard has no text."
            return
        }
        if let reply = await call("clipboard.set", ["text": text]), reply.kind == "done" { model.toast = reply.message }
    }

    // MARK: files

    func roots() async -> [FileEntry] { await list("files.roots", [:]) }

    func list(_ path: String) async -> [FileEntry] { await list("files.list", ["path": path]) }

    private func list(_ kind: String, _ body: [String: Any]) async -> [FileEntry] {
        guard let reply = await call(kind, body), reply.kind == "files" else { return [] }
        return (reply.body["entries"] as? [[String: Any]] ?? []).map {
            FileEntry(name: $0["name"] as? String ?? "", path: $0["path"] as? String ?? "", folder: $0["folder"] as? Bool ?? false,
                      size: Int64(number($0["size"]) ?? 0))
        }
    }

    /// Face ID the first time on a connection; the PC remembers it until the phone disconnects.
    private func granted(_ kind: String, _ body: [String: Any], reason: String) async throws -> BridgeMessage {
        let client = try await model.session()
        if fileGrant {
            let reply = try await client.request(kind, body)
            if reply.kind == "done" { return reply }
        }
        let reply = try await client.approvedRequest(kind, reason: reason, body)
        fileGrant = reply.kind == "done"
        return reply
    }

    /// Asks for a file; its parts arrive as "file.data" pushes and are written to a temporary file for sharing.
    func fetch(_ entry: FileEntry) async {
        do {
            let reply = try await granted("file.get", ["path": entry.path], reason: "Copy a file from your PC")
            guard reply.kind == "done", let count = number(reply.body["count"]) else {
                model.toast = reply.message
                return
            }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("from-pc", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(entry.name)
            try? FileManager.default.removeItem(at: url)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            download = (reply.id, entry.name, Int(count), handle, url, 0)
            transfer = (entry.name, 0)
        } catch {
            model.toast = error.localizedDescription
        }
    }

    func receiveFileData(_ message: BridgeMessage) {
        guard var current = download, message.text("for") == current.id,
              let index = number(message.body["index"]).map({ Int($0) }), index == current.received,
              let data = Data(base64Encoded: message.text("data") ?? "") else { return }
        current.handle.write(data)
        current.received += 1
        transfer = (current.name, Double(current.received) / Double(max(1, current.count)))
        if current.received >= current.count {
            try? current.handle.close()
            download = nil
            transfer = nil
            downloaded = current.url
        } else {
            download = current
        }
    }

    /// Sends a file to the PC's Downloads\From iPhone folder, one part at a time.
    func send(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            let begun = try await granted("file.put", ["name": url.lastPathComponent, "size": size], reason: "Send a file to your PC")
            guard begun.kind == "done", let upload = begun.text("upload") else {
                model.toast = begun.message
                return
            }

            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let chunk = 128 * 1024
            var index = 0
            var sent: Int64 = 0
            transfer = (url.lastPathComponent, 0)
            let client = try await model.session()

            repeat {
                let data = try handle.read(upToCount: chunk) ?? Data()
                let reply = try await client.request("file.part", ["upload": upload, "index": index, "data": data.base64EncodedString()], timeout: 60)
                guard reply.kind == "done" else {
                    model.toast = reply.message
                    transfer = nil
                    return
                }
                sent += Int64(data.count)
                index += 1
                transfer = (url.lastPathComponent, size == 0 ? 1 : Double(sent) / Double(size))
                if sent >= size { model.toast = reply.message }
            } while sent < size

            transfer = nil
        } catch {
            transfer = nil
            model.toast = error.localizedDescription
        }
    }

    /// Photos arrive from the picker as data; they go through a temporary file like any other.
    func send(data: Data, name: String) async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try data.write(to: url)
            await send(url)
            try? FileManager.default.removeItem(at: url)
        } catch {
            model.toast = error.localizedDescription
        }
    }

    /// A new connection starts with nothing granted.
    func connectionChanged() {
        fileGrant = false
        if let current = download {
            try? current.handle.close()
            download = nil
            transfer = nil
        }
    }
}
