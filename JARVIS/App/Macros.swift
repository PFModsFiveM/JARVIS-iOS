import Foundation
import SwiftUI

/// A button of your own: a named list of steps JARVIS runs on the PC in order.
struct Macro: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var symbol: String
    var steps: [MacroStep]
}

enum MacroStep: Codable, Hashable {
    /// A sentence for JARVIS, exactly as if said at the desk - anything JARVIS can do.
    case ask(String)
    case open(String)
    /// `playPause`, `next` or `previous`.
    case media(String)
    case volume(Int)
    /// A key chord such as `Win+D`; needs control (Face ID once).
    case key(String)
    case wait(Double)
    case lock

    var summary: String {
        switch self {
        case .ask(let text): return "Ask: \(text)"
        case .open(let name): return "Open \(name)"
        case .media(let action): return action == "playPause" ? "Play / pause" : action == "next" ? "Next track" : "Previous track"
        case .volume(let percent): return "Volume \(percent)%"
        case .key(let chord): return "Press \(chord)"
        case .wait(let seconds): return String(format: "Wait %.0f s", seconds)
        case .lock: return "Lock the PC"
        }
    }
}

/// The phone's macros, kept on the phone. Starts with three examples to change or delete.
@MainActor
final class MacroStore: ObservableObject {
    static let shared = MacroStore()
    private static let key = "macros"

    @Published var macros: [Macro] {
        didSet { save() }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key), let saved = try? JSONDecoder().decode([Macro].self, from: data) {
            macros = saved
        } else {
            macros = [
                Macro(name: "Music", symbol: "music.note", steps: [.open("Spotify"), .wait(3), .media("playPause")]),
                Macro(name: "Focus", symbol: "moon.stars", steps: [.media("playPause"), .volume(25), .ask("brief me")]),
                Macro(name: "Leaving", symbol: "figure.walk", steps: [.media("playPause"), .lock])
            ]
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(macros) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    func macro(named name: String) -> Macro? {
        macros.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

/// Runs a macro's steps in order over one connection, and says how it went. Used by the app and by Siri.
enum MacroRunner {
    static func run(_ macro: Macro, on client: BridgeClient) async throws -> String {
        var controlTaken = false
        var failures: [String] = []

        for step in macro.steps {
            let reply: BridgeMessage?
            switch step {
            case .ask(let text):
                reply = try await client.request("ask", ["text": text], timeout: 90)
            case .open(let name):
                reply = try await client.request("app.open", ["name": name], timeout: 60)
            case .media(let action):
                reply = try await client.request("media.action", ["action": action])
            case .volume(let percent):
                reply = try await client.request("volume", ["percent": percent])
            case .key(let chord):
                if !controlTaken {
                    let granted = try await client.approvedRequest("control.start", reason: "Let \"\(macro.name)\" press keys on your PC")
                    controlTaken = granted.kind == "done"
                }
                reply = controlTaken ? try await client.request("input.key", ["chord": chord]) : nil
            case .wait(let seconds):
                try await Task.sleep(nanoseconds: UInt64(max(0, min(seconds, 60)) * 1_000_000_000))
                reply = nil
            case .lock:
                reply = try await client.request("security.lock")
            }

            if let reply, reply.kind == "failed" || reply.kind == "error" {
                failures.append("\(step.summary): \(reply.message)")
            }
        }

        return failures.isEmpty ? "\(macro.name): done." : "\(macro.name): " + failures.joined(separator: " ")
    }
}

// MARK: - views

/// The macro buttons on the Control tab, with + to make a new one and a long press to edit.
struct MacrosPanel: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var store = MacroStore.shared
    @State private var editing: Macro?
    @State private var running: UUID?

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 8)]

