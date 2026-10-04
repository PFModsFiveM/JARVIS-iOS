import Foundation

// MARK: - The information architecture, as data
//
// §17 asks for a named hierarchy, §18 for search over it and §22 for a canonical link to every
// destination. Those are three views of one fact - what settings exist and where each one lives -
// so there is one declaration of it here and the screens, the search field and the URL handler all
// read from it.
//
// Written out as a table rather than grown inside a `body`, for two reasons. A page cannot be
// reachable from the list but missing from search, or linkable but absent from the list, because
// all three come from the same rows; `SettingsCatalogueTests` checks that every destination has
// exactly one entry and every slug is unique, which is a test that can only exist if the structure
// is data. And the old page could not have been searched at all: it was a `VStack` at the
// ViewBuilder's ten-child limit, with a `Group` wrapped round two panels to get under it.

/// Every page Settings can show. The raw value is the slug in `jarvis://settings/<slug>`, so it is
/// part of the app's external contract: widgets, Shortcuts and the PC all build links from it.
/// Rename a case and old links break - add a case instead.
enum SettingsDestination: String, CaseIterable, Hashable, Codable {
    // GENERAL
    case connection = "connection"
    case appearance = "appearance"
    case voice = "voice"
    case siri = "siri"
    case alerts = "alerts"

    // MOBILE JARVIS - what this phone is on its own, not what it can ask the PC for
    case mobileCapabilities = "mobile"
    case standbyLights = "standby-lights"
    case whereabouts = "whereabouts"

    // PC-PRIME
    case waking = "waking"
    case reaching = "reaching"

    // SMART HOME
    case smartHome = "smart-home"

    // SECURITY
    case footageStore = "footage-store"

    // LEARNING
    case learning = "learning"

    // ADVANCED
    case diagnostics = "diagnostics"
    case encryption = "encryption"
    case forget = "forget"

    // ABOUT
    case about = "about"
}

/// The nine groups of §17, in the order they appear.
enum SettingsCategory: String, CaseIterable, Hashable {
    case general
    case mobile
    case pcPrime
    case smartHome
    case security
    case learning
    case advanced
    case about

    var title: String {
        switch self {
        case .general: return "General"
        case .mobile: return "Mobile JARVIS"
        case .pcPrime: return "PC-Prime"
        case .smartHome: return "Smart home"
        case .security: return "Security"
        case .learning: return "Learning"
        case .advanced: return "Advanced"
        case .about: return "About"
        }
    }

    /// One line under the group's name on the top-level list. The groups are not self-explanatory -
    /// "Mobile JARVIS" against "PC-Prime" is the whole architecture in two words - so each says what
    /// it is for.
    var note: String? {
        switch self {
        case .mobile: return "What this phone can do on its own, with your PC off."
        case .pcPrime: return "The machine that does the heavy work, and how this phone reaches it."
        default: return nil
        }
    }
}

struct SettingsEntry: Identifiable, Hashable {
    let destination: SettingsDestination
    let title: String
    let subtitle: String
    let symbol: String
    let category: SettingsCategory
    /// What somebody might type looking for this page, including the words that are *not* on it.
    /// "Tailscale" is the obvious example: it is the answer to "mobile data" and neither phrase
    /// appears in the page's title.
    let keywords: [String]

    var id: SettingsDestination { destination }
}

