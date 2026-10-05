import Foundation

/// How good the evidence behind a learned word is. The same four as the PC's `EvidenceStrength`.
enum MobileEvidence: String, Codable, Equatable, Comparable {
    case weak = "Weak"
    case medium = "Medium"
    case strong = "Strong"
    case veryStrong = "VeryStrong"

    private var rank: Int {
        switch self {
        case .weak: return 0
        case .medium: return 1
        case .strong: return 2
        case .veryStrong: return 3
        }
    }

    static func < (a: MobileEvidence, b: MobileEvidence) -> Bool { a.rank < b.rank }

    /// How to word an answer that rests on this.
    ///
    /// The owner's own word is stated; anything softer is hedged. Saying "that's the bedroom
    /// light" on an inference and being wrong is how an assistant stops being trusted about the
    /// things it is right about.
    var hedge: String {
        switch self {
        case .veryStrong: return ""
        case .strong: return ""
        case .medium: return "I think "
        case .weak: return "I'm guessing "
        }
    }
}

/// What sort of thing a word refers to. Matches the PC's `EntityKind`.
enum MobileEntityKind: String, Codable, Equatable, CaseIterable {
    case unknown = "Unknown"
    case device = "Device"
    case place = "Place"
    case project = "Project"
    case app = "App"
    case node = "Node"
    case person = "Person"
}

/// One of the owner's words for one thing, as this phone holds it.
struct MobileAlias: Codable, Equatable, Identifiable {
    /// The normalised phrase. The key, and the id.
    let said: String
    let entity: String
    let kind: MobileEntityKind
    let strength: MobileEvidence
    /// Whether the PC considers the evidence good enough to act on.
    let trusted: Bool
    let confidence: Double
    let count: Int
    let revision: Int64

    var id: String { said }
}

/// What the owner's words mean, on the phone - priority §4D and §6A.
///
/// The PC learns; the phone is told. The same split as places and for the same reason, with one
/// addition that matters more here: resolving a word is in the path of every command, so a phone
/// that had to ask the PC what "the bedroom lamp" means could not switch a light with the PC
/// asleep. That is the whole case the independence work exists for.
///
/// It resolves and it does not decide. The strength and the trusted flag come from the PC, which
/// has the evidence; the phone's only judgement is how to word what it says.
@MainActor
final class MobileAliases: ObservableObject {
    static let shared = MobileAliases()

    /// How many words are kept.
    ///
    /// Generous. An alias is a few dozen bytes, and the owner's vocabulary for their own house is
    /// the last thing worth dropping to save room on a phone with gigabytes of photographs.
    static let most = 300

    @Published private(set) var aliases: [MobileAlias] = []
    @Published private(set) var revision: Int64 = 0
    @Published private(set) var failed: String?

    private let store: URL?

    init(store: URL? = MobileAliases.defaultStore()) {
        self.store = store
        load()
    }

    /// The form a phrase is stored under. Must match the PC's `OwnerAliases.Normalise` exactly.
    ///
    /// If the two ever disagree the phone and the PC would resolve the same sentence differently,
    /// which is the one failure this whole design is meant to make impossible. Lower case,
    /// collapsed whitespace, leading article dropped; nothing stemmed and nothing expanded.
    static func normalise(_ said: String) -> String {
        var words = said
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)

        if words.count > 1, ["the", "my", "a"].contains(words[0]) {
            words.removeFirst()
        }

