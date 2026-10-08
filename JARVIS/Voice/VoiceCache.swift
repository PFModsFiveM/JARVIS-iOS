import CryptoKit
import Foundation

/// JARVIS's own voice, kept so it works with the PC off - programme §4C.
///
/// The thing that makes the top rung of the ladder reachable at all. The PC renders a sentence
/// once; this keeps the audio; from then on that sentence is in JARVIS's own voice with no network
/// and no desk. Since most of what JARVIS says is one of a few dozen sentences, warming this from
/// the phrase bank covers nearly every ordinary exchange.
///
/// **The key includes the voice, not just the words.** A cache keyed on text alone would keep
/// speaking in last month's voice after the owner changed it, and would do so indefinitely because
/// nothing would ever invalidate it. The model's checksum is part of the key, so changing the voice
/// silently orphans the old audio rather than serving it.
@MainActor
final class VoiceCache: ObservableObject {
    static let shared = VoiceCache()

    /// The most sentences kept. A few dozen phrases plus room for what the owner actually says.
    static let most = 120

    /// The most disk it may take. Piper at 22 kHz is roughly 44 kB a second, so this is minutes.
    static let mostBytes = 12 * 1024 * 1024

    /// How long an unused entry survives. Long, because the point is to be there when offline.
    static let keepFor: TimeInterval = 90 * 24 * 60 * 60

    /// Which voice the kept audio is in. Changing it makes everything held unreachable.
    @Published private(set) var voiceId: String = ""

    @Published private(set) var held = 0
    @Published private(set) var bytes = 0

    /// Sentences rendered and deliberately not kept, because they carried a value - priority §14.
    @Published private(set) var notKept = 0

    /// Why the last one was not kept. Shown in the voice diagnosis, never a number of its own.
    @Published private(set) var lastNotKept: String?

    private struct Entry: Codable {
        let key: String
        let words: String
        var usedAt: Date
        var bytes: Int
        var mouth: [Float]
    }

    private var entries: [String: Entry] = [:]
    private var loaded = false

    private init() { load() }

    /// Tells the cache which voice is being kept, orphaning anything from another.
    ///
    /// Called when the PC says what its voice is. A change throws the audio away rather than
    /// keeping it for a voice nobody uses: disk is cheaper than the owner hearing two JARVISes.
    func voice(is identity: String) {
        load()

        guard identity != voiceId else { return }

        for key in entries.keys { remove(key) }

        entries = [:]
        voiceId = identity
        recount()
        save()
    }

    /// The audio for exactly these words, if it is held, and its mouth schedule.
    func audio(for words: String) -> (wav: Data, mouth: [Float])? {
        load()

        let key = Self.key(words, voiceId)

        guard var entry = entries[key], let wav = try? Data(contentsOf: Self.file(key)) else { return nil }

        entry.usedAt = Date()
        entries[key] = entry
        save()

        return (wav, entry.mouth)
    }

    /// Whether these words are held, without reading the audio off disk.
    func holds(_ words: String) -> Bool {
        load()

        return entries[Self.key(words, voiceId)] != nil
    }

    /// Keeps a rendering the PC has just sent.
    /// Keeps the audio for a sentence worth keeping, and refuses one that is not - priority §14.
    ///
    /// The refusal is here rather than at the call site on purpose. Every sentence the PC renders
    /// arrives through one path, and a caller that forgot would quietly fill the bank with
    /// percentages; a sentence carrying a value is stale the next time it would be played, and the
    /// slot it took belongs to a phrase JARVIS says every day.
    func keep(_ words: String, wav: Data, mouth: [Float]) {
        load()

        guard !voiceId.isEmpty, !wav.isEmpty, wav.count < Self.mostBytes / 4 else { return }

        guard SpokenPhrase.worthKeeping(words) else {
            notKept += 1
            lastNotKept = SpokenPhrase.whyNotKept(words)

            return
        }

        let key = Self.key(words, voiceId)

        do {
            try wav.write(to: Self.file(key), options: [.atomic])
        } catch {
            return
        }

        entries[key] = Entry(key: key, words: words, usedAt: Date(), bytes: wav.count, mouth: mouth)

        trim()
        recount()
        save()
    }

