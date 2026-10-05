import CoreLocation
import UserNotifications
import XCTest
@testable import JARVIS

/// Where the cloud lane stands, as six distinguishable states - priority §8A and §8B.
///
/// The brief's instruction is not to collapse these into "cloud unavailable", and the reason is
/// that each has a different thing the owner would do about it. No key means add one; a refused
/// key means check it; rate-limited means wait; no network means wait differently.
@MainActor
final class CloudStatusTests: XCTestCase {
    private func status() -> CloudStatus { CloudStatus() }

    func testNothingConfiguredIsNotTheSameAsNothingWorking() {
        let held = status()

        XCTAssertEqual(held.readiness, .notConfigured)
        XCTAssertFalse(held.readiness.worthTrying)
        XCTAssertTrue(held.readiness.detail.contains("Add a key"))
    }

    func testAKeyArrivingIsSetUpAndNotYetKnownToWork() {
        let held = status()
        held.configured(true)

        // "Working" is a claim about the provider and has to be earned by an answer.
        XCTAssertEqual(held.readiness, .configured)
        XCTAssertTrue(held.readiness.worthTrying)
    }

    func testAnAnswerIsTheOnlyThingThatMakesItWorking() {
        let held = status()
        held.configured(true)
        held.worked()

        XCTAssertEqual(held.readiness, .reachable)
        XCTAssertEqual(held.answered, 1)
        XCTAssertNotNil(held.lastAnswer)
        XCTAssertNil(held.lastProblem)
    }

    func testARefusedKeyIsNotWorthRetrying() {
        let held = status()
        held.failed(.refused("The provider didn't accept this phone's key. Check it in Settings."))

        XCTAssertEqual(held.readiness, .authenticationFailed)

        // A key will not start working on its own, and retrying it is how an account gets locked.
        XCTAssertFalse(held.readiness.worthTrying)
    }

    func testBeingRateLimitedIsStillWorthRetrying() {
        let held = status()
        held.failed(.refused("The provider is rate-limiting that key. Try again shortly."))

        XCTAssertEqual(held.readiness, .rateLimited)

        // The window passes. The alternative is a lane that stays off until the app is relaunched.
        XCTAssertTrue(held.readiness.worthTrying)
    }

    func testNoRouteOutIsItsOwnState() {
        let held = status()
        held.failed(.unreachable)

        XCTAssertEqual(held.readiness, .offline)
        XCTAssertTrue(held.readiness.detail.contains("no route out"))
    }

    func testTroubleAtTheProvidersEndDoesNotBlameThePhonesConnection() {
        let held = status()
        held.worked()
        held.failed(.refused("The provider is having trouble at its end."))

        // The key is fine and the phone has a route out. Calling it "no connection" would send the
        // owner to check their Wi-Fi over a fault at the provider's end.
        XCTAssertEqual(held.readiness, .reachable)
        XCTAssertEqual(held.lastProblem, "The provider is having trouble at its end.")
    }

    func testAnUnexplainedRefusalWithNoKeyStillCountsAsSetUp() {
        let held = status()
        held.failed(.refused("The provider refused it."))

        XCTAssertEqual(held.readiness, .configured)
    }

    func testAnEmptyAnswerMeansTheLaneWorksAndTheAnswerDidNot() {
        let held = status()
        held.failed(.emptyAnswer)

        // Saying the lane is down would send the owner to check a key that is fine.
        XCTAssertEqual(held.readiness, .reachable)
        XCTAssertNotNil(held.lastAnswer)
        XCTAssertNotNil(held.lastProblem)
    }

    func testAddingAKeyClearsAPreviousRefusal() {
        let held = status()
        held.failed(.refused("The provider didn't accept this phone's key. Check it in Settings."))
        held.configured(true)

        // They have just changed something. Keeping "key refused" would make a fixed lane look
        // broken.
        XCTAssertEqual(held.readiness, .configured)
        XCTAssertNil(held.lastProblem)
    }

    func testRemovingTheKeyGoesBackToNotConfigured() {
        let held = status()
        held.worked()
        held.configured(false)

        XCTAssertEqual(held.readiness, .notConfigured)
    }

    func testAnAnswerDoesNotStopBeingWorkingBecauseAKeyWasSavedAgain() {
        let held = status()
        held.worked()
        held.configured(true)

        XCTAssertEqual(held.readiness, .reachable)
    }

