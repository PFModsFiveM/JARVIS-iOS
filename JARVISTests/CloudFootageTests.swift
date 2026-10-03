import CryptoKit
import XCTest
@testable import JARVIS

/// Signing a request to the store.
///
/// The vector is worked out from the documented rule rather than from this implementation, which is
/// the only kind of check that catches a signing bug.
final class StoreSigningTests: XCTestCase {
    private let credentials = StoreCredentials(
        accessKeyId: "NotARealKey-id",
        secretAccessKey: "NotARealKey-secret",
        region: "auto")

    func testTheStampIsTheFormASignatureNeedsAndAlwaysUtc() {
        // Built by hand rather than with a locale-sensitive formatter: a phone on a non-Gregorian
        // calendar would otherwise produce a stamp the store rejects, looking like a wrong key.
        let at = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertEqual(SignedRequest.stamp(at), "20231114T221320Z")
    }

    func testTheSigningKeyIsWalkedThroughDateRegionAndService() {
        // Four nested HMACs in a documented order. A signature is only good for one day, one
        // region and one service because of this, which is why the order is pinned.
        let day = "20231114"

        let start = SignedRequest.hmac(key: Data("AWS4NotARealKey-secret".utf8), message: day)
        let region = SignedRequest.hmac(key: start, message: "auto")
        let service = SignedRequest.hmac(key: region, message: "s3")
        let expected = SignedRequest.hmac(key: service, message: "aws4_request")

        XCTAssertEqual(SignedRequest.signingKey(credentials, day: day), expected)
        XCTAssertEqual(expected.count, 32)
    }

    func testTheThreeHeadersAreSentAndTheSecretIsNot() {
        let headers = SignedRequest.headers(
            method: "GET",
            host: "abc.r2.cloudflarestorage.com",
            path: "/jarvis/footage/DOM-PC/index/evt-1.json",
            query: "",
            payload: Data(),
            credentials: credentials,
            at: Date(timeIntervalSince1970: 1_700_000_000))

        XCTAssertEqual(headers["x-amz-date"], "20231114T221320Z")
        XCTAssertEqual(headers["x-amz-content-sha256"], SignedRequest.emptyPayload)
        XCTAssertTrue(headers["Authorization"]?.hasPrefix("AWS4-HMAC-SHA256 Credential=NotARealKey-id/20231114/auto/s3/aws4_request") == true)

        // The id is public by design; the secret derives a key and never travels.
        XCTAssertFalse(headers.values.contains { $0.contains("NotARealKey-secret") })
    }

    func testTheSignatureChangesWithThePathSoOneCannotBeReusedForAnother() {
        func sign(_ path: String) -> String? {
            SignedRequest.headers(
                method: "GET", host: "h", path: path, query: "", payload: Data(),
                credentials: credentials, at: Date(timeIntervalSince1970: 1_700_000_000))["Authorization"]
        }

        XCTAssertNotEqual(sign("/a"), sign("/b"))
    }

    func testAKeyKeepsItsSlashesAndEncodesEverythingElse() {
        XCTAssertEqual(SignedRequest.encodeKey("footage/DOM-PC/index/evt-1.json"), "footage/DOM-PC/index/evt-1.json")
        XCTAssertEqual(SignedRequest.encodeKey("a b/c"), "a%20b/c")
    }

    func testACredentialIsNeverInAnythingPrintable() {
        XCTAssertFalse("\(credentials)".contains("NotARealKey"))
    }
}

/// Opening what the PC sealed.
final class CloudVaultTests: XCTestCase {
    /// The PC's format: "JV1", a twelve-byte nonce, the ciphertext, then the sixteen-byte tag.
    private func seal(_ plain: Data, with key: SymmetricKey) throws -> Data {
        let nonce = AES.GCM.Nonce()
        let box = try AES.GCM.seal(plain, using: key, nonce: nonce)

        var sealed = CloudVault.magic
        sealed.append(Data(nonce))
        sealed.append(box.ciphertext)
        sealed.append(box.tag)

        return sealed
    }

    private var key: SymmetricKey { SymmetricKey(data: Data(repeating: 7, count: 32)) }

    private var written: String { Data(repeating: 7, count: 32).base64EncodedString() }

    func testWhatThePcSealedIsOpenedByteForByte() {
        let vault = CloudVault(written: written)
        let plain = Data("an incident the camera recorded".utf8)

        XCTAssertEqual(vault?.open(try! seal(plain, with: key)), plain)
    }

