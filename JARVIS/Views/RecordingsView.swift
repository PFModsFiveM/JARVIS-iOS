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

    /// Whether it has been seen. "Hidden" on this screen; `Acknowledged` on the PC.
    var seen: Bool

    struct Clip: Equatable {
        let kind: String
        let name: String
        let bytes: Int

        /// The composite - the screen being used with the camera inset - rather than the camera alone.
        var isEvidence: Bool { kind.caseInsensitiveCompare("Evidence") == .orderedSame }
    }

    var evidence: Clip? { clips.first(where: { $0.isEvidence }) }
    var camera: Clip? { clips.first(where: { !$0.isEvidence }) }

    /// Whether it happened recently enough to want looking at now.
    ///
    /// A day rather than an hour: somebody who was out all afternoon should come back to the
    /// afternoon's incidents under Recent, not have to go hunting for them under Earlier.
    var isRecent: Bool { at > Date.now.addingTimeInterval(-86_400) }

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
            accept(reply.body["recordings"] as? [[String: Any]] ?? [])
        } catch {
            trouble = error.localizedDescription
        }
    }

    static func read(_ body: [String: Any]) -> SecurityRecording? {
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
            clips: clips,
            seen: body["acknowledged"] as? Bool ?? false)
    }

    /// Takes the PC's list.
    ///
    /// Separate from <c>load</c> so the grouping can be tested without a PC: the sections are the
    /// part with rules in them, and rules that only run against a live bridge are rules nobody
    /// checks.
    func accept(_ rows: [[String: Any]]) {
        recordings = rows.compactMap(Self.read)
    }

    /// The ones worth looking at, newest first.
    var recent: [SecurityRecording] { recordings.filter { !$0.seen && $0.isRecent } }

    /// Older, and still not seen.
    var earlier: [SecurityRecording] { recordings.filter { !$0.seen && !$0.isRecent } }

    /// Hidden, kept rather than deleted - and still watchable.
    var hidden: [SecurityRecording] { recordings.filter(\.seen) }

    /// Hides an incident, or puts it back.
    ///
    /// Drawn before the PC answers, because the tap should feel like it did something, and put
    /// back if the PC refuses - the list is the PC's, and a phone that quietly disagreed with it
    /// would be worse than one that flickered.
    func hide(_ recording: SecurityRecording, _ seen: Bool) async {
        guard let index = recordings.firstIndex(where: { $0.id == recording.id }) else { return }

        let before = recordings[index].seen
        recordings[index].seen = seen

        do {
            _ = try await model.session().request("camera.event.ack", ["id": recording.id, "seen": seen], timeout: 10)
        } catch {
            recordings[index].seen = before
            trouble = "That didn't reach your PC, so nothing changed."
        }
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
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var stored = FootageModel.shared

    /// Hidden incidents are collapsed, not gone. Off each time the screen opens.
    @State private var showHidden = false

    /// This screen is presented as a sheet from Security, so it needs its own way out. A
    /// ScrollView in a sheet is swipe-dismissable, but "swipe from the right place" is not an
    /// affordance somebody finds while annoyed, and it was the first half of the trap.
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    HUDLabel(text: "What the camera kept", color: HUD.accent)

                    Spacer(minLength: 8)

                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(HUD.dim)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Close recordings")
                }
                .padding(.top, 8)

                if let trouble = recordings.trouble {
                    HUDFrame(title: "Trouble", tint: HUD.alert) {
                        Text(trouble).font(.footnote).foregroundStyle(HUD.dim)
                    }
                }

                if recordings.loading {
                    HUDFrame { Text("Reading…").foregroundStyle(HUD.dim) }
                } else if recordings.recordings.isEmpty && !model.link.isOnline {
                    // Not "nothing was recorded": the PC is the only thing that knows that, and it
                    // is not answering. What the store holds is a different question, below.
                    HUDFrame {
                        Text("Your PC isn't answering, so this is whatever it uploaded before it went off.")
                            .font(.footnote).foregroundStyle(HUD.dim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if recordings.recordings.isEmpty {
                    HUDFrame {
                        Text("Nothing has been recorded in the last week.")
                            .foregroundStyle(HUD.dim)
                    }
                }

                // Recent first and on its own, because the question somebody opens this screen
                // with is "what happened while I was out", and a week of incidents in one flat
                // list answers it slowly.
                if !recordings.recent.isEmpty {
                    HUDLabel(text: "Recent", color: HUD.alert)
                    ForEach(recordings.recent) { one in card(one) }
                }

                if !recordings.earlier.isEmpty {
                    HUDLabel(text: "Earlier", color: HUD.accent)
                    ForEach(recordings.earlier) { one in card(one) }
                }

                // What the store holds, which is the only thing readable with the PC off. Shown
                // below the PC's own list rather than mixed into it: the PC knows everything and
                // the store knows what was uploaded, and running them together would make it
                // impossible to tell which answered.
                StoredFootageSection()

                if !recordings.hidden.isEmpty {
                    Button(showHidden
                           ? "Hide \(recordings.hidden.count) seen"
                           : "Show \(recordings.hidden.count) seen") {
                        withAnimation { showHidden.toggle() }
                    }
                    .buttonStyle(HUDButtonStyle())

                    if showHidden {
                        ForEach(recordings.hidden) { one in card(one) }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(HUD.background.ignoresSafeArea())
        .task { await recordings.load() }
        .refreshable { await recordings.load() }
        // One player for both lists, with a Close button that is always reachable. This was a
        // sheet on a sheet containing a full-bleed VideoPlayer: AVPlayerViewController ate the
        // drag gesture, ignoresSafeArea covered the top edge, and there was no way back short of
        // closing the app.
        .recordingPlayer(Binding(
            get: { recordings.playing.map { RecordingPlayable(url: $0, title: "Recording") } },
            set: { if $0 == nil { recordings.playing = nil } }))
    }

    /// One incident: what it was, what there is to watch, and a way to put it away.
    @ViewBuilder
    private func card(_ one: SecurityRecording) -> some View {
        HUDFrame(
            title: one.at.formatted(date: .abbreviated, time: .shortened),
            tint: one.seen ? HUD.dim : HUD.alert
        ) {
            Text(one.summary).font(.footnote).foregroundStyle(HUD.dim)

            if recordings.fetching == one.id {
                ProgressView(value: recordings.progress).tint(HUD.accent)
            } else {
                // The composite first, because it answers more: the screen is what somebody
                // did and the face is who did it.
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

                // Hiding keeps it. Nothing on this screen deletes a recording, because the one
                // time that matters is the time somebody taps it by accident.
                Button(one.seen ? "Put back" : "Hide") {
                    Task { await recordings.hide(one, !one.seen) }
                }
                .buttonStyle(HUDButtonStyle())
            }
        }
    }

}

/// What the shared store holds, which is what can be watched with the PC off.
///
/// Deliberately its own section rather than mixed into the PC's list. The PC knows about every
/// incident; the store knows about the ones it managed to upload, and each row says exactly what of
/// it is there - the details, a still, or the whole recording. Running the two together would make
/// it impossible to tell which answered, and "ready to watch" means different things to each.
struct StoredFootageSection: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var stored = FootageModel.shared

    @State private var joining = false
    @State private var said: String?
    @State private var fetching: String?
    @State private var playing: URL?

    var body: some View {
        HUDFrame(title: "Without your PC") {
            Text(stored.summary)
                .font(.footnote).foregroundStyle(HUD.dim)
                .fixedSize(horizontal: false, vertical: true)

            if let said {
                Text(said)
                    .font(.footnote).foregroundStyle(HUD.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if stored.coordinates == nil || stored.vault == nil {
                Button(HUD.spaced(joining ? "Joining..." : "Join the store")) {
                    joining = true
                    Task {
                        said = await stored.join()
                        joining = false
                    }
                }
                .buttonStyle(HUDButtonStyle())
                .disabled(joining || !model.link.isOnline)
            } else {
                Button(HUD.spaced(stored.reading ? "Reading..." : "Read the store")) {
                    Task { await stored.refresh() }
                }
                .buttonStyle(HUDButtonStyle())
                .disabled(stored.reading || !stored.ready)
            }

            ForEach(stored.incidents) { incident in
                VStack(alignment: .leading, spacing: 6) {
                    Text(incident.summary)
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundStyle(HUD.text)

                    Text(incident.startedAt.formatted(date: .abbreviated, time: .standard))
                        .font(.caption).foregroundStyle(HUD.dim)

                    // The honest line. A row whose recording is still going up says so rather
                    // than offering a play button that would hand back something unplayable.
                    Text(incident.availability)
                        .font(.caption)
                        .foregroundStyle(incident.clipComplete ? HUD.accent : HUD.amber)
                        .fixedSize(horizontal: false, vertical: true)

                    if incident.clipComplete {
                        Button(fetching == incident.id ? "Fetching…" : "Watch (\(incident.size))") {
                            fetching = incident.id
                            Task {
                                playing = await stored.download(incident)
                                fetching = nil
                            }
                        }
                        .buttonStyle(HUDButtonStyle())
                        .disabled(fetching != nil)
                    }
                }
                .padding(.vertical, 6)
            }
        }
        // The same player as the PC-provided list above, for the same reason: two near-identical
        // player screens is how one of them ends up with the exit and the other does not.
        .recordingPlayer(Binding(
            get: { playing.map { RecordingPlayable(url: $0, title: "Recording") } },
            set: { if $0 == nil { playing = nil } }))
    }
}