    /// The phrases that are not held yet, so the PC can be asked for exactly those.
    func missing(_ kinds: [SpokenKind] = SpokenKind.allCases) -> [SpokenKind] {
        load()

        guard !voiceId.isEmpty else { return [] }

        return kinds.filter { !holds($0.words) }
    }

    func forget() {
        load()

        for key in entries.keys { remove(key) }

        entries = [:]
        recount()
        save()
    }

    // MARK: keeping it bounded

    /// Drops the stalest entries until the cache is inside both of its limits.
    ///
    /// By last use rather than by age, because the phrases JARVIS says constantly should survive
    /// indefinitely and a sentence the owner said once in March should not.
    private func trim() {
        for (key, entry) in entries where Date().timeIntervalSince(entry.usedAt) > Self.keepFor {
            remove(key)
            entries.removeValue(forKey: key)
        }

        // The bank last - priority §14. Within each group the stalest goes first, as before, but
        // a sentence the owner happened to say once never evicts one of the phrases the bank
        // exists to hold: those are what make JARVIS's own voice work with the desk asleep, and
        // re-warming them costs three renders a connection.
        // One comparator rather than two sorts, because Swift's sort is not stable and a second
        // pass would scramble the staleness order inside each group.
        var order = entries.values.sorted { left, right in
            let leftIsBank = SpokenPhrase.isOneOfTheBanks(left.words)
            let rightIsBank = SpokenPhrase.isOneOfTheBanks(right.words)

            if leftIsBank != rightIsBank { return leftIsBank }

            return left.usedAt > right.usedAt
        }

        while order.count > Self.most || order.reduce(0, { $0 + $1.bytes }) > Self.mostBytes {
            guard let stalest = order.popLast() else { break }

            remove(stalest.key)
            entries.removeValue(forKey: stalest.key)
        }
    }

    private func recount() {
        held = entries.count
        bytes = entries.values.reduce(0) { $0 + $1.bytes }
    }

    // MARK: on disk

    /// The key: the words and the voice together, so a voice change orphans rather than misleads.
    nonisolated static func key(_ words: String, _ voiceId: String) -> String {
        let material = Data("\(voiceId)|\(words)".utf8)
        let digest = SHA256.hash(data: material)

        return digest.map { String(format: "%02x", $0) }.joined().prefix(24).description
    }

    private static var folder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = support.appendingPathComponent("jarvis-voice", isDirectory: true)

        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        return folder
    }

    private static func file(_ key: String) -> URL {
        folder.appendingPathComponent("\(key).wav")
    }

    private static var index: URL { folder.appendingPathComponent("index.json") }

    private func remove(_ key: String) {
        try? FileManager.default.removeItem(at: Self.file(key))
    }

    private struct Stored: Codable {
        var voiceId: String
        var entries: [Entry]
    }

    private func load() {
        guard !loaded else { return }

        loaded = true

        guard let data = try? Data(contentsOf: Self.index),
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return }

        voiceId = stored.voiceId
        entries = Dictionary(uniqueKeysWithValues: stored.entries.map { ($0.key, $0) })

        // Anything the index claims and the disk does not have is dropped rather than returned as
        // an entry that fails to read: an interrupted write should cost one phrase, not a crash.
        for (key, _) in entries where !FileManager.default.fileExists(atPath: Self.file(key).path) {
            entries.removeValue(forKey: key)
        }

        recount()
    }

    private func save() {
        let stored = Stored(voiceId: voiceId, entries: Array(entries.values))

        guard let data = try? JSONEncoder().encode(stored) else { return }

        try? data.write(to: Self.index, options: [.atomic])
    }
}