    func testAnObjectSealedByAnotherJarvisReadsAsNothing() {
        let other = SymmetricKey(data: Data(repeating: 9, count: 32))
        let vault = CloudVault(written: written)

        XCTAssertNil(vault?.open(try! seal(Data("private".utf8), with: other)))
    }

    func testSomethingThatIsNotOursIsRecognisedRatherThanMangled() {
        let vault = CloudVault(written: written)

        XCTAssertNil(vault?.open(Data("a file somebody put in the bucket".utf8)))
        XCTAssertNil(vault?.open(Data()))
        XCTAssertNil(vault?.open(CloudVault.magic))
    }

    func testATamperedObjectIsRefusedBecauseThisIsAuthenticatedNotJustEncrypted() {
        // Without the tag, whoever holds the bucket could change what JARVIS believes.
        var sealed = try! seal(Data("the owner was at the desk".utf8), with: key)
        sealed[sealed.count - 1] ^= 0xFF

        XCTAssertNil(CloudVault(written: written)?.open(sealed))
    }

    func testAnythingThatIsNotAKeyIsRefusedRatherThanStored() {
        XCTAssertNil(CloudVault(written: "not base64 at all !!"))
        XCTAssertNil(CloudVault(written: Data(repeating: 1, count: 16).base64EncodedString()))
        XCTAssertNil(CloudVault(written: ""))
    }

    func testTheKeyIsNeverInAnythingPrintable() {
        XCTAssertEqual(CloudVault(written: written)?.description, "CloudVault(***)")
    }
}

/// Reading the store: the listing, the index entries, and what is refused.
final class CloudFootageTests: XCTestCase {
    private var vault: CloudVault { CloudVault(written: Data(repeating: 7, count: 32).base64EncodedString())! }

    private var key: SymmetricKey { SymmetricKey(data: Data(repeating: 7, count: 32)) }

    private var coordinates: StoreCoordinates {
        StoreCoordinates([
            "host": "abc.r2.cloudflarestorage.com", "bucket": "jarvis", "region": "auto", "device": "DOM-PC"
        ])!
    }

    private func seal(_ plain: Data) throws -> Data {
        let nonce = AES.GCM.Nonce()
        let box = try AES.GCM.seal(plain, using: key, nonce: nonce)

        var sealed = CloudVault.magic
        sealed.append(Data(nonce))
        sealed.append(box.ciphertext)
        sealed.append(box.tag)

        return sealed
    }

    /// An index entry exactly as the PC's FootageSync writes it: PascalCase, .NET dates.
    private func entry(
        id: String = "evt-1",
        parts: Int = 2,
        stored: Int = 2,
        thumbnail: Bool = true,
        bytes: Int = 3_000_000,
        at: String = "2026-10-02T23:40:00.0000000+00:00"
    ) -> Data {
        Data("""
        {"Id":"\(id)","Device":"DOM-PC","StartedAt":"\(at)","EndedAt":"2026-10-02T23:40:12.0000000+00:00",\
        "What":"An unrecognised person","Photos":3,"Thumbnail":\(thumbnail),"ClipParts":\(parts),\
        "ClipPartsStored":\(stored),"ClipBytes":\(bytes),"UpdatedAt":"\(at)"}
        """.utf8)
    }

    private func store(_ objects: [String: Data], seen: ((URLRequest) -> Void)? = nil) -> CloudFootage {
        var wiring = CloudFootage.Wiring { request in
            seen?(request)

            let url = request.url!.absoluteString
            let ok = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let missing = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!

            // A listing: everything under the prefix, as ListObjectsV2 answers it.
            if url.contains("list-type=2") {
                let keys = objects.keys.sorted().map { "<Contents><Key>\($0)</Key></Contents>" }.joined()
                return (Data("<ListBucketResult>\(keys)</ListBucketResult>".utf8), ok)
            }

            // An object, addressed by its key under the bucket.
            for (key, bytes) in objects where url.hasSuffix("/jarvis/\(SignedRequest.encodeKey(key))") {
                return (bytes, ok)
            }

            return (Data(), missing)
        }
        wiring.now = { Date(timeIntervalSince1970: 1_700_000_000) }

        return CloudFootage(
            coordinates: coordinates,
            credentials: StoreCredentials(accessKeyId: "NotARealKey-id", secretAccessKey: "NotARealKey-secret"),
            vault: vault,
            wiring: wiring)
    }