enum SettingsCatalogue {
    static let entries: [SettingsEntry] = [
        // MARK: General
        SettingsEntry(destination: .connection,
                      title: "PC connection",
                      subtitle: "Which machine this phone is paired with, and its key.",
                      symbol: "desktopcomputer",
                      category: .general,
                      keywords: ["pair", "pairing", "key", "fingerprint", "reconnect", "version", "trust", "sign in"]),
        SettingsEntry(destination: .appearance,
                      title: "Display",
                      subtitle: "The centrepiece, and whether the face has expressions.",
                      symbol: "circle.hexagongrid",
                      category: .general,
                      keywords: ["face", "circle", "orb", "centrepiece", "expressions", "theme", "look", "appearance"]),
        SettingsEntry(destination: .voice,
                      title: "Voice",
                      subtitle: "Speaking answers, JARVIS's own voice, and the wake word.",
                      symbol: "waveform",
                      category: .general,
                      keywords: ["speak", "speech", "tts", "wake word", "hey jarvis", "listen", "microphone", "accent", "voice"]),
        SettingsEntry(destination: .siri,
                      title: "Siri and the Action button",
                      subtitle: "Asking JARVIS without opening the app.",
                      symbol: "mic.circle",
                      category: .general,
                      keywords: ["siri", "shortcuts", "action button", "hey siri", "intents"]),
        SettingsEntry(destination: .alerts,
                      title: "Alerts",
                      subtitle: "Reaching this phone while JARVIS is closed.",
                      symbol: "bell",
                      category: .general,
                      keywords: ["ntfy", "notifications", "push", "alerts", "topic", "background"]),

        // MARK: Mobile JARVIS
        SettingsEntry(destination: .mobileCapabilities,
                      title: "What this phone can do",
                      subtitle: "Which requests it answers itself, and which are your PC's.",
                      symbol: "iphone.radiowaves.left.and.right",
                      category: .mobile,
                      keywords: ["capabilities", "offline", "pc off", "standalone", "node", "routing",
                                 "what can you do", "without the pc", "on its own"]),
        SettingsEntry(destination: .standbyLights,
                      title: "Switching lights without the PC",
                      subtitle: "This phone's own SwitchBot token.",
                      symbol: "lightbulb",
                      category: .mobile,
                      keywords: ["switchbot", "token", "secret", "keychain", "lights", "standby", "pc off", "credentials"]),
        SettingsEntry(destination: .whereabouts,
                      title: "Where you are",
                      subtitle: "Telling the PC when you leave and come home.",
                      symbol: "location",
                      category: .mobile,
                      keywords: ["location", "gps", "home", "away", "geofence", "whereabouts", "presence"]),

        // MARK: PC-Prime
        SettingsEntry(destination: .waking,
                      title: "Waking the PC",
                      subtitle: "Wake-on-LAN, at home and from outside.",
                      symbol: "power",
                      category: .pcPrime,
                      keywords: ["wake on lan", "wol", "magic packet", "mac", "broadcast", "switch on", "turn on pc", "cellular", "port"]),
        SettingsEntry(destination: .reaching,
                      title: "Reaching the PC from away",
                      subtitle: "Addresses, which network is preferred, and the connection log.",
                      symbol: "network",
                      category: .pcPrime,
                      keywords: ["tailscale", "mobile data", "remote", "address", "host", "vpn", "away from home", "route", "ddns"]),

        // MARK: Smart home
        SettingsEntry(destination: .smartHome,
                      title: "Lights and devices",
                      subtitle: "What JARVIS can switch, and from which node.",
                      symbol: "house",
                      category: .smartHome,
                      keywords: ["lights", "bedroom", "switchbot", "hub", "plug", "scene", "devices", "smart home"]),

        // MARK: Security
        SettingsEntry(destination: .footageStore,
                      title: "Watching the camera without your PC",
                      subtitle: "The read-only store the PC uploads to.",
                      symbol: "externaldrive.badge.icloud",
                      category: .security,
                      keywords: ["r2", "cloudflare", "bucket", "footage", "recordings", "store", "access key", "s3", "pc off"]),

        // MARK: Learning
        SettingsEntry(destination: .learning,
                      title: "Learning sessions",
                      subtitle: "What JARVIS works out about how it is being used.",
                      symbol: "brain",
                      category: .learning,
                      keywords: ["learning", "improve", "reflection", "corrections", "session", "analysis", "experience"]),

        // MARK: Advanced
        SettingsEntry(destination: .diagnostics,
                      title: "Connection diagnostics",
                      subtitle: "Every step of reaching the PC, and where it stopped.",
                      symbol: "stethoscope",
                      category: .advanced,
                      keywords: ["diagnostics", "debug", "log", "trace", "handshake", "why", "failed", "troubleshoot"]),
        SettingsEntry(destination: .encryption,
                      title: "Encryption self-test",
                      subtitle: "Checks this phone computes what the PC computes.",
                      symbol: "checkmark.seal",
                      category: .advanced,
                      keywords: ["encryption", "self test", "keys", "crypto", "verify", "frames"]),
        SettingsEntry(destination: .forget,
                      title: "Forget this PC",
                      subtitle: "Deletes this phone's keys.",
                      symbol: "trash",
                      category: .advanced,
                      keywords: ["forget", "unpair", "reset", "delete", "remove", "start again"]),

        // MARK: About
        SettingsEntry(destination: .about,
                      title: "About",
                      subtitle: "Versions, and what this app is.",
                      symbol: "info.circle",
                      category: .about,
                      keywords: ["about", "version", "build", "licence", "credits"]),
    ]

