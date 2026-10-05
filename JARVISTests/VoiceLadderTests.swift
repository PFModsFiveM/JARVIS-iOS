import XCTest
@testable import JARVIS

/// Whose voice answers, and when nothing does - programme §4A to §4C.
///
/// The requirement behind every one of these is a sentence from the brief: generic Apple speech
/// must not unexpectedly replace JARVIS. So the interesting assertions are the ones about what is
/// *not* spoken.
final class VoiceLadderTests: XCTestCase {
    private func able(
        cached: String? = nil,
        onDevice: Bool = false,
        pcAnswering: Bool = false,
        systemVoiceAllowed: Bool = false,
        speaking: Bool = true
    ) -> MobileVoiceRouter.Able {
        MobileVoiceRouter.Able(
            cached: cached, onDevice: onDevice, pcAnswering: pcAnswering,
            systemVoiceAllowed: systemVoiceAllowed, speaking: speaking)
    }

    // MARK: the order

    func testACachedRenderingWinsOverEverythingBecauseItIsJarvissOwnVoice() {
        let route = MobileVoiceRouter.route(
            "Certainly, sir.",
            able: able(cached: "Certainly, sir.", onDevice: true, pcAnswering: true, systemVoiceAllowed: true))

        XCTAssertEqual(route, .cached("Certainly, sir."))
    }

    func testOnDeviceComesBeforeThePcBecauseItNeedsNoNetwork() {
        let route = MobileVoiceRouter.route(
            "Right away, sir.", able: able(onDevice: true, pcAnswering: true, systemVoiceAllowed: true))

        XCTAssertEqual(route, .onDevice)
    }

    func testThePcIsUsedWhenNothingLocalCanSpeakInJarvissVoice() {
        XCTAssertEqual(
            MobileVoiceRouter.route("Right away, sir.", able: able(pcAnswering: true)), .fromThePC)
    }

    // MARK: the rung that is off

    /// The whole reason this type exists.
    func testWithNothingAvailableTheWordsAreShownRatherThanSpokenByAStranger() {
        let route = MobileVoiceRouter.route("Right away, sir.", able: able())

        XCTAssertEqual(route, .text("Right away, sir."))
        XCTAssertFalse(route.spoken)
    }

    func testThePhonesOwnVoiceIsUsedOnlyWhenTheOwnerHasAllowedIt() {
        XCTAssertEqual(
            MobileVoiceRouter.route("Right away, sir.", able: able(systemVoiceAllowed: true)),
            .systemVoice)
    }

    func testTheReasonGivenForFallingToTextSaysWhyRatherThanThatItFailed() {
        let route = MobileVoiceRouter.route("Right away, sir.", able: able())
        let because = MobileVoiceRouter.because(route, able: able())

        XCTAssertTrue(because.contains("phone's own voice is off"))
        XCTAssertTrue(because.contains("surprised"))
    }

    func testSpeakingBeingOffMeansNothingIsSpokenByAnyRoute() {
        let route = MobileVoiceRouter.route(
            "Right away, sir.",
            able: able(cached: "Right away, sir.", pcAnswering: true, systemVoiceAllowed: true, speaking: false))

        XCTAssertFalse(route.spoken)
    }

    func testAnEmptySentenceIsNotSpoken() {
        XCTAssertFalse(MobileVoiceRouter.route("   ", able: able(pcAnswering: true)).spoken)
    }

    /// On-device synthesis is not available, and the reason is stated rather than implied.
    func testTheMissingRungSaysExactlyWhatIsMissing() {
        XCTAssertTrue(MobileVoiceRouter.whyNotOnDevice.contains("onnxruntime"))
        XCTAssertTrue(MobileVoiceRouter.whyNotOnDevice.contains("espeak-ng"))
    }

    // MARK: the phrase bank, keyed rather than matched

    func testEveryPhraseHasWordsAndNoneCarriesAValueThatCouldGoStale() {
        for kind in SpokenKind.allCases {
            XCTAssertFalse(kind.words.isEmpty, "\(kind)")

            // A pre-rendered sentence cannot contain a number or a name: it would be recorded
            // once and then be wrong for ever, in JARVIS's own voice, which is worse than text.
            XCTAssertNil(kind.words.rangeOfCharacter(from: .decimalDigits), "\(kind): \(kind.words)")
            XCTAssertFalse(kind.words.contains("%"), "\(kind)")
        }
    }

    func testThePhrasesAreDistinctSoTheCacheCannotCollapseTwoOfThem() {
        let words = SpokenKind.allCases.map(\.words)

        XCTAssertEqual(Set(words).count, words.count)
    }

