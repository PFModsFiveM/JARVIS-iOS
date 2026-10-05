import Foundation

/// What a cloud provider is told about the owner, and what it is never told - programme §3C.
///
/// **The rule is retrieval, not disclosure.** The owner's timeline is the richest thing JARVIS
/// holds and sending it with every question would be both useless and indefensible: useless
/// because a model given five hundred lines of context answers the question worse, and
/// indefensible because a general question about black holes is not a reason to tell a third party
/// where somebody lives.
///
/// So this builds a handful of short lines from what the question could plausibly need, and the
/// exclusions are absolute rather than best-effort:
///
/// - **no coordinates, ever**, in any form - a place reaches here as its name or not at all;
/// - no event the PC marked sensitive or secret;
/// - no device identifiers, keys, or anything from the Keychain;
/// - nothing from the timeline wholesale: the lines are composed here, from typed values.
///
/// It is a pure function of its arguments so the whole of what can leave the device is readable in
/// one place and assertable in a test, which is the only way a boundary like this stays true.
enum CloudContext {
    /// The most lines ever sent. Small on purpose: this is context, not a briefing.
    static let mostLines = 8

    /// The longest any one line may be, so a long document title cannot become a paragraph.
    static let longestLine = 160

    /// What the phone knows that a question might need.
    struct Known {
        /// The last few turns of this conversation, oldest first, as (said, answered).
        let turns: [(said: String, answered: String)]

        /// Where the owner is, as a name. Never a coordinate.
        let place: String?

        /// Whether the PC is answering, so the model does not offer to do things it cannot.
        let pcAnswering: Bool

        /// The name of the PC, when the owner has one paired.
        let pcName: String?

        /// The one pattern relevant to now, already worded as a pattern.
        let routine: String?

        init(
            turns: [(said: String, answered: String)] = [],
            place: String? = nil,
            pcAnswering: Bool = false,
            pcName: String? = nil,
            routine: String? = nil
        ) {
            self.turns = turns
            self.place = place
            self.pcAnswering = pcAnswering
            self.pcName = pcName
            self.routine = routine
        }
    }

    /// The context lines for one question, or none when the question needs none.
    ///
    /// Selection is by what the question is about rather than by what is available. A question
    /// about physics gets the conversation and nothing else; one that says "here" or "home" gets
    /// the place, because without it the pronoun is unanswerable.
    static func lines(for question: String, from known: Known) -> [String] {
        var lines: [String] = []

        // The conversation always, because a follow-up with no thread is a different question.
        // Trimmed to the last two exchanges: enough for "and the second one", not a transcript.
        for turn in known.turns.suffix(2) {
            lines.append("Earlier - asked: \(clip(turn.said))")
            lines.append("Earlier - answered: \(clip(turn.answered))")
        }

        let words = question.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        // The place only when the question is about where the owner is. This is the line that
        // would be a privacy failure if it were sent unconditionally.
        let aboutHere = ["here", "home", "nearby", "near", "local", "around", "outside", "weather"]

        if words.contains(where: { aboutHere.contains($0) }), let place = known.place {
            lines.append("The owner is at \(clip(place)).")
        }

        // What the ecosystem can do, only when the question asks for something to be done. A model
        // that is told the PC is asleep stops offering to open things on it.
        let askingForAction = ["open", "start", "run", "launch", "play", "switch", "turn", "wake", "lock", "send"]

        if words.contains(where: { askingForAction.contains($0) }) {
            lines.append(known.pcAnswering
                ? "The owner's PC is awake and can be asked to do things."
                : "The owner's PC is not answering, so nothing on it can be done right now.")
        }

        // A pattern, when the question is about the owner's day. Already hedged by the wording it
        // arrives in, so the model cannot restate it as a fact without contradicting its source.
        let aboutTheDay = ["usually", "normally", "routine", "today", "tomorrow", "schedule", "when"]

        if words.contains(where: { aboutTheDay.contains($0) }), let routine = known.routine {
            lines.append(clip(routine))
        }

        return Array(lines.prefix(mostLines))
    }

    private static func clip(_ text: String) -> String {
        let flat = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard flat.count > longestLine else { return flat }

        return String(flat.prefix(longestLine)) + "…"
    }
}
