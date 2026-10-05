import Foundation

/// What a notice is about, so the owner can silence one kind without silencing all of them.
///
/// The same seven as the PC's `NoticeCategory`, by the same names. One mechanism with two halves:
/// the PC decides whether to send and this decides whether to show, and if the two disagreed about
/// what a category was the owner's setting would mean different things on each.
enum MobileNoticeCategory: String, Codable, CaseIterable, Identifiable {
    case security = "Security"
    case pcState = "PcState"
    case devicePower = "DevicePower"
    case smartHome = "SmartHome"
    case sync = "Sync"
    case routineSuggestion = "RoutineSuggestion"
    case learning = "Learning"
    case other = "Other"

    var id: String { rawValue }

    /// What the owner reads.
    var name: String {
        switch self {
        case .security: return "Security"
        case .pcState: return "Your PC"
        case .devicePower: return "Battery and power"
        case .smartHome: return "Smart home"
        case .sync: return "Syncing"
        case .routineSuggestion: return "Routine suggestions"
        case .learning: return "Learning"
        case .other: return "Everything else"
        }
    }

    /// One line saying what they would stop being told.
    var detail: String {
        switch self {
        case .security:
            return "Someone at the door, a challenge at the PC, a smoke alarm. Always interrupts."
        case .pcState:
            return "Your PC coming online or going away, and anything unusual about it."
        case .devicePower:
            return "A battery getting low, a charger connected or disconnected."
        case .smartHome:
            return "What happened when something switched, including when it didn't."
        case .sync:
            return "When observations have been waiting a long time to reach your PC."
        case .routineSuggestion:
            return "What I would offer to do, based on what you usually do."
        case .learning:
            return "What I concluded about your week, and what I changed my mind about."
        case .other:
            return "Anything I haven't put in a category yet."
        }
    }

    /// Whether this may interrupt. Only security, as on the PC.
    var interrupts: Bool { self == .security }

    /// Whether the owner is allowed to switch it off entirely.
    ///
    /// Security is not. A silenced notice is one that will not arrive, and this is the category
    /// where not arriving could matter. It can still be made quieter, which is the honest version
    /// of the same preference.
    var optional: Bool { self != .security }

    /// Whether this category is on unless the owner says otherwise.
    ///
    /// The quiet three are off by default on the phone, which is a stricter default than the PC's.
    /// A notification is more intrusive than a sentence spoken in a room the owner is already in,
    /// and a phone that buzzed about sync queues would be a phone whose notifications get turned
    /// off wholesale.
    var onByDefault: Bool {
        switch self {
        case .sync, .routineSuggestion, .learning: return false
        default: return true
        }
    }

    /// Which category one of this phone's own notice kinds belongs to.
    static func of(_ kind: NoticeKind) -> MobileNoticeCategory {
        switch kind {
        case .security: return .security
        case .pcAnswering, .pcAway: return .pcState
        case .batteryLow: return .devicePower
        case .footageArrived: return .security
        case .syncStuck: return .sync
        }
    }
}

/// What the owner has decided about each category, on this phone - priority §7A and §7B.
///
/// One store, and the owner's decisions live here rather than being scattered across the screens
/// that happen to produce each kind of notice. The brief asks for one canonical notification
/// settings authority; this is the phone's half of it, and it is deliberately the same shape as the
/// PC's `NoticePreferences` so that the two screens can say the same words.
///
/// Only what the owner actually changed is stored. A category added in a later version then
/// behaves sensibly for somebody who configured this today, rather than being silently off because
/// their saved settings did not mention it.
@MainActor
final class NoticeSettings: ObservableObject {
    static let shared = NoticeSettings()

    private static let key = "jarvis.notices.categories"

    @Published private(set) var decided: [String: Bool] = [:]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        decided = defaults.dictionary(forKey: NoticeSettings.key) as? [String: Bool] ?? [:]
    }

    /// Whether the owner wants anything from this category.
    func wants(_ category: MobileNoticeCategory) -> Bool {
        if !category.optional { return true }

        return decided[category.rawValue] ?? category.onByDefault
    }

    /// Turns a category on or off. Refuses to switch security off.
    @discardableResult
    func set(_ category: MobileNoticeCategory, wanted: Bool) -> Bool {
        guard category.optional || wanted else { return false }

        decided[category.rawValue] = wanted
        defaults.set(decided, forKey: NoticeSettings.key)

        return true
    }

    /// Forgets a decision, so the category goes back to its default.
    func useDefault(_ category: MobileNoticeCategory) {
        decided.removeValue(forKey: category.rawValue)
        defaults.set(decided, forKey: NoticeSettings.key)
    }

    /// Whether a notice of this kind should be shown at all.
    func wanted(_ kind: NoticeKind) -> Bool {
        wants(MobileNoticeCategory.of(kind))
    }

    /// Whether the owner has changed this category from its default, for the settings screen.
    func changed(_ category: MobileNoticeCategory) -> Bool {
        decided[category.rawValue] != nil
    }
}
