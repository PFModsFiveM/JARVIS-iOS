import Foundation

/// Which sentences are phrases and which are answers - priority §14.
///
/// **The distinction the cache needs and did not have.** `VoiceCache` kept every sentence the PC
/// rendered, keyed on the words. That is right for "Right away, sir." and wrong for "Your iPhone
/// is at forty-seven per cent, sir.": the second is true for about a minute, will never be asked
/// for in those exact words again, and takes one of a hundred and twenty slots that exist so
/// JARVIS still has its own voice with the desk asleep. A hundred battery readings and the phrase
/// bank is gone - and re-warming it is three renders per connection.
///
/// So the rule the brief states - do not put a percentage or a number inside a static cached
/// phrase - is enforced here, as a property of the sentence, rather than trusted to every caller
/// that ever speaks.
///
/// It says nothing about whether a sentence may be *spoken*. Everything is spoken. This decides
/// only what is worth keeping afterwards.
enum SpokenPhrase {
    /// The longest a sentence can be and still be a phrase JARVIS says habitually.
    ///
    /// Measured against the bank: the longest of them is comfortably inside this, and a sentence
    /// twice as long is a bespoke answer whatever else is true of it.
    static let mostCharacters = 120

    /// Characters that mean the sentence carries a value rather than a sentiment.
    ///
    /// Digits catch percentages, counts, times and dates. The symbols catch the cases where the
    /// number has already been spelled out but the unit has not - and a sentence with a currency
    /// or degree sign in it is an answer about a quantity either way.
    private static let values = CharacterSet(charactersIn: "0123456789%£$€°")

    /// Whether this sentence is worth keeping in JARVIS's own voice.
    static func worthKeeping(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty, trimmed.count <= mostCharacters else { return false }

        return trimmed.rangeOfCharacter(from: values) == nil
    }

    /// Why a sentence is not kept, for the voice diagnosis rather than for a log.
    static func whyNotKept(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty { return "there is nothing to keep" }

        if trimmed.count > mostCharacters {
            return "it is a bespoke answer rather than a phrase, at \(trimmed.count) characters"
        }

        if trimmed.rangeOfCharacter(from: values) != nil {
            return "it carries a value, which would be stale the next time it was played"
        }

        return nil
    }

    /// Whether these words are one of the phrase bank's own, which the bank may not lose.
    ///
    /// Compared against `SpokenKind.words` rather than matched loosely, for the same reason the
    /// bank is keyed by kind in the first place: a loose match is a thing that works until
    /// somebody rewords a sentence.
    static func isOneOfTheBanks(_ text: String) -> Bool {
        SpokenKind.allCases.contains { $0.words == text }
    }
}
