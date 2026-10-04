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
///
/// A light is the third member of that set, and only by the same test. Switching it normally goes
/// through the PC and should: the PC owns the device state and tells every other phone what
/// changed. But a PC that is off cannot relay a command to SwitchBot, so the choice is between this
/// phone addressing the device itself and the light being unreachable until the PC wakes. The match
/// is made against the devices the PC itself taught this phone, never against a word list - so the
/// names here are JARVIS's names, and adding a device to the PC adds it here with no code at all.
enum LocalCapability: Equatable {
    /// Turn a machine on. The name is the one the rest of JARVIS will use when a Home Node can do
    /// this too, so the button, the voice command and whatever comes later are one action.
    case wake(target: String?)

    /// Ask a machine what it is doing. Answerable while the PC is off, because the thing that
    /// answers it is the pre-login service rather than JARVIS - and unanswerable any other way,
    /// which is what puts it here rather than on the PC.
    case state(target: String?)

    /// Work a device this phone was taught to reach, because the PC cannot relay the command.
    ///
    /// Carries JARVIS's own device id, never the vendor's, so this is the same action the panel's
    /// switch takes and the same one the PC would have taken.
    case device(id: String, command: StandbyCommand)

    /// How a device is doing for battery - programme §18.
    ///
    /// Here by the same test as the others: a battery is readable only by the device it is in, so
    /// this phone's own level is something the PC cannot look up however awake it is. It reports
    /// it over the bridge while connected, and with the PC off the reading is still here to be
    /// read - which makes this the one question about power the phone must answer itself.
    ///
    /// The target is whatever was named, or nil for everything readable. Nothing here decides
    /// whether the named thing exists: the reporter matches it against what it actually read.
    case power(target: String?)

    /// The capability's name, as the PC's own tool catalogue would write it.
    var action: String {
        switch self {
        case .wake: return "device.power.wake"
        case .state: return "device.power.state"
        case .power: return "device.power.battery"
        case .device(_, let command):
            switch command {
            case .on: return "devices.power.on"
            case .off: return "devices.power.off"
            case .press: return "devices.press"
            }
        }
    }

