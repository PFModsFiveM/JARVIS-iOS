import CryptoKit
import Foundation

/// What a request to the store needs to be signed: who is asking, and where.
///
/// Kept in the Keychain, device-only and never synchronised. `description` prints nothing, so a
/// credential cannot reach a log through interpolation.
///
/// **Entered on this phone, not sent by the PC.** The bridge hands over the bucket's coordinates and
/// the sealing key; it deliberately does not hand over a bucket credential, so the owner can give
/// this phone one scoped read-only to the footage prefix. A phone that is lost can then read what it
/// could already read, and cannot delete or overwrite the bucket.
struct StoreCredentials: Equatable, CustomStringConvertible {
    let accessKeyId: String
    let secretAccessKey: String
    var region: String = "auto"
    var service: String = "s3"

    var description: String { "StoreCredentials(***)" }

    var usable: Bool { !accessKeyId.isEmpty && !secretAccessKey.isEmpty }

    private static let account = "store-credentials"

    static func load() -> StoreCredentials? {
        guard let data = Keychain.read(account),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              !stored.accessKeyId.isEmpty, !stored.secretAccessKey.isEmpty
        else { return nil }

        return StoreCredentials(
            accessKeyId: stored.accessKeyId,
            secretAccessKey: stored.secretAccessKey,
            region: stored.region.isEmpty ? "auto" : stored.region)
    }

    func save() {
        let stored = Stored(accessKeyId: accessKeyId, secretAccessKey: secretAccessKey, region: region)
        if let data = try? JSONEncoder().encode(stored) { Keychain.write(Self.account, data) }
    }

    static func forget() { Keychain.delete(account) }

    private struct Stored: Codable {
        let accessKeyId: String
        let secretAccessKey: String
        let region: String
    }
}

/// Signature Version 4, which is how an S3-compatible store knows a request is from its owner.
///
/// The same function as the PC's `SignedRequest`, written out for the same reason: what is needed is
/// four hashes and a string in a documented order, and having it in the open means the one thing
/// that matters - that the secret derives a key and is never sent - can be read rather than trusted.
///
/// The secret appears in exactly one place, `signingKey`, and leaves as a signature.
enum SignedRequest {
    static let algorithm = "AWS4-HMAC-SHA256"

    /// The hash of an empty body, which a GET sends.
    static var emptyPayload: String { hex(Data(SHA256.hash(data: Data()))) }

    /// Signs a request, returning the headers to send with it.
    ///
    /// - Parameters:
    ///   - path: the absolute path, already encoded, beginning with a slash.
    ///   - query: the canonical query string, or empty. Sorted by name, encoded.
    ///   - at: the moment of the request. The store refuses one whose clock is far out.
    static func headers(
        method: String,
        host: String,
        path: String,
        query: String,
        payload: Data,
        credentials: StoreCredentials,
        at: Date
    ) -> [String: String] {
        let stamp = stamp(at)
        let day = String(stamp.prefix(8))
        let payloadHash = hex(Data(SHA256.hash(data: payload)))

        // Three headers, in the order a signature requires: lower case, sorted by name.
        let canonicalHeaders = "host:\(host)\nx-amz-content-sha256:\(payloadHash)\nx-amz-date:\(stamp)\n"
        let signedHeaders = "host;x-amz-content-sha256;x-amz-date"

        let canonicalRequest = [method, path, query, canonicalHeaders, signedHeaders, payloadHash]
            .joined(separator: "\n")

        let scope = "\(day)/\(credentials.region)/\(credentials.service)/aws4_request"

        let toSign = [
            algorithm,
            stamp,
            scope,
            hex(Data(SHA256.hash(data: Data(canonicalRequest.utf8))))
        ].joined(separator: "\n")

        let signature = hex(hmac(key: signingKey(credentials, day: day), message: toSign))

        return [
            "x-amz-date": stamp,
            "x-amz-content-sha256": payloadHash,
            "Authorization":
                "\(algorithm) Credential=\(credentials.accessKeyId)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
        ]
    }

    /// The key the signature is made with: the secret walked through the date, the region and the
    /// service, so a signature is only good for one day, one region and one service.
    ///
    /// The only place the secret is used. What goes over the wire is a hash made with it.
    static func signingKey(_ credentials: StoreCredentials, day: String) -> Data {
        let start = hmac(key: Data("AWS4\(credentials.secretAccessKey)".utf8), message: day)
        let region = hmac(key: start, message: credentials.region)
        let service = hmac(key: region, message: credentials.service)

        return hmac(key: service, message: "aws4_request")
    }

    /// The timestamp form a signature uses: yyyyMMdd'T'HHmmss'Z', always UTC.
    ///
    /// Built by hand rather than with a locale-sensitive formatter: a phone set to a non-Gregorian
    /// calendar would otherwise produce a stamp the store rejects, and the failure would look like
    /// a wrong key.
    static func stamp(_ at: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: at)

        return String(
            format: "%04d%02d%02dT%02d%02d%02dZ",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
            parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }

    /// A key as it appears in a path. The slashes stay; everything else is encoded.
    static func encodeKey(_ key: String) -> String {
        key.split(separator: "/", omittingEmptySubsequences: false)
            .map { part in
                String(part).addingPercentEncoding(withAllowedCharacters: unreserved) ?? String(part)
            }
            .joined(separator: "/")
    }

    /// What a signature leaves unencoded, which is narrower than iOS's own URL character sets.
    static let unreserved: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    static func hmac(key: Data, message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)))
    }

    /// Lower-case hexadecimal, which is the only form a signature is accepted in.
    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