        return words.joined(separator: " ")
    }

    /// Applies rows from `aliases.pull`, forward only, with the retractions.
    func apply(_ rows: [MobileAlias], forgotten: [String], through: Int64) {
        var held = Dictionary(uniqueKeysWithValues: aliases.map { ($0.said, $0) })

        for row in rows {
            if let already = held[row.said], already.revision >= row.revision { continue }
            held[row.said] = row
        }

        for gone in forgotten {
            held.removeValue(forKey: MobileAliases.normalise(gone))
        }

        aliases = Array(held.values).sorted { $0.revision > $1.revision }
        revision = max(revision, through)
        failed = nil

        trim()
        save()
    }

    func couldNotCatchUp(_ why: String) {
        failed = why
    }

    /// What a phrase means, or why nothing does.
    ///
    /// Deterministic and local. The same ambiguity refusal as the PC: two things equally well
    /// described are answered as two, because switching one of them would be a coin toss in
    /// somebody's bedroom.
    func resolve(_ said: String, kind: MobileEntityKind = .unknown) -> MobileAliasVerdict {
        let key = MobileAliases.normalise(said)

        guard !key.isEmpty else { return .nothing("nothing was said") }

        if let exact = aliases.first(where: { $0.said == key }) {
            if kind != .unknown, exact.kind != .unknown, exact.kind != kind {
                return .nothing("\"\(key)\" is a \(exact.kind.rawValue.lowercased()), not a \(kind.rawValue.lowercased())")
            }

            return exact.trusted
                ? .one(exact)
                : .nothing("I'm not sure enough about what \"\(key)\" means")
        }

        let near = aliases
            .filter(\.trusted)
            .filter { kind == .unknown || $0.kind == kind || $0.kind == .unknown }
            .filter { $0.said.contains(key) || key.contains($0.said) }
            .sorted {
                if $0.strength != $1.strength { return $0.strength > $1.strength }
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.said.count < $1.said.count
            }

        guard let best = near.first else {
            return .nothing("I don't know what \"\(key)\" refers to")
        }

        let tied = near.filter { $0.strength == best.strength && $0.entity != best.entity }

        if let first = tied.first, first.count == best.count {
            return .several([best] + tied)
        }

        return .one(best)
    }

    /// Every word the owner has for one thing, for the devices screen.
    func words(for entity: String) -> [MobileAlias] {
        aliases
            .filter { $0.entity.caseInsensitiveCompare(entity) == .orderedSame }
            .sorted {
                $0.strength != $1.strength ? $0.strength > $1.strength : $0.count > $1.count
            }
    }

    func forget() {
        aliases = []
        revision = 0
        failed = nil
        save()
    }

    // MARK: - storage

    private func trim() {
        guard aliases.count > MobileAliases.most else { return }

        // The weakest go first. Nothing the owner said is dropped to make room for a guess.
        let ordered = aliases.sorted {
            $0.strength != $1.strength ? $0.strength < $1.strength : $0.count < $1.count
        }

        let drop = Set(ordered.prefix(aliases.count - MobileAliases.most).map(\.said))

        aliases = aliases.filter { !drop.contains($0.said) }
    }

    private struct Stored: Codable {
        var revision: Int64
        var aliases: [MobileAlias]
    }

    private static func defaultStore() -> URL? {
        guard let folder = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }

        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        return folder.appendingPathComponent("aliases.json")
    }

    private func load() {
        guard let store, let data = try? Data(contentsOf: store) else { return }
        guard let held = try? JSONDecoder().decode(Stored.self, from: data) else { return }

        revision = held.revision
        aliases = held.aliases
    }

    private func save() {
        guard let store else { return }

        guard let data = try? JSONEncoder().encode(Stored(revision: revision, aliases: aliases)) else { return }

        do {
            try data.write(to: store, options: .atomic)

            // Readable while locked, for the same reason as places: a command arriving from the
            // lock screen has to be able to resolve what the owner called something.
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: store.path)
        } catch {
            failed = "could not save what your words mean"
        }
    }
}

/// What the phone decided a phrase meant.
enum MobileAliasVerdict: Equatable {
    /// Exactly one thing.
    case one(MobileAlias)

    /// More than one, equally well described. Ask rather than guess.
    case several([MobileAlias])

    /// Nothing, and why.
    case nothing(String)

    var alias: MobileAlias? {
        if case .one(let alias) = self { return alias }
        return nil
    }

    var resolved: Bool { alias != nil }

    /// What to say, in JARVIS's own wording, hedged to the evidence.
    var spoken: String {
        switch self {
        case .one(let alias):
            return "\(alias.strength.hedge)you mean \(alias.entity)"
        case .several(let all):
            return "that could be \(all.count) different things"
        case .nothing(let because):
            return because
        }
    }
}