    /// Keyed by kind, never by matching the text of an answer.
    func testAPhraseIsFoundByItsKindAndNotBySearchingAnAnswer() {
        XCTAssertEqual(SpokenKind.atHome.words, "You're at home, sir.")
        XCTAssertEqual(SpokenKind(rawValue: "atHome"), .atHome)
    }

    // MARK: the cache key

    /// A cache keyed on text alone goes on speaking in last month's voice for ever.
    func testTheKeyIncludesTheVoiceSoChangingItOrphansTheOldAudio() {
        let one = VoiceCache.key("Certainly, sir.", "voice-a")
        let two = VoiceCache.key("Certainly, sir.", "voice-b")

        XCTAssertNotEqual(one, two)
    }

    func testTheSameWordsInTheSameVoiceAreTheSameKey() {
        XCTAssertEqual(
            VoiceCache.key("Certainly, sir.", "voice-a"),
            VoiceCache.key("Certainly, sir.", "voice-a"))
    }

    func testTheKeyIsAFixedLengthWhateverTheSentence() {
        let short = VoiceCache.key("Yes.", "v")
        let long = VoiceCache.key(String(repeating: "a very long sentence ", count: 50), "v")

        XCTAssertEqual(short.count, long.count)
    }

    @MainActor
    func testAnEmptyCacheHoldsNothingAndWantsEveryPhrase() {
        let cache = VoiceCache.shared
        cache.voice(is: "test-voice")
        cache.forget()
        defer { cache.forget() }

        XCTAssertEqual(cache.held, 0)
        XCTAssertFalse(cache.holds("Certainly, sir."))
        XCTAssertEqual(cache.missing().count, SpokenKind.allCases.count)
    }

    @MainActor
    func testWithNoVoiceKnownNothingIsWantedBecauseNothingCouldBeKeyed() {
        let cache = VoiceCache.shared
        cache.voice(is: "")
        defer { cache.forget() }

        XCTAssertTrue(cache.missing().isEmpty)
    }

    @MainActor
    func testKeepingAndReadingBackASentenceWorks() {
        let cache = VoiceCache.shared
        cache.voice(is: "test-voice")
        cache.forget()
        defer { cache.forget() }

        // Not real audio - the cache does not inspect it, which is the point of keeping the
        // playing in `Voice` and the keeping here.
        let wav = Data(repeating: 7, count: 2048)

        cache.keep("Certainly, sir.", wav: wav, mouth: [0.1, 0.2, 0.3])

        XCTAssertTrue(cache.holds("Certainly, sir."))
        XCTAssertEqual(cache.held, 1)
        XCTAssertEqual(cache.audio(for: "Certainly, sir.")?.wav, wav)
        XCTAssertEqual(cache.audio(for: "Certainly, sir.")?.mouth, [0.1, 0.2, 0.3])
        XCTAssertFalse(cache.missing().contains(.certainly))
    }

    @MainActor
    func testChangingTheVoiceThrowsTheOldAudioAwayRatherThanServingIt() {
        let cache = VoiceCache.shared
        cache.voice(is: "voice-a")
        cache.forget()
        defer { cache.forget() }

        cache.keep("Certainly, sir.", wav: Data(repeating: 1, count: 1024), mouth: [])
        XCTAssertTrue(cache.holds("Certainly, sir."))

        cache.voice(is: "voice-b")

        XCTAssertFalse(cache.holds("Certainly, sir."))
        XCTAssertEqual(cache.held, 0)
    }

    @MainActor
    func testAnAbsurdlyLargeRenderingIsRefusedRatherThanFillingTheDisk() {
        let cache = VoiceCache.shared
        cache.voice(is: "test-voice")
        cache.forget()
        defer { cache.forget() }

        cache.keep("Huge.", wav: Data(repeating: 0, count: VoiceCache.mostBytes), mouth: [])

        XCTAssertFalse(cache.holds("Huge."))
    }

    @MainActor
    func testTheCacheIsBoundedByCount() {
        let cache = VoiceCache.shared
        cache.voice(is: "test-voice")
        cache.forget()
        defer { cache.forget() }

        for index in 0..<(VoiceCache.most + 10) {
            cache.keep("Sentence \(index).", wav: Data(repeating: 3, count: 512), mouth: [])
        }

        XCTAssertLessThanOrEqual(cache.held, VoiceCache.most)

        // And what survived is what was kept most recently, which is the useful end.
        XCTAssertTrue(cache.holds("Sentence \(VoiceCache.most + 9)."))
    }

    func testSentinel() {}
}