    func testTheKeysAreTheSameOnesThePcWrites() {
        // If these drift, the phone reads nothing and nothing says why.
        let reader = store([:])

        XCTAssertEqual(reader.indexKey("evt-1"), "footage/DOM-PC/index/evt-1.json")
        XCTAssertEqual(reader.thumbnailKey("evt-1"), "footage/DOM-PC/clips/evt-1/thumb")
        XCTAssertEqual(reader.partKey("evt-1", 0), "footage/DOM-PC/clips/evt-1/0000")
        XCTAssertEqual(reader.partKey("evt-1", 11), "footage/DOM-PC/clips/evt-1/0011")
    }

    func testAnIncidentIsReadWithItsDetailsIntact() async throws {
        let reader = store(["footage/DOM-PC/index/evt-1.json": try seal(entry())])

        let found = await reader.list()

        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].id, "evt-1")
        XCTAssertEqual(found[0].what, "An unrecognised person")
        XCTAssertEqual(found[0].photos, 3)
        XCTAssertEqual(found[0].clipBytes, 3_000_000)
        XCTAssertTrue(found[0].clipComplete)
        XCTAssertEqual(found[0].availability, "Ready to watch.")
    }

    func testTheListIsNewestFirst() async throws {
        let reader = store([
            "footage/DOM-PC/index/old.json": try seal(entry(id: "old", at: "2026-10-02T20:00:00.0000000+00:00")),
            "footage/DOM-PC/index/new.json": try seal(entry(id: "new", at: "2026-10-02T23:40:00.0000000+00:00"))
        ])

        let found = await reader.list()

        XCTAssertEqual(found.map(\.id), ["new", "old"])
    }

    func testOnlyTheIndexFolderIsListedSoAClipsPartsAreNotPagedThrough() async throws {
        var listed: [String] = []

        let reader = store(["footage/DOM-PC/index/evt-1.json": try seal(entry())]) { request in
            if let query = request.url?.query, query.contains("list-type=2") { listed.append(query) }
        }

        _ = await reader.list()

        XCTAssertEqual(listed.count, 1)
        XCTAssertTrue(listed[0].contains("footage%2FDOM-PC%2Findex%2F"))
    }

    func testSomethingInTheBucketThatIsNotOursIsSkippedRatherThanFatal() async throws {
        let reader = store([
            "footage/DOM-PC/index/evt-1.json": try seal(entry()),
            "footage/DOM-PC/index/somebody-elses.json": Data("a file somebody put here".utf8)
        ])

        let found = await reader.list()

        XCTAssertEqual(found.map(\.id), ["evt-1"])
    }

    func testAWholeRecordingComesBackByteForByte() async throws {
        let first = Data(repeating: 1, count: 1000)
        let second = Data(repeating: 2, count: 500)

        let reader = store([
            "footage/DOM-PC/index/evt-1.json": try seal(entry(parts: 2, stored: 2)),
            "footage/DOM-PC/clips/evt-1/0000": try seal(first),
            "footage/DOM-PC/clips/evt-1/0001": try seal(second)
        ])

        let incident = await reader.list()[0]
        let whole = await reader.clip(incident)

        XCTAssertEqual(whole, first + second)
    }

    func testHalfARecordingIsNeverOfferedAsARecording() async throws {
        // The container's index is at the end, so a partial file will not play and would look like
        // a broken camera rather than an upload still in progress.
        let reader = store([
            "footage/DOM-PC/index/evt-1.json": try seal(entry(parts: 4, stored: 1)),
            "footage/DOM-PC/clips/evt-1/0000": try seal(Data(repeating: 1, count: 10))
        ])

        let incident = await reader.list()[0]
        let whole = await reader.clip(incident)

        XCTAssertFalse(incident.clipComplete)
        XCTAssertEqual(incident.availability, "Still uploading - 1 of 4 parts.")
        XCTAssertNil(whole)
    }

    func testAPartMissingFromTheStoreRefusesRatherThanPatchingTheVideo() async throws {
        let reader = store([
            "footage/DOM-PC/index/evt-1.json": try seal(entry(parts: 2, stored: 2)),
            "footage/DOM-PC/clips/evt-1/0000": try seal(Data(repeating: 1, count: 10))
        ])

        let incident = await reader.list()[0]
        let whole = await reader.clip(incident)

        XCTAssertTrue(incident.clipComplete)
        XCTAssertNil(whole)
    }

    func testAStillComesBackWhenThereIsOne() async throws {
        let still = Data(repeating: 42, count: 2048)

        let reader = store([
            "footage/DOM-PC/index/evt-1.json": try seal(entry()),
            "footage/DOM-PC/clips/evt-1/thumb": try seal(still)
        ])

        let found = await reader.thumbnail("evt-1")
        let missing = await reader.thumbnail("evt-2")

        XCTAssertEqual(found, still)
        XCTAssertNil(missing)
    }

    func testEveryRequestIsSigned() async throws {
        var unsigned = 0

        let reader = store(["footage/DOM-PC/index/evt-1.json": try seal(entry())]) { request in
            if request.value(forHTTPHeaderField: "Authorization") == nil { unsigned += 1 }
        }

        _ = await reader.list()

        XCTAssertEqual(unsigned, 0)
    }

    func testAStoreThatCannotBeReachedReadsAsNothingRatherThanCrashing() async {
        var wiring = CloudFootage.Wiring { _ in throw URLError(.notConnectedToInternet) }
        wiring.now = { Date(timeIntervalSince1970: 1_700_000_000) }

        let reader = CloudFootage(
            coordinates: coordinates,
            credentials: StoreCredentials(accessKeyId: "NotARealKey-id", secretAccessKey: "NotARealKey-secret"),
            vault: vault,
            wiring: wiring)

        let found = await reader.list()

        XCTAssertTrue(found.isEmpty)
    }

    func testAListingThatIsNotWhatWeExpectYieldsNoKeysRatherThanCrashing() {
        XCTAssertTrue(CloudFootage.keys(in: Data("not xml".utf8)).isEmpty)
        XCTAssertTrue(CloudFootage.keys(in: Data()).isEmpty)
        XCTAssertTrue(CloudFootage.keys(in: Data("<Key>".utf8)).isEmpty)
    }

    func testAnEscapedKeyIsReadBackAsItself() {
        XCTAssertEqual(
            CloudFootage.keys(in: Data("<Key>footage/a&amp;b/0000</Key>".utf8)),
            ["footage/a&b/0000"])
    }
}

