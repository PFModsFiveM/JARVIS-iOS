import Foundation

/// What is in the store about one incident, and what is not yet.
///
/// The PC's `FootageInStore`, field for field, including its own sentence about what can honestly be
/// shown. The sentence is computed here rather than sent, so a phone and a PC of different versions
/// cannot disagree about what "ready" means by one of them having an older string.
struct StoredIncident: Codable, Equatable, Identifiable {
    let id: String
    let device: String
    let startedAt: Date
    let endedAt: Date?
    let what: String
    let photos: Int
    let thumbnail: Bool
    let clipParts: Int
    let clipPartsStored: Int
    let clipBytes: Int64
    let updatedAt: Date

    /// Whether the whole recording can be watched from here.
    var clipComplete: Bool { clipParts > 0 && clipPartsStored >= clipParts }

    /// How long the incident lasted, as far as this record knows.
    var lasted: TimeInterval { (endedAt ?? startedAt).timeIntervalSince(startedAt) }

    /// Whether it happened recently enough to want looking at now.
    var isRecent: Bool { startedAt > Date.now.addingTimeInterval(-86_400) }

    /// What may honestly be said about what is available. Never a play button for half a video.
    var availability: String {
        guard clipParts > 0 else {
            return thumbnail ? "A still and the details. No recording was kept." : "The details only. No recording was kept."
        }

        if clipComplete { return "Ready to watch." }

        if clipPartsStored == 0 {
            return thumbnail
                ? "A still and the details. The recording hasn't been uploaded yet (\(size))."
                : "The details only. The recording hasn't been uploaded yet (\(size))."
        }

        return "Still uploading - \(clipPartsStored) of \(clipParts) parts."
    }

    /// The recording's size, as somebody on mobile data would want it said.
    var size: String {
        switch clipBytes {
        case ..<1: return "nothing"
        case ..<1024: return "\(clipBytes) B"
        case ..<(1024 * 1024): return String(format: "%.1f KB", Double(clipBytes) / 1024)
        default: return String(format: "%.1f MB", Double(clipBytes) / (1024 * 1024))
        }
    }

    /// How it reads in a list.
    var summary: String {
        var parts = [what]

        if lasted > 1 { parts.append("\(Int(lasted))s") }
        if photos > 0 { parts.append("\(photos) photo\(photos == 1 ? "" : "s")") }

        return parts.joined(separator: " · ")
    }
}

/// Reading what the camera kept, from the store, without the PC.
///
/// The one thing on this phone that does not go through the bridge, and the reason it exists: with
/// the PC off there is nothing to ask. There is no live view either and there never can be - the
/// camera is plugged into the PC - so what this reads is what was already recorded.
///
/// Needs three things and says which is missing when it cannot work: the bucket's coordinates and
/// the sealing key, both from the PC over the bridge, and a bucket credential the owner entered on
/// this phone.
struct CloudFootage {
    /// Where footage lives. The same prefix the PC writes.
    static let prefix = "footage/"

    let coordinates: StoreCoordinates
    let credentials: StoreCredentials
    let vault: CloudVault

    /// Everything a test needs to pin.
    struct Wiring {
        var now: () -> Date = { Date() }
        var send: (URLRequest) async throws -> (Data, URLResponse)

        static let live = Wiring { request in
            let session = URLSession(configuration: .ephemeral)
            return try await session.data(for: request)
        }
    }

    var wiring: Wiring = .live