    func testARequestRunningOutOfTimeIsCountedAndDoesNotRelabelTheLane() {
        let held = status()
        held.worked()
        held.ranOut()

        // A slow model is a slow model. One slow question must not make a working lane look down.
        XCTAssertEqual(held.readiness, .reachable)
        XCTAssertEqual(held.timedOut, 1)
        XCTAssertTrue(held.lastProblem?.contains("25 seconds") ?? false)
    }

    func testTheOwnerStoppingItIsNotAFailure() {
        let held = status()
        held.worked()
        held.stopped()

        XCTAssertEqual(held.readiness, .reachable)
        XCTAssertEqual(held.cancelled, 1)
        XCTAssertNil(held.lastProblem)
    }

    func testEveryStateHasWordsTheOwnerCanActOn() {
        for readiness in [CloudReadiness.notConfigured, .configured, .reachable,
                          .rateLimited, .authenticationFailed, .offline] {
            XCTAssertFalse(readiness.title.isEmpty)
            XCTAssertGreaterThan(readiness.detail.count, 25, "\(readiness) needs a usable sentence")
        }
    }

    func testForgettingEverythingLeavesNothingBehind() {
        let held = status()
        held.worked()
        held.ranOut()
        held.forget()

        XCTAssertEqual(held.readiness, .notConfigured)
        XCTAssertEqual(held.answered, 0)
        XCTAssertEqual(held.timedOut, 0)
        XCTAssertNil(held.lastAttempt)
    }

    func testSentinel() { XCTAssertTrue(true) }
}

/// Why a rung of the voice ladder is or is not available - priority §9C.
@MainActor
final class VoiceDiagnosisTests: XCTestCase {
    private func diagnosis(
        model: Bool = false,
        config: Bool = false,
        checksum: Bool = false,
        runtime: Bool = false,
        cached: Int = 0,
        route: VoiceRoute = .text(""),
        systemVoice: Bool = false
    ) -> VoiceDiagnosis {
        VoiceDiagnosis(
            modelPresent: model, configPresent: config, checksumValid: checksum,
            runtimeAvailable: runtime, cachedPhrases: cached, cachedBytes: cached * 4096,
            lastRendered: nil, systemVoiceAllowed: systemVoice, route: route)
    }

    func testAMissingModelIsDistinguishedFromAMissingRuntime() {
        XCTAssertTrue(diagnosis().ownVoiceBlocker?.contains("hasn't reached") ?? false)

        let complete = diagnosis(model: true, config: true, checksum: true)

        // The distinction the owner's question actually needs: not "it doesn't work" but which
        // link in the chain is missing.
        XCTAssertTrue(complete.ownVoiceBlocker?.contains("can run it") ?? false)
    }

    func testAModelWithoutItsConfigurationSaysSo() {
        XCTAssertTrue(diagnosis(model: true).ownVoiceBlocker?.contains("configuration") ?? false)
    }

    func testAModelThatDoesNotMatchItsChecksumSaysSo() {
        let held = diagnosis(model: true, config: true, checksum: false)

        XCTAssertTrue(held.ownVoiceBlocker?.contains("checksum") ?? false)
    }

    func testEverythingPresentHasNoBlocker() {
        XCTAssertNil(diagnosis(model: true, config: true, checksum: true, runtime: true).ownVoiceBlocker)
    }

    func testEveryRungSaysWhetherItIsAvailableAndWhyNot() {
        for rung in diagnosis().rungs {
            XCTAssertFalse(rung.rung.isEmpty)
            XCTAssertGreaterThan(rung.because.count, 10, "\(rung.rung) needs a reason")
        }
    }

    func testWordsOnScreenIsAlwaysAvailable() {
        // The bottom of the ladder. If this were ever unavailable JARVIS would have nothing at all.
        let last = diagnosis().rungs.last

        XCTAssertEqual(last?.rung, "Words on screen")
        XCTAssertTrue(last?.available ?? false)
    }

    func testTheCachedRungCountsWhatIsActuallyThere() {
        let held = diagnosis(cached: 12)
        let cached = held.rungs.first

        XCTAssertTrue(cached?.available ?? false)
        XCTAssertTrue(cached?.because.contains("12 phrases") ?? false)
    }

    func testTheSummarySaysWhatWillHappenNext() {
        XCTAssertTrue(diagnosis(route: .text("yes")).summary.contains("show the words"))
        XCTAssertTrue(diagnosis(route: .fromThePC).summary.contains("ask your PC"))
        XCTAssertTrue(diagnosis(route: .cached("yes")).summary.contains("already have"))
        XCTAssertTrue(diagnosis(route: .systemVoice).summary.contains("this phone's voice"))
    }

