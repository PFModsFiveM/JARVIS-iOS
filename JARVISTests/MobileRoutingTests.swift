import XCTest
@testable import JARVIS

/// Mobile JARVIS with the PC off, answering rather than deflecting - priority §3.
///
/// **The complaint.** With PC-Prime switched off, "What's the weather?" and "How are you?" both
/// came back as "That one is DOM-PC's, sir, and it isn't answering. Say 'wake my PC'...". Three
/// things were wrong with that. A greeting is not a machine's property. A question about the world
/// is not either, and this phone can answer one with a provider key. And offering to boot a PC is
/// no remedy for either, so the one sentence JARVIS had was advice about the wrong problem.
///
/// What is tested here is the routing and the words, both of which are pure functions of the node
/// state - so a PC that is off, a provider that is not configured and a wake that cannot be sent
/// are all states a test can simply state.
final class MobileRoutingTests: XCTestCase {

    private func state(
        pcAnswering: Bool = false,
        wakeEnabled: Bool = false,
        wakeReachable: Bool = false,
        cloud: Bool = false,
        token: Bool = false,
        devices: Int = 0
    ) -> MobileCapabilities.NodeState {
        var state = MobileCapabilities.NodeState(
            pcName: "DOM-PC",
            pcAnswering: pcAnswering,
            servicePaired: true,
            wakeEnabled: wakeEnabled,
            wakeReachable: wakeReachable,
            hasOwnDeviceToken: token,
            reachableDevices: devices)

        state.cloudReady = cloud

        return state
    }

    private var light: StandbyDevice {
        StandbyDevice([
            "id": "bedroom_main_light", "name": "Bedroom Light", "room": "Bedroom", "kind": "light",
            "provider": "SwitchBot", "providerDeviceId": "C271D2A08E4F", "preferPress": false
        ])!
    }

    // MARK: §3C - being spoken to

    func testAGreetingIsAPleasantryAndNotARequest() {
        for said in ["hello", "Hi", "hey Jarvis", "good morning", "Jarvis, good evening"] {
            guard case .pleasantry(.greeting) = LocalCapability.of(said) else {
                return XCTFail("\"\(said)\" should be a greeting")
            }
        }
    }

    func testHowAreYouIsAnsweredHereRatherThanBeingTheCalendarsProblem() {
        for said in ["how are you", "How are you doing?", "Jarvis, are you okay?", "how's it going"] {
            guard case .pleasantry(.howAreYou) = LocalCapability.of(said) else {
                return XCTFail("\"\(said)\" should be the how-are-you pleasantry")
            }
        }
    }

    func testThanksAndGoodbyesAndCheckingItIsThere() {
        guard case .pleasantry(.thanks) = LocalCapability.of("thank you") else { return XCTFail("thanks") }
        guard case .pleasantry(.goodbye) = LocalCapability.of("good night") else { return XCTFail("goodbye") }
        guard case .pleasantry(.areYouThere) = LocalCapability.of("are you there") else { return XCTFail("there") }

        // The name on its own is the owner checking JARVIS is listening, and it is the one
        // one-word sentence worth answering rather than forwarding.
        guard case .pleasantry(.areYouThere) = LocalCapability.of("Jarvis") else { return XCTFail("bare name") }
    }

    /// The reason the matching is exact. A keyword search for "how are you" would have swallowed
    /// a request, and a greeting that ate an instruction is worse than no greeting.
    func testASentenceThatMerelyStartsLikeAPleasantryIsStillARequest() {
        for said in ["how are you going to open Blender",
                     "hello, open Spotify",
                     "thanks, now turn the light off",
                     "are you there yet with the render"] {
            if case .pleasantry = LocalCapability.of(said) {
                XCTFail("\"\(said)\" is a request, not a pleasantry")
            }
        }
    }

