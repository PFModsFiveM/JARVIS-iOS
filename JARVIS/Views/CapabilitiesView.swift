import SwiftUI

/// Everything JARVIS can do, straight from the PC's own catalogue, grouped and searchable. Each has its description and,
/// where JARVIS knows one, a sentence that reaches it - tap Try to ask it.
struct CapabilitiesView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var all: [Capability] = []
    @State private var search = ""
    @State private var loading = true

    struct Capability: Identifiable, Hashable {
        let name: String
        let description: String
        let category: String
        let risk: String
        let example: String?
        let confirms: Bool
        var id: String { name }

        var title: String { name.replacingOccurrences(of: "_", with: " ").capitalized }
    }

    private var groups: [(category: String, items: [Capability])] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = query.isEmpty ? all : all.filter {
            $0.name.lowercased().contains(query) || $0.description.lowercased().contains(query) || ($0.example?.lowercased().contains(query) ?? false)
        }
        return Dictionary(grouping: shown, by: \.category).map { ($0.key, $0.value) }.sorted { $0.category < $1.category }
    }

    var body: some View {
        NavigationStack {
            List {
                if loading {
                    ProgressView().tint(HUD.accent)
                }
                ForEach(groups, id: \.category) { group in
                    Section(group.category) {
                        ForEach(group.items) { item in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(item.title).font(.headline).foregroundStyle(HUD.text)
                                    if item.confirms { Image(systemName: "questionmark.circle").foregroundStyle(HUD.amber).font(.caption) }
                                    if item.risk == "High" { Image(systemName: "exclamationmark.triangle").foregroundStyle(HUD.alert).font(.caption) }
                                }
                                Text(item.description).font(.subheadline).foregroundStyle(HUD.dim)
                                if let example = item.example {
                                    Button {
                                        dismiss()
                                        Task { await model.ask(example) }
                                    } label: {
                                        Label("\u{201C}\(example)\u{201D}", systemImage: "play.circle")
                                            .font(.footnote).foregroundStyle(HUD.accent)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(HUD.background.ignoresSafeArea())
            .searchable(text: $search, prompt: "Search what JARVIS can do")
            .navigationTitle("What JARVIS can do")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await load() }
        }
    }

    private func load() async {
        defer { loading = false }
        guard let reply = try? await model.session().request("capabilities"), reply.kind == "capabilities" else {
            model.toast = "The PC didn't send its list."
            return
        }
        all = (reply.body["capabilities"] as? [[String: Any]] ?? []).map {
            Capability(name: $0["name"] as? String ?? "", description: $0["description"] as? String ?? "",
                       category: $0["category"] as? String ?? "Other", risk: $0["risk"] as? String ?? "",
                       example: $0["example"] as? String, confirms: $0["needsConfirmation"] as? Bool ?? false)
        }
    }
}

/// A row of things to try, shown before the first question: one tap asks, "…" ones fill the box to finish.
struct SuggestionChips: View {
    let pick: (String) -> Void

    static let suggestions = [
        "Brief me", "How's my PC doing?", "What's playing?", "Open Spotify", "Take a screenshot",
        "What's the weather?", "What am I working on?", "Remind me in 10 minutes to…", "Open Blender and resume my project",
        "Show the face", "Make the accent gold", "What's using my CPU?", "Clean up my downloads"
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Self.suggestions, id: \.self) { suggestion in
                    Button(suggestion) { pick(suggestion) }
                        .font(.footnote)
                        .foregroundStyle(HUD.accent)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .overlay(Rectangle().stroke(HUD.accent.opacity(0.35), lineWidth: 1))
                }
            }
        }
    }
}