/// What the screen may honestly say about an incident.
final class StoredIncidentWordingTests: XCTestCase {
    private func incident(parts: Int, stored: Int, thumbnail: Bool, bytes: Int64 = 9_800_000) -> StoredIncident {
        let json = Data("""
        {"Id":"evt-1","Device":"DOM-PC","StartedAt":"2026-10-02T23:40:00.0000000+00:00",\
        "What":"An unrecognised person","Photos":0,"Thumbnail":\(thumbnail),"ClipParts":\(parts),\
        "ClipPartsStored":\(stored),"ClipBytes":\(bytes),"UpdatedAt":"2026-10-02T23:40:00.0000000+00:00"}
        """.utf8)

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromPascalCase
        decoder.dateDecodingStrategy = .custom { decoder in
            SmartDevice.date(try decoder.singleValueContainer().decode(String.self))!
        }

        return try! decoder.decode(StoredIncident.self, from: json)
    }

    func testNothingClaimsARecordingIsWatchableUntilItAllArrived() {
        XCTAssertEqual(incident(parts: 5, stored: 5, thumbnail: true).availability, "Ready to watch.")
        XCTAssertEqual(incident(parts: 5, stored: 2, thumbnail: true).availability, "Still uploading - 2 of 5 parts.")
    }

    func testNothingUploadedYetSaysWhatTheDownloadWillCost() {
        let waiting = incident(parts: 5, stored: 0, thumbnail: true)

        XCTAssertTrue(waiting.availability.contains("hasn't been uploaded yet"))
        XCTAssertTrue(waiting.availability.contains("9.3 MB"))
    }

    func testNoRecordingAtAllIsSaidAsThatRatherThanAsAFailure() {
        XCTAssertEqual(incident(parts: 0, stored: 0, thumbnail: true).availability, "A still and the details. No recording was kept.")
        XCTAssertEqual(incident(parts: 0, stored: 0, thumbnail: false).availability, "The details only. No recording was kept.")
    }

    func testSizeIsSaidTheWaySomebodyOnMobileDataWouldWantIt() {
        XCTAssertEqual(incident(parts: 1, stored: 0, thumbnail: false, bytes: 0).size, "nothing")
        XCTAssertEqual(incident(parts: 1, stored: 0, thumbnail: false, bytes: 900).size, "900 B")
        XCTAssertEqual(incident(parts: 1, stored: 0, thumbnail: false, bytes: 2048).size, "2.0 KB")
        XCTAssertEqual(incident(parts: 1, stored: 0, thumbnail: false, bytes: 3 * 1024 * 1024).size, "3.0 MB")
    }
}