    /// "How are things" is the status question and stays the status question, which is a better
    /// answer than a pleasantry: it says what is actually not where it should be.
    func testTheStatusQuestionIsNotSwallowedByThePleasantries() {
        XCTAssertEqual(LocalCapability.of("how are things"), .status)
        XCTAssertEqual(LocalCapability.of("is everything all right"), .status)
    }

    /// With the desk awake the PC says hello, because it knows what it has been doing. With the
    /// desk asleep this phone says it - which is the complaint, answered.
    func testAPleasantryGoesToThePCWhenThereIsOneAndIsAnsweredHereWhenThereIsNot() {
        let up = MobileCapabilities.decide("how are you", devices: [], state: state(pcAnswering: true))
        XCTAssertEqual(up.lane, .pcPrime)
        XCTAssertEqual(up.fallback, .localMobile(.pleasantry(.howAreYou)))

        let off = MobileCapabilities.decide("how are you", devices: [], state: state())
        XCTAssertEqual(off.lane, .localMobile(.pleasantry(.howAreYou)))
        XCTAssertNil(off.fallback)
    }

    func testTheAnswerToHowAreYouSaysWhichPartOfJarvisIsOutOfReach() {
        let said = MobilePhrases.pleasantry(.howAreYou, pcName: "DOM-PC", pcAnswering: false)

        XCTAssertTrue(said.contains("DOM-PC"), said)
        XCTAssertTrue(said.lowercased().contains("phone"), said)

        // And it never says "that one is the PC's", which is what it used to say.
        XCTAssertFalse(said.lowercased().contains("that one is"), said)
    }

    func testEveryPleasantryHasItsOwnAnswer() {
        let kinds: [LocalCapability.Pleasantry] = [.greeting, .howAreYou, .thanks, .areYouThere, .goodbye]

        let answers = kinds.map { MobilePhrases.pleasantry($0, pcName: "DOM-PC", pcAnswering: false) }

        XCTAssertEqual(Set(answers).count, kinds.count, "two pleasantries share an answer: \(answers)")
    }

    // MARK: §3B - what an unknown question is not

    /// The heart of it. An unrecognised question is not the PC's property, and the words must not
    /// say it is.
    func testAGeneralQuestionIsNeverCalledThePCsProperty() {
        let said = MobileCapabilities.nothingCanDoIt("how long does concrete take to cure", state: state())

        XCTAssertFalse(said.lowercased().contains("that one is"), said)
        XCTAssertTrue(said.lowercased().contains("provider"), "it should say what it actually needs: \(said)")
    }

    /// Both remedies, because both would have worked and neither is set up. The machine is named,
    /// so the owner knows which one is asleep.
    func testWithNeitherAPCNorAProviderBothAreOffered() {
        let said = MobileCapabilities.nothingCanDoIt("what's on my calendar", state: state(wakeEnabled: true, wakeReachable: true))

        XCTAssertTrue(said.contains("DOM-PC"), said)
        XCTAssertTrue(said.lowercased().contains("wake my pc"), said)
        XCTAssertTrue(said.lowercased().contains("settings"), said)
    }

    /// §3E. A wake is offered only where a wake would work.
    func testAWakeIsOfferedOnlyWhenAWakeWouldWork() {
        for sentence in ["open Blender", "what's the weather", "how long does concrete take to cure"] {
            let cannot = MobileCapabilities.nothingCanDoIt(sentence, state: state())
            XCTAssertFalse(cannot.lowercased().contains("wake my pc"), "\(sentence): \(cannot)")

            let can = MobileCapabilities.nothingCanDoIt(sentence, state: state(wakeEnabled: true, wakeReachable: true))
            XCTAssertTrue(can.lowercased().contains("wake my pc"), "\(sentence): \(can)")
        }
    }

