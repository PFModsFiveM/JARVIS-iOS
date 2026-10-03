import Foundation

/// What the camera kept, read from the shared store rather than from the PC.
///
/// **There is no live view with the PC off and there never can be.** The camera is a USB camera
/// plugged into the PC, so the host of the camera is the thing that is off. Nothing here offers one.
/// What it offers is what was already recorded, which the PC uploads while it is awake.
///
/// Three things have to be in place, and this says which is missing rather than showing an empty
/// list: the bucket's coordinates and the sealing key, both handed over by the PC after Face ID, and
/// a bucket credential the owner enters on this phone - preferably one scoped read-only, so a phone
/// that is lost can read what it could already read and cannot delete the bucket.
@MainActor
final class FootageModel: ObservableObject {
    static let shared = FootageModel()

    @Published private(set) var incidents: [StoredIncident] = []
    @Published private(set) var reading = false
    @Published private(set) var lastRead: Date?

    /// Where the store is, as the PC told this phone.
    @Published private(set) var coordinates: StoreCoordinates? = StoreCoordinates.load()

    /// The key that opens what is in it.
    @Published private(set) var vault: CloudVault? = CloudVault.load()

    /// The bucket credential, which this phone holds its own of.
    @Published private(set) var credentials: StoreCredentials? = StoreCredentials.load()

    /// Pinned by the tests; the live one talks to the store.
    var wiring: CloudFootage.Wiring = .live

    private let model: AppModel

    init(model: AppModel = .shared) {
        self.model = model
    }

    /// Whether everything needed to read the store is here.
    var ready: Bool { reader != nil }

    /// The reader, when all three pieces are present.
    private var reader: CloudFootage? {
        guard let coordinates, let vault, let credentials, credentials.usable else { return nil }

        return CloudFootage(coordinates: coordinates, credentials: credentials, vault: vault, wiring: wiring)
    }

    /// One sentence about what this phone can show, and what is missing when it cannot show anything.
    ///
    /// Written as a single authority so the recordings screen and the settings screen cannot give
    /// different accounts of the same state.
    var summary: String {
        if coordinates == nil || vault == nil {
            return "Your PC hasn't shared its store with this phone yet. Connect while it's on and tap Join - it needs Face ID, because the key it hands over opens everything in the store."
        }

        if credentials == nil || credentials?.usable != true {
            return "This phone has the key but no bucket credential of its own. Add a read-only one in Settings and it can read what the camera kept while your PC is off."
        }

        if incidents.isEmpty {
            return lastRead == nil
                ? "Nothing read yet."
                : "Nothing in the store. Your PC uploads incidents while it's awake."
        }

        let waiting = incidents.filter { $0.clipParts > 0 && !$0.clipComplete }.count

        return waiting == 0
            ? "\(incidents.count) incident\(incidents.count == 1 ? "" : "s") in the store."
            : "\(incidents.count) incident\(incidents.count == 1 ? "" : "s") in the store, \(waiting) still uploading."
    }

    /// Asks the PC for the store's coordinates and its sealing key. Needs Face ID on this phone.
    ///
    /// The one request on the bridge that does. Switching a light does not and should not - it is
    /// what the phone is for - but this hands over the thing that makes everything in the store
    /// readable, so it goes through the same gate as standing the Security Protocol down.
    func join() async -> String {
        guard model.link.isOnline else {
            return "Your PC isn't answering, so it can't share its store yet. This has to be done while it's on."
        }

        do {
            let client = try await model.session()
            let reply = try await client.approvedRequest(
                "cloud.join",
                reason: "Share this PC’s store with your phone")

            guard reply.kind == "cloud.joined" else {
                return reply.message.isEmpty ? "The PC didn't share its store." : reply.message
            }

            guard let place = StoreCoordinates(reply.body) else {
                return "The PC's answer didn't say where its store is."
            }

            guard let written = reply.text("vaultKey"),
                  let opened = CloudVault.remember(written: written)
            else {
                return "The PC's answer didn't carry a usable key."
            }

            place.save()
            coordinates = place
            vault = opened

            await refresh()

            return credentials?.usable == true
                ? "Joined. This phone can now read what the camera kept without your PC."
                : "Joined. Add a bucket credential in Settings and this phone can read the footage without your PC."
        } catch {
            return "The PC didn't answer that."
        }
    }

    /// The owner's own bucket credential, kept in the Keychain and nowhere else.
    func remember(accessKeyId: String, secretAccessKey: String) {
        let pair = StoreCredentials(
            accessKeyId: accessKeyId.trimmingCharacters(in: .whitespacesAndNewlines),
            secretAccessKey: secretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines),
            region: coordinates?.region ?? "auto")

        guard pair.usable else { return }

        pair.save()
        credentials = pair
    }

    /// Forgets everything about the store. The PC's own copy is untouched.
    func leave() {
        StoreCoordinates.forget()
        CloudVault.forget()
        StoreCredentials.forget()

        coordinates = nil
        vault = nil
        credentials = nil
        incidents = []
        lastRead = nil
    }

    /// Reads the list. Quietly: a store that cannot be reached leaves what was last read alone.
    func refresh() async {
        guard let reader, !reading else { return }

        reading = true
        defer { reading = false }

        let found = await reader.list()

        // An empty answer from a store that could not be reached and an empty store look the same
        // from here, so what was last read is kept rather than blanked. `lastRead` is what the
        // screen uses to tell "nothing yet" from "nothing there".
        if !found.isEmpty || lastRead == nil { incidents = found }

        lastRead = Date()
    }

    /// One incident's still, for a list row.
    func thumbnail(_ id: String) async -> Data? {
        await reader?.thumbnail(id)
    }

    /// The whole recording, written to a temporary file so a player can open it.
    ///
    /// Nil when it is not all in the store yet, which is a state the list already shows: half a
    /// video will not play, and offering it would look like a broken camera.
    func download(_ incident: StoredIncident) async -> URL? {
        guard let reader, let bytes = await reader.clip(incident) else { return nil }

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("jarvis-\(incident.id).mp4")

        do {
            try bytes.write(to: file, options: .atomic)
            return file
        } catch {
            return nil
        }
    }
}
