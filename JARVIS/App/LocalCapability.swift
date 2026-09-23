import Foundation

/// A request this phone can carry out by itself, without the PC.
///
/// Almost everything the app does is a sentence forwarded to the PC, which is right: the PC is where
/// JARVIS lives and where the tools are. But there is one class of request that cannot work that way
/// and never will - the ones about a PC that is asleep. "Wake my PC" sent to a sleeping PC is a
/// request with nowhere to go.
///
/// So a small number of requests are answered here first. The rule for what belongs is narrow and
/// worth keeping: **only what is impossible while the PC is off.** Anything else goes to the PC,
/// where the understanding is, rather than being reimplemented in the phone's own words.
enum LocalCapability: Equatable {
    /// Turn a machine on. The name is the one the rest of JARVIS will use when a Home Node can do
    /// this too, so the button, the voice command and whatever comes later are one action.
    case wake(target: String?)

    /// The capability's name, as the PC's own tool catalogue would write it.
    var action: String {
        switch self {
        case .wake: return "device.power.wake"
        }
    }

    /// What the request was about, when it named something.
    var target: String? {
        switch self {
        case .wake(let target): return target
        }
    }

    /// Whether a sentence is one of the few things this phone must answer itself.
    ///
    /// Not five string comparisons in five places. One reading, used by the typed box, by the wake
    /// word and by Siri, so "wake my PC", "turn the computer on" and "get the workstation online"
    /// are the same action arriving three ways - and adding a way of saying it is one line here
    /// rather than a search through the app.
    ///
    /// Deliberately conservative. It looks for a waking word and a machine word in the same
    /// sentence, so "wake me at seven" and "turn the lights on" are the PC's business, as they
    /// should be: a phone that grabbed those would be worse than one that grabbed nothing.
    static func of(_ sentence: String) -> LocalCapability? {
        let words = sentence.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        guard !words.isEmpty else { return nil }

        let waking = ["wake", "waken", "start", "boot", "power", "turn", "switch", "online"]
        let machines = ["pc", "computer", "workstation", "desktop", "rig", "machine", "tower"]

        guard words.contains(where: { waking.contains($0) }), words.contains(where: { machines.contains($0) }) else {
            return nil
        }

        // "turn the computer off" and "shut the PC down" are the opposite request, and the PC can
        // answer those itself because it is awake to hear them.
        let opposite = ["off", "down", "sleep", "asleep", "shutdown", "shut", "hibernate", "restart", "reboot"]
        guard !words.contains(where: { opposite.contains($0) }) else { return nil }

        // "turn on" and "switch on" need the "on"; "wake" and "boot" do not. Without this,
        // "turn the computer round" would be a wake request.
        let needsOn = ["turn", "switch", "power"]
        if words.contains(where: { needsOn.contains($0) })
            && !words.contains(where: { ["wake", "waken", "start", "boot", "online"].contains($0) })
            && !words.contains("on") {
            return nil
        }

        return .wake(target: named(in: words, among: machines))
    }

    /// The machine the sentence named, when it named one in particular.
    private static func named(in words: [String], among machines: [String]) -> String? {
        // "wake dom-pc" - a word that is none of ours and looks like a name.
        let ours = Set(["wake", "waken", "start", "boot", "power", "turn", "switch", "online", "on", "the", "my",
                        "please", "up", "jarvis", "get"] + machines)

        return words.first { !ours.contains($0) && $0.count > 2 }
    }
}