    /// What the request was about, when it named something.
    var target: String? {
        switch self {
        case .wake(let target), .state(let target), .power(let target): return target
        case .device(let id, _): return id
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
    static func of(_ sentence: String, devices: [StandbyDevice] = []) -> LocalCapability? {
        let words = sentence.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        guard !words.isEmpty else { return nil }

        // A battery, first. "Is my phone charging" carries both a machine word and a power word,
        // so a wake rule asked before this one would read it as a request to switch something on -
        // and the question is one only this phone can answer at all.
        if let battery = aBatteryQuestion(words) { return battery }

        let waking = ["wake", "waken", "start", "boot", "power", "turn", "switch", "online"]
        let machines = ["pc", "computer", "workstation", "desktop", "rig", "machine", "tower"]

        guard words.contains(where: { waking.contains($0) }), words.contains(where: { machines.contains($0) }) else {
            // Not a request to switch something on. It may still be a question about one, which is
            // the other thing that cannot be asked of a PC that is off - or a device this phone was
            // taught to reach, which is the third.
            if askingAboutAMachine(words, machines: machines) {
                return .state(target: named(in: words, among: machines))
            }

            return aDeviceThisPhoneCanReach(words, devices: devices)
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

    /// Whether a sentence is asking what a machine is doing, rather than telling it to do something.
    ///
    /// Only questions. "Is my PC on" is a question this phone can answer while the PC is off; "turn
    /// my PC on" is the request above, and "lock my PC" is the PC's own business. Requiring a
    /// question word is what keeps those apart without a list of phrasings - and a sentence that is
    /// neither goes to the PC, where the understanding lives.
    private static func askingAboutAMachine(_ words: [String], machines: [String]) -> Bool {
        let asking = ["is", "are", "was", "has", "does", "did", "whats", "what", "hows", "how", "status", "state"]

        guard words.contains(where: { asking.contains($0) }) else { return false }
        guard words.contains(where: { machines.contains($0) }) else { return false }

        // The words that make it a question about its state rather than about anything else it
        // might be doing - "is the PC rendering" is a question for the PC, which is awake to answer.
        let about = ["on", "off", "awake", "asleep", "sleeping", "locked", "unlocked", "up", "down",
                     "running", "doing", "status", "state", "signed"]

        return words.contains(where: { about.contains($0) })
    }

    /// A device the PC taught this phone to reach, when the sentence clearly names one.
    ///
    /// Deliberately strict in both directions. Every word of the device's own name - or its room
    /// and its kind - must be in the sentence, so "turn the light on" with two lights in the house
    /// matches neither rather than guessing one; and the sentence must carry an unambiguous verb,
    /// so "is the bedroom light on" is a question for the PC and not a command to switch it.
    private static func aDeviceThisPhoneCanReach(_ words: [String], devices: [StandbyDevice]) -> LocalCapability? {
        guard !devices.isEmpty else { return nil }

        let asking = ["is", "are", "was", "has", "does", "did", "whats", "what", "hows", "how"]
        guard !words.contains(where: { asking.contains($0) }) else { return nil }

        let on = words.contains("on") || (words.contains("light") && words.contains("up"))
        let off = words.contains("off") || words.contains("out")
        let press = words.contains("press") || words.contains("toggle") || words.contains("flip")

        // "turn it on and off" names two opposite things and is nobody's command.
        guard !(on && off) else { return nil }

        let command: StandbyCommand
        if press { command = .press } else if on { command = .on } else if off { command = .off } else { return nil }

        let said = Set(words)

        let matches = devices.filter { device in
            let name = pieces(device.name)
            if !name.isEmpty && name.isSubset(of: said) { return true }

            // "bedroom light" where the device is called something else but sits in the bedroom.
            let room = pieces(device.room ?? "")
            return !room.isEmpty && room.isSubset(of: said) && said.contains(device.kind.lowercased())
        }

        guard matches.count == 1, let only = matches.first else { return nil }

        // A Bot on a push button has no on and off, and a switch has no bare press. Asked for the
        // wrong one, the sentence goes to the PC, which can explain it better than a word list can.
        if only.switches && command == .press { return nil }
        if !only.switches && command != .press { return .device(id: only.id, command: .press) }

        return .device(id: only.id, command: command)
    }

    /// Whether a sentence is asking how something is doing for battery.
    ///
    /// Anchored on the topic word - battery, charge, charging, charged - which is what separates
    /// "is my phone charging" from "is my phone on", and what keeps a rule written around "what's
    /// my X on" from claiming questions that have nothing to do with power. The same discriminator
    /// the PC's own fast path uses, for the same reason.
    ///
    /// The target is the word before or after the topic that is not one of the question's own
    /// words. Nothing is resolved here: the reporter decides whether it read anything by that name.
    private static func aBatteryQuestion(_ words: [String]) -> LocalCapability? {
        let topic = Set(["battery", "batteries", "charge", "charging", "charged"])
        guard words.contains(where: { topic.contains($0) }) else { return nil }

        // A command about power rather than a question about it: "charge my phone" is not something
        // a phone can do to itself, and "turn the charging off" is nobody's request here.
        let commanding = ["turn", "switch", "stop", "start", "set", "put", "plug", "unplug"]
        guard !words.contains(where: { commanding.contains($0) }) else { return nil }

        let ours = Set(["is", "are", "was", "what", "whats", "what's", "how", "hows", "how's", "much",
                        "the", "my", "a", "of", "on", "in", "for", "at", "it", "has", "have", "does",
                        "did", "got", "left", "level", "levels", "status", "tell", "me", "you", "can",
                        "could", "would", "will", "please", "jarvis", "s"]).union(topic)

        let named = words.filter { !ours.contains($0) && $0.count > 1 }

        // One name, or none. Two means the sentence is about something this reading cannot pick
        // out, and the PC - which has every node's readings - is the better place for it.
        return named.count <= 1 ? .power(target: named.first) : nil
    }

    /// A display name as the words it is made of, lower case.
    private static func pieces(_ text: String) -> Set<String> {
        Set(text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty })
    }

    /// The machine the sentence named, when it named one in particular.
    private static func named(in words: [String], among machines: [String]) -> String? {
        // "wake dom-pc" - a word that is none of ours and looks like a name.
        let ours = Set(["wake", "waken", "start", "boot", "power", "turn", "switch", "online", "on", "the", "my",
                        "please", "up", "jarvis", "get",
                        // The question's own words, so "is my pc locked" is about the pc and not
                        // about something called "locked".
                        "is", "are", "was", "has", "does", "did", "whats", "what", "hows", "how",
                        "status", "state", "off", "awake", "asleep", "sleeping", "locked",
                        "unlocked", "down", "running", "doing", "signed", "in", "anyone", "of"]
                       + machines)

        return words.first { !ours.contains($0) && $0.count > 2 }
    }
}
