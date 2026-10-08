import Foundation

/// One of the things JARVIS last read out, wherever it read them out - priority §15.
///
/// The phone's end of the shared conversation's offers. Three fields and no fourth: where it came
/// in the list, what JARVIS called it, and somewhere to go when there is somewhere.
///
/// **There is deliberately nowhere to put a browser handle.** The PC's own offered items carry a
/// reference to an element in a live page, and the PC drops it before the offer crosses: a handle
/// to a tab on the desk means nothing here, and acting on it would send a click to a page that had
/// moved on while telling the owner it had worked. What this phone can do with an offer is
/// recognise it and open its address. That is the whole of it.
struct MobileOffer: Codable, Equatable {
    let position: Int
    let title: String
    let address: String?
}

/// What "the second one" turned out to mean on this phone.
enum MobileOfferPick: Equatable {
    case none
    case one(MobileOffer)
    case ambiguous([MobileOffer])
}

/// Which of the things JARVIS read out a sentence means, and what may be done about it - §15.
///
/// Pure, and the same shape as the PC's resolution so the two nodes agree about what "the second
/// one" means. Not the same code - that lives in C# - which is why the window and the ordinals are
/// written out here with the PC's values beside them in the comments.
enum MobileOffers {
    /// How long a list stays the one being talked about. The PC's window, to the minute.
    static let resolvesFor: TimeInterval = 20 * 60

    /// The words that pick a position out of a list.
    ///
    /// Ordinals only, which is the PC's own vocabulary. Cardinals are deliberately absent: with
    /// "one" meaning position one, "open the fifth one" found no fifth, carried on, hit "one" and
    /// opened the first - the worst possible answer to a sentence that named a position.
    private static let ordinals: [String: Int] = [
        "first": 1, "1st": 1, "top": 1,
        "second": 2, "2nd": 2,
        "third": 3, "3rd": 3,
        "fourth": 4, "4th": 4,
        "fifth": 5, "5th": 5,
        "last": -1
    ]

    /// The words a list is made of, one of which has to be there.
    ///
    /// Required, and that is the point: "open the second one" is about the list and "what's the
    /// weather" is not, and a reading that resolved any ordinal anywhere would answer the wrong
    /// question confidently. The PC draws the same line for the same reason - "first" and "top"
    /// are ordinary words, and "play top gun" is not about a list.
    private static let pointers = [
        "one", "ones", "option", "options", "result", "results",
        "video", "videos", "clip", "link", "item", "idea", "ideas", "page", "list"
    ]

    /// Which offer a sentence means.
    static func pick(_ said: String, from offers: [MobileOffer]) -> MobileOfferPick {
        guard !offers.isEmpty else { return .none }

        let words = said
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        guard words.contains(where: { pointers.contains($0) }) else { return .none }

        // A position, when one was named. "The last one" is the end of the list rather than a
        // number, which is how people actually refer to the end of a list.
        //
        // And a position nobody offered ends it rather than falling through to the titles: the
        // owner named a place in the list, there is nothing there, and guessing from the words
        // instead would be answering a different question.
        for word in words {
            guard let position = ordinals[word] else { continue }

            if position == -1, let last = offers.last { return .one(last) }

            return offers.first(where: { $0.position == position }).map { MobileOfferPick.one($0) } ?? .none
        }

        // No position, so the title has to carry it. Every offer whose title shares a distinctive
        // word with the sentence; one is an answer and two is a question.
        let said = Set(words.filter { $0.count > 3 })

        let matching = offers.filter { offer in
            !said.isDisjoint(with: Set(offer.title
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 3 }))
        }

        if matching.count == 1 { return .one(matching[0]) }
        if matching.count > 1 { return .ambiguous(matching) }

        return .none
    }

    /// Whether this phone can open the offer, or only recognise it.
    static func reopenable(_ offer: MobileOffer) -> Bool {
        guard let address = offer.address, let url = URL(string: address) else { return false }

        return url.scheme == "https" || url.scheme == "http"
    }

    /// What JARVIS says about an offer it knows - priority §15.
    ///
    /// The distinction the brief insists on, in words the owner reads: knowing which one they mean
    /// is not having the tab. Opening it here is a new page on this phone, and saying so is the
    /// difference between an assistant that is honest about its two bodies and one that is not.
    static func because(_ offer: MobileOffer, pcName: String) -> String {
        reopenable(offer)
            ? "Opening \u{201C}\(offer.title)\u{201D} here, sir. The tab you had is still on \(pcName)."
            : "I know which one you mean, sir - \u{201C}\(offer.title)\u{201D} - but there's nothing to open: "
                + "it was something I said rather than somewhere to go."
    }

    /// What to say when two of them fit equally well.
    static func whichOne(_ offers: [MobileOffer]) -> String {
        let named = offers.prefix(3).map { "\u{201C}\($0.title)\u{201D}" }.joined(separator: " or ")

        return "Which one, sir - \(named)?"
    }
}

/// The last list JARVIS read out, kept on this phone so it survives the desk going to sleep - §15.
///
/// **Why it is kept here at all.** The offers come from the PC, and the moment the owner most needs
/// them is the moment the PC is asleep: results read out at the desk in the evening, picked from on
/// the phone later. Fetching them on demand would mean the continuity only worked while the thing
/// it is meant to survive was up.
///
/// Bounded and expiring, for the same reason the PC's window exists: "the second one" twelve hours
/// after the list was read out is almost certainly about something else, and resolving it against
/// last night's results would be worse than not resolving it at all.
@MainActor
final class MobileOfferMemory: ObservableObject {
    static let shared = MobileOfferMemory()

    private static let key = "jarvis.offers.last"

    /// The most offers kept from one list. More than this and nobody is saying "the ninth one".
    static let most = 8

    private struct Held: Codable {
        let offers: [MobileOffer]
        let at: Date
        let node: String
    }

    @Published private(set) var offers: [MobileOffer] = []
    @Published private(set) var from: String = ""
    @Published private(set) var at: Date?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    /// The offers still worth resolving against, given the window.
    func current(now: Date = Date()) -> [MobileOffer] {
        guard let at, now.timeIntervalSince(at) <= MobileOffers.resolvesFor else { return [] }

        return offers
    }

    /// Keeps what a node has just read out.
    func hold(_ offers: [MobileOffer], from node: String, at when: Date = Date()) {
        let kept = Array(offers.prefix(Self.most))

        self.offers = kept
        self.from = node
        self.at = kept.isEmpty ? nil : when

        save()
    }

    func forget() {
        offers = []
        from = ""
        at = nil

        defaults.removeObject(forKey: Self.key)
    }

    private func load() {
        guard let data = defaults.data(forKey: Self.key),
              let held = try? JSONDecoder().decode(Held.self, from: data)
        else { return }

        offers = held.offers
        at = held.at
        from = held.node
    }

    private func save() {
        guard let at, !offers.isEmpty else {
            defaults.removeObject(forKey: Self.key)
            return
        }

        guard let data = try? JSONEncoder().encode(Held(offers: offers, at: at, node: from)) else { return }

        defaults.set(data, forKey: Self.key)
    }
}