    var body: some View {
        HUDFrame(title: "Macros") {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(store.macros) { macro in
                    Button {
                        Task { await run(macro) }
                    } label: {
                        VStack(spacing: 6) {
                            if running == macro.id {
                                ProgressView().tint(HUD.accent)
                            } else {
                                Image(systemName: macro.symbol).font(.system(size: 20))
                            }
                            Text(macro.name).font(.system(size: 12, weight: .semibold, design: .monospaced)).lineLimit(1)
                        }
                        .foregroundStyle(HUD.accent)
                        .frame(maxWidth: .infinity, minHeight: 64)
                        .background(HUD.accent.opacity(0.08))
                        .overlay(Rectangle().stroke(HUD.accent.opacity(0.35), lineWidth: 1))
                    }
                    .contextMenu {
                        Button("Edit") { editing = macro }
                        Button("Delete", role: .destructive) { store.macros.removeAll { $0.id == macro.id } }
                    }
                }
                Button {
                    editing = Macro(name: "New", symbol: "sparkles", steps: [])
                } label: {
                    Image(systemName: "plus").font(.system(size: 20)).foregroundStyle(HUD.dim)
                        .frame(maxWidth: .infinity, minHeight: 64)
                        .overlay(Rectangle().stroke(HUD.dim.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
                }
            }
            Text("Tap to run, press and hold to edit. Siri can run them too: \u{201C}Run Music with JARVIS\u{201D}.")
                .font(.footnote).foregroundStyle(HUD.dim)
        }
        .sheet(item: $editing) { macro in
            MacroEditor(macro: macro) { saved in
                if let index = store.macros.firstIndex(where: { $0.id == saved.id }) {
                    store.macros[index] = saved
                } else {
                    store.macros.append(saved)
                }
            }
        }
    }

    private func run(_ macro: Macro) async {
        running = macro.id
        defer { running = nil }
        do {
            model.toast = try await MacroRunner.run(macro, on: try await model.session())
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            model.toast = error.localizedDescription
        }
    }
}

struct MacroEditor: View {
    @State var macro: Macro
    let save: (Macro) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var adding: String = ""
    @State private var value: String = ""

    private static let symbols = ["sparkles", "music.note", "moon.stars", "figure.walk", "gamecontroller", "tv", "bolt", "house",
                                  "briefcase", "headphones", "mic", "video", "lock", "sun.max", "bed.double", "cup.and.saucer"]

    private static let kinds: [(id: String, title: String, prompt: String)] = [
        ("ask", "Ask JARVIS", "e.g. open Blender and resume my project"),
        ("open", "Open an app or game", "e.g. Discord"),
        ("media", "Media", "playPause, next or previous"),
        ("volume", "Volume", "0-100"),
        ("key", "Press keys", "e.g. Win+D (needs control)"),
        ("wait", "Wait", "seconds"),
        ("lock", "Lock the PC", "")
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Name", text: $macro.name)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(Self.symbols, id: \.self) { symbol in
                                Image(systemName: symbol)
                                    .frame(width: 36, height: 36)
                                    .background(macro.symbol == symbol ? HUD.accent.opacity(0.3) : .clear)
                                    .onTapGesture { macro.symbol = symbol }
                            }
                        }
                    }
                }
                Section("Steps, in order") {
                    ForEach(Array(macro.steps.enumerated()), id: \.offset) { _, step in
                        Text(step.summary)
                    }
                    .onDelete { macro.steps.remove(atOffsets: $0) }
                    .onMove { macro.steps.move(fromOffsets: $0, toOffset: $1) }
                }
                Section("Add a step") {
                    Picker("Kind", selection: $adding) {
                        Text("Choose…").tag("")
                        ForEach(Self.kinds, id: \.id) { Text($0.title).tag($0.id) }
                    }
                    if let kind = Self.kinds.first(where: { $0.id == adding }), kind.id != "lock" {
                        TextField(kind.prompt, text: $value)
                            .textInputAutocapitalization(.never)
                            .keyboardType(kind.id == "volume" || kind.id == "wait" ? .decimalPad : .default)
                    }
                    Button("Add") { addStep() }.disabled(adding.isEmpty || (adding != "lock" && value.trimmingCharacters(in: .whitespaces).isEmpty))
                }
            }
            .navigationTitle(macro.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save(macro); dismiss() }.disabled(macro.name.trimmingCharacters(in: .whitespaces).isEmpty || macro.steps.isEmpty)
                }
                ToolbarItem(placement: .topBarLeading) { EditButton() }
            }
        }
    }

    private func addStep() {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let step: MacroStep?
        switch adding {
        case "ask": step = .ask(text)
        case "open": step = .open(text)
        case "media": step = ["playPause", "next", "previous"].contains(text) ? .media(text) : .media("playPause")
        case "volume": step = Int(text).map { .volume(min(max($0, 0), 100)) }
        case "key": step = .key(text)
        case "wait": step = Double(text).map { .wait(min(max($0, 0), 60)) }
        case "lock": step = .lock
        default: step = nil
        }
        if let step { macro.steps.append(step) }
        value = ""
    }
}
