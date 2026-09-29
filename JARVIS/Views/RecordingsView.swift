import AVKit
import SwiftUI

/// One incident, as the PC describes it.
struct SecurityRecording: Identifiable, Equatable {
    let id: String
    let at: Date
    let seconds: Int
    let what: String
    let snapshots: Int
    let clips: [Clip]

    struct Clip: Equatable {
        let kind: String
        let name: String
        let bytes: Int

        /// The composite - the screen being used with the camera inset - rather than the camera alone.
        var isEvidence: Bool { kind.caseInsensitiveCompare("Evidence") == .orderedSame }
    }

    var evidence: Clip? { clips.first(where: { $0.isEvidence }) }
    var camera: Clip? { clips.first(where: { !$0.isEvidence }) }

    /// How it reads in a list.
    var summary: String {
        var parts = [what]

        if seconds > 1 { parts.append("\(seconds)s") }
        if snapshots > 0 { parts.append("\(snapshots) photo\(snapshots == 1 ? "" : "s")") }
        if evidence != nil && camera != nil { parts.append("screen + camera") }

        return parts.joined(separator: " · ")
    }
}

/// What the camera kept, fetched from the PC a slice at a time.
///
/// An incident video runs to tens of megabytes, so it arrives in bounded pieces rather than in one
/// message - a single message carrying it base64-encoded would be a third larger again and held
/// whole in memory at both ends. The pieces are written straight to a file as they come, so the
/// phone never holds the whole recording either.
@MainActor
final class RecordingsModel: ObservableObject {
    @Published private(set) var recordings: [SecurityRecording] = []
    @Published private(set) var loading = false
    @Published private(set) var fetching: String?
    @Published private(set) var progress: Double = 0
    @Published private(set) var trouble: String?
    @Published var playing: URL?

    private let model = AppModel.shared

    func load() async {
        loading = true
        trouble = nil
        defer { loading = false }

        do {
            let reply = try await model.session().request("camera.recordings", [:], timeout: 20)
            recordings = (reply.body["recordings"] as? [[String: Any]] ?? []).compactMap(Self.read)
        } catch {
            trouble = error.localizedDescription
        }
    }

    private static func read(_ body: [String: Any]) -> SecurityRecording? {
        guard let id = body["id"] as? String else { return nil }

        let clips = (body["clips"] as? [[String: Any]] ?? []).compactMap { clip -> SecurityRecording.Clip? in
            guard let kind = clip["kind"] as? String, let name = clip["name"] as? String else { return nil }

            return SecurityRecording.Clip(kind: kind, name: name, bytes: (clip["bytes"] as? NSNumber)?.intValue ?? 0)
        }

        return SecurityRecording(
            id: id,
            at: (body["at"] as? String).flatMap(ISO8601DateFormatter().date(from:)) ?? .now,
            seconds: (body["seconds"] as? NSNumber)?.intValue ?? 0,
            what: body["what"] as? String ?? "Something happened",
            snapshots: (body["snapshots"] as? NSNumber)?.intValue ?? 0,
            clips: clips)
    }

    /// Fetches one recording to a file and offers it for playing.
    func fetch(_ recording: SecurityRecording, kind: String) async {
        guard fetching == nil else { return }

        fetching = recording.id
        progress = 0
        trouble = nil
        defer { fetching = nil }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(recording.id)-\(kind).mp4")

        // Already here from a previous look. Fetching tens of megabytes again to watch the same
        // incident twice would be rude to somebody on mobile data.
        if FileManager.default.fileExists(atPath: destination.path) {
            playing = destination
            return
        }

        FileManager.default.createFile(atPath: destination.path, contents: nil)

        guard let file = try? FileHandle(forWritingTo: destination) else {
            trouble = "There was nowhere to put it."
            return
        }

        defer { try? file.close() }

        var offset = 0

        do {
            while true {
                let reply = try await model.session().request("camera.recording.chunk", [
                    "id": recording.id,
                    "kind": kind,
                    "offset": offset,
                    "length": 192 * 1024
                ], timeout: 30)

                guard let encoded = reply.text("data"), let slice = Data(base64Encoded: encoded) else {
                    throw BridgeError.refused(reply.message)
                }

                try file.write(contentsOf: slice)

                offset += slice.count

                let total = (reply.body["total"] as? NSNumber)?.intValue ?? 0

                progress = total > 0 ? min(1, Double(offset) / Double(total)) : 0

                if reply.body["done"] as? Bool == true || slice.isEmpty { break }
            }

            playing = destination
        } catch {
            trouble = error.localizedDescription
            try? FileManager.default.removeItem(at: destination)
        }
    }
}

/// What the camera kept, to watch on the phone.
struct RecordingsView: View {
    @StateObject private var recordings = RecordingsModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HUDLabel(text: "What the camera kept", color: HUD.accent).padding(.top, 8)

                if let trouble = recordings.trouble {
                    HUDFrame(title: "Trouble", tint: HUD.alert) {
                        Text(trouble).font(.footnote).foregroundStyle(HUD.dim)
                    }
                }

                if recordings.loading {
                    HUDFrame { Text("Reading…").foregroundStyle(HUD.dim) }
                } else if recordings.recordings.isEmpty {
                    HUDFrame {
                        Text("Nothing has been recorded in the last week.")
                            .foregroundStyle(HUD.dim)
                    }
                }

                ForEach(recordings.recordings) { one in
                    HUDFrame(title: one.at.formatted(date: .abbreviated, time: .shortened), tint: HUD.alert) {
                        Text(one.summary).font(.footnote).foregroundStyle(HUD.dim)

                        if recordings.fetching == one.id {
                            ProgressView(value: recordings.progress).tint(HUD.accent)
                        } else {
                            // The composite first, because it answers more: the screen is what
                            // somebody did and the face is who did it.
                            if one.evidence != nil {
                                Button("Screen + camera") {
                                    Task { await recordings.fetch(one, kind: "Evidence") }
                                }
                                .buttonStyle(HUDButtonStyle())
                            }

                            if one.camera != nil {
                                Button("Camera only") {
                                    Task { await recordings.fetch(one, kind: "Camera") }
                                }
                                .buttonStyle(HUDButtonStyle())
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(HUD.background.ignoresSafeArea())
        .task { await recordings.load() }
        .refreshable { await recordings.load() }
        .sheet(item: Binding(
            get: { recordings.playing.map(Playing.init) },
            set: { if $0 == nil { recordings.playing = nil } })) { item in
            VideoPlayer(player: AVPlayer(url: item.url))
                .ignoresSafeArea()
        }
    }

    private struct Playing: Identifiable {
        let url: URL
        var id: String { url.path }
    }
}