    /// Something that genuinely needs the machine says so, and that is a different sentence from
    /// the one a general question gets.
    func testTheDesksOwnWorkIsNamedAsTheDesks() {
        XCTAssertEqual(MobileCapabilities.shape("open Blender"), .theDesk)
        XCTAssertEqual(MobileCapabilities.shape("close that window"), .theDesk)
        XCTAssertEqual(MobileCapabilities.shape("what's on my screen"), .theDesk)
        XCTAssertEqual(MobileCapabilities.shape("which projects do I have"), .theDesk)

        let desk = MobileCapabilities.nothingCanDoIt("open Blender", state: state())
        let general = MobileCapabilities.nothingCanDoIt("how long does concrete take to cure", state: state())

        XCTAssertNotEqual(desk, general)
    }

    func testAnUnrecognisedSentenceIsGeneralRatherThanTheDesks() {
        for said in ["how long does concrete take to cure",
                     "what's a good interior for a tow company",
                     "what's on my calendar",
                     "remind me why I started this"] {
            XCTAssertEqual(MobileCapabilities.shape(said), .general, said)
        }
    }

    // MARK: §3D - the cloud takes a general question

    func testAGeneralQuestionWithAProviderGoesToTheCloud() {
        let decision = MobileCapabilities.decide(
            "how long does concrete take to cure", devices: [light], state: state(cloud: true, token: true, devices: 1))

        XCTAssertEqual(decision.lane, .cloud)
    }

    /// The PC still wins when it is awake. This phone's provider is the lane for a PC that is not
    /// there, not a second opinion competing with the one JARVIS actually runs on.
    func testAnAnsweringPCStillGetsTheGeneralQuestion() {
        let decision = MobileCapabilities.decide(
            "how long does concrete take to cure", devices: [], state: state(pcAnswering: true, cloud: true))

        XCTAssertEqual(decision.lane, .pcPrime)
    }

    // MARK: §3F - weather, not guessed at

    /// Weather is not treated as something the PC owns, and it is not sent to a provider that
    /// would invent it either. Both of those would be wrong; saying so is not.
    func testWeatherIsNeitherFakedNorSentSomewhereThatWouldFakeIt() {
        let decision = MobileCapabilities.decide("what's the weather", devices: [], state: state(cloud: true))

        guard case .unavailable(let said) = decision.lane else {
            return XCTFail("a provider with no tools has no honest answer: \(decision.lane)")
        }

        XCTAssertTrue(said.lowercased().contains("weather"), said)
        XCTAssertTrue(said.lowercased().contains("won't guess"), said)

        // No number, and no sky. The failure would be a plausible invention, so the test looks
        // for the shape of one.
        XCTAssertFalse(said.contains("°"), said)
        for guessed in ["degrees", "sunny", "raining", "cloudy", "clear"] {
            XCTAssertFalse(said.lowercased().contains(guessed), "\(guessed) was invented: \(said)")
        }
    }

    func testTheOtherThingsNothingHereCanMeasure() {
        for (said, named) in [("what's the share price of Tesla", "market data"),
                              ("what's in the news", "news"),
                              ("what was the score", "sports data"),
                              ("how's the traffic", "traffic")] {
            XCTAssertEqual(MobileCapabilities.shape(said), .liveFact(named), said)
        }
    }

    /// Asking about a subject is not asking for its current value, and a provider can explain how
    /// a barometer works perfectly well.
    func testExplainingAThingIsNotReadingIt() {
        for said in ["how does weather radar work",
                     "why is the sky blue",
                     "what does a stock split mean",
                     "explain the news cycle"] {
            XCTAssertEqual(MobileCapabilities.shape(said), .general, said)
        }
    }

    /// With the PC awake, weather is answered the way everything else is - by the PC, which has
    /// the feed. It is not refused as "the PC's capability" and it is not refused at all.
    func testWithThePCAwakeWeatherIsJustAnotherQuestion() {
        XCTAssertEqual(
            MobileCapabilities.decide("what's the weather", devices: [], state: state(pcAnswering: true)).lane,
            .pcPrime)
    }

    // MARK: §3A - the node state

