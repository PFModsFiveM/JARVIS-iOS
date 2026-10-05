import Foundation
import Network

/// What kind of connection the phone has, and whether it has one at all.
///
/// Two separate facts, and conflating them is a bug waiting to happen. `cellular` decides how much
/// the PC should be asked for - lighter frames on mobile data, so walking out of Wi-Fi range
/// switches quality rather than stalling. `offline` decides whether anything is worth trying at
/// all, which is what tells the smart-home diagnostic that the problem is this phone's connection
/// rather than SwitchBot's hub - programme §54.
///
/// Both are watched rather than asked for. A phone that checked on demand would be asking the one
/// question whose answer changes while nobody is looking.
@MainActor
final class NetworkWatch: ObservableObject {
    @Published private(set) var cellular = false

    /// No usable route to anywhere. Not "the PC is not answering" - that is a different thing and
    /// has a different remedy.
    @Published private(set) var offline = false

    /// When the route last changed, so a diagnostic can say how long it has been like this.
    @Published private(set) var changedAt: Date?

    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let onCellular = path.usesInterfaceType(.cellular)
                && !path.usesInterfaceType(.wifi)
                && !path.usesInterfaceType(.wiredEthernet)
            let down = path.status != .satisfied

            Task { @MainActor in
                guard let self else { return }
                guard self.cellular != onCellular || self.offline != down else { return }

                let wasOffline = self.offline

                self.cellular = onCellular
                self.offline = down
                self.changedAt = Date()

                // A transition worth the PC knowing about: it explains a gap in the phone's
                // reporting that would otherwise look like the phone having stopped working.
                if wasOffline != down {
                    AppModel.shared.networkTransition(offline: down, cellular: onCellular)
                }

                AppModel.shared.networkChanged()
            }
        }
        monitor.start(queue: DispatchQueue(label: "jarvis.network"))
    }
}