    func testTheSystemVoiceRungSaysWhyItIsOff() {
        let off = diagnosis().rungs.first { $0.rung.contains("own voice") && $0.rung.contains("phone") }

        XCTAssertFalse(off?.available ?? true)
        XCTAssertTrue(off?.because.contains("isn't mine") ?? false)
    }

    func testSentinel() { XCTAssertTrue(true) }
}

/// What of JARVIS's own voice has reached the phone - priority §9C.
///
/// The store reports disk state and never downloads, so every test here is about whether it tells
/// the truth about what is there rather than about a transfer.
@MainActor
final class VoiceModelStoreTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        super.setUp()
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    private func write(_ name: String, _ body: String) {
        try? Data(body.utf8).write(to: folder.appendingPathComponent(name))
    }

    func testAnEmptyFolderSaysNothingHasBeenAskedFor() {
        let store = VoiceModelStore(folder: folder)

        XCTAssertFalse(store.modelPresent)
        XCTAssertFalse(store.configPresent)
        XCTAssertEqual(store.bytes, 0)

        // The honest answer, and the one the report needs: not "transfer failed" but "no transfer
        // has ever been attempted, and here is why it is not attempted yet".
        XCTAssertTrue(store.blocker.contains("never been asked for"))
        XCTAssertTrue(store.blocker.contains("could run the model"))
    }

    func testAModelWithoutItsConfigurationIsReportedAsExactlyThat() {
        write("jarvis.onnx", "bytes")
        let store = VoiceModelStore(folder: folder)

        XCTAssertTrue(store.modelPresent)
        XCTAssertFalse(store.configPresent)
        XCTAssertEqual(store.blocker, "The model is here; its configuration is not.")
    }

    func testAChecksumIsNotValidWhenThereIsNothingToCheck() {
        let store = VoiceModelStore(folder: folder)
        store.expects("abc")

        // "The checksum is fine" about a file that does not exist is the kind of true-but-useless
        // answer that makes a diagnostic worthless.
        XCTAssertFalse(store.checksumValid)
    }

    func testAMatchingChecksumIsAcceptedAndAWrongOneIsNot() {
        write("jarvis.onnx", "bytes")
        write("jarvis.onnx.json", "{}")

        let store = VoiceModelStore(folder: folder)

        store.expects("277089d91c0bdf4f2e6862ba7e4a07605119431f5d13f726dd352b06f1b206a9")
        XCTAssertTrue(store.checksumValid)

        // Complete and verified, and still not speakable - which is the whole point of the
        // diagnostic saying where the chain stops rather than whether it works.
        XCTAssertTrue(store.blocker.contains("No runtime in this app"))

        store.expects("277089d91c0bdf4f2e6862ba7e4a07605119431f5d13f726dd352b06f1b206aa")
        XCTAssertFalse(store.checksumValid, "a wrong checksum must not pass")
        XCTAssertTrue(store.blocker.contains("does not match"))
    }

    func testTheChecksumIsCaseInsensitive() {
        write("jarvis.onnx", "bytes")
        write("jarvis.onnx.json", "{}")

        let store = VoiceModelStore(folder: folder)
        store.expects("277089D91C0BDF4F2E6862BA7E4A07605119431F5D13F726DD352B06F1B206A9")

        // The PC writes lowercase hex and nothing promises it always will. A transfer that was
        // bit-for-bit correct must not be reported as corrupt over letter case.
        XCTAssertTrue(store.checksumValid)
    }

    func testAnEmptyChecksumIsTheSameAsNone() {
        let store = VoiceModelStore(folder: folder)
        store.expects("")

        XCTAssertNil(store.expected)
    }

    func testTheSizeOfWhatArrivedIsReported() {
        write("jarvis.onnx", "0123456789")

        XCTAssertEqual(VoiceModelStore(folder: folder).bytes, 10)
    }

    func testSentinel() { XCTAssertTrue(true) }
}