    /// JARVIS is online because this phone is running it. The desk is a separate line, and the
    /// word CONNECTING no longer stands for the whole assistant.
    func testJarvisIsOnlineEvenWithTheDeskAsleep() {
        XCTAssertEqual(MobileStatus.headline(), "JARVIS ONLINE")

        let nodes = MobileStatus.nodes(state(), pcWord: "OFFLINE")

        XCTAssertEqual(nodes.count, 2, "two nodes exist today and no others")
        XCTAssertEqual(nodes[0].title, "MOBILE")
        XCTAssertEqual(nodes[0].word, "ACTIVE")
        XCTAssertEqual(nodes[0].tone, .alive)
        XCTAssertEqual(nodes[1].title, "PC-PRIME")
        XCTAssertEqual(nodes[1].word, "OFFLINE")
        XCTAssertEqual(nodes[1].tone, .down)
    }

    func testThePCsWordIsThePanelsOwnWordAndNotASecondOpinion() {
        // Passed in rather than computed, so the strip and the panel under it cannot drift.
        for word in ["OFFLINE", "WAKING...", "CONNECTING", "ONLINE", "NOT PAIRED"] {
            XCTAssertEqual(MobileStatus.nodes(state(), pcWord: word)[1].word, word)
        }
    }

    func testAWakeableDeskSaysSoOnItsOwnLine() {
        let nodes = MobileStatus.nodes(state(wakeEnabled: true, wakeReachable: true), pcWord: "OFFLINE")

        XCTAssertEqual(nodes[1].detail, "Can be woken from here")
        XCTAssertNil(MobileStatus.nodes(state(pcAnswering: true), pcWord: "ONLINE")[1].detail)
    }

    /// Programme §54, restated for this screen: nothing collapses into "JARVIS offline" while this
    /// phone is the thing being asked.
    func testNothingSaysJarvisIsOffline() {
        XCTAssertTrue(MobileStatus.anythingUsable(state()))
        XCTAssertEqual(MobileStatus.nodes(state(), pcWord: "OFFLINE").first?.tone, .alive)
    }

    // MARK: The order, end to end

    /// The whole ladder in one test, with the PC off: what this phone does itself, what goes
    /// straight to a vendor, what it says in its own voice, what the provider takes, and what
    /// nothing can do - each in its own lane, none of them a transport error.
    func testTheLadderWithThePCOff() {
        let off = state(wakeEnabled: true, wakeReachable: true, cloud: true, token: true, devices: 1)

        // No target: "pc" is a machine word rather than a name, so nothing was named. The target
        // carries a name when one is given - "wake dom-pc" - and this says which it was.
        XCTAssertEqual(MobileCapabilities.decide("wake my pc", devices: [light], state: off).lane,
                       .localMobile(.wake(target: nil)))

        guard case .directDevice = MobileCapabilities.decide("lights out", devices: [light], state: off).lane else {
            return XCTFail("a light goes straight to the vendor")
        }

        XCTAssertEqual(MobileCapabilities.decide("hello", devices: [light], state: off).lane,
                       .localMobile(.pleasantry(.greeting)))

        XCTAssertEqual(MobileCapabilities.decide("how long does concrete take to cure", devices: [light], state: off).lane,
                       .cloud)

        guard case .unavailable = MobileCapabilities.decide("what's the weather", devices: [light], state: off).lane else {
            return XCTFail("a live fact is refused in words")
        }
    }

    /// Whatever the lane, the owner never reads a transport failure.
    func testNoLaneEverAnswersWithATransportFailure() {
        let leaks = ["error", "refused", "socket", "timeout", "nil", "0x", "exception"]

        for sentence in ["what's the weather", "how are you", "open Blender", "what's on my calendar",
                         "how long does concrete take to cure"] {
            for one in [state(), state(wakeEnabled: true, wakeReachable: true), state(cloud: true)] {
                let said = MobileCapabilities.nothingCanDoIt(sentence, state: one).lowercased()

                for leak in leaks {
                    XCTAssertFalse(said.contains(leak), "\(leak) reached the owner: \(said)")
                }
            }
        }
    }
}