    private static let byDestination: [SettingsDestination: SettingsEntry] =
        Dictionary(entries.map { ($0.destination, $0) }, uniquingKeysWith: { first, _ in first })

    static func entry(for destination: SettingsDestination) -> SettingsEntry? {
        byDestination[destination]
    }

    static func entries(in category: SettingsCategory) -> [SettingsEntry] {
        entries.filter { $0.category == category }
    }

    /// The groups that actually have pages, in §17's order. A category with nothing in it does not
    /// appear, so a group can be declared before its pages exist without leaving a dead row.
    static var categories: [SettingsCategory] {
        SettingsCategory.allCases.filter { !entries(in: $0).isEmpty }
    }

    // MARK: Search
    //
    // §18. Every word of a query has to match something, and the best match for each word is what
    // counts - so "pc battery" finds the power page through two different fields, and "pc banana"
    // finds nothing rather than everything with "pc" in it.

    static func search(_ query: String) -> [SettingsEntry] {
        let tokens = query
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !tokens.isEmpty else { return [] }

        let scored: [(entry: SettingsEntry, score: Int)] = entries.compactMap { entry in
            var total = 0
            for token in tokens {
                let best = score(entry, token)
                guard best > 0 else { return nil }
                total += best
            }
            return (entry, total)
        }

        return scored
            .sorted { left, right in
                left.score == right.score
                    ? left.entry.title.localizedCaseInsensitiveCompare(right.entry.title) == .orderedAscending
                    : left.score > right.score
            }
            .map(\.entry)
    }

    private static func score(_ entry: SettingsEntry, _ token: String) -> Int {
        let title = entry.title.lowercased()
        if title.hasPrefix(token) { return 100 }

        // A word of the title starting with the token: "voice" finds "JARVIS's own voice" as
        // readily as it finds "Voice", which is what somebody scanning for a word expects.
        if title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(token) }) {
            return 85
        }
        if title.contains(token) { return 80 }

        let keywords = entry.keywords.map { $0.lowercased() }
        if keywords.contains(token) { return 70 }
        if keywords.contains(where: { $0.hasPrefix(token) }) { return 60 }
        if keywords.contains(where: { $0.contains(token) }) { return 50 }

        if entry.category.title.lowercased().contains(token) { return 40 }
        if entry.subtitle.lowercased().contains(token) { return 30 }
        return 0
    }

    // MARK: Links
    //
    // §22. `jarvis://settings` opens the list; `jarvis://settings/<slug>` opens one page. The PC's
    // own Settings window, a widget and a Shortcut can all send somebody straight to the row they
    // need rather than naming it and hoping.

    static func destination(forPath path: String) -> SettingsDestination? {
        let slug = path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        guard !slug.isEmpty else { return nil }
        if let exact = SettingsDestination(rawValue: slug) { return exact }

        // A link that names a group rather than a page goes to that group's first page, which is
        // better than doing nothing and is what somebody writing jarvis://settings/security means.
        if let category = SettingsCategory.allCases.first(where: { $0.rawValue.lowercased() == slug }) {
            return entries(in: category).first?.destination
        }
        return nil
    }

    static func link(to destination: SettingsDestination) -> URL {
        URL(string: "jarvis://settings/\(destination.rawValue)")!
    }
}