/// Every permission JARVIS uses, read from iOS - priority §20.
///
/// Nothing here asserts what iOS says on the machine running the test, because that would be a
/// test of the simulator. What is asserted is the mapping: that each iOS answer becomes the right
/// owner-facing state, and that the distinctions the brief asked for survive.
@MainActor
final class PermissionCentreTests: XCTestCase {
    private func all(
        location: CLAuthorizationStatus = .notDetermined,
        notifications: UNAuthorizationStatus = .notDetermined,
        localNetwork: Bool? = nil,
        cloud: CloudReadiness = .notConfigured,
        microphone: Bool = false
    ) -> [OwnerPermission] {
        PermissionCentre.all(
            location: location, notifications: notifications, localNetwork: localNetwork,
            cloud: cloud, microphone: microphone)
    }

    func testEveryPermissionSaysWhatItIsForAndWhatIsLostWithoutIt() {
        for permission in all() {
            XCTAssertFalse(permission.title.isEmpty)
            XCTAssertGreaterThan(permission.why.count, 40, "\(permission.id) needs a real reason")
            XCTAssertFalse(permission.said.isEmpty)
        }
    }

    func testBackgroundLocationIsItsOwnRow() {
        let granted = all(location: .authorizedWhenInUse)
        let foreground = granted.first { $0.id == "location" }
        let background = granted.first { $0.id == "background-location" }

        // The distinction a single "location" row would hide: while-in-use is granted, and
        // arrivals while the app is closed still will not be noticed.
        XCTAssertTrue(foreground?.state.allowed ?? false)
        XCTAssertFalse(background?.state.allowed ?? true)
        XCTAssertTrue(background?.said.contains("miss arrivals") ?? false)
    }

    func testAlwaysLocationGrantsBoth() {
        let granted = all(location: .authorizedAlways)

        XCTAssertTrue(granted.first { $0.id == "location" }?.state.allowed ?? false)
        XCTAssertTrue(granted.first { $0.id == "background-location" }?.state.allowed ?? false)
    }

    func testARefusalSendsTheOwnerToSettingsAndAnUnaskedPermissionDoesNot() {
        let refused = all(location: .denied).first { $0.id == "location" }
        let unasked = all(location: .notDetermined).first { $0.id == "location" }

        // iOS only ever asks once. After a refusal the app's own button can do nothing, and
        // showing one that silently fails is worse than saying where to go.
        XCTAssertTrue(refused?.needsSettings ?? false)
        XCTAssertFalse(unasked?.needsSettings ?? true)
    }

    func testProvisionalNotificationsCountAsAllowedAndSayHow() {
        let quiet = all(notifications: .provisional).first { $0.id == "notifications" }

        XCTAssertTrue(quiet?.state.allowed ?? false)
        XCTAssertEqual(quiet?.said, "Quietly, until you decide")
    }

    func testLocalNetworkHasThreeAnswersAndNotTwo() {
        XCTAssertEqual(all(localNetwork: nil).first { $0.id == "local-network" }?.state, .notAsked)
        XCTAssertEqual(all(localNetwork: true).first { $0.id == "local-network" }?.state, .allowed("Allowed"))
        XCTAssertEqual(all(localNetwork: false).first { $0.id == "local-network" }?.state, .refused)
    }

    func testARefusedCloudKeyReadsAsRefusedAndAnAbsentOneAsUnasked() {
        XCTAssertEqual(all(cloud: .notConfigured).first { $0.id == "cloud" }?.state, .notAsked)
        XCTAssertEqual(all(cloud: .authenticationFailed).first { $0.id == "cloud" }?.state, .refused)
        XCTAssertTrue(all(cloud: .reachable).first { $0.id == "cloud" }?.state.allowed ?? false)
    }

    func testNoPermissionPromisesBackgroundListening() {
        let microphone = all().first { $0.id == "microphone" }

        // Said explicitly, because it is the thing an owner reasonably fears about a voice app.
        XCTAssertTrue(microphone?.why.contains("do not listen in the background") ?? false)
    }

    func testTheSummaryCountsWhatNeedsSettingsSeparately() {
        let mixed = all(location: .denied, notifications: .authorized)
        let summary = PermissionCentre.summary(mixed)

        XCTAssertTrue(summary.contains("of \(mixed.count) allowed"))
        XCTAssertTrue(summary.contains("needing iOS Settings"))
    }

    func testTheSummaryIsQuietWhenNothingNeedsSettings() {
        let summary = PermissionCentre.summary(all(notifications: .authorized))

        XCTAssertFalse(summary.contains("needing iOS Settings"))
    }

    func testEveryPermissionHasADistinctIdentity() {
        let ids = all().map(\.id)

        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testSentinel() { XCTAssertTrue(true) }
}