    /// The index entries, as the PC's FootageSync writes them.
    ///
    /// PascalCase, because that serialiser uses System.Text.Json's plain defaults - unlike the
    /// bridge, which uses its Web defaults and so sends camelCase. Two serialisers with two
    /// conventions, and this is the one that reads the store rather than the bridge.
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromPascalCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)

            guard let date = SmartDevice.date(text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a date"))
            }

            return date
        }
        return decoder
    }()

    /// Where one incident's index entry lives.
    func indexKey(_ id: String) -> String { "\(Self.prefix)\(coordinates.device)/index/\(id).json" }

    /// Where one incident's still lives.
    func thumbnailKey(_ id: String) -> String { "\(Self.prefix)\(coordinates.device)/clips/\(id)/thumb" }

    /// Where one part of one incident's recording lives.
    func partKey(_ id: String, _ part: Int) -> String {
        "\(Self.prefix)\(coordinates.device)/clips/\(id)/\(String(format: "%04d", part))"
    }

    /// Every incident in the store for that PC, newest first.
    ///
    /// One listing of the index folder and one read per entry. The clip parts live in a different
    /// folder on purpose: a list must not have to page through every part of every recording.
    func list() async -> [StoredIncident] {
        let keys = await listKeys(prefix: "\(Self.prefix)\(coordinates.device)/index/")

        var found: [StoredIncident] = []

        for key in keys {
            guard let sealed = await get(key), let plain = vault.open(sealed) else { continue }

            // Something in the bucket that is not ours, or an entry from a newer JARVIS. Skipped,
            // not fatal: the rest of the list is still worth showing.
            guard let incident = try? Self.decoder.decode(StoredIncident.self, from: plain) else { continue }

            found.append(incident)
        }

        return found.sorted { $0.startedAt > $1.startedAt }
    }

    /// One incident's still, or nil when there is not one.
    func thumbnail(_ id: String) async -> Data? {
        guard let sealed = await get(thumbnailKey(id)) else { return nil }
        return vault.open(sealed)
    }

    /// The whole recording for one incident, or nil when it is not all there.
    ///
    /// Nil rather than a partial file. Half a video is not a shorter video - the container's index
    /// is at the end - so handing back what arrived would produce something that will not play and
    /// would look like a broken camera rather than an upload still in progress.
    func clip(_ incident: StoredIncident, progress: ((Int, Int) -> Void)? = nil) async -> Data? {
        guard incident.clipComplete else { return nil }

        var whole = Data()

        for part in 0..<incident.clipParts {
            guard let sealed = await get(partKey(incident.id, part)),
                  let plain = vault.open(sealed)
            else { return nil }

            whole.append(plain)
            progress?(part + 1, incident.clipParts)
        }

        return whole
    }

    // ------------------------------------------------------------------ the store itself

    /// One signed GET. Nil for anything that is not there or did not answer.
    private func get(_ key: String) async -> Data? {
        guard let (data, response) = await send(method: "GET", path: "/\(SignedRequest.encodeKey(key))", query: "") else {
            return nil
        }

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }

        return data
    }

    /// The keys under a prefix. One page; a thousand is the store's own maximum and far more
    /// incidents than a day produces.
    private func listKeys(prefix: String) async -> [String] {
        let query = "list-type=2&prefix=\(encodeQuery(prefix))"

        guard let (data, response) = await send(method: "GET", path: "/", query: query),
              let http = response as? HTTPURLResponse, http.statusCode == 200
        else { return [] }

        return Self.keys(in: data)
    }

    /// The keys out of a ListObjectsV2 body.
    ///
    /// Read with a scanner rather than an XML parser: the shape needed is one repeated element and
    /// adding an XML dependency to read it would be the larger risk. Anything unexpected yields no
    /// keys, which shows as an empty list rather than as a crash.
    static func keys(in xml: Data) -> [String] {
        guard let text = String(data: xml, encoding: .utf8) else { return [] }

        var keys: [String] = []
        var rest = Substring(text)

        while let open = rest.range(of: "<Key>"), let close = rest.range(of: "</Key>", range: open.upperBound..<rest.endIndex) {
            let key = rest[open.upperBound..<close.lowerBound]

            if !key.isEmpty { keys.append(unescape(String(key))) }

            rest = rest[close.upperBound...]
        }

        return keys
    }

    /// The five entities an S3 listing can escape a key with.
    private static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
    }

    private func send(method: String, path: String, query: String) async -> (Data, URLResponse)? {
        let host = coordinates.host
        let bucketPath = "/\(SignedRequest.encodeKey(coordinates.bucket))\(path)"

        guard var components = URLComponents(string: "https://\(host)\(bucketPath)") else { return nil }

        components.percentEncodedQuery = query.isEmpty ? nil : query

        guard let url = components.url else { return nil }

        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = method

        var signing = credentials
        signing.region = coordinates.region

        for (header, value) in SignedRequest.headers(
            method: method,
            host: host,
            path: bucketPath,
            query: query,
            payload: Data(),
            credentials: signing,
            at: wiring.now()
        ) {
            request.setValue(value, forHTTPHeaderField: header)
        }

        do {
            return try await wiring.send(request)
        } catch {
            // No network, a refused connection, a timeout. Nil, and the model above says the store
            // could not be reached rather than that there are no incidents.
            return nil
        }
    }

    /// A value inside a query string, encoded the way the signature expects.
    private func encodeQuery(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: SignedRequest.unreserved) ?? value
    }
}

extension JSONDecoder.KeyDecodingStrategy {
    /// The PC writes PascalCase through System.Text.Json's default; Swift wants camelCase.
    static let convertFromPascalCase = JSONDecoder.KeyDecodingStrategy.custom { path in
        guard let key = path.last else { return StoreKey(stringValue: "") }

        let name = key.stringValue

        guard let first = name.first, first.isUppercase else { return key }

        return StoreKey(stringValue: first.lowercased() + name.dropFirst())
    }
}

/// A coding key built from a string, for the PascalCase conversion above.
fileprivate struct StoreKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(stringValue: String) { self.stringValue = stringValue }

    init?(intValue: Int) { return nil }
}
